import Combine
import PDFKit
import SwiftUI

/// Puts marks into one PDF view: highlights and underlines as PDF annotations, notes and drawings on the
/// page sheets. Shows the palette after a text selection (to create a mark), on a clicked highlight and on
/// a selected note or drawing (to change it), takes the keys for the selection, and hands the pointer to
/// the dock's tools.
@MainActor
final class AnnotationController: NSObject {
  private enum Target: Equatable {
    case selection([PaperAnnotation.Span], text: String)
    case mark(String)
  }

  let palette: AnnotationPaletteModel
  let layer = AnnotationLayer()
  let canvas = FreehandCanvas()
  let freehand: FreehandTools

  private weak var pdfView: AnnotatingPDFView?
  private weak var container: NSView?
  private var host: PaletteHost?
  private weak var store: AnnotationStore?
  private var marks: AnyCancellable?
  /// The project whose source this view shows; nil for a loose document, which has nowhere to keep marks.
  private var projectID: String?
  private var target: Target?
  /// what the palette points at, in page space
  private var anchor: (page: Int, rect: CGRect)?
  /// the scroll view's clip view being watched; PDFKit may only create it once a document is set
  private weak var watchedClip: NSClipView?
  private var toolWatch: AnyCancellable?
  private var styleWatch: AnyCancellable?

  /// gap between the text and the palette card
  static let gap: CGFloat = 6

  init(palette: AnnotationPaletteModel? = nil) {
    self.palette = palette ?? AnnotationPaletteModel()
    freehand = FreehandTools(canvas: canvas)
    super.init()
    self.palette.onColor = { [weak self] in self?.pick($0) }
    self.palette.onKind = { [weak self] in self?.restyle($0) }
    self.palette.onSize = { [weak self] size in self?.resize(to: size) }
    self.palette.onWidth = { [weak self] width in self?.reshape { $0.ink?.width = width.points } }
    self.palette.onDelete = { [weak self] in self?.deleteEdited() }
    freehand.onSelection = { [weak self] mark, settled in self?.selected(mark, settled: settled) }
  }

  /// a palette is open, even while it is out of sight or put away for a drag
  var isShowingPalette: Bool { target != nil }
  var tool: MarkupTool { freehand.tool }
  var paletteFrame: CGRect? { host.flatMap { $0.isHidden ? nil : $0.frame } }

