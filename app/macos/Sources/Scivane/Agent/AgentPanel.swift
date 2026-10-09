import SwiftUI

/// Resolves the current level's session (librarian outside a project, reader inside) and hands it
/// to the panel, which holds it as an @ObservedObject. The panel must observe the session itself:
/// its changes aren't AppModel changes, so passing only the model would never redraw a reply.
struct AgentPane: View {
  @ObservedObject var model: AppModel

  var body: some View {
    // The id must include the conversation: otherwise SwiftUI reuses the view and the composer stays
    // bound to the previous conversation's session.
    AgentPanel(
      model: model,
      session: model.session(
        for: model.activeProjectID, conversation: model.activeConversationID))
      .id(AppModel.sessionKey(model.activeProjectID, model.activeConversationID))
  }
}

struct AgentPanel: View {
  @ObservedObject var model: AppModel
  /// must be @ObservedObject; see AgentPane
  @ObservedObject var session: AgentSession
  @State private var draft = ""
  /// images going with the next question
  @State private var images: [ComposerImage] = []
  @State private var pasteMonitor = ImagePasteMonitor()
  @FocusState private var composing: Bool
  @State private var dropping = false

  /// 0 = grow with content. Stored as a preference so a tuned height survives relaunches.
  @AppStorage("agentComposerHeight") private var composerHeight: Double = 0
  /// height when the drag began; drags are relative
  @State private var dragBaseline: Double?

  private static let minComposerHeight: Double = 22    // one line
  private static let maxComposerHeight: Double = 340

  /// a taller box must actually show more lines
  private var lineCap: Int {
    composerHeight > 0 ? max(7, Int(composerHeight / 18)) : 7
  }

  private var isDesk: Bool { model.activeProject == nil }

  /// Must agree with the backend: context.assemble() refuses text an older version left
  /// unconfirmed, so that counts as no text here too.
  private enum ContextState {
    case ready(Project)
    case empty(Project)            // no usable text yet
    case desk
  }

  private var contextState: ContextState {
    guard let project = model.activeProject else { return .desk }
    return project.hasUsableContext ? .ready(project) : .empty(project)
  }

  /// The librarian needs no text, but both levels need a configured model.
  private var canAsk: Bool {
    guard !model.agentProvider.isEmpty else { return false }
    switch contextState {
    case .ready, .desk: return true
    case .empty: return false
    }
  }

