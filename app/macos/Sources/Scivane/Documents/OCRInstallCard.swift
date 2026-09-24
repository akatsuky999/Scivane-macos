import SwiftUI

/// 正文栏顶上的「本地 OCR 还没装」卡片，以及安装进度。
///
/// 与 `ScanProgressBar` 同一个位置、同一套版式：一条浅底的横带，不是模态框。
/// 空闲时什么都不画 —— 所以它可以常驻在视图树里，自己观察 `OCRInstaller`。
struct OCRInstallCard: View {

    @ObservedObject var installer: OCRInstaller
    /// 设置页里嵌同一张卡时不要「以后再说」—— 那里本来就是用户主动来找它的
    var dismissible = true

    var body: some View {
        switch installer.phase {
        case .idle:
            EmptyView()
        case .offer(let status):
            band { offer(status) }
        case .running(let run):
            band(track: run.fraction) { running(run) }
        case .failed(let code, let message, let method):
            band(tint: Palette.danger.opacity(0.07)) { failed(code: code, message: message, method: method) }
        case .done(let elapsed, let method):
            band(track: 1) { done(elapsed, method: method) }
                .task {
                    // 停几秒让人看见「装好了」与那句一分钟的提醒，之后让位给识别进度。
                    // **只收走自己显示的那一个**：等待被取消（卡片撤下 —— 设置页关了、状态被别处换走）就到此为止，
                    // 等完了状态已经换了也不动。从前 `try?` 连取消也吞了、接着 dismiss()：
                    // 另一处还在显示的「装好了」、甚至别处刚换上的状态，都被一起清成 idle
                    let shown = installer.phase
                    guard (try? await Task.sleep(nanoseconds: 8_000_000_000)) != nil,
                          installer.phase == shown else { return }
                    installer.dismiss()
                }
        }
    }

    // MARK: - 四种状态

