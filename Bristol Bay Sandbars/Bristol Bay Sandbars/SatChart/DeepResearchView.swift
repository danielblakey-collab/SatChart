import SwiftUI
import Charts
import Combine
import UIKit
import GRDB

private let deepResearchSelectorHeight: CGFloat = 33
private let deepResearchShellBlueUIColor = UIColor(red: 0.03, green: 0.23, blue: 0.48, alpha: 1.0)
private let deepResearchShellBlue = Color(uiColor: deepResearchShellBlueUIColor)
private let deepResearchBackgroundTop = Color(red: 0.02, green: 0.15, blue: 0.30)
private let deepResearchBackgroundBottom = Color(red: 0.01, green: 0.08, blue: 0.18)
private let deepResearchNavBarColor = Color(red: 0.06, green: 0.24, blue: 0.55)

// MARK: - Models

enum District: String, CaseIterable, Identifiable, Sendable {
    case naknekKvichak = "Naknek-Kvichak"
    case egegik = "Egegik"
    case ugashik = "Ugashik"
    case nushagak = "Nushagak"
    case togiak = "Togiak"

    nonisolated var id: String { rawValue }

    nonisolated var key: String {
        switch self {
        case .naknekKvichak: return "naknek_kvichak"
        case .egegik: return "egegik"
        case .ugashik: return "ugashik"
        case .nushagak: return "nushagak"
        case .togiak: return "togiak"
        }
    }
}

enum DeepMetric: String, CaseIterable, Identifiable {
    case sockeyePerDriftBoat = "Sockeye/Boat Daily*"
    case sockeyePerDriftBoatToDate = "Sockeye/Boat Cumulative*"
    case sockeyePerBoatHour = "Sockeye/Boat Hourly*"
    case dailyCatch = "Daily Harvest"
    case cumulativeCatch = "Cumulative Catch"
    case escapement = "Daily Escapement"
    case districtRegistration = "Drift Boats"
    case driftPermits = "Drift Permits*"
    case driftEffort = "Drift-hrs. Daily"
    case setNetEffort = "Set-hrs. Daily"

    // New cumulative metrics
    case cumulativeDriftEffort = "Drift-hrs. Cumulative"
    case cumulativeSetNetEffort = "Set-hrs. Cumulative"
    case cumulativeBoatHours = "Boat-hrs. Cumulative*"
    case cumulativeHarvest = "Cumulative Harvest"
    case cumulativeEscapement = "Cumulative Escapement"

    var id: String { rawValue }
}

struct SeasonWindow {
    let startMMDD: String // "06-15"
    let endMMDD: String   // "07-17"
    var label: String { "Standard (\(startMMDD)–\(endMMDD))" }
}

struct DeepDay: Identifiable {
    let id = UUID()
    let dayIndex: Int
    let mmddLabel: String

    // Values for ALL selectable metrics
    let values: [DeepMetric: Double]

    // Which metrics are estimated for this day (e.g., post-registration estimated drift boats)
    let estimatedMetrics: Set<DeepMetric>

    // Optional daily escapement (gaps before tower)
    let escapement: Double?

    func value(for metric: DeepMetric) -> Double? {
        values[metric]
    }

    func isEstimated(_ metric: DeepMetric) -> Bool {
        estimatedMetrics.contains(metric)
    }
}

struct YearSeries: Identifiable {
    let id = UUID()
    let year: Int
    let district: District
    let isCurrentYear: Bool
    let days: [DeepDay]
}

// MARK: - ViewModel

@MainActor
final class DeepResearchVM: ObservableObject {
    
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
        
