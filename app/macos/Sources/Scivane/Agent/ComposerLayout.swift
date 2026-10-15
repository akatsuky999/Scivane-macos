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

/// The same quiet, translucent capsule for the document and the model controls.
extension View {
  func composerCapsule() -> some View {
    background(Palette.card, in: Capsule())
      .overlay(Capsule().strokeBorder(Palette.cardEdge, lineWidth: 1).allowsHitTesting(false))
  }
}
