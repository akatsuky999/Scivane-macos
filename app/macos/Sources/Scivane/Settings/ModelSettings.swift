import SwiftUI

/// Settings > Models: protocol, address and model name rather than a vendor list. Keys can only be
/// replaced, never shown or copied; Test Connection checks them.
struct ModelSettings: View {
  @ObservedObject var model: AppModel
  /// for offscreen checks: the expanded card is the layout most likely to break
  var initialExpanded: String?

  @State private var secretDraft = ""
  @State private var testing = false
  @State private var testResult: (ok: Bool, message: String)?
  @State private var checkingVision = false
  /// why a check couldn't decide (no key, no quota...)
  @State private var visionFailure: UIText?
  @State private var saveResult: (ok: Bool, message: String)?

  /// Not model.providers: that is the backend's state, and editing it directly would make the list
  /// jump while typing.
  @State private var draft = ProviderDraft()
  @State private var creating = false
  @State private var confirmingDelete = false
  /// one at a time: several identical forms make it unclear which one is being edited
  @State private var expanded: String?
  /// id, note and mask only; no secrets
  @State private var macroKeys: [MacroKeys.Entry] = MacroKeys.all

  private struct ProviderDraft {
    var id = ""
    var label = ""
    var proto = AppModel.ProviderDefaults.proto
    var model = ""
    var baseURL = ""
    /// optional; empty uses the endpoint's reported window
    var window = ""
    var reasoning = AppModel.ProviderDefaults.reasoning
    /// `own` or `macro:<id>`
    var credentialRef = "own"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      SettingsTitle(text: L("模型", "Models")) { newCardMenu }

      SettingsSection(title: L("模型卡", "Model Cards")) {
        VStack(spacing: 0) {
          if model.providers.isEmpty && !creating {
            SettingsRow(title: L("还没有模型卡", "No model cards yet")) { EmptyView() }
          }
          ForEach(Array(model.providers.enumerated()), id: \.element.id) { index, entry in
            if index > 0 { SettingsDivider() }
            VStack(spacing: 0) {
              ProviderCardHeader(
                provider: entry,
                isDefault: entry.id == model.agentProvider,
                isExpanded: expanded == entry.id,
                keyState: keyState(entry),
                onUse: { model.agentProvider = entry.id },
                onToggle: { toggle(entry.id) })
              if expanded == entry.id { editor(creatingNew: false) }
            }
            .background(expanded == entry.id ? Palette.ink.opacity(0.022) : .clear)
          }
          if creating {
            if !model.providers.isEmpty { SettingsDivider() }
            editor(creatingNew: true)
          }
        }
        .cardSurface()
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      }

