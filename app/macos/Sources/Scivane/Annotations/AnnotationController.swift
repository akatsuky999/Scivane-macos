import Combine
import PDFKit
import SwiftUI

/// A PDFView that reports when a pointer gesture ends.
///
/// PDFKit tracks a drag inside its own mouseDown loop, so the selection is complete when
/// super.mouseDown returns; mouseUp may follow as well. Whichever comes first ends the gesture.
final class AnnotatingPDFView: PDFView {
  var onPress: () -> Void = {}
  /// where the gesture started, in view coordinates
  var onRelease: (NSPoint) -> Void = { _ in }
  /// true when the key was handled
  var onKey: (NSEvent) -> Bool = { _ in false }
  private var pressedAt: NSPoint?

  override func mouseDown(with event: NSEvent) {
    pressedAt = convert(event.locationInWindow, from: nil)
    onPress()
    super.mouseDown(with: event)
    if NSEvent.pressedMouseButtons & 1 == 0 { finishGesture() }
  }

  override func mouseUp(with event: NSEvent) {
    super.mouseUp(with: event)
    finishGesture()
  }

  private func finishGesture() {
    guard let point = pressedAt else { return }
    pressedAt = nil
    onRelease(point)
  }

  override func keyDown(with event: NSEvent) {
    if !onKey(event) { super.keyDown(with: event) }
  }
}

/// Puts marks into one PDF view: draws the open project's marks, and shows the palette after a text
/// selection (to create one) or a click on a mark (to edit it).
@MainActor
final class AnnotationController: NSObject {
  private enum Target: Equatable {
    case selection([PaperAnnotation.Span], text: String)
    case mark(String)
  }

  let palette: AnnotationPaletteModel
  let layer = AnnotationLayer()

  private weak var pdfView: AnnotatingPDFView?
  private weak var container: NSView?
  private var host: NSHostingView<AnnotationPalette>?
  private weak var store: AnnotationStore?
  private var marks: AnyCancellable?
  /// The project whose source this view shows; nil for a loose document, which has nowhere to keep marks.
  private var projectID: String?
  private var target: Target?
  /// what the palette points at, in page space
  private var anchor: (page: Int, rect: CGRect)?
  /// the scroll view's clip view being watched; PDFKit may only create it once a document is set
  private weak var watchedClip: NSClipView?

  /// gap between the text and the palette card
  static let gap: CGFloat = 6

  init(palette: AnnotationPaletteModel? = nil) {
    self.palette = palette ?? AnnotationPaletteModel()
    super.init()
    self.palette.onColor = { [weak self] in self?.pick($0) }
    self.palette.onKind = { [weak self] in self?.restyle($0) }
    self.palette.onDelete = { [weak self] in self?.deleteEdited() }
  }

  var isShowingPalette: Bool { target != nil }
  var paletteFrame: CGRect? { host.flatMap { $0.isHidden ? nil : $0.frame } }

  func attach(_ pdfView: AnnotatingPDFView, in container: NSView) {
    self.pdfView = pdfView
    self.container = container
    pdfView.onPress = { [weak self] in self?.dismiss() }
    pdfView.onRelease = { [weak self] in self?.released(at: $0) }
    pdfView.onKey = { [weak self] in self?.handleKey($0) ?? false }

    let host = NSHostingView(rootView: AnnotationPalette(model: palette))
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
    guard projectID != self.projectID else { return }
    self.projectID = projectID
    dismiss()
    render(store.annotations)
  }

  /// The view switched documents.
  func documentChanged() {
    dismiss()
    watchScrolling()
    render(store?.annotations ?? [])
  }

  /// Takes this layer's marks off the document, which outlives the view.
  func detach() {
    dismiss()
    layer.clear()
    marks = nil
    NotificationCenter.default.removeObserver(self)
  }

  private func render(_ annotations: [PaperAnnotation]) {
    let shown = projectID != nil && store?.projectID == projectID ? annotations : []
    layer.sync(shown, on: pdfView?.document)
    if case .mark(let id) = target {
      if let mark = shown.first(where: { $0.id == id }) { palette.editing = mark } else { dismiss() }
    }
  }

  // MARK: - Gestures

  /// A selection opens the palette to create; a plain click on a mark opens it to edit.
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
      let local = pdfView.convert(point, to: page)
      guard let mark = layer.mark(at: local, onPage: index),
            let span = mark.spans.first(where: { $0.page == index }) else { return }
      target = .mark(mark.id)
      palette.editing = mark
      show(at: index, span.rects)
    }
  }

  private func handleKey(_ event: NSEvent) -> Bool {
    guard let target else { return false }
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
      store.restyle(id, color: color, undo: pdfView.undoManager)
    }
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
    dismiss()
    store?.remove(id, undo: pdfView?.undoManager)
  }

  // MARK: - Placement

  private func show(at page: Int, _ rects: [CGRect]) {
    guard let first = rects.first else { return }
    anchor = (page, rects.dropFirst().reduce(first) { $0.union($1) })
    layoutPalette()
  }

  func dismiss() {
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
