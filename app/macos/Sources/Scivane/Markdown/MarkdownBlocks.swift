import SwiftUI

/// 对话里的 Markdown 渲染。
///
/// **为什么不复用正文栏那套 WKWebView**：一次问答就有好几条消息，每条起一个
/// WebView 既费内存又慢，而且 WebView 一重建就要整篇重放。
/// 所以这里用原生视图搭一套块级渲染 —— 标题、列表、引用、代码块、**表格**、
/// 分隔线都认，行内加粗/斜体/行内代码/链接交给 `AttributedString`。
///
/// 代价是数学公式不渲染（正文栏仍然渲染）。论文问答里模型偶尔会写 `$...$`，
/// 那时候显示原文，比显示一片空白好。
enum MarkdownBlock: Identifiable, Equatable {
  case heading(level: Int, text: String)
  case paragraph(String)
  case bullets([String])
  case ordered([String])
  case quote([String])
  case code(language: String, body: String)
  case table(header: [String], rows: [[String]])
  /// 独占一行的公式（`$$...$$` 或 `\[...\]`）。
  case math(String)
  case rule

  /// 块的身份。
  ///
  /// **必须是纯函数。** 早先 `.rule` 返回的是 `"hr:\(UUID().uuidString)"` ——
  /// 每读一次 id 就是一个新值，于是 `ForEach` 每次 diff 都认为这一块换了，
  /// 整段正文跟着重建。一条 `---` 就够让一段本来静止的回答一直在重画，
  /// 而它不报错、只是风扇转起来。**id 里不许出现任何随机或时间。**
  ///
  /// 身份仍然带上内容：流式追加时最后一块会变，前面的块不该跟着重建。
  /// 重复内容（两条 `---`、两段一样的话）由 `MarkdownText` 用下标兜住。
  var id: String {
    switch self {
    case .heading(let level, let text): return "h\(level):\(text)"
    case .paragraph(let text): return "p:\(text)"
    case .bullets(let items): return "u:\(items.joined(separator: "|"))"
    case .ordered(let items): return "o:\(items.joined(separator: "|"))"
    case .quote(let lines): return "q:\(lines.joined(separator: "|"))"
    case .code(let language, let body): return "c:\(language):\(body)"
    case .table(let header, let rows):
      return "t:\(header.joined(separator: "|")):\(rows.count)"
    case .math(let latex): return "m:\(latex)"
    case .rule: return "hr"
    }
  }
}

/// 按行切块。**刻意写成线性扫描而不是递归下降** —— 模型吐出来的 Markdown
/// 嵌套很浅（标题、列表、代码块、表格），线性扫描够用而且流式追加时
/// 重跑一遍的代价可以忽略。
enum MarkdownParser {

  /// 解析结果的小缓存。
  ///
  /// **顶层改成全量渲染之后这条是必需的。** 每来一个流式分片，整条对话流
  /// 都要重建一遍视图；不缓存的话，前面每一段答案都会被重新切块 ——
  /// 一段两千字的答案切一次就是几千次字符串操作，十几轮叠起来，
  /// 每秒二十帧全花在重复解析已经定稿的老消息上。
  ///
  /// 老消息的文本是不会再变的，所以按文本做键恰好有效。只留最近 32 条：
  /// 缓存本身不该变成第二个内存坑，而屏幕上同时存在的答案远少于这个数。
  private static var cache: [String: [MarkdownBlock]] = [:]
  private static var recent: [String] = []
  private static let cacheLimit = 32

  /// - Parameter cache: 结果要不要留下。
  ///
  ///   **正在流式的那条必须传 false。** 它每 50ms 就是一个新文本、一个新键，
  ///   一段二十秒的回答能塞进四百个键 —— 把上面那 32 格反复挤空，
  ///   于是前面每一条已经定稿的老答案每帧都要重新切块。
  ///   缓存本来是为了省这件事，churn 之后反而比不缓存更糟。
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

