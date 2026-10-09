import SwiftUI

// The two basic rows: a user message and an assistant answer.

// MARK: - User

/// Right-aligned bubble that shrinks to its content, with at least 44 pt kept free on the left so
/// long questions don't fill the column. Images sent with the question sit above it.
struct UserLine: View {
  let text: String
  var images: [TranscriptImage] = []

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      if !images.isEmpty {
        HStack(spacing: 6) {
          Spacer(minLength: 44)
          ForEach(images) { SentImage(image: $0) }
        }
      }
      if !text.isEmpty {
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
      }
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
  }
}

/// A thumbnail of a sent image; click for a larger look.
private struct SentImage: View {
  let image: TranscriptImage
  @State private var enlarged = false

  var body: some View {
    let picture = image.image
    Group {
      if let picture {
        Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
      } else {
        Image(systemName: "photo").font(.system(size: 16, weight: .light))
          .foregroundStyle(Palette.inkFaint)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Palette.sunk)
      }
    }
    .frame(width: 92, height: 72)
    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.ruleSoft))
    .contentShape(Rectangle())
    .onTapGesture { if picture != nil { enlarged = true } }
    .popover(isPresented: $enlarged) {
      if let picture {
        Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit)
          .frame(maxWidth: 640, maxHeight: 520).padding(8)
      }
    }
    .accessibilityLabel(L("附带的图片", "Attached image"))
  }
}

// MARK: - Assistant

struct AssistantLine: View {
  let item: TranscriptItem
  var streaming = false
  /// While streaming the text comes from here, not from `item`, whose text is the last finalised one.
  var live: StreamPacer? = nil
  @Binding var showThinking: Bool
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      if !item.thinking.isEmpty {
        // reasoning collapsed by default; expanded, it would push the answer down
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
        // no text yet (thinking, or about to call a tool): a caret, so the row isn't empty
        StreamingCaret()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    // Copy the whole answer as Markdown with LaTeX: rendered formulas are images and don't survive a
    // text selection copy. Appears on hover only.
    .overlay(alignment: .topTrailing) {
      if hovering, !streaming, !item.text.isEmpty {
        CopyAnswerButton(text: item.text).offset(y: -4)
      }
    }
    .onHover { hovering = $0 }
  }
}

private struct CopyAnswerButton: View {
  let text: String
  @State private var copied = false

  var body: some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      copied = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    } label: {
      Image(systemName: copied ? "checkmark" : "doc.on.doc")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(copied ? Palette.accent : Palette.inkFaint)
        .frame(width: 24, height: 22)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.ruleSoft))
    }
    .buttonStyle(.plain)
    .help(L("复制这段回答（Markdown）", "Copy this answer (Markdown)"))
  }
}

/// The streaming answer. Its own view observes the pacer, so only this redraws per frame.
private struct LiveAnswer: View {
  @ObservedObject var pacer: StreamPacer

  var body: some View {
    if pacer.shown.text.isEmpty {
      // first frame not caught up yet: show the caret
      StreamingCaret()
    } else {
      MarkdownText(pacer.shown.text, streaming: true)
    }
  }
}
