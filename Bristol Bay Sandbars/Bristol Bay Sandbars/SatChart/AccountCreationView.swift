import SwiftUI

struct AccountCreationView: View {
    @EnvironmentObject private var authStore: AuthStateStore
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""

    var body: some View {
        SatChartAuthShell(
            title: "Create account",
            subtitle: "Create a verified email/password account for the production onboarding flow."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if let errorMessage = authStore.errorMessage {
                    AuthMessageBanner(text: errorMessage, kind: .error)
                }

                if let infoMessage = authStore.infoMessage {
                    AuthMessageBanner(text: infoMessage, kind: .info)
                }

                VStack(alignment: .leading, spacing: 8) {
                    AuthFormLabel(title: "Email")
                    TextField("you@email.com", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .authTextField()
                }

                VStack(alignment: .leading, spacing: 8) {
                    AuthFormLabel(title: "Password")
                    SecureField("At least 6 characters", text: $password)
                        .textContentType(.newPassword)
                        .authTextField()
                }

                VStack(alignment: .leading, spacing: 8) {
                    AuthFormLabel(title: "Confirm Password")
                    SecureField("Re-enter password", text: $confirmPassword)
                        .textContentType(.newPassword)
                        .authTextField()
                }

                Text("After creating your account, SatChart will send a verification email before continuing to legal acceptance and profile setup.")
                    .font(.footnote)
                    .foregroundStyle(scTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                AuthPrimaryButton(
                    "Create Account",
                    systemImage: "envelope.badge",
                    isLoading: authStore.isWorking
                ) {
                    Task {
                        await authStore.createAccount(
                            email: email,
                            password: password,
                            confirmPassword: confirmPassword
                        )
                    }
                }

                AuthSecondaryButton("Back", systemImage: "chevron.left") {
                    authStore.show(.welcome)
                }

                AuthFooterLinks()
            }
        }
    }
}
