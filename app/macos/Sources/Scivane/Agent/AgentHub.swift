import AppKit
import Foundation

/// Agent wiring: providers, credential injection, asking, approval. State lives in AppModel; this
/// holds behaviour only, like ProjectWorkspace.
@MainActor
extension AppModel {

  /// Never contains a credential; the backend's describe_all() doesn't return one either.
  struct ProviderSummary: Identifiable, Decodable, Equatable {
    let id: String
    let label: String
    let model: String
    let baseUrl: String
    /// must be filled back in when editing, never guessed
    let proto: String
    /// env var, runtime injection or credentials file
    let hasCredential: Bool
    /// Optional; otherwise the endpoint's reported window (detectedWindow). Never guessed from the
    /// model name: the same name can have different windows behind different gateways, and a wrong
    /// number is worse than none.
    let contextWindow: Int?
    /// Read-only. Not saved into contextWindow, so an alias such as `...-latest` doesn't keep a stale window.
    let detectedWindow: Int?
    var window: Int? { contextWindow ?? detectedWindow }
    /// none / low / medium / high. Per provider, not global: a reasoning and a plain model can be
    /// configured side by side, and the latter ignores or rejects the setting.
    let reasoning: String
    /// `own` or `macro:<n>`; a reference, not a secret
    let credentialRef: String

    /// falls back to the id, never the model id
    var displayName: String { label.isEmpty ? id : label }

    private enum CodingKeys: String, CodingKey {
      case id, label, model, reasoning
      case proto = "protocol"
      case credentialRef = "credential_ref"
      case baseUrl = "base_url"
      case hasCredential = "has_credential"
      case contextWindow = "context_window"
      case detectedWindow = "detected_window"
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      id = try c.decode(String.self, forKey: .id)
      label = (try? c.decode(String.self, forKey: .label)) ?? id
      model = (try? c.decode(String.self, forKey: .model)) ?? ""
      baseUrl = (try? c.decode(String.self, forKey: .baseUrl)) ?? ""
      proto = (try? c.decode(String.self, forKey: .proto)) ?? ProviderDefaults.proto
      hasCredential = (try? c.decode(Bool.self, forKey: .hasCredential)) ?? false
      contextWindow = try? c.decodeIfPresent(Int.self, forKey: .contextWindow)
      detectedWindow = try? c.decodeIfPresent(Int.self, forKey: .detectedWindow)
      reasoning = (try? c.decode(String.self, forKey: .reasoning)) ?? ProviderDefaults.reasoning
      credentialRef = (try? c.decode(String.self, forKey: .credentialRef)) ?? "own"
    }

    /// for previews and offscreen checks; real data is always decoded from the backend
    init(
      id: String, label: String, model: String, baseUrl: String,
      proto: String = ProviderDefaults.proto, hasCredential: Bool = false,
      contextWindow: Int? = nil, detectedWindow: Int? = nil, reasoning: String = ProviderDefaults.reasoning,
      credentialRef: String = "own"
    ) {
      self.contextWindow = contextWindow
      self.detectedWindow = detectedWindow
      self.reasoning = reasoning
      self.credentialRef = credentialRef
      self.id = id
      self.label = label
      self.model = model
      self.baseUrl = baseUrl
      self.proto = proto
      self.hasCredential = hasCredential
    }
  }

  /// Defaults for a new provider: a working OpenRouter setup to edit, rather than four empty fields.
  enum ProviderDefaults {
    static let id = "openrouter"
    static let label = "OpenRouter"
    static let proto = "openai"
    static let baseURL = "https://openrouter.ai/api/v1"
    static let model = "qwen/qwen3.8-flash"
    /// medium, not low: checking that code matches a formula needs real reasoning
    static let reasoning = "medium"
  }

  /// Must match REASONING_LEVELS in the backend; a mismatch silently resets to the default on save.
  /// Computed rather than static let so the labels follow the UI language.
  static var reasoningLevels: [(value: String, label: String, hint: String)] {
    [
      ("none", L("关", "Off"), L("完全不推理。最快，但复杂推导会变浅", "No reasoning. Fastest, but hard derivations get shallow")),
      ("low", L("低", "Low"), L("少想一点。适合问答、摘要", "A little thinking. Good for Q&A and summaries")),
      ("medium", L("中", "Medium"),
       L("默认。核对公式、读代码这类活儿够用", "Default. Enough for checking formulas and reading code")),
      ("high", L("高", "High"),
       L("想得最久。复杂推导更稳，但等待明显变长", "Thinks longest. Steadier on hard derivations, but noticeably slower")),
    ]
  }

