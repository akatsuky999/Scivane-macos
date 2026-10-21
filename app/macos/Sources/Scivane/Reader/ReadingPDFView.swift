import PDFKit

/// A PDFView that keeps what is at the top of the view in place when a new width rescales the page,
/// and reports jumps so they can be stepped back from.
///
/// Fitting the width, PDFKit rescales on every width change and holds the bottom of the view where it
/// was (its coordinates start at the bottom), so the line being read near the top slides away: a
/// narrower pane pulls earlier text in above it, a wider one pushes it out of sight. The width changes
/// on every switch between single and dual mode, a drag of the divider, a window resize, the sidebar
/// pushing the content aside and the thumbnails opening. A change of height alone doesn't rescale, and
/// PDFKit keeping the bottom in place then keeps the page still on screen, so it is left alone.
class ReadingPDFView: PDFView {
  /// Told the view's top left before a jump: a page or destination gone to, by the app, a link or a
  /// thumbnail. Moves made `quietly` (scroll sync, keeping the top, stepping through the history) aren't.
  var onJump: ((PDFDestination) -> Void)?

  /// the top of the view before the width changed, gone back to once the new scale is applied
  private var anchor: PDFDestination?
  /// The top last gone back to, and where that landed on the pixel grid. Until the reader scrolls away
  /// from there, the next rescale keeps the same top, so going back and forth doesn't creep.
  private var kept: (top: PDFDestination, landed: PDFDestination)?
  /// Above zero inside a jump being reported or a quiet move: PDFKit's go(to:) calls one another, and
  /// only the outermost is the jump.
  private var moving = 0

  override func setFrameSize(_ newSize: NSSize) {
    // zero wide, the view hasn't been laid out and has no position to keep yet
    if anchor == nil, autoScales, frame.width > 0, newSize.width != frame.width,
      let top = currentDestination
    {
      anchor = kept.flatMap { Self.same($0.landed, top) ? $0.top : nil } ?? top
    }
    super.setFrameSize(newSize)
  }

  override func layout() {
    super.layout()
    guard let anchor else { return }
    self.anchor = nil
    quietly { scrollTop(to: anchor, horizontally: false) }
    kept = currentDestination.map { (anchor, $0) }
  }

  // MARK: - Jumps

  override func go(to page: PDFPage) { jump { super.go(to: page) } }
  override func go(to destination: PDFDestination) { jump { super.go(to: destination) } }
  override func go(to selection: PDFSelection) { jump { super.go(to: selection) } }
  override func go(to rect: CGRect, on page: PDFPage) { jump { super.go(to: rect, on: page) } }

  /// Moves that are not jumps: whatever `body` scrolls to, nothing is reported.
  func quietly(_ body: () -> Void) {
    moving += 1
    defer { moving -= 1 }
    body()
  }

  /// Runs `body` as one jump, reported with where the view was before it.
  func jump(_ body: () -> Void) {
    guard moving == 0, let origin = currentDestination else { return quietly(body) }
    quietly(body)
    onJump?(origin)
  }

  // MARK: - Placing the top

  /// Scrolls so the destination's point is at the top of the view (and at its left, `horizontally`).
  /// Through the scroll view rather than go(to:), which clamps a point in the gap between two pages to
  /// the edge of one, so a top that fell between pages would jump.
  func scrollTop(to destination: PDFDestination, horizontally: Bool) {
    guard let page = destination.page, let now = currentDestination, let nowPage = now.page,
      let scroll = documentView?.enclosingScrollView
    else { return quietly { super.go(to: destination) } }
    let clip = scroll.contentView
    // both in the clip view's coordinates; the current top is where PDFKit itself puts the top
    let target = clip.convert(convert(destination.point, from: page), from: self)
    let top = clip.convert(convert(now.point, from: nowPage), from: self)
    var bounds = clip.bounds
    bounds.origin.y += target.y - top.y
    if horizontally { bounds.origin.x += target.x - top.x }
    clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
    scroll.reflectScrolledClipView(clip)
  }

  private static func same(_ a: PDFDestination, _ b: PDFDestination) -> Bool {
    a.page == b.page && abs(a.point.x - b.point.x) < 0.01 && abs(a.point.y - b.point.y) < 0.01
  }
}

extension PDFPage {
  /// The link at a point in page space that goes somewhere in this document, topmost first. Our own
  /// marks are annotations too and may lie over a link, so this looks past them instead of asking
  /// annotation(at:), which answers with whatever is on top.
  func internalLink(at point: CGPoint) -> (annotation: PDFAnnotation, destination: PDFDestination)? {
    for annotation in annotations.reversed()
    where annotation.type == "Link" && annotation.bounds.contains(point) {
      if let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination,
        destination.page != nil
      {
        return (annotation, destination)
      }
    }
    return nil
  }
}
