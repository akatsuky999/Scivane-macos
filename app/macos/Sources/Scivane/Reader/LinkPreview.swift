import PDFKit
import SwiftUI

/// What the preview card shows.
@MainActor
final class LinkPreviewModel: ObservableObject {
  enum Content: Equatable {
    case none
    case reference(String)
    case picture(NSImage, CGSize)
  }

  @Published var content: Content = .none
  var onHover: (Bool) -> Void = { _ in }
}

/// A light card under a link: the cited entry as text, or a picture of the place a figure, table or
/// section link goes to. No buttons: a click on the link itself follows it, as PDFKit always has.
struct LinkPreviewCard: View {
  @ObservedObject var model: LinkPreviewModel

  static let width: CGFloat = 400
  /// transparent margin around the card, so its shadow isn't clipped by the hosting view
  static let shadowPadding: CGFloat = 14
  private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

  var body: some View {
    content
      .background(.regularMaterial, in: shape)
      .overlay(shape.strokeBorder(Palette.rule))
      .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
      .onHover { model.onHover($0) }
      .padding(Self.shadowPadding)
      .fixedSize()
  }

  @ViewBuilder private var content: some View {
    switch model.content {
    case .reference(let text):
      Text(verbatim: text)
        .font(.system(size: 12.5, design: .serif)).lineSpacing(2.5)
        .foregroundStyle(Palette.ink)
        .textSelection(.enabled)
        .frame(width: Self.width - 28, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14).padding(.vertical, 11)
    case .picture(let image, let size):
      Image(nsImage: image).resizable().interpolation(.high)
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(6)
    case .none:
      EmptyView()
    }
  }
}

/// Shows the card after the pointer rests on a link, and takes it away once the pointer has left both
/// the link and the card. A hover costs a hit test of the page's links; the target is worked out once,
/// when the card is about to show, and remembered.
@MainActor
final class LinkPreviewController: NSObject {
  let model = LinkPreviewModel()
  /// Whether a card may show for the pointer at a point: not while it would be in the way.
  var allowed: (NSPoint) -> Bool = { _ in true }

  private let targets = LinkTargets()
  private weak var pdfView: AnnotatingPDFView?
  private weak var container: NSView?
  private var host: NSHostingView<LinkPreviewCard>?
  /// the link under the pointer, and the one the card is showing
  private weak var hovered: PDFAnnotation?
  private weak var shown: PDFAnnotation?
  private var anchor: (page: Int, rect: CGRect)?
  private var pending: Task<Void, Never>?
  private var overCard = false
  private weak var watchedClip: NSClipView?
  /// where the view was scrolled and zoomed when the pointer came to rest on the link
  private var resting: (origin: CGPoint, scale: CGFloat)?

  /// long enough that sweeping across the text doesn't flash cards
  static let delay: Duration = .milliseconds(320)
  /// from one link to the next while a card is out
  static let switchDelay: Duration = .milliseconds(90)
  /// time to move the pointer from the link onto the card
  static let linger: Duration = .milliseconds(180)
  static let gap: CGFloat = 4

  var isShowing: Bool { host.map { !$0.isHidden } ?? false }

  func attach(_ pdfView: AnnotatingPDFView, in container: NSView) {
    self.pdfView = pdfView
    self.container = container
    model.onHover = { [weak self] inside in self?.cardHovered(inside) }
    let host = NSHostingView(rootView: LinkPreviewCard(model: model))
    host.isHidden = true
    container.addSubview(host, positioned: .above, relativeTo: nil)
    self.host = host
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(viewMoved), name: .PDFViewScaleChanged, object: pdfView)
    center.addObserver(self, selector: #selector(viewMoved), name: NSView.frameDidChangeNotification, object: pdfView)
    watchScrolling()
  }

  func detach() {
    dismiss()
    NotificationCenter.default.removeObserver(self)
  }

  /// The view switched documents.
  func documentChanged() {
    dismiss()
    watchScrolling()
  }

  func dismiss() {
    pending?.cancel()
    pending = nil
    hovered = nil
    hide()
  }

  // MARK: - Hover

  func hover(at point: NSPoint?) {
    guard let point, let pdfView, let container, allowed(point) else { return leave() }
    if let host, !host.isHidden, host.frame.contains(container.convert(point, from: pdfView)) { return }
    guard let page = pdfView.page(for: point, nearest: false),
      let link = page.internalLink(at: pdfView.convert(point, to: page))
    else { return leave() }
    guard link.annotation !== hovered else { return }
    hovered = link.annotation
    resting = position
    let wait = shown != nil ? Self.switchDelay : Self.delay
    pending?.cancel()
    pending = Task { [weak self] in
      try? await Task.sleep(for: wait)
      guard !Task.isCancelled, let self, self.hovered === link.annotation else { return }
      self.show(link.annotation, link.destination, from: page)
    }
  }

