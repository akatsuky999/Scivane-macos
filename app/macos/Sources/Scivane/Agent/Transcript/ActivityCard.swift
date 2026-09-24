import SwiftUI

// MARK: - 一段过程（思考 + 工具调用）

/// 模型一轮里的**全部过程**，收成一张卡。
///
/// 上一版只把连着的工具收成一行，但模型的真实形状是
/// 「思考 → 工具 → 思考 → 工具 → … → 回答」—— 中间每条只带思考的消息都会
/// 把工具串打断，于是十来步活动摊成十来行「思考过程 / 用了 2 个工具 0.0s」
/// 交替，真正的回答被顶出屏幕。**这张卡把整段收成一处。**
///
/// 跑动时给一行**读得懂的推理摘要**加一行当前动作，
/// 跑完收成一行「已处理 22.3s · 9 个工具」，想看细节再点开。
/// 关键在于它**原地更新**而不是一直往下堆 —— 版面高度是常数，不随步数增长。
///
/// 三个状态：
///
/// - **跑动中** —— 推理摘要（会呼吸）+ 当前在跑什么。**不给折叠箭头**：
///   还在动的东西没有「收起来」的意义
/// - **收起**（默认）—— 一行浅色摘要，没有卡片背景
/// - **展开** —— 思考块与工具明细**按原顺序**交替，左边一条竖线归拢它们
///
/// **异常状态收起时也必须看得见。** 失败、被拦、被拒绝、未执行的条数直接写进
/// 摘要行 —— 把一次失败藏进折叠里，用户会以为一切顺利。
struct ActivityCard: View {
  let items: [TranscriptItem]
  /// 展开状态由父视图按行 id 保管。
  ///
  /// **不能用卡片自己的 `@State`**：跑动中这张卡每来一个分片就重建一次，
  /// 而 `@State` 随视图身份走 —— 用户刚点开，下一个分片到达就又合上了。
  /// 留 `nil` 时退回本地状态，渲染验证里单独摆一张卡仍然能点。
  var expansion: Binding<Bool>? = nil
  /// 正在流式接收的那条记录。**它必须被认出来** —— 展开时把一条还在长的
  /// 正文整体重排，每个分片一次，是 O(n²)，实测 4.3 万字就把主线程占满。
  var streaming: UUID? = nil
  /// 正在生成的那一条屏幕上显示到哪了。展开时那条的尾巴从这里读 ——
  /// 逐帧的增长不经过 `items`（见 `StreamPacer`），读记录只会读到上一次定稿的字。
  var live: StreamPacer? = nil
  @State private var localExpanded = false
  private var expanded: Bool { expansion?.wrappedValue ?? localExpanded }
  private func toggle() {
    if let expansion { expansion.wrappedValue.toggle() } else { localExpanded.toggle() }
  }
  @State private var hovering = false

  /// 此刻该显示哪一句推理。
  ///
  /// 取**最后一行**而不是第一行：模型的推理往往以「接下来我去读 X」收尾，
  /// 那正是此刻最该让用户看见的；第一行通常只是复述题目。
  /// 流式时它跟着更新，让用户始终知道当前正在处理什么。
  /// **只扫尾部那一小段。** 这个函数每来一个流式分片就要跑一次，而推理
  /// 一直在变长 —— 整串 `split` 就是每个分片 O(n)、整轮 O(n²)。
  /// 实测（每 40ms 一个分片）：推理 2700 字时这一处占 6.7% CPU，
  /// 2.8 万字时 15.3%，**随长度单调上升**。那正是「思考越久越卡」。
  /// 要的只是最后一行，它一定在尾部，没有理由看前面几万字。
  static func headline(_ thinking: String, window: Int = 400) -> String {
    let lines = thinking.suffix(window).split(whereSeparator: \.isNewline)
    guard let last = lines.last(where: {
      !$0.trimmingCharacters(in: .whitespaces).isEmpty
    }) else { return "" }
    // 去掉 Markdown 的标题号、强调与列表符号：单行摘要里它们只是噪音
    return String(last).trimmingCharacters(in: CharacterSet(charactersIn: "#*->` \t"))
  }

