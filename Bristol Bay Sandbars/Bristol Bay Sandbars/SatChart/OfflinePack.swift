import Foundation

struct OfflinePack: Identifiable, Hashable {
    let district: DistrictID
    let slug: String            // e.g. "egegik", "egegik_v2"

    var id: String { slug }

    static var shorelinePacks: [OfflinePack] {
        guard let fallbackDistrict = DistrictID.allCases.first else { return [] }
        return [
            OfflinePack(district: fallbackDistrict, slug: "egegik_to_ugashik_shoreline"),
            OfflinePack(district: fallbackDistrict, slug: "naknek_to_egegik_shoreline"),
            OfflinePack(district: fallbackDistrict, slug: "naknek_to_nushagak_shoreline")
        ]
    }

    static var basemapPacks: [OfflinePack] {
        guard let fallbackDistrict = DistrictID.allCases.first else { return [] }
        return [
            OfflinePack(district: fallbackDistrict, slug: "bristol_bay"),
            OfflinePack(district: fallbackDistrict, slug: "noaa_bristol_bay")
        ]
    }

    /// Candidate remote basenames without file extensions.
    ///
    /// This keeps the two offline Bristol Bay basemaps distinct:
    /// - `bristol_bay` / `bristol-bay` for Bristol Bay Satellite Offline
    /// - `noaa_*` / `ncds_*` (and legacy generic `noaa` / `ncds`) for NOAA Charts Offline
    var remoteBasenameCandidates: [String] {
        var candidates: [String] = []

        func add(_ value: String) {
            guard !value.isEmpty, !candidates.contains(value) else { return }
            candidates.append(value)
        }

        add(slug)

        if slug.contains("_") {
            add(slug.replacingOccurrences(of: "_", with: "-"))
        }

        if slug.contains("-") {
            add(slug.replacingOccurrences(of: "-", with: "_"))
        }

        switch slug {
        case "bristol_bay", "bristol-bay":
            add("bristol_bay")
            add("bristol-bay")

        case "ncds_bristol_bay", "noaa_bristol_bay", "ncds-bristol-bay", "noaa-bristol-bay":
            add("ncds_bristol_bay")
            add("noaa_bristol_bay")
            add("ncds-bristol-bay")
            add("noaa-bristol-bay")
            add("ncds")
            add("noaa")

        case "ncds", "noaa":
            add("ncds")
            add("noaa")
            add("ncds_bristol_bay")
            add("noaa_bristol_bay")
            add("ncds-bristol-bay")
            add("noaa-bristol-bay")

        default:
            break
        }

        return candidates
    }

    var remoteMBTilesFilenameCandidates: [String] {
        remoteBasenameCandidates.map { "\($0).mbtiles" }
    }

    var previewFilenameCandidates: [String] {
        remoteBasenameCandidates.flatMap { base in
            ["\(base).jpg", "\(base).jpeg", "\(base).png"]
        }
    }

    var displayTitle: String {
        switch slug {
        case "noaa_bristol_bay", "noaa-bristol-bay", "ncds_bristol_bay", "ncds-bristol-bay":
            return "NOAA Charts Offline"
        case "bristol_bay", "bristol-bay":
            return "Bristol Bay Satellite Offline"
        case "egegik_to_ugashik_shoreline":
            return "Egegik to Ugashik Shoreline"
        case "naknek_to_egegik_shoreline":
            return "Naknek to Egegik Shoreline"
        case "naknek_to_nushagak_shoreline":
            return "Naknek to Nushagak Shoreline"
        default:
            if let version = districtMapVersion {
                return districtPackTitle(forVersion: version)
            }
            return slug
        }
    }

    var previewDateLabel: String? {
        switch slug {
        case "togiak",
            "bristol_bay", "bristol-bay",
            "egegik",
            "ugashik",
            "naknek_kvichak",
            "nushagak",
            "egegik_to_ugashik_shoreline",
            "naknek_to_egegik_shoreline",
            "naknek_to_nushagak_shoreline":
            return "9/14/25"

        case "egegik_v2":
            return "8/17/25"

        case "egegik_v3", "ugashik_v3":
            return "5/9/26"

        case "ugashik_v2":
            return "7/8/25"

        case "naknek_kvichak_v2":
            return "10/26/25"

        case "nushagak_v2":
            return "9/28/25"

        default:
            return nil
        }
    }

    /// Version number for district map packs. v1 is the base district slug; v2+ use `_v#`.
    /// Non-district packs such as shorelines and basemaps return nil.
    var districtMapVersion: Int? {
        if slug == district.rawValue { return 1 }

        let prefix = "\(district.rawValue)_v"
        guard slug.hasPrefix(prefix) else { return nil }

        let suffix = String(slug.dropFirst(prefix.count))
        return Int(suffix)
    }

    var isDistrictMapPack: Bool {
        districtMapVersion != nil
    }

    private func districtPackTitle(forVersion version: Int) -> String {
        version <= 1 ? district.displayName : "\(district.displayName) v\(version)"
    }
}

enum PackVariant: String, CaseIterable, Identifiable {
    case v1
    case v2
    case v3
    case v4
    case v5
    case v6

    var id: String { rawValue }

    private var versionNumber: Int {
        Int(rawValue.dropFirst()) ?? 1
    }

    var displayName: String {
        self == .v1 ? "Standard" : "V\(versionNumber)"
    }

    var fileSuffix: String {
        self == .v1 ? "" : "_v\(versionNumber)"
    }
}
