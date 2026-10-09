import SwiftUI

// Formulas in conversation text: split them out, strip equation numbers, and have MathRenderer
// typeset them into vector images inside native text. The look before typesetting, or without
// it, is in MathDraft.swift.

// MARK: - Splitting

/// plain text and formulas within a paragraph
enum InlineSpan: Equatable {
  case text(String)
  case math(String)
}

extension MathTeX {
  /// KaTeX's Computer Modern has a smaller x-height than the system font and looks a size smaller
  /// side by side. KaTeX uses 1.21 on the web; next to dense CJK text 1.1 matches best.
  static let inlineScale: CGFloat = 1.1
  static let displayScale: CGFloat = 1.16

  /// a lone delimiter hides at most this many characters; beyond that it probably isn't math
  private static let tailLimit = 400

  /// Split out `$...$`, `$$...$$`, `\(...\)` and `\[...\]`.
  /// - `\$` is an escaped dollar; `$` inside backticks (`$HOME`) is code
  /// - `$` followed by whitespace is plain text, and so is a formula of only whitespace
  /// - unpaired delimiters stay plain text, which is normal while streaming: the closing `$` hasn't
  ///   arrived and the rest must not be swallowed
  ///
  /// - Parameter holdingOpenTail: the streaming paragraph. Its unclosed trailing formula is held back;
  ///   showing half the LaTeX and then swapping in the typeset formula flickers.
  static func spans(_ text: String, holdingOpenTail: Bool = false) -> [InlineSpan] {
    let characters = Array(text)
    var out: [InlineSpan] = []
    var buffer = ""
    var index = 0

    func flush() {
      if !buffer.isEmpty { out.append(.text(buffer)); buffer = "" }
    }

    while index < characters.count {
      let character = characters[index]
      let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil

      if character == "\\", next == "$" {
        buffer.append("$")
        index += 2
        continue
      }
      // inline code stays Markdown: `$` there is a shell variable or placeholder
      if character == "`" {
        let end = codeSpanEnd(characters, from: index)
        buffer.append(contentsOf: characters[index..<end])
        index = end
        continue
      }

      let closer: [Character]
      switch (character, next) {
      case ("$", "$"): closer = ["$", "$"]
      case ("$", _): closer = ["$"]
      case ("\\", "("): closer = ["\\", ")"]
      case ("\\", "["): closer = ["\\", "]"]
      default:
        buffer.append(character)
        index += 1
        continue
      }
      let start = index + (closer == ["$"] ? 1 : 2)
      if character == "$", start < characters.count, characters[start].isWhitespace {
        buffer.append(contentsOf: characters[index..<start])
        index = start
        continue
      }
      if let end = closing(closer, in: characters, from: start) {
        let body = String(characters[start..<end])
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          buffer.append(contentsOf: characters[index..<(end + closer.count)])
        } else {
          flush()
          out.append(.math(body))
        }
        index = end + closer.count
        continue
      }
      if holdingOpenTail, characters.count - start <= tailLimit { break }
      buffer.append(contentsOf: characters[index..<start])
      index = start
    }
    flush()
    return out
  }

  /// A cheap character check before real splitting; most paragraphs contain no delimiter.
  /// `live`: any delimiter counts, so an unclosed formula can be held back.
  static func hasMath(_ text: String, live: Bool = false) -> Bool {
    guard text.contains("$") || text.contains("\\(") || text.contains("\\[") else { return false }
    if live { return true }
    return spans(text).contains { if case .math = $0 { return true }; return false }
  }

  /// Finds the closing delimiter from `from`, skipping backslash escapes (`\$`, `\\`).
  private static func closing(_ closer: [Character], in characters: [Character], from: Int) -> Int? {
    var scan = from
    while scan < characters.count {
      let character = characters[scan]
      if closer[0] == "\\" {
        if character == "\\", scan + 1 < characters.count {
          if characters[scan + 1] == closer[1] { return scan }
          scan += 2
          continue
        }
      } else {
        if character == "\\" { scan += 2; continue }
        if character == "$" {
          if closer.count == 1 { return scan }
          if scan + 1 < characters.count, characters[scan + 1] == "$" { return scan }
        }
      }
      scan += 1
    }
    return nil
  }

  /// An inline code span ends at a backtick run of the same length; without one only the run itself
  /// is consumed.
  private static func codeSpanEnd(_ characters: [Character], from: Int) -> Int {
    var run = from
    while run < characters.count, characters[run] == "`" { run += 1 }
    let ticks = run - from
    var scan = run
    while scan < characters.count {
      guard characters[scan] == "`" else { scan += 1; continue }
      var close = scan
      while close < characters.count, characters[close] == "`" { close += 1 }
      if close - scan == ticks { return close }
      scan = close
    }
    return run
  }
}

