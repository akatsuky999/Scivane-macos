import Foundation

/// Starts and supervises the backend (FastAPI, plus llama-server in full mode).
///
/// llama-server keeps 2.8 GB resident and saturates the GPU, so shutdown must be clean and quick:
///   - app quits: wait synchronously until it is gone, SIGKILL if needed
///   - app is killed: the script's watchdog reaps it by PID
///   - idle for a while: stop it; a cold start takes 2-3 s
@MainActor
final class BackendManager: ObservableObject {

    /// UIText, not String: a failure stays on screen and must follow a language switch.
    enum State: Equatable {
        case idle
        case launching(UIText)
        case ready
        case failed(UIText)

        var isReady: Bool { self == .ready }
    }

    /// Projects, reading and cloud chat don't need the local OCR model, so the light mode skips
    /// loading 2.8 GB of weights (starts in 0.4 s, 58 MB resident). Full mode only when OCR runs.
    enum Mode: String {
        case lite   // API only
        case full   // API + llama-server

        var needsModel: Bool { self == .full }
    }

    /// nil when not running
    @Published private(set) var runningMode: Mode?

    @Published private(set) var state: State = .idle
    /// stopped for idling, as opposed to stopped by the user
    @Published private(set) var stoppedForIdle = false

    private let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) { self.preferences = preferences }

    private var process: Process?
    private var pollTask: Task<Void, Never>?
    private var idleTimer: Timer?

    /// set by AppModel: don't idle-stop while work is running
    var isBusy: () -> Bool = { false }

    /// 0 disables the idle stop
    var idleTimeout: TimeInterval {
        get {
            let v = preferences.object(forKey: "idleTimeout") as? Double
            return v ?? 300   // 5 minutes
        }
        set {
            preferences.set(newValue, forKey: "idleTimeout")
            restartIdleTimer()
        }
    }

    /// nil = locate automatically (InstallContext). The key keeps its old name `projectRoot` so values
    /// saved by earlier versions still apply.
    var backendOverride: URL? {
        get {
            guard let s = preferences.string(forKey: "projectRoot"), !s.isEmpty else { return nil }
            return URL(fileURLWithPath: s)
        }
        set {
            if let newValue { preferences.set(newValue.path, forKey: "projectRoot") }
            else { preferences.removeObject(forKey: "projectRoot") }
        }
    }

    /// Recomputed before every launch, so a changed setting or a moved app is picked up.
    var install: Result<InstallContext, InstallContext.Failure> {
        Self.resolve(override: backendOverride ?? Self.environmentOverride)
    }

    private static var environmentOverride: URL? {
        guard let s = ProcessInfo.processInfo.environment["SCIVANE_PROJECT_ROOT"], !s.isEmpty else { return nil }
        return URL(fileURLWithPath: s)
    }

    private static func resolve(override: URL?) -> Result<InstallContext, InstallContext.Failure> {
        InstallContext.resolve(override: override, bundle: Bundle.main.bundleURL, executable: Bundle.main.executableURL)
    }

    /// Written back from the Settings field; only a real change is stored as an override.
    ///
    /// The field is prefilled with the located path. Storing it unchanged would pin an installed app
    /// to that bundle path, which breaks once the app is moved or updated. Clearing the field returns
    /// to automatic location.
    func useBackendLocation(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        let automatic = try? Self.resolve(override: Self.environmentOverride).get()
        if trimmed.isEmpty
            || URL(fileURLWithPath: trimmed).standardizedFileURL.path == automatic?.root.path {
            backendOverride = nil
        } else {
            backendOverride = URL(fileURLWithPath: trimmed)
        }
    }

    /// nil = discover automatically (component dir, then legacy deployment).
    ///
    /// SCIVANE_RUNTIME_ROOT is passed only when the user set it: it is the override tier, and once set
    /// nothing else is looked at.
    var runtimeOverride: URL? {
        get {
            guard let s = preferences.string(forKey: "runtimeRoot"), !s.isEmpty else { return nil }
            return URL(fileURLWithPath: s)
        }
        set {
            if let newValue { preferences.set(newValue.path, forKey: "runtimeRoot") }
            else { preferences.removeObject(forKey: "runtimeRoot") }
        }
    }

    var apiPort: Int {
        Int(ProcessInfo.processInfo.environment["SCIVANE_API_PORT"] ?? "8710") ?? 8710
    }
    var apiBase: URL { URL(string: "http://127.0.0.1:\(apiPort)")! }
    /// Runtime output: logs, pidfiles, OCR crops, sandbox policies. Kept in the user's home, never in
    /// the repository (an installed app has none). Same default as VAR_DIR in config.py.
    nonisolated static let defaultVarRoot = URL(
        fileURLWithPath: NSString(string: "~/.scivane/var").expandingTildeInPath)
    /// The one place this is decided. The app's own timing log (AgentTiming, also used from URLSession
    /// callback threads) reads it too, so both sides log to the same logs/.
    nonisolated static var currentVarRoot: URL {
        if let path = ProcessInfo.processInfo.environment["SCIVANE_VAR_DIR"] { return URL(fileURLWithPath: path) }
        return defaultVarRoot
    }
    var varRoot: URL { Self.currentVarRoot }
    var jobsRoot: URL {
        if let path = ProcessInfo.processInfo.environment["SCIVANE_JOBS_DIR"] { return URL(fileURLWithPath: path) }
        return varRoot.appendingPathComponent("jobs")
    }

    private var pidFile: URL { varRoot.appendingPathComponent("run/backend.pids") }

    // MARK: - Start

    /// Call before use. Does nothing if already running at a sufficient level.
    ///
    /// A running light backend is restarted in full mode when OCR is needed: both levels are one
    /// process tree. This only happens when the user starts OCR, which takes seconds anyway.
    func ensureRunning(mode requested: Mode = .full) {
        noteActivity()
        if let process, process.isRunning {
            if runningMode == .full || requested == .lite { return }
            stop()
        }
        start(mode: requested)
    }

    /// Changes on every backend launch. Credentials live in the backend's memory and are lost on
    /// restart, and upgrading light -> full is a restart; this tells callers to inject them again.
    @Published private(set) var launchGeneration = UUID()

    func start(mode requested: Mode = .full) {
        if let process, process.isRunning { return }
        process = nil
        launchGeneration = UUID()

        let context: InstallContext
        switch install {
        case .success(let resolved): context = resolved
        case .failure(let failure):
            state = .failed(failure.text)
            return
        }
        let script = context.launcher
        guard FileManager.default.fileExists(atPath: script.path) else {
            state = .failed(UIText("后端不完整，缺启动脚本：\(script.path)",
                                   "The backend is incomplete; the launch script is missing: \(script.path)"))
            return
        }

        stoppedForIdle = false
        state = .launching(requested.needsModel
            ? UIText("正在唤醒引擎", "Waking the engine") : UIText("正在启动服务", "Starting the service"))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        p.currentDirectoryURL = context.root
        var env = ProcessInfo.processInfo.environment
        // lets the script kill itself if the app dies, so llama-server is never orphaned
        env["SCIVANE_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        // only when set in Settings; otherwise the backend's own discovery applies
        if let runtimeOverride { env["SCIVANE_RUNTIME_ROOT"] = runtimeOverride.path }
        // Computed once here and passed down: two languages computing it separately would drift one day,
        // and the symptom (figures that won't open) is hard to trace.
        env["SCIVANE_VAR_DIR"] = varRoot.path
        // timing on both sides at once; numbers from one side can't tell which layer is slow
        if AgentTiming.enabled { env["SCIVANE_TIMING"] = "1" }
        if !requested.needsModel { env["SCIVANE_SKIP_LLAMA"] = "1" }
        p.environment = env

        do {
            try p.run()
            process = p
            runningMode = requested
        } catch {
            state = .failed(UIText("无法启动后端：\(error.localizedDescription)",
                                   "Couldn't start the backend: \(error.localizedDescription)"))
            return
        }

        pollHealth(mode: requested)
        restartIdleTimer()
    }

    func restart() {
        let previous = runningMode ?? .full
        stop()
        start(mode: previous)
    }

    // MARK: - Stop
    //
    // Synchronous: quitting must wait until it is really gone, or llama-server outlives the app.

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        idleTimer?.invalidate()
        idleTimer = nil

        defer {
            reapFromPidFile()
            state = .idle
            runningMode = nil
        }

        guard let p = process else { return }
        process = nil

        if p.isRunning { p.terminate() }                       // SIGTERM -> script trap -> children

        // 3 s to exit cleanly; mid-inference on the GPU it may not respond in time
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline {
            usleep(100_000)
        }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
        }
    }

    /// Kill by the PID the script wrote: the last line of defence if the script itself was killed.
    private func reapFromPidFile() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let pid = pid_t(line.trimmingCharacters(in: .whitespaces)), pid > 1 else { continue }
            kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    // MARK: - Idle stop

    /// Postpones the idle stop.
    func noteActivity() {
        restartIdleTimer()
    }

    private func restartIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
        let timeout = idleTimeout
        guard timeout > 0, process != nil else { return }

        idleTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.process != nil else { return }
                // still busy: try again later
                guard !self.isBusy() else { self.restartIdleTimer(); return }
                self.stop()
                self.stoppedForIdle = true
            }
        }
    }

    // MARK: - Health

    private func pollHealth(mode: Mode) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            // full mode's first model load usually takes 10-30 s; the light mode is one Python process, so a
            // slow start there is a real failure
            let deadline = Date().addingTimeInterval(mode.needsModel ? 180 : 30)
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 3
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }

            while !Task.isCancelled && Date() < deadline {
                if await self.processDied() {
                    self.state = .failed(UIText(
                        "后端启动即退出。查看 var/logs/llama-server.log 与 var/logs/api.log。",
                        "The backend exited right after starting. See var/logs/llama-server.log and var/logs/api.log."))
                    return
                }
                if let ok = try? await Self.probe(session: session, base: self.apiBase, mode: mode), ok {
                    self.state = .ready
                    // Keep detecting a dead backend after startup, too.
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                        if await self.processDied() {
                            self.process = nil
                            self.state = .failed(UIText("本地引擎已退出，可以重试。",
                                                        "The local engine exited. You can try again."))
                            return
                        }
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
            if !Task.isCancelled {
                self.state = .failed(mode.needsModel
                    ? UIText("后端 3 分钟未就绪。查看 var/logs/ 下的日志。",
                             "The backend wasn't ready after 3 minutes. See the logs in var/logs/.")
                    : UIText("服务 30 秒未就绪。查看 var/logs/api.log。",
                             "The service wasn't ready after 30 seconds. See var/logs/api.log."))
            }
        }
    }

    private func processDied() async -> Bool {
        guard let p = process else { return true }
        return !p.isRunning
    }

    private static func probe(session: URLSession, base: URL, mode: Mode) async throws -> Bool {
        let (data, response) = try await session.data(from: base.appendingPathComponent("health"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        // `ok` means the OCR engine is ready; in light mode a live API is enough
        if mode.needsModel { return (json["ok"] as? Bool) ?? false }
        return (json["api"] as? String) == "up"
    }
}
