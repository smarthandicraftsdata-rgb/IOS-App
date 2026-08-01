import SwiftUI

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

    var body: some View {
        ZStack {
            LinearGradient(colors: [SHLampTheme.backgroundTop, SHLampTheme.background], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    BrandHeader(subtitle: "Smart Handicrafts® connected lighting")
                        .padding(.top, 26)

                    VStack(spacing: 18) {
                        if mode != .reset {
                            Picker("Account mode", selection: $mode) {
                                Text("Sign in").tag(AccountMode.signIn)
                                Text("Create").tag(AccountMode.register)
                            }
                            .pickerStyle(.segmented)
                        }

                        if mode == .register {
                            TextField("Your name", text: $name)
                                .textContentType(.name)
                                .textFieldStyle(.roundedBorder)
                        }

                        if mode == .reset {
                            resetContent
                        } else {
                            TextField("Email address", text: $email)
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)

                            SecureField("Password", text: $password)
                                .textContentType(mode == .register ? .newPassword : .password)
                                .textFieldStyle(.roundedBorder)

                            if mode == .register {
                                SecureField("Confirm password", text: $confirmPassword)
                                    .textContentType(.newPassword)
                                    .textFieldStyle(.roundedBorder)
                            }

                            Button {
                                Task {
                                    if mode == .register {
                                        guard password == confirmPassword else { model.errorMessage = "Passwords do not match."; return }
                                        await model.register(name: name, email: email, password: password)
                                    } else {
                                        await model.signIn(email: email, password: password)
                                    }
                                }
                            } label: {
                                HStack {
                                    if model.busy { ProgressView().tint(.white) }
                                    Text(mode == .register ? "Create account" : "Sign in").fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(SHLampTheme.primary)
                            .disabled(model.busy || email.isEmpty || password.count < 6 || (mode == .register && name.isEmpty))

                            Button("Forgot password?") { mode = .reset; resetStage = 0; model.errorMessage = "" }
                                .foregroundStyle(SHLampTheme.primary)
                        }

                        if !model.errorMessage.isEmpty {
                            Label(model.errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(SHLampTheme.error)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(SHLampTheme.errorSoft)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        if !model.notice.isEmpty {
                            Text(model.notice).font(.footnote).foregroundStyle(SHLampTheme.success)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .shCard()

                    Text("By continuing, you connect this app to the SH Lamp cloud service. Bluetooth and local-network permissions are requested only when needed.")
                        .font(.caption)
                        .foregroundStyle(SHLampTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
    }

    @ViewBuilder
    private var resetContent: some View {
        if resetStage == 0 {
            Text("Reset your password").font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading)
            TextField("Email address", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .textFieldStyle(.roundedBorder)
            Button("Request reset code") {
                Task {
                    if let result = await model.requestPasswordReset(email: email) {
                        model.notice = result.message
                        if let debug = result.debugResetToken { resetToken = debug }
                        resetStage = 1
                    }
                }
            }
            .buttonStyle(.borderedProminent).tint(SHLampTheme.primary).disabled(email.isEmpty || model.busy)
        } else {
            TextField("Reset code", text: $resetToken).textFieldStyle(.roundedBorder)
            SecureField("New password", text: $password).textFieldStyle(.roundedBorder)
            SecureField("Confirm new password", text: $confirmPassword).textFieldStyle(.roundedBorder)
            Button("Set new password") {
                Task {
                    guard password == confirmPassword else { model.errorMessage = "Passwords do not match."; return }
                    if await model.confirmPasswordReset(token: resetToken, password: password) { mode = .signIn }
                }
            }
            .buttonStyle(.borderedProminent).tint(SHLampTheme.primary)
            .disabled(resetToken.isEmpty || password.count < 6 || model.busy)
        }
        Button("Back to sign in") { mode = .signIn; resetStage = 0 }
            .foregroundStyle(SHLampTheme.primary)
    }
}
