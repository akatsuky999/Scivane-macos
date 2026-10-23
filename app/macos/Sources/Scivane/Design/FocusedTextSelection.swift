import AppKit
import SwiftUI

/// Sets the selection of the text that has focus in this view's window, once that text is in place.
///
/// A field taking focus selects all of its text, so the first key typed replaces everything; and
/// SwiftUI hands new text and focus to the field a pass later. This waits until the focused text view
/// holds `request.text`, then selects. It reads this view's own window rather than the key window,
/// which may not be this one yet.
struct FocusedTextSelection: NSViewRepresentable {
  struct Request: Equatable {
    /// the text the field should hold; until it does, a selection would land in the old text
    let text: String
    /// UTF-16 range in `text`
    let range: NSRange
    /// a new request for the same text and range must still apply
    let id = UUID()

    /// The caret after the last character.
    static func end(of text: String) -> Request {
      Request(text: text, range: NSRange(location: (text as NSString).length, length: 0))
    }

    /// `part` selected, or the caret at the end when the text doesn't contain it.
    static func selecting(_ part: String?, in text: String) -> Request {
      guard let part, let found = text.range(of: part) else { return end(of: text) }
      return Request(text: text, range: NSRange(found, in: text))
    }
  }

  let request: Request?

  final class Coordinator { var applied: UUID? }

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ view: NSView, context: Context) {
    guard let request, context.coordinator.applied != request.id else { return }
    context.coordinator.applied = request.id
    Self.select(request, in: view, passes: 6)
  }

  /// Focus and text normally arrive on the next pass; a few more cover a slow one.
  private static func select(_ request: Request, in view: NSView, passes: Int) {
    DispatchQueue.main.async {
      if let text = view.window?.firstResponder as? NSTextView, text.string == request.text {
        text.setSelectedRange(request.range)
        text.scrollRangeToVisible(request.range)
      } else if passes > 1 {
        select(request, in: view, passes: passes - 1)
      }
    }
  }
}
