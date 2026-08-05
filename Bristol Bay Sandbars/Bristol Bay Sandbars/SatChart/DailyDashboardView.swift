import SwiftUI
import Foundation
import Combine

private let dailyDashboardCardSpacing: CGFloat = 12
private let dailyDashboardCornerRadius: CGFloat = 16
private let dailyDashboardBackgroundTop = Color(red: 0.02, green: 0.15, blue: 0.30)
private let dailyDashboardBackgroundBottom = Color(red: 0.01, green: 0.08, blue: 0.18)
private let dailyDashboardNavBarColor = Color(red: 0.06, green: 0.24, blue: 0.55)

// MARK: - View-only UI enums

private enum DailyDashboardFreshnessState: String {
    case current = "Current"
    case mixed = "Mixed"
    case delayed = "Delayed"
    case missing = "Missing"

    var color: Color {
        switch self {
        case .current: return Color(red: 0.18, green: 0.76, blue: 0.34)
        case .mixed: return Color(red: 0.95, green: 0.72, blue: 0.18)
        case .delayed: return Color(red: 0.88, green: 0.30, blue: 0.28)
        case .missing: return Color.white.opacity(0.24)
        }
    }

    var icon: String {
        switch self {
        case .current: return "checkmark.circle.fill"
        case .mixed: return "exclamationmark.triangle.fill"
        case .delayed: return "xmark.octagon.fill"
        case .missing: return "questionmark.circle.fill"
        }
    }
}

private enum DailyDashboardOpenStatus: String {
    case open = "Open"
    case partial = "Partial"
    case closed = "Closed"
    case unknown = "Unknown"

    var color: Color {
        switch self {
        case .open: return Color(red: 0.16, green: 0.70, blue: 0.34)
        case .partial: return Color(red: 0.95, green: 0.72, blue: 0.18)
        case .closed: return Color(red: 0.87, green: 0.31, blue: 0.29)
        case .unknown: return Color.white.opacity(0.22)
        }
    }
}

private enum DailyDashboardBannerStyle {
    case management
    case signal
    case dataWarning

    var accent: Color {
        switch self {
        case .management: return Color(red: 0.22, green: 0.63, blue: 1.00)
        case .signal: return Color(red: 0.18, green: 0.76, blue: 0.34)
        case .dataWarning: return Color(red: 0.95, green: 0.72, blue: 0.18)
        }
    }

    var icon: String {
        switch self {
        case .management: return "megaphone.fill"
        case .signal: return "chart.line.uptrend.xyaxis"
        case .dataWarning: return "exclamationmark.triangle.fill"
        }
    }
}

private enum DailyDashboardTrendState {
    case rising
    case flat
    case falling
    case unknown

    var label: String {
        switch self {
        case .rising: return "Rising"
        case .flat: return "Flat"
        case .falling: return "Falling"
        case .unknown: return "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .rising: return Color(red: 0.18, green: 0.76, blue: 0.34)
        case .flat: return Color(red: 0.75, green: 0.78, blue: 0.82)
        case .falling: return Color(red: 0.88, green: 0.30, blue: 0.28)
        case .unknown: return Color.white.opacity(0.52)
        }
    }

    var icon: String {
        switch self {
        case .rising: return "arrow.up.right"
        case .flat: return "arrow.right"
        case .falling: return "arrow.down.right"
        case .unknown: return "questionmark"
        }
    }
}

private enum DailyDashboardPressureState {
    case low
    case moderate
    case high
    case unknown

    var color: Color {
        switch self {
        case .low: return Color(red: 0.18, green: 0.76, blue: 0.34)
        case .moderate: return Color(red: 0.95, green: 0.72, blue: 0.18)
        case .high: return Color(red: 0.88, green: 0.30, blue: 0.28)
        case .unknown: return Color.white.opacity(0.52)
        }
    }
}

// MARK: - View state models

private struct DailyDashboardScreenState {
    let lastUpdatedText: String
    let freshnessState: DailyDashboardFreshnessState
    let sourceStatuses: [DailyDashboardSourceStatusItem]
    let banners: [DailyDashboardBannerItem]
    let openNowRows: [DailyDashboardOpenNowRow]
    let districtCards: [DailyDashboardDistrictSnapshotCard]
    let rankedDistricts: [DailyDashboardOpportunityRankRow]
    let detailByDistrict: [District: DailyDashboardDistrictDetail]
    let quickLinks: [DailyDashboardQuickLinkItem]
    let notes: [String]

