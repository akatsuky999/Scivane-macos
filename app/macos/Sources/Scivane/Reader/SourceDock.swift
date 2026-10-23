import SwiftUI

/// Over the bottom of the source: the way back after a jump, the page, and the tools for notes and
/// drawing. One glass island in the toolbar's material, a size smaller; dim while nothing waits on it,
/// as Preview's page number is. While the pen or the text tool is out, its colours and sizes sit in a
/// second strip above.
struct SourceDock: View {
  /// not observed: the dock shows the position, the history and the tools, which are objects of their own
  let model: AppModel
  @ObservedObject var position: ReadingPosition
  @ObservedObject var navigation: SourceNavigation
  @ObservedObject var markup: MarkupTools
  let pageCount: Int
  /// a project's source, which has somewhere to keep notes and strokes
  let markable: Bool

  @State private var hovering = false
  @State private var draft = ""
  @FocusState private var editing: Bool
  @Namespace private var glide
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// as the toolbar's switches: short, with a slight overshoot
  private static let glideCurve = Animation.spring(response: 0.3, dampingFraction: 0.78)
  private static var control: CGFloat { SidebarMetrics.dockControl }

  private var tool: MarkupTool { markable ? markup.tool : .select }
  private var awake: Bool { hovering || editing || tool != .select || navigation.backPage != nil }

  var body: some View {
    VStack(spacing: 6) {
      if tool == .ink || tool == .note {
        options.transition(.opacity.combined(with: .offset(y: 6)))
      }
      dock
    }
    .animation(reduceMotion ? nil : Self.glideCurve, value: tool)
    .animation(reduceMotion ? nil : Self.glideCurve, value: navigation.trail)
  }

