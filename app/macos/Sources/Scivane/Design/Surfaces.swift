import AppKit
import SwiftUI

/// Within-window blending samples content beneath a floating surface, rather than the wallpaper.
struct WindowGlassBackdrop: NSViewRepresentable {
  @Environment(\.colorScheme) private var colorScheme

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.blendingMode = .withinWindow
    view.state = .active
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    // Aqua's sidebar material masks the paper beneath a floating panel.
    let material: NSVisualEffectView.Material = colorScheme == .light ? .popover : .sidebar
    if view.material != material { view.material = material }
  }
}

/// A frosted panel floating over the window: the sidebar island and the settings navigation. The
/// window's own material, tinted towards the paper green, with a light edge and a soft shadow; the
/// shadow sits on the shape, never on the content, so text stays crisp.
struct GlassSurface: ViewModifier {
  var radius: CGFloat

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    content
      .background {
        shape.fill(.regularMaterial)
          .overlay(shape.fill(Palette.glassTint))
          .shadow(color: Palette.glassShadow, radius: 18, y: 8)
      }
      .overlay(shape.strokeBorder(Palette.glassEdge, lineWidth: 1))
  }
}

/// Rows grouped on one card: settings sections, and the sidebar's chats, notes and outline.
struct CardSurface: ViewModifier {
  var radius: CGFloat

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    content
      .background(Palette.card, in: shape)
      .overlay(shape.strokeBorder(Palette.cardEdge, lineWidth: 1))
  }
}

extension View {
  func glassSurface(radius: CGFloat) -> some View { modifier(GlassSurface(radius: radius)) }
  func cardSurface(radius: CGFloat = 14) -> some View { modifier(CardSurface(radius: radius)) }
}

/// A segmented control drawn by hand. AppKit's can't be sized to sit in the sidebar's capsule, and
/// its selected segment is a flat grey; here the selection is a raised thumb that slides, and the
/// labels stay in ink rather than the accent.
struct PillPicker<Value: Hashable, Label: View>: View {
  let options: [Value]
  @Binding var selection: Value
  var height: CGFloat = 24
  /// nil sizes each segment to its label
  var segmentWidth: CGFloat? = nil
  /// tooltip and VoiceOver name of each option
  let name: (Value) -> String
  @ViewBuilder let label: (Value, Bool) -> Label

  @Namespace private var thumb
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 0) {
      ForEach(options, id: \.self) { option in
        let selected = option == selection
        Button { selection = option } label: {
          label(option, selected)
            .padding(.horizontal, segmentWidth == nil ? 10 : 0)
            .frame(width: segmentWidth, height: height)
            .background {
              if selected {
                RoundedRectangle(cornerRadius: height * 0.42, style: .continuous)
                  .fill(Palette.thumb)
                  .shadow(color: .black.opacity(0.10), radius: 1.5, y: 0.5)
                  .matchedGeometryEffect(id: "thumb", in: thumb)
              }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name(option))
        .accessibilityLabel(name(option))
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .padding(2)
    .background(Palette.track, in: RoundedRectangle(cornerRadius: (height + 4) * 0.42, style: .continuous))
    .animation(reduceMotion ? nil : .spring(duration: 0.26, bounce: 0.12), value: selection)
  }
}
