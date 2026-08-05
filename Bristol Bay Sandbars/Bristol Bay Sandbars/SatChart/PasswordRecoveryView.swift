import SwiftUI

struct PasswordRecoveryView: View {
    @EnvironmentObject private var authStore: AuthStateStore
    @State private var email = ""

    var body: some View {
        SatChartAuthShell(
            title: "Reset password",
            subtitle: "SatChart will send a Firebase password reset email."
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

                AuthPrimaryButton(
                    "Send Reset Email",
                    systemImage: "paperplane",
                    isLoading: authStore.isWorking
                ) {
                    Task { await authStore.sendPasswordReset(email: email) }
                }

                AuthSecondaryButton("Back to Sign In", systemImage: "chevron.left") {
                    authStore.show(.signIn)
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
