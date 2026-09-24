import SwiftUI

/// 模型卡与共享 key 的展示件。
///
/// **为什么改成卡片**：原先是「一个下拉选中谁 + 一份表单编辑谁」，
/// 而这两件事在同一个控件上 —— 想看看另一张卡怎么配的，就得把「正在用的」
/// 也换掉。卡片把「有哪些」「在用哪个」「这张怎么配的」三件事同时摊开，
/// 一眼扫完，不用靠记忆。

/// 这张卡的 key 是哪来的、有没有。
enum CardKeyState: Equatable {
  /// 卡片自己存了一把。
  case own
  /// 用共享的那把（带编号与备注）。
  case macro(id: String, note: String)
  /// 还没有可用的 key。
  case missing

  var usable: Bool { self != .missing }
}

/// 一张模型卡的抬头。收起时它就是这张卡的全部。
///
/// **整行点开编辑，左边那个圆点单独管「设为默认」。** 先前只有 10pt 的小三角
/// 能展开，实机反馈是「很难点」—— 点击区得配得上动作的频率，而不是配合图标的
/// 尺寸。圆点保持独立按钮，两个动作才不会抢同一块区域。
struct ProviderCardHeader: View {
  let provider: AppModel.ProviderSummary
  let isDefault: Bool
  let isExpanded: Bool
  let keyState: CardKeyState
  let onUse: () -> Void
  let onToggle: () -> Void

  /// 地址只显示主机名 —— 完整 URL 在窄栏里会把这一行挤爆，
  /// 而用户扫一眼要确认的就是「打到哪家去」。
  private var host: String {
    URL(string: provider.baseUrl)?.host ?? provider.baseUrl
  }

  private var reasoningLabel: String {
    AppModel.reasoningLevels.first { $0.value == provider.reasoning }?.label ?? provider.reasoning
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      // 圆点单独可点：设为默认。**它必须是独立的按钮** —— 整行是展开，
      // 两个动作叠在同一块区域上，点哪儿都不对。
      Button(action: onUse) {
        Image(systemName: isDefault ? "largecircle.fill.circle" : "circle")
          .font(.system(size: 13))
          .foregroundStyle(isDefault ? Palette.accent : Palette.inkFaint)
      }
      .buttonStyle(.plain)
      .help(isDefault ? L("新对话默认用这张", "New chats use this card") : L("设为新对话的默认", "Use this card for new chats"))

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(provider.label.isEmpty ? provider.id : provider.label)
            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink)
          Text(provider.model)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(Palette.inkSoft)
            .lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 0)
        }
        HStack(spacing: 6) {
          chip(host, tint: Palette.inkFaint)
          chip(reasoningLabel, tint: Palette.inkFaint)
          if let window = provider.contextWindow {
            chip(UsageMeter.compact(window), tint: Palette.inkFaint)
          }
          keyChip
          Spacer(minLength: 0)
        }
      }

      // 箭头只是个指示，**不是唯一的点击区** —— 10pt 的小三角太难点了。
      Image(systemName: "chevron.right")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(Palette.inkFaint.opacity(0.7))
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        .padding(.top, 2)
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
    .contentShape(Rectangle())
    // 整行可点 = 展开。圆点那块被上面那个 Button 吃掉，不会误触。
    .onTapGesture(perform: onToggle)
  }

  @ViewBuilder
  private var keyChip: some View {
    switch keyState {
    case .own:
      chip(L("已配置 key", "Key set"), tint: Palette.accent)
    case .macro(let id, let note):
      chip(note.isEmpty ? L("共享 \(id)", "Shared \(id)") : "\(id) · \(note)", tint: Palette.accent)
    case .missing:
      chip(L("未配置 key", "No key"), tint: Palette.danger)
    }
  }

  private func chip(_ text: String, tint: Color) -> some View {
    Text(text)
      .font(.system(size: 9.5))
      .foregroundStyle(tint)
      .lineLimit(1)
      .padding(.horizontal, 5).padding(.vertical, 1.5)
      .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
  }
}

/// 共享 key（宏观 key）那一栏。
///
/// **秘密不经过这里** —— 新建时输入的明文直接交给 `MacroKeys.save`，
/// 存进钥匙串之后视图只留一个掩码。红线：key 不回显、不进偏好文件。
struct MacroKeyPanel: View {
  @Binding var entries: [MacroKeys.Entry]
  /// 每把 key 被几张卡片引用 —— 删之前要让人看见这个数。
  let usage: [String: Int]
  let onChanged: () -> Void

  @State private var creating = false
  @State private var note = ""
  @State private var secret = ""
  @State private var failure: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(entries) { entry in
        HStack(spacing: 8) {
          Text(entry.id)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(Palette.accent)
            .frame(minWidth: 26, alignment: .leading)
          TextField(L("备注", "Note"), text: binding(for: entry.id), prompt: Text(L("备注", "Note")))
            .textFieldStyle(.plain)
            .font(.system(size: 11.5))
            .onSubmit(onChanged)
          Text(entry.masked)
            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.inkFaint)
          Text(usage[entry.id].map { L("\($0) 张卡", plural($0, "card", "cards")) } ?? L("未使用", "Unused"))
            .font(.system(size: 9.5)).foregroundStyle(Palette.inkFaint)
          Button(L("删除", "Delete")) {
            MacroKeys.delete(id: entry.id)
            entries = MacroKeys.all
            onChanged()
          }
          .buttonStyle(.link).foregroundStyle(Palette.danger)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Palette.sunk.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      }

      if creating {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            Text(MacroKeys.nextID())
              .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
              .foregroundStyle(Palette.accent)
            TextField(L("备注", "Note"), text: $note, prompt: Text(L("备注", "Note")))
              .textFieldStyle(.roundedBorder).font(.system(size: 11.5))
          }
          HStack(spacing: 6) {
            SecureField("API key", text: $secret, prompt: Text(L("粘贴 key", "Paste key")))
              .textFieldStyle(.roundedBorder)
              .font(.system(size: 11.5, design: .monospaced))
              .onSubmit(save)
            Button(L("保存", "Save"), action: save)
              .buttonStyle(StudioButtonStyle(primary: true))
              .disabled(secret.trimmingCharacters(in: .whitespaces).isEmpty)
            Button(L("取消", "Cancel")) { creating = false; note = ""; secret = "" }
          }
          if let failure {
            Text(failure).font(.uiCaption).foregroundStyle(Palette.danger)
          }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Palette.sunk.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      } else {
        Button(L("＋ 新建共享 key", "＋ New Shared Key")) { creating = true }
      }
    }
  }

  private func binding(for id: String) -> Binding<String> {
    Binding(
      get: { entries.first { $0.id == id }?.note ?? "" },
      set: { value in
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].note = value
        MacroKeys.rename(id: id, note: value)
      })
  }

  private func save() {
    let raw = secret
    secret = ""
    guard MacroKeys.save(id: MacroKeys.nextID(), note: note, secret: raw) else {
      failure = L("写不进钥匙串", "Couldn't write to the Keychain")
      return
    }
    failure = nil
    note = ""
    creating = false
    entries = MacroKeys.all
    onChanged()
  }
}
