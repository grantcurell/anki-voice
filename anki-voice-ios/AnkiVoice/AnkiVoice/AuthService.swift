//
//  AuthService.swift
//  AnkiVoice
//
//  Authentication service for Sign in with Apple and API token management
//

import Foundation
#if !NO_SIWA
import AuthenticationServices
#endif
import SwiftUI
#if os(iOS)
import UIKit
#endif
import os.log

// Shared logging function for AuthService
private func appLog(_ message: String, category: String = "auth") {
    let logger = Logger(subsystem: "anki.voice", category: category)
    logger.info("\(message)")
    #if DEBUG
    print("[\(category)] \(message)")
    #endif
}

// MARK: - Authentication Models

struct AppleAuthRequest: Codable {
    let identityToken: String
}

struct AppleAuthResponse: Codable {
    let jwt: String
    let user_id: String
}

struct AuthOut: Codable {
    let jwt: String
    let user_id: String
}

struct LocalRegisterRequest: Codable {
    let email: String
    let password: String
}

struct LocalLoginRequest: Codable {
    let email: String
    let password: String
}

struct LinkAnkiRequest: Codable {
    let email: String
    let password: String
}

struct LinkAnkiResponse: Codable {
    let status: String
}

struct SyncAnkiResponse: Codable {
    let status: String
}

// MARK: - Authentication Service

@MainActor
class AuthService: NSObject, ObservableObject {
    static let shared = AuthService()
    
    @Published var isAuthenticated: Bool = false
    @Published var currentUserID: String?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    
    private let keychainService = "com.grantcurell.anki-voice"
    private let jwtKey = "anki-voice-jwt"
    private let userIDKey = "anki-voice-user-id"
    
    private var baseURL: String {
        // Use production API URL
        return "https://api.grantcurell.com"
    }
    
    override init() {
        super.init()
        loadStoredCredentials()
    }
    
    // MARK: - Keychain Management
    
    private func loadStoredCredentials() {
        if let jwt = KeychainHelper.get(key: jwtKey, service: keychainService),
           let userID = KeychainHelper.get(key: userIDKey, service: keychainService) {
            self.currentUserID = userID
            self.isAuthenticated = true
            appLog("Loaded stored credentials for user: \(userID)", category: "auth")
        } else {
            appLog("No stored credentials found", category: "auth")
        }
    }
    
    /// Reload credentials from Keychain (useful after registration/login)
    func reloadCredentials() {
        loadStoredCredentials()
    }
    
    func getJWT() -> String? {
        return KeychainHelper.get(key: jwtKey, service: keychainService)
    }
    
    private func storeCredentials(jwt: String, userID: String) {
        KeychainHelper.save(key: jwtKey, value: jwt, service: keychainService)
        KeychainHelper.save(key: userIDKey, value: userID, service: keychainService)
        self.currentUserID = userID
        self.isAuthenticated = true
        appLog("Stored credentials for user: \(userID)", category: "auth")
    }
    
    func logout() {
        KeychainHelper.delete(key: jwtKey, service: keychainService)
        KeychainHelper.delete(key: userIDKey, service: keychainService)
        self.currentUserID = nil
        self.isAuthenticated = false
        appLog("Logged out", category: "auth")
    }
    
    // MARK: - Sign in with Apple
    
    #if !NO_SIWA
    func signInWithApple() {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        
        let authorizationController = ASAuthorizationController(authorizationRequests: [request])
        authorizationController.delegate = self
        authorizationController.presentationContextProvider = self
        authorizationController.performRequests()
    }
    #else
    func signInWithApple() {
        // Dev build without SiwA: show error message
        self.errorMessage = "Sign in with Apple is disabled in Debug builds."
        appLog("Sign in with Apple attempted but disabled in Debug build", category: "auth")
    }
    #endif
    
    // MARK: - API Calls
    
