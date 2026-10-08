import SwiftUI

/// The line under the composer: card, reasoning level, context occupancy, this turn's usage.
/// These drive a turn's time and cost and are decided while looking at the composer, so they live
/// here rather than in Settings. Each item is in its shortest form; details are in the help
/// tooltips and the context breakdown.
struct ComposerStatusBar: View {
  @ObservedObject var model: AppModel
  let usage: AgentUsage
  /// nil for the librarian, which draws nothing
  var context: ContextReport? = nil
  /// locked while running: a change would only apply next turn but look immediate
  let locked: Bool
  /// only for project conversations
  var onCompact: () -> Void = {}

  private var current: AppModel.ProviderSummary? {
    model.providers.first { $0.id == model.activeProviderID }
  }

  var body: some View {
    HStack(spacing: 10) {
      picker
      if current != nil { reasoning }
      ContextMeter(report: context, busy: locked, onCompact: onCompact)
      UsageMeter(usage: usage)
    }
  }

  // MARK: - Card

  private var picker: some View {
    Menu {
      ForEach(model.providers) { entry in
        Button {
          model.useProvider(entry.id)
        } label: {
          // Nickname only: model ids are long and unreadable in a menu.
          Label(
            AppModel.hasKey(entry)
              ? entry.displayName : L("\(entry.displayName) · 未配置 key", "\(entry.displayName) · no key"),
            systemImage: entry.id == model.activeProviderID ? "checkmark" : "")
        }
      }
      if model.providers.isEmpty {
        Text(L("没有模型卡", "No model cards"))
      }
    } label: {
      HStack(spacing: 4) {
        // macOS Menu labels take only the first image and the first Text and ignore custom colours, so
        // the warning goes into the icon and the title itself.
        Image(systemName: usable ? "cpu" : "exclamationmark.triangle.fill")
          .font(.system(size: 9.5))
        Text(title).font(.system(size: 10)).lineLimit(1)
        Image(systemName: "chevron.up.chevron.down").font(.system(size: 7))
      }
      .foregroundStyle(usable ? Palette.inkSoft : Palette.danger)
      .padding(.horizontal, 6).padding(.vertical, 2.5)
      .background(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill((usable ? Palette.ink : Palette.danger).opacity(0.05)))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(locked || model.providers.isEmpty)
    .help(helpText)
  }

  private var title: String {
    guard let current else { return L("未配置模型", "No model") }
    return usable ? current.displayName : L("\(current.displayName) · 未配置 key", "\(current.displayName) · no key")
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
      HStack(spacing: 4) {
        Image(systemName: "brain").font(.system(size: 9.5))
        Text(reasoningLabel).font(.system(size: 10))
        Image(systemName: "chevron.up.chevron.down").font(.system(size: 7))
      }
      .foregroundStyle(Palette.inkSoft)
      .padding(.horizontal, 6).padding(.vertical, 2.5)
      .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill(Palette.ink.opacity(0.05)))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(locked)
    .help(L("推理预算 · 当前「\(reasoningLabel)」：\(reasoningDetail)",
            "Reasoning budget · currently “\(reasoningLabel)”: \(reasoningDetail)"))
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
