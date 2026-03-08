import Foundation
import FirebaseFirestore

struct AppUser: Codable, Identifiable, Sendable, Hashable {
    @DocumentID var id: String?
    var email: String?
    var phone: String?
    var firstName: String
    var lastName: String
    var profilePhotoURL: String?
    var searchableEmail: String?
    var searchablePhone: String?
    var searchableFirstName: String?
    var searchableLastName: String?
    var isBanned: Bool
    var isHiddenFromSearch: Bool
    var emailSearchable: Bool
    var phoneSearchable: Bool
    var createdAt: Date

    var fullName: String { "\(firstName) \(lastName)" }

    init(
        id: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        firstName: String,
        lastName: String,
        profilePhotoURL: String? = nil,
        isBanned: Bool = false,
        isHiddenFromSearch: Bool = false,
        emailSearchable: Bool = true,
        phoneSearchable: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.email = email
        self.phone = phone
        self.firstName = firstName
        self.lastName = lastName
        self.profilePhotoURL = profilePhotoURL
        self.isBanned = isBanned
        self.searchableEmail = email?.lowercased()
        // Normalize phone to 10 digits for reliable search
        if let phone {
            let digits = phone.filter(\.isNumber)
            if digits.count == 11 && digits.hasPrefix("1") {
                self.searchablePhone = String(digits.dropFirst())
            } else {
                self.searchablePhone = digits
            }
        } else {
            self.searchablePhone = nil
        }
        self.searchableFirstName = firstName.lowercased()
        self.searchableLastName = lastName.lowercased()
        self.isHiddenFromSearch = isHiddenFromSearch
        self.emailSearchable = emailSearchable
        self.phoneSearchable = phoneSearchable
        self.createdAt = createdAt
    }

    // Custom decoder so existing Firestore docs missing new fields decode gracefully
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _id = try container.decode(DocumentID<String>.self, forKey: .id)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        phone = try container.decodeIfPresent(String.self, forKey: .phone)
        firstName = try container.decode(String.self, forKey: .firstName)
        lastName = try container.decode(String.self, forKey: .lastName)
        profilePhotoURL = try container.decodeIfPresent(String.self, forKey: .profilePhotoURL)
        isBanned = (try? container.decode(Bool.self, forKey: .isBanned)) ?? false
        searchableEmail = try container.decodeIfPresent(String.self, forKey: .searchableEmail)
        searchablePhone = try container.decodeIfPresent(String.self, forKey: .searchablePhone)
        searchableFirstName = try container.decodeIfPresent(String.self, forKey: .searchableFirstName)
        searchableLastName = try container.decodeIfPresent(String.self, forKey: .searchableLastName)
        isHiddenFromSearch = (try? container.decode(Bool.self, forKey: .isHiddenFromSearch)) ?? false
        // Per-field searchable flags — default to true unless legacy isHiddenFromSearch was on
        let legacyHidden = (try? container.decode(Bool.self, forKey: .isHiddenFromSearch)) ?? false
        emailSearchable = (try? container.decode(Bool.self, forKey: .emailSearchable)) ?? !legacyHidden
        phoneSearchable = (try? container.decode(Bool.self, forKey: .phoneSearchable)) ?? !legacyHidden
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}
