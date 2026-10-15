import SwiftUI

/// Two independent menus in one capsule: the conversation's model and its reasoning budget.
struct ComposerStatusBar: View {
  @ObservedObject var model: AppModel
  /// locked while running: a change would only apply next turn but look immediate
  let locked: Bool

  private var current: AppModel.ProviderSummary? {
    model.providers.first { $0.id == model.activeProviderID }
  }

  var body: some View {
    HStack(spacing: 0) {
      picker
      if current != nil {
        Rectangle().fill(Palette.ruleSoft).frame(width: 1, height: 14)
        reasoning.fixedSize()
      }
    }
    .frame(height: 30)
    .composerCapsule()
  }

  // MARK: - Card

  private var picker: some View {
    Menu {
      ForEach(model.providers) { entry in
        Button {
          model.useProvider(entry.id)
        } label: {
          // Nickname only: model ids are long and unreadable in a menu.
          Label(entry.displayName,
            systemImage: entry.id == model.activeProviderID ? "checkmark"
              : (AppModel.hasKey(entry) ? "" : "exclamationmark.triangle"))
        }
      }
      if model.providers.isEmpty {
        Text(L("没有模型卡", "No model cards"))
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: usable ? "cpu" : "exclamationmark.triangle.fill")
          .font(.system(size: 12))
        Text(title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
      }
      .foregroundStyle(usable ? Palette.inkSoft : Palette.danger)
      .padding(.leading, 11).padding(.trailing, 10)
      .frame(height: 30)
      .contentShape(Capsule())
    }
    .menuStyle(.button).buttonStyle(.plain)
    .menuIndicator(.hidden)
    .disabled(locked || model.providers.isEmpty)
    .help(helpText)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(L("模型：\(title)", "Model: \(title)"))
    .accessibilityIdentifier("agent-composer-model")
  }

  private var title: String {
    guard let current else { return L("未配置模型", "No model") }
    return current.displayName
  }

  private var usable: Bool {
    guard let current else { return false }
    return AppModel.hasKey(current)
  }

  private var helpText: String {
    guard let current else { return L("设置（⌘,）里建一张模型卡", "Create a model card in Settings (⌘,)") }
    if !AppModel.hasKey(current) { return L("这张卡还没有 key", "This card has no key yet") }
    return L("这条对话用「\(current.displayName)」· \(current.model)",
             "This chat uses “\(current.displayName)” · \(current.model)")
  }

  // MARK: - Reasoning

  /// Four levels right here, not in Settings: generation is most of the wait.
  private var reasoning: some View {
    Menu {
      ForEach(AppModel.reasoningLevels, id: \.value) { level in
        Button {
          guard let current else { return }
          Task {
            _ = await model.saveProvider(
              id: current.id, label: current.label, proto: current.proto,
              model: current.model, baseURL: current.baseUrl,
              contextWindow: current.contextWindow, reasoning: level.value,
              credentialRef: current.credentialRef)
          }
        } label: {
          // level names only; the explanation is in the help tooltip
          Label(level.label, systemImage: level.value == current?.reasoning ? "checkmark" : "")
        }
      }
    } label: {
      HStack(spacing: 5) {
        Text(reasoningLabel).font(.system(size: 12))
        Image(systemName: "chevron.down").font(.system(size: 7, weight: .medium))
      }
      .foregroundStyle(Palette.inkSoft)
      .padding(.leading, 9).padding(.trailing, 11)
      .frame(height: 30)
      .contentShape(Capsule())
    }
    .menuStyle(.button).buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(locked)
    .help(L("推理预算 · 当前「\(reasoningLabel)」：\(reasoningDetail)",
            "Reasoning budget · currently “\(reasoningLabel)”: \(reasoningDetail)"))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(L("推理预算：\(reasoningLabel)", "Reasoning budget: \(reasoningLabel)"))
    .accessibilityIdentifier("agent-composer-reasoning")
  }

  /// just the level; the brain icon says what it is
  private var reasoningLabel: String {
    let value = current?.reasoning ?? AppModel.ProviderDefaults.reasoning
    return AppModel.reasoningLevels.first { $0.value == value }?.label ?? value
  }

  private var reasoningDetail: String {
    let value = current?.reasoning ?? AppModel.ProviderDefaults.reasoning
    return AppModel.reasoningLevels.first { $0.value == value }?.hint ?? ""
  }
}
