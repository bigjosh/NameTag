import Foundation
import FirebaseFirestore
import FirebaseStorage

@Observable
final class AdminService {
    private let db = Firestore.firestore()
    private let storage = Storage.storage()

    // MARK: - Admin User Search (ignores privacy flags)

    func searchAllUsers(query: String) async throws -> [AppUser] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Classify query type
        if trimmed.contains("@") {
            return try await searchByEmail(trimmed)
        }

        let digits = trimmed.filter(\.isNumber)
        if digits.count >= 10 && digits.count <= 11 {
            return try await searchByPhone(trimmed)
        }

        return try await searchByName(trimmed)
    }

    private func searchByEmail(_ email: String) async throws -> [AppUser] {
        let snapshot = try await db.collection(FirestoreCollection.users)
            .whereField("searchableEmail", isEqualTo: email.lowercased())
            .limit(to: 10)
            .getDocuments()
        return try snapshot.documents.map { try $0.data(as: AppUser.self) }
    }

    private func searchByPhone(_ phone: String) async throws -> [AppUser] {
        var digits = phone.filter(\.isNumber)
        if digits.count == 11 && digits.hasPrefix("1") {
            digits = String(digits.dropFirst())
        }
        let snapshot = try await db.collection(FirestoreCollection.users)
            .whereField("searchablePhone", isEqualTo: digits)
            .limit(to: 10)
            .getDocuments()
        return try snapshot.documents.map { try $0.data(as: AppUser.self) }
    }

    private func searchByName(_ name: String) async throws -> [AppUser] {
        let words = name.lowercased().split(separator: " ").map(String.init)
        guard let firstWord = words.first else { return [] }

        let usersCol = db.collection(FirestoreCollection.users)
        let endPrefix = firstWord + "\u{f8ff}"

        let firstNameSnap = try await usersCol
            .whereField("searchableFirstName", isGreaterThanOrEqualTo: firstWord)
            .whereField("searchableFirstName", isLessThan: endPrefix)
            .limit(to: 20)
            .getDocuments()

        let lastNameSnap = try await usersCol
            .whereField("searchableLastName", isGreaterThanOrEqualTo: firstWord)
            .whereField("searchableLastName", isLessThan: endPrefix)
            .limit(to: 20)
            .getDocuments()

        let extraWords = Array(words.dropFirst())
        var seen = Set<String>()
        var results: [AppUser] = []

        for doc in firstNameSnap.documents + lastNameSnap.documents {
            let user = try doc.data(as: AppUser.self)
            guard let uid = user.id, !seen.contains(uid) else { continue }

            if !extraWords.isEmpty {
                let fullName = "\(user.searchableFirstName ?? "") \(user.searchableLastName ?? "")"
                guard extraWords.allSatisfy({ fullName.contains($0) }) else { continue }
            }

            seen.insert(uid)
            results.append(user)
        }

        return results
    }

    // MARK: - Conversation Viewing

    func fetchConversations(forUser uid: String) async throws -> [Conversation] {
        let snapshot = try await db.collection(FirestoreCollection.conversations)
            .whereField("participantUIDs", arrayContains: uid)
            .order(by: "lastMessageTimestamp", descending: true)
            .getDocuments()
        return try snapshot.documents.map { try $0.data(as: Conversation.self) }
    }

    func fetchMessages(conversationID: String) async throws -> [Message] {
        let snapshot = try await db.collection(FirestoreCollection.conversations)
            .document(conversationID)
            .collection(FirestoreCollection.messages)
            .order(by: "sentAt", descending: false)
            .getDocuments()
        return try snapshot.documents.map { try $0.data(as: Message.self) }
    }

    // MARK: - Ban Execution

    func banUser(targetUID: String, targetUser: AppUser, reason: String, adminUID: String) async throws {
        let usersCol = db.collection(FirestoreCollection.users)

        // Step 1: Create bannedUsers record (critical — do first)
        let bannedUser = BannedUser(
            id: targetUID,
            email: targetUser.email?.lowercased(),
            phone: targetUser.searchablePhone,
            firstName: targetUser.firstName,
            lastName: targetUser.lastName,
            originalUID: targetUID,
            reason: reason,
            bannedAt: Date(),
            bannedBy: adminUID
        )
        try db.collection(FirestoreCollection.bannedUsers)
            .document(targetUID)
            .setData(from: bannedUser)

        // Step 2: Mark user as banned (triggers real-time listener on their device)
        try await usersCol.document(targetUID).updateData(["isBanned": true])

        // Step 3: Delete all conversations involving this user
        let convSnap = try? await db.collection(FirestoreCollection.conversations)
            .whereField("participantUIDs", arrayContains: targetUID)
            .getDocuments()
        if let convDocs = convSnap?.documents {
            for doc in convDocs {
                // Delete messages subcollection first
                let msgSnap = try? await doc.reference
                    .collection(FirestoreCollection.messages)
                    .getDocuments()
                if let msgDocs = msgSnap?.documents {
                    for msgDoc in msgDocs {
                        try? await msgDoc.reference.delete()
                    }
                }
                // Delete conversation document
                try? await doc.reference.delete()
            }
        }

        // Step 4: Delete all invitations sent by or to this user
        let sentSnap = try? await db.collection(FirestoreCollection.invitations)
            .whereField("fromUID", isEqualTo: targetUID)
            .getDocuments()
        for doc in sentSnap?.documents ?? [] {
            try? await doc.reference.delete()
        }

        let receivedSnap = try? await db.collection(FirestoreCollection.invitations)
            .whereField("toUID", isEqualTo: targetUID)
            .getDocuments()
        for doc in receivedSnap?.documents ?? [] {
            try? await doc.reference.delete()
        }

        // Step 5: Delete profile photo from Storage
        let photoRef = storage.reference()
            .child(StoragePath.profilePhotos)
            .child(targetUID)
            .child("profile.jpg")
        try? await photoRef.delete()

        // Step 6: Delete all connections (both sides)
        let connSnap = try? await usersCol.document(targetUID)
            .collection(FirestoreCollection.connections).getDocuments()
        for doc in connSnap?.documents ?? [] {
            // Remove the other user's connection to the banned user
            try? await usersCol.document(doc.documentID)
                .collection(FirestoreCollection.connections).document(targetUID).delete()
            // Remove the banned user's connection doc
            try? await doc.reference.delete()
        }

        // Step 7: Scrub user document (keep alive with isBanned = true)
        try? await usersCol.document(targetUID).updateData([
            "profilePhotoURL": FieldValue.delete(),
            "firstName": "Deleted",
            "lastName": "User",
            "phone": FieldValue.delete(),
            "searchableEmail": FieldValue.delete(),
            "searchablePhone": FieldValue.delete(),
            "searchableFirstName": FieldValue.delete(),
            "searchableLastName": FieldValue.delete(),
            "emailSearchable": false,
            "phoneSearchable": false
        ])

        print("[AdminService] User \(targetUID) banned successfully")
    }

    // MARK: - Un-Ban Execution

    func unbanUser(targetUID: String) async throws {
        // Step 1: Read the bannedUser record to get original name/email/phone
        let bannedDoc = try await db.collection(FirestoreCollection.bannedUsers)
            .document(targetUID).getDocument()
        let bannedUser = try? bannedDoc.data(as: BannedUser.self)

        // Step 2: Restore the user document with original data (if doc still exists)
        let userDoc = try? await db.collection(FirestoreCollection.users)
            .document(targetUID).getDocument()
        if userDoc?.exists == true {
            var updates: [String: Any] = ["isBanned": false]

            if let banned = bannedUser {
                updates["firstName"] = banned.firstName
                updates["lastName"] = banned.lastName
                updates["searchableFirstName"] = banned.firstName.lowercased()
                updates["searchableLastName"] = banned.lastName.lowercased()

                if let email = banned.email, !email.isEmpty {
                    updates["searchableEmail"] = email.lowercased()
                    updates["emailSearchable"] = true
                }

                if let phone = banned.phone, !phone.isEmpty {
                    updates["searchablePhone"] = phone
                    updates["phoneSearchable"] = true
                }
            }

            try? await db.collection(FirestoreCollection.users)
                .document(targetUID).updateData(updates)
        }

        // Step 3: Remove from bannedUsers collection (after restoring data)
        try await db.collection(FirestoreCollection.bannedUsers)
            .document(targetUID).delete()

        print("[AdminService] User \(targetUID) un-banned — profile restored")
    }

    // MARK: - Ban Status Checks

    func isEmailBanned(_ email: String) async throws -> Bool {
        let snapshot = try await db.collection(FirestoreCollection.bannedUsers)
            .whereField("email", isEqualTo: email.lowercased())
            .limit(to: 1)
            .getDocuments()
        return !snapshot.documents.isEmpty
    }

    func isPhoneBanned(_ phone: String) async throws -> Bool {
        var digits = phone.filter(\.isNumber)
        if digits.count == 11 && digits.hasPrefix("1") {
            digits = String(digits.dropFirst())
        }
        guard !digits.isEmpty else { return false }

        let snapshot = try await db.collection(FirestoreCollection.bannedUsers)
            .whereField("phone", isEqualTo: digits)
            .limit(to: 1)
            .getDocuments()
        return !snapshot.documents.isEmpty
    }

    func isUIDBanned(_ uid: String) async throws -> Bool {
        let doc = try await db.collection(FirestoreCollection.bannedUsers)
            .document(uid).getDocument()
        return doc.exists
    }

    // MARK: - Fetch Banned Users

    func fetchBannedUsers() async throws -> [BannedUser] {
        let snapshot = try await db.collection(FirestoreCollection.bannedUsers)
            .order(by: "bannedAt", descending: true)
            .getDocuments()
        return try snapshot.documents.map { try $0.data(as: BannedUser.self) }
    }
}
