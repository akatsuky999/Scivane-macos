import SwiftUI

/// Formula draft: LaTeX translated to Unicode plus baseline offsets for a native Text. Real
/// typesetting is KaTeX's (MathRenderer); the draft shows only before a formula is typeset, or for
/// the whole session if the typesetter can't start. It covers the common cases (Greek, blackboard
/// and bold, scripts, common operators and arrows, accents). Unknown commands show their LaTeX:
/// the source is better than a blank or a wrong formula.
enum MathTeX {

  // MARK: - Symbols

  /// One command, one character, ordered by TeX name.
  static let symbols: [String: String] = [
    // Greek letters
    "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
    "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ",
    "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
    "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ",
    "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
    "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
    "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    // operators and relations
    "times": "×", "div": "÷", "pm": "±", "mp": "∓", "cdot": "·", "cdots": "⋯",
    "ldots": "…", "dots": "…", "vdots": "⋮", "ddots": "⋱",
    "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
    "approx": "≈", "sim": "∼", "simeq": "≃", "equiv": "≡", "propto": "∝",
    "ll": "≪", "gg": "≫", "subset": "⊂", "subseteq": "⊆", "supset": "⊃",
    "supseteq": "⊇", "in": "∈", "notin": "∉", "ni": "∋", "cup": "∪", "cap": "∩",
    "emptyset": "∅", "varnothing": "∅", "forall": "∀", "exists": "∃",
    "neg": "¬", "land": "∧", "lor": "∨", "oplus": "⊕", "otimes": "⊗",
    "odot": "⊙", "circ": "∘", "bullet": "∙", "star": "⋆", "ast": "∗",
    // large operators
    "sum": "∑", "prod": "∏", "int": "∫", "iint": "∬", "oint": "∮",
    "partial": "∂", "nabla": "∇", "infty": "∞", "sqrt": "√",
    // arrows
    "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔",
    "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔",
    "mapsto": "↦", "uparrow": "↑", "downarrow": "↓",
    // miscellaneous
    "angle": "∠", "perp": "⊥", "parallel": "∥", "therefore": "∴", "because": "∵",
    "prime": "′", "degree": "°", "ell": "ℓ", "hbar": "ℏ", "Re": "ℜ", "Im": "ℑ",
    "aleph": "ℵ", "top": "⊤", "bot": "⊥", "vert": "|", "|": "‖",
    "{": "{", "}": "}", "%": "%", "$": "$", "&": "&", "#": "#", "_": "_",
  ]

  /// Function names (`\log`, `\exp`, `\max`): set upright, unlike italic variables. Left as unknown
  /// commands they would show as a raw `\log`.
  static let operators: Set<String> = [
    "log", "ln", "lg", "exp", "sin", "cos", "tan", "cot", "sec", "csc",
    "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
    "min", "max", "sup", "inf", "lim", "limsup", "liminf",
    "det", "dim", "ker", "deg", "gcd", "arg", "Pr", "mod", "bmod",
    "softmax", "argmin", "argmax", "sgn", "tr", "rank", "diag",
  ]

  /// Layout commands that produce no text (spacing, delimiter sizes); native layout handles that.
  static let ignored: Set<String> = [
    "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr",
    "displaystyle", "textstyle", "scriptstyle", "limits", "nolimits", "!",
  ]

  /// thin-space commands become a narrow space
  static let spacers: Set<String> = [",", ";", ":", " ", "quad", "qquad", "enspace", "thinspace"]

  /// `\mathbb{R}` -> ℝ. These are separate code points, not bold letters, so they need a table.
  static let blackboard: [Character: String] = [
    "A": "𝔸", "B": "𝔹", "C": "ℂ", "D": "𝔻", "E": "𝔼", "F": "𝔽", "G": "𝔾",
    "H": "ℍ", "I": "𝕀", "J": "𝕁", "K": "𝕂", "L": "𝕃", "M": "𝕄", "N": "ℕ",
    "O": "𝕆", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "S": "𝕊", "T": "𝕋", "U": "𝕌",
    "V": "𝕍", "W": "𝕎", "X": "𝕏", "Y": "𝕐", "Z": "ℤ",
  ]

  /// combining marks after the previous character: `\tilde g` -> g̃
  static let accents: [String: String] = [
    "tilde": "\u{0303}", "widetilde": "\u{0303}", "hat": "\u{0302}",
    "widehat": "\u{0302}", "bar": "\u{0304}", "overline": "\u{0304}",
    "vec": "\u{20D7}", "dot": "\u{0307}", "ddot": "\u{0308}",
    "check": "\u{030C}", "breve": "\u{0306}", "acute": "\u{0301}", "grave": "\u{0300}",
  ]