  /// There is no "vendor" here, only protocol + address + model: DeepSeek is openai +
  /// api.deepseek.com/v1, local Ollama is openai + localhost:11434/v1, both on one adapter.
  static var protocols: [(id: String, label: String, hint: String)] {
    [
      ("openai", L("OpenAI 兼容", "OpenAI-compatible"),
       L("绝大多数都走这个：OpenAI、DeepSeek、Kimi、智谱、通义、硅基流动、OpenRouter、Ollama、vLLM",
         "Most providers use this: OpenAI, DeepSeek, Kimi, Zhipu, Qwen, SiliconFlow, OpenRouter, Ollama, vLLM")),
      ("anthropic", "Anthropic", L("Claude 的 Messages 接口", "Claude's Messages API")),
      ("gemini", "Google Gemini", L("Gemini 的 generateContent 接口", "Gemini's generateContent API")),
    ]
  }

  // MARK: - Providers

  func refreshProviders(quiet: Bool = true) async {
    guard await awaitBackend(quiet: quiet) else { return }
    var request = URLRequest(backend: backend.apiBase.appendingPathComponent("llm/providers"))
    request.timeoutInterval = 15
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200,
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let raw = root["providers"]
    else { return }
    let blob = try? JSONSerialization.data(withJSONObject: raw)
    providers = (blob.flatMap { try? JSONDecoder().decode([ProviderSummary].self, from: $0) }) ?? []
    if providers.isEmpty && isLiveApp { await seedPresetsOnce() }
    if agentProvider.isEmpty || !providers.contains(where: { $0.id == agentProvider }) {
      agentProvider = providers.first?.id ?? ""
    }
    await injectCredentials()
  }

  /// Three preset cards (OpenRouter / DeepSeek / OpenAI) that only need a key.
  ///
  /// Created once, behind a flag; otherwise deleted presets would grow back on the next launch.
  private func seedPresetsOnce() async {
    // Only the real app: this writes providers.json and starts the backend, and refreshProviders()
    // also runs in offscreen checks.
    guard isLiveApp else { return }
    let flag = "seededProviderPresets"
    guard !UserDefaults.standard.bool(forKey: flag) else { return }
    UserDefaults.standard.set(true, forKey: flag)
    for preset in Self.presets {
      _ = await saveProvider(
        id: preset.id, label: preset.label, proto: "openai", model: preset.model,
        baseURL: preset.baseURL, contextWindow: preset.window)
    }
    await refreshProviders()
  }

  /// `window` is the vendor's documented value; unknown ones stay empty, a wrong number being worse
  /// than none. Labels are written in the UI language at creation time and are user data after that.
  static var presets: [(id: String, label: String, model: String, baseURL: String, window: Int?)] {
    [
      // Three endpoints, not three models: the base URL is what people get wrong most. OpenRouter gets
      // openrouter/auto so it doesn't look like a duplicate of another card.
      ("openrouter", "OpenRouter", "openrouter/auto", "https://openrouter.ai/api/v1", nil),
      ("deepseek", L("DeepSeek 官方", "DeepSeek Official"), "deepseek-chat", "https://api.deepseek.com/v1", 128_000),
      ("openai", L("OpenAI 官方", "OpenAI Official"), "gpt-5.2", "https://api.openai.com/v1", nil),
    ]
  }