        // ensure initial value matches default district
        switch district {
        case .togiak:
            seasonWindow = SeasonWindow(startMMDD: "06-17", endMMDD: "08-20")
        default:
            seasonWindow = SeasonWindow(startMMDD: "06-12", endMMDD: "08-03")
        }
    }
    
    // NOTE: districtKey values must match SQLite districts.key:
    // naknek_kvichak, egegik, ugashik, nushagak, togiak
    private func riverKeys(for districtKey: String) -> [String] {
        switch districtKey {
        case "naknek_kvichak": return ["kvichak", "naknek", "alagnak"]
        case "egegik": return ["egegik"]
        case "ugashik": return ["ugashik"]
        case "nushagak": return ["wood", "igushik", "nushagak"]
        case "togiak": return ["togiak"]
        default: return []
        }
    }
    
    private func comparisonSeasonWindow(for districts: [District], metric: DeepMetric? = nil) -> SeasonWindow {
        if metric == .driftPermits || metric == .cumulativeDriftEffort || metric == .cumulativeSetNetEffort {
            return SeasonWindow(startMMDD: "06-12", endMMDD: "07-16")
        }

        let active = districts.isEmpty ? [.ugashik] : districts

        // Togiak keeps its longer season window only when it is the sole selected district.
        if active.count == 1, active.first == .togiak {
            return SeasonWindow(startMMDD: "06-17", endMMDD: "08-20")
        }

        // When Togiak is compared alongside any other district, use the common 6/12-8/3 window.
        return SeasonWindow(startMMDD: "06-12", endMMDD: "08-03")
    }
    private func yearDate(_ year: Int, mmdd: String) -> String {
        String(format: "%04d-%@", year, mmdd)
    }
    
    // M/D label (e.g., 6/12)
    private func label(from yyyyMMdd: String) -> String {
        let mmdd = String(yyyyMMdd.suffix(5))
        let parts = mmdd.split(separator: "-")
        guard parts.count == 2, let m = Int(parts[0]), let d = Int(parts[1]) else { return mmdd }
        return "\(m)/\(d)"
    }
    
    private func loadOpsByDate(appDB: AppDatabase, year: Int, districtKey: String, start: String, end: String) throws -> [String: OpsRow] {
        try appDB.dbQueue.read { db in
            try OpsRow.fetchAll(db, sql: """
                SELECT o.date,
                       o.driftOpenHours, o.setOpenHours,
                       o.driftDeliveries, o.setDeliveries,
                       o.sockeye AS sockeye,
                       o.total AS total
                FROM ops_day o
                JOIN districts d ON d.id = o.districtId
                WHERE o.year = ?
                  AND d.key = ?
                  AND o.date >= ?
                  AND o.date <= ?
                ORDER BY o.date
            """, arguments: [year, districtKey, start, end])
            .reduce(into: [:]) { $0[$1.date] = $1 }
        }
    }
    
    private struct OpsRow: FetchableRecord, Decodable {
        let date: String
        let driftOpenHours: Double?
        let setOpenHours: Double?
        let driftDeliveries: Int?
        let setDeliveries: Int?
        let sockeye: Int?
        let total: Int?
    }
    
    private func loadEscapementDailyByDate(appDB: AppDatabase, year: Int, riverKeys: [String], start: String, end: String) throws -> [String: Double] {
        guard !riverKeys.isEmpty else { return [:] }
        
        let placeholders = riverKeys.map { _ in "?" }.joined(separator: ",")
        
        return try appDB.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT rd.date AS date,
                       SUM(COALESCE(rd.dailyEscapement, 0)) AS daily
                FROM river_day rd
                JOIN rivers r ON r.id = rd.riverId
                WHERE rd.year = ?
                  AND r.key IN (\(placeholders))
                  AND rd.date >= ?
                  AND rd.date <= ?
                  AND COALESCE(rd.isOperational, 0) = 1
                GROUP BY rd.date
                ORDER BY rd.date
            """, arguments: {
                var arguments: StatementArguments = [year]
                arguments += StatementArguments(riverKeys)
                arguments += [start, end]
                return arguments
            }())
            
            var out: [String: Double] = [:]
            for row in rows {
                let date: String = row["date"]
                let daily: Double = row["daily"] ?? 0
                out[date] = daily
            }
            return out
        }
    }
    
    private func loadRegByDate(appDB: AppDatabase, year: Int, districtKey: String, start: String, end: String) throws -> [String: RegRow] {
        try appDB.dbQueue.read { db in
            try RegRow.fetchAll(db, sql: """
                SELECT r.date,
                       r.driftPermits,
                       r.dualPermits,
                       r.driftBoats AS driftBoats
                FROM registration_day r
                JOIN districts d ON d.id = r.districtId
                WHERE r.year = ?
                  AND d.key = ?
                  AND r.date >= ?
                  AND r.date <= ?
                ORDER BY r.date
            """, arguments: [year, districtKey, start, end])
            .reduce(into: [:]) { $0[$1.date] = $1 }
        }
    }
    
    private struct RegRow: FetchableRecord, Decodable {
        let date: String
        let driftPermits: Int?
        let dualPermits: Int?
        let driftBoats: Int?
    }
    
    private func median(_ values: [Double]) -> Double? {
        let clean = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !clean.isEmpty else { return nil }
        let mid = clean.count / 2
        if clean.count % 2 == 1 { return clean[mid] }
        return 0.5 * (clean[mid - 1] + clean[mid])
    }

    private func fallbackBoatsEstimate(
        ops: OpsRow?,
        lastBoats: Double,
        observedDeliveriesPerBoat: Double?
    ) -> Double? {
        guard let ops else { return nil }

        let hrs = ops.driftOpenHours ?? 0
        let del = ops.driftDeliveries ?? 0

        // Only estimate fallback boats when there was real drift activity.
        // Prevent fabricated drift sockeye/boat on days with zero hours or zero deliveries.
        guard hrs > 0, del > 0 else { return nil }

        if let dpb = observedDeliveriesPerBoat, dpb > 0 {
            let boats = Double(Int(round(Double(del) / dpb)))
            if boats > 0 { return boats }
        }

        // Do not carry forward or fabricate boats here.
        return nil
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
    
    // MARK: - Offline helpers (SQLite / GRDB)
    
    private func driftShareFraction(appDB: AppDatabase, year: Int, districtKey: String) throws -> Double? {
        try appDB.dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT a.driftPct AS driftPct, a.setPct AS setPct
                FROM allocation_year a
                JOIN districts d ON d.id = a.districtId
                WHERE a.year = ? AND d.key = ?
                LIMIT 1
            """, arguments: [year, districtKey])

            guard let r = row else { return nil }

            func num(_ key: String) -> Double? {
                if let v: Double = r[key] { return v }
                if let v: Int = r[key] { return Double(v) }
                return nil
            }

            guard let driftRaw = num("driftPct") else { return nil }
            let drift = driftRaw > 1 ? (driftRaw / 100.0) : driftRaw

            guard let setRaw = num("setPct") else { return drift }
            let set = setRaw > 1 ? (setRaw / 100.0) : setRaw

            let denom = drift + set
            guard denom > 0 else { return drift }
            return drift / denom
        }
    }
    
    // MARK: - Main loader (offline)

    /// NOTE: Confidential Togiak 2020 catch has already been distributed in ETL and written into ops_day.sockeye.
    /// The app should NOT apply additional runtime adjustments.
    func loadSeries(appDB: AppDatabase?, years: [Int], districts: [District], metric: DeepMetric? = nil) async throws -> [YearSeries] {
        guard let appDB else { return [] }

        let activeDistricts = districts.isEmpty ? [.ugashik] : districts
        let activeYears = years.isEmpty ? [2025] : years.sorted()
        let activeWindow = comparisonSeasonWindow(for: activeDistricts, metric: metric)
        seasonWindow = activeWindow

        var built: [YearSeries] = []
        built.reserveCapacity(activeDistricts.count * activeYears.count)

        for district in activeDistricts {
            let dk = district.key

            for y in activeYears {
                let startDate = yearDate(y, mmdd: activeWindow.startMMDD)
                let endDate   = yearDate(y, mmdd: activeWindow.endMMDD)

                let driftShare = try driftShareFraction(appDB: appDB, year: y, districtKey: dk)

                let opsByDate = try loadOpsByDate(appDB: appDB, year: y, districtKey: dk, start: startDate, end: endDate)
                let regByDate = try loadRegByDate(appDB: appDB, year: y, districtKey: dk, start: startDate, end: endDate)
                let escByDate = try loadEscapementDailyByDate(appDB: appDB, year: y, riverKeys: riverKeys(for: dk), start: startDate, end: endDate)

                let scaffold = makeSeasonScaffold(year: y, window: activeWindow)

                let observedDeliveriesPerBoat: Double? = {
                    var vals: [Double] = []
                    let observedDates = scaffold.filter { $0 <= String(format: "%04d-07-16", y) }
                    vals.reserveCapacity(observedDates.count)

                    for dateStr in observedDates {
                        guard let ops = opsByDate[dateStr], let reg = regByDate[dateStr] else { continue }
                        let boats = Double(reg.driftBoats ?? 0)
                        let del = Double(ops.driftDeliveries ?? 0)
                        guard boats > 0, del > 0 else { continue }
                        vals.append(del / boats)
                    }

                    return median(vals)
                }()

                let regWindowEnd = String(format: "%04d-07-16", y)

                let estimatorConfig = RegistrationEstimatorConfig.default()
                if dk == "togiak" {
                    // Option A: if your config has a districtOverrides dictionary:
                    // estimatorConfig.districtOverrides["togiak"] = RegistrationEstimatorDistrictOverride(
                    //     deliveriesEmaAlpha: 0.06,
                    //     smoothingAlpha: 0.08,
                    //     maxDailyDecreaseFraction: 0.12,
                    //     maxDailyIncreaseFraction: 0.12
                    // )

                    // Option B: if your config is just flat fields (no overrides dict),
                    // set the fields directly here instead.
                }

                let resolvedCfg = estimatorConfig.resolved(forDistrictKey: dk)
                let observedStart = yearDate(y, mmdd: resolvedCfg.observedWindow.startMMDD)
                let observedEnd   = yearDate(y, mmdd: resolvedCfg.observedWindow.endMMDD)

                let estimatorDays: [RegistrationEstimatorDay] = scaffold.map { dateStr in
                    let ops = opsByDate[dateStr]
                    let reg = regByDate[dateStr]

                    let opsSnap = OpsSnapshot(
                        driftOpenHours: ops?.driftOpenHours,
                        driftDeliveries: ops?.driftDeliveries,
                        sockeyeDaily: ops?.sockeye
                    )

                    let isInObservedWindow = (dateStr >= observedStart && dateStr <= observedEnd)

                    let regSnap: RegSnapshot? = isInObservedWindow ? RegSnapshot(
                        driftPermits: reg?.driftPermits,
                        dualPermits: reg?.dualPermits,
                        driftBoats: reg?.driftBoats
                    ) : nil

                    return RegistrationEstimatorDay(date: dateStr, ops: opsSnap, regObserved: regSnap)
                }

                let regEstimatesByDate: [String: RegistrationEstimate] = {
                    if dk == "togiak" && y == 2020 {
                        return [:]
                    }
                    return RegistrationEstimator.estimatePostWindowRegistration(
                        districtKey: dk,
                        year: y,
                        days: estimatorDays,
                        config: estimatorConfig
                    )
                }()

                var cumulativeHarvest: Double = 0
                var cumulativeBoatHours: Double = 0
                var cumulativeEscapement: Double = 0
                var cumulativeDriftHours: Double = 0
                var cumulativeSetHours: Double = 0
                var lastRegistration: Double = 0
                var cumCatchPerBoat: Double = 0

                let days: [DeepDay] = scaffold.enumerated().map { idx, dateStr in
                    let ops = opsByDate[dateStr]
                    let reg = regByDate[dateStr]

                    let driftHours = ops?.driftOpenHours ?? 0
                    let setHours   = ops?.setOpenHours ?? 0
                    let driftDeliveries = Double(ops?.driftDeliveries ?? 0)
                    let driftPermitsPlusDual = Double((reg?.driftPermits ?? 0) + (reg?.dualPermits ?? 0))

                    let rawDailySockeye = Double(ops?.sockeye ?? 0)
                    let hasRealDriftActivity = (driftHours > 0) && (driftDeliveries > 0)

                    // Do not show drift catch / efficiency before real drift ops exist.
                    // If there were no drift hours or no drift deliveries, treat the day's drift catch as 0.
                    let dailySockeye = hasRealDriftActivity ? rawDailySockeye : 0.0

                    let driftSockeyeAdj: Double = {
                        guard let driftShare else { return dailySockeye }
                        return dailySockeye * driftShare
                    }()

                    let boatsObserved: Double? = {
                        if let b = reg?.driftBoats { return Double(b) }
                        return nil
                    }()

                    enum RegSource { case observed, estimated, fallback, missingZero }
                    var regSource: RegSource = .observed

                    var estimatedSet = Set<DeepMetric>()
                    let regBoats: Double

                    if let obs = boatsObserved {
    #if DEBUG
                        if dk == "togiak" && y == 2020 && (dateStr >= "2020-07-18" && dateStr <= "2020-08-20") {
                            print("DeepResearch reg observed", dateStr, "boats=", obs)
                        }
    #endif
                        regBoats = max(0, obs)
                        regSource = .observed

                    } else if dateStr > regWindowEnd, hasRealDriftActivity, let est = regEstimatesByDate[dateStr] {
    #if DEBUG
                        if dk == "togiak" && y == 2020 && (dateStr >= "2020-07-18" && dateStr <= "2020-08-20") {
                            print("DeepResearch reg ESTIMATED", dateStr, "boats=", est.driftBoats)
                        }
    #endif
                        regBoats = Double(est.driftBoats)
                        regSource = .estimated

                    } else if let fallback = fallbackBoatsEstimate(
                        ops: ops,
                        lastBoats: lastRegistration,
                        observedDeliveriesPerBoat: observedDeliveriesPerBoat
                    ) {
                        regBoats = max(0, fallback)
                        regSource = .fallback

                    } else {
                        // Missing drift-boat count means zero for chart output. Do not carry
                        // the district's prior/maximum registration into no-count days.
                        regBoats = 0
                        regSource = .missingZero
    #if DEBUG
                        if dk == "togiak" && y == 2020 && (dateStr >= "2020-07-18" && dateStr <= "2020-08-20") {
                            print("DeepResearch reg NO_COUNT_ZERO", dateStr, "boats=", regBoats)
                        }
    #endif
                    }

                    if reg == nil && regSource != .observed {
                        if !(dk == "togiak" && y == 2020 && dateStr > regWindowEnd) {
                            estimatedSet.insert(.districtRegistration)
                        }
                    }

                    lastRegistration = regBoats
                    cumulativeHarvest += dailySockeye
                    cumulativeDriftHours += driftHours
                    cumulativeSetHours += setHours

                    let participating = (regBoats > 0) && hasRealDriftActivity
                    let driftHoursForEfficiency: Double = hasRealDriftActivity ? driftHours : 0

                    let dailyBoatHours = (regBoats > 0 && driftHoursForEfficiency > 0) ? (regBoats * driftHoursForEfficiency) : 0
                    cumulativeBoatHours += dailyBoatHours

                    if let escDaily = escByDate[dateStr] {
                        cumulativeEscapement += escDaily
                    }

                    var values: [DeepMetric: Double] = [
                        .districtRegistration: regBoats,
                        .driftPermits: driftPermitsPlusDual,
                        .dailyCatch: dailySockeye,
                        .escapement: escByDate[dateStr] ?? 0,
                        .cumulativeCatch: cumulativeHarvest,
                        .cumulativeHarvest: cumulativeHarvest,
                        .driftEffort: driftHours,
                        .setNetEffort: setHours,
                        .cumulativeDriftEffort: cumulativeDriftHours,
                        .cumulativeSetNetEffort: cumulativeSetHours,
                        .cumulativeBoatHours: cumulativeBoatHours,
                        .cumulativeEscapement: cumulativeEscapement
                    ]

                    if participating {
                        values[.sockeyePerDriftBoat] = driftSockeyeAdj / max(1, regBoats)
                    }

                    if dailyBoatHours > 0 {
                        values[.sockeyePerBoatHour] = driftSockeyeAdj / dailyBoatHours
                    }

                    if participating {
                        cumCatchPerBoat += (driftSockeyeAdj / max(1, regBoats))
                    }
                    values[.sockeyePerDriftBoatToDate] = cumCatchPerBoat

    #if DEBUG
    if dk == "togiak", y == 2020, dateStr >= "2020-07-18", dateStr <= "2020-08-20" {
        print("DeepResearch estimatedSet has districtRegistration?",
              estimatedSet.contains(.districtRegistration),
              "regRowNil=", (reg == nil))
    }
    #endif
                    return DeepDay(
                        dayIndex: idx,
                        mmddLabel: label(from: dateStr),
                        values: values,
                        estimatedMetrics: estimatedSet,
                        escapement: escByDate[dateStr]
                    )
                }

                built.append(YearSeries(year: y, district: district, isCurrentYear: false, days: days))
            }
        }

        return built
    }

    func loadSeries(appDB: AppDatabase?, years: [Int]) async throws -> [YearSeries] {
        try await loadSeries(appDB: appDB, years: years, districts: [district], metric: nil)
    }
    
}// MARK: - View

struct DeepResearchView: View {
    @StateObject private var vm = DeepResearchVM()

    @State private var selectedYearsTop: [Int] = [2025]
    @State private var selectedDistrictsTop: [District] = [.ugashik]

    private let districtSelectedPill = Color(red: 0.10, green: 0.35, blue: 0.20)
    private let neutralPill = Color.white.opacity(0.18)
    private let goPill = Color(red: 0.00, green: 0.48, blue: 1.00)

