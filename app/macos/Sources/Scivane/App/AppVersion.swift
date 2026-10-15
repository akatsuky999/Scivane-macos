import Foundation

/// How the app names its own version: "0.1.0" and the day it was built. The packaging script stamps
/// the build number as a UTC timestamp (yyyyMMddHHmmss); people read a date, while a bug report
/// needs the exact build, which stays available as `build` (shown in tooltips, selectable).
enum AppVersion {
  /// "0.1.0"; nil when running outside a packaged app
  static var short: String? {
    nonEmpty(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
  }

  /// The full build number; nil when the bundle wasn't stamped (the template carries "1").
  static var build: String? {
    guard let raw = nonEmpty(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String),
          buildDate(raw) != nil else { return nil }
    return raw
  }

  /// "版本 0.1.0" / "Version 0.1.0", or a development build.
  static var title: String {
    guard let short else { return L("开发版本", "Development Build") }
    return L("版本 \(short)", "Version \(short)")
  }

  /// "2026年10月13日构建" / "Built October 13, 2026", in the local time zone; nil for a development
  /// build.
  static var built: String? {
    guard let build, let date = buildDate(build) else { return nil }
    let day = date.formatted(.dateTime.year().month(.wide).day()
      .locale(Localization.shared.language.locale))
    return L("\(day)构建", "Built \(day)")
  }

  /// Tooltip and copyable text: the exact build, for bug reports.
  static var detail: String {
    guard let build else { return title }
    return L("\(title)（构建号 \(build)）", "\(title) (build \(build))")
  }

  static func buildDate(_ stamp: String) -> Date? {
    guard stamp.count == 14, stamp.allSatisfy(\.isNumber) else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMddHHmmss"
    return formatter.date(from: stamp)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
    return value
  }
}
