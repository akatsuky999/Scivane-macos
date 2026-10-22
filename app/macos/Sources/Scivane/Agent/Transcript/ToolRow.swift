import SwiftUI

// MARK: - Outcome

/// How a call ended, as the process line counts it and its row colours it. The abnormal outcomes
/// must be told apart at a glance:
/// - failed: it ran and errored; the model usually retries
/// - blocked: the sandbox stopped it; the boundary working, not a fault
/// - denied: the user's decision, not an error
/// - skipped: never ran; a synthetic result after a stop
enum ToolOutcome: Equatable {
  case running, ok, failed, blocked, denied, skipped

  var alert: ProcessSummary.Alert? {
    switch self {
    case .running, .ok: return nil
    case .failed: return .failed
    case .blocked: return .blocked
    case .denied: return .denied
    case .skipped: return .skipped
    }
  }

  var label: String? {
    switch self {
    case .running, .ok: return nil
    case .failed: return L("失败", "Failed")
    case .blocked: return L("被拦", "Blocked")
    case .denied: return L("已拒绝", "Denied")
    case .skipped: return L("未执行", "Not run")
    }
  }

  var tint: Color { alert?.tint ?? Palette.inkFaint }
}

extension TranscriptItem {
  var outcome: ToolOutcome {
    if awaitingResult { return .running }
    if synthetic { return .skipped }
    if let decision, !decision.approved { return .denied }
    if preview.contains("TOOL_DENIED_BY_USER") { return .denied }
    // 不翻: matches tool results, which are always Chinese for the model
    if isError { return preview.contains("沙箱") ? .blocked : .failed }
    return .ok
  }
}

// MARK: - Tool row

/// One call in an opened process line: a verb and what it acted on, then its result when clicked.
struct ToolRow: View {
  let item: TranscriptItem
  /// the process line's type size
  var size: CGFloat = 12.5
  /// The stretch changed several files, so a write names its file as well as its section.
  var namesFile = false
  @State private var expanded = false
  @State private var hovering = false
  @State private var showHosts = false
  @State private var showEnforcement = false

  /// startExpanded is for offscreen checks, which can't click. Seeding the State keeps it collapsible.
  init(item: TranscriptItem, size: CGFloat = 12.5, namesFile: Bool = false, startExpanded: Bool = false) {
    self.item = item
    self.size = size
    self.namesFile = namesFile
    _expanded = State(initialValue: startExpanded)
  }

  /// The verb, in the past; empty when the backend's summary says it all.
  var verb: String {
    switch item.toolName {
    case "read": return L("读取", "Read")
    case "grep": return L("搜索", "Searched")
    case "glob": return L("列出", "Listed")
    case "write": return L("写入", "Wrote")
    case "edit": return L("编辑", "Edited")
    case "bash", "python": return L("运行", "Ran")
    case "cite": return L("核对原文", "Checked the original")
    case "fetch_repo": return L("取回", "Fetched")
    default: return ""
    }
  }

  /// What the call acted on. A long document written in pieces names the section each piece wrote.
  var object: String {
    let subject = item.subject
    switch item.toolName {
    case "read": return subject.path
    case "grep", "glob", "fetch_repo": return subject.query
    case "cite": return "「\(subject.query)」"
    case "write", "edit":
      guard !subject.heading.isEmpty else { return subject.path }
      return namesFile ? "\(subject.fileName) · \(subject.heading)" : subject.heading
    case "bash": return subject.label.isEmpty ? L("一条命令", "a command") : subject.label
    case "python": return subject.label.isEmpty ? "Python" : subject.label
    default: return item.summary
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      if expanded { detail }
    }
    .background(expanded ? Palette.ink.opacity(0.025) : .clear)
  }

