import SwiftUI

// A tool call card, with the file diff (DiffView) inside.

// MARK: - Tool card

/// One tool call: one line collapsed, everything when expanded. The abnormal states must be
/// distinguishable at a glance:
/// - failed: red icon; it ran and errored, the model usually retries
/// - blocked by the sandbox: amber; the boundary working, not a fault
/// - refused: grey hand; the user's decision, not an error
/// - not run: dashed border; a synthetic result after a cancel
struct ToolCard: View {
  let item: TranscriptItem
  /// inside a group the outer decoration goes; the group is already the container
  var dense = false
  @State private var expanded = false
  @State private var hovering = false
  @State private var showHosts = false
  @State private var showEnforcement = false

  /// startExpanded is for offscreen checks, which can't click. Seeding the State keeps it collapsible.
  init(item: TranscriptItem, dense: Bool = false, startExpanded: Bool = false) {
    self.item = item
    self.dense = dense
    _expanded = State(initialValue: startExpanded)
  }

  private var tone: Tone {
    if item.awaitingResult { return .running }
    if item.synthetic { return .skipped }
    if let decision = item.decision, !decision.approved { return .denied }
    if item.preview.contains("TOOL_DENIED_BY_USER") { return .denied }
    // 不翻: matches tool results, which are always Chinese for the model
    if item.isError { return item.preview.contains("沙箱") ? .blocked : .failed }
    return .ok
  }

  private enum Tone {
    case running, ok, failed, blocked, denied, skipped
    var tint: Color {
      switch self {
      case .running: return Palette.inkFaint
      case .ok: return Palette.accent
      case .failed: return Palette.danger
      case .blocked: return Color(light: Color(red: 0.72, green: 0.48, blue: 0.13),
                                  dark: Color(red: 0.93, green: 0.75, blue: 0.42))
      case .denied, .skipped: return Palette.inkFaint
      }
    }
    var label: String? {
      switch self {
      case .running: return nil
      case .ok: return nil
      case .failed: return L("失败", "Failed")
      case .blocked: return L("被拦", "Blocked")
      case .denied: return L("已拒绝", "Denied")
      case .skipped: return L("未执行", "Not run")
      }
    }
    var dashed: Bool { self == .skipped }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      if expanded { detail }
    }
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(
          // a darker inset so grouped rows have visible edges
          dense
            ? (tone == .failed ? Palette.danger.opacity(0.07) : Palette.ink.opacity(0.045))
            : (tone == .failed ? Palette.danger.opacity(0.06) : Palette.sunk.opacity(0.75))))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(
          dense && tone != .failed && !tone.dashed
            ? Palette.ruleSoft.opacity(0.5)
            : (tone == .failed ? Palette.danger.opacity(0.28) : Palette.ruleSoft),
          style: StrokeStyle(lineWidth: 1, dash: tone.dashed ? [3, 3] : []))
    )
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.16), value: expanded)
  }

  private var header: some View {
    Button {
      withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
    } label: {
      HStack(spacing: 8) {
        Group {
          if item.awaitingResult {
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 13, height: 13)
          } else {
            Image(systemName: Self.icon(tone: tone, tool: item.toolName))
              .font(.system(size: 11)).foregroundStyle(tone.tint)
          }
        }.frame(width: 14)

        Text(item.toolName)
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundStyle(Palette.inkSoft)

        // skip a summary equal to the tool name (old logs lack summaries: "bash bash")
        if item.summary != item.toolName, !item.summary.isEmpty {
          if item.awaitingResult {
            // the running card's summary shimmers
            ShimmerText(text: item.summary, size: 11, weight: .regular)
          } else {
            Text(item.summary)
              .font(.system(size: 11)).foregroundStyle(Palette.inkFaint)
              .lineLimit(1).truncationMode(.middle)
          }
        }

        Spacer(minLength: 6)

        if let label = tone.label {
          Text(label)
            .font(.system(size: 9.5, weight: .medium)).foregroundStyle(tone.tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tone.tint.opacity(0.12), in: Capsule())
        }
        if item.enforcement != nil {
          enforcementChip
        }
        // Hosts show in the collapsed line; otherwise where the agent went would only be in the audit log.
        if !item.hosts.isEmpty || !item.blockedHosts.isEmpty {
          hostsChip
        }
        // the size of a change stays visible when collapsed
        if let diff = item.diff, diff.added + diff.removed > 0 {
          Text("+\(diff.added)")
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .foregroundStyle(Palette.added)
          Text("−\(diff.removed)")
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .foregroundStyle(Palette.removed)
        }
        if let seconds = item.duration, seconds >= 0.05 {
          Text(String(format: "%.1fs", seconds))
            .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Palette.inkFaint)
        }
        Image(systemName: expanded ? "chevron.up" : "chevron.down")
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(Palette.inkFaint.opacity(hovering || expanded ? 0.9 : 0))
      }
      .padding(.horizontal, dense ? 7 : 11).padding(.vertical, dense ? 5 : 8)
      .contentShape(Rectangle())
    }.buttonStyle(.plain)
  }

  /// Line-by-line view of one change.
