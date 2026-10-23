import SwiftUI

/// Resolves the current level's session (librarian outside a project, reader inside) and hands it
/// to the panel, which holds it as an @ObservedObject. The panel must observe the session itself:
/// its changes aren't AppModel changes, so passing only the model would never redraw a reply.
struct AgentPane: View {
  @ObservedObject var model: AppModel
  /// The conversation shown, fixed for the pane's life: the reader gives another conversation another
  /// pane, so a hidden one doesn't rebuild itself when the selection moves on.
  let projectID: String?
  let conversationID: String?

  init(model: AppModel, projectID: String?, conversationID: String?) {
    self.model = model
    self.projectID = projectID
    self.conversationID = conversationID
  }

  /// The current level's conversation.
  init(model: AppModel) {
    self.init(model: model, projectID: model.activeProjectID, conversationID: model.activeConversationID)
  }

  var body: some View {
    // The id must include the conversation: otherwise SwiftUI reuses the view and the composer stays
    // bound to the previous conversation's session.
    AgentPanel(model: model, session: model.session(for: projectID, conversation: conversationID))
      .id(AppModel.sessionKey(projectID, conversationID))
  }
}

/// The current conversation's loading and after-turn refresh, apart from the panel and present for as
/// long as the reader is. The panel is built when first shown and leaves the window while hidden; tied
/// to it, this would wait for the first show, run again on every show, and miss a turn that ends while
/// the text is on screen (a note the agent wrote, the document it edited, the name of a new conversation).
struct AgentUpkeep: View {
  @ObservedObject var model: AppModel

  var body: some View {
    // keyed like the panel, so the after-turn refresh follows the conversation in view
    Keyed(model: model, session: model.agentSession)
      .id(AppModel.sessionKey(model.activeProjectID, model.activeConversationID))
      // Warm up the math typesetter. Creating its WebView blocks the main thread for over 100 ms (first
      // time only) and loading takes a few tenths more; do it once the reader settles rather than when
      // the first `$` streams in.
      .task {
        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled else { return }
        MathRenderer.shared.prepare()
      }
  }

  private struct Keyed: View {
    @ObservedObject var model: AppModel
    /// observed for `running`; its changes aren't AppModel changes
    @ObservedObject var session: AgentSession

    var body: some View {
      Color.clear
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
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
  /// what to select in the composer once a starter's text is in it
  @State private var composerSelection: FocusedTextSelection.Request?
  @State private var dropping = false
  @State private var composerFootprint: CGFloat = 142
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
      // the conversations are switched from the toolbar island (ConversationSwitcher)
      ZStack(alignment: .bottom) {
        if session.isEmpty {
          GeometryReader { geo in
            ScrollView {
              welcome.padding(.horizontal, 28)
                .frame(minHeight: max(0, geo.size.height - composerFootprint))
                .padding(.bottom, composerFootprint)
            }
          }
        } else {
          TranscriptPane(session: session, edit: model.resend).equatable()
            .environment(\.composerInset, composerFootprint)
        }
        composer(session)
          .background {
            GeometryReader { geometry in
              Color.clear.preference(key: ComposerFootprint.self, value: geometry.size.height.rounded())
            }
          }
      }
      .onPreferenceChange(ComposerFootprint.self) { height in
        if height > 0, composerFootprint != height { composerFootprint = height }
      }
    }
    .background(Palette.paper)
    // loading and the after-turn refresh are AgentUpkeep's: this panel may be off screen
    .onAppear { pasteMonitor.start { attach($0) } }
    .onDisappear { pasteMonitor.stop() }
    .onChange(of: composing) { _, focused in pasteMonitor.active = focused && !isDesk }
  }

  // MARK: - Empty state

