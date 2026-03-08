import Foundation
import FirebaseFirestore

@Observable
final class InvitationService {
    private let db = Firestore.firestore()
    private(set) var pendingInvitations: [Invitation] = []
    private(set) var sentInvitations: [Invitation] = []
    private var pendingListener: ListenerRegistration?
    private var sentListener: ListenerRegistration?

    var pendingCount: Int { pendingInvitations.count }

    func startListening(forUser uid: String) {
        stopListening()

        // Listen for invitations sent TO me (pending)
        pendingListener = db.collection(FirestoreCollection.invitations)
            .whereField("toUID", isEqualTo: uid)
            .whereField("status", isEqualTo: InvitationStatus.pending.rawValue)
            .addSnapshotListener { [weak self] snapshot, error in
                if let error {
                    print("[InvitationService] pendingListener error: \(error.localizedDescription)")
                    return
                }
                guard let documents = snapshot?.documents else { return }
                self?.pendingInvitations = documents.compactMap { doc in
                    try? doc.data(as: Invitation.self)
                }
                print("[InvitationService] pendingInvitations count: \(documents.count)")
            }

        // Listen for invitations sent BY me (pending, most recent first)
        sentListener = db.collection(FirestoreCollection.invitations)
            .whereField("fromUID", isEqualTo: uid)
            .whereField("status", isEqualTo: InvitationStatus.pending.rawValue)
            .addSnapshotListener { [weak self] snapshot, error in
                if let error {
                    print("[InvitationService] sentListener error: \(error.localizedDescription)")
                    return
                }
                guard let documents = snapshot?.documents else { return }
                let invitations = documents.compactMap { doc in
                    try? doc.data(as: Invitation.self)
                }
                self?.sentInvitations = invitations.sorted { $0.createdAt > $1.createdAt }
                print("[InvitationService] sentInvitations count: \(documents.count)")
            }
    }

    func stopListening() {
        pendingListener?.remove()
        pendingListener = nil
        sentListener?.remove()
        sentListener = nil
        pendingInvitations = []
        sentInvitations = []
    }

    func sendInvitation(
        from currentUser: AppUser,
        toUser: AppUser?,
        toEmail: String?,
        toPhone: String?,
        message: String,
        howDoIKnow: String
    ) async throws {
        guard let myUID = currentUser.id else { return }

        // Build document data manually so nil fields are stored as explicit null
        // (Codable omits nil fields entirely, which breaks Firestore rules that check == null)
        var data: [String: Any] = [
            "fromUID": myUID,
            "fromFirstName": currentUser.firstName,
            "fromLastName": currentUser.lastName,
            "fromProfilePhotoURL": currentUser.profilePhotoURL as Any,
            "toUID": toUser?.id as Any,
            "toEmail": toEmail?.lowercased() as Any,
            "toPhone": toPhone as Any,
            "message": message,
            "howDoIKnow": howDoIKnow,
            "status": InvitationStatus.pending.rawValue,
            "createdAt": Date()
        ]

        // Ensure nil values are stored as NSNull so Firestore rules can check == null
        if toUser?.id == nil { data["toUID"] = NSNull() }
        if toEmail == nil { data["toEmail"] = NSNull() }
        if toPhone == nil { data["toPhone"] = NSNull() }
        if currentUser.profilePhotoURL == nil { data["fromProfilePhotoURL"] = NSNull() }

        print("[InvitationService] sendInvitation — fromUID: \(myUID), toUID: \(toUser?.id ?? "nil"), toEmail: \(toEmail ?? "nil"), toPhone: \(toPhone ?? "nil")")

        try await db.collection(FirestoreCollection.invitations)
            .addDocument(data: data)
    }

    func acceptInvitation(
        _ invitation: Invitation,
        accepterUser: AppUser,
        accepterNote: String
    ) async throws {
        guard let invitationId = invitation.id,
              let accepterUID = accepterUser.id else { return }

        // Re-fetch the invitation to check its current status
        let invRef = db.collection(FirestoreCollection.invitations).document(invitationId)
        let snapshot = try await invRef.getDocument()
        guard let currentInvitation = try? snapshot.data(as: Invitation.self) else {
            throw InvitationError.noLongerValid
        }

        guard currentInvitation.status == .pending else {
            throw InvitationError.noLongerValid
        }

        let batch = db.batch()

        // 1. Update invitation status to accepted
        batch.updateData([
            "status": InvitationStatus.accepted.rawValue,
            "respondedAt": FieldValue.serverTimestamp()
        ], forDocument: invRef)

        // 2. Create connection: inviter → accepter
        let inviterConnectionRef = db.collection(FirestoreCollection.users)
            .document(invitation.fromUID)
            .collection(FirestoreCollection.connections)
            .document(accepterUID)
        let inviterConnectionData: [String: Any] = [
            "userId": accepterUID,
            "firstName": accepterUser.firstName,
            "lastName": accepterUser.lastName,
            "profilePhotoURL": accepterUser.profilePhotoURL as Any,
            "howDoIKnow": invitation.howDoIKnow,
            "connectedAt": FieldValue.serverTimestamp(),
            "invitationId": invitationId
        ]
        batch.setData(inviterConnectionData, forDocument: inviterConnectionRef)

        // 3. Create connection: accepter → inviter
        let accepterConnectionRef = db.collection(FirestoreCollection.users)
            .document(accepterUID)
            .collection(FirestoreCollection.connections)
            .document(invitation.fromUID)
        let accepterConnectionData: [String: Any] = [
            "userId": invitation.fromUID,
            "firstName": invitation.fromFirstName,
            "lastName": invitation.fromLastName,
            "profilePhotoURL": invitation.fromProfilePhotoURL as Any,
            "howDoIKnow": accepterNote,
            "connectedAt": FieldValue.serverTimestamp(),
            "invitationId": invitationId
        ]
        batch.setData(accepterConnectionData, forDocument: accepterConnectionRef)

        try await batch.commit()
    }

