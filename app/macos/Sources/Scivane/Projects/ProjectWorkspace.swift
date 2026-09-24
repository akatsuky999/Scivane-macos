import AppKit
import Foundation
import UniformTypeIdentifiers

/// 项目相关的操作。状态属性在 AppModel 里，这里只放行为。
///
/// 三条流程决定了这一层的形状：
///
/// 1. **构建项目** → 复制原稿、快猜标题、进入项目；已经识别过就沿用现成的正文
/// 2. **项目内 OCR 完成** → 结果写回项目上下文，标题精确化
/// 3. **项目内导入 Markdown** → 落为待确认，由人点头后才作数
@MainActor
extension AppModel {

  // MARK: - 后端就绪

  /// 确保后端起到够用的层级。
  ///
  /// 项目管理不需要 OCR 模型，所以默认只起轻量模式（0.4 秒、58MB）。
  /// 为了列一下项目就加载 2.8GB 权重是说不过去的。
  /// - Parameter quiet: 失败时不打扰用户。
  ///   启动时那次拉取项目列表要用它 —— 没装运行时的人本来只想读 Markdown，
  ///   一开 App 就弹一条「启动失败」是纯粹的骚扰，让项目区空着就好。
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

  // MARK: - 列表

  /// - Parameter quiet: 启动时那次拉取用 true，失败就静静地空着。
  func refreshProjects(quiet: Bool = false) async {
    guard await awaitBackend(quiet: quiet) else { return }
    do {
      projects = try await projectClient.list()
    } catch {
      if !quiet { notifyProject(L("读取项目失败：", "Couldn't load projects: ") + error.localizedDescription) }
    }
  }

  // MARK: - 构建

  /// 这份文档能不能构建成项目。Markdown 不行 —— 项目的身份是原稿。
  func canBuildProject(_ job: DocumentJob) -> Bool {
    !job.isMarkdown && !job.status.isRunning && job.status != .queued
      && jobProjects[job.id] == nil
  }

  /// 构建项目并进入它。**不自动识别。**
  ///
  /// 「构建项目」与「开始 OCR」是两件独立的事：
  ///
  /// - 这篇**已经识别过**了 —— 直接沿用现成的正文，绝不重跑一遍。
  ///   重跑是纯粹的浪费：同一份原稿、同一个模型，结果只会一样，
  ///   而密集论文一页就要十几秒。
  /// - 这篇**还没识别** —— 建完就停在这里，用户想读的时候再点「开始 OCR」。
  ///
  /// 早先的版本在这里自动排队识别（理由是「点它就意味着我要认真读这篇」），
  /// 但那让两个功能纠缠在一起：先 OCR 再构建的人会被迫再等一遍。
  func buildProject(from job: DocumentJob) async {
    guard canBuildProject(job), !projectBusy else { return }
    projectBusy = true
    defer { projectBusy = false }

    guard await awaitBackend() else { return }
    // **必须在 remove(job) 之前把结果取出来。** 之后这个 job 就不在了，
    // 而 enterProject 挂进来的是项目里的副本（pdf/source.pdf）——
    // 那是另一个 URL，重新 adopt 出来的 job 一页结果都没有。
    let scanned = job.hasResult ? job.markdown : ""
    do {
      let project = try await projectClient.create(sourcePath: job.url.path)
      await refreshProjects()
      // 原文档已经"毕业"成项目，从本次文档里撤掉，避免同一篇论文出现两次
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

  /// 把手上已经识别好的正文直接作为项目上下文。
  ///
  /// 走的是和「识别完成写回」同一个接口（`origin: "ocr"`），所以插图会被一并
  /// 吸收进项目、标题也会用一级标题精确化。**不需要 jobID** ——
  /// 后端是从正文里的 `/assets/<job>/...` 引用去 jobs 根下找图的，
  /// jobID 只是记进元数据的一条出处。
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

  // MARK: - 空项目

  /// 新建一个还没有原稿的项目。
  ///
  /// **标题留空是有意义的**，原样交给后端：留空的项目叫「未命名项目」，
  /// 导入 PDF 时会被识别出来的标题改进；打了字的则受红线保护，
  /// 任何自动提取都不许覆盖。所以这里不替用户补一个默认名。
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

  /// 给一个空项目挂上原稿。挂完顺带把标题精确化（由后端按可靠度决定）。
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

  // MARK: - 进入与离开

  func projectSourceJob(_ project: Project) -> DocumentJob? {
    guard let url = project.sourceURL else { return nil }
    let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
    return jobs.first { $0.url == resolved }
  }

  /// 进入项目：把原稿与正文挂进阅读区。
  ///
  /// 复用既有的「原稿 ↔ 正文」配对机制 —— 项目本质上就是一份持久化的配对，
  /// 没必要为它另造一套阅读界面。
  func enterProject(_ project: Project) async {
    guard await awaitBackend() else { return }
    activeProjectID = project.id
    // 对话清单跟着项目走。放在这里而不是面板的 .task 里：切项目时清单必须
    // 先到位，否则面板会先绑到一条还不存在的对话上。
    await refreshConversations(project.id)

    // **空项目不是「原稿缺失」。** 它是用户有意建的一张白纸，
    // 报错会让人以为出了问题。直接落到 Agent 那栏 ——
    // 没有原稿也没有正文时，能做的事只在那里。
    guard project.hasSource else {
      // 没有文档可挂，阅读区就该是空的 —— 留着上一个项目的原稿在那里
      // 比空白更糟：用户会以为那就是这个项目的原稿。
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
      // 上下文可能刚被覆盖过，磁盘上的内容比 job 里缓存的新
      reloadMarkdown(text)
      pair(source: source, text: text)
    } else {
      unpair(source: source)
    }

    // **这里不碰 dualPane。** 它是用户偏好（工具栏那个开关），
    // 导航动作替他改掉的话，"栏数永远是你以为的那个"就不成立了。
    select(source)
  }

  /// 退出项目，回到「还没打开任何项目」那个状态：书房那层 agent 回来，阅读区清空。
  ///
  /// **阅读区必须一起清掉。** 只把 activeProjectID 置空的话，上一篇论文的原稿
  /// 还挂在那儿，用户会以为自己根本没退出去 —— 这和 `enterProject` 里
  /// 「留着上一个项目的原稿比空白更糟」是同一条判断。
  func leaveProject() {
    activeProjectID = nil
    selection = nil
  }

  // MARK: - OCR 结果回写

  /// OCR 完成后把结果写进项目上下文。
  ///
  /// `serverJobID` 是服务端的任务号，缺了它插图就吸收不进项目 ——
  /// 正文里的图会一直指着 var/jobs，`make clean` 一跑就全断。
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

  /// 重新 OCR 覆盖当前项目的上下文。
  func reOCRActiveProject() {
    guard let project = activeProject, let source = projectSourceJob(project) else { return }
    retry(source)
  }

  // MARK: - 导入 Markdown 覆盖

  /// 把一份 Markdown 作为项目上下文导入。
  ///
  /// 落地时是**待确认**状态：这份文件未必真是这篇论文的正文，
  /// 万一不是，模型会一本正经地基于错误材料作答，比没有上下文更糟。
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

  /// 人工确认这份正文是否对应本项目的论文。
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

  // MARK: - 重命名与删除

  func renameProject(_ project: Project, to title: String) async {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    // 改名框里预填的是显示名（占位名会按界面语言说）—— 原样点保存不算改名，
    // 否则一个「未命名」的占位项目会被悄悄钉成手动命名，之后再也不跟着识别改进。
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
    // 项目里有对话历史，删掉不可撤销 —— 必须问一次
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
