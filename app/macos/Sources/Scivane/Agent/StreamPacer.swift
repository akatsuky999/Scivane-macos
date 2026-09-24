import AppKit
import QuartzCore
import SwiftUI

/// 正在生成的那一条：**已经收到的**和**屏幕上显示到哪了**分开记，屏幕逐帧追上去。
///
/// ## 为什么要有这一层
///
/// 模型的分片是成簇来的 —— 平时每秒上百个，偶尔停一两百毫秒再一口气涌来一串
/// （经代理转发的流就是这个样子）。从前攒到 50ms 落一次记录，实测
/// （本地流式基准，M5/16GB）：**83% 的帧屏幕上一个字都不动**，
/// 动的那一帧平均跳 38 个字节、最多 160 个 —— 「一卡一卡」里「一」的那一半。
/// 主线程再闲也救不了它：节奏本身就是一顿一顿的。
///
/// ## 两条纪律
///
/// 1. **只有正在生成的那一行观察它。** 逐帧的变化不经过 `AgentSession.items`：
///    从前每落一次记录，整个面板（对话流里的每一行、输入框、状态栏）都要重算一遍，
///    而且历史越长越贵（12 轮历史下思考阶段主线程 28%，空对话 11%）。
///    记录只在结构性的时刻改：这一路第一次有字、以及定稿（`finish()`）。
/// 2. **屏幕上永远是已收到的前缀，追赶是指数式的。** 每帧露出积压的一个固定比例
///    （时间常数 `catchUp`），至少一个字：一簇涌来时先快后慢地铺开，停顿时平滑地收住，
///    平均滞后约等于时间常数。这是 codex TUI「平滑 / 追赶」两档
///    （`streaming/chunking.rs`）在逐字显示上的对应物 —— 它按行、两档切换还要加迟滞
///    防抖；按字走一条连续的指数曲线，本来就没有档位可抖。
///
/// 结构性事件（工具调用、批准、新一步、收尾）到来时由会话调 `finish()`：屏幕立刻补齐、
/// 全文写回记录 —— 一句旁白必须排在它后面那个工具调用之前。
@MainActor
final class StreamPacer: NSObject, ObservableObject {

  /// 屏幕上此刻显示的正文与推理。
  ///
  /// **两路合成一个值发布**：分开两个 `@Published` 的话，同一帧两路都动时
  /// 观察者要重画两次。
  struct Shown: Equatable {
    var text = ""
    var thinking = ""
  }

  @Published private(set) var shown = Shown()

  /// 追赶的时间常数（秒）：每帧露出积压的 1 − e^(−Δt/τ)。
  ///
  /// 取 0.1 秒：平均滞后与从前「攒 50ms + 等下一帧」相当（实测 100–140ms），
  /// 换来的是每一帧都在动。再小就退回「来多少蹦多少」，再大则停顿之后要追很久。
  static let catchUp: TimeInterval = 0.1

  /// 分段计时（`AgentTiming`，默认关）：每次发布记下屏幕上有多少字。
  var timing: AgentTiming?

  private var text = Channel()
  private var thinking = Channel()
  private var link: CADisplayLink?
  private var timer: Timer?
  private var lastTick: CFTimeInterval?

  /// 已收到、还没显示的字数（两路合计）。给断言与基准用。
  var backlog: Int { text.backlog + thinking.backlog }

  /// 收到一个分片。
  func receive(_ chunk: String, thinking isThinking: Bool) {
    guard !chunk.isEmpty else { return }
    if isThinking { thinking.append(chunk) } else { text.append(chunk) }
    startTicking()
  }

  /// 屏幕立刻补齐、停下，返回已收到的全文。**结构性事件与收尾走这里。**
  @discardableResult
  func finish() -> Shown {
    text.revealAll()
    thinking.revealAll()
    stopTicking()
    publish(text: true, thinking: true)
    return Shown(text: text.target, thinking: thinking.target)
  }

  /// 换一条消息：清空。
  func reset() {
    stopTicking()
    text = Channel()
    thinking = Channel()
    if shown != Shown() { shown = Shown() }
  }

