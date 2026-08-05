import Foundation
import MapKit
import Combine
import CryptoKit

enum SeaSurfaceTemperatureSource: String, CaseIterable, Identifiable, Sendable {
    case gibsMURHighDetail = "coastwatch_mur_1km" // Preserves the stored raw value from older builds.
    case gibsMURSSTAnomaly = "gibs_mur_sst_anomaly"
    case thermalFronts = "thermal_fronts"
    case chlorophyll = "chlorophyll"
    case seaSurfaceHeightAnomaly = "sea_surface_height_anomaly"

    static let selectableCases: [SeaSurfaceTemperatureSource] = [
        .gibsMURHighDetail,
        .gibsMURSSTAnomaly
    ]

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gibsMURHighDetail:
            return "GIBS MUR 1 km SST"
        case .gibsMURSSTAnomaly:
            return "SST anomaly"
        case .thermalFronts:
            return "Thermal fronts"
        case .chlorophyll:
            return "Chlorophyll-a"
        case .seaSurfaceHeightAnomaly:
            return "Sea-surface-height anomaly"
        }
    }

    var shortLabel: String {
        switch self {
        case .gibsMURHighDetail:
            return "MUR"
        case .gibsMURSSTAnomaly:
            return "ΔSST"
        case .thermalFronts:
            return "Fronts"
        case .chlorophyll:
            return "Chl-a"
        case .seaSurfaceHeightAnomaly:
            return "SSH"
        }
    }

    var detail: String {
        switch self {
        case .gibsMURHighDetail:
            return "Daily NASA GIBS browse layer for the GHRSST Level 4 JPL MUR Global Foundation SST analysis on a 0.01° (~1 km) grid. This is the default browse SST layer and is useful for spotting fine-scale temperature structure and day-to-day change."
        case .gibsMURSSTAnomaly:
            return "Daily NASA GIBS MUR sea-surface-temperature anomaly. Values are referenced to the day-of-year average from the 2003–2014 MUR climatology, so positive values are warmer than baseline and negative values are cooler."
        case .thermalFronts:
            return "NOAA ACSPO daily thermal-front strength from the global 0.02° super-collated SST and fronts reanalysis. This highlights sharp SST gradients and front structure."
        case .chlorophyll:
            return "Daily NASA GIBS Sentinel-3A OLCI chlorophyll-a browse layer. Useful for spotting productivity, plume edges, and biological structure."
        case .seaSurfaceHeightAnomaly:
            return "NOAA daily sea-surface-height anomaly from merged satellite altimetry. Useful for spotting eddies, slope structure, and broader circulation patterns."
        }
    }

    fileprivate enum Backend {
        case coastWatch(datasetID: String, layerName: String, timeOfDayUTC: String)
        case gibs(layerIdentifier: String, matrixSets: [SeaSurfaceTemperatureMatrixSet])
    }

    fileprivate var backend: Backend {
        switch self {
        case .gibsMURHighDetail:
            return .gibs(
                layerIdentifier: "GHRSST_L4_MUR_Sea_Surface_Temperature",
                matrixSets: [
                    SeaSurfaceTemperatureMatrixSet(identifier: "GoogleMapsCompatible_Level6", maxZoom: 6),
                    SeaSurfaceTemperatureMatrixSet(identifier: "GoogleMapsCompatible_Level7", maxZoom: 7),
                    SeaSurfaceTemperatureMatrixSet(identifier: "GoogleMapsCompatible_Level8", maxZoom: 8),
                    SeaSurfaceTemperatureMatrixSet(identifier: "GoogleMapsCompatible_Level9", maxZoom: 9),
                    SeaSurfaceTemperatureMatrixSet(identifier: "GoogleMapsCompatible_Level10", maxZoom: 10),
                    SeaSurfaceTemperatureMatrixSet(identifier: "GoogleMapsCompatible_Level11", maxZoom: 11),
                    SeaSurfaceTemperatureMatrixSet(identifier: "GoogleMapsCompatible_Level12", maxZoom: 12)
                ]
            )
        case .gibsMURSSTAnomaly:
            return .gibs(
                layerIdentifier: "GHRSST_L4_MUR_Sea_Surface_Temperature_Anomalies",
                matrixSets: [
                    SeaSurfaceTemperatureMatrixSet(identifier: "GoogleMapsCompatible_Level6", maxZoom: 6),
                    SeaSurfaceTemperatureMatrixSet(identifier: "GoogleMapsCompatible_Level7", maxZoom: 7),
                    SeaSurfaceTemperatureMatrixSet(identifier: "GoogleMapsCompatible_Level8", maxZoom: 8),
                    SeaSurfaceTemperatureMatrixSet(identifier: "GoogleMapsCompatible_Level9", maxZoom: 9),
                    SeaSurfaceTemperatureMatrixSet(identifier: "GoogleMapsCompatible_Level10", maxZoom: 10),
                    SeaSurfaceTemperatureMatrixSet(identifier: "GoogleMapsCompatible_Level11", maxZoom: 11),
                    SeaSurfaceTemperatureMatrixSet(identifier: "GoogleMapsCompatible_Level12", maxZoom: 12)
                ]
            )
        case .thermalFronts:
            return .coastWatch(
                datasetID: "noaacwLEOACSPOSSTL3SCDaily",
                layerName: "sst_gradient_magnitude",
                timeOfDayUTC: "12:00:00Z"
            )
        case .chlorophyll:
            return .gibs(
                layerIdentifier: "S3A_OLCI_Chlorophyll_a",
                matrixSets: [
                    SeaSurfaceTemperatureMatrixSet(identifier: "GoogleMapsCompatible_Level6", maxZoom: 6),
                    SeaSurfaceTemperatureMatrixSet(identifier: "GoogleMapsCompatible_Level7", maxZoom: 7),
                    SeaSurfaceTemperatureMatrixSet(identifier: "GoogleMapsCompatible_Level8", maxZoom: 8)
                ]
            )
        case .seaSurfaceHeightAnomaly:
            return .coastWatch(
                datasetID: "noaacwBLENDEDsshDaily",
                layerName: "sla",
                timeOfDayUTC: "00:00:00Z"
            )
        }
    }

    fileprivate var minDateUTC: String {
        switch self {
        case .gibsMURHighDetail:
            return "2002-06-01"
        case .gibsMURSSTAnomaly:
            return "2019-07-23"
        case .thermalFronts:
            return "2000-02-24"
        case .chlorophyll:
            return "2016-04-05"
        case .seaSurfaceHeightAnomaly:
            return "2015-01-15"
        }
    }

    var recommendedMaximumZ: Int {
        switch self {
        case .gibsMURHighDetail, .gibsMURSSTAnomaly:
            return 9
        case .thermalFronts, .chlorophyll:
            return 8
        case .seaSurfaceHeightAnomaly:
            return 7
        }
    }

    fileprivate var latestDateFallbackLagDays: Int {
        switch self {
        case .gibsMURHighDetail, .gibsMURSSTAnomaly:
            return 2
        case .thermalFronts, .seaSurfaceHeightAnomaly:
            return 2
        case .chlorophyll:
            return 3
        }
    }

    fileprivate var availabilityCacheTTL: TimeInterval {
        6 * 60 * 60
    }

    fileprivate var availabilityURLs: [URL] {
        switch backend {
        case .coastWatch(let datasetID, _, _):
            return [
                URL(string: "https://coastwatch.noaa.gov/erddap/info/\(datasetID)/index.html")!,
                URL(string: "https://coastwatch.noaa.gov/erddap/wms/\(datasetID)/request?service=WMS&request=GetCapabilities&version=1.3.0")!
            ]
        case .gibs(let layerIdentifier, let matrixSets):
            let describeDomains = matrixSets.map { matrixSet in
                URL(string: "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/wmts.cgi?SERVICE=WMTS&REQUEST=DescribeDomains&VERSION=1.0.0&LAYER=\(layerIdentifier)&TILEMATRIXSET=\(matrixSet.identifier)&TIME=all")!
            }
            return describeDomains + [
                URL(string: "https://gibs.earthdata.nasa.gov/layer-metadata/v1.0/\(layerIdentifier).json")!
            ]
        }
    }

    fileprivate func fallbackSource(for _: String) -> SeaSurfaceTemperatureSource? {
        nil
    }

    fileprivate var usesGIBSAvailability: Bool {
        if case .gibs = backend { return true }
        return false
    }
}

