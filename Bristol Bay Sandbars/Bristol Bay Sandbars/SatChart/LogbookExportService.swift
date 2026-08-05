import Foundation
import CoreLocation
import UniformTypeIdentifiers

enum LogbookExportService {
    static func preview(snapshot: LogbookExportSnapshot, options: LogbookExportOptions) -> LogbookExportPreview {
        let seasons = selectedSeasonsWithoutThrowing(snapshot: snapshot, options: options)
        let setContexts = setContexts(in: seasons, options: options)
        let fishTicketContexts = fishTicketContexts(in: seasons)
        let tenderEntries = tenderEntryContexts(in: seasons)

        var warnings: [String] = []
        if options.scope == .activeSeason && seasons.isEmpty {
            warnings.append("No active season is available.")
        }
        if options.scope == .customDateRange,
           let start = options.customStartDate,
           let end = options.customEndDate,
           start > end {
            warnings.append("The selected date range is invalid.")
        }
        if options.includeSets && !setContexts.isEmpty && setContexts.filter(\.isGPXEligible).isEmpty {
            warnings.append("No recorded sets with coordinates are available for GPX export.")
        }

        return LogbookExportPreview(
            seasonCount: seasons.count,
            setCount: setContexts.count,
            gpxEligibleSetCount: setContexts.filter(\.isGPXEligible).count,
            fishTicketCount: fishTicketContexts.count,
            fishTicketTallyRowCount: fishTicketContexts.reduce(0) { $0 + $1.opening.fishTicketTallyRows.count },
            tenderPurchaseCount: tenderEntries.count,
            fishTicketPhotoCount: fishTicketContexts.reduce(0) {
                $0 + $1.opening.fishTicketImageFilenames.count + $1.opening.qcSheetImageFilenames.count
            },
            tenderReceiptPhotoCount: seasons.reduce(0) { $0 + $1.tenderReceiptImageFilenames.count },
            estimatedBytes: nil,
            warnings: warnings
        )
    }

    static func prepareSingleExport(
        snapshot: LogbookExportSnapshot,
        request: LogbookSingleExportRequest
    ) throws -> LogbookPreparedExport {
        let seasons = try selectedSeasons(snapshot: snapshot, options: request.options)
        let summary = preview(snapshot: snapshot, options: request.options)
        let dateText = LogbookExportFormatting.fileDate(snapshot.createdAt)

        switch request.kind {
        case .setsGPX:
            let result = SetGPXExporter.export(seasons: seasons, options: request.options)
            guard !result.exportedSetIDs.isEmpty else {
                throw LogbookExportError.noExportableData("No recorded sets with coordinates are available for GPX export.")
            }
            return LogbookPreparedExport(
                data: result.data,
                contentType: .gpx,
                defaultFilename: "satchart_sets_\(dateText).gpx",
                displayTitle: "Garmin GPX",
                summary: summary
            )

        case .setsCSV:
            let rows = SetCSVExporter.rows(seasons: seasons, options: request.options)
            guard rows.count > 1 else {
                throw LogbookExportError.noExportableData("No sets are available for the selected scope.")
            }
            return LogbookPreparedExport(
                data: CSVWriter.data(rows: rows),
                contentType: .commaSeparatedText,
                defaultFilename: "satchart_sets_\(dateText).csv",
                displayTitle: "Sets CSV",
                summary: summary
            )

        case .fishTicketsCSV:
            let rows = FishTicketCSVExporter.rows(seasons: seasons, includeLinkedSets: request.options.includeLinkedSetNumbers)
            guard rows.count > 1 else {
                throw LogbookExportError.noExportableData("No fish tickets are available for the selected scope.")
            }
            return LogbookPreparedExport(
                data: CSVWriter.data(rows: rows),
                contentType: .commaSeparatedText,
                defaultFilename: "satchart_fish_tickets_\(dateText).csv",
                displayTitle: "Fish Tickets CSV",
                summary: summary
            )

        case .fishTicketTallyCSV:
            let rows = FishTicketTallyCSVExporter.rows(seasons: seasons)
            guard rows.count > 1 else {
                throw LogbookExportError.noExportableData("No fish-ticket tally rows are available for the selected scope.")
            }
            return LogbookPreparedExport(
                data: CSVWriter.data(rows: rows),
                contentType: .commaSeparatedText,
                defaultFilename: "satchart_fish_ticket_tally_rows_\(dateText).csv",
                displayTitle: "Fish Ticket Tally Rows CSV",
                summary: summary
            )

        case .tenderPurchasesCSV:
            let prepared = try TenderPurchasesCSVExporter.preparedExport(
                seasons: seasons,
                shape: request.options.tenderCSVShape,
                dateText: dateText,
                summary: summary
            )
            return prepared

        case .rawJSONBackup:
            let data = try LogbookJSONBackupExporter.data(snapshot: snapshot, seasons: seasons, options: request.options)
            return LogbookPreparedExport(
                data: data,
                contentType: .json,
                defaultFilename: "satchart_logbook_backup_\(dateText).json",
                displayTitle: "Raw Logbook Backup",
                summary: summary
            )
        }
    }

