import AppKit
import Foundation
import UniformTypeIdentifiers

/// Project actions; state lives in AppModel, this holds behaviour only.
/// 1. build a project: copy the source, guess a title, enter it; reuse existing OCR text
/// 2. OCR finishes inside a project: the result becomes its context and refines the title
/// 3. Markdown imported into a project: pending until a person confirms it
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

    if let contextURL = project.contextURL, let text = adopt(url: contextURL) {
      jobProjects[text.id] = project.id
      // the context may have just been replaced; disk is newer than the job's copy
      reloadMarkdown(text)
      pair(source: source, text: text)
    } else {
      unpair(source: source)
    }

    // dualPane is the user's preference and stays untouched
    select(source)
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
        project.id, markdown: job.markdown, origin: "ocr", jobID: serverJobID)
      await refreshProjects()
      if activeProjectID == updated.id {
        await enterProject(updated)
      }
      notifyProject(L("已写入项目「\(updated.displayTitle)」", "Saved to the project “\(updated.displayTitle)”"))
    } catch {
      notifyProject(L("写入项目失败：", "Couldn't save to the project: ") + error.localizedDescription)
    }
  }

  func reOCRActiveProject() {
    guard let project = activeProject, let source = projectSourceJob(project) else { return }
    retry(source)
  }

  // MARK: - Importing Markdown

  /// Lands as pending confirmation: the file may not be this paper, and wrong context is worse than
  /// none.
  func importMarkdownIntoProject(_ url: URL, project: Project) async {
    guard !projectBusy else { return }
    projectBusy = true
    defer { projectBusy = false }

    guard await awaitBackend() else { return }
    do {
      let markdown = try String(contentsOf: url, encoding: .utf8)
      let updated = try await projectClient.setContext(
        project.id, markdown: markdown, origin: "upload",
        sourceDirectory: url.deletingLastPathComponent())
      await refreshProjects()
      if activeProjectID == updated.id { await enterProject(updated) }
    } catch {
      notifyProject(L("导入失败：", "Import failed: ") + error.localizedDescription)
    }
  }

  func chooseMarkdownForProject(_ project: Project) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [
      UTType(filenameExtension: "md") ?? .plainText,
      UTType(filenameExtension: "markdown") ?? .plainText,
    ]
    panel.allowsMultipleSelection = false
    panel.message = L("选择一份 Markdown 作为「\(project.displayTitle)」的正文", "Choose a Markdown file as the text of “\(project.displayTitle)”")
    panel.prompt = L("使用", "Use")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await importMarkdownIntoProject(url, project: project) }
  }

  /// Whether a person accepts the text as this paper's.
  func confirmProjectContext(_ accepted: Bool) async {
    guard let project = activeProject else { return }
    guard await awaitBackend() else { return }
    do {
      let updated = try await projectClient.confirmContext(project.id, accepted: accepted)
      await refreshProjects()
      await enterProject(updated)
      notifyProject(accepted ? L("已确认为本篇正文", "Confirmed as this paper's text") : L("已撤销这份正文", "This text was withdrawn"))
    } catch {
      notifyProject(L("操作失败：", "That didn't work: ") + error.localizedDescription)
    }
  }

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

    do {
      try await projectClient.delete(project.id)
      if activeProjectID == project.id { leaveProject() }
      jobProjects = jobProjects.filter { $0.value != project.id }
      await refreshProjects()
      notifyProject(L("已删除项目", "Project deleted"))
    } catch {
      notifyProject(L("删除失败：", "Couldn't delete: ") + error.localizedDescription)
    }
  }
}
