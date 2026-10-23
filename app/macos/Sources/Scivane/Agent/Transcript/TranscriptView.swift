import SwiftUI

/// The transcript. What the agent says has no container; each stretch of its work between two things
/// it says reads as one process line. Reasoning is never shown.
struct AgentTranscript: View {
  @ObservedObject var session: AgentSession
  let onApprove: (Bool, String) -> Void
  /// Asks an edited question in place of the one with this id; false when it couldn't be sent. nil:
  /// questions can't be edited (offscreen checks).
  var onEdit: ((UUID, String) -> Bool)? = nil

  /// A plain item or a stretch of tool calls.
  enum Row: Identifiable {
    case single(TranscriptItem)
    case activity([TranscriptItem])

    /// A stretch is named after its first call, prefixed so it can never collide with a single row.
    var id: String {
      switch self {
      case .single(let item): return item.id.uuidString
      case .activity(let items): return "run:" + items[0].id.uuidString
      }
    }
  }

  /// Measured, not full width. 720 holds 40-45 CJK characters per line at 13.5 pt. It moves with
  /// the font size, but less than the type does: smaller type fits more on a line instead of
  /// narrowing the column, larger type fewer instead of running wide. A compact page is a little
  /// wider. Up to 1.34x on wide windows so tables and code don't scroll next to empty space.
  static func column(
    width: CGFloat, fontSize: CGFloat, density: ReadingDensity = .standard
  ) -> CGFloat {
    let measure = 720 * pow(fontSize / TypeScale.chat.standardSize, 0.55) * density.measure
    return min(max(measure, width * 0.62 * density.measure), measure * 1.34)
  }

  /// the column follows the conversation font size and density
  @AppStorage(TypeScale.chat.sizeKey) private var fontSize = TypeScale.chat.standardSize
  @AppStorage(TypeScale.chat.densityKey) private var density = ReadingDensity.standard

  /// Static so checks can pin it.
  ///
  /// Spoken text always goes to the message flow; tool calls always go into a process line, file
  /// changes included (their size shows on the line, the change itself one click away). Earlier
  /// versions had to decide whether a sentence was narration or the answer, which depends on what
  /// comes next, and re-deciding later made text jump in and out of the card. The price is one
  /// short narration line per step.
  ///
  /// A step that only reasoned draws nothing, and doesn't split the calls around it. Approvals,
  /// failures and notices are never merged in: they need action or must be seen.
  static func group(_ items: [TranscriptItem], running: Bool = false) -> [Row] {
    var rows: [Row] = []
    var calls: [TranscriptItem] = []
    func flush() {
      if !calls.isEmpty { rows.append(.activity(calls)); calls.removeAll() }
    }
    for item in items {
      switch item.kind {
      case .tool:
        calls.append(item)
      case .assistant where item.text.isEmpty:
        continue
      default:
        flush()
        rows.append(.single(item))
      }
    }
    flush()
    return rows
  }

  /// The column's width while the window or the pane divider is being dragged. Re-wrapping every row
  /// on every frame of the drag takes a long conversation several frames each time; the column keeps
  /// the width it had and takes the new one once, when the drag ends.
  @State private var heldWidth: CGFloat?
  @Environment(\.composerInset) private var composerInset

  private static let resizeBegan = NotificationCenter.default
    .publisher(for: NSWindow.willStartLiveResizeNotification)
    .merge(with: NotificationCenter.default.publisher(for: .paneResizeWillStart))
  private static let resizeEnded = NotificationCenter.default
    .publisher(for: NSWindow.didEndLiveResizeNotification)
    .merge(with: NotificationCenter.default.publisher(for: .paneResizeDidEnd))

  var body: some View {
    // Short content starts at the top: defaultScrollAnchor(.bottom) also decides where short content
    // sits. A container at least as tall as the viewport, aligned to the top, keeps it up there.
    GeometryReader { viewport in
      let column = Self.column(
        width: viewport.size.width, fontSize: TypeScale.chat.clamp(fontSize), density: density)
      ScrollView {
        // Rows of their own, outside this closure: it runs again on every change of the viewport, and
        // rows built in here were all rebuilt and re-laid out on every frame of a resize.
        TranscriptRows(session: session, onApprove: onApprove, onEdit: onEdit, density: density).equatable()
        // Bound to `running` so the end of a turn (status removed, line finalised) animates as one
        // change, without catching per-chunk growth.
        .padding(.horizontal, 22).padding(.top, 20)
        // one frame either way: switching modifiers would rebuild every row
        .frame(minWidth: heldWidth, maxWidth: heldWidth ?? column)
        .frame(
          maxWidth: .infinity, minHeight: max(0, viewport.size.height - composerInset),
          alignment: .top)
        .padding(.bottom, composerInset)
      }
      // One anchor, always at the bottom. Flipping it with `running` dragged the viewport to the top
      // at the end of every turn, just as the content changed.
      .defaultScrollAnchor(.bottom)
      .onReceive(Self.resizeBegan) { _ in heldWidth = min(column, viewport.size.width) }
      .onReceive(Self.resizeEnded) { _ in heldWidth = nil }
    }
  }
}

