import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return L("跟随系统", "System")
        case .light: return L("浅色", "Light")
        case .dark: return L("深色", "Dark")
        }
    }
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    /// The app's appearance is NSApp.appearance alone; every window, sheet and popover follows it.
    /// SwiftUI's preferredColorScheme is deliberately not layered on top: given nil (System) it
    /// leaves SwiftUI's colorScheme stale while the windows have already switched, so a switch to or
    /// from System lagged and redrew in bursts.
    @MainActor func apply() {
        let target: NSAppearance.Name? = switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
        // every control showing the choice reacts to the same stored value: propagate it once
        guard NSApp.appearance?.name != target else { return }
        NSApp.appearance = target.flatMap { NSAppearance(named: $0) }
    }

    /// The stored choice, applied before the first window draws so it never flashes the system one.
    @MainActor static func applyStored(from defaults: UserDefaults = .standard) {
        (defaults.string(forKey: "appearance").flatMap(AppAppearance.init(rawValue:)) ?? .system).apply()
    }
}

/// Both entry points share one stored preference; the system appearance is never changed.
struct AppearanceControl: View {
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppAppearance.allCases) { option in
                Button { appearance = option } label: {
                    Image(systemName: option.symbol)
                        .font(.system(size: 11))
                        .frame(width: 28, height: 25)
                        .foregroundStyle(appearance == option ? Palette.inkSoft : Palette.inkSoft.opacity(0.55))
                        .background(appearance == option ? Palette.selectedRow : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help(option.label)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(appearance == option ? .isSelected : [])
            }
        }
        .onChange(of: appearance) { _, value in value.apply() }
    }
}
