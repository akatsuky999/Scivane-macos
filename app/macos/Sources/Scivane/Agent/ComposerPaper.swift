import SwiftUI

/// The paper reference also owns the existing, confirmed ways to replace its text.
struct ComposerPaper: View {
  @ObservedObject var model: AppModel
  let project: Project
  let locked: Bool

  private var notes: [ProjectNote] { model.projectNotes[project.id] ?? [] }

  var body: some View {
    Menu {
      if project.hasSource {
        Button(project.hasUsableContext ? L("重新识别…", "Recognize Again…") : L("识别原稿…", "Recognize Original…")) {
          model.reOCRActiveProject()
        }
      }
      Menu(L("替换为 Markdown", "Replace with Markdown")) {
        ForEach(notes) { note in
          Button(note.folder.isEmpty ? note.title : "\(note.folder)/\(note.title)") {
            let url = project.directoryURL.appendingPathComponent(note.path)
            Task { await model.replaceProjectContext(with: url) }
          }
        }
        if !notes.isEmpty { Divider() }
        Button(L("其他文件…", "Other File…")) { model.chooseMarkdownToReplaceContext() }
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "bookmark.fill")
          .font(.system(size: 11)).foregroundStyle(Palette.accent)
        Text(project.displayTitle)
          .font(.system(size: 12.5, weight: .medium, design: .serif))
          .foregroundStyle(Palette.inkSoft)
          .lineLimit(1).truncationMode(.tail)
        if project.hasUsableContext, let context = project.context {
          Text(sourceTag(context))
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.rule, lineWidth: 1))
            .fixedSize()
        }
        Text(sizeLabel).font(.system(size: 11)).monospacedDigit().fixedSize()
      }
      .foregroundStyle(Palette.inkFaint)
      .padding(.horizontal, 6).frame(height: 28)
      .composerControl()
    }
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    .disabled(locked || model.projectBusy)
    .help(help)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(L("论文正文：\(project.displayTitle)", "Paper text: \(project.displayTitle)"))
    .accessibilityIdentifier("context-chip")
  }

  private func sourceTag(_ context: ProjectContext) -> String {
    switch context.origin {
    case "ocr": return "OCR"
    case "model": return L("模型", "Model")
    default: return "MD"
    }
  }

  private var sizeLabel: String {
    guard let context = project.context, project.hasUsableContext else { return L("尚无正文", "No text") }
    let tokens = context.tokens
    return tokens >= 1_000_000 ? String(format: "%.1fM", Double(tokens) / 1_000_000)
      : (tokens >= 1_000 ? String(format: "%.1fK", Double(tokens) / 1_000) : "\(tokens)")
  }

  private var help: String {
    guard let context = project.context, project.hasUsableContext else { return project.displayTitle }
    return "\(project.displayTitle)\n" + L("正文来自：\(context.originLabel)", "Text from: \(context.originLabel)")
      + "\n" + context.sizeLabel
  }
}
