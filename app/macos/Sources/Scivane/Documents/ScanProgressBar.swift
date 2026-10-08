import SwiftUI

/// Scan progress. Pages take 3-15 s each, so a bar alone isn't enough: page, elapsed time and
/// time left tell people whether to walk away.
struct ScanProgressBar: View {

    @ObservedObject var job: DocumentJob
    var onCancel: () -> Void
    var onRetry: (() -> Void)? = nil
    /// first run after an install loads the new engine for about a minute; say so
    var firstRun = false

    @State private var showFinished = true

    var body: some View {
        VStack(spacing: 0) {
            track
            if shouldShowStatusLine { statusLine }
            Hairline()
        }
        .animation(.smooth(duration: 0.3), value: job.status)
        .onChange(of: job.status) { _, new in
            guard case .finished = new else { return }
            // keep the finished state a few seconds so the time can be read
            showFinished = true
            Task {
                try? await Task.sleep(nanoseconds: 4_500_000_000)
                withAnimation(.smooth(duration: 0.5)) { showFinished = false }
            }
        }
    }

    // MARK: - Track

    @ViewBuilder
    private var track: some View {
        switch job.status {
        case .running(let done, _):
            if done == 0 {
                // no page back yet: an indeterminate shimmer rather than fake progress
                IndeterminateBar()
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Palette.ruleSoft)
                        Rectangle()
                            .fill(Palette.accent)
                            .frame(width: max(3, geo.size.width * job.progress))
                            .animation(.smooth(duration: 0.5), value: job.progress)
                    }
                }
                .frame(height: 2.5)
            }
        case .finished where showFinished:
            Rectangle().fill(Palette.accent.opacity(0.55)).frame(height: 2.5)
        default:
            EmptyView()
        }
    }

    // MARK: - Status line

    private var shouldShowStatusLine: Bool {
        switch job.status {
        case .ready, .imported: return false
        case .running:          return true
        case .failed, .queued, .cancelled: return true
        case .finished:         return showFinished
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 8) {
            switch job.status {
            case .running(let done, let total):
                // the page in progress, not pages done: a page takes over ten seconds
                Text(job.activePage == 0 ? (firstRun ? L("第一次加载新装的识别引擎，大约一分钟…", "Loading the newly installed engine for the first time — about a minute…") : L("正在分析版面…", "Analyzing the layout…")) : L("识别中", "Recognizing"))
                    .foregroundStyle(Palette.inkSoft)
                if job.activePage > 0 {
                    pill(L("第 \(job.activePage)/\(max(total, job.activePage)) 页", "Page \(job.activePage)/\(max(total, job.activePage))"))
                }
                if done > 0 {
                    Text(L("已完成 \(done)", "\(done) done"))
                        .foregroundStyle(Palette.inkFaint)
                }

                Spacer()

                if job.elapsed > 0 {
                    Text(L("已用 ", "Elapsed ") + Self.duration(job.elapsed))
                        .foregroundStyle(Palette.inkFaint)
                }
                if let eta = remaining {
                    Text("·").foregroundStyle(Palette.inkFaint)
                    Text(L("约剩 ", "About ") + Self.duration(eta) + L("", " left"))
                        .foregroundStyle(Palette.inkFaint)
                }
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.inkFaint)
                .help(L("停止识别", "Stop OCR"))

            case .finished(let seconds):
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.accent)
                Text(L("完成", "Done"))
                    .foregroundStyle(Palette.inkSoft)
                pill(L("\(job.pages.count) 页", plural(job.pages.count, "page", "pages")))
                Spacer()
                Text(Self.duration(seconds))
                    .foregroundStyle(Palette.inkFaint)
                if job.pages.count > 0 {
                    Text("·").foregroundStyle(Palette.inkFaint)
                    let perPage = String(format: "%.1f", seconds / Double(job.pages.count))
                    Text(L("\(perPage) 秒/页", "\(perPage)s/page"))
                        .foregroundStyle(Palette.inkFaint)
                }

            case .ready, .imported: EmptyView()
            case .queued:
                Text(L("等待识别", "Waiting for OCR")).foregroundStyle(Palette.inkSoft)
                Spacer()
                Text(firstRun ? L("正在启动新装的引擎，第一次要久一些", "Starting the newly installed engine; the first run takes longer") : L("引擎就绪后自动开始", "Starts once the engine is ready")).foregroundStyle(Palette.inkFaint)

            case .cancelled:
                Text(L("已停止识别", "OCR stopped")).foregroundStyle(Palette.inkSoft)
                Spacer()
                if let onRetry { Button(L("重新识别", "Run OCR Again"), action: onRetry).buttonStyle(.borderless) }

            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Palette.danger)
                Text(message.text)
                    .foregroundStyle(Palette.inkSoft)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(message.text)
                Spacer()
                if let onRetry { Button(L("重试", "Retry"), action: onRetry).buttonStyle(.borderless) }

            }
        }
        .font(.uiMeta)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(statusBackground)
        .transition(.opacity)
    }

    private var statusBackground: Color {
        if case .failed = job.status { return Palette.danger.opacity(0.07) }
        return Palette.sunk
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(Palette.inkSoft)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Palette.panel, in: Capsule())
    }

    /// Extrapolated from finished pages; nothing until the first one is back. A guessed ETA is worse
    /// than none.
    private var remaining: Double? {
        guard case .running(let done, let total) = job.status,
              done > 0, total > done, job.elapsed > 0 else { return nil }
        let perPage = job.elapsed / Double(done)
        return perPage * Double(total - done)
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return L("\(s) 秒", "\(s)s") }
        let m = s / 60, rest = s % 60
        return rest == 0 ? L("\(m) 分", "\(m) min") : L("\(m) 分 \(rest) 秒", "\(m) min \(rest)s")
    }
}

/// quieter than a spinner and takes no room
private struct IndeterminateBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shift: CGFloat = -0.35

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Palette.ruleSoft)
                LinearGradient(
                    colors: [.clear, Palette.accent.opacity(0.85), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: geo.size.width * 0.35)
                .offset(x: geo.size.width * shift)
            }
            .onAppear {
                if reduceMotion { shift = 0.3; return }
                withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: false)) {
                    shift = 1.0
                }
            }
        }
        .frame(height: 2.5)
        .clipped()
    }
}
