import PDFKit

/// The dock's pen, eraser and text tools on one PDF view, and selecting, moving and resizing notes and
/// drawings with Select, as objects on a slide are.
///
/// Every gesture shows its result on the page sheets as it goes and is stored once, when the pointer
/// lifts, as one step to undo: a stroke, a pass of the eraser, a move, a resize. A note is written in
/// place, in an editor on its page; strokes drawn close together in quick succession, in the same pen,
/// become one drawing.
@MainActor
final class FreehandTools {
  let canvas: FreehandCanvas
  var markup: MarkupTools?
  weak var store: AnnotationStore?
  /// nil for a loose document: no tool but Select, and nothing of these to select
  var projectID: String?
  /// The selected note or drawing, or nil when there is none any more. `settled` once nothing is moving
  /// it: its palette shows then, and stays away while it is dragged.
  var onSelection: (_ mark: PaperAnnotation?, _ settled: Bool) -> Void = { _, _ in }

  private weak var pdfView: AnnotatingPDFView?
  private(set) var selection: String?
  private var editing: Editing?
  /// the drawing the last stroke went into, and when
  private var lastDrawing: (id: String, page: Int, at: Date)?
  private var nudging: Nudge?
  /// the dock's colour and size as last seen, so a change to one of them reaches an open editor alone
  private var style: (color: AnnotationColor, size: CGFloat)?
  private var scale: CGFloat = 0

  private struct Editing {
    /// the stored note, or nil while a new one is written
    let mark: PaperAnnotation?
    var note: PaperAnnotation.Note
    var color: AnnotationColor
    let editor: NoteEditor
    let sheet: PageSheet
  }

  /// Arrow keys move the selection a little at a time; the run of presses is stored once.
  private struct Nudge {
    let original: PaperAnnotation
    var offset: CGVector
    var commit: Task<Void, Never>
  }

  /// The eraser's reach on screen; on the page it is this over the zoom.
  static let eraserRadius: CGFloat = 8
  /// how far the pointer travels before a press becomes a drag, in view points
  static let dragThreshold: CGFloat = 3
  /// screen points a press may be off a note's box or a stroke and still take it
  static let reach: CGFloat = 4
  /// a run of arrow-key presses is stored this long after the last
  static let nudgeSettle: Duration = .milliseconds(450)

  init(canvas: FreehandCanvas) {
    self.canvas = canvas
    canvas.onSheetLeaving = { [weak self] sheet in
      guard let self, self.editing?.sheet === sheet else { return }
      self.endEditing()
    }
  }

  var tool: MarkupTool { projectID == nil ? .select : (markup?.tool ?? .select) }
  var isEditing: Bool { editing != nil }
  var selectedMark: PaperAnnotation? { selection.flatMap(canvas.mark) }

  func attach(_ pdfView: AnnotatingPDFView) {
    self.pdfView = pdfView
    scale = pdfView.scaleFactor
  }

  private var viewScale: CGFloat { max(pdfView?.scaleFactor ?? 1, 0.01) }

  // MARK: - Selection

  func select(_ mark: PaperAnnotation, settled: Bool) {
    if selection != mark.id { flushNudge() }
    selection = mark.id
    canvas.select(mark.id)
    onSelection(mark, settled)
  }

  /// Nothing selected; `quietly` when the controller is the one asking.
  func deselect(quietly: Bool = false) {
    flushNudge()
    guard selection != nil else { return }
    selection = nil
    canvas.select(nil)
    if !quietly { onSelection(nil, true) }
  }

