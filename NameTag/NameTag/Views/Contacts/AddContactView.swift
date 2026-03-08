import SwiftUI
import MessageUI

struct AddContactView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = ConnectionsViewModel()

    private var inviterName: String {
        appState.userService.currentAppUser?.fullName ?? "Someone"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Search by name, email, or phone")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    // Search field
                    HStack {
                        TextField("Name, email, or phone", text: $viewModel.searchQuery)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding()
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .onSubmit {
                                Task { await viewModel.searchAndProcess(using: appState) }
                            }

                        Button {
                            Task { await viewModel.searchAndProcess(using: appState) }
                        } label: {
                            if viewModel.isSearching {
                                ProgressView()
                            } else {
                                Image(systemName: "magnifyingglass")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSearching)
                    }
                    .padding(.horizontal)

                    // Error banner
                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(10)
                            .frame(maxWidth: .infinity)
                            .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal)
                    }

                    // Success banner
                    if let success = viewModel.successMessage {
                        Text(success)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(10)
                            .frame(maxWidth: .infinity)
                            .background(Color.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal)
                    }

                    // Name search results list
                    if !viewModel.nameSearchResults.isEmpty {
                        nameSearchResultsList
                    }

                    // Found user card (if they exist but aren't connected)
                    if let user = viewModel.searchResult {
                        foundUserCard(user: user)
                    }

                    // Invitation fields (shown after search)
                    if viewModel.showingInviteFields {
                        inviteFieldsSection
                    }
                }
                .padding(.top)
            }
            .navigationTitle("Invite Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: viewModel.invitationSent) { _, sent in
                if sent {
                    // Brief delay so the user sees the success message
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $viewModel.showingMailCompose) {
                // After mail compose is dismissed, auto-dismiss the invite screen
                dismiss()
            } content: {
                if viewModel.inviteIsEmail {
                    MailComposeView(
                        recipient: viewModel.inviteTarget,
                        subject: "Join me on NameTagger!",
                        body: viewModel.buildInvitationText(inviterName: inviterName)
                    )
                } else {
                    MessageComposeView(
                        recipient: viewModel.inviteTarget,
                        body: viewModel.buildInvitationText(inviterName: inviterName)
                    )
                }
            }
            .alert("Duplicate Invitation", isPresented: $viewModel.showingDuplicateAlert) {
                Button("Send Anyway") {
                    Task { await viewModel.confirmDuplicateSend() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(viewModel.duplicateAlertMessage)
            }
        }
    }

    // MARK: - Name Search Results

    private var nameSearchResultsList: some View {
        VStack(spacing: 8) {
            ForEach(viewModel.nameSearchResults) { user in
                Button {
                    viewModel.selectNameResult(user)
                } label: {
                    HStack(spacing: 12) {
                        AsyncProfileImage(url: user.profilePhotoURL)
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())

                        Text(user.fullName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.04), radius: 2)
                }
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Found User Card

    private func foundUserCard(user: AppUser) -> some View {
        HStack(spacing: 12) {
            AsyncProfileImage(url: user.profilePhotoURL)
                .frame(width: 50, height: 50)
                .clipShape(Circle())

            VStack(alignment: .leading) {
                Text(user.fullName)
                    .font(.headline)
                if let email = user.email {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 4)
        .padding(.horizontal)
    }

    // MARK: - Invite Fields

    private var inviteFieldsSection: some View {
        VStack(spacing: 16) {
            if viewModel.searchResult == nil {
                if viewModel.inviteTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No users found. Enter their email or phone above to send an invitation.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                } else {
                    Text("This person isn't on NameTag yet. Send them an invitation!")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Personal message (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Hey! Let's connect on NameTag...", text: $viewModel.personalMessage, axis: .vertical)
                    .lineLimit(3...6)
                    .padding()
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 8) {
                Text("How do I know this person?")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("e.g. College roommate, Work colleague...", text: $viewModel.howDoIKnow)
                    .padding()
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal)

            Button {
                Task {
                    await viewModel.sendInvitation(using: appState)
                }
            } label: {
                Text("Send Invitation")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
        }
    }

}

// MARK: - Mail Compose Wrapper

struct MailComposeView: UIViewControllerRepresentable {
    let recipient: String
    let subject: String
    let body: String
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([recipient])
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    class Coordinator: NSObject, MFMailComposeViewControllerDelegate, @unchecked Sendable {
        let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            Task { @MainActor in
                dismiss()
            }
        }
    }
}

// MARK: - Message Compose Wrapper

struct MessageComposeView: UIViewControllerRepresentable {
    let recipient: String
    let body: String
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = context.coordinator
        controller.recipients = [recipient]
        controller.body = body
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    class Coordinator: NSObject, MFMessageComposeViewControllerDelegate, @unchecked Sendable {
        let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            Task { @MainActor in
                dismiss()
            }
        }
    }
}
