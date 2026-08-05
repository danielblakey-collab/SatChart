import SwiftUI

struct ManageMyDataView: View {
    @EnvironmentObject private var radioGroup: RadioGroupStore
    @State private var message: String?

    private let profileService = UserProfileService()

    var body: some View {
        SatChartAccountScaffold(title: "Manage My Data") {
            if let message {
                SatChartAccountMessage(text: message, isError: false)
            }

            SatChartAccountCard(title: "Cloud Data") {
                Text("Account deletion can be started below. Some cloud cleanup is completed by backend support workflow and may not remove shared Radio Group content immediately.")
                    .font(.footnote)
                    .foregroundStyle(scTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                SatChartExternalLinkRow(kind: .dataDeletion)
                SatChartExternalLinkRow(kind: .dataCollection)
                SatChartExternalLinkRow(kind: .privacyPolicy)

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

            SatChartAccountCard(title: "Export My Data") {
                Text("Cloud export is not yet available in this build. Contact \(SatChartReleaseConfiguration.supportEmail) for assistance.")
                    .font(.footnote)
                    .foregroundStyle(scTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                SatChartExternalLinkRow(kind: .emailSupport)
            }

            SatChartAccountCard(title: "Local Data") {
                Text("These actions affect local app state on this device. They do not delete your cloud account, Radio Group memberships, shared pins, logbook records, or offline map packs.")
                    .font(.footnote)
                    .foregroundStyle(scTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                SatChartAccountButton(title: "Clear Local Profile Cache", systemImage: "person.crop.circle.badge.xmark") {
                    profileService.clearLocalProfileCache()
                    message = "Local profile cache cleared. Cloud profile data was not deleted."
                }

                SatChartAccountButton(title: "Clear Local Received Waypoint Cache", systemImage: "mappin.slash") {
                    radioGroup.hideAllReceivedWaypoints()
                    message = "Local received waypoint cache cleared for the active Radio Group. Cloud shared waypoints were not deleted."
                }
            }

            SatChartAccountCard(title: "Help") {
                SatChartExternalLinksList([
                    .support,
                    .dataCollection,
                    .dataDeletion,
                    .privacyPolicy,
                    .emailSupport
                ])
            }
        }
    }
}
