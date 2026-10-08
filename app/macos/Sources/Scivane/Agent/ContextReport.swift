import Foundation

/// ContextReport.as_dict() from projects/meter.py: the payload of AgentEvent.CONTEXT and of
/// GET .../agent/context. Field names are a cross-language contract.
///
/// Measures one request. The turn's total (each step resends the whole context) is cost, kept in
/// AgentUsage.
struct ContextReport: Equatable {
  /// in request order
  enum Part: String, CaseIterable {
    case system, tools, paper, summary, history, turn
  }

  /// calibrated total, in tokens
  var used = 0
  var parts: [Part: Int] = [:]
  /// manual first, then reported. nil = unknown: no percentage and no auto-compaction.
  var window: Int?
  /// auto-compaction trigger
  var threshold: Int?
  /// calibrated against reported usage; shown with "≈" when false
  var measured = false
  /// including the turn in progress
  var turns = 0
  /// 0 = never compacted
  var covered = 0
  var compactions = 0
  /// true: a request being sent (this turn included); false: the forecast before the next question
  var live = false

  init() {}

  init(_ d: [String: Any]) {
    used = d["used"] as? Int ?? 0
    let raw = d["parts"] as? [String: Any] ?? [:]
    for part in Part.allCases {
      if let value = raw[part.rawValue] as? Int { parts[part] = value }
    }
    window = (d["window"] as? Int).flatMap { $0 > 0 ? $0 : nil }
    threshold = (d["threshold"] as? Int).flatMap { $0 > 0 ? $0 : nil }
    measured = d["measured"] as? Bool ?? false
    turns = d["turns"] as? Int ?? 0
    covered = d["covered"] as? Int ?? 0
    compactions = d["compactions"] as? Int ?? 0
    live = d["live"] as? Bool ?? false
  }

  func tokens(_ part: Part) -> Int { parts[part] ?? 0 }

  /// nil when the window is unknown
  var fraction: Double? {
    guard let window, window > 0 else { return nil }
    return min(1, Double(used) / Double(window))
  }

  /// window minus trigger: looks empty but isn't usable
  var reserve: Int {
    guard let window, let threshold else { return 0 }
    return max(0, window - threshold)
  }

  var free: Int {
    guard let window else { return 0 }
    return max(0, window - used - reserve)
  }
}

/// AgentEvent.COMPACTION. done carries the same fields as a restored `kind = compaction` item
/// (session.compaction_item).
struct CompactionEvent: Equatable {
  /// start / done / failed
  let phase: String
  /// auto / overflow / manual
  let trigger: String
  var summary = ""
  var turns = 0
  var kept = 0
  var before = 0
  var after = 0
  var code = ""
  var message = ""

  init(_ d: [String: Any]) {
    phase = d["phase"] as? String ?? "done"
    trigger = d["trigger"] as? String ?? "manual"
    summary = d["summary"] as? String ?? ""
    turns = d["turns"] as? Int ?? 0
    kept = d["kept"] as? Int ?? 0
    before = d["before"] as? Int ?? 0
    after = d["after"] as? Int ?? 0
    code = d["code"] as? String ?? ""
    message = d["message"] as? String ?? ""
  }
}
