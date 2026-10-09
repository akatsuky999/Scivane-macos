import SwiftUI

struct SettingsView: View {
    @ObservedObject var backend: BackendManager
    @ObservedObject var model: AppModel
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    /// normally 0; offscreen checks can open another tab
    var initialTab = 0
    /// for offscreen checks: the expanded card is the layout most likely to break
    var initialExpanded: String?
    @State private var tab = 0
    @State private var projectPath: String = ""
    @State private var runtimePath: String = ""
    @State private var idleMinutes: Double = 5

    // Models
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

    /// the reported window when there is one (empty keeps it), otherwise an example
    private var windowPrompt: String {
        if let detected = model.providers.first(where: { $0.id == draft.id })?.detectedWindow {
            return L("自动 \(detected)", "Auto \(detected)")
        }
        return L("可留空，例如 1000000", "Optional, e.g. 1000000")
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

    /// Models: protocol, address and model name rather than a vendor list. Keys can only be replaced,
    /// never shown or copied; Test connection checks them.
    @ViewBuilder
    private var modelTab: some View {
        Section(L("共享 key", "Shared Keys")) {
            MacroKeyPanel(entries: $macroKeys, usage: macroUsage) {
                Task { await model.injectCredentials() }
            }
        }

        Section(L("模型卡", "Model Cards")) {
            if model.providers.isEmpty && !creating {
                Text(L("还没有模型卡", "No model cards yet")).font(.uiCaption).foregroundStyle(Palette.inkFaint)
            }
            // No frame per card: the Form section is already a container. Hairlines between cards, a faint
            // background on the default one.
            ForEach(Array(model.providers.enumerated()), id: \.element.id) { index, entry in
                VStack(alignment: .leading, spacing: 0) {
                    if index > 0 { Hairline() }
                    ProviderCardHeader(
                        provider: entry,
                        isDefault: entry.id == model.agentProvider,
                        isExpanded: expanded == entry.id,
                        keyState: keyState(entry),
                        onUse: { model.agentProvider = entry.id },
                        onToggle: { toggle(entry.id) })
                    .background(entry.id == model.agentProvider
                                ? Palette.accent.opacity(0.055) : Color.clear)
                    if expanded == entry.id {
                        editor(creatingNew: false)
                    }
                }
            }

            if creating {
                VStack(alignment: .leading, spacing: 0) {
                    if !model.providers.isEmpty { Hairline() }
                    editor(creatingNew: true)
                }
            } else {
                // The presets stay reachable here; the first launch only creates them when there are no cards,
                // and base URLs shouldn't require reading docs.
                Menu {
                    ForEach(AppModel.presets, id: \.id) { preset in
                        Button(preset.label) { startNew(preset) }
                    }
                    Divider()
                    Button(L("自定义", "Custom")) { startNew(nil) }
                } label: {
                    Text(L("＋ 新建卡片", "＋ New Card"))
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
    }

    /// Editor of the expanded card.
    @ViewBuilder
    private func editor(creatingNew: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if creatingNew {
                labelled(L("标识", "ID")) {
                    TextField("", text: $draft.id, prompt: Text(L("英文短名，如 openrouter", "A short name, e.g. openrouter")))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                }
            }
            labelled(L("显示名", "Name")) {
                TextField("", text: $draft.label, prompt: Text(L("留空就用标识", "Leave empty to use the ID")))
                    .textFieldStyle(.roundedBorder).font(.system(size: 11.5))
            }
            labelled(L("协议", "Protocol")) {
                Picker("", selection: $draft.proto) {
                    ForEach(AppModel.protocols, id: \.id) { entry in
                        Text(entry.label).tag(entry.id)
                    }
                }.labelsHidden()
            }
            labelled(L("接入地址", "Base URL")) {
                TextField("", text: $draft.baseURL, prompt: Text("https://…/v1"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
            }
            labelled(L("模型名", "Model")) {
                TextField("", text: $draft.model, prompt: Text(L("厂商文档里的那个 id", "The model ID from the provider's docs")))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
            }
            labelled(L("上下文窗口", "Context")) {
                TextField("", text: $draft.window, prompt: Text(windowPrompt))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
            }
            if !creatingNew {
                labelled(L("看图", "Images")) { visionRow }
            }
            keyEditor()

            HStack(spacing: 10) {
                Button(creatingNew ? L("创建", "Create") : L("保存改动", "Save Changes")) { save() }
                    .buttonStyle(StudioButtonStyle(primary: true))
                    .disabled(draft.id.trimmingCharacters(in: .whitespaces).isEmpty
                              || draft.model.trimmingCharacters(in: .whitespaces).isEmpty)
                if creatingNew {
                    Button(L("取消", "Cancel")) { creating = false; expanded = nil }
                } else {
                    Button(testing ? L("测试中…", "Testing…") : L("测试连接", "Test Connection")) {
                        testing = true
                        Task {
                            testResult = await model.testProvider(draft.id)
                            testing = false
                        }
                    }.disabled(testing)
                    Button(L("删除", "Delete")) { confirmingDelete = true }
                        .foregroundStyle(Palette.danger)
                }
                if let result = saveResult ?? testResult {
                    Label(result.message,
                          systemImage: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.uiCaption)
                        .foregroundStyle(result.ok ? Palette.accent : Palette.danger)
                }
                Spacer()
            }
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
        .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.sunk.opacity(0.35))
    }

    /// Whether the card's model reads images: recognising an original with it, and attaching images
    /// in a chat, both need it. Asked by showing the model one, never guessed from its name.
    @ViewBuilder
    private var visionRow: some View {
        HStack(spacing: 8) {
            if checkingVision {
                ProgressView().controlSize(.mini)
            } else if let failure = visionFailure {
                Text(failure.text).font(.uiCaption).foregroundStyle(Palette.danger).lineLimit(1)
            } else {
                switch model.providers.first(where: { $0.id == draft.id })?.vision {
                case true?:
                    Label(L("能看图", "Sees images"), systemImage: "eye").font(.uiCaption)
                        .foregroundStyle(Palette.accent)
                case false?:
                    Label(L("看不到图", "Can't see images"), systemImage: "eye.slash").font(.uiCaption)
                        .foregroundStyle(Palette.inkSoft)
                case nil:
                    Text(L("未检测", "Not checked")).font(.uiCaption).foregroundStyle(Palette.inkFaint)
                }
            }
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
            .disabled(checkingVision)
        }
    }

    /// Shared key, or one stored on this card.
    @ViewBuilder
    private func keyEditor() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            labelled("API key") {
                Picker("", selection: $draft.credentialRef) {
                    Text(L("这张卡自己填", "This card's own key")).tag("own")
                    ForEach(macroKeys) { key in
                        Text(key.note.isEmpty ? L("共享 \(key.id)", "Shared \(key.id)") : "\(key.id) · \(key.note)")
                            .tag("macro:\(key.id)")
                    }
                }.labelsHidden()
            }
            if draft.credentialRef == "own" {
                labelled("") {
                  HStack(spacing: 6) {
                    SecureField(
                        "", text: $secretDraft,
                        prompt: Text(Keychain.has(provider: draft.id)
                                     ? L("已保存 —— 填新的会覆盖", "Saved — a new one replaces it")
                                     : L("粘贴 API key", "Paste API key")))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .onSubmit { saveSecret() }
                    Button(L("保存 key", "Save Key"), action: saveSecret)
                        .disabled(secretDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if Keychain.has(provider: draft.id) {
                        Button(L("清除", "Clear")) {
                            Keychain.clear(provider: draft.id)
                            model.injectedProviders.remove(draft.id)
                            testResult = nil
                        }.buttonStyle(.link).foregroundStyle(Palette.danger)
                    }
                  }
                }
            } else if let picked = macroKeys.first(where: { "macro:\($0.id)" == draft.credentialRef }) {
                Text(picked.masked)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.inkFaint)
            } else {
                Text(L("共享 key 已不存在", "That shared key no longer exists"))
                    .font(.uiCaption).foregroundStyle(Palette.danger)
            }
        }
    }

    /// Label and control laid out by hand: Form's own layout pushes placeholders out of the field in a
    /// narrow window.
    private func labelled<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.uiCaption).foregroundStyle(Palette.inkSoft)
                .frame(width: 60, alignment: .leading)
            // Form right-aligns controls and their text; pin the control to the remaining width and the
            // text to the leading edge.
            content()
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 360, alignment: .leading)
            Spacer(minLength: 0)
        }
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("偏好设置", "Settings")).font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.ink)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Scivane").font(.custom("Baskerville", size: 18))
                    Text(L("构建 ", "Build ")
                         + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? L("开发版", "dev")))
                        .font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
                }.foregroundStyle(Palette.inkFaint)
            }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 8)
            .onAppear { if tab == 0 && initialTab != 0 { tab = initialTab } }
