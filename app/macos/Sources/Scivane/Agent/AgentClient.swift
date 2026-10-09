import Foundation

/// SSE client for the agent conversation stream.
///
/// Not URLSession.bytes(for:).lines: on this path it goes silent after the 200 and delivers no
/// events, while curl receives the same stream fine. URLSessionDataDelegate.didReceive (as in
/// OCRClient) is called for every chunk.
///
/// Event names must match AgentEvent in api/sse.py exactly; frames that don't parse are dropped
/// silently and the UI just keeps spinning.
final class AgentClient: NSObject, @unchecked Sendable {

  enum Event {
    /// First frame carries the job_id, needed to cancel and to approve.
    case messageStart(jobID: String?, step: Int, model: String)
    case text(String)
    case thinking(String)
    case toolCall(ToolCallEvent)
    case toolResult(ToolResultEvent)
    case approvalRequest(ApprovalEvent)
    /// Partial sandbox enforcement; always shown to the user.
    case enforcement(callID: String, level: String, reason: String)
    /// A host the agent reached through the audit proxy. Separate from enforcement: that one is a
    /// warning, this is normal behaviour, and warning about it would teach people to ignore both.
    case network(NetworkEvent)
    case usage(AgentUsage)
    /// sent before each request, after a compaction, and at the end of the turn
    case context(ContextReport)
    /// start / done / failed
    case compaction(CompactionEvent)
    case done(stop: String, steps: Int, exhausted: Bool, text: String, usage: AgentUsage)
    case failed(code: String, message: String)
    case heartbeat

