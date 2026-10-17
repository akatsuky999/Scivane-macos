import SwiftUI

struct ContentView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var backend: BackendManager
  @State private var isTargeted = false
  @AppStorage("sidebarVisible") private var sidebarVisible = true
  @AppStorage("sidebarOverlaysContent") private var sidebarOverlaysContent = true
  @State private var documentQuery = ""
  @State private var creatingProject = false
  @State private var newProjectTitle = ""
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 0) {
      // Keep one reader subtree in both modes; overlaying changes no reading geometry.
      Color.clear.frame(width: sidebarOverlaysContent || !sidebarVisible
        ? SidebarMetrics.collapsedWidth : SidebarMetrics.width)
        .allowsHitTesting(false).accessibilityHidden(true)
      VStack(spacing: 0) {
        ToolbarIsland(model: model, leading: toolbarLeading)
        ZStack {
          ReaderView(model: model, split: model.split)
          if isTargeted { DropHighlight() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }.background(Palette.paper)
    }
    .background(Palette.paper)
    .overlay(alignment: .leading) {
      SidebarView(model: model, backend: backend)
    }
    .overlay(alignment: .bottom) {
      if let notice = model.notice {
        Label(notice, systemImage: "checkmark.circle.fill")
          .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
          .padding(.horizontal, 14).padding(.vertical, 10)
          .background(.regularMaterial, in: Capsule())
          .overlay(Capsule().strokeBorder(Palette.rule))
          .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
          .padding(.bottom, 58).allowsHitTesting(false)
      }
    }
    .sheet(item: $model.recognitionRequest) { request in
      if let job = model.jobs.first(where: { $0.id == request.job }) {
        RecognitionSheet(
          model: model, installer: model.ocrInstaller, job: job,
          replacesText: model.jobProjects[job.id].flatMap { id in
            model.projects.first { $0.id == id }?.hasUsableContext } ?? false,
          dismiss: { model.recognitionRequest = nil })
      }
    }
    .task(id: model.noticeID) {
      guard model.notice != nil else { return }
      do { try await Task.sleep(nanoseconds: 2_200_000_000) } catch { return }
      model.notice = nil
    }
    // Quietly load the project list at launch; without a runtime the list is just empty.
    .task { await model.refreshProjects(quiet: true) }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: sidebarVisible)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: sidebarOverlaysContent)
    .tint(Palette.accent)
    .dropDestination(for: URL.self) { urls, _ in
      model.importDropped(urls)
    } isTargeted: {
      isTargeted = $0
    }
    .navigationTitle("Scivane")
  }


  /// One sidebar row, shared by all rows; the primary action is told apart by icon colour.
  private func navRow(
    _ title: String, symbol: String, accent: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) { navRowLabel(title, symbol: symbol, accent: accent) }
      .buttonStyle(SidebarRowStyle())
  }

  private func navRowLabel(_ title: String, symbol: String, accent: Bool) -> some View {
    HStack(spacing: 9) {
      Image(systemName: symbol).font(.system(size: 12, weight: accent ? .semibold : .regular))
        .foregroundStyle(accent ? Palette.accent : Palette.inkSoft)
        .frame(width: 15)
      Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10).frame(height: 31)
    .contentShape(Rectangle())
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 10.5, weight: .medium))
      .foregroundStyle(Palette.inkFaint)
      .padding(.horizontal, 10).padding(.bottom, 4)
  }

  /// - Parameter action: the "+" of the Projects section; nil shows only the title.
  private func sectionHeader(
    _ title: String, count: Int, action: (label: String, run: () -> Void)? = nil
  ) -> some View {
    HStack(spacing: 6) {
      Text(title).font(.system(size: 10, weight: .medium))
      Spacer()
      if let action {
        Button(action: action.run) {
          Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
        }
        .buttonStyle(.plain).help(action.label).accessibilityLabel(action.label)
      }
      Text("\(count)").font(.system(size: 10, design: .monospaced))
    }.foregroundStyle(Palette.inkFaint).padding(.top, 14).padding(.bottom, 5)
  }

  private var looseCount: Int {
    model.jobs.filter { model.jobProjects[$0.id] == nil }.count
  }

  private var filteredProjects: [Project] {
    let query = documentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty
      ? model.projects : model.projects.filter { $0.title.localizedStandardContains(query) }
  }

  /// Only loose documents. A project's files belong to the project and would otherwise appear twice,
  /// under disk names like `source`.
  private var filteredJobs: [DocumentJob] {
    let query = documentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let loose = model.jobs.filter { model.jobProjects[$0.id] == nil }
    return query.isEmpty
      ? loose : loose.filter { $0.title.localizedStandardContains(query) }
  }

  // MARK: - Toolbar
  //
  // The toolbar is an island of its own (ToolbarIsland); the page number floats over the PDF.
  // One-off actions such as Start OCR live in the empty text pane and the More menu.

  /// Where the island starts: past the sidebar's island when it lies over the reading area, flush when
  /// it pushes the reading area aside, past the rail's crown when folded. The traffic lights stay in
  /// the sidebar's island, which never goes away.
  private var toolbarLeading: CGFloat {
    sidebarVisible ? (sidebarOverlaysContent ? SidebarMetrics.panel : 0) : SidebarMetrics.crownOverflow
  }
}
