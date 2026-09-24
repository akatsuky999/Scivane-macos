import Foundation
import SwiftUI

/// 一层 agent 的对话记录与运行状态。
///
/// **每一层各持一个实例**：书房一个，每个项目一个。这不是为了省事，
/// 而是因为「打开项目是换一个 agent 实例，不是换上下文」——
/// 两层的记录混成一条流，用户就分不清哪句话是对着哪一层说的，
/// 而书房那一层根本读不到论文正文。
@MainActor
final class AgentSession: ObservableObject {

  /// 这是哪一层。`nil` 是书房（不属于任何项目）。
  let projectID: String?

  /// 这是项目里的哪一条对话。书房那层没有对话的概念，永远是 `nil`。
  ///
  /// **它和 projectID 一起构成这个会话的身份。** 换一条对话就是换一段历史，
  /// 所以换的是**另一个 AgentSession 实例**，而不是把这个实例的 items 清空 ——
  /// 后者会让正在跑的那一轮把结果写进新对话的界面里。
  let conversationID: String?

  @Published private(set) var items: [TranscriptItem] = []
  @Published private(set) var running = false
  /// 后端尚未返回 job id 时也要锁住发送入口，避免快速连点创建两条交叠请求。
  @Published private(set) var preparing = false
  @Published private(set) var usage = AgentUsage()
  /// 正在等用户裁决的那一次调用。非空时输入区让位给批准卡。
  @Published private(set) var pending: PendingApproval?
  /// 这一轮里 agent 第一个到达的主机。**显眼但不阻塞**：
  /// 联网是正常行为，不该按住用户，但第一次出网应当被看见 ——
  /// 之后同一轮的主机都收进工具卡的折叠行。
  @Published private(set) var firstNetworkHost: String?
  /// 已经从后端恢复过历史了。避免每次切回来都重拉一遍。
  private(set) var restored = false

  /// 这一轮有没有产出过任何东西（正文、推理、工具、批准、失败）。
  ///
  /// **这是最后一道兜底。** 无论什么原因，一轮跑完却一个字都没有，
  /// 界面都必须说句话 —— 否则用户看到的就是「发了消息没反应」，
  /// 而那和「App 坏了」在观感上毫无区别。实测踩过：key 过期时后端
  /// 一路静默到这里，界面空空如也。
  private var produced = false
  private var terminalEventSeen = false
  /// 用户按过「停」。
  ///
  /// `@Published` 是因为**按下去必须立刻有反应**：后端还要把合成结果补完
  /// 才会收流，中间这一两秒如果界面纹丝不动，用户只会认为按钮坏了
  /// （实机就是这么报的）。所以状态行马上改口说「正在停下」。
  @Published private(set) var cancelRequested = false

  private var jobID: String?
  /// 正在生成的那一条屏幕上显示到哪了。**逐帧的增长只在这里**，见 `StreamPacer`：
  /// 只有正在生成的那一行观察它，对话流与面板不随每个分片重画。
  let pacer = StreamPacer()
  private var stopWatchdog: Task<Void, Never>?
  private var client: AgentClient?
  private var task: Task<Void, Never>?
  /// 这一轮的分段计时（`AgentTiming`，默认关）。
  private var timing: AgentTiming?
  private var timingProvider = ""
  /// 正在流式接收的那条助手消息在 items 里的下标。
  private var streamingIndex: Int?

  init(projectID: String?, conversationID: String? = nil) {
    self.projectID = projectID
    self.conversationID = conversationID
  }

  var isEmpty: Bool { items.isEmpty }

