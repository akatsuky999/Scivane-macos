import SwiftUI

/// 项目标题、折叠箭头与新对话入口各有独立点击区，避免 Button 嵌套吞点击。
struct ProjectRow<Trailing: View>: View {
  @ObservedObject var model: AppModel
  let project: Project
  var expanded = false
  var toggleExpanded: (() -> Void)? = nil
  @ViewBuilder var trailing: () -> Trailing
  @State private var hovering = false
  @State private var renaming = false
  @State private var draftTitle = ""

  private var isActive: Bool { model.activeProjectID == project.id }

  /// 悬停提示。标题被截断成一行之后，**完整标题只剩这一个出口**，
  /// 所以它排在原文件名前面。没有原稿的空项目就不提文件名。
  private var tooltip: String {
    project.sourceName.isEmpty ? project.displayTitle : "\(project.displayTitle)\n\(project.sourceName)"
  }

  var body: some View {
    HStack(spacing: 0) {
      if let toggleExpanded {
        Button(action: toggleExpanded) {
          Image(systemName: "chevron.right")
            .font(.system(size: 8.5, weight: .semibold))
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .frame(width: SidebarMetrics.disclosure, height: SidebarMetrics.treeRow).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Palette.inkFaint)
        .help(expanded ? L("收起对话", "Collapse Chats") : L("展开对话", "Expand Chats"))
        .accessibilityLabel(expanded ? L("收起项目 \(project.displayTitle)", "Collapse project \(project.displayTitle)") : L("展开项目 \(project.displayTitle)", "Expand project \(project.displayTitle)"))
        .accessibilityIdentifier("project-disclosure-\(project.id)")
        .accessibilityValue(expanded ? L("已展开", "Expanded") : L("已收起", "Collapsed"))
      }
      row
      trailing().padding(.trailing, 2)
    }
    .background(Palette.ink.opacity(hovering ? 0.05 : 0),
                in: RoundedRectangle(cornerRadius: SidebarMetrics.corner))
    .onHover { hovering = $0 }
  }

  private var row: some View {
    Button {
      Task {
        guard !model.sidebarNavigationBusy else { return }
        model.sidebarNavigationBusy = true
        defer { model.sidebarNavigationBusy = false }
        await model.enterProject(project)
      }
    } label: {
      // **一行装完。** 论文标题动辄二三十字，两行的行高会让侧栏一屏只剩三四个
      // 项目；而真正帮人认出是哪一篇的是开头那几个词。完整标题在 tooltip 里。
      //
      // 未确认正文仍保留提醒；完整状态放在工作区里，避免与对话导航争抢宽度。
      HStack(spacing: 6) {
        Text(project.displayTitle)
          .font(.system(size: 12, weight: .medium))
          .lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 6)
        if project.awaitsConfirmation {
          Image(systemName: "exclamationmark.circle").font(.system(size: 11))
            .foregroundStyle(ActivityCard.amber)
            .help(L("正文待确认", "Text awaiting confirmation"))
        }
      }.foregroundStyle(isActive ? Palette.ink : Palette.inkSoft)
        .padding(.leading, toggleExpanded == nil ? SidebarMetrics.inset : 0).padding(.trailing, 4)
        .frame(height: SidebarMetrics.treeRow).frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(model.sidebarNavigationBusy || model.projectBusy)
    .accessibilityIdentifier("project-open-\(project.id)")
    .help(tooltip)
    .contextMenu { ProjectActions(model: model, project: project, renaming: $renaming) }
    .accessibilityAddTraits(isActive ? .isSelected : [])
    .alert(L("重命名项目", "Rename Project"), isPresented: $renaming) {
      TextField(L("标题", "Title"), text: $draftTitle)
      Button(L("保存", "Save")) {
        let title = draftTitle
        Task { await model.renameProject(project, to: title) }
      }
      Button(L("取消", "Cancel"), role: .cancel) {}
    } message: {
      Text(L("改过的名字不会被后续识别覆盖。", "A name you set won't be overwritten by later OCR."))
    }
    .onChange(of: renaming) { _, active in
      if active { draftTitle = project.displayTitle }
    }
  }
}

/// 项目的右键菜单。覆盖需求里的三条：重新 OCR 覆盖、上传文件覆盖、删除。
struct ProjectActions: View {
  @ObservedObject var model: AppModel
  let project: Project
  @Binding var renaming: Bool

  var body: some View {
    // 当前项目给的是出口而不是入口 —— 已经在里面了，再摆一个「进入项目」没用。
    if model.activeProjectID == project.id {
      Button(L("退出项目", "Leave Project")) { model.leaveProject() }
    } else {
      Button(L("进入项目", "Open Project")) { Task { await model.enterProject(project) } }
    }
    Button(L("重命名…", "Rename…")) { renaming = true }
    Divider()
    // 空项目还没有原稿，「识别」无从谈起 —— 先给它一份 PDF。
    // 两件事互斥，所以不并排摆两个按钮让用户自己判断哪个能点。
    if project.hasSource {
      Button(project.context == nil ? L("开始识别原稿", "Run OCR on the Original") : L("重新识别并覆盖正文", "Re-run OCR and Replace the Text")) {
        Task {
          await model.enterProject(project)
          model.reOCRActiveProject()
        }
      }
    } else {
      Button(L("导入 PDF 作为原稿…", "Import a PDF as the Original…")) { model.chooseSourceForProject(project) }
    }
    Button(L("导入 Markdown 覆盖正文…", "Import Markdown to Replace the Text…")) {
      Task { await model.enterProject(project) }
      model.chooseMarkdownForProject(project)
    }
    Divider()
    Button(L("在 Finder 中显示项目", "Show Project in Finder")) {
      NSWorkspace.shared.activateFileViewerSelecting([project.directoryURL])
    }
    Divider()
    Button(L("删除项目…", "Delete Project…"), role: .destructive) {
      Task { await model.deleteProject(project) }
    }
  }
}

/// 待确认的正文提示条。
///
/// 上传进来的 Markdown 未必真是这篇论文 —— 万一不是，模型会一本正经地
/// 基于错误材料作答，而用户不会察觉。所以在人点头之前，它不参与问答，
/// 并且界面上一直挂着这条提示。
struct ContextConfirmBar: View {
  @ObservedObject var model: AppModel
  let project: Project

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "questionmark.circle.fill")
        .font(.system(size: 12)).foregroundStyle(Palette.accent)
      VStack(alignment: .leading, spacing: 2) {
        Text(L("这份 Markdown 是「\(project.displayTitle)」的正文吗？", "Is this Markdown the text of “\(project.displayTitle)”?"))
          .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.ink)
        Text(L("确认后它才会参与问答", "It's used for questions only after you confirm"))
          .font(.system(size: 10)).foregroundStyle(Palette.inkFaint)
      }
      Spacer(minLength: 8)
      Button(L("撤销", "Withdraw")) { Task { await model.confirmProjectContext(false) } }
        .buttonStyle(StudioButtonStyle())
      Button(L("确认使用", "Confirm")) { Task { await model.confirmProjectContext(true) } }
        .buttonStyle(StudioButtonStyle(primary: true))
    }
    .padding(.horizontal, 14).padding(.vertical, 9)
    .background(Palette.accent.opacity(0.07))
    .overlay(alignment: .bottom) { Hairline() }
  }
}

extension ProjectRow where Trailing == EmptyView {
  /// 不挂右端控件的那种用法。
  init(model: AppModel, project: Project) {
    self.init(model: model, project: project, trailing: { EmptyView() })
  }
}
