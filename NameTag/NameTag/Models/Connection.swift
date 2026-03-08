import Foundation
import FirebaseFirestore

struct Connection: Codable, Identifiable, Sendable, Hashable {
    @DocumentID var id: String?
    var userId: String
    var firstName: String
    var lastName: String
    var profilePhotoURL: String?
    var howDoIKnow: String
    var connectedAt: Date
    var invitationId: String
    var isPaused: Bool?

    var fullName: String { "\(firstName) \(lastName)" }

    /// Whether proximity detection is paused for this contact
    var proximityPaused: Bool { isPaused ?? false }
}
