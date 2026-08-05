import Foundation
import SwiftUI
import Combine
import GRDB

enum RunTimingMetric: String, CaseIterable, Identifiable {
    case cumulativePercent = "Cumulative % Run"
    case dailyPassage = "Daily Passage"
    case timingVsMedian = "Timing vs Median"

    var id: String { rawValue }
}

struct RunTimingDay: Identifiable {
    let id = UUID()
    let dayIndex: Int
    let mmddLabel: String

    let dailyPassage: Double
    let smoothedDailyPassage: Double
    let cumulativePassage: Double
    let cumulativePassagePct: Double   // 0...100 in the app layer

    let medianPct: Double?
    let p25Pct: Double?
    let p75Pct: Double?
    let p10Pct: Double?
    let p90Pct: Double?
}

struct RunTimingSeries: Identifiable {
    let id = UUID()
    let year: Int
    let district: District
    let days: [RunTimingDay]
}

struct RunTimingSummary: Equatable {
    let year: Int
    let district: District
    let totalPassage: Double
    let peakDailyPassage: Double
    let peakDate: String?
    let p10Date: String?
    let p25Date: String?
    let p50Date: String?
    let p75Date: String?
    let p90Date: String?
    let iqrDays: Double?
}

private struct RunTimingDayRow: FetchableRecord, Decodable {
    let date: String
    let totalPassage: Double
    let smoothedDailyPassage: Double
    let cumulativePassage: Double
    let cumulativePassagePct: Double
}

private struct RunTimingReferenceRow: FetchableRecord, Decodable {
    let mmdd: String
    let medianPct: Double
    let p25Pct: Double
    let p75Pct: Double
    let p10Pct: Double
    let p90Pct: Double
}

private struct RunTimingSummaryRow: FetchableRecord, Decodable {
    let totalPassage: Double
    let peakDailyPassage: Double
    let peakDate: String?
    let p10Date: String?
    let p25Date: String?
    let p50Date: String?
    let p75Date: String?
    let p90Date: String?
    let iqrDays: Double?
}

@MainActor
final class RunTimingVM: ObservableObject {
    @Published var district: District = .ugashik
    @Published var seasonWindow = SeasonWindow(startMMDD: "06-12", endMMDD: "08-03")
    @Published var availableYears: [Int] = Array(2015...2025)

    private var cancellables = Set<AnyCancellable>()

    init() {
        $district
            .removeDuplicates()
            .sink { [weak self] d in
                guard let self else { return }
                switch d {
                case .togiak:
                    self.seasonWindow = SeasonWindow(startMMDD: "06-17", endMMDD: "08-20")
                default:
                    self.seasonWindow = SeasonWindow(startMMDD: "06-12", endMMDD: "08-03")
                }
            }
            .store(in: &cancellables)

        switch district {
        case .togiak:
            seasonWindow = SeasonWindow(startMMDD: "06-17", endMMDD: "08-20")
        default:
            seasonWindow = SeasonWindow(startMMDD: "06-12", endMMDD: "08-03")
        }
    }

    private func comparisonSeasonWindow(for districts: [District]) -> SeasonWindow {
        let active = districts.isEmpty ? [.ugashik] : districts

        if active.count == 1, active.first == .togiak {
            return SeasonWindow(startMMDD: "06-17", endMMDD: "08-20")
        }

        return SeasonWindow(startMMDD: "06-12", endMMDD: "08-03")
    }

    private func yearDate(_ year: Int, mmdd: String) -> String {
        String(format: "%04d-%@", year, mmdd)
    }

    private func label(from yyyyMMdd: String) -> String {
        let mmdd = String(yyyyMMdd.suffix(5))
        let parts = mmdd.split(separator: "-")
        guard parts.count == 2, let m = Int(parts[0]), let d = Int(parts[1]) else { return mmdd }
        return "\(m)/\(d)"
    }

    nonisolated private static func tableExists(_ db: Database, named tableName: String) throws -> Bool {
        let count = try Int.fetchOne(db, sql: """
            SELECT COUNT(*)
            FROM sqlite_master
            WHERE type IN ('table', 'view')
              AND name = ?
        """, arguments: [tableName]) ?? 0
        return count > 0
    }

    private func makeSeasonScaffold(year: Int, window: SeasonWindow? = nil) -> [String] {
        let activeWindow = window ?? seasonWindow
        let start = yearDate(year, mmdd: activeWindow.startMMDD)
        let end   = yearDate(year, mmdd: activeWindow.endMMDD)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!

        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = cal.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"

        guard let s = fmt.date(from: start), let e = fmt.date(from: end) else { return [] }

        var out: [String] = []
        var cur = s
        while cur <= e {
            out.append(fmt.string(from: cur))
            cur = cal.date(byAdding: .day, value: 1, to: cur)!
        }
        return out
    }

