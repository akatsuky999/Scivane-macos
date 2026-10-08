import SwiftUI

/// Model cards and shared keys. Cards show which providers exist, which one is in use and how each
/// is configured at once, unlike the earlier picker plus a single form.

/// Where this card's key comes from, if any.
enum CardKeyState: Equatable {
  /// stored on the card
  case own
  /// the shared one, with id and note
  case macro(id: String, note: String)
  /// no usable key yet
  case missing

  var usable: Bool { self != .missing }
}

/// A card's header, which is the whole card when collapsed. The whole row expands; the dot on the
/// left is a separate button for Make Default, so the two actions don't share an area.
struct ProviderCardHeader: View {
  let provider: AppModel.ProviderSummary
  let isDefault: Bool
  let isExpanded: Bool
  let keyState: CardKeyState
  let onUse: () -> Void
  let onToggle: () -> Void

  /// host only: the full URL doesn't fit, and the host is what people check
  private var host: String {
    URL(string: provider.baseUrl)?.host ?? provider.baseUrl
  }

  private var reasoningLabel: String {
    AppModel.reasoningLevels.first { $0.value == provider.reasoning }?.label ?? provider.reasoning
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      // a separate button, since the row itself expands
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
          if let window = provider.window {
            chip(UsageMeter.compact(window), tint: Palette.inkFaint)
          }
          keyChip
          Spacer(minLength: 0)
        }
      }

      // only an indicator; the whole row is clickable
      Image(systemName: "chevron.right")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(Palette.inkFaint.opacity(0.7))
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        .padding(.top, 2)
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
    .contentShape(Rectangle())
    // the row expands; the dot's Button takes its own clicks
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

/// Shared keys. Secrets never pass through here: new input goes straight to MacroKeys.save and
/// only the mask remains.
struct MacroKeyPanel: View {
  @Binding var entries: [MacroKeys.Entry]
  /// cards using each key; shown before deleting
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