  /// The topmost note or drawing under a point in page space. A press inside the selected one's box
  /// counts as on it, so a thin drawing can be dragged from anywhere within its box.
  func hit(at point: CGPoint, onPage index: Int, notesOnly: Bool = false) -> PaperAnnotation? {
    let slop = Self.reach / viewScale
    for mark in canvas.marks(onPage: index).reversed() {
      if let note = mark.note {
        if note.rect.insetBy(dx: -slop, dy: -slop).contains(point) { return mark }
      } else if !notesOnly, let ink = mark.ink, InkGeometry.hits(ink.strokes, width: ink.width, at: point, slop: slop) {
        return mark
      }
    }
    if !notesOnly, let selected = selectedMark, selected.pages.first == index,
      let grips = Grips(selected, scale: viewScale), grips.box.contains(point)
    {
      return selected
    }
    return nil
  }

  // MARK: - Gestures

  /// The tool's gesture for a press, or nil to leave it to PDFKit (text selection, links, the palette).
  func gesture(for event: NSEvent) -> PointerGesture? {
    guard let pdfView, store != nil, let document = pdfView.document else { return nil }
    let point = pdfView.convert(event.locationInWindow, from: nil)
    // a press while writing stores the note; the press then does what it does
    endEditing()
    flushNudge()
    guard let page = pdfView.page(for: point, nearest: tool != .select) else {
      deselect()
      return nil
    }
    let index = document.index(for: page)
    let local = pdfView.convert(point, to: page)
    switch tool {
    case .select:
      return choosing(event, at: point, local, on: page, index: index)
    case .ink:
      deselect()
      return drawing(from: local, on: page, index: index)
    case .eraser:
      deselect()
      return erasing(from: point)
    case .note:
      deselect()
      if let note = hit(at: local, onPage: index, notesOnly: true) {
        edit(note, at: local)
        return .taken
      }
      return writing(from: point, local, on: page, index: index)
    }
  }

  /// Select: a handle of the selection resizes it, a mark is selected and can be dragged, a double click
  /// on a note opens it for writing, and anywhere else is PDFKit's.
  private func choosing(_ event: NSEvent, at point: NSPoint, _ local: CGPoint, on page: PDFPage, index: Int)
    -> PointerGesture?
  {
    if let selected = selectedMark, selected.pages.first == index, let grips = Grips(selected, scale: viewScale),
      let handle = grips.handle(at: local)
    {
      return resizing(selected, by: handle, grips: grips, from: local, on: page)
    }
    guard let mark = hit(at: local, onPage: index) else {
      deselect()
      return nil
    }
    select(mark, settled: false)
    if event.clickCount >= 2, mark.note != nil {
      edit(mark, at: local)
      return .taken
    }
    return moving(mark, from: point, on: page)
  }

  private func moving(_ mark: PaperAnnotation, from start: NSPoint, on page: PDFPage) -> PointerGesture {
    guard let pdfView, let frame = Grips.frame(of: mark) else { return .taken }
    let box = page.bounds(for: pdfView.displayBox)
    let origin = pdfView.convert(start, to: page)
    var moved: PaperAnnotation?
    return PointerGesture(
      drag: { [weak self] location in
        guard let self, let pdfView = self.pdfView,
          moved != nil || hypot(location.x - start.x, location.y - start.y) >= Self.dragThreshold
        else { return }
        if moved == nil { NSCursor.closedHand.set() }
        let now = pdfView.convert(location, to: page)
        let offset = Reshape.offset(CGVector(dx: now.x - origin.x, dy: now.y - origin.y), keeping: frame, within: box)
        let shifted = Reshape.moved(mark, by: offset)
        moved = shifted
        self.canvas.show(shifted)
      },
      end: { [weak self] _ in
        guard let self else { return }
        if let moved { self.store?.replace(moved, undo: self.pdfView?.undoManager) }
        self.settle()
      })
  }

