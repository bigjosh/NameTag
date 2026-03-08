import Foundation
import FirebaseFirestore

struct Conversation: Codable, Identifiable, Sendable, Hashable {
    @DocumentID var id: String?
    var participantUIDs: [String]
    var lastMessageText: String
    var lastMessageSenderUID: String
    var lastMessageTimestamp: Date
    var participantNames: [String: String]
    var participantPhotos: [String: String]
    var lastReadBy: [String: Date]?

    /// Returns the deterministic conversation ID for two UIDs
    static func conversationID(uid1: String, uid2: String) -> String {
        [uid1, uid2].sorted().joined(separator: "_")
    }

    /// Returns the other participant's UID given the current user's UID
    func otherUID(currentUID: String) -> String? {
        participantUIDs.first { $0 != currentUID }
    }

    /// Returns the other participant's display name
    func otherName(currentUID: String) -> String {
        guard let otherUID = otherUID(currentUID: currentUID) else { return "Unknown" }
        return participantNames[otherUID] ?? "Unknown"
    }

    /// Returns the other participant's photo URL
    func otherPhotoURL(currentUID: String) -> String? {
        guard let otherUID = otherUID(currentUID: currentUID) else { return nil }
        let url = participantPhotos[otherUID]
        // Empty string means no photo
        return (url?.isEmpty == true) ? nil : url
    }

    /// Whether this conversation has unread messages for the given user
    func isUnread(currentUID: String) -> Bool {
        // If the last message was sent by me, it's not unread
        guard lastMessageSenderUID != currentUID else { return false }
        // If we've never read this conversation, it's unread
        guard let lastRead = lastReadBy?[currentUID] else { return true }
        // Unread if the last message came after our last read
        return lastMessageTimestamp > lastRead
    }
}