// MARK: - Before typesetting

extension MathTeX {
  /// A display formula as it goes to the typesetter.
  struct Display: Equatable {
    /// without `\label` and the equation number
    var body: String
    /// `\tag{3}` -> `(3)`, `\tag*{A}` -> `A`; nil without one
    var tag: String?
  }

  /// Strip the equation number and `\label`. The number is placed by the view: KaTeX positions it
  /// absolutely at the line end, and the typesetter crops to the content, so it would overlap the
  /// formula. Only a tag outside environments is stripped; per-row tags in `align` stay with KaTeX.
  static func display(_ latex: String) -> Display {
    var characters = Array(withoutLabels(latex))
    var tags: [(range: Range<Int>, text: String)] = []
    var depth = 0
    var index = 0
    while index < characters.count {
      guard characters[index] == "\\" else { index += 1; continue }
      let (name, after) = command(at: index, in: characters)
      if name == "begin" { depth += 1 }
      if name == "end" { depth = max(0, depth - 1) }
      if name == "tag", depth == 0 {
        var cursor = after
        let starred = cursor < characters.count && characters[cursor] == "*"
        if starred { cursor += 1 }
        while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
        if let group = braced(characters, from: cursor) {
          tags.append((index..<group.end, starred ? group.body : "(\(group.body))"))
          index = group.end
          continue
        }
      }
      index = after
    }
    var tag: String? = nil
    if tags.count == 1, let only = tags.first {
      characters.removeSubrange(only.range)
      tag = only.text
    }
    return Display(
      body: normalizedEnvironments(String(characters)).trimmingCharacters(in: .whitespacesAndNewlines),
      tag: tag)
  }

  /// KaTeX doesn't know `\label`, and it produces no output anyway.
  static func withoutLabels(_ latex: String) -> String {
    guard latex.contains("\\label") else { return latex }
    var characters = Array(latex)
    var index = 0
    while index < characters.count {
      guard characters[index] == "\\" else { index += 1; continue }
      let (name, after) = command(at: index, in: characters)
      if name == "label" {
        var cursor = after
        while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
        if let group = braced(characters, from: cursor) {
          characters.removeSubrange(index..<group.end)
          continue
        }
      }
      index = after
    }
    return String(characters)
  }

  /// Environments common in papers but missing in KaTeX, replaced by ones that render the same.
  private static func normalizedEnvironments(_ latex: String) -> String {
    guard latex.contains("\\begin{") else { return latex }
    var out = latex
    for (from, to) in [
      ("multline*", "gather*"), ("multline", "gather"),
      ("eqnarray*", "align*"), ("eqnarray", "align"),
    ] {
      out = out.replacingOccurrences(of: "\\begin{\(from)}", with: "\\begin{\(to)}")
        .replacingOccurrences(of: "\\end{\(from)}", with: "\\end{\(to)}")
    }
    return out
  }

  /// The name of `\name` and the index after it; single-character commands (`\\`, `\{`) count.
  private static func command(at index: Int, in characters: [Character]) -> (String, Int) {
    var scan = index + 1
    while scan < characters.count, characters[scan].isLetter { scan += 1 }
    if scan == index + 1 {
      return scan < characters.count ? (String(characters[scan]), scan + 1) : ("", scan)
    }
    return (String(characters[(index + 1)..<scan]), scan)
  }

