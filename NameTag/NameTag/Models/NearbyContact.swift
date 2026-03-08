import Foundation

struct NearbyContact: Identifiable, Sendable {
    let id: String
    var connection: Connection
    var lastSeenAt: Date
    var rssi: Int

    var isStale: Bool {
        Date().timeIntervalSince(lastSeenAt) > Proximity.mergedStaleTimeout
    }
}
