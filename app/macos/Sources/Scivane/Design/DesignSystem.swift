import SwiftUI

enum Palette {
    static let accent = Color(light: Color(red: 0.16, green: 0.34, blue: 0.29), dark: Color(red: 0.60, green: 0.79, blue: 0.68))
    static let paper = Color(light: Color(red: 0.98, green: 0.975, blue: 0.96), dark: Color(red: 0.075, green: 0.095, blue: 0.09))
    static let sunk = Color(light: Color(red: 0.94, green: 0.94, blue: 0.91), dark: Color(red: 0.095, green: 0.12, blue: 0.11))
    static let ink = Color(light: Color(red: 0.13, green: 0.19, blue: 0.17), dark: Color(red: 0.91, green: 0.93, blue: 0.88))
    static let inkSoft = Color(light: Color(red: 0.36, green: 0.41, blue: 0.38), dark: Color(red: 0.66, green: 0.72, blue: 0.68))
    static let inkFaint = Color(light: Color(red: 0.46, green: 0.50, blue: 0.46), dark: Color(red: 0.54, green: 0.61, blue: 0.56))
    static let rule = Color(light: .black.opacity(0.12), dark: .white.opacity(0.14))
    static let ruleSoft = Color(light: .black.opacity(0.065), dark: .white.opacity(0.07))
    static let panel = Color(light: .white.opacity(0.72), dark: .white.opacity(0.045))
    static let danger = Color(light: Color(red: 0.67, green: 0.28, blue: 0.20), dark: Color(red: 0.94, green: 0.58, blue: 0.44))
    static let sidebar = Color(light: Color(red: 0.91, green: 0.935, blue: 0.905), dark: Color(red: 0.075, green: 0.12, blue: 0.10))
    static let selectedRow = Color(light: .white.opacity(0.75), dark: .white.opacity(0.085))
    // diff 的增删两色。**不复用 accent / danger**：那两个是「品牌」与「出错」，
    // 而一次删除既不是品牌也不是错误，借用会让用户以为改坏了什么。
    // 明度压在正文之下 —— 整块底色的饱和度一高，代码本身就读不成句了。
    static let added = Color(light: Color(red: 0.13, green: 0.47, blue: 0.27), dark: Color(red: 0.51, green: 0.82, blue: 0.60))
    static let removed = Color(light: Color(red: 0.63, green: 0.24, blue: 0.24), dark: Color(red: 0.91, green: 0.56, blue: 0.54))
    static let addedWash = Color(light: Color(red: 0.13, green: 0.47, blue: 0.27).opacity(0.10), dark: Color(red: 0.32, green: 0.72, blue: 0.45).opacity(0.14))
    static let removedWash = Color(light: Color(red: 0.63, green: 0.24, blue: 0.24).opacity(0.09), dark: Color(red: 0.86, green: 0.40, blue: 0.38).opacity(0.13))
    static let forest = Color(red: 0.075, green: 0.18, blue: 0.15)
    static let cream = Color(red: 0.94, green: 0.94, blue: 0.83)
}
extension Color {
    init(light: Color, dark: Color) {
        self = Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }
}
extension Font {
    static let uiTitle = Font.system(size: 13, weight: .semibold)
    static let uiBody = Font.system(size: 13)
    static let uiCaption = Font.system(size: 11)
    static let uiMeta = Font.system(size: 10.5, weight: .medium).monospacedDigit()
}
struct Hairline: View {
    var axis: Axis = .horizontal
    var body: some View {
        Rectangle().fill(Palette.ruleSoft)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
    }
}
/// 折页构成的 L，与桌面图标共享轮廓。
struct ScivaneMark: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let h = g.size.height
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: w * 0.20, y: h * 0.12))
                    p.addLine(to: CGPoint(x: w * 0.46, y: h * 0.04))
                    p.addLine(to: CGPoint(x: w * 0.46, y: h * 0.65))
                    p.addLine(to: CGPoint(x: w * 0.83, y: h * 0.54))
                    p.addLine(to: CGPoint(x: w * 0.83, y: h * 0.80))
                    p.addLine(to: CGPoint(x: w * 0.20, y: h * 0.98))
                    p.closeSubpath()
                }.fill(Palette.cream)
                Path { p in
                    p.move(to: CGPoint(x: w * 0.50, y: h * 0.16))
                    p.addLine(to: CGPoint(x: w * 0.72, y: h * 0.09))
                    p.addLine(to: CGPoint(x: w * 0.72, y: h * 0.51))
                    p.addLine(to: CGPoint(x: w * 0.50, y: h * 0.58))
                    p.closeSubpath()
                }.fill(Color(red: 0.56, green: 0.72, blue: 0.58))
            }
        }.accessibilityHidden(true)
    }
}
struct StudioButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(primary ? Palette.paper : Palette.ink)
            .background(primary ? Palette.accent : Palette.panel, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(primary ? .clear : Palette.ruleSoft))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}
struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(2).foregroundStyle(Palette.inkFaint)
    }
}

/// Stable hit targets and subtle hover feedback for the workspace toolbar.
struct ToolButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        ToolButtonBody(configuration: configuration, selected: selected)
    }
    private struct ToolButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label.font(.system(size: 12))
                .frame(minWidth: 28, minHeight: 28)
                .foregroundStyle(selected ? Palette.accent : Palette.inkSoft)
                .background(selected ? Palette.accent.opacity(0.10) : (hovering ? Palette.ruleSoft : .clear), in: RoundedRectangle(cornerRadius: 6))
                .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
                .onHover { hovering = $0 }
        }
    }
}

/// 侧栏里一行的按压反馈。
///
/// **hover 一层极淡的底，按下再深一点，没有边框也没有位移。**
/// 侧栏里所有行 ——
/// 主动作、次动作、列表项 —— 共用同一种反馈，谁也不比谁更"隆重"。
struct SidebarRowStyle: ButtonStyle {
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        RoundedRectangle(cornerRadius: SidebarMetrics.corner, style: .continuous)
          .fill(Palette.ink.opacity(configuration.isPressed ? 0.09 : (hovering ? 0.05 : 0))))
      .onHover { hovering = $0 }
  }
}
