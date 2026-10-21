import SwiftUI

/// The toolbar's island: the sidebar's glass with tighter corners and a lighter shadow, since it sits
/// over the paper rather than floating across the page. The source's dock is the same glass.
private struct ToolbarSurface: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme

  let shape: RoundedRectangle
  private let highlight = Color(light: .white.opacity(0.9), dark: .white.opacity(0.06))

  func body(content: Content) -> some View {
    content
      .background {
        ZStack {
          if reduceTransparency { shape.fill(Palette.sidebar) }
          else {
            WindowGlassBackdrop().clipShape(shape)
            shape.fill(Palette.glassTint.opacity(colorScheme == .light ? 0.38 : 0.65))
          }
        }
        .shadow(color: Palette.glassShadow.opacity(0.7), radius: 9, y: 3)
        .allowsHitTesting(false)
      }
      .overlay {
        ZStack {
          shape.strokeBorder(Palette.glassEdge, lineWidth: 1)
          shape.strokeBorder(
            LinearGradient(colors: [highlight, .clear], startPoint: .top, endPoint: .center),
            lineWidth: 1)
        }
        .allowsHitTesting(false)
      }
  }
}

/// A segmented control's track inside the island: only a hairline ring, so the glass shows through
/// and the thumb is the one thing that reads as raised.
struct ToolbarGroove: View {
  static let padding: CGFloat = 2

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
    shape
      .fill(Color(light: .white.opacity(0.18), dark: .white.opacity(0.02)))
      .overlay(shape.strokeBorder(
        Color(light: Palette.forest.opacity(0.11), dark: .white.opacity(0.11)), lineWidth: 1))
  }

  /// concentric with the island
  static var radius: CGFloat { SidebarMetrics.toolbarRadius - SidebarMetrics.toolbarPadding }
}

/// The selected segment: a small lens of glass. Brighter than the island at the top and fading down, a
/// rim that catches light along its upper edge, and a contact shadow under a soft one. In dark mode the
/// same gradients read as an old glossy bevel, so there it is flat: a lighter fill, a hairline, a shadow.
struct ToolbarThumb: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorScheme) private var colorScheme

  static var radius: CGFloat { ToolbarGroove.radius - ToolbarGroove.padding }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
    if reduceTransparency {
      shape.fill(Palette.thumb)
        .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
    } else if colorScheme == .dark {
      shape.fill(Color.white.opacity(0.11))
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.32), radius: 2, y: 1)
    } else {
      shape
        .fill(LinearGradient(
          colors: [Color(light: .white.opacity(0.9), dark: .white.opacity(0.18)),
                   Color(light: .white.opacity(0.6), dark: .white.opacity(0.07))],
          startPoint: .top, endPoint: .bottom))
        .overlay(shape.inset(by: 1).fill(LinearGradient(
          stops: [.init(color: Color(light: .white.opacity(0.8), dark: .white.opacity(0.18)), location: 0),
                  .init(color: .clear, location: 0.55)],
          startPoint: .top, endPoint: .bottom)))
        .overlay(shape.strokeBorder(LinearGradient(
          stops: [.init(color: Color(light: .white, dark: .white.opacity(0.45)), location: 0),
                  .init(color: Color(light: .white.opacity(0.4), dark: .white.opacity(0.08)), location: 0.55),
                  .init(color: Color(light: Palette.forest.opacity(0.12), dark: .black.opacity(0.25)), location: 1)],
          startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .shadow(color: Color(light: Palette.forest.opacity(0.12), dark: .black.opacity(0.5)), radius: 0.5, y: 0.5)
        .shadow(color: Color(light: Palette.forest.opacity(0.16), dark: .black.opacity(0.45)), radius: 4, y: 3)
    }
  }
}

/// The wash under a control in the island while the pointer is on it, with the island's inner corners.
struct ToolbarHover: View {
  let active: Bool

  var body: some View {
    RoundedRectangle(cornerRadius: ToolbarGroove.radius, style: .continuous)
      .fill(Color(light: .white.opacity(0.7), dark: .white.opacity(0.08)))
      .opacity(active ? 1 : 0)
  }
}

/// A control in the island: the hover wash, dimmed while pressed.
struct ToolbarButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    Control(configuration: configuration)
  }

  private struct Control: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
      configuration.label
        .background(ToolbarHover(active: hovering && enabled))
        .contentShape(Rectangle())
        .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
        .onHover { hovering = $0 }
    }
  }
}

/// A square icon button in the island.
struct ToolbarIconButton: View {
  let symbol: String
  let label: String
  /// the tooltip, when it says more than the label
  var help: String? = nil
  var size: CGFloat = 12.5
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: size))
        .foregroundStyle(Palette.inkSoft)
        .frame(width: SidebarMetrics.toolbarControl, height: SidebarMetrics.toolbarControl)
    }
    .buttonStyle(ToolbarButtonStyle())
    .help(help ?? label)
    .accessibilityLabel(label)
  }
}

extension View {
  func toolbarSurface(radius: CGFloat = SidebarMetrics.toolbarRadius) -> some View {
    modifier(ToolbarSurface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous)))
  }
}
