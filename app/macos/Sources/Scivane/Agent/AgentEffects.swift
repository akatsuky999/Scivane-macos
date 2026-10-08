import AppKit
import SwiftUI

// MARK: - Continuous animations run in Core Animation, not SwiftUI
//
// A per-frame SwiftUI animation re-walks the whole transcript's display list on every frame (the
// transcript isn't virtualised), so its cost grows with history. TimelineView and GeometryEffect
// behave the same, and a separate NSHostingView is worse. Plain NSViews with CABasicAnimation run
// in the render server and cost the main thread nothing per frame. Neither takes mouse events:
// tool-card summaries sit inside a button and clicks on the text must reach it.

/// Streaming caret, after the last character. Without it, a two-second pause and a finished answer
/// look the same.
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

  required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }  // 不翻: developer-facing

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

/// Status text with a highlight sweeping across. Unlike a spinner it says what is happening;
/// people wait longer for "reading md/context.md" than for "thinking". The text shape masks the
/// band, so nothing touches layout.
struct ShimmerText: NSViewRepresentable {
  let text: String
  var size: CGFloat = 12
  var weight: NSFont.Weight = .medium

  func makeNSView(context: Context) -> ShimmerView { ShimmerView() }

  func updateNSView(_ view: ShimmerView, context: Context) {
    view.show(text, font: .systemFont(ofSize: size, weight: weight))
  }

  /// natural width; truncated at the tail when less is offered, like Text.lineLimit(1)
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShimmerView, context: Context) -> CGSize? {
    let natural = nsView.naturalSize
    guard let width = proposal.width, width < natural.width else { return natural }
    return CGSize(width: max(width, 0), height: natural.height)
  }
}

final class ShimmerView: NSView {
  static let period: CFTimeInterval = 1.6

  private let base = CATextLayer()
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

  required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }  // 不翻: developer-facing

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
    // resolve colours now: the text layer is drawn in the render server, which doesn't know dynamic colours
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
    // Phase follows the global clock, so restarting the animation after a text or width change
    // doesn't restart the sweep.
    let sweep = CABasicAnimation(keyPath: "position.x")
    sweep.fromValue = -wide / 2
    sweep.toValue = width + wide * 1.5
    sweep.duration = Self.period
    sweep.repeatCount = .infinity
    sweep.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: Self.period)
    band.add(sweep, forKey: "sweep")
  }

  /// warm side, ahead of the highlight, to give the sweep a direction
  static let warm = Color(
    light: Color(red: 0.72, green: 0.48, blue: 0.13),
    dark: Color(red: 0.93, green: 0.75, blue: 0.42))
}

private func resolve(_ color: Color, in appearance: NSAppearance) -> CGColor {
  var resolved = NSColor.clear.cgColor
  appearance.performAsCurrentDrawingAppearance { resolved = NSColor(color).cgColor }
  return resolved
}

/// Small (6 pt) on purpose: big entrances get noisy over dozens of turns.
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
