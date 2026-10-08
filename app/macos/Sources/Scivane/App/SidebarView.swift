import SwiftUI

/// Sidebar metrics. Row heights, indents and spacing are tuned together and live only here;
/// changing one in isolation breaks the column's rhythm without any check failing.
enum SidebarMetrics {
  /// Paper titles don't fit on one line at any sane width (the full title is in the tooltip);
  /// widening only squeezes the reading area.
  static let width: CGFloat = 236
  /// Small outer gutter, generous row padding: hover fills the whole row instead of a boxed inset.
  static let gutter: CGFloat = 8
  static let inset: CGFloat = 10
  /// The two actions at the top are a little taller: they are the column's only primary actions.
  static let actionRow: CGFloat = 32
  static let actionGap: CGFloat = 2
  static let treeRow: CGFloat = 28
  /// Block heights derived from their spacing, so the first project row's position can be computed
  /// here instead of hard-coded.
  static let brandTop: CGFloat = 30      // clearance for the traffic lights; no smaller
  static let brandContent: CGFloat = 27
  static let brandBottom: CGFloat = 14
  static var brandBlock: CGFloat { brandTop + brandContent + brandBottom }
  static let sectionTop: CGFloat = 14
  static let sectionContent: CGFloat = 22
  static let sectionBottom: CGFloat = 4
  static var sectionBlock: CGFloat { sectionTop + sectionContent + sectionBottom }
  static let corner: CGFloat = 8
  /// also where project titles start
  static let disclosure: CGFloat = 20
  /// the dot sits below and right of the chevron, so the two levels line up
  static let childIndent: CGFloat = 20
}

/// Projects and conversations share one tree; expanding only browses, it never changes the workspace.
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

  /// Brand at the smallest legible size: always present, never clicked. 30 pt top clears the
  /// traffic lights.
  private var brand: some View {
    HStack(spacing: 9) {
      // a faint shadow so the flat mark doesn't sink into the tinted background; radius above 2.5 looks dirty
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

  /// Fixed icon and text slots, so SF Symbols' intrinsic widths don't shift where the rows start.
  /// Only the primary action's icon is tinted; otherwise the accent stops meaning anything.
  private func actionRow(_ symbol: String, _ title: String, accent: Bool) -> some View {
    HStack(spacing: 10) {
      Image(systemName: symbol).font(.system(size: 13, weight: accent ? .semibold : .regular))
        .foregroundStyle(accent ? Palette.accent : Palette.inkSoft)
        .frame(width: 18, height: 18)
      // slight tracking: at this size CJK text otherwise looks cramped
      Text(title).font(.system(size: 13, weight: .medium)).tracking(0.15)
      Spacer(minLength: 0)
    }
    .foregroundStyle(Palette.ink)
    .padding(.horizontal, SidebarMetrics.inset).frame(height: SidebarMetrics.actionRow)
    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
  }

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
      // full width, meeting the vertical rule on the right
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
        // Same entry points as appearance: a quick one here, the full one in Settings.
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

/// Several projects can be expanded at once; the list loads on expand, and browsing never creates
/// an empty conversation.
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
      // offscreen galleries use fixtures and must not start the user's backend
      if expanded && model.isLiveApp { await load() }
    }
  }

  /// same text start as conversation rows, so it reads as part of that level
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
      // Not Palette.selectedRow: its near-white fill looks pasted on over the tint. A slightly darker
      // hover tone, a filled dot and heavier text are enough.
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
