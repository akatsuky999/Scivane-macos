import SwiftUI

/// The sidebar's panel: search on top, then the open paper (or the library when none is open), and
/// the controls at the foot.
struct SidebarPanel: View {
  @ObservedObject var model: AppModel
  @ObservedObject var backend: BackendManager
  @ObservedObject var outline: DocumentOutline
  @ObservedObject var state: SidebarState
  @FocusState private var searchFocused: Bool

  private var query: String { state.query.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    VStack(spacing: 0) {
      search.padding(.horizontal, 12).padding(.bottom, 10)
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          if !query.isEmpty {
            SearchResults(model: model, outline: outline, query: query)
          } else if let project = model.activeProject {
            ProjectPanel(model: model, outline: outline, project: project)
          } else {
            LibraryPanel(model: model)
          }
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollIndicators(.never)
      SidebarControls(backend: backend).padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 2)
    }
    .onChange(of: state.focusRequest) { _, _ in searchFocused = true }
  }

  private var search: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Palette.inkFaint)
      TextField("", text: $state.query, prompt: Text(L("搜索论文与对话", "Search papers and chats")))
        .textFieldStyle(.plain).font(.system(size: 12))
        .focused($searchFocused)
        .onExitCommand { state.query = ""; searchFocused = false }
        .accessibilityLabel(L("搜索论文与对话", "Search papers and chats"))
      if state.query.isEmpty {
        Text("⌘K").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.inkFaint)
          .accessibilityHidden(true)
      } else {
        Button { state.query = "" } label: {
          Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.inkFaint)
        }
        .buttonStyle(.plain).accessibilityLabel(L("清除搜索", "Clear Search"))
      }
    }
    .padding(.horizontal, 11).frame(height: 30)
    // the cards' shape: on a capsule the faint edge only shows where it runs vertical, like brackets
    .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
      .strokeBorder(searchFocused ? Palette.accent.opacity(0.5) : Palette.cardEdge, lineWidth: 1))
  }
}

// MARK: - Cards

/// A titled group of rows on a card: chats, notes, outline, papers.
struct PanelCard<Trailing: View, Content: View>: View {
  let title: String
  var count: Int? = nil
  @ViewBuilder var trailing: () -> Trailing
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 6) {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkFaint)
          .accessibilityAddTraits(.isHeader)
        if let count, count > 0 {
          Text("\(count)").font(.uiMeta).foregroundStyle(Palette.inkFaint.opacity(0.8))
        }
        Spacer(minLength: 0)
        trailing()
      }
      .padding(.leading, 8).padding(.trailing, 2).frame(height: 26)
      content()
    }
    .padding(4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(radius: SidebarMetrics.card)
  }
}

extension PanelCard where Trailing == EmptyView {
  init(title: String, count: Int? = nil, @ViewBuilder content: @escaping () -> Content) {
    self.init(title: title, count: count, trailing: { EmptyView() }, content: content)
  }
}

/// A row in a card: an icon, a line of text, selected or hovered.
struct PanelRow: View {
  let symbol: String
  let title: String
  var trailing: String? = nil
  var selected = false
  var indent: CGFloat = 0
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: symbol).font(.system(size: 11))
          .foregroundStyle(selected ? Palette.accent : Palette.inkFaint)
          .frame(width: 14)
        Text(title)
          .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
          .foregroundStyle(selected ? Palette.accent : Palette.ink.opacity(0.88))
          .lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 4)
        if let trailing {
          Text(trailing).font(.uiMeta).foregroundStyle(Palette.inkFaint).lineLimit(1)
        }
      }
      .padding(.leading, 8 + indent).padding(.trailing, 8)
      .frame(height: SidebarMetrics.row)
      .background(
        RoundedRectangle(cornerRadius: SidebarMetrics.corner, style: .continuous)
          .fill(selected ? Palette.accent.opacity(0.12) : Palette.ink.opacity(hovering ? 0.045 : 0)))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// A one-line note inside a card (loading, empty, nothing found).
