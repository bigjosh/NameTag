import Foundation
import FirebaseFirestore

enum InvitationStatus: String, Codable, Sendable {
    case pending
    case accepted
    case declined
    case withdrawn
}

struct Invitation: Codable, Identifiable, Sendable {
    @DocumentID var id: String?
    var fromUID: String
    var fromFirstName: String
    var fromLastName: String
    var fromProfilePhotoURL: String?
    var toUID: String?
    var toEmail: String?
    var toPhone: String?
    var message: String
    var howDoIKnow: String
    var status: InvitationStatus
    var createdAt: Date
    var respondedAt: Date?

    var fromFullName: String { "\(fromFirstName) \(fromLastName)" }

    /// The email or phone the invitation was sent to
    var targetDescription: String {
        toEmail ?? toPhone ?? "Unknown"
    }
}

enum InvitationError: LocalizedError {
    case noLongerValid

    var errorDescription: String? {
        switch self {
        case .noLongerValid:
            return "This invitation is no longer valid. It may have been withdrawn by the sender."
        }
    }
}