  /// Inject the Keychain keys into the backend.
  ///
  /// Through the runtime endpoint rather than environment variables at launch:
  /// 1. process environments are readable (`ps -E`) by any process of the same user
  /// 2. the backend restarts on the light -> full upgrade; the endpoint only needs one injection
  ///    point (backend ready) instead of every restart path
  /// 3. a changed key applies immediately, without a restart
  func injectCredentials() async {
    // credentials only live in the backend process's memory
    if injectedGeneration != backend.launchGeneration {
      injectedProviders.removeAll()
      injectedGeneration = backend.launchGeneration
    }
    for provider in providers {
      guard !injectedProviders.contains(provider.id),
        let secret = Self.secret(for: provider)
      else { continue }
      var request = URLRequest(
        backend: backend.apiBase.appendingPathComponent("llm/providers/\(provider.id)/credential"))
      request.httpMethod = "POST"
      request.timeoutInterval = 15
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try? JSONSerialization.data(withJSONObject: ["api_key": secret])
      // No message on failure: this is background catch-up, and real problems surface on Test or when
      // asking. Never put the secret in a log or error.
      if let (_, response) = try? await URLSession.shared.data(for: request),
        (response as? HTTPURLResponse)?.statusCode == 200 {
        injectedProviders.insert(provider.id)
      }
    }
  }

  /// Which key this card actually uses. Resolved on the app side; the backend never learns about
  /// shared keys and only receives the resolved key in memory.
  static func secret(for provider: ProviderSummary) -> String? {
    if provider.credentialRef.hasPrefix("macro:") {
      return MacroKeys.secret(id: String(provider.credentialRef.dropFirst(6)))
    }
    return Keychain.secret(provider: provider.id)
  }

  /// A card using a shared key depends on that key. Checking only the card's own entry would show a
  /// configured card as unconfigured, and re-entering it would overwrite the shared one.
  static func hasKey(_ provider: ProviderSummary) -> Bool {
    secret(for: provider) != nil
  }

  /// Write to the Keychain, then inject at once.
  func saveCredential(_ secret: String, provider: String) async -> Bool {
    guard Keychain.set(secret, provider: provider) else { return false }
    injectedProviders.remove(provider)
    await injectCredentials()
    await refreshProviders()
    return true
  }

  /// The backend persists it (providers.json; the path is defined only in config.py).
  func saveProvider(
    id: String, label: String, proto: String, model: String, baseURL: String,
    contextWindow: Int? = nil, reasoning: String = ProviderDefaults.reasoning,
    credentialRef: String = "own"
  ) async -> (ok: Bool, message: String) {
    let identifier = id.trimmingCharacters(in: .whitespaces)
    guard !identifier.isEmpty else { return (false, L("标识不能为空", "The ID can't be empty")) }
    guard !model.trimmingCharacters(in: .whitespaces).isEmpty else {
      return (false, L("得填一个模型名", "Enter a model name"))
    }
    guard await awaitBackend() else { return (false, L("本地服务没起来", "The local service isn't running")) }

    var request = URLRequest(backend: backend.apiBase.appendingPathComponent("llm/providers"))
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var payload: [String: Any] = [
      "id": identifier, "protocol": proto,
      "model": model.trimmingCharacters(in: .whitespaces),
      "base_url": baseURL.trimmingCharacters(in: .whitespaces),
      "label": label.trimmingCharacters(in: .whitespaces),
    ]
    if let contextWindow, contextWindow > 0 { payload["context_window"] = contextWindow }
    payload["reasoning"] = reasoning
    payload["credential_ref"] = credentialRef
    request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
    guard let (data, response) = try? await URLSession.shared.data(for: request) else {
      return (false, L("连不上本地服务", "Can't reach the local service"))
    }
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else {
      let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"]
      return (false, (detail as? String) ?? L("保存失败（\(code)）", "Couldn't save (\(code))"))
    }
    // address or model changed: inject again to be safe
    injectedProviders.remove(identifier)
    await refreshProviders()
    agentProvider = identifier
    return (true, L("已保存", "Saved"))
  }

  /// Also removes its key from the Keychain.
  func deleteProvider(_ id: String) async {
    guard await awaitBackend() else { return }
    var request = URLRequest(
      backend: backend.apiBase.appendingPathComponent("llm/providers/\(id)"))
    request.httpMethod = "DELETE"
    request.timeoutInterval = 15
    _ = try? await URLSession.shared.data(for: request)
    Keychain.clear(provider: id)
    injectedProviders.remove(id)
    await refreshProviders()
  }

