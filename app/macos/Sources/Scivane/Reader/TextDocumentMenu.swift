import SwiftUI

/// What the text pane shows inside a project: the paper text, or a Markdown file kept in files/.
/// Showing a file never changes what the model reads; that takes the text chip in the chat.
/// Dim until hovered, like the page number over the PDF.
struct TextDocumentMenu: View {
  @ObservedObject var model: AppModel
  let project: Project
  @State private var hovering = false

  private var files: [ProjectFile] {
    (model.projectFiles[project.id] ?? []).filter {
      ["md", "markdown"].contains(($0.name as NSString).pathExtension.lowercased())
    }
  }

  private var current: String? { model.projectDocument[project.id] }

  var body: some View {
    Menu {
      Button {
        model.showProjectText(nil)
      } label: {
        Label(L("论文正文", "Paper Text"), systemImage: current == nil ? "checkmark" : "")
      }
      .disabled(!project.hasUsableContext)
      if !files.isEmpty {
        Divider()
        ForEach(files) { file in
          Button {
            model.showProjectText(file.path)
          } label: {
            Label(file.name, systemImage: current == file.path ? "checkmark" : "")
          }
        }
      }
      Divider()
      Button(L("打开 Markdown…", "Open Markdown…")) { model.chooseMarkdownToView() }
    } label: {
      HStack(spacing: 5) {
        Image(systemName: current == nil ? "doc.text" : "doc.plaintext").font(.system(size: 9.5))
        Text(title).lineLimit(1).truncationMode(.middle)
        Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
      }
      .font(.system(size: 11)).foregroundStyle(Palette.inkSoft)
      .padding(.horizontal, 9).padding(.vertical, 4.5)
      .background(.regularMaterial, in: Capsule())
      .overlay(Capsule().strokeBorder(Palette.rule.opacity(hovering ? 1 : 0.5)))
      .contentShape(Capsule())
    }
    // the native menu style would drop the capsule, which is what keeps the label legible over text
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    .frame(maxWidth: 260, alignment: .trailing)
    .fixedSize(horizontal: true, vertical: false)
    .opacity(hovering ? 1 : 0.72)
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.15), value: hovering)
    .help(L("正文栏显示的文档", "Document shown in the text pane"))
    .accessibilityIdentifier("text-document-menu")
    .task(id: project.id) { await model.refreshProjectFiles(project.id) }
  }

  private var title: String {
    guard let current else { return L("论文正文", "Paper Text") }
    return (current as NSString).lastPathComponent
  }
}