  private var header: some View {
    let outcome = item.outcome
    return Button {
      withAnimation(.easeOut(duration: 0.14)) { expanded.toggle() }
    } label: {
      HStack(spacing: 6) {
        if outcome == .running {
          ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 12, height: 12)
          ShimmerText(text: ProcessSummary.doing(item), size: size - 0.5, weight: .regular)
        } else {
          if !verb.isEmpty {
            Text(verb).foregroundStyle(outcome == .ok ? Palette.inkFaint : outcome.tint)
          }
          Text(object.isEmpty ? item.toolName : object)
            .foregroundStyle(outcome == .ok ? Palette.inkSoft : outcome.tint)
            .lineLimit(1).truncationMode(.middle)
        }
        Spacer(minLength: 6)
        if let label = outcome.label {
          Text(label)
            .font(.system(size: size - 3, weight: .medium)).foregroundStyle(outcome.tint)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(outcome.tint.opacity(0.12), in: Capsule())
        }
        if item.enforcement != nil { enforcementChip }
        // Hosts show without opening; otherwise where the agent went would only be in the audit log.
        if !item.hosts.isEmpty || !item.blockedHosts.isEmpty { hostsChip }
        if let diff = item.diff, diff.added + diff.removed > 0 {
          DiffBadge(added: diff.added, removed: diff.removed, size: size - 2)
        }
        Image(systemName: "chevron.right")
          .font(.system(size: size * 0.55, weight: .semibold))
          .rotationEffect(.degrees(expanded ? 90 : 0))
          .foregroundStyle(Palette.inkFaint.opacity(hovering || expanded ? 0.9 : 0))
      }
      .font(.system(size: size - 0.5))
      .padding(.horizontal, 12)
      .frame(minHeight: 30)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(item.subject.path.isEmpty ? item.summary : item.subject.path)
  }

  /// Hosts this call reached, host names only. Allowed ones are neutral (networking is normal);
  /// refused ones are highlighted.
  private var hostsChip: some View {
    Button { showHosts.toggle() } label: {
      HStack(spacing: 3) {
        Image(systemName: item.blockedHosts.isEmpty ? "globe" : "globe.badge.chevron.backward")
          .font(.system(size: 9))
        Text(hostsSummary).font(.system(size: 9.5, weight: .medium))
      }
      .foregroundStyle(item.blockedHosts.isEmpty ? Color.secondary : Palette.caution)
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(
        (item.blockedHosts.isEmpty ? Color.secondary : Color.orange).opacity(0.12),
        in: Capsule())
    }
    .buttonStyle(.plain)
    .popover(isPresented: $showHosts, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 6) {
        if !item.hosts.isEmpty {
          Text(L("这次调用访问过", "Reached by this call")).font(.system(size: 10, weight: .semibold))
          ForEach(item.hosts, id: \.self) { host in
            Text(host).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
          }
        }
        if !item.blockedHosts.isEmpty {
          Text(L("被拦下", "Blocked")).font(.system(size: 10, weight: .semibold)).padding(.top, 2)
          ForEach(item.blockedHosts, id: \.host) { blocked in
            Text(L("\(blocked.host) —— \(blocked.reason)", "\(blocked.host) — \(blocked.reason)"))
              .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
          }
        }
        Text(L("只记录主机与端口，不记录路径。", "Only hosts and ports are recorded, never paths."))
          .font(.system(size: 9.5)).foregroundStyle(.secondary).padding(.top, 2)
      }
      .padding(10).frame(maxWidth: 320, alignment: .leading)
    }
  }

  /// Being blocked must be in the text, not only the colour.
  private var hostsSummary: String {
    let blocked = item.blockedHosts.count
    if blocked > 0 {
      return item.hosts.isEmpty
        ? L("拦下 \(blocked)", "\(blocked) blocked")
        : L("\(item.hosts.count) 个主机 · 拦下 \(blocked)",
            "\(plural(item.hosts.count, "host", "hosts")) · \(blocked) blocked")
    }
    if item.hosts.count == 1 { return item.hosts[0] }
    return L("\(item.hosts.count) 个主机", plural(item.hosts.count, "host", "hosts"))
  }

  /// Partial enforcement, with the reason when opened.
  private var enforcementChip: some View {
    Button { showEnforcement.toggle() } label: {
      HStack(spacing: 3) {
        Image(systemName: "exclamationmark.shield").font(.system(size: 9))
        Text(L("沙箱 \(item.enforcement ?? "")", "Sandbox \(item.enforcement ?? "")"))
          .font(.system(size: 9.5, weight: .medium))
      }
      .foregroundStyle(Palette.caution)
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(Color.orange.opacity(0.13), in: Capsule())
    }
    .buttonStyle(.plain)
    .popover(isPresented: $showEnforcement, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 7) {
        Text(L("这次约束没有完全兑现", "The sandbox wasn't fully enforced this time"))
          .font(.system(size: 12, weight: .semibold))
        Text(item.enforcementReason.isEmpty ? L("后端没有给出原因。", "The backend gave no reason.") : item.enforcementReason)
          .font(.system(size: 11.5)).foregroundStyle(Palette.inkSoft)
          .fixedSize(horizontal: false, vertical: true)
        Text(L("边界保证打了折扣，涉及安全判断请自己复核",
               "The boundary guarantee is weaker; double-check anything security-related yourself"))
          .font(.system(size: 10.5)).foregroundStyle(Palette.inkFaint)
          .fixedSize(horizontal: false, vertical: true)
      }.padding(14).frame(width: 300)
    }
  }

  @ViewBuilder
  private var detail: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let decision = item.decision {
        Label(
          decision.timedOut
            ? L("等待超时，按拒绝处理", "Timed out — treated as a denial")
            : (decision.approved ? L("你允许了这次操作", "You allowed this")
               : L("你拒绝了这次操作", "You denied this")
              + (decision.reason.isEmpty ? "" : L("：", ": ") + decision.reason)),
          systemImage: decision.approved ? "checkmark.circle" : "hand.raised")
          .font(.system(size: 11)).foregroundStyle(Palette.inkFaint)
      }
      // a diff is the result; the backend's confirmation line is for the model
      if let diff = item.diff, !diff.rows.isEmpty {
        DiffView(diff: diff)
      } else if item.diff == nil {
        if item.preview.isEmpty {
          Text(item.awaitingResult ? L("还在跑…", "Still running…") : L("（没有输出）", "(no output)"))
            .font(.system(size: 11)).foregroundStyle(Palette.inkFaint)
        } else {
          ScrollView(.vertical) {
            Text(item.preview)
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(item.isError ? Palette.danger : Palette.inkSoft)
              .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }.frame(maxHeight: 220)
        }
      }
      if item.truncated {
        Text(L("已截断，全文在 workbench/tool-results/", "Truncated; the full output is in workbench/tool-results/"))
          .font(.system(size: 10)).foregroundStyle(Palette.inkFaint)
      }
    }
    .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 10)
  }
}

