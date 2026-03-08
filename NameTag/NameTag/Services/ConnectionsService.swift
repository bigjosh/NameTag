import Foundation
import FirebaseFirestore

@Observable
final class ConnectionsService {
    private let db = Firestore.firestore()
    private(set) var connections: [Connection] = []
    private var listener: ListenerRegistration?

    /// UIDs of all connections (including paused) — used for data operations
    var allConnectionUIDs: Set<String> {
        Set(connections.map(\.userId))
    }

    /// UIDs of active (non-paused) connections — used for proximity detection
    var connectionUIDs: Set<String> {
        Set(connections.filter { !$0.proximityPaused }.map(\.userId))
    }

    func startListening(forUser uid: String) {
        stopListening()
        listener = db.collection(FirestoreCollection.users)
            .document(uid)
            .collection(FirestoreCollection.connections)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let documents = snapshot?.documents else { return }
                self?.connections = documents.compactMap { doc in
                    try? doc.data(as: Connection.self)
                }
            }
    }

    func stopListening() {
        listener?.remove()
        listener = nil
        connections = []
    }

    /// Updates this user's profile info (photo, name) in all their connections' documents.
    /// Called after the user updates their profile so other users see the changes on tiles.
    func updateProfileInConnections(myUID: String, firstName: String, lastName: String, profilePhotoURL: String?) async {
        for connection in connections {
            let ref = db.collection(FirestoreCollection.users)
                .document(connection.userId)
                .collection(FirestoreCollection.connections)
                .document(myUID)
            var data: [String: Any] = [
                "firstName": firstName,
                "lastName": lastName
            ]
            if let url = profilePhotoURL {
                data["profilePhotoURL"] = url
            } else {
                data["profilePhotoURL"] = NSNull()
            }
            try? await ref.updateData(data)
        }
    }

    func updateHowDoIKnow(myUID: String, connectionUID: String, howDoIKnow: String) async throws {
        try await db.collection(FirestoreCollection.users)
            .document(myUID)
            .collection(FirestoreCollection.connections)
            .document(connectionUID)
            .updateData(["howDoIKnow": howDoIKnow])
    }

    func togglePause(myUID: String, connectionUID: String, paused: Bool) async throws {
        // Update my side
        try await db.collection(FirestoreCollection.users)
            .document(myUID)
            .collection(FirestoreCollection.connections)
            .document(connectionUID)
            .updateData(["isPaused": paused])

        // Update the other user's side so their device also hides/shows the tile
        try? await db.collection(FirestoreCollection.users)
            .document(connectionUID)
            .collection(FirestoreCollection.connections)
            .document(myUID)
            .updateData(["isPaused": paused])
    }

    /// Removes connections where the other user's account no longer exists in Firestore.
    func cleanupOrphanedConnections(myUID: String, userService: UserService) async {
        let orphanedUIDs: [String] = await withTaskGroup(of: (String, Bool).self) { group in
            for connection in connections {
                let uid = connection.userId
                group.addTask { (uid, await userService.userExists(uid: uid)) }
            }
            var result: [String] = []
            for await (uid, exists) in group {
                if !exists { result.append(uid) }
            }
            return result
        }

        for orphanedUID in orphanedUIDs {
            try? await removeConnection(myUID: myUID, connectionUID: orphanedUID)
            print("[ConnectionsService] Removed orphaned connection: \(orphanedUID)")
        }
    }

    func removeConnection(myUID: String, connectionUID: String) async throws {
        // Remove my side of the connection
        try await db.collection(FirestoreCollection.users)
            .document(myUID)
            .collection(FirestoreCollection.connections)
            .document(connectionUID)
            .delete()

        // Also remove the other side
        try await db.collection(FirestoreCollection.users)
            .document(connectionUID)
            .collection(FirestoreCollection.connections)
            .document(myUID)
            .delete()
    }
}
