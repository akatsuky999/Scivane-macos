import SwiftUI

// Status line while running: shimmering text and a ticking counter. It is the only progress
// indicator of a turn, always at its end: the process line of the stretch the turn is in, or a line
// of its own while the model thinks or answers.

struct LiveStatus: View {
  /// the calls of the stretch the turn is in; empty outside one
  let run: [TranscriptItem]
  /// what the session says when no call is running ("thinking", "answering", "waiting for you")
  let fallback: String
  /// change at once when stop is pressed; closing takes the backend a second or two
  var stopping = false
  /// when the question was sent; for the elapsed time
  var since: Date?
  /// a tool call being written, or a model gone quiet; the session's, a still one for samples
  @ObservedObject var pulse: TurnPulse = TurnPulse()
  /// the process line's type size, so the line keeps its height when the stretch finishes
  var size: CGFloat = 12.5

  private var currentTool: TranscriptItem? {
    run.last { $0.kind == .tool && $0.awaitingResult }
  }

  /// The text's tail, up to 160 characters. Static so a check can pin it. Cut first, then process:
  /// flattening and counting the whole string ran on every chunk and could saturate a core on long
  /// answers. One extra character tells whether anything was cut.
  static func tail(_ text: String, limit: Int = 160) -> String {
    let flat = text.suffix(limit + 1).replacingOccurrences(of: "\n", with: " ")
    return flat.count > limit ? "…" + String(flat.suffix(limit)) : flat
  }

  /// What is happening now: the call running, the arguments of one being written, or the session's
  /// own word for the wait.
  var action: String {
    // after pressing stop, that is all the user wants to know
    if stopping { return L("正在停下…", "Stopping…") }
    if let currentTool { return ProcessSummary.doing(currentTool) }
    // the arguments of a call still being written, e.g. a long document for write
    if let draft = pulse.draft {
      let size = draft.chars.formatted()
      return L("正在写 \(draft.tool) 的内容 · \(size) 字", "Writing the \(draft.tool) call · \(size) chars")
    }
    return fallback.isEmpty ? L("等模型回应", "Waiting for the model") : fallback
  }

  var body: some View {
    // Just one shimmering status line. A preview window of the streaming text used to sit above it;
    // it looked exactly like the answer, swapped its contents every few hundred ms and made the text
    // jump. The status says what is happening without previewing content.
    HStack(spacing: 6) {
      ShimmerText(text: action, size: size, weight: .regular)
      // A counter that keeps ticking: during long reasoning nothing else on screen changes, and the
      // shimmer only shows the animation is alive. Driven by its own TimelineView; on the session it
      // would rerender the whole transcript every second.
      if let since {
        TimelineView(.periodic(from: since, by: 1)) { timeline in
          let seconds = Int(timeline.date.timeIntervalSince(since))
          Text(seconds >= 60
            ? String(format: "%d:%02d", seconds / 60, seconds % 60)
            : "\(seconds)s")
            .font(.system(size: size - 1.5, design: .monospaced))
            .foregroundStyle(Palette.inkFaint.opacity(0.75))
            .contentTransition(.identity)
        }
      }
      // A counter alone can't tell writing from stalled: say when the model has sent nothing for a while.
      if let quiet = pulse.quietSince, !stopping {
        TimelineView(.periodic(from: quiet, by: 1)) { timeline in
          let seconds = Int(timeline.date.timeIntervalSince(quiet))
          Text(L("· 模型 \(seconds) 秒没有输出", "· no output for \(seconds)s"))
            .font(.system(size: size - 1.5))
            .foregroundStyle(Palette.inkFaint.opacity(0.85))
            .contentTransition(.identity)
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}
