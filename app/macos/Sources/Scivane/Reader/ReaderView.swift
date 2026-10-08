import SwiftUI

/// Reading workspace. No pane headers: identity, layout and mode live in the single toolbar, and the
/// page number floats over the PDF.
struct ReaderView: View {
  @ObservedObject var model: AppModel
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      // stays until someone answers
      if let project = model.activeProject, project.awaitsConfirmation {
        ContextConfirmBar(model: model, project: project)
      }
      if model.isSearching { searchBar }
      // draws nothing when idle
      OCRInstallCard(installer: model.ocrInstaller)
      if let source = model.readingSource, source.status != .ready && !source.status.isFinished {
        ScanProgressBar(job: source, onCancel: { model.cancelCurrent() }, onRetry: { model.retry(source) },
                        firstRun: model.ocrInstaller.freshlyInstalled)
      }
      if model.dualPane {
        HSplitView {
          // the agent gets most of the width; the source stays as a reference
          sourcePane.frame(minWidth: 240, idealWidth: model.textMode == .chat ? 360 : 460)
          textPane.frame(minWidth: 460, idealWidth: model.textMode == .chat ? 760 : 560)
        }
      } else {
        Group {
          if model.singlePane == .source { sourcePane } else { textPane }
        }
      }
    }
    .onChange(of: model.selection) { _, _ in
      model.searchQuery = ""
      model.runSearch()
    }
  }

  // MARK: - Source pane

  private var sourcePane: some View {
    ZStack(alignment: .bottom) {
      Group {
        if let job = model.readingSource {
          if job.isPDF {
            PDFReaderView(model: model, job: job)
          } else if let image = job.image {
            ImageReaderView(image: image)
          } else {
            ContentUnavailableView(L("无法预览原稿", "Can't Preview the Original"), systemImage: "doc.questionmark")
          }
        } else {
          emptyPane(.source)
        }
      }
      if let source = model.readingSource, source.isPDF, source.pageCount > 1 {
        PageCapsule(model: model, pageCount: source.pageCount).padding(.bottom, 16)
      }
    }
    .background(Palette.paper)
  }

  // MARK: - Text pane / agent
  //
  // Both stay in one ZStack and switch by opacity, not if/switch: leaving the tree would rebuild
  // the WKWebView, reload viewer.html, replay the whole paper and lose the scroll position.

  private var textPane: some View {
    ZStack {
      documentLayer
        .opacity(model.textMode == .document ? 1 : 0)
        .allowsHitTesting(model.textMode == .document)
        .accessibilityHidden(model.textMode != .document)
      AgentPane(model: model)
        .opacity(model.textMode == .chat ? 1 : 0)
        .allowsHitTesting(model.textMode == .chat)
        .accessibilityHidden(model.textMode != .chat)
    }
    .background(Palette.paper)
  }

  @ViewBuilder
  private var documentLayer: some View {
    if model.readingDocument != nil {
      MarkdownWebView(model: model, language: Localization.shared.language)
    } else {
      emptyPane(.text)
    }
  }

  // MARK: - Empty panes

  private var sourcelessProject: Project? {
    guard let project = model.activeProject, !project.hasSource else { return nil }
    return project
  }

  private func emptyPane(_ kind: AppModel.ReadingPane) -> some View {
    VStack(spacing: 12) {
      Image(systemName: kind == .source ? "doc" : "text.alignleft")
        .font(.system(size: 26, weight: .ultraLight)).foregroundStyle(Palette.accent.opacity(0.7))
      Text(kind == .source ? L("放入原稿", "Add the Original") : L("载入正文", "Load the Text"))
        .font(.system(size: 19, weight: .regular, design: .serif)).foregroundStyle(Palette.ink)
      Text(sourcelessProject != nil && kind == .source
        ? L("这个项目还没有原稿。导入之后它会用论文标题给项目命名。", "This project has no original yet. Once imported, the project takes the paper's title.")
        : (kind == .source ? L("PDF 或图片，导入后先预览。", "A PDF or image; it's previewed after import.") : L("导入 Markdown，或先识别左侧原稿。", "Import Markdown, or run OCR on the original on the left first.")))
        .font(.uiCaption).foregroundStyle(Palette.inkFaint).multilineTextAlignment(.center)
      Button(kind == .source ? L("导入 PDF", "Import PDF") : L("导入 Markdown", "Import Markdown")) {
        // In a project without a source, importing a PDF attaches it to the project rather than opening
        // a loose document.
        if kind == .source, let project = sourcelessProject {
          model.chooseSourceForProject(project)
        } else {
          model.openPanel(markdown: kind == .text)
        }
      }
      .buttonStyle(StudioButtonStyle(primary: kind == .source)).padding(.top, 4)
      if kind == .text, let source = model.readingSource, source.canStartOCR {
        Button(L("从原稿开始 OCR", "Start OCR from the Original")) { model.startOCR(source) }.buttonStyle(.borderless)
          .font(.uiCaption).foregroundStyle(Palette.accent)
      }
    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .dropDestination(for: URL.self) { urls, _ in
        let accepted = urls.filter {
          (["md", "markdown"].contains($0.pathExtension.lowercased())) == (kind == .text)
        }
        guard !accepted.isEmpty else { return false }
        model.add(urls: accepted, to: kind)
        return true
      }
  }

  private var searchBar: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass").foregroundStyle(Palette.inkFaint)
      TextField(L("查找正文…", "Find in text…"), text: $model.searchQuery).textFieldStyle(.plain).focused($searchFocused)
        .onChange(of: model.searchQuery) { _, _ in model.runSearch() }
      if !model.searchQuery.isEmpty {
        Text(L("\(model.searchHits) 处", plural(model.searchHits, "match", "matches"))).foregroundStyle(Palette.inkFaint)
      }
      Button {
        model.isSearching = false
        model.searchQuery = ""
        model.runSearch()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(ToolButtonStyle()).accessibilityLabel(L("关闭查找", "Close Find"))
    }.font(.uiBody).padding(.horizontal, 18).frame(height: 34).background(Palette.sunk)
      .onAppear { searchFocused = true }
  }
}