      SettingsSection(title: L("共享 key", "Shared Keys")) {
        MacroKeyPanel(entries: $macroKeys, usage: macroUsage) {
          Task { await model.injectCredentials() }
        }
      }
    }
    // shared keys live in UserDefaults and may have changed elsewhere
    .onAppear {
      macroKeys = MacroKeys.all
      if let initialExpanded, expanded == nil { toggle(initialExpanded) }
    }
  }

  // MARK: - New card

  /// The presets stay reachable here; the first launch only creates them when there are no cards,
  /// and base URLs shouldn't require reading docs.
  private var newCardMenu: some View {
    Menu {
      ForEach(AppModel.presets, id: \.id) { preset in
        Button(preset.label) { startNew(preset) }
      }
      Divider()
      Button(L("自定义", "Custom")) { startNew(nil) }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "plus").font(.system(size: 10.5, weight: .bold))
        Text(L("新建模型卡", "New Model Card")).font(.system(size: 12.5, weight: .semibold))
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.8)
      }
      .foregroundStyle(Palette.paper)
      .padding(.horizontal, 12).frame(height: 30)
      .background(Palette.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
      .contentShape(Rectangle())
    }
    // the native menu style would keep only the first text, without its size, weight or fill
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    .disabled(creating)
  }

  private func startNew(_ preset: (id: String, label: String, model: String,
                                   baseURL: String, window: Int?)? = nil) {
    // suffix an existing id, or Create would silently overwrite that card
    var identifier = preset?.id ?? ""
    if !identifier.isEmpty, model.providers.contains(where: { $0.id == identifier }) {
      var n = 2
      while model.providers.contains(where: { $0.id == "\(identifier)-\(n)" }) { n += 1 }
      identifier = "\(identifier)-\(n)"
    }
    draft = ProviderDraft(
      id: identifier, label: preset?.label ?? "", proto: AppModel.ProviderDefaults.proto,
      model: preset?.model ?? AppModel.ProviderDefaults.model,
      baseURL: preset?.baseURL ?? AppModel.ProviderDefaults.baseURL,
      window: preset?.window.map(String.init) ?? "",
      reasoning: AppModel.ProviderDefaults.reasoning,
      credentialRef: "own")
    creating = true
    expanded = nil
    secretDraft = ""
    testResult = nil
    saveResult = nil
  }

  // MARK: - Editor

  @ViewBuilder
  private func editor(creatingNew: Bool) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      if creatingNew {
        Text(L("新模型卡", "New Model Card"))
          .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
          .padding(.bottom, 2)
        field(L("标识", "ID")) {
          TextField("", text: $draft.id, prompt: Text(L("英文短名，如 openrouter", "A short name, e.g. openrouter")))
            .settingsField(monospaced: true)
        }
      }
      field(L("显示名", "Name")) {
        TextField("", text: $draft.label, prompt: Text(L("留空就用标识", "Leave empty to use the ID")))
          .settingsField()
      }
      field(L("协议", "Protocol")) {
        PillPicker(options: AppModel.protocols.map(\.id), selection: $draft.proto, height: 24,
                   name: Self.protocolHint) { id, selected in
          Text(Self.protocolName(id))
            .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Palette.ink : Palette.inkSoft)
        }
      }
      field(L("接入地址", "Base URL")) {
        TextField("", text: $draft.baseURL, prompt: Text("https://…/v1")).settingsField(monospaced: true)
      }
      field(L("模型名", "Model")) {
        TextField("", text: $draft.model, prompt: Text(L("厂商文档里的模型 ID", "The model ID from the provider's docs")))
          .settingsField(monospaced: true)
      }
      field(L("上下文窗口", "Context Window")) {
        TextField("", text: $draft.window, prompt: Text(windowPrompt)).settingsField(monospaced: true)
      }
      if !creatingNew {
        field(L("模态", "Modality")) { modalityRow }
      }
      keyEditor()
      footer(creatingNew: creatingNew)
    }
    .padding(.leading, 16).padding(.trailing, 14).padding(.top, creatingNew ? 14 : 4).padding(.bottom, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func footer(creatingNew: Bool) -> some View {
    HStack(spacing: 8) {
      if creatingNew {
        if let result = saveResult { resultLabel(result) }
        Spacer(minLength: 8)
        Button(L("取消", "Cancel")) { creating = false; expanded = nil }
          .buttonStyle(SettingsButtonStyle())
        Button(L("创建", "Create")) { save() }
          .buttonStyle(SettingsButtonStyle(kind: .primary))
          .disabled(!canSave)
      } else {
        Button(testing ? L("测试中…", "Testing…") : L("测试连接", "Test Connection")) {
          testing = true
          Task {
            testResult = await model.testProvider(draft.id)
            testing = false
          }
        }
        .buttonStyle(SettingsButtonStyle())
        .disabled(testing)
        if let result = saveResult ?? testResult { resultLabel(result) }
        Spacer(minLength: 8)
        Button(L("删除", "Delete")) { confirmingDelete = true }
          .buttonStyle(SettingsButtonStyle(kind: .destructive))
        Button(L("保存改动", "Save Changes")) { save() }
          .buttonStyle(SettingsButtonStyle(kind: .primary))
          .disabled(!canSave)
      }
    }
    .padding(.top, 6)
    .confirmationDialog(
      L("删除这张卡？", "Delete this card?"),
      isPresented: $confirmingDelete, titleVisibility: .visible
    ) {
      Button(L("删除，连同它自己的 key", "Delete, Including Its Own Key"), role: .destructive) {
        let target = draft.id
        Task { await model.deleteProvider(target); expanded = nil }
      }
      Button(L("算了", "Cancel"), role: .cancel) {}
    } message: {
      Text(L("这张卡自己的 key 一并清除；共享 key 不受影响。",
             "This card's own key is cleared too; shared keys aren't affected."))
    }
  }

  private var canSave: Bool {
    !draft.id.trimmingCharacters(in: .whitespaces).isEmpty
      && !draft.model.trimmingCharacters(in: .whitespaces).isEmpty
  }

  private func resultLabel(_ result: (ok: Bool, message: String)) -> some View {
    Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
      .font(.system(size: 11.5))
      .foregroundStyle(result.ok ? Palette.ok : Palette.danger)
      .lineLimit(2)
      .help(result.message)
  }

  /// What the card's model takes in: text always, images only once a check has shown it one.
  /// Recognising an original with it, and attaching images in a chat, both need images.
  @ViewBuilder
  private var modalityRow: some View {
    HStack(spacing: 8) {
      ModalityTags(vision: model.providers.first(where: { $0.id == draft.id })?.vision)
      if checkingVision {
        ProgressView().controlSize(.mini)
      } else if let failure = visionFailure {
        Text(failure.text).font(.system(size: 11)).foregroundStyle(Palette.danger).lineLimit(1)
          .help(failure.text)
      }
      Spacer(minLength: 0)
      Button(L("检测", "Check")) {
        let target = draft.id
        checkingVision = true
        visionFailure = nil
        Task {
          let result = await model.checkVision(target)
          checkingVision = false
          visionFailure = result.supported == nil ? result.failure : nil
        }
      }
      .buttonStyle(SettingsButtonStyle())
      .disabled(checkingVision)
      .help(L("看接入点声明的模态；没声明就给模型看一张图", "Read the modalities the endpoint declares, or show the model an image"))
    }
  }

  /// Shared key, or one stored on this card.
  @ViewBuilder
  private func keyEditor() -> some View {
    field("API key") {
      Picker("", selection: $draft.credentialRef) {
        Text(L("这张卡自己填", "This card's own key")).tag("own")
        ForEach(macroKeys) { key in
          Text(key.note.isEmpty ? L("共享 \(key.id)", "Shared \(key.id)") : "\(key.id) · \(key.note)")
            .tag("macro:\(key.id)")
        }
      }
      .labelsHidden().fixedSize()
    }
    if draft.credentialRef == "own" {
      field("") {
        HStack(spacing: 8) {
          SecureField(
            "", text: $secretDraft,
            prompt: Text(Keychain.has(provider: draft.id)
                         ? L("已保存在钥匙串 —— 填新的会覆盖", "Saved in the Keychain — a new one replaces it")
                         : L("粘贴 API key", "Paste API key")))
            .settingsField(monospaced: true)
            .onSubmit { saveSecret() }
          Button(L("保存 key", "Save Key"), action: saveSecret)
            .buttonStyle(SettingsButtonStyle())
            .disabled(secretDraft.trimmingCharacters(in: .whitespaces).isEmpty)
          if Keychain.has(provider: draft.id) {
            Button(L("清除", "Clear")) {
              Keychain.clear(provider: draft.id)
              model.injectedProviders.remove(draft.id)
              testResult = nil
            }
            .buttonStyle(SettingsButtonStyle(kind: .destructive))
          }
        }
      }
    } else if let picked = macroKeys.first(where: { "macro:\($0.id)" == draft.credentialRef }) {
      field("") {
        Text(picked.masked)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(Palette.inkFaint)
      }
    } else {
      field("") {
        Text(L("共享 key 已不存在", "That shared key no longer exists"))
          .font(.system(size: 11)).foregroundStyle(Palette.danger)
      }
    }
  }

  /// Label and control laid out by hand, the label in a fixed column.
  private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: 12) {
      Text(title).font(.system(size: 12)).foregroundStyle(Palette.inkSoft)
        .frame(width: SettingsMetrics.label, alignment: .leading)
      content().frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minHeight: 28)
  }

  // MARK: - State

  /// the reported window when there is one (empty keeps it), otherwise an example
  private var windowPrompt: String {
    if let detected = model.providers.first(where: { $0.id == draft.id })?.detectedWindow {
      return L("自动 \(detected)", "Auto \(detected)")
    }
    return L("可留空，例如 1000000", "Optional, e.g. 1000000")
  }

  static func protocolName(_ id: String) -> String {
    switch id {
    case "openai": return L("OpenAI 兼容", "OpenAI-compatible")
    case "gemini": return "Gemini"
    default: return AppModel.protocols.first { $0.id == id }?.label ?? id
    }
  }

  static func protocolHint(_ id: String) -> String {
    AppModel.protocols.first { $0.id == id }?.hint ?? id
  }

  /// Load a card into the draft, on expanding and after saving.
  private func loadDraft(_ id: String) {
    guard let found = model.providers.first(where: { $0.id == id }) else { return }
    draft = ProviderDraft(
      id: found.id, label: found.label == found.id ? "" : found.label,
      proto: found.proto,
      model: found.model, baseURL: found.baseUrl,
      window: found.contextWindow.map(String.init) ?? "",
      reasoning: found.reasoning,
      credentialRef: found.credentialRef)
    creating = false
    secretDraft = ""
    testResult = nil
    saveResult = nil
    visionFailure = nil
  }

  private func keyState(_ entry: AppModel.ProviderSummary) -> CardKeyState {
    if entry.credentialRef.hasPrefix("macro:") {
      let id = String(entry.credentialRef.dropFirst(6))
      guard let found = macroKeys.first(where: { $0.id == id }) else { return .missing }
      return .macro(id: found.id, note: found.note)
    }
    return Keychain.has(provider: entry.id) ? .own : .missing
  }

  /// cards using each shared key; shown before deleting
  private var macroUsage: [String: Int] {
    var counts: [String: Int] = [:]
    for entry in model.providers where entry.credentialRef.hasPrefix("macro:") {
      counts[String(entry.credentialRef.dropFirst(6)), default: 0] += 1
    }
    return counts
  }

  private func toggle(_ id: String) {
    creating = false
    saveResult = nil
    testResult = nil
    if expanded == id { expanded = nil; return }
    expanded = id
    loadDraft(id)
  }

  private func save() {
    let wasCreating = creating
    Task {
      saveResult = await model.saveProvider(
        id: draft.id, label: draft.label, proto: draft.proto,
        model: draft.model, baseURL: draft.baseURL,
        contextWindow: Int(draft.window.trimmingCharacters(in: .whitespaces)),
        reasoning: draft.reasoning, credentialRef: draft.credentialRef)
      if saveResult?.ok == true {
        if wasCreating { creating = false; expanded = draft.id }
        loadDraft(draft.id)
      }
    }
  }

  private func saveSecret() {
    let secret = secretDraft
    secretDraft = ""
    // Save under the expanded card, not the default one; they used to be the same.
    let target = draft.id
    Task {
      let ok = await model.saveCredential(secret, provider: target)
      testResult = ok ? nil : (false, L("写不进钥匙串", "Couldn't write to the Keychain"))
    }
  }
}
