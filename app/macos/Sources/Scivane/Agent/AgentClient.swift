import Foundation

/// 与 agent 对话流的 SSE 客户端。
///
/// **不要用 `URLSession.bytes(for:).lines`。**
/// 那条 API 在本项目的链路上拿到 HTTP 200 之后彻底静默，一个事件都不投递，
/// 而同一个接口用 curl 收得完全正常 —— 表现是界面永远停在等待，
/// 排查起来毫无头绪。这里照 `OCRClient` 的 `URLSessionDataDelegate.didReceive`
/// 写：几十字节的分片就立刻回调。
///
/// **事件名是跨语言契约**，必须和
/// `services/reader/src/scivane_reader/api/sse.py` 的 `AgentEvent` 一字不差。
/// 对不上的表现同样是「界面一直转」，因为解析不出来的帧会被静静丢掉。
final class AgentClient: NSObject, @unchecked Sendable {

  enum Event {
    /// 一轮（一次模型请求）开始。第一帧带 job_id，取消与批准都要用它。
    case messageStart(jobID: String?, step: Int, model: String)
    case text(String)
    case thinking(String)
    case toolCall(ToolCallEvent)
    case toolResult(ToolResultEvent)
    case approvalRequest(ApprovalEvent)
    /// 沙箱执行强度不足。**这是可报告的事实，必须让用户看见**。
    case enforcement(callID: String, level: String, reason: String)
    /// agent 经审计代理到达了一个主机。
    ///
    /// **与 enforcement 分开。** 那个的含义是「边界没兑现承诺」，是警告；
    /// 联网是**正常行为**。混在一起等于给正常行为挂琥珀色警告，
    /// 看几次之后两种都没人看了。
    case network(NetworkEvent)
    case usage(AgentUsage)
    case done(stop: String, steps: Int, exhausted: Bool, text: String, usage: AgentUsage)
    case failed(code: String, message: String)
    case heartbeat

    /// 线上的事件名（`sse.py` 的 `AgentEvent`）。给分段计时用：两边的记录按它对齐。
    var name: String {
      switch self {
      case .messageStart: return "message_start"
      case .text: return "text"
      case .thinking: return "thinking"
      case .toolCall: return "tool_call"
      case .toolResult: return "tool_result"
      case .approvalRequest: return "approval_request"
      case .enforcement: return "enforcement"
      case .network: return "network"
      case .usage: return "usage"
      case .done: return "done"
      case .failed: return "error"
      case .heartbeat: return "heartbeat"
      }
    }
  }

  /// 一次出网。**只有主机与端口** —— 路径与查询串在后端就不存在
  /// （凭据常藏在查询串里）。
  struct NetworkEvent {
    let callID: String
    let host: String
    let port: Int
    let method: String
    let allowed: Bool
    /// 被拒时的稳定 code（LOOPBACK / PRIVATE / NO_GRANT …），放行时为空。
    let reason: String
    /// 这次工具调用的第一个主机 —— 界面据此决定出显眼的卡还是收进折叠行。
    let first: Bool

    /// 给界面的一行：`example.com:443`。443 与 80 不必显示端口。
    var target: String {
      (port == 443 || port == 80) ? host : "\(host):\(port)"
    }
  }

  struct ToolCallEvent {
    let callID: String
    let name: String
    /// 人类读得懂的一句话，后端生成（「搜索 对比损失」「取回 X，放进 code/Y」）。
    let summary: String
    let arguments: [String: Any]
  }

  struct ToolResultEvent {
    let callID: String
    let name: String
    let preview: String
    let truncated: Bool
    let isError: Bool
    /// 取消之后补的合成结果 —— 界面要能分辨「工具报错了」和「工具根本没跑」。
    let synthetic: Bool
    let enforcement: String?
    let enforcementReason: String
    /// 改文件时后端带回来的结构化 diff。**只有 edit / write 有。**
    let diff: FileDiff?
  }

