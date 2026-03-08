import Foundation
import FirebaseFirestore

struct Message: Codable, Identifiable, Sendable {
    @DocumentID var id: String?
    var senderUID: String
    var text: String
    var sentAt: Date
}
