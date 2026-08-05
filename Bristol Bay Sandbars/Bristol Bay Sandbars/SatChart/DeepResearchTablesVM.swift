import Foundation
import Combine
import GRDB

enum DeepResearchTablesOutputMode: String, CaseIterable, Identifiable, Sendable {
    case display
    case csv

    nonisolated var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .display: return "Display"
        case .csv: return "CSV Export"
        }
    }
}

// MARK: - Metric Grouping

enum DeepResearchTableMetricGroup: String, CaseIterable, Identifiable, Sendable {
    case pressure
    case efficiency
    case outcome
    case runTiming
    case rawInputs

    nonisolated var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .pressure: return "Pressure"
        case .efficiency: return "Efficiency"
        case .outcome: return "Outcome"
        case .runTiming: return "Run Timing"
        case .rawInputs: return "Raw Inputs / Diagnostics"
        }
    }
}

// MARK: - Metric Definitions

enum DeepResearchTableMetric: String, CaseIterable, Identifiable, Hashable, Sendable {
    // Pressure
    case driftBoats
    case driftPermits
    case cumulativeDriftHours
    case cumulativeSetHours
    case dailyDriftHours
    case dailySetHours
    case cumulativeBoatHours
    case totalDriftHours
    case totalSetHours
    case maxDriftBoats
    case maxDriftPermits
    case averageDriftBoats
    case averageDriftPermits

    // Efficiency
    case sockeyePerBoatCumulative
    case sockeyePerBoatDaily
    case sockeyePerBoatDailyTopDistrict
    case topDistrictTenYearMeanDaily
    case sockeyePerBoatHourly
    case totalSockeyePerBoat
    case averageSockeyePerBoatPerDay
    case averageSockeyePerBoatPerHour

    // Outcome
    case cumulativeHarvest
    case dailyHarvest
    case cumulativeEscapement
    case dailyEscapement
    case totalHarvest
    case totalEscapement
    case totalRun
    case totalSockeyeDrift
    case totalSockeyeSet
    case totalChumPct
    case meanSockeyeWeight
    case forecastedRun
    case actualRun
    case runPctDeviation
    case escapementGoalMinimum
    case escapementGoalMaximum
    case actualEscapement
    case projectedHarvest
    case actualHarvest
    case harvestPctDeviation
    case totalEscapementNaknek
    case totalEscapementKvichak
    case totalEscapementAlagnak
    case totalEscapementEgegik
    case totalEscapementUgashik
    case totalEscapementWood
    case totalEscapementIgushik
    case totalEscapementNushagak
    case totalEscapementTogiak

    // Run Timing
    case cumulativePassagePct
    case cumulativePassage
    case dailyPassage
    case smoothedDailyPassage
    case peakTimingDeviationFromMedian

    // Raw Inputs / Diagnostics
    case driftDeliveries
    case driftAllocationPct
    case setAllocationPct
    case driftShareFraction

    nonisolated var id: String { rawValue }

    nonisolated private static let pressureMetrics: Set<DeepResearchTableMetric> = [
        .driftBoats,
        .driftPermits,
        .cumulativeDriftHours,
        .cumulativeSetHours,
        .dailyDriftHours,
        .dailySetHours,
        .cumulativeBoatHours,
        .totalDriftHours,
        .totalSetHours,
        .maxDriftBoats,
        .maxDriftPermits,
        .averageDriftBoats,
        .averageDriftPermits
    ]

    nonisolated private static let efficiencyMetrics: Set<DeepResearchTableMetric> = [
        .sockeyePerBoatCumulative,
        .sockeyePerBoatDaily,
        .sockeyePerBoatDailyTopDistrict,
        .topDistrictTenYearMeanDaily,
        .sockeyePerBoatHourly,
        .totalSockeyePerBoat,
        .averageSockeyePerBoatPerDay,
        .averageSockeyePerBoatPerHour
    ]

    nonisolated private static let outcomeMetrics: Set<DeepResearchTableMetric> = [
        .cumulativeHarvest,
        .dailyHarvest,
        .cumulativeEscapement,
        .dailyEscapement,
        .totalHarvest,
        .totalEscapement,
        .totalRun,
        .totalSockeyeDrift,
        .totalSockeyeSet,
        .totalChumPct,
        .meanSockeyeWeight,
        .forecastedRun,
        .actualRun,
        .runPctDeviation,
        .escapementGoalMinimum,
        .escapementGoalMaximum,
        .actualEscapement,
        .projectedHarvest,
        .actualHarvest,
        .harvestPctDeviation,
        .totalEscapementNaknek,
        .totalEscapementKvichak,
        .totalEscapementAlagnak,
        .totalEscapementEgegik,
        .totalEscapementUgashik,
        .totalEscapementWood,
        .totalEscapementIgushik,
        .totalEscapementNushagak,
        .totalEscapementTogiak
    ]

    nonisolated private static let runTimingMetrics: Set<DeepResearchTableMetric> = [
        .cumulativePassagePct,
        .cumulativePassage,
        .dailyPassage,
        .smoothedDailyPassage,
        .peakTimingDeviationFromMedian
    ]

    private static let rawInputMetrics: Set<DeepResearchTableMetric> = [
        .driftDeliveries,
        .driftAllocationPct,
        .setAllocationPct,
        .driftShareFraction
    ]

    nonisolated private static let seasonAggregateMetrics: Set<DeepResearchTableMetric> = [
        .totalDriftHours,
        .totalSetHours,
        .maxDriftBoats,
        .maxDriftPermits,
        .averageDriftBoats,
        .averageDriftPermits,
        .totalSockeyePerBoat,
        .averageSockeyePerBoatPerDay,
        .averageSockeyePerBoatPerHour,
        .totalHarvest,
        .totalEscapement,
        .totalRun,
        .totalSockeyeDrift,
        .totalSockeyeSet,
        .totalChumPct,
        .meanSockeyeWeight,
        .forecastedRun,
        .actualRun,
        .runPctDeviation,
        .escapementGoalMinimum,
        .escapementGoalMaximum,
        .actualEscapement,
        .projectedHarvest,
        .actualHarvest,
        .harvestPctDeviation,
        .totalEscapementNaknek,
        .totalEscapementKvichak,
        .totalEscapementAlagnak,
        .totalEscapementEgegik,
        .totalEscapementUgashik,
        .totalEscapementWood,
        .totalEscapementIgushik,
        .totalEscapementNushagak,
        .totalEscapementTogiak,
        .peakTimingDeviationFromMedian
    ]

    nonisolated var group: DeepResearchTableMetricGroup {
        if Self.pressureMetrics.contains(self) { return .pressure }
        if Self.efficiencyMetrics.contains(self) { return .efficiency }
        if Self.outcomeMetrics.contains(self) { return .outcome }
        if Self.runTimingMetrics.contains(self) { return .runTiming }
        return .rawInputs
    }

    nonisolated var isSeasonAggregate: Bool {
        Self.seasonAggregateMetrics.contains(self)
    }

    nonisolated var buttonTitle: String {
        switch self {
        case .driftBoats: return "Drift Boats**"
        case .driftPermits: return "Drift Permits*"
        case .cumulativeDriftHours: return "Drift-hrs\nCumulative"
        case .cumulativeSetHours: return "Set-hrs\nCumulative"
        case .dailyDriftHours: return "Drift-hrs\nDaily"
        case .dailySetHours: return "Set-hrs\nDaily"
        case .cumulativeBoatHours: return "Boat-hrs\nCumulative"
        case .totalDriftHours: return "Total Drift\nHours*"
        case .totalSetHours: return "Total Set\nHours*"
        case .maxDriftBoats: return "Max Drift\nBoats"
        case .maxDriftPermits: return "Max Drift\nPermits"
        case .averageDriftBoats: return "Average Drift\nBoats*"
        case .averageDriftPermits: return "Average Drift\nPermits*"

        case .sockeyePerBoatCumulative: return "Sockeye/Boat\nCumulative"
        case .sockeyePerBoatDaily: return "Sockeye/Boat\nDaily"
        case .sockeyePerBoatDailyTopDistrict: return "Sockeye/Boat\nDaily Top\nDistrict"
        case .topDistrictTenYearMeanDaily: return "Top District\n10-year Mean\nDaily"
        case .sockeyePerBoatHourly: return "Sockeye/Boat\nHourly"
        case .totalSockeyePerBoat: return "Total Sockeye/\nBoat**"
        case .averageSockeyePerBoatPerDay: return "Average Sockeye/\nBoat per Day*"
        case .averageSockeyePerBoatPerHour: return "Average Sockeye/\nBoat per Hour*"

        case .cumulativeHarvest: return "Harvest\nCumulative"
        case .dailyHarvest: return "Harvest\nDaily"
        case .cumulativeEscapement: return "Escapement\nCumulative"
        case .dailyEscapement: return "Escapement\nDaily"
        case .totalHarvest: return "Total Harvest"
        case .totalEscapement: return "Total Escapement"
        case .totalRun: return "Total Run"
        case .totalSockeyeDrift: return "Total Sockeye/\nDrift Gear"
        case .totalSockeyeSet: return "Total Sockeye/\nSet Gear"
        case .totalChumPct: return "Total Chum %"
        case .meanSockeyeWeight: return "Mean Sockeye\nWeight"
        case .forecastedRun: return "Forecasted\nRun"
        case .actualRun: return "Actual\nRun"
        case .runPctDeviation: return "Run %\nDeviation"
        case .escapementGoalMinimum: return "Escapement Goal\nMinimum"
        case .escapementGoalMaximum: return "Escapement Goal\nMaximum"
        case .actualEscapement: return "Actual\nEscapement"
        case .projectedHarvest: return "Projected\nHarvest"
        case .actualHarvest: return "Actual\nHarvest"
        case .harvestPctDeviation: return "Harvest %\nDeviation"
        case .totalEscapementNaknek: return "Naknek Esc\nTotal"
        case .totalEscapementKvichak: return "Kvichak Esc\nTotal"
        case .totalEscapementAlagnak: return "Alagnak Esc\nTotal"
        case .totalEscapementEgegik: return "Egegik Esc\nTotal"
        case .totalEscapementUgashik: return "Ugashik Esc\nTotal"
        case .totalEscapementWood: return "Wood Esc\nTotal"
        case .totalEscapementIgushik: return "Igushik Esc\nTotal"
        case .totalEscapementNushagak: return "Nushagak Esc\nTotal"
        case .totalEscapementTogiak: return "Togiak Esc\nTotal"

        case .cumulativePassagePct: return "Cumulative %\nPassage"
        case .cumulativePassage: return "Passage\nCumulative"
        case .dailyPassage: return "Passage\nDaily"
        case .smoothedDailyPassage: return "Smoothed\nPassage (3-day)"
        case .peakTimingDeviationFromMedian: return "Peak Timing\nDeviation from\n10Y Median"

        case .driftDeliveries: return "Drift\nDeliveries"
        case .driftAllocationPct: return "Drift\nAllocation %"
        case .setAllocationPct: return "Set\nAllocation %"
        case .driftShareFraction: return "Drift Share"
        }
    }

