import AppKit
import SwiftUI

/// Places the reading area's two panes: side by side with a divider in dual mode, both at full size in
/// single mode, where the caller hides one of them.
///
/// The panes are placed in every mode, so switching between single and dual, or between source and
/// text, keeps the PDF, the text's WebView and the conversation as they are. Swapping an HSplitView
/// for a single pane (as before) tore all three down: the WebView reloaded and replayed the whole
/// paper, the PDF lost its page and zoom, the conversation rebuilt every row and lost its scroll.
///
/// Subviews, in order: the source pane, the divider, the text pane.
struct ReadingSplit: Layout {
  var dual: Bool
  /// The source pane's share, in dual mode, of the room the panes have: the width less the divider.
  var fraction: CGFloat
  /// Pixels per point: the divider lands on the pixel grid, so on a Retina display at a half point.
  var scale: CGFloat

  static let divider: CGFloat = 1
  static let minSource: CGFloat = 240
  static let minText: CGFloat = 460

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard subviews.count == 3 else { return }
    guard dual else {
      for index in [0, 2] {
        subviews[index].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
      }
      subviews[1].place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
      return
    }
    let source = Self.sourceWidth(fraction: fraction, in: bounds.width, scale: scale)
    subviews[0].place(
      at: bounds.origin, anchor: .topLeading,
      proposal: ProposedViewSize(width: source, height: bounds.height))
    subviews[1].place(
      at: CGPoint(x: bounds.minX + source, y: bounds.minY), anchor: .topLeading,
      proposal: ProposedViewSize(width: Self.divider, height: bounds.height))
    let text = source + Self.divider
    subviews[2].place(
      at: CGPoint(x: bounds.minX + text, y: bounds.minY), anchor: .topLeading,
      proposal: ProposedViewSize(width: max(0, bounds.width - text), height: bounds.height))
  }

  /// On the pixel grid. Both minimums hold when there is room; when there isn't, the source keeps its
  /// minimum.
  static func sourceWidth(fraction: CGFloat, in width: CGFloat, scale: CGFloat) -> CGFloat {
    let room = width - divider
    let widest = max(minSource, room - minText)
    return min(max((room * fraction * scale).rounded() / scale, minSource), widest)
  }

  /// The share a source width is of the room the panes have.
  static func fraction(source: CGFloat, in width: CGFloat) -> CGFloat {
    source / max(1, width - divider)
  }

  /// Dual mode opens evenly split, whichever pane is on the right, until the divider is moved.
  static let initialFraction: CGFloat = 0.5
}

extension Notification.Name {
  /// Around a drag of the divider between the panes. Like a window's live resize, it changes the
  /// panes' width on every frame, and views that are slow to re-lay out wait for the end.
  static let paneResizeWillStart = Notification.Name("local.scivane.paneResizeWillStart")
  static let paneResizeDidEnd = Notification.Name("local.scivane.paneResizeDidEnd")
}

/// The line between the panes, dragged to move it. Thin as a split view's divider, with a wider area to
/// grab that doesn't change the layout.
struct ReadingDivider: View {
  /// the source pane's share; written while dragging
  @Binding var fraction: CGFloat
  /// the reading area's width
  let width: CGFloat
  /// pixels per point, as the split has it
  let scale: CGFloat
  /// the source width when the drag began; drags are relative
  @State private var start: CGFloat?
  @State private var hovering = false
  @State private var cursorPushed = false

  var body: some View {
    Rectangle()
      .fill(Color(nsColor: .separatorColor))
      .overlay {
        Color.clear
          .frame(width: 9)
          .contentShape(Rectangle())
          .onHover { inside in
            hovering = inside
            setCursor(inside || start != nil)
          }
          .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
              .onChanged { drag in
                guard width > 0 else { return }
                let origin = start ?? ReadingSplit.sourceWidth(fraction: fraction, in: width, scale: scale)
                if start == nil {
                  start = origin
                  NotificationCenter.default.post(name: .paneResizeWillStart, object: nil)
                }
                let source = ReadingSplit.sourceWidth(
                  fraction: ReadingSplit.fraction(source: origin + drag.translation.width, in: width),
                  in: width, scale: scale)
                fraction = ReadingSplit.fraction(source: source, in: width)
              }
              .onEnded { _ in endDrag() }
          )
      }
      .onDisappear {
        endDrag()
        setCursor(false)
      }
      .accessibilityHidden(true)
  }

  private func endDrag() {
    guard start != nil else { return }
    start = nil
    setCursor(hovering)
    NotificationCenter.default.post(name: .paneResizeDidEnd, object: nil)
  }

  /// Pushed once and popped once: an unbalanced push leaves the arrows stuck after the pointer leaves.
  private func setCursor(_ on: Bool) {
    guard on != cursorPushed else { return }
    cursorPushed = on
    if on { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
  }
}