    static let mock = DailyDashboardScreenState(
        lastUpdatedText: "3:42 PM AKDT",
        freshnessState: .mixed,
        sourceStatuses: [
            .init(title: "Catch", value: "Current", state: .current),
            .init(title: "Escapement", value: "Current", state: .current),
            .init(title: "Openings", value: "Current", state: .current),
            .init(title: "Registrations", value: "Estimated", state: .mixed),
        ],
        banners: [
            .init(style: .management, title: "Latest Opening", message: "Nushagak Section open 9:00 AM–3:00 PM today for drift gear.", detail: "Updated 2:58 PM"),
            .init(style: .signal, title: "Biggest Shift", message: "Nushagak sockeye/boat is up sharply versus the prior 2 days.", detail: "Momentum improving"),
            .init(style: .dataWarning, title: "Data Caveat", message: "Registrations are carried forward after the latest official report window.", detail: "Modeled values are labeled"),
        ],
        openNowRows: [
            .init(district: .naknekKvichak, status: .partial, hoursText: "9a–3p", gearText: "Drift", noteText: "Naknek only"),
            .init(district: .egegik, status: .open, hoursText: "Open", gearText: "Drift + Set", noteText: "No section qualifier"),
            .init(district: .ugashik, status: .partial, hoursText: "10a–4p", gearText: "Drift", noteText: "Watch next notice"),
            .init(district: .nushagak, status: .open, hoursText: "9a–3p", gearText: "Drift", noteText: "Strong midday signal"),
            .init(district: .togiak, status: .closed, hoursText: "Closed", gearText: "—", noteText: "Conditional / low activity"),
        ],
        districtCards: [
            .init(district: .naknekKvichak, status: .partial, freshness: .current, sockeyePerBoatText: "1,980", dailyCatchText: "412k", passageText: "87k", boatsText: "412", momentumText: "Flat", momentumState: .flat, pressureText: "High", pressureState: .high, summaryText: "Big volume, but crowding remains elevated.", opportunityText: "7.3 / 10"),
            .init(district: .egegik, status: .open, freshness: .current, sockeyePerBoatText: "2,240", dailyCatchText: "368k", passageText: "73k", boatsText: "241", momentumText: "Rising", momentumState: .rising, pressureText: "Moderate", pressureState: .moderate, summaryText: "Strong efficiency with manageable pressure.", opportunityText: "8.4 / 10"),
            .init(district: .ugashik, status: .partial, freshness: .mixed, sockeyePerBoatText: "1,420", dailyCatchText: "158k", passageText: "41k", boatsText: "128", momentumText: "Rising", momentumState: .rising, pressureText: "Low", pressureState: .low, summaryText: "Improving signal before pressure builds.", opportunityText: "7.9 / 10"),
            .init(district: .nushagak, status: .open, freshness: .current, sockeyePerBoatText: "2,610", dailyCatchText: "521k", passageText: "112k", boatsText: "286", momentumText: "Rising", momentumState: .rising, pressureText: "Moderate", pressureState: .moderate, summaryText: "Best current efficiency with solid run support.", opportunityText: "8.8 / 10"),
            .init(district: .togiak, status: .closed, freshness: .delayed, sockeyePerBoatText: "—", dailyCatchText: "12k", passageText: "6k", boatsText: "24", momentumText: "Falling", momentumState: .falling, pressureText: "Low", pressureState: .low, summaryText: "Limited near-term opportunity on current information.", opportunityText: "3.1 / 10"),
        ],
        rankedDistricts: [
            .init(district: .nushagak, scoreText: "8.8", reasonText: "Best efficiency + strong passage"),
            .init(district: .egegik, scoreText: "8.4", reasonText: "Strong catch with moderate pressure"),
            .init(district: .ugashik, scoreText: "7.9", reasonText: "Improving signal, lighter fleet"),
            .init(district: .naknekKvichak, scoreText: "7.3", reasonText: "Big volume, but crowded"),
            .init(district: .togiak, scoreText: "3.1", reasonText: "Limited activity / stale conditions"),
        ],
        detailByDistrict: [
            .nushagak: .init(
                district: .nushagak,
                overview: "Nushagak is the best pure combination of current efficiency, run support, and usable access in this mock layout.",
                operations: [
                    .init(label: "Status", value: "Open"),
                    .init(label: "Hours", value: "9:00 AM–3:00 PM"),
                    .init(label: "Gear", value: "Drift"),
                    .init(label: "Section", value: "District-wide"),
                ],
                catchMetrics: [
                    .init(label: "Daily Catch", value: "521,000"),
                    .init(label: "Cumulative Catch", value: "7.02M"),
                    .init(label: "Sockeye / Boat", value: "2,610"),
                    .init(label: "Vs Yesterday", value: "+9%"),
                ],
                runMetrics: [
                    .init(label: "Daily Escapement", value: "112,000"),
                    .init(label: "Cumulative Esc.", value: "4.18M"),
                    .init(label: "Daily Passage", value: "633,000"),
                    .init(label: "Timing", value: "1 day ahead"),
                ],
                pressureMetrics: [
                    .init(label: "Registrations", value: "286"),
                    .init(label: "Active Boats", value: "274"),
                    .init(label: "Deliveries", value: "201"),
                    .init(label: "Pressure", value: "Moderate"),
                ],
                watchFlags: [
                    "Momentum is positive across catch and passage.",
                    "This is the district the dashboard should highlight first.",
                ],
                trendStrips: [
                    .init(title: "Sockeye / Boat", subtitle: "Recent 5-day trend", values: [1810, 1980, 2190, 2410, 2610], trend: .rising),
                    .init(title: "Passage", subtitle: "Recent 5-day trend", values: [77, 85, 94, 103, 112], trend: .rising),
                    .init(title: "Pressure", subtitle: "Recent 5-day trend", values: [251, 258, 266, 272, 274], trend: .rising),
                ]
            )
        ],
        quickLinks: [
            .init(title: "Research", systemImage: "chart.bar.doc.horizontal", subtitle: "Open charts, tables, and models"),
            .init(title: "Tides & Weather", systemImage: "cloud.sun", subtitle: "Environmental conditions"),
            .init(title: "Radio Group", systemImage: "antenna.radiowaves.left.and.right", subtitle: "Pins and fleet coordination"),
            .init(title: "Announcements", systemImage: "doc.text", subtitle: "Latest openings and notices"),
        ],
        notes: []
    )
}

private struct DailyDashboardSourceStatusItem: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let state: DailyDashboardFreshnessState
}

private struct DailyDashboardBannerItem: Identifiable {
    let id = UUID()
    let style: DailyDashboardBannerStyle
    let title: String
    let message: String
    let detail: String
}

private struct DailyDashboardOpenNowRow: Identifiable {
    let district: District
    let status: DailyDashboardOpenStatus
    let hoursText: String
    let gearText: String
    let noteText: String

    var id: String { district.rawValue }
}