    static func prepareArchive(
        snapshot: LogbookExportSnapshot,
        options: LogbookExportOptions
    ) throws -> LogbookPreparedExport {
        let seasons = try selectedSeasons(snapshot: snapshot, options: options)
        let preview = preview(snapshot: snapshot, options: options)
        guard preview.hasAnyExportableData || options.includeRawJSONBackup else {
            throw LogbookExportError.noExportableData("No logbook data is available for the selected scope.")
        }

        let dateText = LogbookExportFormatting.fileDate(snapshot.createdAt)
        var entries: [SimpleZipWriter.Entry] = []
        var files: [String] = []
        var warnings = preview.warnings

        func addFile(_ path: String, _ data: Data) {
            entries.append(SimpleZipWriter.Entry(path: path, data: data, modifiedAt: snapshot.createdAt))
            files.append(path)
        }

        if options.includeSets {
            if options.includeGarminGPX {
                let result = SetGPXExporter.export(seasons: seasons, options: options)
                if result.exportedSetIDs.isEmpty {
                    warnings.append("Sets GPX skipped because no sets had valid coordinates.")
                } else {
                    warnings.append(contentsOf: result.warnings)
                    addFile("sets/sets.gpx", result.data)
                }
            }

            if options.includeSetsCSV {
                let rows = SetCSVExporter.rows(seasons: seasons, options: options)
                if rows.count > 1 {
                    addFile("sets/sets.csv", CSVWriter.data(rows: rows))
                } else {
                    warnings.append("Sets CSV skipped because no sets were available.")
                }
            }
        }

        if options.includeFishTickets {
            if options.includeFishTicketsCSV {
                let rows = FishTicketCSVExporter.rows(seasons: seasons, includeLinkedSets: options.includeLinkedSetNumbers)
                if rows.count > 1 {
                    addFile("fish_tickets/fish_tickets.csv", CSVWriter.data(rows: rows))
                } else {
                    warnings.append("Fish Tickets CSV skipped because no fish tickets were available.")
                }
            }

            if options.includeFishTicketTallyRows {
                let rows = FishTicketTallyCSVExporter.rows(seasons: seasons)
                if rows.count > 1 {
                    addFile("fish_tickets/fish_ticket_tally_rows.csv", CSVWriter.data(rows: rows))
                } else {
                    warnings.append("Fish Ticket tally CSV skipped because no tally rows were available.")
                }
            }

            if options.includeFishTicketPhotos {
                addFishTicketImages(from: seasons, snapshotDate: snapshot.createdAt, entries: &entries, files: &files, warnings: &warnings)
            } else if preview.fishTicketPhotoCount > 0 {
                warnings.append("Fish-ticket and QC-sheet photos excluded by user.")
            }
        }

        if options.includeTenderPurchases {
            let wideRows = TenderPurchasesCSVExporter.wideRows(seasons: seasons)
            let ledgerRows = TenderPurchasesCSVExporter.ledgerRows(seasons: seasons)

            if options.includeTenderPurchasesCSV {
                switch options.tenderCSVShape {
                case .wide:
                    if wideRows.count > 1 {
                        addFile("tender_purchases/tender_purchases_wide.csv", CSVWriter.data(rows: wideRows))
                    } else {
                        warnings.append("Tender Purchases wide CSV skipped because no purchases were available.")
                    }
                case .ledger:
                    if ledgerRows.count > 1 {
                        addFile("tender_purchases/tender_purchases_ledger.csv", CSVWriter.data(rows: ledgerRows))
                    } else {
                        warnings.append("Tender Purchases ledger CSV skipped because no category rows were available.")
                    }
                case .both:
                    if wideRows.count > 1 {
                        addFile("tender_purchases/tender_purchases_wide.csv", CSVWriter.data(rows: wideRows))
                    } else {
                        warnings.append("Tender Purchases wide CSV skipped because no purchases were available.")
                    }
                    if ledgerRows.count > 1 {
                        addFile("tender_purchases/tender_purchases_ledger.csv", CSVWriter.data(rows: ledgerRows))
                    } else {
                        warnings.append("Tender Purchases ledger CSV skipped because no category rows were available.")
                    }
                }
            }

            if options.includeTenderReceiptPhotos {
                addTenderReceiptImages(from: seasons, snapshotDate: snapshot.createdAt, entries: &entries, files: &files, warnings: &warnings)
            } else if preview.tenderReceiptPhotoCount > 0 {
                warnings.append("Tender receipt photos excluded by user.")
            }
        }

        if options.includeRawJSONBackup {
            let data = try LogbookJSONBackupExporter.data(snapshot: snapshot, seasons: seasons, options: options)
            addFile("backup/smart_logbook.json", data)
        }

        guard !entries.isEmpty else {
            throw LogbookExportError.noExportableData("No files were generated for the selected archive.")
        }

        let manifest = ArchiveManifest(
            schemaVersion: 1,
            createdAt: LogbookExportFormatting.iso(snapshot.createdAt),
            app: "SatChart",
            exportScope: options.scope.rawValue,
            included: ArchiveIncluded(
                sets: options.includeSets,
                fishTickets: options.includeFishTickets,
                tenderPurchases: options.includeTenderPurchases,
                rawJSONBackup: options.includeRawJSONBackup,
                fishTicketPhotos: options.includeFishTicketPhotos,
                tenderReceiptPhotos: options.includeTenderReceiptPhotos
            ),
            counts: ArchiveCounts(
                seasons: preview.seasonCount,
                sets: preview.setCount,
                fishTickets: preview.fishTicketCount,
                fishTicketTallyRows: preview.fishTicketTallyRowCount,
                tenderPurchases: preview.tenderPurchaseCount,
                fishTicketPhotos: preview.fishTicketPhotoCount,
                tenderReceiptPhotos: preview.tenderReceiptPhotoCount
            ),
            files: files.sorted(),
            warnings: Array(Set(warnings)).sorted()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        entries.insert(SimpleZipWriter.Entry(path: "manifest.json", data: manifestData, modifiedAt: snapshot.createdAt), at: 0)

        let zip = try SimpleZipWriter.archive(entries: entries)
        return LogbookPreparedExport(
            data: zip,
            contentType: .satChartLogbookArchive,
            defaultFilename: "satchart_logbook_archive_\(dateText).zip",
            displayTitle: "Full Archive ZIP",
            summary: preview
        )
    }

    private static func selectedSeasonsWithoutThrowing(
        snapshot: LogbookExportSnapshot,
        options: LogbookExportOptions
    ) -> [SmartLogbookSeason] {
        (try? selectedSeasons(snapshot: snapshot, options: options)) ?? []
    }

    private static func selectedSeasons(
        snapshot: LogbookExportSnapshot,
        options: LogbookExportOptions
    ) throws -> [SmartLogbookSeason] {
        if options.scope == .customDateRange,
           let start = options.customStartDate,
           let end = options.customEndDate,
           start > end {
            throw LogbookExportError.invalidDateRange
        }

        let seasons = LogbookExportFilter.seasons(
            from: snapshot,
            scope: options.scope,
            startDate: options.customStartDate,
            endDate: options.customEndDate
        )

        if options.scope == .activeSeason && seasons.isEmpty {
            throw LogbookExportError.noActiveSeason
        }
        return seasons
    }

    fileprivate static func setContexts(
        in seasons: [SmartLogbookSeason],
        options: LogbookExportOptions
    ) -> [ExportSetContext] {
        seasons.flatMap { season in
            let deliveryNumbers = deliveryNumberMap(for: season)
            return season.openings.flatMap { opening in
                opening.fishingSets
                    .filter { !options.includeOnlySetsShownOnMap || $0.displayOnNavPage }
                    .map { set in
                        ExportSetContext(
                            season: season,
                            opening: opening,
                            set: set,
                            assignedDeliveryLabel: assignedDeliveryLabel(
                                for: set.assignedDeliveryOpeningID,
                                deliveryNumbers: deliveryNumbers
                            )
                        )
                    }
            }
        }
        .sorted { lhs, rhs in
            if lhs.season.splashDate != rhs.season.splashDate { return lhs.season.splashDate > rhs.season.splashDate }
            if lhs.opening.openingDate != rhs.opening.openingDate { return lhs.opening.openingDate < rhs.opening.openingDate }
            if lhs.set.setNumber != rhs.set.setNumber { return lhs.set.setNumber < rhs.set.setNumber }
            return lhs.set.startedAt < rhs.set.startedAt
        }
    }

    fileprivate static func fishTicketContexts(in seasons: [SmartLogbookSeason]) -> [ExportFishTicketContext] {
        seasons.flatMap { season in
            let deliveryNumbers = deliveryNumberMap(for: season)
            return season.openings.compactMap { opening -> ExportFishTicketContext? in
                guard opening.isDeliveryEntry
                        || opening.hasAppliedDeliveryFields
                        || !opening.fishTicketImageFilenames.isEmpty
                        || !opening.qcSheetImageFilenames.isEmpty
                        || !opening.fishTicketTallyRows.isEmpty else {
                    return nil
                }
                return ExportFishTicketContext(
                    season: season,
                    opening: opening,
                    deliveryNumber: deliveryNumbers[opening.id],
                    linkedSets: linkedSets(forOpeningID: opening.id, in: season)
                )
            }
        }
        .sorted { lhs, rhs in
            if lhs.season.splashDate != rhs.season.splashDate { return lhs.season.splashDate > rhs.season.splashDate }
            if (lhs.deliveryNumber ?? Int.max) != (rhs.deliveryNumber ?? Int.max) {
                return (lhs.deliveryNumber ?? Int.max) < (rhs.deliveryNumber ?? Int.max)
            }
            return lhs.opening.openingDate < rhs.opening.openingDate
        }
    }

    fileprivate static func tenderEntryContexts(in seasons: [SmartLogbookSeason]) -> [ExportTenderEntryContext] {
        seasons.flatMap { season in
            season.tenderEntries.map { ExportTenderEntryContext(season: season, entry: $0) }
        }
        .sorted { lhs, rhs in
            if lhs.season.splashDate != rhs.season.splashDate { return lhs.season.splashDate > rhs.season.splashDate }
            return lhs.entry.date < rhs.entry.date
        }
    }

    private static func deliveryNumberMap(for season: SmartLogbookSeason) -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: season.deliveryOpenings.enumerated().map { ($0.element.id, $0.offset + 1) })
    }

    private static func assignedDeliveryLabel(for openingID: UUID?, deliveryNumbers: [UUID: Int]) -> String {
        guard let openingID else { return "" }
        if let number = deliveryNumbers[openingID] {
            return "Delivery \(number)"
        }
        return openingID.uuidString
    }

    private static func linkedSets(forOpeningID openingID: UUID, in season: SmartLogbookSeason) -> [SmartFishingSetRecord] {
        var seen: Set<UUID> = []
        return season.openings.flatMap { opening in
            opening.fishingSets.filter { set in
                if set.assignedDeliveryOpeningID == openingID {
                    return true
                }
                return opening.id == openingID && opening.isDeliveryEntry && set.assignedDeliveryOpeningID == nil
            }
        }
        .filter { seen.insert($0.id).inserted }
        .sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.setNumber < $1.setNumber
        }
    }

    private static func addFishTicketImages(
        from seasons: [SmartLogbookSeason],
        snapshotDate: Date,
        entries: inout [SimpleZipWriter.Entry],
        files: inout [String],
        warnings: inout [String]
    ) {
        for context in fishTicketContexts(in: seasons) {
            for filename in context.opening.fishTicketImageFilenames {
                let basePath = "fish_tickets/images/\(filename)"
                let namespacedPath = "fish_tickets/images/\(context.opening.id.uuidString)_\(filename)"
                let path = files.contains(basePath) ? namespacedPath : basePath
                guard let data = SmartFishTicketStorage.loadData(named: filename) else {
                    warnings.append("Missing fish-ticket image skipped: \(filename)")
                    continue
                }
                entries.append(SimpleZipWriter.Entry(path: path, data: data, modifiedAt: snapshotDate))
                files.append(path)
            }

            for filename in context.opening.qcSheetImageFilenames {
                let basePath = "qc_sheets/images/\(filename)"
                let namespacedPath = "qc_sheets/images/\(context.opening.id.uuidString)_\(filename)"
                let path = files.contains(basePath) ? namespacedPath : basePath
                guard let data = SmartFishTicketStorage.loadData(named: filename) else {
                    warnings.append("Missing QC-sheet image skipped: \(filename)")
                    continue
                }
                entries.append(SimpleZipWriter.Entry(path: path, data: data, modifiedAt: snapshotDate))
                files.append(path)
            }
        }
    }

    private static func addTenderReceiptImages(
        from seasons: [SmartLogbookSeason],
        snapshotDate: Date,
        entries: inout [SimpleZipWriter.Entry],
        files: inout [String],
        warnings: inout [String]
    ) {
        for season in seasons {
            for filename in season.tenderReceiptImageFilenames {
                let path = "tender_purchases/receipts/\(season.id.uuidString)_\(filename)"
                guard let data = SmartTenderReceiptStorage.loadData(named: filename) else {
                    warnings.append("Missing tender receipt image skipped: \(filename)")
                    continue
                }
                entries.append(SimpleZipWriter.Entry(path: path, data: data, modifiedAt: snapshotDate))
                files.append(path)
            }
        }
    }
}