  /// 一次改动，拆成行 —— 界面据此画增删着色与行号。
  ///
  /// 后端给的是结构化的行而不是一段 unified diff 文本：文本只能当等宽字块
  /// 贴上去，行号、着色、折叠都做不了。
  struct FileDiff {
    struct Row {
      /// same / add / remove / gap
      let kind: String
      let oldNo: Int?
      let newNo: Int?
      let text: String
      /// `gap` 那一行略过了几行。有它时界面按当前语言说；没有（这个字段之前的日志）就照 `text` 显示 ——
      /// 后端在工具执行期说中文，`text` 总是中文
      var skipped: Int? = nil
    }
    let path: String
    let rows: [Row]
    let added: Int
    let removed: Int
    /// 后端按 `DIFF_MAX_LINES` 截断过 —— 界面要说出来，不能假装这就是全部。
    let truncated: Bool

    init?(_ raw: [String: Any]?) {
      guard let raw, let rows = raw["rows"] as? [[String: Any]] else { return nil }
      self.path = raw["path"] as? String ?? ""
      self.added = raw["added"] as? Int ?? 0
      self.removed = raw["removed"] as? Int ?? 0
      self.truncated = raw["truncated"] as? Bool ?? false
      self.rows = rows.map {
        Row(kind: $0["kind"] as? String ?? "same", oldNo: $0["old"] as? Int,
            newNo: $0["new"] as? Int, text: $0["text"] as? String ?? "", skipped: $0["skipped"] as? Int)
      }
    }
  }

  struct ApprovalEvent {
    let callID: String
    let tool: String
    let summary: String
    let expiresIn: Double
  }

  private let base: URL
  /// 这一轮的分段计时（`AgentTiming`）。没开计时时是 nil。
  var timing: AgentTiming?
  private var session: URLSession!
  private var task: URLSessionDataTask?
  private var continuation: AsyncThrowingStream<Event, Error>.Continuation?
  private var buffer = Data()
  /// 非 200 时响应体不是 SSE，而是一段 JSON 错误。收进这里，收尾时翻成 error 事件。
  private var httpStatus = 200
  private var errorBody = Data()

  init(base: URL) {
    self.base = base
    super.init()
    let config = URLSessionConfiguration.ephemeral
    // 有心跳保活，这里只是兜底。一轮里可能跑几个几十秒的沙箱命令。
    config.timeoutIntervalForRequest = 900
    config.timeoutIntervalForResource = 3 * 3600
    config.waitsForConnectivity = false
    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }

  deinit { session?.invalidateAndCancel() }

  /// 在一个项目里对话（读者那层）。
  /// - Parameter conversation: 这一轮说给哪条对话听。传 nil 时后端接最近那条。
  func chat(
    projectID: String, question: String, provider: String,
    confirmed: [String] = [], conversation: String? = nil
  ) -> AsyncThrowingStream<Event, Error> {
    var body: [String: Any] = [
      "question": question, "provider": provider, "confirmed": confirmed,
    ]
    if let conversation { body["conversation"] = conversation }
    return stream(path: "projects/\(projectID)/agent/chat", body: body)
  }

  /// 和书房对话（只见清单那层）。
  func deskChat(question: String, provider: String) -> AsyncThrowingStream<Event, Error> {
    stream(path: "agent/chat", body: ["question": question, "provider": provider])
  }

  private func stream(path: String, body: [String: Any]) -> AsyncThrowingStream<Event, Error> {
    AsyncThrowingStream { continuation in
      self.continuation = continuation
      var request = URLRequest(backend: base.appendingPathComponent(path))
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
      do {
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
      } catch {
        continuation.finish(throwing: error)
        return
      }
      let task = session.dataTask(with: request)
      self.task = task
      continuation.onTermination = { [weak task] _ in task?.cancel() }
      timing?.mark("request")
      task.resume()
    }
  }

  // MARK: - 旁路请求
  //
  // 批准与取消都是**另起一个请求**，不能占着对话那条流 ——
  // 循环正挂在 Future 上等裁决，用同一条连接回答等于自己等自己。