    func registerWithApple(identityToken: String) async throws -> AppleAuthResponse {
        guard let url = URL(string: "\(baseURL)/auth/apple") else {
            throw AuthError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = AppleAuthRequest(identityToken: identityToken)
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        
        if httpResponse.statusCode == 200 {
            let authResponse = try JSONDecoder().decode(AppleAuthResponse.self, from: data)
            storeCredentials(jwt: authResponse.jwt, userID: authResponse.user_id)
            return authResponse
        } else if httpResponse.statusCode == 401 {
            throw AuthError.invalidAppleToken
        } else if httpResponse.statusCode == 403 {
            throw AuthError.userBanned
        } else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AuthError.serverError(httpResponse.statusCode, errorMsg)
        }
    }
    
    func linkAnkiWeb(email: String, password: String) async throws -> LinkAnkiResponse {
        guard let jwt = getJWT() else {
            throw AuthError.notAuthenticated
        }
        
        guard let url = URL(string: "\(baseURL)/anki/link") else {
            throw AuthError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        
        let body = LinkAnkiRequest(email: email, password: password)
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        
        if httpResponse.statusCode == 200 {
            return try JSONDecoder().decode(LinkAnkiResponse.self, from: data)
        } else if httpResponse.statusCode == 401 {
            throw AuthError.notAuthenticated
        } else if httpResponse.statusCode == 422 {
            throw AuthError.validationError
        } else if httpResponse.statusCode == 424 {
            throw AuthError.provisioningFailed
        } else if httpResponse.statusCode == 504 {
            throw AuthError.tenantNotReady
        } else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AuthError.serverError(httpResponse.statusCode, errorMsg)
        }
    }
    
    func syncAnki() async throws -> SyncAnkiResponse {
        guard let jwt = getJWT() else {
            appLog("❌ syncAnki: Not authenticated - no JWT", category: "auth")
            throw AuthError.notAuthenticated
        }
        
        guard let url = URL(string: "\(baseURL)/anki/sync") else {
            appLog("❌ syncAnki: Invalid URL: \(baseURL)/anki/sync", category: "auth")
            throw AuthError.invalidURL
        }
        
        appLog("🔄 syncAnki: Starting sync request to \(url.absoluteString)", category: "auth")
        appLog("   JWT preview: \(String(jwt.prefix(20)))... (length: \(jwt.count))", category: "auth")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        
        let body: [String: String] = [:]
        request.httpBody = try JSONEncoder().encode(body)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                appLog("❌ syncAnki: Invalid response type", category: "auth")
                throw AuthError.invalidResponse
            }
            
            let statusCode = httpResponse.statusCode
            let responseBody = String(data: data, encoding: .utf8) ?? "<non-UTF8 data>"
            
            appLog("📡 syncAnki: Response status: \(statusCode)", category: "auth")
            appLog("   Response headers: \(httpResponse.allHeaderFields)", category: "auth")
            appLog("   Response body: \(responseBody)", category: "auth")
            
            if statusCode == 200 {
                let syncResponse = try JSONDecoder().decode(SyncAnkiResponse.self, from: data)
                appLog("✅ syncAnki: Success - \(syncResponse.status)", category: "auth")
                return syncResponse
            } else {
                appLog("❌ syncAnki: Server error \(statusCode): \(responseBody)", category: "auth")
                throw AuthError.serverError(statusCode, responseBody)
            }
        } catch let urlError as URLError {
            appLog("❌ syncAnki: Network error - \(urlError.localizedDescription)", category: "auth")
            appLog("   Error code: \(urlError.code.rawValue)", category: "auth")
            appLog("   Error domain: \(urlError.localizedDescription)", category: "auth")
            throw urlError
        } catch {
            appLog("❌ syncAnki: Unexpected error - \(error.localizedDescription)", category: "auth")
            appLog("   Error type: \(type(of: error))", category: "auth")
            throw error
        }
    }
    
    // MARK: - Local Authentication (Email/Password)
    
    func register(email: String, password: String) async throws -> AuthOut {
        guard let url = URL(string: "\(baseURL)/auth/local/register") else {
            throw AuthError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = LocalRegisterRequest(email: email, password: password)
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        
        if httpResponse.statusCode == 200 {
            let authResponse = try JSONDecoder().decode(AuthOut.self, from: data)
            storeCredentials(jwt: authResponse.jwt, userID: authResponse.user_id)
            return authResponse
        } else if httpResponse.statusCode == 409 {
            throw AuthError.emailExists
        } else if httpResponse.statusCode == 429 {
            throw AuthError.rateLimited
        } else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AuthError.serverError(httpResponse.statusCode, errorMsg)
        }
    }
    
    func login(email: String, password: String) async throws -> AuthOut {
        guard let url = URL(string: "\(baseURL)/auth/local/login") else {
            throw AuthError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = LocalLoginRequest(email: email, password: password)
        request.httpBody = try JSONEncoder().encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        
        if httpResponse.statusCode == 200 {
            let authResponse = try JSONDecoder().decode(AuthOut.self, from: data)
            storeCredentials(jwt: authResponse.jwt, userID: authResponse.user_id)
            return authResponse
        } else if httpResponse.statusCode == 401 {
            throw AuthError.invalidCredentials
        } else if httpResponse.statusCode == 403 {
            throw AuthError.userBanned
        } else if httpResponse.statusCode == 429 {
            throw AuthError.rateLimited
        } else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AuthError.serverError(httpResponse.statusCode, errorMsg)
        }
    }
    
    // MARK: - Helper to add Authorization header to requests
    
    func addAuthHeader(to request: inout URLRequest) {
        if let jwt = getJWT() {
            request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        }
    }
}