fileprivate struct ExportSetContext {
    let season: SmartLogbookSeason
    let opening: SmartLogbookOpening
    let set: SmartFishingSetRecord
    let assignedDeliveryLabel: String

    var validLocations: [SmartFishingSetLocation] {
        self.set.sortedLocations.filter { LogbookExportFormatting.isValidCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var isGPXEligible: Bool {
        !validLocations.isEmpty
    }
}

fileprivate struct ExportFishTicketContext {
    let season: SmartLogbookSeason
    let opening: SmartLogbookOpening
    let deliveryNumber: Int?
    let linkedSets: [SmartFishingSetRecord]
}

fileprivate struct ExportTenderEntryContext {
    let season: SmartLogbookSeason
    let entry: SmartLogbookTenderEntry
}

private enum SetGPXExporter {
    struct Result {
        let data: Data
        let exportedSetIDs: Set<UUID>
        let warnings: [String]
    }

    static func export(seasons: [SmartLogbookSeason], options: LogbookExportOptions) -> Result {
        let contexts = LogbookExportService.setContexts(in: seasons, options: options)
        var lines: [String] = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<gpx version="1.1" creator="SatChart" xmlns="http://www.topografix.com/GPX/1/1">"#
        ]
        var exportedSetIDs = Set<UUID>()
        var warnings: [String] = []

        for context in contexts {
            let points = context.validLocations
            guard let first = points.first else {
                warnings.append("Set \(context.set.setNumber) skipped from GPX due to missing coordinates.")
                continue
            }
            exportedSetIDs.insert(context.set.id)

            if options.includeSetStartEndWaypoints {
                appendWaypoint(to: &lines, context: context, point: first, suffix: "START")
                if let last = points.last, last.id != first.id {
                    appendWaypoint(to: &lines, context: context, point: last, suffix: "END")
                }
            }

            guard options.includeSetTracks else { continue }
            guard points.count >= 2 else {
                warnings.append("Set \(context.set.setNumber) has one coordinate; GPX track omitted and waypoint retained.")
                continue
            }

            lines.append("  <trk>")
            lines.append("    <name>\(XMLWriter.escape(trackName(for: context.set)))</name>")
            lines.append("    <desc>\(XMLWriter.escape(description(for: context)))</desc>")
            lines.append("    <trkseg>")
            for point in points {
                lines.append("      <trkpt lat=\"\(LogbookExportFormatting.coordinate(point.latitude))\" lon=\"\(LogbookExportFormatting.coordinate(point.longitude))\">")
                lines.append("        <time>\(LogbookExportFormatting.iso(point.recordedAt))</time>")
                lines.append("      </trkpt>")
            }
            lines.append("    </trkseg>")
            lines.append("  </trk>")
        }

        lines.append("</gpx>")
        return Result(data: Data(lines.joined(separator: "\n").utf8), exportedSetIDs: exportedSetIDs, warnings: warnings)
    }

    private static func appendWaypoint(
        to lines: inout [String],
        context: ExportSetContext,
        point: SmartFishingSetLocation,
        suffix: String
    ) {
        let name = XMLWriter.sanitizedName("S\(context.set.setNumber) \(suffix)", maxLength: 40)
        lines.append("  <wpt lat=\"\(LogbookExportFormatting.coordinate(point.latitude))\" lon=\"\(LogbookExportFormatting.coordinate(point.longitude))\">")
        lines.append("    <name>\(XMLWriter.escape(name))</name>")
        lines.append("    <time>\(LogbookExportFormatting.iso(point.recordedAt))</time>")
        lines.append("    <sym>Waypoint</sym>")
        lines.append("    <desc>\(XMLWriter.escape(description(for: context)))</desc>")
        lines.append("  </wpt>")
    }

    private static func trackName(for set: SmartFishingSetRecord) -> String {
        XMLWriter.sanitizedName("Set \(set.setNumber) - \(LogbookExportFormatting.alaskaMonthDay(set.startedAt))", maxLength: 80)
    }

    private static func description(for context: ExportSetContext) -> String {
        let set = context.set
        let durationMinutes = Int(round(set.duration / 60.0))
        var parts: [String] = [
            "Set number: \(set.setNumber)",
            "Started: \(LogbookExportFormatting.alaskaDateTime(set.startedAt))",
            "Ended: \(LogbookExportFormatting.alaskaDateTime(set.endedAt))",
            "Duration: \(durationMinutes) minutes",
            "Drift miles: \(LogbookExportFormatting.decimal(set.driftMiles, fractionDigits: 2))",
            "Location: \(set.displayLocationLabel)",
            "Location kind: \(set.locationKind?.rawValue ?? "")",
            "District key: \(set.locationDistrictKey ?? context.opening.districtKey ?? context.season.districtKey)",
            "Start tide: \(tideDescription(set.startTide))",
            "End tide: \(tideDescription(set.endTide))",
            "Catch: \(set.catchText)",
            "Picking minutes: \(set.pickingMinutes.map(String.init) ?? "")",
            "Assigned delivery: \(context.assignedDeliveryLabel)",
            "Notes: \(set.notes)"
        ]
        parts.removeAll { $0.hasSuffix(": ") }
        return parts.joined(separator: "\n")
    }

    private static func tideDescription(_ tide: SmartFishingSetTideSnapshot?) -> String {
        guard let tide else { return "" }
        let distance = tide.stationDistanceMiles.map { "\(LogbookExportFormatting.decimal($0, fractionDigits: 1)) mi" } ?? ""
        let height = tide.heightFeet.map { "\(LogbookExportFormatting.decimal($0, fractionDigits: 1)) ft" } ?? ""
        return [tide.stationName, distance, height, tide.state.displayText]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " • ")
    }
}

