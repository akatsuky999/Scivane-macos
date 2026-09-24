import SwiftUI

/// 侧栏的尺寸表。
///
/// **行高、缩进、留白必须一起看。** 三者散在各视图里各写一个数字，改其中一个
/// 就把整列的节奏破掉了 —— 不报错、没有断言会红，只是看起来"不太对"。
/// 宽度也只在这里定一次，别处都从这里取。
enum SidebarMetrics {
  /// 264 → 236。论文标题一行本来就装不下（完整标题在 tooltip 里），
  /// 靠加宽救不动它，只会把右边真正在读的那半边挤窄。
  static let width: CGFloat = 236
  /// **外侧留白小、行内内边距大**：hover 的底色因此铺满一整行，
  /// 而不是缩在一个盒子里，让侧栏与主内容保持清晰的层次。
  static let gutter: CGFloat = 8
  static let inset: CGFloat = 10
  /// 顶上两个动作比树里的行高一点 —— 它们是这一列里唯二的主动作。
  static let actionRow: CGFloat = 32
  static let actionGap: CGFloat = 2
  static let treeRow: CGFloat = 28
  /// 品牌与分节标题的**整块高度**，由各自的留白推出来。
  ///
  /// 写成推导量而不是散在视图里的 padding，是为了能从这里算出
  /// 第一条项目行在哪。
  /// 直接写死坐标的话，改一次行高就对不上了，而且不会报错。
  static let brandTop: CGFloat = 30      // 红绿灯净空，不能再小
  static let brandContent: CGFloat = 27
  static let brandBottom: CGFloat = 14
  static var brandBlock: CGFloat { brandTop + brandContent + brandBottom }
  static let sectionTop: CGFloat = 14
  static let sectionContent: CGFloat = 22
  static let sectionBottom: CGFloat = 4
  static var sectionBlock: CGFloat { sectionTop + sectionContent + sectionBottom }
  static let corner: CGFloat = 8
  /// 折叠箭头的宽度，同时也是项目标题的起点。
  static let disclosure: CGFloat = 20
  /// 对话行的缩进。圆点落在箭头的右下方，两级之间自然接成一条竖线。
  static let childIndent: CGFloat = 20
}

