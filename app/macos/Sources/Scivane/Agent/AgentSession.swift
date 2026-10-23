import Foundation
import SwiftUI

/// Transcript and run state of one agent level: the librarian, or one conversation in a project.
@MainActor
final class AgentSession: ObservableObject {

  /// nil is the librarian
  let projectID: String?

  /// Together with projectID this is the session's identity. Switching conversations switches
  /// instances; clearing this one instead would let a running turn write into the new conversation.
  /// Always nil for the librarian.
  let conversationID: String?

  @Published private(set) var items: [TranscriptItem] = []
  @Published private(set) var running = false
  /// locks sending before the job id arrives, so a double click can't start two overlapping requests
  @Published private(set) var preparing = false
  /// The backend still holds this conversation although our own stream ended: the write lock
  /// follows the turn's own life, not whoever listens to it, so the turn runs on and its answer
  /// lands in the log. Keeps the composer locked instead of letting a question be refused.
  @Published private(set) var backendBusy = false
  @Published private(set) var usage = AgentUsage()
  /// Window occupancy of one request, not the turn's total (`usage`). Updated by `context` events
  /// while running; when idle, fetched with refreshContext.
  @Published private(set) var context: ContextReport?
  /// a manual compaction rather than a question
  @Published private(set) var compacting = false
  /// non-nil: the composer gives way to the approval card
  @Published private(set) var pending: PendingApproval?
  /// First host reached this turn: visible but not blocking. Later hosts fold into the tool card.
  @Published private(set) var firstNetworkHost: String?
  private(set) var restored = false

  /// Whether this turn showed anything at all (text, tools, approvals, failures; reasoning is never
  /// shown). The last safety net: a turn that ends with nothing must still say something, or it looks
  /// broken. An expired key once ended up exactly here.
  private var produced = false
  /// This turn asks an edited question again. When the backend never took it (refused, cut off
  /// before its first frame) the transcript, already cut at that question, reloads from the log.
  private var replacing = false
  /// The cut may also have passed a question the backend never numbered, whose turn the log may
  /// still hold: reload after the turn rather than guess.
  private var reloadAfterTurn = false
  private var base: URL?
  private var terminalEventSeen = false
  /// This turn was refused as CONVERSATION_BUSY: the previous one still holds the conversation.
  private var heldByBackend = false
  /// Published so the button reacts at once: the backend still fills in synthetic results before
  /// closing the stream, and a second of stillness reads as a broken button.
  @Published private(set) var cancelRequested = false

  private var jobID: String?
  /// The streaming message's visible length. Per-frame growth lives only here; only the streaming
  /// row observes it, so the transcript and panel don't redraw per chunk.
  let pacer = StreamPacer()
  /// A tool call being written, or a model gone quiet; only the status line observes it.
  let pulse = TurnPulse()
  private var stopWatchdog: Task<Void, Never>?
  private var client: AgentClient?
  private var task: Task<Void, Never>?
  /// off by default
  private var timing: AgentTiming?
  private var timingProvider = ""
  /// index in items of the message being streamed
  private var streamingIndex: Int?

  init(projectID: String?, conversationID: String? = nil) {
    self.projectID = projectID
    self.conversationID = conversationID
  }

  var isEmpty: Bool { items.isEmpty }

  /// Shown in the waiting line. "Thinking" and "reading md/context.md" are different waits.
  var activity: String {
    // Not ours any more, but still running: say so, or the status line would look idle while the
    // answer is on its way into the log.
    if backendBusy && !running {
      return L("上一轮还在后台跑", "The previous turn is still running")
    }
    if let last = items.last, last.kind == .compaction, last.compaction?.state == .running {
      return L("正在压缩上下文", "Compacting context")
    }
    if let tool = items.last(where: { $0.kind == .tool && $0.awaitingResult }) {
      // English summaries already start with a gerund ("Searching ..."), no prefix needed
      return tool.summary.isEmpty
        ? L("正在跑 \(tool.toolName)", "Running \(tool.toolName)") : L("正在\(tool.summary)", tool.summary)
    }
    if cancelRequested { return L("正在停下…", "Stopping…") }
    if items.contains(where: { $0.kind == .approval && $0.decision == nil }) {
      return L("等你的决定", "Waiting for your decision")
    }
    // Writing only while this turn's last row is its words: after a call finishes the model is
    // thinking again, even if it spoke before the call. Searching the whole transcript found the
    // previous turn's answer before this turn's first byte.
    let thisTurn = items.lastIndex(where: { $0.kind == .user }).map { items[($0 + 1)...] } ?? items[...]
    if let latest = thisTurn.last, latest.kind == .assistant, !latest.text.isEmpty {
      return L("正在作答", "Answering")
    }
    return L("正在思考", "Thinking")
  }

