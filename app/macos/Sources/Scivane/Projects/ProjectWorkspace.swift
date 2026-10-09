import AppKit
import Foundation
import UniformTypeIdentifiers

/// Project actions; state lives in AppModel, this holds behaviour only.
/// 1. build a project: copy the source, guess a title, enter it; reuse existing OCR text
/// 2. recognition (local OCR or a model card) finishes inside a project: the result becomes the
///    paper text and refines the title
/// 3. the paper text changes only through those runs or Replace on the text chip; other Markdown
///    goes into files/ and is only shown
@MainActor
extension AppModel {

  // MARK: - Backend

  /// Projects don't need the OCR model, so the light mode is the default.
  /// - Parameter quiet: no error on failure. Used for the launch-time list, where someone without
  ///   the runtime would only be annoyed by a startup error.
  @discardableResult
  func awaitBackend(mode: BackendManager.Mode = .lite, quiet: Bool = false) async -> Bool {
    backend.ensureRunning(mode: mode)
    while !backend.state.isReady {
      if case .failed(let message) = backend.state {
        if !quiet { notifyProject(L("本地服务启动失败：", "The local service failed to start: ") + message.text) }
        return false
      }
      try? await Task.sleep(nanoseconds: 300_000_000)
      if Task.isCancelled { return false }
    }
    return true
  }

  func notifyProject(_ message: String) {
    notice = message
    noticeID = UUID()
  }

  // MARK: - List

  /// - Parameter quiet: true at launch; a failure just leaves the list empty.
  func refreshProjects(quiet: Bool = false) async {
    guard await awaitBackend(quiet: quiet) else { return }
    do {
      projects = try await projectClient.list()
    } catch {
      if !quiet { notifyProject(L("读取项目失败：", "Couldn't load projects: ") + error.localizedDescription) }
    }
  }

  // MARK: - Building

  /// Markdown can't: a project's identity is its source.
  func canBuildProject(_ job: DocumentJob) -> Bool {
    !job.isMarkdown && !job.status.isRunning && job.status != .queued
      && jobProjects[job.id] == nil
  }

  /// Build a project and enter it, without starting recognition. Existing OCR text is reused, never
  /// recomputed; otherwise it waits until the user starts OCR. Queueing it automatically made
  /// people who had already run OCR wait again.
  func buildProject(from job: DocumentJob) async {
    guard canBuildProject(job), !projectBusy else { return }
    projectBusy = true
    defer { projectBusy = false }

    guard await awaitBackend() else { return }
    // Read the result before remove(job): enterProject attaches the project's copy
    // (pdf/source.pdf), a different URL with no results.
    let scanned = job.hasResult ? job.markdown : ""
    do {
      let project = try await projectClient.create(sourcePath: job.url.path)
      await refreshProjects()
      // the document became a project; remove it from loose documents so it doesn't appear twice
      let alreadyHadContext = project.hasUsableContext
      remove(job)
      await enterProject(project)

      if !alreadyHadContext, !scanned.isEmpty {
        await adoptScannedText(project, markdown: scanned)
      } else {
        notifyProject(L("已构建项目「\(project.displayTitle)」", "Built the project “\(project.displayTitle)”"))
      }
    } catch {
      notifyProject(L("构建项目失败：", "Couldn't build the project: ") + error.localizedDescription)
    }
  }

  /// Use already recognised text as the project's context, through the same endpoint as a finished
  /// OCR (origin "ocr"), so figures are absorbed and the title refined. No job id needed: the
  /// backend finds figures from the `/assets/<job>/...` references in the text.
  private func adoptScannedText(_ project: Project, markdown: String) async {
    do {
      let updated = try await projectClient.setContext(
        project.id, markdown: markdown, origin: "ocr")
      await refreshProjects()
      if activeProjectID == updated.id { await enterProject(updated) }
      notifyProject(L("已构建项目「\(updated.displayTitle)」，沿用现成的识别结果", "Built “\(updated.displayTitle)” using the existing OCR result"))
    } catch {
      notifyProject(L("项目已建好，但沿用识别结果失败：", "The project was built, but reusing the OCR result failed: ") + error.localizedDescription)
    }
  }

