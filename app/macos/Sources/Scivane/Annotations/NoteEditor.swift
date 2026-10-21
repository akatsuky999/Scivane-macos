import AppKit

/// Writing a note in place, on its page's sheet and in the sheet's units: plain text at the note's size
/// and colour, laid out as the page lays it out. A note begun with a click widens with its words up to
/// `grows` and wraps there; one with a set width wraps to it. The top stays put and the box grows down
/// as lines are added, while composing with an input method too.
final class NoteEditor: NSTextView {
  /// Esc or ⌘↩ (true: what was written stays selected), or the focus gone elsewhere (false)
  var onFinish: (_ select: Bool) -> Void = { _ in }
  /// the box changed size
  var onResize: () -> Void = {}
  /// ⌘⇧> (true) or ⌘⇧< (false)
  var onStep: (_ up: Bool) -> Void = { _ in }

  /// how wide it may grow while it widens with its words; nil for a set width
  let grows: CGFloat?
  private var size: CGFloat
  /// Typing is undone here while the editor is open, not on the window's stack: there it would sit on
  /// top of the note's own steps after the editor is gone, and ⌘Z would undo invisible keystrokes.
  private let typing = UndoManager()
  /// the top edge in the superview's coordinates
  private var top: CGFloat = 0
  private var closed = false

  init(frame: NSRect, size: CGFloat, color: NSColor, grows: CGFloat?) {
    self.size = size
    self.grows = grows
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)
    let container = NSTextContainer(size: NSSize(width: grows ?? frame.width, height: .greatestFiniteMagnitude))
    container.widthTracksTextView = grows == nil
    // the page draws the words without padding; the editor lines up with it
    container.lineFragmentPadding = 0
    layout.addTextContainer(container)
    super.init(frame: frame, textContainer: container)
    isRichText = false
    importsGraphics = false
    allowsUndo = true
    isAutomaticQuoteSubstitutionEnabled = false
    isAutomaticDashSubstitutionEnabled = false
    isAutomaticTextReplacementEnabled = false
    drawsBackground = false
    textContainerInset = .zero
    isVerticallyResizable = false
    isHorizontallyResizable = false
    restyle(size: size, color: color)
    setAccessibilityLabel(L("文字批注", "Note"))
    delegate = self
  }

  required init?(coder: NSCoder) { nil }

  override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
    size = NoteText.standard
    grows = nil
    super.init(frame: frameRect, textContainer: container)
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    guard let superview else { return }
    top = superview.isFlipped ? frame.minY : frame.maxY
  }

  /// A new size or colour for all of it and for what is typed next.
  func restyle(size: CGFloat, color: NSColor) {
    self.size = size
    let attributes = NoteText.attributes(size: size, color: color)
    typingAttributes = attributes
    if let textStorage, textStorage.length > 0, !hasMarkedText() {
      textStorage.setAttributes(attributes, range: NSRange(location: 0, length: textStorage.length))
    }
    insertionPointColor = color
    fit()
  }

  /// The box to the words: as wide as the longest line while it widens, as tall as the lines, at least
  /// a line, top edge in place.
  func fit() {
    guard let layoutManager, let textContainer, let superview else { return }
    layoutManager.ensureLayout(for: textContainer)
    let used = layoutManager.usedRect(for: textContainer)
    var rect = frame
    if let grows {
      rect.size.width = min(max(ceil(used.width) + 2, size * NoteText.minimumWidth), grows)
    }
    rect.size.height = ceil(max(used.height, size * 1.2)) + 1
    rect.origin.y = superview.isFlipped ? top : top - rect.height
    guard rect != frame else { return }
    frame = rect
    onResize()
  }

  /// The caret where the click was, a point in this view.
  func placeCaret(at point: NSPoint) {
    setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
  }

  override func didChangeText() {
    super.didChangeText()
    fit()
  }

  override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    fit()
  }

  override func unmarkText() {
    super.unmarkText()
    fit()
  }

  override func cancelOperation(_ sender: Any?) { onFinish(true) }
  /// Esc in a text view asks for completion; here it ends the note
  override func complete(_ sender: Any?) { onFinish(true) }

  override func keyDown(with event: NSEvent) {
    let keys = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    // ⌘↩ ends the note; a plain return is a new line
    if keys.contains(.command), event.keyCode == 36 || event.keyCode == 76 { return onFinish(true) }
    super.keyDown(with: event)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let keys = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
    // ⌘⇧. and ⌘⇧, by key, so they are the same keys on every layout
    if window?.firstResponder === self, keys == [.command, .shift], event.keyCode == 47 || event.keyCode == 43 {
      onStep(event.keyCode == 47)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    // after the click that took the focus has been handled
    if resigned, !closed { DispatchQueue.main.async { [weak self] in self?.onFinish(false) } }
    return resigned
  }

  /// Leaves the page. Only once; what it holds has been read by then.
  func close() {
    guard !closed else { return }
    closed = true
    removeFromSuperview()
  }
}

extension NoteEditor: NSTextViewDelegate {
  func undoManager(for view: NSTextView) -> UndoManager? { typing }
}
