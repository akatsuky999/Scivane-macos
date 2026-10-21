import PDFKit

/// Notes and drawings over the source's pages. PDFKit asks for a view to lay over each page as the page
/// comes into sight and takes it away when the page leaves; each such sheet shows the marks of its page.
///
/// They are not PDF annotations. PDFKit draws an annotation that draws itself in a layer of its own, and
/// that layer stays on the page after the annotation is removed: an erased stroke stayed in sight and a
/// moved or rewritten note left a copy behind. A sheet shows exactly the marks held here and changes one
/// mark's view at a time. Sheets are in the page's own coordinates, which PDFKit magnifies with the page,
/// so scrolling and zooming move the marks along at no cost; marks are shapes, so they stay sharp at any
/// zoom without a bitmap to redraw.
@MainActor
final class FreehandCanvas: NSObject, @preconcurrency PDFPageOverlayViewProvider {
  weak var pdfView: PDFView?
  /// A page's sheet is about to leave the screen; a note being written on it is stored first.
  var onSheetLeaving: (PageSheet) -> Void = { _ in }

  /// The notes and drawings shown, in drawing order: as stored, or as they are in the middle of a gesture.
  private(set) var marks: [PaperAnnotation] = []
  private var sheets: [Int: PageSheet] = [:]
  /// the note being written, which its editor stands in for
  private var hidden: String?
  /// the selected mark
  private(set) var selected: String?
  /// a box with no handles: a note being written, or a text box being dragged out
  private var outline: (page: Int, rect: CGRect)?

  func mark(_ id: String) -> PaperAnnotation? { marks.first { $0.id == id } }

  func marks(onPage page: Int) -> [PaperAnnotation] { marks.filter { $0.pages.first == page } }

  func sheet(forPage page: Int) -> PageSheet? { sheets[page] }

  // MARK: - Content

  /// The store's notes and drawings. Only the pages where something changed are touched.
  func sync(_ freehand: [PaperAnnotation]) {
    guard freehand != marks else { return }
    let before = Dictionary(marks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let after = Dictionary(freehand.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var pages = Set<Int>()
    for mark in marks where after[mark.id] != mark { pages.formUnion(mark.pages) }
    for mark in freehand where before[mark.id] != mark { pages.formUnion(mark.pages) }
    // the same marks in another order: an undone delete going back to its place
    if pages.isEmpty { pages = Set(freehand.flatMap(\.pages)) }
    marks = freehand
    if let selected, after[selected] == nil { self.selected = nil }
    for page in pages { refresh(page) }
    drawChrome()
  }

  /// Shows `mark` as it is in the middle of a gesture, without storing it. The next sync puts back
  /// whatever the store holds.
  func show(_ mark: PaperAnnotation) {
    if let index = marks.firstIndex(where: { $0.id == mark.id }) { marks[index] = mark } else { marks.append(mark) }
    for page in mark.pages { sheets[page]?.update(mark) }
    if selected == mark.id { drawChrome() }
  }

  /// Keeps a note off its page while its editor is on it; nil puts it back.
  func hide(_ id: String?) {
    guard id != hidden else { return }
    let pages = [hidden, id].compactMap { $0.flatMap(mark)?.pages.first }
    hidden = id
    for page in Set(pages) { refresh(page) }
  }

  // MARK: - Selection

  func select(_ id: String?) {
    guard id != selected else { return }
    selected = id
    drawChrome()
  }

  /// A dashed box without handles on a page, or none.
  func outline(_ rect: CGRect?, onPage page: Int) {
    outline = rect.map { (page, $0) }
    drawChrome()
  }

  /// The zoom changed: the handles stay the same size on screen.
  func scaleChanged() { drawChrome() }

  private func refresh(_ page: Int) {
    sheets[page]?.show(marks(onPage: page), hidden: hidden)
  }

  private func drawChrome() {
    let scale = pdfView?.scaleFactor ?? 1
    let selection = selected.flatMap(mark).flatMap { mark in Grips(mark, scale: scale).map { (mark.pages[0], $0) } }
    for (page, sheet) in sheets {
      if let outline, outline.page == page {
        sheet.chrome(Grips(frame: outline.rect, sides: false, scale: scale), handles: false)
      } else if let selection, selection.0 == page {
        sheet.chrome(selection.1, handles: true)
      } else {
        sheet.chrome(nil, handles: false)
      }
    }
  }

  // MARK: - PDFPageOverlayViewProvider

  func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
    guard let index = view.document?.index(for: page), index != NSNotFound else { return nil }
    return PageSheet(page: page, index: index, pdfView: view)
  }

  func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: NSView, for page: PDFPage) {
    guard let sheet = overlayView as? PageSheet else { return }
    sheets[sheet.index] = sheet
    sheet.show(marks(onPage: sheet.index), hidden: hidden)
    drawChrome()
  }

