import SwiftUI

private struct ComposerSurface: ViewModifier {
  let focused: Bool
  let targeted: Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme

  private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
  private let edge = Color(light: .white.opacity(0.85), dark: .white.opacity(0.10))
  private let highlight = Color(light: .white.opacity(0.9), dark: .white.opacity(0.06))

  func body(content: Content) -> some View {
    content
      .background {
        ZStack {
          if reduceTransparency { shape.fill(Palette.sidebar) }
          else {
            WindowGlassBackdrop().clipShape(shape)
            // The native material already supplies opacity; the wash only gives it the island's hue.
            shape.fill(Palette.glassTint.opacity(colorScheme == .light ? 0.38 : 0.65))
          }
        }
        .shadow(color: Palette.glassShadow, radius: 24, y: 12)
        .allowsHitTesting(false)
      }
      .overlay {
        ZStack {
          shape.strokeBorder(edge, lineWidth: 1)
          shape.strokeBorder(
            LinearGradient(colors: [highlight, .clear], startPoint: .top, endPoint: .center),
            lineWidth: 1)
          shape.strokeBorder(
            Palette.accent.opacity(targeted ? 0.9 : (focused ? 0.18 : 0)),
            lineWidth: targeted ? 1.6 : 1)
        }
        .allowsHitTesting(false)
      }
  }
}

extension View {
  func composerSurface(focused: Bool, targeted: Bool) -> some View {
    modifier(ComposerSurface(focused: focused, targeted: targeted))
  }
}
