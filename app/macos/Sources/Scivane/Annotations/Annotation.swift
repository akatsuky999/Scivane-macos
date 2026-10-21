import AppKit
import Foundation

/// Highlight or underline. Raw values are the stored keys (KINDS in projects/annotations.py).
enum AnnotationKind: String, CaseIterable, Identifiable {
  case highlight, underline

  var id: String { rawValue }

  var label: String {
    switch self {
    case .highlight: return L("高亮", "Highlight")
    case .underline: return L("下划线", "Underline")
    }
  }

  var symbol: String { self == .highlight ? "highlighter" : "underline" }
}

/// The palette, in swatch order. Raw values are the stored keys (COLORS in projects/annotations.py);
/// the order is checked there too.
enum AnnotationColor: String, CaseIterable, Identifiable {
  case yellow, red, green, blue, purple, magenta, orange, gray

  var id: String { rawValue }

  /// The usual reader marker colours, so marks read the same as in other PDF tools.
  var color: NSColor {
    switch self {
    case .yellow: return NSColor(srgbRed: 1.00, green: 0.83, blue: 0.00, alpha: 1)
    case .red: return NSColor(srgbRed: 1.00, green: 0.40, blue: 0.40, alpha: 1)
    case .green: return NSColor(srgbRed: 0.37, green: 0.70, blue: 0.21, alpha: 1)
    case .blue: return NSColor(srgbRed: 0.18, green: 0.66, blue: 0.90, alpha: 1)
    case .purple: return NSColor(srgbRed: 0.64, green: 0.54, blue: 0.90, alpha: 1)
    case .magenta: return NSColor(srgbRed: 0.90, green: 0.43, blue: 0.93, alpha: 1)
    case .orange: return NSColor(srgbRed: 0.95, green: 0.60, blue: 0.22, alpha: 1)
    case .gray: return NSColor(srgbRed: 0.67, green: 0.67, blue: 0.67, alpha: 1)
    }
  }

  /// For writing on the page: the marker colour a shade darker, so yellow and gray text still read on
  /// white paper.
  var text: NSColor {
    switch self {
    case .yellow, .orange, .gray: return color.blended(withFraction: 0.3, of: .black) ?? color
    default: return color.blended(withFraction: 0.12, of: .black) ?? color
    }
  }

  var name: String {
    switch self {
    case .yellow: return L("黄色", "Yellow")
    case .red: return L("红色", "Red")
    case .green: return L("绿色", "Green")
    case .blue: return L("蓝色", "Blue")
    case .purple: return L("紫色", "Purple")
    case .magenta: return L("品红", "Magenta")
    case .orange: return L("橙色", "Orange")
    case .gray: return L("灰色", "Gray")
    }
  }
}

/// One mark on a project's source PDF, as stored in .lumen/annotations.json: a highlight or an
/// underline of its text, a note written on a page, or pen strokes on a page.
struct PaperAnnotation: Identifiable, Equatable {
  /// The part of a mark on one page: one rect per text line, in PDF page space.
  struct Span: Equatable {
    var page: Int
    var rects: [CGRect]
  }

  /// Words written on the page, wrapped to the box's width. Page space, so it scales with the page.
  struct Note: Equatable {
    var page: Int
    var rect: CGRect
    var body: String
    /// text size in page points
    var size: CGFloat
  }

  /// Strokes of the pen on one page, each a line through points in page space.
  struct Ink: Equatable {
    var page: Int
    var width: CGFloat
    var strokes: [[CGPoint]]
  }

  /// stored kinds besides the two text styles (NOTE and INK in projects/annotations.py)
  static let noteKind = "note"
  static let inkKind = "ink"

  let id: String
  /// Kept as stored rather than as enums, so a mark written by a newer app survives a round trip.
  var kind: String
  var color: String
  /// a mark on the text; empty for a note or a drawing
  let spans: [Span]
  let text: String
  var note: Note?
  var ink: Ink?

  var style: AnnotationKind { AnnotationKind(rawValue: kind) ?? .highlight }
  var tint: AnnotationColor { AnnotationColor(rawValue: color) ?? .yellow }
  var isFreehand: Bool { note != nil || ink != nil }

