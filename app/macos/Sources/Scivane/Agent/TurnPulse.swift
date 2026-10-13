import Foundation

/// What the model is doing while nothing reaches the transcript: writing a tool call's
/// arguments, or sending nothing at all.
///
/// A whole document passed to one call can take minutes, and a ticking counter alone can't tell
/// "writing" from "stalled". Kept apart from AgentSession (like StreamPacer) because it changes
/// several times a second and only the status line observes it.
@MainActor
final class TurnPulse: ObservableObject {

  struct Draft: Equatable {
    let tool: String
    let chars: Int
  }

  /// the tool call being written, from tool_input events; nil once it arrives whole
  @Published private(set) var draft: Draft?
  /// When the model last sent anything, once it has been quiet for `threshold` seconds; nil while
  /// it is talking or between model requests.
  @Published private(set) var quietSince: Date?

  /// Below this a pause is ordinary (time to first token, a short think).
  static let threshold = 15

  func drafting(_ tool: String, chars: Int) {
    let next = Draft(tool: tool, chars: chars)
    if draft != next { draft = next }
    heard()
  }

  /// Anything from the model. Called per chunk, so it only writes when something changes.
  func heard() {
    if quietSince != nil { quietSince = nil }
  }

  /// A call arrived whole or a new step began.
  func settled() {
    if draft != nil { draft = nil }
    heard()
  }

  /// From a heartbeat: seconds the open stream has been silent, nil when none is open.
  func quiet(_ seconds: Int?) {
    guard let seconds, seconds >= Self.threshold else {
      if seconds == nil { heard() }
      return
    }
    // keep the first anchor: later heartbeats round differently and the counter would jump
    if quietSince == nil { quietSince = Date().addingTimeInterval(-Double(seconds)) }
  }

  func reset() {
    if draft != nil { draft = nil }
    heard()
  }
}