  /// For the elapsed-time display: during long reasoning a ticking counter is the cheapest sign of
  /// life.
  private(set) var askedAt: Date?

  /// Models sometimes run tools and stop without a word; that must be said explicitly.
  private var endsWithAnswer: Bool {
    guard let last = items.last else { return false }
    return last.kind == .assistant && !last.text.isEmpty
  }

  /// gets the caret
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

  // MARK: - Restoring history

  /// Uses the backend's /agent/transcript projection rather than parsing here: filling in results
  /// for calls without one must have a single implementation.
  ///
  /// A project session without a conversation is a new chat and restores nothing. Asked without one,
  /// the backend answers with the most recent conversation; that transcript would stay in this
  /// session and come back under "New Chat" once the conversation is deleted.
  func restore(base: URL) async {
    guard let projectID, let conversationID, !restored else { return }
    restored = true
    let raw = await AgentClient(base: base)
      .transcript(projectID: projectID, conversation: conversationID)
    // A question sent while this was in flight owns the transcript now; the projection of a turn
    // still running would show its tools as never run.
    guard !raw.isEmpty, !running, items.isEmpty else { return }
    items = raw.compactMap(TranscriptItem.init(restored:))
  }

  /// A conversation created just now has nothing to restore.
  func startFresh() { restored = true }

  /// Not while running: events carry the live numbers, and the idle forecast would overwrite them.
  func refreshContext(base: URL, provider: String?) async {
    guard let projectID, !running else { return }
    let report = await AgentClient(base: base)
      .context(projectID: projectID, conversation: conversationID, provider: provider)
    // an unchanged report must not publish: the whole transcript observes this session
    guard let report, !running, report != context else { return }
    context = report
  }

  // MARK: - Compaction

  /// Manual compaction (POST .../agent/compact). Same receiving path as asking: job id, cancel,
  /// watchdog and wrap-up all apply, and a cancelled compaction leaves nothing in the log.
  func compact(base: URL, provider: String) {
    // a new chat has nothing to compact; without a conversation the backend would pick another one
    guard let projectID, conversationID != nil, !locked else { return }
    preparing = true
    running = true
    compacting = true
    produced = false
    terminalEventSeen = false
    cancelRequested = false
    askedAt = Date()
    streamingIndex = nil

    let client = AgentClient(base: base)
    self.client = client
    let stream = client.compact(projectID: projectID, provider: provider, conversation: conversationID)
    task = Task { [weak self] in
      do {
        for try await event in stream {
          guard let self else { return }
          if Task.isCancelled { return }
          self.absorb(event)
        }
        if let self, !self.terminalEventSeen, !self.cancelRequested {
          self.endCompaction(UIText("连接提前结束了", "The connection ended early"))
        }
      } catch {
        if let self, !self.cancelRequested {
          self.endCompaction(.verbatim(error.localizedDescription))
        }
      }
      self?.finish()
    }
  }

  /// start opens a card; done / failed update the same card in place.
  private func applyCompaction(_ event: CompactionEvent) {
    switch event.phase {
    case "start":
      streamingIndex = nil
      items.append(.compaction(TranscriptItem.Compaction(state: .running, trigger: event.trigger)))
    case "done":
      let result = TranscriptItem.Compaction(
        state: .done, trigger: event.trigger, summary: event.summary, turns: event.turns,
        kept: event.kept, before: event.before, after: event.after)
      if let index = runningCompaction {
        items[index].compaction = result
      } else {
        items.append(.compaction(result))
      }
    default:
      endCompaction(.verbatim(event.message))
    }
  }

