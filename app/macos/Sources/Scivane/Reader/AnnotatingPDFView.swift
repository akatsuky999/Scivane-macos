import PDFKit

/// A press a drawing tool took over: it gets the drags and the release, and PDFKit neither selects nor
/// follows links meanwhile. Points are in view coordinates.
struct PointerGesture {
  var drag: (NSPoint) -> Void
  var end: (NSPoint) -> Void
}

/// The source's PDF view: reports when a pointer gesture ends, where the pointer rests, and lets a
/// drawing tool take the pointer.
///
/// PDFKit tracks a drag inside its own mouseDown loop, so the selection is complete when
/// super.mouseDown returns; mouseUp may follow as well. Whichever comes first ends the gesture.
final class AnnotatingPDFView: ReadingPDFView {
  var onPress: () -> Void = {}
  /// where the gesture started, in view coordinates
  var onRelease: (NSPoint) -> Void = { _ in }
  /// true when the key was handled
  var onKey: (NSEvent) -> Bool = { _ in false }
  /// The pointer at rest over the view with no button down, in view coordinates; nil once it has left.
  var onHover: (NSPoint?) -> Void = { _ in }
  /// A tool's gesture for this press, or nil to leave it to PDFKit.
  var takesPointer: (NSEvent) -> PointerGesture? = { _ in nil }
  /// The cursor for the pointer at a point in view coordinates, over PDFKit's own; nil leaves PDFKit's.
  var toolCursor: (NSPoint) -> NSCursor? = { _ in nil }

  private var pressedAt: NSPoint?
  private var gesture: PointerGesture?
  /// where the open gesture last had the pointer
  private var gestureAt: NSPoint = .zero
  private var tracking: NSTrackingArea?

  override func mouseDown(with event: NSEvent) {
    // a press is not a rest
    onHover(nil)
    // A press while a tool's gesture is still open, its release never delivered: that gesture ends where
    // it was, so what it showed is stored rather than left on screen alone.
    if let open = gesture {
      gesture = nil
      open.end(gestureAt)
    }
    // PDFKit takes the keys in its own mouseDown, which a tool's press skips: without them ⌘Z and Delete
    // would go wherever the focus was before
    if window?.firstResponder !== self { window?.makeFirstResponder(self) }
    if let gesture = takesPointer(event) {
      self.gesture = gesture
      gestureAt = convert(event.locationInWindow, from: nil)
      return
    }
    let point = convert(event.locationInWindow, from: nil)
    pressedAt = point
    onPress()
    if followsLink(at: point) {
      // a link followed inside PDFKit's tracking loop is one jump, reported with where it left from
      jump { super.mouseDown(with: event) }
    } else {
      super.mouseDown(with: event)
    }
    if NSEvent.pressedMouseButtons & 1 == 0 { finishGesture() }
  }

  override func mouseDragged(with event: NSEvent) {
    guard let gesture else { return super.mouseDragged(with: event) }
    gestureAt = convert(event.locationInWindow, from: nil)
    gesture.drag(gestureAt)
  }

  override func mouseUp(with event: NSEvent) {
    if let gesture {
      self.gesture = nil
      return gesture.end(convert(event.locationInWindow, from: nil))
    }
    super.mouseUp(with: event)
    finishGesture()
  }

  private func finishGesture() {
    guard let point = pressedAt else { return }
    pressedAt = nil
    onRelease(point)
  }

  private func followsLink(at point: NSPoint) -> Bool {
    guard let page = page(for: point, nearest: false) else { return false }
    return page.internalLink(at: convert(point, to: page)) != nil
  }

  override func keyDown(with event: NSEvent) {
    if !onKey(event) { super.keyDown(with: event) }
  }

  /// Keys with ⌘ come here before keyDown, and only reach it if nothing else takes them.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.modifierFlags.contains(.command), window?.firstResponder === self, onKey(event) { return true }
    return super.performKeyEquivalent(with: event)
  }

  // MARK: - Hover

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    // PDFKit's own areas don't promise mouseMoved to a subclass; this one only reports, it doesn't move
    // the cursor
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    let point = convert(event.locationInWindow, from: nil)
    toolCursor(point)?.set()
    onHover(point)
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    onHover(nil)
  }

  override func cursorUpdate(with event: NSEvent) {
    if let cursor = toolCursor(convert(event.locationInWindow, from: nil)) { cursor.set() } else { super.cursorUpdate(with: event) }
  }
}
