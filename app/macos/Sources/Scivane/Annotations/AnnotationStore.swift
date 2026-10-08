import Foundation

/// The marks of the open project.
///
/// Edits show at once and are written through the backend one after another, in the order they
/// were made: two quick recolours sent concurrently could land in either order. A failed write is
/// rolled back locally and reported. Loads queue behind pending writes, so a reload never drops a
/// mark that is still on its way.
@MainActor
final class AnnotationStore: ObservableObject {
  @Published private(set) var projectID: String?
  @Published private(set) var annotations: [PaperAnnotation] = []
  /// Writes not yet confirmed by the backend; it must not idle-stop under them.
  private(set) var pendingWrites = 0

  var onError: (String) -> Void = { _ in }
  /// Brings the backend up; it stops itself when idle.
  var ready: () async -> Bool = { true }

  private let service: () -> AnnotationService
  private var tail: Task<Void, Never>?
  private var loadGeneration = 0
  /// Bumped by every local edit, so a load that raced one is retried instead of applied.
  private var revision = 0
  /// Undo actions belong to the project they were made in; they are dropped on a switch.
  private weak var undoManager: UndoManager?

  init(service: @escaping () -> AnnotationService) {
    self.service = service
  }

  var hasPendingWrites: Bool { pendingWrites > 0 }

  func annotation(_ id: String) -> PaperAnnotation? { annotations.first { $0.id == id } }

  // MARK: - Loading

  /// Show this project's marks; nil clears them.
  func load(_ projectID: String?) {
    if projectID != self.projectID {
      undoManager?.removeAllActions(withTarget: self)
      self.projectID = projectID
      annotations = []
    }
    loadGeneration += 1
    guard let projectID else { return }
    let generation = loadGeneration
    // taken now, not when the load runs: an edit made in between is queued behind it and isn't on
    // the backend yet
    let started = revision
    enqueue { store in
      guard store.isCurrent(generation, projectID), await store.ready() else { return }
      do {
        let loaded = try await store.service().annotations(projectID)
        guard store.isCurrent(generation, projectID) else { return }
        if store.revision != started {
          store.load(projectID)
        } else {
          store.annotations = loaded
        }
      } catch {
        guard store.isCurrent(generation, projectID) else { return }
        store.onError(L("标注读取失败：", "Couldn't load the marks: ") + error.localizedDescription)
      }
    }
  }

  private func isCurrent(_ generation: Int, _ projectID: String) -> Bool {
    generation == loadGeneration && self.projectID == projectID
  }

  /// Waits until every queued load and write has finished.
  func settle() async {
    while let task = tail {
      await task.value
      if task == tail { return }
    }
  }

  // MARK: - Editing

  func add(_ annotation: PaperAnnotation, undo: UndoManager?) {
    guard let projectID, self.annotation(annotation.id) == nil else { return }
    annotations.append(annotation)
    revision += 1
    register(undo, L("添加标注", "Add Mark")) { [weak undo] in $0.remove(annotation.id, undo: undo) }
    write(projectID, { try await $0.addAnnotation(annotation, to: projectID) }) { store in
      store.annotations.removeAll { $0.id == annotation.id }
    }
  }

  func restyle(_ id: String, kind: AnnotationKind? = nil, color: AnnotationColor? = nil,
               undo: UndoManager?) {
    guard let projectID, let index = annotations.firstIndex(where: { $0.id == id }) else { return }
    let before = annotations[index]
    var after = before
    if let kind { after.kind = kind.rawValue }
    if let color { after.color = color.rawValue }
    guard after != before else { return }
    annotations[index] = after
    revision += 1
    register(undo, L("修改标注", "Change Mark")) { [weak undo] store in
      store.restyle(id, kind: AnnotationKind(rawValue: before.kind),
                    color: AnnotationColor(rawValue: before.color), undo: undo)
    }
    write(projectID, {
      try await $0.updateAnnotation(id, in: projectID, kind: kind?.rawValue, color: color?.rawValue)
    }) { store in
      // only undo our own change; a later edit that also failed rolls itself back
      if let i = store.annotations.firstIndex(where: { $0.id == id }), store.annotations[i] == after {
        store.annotations[i] = before
      }
    }
  }

  func remove(_ id: String, undo: UndoManager?) {
    guard let projectID, let index = annotations.firstIndex(where: { $0.id == id }) else { return }
    let removed = annotations.remove(at: index)
    revision += 1
    // re-creating under the same id is allowed once the backend has deleted it
    register(undo, L("删除标注", "Delete Mark")) { [weak undo] in $0.add(removed, undo: undo) }
    write(projectID, { try await $0.removeAnnotation(id, from: projectID) }) { store in
      if store.annotation(id) == nil {
        store.annotations.insert(removed, at: min(index, store.annotations.count))
      }
    }
  }

  // MARK: - Plumbing

  private func register(_ undo: UndoManager?, _ name: String,
                        _ inverse: @escaping (AnnotationStore) -> Void) {
    guard let undo else { return }
    undoManager = undo
    undo.registerUndo(withTarget: self) { store in
      MainActor.assumeIsolated { inverse(store) }
    }
    undo.setActionName(name)
  }

  private func write(_ projectID: String, _ request: @escaping (AnnotationService) async throws -> Void,
                     rollback: @escaping (AnnotationStore) -> Void) {
    pendingWrites += 1
    enqueue { store in
      defer { store.pendingWrites -= 1 }
      do {
        guard await store.ready() else { throw ProjectClientError.notRunning }
        try await request(store.service())
      } catch {
        // edits of a project that is no longer shown have nothing on screen to restore
        if store.projectID == projectID { rollback(store) }
        store.onError(L("标注没有保存：", "Couldn't save the mark: ") + error.localizedDescription)
      }
    }
  }

  private func enqueue(_ job: @escaping (AnnotationStore) async -> Void) {
    let previous = tail
    tail = Task { [weak self] in
      await previous?.value
      guard let self else { return }
      await job(self)
    }
  }
}