  // MARK: - Empty projects

  /// An empty title is passed through as is (see ProjectClient.createEmpty).
  func createEmptyProject(title: String) async {
    guard !projectBusy else { return }
    projectBusy = true
    defer { projectBusy = false }

    guard await awaitBackend() else { return }
    do {
      let project = try await projectClient.createEmpty(
        title: title.trimmingCharacters(in: .whitespacesAndNewlines))
      await refreshProjects()
      await enterProject(project)
      notifyProject(L("已新建项目「\(project.displayTitle)」", "Created the project “\(project.displayTitle)”"))
    } catch {
      notifyProject(L("新建项目失败：", "Couldn't create the project: ") + error.localizedDescription)
    }
  }

  /// The backend refines the title afterwards, depending on how reliable it is.
  func attachSource(_ url: URL, to project: Project) async {
    guard !projectBusy else { return }
    projectBusy = true
    defer { projectBusy = false }

    guard await awaitBackend() else { return }
    do {
      let updated = try await projectClient.attachSource(project.id, path: url.path)
      await refreshProjects()
      if activeProjectID == updated.id { await enterProject(updated) }
      notifyProject(
        updated.title == project.title
          ? L("已导入原稿", "Original imported") : L("已导入原稿，项目改名为「\(updated.displayTitle)」", "Original imported; the project is now called “\(updated.displayTitle)”"))
    } catch {
      notifyProject(L("导入原稿失败：", "Couldn't import the original: ") + error.localizedDescription)
    }
  }

