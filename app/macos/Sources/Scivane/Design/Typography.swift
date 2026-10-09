import CoreGraphics

/// How tightly text is set. Line spacing, the gaps between blocks and line length move together,
/// so one choice gives a compact page or an airy one. The text pane and the conversation each keep
/// their own.
enum ReadingDensity: String, CaseIterable, Identifiable {
  case compact, standard, relaxed

  var id: String { rawValue }

  /// Multiplies every gap between blocks. viewer.css uses the same three values (--space).
  var space: CGFloat {
    switch self {
    case .compact: return 0.72
    case .standard: return 1
    case .relaxed: return 1.24
    }
  }

  /// Extra space between lines in the conversation, as a fraction of the type size. Standard is
  /// what the conversation always used.
  var leading: CGFloat {
    switch self {
    case .compact: return 0.24
    case .standard: return 0.37
    case .relaxed: return 0.52
    }
  }

  /// Line length against standard: a compact page fits more on a line, an airy one less.
  var measure: CGFloat {
    switch self {
    case .compact: return 1.1
    case .standard: return 1
    case .relaxed: return 0.92
    }
  }
}

/// The type settings of one pane, and their single source: the options popover, the renderers and
/// the checks all read these, so a slider can't offer sizes the renderer quietly ignores.
struct TypeScale {
  let sizeKey: String
  let densityKey: String
  let sizes: ClosedRange<Double>
  let standardSize: Double

  /// Stored sizes may come from older, wider ranges.
  func clamp(_ size: Double) -> Double {
    guard size.isFinite else { return standardSize }
    return min(sizes.upperBound, max(sizes.lowerBound, size))
  }

  /// The paper and notes in the text pane, in px.
  static let paper = TypeScale(
    sizeKey: "readerFontSize", densityKey: "readerDensity", sizes: 12...24, standardSize: 15)
  /// The conversation, in pt. Headings, tables and code scale from it.
  static let chat = TypeScale(
    sizeKey: "agentFontSize", densityKey: "agentDensity", sizes: 11...20, standardSize: 13.5)
}
