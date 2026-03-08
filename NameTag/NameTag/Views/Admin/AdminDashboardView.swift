import SwiftUI

struct AdminDashboardView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = AdminViewModel()

    var body: some View {
        List {
            // MARK: - Search Section
            Section {
                HStack {
                    TextField("Search by name, email, or phone", text: $viewModel.searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit {
                            Task { await viewModel.search(using: appState) }
                        }

                    Button {
                        Task { await viewModel.search(using: appState) }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .disabled(viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("User Search")
            }

            // MARK: - Search Results
            if viewModel.isSearching {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else if !viewModel.searchResults.isEmpty {
                Section {
                    ForEach(viewModel.searchResults) { user in
                        NavigationLink {
                            AdminUserDetailView(user: user, viewModel: viewModel)
                        } label: {
                            AdminUserRow(user: user)
                        }
                    }
                } header: {
                    Text("Results (\(viewModel.searchResults.count))")
                }
            } else if !viewModel.searchQuery.isEmpty && !viewModel.isSearching {
                Section {
                    Text("No users found.")
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: - Status Messages
            if let error = viewModel.errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            if let success = viewModel.successMessage {
                Section {
                    Text(success)
                        .foregroundStyle(.green)
                        .font(.footnote)
                }
            }

            // MARK: - Banned Users
            Section {
                if viewModel.isLoadingBannedUsers {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if viewModel.bannedUsers.isEmpty {
                    Text("No banned users.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.bannedUsers) { bannedUser in
                        BannedUserRow(bannedUser: bannedUser) {
                            viewModel.confirmUnban(bannedUser: bannedUser)
                        }
                    }
                }
            } header: {
                Text("Banned Users (\(viewModel.bannedUsers.count))")
            }
        }
        .navigationTitle("Admin Dashboard")
        .task {
            await viewModel.fetchBannedUsers(using: appState)
        }
        .alert("Confirm Unban", isPresented: $viewModel.showingUnbanConfirmation) {
            Button("Unban", role: .destructive) {
                Task { await viewModel.executeUnban(using: appState) }
            }
            Button("Cancel", role: .cancel) {
                viewModel.unbanTarget = nil
            }
        } message: {
            if let target = viewModel.unbanTarget {
                Text("Un-ban \(target.fullName)? They will be able to register and receive invitations again.")
            }
        }
    }
}

// MARK: - User Row

private struct AdminUserRow: View {
    let user: AppUser

    var body: some View {
        HStack(spacing: 12) {
            AsyncProfileImage(url: user.profilePhotoURL)
                .frame(width: 44, height: 44)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(user.fullName)
                        .font(.headline)
                    if user.isBanned {
                        Text("BANNED")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.red, in: Capsule())
                    }
                }
                if let email = user.email {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let phone = user.phone {
                    Text(phone)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Banned User Row

private struct BannedUserRow: View {
    let bannedUser: BannedUser
    let onUnban: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(bannedUser.fullName)
                    .font(.headline)
                Spacer()
                Button("Unban") {
                    onUnban()
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .tint(.green)
            }

            if let email = bannedUser.email {
                Text(email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let phone = bannedUser.phone {
                Text(phone)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Reason: \(bannedUser.reason.isEmpty ? "No reason given" : bannedUser.reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Banned \(bannedUser.bannedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
