import SwiftUI

enum SatChartExternalLinkKind: CaseIterable, Identifiable {
    case website
    case privacyPolicy
    case termsOfUse
    case support
    case dataCollection
    case dataDeletion
    case safetyNotice
    case dataAcknowledgments
    case emailSupport

    var id: String { title }

    var title: String {
        switch self {
        case .website: return "SatChart Website"
        case .privacyPolicy: return "Privacy Policy"
        case .termsOfUse: return "Terms of Use"
        case .support: return "Support"
        case .dataCollection: return "Data Collection"
        case .dataDeletion: return "Data Deletion"
        case .safetyNotice: return "Safety Notice"
        case .dataAcknowledgments: return "Data Acknowledgments"
        case .emailSupport: return "Email Support"
        }
    }

    var systemImage: String {
        switch self {
        case .website: return "safari"
        case .privacyPolicy: return "hand.raised"
        case .termsOfUse: return "doc.text"
        case .support: return "lifepreserver"
        case .dataCollection: return "list.bullet.rectangle"
        case .dataDeletion: return "trash"
        case .safetyNotice: return "exclamationmark.shield"
        case .dataAcknowledgments: return "checkmark.seal"
        case .emailSupport: return "envelope"
        }
    }

    var url: URL {
        switch self {
        case .website: return SatChartReleaseConfiguration.websiteURL
        case .privacyPolicy: return SatChartReleaseConfiguration.privacyPolicyURL
        case .termsOfUse: return SatChartReleaseConfiguration.termsURL
        case .support: return SatChartReleaseConfiguration.supportURL
        case .dataCollection: return SatChartReleaseConfiguration.dataCollectionURL
        case .dataDeletion: return SatChartReleaseConfiguration.dataDeletionURL
        case .safetyNotice: return SatChartReleaseConfiguration.safetyURL
        case .dataAcknowledgments: return SatChartReleaseConfiguration.acknowledgmentsURL
        case .emailSupport: return SatChartReleaseConfiguration.supportMailURL
        }
    }

    var detail: String {
        switch self {
        case .emailSupport:
            return SatChartReleaseConfiguration.supportEmail
        default:
            return url.absoluteString
        }
    }
}

struct SatChartExternalLinkRow: View {
    let kind: SatChartExternalLinkKind

    var body: some View {
        Link(destination: kind.url) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: kind.systemImage)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(scTextPrimary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(scTextPrimary)
                    Text(kind.detail)
                        .font(.caption)
                        .foregroundStyle(scTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(scTextSecondary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(scSurfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
    }
}

struct SatChartExternalLinksList: View {
    let kinds: [SatChartExternalLinkKind]

    init(_ kinds: [SatChartExternalLinkKind]) {
        self.kinds = kinds
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(kinds) { kind in
                SatChartExternalLinkRow(kind: kind)
            }
        }
    }
}
