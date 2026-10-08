import AppKit
import QuartzCore
import SwiftUI

/// The streaming message: what has been received and what is on screen are kept apart, and the
/// screen catches up every frame.
///
/// Chunks arrive in bursts, with pauses of a few hundred ms in between. Updating the transcript
/// every 50 ms left most frames unchanged and the rest jumping by dozens of bytes.
///
/// 1. Only the streaming row observes this. Per-frame changes never touch AgentSession.items,
///    whose updates recompute the whole panel at a cost that grows with history. The transcript
///    changes only at structural moments: first text, and finish().
/// 2. The screen always shows a prefix of what was received and catches up exponentially: each
///    frame reveals a fixed share of the backlog (time constant `catchUp`), at least one
///    character. Bursts unroll fast then slow, pauses settle smoothly.
///
/// Structural events (tool calls, approvals, a new step, the end) call finish(): the screen
/// catches up at once and the full text goes into the transcript, so narration stays ahead of
/// the tool call that follows it.
@MainActor
final class StreamPacer: NSObject, ObservableObject {

  /// Text and reasoning published as one value, so a frame where both move redraws once.
  struct Shown: Equatable {
    var text = ""
    var thinking = ""
  }

  @Published private(set) var shown = Shown()

  /// Each frame reveals 1 - e^(-dt/tau) of the backlog. 0.1 s keeps the average lag of the old
  /// 50 ms batching while moving every frame; smaller jumps, larger lags after a pause.
  static let catchUp: TimeInterval = 0.1

  /// off by default; records visible length on each publish
  var timing: AgentTiming?

  private var text = Channel()
  private var thinking = Channel()
  private var link: CADisplayLink?
  private var timer: Timer?
  private var lastTick: CFTimeInterval?

  /// both channels; for checks and benchmarks
  var backlog: Int { text.backlog + thinking.backlog }

  func receive(_ chunk: String, thinking isThinking: Bool) {
    guard !chunk.isEmpty else { return }
    if isThinking { thinking.append(chunk) } else { text.append(chunk) }
    startTicking()
  }

  /// Catch up at once and stop; returns the full text. Used for structural events and the end.
  @discardableResult
  func finish() -> Shown {
    text.revealAll()
    thinking.revealAll()
    stopTicking()
    publish(text: true, thinking: true)
    return Shown(text: text.target, thinking: thinking.target)
  }

  /// new message: clear
  func reset() {
    stopTicking()
    text = Channel()
    thinking = Channel()
    if shown != Shown() { shown = Shown() }
  }

  /// `now` is the frame timestamp; checks and benchmarks drive it with fixed times.
  func tick(at now: CFTimeInterval) {
    // clamp dt to [1/240, 0.1]: after the main thread was busy for half a second, don't dump half a
    // second of backlog in one frame
    let dt = lastTick.map { min(max(now - $0, 1.0 / 240), 0.1) } ?? (1.0 / 60)
    lastTick = now
    let movedText = text.advance(dt: dt, tau: Self.catchUp)
    let movedThinking = thinking.advance(dt: dt, tau: Self.catchUp)
    if movedText || movedThinking { publish(text: movedText, thinking: movedThinking) }
    if backlog == 0 { stopTicking() }
  }

  private func publish(text movedText: Bool, thinking movedThinking: Bool) {
    var next = shown
    if movedText { next.text = text.visible }
    if movedThinking { next.thinking = thinking.visible }
    if next != shown {
      shown = next
      timing?.shown(text: next.text.utf8.count, thinking: next.thinking.utf8.count)
    }
  }

  // MARK: - Frame clock

  /// Runs only while there is a backlog; idle means no work per frame.
  private func startTicking() {
    guard link == nil, timer == nil else { return }
    lastTick = nil
    if let screen = NSScreen.main {
      // Display link (NSScreen, macOS 14+): exactly once per frame, in step with SwiftUI. A plain Timer
      // drifts and sometimes fires twice or not at all in a frame.
      let link = screen.displayLink(target: self, selector: #selector(step(_:)))
      link.add(to: .main, forMode: .common)
      self.link = link
    } else {
      // no screen (headless): fall back to a 60 Hz timer so text still catches up
      timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.tick(at: CACurrentMediaTime()) }
      }
    }
  }

  private func stopTicking() {
    link?.invalidate()
    link = nil
    timer?.invalidate()
    timer = nil
  }

  @objc private func step(_ link: CADisplayLink) {
    tick(at: link.timestamp)
  }

  // MARK: - Channel

  private struct Channel {
    private(set) var target = ""
    /// A UTF-8 byte offset into `target`, always on a character boundary. Not a String.Index: indices
    /// aren't guaranteed valid after appending.
    private var shownBytes = 0
    private(set) var backlog = 0

    var visible: String {
      let utf8 = target.utf8
      return String(target[..<utf8.index(utf8.startIndex, offsetBy: shownBytes)])
    }

    mutating func append(_ chunk: String) {
      target += chunk
      backlog += chunk.count
    }

    mutating func revealAll() {
      shownBytes = target.utf8.count
      backlog = 0
    }

    /// Returns whether anything changed on screen.
    mutating func advance(dt: TimeInterval, tau: TimeInterval) -> Bool {
      guard backlog > 0 else { return false }
      let share = Double(backlog) * (1 - exp(-dt / tau))
      let step = min(backlog, max(1, Int(share.rounded(.up))))
      let utf8 = target.utf8
      let from = utf8.index(utf8.startIndex, offsetBy: shownBytes)
      let to = target.index(from, offsetBy: step, limitedBy: target.endIndex) ?? target.endIndex
      shownBytes = utf8.distance(from: utf8.startIndex, to: to)
      backlog -= step
      // Chunk sizes are counted separately, so a character split across chunks counts once extra. At
      // the end the backlog is zero by definition, or the clock would run for a phantom character.
      if to == target.endIndex { backlog = 0 }
      return true
    }
  }
}