    var body: some View {
        ZStack(alignment: .top) {
            deepResearchShellBlue.ignoresSafeArea()
            HostingBackgroundFixer(color: deepResearchShellBlueUIColor)
                .frame(width: 0, height: 0)

            LinearGradient(
                colors: [deepResearchBackgroundTop, deepResearchBackgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: [.top, .leading, .trailing])

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    districtHeader

                    GraphCard(
                        title: "Pressure",
                        metrics: [
                            .districtRegistration,
                            .driftPermits,
                            .cumulativeDriftEffort,
                            .cumulativeSetNetEffort,
                            .driftEffort,
                            .setNetEffort,
                            .cumulativeBoatHours
                        ],
                        defaultMetric: .districtRegistration,
                        years: $selectedYearsTop,
                        districts: $selectedDistrictsTop,
                        vm: vm,
                        neutralPill: neutralPill,
                        goPill: goPill
                    )

                    GraphCard(
                        title: "Efficiency (Allocation-Adjusted**)",
                        metrics: [.sockeyePerDriftBoatToDate, .sockeyePerDriftBoat, .sockeyePerBoatHour],
                        defaultMetric: .sockeyePerDriftBoatToDate,
                        years: $selectedYearsTop,
                        districts: $selectedDistrictsTop,
                        vm: vm,
                        neutralPill: neutralPill,
                        goPill: goPill
                    )

                    GraphCard(
                        title: "Outcome (Drift + Set)",
                        metrics: [.cumulativeHarvest, .dailyCatch, .cumulativeEscapement, .escapement],
                        defaultMetric: .cumulativeHarvest,
                        years: $selectedYearsTop,
                        districts: $selectedDistrictsTop,
                        vm: vm,
                        neutralPill: neutralPill,
                        goPill: goPill
                    )

                    RunTimingCard(
                        title: "Run Timing",
                        years: $selectedYearsTop,
                        districts: $selectedDistrictsTop,
                        neutralPill: neutralPill,
                        goPill: goPill
                    )

                    OptimalTransfersCard(
                        title: "Optimal District & Transfers*",
                        neutralPill: neutralPill,
                        goPill: goPill
                    )
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 0)
            }
        }
        .navigationTitle("Charts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(deepResearchNavBarColor, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            BBMenuAppearance.applyNavBar()
        }
    }

    private var districtHeader: some View {
        VStack(spacing: 10) {
            districtButtonsRow
                .padding(.top, 10)

            yearsTopRow
        }
        .padding(12)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var districtButtonsRow: some View {
        HStack(spacing: 8) {
            ForEach(District.allCases) { d in
                let selected = selectedDistrictsTop.contains(d)
                Button { toggleTopDistrict(d) } label: {
                    Text(d == .naknekKvichak ? "Nak-Kvi" : d.rawValue)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: deepResearchSelectorHeight, maxHeight: deepResearchSelectorHeight)
                        .background(selected ? districtSelectedPill : neutralPill)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                }
                .buttonStyle(SatChartPressFeedbackButtonStyle())
            }
        }
        .padding(.horizontal, 2)
    }

    private var yearsTopRow: some View {
        let cols: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)
        return LazyVGrid(columns: cols, spacing: 8) {
            ForEach(vm.availableYears, id: \.self) { y in
                let selected = selectedYearsTop.contains(y)
                Button { toggleTopYear(y) } label: {
                    Text(verbatim: String(y))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(selected ? .black : .white)
                        .frame(maxWidth: .infinity, minHeight: deepResearchSelectorHeight, maxHeight: deepResearchSelectorHeight)
                        .background(selected ? Color.white : neutralPill)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(SatChartPressFeedbackButtonStyle())
            }
        }
    }

    private func toggleTopDistrict(_ d: District) {
        if let idx = selectedDistrictsTop.firstIndex(of: d) {
            if selectedDistrictsTop.count == 1 { return }
            selectedDistrictsTop.remove(at: idx)
            return
        }

        // If multiple years are selected, district mode is limited to a single district.
        if selectedYearsTop.count > 1 {
            selectedDistrictsTop = [d]
            return
        }

        if selectedDistrictsTop.count >= 4 {
            selectedDistrictsTop.removeLast()
        }
        selectedDistrictsTop.insert(d, at: 0)
    }

    private func toggleTopYear(_ y: Int) {
        if let idx = selectedYearsTop.firstIndex(of: y) {
            if selectedYearsTop.count == 1 { return }
            selectedYearsTop.remove(at: idx)
            return
        }

        // If multiple districts are selected, year mode is limited to a single year.
        if selectedDistrictsTop.count > 1 {
            selectedYearsTop = [y]
            return
        }

        if selectedYearsTop.count >= 4 {
            selectedYearsTop.removeLast()
        }
        selectedYearsTop.insert(y, at: 0)
    }
}

// MARK: - GraphCard

private struct GraphCard: View {
    let title: String
    let metrics: [DeepMetric]
    let defaultMetric: DeepMetric

    @Binding var years: [Int]
    @Binding var districts: [District]
    @ObservedObject var vm: DeepResearchVM
    let neutralPill: Color
    let goPill: Color

    @State private var selectedMetric: DeepMetric
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    @State private var series: [YearSeries] = []
    @State private var selectedPoint: SelectedGraphPoint? = nil

    @Environment(\.appDatabase) private var appDatabase

    init(
        title: String,
        metrics: [DeepMetric],
        defaultMetric: DeepMetric,
        years: Binding<[Int]>,
        districts: Binding<[District]>,
        vm: DeepResearchVM,
        neutralPill: Color,
        goPill: Color
    ) {
        self.title = title
        self.metrics = metrics
        self.defaultMetric = defaultMetric
        self._years = years
        self._districts = districts
        self.vm = vm
        self.neutralPill = neutralPill
        self.goPill = goPill
        _selectedMetric = State(initialValue: defaultMetric)
    }

    private enum ComparisonMode {
        case years
        case districts
    }

    private struct SelectedGraphPoint: Equatable {
        let x: Double
        let y: Double
        let label: String
        let value: Double
        let seriesName: String
    }

    private var comparisonMode: ComparisonMode {
        districts.count > 1 ? .districts : .years
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .underline(true, color: Color.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .center)

            metricAndGoRow
            chart
            legend

            if let msg = errorMessage {
                Text(msg)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.red.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var metricAndGoRow: some View {
        Group {
            if title == "Pressure" {
                pressureMetricRows
            } else {
                HStack(spacing: 8) {
                    metricRow
                        .frame(maxWidth: .infinity, alignment: .leading)
                    goButtonSmall
                }
            }
        }
    }

    private var goButtonSmall: some View {
        Button { Task { await run() } } label: {
            Text(isLoading ? "…" : "GO")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 58, height: deepResearchSelectorHeight)
                .background(goPill)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    private var pressureMetricRows: some View {
        let firstRowMetrics = Array(metrics.prefix(3))
        let secondRowMetrics = Array(metrics.dropFirst(3))

        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(firstRowMetrics) { m in
                    metricButton(for: m, wraps: true)
                }
                goButtonSmall
            }

            HStack(spacing: 8) {
                ForEach(secondRowMetrics) { m in
                    metricButton(for: m, wraps: true)
                }
            }
        }
    }
    private var metricRow: some View {
        let shouldWrap = title.hasPrefix("Efficiency") || title.hasPrefix("Outcome")
        return HStack(spacing: 8) {
            ForEach(metrics) { m in
                metricButton(for: m, wraps: shouldWrap)
            }
        }
    }

    @ViewBuilder
    private func metricButton(for m: DeepMetric, wraps: Bool) -> some View {
        let selected = (selectedMetric == m)
        Button {
            selectedMetric = m
            selectedPoint = nil
        } label: {
            Text(metricButtonTitle(for: m, wraps: wraps))
                .font(.system(size: wraps ? 10 : 11, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundColor(selected ? .black : .white)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: deepResearchSelectorHeight, maxHeight: deepResearchSelectorHeight)
                .lineLimit(wraps ? 2 : 1)
                .minimumScaleFactor(wraps ? 0.85 : 0.75)
                .background(selected ? Color.white : neutralPill)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    private func metricButtonTitle(for m: DeepMetric, wraps: Bool) -> String {
        guard wraps else { return shortLabel(for: m) }

        switch m {
        case .cumulativeDriftEffort: return "Drift-hrs\nCumulative"
        case .cumulativeSetNetEffort: return "Set-hrs\nCumulative"
        case .driftEffort: return "Drift-hrs\nDaily"
        case .setNetEffort: return "Set-hrs\nDaily"
        case .cumulativeBoatHours: return "Boat-hrs\nCumulative"
        case .sockeyePerDriftBoatToDate: return "Sockeye/Boat\nCumulative*"
        case .sockeyePerDriftBoat: return "Sockeye/Boat\nDaily"
        case .sockeyePerBoatHour: return "Sockeye/Boat\nHourly"
        case .cumulativeHarvest: return "Cumulative\nHarvest"
        case .dailyCatch: return "Daily\nHarvest"
        case .cumulativeEscapement: return "Cumulative\nEscapement"
        case .escapement: return "Daily\nEscapement"
        default: return shortLabel(for: m)
        }
    }

    private func shortLabel(for m: DeepMetric) -> String {
        switch m {
        case .districtRegistration: return "Drift Boats*"
        case .driftPermits: return "Drift Permits"
        case .cumulativeDriftEffort: return "Drift-hrs. Cumulative"
        case .cumulativeSetNetEffort: return "Set-hrs Cumulative"
        case .driftEffort: return "Drift-hrs Daily"
        case .setNetEffort: return "Set-hrs Daily"
        case .cumulativeBoatHours: return "Boat-hrs Cumulative"
        case .sockeyePerDriftBoatToDate: return "Sockeye/Boat Cumulative*"
        case .sockeyePerDriftBoat: return "Sockeye/Boat Daily*"
        case .sockeyePerBoatHour: return "Sockeye/Boat Hourly*"
        case .cumulativeHarvest: return "Cumulative Harvest"
        case .dailyCatch: return "Daily Harvest"
        case .cumulativeEscapement: return "Cumulative Escapement"
        case .escapement: return "Daily Escapement"
        default: return m.rawValue
        }
    }

    private func run() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let yrs = years.sorted()
            series = try await vm.loadSeries(appDB: appDatabase, years: yrs, districts: districts, metric: selectedMetric)
            selectedPoint = nil
        } catch {
            DeepResearchBetaError.debugLog(error, context: "Deep Research Charts")
            errorMessage = DeepResearchBetaError.userFacingMessage(for: error, feature: "Deep Research Charts")
            series = []
            selectedPoint = nil
        }
    }

    private var orderedYears: [Int] {
        let ys = series.map { $0.year }
        let unique = Array(Set(ys))
        return unique.isEmpty ? years.sorted() : unique.sorted()
    }

    private var orderedDistricts: [District] {
        let active = series.isEmpty ? districts : Array(Set(series.map { $0.district }))
        return District.allCases.filter { active.contains($0) }
    }

    private var yearPalette: [Color] {
        [
            Color(red: 0.15, green: 0.85, blue: 0.35),
            Color(red: 1.00, green: 0.55, blue: 0.10),
            Color(red: 0.25, green: 0.70, blue: 1.00),
            Color(red: 0.72, green: 0.46, blue: 0.95)
        ]
    }

    private func districtColor(_ district: District) -> Color {
        switch district {
        case .naknekKvichak: return Color(red: 0.25, green: 0.70, blue: 1.00)
        case .egegik: return Color(red: 1.00, green: 0.55, blue: 0.10)
        case .ugashik: return Color(red: 0.15, green: 0.85, blue: 0.35)
        case .nushagak: return Color(red: 0.95, green: 0.25, blue: 0.45)
        case .togiak: return Color(red: 0.85, green: 0.75, blue: 0.25)
        }
    }

    private func districtLabel(_ district: District) -> String {
        district == .naknekKvichak ? "Nak-Kvi" : district.rawValue
    }
    private func legendDistrictLabel(_ district: District) -> String {
        let base = districtLabel(district)
        let needsFootnote = title.hasPrefix("Outcome") && (district == .naknekKvichak || district == .nushagak)
        return needsFootnote ? "\(base)*" : base
    }

    private func yearKey(_ y: Int) -> String { String(y) }

    private func colorForYear(_ y: Int) -> Color {
        let idx = orderedYears.firstIndex(of: y) ?? 0
        return yearPalette[idx % yearPalette.count]
    }

    private func displayKey(for series: YearSeries) -> String {
        comparisonMode == .years ? yearKey(series.year) : series.district.rawValue
    }

    private var orderedDisplayKeys: [String] {
        switch comparisonMode {
        case .years:
            return orderedYears.map(yearKey)
        case .districts:
            return orderedDistricts.map { $0.rawValue }
        }
    }

    private func colorForDisplayKey(_ key: String) -> Color {
        switch comparisonMode {
        case .years:
            return colorForYear(Int(key) ?? (orderedYears.first ?? 2025))
        case .districts:
            return districtColor(District(rawValue: key) ?? .ugashik)
        }
    }

    private func colorForSeries(_ series: YearSeries) -> Color {
        comparisonMode == .years ? colorForYear(series.year) : districtColor(series.district)
    }

    private func displayName(for series: YearSeries) -> String {
        switch comparisonMode {
        case .years:
            return String(series.year)
        case .districts:
            return districtLabel(series.district)
        }
    }

    private struct XYPoint: Identifiable {
        let id = UUID()
        let x: Double
        let y: Double
    }

    private func cutoffIndex(for series: YearSeries) -> Int? {
        series.days.first(where: { $0.mmddLabel == "7/17" })?.dayIndex
    }

    private func shouldDashAfterCutoff(_ metric: DeepMetric) -> Bool {
        switch metric {
        case .cumulativeBoatHours,
             .sockeyePerDriftBoatToDate,
             .sockeyePerDriftBoat,
             .sockeyePerBoatHour:
            return true
        default:
            return false
        }
    }

    private var legend: some View {
        let showOutcomeDistrictFootnote = title.hasPrefix("Outcome") && comparisonMode == .districts && orderedDistricts.contains { $0 == .naknekKvichak || $0 == .nushagak }

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                switch comparisonMode {
                case .years:
                    ForEach(orderedYears, id: \.self) { y in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(colorForYear(y))
                                .frame(width: 8, height: 8)
                            Text(String(y))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                        }
                    }
                case .districts:
                    ForEach(orderedDistricts) { district in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(districtColor(district))
                                .frame(width: 8, height: 8)
                            Text(legendDistrictLabel(district))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            if showOutcomeDistrictFootnote {
                Text("*Escapement summed across reporting rivers in this district")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.70))
            }
        }
        .padding(.top, 2)
    }

