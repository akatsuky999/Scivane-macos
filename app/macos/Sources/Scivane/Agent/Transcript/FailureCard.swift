import SwiftUI

// MARK: - 错误与提示

/// 失败卡片。**每一类都要有自己的下一步建议**，不要都退化成「出错了」。
struct FailureCard: View {
  let code: String
  let message: String

  private var copy: (title: String, hint: String) {
    switch code {
    case "SANDBOX_UNAVAILABLE":
      return (L("沙箱起不来，这一步没有执行", "The sandbox couldn't start, so this step didn't run"),
              L("这是刻意的：不受约束地跑命令等于没有边界，所以我们拒绝执行而不是降级。多半是系统缺了 /usr/bin/sandbox-exec（macOS 自带的沙箱工具）。",
                "This is deliberate: running commands unconstrained means no boundary at all, so we refuse "
                  + "rather than downgrade. Most likely /usr/bin/sandbox-exec (the sandbox tool built into macOS) is missing."))
    case "AUTH", "INVALID_CREDENTIAL", "MISSING_CREDENTIAL":
      return (L("模型拒绝了这次请求：凭据不对", "The model refused the request: the key is wrong"),
              L("去设置里重新填一次 API key，填完可以点「测试连接」确认。",
                "Enter the API key again in Settings, then click “Test Connection” to check."))
    case "CONTEXT_WINDOW_EXCEEDED":
      return (L("这篇论文加上对话已经超出模型的上下文窗口", "This paper plus the chat exceeds the model's context window"),
              L("换一个窗口更大的模型，或者新开一轮对话把历史清掉。",
                "Switch to a model with a larger window, or start a new chat to clear the history."))
    case "RATE_LIMIT":
      return (L("被厂商限流了", "Rate-limited by the provider"),
              L("等一会儿再问。频繁出现的话换个 provider 或升级配额。",
                "Wait a moment and ask again. If it keeps happening, switch providers or raise your quota."))
    case "QUOTA":
      return (L("配额用完了", "Out of quota"),
              L("重试不会有用 —— 去厂商后台充值或换一个 provider。",
                "Retrying won't help — top up with the provider or switch to another one."))
    case "HTTP_409":
      return (L("这篇论文的正文还不能用于问答", "This paper's text can't be used for questions yet"), message)
    case "HTTP_404":
      return (L("找不到这个 provider", "Can't find this provider"),
              L("去设置里确认已经配好模型，再回来重试。", "Check that a model is set up in Settings, then try again."))
    case "TRANSPORT":
      return (L("连不上本地服务", "Can't reach the local service"),
              L("后端可能没起来。看看侧栏底部的状态，或重开一次 App。",
                "The backend may not be running. Check the status at the bottom of the sidebar, or reopen the app."))
    case "STREAM_ENDED":
      return (L("模型连接提前结束了", "The model connection ended early"),
              L("工具结果已经保留，但模型没有给出最终结论。可以直接重试这一轮。",
                "Tool results are kept, but the model gave no final conclusion. You can retry this turn."))
    default:
      return (L("这一轮没能走完", "This turn didn't finish"), message)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 7) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 11)).foregroundStyle(Palette.danger)
        Text(copy.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
      }
      Text(copy.hint)
        .font(.system(size: 11.5)).foregroundStyle(Palette.inkSoft)
        .fixedSize(horizontal: false, vertical: true)
      if copy.hint != message, !message.isEmpty {
        Text(message)
          .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.inkFaint)
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(13)
    .background(Palette.danger.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .strokeBorder(Palette.danger.opacity(0.25)))
  }
}

// 原先是 file-private。拆文件之后用它的视图在别的文件里，
// 只能收窄到模块内可见。
struct NoticeLine: View {
  let text: String
  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "info.circle").font(.system(size: 10))
      Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
    }
    .foregroundStyle(Palette.inkFaint)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
