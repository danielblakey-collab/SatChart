import Foundation

enum SatChartReleaseConfiguration {
    static let appDisplayName = "SatChart"
    static let supportEmail = "support@getsatchart.com"

    static let websiteURL = URL(string: "https://www.getsatchart.com")!
    static let privacyPolicyURL = URL(string: "https://www.getsatchart.com/privacy")!
    static let termsURL = URL(string: "https://www.getsatchart.com/terms")!
    static let supportURL = URL(string: "https://www.getsatchart.com/support")!
    static let dataCollectionURL = URL(string: "https://www.getsatchart.com/data-collection")!
    static let dataDeletionURL = URL(string: "https://www.getsatchart.com/data-deletion")!
    static let safetyURL = URL(string: "https://www.getsatchart.com/safety")!
    static let acknowledgmentsURL = URL(string: "https://www.getsatchart.com/acknowledgments")!
    static let supportMailURL = URL(string: "mailto:\(supportEmail)")!

    static let termsVersion = "2026-05-28"
    static let privacyVersion = "2026-05-28"
    static let safetyNoticeVersion = "2026-05-28"

    static let legalEntityDisplayName = "SatChart"
    static let legalEffectiveDate = termsVersion

    static var websiteURLString: String { websiteURL.absoluteString }
    static var privacyPolicyURLString: String { privacyPolicyURL.absoluteString }
    static var termsOfUseURLString: String { termsURL.absoluteString }
    static var supportWebsiteURLString: String { supportURL.absoluteString }
    static var dataCollectionURLString: String { dataCollectionURL.absoluteString }
    static var dataDeletionURLString: String { dataDeletionURL.absoluteString }
    static var safetyURLString: String { safetyURL.absoluteString }
    static var acknowledgmentsURLString: String { acknowledgmentsURL.absoluteString }

    static func needsReleaseValue(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func validURL(from string: String) -> URL? {
        guard !needsReleaseValue(string), let url = URL(string: string), url.scheme != nil else {
            return nil
        }
        return url
    }
}
