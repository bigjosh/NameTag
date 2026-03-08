import Foundation

@Observable
final class AdminViewModel {
    var searchQuery = ""
    var searchResults: [AppUser] = []
    var isSearching = false
    var errorMessage: String?
    var successMessage: String?

    // Ban flow
    var showingBanConfirmation = false
    var banReason = ""
    var banTarget: AppUser?
    var isBanning = false
    var didCompleteBan = false

    // Unban flow
    var showingUnbanConfirmation = false
    var unbanTarget: BannedUser?
    var isUnbanning = false

    // Banned users list
    var bannedUsers: [BannedUser] = []
    var isLoadingBannedUsers = false

    // Conversations for a target user
    var conversations: [Conversation] = []
    var isLoadingConversations = false

    // Messages for a conversation
    var messages: [Message] = []
    var isLoadingMessages = false

    // Participant name cache for conversation detail
    var participantNames: [String: String] = [:]

    // MARK: - Search

    func search(using appState: AppState) async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        isSearching = true
        errorMessage = nil

        do {
            searchResults = try await appState.adminService.searchAllUsers(query: query)
        } catch {
            errorMessage = error.localizedDescription
        }

        isSearching = false
    }

    // MARK: - Banned Users

    func fetchBannedUsers(using appState: AppState) async {
        isLoadingBannedUsers = true
        do {
            bannedUsers = try await appState.adminService.fetchBannedUsers()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingBannedUsers = false
    }

    // MARK: - Ban User

    func confirmBan(user: AppUser) {
        banTarget = user
        banReason = ""
        showingBanConfirmation = true
    }

    func executeBan(using appState: AppState) async {
        guard let target = banTarget, let targetUID = target.id else { return }
        guard let adminUID = appState.authService.currentUID else { return }

        isBanning = true
        errorMessage = nil

        do {
            try await appState.adminService.banUser(
                targetUID: targetUID,
                targetUser: target,
                reason: banReason.trimmingCharacters(in: .whitespacesAndNewlines),
                adminUID: adminUID
            )
            successMessage = "\(target.fullName) has been banned."
            banTarget = nil
            banReason = ""
            didCompleteBan = true

            // Refresh search results and banned users list
            await search(using: appState)
            await fetchBannedUsers(using: appState)
        } catch {
            errorMessage = "Ban failed: \(error.localizedDescription)"
        }

        isBanning = false
    }

    // MARK: - Unban User

    func confirmUnban(bannedUser: BannedUser) {
        unbanTarget = bannedUser
        showingUnbanConfirmation = true
    }

    func executeUnban(using appState: AppState) async {
        guard let target = unbanTarget, let targetUID = target.id else { return }

        isUnbanning = true
        errorMessage = nil

        do {
            try await appState.adminService.unbanUser(targetUID: targetUID)
            successMessage = "\(target.fullName) has been un-banned."
            unbanTarget = nil

            // Refresh banned users list
            await fetchBannedUsers(using: appState)
        } catch {
            errorMessage = "Unban failed: \(error.localizedDescription)"
        }

        isUnbanning = false
    }

    // MARK: - Conversations

    func fetchConversations(forUser uid: String, using appState: AppState) async {
        isLoadingConversations = true
        do {
            conversations = try await appState.adminService.fetchConversations(forUser: uid)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingConversations = false
    }

    // MARK: - Messages

    func fetchMessages(conversationID: String, using appState: AppState) async {
        isLoadingMessages = true
        do {
            messages = try await appState.adminService.fetchMessages(conversationID: conversationID)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingMessages = false
    }
}