fileprivate struct SeaSurfaceTemperatureMatrixSet: Sendable {
    let identifier: String
    let maxZoom: Int
}

fileprivate struct SeaSurfaceTemperatureTileCandidate {
    let cacheKey: String
    let url: URL
    let backendKey: String
}

fileprivate struct SeaSurfaceTemperatureTilePlan {
    let coalescingKey: String
    let primaryCandidates: [SeaSurfaceTemperatureTileCandidate]
    let fallbackCandidates: [SeaSurfaceTemperatureTileCandidate]
}

final class SeaSurfaceTemperatureOverlay: MKTileOverlay {

    private static let tileStore = SeaSurfaceTemperatureTileStore.shared

    let source: SeaSurfaceTemperatureSource
    let dateUTC: String

    init(
        source: SeaSurfaceTemperatureSource = .gibsMURHighDetail,
        dateUTC: String = SeaSurfaceTemperatureOverlay.defaultDateUTC()
    ) {
        self.source = source
        self.dateUTC = SeaSurfaceTemperatureOverlay.clampedDateUTC(dateUTC, for: source)
        super.init(urlTemplate: nil)

        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0
        maximumZ = source.recommendedMaximumZ
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let plan = Self.tilePlan(source: source, dateUTC: dateUTC, path: path)
        return plan.primaryCandidates.first?.url
            ?? plan.fallbackCandidates.first?.url
            ?? URL(string: "about:blank")!
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let plan = Self.tilePlan(source: source, dateUTC: dateUTC, path: path)
        Self.tileStore.loadTile(plan: plan, result: result)
    }

