import Foundation

@Observable
final class CardStackViewModel {
    private(set) var nearbyContacts: [NearbyContact] = []
    private var refreshTimer: Timer?

    func startMonitoring(appState: AppState) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshNearbyContacts(appState: appState)
        }
    }

    func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refreshNearbyContacts(appState: AppState) {
        let connectionUIDs = appState.connectionsService.connectionUIDs

        // Update all services with latest connection UIDs
        appState.bleService.updateConnectionUIDs(connectionUIDs)
        appState.multipeerService.updateConnectionUIDs(connectionUIDs)
        appState.bonjourService.updateConnectionUIDs(connectionUIDs)
        appState.locationService.updateConnectionUIDs(connectionUIDs)

        // Collect nearbyUserIDs from all 4 proximity sources
        let sources: [[String: (lastSeen: Date, rssi: Int)]] = [
            appState.bleService.nearbyUserIDs,
            appState.multipeerService.nearbyUserIDs,
            appState.bonjourService.nearbyUserIDs,
            appState.locationService.nearbyUserIDs
        ]

        // Merge: union of UIDs, most recent lastSeen, highest rssi
        var merged: [String: (lastSeen: Date, rssi: Int)] = [:]
        for source in sources {
            for (uid, info) in source {
                if let existing = merged[uid] {
                    merged[uid] = (
                        lastSeen: max(existing.lastSeen, info.lastSeen),
                        rssi: max(existing.rssi, info.rssi)
                    )
                } else {
                    merged[uid] = info
                }
            }
        }

        // Filter merged to only include active (non-paused) connection UIDs
        merged = merged.filter { connectionUIDs.contains($0.key) }

        let connections = appState.connectionsService.connections.filter { !$0.proximityPaused }

        // Build NearbyContact for each detected connection
        var result: [NearbyContact] = []
        for connection in connections {
            if let mergedInfo = merged[connection.userId] {
                result.append(NearbyContact(
                    id: connection.userId,
                    connection: connection,
                    lastSeenAt: mergedInfo.lastSeen,
                    rssi: mergedInfo.rssi
                ))
            }
        }

        // Sort by lastSeenAt descending (most recent on top)
        result.sort { $0.lastSeenAt > $1.lastSeenAt }
        nearbyContacts = result
    }
}
