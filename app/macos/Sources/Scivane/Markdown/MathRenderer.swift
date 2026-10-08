import AppKit
import WebKit

/// Formulas in the conversation, typeset by KaTeX and kept as vector images.
///
/// The earlier hand translation to Unicode could never cover `cases`, `aligned`, `\binom` or
/// `\tag`, and paper translations are full of them. One hidden WebView serves the whole app as a
/// typesetter (one per message would be heavy); the transcript stays native, selectable and
/// wrapping. Output is PDF: vector at any size, and on a transparent background it works as a
/// template image that takes the text colour in light and dark mode. Exporting takes a millisecond
/// or two per formula.
///
/// When typesetting fails (KaTeX rejects it, the WebView can't start) views fall back to the draft
/// (MathDraft) or the source.
@MainActor
final class MathRenderer: NSObject {
  static let shared = MathRenderer()

  /// pixels per em in the page (see math.html); metrics and images are at this size and views scale
  static let referenceSize: CGFloat = 20

  /// One round trip per batch; too large and the first formula waits for the last.
  private static let batchLimit = 48

  /// each entry is a few KB of PDF; a long translation has tens to hundreds of formulas
  private static let capacity = 1500

  /// padding around the export, in reference px, so antialiasing and italic overhangs aren't clipped
  private static let margin = CGSize(width: 2, height: 1)

  struct Key: Hashable {
    let latex: String
    let display: Bool
  }

  struct Formula {
    fileprivate let page: NSPDFImageRep
    /// at the reference size, in pt
    let size: CGSize
    /// distance from the top to the baseline, at the reference size
    let ascent: CGFloat
    var descent: CGFloat { size.height - ascent }
  }

  enum Outcome {
    case typeset(Formula)
    /// KaTeX rejected it, usually malformed LaTeX; the UI shows the source
    case failed
  }

  private enum Phase { case idle, loading, ready, unavailable }
  private var phase = Phase.idle
  private var web: WKWebView?

  private var outcomes: [Key: Outcome] = [:]
  /// first in, first evicted
  private var arrival: [Key] = []
  /// Scaled images. The same size must return the same object; a new image per frame would be
  /// rasterised again on every frame while streaming.
  private var scaled: [Key: [Int: NSImage]] = [:]

  private var queue: [Key] = []
  private var queued: Set<Key> = []
  private var waiters: [Key: [CheckedContinuation<Void, Never>]] = [:]
  private var draining = false
  private var drainScheduled = false

  // MARK: - Lookup

  func outcome(_ key: Key) -> Outcome? { outcomes[key] }

  /// Template image scaled to `em` (pt), and how far its baseline sits above the bottom edge.
  func image(_ key: Key, em: CGFloat) -> (image: NSImage, descent: CGFloat)? {
    guard case .typeset(let formula)? = outcomes[key] else { return nil }
    // keyed by 0.1 pt, so dragging the slider doesn't store every intermediate size
    let tenths = max(1, Int((em * 10).rounded()))
    let scale = CGFloat(tenths) / 10 / Self.referenceSize
    let descent = formula.descent * scale
    if let image = scaled[key]?[tenths] { return (image, descent) }
    let page = formula.page
    let image = NSImage(
      size: CGSize(width: formula.size.width * scale, height: formula.size.height * scale),
      flipped: false
    ) { rect in
      page.draw(in: rect)
    }
    image.isTemplate = true
    scaled[key, default: [:]][tenths] = image
    return (image, descent)
  }

  // MARK: - Typesetting

  /// Warm-up: create the WebView, load the page and all fonts. About 0.2 s warm and 1 s on the first
  /// launch after boot, so it runs when the agent pane appears rather than at the first formula.
  func prepare() {
    if phase == .idle { load() }
  }