// MARK: - Diff

/// Line-by-line view of one change.
/// - Line numbers follow the change: removed lines have only the old number, added lines only
///   the new one, so they match the editor.
/// - Very light washes: the colours are for scanning, the code must stay readable.
/// - Monospaced and truncated rather than wrapped: wrapping would break the indentation.
private struct DiffView: View {
  let diff: AgentClient.FileDiff

  /// The backend already caps at DIFF_MAX_LINES (400); the row is an index, not the record.
  static let visibleRows = 24

  private func tint(_ kind: String) -> Color {
    switch kind {
    case "add": return Palette.added
    case "remove": return Palette.removed
    default: return Palette.inkFaint
    }
  }

  private func wash(_ kind: String) -> Color {
    switch kind {
    case "add": return Palette.addedWash
    case "remove": return Palette.removedWash
    default: return .clear
    }
  }

  private func sign(_ kind: String) -> String {
    switch kind {
    case "add": return "+"
    case "remove": return "−"
    default: return " "
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      // No nested ScrollView: inside the transcript's scroll view they fight over scrolling. Draw the
      // first rows and report the rest; the file is the authority.
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(diff.rows.prefix(Self.visibleRows).enumerated()), id: \.offset) { _, row in
          if row.kind == "gap" {
            Text(row.skipped.map { L("… 略过 \($0) 行", "… \(plural($0, "line", "lines")) skipped") } ?? row.text)
              .font(.system(size: 9.5)).foregroundStyle(Palette.inkFaint)
              .padding(.vertical, 2).padding(.leading, 66)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            HStack(spacing: 0) {
              Text(row.oldNo.map(String.init) ?? "")
                .frame(width: 26, alignment: .trailing)
              Text(row.newNo.map(String.init) ?? "")
                .frame(width: 26, alignment: .trailing)
              Text(sign(row.kind))
                .frame(width: 14, alignment: .center)
                .foregroundStyle(tint(row.kind))
              Text(row.text.isEmpty ? " " : row.text)
                .foregroundStyle(row.kind == "same" ? Palette.inkSoft : Palette.ink)
                .lineLimit(1).truncationMode(.tail)
                .textSelection(.enabled)
              Spacer(minLength: 4)
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(Palette.inkFaint)
            .padding(.vertical, 1.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(wash(row.kind))
          }
        }
      }

      if diff.rows.count > Self.visibleRows || diff.truncated {
        Text(
          diff.truncated
            ? L("改动太长，这里只列了开头 —— 完整内容在文件里",
                "The change is long; only the start is shown here — the full change is in the file")
            : L("还有 \(diff.rows.count - Self.visibleRows) 行改动，完整内容在文件里",
                "\(plural(diff.rows.count - Self.visibleRows, "more changed line", "more changed lines")); "
                  + "the full change is in the file"))
          .font(.system(size: 10)).foregroundStyle(Palette.inkFaint)
      }
    }
    .padding(.vertical, 7)
    .background(Palette.paper.opacity(0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.ruleSoft))
  }
}