  func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
    guard let sheet = overlayView as? PageSheet else { return }
    onSheetLeaving(sheet)
    // a new document's sheet for the same page number may already be in its place
    if sheets[sheet.index] === sheet { sheets[sheet.index] = nil }
  }
}

/// One page's notes and drawings, laid over the page by PDFKit. Takes no clicks: presses reach the PDF
/// view, which hands them to the tools. Only a note's editor, while open, takes its own.
final class PageSheet: NSView {
  let page: PDFPage
  let index: Int
  /// Page space to this view. Fixed while the page shows: PDFKit zooms by magnifying the page views,
  /// not by resizing them. Nil until the sheet has been laid out on its page.
  private(set) var transform: CGAffineTransform?
  private weak var pdfView: PDFView?
  private let stack = MarkStack()
  private let chromeView = SelectionChrome()
  private var views: [String: MarkView] = [:]
  private var shown: [PaperAnnotation] = []
  private var hiddenID: String?
  private var chrome: (grips: Grips, handles: Bool)?

  init(page: PDFPage, index: Int, pdfView: PDFView) {
    self.page = page
    self.index = index
    self.pdfView = pdfView
    super.init(frame: .zero)
    wantsLayer = true
    for view in [stack, chromeView] as [NSView] {
      view.frame = bounds
      view.autoresizingMask = [.width, .height]
      addSubview(view)
    }
  }

  required init?(coder: NSCoder) { nil }

  override var isFlipped: Bool { false }

  override func hitTest(_ point: NSPoint) -> NSView? {
    super.hitTest(point) as? NoteEditor
  }

  override func layout() {
    super.layout()
    guard let pdfView, superview != nil else { return }
    func map(_ point: CGPoint) -> CGPoint { convert(pdfView.convert(point, from: page), from: pdfView) }
    let origin = map(.zero), x = map(CGPoint(x: 100, y: 0)), y = map(CGPoint(x: 0, y: 100))
    let next = CGAffineTransform(a: (x.x - origin.x) / 100, b: (x.y - origin.y) / 100,
                                 c: (y.x - origin.x) / 100, d: (y.y - origin.y) / 100, tx: origin.x, ty: origin.y)
    if let transform, transform.isClose(to: next) { return }
    transform = next
    for mark in shown { place(mark) }
    drawChrome()
  }

  /// Sheet units per page point.
  var scale: CGFloat { transform.map { hypot($0.a, $0.b) } ?? 1 }

  // MARK: - Marks

  /// Exactly these marks, in this order; views of unchanged marks are kept.
  func show(_ marks: [PaperAnnotation], hidden: String?) {
    shown = marks
    hiddenID = hidden
    let ids = Set(marks.map(\.id))
    for (id, view) in views where !ids.contains(id) {
      view.removeFromSuperview()
      views[id] = nil
    }
    for mark in marks { place(mark) }
    let order = marks.compactMap { views[$0.id] }
    if stack.subviews != order { stack.subviews = order }
  }

  /// One mark changed, in the middle of a gesture.
  func update(_ mark: PaperAnnotation) {
    if let index = shown.firstIndex(where: { $0.id == mark.id }) { shown[index] = mark } else { shown.append(mark) }
    place(mark)
  }

  private func place(_ mark: PaperAnnotation) {
    let view: MarkView
    if let existing = views[mark.id], existing.shows(mark) {
      view = existing
    } else {
      views[mark.id]?.removeFromSuperview()
      view = mark.note != nil ? NoteView() : InkView()
      views[mark.id] = view
      stack.addSubview(view)
    }
    view.isHidden = mark.id == hiddenID
    if let transform { view.show(mark, transform) }
  }

  // MARK: - On top of the marks

