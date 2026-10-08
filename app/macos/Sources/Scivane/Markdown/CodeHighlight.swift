import SwiftUI

/// Syntax colouring for code blocks: keywords, strings, comments and numbers (shell variables share
/// the number colour). One linear scan; each language only swaps its keyword table and comment
/// markers. Unknown languages stay uncoloured rather than wrongly coloured.
enum CodeHighlight {

  private enum Token {
    case keyword, string, comment, number
  }

  private struct Grammar {
    var keywords: Set<String> = []
    var lineComments: [String] = []
    var blockComment: (open: String, close: String)? = nil
    var quotes: Set<Character> = ["\"", "'"]
    /// Python's triple quotes
    var tripleQuotes = false
    /// shell `$VAR` and `${VAR}`
    var variables = false
    /// LaTeX `\command`
    var commands = false
    /// `#` starts a comment only at a word start (`$#` and `a#b` aren't comments in shell)
    var commentAtWordStart = false
  }

  /// Returned unchanged for an unknown language.
  static func attributed(_ code: String, language: String) -> AttributedString {
    guard let grammar = grammar(language.lowercased()) else { return AttributedString(code) }
    var out = AttributedString()
    var plain = ""
    for (text, token) in tokens(Array(code), grammar) {
      guard let token else { plain += text; continue }
      if !plain.isEmpty { out += AttributedString(plain); plain = "" }
      var piece = AttributedString(text)
      piece.foregroundColor = color(token)
      out += piece
    }
    if !plain.isEmpty { out += AttributedString(plain) }
    return out
  }

  private static func color(_ token: Token) -> Color {
    switch token {
    case .keyword: return Palette.codeKeyword
    case .string: return Palette.codeString
    case .comment: return Palette.inkFaint
    case .number: return Palette.codeNumber
    }
  }

  // MARK: - Scanning

  private static func tokens(_ source: [Character], _ grammar: Grammar) -> [(String, Token?)] {
    var out: [(String, Token?)] = []
    var index = 0

    func starts(_ text: String, at position: Int) -> Bool {
      var scan = position
      for character in text {
        guard scan < source.count, source[scan] == character else { return false }
        scan += 1
      }
      return true
    }
    func take(_ end: Int, _ token: Token?) {
      out.append((String(source[index..<end]), token))
      index = end
    }
    func lineEnd(from position: Int) -> Int {
      var scan = position
      while scan < source.count, source[scan] != "\n" { scan += 1 }
      return scan
    }
    func isWordCharacter(_ character: Character) -> Bool {
      character.isLetter || character.isNumber || character == "_"
    }

    while index < source.count {
      let character = source[index]
      let previous: Character? = index > 0 ? source[index - 1] : nil

      if let block = grammar.blockComment, starts(block.open, at: index) {
        var scan = index + block.open.count
        while scan < source.count, !starts(block.close, at: scan) { scan += 1 }
        take(min(source.count, scan + block.close.count), .comment)
        continue
      }
      if grammar.lineComments.contains(where: { starts($0, at: index) }),
        !grammar.commentAtWordStart || previous == nil || previous!.isWhitespace,
        // in LaTeX `\%` is a percent sign, not a comment
        !(grammar.commands && previous == "\\")
      {
        take(lineEnd(from: index), .comment)
        continue
      }
      if grammar.tripleQuotes, character == "\"" || character == "'",
        starts(String(repeating: character, count: 3), at: index)
      {
        let fence = String(repeating: character, count: 3)
        var scan = index + 3
        while scan < source.count, !starts(fence, at: scan) {
          scan += source[scan] == "\\" ? 2 : 1
        }
        take(min(source.count, scan + 3), .string)
        continue
      }
      if grammar.quotes.contains(character) {
        // strings don't span lines: an unclosed quote ends at the line end instead of colouring the rest
        var scan = index + 1
        while scan < source.count, source[scan] != character, source[scan] != "\n" {
          scan += source[scan] == "\\" ? 2 : 1
        }
        take(min(source.count, scan < source.count && source[scan] == character ? scan + 1 : scan), .string)
        continue
      }
      if grammar.variables, character == "$", index + 1 < source.count {
        var scan = index + 1
        if source[scan] == "{" {
          while scan < source.count, source[scan] != "}", source[scan] != "\n" { scan += 1 }
          scan = min(source.count, scan + 1)
        } else {
          while scan < source.count, isWordCharacter(source[scan]) { scan += 1 }
        }
        if scan > index + 1 { take(scan, .number); continue }
      }
      if grammar.commands, character == "\\" {
        var scan = index + 1
        while scan < source.count, source[scan].isLetter { scan += 1 }
        if scan > index + 1 { take(scan, .keyword); continue }
      }
      if character.isNumber, previous.map({ !isWordCharacter($0) }) ?? true {
        var scan = index + 1
        while scan < source.count,
          isWordCharacter(source[scan]) || source[scan] == "."
        { scan += 1 }
        take(scan, .number)
        continue
      }
      if character.isLetter || character == "_" {
        var scan = index + 1
        while scan < source.count, isWordCharacter(source[scan]) { scan += 1 }
        let word = String(source[index..<scan])
        take(scan, grammar.keywords.contains(word) ? .keyword : nil)
        continue
      }
      take(index + 1, nil)
    }
    return out
  }