/// - Line numbers follow the change: removed lines have only the old number, added lines only
///   the new one, so they match the editor.
/// - Very light washes: the colours are for scanning, the code must stay readable.
/// - Monospaced, scrolling horizontally: wrapping would break the indentation.
private struct DiffView: View {
  let diff: AgentClient.FileDiff

  /// The backend already caps at DIFF_MAX_LINES (400); the card is an index, not the record.
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
    case "gap": return " "
    default: return " "
    }
  }

  var body: some View {
    // No file name or +n -m here; the card's header already says it.
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
              // truncate rather than wrap, keeping indentation
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
    // a darker background but no border; the tool card already has one
    .padding(.vertical, 7)
    .background(
      Palette.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
  }
}

/// Partial enforcement, with the reason when expanded.
  /// Hosts this call reached, host names only. Allowed ones are neutral (networking is normal);
  /// refused ones are highlighted.
  private var hostsChip: some View {
    Button { showHosts.toggle() } label: {
      HStack(spacing: 3) {
        Image(systemName: item.blockedHosts.isEmpty ? "globe" : "globe.badge.chevron.backward")
          .font(.system(size: 9))
        Text(hostsSummary).font(.system(size: 9.5, weight: .medium))
      }
      .foregroundStyle(item.blockedHosts.isEmpty
                       ? Color.secondary
                       : Color(light: Color(red: 0.72, green: 0.48, blue: 0.13),
                               dark: Color(red: 0.95, green: 0.74, blue: 0.40)))
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

  private var enforcementChip: some View {
    Button { showEnforcement.toggle() } label: {
      HStack(spacing: 3) {
        Image(systemName: "exclamationmark.shield").font(.system(size: 9))
        Text(L("沙箱 \(item.enforcement ?? "")", "Sandbox \(item.enforcement ?? "")"))
          .font(.system(size: 9.5, weight: .medium))
      }
      .foregroundStyle(Color(light: Color(red: 0.72, green: 0.48, blue: 0.13),
                             dark: Color(red: 0.93, green: 0.75, blue: 0.42)))
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
      Hairline()
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
      // a diff comes first; it matters more than the tool's reply
      if let diff = item.diff, !diff.rows.isEmpty {
        DiffView(diff: diff)
      }
      if item.diff != nil {
        // the diff is the result; the backend's confirmation line is for the model
        EmptyView()
      } else if item.preview.isEmpty {
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
      if item.truncated {
        Text(L("已截断，全文在 workbench/tool-results/", "Truncated; the full output is in workbench/tool-results/"))
          .font(.system(size: 10)).foregroundStyle(Palette.inkFaint)
      }
    }.padding(.horizontal, 11).padding(.bottom, 10)
  }

  private static func icon(tone: Tone, tool: String) -> String {
    switch tone {
    case .failed: return "exclamationmark.triangle"
    case .blocked: return "shield.lefthalf.filled"
    case .denied: return "hand.raised"
    case .skipped: return "circle.dashed"
    case .running, .ok: break
    }
    switch tool {
    case "read": return "doc.text"
    case "write": return "square.and.pencil"
    case "edit": return "pencil"
    case "glob": return "folder"
    case "grep": return "magnifyingglass"
    case "bash": return "terminal"
    case "python": return "chevron.left.forwardslash.chevron.right"
    case "fetch_repo": return "arrow.down.circle"
    case "reocr": return "doc.viewfinder"
    case "cite": return "quote.opening"
    case "annotations": return "highlighter"
    case "list_projects", "find_project": return "list.bullet"
    case "open_project": return "folder.badge.gearshape"
    case "delete_project": return "trash"
    default: return "wrench.and.screwdriver"
    }
  }
}
