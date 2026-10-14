import SwiftUI

/// Names of the language choices, shared by the sidebar menu and Settings > General.
enum LanguageNames {
  /// segmented control: "System" without the language it resolves to
  static func shortTitle(_ option: LanguagePreference) -> String {
    switch option {
    case .system: return L("跟随系统", "System")
    case .zh: return AppLanguage.zh.nativeName
    case .en: return AppLanguage.en.nativeName
    }
  }

  /// menu: "System" names the language it resolves to
  static func menuTitle(_ option: LanguagePreference) -> String {
    guard option == .system else { return shortTitle(option) }
    let system = Localization.resolve(.system).displayName
    return L("跟随系统 · \(system)", "System · \(system)")
  }

  /// the compact label: the language in use, in its own script
  static var code: String { L("中", "EN") }
}

/// The sidebar's language switch: the language in use as a label, the three choices in a menu.
/// `.menuStyle(.button)` with a plain button style keeps the label's own type; the native menu style
/// keeps only its first text and drops size and weight.
struct LanguageMenu: View {
  var width: CGFloat = 28
  var height: CGFloat = 24

  var body: some View {
    let localization = Localization.shared
    Menu {
      Picker(selection: Binding(get: { localization.preference }, set: { localization.choose($0) })) {
        ForEach(LanguagePreference.allCases) { option in
          Text(LanguageNames.menuTitle(option)).tag(option)
        }
      } label: {
        Text(L("界面语言", "Language"))
      }
      .pickerStyle(.inline).labelsHidden()
    } label: {
      Text(LanguageNames.code)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Palette.inkSoft)
        .frame(width: width, height: height)
        .contentShape(Rectangle())
    }
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    .help(L("界面语言", "Language"))
    .accessibilityLabel(L("界面语言", "Language"))
    .accessibilityValue(localization.language.displayName)
  }
}

/// Settings > General: the language row, findable even by someone who switched by mistake (the
/// section label is bilingual), with a way to reopen when the system menus lag behind.
struct LanguageRows: View {
  /// relaunching would interrupt a running conversation or recognition
  var busy = false

  var body: some View {
    let localization = Localization.shared
    SettingsRow(title: L("界面语言", "Interface Language"), detail: currentDetail) {
      PillPicker(
        options: LanguagePreference.allCases,
        selection: Binding(get: { localization.preference }, set: { localization.choose($0) }),
        name: LanguageNames.menuTitle
      ) { option, selected in
        Text(LanguageNames.shortTitle(option))
          .font(.system(size: 12, weight: selected ? .semibold : .regular))
          .foregroundStyle(selected ? Palette.ink : Palette.inkSoft)
      }
    }
    if localization.menusLagBehind {
      SettingsDivider()
      SettingsRow(title: L("系统菜单重新打开后切换", "System menus switch after reopening")) {
        Button(L("现在重新打开", "Reopen Now")) { Localization.relaunch() }
          .buttonStyle(SettingsButtonStyle())
          .disabled(busy)
          .help(busy ? L("有对话或识别在跑，等它结束再重新打开",
                         "Something is still running — reopen when it finishes") : "")
      }
    }
  }

  /// what "System" resolves to right now; nothing to add for an explicit choice
  private var currentDetail: String? {
    guard Localization.shared.preference == .system else { return nil }
    let system = Localization.resolve(.system).displayName
    return L("当前：\(system)", "Currently \(system)")
  }
}