  private var runningCompaction: Int? {
    items.lastIndex { $0.kind == .compaction && $0.compaction?.state == .running }
  }

  /// Mark the running card failed, or add a notice if it never started (e.g. nothing to compact).
  private func endCompaction(_ message: UIText) {
    if let index = runningCompaction {
      items[index].compaction?.state = .failed
      items[index].localized = message
      items[index].text = message.zh
    } else {
      items.append(.notice(message))
    }
  }

  // MARK: - Asking

  /// `replacing` is a question asked earlier, edited: it and everything after it leave the
  /// transcript, and the backend drops the same turns from the conversation (its log keeps them).
  func ask(
    _ question: String, base: URL, provider: String, images: [ComposerImage] = [],
    replacing original: UUID? = nil
  ) {
    guard !locked else { return }
    var rewind: Int?
    replacing = false
    reloadAfterTurn = false
    if let original {
      guard let index = items.firstIndex(where: { $0.id == original && $0.kind == .user }) else { return }
      // the librarian keeps no history, so cutting the transcript is all an edit needs there
      if projectID != nil {
        rewind = keptTurns(before: original)
        replacing = true
        reloadAfterTurn = items[..<index].contains { $0.kind == .user && $0.turn == nil }
      }
      items.removeSubrange(index...)
    }
    preparing = true
    running = true
    produced = false
    terminalEventSeen = false
    cancelRequested = false
    usage = AgentUsage()
    askedAt = Date()
    self.base = base
    pacer.reset()
    items.append(.user(question, images: images.map(TranscriptImage.init(composed:))))
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
          conversation: conversationID, images: images, rewind: rewind)
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
    // Not stop() right away: the backend still sends the synthetic results before closing, and
    // cutting early would lose those cards (the log stays complete). But not forever either: if the
    // backend is gone nobody closes the stream, so cut it off after a grace period.
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

  /// the backend normally answers in milliseconds; past this something is really wrong
  static let stopGrace: Double = 8

  /// Whether the question in this row can be edited and asked again right now.
  var canEdit: Bool { !locked }

  /// Everything that must keep the composer locked, in one place.
  var locked: Bool { running || preparing || backendBusy }

  /// What the conversation list says about this conversation; it is the only read-only place that
  /// reports the write lock. A turn of our own always wins: it is the same fact, first hand.
  func backend(running: Bool) {
    let busy = running && !self.running && !preparing
    guard backendBusy != busy else { return }
    backendBusy = busy
  }

  /// How many turns the backend keeps when the question `id` is asked again: all before it. Its own
  /// number says so; a question the backend never numbered (refused) counts the numbered ones above
  /// it. nil when `id` isn't a question here.
  func keptTurns(before id: UUID) -> Int? {
    guard let index = items.firstIndex(where: { $0.id == id && $0.kind == .user }) else { return nil }
    if let turn = items[index].turn { return turn - 1 }
    return items[..<index].last { $0.kind == .user && $0.turn != nil }?.turn ?? 0
  }

  /// Replace the transcript with the log's projection, keeping what this turn said about itself (a
  /// refusal or failure). An empty answer is a failed fetch: the conversation itself is never empty
  /// here, so the transcript stays as it is.
  private func reload(keeping notes: [TranscriptItem]) {
    guard let projectID, let conversationID, let base else { return }
    Task { [weak self] in
      let raw = await AgentClient(base: base).transcript(projectID: projectID, conversation: conversationID)
      guard let self, !raw.isEmpty, !self.running else { return }
      self.items = raw.compactMap(TranscriptItem.init(restored:)) + notes
    }
  }

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

  /// Timed out counts as refused, as the backend decided; say it was a timeout, not the user.
  func expireApproval() {
    guard let pending else { return }
    self.pending = nil
    markDecision(callID: pending.callID, approved: false, reason: "", timedOut: true)
  }

  // MARK: - Events

  /// Seam for the panel checks: finalising the stream is where text gets lost or reordered silently.
  func ingest(_ event: AgentClient.Event) { absorb(event) }

  /// finalise the streaming message, as at the end of a turn
  func drainForTesting() { flushStream() }

