import Foundation

enum DistrictID: String, CaseIterable, Identifiable {
    case togiak
    case nushagak
    case naknek_kvichak
    case egegik
    case ugashik

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .naknek_kvichak: return "Naknek–Kvichak"
        default:
            return rawValue
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    /// Default/original file for the district
    var defaultPack: OfflinePack {
        OfflinePack(district: self, slug: rawValue)   // e.g. "egegik"
    }

    /// All packs you want to show under this district (add more over time)
    var packs: [OfflinePack] {
        switch self {
        case .egegik:
            return [
                OfflinePack(district: self, slug: "egegik"),
                OfflinePack(district: self, slug: "egegik_v2"),
            ]
        default:
            return [defaultPack]
        }
    }
}
