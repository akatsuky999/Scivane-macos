// URL scheme handlers that serve images to the WKWebView. Not file://, which would expose the
// whole file system: every request passes LocalAssets.resolve()'s boundary check.
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import WebKit

/// Resolves only the OCR artifact namespace, including symlink containment.
enum LocalAssets {
  static func resolve(_ path: String, root: URL) -> URL? {
    guard path.hasPrefix("/assets/") else { return nil }
    let relative = String(path.dropFirst("/assets/".count)).removingPercentEncoding ?? ""
    let base = root.resolvingSymlinksInPath().standardizedFileURL
    let file = base.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
    guard file.path.hasPrefix(base.path + "/"),
      (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    else { return nil }
    return file
  }
}

/// Reading an existing result must not require waking a 2 GB inference engine.
final class LocalAssetHandler: NSObject, WKURLSchemeHandler {
  let root: URL
  init(root: URL) { self.root = root }
  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    guard let url = task.request.url, url.host == "local",
      let file = LocalAssets.resolve(url.path, root: root)
    else {
      task.didFailWithError(URLError(.fileDoesNotExist))
      return
    }
    do {
      let data = try Data(contentsOf: file)
      let mime =
        UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
        ?? "application/octet-stream"
      task.didReceive(
        URLResponse(
          url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
      task.didReceive(data)
      task.didFinish()
    } catch { task.didFailWithError(error) }
  }
  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class DocumentAssetHandler: NSObject, WKURLSchemeHandler {
  let directory: () -> URL?
  init(directory: @escaping () -> URL?) { self.directory = directory }
  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    guard let url = task.request.url, url.host == "local", let root = directory(),
      let file = LocalAssets.resolve("/assets/" + url.path.drop(while: { $0 == "/" }), root: root)
    else {
      task.didFailWithError(URLError(.fileDoesNotExist))
      return
    }
    do {
      let data = try Data(contentsOf: file)
      task.didReceive(
        URLResponse(
          url: url,
          mimeType: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream", expectedContentLength: data.count, textEncodingName: nil)
      )
      task.didReceive(data)
      task.didFinish()
    } catch { task.didFailWithError(error) }
  }
  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