  /// offscreen rendering and checks only
  func seedForTesting(_ item: TranscriptItem) { items.append(item) }

  private func absorb(_ event: AgentClient.Event) {
    timing?.handled(event.name)
    switch event {
    case .text, .toolCall, .approvalRequest, .failed:
      produced = true
    default:
      break
    }
    // Events that add rows or replace the streaming one finalise it first, so narration stays ahead of
    // the tool call that follows it. Tool results and enforcement only edit existing rows and don't
    // interrupt the text being paced out.
    switch event {
    case .text, .thinking, .heartbeat, .usage, .context, .toolResult, .enforcement, .toolInput:
      break
    default:
      flushStream()
    }
    switch event {
    case .messageStart(let id, _, _, let turn):
      if let id { jobID = id }
      // The question is in the log now; its number is what editing it sends back. Only the first
      // frame carries one.
      if let turn, let index = items.lastIndex(where: { $0.kind == .user }) {
        items[index].turn = turn
        replacing = false
      }
      // new step: the previous assistant message is final
      streamingIndex = nil
      pulse.settled()

    case .text(let chunk):
      pulse.heard()
      stream(chunk)

    case .thinking:
      // Never shown: it only proves the model is alive. The status line says "thinking".
      pulse.heard()

    case .toolInput(_, let name, let chars):
      pulse.drafting(name, chars: chars)

    case .toolCall(let call):
      pulse.settled()
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
      // dedupe, keeping first-arrival order: a clone sends dozens of requests to one host
      update(callID: hit.callID) { item in
        if hit.allowed {
          if !item.hosts.contains(hit.target) { item.hosts.append(hit.target) }
        } else if !item.blockedHosts.contains(where: { $0.host == hit.target }) {
          item.blockedHosts.append((host: hit.target, reason: hit.reason))
        }
      }
      // A notice rather than a modal: networking is normal, and confirm-every-time trains people to
      // click through.
      if hit.first && hit.allowed {
        firstNetworkHost = hit.target
        items.append(.notice(UIText(
          "联网：agent 正在访问 \(hit.target)。这一轮访问过的主机都记在工具卡里。",
          "Network: the agent is reaching \(hit.target). Every host visited this turn is listed on its tool card.")))
      }

    case .usage(let value):
      usage = value

    case .context(let report):
      context = report

    case .compaction(let event):
      applyCompaction(event)

    case .notice(let code, _, let quiet):
      items.append(.notice(Self.notice(code: code, quiet: quiet)))

    case .done(let stop, let steps, let exhausted, _, let total):
      terminalEventSeen = true
      if !total.isEmpty { usage = total }
      if stop == "compacted" {
        // manual compaction: the card already says it all
      } else if exhausted {
        // The cap (200) is a runaway guard, not a work limit; hitting it usually means going in circles,
        // so suggest rephrasing rather than continuing.
        items.append(.notice(UIText(
          "走了 \(steps) 步还没收敛，按防跑飞的兜底停下了。多半是它在原地打转 —— 换个更具体的问法通常比让它继续更有效。",
          "Stopped by the runaway guard after \(steps) steps without converging. It was probably going in "
            + "circles — a more specific question usually works better than letting it continue.")))
      } else if stop == "aborted" {
        items.append(.notice(UIText("已取消。没来得及跑的调用都补了结果，历史仍然完整。",
                                    "Canceled. Calls that hadn't run got placeholder results, so the history stays intact.")))
      } else if stop == "error" {
        // The backend sends a separate error event now; older backends still report failure as done.
        items.append(.failure(code: "LLM_ERROR",
                              message: UIText("这一轮在模型那边失败了。", "This turn failed on the model's side.")))
      } else if !produced {
        // neither an error nor any output: silence is the worst possible answer
        items.append(.notice(UIText("模型这一轮什么都没返回。再问一次，或者换一个模型试试。",
                                    "The model returned nothing this turn. Ask again, or try another model.")))
      } else if !endsWithAnswer {
        // tools ran but no answer followed
        items.append(.notice(UIText(
          "它跑完工具就停下了，没有给出结论。追问一句「所以结论是什么」通常就能拿到。",
          "It stopped after running tools without a conclusion. Asking “so what's the conclusion?” usually gets it.")))
      }

    case .failed(let code, let message):
      terminalEventSeen = true
      // the backend's wording is in a single language (the UI language at request time)
      // Refused because the previous turn still holds this conversation: first-hand news that it
      // is running on, so lock the composer again instead of letting the next question be refused too.
      if code == "CONVERSATION_BUSY" { heldByBackend = true }
      if compacting {
        // a failed manual compaction isn't a failed turn: it lands on the card, or as a notice
        endCompaction(.verbatim(message))
      } else {
        items.append(.failure(code: code, message: .verbatim(message)))
      }

    case .heartbeat(let quiet):
      pulse.quiet(quiet)
    }
  }