    private static func tilePlan(
        source: SeaSurfaceTemperatureSource,
        dateUTC: String,
        path: MKTileOverlayPath
    ) -> SeaSurfaceTemperatureTilePlan {
        let coalescingKey = canonicalCoalescingKey(source: source, dateUTC: dateUTC, path: path)

        switch source.backend {
        case .coastWatch:
            return SeaSurfaceTemperatureTilePlan(
                coalescingKey: coalescingKey,
                primaryCandidates: coastWatchCandidate(source: source, dateUTC: dateUTC, path: path).map { [$0] } ?? [],
                fallbackCandidates: []
            )

        case .gibs(_, let matrixSets):
            let primaryCandidates = gibsCandidates(source: source, dateUTC: dateUTC, path: path, matrixSets: matrixSets)
            let fallbackCandidates: [SeaSurfaceTemperatureTileCandidate]
            if let fallbackSource = source.fallbackSource(for: dateUTC) {
                let fallbackDateUTC = clampedDateUTC(dateUTC, for: fallbackSource)
                fallbackCandidates = coastWatchCandidate(source: fallbackSource, dateUTC: fallbackDateUTC, path: path).map { [$0] } ?? []
            } else {
                fallbackCandidates = []
            }

            return SeaSurfaceTemperatureTilePlan(
                coalescingKey: coalescingKey,
                primaryCandidates: primaryCandidates,
                fallbackCandidates: fallbackCandidates
            )
        }
    }

    private static func canonicalCoalescingKey(
        source: SeaSurfaceTemperatureSource,
        dateUTC: String,
        path: MKTileOverlayPath
    ) -> String {
        let scale = max(1, Int(path.contentScaleFactor.rounded()))
        return "\(source.rawValue)|\(dateUTC)|z\(path.z)|x\(path.x)|y\(path.y)|s\(scale)|v4"
    }

    private static func coastWatchCandidate(
        source: SeaSurfaceTemperatureSource,
        dateUTC: String,
        path: MKTileOverlayPath
    ) -> SeaSurfaceTemperatureTileCandidate? {
        let scale = max(1, Int(path.contentScaleFactor.rounded()))
        let pixelSize = Int(256 * scale)
        let bounds = geographicBounds(for: path)

        guard case .coastWatch(let datasetID, let layerName, let timeOfDayUTC) = source.backend else {
            assertionFailure("CoastWatch candidate requested for non-CoastWatch source")
            return nil
        }

        let serviceURL = URL(string: "https://coastwatch.noaa.gov/erddap/wms/\(datasetID)/request")!
        var components = URLComponents(url: serviceURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "service", value: "WMS"),
            URLQueryItem(name: "version", value: "1.3.0"),
            URLQueryItem(name: "request", value: "GetMap"),
            URLQueryItem(name: "crs", value: "EPSG:4326"),
            URLQueryItem(
                name: "bbox",
                value: "\(format(bounds.minLat)),\(format(bounds.minLon)),\(format(bounds.maxLat)),\(format(bounds.maxLon))"
            ),
            URLQueryItem(name: "width", value: "\(pixelSize)"),
            URLQueryItem(name: "height", value: "\(pixelSize)"),
            URLQueryItem(name: "format", value: "image/png"),
            URLQueryItem(name: "transparent", value: "TRUE"),
            URLQueryItem(name: "exceptions", value: "XML"),
            URLQueryItem(name: "layers", value: "\(datasetID):\(layerName)"),
            URLQueryItem(name: "styles", value: ""),
            URLQueryItem(name: "time", value: "\(dateUTC)T\(timeOfDayUTC)")
        ]

