import Foundation
import UIKit
import MultipeerConnectivity

@Observable
final class MultipeerService: NSObject, ProximityService, @unchecked Sendable {
    private(set) var nearbyUserIDs: [String: (lastSeen: Date, rssi: Int)] = [:]

    private var userID: String = ""
    private var knownConnectionUIDs: Set<String> = []
    private var discoveredPeerUIDs: Set<String> = []  // ALL discovered UIDs, even non-connections

    /// Called when a new contact is discovered (for centralized notification handling)
    var onContactDiscovered: ((String) -> Void)?
    private var lastCallbackAt: [String: Date] = [:]
    private let callbackRecheckInterval: TimeInterval = 60
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var myPeerID: MCPeerID?
    private var staleTimer: Timer?

    func configure(userID: String, connectionUIDs: Set<String>) {
        print("[Multipeer] configure — userID: \(userID), connectionUIDs: \(connectionUIDs)")
        self.userID = userID
        self.knownConnectionUIDs = connectionUIDs
        self.myPeerID = MCPeerID(displayName: userID)
    }

    func updateConnectionUIDs(_ uids: Set<String>) {
        let previousUIDs = knownConnectionUIDs
        knownConnectionUIDs = uids
        print("[Multipeer] updateConnectionUIDs — \(uids.count) UIDs: \(uids)")

        // Re-evaluate any peers that were discovered before UIDs loaded
        let newUIDs = uids.subtracting(previousUIDs)
        if !newUIDs.isEmpty {
            print("[Multipeer] New UIDs to check: \(newUIDs), discoveredPeerUIDs: \(discoveredPeerUIDs)")
        }
        for uid in discoveredPeerUIDs.intersection(newUIDs) {
            print("[Multipeer] Re-evaluating previously discovered peer: \(uid)")
            handleDiscoveredUID(uid)
        }
    }

    func startDiscovery() {
        guard let myPeerID else {
            print("[Multipeer] startDiscovery — SKIPPED, no myPeerID")
            return
        }
        stopAll()

        print("[Multipeer] startDiscovery — starting advertiser and browser")

        // Advertiser: share our UID via discoveryInfo
        let advertiser = MCNearbyServiceAdvertiser(
            peer: myPeerID,
            discoveryInfo: ["uid": userID],
            serviceType: MultipeerConstants.serviceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser

        // Browser: discover other peers
        let browser = MCNearbyServiceBrowser(
            peer: myPeerID,
            serviceType: MultipeerConstants.serviceType
        )
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser

        startStaleTimer()
    }

    func stopAll() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser = nil
        staleTimer?.invalidate()
        staleTimer = nil
        nearbyUserIDs.removeAll()
        discoveredPeerUIDs.removeAll()
    }

    private func startStaleTimer() {
        staleTimer?.invalidate()
        staleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.pruneStaleContacts()
        }
    }

    private func pruneStaleContacts() {
        let now = Date()
        nearbyUserIDs = nearbyUserIDs.filter { _, value in
            now.timeIntervalSince(value.lastSeen) <= MultipeerConstants.staleTimeout
        }
    }

    private func handleDiscoveredUID(_ uid: String) {
        print("[Multipeer] handleDiscoveredUID — uid: \(uid)")
        print("[Multipeer]   knownConnectionUIDs: \(knownConnectionUIDs)")
        print("[Multipeer]   contains: \(knownConnectionUIDs.contains(uid))")

        guard knownConnectionUIDs.contains(uid) else {
            print("[Multipeer]   REJECTED — not in knownConnectionUIDs")
            return
        }

        let now = Date()
        var shouldNotify: Bool

        if let existing = nearbyUserIDs[uid] {
            shouldNotify = now.timeIntervalSince(existing.lastSeen) > MultipeerConstants.staleTimeout
        } else {
            shouldNotify = true
        }

        if !shouldNotify, let lastCB = lastCallbackAt[uid],
           now.timeIntervalSince(lastCB) > callbackRecheckInterval {
            shouldNotify = true
        }

        nearbyUserIDs[uid] = (lastSeen: now, rssi: -40)

        if shouldNotify {
            lastCallbackAt[uid] = now
            print("[Multipeer]   Contact discovered (new or re-appeared), notifying gatekeeper")
            onContactDiscovered?(uid)
        }
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate
extension MultipeerService: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        // We don't need sessions — reject all invitations
        invitationHandler(false, nil)
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("[Multipeer] didNotStartAdvertising: \(error.localizedDescription)")
    }
}

// MARK: - MCNearbyServiceBrowserDelegate
extension MultipeerService: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        print("[Multipeer] foundPeer: \(peerID.displayName), info: \(info ?? [:])")
        guard let uid = info?["uid"] else {
            print("[Multipeer]   NO uid in discoveryInfo, skipping")
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.discoveredPeerUIDs.insert(uid)
            self.handleDiscoveredUID(uid)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        print("[Multipeer] lostPeer: \(peerID.displayName)")
        let uid = peerID.displayName

        Task { @MainActor [weak self] in
            self?.discoveredPeerUIDs.remove(uid)
            self?.nearbyUserIDs.removeValue(forKey: uid)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("[Multipeer] didNotStartBrowsing: \(error.localizedDescription)")
    }
}