private struct DailyDashboardDistrictSnapshotCard: Identifiable {
    let district: District
    let status: DailyDashboardOpenStatus
    let freshness: DailyDashboardFreshnessState
    let sockeyePerBoatText: String
    let dailyCatchText: String
    let passageText: String
    let boatsText: String
    let momentumText: String
    let momentumState: DailyDashboardTrendState
    let pressureText: String
    let pressureState: DailyDashboardPressureState
    let summaryText: String
    let opportunityText: String

    var id: String { district.rawValue }
}

private struct DailyDashboardOpportunityRankRow: Identifiable {
    let district: District
    let scoreText: String
    let reasonText: String

    var id: String { district.rawValue }
}

private struct DailyDashboardMetricPair: Identifiable {
    let id = UUID()
    let label: String
    let value: String
}

private struct DailyDashboardTrendStripModel: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let values: [Double]
    let trend: DailyDashboardTrendState
}

private struct DailyDashboardDistrictDetail {
    let district: District
    let overview: String
    let operations: [DailyDashboardMetricPair]
    let catchMetrics: [DailyDashboardMetricPair]
    let runMetrics: [DailyDashboardMetricPair]
    let pressureMetrics: [DailyDashboardMetricPair]
    let watchFlags: [String]
    let trendStrips: [DailyDashboardTrendStripModel]
}

private struct DailyDashboardQuickLinkItem: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let subtitle: String?
}

// MARK: - View model / loader

@MainActor
private final class DailyDashboardViewModel: ObservableObject {
    @Published var state: DailyDashboardScreenState = .mock
    @Published var loadError: String?

    private var hasLoaded = false

    func load(force: Bool = false) async -> District? {
        if hasLoaded && !force { return nil }
        hasLoaded = true

        do {
            let result = try DailyDashboardFeedLoader.load()
            state = result.state
            loadError = nil
            return result.defaultDistrict
        } catch {
            loadError = error.localizedDescription
            return nil
        }
    }
}

private enum DailyDashboardFeedLoader {
    static func load() throws -> (state: DailyDashboardScreenState, defaultDistrict: District?) {
        let url = try firstExistingFeedURL()
        let data = try Data(contentsOf: url)
        return try decodeFeedBundle(from: data)
    }