    private var seriesOffsets: [String: Double] {
        let keys = orderedDisplayKeys
        let n = max(1, keys.count)
        let spread = min(1.30, 0.45 * Double(n - 1))
        if n == 1, let key = keys.first { return [key: 0.0] }
        let step = spread / Double(n - 1)
        let start = -spread / 2.0
        var out: [String: Double] = [:]
        for (i, key) in keys.enumerated() {
            out[key] = start + Double(i) * step
        }
        return out
    }

    private func xForSeries(_ series: YearSeries, dayIndex: Int) -> Double {
        Double(dayIndex) + (seriesOffsets[displayKey(for: series)] ?? 0.0)
    }

    private var barWidth: MarkDimension {
        let n = max(1, orderedDisplayKeys.count)
        let w: CGFloat
        switch n {
        case 1: w = 6
        case 2: w = 4
        default: w = 2.5
        }
        return .fixed(w)
    }

    private func labelForIndex(_ idx: Int) -> String {
        if let s0 = series.first, let day = s0.days.first(where: { $0.dayIndex == idx }) {
            return day.mmddLabel
        }
        return ""
    }

    private var selectablePoints: [SelectedGraphPoint] {
        series.flatMap { s in
            s.days.compactMap { d in
                guard let v = d.value(for: selectedMetric) else { return nil }
                return SelectedGraphPoint(
                    x: xForSeries(s, dayIndex: d.dayIndex),
                    y: v,
                    label: d.mmddLabel,
                    value: v,
                    seriesName: displayName(for: s)
                )
            }
        }
    }

    private func nearestPoint(atPlotX plotX: CGFloat, plotY: CGFloat, proxy: ChartProxy) -> SelectedGraphPoint? {
        let candidates = selectablePoints.compactMap { point -> (SelectedGraphPoint, CGFloat)? in
            guard let px = proxy.position(forX: point.x),
                  let py = proxy.position(forY: point.y) else {
                return nil
            }
            let dx = px - plotX
            let dy = py - plotY
            return (point, dx * dx + dy * dy)
        }

        return candidates.min { $0.1 < $1.1 }?.0
    }

    private func formattedSelectedValue(_ value: Double) -> String {
        let rounded = value.rounded()

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0

        return formatter.string(from: NSNumber(value: rounded)) ?? String(format: "%.0f", rounded)
    }

    @ChartContentBuilder
    private func chartMarks() -> some ChartContent {
        if selectedMetric == .districtRegistration {
            registrationMarks()
        } else {
            nonRegistrationMarks()
        }
    }

    @ChartContentBuilder
    private func registrationMarks() -> some ChartContent {
        ForEach(series) { s in
            // Force post-7/16 dashed rendering for:
            // - Togiak 2020 (backfilled observed DB values)
            // - all districts in 2015
            let forceDashAfterCutoff = (s.year == 2015) || (s.district == .togiak && s.year == 2020)
            let cutoffIdx: Int? = s.days.first(where: { $0.mmddLabel == "7/17" })?.dayIndex

            let firstEstimatedIdx: Int? = {
                guard !forceDashAfterCutoff else { return nil }
                return s.days
                    .filter { $0.isEstimated(.districtRegistration) }
                    .map { $0.dayIndex }
                    .min()
            }()

            let splitIdx: Int? = forceDashAfterCutoff ? cutoffIdx : firstEstimatedIdx

            let solidPts: [XYPoint] = {
                guard let splitIdx else {
                    return s.days.compactMap { d in
                        guard let v = d.value(for: .districtRegistration) else { return nil }
                        return XYPoint(x: xForSeries(s, dayIndex: d.dayIndex), y: v)
                    }.sorted { $0.x < $1.x }
                }

                let anchorIdx = max(0, splitIdx - 1)
                return s.days.compactMap { d in
                    guard d.dayIndex <= anchorIdx else { return nil }
                    guard let v = d.value(for: .districtRegistration) else { return nil }
                    return XYPoint(x: xForSeries(s, dayIndex: d.dayIndex), y: v)
                }.sorted { $0.x < $1.x }
            }()

            let dashedPts: [XYPoint] = {
                guard let splitIdx else { return [] }

                let anchorIdx = max(0, splitIdx - 1)
                var pts: [XYPoint] = []

                if let anchorDay = s.days.first(where: { $0.dayIndex == anchorIdx }),
                   let anchorVal = anchorDay.value(for: .districtRegistration) {
                    pts.append(XYPoint(x: xForSeries(s, dayIndex: anchorDay.dayIndex), y: anchorVal))
                }

                let tail = s.days.compactMap { d -> XYPoint? in
                    guard d.dayIndex >= splitIdx else { return nil }
                    guard let v = d.value(for: .districtRegistration) else { return nil }
                    return XYPoint(x: xForSeries(s, dayIndex: d.dayIndex), y: v)
                }

                pts.append(contentsOf: tail)
                return pts.sorted { $0.x < $1.x }
            }()

            let baseKey = displayKey(for: s)
            let solidSeries = "\(baseKey)-solid"
            let dashSeries  = "\(baseKey)-dash"

            ForEach(solidPts) { p in
                LineMark(
                    x: .value("Day", p.x),
                    y: .value("District Registration", p.y)
                )
                .foregroundStyle(by: .value("RegSeries", solidSeries))
                .interpolationMethod(.linear)
                .lineStyle(.init(lineWidth: 2))
                .opacity(0.95)
            }

            ForEach(dashedPts) { p in
                LineMark(
                    x: .value("Day", p.x),
                    y: .value("District Registration", p.y)
                )
                .foregroundStyle(by: .value("RegSeries", dashSeries))
                .interpolationMethod(.linear)
                .lineStyle(.init(lineWidth: 2, dash: [4, 4]))
                .opacity(0.95)
            }
        }
    }

