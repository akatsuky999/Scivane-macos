import Foundation

/// API key 的存放与注入。
///
/// **key 只进 Keychain，不进文件、不进 UserDefaults。**
/// UserDefaults 是明文 plist，`defaults read` 一行就能读出来；
/// 写文件同理，而且备份、同步、误提交都会把它带走。
///
/// 红线：key 不进日志、不进错误消息、不回显前端。
/// 所以这里只提供「写入」和「取出来注入后端」，**没有读回给界面的接口** ——
/// 界面要显示的是掩码，那由 `masked(_:)` 在写入时算好并单独存。
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
    // 只在本机、解锁后可用。不参与 iCloud 钥匙串同步 ——
    // 这把 key 对应的是这台机器上的一个本地服务，没有跨设备的意义。
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
  }

  /// 取出来**只为了注入后端**。不要把返回值放进任何界面状态。
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

  /// 界面上能显示的形态：只留前缀与最后四位。
  ///
  /// 不给复制按钮，也不提供「看一眼完整的」—— 想确认填对没有就点「测试连接」，
  /// 那比把明文摆回屏幕上安全得多。
  static func masked(_ secret: String) -> String {
    let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 8 else { return L("已保存", "Saved") }
    let head = trimmed.hasPrefix("sk-") ? "sk-" : String(trimmed.prefix(3))
    return head + "…" + String(trimmed.suffix(4))
  }
}

/// 共享的 key（界面上叫「宏观 key」）。
///
/// **为什么要有它**：同一个网关上常常开好几张卡（OpenRouter 上挂三个模型就是
/// 三张卡），它们用的是同一把 key。没有共享的话，换一次 key 要挨张改，
/// 漏掉一张的表现是那张卡突然「未配置」——而用户以为自己已经改完了。
///
/// **秘密仍然只在钥匙串里**，与 provider 自己的 key 共用一个 service，
/// 只是 account 换成 `macro:<编号>`。这里额外存一份**不含秘密**的索引
/// （编号、备注、掩码）到 UserDefaults，用来把列表画出来 ——
/// 钥匙串本身不适合拿来当「列举」用（枚举要额外权限，而且会弹授权框）。
enum MacroKeys {
  /// 一把共享 key 在界面上的样子。**没有秘密原文**。
  struct Entry: Identifiable, Codable, Equatable {
    /// 编号，如 `K1`。它是 account 的一部分，**建了就不改** ——
    /// 改编号等于换一把 key，而引用它的卡片不会跟着变。
    let id: String
    var note: String
    /// 只用于显示，如 `sk-…9f2c`。
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

  /// 下一个可用编号。**从现有的最大号往后排，不复用已删掉的号** ——
  /// 复用的话，一张还引用着 K2 的旧卡会突然指到一把完全不同的 key 上。
  static func nextID() -> String {
    let used = all.compactMap { Int($0.id.dropFirst()) }
    return "K\((used.max() ?? 0) + 1)"
  }

  static func account(_ id: String) -> String { "macro:\(id)" }

  /// 存一把共享 key。`note` 是给人看的，比如「OpenRouter 主号」。
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

  /// 只改备注，不动秘密。
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
