import SwiftUI

struct EmailVerificationView: View {
    @EnvironmentObject private var authStore: AuthStateStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let cooldownRemaining = authStore.verificationEmailCooldownRemaining(now: context.date)
            let resendDisabled = authStore.isWorking || cooldownRemaining > 0

            SatChartAuthShell(
                title: "Verify your email",
                subtitle: "We sent a verification email to your account email address."
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    if let errorMessage = authStore.errorMessage {
                        AuthMessageBanner(text: errorMessage, kind: .error)
                    }

                    if let infoMessage = authStore.infoMessage {
                        AuthMessageBanner(text: infoMessage, kind: .info)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        AuthFormLabel(title: "Account Email")
                        Text(authStore.activeEmail.isEmpty ? "Your account email" : authStore.activeEmail)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(scTextPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Check your email folders", systemImage: "tray.full")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(scTextPrimary)

                        Text("Open the email and tap the verification link to continue. Email delivery can take a minute or two.")
                            .font(.footnote)
                            .foregroundStyle(scTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("If you do not see it, check your Inbox, Junk, Spam, Promotions, or Clutter folder. The sender may appear as SatChart, Firebase / no-reply, or noreply@auth.getsatchart.com.")
                            .font(.footnote)
                            .foregroundStyle(scTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(scSurfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Text("After tapping the link, return to SatChart and tap 'I Verified My Email'.")
                        .font(.footnote)
                        .foregroundStyle(scTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    AuthPrimaryButton(
                        "I Verified My Email",
                        systemImage: "checkmark.seal",
                        isLoading: authStore.isWorking
                    ) {
                        Task { await authStore.refreshEmailVerificationStatus() }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("If the email never arrives, you can resend it below. To avoid delivery problems, wait at least 60 seconds before resending.")
                            .font(.caption)
                            .foregroundStyle(scTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        AuthSecondaryButton(
                            cooldownRemaining > 0 ? "Resend in \(cooldownRemaining)s" : "Resend Verification Email",
                            systemImage: "envelope"
                        ) {
                            Task { await authStore.sendVerificationEmail() }
                        }
                        .disabled(resendDisabled)
                        .opacity(resendDisabled ? 0.55 : 1.0)
                    }

                    AuthSecondaryButton("Change Email or Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                        Task { await authStore.signOut() }
                    }
                    .disabled(authStore.isWorking)
                    .opacity(authStore.isWorking ? 0.55 : 1.0)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Still having trouble? Contact \(SatChartLegalLinks.supportEmail).")
                            .font(.caption)
                            .foregroundStyle(scTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Link(destination: SatChartLegalLinks.support) {
                            HStack(spacing: 8) {
                                Image(systemName: "lifepreserver")
                                Text("Contact Support")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 46)
                            .padding(.horizontal, 14)
                            .foregroundStyle(scTextPrimary)
                            .background(scSurfaceAlt)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(SatChartPressFeedbackButtonStyle())
                    }

                    AuthFooterLinks()
                }
            }
        }
    }
}
