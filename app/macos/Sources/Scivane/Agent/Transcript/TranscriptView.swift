import SwiftUI

/// 对话流。
///
/// 设计取向延续面板本身：**内容优先，chrome 归零**。
///
/// - 用户的话是一块安静的浅底，不做气泡 —— 窄栏里左右对齐的气泡只会浪费宽度
/// - 助手的回答**不加任何容器**：它就是内容本身，装进框里反而降了一级
/// - **一整段过程（思考 + 工具调用）收成一张卡**，见 `ActivityCard`
struct AgentTranscript: View {
  @ObservedObject var session: AgentSession
  let onApprove: (Bool, String) -> Void
  @State private var expandedRows: Set<String> = []

  private func expansion(for id: String) -> Binding<Bool> {
    Binding(get: { expandedRows.contains(id) }, set: { value in
      if value { expandedRows.insert(id) } else { expandedRows.remove(id) }
    })
  }

  /// 渲染单元：要么是一条普通记录，要么是**一整段过程**（思考 + 工具调用）。
  enum Row: Identifiable {
    case single(TranscriptItem)
    case activity([TranscriptItem])

    /// 行的身份。
    ///
    /// 活动行**不能直接用首条记录的 id**：一条既有推理又有正文的助手消息
    /// 会被拆成两半（推理进卡、正文进流），两半共用同一个 UUID。
    /// 直接拿来当行 id 就会在 `ForEach` 里撞号 —— SwiftUI 会丢掉其中一行，
    /// 而且只在控制台留一行警告。
    var id: String {
      switch self {
      case .single(let item): return item.id.uuidString
      case .activity(let items): return "run:" + items[0].id.uuidString
      }
    }
  }

  /// 对话流的栏宽。**量出来的，不是铺满** —— 但也不再是一个死数。
  ///
  /// 720 是 13.5pt 下中文一行 40–45 字的舒适区（codex desktop 把对话流钉在
  /// `min(870px, 100%)`，同一个判断）。两件事要让它动起来：
  ///
  /// 1. **字号调大了，同样的字数需要更宽的栏** —— 不跟着走的话，
  ///    把字调大等于把每行的字数调少，读起来更累而不是更轻松。
  /// 2. **窗口很宽时留一点余量**：表格和代码块是这一栏里唯二会横向溢出的东西，
  ///    右边明明空着一大片却让它们横向滚动，说不过去。上限压在 1.34 倍，
  ///    再宽就越过舒适区了。
  static func column(width: CGFloat, fontSize: CGFloat) -> CGFloat {
    let measure = 720 * (fontSize / 13.5)
    return min(max(measure, width * 0.62), measure * 1.34)
  }

  /// 栏宽要跟着对话字号走，所以这一层也要读它。
  @AppStorage("agentFontSize") private var fontSize = 13.5

  /// 把**连着的过程**并成一张卡：思考与工具调用一视同仁。
  private var rows: [Row] { Self.group(session.items, running: session.running) }

  /// 提成静态函数是为了能被断言钉住。
  ///
  /// **分界线是「模型说的话」还是「模型的过程」，不是「后面还有没有工具」。**
  ///
  /// 这块判据改过三次，把过程写清楚，免得再来回摆：
  ///
  /// 1. 最早按「有没有正文」分 —— 失效了：模型每一步都先说一句旁白再调工具，
  ///    那条消息有正文，于是每步拆成两行，六步十二行，合并等于没做。
  /// 2. 改成「后面还有没有工具调用」＋跑动中一律算过程 —— 版面是干净了，
  ///    代价是**跑动中一个字都看不见**：正文全压在折叠卡里，等这一轮结束
  ///    才整段蹦出来。实机连报两次「不流式」「一下跳出来的」。
  /// 3. 现在这版：**模型说出来的话一律进消息流，思考与工具一律进折叠卡。**
  ///
  /// 第三版为什么不会再跳：**它不再需要事后改判**。前两版都要回答
  /// 「这句话到底是旁白还是答案」，而那个答案要等后面来了什么才知道 ——
  /// 先当答案铺开、工具一来又缩回卡里，那一下就是跳变的来源。
  /// 现在不问这个问题了：说出来的话就是说出来的话，落在流里不再动。
  ///
  /// 代价是一轮六步会出现六行短旁白。**这正是 codex 的样子** ——
  /// 它把 reasoning 折起来、把 message 作为消息留在流里，从不回收。
  /// 旁白通常只有一句，一行而已；而换来的是逐字生成真的看得见。
  ///
  /// 批准卡、失败卡、改文件的 diff 都不并进来：它们要么等用户动作，
  /// 要么是必须看见的结果，藏进折叠里就等于没说。
  static func group(_ items: [TranscriptItem], running: Bool = false) -> [Row] {
    func isProcess(_ index: Int) -> Bool {
      let item = items[index]
      // **改了文件的那一次不是过程，是结果。**
      //
      // 沿用批准卡/失败卡那同一条判据：「必须看见的结果，藏进折叠里
      // 就等于没说」。agent 动了用户项目里的文件，这是这一轮最该被看见的
      // 东西 —— 它已经落盘了，用户此刻唯一需要的是核对改得对不对。
      if item.diff != nil { return false }
      // 工具调用是过程
      if item.kind == .tool { return true }
      guard item.kind == .assistant else { return false }
      // **只有思考、没有正文 → 过程。** 推理是模型怎么想的，不是它说的话；
      // 它该被折起来，需要时再点开。
      //
      // **有正文 → 消息流。** 不管后面还会不会调工具，也不管这一轮完没完。
      return item.text.isEmpty
    }

    var rows: [Row] = []
    var pending: [TranscriptItem] = []
    func flush() {
      if !pending.isEmpty { rows.append(.activity(pending)); pending.removeAll() }
    }
    for index in items.indices {
      let item = items[index]
      if isProcess(index) {
        pending.append(item)
        continue
      }
      // **一条消息里推理和正文要分开去处。**
      //
      // 模型一步里往往先推理、再说一句话，两者被 `appendAssistant` 合进
      // 同一条记录。整条留在流里的话，每句旁白上面都会挂一个「展开思考」——
      // 实机上那正是用户说的「不是设置了折叠吗，为什么这里还有」。
      // 推理归折叠卡、说的话归消息流，这也正是 codex 的分法。
      if item.kind == .assistant, !item.thinking.isEmpty, !item.text.isEmpty {
        pending.append(item.reasoningOnly())
      }
      flush()
      rows.append(.single(item.spokenOnly()))
    }
    flush()
    return rows
  }

