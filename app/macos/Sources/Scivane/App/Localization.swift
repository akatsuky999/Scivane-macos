import AppKit
import Observation
import os

/// UI language: Chinese or English.
///
/// Human-facing text only; prompts, tool descriptions and tool results never follow it. The backend
/// learns it from X-Scivane-Language on every request (URLRequest(backend:)).
enum AppLanguage: String, CaseIterable, Sendable {
  case zh, en

  /// Each language's name in its own script, so the right option can always be found.
  var nativeName: String { self == .zh ? "简体中文" : "English" }  // 不翻: language names are always written in their own script
  /// The language's name in the current UI language, for use inside sentences.
  var displayName: String { self == .zh ? L("简体中文", "Simplified Chinese") : L("英文", "English") }
  /// code for macOS: AppleLanguages, Locale
  var code: String { self == .zh ? "zh-Hans" : "en" }
  var locale: Locale { Locale(identifier: code) }
}

/// Settings choice. `system` is the default: Chinese when the system prefers Simplified Chinese,
/// English otherwise.
enum LanguagePreference: String, CaseIterable, Identifiable, Sendable {
  case system, zh, en
  var id: String { rawValue }
}

/// The single home of the UI language.
///
/// Not .lproj and String(localized:): those need Bundle.module, which can't find resources in this
/// hand-assembled bundle, and they only switch on relaunch. Both variants sit on one line,
/// L("新建项目", "New Project"), so every string has its English.
///
/// `language` is an Observation property: views that read it through L() redraw in place when it
/// changes, keeping web views, scroll positions and streaming answers (no .id() rebuild). The
/// Observable conformance is hand-written and lock-protected because L() is also called off the
/// main thread.
final class Localization: Observable, @unchecked Sendable {

  static let shared = Localization(defaults: .standard)

  /// same header as the backend's i18n.HEADER; a cross-language contract
  static let header = "X-Scivane-Language"
  static let preferenceKey = "appLanguage"

  private let registrar = ObservationRegistrar()
  private let current: OSAllocatedUnfairLock<AppLanguage>
  private var stored: LanguagePreference
  /// nil means nothing is persisted (offscreen checks)
  private let defaults: UserDefaults?

  /// Language macOS chose for its own menus at launch. AppKit fixes built-in menu items and panel
  /// buttons from AppleLanguages at startup; when that differs, Settings offers a relaunch.
  let launchLanguage: AppLanguage

  init(defaults: UserDefaults?) {
    self.defaults = defaults
    let saved = defaults?.string(forKey: Self.preferenceKey).flatMap(LanguagePreference.init(rawValue:))
    stored = saved ?? .system
    current = OSAllocatedUnfairLock(initialState: Self.resolve(saved ?? .system))
    launchLanguage = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? .zh : .en
  }

  /// The current UI language; this is what L() reads.
  var language: AppLanguage {
    registrar.access(self, keyPath: \.language)
    return current.withLock { $0 }
  }

  var preference: LanguagePreference {
    registrar.access(self, keyPath: \.preference)
    return stored
  }

  @MainActor func choose(_ preference: LanguagePreference) {
    guard preference != stored else { return }
    registrar.withMutation(of: self, keyPath: \.preference) { stored = preference }
    if let defaults {
      defaults.set(preference.rawValue, forKey: Self.preferenceKey)
      // Built-in menus only pick their language at launch, so the choice is written to macOS for the
      // next launch. Following the system removes the override again.
      switch preference {
      case .system: defaults.removeObject(forKey: "AppleLanguages")
      case .zh, .en: defaults.set([Self.resolve(preference).code], forKey: "AppleLanguages")
      }
    }
    set(Self.resolve(preference))
  }

  /// Offscreen checks only: draw in another language without persisting anything.
  func override(_ language: AppLanguage) { set(language) }

  private func set(_ language: AppLanguage) {
    guard language != current.withLock({ $0 }) else { return }
    registrar.withMutation(of: self, keyPath: \.language) {
      current.withLock { $0 = language }
    }
  }

  static func resolve(_ preference: LanguagePreference) -> AppLanguage {
    switch preference {
    case .zh: return .zh
    case .en: return .en
    case .system: return match(systemLanguages())
    }
  }

  /// "Follow System" uses the same matching as macOS does for its own menus: zh-Hans-* is Chinese,
  /// everything else (Traditional Chinese, Japanese...) English.
  static func match(_ preferences: [String]) -> AppLanguage {
    let picked = Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: preferences)
    return picked.first == "zh-Hans" ? .zh : .en
  }

  /// Global language order, not this app's own domain, which is overwritten once a language is chosen.
  static func systemLanguages() -> [String] {
    CFPreferencesCopyAppValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication) as? [String]
      ?? Locale.preferredLanguages
  }

  /// Whether the built-in menus are still in another language until relaunch. Only meaningful in a
  /// real .app; offscreen checks and `swift run` have no declared localizations.
  var menusLagBehind: Bool {
    Bundle.main.bundleURL.pathExtension == "app" && language != launchLanguage
  }

  /// Relaunch so the built-in menus follow.
  ///
  /// Waits until this process has fully exited: quitting stops the backend synchronously, and a new
  /// instance starting earlier would collide with it on the same port.
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

/// Pick the variant for the current UI language. Call it in body so views redraw on change; to
/// store text that should follow later switches, store UIText instead of the returned String.
func L(_ zh: String, _ en: String) -> String {
  Localization.shared.language == .en ? en : zh
}

/// English plurals: plural(1, "tool", "tools") -> "1 tool".
func plural(_ count: Int, _ one: String, _ many: String) -> String {
  "\(count) \(count == 1 ? one : many)"
}

/// UI text that is stored and shown later (backend status, failure reasons, transcript notices).
/// Both variants are kept so text written before a switch follows it; backend wording, already in
/// one language, uses .verbatim.
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
  /// Every request to the local backend is built with this, carrying the UI language. Model-facing
  /// text is unaffected (the backend pins tool execution to Chinese).
  init(backend url: URL) {
    self.init(url: url)
    setValue(Localization.shared.language.rawValue, forHTTPHeaderField: Localization.header)
  }
}
