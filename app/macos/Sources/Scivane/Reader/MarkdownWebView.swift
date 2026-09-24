import SwiftUI
import WebKit

/// 右栏：Markdown 渲染。
/// 用 WKWebView 而不是原生 Text —— PaddleOCR-VL 会吐 LaTeX 公式和 HTML 表格，
/// 这两样纯 SwiftUI 排不出来。
struct MarkdownWebView: NSViewRepresentable {

    @ObservedObject var model: AppModel
    /// 界面语言（空态那两句、每页的页码标签）。**由父视图显式传进来**：它一变，
    /// 这个值就不同，SwiftUI 一定会走一遍 `updateNSView` —— 不去赌 Observation
    /// 对 AppKit 视图的追踪。
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
        web.setValue(false, forKey: "drawsBackground")   // 让 body 背景透出来，避免白闪
        web.allowsMagnification = true
        web.allowsBackForwardNavigationGestures = false

        context.coordinator.web = web
        context.coordinator.load()

        // 把「调 JS」的能力交给 model，视图层不持有渲染逻辑
        model.renderBridge = { [weak coordinator = context.coordinator] fn, args in
            coordinator?.call(fn, args)
        }
        // WebView 建好之前到达的页要补回来
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
                assertionFailure("viewer.html 没打进 bundle")  // 不翻：开发者看的
                return
            }
            // 授予同目录读权限，vendor/ 下的 KaTeX 与 markdown-it 才加载得到
            web?.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }

        /// 页面还没 ready 的调用先攒着，ready 后按序补发 —— 否则首页结果会丢
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

        /// 页面模板本身是中文那一套，所以起点记成中文：中文界面一次都不用调。
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

        /// JS 字面量编码。字符串走 JSON 序列化，反斜杠和引号都能安全穿过。
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
