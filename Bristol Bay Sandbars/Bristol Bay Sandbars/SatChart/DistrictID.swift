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
        case .naknek_kvichak:
            return "Naknek–Kvichak"
        default:
            return rawValue
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    var defaultPack: OfflinePack {
        OfflinePack(district: self, slug: rawValue)
    }

    /// Highest variant currently supported by the app's naming convention.
    /// v1 is the base slug, and v2+ use suffixes like `_v2`, `_v3`, etc.
    static let maximumSupportedPackVersion = 12

    /// Controls which offline map cards show up for each district.
    ///
    /// Add a version number here after adding the matching files to R2:
    /// - MBTiles: `<district>_v3.mbtiles`, `<district>_v4.mbtiles`, etc.
    /// - Preview: `<district>_v3.jpg`, `<district>_v4.jpg`, etc.
    ///
    /// Examples:
    /// - `[1, 2, 3]` shows base, v2, and v3.
    /// - `[1, 2, 3, 4, 5, 6]` shows all supported variants.
    private var offlinePackVersions: [Int] {
        switch self {
        case .egegik:
            // Published MBTiles and previews, including the new COG-derived variants.
            return [1, 2, 3, 4, 5, 6, 7]

        case .ugashik:
            // ugashik_v3.mbtiles / ugashik_v3.jpg are enabled here.
            return [1, 2, 3]

        case .naknek_kvichak, .nushagak:
            return [1, 2]

        case .togiak:
            return [1]
        }
    }

    var packs: [OfflinePack] {
        var seenVersions = Set<Int>()

        return offlinePackVersions
            .filter { version in
                guard (1...Self.maximumSupportedPackVersion).contains(version) else { return false }
                return seenVersions.insert(version).inserted
            }
            .map { version in
                OfflinePack(district: self, slug: packSlug(forVersion: version))
            }
    }

    /// All naming-convention district map packs the map renderer can recognize locally.
    /// The Offline Maps screen still uses `packs` above so remote download cards stay curated.
    var supportedLocalMapPacks: [OfflinePack] {
        (1...Self.maximumSupportedPackVersion).map { version in
            OfflinePack(district: self, slug: packSlug(forVersion: version))
        }
    }

    func packSlug(forVersion version: Int) -> String {
        version <= 1 ? rawValue : "\(rawValue)_v\(version)"
    }

    func mapVersion(forPackSlug slug: String) -> Int? {
        if slug == rawValue { return 1 }

        let prefix = "\(rawValue)_v"
        guard slug.hasPrefix(prefix) else { return nil }

        let suffix = String(slug.dropFirst(prefix.count))
        guard let version = Int(suffix), (1...Self.maximumSupportedPackVersion).contains(version) else {
            return nil
        }
        return version
    }

    static func district(forDistrictMapSlug slug: String) -> DistrictID? {
        allCases.first { district in
            district.mapVersion(forPackSlug: slug) != nil
        }
    }
}
