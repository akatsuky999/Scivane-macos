import SwiftUI

/// Markdown in the conversation, as native views. Not the reader's WKWebView: one per message is
/// heavy and replays on every rebuild. Blocks are handled here, inline formatting by
/// AttributedString, and formulas are typeset by KaTeX into vector images (MathRenderer).
enum MarkdownBlock: Identifiable, Equatable {
  case heading(level: Int, text: String)
  case paragraph(String)
  /// unordered, ordered and task items can be nested and mixed
  case list([MarkdownListItem])
  case quote([String])
  case code(language: String, body: String)
  case table(header: [String], alignments: [MarkdownColumnAlignment], rows: [[String]])
  /// `$$...$$`, `\[...\]`, or a standalone environment such as `\begin{equation}`.
  /// `open`: the closing delimiter hasn't streamed in yet.
  case math(latex: String, open: Bool)
  case rule

  /// Must be a pure function of the content: a random id made ForEach rebuild the block on every
  /// diff. Content-based so streaming only changes the last block; duplicates are disambiguated by
  /// index in MarkdownText.
  var id: String {
    switch self {
    case .heading(let level, let text): return "h\(level):\(text)"
    case .paragraph(let text): return "p:\(text)"
    case .list(let items):
      return "l:" + items.map { "\($0.depth)\($0.marker):\($0.text)" }.joined(separator: "|")
    case .quote(let lines): return "q:\(lines.joined(separator: "|"))"
    case .code(let language, let body): return "c:\(language):\(body)"
    case .table(let header, _, let rows):
      return "t:\(header.joined(separator: "|")):\(rows.count)"
    case .math(let latex, let open): return "m\(open ? "~" : ""):\(latex)"
    case .rule: return "hr"
    }
  }
}

struct MarkdownListItem: Equatable {
  enum Marker: Equatable {
    case bullet
    /// numbered as CommonMark does, counting up from the first item: models often write `1.` for
    /// every item
    case number(Int)
    case task(done: Bool)
  }

  /// 0 is the outermost level
  var depth: Int
  var marker: Marker
  var text: String
}

enum MarkdownColumnAlignment: Equatable {
  case leading, center, trailing
}

/// A linear scan rather than recursive descent: model output nests shallowly, and rerunning on every
/// streamed chunk stays cheap.
enum MarkdownParser {

  /// The whole transcript is rebuilt on every chunk, so without a cache every finished answer would
  /// be re-split each time. Finished text never changes, which makes the text a good key. Only the
  /// most recent 32 are kept.
  private static var cache: [String: [MarkdownBlock]] = [:]
  private static var recent: [String] = []
  private static let cacheLimit = 32

  /// - Parameter cache: false for the streaming message. It has a new text, and so a new key,
  ///   every frame, which would keep flushing the finished answers out of the cache.
  static func blocks(_ text: String, cache useCache: Bool = true) -> [MarkdownBlock] {
    if let hit = cache[text] { return hit }
    let parsed = parse(text)
    guard useCache else { return parsed }
    cache[text] = parsed
    recent.append(text)
    if recent.count > cacheLimit {
      let evicted = recent.removeFirst()
      cache.removeValue(forKey: evicted)
    }
    return parsed
  }

  /// Environments treated as display math when standalone; MathTeX.display replaces the ones KaTeX
  /// lacks.
  private static let mathEnvironments: Set<String> = [
    "equation", "equation*", "align", "align*", "gather", "gather*", "multline", "multline*",
    "flalign", "flalign*", "alignat", "alignat*", "eqnarray", "eqnarray*",
  ]