    nonisolated var columnTitle: String {
        switch self {
        case .driftBoats: return "Drift Boats**"
        case .driftPermits: return "Drift Permits"
        case .cumulativeDriftHours: return "Drift-hrs Cumulative"
        case .cumulativeSetHours: return "Set-hrs Cumulative"
        case .dailyDriftHours: return "Drift-hrs Daily"
        case .dailySetHours: return "Set-hrs Daily"
        case .cumulativeBoatHours: return "Boat-hrs Cumulative"
        case .totalDriftHours: return "Total Drift Hours*"
        case .totalSetHours: return "Total Set Hours*"
        case .maxDriftBoats: return "Max Drift Boats"
        case .maxDriftPermits: return "Max Drift Permits"
        case .averageDriftBoats: return "Average Drift Boats*"
        case .averageDriftPermits: return "Average Drift Permits*"

        case .sockeyePerBoatCumulative: return "Sockeye/Boat Cumulative"
        case .sockeyePerBoatDaily: return "Sockeye/Boat Daily*"
        case .sockeyePerBoatDailyTopDistrict: return "Sockeye/Boat Daily Top District"
        case .topDistrictTenYearMeanDaily: return "Top District 10-year Mean Daily"
        case .sockeyePerBoatHourly: return "Sockeye/Boat Hourly*"
        case .totalSockeyePerBoat: return "Total Sockeye/Boat**"
        case .averageSockeyePerBoatPerDay: return "Average Sockeye/Boat per Day*"
        case .averageSockeyePerBoatPerHour: return "Average Sockeye/Boat per Hour*"

        case .cumulativeHarvest: return "Cumulative Harvest"
        case .dailyHarvest: return "Daily Harvest"
        case .cumulativeEscapement: return "Cumulative Escapement"
        case .dailyEscapement: return "Daily Escapement"
        case .totalHarvest: return "Total Harvest"
        case .totalEscapement: return "Total Escapement"
        case .totalRun: return "Total Run"
        case .totalSockeyeDrift: return "Total Sockeye/Drift"
        case .totalSockeyeSet: return "Total Sockeye/Set"
        case .totalChumPct: return "Total Chum %"
        case .meanSockeyeWeight: return "Mean Sockeye Weight"
        case .forecastedRun: return "Forecasted Run"
        case .actualRun: return "Actual Run"
        case .runPctDeviation: return "Run % Deviation"
        case .escapementGoalMinimum: return "Escapement Goal Minimum"
        case .escapementGoalMaximum: return "Escapement Goal Maximum"
        case .actualEscapement: return "Actual Escapement"
        case .projectedHarvest: return "Projected Harvest"
        case .actualHarvest: return "Actual Harvest"
        case .harvestPctDeviation: return "Harvest % Deviation"
        case .totalEscapementNaknek: return "Total Escapement - Naknek"
        case .totalEscapementKvichak: return "Total Escapement - Kvichak"
        case .totalEscapementAlagnak: return "Total Escapement - Alagnak"
        case .totalEscapementEgegik: return "Total Escapement - Egegik"
        case .totalEscapementUgashik: return "Total Escapement - Ugashik"
        case .totalEscapementWood: return "Total Escapement - Wood"
        case .totalEscapementIgushik: return "Total Escapement - Igushik"
        case .totalEscapementNushagak: return "Total Escapement - Nushagak"
        case .totalEscapementTogiak: return "Total Escapement - Togiak"

        case .cumulativePassagePct: return "Cumulative % Run"
        case .cumulativePassage: return "Cumulative Passage"
        case .dailyPassage: return "Daily Passage"
        case .smoothedDailyPassage: return "Smoothed Daily Passage"
        case .peakTimingDeviationFromMedian: return "Peak Timing Deviation from 10Y Median"

        case .driftDeliveries: return "Drift Deliveries"
        case .driftAllocationPct: return "Drift Allocation %"
        case .setAllocationPct: return "Set Allocation %"
        case .driftShareFraction: return "Drift Share Fraction"
        }
    }

    nonisolated var sortOrder: Int {
        switch self {
        case .driftBoats: return 10
        case .driftPermits: return 20
        case .cumulativeDriftHours: return 30
        case .cumulativeSetHours: return 40
        case .dailyDriftHours: return 50
        case .dailySetHours: return 60
        case .cumulativeBoatHours: return 70
        case .totalDriftHours: return 80
        case .totalSetHours: return 90
        case .maxDriftBoats: return 100
        case .maxDriftPermits: return 110
        case .averageDriftBoats: return 120
        case .averageDriftPermits: return 130

        case .sockeyePerBoatCumulative: return 140
        case .sockeyePerBoatDaily: return 150
        case .sockeyePerBoatDailyTopDistrict: return 155
        case .topDistrictTenYearMeanDaily: return 156
        case .sockeyePerBoatHourly: return 160
        case .totalSockeyePerBoat: return 170
        case .averageSockeyePerBoatPerDay: return 180
        case .averageSockeyePerBoatPerHour: return 190

        case .cumulativeHarvest: return 200
        case .dailyHarvest: return 210
        case .cumulativeEscapement: return 220
        case .dailyEscapement: return 230
        case .totalHarvest: return 240
        case .totalEscapement: return 250
        case .totalRun: return 260
        case .totalSockeyeDrift: return 270
        case .totalSockeyeSet: return 280
        case .totalChumPct: return 290
        case .meanSockeyeWeight: return 300
        case .forecastedRun: return 310
        case .actualRun: return 320
        case .runPctDeviation: return 330
        case .escapementGoalMinimum: return 340
        case .escapementGoalMaximum: return 350
        case .actualEscapement: return 360
        case .projectedHarvest: return 370
        case .actualHarvest: return 380
        case .harvestPctDeviation: return 390
        case .totalEscapementNaknek: return 400
        case .totalEscapementKvichak: return 410
        case .totalEscapementAlagnak: return 420
        case .totalEscapementEgegik: return 430
        case .totalEscapementUgashik: return 440
        case .totalEscapementWood: return 450
        case .totalEscapementIgushik: return 460
        case .totalEscapementNushagak: return 470
        case .totalEscapementTogiak: return 480

        case .cumulativePassagePct: return 490
        case .cumulativePassage: return 500
        case .dailyPassage: return 510
        case .smoothedDailyPassage: return 520
        case .peakTimingDeviationFromMedian: return 530

        case .driftDeliveries: return 540
        case .driftAllocationPct: return 550
        case .setAllocationPct: return 560
        case .driftShareFraction: return 570
        }
    }
}

// MARK: - Table View Models

struct TableRiverOption: Hashable, Identifiable, Sendable {
    let key: String
    let label: String

    nonisolated var id: String { key }
}

struct DeepResearchTablesPreview: Equatable, Sendable {
    let districtCount: Int
    let estimatedRowCount: Int
    let columnTitles: [String]
    let dateRangeLabel: String
}

struct DeepResearchTableColumn: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
}

struct DeepResearchTableRow: Identifiable, Hashable, Sendable {
    let id: String
    let date: String
    let district: District
    let districtLabel: String
    let values: [String: String]
}

struct TopDistrictTenYearMeanDailySample: Hashable, Sendable {
    let district: District
    let year: Int
    let monthDay: String
    let sockeyePerBoatDaily: Double?
}

struct TopDistrictTenYearMeanDailyResult: Equatable, Sendable {
    let district: District
    let meanSockeyePerBoatDaily: Double
    let yearsUsed: Int
}

enum TopDistrictTenYearMeanDailyCalculator {
    nonisolated static func groupedSamples(
        _ samples: [TopDistrictTenYearMeanDailySample]
    ) -> [String: [TopDistrictTenYearMeanDailySample]] {
        samples.reduce(into: [:]) { grouped, sample in
            grouped[key(district: sample.district, monthDay: sample.monthDay), default: []].append(sample)
        }
    }