  /// Wording for a notice code; the backend sends only the code and numbers.
  nonisolated static func notice(code: String, quiet: Double?) -> UIText {
    switch code {
    case "SILENT_CUT":
      let seconds = Int((quiet ?? 0).rounded())
      return UIText("模型 \(seconds) 秒没有输出，连接断开，没写完的部分作废。已让它分节写，接着做。",
                    "The model sent nothing for \(seconds)s and the connection was cut; the unfinished part was lost. "
                      + "It was asked to write in sections and is carrying on.")
    default:
      return UIText("这一轮中途出了状况（\(code)），已接着做。", "Something happened mid-turn (\(code)); it carried on.")
    }
  }

  /// Text chunks. The transcript is touched only for the first chunk; after that growth goes to the
  /// pacer. Updating items every 50 ms recomputed the whole panel and still stuttered. The first
  /// chunk is structural: grouping and the thinking/writing state depend on whether there is text.
  private func stream(_ chunk: String) {
    guard !chunk.isEmpty else { return }
    if let index = streamingIndex, items.indices.contains(index) {
      if items[index].text.isEmpty { items[index].text = chunk }
    } else {
      pacer.reset()
      items.append(.assistant(chunk))
      streamingIndex = items.count - 1
    }
    pacer.receive(chunk)
  }

  /// Finalise the streaming message: the screen catches up and the full text goes into the
  /// transcript. Every ending must pass here, or the last words (the conclusion) are lost.
  private func flushStream() {
    guard let index = streamingIndex, items.indices.contains(index) else { return }
    let full = pacer.finish()
    guard items[index].text != full.text else { return }
    items[index].text = full.text
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
    // finalise first, or the last words are lost
    flushStream()
    // An edit the backend never took left the transcript cut where the log isn't: show the log
    // again, with the refusal under it. One it took is in the log, failures included.
    if replacing {
      let since = items.lastIndex { $0.kind == .user }.map { items.index(after: $0) } ?? items.endIndex
      reload(keeping: items[since...].filter { $0.kind == .failure || $0.kind == .notice })
    } else if reloadAfterTurn {
      reload(keeping: [])
    }
    replacing = false
    reloadAfterTurn = false
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
    pulse.reset()
    stopWatchdog?.cancel()
    stopWatchdog = nil
    // Our stream ended without the backend saying the turn did (it broke, or we let go of a stop
    // before it closed): assume the turn runs on and stay locked until the conversation list says
    // otherwise. A turn that ended with done / error needs none of this.
    backendBusy = heldByBackend || (!terminalEventSeen && projectID != nil)
    heldByBackend = false
    preparing = false
    running = false
    compacting = false
    streamingIndex = nil
    pending = nil
    jobID = nil
    task = nil
  }
}

// MARK: - Transcript item

/// An image in a question: the bytes just sent, or the stored file of a restored conversation.
struct TranscriptImage: Identifiable, Hashable {
  let id: String
  var data: Data?
  var path: String?
  var width: Int?
  var height: Int?

  init(composed image: ComposerImage) {
    id = image.id.uuidString
    data = image.data
    width = image.width
    height = image.height
  }

  init?(restored raw: [String: Any]) {
    guard let sha = raw["sha256"] as? String else { return nil }
    id = sha
    path = raw["path"] as? String
    width = raw["width"] as? Int
    height = raw["height"] as? Int
  }

