import SwiftUI

struct SidebarDocument: View {
    @ObservedObject var model: AppModel
    @ObservedObject var job: DocumentJob
    @State private var hovering = false
    var body: some View {
        Button { model.select(job) } label: {
            // 与 ProjectRow 同一种行：单行、同高、极淡的选中层（尺寸见 SidebarMetrics）。
            // 状态只在**没跑完或出错**时写在右边 —— 完成是常态，不必每行重复。
            HStack(spacing: 9) {
                Image(systemName: job.isMarkdown ? "text.alignleft" : (job.isPDF ? "doc.text" : "photo"))
                    .font(.system(size: 12)).frame(width: 17).foregroundStyle(Palette.inkSoft)
                Text(job.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 6)
                if !job.status.isFinished {
                    Text(job.status.label).font(.system(size: 10)).foregroundStyle(Palette.inkFaint)
                }
                if case .failed = job.status {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 10))
                        .foregroundStyle(Palette.danger)
                }
            }.foregroundStyle(Palette.ink)
                .padding(.horizontal, SidebarMetrics.inset).frame(height: SidebarMetrics.treeRow)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: SidebarMetrics.corner, style: .continuous)
                        .fill(Palette.ink.opacity(model.selected?.id == job.id ? 0.06 : (hovering ? 0.035 : 0))))
        }.buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(job.url.lastPathComponent)
            .contextMenu { DocumentActions(model: model, job: job) }
            .accessibilityAddTraits(model.selected?.id == job.id ? .isSelected : [])
    }
}