    nonisolated static func topDistrict(
        for dateString: String,
        districts: [District],
        samplesByDistrictMonthDay: [String: [TopDistrictTenYearMeanDailySample]]
    ) -> TopDistrictTenYearMeanDailyResult? {
        guard let outputYear = year(fromISODate: dateString),
              let outputMonthDay = monthDay(fromISODate: dateString) else {
            return nil
        }

        var best: TopDistrictTenYearMeanDailyResult?

        for district in districts {
            let sampleKey = key(district: district, monthDay: outputMonthDay)
            let valueByYear = (samplesByDistrictMonthDay[sampleKey] ?? [])
                .reduce(into: [Int: Double]()) { values, sample in
                    guard sample.year < outputYear,
                          let value = sample.sockeyePerBoatDaily,
                          value.isFinite else {
                        return
                    }
                    values[sample.year] = value
                }

            let values = valueByYear.keys
                .sorted(by: >)
                .prefix(10)
                .compactMap { valueByYear[$0] }

            guard !values.isEmpty else { continue }

            let mean = values.reduce(0, +) / Double(values.count)
            if best == nil || mean > (best?.meanSockeyePerBoatDaily ?? 0) {
                best = TopDistrictTenYearMeanDailyResult(
                    district: district,
                    meanSockeyePerBoatDaily: mean,
                    yearsUsed: values.count
                )
            }
        }

        return best
    }

    nonisolated static func key(district: District, monthDay: String) -> String {
        "\(district.key)|\(monthDay)"
    }

    nonisolated private static func year(fromISODate dateString: String) -> Int? {
        guard dateString.count >= 4 else { return nil }
        return Int(dateString.prefix(4))
    }

    nonisolated private static func monthDay(fromISODate dateString: String) -> String? {
        let parts = dateString.split(separator: "-")
        guard parts.count == 3 else { return nil }
        return "\(parts[1])-\(parts[2])"
    }
}

struct DeepResearchTablesResult: Sendable {
    let preview: DeepResearchTablesPreview
    let columns: [DeepResearchTableColumn]
    let rows: [DeepResearchTableRow]
}

struct DeepResearchTablesFilters: Equatable, Sendable {
    var startDate: Date
    var endDate: Date
    var selectedDistricts: Set<District>
    var selectedMetrics: Set<DeepResearchTableMetric>
    var includeRiverEscapementBreakdown: Bool
    var includeRiverDailyEscColumns: Bool
    var includeRiverCumulativeEscColumns: Bool
    var selectedRiversByDistrict: [District: Set<String>]
    var outputMode: DeepResearchTablesOutputMode

    nonisolated static func `default`() -> DeepResearchTablesFilters {
        let cal = Calendar(identifier: .gregorian)
        let start = cal.date(from: DateComponents(year: 2015, month: 6, day: 12)) ?? Date()
        let end = cal.date(from: DateComponents(year: 2025, month: 8, day: 20)) ?? Date()

        return DeepResearchTablesFilters(
            startDate: start,
            endDate: end,
            selectedDistricts: [],
            selectedMetrics: [],
            includeRiverEscapementBreakdown: false,
            includeRiverDailyEscColumns: true,
            includeRiverCumulativeEscColumns: false,
            selectedRiversByDistrict: [:],
            outputMode: .display
        )
    }
}

// MARK: - Daily Query Rows

private struct TableExporterRow: FetchableRecord, Decodable, Sendable {
    let date: String
    let districtKey: String
    let driftOpenHours: Double?
    let driftDeliveries: Int?
    let driftPct: Double?
    let setPct: Double?
    let driftShareFraction: Double?
    let driftSockeyeAllocAdj: Double?
    let driftBoats: Int?
    let boatsSource: String?
    let sockeyePerBoatRaw: Double?
    let sockeyePerBoatAllocAdj: Double?
}

private struct TableHistoricalSockeyePerBoatDailyRow: FetchableRecord, Decodable, Sendable {
    let date: String
    let districtKey: String
    let sockeyePerBoatAllocAdj: Double?
}

private struct TableOpsRow: FetchableRecord, Decodable, Sendable {
    let date: String
    let districtKey: String
    let driftOpenHours: Double?
    let setOpenHours: Double?
    let driftDeliveries: Int?
    let setDeliveries: Int?
    let sockeye: Int?
    let chum: Int?
    let total: Int?
}

private struct TableRegRow: FetchableRecord, Decodable, Sendable {
    let date: String
    let districtKey: String
    let driftPermits: Int?
    let dualPermits: Int?
    let driftBoats: Int?
}

private struct TableRunTimingRow: FetchableRecord, Decodable, Sendable {
    let date: String
    let districtKey: String
    let totalPassage: Double?
    let smoothedDailyPassage: Double?
    let cumulativePassage: Double?
    let cumulativePassagePct: Double?
}

private struct TableRiverEscRow: FetchableRecord, Decodable, Sendable {
    let date: String
    let riverKey: String
    let dailyEscapement: Double?
    let isOperational: Int?
}

// MARK: - Season Summary Rows

private struct TableSeasonMetricsRow: FetchableRecord, Decodable, Sendable {
    let year: Int
    let districtKey: String
    let totalDriftHours: Double?
    let totalSetHours: Double?
    let maxDriftBoats: Double?
    let maxDriftPermits: Double?
    let averageDriftBoats: Double?
    let averageDriftPermits: Double?
    let totalSockeyePerBoat: Double?
    let averageSockeyePerBoatPerDay: Double?
    let averageSockeyePerBoatPerHour: Double?
    let totalHarvest: Double?
    let totalEscapement: Double?
    let totalRun: Double?
    let totalSockeyeDrift: Double?
    let totalSockeyeSet: Double?
    let totalChumPct: Double?
    let meanSockeyeWeight: Double?
    let forecastedRun: Double?
    let actualRun: Double?
    let runPctDeviation: Double?
    let escapementGoalMinimum: Double?
    let escapementGoalMaximum: Double?
    let actualEscapement: Double?
    let projectedHarvest: Double?
    let actualHarvest: Double?
    let harvestPctDeviation: Double?
    let totalEscapementNaknek: Double?
    let totalEscapementKvichak: Double?
    let totalEscapementAlagnak: Double?
    let totalEscapementEgegik: Double?
    let totalEscapementUgashik: Double?
    let totalEscapementWood: Double?
    let totalEscapementIgushik: Double?
    let totalEscapementNushagak: Double?
    let totalEscapementTogiak: Double?
    let peakTimingDeviationFromMedian: Int?
}
final class DeepResearchTablesVM: ObservableObject {
    @Published var filters: DeepResearchTablesFilters = .default()
    @Published var columns: [DeepResearchTableColumn] = []
    @Published var rows: [DeepResearchTableRow] = []
    @Published var preview: DeepResearchTablesPreview?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastExportURL: URL?

    @MainActor
    func generate(appDB: AppDatabase?) async {
        guard let appDB else {
            errorMessage = "Offline database unavailable."
            rows = []
            columns = []
            preview = nil
            return
        }

        guard canGenerate else {
            errorMessage = "Select at least one district, one metric, and a valid date range."
            rows = []
            columns = []
            preview = nil
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let built = try await DeepResearchTablesBuilder.buildResult(appDB: appDB, filters: filters)
            columns = built.columns
            rows = built.rows
            preview = built.preview
        } catch {
            DeepResearchBetaError.debugLog(error, context: "Deep Research Tables generate with filters \(filters)")
            errorMessage = DeepResearchBetaError.userFacingMessage(for: error, feature: "Deep Research Tables")
            rows = []
            columns = []
            preview = nil
        }
    }

    func exportCSV(appDB: AppDatabase?) async throws -> URL? {
        guard let appDB else { return nil }
        guard canGenerate else { return nil }

        let fileName = "deep_research_table_\(Self.exportTimestampFormatter.string(from: Date())).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        let exportFilters = filters

        try await DeepResearchTablesBuilder.exportCSV(appDB: appDB, filters: exportFilters, to: url)
        await MainActor.run {
            lastExportURL = url
        }
        return url
    }

    var canGenerate: Bool {
        !filters.selectedDistricts.isEmpty &&
        !filters.selectedMetrics.isEmpty &&
        filters.startDate <= filters.endDate
    }

    func districtLabel(_ district: District) -> String {
        district == .naknekKvichak ? "Nak-Kvi" : district.rawValue
    }

    func riverOptions(for district: District) -> [TableRiverOption] {
        switch district {
        case .naknekKvichak:
            return [
                .init(key: "naknek", label: "Naknek"),
                .init(key: "kvichak", label: "Kvichak"),
                .init(key: "alagnak", label: "Alagnak")
            ]
        case .egegik:
            return [.init(key: "egegik", label: "Egegik")]
        case .ugashik:
            return [.init(key: "ugashik", label: "Ugashik")]
        case .nushagak:
            return [
                .init(key: "wood", label: "Wood"),
                .init(key: "igushik", label: "Igushik"),
                .init(key: "nushagak", label: "Nushagak")
            ]
        case .togiak:
            return [.init(key: "togiak", label: "Togiak")]
        }
    }


    private static let exportTimestampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyyMMdd_HHmmss"
        return df
    }()
}

private enum DeepResearchTablesBuilder {
    nonisolated private static let orderedDistricts: [District] = [
        .naknekKvichak,
        .egegik,
        .ugashik,
        .nushagak,
        .togiak
    ]

