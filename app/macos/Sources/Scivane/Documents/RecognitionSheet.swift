import SwiftUI

/// Which engine reads the original: local OCR on this Mac, or a model card that can see images.
/// Two rows and a start button. An engine that can't run here is shown but can't be picked, with
/// the one action that would fix it.
struct RecognitionSheet: View {
  @ObservedObject var model: AppModel
  @ObservedObject var installer: OCRInstaller
  let job: DocumentJob
  /// the run will overwrite this project's paper text
  let replacesText: Bool
  let dismiss: () -> Void

  private enum Choice { case local, model }

  @State private var choice: Choice?
  @State private var provider = ""
  /// the user picked something; defaults stop following what arrives later
  @State private var touched = false
  @State private var checking = false
  @State private var checkFailure: UIText?

  /// Cards with a key, in the Keychain or already in the backend (an environment variable); one
  /// without can't run anything.
  private var cards: [AppModel.ProviderSummary] {
    model.providers.filter { AppModel.hasKey($0) || $0.hasCredential }
  }

  private var localStatus: RuntimeClient.Status? { installer.status }
  private var localReady: Bool { localStatus?.available == true && localStatus?.overrideProblem == nil }

  private var selectedCard: AppModel.ProviderSummary? { cards.first { $0.id == provider } }

