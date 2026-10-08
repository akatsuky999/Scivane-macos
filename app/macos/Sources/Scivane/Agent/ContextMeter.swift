import SwiftUI

/// Window occupancy of one request (not the turn's total, which is cost and lives in UsageMeter).
/// With a known window: a small ring and a percentage, amber near the auto-compact point. Without
/// one: just "≈ N tokens". "≈" until calibrated by reported usage.
struct ContextMeter: View {
  let report: ContextReport?
  /// no manual compaction while busy: one writer per conversation
  var busy = false
  var onCompact: () -> Void = {}
  @State private var showing = false

  var body: some View {
    if let report {
      Button { showing.toggle() } label: {
        HStack(spacing: 4) {
          if let fraction = report.fraction {
            ContextRing(fraction: fraction, tint: Self.level(of: report).ring).frame(width: 11, height: 11)
            Text("\(report.measured ? "" : "≈")\(Int((fraction * 100).rounded()))%")
              .font(.system(size: 9.5, design: .monospaced)).monospacedDigit()
          } else {
            Image(systemName: "square.stack.3d.up").font(.system(size: 8.5))
            Text("≈" + UsageMeter.compact(report.used))
              .font(.system(size: 9.5, design: .monospaced)).monospacedDigit()
          }
        }
        .foregroundStyle(Self.level(of: report).text)
        .padding(.horizontal, 5).padding(.vertical, 2.5)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.ink.opacity(0.05)))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .fixedSize()
      .help(Self.summary(report))
      .accessibilityLabel(Self.summary(report))
      .popover(isPresented: $showing, arrowEdge: .top) {
        ContextBreakdown(report: report, busy: busy, onCompact: { showing = false; onCompact() })
      }
      .animation(.easeOut(duration: 0.25), value: report.used)
    }
  }

  /// Colour is the only alarm: normal, amber near the auto-compact point, red at 95% of the window
  /// (past auto-compaction).
  enum Level {
    case normal, near, full

    var ring: Color {
      switch self {
      case .normal: return Palette.accent
      case .near: return ActivityCard.amber
      case .full: return Palette.danger
      }
    }

    /// faint normally, ring colour when alarming
    var text: Color { self == .normal ? Palette.inkFaint : ring }
  }

  static func level(of report: ContextReport) -> Level {
    guard let window = report.window, window > 0 else { return .normal }
    if Double(report.used) >= Double(window) * 0.95 { return .full }
    if let threshold = report.threshold, Double(report.used) >= Double(threshold) * 0.9 { return .near }
    return .normal
  }

  /// tooltip and VoiceOver: numbers only
  static func summary(_ report: ContextReport) -> String {
    let approx = report.measured ? "" : "≈"
    let used = UsageMeter.compact(report.used)
    guard let window = report.window, let fraction = report.fraction else {
      return L("上下文 \(approx)\(used)", "Context \(approx)\(used)")
    }
    let percent = Int((fraction * 100).rounded())
    return L("上下文 \(approx)\(percent)% · \(used) / \(UsageMeter.compact(window))",
             "Context \(approx)\(percent)% · \(used) / \(UsageMeter.compact(window))")
  }
}

/// Static ring that eases only when the number changes; continuous animation belongs to Core
/// Animation (see AgentEffects).
private struct ContextRing: View {
  let fraction: Double
  let tint: Color

  var body: some View {
    ZStack {
      Circle().stroke(Palette.inkFaint.opacity(0.22), lineWidth: 2)
      Circle()
        .trim(from: 0, to: max(0.02, fraction))
        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
    .animation(.easeOut(duration: 0.25), value: fraction)
  }
}

/// Breakdown popover: total, a bar coloured by part, per-part numbers, Compact. Numbers only.
struct ContextBreakdown: View {
  let report: ContextReport
  var busy = false
  var onCompact: () -> Void = {}

  struct Row: Identifiable {
    let id: String
    let label: String
    let tokens: Int
    let color: Color
  }

  static let summaryTint = Color(
    light: Color(red: 0.36, green: 0.42, blue: 0.62), dark: Color(red: 0.62, green: 0.68, blue: 0.88))

