import SwiftUI

/// The settings window's layout, set in one place: the pages and the navigation are tuned together.
enum SettingsMetrics {
  static let window = CGSize(width: 760, height: 620)
  static let navigation: CGFloat = 196
  /// navigation island to the window edge
  static let inset: CGFloat = 8
  /// clears the transparent title bar
  static let pageTop: CGFloat = 36
  static let pageLeading: CGFloat = 30
  static let pageTrailing: CGFloat = 34
  static let row: CGFloat = 50
  /// label column of the model card editor
  static let label: CGFloat = 76
}

/// Page title, in the reading serif: settings belong to the same app as the paper.
struct SettingsTitle<Trailing: View>: View {
  let text: String
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(text)
        .font(.system(size: 26, weight: .semibold, design: .serif))
        .tracking(-0.2)
        .foregroundStyle(Palette.ink)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 12)
      trailing()
    }
  }
}

extension SettingsTitle where Trailing == EmptyView {
  init(_ text: String) { self.init(text: text, trailing: { EmptyView() }) }
}

/// One group: a small label, then its card.
struct SettingsSection<Content: View>: View {
  let title: String
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(title)
        .font(.system(size: 11, weight: .semibold)).tracking(0.5)
        .foregroundStyle(Palette.inkFaint)
        .padding(.leading, 2)
        .accessibilityAddTraits(.isHeader)
      content()
    }
  }
}

/// Rows on one card, a hairline between neighbours.
struct SettingsGroup<Content: View>: View {
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(spacing: 0) { content() }
      .frame(maxWidth: .infinity, alignment: .leading)
      .cardSurface()
  }
}

struct SettingsDivider: View {
  var body: some View {
    Rectangle().fill(Palette.ruleSoft).frame(height: 1).padding(.leading, 16)
  }
}

/// A row: the setting on the left (with an optional short state below it), its control on the right.
struct SettingsRow<Accessory: View>: View {
  let title: String
  var detail: String? = nil
  @ViewBuilder var accessory: () -> Accessory

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 13)).foregroundStyle(Palette.ink)
        if let detail, !detail.isEmpty {
          Text(detail).font(.system(size: 11)).foregroundStyle(Palette.inkFaint)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 12)
      accessory()
    }
    .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 8)
    .frame(minHeight: SettingsMetrics.row)
  }
}

/// Text fields drawn to match the cards: no bezel, a faint well, a light edge.
struct SettingsField: ViewModifier {
  var monospaced = false

  func body(content: Content) -> some View {
    content
      .textFieldStyle(.plain)
      .font(.system(size: 12, design: monospaced ? .monospaced : .default))
      .padding(.horizontal, 9).frame(height: 28)
      .background(Self.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.rule, lineWidth: 1))
  }

  static let well = Color(light: Color(red: 0.985, green: 0.985, blue: 0.975), dark: .black.opacity(0.22))
}

extension View {
  func settingsField(monospaced: Bool = false) -> some View { modifier(SettingsField(monospaced: monospaced)) }
}

/// Buttons of the settings pages. Secondary is a white chip, primary the accent; destructive is
/// plain text, so a red button never sits next to Save.
struct SettingsButtonStyle: ButtonStyle {
  enum Kind { case primary, secondary, destructive }
  var kind: Kind = .secondary
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    return configuration.label
      .font(.system(size: 12, weight: kind == .primary ? .semibold : .regular))
      .foregroundStyle(foreground)
      .padding(.horizontal, kind == .destructive ? 6 : 12).frame(height: 28)
      .background {
        switch kind {
        case .primary: shape.fill(Palette.accent)
        case .secondary: shape.fill(Palette.cardSolid).shadow(color: .black.opacity(0.04), radius: 0.5, y: 0.5)
        case .destructive: Color.clear
        }
      }
      .overlay { if kind == .secondary { shape.strokeBorder(Palette.rule, lineWidth: 1) } }
      .contentShape(shape)
      .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
  }

  private var foreground: Color {
    switch kind {
    case .primary: return Palette.paper
    case .secondary: return Palette.ink
    case .destructive: return Palette.danger
    }
  }
}

/// A small tag: modality, reasoning level, and other single words on a card.
struct SettingsTag: View {
  let text: String
  var tint: Color = Palette.inkSoft
  var emphasized = false

  var body: some View {
    Text(text)
      .font(.system(size: 10.5, weight: emphasized ? .semibold : .regular))
      .foregroundStyle(tint)
      .lineLimit(1)
      .padding(.horizontal, 7).frame(height: 20)
      .background(tint.opacity(emphasized ? 0.12 : 0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}
