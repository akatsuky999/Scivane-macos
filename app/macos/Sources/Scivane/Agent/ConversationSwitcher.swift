import SwiftUI

/// The project's conversations, in the toolbar island over the agent: the current one with a menu to
/// switch, rename, export or delete, and a button for a new one. It used to be a row of its own above
/// the transcript.
struct ConversationSwitcher: View {
  @ObservedObject var model: AppModel
  @State private var renaming = false
  @State private var draftTitle = ""
  @State private var hovering = false

  private var current: Conversation? {
    guard let id = model.activeConversationID else { return nil }
    return model.activeConversations.first { $0.id == id }
  }

  /// Never creates one here: the backend does on the first question, otherwise opening the pane
  /// would leave an empty conversation on disk.
  private var currentTitle: String { current?.displayTitle ?? L("新对话", "New Chat") }

  var body: some View {
    HStack(spacing: 2) {
      Menu {
        conversationList
        Divider()
        actions
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "bubble.left").font(.system(size: 11)).foregroundStyle(Palette.inkSoft)
          Text(currentTitle)
            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.ink)
            .lineLimit(1).truncationMode(.tail)
          if model.activeConversations.count > 1 {
            Text("\(model.activeConversations.count)")
              .font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.inkFaint)
          }
          Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .semibold))
            .foregroundStyle(Palette.inkFaint)
        }
        .padding(.horizontal, 9)
        .frame(height: SidebarMetrics.toolbarControl)
        .frame(maxWidth: 230, alignment: .leading)
        .background(ToolbarHover(active: hovering))
        .contentShape(Rectangle())
      }
      .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
      .fixedSize(horizontal: false, vertical: true)
      .onHover { hovering = $0 }
      .help(L("切换对话", "Switch Chat"))

      ToolbarIconButton(symbol: "square.and.pencil", label: L("新对话", "New Chat")) {
        Task { await model.newConversation() }
      }
    }
    .alert(L("重命名对话", "Rename Chat"), isPresented: $renaming) {
      TextField(L("标题", "Title"), text: $draftTitle)
      Button(L("保存", "Save")) {
        let title = draftTitle
        if let id = model.activeConversationID {
          Task { await model.renameConversation(id, to: title) }
        }
      }
      Button(L("取消", "Cancel"), role: .cancel) {}
    } message: {
      Text(L("默认用第一句提问当名字。", "By default it's named after the first question."))
    }
    .onChange(of: renaming) { _, active in
      if active { draftTitle = current?.title ?? "" }
    }
  }

  @ViewBuilder private var conversationList: some View {
    if model.activeConversations.isEmpty {
      Text(L("还没有对话", "No chats yet"))
    } else {
      ForEach(model.activeConversations) { conversation in
        Button {
          model.selectConversation(conversation.id)
        } label: {
          // checkmark: the menu has no other way to say "you are here"
          Label(
            conversation.displayTitle,
            systemImage: conversation.id == model.activeConversationID ? "checkmark" : "")
        }
      }
    }
  }

  @ViewBuilder private var actions: some View {
    Button(L("新对话", "New Chat")) { Task { await model.newConversation() } }
    if let id = model.activeConversationID {
      Button(L("重命名…", "Rename…")) { renaming = true }
      Button(L("导出为 JSON…", "Export as JSON…")) { Task { await model.exportConversation(id) } }
      Divider()
      Button(L("删除这条对话…", "Delete This Chat…"), role: .destructive) {
        Task { await model.deleteConversation(id) }
      }
    }
  }
}