  /// 此刻在做什么。等待时那一行显示它。
  ///
  /// 「正在思考」和「正在读 md/context.md」是两种等待 —— 用户对后者的耐心
  /// 要长得多，因为他知道机器在忙什么。只显示一个转圈的话，两者没有区别。
  var activity: String {
    if let tool = items.last(where: { $0.kind == .tool && $0.awaitingResult }) {
      // 英文摘要本身就是动名词（后端按界面语言说，「Searching …」），不用再接前缀
      return tool.summary.isEmpty
        ? L("正在跑 \(tool.toolName)", "Running \(tool.toolName)") : L("正在\(tool.summary)", tool.summary)
    }
    if cancelRequested { return L("正在停下…", "Stopping…") }
    if items.contains(where: { $0.kind == .approval && $0.decision == nil }) {
      return L("等你的决定", "Waiting for your decision")
    }
    // **「在想」和「在写」要分清楚。**
    //
    // 早先按 `streamingID == nil` 判，而 streamingIndex 在**推理的第一个
    // 分片**落地时就有值了 —— 于是模型还在推理，界面已经写着「正在作答」。
    // 实机截图里就是这样：卡里只有推理、一个字的正文都没有，状态却说在作答。
    // 推理模型一想就是几十秒，这句话错了，用户会以为答案马上就到。
    //
    // **而且只看这一轮。** 早先找的是整段记录里最后一条助手消息 —— 追问时那是**上一轮**
    // 的回答，于是新一轮一个字节都还没到，状态就写着「正在作答」；首字要等几秒的时候
    // （实测：冷连接加慢供应商 3–12 秒），用户看到的是「在作答」却一个字都没有。
    let thisTurn = items.lastIndex(where: { $0.kind == .user }).map { items[($0 + 1)...] } ?? items[...]
    if let latest = thisTurn.last(where: { $0.kind == .assistant }), !latest.text.isEmpty {
      return L("正在作答", "Answering")
    }
    return L("正在思考", "Thinking")
  }

  /// 这一轮是什么时候发出去的。**给界面报已等了多久用。**
  ///
  /// 长推理时屏幕上几十秒没有任何变化，用户分不清「还在想」和「卡死了」——
  /// 一个一直在走的秒数是最便宜也最有效的「还活着」信号。
  private(set) var askedAt: Date?

  /// 这一轮最后落在一条**有正文的回答**上。
  ///
  /// 模型偶尔会调完一串工具就收工，一个字都不说。那时活动卡之后空空如也，
  /// 用户无从判断是还在跑、坏了、还是它就这么结束了 —— 必须说清楚。
  private var endsWithAnswer: Bool {
    guard let last = items.last else { return false }
    return last.kind == .assistant && !last.text.isEmpty
  }

  /// 正在流式接收的那条消息。渲染时给它跟一个光标。
  var streamingID: UUID? {
    guard running, let index = streamingIndex, items.indices.contains(index) else { return nil }
    return items[index].id
  }

  struct PendingApproval: Equatable {
    let callID: String
    let tool: String
    let summary: String
    let expiresAt: Date
  }

  // MARK: - 历史恢复

  /// 从后端拉回此前的对话。
  ///
  /// 走 `/agent/transcript` 的投影接口，**不在 Swift 侧另写一套解析** ——
  /// 「有调用没结果就补一条合成结果」这条纪律只能有一份实现，
  /// 写两份必然漂移，而漂移的那份会让用户看到一段和模型看到的不一样的历史。
  func restore(base: URL) async {
    guard let projectID, !restored else { return }
    restored = true
    let raw = await AgentClient(base: base)
      .transcript(projectID: projectID, conversation: conversationID)
    guard !raw.isEmpty else { return }
    items = raw.compactMap(TranscriptItem.init(restored:))
  }

  // MARK: - 发问