Picker(L("设置分类", "Settings Section"), selection: $tab) {
    Text(L("通用", "General")).tag(0)
    Text(L("模型", "Models")).tag(2)
    Text(L("本地引擎", "Local Engine")).tag(1)
}.pickerStyle(.segmented).labelsHidden().frame(width: 300).padding(.vertical, 10)
Form {
if tab == 0 {

            // language first, so someone who switched by mistake finds it (the title is bilingual)
            LanguageSettings(busy: model.hasBackendWork)

            Section(L("外观", "Appearance")) {
                Picker(L("主题", "Theme"), selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Label(option.label, systemImage: option.symbol).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, value in value.apply() }
            }

            }
            if tab == 2 {
                modelTab
                    // reread shared keys on every visit: they live in UserDefaults and may have changed elsewhere
                    .onAppear {
                        macroKeys = MacroKeys.all
                        if let initialExpanded, expanded == nil { toggle(initialExpanded) }
                    }
            }
            if tab == 1 {
            Section(L("目录", "Locations")) {
                LabeledContent(L("项目目录", "Scivane Folder")) {
                    HStack(spacing: 6) {
                        TextField("", text: $projectPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                        Button(L("选择…", "Choose…")) {
                            choose($projectPath, message: L("选择 Scivane 项目目录", "Choose the Scivane folder"))
                        }
                    }
                }
                Text(L("启动识别服务的位置", "Where the recognition service starts from"))
                    .font(.uiCaption)
                    .foregroundStyle(Palette.inkFaint)

                LabeledContent(L("模型运行时", "Model Runtime")) {
                    HStack(spacing: 6) {
                        TextField("", text: $runtimePath, prompt: Text(L("留空：自动发现", "Empty: find it automatically")))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                        Button(L("选择…", "Choose…")) {
                            choose($runtimePath, message: L("选择模型运行时目录", "Choose the model runtime folder"))
                        }
                    }
                }
                Text(L("改完点重启引擎生效", "Restart the engine for changes to take effect"))
                    .font(.uiCaption)
                    .foregroundStyle(Palette.inkFaint)
            }

            Section {
                LabeledContent(L("引擎状态", "Engine Status")) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(backend.state.isReady ? Color.green : Palette.accent)
                            .frame(width: 6, height: 6)
                        Text(statusText).font(.uiBody).foregroundStyle(Palette.inkSoft)
                        Spacer()
                        Button(L("重启引擎", "Restart Engine")) { apply() }
                    }
                }
                OCRRuntimeRow(installer: model.ocrInstaller)
            }

            Section {
                LabeledContent(L("闲置自动停", "Stop When Idle")) {
                    Picker("", selection: $idleMinutes) {
                        Text(L("2 分钟", "2 minutes")).tag(2.0)
                        Text(L("5 分钟", "5 minutes")).tag(5.0)
                        Text(L("15 分钟", "15 minutes")).tag(15.0)
                        Text(L("不自动停", "Never")).tag(0.0)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .onChange(of: idleMinutes) { _, new in
                        backend.idleTimeout = new * 60
                    }
                }
                Text(L("闲置时释放模型内存，下次识别自动唤醒",
                       "Frees the model's memory when idle; it wakes up again for the next OCR"))
                    .font(.uiCaption)
                    .foregroundStyle(Palette.inkFaint)
            }

            }
            if tab == 0 {
            Section {
                LabeledContent(L("自动导出", "Auto Export")) {
                    HStack(spacing: 6) {
                        Text(model.autoExportDirectory?.path ?? L("未设置", "Not set"))
                            .font(.uiCaption)
                            .foregroundStyle(model.autoExportDirectory == nil ? Palette.inkFaint : Palette.inkSoft)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button(L("选择…", "Choose…")) { model.chooseAutoExportDirectory() }
                        if model.autoExportDirectory != nil {
                            Button(L("清除", "Clear")) { model.autoExportDirectory = nil }
                        }
                    }
                }
                Text(L("识别完自动写入", "Written automatically once OCR finishes"))
                    .font(.uiCaption)
                    .foregroundStyle(Palette.inkFaint)
            }
        }
            }
        .formStyle(.grouped)
        }
        .background(Palette.paper)
        .tint(Palette.accent)
        .frame(width: 540, height: 550)
        .onAppear {
            projectPath = (try? backend.install.get())?.root.path ?? ""
            runtimePath = backend.runtimeOverride?.path ?? ""
            idleMinutes = backend.idleTimeout / 60
        }
    }

    private var statusText: String {
        switch backend.state {
        case .idle:
            return backend.stoppedForIdle
                ? L("已闲置自动停止（下次识别自动拉起）", "Stopped after being idle (starts again for the next OCR)")
                : L("未启动", "Not started")
        case .launching(let s): return s.text
        case .ready:            return L("运行中 · ", "Running · ") + backend.apiBase.absoluteString
        case .failed(let m):    return m.text
        }
    }

    private func choose(_ binding: Binding<String>, message: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = message
        panel.prompt = L("选择", "Choose")
        if panel.runModal() == .OK, let url = panel.url { binding.wrappedValue = url.path }
    }

    private func apply() {
        backend.useBackendLocation(projectPath)
        let runtime = runtimePath.trimmingCharacters(in: .whitespaces)
        backend.runtimeOverride = runtime.isEmpty ? nil : URL(fileURLWithPath: runtime)
        backend.restart()
    }
}
