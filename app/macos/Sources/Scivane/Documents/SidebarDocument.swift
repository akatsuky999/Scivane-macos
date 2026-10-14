import SwiftUI

/// A document opened this session without a project, in the library's list. Status shows only while
/// it runs or after it failed.
struct SidebarDocument: View {
    @ObservedObject var model: AppModel
    @ObservedObject var job: DocumentJob
    @State private var hovering = false

    private var selected: Bool { model.selected?.id == job.id }

    var body: some View {
        Button { model.select(job) } label: {
            HStack(spacing: 8) {
                Image(systemName: job.isMarkdown ? "text.alignleft" : (job.isPDF ? "doc.text" : "photo"))
                    .font(.system(size: 11)).frame(width: 14)
                    .foregroundStyle(selected ? Palette.accent : Palette.inkFaint)
                Text(job.title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Palette.accent : Palette.ink.opacity(0.88))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if !job.status.isFinished {
                    Text(job.status.label).font(.system(size: 10)).foregroundStyle(Palette.inkFaint)
                }
                if case .failed = job.status {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 10))
                        .foregroundStyle(Palette.danger)
                }
            }
            .padding(.horizontal, 8).frame(height: SidebarMetrics.row)
            .background(
                RoundedRectangle(cornerRadius: SidebarMetrics.corner, style: .continuous)
                    .fill(selected ? Palette.accent.opacity(0.12) : Palette.ink.opacity(hovering ? 0.045 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(job.url.lastPathComponent)
        .contextMenu { DocumentActions(model: model, job: job) }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
