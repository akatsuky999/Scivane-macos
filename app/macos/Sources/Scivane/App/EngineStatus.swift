import SwiftUI

/// The service's state in the words and colors every surface uses: the sidebar's capsule, the
/// settings navigation and the engine page say the same thing.
extension BackendManager {
  /// one word, for the sidebar's capsule
  var statusWord: String {
    switch state {
    case .idle: return stoppedForIdle ? L("已停", "Idle") : L("未启动", "Stopped")
    case .launching: return L("启动中", "Starting")
    case .ready: return L("就绪", "Ready")
    case .failed: return L("失败", "Failed")
    }
  }

  /// a short phrase, where there is room; the settings navigation fits about fifteen characters
  var statusTitle: String {
    switch state {
    case .idle: return stoppedForIdle ? L("闲置已停止", "Idle") : L("服务未启动", "Not started")
    case .launching: return L("正在启动服务", "Starting")
    case .ready:
      return runningMode == .full ? L("本地引擎就绪", "Engine ready") : L("服务就绪", "Ready")
    case .failed: return L("服务启动失败", "Failed to start")
    }
  }

  /// tooltip: why it failed, or what the light mode means
  var statusDetail: String {
    if case .failed(let message) = state { return message.text }
    if case .launching(let step) = state { return step.text }
    return runningMode == .lite
      ? L("需要识别文档时加载本地模型", "The local model loads when a document needs OCR") : statusTitle
  }

  var statusTone: Color {
    switch state {
    case .ready: return Palette.ok
    case .launching: return Palette.pending
    case .failed: return Palette.danger
    case .idle: return Palette.inkFaint
    }
  }
}

/// The state as a dot with a soft halo; the halo only while healthy, so a failure doesn't glow.
struct StatusDot: View {
  let tone: Color
  var size: CGFloat = 7
  var halo = true

  var body: some View {
    Circle().fill(tone).frame(width: size, height: size)
      .background(Circle().fill(tone.opacity(halo ? 0.18 : 0)).frame(width: size + 6, height: size + 6))
      .accessibilityHidden(true)
  }
}
