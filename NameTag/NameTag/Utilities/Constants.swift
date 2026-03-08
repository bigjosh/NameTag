import CoreBluetooth

enum BLE {
    static let serviceUUID = CBUUID(string: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")
    static let characteristicUUID = CBUUID(string: "A1B2C3D4-E5F6-7890-ABCD-EF1234567891")
    static let staleTimeout: TimeInterval = 30

    // State restoration identifiers
    static let centralRestoreIdentifier = "com.nametag.central"
    static let peripheralRestoreIdentifier = "com.nametag.peripheral"

    // UserDefaults keys for persisting BLE config across app relaunches
    static let userDefaultsUserIDKey = "ble_userID"
    static let userDefaultsConnectionUIDsKey = "ble_connectionUIDs"
}

enum FirestoreCollection {
    static let users = "users"
    static let connections = "connections"
    static let invitations = "invitations"
    static let conversations = "conversations"
    static let messages = "messages"
    static let bannedUsers = "bannedUsers"
}

enum Admin {
    static let adminUIDs: Set<String> = ["sDHSypYcylRR9xRAjIFjDlGbWe12"]

    static func isAdmin(_ uid: String) -> Bool {
        adminUIDs.contains(uid)
    }
}

enum StoragePath {
    static let profilePhotos = "profilePhotos"
}

enum MultipeerConstants {
    static let serviceType = "nametag-prox"  // 1-15 chars, lowercase+hyphens
    static let staleTimeout: TimeInterval = 30
}

enum BonjourConstants {
    static let serviceType = "_nametag._tcp"
    static let serviceDomain = "local."
    static let txtRecordUIDKey = "uid"
    static let staleTimeout: TimeInterval = 30
}

enum LocationConstants {
    static let proximityThresholdMeters: Double = 100
    static let locationUpdateInterval: TimeInterval = 15
    static let queryInterval: TimeInterval = 10
    static let staleTimeout: TimeInterval = 60

    /// Maximum age (in seconds) of a peer's Firestore location before we ignore it.
    /// If their lastLocationUpdate is older than this, treat them as "location unknown."
    static let maxLocationAgeSec: TimeInterval = 30 * 60  // 30 minutes
}

enum Proximity {
    static let mergedStaleTimeout: TimeInterval = 60
}

enum BackgroundTask {
    static let locationRefreshIdentifier = "alex.NameTag.locationRefresh"
}

enum NotificationSuppression {
    static let userDefaultsKey = "notificationSuppressionDuration"
    /// Default suppression: 15 minutes between repeat notifications
    static let defaultDuration: TimeInterval = 900

    static let none: TimeInterval = 0
    static let fifteenMinutes: TimeInterval = 900
    static let oneHour: TimeInterval = 3600
    static let oneDay: TimeInterval = 86400

    /// 1 mile in meters — suppression clears if contact moves beyond this
    static let clearDistanceMeters: Double = 1609.34
}