  func ask(_ question: String, base: URL, provider: String, confirmed: [String] = []) {
    guard !running, !preparing else { return }
    preparing = true
    running = true
    produced = false
    terminalEventSeen = false
    cancelRequested = false
    usage = AgentUsage()
    askedAt = Date()
    pacer.reset()
    items.append(.user(question))
    streamingIndex = nil

    let client = AgentClient(base: base)
    self.client = client
    if AgentTiming.enabled {
      let timing = AgentTiming()
      timing.mark("ask")
      self.timing = timing
      timingProvider = provider
      client.timing = timing
      pacer.timing = timing
    }
    let stream =
      projectID.map {
        client.chat(
          projectID: $0, question: question, provider: provider,
          confirmed: confirmed, conversation: conversationID)
      } ?? client.deskChat(question: question, provider: provider)

    task = Task { [weak self] in
      do {
        for try await event in stream {
          guard let self else { return }
          if Task.isCancelled { return }
          self.absorb(event)
        }
        if let self, !self.terminalEventSeen, !self.cancelRequested {
          self.items.append(.failure(
            code: "STREAM_ENDED",
            message: UIText("模型连接在给出结论前结束了。工具结果已保留，可以重试这一轮。",
                            "The model connection ended before a conclusion. Tool results are kept; "
                              + "you can retry this turn.")))
        }
      } catch {
        if let self, !self.cancelRequested {
          self.items.append(.failure(code: "TRANSPORT", message: .verbatim(error.localizedDescription)))
        }
      }
      self?.finish()
    }
  }