  private static func parse(_ text: String) -> [MarkdownBlock] {
    let lines = text.components(separatedBy: "\n")
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []
    var quote: [String] = []
    var table: [String] = []
    var list = ListBuilder()

    func flushParagraph() {
      let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !joined.isEmpty { blocks.append(.paragraph(joined)) }
      paragraph.removeAll()
    }
    func flushQuote() {
      if !quote.isEmpty { blocks.append(.quote(quote)); quote.removeAll() }
    }
    func flushList() {
      if let items = list.finish() { blocks.append(.list(items)) }
    }
    func flushTable() {
      guard !table.isEmpty else { return }
      blocks.append(tableBlock(table))
      table.removeAll()
    }
    func flushAll() { flushParagraph(); flushQuote(); flushList(); flushTable() }

    var index = 0
    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      index += 1

      // Up to the closing fence, or the end of input (the last block is often still open while
      // streaming). Indented code inside list items counts too, minus that indent.
      if let fence = fence(trimmed) {
        flushAll()
        let indent = line.prefix { $0 == " " }.count
        let language = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
          .split(separator: " ").first.map(String.init) ?? ""
        var body: [String] = []
        while index < lines.count {
          let next = lines[index]
          index += 1
          let cut = next.trimmingCharacters(in: .whitespaces)
          if cut.hasPrefix(fence), cut.allSatisfy({ $0 == fence.first }) { break }
          body.append(String(next.dropFirst(min(indent, next.prefix { $0 == " " }.count))))
        }
        blocks.append(.code(language: language, body: body.joined(separator: "\n")))
        continue
      }

      // `$$` may share a line with the formula or stand alone; multi-line ones run to the closing
      // delimiter. An unclosed one is still emitted (marked open), or a streaming formula would vanish
      // and then pop in when closed.
      if let opener = displayOpener(trimmed) {
        flushAll()
        var collected: [String] = []
        var closed = false
        var rest = String(trimmed.dropFirst(opener.skip))
        while true {
          if let range = rest.range(of: opener.closer) {
            let head = opener.keepsDelimiters
              ? String(rest[..<range.upperBound]) : String(rest[..<range.lowerBound])
            collected.append(head)
            closed = true
            break
          }
          collected.append(rest)
          guard index < lines.count else { break }
          rest = lines[index]
          index += 1
        }
        let latex = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !latex.isEmpty { blocks.append(.math(latex: latex, open: !closed)) }
        continue
      }

      // a table: consecutive lines starting with |
      if trimmed.hasPrefix("|"), trimmed.count > 1 {
        flushParagraph(); flushQuote(); flushList()
        table.append(trimmed)
        continue
      } else if !table.isEmpty {
        flushTable()
      }

      if trimmed.isEmpty {
        flushParagraph(); flushQuote()
        // loose lists put blank lines between items; keep the list open if the next line still belongs
        // to it
        if list.isOpen, let next = lines[index...].first(where: {
          !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }), listItem(next) != nil || list.continues(next) {
          continue
        }
        flushList()
        continue
      }

      if isRule(trimmed) {
        flushAll(); blocks.append(.rule); continue
      }

      if let heading = heading(trimmed) {
        flushAll()
        blocks.append(.heading(level: heading.level, text: heading.text))
        continue
      }

      if trimmed.hasPrefix(">") {
        flushParagraph(); flushList()
        var body = trimmed.dropFirst()
        if body.first == " " { body = body.dropFirst() }
        quote.append(String(body))
        continue
      }

      if let item = listItem(line) {
        flushParagraph(); flushQuote()
        list.add(indent: item.indent, marker: item.marker, text: item.text)
        continue
      }

      // Continuation lines are indented under the item. Lazy continuation (an unindented line right
      // after the item) is not supported: models mean a new paragraph there, and CommonMark would tuck
      // the summary under the last bullet.
      if list.isOpen, list.continues(line) {
        list.extend(with: trimmed)
        continue
      }

      // a plain paragraph ends any list or quote
      flushQuote(); flushList()
      paragraph.append(line)
    }
    flushAll()
    return blocks
  }

  // MARK: - Lists

  /// Levels come from a stack of indents, not two spaces per level: models indent by two, three or
  /// four, and a fixed width would skip levels.
  private struct ListBuilder {
    private var items: [MarkdownListItem] = []
    /// indent of each level's first item
    private var indents: [Int] = []
    /// last number per level; reset by an unordered item
    private var counters: [Int?] = []

    var isOpen: Bool { !items.isEmpty }

    mutating func add(indent: Int, marker: MarkdownListItem.Marker, text: String) {
      while indents.count > 1, let last = indents.last, indent < last { indents.removeLast() }
      if let last = indents.last {
        if indent >= last + 2 { indents.append(indent) }
      } else {
        indents.append(indent)
      }
      let depth = indents.count - 1
      counters = Array(counters.prefix(depth + 1))
      while counters.count <= depth { counters.append(nil) }

      var resolved = marker
      if case .number(let written) = marker {
        let number = counters[depth].map { $0 + 1 } ?? written
        counters[depth] = number
        resolved = .number(number)
      } else {
        counters[depth] = nil
      }
      items.append(MarkdownListItem(depth: depth, marker: resolved, text: text))
    }

    /// indented inside the list: a continuation of the previous item, not a new paragraph
    func continues(_ line: String) -> Bool {
      guard let base = indents.first else { return false }
      return MarkdownParser.indentation(line) > base
    }

    mutating func extend(with text: String) {
      guard !items.isEmpty else { return }
      items[items.count - 1].text += "\n" + text
    }

    mutating func finish() -> [MarkdownListItem]? {
      defer { self = ListBuilder() }
      return items.isEmpty ? nil : items
    }
  }

  /// indent, marker and text; nil if not a list item
  private static func listItem(
    _ line: String
  ) -> (indent: Int, marker: MarkdownListItem.Marker, text: String)? {
    let indent = indentation(line)
    let rest = line.drop { $0 == " " || $0 == "\t" }
    if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
      let text = rest.dropFirst(2)
      for (box, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where text.hasPrefix(box) {
        return (indent, .task(done: done), String(text.dropFirst(box.count)))
      }
      return (indent, .bullet, String(text))
    }
    let digits = rest.prefix { $0.isNumber }
    guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
    let after = rest.dropFirst(digits.count)
    guard let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " else {
      return nil
    }
    return (indent, .number(number), String(after.dropFirst(2)))
  }

  /// tabs count as four
  fileprivate static func indentation(_ line: String) -> Int {
    var width = 0
    for character in line {
      if character == " " { width += 1 } else if character == "\t" { width += 4 } else { break }
    }
    return width
  }

  // MARK: - Other blocks

  /// three or more backticks or tildes
  private static func fence(_ trimmed: String) -> String? {
    for mark in ["`", "~"] {
      let run = trimmed.prefix { String($0) == mark }
      if run.count >= 3 { return String(run) }
    }
    return nil
  }

  private struct DisplayOpener {
    var skip: Int
    var closer: String
    /// `\begin{...}`: the delimiters are part of the formula and go to KaTeX
    var keepsDelimiters: Bool
  }

  private static func displayOpener(_ trimmed: String) -> DisplayOpener? {
    if trimmed.hasPrefix("$$") { return DisplayOpener(skip: 2, closer: "$$", keepsDelimiters: false) }
    if trimmed.hasPrefix("\\[") { return DisplayOpener(skip: 2, closer: "\\]", keepsDelimiters: false) }
    if trimmed.hasPrefix("\\begin{"), let close = trimmed.firstIndex(of: "}") {
      let name = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 7)..<close])
      if mathEnvironments.contains(name) {
        return DisplayOpener(skip: 0, closer: "\\end{\(name)}", keepsDelimiters: true)
      }
    }
    return nil
  }

  /// three or more of the same `-` `*` `_`, spaces allowed
  private static func isRule(_ trimmed: String) -> Bool {
    let marks = trimmed.filter { $0 != " " }
    guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
    return marks.allSatisfy { $0 == first }
  }

  private static func heading(_ trimmed: String) -> (level: Int, text: String)? {
    let level = trimmed.prefix { $0 == "#" }.count
    guard (1...6).contains(level), trimmed.dropFirst(level).first == " " else { return nil }
    var text = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
    // a closing `##` (ATX) isn't part of the heading
    if let close = text.range(of: #"\s+#+$"#, options: .regularExpression) {
      text.removeSubrange(close)
    }
    return (level, text)
  }

  // MARK: - Tables

  private static func tableBlock(_ rows: [String]) -> MarkdownBlock {
    let parsed = rows.map(cells)
    var alignments: [MarkdownColumnAlignment] = []
    var body = Array(parsed.dropFirst())
    if parsed.count > 1, let marks = separator(parsed[1]) {
      alignments = marks
      body = Array(parsed.dropFirst(2))
    }
    return .table(header: parsed.first ?? [], alignments: alignments, rows: body)
  }

  /// Pipes inside inline code or math don't split cells: `$\|x\|$` and `` `a|b` `` are one cell.
  private static func cells(_ line: String) -> [String] {
    var cells: [String] = []
    var current = ""
    var inCode = false
    var inMath = false
    let characters = Array(line)
    var index = characters.first == "|" ? 1 : 0
    while index < characters.count {
      let character = characters[index]
      if character == "\\", index + 1 < characters.count {
        current.append(character)
        current.append(characters[index + 1])
        index += 2
        continue
      }
      if character == "`" { inCode.toggle() }
      if character == "$", !inCode { inMath.toggle() }
      if character == "|", !inCode, !inMath {
        cells.append(current)
        current = ""
      } else {
        current.append(character)
      }
      index += 1
    }
    if !current.trimmingCharacters(in: .whitespaces).isEmpty { cells.append(current) }
    // models often break lines in cells with <br>
    return cells.map {
      $0.trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
    }
  }

  /// The `|:---|:---:|---:|` row; returns each column's alignment.
  private static func separator(_ row: [String]) -> [MarkdownColumnAlignment]? {
    guard !row.isEmpty else { return nil }
    var out: [MarkdownColumnAlignment] = []
    for cell in row {
      let mark = cell.filter { $0 != " " }
      guard !mark.isEmpty, mark.allSatisfy({ ":-=".contains($0) }), mark.contains("-") || mark.contains("=") else {
        return nil
      }
      switch (mark.hasPrefix(":"), mark.hasSuffix(":")) {
      case (true, true): out.append(.center)
      case (false, true): out.append(.trailing)
      default: out.append(.leading)
      }
    }
    return out
  }
}

