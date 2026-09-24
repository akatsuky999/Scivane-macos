import Foundation

/// 负责拉起并守着后端两层（llama-server + FastAPI）。
///
/// 这台是无风扇的 Air，llama-server 抱着 2.8GB 常驻、推理时吃满 GPU。
/// 所以这里的第一原则是**收得干净、收得快**：
///   - App 退出 → 同步等它死透，必要时 SIGKILL，不留残留
///   - App 被强杀 → 脚本里的守护进程按 PID 补刀
///   - 长时间不用 → 自动停掉，下次要用再拉起（冷启动只要 2-3 秒）
@MainActor
final class BackendManager: ObservableObject {

    /// 带的是 `UIText` 而不是 String：「启动失败」这类状态会一直挂在侧栏与设置页上，
    /// 切换界面语言之后要跟着换，而不是停在出事那一刻的语言里。
    enum State: Equatable {
        case idle
        case launching(UIText)
        case ready
        case failed(UIText)

        var isReady: Bool { self == .ready }
    }

    /// 后端起到哪一层。
    ///
    /// 项目管理、阅读、云端问答都不需要本地 OCR 模型 —— 没理由为了列一下
    /// 项目就加载 2.8GB 权重。轻量模式实测 0.4 秒起、常驻 58MB；
    /// 真要 OCR 时再换成完整模式。
    enum Mode: String {
        case lite   // 只有编排层
        case full   // 编排层 + llama-server

        var needsModel: Bool { self == .full }
    }

    /// 当前进程实际起到哪一层。没在跑时为 nil。
    @Published private(set) var runningMode: Mode?

    @Published private(set) var state: State = .idle
    /// 因为长时间闲置被自动停掉（区别于用户主动停）
    @Published private(set) var stoppedForIdle = false

    private let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) { self.preferences = preferences }

    private var process: Process?
    private var pollTask: Task<Void, Never>?
    private var idleTimer: Timer?

    /// 由 AppModel 注入：还有任务在跑就不要自动停
    var isBusy: () -> Bool = { false }

    /// 闲置多久后自动停掉后端。0 表示不自动停。
    var idleTimeout: TimeInterval {
        get {
            let v = preferences.object(forKey: "idleTimeout") as? Double
            return v ?? 300   // 默认 5 分钟
        }
        set {
            preferences.set(newValue, forKey: "idleTimeout")
            restartIdleTimer()
        }
    }

    /// 设置页里指定的后端位置。nil = 自动定位（见 `InstallContext`）。
    /// 键名沿用 `projectRoot`：老版本存下的值照样被当成覆盖读出来。
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

    /// 后端从哪来。每次启动前现算 —— 设置改了、App 被挪了都跟得上。
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

    /// 设置页「项目目录」一栏的写回。**只有用户真的改了才记成覆盖。**
    ///
    /// 那一栏打开时预填的是自动定位的结果。原样点一下「重启引擎」就把它记成覆盖的话，
    /// 装包的用户会被钉死在包内那条路径上 —— App 挪个位置或换个版本，就指向一个
    /// 不存在的旧包，而自动定位本来能找对。清空这一栏同样回到自动定位。
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

    /// 设置页里指定的本地 OCR 位置。nil = 自动发现（组件目录 → 旧部署，见 runtime.py）。
    ///
    /// **只有用户真的指定了才传 `SCIVANE_RUNTIME_ROOT`** —— 那是「覆盖」档，设了就只看它。
    /// 从前这里总会传一个默认的个人路径，等于在每台机器上都把发现链短路成「只看那个
    /// 不存在的目录」。
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
    /// 运行期产物：日志、pidfile、OCR 抠图、沙箱策略。
    ///
    /// **在用户目录下，不跟着仓库走。** 打包安装的机器上根本没有仓库；
    /// 从源码跑时也不该往工作副本里写。与 `config.py` 的 `VAR_DIR` 是同一个默认值。
    nonisolated static let defaultVarRoot = URL(
        fileURLWithPath: NSString(string: "~/.scivane/var").expandingTildeInPath)
    /// 这一次运行的产物目录。**这条规则只写在这里** —— App 自己的计时日志
    /// （`AgentTiming`，在 URLSession 的回调线程上也会用到）也从这里取，
    /// 和后端的日志落在同一个 `logs/` 下。
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

    // MARK: - 启动

    /// 要用的时候调这个。已在运行且层级够用就什么都不做。
    ///
    /// 轻量在跑而这次需要 OCR 时会重启成完整模式 —— 两层是同一个进程树，
    /// 没法只补上缺的那一层。重启只发生在用户真的点了 OCR 的时候，
    /// 而 OCR 本来就要等好几秒，这几秒不显眼。
    func ensureRunning(mode requested: Mode = .full) {
        noteActivity()
        if let process, process.isRunning {
            if runningMode == .full || requested == .lite { return }
            stop()
        }
        start(mode: requested)
    }

    /// 每起一次后端换一个号。
    ///
    /// 凭据是注入进后端进程内存的（走 /llm/providers/{id}/credential），
    /// 进程一重启就没了 —— 而「轻量 → 完整」的升级**就是一次重启**。
    /// 上层据此知道该重新注入，否则升级去做 OCR 之后再提问会莫名其妙地
    /// 报「没有凭据」。
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
        // 脚本据此在 App 意外退出时自我了断，避免 llama-server 变成孤儿
        env["SCIVANE_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        // 本地 OCR：只有设置页里指定了才覆盖；否则交给后端的三档发现
        if let runtimeOverride { env["SCIVANE_RUNTIME_ROOT"] = runtimeOverride.path }
        // **产物位置由这一侧说了算。** 两种语言各算一遍必然有一天算得不一样，
        // 而症状是「插图打不开」这类极难查的错 —— 算一次，传下去。
        env["SCIVANE_VAR_DIR"] = varRoot.path
        // 分段计时开着时两边一起开：只有一边的数字分不清慢在哪一层
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

    // MARK: - 停止
    //
    // 同步收尾：App 退出时必须等它真的死了才返回，
    // 否则 llama-server 会活过 App，在后台继续烤 CPU。

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

        if p.isRunning { p.terminate() }                       // SIGTERM → 脚本 trap → 收子进程

        // 给 3 秒优雅退出。GPU 上正在推理时未必来得及响应。
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline {
            usleep(100_000)
        }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
        }
    }

    /// 按脚本落盘的 PID 补刀。脚本自己被强杀时这是最后一道防线。
    private func reapFromPidFile() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let pid = pid_t(line.trimmingCharacters(in: .whitespaces)), pid > 1 else { continue }
            kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    // MARK: - 闲置自动停

    /// 有识别活动时调用，把闲置计时推后
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
                // 还在跑就不要停，往后顺延
                guard !self.isBusy() else { self.restartIdleTimer(); return }
                self.stop()
                self.stoppedForIdle = true
            }
        }
    }

    // MARK: - 健康检查

    private func pollHealth(mode: Mode) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            // 完整模式首次加载模型通常 10-30 秒，给到 3 分钟；
            // 轻量模式只起一个 Python 进程，几秒不成就是真出问题了
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
        // `ok` 专指本地 OCR 引擎就绪；轻量模式只要编排层活着就算数
        if mode.needsModel { return (json["ok"] as? Bool) ?? false }
        return (json["api"] as? String) == "up"
    }
}