  /// 推进一帧。`now` 是这一帧的时间戳 —— 断言与基准也走这个缝，拿确定的时间驱动它。
  func tick(at now: CFTimeInterval) {
    // 两帧之间的时间夹在 [1/240, 0.1]：主线程被别的事占住半秒之后，
    // 不该一帧把半秒的积压全倒出来 —— 那正是要消灭的「跳一截」。
    let dt = lastTick.map { min(max(now - $0, 1.0 / 240), 0.1) } ?? (1.0 / 60)
    lastTick = now
    let movedText = text.advance(dt: dt, tau: Self.catchUp)
    let movedThinking = thinking.advance(dt: dt, tau: Self.catchUp)
    if movedText || movedThinking { publish(text: movedText, thinking: movedThinking) }
    if backlog == 0 { stopTicking() }
  }

  private func publish(text movedText: Bool, thinking movedThinking: Bool) {
    var next = shown
    if movedText { next.text = text.visible }
    if movedThinking { next.thinking = thinking.visible }
    if next != shown {
      shown = next
      timing?.shown(text: next.text.utf8.count, thinking: next.thinking.utf8.count)
    }
  }

  // MARK: - 帧时钟

  /// 有积压才走帧时钟，追平就停 —— 空闲时一帧的活都不该有。
  private func startTicking() {
    guard link == nil, timer == nil else { return }
    lastTick = nil
    if let screen = NSScreen.main {
      // 跟着屏幕刷新走（macOS 14 起 NSScreen 直接给显示链接）：每帧恰好一次，
      // 和 SwiftUI 画帧对齐。普通 Timer 与刷新不同步，会时而一帧两次、时而一次没有。
      let link = screen.displayLink(target: self, selector: #selector(step(_:)))
      link.add(to: .main, forMode: .common)
      self.link = link
    } else {
      // 没有屏幕（无显示器的环境）：退回 60Hz 的计时器，保证字照样会追平。
      timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.tick(at: CACurrentMediaTime()) }
      }
    }
  }

  private func stopTicking() {
    link?.invalidate()
    link = nil
    timer?.invalidate()
    timer = nil
  }

  @objc private func step(_ link: CADisplayLink) {
    tick(at: link.timestamp)
  }

  // MARK: - 一路字

  private struct Channel {
    private(set) var target = ""
    /// 屏幕显示到 `target` 的第几个 UTF-8 字节（总在字符边界上）。
    ///
    /// **记偏移量而不是 `String.Index`**：字符串追加之后，之前取到的索引不保证仍然可用。
    private var shownBytes = 0
    /// 已收到、还没显示的字数。
    private(set) var backlog = 0

    var visible: String {
      let utf8 = target.utf8
      return String(target[..<utf8.index(utf8.startIndex, offsetBy: shownBytes)])
    }

    mutating func append(_ chunk: String) {
      target += chunk
      backlog += chunk.count
    }

    mutating func revealAll() {
      shownBytes = target.utf8.count
      backlog = 0
    }

    /// 露出这一帧该露的字。返回屏幕上有没有变化。
    mutating func advance(dt: TimeInterval, tau: TimeInterval) -> Bool {
      guard backlog > 0 else { return false }
      let share = Double(backlog) * (1 - exp(-dt / tau))
      let step = min(backlog, max(1, Int(share.rounded(.up))))
      let utf8 = target.utf8
      let from = utf8.index(utf8.startIndex, offsetBy: shownBytes)
      let to = target.index(from, offsetBy: step, limitedBy: target.endIndex) ?? target.endIndex
      shownBytes = utf8.distance(from: utf8.startIndex, to: to)
      backlog -= step
      // 分片的字数是分开数的：一个组合字符恰好被切在两个分片之间时会多数一个。
      // 到了末尾就是追平了 —— 不这样兜住，帧时钟会为一个不存在的字一直跑下去。
      if to == target.endIndex { backlog = 0 }
      return true
    }
  }
}