    /// 三种来由，三种说法：
    /// - 设置页指定的位置用不了 —— 装组件也没用（覆盖档设了就只看它），说清楚去清掉那一栏
    /// - 已经在用旧部署、从设置页来迁 —— 这是「一键迁移」，不是「没装」
    /// - 真没装 —— 下载，或者有旧部署时迁移
    private func offer(_ status: RuntimeClient.Status) -> some View {
        let (icon, title, detail): (String, String, String) = {
            if let problem = status.overrideProblem {
                return ("exclamationmark.circle",
                        L("设置页里指定的本地 OCR 位置用不了", "The local OCR location set in Settings doesn't work"),
                        L("\(problem)。清掉设置页「模型运行时」那一栏，App 会自己去找；要装组件也得先清掉它。",
                          "\(problem). Clear “Model Runtime” in Settings and the app will find OCR itself; "
                            + "installing the component also needs it cleared first."))
            }
            if status.available {
                return ("arrow.triangle.2.circlepath",
                        L("把旧部署迁成 App 自己管理的组件", "Convert the old deployment into an app-managed component"),
                        L("本机拷贝、不联网，几秒钟；旧部署一个字节都不动。之后删掉或挪走旧部署，App 照样能识别。",
                          "A local copy, no network, a few seconds; the old deployment isn't touched. "
                            + "Afterwards you can delete or move it and OCR keeps working."))
            }
            if status.migratable {
                return ("arrow.down.circle",
                        L("识别原稿要用本地 OCR，这台机器还没装", "Recognizing the original needs local OCR, which isn't installed on this Mac"),
                        L("这台机器上有旧部署，可以直接迁过来：本机拷贝、不联网，几秒钟。也可以重新下载（约 2.2 GB）。",
                          "There's an old deployment on this Mac that can be migrated: a local copy, no network, "
                            + "a few seconds. Or download it again (about 2.2 GB)."))
            }
            return ("arrow.down.circle",
                    L("识别原稿要用本地 OCR，这台机器还没装", "Recognizing the original needs local OCR, which isn't installed on this Mac"),
                    L("它是可选组件，装一次约 2.2 GB，网速正常时五六分钟。阅读与问答不受影响；上游连不上会自动换国内镜像。",
                      "It's optional: about 2.2 GB, five or six minutes on a normal connection. Reading and Q&A "
                        + "work without it; if the upstream is unreachable it switches to a mirror automatically."))
        }()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .foregroundStyle(status.overrideProblem == nil ? Palette.accent : Palette.danger)
                Text(title)
                    .font(.uiTitle).foregroundStyle(Palette.ink)
            }
            Text(detail)
                .font(.uiCaption).foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if status.overrideProblem != nil {
                    Button(L("知道了", "Got It")) { installer.dismiss() }
                        .buttonStyle(StudioButtonStyle(primary: false))
                } else if status.migratable {
                    Button(status.available ? L("迁移", "Migrate") : L("从旧部署迁移", "Migrate the Old Deployment")) {
                        installer.start(.migrate)
                    }
                        .buttonStyle(StudioButtonStyle(primary: true))
                    if !status.available {
                        Button(L("重新下载", "Download Again")) { installer.start(.download) }
                            .buttonStyle(StudioButtonStyle(primary: false))
                    }
                } else {
                    Button(L("下载安装", "Download and Install")) { installer.start(.download) }
                        .buttonStyle(StudioButtonStyle(primary: true))
                }
                if dismissible || status.available, status.overrideProblem == nil {
                    Button(status.available ? L("取消", "Cancel") : L("以后再说", "Not Now")) { installer.dismiss() }
                        .buttonStyle(.borderless).font(.uiCaption).foregroundStyle(Palette.inkFaint)
                }
            }
            .padding(.top, 2)
        }
    }

    private func running(_ run: OCRInstaller.Run) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(run.method == .migrate ? L("正在迁移本地 OCR", "Migrating local OCR")
                                            : L("正在安装本地 OCR", "Installing local OCR"))
                    .foregroundStyle(Palette.inkSoft)
                if run.steps > 0 {
                    pill(L("第 \(run.step)/\(run.steps) 步", "Step \(run.step)/\(run.steps)"))
                }
                Text(run.label.isEmpty ? L("准备中…", "Preparing…") : run.label)
                    .foregroundStyle(Palette.inkSoft).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                if let amount = amount(run) {
                    Text(amount).foregroundStyle(Palette.inkFaint)
                }
                if !run.source.isEmpty {
                    Text("· \(run.source)").foregroundStyle(Palette.inkFaint).lineLimit(1)
                }
                if run.elapsed > 0 {
                    Text("· " + ScanProgressBar.duration(run.elapsed)).foregroundStyle(Palette.inkFaint)
                }
                Button(action: installer.cancel) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless).foregroundStyle(Palette.inkFaint)
                .help(L("停下安装（已下载的部分留着，下次接着下）",
                        "Stop the install (what's downloaded is kept; next time it resumes)"))
            }
            // 换了来源要让人看得见 —— 否则「怎么突然变快 / 变慢了」无从解释
            if let switched = run.switched {
                Label(switched, systemImage: "arrow.triangle.branch")
                    .foregroundStyle(Palette.accent).lineLimit(1).truncationMode(.middle)
            }
        }
        .font(.uiMeta)
    }

    private func failed(code: String, message: String, method: RuntimeClient.Method) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9.5)).foregroundStyle(Palette.danger)
            Text(message)
                .foregroundStyle(Palette.inkSoft).lineLimit(2).truncationMode(.middle)
                .help(L("\(code)：\(message)", "\(code): \(message)"))
            Spacer(minLength: 6)
            // 已下载的部分在缓存里：「继续」真的是接着下，不是从头来
            if code != "HTTP_409" {
                Button(code == "CANCELLED" ? L("继续安装", "Resume Install") : L("重试", "Retry")) {
                    installer.start(method)
                }
                    .buttonStyle(.borderless)
            }
            Button(L("关闭", "Close")) { installer.dismiss() }.buttonStyle(.borderless).foregroundStyle(Palette.inkFaint)
        }
        .font(.uiMeta)
    }

    private func done(_ elapsed: Double, method: RuntimeClient.Method) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.accent)
            Text(method == .migrate ? L("本地 OCR 迁好了", "Local OCR migrated") : L("本地 OCR 装好了", "Local OCR installed"))
                .foregroundStyle(Palette.inkSoft)
            pill(ScanProgressBar.duration(elapsed))
            // 新装的二进制第一次加载要一分钟左右，不说出来就像卡死了
            Text(L("第一次识别要加载新装的引擎，大约一分钟", "The first OCR loads the new engine — about a minute"))
                .foregroundStyle(Palette.inkFaint)
            Spacer()
        }
        .font(.uiMeta)
    }

    // MARK: - 版式

    private func band<Content: View>(tint: Color = Palette.sunk, track: Double? = nil,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            if let track {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Palette.ruleSoft)
                        Rectangle().fill(Palette.accent)
                            .frame(width: max(3, geo.size.width * track))
                            .animation(.smooth(duration: 0.4), value: track)
                    }
                }
                .frame(height: 2.5)
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(tint)
            Hairline()
        }
        .transition(.opacity)
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(Palette.inkSoft)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Palette.panel, in: Capsule())
    }

    private func amount(_ run: OCRInstaller.Run) -> String? {
        guard run.total > 0 else { return nil }
        // `unit` 是后端的契约字段（只有 pip 那一步有，值是「包」）—— 英文照它的意思说
        if let unit = run.unit { return L("\(run.done)/\(run.total) 个\(unit)", "\(run.done)/\(run.total) packages") }
        let mb = { (bytes: Int) in bytes >= 10_000_000 ? String(format: "%.0f", Double(bytes) / 1e6)
                                                      : String(format: "%.1f", Double(bytes) / 1e6) }
        return "\(mb(run.done))/\(mb(run.total)) MB"
    }
}
