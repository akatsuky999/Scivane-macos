import SwiftUI

/// A compaction in the transcript. Labels and numbers only.
/// - running: a shimmering "Compacting context..." (Core Animation, see ShimmerText)
/// - done: a divider with before / after sizes; expanding shows the summary itself, since people
///   should know what the model now remembers. Earlier turns stay visible in full.
/// - failed: one line with the reason
struct CompactionCard: View {
  let item: TranscriptItem
  @Binding var expanded: Bool

  private var info: TranscriptItem.Compaction {
    item.compaction ?? TranscriptItem.Compaction(state: .done, trigger: "manual")
  }

  var body: some View {
    switch info.state {
    case .running: running
    case .done: done
    case .failed: failed
    }
  }

  private var running: some View {
    HStack(spacing: 7) {
      Image(systemName: "rectangle.compress.vertical")
        .font(.system(size: 10)).foregroundStyle(Palette.accent)
      ShimmerText(text: L("正在压缩上下文…", "Compacting context…"), size: 11.5, weight: .medium)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private var done: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button { expanded.toggle() } label: {
        HStack(spacing: 8) {
          rule
          HStack(spacing: 5) {
            Image(systemName: "rectangle.compress.vertical").font(.system(size: 9))
            Text(Self.doneTitle(info)).font(.system(size: 10.5, weight: .medium))
            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 7.5, weight: .semibold))
          }
          .foregroundStyle(Palette.inkFaint)
          .fixedSize()
          rule
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if expanded, !info.summary.isEmpty {
        MarkdownText(info.summary)
          .padding(12)
        .background(Palette.sunk, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
    }
  }

  private var failed: some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: "exclamationmark.circle").font(.system(size: 10)).padding(.top, 1)
      Text(Self.failedText(info.trigger, item.displayText))
        .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
    }
    .foregroundStyle(Palette.inkFaint)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var rule: some View {
    Rectangle().fill(Palette.rule).frame(height: 1).frame(maxWidth: .infinity)
  }

  static func doneTitle(_ info: TranscriptItem.Compaction) -> String {
    var title = L("上下文已压缩", "Context compacted")
    if info.before > 0, info.after > 0 {
      title += " · \(UsageMeter.compact(info.before)) → \(UsageMeter.compact(info.after))"
    }
    return title
  }

  static func failedText(_ trigger: String, _ message: String) -> String {
    // drop the backend's trailing full stop after the colon
    let trimmed = message.trimmingCharacters(in: CharacterSet(charactersIn: "。.！!  \n"))
    let reason = trimmed.isEmpty ? L("原因不明", "unknown reason") : trimmed
    return L("压缩失败：\(reason)", "Compaction failed: \(reason)")
  }
}