  private var welcome: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 24)
      if canAsk, case .ready(let project) = contextState {
        // the paper is the headline; nothing here explains the agent
        PaperWelcome(project: project, use: use)
      } else {
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
          StarterLedger(starters: Starter.library, use: use).padding(.top, 24).frame(maxWidth: 380)
        } else if let action = recoveryAction {
          Button(action.title, action: action.run)
            .buttonStyle(StudioButtonStyle(primary: true)).padding(.top, 20)
        }
      }
      Spacer(minLength: 24)
    }.frame(maxWidth: .infinity)
  }

  /// A starter only fills the composer: the user reads it, changes it, and sends it. Its blank (the
  /// language to translate into) comes selected, to be typed over; otherwise the caret goes to the end,
  /// since a field taking focus selects all its text.
  private func use(_ starter: Starter) {
    draft = starter.prompt
    composing = true
    composerSelection = .selecting(starter.blank, in: starter.prompt)
  }

  /// Shown when there's nothing to ask yet, or in the librarian. A ready paper is its own headline
  /// (PaperWelcome).
  private var headline: String {
    if model.agentProvider.isEmpty { return L("还没有配置模型", "No model set up yet") }
    switch contextState {
    case .ready: return ""
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
      return ""
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
  // The tray overlays the scroll view so the glass can sample the conversation beneath it.

  private func composer(_ session: AgentSession) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if !images.isEmpty { imageStrip }
      TextField(
        placeholder, text: $draft,
        prompt: Text(placeholder).foregroundColor(Palette.inkFaint), axis: .vertical
      )
      .textFieldStyle(.plain).lineLimit(1...lineCap)
      .font(.system(size: 14)).foregroundStyle(Palette.ink)
      .focused($composing).disabled(!canAsk || session.locked)
      .padding(.horizontal, 2).padding(.top, 2)
      .frame(
        minHeight: max(26, composerHeight),
        alignment: .topLeading)
      .onSubmit { send(session) }
      .background(FocusedTextSelection(request: composerSelection))
      .accessibilityIdentifier("agent-composer-input")

      if !model.activeProjectFiles.isEmpty { attachments }

      composerFooter(session)
    }
    // Dropped images go with the next question; anything else goes into the project's files/.
    .dropDestination(for: URL.self) { urls, _ in
      guard !isDesk, !urls.isEmpty else { return false }
      receive(urls)
      return true
    } isTargeted: { dropping = $0 }
    .padding(.leading, 16).padding(.top, 12).padding([.trailing, .bottom], 10)
    .composerSurface(focused: composing, targeted: dropping)
    .overlay(alignment: .top) { resizeGrabber }
    .padding(.horizontal, 20).padding(.bottom, 16).padding(.top, 4)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: composing)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: dropping)
  }

  private func composerFooter(_ session: AgentSession) -> some View {
    ComposerControlsLayout {
      HStack(spacing: 2) {
        if !isDesk { attachButton }
        paperReference(session)
        Spacer(minLength: 0)
      }
      HStack(spacing: 2) {
        ContextMeter(
          report: isDesk ? nil : session.context, busy: session.locked,
          compact: true, usage: session.usage, onCompact: { model.compactAgentContext() })
        ComposerStatusBar(model: model, locked: session.locked)
      }
      sendButton(session)
    }
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
      Image(systemName: "plus")
        .font(.system(size: 15))
        .foregroundStyle(Palette.inkSoft)
        .frame(width: 28, height: 28)
        .composerControl()
    }
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    .help(model.activeVision == false
          ? L("这张卡看不到图片；材料可以放进项目", "This card can't see images; files can go into the project")
          : L("图片随这条消息发送；材料放进项目，Markdown 进 notes/（都可以直接拖进来）",
              "Images go with this message; files go into the project, Markdown into notes/ (or drag them in)"))
    .accessibilityLabel(L("添加附件", "Attach"))
    .accessibilityIdentifier("agent-composer-attach")
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
    .frame(height: 52)
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
    case .desk, .ready: return L("描述任务或提出问题", "Describe a task or ask a question")
    case .empty: return L("先备好正文，再开始提问", "Get the text ready before asking")
    }
  }

  private func send(_ session: AgentSession) {
    guard canAsk, !session.locked, hasSomethingToSend else { return }
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
      onReset: { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { composerHeight = 0 } }
    )
  }

  /// While running, the same button stops; that is the only meaningful action there.
  private func sendButton(_ session: AgentSession) -> some View {
    let live = canAsk && hasSomethingToSend && !session.preparing
    return Button {
      if session.running { session.cancel() } else { send(session) }
    } label: {
      Image(systemName: session.running ? "stop.fill" : "arrow.up")
        .font(.system(size: session.running ? 10 : 14, weight: .semibold))
        .foregroundStyle(session.running || live ? Palette.paper : Palette.inkFaint)
        .frame(width: 30, height: 30)
        .background(
          session.running ? Palette.ink : (live ? Palette.accent : Palette.ink.opacity(0.055)),
          in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .buttonStyle(.plain)
    // one cancel is enough; a button that stays live invites repeated clicks
    .disabled(session.cancelRequested || session.backendBusy || (!session.running && !live))
    .help(session.running
          ? (session.cancelRequested ? L("正在停下…", "Stopping…") : L("停下这一轮", "Stop this turn"))
          : L("发送（⏎）", "Send (⏎)"))
    .accessibilityLabel(session.running ? L("停止", "Stop") : L("发送", "Send"))
    .accessibilityIdentifier("agent-composer-send")
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: session.running)
  }

  @ViewBuilder
  private func paperReference(_ session: AgentSession) -> some View {
    switch contextState {
    case .ready(let project), .empty(let project):
      ComposerPaper(model: model, project: project, locked: session.locked)
    case .desk:
      Label(L("书房 · 只见清单", "Library · list only"), systemImage: "books.vertical")
        .font(.system(size: 11.5)).foregroundStyle(Palette.inkSoft)
        .lineLimit(1).truncationMode(.tail)
        .padding(.horizontal, 6).frame(height: 28)
    }
  }
}

/// The transcript changes only with its session, which it observes itself. The panel around it redraws
/// on every change of the app model (the provider list, notes, the open project); without this the
/// transcript was regrouped and its rows rebuilt each time, at a cost that grows with the history.
private struct TranscriptPane: View, Equatable {
  let session: AgentSession
  /// asks an edited question in place of an earlier one (AppModel.resend)
  let edit: (UUID, String) -> Bool

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.session === rhs.session }

  var body: some View {
    AgentTranscript(
      session: session,
      onApprove: { approved, reason in session.answer(approved, reason: reason) },
      onEdit: edit)
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
    .frame(width: 64, height: 48)
    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.ruleSoft))
    .overlay(alignment: .topTrailing) {
      if hovering {
        Button(action: onRemove) {
          Image(systemName: "xmark.circle.fill").font(.system(size: 15))
            .symbolRenderingMode(.palette)
            .foregroundStyle(Palette.cream, Palette.ink.opacity(0.7))
            .frame(width: 18, height: 18)
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
      // Keep the hit area above, rather than across, the document and context controls.
      .frame(width: 72, height: 10)
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