  /// 跑动中那一段过程。底部那块常驻状态要用它。
  private var liveRun: [TranscriptItem] {
    guard session.running, case .activity(let items)? = rows.last else { return [] }
    return items
  }

  var body: some View {
    // **内容短的时候要贴着顶，不是贴着底。**
    //
    // 上一版只加了 `.defaultScrollAnchor(.bottom)`，而那个锚点同时决定了
    // **内容比视口短时摆在哪** —— 于是刚发出第一条消息，它就沉到输入框
    // 上方去了，上面一大片空白。用一个至少占满视口、内容靠顶的容器兜住：
    // 短内容照常从顶上开始，长内容才轮到锚点起作用。
    // （`AgentPanel` 的空态早就用的是同一个法子。）
    GeometryReader { viewport in
      ScrollView {
        // **顶层不用 LazyVStack。**
        //
        // 行高差别极大（一行工具卡 vs 一整段带表格的答案），而 Lazy 容器
        // 对没材料化的行只能**估**高度。估错的表现正是实机报的那两样：
        // 滚到底却下面一大片空白（估高了）、以及消息一多就版面跳。
        //
        // 这里行数本来就少 —— `group` 把整段过程收成一张卡，一轮最多三四行，
        // 几十轮也就百来行。codex desktop 的 `.transcript` 同样是普通 grid，
        // 全量渲染、不虚拟化。**先要对，再谈省。**
        VStack(alignment: .leading, spacing: 2) {
          ForEach(rows) { row in
            view(for: row).id(row.id)
          }
          // **跑动中唯一的进度指示，而且常驻。**
          //
          // 之前是两处：活动卡自己演一份「正在跑 X」，底下再来一行
          // 「正在思考」，由一个条件决定谁出场 —— 那个条件每来一个工具、
          // 每收一段正文就翻一次，两块高度不同的东西轮流出现，界面就在抖。
          // 现在整轮只有这一块，位置固定，内容原地换。
          // **整轮常驻，不按条件出没。** 早先这里加了 `liveRun.isEmpty`，
          // 想让跑动中的指示只由活动卡来演；代价是模型刚吐第一个字这块就撤了，
          // 而正文按 `group` 的规则还留在过程卡里 —— 于是逐字生成在屏幕上
          // 没有任何落点，观感就是"不流式了"。
          if session.running && session.pending == nil {
            LiveStatus(run: liveRun, fallback: session.activity,
                       stopping: session.cancelRequested, since: session.askedAt)
              .padding(.top, 8)
              .transition(.opacity)
          }
          // **底部这块必须是 Spacer，不能是定高的留白。**
          //
          // 外面那层 `minHeight: viewport.size.height` 会在内容比视口短时
          // 撑出一段富余。LazyVStack 会把富余丢掉，而普通 VStack 会**分给
          // 能伸的子视图** —— 于是一张两行的表格被拉成半屏高，实机上
          // 正是那个样子。让 Spacer 把富余全吃掉，行本身就按自然高度排。
          Spacer(minLength: 10)
        }
        // **一轮收尾时三件事同时发生**：状态块撤掉、尾巴那段正文升格成答案、
        // 活动卡定稿。不给它们一个共同的动画上下文，三者会各自瞬切，
        // 看起来就是"啪"地换了一屏。绑在 `running` 这一个值上，
        // 既让这一次交接是渐变的，又不会把流式追加正文那种高频变化也卷进来。
        // **量出来的栏宽，不是铺满。**
        //
        // 这是 codex desktop 那套里最见效的一条：它把对话流钉在
        // `width: min(870px, 100%)` 并居中。窄栏时没区别，宽窗口下差别很大 ——
        // 一行八九十个汉字，眼睛回到行首要找半天，读长回答尤其累。
        // 取 720：中文正文一行落在 40–45 字，是长文阅读的舒适区。
        .padding(.horizontal, 22).padding(.top, 20)
        .frame(maxWidth: Self.column(width: viewport.size.width, fontSize: fontSize))
        .frame(
          maxWidth: .infinity, minHeight: viewport.size.height,
          alignment: .top)
      }
      // **贴着底走，而不是每次变化都手动滚一次。**
      //
      // 原先只在 `items.count` 变化时滚：流式追加正文时条数不变、高度在涨，
      // 视口于是慢慢离开底部，等下一条消息落地又被猛地拽回去 —— 那一下
      // 就是最明显的跳。`defaultScrollAnchor` 让内容长高时锚点留在底部，
      // 没有动画去和内容增长打架。
      // **一个锚点，始终贴底。**
      //
      // 早先这里按 `running` 在 .bottom / .top 之间翻：想让「展开一张历史卡」
      // 不被底部锚点顶走。代价远大于收益 —— 一轮结束的那一刻 `running` 变 false，
      // 锚点同时翻成 .top，而那一刻内容正好大改（尾巴那段正文从过程卡里
      // 升格成整段 Markdown）。两件事撞在一起，视口被拽回内容顶部，
      // 实机表现就是「输出完消息全挤到上面去了」。
      //
      // 聊天流本来就该只有一个锚点。展开历史卡时内容往下长、视口跟着走，
      // 这是所有聊天界面的既定行为，用户预期得到。
      .defaultScrollAnchor(.bottom)
    }
  }



