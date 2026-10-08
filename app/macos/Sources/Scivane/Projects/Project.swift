import Foundation

/// A paper. Fields match projects.model.Project in the backend.
struct Project: Codable, Identifiable, Equatable, Hashable {
  let id: String
  var title: String
  var titleSource: String
  var sourceName: String
  var sourceSha256: String
  var createdAt: String
  var updatedAt: String
  var context: ProjectContext?
  var hasUsableContext: Bool
  /// false for an empty project (created without a PDF); decides whether a reading area is shown
  var hasSource: Bool = false
  /// The app reads the source and figures by path rather than moving large files over HTTP.
  var dir: String
  var sourcePath: String?
  var contextPath: String?

  var sourceURL: URL? { sourcePath.map { URL(fileURLWithPath: $0) } }
  var contextURL: URL? { contextPath.map { URL(fileURLWithPath: $0) } }
  var directoryURL: URL { URL(fileURLWithPath: dir) }

  /// has text that nobody has confirmed belongs to this paper; shows the confirmation bar
  var awaitsConfirmation: Bool {
    guard let context else { return false }
    return !context.confirmed
  }

  var titleIsProvisional: Bool {
    titleSource == "filename" || titleSource == "pdf-metadata" || titleSource == "pdf-heading"
  }

  /// An empty project's stored title is the placeholder "未命名项目" (title_source = placeholder).
  /// That is data on disk and stays as is; only the display follows the UI language. A name the
  /// user typed (title_source = manual) is shown verbatim, even if it is the same text.
  var displayTitle: String {
    // 不翻: compares with the placeholder the backend writes to disk (UNTITLED in store.py)
    titleSource == "placeholder" && title == "未命名项目"
      ? L("未命名项目", "Untitled Project") : title
  }

  /// for previews and offscreen checks; real data is always decoded from the backend
  static func sample(id: String, title: String, sourceName: String = "") -> Project {
    Project(
      id: id, title: title, titleSource: "markdown-heading", sourceName: sourceName,
      sourceSha256: "", createdAt: "", updatedAt: "", context: nil, hasUsableContext: true,
      hasSource: !sourceName.isEmpty, dir: "/tmp/\(id)", sourcePath: nil, contextPath: nil)
  }
}

struct ProjectContext: Codable, Equatable, Hashable {
  var origin: String  // "ocr" | "upload"
  var sha256: String
  var chars: Int
  var tokens: Int
  var updatedAt: String
  var confirmed: Bool
  var jobId: String?

  var fromOCR: Bool { origin == "ocr" }

  var sizeLabel: String {
    guard tokens >= 1000 else { return L("约 \(tokens) token", "~\(tokens) tokens") }
    let wan = String(format: "%.1f", Double(tokens) / 10000)
    let thousands = String(format: "%.1f", Double(tokens) / 1000)
    return L("约 \(wan) 万 token", "~\(thousands)K tokens")
  }
}

/// A conversation in a project; fields match summarise() in projects/conversations.py. Each one
/// is its own .lumen/conversations/<id>.jsonl.
struct Conversation: Codable, Identifiable, Equatable, Hashable {
  let id: String
  var title: String
  var messages: Int
  var createdAt: String
  var updatedAt: String
  /// Model card chosen for this conversation; nil falls back to the global default. Older
  /// conversations decode as nil, so no migration is needed.
  var provider: String?

  /// The backend returns an empty title before the first message; the UI names it.
  var displayTitle: String { title.isEmpty ? L("新对话", "New Chat") : title }

  var isEmpty: Bool { messages == 0 }
}

/// A file the user dropped into files/. Separate from notes/: notes are written by people (the
/// agent needs confirmation to change them), files are given to the agent and need no gate.
struct ProjectFile: Codable, Identifiable, Equatable, Hashable {
  let name: String
  /// relative to the project root, e.g. `files/data.csv`; this is what the agent sees
  let path: String
  let bytes: Int

