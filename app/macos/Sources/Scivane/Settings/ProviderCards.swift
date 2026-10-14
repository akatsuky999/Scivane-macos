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

  var name: String {
    switch self {
    case .own: return L("key：本卡专用", "Key: this card's own")
    case .macro(let id, let note): return note.isEmpty ? L("key：共享 \(id)", "Key: shared \(id)") : L("key：共享 \(id) · \(note)", "Key: shared \(id) · \(note)")
    case .missing: return L("没有 key", "No key")
    }
  }
}

/// What a card's model takes in. Every chat model reads text; images only once a check has shown it
/// one, so an unchecked card says so rather than guessing from the model name.
struct ModalityTags: View {
  let vision: Bool?

  var body: some View {
    HStack(spacing: 4) {
      SettingsTag(text: L("文本", "Text"))
      switch vision {
      case true?: SettingsTag(text: L("图像", "Image"), tint: Palette.accent, emphasized: true)
      case nil: SettingsTag(text: L("待检测", "Unchecked"), tint: Palette.inkFaint)
      case false?: EmptyView()
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.name(vision))
    .help(Self.name(vision))
  }

  static func name(_ vision: Bool?) -> String {
    switch vision {
    case true?: return L("模态：文本、图像", "Modality: text, image")
    case false?: return L("模态：仅文本", "Modality: text only")
    case nil: return L("模态：文本；图像未检测", "Modality: text; image not checked")
    }
  }
}

/// The endpoint at a glance: two letters for a gateway or vendor, LAN for a machine on this network.
struct ProviderMark: View {
  let baseURL: String

  var body: some View {
    let letters = Self.letters(for: baseURL)
    let tint = letters == "LAN" ? Palette.codeString : Palette.codeNumber
    Text(letters)
      .font(.system(size: letters.count > 2 ? 9 : 10.5, weight: .bold)).tracking(0.3)
      .foregroundStyle(tint)
      .frame(width: 30, height: 30)
      .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .accessibilityHidden(true)
  }

  static func letters(for baseURL: String) -> String {
    guard let host = URL(string: baseURL)?.host?.lowercased(), !host.isEmpty else { return "API" }
    if isLocal(host) { return "LAN" }
    let known: [(String, String)] = [
      ("openrouter.ai", "OR"), ("deepseek.com", "DS"), ("openai.com", "OA"),
      ("anthropic.com", "AN"), ("googleapis.com", "GE"),
    ]
    if let hit = known.first(where: { host == $0.0 || host.hasSuffix("." + $0.0) }) { return hit.1 }
    // the registrable name: api.example.com -> example
    let labels = host.split(separator: ".")
    let name = labels.count >= 2 ? labels[labels.count - 2] : labels.first ?? "api"
    return String(name.prefix(2)).uppercased()
  }

  /// localhost, .local and the private IPv4 ranges: a model served on this machine or network
  static func isLocal(_ host: String) -> Bool {
    if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
    let parts = host.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4 else { return false }
    switch (parts[0], parts[1]) {
    case (10, _), (127, _), (192, 168): return true
    case (172, 16...31): return true
    default: return false
    }
  }
}

/// A card's header, which is the whole card when collapsed. The whole row expands; making a card
/// the default is a separate control, shown on the open card and in the context menu.
struct ProviderCardHeader: View {
  let provider: AppModel.ProviderSummary
  let isDefault: Bool
  let isExpanded: Bool
  let keyState: CardKeyState
  let onUse: () -> Void
  let onToggle: () -> Void

  private var reasoningLabel: String {
    AppModel.reasoningLevels.first { $0.value == provider.reasoning }?.label ?? provider.reasoning
  }

  var body: some View {
    HStack(spacing: 11) {
      ProviderMark(baseURL: provider.baseUrl)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(provider.displayName)
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
            .lineLimit(1)
          if isDefault {
            SettingsTag(text: L("默认", "Default"), tint: Palette.accent, emphasized: true)
              .help(L("新对话默认用这张", "New chats use this card"))
          }
        }
        Text(provider.model)
          .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.inkFaint)
          .lineLimit(1).truncationMode(.middle)
      }
      .layoutPriority(1)
      Spacer(minLength: 8)
      if isExpanded && !isDefault {
        Button(L("设为默认", "Make Default"), action: onUse)
          .buttonStyle(SettingsButtonStyle())
          .help(L("新对话默认用这张", "Use this card for new chats"))
      }
      ModalityTags(vision: provider.vision)
      SettingsTag(text: reasoningLabel).help(L("推理档位", "Reasoning"))
      Circle().fill(keyState.usable ? Palette.ok : Palette.danger)
        .frame(width: 7, height: 7)
        .help(keyState.name)
        .accessibilityLabel(keyState.name)
      Image(systemName: "chevron.right")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(Palette.inkFaint)
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        .accessibilityHidden(true)
    }
    .padding(.horizontal, 10).frame(minHeight: 56)
    .contentShape(Rectangle())
    // the row expands; buttons inside take their own clicks
    .onTapGesture(perform: onToggle)
    .contextMenu {
      if !isDefault {
        Button(L("设为新对话的默认", "Use for New Chats"), action: onUse)
      }
      Button(isExpanded ? L("收起", "Collapse") : L("编辑…", "Edit…"), action: onToggle)
    }
    .accessibilityElement(children: .contain)
    .accessibilityAction(named: isExpanded ? L("收起", "Collapse") : L("编辑", "Edit"), onToggle)
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
    VStack(spacing: 0) {
      ForEach(entries) { entry in
        HStack(spacing: 10) {
          Text(entry.id)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 6).frame(height: 20)
            .background(Palette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
          TextField(L("备注", "Note"), text: binding(for: entry.id), prompt: Text(L("备注", "Note")))
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .onSubmit(onChanged)
          Text(entry.masked)
            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.inkFaint)
          Text(usage[entry.id].map { L("\($0) 张卡", plural($0, "card", "cards")) } ?? L("未使用", "Unused"))
            .font(.system(size: 11)).foregroundStyle(Palette.inkFaint)
          Button(L("删除", "Delete")) {
            MacroKeys.delete(id: entry.id)
            entries = MacroKeys.all
            onChanged()
          }
          .buttonStyle(SettingsButtonStyle(kind: .destructive))
        }
        .padding(.leading, 16).padding(.trailing, 10).frame(minHeight: 46)
        SettingsDivider()
      }

      if creating {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 8) {
            Text(MacroKeys.nextID())
              .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
              .foregroundStyle(Palette.accent)
            TextField(L("备注", "Note"), text: $note, prompt: Text(L("备注", "Note")))
              .settingsField()
          }
          HStack(spacing: 8) {
            SecureField("API key", text: $secret, prompt: Text(L("粘贴 key", "Paste key")))
              .settingsField(monospaced: true)
              .onSubmit(save)
            Button(L("取消", "Cancel")) { creating = false; note = ""; secret = "" }
              .buttonStyle(SettingsButtonStyle())
            Button(L("保存", "Save"), action: save)
              .buttonStyle(SettingsButtonStyle(kind: .primary))
              .disabled(secret.trimmingCharacters(in: .whitespaces).isEmpty)
          }
          if let failure {
            Text(failure).font(.system(size: 11)).foregroundStyle(Palette.danger)
          }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
      } else {
        SettingsRow(title: entries.isEmpty ? L("还没有共享 key", "No shared keys") : L("新建共享 key", "New Shared Key")) {
          Button(L("新建", "Add")) { creating = true }
            .buttonStyle(SettingsButtonStyle())
        }
      }
    }
    .cardSurface()
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
