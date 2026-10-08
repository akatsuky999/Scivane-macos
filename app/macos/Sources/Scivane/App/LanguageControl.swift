import SwiftUI

/// Language switch at the bottom of the sidebar, next to AppearanceControl. Settings > General has
/// the full version (LanguageSettings).
struct LanguageControl: View {
  var body: some View {
    let localization = Localization.shared
    Menu {
      Picker(selection: Binding(get: { localization.preference }, set: { localization.choose($0) })) {
        ForEach(LanguagePreference.allCases) { option in
          Text(LanguageSettings.menuTitle(option)).tag(option)
        }
      } label: {
        Text(L("界面语言", "Language"))
      }
      .pickerStyle(.inline).labelsHidden()
    } label: {
      Image(systemName: "globe")
        .font(.system(size: 11))
        .frame(width: 28, height: 25)
        .foregroundStyle(Palette.inkSoft.opacity(0.55))
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    .help(L("界面语言", "Language"))
    .accessibilityLabel(L("界面语言", "Language"))
    .accessibilityValue(localization.language.displayName)
  }
}

/// Language section in Settings > General, findable even by someone who switched by mistake:
/// the title is bilingual, language names use their own script, "Follow System" says what it
/// resolves to, and a button appears when the system menus need a relaunch.
struct LanguageSettings: View {
  /// relaunching would interrupt a running conversation or recognition
  var busy = false

  var body: some View {
    let localization = Localization.shared
    Section {
      Picker(L("界面语言", "Language"),
             selection: Binding(get: { localization.preference }, set: { localization.choose($0) })) {
        ForEach(LanguagePreference.allCases) { option in
          Text(Self.shortTitle(option)).tag(option)
        }
      }
      .pickerStyle(.segmented)

      VStack(alignment: .leading, spacing: 4) {
        let system = Localization.resolve(.system).displayName
        Text(L("「跟随系统」此刻是\(system)。切换立即生效；Agent 始终用你提问的语言回答。",
               "“System” is currently \(system). Changes apply right away; "
                 + "the agent always replies in the language you ask in."))
        if localization.menusLagBehind {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L("菜单栏里系统自带的项目（编辑、窗口、退出…）重新打开 Scivane 后切换。",
                   "Built-in menu items (Edit, Window, Quit…) switch after Scivane reopens."))
            Button(L("现在重新打开", "Reopen Now")) { Localization.relaunch() }
              .buttonStyle(.link).disabled(busy)
              .help(busy ? L("有对话或识别在跑，等它结束再重新打开",
                             "Something is still running — reopen when it finishes") : "")
          }
        }
      }
      .font(.uiCaption).foregroundStyle(Palette.inkFaint)
      .fixedSize(horizontal: false, vertical: true)
    } header: {
      Text(verbatim: "语言 · Language")  // 不翻: bilingual on purpose, so the section can be found in either language
    }
  }

  /// narrow segmented control: "Follow System" without the suffix
  static func shortTitle(_ option: LanguagePreference) -> String {
    switch option {
    case .system: return L("跟随系统", "System")
    case .zh: return AppLanguage.zh.nativeName
    case .en: return AppLanguage.en.nativeName
    }
  }

  /// menu: "Follow System" names the language it resolves to
  static func menuTitle(_ option: LanguagePreference) -> String {
    guard option == .system else { return shortTitle(option) }
    let system = Localization.resolve(.system).displayName
    return L("跟随系统 · \(system)", "System · \(system)")
  }
}