/// 项目与对话共用一棵导航树；展开只影响浏览，不改变当前工作区。
struct SidebarView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var backend: BackendManager
  @State private var query = ""
  @State private var searching = false
  @State private var creatingProject = false
  @State private var newProjectTitle = ""
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      brand
      actions
      sectionHeader
      if searching { filter }
      list
      footer
    }
    .padding(.horizontal, SidebarMetrics.gutter)
    .frame(width: SidebarMetrics.width)
    .background(Palette.sidebar)
    .overlay(alignment: .trailing) { Rectangle().fill(Palette.ruleSoft).frame(width: 1) }
    .alert(L("新建项目", "New Project"), isPresented: $creatingProject) {
      TextField(L("项目名称（可留空）", "Project name (optional)"), text: $newProjectTitle)
      Button(L("创建", "Create")) {
        let title = newProjectTitle
        Task { await model.createEmptyProject(title: title) }
      }
      Button(L("取消", "Cancel"), role: .cancel) {}
    }
  }

  /// 品牌压到这一列里最小的可辨识尺寸。
  ///
  /// 它是每次开 App 都在、但**一次都不会被点**的东西；先前 23pt 的字加一块
  /// 大色块占掉顶上 90pt，等于把最贵的位置给了不干活的元素。
  /// 上留白 30pt 是红绿灯的净空，不能再小。
  private var brand: some View {
    HStack(spacing: 9) {
      // 色块给一层极浅的投影：纯平的方块在这片淡绿上会"浮"不起来，
      // 一点点阴影就能让它像一枚压在纸上的印章。半径压到 2.5，再多就脏了。
      ScivaneMark().frame(width: 14, height: 17).padding(5)
        .background(Palette.forest, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 2.5, y: 1)
      Text("Scivane").font(.custom("Baskerville", size: 21.5)).tracking(-0.5)
      Spacer()
    }
    .foregroundStyle(Palette.ink)
    .padding(.horizontal, SidebarMetrics.inset)
    .frame(height: SidebarMetrics.brandContent)
    .padding(.top, SidebarMetrics.brandTop).padding(.bottom, SidebarMetrics.brandBottom)
  }

  private var actions: some View {
    VStack(spacing: SidebarMetrics.actionGap) {
      Button { newProjectTitle = ""; creatingProject = true } label: {
        actionRow("plus", L("新建项目", "New Project"), accent: true)
      }
      .accessibilityIdentifier("sidebar-new-project")
      .disabled(model.projectBusy)
      Button { model.importPanel() } label: {
        actionRow("tray.and.arrow.down", L("导入文档", "Import Document"), accent: false)
      }
      .accessibilityIdentifier("sidebar-import")
    }
    .buttonStyle(SidebarRowStyle())
  }

  /// 同一种控件、图标槽与文字槽，避免 SF Symbol 的固有宽度改变两行起点。
  ///
  /// **只有主动作那个图标着色。** 两行都是绿的时候，绿色不再表示"这是主动作"，
  /// 只表示"这是图标"；次动作退回墨色之后，视线第一下才落得到「新建项目」上。
  private func actionRow(_ symbol: String, _ title: String, accent: Bool) -> some View {
    HStack(spacing: 10) {
      Image(systemName: symbol).font(.system(size: 13, weight: accent ? .semibold : .regular))
        .foregroundStyle(accent ? Palette.accent : Palette.inkSoft)
        .frame(width: 18, height: 18)
      // 字距开 0.15：这两行是整列里字号最大的文字，中文在小字号下挤在一起
      // 会显得"闷"，开一点点就松下来了 —— 再多就散，不成词。
      Text(title).font(.system(size: 13, weight: .medium)).tracking(0.15)
      Spacer(minLength: 0)
    }
    .foregroundStyle(Palette.ink)
    .padding(.horizontal, SidebarMetrics.inset).frame(height: SidebarMetrics.actionRow)
    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
  }

  /// 分节标题：安静、小、带一点字距 —— 它是路标，不是按钮。
  private var sectionHeader: some View {
    HStack(spacing: 4) {
      Text(L("项目", "Projects")).font(.system(size: 10.5, weight: .medium)).tracking(0.4)
      Spacer(minLength: 0)
      Button {
        searching.toggle()
        if searching { searchFocused = true } else { query = "" }
      } label: {
        Image(systemName: "magnifyingglass").font(.system(size: 10.5))
          .frame(width: 22, height: 22)
      }
      .buttonStyle(SidebarRowStyle()).help(L("筛选项目", "Filter Projects"))
      .accessibilityLabel(L("筛选项目", "Filter Projects"))
    }
    .foregroundStyle(Palette.inkFaint)
    .padding(.leading, SidebarMetrics.inset).padding(.trailing, 2)
    .frame(height: SidebarMetrics.sectionContent)
    .padding(.top, SidebarMetrics.sectionTop).padding(.bottom, SidebarMetrics.sectionBottom)
  }

  private var filter: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").font(.system(size: 10.5))
      TextField(L("筛选项目", "Filter Projects"), text: $query)
        .textFieldStyle(.plain).font(.system(size: 12)).focused($searchFocused)
        .accessibilityLabel(L("项目名称", "Project name"))
        .onExitCommand { query = ""; searching = false }
      if !query.isEmpty {
        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
          .buttonStyle(.plain).accessibilityLabel(L("清除筛选", "Clear Filter"))
      }
    }
    .foregroundStyle(Palette.inkSoft).padding(.horizontal, SidebarMetrics.inset).frame(height: 28)
    .background(Palette.ruleSoft, in: RoundedRectangle(cornerRadius: SidebarMetrics.corner))
    .padding(.bottom, 6)
  }

  private var list: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(projects) { project in
          SidebarProjectGroup(model: model, project: project)
        }
        if projects.isEmpty {
          Text(query.isEmpty ? L("还没有项目", "No projects yet") : L("没有匹配的项目", "No matching projects"))
            .font(.system(size: 11.5)).foregroundStyle(Palette.inkFaint)
            .padding(.horizontal, SidebarMetrics.inset).padding(.vertical, 10)
        }
        if !looseJobs.isEmpty {
          Text(L("本次文档", "This Session")).font(.system(size: 10.5, weight: .medium)).tracking(0.4)
            .foregroundStyle(Palette.inkFaint)
            .padding(.horizontal, SidebarMetrics.inset).padding(.top, 10)
          VStack(spacing: 1) {
            ForEach(looseJobs) { job in SidebarDocument(model: model, job: job) }
          }
        }
      }
      .padding(.bottom, 14)
    }
    .scrollIndicators(.hidden)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var projects: [Project] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty
      ? model.projects : model.projects.filter { $0.title.localizedStandardContains(trimmed) }
  }

  private var looseJobs: [DocumentJob] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return model.jobs.filter {
      model.jobProjects[$0.id] == nil
        && (trimmed.isEmpty || $0.title.localizedStandardContains(trimmed))
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 7) {
      // 横贯整列，与右侧那条竖线接上；缩在留白里的短线看着像没画完。
      Rectangle().fill(Palette.ruleSoft).frame(height: 1)
        .padding(.horizontal, -SidebarMetrics.gutter)
      HStack(spacing: 6) {
        Circle().fill(backend.state.isReady ? Palette.accent : Palette.inkFaint)
          .frame(width: 5, height: 5)
        Text(engineTitle).font(.system(size: 10.5))
        Spacer()
        if case .failed = backend.state {
          Button(L("重试", "Retry")) { backend.restart() }.buttonStyle(.plain)
            .font(.system(size: 10.5)).foregroundStyle(Palette.accent)
        }
      }
      .foregroundStyle(Palette.inkFaint).padding(.horizontal, SidebarMetrics.inset)
      .help(engineDetail)
      HStack(spacing: 0) {
        SettingsLink {
          HStack(spacing: 9) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 12)).frame(width: 17)
            Text(L("设置", "Settings")).font(.system(size: 12))
          }.padding(.horizontal, SidebarMetrics.inset).frame(height: SidebarMetrics.treeRow)
        }
        .buttonStyle(SidebarRowStyle())
        Spacer(minLength: 0)
        // 语言与外观同一种形态、并排：两件都是「这台 App 长什么样」，
        // 一个在设置里有完整的一栏，这里是随手可够的那一处（与外观一样两处入口）。
        LanguageControl()
        AppearanceControl()
      }.foregroundStyle(Palette.inkSoft)
    }
    .padding(.bottom, 12)
  }

  private var engineTitle: String {
    switch backend.state {
    case .idle: return L("服务未启动", "Service not started")
    case .launching: return L("正在启动服务", "Starting service")
    case .ready:
      return backend.runningMode == .full
        ? L("本地引擎就绪", "Local engine ready") : L("服务就绪", "Service ready")
    case .failed: return L("服务启动失败", "Service failed to start")
    }
  }

  private var engineDetail: String {
    if case .failed(let message) = backend.state { return message.text }
    return backend.runningMode == .lite
      ? L("需要识别文档时加载本地模型", "The local model loads when a document needs OCR") : engineTitle
  }
}

