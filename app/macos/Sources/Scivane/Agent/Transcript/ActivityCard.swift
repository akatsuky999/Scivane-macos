import SwiftUI

// MARK: - Process (reasoning + tool calls)

/// All of a turn's process in one card, so a dozen steps don't push the answer off screen.
/// Collapsed it is one line ("Processed 22.3s · 9 tools"); expanded, reasoning and tools appear
/// in their original order. Failures, blocks, refusals and skipped calls are counted in the
/// collapsed line too: hiding a failure in a fold reads as success.
struct ActivityCard: View {
  let items: [TranscriptItem]
  /// Owned by the parent per row id. The card is rebuilt on every chunk while running and @State
  /// follows view identity, so it would close again right after being opened. nil falls back to
  /// local state (single cards in offscreen checks).
  var expansion: Binding<Bool>? = nil
  /// The streaming item must be recognisable: relaying out a growing text on every chunk is
  /// quadratic and saturated the main thread around 43k characters.
  var streaming: UUID? = nil
  /// Expanded, the streaming item's tail is read from here; per-frame growth never reaches `items`.
  var live: StreamPacer? = nil
  @State private var localExpanded = false
  private var expanded: Bool { expansion?.wrappedValue ?? localExpanded }
  private func toggle() {
    if let expansion { expansion.wrappedValue.toggle() } else { localExpanded.toggle() }
  }
  @State private var hovering = false

  /// The reasoning line to show: the last one, which tends to be "next I'll read X"; the first one
  /// usually restates the question. Called on every chunk while the text keeps growing, so only the
  /// tail is scanned; splitting the whole string made long reasoning steadily slower.
  static func headline(_ thinking: String, window: Int = 400) -> String {
    let lines = thinking.suffix(window).split(whereSeparator: \.isNewline)
    guard let last = lines.last(where: {
      !$0.trimmingCharacters(in: .whitespaces).isEmpty
    }) else { return "" }
    // strip heading marks, emphasis and bullets; noise in a one-line summary
    return String(last).trimmingCharacters(in: CharacterSet(charactersIn: "#*->` \t"))
  }

  struct Anomaly { let label: String; let count: Int; let tint: Color }

  /// Anomaly counts as chips that stay visible when collapsed.
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

  /// Tools as actions ("read files, ran commands") rather than a count, which says nothing about
  /// what happened. English needs two tenses; Chinese adds 正在 / 已 at the call site.
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

  /// What the streaming item draws when expanded. Static so a check can pin it: drawing the full
  /// text compiles and looks right but relayouts everything on every chunk.
  static func live(_ item: TranscriptItem) -> String {
    live(text: item.text, thinking: item.thinking)
  }

  static func live(text: String, thinking: String) -> String {
    LiveStatus.tail(text.isEmpty ? thinking : text)
  }

  /// Read from the pacer when there is one; offscreen there isn't, so use the finalised text.
  @ViewBuilder
  private func liveTail(_ item: TranscriptItem) -> some View {
    if let live {
      LiveTail(pacer: live)
    } else {
      Text(Self.live(item))
    }
  }

  /// The collapsed line, from the same Digest the view draws; a separate copy here had already drifted.
  var summary: String { Digest(items: items, running: isRunning).summary }

  private var isRunning: Bool {
    streaming.map { id in items.contains { $0.id == id } } ?? false
  }

