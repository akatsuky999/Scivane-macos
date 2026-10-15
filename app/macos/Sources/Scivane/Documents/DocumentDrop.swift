import SwiftUI

/// Documents dropped onto a view are imported, with the dashed outline while they hover. The window
/// has it, and so does the conversation pane: its own hosting view would otherwise take the drop and
/// keep it from reaching the window's.
struct DocumentDrop: ViewModifier {
  let model: AppModel
  @State private var targeted = false

  func body(content: Content) -> some View {
    content
      .overlay { if targeted { DropHighlight() } }
      .dropDestination(for: URL.self) { urls, _ in
        model.importDropped(urls)
      } isTargeted: {
        targeted = $0
      }
  }
}

/// The dashed outline over the reading area while documents are dragged over it.
struct DropHighlight: View {
  var body: some View {
    RoundedRectangle(cornerRadius: 16)
      .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
      .background(Palette.accent.opacity(0.05))
      .padding(.horizontal, 10).padding(.vertical, 9)
      .allowsHitTesting(false)
  }
}
