import Foundation
import BackgroundTasks
import UIKit

/// Manages BGAppRefreshTask scheduling for periodic background location refresh.
final class BackgroundTaskService {
    weak var locationService: LocationService?

    /// Register the BGAppRefreshTask handler. Must be called in
    /// `application(_:didFinishLaunchingWithOptions:)` BEFORE returning.
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTask.locationRefreshIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            self?.handleAppRefresh(task: refreshTask)
        }
    }

    /// Schedule the next background app refresh. Call this:
    /// 1. When the app enters background (from scenePhase handler)
    /// 2. At the end of each BGAppRefreshTask completion
    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(
            identifier: BackgroundTask.locationRefreshIdentifier
        )
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[BGTask] Scheduled app refresh")
        } catch {
            print("[BGTask] Failed to schedule app refresh: \(error.localizedDescription)")
        }
    }

    private func handleAppRefresh(task: BGAppRefreshTask) {
        print("[BGTask] App refresh task started")

        // Schedule the next refresh before doing work
        scheduleAppRefresh()

        let workTask = Task { @MainActor [weak self] in
            guard let locationService = self?.locationService else {
                task.setTaskCompleted(success: false)
                return
            }
            locationService.performBackgroundUploadAndQuery()
            // Allow time for Firestore operations
            try? await Task.sleep(for: .seconds(5))
            task.setTaskCompleted(success: true)
            print("[BGTask] App refresh task completed")
        }

        // Handle task expiration
        task.expirationHandler = {
            workTask.cancel()
            task.setTaskCompleted(success: false)
            print("[BGTask] App refresh task expired")
        }
    }
}
