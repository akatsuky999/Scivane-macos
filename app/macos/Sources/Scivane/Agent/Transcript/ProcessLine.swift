import SwiftUI

// MARK: - Process line

/// A stretch of the agent's work between two things it said, read as one quiet line: "Read
/// context.md, searched twice, wrote notes.md 11 times +401 −369 ›". Opened, a list with one row per
/// call, each opening onto its result. While the stretch is still going, the line is the turn's live
/// status instead.
///
/// Process is set apart from what the agent says by type alone: a smaller, grey line in which file
/// names are the only dark words, and nothing boxed until it is opened. Reasoning is never shown;
/// what the agent did is.
struct ProcessLine: View {
  /// the stretch's tool calls, in order
  let calls: [TranscriptItem]
  /// Owned by the parent per row id: the line is rebuilt on every chunk while running and @State
  /// would close it again right after it was opened. nil falls back to local state (offscreen
  /// checks).
  var expansion: Binding<Bool>? = nil
  /// The turn is in this stretch now: the line says what is happening instead of what was done.
  var live: LiveStatus? = nil
  @State private var localExpanded = false
  @State private var hovering = false
  /// follows the conversation's type size, a step below the answer
  @AppStorage(TypeScale.chat.sizeKey) private var base = TypeScale.chat.standardSize

  private var expanded: Bool { expansion?.wrappedValue ?? localExpanded }
  private func toggle() {
    if let expansion { expansion.wrappedValue.toggle() } else { localExpanded.toggle() }
  }

  /// Status text sits a point under the answer's size; it scales with the conversation's type size.
  static func size(for base: CGFloat) -> CGFloat { TypeScale.chat.clamp(base) - 1 }

  var body: some View {
    // computed on every render, never stored: it reads the UI language
    let summary = ProcessSummary(calls: calls)
    let size = Self.size(for: base)
    VStack(alignment: .leading, spacing: 6) {
      Button(action: toggle) {
        HStack(spacing: 6) {
          if let live {
            live
          } else if let waiting = calls.last(where: \.awaitingResult) {
            // still waiting (for an approval, say) while the status line gives way: not done yet
            Text(ProcessSummary.doing(waiting))
              .lineLimit(1).truncationMode(.tail)
          } else {
            Text(summary.sentence)
              .lineLimit(1).truncationMode(.tail)
            if summary.added > 0 || summary.removed > 0 {
              DiffBadge(added: summary.added, removed: summary.removed, size: size - 1.5)
            }
          }
          Image(systemName: "chevron.right")
            .font(.system(size: size * 0.6, weight: .semibold))
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .opacity(hovering || expanded ? 0.9 : 0.45)
          Spacer(minLength: 0)
        }
        .font(.system(size: size))
        .foregroundStyle(hovering || expanded ? Palette.inkSoft : Palette.inkFaint)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .onHover { hovering = $0 }
      .help(summary.text)
      .accessibilityLabel(live?.action ?? summary.text)
      .accessibilityValue(expanded ? L("已展开", "Expanded") : L("已收起", "Collapsed"))
      .accessibilityHint(L("显示每一步", "Shows each step"))

      if expanded { list(size: size) }
    }
  }

  /// One row per call. Lazy: a long stretch holds hundreds of calls, and a running one changes on
  /// every chunk.
  private func list(size: CGFloat) -> some View {
    // file names go into each row only when the stretch changed more than one file
    let files = Set(calls.filter { $0.toolName == "write" || $0.toolName == "edit" }.map(\.subject.path))
    return LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(Array(calls.enumerated()), id: \.element.id) { index, call in
        if index > 0 { Hairline() }
        ToolRow(item: call, size: size, namesFile: files.count > 1)
      }
    }
    .background(Palette.sunk.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.ruleSoft))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

// MARK: - The sentence

/// The collapsed line of a stretch: what was done, in the order first done, with files named and the
/// changed lines added up. Anything that went wrong stays in the sentence; hidden in the fold, a
/// failure reads as success. One pass over the calls, built on every render of a running stretch.
struct ProcessSummary {
  enum Alert: Hashable {
    case failed, blocked, denied, skipped, partial

    var tint: Color {
      switch self {
      case .failed: return Palette.danger
      case .blocked, .partial: return Palette.caution
      case .denied, .skipped: return Palette.inkSoft
      }
    }
  }

  /// Names are files and repositories, the only dark words in the line.
  enum Piece: Equatable {
    case plain(String)
    case name(String)
    case alert(String, Alert)

    var string: String {
      switch self {
      case .plain(let text), .name(let text), .alert(let text, _): return text
      }
    }
  }

  private(set) var pieces: [Piece] = []
  private(set) var added = 0
  private(set) var removed = 0

