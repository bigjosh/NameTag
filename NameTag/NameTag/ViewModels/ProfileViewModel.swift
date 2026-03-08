import Foundation
import UIKit
import AVFoundation
import FirebaseAuth

@Observable
final class ProfileViewModel {
    var firstName = ""
    var lastName = ""
    var isHiddenFromSearch = false
    var emailSearchable = true
    var phoneSearchable = true
    var selectedImage: UIImage?
    var isEditing = false
    var isLoading = false
    var errorMessage: String?
    var successMessage: String?
    var showingPhotoOptions = false
    var showingCamera = false
    var showingCameraDeniedAlert = false

    // Account deletion state
    var showingDeleteConfirmation = false
    var isDeleting = false
    var deleteError: String?

    var isNameValid: Bool {
        !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasNameChanges: Bool {
        guard let user = originalUser else { return false }
        return firstName.trimmingCharacters(in: .whitespacesAndNewlines) != user.firstName ||
               lastName.trimmingCharacters(in: .whitespacesAndNewlines) != user.lastName
    }

    var hasPhotoChange: Bool {
        selectedImage != nil
    }

    var hasChanges: Bool {
        hasNameChanges || hasPhotoChange
    }

    private var originalUser: AppUser?

    func loadUser(from appState: AppState) {
        guard let user = appState.userService.currentAppUser else { return }
        originalUser = user
        firstName = user.firstName
        lastName = user.lastName
        isHiddenFromSearch = user.isHiddenFromSearch
        emailSearchable = user.emailSearchable
        phoneSearchable = user.phoneSearchable
        selectedImage = nil
    }

    func startEditing(from appState: AppState) {
        loadUser(from: appState)
        isEditing = true
        errorMessage = nil
        successMessage = nil
    }

    func requestCameraAccess() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            showingCamera = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted {
                        self.showingCamera = true
                    } else {
                        self.showingCameraDeniedAlert = true
                    }
                }
            }
        case .denied, .restricted:
            showingCameraDeniedAlert = true
        @unknown default:
            showingCameraDeniedAlert = true
        }
    }

    func cancelEditing() {
        if let user = originalUser {
            firstName = user.firstName
            lastName = user.lastName
        }
        selectedImage = nil
        isEditing = false
        errorMessage = nil
    }

    func toggleHiddenFromSearch(using appState: AppState) async {
        guard let uid = appState.authService.currentUID else { return }
        let newValue = isHiddenFromSearch
        do {
            try await appState.userService.updateHiddenFromSearch(uid: uid, isHidden: newValue)
        } catch {
            // Revert on failure
            isHiddenFromSearch = !newValue
            errorMessage = error.localizedDescription
        }
    }

    func updateSearchablePreference(field: String, using appState: AppState) async {
        guard let uid = appState.authService.currentUID else { return }
        let emailVal = emailSearchable
        let phoneVal = phoneSearchable
        do {
            try await appState.userService.updateSearchablePreferences(
                uid: uid,
                emailSearchable: emailVal,
                phoneSearchable: phoneVal
            )
        } catch {
            // Revert on failure
            if field == "email" { emailSearchable = !emailVal }
            if field == "phone" { phoneSearchable = !phoneVal }
            errorMessage = error.localizedDescription
        }
    }

    func deleteAccount(using appState: AppState) async {
        isDeleting = true
        deleteError = nil

        do {
            try await appState.deleteAccount()
        } catch {
            let nsError = error as NSError
            if nsError.domain == AuthErrorDomain,
               nsError.code == AuthErrorCode.requiresRecentLogin.rawValue {
                deleteError = "For security, please sign out and sign back in, then try again."
            } else {
                deleteError = error.localizedDescription
            }
            isDeleting = false
        }
    }

    func save(using appState: AppState) async {
        guard let uid = appState.authService.currentUID else {
            errorMessage = "Not signed in."
            return
        }

        guard isNameValid else {
            errorMessage = "First and last name are required."
            return
        }

        isLoading = true
        errorMessage = nil
        successMessage = nil

        do {
            let trimmedFirst = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedLast = lastName.trimmingCharacters(in: .whitespacesAndNewlines)

            // Update name if changed
            if hasNameChanges {
                try await appState.userService.updateProfile(
                    uid: uid,
                    firstName: trimmedFirst,
                    lastName: trimmedLast
                )
            }

            // Upload new photo if selected
            if let image = selectedImage {
                let url = try await appState.storageService.uploadProfilePhoto(uid: uid, image: image)
                try await appState.userService.updateProfilePhotoURL(uid: uid, url: url)
            }

            selectedImage = nil
            isEditing = false
            successMessage = "Profile updated!"

            // Refresh the original user reference
            originalUser = appState.userService.currentAppUser

            // Propagate profile changes to all connections so other users see updated tiles
            if let user = appState.userService.currentAppUser {
                await appState.connectionsService.updateProfileInConnections(
                    myUID: uid,
                    firstName: user.firstName,
                    lastName: user.lastName,
                    profilePhotoURL: user.profilePhotoURL
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
