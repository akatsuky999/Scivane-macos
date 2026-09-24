import AppKit
import SwiftUI

// MARK: - 一直在动的两样东西：交给 Core Animation，不交给 SwiftUI
//
// **SwiftUI 的逐帧动画在 macOS 上按整棵树计价。** 实测（stream_perf.sh 的长推理场景，
// M5/16GB、12 轮历史，此时屏幕上只有一道扫光在动）：扫光还在 SwiftUI 里动时主线程
// 26.5%，把它换成静止的字只剩 5%。剖析下来，每一帧都是 `NSHostingView.layout()` →
// `DisplayList.ViewUpdater.update` 把**整棵对话流**的显示列表走一遍 —— 那棵树刻意不虚拟化，
// 历史越长越贵。换成 `TimelineView` 或 `GeometryEffect` 都一样；
// 把它单独放进一个 NSHostingView 反而更贵（里面那棵树逐帧要布局，照样冒泡到外面）。
//
// 所以这两样一直在动的东西改成普通的 NSView + `CABasicAnimation`：动画在渲染服务里跑，
// **主线程每帧零活**。样子与从前逐字一致（同样的颜色、宽度、周期、路径）。
// 两者都不接鼠标 —— 工具卡的摘要就在一个按钮里，点在字上也要能展开。

/// 流式输出时的光标。
///
/// 一个方块随呼吸淡入淡出，跟在已经吐出来的最后一个字后面。它回答的是
/// 「这句话说完了没有」—— 没有它的话，模型停顿两秒和模型说完了，
/// 在屏幕上长得一模一样。
struct StreamingCaret: NSViewRepresentable {
  func makeNSView(context: Context) -> CaretView { CaretView() }
  func updateNSView(_ view: CaretView, context: Context) {}
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: CaretView, context: Context) -> CGSize? {
    CGSize(width: 7, height: 15)
  }
}

final class CaretView: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 1.5
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }  // 不翻：开发者看的

  override var wantsUpdateLayer: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func updateLayer() {
    layer?.backgroundColor = resolve(Palette.accent, in: effectiveAppearance)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil, layer?.animation(forKey: "breathe") == nil else { return }
    let breathe = CABasicAnimation(keyPath: "opacity")
    breathe.fromValue = 0.95
    breathe.toValue = 0.12
    breathe.duration = 0.62
    breathe.autoreverses = true
    breathe.repeatCount = .infinity
    breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    layer?.add(breathe, forKey: "breathe")
  }
}

/// 会呼吸的状态文字：一道亮色从左扫到右。
///
/// 比转圈的 spinner 好在**它能说出此刻在做什么** —— 「正在思考」和
/// 「正在读 md/context.md」是两种等待，用户对后者的耐心要长得多。
/// 用遮罩而不是逐字改颜色：光带只是在同一段文字的形状里平移，不碰布局。
///
/// 这一处改过四版，前三版都在 SwiftUI 里：`@State` + `.id(text)`（换文字就从头闪）→
/// `TimelineView`（不闪了，但每帧重算 body）→ `GeometryEffect`（不重算 body，但每帧
/// 照样把整棵对话流的显示列表走一遍）。见上面那段说明。
struct ShimmerText: NSViewRepresentable {
  let text: String
  var size: CGFloat = 12
  var weight: NSFont.Weight = .medium

  func makeNSView(context: Context) -> ShimmerView { ShimmerView() }

  func updateNSView(_ view: ShimmerView, context: Context) {
    view.show(text, font: .systemFont(ofSize: size, weight: weight))
  }

  /// 自然宽度；给的地方不够就按给的宽，末尾截断（同 `Text.lineLimit(1)`）。
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShimmerView, context: Context) -> CGSize? {
    let natural = nsView.naturalSize
    guard let width = proposal.width, width < natural.width else { return natural }
    return CGSize(width: max(width, 0), height: natural.height)
  }
}

final class ShimmerView: NSView {
  /// 扫一轮几秒。
  static let period: CFTimeInterval = 1.6

