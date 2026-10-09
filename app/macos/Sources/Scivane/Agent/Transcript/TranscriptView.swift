import SwiftUI

/// The transcript. Answers have no container; a stretch of process (reasoning and tool calls)
/// collapses into one ActivityCard.
struct AgentTranscript: View {
  @ObservedObject var session: AgentSession
  let onApprove: (Bool, String) -> Void
  @State private var expandedRows: Set<String> = []

  private func expansion(for id: String) -> Binding<Bool> {
    Binding(get: { expandedRows.contains(id) }, set: { value in
      if value { expandedRows.insert(id) } else { expandedRows.remove(id) }
    })
  }

  /// A plain item or a whole stretch of process.
  enum Row: Identifiable {
    case single(TranscriptItem)
    case activity([TranscriptItem])

    /// Activity rows can't reuse the first item's id: an assistant message with both reasoning and text
    /// is split into two halves sharing one UUID, and ForEach would silently drop one.
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

  /// consecutive process items merge into one card
  private var rows: [Row] { Self.group(session.items, running: session.running) }

  /// Static so checks can pin it.
  ///
  /// Spoken text always goes to the message flow; reasoning and tools always go into the collapsed
  /// card. Earlier versions had to decide whether a sentence was narration or the answer, which
  /// depends on what comes next, and re-deciding later made text jump in and out of the card. The
  /// price is one short narration line per step.
  ///
  /// Approvals, failures and diffs are never merged in: they need action or must be seen.
  static func group(_ items: [TranscriptItem], running: Bool = false) -> [Row] {
    func isProcess(_ index: Int) -> Bool {
      let item = items[index]
      // A file change is a result, not process: it must be seen and checked.
      if item.diff != nil { return false }
      if item.kind == .tool { return true }
      guard item.kind == .assistant else { return false }
      // Reasoning only: process. Any text: message flow, regardless of what follows.
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
      // Reasoning and text of one message go to different places, or every narration line carries its
      // own reasoning toggle.
      if item.kind == .assistant, !item.thinking.isEmpty, !item.text.isEmpty {
        pending.append(item.reasoningOnly())
      }
      flush()
      rows.append(.single(item.spokenOnly()))
    }
    flush()
    return rows
  }

  /// the running stretch, for the status block
  private var liveRun: [TranscriptItem] {
    guard session.running, case .activity(let items)? = rows.last else { return [] }
    return items
  }

  var body: some View {
    // Short content starts at the top: defaultScrollAnchor(.bottom) also decides where short content
    // sits. A container at least as tall as the viewport, aligned to the top, keeps it up there.
    GeometryReader { viewport in
      ScrollView {
        // Not a LazyVStack: row heights vary widely and lazy containers estimate unrealised rows, which
        // showed as blank space at the bottom and jumping layout. There are few rows anyway, since
        // grouping turns a turn into three or four.
        VStack(alignment: .leading, spacing: 2) {
          ForEach(rows) { row in
            view(for: row).id(row.id)
          }
          // The only progress indicator while running, always in the same place for the whole turn.
          if session.running && session.pending == nil {
            LiveStatus(run: liveRun, fallback: session.activity,
                       stopping: session.cancelRequested, since: session.askedAt)
              .padding(.top, 8)
              .transition(.opacity)
          }
          // Must be a Spacer: VStack hands spare height from the minHeight container to flexible children,
          // and a two-row table got stretched to half the screen.
          Spacer(minLength: 10)
        }
        // Bound to `running` so the end of a turn (status removed, card finalised) animates as one
        // change, without catching per-chunk growth.
        .padding(.horizontal, 22).padding(.top, 20)
        .frame(maxWidth: Self.column(
          width: viewport.size.width, fontSize: TypeScale.chat.clamp(fontSize), density: density))
        .frame(
          maxWidth: .infinity, minHeight: viewport.size.height,
          alignment: .top)
      }
      // One anchor, always at the bottom. Flipping it with `running` dragged the viewport to the top
      // at the end of every turn, just as the content changed.
      .defaultScrollAnchor(.bottom)
    }
  }



  @ViewBuilder
  private func view(for row: Row) -> some View {
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
    case .activity(let items):
      // expansion owned by the parent; the card is rebuilt on every chunk
      ActivityCard(
        items: items, expansion: expansion(for: row.id),
        streaming: session.streamingID, live: session.pacer
      ).padding(.top, 6)
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
    case .user: UserLine(text: item.text, images: item.images)
    case .assistant:
      AssistantLine(item: item, streaming: item.id == session.streamingID,
                    live: session.pacer, showThinking: expansion(for: item.id.uuidString))
    // Expanded by default: the point of lifting it out of the fold is to check the change.
    case .tool: ToolCard(item: item, startExpanded: item.diff != nil)
    case .approval: ApprovalCard(item: item, onAnswer: onApprove)
    case .failure: FailureCard(code: item.code, message: item.displayText)
    case .notice: NoticeLine(text: item.displayText)
    // expansion owned by the parent; @State would close on the next chunk
    case .compaction: CompactionCard(item: item, expanded: expansion(for: item.id.uuidString))
    }
  }
}

/// Long reasoning scrolls in its own area; the collapse button stays outside.
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
