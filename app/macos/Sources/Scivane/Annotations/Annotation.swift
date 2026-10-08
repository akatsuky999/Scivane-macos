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

/// One mark on a project's source PDF, as stored in .lumen/annotations.json.
struct PaperAnnotation: Identifiable, Equatable {
  /// The part of a mark on one page: one rect per text line, in PDF page space.
  struct Span: Equatable {
    var page: Int
    var rects: [CGRect]
  }

  let id: String
  /// Kept as stored rather than as enums, so a mark written by a newer app survives a round trip.
  var kind: String
  var color: String
  let spans: [Span]
  let text: String

  var style: AnnotationKind { AnnotationKind(rawValue: kind) ?? .highlight }
  var tint: AnnotationColor { AnnotationColor(rawValue: color) ?? .yellow }

  init(id: String = UUID().uuidString, kind: AnnotationKind, color: AnnotationColor,
       spans: [Span], text: String) {
    self.id = id
    self.kind = kind.rawValue
    self.color = color.rawValue
    self.spans = spans
    self.text = text
  }

  /// Request body for the backend.
  var payload: [String: Any] {
    [
      "id": id, "kind": kind, "color": color, "text": text,
      "spans": spans.map { span in
        ["page": span.page,
         "rects": span.rects.map { [$0.origin.x, $0.origin.y, $0.width, $0.height] }] as [String: Any]
      },
    ]
  }
}

extension PaperAnnotation: Decodable {
  private enum Keys: String, CodingKey { case id, kind, color, spans, text }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: Keys.self)
    id = try container.decode(String.self, forKey: .id)
    kind = try container.decode(String.self, forKey: .kind)
    color = try container.decode(String.self, forKey: .color)
    spans = try container.decode([Span].self, forKey: .spans)
    text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
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
  func removeAnnotation(_ id: String, from projectID: String) async throws
}

extension ProjectClient: AnnotationService {}
