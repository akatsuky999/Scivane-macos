import SwiftUI

struct DocumentActions: View {
    @ObservedObject var model: AppModel
    @ObservedObject var job: DocumentJob
    var body: some View {
        if model.canBuildProject(job) {
            Button(L("构建项目", "Build Project")) { Task { await model.buildProject(from: job) } }
        }
        // every engine choice goes through the chooser: local OCR may not be installed here
        if job.canStartOCR {
            Button(L("识别原稿…", "Recognize Original…")) { model.requestRecognition(job) }
        } else if !job.isMarkdown && !job.status.isRunning && job.status != .queued {
            Button(L("重新识别…", "Recognize Again…")) { model.requestRecognition(job) }
        }
        Button(L("阅读文档", "Read Document")) { model.select(job); model.mode = .read }
        Button(L("复制 Markdown", "Copy Markdown")) { model.copyMarkdown(job) }.disabled(!job.hasResult)
        Button(L("导出 Markdown…", "Export Markdown…")) { model.exportOne(job) }.disabled(!job.hasResult)
        if job.isMarkdown { Button(L("重新载入 Markdown", "Reload Markdown")) { model.reloadMarkdown(job) } }
        Divider()
        Button(L("在 Finder 中显示原文件", "Show Original in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }
        Divider()
        Button(L("从列表移除", "Remove from List")) { model.remove(job) }.disabled(job.status.isRunning)
    }
}

/// Type size and spacing, one section per pane: the paper is read at length in a serif face,
/// answers are scanned in a sans one, and a shared setting always leaves one side looking wrong.
struct ReadingOptions: View {
    @AppStorage(TypeScale.paper.sizeKey) private var paperSize = TypeScale.paper.standardSize
    @AppStorage(TypeScale.paper.densityKey) private var paperDensity = ReadingDensity.standard
    @AppStorage(TypeScale.chat.sizeKey) private var chatSize = TypeScale.chat.standardSize
    @AppStorage(TypeScale.chat.densityKey) private var chatDensity = ReadingDensity.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            section(title: L("正文", "Text"), scale: .paper, size: $paperSize,
                    density: $paperDensity, serif: true)
            Hairline()
            section(title: L("对话", "Chat"), scale: .chat, size: $chatSize,
                    density: $chatDensity, serif: false)
        }
        .padding(18).frame(width: 286).tint(Palette.accent)
        .accessibilityIdentifier("reading-options")
    }

    /// title, value and reset; small and large A around the slider; then the spacing
    private func section(
        title: String, scale: TypeScale, size: Binding<Double>, density: Binding<ReadingDensity>,
        serif: Bool
    ) -> some View {
        let isDefault = size.wrappedValue == scale.standardSize && density.wrappedValue == .standard
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(.uiTitle)
                Spacer()
                // not rounded: half sizes occur (the conversation default is 13.5)
                Text(Self.sizeLabel(scale.clamp(size.wrappedValue)))
                    .font(.uiMeta).foregroundStyle(Palette.inkFaint)
                Button {
                    size.wrappedValue = scale.standardSize
                    density.wrappedValue = .standard
                } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 9.5))
                }
                .buttonStyle(.plain).foregroundStyle(Palette.inkFaint)
                .help(L("恢复默认", "Reset to Default"))
                .accessibilityLabel(L("\(title)恢复默认", "Reset \(title) to default"))
                .opacity(isDefault ? 0.25 : 1)
                .disabled(isDefault)
            }
            HStack(spacing: 12) {
                Text("A").font(.system(size: 11, design: serif ? .serif : .default))
                    .foregroundStyle(Palette.inkFaint)
                // half points, rounded here rather than with `step`, which draws a tick per step
                Slider(
                    value: Binding(get: { scale.clamp(size.wrappedValue) },
                                   set: { size.wrappedValue = ($0 * 2).rounded() / 2 }),
                    in: scale.sizes
                ).accessibilityLabel(title)
                Text("A").font(.system(size: 20, design: serif ? .serif : .default))
                    .foregroundStyle(Palette.inkSoft)
            }
            SegmentedTabs(
                items: ReadingDensity.allCases.map { option in
                    SegmentedTabs.Item(id: option.rawValue, label: Self.label(option),
                                       symbol: Self.symbol(option))
                },
                selection: Binding(get: { density.wrappedValue.rawValue },
                                   set: { density.wrappedValue = ReadingDensity(rawValue: $0) ?? .standard })
            )
            .frame(maxWidth: .infinity)
            .accessibilityLabel(L("\(title)间距", "\(title) spacing"))
        }
    }

    static func sizeLabel(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    }

    static func label(_ density: ReadingDensity) -> String {
        switch density {
        case .compact: return L("紧凑", "Compact")
        case .standard: return L("适中", "Standard")
        case .relaxed: return L("宽松", "Relaxed")
        }
    }

    /// lines pressed together, evenly set, pulled apart
    static func symbol(_ density: ReadingDensity) -> String {
        switch density {
        case .compact: return "arrow.down.and.line.horizontal.and.arrow.up"
        case .standard: return "line.3.horizontal"
        case .relaxed: return "arrow.up.and.line.horizontal.and.arrow.down"
        }
    }
}
