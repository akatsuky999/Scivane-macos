import AppKit
import SwiftUI

// Selectable text in the transcript, one row at a time.
//
// `.textSelection(.enabled)` lays an AppKit text field over each Text it covers; the field draws the
// same pixels and only handles selection. A long conversation has well over a thousand of them, and
// every one is laid out on each layout pass of the window, restyled on each appearance change and
// built each time the conversation opens, though nearly all sit off screen. So text is selectable in
// the row under the pointer, and in the row last clicked until the next click: a selection made
// there survives the pointer moving on to a menu.
//
// Per row rather than per block: SwiftUI hit-tests every hover region after each layout pass, and a
// region per paragraph and table cell made each frame of an animation hit-test a thousand of them.

private struct TextSelectableKey: EnvironmentKey {
  static let defaultValue = true
}

extension EnvironmentValues {
  /// Whether text below may be selected; on unless a transcript row turns it off.
  var textSelectable: Bool {
    get { self[TextSelectableKey.self] }
    set { self[TextSelectableKey.self] = newValue }
  }
}

/// Selection for a Text, when the row it is in allows it. Inside a passage (PassageSelection) the
/// passage selects across its Texts instead, except for those that keep a field of their own.
private struct SelectableText: ViewModifier {
  let standalone: Bool
  @Environment(\.textSelectable) private var selectable
  @Environment(\.passageText) private var passage

  func body(content: Content) -> some View {
    selectable(content)
  }

  @ViewBuilder
  private func selectable(_ content: Content) -> some View {
    if selectable && (standalone || !passage) {
      content.textSelection(.enabled)
    } else {
      content
    }
  }
}

extension View {
  /// - Parameter standalone: selected on its own even inside a passage, for text the passage takes
  ///   whole (code, tables that scroll sideways)
  func selectableText(standalone: Bool = false) -> some View {
    modifier(SelectableText(standalone: standalone))
  }
}

/// A transcript row: its text turns selectable under the pointer and after a click, and the content
/// gets to know whether the pointer is over it.
struct SelectableRow<Content: View>: View {
  @ViewBuilder let content: (_ hovering: Bool) -> Content
  @State private var hovering = false
  @State private var kept = false
  @State private var id = UUID()

  var body: some View {
    content(hovering)
      .environment(\.textSelectable, hovering || kept)
      .onHover { inside in
        hovering = inside
        SelectionKeeper.shared.hover(id, inside: inside)
      }
      .onAppear { SelectionKeeper.shared.register(id) { kept = $0 } }
      .onDisappear { SelectionKeeper.shared.unregister(id) }
  }
}

/// Which row keeps its selection once the pointer leaves: the one under the pointer at the last click.
/// A click anywhere else hands it on, as it clears a selection anyway.
@MainActor
final class SelectionKeeper {
  static let shared = SelectionKeeper()

  private var hovered: UUID?
  private var kept: UUID?
  private var keep: [UUID: (Bool) -> Void] = [:]
  private var monitor: Any?

  func hover(_ id: UUID, inside: Bool) {
    if inside { hovered = id } else if hovered == id { hovered = nil }
  }

  func register(_ id: UUID, keep: @escaping (Bool) -> Void) {
    self.keep[id] = keep
    guard monitor == nil else { return }
    // Local monitors run on the main thread and see the event before the view it goes to. A right
    // click counts: the context menu's Copy must find the selection still there.
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
      MainActor.assumeIsolated { self?.pressed() }
      return event
    }
  }

  func unregister(_ id: UUID) {
    keep.removeValue(forKey: id)
    if hovered == id { hovered = nil }
    if kept == id { kept = nil }
  }

  private func pressed() {
    guard hovered != kept else { return }
    if let kept { keep[kept]?(false) }
    kept = hovered
    if let hovered { keep[hovered]?(true) }
  }
}