  func cancel() {
    guard running, !cancelRequested else { return }
    cancelRequested = true
    guard let jobID else {
      task?.cancel(); client?.stop(); finish(); return
    }
    let client = self.client
    let projectID = self.projectID
    Task { await client?.cancel(projectID: projectID, jobID: jobID) }
    // 不立刻 stop()：后端还要把合成结果补完再收流，
    // 提前掐断的话那几条 tool_result 就到不了界面上（日志里仍然是全的）。
    //
    // **但不能无限等。** 正常路径上后端 0.03 秒就返回 aborted（实测），
    // 慢的是补合成结果那一段；真出了岔子（后端崩了、连接半死）就没人来
    // 收这个流了，而界面会永远停在「正在停下…」——那和按钮坏了没区别。
    // 兜底掐断：宁可少几条 tool_result 卡片（日志里仍然是全的），
    // 也不能把用户锁在一个转不完的圈里。
    stopWatchdog?.cancel()
    stopWatchdog = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.stopGrace))
      guard let self, self.running, self.cancelRequested else { return }
      self.items.append(.notice(UIText("这一轮已经停下。后端没有按时收流，界面先放开了。",
                                       "This turn has stopped. The backend didn't close the stream in time, "
                                         + "so the interface let go first.")))
      self.task?.cancel()
      self.client?.stop()
      self.finish()
    }
  }

  /// 按下「停」之后最多等多久。后端正常在毫秒级返回，这里给足余量
  /// 让它把合成结果补完 —— 超过就是真出岔子了。
  static let stopGrace: Double = 8

  func answer(_ approved: Bool, reason: String = "") {
    guard let pending, let jobID else { return }
    let client = self.client
    let projectID = self.projectID
    let callID = pending.callID
    self.pending = nil
    markDecision(callID: callID, approved: approved, reason: reason, timedOut: false)
    Task {
      await client?.approve(
        projectID: projectID, jobID: jobID, callID: callID,
        approved: approved, reason: reason)
    }
  }

  /// 超时按拒绝 —— 后端已经这么判了，界面要说清是超时而不是用户点的。
  func expireApproval() {
    guard let pending else { return }
    self.pending = nil
    markDecision(callID: pending.callID, approved: false, reason: "", timedOut: true)
  }

  // MARK: - 事件

  /// 把一个事件喂进来。**给断言用的缝** —— 定稿（`stream`/`flushStream`）
  /// 是这条链路上最容易静默出错的一段：丢掉最后几个字、或者把旁白排到
  /// 它后面那个工具调用之后，两种都不会报错，只会让记录悄悄失真。
  /// 提成 internal 才能让 `verify_agent_panel` 用合成事件钉住它。
  func ingest(_ event: AgentClient.Event) { absorb(event) }

  /// 把正在生成的那一条立刻定稿。断言里用它模拟「一轮收尾」。
  func drainForTesting() { flushStream() }

  /// 直接塞一条记录进去。**只给离屏出图与断言用** ——
  /// 版式、密度、层次这些必须用眼睛看，而看需要一段像样的记录。
  func seedForTesting(_ item: TranscriptItem) { items.append(item) }

  private func absorb(_ event: AgentClient.Event) {
    timing?.handled(event.name)
    switch event {
    case .text, .thinking, .toolCall, .approvalRequest, .failed:
      produced = true
    default:
      break
    }
    // **会往记录里添行、或者换掉正在生成的那一条的事件，先把它定稿再处理。**
    // 顺序是有意义的：一句旁白必须排在它之后那个工具调用前面，
    // 不定稿的话就会颠倒过来。
    //
    // 工具结果与执行强度只改已有的那几行、不影响先后，**不为它们打断**正在平滑
    // 铺开的字 —— 流中派发之后，工具结果可能在模型还在说话时回来。
    switch event {
    case .text, .thinking, .heartbeat, .usage, .toolResult, .enforcement:
      break
    default:
      flushStream()
    }
    switch event {
    case .messageStart(let id, _, _):
      if let id { jobID = id }
      // 新一轮开始：上一条助手消息已经定稿，不要再往里追加
      streamingIndex = nil

    case .text(let chunk):
      stream(chunk, thinking: false)

    case .thinking(let chunk):
      stream(chunk, thinking: true)

    case .toolCall(let call):
      streamingIndex = nil
      items.append(.tool(call))

    case .toolResult(let result):
      update(callID: result.callID) { $0.applyResult(result) }

    case .approvalRequest(let request):
      streamingIndex = nil
      let expiry = Date().addingTimeInterval(request.expiresIn)
      pending = PendingApproval(
        callID: request.callID, tool: request.tool,
        summary: request.summary, expiresAt: expiry)
      items.append(.approval(request, expiresAt: expiry))

    case .enforcement(let callID, let level, let reason):
      update(callID: callID) { $0.enforcement = level; $0.enforcementReason = reason }

    case .network(let hit):
      // 去重按「首次到达」保序：一次 clone 会往同一个主机发几十个请求，
      // 折叠行里重复几十遍没有信息量。
      update(callID: hit.callID) { item in
        if hit.allowed {
          if !item.hosts.contains(hit.target) { item.hosts.append(hit.target) }
        } else if !item.blockedHosts.contains(where: { $0.host == hit.target }) {
          item.blockedHosts.append((host: hit.target, reason: hit.reason))
        }
      }
      // **第一个主机出一条显眼但不阻塞的提示**。
      // 用 notice 而不是模态框：联网是正常行为，按住用户去点「知道了」
      // 会把它训练成无脑点同意 —— 逐次批准最后只会被一路点过去。
      if hit.first && hit.allowed {
        firstNetworkHost = hit.target
        items.append(.notice(UIText(
          "联网：agent 正在访问 \(hit.target)。这一轮访问过的主机都记在工具卡里。",
          "Network: the agent is reaching \(hit.target). Every host visited this turn is listed on its tool card.")))
      }

    case .usage(let value):
      usage = value

    case .done(let stop, let steps, let exhausted, _, let total):
      terminalEventSeen = true
      if !total.isEmpty { usage = total }
      if exhausted {
        // 上限现在是**防跑飞的兜底**（200），
        // 不再是工作上限。撞到它多半是真在原地打转，所以这句话的建议
        // 从「继续」换成「换个问法」—— 让一个已经转圈的循环接着转没有意义。
        // 历史仍然留着，真想接着做说一句「继续」也行。
        items.append(.notice(UIText(
          "走了 \(steps) 步还没收敛，按防跑飞的兜底停下了。多半是它在原地打转 —— 换个更具体的问法通常比让它继续更有效。",
          "Stopped by the runaway guard after \(steps) steps without converging. It was probably going in "
            + "circles — a more specific question usually works better than letting it continue.")))
      } else if stop == "aborted" {
        items.append(.notice(UIText("已取消。没来得及跑的调用都补了结果，历史仍然完整。",
                                    "Canceled. Calls that hadn't run got placeholder results, so the history stays intact.")))
      } else if stop == "error" {
        // 后端现在会单独发 error 事件，正常走不到这里。留着是因为
        // **旧后端仍会把失败发成 done**，而那条路的表现是整屏静默。
        items.append(.failure(code: "LLM_ERROR",
                              message: UIText("这一轮在模型那边失败了。", "This turn failed on the model's side.")))
      } else if !produced {
        // 兜底：走到这里说明既没报错也没产出。多半是模型真的返回了空，
        // 但无论什么原因，**沉默是最糟的呈现**。
        items.append(.notice(UIText("模型这一轮什么都没返回。再问一次，或者换一个模型试试。",
                                    "The model returned nothing this turn. Ask again, or try another model.")))
      } else if !endsWithAnswer {
        // **跑了一堆工具却不给答案**，实机遇到过。界面上的表现是活动卡之后
        // 空空如也，用户无从判断是还在跑、还是坏了、还是它就这么结束了。
        items.append(.notice(UIText(
          "它跑完工具就停下了，没有给出结论。追问一句「所以结论是什么」通常就能拿到。",
          "It stopped after running tools without a conclusion. Asking “so what's the conclusion?” usually gets it.")))
      }

    case .failed(let code, let message):
      terminalEventSeen = true
      // 后端给的原话只有一种语言（它按请求那一刻的界面语言说）
      items.append(.failure(code: code, message: .verbatim(message)))

    case .heartbeat:
      break
    }
  }

  /// 正文与推理的分片。**只在这一路第一次有字时改记录，之后只交给 pacer。**
  ///
  /// 从前的做法是攒到 50ms 再改一次记录 —— 每改一次，整个面板都要重算（对话流的
  /// 每一行、输入框、状态栏），历史越长越贵；而屏幕上的字照样一顿一顿地跳
  /// （实测 83% 的帧一个字不动，见 `StreamPacer`）。现在逐帧在长的部分只在 pacer 里，
  /// 只有正在生成的那一行观察它。
  ///
  /// **第一次有字是结构变化，必须进记录**：分组据「有没有正文」决定这一条进消息流
  /// 还是进过程卡（`AgentTranscript.group`），`activity` 据此分「在想」与「在写」。
  private func stream(_ chunk: String, thinking: Bool) {
    guard !chunk.isEmpty else { return }
    if let index = streamingIndex, items.indices.contains(index) {
      if thinking, items[index].thinking.isEmpty {
        items[index].thinking = chunk
      } else if !thinking, items[index].text.isEmpty {
        items[index].text = chunk
      }
    } else {
      var line = TranscriptItem.assistant("")
      if thinking { line.thinking = chunk } else { line.text = chunk }
      // 打上时间戳：活动卡要报「已处理多久」，而一段纯思考里没有工具可以借时间
      line.startedAt = Date()
      line.finishedAt = Date()
      pacer.reset()
      items.append(line)
      streamingIndex = items.count - 1
    }
    pacer.receive(chunk, thinking: thinking)
  }

  /// 把正在生成的那一条定稿：屏幕立刻补齐，已收到的全文写回记录。
  ///
  /// 收尾时必须走到这里 —— 丢掉的话回答会缺最后几个字，而那正是结论所在。
  private func flushStream() {
    guard let index = streamingIndex, items.indices.contains(index) else { return }
    let full = pacer.finish()
    guard items[index].text != full.text || items[index].thinking != full.thinking else { return }
    items[index].text = full.text
    items[index].thinking = full.thinking
    items[index].finishedAt = Date()
  }

  private func update(callID: String, _ change: (inout TranscriptItem) -> Void) {
    guard let index = items.lastIndex(where: { $0.kind == .tool && $0.callID == callID })
    else { return }
    change(&items[index])
  }

  private func markDecision(callID: String, approved: Bool, reason: String, timedOut: Bool) {
    guard let index = items.lastIndex(where: { $0.kind == .approval && $0.callID == callID })
    else { return }
    items[index].decision = TranscriptItem.Decision(
      approved: approved, reason: reason, timedOut: timedOut)
  }

  private func finish() {
    // 收尾前把正在生成的那一条定稿 —— 丢掉的话回答会缺最后几个字，
    // 而那正是结论所在。
    flushStream()
    if let timing {
      timing.mark("finished")
      timing.write(meta: [
        "project": projectID ?? "", "conversation": conversationID ?? "",
        "provider": timingProvider,
      ])
      self.timing = nil
      pacer.timing = nil
    }
    pacer.reset()
    stopWatchdog?.cancel()
    stopWatchdog = nil
    preparing = false
    running = false
    streamingIndex = nil
    pending = nil
    jobID = nil
    task = nil
  }
}

