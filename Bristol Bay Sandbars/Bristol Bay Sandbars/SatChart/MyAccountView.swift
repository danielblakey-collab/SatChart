import SwiftUI
import UIKit
import Combine
import FirebaseAuth

struct SatChartAccountScaffold<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            scBackground.ignoresSafeArea()
            HostingBackgroundFixer(color: scBackgroundUIColor)
                .frame(width: 0, height: 0)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    content()
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(menuBlue, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

struct SatChartAccountCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(scTextPrimary)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(scSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

struct SatChartAccountRow: View {
    let title: String
    let value: String
    var isCopyable = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(scTextPrimary)

            Spacer(minLength: 12)

            valueText
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(scSurfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var valueText: some View {
        if isCopyable {
            Text(value.isEmpty ? "Not set" : value)
                .font(.subheadline)
                .foregroundStyle(scTextSecondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } else {
            Text(value.isEmpty ? "Not set" : value)
                .font(.subheadline)
                .foregroundStyle(scTextSecondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct SatChartAccountMessage: View {
    let text: String
    let isError: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.orange : Color.green)
            Text(text)
                .font(.footnote)
                .foregroundStyle(scTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isError ? Color.orange : Color.green).opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SatChartAccountButton: View {
    enum Style {
        case primary
        case secondary
        case destructive
    }

    let title: String
    let systemImage: String
    var style: Style = .secondary
    var isLoading = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: systemImage)
                }

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 46)
            .padding(.horizontal, 12)
            .foregroundStyle(.white)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
        .disabled(isLoading || isDisabled)
        .opacity(isDisabled ? 0.55 : 1.0)
    }

    private var backgroundColor: Color {
        if isLoading { return scSurfaceAlt }

        switch style {
        case .primary:
            return scAccent
        case .secondary:
            return scSurfaceAlt
        case .destructive:
            return Color.red.opacity(0.72)
        }
    }
}

struct SatChartProfileTextField: View {
    let title: String
    @Binding var text: String
    var textContentType: UITextContentType?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(scTextSecondary)

            TextField(title, text: $text)
                .font(.body)
                .foregroundStyle(scTextPrimary)
                .textContentType(textContentType)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .frame(minHeight: 46)
                .background(scSurfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

struct MyAccountView: View {
    @StateObject private var model = MyAccountViewModel()
    @EnvironmentObject private var radioGroup: RadioGroupStore

    var body: some View {
        SatChartAccountScaffold(title: "My Account") {
            if model.isLoading {
                loadingCard
            } else {
                if let errorMessage = model.errorMessage {
                    SatChartAccountMessage(text: errorMessage, isError: true)
                }

                if let infoMessage = model.infoMessage {
                    SatChartAccountMessage(text: infoMessage, isError: false)
                }

                accountSection
                profileEditorSection
                actionsSection
                linksSection
            }
        }
        .task {
            await model.loadIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .satChartUserProfileDidChange)) { notification in
            if let profile = notification.object as? UserProfile {
                model.applyExternalProfile(profile)
            } else {
                Task { await model.reloadProfile() }
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
            model.refreshVerificationCooldown(now: now)
        }
    }

    private var loadingCard: some View {
        SatChartAccountCard(title: "Account") {
            HStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                Text("Loading account...")
                    .font(.subheadline)
                    .foregroundStyle(scTextSecondary)
            }
        }
    }

    private var accountSection: some View {
        SatChartAccountCard(title: "Account") {
            SatChartAccountRow(title: "Email", value: model.email)
            SatChartAccountRow(title: "Email status", value: model.emailVerified ? "Verified" : "Not verified")
            SatChartAccountRow(title: "User ID", value: model.uid, isCopyable: true)

            if let createdAt = model.createdAtText {
                SatChartAccountRow(title: "Created", value: createdAt)
            }

            SatChartAccountButton(title: "Copy User ID", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = model.uid
                model.infoMessage = "User ID copied."
            }
        }
    }

    private var profileEditorSection: some View {
        SatChartAccountCard(title: "Profile") {
            SatChartProfileTextField(title: "First name", text: $model.firstName, textContentType: .givenName)
            SatChartProfileTextField(title: "Last name", text: $model.lastName, textContentType: .familyName)
            SatChartProfileTextField(title: "Vessel name", text: $model.vesselName)
            SatChartProfileTextField(title: "Radio display name", text: $model.radioDisplayName)

            SatChartAccountButton(
                title: "Save Profile",
                systemImage: "checkmark.circle",
                style: .primary,
                isLoading: model.isSaving
            ) {
                Task { await model.saveProfile() }
            }
        }
    }

    private var actionsSection: some View {
        SatChartAccountCard(title: "Account Actions") {
            if !model.emailVerified {
                SatChartAccountButton(
                    title: model.verificationCooldownText ?? "Resend Verification Email",
                    systemImage: "envelope.badge",
                    isLoading: model.isSendingVerificationEmail,
                    isDisabled: model.verificationCooldownText != nil
                ) {
                    Task { await model.sendVerificationEmail() }
                }
            }

            SatChartAccountButton(
                title: "Refresh Account Status",
                systemImage: "arrow.clockwise",
                isLoading: model.isRefreshing
            ) {
                Task { await model.reloadProfile() }
            }

            SatChartAccountButton(
                title: "Send Password Reset Email",
                systemImage: "key",
                isLoading: model.isSendingPasswordReset
            ) {
                Task { await model.sendPasswordReset() }
            }

            SatChartAccountButton(
                title: "Sign Out",
                systemImage: "rectangle.portrait.and.arrow.right",
                isLoading: model.isSigningOut
            ) {
                Task { await model.signOut() }
            }

            NavigationLink {
                DeleteAccountView(onStopLiveSharing: {
                    radioGroup.stopLiveSharing()
                })
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "person.crop.circle.badge.minus")
                    Text("Delete Account")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 46)
                .padding(.horizontal, 12)
                .background(Color.red.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(SatChartPressFeedbackButtonStyle())
        }
    }

    private var linksSection: some View {
        SatChartAccountCard(title: "Legal & Support") {
            SatChartExternalLinksList([
                .website,
                .privacyPolicy,
                .termsOfUse,
                .support,
                .dataCollection,
                .dataDeletion,
                .safetyNotice,
                .dataAcknowledgments,
                .emailSupport
            ])
        }
    }
}

@MainActor
final class MyAccountViewModel: ObservableObject {
    @Published var profile: UserProfile?
    @Published var firstName = ""
    @Published var lastName = ""
    @Published var vesselName = ""
    @Published var radioDisplayName = ""
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published var isLoading = true
    @Published var isRefreshing = false
    @Published var isSaving = false
    @Published var isSendingVerificationEmail = false
    @Published var isSendingPasswordReset = false
    @Published var isSigningOut = false
    @Published private var verificationCooldownEndsAt: Date?
    @Published private var cooldownNow = Date()

    private let service: UserProfileService
    private let verificationCooldownSeconds: TimeInterval = 60
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init(service: UserProfileService? = nil) {
        self.service = service ?? UserProfileService()
    }

    var uid: String {
        profile?.uid ?? service.currentUser?.uid ?? ""
    }

    var email: String {
        profile?.email ?? service.currentUser?.email ?? ""
    }

    var emailVerified: Bool {
        profile?.emailVerified ?? service.currentUser?.isEmailVerified ?? false
    }

    var createdAtText: String? {
        guard let createdAt = profile?.createdAt else { return nil }
        return dateFormatter.string(from: createdAt)
    }

    var verificationCooldownText: String? {
        guard let verificationCooldownEndsAt else { return nil }
        let remaining = Int(ceil(verificationCooldownEndsAt.timeIntervalSince(cooldownNow)))
        guard remaining > 0 else { return nil }
        return "Resend available in \(remaining)s"
    }

    func loadIfNeeded() async {
        guard profile == nil else { return }
        await reloadProfile()
    }

    func reloadProfile() async {
        isRefreshing = true
        if profile == nil { isLoading = true }
        errorMessage = nil
        infoMessage = nil

        do {
            let loaded = try await service.loadProfile()
            apply(loaded)
        } catch {
            errorMessage = "Unable to load account. \(UserProfileService.friendlyMessage(for: error))"
        }

        isLoading = false
        isRefreshing = false
    }

    func saveProfile() async {
        guard var profile else { return }
        isSaving = true
        errorMessage = nil
        infoMessage = nil

        profile.firstName = clean(firstName)
        profile.lastName = clean(lastName)
        profile.vesselName = clean(vesselName)
        profile.radioDisplayName = clean(radioDisplayName)

        do {
            let saved = try await service.saveProfile(profile)
            apply(saved)
            infoMessage = "Profile saved."
        } catch {
            errorMessage = "Unable to save profile. \(UserProfileService.friendlyMessage(for: error))"
        }

        isSaving = false
    }

    func applyExternalProfile(_ profile: UserProfile) {
        apply(profile)
    }

    func sendVerificationEmail() async {
        if let verificationCooldownText {
            infoMessage = verificationCooldownText
            return
        }

        isSendingVerificationEmail = true
        errorMessage = nil
        infoMessage = nil

        do {
            try await service.sendVerificationEmail()
            verificationCooldownEndsAt = Date().addingTimeInterval(verificationCooldownSeconds)
            infoMessage = "Verification email sent. Check your Inbox, Junk, Spam, Promotions, or Clutter folder."
        } catch {
            errorMessage = "Unable to send verification email. \(UserProfileService.friendlyMessage(for: error))"
        }

        isSendingVerificationEmail = false
    }

    func sendPasswordReset() async {
        isSendingPasswordReset = true
        errorMessage = nil
        infoMessage = nil

        do {
            try await service.sendPasswordReset()
            infoMessage = "Password reset email sent to \(email)."
        } catch {
            errorMessage = "Unable to send password reset email. \(UserProfileService.friendlyMessage(for: error))"
        }

        isSendingPasswordReset = false
    }

    func signOut() async {
        isSigningOut = true
        errorMessage = nil
        infoMessage = nil

        do {
            try service.signOut()
        } catch {
            errorMessage = "Unable to sign out. \(UserProfileService.friendlyMessage(for: error))"
        }

        isSigningOut = false
    }

    func refreshVerificationCooldown(now: Date) {
        cooldownNow = now
        if let verificationCooldownEndsAt, verificationCooldownEndsAt <= now {
            self.verificationCooldownEndsAt = nil
        }
    }

    private func apply(_ profile: UserProfile) {
        self.profile = profile
        firstName = profile.firstName
        lastName = profile.lastName
        vesselName = profile.vesselName
        radioDisplayName = profile.radioDisplayName
    }

    private func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