    private static func firstExistingFeedURL() throws -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let doc = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(doc.appendingPathComponent("dashboard_feed_bundle.json"))
            candidates.append(doc.appendingPathComponent("dashboard_feed.json"))
            candidates.append(doc.appendingPathComponent("daily_dashboard_feed.json"))
        }

        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(appSupport.appendingPathComponent("dashboard_feed_bundle.json"))
            candidates.append(appSupport.appendingPathComponent("dashboard_feed.json"))
            candidates.append(appSupport.appendingPathComponent("daily_dashboard_feed.json"))
        }

        if let url = Bundle.main.url(forResource: "dashboard_feed_bundle", withExtension: "json") {
            candidates.append(url)
        }
        if let url = Bundle.main.url(forResource: "dashboard_feed", withExtension: "json") {
            candidates.append(url)
        }
        if let url = Bundle.main.url(forResource: "daily_dashboard_feed", withExtension: "json") {
            candidates.append(url)
        }

        if let found = candidates.first(where: { fm.fileExists(atPath: $0.path) }) {
            return found
        }

        throw NSError(
            domain: "DailyDashboardFeedLoader",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No daily dashboard feed JSON was found in the app bundle, Documents, or Application Support."]
        )
    }

    private static func decodeFeedBundle(from data: Data) throws -> (state: DailyDashboardScreenState, defaultDistrict: District?) {
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        guard let root = jsonObject as? [String: Any] else {
            throw NSError(domain: "DailyDashboardFeedLoader", code: 2, userInfo: [NSLocalizedDescriptionKey: "Dashboard feed JSON is not a dictionary."])
        }

        let current = (root["current"] as? [String: Any]) ?? root
        let districtDetailsRoot = root["districtDetails"] as? [String: Any] ?? [:]
        let header = current.dictionaryValue(forKey: "header")

        let generatedAt = current.stringValue(forKey: "generatedAt") ?? ISO8601DateFormatter().string(from: Date())
        let lastUpdatedText = header?.stringValue(forKey: "asOfText") ?? formatAnchorageAsOf(generatedAt)
        let freshnessState = DailyDashboardFreshnessState(rawBackendValue: current.stringValue(forKey: "overallFreshness"))

        let sourceStatuses = parseSourceStatuses(header: header, current: current)
        let banners = parseBanners(current.arrayOfDictionaries(forKey: "banners"))
        let openNowRows = parseOpenNowRows(current.arrayOfDictionaries(forKey: "openNow"))
        let districtCards = parseDistrictCards(current.arrayOfDictionaries(forKey: "districtSnapshots"))
        let rankedDistricts = parseOpportunityRanks(current.arrayOfDictionaries(forKey: "opportunityRanks"))
        let detailByDistrict = parseDistrictDetails(districtDetailsRoot)
        let quickLinks = parseQuickLinks(current.arrayOfDictionaries(forKey: "quickLinks"))
        let notes = current.arrayOfStrings(forKey: "notes")
        let defaultDistrict = District(dashboardKey: current.stringValue(forKey: "defaultSelectedDistrict"))

        let state = DailyDashboardScreenState(
            lastUpdatedText: lastUpdatedText,
            freshnessState: freshnessState,
            sourceStatuses: sourceStatuses,
            banners: banners,
            openNowRows: openNowRows,
            districtCards: districtCards,
            rankedDistricts: rankedDistricts,
            detailByDistrict: detailByDistrict,
            quickLinks: quickLinks,
            notes: notes
        )

        return (state, defaultDistrict)
    }

    private static func parseSourceStatuses(header: [String: Any]?, current: [String: Any]) -> [DailyDashboardSourceStatusItem] {
        if let items = header?.arrayOfDictionaries(forKey: "sourceItems"), !items.isEmpty {
            return items.map {
                DailyDashboardSourceStatusItem(
                    title: $0.stringValue(forKey: "title") ?? "Source",
                    value: $0.stringValue(forKey: "summary") ?? $0.stringValue(forKey: "displayText") ?? "—",
                    state: DailyDashboardFreshnessState(rawBackendValue: $0.stringValue(forKey: "status"))
                )
            }
        }

        return current.arrayOfDictionaries(forKey: "sourceStatuses").map {
            DailyDashboardSourceStatusItem(
                title: $0.stringValue(forKey: "title") ?? "Source",
                value: $0.stringValue(forKey: "summary") ?? "—",
                state: DailyDashboardFreshnessState(rawBackendValue: $0.stringValue(forKey: "status"))
            )
        }
    }

    private static func parseBanners(_ rows: [[String: Any]]) -> [DailyDashboardBannerItem] {
        rows.prefix(3).map {
            DailyDashboardBannerItem(
                style: DailyDashboardBannerStyle(rawBackendValue: $0.stringValue(forKey: "type")),
                title: $0.stringValue(forKey: "title") ?? "Banner",
                message: $0.stringValue(forKey: "message") ?? "",
                detail: $0.stringValue(forKey: "detail") ?? ""
            )
        }
    }

    private static func parseOpenNowRows(_ rows: [[String: Any]]) -> [DailyDashboardOpenNowRow] {
        rows.compactMap { row in
            guard let district = District(dashboardKey: row.stringValue(forKey: "districtKey")) else { return nil }
            let currentWindows = row.arrayOfDictionaries(forKey: "currentWindows")
            let nextWindow = row.dictionaryValue(forKey: "nextWindow")
            let status = DailyDashboardOpenStatus(rawBackendValue: row.stringValue(forKey: "status"))

            let hoursText = formatHoursText(status: status, currentWindows: currentWindows, nextWindow: nextWindow)
            let gearText = formatGearText(currentWindows: currentWindows, nextWindow: nextWindow)
            let noteText = row.stringValue(forKey: "noteText") ?? ""

            return DailyDashboardOpenNowRow(
                district: district,
                status: status,
                hoursText: hoursText,
                gearText: gearText,
                noteText: noteText
            )
        }
    }

    private static func parseDistrictCards(_ rows: [[String: Any]]) -> [DailyDashboardDistrictSnapshotCard] {
        rows.compactMap { row in
            guard let district = District(dashboardKey: row.stringValue(forKey: "districtKey")) else { return nil }

            let dailyCatch = row.dictionaryValue(forKey: "dailyCatch")?.stringValue(forKey: "displayText") ?? "—"
            let passage = row.dictionaryValue(forKey: "dailyEscapement")?.stringValue(forKey: "displayText")
                ?? row.dictionaryValue(forKey: "totalRunToDate")?.stringValue(forKey: "displayText")
                ?? "—"
            let boats = row.dictionaryValue(forKey: "activeBoatsEstimate")?.stringValue(forKey: "displayText")
                ?? row.dictionaryValue(forKey: "registrations")?.stringValue(forKey: "displayText")
                ?? "—"

            return DailyDashboardDistrictSnapshotCard(
                district: district,
                status: DailyDashboardOpenStatus(rawBackendValue: row.stringValue(forKey: "openStatus")),
                freshness: DailyDashboardFreshnessState(rawBackendValue: row.stringValue(forKey: "freshness")),
                sockeyePerBoatText: row.dictionaryValue(forKey: "sockeyePerDriftDelivery")?.stringValue(forKey: "displayText") ?? "—",
                dailyCatchText: dailyCatch,
                passageText: passage,
                boatsText: boats,
                momentumText: row.dictionaryValue(forKey: "momentum")?.stringValue(forKey: "label") ?? "Unknown",
                momentumState: DailyDashboardTrendState(rawBackendValue: row.dictionaryValue(forKey: "momentum")?.stringValue(forKey: "direction")),
                pressureText: row.dictionaryValue(forKey: "pressure")?.stringValue(forKey: "label") ?? "Unknown",
                pressureState: DailyDashboardPressureState(rawBackendValue: row.dictionaryValue(forKey: "pressure")?.stringValue(forKey: "level")),
                summaryText: row.stringValue(forKey: "summaryText") ?? "",
                opportunityText: row.dictionaryValue(forKey: "opportunity")?.stringValue(forKey: "label") ?? "—"
            )
        }
    }

    private static func parseOpportunityRanks(_ rows: [[String: Any]]) -> [DailyDashboardOpportunityRankRow] {
        rows.compactMap { row in
            guard let district = District(dashboardKey: row.stringValue(forKey: "districtKey")) else { return nil }
            return DailyDashboardOpportunityRankRow(
                district: district,
                scoreText: row.stringValue(forKey: "scoreText") ?? "—",
                reasonText: row.stringValue(forKey: "reasonText") ?? ""
            )
        }
    }

    private static func parseDistrictDetails(_ root: [String: Any]) -> [District: DailyDashboardDistrictDetail] {
        var out: [District: DailyDashboardDistrictDetail] = [:]

        for (key, value) in root {
            guard let district = District(dashboardKey: key), let row = value as? [String: Any] else { continue }

            let operations = buildOperationsMetrics(row.dictionaryValue(forKey: "operations"))
            let catchMetrics = buildCatchMetrics(row.dictionaryValue(forKey: "catchMetrics"))
            let runMetrics = buildRunMetrics(row.dictionaryValue(forKey: "runMetrics"))
            let pressureMetrics = buildPressureMetrics(row.dictionaryValue(forKey: "pressureMetrics"))
            let watchFlags = row.arrayOfStrings(forKey: "whyItMatters")
            let trendStrips = buildTrendStrips(row.arrayOfDictionaries(forKey: "recentTrends"))

            out[district] = DailyDashboardDistrictDetail(
                district: district,
                overview: row.stringValue(forKey: "overviewText") ?? "",
                operations: operations,
                catchMetrics: catchMetrics,
                runMetrics: runMetrics,
                pressureMetrics: pressureMetrics,
                watchFlags: watchFlags,
                trendStrips: trendStrips
            )
        }

        return out
    }

    private static func parseQuickLinks(_ rows: [[String: Any]]) -> [DailyDashboardQuickLinkItem] {
        rows.map {
            DailyDashboardQuickLinkItem(
                title: $0.stringValue(forKey: "title") ?? "Link",
                systemImage: $0.stringValue(forKey: "systemImage") ?? "link",
                subtitle: $0.stringValue(forKey: "subtitle")
            )
        }
    }

    private static func buildOperationsMetrics(_ row: [String: Any]?) -> [DailyDashboardMetricPair] {
        guard let row else { return [] }
        let openingMetrics = row.dictionaryValue(forKey: "openingMetrics")
        let currentWindows = row.arrayOfDictionaries(forKey: "currentWindows")
        let nextWindow = row.dictionaryValue(forKey: "nextWindow")

        let status = DailyDashboardOpenStatus(rawBackendValue: row.stringValue(forKey: "status")).rawValue
        let hours = formatHoursText(
            status: DailyDashboardOpenStatus(rawBackendValue: row.stringValue(forKey: "status")),
            currentWindows: currentWindows,
            nextWindow: nextWindow
        )
        let gear = formatGearText(currentWindows: currentWindows, nextWindow: nextWindow)
        let section = openingMetrics?.dictionaryValue(forKey: "sectionScopeCurrent")?.stringValue(forKey: "displayText")
            ?? currentWindows.first?.dictionaryValue(forKey: "sectionScope")?.stringValue(forKey: "displayText")
            ?? "District-wide"

        return [
            .init(label: "Status", value: status),
            .init(label: "Hours", value: hours),
            .init(label: "Gear", value: gear),
            .init(label: "Section", value: section),
        ]
    }

    private static func buildCatchMetrics(_ row: [String: Any]?) -> [DailyDashboardMetricPair] {
        guard let row else { return [] }
        return [
            .init(label: "Daily Catch", value: row.dictionaryValue(forKey: "dailyCatch")?.stringValue(forKey: "displayText") ?? "—"),
            .init(label: "Cumulative Catch", value: row.dictionaryValue(forKey: "cumulativeCatch")?.stringValue(forKey: "displayText") ?? "—"),
            .init(label: "Sockeye / Delivery", value: row.dictionaryValue(forKey: "sockeyePerDriftDelivery")?.stringValue(forKey: "displayText") ?? "—"),
            .init(label: "Drift Deliveries", value: row.dictionaryValue(forKey: "driftDeliveries")?.stringValue(forKey: "displayText") ?? "—"),
        ]
    }

    private static func buildRunMetrics(_ row: [String: Any]?) -> [DailyDashboardMetricPair] {
        guard let row else { return [] }
        return [
            .init(label: "Daily Escapement", value: row.dictionaryValue(forKey: "dailyEscapement")?.stringValue(forKey: "displayText") ?? "—"),
            .init(label: "Cumulative Esc.", value: row.dictionaryValue(forKey: "cumulativeEscapement")?.stringValue(forKey: "displayText") ?? "—"),
            .init(label: "In-River Est.", value: row.dictionaryValue(forKey: "cumulativeInRiverEstimate")?.stringValue(forKey: "displayText") ?? "—"),
            .init(label: "Total Run", value: row.dictionaryValue(forKey: "totalRunToDate")?.stringValue(forKey: "displayText") ?? "—"),
        ]
    }

    private static func buildPressureMetrics(_ row: [String: Any]?) -> [DailyDashboardMetricPair] {
        guard let row else { return [] }
        return [
            .init(label: "Registrations", value: row.dictionaryValue(forKey: "registrations")?.stringValue(forKey: "displayText") ?? "—"),
            .init(label: "Active Boats", value: row.dictionaryValue(forKey: "activeBoatsEstimate")?.stringValue(forKey: "displayText") ?? "—"),
            .init(label: "Deliveries", value: row.dictionaryValue(forKey: "driftDeliveries")?.stringValue(forKey: "displayText") ?? "—"),
            .init(label: "Pressure", value: row.dictionaryValue(forKey: "pressure")?.stringValue(forKey: "label") ?? "Unknown"),
        ]
    }

    private static func buildTrendStrips(_ rows: [[String: Any]]) -> [DailyDashboardTrendStripModel] {
        rows.compactMap { row in
            let values = row.arrayOfDictionaries(forKey: "points").compactMap { $0.doubleValue(forKey: "value") }
            guard !values.isEmpty else { return nil }
            return DailyDashboardTrendStripModel(
                title: row.stringValue(forKey: "title") ?? "Trend",
                subtitle: row.stringValue(forKey: "subtitle") ?? "Recent trend",
                values: values,
                trend: DailyDashboardTrendState(rawBackendValue: row.stringValue(forKey: "direction"))
            )
        }
    }

    private static func formatHoursText(status: DailyDashboardOpenStatus, currentWindows: [[String: Any]], nextWindow: [String: Any]?) -> String {
        if let window = currentWindows.first,
           let startAt = window.stringValue(forKey: "startAt"),
           let endAt = window.stringValue(forKey: "endAt") {
            return shortTimeRange(startAt: startAt, endAt: endAt)
        }

        if let nextWindow,
           let startAt = nextWindow.stringValue(forKey: "startAt") {
            return formatAnchorageMonthDay(startAt) ?? "Next"
        }

        switch status {
        case .open: return "Open"
        case .partial: return "Partial"
        case .closed: return "Closed"
        case .unknown: return "Unknown"
        }
    }

    private static func formatGearText(currentWindows: [[String: Any]], nextWindow: [String: Any]?) -> String {
        let raw = currentWindows.first?.stringValue(forKey: "gearType") ?? nextWindow?.stringValue(forKey: "gearType")
        switch raw?.lowercased() {
        case "drift": return "Drift"
        case "set": return "Set"
        case "drift_and_set": return "Drift + Set"
        case "none": return "—"
        default: return "—"
        }
    }

    private static func shortTimeRange(startAt: String, endAt: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let start = formatter.date(from: startAt) ?? ISO8601DateFormatter().date(from: startAt)
        let end = formatter.date(from: endAt) ?? ISO8601DateFormatter().date(from: endAt)

        guard let start, let end else { return "Open" }

        let tf = DateFormatter()
        tf.timeZone = TimeZone(identifier: "America/Anchorage")
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.dateFormat = "h:mma"

        let startText = tf.string(from: start).lowercased().replacingOccurrences(of: ":00", with: "")
        let endText = tf.string(from: end).lowercased().replacingOccurrences(of: ":00", with: "")
        return "\(startText)–\(endText)"
    }

    private static func formatAnchorageAsOf(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: iso) ?? Date()

        let df = DateFormatter()
        df.timeZone = TimeZone(identifier: "America/Anchorage")
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "h:mm a 'AKDT'"
        return df.string(from: date)
    }

    private static func formatAnchorageMonthDay(_ iso: String) -> String? {
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return nil }

        let df = DateFormatter()
        df.timeZone = TimeZone(identifier: "America/Anchorage")
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MMM d"
        return df.string(from: date)
    }
}