    // MARK: - Entry Point
    nonisolated static func exportCSV(appDB: AppDatabase, filters: DeepResearchTablesFilters, to url: URL) async throws {
        let districtList = orderedDistricts.filter { filters.selectedDistricts.contains($0) }
        let districtKeys = districtList.map(\.key)
        let startYear = calendarYear(filters.startDate)
        let endYear = calendarYear(filters.endDate)
        let seasonRequest = isSeasonTotalsRequest(filters: filters)

        let columns: [DeepResearchTableColumn] = seasonRequest
            ? buildSeasonColumns(filters: filters, districts: districtList)
            : buildDailyColumns(filters: filters, districts: districtList)

        try Data().write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        try writeCSVLine(columns.map(\.title), to: handle)

        if seasonRequest {
            let seasonRows = try await appDB.dbQueue.read { db in
                try loadSeasonMetricRows(db: db, districtKeys: districtKeys, startYear: startYear, endYear: endYear)
            }
            try writeSeasonCSVRows(
                to: handle,
                columns: columns,
                filters: filters,
                districts: districtList,
                startYear: startYear,
                endYear: endYear,
                seasonRows: seasonRows
            )
            return
        }

        let startString = isoDateString(filters.startDate)
        let endString = isoDateString(filters.endDate)
        let scaffoldDates = seasonalDateRangeStrings(from: filters.startDate, to: filters.endDate)

        let raw = try await appDB.dbQueue.read { db in
            let exporterRows = try loadExporterRows(db: db, districtKeys: districtKeys, start: startString, end: endString)
            let opsRows = try loadOpsRows(db: db, districtKeys: districtKeys, start: startString, end: endString)
            let regRows = try loadRegRows(db: db, districtKeys: districtKeys, start: startString, end: endString)
            let runTimingRows = try loadRunTimingRows(db: db, districtKeys: districtKeys, start: startString, end: endString)
            let historicalSockeyePerBoatDailySamples = try loadHistoricalSockeyePerBoatDailySamples(
                db: db,
                districtKeys: districtKeys,
                beforeYear: endYear,
                isNeeded: needsTopDistrictTenYearMeanDaily(filters: filters)
            )

            let riverKeys = selectedRiverKeys(filters: filters, districts: districtList)
            let riverEscRows = try loadRiverEscRows(db: db, riverKeys: riverKeys, start: startString, end: endString)

            return RawTablesBundle(
                exporterRows: exporterRows,
                opsRows: opsRows,
                regRows: regRows,
                runTimingRows: runTimingRows,
                riverEscRows: riverEscRows,
                historicalSockeyePerBoatDailySamples: historicalSockeyePerBoatDailySamples
            )
        }

        try writeDailyCSVRows(
            to: handle,
            columns: columns,
            filters: filters,
            districts: districtList,
            dates: scaffoldDates,
            raw: raw
        )
    }

    nonisolated static func buildResult(appDB: AppDatabase, filters: DeepResearchTablesFilters) async throws -> DeepResearchTablesResult {
        let districtList = orderedDistricts.filter { filters.selectedDistricts.contains($0) }
        let districtKeys = districtList.map(\.key)
        let startYear = calendarYear(filters.startDate)
        let endYear = calendarYear(filters.endDate)

        if isSeasonTotalsRequest(filters: filters) {
            let seasonRows = try await appDB.dbQueue.read { db in
                try loadSeasonMetricRows(db: db, districtKeys: districtKeys, startYear: startYear, endYear: endYear)
            }

            let columns = buildSeasonColumns(filters: filters, districts: districtList)
            let rows = buildSeasonRows(
                filters: filters,
                districts: districtList,
                startYear: startYear,
                endYear: endYear,
                seasonRows: seasonRows
            )

            return makeResult(
                filters: filters,
                districtList: districtList,
                columns: columns,
                rows: rows
            )
        }

        let startString = isoDateString(filters.startDate)
        let endString = isoDateString(filters.endDate)
        let scaffoldDates = seasonalDateRangeStrings(from: filters.startDate, to: filters.endDate)

        let raw = try await appDB.dbQueue.read { db in
            let exporterRows = try loadExporterRows(db: db, districtKeys: districtKeys, start: startString, end: endString)
            let opsRows = try loadOpsRows(db: db, districtKeys: districtKeys, start: startString, end: endString)
            let regRows = try loadRegRows(db: db, districtKeys: districtKeys, start: startString, end: endString)
            let runTimingRows = try loadRunTimingRows(db: db, districtKeys: districtKeys, start: startString, end: endString)
            let historicalSockeyePerBoatDailySamples = try loadHistoricalSockeyePerBoatDailySamples(
                db: db,
                districtKeys: districtKeys,
                beforeYear: endYear,
                isNeeded: needsTopDistrictTenYearMeanDaily(filters: filters)
            )

            let riverKeys = selectedRiverKeys(filters: filters, districts: districtList)
            let riverEscRows = try loadRiverEscRows(db: db, riverKeys: riverKeys, start: startString, end: endString)

            return RawTablesBundle(
                exporterRows: exporterRows,
                opsRows: opsRows,
                regRows: regRows,
                runTimingRows: runTimingRows,
                riverEscRows: riverEscRows,
                historicalSockeyePerBoatDailySamples: historicalSockeyePerBoatDailySamples
            )
        }

        let columns = buildDailyColumns(filters: filters, districts: districtList)
        let rows = buildDailyRows(
            filters: filters,
            districts: districtList,
            dates: scaffoldDates,
            raw: raw
        )

        return makeResult(
            filters: filters,
            districtList: districtList,
            columns: columns,
            rows: rows
        )
    }

    // MARK: - Result Builders

    nonisolated private static func makeResult(
        filters: DeepResearchTablesFilters,
        districtList: [District],
        columns: [DeepResearchTableColumn],
        rows: [DeepResearchTableRow]
    ) -> DeepResearchTablesResult {
        let preview = DeepResearchTablesPreview(
            districtCount: districtList.count,
            estimatedRowCount: rows.count,
            columnTitles: columns.map(\.title),
            dateRangeLabel: "\(displayDateString(filters.startDate)) – \(displayDateString(filters.endDate))"
        )

        return DeepResearchTablesResult(
            preview: preview,
            columns: columns,
            rows: rows
        )
    }

    nonisolated private static func isSeasonTotalsRequest(filters: DeepResearchTablesFilters) -> Bool {
        !filters.selectedMetrics.isEmpty && filters.selectedMetrics.allSatisfy { $0.isSeasonAggregate }
    }

    nonisolated private static func sortedMetrics(_ filters: DeepResearchTablesFilters) -> [DeepResearchTableMetric] {
        filters.selectedMetrics.sorted { $0.sortOrder < $1.sortOrder }
    }

    nonisolated private static func districtDisplayLabel(_ district: District) -> String {
        district == .naknekKvichak ? "Nak-Kvi" : district.rawValue
    }

    nonisolated private static func includeDailyRiverEscapementColumns(filters: DeepResearchTablesFilters) -> Bool {
        filters.includeRiverEscapementBreakdown &&
        (filters.selectedMetrics.contains(.dailyEscapement) || filters.selectedMetrics.contains(.cumulativeEscapement))
    }

    nonisolated private static func includeSeasonRiverEscapementColumns(filters: DeepResearchTablesFilters) -> Bool {
        filters.includeRiverEscapementBreakdown && filters.selectedMetrics.contains(.totalEscapement)
    }

    nonisolated private static func needsTopDistrictTenYearMeanDaily(filters: DeepResearchTablesFilters) -> Bool {
        filters.selectedMetrics.contains(.topDistrictTenYearMeanDaily)
    }

    nonisolated private static func selectedRivers(for district: District, filters: DeepResearchTablesFilters) -> [TableRiverOption] {
        let selectedRiverKeys = filters.selectedRiversByDistrict[district] ?? Set(riverOptionsStatic(for: district).map(\.key))
        return riverOptionsStatic(for: district).filter { selectedRiverKeys.contains($0.key) }
    }

    nonisolated private static func buildDailyColumns(filters: DeepResearchTablesFilters, districts: [District]) -> [DeepResearchTableColumn] {
        var columns: [DeepResearchTableColumn] = [
            .init(id: "date", title: "Date"),
            .init(id: "district", title: "District")
        ]

        columns.append(contentsOf: sortedMetrics(filters).map { .init(id: $0.rawValue, title: $0.columnTitle) })

        if includeDailyRiverEscapementColumns(filters: filters) {
            for district in districts {
                for river in selectedRivers(for: district, filters: filters) {
                    if filters.includeRiverDailyEscColumns {
                        columns.append(.init(id: "river_daily_\(district.key)_\(river.key)", title: "Esc - \(river.label)"))
                    }
                    if filters.includeRiverCumulativeEscColumns {
                        columns.append(.init(id: "river_cum_\(district.key)_\(river.key)", title: "Cum Esc - \(river.label)"))
                    }
                }
            }
        }

        return columns
    }

    nonisolated private static func buildSeasonColumns(filters: DeepResearchTablesFilters, districts: [District]) -> [DeepResearchTableColumn] {
        var columns: [DeepResearchTableColumn] = [
            .init(id: "year", title: "Year"),
            .init(id: "district", title: "District")
        ]

        columns.append(contentsOf: sortedMetrics(filters).map { .init(id: $0.rawValue, title: $0.columnTitle) })

        if includeSeasonRiverEscapementColumns(filters: filters) {
            for district in districts {
                for river in selectedRivers(for: district, filters: filters) {
                    columns.append(
                        .init(
                            id: seasonRiverColumnID(districtKey: district.key, riverKey: river.key),
                            title: "Total Esc - \(river.label)"
                        )
                    )
                }
            }
        }

        return columns
    }

    nonisolated private static func dailyDriftBoats(exporter: TableExporterRow?, reg: TableRegRow?) -> Double {
        if let observed = reg?.driftBoats {
            return max(0, Double(observed))
        }

        let modeledBoatSources: Set<String> = [
            "registration_estimator",
            "fallback_deliveries_per_boat_0612_0716",
            "estimated_deliveries_per_boat_0710_0716"
        ]

        if let source = exporter?.boatsSource,
           modeledBoatSources.contains(source),
           let estimated = exporter?.driftBoats {
            return max(0, Double(estimated))
        }

        return 0
    }

    private struct DailyDistrictMetricSnapshot: Sendable {
        let dateString: String
        let district: District
        let districtLabel: String
        let sockeyePerBoatDaily: Double?
        let values: [String: String]