  private var hasSomethingToSend: Bool {
    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      // the librarian has no conversations
      if !isDesk { ConversationBar(model: model) }
      if session.isEmpty {
        // Centre when there is room, scroll otherwise; a Spacer can't expand inside a ScrollView, hence
        // the minHeight.
        GeometryReader { geo in
          ScrollView {
            welcome.padding(.horizontal, 28).frame(minHeight: geo.size.height)
          }
        }
      } else {
        AgentTranscript(session: session) { approved, reason in
          session.answer(approved, reason: reason)
        }
      }
      composer(session)
    }
    .background(Palette.paper)
    // Warm up the math typesetter. Creating its WebView blocks the main thread for over 100 ms (first
    // time only) and loading takes a few tenths more; do it after the panel settles rather than when
    // the first `$` streams in.
    .task {
      try? await Task.sleep(for: .milliseconds(700))
      guard !Task.isCancelled else { return }
      MathRenderer.shared.prepare()
    }
    .task(id: AppModel.sessionKey(model.activeProjectID, model.activeConversationID)) {
      // restore history when the level or conversation changes (fetched once)
      model.restoreAgentHistory()
      await model.refreshProviders()
    }
    .task(id: model.activeProjectID) {
      guard let projectID = model.activeProjectID else { return }
      await model.refreshProjectFiles(projectID)
      await model.refreshProjectNotes(projectID)
    }
    // refetch on opening a conversation, switching cards or changing the window; during a turn it
    // comes from events (AgentSession)
    .task(id: contextKey) {
      await model.refreshAgentContext()
    }
    .onAppear { pasteMonitor.start { attach($0) } }
    .onDisappear { pasteMonitor.stop() }
    .onChange(of: composing) { _, focused in pasteMonitor.active = focused && !isDesk }
    .onChange(of: session.running) { _, running in
      // After each turn: the backend names a conversation after its first question, and the agent
      // may have written a note or edited the document on screen.
      guard !running, let projectID = model.activeProjectID else { return }
      Task {
        await model.refreshConversations(projectID)
        await model.refreshAfterAgentTurn(projectID)
      }
    }
  }

  private var contextKey: String {
    "\(AppModel.sessionKey(model.activeProjectID, model.activeConversationID))|"
      + "\(model.activeProviderID)|\(model.activeContextWindow ?? 0)"
  }

  // MARK: - Empty state

  private var welcome: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 24)
      VStack(spacing: 11) {
        Image(systemName: isDesk ? "books.vertical" : "sparkles")
          .font(.system(size: 26, weight: .ultraLight))
          .foregroundStyle(Palette.accent.opacity(0.8))
        Text(headline)
          .font(.system(size: 20, weight: .regular, design: .serif))
          .foregroundStyle(Palette.ink)
        Text(subhead)
          .font(.system(size: 12)).foregroundStyle(Palette.inkFaint)
          .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
      }
      if canAsk {
        VStack(spacing: 1) {
          ForEach(starters, id: \.self) { SuggestionRow(text: $0) { draft = $0; composing = true } }
        }
        .padding(.top, 24).frame(maxWidth: 340)
      } else if let action = recoveryAction {
        Button(action.title, action: action.run)
          .buttonStyle(StudioButtonStyle(primary: true)).padding(.top, 20)
      }
      Spacer(minLength: 24)
    }.frame(maxWidth: .infinity)
  }

  /// The librarian can't read any text, so its starters differ (matching its prompt). Starters
  /// follow the UI language, and the agent answers in the language it is asked in.
  private var starters: [String] {
    isDesk
      ? [L("我都有哪些论文", "What papers do I have?"),
         L("找一篇讲对比学习的", "Find one about contrastive learning"),
         L("这些项目里哪些还没有正文", "Which of these projects have no text yet?")]
      : [L("概括这篇论文的核心贡献", "Summarize this paper's core contributions"),
         L("把结果表格画成一张图", "Plot the results table as a chart"),
         L("找出实验里最有说服力的证据", "Find the most convincing evidence in the experiments")]
  }

  private var headline: String {
    if model.agentProvider.isEmpty { return L("还没有配置模型", "No model set up yet") }
    switch contextState {
    case .ready: return L("和这篇论文对话", "Chat with this paper")
    case .empty: return L("这个项目还没有正文", "This project has no text yet")
    case .desk: return L("书房", "Library")
    }
  }

  private var subhead: String {
    if model.agentProvider.isEmpty {
      return L("去设置（⌘,）里填一个模型的 API key，回来就能开始。",
               "Add a model's API key in Settings (⌘,), then come back to start.")
    }
    switch contextState {
    case .ready:
      return L("它能读正文、跑脚本、取论文代码 —— 全部落在这个项目目录里。",
               "It can read the text, run scripts and fetch the paper's code — all inside this project's folder.")
    case .empty:
      return L("识别原稿，或在下面的正文标签里换成一份 Markdown。",
               "Recognize the original, or use a Markdown file from the text chip below.")
    case .desk:
      return L("这一层只看得到项目清单 —— 标题、时间、状态。\n它读不到任何一篇论文的正文，也不能跑命令。",
               "This level sees only the project list — titles, dates and status.\n"
                 + "It can't read any paper's text or run commands.")
    }
  }

  private var recoveryAction: (title: String, run: () -> Void)? {
    if model.agentProvider.isEmpty {
      return (L("打开设置", "Open Settings"),
              { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) })
    }
    switch contextState {
    case .ready, .desk:
      return nil
    case .empty(let project):
      if project.hasSource {
        return (L("识别原稿…", "Recognize Original…"), { model.reOCRActiveProject() })
      }
      return (L("导入 PDF 作为原稿…", "Import a PDF as the Original…"),
              { model.chooseSourceForProject(project) })
    }
  }

  // MARK: - Composer
  //
  // Separated from the transcript by a floating card, not a divider: a shadow doesn't cut the
  // reading flow the way a line does.

  private func composer(_ session: AgentSession) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      contextRow(session)
      if !images.isEmpty { imageStrip }
      TextField(
        placeholder, text: $draft, axis: .vertical
      )
      .textFieldStyle(.plain).lineLimit(1...lineCap)
      .font(.system(size: 13)).foregroundStyle(Palette.ink)
      .focused($composing).disabled(!canAsk || session.running || session.preparing)
      .padding(.vertical, 2)
      .frame(
        minHeight: composerHeight > 0 ? composerHeight : nil,
        alignment: .topLeading)
      .onSubmit { send(session) }

      if !model.activeProjectFiles.isEmpty { attachments }

      HStack(spacing: 8) {
        if !isDesk {
          attachButton
        }
        ComposerStatusBar(
          model: model, usage: session.usage, context: isDesk ? nil : session.context,
          locked: session.running || session.preparing,
          onCompact: { model.compactAgentContext() })
        Spacer(minLength: 0)
        if canAsk && hasSomethingToSend && !session.running && !session.preparing {
          Text(L("⏎ 发送", "⏎ Send")).font(.system(size: 10)).foregroundStyle(Palette.inkFaint)
            .transition(.opacity)
        }
        sendButton(session)
      }
    }
    // Dropped images go with the next question; anything else goes into the project's files/.
    .dropDestination(for: URL.self) { urls, _ in
      guard !isDesk, !urls.isEmpty else { return false }
      receive(urls)
      return true
    } isTargeted: { dropping = $0 }
    .padding(14)
    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(alignment: .top) { resizeGrabber }
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(
          dropping
            ? Palette.accent
            : (composing ? Palette.accent.opacity(0.5) : Palette.rule.opacity(0.55)),
          lineWidth: dropping ? 1.8 : (composing ? 1.2 : 1))
    )
    .shadow(color: .black.opacity(composing ? 0.10 : 0.05), radius: composing ? 14 : 9, y: 3)
    .padding(.horizontal, 16).padding(.bottom, 16).padding(.top, 4)
    .animation(.easeOut(duration: 0.16), value: composing)
    .animation(.easeOut(duration: 0.16), value: draft.isEmpty)
    .animation(.easeOut(duration: 0.14), value: dropping)
  }

  /// Files already in files/, not a staging area: they were written when dropped, and a pending
  /// state would only raise the question whether they were uploaded.
  private var attachments: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(model.activeProjectFiles) { file in
          AttachmentChip(file: file) {
            Task { await model.removeProjectFile(file) }
          }
        }
      }
    }
    .frame(maxHeight: 26)
  }

  /// Two kinds of attachment: an image for this question, or material kept in the project.
  private var attachButton: some View {
    Menu {
      Button(L("图片…", "Images…")) { pickImages() }
        .disabled(model.activeVision == false)
      Button(L("放进项目材料…", "Add to Project Files…")) { model.chooseProjectFiles() }
    } label: {
      Image(systemName: "paperclip")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Palette.inkFaint)
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    .help(model.activeVision == false
          ? L("这张卡看不到图片；材料可以放进项目", "This card can't see images; files can go into the project")
          : L("图片随这条消息发送；材料放进项目，Markdown 进 notes/（都可以直接拖进来）",
              "Images go with this message; files go into the project, Markdown into notes/ (or drag them in)"))
    .accessibilityLabel(L("添加附件", "Attach"))
  }

  /// Images waiting to be sent; the cross shows on hover.
  private var imageStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(images) { image in
          PendingImage(image: image) { images.removeAll { $0.id == image.id } }
        }
      }
    }
    .frame(height: 46)
  }

  private func attach(_ incoming: [ComposerImage]) {
    guard !isDesk, !incoming.isEmpty else { return }
    if model.activeVision == false {
      model.notifyProject(L("这张卡看不到图片 —— 换一张能看图的卡再附图", "This card can't see images — switch to one that can"))
      return
    }
    let room = ComposerImage.perMessage - images.count
    images.append(contentsOf: incoming.prefix(max(0, room)))
    if incoming.count > room {
      model.notifyProject(L("一条消息最多 \(ComposerImage.perMessage) 张图", "At most \(ComposerImage.perMessage) images per message"))
    }
  }

  /// Dropped files: images become attachments (unless the card can't see them), the rest material.
  private func receive(_ urls: [URL]) {
    let pictures = urls.filter(ComposerImage.isImage)
    let others = urls.filter { !ComposerImage.isImage($0) }
    if !pictures.isEmpty {
      if model.activeVision == false {
        Task { await model.addProjectFiles(pictures) }
      } else {
        let prepared = pictures.compactMap(ComposerImage.prepare(url:))
        if prepared.count < pictures.count {
          model.notifyProject(L("有图片读不出来，没附上", "Some images couldn't be read and weren't attached"))
        }
        attach(prepared)
      }
    }
    if !others.isEmpty { Task { await model.addProjectFiles(others) } }
  }

  private func pickImages() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = true
    panel.message = L("选择随这条消息发送的图片", "Choose images to send with this message")
    panel.prompt = L("附上", "Attach")
    guard panel.runModal() == .OK else { return }
    receive(panel.urls)
  }

  private var placeholder: String {
    if model.agentProvider.isEmpty { return L("先在设置里配一个模型", "Set up a model in Settings first") }
    switch contextState {
    case .desk: return L("问问书房里都有什么…", "Ask what's in your library…")
    case .ready: return L("让它读、跑、画，或者直接提问…", "Have it read, run, plot — or just ask…")
    case .empty: return L("先备好正文，再开始提问", "Get the text ready before asking")
    }
  }

  private func send(_ session: AgentSession) {
    guard canAsk, !session.running, hasSomethingToSend else { return }
    let question = draft
    let attached = images
    draft = ""
    images = []
    model.askAgent(question, images: attached)
  }

  /// Nearly invisible until hovered. Double-click restores automatic height.
  private var resizeGrabber: some View {
    ResizeGrabber(
      isDragging: dragBaseline != nil,
      onChanged: { translation in
        let base = dragBaseline ?? max(Self.minComposerHeight, composerHeight)
        if dragBaseline == nil { dragBaseline = base }
        // dragging up is a negative translation; rounded to whole points, since sub-pixel heights
        // relayout the content above on every frame
        composerHeight = (min(
          Self.maxComposerHeight, max(Self.minComposerHeight, base - translation))).rounded()
      },
      onEnded: { dragBaseline = nil },
      onReset: { withAnimation(.easeOut(duration: 0.18)) { composerHeight = 0 } }
    )
  }

  /// While running, the same button stops; that is the only meaningful action there.
  private func sendButton(_ session: AgentSession) -> some View {
    let live = canAsk && hasSomethingToSend && !session.preparing
    return Button {
      if session.running { session.cancel() } else { send(session) }
    } label: {
      Image(systemName: session.running ? "stop.fill" : "arrow.up")
        .font(.system(size: session.running ? 10 : 12, weight: .bold))
        .foregroundStyle(session.running || live ? Palette.cream : Palette.inkFaint.opacity(0.55))
        .frame(width: 28, height: 28)
        .background(
          session.running ? Palette.danger : (live ? Palette.accent : Palette.inkFaint.opacity(0.12)),
          in: Circle())
    }
    .buttonStyle(.plain)
    // one cancel is enough; a button that stays live invites repeated clicks
    .disabled(session.cancelRequested || (!session.running && !live))
    .help(session.running
          ? (session.cancelRequested ? L("正在停下…", "Stopping…") : L("停下这一轮", "Stop this turn"))
          : L("发送（⏎）", "Send (⏎)"))
    .accessibilityLabel(session.running ? L("停止", "Stop") : L("发送", "Send"))
    .animation(.easeOut(duration: 0.16), value: session.running)
  }

  /// The title is truncated at the tail on its own chip; a middle-truncated combined string was
  /// unreadable.
  @ViewBuilder
  private func contextRow(_ session: AgentSession) -> some View {
    switch contextState {
    case .ready(let project):
      HStack(spacing: 7) {
        ContextChip(model: model, project: project, locked: session.running || session.preparing)
        if let context = project.context {
          Text(context.sizeLabel)
            .font(.system(size: 10).monospacedDigit()).foregroundStyle(Palette.inkFaint)
        }
        Spacer(minLength: 0)
        modelChip
      }
    case .empty(let project):
      HStack(spacing: 7) {
        ContextChip(model: model, project: project, locked: session.running || session.preparing)
        Text(L("尚无正文", "No text yet")).font(.system(size: 10, weight: .medium))
          .foregroundStyle(Palette.inkFaint)
        Spacer(minLength: 0)
        modelChip
      }
    case .desk:
      HStack(spacing: 7) {
        chip(icon: "books.vertical", title: L("书房 · 只见清单", "Library · list only"))
        Spacer(minLength: 0)
        modelChip
      }
    }
  }

  /// Clicking the model opens Settings to change it.
  @ViewBuilder
  private var modelChip: some View {
    if let provider = model.providers.first(where: { $0.id == model.agentProvider }) {
      Text(provider.model.isEmpty ? provider.label : provider.model)
        .font(.system(size: 9.5, design: .monospaced))
        .foregroundStyle(Palette.inkFaint)
        .lineLimit(1).truncationMode(.head)
        .help(L("当前模型：\(provider.label) · \(provider.model)", "Current model: \(provider.label) · \(provider.model)"))
    }
  }

  private func chip(icon: String, title: String) -> some View {
    HStack(spacing: 5) {
      Image(systemName: icon).font(.system(size: 9))
      Text(title).lineLimit(1).truncationMode(.tail)
    }
    .font(.system(size: 10)).foregroundStyle(Palette.inkSoft)
    .padding(.horizontal, 7).padding(.vertical, 3.5)
    .background(Palette.sunk, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .frame(maxWidth: 220, alignment: .leading)
    .help(title)
  }
}