private struct PanelNote: View {
  let text: String
  var body: some View {
    Text(text).font(.system(size: 11.5)).foregroundStyle(Palette.inkFaint)
      .padding(.horizontal, 8).frame(height: 26, alignment: .leading)
  }
}

private func glyphButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
  Button(action: action) {
    Image(systemName: symbol).font(.system(size: 11, weight: .medium))
      .foregroundStyle(Palette.inkSoft)
      .frame(width: 22, height: 22).contentShape(Rectangle())
  }
  .buttonStyle(SidebarRowStyle())
  .help(help).accessibilityLabel(help)
}

// MARK: - The open paper

/// The open paper: its title and where its text came from, then its chats, its documents, and the
/// outline of the one in the text pane.
struct ProjectPanel: View {
  @ObservedObject var model: AppModel
  @ObservedObject var outline: DocumentOutline
  let project: Project
  @State private var renaming = false
  @State private var creatingChat = false
  @State private var loading = false
  @State private var loadFailed = false
  @State private var allNotes = false

  /// past this many notes the rest fold behind one row
  private static let notesShown = 5

  private var conversations: [Conversation] { model.conversations[project.id] ?? [] }
  private var notes: [ProjectNote] { model.projectNotes[project.id] ?? [] }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      chats
      documents
      contents
    }
    // offscreen galleries use fixtures and must not start the user's backend
    .task(id: project.id) {
      guard model.isLiveApp else { return }
      if model.conversations[project.id] == nil {
        loading = true
        loadFailed = !(await model.refreshConversations(project.id))
        loading = false
      }
      await model.refreshProjectNotes(project.id)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(project.displayTitle)
        .font(.system(size: 15, weight: .semibold, design: .serif))
        .foregroundStyle(Palette.ink)
        .lineLimit(5).fixedSize(horizontal: false, vertical: true)
        .help(project.tooltip)
        .contextMenu { ProjectActions(model: model, project: project, renaming: $renaming) }
        .projectRename(model: model, project: project, isPresented: $renaming)
        .accessibilityAddTraits(.isHeader)
      HStack(spacing: 5) {
        chip(project.summaryLine).help(project.hasUsableContext ? project.context?.originLabel ?? "" : "")
        if project.hasUsableContext, let chars = project.context?.chars, chars > 0 {
          chip(Project.lengthLabel(chars))
        }
      }
    }
    .padding(.horizontal, 4).padding(.top, 2)
  }

  private func chip(_ text: String) -> some View {
    Text(text).font(.system(size: 10.5)).foregroundStyle(Palette.inkSoft)
      .padding(.horizontal, 7).frame(height: 20)
      .background(Palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  private var chats: some View {
    PanelCard(title: L("对话", "Chats"), count: conversations.count) {
      glyphButton("plus", L("新对话", "New Chat")) {
        Task {
          creatingChat = true
          defer { creatingChat = false }
          await model.newConversation(in: project)
        }
      }
      .disabled(creatingChat || model.projectBusy || model.sidebarNavigationBusy)
      .accessibilityIdentifier("project-new-chat-\(project.id)")
    } content: {
      ForEach(conversations) { conversation in
        SidebarConversationRow(model: model, project: project, conversation: conversation)
      }
      if conversations.isEmpty {
        if loading {
          PanelNote(text: L("正在载入…", "Loading…"))
        } else if loadFailed {
          Button {
            Task {
              loading = true
              loadFailed = !(await model.refreshConversations(project.id))
              loading = false
            }
          } label: { PanelNote(text: L("载入失败 · 重试", "Couldn't load · Retry")) }
            .buttonStyle(.plain)
        } else {
          PanelNote(text: L("还没有对话", "No chats yet"))
        }
      }
    }
  }

  /// What the text pane can show: the paper text, or a note. Showing a note never changes what the
  /// model reads.
  private var documents: some View {
    let shown = model.projectDocument[project.id]
    let visible = allNotes ? notes : Array(notes.prefix(Self.notesShown))
    return PanelCard(title: L("正文与笔记", "Text & Notes"), count: notes.count) {
      HStack(spacing: 0) {
        glyphButton("square.and.arrow.down", L("导入 Markdown…", "Import Markdown…")) {
          model.chooseMarkdownToView()
        }
        glyphButton("folder", L("在 Finder 中显示 notes/", "Show notes/ in Finder")) {
          model.revealProjectNotes()
        }
      }
    } content: {
      PanelRow(symbol: "book.pages", title: L("论文正文", "Paper Text"),
               selected: shown == nil && project.hasUsableContext) { model.showProjectText(nil) }
        .disabled(!project.hasUsableContext)
      ForEach(visible) { note in
        PanelRow(symbol: "doc.text", title: note.title,
                 trailing: NotesShelf.relative(note.modified), selected: shown == note.path) {
          model.showProjectText(note.path)
        }
        .help(note.path)
      }
      if notes.count > Self.notesShown {
        Button { allNotes.toggle() } label: {
          PanelNote(text: allNotes ? L("收起", "Show Less")
                                   : L("其余 \(notes.count - Self.notesShown) 份…",
                                       "\(notes.count - Self.notesShown) more…"))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
  }

  /// The outline of the document in the text pane, with the heading being read.
  @ViewBuilder
  private var contents: some View {
    let entries = outline.entries(for: model.readingDocument?.id)
    if !entries.isEmpty {
      let top = entries.map(\.level).min() ?? 1
      PanelCard(title: L("目录", "Outline"), count: nil) {
        ForEach(entries) { entry in
          OutlineRow(entry: entry, indent: CGFloat(entry.level - top) * 11,
                     current: outline.current == entry.id) { model.showOutlineEntry(entry.id) }
        }
      }
    }
  }
}

private struct OutlineRow: View {
  let entry: DocumentOutline.Entry
  let indent: CGFloat
  let current: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 7) {
        Circle().fill(current ? Palette.accent : .clear).frame(width: 4, height: 4)
        Text(entry.title)
          .font(.system(size: 12, weight: current ? .semibold : .regular))
          .foregroundStyle(current ? Palette.ink : Palette.inkSoft)
          .lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 0)
      }
      .padding(.leading, 6 + indent).padding(.trailing, 8)
      .frame(height: 25)
      .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Palette.ink.opacity(hovering ? 0.045 : 0)))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(entry.title)
    .accessibilityAddTraits(current ? .isSelected : [])
  }
}