    func declineInvitation(_ invitation: Invitation) async throws {
        guard let invitationId = invitation.id else { return }
        try await db.collection(FirestoreCollection.invitations)
            .document(invitationId)
            .updateData([
                "status": InvitationStatus.declined.rawValue,
                "respondedAt": FieldValue.serverTimestamp()
            ])
    }

    func withdrawInvitation(_ invitation: Invitation) async throws {
        guard let invitationId = invitation.id else { return }
        try await db.collection(FirestoreCollection.invitations)
            .document(invitationId)
            .updateData([
                "status": InvitationStatus.withdrawn.rawValue,
                "respondedAt": FieldValue.serverTimestamp()
            ])
    }

    // MARK: - Delete All Invitations (Account Deletion)

    /// Deletes ALL invitations sent by or to this user.
    /// Used during account deletion to clean up invitation records.
    func deleteAllInvitations(forUser uid: String) async throws {
        // Delete invitations sent BY this user
        let sentSnap = try await db.collection(FirestoreCollection.invitations)
            .whereField("fromUID", isEqualTo: uid)
            .getDocuments()
        print("[InvitationService] deleteAllInvitations — found \(sentSnap.documents.count) sent invitations")
        for doc in sentSnap.documents {
            try await doc.reference.delete()
        }

        // Delete invitations sent TO this user
        let receivedSnap = try await db.collection(FirestoreCollection.invitations)
            .whereField("toUID", isEqualTo: uid)
            .getDocuments()
        print("[InvitationService] deleteAllInvitations — found \(receivedSnap.documents.count) received invitations")
        for doc in receivedSnap.documents {
            try await doc.reference.delete()
        }

        print("[InvitationService] deleteAllInvitations — completed for uid: \(uid)")
    }

    /// Called after registration/login to claim invitations sent before this user registered
    func claimPendingInvitations(uid: String, email: String?, phone: String?) async throws {
        print("[InvitationService] claimPendingInvitations called — uid: \(uid), email: \(email ?? "nil"), phone: \(phone ?? "nil")")
        var documents: [QueryDocumentSnapshot] = []

        if let email = email {
            let snap = try await db.collection(FirestoreCollection.invitations)
                .whereField("toEmail", isEqualTo: email.lowercased())
                .whereField("status", isEqualTo: InvitationStatus.pending.rawValue)
                .getDocuments()
            print("[InvitationService] claim query (email) returned \(snap.documents.count) docs")
            for doc in snap.documents {
                let toUID = doc.data()["toUID"]
                let hasNoUID = toUID is NSNull || toUID == nil
                print("[InvitationService]   doc \(doc.documentID): toUID=\(String(describing: toUID)), claimable=\(hasNoUID)")
            }
            // Only claim those that don't already have a toUID
            documents.append(contentsOf: snap.documents.filter { doc in
                let toUID = doc.data()["toUID"]
                return toUID is NSNull || toUID == nil
            })
        }

        if let phone = phone {
            let snap = try await db.collection(FirestoreCollection.invitations)
                .whereField("toPhone", isEqualTo: phone)
                .whereField("status", isEqualTo: InvitationStatus.pending.rawValue)
                .getDocuments()
            print("[InvitationService] claim query (phone) returned \(snap.documents.count) docs")
            documents.append(contentsOf: snap.documents.filter { doc in
                let toUID = doc.data()["toUID"]
                return toUID is NSNull || toUID == nil
            })
        }

        print("[InvitationService] total claimable documents: \(documents.count)")
        guard !documents.isEmpty else { return }

        let batch = db.batch()
        for doc in documents {
            batch.updateData(["toUID": uid], forDocument: doc.reference)
        }
        try await batch.commit()
        print("[InvitationService] claimed \(documents.count) invitations for uid: \(uid)")
    }
}
