import Foundation

/// 一轮对话在 App 这一侧的分段计时。
///
/// 「对话慢」可能慢在模型、请求的形状、后端转发、客户端解析或界面显示 —— 只看总时长分不出来。
/// 后端那一半在 `llm/timing.py`：厂商那一段，与每个 SSE 帧交给 HTTP 层的时刻。这里记另一半：
///
/// - 请求发出、响应头到达；
/// - **每个事件解码出来的时刻**（URLSession 的回调线程上）；
/// - **主线程处理它的时刻**（`AgentSession.absorb`）—— 与上一项之差就是主线程排队多久；
/// - **字交给界面的时刻**（`StreamPacer` 每次发布）—— 下一帧就画到屏幕上。
///
/// 两边都用墙上时钟，同一台机器上逐帧对齐，就分得清慢在哪一层。
///
/// **默认关。** `SCIVANE_TIMING=1`（验证脚本）或 `defaults write local.scivane.app agentTiming -bool YES`
/// （真 App，下次启动生效）打开；开着时 App 也把 `SCIVANE_TIMING=1` 交给它起的后端。
/// 写到 `<var>/logs/ui-timing.jsonl`，一轮一行。**只记时刻、事件名与字节数，不记内容与凭据。**
final class AgentTiming: @unchecked Sendable {

  /// 开没开。启动时读一次：一轮跑到一半改了开关，那一轮的记录也不该半截。
  static let enabled: Bool =
    ProcessInfo.processInfo.environment["SCIVANE_TIMING"] == "1"
    || UserDefaults.standard.bool(forKey: "agentTiming")

  static var log: URL {
    BackendManager.currentVarRoot.appendingPathComponent("logs/ui-timing.jsonl")
  }

  private let lock = NSLock()
  private var marks: [String: Double] = [:]
  /// 解码出来的时刻、事件名、这一帧的字节数、其中正文或推理的字节数。
  private var received: [(Double, String, Int, Int)] = []
  /// 主线程处理的时刻、事件名。
  private var handled: [(Double, String)] = []
  /// 交给界面的时刻、屏幕上的正文字节数、推理字节数。
  private var shown: [(Double, Int, Int)] = []

  private static func now() -> Double { Date().timeIntervalSince1970 }

  /// 这一轮层面的一个时刻（第一次为准）。
  func mark(_ name: String) {
    let t = Self.now()
    lock.lock(); defer { lock.unlock() }
    if marks[name] == nil { marks[name] = t }
  }

  func received(_ event: String, bytes: Int, text: Int = 0) {
    let t = Self.now()
    lock.lock(); defer { lock.unlock() }
    received.append((t, event, bytes, text))
  }

  func handled(_ event: String) {
    let t = Self.now()
    lock.lock(); defer { lock.unlock() }
    handled.append((t, event))
  }

  func shown(text: Int, thinking: Int) {
    let t = Self.now()
    lock.lock(); defer { lock.unlock() }
    shown.append((t, text, thinking))
  }

  /// 追加一行。写不了就算了 —— 计时不该让一轮对话出错。
  func write(meta: [String: Any]) {
    lock.lock()
    var record: [String: Any] = ["kind": "ui-turn"]
    for (key, value) in meta { record[key] = value }
    for (key, value) in marks { record[key] = value }
    record["received"] = received.map { [round4($0.0), $0.1, $0.2, $0.3] as [Any] }
    record["handled"] = handled.map { [round4($0.0), $0.1] as [Any] }
    record["shown"] = shown.map { [round4($0.0), $0.1, $0.2] as [Any] }
    lock.unlock()
    guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
    let url = Self.log
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data + Data("\n".utf8))
    } else {
      try? (data + Data("\n".utf8)).write(to: url)
    }
  }

  private func round4(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }
}
