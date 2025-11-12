//
//  AuthSheet.swift
//  AnkiVoice
//
//  Registration and login UI for email/password authentication
//

import SwiftUI

struct AuthSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var authService: AuthService
    
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isRegisterMode: Bool = false
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    
                    SecureField("Password", text: $password)
                        .textContentType(isRegisterMode ? .newPassword : .password)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                } header: {
                    Text(isRegisterMode ? "Create Account" : "Sign In")
                } footer: {
                    if let errorMessage = errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
                
                Section {
                    Button(action: {
                        Task {
                            await handleAuth()
                        }
                    }) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                            }
                            Text(isRegisterMode ? "Create Account" : "Sign In")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(isLoading || email.isEmpty || password.isEmpty)
                    
                    Button(action: {
                        isRegisterMode.toggle()
                        errorMessage = nil
                    }) {
                        Text(isRegisterMode ? "Already have an account? Sign in" : "Don't have an account? Create one")
                    }
                    .foregroundColor(.blue)
                }
            }
            .navigationTitle(isRegisterMode ? "Register" : "Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    @MainActor
    private func handleAuth() async {
        isLoading = true
        errorMessage = nil
        
        do {
            if isRegisterMode {
                _ = try await authService.register(email: email, password: password)
            } else {
                _ = try await authService.login(email: email, password: password)
            }
            
            // Success - reload credentials to ensure state is updated
            // This ensures the JWT is available immediately after registration/login
            authService.reloadCredentials()
            
            // Verify authentication state
            if authService.isAuthenticated, let jwt = authService.getJWT() {
                appLog("Authentication successful, JWT available (length: \(jwt.count))", category: "auth")
            } else {
                appLog("WARNING: Authentication succeeded but JWT not available", category: "auth")
            }
            
            // Small delay to ensure state propagates to parent view
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            
            // Dismiss the sheet
            isLoading = false
            dismiss()
        } catch {
            isLoading = false
            if let authError = error as? AuthError {
                errorMessage = authError.localizedDescription
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}

