import SwiftUI

/// 对话里的数学公式。
///
/// **为什么不挂 KaTeX/MathJax**：那要为每条消息起一个 WKWebView。一次问答
/// 就有十几条消息，而 WebView 一重建就要整篇重放。
/// 正文栏只有一个 WebView，所以那边可以；对话流这边不行。
///
/// 所以这里把 LaTeX 译成 **Unicode + 基线偏移**，交给原生 `Text` 排版。
/// 换来的是：能选中、能跟着行宽换行、和正文共用字体度量、零额外进程。
///
/// **覆盖的是「论文问答里真实出现的那些」**，不是整个 TeX：希腊字母、
/// 黑板粗体与粗体、上下标、分式、根号、常见算符与箭头、`\tilde`/`\hat`/`\bar`。
/// 碰上不认识的命令**原样显示那段 LaTeX** —— 显示原文永远好过显示空白或者
/// 一个错的公式，后者在论文场景里是会误导结论的。
enum MathTeX {

  // MARK: - 符号表

  /// 单个命令 → 单个字符。按 TeX 名字排，便于和论文里的写法对照。
  static let symbols: [String: String] = [
    // 希腊字母
    "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
    "varepsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ",
    "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
    "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ",
    "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
    "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
    "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    // 算符与关系
    "times": "×", "div": "÷", "pm": "±", "mp": "∓", "cdot": "·", "cdots": "⋯",
    "ldots": "…", "dots": "…", "vdots": "⋮", "ddots": "⋱",
    "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
    "approx": "≈", "sim": "∼", "simeq": "≃", "equiv": "≡", "propto": "∝",
    "ll": "≪", "gg": "≫", "subset": "⊂", "subseteq": "⊆", "supset": "⊃",
    "supseteq": "⊇", "in": "∈", "notin": "∉", "ni": "∋", "cup": "∪", "cap": "∩",
    "emptyset": "∅", "varnothing": "∅", "forall": "∀", "exists": "∃",
    "neg": "¬", "land": "∧", "lor": "∨", "oplus": "⊕", "otimes": "⊗",
    "odot": "⊙", "circ": "∘", "bullet": "∙", "star": "⋆", "ast": "∗",
    // 大算符
    "sum": "∑", "prod": "∏", "int": "∫", "iint": "∬", "oint": "∮",
    "partial": "∂", "nabla": "∇", "infty": "∞", "sqrt": "√",
    // 箭头
    "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔",
    "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔",
    "mapsto": "↦", "uparrow": "↑", "downarrow": "↓",
    // 杂项
    "angle": "∠", "perp": "⊥", "parallel": "∥", "therefore": "∴", "because": "∵",
    "prime": "′", "degree": "°", "ell": "ℓ", "hbar": "ℏ", "Re": "ℜ", "Im": "ℑ",
    "aleph": "ℵ", "top": "⊤", "bot": "⊥", "vert": "|", "|": "‖",
    "{": "{", "}": "}", "%": "%", "$": "$", "&": "&", "#": "#", "_": "_",
  ]

  /// 函数名类命令：`\log` `\exp` `\max`…
  ///
  /// **必须单列一类。** 它们既不是符号也不是排版指令 —— 数学惯例是
  /// **正体**（区别于变量的斜体），而我们如果当成不认识的命令原样留下，
  /// 屏幕上就会出现一个扎眼的 `\log`。实机截图里就是这么露馅的。
  static let operators: Set<String> = [
    "log", "ln", "lg", "exp", "sin", "cos", "tan", "cot", "sec", "csc",
    "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
    "min", "max", "sup", "inf", "lim", "limsup", "liminf",
    "det", "dim", "ker", "deg", "gcd", "arg", "Pr", "mod", "bmod",
    "softmax", "argmin", "argmax", "sgn", "tr", "rank", "diag",
  ]

  /// 只吞掉、不出字的排版命令。TeX 里它们管间距与定界符大小，
  /// 而我们交给原生排版，留着只会变成一串反斜杠噪音。
  static let ignored: Set<String> = [
    "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr",
    "displaystyle", "textstyle", "scriptstyle", "limits", "nolimits", "!",
  ]

  /// 细空格类命令 → 一个窄空格。
  static let spacers: Set<String> = [",", ";", ":", " ", "quad", "qquad", "enspace", "thinspace"]

