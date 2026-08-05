import SwiftUI

struct UserProfileSetupView: View {
    @EnvironmentObject private var authStore: AuthStateStore
    @State private var displayName = ""
    @State private var vesselName = ""
    @State private var role = "Commercial Fisher"
    @State private var homeDistrict: DistrictID = .naknek_kvichak

    private let roles = [
        "Commercial Fisher",
        "Processor or Tender",
        "Manager or Analyst",
        "Other"
    ]

    var body: some View {
        SatChartAuthShell(
            title: "Profile setup",
            subtitle: "Add the basic account details SatChart needs before opening the app."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if let errorMessage = authStore.errorMessage {
                    AuthMessageBanner(text: errorMessage, kind: .error)
                }

                if let infoMessage = authStore.infoMessage {
                    AuthMessageBanner(text: infoMessage, kind: .info)
                }

                VStack(alignment: .leading, spacing: 8) {
                    AuthFormLabel(title: "Name")
                    TextField("Full name", text: $displayName)
                        .textContentType(.name)
                        .authTextField()
                }

                VStack(alignment: .leading, spacing: 8) {
                    AuthFormLabel(title: "Vessel or Organization")
                    TextField("Optional", text: $vesselName)
                        .textContentType(.organizationName)
                        .authTextField()
                }

                VStack(alignment: .leading, spacing: 8) {
                    AuthFormLabel(title: "Role")
                    Picker("Role", selection: $role) {
                        ForEach(roles, id: \.self) { role in
                            Text(role).tag(role)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(scTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 46)
                    .background(scSurfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 8) {
                    AuthFormLabel(title: "Primary District")
                    Picker("Primary District", selection: $homeDistrict) {
                        ForEach(DistrictID.allCases) { district in
                            Text(district.displayName).tag(district)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(scTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 46)
                    .background(scSurfaceAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                AuthPrimaryButton(
                    "Finish Setup",
                    systemImage: "checkmark.circle",
                    isLoading: authStore.isWorking
                ) {
                    Task {
                        await authStore.completeProfile(
                            displayName: displayName,
                            vesselName: vesselName,
                            role: role,
                            homeDistrict: homeDistrict
                        )
                    }
                }

                AuthSecondaryButton("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                    Task { await authStore.signOut() }
                }
                .disabled(authStore.isWorking)
                .opacity(authStore.isWorking ? 0.55 : 1.0)

                AuthFooterLinks()
            }
        }
        .onAppear {
            guard let profile = authStore.userProfile else { return }

            if displayName.isEmpty {
                displayName = profile.displayName
            }

            if vesselName.isEmpty {
                vesselName = profile.vesselName
            }

            if roles.contains(profile.role) {
                role = profile.role
            }

            if let district = DistrictID(rawValue: profile.homeDistrict) {
                homeDistrict = district
            }
        }
    }
}