        let cacheKey = "cw|\(source.rawValue)|\(dateUTC)|z\(path.z)|x\(path.x)|y\(path.y)|s\(scale)|v4"
        return SeaSurfaceTemperatureTileCandidate(
            cacheKey: cacheKey,
            url: components.url!,
            backendKey: "cw:\(datasetID):\(layerName)"
        )
    }

    private static func gibsCandidates(
        source: SeaSurfaceTemperatureSource,
        dateUTC: String,
        path: MKTileOverlayPath,
        matrixSets: [SeaSurfaceTemperatureMatrixSet]
    ) -> [SeaSurfaceTemperatureTileCandidate] {
        guard case .gibs(let layerIdentifier, _) = source.backend else {
            return []
        }

        let availableMatrixSets = matrixSets.filter { path.z <= $0.maxZoom }
        let chosenMatrixSets = availableMatrixSets.isEmpty ? matrixSets : availableMatrixSets

        return chosenMatrixSets.map { matrixSet in
            let urlString = "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/\(layerIdentifier)/default/\(dateUTC)/\(matrixSet.identifier)/\(path.z)/\(path.y)/\(path.x).png"
            return SeaSurfaceTemperatureTileCandidate(
                cacheKey: "gibs|\(source.rawValue)|\(matrixSet.identifier)|\(dateUTC)|z\(path.z)|x\(path.x)|y\(path.y)|v4",
                url: URL(string: urlString)!,
                backendKey: "gibs:\(layerIdentifier):\(matrixSet.identifier)"
            )
        }
    }

    static func defaultDateUTC(reference: Date = Date()) -> String {
        latestAllowedDateUTC(for: .gibsMURHighDetail, reference: reference)
    }

    static func latestAvailableDateUTC(for source: SeaSurfaceTemperatureSource, reference: Date = Date()) -> String {
        SeaSurfaceTemperatureAvailabilityCache.bestKnownLatestDate(for: source)
            ?? latestFallbackDateUTC(for: source, reference: reference)
    }

    static func latestFallbackDateUTC(for source: SeaSurfaceTemperatureSource, reference: Date = Date()) -> String {
        let calendar = utcCalendar()
        let safeDate = calendar.date(byAdding: .day, value: -source.latestDateFallbackLagDays, to: reference) ?? reference
        return normalizedUTCDateString(from: safeDate)
    }

    static func latestAllowedDateUTC(
        for source: SeaSurfaceTemperatureSource,
        latestAvailableUTC: String? = nil,
        reference: Date = Date()
    ) -> String {
        clampedDateUTC(
            latestAvailableUTC ?? latestAvailableDateUTC(for: source, reference: reference),
            for: source,
            latestAvailableUTC: latestAvailableUTC,
            reference: reference
        )
    }

    static func clampedDateUTC(
        _ dateUTC: String,
        for source: SeaSurfaceTemperatureSource,
        latestAvailableUTC: String? = nil,
        reference: Date = Date()
    ) -> String {
        let minimum = source.minDateUTC
        let maximum = latestAvailableUTC ?? latestAvailableDateUTC(for: source, reference: reference)
        let candidate = isValidUTCDateString(dateUTC) ? dateUTC : maximum
        return min(max(candidate, minimum), maximum)
    }

    static func displayDateRange(
        for source: SeaSurfaceTemperatureSource,
        latestAvailableUTC: String? = nil,
        reference: Date = Date()
    ) -> ClosedRange<Date> {
        let lower = displayDate(
            forUTCDate: source.minDateUTC,
            source: source,
            latestAvailableUTC: latestAvailableUTC,
            reference: reference
        )
        let upper = displayDate(
            forUTCDate: latestAllowedDateUTC(
                for: source,
                latestAvailableUTC: latestAvailableUTC,
                reference: reference
            ),
            source: source,
            latestAvailableUTC: latestAvailableUTC,
            reference: reference
        )
        return lower...upper
    }

    static func displayDate(
        forUTCDate dateUTC: String,
        source: SeaSurfaceTemperatureSource,
        latestAvailableUTC: String? = nil,
        reference: Date = Date()
    ) -> Date {
        middayUTCDate(
            from: clampedDateUTC(
                dateUTC,
                for: source,
                latestAvailableUTC: latestAvailableUTC,
                reference: reference
            )
        )
        ?? middayUTCDate(from: source.minDateUTC)
        ?? Date()
    }

    static func utcDateString(
        fromDisplayDate date: Date,
        for source: SeaSurfaceTemperatureSource,
        latestAvailableUTC: String? = nil,
        reference: Date = Date()
    ) -> String {
        clampedDateUTC(
            normalizedUTCDateString(from: date),
            for: source,
            latestAvailableUTC: latestAvailableUTC,
            reference: reference
        )
    }

    static func shiftDateUTC(
        _ dateUTC: String,
        byDays days: Int,
        for source: SeaSurfaceTemperatureSource,
        latestAvailableUTC: String? = nil,
        reference: Date = Date()
    ) -> String {
        let calendar = utcCalendar()
        let baseDate = middayUTCDate(
            from: clampedDateUTC(
                dateUTC,
                for: source,
                latestAvailableUTC: latestAvailableUTC,
                reference: reference
            )
        ) ?? reference
        let shifted = calendar.date(byAdding: .day, value: days, to: baseDate) ?? baseDate
        return clampedDateUTC(
            normalizedUTCDateString(from: shifted),
            for: source,
            latestAvailableUTC: latestAvailableUTC,
            reference: reference
        )
    }

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = utcCalendar()
        formatter.timeZone = formatter.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func middayUTCDate(from dateUTC: String) -> Date? {
        let formatter = dateFormatter()
        guard let midnight = formatter.date(from: dateUTC) else { return nil }
        let components = utcCalendar().dateComponents([.year, .month, .day], from: midnight)
        return utcCalendar().date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: components.year,
            month: components.month,
            day: components.day,
            hour: 12
        ))
    }

    private static func normalizedUTCDateString(from date: Date) -> String {
        let components = utcCalendar().dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return latestFallbackDateUTC(for: .gibsMURHighDetail, reference: date)
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func isValidUTCDateString(_ value: String) -> Bool {
        dateFormatter().date(from: value) != nil
    }

    private static func geographicBounds(for path: MKTileOverlayPath) -> (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) {
        let minLon = tileXToLongitude(path.x, z: path.z)
        let maxLon = tileXToLongitude(path.x + 1, z: path.z)
        let maxLat = tileYToLatitude(path.y, z: path.z)
        let minLat = tileYToLatitude(path.y + 1, z: path.z)
        return (minLat, minLon, maxLat, maxLon)
    }

    private static func tileXToLongitude(_ x: Int, z: Int) -> Double {
        let n = Double(1 << z)
        return (Double(x) / n) * 360.0 - 180.0
    }

    private static func tileYToLatitude(_ y: Int, z: Int) -> Double {
        let n = Double(1 << z)
        let mercator = .pi - (2.0 * .pi * Double(y) / n)
        return atan(sinh(mercator)) * 180.0 / .pi
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}

@MainActor
final class SeaSurfaceTemperatureAvailabilityStore: ObservableObject {
    @Published private var latestAvailableDates: [SeaSurfaceTemperatureSource: String]
    @Published private var refreshingSources: Set<SeaSurfaceTemperatureSource>
    @Published private var errorMessages: [SeaSurfaceTemperatureSource: String]

    init() {
        var initialLatest: [SeaSurfaceTemperatureSource: String] = [:]
        for source in SeaSurfaceTemperatureSource.allCases {
            if let cached = SeaSurfaceTemperatureAvailabilityCache.bestKnownLatestDate(for: source) {
                initialLatest[source] = cached
            }
        }
        self.latestAvailableDates = initialLatest
        self.refreshingSources = []
        self.errorMessages = [:]
    }

    func latestAvailableDate(for source: SeaSurfaceTemperatureSource) -> String? {
        latestAvailableDates[source] ?? SeaSurfaceTemperatureAvailabilityCache.bestKnownLatestDate(for: source)
    }

    func latestAvailableOrFallback(for source: SeaSurfaceTemperatureSource) -> String {
        latestAvailableDate(for: source)
            ?? SeaSurfaceTemperatureOverlay.latestFallbackDateUTC(for: source)
    }

    func isRefreshing(_ source: SeaSurfaceTemperatureSource) -> Bool {
        refreshingSources.contains(source)
    }

    func lastErrorMessage(for source: SeaSurfaceTemperatureSource) -> String? {
        errorMessages[source]
    }

    func refreshIfNeeded(for source: SeaSurfaceTemperatureSource, force: Bool = false) {
        if !force {
            if let cached = SeaSurfaceTemperatureAvailabilityCache.record(for: source),
               Date().timeIntervalSince(cached.fetchedAt) < source.availabilityCacheTTL {
                latestAvailableDates[source] = cached.latestDateUTC
                errorMessages[source] = nil
                return
            }

            if refreshingSources.contains(source) {
                return
            }
        }

        refreshingSources.insert(source)

        Task {
            let latest = await SeaSurfaceTemperatureAvailabilityService.shared.fetchLatestAvailableDate(for: source, force: force)

            await MainActor.run {
                refreshingSources.remove(source)

                if let latest {
                    latestAvailableDates[source] = latest
                    errorMessages[source] = nil
                } else if latestAvailableDates[source] == nil {
                    if source.usesGIBSAvailability {
                        errorMessages[source] = "Couldn’t verify the newest NASA published day right now. Using a conservative recent fallback so the layer stays usable."
                    } else {
                        errorMessages[source] = "Couldn’t verify the newest published day right now. Using a safe fallback so the layer stays usable."
                    }
                } else {
                    errorMessages[source] = "Couldn’t refresh just now. Keeping the last verified availability."
                }
            }
        }
    }
}

fileprivate struct SeaSurfaceTemperatureAvailabilityRecord: Codable {
    let latestDateUTC: String
    let fetchedAt: Date
}

fileprivate enum SeaSurfaceTemperatureAvailabilityCache {
    private static let defaults = UserDefaults.standard
    private static let prefix = "SeaSurfaceTemperatureOverlay.latestAvailable."

    fileprivate static func record(for source: SeaSurfaceTemperatureSource) -> SeaSurfaceTemperatureAvailabilityRecord? {
        guard let data = defaults.data(forKey: key(for: source)) else { return nil }
        return try? JSONDecoder().decode(SeaSurfaceTemperatureAvailabilityRecord.self, from: data)
    }

    fileprivate static func bestKnownLatestDate(for source: SeaSurfaceTemperatureSource) -> String? {
        record(for: source)?.latestDateUTC
    }

    fileprivate static func save(latestDateUTC: String, for source: SeaSurfaceTemperatureSource, fetchedAt: Date = Date()) {
        let record = SeaSurfaceTemperatureAvailabilityRecord(latestDateUTC: latestDateUTC, fetchedAt: fetchedAt)
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key(for: source))
    }

    private static func key(for source: SeaSurfaceTemperatureSource) -> String {
        prefix + source.rawValue
    }
}