  var text: String { pieces.map(\.string).joined() }

  var sentence: AttributedString {
    var out = AttributedString()
    for piece in pieces {
      var run = AttributedString(piece.string)
      switch piece {
      case .plain: break
      case .name: run.foregroundColor = Palette.ink
      case .alert(_, let alert): run.foregroundColor = alert.tint
      }
      out += run
    }
    return out
  }

  /// What a call does, grouped the way the sentence counts it.
  private enum Kind: Equatable {
    case read, search, command, change, plan, cite, marks, fetch, ocr
    case library(String)
    case other(String)

    init(tool: String) {
      switch tool {
      case "read": self = .read
      case "grep", "glob": self = .search
      case "bash", "python": self = .command
      case "write", "edit": self = .change
      case "plan": self = .plan
      case "cite": self = .cite
      case "annotations": self = .marks
      case "fetch_repo": self = .fetch
      case "reocr": self = .ocr
      case "list_projects", "find_project", "open_project", "delete_project": self = .library(tool)
      default: self = .other(tool)
      }
    }
  }

  init(calls: [TranscriptItem]) {
    var kinds: [Kind] = []
    var read: [String] = []
    var searches = 0
    var commands: [TranscriptItem] = []
    /// path -> calls on it, and whether any wrote rather than edited
    var changed: [(path: String, count: Int, wrote: Bool)] = []
    var plan = ToolSubject()
    var checks = 0
    var repositories: [String] = []
    var counts: [Alert: Int] = [:]

    for call in calls where call.kind == .tool {
      let kind = Kind(tool: call.toolName)
      if !kinds.contains(kind) { kinds.append(kind) }
      let subject = call.subject
      switch kind {
      case .read:
        let name = subject.fileName.isEmpty ? call.summary : subject.fileName
        if !read.contains(name) { read.append(name) }
      case .search: searches += 1
      case .command: commands.append(call)
      case .change:
        if let at = changed.firstIndex(where: { $0.path == subject.path }) {
          changed[at].count += 1
          changed[at].wrote = changed[at].wrote || call.toolName == "write"
        } else {
          changed.append((subject.path, 1, call.toolName == "write"))
        }
      case .plan: plan = subject
      case .cite: checks += 1
      case .fetch:
        if !repositories.contains(subject.repository) { repositories.append(subject.repository) }
      case .marks, .ocr, .library, .other: break
      }
      if let alert = call.outcome.alert { counts[alert, default: 0] += 1 }
      if call.enforcement != nil { counts[.partial, default: 0] += 1 }
      if let diff = call.diff {
        added += diff.added
        removed += diff.removed
      }
    }

    let and = L("、", " and ")
    var phrases: [[Piece]] = []
    for kind in kinds {
      switch kind {
      case .read:
        phrases.append(Self.naming(read, verb: L("读取 ", "read "), count: L("读取 \(read.count) 个文件", "read \(read.count) files"), and: and))
      case .search:
        phrases.append([.plain(L("搜索 \(searches) 次", searches == 1 ? "searched once" : "searched \(searches) times"))])
      case .command:
        let label = commands.count == 1 ? commands[0].subject.label : ""
        phrases.append([.plain(!label.isEmpty ? label
          : L("运行 \(commands.count) 条命令", commands.count == 1 ? "ran a command" : "ran \(commands.count) commands"))])
      case .change:
        let verb = changed.allSatisfy { !$0.wrote } ? L("编辑 ", "edited ") : L("写入 ", "wrote ")
        if changed.count == 1, changed[0].count > 1 {
          let times = changed[0].count
          phrases.append([.plain(verb), .name(Self.fileName(changed[0].path)), .plain(L(" \(times) 次", " \(times) times"))])
        } else {
          phrases.append(Self.naming(changed.map { Self.fileName($0.path) }, verb: verb,
                                     count: L("改动 \(changed.count) 个文件", "changed \(changed.count) files"), and: and))
        }
      case .plan:
        phrases.append([.plain(plan.total > 0 ? L("计划 \(plan.done)/\(plan.total)", "plan \(plan.done)/\(plan.total)") : L("计划", "planned"))])
      case .cite:
        phrases.append([.plain(L("核对原文 \(checks) 处", checks == 1 ? "checked the original" : "checked the original \(checks) times"))])
      case .marks:
        phrases.append([.plain(L("查看标注", "read your marks"))])
      case .fetch:
        phrases.append(Self.naming(repositories, verb: L("取回 ", "fetched "),
                                   count: L("取回 \(repositories.count) 个仓库", "fetched \(repositories.count) repositories"), and: and))
      case .ocr:
        phrases.append([.plain(L("重新识别", "re-ran OCR"))])
      case .library(let tool):
        phrases.append([.plain(Self.library(tool, doing: false))])
      case .other(let tool):
        phrases.append([.plain(tool)])
      }
    }

    let comma = L("，", ", ")
    for (index, phrase) in phrases.enumerated() {
      if index > 0 { pieces.append(.plain(comma)) }
      pieces.append(contentsOf: phrase)
    }
    for alert in [Alert.failed, .blocked, .denied, .skipped, .partial] {
      guard let count = counts[alert], count > 0 else { continue }
      if !pieces.isEmpty { pieces.append(.plain(comma)) }
      pieces.append(.alert(Self.wording(alert, count), alert))
    }
    // English starts with a capital; Chinese has none
    if case .plain(let first)? = pieces.first, let letter = first.first, letter.isLowercase {
      pieces[0] = .plain(letter.uppercased() + first.dropFirst())
    }
  }