  private var canStart: Bool {
    switch choice {
    case .local: return localReady
    case .model: return selectedCard != nil && selectedCard?.vision != false && !checking
    case nil: return false
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 3) {
        Text(L("识别原稿", "Recognize Original"))
          .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
        Text(L("\(job.title) · \(job.pageCount) 页", "\(job.title) · \(plural(job.pageCount, "page", "pages"))"))
          .font(.uiCaption).foregroundStyle(Palette.inkFaint)
          .lineLimit(1).truncationMode(.middle)
      }

      VStack(spacing: 8) {
        row(.local, title: L("本地 OCR", "Local OCR"), enabled: localReady) { localDetail }
        row(.model, title: L("云端模型", "Cloud Model"), enabled: !cards.isEmpty) { modelDetail }
      }

      HStack(spacing: 10) {
        if replacesText {
          Text(L("完成后覆盖现在的正文", "Replaces the current text when done"))
            .font(.uiCaption).foregroundStyle(Palette.inkFaint)
        }
        Spacer(minLength: 0)
        Button(L("取消", "Cancel"), action: dismiss)
          .keyboardShortcut(.cancelAction)
        Button(L("开始识别", "Start")) { start() }
          .buttonStyle(StudioButtonStyle(primary: true))
          .keyboardShortcut(.defaultAction)
          .disabled(!canStart)
      }
    }
    .padding(20)
    .frame(width: 420)
    .background(Palette.paper)
    .task {
      // what is already known first, so the sheet never opens empty; then what the backend says
      pickDefault()
      guard await model.awaitBackend(quiet: true) else { return }
      await installer.refresh()
      await model.refreshProviders()
      pickDefault()
    }
  }

  // MARK: - Rows

  private func row<Detail: View>(
    _ which: Choice, title: String, enabled: Bool, @ViewBuilder detail: () -> Detail
  ) -> some View {
    let selected = choice == which
    return HStack(alignment: .top, spacing: 10) {
      Image(systemName: selected ? "largecircle.fill.circle" : "circle")
        .font(.system(size: 13))
        .foregroundStyle(selected ? Palette.accent : Palette.inkFaint)
        .padding(.top, 1)
        .opacity(enabled ? 1 : 0.5)
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink)
          .opacity(enabled ? 1 : 0.5)
        // full strength even when the row is off: it holds the one action that turns it on
        detail()
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
    .background(selected ? Palette.accent.opacity(0.06) : Palette.panel,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(selected ? Palette.accent.opacity(0.55) : Palette.ruleSoft))
    .contentShape(Rectangle())
    .onTapGesture {
      guard enabled else { return }
      choice = which
      touched = true
    }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  @ViewBuilder private var localDetail: some View {
    if let status = localStatus {
      if localReady {
        caption(L("PaddleOCR-VL · 在本机运行", "PaddleOCR-VL · runs on this Mac"))
      } else if status.overrideProblem != nil {
        caption(L("设置里指定的位置用不了", "The location set in Settings doesn't work"), tint: Palette.danger)
      } else {
        HStack(spacing: 8) {
          caption(L("未安装", "Not installed"))
          Button(L("安装…", "Install…")) {
            // Queued for local OCR rather than only opening the card: the run is held while the
            // install card is up and carries on by itself once the engine is in.
            RecognitionEngine.remembered = .local
            dismiss()
            model.startRecognition(job, engine: .local)
          }
          .buttonStyle(.link).font(.uiCaption).foregroundStyle(Palette.accent)
        }
      }
    } else {
      caption(L("查询中…", "Checking…"))
    }
  }

  @ViewBuilder private var modelDetail: some View {
    if cards.isEmpty {
      HStack(spacing: 8) {
        caption(L("还没有配好 key 的模型卡", "No model card with a key yet"))
        Button(L("打开设置", "Open Settings")) {
          dismiss()
          NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        .buttonStyle(.link).font(.uiCaption).foregroundStyle(Palette.accent)
      }
    } else {
      Picker("", selection: $provider) {
        ForEach(cards) { card in
          Text(card.model.isEmpty ? card.displayName : "\(card.displayName) · \(card.model)").tag(card.id)
        }
      }
      .labelsHidden().pickerStyle(.menu).controlSize(.small)
      .frame(maxWidth: 300, alignment: .leading)
      .onChange(of: provider) { old, _ in
        checkFailure = nil
        // a pick by the user, not the default being filled in
        guard !old.isEmpty else { return }
        choice = .model
        touched = true
      }
      visionLine
    }
  }

  /// Transcription needs a model that sees images. Say so in three words, never in a paragraph.
  @ViewBuilder private var visionLine: some View {
    HStack(spacing: 6) {
      if checking {
        ProgressView().controlSize(.mini)
        caption(L("检测中…", "Checking…"))
      } else if let failure = checkFailure {
        caption(failure.text, tint: Palette.danger)
      } else {
        switch selectedCard?.vision {
        case true?:
          Label(L("能看图", "Sees images"), systemImage: "eye")
            .font(.uiCaption).foregroundStyle(Palette.accent)
        case false?:
          Label(L("看不到图，转写不了", "Can't see images"), systemImage: "eye.slash")
            .font(.uiCaption).foregroundStyle(Palette.danger)
        case nil:
          caption(L("还没检测能不能看图", "Image input not checked yet"))
          Button(L("检测", "Check")) { Task { await check() } }
            .buttonStyle(.link).font(.uiCaption).foregroundStyle(Palette.accent)
        }
      }
    }
  }

  private func caption(_ text: String, tint: Color = Palette.inkFaint) -> some View {
    Text(text).font(.uiCaption).foregroundStyle(tint)
  }

  // MARK: - Actions

  /// The last choice when it can still run; otherwise local OCR if installed, else the first card
  /// not known to be blind.
  private func pickDefault() {
    guard !touched else { return }
    if provider.isEmpty || !cards.contains(where: { $0.id == provider }) {
      let remembered = RecognitionEngine.remembered?.provider
      provider = cards.first { $0.id == remembered }?.id
        ?? cards.first { $0.vision != false }?.id ?? cards.first?.id ?? ""
    }
    switch RecognitionEngine.remembered {
    case .local? where localReady: choice = .local
    case .model? where !cards.isEmpty: choice = .model
    default: choice = localReady ? .local : (cards.isEmpty ? nil : .model)
    }
  }

  private func check() async {
    guard !provider.isEmpty else { return }
    checking = true
    let result = await model.checkVision(provider)
    checking = false
    checkFailure = result.supported == nil ? result.failure : nil
  }

  private func start() {
    let engine: RecognitionEngine
    switch choice {
    case .local: engine = .local
    case .model: engine = .model(provider: provider)
    case nil: return
    }
    RecognitionEngine.remembered = engine
    dismiss()
    model.startRecognition(job, engine: engine)
  }
}