fileprivate actor SeaSurfaceTemperatureAvailabilityService {
    static let shared = SeaSurfaceTemperatureAvailabilityService()

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private var inFlightTasks: [SeaSurfaceTemperatureSource: Task<String?, Never>] = [:]

    func fetchLatestAvailableDate(
        for source: SeaSurfaceTemperatureSource,
        force: Bool = false
    ) async -> String? {
        if !force {
            let (cached, cacheTTL): (SeaSurfaceTemperatureAvailabilityRecord?, TimeInterval) = await MainActor.run {
                (
                    SeaSurfaceTemperatureAvailabilityCache.record(for: source),
                    source.availabilityCacheTTL
                )
            }

            if let cached,
               Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
                return cached.latestDateUTC
            }
        }

        if let inFlight = inFlightTasks[source] {
            return await inFlight.value
        }

        let task = Task<String?, Never> { [source] in
            await self.fetchLatestAvailableDateUncached(for: source)
        }
        inFlightTasks[source] = task
        let value = await task.value
        inFlightTasks[source] = nil
        return value
    }

    private func fetchLatestAvailableDateUncached(
        for source: SeaSurfaceTemperatureSource
    ) async -> String? {
        let (candidateURLs, usesGIBSAvailability): ([URL], Bool) = await MainActor.run {
            (
                source.availabilityURLs,
                source.usesGIBSAvailability
            )
        }

        for url in candidateURLs {
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    continue
                }

                let text = String(decoding: data, as: UTF8.self)
                if let parsed = parseLatestDateUTC(from: text, usesGIBSAvailability: usesGIBSAvailability) {
                    await MainActor.run {
                        SeaSurfaceTemperatureAvailabilityCache.save(latestDateUTC: parsed, for: source)
                    }
                    return parsed
                }
            } catch {
                continue
            }
        }

        return nil
    }

    private func parseLatestDateUTC(from text: String, usesGIBSAvailability: Bool) -> String? {
        if usesGIBSAvailability {
            return parseGIBSLatestDateUTC(from: text)
        } else {
            return parseCoastWatchLatestDateUTC(from: text)
        }
    }

    private func parseCoastWatchLatestDateUTC(from text: String) -> String? {
        if let infoMatch = firstMatch(
            in: text,
            pattern: #"time_coverage_end\s+String\s+([0-9]{4}-[0-9]{2}-[0-9]{2})T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"#
        ) {
            return infoMatch
        }

        if let extentMatch = firstMatch(
            in: text,
            pattern: #"([0-9]{4}-[0-9]{2}-[0-9]{2})T[0-9]{2}:[0-9]{2}:[0-9]{2}Z</Extent>"#
        ) {
            return extentMatch
        }

        let allDates = allMatches(
            in: text,
            pattern: #"([0-9]{4}-[0-9]{2}-[0-9]{2})T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"#
        )
        return allDates.last
    }

    private func parseGIBSLatestDateUTC(from text: String) -> String? {
        if let domain = firstMatch(
            in: text,
            pattern: #"<Domain>\s*([^<]+?)\s*</Domain>"#,
            options: [.dotMatchesLineSeparators]
        ), let latest = latestDateInGIBSDomain(domain) {
            return latest
        }

        if let extentEnd = firstMatch(
            in: text,
            pattern: #">[0-9]{4}-[0-9]{2}-[0-9]{2}/([0-9]{4}-[0-9]{2}-[0-9]{2})/P1D<"#,
            options: [.dotMatchesLineSeparators]
        ) {
            return extentEnd
        }

        let allDates = allMatches(
            in: text,
            pattern: #"([0-9]{4}-[0-9]{2}-[0-9]{2})"#,
            options: [.dotMatchesLineSeparators]
        )
        return allDates.last
    }

    private func latestDateInGIBSDomain(_ domain: String) -> String? {
        let segments = domain
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for segment in segments.reversed() {
            if segment == "all" { continue }

            let pieces = segment.split(separator: "/").map { String($0) }
            if pieces.count >= 2,
               isValidUTCDateString(pieces[1]) {
                return pieces[1]
            }

            if let exactDate = pieces.first, isValidUTCDateString(exactDate) {
                return exactDate
            }
        }

        return nil
    }

    private func isValidUTCDateString(_ value: String) -> Bool {
        let formatter = DateFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value) != nil
    }

    private func firstMatch(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    private func allMatches(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[captureRange])
        }
    }
}