  private func resizing(_ mark: PaperAnnotation, by handle: Grips.Handle, grips: Grips, from start: CGPoint,
                        on page: PDFPage) -> PointerGesture {
    guard let pdfView else { return .taken }
    let box = page.bounds(for: pdfView.displayBox)
    // where on the handle the pointer took it, so the box's edge follows the pointer without a jump
    let anchor = grips.anchor(of: handle)
    let grab = CGVector(dx: start.x - anchor.x, dy: start.y - anchor.y)
    var resized: PaperAnnotation?
    onSelection(mark, false)
    return PointerGesture(
      drag: { [weak self] location in
        guard let self, let pdfView = self.pdfView else { return }
        let now = pdfView.convert(location, to: page)
        let target = CGPoint(x: now.x - grab.dx, y: now.y - grab.dy)
        let changed = Reshape.resized(mark, handle, to: target, within: box,
                                      free: NSEvent.modifierFlags.contains(.shift))
        resized = changed
        self.canvas.show(changed)
      },
      end: { [weak self] _ in
        guard let self else { return }
        if let resized { self.store?.replace(resized, undo: self.pdfView?.undoManager) }
        self.settle()
      })
  }

  /// The selection's palette comes back once nothing moves it.
  private func settle() {
    if let mark = selectedMark { onSelection(mark, true) }
  }

  // MARK: - Pen and eraser

  private func drawing(from start: CGPoint, on page: PDFPage, index: Int) -> PointerGesture? {
    guard let pdfView, let markup, let sheet = canvas.sheet(forPage: index) else { return nil }
    let box = page.bounds(for: pdfView.displayBox)
    var points = [Self.clamp(start, to: box)]
    let stroke = sheet.beginStroke(color: markup.color.color, width: markup.inkWidth.points)
    stroke.add(points[0])
    return PointerGesture(
      drag: { [weak self] location in
        guard let self, let pdfView = self.pdfView else { return }
        let local = Self.clamp(pdfView.convert(location, to: page), to: box)
        points.append(local)
        stroke.add(local)
      },
      end: { [weak self] _ in
        // stored first, so the drawing is on the sheet before the live stroke leaves it
        if let self, let smooth = InkGeometry.stroke(from: points) { self.commit(smooth, page: index) }
        stroke.finish()
      })
  }

  /// Adds the stroke to the last drawing when it belongs there, or starts a new one.
  private func commit(_ stroke: [CGPoint], page: Int) {
    guard let store, let markup else { return }
    let width = markup.inkWidth.points
    let now = Date()
    if let last = lastDrawing, last.page == page, now.timeIntervalSince(last.at) < InkGeometry.mergeWindow,
      var drawing = store.annotation(last.id), let ink = drawing.ink,
      drawing.color == markup.color.rawValue, ink.width == width,
      InkGeometry.gap(InkGeometry.bounds(of: ink.strokes), InkGeometry.bounds(of: [stroke])) < InkGeometry.mergeDistance
    {
      drawing.ink?.strokes.append(stroke)
      store.replace(drawing, undo: pdfView?.undoManager)
      lastDrawing = (last.id, page, now)
    } else {
      let drawing = PaperAnnotation(
        color: markup.color, ink: PaperAnnotation.Ink(page: page, width: width, strokes: [stroke]))
      store.add(drawing, undo: pdfView?.undoManager)
      lastDrawing = (drawing.id, page, now)
    }
  }

  /// The eraser takes out what it sweeps over between one pointer sample and the next, shown at once and
  /// stored when the pointer lifts, as one step to undo however many drawings it touched.
  private func erasing(from start: NSPoint) -> PointerGesture? {
    var edited: [String: PaperAnnotation] = [:]
    var last: (page: PDFPage, point: CGPoint)?
    let rub: (NSPoint) -> Void = { [weak self] location in
      guard let self, let pdfView = self.pdfView, let document = pdfView.document,
        let page = pdfView.page(for: location, nearest: false)
      else {
        last = nil
        return
      }
      let index = document.index(for: page)
      let local = pdfView.convert(location, to: page)
      let from = last?.page == page ? last?.point ?? local : local
      last = (page, local)
      let radius = Self.eraserRadius / self.viewScale
      for drawing in self.canvas.marks(onPage: index) {
        guard let ink = drawing.ink, !ink.strokes.isEmpty,
          let strokes = InkGeometry.erase(ink.strokes, from: from, to: local, radius: radius)
        else { continue }
        var changed = drawing
        changed.ink?.strokes = strokes
        edited[drawing.id] = changed
        self.canvas.show(changed)
      }
    }
    rub(start)
    return PointerGesture(drag: rub, end: { [weak self] location in
      // the sweep runs to where the pointer lifted, which no drag may have reported
      rub(location)
      guard let self, let store = self.store, !edited.isEmpty else { return }
      let undo = self.pdfView?.undoManager
      undo?.beginUndoGrouping()
      for (id, drawing) in edited {
        if drawing.ink?.strokes.isEmpty ?? true { store.remove(id, undo: undo) } else { store.replace(drawing, undo: undo) }
      }
      undo?.endUndoGrouping()
      undo?.setActionName(L("擦除", "Erase"))
      self.lastDrawing = nil
    })
  }

