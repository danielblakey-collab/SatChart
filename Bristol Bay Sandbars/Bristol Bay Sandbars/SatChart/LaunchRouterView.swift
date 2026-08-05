import SwiftUI

struct LaunchRouterView: View {
    @StateObject private var authStore = AuthStateStore()
    @State private var visibleOfflineAccountBannerText: String?

    var body: some View {
        Group {
            switch authStore.route {
            case .loading:
                LaunchLoadingView()
            case .welcome:
                WelcomeView()
            case .createAccount:
                AccountCreationView()
            case .signIn:
                SignInView()
            case .passwordRecovery:
                PasswordRecoveryView()
            case .emailVerification:
                EmailVerificationView()
            case .legalAcceptance:
                LegalAcceptanceView()
            case .profileSetup:
                UserProfileSetupView()
            case .accountUnavailable:
                AccountUnavailableView()
            case .app:
                BootstrapView()
                    .overlay(alignment: .top) {
                        if let banner = visibleOfflineAccountBannerText {
                            Text(banner)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(scTextPrimary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(scSurface.opacity(0.96))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .padding(.horizontal, 18)
                                .padding(.top, 12)
                        }
                    }
            }
        }
        .environmentObject(authStore)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: authStore.route)
        .animation(.easeInOut(duration: 0.2), value: visibleOfflineAccountBannerText)
        .task(id: authStore.offlineAccountBannerText) {
            await updateVisibleOfflineAccountBanner(authStore.offlineAccountBannerText)
        }
    }

    private func updateVisibleOfflineAccountBanner(_ text: String?) async {
        await MainActor.run {
            visibleOfflineAccountBannerText = text
        }

        guard text != nil else { return }

        try? await Task.sleep(nanoseconds: 5_000_000_000)
        guard !Task.isCancelled else { return }

        await MainActor.run {
            visibleOfflineAccountBannerText = nil
        }
    }
}

private struct LaunchLoadingView: View {
    var body: some View {
        SatChartAuthShell(
            title: "SatChart",
            subtitle: "Preparing your account."
        ) {
            HStack(spacing: 12) {
                ProgressView()
                    .tint(.white)

                Text("Checking authentication...")
                    .font(.subheadline)
                    .foregroundStyle(scTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AccountUnavailableView: View {
    @EnvironmentObject private var authStore: AuthStateStore

    var body: some View {
        SatChartAuthShell(
            title: authStore.accountUnavailableTitle,
            subtitle: authStore.accountUnavailableSubtitle
        ) {
            VStack(alignment: .leading, spacing: 16) {
                AuthMessageBanner(
                    text: authStore.accountLoadError ?? "Try again or contact support@getsatchart.com.",
                    kind: .error
                )

                AuthPrimaryButton(
                    "Try Again",
                    systemImage: "arrow.clockwise",
                    isLoading: authStore.isWorking
                ) {
                    Task { await authStore.retryAccountLoad() }
                }

                AuthSecondaryButton("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                    Task { await authStore.signOut() }
                }

                AuthFooterLinks()
            }
        }
    }
}

enum SatChartLegalLinks {
    static let privacy = SatChartReleaseConfiguration.privacyPolicyURL
    static let terms = SatChartReleaseConfiguration.termsURL
    static let support = SatChartReleaseConfiguration.supportURL
    static let supportEmail = SatChartReleaseConfiguration.supportEmail
}

struct SatChartAuthShell<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ZStack {
            scBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                menuBlue
                    .frame(height: 10)
                    .ignoresSafeArea(edges: .top)

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        SatChartBrandHeader()

                        VStack(alignment: .leading, spacing: 8) {
                            Text(title)
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(scTextPrimary)

                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(scTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(alignment: .leading, spacing: 18) {
                            content
                        }
                        .padding(18)
                        .background(scSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .frame(maxWidth: 520, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 30)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct SatChartBrandHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(menuBlue)

                Image(systemName: "wave.3.right")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text("SatChart")
                    .font(.headline)
                    .foregroundStyle(scTextPrimary)

                Text("Bristol Bay fisheries analytics")
                    .font(.caption)
                    .foregroundStyle(scTextSecondary)
            }
        }
    }
}

enum AuthMessageKind {
    case error
    case info
}

struct AuthMessageBanner: View {
    let text: String
    let kind: AuthMessageKind

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(kind == .error ? Color.orange : Color.green)

            Text(text)
                .font(.footnote)
                .foregroundStyle(scTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((kind == .error ? Color.orange : Color.green).opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct AuthPrimaryButton: View {
    let title: String
    let systemImage: String?
    let isLoading: Bool
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }

                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 50)
            .padding(.horizontal, 14)
            .foregroundStyle(.white)
            .background(isLoading ? scSurfaceAlt : scAccent)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
        .disabled(isLoading)
    }
}

struct AuthSecondaryButton: View {
    let title: String
    let systemImage: String?
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                }

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
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
}

struct AuthFooterLinks: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Link("Privacy", destination: SatChartLegalLinks.privacy)
                Link("Terms", destination: SatChartLegalLinks.terms)
                Link("Support", destination: SatChartLegalLinks.support)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(scAccent)

            Text("Need help? Email \(SatChartLegalLinks.supportEmail).")
                .font(.caption)
                .foregroundStyle(scTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AuthFormLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(scTextSecondary)
    }
}

private struct AuthTextFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.body)
            .foregroundStyle(scTextPrimary)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .background(scSurfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension View {
    func authTextField() -> some View {
        modifier(AuthTextFieldModifier())
    }
}
