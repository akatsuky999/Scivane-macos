import Foundation

/// 「装本地 OCR」这件事在界面上的状态机。
///
/// 入口不是一个模态框，而是正文栏顶上的一张卡（`OCRInstallCard`）—— 同批准卡的判断：
/// 装一次要几分钟，这段时间用户很可能在读别的，不该被按住。
///
/// **视图直接观察这个对象**，不经过 AppModel 转发：安装时每秒四次进度，转发出去等于
/// 每秒把整个窗口重算四次；而从 AppModel 的属性里「顺手取出来」的对象又是不被观察的。
/// 所以卡片自己持有它，空闲时什么都不画。
@MainActor
final class OCRInstaller: ObservableObject {

    enum Phase: Equatable {
        case idle
        /// 用户要识别，但本地 OCR 没装：给出「下载安装 / 从旧部署迁移」
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
        /// 空串 = 还没到第一步；卡片显示「准备中…」（按界面语言）
        var label = ""
        var done = 0
        var total = 0
        /// nil 表示字节；pip 那一步是「包」
        var unit: String?
        var source = ""
        /// 最近一次换源，说给用户听的那一句
        var switched: String?
        var lastLog = ""
        var elapsed: Double = 0

        var fraction: Double? { total > 0 ? min(1, Double(done) / Double(total)) : nil }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status: RuntimeClient.Status?
    /// 刚装完（或迁完）之后的第一次识别要一分钟左右：macOS 第一次加载新创建的二进制。
    /// 不说出来的话，那一分钟看着像卡死。
    @Published var freshlyInstalled = false

    /// 装好之后接着识别被挡下的那几份。由 AppModel 接上。
    var onInstalled: (() -> Void)?

    var isRunning: Bool { if case .running = phase { return true }; return false }

    private let backend: BackendManager
    /// 必须持有：RuntimeClient 内含 URLSession 与 delegate，被释放会中断流
    private var client: RuntimeClient?
    private var task: Task<Void, Never>?

    init(backend: BackendManager) {
        self.backend = backend
    }

    /// 问一次后端。后端没起来时返回上一次的结果 —— 这里不负责拉起后端。
    @discardableResult
    func refresh() async -> RuntimeClient.Status? {
        guard backend.state.isReady else { return status }
        if let fresh = try? await RuntimeClient(base: backend.apiBase).status() {
            status = fresh
            return fresh
        }
        return nil
    }

    /// 识别被挡下了：在卡上给出选项。正在装的时候不打断它。
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
        // 装的时候后端在干活：别让闲置计时把它停了（默认 5 分钟，正好是一次安装的量级）
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
        // 流断了却没有收到终态：后端多半退出了。已下的部分在缓存里，重来会接着下
        if isRunning {
            phase = .failed(code: "INTERRUPTED", message: L("安装中断了（本地服务退出了？）。已下载的部分留着，重来会接着下。", "The install was interrupted (did the local service quit?). What was downloaded is kept; trying again resumes it."),
                            method: method)
        }
    }
}