    @ChartContentBuilder
    private func nonRegistrationMarks() -> some ChartContent {
        ForEach(series) { s in
            let cutoffIdx = cutoffIndex(for: s)

            if !isBarMetric(selectedMetric) {
                if shouldDashAfterCutoff(selectedMetric), let cutoffIdx {
                    let solidPts: [XYPoint] = s.days.compactMap { d in
                        guard d.dayIndex <= cutoffIdx else { return nil }
                        guard let v = d.value(for: selectedMetric) else { return nil }
                        return XYPoint(x: xForSeries(s, dayIndex: d.dayIndex), y: v)
                    }.sorted { $0.x < $1.x }

                    let dashedPts: [XYPoint] = {
                        var pts: [XYPoint] = []
                        if let anchorDay = s.days.first(where: { $0.dayIndex == cutoffIdx }),
                           let anchorVal = anchorDay.value(for: selectedMetric) {
                            pts.append(XYPoint(x: xForSeries(s, dayIndex: anchorDay.dayIndex), y: anchorVal))
                        }
                        let tail = s.days.compactMap { d -> XYPoint? in
                            guard d.dayIndex >= cutoffIdx else { return nil }
                            guard let v = d.value(for: selectedMetric) else { return nil }
                            return XYPoint(x: xForSeries(s, dayIndex: d.dayIndex), y: v)
                        }
                        pts.append(contentsOf: tail)
                        return pts.sorted { $0.x < $1.x }
                    }()

                    let baseKey = displayKey(for: s)
                    let solidSeries = "\(baseKey)-solid"
                    let dashedSeries = "\(baseKey)-dash"

                    ForEach(solidPts) { p in
                        LineMark(
                            x: .value("Day", p.x),
                            y: .value(selectedMetric.rawValue, p.y)
                        )
                        .foregroundStyle(by: .value("Series", solidSeries))
                        .interpolationMethod(.linear)
                        .lineStyle(.init(lineWidth: 2))
                        .opacity(0.95)
                    }

                    ForEach(dashedPts) { p in
                        LineMark(
                            x: .value("Day", p.x),
                            y: .value(selectedMetric.rawValue, p.y)
                        )
                        .foregroundStyle(by: .value("Series", dashedSeries))
                        .interpolationMethod(.linear)
                        .lineStyle(.init(lineWidth: 2, dash: [4, 4]))
                        .opacity(0.95)
                    }
                } else {
                    ForEach(s.days) { d in
                        if let v = d.value(for: selectedMetric) {
                            LineMark(
                                x: .value("Day", xForSeries(s, dayIndex: d.dayIndex)),
                                y: .value(selectedMetric.rawValue, v)
                            )
                            .foregroundStyle(by: .value("Series", displayKey(for: s)))
                            .interpolationMethod(.linear)
                            .lineStyle(.init(lineWidth: 2))
                            .opacity(0.95)
                        }
                    }
                }
            } else {
                ForEach(s.days) { d in
                    if let v = d.value(for: selectedMetric) {
                        let isEstimated = d.isEstimated(selectedMetric)

                        let isPost716DashedBar: Bool = {
                            guard let cutoffIdx else { return false }
                            switch selectedMetric {
                            case .sockeyePerDriftBoat, .sockeyePerBoatHour:
                                return d.dayIndex >= cutoffIdx
                            default:
                                return false
                            }
                        }()

                        let shouldShowDashedEquivalent = isEstimated || isPost716DashedBar

                        BarMark(
                            x: .value("Day", xForSeries(s, dayIndex: d.dayIndex)),
                            y: .value(selectedMetric.rawValue, v),
                            width: barWidth
                        )
                        .foregroundStyle(by: .value("Series", displayKey(for: s)))
                        .opacity(shouldShowDashedEquivalent ? 0.55 : 0.85)
                        .annotation(position: .overlay, alignment: .center) {
                            if shouldShowDashedEquivalent {
                                Rectangle()
                                    .stroke(style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                                    .foregroundStyle(colorForSeries(s))
                            }
                        }
                    }
                }
            }
        }
    }

    private var chart: some View {
        let maxIdx = max(0, series.first?.days.last?.dayIndex ?? 0)
        let xPad: Double = 0.75

        let metricValues: [Double] = series.flatMap { s in
            s.days.compactMap { $0.value(for: selectedMetric) }
        }
        let yMinRaw = metricValues.min() ?? 0
        let yMaxRaw = metricValues.max() ?? 1
        let ySpan = max(1e-9, yMaxRaw - yMinRaw)
        let yPad = ySpan * 0.08

        let yLower = isBarMetric(selectedMetric) ? 0.0 : max(0.0, yMinRaw - yPad)
        let yUpper = yMaxRaw + yPad

        let styleDomain: [String] = {
            if selectedMetric == .districtRegistration {
                return orderedDisplayKeys.flatMap { ["\($0)-solid", "\($0)-dash"] }
            }
            if !isBarMetric(selectedMetric) && shouldDashAfterCutoff(selectedMetric) {
                return orderedDisplayKeys.flatMap { ["\($0)-solid", "\($0)-dash"] }
            }
            return orderedDisplayKeys
        }()

        let styleRange: [Color] = {
            if selectedMetric == .districtRegistration {
                return orderedDisplayKeys.flatMap { key in
                    let c = colorForDisplayKey(key)
                    return [c, c]
                }
            }
            if !isBarMetric(selectedMetric) && shouldDashAfterCutoff(selectedMetric) {
                return orderedDisplayKeys.flatMap { key in
                    let c = colorForDisplayKey(key)
                    return [c, c]
                }
            }
            return orderedDisplayKeys.map { colorForDisplayKey($0) }
        }()

        let chartView = Chart {
            chartMarks()

            if let selectedPoint {
                RuleMark(x: .value("Selected Day", selectedPoint.x))
                    .foregroundStyle(Color.white.opacity(0.40))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedPoint.seriesName)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                            Text(selectedPoint.label)
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                            Text(formattedSelectedValue(selectedPoint.value))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                PointMark(
                    x: .value("Selected Day", selectedPoint.x),
                    y: .value("Selected Value", selectedPoint.y)
                )
                .symbolSize(40)
                .foregroundStyle(Color.white)
            }
        }
        .chartForegroundStyleScale(domain: styleDomain, range: styleRange)
        .chartPlotStyle { plot in plot.padding(.horizontal, 0) }
        .chartXScale(domain: (-xPad)...(Double(maxIdx) + xPad))
        .chartYScale(domain: yLower...yUpper)
        .chartXAxis {
            AxisMarks(values: .stride(by: 1)) { value in
                AxisTick().foregroundStyle(Color.white.opacity(0.35))

                let idx: Int? = value.as(Int.self) ?? value.as(Double.self).map { Int($0) }
                if let idx, idx % 5 == 0 {
                    let label = labelForIndex(idx)
                    if !label.isEmpty {
                        AxisValueLabel {
                            Text(label)
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }

                AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                AxisValueLabel()
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.90))
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                let plotFrame = geo[proxy.plotAreaFrame]
                                let localX = value.location.x - plotFrame.origin.x
                                let localY = value.location.y - plotFrame.origin.y

                                guard localX >= 0,
                                      localX <= plotFrame.size.width,
                                      localY >= 0,
                                      localY <= plotFrame.size.height else {
                                    selectedPoint = nil
                                    return
                                }

                                selectedPoint = nearestPoint(
                                    atPlotX: localX,
                                    plotY: localY,
                                    proxy: proxy
                                )
                            }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 12)
                            .onChanged { value in
                                let plotFrame = geo[proxy.plotAreaFrame]
                                let localX = value.location.x - plotFrame.origin.x
                                let localY = value.location.y - plotFrame.origin.y

                                guard localX >= 0,
                                      localX <= plotFrame.size.width,
                                      localY >= 0,
                                      localY <= plotFrame.size.height else {
                                    selectedPoint = nil
                                    return
                                }

                                selectedPoint = nearestPoint(
                                    atPlotX: localX,
                                    plotY: localY,
                                    proxy: proxy
                                )
                            }
                    )
            }
        }
        
        .frame(height: 220)

        return Group {
            let showConfNote = series.contains(where: { $0.district == .togiak && $0.year == 2020 })
            let showEfficiencyBlock = title.hasPrefix("Efficiency") &&
                (selectedMetric == .sockeyePerDriftBoatToDate ||
                 selectedMetric == .sockeyePerDriftBoat ||
                 selectedMetric == .sockeyePerBoatHour)
            let showEstimatedBoatsFootnote = title.hasPrefix("Efficiency") &&
                (selectedMetric == .sockeyePerDriftBoat ||
                 selectedMetric == .sockeyePerBoatHour)
            let showPressureEstimatedBoatsFootnote = title == "Pressure"

            if showEfficiencyBlock {
                VStack(spacing: 0) {
                    chartView
                    Text("**Uses observed allocation % to calculate drift sockeye catch. Daily values may be innacurate")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.70))
                        .padding(.top, 4)

                    if showEstimatedBoatsFootnote {
                        Text("*Daily boat count post 7/16 is estimated through a model utilizing drift deliveries, open hours, catch, allocation and known permit registration trends.")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.70))
                            .padding(.top, 2)
                            .multilineTextAlignment(.center)
                    }

                    if showConfNote {
                        Text("2020 Togiak harvest information confidential from 8/18-8/25 because fewer than three permit holders or processors involved in fishery. Daily harvest for these dates is an estimate based on cumulative harvest and other available data.")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.70))
                            .padding(.top, 2)
                            .multilineTextAlignment(.center)
                    }
                }
            } else if showPressureEstimatedBoatsFootnote {
                VStack(spacing: 0) {
                    chartView
                    Text("*Daily boat count post 7/16 is estimated through a model utilizing drift deliveries, open hours, catch, allocation and known permit registration trends.")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.70))
                        .padding(.top, 4)
                        .multilineTextAlignment(.center)

                    if showConfNote {
                        Text("Information confidential because fewer than three permit holders or processors involved in fishery.")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.70))
                            .padding(.top, 2)
                            .multilineTextAlignment(.center)
                    }
                }
            } else if showConfNote {
                VStack(spacing: 0) {
                    chartView
                    Text("Information confidential because fewer than three permit holders or processors involved in fishery.")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.70))
                        .padding(.top, 4)
                        .multilineTextAlignment(.center)
                }
            } else {
                chartView
            }
        }
    }

    private func isBarMetric(_ m: DeepMetric) -> Bool {
        switch m {
        case .dailyCatch, .escapement, .driftEffort, .setNetEffort, .sockeyePerDriftBoat, .sockeyePerBoatHour:
            return true
        default:
            return false
        }
    }
}
private struct RunTimingCard: View {
    let title: String
    @Binding var years: [Int]
    @Binding var districts: [District]
    let neutralPill: Color
    let goPill: Color

    @StateObject private var vm = RunTimingVM()
    @State private var selectedMetric: RunTimingMetric = .cumulativePercent
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var series: [RunTimingSeries] = []
    @State private var medianPeakByDistrict: [District: String] = [:]
    @Environment(\.appDatabase) private var appDatabase

    private enum ComparisonMode {
        case years
        case districts
    }