/// A quiet row that lights up on hover, so the suggestions don't outweigh the composer.
private struct SuggestionRow: View {
  let text: String
  let pick: (String) -> Void
  @State private var hovering = false

  var body: some View {
    Button { pick(text) } label: {
      HStack(spacing: 8) {
        Text(text).font(.system(size: 12)).foregroundStyle(hovering ? Palette.ink : Palette.inkSoft)
        Spacer(minLength: 8)
        Image(systemName: "arrow.up.right")
          .font(.system(size: 9)).foregroundStyle(Palette.accent)
          .opacity(hovering ? 1 : 0)
      }
      .padding(.horizontal, 12).padding(.vertical, 9)
      .background(hovering ? Palette.sunk : .clear, in: RoundedRectangle(cornerRadius: 8))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.12), value: hovering)
  }
}


/// The paper text in the composer, and the one place to change it: recognise the original again,
/// or replace it with a Markdown file (a note from notes/, or any other).
private struct ContextChip: View {
  @ObservedObject var model: AppModel
  let project: Project
  /// while a turn runs: a new text would only reach the next turn
  let locked: Bool

  private var notes: [ProjectNote] { model.projectNotes[project.id] ?? [] }

  var body: some View {
    Menu {
      if project.hasSource {
        Button(project.hasUsableContext ? L("重新识别…", "Recognize Again…") : L("识别原稿…", "Recognize Original…")) {
          model.reOCRActiveProject()
        }
      }
      Menu(L("替换为 Markdown", "Replace with Markdown")) {
        ForEach(notes) { note in
          Button(note.folder.isEmpty ? note.title : "\(note.folder)/\(note.title)") {
            let url = project.directoryURL.appendingPathComponent(note.path)
            Task { await model.replaceProjectContext(with: url) }
          }
        }
        if !notes.isEmpty { Divider() }
        Button(L("其他文件…", "Other File…")) { model.chooseMarkdownToReplaceContext() }
      }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: "doc.text").font(.system(size: 9))
        Text(project.displayTitle).lineLimit(1).truncationMode(.tail)
        Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
      }
      .font(.system(size: 10)).foregroundStyle(Palette.inkSoft)
      .padding(.horizontal, 7).padding(.vertical, 3.5)
      .background(Palette.sunk, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .contentShape(Rectangle())
    }
    // A plain button-style menu draws the label as written. The native style keeps only the first
    // image and text, drops the background, and never truncates, so a long title runs over its neighbours.
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    .frame(maxWidth: 240, alignment: .leading)
    .fixedSize(horizontal: true, vertical: false)
    .disabled(locked || model.projectBusy)
    .help(help)
    .accessibilityIdentifier("context-chip")
  }

  private var help: String {
    guard let context = project.context, project.hasUsableContext else { return project.displayTitle }
    return "\(project.displayTitle)\n" + L("正文来自：\(context.originLabel)", "Text from: \(context.originLabel)")
  }
}

