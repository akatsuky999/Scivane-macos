import SwiftUI

/// 设置页「引擎」里的本地 OCR：在用哪一档；没装的话，从这里也能装。
///
/// 自己观察 `OCRInstaller`（从 AppModel 的属性里顺手取出来的对象
/// 不被观察），安装进度用正文栏顶上的同一张卡。
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
                    // 没装：装或迁。在用旧部署：这里是「一键迁移」入口 ——
                    // 迁成组件之后 App 就不再依赖旧部署
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
