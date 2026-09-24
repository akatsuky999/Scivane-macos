import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var backend: BackendManager
  @State private var isTargeted = false
  @AppStorage("sidebarVisible") private var sidebarVisible = true
  @State private var documentQuery = ""
  /// 「新建项目」弹窗。
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
    // 启动时静默拉一次项目列表。没装运行时的人只是看不到项目，
    // 读 Markdown 这条路完全不受影响。
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


  /// 侧栏里的一行导航。**所有行共用它** —— 主动作靠图标着色区分，不靠实心底。
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

  /// 分组标题。安静、不带计数 —— 计数是给统计看的，不是给人找东西用的。
  private func sectionTitle(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 10.5, weight: .medium))
      .foregroundStyle(Palette.inkFaint)
      .padding(.horizontal, 10).padding(.bottom, 4)
  }

  /// - Parameter action: 给「项目」那节用的「＋」。传 nil 就只有标题和计数。
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

  /// 不属于任何项目的文档数。
  private var looseCount: Int {
    model.jobs.filter { model.jobProjects[$0.id] == nil }.count
  }

  private var filteredProjects: [Project] {
    let query = documentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty
      ? model.projects : model.projects.filter { $0.title.localizedStandardContains(query) }
  }

  /// 「本次文档」只列临时文档。
  ///
  /// 属于某个项目的文件不在这里出现 —— 进入项目时它的原稿与正文会被挂进
  /// 阅读区（走和手动导入同一套 job 机制），但那是项目的一部分，
  /// 在侧栏里再列一遍会让同一篇论文出现两次，而且名字是 `source` 这种
  /// 磁盘文件名，读的人根本认不出是哪篇。
  private var filteredJobs: [DocumentJob] {
    let query = documentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let loose = model.jobs.filter { model.jobProjects[$0.id] == nil }
    return query.isEmpty
      ? loose : loose.filter { $0.title.localizedStandardContains(query) }
  }

  // MARK: - 唯一那条工具栏
  //
  // 之前是两条：46pt 的全局栏 + 每栏 38pt 的栏头，内容开始前先吃掉 84pt。
  // 对一个「论文才是主角」的阅读器，这个比例站不住。现在栏的身份、布局、
  // 模式切换全部收在这一条里；页码浮到原稿之上，不再占布局高度。
  //
  // 常驻的只有五类：**退到哪去**（返回）、**当前在读什么**（标题）、
  // **看哪一栏**（分段）、**怎么排**（单双栏）、**还能做什么**（⋯ 与 ＋）。
  // 「开始 OCR」这种一次性动作不常驻 —— 它在正文栏的空态里，也在 ⋯ 里。

  private var header: some View {
    HStack(spacing: 12) {
      Button { sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
        .help(L("文档列表（⌘B）", "Sidebar (⌘B)")).accessibilityLabel(L("切换侧栏", "Toggle Sidebar"))

      // **进得去就必须出得来。** 没有这个入口时，打开一篇论文之后回不到
      // 「还没打开任何项目」那个状态 —— 书房那层 agent（跨项目的那一层）
      // 也就再没有入口了。`leaveProject` 一直都在，缺的只是一个按钮。
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

      // 这一篇还没建项目时，把主动作摆出来 —— 它是产品里最该被点的那个
      Group {
        if let source = model.readingSource, model.canBuildProject(source) {
          Button { Task { await model.buildProject(from: source) } } label: {
            Label(L("构建项目", "Build Project"), systemImage: "square.stack.3d.up.fill")
          }
          .buttonStyle(StudioButtonStyle(primary: true)).disabled(model.projectBusy)
          .help(L("复制原稿建立项目，自动识别并长期保存",
                  "Copy the original into a project that's recognized and kept"))
        }

        // 放大镜去掉了 —— ⌘F 人人都会按，而工具栏上每多一个常驻图标，
        // 真正重要的那几个就少一分。
        SegmentedTabs(items: paneTabs, selection: $model.paneSelection)

        // **单/双栏常驻。** 一度随「双栏对照下架」一起去掉，结果是进了项目就是
        // 双栏且回不到单栏。对照着读是这个产品的日常
        // 动作之一，藏进菜单等于没有。
        //
        // 用**和左边那组同一种分段控件**，只是不带文字：一个裸图标按钮要靠
        // 选中态去表达"现在是几栏"，而分段控件把两种状态一起摆出来、滑块指着
        // 当前那个 —— 不用猜画的是"现在"还是"点下去会变成"。
        SegmentedTabs(items: layoutTabs, selection: layoutSelection, iconOnly: true)
          .accessibilityIdentifier("toggle-dual-pane")
      }

      Menu {
        if let source = model.readingSource, source.canStartOCR {
          Button(L("开始 OCR", "Start OCR")) { model.startOCR(source) }
          Divider()
        }
        // 里面现在有正文与对话两档，所以**不再随"有没有正文"禁用** ——
        // 在 Agent 那栏想调对话字号时，正文栏往往正好是空的。
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

  /// 标题显示项目名，而不是磁盘文件名。
  /// 项目里的原稿副本一律叫 `source.pdf`，把它摆在最显眼处毫无信息量。
  private var anchorTitle: String {
    if let project = model.activeProject { return project.title }
    if let job = model.selected { return job.title }
    return "Scivane"
  }

  private var anchorSubtitle: String {
    model.activeProject?.sourceName ?? model.selected?.url.path ?? ""
  }

  /// 单 / 双栏那一组。图标本身就说明形状，文字退到 tooltip。
  private var layoutTabs: [SegmentedTabs.Item] {
    [.init(id: "single", label: L("单栏", "Single Pane"), symbol: "rectangle"),
     .init(id: "dual", label: L("双栏对照 · 原稿在左", "Side by Side · Original on the Left"),
           symbol: "rectangle.split.2x1")]
  }

  /// 分段控件认字符串，布局是个布尔 —— 这里翻译一次。
  private var layoutSelection: Binding<String> {
    Binding(get: { model.dualPane ? "dual" : "single" },
            set: { model.dualPane = $0 == "dual" })
  }

  /// 单栏三选一，双栏右栏两选一。
  private var paneTabs: [SegmentedTabs.Item] {
    let text = SegmentedTabs.Item(id: "text", label: L("正文", "Text"), symbol: "text.alignleft")
    let chat = SegmentedTabs.Item(id: "chat", label: "Agent", symbol: "sparkles")
    if model.dualPane { return [text, chat] }
    return [.init(id: "source", label: L("原稿", "Original"), symbol: "doc"), text, chat]
  }

}