private enum SetCSVExporter {
    static func rows(seasons: [SmartLogbookSeason], options: LogbookExportOptions) -> [[String]] {
        let header = [
            "season_id",
            "season_splash_date",
            "season_district",
            "opening_id",
            "opening_date",
            "set_id",
            "set_number",
            "started_at",
            "ended_at",
            "duration_minutes",
            "drift_miles",
            "point_count",
            "start_latitude",
            "start_longitude",
            "end_latitude",
            "end_longitude",
            "location_label",
            "location_kind",
            "location_district_key",
            "start_tide_station",
            "start_tide_distance_miles",
            "start_tide_height_ft",
            "start_tide_state",
            "end_tide_station",
            "end_tide_distance_miles",
            "end_tide_height_ft",
            "end_tide_state",
            "catch_text",
            "picking_minutes",
            "notes",
            "assigned_delivery_opening_id",
            "display_on_nav_page"
        ]

        let body = LogbookExportService.setContexts(in: seasons, options: options).map { context -> [String] in
            let locations = context.set.sortedLocations
            let start = locations.first
            let end = locations.last
            return [
                context.season.id.uuidString,
                LogbookExportFormatting.iso(context.season.splashDate),
                context.season.districtKey,
                context.opening.id.uuidString,
                LogbookExportFormatting.iso(context.opening.openingDate),
                context.set.id.uuidString,
                String(context.set.setNumber),
                LogbookExportFormatting.iso(context.set.startedAt),
                LogbookExportFormatting.iso(context.set.endedAt),
                String(Int(round(context.set.duration / 60.0))),
                LogbookExportFormatting.decimal(context.set.driftMiles, fractionDigits: 3),
                String(locations.count),
                LogbookExportFormatting.coordinateOptional(start?.latitude),
                LogbookExportFormatting.coordinateOptional(start?.longitude),
                LogbookExportFormatting.coordinateOptional(end?.latitude),
                LogbookExportFormatting.coordinateOptional(end?.longitude),
                context.set.displayLocationLabel,
                context.set.locationKind?.rawValue ?? "",
                context.set.locationDistrictKey ?? context.opening.districtKey ?? context.season.districtKey,
                context.set.startTide?.stationName ?? "",
                LogbookExportFormatting.decimalOptional(context.set.startTide?.stationDistanceMiles, fractionDigits: 2),
                LogbookExportFormatting.decimalOptional(context.set.startTide?.heightFeet, fractionDigits: 2),
                context.set.startTide?.state.displayText ?? "",
                context.set.endTide?.stationName ?? "",
                LogbookExportFormatting.decimalOptional(context.set.endTide?.stationDistanceMiles, fractionDigits: 2),
                LogbookExportFormatting.decimalOptional(context.set.endTide?.heightFeet, fractionDigits: 2),
                context.set.endTide?.state.displayText ?? "",
                context.set.catchText,
                context.set.pickingMinutes.map(String.init) ?? "",
                context.set.notes,
                context.set.assignedDeliveryOpeningID?.uuidString ?? "",
                context.set.displayOnNavPage ? "true" : "false"
            ]
        }

        return [header] + body
    }
}