// MARK: - ASAuthorizationControllerDelegate

#if !NO_SIWA
extension AuthService: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
            guard let identityTokenData = appleIDCredential.identityToken,
                  let identityToken = String(data: identityTokenData, encoding: .utf8) else {
                Task { @MainActor in
                    self.errorMessage = "Failed to get identity token"
                }
                return
            }
            
            Task {
                await MainActor.run {
                    self.isLoading = true
                    self.errorMessage = nil
                }
                
                do {
                    let response = try await registerWithApple(identityToken: identityToken)
                    await MainActor.run {
                        self.isLoading = false
                        appLog("Successfully registered with Apple. User ID: \(response.user_id)", category: "auth")
                    }
                } catch {
                    await MainActor.run {
                        self.isLoading = false
                        self.errorMessage = error.localizedDescription
                        appLog("Registration failed: \(error.localizedDescription)", category: "auth")
                    }
                }
            }
        }
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Task { @MainActor in
            self.isLoading = false
            if let authError = error as? ASAuthorizationError {
                switch authError.code {
                case .canceled:
                    self.errorMessage = "Sign in was canceled"
                case .failed:
                    self.errorMessage = "Sign in failed"
                case .invalidResponse:
                    self.errorMessage = "Invalid response from Apple"
                case .notHandled:
                    self.errorMessage = "Sign in not handled"
                case .unknown:
                    self.errorMessage = "Unknown sign-in error"
                @unknown default:
                    self.errorMessage = "Unrecognized sign-in error"
                }
            } else {
                self.errorMessage = error.localizedDescription
            }
            appLog("Apple Sign-In error: \(error.localizedDescription)", category: "auth")
        }
    }
}
#endif

// MARK: - ASAuthorizationControllerPresentationContextProviding

#if !NO_SIWA
extension AuthService: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // Get the window from the scene
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) {
            return window
        }
        // Last resort (rare in practice)
        return UIWindow(frame: UIScreen.main.bounds)
    }
}
#endif

// MARK: - Auth Errors

enum AuthError: LocalizedError {
    case invalidURL
    case invalidResponse
    case notAuthenticated
    case invalidAppleToken
    case userBanned
    case validationError
    case provisioningFailed
    case tenantNotReady
    case emailExists
    case invalidCredentials
    case rateLimited
    case serverError(Int, String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .notAuthenticated:
            return "Not authenticated. Please sign in."
        case .invalidAppleToken:
            return "Invalid Apple sign-in token"
        case .userBanned:
            return "User account is banned"
        case .validationError:
            return "Invalid email or password format"
        case .provisioningFailed:
            return "Failed to provision your Anki environment"
        case .tenantNotReady:
            return "Anki environment is not ready yet. Please try again."
        case .emailExists:
            return "Email already in use"
        case .invalidCredentials:
            return "Email or password is incorrect"
        case .rateLimited:
            return "Too many requests. Please try again later."
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        }
    }
}