  /// The dashed box and, when `handles`, its handles; nil takes them away.
  func chrome(_ grips: Grips?, handles: Bool) {
    chrome = grips.map { ($0, handles) }
    drawChrome()
  }

  private func drawChrome() {
    guard let transform, let chrome else { return chromeView.clear() }
    // screen points to this view's units, at the view's zoom
    let unit = 100 / max(abs(convert(NSSize(width: 100, height: 0), to: nil).width), 0.01)
    chromeView.show(box: chrome.grips.box.applying(transform),
                    handles: chrome.handles ? chrome.grips.handles.map { $0.point.applying(transform) } : [],
                    unit: unit)
  }

  /// A note's editor sits over the marks, under the dashed box.
  func addEditor(_ editor: NoteEditor) {
    addSubview(editor, positioned: .below, relativeTo: chromeView)
  }

  /// The stroke being drawn, over the marks, until it is stored.
  func beginStroke(color: NSColor, width: CGFloat) -> LiveStroke {
    let stroke = LiveStroke(frame: bounds, transform: transform ?? .identity, color: color, width: width * scale)
    stroke.autoresizingMask = [.width, .height]
    addSubview(stroke, positioned: .below, relativeTo: chromeView)
    return stroke
  }
}

/// The marks of a sheet, in drawing order.
private final class MarkStack: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One note or drawing on a sheet.
class MarkView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  /// whether this view can show `mark` (a note's view can't show a drawing)
  func shows(_ mark: PaperAnnotation) -> Bool { false }
  func show(_ mark: PaperAnnotation, _ transform: CGAffineTransform) {}
}

/// A drawing: its strokes as one shape, with round ends and joins.
final class InkView: MarkView {
  private var shown: (ink: PaperAnnotation.Ink, color: String, transform: CGAffineTransform)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { nil }

  override func makeBackingLayer() -> CALayer {
    let shape = CAShapeLayer()
    shape.fillColor = nil
    shape.lineCap = .round
    shape.lineJoin = .round
    return shape
  }

  override var wantsUpdateLayer: Bool { true }

  override func shows(_ mark: PaperAnnotation) -> Bool { mark.ink != nil }

  override func show(_ mark: PaperAnnotation, _ transform: CGAffineTransform) {
    guard let ink = mark.ink, let shape = layer as? CAShapeLayer else { return }
    if let shown, shown.ink == ink, shown.color == mark.color, shown.transform == transform { return }
    shown = (ink, mark.color, transform)
    let box = InkGeometry.frame(of: ink)
    guard !box.isNull else {
      shape.path = nil
      return
    }
    let frame = box.applying(transform).insetBy(dx: -1, dy: -1)
    let local = transform.concatenating(CGAffineTransform(translationX: -frame.minX, y: -frame.minY))
    let path = CGMutablePath()
    for stroke in ink.strokes { path.addPath(InkGeometry.path(through: stroke, local)) }
    self.frame = frame
    shape.path = path
    shape.lineWidth = ink.width * hypot(transform.a, transform.b)
    shape.strokeColor = mark.tint.color.cgColor
  }
}

/// A note: its words in the marker colour a shade darker, wrapped to its box. Drawn as the outlines of
/// its glyphs, laid out as the editor lays them out; drawn as text only when a glyph has no outline.
final class NoteView: MarkView {
  private var shown: (note: PaperAnnotation.Note, color: String, transform: CGAffineTransform)?
  /// the words laid out, kept while only the place changes
  private var layout: (key: Key, layout: NoteText.Layout)?
  private var fallback: (body: String, size: CGFloat, color: NSColor)?

  private struct Key: Equatable {
    let body: String
    let size: CGFloat
    let width: CGFloat
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { nil }

  override func makeBackingLayer() -> CALayer { CAShapeLayer() }

  override var wantsUpdateLayer: Bool { fallback == nil }

  override func shows(_ mark: PaperAnnotation) -> Bool { mark.note != nil }