  func chooseSourceForProject(_ project: Project) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf, .image]
    panel.allowsMultipleSelection = false
    panel.message = L("选择「\(project.displayTitle)」的原稿", "Choose the original for “\(project.displayTitle)”")
    panel.prompt = L("导入", "Import")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await attachSource(url, to: project) }
  }

  // MARK: - Entering and leaving

  func projectSourceJob(_ project: Project) -> DocumentJob? {
    guard let url = project.sourceURL else { return nil }
    let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
    return jobs.first { $0.url == resolved }
  }

  /// Attach the source and text to the reading area, reusing the source-text pairing: a project is
  /// a persisted pairing.
  func enterProject(_ project: Project) async {
    guard await awaitBackend() else { return }
    activeProjectID = project.id
    annotations.load(project.hasSource ? project.id : nil)
    // Conversations load here rather than in the pane's .task, so the pane never binds to one that
    // doesn't exist yet.
    await refreshConversations(project.id)

    // An empty project is a deliberate blank page, not a missing source: go straight to the agent.
    guard project.hasSource else {
      // Nothing to attach, so the reading area is empty; the previous project's PDF would pass for this one's.
      selection = nil
      textMode = .chat
      singlePane = .text
      return
    }

    guard let sourceURL = project.sourceURL,
      let source = adopt(url: sourceURL, restoreCache: false)
    else {
      notifyProject(L("项目的原稿文件缺失", "The project's original file is missing"))
      return
    }
    jobProjects[source.id] = project.id
    pairProjectText(project, source: source)

    // dualPane is the user's preference and stays untouched
    select(source)
  }

  /// Put the project's text beside its source: the paper text, or the Markdown from files/ chosen in
  /// the text pane. Text an older version left unconfirmed isn't shown as the paper text.
  private func pairProjectText(_ project: Project, source: DocumentJob) {
    let chosen = projectDocument[project.id].map { project.directoryURL.appendingPathComponent($0) }
    let url = chosen.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
      ?? (project.hasUsableContext ? project.contextURL : nil)
    if chosen != nil, url != chosen { projectDocument.removeValue(forKey: project.id) }
    guard let url, let text = adopt(url: url) else {
      unpair(source: source)
      return
    }
    jobProjects[text.id] = project.id
    // the file may have just been replaced; disk is newer than the job's copy
    reloadMarkdown(text)
    pair(source: source, text: text)
  }

  /// What the text pane shows in this project: nil for the paper text, or a Markdown under files/.
  func showProjectText(_ relativePath: String?) {
    guard let project = activeProject else { return }
    if let relativePath {
      projectDocument[project.id] = relativePath
    } else {
      projectDocument.removeValue(forKey: project.id)
    }
    guard let source = projectSourceJob(project) else {
      // a project without a source has no pairing; show the file on its own
      let url = relativePath.map { project.directoryURL.appendingPathComponent($0) } ?? project.contextURL
      if let url, let job = adopt(url: url) {
        jobProjects[job.id] = project.id
        reloadMarkdown(job)
      } else {
        selection = nil
        replayIntoRenderer()
      }
      textMode = .document
      return
    }
    pairProjectText(project, source: source)
    textMode = .document
    if !dualPane { singlePane = .text }
    selection = source.id
    replayIntoRenderer()
  }

  /// Back to no open project: the librarian returns and the reading area is cleared, or it looks as
  /// if leaving didn't work.
  func leaveProject() {
    activeProjectID = nil
    selection = nil
    annotations.load(nil)
  }

  /// The project whose marks belong on this document: the open project, when this is its source.
  func annotatableProject(for job: DocumentJob) -> String? {
    guard let project = activeProject, project.hasSource, projectSourceJob(project)?.id == job.id
    else { return nil }
    return project.id
  }

  // MARK: - Writing OCR results back

  /// Without serverJobID figures can't be absorbed into the project, and the text keeps pointing at
  /// var/jobs, which `make clean` wipes.
  func attachOCRResult(_ job: DocumentJob, serverJobID: String?) async {
    guard let projectID = jobProjects[job.id],
      let project = projects.first(where: { $0.id == projectID })
    else { return }
    guard !job.markdown.isEmpty else { return }

    do {
      let updated = try await projectClient.setContext(
        project.id, markdown: job.markdown, origin: job.engine.provider == nil ? "ocr" : "model",
        jobID: serverJobID, model: job.engineModel.isEmpty ? nil : job.engineModel)
      // the fresh text is what the pane should show, not a file the user was reading meanwhile
      projectDocument.removeValue(forKey: updated.id)
      await refreshProjects()
      if activeProjectID == updated.id {
        await enterProject(updated)
      }
      if job.failedPages.isEmpty {
        notifyProject(L("已写入项目「\(updated.displayTitle)」", "Saved to the project “\(updated.displayTitle)”"))
      } else {
        let pages = job.failedPages.map(String.init).joined(separator: L("、", ", "))
        notifyProject(L("已写入项目；第 \(pages) 页没识别出来", "Saved; pages \(pages) couldn't be recognized"))
      }
    } catch {
      notifyProject(L("写入项目失败：", "Couldn't save to the project: ") + error.localizedDescription)
    }
  }

  /// Recognise the open project's source again: opens the engine chooser.
  func reOCRActiveProject() {
    guard let project = activeProject, let source = projectSourceJob(project) else { return }
    requestRecognition(source)
  }

  // MARK: - Markdown in files/

  /// Keep a Markdown file in the project's files/ (with its images) and show it in the text pane.
  /// The paper text is untouched.
  func viewMarkdownInProject(_ url: URL) async {
    guard let projectID = activeProjectID else { return }
    guard await awaitBackend() else { return }
    do {
      let added = try await projectClient.addFile(projectID, path: url.path)
      await refreshProjectFiles(projectID)
      guard activeProjectID == projectID else { return }
      showProjectText(added.path)
    } catch {
      notifyProject(L("「\(url.lastPathComponent)」没放进去：", "Couldn't add “\(url.lastPathComponent)”: ")
                    + error.localizedDescription)
    }
  }

  func chooseMarkdownToView() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = Self.markdownTypes
    panel.allowsMultipleSelection = false
    panel.message = L("放进项目的 files/ 并在正文栏查看", "Keep it in the project's files/ and show it in the text pane")
    panel.prompt = L("打开", "Open")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await viewMarkdownInProject(url) }
  }

  // MARK: - Replacing the paper text

  /// Make a Markdown file the paper text. Nothing is versioned, so replacing existing text asks
  /// first. `askFirst` is off only in checks that can't answer a dialog.
  func replaceProjectContext(with url: URL, askFirst: Bool = true) async {
    guard let project = activeProject, !projectBusy else { return }
    if askFirst, project.hasUsableContext {
      let alert = NSAlert()
      alert.messageText = L("用「\(url.lastPathComponent)」替换论文正文？", "Replace the paper text with “\(url.lastPathComponent)”?")
      alert.informativeText = L("现在的正文会被覆盖，不能撤销。", "The current text will be overwritten. This can't be undone.")
      alert.alertStyle = .warning
      alert.addButton(withTitle: L("替换", "Replace"))
      alert.addButton(withTitle: L("取消", "Cancel"))
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    projectBusy = true
    defer { projectBusy = false }
    guard await awaitBackend() else { return }
    do {
      let markdown = try String(contentsOf: url, encoding: .utf8)
      let updated = try await projectClient.setContext(
        project.id, markdown: markdown, origin: "upload",
        sourceDirectory: url.deletingLastPathComponent())
      projectDocument.removeValue(forKey: updated.id)
      await refreshProjects()
      if activeProjectID == updated.id { await enterProject(updated) }
      notifyProject(L("论文正文已换成「\(url.lastPathComponent)」", "The paper text is now “\(url.lastPathComponent)”"))
    } catch {
      notifyProject(L("替换失败：", "Couldn't replace the text: ") + error.localizedDescription)
    }
  }

  func chooseMarkdownToReplaceContext() {
    guard let project = activeProject else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = Self.markdownTypes
    panel.allowsMultipleSelection = false
    panel.message = L("选择一份 Markdown 作为「\(project.displayTitle)」的正文", "Choose a Markdown file as the text of “\(project.displayTitle)”")
    panel.prompt = L("替换", "Replace")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await replaceProjectContext(with: url) }
  }

  static let markdownTypes: [UTType] = [
    UTType(filenameExtension: "md") ?? .plainText,
    UTType(filenameExtension: "markdown") ?? .plainText,
  ]

  // MARK: - Rename and delete

  func renameProject(_ project: Project, to title: String) async {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    // The field is prefilled with the display name; saving it unchanged must not pin a placeholder
    // title as manual, or it would stop improving from OCR.
    guard !trimmed.isEmpty, trimmed != project.title, trimmed != project.displayTitle else { return }
    guard await awaitBackend() else { return }
    do {
      _ = try await projectClient.rename(project.id, to: trimmed)
      await refreshProjects()
    } catch {
      notifyProject(L("重命名失败：", "Couldn't rename: ") + error.localizedDescription)
    }
  }

  func deleteProject(_ project: Project) async {
    guard await awaitBackend() else { return }
    // the project holds conversation history; deleting is irreversible, so ask
    let alert = NSAlert()
    alert.messageText = L("删除项目「\(project.displayTitle)」？", "Delete the project “\(project.displayTitle)”?")
    alert.informativeText = L("项目里的原稿副本、正文与会话历史都会被删除，无法撤销。", "The copy of the original, its text and all chat history will be deleted. This can't be undone.")
    alert.alertStyle = .warning
    alert.addButton(withTitle: L("删除", "Delete"))
    alert.addButton(withTitle: L("取消", "Cancel"))
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    await removeProject(project)
  }

  /// The deletion itself, once confirmed.
  func removeProject(_ project: Project) async {
    do {
      try await projectClient.delete(project.id)
      if activeProjectID == project.id { leaveProject() }
      // Its documents (source, paper text, Markdown from files/) go with it. Only unlinked, they
      // would turn up among this session's loose documents, pointing at files no longer there.
      forget(Set(jobProjects.filter { $0.value == project.id }.map(\.key)))
      projectDocument.removeValue(forKey: project.id)
      await refreshProjects()
      notifyProject(L("已删除项目", "Project deleted"))
    } catch {
      notifyProject(L("删除失败：", "Couldn't delete: ") + error.localizedDescription)
    }
  }
}