// MARK: - Floating page number
//
// Dim until hovered, as in Preview.

private struct PageCapsule: View {
  @ObservedObject var model: AppModel
  let pageCount: Int
  @State private var hovering = false
  @State private var draft = ""
  @FocusState private var editing: Bool

  var body: some View {
    HStack(spacing: 3) {
      step("chevron.left", enabled: model.currentPage > 1) { model.goToPage(model.currentPage - 1) }
      TextField("", text: $draft)
        .textFieldStyle(.plain).multilineTextAlignment(.center).focused($editing)
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .frame(width: max(18, CGFloat("\(pageCount)".count) * 9))
        .onSubmit {
          model.goToPage(Int(draft) ?? model.currentPage)
          draft = String(model.currentPage)
          editing = false
        }
        .accessibilityLabel(L("跳转页码", "Go to Page"))
      Text("/ \(pageCount)")
        .font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.inkFaint)
        .padding(.trailing, 2)
      step("chevron.right", enabled: model.currentPage < pageCount) { model.goToPage(model.currentPage + 1) }
    }
    .padding(.horizontal, 7).padding(.vertical, 5)
    .background(.regularMaterial, in: Capsule())
    .overlay(Capsule().strokeBorder(Palette.rule.opacity(hovering ? 1 : 0.5)))
    .shadow(color: .black.opacity(hovering ? 0.10 : 0.05), radius: hovering ? 9 : 4, y: 2)
    .opacity(hovering || editing ? 1 : 0.62)
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.15), value: hovering)
    .onAppear { draft = String(model.currentPage) }
    .onChange(of: model.currentPage) { _, page in if !editing { draft = String(page) } }
  }

  private func step(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 9, weight: .semibold))
        .frame(width: 20, height: 18)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain).disabled(!enabled)
    .foregroundStyle(enabled ? Palette.inkSoft : Palette.inkFaint.opacity(0.4))
    .accessibilityLabel(symbol == "chevron.left" ? L("上一页", "Previous Page") : L("下一页", "Next Page"))
  }
}

// MARK: - Segmented control
//
// The highlight slides: matchedGeometryEffect only animates inside withAnimation. A spring, for
// a little overshoot.

struct SegmentedTabs: View {
  struct Item: Identifiable, Equatable {
    let id: String
    let label: String
    let symbol: String
  }

  let items: [Item]
  @Binding var selection: String
  /// Icons only, text in the tooltip, for switches whose shape says it all (single / dual pane).
  /// Reuses this control so the slide and hover feel stay the same.
  var iconOnly = false
  @Namespace private var glide
  @State private var hovering: String?

  /// short response to track the pointer, 0.78 damping for a slight bounce
  private static let glideCurve = Animation.spring(response: 0.3, dampingFraction: 0.78)

  var body: some View {
    HStack(spacing: 1) {
      ForEach(items) { item in
        let active = item.id == selection
        Button {
          guard !active else { return }
          withAnimation(Self.glideCurve) { selection = item.id }
        } label: {
          HStack(spacing: 5) {
            Image(systemName: item.symbol).font(.system(size: iconOnly ? 11.5 : 10))
            if !iconOnly { Text(item.label) }
          }
          .font(.system(size: 11, weight: active ? .semibold : .regular))
          .foregroundStyle(active ? Palette.ink : Palette.inkFaint)
          .frame(minWidth: iconOnly ? 22 : 0)
          .padding(.horizontal, iconOnly ? 5 : 9).padding(.vertical, 4.5)
          .help(iconOnly ? item.label : "")
          .accessibilityLabel(item.label)

          .background {
            if active {
              // a single shape, interpolated between positions
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Palette.panel)
                .shadow(color: .black.opacity(0.07), radius: 2.5, y: 1)
                .matchedGeometryEffect(id: "slider", in: glide)
            } else if hovering == item.id {
              // light hover feedback on unselected items
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Palette.panel.opacity(0.4))
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
          withAnimation(.easeOut(duration: 0.12)) { hovering = inside ? item.id : nil }
        }
        .accessibilityAddTraits(active ? .isSelected : [])
      }
    }
    .padding(2).background(Palette.ruleSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

struct DocumentHeading: View {
  @ObservedObject var job: DocumentJob
  var body: some View {
    Text(job.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
      .lineLimit(1).truncationMode(.middle).help(job.url.path)
  }
}
