import SwiftUI

/// 与 agent 对话的面板。
///
/// 设计取向：**内容优先，chrome 归零**。切到这一栏本身就说明了「这是 Agent」，
/// 所以面板内没有标题栏、状态点、省略号菜单这类只占位不做事的模块。
/// 视觉重心落在两处 —— 对话流本身，和底部那张浮起来的输入卡。
///
/// **它同时是两层 agent 的界面。** 没打开项目时这里是**书房**（只见清单、
/// 没有 shell、读不到任何正文），打开项目后换成**读者**。两层各持一个会话，
/// 记录不混在一起 —— 打开项目是换一个 agent 实例，不是换上下文。
/// 解析出当前这一层的会话，再交给面板。
///
/// **这一层不能省。** 面板要观察的是**会话对象内部**（消息来了没有、还在不在跑），
/// 而那不是 AppModel 的变更 —— 只传 model 的话，`session.items` 变了界面
/// 一个字都不会重画，表现就是「发了消息一直没反应」。
/// 所以在这里把会话取出来，由面板用 @ObservedObject 持有它。
///
/// `activeProjectID` 是 @Published，所以换一层时这里会重跑、
/// 面板会重新绑到另一个会话上 —— 两层的记录因此各归各的。
struct AgentPane: View {
  @ObservedObject var model: AppModel

  var body: some View {
    // **id 里必须带上对话**：换一条对话是换另一个会话实例，
    // 只换 projectID 的话 SwiftUI 会复用同一棵视图，新对话的输入框
    // 仍然绑在旧会话上 —— 症状是「切过去了，发的话却进了上一条」。
    AgentPanel(
      model: model,
      session: model.session(
        for: model.activeProjectID, conversation: model.activeConversationID))
      .id(AppModel.sessionKey(model.activeProjectID, model.activeConversationID))
  }
}

struct AgentPanel: View {
  @ObservedObject var model: AppModel
  /// **必须是 @ObservedObject。** 见 `AgentPane` 的说明。
  @ObservedObject var session: AgentSession
  @State private var draft = ""
  @FocusState private var composing: Bool
  /// 有文件悬在输入区上方。边框据此给反馈。
  @State private var dropping = false

  /// 用户拖出来的输入框高度。0 表示跟随内容自动增高。
  ///
  /// 存进偏好而不是 @State：调好的高度是个人习惯，不该每次开 App 都退回默认。
  @AppStorage("agentComposerHeight") private var composerHeight: Double = 0
  /// 一次拖拽开始时的基准高度。拖的是增量，不是绝对位置。
  @State private var dragBaseline: Double?

  private static let minComposerHeight: Double = 22    // 一行
  private static let maxComposerHeight: Double = 340

  /// 拖高之后要能真的显示那么多行，否则框变大了字还是挤在 7 行里。
  private var lineCap: Int {
    composerHeight > 0 ? max(7, Int(composerHeight / 18)) : 7
  }

  /// 这一层是书房还是读者。
  private var isDesk: Bool { model.activeProject == nil }

  /// 上下文的四种状态。界面与后端必须说同一套话：
  /// 后端 `context.assemble()` 对未确认的正文直接拒绝装配，
  /// 所以这里也绝不能显示成「已加载」。
  private enum ContextState {
    case ready(Project)            // 可用
    case awaitingConfirm(Project)  // 有正文，但没人认账
    case empty(Project)            // 有项目，没正文
    case desk                      // 书房那一层
  }

  private var contextState: ContextState {
    guard let project = model.activeProject else { return .desk }
    if project.awaitsConfirmation { return .awaitingConfirm(project) }
    return project.hasUsableContext ? .ready(project) : .empty(project)
  }