        nonisolated init(
            dateString: String,
            district: District,
            districtLabel: String,
            sockeyePerBoatDaily: Double?,
            values: [String: String]
        ) {
            self.dateString = dateString
            self.district = district
            self.districtLabel = districtLabel
            self.sockeyePerBoatDaily = sockeyePerBoatDaily
            self.values = values
        }
    }

    private struct DailyDistrictMetricAccumulator {
        var cumulativeDriftHours = 0.0
        var cumulativeSetHours = 0.0
        var cumulativeBoatHours = 0.0
        var cumulativeHarvest = 0.0
        var cumulativeEscapement = 0.0
        var cumulativeSockeyePerBoat: Double?
        var currentYear: Int?
        var riverCumulative: [String: Double] = [:]

        nonisolated init() {}

        nonisolated mutating func resetIfNeeded(forYear year: Int?) {
            guard currentYear != year else { return }
            currentYear = year
            cumulativeDriftHours = 0
            cumulativeSetHours = 0
            cumulativeBoatHours = 0
            cumulativeHarvest = 0
            cumulativeEscapement = 0
            cumulativeSockeyePerBoat = 0
            riverCumulative = [:]
        }
    }

    nonisolated private static func buildDailySnapshots(
        filters: DeepResearchTablesFilters,
        districts: [District],
        dates: [String],
        raw: RawTablesBundle
    ) -> [DailyDistrictMetricSnapshot] {
        let includeRiverColumns = includeDailyRiverEscapementColumns(filters: filters)
        var snapshots: [DailyDistrictMetricSnapshot] = []
        snapshots.reserveCapacity(max(1, districts.count * dates.count))

        for district in districts {
            let districtKey = district.key
            let rivers = selectedRivers(for: district, filters: filters)
            var accumulator = DailyDistrictMetricAccumulator()

            for dateString in dates {
                snapshots.append(
                    dailySnapshot(
                        dateString: dateString,
                        district: district,
                        districtKey: districtKey,
                        rivers: rivers,
                        includeRiverColumns: includeRiverColumns,
                        raw: raw,
                        accumulator: &accumulator
                    )
                )
            }
        }

        return snapshots
    }

    nonisolated private static func dailySnapshot(
        dateString: String,
        district: District,
        districtKey: String,
        rivers: [TableRiverOption],
        includeRiverColumns: Bool,
        raw: RawTablesBundle,
        accumulator: inout DailyDistrictMetricAccumulator
    ) -> DailyDistrictMetricSnapshot {
        let key = districtDateKey(districtKey: districtKey, date: dateString)
        let exporter = raw.exporterRows[key]
        let ops = raw.opsRows[key]
        let reg = raw.regRows[key]
        let runTiming = raw.runTimingRows[key]

        accumulator.resetIfNeeded(forYear: year(fromISODate: dateString))

        let driftBoats = dailyDriftBoats(exporter: exporter, reg: reg)
        let driftPermits = Double((reg?.driftPermits ?? 0) + (reg?.dualPermits ?? 0))
        let driftHours = exporter?.driftOpenHours ?? ops?.driftOpenHours ?? 0
        let setHours = ops?.setOpenHours ?? 0
        let dailyHarvest = Double(ops?.sockeye ?? 0)
        let driftDeliveries = Double(exporter?.driftDeliveries ?? ops?.driftDeliveries ?? 0)
        let driftPct = normalizedPercent(exporter?.driftPct)
        let setPct = normalizedPercent(exporter?.setPct)
        let driftShare = exporter?.driftShareFraction ?? driftShareFraction(driftPct: driftPct, setPct: setPct)
        let driftSockeyeAllocAdj = exporter?.driftSockeyeAllocAdj ?? driftShare.map { dailyHarvest * $0 }
        let sockeyePerBoatDaily = exporter?.sockeyePerBoatAllocAdj
        let sockeyePerBoatHourly: Double? = {
            guard let driftSockeyeAllocAdj else { return nil }
            let denom = driftBoats * driftHours
            guard denom > 0 else { return nil }
            return driftSockeyeAllocAdj / denom
        }()

        let dailyEscapement = sumDistrictEscapement(raw.riverEscRows, district: district, date: dateString)
        let dailyPassage = runTiming?.totalPassage ?? 0
        let smoothedDailyPassage = runTiming?.smoothedDailyPassage ?? 0
        let cumulativePassage = runTiming?.cumulativePassage ?? 0
        let cumulativePassagePct = (runTiming?.cumulativePassagePct ?? 0) * 100.0

        accumulator.cumulativeDriftHours += driftHours
        accumulator.cumulativeSetHours += setHours
        accumulator.cumulativeBoatHours += max(0, driftBoats * driftHours)
        accumulator.cumulativeHarvest += dailyHarvest
        accumulator.cumulativeEscapement += dailyEscapement
        if let sockeyePerBoatDaily {
            accumulator.cumulativeSockeyePerBoat = (accumulator.cumulativeSockeyePerBoat ?? 0) + sockeyePerBoatDaily
        }
        let cumulativeSockeyePerBoatDisplay = sockeyePerBoatDaily == nil ? nil : accumulator.cumulativeSockeyePerBoat

        var values: [String: String] = [
            "date": shortDateString(dateString),
            "district": districtDisplayLabel(district),
            DeepResearchTableMetric.driftBoats.rawValue: formatNumber(driftBoats, decimals: 0),
            DeepResearchTableMetric.driftPermits.rawValue: formatNumber(driftPermits, decimals: 0),
            DeepResearchTableMetric.cumulativeDriftHours.rawValue: formatNumber(accumulator.cumulativeDriftHours, decimals: 1),
            DeepResearchTableMetric.cumulativeSetHours.rawValue: formatNumber(accumulator.cumulativeSetHours, decimals: 1),
            DeepResearchTableMetric.dailyDriftHours.rawValue: formatNumber(driftHours, decimals: 1),
            DeepResearchTableMetric.dailySetHours.rawValue: formatNumber(setHours, decimals: 1),
            DeepResearchTableMetric.cumulativeBoatHours.rawValue: formatNumber(accumulator.cumulativeBoatHours, decimals: 1),
            DeepResearchTableMetric.sockeyePerBoatCumulative.rawValue: formatNumber(cumulativeSockeyePerBoatDisplay, decimals: 0),
            DeepResearchTableMetric.sockeyePerBoatDaily.rawValue: formatNumber(sockeyePerBoatDaily, decimals: 0),
            DeepResearchTableMetric.sockeyePerBoatDailyTopDistrict.rawValue: formatNumber(sockeyePerBoatDaily, decimals: 0),
            DeepResearchTableMetric.sockeyePerBoatHourly.rawValue: formatNumber(sockeyePerBoatHourly, decimals: 0),
            DeepResearchTableMetric.cumulativeHarvest.rawValue: formatNumber(accumulator.cumulativeHarvest, decimals: 0),
            DeepResearchTableMetric.dailyHarvest.rawValue: formatNumber(dailyHarvest, decimals: 0),
            DeepResearchTableMetric.cumulativeEscapement.rawValue: formatNumber(accumulator.cumulativeEscapement, decimals: 0),
            DeepResearchTableMetric.dailyEscapement.rawValue: formatNumber(dailyEscapement, decimals: 0),
            DeepResearchTableMetric.cumulativePassagePct.rawValue: formatPercent(cumulativePassagePct / 100.0, decimals: 1),
            DeepResearchTableMetric.cumulativePassage.rawValue: formatNumber(cumulativePassage, decimals: 0),
            DeepResearchTableMetric.dailyPassage.rawValue: formatNumber(dailyPassage, decimals: 0),
            DeepResearchTableMetric.smoothedDailyPassage.rawValue: formatNumber(smoothedDailyPassage, decimals: 0),
            DeepResearchTableMetric.driftDeliveries.rawValue: formatNumber(driftDeliveries, decimals: 0),
            DeepResearchTableMetric.driftAllocationPct.rawValue: formatPercent(driftPct, decimals: 1),
            DeepResearchTableMetric.setAllocationPct.rawValue: formatPercent(setPct, decimals: 1),
            DeepResearchTableMetric.driftShareFraction.rawValue: formatPercent(driftShare, decimals: 1)
        ]

        if includeRiverColumns {
            for river in rivers {
                let riverKey = riverDateKey(riverKey: river.key, date: dateString)
                let riverDaily = raw.riverEscRows[riverKey]?.dailyEscapement ?? 0
                accumulator.riverCumulative[river.key, default: 0] += riverDaily

                values["river_daily_\(district.key)_\(river.key)"] = formatNumber(riverDaily, decimals: 0)
                values["river_cum_\(district.key)_\(river.key)"] = formatNumber(accumulator.riverCumulative[river.key] ?? 0, decimals: 0)
            }
        }

        return DailyDistrictMetricSnapshot(
            dateString: dateString,
            district: district,
            districtLabel: districtDisplayLabel(district),
            sockeyePerBoatDaily: sockeyePerBoatDaily,
            values: values
        )
    }

    nonisolated private static func topSockeyePerBoatDailySnapshot(
        for dateString: String,
        snapshots: [DailyDistrictMetricSnapshot]
    ) -> DailyDistrictMetricSnapshot? {
        snapshots
            .filter { snapshot in
                guard snapshot.dateString == dateString,
                      let value = snapshot.sockeyePerBoatDaily else { return false }
                return value.isFinite && value > 0
            }
            .max { lhs, rhs in
                let lhsValue = lhs.sockeyePerBoatDaily ?? 0
                let rhsValue = rhs.sockeyePerBoatDaily ?? 0
                if lhsValue != rhsValue { return lhsValue < rhsValue }
                return orderedDistrictIndex(lhs.district) > orderedDistrictIndex(rhs.district)
            }
    }

