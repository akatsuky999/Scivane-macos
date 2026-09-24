import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {

  enum Mode: String, CaseIterable, Identifiable {
    case convert  // 只要 Markdown，不打算读：拖一批进来，出一批 .md
    case read  // 左原文右译稿，逐页对读

    var id: String { rawValue }
    var label: String { self == .convert ? L("转换", "Convert") : L("阅读", "Read") }
    var symbol: String { self == .convert ? "square.stack.3d.down.right" : "book.pages" }
  }

  enum ReadingPane: String, CaseIterable { case source, text }

  /// 正文栏显示什么：渲染出来的正文，还是 Agent 对话。
  ///
  /// 放在 AppModel 而不是 ReaderView 的 @State：栏头已经合并进全局工具栏，
  /// 驱动它的控件和使用它的视图不在同一层，状态必须提上来。
  enum TextMode: String, CaseIterable {
    case document, chat
    var label: String { self == .document ? L("正文", "Text") : "Agent" }
    var symbol: String { self == .document ? "text.alignleft" : "sparkles" }
  }

  @Published var textMode: TextMode = .document

  /// 全局工具栏里那个分段控件的选中项。
  /// 单栏时是「原稿／正文／Agent」三选一，双栏时右栏只在「正文／Agent」间切。
  var paneSelection: String {
    get {
      if !dualPane && singlePane == .source { return "source" }
      return textMode == .chat ? "chat" : "text"
    }
    set {
      switch newValue {
      case "source": singlePane = .source
      case "text": singlePane = .text; textMode = .document
      default: singlePane = .text; textMode = .chat
      }
    }
  }
  /// 单栏还是双栏对照 —— **这是用户偏好，只由工具栏那个开关改。**
  ///
  /// 两条纪律：
  /// 1. **任何导航动作都不许覆盖它。** 进项目、点对话都只决定"看哪一栏"，
  ///    不决定"怎么排"；否则用户刚切成单栏，一进项目又变回双栏。
  /// 2. **启动时要读得回来。** 先前它只写不读，于是每次开 App 都回到单栏，
  ///    而用户会以为自己上次没设成功。
  @Published var dualPane = UserDefaults.standard.string(forKey: "readingLayout") == "split" {
    didSet { UserDefaults.standard.set(dualPane ? "split" : "single", forKey: "readingLayout") }
  }
  @Published var singlePane: ReadingPane = .source
  @Published private var comparisons: [DocumentJob.ID: DocumentJob.ID] = [:]
  var readingSource: DocumentJob? {
    guard let job = selected else { return nil }
    if !job.isMarkdown { return job }
    guard let id = comparisons.first(where: { $0.value == job.id })?.key else { return nil }
    return jobs.first { $0.id == id }
  }
  var readingDocument: DocumentJob? {
    guard let job = selected else { return nil }
    if job.isMarkdown { return job }
    if let id = comparisons[job.id], let linked = jobs.first(where: { $0.id == id }) {
      return linked
    }
    return job.hasResult ? job : nil
  }
  var canSyncReading: Bool {
    dualPane && readingSource?.isPDF == true && readingDocument?.isMarkdown == false
  }
  func useOCRText() {
    if let source = readingSource {
      comparisons.removeValue(forKey: source.id)
      selection = source.id
      replayIntoRenderer()
    }
  }

  /// 现在只有阅读这一种形态。
  ///
  /// **批量转换与对照阅读已下架**（2026-09-16）：产品的重心是「和一篇论文
  /// 对话」，那两件事既不服务这个目标，又各自占着一块常驻界面。枚举与
  /// `ConvertView` 留着没删 —— 下架是界面决定，不是代码判决，真要回来
  /// 只需要把入口放回去。
  @Published var mode: Mode = .read
  @Published private(set) var jobs: [DocumentJob] = [] {
    didSet { observeJobs() }
  }

  // MARK: - 项目
  //
  // 一个 PDF 就是一个项目：原稿、作为静态上下文的正文、标题、会话历史。
  // 与「本次文档」的区别是它**持久** —— 退出 App 再打开还在。
  // 存储在后端（~/.scivane/projects），这里只持有视图状态。

  @Published var projects: [Project] = []
  @Published var activeProjectID: Project.ID?
  /// 项目操作进行中（构建、切换、覆盖上下文），界面据此禁用按钮避免重复点击。
  @Published var projectBusy = false
  @Published var sidebarNavigationBusy = false
  /// 哪些 job 属于哪个项目。OCR 完成时据此决定要不要写回项目上下文。
  @Published var jobProjects: [DocumentJob.ID: Project.ID] = [:]

  var activeProject: Project? {
    guard let activeProjectID else { return nil }
    return projects.first { $0.id == activeProjectID }
  }

  var projectClient: ProjectClient { ProjectClient(base: backend.apiBase) }
  @Published var notice: String?
  @Published var noticeID = UUID()
  private var jobChanges: AnyCancellable?

  private func observeJobs() {
    jobChanges = Publishers.MergeMany(jobs.map { $0.objectWillChange })
      .debounce(for: .milliseconds(16), scheduler: RunLoop.main)
      .sink { [weak self] _ in self?.objectWillChange.send() }
  }

  private func notify(_ message: String) {
    notice = message
    noticeID = UUID()
  }
  @Published var selection: DocumentJob.ID?

  // 阅读模式的视图状态
  @Published var currentPage = 1
  @Published var syncScroll = true
  /// 原稿缩略图。**默认关** —— 它替代不了滚动，却一直占着左边一条。
  @Published var showThumbnails = false
  @Published var isSearching = false
  @Published var searchQuery = ""
  @Published var searchHits = 0

  /// 转换模式下自动把结果写到这里，省掉逐个另存
  @Published var autoExportDirectory: URL? {
    didSet {
      UserDefaults.standard.set(autoExportDirectory?.path, forKey: "autoExportDirectory")
    }
  }

  /// 由 MarkdownWebView 注入
  var renderBridge: ((String, [Any]) -> Void)?
  /// 由 PDFReaderView 注入
  var pdfGoToPage: ((Int) -> Void)?

  // MARK: - Agent
  //
  // **每一层各持一个会话实例**：书房一个，每个项目一个。
  // 「打开项目是换一个 agent 实例，不是换上下文」—— 两层的记录混成一条流，
  // 用户就分不清哪句话是对着哪一层说的，而书房那层根本读不到论文正文。

  /// **刻意不是 @Published。**
  ///
  /// 它是个「按 key 取对象」的仓库，不是界面状态。做成 @Published 会出两个问题：
  /// 取用发生在 `body` 里，而按需建实例会顺手写这个字典 —— 那就是
  /// 「view update 期间改状态」，SwiftUI 会丢掉这次变更；
  /// 而且字典本身变不变，与**会话内部**（消息、运行中）变没变是两回事，
  /// 界面要观察的是后者。所以界面直接 @ObservedObject 持有会话对象本身，
  /// 见 `AgentPane`。
  private var agentSessions: [String: AgentSession] = [:]
  /// 已配置的 provider（只含元数据，**绝不含凭据**）。
  @Published var providers: [ProviderSummary] = []
  /// 当前选中的 provider id。存偏好 —— 选好的模型是个人习惯。
  /// 这个 AppModel 是不是真 App 在用（而不是离屏验证 / 预览）。
  ///
  /// **只有 `ScivaneApp` 会把它置成 true。** 有些动作带副作用（写 providers.json、
  /// 起后端），它们只该发生在用户面前，不该因为某条验证构造了一个 AppModel
  /// 就跟着发生。
  var isLiveApp = false

  @Published var agentProvider: String = UserDefaults.standard.string(forKey: "agentProvider") ?? "" {
    didSet { UserDefaults.standard.set(agentProvider, forKey: "agentProvider") }
  }
  /// 凭据已经注入过的 provider。后端重启（轻量→完整升级）之后要重来一次。
  var injectedProviders: Set<String> = []
  /// 上次注入时后端是第几次启动的。对不上就说明重启过，要重新注入。
  var injectedGeneration: UUID?

  /// 每个项目的对话清单。**这个是 @Published** —— 切换条要跟着它重画。
  ///
  /// 与 `agentSessions` 的区别值得说清楚：这里存的是**清单**（有哪些对话、
  /// 各自叫什么），那里存的是**运行中的会话对象**。清单变了界面要重画，
  /// 所以它发布；会话内部变了界面也要重画，但那一层观察由视图自己做
  /// （`AgentPane` → `@ObservedObject`），不经过 AppModel。
  @Published var conversations: [String: [Conversation]] = [:]

  /// 每个项目当前选中哪条对话。项目 id → 对话 id。
  @Published var activeConversation: [String: String] = [:]

  /// 每个项目 `files/` 里的材料。项目 id → 文件清单。
  @Published var projectFiles: [String: [ProjectFile]] = [:]

  /// 当前项目的材料清单。
  var activeProjectFiles: [ProjectFile] {
    guard let activeProjectID else { return [] }
    return projectFiles[activeProjectID] ?? []
  }

  /// 当前这一层的会话。没打开项目就是书房。
  var agentSession: AgentSession {
    session(for: activeProjectID, conversation: activeConversationID)
  }

  /// 当前项目选中的那条对话。没打开项目、或还没拉到清单时是 nil。
  var activeConversationID: String? {
    guard let activeProjectID else { return nil }
    return activeConversation[activeProjectID]
  }

  /// 当前项目的对话清单。
  var activeConversations: [Conversation] {
    guard let activeProjectID else { return [] }
    return conversations[activeProjectID] ?? []
  }

  /// 取这一层这条对话的会话，没有就建一个。**不发布任何变更** —— 见上面的说明。
  ///
  /// key 里带上对话 id：换一条对话是换**另一个会话实例**，不是把当前实例
  /// 清空重来。后者会让正在跑的那一轮把结果写进新对话的界面里。
  func session(for projectID: String?, conversation: String? = nil) -> AgentSession {
    let key = Self.sessionKey(projectID, conversation)
    if let existing = agentSessions[key] { return existing }
    let session = AgentSession(projectID: projectID, conversationID: conversation)
    agentSessions[key] = session
    return session
  }

  /// 会话仓库的键。**书房那层没有对话的概念**，所以它永远只有一个键。
  static func sessionKey(_ projectID: String?, _ conversation: String?) -> String {
    guard let projectID else { return deskKey }
    return conversation.map { "\(projectID)/\($0)" } ?? projectID
  }

  /// 丢掉某条对话的会话实例。删除对话之后要清掉，否则同 id 再出现时
  /// 会拿到一份陈旧的记录。
  func forgetSession(projectID: String, conversation: String) {
    agentSessions.removeValue(forKey: Self.sessionKey(projectID, conversation))
  }

  static let deskKey = "__desk__"

  let backend: BackendManager
  /// 本地 OCR 的安装。卡片直接观察它，不经这里转发（见 OCRInstaller 的说明）。
  let ocrInstaller: OCRInstaller
  /// 因为本地 OCR 没装而被挡下的那几份：装好之后接着识别，不用用户再点一次
  private var awaitingOCR: [DocumentJob.ID] = []
  private var runner: Task<Void, Never>?
  private var runGeneration = UUID()
  private var activeJobID: String?
  /// 必须持有：OCRClient 内含 URLSession 与 delegate，被释放会中断流
  private var client: OCRClient?

  init(backend: BackendManager) {
    self.backend = backend
    self.ocrInstaller = OCRInstaller(backend: backend)
    // 还有任务在跑就别自动停后端
    backend.isBusy = { [weak self] in self?.hasBackendWork ?? false }
    ocrInstaller.onInstalled = { [weak self] in self?.resumeAfterOCRInstall() }
    if let p = UserDefaults.standard.string(forKey: "autoExportDirectory") {
      autoExportDirectory = URL(fileURLWithPath: p)
    }
  }

  // MARK: - 选中

  var selected: DocumentJob? {
    if let selection, let job = jobs.first(where: { $0.id == selection }) { return job }
    return fallbackJob
  }

  /// 没有明确选中时兜底挑哪一份。
  ///
  /// **不能一律 `jobs.first`。** 项目的原稿与正文进项目时也挂进了 `jobs`，
  /// 于是退出项目之后兜底会把刚退出去的那篇论文又端上来，用户以为退出没生效。
  /// 规则改成对称的一句：**在项目里只认这个项目的文件，不在项目里只认
  /// 「本次文档」**。空项目因此是真的空白，而不是显示上一篇的原稿。
  private var fallbackJob: DocumentJob? {
    if let activeProjectID { return jobs.first { jobProjects[$0.id] == activeProjectID } }
    return jobs.first { jobProjects[$0.id] == nil }
  }

  var hasJobs: Bool { !jobs.isEmpty }
  var isBusy: Bool { jobs.contains { $0.status.isRunning || $0.status == .queued } }

  // 后台对话和等待批准也占用后端；只看 OCR 会在五分钟后杀掉仍在工作的 agent。
  var hasBackendWork: Bool {
    isBusy || ocrInstaller.isRunning || agentSessions.values.contains { $0.running || $0.preparing }
  }

  var finishedCount: Int { jobs.filter(\.status.isFinished).count }

  // MARK: - 入队

  func add(urls: [URL], to pane: ReadingPane? = nil) {
    // 在项目里导入 Markdown，意思是「用它当这篇论文的正文」，
    // 而不是临时拉一份来对照 —— 所以要走项目上下文与二次确认。
    if let project = activeProject, pane != .source {
      let markdown = urls.first {
        ["md", "markdown"].contains($0.pathExtension.lowercased())
      }
      if let markdown {
        Task { await importMarkdownIntoProject(markdown, project: project) }
        return
      }
    }
    let previousSource = readingSource
    let previousText = readingDocument
    var first: DocumentJob?
    for raw in urls {
      let url = raw.standardizedFileURL.resolvingSymlinksInPath()
      guard
        DocumentJob.supportedTypes.contains(where: { type in
          UTType(filenameExtension: url.pathExtension)?.conforms(to: type) == true
        })
      else { continue }
      guard let job = adopt(url: url) else { continue }
      first = first ?? job
    }
    if let first {
      if pane == .text, first.isMarkdown, let source = previousSource {
        comparisons[source.id] = first.id
        select(source)
      } else if pane == .source, !first.isMarkdown, let text = previousText, text.isMarkdown {
        // A Markdown document belongs to one explicit comparison at a time.
        comparisons = comparisons.filter { $0.value != text.id }
        comparisons[first.id] = text.id
        select(first)
      } else {
        select(first)
      }
      if let pane { singlePane = pane }
    }
  }

  /// 找到或新建这个 URL 对应的 job。
  ///
  /// 单独抽出来是因为项目要复用同一套逻辑：进入项目时也要把原稿与正文
  /// 变成 job 挂进阅读区，规则必须与手动导入完全一致，否则两条路径会慢慢漂移。
  @discardableResult
  func adopt(url raw: URL, restoreCache: Bool = true) -> DocumentJob? {
    let url = raw.standardizedFileURL.resolvingSymlinksInPath()
    if let existing = jobs.first(where: { $0.url == url }) { return existing }
    let job = DocumentJob(url: url)
    if job.isMarkdown {
      do {
        let text = try String(contentsOf: url, encoding: .utf8)
        job.pages = [1: text]
        job.consolidated = text
        job.status = .imported
      } catch {
        notify(L("无法读取 Markdown：", "Couldn't read the Markdown: ") + error.localizedDescription)
        return nil
      }
    } else if restoreCache {
      ResultCache.restore(job, root: backend.varRoot)
    }
    jobs.append(job)
    return job
  }

  /// 把两份文档配成「原稿 ↔ 正文」。项目与手动配对共用它。
  func pair(source: DocumentJob, text: DocumentJob) {
    comparisons = comparisons.filter { $0.value != text.id }
    comparisons[source.id] = text.id
  }

  func unpair(source: DocumentJob) {
    comparisons.removeValue(forKey: source.id)
  }

  /// 一个面板收所有支持的类型。**侧栏那个「导入文档」用它。**
  ///
  /// 早先分成 PDF / Markdown 两个入口，是批量转换那个模式的遗留 ——
  /// 那时两者的去向不同。现在拖进来什么都能收（见 ContentView 的
  /// dropDestination 走的就是 `add(urls:)`），面板没有理由比拖拽更笨。
  func importPanel() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = DocumentJob.supportedTypes
    panel.allowsMultipleSelection = true
    panel.message = L("导入 PDF、图片或 Markdown", "Import a PDF, image or Markdown file")
    panel.prompt = L("导入", "Import")
    if panel.runModal() == .OK {
      add(urls: panel.urls)
      mode = .read
    }
  }

  func openPanel(markdown: Bool = false) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes =
      markdown
      ? [
        UTType(filenameExtension: "md") ?? .plainText,
        UTType(filenameExtension: "markdown") ?? .plainText,
      ] : DocumentJob.supportedTypes.filter { !$0.conforms(to: .text) }
    panel.allowsMultipleSelection = true
    panel.message = markdown
      ? L("导入 Markdown，直接阅读正文和本地插图", "Import Markdown to read its text and local images directly")
      : L("导入 PDF 或图片，预览后手动开始 OCR", "Import a PDF or image; preview it, then start OCR yourself")
    panel.prompt = L("导入", "Import")
    if panel.runModal() == .OK {
      add(urls: panel.urls, to: markdown ? .text : .source)
      mode = .read
    }
  }

  func reloadMarkdown(_ job: DocumentJob) {
    guard job.isMarkdown else { return }
    do {
      let text = try String(contentsOf: job.url, encoding: .utf8)
      job.pages = [1: text]
      job.consolidated = text
      job.status = .imported
      select(job)
    } catch { notify(L("重新载入失败：", "Couldn't reload: ") + error.localizedDescription) }
  }

  /// 本地 OCR 能不能用。轻量后端起不来、或者问不到（旧后端没有这个接口）时照原路走 ——
  /// 那条路自己会报出真实原因，这里只负责「明确没装」这一种情况。
  private func ocrAvailable() async -> Bool {
    guard await awaitBackend(mode: .lite, quiet: true) else { return true }
    guard let status = await ocrInstaller.refresh() else { return true }
    if status.available { return true }
    ocrInstaller.offer(status)
    return false
  }

  private func resumeAfterOCRInstall() {
    let ids = awaitingOCR
    awaitingOCR.removeAll()
    for job in jobs where ids.contains(job.id) && job.canStartOCR { job.status = .queued }
    startRunner()
  }

  func startOCR(_ job: DocumentJob) {
    guard job.canStartOCR else { return }
    job.status = .queued
    startRunner()
  }
  func startAllOCR() {
    for job in jobs where job.canStartOCR { job.status = .queued }
    startRunner()
  }

  func select(_ job: DocumentJob) {
    selection = job.id
    if !dualPane { singlePane = job.isMarkdown || job.hasResult ? .text : .source }
    currentPage = 1
    replayIntoRenderer()
  }

  /// 把当前文档已有的页重新灌进渲染器。
  /// WebView 是懒创建的：拖入第一份文件时它还不存在，此时到达的页会丢，
  /// 所以 WebView 建好后要主动回放一次。
  func replayIntoRenderer() {
    guard let job = readingDocument else {
      renderBridge?("reset", [0])
      return
    }
    renderBridge?("setDocumentBase", [job.isMarkdown ? "scivane-document://local/" : ""])
    renderBridge?("reset", [job.pageCount])
    for index in job.pages.keys.sorted() {
      renderBridge?("setPage", [index, job.pages[index] ?? ""])
    }
  }

  func remove(_ job: DocumentJob) {
    guard !job.status.isRunning else { return }
    jobs.removeAll { $0.id == job.id }
    if selection == job.id {
      selection = jobs.first?.id
      replayIntoRenderer()
    }
  }

  func clearFinished() {
    jobs.removeAll { $0.status.isFinished }
    if !jobs.contains(where: { $0.id == selection }) {
      selection = jobs.first?.id
      replayIntoRenderer()
    }
  }

  // MARK: - 执行队列
  //
  // llama-server 单实例是串行的，并发排队只会让首份文档更晚出结果，
  // 所以这里就老老实实一份一份来。

  private func startRunner() {
    guard runner == nil else { return }
    let generation = UUID()
    runGeneration = generation
    runner = Task { [weak self] in
      guard let self else { return }
      while let next = self.jobs.first(where: { $0.status == .queued }) {
        if Task.isCancelled { break }
        await self.run(next)
      }
      if self.runGeneration == generation { self.runner = nil }
    }
  }

  private func run(_ job: DocumentJob) async {
    // 本地 OCR 是可选组件：**先问轻量后端装没装，没装就别去升级**。
    // 升级到完整模式要先停掉正在跑的轻量后端，而完整模式又起不来 —— 用户会同时失去
    // 识别和项目列表，只看到一句与原因无关的「后端启动即退出」。
    if backend.runningMode != .full, !(await ocrAvailable()) {
      for pending in jobs where pending.id == job.id || pending.status == .queued {
        pending.status = .ready
        if !awaitingOCR.contains(pending.id) { awaitingOCR.append(pending.id) }
      }
      return
    }
    // 可能因为长时间闲置被自动停了，用之前先确保它活着
    let generation = runGeneration
    backend.ensureRunning()
    while !backend.state.isReady {
      if case .failed(let message) = backend.state {
        job.status = .failed(message)
        return
      }
      try? await Task.sleep(nanoseconds: 800_000_000)
      if Task.isCancelled { return }
    }

    guard generation == runGeneration, !Task.isCancelled else { return }
    job.status = .running(done: 0, total: job.pageCount)
    job.activePage = 0
    let client = OCRClient(base: backend.apiBase)
    self.client = client

    do {
      for try await event in client.recognise(path: job.url.path) {
        guard generation == runGeneration else { return }
        if Task.isCancelled {
          job.status = .cancelled
          return
        }
        backend.noteActivity()  // 推后闲置自动停
        switch event {
        case .meta(let id, let pages, _):
          activeJobID = id
          if pages > 0 { job.status = .running(done: 0, total: pages) }

        case .progress(let page, let total, let elapsed),
          .heartbeat(let page, let total, let elapsed):
          job.activePage = page
          job.elapsed = elapsed
          if total > 0 {
            job.status = .running(done: job.pages.count, total: total)
          }

        case .page(let index, let total, let markdown, let elapsed):
          // 第一页回来了，「新装的引擎第一次加载」那一分钟已经过去
          ocrInstaller.freshlyInstalled = false
          job.pages[index] = markdown
          job.elapsed = elapsed
          job.status = .running(done: job.pages.count, total: max(total, job.pageCount))
          if job.id == readingDocument?.id && mode == .read {
            renderBridge?("setPage", [index, markdown])
          }

        case .done(let markdown, let text, let elapsed, let cancelled):
          job.elapsed = elapsed
          job.consolidated = markdown
          job.plainText = text
          job.status = cancelled ? .cancelled : .finished(seconds: elapsed)
          if !cancelled {
            ResultCache.save(job, root: backend.varRoot)
            autoExport(job)
            // 属于某个项目的话，结果要成为它的静态上下文。
            // serverJobID 决定插图能不能被吸收进项目目录，不能丢。
            if jobProjects[job.id] != nil {
              let serverJobID = activeJobID
              Task { await attachOCRResult(job, serverJobID: serverJobID) }
            }
          }

        case .failed(let message):
          // 后端的原话（它按请求那一刻的界面语言说）
          job.status = .failed(.verbatim(message))
        }
      }
      if generation == runGeneration, case .running = job.status {
        job.status = .failed(UIText("识别连接中断，请重试。", "The OCR connection dropped. Please try again."))
      }
    } catch is CancellationError {
      if generation == runGeneration { job.status = .cancelled }
    } catch {
      if generation == runGeneration { job.status = .failed(.verbatim(error.localizedDescription)) }
    }
    if generation == runGeneration { activeJobID = nil }
  }

  func cancelAll() {
    runGeneration = UUID()
    runner?.cancel()
    runner = nil
    client?.stop()
    if let id = activeJobID {
      let client = OCRClient(base: backend.apiBase)
      Task { await client.cancel(jobID: id) }
      activeJobID = nil
    }
    for job in jobs where job.status.isRunning || job.status == .queued {
      job.status = .cancelled
    }
  }

  /// 只停当前这一份，队列里排着的继续跑
  func cancelCurrent() {
    if let id = activeJobID {
      let client = OCRClient(base: backend.apiBase)
      Task { await client.cancel(jobID: id) }
    }
  }

  func retry(_ job: DocumentJob) {
    guard !job.isMarkdown, !job.status.isRunning, job.status != .queued else { return }
    job.elapsed = 0
    job.activePage = 0
    job.plainText = ""
    job.exportedTo = nil
    job.pages = [:]
    job.consolidated = ""
    job.status = .queued
    startRunner()
  }

  // MARK: - 导出

  private func autoExport(_ job: DocumentJob) {
    guard let dir = autoExportDirectory else { return }
    do { try job.write(to: dir, assetsRoot: backend.jobsRoot) } catch {
      notify(L("自动导出失败：", "Auto export failed: ") + error.localizedDescription)
    }
  }

  func chooseAutoExportDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.message = L("识别完成后自动导出到这个文件夹", "Export here automatically once OCR finishes")
    panel.prompt = L("选择", "Choose")
    if panel.runModal() == .OK { autoExportDirectory = panel.url }
  }

  func exportOne(_ job: DocumentJob) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    panel.nameFieldStringValue = job.title + ".md"
    panel.message = L("导出 Markdown", "Export Markdown")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try MarkdownExporter.write(
        job.markdown, to: url, assetsRoot: backend.jobsRoot,
        sourceDirectory: job.isMarkdown ? job.url.deletingLastPathComponent() : nil)
      job.exportedTo = url
      notify(L("已导出 ", "Exported ") + url.lastPathComponent)
    } catch {
      NSAlert(error: error).runModal()
    }
  }

  func exportAll() {
    let ready = jobs.filter(\.hasResult)
    guard !ready.isEmpty else { return }

    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.message = L("导出 \(ready.count) 份 Markdown 到",
                      "Export \(plural(ready.count, "Markdown file", "Markdown files")) to")
    panel.prompt = L("导出", "Export")
    guard panel.runModal() == .OK, let dir = panel.url else { return }

    for job in ready {
      do { try job.write(to: dir, assetsRoot: backend.jobsRoot) } catch {
        NSAlert(error: error).runModal()
        return
      }
    }
    NSWorkspace.shared.activateFileViewerSelecting(ready.compactMap(\.exportedTo))
  }

  func copyMarkdown(_ target: DocumentJob? = nil) {
    guard let job = target ?? readingDocument, job.hasResult else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    if pb.setString(job.markdown, forType: .string) { notify(L("已复制 Markdown", "Markdown copied")) }
  }

  // MARK: - 左右联动

  func pdfDidScroll(to page: Int) {
    guard page != currentPage else { return }
    currentPage = page
    guard syncScroll && canSyncReading else { return }
    renderBridge?("scrollToPage", [page])
  }

  func markdownDidScroll(to page: Int) {
    guard readingDocument?.isMarkdown != true else { return }
    guard page != currentPage else { return }
    currentPage = page
    guard syncScroll && canSyncReading else { return }
    pdfGoToPage?(page)
  }

  func goToPage(_ page: Int) {
    guard let job = readingSource else { return }
    let target = min(max(1, page), max(1, job.pageCount))
    currentPage = target
    pdfGoToPage?(target)
    if readingDocument?.isMarkdown != true { renderBridge?("scrollToPage", [target]) }
  }

  func runSearch() {
    renderBridge?("find", [searchQuery])
  }
}
