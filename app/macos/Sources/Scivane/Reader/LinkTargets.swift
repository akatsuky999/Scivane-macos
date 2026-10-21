import PDFKit

/// What a link in the source points at, read from the PDF itself: a bibliography entry as its text, or
/// any other place (a figure, a table, an equation, a section) as a picture of that place.
enum LinkTarget: Equatable {
  case reference(String)
  /// a stretch of a page, in page space
  case region(page: Int, rect: CGRect)
}

/// Works out link targets on demand, one link at a time, and remembers them.
///
/// Nothing is indexed up front: a hover asks about one destination, which costs one look at the text
/// below it. LaTeX puts a citation's destination at the top of its entry, a little left of it, so the
/// entry is the lines from there until the next one starts: a line beginning with a label like "[41]",
/// a line back at the entry's left edge after the hanging indent, or a gap wider than the lines' own
/// spacing. A scanned page has no text layer and yields no reference.
@MainActor
final class LinkTargets {
  private weak var document: PDFDocument?
  private var texts: [Int: NSString] = [:]
  private var known: [Key: LinkTarget?] = [:]

  private struct Key: Hashable {
    let page: Int
    let x: CGFloat
    let y: CGFloat
  }

  /// longer than any real entry: something has gone wrong past this
  static let maxLines = 14
  static let maxCharacters = 900
  /// how far below its destination an entry is read
  static let reach: CGFloat = 260
  /// how far back to look for the References heading
  static let headingPages = 8

  func target(for destination: PDFDestination, in document: PDFDocument) -> LinkTarget? {
    if document !== self.document {
      self.document = document
      texts = [:]
      known = [:]
    }
    guard let page = destination.page else { return nil }
    let index = document.index(for: page)
    guard index != NSNotFound else { return nil }
    let key = Key(page: index, x: destination.point.x, y: destination.point.y)
    if let cached = known[key] { return cached }
    let found = resolve(page: page, index: index, point: Self.specified(destination.point, on: page))
    known[key] = found
    return found
  }

  // MARK: - Resolving

  private func resolve(page: PDFPage, index: Int, point: CGPoint) -> LinkTarget? {
    let rows = Self.rows(below: point, on: page)
    let place = { LinkTarget.region(page: index, rect: Self.region(below: point, on: page, caption: Self.isCaption(below: point, on: page))) }
    guard let first = firstRow(of: rows, at: point, on: page, index: index) else { return place() }
    if !Self.looksLikeHeading(first.text),
      Self.hasLabel(first.text) || referencesBefore(page: page, index: index, point: point),
      let entry = Self.entry(from: first, in: rows), Self.citesSomething(entry)
    {
      return .reference(entry)
    }
    return place()
  }

