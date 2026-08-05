//
//  DailyDashboardFeedModels.swift
//  SatChart
//
//  Created by Daniel Blakey on 3/15/26.
//

import Foundation

enum DashboardDistrictKey: String, Codable, CaseIterable, Identifiable {
    case naknekKvichak = "naknek_kvichak"
    case egegik = "egegik"
    case ugashik = "ugashik"
    case nushagak = "nushagak"
    case togiak = "togiak"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .naknekKvichak: return "Naknek-Kvichak"
        case .egegik: return "Egegik"
        case .ugashik: return "Ugashik"
        case .nushagak: return "Nushagak"
        case .togiak: return "Togiak"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .naknekKvichak: return "Nak-Kvi"
        case .egegik: return "Egegik"
        case .ugashik: return "Ugashik"
        case .nushagak: return "Nushagak"
        case .togiak: return "Togiak"
        }
    }
}

enum DashboardFreshnessStatus: String, Codable, CaseIterable {
    case current
    case mixed
    case delayed
    case missing
}

enum DashboardValueKind: String, Codable, CaseIterable {
    case officialObserved
    case officialCumulative
    case estimated
    case carriedForward
    case derived
}

enum DashboardSourceFamily: String, Codable, CaseIterable {
    case advisoryAnnouncements = "advisory_announcements"
    case dailyRunSummary = "daily_run_summary"
    case riverEscapement = "river_escapement"
    case registrations = "registrations"
    case weather = "weather"
    case tides = "tides"
    case pmtf = "pmtf"
}

enum DashboardBannerType: String, Codable, CaseIterable {
    case management
    case signal
    case dataWarning = "data_warning"
}

enum DashboardOpenStatus: String, Codable, CaseIterable {
    case open
    case partial
    case closed
    case unknown
}

enum DashboardGearType: String, Codable, CaseIterable {
    case drift
    case set
    case driftAndSet = "drift_and_set"
    case none
    case unknown
}

enum DashboardTrendDirection: String, Codable, CaseIterable {
    case rising
    case flat
    case falling
    case unknown
}

enum DashboardPressureLevel: String, Codable, CaseIterable {
    case low
    case moderate
    case high
    case unknown
}

enum DashboardSectionScopeMode: String, Codable, CaseIterable {
    case fullDistrict = "full_district"
    case includeOnly = "include_only"
    case excludeOnly = "exclude_only"
    case unknown
}

struct DashboardProvenance: Codable {
    let sourceKey: String
    let sourceFamily: DashboardSourceFamily
    let sourceURL: String
    let parserVersion: String
    let rawSnapshotPath: String?
    let sourcePublishedAt: Date?
    let fetchedAt: Date
    let confidence: Double?
}

struct DashboardFreshValue<Value: Codable>: Codable {
    let value: Value?
    let displayText: String
    let unitText: String?
    let kind: DashboardValueKind
    let freshness: DashboardFreshnessStatus
    let observedDate: String?
    let confidence: Double?
    let notes: [String]
    let provenance: DashboardProvenance?
}

struct DashboardSectionScope: Codable {
    let mode: DashboardSectionScopeMode
    let includedSectionKeys: [String]
    let excludedSectionKeys: [String]
    let rawSectionPhrase: String?
    let isDistrictWide: Bool
    let activeSectionCount: Int?
    let totalDistrictSectionCount: Int?
    let coverageFraction: Double?
    let displayText: String

    var normalizedCoverageFraction: Double? {
        guard let coverageFraction else { return nil }
        return min(max(coverageFraction, 0.0), 1.0)
    }

    var hasExplicitRestriction: Bool {
        if isDistrictWide { return false }
        return mode == .includeOnly || mode == .excludeOnly || !includedSectionKeys.isEmpty || !excludedSectionKeys.isEmpty
    }
}

struct DashboardOpeningWindow: Codable, Identifiable {
    let id: String
    let districtKey: DashboardDistrictKey
    let gearType: DashboardGearType
    let startAt: Date
    let endAt: Date
    let durationMinutes: Int
    let sectionScope: DashboardSectionScope
    let announcementNumber: String?
    let emergencyOrderNumbers: [String]
    let sourcePublishedAt: Date?
    let provenance: DashboardProvenance?