private enum FishTicketCSVExporter {
    static func rows(seasons: [SmartLogbookSeason], includeLinkedSets: Bool) -> [[String]] {
        let header = [
            "season_id",
            "season_splash_date",
            "season_district",
            "delivery_opening_id",
            "delivery_number",
            "opening_date",
            "opening_district",
            "total_catch_lbs",
            "stat_area",
            "stat_area_section",
            "start_date_caught",
            "date_landed",
            "time_of_landing",
            "fish_temp_f",
            "delivery_tender",
            "chill_type",
            "drift_opening_start",
            "drift_opening_end",
            "is_drift_opening_confirmed",
            "opening_hours",
            "outcome",
            "did_deliver",
            "notes",
            "flag_notes",
            "fish_ticket_photo_count",
            "fish_ticket_summary_photo_filename",
            "fish_ticket_tally_photo_filenames",
            "qc_sheet_photo_count",
            "qc_sheet_photo_filenames",
            "tally_row_count",
            "linked_set_count",
            "linked_set_numbers",
            "linked_set_ids"
        ]

        let body = LogbookExportService.fishTicketContexts(in: seasons).map { context -> [String] in
            let linkedSets = includeLinkedSets ? context.linkedSets : []
            return [
                context.season.id.uuidString,
                LogbookExportFormatting.iso(context.season.splashDate),
                context.season.districtKey,
                context.opening.id.uuidString,
                context.deliveryNumber.map(String.init) ?? "",
                LogbookExportFormatting.iso(context.opening.openingDate),
                context.opening.openingDistrict?.rawValue ?? "",
                context.opening.totalCatchLbs.map(String.init) ?? "",
                context.opening.statAreaText,
                context.opening.statAreaSectionText,
                context.opening.startDateCaughtText,
                context.opening.dateLandedText,
                context.opening.timeOfLandingText,
                context.opening.fishTempF,
                context.opening.deliveryTender,
                context.opening.chillType,
                LogbookExportFormatting.isoOptional(context.opening.driftOpeningStart),
                LogbookExportFormatting.isoOptional(context.opening.driftOpeningEnd),
                context.opening.isDriftOpeningConfirmed ? "true" : "false",
                LogbookExportFormatting.decimalOptional(context.opening.openingHours, fractionDigits: 2),
                context.opening.outcome?.title ?? "",
                context.opening.didDeliver ? "true" : "false",
                context.opening.notes,
                context.opening.flagNotes ?? "",
                String(context.opening.fishTicketImageFilenames.count),
                context.opening.fishTicketSummaryImageFilename ?? "",
                context.opening.fishTicketTallyImageFilenames.joined(separator: ";"),
                String(context.opening.qcSheetImageFilenames.count),
                context.opening.qcSheetImageFilenames.joined(separator: ";"),
                String(context.opening.fishTicketTallyRows.count),
                String(linkedSets.count),
                linkedSets.map { String($0.setNumber) }.joined(separator: ";"),
                linkedSets.map { $0.id.uuidString }.joined(separator: ";")
            ]
        }

        return [header] + body
    }
}