  // MARK: - Notes

  /// The text tool on the page: a click starts a note that widens as it is written, a drag sets its width.
  private func writing(from start: NSPoint, _ local: CGPoint, on page: PDFPage, index: Int) -> PointerGesture {
    guard let pdfView else { return .taken }
    let box = page.bounds(for: pdfView.displayBox)
    var dragged: CGRect?
    return PointerGesture(
      drag: { [weak self] location in
        guard let self, let pdfView = self.pdfView,
          dragged != nil || hypot(location.x - start.x, location.y - start.y) >= Self.dragThreshold
        else { return }
        let now = Self.clamp(pdfView.convert(location, to: page), to: box)
        let rect = CGRect(x: min(local.x, now.x), y: min(local.y, now.y), width: abs(now.x - local.x), height: abs(now.y - local.y))
        dragged = rect
        self.canvas.outline(rect, onPage: index)
      },
      end: { [weak self] _ in
        guard let self, let markup = self.markup else { return }
        self.canvas.outline(nil, onPage: index)
        let size = markup.noteSize
        if let dragged, dragged.width >= size * NoteText.minimumWidth {
          let height = NoteText.height(of: "", size: size, width: dragged.width)
          let rect = CGRect(x: dragged.minX, y: dragged.maxY - height, width: dragged.width, height: height)
          self.open(PaperAnnotation.Note(page: index, rect: rect, body: "", size: size), color: markup.color,
                    stored: nil, caret: nil, grows: nil)
        } else {
          // the first line's middle at the click; it widens as it is written, up to the page's edge
          let x = min(max(local.x, box.minX + 2), box.maxX - size * NoteText.minimumWidth - 2)
          let height = NoteText.height(of: "", size: size, width: .greatestFiniteMagnitude)
          let top = min(local.y + height / 2, box.maxY - 2)
          let rect = CGRect(x: x, y: top - height, width: size * NoteText.minimumWidth, height: height)
          self.open(PaperAnnotation.Note(page: index, rect: rect, body: "", size: size), color: markup.color,
                    stored: nil, caret: nil, grows: box.maxX - x - 2)
        }
      })
  }

  /// Opens a stored note for writing, the caret where the click was or at the end.
  func edit(_ mark: PaperAnnotation, at point: CGPoint? = nil) {
    guard let note = mark.note else { return }
    flushNudge()
    selection = nil
    canvas.select(nil)
    onSelection(nil, true)
    open(note, color: mark.tint, stored: mark, caret: point, grows: nil)
  }

