import SwiftUI

// The empty conversation: the paper itself, then a few ways in. A way in puts a whole instruction in
// the composer to read, change and send; nothing is sent from here.

/// A way into a new conversation: a short title and note on screen, and the instruction it fills in.
/// Built on every access, so it follows a language switch.
struct Starter: Identifiable {
  let title: String
  let note: String
  let prompt: String
  /// Part of the prompt selected once it is in the composer, for the user to type over.
  var blank: String? = nil

  var id: String { title }

  static var paper: [Starter] {
    let language = L("[目标语言]", "[target language]")
    return [
      Starter(
        title: L("全文翻译", "Translate the paper"),
        note: L("译成你指定的语言，版式与图片照原文，存进笔记",
                "Into the language you choose, layout and figures kept, saved as a note"),
        prompt: L(
          """
          通读本论文的 Markdown 正文，完整译成\(language)，存入 notes/。
          1. 忠实保留全部内容、学术含义与技术细节；作者姓名不译；行文自然准确，避免直译腔，术语前后统一。
          2. 只读现有的 Markdown 正文，不重读 PDF、不重新识别；明显的识别错误、公式与排版问题按上下文修正，不得编造。
          3. 保留原文的全部图片，按 notes/ 的位置改写图片路径，确保译稿里正常显示。
          """,
          """
          Read this paper's Markdown text in full and translate all of it into \(language), saving it in notes/.
          1. Keep all of the content, its academic meaning and technical detail; leave author names untranslated; write natural, accurate academic prose without literal-translation stiffness, with consistent terminology.
          2. Work only from the existing Markdown text: don't reread the PDF or run recognition again. Fix obvious recognition errors and broken formulas or layout from context; never invent content.
          3. Keep every figure from the original, rewriting image paths for the note's place in notes/ so they display in the translation.
          """),
        blank: language),
      Starter(
        title: L("作者提出的挑战", "The challenges it takes on"),
        note: L("要解决的难题、难在哪、论文如何回应", "What is hard, why, and how the paper answers"),
        prompt: L(
          "总结作者在这篇论文中指出的关键挑战：每个挑战具体是什么、为什么难，论文又是如何应对的；引用时标出原文出处。",
          "Summarize the key challenges the authors identify in this paper: what each one is, why it is hard, "
            + "and how the paper addresses it. Cite where in the paper each point comes from.")),
      Starter(
        title: L("研究脉络与不足", "Lineage and gaps"),
        note: L("从相关工作梳理这一方向，指出现有研究的空白", "Trace the field from Related Work and name its gaps"),
        prompt: L(
          "以「相关工作」一节为起点，梳理这篇论文所在细分方向的研究脉络（按技术路线或时间分组），总结现有研究的主要不足，并说明本文针对的是哪一点。",
          "Starting from the Related Work section, trace how this paper's subfield has developed (grouped by "
            + "approach or over time), summarize the main gaps in existing work, and say which of them this paper targets.")),
    ]
  }

  /// The librarian reads no paper, so its ways in are about the list.
  static var library: [Starter] {
    [L("我都有哪些论文", "What papers do I have?"),
     L("找一篇讲对比学习的", "Find one about contrastive learning"),
     L("这些项目里哪些还没有正文", "Which of these projects have no text yet?")]
      .map { Starter(title: $0, note: "", prompt: $0) }
  }
}

/// A project's empty conversation: which paper this is, then its ways in.
struct PaperWelcome: View {
  let project: Project
  let use: (Starter) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(L("这篇论文", "This paper"))
        .font(.system(size: 11.5)).tracking(0.4).foregroundStyle(Palette.inkSoft)
      Text(project.displayTitle)
        .font(.system(size: 26, design: .serif)).foregroundStyle(Palette.ink)
        .lineSpacing(3).lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 12)
      if let context = project.context {
        Text("\(context.kindLabel) · \(context.sizeLabel)")
          .font(.system(size: 12)).foregroundStyle(Palette.inkFaint)
          .padding(.top, 8)
      }
      StarterLedger(starters: Starter.paper, use: use).padding(.top, 40)
    }
    .frame(maxWidth: 540, alignment: .leading)
  }
}

/// Ways in as lines of a contents page: a serif title, its note beside it, hairlines between. The
/// notes line up on the widest title; where a line doesn't fit, the note goes under its title.
struct StarterLedger: View {
  let starters: [Starter]
  let use: (Starter) -> Void
  @State private var titleWidth: CGFloat = 0

  var body: some View {
    VStack(spacing: 0) {
      ForEach(starters) { starter in
        Hairline()
        StarterLine(starter: starter, titleWidth: titleWidth) { use(starter) }
      }
      Hairline()
    }
    .onPreferenceChange(StarterTitleWidth.self) { titleWidth = $0 }
  }
}

private struct StarterTitleWidth: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct StarterLine: View {
  let starter: Starter
  let titleWidth: CGFloat
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
          title.frame(minWidth: titleWidth, alignment: .leading)
          if !starter.note.isEmpty { note.lineLimit(1) }
          Spacer(minLength: 8)
          arrow
        }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          VStack(alignment: .leading, spacing: 4) {
            title
            if !starter.note.isEmpty { note.fixedSize(horizontal: false, vertical: true) }
          }
          Spacer(minLength: 8)
          arrow
        }
      }
      .padding(.vertical, 15)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.14), value: hovering)
    // the whole instruction it fills in, before choosing it
    .help(starter.prompt)
    .accessibilityLabel(starter.title)
    .accessibilityHint(starter.note)
  }

  private var title: some View {
    Text(starter.title)
      .font(.system(size: 17, design: .serif))
      .foregroundStyle(hovering ? Palette.accent : Palette.ink)
      .fixedSize()
      .background(GeometryReader { Color.clear.preference(key: StarterTitleWidth.self, value: $0.size.width) })
  }

  private var note: some View {
    Text(starter.note).font(.system(size: 12.5)).foregroundStyle(Palette.inkFaint)
  }

  private var arrow: some View {
    Image(systemName: "arrow.right")
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(Palette.accent)
      .opacity(hovering ? 1 : 0)
  }
}
