import Foundation
import MessageUI
import UIKit

@Observable
final class ConnectionsViewModel {
    var searchQuery = ""
    var searchResult: AppUser?
    var nameSearchResults: [AppUser] = []
    var isSearching = false
    var errorMessage: String?
    var successMessage: String?

    // Invitation fields
    var personalMessage = ""
    var howDoIKnow = ""
    var showingInviteFields = false
    var showingMailCompose = false
    var inviteTarget = ""
    var inviteIsEmail = false

    // Tracks when an invitation was successfully sent (for auto-dismiss)
    var invitationSent = false

    // Duplicate invitation warning
    var showingDuplicateAlert = false
    var duplicateAlertMessage = ""
    private var pendingAppState: AppState?

    // Accept invitation fields
    var acceptNote = ""

    var invitationMessage: String {
        ""  // Computed dynamically in the view using inviter name
    }

    /// Determines query type: email (contains @), phone (digits only), or name.
    enum SearchQueryType {
        case email, phone, name
    }

    func classifyQuery(_ query: String) -> SearchQueryType {
        if query.contains("@") { return .email }
        let digitsOnly = query.filter(\.isNumber)
        if digitsOnly.count >= 10 && digitsOnly.count <= 11 {
            return .phone
        }
        return .name
    }

    func searchAndProcess(using appState: AppState) async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        isSearching = true
        errorMessage = nil
        successMessage = nil
        searchResult = nil
        nameSearchResults = []
        showingInviteFields = false

        let queryType = classifyQuery(query)
        inviteIsEmail = queryType == .email
        inviteTarget = query

