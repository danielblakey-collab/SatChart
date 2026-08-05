import Foundation

enum FisheryResourceCategory: String, CaseIterable, Codable, Identifiable {
    case friInseasonReports = "fri_inseason_reports"
    case portMollerTestFishing = "port_moller_test_fishing"
    case historicalFMR = "historical_fmr"
    case districtBoundariesMaps = "district_boundaries_maps"
    case adfgAnnouncements = "adfg_announcements"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .friInseasonReports:
            return "FRI In-Season Reports"
        case .portMollerTestFishing:
            return "Port Moller Test Fishing Results"
        case .historicalFMR:
            return "Historical Fishery Management Reports"
        case .districtBoundariesMaps:
            return "District Boundaries and Maps"
        case .adfgAnnouncements:
            return "Announcements"
        }
    }

    var emptyMessage: String {
        switch self {
        case .adfgAnnouncements:
            return "No direct ADF&G Bristol Bay announcement or emergency-order links are available from the catalog right now. Refresh when online."
        default:
            return "No links are available from the catalog right now. Refresh when online or contact support if this persists."
        }
    }
}

struct FisheryResourceSection: Identifiable, Hashable {
    let category: FisheryResourceCategory
    var items: [FisheryResourceItem]

    var id: String { category.rawValue }
    var title: String { category.title }
}

enum FisheryResourceDistrict {
    static let allFilterID = "all"

    static let filters: [(id: String, title: String)] = [
        (allFilterID, "All"),
        ("naknek_kvichak", "Nak-Kvi"),
        ("egegik", "Egegik"),
        ("ugashik", "Ugashik"),
        ("nushagak", "Nushagak"),
        ("togiak", "Togiak")
    ]

    nonisolated static func displayName(for key: String) -> String {
        switch key {
        case "baywide":
            return "Baywide"
        case "naknek_kvichak":
            return "Nak-Kvi"
        case "egegik":
            return "Egegik"
        case "ugashik":
            return "Ugashik"
        case "nushagak":
            return "Nushagak"
        case "togiak":
            return "Togiak"
        default:
            return key
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }
    }
}
