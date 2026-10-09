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

/// Two separate sizes: the paper is read at length in a serif face, answers are scanned in a sans
/// one. A shared slider always leaves one side looking wrong.
struct ReadingOptions: View {
    @AppStorage("readerFontSize") private var readerSize = 17.0
    @AppStorage("agentFontSize") private var agentSize = 13.5

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            slider(title: L("正文字号", "Text Size"), value: $readerSize, range: 13...28,
                   serif: true, reset: 17)
            Hairline()
            slider(title: L("对话字号", "Chat Text Size"), value: $agentSize, range: 11...20,
                   serif: false, reset: 13.5)
        }.padding(18).frame(width: 248).tint(Palette.accent)
    }

    /// title and value, small and large A, double-click the title to reset
    private func slider(
        title: String, value: Binding<Double>, range: ClosedRange<Double>,
        serif: Bool, reset: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title).font(.uiTitle)
                Spacer()
                // not rounded: half sizes occur (the conversation default is 13.5)
                Text(value.wrappedValue == value.wrappedValue.rounded()
                     ? "\(Int(value.wrappedValue))" : String(format: "%.1f", value.wrappedValue))
                    .font(.uiMeta).foregroundStyle(Palette.inkFaint)
                Button {
                    value.wrappedValue = reset
                } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 9.5))
                }
                .buttonStyle(.plain).foregroundStyle(Palette.inkFaint)
                .help(L("恢复默认", "Reset to Default")).accessibilityLabel(L("\(title)恢复默认", "Reset \(title) to default"))
                .opacity(value.wrappedValue == reset ? 0.25 : 1)
                .disabled(value.wrappedValue == reset)
            }
            HStack(spacing: 12) {
                Text("A").font(.system(size: 11, design: serif ? .serif : .default))
                    .foregroundStyle(Palette.inkFaint)
                Slider(value: value, in: range, step: 0.5).accessibilityLabel(title)
                Text("A").font(.system(size: 20, design: serif ? .serif : .default))
                    .foregroundStyle(Palette.inkSoft)
            }
        }
    }
}
