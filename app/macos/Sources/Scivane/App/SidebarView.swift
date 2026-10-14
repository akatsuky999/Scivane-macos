import SwiftUI

/// Sidebar metrics, tuned together and kept in one place: the island's margins, the rail and the
/// panel, the paper tiles and rows.
enum SidebarMetrics {
  /// island to the window edges
  static let inset: CGFloat = 8
  static let radius: CGFloat = 20
  /// the band at the top of the island where the window's traffic lights sit
  static let topBar: CGFloat = 38
  static let rail: CGFloat = 62
  static let panel: CGFloat = 236
  /// the whole column, island and margins, with the panel open
  static var width: CGFloat { inset + rail + panel + inset }
  /// with only the rail
  static var collapsedWidth: CGFloat { inset + rail + inset }
  /// the fold button at the top bar's right; the toolbar owns unfolding
  static let foldButton = CGSize(width: 28, height: 26)
  static let unfoldButton = CGSize(width: 24, height: 26)
  /// top bar's side padding, where the fold button sits
  static let topBarPadding: CGFloat = 8
  static let trafficLightInset: CGFloat = 14
  static let trafficLightGap: CGFloat = 6
  static let logo: CGFloat = 36
  static let logoMark = CGSize(width: 18, height: 22)
  static let toolbarHeight: CGFloat = 46
  static let toolbarInset: CGFloat = 16
  static let tile = CGSize(width: 36, height: 44)
  static let tileGap: CGFloat = 8
  static let row: CGFloat = 28
  static let corner: CGFloat = 9
  static let card: CGFloat = 14
}

/// The sidebar: a glass island floating over the window. The rail lists every paper (the library
/// level); the panel shows the one that is open (the reader level): its chats, notes and outline.
/// ⌘B folds the panel away and leaves the rail.
struct SidebarView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var backend: BackendManager
  @ObservedObject private var state: SidebarState
  @AppStorage("sidebarVisible") private var expanded = true
  /// the tile under the pointer, and the one whose title is shown after a short wait
  @State private var hovering: Project.ID?
  @State private var tipFor: Project.ID?
  @State private var newProjectTitle = ""
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(model: AppModel, backend: BackendManager) {
    self.model = model
    self.backend = backend
    _state = ObservedObject(wrappedValue: model.sidebar)
  }

  var body: some View {
    island
      .padding(SidebarMetrics.inset)
      .frame(width: expanded ? SidebarMetrics.width : SidebarMetrics.collapsedWidth)
      .frame(maxHeight: .infinity)
      .overlayPreferenceValue(TileAnchors.self) { anchors in tooltip(anchors) }
      .task(id: hovering) {
        guard let hovering else { tipFor = nil; return }
        try? await Task.sleep(for: .milliseconds(350))
        // try? swallows cancellation too: a pointer that moved on mustn't bring the tip back
        guard !Task.isCancelled else { return }
        tipFor = hovering
      }
      .alert(L("新建项目", "New Project"), isPresented: $state.creatingProject) {
        TextField(L("项目名称（可留空）", "Project name (optional)"), text: $newProjectTitle)
        Button(L("创建", "Create")) {
          let title = newProjectTitle
          Task { await model.createEmptyProject(title: title) }
        }
        Button(L("取消", "Cancel"), role: .cancel) {}
      }
      .onChange(of: state.creatingProject) { _, active in if active { newProjectTitle = "" } }
  }

  private var island: some View {
    let shape = RoundedRectangle(cornerRadius: SidebarMetrics.radius, style: .continuous)
    return VStack(spacing: 0) {
      topBar
      HStack(spacing: 0) {
        SidebarRail(model: model, backend: backend, expanded: expanded, toggle: toggle, hovering: $hovering)
        if expanded {
          Rectangle().fill(Palette.ruleSoft).frame(width: 1)
          SidebarPanel(model: model, backend: backend, outline: model.outline, state: state)
            .frame(width: SidebarMetrics.panel - 1)
            .transition(.opacity)
        }
      }
    }
    .clipShape(shape)
    .glassSurface(radius: SidebarMetrics.radius)
  }

  /// The traffic lights sit at its left; the panel's fold button at its right.
  private var topBar: some View {
    HStack {
      Spacer(minLength: 0)
      if expanded {
        Button(action: toggle) {
          Image(systemName: "sidebar.left").font(.system(size: 13))
            .foregroundStyle(Palette.inkSoft)
            .frame(width: SidebarMetrics.foldButton.width, height: SidebarMetrics.foldButton.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle())
        .help(L("收起侧栏（⌘B）", "Collapse Sidebar (⌘B)"))
        .accessibilityLabel(L("收起侧栏", "Collapse Sidebar"))
        .accessibilityIdentifier("sidebar-collapse")
      }
    }
    .padding(.horizontal, SidebarMetrics.topBarPadding)
    .frame(height: SidebarMetrics.topBar)
    .background(WindowChrome(expanded: expanded))
  }

  private func toggle() {
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { expanded.toggle() }
  }

  /// A paper's full title next to its tile: the letters are only a mark. Not for the open paper
  /// while the panel shows its title anyway.
  @ViewBuilder
  private func tooltip(_ anchors: [Project.ID: Anchor<CGRect>]) -> some View {
    GeometryReader { geo in
      if let id = tipFor, let anchor = anchors[id], let project = model.projects.first(where: { $0.id == id }),
         !(expanded && id == model.activeProjectID) {
        let tile = geo[anchor]
        PaperTooltip(project: project, chats: model.conversations[id]?.count)
          .frame(width: 228, alignment: .leading)
          .offset(x: tile.maxX + 10, y: max(4, tile.minY - 4))
          .transition(.opacity)
          .allowsHitTesting(false)
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: tipFor)
  }
}

/// Where each paper's tile is, for the tooltip.
struct TileAnchors: PreferenceKey {
  static let defaultValue: [Project.ID: Anchor<CGRect>] = [:]
  static func reduce(value: inout [Project.ID: Anchor<CGRect>], nextValue: () -> [Project.ID: Anchor<CGRect>]) {
    value.merge(nextValue()) { $1 }
  }
}

private struct PaperTooltip: View {
  let project: Project
  let chats: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(project.displayTitle)
        .font(.system(size: 12.5, weight: .semibold, design: .serif))
        .lineLimit(4).fixedSize(horizontal: false, vertical: true)
      Text(meta).font(.system(size: 10.5)).opacity(0.72)
    }
    .foregroundStyle(Palette.paper)
    .padding(.horizontal, 11).padding(.vertical, 8)
    .background(Palette.ink.opacity(0.93), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
  }

  private var meta: String {
    guard let chats else { return project.summaryLine }
    let count = chats == 0 ? L("还没有对话", "No chats yet") : L("\(chats) 条对话", plural(chats, "chat", "chats"))
    return project.summaryLine + " · " + count
  }
}