// MARK: - 一条记录

/// 对话流里的一条。做成带 kind 的结构体而不是 enum，是因为流式更新要**原地改**
/// （正文逐字追加、工具结果回填、执行强度事后挂上去），
/// enum 每次都要拆开重装，代码会难看很多。
struct TranscriptItem: Identifiable {
  enum Kind { case user, assistant, tool, approval, failure, notice }

  struct Decision: Equatable {
    let approved: Bool
    let reason: String
    let timedOut: Bool
  }

  let id = UUID()
  var kind: Kind
  var text = ""
  /// 推理过程。默认折起来 —— 它对判断「模型有没有理解题目」有用，
  /// 但常驻展开会把真正的回答挤下去。
  var thinking = ""

  // --- 工具 / 批准 ---
  var callID = ""
  var toolName = ""
  var summary = ""
  var preview = ""
  var truncated = false
  var isError = false
  /// 取消后补的合成结果。**必须与「工具报错了」分开显示** ——
  /// 一个是跑了但失败，一个是根本没跑，回放时这两件事完全不同。
  var synthetic = false
  var enforcement: String?
  var enforcementReason = ""
  /// 这次工具调用到达过的主机，按首次到达排序、已去重。
  ///
  /// **只有主机与端口**（`example.com`、`127.0.0.1:8080`）—— 路径与查询串
  /// 在后端就不存在，凭据常藏在查询串里。收进工具卡的折叠行；
  /// 每次调用的**第一个**主机另外出一条显眼但不阻塞的提示。
  var hosts: [String] = []
  /// 被代理拒掉的出网：`主机 → 原因`。这一条要显眼 —— 它说明 agent 试过
  /// 去它不该去的地方（多半是连回环），用户有权知道。
  var blockedHosts: [(host: String, reason: String)] = []
  var decision: Decision?
  var startedAt: Date?
  var finishedAt: Date?
  var expiresAt: Date?
  /// 工具还没回结果。界面上显示成「进行中」。
  var awaitingResult = false
  /// edit / write 带回来的结构化改动。**只有这两个工具有。**
  var diff: AgentClient.FileDiff?
  var code = ""
  /// 界面自己写下的那句话（提示、本地的失败说明）。**两种说法都存**，显示时按当前语言挑 ——
  /// 存成 String 的话，切换语言之前写下的那几条就停在旧语言里。`text` 里仍是中文那句
  /// （断言与导出照旧读它）；后端给的原话只有一种，`localized` 两边相同。
  var localized: UIText?
  /// 显示用的那句。
  var displayText: String { localized?.text ?? text }