  private func open(_ note: PaperAnnotation.Note, color: AnnotationColor, stored: PaperAnnotation?, caret: CGPoint?,
                    grows: CGFloat?) {
    guard let pdfView, let sheet = canvas.sheet(forPage: note.page), let transform = sheet.transform else { return }
    let scale = sheet.scale
    let editor = NoteEditor(frame: note.rect.applying(transform), size: note.size * scale, color: color.text,
                            grows: grows.map { $0 * scale })
    editor.string = note.body
    // only this editor: a late close of the one before mustn't end a new one
    editor.onFinish = { [weak self, weak editor] keep in
      guard let self, let editor, self.editing?.editor === editor else { return }
      self.endEditing(select: keep)
    }
    editor.onResize = { [weak self] in self?.outlineEditor() }
    editor.onStep = { [weak self] up in
      guard let self, let editing = self.editing else { return }
      self.restyle(size: NoteText.step(editing.note.size, up: up))
    }
    if let stored { canvas.hide(stored.id) }
    sheet.addEditor(editor)
    editor.fit()
    editing = Editing(mark: stored, note: note, color: color, editor: editor, sheet: sheet)
    style = markup.map { ($0.color, $0.noteSize) }
    pdfView.window?.makeFirstResponder(editor)
    if let caret {
      editor.placeCaret(at: editor.convert(caret.applying(transform), from: sheet))
    } else {
      editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }
    outlineEditor()
  }

  /// The dashed box follows the editor as it grows.
  private func outlineEditor() {
    guard let editing, let transform = editing.sheet.transform else { return }
    canvas.outline(editing.editor.frame.applying(transform.inverted()), onPage: editing.note.page)
  }

  /// The dock's colour or size changed: an open editor takes the one that changed.
  func markupChanged() {
    guard let markup else { return }
    defer { style = (markup.color, markup.noteSize) }
    guard editing != nil, let style else { return }
    if markup.color != style.color { restyle(color: markup.color) }
    if markup.noteSize != style.size { restyle(size: markup.noteSize) }
  }

  private func restyle(size: CGFloat? = nil, color: AnnotationColor? = nil) {
    guard var editing else { return }
    if let size { editing.note.size = NoteText.clamped(size) }
    if let color { editing.color = color }
    self.editing = editing
    editing.editor.restyle(size: editing.note.size * editing.sheet.scale, color: editing.color.text)
  }

  /// Closes the editor and stores what it holds; a note left empty is deleted. `select` leaves it
  /// selected, as Esc does.
  func endEditing(select keep: Bool = false) {
    guard let editing else { return }
    self.editing = nil
    let editor = editing.editor
    // closed with Esc, the keys go back to the page; closed by a click elsewhere, they stay there
    let focused = editor.window?.firstResponder === editor
    let body = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
    // a note that widened as it was written keeps the width of its longest line
    var width = editing.note.rect.width
    if let grows = editor.grows { width = min(NoteText.width(of: body, size: editing.note.size), grows / editing.sheet.scale) }
    editor.close()
    canvas.outline(nil, onPage: editing.note.page)
    canvas.hide(nil)
    if focused, let pdfView { pdfView.window?.makeFirstResponder(pdfView) }

    var note = editing.note
    note.body = body
    let height = NoteText.height(of: body, size: note.size, width: width)
    note.rect = CGRect(x: note.rect.minX, y: note.rect.maxY - height, width: width, height: height)
    note = Reshape.rounded(note)
    guard let store else { return }
    let undo = pdfView?.undoManager
    var result: PaperAnnotation?
    if let stored = editing.mark {
      if body.isEmpty {
        store.remove(stored.id, undo: undo)
      } else {
        var changed = stored
        changed.note = note
        changed.color = editing.color.rawValue
        store.replace(changed, undo: undo)
        result = changed
      }
    } else if !body.isEmpty {
      let written = PaperAnnotation(color: editing.color, note: note)
      store.add(written, undo: undo)
      result = written
    }
    if keep, let result { select(result, settled: true) }
  }

  // MARK: - Keys

