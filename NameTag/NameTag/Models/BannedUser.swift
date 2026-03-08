import Foundation
import FirebaseFirestore

struct BannedUser: Codable, Identifiable, Sendable {
    @DocumentID var id: String?
    var email: String?
    var phone: String?
    var firstName: String
    var lastName: String
    var originalUID: String
    var reason: String
    var bannedAt: Date
    var bannedBy: String

    var fullName: String { "\(firstName) \(lastName)" }
}
