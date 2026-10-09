import AppKit
import PDFKit
import UniformTypeIdentifiers

/// A document to recognise, or already recognised.
@MainActor
final class DocumentJob: ObservableObject, Identifiable {

    enum Status: Equatable {
        case ready
        case imported
        case queued
        case running(done: Int, total: Int)
        case finished(seconds: Double)
        /// UIText: the reason stays on the document and must follow a language switch
        case failed(UIText)
        case cancelled

        var isRunning: Bool { if case .running = self { return true }; return false }
        var isFinished: Bool { if case .finished = self { return true }; return false }

        var label: String {
            switch self {
            case .ready: return L("待识别", "Ready for OCR")
            case .imported: return L("Markdown · 已载入", "Markdown · Loaded")
            case .queued:                     return L("排队中", "Queued")
            case .running(let d, let t):
                return t > 0 ? L("识别中 \(d)/\(t)", "Recognizing \(d)/\(t)") : L("识别中", "Recognizing")
            case .finished(let s):
                let seconds = String(format: "%.0f", s)
                return L("完成 · \(seconds) 秒", "Done · \(seconds)s")
            case .failed:                     return L("失败", "Failed")
            case .cancelled:                  return L("已取消", "Canceled")
            }
        }
    }

    let id = UUID()
    let url: URL

    @Published var status: Status = .ready
    @Published var pages: [Int: String] = [:]
    @Published var consolidated = ""
    @Published var plainText = ""
    @Published var exportedTo: URL?

    /// seconds reported by the server, for per-page averages and time left
    @Published var elapsed: Double = 0
    /// dense pages take over ten seconds; without this the UI looks frozen
    @Published var activePage: Int = 0
    /// what this run recognises with; a retry keeps it
    @Published var engine: RecognitionEngine = .local
    /// the card's model name while a cloud run is on, for the status line
    @Published var engineModel = ""
    /// cloud runs only: tokens so far, and pages that still failed after their retries
    @Published var usage: AgentUsage?
    @Published var failedPages: [Int] = []

    let pdf: PDFDocument?
    let image: NSImage?
    let pageCount: Int

    init(url: URL) {
        self.url = url
        if url.pathExtension.lowercased() == "pdf" {
            let doc = PDFDocument(url: url)
            self.pdf = doc
            self.image = nil
            self.pageCount = doc?.pageCount ?? 0
        } else {
            self.pdf = nil
            self.image = ["md", "markdown"].contains(url.pathExtension.lowercased()) ? nil : NSImage(contentsOf: url)
            self.pageCount = 1
        }
    }

    var isMarkdown: Bool { ["md", "markdown"].contains(url.pathExtension.lowercased()) }
    var canStartOCR: Bool { !isMarkdown && !hasResult && !status.isRunning && status != .queued }

    var title: String { url.deletingPathExtension().lastPathComponent }
    var isPDF: Bool { pdf != nil }

    var progress: Double {
        switch status {
        case .running(let done, let total): return total > 0 ? Double(done) / Double(total) : 0
        case .finished:                     return 1
        default:                            return 0
        }
    }

    /// the cross-page restructured text if available, else the pages joined, so export never waits
    var markdown: String {
        if !consolidated.isEmpty { return consolidated }
        return pages.keys.sorted().compactMap { pages[$0] }.joined(separator: "\n\n")
    }

    var hasResult: Bool { !pages.isEmpty }

    @discardableResult
    func write(to directory: URL, assetsRoot: URL? = nil) throws -> URL {
        let target = directory.appendingPathComponent(title + ".md")
        try MarkdownExporter.write(markdown, to: target, assetsRoot: assetsRoot, sourceDirectory: isMarkdown ? url.deletingLastPathComponent() : nil)
        exportedTo = target
        return target
    }

    static let supportedTypes: [UTType] = [UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText, .pdf, .png, .jpeg, .tiff, .bmp, .gif, .webP, .heic]
}
