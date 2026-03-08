import SwiftUI
import MessageUI

struct SentInvitationDetailSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let invitation: Invitation
    @State private var isResending = false
    @State private var isWithdrawing = false
    @State private var showingMailCompose = false
    @State private var showingWithdrawConfirmation = false
    @State private var successMessage: String?
    @State private var errorMessage: String?

    private var inviterName: String {
        appState.userService.currentAppUser?.fullName ?? "Someone"
    }

    private var canSendNotification: Bool {
        if invitation.toEmail != nil {
            return MFMailComposeViewController.canSendMail()
        } else {
            return MFMessageComposeViewController.canSendText()
        }
    }

    private var invitationText: String {
        var text = "You've been invited by \(inviterName) to connect on NameTagger. Now you will always be able to put a name to a face!"
        if !invitation.message.isEmpty {
            text += "\n\n\(invitation.message)"
        }
        text += "\n\nDownload NameTagger: https://apps.apple.com/us/app/nametagger/id6759207439"
        return text
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Icon
                    Image(systemName: "paperplane.circle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.orange)

                    // Who it was sent to
                    VStack(spacing: 4) {
                        Text("Invitation sent to")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text(invitation.targetDescription)
                            .font(.title3.bold())
                    }

                    // How Do I Know
                    if !invitation.howDoIKnow.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("How do I know this person?")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(invitation.howDoIKnow)
                                .font(.body)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(.horizontal)
                    }

                    // Personal message
                    if !invitation.message.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Personal message")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(invitation.message)
                                .font(.body)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(.horizontal)
                    }

                    // Sent date
                    HStack {
                        Text("Sent")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(invitation.createdAt, style: .relative)
                            .foregroundStyle(.secondary)
                        Text("ago")
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                    .padding(.horizontal)

                    // Status banners
                    if let success = successMessage {
                        Text(success)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(10)
                            .frame(maxWidth: .infinity)
                            .background(Color.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal)
                    }

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(10)
                            .frame(maxWidth: .infinity)
                            .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal)
                    }

                    // Re-send button
                    Button {
                        Task { await resend() }
                    } label: {
                        if isResending {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("Re-send Invitation", systemImage: "arrow.counterclockwise")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isResending || isWithdrawing)
                    .padding(.horizontal)

                    // Withdraw button
                    Button(role: .destructive) {
                        showingWithdrawConfirmation = true
                    } label: {
                        if isWithdrawing {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("Withdraw Invitation", systemImage: "xmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isResending || isWithdrawing)
                    .padding(.horizontal)
                }
                .padding(.top, 32)
            }
            .navigationTitle("Sent Invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showingMailCompose) {
                if invitation.toEmail != nil {
                    MailComposeView(
                        recipient: invitation.targetDescription,
                        subject: "Join me on NameTagger!",
                        body: invitationText
                    )
                } else {
                    MessageComposeView(
                        recipient: invitation.targetDescription,
                        body: invitationText
                    )
                }
            }
            .alert("Withdraw Invitation?", isPresented: $showingWithdrawConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Withdraw", role: .destructive) {
                    Task { await withdraw() }
                }
            } message: {
                Text("This will cancel the invitation. If \(invitation.targetDescription) tries to accept it, they'll be told it's no longer valid.")
            }
        }
    }

    private func withdraw() async {
        isWithdrawing = true
        errorMessage = nil
        successMessage = nil

        do {
            try await appState.invitationService.withdrawInvitation(invitation)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }

        isWithdrawing = false
    }

    private func resend() async {
        isResending = true
        errorMessage = nil
        successMessage = nil

        guard let currentUser = appState.userService.currentAppUser else {
            errorMessage = "Not signed in."
            isResending = false
            return
        }

        guard !currentUser.firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !currentUser.lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Please add your name in Profile before sending invitations."
            isResending = false
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

            if canSendNotification {
                successMessage = "Invitation re-sent!"
                showingMailCompose = true
            } else {
                successMessage = "Invitation re-sent!"
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isResending = false
    }
}
