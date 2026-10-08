import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var backend: BackendManager
  @State private var isTargeted = false
  @AppStorage("sidebarVisible") private var sidebarVisible = true
  @State private var documentQuery = ""
  @State private var creatingProject = false
  @State private var newProjectTitle = ""
  @State private var showReadingOptions = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 0) {
      if sidebarVisible { SidebarView(model: model, backend: backend) }
      VStack(spacing: 0) {
        header
        Hairline()
        ZStack {
          ReaderView(model: model)
          if isTargeted {
            RoundedRectangle(cornerRadius: 16)
              .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
              .background(Palette.accent.opacity(0.05)).padding(.horizontal, 10).padding(
                .vertical, 9
              ).allowsHitTesting(false)
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }.background(Palette.paper)
    }
    .overlay(alignment: .bottom) {
      if let notice = model.notice {
        Label(notice, systemImage: "checkmark.circle.fill")
          .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
          .padding(.horizontal, 14).padding(.vertical, 10)
          .background(.regularMaterial, in: Capsule())
          .overlay(Capsule().strokeBorder(Palette.rule))
          .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
          .padding(.bottom, 58).allowsHitTesting(false)
      }
    }
    .task(id: model.noticeID) {
      guard model.notice != nil else { return }
      do { try await Task.sleep(nanoseconds: 2_200_000_000) } catch { return }
      model.notice = nil
    }
    // Quietly load the project list at launch; without a runtime the list is just empty.
    .task { await model.refreshProjects(quiet: true) }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: sidebarVisible)
    .tint(Palette.accent)
    .dropDestination(for: URL.self) { urls, _ in
      let accepted = urls.filter { url in
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return DocumentJob.supportedTypes.contains { type.conforms(to: $0) }
      }
      guard !accepted.isEmpty else { return false }
      model.add(urls: accepted)
      return true
    } isTargeted: {
      isTargeted = $0
    }
    .navigationTitle("Scivane")
  }


  /// One sidebar row, shared by all rows; the primary action is told apart by icon colour.
  private func navRow(
    _ title: String, symbol: String, accent: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) { navRowLabel(title, symbol: symbol, accent: accent) }
      .buttonStyle(SidebarRowStyle())
  }

  private func navRowLabel(_ title: String, symbol: String, accent: Bool) -> some View {
    HStack(spacing: 9) {
      Image(systemName: symbol).font(.system(size: 12, weight: accent ? .semibold : .regular))
        .foregroundStyle(accent ? Palette.accent : Palette.inkSoft)
        .frame(width: 15)
      Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10).frame(height: 31)
    .contentShape(Rectangle())
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 10.5, weight: .medium))
      .foregroundStyle(Palette.inkFaint)
      .padding(.horizontal, 10).padding(.bottom, 4)
  }

  /// - Parameter action: the "+" of the Projects section; nil shows only the title.
  private func sectionHeader(
    _ title: String, count: Int, action: (label: String, run: () -> Void)? = nil
  ) -> some View {
    HStack(spacing: 6) {
      Text(title).font(.system(size: 10, weight: .medium))
      Spacer()
      if let action {
        Button(action: action.run) {
          Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
        }
        .buttonStyle(.plain).help(action.label).accessibilityLabel(action.label)
      }
      Text("\(count)").font(.system(size: 10, design: .monospaced))
    }.foregroundStyle(Palette.inkFaint).padding(.top, 14).padding(.bottom, 5)
  }

  private var looseCount: Int {
    model.jobs.filter { model.jobProjects[$0.id] == nil }.count
  }

  private var filteredProjects: [Project] {
    let query = documentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty
      ? model.projects : model.projects.filter { $0.title.localizedStandardContains(query) }
  }

  /// Only loose documents. A project's files belong to the project and would otherwise appear twice,
  /// under disk names like `source`.
  private var filteredJobs: [DocumentJob] {
    let query = documentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let loose = model.jobs.filter { model.jobProjects[$0.id] == nil }
    return query.isEmpty
      ? loose : loose.filter { $0.title.localizedStandardContains(query) }
  }

  // MARK: - Toolbar
  //
  // One toolbar for back, title, pane, layout and more; the page number floats over the PDF.
  // One-off actions such as Start OCR live in the empty text pane and the ... menu.

  private var header: some View {
    HStack(spacing: 12) {
      Button { sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
        .help(L("文档列表（⌘B）", "Sidebar (⌘B)")).accessibilityLabel(L("切换侧栏", "Toggle Sidebar"))

      // A way back out of a project, without which the librarian could never be reached again.
      if model.activeProject != nil {
        Button { model.leaveProject() } label: { Image(systemName: "chevron.backward") }
          .help(L("退出项目 · 回到全部项目", "Leave Project · Back to All Projects"))
          .accessibilityLabel(L("退出项目", "Leave Project"))
          .accessibilityIdentifier("leave-project")
      }

      Text(anchorTitle)
        .font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
        .lineLimit(1).truncationMode(.middle)
        .help(anchorSubtitle)

      Spacer(minLength: 16)

      // no project yet for this document: show the main action
      Group {
        if let source = model.readingSource, model.canBuildProject(source) {
          Button { Task { await model.buildProject(from: source) } } label: {
            Label(L("构建项目", "Build Project"), systemImage: "square.stack.3d.up.fill")
          }
          .buttonStyle(StudioButtonStyle(primary: true)).disabled(model.projectBusy)
          .help(L("复制原稿建立项目，自动识别并长期保存",
                  "Copy the original into a project that's recognized and kept"))
        }

        SegmentedTabs(items: paneTabs, selection: $model.paneSelection)

        // Single/dual layout stays on the toolbar, as a segmented control so both states are visible.
        SegmentedTabs(items: layoutTabs, selection: layoutSelection, iconOnly: true)
          .accessibilityIdentifier("toggle-dual-pane")
      }

      Menu {
        if let source = model.readingSource, source.canStartOCR {
          Button(L("开始 OCR", "Start OCR")) { model.startOCR(source) }
          Divider()
        }
        // Not disabled without a text pane: the dialog also sets the conversation text size.
        Button(L("字号…", "Text Size…")) { showReadingOptions = true }
        Toggle(L("原稿缩略图", "Page Thumbnails"), isOn: $model.showThumbnails)
          .disabled(model.readingSource?.isPDF != true)
        if model.readingDocument?.isMarkdown == true, model.readingSource?.hasResult == true {
          Button(L("改用原稿的 OCR 结果", "Use the Original's OCR Result Instead")) { model.useOCRText() }
        }
        Divider()
        Button(L("导出 Markdown…", "Export Markdown…")) {
          if let job = model.readingDocument { model.exportOne(job) }
        }
          .disabled(model.readingDocument == nil)
        Button(L("复制 Markdown", "Copy Markdown")) { model.copyMarkdown() }
          .disabled(model.readingDocument == nil)
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.borderlessButton).fixedSize().help(L("更多", "More"))
      .accessibilityLabel(L("更多选项", "More Options"))
      .popover(isPresented: $showReadingOptions) { ReadingOptions() }

      Button { model.importPanel() } label: { Image(systemName: "plus") }
        .help(L("导入文档", "Import Document")).accessibilityLabel(L("导入文档", "Import Document"))
    }
    .buttonStyle(ToolButtonStyle()).foregroundStyle(Palette.inkSoft)
    .padding(.horizontal, 16).padding(.leading, sidebarVisible ? 0 : 76)
    .frame(height: 46)
  }

  /// The project name, not the on-disk file name (every source copy is called source.pdf).
  private var anchorTitle: String {
    if let project = model.activeProject { return project.title }
    if let job = model.selected { return job.title }
    return "Scivane"
  }

  private var anchorSubtitle: String {
    model.activeProject?.sourceName ?? model.selected?.url.path ?? ""
  }

  private var layoutTabs: [SegmentedTabs.Item] {
    [.init(id: "single", label: L("单栏", "Single Pane"), symbol: "rectangle"),
     .init(id: "dual", label: L("双栏对照 · 原稿在左", "Side by Side · Original on the Left"),
           symbol: "rectangle.split.2x1")]
  }

  private var layoutSelection: Binding<String> {
    Binding(get: { model.dualPane ? "dual" : "single" },
            set: { model.dualPane = $0 == "dual" })
  }

  private var paneTabs: [SegmentedTabs.Item] {
    let text = SegmentedTabs.Item(id: "text", label: L("正文", "Text"), symbol: "text.alignleft")
    let chat = SegmentedTabs.Item(id: "chat", label: "Agent", symbol: "sparkles")
    if model.dualPane { return [text, chat] }
    return [.init(id: "source", label: L("原稿", "Original"), symbol: "doc"), text, chat]
  }

}