private enum FishTicketTallyCSVExporter {
    static func rows(seasons: [SmartLogbookSeason]) -> [[String]] {
        let header = [
            "season_id",
            "delivery_opening_id",
            "delivery_number",
            "opening_date",
            "row_number",
            "species",
            "delivery_condition",
            "sold_weight_lbs",
            "brailers"
        ]

        let body = LogbookExportService.fishTicketContexts(in: seasons).flatMap { context in
            context.opening.fishTicketTallyRows.enumerated().map { index, row in
                [
                    context.season.id.uuidString,
                    context.opening.id.uuidString,
                    context.deliveryNumber.map(String.init) ?? "",
                    LogbookExportFormatting.iso(context.opening.openingDate),
                    String(index + 1),
                    row.speciesText,
                    row.deliveryConditionText,
                    row.soldWeightText,
                    row.brailersText
                ]
            }
        }

        return [header] + body
    }
}

private enum TenderPurchasesCSVExporter {
    static func preparedExport(
        seasons: [SmartLogbookSeason],
        shape: TenderPurchasesCSVShape,
        dateText: String,
        summary: LogbookExportPreview
    ) throws -> LogbookPreparedExport {
        switch shape {
        case .wide:
            let rows = wideRows(seasons: seasons)
            guard rows.count > 1 else {
                throw LogbookExportError.noExportableData("No tender purchases are available for the selected scope.")
            }
            return LogbookPreparedExport(
                data: CSVWriter.data(rows: rows),
                contentType: .commaSeparatedText,
                defaultFilename: "satchart_tender_purchases_\(dateText).csv",
                displayTitle: "Tender Purchases CSV",
                summary: summary
            )

        case .ledger:
            let rows = ledgerRows(seasons: seasons)
            guard rows.count > 1 else {
                throw LogbookExportError.noExportableData("No tender purchase ledger rows are available for the selected scope.")
            }
            return LogbookPreparedExport(
                data: CSVWriter.data(rows: rows),
                contentType: .commaSeparatedText,
                defaultFilename: "satchart_tender_purchases_ledger_\(dateText).csv",
                displayTitle: "Tender Purchases Ledger CSV",
                summary: summary
            )

        case .both:
            let wide = wideRows(seasons: seasons)
            let ledger = ledgerRows(seasons: seasons)
            guard wide.count > 1 || ledger.count > 1 else {
                throw LogbookExportError.noExportableData("No tender purchases are available for the selected scope.")
            }

            var entries: [SimpleZipWriter.Entry] = []
            if wide.count > 1 {
                entries.append(SimpleZipWriter.Entry(path: "satchart_tender_purchases_\(dateText).csv", data: CSVWriter.data(rows: wide)))
            }
            if ledger.count > 1 {
                entries.append(SimpleZipWriter.Entry(path: "satchart_tender_purchases_ledger_\(dateText).csv", data: CSVWriter.data(rows: ledger)))
            }

            return LogbookPreparedExport(
                data: try SimpleZipWriter.archive(entries: entries),
                contentType: .satChartLogbookArchive,
                defaultFilename: "satchart_tender_purchases_csvs_\(dateText).zip",
                displayTitle: "Tender Purchases CSVs",
                summary: summary
            )
        }
    }

