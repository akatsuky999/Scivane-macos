import PDFKit
import SwiftUI

/// 左栏：原文阅读。PDFKit 是 Apple 自家框架，预览.app 就用它 ——
/// 连续滚动、文字选择、缩略图、搜索这些都是白送的。
struct PDFReaderView: NSViewRepresentable {

    @ObservedObject var model: AppModel
    let job: DocumentJob

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = NSColor(Palette.sunk)
        pdfView.translatesAutoresizingMaskIntoConstraints = false

        let thumbs = PDFThumbnailView()
        thumbs.pdfView = pdfView
        thumbs.thumbnailSize = NSSize(width: 84, height: 108)
        thumbs.backgroundColor = NSColor(Palette.sunk)
        thumbs.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(thumbs)
        container.addSubview(pdfView)

        let thumbWidth = thumbs.widthAnchor.constraint(equalToConstant: 108)
        NSLayoutConstraint.activate([
            thumbs.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            thumbs.topAnchor.constraint(equalTo: container.topAnchor),
            thumbs.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            thumbWidth,
            pdfView.leadingAnchor.constraint(equalTo: thumbs.trailingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: container.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        context.coordinator.pdfView = pdfView
        context.coordinator.thumbWidth = thumbWidth
        context.coordinator.observe(pdfView)

        model.pdfGoToPage = { [weak coordinator = context.coordinator] page in
            coordinator?.go(to: page)
        }
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.show(job: job)
        context.coordinator.setThumbnails(visible: model.showThumbnails)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        let model: AppModel
        var pdfView: PDFView?
        var thumbWidth: NSLayoutConstraint?

        private var shownJobID: DocumentJob.ID?
        private var suppress = false

        init(model: AppModel) { self.model = model }

        func observe(_ pdfView: PDFView) {
            NotificationCenter.default.addObserver(
                self, selector: #selector(pageChanged),
                name: .PDFViewPageChanged, object: pdfView
            )
        }

        func show(job: DocumentJob) {
            guard shownJobID != job.id else { return }
            shownJobID = job.id
            suppress = true
            pdfView?.document = job.pdf
            go(to: model.currentPage)
        }

        func setThumbnails(visible: Bool) {
            guard let c = thumbWidth, c.constant != (visible ? 108 : 0) else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.allowsImplicitAnimation = true
                c.animator().constant = visible ? 108 : 0
            }
        }

        func go(to page: Int) {
            guard let pdfView, let doc = pdfView.document,
                  page >= 1, page <= doc.pageCount,
                  let target = doc.page(at: page - 1) else { return }
            suppress = true
            pdfView.go(to: target)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.suppress = false }
        }

        @objc private func pageChanged() {
            guard !suppress,
                  let pdfView, let doc = pdfView.document,
                  let current = pdfView.currentPage else { return }
            let index = doc.index(for: current) + 1
            Task { @MainActor in self.model.pdfDidScroll(to: index) }
        }
    }
}

/// 图片文档没有 PDF 那套，单独给一个可缩放的查看器。
struct ImageReaderView: View {
    let image: NSImage
    @State private var scale: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width * scale)
                    .padding(20)
            }
            .background(Palette.sunk)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 2) {
                Button { scale = max(0.4, scale - 0.2) } label: { Image(systemName: "minus") }
                Button { scale = 1 } label: { Text(L("适合", "Fit")).font(.uiCaption) }
                Button { scale = min(4, scale + 0.2) } label: { Image(systemName: "plus") }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.rule))
            .padding(14)
        }
    }
}
