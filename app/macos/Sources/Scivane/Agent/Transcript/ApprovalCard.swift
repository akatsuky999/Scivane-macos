import SwiftUI

// MARK: - 批准

/// 需要用户点头的那一次调用。
///
/// **刻意不用模态对话框。** 模态会把整个界面按住，而用户此刻很可能正在
/// 左边看原稿对照 —— 打断阅读去回答一个是非题，是最糟的时机。
/// 这里让它作为对话流里的一张卡浮出来：显眼，但不夺走控制权。
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
    // **裁决完就收成一行。** 这张卡之所以大，是因为它要让人在一秒内判断
    // 该不该批 —— 那是「待决」时的需要。答完之后它只是一条记录，
    // 再占 140pt 就是在和真正的回答抢版面（活动卡收起是同一个道理）。
    if answered { settled } else { prompt }
  }

  /// 已裁决：一行浅色记录。**动作本身要留在行里** ——
  /// 只写「已允许」而不写允许了什么，这条记录就没有价值了。
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

  /// 这张卡在问什么。**按工具说，不写死一句。**
  ///
  /// 从前这里写死「这一步要联网」和「沙箱内没有网络，只有这一类动作会走到外面」——
  /// 那时要批准的只有 `fetch_repo`。沙箱通网之后，后一句就不对了；取代码也搬进沙箱之后
  /// 弹这张卡的只剩书房的删项目（读者那一层零审批工具），前一句也不对了：
  /// 用户删一篇论文时看到的会是「这一步要联网」。
  private var ask: (symbol: String, title: String, note: String) {
    switch item.toolName {
    case "delete_project":
      return ("trash", L("要删除一个项目", "Delete a project"),
              L("原稿副本与这个项目的全部对话会一起删掉，删了找不回来",
                "The copy of the original and all of this project's chats go with it — this can't be undone"))
    default:
      // 没见过的工具：只说要你点头，不替它编一句后果
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
