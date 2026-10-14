import SwiftUI

/// Local OCR in Settings > Local Engine: whether it's installed and which tier is in use, with install
/// from here. Observes OCRInstaller itself; progress uses the same card as the text pane.
struct OCRRuntimeRow: View {

    @ObservedObject var installer: OCRInstaller
    /// asked for when the page is shown, not whenever Settings opens
    var visible = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 14)).foregroundStyle(Palette.inkSoft)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("本地 OCR", "Local OCR")).font(.system(size: 13)).foregroundStyle(Palette.ink)
                    if let location {
                        Text(location)
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.inkFaint)
                            .lineLimit(1).truncationMode(.middle)
                            .help(installer.status?.root ?? "")
                    }
                }
                Spacer(minLength: 12)
                state
            }
            .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 8)
            .frame(minHeight: SettingsMetrics.row)
            OCRInstallCard(installer: installer, dismissible: false)
                .padding(.horizontal, 10)
        }
        .task(id: visible) {
            if visible { await installer.refresh() }
        }
    }

    /// Installed: a tag. Not installed, or on the old deployment: the action that fixes it.
    @ViewBuilder
    private var state: some View {
        if let status = installer.status {
            if status.available && !status.migratable {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                    Text(tier(status.tier ?? ""))
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ok)
                .padding(.horizontal, 8).frame(height: 22)
                .background(Palette.ok.opacity(0.11), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                HStack(spacing: 8) {
                    if !status.available {
                        Text(status.migratable ? L("可迁移", "Can migrate") : L("未安装 · 约 2.2 GB", "Not installed · about 2.2 GB"))
                            .font(.system(size: 11)).foregroundStyle(Palette.inkFaint)
                    }
                    if status.overrideProblem == nil, case .idle = installer.phase {
                        Button(status.available ? L("迁成组件…", "Convert to Component…")
                               : (status.migratable ? L("迁移…", "Migrate…") : L("安装…", "Install…"))) {
                            installer.offer(status)
                        }
                        .buttonStyle(SettingsButtonStyle())
                    }
                }
            }
        } else {
            Text(L("查询中…", "Checking…")).font(.system(size: 11)).foregroundStyle(Palette.inkFaint)
                .help(L("本地服务没起来时查不到", "Unavailable while the local service is down"))
        }
    }

    /// where it is, home as ~; nothing before the status is known or when not installed
    private var location: String? {
        guard let status = installer.status, status.available, let root = status.root, !root.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return root.hasPrefix(home) ? "~" + root.dropFirst(home.count) : root
    }

    private func tier(_ tier: String) -> String {
        switch tier {
        case "legacy": return L("旧部署", "Old deployment")
        case "override": return L("指定位置", "Custom location")
        default: return L("已安装", "Installed")
        }
    }
}