  /// Typeset these, skipping known ones; results are in outcome(_:) on return. If the typesetter
  /// can't start nothing is recorded and views keep the draft.
  func typeset(_ keys: [Key]) async {
    let missing = keys.filter { outcomes[$0] == nil }
    guard !missing.isEmpty else { return }
    prepare()
    guard phase != .unavailable else { return }
    for key in missing where !queued.contains(key) {
      queue.append(key)
      queued.insert(key)
    }
    scheduleDrain()
    for key in missing {
      await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
        // the closure runs synchronously with no suspension after the check: either done or queued
        if outcomes[key] != nil || !queued.contains(key) {
          waiter.resume()
        } else {
          waiters[key, default: []].append(waiter)
        }
      }
    }
  }

  /// Formulas requested in the same UI update form one batch, drained on the next main-queue turn.
  private func scheduleDrain() {
    guard !drainScheduled, !draining else { return }
    drainScheduled = true
    Task { @MainActor in await self.drain() }
  }

  private func drain() async {
    drainScheduled = false
    // still loading; it drains itself once ready
    guard !draining, phase == .ready else { return }
    draining = true
    defer { draining = false }
    while !queue.isEmpty, phase == .ready, let web {
      let batch = Array(queue.prefix(Self.batchLimit))
      queue.removeFirst(batch.count)
      await run(batch, on: web)
      for key in batch {
        queued.remove(key)
        for waiter in waiters.removeValue(forKey: key) ?? [] { waiter.resume() }
      }
    }
  }

  /// Typeset a batch, measure, export one by one. If the round trip fails (page gone, process died)
  /// nothing is recorded and the next request retries. Only an explicit KaTeX rejection is recorded
  /// as failed, since retrying wouldn't change it.
  private func run(_ batch: [Key], on web: WKWebView) async {
    let items: [[String: Any]] = batch.map { ["tex": $0.latex, "display": $0.display] }
    guard
      let reply = try? await web.callAsyncJavaScript(
        "return await renderBatch(items)", arguments: ["items": items], contentWorld: .page),
      let metrics = reply as? [Any], metrics.count == batch.count
    else { return }

    for (key, entry) in zip(batch, metrics) {
      guard let metric = entry as? [String: Any] else { continue }
      guard metric["ok"] as? Bool == true else {
        record(key, .failed)
        continue
      }
      guard
        let x = Self.number(metric["x"]), let y = Self.number(metric["y"]),
        let width = Self.number(metric["width"]), let height = Self.number(metric["height"]),
        let baseline = Self.number(metric["baseline"]), width > 0, height > 0
      else { continue }
      let margin = Self.margin
      let rect = CGRect(
        x: x - margin.width, y: y - margin.height,
        width: width + margin.width * 2, height: height + margin.height * 2)
      let configuration = WKPDFConfiguration()
      configuration.rect = rect
      guard
        let data = try? await web.pdf(configuration: configuration),
        let page = NSPDFImageRep(data: data)
      else { continue }
      record(key, .typeset(Formula(page: page, size: rect.size, ascent: baseline + margin.height)))
    }
  }

  private func record(_ key: Key, _ outcome: Outcome) {
    if outcomes.updateValue(outcome, forKey: key) == nil { arrival.append(key) }
    let overflow = arrival.count - Self.capacity
    guard overflow > 0 else { return }
    for old in arrival.prefix(overflow) {
      outcomes.removeValue(forKey: old)
      scaled.removeValue(forKey: old)
    }
    arrival.removeFirst(overflow)
  }

  private static func number(_ value: Any?) -> CGFloat? {
    (value as? NSNumber).map { CGFloat($0.doubleValue) }
  }

  // MARK: - The typesetter

  private func load() {
    guard let directory = WebResources.directory else { return giveUp() }
    let page = directory.appendingPathComponent("math.html")
    guard FileManager.default.fileExists(atPath: page.path) else { return giveUp() }
    phase = .loading
    // wide, so long formulas stay on one line
    let view = WKWebView(
      frame: CGRect(x: 0, y: 0, width: 2400, height: 1600), configuration: WKWebViewConfiguration())
    // transparent, so the exported PDF holds only glyphs and works as a template image
    view.setValue(false, forKey: "drawsBackground")
    view.navigationDelegate = self
    web = view
    view.loadFileURL(page, allowingReadAccessTo: directory)
  }

  private func fontsLoaded(on view: WKWebView) async {
    guard view === web else { return }
    do {
      _ = try await view.callAsyncJavaScript(
        "return await loadAllFonts()", arguments: [:], contentWorld: .page)
    } catch {
      return giveUp()
    }
    guard view === web else { return }
    phase = .ready
    scheduleDrain()
  }

  /// can't start: don't retry in this run, release everyone waiting (they keep the draft)
  private func giveUp() {
    NSLog("Scivane math: typesetter unavailable, formulas stay as drafts")
    phase = .unavailable
    web = nil
    abandon()
  }

  /// the web content process is gone (reclaimed, crashed): drop the WebView; the next request starts
  /// a new one
  private func reset() {
    phase = .idle
    web = nil
    abandon()
  }

  private func abandon() {
    queue.removeAll()
    queued.removeAll()
    let pending = waiters
    waiters.removeAll()
    for waiter in pending.values.joined() { waiter.resume() }
  }
}

extension MathRenderer: WKNavigationDelegate {
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    Task { await fontsLoaded(on: webView) }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    if webView === web { giveUp() }
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    if webView === web { giveUp() }
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    if webView === web { reset() }
  }
}
