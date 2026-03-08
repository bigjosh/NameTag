import Foundation
import FirebaseMessaging
import FirebaseFirestore
import UIKit

/// Manages FCM token lifecycle and storage in Firestore.
/// Silent pushes from Cloud Functions wake the app to refresh location data.
final class PushNotificationService: NSObject, MessagingDelegate {
    private let db = Firestore.firestore()
    private var currentUID: String?

    func configure(userID: String) {
        currentUID = userID
        Messaging.messaging().delegate = self

        // Register for remote notifications (triggers APNs token request)
        UIApplication.shared.registerForRemoteNotifications()

        // If FCM token already exists, upload it
        if let token = Messaging.messaging().fcmToken {
            storeToken(token)
        }
    }

    /// Called by FCM when the registration token is refreshed.
    nonisolated func messaging(
        _ messaging: Messaging,
        didReceiveRegistrationToken fcmToken: String?
    ) {
        guard let token = fcmToken else { return }
        print("[FCM] Token refreshed: \(token.prefix(20))...")
        Task { @MainActor [weak self] in
            self?.storeToken(token)
        }
    }

    /// Store FCM token in the user's Firestore document.
    private func storeToken(_ token: String) {
        guard let uid = currentUID else { return }
        Task {
            try? await db.collection(FirestoreCollection.users)
                .document(uid)
                .updateData(["fcmToken": token])
            print("[FCM] Token stored in Firestore for user \(uid)")
        }
    }

    /// Remove FCM token from Firestore (call on sign-out or account deletion).
    func clearToken() {
        guard let uid = currentUID else { return }
        Task {
            try? await db.collection(FirestoreCollection.users)
                .document(uid)
                .updateData(["fcmToken": FieldValue.delete()])
        }
        currentUID = nil
    }
}
