import SwiftUI

/// The reading area's toolbar: a glass island beside the sidebar's, with the panes starting below it.
///
/// Its first zone is the paper: unfold the sidebar, back out of a project, the title. The second belongs
/// to the right-hand pane, the chat or the document shown; side by side, it starts right above the
/// panes' divider, so each control sits over the pane it acts on. The view and layout switches and the
/// More menu close the row.
struct ToolbarIsland: View {
  @ObservedObject var model: AppModel
  /// from the reading area's leading edge: clear of the sidebar's island, or of its rail
  let leading: CGFloat
  @State private var showReadingOptions = false
  @State private var moreHovering = false

  private var textShown: Bool { model.dualPane || model.singlePane == .text }
  private var agentShown: Bool { textShown && model.textMode == .chat }
  private var documentShown: Bool { textShown && model.textMode == .document }
  private var hasPaneZone: Bool { model.activeProject != nil && (agentShown || documentShown) }

  var body: some View {
    GeometryReader { band in
      HStack(spacing: 2) {
        PaperZone(
          model: model, split: model.split, bandWidth: band.size.width, leading: leading,
          aligned: model.dualPane && hasPaneZone)
        if hasPaneZone {
          Rectangle().fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: SidebarMetrics.toolbarControl)
            .accessibilityHidden(true)
          paneZone.padding(.leading, 4)
        }
        Spacer(minLength: 12)
        buildProject
        ViewSwitcher(pane: $model.paneSelection, dual: $model.dualPane)
          .fixedSize()
          .padding(.trailing, 2)
        moreMenu
      }
      .padding(SidebarMetrics.toolbarPadding)
      .frame(height: SidebarMetrics.toolbar)
      .toolbarSurface()
      .padding(.leading, leading)
      .padding(.trailing, SidebarMetrics.inset)
      .padding(.vertical, SidebarMetrics.inset)
    }
    .frame(height: SidebarMetrics.toolbarBand)
  }

  @ViewBuilder private var paneZone: some View {
    if let project = model.activeProject {
      if agentShown {
        ConversationSwitcher(model: model)
      } else if documentShown {
        TextDocumentMenu(model: model, project: project)
      }
    }
  }

  /// A loose document has no project yet: its main action.
  @ViewBuilder private var buildProject: some View {
    if let source = model.readingSource, model.canBuildProject(source) {
      Button { Task { await model.buildProject(from: source) } } label: {
        Label(L("构建项目", "Build Project"), systemImage: "square.stack.3d.up.fill")
      }
      .buttonStyle(StudioButtonStyle(primary: true)).disabled(model.projectBusy)
      .help(L("复制原稿建立项目，自动识别并长期保存",
              "Copy the original into a project that's recognized and kept"))
      .padding(.trailing, 6)
    }
  }

  // MARK: - More

  private var moreMenu: some View {
    Menu {
      moreItems
    } label: {
      Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium))
        .foregroundStyle(Palette.inkSoft)
        .frame(width: 34, height: SidebarMetrics.toolbarControl)
        .background(ToolbarHover(active: moreHovering || showReadingOptions))
        .contentShape(Rectangle())
    }
    // the native borderless style keeps only the label's first image and text
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    .onHover { moreHovering = $0 }
    .help(L("更多", "More"))
    .accessibilityLabel(L("更多选项", "More Options"))
    .popover(isPresented: $showReadingOptions) { ReadingOptions() }
  }

  /// Most used first; recognizing again, which replaces the text, last and on its own.
  @ViewBuilder private var moreItems: some View {
    Section(L("阅读", "Reading")) {
      // not disabled without a text pane: the dialog also sets the conversation text size
      Button { showReadingOptions = true } label: {
        Label(L("字号与间距…", "Text Size & Spacing…"), systemImage: "textformat.size")
      }
      Toggle(isOn: $model.showThumbnails) {
        Label(L("原稿缩略图", "Page Thumbnails"), systemImage: "sidebar.squares.left")
      }
      .keyboardShortcut("t", modifiers: [.command, .control])
      .disabled(model.readingSource?.isPDF != true)
      if model.readingDocument?.isMarkdown == true, model.readingSource?.hasResult == true {
        Button { model.useOCRText() } label: {
          Label(L("改用原稿的 OCR 结果", "Use the Original's OCR Result Instead"), systemImage: "arrow.uturn.backward")
        }
      }
    }
    Section(L("导出", "Export")) {
      Button {
        if let job = model.readingDocument { model.exportOne(job) }
      } label: {
        Label(L("导出 Markdown…", "Export Markdown…"), systemImage: "square.and.arrow.up")
      }
      .keyboardShortcut("e", modifiers: .command)
      .disabled(model.readingDocument == nil)
      Button { model.copyMarkdown() } label: {
        Label(L("复制 Markdown", "Copy Markdown"), systemImage: "doc.on.doc")
      }
      .keyboardShortcut("c", modifiers: [.command, .shift])
      .disabled(model.readingDocument == nil)
    }
    if let source = model.readingSource, !source.isMarkdown, !source.status.isRunning,
      source.status != .queued
    {
      Section(L("原稿", "Original")) {
        Button { model.requestRecognition(source) } label: {
          Label(hasText(source) ? L("重新识别…", "Recognize Again…") : L("识别原稿…", "Recognize Original…"),
                systemImage: "doc.text.viewfinder")
        }
      }
    }
  }

  /// Recognised already, in this session or as its project's paper text.
  private func hasText(_ source: DocumentJob) -> Bool {
    source.hasResult || model.jobProjects[source.id].flatMap { id in
      model.projects.first { $0.id == id }?.hasUsableContext } == true
  }
}