    var durationHours: Double {
        Double(durationMinutes) / 60.0
    }

    func contains(_ date: Date) -> Bool {
        startAt <= date && date < endAt
    }

    func isUpcoming(relativeTo date: Date) -> Bool {
        startAt > date
    }

    func minutesRemaining(at date: Date) -> Int {
        guard contains(date) else { return 0 }
        return max(0, Int(endAt.timeIntervalSince(date) / 60.0))
    }
}

struct DashboardOpeningMetrics: Codable {
    let calculatedAt: Date
    let status: DashboardOpenStatus

    let currentWindowStartAt: Date?
    let currentWindowEndAt: Date?
    let nextWindowStartAt: Date?

    let openMinutesTodayDrift: Int?
    let openMinutesTodaySet: Int?
    let openMinutesTodayAllGears: Int?

    let openMinutesRemainingDrift: Int?
    let openMinutesRemainingSet: Int?
    let openMinutesRemainingAllGears: Int?

    let currentlyOpenDrift: Bool?
    let currentlyOpenSet: Bool?
    let currentlyOpenAnyGear: Bool?

    let sectionScopeCurrent: DashboardSectionScope?
    let sectionCoverageFractionCurrent: Double?
    let districtWideNow: Bool

    var effectiveCoverageFraction: Double? {
        if let sectionCoverageFractionCurrent {
            return min(max(sectionCoverageFractionCurrent, 0.0), 1.0)
        }
        return districtWideNow ? 1.0 : nil
    }

    var hasSectionRestrictionNow: Bool {
        guard let sectionScopeCurrent else { return false }
        return sectionScopeCurrent.hasExplicitRestriction
    }
}

struct DashboardTrendSignal: Codable {
    let direction: DashboardTrendDirection
    let score: Double?
    let label: String
    let explanation: String?
}

struct DashboardPressureSignal: Codable {
    let level: DashboardPressureLevel
    let score: Double?
    let label: String
    let explanation: String?
}

struct DashboardOpportunitySignal: Codable {
    let score: Double?
    let rank: Int?
    let label: String
    let explanation: String?
}

struct DashboardChangeSummary: Codable {
    let primaryText: String
    let dailyCatchDeltaPct: Double?
    let escapementDeltaPct: Double?
    let efficiencyDeltaPct: Double?
    let pressureDeltaPct: Double?
}

struct DashboardFeed: Codable {
    let feedVersion: Int
    let generatedAt: Date
    let runID: String
    let seasonYear: Int
    let fisheryDate: String
    let timeZoneIdentifier: String

    let overallFreshness: DashboardFreshnessStatus
    let sourceStatuses: [DashboardSourceStatus]

    let banners: [DashboardBanner]
    let openNow: [DashboardOpenNowRow]
    let districtSnapshots: [DashboardDistrictSnapshot]
    let opportunityRanks: [DashboardOpportunityRankRow]

    let defaultSelectedDistrict: DashboardDistrictKey?
    let notes: [String]
}

struct DashboardSourceStatus: Codable, Identifiable {
    let id: String
    let title: String
    let sourceFamily: DashboardSourceFamily
    let status: DashboardFreshnessStatus
    let summary: String
    let sourcePublishedAt: Date?
    let fetchedAt: Date?
    let ageMinutes: Int?
    let notes: [String]
}

struct DashboardBanner: Codable, Identifiable {
    let id: String
    let type: DashboardBannerType
    let title: String
    let message: String
    let detail: String?
    let districtKey: DashboardDistrictKey?
    let issuedAt: Date?
    let priority: Int
    let provenance: DashboardProvenance?
}

struct DashboardOpenNowRow: Codable, Identifiable {
    let districtKey: DashboardDistrictKey
    let status: DashboardOpenStatus
    let openingMetrics: DashboardOpeningMetrics
    let currentWindows: [DashboardOpeningWindow]
    let nextWindow: DashboardOpeningWindow?
    let noteText: String?
    let provenance: DashboardProvenance?

    var id: String { districtKey.rawValue }
}

