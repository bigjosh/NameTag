import SwiftUI

struct AcceptInvitationSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let invitation: Invitation
    @State private var howDoIKnow = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Inviter info
                    AsyncProfileImage(url: invitation.fromProfilePhotoURL)
                        .frame(width: 100, height: 100)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.separator, lineWidth: 1))

                    Text(invitation.fromFullName)
                        .font(.title2.bold())

                    Text("wants to connect with you")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    // Personal message from inviter
                    if !invitation.message.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Message:")
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

                    // How do I know this person field
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How do I know this person?")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("e.g. Met at conference, Friend of a friend...", text: $howDoIKnow)
                            .padding()
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal)

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    // Accept button
                    Button {
                        Task { await accept() }
                    } label: {
                        if isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Accept")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isLoading)
                    .padding(.horizontal)

                    // Decline button
                    Button(role: .destructive) {
                        Task { await decline() }
                    } label: {
                        Text("Decline")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isLoading)
                    .padding(.horizontal)
                }
                .padding(.top, 32)
            }
            .navigationTitle("Invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func accept() async {
        guard let currentUser = appState.userService.currentAppUser else {
            errorMessage = "Not signed in."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            try await appState.invitationService.acceptInvitation(
                invitation,
                accepterUser: currentUser,
                accepterNote: howDoIKnow.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func decline() async {
        isLoading = true
        do {
            try await appState.invitationService.declineInvitation(invitation)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