    static func wideRows(seasons: [SmartLogbookSeason]) -> [[String]] {
        let header = [
            "season_id",
            "season_splash_date",
            "season_district",
            "entry_id",
            "date",
            "tender_name",
            "fuel_gallons",
            "groceries_description",
            "groceries_amount",
            "misc_description",
            "misc_amount",
            "cash_total",
            "has_fuel",
            "has_groceries",
            "has_misc",
            "receipt_count_for_season",
            "season_receipt_filenames"
        ]

        let body = LogbookExportService.tenderEntryContexts(in: seasons).map { context -> [String] in
            let receiptFilenames = context.season.tenderReceiptImageFilenames.joined(separator: ";")
            let cashTotal = (context.entry.groceriesAmount ?? 0) + (context.entry.miscAmount ?? 0)
            return [
                context.season.id.uuidString,
                LogbookExportFormatting.iso(context.season.splashDate),
                context.season.districtKey,
                context.entry.id.uuidString,
                LogbookExportFormatting.iso(context.entry.date),
                context.entry.tenderName,
                LogbookExportFormatting.decimalOptional(context.entry.fuelGallons, fractionDigits: 2),
                context.entry.groceriesDescription,
                LogbookExportFormatting.decimalOptional(context.entry.groceriesAmount, fractionDigits: 2),
                context.entry.miscDescription,
                LogbookExportFormatting.decimalOptional(context.entry.miscAmount, fractionDigits: 2),
                LogbookExportFormatting.decimal(cashTotal, fractionDigits: 2),
                context.entry.fuelGallons == nil ? "false" : "true",
                context.entry.groceriesAmount == nil ? "false" : "true",
                context.entry.miscAmount == nil ? "false" : "true",
                String(context.season.tenderReceiptImageFilenames.count),
                receiptFilenames
            ]
        }

        return [header] + body
    }

