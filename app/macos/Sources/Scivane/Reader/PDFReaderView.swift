import PDFKit
import SwiftUI

/// Source pane, on PDFKit.
struct PDFReaderView: NSViewRepresentable {

    @ObservedObject var model: AppModel
    let job: DocumentJob
    /// Hidden rather than removed while the other pane shows, so the page and zoom stay; a hidden
    /// view isn't drawn.
    var visible = true

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        let pdfView = AnnotatingPDFView()
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
        context.coordinator.marks.attach(pdfView, in: container)
        context.coordinator.zoom.attach(pdfView)

        model.pdfGoToPage = { [weak coordinator = context.coordinator] page in
            coordinator?.go(to: page)
        }
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        if view.isHidden == visible { view.isHidden = !visible }
        context.coordinator.show(job: job)
        context.coordinator.setThumbnails(visible: model.showThumbnails)
        context.coordinator.marks.update(store: model.annotations, projectID: model.annotatableProject(for: job))
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.marks.detach()
        coordinator.zoom.detach()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        let model: AppModel
        var pdfView: PDFView?
        var thumbWidth: NSLayoutConstraint?
        let marks = AnnotationController()
        let zoom = PDFZoom()

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
            marks.documentChanged()
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

/// Zoom from the keyboard and a mouse: ⌘ or ⌥ with the scroll wheel, around the pointer, and ⌘+ / ⌘− /
/// ⌘0 while the PDF has the focus. The trackpad pinch is PDFKit's own.
///
/// A local event monitor, because wheel events land on PDFKit's inner page view and its scroll view
/// consumes them: an override on the PDFView never sees one.
@MainActor
final class PDFZoom {
    private weak var view: PDFView?
    private var monitor: Any?

    func attach(_ view: PDFView) {
        self.view = view
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
            // local monitors run on the main thread
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    func detach() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let view, let window = view.window, view.document != nil else { return false }
        return event.type == .scrollWheel ? wheel(event, view, window) : key(event, view, window)
    }

    private func wheel(_ event: NSEvent, _ view: PDFView, _ window: NSWindow) -> Bool {
        let keys = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !keys.isDisjoint(with: [.command, .option]) else { return false }
        // an event without a window carries screen coordinates
        let inWindow: NSPoint
        if let source = event.window {
            guard source === window else { return false }
            inWindow = event.locationInWindow
        } else {
            inWindow = window.convertPoint(fromScreen: event.locationInWindow)
        }
        let point = view.convert(inWindow, from: nil)
        guard view.visibleRect.contains(point) else { return false }
        // trackpad momentum after the fingers lift would overshoot
        guard event.momentumPhase.isEmpty else { return true }
        // the wheel's physical direction: away from you zooms in, whatever natural scrolling says
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        // a wheel notch is about one line; a trackpad reports points
        let step = event.hasPreciseScrollingDeltas ? delta * 0.006 : delta * 0.1
        view.zoom(by: exp(max(-0.4, min(0.4, step))), around: point)
        return true
    }

    private func key(_ event: NSEvent, _ view: PDFView, _ window: NSWindow) -> Bool {
        let keys = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.shift, .numericPad, .function])
        guard keys == .command, event.window === window,
              let focus = window.firstResponder as? NSView, focus.isDescendant(of: view) else { return false }
        switch event.charactersIgnoringModifiers {
        case "=", "+": if view.canZoomIn { view.zoomIn(nil) }
        case "-": if view.canZoomOut { view.zoomOut(nil) }
        case "0": view.autoScales = true
        default: return false
        }
        return true
    }
}

extension PDFView {
    /// Scales by `factor` within PDFKit's limits and keeps the spot under `point` (view coordinates)
    /// where it is, as a pinch does.
    func zoom(by factor: CGFloat, around point: NSPoint) {
        let scale = min(maxScaleFactor, max(minScaleFactor, scaleFactor * factor))
        guard scale != scaleFactor else { return }
        let page = page(for: point, nearest: true)
        let spot = page.map { convert(point, to: $0) }
        autoScales = false
        scaleFactor = scale
        guard let page, let spot, let clip = documentView?.enclosingScrollView?.contentView else { return }
        layoutDocumentView()
        let now = clip.convert(convert(spot, from: page), from: self)
        let target = clip.convert(point, from: self)
        var bounds = clip.bounds
        bounds.origin.x += now.x - target.x
        bounds.origin.y += now.y - target.y
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
    }
}

/// Images get a separate zoomable viewer.
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
