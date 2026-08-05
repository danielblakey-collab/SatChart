import Foundation
import UniformTypeIdentifiers

enum LogbookExportScope: String, CaseIterable, Identifiable, Codable {
    case activeSeason
    case allSeasons
    case customDateRange

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activeSeason: return "Active Season"
        case .allSeasons: return "All Seasons"
        case .customDateRange: return "Date Range"
        }
    }
}

enum LogbookExportDataKind: String, CaseIterable, Identifiable, Codable {
    case sets
    case fishTickets
    case tenderPurchases
    case rawBackup

    var id: String { rawValue }
}

enum LogbookExportFormat: String, CaseIterable, Identifiable, Codable {
    case garminGPX
    case csv
    case json
    case zipArchive

    var id: String { rawValue }
}

enum TenderPurchasesCSVShape: String, CaseIterable, Identifiable, Codable {
    case wide
    case ledger
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wide: return "Wide"
        case .ledger: return "Ledger"
        case .both: return "Both"
        }
    }
}

struct LogbookExportOptions: Equatable, Codable {
    var scope: LogbookExportScope = .activeSeason
    var customStartDate: Date?
    var customEndDate: Date?

    var includeSets: Bool = true
    var includeFishTickets: Bool = true
    var includeTenderPurchases: Bool = true

    var includeGarminGPX: Bool = true
    var includeSetsCSV: Bool = true
    var includeSetStartEndWaypoints: Bool = true
    var includeSetTracks: Bool = true
    var includeOnlySetsShownOnMap: Bool = false

    var includeFishTicketsCSV: Bool = true
    var includeFishTicketTallyRows: Bool = true
    var includeLinkedSetNumbers: Bool = true
    var includeFishTicketPhotos: Bool = false

    var includeTenderPurchasesCSV: Bool = true
    var tenderCSVShape: TenderPurchasesCSVShape = .both
    var includeTenderReceiptPhotos: Bool = false

    var includeRawJSONBackup: Bool = false

    static var archiveDefaults: LogbookExportOptions {
        var options = LogbookExportOptions()
        options.includeRawJSONBackup = true
        return options
    }
}

struct LogbookExportSnapshot {
    let createdAt: Date
    let seasons: [SmartLogbookSeason]
    let activeSeasonID: UUID?
    let sourceLogbookURL: URL?
}

struct LogbookExportPreview {
    let seasonCount: Int
    let setCount: Int
    let gpxEligibleSetCount: Int
    let fishTicketCount: Int
    let fishTicketTallyRowCount: Int
    let tenderPurchaseCount: Int
    let fishTicketPhotoCount: Int
    let tenderReceiptPhotoCount: Int
    let estimatedBytes: Int64?
    let warnings: [String]

    var hasAnyExportableData: Bool {
        setCount > 0
            || fishTicketCount > 0
            || fishTicketTallyRowCount > 0
            || tenderPurchaseCount > 0
            || fishTicketPhotoCount > 0
            || tenderReceiptPhotoCount > 0
    }
}

enum LogbookSingleExportKind {
    case setsGPX
    case setsCSV
    case fishTicketsCSV
    case fishTicketTallyCSV
    case tenderPurchasesCSV
    case rawJSONBackup
}

struct LogbookSingleExportRequest {
    var kind: LogbookSingleExportKind
    var options: LogbookExportOptions
}

struct LogbookPreparedExport {
    let data: Data
    let contentType: UTType
    let defaultFilename: String
    let displayTitle: String
    let summary: LogbookExportPreview
}

enum LogbookExportError: LocalizedError {
    case noActiveSeason
    case noExportableData(String)
    case unsupportedCombination(String)
    case invalidDateRange
    case fileTooLarge(String)
    case zipUnavailable

    var errorDescription: String? {
        switch self {
        case .noActiveSeason:
            return "No active season is available for the selected export."
        case .noExportableData(let message):
            return message
        case .unsupportedCombination(let message):
            return message
        case .invalidDateRange:
            return "Choose a start date that is before or the same as the end date."
        case .fileTooLarge(let message):
            return message
        case .zipUnavailable:
            return "ZIP archive export is unavailable on this device."
        }
    }
}

enum LogbookExportFilter {
    static func seasons(
        from snapshot: LogbookExportSnapshot,
        scope: LogbookExportScope,
        startDate: Date?,
        endDate: Date?
    ) -> [SmartLogbookSeason] {
        switch scope {
        case .activeSeason:
            if let activeSeasonID = snapshot.activeSeasonID,
               let season = snapshot.seasons.first(where: { $0.id == activeSeasonID }) {
                return [season]
            }
            return snapshot.seasons.first.map { [$0] } ?? []

        case .allSeasons:
            return snapshot.seasons

        case .customDateRange:
            guard let startDate, let endDate else { return [] }
            let calendar = Calendar(identifier: .gregorian)
            let lower = calendar.startOfDay(for: min(startDate, endDate))
            let upper = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: max(startDate, endDate)))
                ?? max(startDate, endDate)

            return snapshot.seasons.compactMap { season in
                var filteredSeason = season
                filteredSeason.openings = season.openings.compactMap { opening in
                    var filteredOpening = opening
                    filteredOpening.fishingSets = opening.fishingSets.filter { set in
                        rangesOverlap(startA: set.startedAt, endA: set.endedAt, startB: lower, endB: upper)
                    }

                    let openingInRange = date(opening.openingDate, isBetween: lower, and: upper)
                    return openingInRange || !filteredOpening.fishingSets.isEmpty ? filteredOpening : nil
                }
                filteredSeason.tenderEntries = season.tenderEntries.filter { date($0.date, isBetween: lower, and: upper) }
                return filteredSeason.openings.isEmpty && filteredSeason.tenderEntries.isEmpty ? nil : filteredSeason
            }
        }
    }

    private static func date(_ date: Date, isBetween lower: Date, and upper: Date) -> Bool {
        date >= lower && date <= upper
    }

    private static func rangesOverlap(startA: Date, endA: Date, startB: Date, endB: Date) -> Bool {
        max(startA, endA) >= startB && min(startA, endA) <= endB
    }
}

extension SmartLogbookStore {
    func seasonsForExport(
        scope: LogbookExportScope,
        startDate: Date?,
        endDate: Date?
    ) -> [SmartLogbookSeason] {
        LogbookExportFilter.seasons(
            from: makeExportSnapshot(),
            scope: scope,
            startDate: startDate,
            endDate: endDate
        )
    }
}
