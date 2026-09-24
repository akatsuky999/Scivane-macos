import AppKit
import Observation
import os

/// 界面语言：中文或英文。
///
/// **只管人看的字** —— 发给模型的提示词、工具描述、工具结果都不跟着它变。
/// 后端要说给人听的那些话（工具摘要、报错、安装步骤）由每个请求上的
/// `X-Scivane-Language` 告诉它（`URLRequest(backend:)`，后端见 `i18n.py`）。
enum AppLanguage: String, CaseIterable, Sendable {
  case zh, en

  /// 这门语言用它自己的文字写出来的名字。**设置里的选项永远这么写** ——
  /// 切错了语言的人，也认得出自己要的那一项。
  var nativeName: String { self == .zh ? "简体中文" : "English" }  // 不翻：语言名永远用它自己的文字
  /// 用**当前界面语言**说出这门语言：句子里提到它时用这个（「跟随系统」此刻落在哪一种）。
  /// 英文界面里夹一句「简体中文」，读的人未必认得。
  var displayName: String { self == .zh ? L("简体中文", "Simplified Chinese") : L("英文", "English") }
  /// 给 macOS 的代号：AppleLanguages、Locale。
  var code: String { self == .zh ? "zh-Hans" : "en" }
  var locale: Locale { Locale(identifier: code) }
}

/// 设置里的那一项。`system` 是默认：系统首选中文就是中文，其余一律英文。
enum LanguagePreference: String, CaseIterable, Identifiable, Sendable {
  case system, zh, en
  var id: String { rawValue }
}

/// 界面语言的唯一住处。
///
/// **为什么不用 `.lproj` 与 `String(localized:)`**：那一套要靠 `Bundle.module` 或资源编译找字符串表，
/// 而这个包是 `build_app.sh` 自己拼的（`Bundle.module` 在这里找不到资源，找不到就 `fatalError`）；
/// 它还要重开 App 才换得了语言。这里两种说法写在同一行 —— `L("新建项目", "New Project")`：
/// 编译器保证每一句都带着英文，中文原样留在代码里（二进制里照旧按中文串查得到）。
///
/// **为什么切了立刻生效、又不重建视图**：`language` 是 Observation 的属性。body 里调 `L()`
/// 就读了它，SwiftUI 记下这次读取；它一变，读过它的视图原地重画 —— 正文栏的 WebView、
/// 滚动位置、正在流式的回答都不受影响（不是 `.id()` 那种整棵重建）。
///
/// 手写 `Observable` 而不用宏：`L()` 也会在后台线程上被调（URLSession 的回调里拼报错），
/// 当前语言放进一把锁里，哪个线程读都安全。
final class Localization: Observable, @unchecked Sendable {

  static let shared = Localization(defaults: .standard)

  /// 请求头的名字。与后端 `i18n.HEADER` 是同一个 —— 跨语言契约。
  static let header = "X-Scivane-Language"
  static let preferenceKey = "appLanguage"

  private let registrar = ObservationRegistrar()
  private let current: OSAllocatedUnfairLock<AppLanguage>
  private var stored: LanguagePreference
  /// nil = 不落盘。离屏验证用这种实例，免得在别处的偏好域里留下东西。
  private let defaults: UserDefaults?

  /// 这次启动时 macOS 给系统菜单挑的语言。
  ///
  /// 菜单栏里系统自带的项目（编辑、窗口、退出）、存储面板的按钮，由 AppKit 在进程启动时
  /// 按 `AppleLanguages` 定死 —— 我们的字可以当场换，它们不行。两者不一致时，
  /// 设置页说一句「重新打开后切换」，并给一个按钮。
  let launchLanguage: AppLanguage

  init(defaults: UserDefaults?) {
    self.defaults = defaults
    let saved = defaults?.string(forKey: Self.preferenceKey).flatMap(LanguagePreference.init(rawValue:))
    stored = saved ?? .system
    current = OSAllocatedUnfairLock(initialState: Self.resolve(saved ?? .system))
    launchLanguage = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? .zh : .en
  }

  /// 此刻界面用哪种语言。**`L()` 读的就是它。**
  var language: AppLanguage {
    registrar.access(self, keyPath: \.language)
    return current.withLock { $0 }
  }

  /// 设置里选的那一项。
  var preference: LanguagePreference {
    registrar.access(self, keyPath: \.preference)
    return stored
  }