  private static func parse(_ text: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []
    var bullets: [String] = []
    var ordered: [String] = []
    var quote: [String] = []
    var table: [[String]] = []

    func flushParagraph() {
      let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !joined.isEmpty { blocks.append(.paragraph(joined)) }
      paragraph.removeAll()
    }
    func flushLists() {
      if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets.removeAll() }
      if !ordered.isEmpty { blocks.append(.ordered(ordered)); ordered.removeAll() }
      if !quote.isEmpty { blocks.append(.quote(quote)); quote.removeAll() }
    }
    func flushTable() {
      guard !table.isEmpty else { return }
      let header = table[0]
      // 第二行是 |---|---| 那样的分隔行，跳过
      let body = table.count > 1 ? Array(table.dropFirst(isSeparator(table[1]) ? 2 : 1)) : []
      blocks.append(.table(header: header, rows: body))
      table.removeAll()
    }
    func flushAll() { flushParagraph(); flushLists(); flushTable() }

    var lines = text.components(separatedBy: "\n")[...]
    while let line = lines.first {
      lines = lines.dropFirst()
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      // 代码块：吃到收尾的 ``` 为止（没有收尾也要吐出来，流式时最后一块常常没闭合）
      if trimmed.hasPrefix("```") {
        flushAll()
        let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        var body: [String] = []
        while let next = lines.first, !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
          body.append(next)
          lines = lines.dropFirst()
        }
        if lines.first != nil { lines = lines.dropFirst() }
        blocks.append(.code(language: language, body: body.joined(separator: "\n")))
        continue
      }

      // 表格：连续的以 | 开头的行
      if trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), trimmed.count > 2 {
        flushParagraph(); flushLists()
        table.append(cells(trimmed))
        continue
      } else if !table.isEmpty {
        flushTable()
      }

      if trimmed.isEmpty { flushAll(); continue }

      // 独占一行的公式。`$$` 可能和公式同一行、也可能单独占一行，
      // 两种写法模型都在用；跨行的要吃到收尾的 `$$` 为止。
      // **没有收尾也要吐出来** —— 流式时最后一块常常还没闭合，
      // 把它吞掉的话公式会整段消失，等收尾那一刻又突然冒出来。
      if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") {
        flushAll()
        let opener = trimmed.hasPrefix("$$") ? "$$" : "\\["
        let closer = opener == "$$" ? "$$" : "\\]"
        var body = String(trimmed.dropFirst(opener.count))
        if body.hasSuffix(closer) {
          body = String(body.dropLast(closer.count))
        } else {
          var rest: [String] = body.isEmpty ? [] : [body]
          while let next = lines.first {
            lines = lines.dropFirst()
            let cut = next.trimmingCharacters(in: .whitespaces)
            if cut.hasSuffix(closer) {
              let head = String(cut.dropLast(closer.count))
              if !head.isEmpty { rest.append(head) }
              break
            }
            rest.append(next)
          }
          body = rest.joined(separator: " ")
        }
        let latex = body.trimmingCharacters(in: .whitespaces)
        if !latex.isEmpty { blocks.append(.math(latex)) }
        continue
      }

      if trimmed == "---" || trimmed == "***" || trimmed == "___" {
        flushAll(); blocks.append(.rule); continue
      }

      if let level = headingLevel(trimmed) {
        flushAll()
        blocks.append(.heading(
          level: level,
          text: String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
        continue
      }

      if trimmed.hasPrefix("> ") || trimmed == ">" {
        flushParagraph()
        if !bullets.isEmpty || !ordered.isEmpty { flushLists() }
        quote.append(String(trimmed.dropFirst(trimmed.count > 1 ? 2 : 1)))
        continue
      }

      if let item = bulletItem(trimmed) {
        flushParagraph()
        if !ordered.isEmpty || !quote.isEmpty { flushLists() }
        bullets.append(item)
        continue
      }

      if let item = orderedItem(trimmed) {
        flushParagraph()
        if !bullets.isEmpty || !quote.isEmpty { flushLists() }
        ordered.append(item)
        continue
      }

      // 普通段落：列表/引用一断就收尾
      if !bullets.isEmpty || !ordered.isEmpty || !quote.isEmpty { flushLists() }
      paragraph.append(line)
    }
    flushAll()
    return blocks
  }

  private static func headingLevel(_ line: String) -> Int? {
    var level = 0
    for character in line {
      if character == "#" { level += 1 } else { break }
    }
    guard level > 0, level <= 4, line.dropFirst(level).first == " " else { return nil }
    return level
  }

  private static func bulletItem(_ line: String) -> String? {
    for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
      return String(line.dropFirst(2))
    }
    return nil
  }

  private static func orderedItem(_ line: String) -> String? {
    let digits = line.prefix { $0.isNumber }
    guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
    return String(line.dropFirst(digits.count + 2))
  }

  private static func cells(_ line: String) -> [String] {
    line.split(separator: "|", omittingEmptySubsequences: false)
      .dropFirst().dropLast()
      .map { $0.trimmingCharacters(in: .whitespaces) }
  }

  private static func isSeparator(_ row: [String]) -> Bool {
    !row.isEmpty && row.allSatisfy { cell in
      !cell.isEmpty && cell.allSatisfy { ":-= ".contains($0) }
    }
  }
}

