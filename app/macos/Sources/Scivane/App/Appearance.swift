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
    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// 两处入口共享同一持久化偏好；不改变系统外观。
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
