import SwiftUI

/// A paper in the library list: its glyph, its title over two lines, where its text came from.
/// Entering it is the row; recognising, renaming, revealing and deleting are in its context menu.
struct PaperRow: View {
  @ObservedObject var model: AppModel
  let project: Project
  @State private var hovering = false
  @State private var renaming = false

  var body: some View {
    Button { Task { await model.enterProjectFromSidebar(project) } } label: {
      HStack(alignment: .top, spacing: 10) {
        PaperGlyph(title: project.displayTitle, size: CGSize(width: 24, height: 30))
        VStack(alignment: .leading, spacing: 2) {
          Text(project.displayTitle)
            .font(.system(size: 12.5, weight: .medium, design: .serif))
            .foregroundStyle(Palette.ink)
            .lineLimit(2).multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
          Text(project.summaryLine)
            .font(.system(size: 10.5)).foregroundStyle(Palette.inkFaint).lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8).padding(.vertical, 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Palette.ink.opacity(hovering ? 0.045 : 0),
                  in: RoundedRectangle(cornerRadius: SidebarMetrics.corner, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .disabled(model.sidebarNavigationBusy || model.projectBusy)
    .help(project.tooltip)
    .contextMenu { ProjectActions(model: model, project: project, renaming: $renaming) }
    .projectRename(model: model, project: project, isPresented: $renaming)
    .accessibilityLabel(project.displayTitle)
    .accessibilityIdentifier("project-open-\(project.id)")
  }
}

extension Project {
  /// Where the paper's text came from, or that there is none yet; one line under its title.
  var summaryLine: String {
    if !hasSource && !hasUsableContext { return L("空项目", "Empty project") }
    guard hasUsableContext, let context else { return L("还没有正文", "No text yet") }
    return context.kindLabel
  }

  /// the full title, the original's file name and, for a transcription, the model that made it
  var tooltip: String {
    var lines = [displayTitle]
    if !sourceName.isEmpty { lines.append(sourceName) }
    if hasUsableContext, let context, context.origin == "model", let model = context.model { lines.append(model) }
    return lines.joined(separator: "\n")
  }
}

extension AppModel {
  /// Enter a project from the sidebar, once: a second click while the first is on its way is ignored.
  func enterProjectFromSidebar(_ project: Project) async {
    guard !sidebarNavigationBusy else { return }
    sidebarNavigationBusy = true
    defer { sidebarNavigationBusy = false }
    await enterProject(project)
  }
}

/// Context menu: recognise the source, reveal, delete. Replacing the text with a Markdown file
/// lives on the text chip in the chat, the one place that changes it.
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
      Button(L("识别原稿…", "Recognize Original…")) {
        Task {
          await model.enterProject(project)
          model.reOCRActiveProject()
        }
      }
    } else {
      Button(L("导入 PDF 作为原稿…", "Import a PDF as the Original…")) { model.chooseSourceForProject(project) }
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

/// The rename prompt shared by every place a project can be renamed from.
private struct ProjectRename: ViewModifier {
  @ObservedObject var model: AppModel
  let project: Project
  @Binding var isPresented: Bool
  @State private var draft = ""

  func body(content: Content) -> some View {
    content
      .alert(L("重命名项目", "Rename Project"), isPresented: $isPresented) {
        TextField(L("标题", "Title"), text: $draft)
        Button(L("保存", "Save")) {
          let title = draft
          Task { await model.renameProject(project, to: title) }
        }
        Button(L("取消", "Cancel"), role: .cancel) {}
      } message: {
        Text(L("改过的名字不会被后续识别覆盖。", "A name you set won't be overwritten by later OCR."))
      }
      .onChange(of: isPresented) { _, active in
        if active { draft = project.displayTitle }
      }
  }
}

extension View {
  func projectRename(model: AppModel, project: Project, isPresented: Binding<Bool>) -> some View {
    modifier(ProjectRename(model: model, project: project, isPresented: isPresented))
  }
}
