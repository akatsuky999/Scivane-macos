import SwiftUI

/// 侧栏底部的语言切换：一个地球，点开选。
///
/// 与 `AppearanceControl` 并排、同一种尺寸。设置页「通用」里有完整的一栏（`LanguageSettings`），
/// 这里是随手可够的那一处 —— 与外观一样两处入口。
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

/// 设置页「通用」里的语言一栏。
///
/// 三个小巧思，都来自同一个念头 —— **切错了语言的人也要找得回来**：
/// - 分节标题两种语言都写（「语言 · Language」），语言名用它自己的文字写（简体中文 / English）；
/// - 「跟随系统」后面写明它此刻落在哪一种，不必猜；
/// - 系统自带的菜单项要重新打开才跟上时，说出来、给一个按钮，而不是让人以为没切干净。
struct LanguageSettings: View {
  /// 有对话或识别在跑时，「现在重新打开」会把它们打断 —— 那时按钮不可点。
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
      Text(verbatim: "语言 · Language")  // 不翻：两种语言都写，切错了也认得出这一栏
    }
  }

  /// 分段控件里的字：窄，所以「跟随系统」不带后缀。
  static func shortTitle(_ option: LanguagePreference) -> String {
    switch option {
    case .system: return L("跟随系统", "System")
    case .zh: return AppLanguage.zh.nativeName
    case .en: return AppLanguage.en.nativeName
    }
  }

  /// 菜单里的字：宽，「跟随系统」后面写明它此刻落在哪一种。
  static func menuTitle(_ option: LanguagePreference) -> String {
    guard option == .system else { return shortTitle(option) }
    let system = Localization.resolve(.system).displayName
    return L("跟随系统 · \(system)", "System · \(system)")
  }
}
