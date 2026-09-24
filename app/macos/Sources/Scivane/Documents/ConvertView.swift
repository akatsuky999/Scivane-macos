import SwiftUI

// **入口已下架（2026-09-16）。** 这个视图现在没有任何调用方 —— 保留是因为
// 下架是产品决定而不是代码判决：真要把它放回去，只需要在 ContentView 里
// 接一个分支。**不要以为它是死代码顺手删掉**，也不要往它上面加新东西。
//

/// 转换模式：不打算读，只要 .md。一队文档串行跑完，一次导出。
struct ConvertView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("文档", "Documents")).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(L("\(model.finishedCount) / \(model.jobs.count) 已完成", "\(model.finishedCount) / \(model.jobs.count) done")).font(.uiMeta)
            }.foregroundStyle(Palette.inkFaint)
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 10)
            Hairline().padding(.horizontal, 20)
            ScrollView {

                LazyVStack(spacing: 0) {
                    ForEach(model.jobs) { job in
                        JobRow(model: model, job: job)
                        Hairline().padding(.leading, 46)

                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
            Hairline()
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                model.chooseAutoExportDirectory()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.autoExportDirectory == nil ? "folder.badge.questionmark" : "folder.fill")
                        .font(.system(size: 10.5))
                    Text(model.autoExportDirectory.map { L("自动导出 → ", "Auto export → ") + $0.lastPathComponent } ?? L("设置自动导出位置", "Set Auto-Export Folder"))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.borderless)
            .font(.uiCaption)
            .foregroundStyle(model.autoExportDirectory == nil ? Palette.inkFaint : Palette.inkSoft)
            .help(L("设定后，每份文档识别完会自动写入该文件夹", "Once set, each document is written here as soon as its OCR finishes"))

            if model.autoExportDirectory != nil {
                Button {
                    model.autoExportDirectory = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.inkFaint)
            }

            Spacer()

            if model.jobs.contains(where: \.canStartOCR) { Button(L("开始 OCR", "Start OCR")) { model.startAllOCR() }.buttonStyle(StudioButtonStyle(primary: true)) }
            if model.isBusy {
                Button(L("全部取消", "Cancel All")) { model.cancelAll() }
                    .buttonStyle(.borderless)
                    .font(.uiCaption)
                    .foregroundStyle(Palette.inkSoft)
            }

            if model.finishedCount > 0 {
                Button(L("清除已完成", "Clear Finished")) { model.clearFinished() }
                    .buttonStyle(.borderless)
                    .font(.uiCaption)
                    .foregroundStyle(Palette.inkSoft)
            }

            Button {
                model.exportAll()
            } label: {
                Text(L("导出全部（\(model.jobs.filter(\.hasResult).count)）", "Export All (\(model.jobs.filter(\.hasResult).count))"))
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(StudioButtonStyle(primary: true))
            .tint(Palette.accent)
            .disabled(!model.jobs.contains(where: \.hasResult))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.sunk)
    }
}

// MARK: - 队列行

private struct JobRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var job: DocumentJob
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: job.isPDF ? "doc.richtext" : "photo")
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(iconTint)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(job.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text(statusLabel)
                        .font(.uiMeta)
                        .foregroundStyle(statusTint)
                        .lineLimit(1)
                        .help(statusLabel)
                    if job.pageCount > 0 {
                        Text("·").foregroundStyle(Palette.inkFaint)
                        Text(L("\(job.pageCount) 页", plural(job.pageCount, "page", "pages")))
                            .font(.uiMeta)
                            .foregroundStyle(Palette.inkFaint)
                    }
                    if let eta = remaining {
                        Text("·").foregroundStyle(Palette.inkFaint)
                        Text(L("约剩 ", "About ") + ScanProgressBar.duration(eta) + L("", " left"))
                            .font(.uiMeta)
                            .foregroundStyle(Palette.inkFaint)
                    }
                    if let exported = job.exportedTo {
                        Text("·").foregroundStyle(Palette.inkFaint)
                        Text(L("已存到 ", "Saved to ") + exported.deletingLastPathComponent().lastPathComponent)
                            .font(.uiMeta)
                            .foregroundStyle(Palette.inkFaint)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            if job.status.isRunning {
                ProgressView(value: job.progress)
                    .progressViewStyle(.linear)
                    .tint(Palette.accent)
                    .frame(width: 78)
            }

            HStack(spacing: 2) {
                if case .failed = job.status {
                    iconButton("arrow.clockwise", help: L("重试", "Retry")) { model.retry(job) }
                }
                if job.hasResult {
                    iconButton("book", help: L("在阅读模式打开", "Open in Reading Mode")) {
                        model.select(job)
                        model.mode = .read
                    }
                    iconButton("square.and.arrow.down", help: L("导出这一份", "Export This One")) { model.exportOne(job) }
                }
                iconButton("xmark", help: job.status.isRunning ? L("识别中，请先停止识别", "OCR is running — stop it first") : L("移出队列", "Remove from Queue")) { model.remove(job) }
                    .disabled(job.status.isRunning)
            }
            .opacity(hovering ? 1 : 0.65)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 13)
        .background(hovering ? Palette.sunk : .clear)
        .contextMenu { DocumentActions(model: model, job: job) }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.14), value: hovering)
        .onTapGesture(count: 2) {
            guard job.hasResult else { return }
            model.select(job)
            model.mode = .read
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Palette.inkSoft)
        .help(help)
        .accessibilityLabel(help)
    }

    private var statusLabel: String {
        if case .failed(let message) = job.status { return L("识别失败 · ", "OCR failed · ") + message.text }
        return job.status.label
    }

    /// 按已完成页的平均耗时外推剩余时间

    private var remaining: Double? {
        guard case .running(let done, let total) = job.status,
              done > 0, total > done, job.elapsed > 0 else { return nil }
        return (job.elapsed / Double(done)) * Double(total - done)
    }

    private var iconTint: Color {
        switch job.status {
        case .finished: return Palette.accent
        case .failed:   return Palette.danger
        default:        return Palette.inkFaint
        }
    }

    private var statusTint: Color {
        switch job.status {
        case .failed:   return Palette.danger
        case .finished: return Palette.inkSoft
        default:        return Palette.inkFaint
        }
    }
}