    private var comparisonMode: ComparisonMode {
        districts.count > 1 ? .districts : .years
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .underline(true, color: Color.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .center)

            metricAndGoRow
            chart
            legend

            Text("*Daily passage = harvest + lag-adjusted escapement.")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.70))
                .padding(.top, 2)

            if let msg = errorMessage {
                Text(msg)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.red.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var metricAndGoRow: some View {
        HStack(spacing: 8) {
            metricRow
                .frame(maxWidth: .infinity, alignment: .leading)
            goButtonSmall
        }
    }

    private var goButtonSmall: some View {
        Button { Task { await run() } } label: {
            Text(isLoading ? "…" : "GO")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 58, height: deepResearchSelectorHeight)
                .background(goPill)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    private var metricRow: some View {
        HStack(spacing: 8) {
            ForEach(RunTimingMetric.allCases) { metric in
                let selected = (selectedMetric == metric)
                Button {
                    selectedMetric = metric
                } label: {
                    Text(metricButtonTitle(metric))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundColor(selected ? .black : .white)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: deepResearchSelectorHeight, maxHeight: deepResearchSelectorHeight)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .background(selected ? Color.white : neutralPill)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(SatChartPressFeedbackButtonStyle())
            }
        }
    }

    private func metricButtonTitle(_ metric: RunTimingMetric) -> String {
        switch metric {
        case .cumulativePercent:
            return "Cumulative %\nRun"
        case .dailyPassage:
            return "Daily\nPassage"
        case .timingVsMedian:
            return "Timing vs\nMedian"
        }
    }

    private func run() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let yrs = years.sorted()
            let activeDistricts = districts.isEmpty ? [.ugashik] : districts

            series = try await vm.loadSeries(appDB: appDatabase, years: yrs, districts: activeDistricts)

            var medians: [District: String] = [:]
            let historicalYears = vm.availableYears.sorted()

            for district in activeDistricts {
                let historicalSeries = try await vm.loadSeries(
                    appDB: appDatabase,
                    years: historicalYears,
                    districts: [district]
                )
                if let med = medianPeakDateLabel(for: historicalSeries, district: district) {
                    medians[district] = med
                }
            }

            medianPeakByDistrict = medians
        } catch {
            DeepResearchBetaError.debugLog(error, context: "Run Timing")
            errorMessage = DeepResearchBetaError.userFacingMessage(for: error, feature: "Run Timing")
            series = []
            medianPeakByDistrict = [:]
        }
    }

    private var orderedYears: [Int] {
        let ys = series.map { $0.year }
        let unique = Array(Set(ys))
        return unique.isEmpty ? years.sorted() : unique.sorted()
    }

    private var orderedDistricts: [District] {
        let active = series.isEmpty ? districts : Array(Set(series.map { $0.district }))
        return District.allCases.filter { active.contains($0) }
    }

    private var yearPalette: [Color] {
        [
            Color(red: 0.15, green: 0.85, blue: 0.35),
            Color(red: 1.00, green: 0.55, blue: 0.10),
            Color(red: 0.25, green: 0.70, blue: 1.00),
            Color(red: 0.72, green: 0.46, blue: 0.95)
        ]
    }

    private func districtColor(_ district: District) -> Color {
        switch district {
        case .naknekKvichak: return Color(red: 0.25, green: 0.70, blue: 1.00)
        case .egegik: return Color(red: 1.00, green: 0.55, blue: 0.10)
        case .ugashik: return Color(red: 0.15, green: 0.85, blue: 0.35)
        case .nushagak: return Color(red: 0.95, green: 0.25, blue: 0.45)
        case .togiak: return Color(red: 0.85, green: 0.75, blue: 0.25)
        }
    }

    private func districtLabel(_ district: District) -> String {
        district == .naknekKvichak ? "Nak-Kvi" : district.rawValue
    }

    private func peakDateLabel(for series: RunTimingSeries) -> String? {
        let smoothed = series.days.map(\.smoothedDailyPassage)
        guard !smoothed.isEmpty else { return nil }

        // Peak = center day of the strongest 3-day smoothed passage window.
        if smoothed.count >= 3 {
            var bestCenterIndex = 1
            var bestWindowSum = smoothed[0] + smoothed[1] + smoothed[2]

            if smoothed.count > 3 {
                for center in 1..<(smoothed.count - 1) {
                    let windowSum = smoothed[center - 1] + smoothed[center] + smoothed[center + 1]
                    if windowSum > bestWindowSum {
                        bestWindowSum = windowSum
                        bestCenterIndex = center
                    }
                }
            }

            guard bestWindowSum > 0 else { return nil }
            return series.days[bestCenterIndex].mmddLabel
        }

        guard let maxValue = smoothed.max(), maxValue > 0,
              let maxIndex = smoothed.firstIndex(of: maxValue) else { return nil }
        return series.days[maxIndex].mmddLabel
    }

    private func fixedDate(from label: String) -> Date? {
        let parts = label.split(separator: "/")
        guard parts.count == 2,
              let month = Int(parts[0]),
              let day = Int(parts[1]) else { return nil }

        var comps = DateComponents()
        comps.calendar = Calendar(identifier: .gregorian)
        comps.year = 2001
        comps.month = month
        comps.day = day
        return comps.date
    }

    private func label(fromFixedDate date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }

    private func medianPeakDateLabel(for allSeries: [RunTimingSeries], district: District) -> String? {
        let dates = allSeries
            .filter { $0.district == district }
            .compactMap { peakDateLabel(for: $0) }
            .compactMap { fixedDate(from: $0) }
            .sorted()

        guard !dates.isEmpty else { return nil }

        let mid = dates.count / 2
        let medianDate: Date
        if dates.count % 2 == 1 {
            medianDate = dates[mid]
        } else {
            let t0 = dates[mid - 1].timeIntervalSinceReferenceDate
            let t1 = dates[mid].timeIntervalSinceReferenceDate
            medianDate = Date(timeIntervalSinceReferenceDate: (t0 + t1) / 2.0)
        }

        return label(fromFixedDate: medianDate)
    }

    private var showPeakLegendBoxes: Bool {
        !series.isEmpty
    }

    private func colorForSeries(_ series: RunTimingSeries) -> Color {
        comparisonMode == .years ? colorForYear(series.year) : districtColor(series.district)
    }

    private func colorForYear(_ year: Int) -> Color {
        let idx = orderedYears.firstIndex(of: year) ?? 0
        return yearPalette[idx % yearPalette.count]
    }

    private func displayKey(for series: RunTimingSeries) -> String {
        comparisonMode == .years ? String(series.year) : series.district.rawValue
    }

    private func colorForDisplayKey(_ key: String) -> Color {
        switch comparisonMode {
        case .years:
            return colorForYear(Int(key) ?? (orderedYears.first ?? 2025))
        case .districts:
            return districtColor(District(rawValue: key) ?? .ugashik)
        }
    }

    private var orderedDisplayKeys: [String] {
        switch comparisonMode {
        case .years:
            return orderedYears.map(String.init)
        case .districts:
            return orderedDistricts.map { $0.rawValue }
        }
    }

    private var seriesOffsets: [String: Double] {
        let keys = orderedDisplayKeys
        let n = max(1, keys.count)
        let spread = min(1.30, 0.45 * Double(n - 1))
        if n == 1, let key = keys.first { return [key: 0.0] }
        let step = spread / Double(n - 1)
        let start = -spread / 2.0
        var out: [String: Double] = [:]
        for (i, key) in keys.enumerated() {
            out[key] = start + Double(i) * step
        }
        return out
    }

    private func xForSeries(_ series: RunTimingSeries, dayIndex: Int) -> Double {
        Double(dayIndex) + (seriesOffsets[displayKey(for: series)] ?? 0.0)
    }

    private var barWidth: MarkDimension {
        let n = max(1, orderedDisplayKeys.count)
        let w: CGFloat
        switch n {
        case 1: w = 6
        case 2: w = 4
        default: w = 2.5
        }
        return .fixed(w)
    }

    private func labelForIndex(_ idx: Int) -> String {
        if let s0 = series.first, let day = s0.days.first(where: { $0.dayIndex == idx }) {
            return day.mmddLabel
        }
        return ""
    }

    @ChartContentBuilder
    private func chartMarks() -> some ChartContent {
        switch selectedMetric {
        case .cumulativePercent:
            cumulativePercentMarks(showP50Line: true)
        case .dailyPassage:
            dailyPassageMarks()
        case .timingVsMedian:
            timingVsMedianMarks()
        }
    }

    @ChartContentBuilder
    private func cumulativePercentMarks(showP50Line: Bool = false) -> some ChartContent {
        ForEach(series) { s in
            let key = displayKey(for: s)

            if showP50Line,
               let p50Day = s.days.first(where: { $0.cumulativePassagePct >= 50.0 }) {
                RuleMark(x: .value("P50 Day", xForSeries(s, dayIndex: p50Day.dayIndex)))
                    .foregroundStyle(by: .value("RunSeries", key))
                    .lineStyle(.init(lineWidth: 1.5, dash: [4, 4]))
                    .opacity(0.70)
            }

            ForEach(s.days) { d in
                LineMark(
                    x: .value("Day", xForSeries(s, dayIndex: d.dayIndex)),
                    y: .value("Cumulative % Run", d.cumulativePassagePct)
                )
                .foregroundStyle(by: .value("RunSeries", key))
                .interpolationMethod(.linear)
                .lineStyle(.init(lineWidth: 2))
                .opacity(0.95)
            }
        }
    }

    @ChartContentBuilder
    private func dailyPassageMarks() -> some ChartContent {
        ForEach(series) { s in
            let key = displayKey(for: s)

            ForEach(s.days) { d in
                BarMark(
                    x: .value("Day", xForSeries(s, dayIndex: d.dayIndex)),
                    y: .value("Daily Passage", d.dailyPassage),
                    width: barWidth
                )
                .foregroundStyle(by: .value("RunSeries", key))
                .opacity(0.35)
            }

            ForEach(s.days) { d in
                LineMark(
                    x: .value("Day", xForSeries(s, dayIndex: d.dayIndex)),
                    y: .value("Smoothed Daily Passage", d.smoothedDailyPassage)
                )
                .foregroundStyle(by: .value("RunSeries", key))
                .interpolationMethod(.linear)
                .lineStyle(.init(lineWidth: 2))
                .opacity(0.95)
            }
        }
    }

    @ChartContentBuilder
    private func timingVsMedianMarks() -> some ChartContent {
        if comparisonMode == .years, let referenceSeries = series.first {
            ForEach(referenceSeries.days) { d in
                if let p25 = d.p25Pct, let p75 = d.p75Pct {
                    AreaMark(
                        x: .value("Day", Double(d.dayIndex)),
                        yStart: .value("P25", p25),
                        yEnd: .value("P75", p75)
                    )
                    .foregroundStyle(Color.white.opacity(0.08))
                }
            }

            ForEach(referenceSeries.days) { d in
                if let median = d.medianPct {
                    LineMark(
                        x: .value("Day", Double(d.dayIndex)),
                        y: .value("Median %", median)
                    )
                    .foregroundStyle(Color.white.opacity(0.50))
                    .interpolationMethod(.linear)
                    .lineStyle(.init(lineWidth: 1.5, dash: [4, 4]))
                }
            }
        } else {
            ForEach(series) { s in
                ForEach(s.days) { d in
                    if let median = d.medianPct {
                        LineMark(
                            x: .value("Day", xForSeries(s, dayIndex: d.dayIndex)),
                            y: .value("Median %", median)
                        )
                        .foregroundStyle(Color.white.opacity(0.35))
                        .interpolationMethod(.linear)
                        .lineStyle(.init(lineWidth: 1.25, dash: [4, 4]))
                    }
                }
            }
        }

        cumulativePercentMarks(showP50Line: false)
    }

    private var legend: some View {
        HStack(alignment: .top, spacing: 10) {
            switch comparisonMode {
            case .years:
                ForEach(orderedYears, id: \.self) { year in
                    let color = colorForYear(year)
                    let peak = series.first(where: { $0.year == year }).flatMap { peakDateLabel(for: $0) }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(color)
                                .frame(width: 8, height: 8)
                            Text(String(year))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                        }

                        if showPeakLegendBoxes {
                            Text("Peak: \(peak ?? "—")")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                                )
                        }
                    }
                }

                if orderedDistricts.count == 1, let district = orderedDistricts.first {
                    let medPeak = medianPeakByDistrict[district]

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.clear)
                                .frame(width: 8, height: 8)
                            Text(" ")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(.clear)
                        }

                        Text("10Y Med Peak:\n\(medPeak ?? "—")")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
                            )
                    }
                }

            case .districts:
                ForEach(orderedDistricts) { district in
                    let color = districtColor(district)
                    let peak = series.first(where: { $0.district == district }).flatMap { peakDateLabel(for: $0) }
                    let medPeak = medianPeakByDistrict[district]

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(color)
                                .frame(width: 8, height: 8)
                            Text(districtLabel(district))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                        }

                        if showPeakLegendBoxes {
                            Text("Peak: \(peak ?? "—")")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                                )
                        }

                        Text("10Y Med Peak:\n\(medPeak ?? "—")")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
                            )
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }
    
    private var chart: some View {
        let maxIdx = max(0, series.first?.days.last?.dayIndex ?? 0)
        let xPad: Double = 0.75

        let metricValues: [Double] = series.flatMap { s in
            s.days.compactMap {
                switch selectedMetric {
                case .cumulativePercent, .timingVsMedian:
                    return $0.cumulativePassagePct
                case .dailyPassage:
                    return max($0.dailyPassage, $0.smoothedDailyPassage)
                }
            }
        }
        let yMaxRaw = metricValues.max() ?? 1
        let yUpper = max(1, yMaxRaw * 1.08)

        let styleDomain = orderedDisplayKeys
        let styleRange = orderedDisplayKeys.map { colorForDisplayKey($0) }

        return Chart {
            chartMarks()
        }
        .chartForegroundStyleScale(domain: styleDomain, range: styleRange)
        .chartPlotStyle { plot in plot.padding(.horizontal, 0) }
        .chartXScale(domain: (-xPad)...(Double(maxIdx) + xPad))
        .chartYScale(domain: 0...yUpper)
        .chartXAxis {
            AxisMarks(values: .stride(by: 1)) { value in
                AxisTick().foregroundStyle(Color.white.opacity(0.35))

                let idx: Int? = value.as(Int.self) ?? value.as(Double.self).map { Int($0) }
                if let idx, idx % 5 == 0 {
                    let label = labelForIndex(idx)
                    if !label.isEmpty {
                        AxisValueLabel {
                            Text(label)
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }

                AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                AxisValueLabel()
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.90))
            }
        }
        .chartLegend(.hidden)
        .frame(height: 220)
    }
}

// MARK: - Optimal District & Transfers

private struct OptimalPlanPoint: Identifiable {
    let id = UUID()
    let year: Int
    let xDate: Date          // normalized to a fixed year for charting
    let yCumulative: Double
    let district: String
    let isCooldown: Bool
    let seriesKey: String    // used to split into segments
    let color: Color
    let legendKey: String
}

private struct OptimalPlanSummary: Identifiable {
    let id = UUID()
    let year: Int
    let startingDistrict: String
    let transfersPre716: [(to: String, date: String)]
    let districtChangesPost716: [(to: String, date: String)]
    let cumulativeAsOfAug1: Double?
}

private enum OptimalGraphMode: String, CaseIterable, Identifiable {
    case transfer
    case district

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transfer: return "Optimal Transfer"
        case .district: return "Optimal District"
        }
    }
}

private struct OptimalDistrictSummary: Identifiable {
    let id = UUID()
    let year: Int
    let districtKey: String
    let districtLabel: String
    let cumulativeSockeyePerBoat: Double
}

private let optimalDistrictOrder: [String] = [
    "naknek_kvichak",
    "egegik",
    "ugashik",
    "nushagak",
    "togiak"
]

private func optimalDistrictOrderIndex(_ districtKey: String) -> Int {
    optimalDistrictOrder.firstIndex(of: districtKey.lowercased()) ?? Int.max
}

private func optimalDistrictDisplayName(_ districtKey: String) -> String {
    switch districtKey.lowercased() {
    case "naknek-kvichak", "naknek_kvichak", "naknekkvichak":
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
        return districtKey
    }
}

private enum OptimalPlanLoadError: LocalizedError {
    case unavailableInOfflinePack
    case invalidFormat(String)
    case noSockeyePerBoatRows(Int)

    var errorDescription: String? {
        switch self {
        case .unavailableInOfflinePack:
            return "Optimal transfer data is not available in this offline data pack. Update SatChart offline data and try again."
        case .invalidFormat(let msg): return msg
        case .noSockeyePerBoatRows(let year):
            return "No sockeye/boat daily rows found for \(year)."
        }
    }

    static func userFacingMessage(for error: Error) -> String {
        if let loadError = error as? OptimalPlanLoadError {
            switch loadError {
            case .unavailableInOfflinePack:
                return loadError.localizedDescription
            case .noSockeyePerBoatRows:
                return loadError.localizedDescription
            case .invalidFormat:
                return "Optimal transfer data for the selected year is incomplete in this beta data pack. Open Beta Diagnostics in Settings to verify the offline database."
            }
        }
        return DeepResearchBetaError.userFacingMessage(for: error, feature: "Optimal District & Transfers")
    }
}

private struct OptimalDistrictDBLoader {
    private static let ymd = DateFormatter.with(format: "yyyy-MM-dd")
    private static let fixedYear = 2000
    private static let loadSQL = """
        SELECT
            date,
            districtKey,
            sockeyePerBoatAllocAdj
        FROM exporter_sockeye_per_boat_daily
        WHERE date >= ?
          AND date <= ?
        ORDER BY date, districtKey
    """

