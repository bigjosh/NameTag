import Foundation
import UserNotifications

@Observable
final class NotificationGatekeeper {
    /// Whether the user is currently viewing the Nearby tab.
    /// When true, notifications are suppressed because the card is already visible.
    var isOnNearbyTab: Bool = false

    /// Connection names for notification body text (UID → display name)
    var connectionNames: [String: String] = [:]

    /// How long to suppress repeat notifications after one fires.
    /// Persisted in UserDefaults so it survives app restarts.
    var suppressionDuration: TimeInterval {
        didSet {
            UserDefaults.standard.set(suppressionDuration, forKey: NotificationSuppression.userDefaultsKey)
        }
    }

    /// UIDs mapped to the time their suppression expires.
    /// After a notification fires, the UID is suppressed until this date.
    private var suppressedUntil: [String: Date] = [:]

    init() {
        let stored = UserDefaults.standard.double(forKey: NotificationSuppression.userDefaultsKey)
        suppressionDuration = stored > 0 ? stored : NotificationSuppression.defaultDuration
    }

    /// Attempt to send a notification for the given UID.
    /// Called by proximity services when they discover a new nearby contact.
    func notifyIfAllowed(uid: String) {
        // Rule 1: If the user is on the Nearby tab, the card is visible — no notification.
        // Don't set any suppression here — we want the first notification to fire
        // immediately when the user backgrounds the app.
        if isOnNearbyTab {
            return
        }

        // Rule 2: Suppress if within the suppression window from a previous notification
        if let expiration = suppressedUntil[uid] {
            if Date() < expiration {
                print("[NotificationGatekeeper] Suppressed for \(uid) — suppressed until \(expiration.formatted(date: .omitted, time: .shortened))")
                return
            } else {
                // Suppression expired — allow through
                suppressedUntil.removeValue(forKey: uid)
            }
        }

        // Send notification and suppress for the chosen duration (if any)
        let name = connectionNames[uid] ?? "Unknown"
        if suppressionDuration > 0 {
            print("[NotificationGatekeeper] ✅ Sending notification for \(name) (\(uid)) — suppressed for \(Int(suppressionDuration / 60)) min")
            suppressedUntil[uid] = Date().addingTimeInterval(suppressionDuration)
        } else {
            print("[NotificationGatekeeper] ✅ Sending notification for \(name) (\(uid)) — no snooze")
        }
        sendLocalNotification(for: uid)
    }

    /// Cancel any pending/delivered notifications (call when app returns to foreground)
    func cancelPendingNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    /// Called periodically with the latest GPS distances from LocationService.
    /// Clears suppression for any UID that is now > 1 mile away.
    func updateDistances(_ distances: [String: Double]) {
        for uid in Array(suppressedUntil.keys) {
            if let distance = distances[uid],
               distance > NotificationSuppression.clearDistanceMeters {
                suppressedUntil.removeValue(forKey: uid)
            }
        }
    }

    /// Clear all state (call on sign-out)
    func reset() {
        suppressedUntil.removeAll()
        connectionNames.removeAll()
        isOnNearbyTab = false
    }

    // MARK: - Private

    private func sendLocalNotification(for uid: String) {
        let content = UNMutableNotificationContent()
        content.title = "NameTagger"
        content.body = if let name = connectionNames[uid] {
            "\(name) is nearby!"
        } else {
            "A contact is nearby!"
        }
        content.sound = .default

        // Use a 1-second delay so the notification fires after the app
        // has fully transitioned to the background (immediate trigger
        // can be swallowed if iOS still considers the app foreground).
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)

        let request = UNNotificationRequest(
            identifier: "nearby-\(uid)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[NotificationGatekeeper] Failed to send notification: \(error.localizedDescription)")
            }
        }
    }
}