  var rows: [Row] {
    var rows: [Row] = [
      Row(id: "system", label: L("系统提示词", "System prompt"),
          tokens: report.tokens(.system), color: Palette.ink.opacity(0.55)),
      Row(id: "tools", label: L("工具定义", "Tool definitions"),
          tokens: report.tokens(.tools), color: Palette.ink.opacity(0.32)),
      Row(id: "paper", label: L("论文正文", "Paper text"),
          tokens: report.tokens(.paper), color: Palette.accent),
    ]
    if report.tokens(.summary) > 0 {
      rows.append(Row(id: "summary", label: L("对话摘要", "Conversation summary"),
                      tokens: report.tokens(.summary), color: Self.summaryTint))
    }
    rows.append(Row(id: "history", label: L("之前的对话", "Earlier turns"),
                    tokens: report.tokens(.history), color: Palette.accent.opacity(0.5)))
    if report.live || report.tokens(.turn) > 0 {
      rows.append(Row(id: "turn", label: L("这一轮", "This turn"),
                      tokens: report.tokens(.turn), color: ActivityCard.amber.opacity(0.75)))
    }
    if report.window != nil {
      // the reserve is darker than truly free space: it looks empty but isn't usable
      rows.append(Row(id: "reserve", label: L("自动压缩预留", "Auto-compact buffer"),
                      tokens: report.reserve, color: Palette.inkFaint.opacity(0.5)))
      rows.append(Row(id: "free", label: L("剩余空间", "Free space"),
                      tokens: report.free, color: Palette.rule.opacity(0.55)))
    }
    return rows
  }

  /// the window if known, otherwise usage itself (proportions only)
  private var scale: Int { max(1, report.window ?? report.used) }

  private var headline: String {
    let approx = report.measured ? "" : "≈"
    guard let window = report.window, let fraction = report.fraction else {
      return "\(approx)\(UsageMeter.compact(report.used)) token"
    }
    return "\(approx)\(UsageMeter.compact(report.used)) / \(UsageMeter.compact(window)) (\(Int((fraction * 100).rounded()))%)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(alignment: .firstTextBaseline) {
        Text(L("上下文", "Context")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
        Spacer(minLength: 8)
        Text(headline)
          .font(.system(size: 11, design: .monospaced)).monospacedDigit()
          .foregroundStyle(ContextMeter.level(of: report) == .normal ? Palette.inkSoft : ContextMeter.level(of: report).ring)
      }

      bar

      VStack(alignment: .leading, spacing: 5) {
        ForEach(rows) { row in
          HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(row.color).frame(width: 8, height: 8)
            Text(row.label).font(.system(size: 11)).foregroundStyle(Palette.inkSoft)
            Spacer(minLength: 8)
            Text(UsageMeter.compact(row.tokens))
              .font(.system(size: 10.5, design: .monospaced)).monospacedDigit()
              .foregroundStyle(Palette.ink)
            if report.window != nil {
              Text(percent(row.tokens))
                .font(.system(size: 10, design: .monospaced)).monospacedDigit()
                .foregroundStyle(Palette.inkFaint)
                .frame(width: 38, alignment: .trailing)
            }
          }
        }
      }

      HStack {
        Spacer(minLength: 0)
        Button(L("压缩", "Compact"), action: onCompact)
          .controlSize(.small)
          .disabled(busy || report.turns == 0)
      }
    }
    .padding(14)
    .frame(width: 300)
  }

  /// parts get at least 1.5 pt so a tiny question still leaves a mark
  private var bar: some View {
    GeometryReader { geo in
      HStack(spacing: 1) {
        ForEach(rows) { row in
          if row.tokens > 0 {
            Rectangle().fill(row.color)
              .frame(width: max(1.5, geo.size.width * CGFloat(row.tokens) / CGFloat(scale)))
          }
        }
      }
      .frame(width: geo.size.width, alignment: .leading)
      .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
    .frame(height: 8)
    .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Palette.rule.opacity(0.5)))
  }

  private func percent(_ tokens: Int) -> String {
    guard let window = report.window, window > 0 else { return "" }
    let value = Double(tokens) / Double(window) * 100
    return value > 0 && value < 0.1 ? "<0.1%" : String(format: "%.1f%%", value)
  }
}
