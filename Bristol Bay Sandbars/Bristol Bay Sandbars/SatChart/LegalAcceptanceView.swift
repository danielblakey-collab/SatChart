import SwiftUI

struct LegalAcceptanceView: View {
    @EnvironmentObject private var authStore: AuthStateStore
    @State private var acceptedTerms = false
    @State private var acceptedSafetyNotice = false

    private var canContinue: Bool {
        acceptedTerms && acceptedSafetyNotice && !authStore.isWorking
    }

    var body: some View {
        SatChartAuthShell(
            title: "Safety and legal notice",
            subtitle: "Review and accept these notices before using SatChart."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if let errorMessage = authStore.errorMessage {
                    AuthMessageBanner(text: errorMessage, kind: .error)
                }

                if let infoMessage = authStore.infoMessage {
                    AuthMessageBanner(text: infoMessage, kind: .info)
                }

                Text("SatChart is designed for commercial fishing and maritime planning support. It is not a substitute for official navigation equipment, official nautical charts, weather warnings, fishery announcements, emergency orders, or operator judgment.")
                    .font(.footnote)
                    .foregroundStyle(scTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $acceptedSafetyNotice) {
                    Text("I understand SatChart is informational and does not replace official sources or safe vessel operation.")
                        .font(.footnote)
                        .foregroundStyle(scTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tint(scAccent)

                Toggle(isOn: $acceptedTerms) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("I agree to the SatChart Terms and Privacy Policy.")
                            .font(.footnote)
                            .foregroundStyle(scTextPrimary)

                        HStack(spacing: 14) {
                            Link("Privacy", destination: SatChartLegalLinks.privacy)
                            Link("Terms", destination: SatChartLegalLinks.terms)
                            Link("Support", destination: SatChartLegalLinks.support)
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(scAccent)
                    }
                }
                .tint(scAccent)

                Text("Questions? Email \(SatChartLegalLinks.supportEmail).")
                    .font(.caption)
                    .foregroundStyle(scTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                AuthPrimaryButton(
                    "Accept and Continue",
                    systemImage: "checkmark.circle",
                    isLoading: authStore.isWorking
                ) {
                    Task { await authStore.acceptLegalNotice() }
                }
                .disabled(!canContinue)
                .opacity(canContinue ? 1.0 : 0.55)

                AuthSecondaryButton("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                    Task { await authStore.signOut() }
                }
                .disabled(authStore.isWorking)
                .opacity(authStore.isWorking ? 0.55 : 1.0)
            }
        }
    }
}
