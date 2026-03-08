import Foundation
import UIKit
import Network

@Observable
final class BonjourService: ProximityService {
    private(set) var nearbyUserIDs: [String: (lastSeen: Date, rssi: Int)] = [:]

    private var userID: String = ""
    private var knownConnectionUIDs: Set<String> = []
    private var lastBrowseResults: Set<NWBrowser.Result> = []  // Cached results for re-evaluation

    /// Called when a new contact is discovered (for centralized notification handling)
    var onContactDiscovered: ((String) -> Void)?
    private var lastCallbackAt: [String: Date] = [:]
    private let callbackRecheckInterval: TimeInterval = 60
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var staleTimer: Timer?

    func configure(userID: String, connectionUIDs: Set<String>) {
        print("[Bonjour] configure — userID: \(userID), connectionUIDs: \(connectionUIDs)")
        self.userID = userID
        self.knownConnectionUIDs = connectionUIDs
    }

    func updateConnectionUIDs(_ uids: Set<String>) {
        let previousUIDs = knownConnectionUIDs
        knownConnectionUIDs = uids
        print("[Bonjour] updateConnectionUIDs — \(uids.count) UIDs: \(uids)")

        // Re-evaluate cached browse results against new UIDs
        let newUIDs = uids.subtracting(previousUIDs)
        if !newUIDs.isEmpty && !lastBrowseResults.isEmpty {
            print("[Bonjour] Re-evaluating \(lastBrowseResults.count) cached results against \(newUIDs.count) new UIDs")
            handleBrowseResults(lastBrowseResults)
        }
    }

    func startDiscovery() {
        guard !userID.isEmpty else { return }
        stopAll()

        print("[Bonjour] startDiscovery")
        startListener()
        startBrowser()
        startStaleTimer()
    }

    func stopAll() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        staleTimer?.invalidate()
        staleTimer = nil
        nearbyUserIDs.removeAll()
        lastBrowseResults.removeAll()
    }

    // MARK: - Listener (advertise our presence)

    private func startListener() {
        // Advertise a Bonjour service with our UID as the service name
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        do {
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(
                name: userID,
                type: BonjourConstants.serviceType,
                domain: BonjourConstants.serviceDomain
            )

            listener.stateUpdateHandler = { state in
                print("[Bonjour] Listener state: \(state)")
            }

            listener.newConnectionHandler = { connection in
                // We don't need connections — cancel immediately
                connection.cancel()
            }

            listener.start(queue: .main)
            self.listener = listener
        } catch {
            print("[Bonjour] Failed to create listener: \(error.localizedDescription)")
        }
    }

    // MARK: - Browser (discover nearby peers)

    private func startBrowser() {
        let descriptor = NWBrowser.Descriptor.bonjour(
            type: BonjourConstants.serviceType,
            domain: BonjourConstants.serviceDomain
        )

        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { state in
            print("[Bonjour] Browser state: \(state)")
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            print("[Bonjour] browseResultsChanged — \(results.count) results")
            Task { @MainActor [weak self] in
                self?.handleBrowseResults(results)
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        lastBrowseResults = results
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }

            let uid = name
            print("[Bonjour] Found service: \(uid)")
            guard uid != userID else {
                print("[Bonjour]   Skipping self")
                continue
            }
            handleDiscoveredUID(uid)
        }
    }

    private func handleDiscoveredUID(_ uid: String) {
        print("[Bonjour] handleDiscoveredUID — uid: \(uid)")
        print("[Bonjour]   knownConnectionUIDs: \(knownConnectionUIDs)")
        print("[Bonjour]   contains: \(knownConnectionUIDs.contains(uid))")

        guard knownConnectionUIDs.contains(uid) else {
            print("[Bonjour]   REJECTED — not in knownConnectionUIDs")
            return
        }

        let now = Date()
        var shouldNotify: Bool

        if let existing = nearbyUserIDs[uid] {
            shouldNotify = now.timeIntervalSince(existing.lastSeen) > BonjourConstants.staleTimeout
        } else {
            shouldNotify = true
        }

        if !shouldNotify, let lastCB = lastCallbackAt[uid],
           now.timeIntervalSince(lastCB) > callbackRecheckInterval {
            shouldNotify = true
        }

        nearbyUserIDs[uid] = (lastSeen: now, rssi: -45)

        if shouldNotify {
            lastCallbackAt[uid] = now
            print("[Bonjour]   Contact discovered (new or re-appeared), notifying gatekeeper")
            onContactDiscovered?(uid)
        }
    }

    // MARK: - Stale timer

    private func startStaleTimer() {
        staleTimer?.invalidate()
        staleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.pruneStaleContacts()
        }
    }

    private func pruneStaleContacts() {
        let now = Date()
        nearbyUserIDs = nearbyUserIDs.filter { _, value in
            now.timeIntervalSince(value.lastSeen) <= BonjourConstants.staleTimeout
        }
    }
}