    nonisolated private static func topDistrictTenYearMeanDailyDisplayValue(
        _ result: TopDistrictTenYearMeanDailyResult?
    ) -> String {
        guard let result else { return "—" }
        let yearLabel = result.yearsUsed == 1 ? "1 yr" : "\(result.yearsUsed) yrs"
        return "\(districtDisplayLabel(result.district)) — \(formatNumber(result.meanSockeyePerBoatDaily, decimals: 0)) sockeye/boat (\(yearLabel))"
    }

    nonisolated private static func orderedDistrictIndex(_ district: District) -> Int {
        orderedDistricts.firstIndex(of: district) ?? Int.max
    }

    nonisolated private static func buildDailyRows(
        filters: DeepResearchTablesFilters,
        districts: [District],
        dates: [String],
        raw: RawTablesBundle
    ) -> [DeepResearchTableRow] {
        var built: [DeepResearchTableRow] = []
        let snapshots = buildDailySnapshots(filters: filters, districts: districts, dates: dates, raw: raw)
        let wantsDailyTopDistrict = filters.selectedMetrics.contains(.sockeyePerBoatDailyTopDistrict)
        let wantsTenYearMeanTopDistrict = filters.selectedMetrics.contains(.topDistrictTenYearMeanDaily)

        if wantsDailyTopDistrict || wantsTenYearMeanTopDistrict {
            built.reserveCapacity(dates.count)
            let fallbackDistrict = districts.first ?? .nushagak
            for dateString in dates {
                let dailyTopSnapshot = topSockeyePerBoatDailySnapshot(for: dateString, snapshots: snapshots)
                let tenYearMeanTopDistrict = TopDistrictTenYearMeanDailyCalculator.topDistrict(
                    for: dateString,
                    districts: districts,
                    samplesByDistrictMonthDay: raw.historicalSockeyePerBoatDailySamples
                )
                let displayDistrict = dailyTopSnapshot?.district ?? tenYearMeanTopDistrict?.district
                var values = dailyTopSnapshot?.values ?? [
                    "date": shortDateString(dateString),
                    "district": displayDistrict.map(districtDisplayLabel) ?? ""
                ]

                if wantsDailyTopDistrict && dailyTopSnapshot == nil {
                    values[DeepResearchTableMetric.sockeyePerBoatDailyTopDistrict.rawValue] = ""
                }
                if wantsTenYearMeanTopDistrict {
                    values[DeepResearchTableMetric.topDistrictTenYearMeanDaily.rawValue] =
                        topDistrictTenYearMeanDailyDisplayValue(tenYearMeanTopDistrict)
                }

                built.append(
                    DeepResearchTableRow(
                        id: "\(dateString)|top-district",
                        date: dateString,
                        district: displayDistrict ?? fallbackDistrict,
                        districtLabel: displayDistrict.map(districtDisplayLabel) ?? "",
                        values: values
                    )
                )
            }
            return built
        }

        built.reserveCapacity(max(1, snapshots.count))
        for snapshot in snapshots {
            built.append(
                DeepResearchTableRow(
                    id: "\(snapshot.dateString)|\(snapshot.district.key)",
                    date: snapshot.dateString,
                    district: snapshot.district,
                    districtLabel: snapshot.districtLabel,
                    values: snapshot.values
                )
            )
        }

        return built
    }

    nonisolated private static func writeDailyCSVRows(
        to handle: FileHandle,
        columns: [DeepResearchTableColumn],
        filters: DeepResearchTablesFilters,
        districts: [District],
        dates: [String],
        raw: RawTablesBundle
    ) throws {
        let rows = buildDailyRows(filters: filters, districts: districts, dates: dates, raw: raw)
        for row in rows {
            try writeCSVLine(columns.map { row.values[$0.id] ?? "" }, to: handle)
        }
    }

    nonisolated private static func writeSeasonCSVRows(
        to handle: FileHandle,
        columns: [DeepResearchTableColumn],
        filters: DeepResearchTablesFilters,
        districts: [District],
        startYear: Int,
        endYear: Int,
        seasonRows: [String: TableSeasonMetricsRow]
    ) throws {
        let metrics = sortedMetrics(filters)
        let includeRiverColumns = includeSeasonRiverEscapementColumns(filters: filters)

        for year in startYear...endYear {
            for district in districts {
                let key = seasonRowKey(districtKey: district.key, year: year)
                let season = seasonRows[key]

                var values: [String: String] = [
                    "year": String(year),
                    "district": districtDisplayLabel(district)
                ]

                for metric in metrics {
                    values[metric.rawValue] = seasonMetricDisplayValue(metric: metric, row: season)
                }

                if includeRiverColumns {
                    for river in selectedRivers(for: district, filters: filters) {
                        values[seasonRiverColumnID(districtKey: district.key, riverKey: river.key)] =
                            formatNumber(seasonRiverEscapementValue(row: season, riverKey: river.key), decimals: 0)
                    }
                }

                try writeCSVLine(columns.map { values[$0.id] ?? "" }, to: handle)
            }
        }
    }
    nonisolated private static func buildSeasonRows(
        filters: DeepResearchTablesFilters,
        districts: [District],
        startYear: Int,
        endYear: Int,
        seasonRows: [String: TableSeasonMetricsRow]
    ) -> [DeepResearchTableRow] {
        let metrics = sortedMetrics(filters)
        let includeRiverColumns = includeSeasonRiverEscapementColumns(filters: filters)
        var built: [DeepResearchTableRow] = []

        for year in startYear...endYear {
            for district in districts {
                let key = seasonRowKey(districtKey: district.key, year: year)
                let season = seasonRows[key]

                var values: [String: String] = [
                    "year": String(year),
                    "district": districtDisplayLabel(district)
                ]

                for metric in metrics {
                    values[metric.rawValue] = seasonMetricDisplayValue(metric: metric, row: season)
                }

                if includeRiverColumns {
                    for river in selectedRivers(for: district, filters: filters) {
                        values[seasonRiverColumnID(districtKey: district.key, riverKey: river.key)] =
                            formatNumber(seasonRiverEscapementValue(row: season, riverKey: river.key), decimals: 0)
                    }
                }

                built.append(
                    DeepResearchTableRow(
                        id: "season|\(year)|\(district.key)",
                        date: String(year),
                        district: district,
                        districtLabel: districtDisplayLabel(district),
                        values: values
                    )
                )
            }
        }

        return built
    }

    // MARK: - Season Metric Rendering

    nonisolated private static func seasonMetricApplies(metric: DeepResearchTableMetric, row: TableSeasonMetricsRow) -> Bool {
        switch metric {
        case .totalEscapementNaknek, .totalEscapementKvichak, .totalEscapementAlagnak:
            return row.districtKey == "naknek_kvichak"
        case .totalEscapementEgegik:
            return row.districtKey == "egegik"
        case .totalEscapementUgashik:
            return row.districtKey == "ugashik"
        case .totalEscapementWood, .totalEscapementIgushik, .totalEscapementNushagak:
            return row.districtKey == "nushagak"
        case .totalEscapementTogiak:
            return row.districtKey == "togiak"
        default:
            return true
        }
    }

    nonisolated private static func seasonRiverColumnID(districtKey: String, riverKey: String) -> String {
        "season_river_total_\(districtKey)_\(riverKey)"
    }

    nonisolated private static func seasonRiverEscapementValue(row: TableSeasonMetricsRow?, riverKey: String) -> Double? {
        guard let row else { return nil }

        switch riverKey {
        case "naknek": return row.totalEscapementNaknek
        case "kvichak": return row.totalEscapementKvichak
        case "alagnak": return row.totalEscapementAlagnak
        case "egegik": return row.totalEscapementEgegik
        case "ugashik": return row.totalEscapementUgashik
        case "wood": return row.totalEscapementWood
        case "igushik": return row.totalEscapementIgushik
        case "nushagak": return row.totalEscapementNushagak
        case "togiak": return row.totalEscapementTogiak
        default: return nil
        }
    }

