import SwiftUI
import UIKit
import Combine
import FirebaseAuth

struct DeleteAccountView: View {
    let onStopLiveSharing: () -> Void

    @StateObject private var model = DeleteAccountViewModel()

    var body: some View {
        SatChartAccountScaffold(title: "Delete Account") {
            if let errorMessage = model.errorMessage {
                SatChartAccountMessage(text: errorMessage, isError: true)
            }

            if let infoMessage = model.infoMessage {
                SatChartAccountMessage(text: infoMessage, isError: false)
            }

            SatChartAccountCard(title: "Delete Account") {
                Text("This is a destructive account action. SatChart will request deletion of your cloud account profile and then attempt to delete your Firebase sign-in account.")
                    .font(.footnote)
                    .foregroundStyle(scTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    deletionBullet("Deletes or requests deletion of your Firebase account and account profile data.")
                    deletionBullet("Stops access to cloud account features.")
                    deletionBullet("Shared Radio Group content may not be removed immediately until backend cleanup is complete.")
                    deletionBullet("Local device data may remain until SatChart is deleted or local data is cleared.")
                }

                SatChartExternalLinkRow(kind: .dataDeletion)
                SatChartExternalLinkRow(kind: .emailSupport)
            }

            SatChartAccountCard(title: "Confirm") {
                Text("Type DELETE to enable final deletion.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(scTextPrimary)

                TextField("DELETE", text: $model.confirmationText)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(scTextPrimary)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .frame(minHeight: 46)
                    .background(scSurfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                SatChartDeleteConfirmationButton(
                    confirmationTitle: "Delete your SatChart account?",
                    confirmationMessage: "This permanently deletes or requests deletion of your account and cloud profile data."
                ) {
                    Task {
                        await model.deleteAccount(onStopLiveSharing: onStopLiveSharing)
                    }
                } label: { isFlashingRed in
                    HStack(spacing: 9) {
                        if model.isDeleting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            SatChartDeleteIcon(isFlashingRed: isFlashingRed, defaultColor: .white)
                        }

                        Text("Delete My Account")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 46)
                    .padding(.horizontal, 12)
                    .foregroundStyle(.white)
                    .background(scSurfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(SatChartPressFeedbackButtonStyle())
                .disabled(model.isDeleting || !model.canDelete)
                .opacity(model.canDelete ? 1.0 : 0.55)

                if model.requiresReauthentication {
                    NavigationLink {
                        ReauthenticationView(initialEmail: model.email) {
                            Task {
                                await model.deleteAccount(onStopLiveSharing: onStopLiveSharing)
                            }
                        }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "lock.rotation")
                            Text("Sign In Again")
                                .font(.subheadline.weight(.semibold))
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 46)
                        .padding(.horizontal, 12)
                        .background(scSurfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(SatChartPressFeedbackButtonStyle())
                }
            }

            SatChartAccountButton(title: "Contact Support", systemImage: "lifepreserver") {
                model.openSupportEmail()
            }
        }
        .task {
            await model.loadAccount()
        }
    }

    private func deletionBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.footnote.weight(.bold))
                .foregroundStyle(scTextSecondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(scTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
final class DeleteAccountViewModel: ObservableObject {
    @Published var confirmationText = ""
    @Published var email = ""
    @Published var isDeleting = false
    @Published var requiresReauthentication = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?

    private let service: UserProfileService

    init(service: UserProfileService? = nil) {
        self.service = service ?? UserProfileService()
        email = self.service.currentUser?.email ?? ""
    }

    var canDelete: Bool {
        confirmationText.trimmingCharacters(in: .whitespacesAndNewlines) == "DELETE"
    }

    func loadAccount() async {
        guard email.isEmpty else { return }
        do {
            let profile = try await service.loadProfile()
            email = profile.email
        } catch {
            email = service.currentUser?.email ?? ""
        }
    }

    func deleteAccount(onStopLiveSharing: () -> Void) async {
        guard canDelete else { return }
        guard !isDeleting else { return }

        isDeleting = true
        errorMessage = nil
        infoMessage = nil
        requiresReauthentication = false

        do {
            try await service.requestAccountDeletion()
            try await service.deleteCurrentAuthAccount()
            onStopLiveSharing()
            service.clearLocalProfileCache()
            AccountGateCache.shared.clear()
            try? service.signOut()
            infoMessage = "Your account deletion request was submitted."
        } catch {
            if UserProfileService.isRecentLoginError(error) {
                requiresReauthentication = true
                errorMessage = "For your security, please sign in again before deleting your account."
            } else {
                errorMessage = "Unable to finish account deletion. Your deletion request may have been recorded. Please contact \(SatChartReleaseConfiguration.supportEmail)."
            }
        }

        isDeleting = false
    }

    func openSupportEmail() {
        UIApplication.shared.open(SatChartReleaseConfiguration.supportMailURL)
    }
}

struct ReauthenticationView: View {
    let initialEmail: String
    let onSuccess: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var email: String
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    private let service = UserProfileService()

    init(initialEmail: String, onSuccess: @escaping () -> Void) {
        self.initialEmail = initialEmail
        self.onSuccess = onSuccess
        _email = State(initialValue: initialEmail)
    }

    var body: some View {
        SatChartAccountScaffold(title: "Sign In Again") {
            if let errorMessage {
                SatChartAccountMessage(text: errorMessage, isError: true)
            }

            SatChartAccountCard(title: "Security Check") {
                Text("For your security, sign in again with your SatChart password before deleting your account.")
                    .font(.footnote)
                    .foregroundStyle(scTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Email")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(scTextSecondary)
                    TextField("you@email.com", text: $email)
                        .font(.body)
                        .foregroundStyle(scTextPrimary)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .frame(minHeight: 46)
                        .background(scSurfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Password")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(scTextSecondary)
                    SecureField("Password", text: $password)
                        .font(.body)
                        .foregroundStyle(scTextPrimary)
                        .textContentType(.password)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 46)
                        .background(scSurfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                SatChartAccountButton(
                    title: "Continue",
                    systemImage: "lock.open",
                    style: .primary,
                    isLoading: isWorking,
                    isDisabled: email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty
                ) {
                    Task { await reauthenticate() }
                }

                SatChartAccountButton(title: "Cancel", systemImage: "xmark") {
                    dismiss()
                }
            }
        }
    }

    private func reauthenticate() async {
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanEmail.isEmpty, !password.isEmpty else { return }

        isWorking = true
        errorMessage = nil

        do {
            try await service.reauthenticate(email: cleanEmail, password: password)
            dismiss()
            onSuccess()
        } catch {
            errorMessage = "Unable to sign in again. \(UserProfileService.friendlyMessage(for: error))"
        }

        isWorking = false
    }
}