  // MARK: - Languages

  private static func grammar(_ language: String) -> Grammar? {
    switch language {
    case "python", "py", "python3", "ipython", "pycon":
      return Grammar(
        keywords: [
          "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class",
          "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global",
          "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise",
          "return", "try", "while", "with", "yield", "match", "case",
        ],
        lineComments: ["#"], tripleQuotes: true)
    case "bash", "sh", "shell", "zsh", "console", "terminal", "shellscript":
      return Grammar(
        keywords: [
          "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case",
          "esac", "function", "in", "select", "return", "export", "local", "readonly", "unset",
          "source", "alias",
        ],
        lineComments: ["#"], variables: true, commentAtWordStart: true)
    case "javascript", "js", "jsx", "mjs", "typescript", "ts", "tsx":
      return Grammar(
        keywords: [
          "break", "case", "catch", "class", "const", "continue", "default", "delete", "do",
          "else", "export", "extends", "finally", "for", "function", "if", "import", "in",
          "instanceof", "let", "new", "return", "super", "switch", "this", "throw", "try",
          "typeof", "var", "void", "while", "yield", "async", "await", "of", "null",
          "undefined", "true", "false", "interface", "type", "enum", "implements", "readonly",
          "static", "as", "from",
        ],
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"])
    case "json", "jsonc", "json5":
      return Grammar(
        keywords: ["true", "false", "null"], lineComments: ["//"], blockComment: ("/*", "*/"),
        quotes: ["\""])
    case "yaml", "yml", "toml", "ini":
      return Grammar(
        keywords: ["true", "false", "null", "yes", "no", "on", "off"],
        lineComments: ["#"], commentAtWordStart: true)
    case "r":
      return Grammar(
        keywords: [
          "function", "if", "else", "for", "while", "repeat", "break", "next", "return", "in",
          "TRUE", "FALSE", "NULL", "NA", "Inf", "NaN", "library",
        ],
        lineComments: ["#"])
    case "matlab", "octave", "m":
      return Grammar(
        keywords: [
          "function", "end", "if", "else", "elseif", "for", "while", "switch", "case",
          "otherwise", "return", "break", "continue", "true", "false",
        ],
        lineComments: ["%"])
    case "latex", "tex":
      return Grammar(lineComments: ["%"], quotes: [], commands: true)
    case "swift", "c", "h", "cpp", "c++", "cc", "hpp", "cxx", "objc", "java", "kotlin", "kt",
      "rust", "rs", "go", "golang", "cs", "csharp", "c#", "scala", "dart", "cuda", "cu":
      return Grammar(keywords: cFamily, lineComments: ["//"], blockComment: ("/*", "*/"))
    default:
      return nil
    }
  }

  /// One keyword table for the C family: the languages share most keywords, and a word coloured in
  /// the wrong one (Rust's `type`) hardly misleads.
  private static let cFamily: Set<String> = [
    "auto", "bool", "break", "case", "catch", "char", "class", "const", "continue", "default",
    "defer", "delete", "do", "double", "else", "enum", "extends", "extern", "false", "final",
    "float", "for", "func", "fn", "go", "guard", "if", "impl", "implements", "import", "in",
    "inline", "int", "interface", "internal", "let", "long", "match", "mod", "mut", "namespace",
    "new", "nil", "null", "nullptr", "override", "package", "private", "protected", "pub",
    "public", "return", "self", "Self", "short", "signed", "sizeof", "static", "struct", "super",
    "switch", "template", "this", "throw", "throws", "trait", "true", "try", "typedef",
    "typename", "union", "unsigned", "use", "using", "val", "var", "virtual", "void",
    "volatile", "where", "while", "async", "await", "protocol", "extension", "some", "any",
    "init", "deinit", "fun", "object", "when", "is", "as", "type", "chan", "range", "select",
    "map", "__global__", "__device__", "__shared__",
  ]
}