    private func loadRunTimingDailyByDate(
        appDB: AppDatabase,
        year: Int,
        districtKey: String,
        start: String,
        end: String
    ) throws -> [String: RunTimingDayRow] {
        try appDB.dbQueue.read { db in
            guard try Self.tableExists(db, named: "district_run_timing_day") else { return [:] }
            return try RunTimingDayRow.fetchAll(db, sql: """
                SELECT
                    drt.date AS date,
                    COALESCE(drt.totalPassage, 0) AS totalPassage,
                    COALESCE(drt.smoothedDailyPassage, 0) AS smoothedDailyPassage,
                    COALESCE(drt.cumulativePassage, 0) AS cumulativePassage,
                    COALESCE(drt.cumulativePassagePct, 0) AS cumulativePassagePct
                FROM district_run_timing_day drt
                JOIN districts d ON d.id = drt.districtId
                WHERE drt.year = ?
                  AND d.key = ?
                  AND drt.date >= ?
                  AND drt.date <= ?
                ORDER BY drt.date
            """, arguments: [year, districtKey, start, end])
            .reduce(into: [:]) { $0[$1.date] = $1 }
        }
    }

    private func loadRunTimingReferenceByMMDD(
        appDB: AppDatabase,
        districtKey: String
    ) throws -> [String: RunTimingReferenceRow] {
        try appDB.dbQueue.read { db in
            guard try Self.tableExists(db, named: "district_run_timing_reference_day") else { return [:] }
            return try RunTimingReferenceRow.fetchAll(db, sql: """
                SELECT
                    r.mmdd AS mmdd,
                    COALESCE(r.medianPct, 0) AS medianPct,
                    COALESCE(r.p25Pct, 0) AS p25Pct,
                    COALESCE(r.p75Pct, 0) AS p75Pct,
                    COALESCE(r.p10Pct, 0) AS p10Pct,
                    COALESCE(r.p90Pct, 0) AS p90Pct
                FROM district_run_timing_reference_day r
                JOIN districts d ON d.id = r.districtId
                WHERE d.key = ?
                ORDER BY r.mmdd
            """, arguments: [districtKey])
            .reduce(into: [:]) { $0[$1.mmdd] = $1 }
        }
    }

    func loadSummary(appDB: AppDatabase?, year: Int, district: District) async throws -> RunTimingSummary? {
        guard let appDB else { return nil }

        let row = try await appDB.dbQueue.read { db in
            guard try Self.tableExists(db, named: "district_run_timing_summary") else { return nil as RunTimingSummaryRow? }
            return try RunTimingSummaryRow.fetchOne(db, sql: """
                SELECT
                    COALESCE(s.totalPassage, 0) AS totalPassage,
                    COALESCE(s.peakDailyPassage, 0) AS peakDailyPassage,
                    s.peakDate AS peakDate,
                    s.p10Date AS p10Date,
                    s.p25Date AS p25Date,
                    s.p50Date AS p50Date,
                    s.p75Date AS p75Date,
                    s.p90Date AS p90Date,
                    s.iqrDays AS iqrDays
                FROM district_run_timing_summary s
                JOIN districts d ON d.id = s.districtId
                WHERE s.year = ?
                  AND d.key = ?
                LIMIT 1
            """, arguments: [year, district.key])
        }

        guard let row else { return nil }
        return RunTimingSummary(
            year: year,
            district: district,
            totalPassage: row.totalPassage,
            peakDailyPassage: row.peakDailyPassage,
            peakDate: row.peakDate,
            p10Date: row.p10Date,
            p25Date: row.p25Date,
            p50Date: row.p50Date,
            p75Date: row.p75Date,
            p90Date: row.p90Date,
            iqrDays: row.iqrDays
        )
    }

    func loadSeries(appDB: AppDatabase?, years: [Int], districts: [District]) async throws -> [RunTimingSeries] {
        guard let appDB else { return [] }

        let activeDistricts = districts.isEmpty ? [.ugashik] : districts
        let activeYears = years.isEmpty ? [2025] : years.sorted()
        let activeWindow = comparisonSeasonWindow(for: activeDistricts)
        seasonWindow = activeWindow

        var built: [RunTimingSeries] = []
        built.reserveCapacity(activeDistricts.count * activeYears.count)

        for district in activeDistricts {
            let dk = district.key
            let refs = try loadRunTimingReferenceByMMDD(appDB: appDB, districtKey: dk)

            for y in activeYears {
                let startDate = yearDate(y, mmdd: activeWindow.startMMDD)
                let endDate   = yearDate(y, mmdd: activeWindow.endMMDD)
                let scaffold = makeSeasonScaffold(year: y, window: activeWindow)
                let rows = try loadRunTimingDailyByDate(appDB: appDB, year: y, districtKey: dk, start: startDate, end: endDate)

                let days: [RunTimingDay] = scaffold.enumerated().map { idx, dateStr in
                    let row = rows[dateStr]
                    let mmdd = String(dateStr.suffix(5))
                    let ref = refs[mmdd]

                    return RunTimingDay(
                        dayIndex: idx,
                        mmddLabel: label(from: dateStr),
                        dailyPassage: row?.totalPassage ?? 0,
                        smoothedDailyPassage: row?.smoothedDailyPassage ?? 0,
                        cumulativePassage: row?.cumulativePassage ?? 0,
                        cumulativePassagePct: (row?.cumulativePassagePct ?? 0) * 100.0,
                        medianPct: ref.map { $0.medianPct * 100.0 },
                        p25Pct: ref.map { $0.p25Pct * 100.0 },
                        p75Pct: ref.map { $0.p75Pct * 100.0 },
                        p10Pct: ref.map { $0.p10Pct * 100.0 },
                        p90Pct: ref.map { $0.p90Pct * 100.0 }
                    )
                }

                built.append(RunTimingSeries(year: y, district: district, days: days))
            }
        }

        return built
    }
}