extension MarkdownParser {
  /// Every formula to typeset in this text, for checks and prefetching.
  static func formulas(in text: String) -> [MathRenderer.Key] {
    func inline(_ text: String) -> [MathRenderer.Key] { MathTeX.keys(MathTeX.spans(text)) }
    return blocks(text).flatMap { block -> [MathRenderer.Key] in
      switch block {
      case .heading(_, let text), .paragraph(let text): return inline(text)
      case .list(let items): return items.flatMap { inline($0.text) }
      case .quote(let lines): return inline(lines.joined(separator: "\n"))
      case .table(let header, _, let rows): return (header + rows.flatMap { $0 }).flatMap(inline)
      case .math(let latex, let open): return open ? [] : MathTeX.keys(MathTeX.display(latex))
      case .code, .rule: return []
      }
    }
  }
}

/// Inline Markdown through AttributedString; inline code gets a monospaced font and a light wash.
enum MarkdownInline {
  /// On parse failure show the raw text: models occasionally emit half a construct.
  static func attributed(_ text: String, size: CGFloat) -> AttributedString {
    var string = (try? AttributedString(
      markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
    let code = string.runs
      .filter { $0.inlinePresentationIntent?.contains(.code) == true }
      .map(\.range)
    for range in code {
      // monospaced text looks larger at the same size
      string[range].font = Font.system(size: size * 0.9, design: .monospaced)
      string[range].backgroundColor = Palette.codeChip
    }
    return string
  }
}

/// Renders the blocks. Headings get more space above than below so they belong to what follows;
/// quotes use a 2 pt rule rather than a filled box.
struct MarkdownText: View {
  private let blocks: [MarkdownBlock]
  /// still streaming: a caret after the last block
  var streaming = false

  /// Stored apart from the reader's font size. Headings, tables and code scale from this base so
  /// their proportions survive resizing.
  @AppStorage("agentFontSize") private var base = 13.5

  init(_ text: String, streaming: Bool = false) {
    self.blocks = MarkdownParser.blocks(text, cache: !streaming)
    self.streaming = streaming
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Identified by index, not content: repeated blocks (two `---`) would collide and SwiftUI would
      // drop one. Indices of earlier blocks are stable while streaming.
      ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
        MarkdownBlockView(block: block, base: base, live: streaming && index == blocks.count - 1)
          .equatable()
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// One equatable view per block: while streaming only the last block changes, and unchanged ones
/// are skipped at `.equatable()` without re-parsing their inline Markdown and formulas.
private struct MarkdownBlockView: View, Equatable {
  let block: MarkdownBlock
  /// read from preferences by MarkdownText
  let base: Double
  /// the streaming last block: caret after it, an unclosed trailing formula held back
  let live: Bool

  var body: some View {
    switch block {
    case .heading(let level, let text):
      // heading sizes are ratios of the base, so they move together
      prose(text, size: base * [0, 1.26, 1.13, 1.03, 1.0, 1.0, 1.0][min(level, 6)], weight: .semibold)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, level <= 2 ? 15 : 12).padding(.bottom, 4)

    case .paragraph(let text):
      HStack(alignment: .bottom, spacing: 3) {
        prose(text, size: base, live: live)
          .lineSpacing(base * 0.37).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        if live { StreamingCaret().padding(.bottom, 2) }
      }
      .padding(.vertical, 5)

    case .list(let items):
      VStack(alignment: .leading, spacing: 5) {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            ListMarker(marker: item.marker, depth: item.depth, size: base)
            prose(item.text, size: base, live: live && index == items.count - 1)
              .lineSpacing(base * 0.3).textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.leading, CGFloat(item.depth) * base * 1.45)
        }
      }.padding(.vertical, 5).padding(.leading, 2)

    case .quote(let lines):
      HStack(alignment: .top, spacing: 10) {
        RoundedRectangle(cornerRadius: 1).fill(Palette.accent.opacity(0.4)).frame(width: 2)
        prose(lines.joined(separator: "\n"), size: base - 0.5, tint: Palette.inkSoft, live: live)
          .lineSpacing(base * 0.33).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }.padding(.vertical, 7)

    case .code(let language, let body):
      CodeBlock(language: language, code: body, size: base - 2).padding(.vertical, 7)

    case .table(let header, let alignments, let rows):
      MarkdownTable(header: header, alignments: alignments, rows: rows, size: base - 1.5)
        .padding(.vertical, 8)

    case .math(let latex, let open):
      MathDisplayBlock(latex: latex, size: base, open: open)

    case .rule:
      Hairline().padding(.vertical, 11)
    }
  }

  /// Only paragraphs that contain math take the formula path; most have none.
  @ViewBuilder
  private func prose(
    _ text: String, size: CGFloat, tint: Color = Palette.ink, weight: Font.Weight = .regular,
    live: Bool = false
  ) -> some View {
    if MathTeX.hasMath(text, live: live) {
      MathInlineText(text: text, size: size, tint: tint, weight: weight, live: live)
    } else {
      Text(MarkdownInline.attributed(text, size: size))
        .font(.system(size: size, weight: weight))
        .foregroundStyle(tint)
    }
  }
}

/// Text rather than Circle: shapes have no baseline and sink in a firstTextBaseline HStack.
private struct ListMarker: View {
  let marker: MarkdownListItem.Marker
  let depth: Int
  let size: Double

