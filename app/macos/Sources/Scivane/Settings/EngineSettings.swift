import SwiftUI

/// Settings > Local Engine: the service's state, the optional local OCR, where things live, and
/// when the engine stops by itself.
struct EngineSettings: View {
  @ObservedObject var backend: BackendManager
  @ObservedObject var model: AppModel
  /// the OCR status is asked for when this page is shown, not whenever Settings opens
  var visible: Bool

  @State private var projectPath = ""
  @State private var runtimePath = ""
  /// what the engine was last started with, to tell whether the fields still need a restart
  @State private var appliedProject = ""
  @State private var appliedRuntime = ""
  @State private var idleMinutes: Double = 5

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      SettingsTitle(L("本地引擎", "Local Engine"))
      status

      SettingsSection(title: L("组件", "Components")) {
        SettingsGroup { OCRRuntimeRow(installer: model.ocrInstaller, visible: visible) }
      }

      SettingsSection(title: L("位置", "Locations")) {
        SettingsGroup {
          pathRow(L("项目目录", "Scivane Folder"), text: $projectPath, prompt: "",
                  message: L("选择 Scivane 项目目录", "Choose the Scivane folder"))
          SettingsDivider()
          pathRow(L("模型运行时", "Model Runtime"), text: $runtimePath,
                  prompt: L("自动发现", "Found automatically"),
                  message: L("选择模型运行时目录", "Choose the model runtime folder"))
        }
      }

      SettingsSection(title: L("内存", "Memory")) {
        SettingsGroup {
          SettingsRow(title: L("闲置自动停", "Stop When Idle")) {
            PillPicker(options: [2.0, 5.0, 15.0, 0.0], selection: $idleMinutes, name: Self.idleName) { value, selected in
              Text(Self.idleName(value))
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Palette.ink : Palette.inkSoft)
            }
          }
        }
      }
    }
    .onAppear {
      projectPath = (try? backend.install.get())?.root.path ?? ""
      runtimePath = backend.runtimeOverride?.path ?? ""
      appliedProject = projectPath
      appliedRuntime = runtimePath
      idleMinutes = backend.idleTimeout / 60
    }
    .onChange(of: idleMinutes) { _, minutes in backend.idleTimeout = minutes * 60 }
  }

  // MARK: - Status

  private var status: some View {
    HStack(spacing: 14) {
      ZStack(alignment: .bottomTrailing) {
        Image(systemName: "cpu")
          .font(.system(size: 18, weight: .regular))
          .foregroundStyle(tone)
          .frame(width: 42, height: 42)
          .background(tone.opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        Circle().fill(tone).frame(width: 11, height: 11)
          .overlay(Circle().strokeBorder(Palette.cardSolid, lineWidth: 2.5))
          .offset(x: 3, y: 3)
      }
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 7) {
          Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
          if case .ready = backend.state, let mode = backend.runningMode {
            SettingsTag(text: mode == .full ? L("完整模式", "Full") : L("轻量模式", "Light"))
          }
        }
        if let detail {
          Text(detail)
            .font(.system(size: 11, design: isAddress ? .monospaced : .default))
            .foregroundStyle(isFailure ? Palette.danger : Palette.inkFaint)
            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
      Spacer(minLength: 12)
      Button { restart() } label: {
        Label(L("重启引擎", "Restart Engine"), systemImage: "arrow.clockwise")
          .labelStyle(.titleAndIcon)
      }
      .buttonStyle(SettingsButtonStyle())
      // changed paths only take effect on a restart: the button says so, no sentence needed
      .overlay(alignment: .topTrailing) {
        if pathsChanged {
          Circle().fill(Palette.accent).frame(width: 7, height: 7).offset(x: 2, y: -2)
            .accessibilityHidden(true)
        }
      }
      .help(pathsChanged ? L("位置改了，重启后生效", "Restart to use the new locations") : "")
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(radius: 16)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(L("引擎状态：\(title)", "Engine: \(title)"))
  }

  private var title: String {
    switch backend.state {
    case .idle: return backend.stoppedForIdle ? L("已闲置停止", "Stopped When Idle") : L("未启动", "Not Running")
    case .launching: return L("启动中", "Starting")
    case .ready: return L("运行中", "Running")
    case .failed: return L("启动失败", "Failed to Start")
    }
  }

  private var detail: String? {
    switch backend.state {
    case .idle: return backend.stoppedForIdle ? L("下次识别时自动启动", "Starts again for the next recognition") : nil
    case .launching(let step): return step.text
    case .ready: return backend.apiBase.host.map { "\($0):\(backend.apiBase.port ?? 0)" }
    case .failed(let message): return message.text
    }
  }

  private var isAddress: Bool { backend.state.isReady }
  private var isFailure: Bool { if case .failed = backend.state { return true } else { return false } }

  private var tone: Color {
    switch backend.state {
    case .ready: return Palette.ok
    case .launching: return Palette.pending
    case .failed: return Palette.danger
    case .idle: return Palette.inkFaint
    }
  }

  // MARK: - Locations

  private var pathsChanged: Bool {
    projectPath.trimmingCharacters(in: .whitespaces) != appliedProject
      || runtimePath.trimmingCharacters(in: .whitespaces) != appliedRuntime
  }

  private func pathRow(_ title: String, text: Binding<String>, prompt: String, message: String) -> some View {
    HStack(spacing: 10) {
      Text(title).font(.system(size: 13)).foregroundStyle(Palette.ink)
        .frame(width: 96, alignment: .leading)
      TextField("", text: text, prompt: Text(prompt))
        .settingsField(monospaced: true)
        .accessibilityLabel(title)
      Button(L("选择…", "Choose…")) { choose(text, message: message) }
        .buttonStyle(SettingsButtonStyle())
    }
    .padding(.leading, 16).padding(.trailing, 10)
    .frame(minHeight: SettingsMetrics.row)
  }

  private func choose(_ binding: Binding<String>, message: String) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.message = message
    panel.prompt = L("选择", "Choose")
    if panel.runModal() == .OK, let url = panel.url { binding.wrappedValue = url.path }
  }

  private func restart() {
    let project = projectPath.trimmingCharacters(in: .whitespaces)
    let runtime = runtimePath.trimmingCharacters(in: .whitespaces)
    backend.useBackendLocation(project)
    backend.runtimeOverride = runtime.isEmpty ? nil : URL(fileURLWithPath: runtime)
    backend.restart()
    appliedProject = project
    appliedRuntime = runtime
  }

  static func idleName(_ minutes: Double) -> String {
    minutes == 0 ? L("不停", "Never") : L("\(Int(minutes)) 分钟", "\(Int(minutes)) min")
  }
}