  /// Reads a `{...}` from `from`; returns its contents and the index after the closing brace.
  private static func braced(_ characters: [Character], from: Int) -> (body: String, end: Int)? {
    guard from < characters.count, characters[from] == "{" else { return nil }
    var depth = 0
    var index = from
    var body = ""
    while index < characters.count {
      let character = characters[index]
      if character == "\\", index + 1 < characters.count {
        if depth > 0 { body.append(character); body.append(characters[index + 1]) }
        index += 2
        continue
      }
      if character == "{" {
        depth += 1
        if depth == 1 { index += 1; continue }
      }
      if character == "}" {
        depth -= 1
        if depth == 0 { return (body, index + 1) }
      }
      body.append(character)
      index += 1
    }
    return nil
  }

  // MARK: Typesetter keys

  static func inlineKey(_ latex: String) -> MathRenderer.Key {
    MathRenderer.Key(latex: withoutLabels(latex), display: false)
  }

  static func displayKey(_ display: Display) -> MathRenderer.Key {
    MathRenderer.Key(latex: display.body, display: true)
  }

  /// Numbers go through KaTeX too, so they share the formula's font.
  static func tagKey(_ tag: String) -> MathRenderer.Key {
    MathRenderer.Key(latex: "\\text{\(tag)}", display: false)
  }

  static func keys(_ spans: [InlineSpan]) -> [MathRenderer.Key] {
    spans.compactMap { span in
      if case .math(let latex) = span { return inlineKey(latex) }
      return nil
    }
  }

  static func keys(_ display: Display) -> [MathRenderer.Key] {
    [displayKey(display)] + (display.tag.map { [tagKey($0)] } ?? [])
  }
}

// MARK: - Views

/// Text with inline formulas, wrapping and selectable. Built by adding Texts, since an HStack
/// doesn't wrap; each formula is a vector template image embedded as one glyph, on the text
/// baseline and in the text colour.
struct MathInlineText: View {
  let text: String
  var size: CGFloat = 13.5
  var tint: Color = Palette.ink
  var weight: Font.Weight = .regular
  /// the streaming paragraph: an unclosed trailing formula is held back (MathTeX.spans)
  var live = false
  /// Bumped when the typesetter returns, to redraw just this paragraph. Observing the global
  /// typesetter instead would redraw every paragraph with math whenever any formula finished.
  @State private var settled = 0

  var body: some View {
    let spans = MathTeX.spans(text, holdingOpenTail: live)
    let keys = MathTeX.keys(spans)
    let _ = settled
    spans.reduce(Text("")) { acc, span in
      switch span {
      case .text(let plain): return acc + Text(MarkdownInline.attributed(plain, size: size))
      case .math(let latex): return acc + Self.formula(latex, size: size)
      }
    }
    .font(.system(size: size, weight: weight))
    .foregroundStyle(tint)
    .task(id: keys) {
      let renderer = MathRenderer.shared
      guard keys.contains(where: { renderer.outcome($0) == nil }) else { return }
      await renderer.typeset(keys)
      settled &+= 1
    }
  }

  /// Typeset: an image. Rejected by KaTeX: the source. Not yet typeset: the draft.
  static func formula(_ latex: String, size: CGFloat) -> Text {
    let key = MathTeX.inlineKey(latex)
    let renderer = MathRenderer.shared
    if let typeset = renderer.image(key, em: size * MathTeX.inlineScale) {
      // images sit on the baseline; the formula's own baseline is `descent` above the image bottom
      return Text(Image(nsImage: typeset.image).renderingMode(.template))
        .baselineOffset(-typeset.descent)
    }
    if case .failed? = renderer.outcome(key) {
      return Text(latex)
        .font(.system(size: size * 0.9, design: .monospaced))
        .foregroundStyle(Palette.inkSoft)
    }
    return MathTeX.draft(latex, size: size)
  }
}

