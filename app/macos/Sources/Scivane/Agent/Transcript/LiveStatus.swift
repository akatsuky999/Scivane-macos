import SwiftUI

// Status line while running: shimmering text and a ticking counter.

struct LiveStatus: View {
  /// this turn's process so far; empty until the first chunk
  let run: [TranscriptItem]
  /// used when there is no reasoning line to show (the session's `activity`)
  let fallback: String
  /// change at once when stop is pressed; closing takes the backend a second or two
  var stopping = false
  /// when the question was sent; for the elapsed time
  var since: Date?

  private var thoughts: [TranscriptItem] { run.filter { $0.kind == .assistant } }
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

  /// The running tool if any; otherwise thinking vs. writing, so people know the answer is coming.
  var action: String {
    // after pressing stop, that is all the user wants to know
    if stopping { return L("正在停下…", "Stopping…") }
    if let currentTool {
      return currentTool.summary.isEmpty
        ? L("正在跑 \(currentTool.toolName)", "Running \(currentTool.toolName)") : currentTool.summary
    }
    // text may just be narration before a tool call; only claim "answering" with no tool pending
    if thoughts.last?.text.isEmpty == false, tools.allSatisfy({ !$0.awaitingResult }) {
      return L("正在整理回答", "Wrapping up the answer")
    }
    if !tools.isEmpty { return L("已用 \(tools.count) 个工具", "Used " + plural(tools.count, "tool", "tools")) }
    // The session's line knows more specific states ("reading md/context.md", "waiting for you").
    return fallback.isEmpty ? L("等模型回应", "Waiting for the model") : fallback
  }

  private var tools: [TranscriptItem] { run.filter { $0.kind == .tool } }

  var body: some View {
    // Just one shimmering status line. A preview window of the streaming text used to sit above it;
    // it looked exactly like the answer, swapped its contents every few hundred ms and made the text
    // jump. The status says what is happening without previewing content.
    HStack(spacing: 6) {
      ShimmerText(text: action, size: 10.5, weight: .medium)
      // A counter that keeps ticking: during long reasoning nothing else on screen changes, and the
      // shimmer only shows the animation is alive. Driven by its own TimelineView; on the session it
      // would rerender the whole transcript every second.
      if let since {
        TimelineView(.periodic(from: since, by: 1)) { timeline in
          let seconds = Int(timeline.date.timeIntervalSince(since))
          Text(seconds >= 60
            ? String(format: "%d:%02d", seconds / 60, seconds % 60)
            : "\(seconds)s")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Palette.inkFaint.opacity(0.7))
            .contentTransition(.identity)
        }
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// shared by group headers and the waiting line
struct SpinnerRing: View {
  @State private var spin = false
  var body: some View {
    Circle()
      .trim(from: 0, to: 0.68)
      .stroke(
        AngularGradient(colors: [Palette.accent.opacity(0.15), Palette.accent], center: .center),
        style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
      .rotationEffect(.degrees(spin ? 360 : 0))
      .animation(.linear(duration: 0.95).repeatForever(autoreverses: false), value: spin)
      .onAppear { spin = true }
  }
}