// MARK: - JSON helpers

private extension Dictionary where Key == String, Value == Any {
    func stringValue(forKey key: String) -> String? {
        if let value = self[key] as? String { return value }
        if let value = self[key] as? NSNumber { return value.stringValue }
        return nil
    }

    func doubleValue(forKey key: String) -> Double? {
        if let value = self[key] as? Double { return value }
        if let value = self[key] as? NSNumber { return value.doubleValue }
        if let value = self[key] as? String { return Double(value) }
        return nil
    }

    func dictionaryValue(forKey key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func arrayOfDictionaries(forKey key: String) -> [[String: Any]] {
        self[key] as? [[String: Any]] ?? []
    }

    func arrayOfStrings(forKey key: String) -> [String] {
        self[key] as? [String] ?? []
    }
}

private extension District {
    init?(dashboardKey: String?) {
        switch dashboardKey {
        case "naknek_kvichak": self = .naknekKvichak
        case "egegik": self = .egegik
        case "ugashik": self = .ugashik
        case "nushagak": self = .nushagak
        case "togiak": self = .togiak
        default: return nil
        }
    }
}

private extension DailyDashboardFreshnessState {
    init(rawBackendValue: String?) {
        switch rawBackendValue?.lowercased() {
        case "current": self = .current
        case "mixed": self = .mixed
        case "delayed": self = .delayed
        case "missing": self = .missing
        default: self = .missing
        }
    }
}

private extension DailyDashboardOpenStatus {
    init(rawBackendValue: String?) {
        switch rawBackendValue?.lowercased() {
        case "open": self = .open
        case "partial": self = .partial
        case "closed": self = .closed
        default: self = .unknown
        }
    }
}

private extension DailyDashboardBannerStyle {
    init(rawBackendValue: String?) {
        switch rawBackendValue?.lowercased() {
        case "management": self = .management
        case "signal": self = .signal
        default: self = .dataWarning
        }
    }
}

private extension DailyDashboardTrendState {
    init(rawBackendValue: String?) {
        switch rawBackendValue?.lowercased() {
        case "rising": self = .rising
        case "flat": self = .flat
        case "falling": self = .falling
        default: self = .unknown
        }
    }
}

private extension DailyDashboardPressureState {
    init(rawBackendValue: String?) {
        switch rawBackendValue?.lowercased() {
        case "low": self = .low
        case "moderate": self = .moderate
        case "high": self = .high
        default: self = .unknown
        }
    }
}

// MARK: - View

struct DailyDashboardView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var viewModel = DailyDashboardViewModel()