  struct Anomaly { let label: String; let count: Int; let tint: Color }

  /// 异常计数 → 收起时也看得见的那几枚标签。
  /// **把一次失败藏进折叠里，用户会以为一切顺利。**
  static func anomalyChips(
    failed: Int, blocked: Int, denied: Int, skipped: Int, partial: Int
  ) -> [Anomaly] {
    var out: [Anomaly] = []
    if failed > 0 { out.append(.init(label: L("失败", "failed"), count: failed, tint: Palette.danger)) }
    if blocked > 0 { out.append(.init(label: L("被拦", "blocked"), count: blocked, tint: Self.amber)) }
    if denied > 0 { out.append(.init(label: L("已拒绝", "denied"), count: denied, tint: Palette.inkFaint)) }
    if skipped > 0 { out.append(.init(label: L("未执行", "not run"), count: skipped, tint: Palette.inkFaint)) }
    if partial > 0 {
      out.append(.init(label: L("沙箱 partial", "sandbox partial"), count: partial, tint: Self.amber))
    }
    return out
  }

  static let amber = Color(
    light: Color(red: 0.72, green: 0.48, blue: 0.13),
    dark: Color(red: 0.93, green: 0.75, blue: 0.42))

  /// 把这一段的工具翻成一句人话：「已读取文件、运行命令」。
  ///
  /// **报动作而不是报数量。** 「6 个工具」说不清它到底干了什么，
  /// 而「读取文件、运行命令」一眼就知道这一段发生过什么。
  ///
  /// 英文要两种时态（「Reading files」跑动中、「Read files, ran commands」跑完），
  /// 中文一种就够 —— 「正在」「已」由调用处接上。
  struct Verb: Equatable {
    let zh: String
    let doing: String
    let done: String
  }

  static func verb(for tool: String) -> Verb {
    switch tool {
    case "read", "glob", "grep": return Verb(zh: "读取文件", doing: "Reading files", done: "read files")
    case "bash", "python": return Verb(zh: "运行命令", doing: "Running commands", done: "ran commands")
    case "write", "edit": return Verb(zh: "改写文件", doing: "Editing files", done: "edited files")
    case "fetch_repo": return Verb(zh: "取回代码", doing: "Fetching code", done: "fetched code")
    case "reocr": return Verb(zh: "重跑识别", doing: "Re-running OCR", done: "re-ran OCR")
    case "cite": return Verb(zh: "定位原文", doing: "Locating the source", done: "located the source")
    default: return Verb(zh: tool, doing: tool, done: tool)
    }
  }

  /// 展开时，**还在流式的那条**画什么。
  ///
  /// 提成静态是为了能被断言钉住：这里一旦改回「原样画全文」，编译过、
  /// 画面也对，只是每个分片都要把整段重排一次 —— 实测 4.3 万字就把主线程
  /// 占满，而症状（界面卡死）完全不像是一行渲染代码造成的。
  static func live(_ item: TranscriptItem) -> String {
    live(text: item.text, thinking: item.thinking)
  }

  static func live(text: String, thinking: String) -> String {
    LiveStatus.tail(text.isEmpty ? thinking : text)
  }

  /// 展开时正在生成的那一条。有 pacer 就从它读（逐帧在长的那部分只在那里），
  /// 离屏出图时没有 pacer，退回记录里定稿的字。
  @ViewBuilder
  private func liveTail(_ item: TranscriptItem) -> some View {
    if let live {
      LiveTail(pacer: live)
    } else {
      Text(Self.live(item))
    }
  }

