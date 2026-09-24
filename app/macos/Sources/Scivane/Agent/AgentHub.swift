import AppKit
import Foundation

/// Agent 的接线：provider 列表、凭据注入、发问、批准。
///
/// 状态在 AppModel 里，这里只放行为（与 ProjectWorkspace 同一个路数）。
@MainActor
extension AppModel {

  /// 设置页要显示的 provider 概要。**不含任何凭据原文** ——
  /// 后端的 `describe_all()` 也刻意不返回它。
  struct ProviderSummary: Identifiable, Decodable, Equatable {
    let id: String
    let label: String
    let model: String
    let baseUrl: String
    /// 三套协议之一。编辑时要回填它，不能猜。
    let proto: String
    /// 后端那边有没有凭据（环境变量 / 运行时注入 / 凭据文件，任一）。
    let hasCredential: Bool
    /// 这个模型的上下文窗口有多大。**可选** —— 没填就不画余量条。
    ///
    /// 不猜：这个系统里没有「厂商」概念，同一个模型名在不同网关后面可能是
    /// 不同的窗口，**猜错比不显示更糟** —— 用户会照着一个假的余量规划对话。
    let contextWindow: Int?
    /// 推理预算档位（none / low / medium / high）。
    ///
    /// **放在 provider 上而不是全局**：同一个系统里可能同时接着一个推理模型
    /// 和一个普通模型，给后者传档位只会被忽略或者直接报错。
    let reasoning: String
    /// 这张卡的 key 从哪来：`own` 或 `macro:<编号>`。**不是秘密，只是引用。**
    let credentialRef: String

    /// 界面上叫它什么。昵称是用户自己起的，没起就退回标识 ——
    /// **不要退回模型 id**，那串东西是给机器看的。
    var displayName: String { label.isEmpty ? id : label }

    private enum CodingKeys: String, CodingKey {
      case id, label, model, reasoning
      case proto = "protocol"
      case credentialRef = "credential_ref"
      case baseUrl = "base_url"
      case hasCredential = "has_credential"
      case contextWindow = "context_window"
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
      reasoning = (try? c.decode(String.self, forKey: .reasoning)) ?? ProviderDefaults.reasoning
      credentialRef = (try? c.decode(String.self, forKey: .credentialRef)) ?? "own"
    }