  private let base = CATextLayer()
  /// 光带在这一层里平移，文字的形状（`shape`）做这一层的遮罩。
  private let lane = CALayer()
  private let band = CAGradientLayer()
  private let shape = CATextLayer()
  private var text = ""
  private var font = NSFont.systemFont(ofSize: 12, weight: .medium)
  private(set) var naturalSize: CGSize = .zero

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    for layer in [base, shape] {
      layer.isWrapped = false
      layer.truncationMode = .end
      layer.alignmentMode = .left
    }
    band.startPoint = CGPoint(x: 0, y: 0.5)
    band.endPoint = CGPoint(x: 1, y: 0.5)
    band.locations = [0, 0.34, 0.5, 0.66, 1]
    lane.addSublayer(band)
    lane.mask = shape
    layer?.addSublayer(base)
    layer?.addSublayer(lane)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }  // 不翻：开发者看的

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func show(_ text: String, font: NSFont) {
    guard text != self.text || font != self.font else { return }
    self.text = text
    self.font = font
    let measured = (text as NSString).size(withAttributes: [.font: font])
    naturalSize = CGSize(width: ceil(measured.width), height: ceil(measured.height))
    setAccessibilityLabel(text)
    setAccessibilityRole(.staticText)
    needsDisplay = true
    needsLayout = true
  }

  override func updateLayer() {
    // 颜色按当前外观解析成定值：文字层是在渲染服务那边画的，动态色到那里就不认了
    let appearance = effectiveAppearance
    let scale = window?.backingScaleFactor ?? 2
    base.string = NSAttributedString(string: text, attributes: [
      .font: font, .foregroundColor: NSColor(cgColor: resolve(Palette.inkFaint, in: appearance)) ?? .gray,
    ])
    shape.string = NSAttributedString(string: text, attributes: [
      .font: font, .foregroundColor: NSColor.black,
    ])
    base.contentsScale = scale
    shape.contentsScale = scale
    band.colors = [
      NSColor.clear.cgColor,
      resolve(ShimmerView.warm, in: appearance).copy(alpha: 0.75) ?? NSColor.clear.cgColor,
      resolve(Palette.ink, in: appearance),
      resolve(Palette.accent, in: appearance),
      NSColor.clear.cgColor,
    ]
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    needsDisplay = true
  }

  override func layout() {
    super.layout()
    let width = max(bounds.width, 1)
    let wide = max(96, width * 0.55)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    base.frame = bounds
    lane.frame = bounds
    shape.frame = bounds
    band.frame = CGRect(x: -wide, y: 0, width: wide, height: bounds.height)
    CATransaction.commit()
    // 从左边光带外扫到右边光带外，走完一个整程。**相位跟着全局时钟走**：
    // 换文字、改宽度都要重设这段动画，但光不会因此从头来。
    let sweep = CABasicAnimation(keyPath: "position.x")
    sweep.fromValue = -wide / 2
    sweep.toValue = width + wide * 1.5
    sweep.duration = Self.period
    sweep.repeatCount = .infinity
    sweep.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: Self.period)
    band.add(sweep, forKey: "sweep")
  }

  /// 扫光的暖侧。放在亮点之前，让这道光有方向感。
  static let warm = Color(
    light: Color(red: 0.72, green: 0.48, blue: 0.13),
    dark: Color(red: 0.93, green: 0.75, blue: 0.42))
}

/// 把界面色板里的颜色按某个外观解析成定值。
private func resolve(_ color: Color, in appearance: NSAppearance) -> CGColor {
  var resolved = NSColor.clear.cgColor
  appearance.performAsCurrentDrawingAppearance { resolved = NSColor(color).cgColor }
  return resolved
}

/// 新消息浮上来。
///
/// 幅度很小（6pt）—— 大开大合的入场动画在一次会问十几轮的界面里会很吵。
struct RiseIn: ViewModifier {
  @State private var shown = false
  func body(content: Content) -> some View {
    content
      .opacity(shown ? 1 : 0)
      .offset(y: shown ? 0 : 6)
      .onAppear { withAnimation(.easeOut(duration: 0.22)) { shown = true } }
  }
}

extension View {
  func riseIn() -> some View { modifier(RiseIn()) }
}