// MARK: - Rail

/// Every paper as a tile, the library above them and adding below. Collapsed, the rail also carries
/// the appearance, language and settings controls.
struct SidebarRail: View {
  @ObservedObject var model: AppModel
  @ObservedObject var backend: BackendManager
  let expanded: Bool
  let toggle: () -> Void
  @Binding var hovering: Project.ID?

  var body: some View {
    VStack(spacing: 0) {
      library.padding(.bottom, 4)
      ScrollView(.vertical) {
        VStack(spacing: SidebarMetrics.tileGap) {
          ForEach(model.projects) { project in
            PaperTile(model: model, project: project, expanded: expanded, expand: toggle) { inside in
              if inside { hovering = project.id } else if hovering == project.id { hovering = nil }
            }
          }
          NewPaperMenu(model: model) {
            Image(systemName: "plus").font(.system(size: 12, weight: .medium))
              .foregroundStyle(Palette.inkSoft)
              .frame(width: SidebarMetrics.tile.width, height: 36)
              .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                  .strokeBorder(Palette.inkFaint.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
              }
              .contentShape(Rectangle())
          }
          .help(L("新建项目或导入文档", "New Project or Import Document"))
          .accessibilityLabel(L("新建项目或导入文档", "New Project or Import Document"))
        }
        // room for the open tile's shadow, which the scroll view would otherwise cut
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
      }
      .scrollIndicators(.never)
      if !expanded {
        SidebarControls(backend: backend, vertical: true).padding(.top, 8)
      }
    }
    .padding(.bottom, 12)
    .frame(width: SidebarMetrics.rail)
    .frame(maxHeight: .infinity, alignment: .top)
  }

