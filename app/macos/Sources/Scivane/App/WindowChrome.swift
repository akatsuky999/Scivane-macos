import AppKit
import SwiftUI

/// Anchors the native window controls to the island's header. Reserving SwiftUI space alone
/// leaves AppKit's buttons against the window edge, outside the glass surface.
struct WindowChrome: NSViewRepresentable {
  var expanded: Bool

  func makeNSView(context: Context) -> Anchor { Anchor() }

  func updateNSView(_ view: Anchor, context: Context) {
    view.expanded = expanded
    view.positionButtons()
  }

  static func dismantleNSView(_ view: Anchor, coordinator: ()) {
    view.stopObserving()
  }

  final class Anchor: NSView {
    var expanded = true
    private var observers: [NSObjectProtocol] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopObserving()
      guard let window else { return }
      for name in [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification] {
        observers.append(NotificationCenter.default.addObserver(
          forName: name, object: window, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.positionButtons() }
        })
      }
      // The hosting view and title bar acquire their final frames after attachment.
      DispatchQueue.main.async { [weak self] in self?.positionButtons() }
    }

    override func layout() {
      super.layout()
      positionButtons()
    }

    func stopObserving() {
      observers.forEach { NotificationCenter.default.removeObserver($0) }
      observers.removeAll()
    }

    func positionButtons() {
      guard let window, !window.styleMask.contains(.fullScreen), bounds.height > 0 else { return }
      let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
        .compactMap { window.standardWindowButton($0) }
      guard buttons.count == 3 else { return }
      let width = buttons.reduce(CGFloat.zero) { $0 + $1.frame.width }
        + SidebarMetrics.trafficLightGap * 2
      var x = expanded ? SidebarMetrics.trafficLightInset : (SidebarMetrics.rail - width) / 2
      for button in buttons {
        guard let parent = button.superview else { continue }
        let header = convert(bounds, to: parent)
        var frame = button.frame
        frame.origin = NSPoint(x: header.minX + x, y: header.midY - frame.height / 2)
        if button.frame != frame { button.setFrameOrigin(frame.origin) }
        x += frame.width + SidebarMetrics.trafficLightGap
      }
    }
  }
}