/// 把块画出来。排版节奏是这套界面里最花心思的地方：
/// 标题上方留白比下方大（让它归属下一段而不是浮在中间）、
/// 列表用 accent 色的小圆点、引用用一条 2pt 的竖线而不是整块填色。
struct MarkdownText: View {
  private let blocks: [MarkdownBlock]
  /// 流式还没结束 —— 最后一块后面跟一个光标。
  var streaming = false

  /// 对话的字号。
  ///
  /// **和正文栏的 `readerFontSize` 分开存。** 一个是论文、一个是对话，
  /// 舒适字号本来就不一样：论文要长时间读，对话是一眼扫完再往下。
  /// 这里只存一个基准，标题/表格/代码按比例跟着走 ——
  /// 各调各的会把版面的比例关系拆散，调大一次就散一次。
  @AppStorage("agentFontSize") private var base = 13.5

  init(_ text: String, streaming: Bool = false) {
    self.blocks = MarkdownParser.blocks(text, cache: !streaming)
    self.streaming = streaming
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // 按**下标**认身份，不按内容。两条 `---`、两段一样的话在同一段回答里
      // 并不罕见，内容做 id 会撞；撞了之后 SwiftUI 会丢掉其中一块，
      // 而且只在控制台留一行警告。下标在流式追加时对前面的块也是稳定的。
      ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
        MarkdownBlockView(block: block, base: base, caret: streaming && index == blocks.count - 1)
          .equatable()
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// 一块。**单独一个视图、可判等** —— 流式时每帧只有最后一块在变。
///
/// 从前整段正文是一个视图：每帧（现在是逐帧铺开，一秒六十次）都要把**每一段**的
/// 行内 Markdown 重新解析一遍（`AttributedString(markdown:)`）、再逐字和上一帧比较、
/// 再扫一遍有没有公式。实测（stream_perf.sh 长回答）这三样占了主线程忙碌时间的
/// 两成多，而其中只有最后那一段真的变了。拆成可判等的块之后，没变的块在
/// `.equatable()` 那一步就被跳过，body 都不进 —— 稳定前缀只解析一次，
/// 只重解析仍在增长的那一块。
private struct MarkdownBlockView: View, Equatable {
  let block: MarkdownBlock
  /// 对话的基准字号（由 `MarkdownText` 从偏好里读好传进来）。
  let base: Double
  /// 跟在这一块后面的流式光标。
  let caret: Bool

  var body: some View {
    switch block {
    case .heading(let level, let text):
      // 字阶用**比例**而不是一串固定值：基准字号一调，四级标题一起走。
      Text(inline(text))
        .font(.system(size: base * [0, 1.26, 1.11, 1.0, 0.96][min(level, 4)], weight: .semibold))
        .foregroundStyle(Palette.ink)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, level == 1 ? 16 : 13).padding(.bottom, 5)

    case .paragraph(let text):
      HStack(alignment: .bottom, spacing: 3) {
        prose(text, size: base)
          .lineSpacing(base * 0.37).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        if caret { StreamingCaret().padding(.bottom, 2) }
      }
      .padding(.vertical, 5)

    case .bullets(let items):
      VStack(alignment: .leading, spacing: 5) {
        ForEach(items, id: \.self) { item in
          HStack(alignment: .firstTextBaseline, spacing: 9) {
            // 用 Text 而不是 Circle：形状没有基线，放进 firstTextBaseline 的
            // HStack 里会被当成底部对齐，圆点会明显低于第一行文字
            Text("•")
              .font(.system(size: base, weight: .bold))
              .foregroundStyle(Palette.accent.opacity(0.55))
            prose(item, size: base)
              .lineSpacing(base * 0.3).textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }.padding(.vertical, 5).padding(.leading, 2)

    case .ordered(let items):
      VStack(alignment: .leading, spacing: 5) {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index + 1).")
              .font(.system(size: base - 1.5, weight: .medium, design: .monospaced))
              .foregroundStyle(Palette.accent.opacity(0.8))
              .frame(minWidth: 16, alignment: .trailing)
            prose(item, size: base)
              .lineSpacing(base * 0.3).textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }.padding(.vertical, 5)

    case .quote(let lines):
      HStack(alignment: .top, spacing: 10) {
        RoundedRectangle(cornerRadius: 1).fill(Palette.accent.opacity(0.4)).frame(width: 2)
        prose(lines.joined(separator: "\n"), size: base - 0.5, tint: Palette.inkSoft)
          .lineSpacing(base * 0.33).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }.padding(.vertical, 7)

    case .code(let language, let body):
      CodeBlock(language: language, code: body, size: base - 2).padding(.vertical, 7)

    case .table(let header, let rows):
      MarkdownTable(header: header, rows: rows, size: base - 1.5).padding(.vertical, 8)

    case .math(let latex):
      MathDisplayBlock(latex: latex)

    case .rule:
      Hairline().padding(.vertical, 11)
    }
  }

  /// 一段正文：**有公式才走公式那条路**。
  ///
  /// 论文问答里绝大多数段落一个 `$` 都没有，为它们多跑一遍公式扫描是白费。
  /// `hasMath` 只扫一遍字符，命中率低时几乎免费。
  @ViewBuilder
  private func prose(_ text: String, size: CGFloat, tint: Color = Palette.ink) -> some View {
    if MathTeX.hasMath(text) {
      MathInlineText(text: text, size: size, tint: tint)
    } else {
      Text(inline(text)).font(.system(size: size)).foregroundStyle(tint)
    }
  }

  /// 行内 Markdown。解析失败就原样显示 —— 模型偶尔吐半截语法，
  /// 那时候显示原文远好过显示一片空白。
  private func inline(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }
}

/// 代码块：右上角标语言，悬停出现复制。
private struct CodeBlock: View {
  let language: String
  /// 不能叫 body —— 会和 View 的 body 撞名
  let code: String
  var size: CGFloat = 11.5
  @State private var hovering = false
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !language.isEmpty || hovering {
        HStack {
          Text(language.isEmpty ? L("代码", "Code") : language)
            .font(.system(size: size - 2, weight: .medium, design: .monospaced))
            .foregroundStyle(Palette.inkFaint)
          Spacer()
          if hovering {
            Button {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(code, forType: .string)
              copied = true
              DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
            } label: {
              Label(copied ? L("已复制", "Copied") : L("复制", "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: size - 2)).foregroundStyle(Palette.inkFaint)
            }.buttonStyle(.plain).transition(.opacity)
          }
        }
        .padding(.horizontal, 12).padding(.top, 7).padding(.bottom, 0)
      }
      // **横向滚动容器在纵向也是贪心的。** 它会把父视图提议的高度全吃下来 ——
      // 顶层从 LazyVStack 换成 VStack 之后，父视图提议的是整个视口高度，
      // 于是一张两行的表格被拉成半屏高（实机可见）。
      // `fixedSize(vertical:)` 把纵向钉回内容自身的高度，横向仍然可滚。
      ScrollView(.horizontal, showsIndicators: false) {
        Text(code)
          .font(.system(size: size, design: .monospaced))
          .foregroundStyle(Palette.inkSoft)
          .lineSpacing(3)
          .textSelection(.enabled)
          .padding(.horizontal, 12)
          .padding(.top, language.isEmpty ? 10 : 6).padding(.bottom, 10)
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .background(Palette.sunk, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.ruleSoft))
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.14), value: hovering)
  }
}

/// 表格。论文问答里模型很爱用表格回答「对比一下这几个方法」。
///
/// **用 `Grid`，不是「一行一个 HStack」。** 后者每一行各自算列宽 —— 表头那格
/// 和它正下方那格宽度对不上，整张表是错位的（实机可见，三列的对比表最明显）。
/// Grid 是唯一能让列宽**跨行**对齐的容器。
///
/// **列数少时不横向滚动，让长句子折行。** 先前一个长句子就能把整行撑出栏宽，
/// 结果是表格横着滚、读的人第一眼只看得见左边两列，而右边栏外明明空着。
/// 折行之后它装得进栏宽里；真到了五列以上再退回横向滚动。
///
/// 样式照期刊表格：**没有竖线**，只有表头下面那条线与上下两条边线。
/// 竖线是电子表格的默认，不是论文的默认。
private struct MarkdownTable: View {
  let header: [String]
  let rows: [[String]]
  var size: CGFloat = 12

