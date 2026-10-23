import AppKit

/// What a press on the source does. Selecting is PDFKit's own (text, links, the palette for
/// highlights); the others take the pointer.
enum MarkupTool: String, CaseIterable, Identifiable {
  case select, note, ink, eraser

  var id: String { rawValue }

  var label: String {
    switch self {
    case .select: return L("选择", "Select")
    case .note: return L("文字", "Text")
    case .ink: return L("画笔", "Pen")
    case .eraser: return L("橡皮", "Eraser")
    }
  }
}

/// Pen widths, in page points so a stroke scales with the page. Raw values are stored preferences.
enum InkWidth: String, CaseIterable, Identifiable {
  case thin, medium, thick

  var id: String { rawValue }
  var points: CGFloat {
    switch self {
    case .thin: return 1
    case .medium: return 2
    case .thick: return 3.5
    }
  }

  var label: String {
    switch self {
    case .thin: return L("细", "Thin")
    case .medium: return L("中", "Medium")
    case .thick: return L("粗", "Thick")
    }
  }

  /// the stored width read back as the nearest choice
  static func nearest(_ points: CGFloat) -> InkWidth {
    allCases.min { abs($0.points - points) < abs($1.points - points) } ?? .medium
  }
}

/// The dock's tool and the colour, width and size new notes and strokes get. The tool always starts
/// as Select; the rest is remembered across launches.
@MainActor
final class MarkupTools: ObservableObject {
  @Published var tool: MarkupTool = .select
  @Published var color: AnnotationColor { didSet { defaults.set(color.rawValue, forKey: Keys.color) } }
  @Published var inkWidth: InkWidth { didSet { defaults.set(inkWidth.rawValue, forKey: Keys.width) } }
  /// in page points, within NoteText.sizes
  @Published var noteSize: CGFloat { didSet { defaults.set(Double(noteSize), forKey: Keys.size) } }

  private enum Keys {
    static let color = "markupColor"
    static let width = "inkWidth"
    static let size = "noteTextSize"
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    color = defaults.string(forKey: Keys.color).flatMap(AnnotationColor.init(rawValue:)) ?? .red
    inkWidth = defaults.string(forKey: Keys.width).flatMap(InkWidth.init(rawValue:)) ?? .medium
    let size = defaults.double(forKey: Keys.size)
    noteSize = size > 0 ? NoteText.clamped(CGFloat(size)) : NoteText.standard
  }

  /// Esc, a project switch, or a source that can't hold marks
  func reset() {
    if tool != .select { tool = .select }
  }
}
