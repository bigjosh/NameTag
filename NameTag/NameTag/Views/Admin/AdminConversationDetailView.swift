import SwiftUI

struct AdminConversationDetailView: View {
    @Environment(AppState.self) private var appState
    let conversation: Conversation
    let targetUserUID: String
    @Bindable var viewModel: AdminViewModel

    private var otherName: String {
        conversation.otherName(currentUID: targetUserUID)
    }

    var body: some View {
        Group {
            if viewModel.isLoadingMessages {
                ProgressView("Loading messages…")
            } else if viewModel.messages.isEmpty {
                ContentUnavailableView(
                    "No Messages",
                    systemImage: "bubble.left",
                    description: Text("This conversation has no messages.")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(viewModel.messages) { message in
                                AdminMessageBubble(
                                    message: message,
                                    isTargetUser: message.senderUID == targetUserUID,
                                    senderName: senderName(for: message)
                                )
                                .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onAppear {
                        // Scroll to the latest message
                        if let lastID = viewModel.messages.last?.id {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .navigationTitle(otherName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let convID = conversation.id else { return }
            // Cache participant names for display
            viewModel.participantNames = conversation.participantNames
            await viewModel.fetchMessages(conversationID: convID, using: appState)
        }
    }

    private func senderName(for message: Message) -> String {
        conversation.participantNames[message.senderUID] ?? "Unknown"
    }
}

// MARK: - Message Bubble

private struct AdminMessageBubble: View {
    let message: Message
    let isTargetUser: Bool
    let senderName: String

    var body: some View {
        VStack(alignment: isTargetUser ? .trailing : .leading, spacing: 2) {
            // Sender label
            Text(senderName)
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Message bubble
            Text(message.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isTargetUser ? Color.blue : Color(.systemGray5))
                .foregroundStyle(isTargetUser ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            // Timestamp
            Text(message.sentAt.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: isTargetUser ? .trailing : .leading)
    }
}
