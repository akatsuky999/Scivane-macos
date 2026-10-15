import AppKit
import SwiftUI

/// The Settings scene owns its window style; anchor its native controls to the navigation header.
struct SettingsWindowChrome: NSViewRepresentable {
  func makeNSView(context: Context) -> Anchor { Anchor() }
  func updateNSView(_ view: Anchor, context: Context) { view.positionButtons() }

  static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.stopObserving() }

  final class Anchor: NSView {
    private static let windowStyle: NSWindow.StyleMask = [.fullSizeContentView, .miniaturizable, .resizable]
    private var observers: [NSObjectProtocol] = []
    private weak var preparedWindow: NSWindow?
    private var placementScheduled = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopObserving()
      guard let window, window.styleMask.contains(.titled) else { return }
      let firstAttachment = preparedWindow !== window
      preparedWindow = window
      configure(window)
      for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification,
                   NSWindow.didExitFullScreenNotification, NSWindow.didUpdateNotification] {
        observers.append(NotificationCenter.default.addObserver(
          forName: name, object: window, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self, let window = self.window else { return }
            // Enqueuing every native update can keep the run loop awake after layout settles.
            if name != NSWindow.didUpdateNotification || self.needsRepair(window) {
              self.schedulePlacement()
            }
          }
        })
      }
      DispatchQueue.main.async { [weak self, weak window] in
        // Resolve the initial size after full-size content changes the hosting view's safe area.
        if firstAttachment { window?.setContentSize(SettingsMetrics.window) }
        self?.positionButtons()
      }
    }

    override func layout() {
      super.layout()
      positionButtons()
    }

    func stopObserving() {
      observers.forEach { NotificationCenter.default.removeObserver($0) }
      observers.removeAll()
    }

    private func configure(_ window: NSWindow) {
      guard !window.styleMask.contains(.fullScreen) else { return }
      if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
      if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
      if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
      if !window.styleMask.isSuperset(of: Self.windowStyle) { window.styleMask.formUnion(Self.windowStyle) }
    }

    private func needsRepair(_ window: NSWindow) -> Bool {
      guard !window.styleMask.contains(.fullScreen) else { return false }
      if !window.titlebarAppearsTransparent || window.titleVisibility != .hidden
        || window.titlebarSeparatorStyle != .none
        || !window.styleMask.isSuperset(of: Self.windowStyle) { return true }
      return buttonPlacements().contains { button, origin in button.frame.origin != origin }
    }

    private func schedulePlacement() {
      guard !placementScheduled else { return }
      placementScheduled = true
      // AppKit may rebuild its traffic-light group after activation and title-bar layout.
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.placementScheduled = false
        if let window = self.window { self.configure(window) }
        self.positionButtons()
      }
    }

    func positionButtons() {
      for (button, origin) in buttonPlacements() where button.frame.origin != origin {
        button.setFrameOrigin(origin)
      }
    }

    private func buttonPlacements() -> [(NSButton, NSPoint)] {
      guard let window, !window.styleMask.contains(.fullScreen), bounds.height > 0 else { return [] }
      let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
      return types.enumerated().compactMap { index, type in
        guard let button = window.standardWindowButton(type), let parent = button.superview else { return nil }
        let header = convert(bounds, to: parent)
        let origin = NSPoint(
          x: header.minX + SettingsMetrics.trafficLightLeading
            + CGFloat(index) * SettingsMetrics.trafficLightSpacing,
          y: header.midY - button.frame.height / 2)
        return (button, origin)
      }
    }
  }
}
