import SwiftUI

struct SettingsView: View {
    @ObservedObject var backend: BackendManager
    @ObservedObject var model: AppModel
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    /// 打开时停在哪一页。正常使用一律从 0 开始；渲染检查时可以直接停在别的页。
    var initialTab = 0
    /// 打开时哪张卡是展开的。**同样只为渲染检查** —— 展开态是这一页最容易
    /// 排版塌掉的地方（一列输入框加一排按钮），得能直接打开到这个状态来看。
    var initialExpanded: String?
    @State private var tab = 0
    @State private var projectPath: String = ""
    @State private var runtimePath: String = ""
    @State private var idleMinutes: Double = 5

    // --- 模型 ---
    @State private var secretDraft = ""
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?
    @State private var saveResult: (ok: Bool, message: String)?

    /// 正在编辑的那份配置。**不直接改 model.providers** ——
    /// 那是后端的事实，编辑中的草稿是另一回事；混在一起的话打字打到一半
    /// 列表就跳了。
    @State private var draft = ProviderDraft()
    @State private var creating = false
    @State private var confirmingDelete = false
    /// 哪张卡是展开的。**只展开一张** —— 同时摊开三份表单，人会分不清
    /// 正在改的是哪一张，而它们的字段长得一模一样。
    @State private var expanded: String?
    /// 共享 key 的索引（**不含秘密**，只有编号、备注、掩码）。
    @State private var macroKeys: [MacroKeys.Entry] = MacroKeys.all

    private struct ProviderDraft {
        var id = ""
        var label = ""
        var proto = AppModel.ProviderDefaults.proto
        var model = ""
        var baseURL = ""
        /// 上下文窗口，**可留空**。填了输入区才画余量条。
        var window = ""
        /// 推理预算档位。
        var reasoning = AppModel.ProviderDefaults.reasoning
        /// key 从哪来：`own` 或 `macro:<编号>`。
        var credentialRef = "own"
    }

    /// 把某一张卡读进草稿。展开、刚保存完都要走一遍。
    ///
    /// **不直接改 model.providers**：那是后端的事实，编辑中的草稿是另一回事；
    /// 混在一起的话打字打到一半列表就跳了。
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
    }

    private func startNew(_ preset: (id: String, label: String, model: String,
                                     baseURL: String, window: Int?)? = nil) {
        // 已经有同名卡时给个后缀，不然「创建」会静默覆盖掉那一张
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

    /// 模型这一页。
    ///
    /// **不是「选一个厂商」，是填「协议 + 地址 + 模型名」。** 这个系统里
    /// 「厂商」不是一个概念：接 DeepSeek 是 openai + api.deepseek.com/v1，
    /// 接本地 Ollama 是 openai + localhost:11434/v1，两者共用同一个适配器。
    /// 所以只要能给出 URL 和 key，填上模型名就能用。
    ///
    /// 红线：**key 不进日志、不进错误消息、不回显**。
    /// 所以只有「填一个新的」，没有「看一眼现在填的是什么」，也没有复制按钮 ——
    /// 想确认填对没有就点「测试连接」。
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
            // **不给每张卡再套一层圆角框。** Form 的分组本身就是一个容器，
            // 里面再画框就是「框里的框」，最显廉价。
            // 卡与卡之间用一条细线分开；当前默认那张只做一层极淡的底。
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
                // 三个预置接入点也从这里拿得到 —— 首启那次只在「一张卡都没有」时
                // 建，已经配过卡的人本来永远碰不到它们，而**地址正是最不该让人
                // 去翻文档的东西**。
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

    /// 展开的那张卡的编辑区。
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
                TextField("", text: $draft.window, prompt: Text(L("可留空，例如 1000000", "Optional, e.g. 1000000")))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
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

    /// key 从哪来：共享的那把，还是这张卡自己填。
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

    /// 编辑区里「标签 + 控件」的统一排法。Form 自带的那套在窄栏里会把
    /// 占位文字挤到框外面去，看着像排版塌了。
    private func labelled<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.uiCaption).foregroundStyle(Palette.inkSoft)
                .frame(width: 60, alignment: .leading)
            // Form 会把控件推到右边、里面的文字也跟着右对齐 ——
            // 一列右对齐的输入框读起来像排版塌了。两件都要钉：
            // 控件本身占满剩余宽度，文字在控件内部靠左。
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

    /// 每把共享 key 被几张卡引用。删之前要让人看见这个数。
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
        // 存进**这张展开的卡**名下，不是「当前默认那张」——
        // 两者早先是同一个值，改成卡片之后就不是了，照旧写的话
        // 会把 key 存到另一张卡上，而两张卡都显示得好好的。
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

            // 语言放在最前：切错了语言的人第一眼就要看得到它（分节标题两种语言都写）
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
                    // 每次进这一页都重读一次共享 key —— 它存在 UserDefaults 里，
                    // 别处（比如另一个窗口）改过的话这里要跟上。
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