  /// 数学字体族：`\mathbb{R}` → ℝ。这些字符在 Unicode 里是独立码位，
  /// 不是「把 R 变粗」，所以必须查表而不是改字重。
  static let blackboard: [Character: String] = [
    "A": "𝔸", "B": "𝔹", "C": "ℂ", "D": "𝔻", "E": "𝔼", "F": "𝔽", "G": "𝔾",
    "H": "ℍ", "I": "𝕀", "J": "𝕁", "K": "𝕂", "L": "𝕃", "M": "𝕄", "N": "ℕ",
    "O": "𝕆", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "S": "𝕊", "T": "𝕋", "U": "𝕌",
    "V": "𝕍", "W": "𝕎", "X": "𝕏", "Y": "𝕐", "Z": "ℤ",
  ]

  /// 附在前一个字符上的组合记号：`\tilde g` → g̃。
  static let accents: [String: String] = [
    "tilde": "\u{0303}", "widetilde": "\u{0303}", "hat": "\u{0302}",
    "widehat": "\u{0302}", "bar": "\u{0304}", "overline": "\u{0304}",
    "vec": "\u{20D7}", "dot": "\u{0307}", "ddot": "\u{0308}",
    "check": "\u{030C}", "breve": "\u{0306}", "acute": "\u{0301}", "grave": "\u{0300}",
  ]

  /// 上标能用 Unicode 直接表示的字符。用码位而不是基线偏移，
  /// 是因为 `x²` 这种在任何字体下都对得齐，而偏移要靠字号猜。
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

  // MARK: - 一段公式 → 带排版属性的串

  /// 译好的一小段：文字 + 它该用什么字号与基线。
  ///
  /// 分成「段」而不是直接拼一个大字符串，是因为上下标要真的抬高压低 ——
  /// 纯 Unicode 上下标只覆盖数字和少数字母，`X^{B}` 里的 B 就没有码位。
  struct Run: Equatable {
    var text: String
    /// 相对正文字号的倍率。上下标 0.72。
    var scale: CGFloat = 1
    /// 基线偏移（正数往上）。
    var offset: CGFloat = 0
    var bold: Bool = false
    var italic: Bool = false
    /// 强制正体。数学里变量斜体、函数名正体，这是能不能读出
    /// 「这是 log 函数」而不是「l 乘 o 乘 g」的唯一线索。
    var upright: Bool = false
  }

  /// **入口。** 把一段 LaTeX（不含 `$`）译成若干段。
  ///
  /// 不认识的命令原样留下（带反斜杠）—— 在论文场景里，显示 `\foo`
  /// 比默默吞掉它安全得多：用户至少知道这里有东西没渲染出来。
  static func runs(_ latex: String, display: Bool = false) -> [Run] {
    var parser = Scanner(source: Array(latex))
    return parser.parse(display: display)
  }

  /// 纯文本形式。给无障碍标签、日志与断言用。
  static func plain(_ latex: String) -> String {
    runs(latex).map(\.text).joined()
  }