/// The rows of the transcript. Equal while the session and density are, so a change of the viewport
/// (a resize, the sidebar, single or dual panes) reaches only the frame around them.
private struct TranscriptRows: View, Equatable {
  @ObservedObject var session: AgentSession
  let onApprove: (Bool, String) -> Void
  let onEdit: ((UUID, String) -> Bool)?
  let density: ReadingDensity
  @State private var expandedRows: Set<String> = []
  /// The question being edited in place. The rows after it dim: sending replaces them.
  @State private var editing: UUID?
  @AppStorage(TypeScale.chat.sizeKey) private var base = TypeScale.chat.standardSize

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.session === rhs.session && lhs.density == rhs.density
  }

  private func expansion(for id: String) -> Binding<Bool> {
    Binding(get: { expandedRows.contains(id) }, set: { value in
      if value { expandedRows.insert(id) } else { expandedRows.remove(id) }
    })
  }

  /// consecutive calls merge into one process line
  private var rows: [AgentTranscript.Row] { AgentTranscript.group(session.items, running: session.running) }

  /// Also while the backend holds the conversation after our stream ended: that turn is still the
  /// one in progress, and its answer is on its way into the log.
  private var showsStatus: Bool { (session.running || session.backendBusy) && session.pending == nil }

  private func status(for run: [TranscriptItem]) -> LiveStatus {
    LiveStatus(run: run, fallback: session.activity, stopping: session.cancelRequested,
               since: session.askedAt, pulse: session.pulse, size: ProcessLine.size(for: base))
  }

  var body: some View {
    let rows = self.rows
    // the stretch the turn is in says what is happening now, in place of a separate status line
    let live = showsStatus && rows.last.map { if case .activity = $0 { return true } else { return false } } == true
    let edited = editing.flatMap { id in
      rows.firstIndex { if case .single(let item) = $0 { return item.id == id } else { return false } }
    }
    // Not a LazyVStack: row heights vary widely and lazy containers estimate unrealised rows, which
    // showed as blank space at the bottom and jumping layout. There are few rows anyway, since
    // grouping turns a turn into three or four.
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
        let replaced = edited.map { index > $0 } ?? false
        view(for: row, live: live && index == rows.count - 1)
          .id(row.id)
          .opacity(replaced ? 0.35 : 1)
          .allowsHitTesting(!replaced)
      }
      // The only progress indicator while running, always at the end of the turn: here while the model
      // thinks or answers, on the process line while it works.
      if showsStatus && !live {
        status(for: [])
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 6 * density.space)
          .transition(.opacity)
      }
      // Must be a Spacer: VStack hands spare height from the minHeight container to flexible children,
      // and a two-row table got stretched to half the screen.
      Spacer(minLength: 10)
    }
    .animation(.easeOut(duration: 0.18), value: edited)
    .onChange(of: session.running) { _, running in
      if running { editing = nil }
    }
  }

  @ViewBuilder
  private func view(for row: AgentTranscript.Row, live: Bool) -> some View {
    switch row {
    case .single(let item):
      // Only user rows animate in: every other kind is edited in place, and RiseIn's @State replays
      // on every rebuild, which looks like flicker.
      if item.kind == .user {
        self.row(item).padding(.top, topGap(for: item)).riseIn()
      } else {
        // the answer appears in one piece; fading in is gentler
        self.row(item).padding(.top, topGap(for: item)).transition(.opacity)
      }
    case .activity(let calls):
      // expansion owned by the parent; the line is rebuilt on every chunk
      ProcessLine(calls: calls, expansion: expansion(for: row.id), live: live ? status(for: calls) : nil)
        .padding(.top, 6 * density.space)
    }
  }

  /// Tight within a turn, a clear gap before each new question; closer or wider with the density.
  private func topGap(for item: TranscriptItem) -> CGFloat {
    let gap: CGFloat
    switch item.kind {
    case .tool: gap = 4
    case .user: gap = 20
    case .assistant: gap = 10
    case .approval, .failure: gap = 8
    case .notice: gap = 8
    case .compaction: gap = 10
    }
    return gap * density.space
  }

  @ViewBuilder
  private func row(_ item: TranscriptItem) -> some View {
    switch item.kind {
    case .user:
      UserLine(text: item.text, images: item.images, sentAt: item.startedAt, edit: edit(for: item))
    case .assistant:
      AssistantLine(item: item, streaming: item.id == session.streamingID, live: session.pacer)
    // grouping puts every call in a process line; a call on its own is drawn the same way
    case .tool: ProcessLine(calls: [item], expansion: expansion(for: item.id.uuidString))
    case .approval: ApprovalCard(item: item, onAnswer: onApprove)
    case .failure: FailureCard(code: item.code, message: item.displayText)
    case .notice: NoticeLine(text: item.displayText)
    // expansion owned by the parent; @State would close on the next chunk
    case .compaction: CompactionCard(item: item, expanded: expansion(for: item.id.uuidString))
    }
  }

  private func edit(for item: TranscriptItem) -> MessageEdit? {
    guard let onEdit else { return nil }
    return MessageEdit(
      editing: Binding(get: { editing == item.id }, set: { editing = $0 ? item.id : nil }),
      enabled: session.canEdit,
      send: { text in
        guard onEdit(item.id, text) else { return false }
        editing = nil
        return true
      })
  }
}
