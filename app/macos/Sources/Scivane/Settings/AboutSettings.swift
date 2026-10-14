import SwiftUI

/// Settings > About: what this is, which version, where it comes from.
struct AboutSettings: View {
  static let repository = URL(string: "https://github.com/akatsuky999/Scivane-macos")!

  var body: some View {
    VStack(spacing: 14) {
      Spacer(minLength: 40)
      ScivaneMark().frame(width: 30, height: 36).padding(18)
        .background(Palette.forest, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Palette.forest.opacity(0.32), radius: 14, y: 8)
        .accessibilityHidden(true)
      Text("Scivane").font(.custom("Baskerville", size: 34)).foregroundStyle(Palette.ink)
      Text(L("专门读论文的本地阅读代理", "A local reading agent for research papers"))
        .font(.system(size: 13)).foregroundStyle(Palette.inkSoft)

      HStack(spacing: 8) {
        SettingsTag(text: AppVersion.title, tint: Palette.inkSoft)
        if let built = AppVersion.built { SettingsTag(text: built, tint: Palette.inkFaint) }
      }
      .padding(.top, 4)
      .help(AppVersion.detail)
      .contextMenu {
        Button(L("拷贝版本信息", "Copy Version Details")) {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(AppVersion.detail, forType: .string)
        }
      }

      HStack(spacing: 10) {
        Button { NSWorkspace.shared.open(Self.repository) } label: {
          Label("GitHub", systemImage: "link")
        }
        .buttonStyle(SettingsButtonStyle())
        .help(Self.repository.absoluteString)
        Text("AGPL-3.0")
          .font(.system(size: 12)).foregroundStyle(Palette.inkSoft)
          .padding(.horizontal, 12).frame(height: 28)
          .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.rule, lineWidth: 1))
          .help(L("许可证", "License"))
      }
      .padding(.top, 10)
      Spacer(minLength: 40)
    }
    .frame(maxWidth: .infinity)
  }
}
