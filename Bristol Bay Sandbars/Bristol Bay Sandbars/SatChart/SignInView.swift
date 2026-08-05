import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var authStore: AuthStateStore
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        SatChartAuthShell(
            title: "Sign in",
            subtitle: "Use the email and password for your SatChart account."
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
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .authTextField()
                }

                AuthPrimaryButton(
                    "Sign In",
                    systemImage: "arrow.right.circle",
                    isLoading: authStore.isWorking
                ) {
                    Task { await authStore.signIn(email: email, password: password) }
                }

                AuthSecondaryButton("Reset Password", systemImage: "key") {
                    authStore.show(.passwordRecovery)
                }

                AuthSecondaryButton("Back", systemImage: "chevron.left") {
                    authStore.show(.welcome)
                }

                AuthFooterLinks()
            }
        }
        .onAppear {
            if email.isEmpty {
                email = authStore.activeEmail
            }
        }
    }
}