    nonisolated private static func seasonMetricDisplayValue(metric: DeepResearchTableMetric, row: TableSeasonMetricsRow?) -> String {
        guard let row else { return "" }
        guard seasonMetricApplies(metric: metric, row: row) else { return "" }

        switch metric {
        case .totalDriftHours:
            return formatNumber(row.totalDriftHours, decimals: 1)
        case .totalSetHours:
            return formatNumber(row.totalSetHours, decimals: 1)
        case .maxDriftBoats:
            return formatNumber(row.maxDriftBoats, decimals: 0)
        case .maxDriftPermits:
            return formatNumber(row.maxDriftPermits, decimals: 0)
        case .averageDriftBoats:
            return formatNumber(row.averageDriftBoats, decimals: 1)
        case .averageDriftPermits:
            return formatNumber(row.averageDriftPermits, decimals: 1)

        case .totalSockeyePerBoat:
            return formatNumber(row.totalSockeyePerBoat, decimals: 1)
        case .averageSockeyePerBoatPerDay:
            return formatNumber(row.averageSockeyePerBoatPerDay, decimals: 1)
        case .averageSockeyePerBoatPerHour:
            return formatNumber(row.averageSockeyePerBoatPerHour, decimals: 2)

        case .totalHarvest:
            return formatNumber(row.totalHarvest, decimals: 0)
        case .totalEscapement:
            return formatNumber(row.totalEscapement, decimals: 0)
        case .totalRun:
            return formatNumber(row.totalRun, decimals: 0)
        case .totalSockeyeDrift:
            return formatNumber(row.totalSockeyeDrift, decimals: 0)
        case .totalSockeyeSet:
            return formatNumber(row.totalSockeyeSet, decimals: 0)
        case .totalChumPct:
            return formatPercent(row.totalChumPct, decimals: 1)
        case .meanSockeyeWeight:
            return formatNumber(row.meanSockeyeWeight, decimals: 1)
        case .forecastedRun:
            return formatNumber(row.forecastedRun, decimals: 3)
        case .actualRun:
            return formatNumber(row.actualRun, decimals: 3)
        case .runPctDeviation:
            return formatPercent(row.runPctDeviation, decimals: 1)
        case .escapementGoalMinimum:
            return formatNumber(row.escapementGoalMinimum, decimals: 3)
        case .escapementGoalMaximum:
            return formatNumber(row.escapementGoalMaximum, decimals: 3)
        case .actualEscapement:
            return formatNumber(row.actualEscapement, decimals: 3)
        case .projectedHarvest:
            return formatNumber(row.projectedHarvest, decimals: 3)
        case .actualHarvest:
            return formatNumber(row.actualHarvest, decimals: 3)
        case .harvestPctDeviation:
            return formatPercent(row.harvestPctDeviation, decimals: 1)
        case .totalEscapementNaknek:
            return formatNumber(row.totalEscapementNaknek, decimals: 0)
        case .totalEscapementKvichak:
            return formatNumber(row.totalEscapementKvichak, decimals: 0)
        case .totalEscapementAlagnak:
            return formatNumber(row.totalEscapementAlagnak, decimals: 0)
        case .totalEscapementEgegik:
            return formatNumber(row.totalEscapementEgegik, decimals: 0)
        case .totalEscapementUgashik:
            return formatNumber(row.totalEscapementUgashik, decimals: 0)
        case .totalEscapementWood:
            return formatNumber(row.totalEscapementWood, decimals: 0)
        case .totalEscapementIgushik:
            return formatNumber(row.totalEscapementIgushik, decimals: 0)
        case .totalEscapementNushagak:
            return formatNumber(row.totalEscapementNushagak, decimals: 0)
        case .totalEscapementTogiak:
            return formatNumber(row.totalEscapementTogiak, decimals: 0)

        case .peakTimingDeviationFromMedian:
            if let value = row.peakTimingDeviationFromMedian {
                return String(value)
            }
            return ""

        default:
            return ""
        }
    }

    // MARK: - Database Loaders

    nonisolated private static func tableExists(_ db: Database, named tableName: String) throws -> Bool {
        let count = try Int.fetchOne(db, sql: """
            SELECT COUNT(*)
            FROM sqlite_master
            WHERE type IN ('table', 'view')
              AND name = ?
        """, arguments: [tableName]) ?? 0
        return count > 0
    }

    nonisolated private static func loadExporterRows(
        db: Database,
        districtKeys: [String],
        start: String,
        end: String
    ) throws -> [String: TableExporterRow] {
        guard !districtKeys.isEmpty else { return [:] }
        guard try tableExists(db, named: "exporter_sockeye_per_boat_daily") else { return [:] }
        let placeholders = districtKeys.map { _ in "?" }.joined(separator: ",")
        let args = StatementArguments(districtKeys + [start, end])

        return try TableExporterRow.fetchAll(db, sql: """
            SELECT
                date,
                districtKey,
                driftOpenHours,
                driftDeliveries,
                driftPct,
                setPct,
                driftShareFraction,
                driftSockeyeAllocAdj,
                driftBoats,
                boatsSource,
                sockeyePerBoatRaw,
                sockeyePerBoatAllocAdj
            FROM exporter_sockeye_per_boat_daily
            WHERE districtKey IN (\(placeholders))
              AND date >= ?
              AND date <= ?
            ORDER BY date, districtKey
        """, arguments: args).reduce(into: [:]) {
            $0[districtDateKey(districtKey: $1.districtKey, date: $1.date)] = $1
        }
    }

    nonisolated private static func loadHistoricalSockeyePerBoatDailySamples(
        db: Database,
        districtKeys: [String],
        beforeYear: Int,
        isNeeded: Bool
    ) throws -> [String: [TopDistrictTenYearMeanDailySample]] {
        guard isNeeded, !districtKeys.isEmpty else { return [:] }
        guard try tableExists(db, named: "exporter_sockeye_per_boat_daily") else { return [:] }

        let districtByKey = Dictionary(uniqueKeysWithValues: orderedDistricts.map { ($0.key, $0) })
        let placeholders = districtKeys.map { _ in "?" }.joined(separator: ",")
        let args = StatementArguments(districtKeys + [String(beforeYear)])

        let rows = try TableHistoricalSockeyePerBoatDailyRow.fetchAll(db, sql: """
            SELECT
                date,
                districtKey,
                sockeyePerBoatAllocAdj
            FROM exporter_sockeye_per_boat_daily
            WHERE districtKey IN (\(placeholders))
              AND CAST(substr(date, 1, 4) AS INTEGER) < ?
            ORDER BY date DESC, districtKey
        """, arguments: args)

        let samples = rows.compactMap { row -> TopDistrictTenYearMeanDailySample? in
            guard let district = districtByKey[row.districtKey],
                  let year = year(fromISODate: row.date),
                  let monthDay = monthDay(fromISODate: row.date) else {
                return nil
            }

            return TopDistrictTenYearMeanDailySample(
                district: district,
                year: year,
                monthDay: monthDay,
                sockeyePerBoatDaily: row.sockeyePerBoatAllocAdj
            )
        }

        return TopDistrictTenYearMeanDailyCalculator.groupedSamples(samples)
    }

    nonisolated private static func loadOpsRows(
        db: Database,
        districtKeys: [String],
        start: String,
        end: String
    ) throws -> [String: TableOpsRow] {
        guard !districtKeys.isEmpty else { return [:] }
        let placeholders = districtKeys.map { _ in "?" }.joined(separator: ",")
        let args = StatementArguments(districtKeys + [start, end])

        return try TableOpsRow.fetchAll(db, sql: """
            SELECT
                o.date AS date,
                d.key AS districtKey,
                o.driftOpenHours AS driftOpenHours,
                o.setOpenHours AS setOpenHours,
                o.driftDeliveries AS driftDeliveries,
                o.setDeliveries AS setDeliveries,
                o.sockeye AS sockeye,
                o.chum AS chum,
                o.total AS total
            FROM ops_day o
            JOIN districts d ON d.id = o.districtId
            WHERE d.key IN (\(placeholders))
              AND o.date >= ?
              AND o.date <= ?
            ORDER BY o.date, d.key
        """, arguments: args).reduce(into: [:]) {
            $0[districtDateKey(districtKey: $1.districtKey, date: $1.date)] = $1
        }
    }

    nonisolated private static func loadRegRows(
        db: Database,
        districtKeys: [String],
        start: String,
        end: String
    ) throws -> [String: TableRegRow] {
        guard !districtKeys.isEmpty else { return [:] }
        let placeholders = districtKeys.map { _ in "?" }.joined(separator: ",")
        let args = StatementArguments(districtKeys + [start, end])

        return try TableRegRow.fetchAll(db, sql: """
            SELECT
                r.date AS date,
                d.key AS districtKey,
                r.driftPermits AS driftPermits,
                r.dualPermits AS dualPermits,
                r.driftBoats AS driftBoats
            FROM registration_day r
            JOIN districts d ON d.id = r.districtId
            WHERE d.key IN (\(placeholders))
              AND r.date >= ?
              AND r.date <= ?
            ORDER BY r.date, d.key
        """, arguments: args).reduce(into: [:]) {
            $0[districtDateKey(districtKey: $1.districtKey, date: $1.date)] = $1
        }
    }

    nonisolated private static func loadRunTimingRows(
        db: Database,
        districtKeys: [String],
        start: String,
        end: String
    ) throws -> [String: TableRunTimingRow] {
        guard !districtKeys.isEmpty else { return [:] }
        guard try tableExists(db, named: "district_run_timing_day") else { return [:] }
        let placeholders = districtKeys.map { _ in "?" }.joined(separator: ",")
        let args = StatementArguments(districtKeys + [start, end])

        return try TableRunTimingRow.fetchAll(db, sql: """
            SELECT
                drt.date AS date,
                d.key AS districtKey,
                drt.totalPassage AS totalPassage,
                drt.smoothedDailyPassage AS smoothedDailyPassage,
                drt.cumulativePassage AS cumulativePassage,
                drt.cumulativePassagePct AS cumulativePassagePct
            FROM district_run_timing_day drt
            JOIN districts d ON d.id = drt.districtId
            WHERE d.key IN (\(placeholders))
              AND drt.date >= ?
              AND drt.date <= ?
            ORDER BY drt.date, d.key
        """, arguments: args).reduce(into: [:]) {
            $0[districtDateKey(districtKey: $1.districtKey, date: $1.date)] = $1
        }
    }

    nonisolated private static func loadRiverEscRows(
        db: Database,
        riverKeys: [String],
        start: String,
        end: String
    ) throws -> [String: TableRiverEscRow] {
        guard !riverKeys.isEmpty else { return [:] }
        let placeholders = riverKeys.map { _ in "?" }.joined(separator: ",")
        let args = StatementArguments(riverKeys + [start, end])

        return try TableRiverEscRow.fetchAll(db, sql: """
            SELECT
                rd.date AS date,
                rv.key AS riverKey,
                rd.dailyEscapement AS dailyEscapement,
                rd.isOperational AS isOperational
            FROM river_day rd
            JOIN rivers rv ON rv.id = rd.riverId
            WHERE rv.key IN (\(placeholders))
              AND rd.date >= ?
              AND rd.date <= ?
              AND COALESCE(rd.isOperational, 0) = 1
            ORDER BY rd.date, rv.key
        """, arguments: args).reduce(into: [:]) {
            $0[riverDateKey(riverKey: $1.riverKey, date: $1.date)] = $1
        }
    }