  var duration: TimeInterval? {
    guard let startedAt, let finishedAt else { return nil }
    return finishedAt.timeIntervalSince(startedAt)
  }


  static func user(_ text: String) -> TranscriptItem {
    var item = TranscriptItem(kind: .user); item.text = text; return item
  }
  static func assistant(_ text: String) -> TranscriptItem {
    var item = TranscriptItem(kind: .assistant); item.text = text; return item
  }
  static func notice(_ text: UIText) -> TranscriptItem {
    var item = TranscriptItem(kind: .notice); item.text = text.zh; item.localized = text; return item
  }
  static func failure(code: String, message: UIText) -> TranscriptItem {
    var item = TranscriptItem(kind: .failure)
    item.code = code; item.text = message.zh; item.localized = message
    return item
  }
  static func tool(_ call: AgentClient.ToolCallEvent) -> TranscriptItem {
    var item = TranscriptItem(kind: .tool)
    item.callID = call.callID
    item.toolName = call.name
    item.summary = call.summary.isEmpty ? call.name : call.summary
    item.startedAt = Date()
    item.awaitingResult = true
    return item
  }
  static func approval(_ request: AgentClient.ApprovalEvent, expiresAt: Date) -> TranscriptItem {
    var item = TranscriptItem(kind: .approval)
    item.callID = request.callID
    item.toolName = request.tool
    item.summary = request.summary
    item.expiresAt = expiresAt
    return item
  }