    @State private var selectedScopeDistrict: District? = nil
    @State private var selectedDistrict: District = .nushagak

    private var state: DailyDashboardScreenState { viewModel.state }

    private var isRegularWidth: Bool {
        horizontalSizeClass == .regular
    }

    private var visibleOpenNowRows: [DailyDashboardOpenNowRow] {
        if let selectedScopeDistrict {
            return state.openNowRows.filter { $0.district == selectedScopeDistrict }
        }
        return state.openNowRows
    }

    private var visibleDistrictCards: [DailyDashboardDistrictSnapshotCard] {
        if let selectedScopeDistrict {
            return state.districtCards.filter { $0.district == selectedScopeDistrict }
        }
        return state.districtCards
    }

    private var visibleRankedDistricts: [DailyDashboardOpportunityRankRow] {
        if let selectedScopeDistrict {
            return state.rankedDistricts.filter { $0.district == selectedScopeDistrict }
        }
        return state.rankedDistricts
    }

    private var activeDetailDistrict: District {
        if let selectedScopeDistrict {
            return selectedScopeDistrict
        }
        if state.detailByDistrict[selectedDistrict] != nil {
            return selectedDistrict
        }
        return state.detailByDistrict.keys.sorted { $0.rawValue < $1.rawValue }.first ?? .nushagak
    }

    private var selectedDetail: DailyDashboardDistrictDetail? {
        state.detailByDistrict[activeDetailDistrict]
    }