  /// 能不能发问。书房那层不需要正文，但两层都需要一个配好的模型。
  private var canAsk: Bool {
    guard !model.agentProvider.isEmpty else { return false }
    switch contextState {
    case .ready, .desk: return true
    case .awaitingConfirm, .empty: return false
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      // 书房那层没有对话的概念，所以这条只在项目里出现
      if !isDesk { ConversationBar(model: model) }
      if session.isEmpty {
        // 有空间就居中，空间不够再滚动。ScrollView 里的 Spacer 撑不开
        // （内容高度不受限），所以要用容器高度兜一个 minHeight。
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
    .task(id: AppModel.sessionKey(model.activeProjectID, model.activeConversationID)) {
      // 换了一层或换了一条对话，就把那一段历史补回来（第一次进来才拉）
      model.restoreAgentHistory()
      await model.refreshProviders()
    }
    .task(id: model.activeProjectID) {
      guard let projectID = model.activeProjectID else { return }
      await model.refreshProjectFiles(projectID)
    }
    .onChange(of: session.running) { _, running in
      // 一轮跑完再拉一次清单：第一句话之后后端才会给这条对话起名字
      // （标题取自第一句提问），条数也变了。
      guard !running, let projectID = model.activeProjectID else { return }
      Task { await model.refreshConversations(projectID) }
    }
  }

  // MARK: - 空态

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

  /// 两层的起手问题不一样 —— 书房那层问正文是问不出东西的，
  /// 它根本读不到。提示词里也是这么写的，界面要和它说同一套话。
  /// 起手问题跟着界面语言：点一下就是一句那种语言的提问，而 agent 用提问的语言回答 ——
  /// 英文界面的人点下去，得到的就是英文回答。
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
    case .awaitingConfirm: return L("正文还没确认", "The text isn't confirmed yet")
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
    case .awaitingConfirm:
      return L("导入的 Markdown 需要你确认是这篇论文的正文，确认后才会作为上下文。",
               "Confirm that the imported Markdown is this paper's text; only then is it used as context.")
    case .empty:
      return L("识别原稿，或导入一份 Markdown 作为正文。",
               "Run OCR on the original, or import a Markdown file as its text.")
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
    case .ready, .desk, .awaitingConfirm:
      return nil
    case .empty(let project):
      return (L("开始识别原稿", "Run OCR on the Original"),
              { Task { await model.enterProject(project); model.reOCRActiveProject() } })
    }
  }

  // MARK: - 输入区
  //
  // **不用分割线**，靠一张浮起来的圆角卡片与对话流分开 ——
  // 线是硬边界，阴影是软边界，后者才不打断阅读。