  /// 设置页与侧栏那个地球按钮调这个。
  @MainActor func choose(_ preference: LanguagePreference) {
    guard preference != stored else { return }
    registrar.withMutation(of: self, keyPath: \.preference) { stored = preference }
    if let defaults {
      defaults.set(preference.rawValue, forKey: Self.preferenceKey)
      // 系统自带的菜单项只在启动时定语言：把选择写给 macOS，下次启动它们就跟上。
      // 跟随系统时删掉这一项，交还给系统设置 —— 否则系统换了语言，这个 App 还停在旧的那种。
      switch preference {
      case .system: defaults.removeObject(forKey: "AppleLanguages")
      case .zh, .en: defaults.set([Self.resolve(preference).code], forKey: "AppleLanguages")
      }
    }
    set(Self.resolve(preference))
  }

  /// **只给离屏验证**：换一种语言画，不落盘、不碰 AppleLanguages。
  func override(_ language: AppLanguage) { set(language) }

  private func set(_ language: AppLanguage) {
    guard language != current.withLock({ $0 }) else { return }
    registrar.withMutation(of: self, keyPath: \.language) {
      current.withLock { $0 = language }
    }
  }

  /// 一项偏好落到哪种语言。
  static func resolve(_ preference: LanguagePreference) -> AppLanguage {
    switch preference {
    case .zh: return .zh
    case .en: return .en
    case .system: return match(systemLanguages())
    }
  }

  /// 「跟随系统」的规则 —— **与 macOS 给系统菜单挑语言的是同一个函数**，
  /// 两边因此永远说同一种话：`zh-Hans-*` → 中文；繁体、日文这类没有的一律英文；
  /// 日文在前、简体中文在后时取简体中文（实测）。
  static func match(_ preferences: [String]) -> AppLanguage {
    let picked = Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: preferences)
    return picked.first == "zh-Hans" ? .zh : .en
  }

  /// 系统设置里的语言顺序。**读全局那一份，不读这个 App 自己的** —— 手动选过语言之后，
  /// App 自己那一份被写成了那种语言，再读它就分不出「系统是什么」。
  static func systemLanguages() -> [String] {
    CFPreferencesCopyAppValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication) as? [String]
      ?? Locale.preferredLanguages
  }

  /// 系统菜单是不是还停在另一种语言上（要重新打开才跟得上）。
  ///
  /// 只在真的 .app 里算数：离屏验证与 `swift run` 没有 Info.plist 声明的本地化，
  /// AppKit 在那里永远是英文，提示了也没有意义。
  var menusLagBehind: Bool {
    Bundle.main.bundleURL.pathExtension == "app" && language != launchLanguage
  }

  /// 重新打开 Scivane，让系统菜单跟上。
  ///
  /// **等这个进程真的退干净再打开**：退出时要同步收掉后端（`BackendManager.stop`），
  /// 新实例若抢在那之前起来，会和旧后端撞在同一个端口上。所以不用
  /// `createsNewApplicationInstance`，而是交给一个小 shell 等旧进程消失。
  @MainActor static func relaunch() {
    let waiter = Process()
    waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
    waiter.arguments = [
      "-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; "
        + "do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
      Bundle.main.bundleURL.path,
    ]
    guard (try? waiter.run()) != nil else { return }
    NSApp.terminate(nil)
  }
}

/// 一句界面文字的两种说法，按当前界面语言挑一种。
///
/// **在 body 里调**：它读的是 Observation 属性，语言一变，读过它的视图原地重画。
/// 要**存下来**、切换之后也跟着换的话，存 `UIText`，别存这里返回的 String。
func L(_ zh: String, _ en: String) -> String {
  Localization.shared.language == .en ? en : zh
}

/// 英文的单复数：`plural(1, "tool", "tools")` → "1 tool"。中文没有这回事，所以只在英文那一半用。
func plural(_ count: Int, _ one: String, _ many: String) -> String {
  "\(count) \(count == 1 ? one : many)"
}

/// 一句要**存下来**、之后再显示的界面文字：后端状态、任务失败的原因、对话流里的提示。
///
/// 存 String 的话，切换语言之前写下的那句就停在旧语言里；存两种说法，显示时再挑。
/// 后端给的原话本来就只有一种（它按请求那一刻的界面语言说），用 `.verbatim`。
struct UIText: Hashable, Sendable {
  let zh: String
  let en: String

  init(_ zh: String, _ en: String) {
    self.zh = zh
    self.en = en
  }

  static func verbatim(_ text: String) -> UIText { UIText(text, text) }

  var text: String { L(zh, en) }
  var isEmpty: Bool { zh.isEmpty && en.isEmpty }
}

extension URLRequest {
  /// 发给本机后端的请求。**一律用它建** —— 带上界面语言，后端据此说给人看的那些话；
  /// 给模型看的不受它影响（后端 `i18n.py` 在工具执行期把语言钉成中文）。
  init(backend url: URL) {
    self.init(url: url)
    setValue(Localization.shared.language.rawValue, forHTTPHeaderField: Localization.header)
  }
}