/// 多个项目可以同时展开；只在展开时读取清单，不为浏览创建空对话。
struct SidebarProjectGroup: View {
  @ObservedObject var model: AppModel
  let project: Project
  @State private var expanded = true
  @State private var loading = false
  @State private var loadFailed = false
  @State private var navigating = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var conversations: [Conversation] { model.conversations[project.id] ?? [] }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ProjectRow(model: model, project: project, expanded: expanded, toggleExpanded: {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { expanded.toggle() }
      }) {
        Button {
          expanded = true
          Task {
            navigating = true
            defer { navigating = false }
            await model.newConversation(in: project)
          }
        } label: {
          Image(systemName: "plus").font(.system(size: 11.5, weight: .regular))
            .frame(width: 22, height: SidebarMetrics.treeRow).contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle()).foregroundStyle(Palette.inkFaint)
        .disabled(navigating || model.projectBusy || model.sidebarNavigationBusy)
        .help(L("在「\(project.displayTitle)」中新建对话", "New chat in “\(project.displayTitle)”"))
        .accessibilityLabel(L("在 \(project.displayTitle) 中新建对话", "New chat in \(project.displayTitle)"))
        .accessibilityIdentifier("project-new-chat-\(project.id)")
      }
      if expanded {
        VStack(alignment: .leading, spacing: 1) {
          ForEach(conversations) { conversation in
            SidebarConversationRow(model: model, project: project, conversation: conversation)
          }
          if conversations.isEmpty {
            if loading {
              placeholder(L("正在载入…", "Loading…"))
            } else if loadFailed {
              Button { Task { await load() } } label: {
                placeholder(L("载入失败 · 重试", "Couldn't load · Retry"))
              }
                .buttonStyle(.plain)
            } else {
              placeholder(L("暂无对话", "No chats yet"))
            }
          }
        }
      }
    }
    .task(id: expanded) {
      // 离屏画廊只消费夹具，不应为了渲染启动用户的后端。
      if expanded && model.isLiveApp { await load() }
    }
  }

  /// 与对话行同一个文字起点 —— 占位文字缩在别处会让人以为它属于另一层。
  private func placeholder(_ text: String) -> some View {
    Text(text).font(.system(size: 11)).foregroundStyle(Palette.inkFaint)
      .padding(.leading, SidebarMetrics.childIndent + 13).frame(height: 26)
  }

  private func load() async {
    loading = true
    defer { loading = false }
    loadFailed = !(await model.refreshConversations(project.id))
  }
}