/// An image waiting in the composer.
private struct PendingImage: View {
  let image: ComposerImage
  let onRemove: () -> Void
  @State private var hovering = false

  var body: some View {
    Group {
      if let thumbnail = image.thumbnail {
        Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
      } else {
        Image(systemName: "photo").foregroundStyle(Palette.inkFaint)
      }
    }
    .frame(width: 56, height: 44)
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.ruleSoft))
    .overlay(alignment: .topTrailing) {
      if hovering {
        Button(action: onRemove) {
          Image(systemName: "xmark.circle.fill").font(.system(size: 12))
            .symbolRenderingMode(.palette)
            .foregroundStyle(Palette.cream, Palette.ink.opacity(0.7))
        }
        .buttonStyle(.plain).padding(2)
        .accessibilityLabel(L("移除这张图", "Remove this image"))
      }
    }
    .onHover { hovering = $0 }
    .help("\(image.width)×\(image.height)")
  }
}

/// Height handle on the composer's top edge.
///
/// The gesture uses global coordinates: the handle moves up as the composer grows, so in local
/// coordinates the same mouse position yields a growing translation, a feedback loop that made
/// the panel shake while dragging.
private struct ResizeGrabber: View {
  let isDragging: Bool
  let onChanged: (CGFloat) -> Void
  let onEnded: () -> Void
  let onReset: () -> Void