  /// One name, two joined, or a count past that: a line that lists five files says nothing.
  private static func naming(_ names: [String], verb: String, count: String, and: String) -> [Piece] {
    switch names.count {
    case 0: return []
    case 1: return [.plain(verb), .name(names[0])]
    case 2: return [.plain(verb), .name(names[0]), .plain(and), .name(names[1])]
    default: return [.plain(count)]
    }
  }

  private static func fileName(_ path: String) -> String { (path as NSString).lastPathComponent }

  private static func wording(_ alert: Alert, _ count: Int) -> String {
    switch alert {
    case .failed: return L("\(count) 次失败", "\(count) failed")
    case .blocked: return L("\(count) 次被拦", "\(count) blocked")
    case .denied: return L("\(count) 次被拒绝", "\(count) denied")
    case .skipped: return L("\(count) 次未执行", "\(count) not run")
    case .partial: return L("沙箱 partial", "sandbox partial")
    }
  }

  private static func library(_ tool: String, doing: Bool) -> String {
    switch tool {
    case "open_project": return doing ? L("正在打开论文", "Opening a paper") : L("打开论文", "opened a paper")
    case "delete_project": return doing ? L("正在删除论文", "Deleting a paper") : L("删除论文", "deleted a paper")
    default: return doing ? L("正在查看论文清单", "Looking through the papers") : L("查看论文清单", "looked through the papers")
    }
  }

  /// The call in progress, as the live line says it.
  static func doing(_ call: TranscriptItem) -> String {
    let subject = call.subject
    let name = subject.fileName.isEmpty ? call.summary : subject.fileName
    switch call.toolName {
    case "read": return L("正在读取 \(name)", "Reading \(name)")
    case "grep": return L("正在搜索 \(subject.query)", "Searching \(subject.query)")
    case "glob": return L("正在列出 \(subject.query)", "Listing \(subject.query)")
    case "write": return L("正在写入 \(name)", "Writing \(name)")
    case "edit": return L("正在编辑 \(name)", "Editing \(name)")
    case "bash", "python":
      // the description is the model's own words, usually a verb phrase
      if !subject.label.isEmpty { return L("正在\(subject.label)", subject.label) }
      return call.toolName == "bash" ? L("正在运行命令", "Running a command") : L("正在运行 Python", "Running Python")
    case "plan": return L("正在更新计划", "Updating the plan")
    case "cite": return L("正在核对原文", "Checking the original")
    case "annotations": return L("正在查看标注", "Reading your marks")
    case "fetch_repo": return L("正在取回 \(subject.repository)", "Fetching \(subject.repository)")
    case "reocr": return L("正在重新识别", "Re-running OCR")
    case "list_projects", "find_project", "open_project", "delete_project": return library(call.toolName, doing: true)
    default: return L("正在运行 \(call.toolName)", "Running \(call.toolName)")
    }
  }
}

// MARK: - Diff badge

/// "+401 −369" on light washes: the size of a change, readable without opening it.
struct DiffBadge: View {
  let added: Int
  let removed: Int
  var size: CGFloat = 11

  var body: some View {
    HStack(spacing: 0) {
      if added > 0 || removed == 0 { part("+\(added.formatted())", Palette.added, Palette.addedWash) }
      if removed > 0 { part("−\(removed.formatted())", Palette.removed, Palette.removedWash) }
    }
    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(L("新增 \(added) 行，删除 \(removed) 行", "\(added) lines added, \(removed) removed"))
  }

  private func part(_ text: String, _ tint: Color, _ wash: Color) -> some View {
    Text(text)
      .font(.system(size: size, weight: .medium, design: .monospaced))
      .foregroundStyle(tint)
      .padding(.horizontal, 5).padding(.vertical, 1)
      .background(wash)
  }
}