    private struct OptimalDistrictRow: FetchableRecord, Decodable {
        let date: String
        let districtKey: String
        let sockeyePerBoatAllocAdj: Double?
    }

    static func load(appDB: AppDatabase, year: Int, color: Color) throws -> (points: [OptimalPlanPoint], summary: OptimalDistrictSummary) {
        let rows: [OptimalDistrictRow]
        do {
            rows = try appDB.dbQueue.read { db in
                try OptimalDistrictRow.fetchAll(db, sql: Self.loadSQL, arguments: [
                    String(format: "%04d-06-12", year),
                    String(format: "%04d-08-01", year)
                ])
            }
        } catch {
            #if DEBUG
            print("""
            OptimalDistrictDBLoader failed.
            Year: \(year)
            SQL: \(Self.loadSQL)
            Error: \(error)
            """)
            #endif
            throw error
        }

        let grouped = Dictionary(grouping: rows) { $0.districtKey.lowercased() }
        let districtSums: [(districtKey: String, total: Double)] = grouped.map { districtKey, districtRows in
            let total = districtRows.reduce(0.0) { partial, row in
                guard let value = row.sockeyePerBoatAllocAdj, value.isFinite, value > 0 else { return partial }
                return partial + value
            }
            return (districtKey, total)
        }

        guard let winner = districtSums
            .filter({ $0.total > 0 && $0.total.isFinite })
            .max(by: { lhs, rhs in
                if lhs.total != rhs.total { return lhs.total < rhs.total }
                return optimalDistrictOrderIndex(lhs.districtKey) > optimalDistrictOrderIndex(rhs.districtKey)
            }) else {
            throw OptimalPlanLoadError.noSockeyePerBoatRows(year)
        }

        let winningRows = (grouped[winner.districtKey] ?? [])
            .sorted { $0.date < $1.date }

        var cumulativeSockeyePerBoat = 0.0
        let points = winningRows.compactMap { row -> OptimalPlanPoint? in
            guard let x = normalizeToFixedYear(row.date) else { return nil }
            let value = row.sockeyePerBoatAllocAdj.flatMap { $0.isFinite ? $0 : nil } ?? 0
            cumulativeSockeyePerBoat += max(0, value)
            return OptimalPlanPoint(
                year: year,
                xDate: x,
                yCumulative: cumulativeSockeyePerBoat,
                district: winner.districtKey,
                isCooldown: false,
                seriesKey: "\(year)-optimal-district-\(winner.districtKey)",
                color: color,
                legendKey: "\(year) - \(optimalDistrictDisplayName(winner.districtKey))"
            )
        }

        guard !points.isEmpty else {
            throw OptimalPlanLoadError.noSockeyePerBoatRows(year)
        }

        return (
            points,
            OptimalDistrictSummary(
                year: year,
                districtKey: winner.districtKey,
                districtLabel: optimalDistrictDisplayName(winner.districtKey),
                cumulativeSockeyePerBoat: winner.total
            )
        )
    }

    private static func normalizeToFixedYear(_ yyyyMMdd: String) -> Date? {
        guard let date = ymd.date(from: yyyyMMdd) else { return nil }
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.month, .day], from: date)
        return cal.date(from: DateComponents(calendar: cal, year: fixedYear, month: c.month, day: c.day))
    }
}

private struct OptimalPlanDBLoader {
    private static let ymd = DateFormatter.with(format: "yyyy-MM-dd")
    private static let fixedYear = 2000
    private static let loadSQL = """
        SELECT
            year,
            date,
            district_key AS districtKey,
            is_cooldown_day AS isCooldownDay,
            transfer,
            transfer_to AS transferTo,
            cumulative_sockeye_per_boat_to_date AS cumulativeSockeyePerBoatToDate
        FROM optimal_transfer_plan_day
        WHERE year = ?
          AND date >= ?
          AND date <= ?
        ORDER BY date
    """

    private struct PlanRow: FetchableRecord, Decodable {
        let year: Int
        let date: String
        let districtKey: String
        let isCooldownDay: Int
        let transfer: Int
        let transferTo: String?
        let cumulativeSockeyePerBoatToDate: Double
    }

    private static func mmddInt(_ yyyyMMdd: String) -> Int {
        let mmdd = String(yyyyMMdd.suffix(5)).replacingOccurrences(of: "-", with: "")
        return Int(mmdd) ?? 0
    }

    private static func isMissingOptimalTransferTable(_ error: Error) -> Bool {
        let message = "\(error.localizedDescription) \(String(describing: error))"
        return message.localizedCaseInsensitiveContains("no such table")
            && message.localizedCaseInsensitiveContains("optimal_transfer_plan_day")
    }
    
    static func load(appDB: AppDatabase, year: Int) throws -> (points: [OptimalPlanPoint], summary: OptimalPlanSummary) {
        let rows: [PlanRow]
        do {
            rows = try appDB.dbQueue.read { db in
                try PlanRow.fetchAll(db, sql: Self.loadSQL, arguments: [
                    year,
                    String(format: "%04d-06-12", year),
                    String(format: "%04d-08-01", year)
                ])
            }
        } catch {
            #if DEBUG
            print("""
            OptimalPlanDBLoader failed.
            Year: \(year)
            SQL: \(Self.loadSQL)
            Error: \(error)
            """)
            #endif

            if Self.isMissingOptimalTransferTable(error) {
                throw OptimalPlanLoadError.unavailableInOfflinePack
            }

            throw error
        }

        guard let first = rows.first else {
            throw OptimalPlanLoadError.invalidFormat("No optimal transfer rows found in offline DB for year \(year)")
        }

        func districtColor(_ d: String) -> Color {
            switch d.lowercased() {
            case "naknek-kvichak", "naknek_kvichak", "naknekkvichak":
                return Color(red: 0.25, green: 0.70, blue: 1.00)
            case "egegik":
                return Color(red: 1.00, green: 0.55, blue: 0.10)
            case "ugashik":
                return Color(red: 0.15, green: 0.85, blue: 0.35)
            case "nushagak":
                return Color(red: 0.95, green: 0.25, blue: 0.45)
            case "togiak":
                return Color(red: 0.85, green: 0.75, blue: 0.25)
            default:
                return .white
            }
        }

        func normalizeToFixedYear(_ yyyyMMdd: String) -> Date? {
            guard let date = ymd.date(from: yyyyMMdd) else { return nil }
            let cal = Calendar(identifier: .gregorian)
            let c = cal.dateComponents([.month, .day], from: date)
            return cal.date(from: DateComponents(calendar: cal, year: fixedYear, month: c.month, day: c.day))
        }

        var outPoints: [OptimalPlanPoint] = []
        outPoints.reserveCapacity(rows.count * 2)

        var cooldownRun = 0
        var districtRun = 0
        var inCooldown = false
        var previousWasCooldown = false
        var previousDistrictKey = first.districtKey

        var prevDistrictForContinuation = first.districtKey
        var prevCum = first.cumulativeSockeyePerBoatToDate

        for (index, r) in rows.enumerated() {
            guard let x = normalizeToFixedYear(r.date) else { continue }

            let isCooldown = (r.isCooldownDay != 0)

            if isCooldown {
                if !inCooldown {
                    inCooldown = true
                    cooldownRun += 1
                }

                // Cooldown period should render as a flat gray continuation of the prior district line.
                outPoints.append(
                    OptimalPlanPoint(
                        year: year,
                        xDate: x,
                        yCumulative: prevCum,
                        district: prevDistrictForContinuation,
                        isCooldown: true,
                        seriesKey: "\(year)-cooldown-\(cooldownRun)",
                        color: Color.gray.opacity(0.75),
                        legendKey: "Cooldown"
                    )
                )
            } else {
                if inCooldown {
                    inCooldown = false
                }

                let startsNewDistrictRun = (index == 0) || previousWasCooldown || (r.districtKey != previousDistrictKey)
                if startsNewDistrictRun {
                    districtRun += 1
                }

                outPoints.append(
                    OptimalPlanPoint(
                        year: year,
                        xDate: x,
                        yCumulative: r.cumulativeSockeyePerBoatToDate,
                        district: r.districtKey,
                        isCooldown: false,
                        seriesKey: "\(year)-district-run-\(districtRun)",
                        color: districtColor(r.districtKey),
                        legendKey: r.districtKey
                    )
                )

                prevDistrictForContinuation = r.districtKey
                previousDistrictKey = r.districtKey
            }

            if !isCooldown {
                prevCum = r.cumulativeSockeyePerBoatToDate
                prevDistrictForContinuation = r.districtKey
                previousDistrictKey = r.districtKey
            }
            previousWasCooldown = isCooldown
        }

        var transfersPre716: [(String, String)] = []
        var districtChangesPost716: [(String, String)] = []

        var prevDistrict = first.districtKey
        var prevWasCooldown = (first.isCooldownDay != 0)

        for r in rows.dropFirst() {
            let post716 = Self.mmddInt(r.date) >= 717
            if r.transfer != 0, let to = r.transferTo, !to.isEmpty {
                if !post716 {
                    transfersPre716.append((to, r.date))
                } else {
                    districtChangesPost716.append((to, r.date))
                }
            }

            let isCooldown = (r.isCooldownDay != 0)
            if post716, !isCooldown, !prevWasCooldown, r.districtKey != prevDistrict {
                districtChangesPost716.append((r.districtKey, r.date))
            }

            if !isCooldown { prevDistrict = r.districtKey }
            prevWasCooldown = isCooldown
        }

        let cumAug1 = rows.last(where: { Self.mmddInt($0.date) == 801 })?.cumulativeSockeyePerBoatToDate ?? rows.last?.cumulativeSockeyePerBoatToDate

        let summary = OptimalPlanSummary(
            year: year,
            startingDistrict: first.districtKey,
            transfersPre716: transfersPre716,
            districtChangesPost716: districtChangesPost716,
            cumulativeAsOfAug1: cumAug1
        )

        return (outPoints, summary)
    }
}

private struct OptimalTransfersCard: View {
    let title: String
    let neutralPill: Color
    let goPill: Color

    private let yearsAll = Array(2015...2025)

    @State private var selectedYears: [Int] = [2025]
    @State private var selectedMode: OptimalGraphMode = .transfer
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    @State private var pointsByYear: [Int: [OptimalPlanPoint]] = [:]
    @State private var summaries: [OptimalPlanSummary] = []
    @State private var districtSummaries: [OptimalDistrictSummary] = []
    @Environment(\.appDatabase) private var appDatabase

    private struct ChartSegment: Identifiable {
        let id: String
        let start: OptimalPlanPoint
        let end: OptimalPlanPoint
        let color: Color
    }