  @State private var hovering = false
  /// push and pop must pair up, or releasing outside the handle corrupts the cursor stack
  @State private var cursorPushed = false

  var body: some View {
    Capsule()
      .fill(Palette.inkFaint)
      .frame(width: 34, height: 3.5)
      .opacity(isDragging ? 0.7 : (hovering ? 0.42 : 0))
      .padding(.top, 5)
      // much larger hit area: a 3.5 pt bar can't be grabbed
      .frame(maxWidth: .infinity).frame(height: 16)
      .contentShape(Rectangle())
      .onHover { inside in
        hovering = inside
        syncCursor(active: inside || isDragging)
      }
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { onChanged($0.translation.height) }
          .onEnded { _ in onEnded() }
      )
      .onChange(of: isDragging) { _, dragging in
        // the handle itself moves, so the cursor may leave it mid-drag; keep the cursor until the drag ends
        syncCursor(active: dragging || hovering)
      }
      .onDisappear { syncCursor(active: false) }
      .onTapGesture(count: 2) { onReset() }
      .help(L("拖动调整高度，双击恢复自动", "Drag to resize; double-click to reset"))
      // Animate only properties that don't affect layout. The height changes every frame while
      // dragging; animating it would always trail the pointer.
      .animation(.easeOut(duration: 0.14), value: hovering)
      .animation(.easeOut(duration: 0.14), value: isDragging)
  }

  private func syncCursor(active: Bool) {
    guard active != cursorPushed else { return }
    if active { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
    cursorPushed = active
  }
}