  init(id: String = UUID().uuidString, kind: AnnotationKind, color: AnnotationColor,
       spans: [Span], text: String) {
    self.id = id
    self.kind = kind.rawValue
    self.color = color.rawValue
    self.spans = spans
    self.text = text
  }

  init(id: String = UUID().uuidString, color: AnnotationColor, note: Note) {
    self.id = id
    kind = Self.noteKind
    self.color = color.rawValue
    spans = []
    text = ""
    self.note = note
  }

  init(id: String = UUID().uuidString, color: AnnotationColor, ink: Ink) {
    self.id = id
    kind = Self.inkKind
    self.color = color.rawValue
    spans = []
    text = ""
    self.ink = ink
  }

  /// The pages it is on, from 0.
  var pages: [Int] {
    if let note { return [note.page] }
    if let ink { return [ink.page] }
    return spans.map(\.page)
  }

  /// Request body for the backend.
  var payload: [String: Any] {
    var body = changes
    body["id"] = id
    body["kind"] = kind
    if let page = note?.page ?? ink?.page {
      body["page"] = page
    } else {
      body["text"] = text
      body["spans"] = spans.map { span in
        ["page": span.page, "rects": span.rects.map(Self.numbers)] as [String: Any]
      }
    }
    return body
  }

  /// What a note or a drawing sends when it changes: all of what may change (the page doesn't).
  var changes: [String: Any] {
    if let note {
      return ["color": color, "rect": Self.numbers(note.rect), "body": note.body, "size": Double(note.size)]
    }
    if let ink {
      return ["color": color, "width": Double(ink.width),
              "strokes": ink.strokes.map { $0.flatMap { [Double($0.x), Double($0.y)] } }]
    }
    return ["color": color]
  }

  private static func numbers(_ rect: CGRect) -> [Double] {
    [rect.origin.x, rect.origin.y, rect.width, rect.height].map(Double.init)
  }
}

extension PaperAnnotation: Decodable {
  private enum Keys: String, CodingKey { case id, kind, color, spans, text, page, rect, body, size, width, strokes }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: Keys.self)
    id = try container.decode(String.self, forKey: .id)
    kind = try container.decode(String.self, forKey: .kind)
    color = try container.decode(String.self, forKey: .color)
    text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
    switch kind {
    case Self.noteKind:
      spans = []
      let rect = try container.decode([Double].self, forKey: .rect)
      guard rect.count == 4 else {
        throw DecodingError.dataCorruptedError(forKey: .rect, in: container, debugDescription: "a note's box is four numbers")
      }
      note = Note(page: try container.decode(Int.self, forKey: .page),
                  rect: CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]),
                  body: try container.decode(String.self, forKey: .body),
                  size: try container.decode(Double.self, forKey: .size))
    case Self.inkKind:
      spans = []
      let flat = try container.decode([[Double]].self, forKey: .strokes)
      ink = Ink(page: try container.decode(Int.self, forKey: .page),
                width: try container.decode(Double.self, forKey: .width),
                strokes: flat.map { values in
                  stride(from: 0, to: values.count - 1, by: 2).map { CGPoint(x: values[$0], y: values[$0 + 1]) }
                })
    default:
      // a kind from a newer app without spans is kept, and drawn as nothing
      spans = try container.decodeIfPresent([Span].self, forKey: .spans) ?? []
    }
  }
}

extension PaperAnnotation.Span: Decodable {
  private enum Keys: String, CodingKey { case page, rects }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: Keys.self)
    page = try container.decode(Int.self, forKey: .page)
    rects = try container.decode([[Double]].self, forKey: .rects).compactMap { values in
      values.count == 4 ? CGRect(x: values[0], y: values[1], width: values[2], height: values[3]) : nil
    }
  }
}

/// What the store needs from the backend: ProjectClient in the app, an in-memory fake in checks.
protocol AnnotationService {
  func annotations(_ projectID: String) async throws -> [PaperAnnotation]
  func addAnnotation(_ annotation: PaperAnnotation, to projectID: String) async throws
  func updateAnnotation(_ id: String, in projectID: String, kind: String?, color: String?) async throws
  /// a note or a drawing, changed as a whole
  func replaceAnnotation(_ annotation: PaperAnnotation, in projectID: String) async throws
  func removeAnnotation(_ id: String, from projectID: String) async throws
}

extension ProjectClient: AnnotationService {}
