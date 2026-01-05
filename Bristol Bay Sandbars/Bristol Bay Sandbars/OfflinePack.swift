import Foundation

enum PackVariant: String, CaseIterable, Identifiable {
    case v1
    case v2
    // later: case lowTide, midTide, highTide, etc.
    struct OfflinePack: Identifiable, Hashable {
        let district: DistrictID
        let slug: String            // e.g. "egegik", "egegik_v2"

        var id: String { slug }
    }
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .v1: return "Standard"
        case .v2: return "V2"
        }
    }

    /// Remote + local file naming
    var fileSuffix: String {
        switch self {
        case .v1: return ""      // egegik.mbtiles / egegik.jpg
        case .v2: return "_v2"   // egegik_v2.mbtiles / egegik_v2.jpg
        }
    }
}