  func approve(projectID: String?, jobID: String, callID: String, approved: Bool, reason: String)
    async
  {
    let path = projectID.map { "projects/\($0)/agent/approve" } ?? "agent/approve"
    await post(path, [
      "job_id": jobID, "call_id": callID, "approved": approved, "reason": reason,
    ])
  }

  func cancel(projectID: String?, jobID: String) async {
    let path = projectID.map { "projects/\($0)/agent/cancel" } ?? "agent/cancel"
    await post(path, ["job_id": jobID])
  }

  /// 恢复这个项目此前的对话记录。
  ///
  /// 走后端的投影接口，**不在这里重写一套「缺结果要补」的配对逻辑** ——
  /// 写两份必然漂移，而漂移的那份会让用户看到一段和模型看到的不一样的历史。
  /// - Parameter conversation: 要恢复哪条对话。传 nil 时后端给最近那条。
  func transcript(projectID: String, conversation: String? = nil) async -> [[String: Any]] {
    var components = URLComponents(
      url: base.appendingPathComponent("projects/\(projectID)/agent/transcript"),
      resolvingAgainstBaseURL: false)
    if let conversation {
      components?.queryItems = [URLQueryItem(name: "conversation", value: conversation)]
    }
    guard let url = components?.url else { return [] }
    var request = URLRequest(backend: url)
    request.timeoutInterval = 15
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200,
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let items = root["items"] as? [[String: Any]]
    else { return [] }
    return items
  }

  private func post(_ path: String, _ body: [String: Any]) async {
    var request = URLRequest(backend: base.appendingPathComponent(path))
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    _ = try? await URLSession.shared.data(for: request)
  }

  func stop() {
    task?.cancel()
    continuation?.finish()
  }

  // MARK: - 分帧

  /// SSE 以空行分帧。按 \n\n 切，切不完整就留在缓冲里等下一片。
  private func drain() {
    let separator = Data("\n\n".utf8)
    while let range = buffer.range(of: separator) {
      let frame = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
      buffer.removeSubrange(buffer.startIndex..<range.upperBound)
      guard let text = String(data: frame, encoding: .utf8) else { continue }
      if let event = Self.decode(frame: text) {
        if let timing {
          // 正文与推理另记字数（UTF-8 字节），和 pacer 发布的字数是同一把尺子
          var chars = 0
          if case .text(let piece) = event { chars = piece.utf8.count }
          if case .thinking(let piece) = event { chars = piece.utf8.count }
          timing.received(event.name, bytes: frame.count + separator.count, text: chars)
        }
        continuation?.yield(event)
      }
    }
  }