    nonisolated private static func loadSeasonMetricRows(
        db: Database,
        districtKeys: [String],
        startYear: Int,
        endYear: Int
    ) throws -> [String: TableSeasonMetricsRow] {
        guard !districtKeys.isEmpty else { return [:] }
        guard try tableExists(db, named: "district_season_metrics") else { return [:] }
        let placeholders = districtKeys.map { _ in "?" }.joined(separator: ",")
        let args = StatementArguments(districtKeys)

        return try TableSeasonMetricsRow.fetchAll(db, sql: """
            SELECT
                s.year AS year,
                d.key AS districtKey,
                s.totalDriftHours_0612_0716 AS totalDriftHours,
                s.totalSetHours_0612_0716 AS totalSetHours,
                s.maxDriftBoats_0612_0820 AS maxDriftBoats,
                s.maxDriftPermits_0612_0820 AS maxDriftPermits,
                s.avgDriftBoats_0612_0716 AS averageDriftBoats,
                s.avgDriftPermits_0612_0716 AS averageDriftPermits,
                s.totalSockeyePerBoat_0612_0801 AS totalSockeyePerBoat,
                s.avgSockeyePerBoatPerDay_0612_0716 AS averageSockeyePerBoatPerDay,
                s.avgSockeyePerBoatPerHour_0612_0716 AS averageSockeyePerBoatPerHour,
                s.totalHarvest_0612_0820 AS totalHarvest,
                s.totalEscapement_0612_0820 AS totalEscapement,
                s.totalRun_0612_0820 AS totalRun,
                s.totalSockeyeDrift_0612_0820 AS totalSockeyeDrift,
                s.totalSockeyeSet_0612_0820 AS totalSockeyeSet,
                s.totalChumPct_0612_0820 AS totalChumPct,
                s.meanSockeyeWeight_lbs AS meanSockeyeWeight,
                s.inshoreRunForecast_millions AS forecastedRun,
                s.inshoreRunActual_millions AS actualRun,
                s.inshoreRunPctDeviation AS runPctDeviation,
                s.escapementGoalMin_millions AS escapementGoalMinimum,
                s.escapementGoalMax_millions AS escapementGoalMaximum,
                s.escapementActual_millions AS actualEscapement,
                s.inshoreCatchProjected_millions AS projectedHarvest,
                s.inshoreCatchActual_millions AS actualHarvest,
                s.inshoreCatchPctDeviation AS harvestPctDeviation,
                s.totalEscapement_naknek_0612_0820 AS totalEscapementNaknek,
                s.totalEscapement_kvichak_0612_0820 AS totalEscapementKvichak,
                s.totalEscapement_alagnak_0612_0820 AS totalEscapementAlagnak,
                s.totalEscapement_egegik_0612_0820 AS totalEscapementEgegik,
                s.totalEscapement_ugashik_0612_0820 AS totalEscapementUgashik,
                s.totalEscapement_wood_0612_0820 AS totalEscapementWood,
                s.totalEscapement_igushik_0612_0820 AS totalEscapementIgushik,
                s.totalEscapement_nushagak_0612_0820 AS totalEscapementNushagak,
                s.totalEscapement_togiak_0612_0820 AS totalEscapementTogiak,
                s.peakTimingDeviationDays_10yMedian AS peakTimingDeviationFromMedian
            FROM district_season_metrics s
            JOIN districts d ON d.id = s.districtId
            WHERE d.key IN (\(placeholders))
              AND s.year >= \(startYear)
              AND s.year <= \(endYear)
            ORDER BY s.year, d.key
        """, arguments: args).reduce(into: [:]) {
            $0[seasonRowKey(districtKey: $1.districtKey, year: $1.year)] = $1
        }
    }

    // MARK: - Shared Lookup Helpers

    nonisolated private static func selectedRiverKeys(filters: DeepResearchTablesFilters, districts: [District]) -> [String] {
        guard filters.includeRiverEscapementBreakdown || filters.selectedMetrics.contains(.dailyEscapement) || filters.selectedMetrics.contains(.cumulativeEscapement) else {
            return districts.flatMap { riverOptionsStatic(for: $0).map(\.key) }
        }

        return districts.flatMap { district in
            let fallback = Set(riverOptionsStatic(for: district).map(\.key))
            let selected = filters.selectedRiversByDistrict[district] ?? fallback
            return Array(selected)
        }
    }

    nonisolated private static func riverOptionsStatic(for district: District) -> [TableRiverOption] {
        switch district {
        case .naknekKvichak:
            return [
                .init(key: "naknek", label: "Naknek"),
                .init(key: "kvichak", label: "Kvichak"),
                .init(key: "alagnak", label: "Alagnak")
            ]
        case .egegik:
            return [.init(key: "egegik", label: "Egegik")]
        case .ugashik:
            return [.init(key: "ugashik", label: "Ugashik")]
        case .nushagak:
            return [
                .init(key: "wood", label: "Wood"),
                .init(key: "igushik", label: "Igushik"),
                .init(key: "nushagak", label: "Nushagak")
            ]
        case .togiak:
            return [.init(key: "togiak", label: "Togiak")]
        }
    }

    nonisolated private static func sumDistrictEscapement(
        _ rows: [String: TableRiverEscRow],
        district: District,
        date: String
    ) -> Double {
        riverOptionsStatic(for: district).reduce(0.0) { partial, river in
            partial + (rows[riverDateKey(riverKey: river.key, date: date)]?.dailyEscapement ?? 0)
        }
    }

    nonisolated private static func normalizedPercent(_ value: Double?) -> Double? {
        guard let value else { return nil }
        if value > 1 { return value / 100.0 }
        return value
    }

    nonisolated private static func driftShareFraction(driftPct: Double?, setPct: Double?) -> Double? {
        guard let driftPct else { return nil }
        let set = setPct ?? 0
        let denom = driftPct + set
        guard denom > 0 else { return driftPct }
        return driftPct / denom
    }

    nonisolated private static func districtDateKey(districtKey: String, date: String) -> String {
        "\(districtKey)|\(date)"
    }

    nonisolated private static func riverDateKey(riverKey: String, date: String) -> String {
        "\(riverKey)|\(date)"
    }

    nonisolated private static func seasonRowKey(districtKey: String, year: Int) -> String {
        "\(districtKey)|\(year)"
    }

    nonisolated private static func csvEscape(_ raw: String) -> String {
        if raw.contains(",") || raw.contains("\n") || raw.contains("\"") {
            return "\"\(raw.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return raw
    }

    nonisolated private static func writeCSVLine(_ fields: [String], to handle: FileHandle) throws {
        let line = fields.map(csvEscape).joined(separator: ",") + "\n"
        try handle.write(contentsOf: Data(line.utf8))
    }

    // MARK: - Formatting / Date Helpers

    nonisolated private static func isoDateString(_ date: Date) -> String {
        let formatter = makeISODateFormatter()
        return formatter.string(from: date)
    }

    nonisolated private static func shortDateString(_ dateString: String) -> String {
        let iso = makeISODateFormatter()
        guard let date = iso.date(from: dateString) else { return dateString }
        let formatter = makeShortDateFormatter()
        return formatter.string(from: date)
    }

    nonisolated private static func displayDateString(_ date: Date) -> String {
        let formatter = makeDisplayDateFormatter()
        return formatter.string(from: date)
    }

    nonisolated private static func seasonalDateRangeStrings(from start: Date, to end: Date) -> [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = makeISODateFormatter()

        let startYear = cal.component(.year, from: start)
        let endYear = cal.component(.year, from: end)
        let startMonth = cal.component(.month, from: start)
        let startDay = cal.component(.day, from: start)
        let endMonth = cal.component(.month, from: end)
        let endDay = cal.component(.day, from: end)

        guard startYear <= endYear else { return [] }

        var out: [String] = []

        for year in startYear...endYear {
            guard let seasonStart = cal.date(from: DateComponents(year: year, month: startMonth, day: startDay)),
                  let seasonEnd = cal.date(from: DateComponents(year: year, month: endMonth, day: endDay)) else {
                continue
            }

            var current = seasonStart
            while current <= seasonEnd {
                out.append(formatter.string(from: current))
                current = cal.date(byAdding: .day, value: 1, to: current) ?? current
                if out.count > 10000 { break }
            }
        }

        return out
    }

    nonisolated private static func calendarYear(_ date: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal.component(.year, from: date)
    }

    nonisolated private static func year(fromISODate dateString: String) -> Int? {
        guard dateString.count >= 4 else { return nil }
        return Int(dateString.prefix(4))
    }

    nonisolated private static func monthDay(fromISODate dateString: String) -> String? {
        let parts = dateString.split(separator: "-")
        guard parts.count == 3 else { return nil }
        return "\(parts[1])-\(parts[2])"
    }

    nonisolated private static func formatNumber(_ value: Double?, decimals: Int) -> String {
        guard let value else { return "" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = decimals
        return formatter.string(from: NSNumber(value: value)) ?? ""
    }

    nonisolated private static func formatPercent(_ value: Double?, decimals: Int) -> String {
        guard let value else { return "" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = decimals
        return formatter.string(from: NSNumber(value: value)) ?? ""
    }

    nonisolated private static func makeISODateFormatter() -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd"
        return df
    }

    nonisolated private static func makeShortDateFormatter() -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "M/d/yy"
        return df
    }

    nonisolated private static func makeDisplayDateFormatter() -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "M/d/yyyy"
        return df
    }
}

private struct RawTablesBundle: Sendable {
    let exporterRows: [String: TableExporterRow]
    let opsRows: [String: TableOpsRow]
    let regRows: [String: TableRegRow]
    let runTimingRows: [String: TableRunTimingRow]
    let riverEscRows: [String: TableRiverEscRow]
    let historicalSockeyePerBoatDailySamples: [String: [TopDistrictTenYearMeanDailySample]]
}