/// A chat of the open paper. Selecting it opens it in the agent pane.
struct SidebarConversationRow: View {
  @ObservedObject var model: AppModel
  let project: Project
  let conversation: Conversation
  @State private var renaming = false
  @State private var draftTitle = ""
  @State private var hovering = false

  private var isCurrent: Bool {
    model.activeProjectID == project.id && model.activeConversation[project.id] == conversation.id
  }

  var body: some View {
    Button {
      Task { await model.openConversation(project: project, conversation: conversation.id) }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: isCurrent ? "bubble.left.fill" : "bubble.left")
          .font(.system(size: 10.5))
          .foregroundStyle(isCurrent ? Palette.accent : Palette.inkFaint)
          .frame(width: 14)
        Text(conversation.displayTitle)
          .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
          .foregroundStyle(isCurrent ? Palette.accent : Palette.ink.opacity(0.88))
          .lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .frame(height: SidebarMetrics.row)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: SidebarMetrics.corner, style: .continuous)
          .fill(isCurrent ? Palette.accent.opacity(0.12) : Palette.ink.opacity(hovering ? 0.045 : 0)))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
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

// MARK: - The library

/// No paper open: every paper with its title, and the documents opened this session without a project.
struct LibraryPanel: View {
  @ObservedObject var model: AppModel

