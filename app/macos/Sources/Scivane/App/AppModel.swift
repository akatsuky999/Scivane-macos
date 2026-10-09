import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {

  enum Mode: String, CaseIterable, Identifiable {
    case convert
    case read

    var id: String { rawValue }
    var label: String { self == .convert ? L("转换", "Convert") : L("阅读", "Read") }
    var symbol: String { self == .convert ? "square.stack.3d.down.right" : "book.pages" }
  }

  enum ReadingPane: String, CaseIterable { case source, text }

  /// Held here rather than in ReaderView: the control that drives it sits in the global toolbar.
  enum TextMode: String, CaseIterable {
    case document, chat
    var label: String { self == .document ? L("正文", "Text") : "Agent" }
    var symbol: String { self == .document ? "text.alignleft" : "sparkles" }
  }

  @Published var textMode: TextMode = .document

  /// Single pane: source / text / agent. Dual pane: the right pane switches between text and agent.
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
  /// User preference, changed only by the toolbar switch. Navigation never overrides it, and it is
  /// read back at launch.
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

  /// Reading is the only mode in the UI. Batch conversion and side-by-side reading were taken out of
  /// the UI; the enum and ConvertView stay so they can be wired back in.
  @Published var mode: Mode = .read
  @Published private(set) var jobs: [DocumentJob] = [] {
    didSet { observeJobs() }
  }

  // MARK: - Projects
  //
  // Stored by the backend; this holds view state only.

  @Published var projects: [Project] = []
  @Published var activeProjectID: Project.ID?
  /// project id -> Markdown file under files/ shown in the text pane; absent means the paper text.
  /// Viewing never changes what the model reads.
  @Published var projectDocument: [String: String] = [:]
  /// non-nil: the engine chooser is up for that document
  @Published var recognitionRequest: RecognitionRequest?
  @Published var projectBusy = false
  @Published var sidebarNavigationBusy = false
  /// A project job's OCR result becomes that project's context.
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

  @Published var currentPage = 1
  @Published var syncScroll = true
  /// Off by default: it doesn't replace scrolling and permanently takes a column.
  @Published var showThumbnails = false
  @Published var isSearching = false
  @Published var searchQuery = ""
  @Published var searchHits = 0

  @Published var autoExportDirectory: URL? {
    didSet {
      UserDefaults.standard.set(autoExportDirectory?.path, forKey: "autoExportDirectory")
    }
  }

  /// set by MarkdownWebView
  var renderBridge: ((String, [Any]) -> Void)?
  /// set by PDFReaderView
  var pdfGoToPage: ((Int) -> Void)?

  // MARK: - Agent
  //
  // One session per level: the librarian, and one per project. Opening a project is a new agent
  // instance, not a context switch.

  /// Deliberately not @Published: sessions are created on demand from `body`, and publishing that
  /// write would mutate state during a view update. Views observe the session objects directly
  /// (AgentPane).
  private var agentSessions: [String: AgentSession] = [:]
  /// metadata only, never credentials
  @Published var providers: [ProviderSummary] = []
  /// Set to true only by ScivaneApp. Side effects such as writing providers.json or starting the
  /// backend must not happen just because a check built an AppModel.
  var isLiveApp = false

  @Published var agentProvider: String = UserDefaults.standard.string(forKey: "agentProvider") ?? "" {
    didSet { UserDefaults.standard.set(agentProvider, forKey: "agentProvider") }
  }
  /// Providers whose credential was injected; redone after the backend restarts.
  var injectedProviders: Set<String> = []
  /// Backend generation at the last injection; a mismatch means it restarted.
  var injectedGeneration: UUID?

  /// Published, unlike agentSessions: the conversation list drives the switcher. Changes inside a
  /// session are observed by the views themselves.
  @Published var conversations: [String: [Conversation]] = [:]

  /// project id -> conversation id
  @Published var activeConversation: [String: String] = [:]

  /// project id -> files in its files/
  @Published var projectFiles: [String: [ProjectFile]] = [:]

  var activeProjectFiles: [ProjectFile] {
    guard let activeProjectID else { return [] }
    return projectFiles[activeProjectID] ?? []
  }

  /// The current level's session; the librarian outside a project.
  var agentSession: AgentSession {
    session(for: activeProjectID, conversation: activeConversationID)
  }

  /// nil outside a project or before the list has loaded
  var activeConversationID: String? {
    guard let activeProjectID else { return nil }
    return activeConversation[activeProjectID]
  }

  var activeConversations: [Conversation] {
    guard let activeProjectID else { return [] }
    return conversations[activeProjectID] ?? []
  }

  /// Get or create a session without publishing anything (see agentSessions).
  ///
  /// The key includes the conversation: switching conversations switches instances, so a running
  /// turn can't write into another conversation's view.
  func session(for projectID: String?, conversation: String? = nil) -> AgentSession {
    let key = Self.sessionKey(projectID, conversation)
    if let existing = agentSessions[key] { return existing }
    let session = AgentSession(projectID: projectID, conversationID: conversation)
    agentSessions[key] = session
    return session
  }

  /// The librarian has no conversations, so it has a single key.
  static func sessionKey(_ projectID: String?, _ conversation: String?) -> String {
    guard let projectID else { return deskKey }
    return conversation.map { "\(projectID)/\($0)" } ?? projectID
  }

  /// Call after deleting a conversation, or a reused id would get a stale transcript.
  func forgetSession(projectID: String, conversation: String) {
    agentSessions.removeValue(forKey: Self.sessionKey(projectID, conversation))
  }

  static let deskKey = "__desk__"

  let backend: BackendManager
  /// cards observe it directly
  let ocrInstaller: OCRInstaller
  /// The open project's marks; the PDF view observes it directly.
  let annotations: AnnotationStore
  /// held back because local OCR was missing; they resume once it is installed
  private var awaitingOCR: [DocumentJob.ID] = []
  private var runner: Task<Void, Never>?
  private var runGeneration = UUID()
  private var activeJobID: String?
  /// must be retained: releasing it tears down its URLSession and ends the stream
  private var client: OCRClient?

  init(backend: BackendManager) {
    self.backend = backend
    self.ocrInstaller = OCRInstaller(backend: backend)
    self.annotations = AnnotationStore(service: { ProjectClient(base: backend.apiBase) })
    // don't auto-stop the backend while work is running
    backend.isBusy = { [weak self] in self?.hasBackendWork ?? false }
    ocrInstaller.onInstalled = { [weak self] in self?.resumeAfterOCRInstall() }
    annotations.ready = { [weak self] in await self?.awaitBackend(quiet: true) ?? false }
    annotations.onError = { [weak self] in self?.notifyProject($0) }
    if let p = UserDefaults.standard.string(forKey: "autoExportDirectory") {
      autoExportDirectory = URL(fileURLWithPath: p)
    }
  }

  // MARK: - Selection

  var selected: DocumentJob? {
    if let selection, let job = jobs.first(where: { $0.id == selection }) { return job }
    return fallbackJob
  }

  /// Not simply jobs.first: a project's documents are in `jobs` too, so the paper just left would
  /// come back. Inside a project only its files count; outside, only loose documents.
  private var fallbackJob: DocumentJob? {
    if let activeProjectID { return jobs.first { jobProjects[$0.id] == activeProjectID } }
    return jobs.first { jobProjects[$0.id] == nil }
  }

  var hasJobs: Bool { !jobs.isEmpty }
  var isBusy: Bool { jobs.contains { $0.status.isRunning || $0.status == .queued } }

  // Conversations and pending approvals count too; looking only at OCR would stop the backend under
  // a working agent after five minutes.
  var hasBackendWork: Bool {
    isBusy || ocrInstaller.isRunning || annotations.hasPendingWrites
      || agentSessions.values.contains { $0.running || $0.preparing }
  }

  var finishedCount: Int { jobs.filter(\.status.isFinished).count }

  // MARK: - Queue

  func add(urls: [URL], to pane: ReadingPane? = nil) {
    // Markdown dropped into a project is kept in its files/ and shown in the text pane. It never
    // becomes the paper text this way; that takes Replace on the text chip in the chat.
    if activeProject != nil, pane != .source {
      let markdown = urls.first {
        ["md", "markdown"].contains($0.pathExtension.lowercased())
      }
      if let markdown {
        Task { await viewMarkdownInProject(markdown) }
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

  /// Shared with projects, so opening a project and importing by hand follow the same rules.
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

  func pair(source: DocumentJob, text: DocumentJob) {
    comparisons = comparisons.filter { $0.value != text.id }
    comparisons[source.id] = text.id
  }

  func unpair(source: DocumentJob) {
    comparisons.removeValue(forKey: source.id)
  }

  /// The sidebar's Import. One panel for every supported type, like drag and drop.
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

  /// If the light backend can't answer (not running, or too old for this endpoint), take the normal
  /// path, which reports the real reason. This only catches "definitely not installed".
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

  /// Open the engine chooser for a document: first recognition or a re-run.
  func requestRecognition(_ job: DocumentJob) {
    guard !job.isMarkdown, !job.status.isRunning, job.status != .queued else { return }
    recognitionRequest = RecognitionRequest(job: job.id)
  }

  /// Queue a recognition with the chosen engine. Earlier results are cleared: the run replaces them.
  func startRecognition(_ job: DocumentJob, engine: RecognitionEngine) {
    guard !job.isMarkdown, !job.status.isRunning, job.status != .queued else { return }
    job.engine = engine
    job.engineModel = engine.provider.flatMap { id in providers.first { $0.id == id }?.model } ?? ""
    if job.hasResult {
      job.pages = [:]
      job.consolidated = ""
      job.plainText = ""
      job.exportedTo = nil
      if job.id == readingDocument?.id { replayIntoRenderer() }
    }
    job.elapsed = 0
    job.activePage = 0
    job.usage = nil
    job.failedPages = []
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

  /// The WebView is created lazily and pages arriving before it are lost, so replay once it exists.
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

  // MARK: - Run queue
  //
  // One document at a time: llama-server is a single serial instance, so concurrency would only
  // delay the first result.

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
    let generation = runGeneration
    let provider = job.engine.provider
    if provider == nil {
      // Local OCR is optional: ask the light backend before upgrading. Upgrading stops the light
      // backend, and a full backend that can't start would take recognition and the project list
      // down with it, behind an unrelated error.
      if backend.runningMode != .full, !(await ocrAvailable()) {
        for pending in jobs where pending.id == job.id
          || (pending.status == .queued && pending.engine == .local)
        {
          pending.status = .ready
          if !awaitingOCR.contains(pending.id) { awaitingOCR.append(pending.id) }
        }
        return
      }
    }
    // It may have been stopped after idling; make sure it is up. A model card needs no OCR engine,
    // so the light backend is enough.
    backend.ensureRunning(mode: provider == nil ? .full : .lite)
    while !backend.state.isReady {
      if case .failed(let message) = backend.state {
        job.status = .failed(message)
        return
      }
      try? await Task.sleep(nanoseconds: 800_000_000)
      if Task.isCancelled { return }
    }
    if provider != nil { await injectCredentials() }

    guard generation == runGeneration, !Task.isCancelled else { return }
    job.status = .running(done: 0, total: job.pageCount)
    job.activePage = 0
    let client = OCRClient(base: backend.apiBase)
    self.client = client
    let stream = provider.map { client.transcribe(path: job.url.path, provider: $0) }
      ?? client.recognise(path: job.url.path)

    do {
      for try await event in stream {
        guard generation == runGeneration else { return }
        if Task.isCancelled {
          job.status = .cancelled
          return
        }
        backend.noteActivity()  // postpone the idle stop
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

        case .page(let index, let total, let markdown, let elapsed, let usage):
          // first page is back: a fresh install's first load is over
          if provider == nil { ocrInstaller.freshlyInstalled = false }
          job.pages[index] = markdown
          job.elapsed = elapsed
          if let usage { job.usage = usage }
          job.status = .running(done: job.pages.count, total: max(total, job.pageCount))
          if job.id == readingDocument?.id && mode == .read {
            renderBridge?("setPage", [index, markdown])
          }

        case .done(let markdown, let text, let elapsed, let cancelled, let failedPages, let usage):
          job.elapsed = elapsed
          job.consolidated = markdown
          job.plainText = text
          job.failedPages = failedPages
          if let usage { job.usage = usage }
          job.status = cancelled ? .cancelled : .finished(seconds: elapsed)
          if !cancelled {
            ResultCache.save(job, root: backend.varRoot)
            autoExport(job)
            // A project job's result becomes its context. Keep serverJobID: figures can only be absorbed into
            // the project with it.
            if jobProjects[job.id] != nil {
              let serverJobID = activeJobID
              Task { await attachOCRResult(job, serverJobID: serverJobID) }
            }
          }

        case .failed(let message, let code):
          // stable codes are phrased here; anything else is the backend's own wording
          job.status = .failed(ModelFailure.describe(code: code, message: message))
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

  /// Stops only this document; the queue keeps going.
  func cancelCurrent() {
    if let id = activeJobID {
      let client = OCRClient(base: backend.apiBase)
      Task { await client.cancel(jobID: id) }
    }
  }

  /// Run again with the same engine (the progress bar's Retry).
  func retry(_ job: DocumentJob) {
    startRecognition(job, engine: job.engine)
  }

  // MARK: - Export

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

  // MARK: - Scroll sync

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
