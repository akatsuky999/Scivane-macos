import PDFKit

/// A PDFView that keeps what is at the top of the view in place when a new width rescales the page.
///
/// Fitting the width, PDFKit rescales on every width change and holds the bottom of the view where it
/// was (its coordinates start at the bottom), so the line being read near the top slides away: a
/// narrower pane pulls earlier text in above it, a wider one pushes it out of sight. The width changes
/// on every switch between single and dual mode, a drag of the divider, a window resize, the sidebar
/// pushing the content aside and the thumbnails opening. A change of height alone doesn't rescale, and
/// PDFKit keeping the bottom in place then keeps the page still on screen, so it is left alone.
class ReadingPDFView: PDFView {
  /// the top of the view before the width changed, gone back to once the new scale is applied
  private var anchor: PDFDestination?
  /// The top last gone back to, and where that landed on the pixel grid. Until the reader scrolls away
  /// from there, the next rescale keeps the same top, so going back and forth doesn't creep.
  private var kept: (top: PDFDestination, landed: PDFDestination)?

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
    put(anchor)
    kept = currentDestination.map { (anchor, $0) }
  }

  /// Scrolls so the anchored point is at the top again. Through the scroll view rather than go(to:),
  /// which clamps a point in the gap between two pages to the edge of one, so a top that fell between
  /// pages would jump.
  private func put(_ anchor: PDFDestination) {
    guard let page = anchor.page, let now = currentDestination, let nowPage = now.page,
      let scroll = documentView?.enclosingScrollView
    else { return go(to: anchor) }
    let clip = scroll.contentView
    // both in the clip view's coordinates; the current top is where PDFKit itself puts the top
    let target = clip.convert(convert(anchor.point, from: page), from: self)
    let top = clip.convert(convert(now.point, from: nowPage), from: self)
    var bounds = clip.bounds
    bounds.origin.y += target.y - top.y
    clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
    scroll.reflectScrolledClipView(clip)
  }

  private static func same(_ a: PDFDestination, _ b: PDFDestination) -> Bool {
    a.page == b.page && abs(a.point.x - b.point.x) < 0.01 && abs(a.point.y - b.point.y) < 0.01
  }
}