  private func leave() {
    hovered = nil
    pending?.cancel()
    guard isShowing else { return }
    pending = Task { [weak self] in
      try? await Task.sleep(for: Self.linger)
      guard !Task.isCancelled, let self, self.hovered == nil, !self.overCard else { return }
      self.hide()
    }
  }

  private func cardHovered(_ inside: Bool) {
    overCard = inside
    if !inside, hovered == nil { leave() }
  }

  /// A scroll or a zoom takes the card away. PDFKit also reports small re-layouts that move nothing;
  /// those leave it.
  @objc private func viewMoved() {
    guard isShowing || pending != nil, let resting, let now = position else { return }
    if hypot(now.origin.x - resting.origin.x, now.origin.y - resting.origin.y) > 0.5
      || abs(now.scale - resting.scale) > 0.001
    {
      dismiss()
    }
  }

  private var position: (origin: CGPoint, scale: CGFloat)? {
    guard let pdfView, let clip = pdfView.documentView?.enclosingScrollView?.contentView else { return nil }
    return (clip.bounds.origin, pdfView.scaleFactor)
  }

  private func watchScrolling() {
    guard let clip = pdfView?.documentView?.enclosingScrollView?.contentView, clip !== watchedClip else { return }
    let center = NotificationCenter.default
    if let old = watchedClip { center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old) }
    clip.postsBoundsChangedNotifications = true
    center.addObserver(self, selector: #selector(viewMoved), name: NSView.boundsDidChangeNotification, object: clip)
    watchedClip = clip
  }

  // MARK: - The card

  private func show(_ link: PDFAnnotation, _ destination: PDFDestination, from page: PDFPage) {
    pending = nil
    guard let pdfView, let document = pdfView.document,
      let target = targets.target(for: destination, in: document)
    else { return }
    switch target {
    case .reference(let text):
      model.content = .reference(text)
    case .region(let index, let rect):
      guard let source = document.page(at: index) else { return }
      model.content = Self.picture(of: rect, on: source)
    }
    shown = link
    anchor = (document.index(for: page), link.bounds)
    layout()
  }

  private func hide() {
    guard let host, !host.isHidden else { return }
    host.isHidden = true
    shown = nil
    anchor = nil
    overCard = false
    // drops the picture
    model.content = .none
  }

  /// Below the link, or above it when there is no room, kept inside the source pane.
  private func layout() {
    guard let host, let pdfView, let container, let anchor,
      let page = pdfView.document?.page(at: anchor.page)
    else { return }
    let link = container.convert(pdfView.convert(anchor.rect, from: page), from: pdfView)
    let visible = container.convert(pdfView.bounds, from: pdfView)
    let size = host.fittingSize
    let pad = LinkPreviewCard.shadowPadding
    let offset = Self.gap - pad
    let y: CGFloat
    if container.isFlipped {
      let below = link.maxY + offset
      y = below + size.height - pad <= visible.maxY ? below : link.minY - offset - size.height
    } else {
      let below = link.minY - offset - size.height
      y = below + pad >= visible.minY ? below : link.maxY + offset
    }
    func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { min(max(value, low), max(low, high)) }
    let x = clamp(link.midX - size.width / 2, visible.minX + 8 - pad, visible.maxX - size.width - 8 + pad)
    host.frame = CGRect(x: x, y: clamp(y, visible.minY - pad, visible.maxY - size.height + pad),
                        width: size.width, height: size.height)
    host.isHidden = false
  }

  /// The place drawn at the card's width. Drawn when first shown and kept by the image.
  private static func picture(of rect: CGRect, on page: PDFPage) -> LinkPreviewModel.Content {
    let scale = (LinkPreviewCard.width - 12) / rect.width
    let size = CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
    let box = page.bounds(for: .cropBox)
    let image = NSImage(size: size, flipped: false) { _ in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      context.setFillColor(NSColor.white.cgColor)
      context.fill(CGRect(origin: .zero, size: size))
      context.scaleBy(x: scale, y: scale)
      // page.draw puts the box's lower left at the origin
      context.translateBy(x: box.minX - rect.minX, y: box.minY - rect.minY)
      page.draw(with: .cropBox, to: context)
      return true
    }
    return .picture(image, size)
  }
}
