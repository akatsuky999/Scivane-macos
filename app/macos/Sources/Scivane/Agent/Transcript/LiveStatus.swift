import SwiftUI

// 跑动中的那一行状态：扫光的文字 + 一直在走的秒数。

struct LiveStatus: View {
  /// 这一轮到目前为止的过程（旁白、思考、工具）。可能是空的 —— 刚发出提问、
  /// 模型还没吐第一个字的那几百毫秒就是空的。
  let run: [TranscriptItem]
  /// 没有推理摘要可显示时退回的那句话（会话自己算的 `activity`）。
  let fallback: String
  /// 用户按过「停」。这一行要立刻改口 —— 后端收流还要一两秒，
  /// 期间界面一动不动的话，按钮看起来就是坏的。
  var stopping = false
  /// 这一轮是什么时候发出去的。用来报已等了多久。
  var since: Date?

  private var thoughts: [TranscriptItem] { run.filter { $0.kind == .assistant } }
  private var currentTool: TranscriptItem? {
    run.last { $0.kind == .tool && $0.awaitingResult }
  }

  /// 截出正文的尾巴。提成静态是为了能被断言钉住 ——
  /// 取成头部不会报错，只是"在动"的观感整个没了。
  ///
  /// 截到 160 字 —— 配合固定两行的框，正好是一个不断上滚的小窗口。
  /// **先截尾再处理。** 老写法是 `text.replacingOccurrences(...)` 整串压平、
  /// 再 `text.count` 数一遍 —— 两个都是 O(n)，而这个函数每个流式分片跑一次。
  /// 正文长到几万字时，光这一处就够把一个核占满。
  /// 多取一个字符是为了判断「到底截没截」，不必回头数整串。
  static func tail(_ text: String, limit: Int = 160) -> String {
    let flat = text.suffix(limit + 1).replacingOccurrences(of: "\n", with: " ")
    return flat.count > limit ? "…" + String(flat.suffix(limit)) : flat
  }

  /// 正在跑工具就报它；否则区分「在想」和「在写答案」——
  /// 后者要让用户知道**答案在来了**，而不是还在琢磨。
  var action: String {
    // 按了停就先说这个 —— 它比「正在跑 grep」更要紧，因为用户此刻
    // 唯一关心的是「我按的那下到底生效没有」。
    if stopping { return L("正在停下…", "Stopping…") }
    if let currentTool {
      return currentTool.summary.isEmpty
        ? L("正在跑 \(currentTool.toolName)", "Running \(currentTool.toolName)") : currentTool.summary
    }
    // 正文可能只是工具前的旁白，不能据此宣布“正在作答”。
    // 只有没有待执行工具时，才把状态交给稳定的作答提示。
    if thoughts.last?.text.isEmpty == false, tools.allSatisfy({ !$0.awaitingResult }) {
      return L("正在整理回答", "Wrapping up the answer")
    }
    if !tools.isEmpty { return L("已用 \(tools.count) 个工具", "Used " + plural(tools.count, "tool", "tools")) }
    // 退回会话自己算的那句：它知道「正在读 md/context.md」「等你的决定」
    // 这些比「等模型回应」具体得多的情形。**这是 fallback 唯一的落点** ——
    // 上面那块预览窗口拆掉之后，不接回来它就成了一个没人读的参数。
    return fallback.isEmpty ? L("等模型回应", "Waiting for the model") : fallback
  }

  private var tools: [TranscriptItem] { run.filter { $0.kind == .tool } }

  var body: some View {
    // **只有一行会扫光的状态，没有别的。**
    //
    // 早先这上面还有一块「固定两行的窗口」，把正在生成的旁白尾巴摊在那儿。
    // 出发点是让逐字生成看得见，代价是实机上非常难看：那块窗口是 12pt 中黑、
    // 每个分片换一次内容，长得**和答案一模一样**，于是
    //
    //   - 用户以为旁白没被折叠（其实卡里那份才是正主，窗口只是复读）
    //   - 文字每几百毫秒整段换一次，两行之间还会重排 —— 就是「字体跳动」
    //
    // codex desktop 跑动时屏幕上只有一个 `Thinking` 在扫光，正文一个字都不露；
    // 中间说的话作为消息落进流里，由 `group` 收进过程卡。这里照同一个判断：
    // **过程只报「在做什么」，不预演内容。**
    HStack(spacing: 6) {
      ShimmerText(text: action, size: 10.5, weight: .medium)
      // **一直在走的秒数。**
      //
      // 推理模型一想就是几十秒，那期间屏幕上其余部分完全不变 ——
      // 用户分不清「还在想」和「卡死了」，实机就是这么报上来的
      // （「一直是这个界面很久没有变化」）。扫光只说明动画在跑，
      // 秒数才说明**这一轮**还在走。
      //
      // 每秒跳一次，用 TimelineView 自己驱动：挂在会话上的话，
      // 整条对话流每秒都要重渲染一遍。
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

/// 转着的小环。抽出来给分组头和等待行共用。
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