  /// 超过这个列数就认为是"宽表"，改回横向滚动 —— 六列各自折行的结果是
  /// 每格两三个字一行，那比滚动更难读。
  private static let wrapLimit = 4

  private var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }
  private var wraps: Bool { columns <= Self.wrapLimit }

  var body: some View {
    Group {
      if wraps {
        grid
      } else {
        // 横向滚动容器纵向贪心，不钉住就会被拉长。
        ScrollView(.horizontal, showsIndicators: false) { grid }
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var grid: some View {
    Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
      GridRow {
        ForEach(0..<columns, id: \.self) { cell(header, $0, isHeader: true) }
      }
      // 直接放在 Grid 里（不在 GridRow 内）的视图横跨整行；
      // `gridCellUnsizedAxes` 让分隔线不要用自己的"无限宽"去参与列宽计算。
      Divider().overlay(Palette.rule).gridCellUnsizedAxes(.horizontal)
      ForEach(Array(rows.enumerated()), id: \.offset) { offset, cells in
        if offset > 0 {
          Divider().overlay(Palette.ruleSoft).gridCellUnsizedAxes(.horizontal)
        }
        GridRow {
          ForEach(0..<columns, id: \.self) { cell(cells, $0, isHeader: false) }
        }
      }
    }
    .padding(.vertical, 3)
    .overlay(alignment: .top) { Hairline() }
    .overlay(alignment: .bottom) { Hairline() }
  }

  private func cell(_ cells: [String], _ index: Int, isHeader: Bool) -> some View {
    Text(index < cells.count ? cells[index] : "")
      .font(.system(size: isHeader ? size - 0.5 : size, weight: isHeader ? .semibold : .regular))
      .foregroundStyle(isHeader ? Palette.inkSoft : Palette.ink)
      .lineSpacing(2.5)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .frame(minWidth: 52, maxWidth: wraps ? .infinity : 230, alignment: .topLeading)
      .padding(.horizontal, 11).padding(.vertical, 7)
  }
}
