import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var authStore: AuthStateStore

    var body: some View {
        SatChartAuthShell(
            title: "Welcome to SatChart",
            subtitle: "Sign in with email to use the Bristol Bay analytics and map tools."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if let errorMessage = authStore.errorMessage {
                    AuthMessageBanner(text: errorMessage, kind: .error)
                }

                if let infoMessage = authStore.infoMessage {
                    AuthMessageBanner(text: infoMessage, kind: .info)
                }

                Text("Use your verified SatChart account to access Bristol Bay analytics and navigation tools during beta testing.")
                    .font(.footnote)
                    .foregroundStyle(scTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                AuthPrimaryButton("Create Account", systemImage: "person.crop.circle.badge.plus") {
                    authStore.show(.createAccount)
                }

                AuthSecondaryButton("Sign In", systemImage: "person.crop.circle") {
                    authStore.show(.signIn)
                }

                AuthFooterLinks()
            }
        }
    }
}
