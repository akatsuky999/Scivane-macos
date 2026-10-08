import Foundation

/// API key storage. Keys live only in the Keychain, never in files or UserDefaults (a plain plist
/// that `defaults read` prints). There is deliberately no way to read a key back for the UI: it
/// shows a mask computed at write time and stored separately.
enum Keychain {
  private static let service = "local.scivane.app.llm"

  static func set(_ secret: String, provider: String) -> Bool {
    let account = provider as CFString
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(base as CFDictionary)
    guard !secret.isEmpty else { return true }
    var item = base
    item[kSecValueData as String] = Data(secret.utf8)
    // this machine only, after first unlock; no iCloud sync, the key serves a local service
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
  }

  /// Only for injecting into the backend; never keep the result in UI state.
  static func secret(provider: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: provider,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
      let data = out as? Data, let text = String(data: data, encoding: .utf8)
    else { return nil }
    return text
  }

  static func has(provider: String) -> Bool { secret(provider: provider) != nil }

  static func clear(provider: String) {
    _ = set("", provider: provider)
  }

  /// Prefix and last four characters only. No copy and no reveal: Test connection is the safe way to
  /// check a key.
  static func masked(_ secret: String) -> String {
    let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 8 else { return L("已保存", "Saved") }
    let head = trimmed.hasPrefix("sk-") ? "sk-" : String(trimmed.prefix(3))
    return head + "…" + String(trimmed.suffix(4))
  }
}

/// Shared keys: several cards on one gateway use the same key, and changing it card by card is
/// error-prone. The secret stays in the Keychain (same service, account `macro:<id>`); a
/// secret-free index (id, note, mask) in UserDefaults draws the list, since enumerating the
/// Keychain needs extra permission and prompts.
enum MacroKeys {
  /// No secret in here.
  struct Entry: Identifiable, Codable, Equatable {
    /// e.g. `K1`. Part of the account name and never changed; a new id is a different key for the
    /// cards referencing the old one.
    let id: String
    var note: String
    /// display only, e.g. `sk-…9f2c`
    var masked: String
  }

  private static let indexKey = "macroKeys"

  static var all: [Entry] {
    guard let data = UserDefaults.standard.data(forKey: indexKey),
      let decoded = try? JSONDecoder().decode([Entry].self, from: data)
    else { return [] }
    return decoded
  }

  private static func write(_ entries: [Entry]) {
    guard let data = try? JSONEncoder().encode(entries) else { return }
    UserDefaults.standard.set(data, forKey: indexKey)
  }

  /// Counts up from the highest id and never reuses a deleted one, or an old card referencing K2
  /// would silently point at a different key.
  static func nextID() -> String {
    let used = all.compactMap { Int($0.id.dropFirst()) }
    return "K\((used.max() ?? 0) + 1)"
  }

  static func account(_ id: String) -> String { "macro:\(id)" }

  /// `note` is for people, e.g. "OpenRouter main".
  @discardableResult
  static func save(id: String, note: String, secret: String) -> Bool {
    guard Keychain.set(secret, provider: account(id)) else { return false }
    var entries = all
    let entry = Entry(id: id, note: note, masked: Keychain.masked(secret))
    if let index = entries.firstIndex(where: { $0.id == id }) { entries[index] = entry }
    else { entries.append(entry) }
    write(entries)
    return true
  }

  /// Changes the note only, never the secret.
  static func rename(id: String, note: String) {
    var entries = all
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    entries[index].note = note
    write(entries)
  }

  static func delete(id: String) {
    Keychain.clear(provider: account(id))
    write(all.filter { $0.id != id })
  }

  static func secret(id: String) -> String? { Keychain.secret(provider: account(id)) }

  static func exists(_ id: String) -> Bool { all.contains { $0.id == id } }
}
