import SwiftUI

/// Settings > General: appearance, language, export.
struct GeneralSettings: View {
  @ObservedObject var model: AppModel
  @AppStorage("sidebarOverlaysContent") private var sidebarOverlaysContent = true

  var body: some View {
    VStack(alignment: .leading, spacing: 26) {
      SettingsTitle(L("通用", "General"))

      SettingsSection(title: L("外观", "Appearance")) { AppearanceTiles() }

      SettingsSection(title: L("侧栏", "Sidebar")) {
        SettingsGroup {
          SettingsRow(title: L("侧栏覆盖阅读区", "Overlay the Reading Area")) {
            Toggle(L("侧栏覆盖阅读区", "Overlay the Reading Area"), isOn: $sidebarOverlaysContent)
              .labelsHidden().toggleStyle(.switch)
              .accessibilityIdentifier("sidebar-overlay-setting")
          }
        }
      }

      // bilingual on purpose: findable by someone who switched to a language they can't read
      SettingsSection(title: "语言 · Language") {  // 不翻: bilingual on purpose
        SettingsGroup { LanguageRows(busy: model.hasBackendWork) }
      }

      SettingsSection(title: L("导出", "Export")) {
        SettingsGroup { autoExport }
      }
    }
  }

  private var autoExport: some View {
    SettingsRow(title: L("识别完自动导出到", "After Recognition, Export To")) {
      HStack(spacing: 8) {
        HStack(spacing: 6) {
          Image(systemName: "folder").font(.system(size: 11))
          Text(model.autoExportDirectory.map(Self.abbreviated) ?? L("未设置", "Not set"))
            .lineLimit(1).truncationMode(.head)
        }
        .font(.system(size: 11.5, design: model.autoExportDirectory == nil ? .default : .monospaced))
        .foregroundStyle(model.autoExportDirectory == nil ? Palette.inkFaint : Palette.inkSoft)
        .padding(.horizontal, 9).frame(maxWidth: 220, minHeight: 28)
        .background(Palette.track, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(model.autoExportDirectory?.path ?? "")
        if model.autoExportDirectory != nil {
          Button(L("清除", "Clear")) { model.autoExportDirectory = nil }
            .buttonStyle(SettingsButtonStyle(kind: .destructive))
        }
        Button(L("选择…", "Choose…")) { model.chooseAutoExportDirectory() }
          .buttonStyle(SettingsButtonStyle())
      }
    }
  }

  /// the home folder as ~, as the Finder and Terminal show it
  static func abbreviated(_ url: URL) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
  }
}

/// Appearance as three small windows, the way macOS shows it: easier to pick by look than by name.
struct AppearanceTiles: View {
  @AppStorage("appearance") private var appearance: AppAppearance = .system

  var body: some View {
    HStack(spacing: 16) {
      ForEach(AppAppearance.allCases) { option in
        let selected = appearance == option
        Button { appearance = option } label: {
          VStack(spacing: 8) {
            AppearancePreview(option: option)
              .frame(width: 128, height: 82)
              .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
              .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                  .strokeBorder(selected ? Palette.accent : Palette.cardEdge, lineWidth: selected ? 2 : 1)
              }
              .overlay(alignment: .bottomTrailing) {
                if selected {
                  Image(systemName: "checkmark")
                    .font(.system(size: 8.5, weight: .bold)).foregroundStyle(Palette.paper)
                    .frame(width: 18, height: 18)
                    .background(Palette.accent, in: Circle())
                    .padding(6)
                }
              }
              .shadow(color: .black.opacity(selected ? 0.10 : 0.05), radius: selected ? 8 : 3, y: 2)
            Text(option.label)
              .font(.system(size: 12, weight: selected ? .semibold : .regular))
              .foregroundStyle(selected ? Palette.ink : Palette.inkSoft)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .onChange(of: appearance) { _, value in value.apply() }
  }
}

/// A window in miniature: its sidebar and a few lines of text, in the colors of one appearance.
/// System is drawn half light, half dark.
private struct AppearancePreview: View {
  let option: AppAppearance

  var body: some View {
    switch option {
    case .light: Miniature(dark: false)
    case .dark: Miniature(dark: true)
    case .system:
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Miniature(dark: false)
          Miniature(dark: true)
            .mask(alignment: .trailing) { Rectangle().frame(width: geo.size.width / 2) }
        }
      }
    }
  }

  private struct Miniature: View {
    let dark: Bool

    var body: some View {
      // fixed colors: the miniature shows an appearance, whatever the current one is
      let page = dark ? Color(red: 0.075, green: 0.095, blue: 0.08) : Color(red: 0.98, green: 0.975, blue: 0.96)
      let side = dark ? Color.white.opacity(0.10) : Color(red: 0.89, green: 0.92, blue: 0.88)
      let ink = dark ? Color(red: 0.91, green: 0.93, blue: 0.88) : Color(red: 0.13, green: 0.19, blue: 0.17)
      HStack(spacing: 7) {
        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(side).frame(width: 30)
        VStack(alignment: .leading, spacing: 5) {
          Capsule().fill(ink.opacity(0.32)).frame(width: 52, height: 4)
          Capsule().fill(ink.opacity(0.14)).frame(width: 70, height: 3)
          Capsule().fill(ink.opacity(0.14)).frame(width: 62, height: 3)
          Capsule().fill(ink.opacity(0.14)).frame(width: 48, height: 3)
          Spacer(minLength: 0)
        }
        .padding(.top, 13)
        Spacer(minLength: 0)
      }
      .padding(5)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(page)
    }
  }
}
