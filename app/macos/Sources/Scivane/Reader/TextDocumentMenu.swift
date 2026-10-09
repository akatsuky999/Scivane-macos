import SwiftUI

/// What the text pane shows inside a project: the paper text, or a Markdown document from notes/,
/// imported by the user or written by the agent. Showing a note never changes what the model reads;
/// that takes the text chip in the chat. Dim until hovered, like the page number over the PDF.
struct TextDocumentMenu: View {
  @ObservedObject var model: AppModel
  let project: Project
  @State private var hovering = false
  @State private var open = false

  private var current: String? { model.projectDocument[project.id] }

  var body: some View {
    Button { open.toggle() } label: {
      HStack(spacing: 5) {
        Image(systemName: current == nil ? "doc.text" : "doc.plaintext").font(.system(size: 9.5))
        Text(title).lineLimit(1).truncationMode(.middle)
        Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
      }
      .font(.system(size: 11)).foregroundStyle(Palette.inkSoft)
      .padding(.horizontal, 9).padding(.vertical, 4.5)
      // the material is what keeps the label legible over text
      .background(.regularMaterial, in: Capsule())
      .overlay(Capsule().strokeBorder(Palette.rule.opacity(hovering || open ? 1 : 0.5)))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .frame(maxWidth: 260, alignment: .trailing)
    .fixedSize(horizontal: true, vertical: false)
    .opacity(hovering || open ? 1 : 0.72)
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.15), value: hovering)
    .help(L("正文栏显示的文档", "Document shown in the text pane"))
    .accessibilityIdentifier("text-document-menu")
    .popover(isPresented: $open, arrowEdge: .bottom) {
      NotesShelf(model: model, project: project) { open = false }
    }
    .task(id: project.id) { await model.refreshProjectNotes(project.id) }
  }

  private var title: String {
    guard let current else { return L("论文正文", "Paper Text") }
    return ((current as NSString).lastPathComponent as NSString).deletingPathExtension
  }
}

/// The paper text, then every note in notes/, newest first; importing and the folder below.
struct NotesShelf: View {
  @ObservedObject var model: AppModel
  let project: Project
  let dismiss: () -> Void
  @State private var query = ""
  @State private var hovered: String?

  /// past this many a filter field appears; fewer are found by eye faster
  private static let filterThreshold = 8

  private var notes: [ProjectNote] { model.projectNotes[project.id] ?? [] }
  private var current: String? { model.projectDocument[project.id] }

  private var shown: [ProjectNote] {
    let needle = query.trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else { return notes }
    return notes.filter {
      $0.title.localizedCaseInsensitiveContains(needle)
        || $0.folder.localizedCaseInsensitiveContains(needle)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      paperRow
      Hairline().padding(.vertical, 6)
      HStack {
        Text(L("笔记", "Notes")).font(.system(size: 10.5, weight: .semibold))
          .foregroundStyle(Palette.inkFaint)
        Spacer()
        if !notes.isEmpty {
          Text("\(notes.count)").font(.uiMeta).foregroundStyle(Palette.inkFaint)
        }
      }
      .padding(.horizontal, 10).padding(.bottom, 4)
      if notes.count > Self.filterThreshold { filterField }
      if shown.isEmpty {
        Text(notes.isEmpty ? L("notes/ 里还没有 Markdown", "No Markdown in notes/ yet")
                           : L("没有匹配的笔记", "No matching notes"))
          .font(.uiCaption).foregroundStyle(Palette.inkFaint)
          .padding(.horizontal, 10).padding(.vertical, 8)
      } else {
        ScrollView {
          VStack(spacing: 1) {
            ForEach(shown) { row($0) }
          }
        }
        .frame(maxHeight: 340)
        .fixedSize(horizontal: false, vertical: true)
      }
      Hairline().padding(.vertical, 6)
      HStack(spacing: 6) {
        Button {
          dismiss()
          model.chooseMarkdownToView()
        } label: {
          Label(L("导入 Markdown…", "Import Markdown…"), systemImage: "square.and.arrow.down")
            .font(.system(size: 12)).foregroundStyle(Palette.ink)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("import-note")
        Spacer()
        Button { model.revealProjectNotes() } label: {
          Image(systemName: "folder").font(.system(size: 11.5)).foregroundStyle(Palette.inkSoft)
            .frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("在 Finder 中显示 notes/", "Show notes/ in Finder"))
        .accessibilityLabel(L("在 Finder 中显示 notes/", "Show notes/ in Finder"))
      }
    }
    .padding(8)
    .frame(width: 304)
    .task { await model.refreshProjectNotes(project.id) }
  }

  private var paperRow: some View {
    let usable = project.hasUsableContext
    return choice(
      id: "paper", symbol: "book.pages", title: L("论文正文", "Paper Text"),
      detail: usable ? project.context?.originLabel ?? "" : L("还没有正文", "No text yet"),
      trailing: nil, selected: current == nil && usable
    ) { model.showProjectText(nil) }
    .disabled(!usable)
  }

  private func row(_ note: ProjectNote) -> some View {
    choice(
      id: note.id, symbol: "doc.text", title: note.title, detail: note.folder,
      trailing: Self.relative(note.modified), selected: current == note.path
    ) { model.showProjectText(note.path) }
    .help(note.path)
  }

  private func choice(
    id: String, symbol: String, title: String, detail: String, trailing: String?,
    selected: Bool, action: @escaping () -> Void
  ) -> some View {
    Button {
      action()
      dismiss()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: symbol).font(.system(size: 11))
          .foregroundStyle(selected ? Palette.accent : Palette.inkFaint)
          .frame(width: 15)
        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
            .foregroundStyle(Palette.ink)
            .lineLimit(1).truncationMode(.middle)
          if !detail.isEmpty {
            Text(detail).font(.system(size: 10.5)).foregroundStyle(Palette.inkFaint)
              .lineLimit(1).truncationMode(.head)
          }
        }
        Spacer(minLength: 8)
        if let trailing {
          Text(trailing).font(.uiMeta).foregroundStyle(Palette.inkFaint).lineLimit(1)
        }
        Image(systemName: "checkmark").font(.system(size: 9.5, weight: .semibold))
          .foregroundStyle(Palette.accent)
          .opacity(selected ? 1 : 0)
      }
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(hovered == id ? Palette.ruleSoft : .clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { inside in
      if inside { hovered = id } else if hovered == id { hovered = nil }
    }
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var filterField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").font(.system(size: 10.5)).foregroundStyle(Palette.inkFaint)
      TextField(L("筛选笔记", "Filter notes"), text: $query)
        .textFieldStyle(.plain).font(.system(size: 12))
    }
    .padding(.horizontal, 9).padding(.vertical, 5)
    .background(Palette.sunk, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    .padding(.horizontal, 4).padding(.bottom, 6)
  }

  /// "3 minutes ago" in the interface language, computed when drawn, never stored
  static func relative(_ date: Date, now: Date = Date()) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    formatter.dateTimeStyle = .named
    formatter.locale = Localization.shared.language.locale
    return formatter.localizedString(for: min(date, now), relativeTo: now)
  }
}
