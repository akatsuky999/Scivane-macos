import PDFKit

/// Draws marks as PDFKit annotations on the in-memory document and answers which mark is under a
/// point. The document is never written back, so the source file stays untouched.
@MainActor
final class AnnotationLayer {
  private struct Drawn {
    let mark: PaperAnnotation
    let pieces: [(page: PDFPage, annotation: PDFAnnotation)]
  }

  private(set) weak var document: PDFDocument?
  /// in drawing order, so the latest mark is on top for hit testing
  private var order: [String] = []
  private var drawn: [String: Drawn] = [:]

  /// Highlight fill opacity; PDFKit multiplies it over the page, so text stays black.
  static let fillAlpha: CGFloat = 0.5
  /// clicks this close to a line still hit it, in page points
  static let hitSlop: CGFloat = 1.5

  var drawnCount: Int { drawn.count }

  /// Make the document show exactly these marks. Unchanged marks are left alone.
  func sync(_ marks: [PaperAnnotation], on document: PDFDocument?) {
    if document !== self.document {
      clear()
      self.document = document
    }
    guard let document else { return }
    let wanted = Dictionary(marks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for (id, entry) in drawn where wanted[id] != entry.mark { erase(id) }
    for mark in marks where drawn[mark.id] == nil {
      drawn[mark.id] = Drawn(mark: mark, pieces: Self.pieces(of: mark, in: document))
    }
    order = marks.map(\.id).filter { drawn[$0] != nil }
  }

  /// Remove everything this layer added; other annotations in the PDF are untouched.
  func clear() {
    for id in Array(drawn.keys) { erase(id) }
    order = []
  }

  private func erase(_ id: String) {
    guard let entry = drawn.removeValue(forKey: id) else { return }
    for piece in entry.pieces { piece.page.removeAnnotation(piece.annotation) }
  }

  /// The topmost mark under a point on a page.
  func mark(at point: CGPoint, onPage index: Int) -> PaperAnnotation? {
    for id in order.reversed() {
      guard let mark = drawn[id]?.mark else { continue }
      for span in mark.spans where span.page == index {
        if span.rects.contains(where: { $0.insetBy(dx: -Self.hitSlop, dy: -Self.hitSlop).contains(point) }) {
          return mark
        }
      }
    }
    return nil
  }

  // MARK: - Geometry

  /// A selection as one span per page with one rect per text line, rounded to 0.01 pt so the
  /// stored file stays small and stable.
  static func spans(of selection: PDFSelection, in document: PDFDocument) -> [PaperAnnotation.Span] {
    var byPage: [Int: [CGRect]] = [:]
    for line in selection.selectionsByLine() {
      for page in line.pages {
        let rect = line.bounds(for: page)
        guard rect.width >= 0.5, rect.height >= 0.5 else { continue }
        let index = document.index(for: page)
        guard index != NSNotFound else { continue }
        byPage[index, default: []].append(rounded(rect))
      }
    }
    return byPage.keys.sorted().map { PaperAnnotation.Span(page: $0, rects: byPage[$0]!) }
  }

  private static func rounded(_ rect: CGRect) -> CGRect {
    func r(_ value: CGFloat) -> CGFloat { (value * 100).rounded() / 100 }
    return CGRect(x: r(rect.minX), y: r(rect.minY), width: r(rect.width), height: r(rect.height))
  }

  /// One PDFKit annotation per line rect, so every piece is a plain box whose bounds are the rect.
  static func pieces(of mark: PaperAnnotation, in document: PDFDocument)
    -> [(page: PDFPage, annotation: PDFAnnotation)]
  {
    var pieces: [(page: PDFPage, annotation: PDFAnnotation)] = []
    for span in mark.spans {
      guard let page = document.page(at: span.page) else { continue }
      for rect in span.rects {
        let annotation = make(mark, rect: rect)
        page.addAnnotation(annotation)
        pieces.append((page, annotation))
      }
    }
    return pieces
  }

  static func make(_ mark: PaperAnnotation, rect: CGRect) -> PDFAnnotation {
    let underline = mark.style == .underline
    let annotation = PDFAnnotation(bounds: rect, forType: underline ? .underline : .highlight,
                                   withProperties: nil)
    annotation.color = underline ? mark.tint.color : mark.tint.color.withAlphaComponent(fillAlpha)
    // quad points are relative to the bounds: upper left, upper right, lower left, lower right
    annotation.quadrilateralPoints = [
      CGPoint(x: 0, y: rect.height), CGPoint(x: rect.width, y: rect.height),
      CGPoint(x: 0, y: 0), CGPoint(x: rect.width, y: 0),
    ].map { NSValue(point: $0) }
    annotation.setValue("scivane:\(mark.id)", forAnnotationKey: .name)
    return annotation
  }
}