  override func show(_ mark: PaperAnnotation, _ transform: CGAffineTransform) {
    guard let note = mark.note, let shape = layer as? CAShapeLayer else { return }
    if let shown, shown.note == note, shown.color == mark.color, shown.transform == transform { return }
    shown = (note, mark.color, transform)
    let key = Key(body: note.body, size: note.size, width: note.rect.width)
    if layout?.key != key {
      layout = (key, NoteText.layout(note.body, size: note.size, width: note.rect.width, outlines: true))
    }
    let frame = note.rect.applying(transform)
    self.frame = frame
    guard let words = layout?.layout, words.complete, let outlines = words.outlines else {
      shape.path = nil
      fallback = (note.body, note.size * hypot(transform.a, transform.b), mark.tint.text)
      needsDisplay = true
      return
    }
    if fallback != nil {
      fallback = nil
      shape.contents = nil
    }
    // the layout runs down from the box's top left, the page and this view up from the bottom left
    let onPage = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: note.rect.minX, ty: note.rect.maxY)
    var local = onPage.concatenating(transform).concatenating(CGAffineTransform(translationX: -frame.minX, y: -frame.minY))
    shape.path = outlines.copy(using: &local)
    shape.fillColor = mark.tint.text.cgColor
  }

  /// Only for words with a glyph that has no outline; draw(in:) sets them from the top of the box.
  override func draw(_ dirtyRect: NSRect) {
    guard let fallback else { return }
    (fallback.body as NSString).draw(in: bounds, withAttributes: NoteText.attributes(size: fallback.size, color: fallback.color))
  }
}

/// The dashed box around the selection and its round handles, in the system's accent colour, the same
/// size on screen at any zoom.
private final class SelectionChrome: NSView {
  private let box = CAShapeLayer()
  private let handles = CAShapeLayer()

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    for shape in [box, handles] {
      // nothing here eases into place: it follows the pointer
      shape.actions = ["path": NSNull(), "lineWidth": NSNull(), "lineDashPattern": NSNull(), "position": NSNull(),
                       "bounds": NSNull(), "hidden": NSNull(), "strokeColor": NSNull(), "fillColor": NSNull()]
      layer?.addSublayer(shape)
    }
    box.fillColor = nil
  }

  required init?(coder: NSCoder) { nil }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    box.frame = bounds
    handles.frame = bounds
  }

  /// `unit` is this view's units per screen point.
  func show(box rect: CGRect, handles points: [CGPoint], unit: CGFloat) {
    let accent = NSColor.controlAccentColor.cgColor
    box.path = CGPath(rect: rect, transform: nil)
    box.strokeColor = accent
    box.lineWidth = unit
    box.lineDashPattern = [NSNumber(value: Double(4 * unit)), NSNumber(value: Double(3 * unit))]
    let dots = CGMutablePath()
    let radius = Grips.radius * unit
    for point in points {
      dots.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    }
    handles.path = dots
    handles.fillColor = accent
    handles.strokeColor = NSColor.white.cgColor
    handles.lineWidth = unit
    box.isHidden = false
    handles.isHidden = points.isEmpty
  }

  func clear() {
    box.isHidden = true
    handles.isHidden = true
  }
}

/// The stroke being drawn, in the pen's colour and width, before it is smoothed and stored.
final class LiveStroke: NSView {
  private let transform: CGAffineTransform
  private let path = CGMutablePath()

  init(frame: NSRect, transform: CGAffineTransform, color: NSColor, width: CGFloat) {
    self.transform = transform
    super.init(frame: frame)
    wantsLayer = true
    guard let shape = layer as? CAShapeLayer else { return }
    shape.strokeColor = color.cgColor
    shape.lineWidth = width
  }

  required init?(coder: NSCoder) { nil }

  override func makeBackingLayer() -> CALayer {
    let shape = CAShapeLayer()
    shape.fillColor = nil
    shape.lineCap = .round
    shape.lineJoin = .round
    return shape
  }

  override var wantsUpdateLayer: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// a point in page space
  func add(_ point: CGPoint) {
    let at = point.applying(transform)
    if path.isEmpty { path.move(to: at) } else { path.addLine(to: at) }
    (layer as? CAShapeLayer)?.path = path.copy()
  }

  func finish() { removeFromSuperview() }
}

private extension CGAffineTransform {
  /// equal but for rounding: the sheet's mapping is measured through the view, which adds noise
  func isClose(to other: CGAffineTransform) -> Bool {
    abs(a - other.a) < 1e-6 && abs(b - other.b) < 1e-6 && abs(c - other.c) < 1e-6 && abs(d - other.d) < 1e-6
      && abs(tx - other.tx) < 1e-3 && abs(ty - other.ty) < 1e-3
  }
}