    /// Wire name (AgentEvent in sse.py); timing records on both sides are aligned by it.
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
      case .context: return "context"
      case .compaction: return "compaction"
      case .done: return "done"
      case .failed: return "error"
      case .heartbeat: return "heartbeat"
      }
    }
  }

  /// Host and port only: the backend never has the path or query string (where credentials hide).
  struct NetworkEvent {
    let callID: String
    let host: String
    let port: Int
    let method: String
    let allowed: Bool
    /// stable code when refused (LOOPBACK / PRIVATE / NO_GRANT ...); empty when allowed
    let reason: String
    /// first host of this tool call: gets a visible card, later ones fold into a row
    let first: Bool

    /// 443 and 80 are shown without the port
    var target: String {
      (port == 443 || port == 80) ? host : "\(host):\(port)"
    }
  }

  struct ToolCallEvent {
    let callID: String
    let name: String
    /// written by the backend for people
    let summary: String
    let arguments: [String: Any]
  }

  struct ToolResultEvent {
    let callID: String
    let name: String
    let preview: String
    let truncated: Bool
    let isError: Bool
    /// filled in after a cancel; the UI must tell "the tool failed" from "the tool never ran"
    let synthetic: Bool
    let enforcement: String?
    let enforcementReason: String
    /// edit and write only
    let diff: FileDiff?
  }

  /// A change as structured rows, so the UI can draw line numbers, colours and folds; a unified diff
  /// could only be pasted as a monospaced block.
  struct FileDiff {
    struct Row {
      let kind: String
      let oldNo: Int?
      let newNo: Int?
      let text: String
      /// Lines skipped by a `gap` row, phrased in the UI language. Missing in older logs: show `text`,
      /// which is always Chinese since tools run in Chinese.
      var skipped: Int? = nil
    }
    let path: String
    let rows: [Row]
    let added: Int
    let removed: Int
    /// cut at DIFF_MAX_LINES; the UI must say so
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
  /// nil unless timing is enabled
  var timing: AgentTiming?
  private var session: URLSession!
  private var task: URLSessionDataTask?
  private var continuation: AsyncThrowingStream<Event, Error>.Continuation?
  private var buffer = Data()
  /// A non-200 body is a JSON error, not SSE; collected here and turned into an error event at the end.
  private var httpStatus = 200
  private var errorBody = Data()

  init(base: URL) {
    self.base = base
    super.init()
    let config = URLSessionConfiguration.ephemeral
    // a fallback only: heartbeats keep the stream alive, and a turn may run sandbox commands for minutes
    config.timeoutIntervalForRequest = 900
    config.timeoutIntervalForResource = 3 * 3600
    config.waitsForConnectivity = false
    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }

  deinit { session?.invalidateAndCancel() }

  /// Chat inside a project (the reader).
  /// - Parameter conversation: nil means the most recent one.
  func chat(
    projectID: String, question: String, provider: String,
    conversation: String? = nil, images: [ComposerImage] = []
  ) -> AsyncThrowingStream<Event, Error> {
    var body: [String: Any] = ["question": question, "provider": provider]
    if let conversation { body["conversation"] = conversation }
    if !images.isEmpty {
      // the backend reads the type from the bytes; only the data goes
      body["images"] = images.map { ["data": $0.data.base64EncodedString()] }
    }
    return stream(path: "projects/\(projectID)/agent/chat", body: body)
  }

  /// Chat with the librarian.
  func deskChat(question: String, provider: String) -> AsyncThrowingStream<Event, Error> {
    stream(path: "agent/chat", body: ["question": question, "provider": provider])
  }

  /// Compact a conversation by hand. Same stream shape as chat (job_id first, same /cancel,
  /// done / error); progress arrives as `compaction` events and done's stop is `compacted`.
  func compact(projectID: String, provider: String, conversation: String? = nil)
    -> AsyncThrowingStream<Event, Error>
  {
    var body: [String: Any] = ["provider": provider]
    if let conversation { body["conversation"] = conversation }
    return stream(path: "projects/\(projectID)/agent/compact", body: body)
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

  // MARK: - Side requests
  //
  // Approval and cancel are separate requests: the loop is blocked waiting for the verdict, so
  // answering on the chat stream would wait on itself.

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

  /// Restore a conversation from the backend's projection, rather than re-implementing the pairing
  /// of missing results here; a second copy would drift from what the model sees.
  /// - Parameter conversation: nil means the most recent one.
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

  /// Context occupancy before the next question; during a turn it comes from `context` events.
  /// nil when unavailable.
  func context(projectID: String, conversation: String?, provider: String?) async -> ContextReport? {
    var components = URLComponents(
      url: base.appendingPathComponent("projects/\(projectID)/agent/context"),
      resolvingAgainstBaseURL: false)
    var query: [URLQueryItem] = []
    if let conversation { query.append(URLQueryItem(name: "conversation", value: conversation)) }
    if let provider { query.append(URLQueryItem(name: "provider", value: provider)) }
    components?.queryItems = query.isEmpty ? nil : query
    guard let url = components?.url else { return nil }
    var request = URLRequest(backend: url)
    request.timeoutInterval = 15
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200,
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return ContextReport(root)
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

  // MARK: - Framing

  /// Frames end with a blank line; an incomplete one stays buffered for the next chunk.
  private func drain() {
    let separator = Data("\n\n".utf8)
    while let range = buffer.range(of: separator) {
      let frame = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
      buffer.removeSubrange(buffer.startIndex..<range.upperBound)
      guard let text = String(data: frame, encoding: .utf8) else { continue }
      if let event = Self.decode(frame: text) {
        if let timing {
          // UTF-8 bytes, the same unit the pacer publishes
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
    case "context":
      return .context(ContextReport(d))
    case "compaction":
      return .compaction(CompactionEvent(d))
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

/// Cache reads and writes are kept apart: whether caching works is the number that matters most.
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

  var label: String {
    var parts = ["↓\(input + cacheRead)", "↑\(output)"]
    if cacheRead > 0 { parts.append(L("缓存 \(cacheRead)", "cache \(cacheRead)")) }
    return parts.joined(separator: " · ")
  }
}

extension AgentClient: URLSessionDataDelegate {

  /// Non-200 bodies are JSON errors, not SSE; framing them as SSE would parse nothing and the UI
  /// would spin forever.
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
      // Mostly 409 (text not confirmed, or none yet) and 404 (unknown provider). Show the detail, or the
      // user has no idea what to fix.
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
