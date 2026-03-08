import SwiftUI

struct AdminUserDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let user: AppUser
    @Bindable var viewModel: AdminViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // MARK: - Profile Photo
            AsyncProfileImage(url: user.profilePhotoURL)
                .frame(width: 140, height: 140)
                .clipShape(Circle())
                .overlay(Circle().stroke(.separator, lineWidth: 1))

            // MARK: - Name + Ban Badge
            VStack(spacing: 8) {
                Text(user.fullName)
                    .font(.title.bold())

                if user.isBanned {
                    Text("BANNED")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.red, in: Capsule())
                }
            }

            // MARK: - Message Streams Button
            NavigationLink {
                AdminConversationsListView(
                    targetUser: user,
                    viewModel: viewModel
                )
            } label: {
                Label("\(user.firstName)'s Message Streams", systemImage: "bubble.left.and.bubble.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)

            // MARK: - Ban Action
            if !user.isBanned {
                Button(role: .destructive) {
                    viewModel.confirmBan(user: user)
                } label: {
                    HStack {
                        if viewModel.isBanning {
                            ProgressView()
                        } else {
                            Label("Ban User", systemImage: "exclamationmark.shield")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .padding(.horizontal, 32)
                .disabled(viewModel.isBanning)
            }

            // MARK: - Status Messages
            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .padding(.horizontal)
            }

            if let success = viewModel.successMessage {
                Text(success)
                    .foregroundStyle(.green)
                    .font(.footnote)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .navigationTitle("User Detail")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: viewModel.didCompleteBan) { _, completed in
            if completed {
                viewModel.didCompleteBan = false
                dismiss()
            }
        }
        .alert("Ban User", isPresented: $viewModel.showingBanConfirmation) {
            TextField("Reason for ban", text: $viewModel.banReason)
            Button("Ban", role: .destructive) {
                Task { await viewModel.executeBan(using: appState) }
            }
            Button("Cancel", role: .cancel) {
                viewModel.banTarget = nil
                viewModel.banReason = ""
            }
        } message: {
            if let target = viewModel.banTarget {
                Text("Ban \(target.fullName)? This will delete their data, messages, connections, and photo. They will be unable to register or be invited again.")
            }
        }
    }
}
