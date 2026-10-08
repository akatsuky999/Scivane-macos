import SwiftUI
import WebKit

/// Text pane: rendered Markdown in a WKWebView, since the OCR output contains LaTeX and HTML
/// tables that SwiftUI can't lay out.
struct MarkdownWebView: NSViewRepresentable {

    @ObservedObject var model: AppModel
    /// Passed in explicitly so a change always goes through updateNSView, rather than relying on
    /// Observation tracking inside an AppKit view.
    var language: AppLanguage = .zh
    @AppStorage("readerFontSize") private var fontSize = 17.0
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalAssetHandler(root: model.backend.jobsRoot), forURLScheme: "scivane-asset")
        config.setURLSchemeHandler(DocumentAssetHandler(directory: { [weak model] in model?.readingDocument?.isMarkdown == true ? model?.readingDocument?.url.deletingLastPathComponent() : nil }), forURLScheme: "scivane-document")
        config.userContentController.add(context.coordinator, name: "scivane")
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")   // let the body background show through; avoids a white flash
        web.allowsMagnification = true
        web.allowsBackForwardNavigationGestures = false

        context.coordinator.web = web
        context.coordinator.load()

        // the model calls JS through this; the view holds no rendering logic
        model.renderBridge = { [weak coordinator = context.coordinator] fn, args in
            coordinator?.call(fn, args)
        }
        // replay pages that arrived before the WebView existed
        model.replayIntoRenderer()
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.apply(theme: colorScheme == .dark ? "dark" : "light")
        context.coordinator.apply(fontSize: fontSize)
        context.coordinator.apply(language: language)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let model: AppModel
        weak var web: WKWebView?

        private var ready = false
        private var pending: [(String, [Any])] = []
        private var theme = "light"
        private var fontSize: Double?

        init(model: AppModel) { self.model = model }

        func load() {
            guard let html = WebResources.viewerHTML else {
                assertionFailure("viewer.html 没打进 bundle")  // 不翻: developer-facing
                return
            }
            // read access to the directory, so KaTeX and markdown-it under vendor/ can load
            web?.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }

        /// Calls before the page is ready are queued and replayed in order, or the first page is lost.
        func call(_ fn: String, _ args: [Any]) {
            guard ready else { pending.append((fn, args)); return }
            let encoded = args.map(Self.jsLiteral).joined(separator: ", ")
            web?.evaluateJavaScript("window.Scivane.\(fn)(\(encoded));") { [weak self] value, _ in
                if fn == "find", let count = value as? Int { self?.model.searchHits = count }
            }
        }

        func apply(fontSize newSize: Double) {
            let size = min(22, max(14, newSize.isFinite ? newSize : 17))
            guard size != fontSize else { return }
            fontSize = size
            call("setFontSize", [size])
        }

        func apply(theme newTheme: String) {
            guard newTheme != theme else { return }
            theme = newTheme
            call("setTheme", [newTheme])
        }

        /// the page template starts in Chinese
        private var language: AppLanguage = .zh

        func apply(language newLanguage: AppLanguage) {
            guard newLanguage != language else { return }
            language = newLanguage
            call("setLanguage", [newLanguage.rawValue])
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            switch type {
            case "ready":
                ready = true
                // Configure the image origin before replaying any queued pages.
                call("setAssetBase", ["scivane-asset://local/"])
                call("setTheme", [theme])
                let queued = pending
                pending = []
                for (fn, args) in queued { call(fn, args) }
                call("scrollToPage", [model.currentPage])

            case "pageVisible":
                if let page = body["page"] as? Int { model.markdownDidScroll(to: page) }

            default:
                break
            }
        }

        /// Strings go through JSON serialisation, so backslashes and quotes pass safely.
        private static func jsLiteral(_ value: Any) -> String {
            switch value {
            case let s as String:
                let data = try? JSONSerialization.data(withJSONObject: [s], options: [])
                let wrapped = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
                return String(wrapped.dropFirst().dropLast())
            case let i as Int:    return String(i)
            case let d as Double: return String(d)
            case let b as Bool:   return b ? "true" : "false"
            default:              return "null"
            }
        }
    }
}
