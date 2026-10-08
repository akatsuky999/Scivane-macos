import SwiftUI

/// Title, chevron and New Chat have separate hit areas; nested Buttons swallow clicks.
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

  /// With the title cut to one line the tooltip is the only place for the full title, so it comes
  /// first. Empty projects have no file name to show.
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
      // One line: paper titles run long, and two-line rows would leave room for three or four projects.
      // The opening words are what people recognise; the full title is in the tooltip.
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

/// Context menu: re-run OCR, replace with an upload, delete.
struct ProjectActions: View {
  @ObservedObject var model: AppModel
  let project: Project
  @Binding var renaming: Bool

  var body: some View {
    // the current project offers a way out rather than in
    if model.activeProjectID == project.id {
      Button(L("退出项目", "Leave Project")) { model.leaveProject() }
    } else {
      Button(L("进入项目", "Open Project")) { Task { await model.enterProject(project) } }
    }
    Button(L("重命名…", "Rename…")) { renaming = true }
    Divider()
    // An empty project has no source to recognise yet; offer to attach a PDF instead of two buttons
    // of which only one works.
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

/// Shown while the text awaits confirmation. An uploaded Markdown file may not be this paper, and
/// the model would answer confidently from the wrong text, so it is excluded from answers until
/// someone confirms it.
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
  /// without a trailing control
  init(model: AppModel, project: Project) {
    self.init(model: model, project: project, trailing: { EmptyView() })
  }
}
