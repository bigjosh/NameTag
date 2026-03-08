import Foundation
import FirebaseFirestore

@Observable
final class MessagingService {
    private let db = Firestore.firestore()
    private(set) var conversations: [Conversation] = []
    private(set) var currentMessages: [Message] = []
    private var conversationsListener: ListenerRegistration?
    private var messagesListener: ListenerRegistration?
    private var currentUID: String?

    /// Number of conversations with unread messages
    var unreadCount: Int {
        guard let uid = currentUID else { return 0 }
        return conversations.filter { $0.isUnread(currentUID: uid) }.count
    }

    // MARK: - Conversations Listener (Inbox)

    func startListening(forUser uid: String) {
        stopListening()
        currentUID = uid

        conversationsListener = db.collection(FirestoreCollection.conversations)
            .whereField("participantUIDs", arrayContains: uid)
            .order(by: "lastMessageTimestamp", descending: true)
            .addSnapshotListener { [weak self] snapshot, error in
                if let error {
                    print("[MessagingService] conversationsListener error: \(error.localizedDescription)")
                    return
                }
                guard let documents = snapshot?.documents else { return }
                self?.conversations = documents.compactMap { doc in
                    try? doc.data(as: Conversation.self)
                }
                print("[MessagingService] conversations count: \(documents.count)")
            }
    }

    func stopListening() {
        conversationsListener?.remove()
        conversationsListener = nil
        stopListeningToMessages()
        conversations = []
        currentUID = nil
    }

    // MARK: - Messages Listener (Single Conversation)

    func startListeningToMessages(conversationID: String) {
        stopListeningToMessages()

        messagesListener = db.collection(FirestoreCollection.conversations)
            .document(conversationID)
            .collection(FirestoreCollection.messages)
            .order(by: "sentAt", descending: false)
            .limit(toLast: 100)
            .addSnapshotListener { [weak self] snapshot, error in
                if let error {
                    print("[MessagingService] messagesListener error: \(error.localizedDescription)")
                    return
                }
                guard let documents = snapshot?.documents else { return }
                self?.currentMessages = documents.compactMap { doc in
                    try? doc.data(as: Message.self)
                }
            }
    }

    func stopListeningToMessages() {
        messagesListener?.remove()
        messagesListener = nil
        currentMessages = []
    }

    // MARK: - Mark as Read