    /// 给预览与离屏验证造样本用。真实数据一律从后端解码。
    init(
      id: String, label: String, model: String, baseUrl: String,
      proto: String = ProviderDefaults.proto, hasCredential: Bool = false,
      contextWindow: Int? = nil, reasoning: String = ProviderDefaults.reasoning,
      credentialRef: String = "own"
    ) {
      self.contextWindow = contextWindow
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

  /// 新建 provider 时的默认值。
  ///
  /// 用当前这套 OpenRouter 配置当起点 —— 它是验证过能跑通的，
  /// 让第一次配的人有个能改的样板，而不是面对四个空框。
  enum ProviderDefaults {
    static let id = "openrouter"
    static let label = "OpenRouter"
    static let proto = "openai"
    static let baseURL = "https://openrouter.ai/api/v1"
    static let model = "qwen/qwen3.8-flash"
    /// 默认档位。取 medium 而不是 low：论文场景里「核对公式和代码是否等价」
    /// 这类活儿确实需要推理，砍到最低会让结论变浅。
    static let reasoning = "medium"
  }

  /// 推理预算的四档。值与后端 `REASONING_LEVELS` 一一对应 ——
  /// **改一边必须改另一边**，对不上的表现是保存之后悄悄回到默认。
  ///
  /// 是计算属性而不是 `static let`：里面的字要跟着界面语言换，
  /// `static let` 在第一次读的时候就把那一刻的语言定死了。
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

  /// 三套协议。**「厂商」在这个系统里不是一个概念** ——
  /// 它就是「协议 + 地址 + 模型名」的组合：接 DeepSeek 是
  /// openai + api.deepseek.com/v1，接本地 Ollama 是 openai + localhost:11434/v1，
  /// 两者共用同一个适配器。所以界面上问的也是这三样，不是「选一个厂商」。
  static var protocols: [(id: String, label: String, hint: String)] {
    [
      ("openai", L("OpenAI 兼容", "OpenAI-compatible"),
       L("绝大多数都走这个：OpenAI、DeepSeek、Kimi、智谱、通义、硅基流动、OpenRouter、Ollama、vLLM",
         "Most providers use this: OpenAI, DeepSeek, Kimi, Zhipu, Qwen, SiliconFlow, OpenRouter, Ollama, vLLM")),
      ("anthropic", "Anthropic", L("Claude 的 Messages 接口", "Claude's Messages API")),
      ("gemini", "Google Gemini", L("Gemini 的 generateContent 接口", "Gemini's generateContent API")),
    ]
  }

  // MARK: - provider

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

  /// 三张预置卡：OpenRouter / DeepSeek / OpenAI，地址与协议都填好，只差 key。
  ///
  /// **只建一次**（记一个标记）。不记的话，用户把三张都删掉之后它们会在下次
  /// 启动时原样长回来 —— 那不是「预置」，是「删不掉」。
  ///
  /// 模型名给的是各家当下的通用款，**用户几乎一定会改** ——
  /// 填一个能跑的默认值，比留空让人对着一个必填框发愣要好。
  private func seedPresetsOnce() async {
    // **只有真 App 能建卡。** 这件事是写盘（providers.json）+ 起后端，
    // 而 `refreshProviders()` 在离屏验证里也会被调到 —— 那边既没有把落盘路径
    // 引开、也不该凭空起一个占着 8710 的后端。挂在只读刷新上的副作用，
    // 症状是「跑一次验证，用户的真实配置里多出三张卡」。
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

  /// 预置卡的内容。`window` 填的是各家文档上的公开值，填了才画余量条；
  /// 拿不准的留空 —— **猜错比不显示更糟**（见 ProviderSummary.contextWindow）。
  ///
  /// 显示名按**建卡那一刻**的界面语言写进卡里（它是用户可改的数据，之后不再跟着换）。
  static var presets: [(id: String, label: String, model: String, baseURL: String, window: Int?)] {
    [
      // **三个不同的接入点，不是三个模型。** 中转站与官方的地址各不相同，
      // 而地址正是新建一张卡时最容易填错、也最不该让人去查文档的东西。
      // OpenRouter 那张给 `openrouter/auto`（它自己的路由模型）——
      // 填某一家的模型会让这张卡看起来像另一张的重复。
      ("openrouter", "OpenRouter", "openrouter/auto", "https://openrouter.ai/api/v1", nil),
      ("deepseek", L("DeepSeek 官方", "DeepSeek Official"), "deepseek-chat", "https://api.deepseek.com/v1", 128_000),
      ("openai", L("OpenAI 官方", "OpenAI Official"), "gpt-5.2", "https://api.openai.com/v1", nil),
    ]
  }

  /// 把 Keychain 里的 key 注入后端。
  ///
  /// **走运行时接口而不是启动时的环境变量**，理由有三：
  ///
  /// 1. 进程环境是可读的 —— `ps -E` 能看到同一用户下任何进程的环境变量，
  ///    把 key 摆在那里等于让用户自己跑的任何程序都能顺手读走
  /// 2. 后端会因为「轻量 → 完整」升级而重启（加载 OCR 模型那次）。
  ///    环境变量那条路要在每个重启分支上重新铺一遍；走接口只要在
  ///    「后端就绪」这一个点上补一次
  /// 3. 在设置里换了 key 立刻生效，不必重启后端
  ///
  /// 注入之后把 provider 记进 `injectedProviders`，后端重启时清空重来。
  func injectCredentials() async {
    // 后端重启过（比如为了 OCR 从轻量升级到完整）就得重新注入 ——
    // 凭据只活在那个进程的内存里
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
      // 失败不提示：这是后台补齐，真有问题会在「测试连接」或提问时说清楚。
      // **绝不把 secret 写进任何日志或错误消息。**
      if let (_, response) = try? await URLSession.shared.data(for: request),
        (response as? HTTPURLResponse)?.statusCode == 200 {
        injectedProviders.insert(provider.id)
      }
    }
  }

  /// 这张卡实际该用哪把 key。
  ///
  /// **解析发生在 App 这一侧，后端从头到尾不知道「宏观 key」存在** ——
  /// 它只会收到一把解析好的明文（走 `/credential`，只活在它的内存里）。
  /// 这样红线（key 不进 providers.json、不进日志）一个字都不用改。
  static func secret(for provider: ProviderSummary) -> String? {
    if provider.credentialRef.hasPrefix("macro:") {
      return MacroKeys.secret(id: String(provider.credentialRef.dropFirst(6)))
    }
    return Keychain.secret(provider: provider.id)
  }

  /// 这张卡现在有没有可用的 key。**界面据此显示「未配置」。**
  ///
  /// 用共享 key 的卡片要看那把共享 key 在不在 —— 只看自己名下的条目会让
  /// 一张配好的卡显示成未配置，用户会去重填一遍，反而把共享那把覆盖掉。
  static func hasKey(_ provider: ProviderSummary) -> Bool {
    secret(for: provider) != nil
  }

  /// 保存 key：写 Keychain，然后立刻注入后端。
  func saveCredential(_ secret: String, provider: String) async -> Bool {
    guard Keychain.set(secret, provider: provider) else { return false }
    injectedProviders.remove(provider)
    await injectCredentials()
    await refreshProviders()
    return true
  }

  /// 新增或改写一个 provider。**后端会落盘**（写 providers.json），
  /// 所以改完重启还在 —— 落盘的路径只在后端的 config.py 里定义一处，
  /// 这边不重复那个路径。
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
    // 换了地址或模型，之前注入的凭据仍然属于这个 id，但后端可能换了实例，
    // 重新注入一次最省心
    injectedProviders.remove(identifier)
    await refreshProviders()
    agentProvider = identifier
    return (true, L("已保存", "Saved"))
  }