  /// Characters with Unicode superscript forms. Code points line up in any font; offsets have to
  /// guess from the font size.
  static let superscripts: [Character: Character] = [
    "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶",
    "7": "⁷", "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽",
    ")": "⁾", "n": "ⁿ", "i": "ⁱ",
  ]

  static let subscripts: [Character: Character] = [
    "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆",
    "7": "₇", "8": "₈", "9": "₉", "+": "₊", "-": "₋", "=": "₌", "(": "₍",
    ")": "₎", "a": "ₐ", "e": "ₑ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "m": "ₘ",
    "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ",
    "v": "ᵥ", "x": "ₓ",
  ]

  // MARK: - Formula -> styled runs

  /// A translated piece: text plus its size and baseline. Runs rather than one string because
  /// scripts must really be raised and lowered: Unicode only has superscripts for digits and a few
  /// letters.
  struct Run: Equatable {
    var text: String
    /// relative to the text size; scripts use 0.72
    var scale: CGFloat = 1
    /// baseline offset, positive is up
    var offset: CGFloat = 0
    var bold: Bool = false
    var italic: Bool = false
    /// Function names are upright and variables italic; that is what tells `log` from l times o times g.
    var upright: Bool = false
  }

  /// Entry point: LaTeX without `$`, translated into runs. Unknown commands keep their backslash so
  /// it is visible that something wasn't rendered.
  static func runs(_ latex: String, display: Bool = false) -> [Run] {
    var parser = Scanner(source: Array(latex))
    return parser.parse(display: display)
  }

  /// Plain text, for accessibility labels, logs and checks.
  static func plain(_ latex: String) -> String {
    runs(latex).map(\.text).joined()
  }

  // MARK: - Scanner

  private struct Scanner {
    let source: [Character]
    var index = 0

    init(source: [Character]) { self.source = source }

    var done: Bool { index >= source.count }
    func peek(_ ahead: Int = 0) -> Character? {
      index + ahead < source.count ? source[index + ahead] : nil
    }

    mutating func parse(display: Bool) -> [Run] {
      var out: [Run] = []
      while !done {
        let character = source[index]
        switch character {
        case "\\":
          index += 1
          appendCommand(into: &out)
        case "^", "_":
          index += 1
          let up = character == "^"
          let group = readGroup()
          append(script: group, up: up, into: &out)
        case "{", "}":
          // grouping braces produce no text
          index += 1
        case " ":
          // spaces only separate in TeX; runs collapse to one
          index += 1
          if out.last?.text.hasSuffix(" ") != true, !out.isEmpty { push(" ", into: &out) }
        default:
          index += 1
          push(String(character), into: &out, italic: character.isLetter && !display ? false : false)
        }
      }
      return merge(out)
    }

    /// Read a group: the contents of `{...}`, otherwise the next token. Skips spaces first: in TeX
    /// `\tilde g` equals `\tilde{g}`, and reading the space as the group put the accent on nothing.
    mutating func readGroup() -> String {
      while let character = peek(), character == " " { index += 1 }
      guard let first = peek() else { return "" }
      if first == "{" {
        index += 1
        var depth = 1
        var buffer = ""
        while let character = peek() {
          index += 1
          if character == "{" { depth += 1 }
          if character == "}" { depth -= 1; if depth == 0 { break } }
          buffer.append(character)
        }
        return buffer
      }
      if first == "\\" {
        index += 1
        let name = readName()
        return "\\" + name
      }
      index += 1
      return String(first)
    }

    mutating func readName() -> String {
      var name = ""
      while let character = peek(), character.isLetter {
        name.append(character)
        index += 1
      }
      if name.isEmpty, let character = peek() {
        // single-character commands such as `\,` `\{` `\%`
        name = String(character)
        index += 1
      }
      return name
    }

