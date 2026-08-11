import SwiftUI
import UIKit

private enum AccountMode: String, CaseIterable {
    case signIn = "Sign in"
    case register = "Create account"
    case reset = "Reset password"
}

struct AccountView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var mode: AccountMode = .signIn
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var resetToken = ""
    @State private var resetStage = 0

    private var cleanEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmitAccount: Bool {
        !model.busy && !cleanEmail.isEmpty && password.count >= 6 && (mode != .register || !cleanName.isEmpty)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [SHLampTheme.backgroundTop, SHLampTheme.background], startPoint: .topLeading, endPoint: .bottom)
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    VStack(spacing: 14) {
                        ZStack {
                            Circle().fill(SHLampTheme.primarySoft).frame(width: 118, height: 118).blur(radius: 6)
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .fill(.white.opacity(0.72))
                                .frame(width: 96, height: 96)
                            BrandLogoView(size: 64)
                        }
                        .padding(.top, 10)

                        VStack(spacing: 6) {
                            Text("Smart Handicrafts®")
                                .font(.title2.bold())
                                .foregroundStyle(SHLampTheme.textPrimary)
                            Text("Sign in to control your SH Lamp devices")
                                .font(.subheadline)
                                .foregroundStyle(SHLampTheme.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.top, 24)

                    VStack(spacing: 18) {
                        if mode != .reset {
                            Picker("Account mode", selection: $mode) {
                                Text("Sign in").tag(AccountMode.signIn)
                                Text("Create").tag(AccountMode.register)
                            }
                            .pickerStyle(.segmented)
                        }

                        if mode == .register {
                            shTextField(title: "Your name", text: $name, contentType: .name, capitalization: .words)
                        }

                        if mode == .reset {
                            resetContent
                        } else {
                            shTextField(title: "Email address", text: $email, contentType: .emailAddress, keyboardType: .emailAddress)

                            shSecureField(title: "Password", text: $password, contentType: mode == .register ? .newPassword : .password)

                            if mode == .register {
                                shSecureField(title: "Confirm password", text: $confirmPassword, contentType: .newPassword)
                            }

                            Button {
                                Task {
                                    if mode == .register {
                                        guard password == confirmPassword else {
                                            model.errorMessage = "Passwords do not match."
                                            return
                                        }
                                        await model.register(name: name, email: email, password: password)
                                    } else {
                                        await model.signIn(email: email, password: password)
                                    }
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    if model.busy { ProgressView().tint(.white) }
                                    Text(mode == .register ? "Create account" : "Sign in")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(SHLampTheme.primary)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            }
                            .disabled(!canSubmitAccount)
                            .opacity(canSubmitAccount ? 1 : 0.5)

                            Button("Forgot password?") {
                                mode = .reset
                                resetStage = 0
                                model.errorMessage = ""
                            }
                            .foregroundStyle(SHLampTheme.primary)
                        }

                        if !model.errorMessage.isEmpty {
                            Label(model.errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(SHLampTheme.error)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(SHLampTheme.errorSoft)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        if !model.notice.isEmpty {
                            Text(model.notice)
                                .font(.footnote)
                                .foregroundStyle(SHLampTheme.success)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .shGlassCard(padding: 20, radius: 30)

                    Text("Bluetooth and local-network permissions are requested only when needed for lamp setup and control.")
                        .font(.caption)
                        .foregroundStyle(SHLampTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
        .onChange(of: mode) { _, _ in
            model.errorMessage = ""
            model.notice = ""
            password = ""
            confirmPassword = ""
        }
    }

    @ViewBuilder
    private var resetContent: some View {
        if resetStage == 0 {
            SectionHeader("Reset your password", subtitle: "We will send a reset code to your email.")
                .frame(maxWidth: .infinity, alignment: .leading)
            shTextField(title: "Email address", text: $email, contentType: .emailAddress, keyboardType: .emailAddress)
            Button("Request reset code") {
                Task {
                    if let result = await model.requestPasswordReset(email: email) {
                        model.notice = result.message
                        if let debug = result.debugResetToken { resetToken = debug }
                        resetStage = 1
                    }
                }
            }
            .primaryButtonStyle(disabled: cleanEmail.isEmpty || model.busy)
        } else {
            shTextField(title: "Reset code", text: $resetToken)
            shSecureField(title: "New password", text: $password, contentType: .newPassword)
            shSecureField(title: "Confirm new password", text: $confirmPassword, contentType: .newPassword)
            Button("Set new password") {
                Task {
                    guard password == confirmPassword else {
                        model.errorMessage = "Passwords do not match."
                        return
                    }
                    if await model.confirmPasswordReset(token: resetToken, password: password) {
                        mode = .signIn
                    }
                }
            }
            .primaryButtonStyle(disabled: resetToken.isEmpty || password.count < 6 || model.busy)
        }
        Button("Back to sign in") {
            mode = .signIn
            resetStage = 0
        }
        .foregroundStyle(SHLampTheme.primary)
    }

    private func shTextField(
        title: String,
        text: Binding<String>,
        contentType: UITextContentType? = nil,
        keyboardType: UIKeyboardType = .default,
        capitalization: TextInputAutocapitalization = .never
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(SHLampTheme.textSecondary)
            TextField(title, text: text)
                .textContentType(contentType)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(capitalization)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(.white.opacity(0.78))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(SHLampTheme.border.opacity(0.75), lineWidth: 1))
        }
    }

    private func shSecureField(title: String, text: Binding<String>, contentType: UITextContentType? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(SHLampTheme.textSecondary)
            SecureField(title, text: text)
                .textContentType(contentType)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(.white.opacity(0.78))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(SHLampTheme.border.opacity(0.75), lineWidth: 1))
        }
    }
}

private extension View {
    func primaryButtonStyle(disabled: Bool) -> some View {
        self
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(disabled ? SHLampTheme.primary.opacity(0.45) : SHLampTheme.primary)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .disabled(disabled)
    }
}