  @ViewBuilder
  private func view(for row: Row) -> some View {
    switch row {
    case .single(let item):
      // **入场动画只给用户气泡。**
      //
      // 它是唯一「落地即定稿」的行；其余几种都在原地改（正文逐字追加、
      // 工具结果回填、分组重算），而 `RiseIn` 的 @State 会随视图身份重建，
      // 于是每改一次就重放一次淡入加位移 —— 看起来就是闪。
      // LazyVStack 回收重用时的 onAppear 也会再触发一次。
      if item.kind == .user {
        self.row(item).padding(.top, topGap(for: item)).riseIn()
      } else {
        // 答案是整段一次出现的（跑动中它还在过程卡里，见 group 的说明），
        // 淡入比瞬间铺开一屏温和得多。
        self.row(item).padding(.top, topGap(for: item)).transition(.opacity)
      }
    case .activity(let items):
      // 展开状态交给父视图按行 id 保管 —— 跑动中这张卡每来一个分片就重建，
      // 放在卡片自己的 @State 里会被随手合上。
      ActivityCard(
        items: items, expansion: expansion(for: row.id),
        streaming: session.streamingID, live: session.pacer
      ).padding(.top, 6)
    }
  }

  /// 节奏：**一轮之内收紧，轮与轮之间留口子。**
  ///
  /// 之前一轮里的每一段都留 12–14pt，加上 LazyVStack 的 4pt 行距，
  /// 一次「取代码 → 批准 → 读文件 → 作答」就被四道空隙撑开，读起来是
  /// 四件互不相干的事 —— 而它们其实是同一件事的四步。
  /// 现在轮内压到 6–8pt（还能分开，但连成一气），只有用户提问之前
  /// 保留大口子，因为那里**确实**是新的一轮。
  private func topGap(for item: TranscriptItem) -> CGFloat {
    switch item.kind {
    case .tool: return 4
    case .user: return 20
    case .assistant: return 10
    case .approval, .failure: return 8
    case .notice: return 8
    }
  }

  @ViewBuilder
  private func row(_ item: TranscriptItem) -> some View {
    switch item.kind {
    case .user: UserLine(text: item.text)
    case .assistant:
      AssistantLine(item: item, streaming: item.id == session.streamingID,
                    live: session.pacer, showThinking: expansion(for: item.id.uuidString))
    // 改了文件的那张卡**默认展开**。把它从折叠里提出来却还要再点一下，
    // 等于没提 —— 用户此刻要做的就是核对改得对不对。
    // codex desktop 的 `.activity-block` 同样是 `open` 的。
    case .tool: ToolCard(item: item, startExpanded: item.diff != nil)
    case .approval: ApprovalCard(item: item, onAnswer: onApprove)
    case .failure: FailureCard(code: item.code, message: item.displayText)
    case .notice: NoticeLine(text: item.displayText)
    }
  }
}

/// 长推理在自己的区域滚动，收起按钮始终留在外面。
// 原先是 file-private。拆文件之后用它的视图在别的文件里，
// 只能收窄到模块内可见。
struct ThinkingContent: View {
  let text: String
  private var prose: some View {
    Text(text).font(.system(size: 11.5)).foregroundStyle(Palette.inkFaint)
      .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
  var body: some View {
    if text.count > 900 {
      ScrollView { prose }.frame(height: 220)
    } else {
      prose
    }
  }
}
