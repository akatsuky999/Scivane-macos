import SwiftUI

/// 输入框底下那一行：**在用哪张卡 · 想多久 · 窗口还剩多少 · 缓存命中多少**。
///
/// **为什么放在这里而不是设置里**：这四件事都是「这一轮要花多少时间和钱」的
/// 直接因素，而决定要不要换的那一刻，人正盯着输入框。塞进设置页的代价是
/// 每次都要离开对话、翻两层、再回来 —— 于是实际上没人会去调。
///
/// 一行装得下，是因为每项都压成了最短形态：卡片名 + 模型名、四个字的档位、
/// `56K/1.0M` 的余量、一个百分数。**想知道细节就 hover**（都挂了 help）。
struct ComposerStatusBar: View {
  @ObservedObject var model: AppModel
  let usage: AgentUsage
  /// 跑动中不给换 —— 换了也只在下一轮生效，而界面上看起来像是立刻换了。
  let locked: Bool

  private var current: AppModel.ProviderSummary? {
    model.providers.first { $0.id == model.activeProviderID }
  }

  var body: some View {
    HStack(spacing: 10) {
      picker
      if current != nil { reasoning }
      UsageMeter(usage: usage, window: model.activeContextWindow)
    }
  }

  // MARK: - 换卡

  private var picker: some View {
    Menu {
      ForEach(model.providers) { entry in
        Button {
          model.useProvider(entry.id)
        } label: {
          // 只报昵称。**模型 id 又长又像乱码**（`~deepseek/deepseek-flash-latest`），
          // 挂在菜单里把一行撑到不可读，而昵称是用户自己在设置里起的、
          // 本来就是给自己认的那个名字。
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
        // **「不能用」必须写进图标和这一行字本身。** macOS 的 Menu 标签
        // 会被系统的按钮样式接管：自定义前景色不生效，而且**只认第一个图标
        // 加第一个文本**，再多一个 Text 会被静静丢掉（两条都是实测踩的）。
        // 所以警告并进 `title` 里，而不是另起一段。
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

  // MARK: - 推理预算

  /// 四档直接点，不进设置页。**这是等待时间最大的那个旋钮** ——
  /// 实测一轮 121 秒里模型生成占 113 秒（93.3%）。
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
          // 菜单里只给档位名。**一行一句解释会把选择变成阅读** ——
          // 要细节的人 hover 整个控件就有（见 help）。
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

  /// 只写档位本身（关 / 低 / 中 / 高）。加前缀试过「想中」，读起来像半句话；
  /// 旁边那个脑子图标已经说清楚这是什么了。
  private var reasoningLabel: String {
    let value = current?.reasoning ?? AppModel.ProviderDefaults.reasoning
    return AppModel.reasoningLevels.first { $0.value == value }?.label ?? value
  }

  private var reasoningDetail: String {
    let value = current?.reasoning ?? AppModel.ProviderDefaults.reasoning
    return AppModel.reasoningLevels.first { $0.value == value }?.hint ?? ""
  }
}