/// Conversation switcher: current conversation, switch, new. The only chrome in the panel, kept to
/// one light row with the details in a menu.
struct ConversationBar: View {
  @ObservedObject var model: AppModel
  @State private var renaming = false
  @State private var draftTitle = ""

  private var current: Conversation? {
    guard let id = model.activeConversationID else { return nil }
    return model.activeConversations.first { $0.id == id }
  }

  /// Never creates one here: the backend does on the first question, otherwise opening the pane
  /// would leave an empty conversation on disk.
  private var currentTitle: String { current?.displayTitle ?? L("新对话", "New Chat") }

  var body: some View {
    HStack(spacing: 6) {
      Menu {
        conversationList
        Divider()
        actions
      } label: {
        HStack(spacing: 4) {
          Text(currentTitle).lineLimit(1).truncationMode(.tail)
          Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Palette.ink)
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      .help(L("切换对话", "Switch Chat"))

      if let count = countLabel {
        Text(count).font(.system(size: 10)).foregroundStyle(Palette.inkFaint)
      }
      Spacer(minLength: 8)
      Button {
        Task { await model.newConversation() }
      } label: {
        Image(systemName: "square.and.pencil").font(.system(size: 11))
      }
      .buttonStyle(.plain).foregroundStyle(Palette.inkSoft)
      .help(L("新对话", "New Chat")).accessibilityLabel(L("新对话", "New Chat"))
    }
    .padding(.horizontal, 14).padding(.vertical, 7)
    .overlay(alignment: .bottom) { Hairline() }
    .alert(L("重命名对话", "Rename Chat"), isPresented: $renaming) {
      TextField(L("标题", "Title"), text: $draftTitle)
      Button(L("保存", "Save")) {
        let title = draftTitle
        if let id = model.activeConversationID {
          Task { await model.renameConversation(id, to: title) }
        }
      }
      Button(L("取消", "Cancel"), role: .cancel) {}
    } message: {
      Text(L("默认用第一句提问当名字。", "By default it's named after the first question."))
    }
    .onChange(of: renaming) { _, active in
      if active { draftTitle = current?.title ?? "" }
    }
  }

  /// no count for a single conversation
  private var countLabel: String? {
    let total = model.activeConversations.count
    return total > 1 ? L("\(total) 条", "\(total) chats") : nil
  }

  @ViewBuilder private var conversationList: some View {
    if model.activeConversations.isEmpty {
      Text(L("还没有对话", "No chats yet"))
    } else {
      ForEach(model.activeConversations) { conversation in
        Button {
          model.selectConversation(conversation.id)
        } label: {
          // checkmark: the menu has no other way to say "you are here"
          Label(
            conversation.displayTitle,
            systemImage: conversation.id == model.activeConversationID ? "checkmark" : "")
        }
      }
    }
  }

  @ViewBuilder private var actions: some View {
    Button(L("新对话", "New Chat")) { Task { await model.newConversation() } }
    if let id = model.activeConversationID {
      Button(L("重命名…", "Rename…")) { renaming = true }
      Button(L("导出为 JSON…", "Export as JSON…")) { Task { await model.exportConversation(id) } }
      Divider()
      Button(L("删除这条对话…", "Delete This Chat…"), role: .destructive) {
        Task { await model.deleteConversation(id) }
      }
    }
  }
}

// MARK: - Usage

/// Totals for this turn: tokens in, out, and cached. This is cost; window occupancy is ContextMeter.
/// Cache hits are shown as a ratio, which is the conclusion people want; amounts are compact
/// (56.4K) since they are only for scale.
struct UsageMeter: View {
  let usage: AgentUsage