    private static let yearFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.usesGroupingSeparator = false
        nf.maximumFractionDigits = 0
        return nf
    }()

    private static let wholeNumberFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.usesGroupingSeparator = true
        nf.maximumFractionDigits = 0
        return nf
    }()

    private func formatYear(_ year: Int) -> String {
        Self.yearFormatter.string(from: NSNumber(value: year)) ?? String(year)
    }

    private func formatWhole(_ value: Double) -> String {
        Self.wholeNumberFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }

    private func yearColor(for year: Int) -> Color {
        let palette: [Color] = [
            Color(red: 0.25, green: 0.70, blue: 1.00),
            Color(red: 1.00, green: 0.55, blue: 0.10),
            Color(red: 0.15, green: 0.85, blue: 0.35),
            Color(red: 0.95, green: 0.25, blue: 0.45),
            Color(red: 0.85, green: 0.75, blue: 0.25),
            Color(red: 0.75, green: 0.55, blue: 1.00)
        ]
        let index = abs(year - 2015) % palette.count
        return palette[index]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .underline(true, color: Color.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .center)

            modeSelectorRow
            chart
            legendView

            yearsAndGoRow

            if let msg = errorMessage {
                Text(msg)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.red.opacity(0.9))
                    .multilineTextAlignment(.center)
            }

            summariesView

            footnotesView
        }
        .padding(12)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .onAppear {
            if pointsByYear.isEmpty && !isLoading {
                run()
            }
        }
        .onChange(of: selectedMode) { _ in
            clearChartState()
            run()
        }
    }

    private var modeSelectorRow: some View {
        HStack(spacing: 8) {
            ForEach(OptimalGraphMode.allCases) { mode in
                let selected = selectedMode == mode
                Button {
                    selectedMode = mode
                } label: {
                    Text(mode.title)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(selected ? .black : .white)
                        .frame(maxWidth: .infinity, minHeight: deepResearchSelectorHeight, maxHeight: deepResearchSelectorHeight)
                        .background(selected ? Color.white : neutralPill)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(SatChartPressFeedbackButtonStyle())
            }
        }
    }
    
    private var yearsAndGoRow: some View {
        VStack(spacing: 8) {
            let cols: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(yearsAll, id: \.self) { y in
                    let selected = selectedYears.contains(y)
                    Button { toggleYear(y) } label: {
                        Text(verbatim: String(y))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(selected ? .black : .white)
                            .frame(maxWidth: .infinity, minHeight: deepResearchSelectorHeight, maxHeight: deepResearchSelectorHeight)
                            .background(selected ? Color.white : neutralPill)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(SatChartPressFeedbackButtonStyle())
                }
            }

            HStack {
                Spacer(minLength: 0)
                Button { run() } label: {
                    Text(isLoading ? "…" : "Go")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .frame(width: 58, height: deepResearchSelectorHeight)
                        .background(goPill)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(SatChartPressFeedbackButtonStyle())
            }
        }
    }

    private var legendView: some View {
        let items: [(label: String, color: Color)] = {
            switch selectedMode {
            case .transfer:
                return [
                    ("Nak-Kvi", Color(red: 0.25, green: 0.70, blue: 1.00)),
                    ("Egegik", Color(red: 1.00, green: 0.55, blue: 0.10)),
                    ("Ugashik", Color(red: 0.15, green: 0.85, blue: 0.35)),
                    ("Nushagak", Color(red: 0.95, green: 0.25, blue: 0.45)),
                    ("Togiak", Color(red: 0.85, green: 0.75, blue: 0.25)),
                    ("Cooldown", Color.gray.opacity(0.75))
                ]
            case .district:
                return districtSummaries
                    .sorted { $0.year < $1.year }
                    .map { summary in
                        ("\(formatYear(summary.year)) - \(summary.districtLabel)", yearColor(for: summary.year))
                    }
            }
        }()

        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
            spacing: 6
        ) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 6) {
                    Capsule()
                        .fill(item.color)
                        .frame(width: 16, height: 6)
                    Text(item.label)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.top, 2)
    }
    
    private func toggleYear(_ y: Int) {
        if let idx = selectedYears.firstIndex(of: y) {
            selectedYears.remove(at: idx)
        } else {
            if selectedYears.count >= 4 { selectedYears.removeLast() }
            selectedYears.insert(y, at: 0)
        }
        selectedYears = Array(selectedYears.prefix(4))
    }

    private func run() {
        isLoading = true
        errorMessage = nil
        clearChartState()
        defer { isLoading = false }

        guard let appDatabase else {
            errorMessage = "Offline database unavailable."
            return
        }

        do {
            let years = selectedYears.sorted()
            var newPoints: [Int: [OptimalPlanPoint]] = [:]
            var newSummaries: [OptimalPlanSummary] = []
            var newDistrictSummaries: [OptimalDistrictSummary] = []

            switch selectedMode {
            case .transfer:
                for y in years {
                    let (pts, summary) = try OptimalPlanDBLoader.load(appDB: appDatabase, year: y)
                    newPoints[y] = pts
                    newSummaries.append(summary)
                }

            case .district:
                for y in years {
                    let (pts, summary) = try OptimalDistrictDBLoader.load(
                        appDB: appDatabase,
                        year: y,
                        color: yearColor(for: y)
                    )
                    newPoints[y] = pts
                    newDistrictSummaries.append(summary)
                }
            }

            pointsByYear = newPoints
            summaries = newSummaries.sorted { $0.year < $1.year }
            districtSummaries = newDistrictSummaries.sorted { $0.year < $1.year }
        } catch {
            #if DEBUG
            print("Optimal District & Transfers load failed for years \(selectedYears.sorted()): \(error)")
            #endif
            errorMessage = OptimalPlanLoadError.userFacingMessage(for: error)
        }
    }

    private func clearChartState() {
        pointsByYear = [:]
        summaries = []
        districtSummaries = []
    }

    private var emptyChartText: String {
        switch selectedMode {
        case .transfer:
            return "Select up to 4 years and tap Go"
        case .district:
            return "Select up to 4 years to graph each year's optimal district"
        }
    }

    private var yAxisLabel: String {
        switch selectedMode {
        case .transfer: return "Sockeye/Boat Cumulative"
        case .district: return "Sockeye/Boat Cumulative"
        }
    }

    private var chart: some View {
        let allPoints = pointsByYear.values.flatMap { $0 }

        let cal = Calendar(identifier: .gregorian)
        let start = cal.date(from: DateComponents(calendar: cal, year: 2000, month: 6, day: 12)) ?? Date()
        let end = cal.date(from: DateComponents(calendar: cal, year: 2000, month: 8, day: 1)) ?? Date()

        if allPoints.isEmpty {
            return AnyView(
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.04))

                    Text(isLoading ? "Loading…" : emptyChartText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.65))
                }
                .frame(height: 240)
            )
        }

        let yMax = (allPoints.map { $0.yCumulative }.max() ?? 1)
        let yUpper = max(1, yMax * 1.06)

        let pointsByYearSorted: [(year: Int, points: [OptimalPlanPoint])] = pointsByYear
            .keys
            .sorted()
            .map { year in
                let pts = (pointsByYear[year] ?? []).sorted { a, b in
                    if a.xDate != b.xDate { return a.xDate < b.xDate }
                    if a.isCooldown != b.isCooldown { return a.isCooldown && !b.isCooldown }
                    return a.yCumulative < b.yCumulative
                }
                return (year: year, points: pts)
            }

       
        
        let segments: [ChartSegment] = pointsByYearSorted.flatMap { entry -> [ChartSegment] in
            let pts = entry.points
            guard pts.count >= 2 else { return [] }

            var segs: [ChartSegment] = []
            segs.reserveCapacity(max(0, pts.count - 1))

            for idx in pts.indices.dropFirst() {
                let prev = pts[idx - 1]
                let curr = pts[idx]

                if selectedMode == .district {
                    segs.append(
                        ChartSegment(
                            id: "\(entry.year)-district-\(idx)-\(curr.xDate.timeIntervalSinceReferenceDate)",
                            start: prev,
                            end: curr,
                            color: curr.color
                        )
                    )
                    continue
                }

                // Normal case: continue drawing within the same run.
                if prev.seriesKey == curr.seriesKey {
                    segs.append(
                        ChartSegment(
                            id: "\(entry.year)-\(idx)-same-\(curr.seriesKey)-\(curr.xDate.timeIntervalSinceReferenceDate)",
                            start: prev,
                            end: curr,
                            color: curr.color
                        )
                    )
                    continue
                }

                // Entering a stand-down period: keep the bridge in the prior district color
                // so the gray line begins on the first actual stand-down day.
                if curr.isCooldown {
                    segs.append(
                        ChartSegment(
                            id: "\(entry.year)-\(idx)-into-cooldown-\(curr.xDate.timeIntervalSinceReferenceDate)",
                            start: prev,
                            end: curr,
                            color: prev.color
                        )
                    )
                    continue
                }

                // Leaving a stand-down period: draw the bridge in gray so the stand-down line
                // stays connected all the way to the first new fishing day, while the new district
                // color starts on its actual run.
                if prev.isCooldown {
                    segs.append(
                        ChartSegment(
                            id: "\(entry.year)-\(idx)-out-of-cooldown-\(curr.xDate.timeIntervalSinceReferenceDate)",
                            start: prev,
                            end: curr,
                            color: prev.color
                        )
                    )
                    continue
                }

                // Direct district-to-district handoff (no stand-down): keep the bridge in the old district color
                // so the new district color begins on its actual start date.
                segs.append(
                    ChartSegment(
                        id: "\(entry.year)-\(idx)-handoff-\(curr.xDate.timeIntervalSinceReferenceDate)",
                        start: prev,
                        end: curr,
                        color: prev.color
                    )
                )
            }

            return segs
        }
        let styleDomain = segments.map { $0.id }
        let styleRange = segments.map { $0.color }

        return AnyView(
            Chart {
                ForEach(segments) { segment in
                    LineMark(
                        x: .value("Date", segment.start.xDate),
                        y: .value(yAxisLabel, segment.start.yCumulative)
                    )
                    .foregroundStyle(by: .value("Segment", segment.id))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.linear)

                    LineMark(
                        x: .value("Date", segment.end.xDate),
                        y: .value(yAxisLabel, segment.end.yCumulative)
                    )
                    .foregroundStyle(by: .value("Segment", segment.id))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.linear)
                }
            }
            .chartForegroundStyleScale(domain: styleDomain, range: styleRange)
            .chartXScale(domain: start...end)
            .chartYScale(domain: 0...yUpper)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 5)) { v in
                    AxisValueLabel {
                        if let d = v.as(Date.self) {
                            Text(mmddLabel(d))
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                }
            }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 10)) { _ in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                        AxisValueLabel()
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.90))
                    }
                }
            .chartLegend(.hidden)
            .frame(height: 260)
        )
    }
    
    private func mmddLabel(_ date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.month, .day], from: date)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }

    @ViewBuilder
    private var footnotesView: some View {
        switch selectedMode {
        case .transfer:
            Text("*Daily boat count post 7/16 is estimated through a model utilizing drift deliveries, open hours, catch, allocation and known permit registration trends.")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.70))
                .padding(.top, 2)

        case .district:
            VStack(alignment: .leading, spacing: 4) {
                Text("*Optimal District selects the district with the highest cumulative sockeye/boat over 6/12-8/1 for each selected year, then graphs that district's cumulative daily sockeye/boat.")
                Text("*Daily boat count post 7/16 is estimated through a model utilizing drift deliveries, open hours, catch, allocation and known permit registration trends.")
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(0.70))
            .padding(.top, 2)
        }
    }

    private var summariesView: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch selectedMode {
            case .transfer:
                ForEach(summaries) { s in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Year: \(formatYear(s.year))")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        Text("Starting District: \(s.startingDistrict)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.92))

                        if s.transfersPre716.isEmpty {
                            Text("Transfer: None")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(.white.opacity(0.92))
                        } else {
                            ForEach(Array(s.transfersPre716.enumerated()), id: \.offset) { _, t in
                                Text("Transfer: \(t.to), Date: \(t.date)")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white.opacity(0.92))
                            }
                        }

                        if !s.districtChangesPost716.isEmpty {
                            ForEach(Array(s.districtChangesPost716.enumerated()), id: \.offset) { _, dc in
                                Text("District Change: \(dc.to), Date: \(dc.date)")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white.opacity(0.92))
                            }
                        }

                        if let cum = s.cumulativeAsOfAug1 {
                            Text("Cumulative Sockeye/Boat: \(formatWhole(cum))")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
                }

            case .district:
                ForEach(districtSummaries) { s in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Year: \(formatYear(s.year))")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        Text("Optimal District: \(s.districtLabel)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.92))

                        Text("Cumulative Sockeye/Boat: \(formatWhole(s.cumulativeSockeyePerBoat))")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
                }
            }
        }
        .padding(.top, 2)
    }
}

private extension DateFormatter {
    static func with(format: String) -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = format
        return df
    }
}