  /// 收起时那一行说什么。**与界面画的是同一份**（`Digest`）。
  ///
  /// 早先这里另写了一遍同样的规则，而界面画的是 `Digest` 那一份 —— 断言钉着这一份，
  /// 绿灯就说明不了屏幕上是什么。两份各写一遍必然漂移，这一次就漂了：
  /// 跑动中不报耗时只改在了 `Digest` 里。
  var summary: String { Digest(items: items, running: isRunning).summary }

  /// 这张卡里有正在生成的那一条。
  private var isRunning: Bool {
    streaming.map { id in items.contains { $0.id == id } } ?? false
  }

  /// **这张卡只有一种长相：收起的那一行。**
  ///
  /// 早先它自己还演一个「跑动中」的形态（推理摘要 + 当前动作），于是
  /// 同一件事在屏幕上有两处在说 —— 卡片一处、底下那行状态一处，
  /// 由一个每来一个工具就翻一次的条件决定谁出场。两块高度不同的东西
  /// 轮流出现，界面就在抖。现在跑动中的那一份**只在底部的 `LiveStatus`**，
  /// 卡片专心做「这一段干了什么」的索引。
  var body: some View {
    // **一次扫描，算出这张卡要用的全部派生值。**
    //
    // 早先 `summary` 在一次 body 里被读三次（动画的 value、标题、无障碍值），
    // 而它内部又各扫一遍 `tools` / `verbs` / `span`；加上 `anomalies` 和图标
    // 那一处，一次渲染要把 items 走十来遍。跑动中每个流式分片渲染一次，
    // 一段几十步的对话就是每秒几十万次元素访问 —— 稳定但白烧的那部分 CPU
    // 主要就在这里。派生值本来就只依赖 items，算一次传下去即可。
    let digest = Digest(items: items, running: isRunning)
    return VStack(alignment: .leading, spacing: 0) {
      header(digest)
      if expanded { detail }
    }
    // **给它一个实体。**
    //
    // 早先收起时是一行裸文字，飘在回答和提问中间，既不像标题也不像控件 ——
    // 用户看不出它是可以点开的一个东西。codex desktop 那边任何时候都是一张
    // 有底有边的 `.activity-block`，所以"这是一段过程"一眼就成立。
    //
    // 底色压到几乎看不见（3%）：它是**索引**，不该和答案抢注意力。
    // 展开之后底色略深一点，让"现在打开了"有个交代。
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Palette.sunk.opacity(expanded ? 0.75 : 0.45)))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Palette.ruleSoft, lineWidth: 1))
    // 跑动中每完成一个工具，摘要就从「已读取文件」变成「已读取文件、运行命令」。
    // 硬切会让人以为界面在闪，渐变一下就只是"它又干了一件事"。
    //
    // **动画只跟着「做了哪些事」走，绝不跟着时间走。** 早先键是整句摘要，
    // 而摘要里带着「· 3.2s」—— 流式时每 50ms 变一次，于是这句话**一直在做
    // 0.2 秒的渐变**：SwiftUI 把正在插值的文字交给 CPU 逐帧重画（每秒约 120 次），
    // 每画一次主线程都要等渲染服务交还上一块后备存储。实测（stream_perf.sh，
    // 12 轮历史）：这一个修饰符就让主线程在思考阶段占 33–55%、不时整块停住
    // 约 215ms；换成下面这个键之后 28%、最长一段 29ms。「一卡一卡」的「卡」
    // 主要就是它。
    .animation(.easeOut(duration: 0.2), value: digest.head)
  }

  /// 这张卡的全部派生值，**一次扫描算完**。
  struct Digest {
    var toolCount = 0
    var summary = ""
    /// 摘要里**不带耗时**的那一段。动画只认它 —— 见 body 里那条说明。
    var head = ""
    var anomalies: [Anomaly] = []

    /// - Parameter running: 这张卡里有正在生成的那一条。**跑动中不报耗时**：
    ///   正在长的那条不再逐帧改记录（见 `StreamPacer`），它的结束时间是上一次定稿的，
    ///   报出来就是一个不走的数；底部的 `LiveStatus` 本来就有一直在走的秒数。
    init(items: [TranscriptItem], running: Bool = false) {
      var verbs: [Verb] = []
      var pending: Verb? = nil
      var onlyTool: TranscriptItem? = nil
      var thoughtCount = 0
      var earliest: Date? = nil
      var latest: Date? = nil
      var failed = 0, blocked = 0, denied = 0, skipped = 0, partial = 0

      for item in items {
        if let start = item.startedAt, earliest == nil || start < earliest! { earliest = start }
        if let end = item.finishedAt, latest == nil || end > latest! { latest = end }
        switch item.kind {
        case .assistant:
          thoughtCount += 1
        case .tool:
          toolCount += 1
          onlyTool = toolCount == 1 ? item : nil
          let verb = ActivityCard.verb(for: item.toolName)
          // 去重并保持首次出现的顺序 —— 顺序本身就是这一段的叙事
          if !verbs.contains(verb) { verbs.append(verb) }
          if item.awaitingResult {
            pending = verb
          } else {
            if item.synthetic { skipped += 1 }
            else if item.decision?.approved == false
              || item.preview.contains("TOOL_DENIED_BY_USER") { denied += 1 }
            else if item.isError {
              // 不翻：看的是工具结果（给模型的那份永远是中文，后端 `i18n.py`）
              item.preview.contains("沙箱") ? (blocked += 1) : (failed += 1)
            }
            if item.enforcement != nil { partial += 1 }
          }
        default:
          break
        }
      }

      // 工具仍在等待结果时不能使用过去时 —— 过去时会让运行中的任务
      // 看起来已经完成，所以当前动作与历史结果要分开。
      if let pending {
        summary = L("正在" + pending.zh, pending.doing)
      } else if toolCount == 1, thoughtCount == 0, let only = onlyTool {
        // 只有一次调用、也没有思考时报它自己（「搜索 对比损失」），
        // 别说「已读取文件」那种比原文还模糊的话
        summary = only.summary.isEmpty ? only.toolName : only.summary
      } else if verbs.isEmpty {
        summary = L("思考过程", "Thinking")
      } else {
        let done = verbs.map(\.done).joined(separator: ", ")
        summary = L("已" + verbs.map(\.zh).joined(separator: "、"), done.prefix(1).uppercased() + done.dropFirst())
      }
      head = summary
      // 跨度而不是各段耗时相加 —— 只读工具并发跑，相加会算出比实际长的数字。
      // **短于 0.05 秒不报**：一串「· 0.0s」是纯噪音，而且会让人以为
      // 这里本该有个数字却没算出来。和工具卡自己那条门槛保持一致。
      if pending == nil, !(toolCount == 1 && thoughtCount == 0), !running,
        let first = earliest, let last = latest, last.timeIntervalSince(first) >= 0.05
      {
        summary += String(format: " · %.1fs", last.timeIntervalSince(first))
      }
      anomalies = ActivityCard.anomalyChips(
        failed: failed, blocked: blocked, denied: denied,
        skipped: skipped, partial: partial)
    }
  }

  // MARK: 收起 / 展开

  private func header(_ digest: Digest) -> some View {
    Button {
      toggle()
    } label: {
      HStack(spacing: 7) {
        // **转环只在底部那块状态里有一个。** 这里也放一个的话，同一件事
        // 在屏幕上有两处在转，而且两处的文案还不一定同步。
        // 卡片专心做「这一段干了什么」的索引，跑动中的那一份交给 `LiveStatus`。
        Image(systemName: digest.toolCount == 0 ? "text.alignleft" : "wrench.adjustable")
          .font(.system(size: 10)).foregroundStyle(Palette.inkFaint)
          .frame(width: 12)

        // 摘要按**标签**排，不按正文排：小一号、字重压上去、字距放开一点。
        // 这是 codex desktop 的 `.activity-block summary` 的判断
        // （10px / weight 760 / letter-spacing .02em）—— 小字重了才立得住，
        // 不然在浅色文字里就糊成一片。
        Text(digest.summary)
          .font(.system(size: 10.5, weight: .medium))
          .foregroundStyle(hovering ? Palette.inkSoft : Palette.inkFaint)
          .kerning(0.2)
          .lineLimit(1).truncationMode(.middle)

        // 异常在收起时也要看得见 —— 藏起来用户会以为一切顺利
        ForEach(Array(digest.anomalies.enumerated()), id: \.offset) { _, anomaly in
          Text(anomaly.count > 1 ? L("\(anomaly.count) 个\(anomaly.label)", "\(anomaly.count) \(anomaly.label)")
                                 : anomaly.label)
            .font(.system(size: 9.5, weight: .medium)).foregroundStyle(anomaly.tint)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(anomaly.tint.opacity(0.13), in: Capsule())
        }

        Spacer(minLength: 4)
        Image(systemName: "chevron.down")
          .font(.system(size: 8, weight: .semibold))
          .rotationEffect(.degrees(expanded ? 180 : 0))
          .foregroundStyle(Palette.inkFaint.opacity(hovering || expanded ? 0.85 : 0.3))
      }
      .padding(.horizontal, 10).padding(.vertical, 7)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(expanded ? L("收起思考与工具", "Collapse thinking and tools")
                                 : L("展开思考与工具", "Expand thinking and tools"))
    .accessibilityValue(digest.summary)
    .onHover { hovering = $0 }
    .help(expanded ? L("收起", "Collapse") : L("看看它做了什么", "See what it did"))
  }

  /// 展开的明细：**思考与工具按原顺序交替**。
  ///
  /// 不把思考挪到一起 —— 「想了什么、于是做了什么」的因果只在原顺序里成立，
  /// 打乱之后这段记录就只剩流水账。
  ///
  /// **必须是 Lazy 的。** 跑动中这张卡持有**整轮**记录（一轮几十步就是上百条），
  /// 而每来一个流式分片 `items` 就变一次 —— 急切的 VStack 会把上百条全部
  /// 重建重排一遍，每条还带 `textSelection` 和（长推理时）一个嵌套 ScrollView。
  /// 那就是每个分片 O(n)、整轮 O(n²)。
  ///
  /// 实测条件：M5/16GB，700pt 宽，每 0.25 秒追加一条（含 >900 字的长推理，
  /// 会触发 `ThinkingContent` 里的嵌套 ScrollView），离屏窗口。
  ///
  /// | | 收起 | 展开（急切 VStack） | 展开（LazyVStack） |
  /// |---|---|---|---|
  /// | 80 条 | 0.9% | 32% | 17% |
  /// | 320 条 | 0.9% | 63% | 15% |
  /// | 450 条 | 0.9% | **99.5%** | 17% |
  /// | 800 条 | 0.9% | —— | 29% |
  ///
  /// 急切那一列**随条数单调上升**，450 条左右主线程就占满了；再往后连
  /// 追加都跟不上（100 秒里只收进 508 条，Lazy 那边同样时间收进 800 条）——
  /// 界面从这里开始就是"卡死"。这正是实机报的那个现象。
  ///
  /// **Lazy 只挡住了「条数多」那一路，还有一路是「一条自己长」**：
  /// 正在流式的那条每来一个分片就整体重排一次，而它一直可见，Lazy 跳不过它。
  /// 同样条件下只放两条记录、让一条正文自己长：收起恒定 3%，展开从 35% 一路
  /// 涨到 **100%**（约 4.3 万字时占满）。所以流式中的那条只画尾巴 ——
  /// 见 `settled(_:)`。
  private var detail: some View {
    // 卡片现在自己有底有边，**里面就不必再来一道竖线**了 ——
    // 两层容器叠在一起是"框里的框"，最显廉价。改用一条发丝线把
    // 头和明细分开，再靠缩进表达层级。
    VStack(alignment: .leading, spacing: 0) {
      Rectangle().fill(Palette.ruleSoft).frame(height: 1)
        .padding(.horizontal, 10)
      LazyVStack(alignment: .leading, spacing: 7) {
        ForEach(items) { item in
          if item.kind == .tool {
            ToolCard(item: item, dense: true)
          } else if item.kind == .assistant, !item.thinking.isEmpty {
            // 思考是**过程里的过程**，比工具还要退一层：标签用最小号、
            // 字距拉开当小标题使，正文再压一档灰度。没有这个层级的话，
            // 一段推理和一条工具结果看起来一样重，读的人分不出主次。
            //
            // **标签要留住，哪怕这条正在流式。** 早先「正在流式」那个分支排在
            // 最前面，于是推理刚开始时卡里只剩一个孤零零的词（实机截图里是
            // 「用户」），既没有标签也看不出是什么 —— 用户完全不知道那是什么。
            // 现在只有**内容**按流式设界，标签照常。
            VStack(alignment: .leading, spacing: 3) {
              Text(L("思考", "THINKING"))
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(Palette.inkFaint.opacity(0.75))
              if item.id == streaming {
                // 还在长的那条只画一段有界的尾巴，**不开 textSelection**：
                // 正在生成的文字选不住，而全量重排正是把主线程占满的那一路。
                liveTail(item)
                  .font(.system(size: 11.5)).foregroundStyle(Palette.inkFaint)
                  .fixedSize(horizontal: false, vertical: true)
              } else {
                ThinkingContent(text: item.thinking)
              }
            }
          } else if item.id == streaming {
            liveTail(item)
              .font(.system(size: 11.5)).foregroundStyle(Palette.inkFaint)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.vertical, 2)
          } else if item.kind == .assistant, !item.text.isEmpty {
            Text(item.text)
              .font(.system(size: 11.5)).foregroundStyle(Palette.inkSoft)
              .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          } else {
            Text(item.thinking)
              .font(.system(size: 11.5)).foregroundStyle(Palette.inkFaint)
              .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
              .padding(.vertical, 2)
          }
        }
      }
      .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 10)
    }
  }
}