  var id: String { path }

  var sizeLabel: String {
    if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
    if bytes >= 1024 { return "\(bytes / 1024) KB" }
    return "\(bytes) B"
  }
}

enum ProjectClientError: LocalizedError {
  case http(Int, String)
  case notRunning

  var errorDescription: String? {
    switch self {
    case .http(let code, let detail):
      return detail.isEmpty ? L("服务返回 HTTP \(code)", "The service returned HTTP \(code)") : detail
    case .notRunning:
      return L("本地服务尚未就绪", "The local service isn't ready yet")
    }
  }
}

/// Client for the project API. All writes go through the backend so the storage format has a
/// single implementation; the source PDF and figures are read from disk directly.
struct ProjectClient {
  let base: URL

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  private func send<T: Decodable>(
    _ path: String, method: String = "GET", body: [String: Any]? = nil,
    as type: T.Type, key: String
  ) async throws -> T {
    var request = URLRequest(backend: base.appendingPathComponent(path))
    request.httpMethod = method
    request.timeoutInterval = 30
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else {
      let detail =
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
      throw ProjectClientError.http(code, detail ?? "")
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let slice = root[key]
    else {
      throw ProjectClientError.http(code, L("响应缺少字段 \(key)", "The response is missing the field \(key)"))
    }
    let sliced = try JSONSerialization.data(withJSONObject: slice)
    return try Self.decoder.decode(T.self, from: sliced)
  }

  func list() async throws -> [Project] {
    try await send("projects", as: [Project].self, key: "projects")
  }

  func get(_ id: String) async throws -> Project {
    try await send("projects/\(id)", as: Project.self, key: "project")
  }

  /// Building the same paper twice returns the existing project.
  func create(sourcePath: String) async throws -> Project {
    try await send(
      "projects", method: "POST", body: ["path": sourcePath],
      as: Project.self, key: "project")
  }

  func rename(_ id: String, to title: String) async throws -> Project {
    try await send(
      "projects/\(id)", method: "PATCH", body: ["title": title],
      as: Project.self, key: "project")
  }

  func delete(_ id: String) async throws {
    var request = URLRequest(backend: base.appendingPathComponent("projects/\(id)"))
    request.httpMethod = "DELETE"
    request.timeoutInterval = 30
    _ = try await URLSession.shared.data(for: request)
  }

  /// Replaces the context; re-running OCR and uploading share this entry point.
  func setContext(
    _ id: String, markdown: String, origin: String,
    jobID: String? = nil, sourceDirectory: URL? = nil
  ) async throws -> Project {
    var body: [String: Any] = ["markdown": markdown, "origin": origin]
    if let jobID { body["job_id"] = jobID }
    if let sourceDirectory { body["source_dir"] = sourceDirectory.path }
    return try await send(
      "projects/\(id)/context", method: "PUT", body: body,
      as: Project.self, key: "project")
  }

  func confirmContext(_ id: String, accepted: Bool) async throws -> Project {
    try await send(
      "projects/\(id)/context/confirm", method: "POST", body: ["accepted": accepted],
      as: Project.self, key: "project")
  }

  // MARK: - Empty projects and sources

  /// Create a project without a source. An empty title is passed through as is: the project is then
  /// untitled and later improved from the PDF, while a typed title is never overwritten.
  func createEmpty(title: String) async throws -> Project {
    try await send(
      "projects", method: "POST", body: ["title": title],
      as: Project.self, key: "project")
  }

  /// Only for projects without a source yet.
  func attachSource(_ id: String, path: String) async throws -> Project {
    try await send(
      "projects/\(id)/source", method: "POST", body: ["path": path],
      as: Project.self, key: "project")
  }

  // MARK: - User files

  func files(_ id: String) async throws -> [ProjectFile] {
    try await send("projects/\(id)/files", as: [ProjectFile].self, key: "files")
  }

  /// Copy a local file into files/. Sends a path, not bytes: app and backend share the machine.
  func addFile(_ id: String, path: String) async throws -> ProjectFile {
    try await send(
      "projects/\(id)/files", method: "POST", body: ["path": path],
      as: ProjectFile.self, key: "file")
  }

  func removeFile(_ id: String, name: String) async throws {
    let encoded =
      name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
    var request = URLRequest(
      backend: base.appendingPathComponent("projects/\(id)/files").appendingPathComponent(encoded))
    request.httpMethod = "DELETE"
    request.timeoutInterval = 30
    _ = try await URLSession.shared.data(for: request)
  }

  // MARK: - Conversations

  func conversations(_ id: String) async throws -> [Conversation] {
    try await send(
      "projects/\(id)/conversations", as: [Conversation].self, key: "conversations")
  }

  func createConversation(_ id: String) async throws -> Conversation {
    try await send(
      "projects/\(id)/conversations", method: "POST", body: [:],
      as: Conversation.self, key: "conversation")
  }

  func renameConversation(_ id: String, _ conversation: String, to title: String) async throws
    -> Conversation
  {
    try await send(
      "projects/\(id)/conversations/\(conversation)", method: "PATCH", body: ["title": title],
      as: Conversation.self, key: "conversation")
  }

  /// Reuses the rename endpoint: both change a conversation's attributes.
  func setConversationProvider(_ id: String, _ conversation: String, to provider: String)
    async throws -> Conversation
  {
    try await send(
      "projects/\(id)/conversations/\(conversation)", method: "PATCH",
      body: ["provider": provider], as: Conversation.self, key: "conversation")
  }

  func deleteConversation(_ id: String, _ conversation: String) async throws {
    var request = URLRequest(
      backend: base.appendingPathComponent("projects/\(id)/conversations/\(conversation)"))
    request.httpMethod = "DELETE"
    request.timeoutInterval = 30
    _ = try await URLSession.shared.data(for: request)
  }

  // MARK: - Annotations

  func annotations(_ projectID: String) async throws -> [PaperAnnotation] {
    try await send(
      "projects/\(projectID)/annotations", as: [PaperAnnotation].self, key: "annotations")
  }

  func addAnnotation(_ annotation: PaperAnnotation, to projectID: String) async throws {
    try await expectOK(
      "projects/\(projectID)/annotations", method: "POST", body: annotation.payload)
  }

  func updateAnnotation(_ id: String, in projectID: String, kind: String?, color: String?)
    async throws
  {
    var body: [String: Any] = [:]
    if let kind { body["kind"] = kind }
    if let color { body["color"] = color }
    try await expectOK("projects/\(projectID)/annotations/\(id)", method: "PATCH", body: body)
  }

  func removeAnnotation(_ id: String, from projectID: String) async throws {
    try await expectOK("projects/\(projectID)/annotations/\(id)", method: "DELETE")
  }

  /// For writes whose response carries nothing the caller needs; a failure still throws.
  private func expectOK(_ path: String, method: String, body: [String: Any]? = nil) async throws {
    var request = URLRequest(backend: base.appendingPathComponent(path))
    request.httpMethod = method
    request.timeoutInterval = 30
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else {
      let detail =
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
      throw ProjectClientError.http(code, detail ?? "")
    }
  }

  /// Raw bytes rather than decoded data: the JSON is written to a file as is, and decoding and
  /// re-encoding would only reorder and reformat it.
  func exportConversation(_ id: String, _ conversation: String) async throws -> Data {
    let url = base.appendingPathComponent(
      "projects/\(id)/conversations/\(conversation)/export")
    var request = URLRequest(backend: url)
    request.timeoutInterval = 30
    let (data, response) = try await URLSession.shared.data(for: request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else {
      let detail =
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
      throw ProjectClientError.http(code, detail ?? "")
    }
    return data
  }
}