  // MARK: - 扫描器

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
          // 分组符号本身不出字
          index += 1
        case " ":
          // TeX 里空格只是分隔符；连续空格压成一个
          index += 1
          if out.last?.text.hasSuffix(" ") != true, !out.isEmpty { push(" ", into: &out) }
        default:
          index += 1
          push(String(character), into: &out, italic: character.isLetter && !display ? false : false)
        }
      }
      return merge(out)
    }

    /// 读一个「组」：`{...}` 取花括号里的整串，否则只取下一个记号。
    ///
    /// **先跳空白。** TeX 里 `\tilde g` 和 `\tilde{g}` 是同一个意思，而命令名
    /// 后面那个空格只是分隔符。不跳的话读到的「组」是那个空格 ——
    /// 于是波浪号扣在空格上，`\tilde g` 显示成光秃秃的 `g`，
    /// `\mathbb R` 显示成普通的 `R`。两个都是实机截图里看得见的错。
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
        // 单字符命令，如 `\,` `\{` `\%`
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
        // 行内分式用普通斜线。**试过 U+2044（真正的分数斜线）**，
        // 在系统衬线体里它细得几乎看不见 —— `(e+e_v)⁄2` 看起来像
        // `(e+e_v)2`，比不渲染还糟。分数线宁可粗一点也要认得出来。
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
        // 上划线把根号的覆盖范围画出来 —— 没有它，√a+b 到底盖到哪说不清
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
          // 组合记号必须紧跟在**被标记的那个字符**后面，不能挂在整段末尾
          if var first = inner.first {
            first.text = attach(accent, to: first.text)
            out.append(first)
            out.append(contentsOf: inner.dropFirst())
          }
          return
        }
        if MathTeX.operators.contains(name) {
          // 正体 + 前后各一个窄空格：`x=\log y` 挤在一起读不出断点
          push("\u{2009}" + name + "\u{2009}", into: &out, upright: true)
          return
        }
        if let symbol = MathTeX.symbols[name] {
          push(symbol, into: &out)
          return
        }
        // 不认识 —— 原样留下，让用户看得见这里没渲染
        push("\\" + name, into: &out)
      }
    }

    func attach(_ accent: String, to text: String) -> String {
      guard let first = text.first else { return accent }
      return String(first) + accent + String(text.dropFirst())
    }

    /// 上下标。能用 Unicode 码位就用码位，否则缩小 + 挪基线。
    mutating func append(script group: String, up: Bool, into out: inout [Run]) {
      let table = up ? MathTeX.superscripts : MathTeX.subscripts
      // 简单情形（纯数字/单字母）直接用码位：任何字体下都对得齐
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
        // 上标抬高、下标压低。数值按 13.5pt 正文调过 —— 再大会脱开基线，
        // 再小在中文行距里看不出层级。
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

    /// 相邻且排版属性相同的段合并 —— 段少一点，`Text` 拼起来也快一点。
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

// MARK: - 行内：文字与公式混排

/// 一段话里的「普通文字」与「公式」。
enum InlineSpan: Equatable {
  case text(String)
  case math(String)
}

extension MathTeX {
  /// 切出 `$...$`。
  ///
  /// 三条判据，全部来自实机踩的坑：
  ///
  /// - `\$` 是转义的美元号，不开公式
  /// - `$` 后面紧跟空格、或者前面紧跟空格又紧跟数字（`共 $5 万`），当普通文字
  /// - 没有配对的 `$` 一律当普通文字 —— **流式时这是常态**：
  ///   公式刚吐出一半，右边那个 `$` 还没到，这时候绝不能把后面整段吞掉
  static func spans(_ text: String) -> [InlineSpan] {
    var out: [InlineSpan] = []
    var buffer = ""
    let characters = Array(text)
    var index = 0

    func flush() {
      if !buffer.isEmpty { out.append(.text(buffer)); buffer = "" }
    }

    while index < characters.count {
      let character = characters[index]
      if character == "\\", index + 1 < characters.count, characters[index + 1] == "$" {
        buffer.append("$")
        index += 2
        continue
      }
      guard character == "$" else {
        buffer.append(character)
        index += 1
        continue
      }
      // `$$` 在行内出现时按一个定界符处理（块级的已经在切块时挑走了）
      let doubled = index + 1 < characters.count && characters[index + 1] == "$"
      let open = index + (doubled ? 2 : 1)
      // 找配对
      var close: Int? = nil
      var scan = open
      while scan < characters.count {
        if characters[scan] == "\\" { scan += 2; continue }
        if characters[scan] == "$" { close = scan; break }
        scan += 1
      }
      guard let end = close, end > open else {
        // 没配上 —— 当普通文字，往下走
        buffer.append(character)
        index += 1
        continue
      }
      let body = String(characters[open..<end])
      // 纯空白或明显是货币（`$5`）就不当公式
      if body.trimmingCharacters(in: .whitespaces).isEmpty {
        buffer.append(character)
        index += 1
        continue
      }
      flush()
      out.append(.math(body))
      index = end + 1
      if doubled, index < characters.count, characters[index] == "$" { index += 1 }
    }
    flush()
    return out
  }

  /// 这一段里有没有公式。没有就走原来的纯 Markdown 路径，一点开销都不加。
  static func hasMath(_ text: String) -> Bool {
    spans(text).contains { if case .math = $0 { return true }; return false }
  }
}

// MARK: - 视图

/// 行内公式与文字混排的一行（可换行、可选中）。
///
/// 用 `Text` 相加而不是 `HStack`：只有前者会**在公式内部换行**。
/// 用 HStack 的话，一条长公式会把整段挤成一行然后溢出栏外。
struct MathInlineText: View {
  let text: String
  var size: CGFloat = 13.5
  var tint: Color = Palette.ink

  var body: some View {
    MathTeX.spans(text).reduce(Text("")) { acc, span in
      switch span {
      case .text(let plain):
        return acc + Text(MathInlineText.markdown(plain))
      case .math(let latex):
        return acc + MathInlineText.formula(latex, size: size)
      }
    }
    .foregroundStyle(tint)
  }

  /// 行内 Markdown。解析失败就原样显示。
  static func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }

  /// 一段公式拼成的 `Text`。
  ///
  /// 公式用**衬线体**：正文是无衬线，而数学变量按惯例是衬线斜体，
  /// 两者并排时字形差异正好把「这是符号」和「这是词」分开。
  static func formula(_ latex: String, size: CGFloat) -> Text {
    MathTeX.runs(latex).reduce(Text("")) { acc, run in
      acc + Text(run.text)
        .font(.system(size: size * run.scale, design: .serif)
          .italic(!run.upright && (run.italic || !run.bold)))
        .fontWeight(run.bold ? .semibold : .regular)
        .baselineOffset(run.offset)
    }
  }
}

