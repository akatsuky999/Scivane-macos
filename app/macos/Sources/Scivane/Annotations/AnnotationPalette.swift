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
  /// a note's text size in page points, a drawing's pen width
  var onSize: (CGFloat) -> Void = { _ in }
  var onWidth: (InkWidth) -> Void = { _ in }
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

/// Colour swatches over a highlight / underline switch (a note's text size, a drawing's pen width); a
/// delete button when editing a mark.
struct AnnotationPalette: View {
  @ObservedObject var model: AnnotationPaletteModel

  static let swatch: CGFloat = 16
  /// transparent margin around the card, so its shadow isn't clipped by the hosting view
  static let shadowPadding: CGFloat = 14

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 7) {
        ForEach(AnnotationColor.allCases) { color in
          MarkSwatch(color: color, selected: model.shownColor == color) { model.onColor(color) }
        }
      }
      HStack(spacing: 6) {
        shape.frame(maxWidth: .infinity)
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

/// The second row: the style of a mark on the text, a note's text size, or a drawing's pen width.
extension AnnotationPalette {
  @ViewBuilder fileprivate var shape: some View {
    if let note = model.editing?.note {
      NoteSizeControl(size: note.size, style: ToolButtonStyle(), change: model.onSize)
    } else if let ink = model.editing?.ink {
      SegmentedTabs(
        items: InkWidth.allCases.map { .init(id: $0.rawValue, label: $0.label, symbol: "") },
        selection: Binding(
          get: { InkWidth.nearest(ink.width).rawValue },
          set: { model.onWidth(InkWidth(rawValue: $0) ?? .medium) }))
    } else {
      SegmentedTabs(
        items: AnnotationKind.allCases.map { .init(id: $0.rawValue, label: $0.label, symbol: $0.symbol) },
        selection: Binding(
          get: { model.shownKind.rawValue },
          set: { model.onKind(AnnotationKind(rawValue: $0) ?? .highlight) }))
    }
  }
}

/// A note's text size: a step down, the size with the usual sizes in a menu, a step up. In the palette
/// for a selected note and in the dock for new ones.
struct NoteSizeControl<Style: ButtonStyle>: View {
  let size: CGFloat
  let style: Style
  let change: (CGFloat) -> Void

  var body: some View {
    HStack(spacing: 0) {
      step(up: false)
      Menu {
        Picker(L("字号", "Text Size"), selection: Binding(get: { size }, set: change)) {
          ForEach(NoteText.presets, id: \.self) { preset in
            Text(verbatim: NoteText.label(preset)).tag(preset)
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      } label: {
        HStack(spacing: 3) {
          Text(verbatim: NoteText.label(size))
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            .foregroundStyle(Palette.ink)
          Image(systemName: "chevron.down")
            .font(.system(size: 7.5, weight: .semibold))
            .foregroundStyle(Palette.inkFaint)
        }
        .frame(minWidth: 38, minHeight: 24)
        .contentShape(Rectangle())
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .help(L("字号", "Text Size"))
      .accessibilityLabel(L("字号", "Text Size"))
      .accessibilityValue(NoteText.label(size))
      .accessibilityIdentifier("note-size")
      step(up: true)
    }
  }

  private func step(up: Bool) -> some View {
    let label = up ? L("增大字号", "Bigger") : L("减小字号", "Smaller")
    return Button { change(NoteText.step(size, up: up)) } label: {
      Image(systemName: up ? "textformat.size.larger" : "textformat.size.smaller")
        .font(.system(size: 11.5))
        .frame(width: 26, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(style)
    .disabled(up ? size >= NoteText.sizes.upperBound : size <= NoteText.sizes.lowerBound)
    .help(label + (up ? "（⌘⇧>）" : "（⌘⇧<）"))
    .accessibilityLabel(label)
  }
}

/// One colour of the palette; the dock's pen and text colours use the same.
struct MarkSwatch: View {
  let color: AnnotationColor
  let selected: Bool
  var size: CGFloat = AnnotationPalette.swatch
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Circle()
        .fill(Color(nsColor: color.color))
        .overlay(Circle().strokeBorder(.black.opacity(0.12)))
        .frame(width: size, height: size)
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