  private var looseJobs: [DocumentJob] { model.jobs.filter { model.jobProjects[$0.id] == nil } }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text(L("书房", "Library"))
          .font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(Palette.ink)
          .accessibilityAddTraits(.isHeader)
        Text(L("\(model.projects.count) 篇论文", plural(model.projects.count, "paper", "papers")))
          .font(.system(size: 11)).foregroundStyle(Palette.inkFaint)
      }
      .padding(.horizontal, 4).padding(.top, 2)

      PanelCard(title: L("论文", "Papers"), count: model.projects.count) {
        NewPaperMenu(model: model) {
          Image(systemName: "plus").font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.inkSoft)
            .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .help(L("新建项目或导入文档", "New Project or Import Document"))
        .accessibilityLabel(L("新建项目或导入文档", "New Project or Import Document"))
      } content: {
        ForEach(model.projects) { PaperRow(model: model, project: $0) }
        if model.projects.isEmpty { PanelNote(text: L("还没有论文", "No papers yet")) }
      }

      if !looseJobs.isEmpty {
        PanelCard(title: L("本次文档", "This Session"), count: looseJobs.count) {
          ForEach(looseJobs) { SidebarDocument(model: model, job: $0) }
        }
      }
    }
  }
}

// MARK: - Search

/// Matches across the papers, and within the open one its chats, notes and headings.
private struct SearchResults: View {
  @ObservedObject var model: AppModel
  @ObservedObject var outline: DocumentOutline
  let query: String

  var body: some View {
    let papers = model.projects.filter { $0.displayTitle.localizedStandardContains(query) }
    let project = model.activeProject
    let chats = project.map { p in (model.conversations[p.id] ?? []).filter { $0.displayTitle.localizedStandardContains(query) } } ?? []
    let notes = project.map { p in (model.projectNotes[p.id] ?? []).filter {
      $0.title.localizedStandardContains(query) || $0.folder.localizedStandardContains(query) } } ?? []
    let headings = outline.entries(for: model.readingDocument?.id).filter { $0.title.localizedStandardContains(query) }
    let loose = model.jobs.filter { model.jobProjects[$0.id] == nil && $0.title.localizedStandardContains(query) }

    VStack(alignment: .leading, spacing: 10) {
      if let project, !chats.isEmpty {
        PanelCard(title: L("对话", "Chats"), count: chats.count) {
          ForEach(chats) { SidebarConversationRow(model: model, project: project, conversation: $0) }
        }
      }
      if !notes.isEmpty {
        PanelCard(title: L("笔记", "Notes"), count: notes.count) {
          ForEach(notes) { note in
            PanelRow(symbol: "doc.text", title: note.title,
                     selected: project.map { model.projectDocument[$0.id] == note.path } ?? false) {
              model.showProjectText(note.path)
            }
          }
        }
      }
      if !headings.isEmpty {
        PanelCard(title: L("目录", "Outline"), count: headings.count) {
          ForEach(headings) { entry in
            PanelRow(symbol: "list.bullet.indent", title: entry.title,
                     selected: outline.current == entry.id) { model.showOutlineEntry(entry.id) }
          }
        }
      }
      if !papers.isEmpty {
        PanelCard(title: L("论文", "Papers"), count: papers.count) {
          ForEach(papers) { PaperRow(model: model, project: $0) }
        }
      }
      if !loose.isEmpty {
        PanelCard(title: L("本次文档", "This Session"), count: loose.count) {
          ForEach(loose) { SidebarDocument(model: model, job: $0) }
        }
      }
      if chats.isEmpty && notes.isEmpty && headings.isEmpty && papers.isEmpty && loose.isEmpty {
        PanelNote(text: L("没有找到「\(query)」", "Nothing matches “\(query)”"))
      }
    }
  }
}

extension Project {
  /// The paper text's length: "16.1 万字" / "161K chars".
  static func lengthLabel(_ chars: Int) -> String {
    let thousands = Int((Double(chars) / 1_000).rounded())
    if chars >= 10_000 {
      let tenThousands = String(format: "%.1f", Double(chars) / 10_000)
      return L("\(tenThousands) 万字", "\(thousands)K chars")
    }
    return chars >= 1_000 ? L("\(chars) 字", "\(thousands)K chars") : L("\(chars) 字", "\(chars) chars")
  }
}
