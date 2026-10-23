import SwiftUI

// Icons drawn here rather than taken from SF Symbols: the system's text symbols turn into the system
// language's own letters (字, 小, 大 in Chinese) whatever the app's language, and its pointer is solid
// beside outline tools. Each is drawn on a 24-unit grid and stroked with `StrokeStyle.glyph`.

extension StrokeStyle {
  /// close to a regular SF Symbol's stroke at 13 pt
  static let glyph = StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
}

/// An outline pointer.
struct PointerGlyph: Shape {
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.addLines([CGPoint(x: 6, y: 3.5), CGPoint(x: 6, y: 18.8), CGPoint(x: 10, y: 14.9),
                     CGPoint(x: 12.7, y: 20.9), CGPoint(x: 15.3, y: 19.8), CGPoint(x: 12.6, y: 13.8),
                     CGPoint(x: 18.2, y: 13.8)])
      path.closeSubpath()
    }
    .fitted(to: rect)
  }
}

/// A capital T with a foot.
struct TextGlyph: Shape {
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.addLines([CGPoint(x: 5.5, y: 6.5), CGPoint(x: 5.5, y: 4.5), CGPoint(x: 18.5, y: 4.5),
                     CGPoint(x: 18.5, y: 6.5)])
      path.move(to: CGPoint(x: 12, y: 4.5))
      path.addLine(to: CGPoint(x: 12, y: 19.5))
      path.move(to: CGPoint(x: 9, y: 19.5))
      path.addLine(to: CGPoint(x: 15, y: 19.5))
    }
    .fitted(to: rect)
  }
}

/// A capital A, small or large: the text size a step down or up. Both stand on the same baseline.
struct SizeGlyph: Shape {
  let larger: Bool

  func path(in rect: CGRect) -> Path {
    // apex height and half the width at the baseline; the bar crosses a third of the way up
    let (top, half): (CGFloat, CGFloat) = larger ? (4, 6.5) : (8.5, 4.6)
    let base: CGFloat = 19.5
    let bar = base - (base - top) * 0.34
    let inset = half * 0.34
    return Path { path in
      path.addLines([CGPoint(x: 12 - half, y: base), CGPoint(x: 12, y: top), CGPoint(x: 12 + half, y: base)])
      path.move(to: CGPoint(x: 12 - half + inset, y: bar))
      path.addLine(to: CGPoint(x: 12 + half - inset, y: bar))
    }
    .fitted(to: rect)
  }
}

private extension Path {
  /// from the 24-unit grid into `rect`
  func fitted(to rect: CGRect) -> Path {
    applying(CGAffineTransform(translationX: rect.minX, y: rect.minY)
      .scaledBy(x: rect.width / 24, y: rect.height / 24))
  }
}