  /// 删掉一个 provider，连同它在钥匙串里的 key。
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

  /// 「测试连接」。返回一句能直接显示给用户的话。
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
    // 后端的错误码是稳定的，这里翻成人话。**不回显任何凭据原文。**
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

  /// 当前 provider 声明的上下文窗口。没填就是 nil，界面据此决定画不画余量条。
  var activeContextWindow: Int? {
    providers.first { $0.id == activeProviderID }?.contextWindow
  }

  // MARK: - 用户上传的材料

  /// 拉一次这个项目 `files/` 里的清单。
  func refreshProjectFiles(_ projectID: String) async {
    guard await awaitBackend(quiet: true) else { return }
    guard let found = try? await projectClient.files(projectID) else { return }
    projectFiles[projectID] = found
  }

  /// 把一批本机文件复制进项目的 `files/`。
  ///
  /// 一次拖进来几个就逐个送 —— 失败的那个单独报，不要因为一个坏文件
  /// 让其余几个也白拖一次。
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

  // MARK: - 发问

  var canAskAgent: Bool {
    guard !agentProvider.isEmpty else { return false }
    // 书房那层不需要正文
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

  /// 这一刻该用哪张卡。
  ///
  /// **每条对话各记各的**：优先用这条对话选定的那张；没选过（老对话、
  /// 刚建的新对话）就回落到全局默认。指向一张已经被删掉的卡时也回落 ——
  /// 否则发问会以「没有这个 provider」失败，而用户完全看不出为什么。
  var activeProviderID: String {
    if let chosen = activeConversationRecord?.provider,
      providers.contains(where: { $0.id == chosen }) {
      return chosen
    }
    return agentProvider
  }

  /// 当前这条对话的记录（书房层没有对话，所以可能是 nil）。
  var activeConversationRecord: Conversation? {
    guard let projectID = activeProjectID, let current = activeConversation[projectID]
    else { return nil }
    return conversations[projectID]?.first { $0.id == current }
  }

  /// 在聊天框里换一张卡。写进这条对话的日志，所以下次打开还记得。
  func useProvider(_ providerID: String) {
    guard let projectID = activeProjectID,
      let conversationID = activeConversation[projectID]
    else {
      // 书房层没有对话可记，只能改全局默认 —— 那一层本来也只有一问一答。
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

  /// 进入项目、切回书房、或换一条对话时把那一段历史补回来。
  func restoreAgentHistory() {
    let session = agentSession
    Task {
      guard await awaitBackend(quiet: true) else { return }
      await session.restore(base: backend.apiBase)
    }
  }

  // MARK: - 对话
  //
  // 一个项目可以有多条对话，各自一段历史。切换条在 AgentPanel 顶部。
  // 清单的唯一来源是后端（它从对话文件本身算出来），这边不另存一份 ——
  // 两份必然漂移，而漂移的那份会让用户看到一个不存在的对话。

  /// 拉一次这个项目的对话清单，并确保有一条被选中。
  ///
  /// **一条都没有时不在这里建。** 建在发问那一刻（后端的
  /// `ensure_conversation` 会接上），否则光是点开 Agent 栏就会在磁盘上
  /// 留下一条空对话。
  @discardableResult
  func refreshConversations(_ projectID: String) async -> Bool {
    guard await awaitBackend(quiet: true) else { return false }
    guard let found = try? await projectClient.conversations(projectID) else { return false }
    conversations[projectID] = found
    // 选中的那条被删掉了（或者还没选过）就回到最近一条
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

  /// 开一条新对话并切过去。
  ///
  /// 当前这条要是还没说过话，就原地不动 —— 连点几下「新对话」不该在磁盘上
  /// 堆出一串空文件，而用户想要的「一张白纸」他已经看着了。
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

  /// 从侧栏点开某个项目的某条对话 —— **那个项目可能还不是当前项目**。
  ///
  /// 先进项目再选对话，顺序不能反：`selectConversation` 写的是
  /// `activeConversation[activeProjectID]`，项目没切过去的话会写到别人头上。
  func openConversation(project: Project, conversation: String) async {
    guard !sidebarNavigationBusy else { return }
    sidebarNavigationBusy = true
    defer { sidebarNavigationBusy = false }
    if activeProjectID != project.id { await enterProject(project) }
    // 进入失败不能把目标对话写进上一个项目；点击对话也必须真的显示 Agent。
    guard activeProjectID == project.id else { return }
    // 只决定「看哪一栏」。**不碰 dualPane** —— 那是用户偏好，顺手改掉的话，
    // 用户刚切成双栏、点一下对话又被打回单栏。
    paneSelection = "chat"
    selectConversation(conversation)
  }

  /// 在某个项目里开一条新对话（同样可能不是当前项目）。
  func newConversation(in project: Project) async {
    guard !sidebarNavigationBusy else { return }
    sidebarNavigationBusy = true
    defer { sidebarNavigationBusy = false }
    if activeProjectID != project.id { await enterProject(project) }
    guard activeProjectID == project.id else { return }
    // 只决定「看哪一栏」。**不碰 dualPane** —— 那是用户偏好，顺手改掉的话，
    // 用户刚切成双栏、点一下对话又被打回单栏。
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

  /// 删掉一条对话。**问一次** —— 它带着这段谈话的全部历史，删了不可撤销。
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
      // 会话实例也要丢掉，否则同 id 再出现时会拿到一份陈旧的记录
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

  /// 导出一条对话为 .json 文件。
  ///
  /// 后端给的是**原始事件流**（权威记录，能重建模型历史与界面记录两种投影），
  /// 这里原样写盘，不在中间解码再编码。
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

  /// 导出文件的默认名字：`<项目> · <对话>.json`。
  ///
  /// 把项目名也放进去：导出的文件多半会离开这台机器，只叫「对话.json」
  /// 的话，几个月后没人知道它属于哪篇论文。
  /// 路径分隔符要换掉 —— 论文标题里真的会出现斜杠（"A/B testing"）。
  static func exportFilename(project: String, conversation: String) -> String {
    func safe(_ text: String) -> String {
      text.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
    }
    let stem = "\(safe(project)) · \(safe(conversation))"
    return String(stem.prefix(100)) + ".json"
  }
}
