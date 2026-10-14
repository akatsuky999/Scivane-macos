import Foundation

/// The headings of the document in the text pane, as the renderer drew them, and the one being read.
/// An object of its own: scrolling past a heading redraws the sidebar's outline, not every view that
/// watches the app model.
@MainActor
final class DocumentOutline: ObservableObject {
  struct Entry: Identifiable, Equatable {
    /// position among the rendered headings; what the renderer scrolls to
    let id: Int
    /// 1–3, from h1–h3
    let level: Int
    let title: String
  }

  /// the document the entries belong to: a renderer that went away leaves them, but only for it
  @Published private(set) var documentID: DocumentJob.ID?
  @Published private(set) var entries: [Entry] = []
  @Published private(set) var current: Int?
  /// A heading asked for while no renderer could scroll (the text pane wasn't showing). Scrolled to
  /// once the document's headings are reported, and cleared when the renderer confirms.
  var pending: Int?

  func update(document: DocumentJob.ID?, entries: [Entry]) {
    if document != documentID || entries != self.entries {
      documentID = document
      self.entries = entries
    }
    if let current, current >= entries.count { self.current = nil }
  }

  func setCurrent(_ index: Int?) {
    guard index != current else { return }
    current = index
  }

  /// the headings, if they belong to this document
  func entries(for document: DocumentJob.ID?) -> [Entry] {
    document != nil && document == documentID ? entries : []
  }
}

/// The sidebar's own state. Whether the panel is open is a stored preference (sidebarVisible); the
/// search text and a request to focus it (⌘K from the menu) live here, so typing doesn't redraw the
/// reading area.
@MainActor
final class SidebarState: ObservableObject {
  @Published var query = ""
  /// bumped to put the cursor in the search field
  @Published var focusRequest = 0
  /// the New Project prompt, asked for from the rail or the library
  @Published var creatingProject = false
}
