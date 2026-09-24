import SwiftUI

// 用户的一句话、助手的一段回答 —— 对话流里最基本的两种行。

// MARK: - 用户

/// 用户的话：**右对齐的气泡**。
///
/// 与助手的回答形成左右分野，一眼看得出谁在说话 —— 这也是 ChatGPT 与
/// 左边永远留一段空白（至少 44pt），
/// 长问题不会顶满整栏；气泡自己按内容收缩，短问题就是短短一块。
// 原先是 file-private。拆文件之后用它的视图在别的文件里，
// 只能收窄到模块内可见。
struct UserLine: View {
  let text: String
  var body: some View {
    HStack(spacing: 0) {
      Spacer(minLength: 44)
      Text(text)
        .font(.system(size: 13)).foregroundStyle(Palette.ink)
        .textSelection(.enabled)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 13).padding(.vertical, 9)
        .background(
          Palette.sunk, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(Palette.ruleSoft.opacity(0.6)))
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
  }
}

// MARK: - 助手

// 原先是 file-private。拆文件之后用它的视图在别的文件里，
// 只能收窄到模块内可见。
struct AssistantLine: View {
  let item: TranscriptItem
  var streaming = false
  /// 正在生成的那一条屏幕上显示到哪了。**流式时正文从这里读**，不从 `item` 读 ——
  /// 逐帧的增长不经过记录（见 `StreamPacer`），`item.text` 只是上一次定稿的字。
  var live: StreamPacer? = nil
  @Binding var showThinking: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      if !item.thinking.isEmpty {
        // 推理默认折起来：它对判断「模型有没有理解题目」有用，
        // 但常驻展开会把真正的回答挤下去
        Button {
          showThinking.toggle()
        } label: {
          HStack(spacing: 5) {
            Image(systemName: showThinking ? "chevron.down" : "chevron.right")
              .font(.system(size: 8, weight: .semibold))
            Text(showThinking ? L("收起思考", "Hide Thinking") : L("展开思考", "Show Thinking"))
              .font(.system(size: 11, weight: .medium))
            Spacer(minLength: 0)
          }.foregroundStyle(Palette.inkFaint)
            .padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(.plain)
          .accessibilityValue(showThinking ? L("已展开", "Expanded") : L("已收起", "Collapsed"))

        if showThinking {
          ThinkingContent(text: item.thinking)
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
              Rectangle().fill(Palette.rule).frame(width: 1.5)
            }
        }
      }
      if streaming, let live {
        LiveAnswer(pacer: live)
      } else if !item.text.isEmpty {
        MarkdownText(item.text, streaming: streaming)
      } else if streaming {
        // 还没吐出正文（可能在想，也可能正要调工具）—— 先摆个光标占位，
        // 否则这一条在屏幕上什么都没有，看着像卡住了
        StreamingCaret()
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// 正在生成的回答。**单独一个视图观察 pacer** —— 逐帧重画的只有这一段，
/// 对话流里的其余行、外面的面板与输入框一概不动。
private struct LiveAnswer: View {
  @ObservedObject var pacer: StreamPacer

  var body: some View {
    if pacer.shown.text.isEmpty {
      // 这一行刚出现、第一帧还没追上来 —— 先摆个光标，别让它空着
      StreamingCaret()
    } else {
      MarkdownText(pacer.shown.text, streaming: true)
    }
  }
}
