import Foundation

protocol ProximityService: AnyObject {
    var nearbyUserIDs: [String: (lastSeen: Date, rssi: Int)] { get }
    func configure(userID: String, connectionUIDs: Set<String>)
    func updateConnectionUIDs(_ uids: Set<String>)
    func startDiscovery()
    func stopAll()
}