  var body: some View {
    switch marker {
    case .bullet:
      // a different marker per level
      Text(["•", "◦", "▪︎"][depth % 3])
        .font(.system(size: size, weight: .bold))
        .foregroundStyle(Palette.accent.opacity(0.55))
        .frame(minWidth: size * 0.75)
    case .number(let number):
      Text("\(number).")
        .font(.system(size: size - 1, weight: .medium).monospacedDigit())
        .foregroundStyle(Palette.accent.opacity(0.85))
        .frame(minWidth: size * 1.2, alignment: .trailing)
    case .task(let done):
      Text(Image(systemName: done ? "checkmark.square.fill" : "square"))
        .font(.system(size: size - 1))
        .foregroundStyle(done ? Palette.accent : Palette.inkFaint)
    }
  }
}

/// Language label on top, copy on hover, coloured by CodeHighlight.
private struct CodeBlock: View {
  let language: String
  /// can't be called body: it would clash with View.body
  let code: String
  var size: CGFloat = 11.5
  @State private var hovering = false
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !language.isEmpty {
        Text(language.lowercased())
          .font(.system(size: size - 1.5, weight: .medium, design: .monospaced))
          .foregroundStyle(Palette.inkFaint)
          .padding(.horizontal, 13).padding(.top, 9)
      }
      // Horizontal scroll views are greedy vertically too and take all the height offered;
      // fixedSize(vertical:) pins the height to the content.
      ScrollView(.horizontal, showsIndicators: false) {
        Text(CodeHighlight.attributed(code, language: language))
          .font(.system(size: size, design: .monospaced))
          .foregroundStyle(Palette.ink.opacity(0.88))
          .lineSpacing(3.5)
          .textSelection(.enabled)
          .padding(.horizontal, 13)
          .padding(.top, language.isEmpty ? 11 : 6).padding(.bottom, 11)
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Palette.sunk, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.ruleSoft))
    // the copy button floats, so hovering never makes the block taller
    .overlay(alignment: .topTrailing) {
      if hovering || copied {
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(code, forType: .string)
          copied = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
        } label: {
          Label(copied ? L("已复制", "Copied") : L("复制", "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
            .font(.system(size: size - 1.5))
            .foregroundStyle(Palette.inkFaint)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Palette.sunk, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 5).padding(.trailing, 6)
        .transition(.opacity)
      }
    }
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.14), value: hovering)
  }
}

