import SwiftUI
import FirebaseCore
import FirebaseMessaging
import UserNotifications
import BackgroundTasks

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let backgroundTaskService = BackgroundTaskService()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()

        // Register background tasks BEFORE returning
        backgroundTaskService.registerBackgroundTasks()

        // Set ourselves as the notification delegate so notifications display in-app
        UNUserNotificationCenter.current().delegate = self

        // Request notification permissions for proximity alerts
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            if let error {
                print("[AppDelegate] Notification permission error: \(error.localizedDescription)")
            }
            print("[AppDelegate] Notification permission granted: \(granted)")
        }

        // Register for remote notifications (required for FCM silent push)
        application.registerForRemoteNotifications()

        // Log if we were launched due to BLE state restoration
        if let centralIDs = launchOptions?[.bluetoothCentrals] as? [String] {
            print("[AppDelegate] Launched for BLE central restoration: \(centralIDs)")
        }
        if let peripheralIDs = launchOptions?[.bluetoothPeripherals] as? [String] {
            print("[AppDelegate] Launched for BLE peripheral restoration: \(peripheralIDs)")
        }

        return true
    }

    // MARK: - APNs Token → FCM

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Pass the APNs token to FCM so it can generate an FCM token
        Messaging.messaging().apnsToken = deviceToken
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("[AppDelegate] APNs token registered: \(tokenString.prefix(20))...")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[AppDelegate] Failed to register for remote notifications: \(error.localizedDescription)")
    }

    // MARK: - Silent Push Handler

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        print("[AppDelegate] Silent push received")

        guard let locationService = backgroundTaskService.locationService else {
            print("[AppDelegate] No location service available for silent push")
            completionHandler(.noData)
            return
        }

        Task { @MainActor in
            locationService.performBackgroundUploadAndQuery()
            // Give Firestore operations time to complete
            try? await Task.sleep(for: .seconds(5))
            completionHandler(.newData)
            print("[AppDelegate] Silent push handling completed")
        }
    }

    // MARK: - Foreground Notification Display

    // Show notification banners even when the app is in the foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

@main
struct NameTagApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