struct DashboardDistrictSnapshot: Codable, Identifiable {
    let districtKey: DashboardDistrictKey
    let openStatus: DashboardOpenStatus
    let freshness: DashboardFreshnessStatus

    let openingMetrics: DashboardOpeningMetrics

    let dailyCatch: DashboardFreshValue<Int>
    let cumulativeCatch: DashboardFreshValue<Int>?
    let dailyEscapement: DashboardFreshValue<Int>?
    let cumulativeEscapement: DashboardFreshValue<Int>?
    let cumulativeInRiverEstimate: DashboardFreshValue<Int>?
    let totalRunToDate: DashboardFreshValue<Int>?

    let driftDeliveries: DashboardFreshValue<Int>?
    let sockeyePerDriftDelivery: DashboardFreshValue<Double>?
    let registrations: DashboardFreshValue<Int>?
    let activeBoatsEstimate: DashboardFreshValue<Int>?

    let momentum: DashboardTrendSignal
    let pressure: DashboardPressureSignal
    let opportunity: DashboardOpportunitySignal

    let summaryText: String
    let changeSummary: DashboardChangeSummary?
    let provenance: [DashboardProvenance]

    var id: String { districtKey.rawValue }
}

struct DashboardOpportunityRankRow: Codable, Identifiable {
    let districtKey: DashboardDistrictKey
    let rank: Int
    let score: Double?
    let scoreText: String
    let reasonText: String

    var id: String { districtKey.rawValue }
}

struct DashboardDistrictDetail: Codable {
    let districtKey: DashboardDistrictKey
    let generatedAt: Date
    let freshness: DashboardFreshnessStatus

    let overviewText: String

    let operations: DashboardDistrictOperationsBlock
    let catchMetrics: DashboardDistrictCatchBlock
    let runMetrics: DashboardDistrictRunBlock
    let pressureMetrics: DashboardDistrictPressureBlock

    let whyItMatters: [String]
    let recentTrends: [DashboardTrendSlice]

    let latestAnnouncementSummary: String?
    let latestAnnouncementIssuedAt: Date?
    let provenance: [DashboardProvenance]
}

struct DashboardDistrictOperationsBlock: Codable {
    let status: DashboardOpenStatus
    let currentWindows: [DashboardOpeningWindow]
    let nextWindow: DashboardOpeningWindow?
    let openingMetrics: DashboardOpeningMetrics
    let latestAnnouncementSummary: String?
    let announcementNumber: String?
    let emergencyOrderNumbers: [String]
    let sourcePublishedAt: Date?
}

struct DashboardDistrictCatchBlock: Codable {
    let dailyCatch: DashboardFreshValue<Int>
    let cumulativeCatch: DashboardFreshValue<Int>?
    let driftDeliveries: DashboardFreshValue<Int>?
    let sockeyePerDriftDelivery: DashboardFreshValue<Double>?
    let changeVsYesterdayPct: DashboardFreshValue<Double>?
}

struct DashboardDistrictRunBlock: Codable {
    let dailyEscapement: DashboardFreshValue<Int>?
    let cumulativeEscapement: DashboardFreshValue<Int>?
    let cumulativeInRiverEstimate: DashboardFreshValue<Int>?
    let totalRunToDate: DashboardFreshValue<Int>?
}

struct DashboardDistrictPressureBlock: Codable {
    let registrations: DashboardFreshValue<Int>?
    let activeBoatsEstimate: DashboardFreshValue<Int>?
    let driftDeliveries: DashboardFreshValue<Int>?
    let pressure: DashboardPressureSignal
}

struct DashboardTrendSlice: Codable, Identifiable {
    let id: String
    let metricKey: String
    let title: String
    let subtitle: String?
    let direction: DashboardTrendDirection
    let points: [DashboardTrendPoint]
    let sourceFamily: DashboardSourceFamily
    let freshness: DashboardFreshnessStatus

    var latestPoint: DashboardTrendPoint? {
        points.last
    }
}

struct DashboardTrendPoint: Codable, Identifiable {
    let id: String
    let at: Date?
    let label: String?
    let value: Double
    let kind: DashboardValueKind
}
