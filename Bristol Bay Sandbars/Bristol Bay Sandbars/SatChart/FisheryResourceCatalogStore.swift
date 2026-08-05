import Foundation
import Combine
import FirebaseFirestore

@MainActor
final class FisheryResourceCatalogStore: ObservableObject {
    static let shared = FisheryResourceCatalogStore()

    @Published private(set) var sections: [FisheryResourceSection] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadedSource: LoadedSource = .notLoaded
    @Published private(set) var latestFetchedAt: Date?
    @Published private(set) var loadedAt: Date?
    @Published private(set) var errorMessage: String?

    enum LoadedSource: Equatable {
        case notLoaded
        case firestore
        case bundledFallback

        var title: String {
            switch self {
            case .notLoaded:
                return "Not loaded"
            case .firestore:
                return "Firestore"
            case .bundledFallback:
                return "Bundled fallback"
            }
        }
    }

    private let db: Firestore
    private var hasLoaded = false

    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    var resourceCount: Int {
        sections.reduce(0) { $0 + $1.items.count }
    }

    var dataStatusSummary: String {
        switch loadedSource {
        case .notLoaded:
            return isLoading ? "Loading fishery resources..." : "Not loaded"
        case .firestore:
            let timestamp = latestFetchedAt.map(Self.shortDateFormatter.string(from:)) ?? "no fetch timestamp"
            return "Firestore: \(resourceCount) resources; latest fetch \(timestamp)"
        case .bundledFallback:
            return "Bundled fallback: \(resourceCount) resources; Firestore unavailable"
        }
    }

    func loadIfNeeded(maxAge: TimeInterval = 900) async {
        if hasLoaded,
           let loadedAt,
           Date().timeIntervalSince(loadedAt) < maxAge {
            return
        }
        await reload()
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoaded = true
        }

        var fallbackItems: [FisheryResourceItem] = []
        var fallbackLoadError: Error?
        do {
            fallbackItems = try Self.loadFallbackItems()
        } catch {
            fallbackLoadError = error
        }