    private var selectedTrendStrips: [DailyDashboardTrendStripModel] {
        selectedDetail?.trendStrips ?? []
    }

    var body: some View {
        ZStack {
            menuBlue.ignoresSafeArea()

            LinearGradient(
                colors: [dailyDashboardBackgroundTop, dailyDashboardBackgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: [.top, .leading, .trailing])

            ScrollView(.vertical, showsIndicators: false) {
                if isRegularWidth {
                    regularWidthLayout
                } else {
                    compactLayout
                }
            }
        }
        .navigationTitle("Daily Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(dailyDashboardNavBarColor, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            if let defaultDistrict = await viewModel.load() {
                selectedDistrict = defaultDistrict
            }
        }
        .onAppear {
            BBMenuAppearance.applyNavBar()
        }
    }

    private var compactLayout: some View {
        VStack(spacing: dailyDashboardCardSpacing) {
            dashboardHeaderCard
            if let loadError = viewModel.loadError {
                loaderWarningCard(loadError)
            }
            priorityBannerStack
            openNowCard
            districtSnapshotSection
            opportunityNowCard
            selectedDistrictDetailCard
            recentTrendsCard
            quickLinksCard
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 0)
    }

    private var regularWidthLayout: some View {
        HStack(alignment: .top, spacing: dailyDashboardCardSpacing) {
            VStack(spacing: dailyDashboardCardSpacing) {
                dashboardHeaderCard
                if let loadError = viewModel.loadError {
                    loaderWarningCard(loadError)
                }
                priorityBannerStack
                openNowCard
                opportunityNowCard
            }
            .frame(maxWidth: .infinity, alignment: .top)

            VStack(spacing: dailyDashboardCardSpacing) {
                districtSnapshotSection
                selectedDistrictDetailCard
                recentTrendsCard
                quickLinksCard
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 0)
    }

    private var dashboardHeaderCard: some View {
        DailyDashboardSectionCard(title: "Data Status") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    freshnessSummaryBadge(state: state.freshnessState)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("As of \(state.lastUpdatedText)")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        Text("Build trust first: every block should clearly separate current, estimated, and delayed values.")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    Button(action: refreshDashboard) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(Color.white.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(SatChartPressFeedbackButtonStyle())
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Scope")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.82))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            scopeChip(title: "All Districts", district: nil)

                            ForEach(District.allCases) { district in
                                scopeChip(title: dashboardDistrictLabel(district), district: district)
                            }
                        }
                    }
                }

