import Foundation

/// UI state machine for installing local OCR. A card rather than a modal: an install takes
/// minutes and the user is probably reading.
///
/// Views observe this object directly rather than through AppModel: progress arrives four times
/// a second, and forwarding it would recompute the whole window each time.
@MainActor
final class OCRInstaller: ObservableObject {

    enum Phase: Equatable {
        case idle
        /// recognition requested without local OCR: offer download or migration
        case offer(RuntimeClient.Status)
        case running(Run)
        case failed(code: String, message: String, method: RuntimeClient.Method)
        case done(elapsed: Double, method: RuntimeClient.Method)
    }

    struct Run: Equatable {
        var method: RuntimeClient.Method
        var jobID = ""
        var step = 0
        var steps = 0
        /// empty until the first step; the card shows "Preparing..."
        var label = ""
        var done = 0
        var total = 0
        /// nil means bytes; the pip step counts packages
        var unit: String?
        var source = ""
        /// the latest source switch, as told to the user
        var switched: String?
        var lastLog = ""
        var elapsed: Double = 0

        var fraction: Double? { total > 0 ? min(1, Double(done) / Double(total)) : nil }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status: RuntimeClient.Status?
    /// The first recognition after an install takes about a minute while macOS loads the new binary.
    @Published var freshlyInstalled = false

    /// Resumes the jobs held back for OCR; set by AppModel.
    var onInstalled: (() -> Void)?

    var isRunning: Bool { if case .running = phase { return true }; return false }

    private let backend: BackendManager
    /// must be retained: releasing it tears down its URLSession and ends the stream
    private var client: RuntimeClient?
    private var task: Task<Void, Never>?

    init(backend: BackendManager) {
        self.backend = backend
    }

    /// Asks the backend once; returns the last result when it isn't running. Never starts it.
    @discardableResult
    func refresh() async -> RuntimeClient.Status? {
        guard backend.state.isReady else { return status }
        if let fresh = try? await RuntimeClient(base: backend.apiBase).status() {
            status = fresh
            return fresh
        }
        return nil
    }

    /// Show the options on the card; never interrupts a running install.
    func offer(_ status: RuntimeClient.Status) {
        self.status = status
        if isRunning { return }
        phase = .offer(status)
    }

    func start(_ method: RuntimeClient.Method) {
        guard task == nil else { return }
        let client = RuntimeClient(base: backend.apiBase)
        self.client = client
        phase = .running(Run(method: method))
        task = Task { [weak self] in
            for await event in client.install(method: method) {
                self?.apply(event, method: method)
            }
            self?.streamEnded(method: method)
        }
    }

    func cancel() {
        guard case .running(let run) = phase, !run.jobID.isEmpty, let client else { return }
        Task { await client.cancel(jobID: run.jobID) }
    }

    func dismiss() {
        guard !isRunning else { return }
        phase = .idle
    }

    private func apply(_ event: RuntimeClient.Event, method: RuntimeClient.Method) {
        // keep the idle stop away: its 5 minutes are about the length of an install
        backend.noteActivity()
        switch event {
        case .done(_, _, let elapsed):
            phase = .done(elapsed: elapsed, method: method)
            freshlyInstalled = true
            Task { [weak self] in
                await self?.refresh()
                self?.onInstalled?()
            }
            return
        case .failed(let code, let message):
            phase = .failed(code: code, message: message, method: method)
            return
        default:
            break
        }
        guard case .running(var run) = phase else { return }
        switch event {
        case .meta(let jobID, _):
            run.jobID = jobID
        case .step(let index, let total, _, let label):
            run.step = index
            run.steps = total
            run.label = label
            run.done = 0
            run.total = 0
            run.unit = nil
        case .progress(_, let done, let total, let unit, let source):
            run.done = done
            run.total = total
            run.unit = unit
            run.source = source
        case .source(_, let from, let to, let reason):
            run.switched = L("\(from) \(reason)，换到 \(to)", "\(from): \(reason); switched to \(to)")
        case .log(let message):
            run.lastLog = message
        case .heartbeat(let elapsed):
            run.elapsed = elapsed
        case .done, .failed:
            break
        }
        phase = .running(run)
    }

    private func streamEnded(method: RuntimeClient.Method) {
        task = nil
        client = nil
        // stream ended without a final state: the backend probably exited. Retrying resumes from the cache
        if isRunning {
            phase = .failed(code: "INTERRUPTED", message: L("安装中断了（本地服务退出了？）。已下载的部分留着，重来会接着下。", "The install was interrupted (did the local service quit?). What was downloaded is kept; trying again resumes it."),
                            method: method)
        }
    }
}