fileprivate final class SeaSurfaceTemperatureTileStore {
    static let shared = SeaSurfaceTemperatureTileStore()

    private let memoryCache = NSCache<NSString, NSData>()
    private let session: URLSession
    private let rootDirectory: URL
    private let lock = NSLock()
    private var inFlight: [String: [(Data?, Error?) -> Void]] = [:]
    private var backendBlockedUntil: [String: Date] = [:]

    private init() {
        memoryCache.totalCostLimit = 96 * 1024 * 1024
        memoryCache.countLimit = 1200

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)

        let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        rootDirectory = cachesRoot.appendingPathComponent("SeaSurfaceTemperatureTiles/v4", isDirectory: true)

        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true, attributes: nil)
    }

    fileprivate func loadTile(plan: SeaSurfaceTemperatureTilePlan, result: @escaping (Data?, Error?) -> Void) {
        if let cached = firstCached(in: plan.primaryCandidates) {
            result(cached, nil)
            return
        }

        if allCandidatesAreTemporarilyBlocked(plan.primaryCandidates),
           let cachedFallback = firstCached(in: plan.fallbackCandidates) {
            result(cachedFallback, nil)
            return
        }

        lock.lock()
        if var callbacks = inFlight[plan.coalescingKey] {
            callbacks.append(result)
            inFlight[plan.coalescingKey] = callbacks
            lock.unlock()
            return
        } else {
            inFlight[plan.coalescingKey] = [result]
            lock.unlock()
        }

        fetchPrimaryCandidates(
            Array(plan.primaryCandidates.enumerated()),
            fallbackCandidates: Array(plan.fallbackCandidates.enumerated()),
            coalescingKey: plan.coalescingKey,
            lastError: nil
        )
    }

    private func fetchPrimaryCandidates(
        _ enumeratedCandidates: [(offset: Int, element: SeaSurfaceTemperatureTileCandidate)],
        fallbackCandidates: [(offset: Int, element: SeaSurfaceTemperatureTileCandidate)],
        coalescingKey: String,
        lastError: Error?
    ) {
        if let next = nextCandidate(from: enumeratedCandidates) {
            let remaining = enumeratedCandidates.filter { $0.offset > next.offset }
            fetchCandidate(next.element, coalescingKey: coalescingKey) { [weak self] success, error in
                guard let self else { return }
                if success { return }
                self.fetchPrimaryCandidates(
                    remaining,
                    fallbackCandidates: fallbackCandidates,
                    coalescingKey: coalescingKey,
                    lastError: error ?? lastError
                )
            }
            return
        }

        if let cachedFallback = firstCached(in: fallbackCandidates.map(\.element)) {
            finish(coalescingKey: coalescingKey, data: cachedFallback, error: nil)
            return
        }

        fetchFallbackCandidates(fallbackCandidates, coalescingKey: coalescingKey, lastError: lastError)
    }

    private func fetchFallbackCandidates(
        _ enumeratedCandidates: [(offset: Int, element: SeaSurfaceTemperatureTileCandidate)],
        coalescingKey: String,
        lastError: Error?
    ) {
        if let next = nextCandidate(from: enumeratedCandidates) {
            let remaining = enumeratedCandidates.filter { $0.offset > next.offset }
            fetchCandidate(next.element, coalescingKey: coalescingKey) { [weak self] success, error in
                guard let self else { return }
                if success { return }
                self.fetchFallbackCandidates(
                    remaining,
                    coalescingKey: coalescingKey,
                    lastError: error ?? lastError
                )
            }
            return
        }

        finish(
            coalescingKey: coalescingKey,
            data: nil,
            error: lastError ?? NSError(
                domain: "SeaSurfaceTemperatureTileStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No ocean-layer tile data returned."]
            )
        )
    }

    private func nextCandidate(
        from enumeratedCandidates: [(offset: Int, element: SeaSurfaceTemperatureTileCandidate)]
    ) -> (offset: Int, element: SeaSurfaceTemperatureTileCandidate)? {
        if let firstUnblocked = enumeratedCandidates.first(where: { !isBackendTemporarilyBlocked($0.element.backendKey) }) {
            return firstUnblocked
        }
        return enumeratedCandidates.first
    }

    private func fetchCandidate(
        _ candidate: SeaSurfaceTemperatureTileCandidate,
        coalescingKey: String,
        completion: @escaping (Bool, Error?) -> Void
    ) {
        if let cached = loadFromCache(cacheKey: candidate.cacheKey) {
            finish(coalescingKey: coalescingKey, data: cached, error: nil)
            completion(true, nil)
            return
        }

        var request = URLRequest(url: candidate.url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("image/png,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("SatChartApp-OceanLayers/1.0", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else {
                completion(false, error)
                return
            }

            if let validated = self.validatedImageData(data, response: response) {
                self.clearBackendBlock(candidate.backendKey)
                self.storeInCache(validated, cacheKey: candidate.cacheKey)
                self.finish(coalescingKey: coalescingKey, data: validated, error: nil)
                completion(true, nil)
                return
            }

            self.blockBackend(candidate.backendKey, response: response, error: error)
            completion(false, error ?? NSError(
                domain: "SeaSurfaceTemperatureTileStore",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid SST tile response."]
            ))
        }.resume()
    }

    private func firstCached(in candidates: [SeaSurfaceTemperatureTileCandidate]) -> Data? {
        for candidate in candidates {
            if let data = loadFromCache(cacheKey: candidate.cacheKey) {
                return data
            }
        }
        return nil
    }

    private func loadFromCache(cacheKey: String) -> Data? {
        let nsKey = cacheKey as NSString
        if let cached = memoryCache.object(forKey: nsKey) {
            return cached as Data
        }

        if let diskData = loadFromDisk(cacheKey: cacheKey) {
            memoryCache.setObject(diskData as NSData, forKey: nsKey, cost: diskData.count)
            return diskData
        }

        return nil
    }

    private func storeInCache(_ data: Data, cacheKey: String) {
        memoryCache.setObject(data as NSData, forKey: cacheKey as NSString, cost: data.count)
        storeOnDisk(data, cacheKey: cacheKey)
    }

    private func allCandidatesAreTemporarilyBlocked(_ candidates: [SeaSurfaceTemperatureTileCandidate]) -> Bool {
        guard !candidates.isEmpty else { return false }
        return candidates.allSatisfy { isBackendTemporarilyBlocked($0.backendKey) }
    }

    private func isBackendTemporarilyBlocked(_ backendKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let blockedUntil = backendBlockedUntil[backendKey] else { return false }
        if blockedUntil <= Date() {
            backendBlockedUntil.removeValue(forKey: backendKey)
            return false
        }
        return true
    }

    private func clearBackendBlock(_ backendKey: String) {
        lock.lock()
        backendBlockedUntil.removeValue(forKey: backendKey)
        lock.unlock()
    }

    private func blockBackend(_ backendKey: String, response: URLResponse?, error: Error?) {
        let duration = backendBlockDuration(response: response, error: error)
        lock.lock()
        backendBlockedUntil[backendKey] = Date().addingTimeInterval(duration)
        lock.unlock()
    }

    private func backendBlockDuration(response: URLResponse?, error: Error?) -> TimeInterval {
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 404, 410:
                return 30 * 60
            case 400, 401, 403:
                return 20 * 60
            case 429:
                return 2 * 60
            case 500...599:
                return 90
            default:
                break
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
                return 60
            default:
                break
            }
        }

        return 10 * 60
    }

    private func finish(coalescingKey: String, data: Data?, error: Error?) {
        let callbacks: [(Data?, Error?) -> Void]
        lock.lock()
        callbacks = inFlight.removeValue(forKey: coalescingKey) ?? []
        lock.unlock()

        for callback in callbacks {
            callback(data, error)
        }
    }

    private func validatedImageData(_ data: Data?, response: URLResponse?) -> Data? {
        guard let data, !data.isEmpty else { return nil }

        if let http = response as? HTTPURLResponse {
            guard (200...299).contains(http.statusCode) else { return nil }

            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if contentType.contains("image/png") {
                return data
            }

            if contentType.contains("xml") || contentType.contains("html") || contentType.contains("text") {
                return nil
            }
        }

        return Self.looksLikePNG(data) ? data : nil
    }

    private static func looksLikePNG(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        return Array(data.prefix(8)) == signature
    }

    private func storeOnDisk(_ data: Data, cacheKey: String) {
        let url = cacheFileURL(for: cacheKey)
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadFromDisk(cacheKey: String) -> Data? {
        let url = cacheFileURL(for: cacheKey)
        return try? Data(contentsOf: url)
    }

    private func cacheFileURL(for cacheKey: String) -> URL {
        let digest = SHA256.hash(data: Data(cacheKey.utf8))
        let fileName = digest.map { String(format: "%02x", $0) }.joined() + ".png"
        return rootDirectory.appendingPathComponent(fileName)
    }
}

typealias GIBSSSTOverlay = SeaSurfaceTemperatureOverlay
