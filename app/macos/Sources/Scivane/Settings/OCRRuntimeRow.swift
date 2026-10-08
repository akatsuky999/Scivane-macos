import SwiftUI

/// Local OCR in Settings > Engine: which tier is in use, with install from here. Observes
/// OCRInstaller itself; progress uses the same card as the text pane.
struct OCRRuntimeRow: View {

    @ObservedObject var installer: OCRInstaller

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(L("本地 OCR", "Local OCR")) {
                HStack(spacing: 6) {
                    Text(summary)
                        .font(.uiCaption).foregroundStyle(Palette.inkSoft)
                        .lineLimit(1).truncationMode(.middle)
                        .help(installer.status?.root ?? "")
                    Spacer()
                    // not installed: install or migrate. On a legacy deployment this is the one-click migration
                    if let status = installer.status, !status.available || status.migratable,
                       status.overrideProblem == nil, case .idle = installer.phase {
                        Button(status.available ? L("迁成组件…", "Convert to Component…")
                               : (status.migratable ? L("迁移…", "Migrate…") : L("安装…", "Install…"))) {
                            installer.offer(status)
                        }
                    }
                }
            }
            OCRInstallCard(installer: installer, dismissible: false)
        }
        .task { await installer.refresh() }
    }

    private var summary: String {
        guard let status = installer.status else {
            return L("查询中…（本地服务没起来时查不到）", "Checking… (unavailable while the local service is down)")
        }
        guard status.available else {
            return status.migratable
                ? L("没装 · 这台机器上有旧部署可以迁过来", "Not installed · an old deployment on this Mac can be migrated")
                : L("没装（可选组件，约 2.2 GB）", "Not installed (optional, about 2.2 GB)")
        }
        switch status.tier {
        case "component": return L("已装", "Installed")
        case "legacy": return L("在用旧部署（只有这台机器有）", "Using the old deployment (only on this Mac)")
        case "override": return L("在用指定的位置", "Using the location you set")
        default: return L("已装", "Installed")
        }
    }
}
