import AppKit
import SwiftUI

/// Keeps a view's SwiftUI state alive while it isn't on screen, without letting it work there.
///
/// SwiftUI's two ways of hiding a view both cost something for a long conversation. With opacity the
/// view stays in the window: every appearance change, width change and model update lays it out and
/// redraws it again, in time that grows with the history. Taken out of the tree it loses its state:
/// the next showing rebuilds every row, and the scroll position, a draft and running tasks are gone.
///
/// So the content lives in a hosting view of its own that leaves the window while hidden. Outside the
/// window nothing lays it out or draws it; back in, it is as it was and catches up once. The content is
/// built on first presentation and then keeps itself current by observing its own objects; its root is
/// never replaced. Nothing it sets in the environment flows out, and only what the caller passes in
/// flows in.
///
/// Its appearance is pinned while it is out. A view outside any window follows the app's appearance, so
/// switching between light and dark would redraw it there, and its layers then wait on the render
/// server for a frame that is never shown, blocking the main thread for a few tenths of a second.
///
/// `identity` names what the content shows. Another identity gets another host: the old one is
/// released at once and the new one built when next presented, so a hidden pane never rebuilds itself
/// for content nobody is looking at.
struct RetainedPane<Content: View>: NSViewRepresentable {
  var isPresented: Bool
  var identity: AnyHashable
  private let content: () -> Content

  init(isPresented: Bool, identity: AnyHashable, @ViewBuilder content: @escaping () -> Content) {
    self.isPresented = isPresented
    self.identity = identity
    self.content = content
  }

  final class Coordinator {
    var host: NSHostingView<Content>?
    var identity: AnyHashable?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let container = NSView()
    place(in: container, context.coordinator)
    return container
  }

  func updateNSView(_ container: NSView, context: Context) {
    place(in: container, context.coordinator)
  }

  static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
    coordinator.host?.removeFromSuperview()
    coordinator.host = nil
  }

  private func place(in container: NSView, _ coordinator: Coordinator) {
    if let host = coordinator.host, coordinator.identity != identity {
      host.removeFromSuperview()
      coordinator.host = nil
    }
    guard isPresented else {
      if let host = coordinator.host, host.superview != nil {
        host.appearance = host.effectiveAppearance
        host.removeFromSuperview()
      }
      return
    }
    let host = coordinator.host ?? makeHost(coordinator)
    guard host.superview !== container else { return }
    host.frame = container.bounds
    // follows the window again; a change made while it was out is caught up in this one update
    host.appearance = nil
    container.addSubview(host)
  }

  private func makeHost(_ coordinator: Coordinator) -> NSHostingView<Content> {
    let host = NSHostingView(rootView: content())
    // The pane's size comes from the layout around it; nothing inside may push it.
    host.sizingOptions = []
    host.translatesAutoresizingMaskIntoConstraints = true
    host.autoresizingMask = [.width, .height]
    coordinator.host = host
    coordinator.identity = identity
    return host
  }
}