  private var dock: some View {
    HStack(spacing: 2) {
      if !navigation.trail.isEmpty {
        history.transition(.opacity.combined(with: .scale(scale: 0.85)))
        separator
      }
      if pageCount > 1 { pages }
      if markable {
        if pageCount > 1 { separator }
        tools
      }
    }
    .padding(SidebarMetrics.dockPadding)
    .frame(height: SidebarMetrics.dock)
    .toolbarSurface(radius: SidebarMetrics.dockRadius)
    .opacity(awake ? 1 : 0.68)
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.15), value: awake)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(L("原稿工具", "Original Tools"))
  }

  private var separator: some View {
    Rectangle().fill(Color(nsColor: .separatorColor))
      .frame(width: 1, height: 14).padding(.horizontal, 4)
      .accessibilityHidden(true)
  }

  // MARK: - History

  @ViewBuilder private var history: some View {
    HStack(spacing: 0) {
      if let page = navigation.backPage {
        Button { navigation.goBack() } label: {
          HStack(spacing: 4) {
            Image(systemName: "arrow.uturn.backward").font(.system(size: 10.5, weight: .semibold))
            Text(verbatim: "\(page)").font(.system(size: 12, weight: .semibold).monospacedDigit())
          }
          .foregroundStyle(Palette.accent)
          .padding(.horizontal, 8)
          .frame(height: Self.control)
        }
        .buttonStyle(DockButtonStyle())
        .help(L("返回第 \(page) 页（⌘[）", "Back to Page \(page) (⌘[)"))
        .accessibilityLabel(L("返回第 \(page) 页", "Back to Page \(page)"))
        .accessibilityIdentifier("source-back")
      }
      if let page = navigation.forwardPage {
        icon("arrow.uturn.forward", label: L("前进到第 \(page) 页", "Forward to Page \(page)"),
             help: L("前进到第 \(page) 页（⌘]）", "Forward to Page \(page) (⌘])")) { navigation.goForward() }
          .accessibilityIdentifier("source-forward")
      }
    }
  }

  // MARK: - Page

  private var pages: some View {
    HStack(spacing: 0) {
      icon("chevron.left", label: L("上一页", "Previous Page"), enabled: position.page > 1) {
        model.goToPage(position.page - 1)
      }
      TextField("", text: $draft)
        .textFieldStyle(.plain).multilineTextAlignment(.center).focused($editing)
        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
        .foregroundStyle(Palette.ink)
        .frame(width: CGFloat("\(pageCount)".count) * 8 + 8, height: Self.control - 6)
        .background(ToolbarHover(active: editing))
        .onSubmit {
          // a page typed in is a jump, so it can be stepped back from
          model.goToPage(Int(draft) ?? position.page, jump: true)
          draft = String(position.page)
          editing = false
        }
        .accessibilityLabel(L("跳转页码", "Go to Page"))
      Text(verbatim: "/ \(pageCount)")
        .font(.system(size: 12.5).monospacedDigit()).foregroundStyle(Palette.inkFaint)
        .padding(.leading, 1).padding(.trailing, 3)
      icon("chevron.right", label: L("下一页", "Next Page"), enabled: position.page < pageCount) {
        model.goToPage(position.page + 1)
      }
    }
    .onAppear { draft = String(position.page) }
    .onChange(of: position.page) { _, page in if !editing { draft = String(page) } }
  }

  // MARK: - Tools

  private var tools: some View {
    HStack(spacing: 2) {
      ForEach(MarkupTool.allCases) { item in
        let active = tool == item
        Button { pick(item) } label: {
          MarkupToolIcon(tool: item)
            .foregroundStyle(active ? Palette.accent : Palette.inkSoft)
            .frame(width: Self.control, height: Self.control)
            .background { if active { DockSelection().matchedGeometryEffect(id: "tool", in: glide) } }
        }
        .buttonStyle(DockButtonStyle(selected: active))
        .help(item.label)
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("tool-\(item.rawValue)")
      }
    }
  }

  private func pick(_ item: MarkupTool) {
    guard markup.tool != item else { return }
    if reduceMotion { markup.tool = item } else { withAnimation(Self.glideCurve) { markup.tool = item } }
  }

  /// The pen's or the text's colour, and its width or size.
  private var options: some View {
    HStack(spacing: 6) {
      HStack(spacing: 4) {
        ForEach(AnnotationColor.allCases) { color in
          MarkSwatch(color: color, selected: markup.color == color, size: 15) { markup.color = color }
        }
      }
      separator
      if tool == .ink {
        HStack(spacing: 2) {
          ForEach(InkWidth.allCases) { width in
            option(width.rawValue, label: width.label, selected: markup.inkWidth == width) {
              markup.inkWidth = width
            } content: {
              Capsule().fill(Color(nsColor: markup.color.color))
                .frame(width: 16, height: width.points * 1.2)
            }
          }
        }
      } else {
        NoteSizeControl(size: markup.noteSize, style: DockButtonStyle()) { markup.noteSize = $0 }
      }
    }
    // the swatches' rings need room from the edge; a square at the end sits as the dock's do
    .padding(.leading, 9)
    .padding(.trailing, SidebarMetrics.dockPadding)
    .frame(height: SidebarMetrics.dock)
    .toolbarSurface(radius: SidebarMetrics.dockRadius)
  }

  private func option<Content: View>(
    _ id: String, label: String, selected: Bool, action: @escaping () -> Void,
    @ViewBuilder content: () -> Content
  ) -> some View {
    Button {
      if reduceMotion { action() } else { withAnimation(Self.glideCurve, action) }
    } label: {
      content()
        .frame(width: Self.control, height: Self.control)
        .background { if selected { DockSelection().matchedGeometryEffect(id: "option", in: glide) } }
    }
    .buttonStyle(DockButtonStyle(selected: selected))
    .help(label)
    .accessibilityLabel(label)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  // MARK: - Pieces

  private func icon(_ symbol: String, label: String, help: String? = nil, enabled: Bool = true,
                    action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Palette.inkSoft)
        .frame(width: Self.control, height: Self.control)
    }
    .buttonStyle(DockButtonStyle())
    .disabled(!enabled)
    .help(help ?? label)
    .accessibilityLabel(label)
  }
}

/// A control in the dock: a faint ink wash under the pointer, dimmed while pressed. The selected one
/// carries its own tint and takes no wash.
private struct DockButtonStyle: ButtonStyle {
  var selected = false

  func makeBody(configuration: Configuration) -> some View {
    Control(configuration: configuration, selected: selected)
  }

  private struct Control: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
      configuration.label
        .background(DockSelection.shape.fill(Palette.ink.opacity(hovering && enabled && !selected ? 0.05 : 0)))
        .contentShape(Rectangle())
        .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
        .onHover { hovering = $0 }
    }
  }
}

/// The selected tool or width: a square of the accent's tint, with the island's inner corners.
private struct DockSelection: View {
  static let shape = RoundedRectangle(cornerRadius: ToolbarGroove.radius, style: .continuous)

  var body: some View {
    Self.shape.fill(Palette.accent.opacity(0.13))
  }
}

/// A tool's icon: Select and Text drawn (see DrawnGlyphs), Pen and Eraser from SF Symbols.
private struct MarkupToolIcon: View {
  let tool: MarkupTool

  var body: some View {
    switch tool {
    case .select: PointerGlyph().stroke(style: .glyph).frame(width: 16, height: 16)
    case .note: TextGlyph().stroke(style: .glyph).frame(width: 16, height: 16)
    case .ink: Image(systemName: "pencil").font(.system(size: 13))
    case .eraser: Image(systemName: "eraser").font(.system(size: 13))
    }
  }
}