    static func ledgerRows(seasons: [SmartLogbookSeason]) -> [[String]] {
        let header = [
            "season_id",
            "season_splash_date",
            "season_district",
            "entry_id",
            "date",
            "tender_name",
            "category",
            "description",
            "quantity",
            "unit",
            "amount",
            "season_receipt_filenames"
        ]

        let body = LogbookExportService.tenderEntryContexts(in: seasons).flatMap { context -> [[String]] in
            let receiptFilenames = context.season.tenderReceiptImageFilenames.joined(separator: ";")
            func base(category: String, description: String, quantity: String, unit: String, amount: String) -> [String] {
                [
                    context.season.id.uuidString,
                    LogbookExportFormatting.iso(context.season.splashDate),
                    context.season.districtKey,
                    context.entry.id.uuidString,
                    LogbookExportFormatting.iso(context.entry.date),
                    context.entry.tenderName,
                    category,
                    description,
                    quantity,
                    unit,
                    amount,
                    receiptFilenames
                ]
            }

            var rows: [[String]] = []
            if let gallons = context.entry.fuelGallons {
                rows.append(base(category: "Fuel", description: "Fuel", quantity: LogbookExportFormatting.decimal(gallons, fractionDigits: 2), unit: "gallons", amount: ""))
            }
            if let amount = context.entry.groceriesAmount {
                let description = context.entry.groceriesDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                rows.append(base(category: "Groceries", description: description.isEmpty ? "Groceries" : description, quantity: "", unit: "", amount: LogbookExportFormatting.decimal(amount, fractionDigits: 2)))
            }
            if let amount = context.entry.miscAmount {
                let description = context.entry.miscDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                rows.append(base(category: "Misc", description: description.isEmpty ? "Miscellaneous" : description, quantity: "", unit: "", amount: LogbookExportFormatting.decimal(amount, fractionDigits: 2)))
            }
            return rows
        }

        return [header] + body
    }
}

private enum LogbookJSONBackupExporter {
    struct WrappedExport: Encodable {
        let schemaVersion: Int
        let createdAt: String
        let scope: String
        let seasons: [SmartLogbookSeason]
    }

    static func data(
        snapshot: LogbookExportSnapshot,
        seasons: [SmartLogbookSeason],
        options: LogbookExportOptions
    ) throws -> Data {
        if options.scope == .allSeasons,
           let sourceLogbookURL = snapshot.sourceLogbookURL,
           let rawData = try? Data(contentsOf: sourceLogbookURL),
           !rawData.isEmpty {
            return rawData
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        if options.scope == .allSeasons {
            return try encoder.encode(seasons)
        }

        return try encoder.encode(
            WrappedExport(
                schemaVersion: 1,
                createdAt: LogbookExportFormatting.iso(snapshot.createdAt),
                scope: options.scope.rawValue,
                seasons: seasons
            )
        )
    }
}

private struct ArchiveManifest: Encodable {
    let schemaVersion: Int
    let createdAt: String
    let app: String
    let exportScope: String
    let included: ArchiveIncluded
    let counts: ArchiveCounts
    let files: [String]
    let warnings: [String]
}

private struct ArchiveIncluded: Encodable {
    let sets: Bool
    let fishTickets: Bool
    let tenderPurchases: Bool
    let rawJSONBackup: Bool
    let fishTicketPhotos: Bool
    let tenderReceiptPhotos: Bool
}

private struct ArchiveCounts: Encodable {
    let seasons: Int
    let sets: Int
    let fishTickets: Int
    let fishTicketTallyRows: Int
    let tenderPurchases: Int
    let fishTicketPhotos: Int
    let tenderReceiptPhotos: Int
}

private enum LogbookExportFormatting {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func isoOptional(_ date: Date?) -> String {
        guard let date else { return "" }
        return iso(date)
    }

    static func fileDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = posixLocale
        formatter.timeZone = TimeZone(identifier: "America/Anchorage")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func alaskaMonthDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = posixLocale
        formatter.timeZone = TimeZone(identifier: "America/Anchorage")
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    static func alaskaDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = posixLocale
        formatter.timeZone = TimeZone(identifier: "America/Anchorage")
        formatter.dateFormat = "yyyy-MM-dd h:mm a zzz"
        return formatter.string(from: date)
    }

    static func coordinate(_ value: Double) -> String {
        String(format: "%.6f", locale: posixLocale, value)
    }

    static func coordinateOptional(_ value: Double?) -> String {
        guard let value, isFinite(value) else { return "" }
        return coordinate(value)
    }

    static func decimal(_ value: Double, fractionDigits: Int) -> String {
        String(format: "%.\(fractionDigits)f", locale: posixLocale, value)
    }

    static func decimalOptional(_ value: Double?, fractionDigits: Int) -> String {
        guard let value, isFinite(value) else { return "" }
        return decimal(value, fractionDigits: fractionDigits)
    }

    static func isValidCoordinate(latitude: Double, longitude: Double) -> Bool {
        isFinite(latitude)
            && isFinite(longitude)
            && (-90...90).contains(latitude)
            && (-180...180).contains(longitude)
    }

    private static func isFinite(_ value: Double) -> Bool {
        value.isFinite && !value.isNaN
    }
}
