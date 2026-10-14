import SwiftUI

/// The letters that stand for a paper on the rail. A paper's own short name when it has one
/// ("MedRel: …" → MR, "FLAME: …" → FL), otherwise the first letters of its first two words with
/// articles and prepositions skipped ("Invariant Representation Learning for …" → IR); a CJK title
/// gives its first character.
enum ProjectMark {
  static func initials(_ title: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.unicodeScalars.first else { return "·" }
    if isCJK(first) { return String(trimmed.prefix(1)) }

    // "MedRel: Relation-Centric …": the part before a short colon is the paper's own name
    var head = Substring(trimmed)
    if let colon = trimmed.firstIndex(where: { $0 == ":" || $0 == "：" }),
       trimmed.distance(from: trimmed.startIndex, to: colon) <= 24 {
      head = trimmed[..<colon]
    }
    let words = head.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    let significant = words.filter { !stopwords.contains($0.lowercased()) }
    let picked = significant.isEmpty ? words : significant
    guard let word = picked.first else { return String(trimmed.prefix(2)).uppercased() }

    if picked.count == 1 {
      // its own capitals when mixed case (TiWeaver → TW), else its first two letters (FLAME → FL)
      let capitals = word.filter(\.isUppercase)
      if capitals.count >= 2 && capitals.count < word.count { return String(capitals.prefix(2)) }
      return String(word.prefix(2)).uppercased()
    }
    return picked.prefix(2).map { String($0.prefix(1)).uppercased() }.joined()
  }

  private static let stopwords: Set<String> = [
    "a", "an", "the", "of", "for", "with", "via", "and", "or", "on", "in", "to", "from", "by", "as",
    "at", "is", "are", "towards", "toward", "into", "over", "under", "through", "without",
  ]

  private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7AF: return true
    default: return false
    }
  }
}

/// A page with its top right corner folded, the shape of the app's mark: how a paper looks on the
/// rail and in the library list.
struct PaperGlyph: View {
  let title: String
  var active = false
  var size = CGSize(width: 36, height: 44)

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: size.width * 0.2, style: .continuous)
    Text(ProjectMark.initials(title))
      .font(.system(size: size.width * 0.36, weight: .semibold, design: .serif))
      .tracking(0.3)
      .foregroundStyle(active ? Palette.accent : Palette.inkSoft)
      .frame(width: size.width, height: size.height)
      .background(active ? Palette.cardSolid : Palette.card, in: shape)
      .overlay(alignment: .topTrailing) {
        FoldedCorner()
          .fill(Palette.ink.opacity(active ? 0.10 : 0.07))
          .frame(width: size.width * 0.28, height: size.width * 0.28)
      }
      .clipShape(shape)
      .overlay(shape.strokeBorder(active ? Palette.accent : Palette.cardEdge, lineWidth: active ? 1.5 : 1))
      .shadow(color: .black.opacity(active ? 0.12 : 0), radius: 5, y: 2)
  }
}

/// The folded corner: a quarter that curls over at the top right.
private struct FoldedCorner: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.7, y: rect.minY))
    path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.7),
                      control: CGPoint(x: rect.maxX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}
