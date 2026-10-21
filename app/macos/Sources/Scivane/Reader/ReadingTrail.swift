import PDFKit

/// Where reading jumped from in one document, as a browser keeps it: a jump pushes the spot left
/// behind, stepping back pushes the spot stepped away from onto the way forward, and a new jump forgets
/// the way forward.
struct ReadingTrail: Equatable {
  /// The top left of the view on a page, in page space: what the view showed, not just which page.
  struct Spot: Equatable {
    /// 0-based
    var page: Int
    var point: CGPoint
  }

  private(set) var back: [Spot] = []
  private(set) var forward: [Spot] = []

  /// a long session of following references keeps its recent history, not all of it
  static let limit = 64

  var isEmpty: Bool { back.isEmpty && forward.isEmpty }

  mutating func jumped(from origin: Spot) {
    back.append(origin)
    if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
    forward.removeAll()
  }

  /// Where to go back to, remembering `current` as the way forward.
  mutating func stepBack(from current: Spot) -> Spot? {
    guard let target = back.popLast() else { return nil }
    forward.append(current)
    return target
  }

  mutating func stepForward(from current: Spot) -> Spot? {
    guard let target = forward.popLast() else { return nil }
    back.append(current)
    return target
  }
}

/// The source view's back and forward. The view reports every jump with the spot it left (a link
/// followed, a page asked for, a thumbnail clicked); scrolling and zooming are not jumps. One that lands
/// within the same screen isn't worth a step back, so it is dropped.
@MainActor
final class SourceNavigation: ObservableObject {
  @Published private(set) var trail = ReadingTrail()
  private weak var view: ReadingPDFView?
  private var monitor: Any?

  /// 1-based pages, for the dock's label and tooltips
  var backPage: Int? { trail.back.last.map { $0.page + 1 } }
  var forwardPage: Int? { trail.forward.last.map { $0.page + 1 } }

  func attach(_ view: ReadingPDFView) {
    self.view = view
    view.onJump = { [weak self] origin in self?.jumped(from: origin) }
    // The mouse's side buttons, as a browser reads them. Taken at the app's level: PDFKit's inner
    // views keep other-button presses from reaching the PDF view.
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
      // local monitors run on the main thread
      let handled = MainActor.assumeIsolated { self?.sideButton(event) ?? false }
      return handled ? nil : event
    }
  }

  private func sideButton(_ event: NSEvent) -> Bool {
    guard event.buttonNumber == 3 || event.buttonNumber == 4, let view, let window = view.window,
      !view.isHiddenOrHasHiddenAncestor
    else { return false }
    // an event without a window carries screen coordinates
    let inWindow: NSPoint
    if let source = event.window {
      guard source === window else { return false }
      inWindow = event.locationInWindow
    } else {
      inWindow = window.convertPoint(fromScreen: event.locationInWindow)
    }
    guard view.bounds.contains(view.convert(inWindow, from: nil)) else { return false }
    if event.buttonNumber == 3 { goBack() } else { goForward() }
    return true
  }

  /// A new document starts without history: the spots are in the old one's pages.
  func reset() {
    if !trail.isEmpty { trail = ReadingTrail() }
  }

  func goBack() { step { $0.stepBack(from: $1) } }
  func goForward() { step { $0.stepForward(from: $1) } }

  private func step(_ move: (inout ReadingTrail, ReadingTrail.Spot) -> ReadingTrail.Spot?) {
    guard let view, !view.isHiddenOrHasHiddenAncestor, let document = view.document,
      let current = view.currentDestination.flatMap({ Self.spot($0, in: document) })
    else { return }
    var trail = self.trail
    guard let target = move(&trail, current), let page = document.page(at: target.page) else { return }
    self.trail = trail
    view.quietly { view.scrollTop(to: PDFDestination(page: page, at: target.point), horizontally: true) }
  }

  private func jumped(from origin: PDFDestination) {
    guard let view, let document = view.document,
      let from = Self.spot(origin, in: document), let page = origin.page,
      let now = view.currentDestination, let nowPage = now.page
    else { return }
    // both in the view's coordinates as it is scrolled now: the spot left behind is far off screen
    // after a real jump, and within half a screen when the target was already in sight
    let a = view.convert(origin.point, from: page)
    let b = view.convert(now.point, from: nowPage)
    guard hypot(a.x - b.x, a.y - b.y) > view.bounds.height / 2 else { return }
    trail.jumped(from: from)
  }

  private static func spot(_ destination: PDFDestination, in document: PDFDocument) -> ReadingTrail.Spot? {
    guard let page = destination.page else { return nil }
    let index = document.index(for: page)
    guard index != NSNotFound else { return nil }
    return ReadingTrail.Spot(page: index, point: destination.point)
  }
}