  /// Returns a sentence that can be shown as is.
  func testProvider(_ id: String) async -> (ok: Bool, message: String) {
    guard await awaitBackend() else { return (false, L("本地服务没起来", "The local service isn't running")) }
    var request = URLRequest(
      backend: backend.apiBase.appendingPathComponent("llm/providers/\(id)/test"))
    request.httpMethod = "POST"
    request.timeoutInterval = 60
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return (false, L("连不上本地服务", "Can't reach the local service")) }
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    if code == 200, root["ok"] as? Bool == true {
      guard let model = root["model"] as? String else { return (true, L("连通了", "Connected")) }
      return (true, L("连通了，模型 \(model)", "Connected · model \(model)"))
    }
    // stable backend error codes, phrased for people; no credential is ever echoed
    let failure = root["code"] as? String ?? "UNKNOWN"
    switch failure {
    case "MISSING_CREDENTIAL": return (false, L("还没填 API key", "No API key yet"))
    case "INVALID_CREDENTIAL", "AUTH":
      return (false, L("key 不对，或者没有这个模型的权限", "Wrong key, or no access to this model"))
    case "RATE_LIMIT": return (false, L("被限流了，等一会儿再试", "Rate-limited — try again in a moment"))
    case "QUOTA": return (false, L("配额用完了", "Out of quota"))
    case "TIMEOUT", "TRANSPORT":
      return (false, L("连不上厂商，检查网络或 base_url", "Can't reach the provider — check the network or base URL"))
    case "NO_ADAPTER": return (false, L("这个 provider 没有注册", "This provider isn't registered"))
    default:
      return (false, (root["message"] as? String) ?? L("测试失败（\(failure)）", "Test failed (\(failure))"))
    }
  }

  /// manual window first, then the reported one; nil if neither
  var activeContextWindow: Int? {
    providers.first { $0.id == activeProviderID }?.window
  }

  // MARK: - Project files

  func refreshProjectFiles(_ projectID: String) async {
    guard await awaitBackend(quiet: true) else { return }
    guard let found = try? await projectClient.files(projectID) else { return }
    projectFiles[projectID] = found
  }

  /// Files are sent one by one, so a bad file fails on its own.
  func addProjectFiles(_ urls: [URL]) async {
    guard let projectID = activeProjectID else {
      notifyProject(L("先打开一个项目，文件才知道该放哪儿", "Open a project first, so the files know where to go"))
      return
    }
    guard await awaitBackend() else { return }
    var added: [String] = []
    for url in urls {
      do {
        added.append(try await projectClient.addFile(projectID, path: url.path).name)
      } catch {
        notifyProject(L("「\(url.lastPathComponent)」没放进去：", "Couldn't add “\(url.lastPathComponent)”: ")
                      + error.localizedDescription)
      }
    }
    await refreshProjectFiles(projectID)
    if !added.isEmpty {
      notifyProject(
        added.count == 1
          ? L("已放进 files/：\(added[0])", "Added to files/: \(added[0])")
          : L("已放进 files/：\(added.count) 个文件", "Added to files/: \(added.count) files"))
    }
  }

  func chooseProjectFiles() {
    guard activeProjectID != nil else {
      notifyProject(L("先打开一个项目，文件才知道该放哪儿", "Open a project first, so the files know where to go"))
      return
    }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.message = L("选择要交给 agent 的材料（相关论文、数据、截图）",
                      "Choose files for the agent (related papers, data, screenshots)")
    panel.prompt = L("放进项目", "Add to Project")
    guard panel.runModal() == .OK else { return }
    let urls = panel.urls
    Task { await addProjectFiles(urls) }
  }

  func removeProjectFile(_ file: ProjectFile) async {
    guard let projectID = activeProjectID else { return }
    guard await awaitBackend() else { return }
    try? await projectClient.removeFile(projectID, name: file.name)
    await refreshProjectFiles(projectID)
  }

  // MARK: - Asking

  var canAskAgent: Bool {
    guard !agentProvider.isEmpty else { return false }
    // the librarian needs no text
    guard let project = activeProject else { return true }
    return project.hasUsableContext
  }

  func askAgent(_ question: String) {
    let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, canAskAgent else { return }
    let session = agentSession
    let provider = activeProviderID
    Task {
      guard await awaitBackend() else { return }
      await injectCredentials()
      session.ask(trimmed, base: backend.apiBase, provider: provider)
    }
  }

  /// Compact the current conversation by hand. Same preparation as asking (backend, credentials):
  /// it calls the model. The librarian has nothing to compact.
  func compactAgentContext() {
    guard activeProjectID != nil, !activeProviderID.isEmpty else { return }
    let session = agentSession
    let provider = activeProviderID
    Task {
      guard await awaitBackend() else { return }
      await injectCredentials()
      session.compact(base: backend.apiBase, provider: provider)
    }
  }

  /// Reads local numbers only, so no credential injection.
  func refreshAgentContext() async {
    guard activeProjectID != nil else { return }
    let session = agentSession
    let provider = activeProviderID
    guard await awaitBackend(quiet: true) else { return }
    await session.refreshContext(base: backend.apiBase, provider: provider.isEmpty ? nil : provider)
  }

  /// Each conversation remembers its own card, falling back to the global default when none is set
  /// or the card was deleted; otherwise asking fails with an unknown provider for no visible reason.
  var activeProviderID: String {
    if let chosen = activeConversationRecord?.provider,
      providers.contains(where: { $0.id == chosen }) {
      return chosen
    }
    return agentProvider
  }

  /// nil for the librarian
  var activeConversationRecord: Conversation? {
    guard let projectID = activeProjectID, let current = activeConversation[projectID]
    else { return nil }
    return conversations[projectID]?.first { $0.id == current }
  }

  /// Saved in the conversation's log, so it sticks.
  func useProvider(_ providerID: String) {
    guard let projectID = activeProjectID,
      let conversationID = activeConversation[projectID]
    else {
      // the librarian has no conversation; change the global default
      agentProvider = providerID
      return
    }
    Task {
      guard await awaitBackend() else { return }
      do {
        _ = try await projectClient.setConversationProvider(
          projectID, conversationID, to: providerID)
        await refreshConversations(projectID)
      } catch {
        notifyProject(L("换模型失败：", "Couldn't switch models: ") + error.localizedDescription)
      }
    }
  }

  /// After entering a project, returning to the librarian or switching conversations.
  func restoreAgentHistory() {
    let session = agentSession
    Task {
      guard await awaitBackend(quiet: true) else { return }
      await session.restore(base: backend.apiBase)
    }
  }

  // MARK: - Conversations
  //
  // The backend is the only source of the list (computed from the conversation files); a second
  // copy here would drift.

  /// Load the list and make sure one is selected. Never creates one here: the backend does that on
  /// the first question, otherwise opening the agent pane would leave an empty conversation on disk.
  @discardableResult
  func refreshConversations(_ projectID: String) async -> Bool {
    guard await awaitBackend(quiet: true) else { return false }
    guard let found = try? await projectClient.conversations(projectID) else { return false }
    conversations[projectID] = found
    // the selection was deleted (or never made): back to the most recent
    if let current = activeConversation[projectID],
      found.contains(where: { $0.id == current })
    { return true }
    if let latest = found.first {
      activeConversation[projectID] = latest.id
    } else {
      activeConversation.removeValue(forKey: projectID)
    }
    return true
  }

  /// Stays put if the current conversation is still empty, so repeated clicks don't leave a trail
  /// of empty files.
  func newConversation() async {
    guard let projectID = activeProjectID else { return }
    if let current = activeConversationID,
      let found = conversations[projectID]?.first(where: { $0.id == current }),
      found.isEmpty
    { return }
    guard await awaitBackend() else { return }
    do {
      let created = try await projectClient.createConversation(projectID)
      await refreshConversations(projectID)
      activeConversation[projectID] = created.id
    } catch {
      notifyProject(L("新建对话失败：", "Couldn't create a chat: ") + error.localizedDescription)
    }
  }

  /// Open a conversation from the sidebar; the project may not be the current one. Enter the project
  /// first: selectConversation writes to activeConversation[activeProjectID].
  func openConversation(project: Project, conversation: String) async {
    guard !sidebarNavigationBusy else { return }
    sidebarNavigationBusy = true
    defer { sidebarNavigationBusy = false }
    if activeProjectID != project.id { await enterProject(project) }
    // if entering failed, don't write into the previous project; and a click must show the agent
    guard activeProjectID == project.id else { return }
    // Only picks the pane; dualPane is the user's preference and stays as it is.
    paneSelection = "chat"
    selectConversation(conversation)
  }

  /// The project may not be the current one here either.
  func newConversation(in project: Project) async {
    guard !sidebarNavigationBusy else { return }
    sidebarNavigationBusy = true
    defer { sidebarNavigationBusy = false }
    if activeProjectID != project.id { await enterProject(project) }
    guard activeProjectID == project.id else { return }
    // Only picks the pane; dualPane is the user's preference and stays as it is.
    paneSelection = "chat"
    await newConversation()
  }

  func selectConversation(_ conversationID: String) {
    guard let projectID = activeProjectID else { return }
    activeConversation[projectID] = conversationID
    restoreAgentHistory()
  }

  func renameConversation(_ conversationID: String, to title: String, in targetProject: String? = nil) async {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let projectID = targetProject ?? activeProjectID else { return }
    guard await awaitBackend() else { return }
    do {
      _ = try await projectClient.renameConversation(projectID, conversationID, to: trimmed)
      await refreshConversations(projectID)
    } catch {
      notifyProject(L("重命名对话失败：", "Couldn't rename the chat: ") + error.localizedDescription)
    }
  }

  /// Asks first: it takes the whole history and can't be undone.
  func deleteConversation(_ conversationID: String, in targetProject: String? = nil) async {
    guard let projectID = targetProject ?? activeProjectID else { return }
    let title =
      conversations[projectID]?.first { $0.id == conversationID }?.displayTitle ?? L("这条对话", "this chat")
    let alert = NSAlert()
    alert.messageText = L("删除对话「\(title)」？", "Delete the chat “\(title)”?")
    alert.informativeText = L("这段谈话的提问、回答与工具记录都会被删除，无法撤销。项目本身不受影响。",
                              "Its questions, answers and tool records will be deleted. This can't be undone. "
                                + "The project itself isn't affected.")
    alert.alertStyle = .warning
    alert.addButton(withTitle: L("删除", "Delete"))
    alert.addButton(withTitle: L("取消", "Cancel"))
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    guard await awaitBackend() else { return }
    do {
      try await projectClient.deleteConversation(projectID, conversationID)
      // drop the session too, or a reused id gets a stale transcript
      forgetSession(projectID: projectID, conversation: conversationID)
      if activeConversation[projectID] == conversationID {
        activeConversation.removeValue(forKey: projectID)
      }
      await refreshConversations(projectID)
      if activeProjectID == projectID { restoreAgentHistory() }
    } catch {
      notifyProject(L("删除对话失败：", "Couldn't delete the chat: ") + error.localizedDescription)
    }
  }

  /// The backend returns the raw event log (the authoritative record); it is written as is, without
  /// decoding and re-encoding.
  func exportConversation(_ conversationID: String, in targetProject: String? = nil) async {
    guard let projectID = targetProject ?? activeProjectID,
      let project = projects.first(where: { $0.id == projectID }) else { return }
    guard await awaitBackend() else { return }
    let data: Data
    do {
      data = try await projectClient.exportConversation(projectID, conversationID)
    } catch {
      notifyProject(L("导出失败：", "Export failed: ") + error.localizedDescription)
      return
    }

    let title =
      conversations[projectID]?.first { $0.id == conversationID }?.displayTitle ?? L("对话", "Chat")
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = Self.exportFilename(project: project.displayTitle, conversation: title)
    panel.message = L("导出「\(title)」", "Export “\(title)”")
    panel.prompt = L("导出", "Export")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try data.write(to: url)
      notifyProject(L("已导出到 \(url.lastPathComponent)", "Exported to \(url.lastPathComponent)"))
    } catch {
      notifyProject(L("写入失败：", "Couldn't write the file: ") + error.localizedDescription)
    }
  }

  /// `<project> · <conversation>.json`. The project is included because exports leave the machine.
  /// Slashes are replaced: titles do contain them ("A/B testing").
  static func exportFilename(project: String, conversation: String) -> String {
    func safe(_ text: String) -> String {
      text.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
    }
    let stem = "\(safe(project)) · \(safe(conversation))"
    return String(stem.prefix(100)) + ".json"
  }
}