  var image: NSImage? {
    if let data { return NSImage(data: data) }
    return path.flatMap { NSImage(contentsOfFile: $0) }
  }

  /// The image as an edited question carries it again. Already fitted, so preparing passes the same
  /// bytes through and the backend stores it once.
  var composed: ComposerImage? {
    if let data { return ComposerImage.prepare(data: data) }
    return path.flatMap { ComposerImage.prepare(url: URL(fileURLWithPath: $0)) }
  }
}

/// What a tool call acted on, read once from its arguments, so the process line can name files and
/// count work without parsing the backend's summary (which follows the UI language).
struct ToolSubject: Equatable {
  /// read, write, edit
  var path = ""
  /// grep and glob patterns, the anchor cite looks for, the repository fetch_repo clones
  var query = ""
  /// bash and python: the call's own one-line description
  var label = ""
  /// write and edit: the first Markdown heading of the new text, so a row of a long document says
  /// which section it wrote
  var heading = ""
  /// plan: steps done and in all
  var done = 0
  var total = 0

  init() {}

  /// Arguments are the model's and unchecked; anything malformed leaves its field empty.
  init(tool: String, arguments: [String: Any]) {
    func string(_ key: String) -> String {
      (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    switch tool {
    case "read":
      path = string("path")
    case "write", "edit":
      path = string("path")
      heading = Self.heading(in: arguments[tool == "write" ? "content" : "new_text"] as? String ?? "")
    case "grep", "glob":
      query = string("pattern")
    case "cite":
      query = string("anchor")
    case "fetch_repo":
      query = string("url")
    case "bash", "python":
      label = string("description")
    case "plan":
      let steps = (arguments["items"] as? [[String: Any]]) ?? []
      total = steps.count
      done = steps.filter { $0["status"] as? String == "done" }.count
    default:
      break
    }
  }

  var fileName: String { (path as NSString).lastPathComponent }

  /// The repository's name, as fetch_repo names its folder.
  var repository: String {
    let last = query.split(separator: "/").last.map(String.init) ?? query
    return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
  }

  /// The first heading near the start. Looking further would cost time on every long write, and a
  /// section written in pieces starts with its heading.
  static func heading(in text: String) -> String {
    for line in text.prefix(4_000).split(separator: "\n").prefix(60) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("#") else { continue }
      let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
      if !title.isEmpty { return String(title.prefix(80)) }
    }
    return ""
  }
}

/// A struct with a kind rather than an enum: streaming updates edit in place (appended text,
/// filled-in results, enforcement attached later).
struct TranscriptItem: Identifiable {
  enum Kind { case user, assistant, tool, approval, failure, notice, compaction }

  /// Running, done or failed. Token counts are the backend's estimates.
  struct Compaction: Equatable {
    enum State { case running, done, failed }
    var state: State
    /// auto / overflow / manual
    var trigger: String
    var summary = ""
    /// turns covered by the summary
    var turns = 0
    /// turns kept verbatim
    var kept = 0
    var before = 0
    var after = 0
  }

  struct Decision: Equatable {
    let approved: Bool
    let reason: String
    let timedOut: Bool
  }

  let id = UUID()
  var kind: Kind
  var text = ""
  /// user messages: the images sent with the question
  var images: [TranscriptImage] = []
  /// user messages: the question's number among the conversation's turns, given by the backend once
  /// it is logged. A refused question never gets one. Editing sends back how many turns to keep.
  var turn: Int?

  // tool / approval
  var callID = ""
  var toolName = ""
  var summary = ""
  /// tool calls: what the call acted on
  var subject = ToolSubject()
  var preview = ""
  var truncated = false
  var isError = false
  /// Filled in after a cancel; shown apart from tool errors (ran and failed vs. never ran).
  var synthetic = false
  var enforcement: String?
  var enforcementReason = ""
  /// Hosts this call reached, deduped in first-arrival order. Host and port only; the path and query
  /// string never exist here.
  var hosts: [String] = []
  /// `host -> reason`; shown prominently, since the agent tried to go somewhere it shouldn't
  var blockedHosts: [(host: String, reason: String)] = []
  var decision: Decision?
  /// user messages: when the question was sent
  var startedAt: Date?
  var finishedAt: Date?
  var expiresAt: Date?
  /// shown as in progress
  var awaitingResult = false
  /// edit and write only
  var diff: AgentClient.FileDiff?
  /// `.compaction` only; a failure's explanation is in `localized`
  var compaction: Compaction?
  var code = ""
  /// Text written by the UI itself, kept in both languages so it follows a switch. `text` still holds
  /// the Chinese (checks and export read it); backend wording is the same on both sides.
  var localized: UIText?
  var displayText: String { localized?.text ?? text }