struct SidebarConversationRow: View {
  @ObservedObject var model: AppModel
  let project: Project
  let conversation: Conversation
  @State private var renaming = false
  @State private var draftTitle = ""

  private var isCurrent: Bool {
    model.activeProjectID == project.id && model.activeConversation[project.id] == conversation.id
  }

  var body: some View {
    Button {
      Task { await model.openConversation(project: project, conversation: conversation.id) }
    } label: {
      HStack(spacing: 8) {
        Circle().fill(isCurrent ? Palette.accent : .clear)
          .overlay(Circle().strokeBorder(isCurrent ? Palette.accent : Palette.inkFaint.opacity(0.55), lineWidth: 1))
          .frame(width: 5, height: 5)
        Text(conversation.displayTitle)
          .font(.system(size: 12, weight: isCurrent ? .medium : .regular))
          .lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 0)
      }
      .foregroundStyle(isCurrent ? Palette.ink : Palette.inkSoft)
      .padding(.leading, SidebarMetrics.childIndent).padding(.trailing, SidebarMetrics.inset)
      .frame(height: SidebarMetrics.treeRow)
      .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
      // **不用 `Palette.selectedRow`。** 那是一块近白的实底，在这片淡绿上像
      // 贴了张纸；选中该是"比 hover 再深一点"的同一族底色，配上实心圆点与
      // 加重的字就够认了，避免再加一层装饰。
      .background(isCurrent ? Palette.ink.opacity(0.08) : .clear,
                  in: RoundedRectangle(cornerRadius: SidebarMetrics.corner, style: .continuous))
    }
    .buttonStyle(SidebarRowStyle())
    .disabled(model.sidebarNavigationBusy || model.projectBusy)
    .help(conversation.displayTitle)
    .accessibilityLabel(conversation.displayTitle)
    .accessibilityIdentifier("conversation-\(project.id)-\(conversation.id)")
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
    .contextMenu {
      Button(L("重命名…", "Rename…")) { draftTitle = conversation.displayTitle; renaming = true }
      Button(L("导出为 JSON…", "Export as JSON…")) {
        Task { await model.exportConversation(conversation.id, in: project.id) }
      }
      Divider()
      Button(L("删除对话…", "Delete Chat…"), role: .destructive) {
        Task { await model.deleteConversation(conversation.id, in: project.id) }
      }
    }
    .alert(L("重命名对话", "Rename Chat"), isPresented: $renaming) {
      TextField(L("标题", "Title"), text: $draftTitle)
      Button(L("保存", "Save")) {
        let title = draftTitle
        Task { await model.renameConversation(conversation.id, to: title, in: project.id) }
      }
      Button(L("取消", "Cancel"), role: .cancel) {}
    }
  }
}