/// 跑动中那块常驻状态：**正文的尾巴在上，当前动作在下**。
///
/// 整轮只有这一块，**位置固定、内容原地换** —— 这是不跳变的关键。
/// 之前是「卡片演一份、底下再来一行」，由一个每来一个工具就翻一次的条件
/// 决定谁出场；两块高度不同的东西轮流出现，界面就在抖。
///
/// 上面那块是**固定两行的窗口，正文的尾巴在里面往上滚**。
/// 高度写死是不抖的前提（内容每几百毫秒换一次），取尾巴是"看得见在动"的
/// 前提 —— 两个要求本来矛盾，用「固定窗口 + 滑动内容」同时满足。
///
/// **这块窗口不是可选的装饰。** 跑动中正文按 `group` 的规则留在过程卡里
/// （否则每一步的旁白都要先铺开成答案、几百毫秒后再缩回去，一轮跳二十次），
/// 于是这里是逐字生成**唯一**看得见的地方。把它拿掉，模型说了多少字
/// 在屏幕上就完全没有反馈，观感退回"憋一大段再啪地出现"。

/// 展开的过程卡里那条正在生成的尾巴。**单独一个视图观察 pacer** ——
/// 这样逐帧重画的只有这一行字，卡片本身和对话流都不动。
private struct LiveTail: View {
  @ObservedObject var pacer: StreamPacer
  var body: some View {
    Text(ActivityCard.live(text: pacer.shown.text, thinking: pacer.shown.thinking))
  }
}
