import Foundation

/// 一篇论文。字段与后端 `scivane_reader.projects.model.Project` 一一对应。
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
  /// 有没有原稿。空项目（直接新建、还没导入 PDF）没有 ——
  /// 界面据此决定要不要摆出阅读区。
  var hasSource: Bool = false
  /// 项目目录。App 直接按路径读原稿与插图，不走 HTTP 搬运大文件。
  var dir: String
  var sourcePath: String?
  var contextPath: String?

  var sourceURL: URL? { sourcePath.map { URL(fileURLWithPath: $0) } }
  var contextURL: URL? { contextPath.map { URL(fileURLWithPath: $0) } }
  var directoryURL: URL { URL(fileURLWithPath: dir) }

  /// 有正文但还没人确认它是不是这篇论文。界面据此弹确认条。
  var awaitsConfirmation: Bool {
    guard let context else { return false }
    return !context.confirmed
  }

  var titleIsProvisional: Bool {
    titleSource == "filename" || titleSource == "pdf-metadata" || titleSource == "pdf-heading"
  }

  /// 界面上显示的名字。
  ///
  /// 空项目留空时，后端存的是占位名「未命名项目」（`title_source = placeholder`）。
  /// 那是写在磁盘上的数据，**不改它**；只在显示时按界面语言说 —— 中文界面里与盘上逐字相同。
  /// 用户自己打的名字（哪怕恰好也叫「未命名项目」）来源是 manual，原样显示。
  var displayTitle: String {
    // 不翻：比对的是后端写在盘上的占位名（store.py 的 UNTITLED）
    titleSource == "placeholder" && title == "未命名项目"
      ? L("未命名项目", "Untitled Project") : title
  }

  /// 给预览与离屏验证造样本用。真实数据一律从后端解码。
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

  /// 给界面显示「这篇论文有多大」。
  var sizeLabel: String {
    guard tokens >= 1000 else { return L("约 \(tokens) token", "~\(tokens) tokens") }
    let wan = String(format: "%.1f", Double(tokens) / 10000)
    let thousands = String(format: "%.1f", Double(tokens) / 1000)
    return L("约 \(wan) 万 token", "~\(thousands)K tokens")
  }
}

/// 项目里的一条对话。字段与后端 `projects/conversations.py` 的 `summarise()` 对应。
///
/// **一个项目可以有多条**，各自一份 `.lumen/conversations/<id>.jsonl`。
/// 换一条对话就是换一段历史 —— 这正是它在模型那边的全部含义。
struct Conversation: Codable, Identifiable, Equatable, Hashable {
  let id: String
  var title: String
  var messages: Int
  var createdAt: String
  var updatedAt: String
  /// 这条对话选定的模型卡。**nil = 没选过**，界面回落到全局默认。
  ///
  /// 老对话（换卡这个能力之前建的）投影出来就是 nil，所以这个字段
  /// 不需要任何迁移 —— 后端那边同理，见 conversations.summarise。
  var provider: String?

  /// 侧栏与菜单里显示的名字。
  ///
  /// 后端对还没说过话的对话返回空标题 —— 由界面决定叫什么，
  /// 而不是让后端替界面编一个（那样两边就有两套文案了）。
  var displayTitle: String { title.isEmpty ? L("新对话", "New Chat") : title }

  var isEmpty: Bool { messages == 0 }
}

/// 用户拖进项目的一份材料，落在 `files/`。
///
/// **和 `notes/` 分开**：notes/ 是人**写**的结论（agent 改它要确认），
/// files/ 是人**给**的材料 —— 本来就是给 agent 看的，读写都不必拦。
struct ProjectFile: Codable, Identifiable, Equatable, Hashable {
  let name: String
  /// 相对项目根，如 `files/数据.csv`。给 agent 的就是这个。
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

/// 项目接口的客户端。
///
/// 所有写操作走后端 —— 存储格式只有一处实现，避免 Swift 和 Python 各写一遍
/// 又慢慢漂移。读原稿和插图则直接按路径访问本地文件，不为几十 MB 的 PDF
/// 走一趟 HTTP。
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

  /// 构建项目。同一篇论文重复构建会返回已有项目。
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

  /// 替换静态上下文。「重新 OCR 覆盖」与「上传覆盖」走同一个入口。
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

  // MARK: - 空项目与原稿

  /// 建一个还没有原稿的项目。
  ///
  /// **标题留空是有意义的**：留空的项目叫「未命名项目」，之后导入 PDF 时
  /// 会被识别出来的标题改进；打了字的则受红线保护，任何自动提取都不许覆盖。
  /// 所以这里原样把用户输入交上去，空串也照传，不在这一层替他补一个默认名。
  func createEmpty(title: String) async throws -> Project {
    try await send(
      "projects", method: "POST", body: ["title": title],
      as: Project.self, key: "project")
  }

  /// 给一个空项目挂上原稿。只对还没有原稿的项目开放。
  func attachSource(_ id: String, path: String) async throws -> Project {
    try await send(
      "projects/\(id)/source", method: "POST", body: ["path": path],
      as: Project.self, key: "project")
  }

  // MARK: - 用户上传的材料

  func files(_ id: String) async throws -> [ProjectFile] {
    try await send("projects/\(id)/files", as: [ProjectFile].self, key: "files")
  }

  /// 把一个本机文件复制进 `files/`。
  ///
  /// **传路径而不是字节** —— App 与后端在同一台机器上，把几十 MB 从 HTTP
  /// 搬一遍毫无收益（与原稿、插图同一个取舍）。
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

  // MARK: - 对话

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

  /// 这条对话改用哪张模型卡。**复用改名那个端点** —— 两者都是「改这条对话的
  /// 属性」，分成两个端点只会让这边多记一条路径。
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

  /// 导出一条对话。
  ///
  /// 返回**原始字节**而不是解码后的结构：这份 JSON 要原样写成文件交给用户，
  /// 中间过一道 Swift 的解码再编码只会改动键序与格式，毫无好处。
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