    mutating func appendCommand(into out: inout [Run]) {
      let name = readName()
      if MathTeX.ignored.contains(name) { return }
      if MathTeX.spacers.contains(name) {
        push("\u{2009}", into: &out)
        return
      }
      switch name {
      case "frac", "dfrac", "tfrac":
        let top = readGroup()
        let bottom = readGroup()
        // Inline fractions use a plain slash. U+2044, the real fraction slash, is almost invisible in the
        // system serif face.
        let needsTop = top.count > 1
        let needsBottom = bottom.count > 1
        push(needsTop ? "(" : "", into: &out)
        out.append(contentsOf: MathTeX.runs(top))
        push(needsTop ? ")" : "", into: &out)
        push("/", into: &out)
        push(needsBottom ? "(" : "", into: &out)
        out.append(contentsOf: MathTeX.runs(bottom))
        push(needsBottom ? ")" : "", into: &out)
      case "sqrt":
        push("√", into: &out)
        let body = readGroup()
        let inner = MathTeX.runs(body)
        // an overline shows how far the root extends
        out.append(contentsOf: inner.map {
          var run = $0
          run.text = $0.text.map { String($0) + "\u{0305}" }.joined()
          return run
        })
      case "mathbb", "Bbb":
        let body = readGroup()
        push(body.map { MathTeX.blackboard[$0] ?? String($0) }.joined(), into: &out)
      case "mathbf", "bm", "boldsymbol", "mathbfit":
        let body = readGroup()
        out.append(contentsOf: MathTeX.runs(body).map {
          var run = $0; run.bold = true; return run
        })
      case "mathcal", "mathscr", "mathfrak", "mathsf", "mathtt", "mathit":
        let body = readGroup()
        out.append(contentsOf: MathTeX.runs(body).map {
          var run = $0; run.italic = name == "mathit"; return run
        })
      case "text", "textrm", "mathrm", "operatorname", "mbox", "textbf", "textit":
        let body = readGroup()
        push(body, into: &out, bold: name == "textbf", italic: name == "textit")
      default:
        if let accent = MathTeX.accents[name] {
          let body = readGroup()
          let inner = MathTeX.runs(body)
          // combining marks must follow the marked character, not the end of the group
          if var first = inner.first {
            first.text = attach(accent, to: first.text)
            out.append(first)
            out.append(contentsOf: inner.dropFirst())
          }
          return
        }
        if MathTeX.operators.contains(name) {
          // upright with a thin space on each side, so `x=\log y` doesn't run together
          push("\u{2009}" + name + "\u{2009}", into: &out, upright: true)
          return
        }
        if let symbol = MathTeX.symbols[name] {
          push(symbol, into: &out)
          return
        }
        // unknown: keep it as is, so it is visible that it wasn't rendered
        push("\\" + name, into: &out)
      }
    }

    func attach(_ accent: String, to text: String) -> String {
      guard let first = text.first else { return accent }
      return String(first) + accent + String(text.dropFirst())
    }

    /// Scripts: Unicode code points when possible, otherwise smaller and shifted.
    mutating func append(script group: String, up: Bool, into out: inout [Run]) {
      let table = up ? MathTeX.superscripts : MathTeX.subscripts
      // simple cases (digits, one letter) use code points, which line up in any font
      if !group.isEmpty, !group.contains("\\"),
        group.allSatisfy({ table[$0] != nil })
      {
        push(String(group.map { table[$0]! }), into: &out)
        return
      }
      let inner = MathTeX.runs(group)
      out.append(contentsOf: inner.map {
        var run = $0
        run.scale = 0.72
        // tuned for 13.5 pt text: more detaches from the baseline, less is lost in CJK line spacing
        run.offset = up ? 4.5 : -2.5
        return run
      })
    }

    func push(
      _ text: String, into out: inout [Run],
      bold: Bool = false, italic: Bool = false, upright: Bool = false
    ) {
      guard !text.isEmpty else { return }
      out.append(Run(text: text, bold: bold, italic: italic, upright: upright))
    }

    /// merge neighbours with the same attributes: fewer runs, faster Text concatenation
    func merge(_ runs: [Run]) -> [Run] {
      var out: [Run] = []
      for run in runs {
        if var last = out.last, last.scale == run.scale, last.offset == run.offset,
          last.bold == run.bold, last.italic == run.italic, last.upright == run.upright
        {
          last.text += run.text
          out[out.count - 1] = last
        } else {
          out.append(run)
        }
      }
      return out
    }
  }
}

extension MathTeX {
  /// A serif face: math variables are conventionally serif italic, which sets symbols apart from the
  /// sans text.
  static func draft(_ latex: String, size: CGFloat) -> Text {
    runs(latex).reduce(Text("")) { acc, run in
      acc + Text(run.text)
        .font(.system(size: size * run.scale, design: .serif)
          .italic(!run.upright && (run.italic || !run.bold)))
        .fontWeight(run.bold ? .semibold : .regular)
        .baselineOffset(run.offset)
    }
  }
}

private extension Font {
  /// Font.italic() takes no argument; this makes it conditional
  func italic(_ on: Bool) -> Font { on ? self.italic() : self }
}
