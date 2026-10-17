import SwiftUI

/// What the reading area shows, in the toolbar island: one groove for the pane (Original / Text /
/// Agent), one for the layout. The layout's glyphs draw what each layout would show with the pane
/// chosen now, so "side by side" reads as "the original, and this next to it".
struct ViewSwitcher: View {
  /// source / text / chat, as AppModel.paneSelection
  @Binding var pane: String
  @Binding var dual: Bool
  @Namespace private var glide
  @State private var hovering: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// short response to track the pointer, 0.78 damping for a slight overshoot
  private static let glideCurve = Animation.spring(response: 0.3, dampingFraction: 0.78)
  private static var segmentHeight: CGFloat { SidebarMetrics.toolbarControl - ToolbarGroove.padding * 2 }

  private struct Item: Identifiable {
    let id: String
    let label: String
    let symbol: String
  }

  private var items: [Item] {
    let text = Item(id: "text", label: L("正文", "Text"), symbol: "text.alignleft")
    let chat = Item(id: "chat", label: "Agent", symbol: "sparkles")
    if dual { return [text, chat] }
    return [Item(id: "source", label: L("原稿", "Original"), symbol: "doc"), text, chat]
  }

  var body: some View {
    HStack(spacing: 6) {
      groove {
        ForEach(items) { item in paneSegment(item) }
      }
      groove {
        layoutSegment(split: false)
        layoutSegment(split: true)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(L("布局", "Layout"))
      .accessibilityIdentifier("toggle-dual-pane")
    }
  }

  private func groove<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    HStack(spacing: 0, content: content)
      .padding(ToolbarGroove.padding)
      .background(ToolbarGroove())
  }

  private func select(_ change: @escaping () -> Void) {
    if reduceMotion { change() } else { withAnimation(Self.glideCurve, change) }
  }

  private func paneSegment(_ item: Item) -> some View {
    let active = item.id == pane
    return Button {
      guard !active else { return }
      select { pane = item.id }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: item.symbol).font(.system(size: 10.5))
          .foregroundStyle(active ? Palette.accent : Palette.inkSoft)
        Text(item.label)
      }
      .font(.system(size: 12, weight: active ? .semibold : .medium))
      .foregroundStyle(active || hovering == item.id ? Palette.ink : Palette.inkSoft)
      .padding(.horizontal, 11)
      .frame(height: Self.segmentHeight)
      .background { if active { thumb("pane") } }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { inside in hovering = inside ? item.id : (hovering == item.id ? nil : hovering) }
    .accessibilityLabel(item.label)
    .accessibilityAddTraits(active ? .isSelected : [])
  }

  private func layoutSegment(split: Bool) -> some View {
    let active = split == dual
    let key = split ? "dual" : "single"
    let label = split ? L("双栏对照 · 原稿在左", "Side by Side · Original on the Left") : L("单栏", "Single Pane")
    return Button {
      guard !active else { return }
      select { dual = split }
    } label: {
      LayoutGlyph(split: split, content: glyphContent(split: split))
        .foregroundStyle(active ? Palette.accent : (hovering == key ? Palette.ink : Palette.inkSoft))
        .frame(width: 34, height: Self.segmentHeight)
        .background { if active { thumb("layout") } }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { inside in hovering = inside ? key : (hovering == key ? nil : hovering) }
    .help(label)
    .accessibilityLabel(label)
    .accessibilityAddTraits(active ? .isSelected : [])
  }

  /// A single pane shows the pane chosen now; side by side keeps the original on the left, so its right
  /// half shows the text unless the agent is chosen.
  private func glyphContent(split: Bool) -> LayoutGlyph.Content {
    switch pane {
    case "chat": return .agent
    case "source": return split ? .text : .page
    default: return .text
    }
  }

  /// one shape per groove, moved between segments rather than faded
  private func thumb(_ id: String) -> some View {
    ToolbarThumb().matchedGeometryEffect(id: id, in: glide)
  }
}

/// A window drawn small: one pane or two, with what each holds. There is no system symbol for "the
/// original on the left and the agent on the right".
struct LayoutGlyph: View {
  enum Content { case page, text, agent }

  let split: Bool
  let content: Content

  var body: some View {
    Canvas { context, size in
      let frame = CGRect(origin: .zero, size: size).insetBy(dx: 0.6, dy: 0.6)
      context.stroke(
        Path(roundedRect: frame, cornerRadius: 2.6, style: .continuous), with: .foreground, lineWidth: 1.2)
      if split {
        var divider = Path()
        divider.move(to: CGPoint(x: size.width / 2, y: 0.6))
        divider.addLine(to: CGPoint(x: size.width / 2, y: size.height - 0.6))
        context.stroke(divider, with: .foreground, lineWidth: 1.2)
        context.stroke(page(in: CGRect(x: 3.3, y: 3.6, width: 3.2, height: 6.8)), with: .foreground, lineWidth: 0.9)
        mark(content == .page ? .text : content, in: CGRect(x: 10.4, y: 0, width: size.width - 12, height: size.height), context: context)
      } else {
        mark(content, in: CGRect(origin: .zero, size: size), context: context)
      }
    }
    .frame(width: 18, height: 14)
    .accessibilityHidden(true)
  }

  private func mark(_ content: Content, in box: CGRect, context: GraphicsContext) {
    switch content {
    case .page:
      context.stroke(page(in: CGRect(x: box.midX - 2.4, y: 3.4, width: 4.8, height: 7.2)), with: .foreground, lineWidth: 0.95)
    case .text:
      let inset: CGFloat = box.minX > 0 ? 0.6 : 4.6
      let left = box.minX + inset
      let right = box.maxX - inset
      var lines = Path()
      for (index, y) in [4.8, 7.0, 9.2].enumerated() {
        lines.move(to: CGPoint(x: left, y: y))
        lines.addLine(to: CGPoint(x: index == 2 ? left + (right - left) * 0.62 : right, y: y))
      }
      context.stroke(lines, with: .foreground, style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
    case .agent:
      context.fill(sparkle(at: CGPoint(x: box.midX, y: box.midY), radius: box.minX > 0 ? 2.5 : 3.3), with: .foreground)
    }
  }

  /// a sheet with its top right corner folded
  private func page(in rect: CGRect) -> Path {
    let fold = min(rect.width, rect.height) * 0.3
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.closeSubpath()
    return path
  }

  /// a four-pointed star with concave sides, as the agent's sparkle
  private func sparkle(at center: CGPoint, radius: CGFloat) -> Path {
    let pinch = radius * 0.16
    var path = Path()
    path.move(to: CGPoint(x: center.x, y: center.y - radius))
    path.addQuadCurve(to: CGPoint(x: center.x + radius, y: center.y), control: CGPoint(x: center.x + pinch, y: center.y - pinch))
    path.addQuadCurve(to: CGPoint(x: center.x, y: center.y + radius), control: CGPoint(x: center.x + pinch, y: center.y + pinch))
    path.addQuadCurve(to: CGPoint(x: center.x - radius, y: center.y), control: CGPoint(x: center.x - pinch, y: center.y + pinch))
    path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - radius), control: CGPoint(x: center.x - pinch, y: center.y - pinch))
    path.closeSubpath()
    return path
  }
}