/// The paper's zone: unfold the sidebar, back out of a project, the title. Side by side it ends right
/// above the panes' divider; it watches the divider's position itself, so a drag redraws only this.
private struct PaperZone: View {
  @ObservedObject var model: AppModel
  @ObservedObject var split: SplitPosition
  /// the reading area's width, which the panes share
  let bandWidth: CGFloat
  let leading: CGFloat
  let aligned: Bool
  @AppStorage("sidebarVisible") private var sidebarVisible = true
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    HStack(spacing: 2) {
      if !sidebarVisible {
        ToolbarIconButton(
          symbol: "sidebar.left", label: L("展开侧栏", "Expand Sidebar"),
          help: L("展开侧栏（⌘B）", "Expand Sidebar (⌘B)")
        ) {
          sidebarVisible = true
        }
        .accessibilityIdentifier("sidebar-expand")
      }
      // A way back out of a project, without which the librarian could never be reached again.
      if model.activeProject != nil {
        ToolbarIconButton(
          symbol: "chevron.backward", label: L("退出项目", "Leave Project"),
          help: L("退出项目 · 回到全部项目", "Leave Project · Back to All Projects"), size: 12
        ) {
          model.leaveProject()
        }
        .accessibilityIdentifier("leave-project")
      }
      Text(title)
        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
        .lineLimit(1).truncationMode(.middle)
        .padding(.leading, 4).padding(.trailing, 8)
        .help(subtitle)
    }
    .frame(width: alignedWidth, alignment: .leading)
  }

  /// Ends where the divider that follows lands right above the panes' divider. Too narrow a zone (a
  /// narrow window with the sidebar over the source) gives up the alignment rather than the title.
  private var alignedWidth: CGFloat? {
    guard aligned else { return nil }
    let divider = ReadingSplit.sourceWidth(fraction: split.current, in: bandWidth, scale: displayScale)
    // the island's padding, then the row's spacing before the divider
    let width = divider - leading - SidebarMetrics.toolbarPadding - 2
    return width >= 140 ? width : nil
  }

  /// The project name, not the on-disk file name (every source copy is called source.pdf).
  private var title: String {
    if let project = model.activeProject { return project.title }
    if let job = model.selected { return job.title }
    return "Scivane"
  }

  private var subtitle: String {
    model.activeProject?.sourceName ?? model.selected?.url.path ?? ""
  }
}