  /// The mark leads back to the library: every paper, and the agent that knows the list.
  private var library: some View {
    let here = model.activeProjectID == nil
    return Button { model.leaveProject() } label: {
      ScivaneMark().frame(width: SidebarMetrics.logoMark.width, height: SidebarMetrics.logoMark.height)
        .frame(width: SidebarMetrics.logo, height: SidebarMetrics.logo)
        .background(Palette.forest, in: RoundedRectangle(cornerRadius: 10.5, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 2.5, y: 1)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity)
    .overlay(alignment: .leading) { RailMarker(on: here) }
    .help(L("书房 · 全部论文", "Library · All Papers"))
    .accessibilityLabel(L("书房", "Library"))
    .accessibilityAddTraits(here ? .isSelected : [])
    .accessibilityIdentifier("sidebar-library")
  }
}

/// The bar at the rail's inner edge beside the place that is open.
private struct RailMarker: View {
  let on: Bool
  var body: some View {
    UnevenRoundedRectangle(bottomTrailingRadius: 2, topTrailingRadius: 2, style: .continuous)
      .fill(Palette.accent)
      .frame(width: 3, height: 22)
      .opacity(on ? 1 : 0)
      .accessibilityHidden(true)
  }
}

/// One paper on the rail. A click opens it; on the open paper with the panel folded, it unfolds.
private struct PaperTile: View {
  @ObservedObject var model: AppModel
  let project: Project
  let expanded: Bool
  let expand: () -> Void
  let onHover: (Bool) -> Void
  @State private var renaming = false
  @State private var hovered = false

  private var active: Bool { model.activeProjectID == project.id }

  var body: some View {
    Button {
      if active { if !expanded { expand() } }
      else { Task { await model.enterProjectFromSidebar(project) } }
    } label: {
      PaperGlyph(title: project.displayTitle, active: active, size: SidebarMetrics.tile)
        .brightness(hovered && !active ? 0.02 : 0)
        .scaleEffect(hovered && !active ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity)
    .overlay(alignment: .leading) { RailMarker(on: active) }
    .anchorPreference(key: TileAnchors.self, value: .bounds) { [project.id: $0] }
    .onHover { inside in hovered = inside; onHover(inside) }
    .disabled(model.sidebarNavigationBusy || model.projectBusy)
    .contextMenu { ProjectActions(model: model, project: project, renaming: $renaming) }
    .projectRename(model: model, project: project, isPresented: $renaming)
    .accessibilityLabel(project.displayTitle)
    .accessibilityAddTraits(active ? .isSelected : [])
    .accessibilityIdentifier("project-tile-\(project.id)")
  }
}

/// New project or import, from the rail's dashed tile and the library's Papers card.
struct NewPaperMenu<Label: View>: View {
  @ObservedObject var model: AppModel
  @ViewBuilder var label: () -> Label

  var body: some View {
    Menu {
      Button(L("新建项目…", "New Project…")) { model.sidebar.creatingProject = true }
        .disabled(model.projectBusy)
        .accessibilityIdentifier("sidebar-new-project")
      Button(L("导入 PDF 或图片…", "Import PDF or Image…")) { model.importPanel() }
        .accessibilityIdentifier("sidebar-import")
    } label: {
      label()
    }
    // the native menu style would keep only the label's first image or text, without its frame
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
  }
}

// MARK: - Controls

/// The service's state, appearance, language and Settings, in one capsule at the foot of the panel;
/// stacked on the rail when the panel is folded, where the state becomes a dot on the gear.
struct SidebarControls: View {
  @ObservedObject var backend: BackendManager
  var vertical = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: vertical ? 15 : 14, style: .continuous)
    Group {
      if vertical {
        VStack(spacing: 2) {
          AppearanceCycleButton()
          LanguageMenu(width: 30, height: 26)
          settings(badge: true)
        }
      } else {
        HStack(spacing: 3) {
          status.frame(maxWidth: .infinity, alignment: .leading)
          AppearanceControl()
          LanguageMenu()
          settings(badge: false)
        }
      }
    }
    .padding(3)
    .background(Palette.card, in: shape)
    .overlay(shape.strokeBorder(Palette.cardEdge, lineWidth: 1))
    .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
  }

  @ViewBuilder
  private var status: some View {
    let label = HStack(spacing: 7) {
      StatusDot(tone: backend.statusTone, halo: backend.state.isReady)
      Text(backend.statusWord).font(.system(size: 11)).foregroundStyle(Palette.inkSoft).lineLimit(1)
    }
    .padding(.leading, 7)
    if case .failed = backend.state {
      Button { backend.restart() } label: {
        HStack(spacing: 4) {
          label
          Text(L("重试", "Retry")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accent)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(backend.statusDetail)
    } else {
      label.help(backend.statusDetail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(backend.statusTitle)
    }
  }

  private func settings(badge: Bool) -> some View {
    SettingsLink {
      Image(systemName: "gearshape").font(.system(size: 12.5))
        .foregroundStyle(Palette.inkSoft)
        .frame(width: badge ? 30 : 28, height: badge ? 28 : 24)
        .overlay(alignment: .topTrailing) {
          if badge { StatusDot(tone: backend.statusTone, size: 6, halo: false).padding(4) }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(badge ? L("设置 · \(backend.statusTitle)", "Settings · \(backend.statusTitle)") : L("设置", "Settings"))
    .accessibilityLabel(L("设置", "Settings"))
  }
}
