import Foundation
import FirebaseAuth

@Observable
final class LoginViewModel {
    var email = ""
    var password = ""
    var stayLoggedIn = true
    var isLoading = false
    var errorMessage: String?

    var isFormValid: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && trimmed.contains(".") && !password.isEmpty
    }

    func signIn(using appState: AppState) async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedEmail.contains("@"), trimmedEmail.contains(".") else {
            errorMessage = "Please enter a valid email address."
            return
        }
        guard !password.isEmpty else {
            errorMessage = "Please enter your password."
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            try await appState.authService.signIn(email: trimmedEmail, password: password)
            UserDefaults.standard.set(stayLoggedIn, forKey: "stayLoggedIn")
        } catch {
            errorMessage = friendlyErrorMessage(for: error)
        }

        isLoading = false
    }

    private func friendlyErrorMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == AuthErrors.domain {
            switch AuthErrorCode(rawValue: nsError.code) {
            case .wrongPassword, .invalidCredential:
                return "Incorrect email or password. Please try again."
            case .userNotFound:
                return "No account found with this email. Try creating an account."
            case .invalidEmail:
                return "Please enter a valid email address."
            case .userDisabled:
                return "This account has been disabled."
            case .tooManyRequests:
                return "Too many failed attempts. Please wait a moment and try again."
            case .networkError:
                return "Network error. Please check your connection and try again."
            default:
                break
            }
        }

        let message = error.localizedDescription
        if message.contains("no user record") || message.contains("user may have been deleted") {
            return "No account found with this email. Try creating an account."
        } else if message.contains("password is invalid") || message.contains("wrong password") {
            return "Incorrect email or password. Please try again."
        } else if message.contains("network") {
            return "Network error. Please check your connection and try again."
        }
        return message
    }
}
