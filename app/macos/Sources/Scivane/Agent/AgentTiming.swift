import Foundation

/// App-side timing of one turn. The backend half is llm/timing.py; this records when the request
/// went out, when headers arrived, when each event was decoded (URLSession thread), when the main
/// thread handled it, and when text was handed to the UI (each StreamPacer publish). Both sides use
/// wall-clock time, so the records line up and show which layer is slow.
///
/// Off by default. Enable with SCIVANE_TIMING=1 (checks) or
/// `defaults write local.scivane.app agentTiming -bool YES` (next launch); the app then passes
/// SCIVANE_TIMING=1 to its backend. Writes one line per turn to <var>/logs/ui-timing.jsonl:
/// times, event names and byte counts only, never content or credentials.
final class AgentTiming: @unchecked Sendable {

  /// read once at launch, so a turn is never half recorded
  static let enabled: Bool =
    ProcessInfo.processInfo.environment["SCIVANE_TIMING"] == "1"
    || UserDefaults.standard.bool(forKey: "agentTiming")

  static var log: URL {
    BackendManager.currentVarRoot.appendingPathComponent("logs/ui-timing.jsonl")
  }

  private let lock = NSLock()
  private var marks: [String: Double] = [:]
  /// time, event, frame bytes, text or reasoning bytes
  private var received: [(Double, String, Int, Int)] = []
  /// time, event
  private var handled: [(Double, String)] = []
  /// time, visible text bytes, visible reasoning bytes
  private var shown: [(Double, Int, Int)] = []

  private static func now() -> Double { Date().timeIntervalSince1970 }

  /// first occurrence wins
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

  /// Best effort: timing must never fail a turn.
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
