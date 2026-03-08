import Foundation
import FirebaseAuth
import UIKit

enum RegistrationStep {
    case credentials
    case profile
    case photo
}

enum ValidationError: LocalizedError {
    case invalidEmail
    case invalidPhone
    case passwordTooShort
    case missingFirstName
    case missingLastName
    case missingPhoto
    case accountCreationFailed

    var errorDescription: String? {
        switch self {
        case .invalidEmail:
            return "Please enter a valid email address."
        case .invalidPhone:
            return "Phone number must be 10 digits including area code."
        case .passwordTooShort:
            return "Password must be at least 6 characters."
        case .missingFirstName:
            return "Please enter your first name."
        case .missingLastName:
            return "Please enter your last name."
        case .missingPhoto:
            return "Please add a profile photo."
        case .accountCreationFailed:
            return "Account was created but setup failed. Please try signing in."
        }
    }
}

@Observable
final class RegistrationViewModel {
    var email = ""
    var phone = ""
    var password = ""
    var firstName = ""
    var lastName = ""
    var selectedImage: UIImage?
    var stayLoggedIn = true
    var emailSearchable = true
    var phoneSearchable = true
    var isLoading = false
    var errorMessage: String?
    var currentStep: RegistrationStep = .credentials

    var isEmailValid: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && trimmed.contains(".") && trimmed.count >= 5
    }

    /// Phone is valid if empty (optional) or exactly 10 digits (or 11 starting with 1).
    var isPhoneValid: Bool {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let digits = trimmed.filter(\.isNumber)
        return digits.count == 10 || (digits.count == 11 && digits.hasPrefix("1"))
    }

    var isPasswordValid: Bool {
        password.count >= 6
    }

    var isCredentialsStepValid: Bool {
        isEmailValid && isPasswordValid
    }

    var isProfileStepValid: Bool {
        !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        isPhoneValid
    }

    var isPhotoStepValid: Bool {
        selectedImage != nil
    }

    func validateAll() throws {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedEmail.contains("@"), trimmedEmail.contains("."), trimmedEmail.count >= 5 else {
            throw ValidationError.invalidEmail
        }
        guard isPhoneValid else {
            throw ValidationError.invalidPhone
        }
        guard password.count >= 6 else {
            throw ValidationError.passwordTooShort
        }
        guard !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.missingFirstName
        }
        guard !lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.missingLastName
        }
        guard selectedImage != nil else {
            throw ValidationError.missingPhoto
        }
    }

    func register(using appState: AppState) async {
        isLoading = true
        errorMessage = nil

        do {
            // Validate all fields before calling Firebase
            try validateAll()

            let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedFirst = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedLast = lastName.trimmingCharacters(in: .whitespacesAndNewlines)

            // Check if this email or phone is banned before creating the account
            if let emailBanned = try? await appState.adminService.isEmailBanned(trimmedEmail), emailBanned {
                errorMessage = "This email address is not eligible for registration."
                isLoading = false
                return
            }
            if !trimmedPhone.isEmpty {
                if let phoneBanned = try? await appState.adminService.isPhoneBanned(trimmedPhone), phoneBanned {
                    errorMessage = "This phone number is not eligible for registration."
                    isLoading = false
                    return
                }
            }

            // 1. Create auth account
            let uid: String
            do {
                uid = try await appState.authService.signUp(email: trimmedEmail, password: password)
            } catch {
                errorMessage = friendlyErrorMessage(for: error)
                currentStep = .credentials
                isLoading = false
                return
            }

            // 2. Upload required profile photo
            let photoURL: String
            do {
                photoURL = try await appState.storageService.uploadProfilePhoto(uid: uid, image: selectedImage!)
            } catch {
                errorMessage = "Photo upload failed. Please try signing in and updating your profile photo."
                isLoading = false
                return
            }

            // 3. Create Firestore user document
            let user = AppUser(
                id: uid,
                email: trimmedEmail,
                phone: trimmedPhone.isEmpty ? nil : trimmedPhone,
                firstName: trimmedFirst,
                lastName: trimmedLast,
                profilePhotoURL: photoURL,
                emailSearchable: emailSearchable,
                phoneSearchable: phoneSearchable
            )
            try await appState.userService.createUser(user)

            // 4. Save stay-logged-in preference
            UserDefaults.standard.set(stayLoggedIn, forKey: "stayLoggedIn")

            // 5. Fetch user to populate currentAppUser
            await appState.onAuthenticated()
        } catch let error as ValidationError {
            errorMessage = error.localizedDescription
            switch error {
            case .invalidEmail, .passwordTooShort:
                currentStep = .credentials
            case .invalidPhone, .missingFirstName, .missingLastName:
                currentStep = .profile
            case .missingPhoto:
                currentStep = .photo
            case .accountCreationFailed:
                break
            }
        } catch {
            errorMessage = friendlyErrorMessage(for: error)
        }

        isLoading = false
    }

    private func friendlyErrorMessage(for error: Error) -> String {
        // Check Firebase AuthErrorCode directly
        let nsError = error as NSError
        if nsError.domain == AuthErrors.domain {
            switch AuthErrorCode(rawValue: nsError.code) {
            case .emailAlreadyInUse:
                return "An account with this email already exists. Please sign in instead."
            case .invalidEmail:
                return "Please enter a valid email address."
            case .weakPassword:
                return "Password is too weak. Please use at least 6 characters."
            case .networkError:
                return "Network error. Please check your connection and try again."
            case .tooManyRequests:
                return "Too many attempts. Please wait a moment and try again."
            default:
                break
            }
        }

        // Fallback: check message strings
        let message = error.localizedDescription
        if message.contains("already in use") {
            return "An account with this email already exists. Please sign in instead."
        } else if message.contains("badly formatted") {
            return "Please enter a valid email address."
        } else if message.contains("network") {
            return "Network error. Please check your connection and try again."
        }
        return message
    }
}