  /// Arrow keys: the selection moves a screen point at a time, ten with Shift. A run of presses shows
  /// at once and is stored a moment after the last, as one step to undo.
  func nudge(dx: CGFloat, dy: CGFloat) {
    guard let mark = selectedMark, let pdfView, let page = pdfView.document?.page(at: mark.pages[0]) else { return }
    let original = nudging?.original ?? mark
    guard let frame = Grips.frame(of: original) else { return }
    let step = CGVector(dx: dx / viewScale, dy: dy / viewScale)
    let wanted = CGVector(dx: (nudging?.offset.dx ?? 0) + step.dx, dy: (nudging?.offset.dy ?? 0) + step.dy)
    let offset = Reshape.offset(wanted, keeping: frame, within: page.bounds(for: pdfView.displayBox))
    let moved = Reshape.moved(original, by: offset)
    canvas.show(moved)
    onSelection(moved, true)
    nudging?.commit.cancel()
    let commit = Task { [weak self] in
      try? await Task.sleep(for: Self.nudgeSettle)
      guard !Task.isCancelled else { return }
      self?.flushNudge()
    }
    nudging = Nudge(original: original, offset: offset, commit: commit)
  }

  /// Stores a run of arrow-key moves now.
  func flushNudge() {
    guard let nudging else { return }
    self.nudging = nil
    nudging.commit.cancel()
    store?.replace(Reshape.moved(nudging.original, by: nudging.offset), undo: pdfView?.undoManager)
  }

  // MARK: - Pointer

  /// The cursor over a point in the view: the tool's, or on the selection's handles a resize cursor and on
  /// a note or a drawing an open hand; nil leaves it to PDFKit.
  func cursor(at point: NSPoint) -> NSCursor? {
    switch tool {
    case .note: return .iBeam
    case .ink: return .crosshair
    case .eraser: return Self.eraserCursor
    case .select:
      guard let pdfView, let document = pdfView.document, let page = pdfView.page(for: point, nearest: false) else {
        return nil
      }
      let index = document.index(for: page)
      let local = pdfView.convert(point, to: page)
      if let selected = selectedMark, selected.pages.first == index, let grips = Grips(selected, scale: viewScale),
        let handle = grips.handle(at: local)
      {
        return Self.cursor(for: handle)
      }
      return hit(at: local, onPage: index) != nil ? .openHand : nil
    }
  }

  /// Whether a point in the view is on a note, a drawing or a handle, where a link's preview would be in
  /// the way.
  func covers(_ point: NSPoint) -> Bool {
    tool == .select && cursor(at: point) != nil
  }

  private static func cursor(for handle: Grips.Handle) -> NSCursor {
    if #available(macOS 15.0, *) {
      let position: NSCursor.FrameResizePosition
      switch handle {
      case .topLeft: position = .topLeft
      case .topRight: position = .topRight
      case .bottomLeft: position = .bottomLeft
      case .bottomRight: position = .bottomRight
      case .left: position = .left
      case .right: position = .right
      }
      return .frameResize(position: position, directions: .all)
    }
    return handle.isSide ? .resizeLeftRight : .crosshair
  }

  // MARK: - Pieces

  /// The view scrolled, zoomed or changed size. A zoom stores an open note where it was, and the handles
  /// keep their size on screen.
  func viewMoved() {
    guard let pdfView, pdfView.scaleFactor != scale else { return }
    scale = pdfView.scaleFactor
    endEditing()
    canvas.scaleChanged()
  }

  func reset() {
    endEditing()
    deselect(quietly: true)
    lastDrawing = nil
  }

  private static func clamp(_ point: CGPoint, to box: CGRect) -> CGPoint {
    CGPoint(x: min(max(point.x, box.minX), box.maxX), y: min(max(point.y, box.minY), box.maxY))
  }

  /// a ring the eraser's size, so what it will take out is visible before the press
  private static let eraserCursor: NSCursor = {
    let side = eraserRadius * 2 + 2
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
      let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
      NSColor.white.withAlphaComponent(0.55).setFill()
      ring.fill()
      NSColor.black.withAlphaComponent(0.7).setStroke()
      ring.lineWidth = 1
      ring.stroke()
      return true
    }
    return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
  }()
}

extension PointerGesture {
  /// a press a tool has dealt with at once: nothing follows it
  static let taken = PointerGesture(drag: { _ in }, end: { _ in })
}
