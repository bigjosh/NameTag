import SwiftUI

struct AdminConversationsListView: View {
    @Environment(AppState.self) private var appState
    let targetUser: AppUser
    @Bindable var viewModel: AdminViewModel

    var body: some View {
        Group {
            if viewModel.isLoadingConversations {
                ProgressView("Loading conversations…")
            } else if viewModel.conversations.isEmpty {
                ContentUnavailableView(
                    "No Conversations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("\(targetUser.fullName) has no conversations.")
                )
            } else {
                List(viewModel.conversations) { conversation in
                    NavigationLink {
                        AdminConversationDetailView(
                            conversation: conversation,
                            targetUserUID: targetUser.id ?? "",
                            viewModel: viewModel
                        )
                    } label: {
                        ConversationRow(
                            conversation: conversation,
                            targetUserUID: targetUser.id ?? ""
                        )
                    }
                }
            }
        }
        .navigationTitle("Conversations")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let uid = targetUser.id else { return }
            await viewModel.fetchConversations(forUser: uid, using: appState)
        }
    }
}

// MARK: - Conversation Row

private struct ConversationRow: View {
    let conversation: Conversation
    let targetUserUID: String

    private var otherName: String {
        conversation.otherName(currentUID: targetUserUID)
    }

    private var otherPhotoURL: String? {
        conversation.otherPhotoURL(currentUID: targetUserUID)
    }

    var body: some View {
        HStack(spacing: 12) {
            AsyncProfileImage(url: otherPhotoURL)
                .frame(width: 40, height: 40)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(otherName)
                    .font(.headline)

                Text(conversation.lastMessageText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Text(conversation.lastMessageTimestamp.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
