import Foundation
import FirebaseFirestore

@Observable
final class AppState {
    let authService = AuthService()
    let userService = UserService()
    let storageService = StorageService()
    let connectionsService = ConnectionsService()
    let invitationService = InvitationService()
    let messagingService = MessagingService()
    let bleService = BLEService()
    let multipeerService = MultipeerService()
    let bonjourService = BonjourService()
    let locationService = LocationService()
    let notificationGatekeeper = NotificationGatekeeper()
    let pushNotificationService = PushNotificationService()
    let adminService = AdminService()

    private var isSettingUp = false
    private var lastAuthenticatedUID: String?
    private var banListener: ListenerRegistration?

    /// Whether the current user has been banned
    private(set) var isBanned = false

    /// Whether the current user is an admin
    var isAdmin: Bool {
        guard let uid = authService.currentUID else { return false }
        return Admin.isAdmin(uid)
    }

    var hasCompletedOnboarding: Bool {
        authService.isAuthenticated && userService.currentAppUser != nil
    }

    func onAuthenticated() async {
        guard let uid = authService.currentUID else { return }

        // If currently set up for a DIFFERENT user, clean up stale state first
        if let lastUID = lastAuthenticatedUID, lastUID != uid {
            print("[AppState] WARNING: UID changed from \(lastUID) to \(uid). Cleaning up stale state.")
            lastAuthenticatedUID = nil
            stopAllServices()
            userService.clearCurrentUser()
        }

        // Prevent duplicate concurrent calls
        guard !isSettingUp else {
            print("[AppState] onAuthenticated — already in progress, skipping")
            return
        }

        // Skip if we've already set up for this UID
        if lastAuthenticatedUID == uid && userService.currentAppUser != nil {
            print("[AppState] onAuthenticated — already set up for \(uid), skipping")
            return
        }

        isSettingUp = true
        defer { isSettingUp = false }

        print("[AppState] onAuthenticated — uid: \(uid)")

        // Check if this UID is banned before proceeding
        if let uidBanned = try? await adminService.isUIDBanned(uid), uidBanned {
            print("[AppState] User \(uid) is banned — blocking access")
            isBanned = true
            return
        }

        do {
            try await userService.fetchCurrentUser(uid: uid)
            print("[AppState] fetchCurrentUser succeeded — email: \(userService.currentAppUser?.email ?? "nil")")
        } catch {
            print("[AppState] fetchCurrentUser FAILED: \(error.localizedDescription)")
            return
        }

        // Check isBanned flag on user document
        if userService.currentAppUser?.isBanned == true {
            print("[AppState] User \(uid) isBanned flag is true — blocking access")
            isBanned = true
            return
        }

        // Start real-time listener for ban detection while app is running
        startBanListener(uid: uid)

        connectionsService.startListening(forUser: uid)
        invitationService.startListening(forUser: uid)
        messagingService.startListening(forUser: uid)

        // Background tasks: sync profile to connections + clean up orphaned data
        let connectionsService = self.connectionsService
        let messagingService = self.messagingService
        let userService = self.userService
        let currentUser = userService.currentAppUser
        Task {
            // Wait for snapshot listeners to populate initial data
            try? await Task.sleep(for: .seconds(2))

            // Sync current profile photo/name to all connection documents
            if let user = currentUser {
                await connectionsService.updateProfileInConnections(
                    myUID: uid,
                    firstName: user.firstName,
                    lastName: user.lastName,
                    profilePhotoURL: user.profilePhotoURL
                )
            }

            await connectionsService.cleanupOrphanedConnections(
                myUID: uid, userService: userService
            )
            await messagingService.cleanupOrphanedConversations(
                currentUID: uid, userService: userService
            )
        }

        // Claim any invitations sent before this user registered
        if let user = userService.currentAppUser {
            do {
                try await invitationService.claimPendingInvitations(
                    uid: uid, email: user.email, phone: user.phone
                )
            } catch {
                print("[AppState] claimPendingInvitations FAILED: \(error.localizedDescription)")
            }
        } else {
            print("[AppState] WARNING: currentAppUser is nil, skipping claimPendingInvitations")
        }

        let connectionUIDs = connectionsService.connectionUIDs

        bleService.configure(userID: uid, connectionUIDs: connectionUIDs)
        bleService.startDiscovery()

        multipeerService.configure(userID: uid, connectionUIDs: connectionUIDs)
        multipeerService.startDiscovery()

        bonjourService.configure(userID: uid, connectionUIDs: connectionUIDs)
        bonjourService.startDiscovery()

        locationService.configure(userID: uid, connectionUIDs: connectionUIDs)
        locationService.startDiscovery()

        // Wire proximity service callbacks through the centralized notification gatekeeper
        let gatekeeper = notificationGatekeeper
        bleService.onContactDiscovered = { uid in
            gatekeeper.notifyIfAllowed(uid: uid)
        }
        multipeerService.onContactDiscovered = { uid in
            gatekeeper.notifyIfAllowed(uid: uid)
        }
        bonjourService.onContactDiscovered = { uid in
            gatekeeper.notifyIfAllowed(uid: uid)
        }
        locationService.onContactDiscovered = { uid in
            gatekeeper.notifyIfAllowed(uid: uid)
        }
        locationService.onDistancesUpdated = { distances in
            gatekeeper.updateDistances(distances)
        }

        // Configure FCM push notifications for silent wake-ups
        pushNotificationService.configure(userID: uid)

        lastAuthenticatedUID = uid
    }