  static func decode(frame: String) -> Event? {
    var name = ""
    var payload = ""
    for line in frame.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("event:") {
        name = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
      } else if line.hasPrefix("data:") {
        payload += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
      }
    }
    guard !name.isEmpty, let data = payload.data(using: .utf8),
      let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    switch name {
    case "message_start":
      return .messageStart(
        jobID: d["job_id"] as? String, step: d["step"] as? Int ?? 0,
        model: d["model"] as? String ?? "")
    case "text":
      return .text(d["text"] as? String ?? "")
    case "thinking":
      return .thinking(d["text"] as? String ?? "")
    case "tool_call":
      return .toolCall(ToolCallEvent(
        callID: d["call_id"] as? String ?? "", name: d["name"] as? String ?? "?",
        summary: d["summary"] as? String ?? "", arguments: d["arguments"] as? [String: Any] ?? [:]))
    case "tool_result":
      let detail = d["detail"] as? [String: Any] ?? [:]
      let level = detail["enforcement"] as? String
      return .toolResult(ToolResultEvent(
        callID: d["call_id"] as? String ?? "", name: d["name"] as? String ?? "?",
        preview: d["preview"] as? String ?? "", truncated: d["truncated"] as? Bool ?? false,
        isError: d["is_error"] as? Bool ?? false, synthetic: d["synthetic"] as? Bool ?? false,
        enforcement: level == "full" ? nil : level,
        enforcementReason: detail["enforcement_reason"] as? String ?? "",
        diff: FileDiff(detail["diff"] as? [String: Any])))
    case "approval_request":
      return .approvalRequest(ApprovalEvent(
        callID: d["call_id"] as? String ?? "", tool: d["tool"] as? String ?? "?",
        summary: d["summary"] as? String ?? "", expiresIn: d["expires_in"] as? Double ?? 120))
    case "enforcement":
      return .enforcement(
        callID: d["call_id"] as? String ?? "", level: d["level"] as? String ?? "partial",
        reason: d["reason"] as? String ?? "")
    case "network":
      return .network(NetworkEvent(
        callID: d["call_id"] as? String ?? "", host: d["host"] as? String ?? "?",
        port: d["port"] as? Int ?? 0, method: d["method"] as? String ?? "?",
        allowed: d["allowed"] as? Bool ?? false, reason: d["reason"] as? String ?? "",
        first: d["first"] as? Bool ?? false))
    case "usage":
      return .usage(AgentUsage(d))
    case "done":
      return .done(
        stop: d["stop"] as? String ?? "stop", steps: d["steps"] as? Int ?? 0,
        exhausted: d["exhausted"] as? Bool ?? false, text: d["text"] as? String ?? "",
        usage: AgentUsage(d["usage"] as? [String: Any] ?? [:]))
    case "error":
      return .failed(code: d["code"] as? String ?? "INTERNAL",
                     message: d["message"] as? String ?? L("未知错误", "Unknown error"))
    case "heartbeat":
      return .heartbeat
    default:
      return nil
    }
  }
}

/// token 用量。缓存命中与写入分开记 —— 缓存是否生效是本产品最关心的指标，
/// 合成一个数字就看不出来了。
struct AgentUsage: Equatable {
  var input = 0
  var output = 0
  var cacheRead = 0
  var cacheWrite = 0

  init() {}
  init(_ d: [String: Any]) {
    input = d["input_tokens"] as? Int ?? 0
    output = d["output_tokens"] as? Int ?? 0
    cacheRead = d["cache_read_tokens"] as? Int ?? 0
    cacheWrite = d["cache_write_tokens"] as? Int ?? 0
  }

  var isEmpty: Bool { input == 0 && output == 0 && cacheRead == 0 }

  /// 「读了多少、出了多少、其中多少是缓存」。缓存比例是省钱的关键指标。
  var label: String {
    var parts = ["↓\(input + cacheRead)", "↑\(output)"]
    if cacheRead > 0 { parts.append(L("缓存 \(cacheRead)", "cache \(cacheRead)")) }
    return parts.joined(separator: " · ")
  }
}

extension AgentClient: URLSessionDataDelegate {

  /// 先看状态码。非 200 的响应体是一段 JSON 错误，不是 SSE ——
  /// 当成 SSE 去分帧只会静静地什么都解析不出来，界面一直转。
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse
  ) async -> URLSession.ResponseDisposition {
    httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
    timing?.mark("response")
    return .allow
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard httpStatus == 200 else {
      errorBody.append(data)
      return
    }
    buffer.append(data)
    drain()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if httpStatus != 200 {
      // 最常见的是 409（正文没确认 / 项目还没有正文）与 404（provider 没注册）。
      // 只显示「请求失败」的话，用户根本不知道该去点什么，所以把 detail 带出来。
      let detail =
        (try? JSONSerialization.jsonObject(with: errorBody) as? [String: Any])?["detail"] as? String
      continuation?.yield(.failed(code: "HTTP_\(httpStatus)",
                                  message: detail ?? L("服务端返回 \(httpStatus)", "The service returned \(httpStatus)")))
      continuation?.finish()
    } else if let error, (error as NSError).code != NSURLErrorCancelled {
      continuation?.finish(throwing: error)
    } else {
      continuation?.finish()
    }
    continuation = nil
    buffer.removeAll()
    errorBody.removeAll()
    httpStatus = 200
  }
}