  /// `markup` is the dock's tools; without it there is only Select.
  func attach(_ pdfView: AnnotatingPDFView, in container: NSView, markup: MarkupTools? = nil) {
    self.pdfView = pdfView
    self.container = container
    pdfView.onPress = { [weak self] in self?.dismiss() }
    pdfView.onRelease = { [weak self] in self?.released(at: $0) }
    pdfView.onKey = { [weak self] in self?.handleKey($0) ?? false }
    pdfView.takesPointer = { [weak self] in self?.takePointer($0) }
    pdfView.toolCursor = { [weak self] in self?.freehand.cursor(at: $0) }
    canvas.pdfView = pdfView
    pdfView.pageOverlayViewProvider = canvas
    // PDFKit asks for the sheets as pages come into sight; a page already shown has to be shown again
    if let document = pdfView.document {
      pdfView.quietly {
        pdfView.document = nil
        pdfView.document = document
      }
    }
    freehand.attach(pdfView)
    freehand.markup = markup
    // both fire before the property changes; on the main queue they are handled after it
    toolWatch = markup?.$tool.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.toolChanged() }
    styleWatch = markup.map { tools in
      tools.$color.map { _ in () }.merge(with: tools.$noteSize.map { _ in () })
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.freehand.markupChanged() }
    }

    let host = PaletteHost(rootView: AnnotationPalette(model: palette))
    host.isHidden = true
    container.addSubview(host, positioned: .above, relativeTo: nil)
    self.host = host

    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: pdfView)
    center.addObserver(self, selector: #selector(viewMoved), name: .PDFViewScaleChanged, object: pdfView)
    pdfView.postsFrameChangedNotifications = true
    center.addObserver(self, selector: #selector(viewMoved), name: NSView.frameDidChangeNotification, object: pdfView)
    watchScrolling()
  }

  private func watchScrolling() {
    guard let clip = pdfView?.documentView?.enclosingScrollView?.contentView, clip !== watchedClip else { return }
    let center = NotificationCenter.default
    if let old = watchedClip { center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old) }
    clip.postsBoundsChangedNotifications = true
    center.addObserver(self, selector: #selector(viewMoved), name: NSView.boundsDidChangeNotification, object: clip)
    watchedClip = clip
  }

  /// Marks belong to `projectID`; pass nil when the document shown isn't a project's source.
  func update(store: AnnotationStore, projectID: String?) {
    if store !== self.store {
      self.store = store
      // fires before the property changes, with the new value
      marks = store.$annotations.sink { [weak self] in self?.render($0) }
    }
    freehand.store = store
    guard projectID != self.projectID else { return }
    freehand.reset()
    self.projectID = projectID
    freehand.projectID = projectID
    dismiss()
    render(store.annotations)
  }

  /// The view switched documents.
  func documentChanged() {
    freehand.reset()
    dismiss()
    watchScrolling()
    render(store?.annotations ?? [])
  }

  /// Takes this layer's marks off the document, which outlives the view.
  func detach() {
    freehand.reset()
    dismiss()
    layer.clear()
    canvas.sync([])
    pdfView?.pageOverlayViewProvider = nil
    marks = nil
    toolWatch = nil
    styleWatch = nil
    NotificationCenter.default.removeObserver(self)
  }

  private func render(_ annotations: [PaperAnnotation]) {
    let shown = projectID != nil && store?.projectID == projectID ? annotations : []
    layer.sync(shown.filter { !$0.isFreehand }, on: pdfView?.document)
    canvas.sync(shown.filter(\.isFreehand))
    guard case .mark(let id) = target else { return }
    guard let mark = shown.first(where: { $0.id == id }) else { return dismiss() }
    palette.editing = mark
    // a recoloured, resized or undone note or drawing: the palette stays with it
    if mark.isFreehand, let place = Self.place(of: mark, scale: pdfView?.scaleFactor ?? 1) {
      anchor = place
      if host?.isHidden == false { layoutPalette() }
    }
  }

  // MARK: - Gestures

  /// A selection opens the palette to create; a plain click on a highlight opens it to edit.
  func released(at point: NSPoint) {
    guard projectID != nil, let pdfView, let document = pdfView.document else { return }
    if let selection = pdfView.currentSelection,
       let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
      let spans = AnnotationLayer.spans(of: selection, in: document)
      guard let first = spans.first else { return }
      target = .selection(spans, text: text)
      palette.editing = nil
      show(at: first.page, first.rects)
    } else if let page = pdfView.page(for: point, nearest: false) {
      let index = document.index(for: page)
      guard let mark = layer.mark(at: pdfView.convert(point, to: page), onPage: index) else { return }
      target = .mark(mark.id)
      palette.editing = mark
      if let rects = mark.spans.first(where: { $0.page == index })?.rects { show(at: index, rects) }
    }
  }

  /// A press the active tool takes from PDFKit. A highlight's palette goes; a selected note or drawing
  /// is the tools' to keep or let go.
  private func takePointer(_ event: NSEvent) -> PointerGesture? {
    switch target {
    case .selection?: dismiss()
    case .mark(let id)? where canvas.mark(id) == nil: dismiss()
    default: break
    }
    return freehand.gesture(for: event)
  }

  /// The tools selected a note or a drawing, or let it go.
  private func selected(_ mark: PaperAnnotation?, settled: Bool) {
    guard let mark else {
      if case .mark(let id) = target, canvas.mark(id) != nil || store?.annotation(id)?.isFreehand == true {
        hidePalette()
      }
      return
    }
    target = .mark(mark.id)
    palette.editing = mark
    anchor = Self.place(of: mark, scale: pdfView?.scaleFactor ?? 1)
    if settled { layoutPalette() } else { host?.isHidden = true }
  }

  /// Where the palette points for a note or a drawing: its dashed box, so the card clears the handles.
  private static func place(of mark: PaperAnnotation, scale: CGFloat) -> (page: Int, rect: CGRect)? {
    guard let grips = Grips(mark, scale: scale), let page = mark.pages.first else { return nil }
    return (page, grips.box.insetBy(dx: 0, dy: -Grips.radius / max(scale, 0.01)))
  }

  /// Whether a link's preview may show for the pointer at `point`: with Select, nothing being written or
  /// dragged, no palette, and not over a note, a drawing or a handle.
  func allowsPreview(at point: NSPoint) -> Bool {
    tool == .select && !isShowingPalette && !freehand.isEditing && NSEvent.pressedMouseButtons == 0
      && !freehand.covers(point)
  }

  private func toolChanged() {
    freehand.endEditing()
    dismiss()
    guard let pdfView, let window = pdfView.window else { return }
    window.invalidateCursorRects(for: pdfView)
    let point = pdfView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    (freehand.cursor(at: point) ?? .arrow).set()
  }

  private func handleKey(_ event: NSEvent) -> Bool {
    let keys = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
    // a selected note or drawing
    if case .mark(let id) = target, let mark = canvas.mark(id) {
      switch event.keyCode {
      case 51, 117:  // delete, forward delete
        deleteEdited()
        return true
      case 53:  // escape
        dismiss()
        return true
      case 36 where keys.isEmpty && mark.note != nil, 76 where keys.isEmpty && mark.note != nil:  // return, enter: write in it
        freehand.edit(mark)
        return true
      case 123...126 where keys.subtracting(.shift).isEmpty:  // arrows
        let step: CGFloat = keys.contains(.shift) ? 10 : 1
        let move: (CGFloat, CGFloat)
        switch event.keyCode {
        case 123: move = (-step, 0)
        case 124: move = (step, 0)
        case 125: move = (0, -step)
        default: move = (0, step)
        }
        freehand.nudge(dx: move.0, dy: move.1)
        return true
      case 47 where keys == [.command, .shift], 43 where keys == [.command, .shift]:  // ⌘⇧> and ⌘⇧<, by key on every layout
        if let note = mark.note { resize(to: NoteText.step(note.size, up: event.keyCode == 47)) }
        return mark.note != nil
      default:
        return false
      }
    }
    guard let target else {
      // Esc puts a drawing tool away
      if event.keyCode == 53, tool != .select {
        freehand.markup?.tool = .select
        return true
      }
      return false
    }
    switch (event.keyCode, target) {
    case (53, _):  // escape
      dismiss()
      return true
    case (51, .mark), (117, .mark):  // delete, forward delete
      deleteEdited()
      return true
    default:
      return false
    }
  }

  @objc private func selectionChanged() {
    guard case .selection = target else { return }
    if (pdfView?.currentSelection?.string ?? "").isEmpty { dismiss() }
  }

  @objc private func viewMoved() {
    freehand.viewMoved()
    if target != nil { layoutPalette() }
  }

  // MARK: - Palette actions

  private func pick(_ color: AnnotationColor) {
    guard let store, let pdfView, let target else { return }
    switch target {
    case .selection(let spans, let text):
      store.add(PaperAnnotation(kind: palette.mode, color: color, spans: spans, text: text),
                undo: pdfView.undoManager)
      dismiss()
      pdfView.clearSelection()
    case .mark(let id):
      if let mark = store.annotation(id), mark.isFreehand {
        reshape { $0.color = color.rawValue }
      } else {
        store.restyle(id, color: color, undo: pdfView.undoManager)
      }
    }
  }

  /// A note's text size: the words rewrap to its width and the top stays put.
  private func resize(to size: CGFloat) {
    reshape { mark in
      guard let note = mark.note else { return }
      let size = NoteText.clamped(size)
      let height = NoteText.height(of: note.body, size: size, width: note.rect.width)
      mark.note?.size = size
      mark.note?.rect = Reshape.rounded(CGRect(x: note.rect.minX, y: note.rect.maxY - height,
                                               width: note.rect.width, height: height))
    }
  }

  /// A note's or a drawing's colour, size or width changed from the palette or the keys.
  private func reshape(_ change: (inout PaperAnnotation) -> Void) {
    freehand.flushNudge()
    guard let store, case .mark(let id) = target, var mark = store.annotation(id), mark.isFreehand else { return }
    change(&mark)
    store.replace(mark, undo: pdfView?.undoManager)
  }

  private func restyle(_ kind: AnnotationKind) {
    if case .mark(let id) = target {
      store?.restyle(id, kind: kind, undo: pdfView?.undoManager)
    } else {
      palette.mode = kind
    }
  }

  private func deleteEdited() {
    guard case .mark(let id) = target else { return }
    freehand.flushNudge()
    dismiss()
    store?.remove(id, undo: pdfView?.undoManager)
  }

  // MARK: - Placement

  private func show(at page: Int, _ rects: [CGRect]) {
    guard let first = rects.first else { return }
    anchor = (page, rects.dropFirst().reduce(first) { $0.union($1) })
    layoutPalette()
  }

  /// No palette and nothing selected.
  func dismiss() {
    hidePalette()
    freehand.deselect(quietly: true)
  }

  private func hidePalette() {
    target = nil
    anchor = nil
    palette.editing = nil
    host?.isHidden = true
  }

  /// Below the marked text, or above it when there is no room; hidden while scrolled out of view.
  private func layoutPalette() {
    guard let host, let pdfView, let container, let anchor,
          let page = pdfView.document?.page(at: anchor.page) else {
      host?.isHidden = true
      return
    }
    let text = container.convert(pdfView.convert(anchor.rect, from: page), from: pdfView)
    let visible = container.convert(pdfView.bounds, from: pdfView)
    guard visible.intersects(text) else {
      host.isHidden = true
      return
    }
    let size = host.fittingSize
    // the card sits inside the hosting view's transparent shadow padding
    let pad = AnnotationPalette.shadowPadding
    let offset = Self.gap - pad
    let y: CGFloat
    if container.isFlipped {
      let below = text.maxY + offset
      y = below + size.height - pad <= visible.maxY ? below : text.minY - offset - size.height
    } else {
      let below = text.minY - offset - size.height
      y = below + pad >= visible.minY ? below : text.maxY + offset
    }
    func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { min(max(value, low), max(low, high)) }
    let x = clamp(text.midX - size.width / 2, visible.minX - pad, visible.maxX - size.width + pad)
    host.frame = CGRect(x: x, y: clamp(y, visible.minY - pad, visible.maxY - size.height + pad),
                        width: size.width, height: size.height)
    host.isHidden = false
  }
}

/// The palette's hosting view. It is larger than the card by the card's shadow, and that margin takes no
/// clicks: it lies over the handles below a selected note or drawing, and over the line of text below a
/// highlight.
private final class PaletteHost: NSHostingView<AnnotationPalette> {
  override func hitTest(_ point: NSPoint) -> NSView? {
    let card = bounds.insetBy(dx: AnnotationPalette.shadowPadding, dy: AnnotationPalette.shadowPadding)
    return card.contains(convert(point, from: superview)) ? super.hitTest(point) : nil
  }
}