/// Display formulas: centred, a size larger, with space around, numbered at the line end. Wider
/// than the column they scroll sideways: shrinking makes them unreadable, wrapping breaks them.
struct MathDisplayBlock: View {
  let latex: String
  var size: CGFloat = 13.5
  /// streaming, closing delimiter not here yet: show the source, typeset once closed
  var open = false
  /// the conversation's gap scale (type size and density)
  var spacing: CGFloat = 1
  @State private var settled = 0

  var body: some View {
    let display = MathTeX.display(latex)
    let keys = open ? [] : MathTeX.keys(display)
    let _ = settled
    content(display)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 9 * spacing)
      .contextMenu {
        Button(L("复制 LaTeX", "Copy LaTeX")) {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(latex, forType: .string)
        }
      }
      .task(id: keys) {
        let renderer = MathRenderer.shared
        guard keys.contains(where: { renderer.outcome($0) == nil }) else { return }
        await renderer.typeset(keys)
        settled &+= 1
      }
  }

  @ViewBuilder
  private func content(_ display: MathTeX.Display) -> some View {
    let renderer = MathRenderer.shared
    let em = size * MathTeX.displayScale
    let key = MathTeX.displayKey(display)
    if open {
      source
    } else if let formula = renderer.image(key, em: em) {
      DisplayFormula(
        formula: formula.image,
        tag: display.tag.map { tag in
          renderer.image(MathTeX.tagKey(tag), em: em).map { .typeset($0.image) } ?? .plain(tag)
        },
        size: size)
        .accessibilityLabel(Text(latex))
    } else if case .failed? = renderer.outcome(key) {
      source
    } else {
      // reserve about the right height, so the text below doesn't jump when the image arrives
      Color.clear.frame(height: estimatedHeight(display.body, em: em))
    }
  }

  /// The source: for formulas that can't be typeset, and for the unclosed one.
  private var source: some View {
    Text(latex)
      .font(.system(size: size - 1.5, design: .monospaced))
      .foregroundStyle(Palette.inkSoft)
      .lineSpacing(3)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12).padding(.vertical, 9)
      .background(Palette.sunk.opacity(0.7), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
  }

  private func estimatedHeight(_ body: String, em: CGFloat) -> CGFloat {
    let rows = CGFloat(body.components(separatedBy: "\\\\").count)
    let tall = ["\\frac", "\\dfrac", "\\sum", "\\int", "\\prod", "\\binom", "\\begin"]
      .contains { body.contains($0) }
    return em * (rows * 1.35 + (tall ? 1.0 : 0.25))
  }
}

/// A typeset display formula and its number.
private struct DisplayFormula: View {
  enum Tag {
    case typeset(NSImage)
    /// number not typeset (yet): plain text
    case plain(String)
  }

  let formula: NSImage
  let tag: Tag?
  let size: CGFloat

  var body: some View {
    // number at the line end, formula centred; both sides reserve the number's width so they never overlap
    ViewThatFits(in: .horizontal) {
      image
      ScrollView(.horizontal, showsIndicators: false) { image }
        // horizontal scroll views are greedy vertically; pin the height
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, gutter)
    .overlay(alignment: .trailing) { tagView }
  }

  private var image: some View {
    Image(nsImage: formula).renderingMode(.template).foregroundStyle(Palette.ink)
  }

  private var gutter: CGFloat {
    switch tag {
    case .typeset(let image)?: return image.size.width + 12
    case .plain?: return size * 2.6
    case nil: return 0
    }
  }

  @ViewBuilder
  private var tagView: some View {
    switch tag {
    case .typeset(let image)?:
      Image(nsImage: image).renderingMode(.template).foregroundStyle(Palette.inkSoft)
    case .plain(let text)?:
      Text(text).font(.system(size: size)).foregroundStyle(Palette.inkSoft)
    case nil:
      EmptyView()
    }
  }
}
