import CryptoKit
import Foundation

/// Reopening an unchanged source can reuse its completed OCR; images stay in var/jobs.
@MainActor enum ResultCache {
  private struct Entry: Codable {
    let fingerprint: String?
    let size: Int?
    let modified: Date?
    let pages: [Int: String]
    let markdown: String
    let seconds: Double
  }
  private static func location(_ job: DocumentJob, _ root: URL) -> URL {
    let key = SHA256.hash(data: Data(job.url.path.utf8)).map { String(format: "%02x", $0) }.joined()
    return root.appendingPathComponent("results/" + key + ".json")
  }
  private static func fingerprint(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  static func save(_ job: DocumentJob, root: URL) {
    guard let fingerprint = fingerprint(job.url) else { return }
    let file = location(job, root)
    do {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(
        Entry(
          fingerprint: fingerprint, size: nil, modified: nil, pages: job.pages, markdown: job.markdown, seconds: job.elapsed)
      ).write(to: file, options: .atomic)
    } catch { NSLog("Scivane result cache: %@", error.localizedDescription) }
  }
private static func matches(_ entry: Entry, source: URL) -> Bool {
  if let digest = entry.fingerprint { return digest == fingerprint(source) }
  // Migrate results produced by the first manual-OCR build in this update.
  guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
        let size = attributes[.size] as? Int, let modified = attributes[.modificationDate] as? Date,
        let oldDate = entry.modified, entry.size == size else { return false }
  return abs(oldDate.timeIntervalSince(modified)) < 0.001
}
  static func restore(_ job: DocumentJob, root: URL) {
    guard let data = try? Data(contentsOf: location(job, root)),
      let e = try? JSONDecoder().decode(Entry.self, from: data),
      matches(e, source: job.url)
    else { return }
    job.pages = e.pages
    job.consolidated = e.markdown
    job.elapsed = e.seconds
    job.status = .finished(seconds: e.seconds)
    if e.fingerprint == nil { save(job, root: root) }
  }
}