  /// everything sent to the model this turn, cached part included
  private var consumed: Int { usage.input + usage.cacheRead }

  /// 56400 -> 56.4K, 1200000 -> 1.2M
  static func compact(_ value: Int) -> String {
    if value >= 1_000_000 {
      let millions = Double(value) / 1_000_000
      return millions >= 10
        ? "\(Int(millions.rounded()))M" : String(format: "%.1fM", millions)
    }
    if value >= 1_000 {
      let thousands = Double(value) / 1_000
      return thousands >= 10
        ? "\(Int(thousands.rounded()))K" : String(format: "%.1fK", thousands)
    }
    return "\(value)"
  }

  /// cached share of all input tokens
  private var cacheHit: Int? {
    guard consumed > 0, usage.cacheRead > 0 else { return nil }
    return Int((Double(usage.cacheRead) / Double(consumed) * 100).rounded())
  }

  var body: some View {
    if !usage.isEmpty {
      HStack(spacing: 6) {
        flow("arrow.down", Self.compact(consumed))
        flow("arrow.up", Self.compact(usage.output))
        if let cacheHit {
          Text(L("缓存 \(cacheHit)%", "Cache \(cacheHit)%"))
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Palette.accent.opacity(0.12), in: Capsule())
            .help(L("送进去的 \(consumed.formatted()) token 里有 \(usage.cacheRead.formatted()) 命中了 prompt 缓存",
                    "\(usage.cacheRead.formatted()) of the \(consumed.formatted()) tokens sent hit the prompt cache"))
        }
      }
      .animation(.easeOut(duration: 0.25), value: consumed)
      .animation(.easeOut(duration: 0.25), value: usage.output)
    }
  }

