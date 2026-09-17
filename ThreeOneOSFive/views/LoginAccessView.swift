import SwiftUI
import UIKit

struct SecureLoginView: View {
    @ObservedObject var manager: LicenseManager
    let onActivate: (String) async -> Void

    @State private var accessKey = ""
    @State private var isSubmitting = false
    @FocusState private var keyFocused: Bool

    var body: some View {
        ZStack {
            LoginBackdrop()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    Spacer(minLength: 44)

                    LoginMark()

                    VStack(spacing: 8) {
                        Text("PROXY SYSTEM")
                            .font(.caption.weight(.bold))
                            .tracking(2.4)
                            .foregroundStyle(Color.cyan.opacity(0.92))

                        Text("Secure access")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)

                        Text("Sign in with your iOS access key")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.62))
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield.fill")
                        Text("Device-bound verification")
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.mint)

                    loginCard

                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                        Text("PROTECTED CONNECTION")
                    }
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.38))
                    .padding(.bottom, 30)
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .scrollDismissesKeyboard(.interactively)
        .onAppear { keyFocused = true }
    }

    private var loginCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ACCESS KEY")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.58))

            HStack(spacing: 12) {
                Image(systemName: "key.horizontal.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.cyan)

                TextField("PROXY-SYSTEM-…", text: $accessKey)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($keyFocused)
                    .onSubmit { submit() }

                if !accessKey.isEmpty {
                    Button { accessKey = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.42))
                    }
                    .buttonStyle(.plain)
                }

                Button("Paste") {
                    accessKey = UIPasteboard.general.string ?? accessKey
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.cyan)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 58)
            .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            }

            Button(action: submit) {
                HStack(spacing: 10) {
                    if isSubmitting {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: "arrow.right.circle.fill")
                        Text("Continue securely")
                            .fontWeight(.bold)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 58)
                .foregroundStyle(.black)
                .background(
                    LinearGradient(
                        colors: [Color.cyan, Color.blue.opacity(0.88)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
            .disabled(accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
            .opacity(accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.48 : 1)
            .buttonStyle(.plain)

            if let errorMessage = manager.message {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.red.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Your key is checked over HTTPS and stored only in the iOS Keychain after successful validation.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.48))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
        .padding(22)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.26), Color.cyan.opacity(0.2), Color.white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(0.35), radius: 28, y: 16)
        .padding(.horizontal, 20)
    }

    private func submit() {
        guard !isSubmitting else { return }
        let trimmed = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSubmitting = true
        Task {
            await onActivate(trimmed)
            await MainActor.run { isSubmitting = false }
        }
    }
}

private struct LoginBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.025, green: 0.04, blue: 0.09), Color(red: 0.015, green: 0.018, blue: 0.04)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Color.cyan.opacity(0.12))
                .frame(width: 260, height: 260)
                .blur(radius: 24)
                .offset(x: 100, y: -80)
        }
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(Color.blue.opacity(0.1))
                .frame(width: 220, height: 220)
                .blur(radius: 32)
                .offset(x: -100, y: 100)
        }
        .ignoresSafeArea()
    }
}

private struct LoginMark: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.cyan, Color.blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 86, height: 86)
        .shadow(color: Color.cyan.opacity(0.28), radius: 22, y: 8)
        .accessibilityLabel("Proxy System secure access")
    }
}
