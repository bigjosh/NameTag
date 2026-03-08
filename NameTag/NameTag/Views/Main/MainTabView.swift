import SwiftUI

struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: String = "nearby"

    /// Pending invitations excluding already-connected contacts, deduplicated per sender
    private var actionableInvitationCount: Int {
        let connectedUIDs = appState.connectionsService.allConnectionUIDs
        var seenSenders: Set<String> = []
        var count = 0
        for invitation in appState.invitationService.pendingInvitations {
            guard !connectedUIDs.contains(invitation.fromUID) else { continue }
            if seenSenders.insert(invitation.fromUID).inserted {
                count += 1
            }
        }
        return count
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Nearby", systemImage: "person.2.wave.2", value: "nearby") {
                CardStackView()
            }

            Tab("Contacts", systemImage: "person.crop.rectangle.stack", value: "contacts") {
                ContactsListView()
            }
            .badge(actionableInvitationCount)

            Tab("Messages", systemImage: "bubble.left.and.bubble.right", value: "messages") {
                MessagesListView()
            }
            .badge(appState.messagingService.unreadCount)

            Tab("Profile", systemImage: "person.circle", value: "profile") {
                ProfileView()
            }
        }
        .onChange(of: selectedTab, initial: true) { _, newTab in
            appState.notificationGatekeeper.isOnNearbyTab = (newTab == "nearby")
        }
        .onChange(of: appState.connectionsService.connectionUIDs, initial: true) { _, newUIDs in
            appState.bleService.updateConnectionUIDs(newUIDs)
            appState.multipeerService.updateConnectionUIDs(newUIDs)
            appState.bonjourService.updateConnectionUIDs(newUIDs)
            appState.locationService.updateConnectionUIDs(newUIDs)
        }
        .onChange(of: appState.connectionsService.connections, initial: true) { _, connections in
            let names = Dictionary(
                uniqueKeysWithValues: connections.map { ($0.userId, $0.fullName) }
            )
            appState.notificationGatekeeper.connectionNames = names
        }
    }
}