  private func flow(_ symbol: String, _ text: String) -> some View {
    HStack(spacing: 2) {
      Image(systemName: symbol).font(.system(size: 7, weight: .bold))
      Text(text).font(.system(size: 9.5, design: .monospaced)).monospacedDigit()
    }
    .foregroundStyle(Palette.inkFaint)
  }
}

/// The remove button only shows on hover, so the row reads as contents rather than a to-do list.
struct AttachmentChip: View {
  let file: ProjectFile
  let onRemove: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: Self.icon(for: file.name))
        .font(.system(size: 9)).foregroundStyle(Palette.accent)
      Text(file.name)
        .font(.system(size: 10.5)).foregroundStyle(Palette.ink)
        .lineLimit(1).truncationMode(.middle)
        // cap the text, not the chip, or short names get stretched to the full width
        .frame(maxWidth: 130)
        .fixedSize(horizontal: true, vertical: false)
      if hovering {
        Button(action: onRemove) {
          Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
            .foregroundStyle(Palette.inkFaint)
        }
        .buttonStyle(.plain).accessibilityLabel(L("从项目里移除 \(file.name)", "Remove \(file.name) from the project"))
      } else {
        Text(file.sizeLabel)
          .font(.system(size: 9)).foregroundStyle(Palette.inkFaint)
      }
    }
    .padding(.horizontal, 7).padding(.vertical, 3.5)
    .background(Palette.ruleSoft, in: Capsule())
    .onHover { hovering = $0 }
    .help("\(file.path) · \(file.sizeLabel)")
    .animation(.easeOut(duration: 0.12), value: hovering)
  }

  /// unknown types get a plain page
  static func icon(for name: String) -> String {
    switch (name as NSString).pathExtension.lowercased() {
    case "pdf": return "doc.richtext"
    case "csv", "tsv", "xlsx": return "tablecells"
    case "png", "jpg", "jpeg", "gif", "heic": return "photo"
    case "py", "json", "yaml", "yml", "toml": return "chevron.left.forwardslash.chevron.right"
    case "md", "txt": return "doc.text"
    case "zip", "tar", "gz": return "shippingbox"
    default: return "doc"
    }
  }
}