  /// A References heading before the destination in reading order: on one of the pages before, or on
  /// its page above it or in a column to its left.
  private func referencesBefore(page: PDFPage, index: Int, point: CGPoint) -> Bool {
    guard let document else { return false }
    for back in 0...Self.headingPages {
      let i = index - back
      guard i >= 0, let candidate = document.page(at: i), let text = text(of: candidate, index: i) else { break }
      var found = false
      text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) {
        line, range, _, stop in
        guard let line, Self.isReferencesHeading(line) else { return }
        let heading = candidate.characterBounds(at: range.location)
        if back > 0 || heading.minY >= point.y - 2 || heading.maxX < point.x - 10 {
          found = true
          stop.pointee = true
        }
      }
      if found { return true }
    }
    return false
  }

  // MARK: - The entry

  /// One printed line, or the part of it within one column: PDFKit hands a line over in pieces (a label
  /// and its text, a word set apart), which are put back together when they nearly touch.
  struct Row {
    var text: String
    var minX: CGFloat
    var maxX: CGFloat
    var minY: CGFloat
    var maxY: CGFloat
  }

  /// Pieces of one line closer than this are one row. A label sits about 5 pt from its text; the
  /// narrowest gutter between columns is about 18 pt.
  static let joinGap: CGFloat = 12

  static func rows(below point: CGPoint, on page: PDFPage) -> [Row] {
    let box = page.bounds(for: .cropBox)
    let left = max(box.minX, point.x - 0.5)
    let area = CGRect(x: left, y: point.y - reach, width: box.maxX - left, height: reach + 2)
      .intersection(box)
    guard !area.isNull, let selection = page.selection(for: area) else { return [] }
    var pieces: [Row] = []
    for line in selection.selectionsByLine() {
      // margin line numbers of a review copy are not text, and would bridge a gutter
      guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
        text.range(of: #"^[\d\s]+$"#, options: .regularExpression) == nil
      else { continue }
      let b = line.bounds(for: page)
      pieces.append(Row(text: text, minX: b.minX, maxX: b.maxX, minY: b.minY, maxY: b.maxY))
    }
    // top to bottom, then left to right, so the pieces of a line arrive together
    pieces.sort { abs($0.maxY - $1.maxY) > 1.5 ? $0.maxY > $1.maxY : $0.minX < $1.minX }
    var rows: [Row] = []
    for piece in pieces {
      if let i = rows.lastIndex(where: { abs($0.maxY - piece.maxY) <= 1.5 && piece.minX - $0.maxX < joinGap && piece.minX >= $0.minX }) {
        rows[i].text += " " + piece.text
        rows[i].maxX = max(rows[i].maxX, piece.maxX)
        rows[i].minY = min(rows[i].minY, piece.minY)
      } else {
        rows.append(piece)
      }
    }
    return rows
  }

  /// The topmost line that starts at or right of the destination and has its top at or below it. The
  /// destination of a float at the top of a page lands above the running head, which is skipped: the
  /// same words at the same height on a neighbouring page. So is the References heading, which the
  /// first entry's destination reaches up to, and a stray end of a line from the column to the left.
  private func firstRow(of rows: [Row], at point: CGPoint, on page: PDFPage, index: Int) -> Row? {
    // the end of a line in the column to the left can reach past the destination
    rows.filter { $0.maxY <= point.y + 1.5 && $0.minX >= point.x - 0.5 && $0.minX <= point.x + 45 }
      .sorted { $0.maxY > $1.maxY }
      .first { Self.opensText($0.text) && !Self.isReferencesHeading($0.text) && !isRunningHead($0, index: index) }
  }

  private func isRunningHead(_ row: Row, index: Int) -> Bool {
    guard let document else { return false }
    let band = CGRect(x: row.minX, y: row.minY, width: row.maxX - row.minX, height: row.maxY - row.minY)
      .insetBy(dx: -1, dy: -1)
    // two-sided layouts alternate their heads, so the pages two away count too
    for other in [index - 1, index + 1, index - 2, index + 2] where other >= 0 && other < document.pageCount {
      let text = document.page(at: other)?.selection(for: band)?.string?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if text == row.text { return true }
    }
    return false
  }

  static func entry(from first: Row, in rows: [Row]) -> String? {
    let left = first.minX
    // this column, below the first line: continuation lines are indented a little, the other column
    // starts far to the right
    // glyph boxes can be taller than the line spacing, so lines overlap a little
    let below = rows.filter { $0.maxY < first.maxY - 2 && $0.minX >= left - 2.5 && $0.minX <= left + 60 }
      .sorted { $0.maxY > $1.maxY }
    let pitch = Self.pitch(of: [first] + below.prefix(20))
    let gap = pitch.map { $0 * 1.35 } ?? (first.maxY - first.minY) * 1.6
    let numbered = hasLabel(first.text)
    var taken = [first]
    var hanging = false
    var ended = false
    for row in below {
      let previous = taken[taken.count - 1]
      let next = previous.maxY - row.maxY > gap || (numbered && hasLabel(row.text))
        || (hanging && row.minX < left + 1.5)
      if next {
        ended = true
        break
      }
      if row.minX > left + 2 { hanging = true }
      taken.append(row)
      if taken.count >= maxLines {
        ended = true
        break
      }
    }
    var entry = joined(taken.map(\.text))
    guard !entry.isEmpty else { return nil }
    if entry.count > maxCharacters {
      entry = String(entry.prefix(maxCharacters)) + "…"
    } else if !ended, let last = entry.last, !".)]".contains(last) {
      // the column ran out mid-entry: it goes on at the top of the next one
      entry += "…"
    }
    return entry
  }

  /// The spacing of lines within an entry: the smallest step down that occurs at least twice. The gaps
  /// between entries are wider.
  private static func pitch(of rows: [Row]) -> CGFloat? {
    let steps = zip(rows, rows.dropFirst()).map { $0.maxY - $1.maxY }.filter { $0 > 2 }.sorted()
    for (i, step) in steps.enumerated() where i + 1 < steps.count && steps[i + 1] - step < step * 0.08 {
      return step
    }
    return nil
  }

  /// Lines joined into one paragraph; a word broken with a hyphen at the end of a line is put back
  /// together.
  private static func joined(_ lines: [String]) -> String {
    var out = ""
    for line in lines {
      if out.hasSuffix("-"), let first = line.first, first.isLowercase {
        out.removeLast()
        out += line
      } else {
        out += out.isEmpty ? line : " " + line
      }
    }
    return out
  }

  // MARK: - Text

  private func text(of page: PDFPage, index: Int) -> NSString? {
    if let text = texts[index] { return text }
    guard let string = page.string, !string.isEmpty else { return nil }
    let text = string as NSString
    texts[index] = text
    return text
  }

  /// An entry starts with a word, a number or a label; a line starting with a comma or a dash is the
  /// end of a line in the neighbouring column.
  private static func opensText(_ line: String) -> Bool {
    line.range(of: #"^[\p{L}\p{N}\[(]"#, options: .regularExpression) != nil
  }

  /// A bibliography entry names a year, or has a label; a figure in an appendix after the references
  /// does neither.
  private static func citesSomething(_ entry: String) -> Bool {
    hasLabel(entry) || entry.range(of: #"\b(1[6-9]|20)\d\d[a-z]?\b"#, options: .regularExpression) != nil
  }

  private static func hasLabel(_ line: String) -> Bool {
    line.range(of: #"^\[\d{1,4}\]"#, options: .regularExpression) != nil
  }

  private static func isReferencesHeading(_ line: String) -> Bool {
    line.trimmingCharacters(in: .whitespaces)
      .range(of: #"^(\d+\.?\s*)?(references|bibliography|literature cited|works cited|参考文献)$"#,  // 不翻: a heading in the paper, not interface text
             options: [.regularExpression, .caseInsensitive]) != nil
  }

  /// A caption or a numbered heading: in an appendix after the references it is not an entry.
  private static func looksLikeHeading(_ line: String) -> Bool {
    line.range(of: #"^(Figure|Fig\.|Table|Algorithm|Appendix)\b|^[A-Z](\.\d+)+\s|^\d+(\.\d+)*\s+\p{Lu}"#,
               options: [.regularExpression, .caseInsensitive]) != nil
  }

  // MARK: - Regions

  /// A figure's destination is usually its caption, under the figure and its panels' labels, and
  /// often centred on the page: the caption is looked for across the whole width just below.
  private static func isCaption(below point: CGPoint, on page: PDFPage) -> Bool {
    let box = page.bounds(for: .cropBox)
    let band = CGRect(x: box.minX, y: point.y - 40, width: box.width, height: 42)
    guard let text = page.selection(for: band)?.string else { return false }
    return text.range(of: #"(^|\n)\s*(Figure|Fig\.)\s*\d"#, options: [.regularExpression, .caseInsensitive]) != nil
  }

  /// An unspecified coordinate (a destination that names only the page) as the page's top left.
  private static func specified(_ point: CGPoint, on page: PDFPage) -> CGPoint {
    let box = page.bounds(for: .cropBox)
    let unset = kPDFDestinationUnspecifiedValue
    return CGPoint(x: point.x >= unset ? box.minX : point.x, y: point.y >= unset ? box.maxY : point.y)
  }

  /// Width of the text, height of a preview card. A figure's caption sits under the figure, so a
  /// destination at a caption shows what is above it.
  static func region(below point: CGPoint, on page: PDFPage, caption: Bool) -> CGRect {
    let box = page.bounds(for: .cropBox)
    let margin = min(54, box.width * 0.08)
    let width = box.width - margin * 2
    let height = width * 0.5
    let top = caption ? point.y + height - 56 : point.y + 10
    let clamped = min(box.maxY, max(box.minY + height, top))
    return CGRect(x: box.minX + margin, y: clamped - height, width: width, height: height)
  }
}