  /// One look only: the collapsed line. The live state is shown once, in LiveStatus at the bottom;
  /// two blocks of different heights taking turns made the layout shake.
  var body: some View {
    // Every derived value in one pass. Recomputing them separately walked `items` about ten times per
    // render, and a render happens on every chunk.
    let digest = Digest(items: items, running: isRunning)
    return VStack(alignment: .leading, spacing: 0) {
      header(digest)
      if expanded { detail }
    }
    // A faint background (3%) so it reads as one clickable thing, a little darker when expanded.
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Palette.sunk.opacity(expanded ? 0.75 : 0.45)))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Palette.ruleSoft, lineWidth: 1))
    // Animate on what was done, never on time. Keyed on the full summary, which includes the
    // elapsed seconds, the text was always mid-crossfade and redrawn on the CPU every frame; that
    // was most of the stutter.
    .animation(.easeOut(duration: 0.2), value: digest.head)
  }

  /// Everything the card shows, computed in one pass.
  struct Digest {
    var toolCount = 0
    var summary = ""
    /// the summary without the elapsed time; the only animation key
    var head = ""
    var anomalies: [Anomaly] = []

    /// - Parameter running: no elapsed time while running. The streaming item no longer updates
    ///   the transcript per frame, so its end time is stale; LiveStatus has a ticking counter.
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
          // deduped in first-seen order; the order is the story
          if !verbs.contains(verb) { verbs.append(verb) }
          if item.awaitingResult {
            pending = verb
          } else {
            if item.synthetic { skipped += 1 }
            else if item.decision?.approved == false
              || item.preview.contains("TOOL_DENIED_BY_USER") { denied += 1 }
            else if item.isError {
              // 不翻: matches tool results, which are always Chinese for the model
              item.preview.contains("沙箱") ? (blocked += 1) : (failed += 1)
            }
            if item.enforcement != nil { partial += 1 }
          }
        default:
          break
        }
      }

      // no past tense while a tool is still waiting for its result
      if let pending {
        summary = L("正在" + pending.zh, pending.doing)
      } else if toolCount == 1, thoughtCount == 0, let only = onlyTool {
        // a single call without reasoning reports itself rather than a vaguer verb
        summary = only.summary.isEmpty ? only.toolName : only.summary
      } else if verbs.isEmpty {
        summary = L("思考过程", "Thinking")
      } else {
        let done = verbs.map(\.done).joined(separator: ", ")
        summary = L("已" + verbs.map(\.zh).joined(separator: "、"), done.prefix(1).uppercased() + done.dropFirst())
      }
      head = summary
      // Span rather than a sum of durations (read-only tools run concurrently). Under 0.05 s it is not
      // shown, matching the tool card.
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

  // MARK: Collapsed / expanded

  private func header(_ digest: Digest) -> some View {
    Button {
      toggle()
    } label: {
      HStack(spacing: 7) {
        // No spinner here: the only one is in the status block at the bottom.
        Image(systemName: digest.toolCount == 0 ? "text.alignleft" : "wrench.adjustable")
          .font(.system(size: 10)).foregroundStyle(Palette.inkFaint)
          .frame(width: 12)

        // Set as a label: smaller and heavier, with a little tracking, or it blurs in light text.
        Text(digest.summary)
          .font(.system(size: 10.5, weight: .medium))
          .foregroundStyle(hovering ? Palette.inkSoft : Palette.inkFaint)
          .kerning(0.2)
          .lineLimit(1).truncationMode(.middle)

        // anomalies stay visible when collapsed
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

  /// Expanded detail: reasoning and tools in their original order, which is what carries the cause
  /// and effect.
  ///
  /// Must be lazy: while running the card holds the whole turn (hundreds of items) and `items`
  /// changes on every chunk; an eager VStack rebuilt them all each time and saturated the main
  /// thread at around 450 items. Laziness doesn't help with one item that keeps growing and stays
  /// visible, so the streaming item only draws its tail (settled(_:)).
  private var detail: some View {
    // The card has its own background and border, so a hairline separates header and detail instead
    // of a second frame.
    VStack(alignment: .leading, spacing: 0) {
      Rectangle().fill(Palette.ruleSoft).frame(height: 1)
        .padding(.horizontal, 10)
      LazyVStack(alignment: .leading, spacing: 7) {
        ForEach(items) { item in
          if item.kind == .tool {
            ToolCard(item: item, dense: true)
          } else if item.kind == .assistant, !item.thinking.isEmpty {
            // Reasoning sits a level below tools: a small spaced label and greyer text. The label stays while
            // streaming; only the content is bounded.
            VStack(alignment: .leading, spacing: 3) {
              Text(L("思考", "THINKING"))
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(Palette.inkFaint.opacity(0.75))
              if item.id == streaming {
                // Only a bounded tail and no textSelection: text being generated can't be selected anyway, and
                // full relayout is what saturated the main thread.
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

/// The streaming tail in an expanded card. Its own view observes the pacer, so only this line
/// redraws per frame.
private struct LiveTail: View {
  @ObservedObject var pacer: StreamPacer
  var body: some View {
    Text(ActivityCard.live(text: pacer.shown.text, thinking: pacer.shown.thinking))
  }
}