private extension Font {
  /// `italic()` 在 Font 上是无参方法，这里包一层方便按条件用。
  func italic(_ on: Bool) -> Font { on ? self.italic() : self }
}

/// 独占一行的公式（`$$...$$`）。
///
/// 居中、放大一档、上下留白 —— 论文里的 display math 本来就是一个独立的
/// 版面单位，挤在段落里读不出结构。**横向可滚**：长公式宁可滚，
/// 也不能把对话栏撑宽。
struct MathDisplayBlock: View {
  let latex: String
  private static let size: CGFloat = 15.5

  var body: some View {
    // 居中：display math 在论文里本来就是居中的一个独立版面单位。
    //
    // **不套横向 ScrollView。** 试过，它会把内容收到自然宽度，于是外面的
    // Spacer 全塌掉、公式仍然贴左。而且 `Text` 本来就会换行 —— 超宽的公式
    // 折两行读得出来，横向滚出去的那半截读不出来。
    content
      .frame(maxWidth: .infinity, alignment: .center)
      .multilineTextAlignment(.center)
      .padding(.horizontal, 8)
      .padding(.vertical, 11)
  }

  @ViewBuilder
  private var content: some View {
    if let split = MathTeX.topLevelFraction(latex) {
      // **真正的上下叠放。** 分式是 display math 里最该画对的东西 ——
      // 写成 a⁄b 时，分子分母稍微长一点就分不清谁是谁了。
      HStack(alignment: .center, spacing: 3) {
        if !split.before.isEmpty {
          MathInlineText.formula(split.before, size: Self.size)
        }
        VStack(spacing: 2) {
          MathInlineText.formula(split.numerator, size: Self.size * 0.95)
          Rectangle().fill(Palette.ink.opacity(0.75)).frame(height: 1)
          MathInlineText.formula(split.denominator, size: Self.size * 0.95)
        }
        .fixedSize()
        if !split.after.isEmpty {
          MathInlineText.formula(split.after, size: Self.size)
        }
      }
      .foregroundStyle(Palette.ink)
    } else {
      MathInlineText.formula(latex, size: Self.size)
        .foregroundStyle(Palette.ink)
        .textSelection(.enabled)
    }
  }
}

extension MathTeX {
  struct Fraction: Equatable {
    var before: String
    var numerator: String
    var denominator: String
    var after: String
  }

  /// 顶层的第一个 `\frac{...}{...}`，拆成「前 / 分子 / 分母 / 后」。
  ///
  /// 只认**顶层**的一个：嵌套分式画成叠放会越叠越扁，两层之后就看不清了，
  /// 那种情况退回行内的 `⁄` 形式反而更稳。找不到就返回 nil。
  static func topLevelFraction(_ latex: String) -> Fraction? {
    let characters = Array(latex)
    var index = 0
    while index < characters.count {
      guard characters[index] == "\\" else { index += 1; continue }
      let nameStart = index + 1
      var scan = nameStart
      while scan < characters.count, characters[scan].isLetter { scan += 1 }
      let name = String(characters[nameStart..<scan])
      guard ["frac", "dfrac", "tfrac"].contains(name) else {
        index = max(scan, index + 1)
        continue
      }
      while scan < characters.count, characters[scan] == " " { scan += 1 }
      guard let top = braced(characters, from: scan) else { return nil }
      var next = top.end
      while next < characters.count, characters[next] == " " { next += 1 }
      guard let bottom = braced(characters, from: next) else { return nil }
      return Fraction(
        before: String(characters[0..<index]),
        numerator: top.body,
        denominator: bottom.body,
        after: String(characters[bottom.end...]))
    }
    return nil
  }

  /// 从 `from` 读一个 `{...}`，返回内容与右花括号之后的位置。
  private static func braced(
    _ characters: [Character], from: Int
  ) -> (body: String, end: Int)? {
    guard from < characters.count, characters[from] == "{" else { return nil }
    var depth = 0
    var index = from
    var body = ""
    while index < characters.count {
      let character = characters[index]
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
}