                LazyVGrid(columns: headerStatusColumns, spacing: 8) {
                    ForEach(state.sourceStatuses) { item in
                        sourceStatusTile(item)
                    }
                }
            }
        }
    }

    private func loaderWarningCard(_ message: String) -> some View {
        DailyDashboardSectionCard(title: "Data Warning") {
            Text(message)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.yellow)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var priorityBannerStack: some View {
        VStack(spacing: 8) {
            ForEach(Array(state.banners.prefix(3))) { banner in
                bannerCard(banner)
            }
        }
    }

    private var openNowCard: some View {
        DailyDashboardSectionCard(title: "Open Now") {
            VStack(spacing: 8) {
                ForEach(visibleOpenNowRows) { row in
                    HStack(alignment: .center, spacing: 10) {
                        Text(dashboardDistrictLabel(row.district))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(width: 92, alignment: .leading)

                        statusPill(row.status)

                        Text(row.hoursText)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.92))
                            .frame(width: 68, alignment: .leading)

                        Text(row.gearText)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.92))
                            .frame(width: 84, alignment: .leading)

                        Spacer(minLength: 0)

                        Text(row.noteText)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.68))
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var districtSnapshotSection: some View {
        DailyDashboardSectionCard(title: "District Snapshot") {
            LazyVGrid(columns: snapshotColumns, spacing: 10) {
                ForEach(visibleDistrictCards) { card in
                    districtSnapshotCard(card)
                }
            }
        }
    }

    private var opportunityNowCard: some View {
        DailyDashboardSectionCard(title: "Opportunity Now") {
            VStack(spacing: 8) {
                ForEach(Array(visibleRankedDistricts.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 10) {
                        Text("#\(index + 1)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.black)
                            .frame(width: 28, height: 28)
                            .background(Color.white)
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(dashboardDistrictLabel(row.district))
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(.white)

                            Text(row.reasonText)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(.white.opacity(0.70))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)

                        Text(row.scoreText)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var selectedDistrictDetailCard: some View {
        DailyDashboardSectionCard(title: "\(dashboardDistrictLabel(activeDetailDistrict)) Detail") {
            if let detail = selectedDetail {
                VStack(alignment: .leading, spacing: 12) {
                    Text(detail.overview)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)

                    detailMetricSection(title: "Operations", metrics: detail.operations)
                    detailMetricSection(title: "Catch", metrics: detail.catchMetrics)
                    detailMetricSection(title: "Run", metrics: detail.runMetrics)
                    detailMetricSection(title: "Pressure", metrics: detail.pressureMetrics)

                    if !detail.watchFlags.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Why It Matters")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundColor(.white)

                            ForEach(detail.watchFlags, id: \.self) { flag in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 5))
                                        .foregroundColor(.white.opacity(0.70))
                                        .padding(.top, 6)

                                    Text(flag)
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        .foregroundColor(.white.opacity(0.78))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        detailActionButton(title: "Open Research", systemImage: "chart.line.uptrend.xyaxis")
                        detailActionButton(title: "View Openings", systemImage: "doc.text")
                    }
                }
            } else {
                Text("Select a district to view deeper operational detail.")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.70))
            }
        }
    }

    private var recentTrendsCard: some View {
        DailyDashboardSectionCard(title: "Recent Trends") {
            VStack(spacing: 10) {
                ForEach(selectedTrendStrips) { strip in
                    trendStripCard(strip)
                }
            }
        }
    }

    private var quickLinksCard: some View {
        DailyDashboardSectionCard(title: "Quick Links") {
            LazyVGrid(columns: quickLinkColumns, spacing: 8) {
                ForEach(state.quickLinks) { link in
                    Button(action: {}) {
                        VStack(spacing: 8) {
                            Image(systemName: link.systemImage)
                                .font(.system(size: 17, weight: .semibold))
                            Text(link.title)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                            if let subtitle = link.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white.opacity(0.70))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                            }
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 78)
                        .padding(.horizontal, 8)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        )
                    }
                    .buttonStyle(SatChartPressFeedbackButtonStyle())
                }
            }
        }
    }

    private var headerStatusColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: isRegularWidth ? 4 : 2)
    }

    private var snapshotColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: isRegularWidth ? 2 : 1)
    }

    private var quickLinkColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: isRegularWidth ? 4 : 2)
    }

    private var detailMetricColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: isRegularWidth ? 4 : 2)
    }

    private func refreshDashboard() {
        Task {
            if let defaultDistrict = await viewModel.load(force: true) {
                selectedDistrict = defaultDistrict
            }
        }
    }

    private func scopeChip(title: String, district: District?) -> some View {
        let isSelected = selectedScopeDistrict == district

        return Button {
            selectedScopeDistrict = district
            if let district {
                selectedDistrict = district
            }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(isSelected ? .black : .white)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(isSelected ? Color.white : Color.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    private func freshnessSummaryBadge(state: DailyDashboardFreshnessState) -> some View {
        VStack(spacing: 6) {
            Image(systemName: state.icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(state.color)

            Text(state.rawValue)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
        .frame(width: 64, height: 58)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(state.color.opacity(0.65), lineWidth: 1)
        )
    }

    private func sourceStatusTile(_ item: DailyDashboardSourceStatusItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(item.state.color)
                    .frame(width: 8, height: 8)

                Text(item.title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }

            Text(item.value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.72))
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func bannerCard(_ banner: DailyDashboardBannerItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: banner.style.icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(banner.style.accent)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(banner.title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.78))

                Text(banner.message)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)

                if !banner.detail.isEmpty {
                    Text(banner.detail)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.68))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(banner.style.accent.opacity(0.70), lineWidth: 1)
        )
    }

    private func districtSnapshotCard(_ card: DailyDashboardDistrictSnapshotCard) -> some View {
        Button {
            selectedDistrict = card.district
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(dashboardDistrictLabel(card.district))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Spacer(minLength: 0)

                    freshnessDot(card.freshness)
                    statusPill(card.status)
                }

                HStack(spacing: 8) {
                    metricTile(title: "Sockeye / Boat", value: card.sockeyePerBoatText)
                    metricTile(title: "Daily Catch", value: card.dailyCatchText)
                }

                HStack(spacing: 8) {
                    metricTile(title: "Passage", value: card.passageText)
                    metricTile(title: "Regs / Boats", value: card.boatsText)
                }

                HStack(spacing: 8) {
                    stateTile(title: "Momentum", value: card.momentumText, tint: card.momentumState.color)
                    stateTile(title: "Pressure", value: card.pressureText, tint: card.pressureState.color)
                }

                HStack(spacing: 8) {
                    Text(card.summaryText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.76))
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Opportunity")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.62))
                        Text(card.opportunityText)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(selectedDistrict == card.district ? 0.12 : 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selectedDistrict == card.district ? Color.white.opacity(0.24) : Color.white.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    private func metricTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.62))
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func stateTile(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.62))

            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)

                Text(value)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func detailMetricSection(title: String, metrics: [DailyDashboardMetricPair]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            LazyVGrid(columns: detailMetricColumns, spacing: 8) {
                ForEach(metrics) { metric in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(metric.label)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.62))

                        Text(metric.value)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    private func detailActionButton(title: String, systemImage: String) -> some View {
        Button(action: {}) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    private func trendStripCard(_ strip: DailyDashboardTrendStripModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(strip.title)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text(strip.subtitle)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.62))
                }

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    Image(systemName: strip.trend.icon)
                        .font(.system(size: 10, weight: .bold))
                    Text(strip.trend.label)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                }
                .foregroundColor(strip.trend.color)
            }

            TrendBarsView(values: strip.values, tint: strip.trend.color)
                .frame(height: 44)
        }
        .padding(10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func freshnessDot(_ state: DailyDashboardFreshnessState) -> some View {
        Circle()
            .fill(state.color)
            .frame(width: 8, height: 8)
    }

    private func statusPill(_ status: DailyDashboardOpenStatus) -> some View {
        Text(status.rawValue)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(status.color)
            .clipShape(Capsule())
    }

    private func dashboardDistrictLabel(_ district: District) -> String {
        district == .naknekKvichak ? "Nak-Kvi" : district.rawValue
    }
}

// MARK: - Shared dashboard section card

private struct DailyDashboardSectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .underline(true, color: Color.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .center)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: dailyDashboardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: dailyDashboardCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

private struct TrendBarsView: View {
    let values: [Double]
    let tint: Color

    private var normalizedValues: [Double] {
        guard let maxValue = values.max(), maxValue > 0 else {
            return values.map { _ in 0.15 }
        }
        return values.map { max($0 / maxValue, 0.15) }
    }

    var body: some View {
        GeometryReader { proxy in
            let count = max(normalizedValues.count, 1)
            let spacing: CGFloat = 6
            let totalSpacing = spacing * CGFloat(max(0, count - 1))
            let width = max((proxy.size.width - totalSpacing) / CGFloat(count), 4)

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(normalizedValues.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(tint.opacity(0.90))
                        .frame(width: width, height: max(proxy.size.height * value, 6))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}
