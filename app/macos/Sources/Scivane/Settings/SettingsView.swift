import SwiftUI

/// The pages of Settings, in navigation order.
enum SettingsPage: String, CaseIterable, Identifiable {
  case general, models, engine, about

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: return L("通用", "General")
    case .models: return L("模型", "Models")
    case .engine: return L("本地引擎", "Local Engine")
    case .about: return L("关于", "About")
    }
  }

  var symbol: String {
    switch self {
    case .general: return "slider.horizontal.3"
    case .models: return "sparkles"
    case .engine: return "cpu"
    case .about: return "info.circle"
    }
  }
}

/// Settings: a glass navigation on the left, the same family as the main window's sidebar, and the
/// page on the right. Every page stays alive and only the visible one takes input, so a model card
/// half edited survives a look at another page.
struct SettingsView: View {
  @ObservedObject var backend: BackendManager
  @ObservedObject var model: AppModel
  /// normally General; offscreen checks open another page
  var initialPage: SettingsPage = .general
  /// for offscreen checks: the expanded card is the layout most likely to break
  var initialExpanded: String?
  @State private var chosen: SettingsPage?

  private var page: SettingsPage { chosen ?? initialPage }

  var body: some View {
    HStack(spacing: 0) {
      SettingsNavigation(selection: Binding(get: { page }, set: { chosen = $0 }), backend: backend)
        .frame(width: SettingsMetrics.navigation)
        .padding([.top, .bottom, .leading], SettingsMetrics.inset)
      GeometryReader { viewport in
        ZStack(alignment: .topLeading) {
          ForEach(SettingsPage.allCases) { item in
            let shown = item == page
            ScrollView {
              content(item)
                .frame(
                  maxWidth: .infinity,
                  minHeight: item == .about
                    ? max(0, viewport.size.height - SettingsMetrics.pageTop - 28) : nil,
                  alignment: .topLeading)
                .padding(.top, SettingsMetrics.pageTop)
                .padding(.leading, SettingsMetrics.pageLeading)
                .padding(.trailing, SettingsMetrics.pageTrailing)
                .padding(.bottom, 28)
            }
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            // hidden pages leave the key view loop too, or Tab would land in an invisible field
            .disabled(!shown)
            .accessibilityHidden(!shown)
          }
        }
      }
    }
    .frame(
      minWidth: SettingsMetrics.minimumWindow.width, idealWidth: SettingsMetrics.window.width,
      maxWidth: .infinity,
      minHeight: SettingsMetrics.minimumWindow.height, idealHeight: SettingsMetrics.window.height,
      maxHeight: .infinity)
    .background(Palette.paper.ignoresSafeArea())
    .ignoresSafeArea()
    .tint(Palette.accent)
  }

  @ViewBuilder
  private func content(_ item: SettingsPage) -> some View {
    switch item {
    case .general: GeneralSettings(model: model)
    case .models: ModelSettings(model: model, initialExpanded: initialExpanded)
    case .engine: EngineSettings(backend: backend, model: model, visible: page == .engine)
    case .about: AboutSettings()
    }
  }
}

/// The navigation island: the brand, the pages, and the service's state with the version.
private struct SettingsNavigation: View {
  @Binding var selection: SettingsPage
  @ObservedObject var backend: BackendManager
  @State private var hovered: SettingsPage?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Color.clear.frame(height: SettingsMetrics.navigationHeader)
        .background(SettingsWindowChrome())
        .accessibilityHidden(true)
      HStack(spacing: 10) {
        ScivaneMark().frame(width: 14, height: 17).frame(width: 30, height: 30)
          .background(Palette.forest, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
        VStack(alignment: .leading, spacing: 1) {
          Text("Scivane").font(.custom("Baskerville", size: 17)).foregroundStyle(Palette.ink)
          Text(L("设置", "Settings")).font(.system(size: 11)).foregroundStyle(Palette.inkFaint)
        }
      }
      .padding(.horizontal, 6).padding(.top, 12).padding(.bottom, 18)
      .accessibilityElement(children: .combine)

      VStack(spacing: 2) {
        ForEach(SettingsPage.allCases) { item in row(item) }
      }
      Spacer(minLength: 12)
      HStack(spacing: 8) {
        StatusDot(tone: backend.statusTone, halo: backend.state.isReady)
        Text(backend.statusTitle).font(.system(size: 11.5)).foregroundStyle(Palette.inkSoft)
          .lineLimit(1)
        Spacer(minLength: 4)
        Text(AppVersion.short ?? L("开发版", "Dev"))
          .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.inkFaint)
      }
      .padding(.horizontal, 10).frame(height: 34)
      .cardSurface(radius: 11)
      .help(backend.statusDetail + "\n" + AppVersion.detail)
    }
    .padding(.horizontal, 10).padding(.bottom, 10)
    .frame(maxHeight: .infinity, alignment: .top)
    .glassSurface(radius: 16)
    .accessibilityIdentifier("settings-navigation")
  }

  private func row(_ item: SettingsPage) -> some View {
    let selected = item == selection
    return Button { selection = item } label: {
      HStack(spacing: 10) {
        Image(systemName: item.symbol)
          .font(.system(size: 13, weight: selected ? .semibold : .regular))
          .foregroundStyle(selected ? Palette.accent : Palette.inkSoft)
          .frame(width: 18)
        Text(item.title)
          .font(.system(size: 13, weight: selected ? .semibold : .regular))
          .foregroundStyle(selected ? Palette.ink : Palette.inkSoft)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10).frame(height: 32)
      .background {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(selected ? Palette.thumb : (hovered == item ? Palette.ink.opacity(0.05) : .clear))
          .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 2, y: 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { inside in
      if inside { hovered = item } else if hovered == item { hovered = nil }
    }
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
