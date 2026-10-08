import SwiftUI

// MARK: - Approval

/// A call waiting for the user's OK. A card in the transcript rather than a modal: the user may be
/// reading the source on the left.
struct ApprovalCard: View {
  let item: TranscriptItem
  let onAnswer: (Bool, String) -> Void

  @State private var reasoning = false
  @State private var reason = ""
  @State private var now = Date()
  private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  private var remaining: Int {
    guard let expiresAt = item.expiresAt else { return 0 }
    return max(0, Int(expiresAt.timeIntervalSince(now).rounded()))
  }
  private var answered: Bool { item.decision != nil }

  var body: some View {
    // Collapses to one line once answered; it only needs to be large while undecided.
    if answered { settled } else { prompt }
  }

  /// Answered: one quiet line that still names the action.
  private var settled: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: verdictSymbol)
        .font(.system(size: 10))
        .foregroundStyle(item.decision?.approved == true ? Palette.accent : Palette.inkFaint)
        .frame(width: 12)
      Text(verdictText)
        .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.inkSoft)
      Text(item.summary)
        .font(.system(size: 11)).foregroundStyle(Palette.inkFaint)
        .lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 4)
    }
    .padding(.horizontal, 9).padding(.vertical, 6)
    .help(item.summary)
  }

  private var verdictSymbol: String {
    item.decision?.approved == true ? "checkmark.circle.fill" : "hand.raised.fill"
  }

  private var verdictText: String {
    guard let decision = item.decision else { return "" }
    if decision.timedOut { return L("等超时了，按拒绝处理", "Timed out — treated as a denial") }
    let head = decision.approved ? L("已允许", "Allowed") : L("已拒绝", "Denied")
    return decision.reason.isEmpty ? head : head + L("：", ": ") + decision.reason
  }

  /// Phrased per tool rather than one fixed sentence.
  private var ask: (symbol: String, title: String, note: String) {
    switch item.toolName {
    case "delete_project":
      return ("trash", L("要删除一个项目", "Delete a project"),
              L("原稿副本与这个项目的全部对话会一起删掉，删了找不回来",
                "The copy of the original and all of this project's chats go with it — this can't be undone"))
    default:
      // unknown tool: ask, without inventing a consequence
      return ("hand.raised", L("这一步要你点头", "This step needs your OK"), "")
    }
  }

  private var prompt: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(spacing: 8) {
        Image(systemName: ask.symbol)
          .font(.system(size: 13)).foregroundStyle(Palette.accent)
        Text(ask.title).font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Palette.ink)
        Spacer(minLength: 0)
        if !answered {
          Text(L("\(remaining) 秒后自动拒绝", "Auto-denied in \(remaining)s"))
            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.inkFaint)
        }
      }

      Text(item.summary)
        .font(.system(size: 12.5)).foregroundStyle(Palette.ink)
        .fixedSize(horizontal: false, vertical: true)

      if !ask.note.isEmpty {
        Text(ask.note)
          .font(.system(size: 10.5)).foregroundStyle(Palette.inkFaint)
          .fixedSize(horizontal: false, vertical: true)
      }

      if reasoning {
        HStack(spacing: 7) {
          TextField(L("说一句为什么（可留空）", "Say why (optional)"), text: $reason)
            .textFieldStyle(.plain).font(.system(size: 11.5))
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.ruleSoft))
            .onSubmit { onAnswer(false, reason) }
          Button(L("确认拒绝", "Deny")) { onAnswer(false, reason) }
            .buttonStyle(StudioButtonStyle())
        }
      } else {
        HStack(spacing: 8) {
          Button(L("允许这一次", "Allow Once")) { onAnswer(true, "") }
            .buttonStyle(StudioButtonStyle(primary: true))
          Button(L("拒绝", "Deny…")) { withAnimation(.easeOut(duration: 0.15)) { reasoning = true } }
            .buttonStyle(StudioButtonStyle())
          Spacer(minLength: 0)
        }
      }
    }
    .padding(14)
    .background(Palette.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .strokeBorder(Palette.accent.opacity(0.34), lineWidth: 1))
    .onReceive(tick) { now = $0 }
    .animation(.easeOut(duration: 0.16), value: reasoning)
  }
}
