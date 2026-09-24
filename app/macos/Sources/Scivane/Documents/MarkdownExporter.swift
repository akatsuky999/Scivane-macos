// 导出 Markdown，并把它引用的图片一并带走。
//
// 从 LocalAssets.swift 里拆出来的：那个文件原先同时装着「Web 资源处理器」
// 与「导出」两件不相干的事，按文件名谁也找不到导出在哪。

import CryptoKit
import Foundation

enum MarkdownExporter {
  /// 导出 Markdown，把它引用的图片一并复制到**一个固定名字的**同级文件夹里。
  ///
  /// 文件夹名是 `<md 文件名>.assets`，**不带随机后缀**。早先每次导出都拼一个
  /// 新的 UUID 后缀（`.assets-3F2A1B7C`），后果是同一份文档导出三次就在桌面上
  /// 留下三个文件夹，而且名字看不出哪个配哪份 md；用户把它当垃圾删掉之后，
  /// 已经导出的那份 md 里的图会全部变成断链。
  ///
  /// 「不能因为导出中途失败而毁掉上一次的图」这个顾虑仍然成立，所以改成
  /// **先写进同级的临时目录，全部成功之后再整体换上去** —— 固定名字与
  /// 崩溃安全两者都要。
  static func write(
    _ markdown: String, to target: URL, assetsRoot: URL?, sourceDirectory: URL? = nil
  ) throws {
    let pattern = #"/assets/[A-Za-z0-9_-]+/[^\s\"'<>\)]+"#
    let regex = try NSRegularExpression(pattern: pattern)
    var paths = Set(
      regex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown))
        .compactMap { Range($0.range, in: markdown).map { String(markdown[$0]) } })
    var localSources: [String: URL] = [:]
    if let sourceDirectory {
      // Inline Markdown, reference definitions and raw HTML image sources.
      let patterns = [
        #"!\[[^\]]*\]\(\s*<?([^\n]+?)>?\s*\)"#, #"(?m)^\s*\[[^\]]+\]:\s*<?([^\n]+?)>?\s*$"#,
        #"(?i)<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#,
      ]
      for pattern in patterns {
        let exp = try NSRegularExpression(pattern: pattern)
        for match in exp.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown))
        {
          guard let range = Range(match.range(at: 1), in: markdown) else { continue }
          let path = String(markdown[range]).components(separatedBy: " \"").first!
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
          guard !path.hasPrefix("/assets/"), URL(string: path)?.scheme == nil else { continue }
          guard let file = LocalAssets.resolve("/assets/" + path, root: sourceDirectory) else {
            throw CocoaError(.fileReadNoSuchFile)
          }
          localSources[path] = file
          paths.insert(path)
        }
      }
    }
    guard !paths.isEmpty else {
      try markdown.write(to: target, atomically: true, encoding: .utf8)
      return
    }

    let parent = target.deletingLastPathComponent()
    let directoryName = target.deletingPathExtension().lastPathComponent + ".assets"
    let directory = parent.appendingPathComponent(directoryName)
    // 先全写进临时目录，成功了再整体换上去。中途失败不该毁掉上一次导出的图。
    let staging = parent.appendingPathComponent(
      directoryName + ".partial-" + UUID().uuidString.prefix(8))
    var output = markdown
    do {
      for path in paths.sorted(by: { $0.count > $1.count }) {
        guard
          let source = localSources[path]
            ?? assetsRoot.flatMap({ LocalAssets.resolve(path, root: $0) })
        else { throw CocoaError(.fileReadNoSuchFile) }
        let relative =
          localSources[path] != nil
          ? "local/" + MarkdownExporter.stableTag(for: source) + "-" + source.lastPathComponent
          : (String(path.dropFirst("/assets/".count)).removingPercentEncoding ?? "")
        let destination = staging.appendingPathComponent(relative).standardizedFileURL
        guard destination.path.hasPrefix(staging.standardizedFileURL.path + "/") else {
          throw CocoaError(.fileReadInvalidFileName)
        }
        try FileManager.default.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
        // 链接写的是**最终**的固定目录名，不是临时目录
        let link = (directoryName + "/" + relative).addingPercentEncoding(
          withAllowedCharacters: allowed)!
        output = output.replacingOccurrences(of: path, with: link)
      }
      try output.write(to: target, atomically: true, encoding: .utf8)
      try MarkdownExporter.swap(staging, into: directory)
    } catch {
      try? FileManager.default.removeItem(at: staging)
      throw error
    }
  }

  /// 把临时目录换成正式目录。原来那个存在就整体替换，不存在就直接改名。
  private static func swap(_ staging: URL, into directory: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: directory.path) {
      // replaceItemAt 在同一卷上是原子的：换不成功的话旧的那份原封不动
      _ = try fm.replaceItemAt(directory, withItemAt: staging)
    } else {
      try fm.moveItem(at: staging, to: directory)
    }
  }

  /// 给同名不同处的图片一个**稳定**的前缀，避免撞名。
  ///
  /// 早先用 `UUID().prefix(8)`，于是同一份文档导出两次，文件夹里的图片名字
  /// 全不一样 —— 导出结果不可复现，也没法用 diff 看两次导出差在哪。
  /// 换成源路径的哈希：同一个来源永远是同一个前缀。
  private static func stableTag(for source: URL) -> String {
    SHA256.hash(data: Data(source.standardizedFileURL.path.utf8))
      .prefix(4).map { String(format: "%02X", $0) }.joined()
  }
}
