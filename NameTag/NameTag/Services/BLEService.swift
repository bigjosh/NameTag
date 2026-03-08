import Foundation
import UIKit
import CoreBluetooth

@Observable
final class BLEService: NSObject, ProximityService, @unchecked Sendable {
    private(set) var nearbyUserIDs: [String: (lastSeen: Date, rssi: Int)] = [:]
    private(set) var isScanning = false
    private(set) var isAdvertising = false
    private(set) var bluetoothState: CBManagerState = .unknown

    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    private var userID: String = ""
    private var knownConnectionUIDs: Set<String> = []
    private var staleTimer: Timer?

    /// Called when a new contact is discovered (for centralized notification handling)
    var onContactDiscovered: ((String) -> Void)?

    /// Tracks when we last fired onContactDiscovered for each UID, so we can
    /// periodically re-fire for continuously-present contacts (allows the
    /// gatekeeper to re-evaluate expired suppressions).
    private var lastCallbackAt: [String: Date] = [:]

    /// How often to re-fire the callback for a continuously-present contact
    private let callbackRecheckInterval: TimeInterval = 60

    // Track peripherals we're connecting to so we can read their characteristic
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]

    // All UIDs read from peripherals, even if not in knownConnectionUIDs yet
    private var discoveredUIDs: Set<String> = []

    override init() {
        super.init()

        // Load persisted config so BLE can resume immediately after state restoration
        userID = UserDefaults.standard.string(forKey: BLE.userDefaultsUserIDKey) ?? ""
        if let saved = UserDefaults.standard.array(forKey: BLE.userDefaultsConnectionUIDsKey) as? [String] {
            knownConnectionUIDs = Set(saved)
        }

        // Initialize managers WITH restore identifiers for state preservation
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: BLE.centralRestoreIdentifier]
        )
        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: nil,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: BLE.peripheralRestoreIdentifier]
        )
    }

    func configure(userID: String, connectionUIDs: Set<String>) {
        self.userID = userID
        self.knownConnectionUIDs = connectionUIDs
        persistConfig()
    }

    func updateConnectionUIDs(_ uids: Set<String>) {
        let previousUIDs = knownConnectionUIDs
        knownConnectionUIDs = uids
        persistConfig()

        // Re-evaluate any UIDs that were read before connection UIDs loaded
        let newUIDs = uids.subtracting(previousUIDs)
        for uid in discoveredUIDs.intersection(newUIDs) {
            handleDiscoveredUID(uid)
        }
    }

    func startAdvertising() {
        guard peripheralManager.state == .poweredOn else { return }

        let characteristic = CBMutableCharacteristic(
            type: BLE.characteristicUUID,
            properties: .read,
            value: nil,
            permissions: .readable
        )

        let service = CBMutableService(type: BLE.serviceUUID, primary: true)
        service.characteristics = [characteristic]

        peripheralManager.removeAllServices()
        peripheralManager.add(service)
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        centralManager.scanForPeripherals(
            withServices: [BLE.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        isScanning = true
        startStaleTimer()
    }

    func startDiscovery() {
        startAdvertising()
        startScanning()
    }

    func stopAll() {
        centralManager.stopScan()
        peripheralManager.stopAdvertising()
        peripheralManager.removeAllServices()
        isScanning = false
        isAdvertising = false
        staleTimer?.invalidate()
        staleTimer = nil

        for peripheral in discoveredPeripherals.values {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        discoveredPeripherals.removeAll()
    }

    /// Clear persisted BLE config (call on sign-out)
    func clearPersistedConfig() {
        UserDefaults.standard.removeObject(forKey: BLE.userDefaultsUserIDKey)
        UserDefaults.standard.removeObject(forKey: BLE.userDefaultsConnectionUIDsKey)
    }

    // MARK: - Private Helpers

    private func persistConfig() {
        UserDefaults.standard.set(userID, forKey: BLE.userDefaultsUserIDKey)
        UserDefaults.standard.set(Array(knownConnectionUIDs), forKey: BLE.userDefaultsConnectionUIDsKey)
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
            now.timeIntervalSince(value.lastSeen) <= BLE.staleTimeout
        }
    }

    private func handleDiscoveredUID(_ uid: String) {
        discoveredUIDs.insert(uid)
        guard knownConnectionUIDs.contains(uid) else { return }

        let now = Date()
        var shouldNotify: Bool

        if let existing = nearbyUserIDs[uid] {
            // Treat as "new" if they haven't been seen for longer than the stale timeout.
            shouldNotify = now.timeIntervalSince(existing.lastSeen) > BLE.staleTimeout
        } else {
            shouldNotify = true
        }

        // Also re-fire periodically for continuously-present contacts so the
        // gatekeeper can re-evaluate after a suppression window expires.
        if !shouldNotify, let lastCB = lastCallbackAt[uid],
           now.timeIntervalSince(lastCB) > callbackRecheckInterval {
            shouldNotify = true
        }

        nearbyUserIDs[uid] = (lastSeen: now, rssi: -50)

        if shouldNotify {
            lastCallbackAt[uid] = now
            onContactDiscovered?(uid)
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEService: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            bluetoothState = central.state
            if central.state == .poweredOn && !userID.isEmpty {
                startScanning()
            }
        }
    }

    /// Called when iOS relaunches the app and restores the central manager state
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            print("[BLE] Central manager restoring state")

            // Re-track any peripherals that were being connected to when the app was killed
            if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
                for peripheral in peripherals {
                    print("[BLE] Restoring peripheral: \(peripheral.identifier)")
                    discoveredPeripherals[peripheral.identifier] = peripheral
                    peripheral.delegate = self

                    // Resume the connection flow based on the peripheral's current state
                    switch peripheral.state {
                    case .connected:
                        peripheral.discoverServices([BLE.serviceUUID])
                    case .connecting:
                        break // already connecting, wait for didConnect
                    default:
                        // Try to reconnect
                        central.connect(peripheral, options: nil)
                    }
                }
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        MainActor.assumeIsolated {
            // If we're already connected to this peripheral, skip
            guard discoveredPeripherals[peripheral.identifier] == nil else { return }

            discoveredPeripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            peripheral.discoverServices([BLE.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            discoveredPeripherals.removeValue(forKey: peripheral.identifier)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            discoveredPeripherals.removeValue(forKey: peripheral.identifier)
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BLEService: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == BLE.serviceUUID }) else {
                centralManager.cancelPeripheralConnection(peripheral)
                return
            }
            peripheral.discoverCharacteristics([BLE.characteristicUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard let characteristic = service.characteristics?.first(where: { $0.uuid == BLE.characteristicUUID }) else {
                centralManager.cancelPeripheralConnection(peripheral)
                return
            }
            peripheral.readValue(for: characteristic)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            defer { centralManager.cancelPeripheralConnection(peripheral) }

            guard let data = characteristic.value,
                  let uid = String(data: data, encoding: .utf8) else { return }

            handleDiscoveredUID(uid)
        }
    }
}

// MARK: - CBPeripheralManagerDelegate
extension BLEService: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated {
            if peripheral.state == .poweredOn && !userID.isEmpty {
                startAdvertising()
            }
        }
    }

    /// Called when iOS relaunches the app and restores the peripheral manager state
    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            print("[BLE] Peripheral manager restoring state")

            // Check if our service is still registered; if not, re-add it
            if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] {
                let hasOurService = services.contains { $0.uuid == BLE.serviceUUID }
                if !hasOurService && !userID.isEmpty {
                    startAdvertising()
                }
            } else if !userID.isEmpty {
                // No services restored — re-add
                startAdvertising()
            }

            // Re-start advertising if it was active
            if let advertising = dict[CBPeripheralManagerRestoredStateAdvertisementDataKey] as? [String: Any],
               !advertising.isEmpty {
                isAdvertising = true
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil else { return }
            peripheralManager.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [BLE.serviceUUID],
                CBAdvertisementDataLocalNameKey: "NameTag"
            ])
            isAdvertising = true
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        MainActor.assumeIsolated {
            guard request.characteristic.uuid == BLE.characteristicUUID else {
                peripheral.respond(to: request, withResult: .attributeNotFound)
                return
            }

            guard let data = userID.data(using: .utf8) else {
                peripheral.respond(to: request, withResult: .unlikelyError)
                return
            }

            if request.offset > data.count {
                peripheral.respond(to: request, withResult: .invalidOffset)
                return
            }

            request.value = data.subdata(in: request.offset..<data.count)
            peripheral.respond(to: request, withResult: .success)
        }
    }
}
