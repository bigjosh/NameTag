import Foundation
import FirebaseAuth

@Observable
final class AuthService {
    private(set) var currentUser: FirebaseAuth.User?
    private(set) var isAuthenticated = false
    private var authStateHandle: AuthStateDidChangeListenerHandle?

    init() {
        // If user chose not to stay logged in, sign them out now
        let stayLoggedIn = UserDefaults.standard.object(forKey: "stayLoggedIn") as? Bool ?? true
        if !stayLoggedIn {
            try? Auth.auth().signOut()
        }

        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            self?.currentUser = user
            self?.isAuthenticated = user != nil
        }
    }

    var currentUID: String? { currentUser?.uid }

    func signUp(email: String, password: String) async throws -> String {
        let result = try await Auth.auth().createUser(withEmail: email, password: password)
        return result.user.uid
    }

    func signIn(email: String, password: String) async throws {
        try await Auth.auth().signIn(withEmail: email, password: password)
    }

    func signOut() throws {
        UserDefaults.standard.removeObject(forKey: "stayLoggedIn")
        try Auth.auth().signOut()
    }

    func deleteAccount() async throws {
        guard let user = Auth.auth().currentUser else {
            throw AuthError.notAuthenticated
        }
        try await user.delete()
        UserDefaults.standard.removeObject(forKey: "stayLoggedIn")
    }
}

enum AuthError: LocalizedError {
    case notAuthenticated
    case requiresRecentLogin

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "No user is currently signed in."
        case .requiresRecentLogin:
            return "For security, please sign out and sign back in before deleting your account."
        }
    }
}
