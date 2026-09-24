import SwiftUI

struct DocumentActions: View {
    @ObservedObject var model: AppModel
    @ObservedObject var job: DocumentJob
    var body: some View {
        if model.canBuildProject(job) {
            Button(L("构建项目", "Build Project")) { Task { await model.buildProject(from: job) } }
        }
        if job.canStartOCR { Button(L("开始 OCR", "Start OCR")) { model.startOCR(job) } }
        Button(L("阅读文档", "Read Document")) { model.select(job); model.mode = .read }
        Button(L("复制 Markdown", "Copy Markdown")) { model.copyMarkdown(job) }.disabled(!job.hasResult)
        Button(L("导出 Markdown…", "Export Markdown…")) { model.exportOne(job) }.disabled(!job.hasResult)
        if job.isMarkdown { Button(L("重新载入 Markdown", "Reload Markdown")) { model.reloadMarkdown(job) } }
        if !job.isMarkdown && job.hasResult && !job.status.isRunning { Button(L("重新 OCR", "Re-run OCR")) { model.retry(job) } }
        Divider()
        Button(L("在 Finder 中显示原文件", "Show Original in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }
        if case .failed = job.status { Button(L("重新识别", "Run OCR Again")) { model.retry(job) } }
        if case .cancelled = job.status { Button(L("重新识别", "Run OCR Again")) { model.retry(job) } }
        Divider()
        Button(L("从列表移除", "Remove from List")) { model.remove(job) }.disabled(job.status.isRunning)
    }
}

/// 字号。**两档分开**：正文是论文，对话是回答。
///
/// 两者的舒适字号本来就不同 —— 论文要长时间读、对话是一眼扫完再往下；
/// 而且正文那栏是衬线、对话那栏是无衬线，同一个数字在两边看起来也不一样大。
/// 共用一个滑块的结果必然是"调好了一边、另一边变难看"。
///
/// 范围都比先前宽（正文 14–22 → 13–28）：14 起跳对 4K 屏上的老花眼是不够的，
/// 而 22 封顶让"想只看一小段、把字调很大"这种读法根本做不到。
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

    /// 两条滑块共用一种排布：标题 + 当前值、大小两个 A、双击标题恢复默认。
    private func slider(
        title: String, value: Binding<Double>, range: ClosedRange<Double>,
        serif: Bool, reset: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title).font(.uiTitle)
                Spacer()
                // 半号也要显示得出来（对话默认就是 13.5），所以不取整
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
