import Foundation
import FirebaseFirestore

enum UserServiceError: LocalizedError {
    case missingUID
    case userNotFound

    var errorDescription: String? {
        switch self {
        case .missingUID:
            return "Failed to create user: missing user ID."
        case .userNotFound:
            return "User profile not found."
        }
    }
}

@Observable
final class UserService {
    private let db = Firestore.firestore()
    private(set) var currentAppUser: AppUser?

    func clearCurrentUser() {
        currentAppUser = nil
    }

    func createUser(_ user: AppUser) async throws {
        guard let uid = user.id else {
            throw UserServiceError.missingUID
        }
        try db.collection(FirestoreCollection.users).document(uid).setData(from: user)
    }

    func fetchUser(uid: String) async throws -> AppUser {
        let snapshot = try await db.collection(FirestoreCollection.users).document(uid).getDocument()
        guard snapshot.exists else {
            throw UserServiceError.userNotFound
        }
        return try snapshot.data(as: AppUser.self)
    }

    func fetchCurrentUser(uid: String) async throws {
        currentAppUser = try await fetchUser(uid: uid)

        // Backfill searchable name fields for users created before this feature
        if let user = currentAppUser,
           user.searchableFirstName == nil || user.searchableLastName == nil {
            let updates: [String: Any] = [
                "searchableFirstName": user.firstName.lowercased(),
                "searchableLastName": user.lastName.lowercased()
            ]
            try? await db.collection(FirestoreCollection.users).document(uid).updateData(updates)
            currentAppUser?.searchableFirstName = user.firstName.lowercased()
            currentAppUser?.searchableLastName = user.lastName.lowercased()
        }
    }

    func updateProfile(uid: String, firstName: String, lastName: String) async throws {
        try await db.collection(FirestoreCollection.users).document(uid).updateData([
            "firstName": firstName,
            "lastName": lastName,
            "searchableFirstName": firstName.lowercased(),
            "searchableLastName": lastName.lowercased()
        ])
        // Update local cache
        currentAppUser?.firstName = firstName
        currentAppUser?.lastName = lastName
        currentAppUser?.searchableFirstName = firstName.lowercased()
        currentAppUser?.searchableLastName = lastName.lowercased()
    }

    func updateProfilePhotoURL(uid: String, url: String) async throws {
        try await db.collection(FirestoreCollection.users).document(uid).updateData([
            "profilePhotoURL": url
        ])
        // Update local cache
        currentAppUser?.profilePhotoURL = url
    }

    func searchByEmail(_ email: String) async throws -> AppUser? {
        let snapshot = try await db.collection(FirestoreCollection.users)
            .whereField("searchableEmail", isEqualTo: email.lowercased())
            .limit(to: 1)
            .getDocuments()
        guard let user = try snapshot.documents.first.map({ try $0.data(as: AppUser.self) }) else {
            return nil
        }
        guard !user.isBanned else { return nil }
        return user.emailSearchable ? user : nil
    }

    func searchByPhone(_ phone: String) async throws -> AppUser? {
        // Normalize query to 10 digits to match stored searchablePhone
        var digits = phone.filter(\.isNumber)
        if digits.count == 11 && digits.hasPrefix("1") {
            digits = String(digits.dropFirst())
        }

        let snapshot = try await db.collection(FirestoreCollection.users)
            .whereField("searchablePhone", isEqualTo: digits)
            .limit(to: 1)
            .getDocuments()
        guard let user = try snapshot.documents.first.map({ try $0.data(as: AppUser.self) }) else {
            return nil
        }
        guard !user.isBanned else { return nil }
        return user.phoneSearchable ? user : nil
    }

    func searchByName(_ name: String, excludingUID: String?) async throws -> [AppUser] {
        let words = name.lowercased().split(separator: " ").map(String.init)
        guard let firstWord = words.first else { return [] }

        let usersCol = db.collection(FirestoreCollection.users)
        let endPrefix = firstWord + "\u{f8ff}"

        // Use first word for Firestore prefix queries on both name fields
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

        // Merge, deduplicate, filter hidden/self, and verify remaining words match
        var seen = Set<String>()
        var results: [AppUser] = []

        for doc in firstNameSnap.documents + lastNameSnap.documents {
            let user = try doc.data(as: AppUser.self)
            guard let uid = user.id,
                  uid != excludingUID,
                  !user.isBanned,
                  user.emailSearchable || user.phoneSearchable,
                  !seen.contains(uid) else { continue }

            // For multi-word queries, verify all extra words appear in the full name
            if !extraWords.isEmpty {
                let fullName = "\(user.searchableFirstName ?? "") \(user.searchableLastName ?? "")"
                guard extraWords.allSatisfy({ fullName.contains($0) }) else { continue }
            }

            seen.insert(uid)
            results.append(user)
        }

        return results
    }

    func updateHiddenFromSearch(uid: String, isHidden: Bool) async throws {
        try await db.collection(FirestoreCollection.users).document(uid).updateData([
            "isHiddenFromSearch": isHidden
        ])
        currentAppUser?.isHiddenFromSearch = isHidden
    }

    func updateSearchablePreferences(uid: String, emailSearchable: Bool, phoneSearchable: Bool) async throws {
        try await db.collection(FirestoreCollection.users).document(uid).updateData([
            "emailSearchable": emailSearchable,
            "phoneSearchable": phoneSearchable
        ])
        currentAppUser?.emailSearchable = emailSearchable
        currentAppUser?.phoneSearchable = phoneSearchable
    }

    /// Returns true if a user document exists in Firestore for the given UID.
    /// Returns true on error (network failure) to avoid accidentally deleting valid connections.
    func userExists(uid: String) async -> Bool {
        do {
            let snapshot = try await db.collection(FirestoreCollection.users)
                .document(uid).getDocument()
            return snapshot.exists
        } catch {
            return true
        }
    }

    func deleteUser(uid: String) async throws {
        let usersCol = db.collection(FirestoreCollection.users)

        // Delete all connections (both sides)
        let connSnap = try await usersCol.document(uid)
            .collection(FirestoreCollection.connections).getDocuments()
        for doc in connSnap.documents {
            // Remove the other user's connection to this user
            try? await usersCol.document(doc.documentID)
                .collection(FirestoreCollection.connections).document(uid).delete()
            // Remove this user's connection doc
            try await doc.reference.delete()
        }

        // Delete the user document
        try await usersCol.document(uid).delete()

        currentAppUser = nil
    }
}