  private func composer(_ session: AgentSession) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      contextRow(session)
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
          model: model, usage: session.usage,
          locked: session.running || session.preparing)
        Spacer(minLength: 0)
        if canAsk && !draft.isEmpty && !session.running && !session.preparing {
          Text(L("⏎ 发送", "⏎ Send")).font(.system(size: 10)).foregroundStyle(Palette.inkFaint)
            .transition(.opacity)
        }
        sendButton(session)
      }
    }
    // 拖进来就放进项目的 files/ —— 这是最短的那条路，比「点按钮、开面板、
    // 找文件」少三步，而拖拽本来就是用户手边已有文件时的第一反应。
    .dropDestination(for: URL.self) { urls, _ in
      guard !isDesk, !urls.isEmpty else { return false }
      Task { await model.addProjectFiles(urls) }
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
    // 浮起来而不是划条线：线是硬边界，会把面板切成两块；阴影是软的，
    // 对话滚到底下也不会被一刀截断。
    .shadow(color: .black.opacity(composing ? 0.10 : 0.05), radius: composing ? 14 : 9, y: 3)
    .padding(.horizontal, 16).padding(.bottom, 16).padding(.top, 4)
    .animation(.easeOut(duration: 0.16), value: composing)
    .animation(.easeOut(duration: 0.16), value: draft.isEmpty)
    .animation(.easeOut(duration: 0.14), value: dropping)
  }

  /// 已经放进 `files/` 的材料。**列的是项目里真实存在的东西**，
  /// 不是「这次要上传的暂存区」—— 拖进来那一刻就已经落盘了，
  /// 再做一个待提交状态只会让人搞不清到底传没传。
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

  private var attachButton: some View {
    Button {
      model.chooseProjectFiles()
    } label: {
      Image(systemName: "paperclip")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Palette.inkFaint)
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(L("把材料放进项目的 files/（也可以直接拖进来）", "Add files to the project's files/ (or just drag them in)"))
    .accessibilityLabel(L("添加材料", "Add Files"))
  }

  private var placeholder: String {
    if model.agentProvider.isEmpty { return L("先在设置里配一个模型", "Set up a model in Settings first") }
    switch contextState {
    case .desk: return L("问问书房里都有什么…", "Ask what's in your library…")
    case .ready: return L("让它读、跑、画，或者直接提问…", "Have it read, run, plot — or just ask…")
    default: return L("先备好正文，再开始提问", "Get the text ready before asking")
    }
  }

  private func send(_ session: AgentSession) {
    guard canAsk, !session.running else { return }
    let question = draft
    draft = ""
    model.askAgent(question)
  }

  /// 顶边的拖拽手柄。
  ///
  /// 平时几乎看不见，指过去才浮出来 —— 它是个「需要时才存在」的控件，
  /// 常驻一条明显的横杠会把输入框切成两半。双击回到自动高度。
  private var resizeGrabber: some View {
    ResizeGrabber(
      isDragging: dragBaseline != nil,
      onChanged: { translation in
        let base = dragBaseline ?? max(Self.minComposerHeight, composerHeight)
        if dragBaseline == nil { dragBaseline = base }
        // 往上拖变高：translation 向上为负，所以取减
        // 取整到整点：亚像素高度会让上方内容每帧重排一次，看着发毛
        composerHeight = (min(
          Self.maxComposerHeight, max(Self.minComposerHeight, base - translation))).rounded()
      },
      onEnded: { dragBaseline = nil },
      onReset: { withAnimation(.easeOut(duration: 0.18)) { composerHeight = 0 } }
    )
  }

  /// 跑起来之后按钮变成「停」。同一个位置换语义，而不是再挤一个按钮进来 ——
  /// 那个位置在跑的时候唯一有意义的动作就是停下。
  private func sendButton(_ session: AgentSession) -> some View {
    let live = canAsk && !draft.isEmpty && !session.preparing
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
    // 按过一次就不再接受第二次 —— 重复 POST /cancel 没有意义，
    // 而按钮继续亮着会让人反复点，更像是坏的。
    .disabled(session.cancelRequested || (!session.running && !live))
    .help(session.running
          ? (session.cancelRequested ? L("正在停下…", "Stopping…") : L("停下这一轮", "Stop this turn"))
          : L("发送（⏎）", "Send (⏎)"))
    .accessibilityLabel(session.running ? L("停止", "Stop") : L("发送", "Send"))
    .animation(.easeOut(duration: 0.16), value: session.running)
  }

  /// 上下文行：标题一枚 chip，状态另起。
  ///
  /// 关键是**标题按尾部截断**。之前拼成「「长标题…」尚无正文」再中间截断，
  /// 结果是一串读不出来的碎片 —— 用户既认不出是哪篇，也看不清状态。
  @ViewBuilder
  private func contextRow(_ session: AgentSession) -> some View {
    switch contextState {
    case .ready(let project):
      HStack(spacing: 7) {
        chip(icon: "doc.text", title: project.displayTitle)
        if let context = project.context {
          Text(context.sizeLabel)
            .font(.system(size: 10).monospacedDigit()).foregroundStyle(Palette.inkFaint)
        }
        Spacer(minLength: 0)
        modelChip
      }
    case .awaitingConfirm(let project):
      statusRow(project.displayTitle, icon: "doc.text", status: L("待确认", "Unconfirmed"), tint: Palette.accent)
    case .empty(let project):
      statusRow(project.displayTitle, icon: "doc.text", status: L("尚无正文", "No text yet"), tint: Palette.inkFaint)
    case .desk:
      HStack(spacing: 7) {
        chip(icon: "books.vertical", title: L("书房 · 只见清单", "Library · list only"))
        Spacer(minLength: 0)
        modelChip
      }
    }
  }

  /// 当前用的模型。点它直接去设置换 —— 换模型是个高频动作，
  /// 不该逼用户去菜单里找。
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

  private func statusRow(_ title: String, icon: String, status: String, tint: Color) -> some View {
    HStack(spacing: 7) {
      chip(icon: icon, title: title)
      Text(status).font(.system(size: 10, weight: .medium)).foregroundStyle(tint)
      Spacer(minLength: 0)
      modelChip
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

/// 空态里的引导问题。安静的一行，悬停才浮出来 —— 不用填色卡片，
/// 免得三条建议在视觉上压过真正的主角（输入框）。
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


/// 输入框顶边的高度手柄。
///
/// **手势必须用全局坐标系。** 这个手柄贴在输入框顶边，而输入框长高时顶边是
/// 向上移动的（面板里 GeometryReader 占弹性空间，composer 在底部）——
/// 也就是说，手柄会被自己这次拖拽推着走。
///
/// `DragGesture` 默认在 `.local` 坐标系里算 `translation`：视图一移动，
/// 同一个鼠标位置对应的局部坐标就变了，位移被重复计入，于是
/// 「变高 → 手柄上移 → 位移变大 → 更高」形成自激回路，表现就是拖的时候页面震荡。
/// 换成 `.global` 之后 startLocation 与 location 都在屏幕坐标里，
/// 只反映真实的鼠标移动，回路断开。
private struct ResizeGrabber: View {
  let isDragging: Bool
  let onChanged: (CGFloat) -> Void
  let onEnded: () -> Void
  let onReset: () -> Void

  @State private var hovering = false
  /// 光标是否已入栈。push/pop 必须配对，否则拖到手柄外面松手会把栈弄乱。
  @State private var cursorPushed = false

  var body: some View {
    Capsule()
      .fill(Palette.inkFaint)
      .frame(width: 34, height: 3.5)
      .opacity(isDragging ? 0.7 : (hovering ? 0.42 : 0))
      .padding(.top, 5)
      // 命中区比视觉大得多：3.5pt 高的东西直接拖是拖不住的
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
        // 拖动中光标可能已经移出手柄（手柄自己在动），这时不能把光标收回去
        syncCursor(active: dragging || hovering)
      }
      .onDisappear { syncCursor(active: false) }
      .onTapGesture(count: 2) { onReset() }
      .help(L("拖动调整高度，双击恢复自动", "Drag to resize; double-click to reset"))
      // 只给不影响布局的属性上动画。高度本身绝不能带动画 ——
      // 拖动时每帧都在改它，动画会让它永远在追上一帧的值，看起来就是发飘。
      .animation(.easeOut(duration: 0.14), value: hovering)
      .animation(.easeOut(duration: 0.14), value: isDragging)
  }

  private func syncCursor(active: Bool) {
    guard active != cursorPushed else { return }
    if active { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
    cursorPushed = active
  }
}

/// 项目内的对话切换条。
///
/// **这是面板里唯一一处 chrome，它是挣来的。** 面板的设计取向是「内容优先、
/// chrome 归零」，不放只占位不做事的模块；而这一条做的是三件没有别处可放的事：
/// 现在在哪条对话、切到别条、开一条新的，所以收成一行，细节藏进菜单。
///
/// 视觉上刻意压到最轻：没有背景块、字号 11、只有一条底边发丝线 ——
/// 它是索引，不该和对话内容抢注意力。
struct ConversationBar: View {
  @ObservedObject var model: AppModel
  @State private var renaming = false
  @State private var draftTitle = ""

  private var current: Conversation? {
    guard let id = model.activeConversationID else { return nil }
    return model.activeConversations.first { $0.id == id }
  }

  /// 还没开过对话时显示什么。
  ///
  /// **不在这里替它建一条。** 建在发问那一刻（后端的 `ensure_conversation`
  /// 会接上），否则光是点开 Agent 栏就会在磁盘上留下一条空对话。
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

  /// 只有一条时不报条数 —— 「1 条对话」是句废话。
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
          // 勾出当前这条。菜单里没有别的办法说明"你在这儿"
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

// MARK: - 用量与上下文余量

/// 输入区底部那一行：**这一轮花了多少、窗口还剩多少**。
///
/// 三个数字的分量不一样，所以长相也不一样：
///
/// - **余量**最要紧 —— 它决定「这段对话还能不能继续」，所以给它一条真的进度条，
///   并且过了七成变琥珀、过了九成变红。数字本身反而次要，一眼看条就够。
/// - **缓存命中**报**比例**而不是绝对值。「缓存 54848」要和输入量心算一下才有意义，
///   「缓存 97%」直接就是结论 —— 而这正是这个产品最该盯的一个指标
///   （一篇论文当静态前缀，命中率高才谈得上便宜）。
/// - **进出量**用紧凑写法（56.4K），它只是量级参考，占不了主位。
///
/// 窗口没配就**不画条**，只报用量。猜一个窗口比不显示更糟：用户会照着一个
/// 假的余量规划对话，直到某次突然撞上 CONTEXT_WINDOW_EXCEEDED。
struct UsageMeter: View {
  let usage: AgentUsage
  /// 当前 provider 声明的上下文窗口。nil 表示没配。
  var window: Int?

  /// 这一轮实际送进模型的量（缓存命中的那部分也占窗口）。
  private var consumed: Int { usage.input + usage.cacheRead }

  private var ratio: Double {
    guard let window, window > 0 else { return 0 }
    return min(1, Double(consumed) / Double(window))
  }

  /// 七成之前是安静的绿，之后开始提醒 —— 颜色是这里唯一的告警手段。
  private var tint: Color {
    if ratio >= 0.9 { return Palette.danger }
    if ratio >= 0.75 { return ActivityCard.amber }
    return Palette.accent
  }

  /// 紧凑记数：56400 → 56.4K，1200000 → 1.2M。
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

  /// 缓存命中率：命中的 token 占送进去总量的比例。
  private var cacheHit: Int? {
    guard consumed > 0, usage.cacheRead > 0 else { return nil }
    return Int((Double(usage.cacheRead) / Double(consumed) * 100).rounded())
  }

  var body: some View {
    HStack(spacing: 8) {
      if let window, window > 0 {
        HStack(spacing: 5) {
          gauge
          Text("\(Self.compact(consumed)) / \(Self.compact(window))")
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(ratio >= 0.75 ? tint : Palette.inkFaint)
            .monospacedDigit()
        }
        .help(L("这一轮送进模型 \(consumed.formatted()) token，窗口 \(window.formatted()) —— 已用 \(Int(ratio * 100))%",
                "This turn sent \(consumed.formatted()) tokens; the window is \(window.formatted()) — "
                  + "\(Int(ratio * 100))% used"))
      }

      if !usage.isEmpty {
        HStack(spacing: 6) {
          // 配了窗口时**不再报一遍输入量** —— 「56K / 1.0M」左边那个数
          // 就是它，两处说同一件事只是在窄栏里抢宽度。
          if window == nil || window == 0 {
            flow("arrow.down", Self.compact(consumed))
          }
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
      }
    }
    .animation(.easeOut(duration: 0.25), value: consumed)
    .animation(.easeOut(duration: 0.25), value: usage.output)
  }

  private var gauge: some View {
    ZStack(alignment: .leading) {
      Capsule().fill(Palette.inkFaint.opacity(0.16))
      Capsule().fill(tint).frame(width: max(2, 52 * ratio))
    }
    .frame(width: 52, height: 4)
  }

  private func flow(_ symbol: String, _ text: String) -> some View {
    HStack(spacing: 2) {
      Image(systemName: symbol).font(.system(size: 7, weight: .bold))
      Text(text).font(.system(size: 9.5, design: .monospaced)).monospacedDigit()
    }
    .foregroundStyle(Palette.inkFaint)
  }
}

/// `files/` 里一份材料的小标签。
///
/// 指过去才露出叉号 —— 常驻一个删除按钮会让这一排看起来像待办清单，
/// 而它其实只是「项目里有这些东西」的陈述。
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
        // 上限给**文字**，不是给整张标签 —— 给标签的话短名字也会被撑到
        // 190pt 宽，一排下来中间全是空，看着像没对齐。
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

  /// 按扩展名给个图标。认不出来就是一张纸 —— 不必穷举。
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
