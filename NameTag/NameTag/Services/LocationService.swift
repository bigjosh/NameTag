import Foundation
import UIKit
import CoreLocation
import FirebaseFirestore

@Observable
final class LocationService: NSObject, ProximityService, @unchecked Sendable {
    private(set) var nearbyUserIDs: [String: (lastSeen: Date, rssi: Int)] = [:]

    /// Raw GPS distances to all queried contacts (meters), regardless of proximity threshold.
    private(set) var contactDistances: [String: Double] = [:]

    /// Called after each query cycle with the latest distances.
    var onDistancesUpdated: (([String: Double]) -> Void)?

    /// Called when a contact is detected within proximity threshold (for notification handling)
    var onContactDiscovered: ((String) -> Void)?

    private(set) var currentLatitude: Double?
    private(set) var currentLongitude: Double?

    private var userID: String = ""
    private var knownConnectionUIDs: Set<String> = []
    private var locationManager: CLLocationManager?
    private var lastLocation: CLLocation?
    private var locationUploadTimer: Timer?
    private var queryTimer: Timer?
    private var staleTimer: Timer?
    private let db = Firestore.firestore()

    /// Tracks when we last fired onContactDiscovered for each UID, so we can
    /// periodically re-fire for continuously-present contacts.
    private var lastCallbackAt: [String: Date] = [:]

    /// How often to re-fire the callback for a continuously-present contact
    private let callbackRecheckInterval: TimeInterval = 60

    func configure(userID: String, connectionUIDs: Set<String>) {
        self.userID = userID
        self.knownConnectionUIDs = connectionUIDs
    }

    func updateConnectionUIDs(_ uids: Set<String>) {
        knownConnectionUIDs = uids
    }

    func startDiscovery() {
        guard !userID.isEmpty else { return }
        stopAll()

        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        self.locationManager = manager

        // Request Always authorization for background location updates.
        // On first call this shows "When In Use" prompt; on second launch
        // iOS may show the "Always" upgrade prompt automatically.
        manager.requestAlwaysAuthorization()

        startLocationUploadTimer()
        startQueryTimer()
        startStaleTimer()
    }

    func stopAll() {
        locationManager?.stopUpdatingLocation()
        locationManager?.stopMonitoringSignificantLocationChanges()
        locationManager = nil
        locationUploadTimer?.invalidate()
        locationUploadTimer = nil
        queryTimer?.invalidate()
        queryTimer = nil
        staleTimer?.invalidate()
        staleTimer = nil
        nearbyUserIDs.removeAll()
        contactDistances.removeAll()
        lastLocation = nil
        currentLatitude = nil
        currentLongitude = nil

        // Delete location from Firestore to prevent ghost presence
        guard !userID.isEmpty else { return }
        Task {
            try? await db.collection(FirestoreCollection.users)
                .document(userID)
                .updateData([
                    "latitude": FieldValue.delete(),
                    "longitude": FieldValue.delete(),
                    "lastLocationUpdate": FieldValue.delete()
                ])
        }
    }

    // MARK: - Location upload timer

    private func startLocationUploadTimer() {
        locationUploadTimer?.invalidate()
        locationUploadTimer = Timer.scheduledTimer(
            withTimeInterval: LocationConstants.locationUpdateInterval,
            repeats: true
        ) { [weak self] _ in
            self?.uploadLocation()
        }
    }

    private func uploadLocation() {
        guard let location = lastLocation else { return }
        guard !userID.isEmpty else { return }

        Task {
            try? await db.collection(FirestoreCollection.users)
                .document(userID)
                .updateData([
                    "latitude": location.coordinate.latitude,
                    "longitude": location.coordinate.longitude,
                    "lastLocationUpdate": FieldValue.serverTimestamp()
                ])
        }
    }

    // MARK: - Query nearby connections timer