  mutating func applyResult(_ result: AgentClient.ToolResultEvent) {
    preview = result.preview
    truncated = result.truncated
    isError = result.isError
    synthetic = result.synthetic
    if let level = result.enforcement {
      enforcement = level
      enforcementReason = result.enforcementReason
    }
    diff = result.diff
    finishedAt = Date()
    awaitingResult = false
  }

  /// 只留推理的那一半（给折叠卡）。
  ///
  /// **id 必须沿用原来的，不能新生成。** 试过新建一个 `TranscriptItem`，
  /// 那样每次重渲染都是一个新 UUID —— `ForEach` 每帧都认为这张卡换了，
  /// 展开状态被重置、视图反复重建。和 `MarkdownBlock.rule` 早先那个
  /// `UUID()` 是同一类坑：**身份里不许出现任何随机值。**
  ///
  /// 两半同号不会撞：`Row.id` 给活动行加了 `run:` 前缀。
  func reasoningOnly() -> TranscriptItem {
    var copy = self
    copy.text = ""
    return copy
  }

  /// 只留说出来那一半（给消息流）。id 沿用原来的 —— 流式那条要靠它
  /// 和 `session.streamingID` 对上，换了号光标就跟丢了。
  func spokenOnly() -> TranscriptItem {
    guard !thinking.isEmpty, !text.isEmpty else { return self }
    var copy = self
    copy.thinking = ""
    return copy
  }

  /// 从后端投影出来的历史条目重建。字段名与 `projects/session.py`
  /// 的 `derive_transcript()` 对应，改那边必须改这里。
  init?(restored raw: [String: Any]) {
    let kindName = raw["kind"] as? String ?? ""
    switch kindName {
    case "user": self.init(kind: .user)
    case "assistant": self.init(kind: .assistant)
    case "tool": self.init(kind: .tool)
    default: return nil
    }
    text = raw["text"] as? String ?? ""
    if kind == .tool {
      callID = raw["call_id"] as? String ?? ""
      toolName = raw["name"] as? String ?? "?"
      // 摘要由后端的 `summarise_call()` 算好带过来 —— 实时推送用的是同一个
      // 函数，两边必须是同一句话。之前这里写成 `summary = toolName`，
      // 恢复出来的每一行都是「bash bash」，把工具名说了两遍。
      summary = raw["summary"] as? String ?? toolName
      preview = raw["preview"] as? String ?? ""
      isError = raw["is_error"] as? Bool ?? false
      synthetic = raw["synthetic"] as? Bool ?? false
      let detail = raw["detail"] as? [String: Any] ?? [:]
      if let level = detail["enforcement"] as? String, level != "full" {
        enforcement = level
        enforcementReason = detail["enforcement_reason"] as? String ?? ""
      }
      // 改动的 diff 也要恢复：退出重开之后「它到底改了什么」不该只剩一句
      // 「已改 md/context.md」。投影里带的是同一份 detail。
      diff = AgentClient.FileDiff(detail["diff"] as? [String: Any])
      if let verdict = raw["decision"] as? [String: Any] {
        decision = Decision(
          approved: verdict["approved"] as? Bool ?? false,
          reason: verdict["reason"] as? String ?? "", timedOut: false)
      }
    }
  }

  private init(kind: Kind) { self.kind = kind }
}