  var duration: TimeInterval? {
    guard let startedAt, let finishedAt else { return nil }
    return finishedAt.timeIntervalSince(startedAt)
  }


  static func user(_ text: String, images: [TranscriptImage] = []) -> TranscriptItem {
    var item = TranscriptItem(kind: .user)
    item.text = text
    item.images = images
    item.startedAt = Date()
    return item
  }
  static func assistant(_ text: String) -> TranscriptItem {
    var item = TranscriptItem(kind: .assistant); item.text = text; return item
  }
  static func notice(_ text: UIText) -> TranscriptItem {
    var item = TranscriptItem(kind: .notice); item.text = text.zh; item.localized = text; return item
  }
  static func compaction(_ info: Compaction) -> TranscriptItem {
    var item = TranscriptItem(kind: .compaction)
    item.compaction = info
    return item
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
    item.subject = ToolSubject(tool: call.name, arguments: call.arguments)
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

  /// The log's timestamps: UTC with milliseconds (store.now()).
  private static let logTime: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  /// Field names follow derive_transcript() in projects/session.py.
  init?(restored raw: [String: Any]) {
    let kindName = raw["kind"] as? String ?? ""
    switch kindName {
    case "user": self.init(kind: .user)
    case "assistant": self.init(kind: .assistant)
    case "tool": self.init(kind: .tool)
    case "compaction": self.init(kind: .compaction)
    case "resumed":
      // fields of session.derive_transcript(); worded here like the live notice
      self.init(kind: .notice)
      let quiet = (raw["quiet"] as? NSNumber)?.doubleValue
      let wording = AgentSession.notice(code: (raw["reason"] as? String) == "silent_cut" ? "SILENT_CUT" : "", quiet: quiet)
      localized = wording
      text = wording.zh
      return
    case "failure":
      // a failed step's code survives in the log; the provider's words don't
      self.init(kind: .failure)
      code = raw["code"] as? String ?? ""
      return
    default: return nil
    }
    if kind == .compaction {
      // fields of session.compaction_item(), the same as the live done event
      compaction = Compaction(
        state: .done, trigger: raw["trigger"] as? String ?? "manual",
        summary: raw["summary"] as? String ?? "", turns: raw["turns"] as? Int ?? 0,
        kept: raw["kept"] as? Int ?? 0, before: raw["before"] as? Int ?? 0,
        after: raw["after"] as? Int ?? 0)
      return
    }
    text = raw["text"] as? String ?? ""
    if kind == .user {
      // field names follow ImageRecord.as_dict(); the backend adds where the file is
      images = (raw["images"] as? [[String: Any]] ?? []).compactMap(TranscriptImage.init(restored:))
      turn = raw["turn"] as? Int
      startedAt = (raw["at"] as? String).flatMap(Self.logTime.date(from:))
    }
    if kind == .tool {
      callID = raw["call_id"] as? String ?? ""
      toolName = raw["name"] as? String ?? "?"
      // computed by the backend's summarise_call(), the same function the live stream uses
      summary = raw["summary"] as? String ?? toolName
      subject = ToolSubject(tool: toolName, arguments: raw["arguments"] as? [String: Any] ?? [:])
      preview = raw["preview"] as? String ?? ""
      isError = raw["is_error"] as? Bool ?? false
      synthetic = raw["synthetic"] as? Bool ?? false
      let detail = raw["detail"] as? [String: Any] ?? [:]
      if let level = detail["enforcement"] as? String, level != "full" {
        enforcement = level
        enforcementReason = detail["enforcement_reason"] as? String ?? ""
      }
      // restore the diff too, so reopening still shows what changed
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
