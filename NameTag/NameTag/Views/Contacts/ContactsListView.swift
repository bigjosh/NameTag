import SwiftUI

enum ContactsTab: String, CaseIterable {
    case contacts = "Contacts"
    case invitations = "Invitations"
}

enum InvitationsSubTab: String, CaseIterable {
    case forYou = "For You"
    case fromYou = "From You"
}

struct ContactsListView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = ConnectionsViewModel()
    @State private var showingAddContact = false
    @State private var selectedInvitation: Invitation?
    @State private var selectedSentInvitation: Invitation?
    @State private var selectedConnection: Connection?
    @State private var selectedTab: ContactsTab = .contacts
    @State private var selectedInvitationsSubTab: InvitationsSubTab = .forYou

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Top-level segmented picker
                Picker("", selection: $selectedTab) {
                    ForEach(ContactsTab.allCases, id: \.self) { tab in
                        if tab == .invitations && !latestPendingInvitations.isEmpty {
                            Text("\(tab.rawValue) (\(latestPendingInvitations.count))")
                                .tag(tab)
                        } else {
                            Text(tab.rawValue)
                                .tag(tab)
                        }
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                // Content
                switch selectedTab {
                case .contacts:
                    contactsContent
                case .invitations:
                    invitationsContent
                }
            }
            .navigationTitle("Contacts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddContact = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddContact) {
                AddContactView()
            }
            .sheet(item: $selectedInvitation) { invitation in
                AcceptInvitationSheet(invitation: invitation)
            }
            .sheet(item: $selectedSentInvitation) { invitation in
                SentInvitationDetailSheet(invitation: invitation)
            }
            .sheet(item: $selectedConnection) { connection in
                ContactDetailSheet(connection: connection)
            }
        }
    }

    // MARK: - Contacts Tab Content

    private var contactsContent: some View {
        Group {
            if appState.connectionsService.connections.isEmpty {
                ContentUnavailableView(
                    "No Contacts Yet",
                    systemImage: "person.slash",
                    description: Text("Invite contacts to see them when they're nearby.")
                )
            } else {
                List {
                    ForEach(appState.connectionsService.connections) { connection in
                        connectionRow(connection: connection)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let connection = appState.connectionsService.connections[index]
                            Task {
                                await viewModel.removeConnection(
                                    connectionUID: connection.userId,
                                    using: appState
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Invitations Tab Content

    private var invitationsContent: some View {
        VStack(spacing: 0) {
            // Sub-tab picker
            Picker("", selection: $selectedInvitationsSubTab) {
                ForEach(InvitationsSubTab.allCases, id: \.self) { subTab in
                    if subTab == .forYou && !latestPendingInvitations.isEmpty {
                        Text("\(subTab.rawValue) (\(latestPendingInvitations.count))")
                            .tag(subTab)
                    } else if subTab == .fromYou && !appState.invitationService.sentInvitations.isEmpty {
                        Text("\(subTab.rawValue) (\(appState.invitationService.sentInvitations.count))")
                            .tag(subTab)
                    } else {
                        Text(subTab.rawValue)
                            .tag(subTab)
                    }
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            switch selectedInvitationsSubTab {
            case .forYou:
                forYouContent
            case .fromYou:
                fromYouContent
            }
        }
    }

    // MARK: - For You (received invitations)

    /// Only show the latest invitation per sender, excluding already-connected contacts
    private var latestPendingInvitations: [Invitation] {
        let connectedUIDs = appState.connectionsService.allConnectionUIDs
        var latest: [String: Invitation] = [:]
        for invitation in appState.invitationService.pendingInvitations {
            // Skip invitations from users we're already connected with
            guard !connectedUIDs.contains(invitation.fromUID) else { continue }
            if let existing = latest[invitation.fromUID] {
                if invitation.createdAt > existing.createdAt {
                    latest[invitation.fromUID] = invitation
                }
            } else {
                latest[invitation.fromUID] = invitation
            }
        }
        return Array(latest.values).sorted { $0.createdAt > $1.createdAt }
    }

    private var forYouContent: some View {
        Group {
            if latestPendingInvitations.isEmpty {
                ContentUnavailableView(
                    "No Invitations",
                    systemImage: "envelope.open",
                    description: Text("When someone invites you to connect, it will appear here.")
                )
            } else {
                List {
                    ForEach(latestPendingInvitations) { invitation in
                        invitationRow(invitation: invitation)
                    }
                }
            }
        }
    }

    // MARK: - From You (sent invitations)

    private var fromYouContent: some View {
        Group {
            if appState.invitationService.sentInvitations.isEmpty {
                ContentUnavailableView(
                    "No Sent Invitations",
                    systemImage: "paperplane",
                    description: Text("Invitations you send will appear here until they're accepted.")
                )
            } else {
                List {
                    ForEach(appState.invitationService.sentInvitations) { invitation in
                        sentInvitationRow(invitation: invitation)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let invitation = appState.invitationService.sentInvitations[index]
                            Task {
                                try? await appState.invitationService.withdrawInvitation(invitation)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Invitation Row (received)

    private func invitationRow(invitation: Invitation) -> some View {
        Button {
            selectedInvitation = invitation
        } label: {
            HStack(spacing: 12) {
                AsyncProfileImage(url: invitation.fromProfilePhotoURL)
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(invitation.fromFullName)
                        .font(.body)
                        .foregroundStyle(.primary)

                    Text("Tap to view invitation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "envelope.badge")
                    .foregroundStyle(.blue)
            }
        }
    }

    // MARK: - Sent Invitation Row

    private func sentInvitationRow(invitation: Invitation) -> some View {
        Button {
            selectedSentInvitation = invitation
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "paperplane.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    if !invitation.howDoIKnow.isEmpty {
                        Text(invitation.howDoIKnow)
                            .font(.body)
                            .foregroundStyle(.primary)
                    }

                    Text(invitation.targetDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(invitation.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Connection Row

    private func connectionRow(connection: Connection) -> some View {
        Button {
            selectedConnection = connection
        } label: {
            HStack(spacing: 12) {
                AsyncProfileImage(url: connection.profilePhotoURL)
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
                    .opacity(connection.proximityPaused ? 0.5 : 1.0)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(connection.fullName)
                            .font(.body)
                            .foregroundStyle(.primary)

                        if connection.proximityPaused {
                            Image(systemName: "wifi.slash")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }

                    if !connection.howDoIKnow.isEmpty {
                        Text(connection.howDoIKnow)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
