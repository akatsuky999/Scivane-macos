// Exports Markdown together with the images it references.

import CryptoKit
import Foundation

enum MarkdownExporter {
  /// Export Markdown and copy its images into a sibling folder named `<file>.assets`.
  ///
  /// The name is fixed: a random suffix left a new folder per export, and deleting the extras broke
  /// the images of the exported files. Everything is written to a staging folder first and swapped
  /// in only when complete, so a failed export never destroys the previous one.
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
        // links use the final folder name, not the staging one
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

  private static func swap(_ staging: URL, into directory: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: directory.path) {
      // atomic on the same volume: on failure the old folder stays untouched
      _ = try fm.replaceItemAt(directory, withItemAt: staging)
    } else {
      try fm.moveItem(at: staging, to: directory)
    }
  }

  /// A stable prefix for images with the same name from different places, derived from the source
  /// path so repeated exports are identical.
  private static func stableTag(for source: URL) -> String {
    SHA256.hash(data: Data(source.standardizedFileURL.path.utf8))
      .prefix(4).map { String(format: "%02X", $0) }.joined()
  }
}
