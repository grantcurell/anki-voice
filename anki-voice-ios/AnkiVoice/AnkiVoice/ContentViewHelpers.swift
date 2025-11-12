//
//  ContentViewHelpers.swift
//  AnkiVoice
//
//  Extracted subviews to reduce ContentView complexity and fix type-checking timeout
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Top Bar View

struct TopBarView: View {
    @ObservedObject var authService: AuthService
    @ObservedObject var stt: SpeechSTT
    @Binding var showAuthSheet: Bool
    
    var body: some View {
        HStack {
            // Register/Logout button
            if !authService.isAuthenticated {
                RegisterButton(showAuthSheet: $showAuthSheet)
                
                #if !NO_SIWA
                SignInWithAppleButton(isLoading: authService.isLoading) {
                    authService.signInWithApple()
                }
                #endif
            } else {
                LogoutButton {
                    authService.logout()
                }
            }
            
            Spacer()
            
            MuteButton(stt: stt)
        }
        .padding(.horizontal)
    }
}

// MARK: - Register Button

struct RegisterButton: View {
    @Binding var showAuthSheet: Bool
    
    var body: some View {
        Button(action: {
            showAuthSheet = true
        }) {
            HStack {
                Image(systemName: "person.badge.plus")
                Text("Register / Sign in")
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)
        }
    }
}

// MARK: - Sign in with Apple Button

#if !NO_SIWA
struct SignInWithAppleButton: View {
    let isLoading: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "applelogo")
                }
                Text("Sign in with Apple")
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.1))
            .cornerRadius(8)
        }
        .disabled(isLoading)
    }
}
#endif

// MARK: - Logout Button

struct LogoutButton: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "person.crop.circle.badge.minus")
                Text("Logout")
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.1))
            .cornerRadius(8)
        }
    }
}

// MARK: - Mute Button

struct MuteButton: View {
    @ObservedObject var stt: SpeechSTT
    
    var body: some View {
        Button(action: {
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
            stt.setMuted(!stt.isMuted)
        }) {
            Image(systemName: stt.isMuted ? "mic.slash.fill" : "mic.fill")
                .font(.title2)
                .foregroundColor(stt.isMuted ? .red : .primary)
                .padding(8)
                .overlay(
                    Group {
                        if stt.isMuted {
                            Circle().stroke(Color.red, lineWidth: 1.5)
                        }
                    }
                )
                .accessibilityLabel(stt.isMuted ? "Microphone muted" : "Microphone on")
                .accessibilityHint("Double tap to toggle microphone")
        }
    }
}

// MARK: - Authentication Status View

struct AuthStatusView: View {
    @ObservedObject var authService: AuthService
    
    var body: some View {
        VStack(spacing: 8) {
            if authService.isAuthenticated {
                Text("Signed in")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Text("Not signed in")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            
            if let errorMsg = authService.errorMessage {
                Text(errorMsg)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// MARK: - Link AnkiWeb Form View

struct LinkAnkiWebFormView: View {
    @ObservedObject var authService: AuthService
    @Binding var showLinkAnkiForm: Bool
    @Binding var ankiEmail: String
    @Binding var ankiPassword: String
    @Binding var isLinkingAnki: Bool
    let linkAction: () async -> Void
    
    var body: some View {
        if authService.isAuthenticated && !showLinkAnkiForm {
            Button("Link AnkiWeb Account") {
                showLinkAnkiForm = true
            }
            .font(.headline)
            .padding(.vertical, 10)
            .padding(.horizontal, 20)
            .background(Color.green.opacity(0.1))
            .cornerRadius(10)
        }
        
        if showLinkAnkiForm {
            VStack(spacing: 12) {
                Text("Link AnkiWeb Account")
                    .font(.headline)
                
                TextField("AnkiWeb Email", text: $ankiEmail)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                
                SecureField("AnkiWeb Password", text: $ankiPassword)
                    .textFieldStyle(.roundedBorder)
                
                HStack {
                    Button("Cancel") {
                        showLinkAnkiForm = false
                        ankiEmail = ""
                        ankiPassword = ""
                    }
                    .foregroundColor(.gray)
                    
                    Button("Link") {
                        Task {
                            await linkAction()
                        }
                    }
                    .disabled(ankiEmail.isEmpty || ankiPassword.isEmpty || isLinkingAnki)
                    .foregroundColor(.blue)
                }
                
                if isLinkingAnki {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(10)
            .padding(.horizontal)
        }
    }
}

