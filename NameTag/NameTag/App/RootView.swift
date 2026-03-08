import SwiftUI

struct RootView: View {
    @State private var appState = AppState()
    @State private var isLoading = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading...")
            } else if appState.isBanned {
                BannedUserView()
            } else if appState.hasCompletedOnboarding {
                MainTabView()
            } else if appState.authService.isAuthenticated {
                ProgressView("Setting up...")
                    .task {
                        await appState.onAuthenticated()
                    }
            } else {
                LoginView()
            }
        }
        .environment(appState)
        .onChange(of: appState.authService.isAuthenticated) { _, isAuth in
            if isAuth {
                Task { await appState.onAuthenticated() }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                // When backgrounding, clear the Nearby tab flag so notifications
                // can fire for NEW contacts discovered while the app is backgrounded.
                // Contacts already seen on the Nearby tab are in suppressedUIDs and
                // won't re-notify.
                appState.notificationGatekeeper.isOnNearbyTab = false
                print("[RootView] App entered background — notifications enabled")
                appState.recheckNearbyNotifications()

                // Schedule background app refresh for periodic location updates
                if let delegate = UIApplication.shared.delegate as? AppDelegate {
                    delegate.backgroundTaskService.locationService = appState.locationService
                    delegate.backgroundTaskService.scheduleAppRefresh()
                }
            case .active:
                // Cancel any pending notifications that haven't fired yet —
                // the user is back in the app
                appState.notificationGatekeeper.cancelPendingNotifications()
                // Restart services that iOS suspends in the background
                // (Multipeer, Bonjour, BLE re-scan) so contacts are detected immediately
                appState.resumeForegroundServices()
                print("[RootView] App became active — services resumed")
            default:
                break
            }
        }
        .task {
            // Brief delay for Firebase auth state to settle
            try? await Task.sleep(for: .milliseconds(500))
            if appState.authService.isAuthenticated {
                await appState.onAuthenticated()
            }
            isLoading = false
        }
    }
}
