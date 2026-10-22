import SwiftUI

// The two basic rows: a user message and an assistant answer.

// MARK: - User

/// What a question needs to be edited where it was asked.
struct MessageEdit {
  /// whether this question's row is the editor right now
  var editing: Binding<Bool>
  /// false while a turn is running: the action shows but can't be used
  var enabled: Bool
  /// asks the edited question in place of this one; false when it couldn't be sent
  var send: (String) -> Bool
}

/// Right-aligned bubble that shrinks to its content, with at least 44 pt kept free on the left so
/// long questions don't fill the column. Images sent with the question sit above it; when it was
/// sent, copy and edit sit under it, shown on hover in space that is always kept, so nothing moves.
struct UserLine: View {
  let text: String
  var images: [TranscriptImage] = []
  var sentAt: Date? = nil
  /// nil: the question can't be edited
  var edit: MessageEdit? = nil
  /// the question follows the conversation's type size, or compact answers sit under 13 pt questions
  @AppStorage(TypeScale.chat.sizeKey) private var base = TypeScale.chat.standardSize

  private var size: CGFloat { TypeScale.chat.clamp(base) - 0.5 }

  var body: some View {
    if let edit, edit.editing.wrappedValue {
      MessageEditor(original: text, images: images, size: size, edit: edit)
    } else {
      SelectableRow { hovering in
        VStack(alignment: .trailing, spacing: 6) {
          if !images.isEmpty {
            HStack(spacing: 6) {
              Spacer(minLength: 44)
              ForEach(images) { SentImage(image: $0) }
            }
          }
          VStack(alignment: .trailing, spacing: 3) {
            if !text.isEmpty {
              HStack(spacing: 0) {
                Spacer(minLength: 44)
                Text(text)
                  .font(.system(size: size)).foregroundStyle(Palette.ink)
                  .selectableText()
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
            MessageActions(text: text, sentAt: sentAt, edit: edit)
              .opacity(hovering ? 1 : 0)
              .animation(.easeOut(duration: 0.12), value: hovering)
          }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
  }
}

/// When a question was sent, then copy and edit; under its bubble.
struct MessageActions: View {
  let text: String
  let sentAt: Date?
  let edit: MessageEdit?
  @State private var copied = false

  /// "11:23" today, "9月14日 11:23" this year, with the year before that; 24-hour, in the UI language.
  static func label(for date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    let template = calendar.isDate(date, inSameDayAs: now) ? "Hm"
      : calendar.isDate(date, equalTo: now, toGranularity: .year) ? "MMMdHm" : "yMMMdHm"
    let formatter = DateFormatter()
    formatter.locale = Localization.shared.language.locale
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter.string(from: date)
  }

  var body: some View {
    HStack(spacing: 2) {
      if let sentAt {
        Text(Self.label(for: sentAt))
          .font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.inkFaint)
          .padding(.trailing, 6)
      }
      if !text.isEmpty {
        MessageActionButton(
          symbol: copied ? "checkmark" : "doc.on.doc", help: L("复制", "Copy"), active: copied
        ) {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
          copied = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
        }
      }
      if let edit {
        MessageActionButton(symbol: "pencil", help: L("编辑消息", "Edit Message")) {
          edit.editing.wrappedValue = true
        }
        .disabled(!edit.enabled)
      }
    }
    .frame(height: 22)
  }
}

private struct MessageActionButton: View {
  let symbol: String
  let help: String
  var active = false
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.isEnabled) private var enabled

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(active ? Palette.accent : (hovering && enabled ? Palette.inkSoft : Palette.inkFaint))
        .frame(width: 24, height: 22)
        .background(
          Palette.ink.opacity(hovering && enabled ? 0.06 : 0),
          in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(enabled ? 1 : 0.45)
    .onHover { hovering = $0 }
    .help(help)
    .accessibilityLabel(help)
  }
}

/// A question being edited where it was asked. Return sends, ⌥Return breaks a line, Escape or Cancel
/// puts it back as it was. Its images go along unchanged.
private struct MessageEditor: View {
  let images: [TranscriptImage]
  let size: CGFloat
  let edit: MessageEdit
  @State private var draft: String
  @FocusState private var focused: Bool

  init(original: String, images: [TranscriptImage], size: CGFloat, edit: MessageEdit) {
    self.images = images
    self.size = size
    self.edit = edit
    _draft = State(initialValue: original)
  }

  private var canSend: Bool {
    edit.enabled && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: 8) {
      if !images.isEmpty {
        HStack(spacing: 6) {
          Spacer(minLength: 0)
          ForEach(images) { SentImage(image: $0) }
        }
      }
      TextField("", text: $draft, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.system(size: size)).foregroundStyle(Palette.ink)
        .lineLimit(1...14)
        .focused($focused)
        .onSubmit(send)
        .onExitCommand(perform: cancel)
        .padding(.horizontal, 13).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(Palette.accent.opacity(focused ? 0.6 : 0.3), lineWidth: 1.2))
        .accessibilityLabel(L("编辑提问", "Edit question"))
      HStack(spacing: 8) {
        Button(L("取消", "Cancel"), action: cancel)
          .buttonStyle(EditorButtonStyle(prominent: false))
        Button(L("发送", "Send"), action: send)
          .buttonStyle(EditorButtonStyle(prominent: true))
          .disabled(!canSend)
      }
    }
    .padding(.leading, 44)
    .frame(maxWidth: .infinity, alignment: .trailing)
    .background(CaretAtEnd(armed: focused))
    .onAppear { focused = true }
  }

  private func cancel() { edit.editing.wrappedValue = false }

  private func send() {
    guard canSend else { return }
    _ = edit.send(draft)
  }
}

/// Puts the caret at the end of the text that just took focus in this window. Taking focus selects
/// all of a field's text, and the first key typed would replace the whole question. Reads this view's
/// own window rather than the key window, which may not be this one yet.
private struct CaretAtEnd: NSViewRepresentable {
  let armed: Bool

  final class Coordinator { var placed = false }

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ view: NSView, context: Context) {
    guard armed, !context.coordinator.placed else { return }
    // after this pass, once focus has reached the text view and its select-all has happened
    DispatchQueue.main.async {
      guard let text = view.window?.firstResponder as? NSTextView else { return }
      text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
      context.coordinator.placed = true
    }
  }
}

private struct EditorButtonStyle: ButtonStyle {
  let prominent: Bool
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(prominent ? Palette.paper : Palette.inkSoft)
      .padding(.horizontal, 12)
      .frame(height: 26)
      .background(
        prominent ? Palette.accent : Palette.ink.opacity(0.06),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
      .contentShape(Rectangle())
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
  /// A StateObject, not State: rows are rebuilt on every streamed frame, and only this keeps from
  /// making a new one each time.
  @StateObject private var passage = PassageSelection()

  var body: some View {
    SelectableRow { hovering in
      VStack(alignment: .leading, spacing: 9) {
        if streaming, let live {
          LiveAnswer(pacer: live)
        } else if !item.text.isEmpty {
          // one passage: a drag selects across paragraphs, lists, tables and formulas
          MarkdownText(item.text, streaming: streaming)
            .passageSelection(hovering: hovering, selection: passage)
        } else if streaming {
          // no text yet: a caret, so the row isn't empty
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
    }
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