    func markConversationRead(conversationID: String, uid: String) async {
        do {
            try await db.collection(FirestoreCollection.conversations)
                .document(conversationID)
                .updateData([
                    "lastReadBy.\(uid)": Date()
                ])
        } catch {
            // Silently fail — conversation doc may not exist yet (no messages sent)
            print("[MessagingService] markConversationRead failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Delete Conversation

    func deleteConversation(myUID: String, otherUID: String) async throws {
        let conversationID = Conversation.conversationID(uid1: myUID, uid2: otherUID)
        let conversationRef = db.collection(FirestoreCollection.conversations).document(conversationID)

        // Delete all messages in the subcollection
        let messagesSnap = try await conversationRef
            .collection(FirestoreCollection.messages)
            .getDocuments()

        for doc in messagesSnap.documents {
            try await doc.reference.delete()
        }

        // Delete the conversation document itself
        try await conversationRef.delete()

        print("[MessagingService] deleted conversation \(conversationID)")
    }

    // MARK: - Delete All Conversations (Account Deletion)

    /// Deletes ALL conversations where the user is a participant, including all messages.
    /// Used during account deletion to clean up conversations from other users' inboxes.
    func deleteAllConversations(forUser uid: String) async throws {
        let snapshot = try await db.collection(FirestoreCollection.conversations)
            .whereField("participantUIDs", arrayContains: uid)
            .getDocuments()

        print("[MessagingService] deleteAllConversations — found \(snapshot.documents.count) conversations for uid: \(uid)")

        for doc in snapshot.documents {
            // Delete the conversation document FIRST so it immediately disappears
            // from other users' snapshot listeners
            try? await doc.reference.delete()

            // Best-effort cleanup of messages subcollection
            let messagesSnap = try? await doc.reference
                .collection(FirestoreCollection.messages)
                .getDocuments()
            for msgDoc in messagesSnap?.documents ?? [] {
                try? await msgDoc.reference.delete()
            }
        }

        print("[MessagingService] deleteAllConversations — completed for uid: \(uid)")
    }

    // MARK: - Cleanup Orphaned Conversations (Ghost Cleanup)

    /// Removes conversations where the other participant's account no longer exists.
    /// Queries Firestore directly instead of relying on the in-memory listener data.
    /// Uses raw document data (not Codable) to avoid silent decoding failures.
    func cleanupOrphanedConversations(currentUID: String, userService: UserService) async {
        print("[MessagingService] cleanupOrphanedConversations — START for uid: \(currentUID)")

        // Query Firestore directly — don't rely on snapshot listener which may not have fired yet
        let snapshot: QuerySnapshot
        do {
            snapshot = try await db.collection(FirestoreCollection.conversations)
                .whereField("participantUIDs", arrayContains: currentUID)
                .getDocuments()
        } catch {
            print("[MessagingService] cleanupOrphanedConversations — query failed: \(error)")
            return
        }

        print("[MessagingService] cleanupOrphanedConversations — raw query returned \(snapshot.documents.count) documents")

        // Extract conversation ID + other participant UID directly from raw data
        // (avoids Codable decoding issues that could silently drop conversations)
        var conversationPartners: [(docID: String, otherUID: String)] = []
        for doc in snapshot.documents {
            let data = doc.data()
            let participants = data["participantUIDs"] as? [String] ?? []
            print("[MessagingService] cleanupOrphanedConversations — doc: \(doc.documentID), participants: \(participants)")

            guard let otherUID = participants.first(where: { $0 != currentUID }) else {
                print("[MessagingService] cleanupOrphanedConversations — could not find otherUID in \(doc.documentID)")
                continue
            }
            conversationPartners.append((docID: doc.documentID, otherUID: otherUID))
        }

        print("[MessagingService] cleanupOrphanedConversations — checking \(conversationPartners.count) conversations")

        // Check which conversation partners still exist (concurrently)
        let orphans: [(docID: String, otherUID: String)] = await withTaskGroup(
            of: (String, String, Bool).self
        ) { group in
            for conv in conversationPartners {
                group.addTask { (conv.docID, conv.otherUID, await userService.userExists(uid: conv.otherUID)) }
            }
            var result: [(docID: String, otherUID: String)] = []
            for await (docID, otherUID, exists) in group {
                print("[MessagingService] cleanupOrphanedConversations — otherUID: \(otherUID) exists=\(exists)")
                if !exists { result.append((docID: docID, otherUID: otherUID)) }
            }
            return result
        }

        print("[MessagingService] cleanupOrphanedConversations — found \(orphans.count) orphaned conversations to delete")

        // Delete orphaned conversations and their messages
        for orphan in orphans {
            let conversationRef = db.collection(FirestoreCollection.conversations)
                .document(orphan.docID)

            // Delete the conversation document FIRST — this immediately removes it from
            // the snapshot listener so the UI updates. Even if message subcollection
            // deletion fails (due to security rules), the conversation will no longer
            // appear in queries since the parent doc is gone.
            do {
                try await conversationRef.delete()
                print("[MessagingService] Removed orphaned conversation doc: \(orphan.docID) (other user: \(orphan.otherUID))")
            } catch {
                print("[MessagingService] Failed to delete conversation doc \(orphan.docID): \(error)")
                continue // If we can't delete the parent, skip message cleanup too
            }

            // Best-effort cleanup of messages subcollection.
            // If security rules block this, the orphaned messages are harmless —
            // they're invisible since the parent conversation doc no longer exists.
            do {
                let messagesSnap = try await conversationRef
                    .collection(FirestoreCollection.messages).getDocuments()
                print("[MessagingService] cleanupOrphanedConversations — deleting \(messagesSnap.documents.count) orphaned messages from \(orphan.docID)")
                for doc in messagesSnap.documents {
                    try? await doc.reference.delete()
                }
            } catch {
                print("[MessagingService] Could not clean up messages for \(orphan.docID) (harmless): \(error.localizedDescription)")
            }
        }

        print("[MessagingService] cleanupOrphanedConversations — DONE (\(orphans.count) removed)")
    }

    // MARK: - Send Message

    func sendMessage(
        text: String,
        from senderUID: String,
        to recipientUID: String,
        senderName: String,
        senderPhotoURL: String?,
        recipientName: String,
        recipientPhotoURL: String?
    ) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let conversationID = Conversation.conversationID(uid1: senderUID, uid2: recipientUID)
        let conversationRef = db.collection(FirestoreCollection.conversations).document(conversationID)
        let messagesRef = conversationRef.collection(FirestoreCollection.messages)

        let now = Date()

        // Create/update conversation document FIRST so the messages subcollection
        // read rules can reference the parent document's participantUIDs
        let conversationData: [String: Any] = [
            "participantUIDs": [senderUID, recipientUID],
            "lastMessageText": trimmedText,
            "lastMessageSenderUID": senderUID,
            "lastMessageTimestamp": now,
            "participantNames": [
                senderUID: senderName,
                recipientUID: recipientName
            ],
            "participantPhotos": [
                senderUID: senderPhotoURL ?? "",
                recipientUID: recipientPhotoURL ?? ""
            ]
        ]
        try await conversationRef.setData(conversationData, merge: true)

        // Then create the message document
        let message = Message(senderUID: senderUID, text: trimmedText, sentAt: now)
        try messagesRef.addDocument(from: message)

        print("[MessagingService] sent message from \(senderUID) to \(recipientUID)")
    }
}
