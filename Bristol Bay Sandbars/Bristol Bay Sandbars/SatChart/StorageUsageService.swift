import Foundation

struct StorageUsageItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let bytes: Int64
    let url: URL?
}

struct StorageUsageSection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let bytes: Int64
    let items: [StorageUsageItem]
}

struct StorageUsageSnapshot: Sendable {
    let generatedAt: Date
    let totalBytes: Int64
    let sections: [StorageUsageSection]
}

enum StorageUsageService {
    nonisolated static func snapshot() async -> StorageUsageSnapshot {
        await Task.detached(priority: .utility) {
            buildSnapshot()
        }.value
    }

    nonisolated static func clearKnownOnlineTileCaches() async -> String {
        await Task.detached(priority: .utility) {
            let targets = [
                cachesDirectoryURL()?.appendingPathComponent("BristolBaySatelliteTiles", isDirectory: true),
                cachesDirectoryURL()?.appendingPathComponent("SeaSurfaceTemperatureTiles", isDirectory: true)
            ].compactMap { $0 }

            var removed = 0
            for url in targets where FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.removeItem(at: url)
                    removed += 1
                } catch {
                    return "Cache cleanup failed: \(error.localizedDescription)"
                }
            }

            return removed == 0 ? "No online tile cache folders were found." : "Cleared \(removed) online tile cache folder(s)."
        }.value
    }

    nonisolated static func formattedByteCount(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }

    nonisolated static func fileSize(at url: URL?) -> Int64 {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return allocatedSize(at: url)
    }

    nonisolated static func directorySize(at url: URL?, excluding excludedURLs: [URL] = []) -> Int64 {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return recursiveDirectorySize(at: url, excluding: excludedURLs)
    }

    private nonisolated static func buildSnapshot() -> StorageUsageSnapshot {
        let offlineDatabase = offlineDatabaseSection()
        let offlineMaps = offlineMapDownloadsSection()
        let documents = documentsSection(excluding: offlineMaps.urlForExclusion)
        let appSupport = appSupportSection()
        let userData = userDataSection()
        let caches = cachesAndTemporarySection()

        let measuredSections = [
            offlineDatabase,
            offlineMaps.section,
            documents,
            appSupport,
            caches
        ]

        let totalBytes = measuredSections.reduce(Int64(0)) { $0 + $1.bytes }
        let summary = StorageUsageSection(
            id: "summary",
            title: "Summary",
            subtitle: "Local storage measured on this device.",
            bytes: totalBytes,
            items: [
                StorageUsageItem(id: "summary-total", title: "Total Measured Storage", subtitle: nil, bytes: totalBytes, url: nil),
                StorageUsageItem(id: "summary-database", title: "Offline Database", subtitle: nil, bytes: offlineDatabase.bytes, url: nil),
                StorageUsageItem(id: "summary-maps", title: "Offline Map Downloads", subtitle: nil, bytes: offlineMaps.section.bytes, url: offlineMaps.urlForExclusion),
                StorageUsageItem(id: "summary-documents", title: "Documents", subtitle: "Excludes the MBTiles folder", bytes: documents.bytes, url: nil),
                StorageUsageItem(id: "summary-app-support", title: "App Support Data", subtitle: "Excludes Offline Database", bytes: appSupport.bytes, url: nil),
                StorageUsageItem(id: "summary-caches", title: "Caches / Temporary Files", subtitle: nil, bytes: caches.bytes, url: nil)
            ]
        )

        return StorageUsageSnapshot(
            generatedAt: Date(),
            totalBytes: totalBytes,
            sections: [summary] + measuredSections
                + [userData]
        )
    }

    private nonisolated static func offlineDatabaseSection() -> StorageUsageSection {
        let databaseDirectoryURL = databaseDirectoryURL()
        let sqliteURL = databaseDirectoryURL?.appendingPathComponent("offline.sqlite")
        let gzipURL = databaseDirectoryURL?.appendingPathComponent("offline.sqlite.gz")
        let tempURL = databaseDirectoryURL?.appendingPathComponent("offline.tmp.sqlite")

        let knownDatabaseFiles = [sqliteURL, gzipURL, tempURL].compactMap { $0 }
        let items = [
            StorageUsageItem(
                id: "offline-sqlite",
                title: "Installed Offline SQLite",
                subtitle: relativeDisplayPath(for: sqliteURL),
                bytes: fileSize(at: sqliteURL),
                url: sqliteURL
            ),
            StorageUsageItem(
                id: "offline-sqlite-gzip",
                title: "Downloaded SQLite Archive",
                subtitle: relativeDisplayPath(for: gzipURL),
                bytes: fileSize(at: gzipURL),
                url: gzipURL
            ),
            StorageUsageItem(
                id: "offline-sqlite-temp",
                title: "Temporary Install Database",
                subtitle: relativeDisplayPath(for: tempURL),
                bytes: fileSize(at: tempURL),
                url: tempURL
            ),
            StorageUsageItem(
                id: "offline-database-other",
                title: "Other Database Files",
                subtitle: relativeDisplayPath(for: databaseDirectoryURL),
                bytes: directorySize(at: databaseDirectoryURL, excluding: knownDatabaseFiles),
                url: databaseDirectoryURL
            )
        ]

        return StorageUsageSection(
            id: "offline-database",
            title: "Offline Database",
            subtitle: "Required offline SQLite data used by SatChart.",
            bytes: items.reduce(Int64(0)) { $0 + $1.bytes },
            items: items
        )
    }

    private nonisolated static func offlineMapDownloadsSection() -> (section: StorageUsageSection, urlForExclusion: URL?) {
        let mbtilesURL = mbtilesDirectoryURL()
        let fileURLs = mbtilesFiles(in: mbtilesURL)
        let items: [StorageUsageItem]

        if fileURLs.isEmpty {
            items = [
                StorageUsageItem(
                    id: "offline-map-downloads-empty",
                    title: "Downloaded Map Files",
                    subtitle: relativeDisplayPath(for: mbtilesURL),
                    bytes: 0,
                    url: mbtilesURL
                )
            ]
        } else {
            items = fileURLs.map { url in
                let slug = url.deletingPathExtension().lastPathComponent
                let description = offlineMapDescription(forSlug: slug)
                return StorageUsageItem(
                    id: "offline-map-\(url.path)",
                    title: description.title,
                    subtitle: "\(description.kind) - \(url.lastPathComponent)",
                    bytes: fileSize(at: url),
                    url: url
                )
            }
        }

        return (
            StorageUsageSection(
                id: "offline-map-downloads",
                title: "Offline Map Downloads",
                subtitle: "Downloaded .mbtiles files stored separately from Documents.",
                bytes: items.reduce(Int64(0)) { $0 + $1.bytes },
                items: items
            ),
            mbtilesURL
        )
    }

    private nonisolated static func documentsSection(excluding mbtilesURL: URL?) -> StorageUsageSection {
        let documentsURL = documentDirectoryURL()
        let excluded = [mbtilesURL].compactMap { $0 }
        let contents = topLevelContents(in: documentsURL, excluding: excluded)
        let items: [StorageUsageItem]

        if contents.isEmpty {
            items = [
                StorageUsageItem(
                    id: "documents-empty",
                    title: "Documents Excluding MBTiles",
                    subtitle: relativeDisplayPath(for: documentsURL),
                    bytes: 0,
                    url: documentsURL
                )
            ]
        } else {
            items = contents.map { url in
                StorageUsageItem(
                    id: "documents-\(url.path)",
                    title: friendlyDocumentTitle(for: url),
                    subtitle: relativeDisplayPath(for: url),
                    bytes: sizeForFileOrDirectory(url, excluding: []),
                    url: url
                )
            }
        }

        return StorageUsageSection(
            id: "documents",
            title: "Documents",
            subtitle: "Non-map documents only. The MBTiles folder is excluded.",
            bytes: directorySize(at: documentsURL, excluding: excluded),
            items: items
        )
    }

    private nonisolated static func appSupportSection() -> StorageUsageSection {
        let appSupportURL = applicationSupportDirectoryURL()
        let databaseURL = databaseDirectoryURL()
        let excluded = [databaseURL].compactMap { $0 }
        let contents = topLevelContents(in: appSupportURL, excluding: excluded)
        let items: [StorageUsageItem]

        if contents.isEmpty {
            items = [
                StorageUsageItem(
                    id: "app-support-empty",
                    title: "Application Support Data",
                    subtitle: "Excludes Application Support/Database",
                    bytes: 0,
                    url: appSupportURL
                )
            ]
        } else {
            items = contents.map { url in
                StorageUsageItem(
                    id: "app-support-\(url.path)",
                    title: friendlyAppSupportTitle(for: url),
                    subtitle: relativeDisplayPath(for: url),
                    bytes: sizeForFileOrDirectory(url, excluding: []),
                    url: url
                )
            }
        }

        return StorageUsageSection(
            id: "app-support",
            title: "App Support Data",
            subtitle: "Local support files such as Radio Group waypoint caches, excluding the offline database.",
            bytes: directorySize(at: appSupportURL, excluding: excluded),
            items: items
        )
    }

    private nonisolated static func userDataSection() -> StorageUsageSection {
        let breakdown = smartLogbookBreakdown()
        let fishTicketImages = fishTicketImagesDirectoryURL()
        let tenderReceiptImages = tenderReceiptImagesDirectoryURL()
        let waypointBytes = waypointsStorageBytes()

        let items = [
            StorageUsageItem(
                id: "user-data-fish-ticket-ocr",
                title: "Fish Ticket OCR",
                subtitle: "Smart logbook OCR fields plus SmartLogbookFishTickets images.",
                bytes: breakdown.fishTicketBytes + directorySize(at: fishTicketImages),
                url: fishTicketImages
            ),
            StorageUsageItem(
                id: "user-data-sets",
                title: "Sets",
                subtitle: "Approximate bytes from fishing set records inside smart_logbook.json.",
                bytes: breakdown.setsBytes,
                url: smartLogbookURL()
            ),
            StorageUsageItem(
                id: "user-data-tender-purchases",
                title: "Tender Purchases",
                subtitle: "Tender entries plus SmartLogbookTenderReceipts images.",
                bytes: breakdown.tenderBytes + directorySize(at: tenderReceiptImages),
                url: tenderReceiptImages
            ),
            StorageUsageItem(
                id: "user-data-waypoints",
                title: "Waypoints",
                subtitle: "Local waypoints plus received/hidden Radio Group waypoint caches.",
                bytes: waypointBytes,
                url: WaypointLocalStore.storageURL()
            )
        ]

        return StorageUsageSection(
            id: "user-data-logbook",
            title: "User Data / Logbook",
            subtitle: "Detailed breakdown. These files are also included in Documents or App Support totals above.",
            bytes: items.reduce(Int64(0)) { $0 + $1.bytes },
            items: items
        )
    }

    private nonisolated static func cachesAndTemporarySection() -> StorageUsageSection {
        let cachesURL = cachesDirectoryURL()
        let satelliteTiles = cachesURL?.appendingPathComponent("BristolBaySatelliteTiles", isDirectory: true)
        let oceanTiles = cachesURL?.appendingPathComponent("SeaSurfaceTemperatureTiles", isDirectory: true)
        let temporaryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        let items = [
            StorageUsageItem(
                id: "cache-bristol-bay-satellite",
                title: "Online Satellite Tile Cache",
                subtitle: relativeDisplayPath(for: satelliteTiles),
                bytes: directorySize(at: satelliteTiles),
                url: satelliteTiles
            ),
            StorageUsageItem(
                id: "cache-ocean-tiles",
                title: "SST / Ocean Tile Cache",
                subtitle: relativeDisplayPath(for: oceanTiles),
                bytes: directorySize(at: oceanTiles),
                url: oceanTiles
            ),
            StorageUsageItem(
                id: "temporary-files",
                title: "Temporary Files",
                subtitle: relativeDisplayPath(for: temporaryURL),
                bytes: directorySize(at: temporaryURL),
                url: temporaryURL
            )
        ]

        return StorageUsageSection(
            id: "caches-temporary",
            title: "Caches / Temporary Files",
            subtitle: "Online caches can be recreated when network access is available.",
            bytes: items.reduce(Int64(0)) { $0 + $1.bytes },
            items: items
        )
    }

    private nonisolated static func mbtilesFiles(in directoryURL: URL?) -> [URL] {
        guard let directoryURL,
              FileManager.default.fileExists(atPath: directoryURL.path),
              let enumerator = FileManager.default.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
              ) else {
            return []
        }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "mbtiles" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private nonisolated static func topLevelContents(in directoryURL: URL?, excluding excludedURLs: [URL]) -> [URL] {
        guard let directoryURL,
              FileManager.default.fileExists(atPath: directoryURL.path),
              let contents = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return contents
            .filter { !isExcluded($0, excludedURLs: excludedURLs) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private nonisolated static func sizeForFileOrDirectory(_ url: URL, excluding excludedURLs: [URL]) -> Int64 {
        if isDirectory(url) {
            return recursiveDirectorySize(at: url, excluding: excludedURLs)
        }
        return allocatedSize(at: url)
    }

    private nonisolated static func recursiveDirectorySize(at directoryURL: URL, excluding excludedURLs: [URL]) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: sizeResourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if isExcluded(fileURL, excludedURLs: excludedURLs) {
                if isDirectory(fileURL) {
                    enumerator.skipDescendants()
                }
                continue
            }

            if isDirectory(fileURL) {
                continue
            }

            total += allocatedSize(at: fileURL)
        }
        return total
    }

    private nonisolated static func allocatedSize(at url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: Set(sizeResourceKeys)) else {
            return 0
        }

        if values.isDirectory == true {
            return recursiveDirectorySize(at: url, excluding: [])
        }

        if let totalFileAllocatedSize = values.totalFileAllocatedSize {
            return Int64(totalFileAllocatedSize)
        }
        if let fileAllocatedSize = values.fileAllocatedSize {
            return Int64(fileAllocatedSize)
        }
        if let totalFileSize = values.totalFileSize {
            return Int64(totalFileSize)
        }
        if let fileSize = values.fileSize {
            return Int64(fileSize)
        }
        return 0
    }

    private nonisolated static var sizeResourceKeys: [URLResourceKey] {
        [
            .isDirectoryKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .totalFileSizeKey,
            .fileSizeKey
        ]
    }

    private nonisolated static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private nonisolated static func isExcluded(_ url: URL, excludedURLs: [URL]) -> Bool {
        let path = url.standardizedFileURL.path
        return excludedURLs.contains { excludedURL in
            let excludedPath = excludedURL.standardizedFileURL.path
            return path == excludedPath || path.hasPrefix(excludedPath + "/")
        }
    }

    private nonisolated static func offlineMapDescription(forSlug slug: String) -> (title: String, kind: String) {
        let normalizedSlug = slug.replacingOccurrences(of: "-", with: "_")

        if let districtDescription = districtMapDescription(forNormalizedSlug: normalizedSlug) {
            return districtDescription
        }

        switch normalizedSlug {
        case "egegik_to_ugashik_shoreline":
            return ("Egegik to Ugashik Shoreline", "Shoreline pack")
        case "naknek_to_egegik_shoreline":
            return ("Naknek to Egegik Shoreline", "Shoreline pack")
        case "naknek_to_nushagak_shoreline":
            return ("Naknek to Nushagak Shoreline", "Shoreline pack")
        case "bristol_bay":
            return ("Bristol Bay Satellite Offline", "Basemap pack")
        case "ncds", "noaa", "ncds_bristol_bay", "noaa_bristol_bay":
            return ("NOAA Charts Offline", "Basemap pack")
        default:
            return (slug.replacingOccurrences(of: "_", with: " ").capitalized, "Other map download")
        }
    }

    private nonisolated static func districtMapDescription(forNormalizedSlug slug: String) -> (title: String, kind: String)? {
        for district in districtMapDisplayNames {
            if slug == district.key {
                return (district.displayName, "District map pack")
            }

            let prefix = "\(district.key)_v"
            if slug.hasPrefix(prefix),
               let version = Int(slug.dropFirst(prefix.count)),
               version > 1 {
                return ("\(district.displayName) v\(version)", "District map pack")
            }
        }

        return nil
    }

    private nonisolated static var districtMapDisplayNames: [(key: String, displayName: String)] {
        [
            ("togiak", "Togiak"),
            ("nushagak", "Nushagak"),
            ("naknek_kvichak", "Naknek-Kvichak"),
            ("egegik", "Egegik"),
            ("ugashik", "Ugashik")
        ]
    }

    private nonisolated static func friendlyDocumentTitle(for url: URL) -> String {
        switch url.lastPathComponent {
        case "smart_logbook.json":
            return "Smart Logbook Records"
        case "SmartLogbookFishTickets":
            return "Fish Ticket OCR Images"
        case "SmartLogbookTenderReceipts":
            return "Tender Receipt Images"
        default:
            return url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }
    }

    private nonisolated static func friendlyAppSupportTitle(for url: URL) -> String {
        if url.lastPathComponent == "SatChart" {
            return "Radio Group Local Cache"
        }
        return url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    private nonisolated static func relativeDisplayPath(for url: URL?) -> String? {
        guard let url else { return nil }
        let standardizedPath = url.standardizedFileURL.path

        let roots: [(String, URL?)] = [
            ("Documents", documentDirectoryURL()),
            ("Application Support", applicationSupportDirectoryURL()),
            ("Caches", cachesDirectoryURL()),
            ("Temporary", URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        ]

        for (label, rootURL) in roots {
            guard let rootURL else { continue }
            let rootPath = rootURL.standardizedFileURL.path
            if standardizedPath == rootPath {
                return label
            }
            if standardizedPath.hasPrefix(rootPath + "/") {
                let relative = String(standardizedPath.dropFirst(rootPath.count + 1))
                return "\(label)/\(relative)"
            }
        }

        return url.lastPathComponent
    }

    private nonisolated static func documentDirectoryURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private nonisolated static func applicationSupportDirectoryURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    private nonisolated static func databaseDirectoryURL() -> URL? {
        applicationSupportDirectoryURL()?.appendingPathComponent("Database", isDirectory: true)
    }

    private nonisolated static func cachesDirectoryURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    private nonisolated static func mbtilesDirectoryURL() -> URL? {
        documentDirectoryURL()?.appendingPathComponent("MBTiles", isDirectory: true)
    }

    private nonisolated static func smartLogbookURL() -> URL? {
        documentDirectoryURL()?.appendingPathComponent("smart_logbook.json")
    }

    private nonisolated static func fishTicketImagesDirectoryURL() -> URL? {
        documentDirectoryURL()?.appendingPathComponent("SmartLogbookFishTickets", isDirectory: true)
    }

    private nonisolated static func tenderReceiptImagesDirectoryURL() -> URL? {
        documentDirectoryURL()?.appendingPathComponent("SmartLogbookTenderReceipts", isDirectory: true)
    }

    private nonisolated static func satChartSupportDirectoryURL() -> URL? {
        applicationSupportDirectoryURL()?.appendingPathComponent("SatChart", isDirectory: true)
    }

    private nonisolated static func smartLogbookBreakdown() -> (fishTicketBytes: Int64, setsBytes: Int64, tenderBytes: Int64) {
        guard let url = smartLogbookURL(),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return (0, 0, 0)
        }

        var fishTicketObjects: [[String: Any]] = []
        var setObjects: [Any] = []
        var tenderObjects: [[String: Any]] = []

        for season in root {
            tenderObjects.append([
                "tenderEntries": season["tenderEntries"] ?? [],
                "tenderReceiptImageFilenames": season["tenderReceiptImageFilenames"] ?? []
            ])

            let openings = season["openings"] as? [[String: Any]] ?? []
            for opening in openings {
                if let sets = opening["fishingSets"] as? [Any] {
                    setObjects.append(contentsOf: sets)
                }

                fishTicketObjects.append([
                    "fishTicketImageFilenames": opening["fishTicketImageFilenames"] ?? [],
                    "fishTicketImageFilename": opening["fishTicketImageFilename"] ?? "",
                    "qcSheetImageFilenames": opening["qcSheetImageFilenames"] ?? [],
                    "fishTicketTallyRows": opening["fishTicketTallyRows"] ?? [],
                    "totalCatchLbs": opening["totalCatchLbs"] ?? 0,
                    "statAreaText": opening["statAreaText"] ?? "",
                    "statAreaSectionText": opening["statAreaSectionText"] ?? "",
                    "startDateCaughtText": opening["startDateCaughtText"] ?? "",
                    "dateLandedText": opening["dateLandedText"] ?? "",
                    "timeOfLandingText": opening["timeOfLandingText"] ?? "",
                    "fishTempF": opening["fishTempF"] ?? "",
                    "deliveryTender": opening["deliveryTender"] ?? "",
                    "chillType": opening["chillType"] ?? "",
                    "flagNotes": opening["flagNotes"] ?? "",
                    "didCaptureFishTicket": opening["didCaptureFishTicket"] ?? false
                ])
            }
        }

        return (
            jsonEncodedSize(fishTicketObjects),
            jsonEncodedSize(setObjects),
            jsonEncodedSize(tenderObjects)
        )
    }

    private nonisolated static func waypointsStorageBytes() -> Int64 {
        var total = fileSize(at: WaypointLocalStore.storageURL())
        guard let supportURL = satChartSupportDirectoryURL(),
              let contents = try? FileManager.default.contentsOfDirectory(
                at: supportURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              )
        else {
            return total
        }

        for url in contents {
            let name = url.lastPathComponent
            if name.hasPrefix("received_waypoints_") || name.hasPrefix("hidden_received_waypoints_") {
                total += fileSize(at: url)
            }
        }
        return total
    }

    private nonisolated static func jsonEncodedSize(_ object: Any) -> Int64 {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else {
            return 0
        }
        return Int64(data.count)
    }
}