        do {
            let firestoreItems = try await fetchFirestoreItems(source: .server)
            try applyLoadedItems(
                firestoreItems: firestoreItems,
                fallbackItems: fallbackItems,
                fallbackLoadError: fallbackLoadError
            )
        } catch {
            if let cachedFirestoreItems = try? await fetchFirestoreItems(source: .cache),
               !cachedFirestoreItems.isEmpty {
                try? applyLoadedItems(
                    firestoreItems: cachedFirestoreItems,
                    fallbackItems: fallbackItems,
                    fallbackLoadError: fallbackLoadError
                )
                errorMessage = "Unable to refresh Firestore catalog. Showing cached catalog links."
            } else if fallbackItems.isEmpty {
                sections = Self.emptySections()
                loadedSource = .bundledFallback
                latestFetchedAt = nil
                loadedAt = Date()
                errorMessage = "Unable to load fishery resources."
            } else {
                apply(items: fallbackItems, source: .bundledFallback)
                errorMessage = "Unable to load Firestore catalog. Using bundled source links."
            }
        }
    }

    func items(for category: FisheryResourceCategory) -> [FisheryResourceItem] {
        sections.first { $0.category == category }?.items ?? []
    }

    static func sortedItems(_ items: [FisheryResourceItem], category: FisheryResourceCategory) -> [FisheryResourceItem] {
        switch category {
        case .historicalFMR:
            return items.sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder > $1.sortOrder }
                return ($0.seasonYear ?? $0.year ?? 0) > ($1.seasonYear ?? $1.year ?? 0)
            }
        case .portMollerTestFishing, .adfgAnnouncements:
            return items.sorted {
                let lhsDate = $0.publishedAt ?? .distantPast
                let rhsDate = $1.publishedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .districtBoundariesMaps, .friInseasonReports:
            return items.sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    private func fetchFirestoreItems(source: FirestoreSource) async throws -> [FisheryResourceItem] {
        var allItems: [FisheryResourceItem] = []

        for category in FisheryResourceCategory.allCases {
            let query = db.collection("fisheryResources")
                .document(category.rawValue)
                .collection("items")
                .whereField("active", isEqualTo: true)

            let snapshot = try await getDocuments(query, source: source)
            allItems.append(contentsOf: snapshot.documents.compactMap { document in
                Self.item(from: document, fallbackCategory: category)
            })
        }

        return allItems
    }

    private func getDocuments(_ query: Query, source: FirestoreSource) async throws -> QuerySnapshot {
        try await withCheckedThrowingContinuation { continuation in
            query.getDocuments(source: source) { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let snapshot {
                    continuation.resume(returning: snapshot)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "FisheryResourceCatalogStore",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Missing Firestore snapshot"]
                    ))
                }
            }
        }
    }

    private func applyLoadedItems(
        firestoreItems: [FisheryResourceItem],
        fallbackItems: [FisheryResourceItem],
        fallbackLoadError: Error?
    ) throws {
        if firestoreItems.isEmpty {
            if fallbackItems.isEmpty {
                throw fallbackLoadError ?? NSError(
                    domain: "FisheryResourceCatalogStore",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "No Firestore or bundled resources are available"]
                )
            } else {
                apply(items: fallbackItems, source: .bundledFallback)
                errorMessage = "No Firestore resources are published yet. Using bundled source links."
            }
        } else {
            let mergedItems = fallbackItems.isEmpty
                ? firestoreItems
                : Self.mergedItems(bundledItems: fallbackItems, firestoreItems: firestoreItems)
            apply(items: mergedItems, source: .firestore)
            if fallbackItems.isEmpty {
                errorMessage = "Bundled source links are unavailable. Showing published catalog links."
            }
        }
    }

    private func apply(items: [FisheryResourceItem], source: LoadedSource) {
        sections = FisheryResourceCategory.allCases.map { category in
            let activeItems = items.filter { $0.active && $0.category == category }
            return FisheryResourceSection(
                category: category,
                items: Self.sortedItems(activeItems, category: category)
            )
        }
        loadedSource = source
        latestFetchedAt = items.compactMap(\.fetchedAt).max()
        loadedAt = Date()
    }

    private static func emptySections() -> [FisheryResourceSection] {
        FisheryResourceCategory.allCases.map {
            FisheryResourceSection(category: $0, items: [])
        }
    }

    private static func mergedItems(
        bundledItems: [FisheryResourceItem],
        firestoreItems: [FisheryResourceItem]
    ) -> [FisheryResourceItem] {
        let uniqueFirestoreItems = deduplicatedItems(firestoreItems)
        let firestoreIDs = Set(uniqueFirestoreItems.map(\.id))
        let firestoreKeys = Set(uniqueFirestoreItems.map(resourceMergeKey))
        let bundledBackfillItems = bundledItems.filter {
            !firestoreIDs.contains($0.id) && !firestoreKeys.contains(resourceMergeKey(for: $0))
        }
        return bundledBackfillItems + uniqueFirestoreItems
    }

    private static func deduplicatedItems(_ items: [FisheryResourceItem]) -> [FisheryResourceItem] {
        var seenKeys: Set<String> = []
        return items.filter { item in
            seenKeys.insert(resourceMergeKey(for: item)).inserted
        }
    }

    private static func resourceMergeKey(for item: FisheryResourceItem) -> String {
        "\(item.category.rawValue)|\(normalizedResourceURLKey(item.urlString))"
    }

    private static func normalizedResourceURLKey(_ urlString: String) -> String {
        var normalized = urlString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }

        return normalized
    }

    private static func loadFallbackItems() throws -> [FisheryResourceItem] {
        guard let url = Bundle.main.url(forResource: "FisheryResourcesSeed", withExtension: "json") else {
            throw NSError(
                domain: "FisheryResourceCatalogStore",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Missing FisheryResourcesSeed.json"]
            )
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeFlexibleDate)
        return try decoder.decode(FisheryResourceSeedCatalog.self, from: data).items
    }

    private static func item(from document: QueryDocumentSnapshot, fallbackCategory: FisheryResourceCategory) -> FisheryResourceItem? {
        let data = document.data()
        guard let title = data["title"] as? String,
              let urlString = data["urlString"] as? String else {
            return nil
        }

        let category = (data["category"] as? String).flatMap(FisheryResourceCategory.init(rawValue:)) ?? fallbackCategory

        return FisheryResourceItem(
            id: document.documentID,
            title: title,
            subtitle: data["subtitle"] as? String,
            urlString: urlString,
            sourceName: data["sourceName"] as? String ?? "Official source",
            sourceURLString: data["sourceURLString"] as? String,
            category: category,
            documentType: data["documentType"] as? String,
            year: intValue(data["year"]),
            seasonYear: intValue(data["seasonYear"]),
            districtKeys: data["districtKeys"] as? [String] ?? ["baywide"],
            publishedAt: dateValue(data["publishedAt"]),
            fetchedAt: dateValue(data["fetchedAt"]),
            sortOrder: intValue(data["sortOrder"]) ?? 0,
            active: data["active"] as? Bool ?? true,
            isOfficialSource: data["isOfficialSource"] as? Bool ?? true,
            notes: data["notes"] as? String,
            releaseType: data["releaseType"] as? String
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let int64 = value as? Int64 { return Int(int64) }
        if let double = value as? Double { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func dateValue(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let timestamp = value as? Timestamp { return timestamp.dateValue() }
        if let string = value as? String { return flexibleDate(from: string) }
        return nil
    }

    private nonisolated static func decodeFlexibleDate(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if let date = flexibleDate(from: value) {
            return date
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date string: \(value)")
    }

    private nonisolated static func flexibleDate(from value: String) -> Date? {
        let fractionalISOFormatter = ISO8601DateFormatter()
        fractionalISOFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalISOFormatter.date(from: value) {
            return date
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: value) {
            return date
        }

        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.calendar = Calendar(identifier: .gregorian)
        dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateOnlyFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
        return dateOnlyFormatter.date(from: value)
    }

    static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct FisheryResourceSeedCatalog: Decodable {
    let items: [FisheryResourceItem]
}