        do {
            switch queryType {
            case .email, .phone:
                let user: AppUser?
                if queryType == .email {
                    user = try await appState.userService.searchByEmail(query)
                } else {
                    user = try await appState.userService.searchByPhone(query)
                }

                if let user = user {
                    let alreadyConnected = appState.connectionsService.connections.contains {
                        $0.userId == user.id
                    }
                    if alreadyConnected {
                        successMessage = "This is an existing contact"
                    } else {
                        searchResult = user
                        showingInviteFields = true
                    }
                } else {
                    showingInviteFields = true
                }

            case .name:
                let results = try await appState.userService.searchByName(
                    query, excludingUID: appState.authService.currentUID
                )
                // Filter out already-connected users
                let connectedUIDs = Set(appState.connectionsService.connections.compactMap(\.userId))
                nameSearchResults = results.filter { !connectedUIDs.contains($0.id ?? "") }
                if nameSearchResults.isEmpty {
                    inviteTarget = ""
                    showingInviteFields = true
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isSearching = false
    }

    /// Select a user from name search results to send an invitation.
    func selectNameResult(_ user: AppUser) {
        searchResult = user
        nameSearchResults = []
        inviteTarget = user.email ?? user.phone ?? ""
        inviteIsEmail = user.email != nil
        showingInviteFields = true
    }

    /// Validates that a string is a plausible email or phone number.
    private func isValidEmailOrPhone(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Email: must contain @ and .
        if trimmed.contains("@") {
            return trimmed.contains(".") && trimmed.count >= 5
        }
        // Phone: exactly 10 digits (or 11 starting with country code 1)
        let digits = trimmed.filter(\.isNumber)
        return digits.count == 10 || (digits.count == 11 && digits.hasPrefix("1"))
    }

    /// Whether the device can send the notification (Mail or Messages)
    var canSendNotification: Bool {
        if inviteIsEmail {
            return MFMailComposeViewController.canSendMail()
        } else {
            return MFMessageComposeViewController.canSendText()
        }
    }

    func sendInvitation(using appState: AppState) async {
        guard let currentUser = appState.userService.currentAppUser else {
            errorMessage = "Not signed in."
            return
        }

        // Require a name before sending invitations
        guard !currentUser.firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !currentUser.lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Please add your name in Profile before sending invitations."
            return
        }

        // Re-derive target from current search field in case user changed it after searching
        if searchResult == nil {
            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let queryType = classifyQuery(query)
            inviteTarget = query
            inviteIsEmail = queryType == .email
        }

        // Need a found user OR a valid email/phone target to send
        let targetToValidate = searchResult != nil
            ? (searchResult!.email ?? searchResult!.phone ?? inviteTarget)
            : inviteTarget
        guard isValidEmailOrPhone(targetToValidate) else {
            errorMessage = "Please enter a valid email address or phone number to send an invitation."
            return
        }

        // Check for existing pending invitation to the same target
        let existingInvitation = appState.invitationService.sentInvitations.first { inv in
            if inviteIsEmail {
                return inv.toEmail?.lowercased() == inviteTarget.lowercased()
            } else {
                let existingDigits = (inv.toPhone ?? "").filter(\.isNumber)
                let targetDigits = inviteTarget.filter(\.isNumber)
                return !existingDigits.isEmpty && existingDigits == targetDigits
            }
        }

        if let existing = existingInvitation {
            let target = existing.toEmail ?? existing.toPhone ?? inviteTarget
            duplicateAlertMessage = "You already have a pending invitation to \(target). Send another?"
            pendingAppState = appState
            showingDuplicateAlert = true
            return
        }

        await performSendInvitation(using: appState)
    }

    /// Called after duplicate check passes or user confirms sending anyway
    func confirmDuplicateSend() async {
        guard let appState = pendingAppState else { return }
        pendingAppState = nil
        await performSendInvitation(using: appState)
    }

    private func performSendInvitation(using appState: AppState) async {
        guard let currentUser = appState.userService.currentAppUser else { return }

        // Check if the target user/email/phone is banned
        do {
            if let targetUser = searchResult, let uid = targetUser.id {
                if let uidBanned = try? await appState.adminService.isUIDBanned(uid), uidBanned {
                    errorMessage = "This user is not eligible to receive invitations."
                    return
                }
            }
            if inviteIsEmail {
                if let emailBanned = try? await appState.adminService.isEmailBanned(inviteTarget), emailBanned {
                    errorMessage = "This email address is not eligible to receive invitations."
                    return
                }
            } else {
                if let phoneBanned = try? await appState.adminService.isPhoneBanned(inviteTarget), phoneBanned {
                    errorMessage = "This phone number is not eligible to receive invitations."
                    return
                }
            }
        }

        let trimmedMessage = personalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = howDoIKnow.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try await appState.invitationService.sendInvitation(
                from: currentUser,
                toUser: searchResult,
                toEmail: inviteIsEmail ? inviteTarget : nil,
                toPhone: inviteIsEmail ? nil : inviteTarget,
                message: trimmedMessage,
                howDoIKnow: trimmedNote
            )

            if canSendNotification {
                successMessage = "Invitation sent!"
                showingMailCompose = true
            } else if !inviteIsEmail {
                // Device can't use in-app compose — open Messages directly via URL scheme
                let digits = inviteTarget.filter(\.isNumber)
                let body = buildInvitationText(inviterName: currentUser.fullName)
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                if let url = URL(string: "sms:\(digits)&body=\(body)") {
                    await UIApplication.shared.open(url)
                }
                successMessage = "Invitation sent!"
                invitationSent = true
            } else if searchResult != nil {
                successMessage = "Invitation sent! They'll see it in the app."
                invitationSent = true
            } else {
                successMessage = "Invitation saved! Set up Mail to also notify them by email."
                invitationSent = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func buildInvitationText(inviterName: String) -> String {
        var text = "You've been invited by \(inviterName) to connect on NameTagger. Now you will always be able to put a name to a face!"
        let trimmedMessage = personalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMessage.isEmpty {
            text += "\n\n\(trimmedMessage)"
        }
        text += "\n\nDownload NameTagger: https://apps.apple.com/us/app/nametagger/id6759207439"
        return text
    }

    func acceptInvitation(_ invitation: Invitation, using appState: AppState) async {
        guard let currentUser = appState.userService.currentAppUser else {
            errorMessage = "Not signed in."
            return
        }

        do {
            try await appState.invitationService.acceptInvitation(
                invitation,
                accepterUser: currentUser,
                accepterNote: acceptNote.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            acceptNote = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func declineInvitation(_ invitation: Invitation, using appState: AppState) async {
        do {
            try await appState.invitationService.declineInvitation(invitation)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeConnection(connectionUID: String, using appState: AppState) async {
        guard let myUID = appState.authService.currentUID else { return }

        do {
            try await appState.connectionsService.removeConnection(
                myUID: myUID, connectionUID: connectionUID
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resendInvitation(_ invitation: Invitation, using appState: AppState) async {
        guard let currentUser = appState.userService.currentAppUser else {
            errorMessage = "Not signed in."
            return
        }

        guard !currentUser.firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !currentUser.lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Please add your name in Profile before sending invitations."
            return
        }

        do {
            try await appState.invitationService.sendInvitation(
                from: currentUser,
                toUser: nil,
                toEmail: invitation.toEmail,
                toPhone: invitation.toPhone,
                message: invitation.message,
                howDoIKnow: invitation.howDoIKnow
            )
            successMessage = "Invitation re-sent!"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetInviteState() {
        searchResult = nil
        nameSearchResults = []
        showingInviteFields = false
        showingMailCompose = false
        personalMessage = ""
        howDoIKnow = ""
        searchQuery = ""
        errorMessage = nil
        successMessage = nil
    }
}
