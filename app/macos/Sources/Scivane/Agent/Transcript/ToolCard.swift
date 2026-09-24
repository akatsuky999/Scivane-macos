import SwiftUI

// 一次工具调用的卡片，以及改文件时画出来的 diff（DiffView 嵌在里面）。

// MARK: - 工具卡片

/// 一次工具调用。折叠一行，点开看全部。
///
/// 四种非正常形态必须**一眼看得出区别**：
///
/// | 形态 | 长相 | 为什么要分开 |
/// |---|---|---|
/// | 失败 | 红色图标 + 「失败」 | 跑了但出错，模型通常会重试 |
/// | 被沙箱拦住 | 琥珀图标 + 「被拦」 | 边界正常工作，不是故障 |
/// | 被拒绝 | 灰色手势图标 + 「已拒绝」 | 是用户的决定，不该显示成错误 |
/// | 未执行 | 虚线边框 + 「未执行」 | **取消后补的合成结果** —— 回放时要能分辨「工具报错了」和「根本没跑」 |
struct ToolCard: View {
  let item: TranscriptItem
  /// 在分组里显示时去掉外层卡片装饰 —— 组已经有了自己的容器，
  /// 再套一层边框会变成「框里的框」，那是最显廉价的做法。
  var dense = false
  @State private var expanded = false
  @State private var hovering = false
  @State private var showHosts = false
  @State private var showEnforcement = false

  /// `startExpanded` 只给渲染验证用 —— 展开态是这张卡最该被看一眼的形态
  /// （diff 就画在里面），而离屏渲染点不了按钮。用 `State(initialValue:)`
  /// 播种而不是加一个 `||` 的旁路，是为了让点击仍然能把它收起来。
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
    // 不翻：看的是工具结果（给模型的那份永远是中文，后端 `i18n.py`）
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
          // 组里的那些也要有落点。**早先 dense 是完全透明的**，于是一串
          // 工具行悬在活动卡里，看不出一行到哪儿结束 —— 尤其是相邻两条
          // 都很短的时候。给一层更暗的内嵌底（codex desktop 给 diff 块的是
          // `rgba(0,0,0,.18)`，同一个判断：里层比外层更沉）。
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

        // 摘要与工具名相同就不重复说一遍。正常情况下后端会给一句人话
        // （「搜索 对比损失」），但老日志里没有这个字段，那时摘要会退回
        // 工具名 —— 不挡这一下就是「bash bash」。
        if item.summary != item.toolName, !item.summary.isEmpty {
          if item.awaitingResult {
            // 跑起来的那张卡，摘要会呼吸 —— 一眼看出是哪一步在等
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
        // **主机要出现在收起行里。** 折叠起来看不见的话，「agent 去过哪」
        // 这件事就只存在于后端的审计簿里 —— 那等于没有做审计
        // （同 enforcement 那一条的理由）。
        if !item.hosts.isEmpty || !item.blockedHosts.isEmpty {
          hostsChip
        }
        // 收起时也要看得见改了多少 —— 一次 edit 的价值全在这两个数上，
        // 藏进折叠里的话，这张卡和「跑了个命令」就长得一样了。
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

  /// 一次改动的逐行对照。
///
/// **这张视图回答的是「它到底改了什么」** —— 在一个会替你改正文和代码的
/// agent 里，这是最该被看见的一件事。只说「已改 md/context.md（1 处）」
/// 等于要用户自己去文件里翻，而那时改动已经落盘了。
///
/// 三个取舍：
///
/// - **行号跟着增删走**：删掉的行只有旧行号、新增的行只有新行号。
///   两边都填的话，用户没法把它和编辑器里的行号对上
/// - **底色压得很淡**（`addedWash` / `removedWash`）：整块高饱和的绿红
///   会让代码本身读不成句；着色是用来扫的，不是用来看的
/// - **等宽字体 + 横向滚动**：代码换行会把缩进结构打乱，而缩进正是
///   读 diff 时判断「改在哪一层」的唯一线索
private struct DiffView: View {
  let diff: AgentClient.FileDiff

  /// 卡片里最多画几行。后端已经按 `DIFF_MAX_LINES`（400）截过一道，
  /// 但 400 行铺在对话流里仍然是一屏半 —— 卡片是索引，不是记录本身。
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
    // **这里不再重复文件名和 +n −m。** 外面那行工具卡已经写着
    // 「edit 改 md/context.md   +1 −1」，再来一遍就是同一句话说三次
    // （加上下面的结果预览是四次）。重复本身就是"粗糙"。
    VStack(alignment: .leading, spacing: 5) {
      // **不套内层 ScrollView。** 嵌在对话流那个 ScrollView 里再来一个，
      // 滚动会互相抢，而且实测里那正是把主线程占满的那类结构。
      // 改成「只画前 VISIBLE_ROWS 行，剩下的报个数」—— 卡片是索引，
      // 要看全的去文件里看，那才是权威。
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
              // 一行一行地截断而不是换行：缩进是判断「改在哪一层」的线索，
              // 换行会把它打乱。截在右边不伤缩进。
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
    // **只给底，不给边。** 外面那张工具卡已经有一圈边框了，这里再来一圈
    // 就是"框里的框"——最显廉价的做法。里层比外层沉一点，层级就出来了。
    .padding(.vertical, 7)
    .background(
      Palette.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
  }
}

/// 执行强度不足的提示。
  ///
  /// 这个事实之前只存在于后端的 `ExecResult` 里 —— 等于「可报告的事实」
  /// 只报告给了日志。点开看原因。
  /// 这次调用到达过的主机。**只有主机名**，点开看全部。
  ///
  /// 放行的用中性色（联网是正常行为，不是警告）；被拒的用警示色 ——
  /// 那说明 agent 试过去它不该去的地方，用户有权当场看见。
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

  /// **被拦下那件事必须出现在文字里**，不能只靠颜色说。
  /// 琥珀色 + 「2 个主机」会让人以为一切正常，只是配色不同 ——
  /// 而这条 chip 之所以变色，正是因为 agent 试过去它不该去的地方。
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
      // 改了文件就先画改动 —— 「它到底改了什么」比「工具回了什么话」
      // 重要得多。后端的那句「已改 md/context.md（1 处）」还在下面。
      if let diff = item.diff, !diff.rows.isEmpty {
        DiffView(diff: diff)
      }
      if item.diff != nil {
        // diff 就是结果本身。后端那句「已改 md/context.md（1 处，+1 −1）」
        // 是给**模型**看的确认，不必再给用户看一遍。
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
    case "list_projects", "find_project": return "list.bullet"
    case "open_project": return "folder.badge.gearshape"
    case "delete_project": return "trash"
    default: return "wrench.and.screwdriver"
    }
  }
}