    func onSignOut() {
        lastAuthenticatedUID = nil
        stopAllServices()
        bleService.clearPersistedConfig()
        pushNotificationService.clearToken()
        notificationGatekeeper.reset()
        userService.clearCurrentUser()
        isBanned = false
        try? authService.signOut()
    }

    func deleteAccount() async throws {
        guard let uid = authService.currentUID else { return }

        // Stop all discovery and listeners first
        stopAllServices()
        bleService.clearPersistedConfig()
        pushNotificationService.clearToken()

        // Delete all conversations and messages (so other users no longer see them)
        try? await messagingService.deleteAllConversations(forUser: uid)

        // Delete all invitations (sent and received)
        try? await invitationService.deleteAllInvitations(forUser: uid)

        // Delete remote data (storage, Firestore user + connections, then Auth)
        try? await storageService.deleteProfilePhoto(uid: uid)
        try await userService.deleteUser(uid: uid)
        try await authService.deleteAccount()

        userService.clearCurrentUser()
        lastAuthenticatedUID = nil
    }

    /// Re-check all currently nearby contacts through the notification gatekeeper.
    /// Call this when a suppression condition is lifted (e.g., user leaves the Nearby tab
    /// or the app enters the background) so contacts that were discovered while suppressed
    /// can now trigger notifications.
    func recheckNearbyNotifications() {
        let allNearbyUIDs = Set(bleService.nearbyUserIDs.keys)
            .union(multipeerService.nearbyUserIDs.keys)
            .union(bonjourService.nearbyUserIDs.keys)
            .union(locationService.nearbyUserIDs.keys)

        guard !allNearbyUIDs.isEmpty else { return }
        print("[AppState] Rechecking \(allNearbyUIDs.count) nearby contacts for notifications")

        for uid in allNearbyUIDs {
            notificationGatekeeper.notifyIfAllowed(uid: uid)
        }
    }

    /// Restart services that get suspended by iOS when the app is backgrounded.
    /// Call this when the app returns to the foreground.
    func resumeForegroundServices() {
        guard lastAuthenticatedUID != nil else { return }

        // Multipeer and Bonjour are suspended by iOS in the background —
        // restart them so they immediately re-detect nearby devices.
        multipeerService.startDiscovery()
        bonjourService.startDiscovery()

        // BLE scan persists in background but can become stale — restart
        // to get fresh discoveries with allowDuplicates active again.
        bleService.startScanning()

        print("[AppState] Foreground services resumed (Multipeer, Bonjour, BLE scan)")
    }

    // MARK: - Private

    private func startBanListener(uid: String) {
        banListener?.remove()
        banListener = Firestore.firestore()
            .collection(FirestoreCollection.users)
            .document(uid)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let data = snapshot?.data(),
                      let banned = data["isBanned"] as? Bool,
                      banned else { return }
                print("[AppState] Ban detected via real-time listener — locking out user")
                self?.isBanned = true
                self?.stopAllServices()
            }
    }

    private func stopAllServices() {
        banListener?.remove()
        banListener = nil
        bleService.stopAll()
        multipeerService.stopAll()
        bonjourService.stopAll()
        locationService.stopAll()
        connectionsService.stopListening()
        invitationService.stopListening()
        messagingService.stopListening()
    }
}