/// Tables. A Grid, not an HStack per row: only Grid aligns column widths across rows.
///
/// With few columns long text wraps instead of scrolling sideways; from five columns on it
/// scrolls. Styled like a journal table: no vertical rules, just the header rule and top and
/// bottom borders. Inline formatting and formulas render as usual.
private struct MarkdownTable: View {
  let header: [String]
  let alignments: [MarkdownColumnAlignment]
  let rows: [[String]]
  var size: CGFloat = 12

  /// beyond this many columns, wrapping leaves two or three characters per line; scroll instead
  private static let wrapLimit = 4

  private var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }
  private var wraps: Bool { columns <= Self.wrapLimit }

  var body: some View {
    Group {
      if wraps {
        grid
      } else {
        // horizontally scrolling containers are greedy vertically; pin them
        ScrollView(.horizontal, showsIndicators: false) { grid }
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var grid: some View {
    Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
      // Cells align on the first baseline, not the top: a cell with a formula has a taller first line
      // and would otherwise sit half a line low.
      GridRow(alignment: .firstTextBaseline) {
        ForEach(0..<columns, id: \.self) { cell(header, $0, isHeader: true) }
      }
      // views placed directly in the Grid span the row; gridCellUnsizedAxes keeps the divider's
      // infinite width out of the column sizing
      Divider().overlay(Palette.rule).gridCellUnsizedAxes(.horizontal)
      ForEach(Array(rows.enumerated()), id: \.offset) { offset, cells in
        if offset > 0 {
          Divider().overlay(Palette.ruleSoft).gridCellUnsizedAxes(.horizontal)
        }
        GridRow(alignment: .firstTextBaseline) {
          ForEach(0..<columns, id: \.self) { cell(cells, $0, isHeader: false) }
        }
      }
    }
    .padding(.vertical, 3)
    .overlay(alignment: .top) { Hairline() }
    .overlay(alignment: .bottom) { Hairline() }
  }

  private func cell(_ cells: [String], _ index: Int, isHeader: Bool) -> some View {
    let text = index < cells.count ? cells[index] : ""
    let alignment = index < alignments.count ? alignments[index] : .leading
    let tint = isHeader ? Palette.inkSoft : Palette.ink
    let weight: Font.Weight = isHeader ? .semibold : .regular
    let cellSize = isHeader ? size - 0.5 : size
    return Group {
      if MathTeX.hasMath(text) {
        MathInlineText(text: text, size: cellSize, tint: tint, weight: weight)
      } else {
        Text(MarkdownInline.attributed(text, size: cellSize))
          .font(.system(size: cellSize, weight: weight))
          .foregroundStyle(tint)
      }
    }
    .multilineTextAlignment(alignment.text)
    .lineSpacing(2.5)
    .textSelection(.enabled)
    .fixedSize(horizontal: false, vertical: true)
    .frame(minWidth: 52, maxWidth: wraps ? .infinity : 230, alignment: alignment.frame)
    .padding(.horizontal, 11).padding(.vertical, 7)
  }
}

private extension MarkdownColumnAlignment {
  var text: TextAlignment {
    switch self {
    case .leading: return .leading
    case .center: return .center
    case .trailing: return .trailing
    }
  }

  var frame: Alignment {
    switch self {
    case .leading: return .topLeading
    case .center: return .top
    case .trailing: return .topTrailing
    }
  }
}
