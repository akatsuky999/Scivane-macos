import SwiftUI

/// Only the scroll container reads this inset; typing must not rebuild the message rows.
private struct ComposerInsetKey: EnvironmentKey {
  static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
  var composerInset: CGFloat {
    get { self[ComposerInsetKey.self] }
    set { self[ComposerInsetKey.self] = newValue }
  }
}

struct ComposerFootprint: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// Wrap controls without replacing their menus or losing an open popover's identity.
struct ComposerControlsLayout: Layout {
  private let gap: CGFloat = 6

  private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
    guard subviews.count == 3 else { return [] }
    let send = subviews[2].sizeThatFits(.unspecified)
    let paperIdeal = subviews[0].sizeThatFits(.unspecified).width
    let modelIdeal = subviews[1].sizeThatFits(.unspecified).width
    let wraps = width < min(180, paperIdeal) + min(190, modelIdeal) + send.width + gap * 2
    let modelWidth = max(0, min(modelIdeal, wraps ? width - send.width - gap : width * 0.46))
    let paperWidth = max(0, wraps ? width : width - modelWidth - send.width - gap * 2)
    let paper = subviews[0].sizeThatFits(ProposedViewSize(width: max(0, paperWidth), height: nil))
    let model = subviews[1].sizeThatFits(ProposedViewSize(width: max(0, modelWidth), height: nil))
    let rowHeight = max(model.height, send.height, wraps ? 0 : paper.height)
    let rowY = wraps ? paper.height + gap : 0
    return [
      CGRect(x: 0, y: wraps ? 0 : (rowHeight - paper.height) / 2, width: paperWidth, height: paper.height),
      CGRect(x: width - send.width - gap - modelWidth, y: rowY + (rowHeight - model.height) / 2,
        width: modelWidth, height: model.height),
      CGRect(x: width - send.width, y: rowY + (rowHeight - send.height) / 2,
        width: send.width, height: send.height),
    ]
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? subviews.reduce(CGFloat(0)) { $0 + $1.sizeThatFits(.unspecified).width } + gap * 2
    return CGSize(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for (view, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
      view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        anchor: .topLeading, proposal: ProposedViewSize(frame.size))
    }
  }
}

private struct ComposerControl: ViewModifier {
  @State private var hovering = false

  func body(content: Content) -> some View {
    content
      .background(Palette.ink.opacity(hovering ? 0.055 : 0),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .contentShape(Rectangle())
      .onHover { hovering = $0 }
  }
}

extension View {
  func composerControl() -> some View {
    modifier(ComposerControl())
  }
}
