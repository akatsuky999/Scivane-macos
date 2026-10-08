import SwiftUI

/// State of the floating palette: creating from a text selection, or editing a clicked mark.
@MainActor
final class AnnotationPaletteModel: ObservableObject {
  /// Style for new marks, remembered across launches.
  @Published var mode: AnnotationKind {
    didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
  }
  /// nil while creating from a selection
  @Published var editing: PaperAnnotation?

  var onColor: (AnnotationColor) -> Void = { _ in }
  var onKind: (AnnotationKind) -> Void = { _ in }
  var onDelete: () -> Void = {}

  static let modeKey = "annotationMode"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    mode = defaults.string(forKey: Self.modeKey).flatMap(AnnotationKind.init(rawValue:)) ?? .highlight
  }

  var shownKind: AnnotationKind { editing?.style ?? mode }
  var shownColor: AnnotationColor? { editing?.tint }
}

/// Colour swatches over a highlight / underline switch; a delete button when editing a mark.
struct AnnotationPalette: View {
  @ObservedObject var model: AnnotationPaletteModel

  static let swatch: CGFloat = 16
  /// transparent margin around the card, so its shadow isn't clipped by the hosting view
  static let shadowPadding: CGFloat = 14

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 7) {
        ForEach(AnnotationColor.allCases) { color in
          Swatch(color: color, selected: model.shownColor == color) { model.onColor(color) }
        }
      }
      HStack(spacing: 6) {
        SegmentedTabs(
          items: AnnotationKind.allCases.map { .init(id: $0.rawValue, label: $0.label, symbol: $0.symbol) },
          selection: Binding(
            get: { model.shownKind.rawValue },
            set: { model.onKind(AnnotationKind(rawValue: $0) ?? .highlight) }))
        .frame(maxWidth: .infinity)
        if model.editing != nil {
          Button(action: model.onDelete) {
            Image(systemName: "trash").font(.system(size: 11.5))
              .frame(width: 26, height: 24).contentShape(Rectangle())
          }
          .buttonStyle(ToolButtonStyle())
          .help(L("删除标注", "Delete Mark"))
          .accessibilityLabel(L("删除标注", "Delete Mark"))
        }
      }
    }
    .padding(.horizontal, 10).padding(.vertical, 9)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.rule))
    .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
    .padding(Self.shadowPadding)
    .fixedSize()
  }
}

private struct Swatch: View {
  let color: AnnotationColor
  let selected: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Circle()
        .fill(Color(nsColor: color.color))
        .overlay(Circle().strokeBorder(.black.opacity(0.12)))
        .frame(width: AnnotationPalette.swatch, height: AnnotationPalette.swatch)
        .padding(3)
        .overlay {
          if selected { Circle().strokeBorder(Palette.ink.opacity(0.75), lineWidth: 1.5) }
        }
        .scaleEffect(hovering && !selected ? 1.12 : 1)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
    .help(color.name)
    .accessibilityLabel(color.name)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