    private func startQueryTimer() {
        queryTimer?.invalidate()
        queryTimer = Timer.scheduledTimer(
            withTimeInterval: LocationConstants.queryInterval,
            repeats: true
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.queryNearbyConnections()
            }
        }
    }

    private func queryNearbyConnections() async {
        guard let myLocation = lastLocation else { return }
        guard !knownConnectionUIDs.isEmpty else { return }

        let uids = Array(knownConnectionUIDs)

        // Firestore `in` query supports max 30 items — batch if needed
        let batches = stride(from: 0, to: uids.count, by: 30).map { start in
            Array(uids[start..<min(start + 30, uids.count)])
        }

        var updatedDistances: [String: Double] = [:]

        for batch in batches {
            do {
                let snapshot = try await db.collection(FirestoreCollection.users)
                    .whereField(FieldPath.documentID(), in: batch)
                    .getDocuments()

                for document in snapshot.documents {
                    let uid = document.documentID
                    guard let latitude = document.data()["latitude"] as? Double,
                          let longitude = document.data()["longitude"] as? Double else {
                        print("[Location] \(uid.prefix(8))… — no lat/lng in Firestore, skipping")
                        continue
                    }

                    // Skip contacts whose location is stale (older than 30 min)
                    // or has no timestamp at all (can't verify freshness).
                    // This prevents false "nearby" detections from old Firestore data.
                    guard let lastUpdate = document.data()["lastLocationUpdate"] as? Timestamp else {
                        print("[Location] \(uid.prefix(8))… — no timestamp, skipping")
                        continue
                    }
                    let age = Date().timeIntervalSince(lastUpdate.dateValue())
                    if age > LocationConstants.maxLocationAgeSec {
                        print("[Location] \(uid.prefix(8))… — stale location (\(Int(age / 60)) min old), skipping")
                        continue
                    }

                    let peerLocation = CLLocation(latitude: latitude, longitude: longitude)
                    let distance = myLocation.distance(from: peerLocation)

                    // Store raw distance for all contacts (used by NotificationGatekeeper)
                    updatedDistances[uid] = distance

                    if distance <= LocationConstants.proximityThresholdMeters {
                        print("[Location] \(uid.prefix(8))… — \(Int(distance))m away ✅ NEARBY")
                        handleDiscoveredUID(uid, distance: distance)
                    }
                }
            } catch {
                // Query failed — skip this batch
            }
        }

        contactDistances = updatedDistances
        onDistancesUpdated?(updatedDistances)
    }

    // MARK: - Contact Discovery

    private func handleDiscoveredUID(_ uid: String, distance: Double) {
        let now = Date()
        var shouldNotify: Bool

        if let existing = nearbyUserIDs[uid] {
            // Treat as "new" if they haven't been seen for longer than the stale timeout.
            shouldNotify = now.timeIntervalSince(existing.lastSeen) > LocationConstants.staleTimeout
        } else {
            shouldNotify = true
        }

        // Also re-fire periodically for continuously-present contacts so the
        // gatekeeper can re-evaluate after a suppression window expires.
        if !shouldNotify, let lastCB = lastCallbackAt[uid],
           now.timeIntervalSince(lastCB) > callbackRecheckInterval {
            shouldNotify = true
        }

        nearbyUserIDs[uid] = (lastSeen: now, rssi: -Int(distance))

        if shouldNotify {
            lastCallbackAt[uid] = now
            onContactDiscovered?(uid)
        }
    }

    // MARK: - Public entry point for background callers

    /// Called by BGAppRefreshTask and silent push handlers to upload + query.
    func performBackgroundUploadAndQuery() {
        guard lastLocation != nil else { return }
        uploadLocation()
        Task {
            await queryNearbyConnections()
        }
    }

    // MARK: - Stale timer

    private func startStaleTimer() {
        staleTimer?.invalidate()
        staleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.pruneStaleContacts()
        }
    }

    private func pruneStaleContacts() {
        let now = Date()
        nearbyUserIDs = nearbyUserIDs.filter { _, value in
            now.timeIntervalSince(value.lastSeen) <= LocationConstants.staleTimeout
        }
    }
}

// MARK: - CLLocationManagerDelegate
extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        Task { @MainActor [weak self] in
            self?.lastLocation = location
            self?.currentLatitude = location.coordinate.latitude
            self?.currentLongitude = location.coordinate.longitude

            // Always upload our location on every GPS update (keeps Firestore fresh for peers)
            self?.uploadLocation()

            // Query nearby connections only at walking pace or slower.
            // speed < 0 means unknown (common for significant-change background events)
            // speed < 2.0 means walking pace (~4.5 mph) or stationary
            if location.speed < 2.0 {
                await self?.queryNearbyConnections()
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedAlways:
                print("[Location] Authorization: Always — starting updates + significant location monitoring")
                manager.startUpdatingLocation()
                manager.startMonitoringSignificantLocationChanges()
            case .authorizedWhenInUse:
                print("[Location] Authorization: WhenInUse — starting updates (no background location)")
                manager.startUpdatingLocation()
                // Significant location changes require Always authorization
                // iOS will show the "upgrade to Always" prompt on next app launch
            default:
                print("[Location] Authorization: \(manager.authorizationStatus.rawValue)")
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Location updates failed — nothing critical to handle
        print("[Location] Error: \(error.localizedDescription)")
    }
}
