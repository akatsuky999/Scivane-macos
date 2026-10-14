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

/// The sidebar's appearance switch. Every entry point (this, the rail's single button, the tiles in
/// Settings) writes one stored preference and applies it from its own onChange; the system appearance
/// is never changed.
struct AppearanceControl: View {
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    var body: some View {
        PillPicker(options: AppAppearance.allCases, selection: $appearance, height: 22, segmentWidth: 26,
                   name: \.label) { option, selected in
            Image(systemName: option.symbol)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Palette.ink : Palette.inkFaint)
        }
        .onChange(of: appearance) { _, value in value.apply() }
    }
}

/// The collapsed rail has room for one button: it shows the current choice and steps to the next.
struct AppearanceCycleButton: View {
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    var body: some View {
        Button {
            let all = AppAppearance.allCases
            appearance = all[(all.firstIndex(of: appearance)! + 1) % all.count]
        } label: {
            Image(systemName: appearance.symbol)
                .font(.system(size: 12))
                .foregroundStyle(Palette.inkSoft)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("外观：\(appearance.label)", "Appearance: \(appearance.label)"))
        .accessibilityLabel(L("外观", "Appearance"))
        .accessibilityValue(appearance.label)
        .onChange(of: appearance) { _, value in value.apply() }
    }
}
