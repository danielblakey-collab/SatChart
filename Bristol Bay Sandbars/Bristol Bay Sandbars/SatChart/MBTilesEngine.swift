import Foundation
import Darwin
import MapKit
import SQLite3
import CoreGraphics
import CoreImage
import ImageIO
import UIKit
import os

nonisolated(unsafe) private let mbtilesSQLiteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

nonisolated enum MBTilesStorageScheme: String, Codable, Hashable, Sendable {
    case tms
    case xyz

    /// MBTiles defaults to TMS when `metadata.scheme` is absent. SatChart's legacy
    /// packages depend on that rule, so a missing value must never be guessed from data.
    static func metadataValue(_ rawValue: String?) throws -> MBTilesStorageScheme {
        guard let rawValue else { return .tms }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "tms": return .tms
        case "xyz": return .xyz
        default: throw MBTilesError.unsupportedScheme(rawValue)
        }
    }

    /// One shipped legacy object predates scheme metadata but stores XYZ rows.
    /// Keep this explicit and package-scoped; all other missing values follow the
    /// MBTiles legacy TMS default and are never inferred from geography.
    static func explicitLegacyOverride(forPackageSlug slug: String) -> MBTilesStorageScheme? {
        slug.lowercased() == "egegik_v2" ? .xyz : nil
    }
}

nonisolated enum MBTilesLayerRole: String, Codable, Hashable, Sendable {
    case basemap
    case district
    case shoreline

    static func inferred(from slug: String) -> MBTilesLayerRole {
        if [
            "egegik_to_ugashik_shoreline",
            "naknek_to_egegik_shoreline",
            "naknek_to_nushagak_shoreline"
        ].contains(slug) { return .shoreline }
        if ["naknek_kvichak", "egegik", "ugashik", "nushagak", "togiak"].contains(where: {
            slug == $0 || slug.hasPrefix("\($0)_v")
        }) { return .district }
        return .basemap
    }
}

/// Values which can materially change the bytes returned for a tile. Installed map
/// files are immutable; version changes therefore produce a new identity and session.
nonisolated struct MBTilesOverlayIdentity: Hashable, Sendable, CustomStringConvertible {
    let role: MBTilesLayerRole
    let packageIdentifier: String
    let packageVersion: String
    let canonicalPath: String
    let storageSchemePolicy: String
    let storageSchemeOverride: MBTilesStorageScheme?
    let tileSizePixels: Int
    let minimumZoom: Int
    let maximumZoom: Int
    let nativeDetailMaximumZoom: Int?
    let maximumFallbackDepth: Int
    let visualSettings: DistrictMapVisualSettings
    let canReplaceMapContent: Bool

    init(
        role: MBTilesLayerRole,
        packageIdentifier: String,
        packageVersion: String,
        fileURL: URL,
        storageSchemeOverride: MBTilesStorageScheme? = nil,
        tileSizePixels: Int = 256,
        minimumZoom: Int = 0,
        maximumZoom: Int = 15,
        nativeDetailMaximumZoom: Int? = nil,
        maximumFallbackDepth: Int = 6,
        visualSettings: DistrictMapVisualSettings = .neutral,
        canReplaceMapContent: Bool = false
    ) {
        self.role = role
        self.packageIdentifier = packageIdentifier
        self.packageVersion = packageVersion
        self.canonicalPath = fileURL.standardizedFileURL.path
        self.storageSchemeOverride = storageSchemeOverride
        self.storageSchemePolicy = storageSchemeOverride
            .map { "explicit-legacy-\($0.rawValue)" }
            ?? "metadata-or-legacy-tms"
        self.tileSizePixels = tileSizePixels
        self.minimumZoom = minimumZoom
        self.maximumZoom = maximumZoom
        self.nativeDetailMaximumZoom = nativeDetailMaximumZoom.map { max(0, $0) }
        self.maximumFallbackDepth = maximumFallbackDepth
        self.visualSettings = visualSettings.normalized
        self.canReplaceMapContent = canReplaceMapContent
    }

    var description: String {
        let v = visualSettings
        let nativeDetail = nativeDetailMaximumZoom.map(String.init) ?? "metadata"
        return "\(role.rawValue):\(packageIdentifier):\(packageVersion):\(canonicalPath):native=\(nativeDetail):visual=\(v.brightness.bitPattern)-\(v.contrast.bitPattern)-\(v.gamma.bitPattern)-\(v.saturation.bitPattern)"
    }

    var sourceIdentity: MBTilesSourceIdentity {
        MBTilesSourceIdentity(
            role: role,
            packageIdentifier: packageIdentifier,
            packageVersion: packageVersion,
            canonicalPath: canonicalPath,
            storageSchemePolicy: storageSchemePolicy,
            storageSchemeOverride: storageSchemeOverride,
            tileSizePixels: tileSizePixels,
            minimumZoom: minimumZoom,
            maximumZoom: maximumZoom,
            nativeDetailMaximumZoom: nativeDetailMaximumZoom,
            maximumFallbackDepth: maximumFallbackDepth
        )
    }
}

/// File- and schema-level identity used for immutable source bytes and decoded raw
/// images. Appearance changes intentionally do not duplicate these cache entries.
nonisolated struct MBTilesSourceIdentity: Hashable, Sendable {
    let role: MBTilesLayerRole
    let packageIdentifier: String
    let packageVersion: String
    let canonicalPath: String
    let storageSchemePolicy: String
    let storageSchemeOverride: MBTilesStorageScheme?
    let tileSizePixels: Int
    let minimumZoom: Int
    let maximumZoom: Int
    let nativeDetailMaximumZoom: Int?
    let maximumFallbackDepth: Int
}

nonisolated struct MBTilesOverlayReconciliationPlan: Equatable, Sendable {
    let additions: [MBTilesOverlayIdentity]
    let removals: [MBTilesOverlayIdentity]

    init(current: Set<MBTilesOverlayIdentity>, desired: [MBTilesOverlayIdentity]) {
        let desiredSet = Set(desired)
        additions = desired.filter { !current.contains($0) }
        removals = current.filter { !desiredSet.contains($0) }.sorted { $0.description < $1.description }
    }

    var isNoOp: Bool { additions.isEmpty && removals.isEmpty }
}

nonisolated struct MBTilesTileCoordinate: Hashable, Sendable {
    let z: Int
    let x: Int
    let y: Int // canonical XYZ/top-origin row

    init?(z: Int, x: Int, y: Int, wrapsHorizontally: Bool = true) {
        guard (0...30).contains(z) else { return nil }
        let side = Int64(1) << Int64(z)
        guard Int64(y) >= 0, Int64(y) < side else { return nil }

        let normalizedX: Int64
        if wrapsHorizontally {
            normalizedX = ((Int64(x) % side) + side) % side
        } else {
            guard Int64(x) >= 0, Int64(x) < side else { return nil }
            normalizedX = Int64(x)
        }

        self.z = z
        self.x = Int(normalizedX)
        self.y = y
    }

    func storedY(for scheme: MBTilesStorageScheme) -> Int {
        switch scheme {
        case .xyz:
            return y
        case .tms:
            return Int((Int64(1) << Int64(z)) - 1 - Int64(y))
        }
    }

    func ancestor(depth: Int) -> MBTilesTileCoordinate? {
        guard depth > 0, depth <= z else { return nil }
        return MBTilesTileCoordinate(z: z - depth, x: x >> depth, y: y >> depth)
    }
}

/// Converts a MapKit viewport into a small, center-first set of XYZ tile coordinates.
/// The one-tile ring is used for predictive loading so a pan or pinch has useful
/// raster data immediately outside the currently drawn rectangle.
nonisolated enum MBTilesViewportTilePlanner {
    static func coordinates(
        in mapRect: MKMapRect,
        zoom: Int,
        ring: Int = 1,
        maximumCount: Int = 96
    ) -> [MBTilesTileCoordinate] {
        guard (0...30).contains(zoom), maximumCount > 0,
              mapRect.origin.x.isFinite, mapRect.origin.y.isFinite,
              mapRect.size.width.isFinite, mapRect.size.height.isFinite,
              mapRect.size.width > 0, mapRect.size.height > 0 else { return [] }

        let side = Int64(1) << Int64(zoom)
        let tileMapPoints = MKMapSize.world.width / Double(side)
        let expandedRing = max(0, ring)
        let rawMinimumX = Int64(floor(mapRect.minX / tileMapPoints)) - Int64(expandedRing)
        let rawMaximumX = Int64(floor((mapRect.maxX.nextDown) / tileMapPoints)) + Int64(expandedRing)
        let minimumY = max(0, Int64(floor(mapRect.minY / tileMapPoints)) - Int64(expandedRing))
        let maximumY = min(side - 1, Int64(floor(mapRect.maxY.nextDown / tileMapPoints)) + Int64(expandedRing))
        guard rawMaximumX >= rawMinimumX, maximumY >= minimumY else { return [] }

        let unwrappedCenterX = mapRect.midX / tileMapPoints
        let centerX = unwrappedCenterX - floor(unwrappedCenterX / Double(side)) * Double(side)
        let centerY = mapRect.midY / tileMapPoints
        var unique: Set<MBTilesTileCoordinate> = []
        let maximumRawWidth = min(side, rawMaximumX - rawMinimumX + 1)
        unique.reserveCapacity(min(maximumCount, Int(maximumRawWidth * (maximumY - minimumY + 1))))
        for rawY in minimumY...maximumY {
            for rawX in rawMinimumX...rawMaximumX {
                if let coordinate = MBTilesTileCoordinate(z: zoom, x: Int(rawX), y: Int(rawY)) {
                    unique.insert(coordinate)
                }
            }
        }

        return unique.sorted { lhs, rhs in
            let lhsDirectX = abs((Double(lhs.x) + 0.5) - centerX)
            let rhsDirectX = abs((Double(rhs.x) + 0.5) - centerX)
            let lhsX = min(lhsDirectX, Double(side) - lhsDirectX)
            let rhsX = min(rhsDirectX, Double(side) - rhsDirectX)
            let lhsDistance = lhsX + abs((Double(lhs.y) + 0.5) - centerY)
            let rhsDistance = rhsX + abs((Double(rhs.y) + 0.5) - centerY)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            return lhs.x < rhs.x
        }.prefix(maximumCount).map { $0 }
    }

    static func mapRect(for coordinate: MBTilesTileCoordinate) -> MKMapRect {
        let side = Double(Int64(1) << Int64(coordinate.z))
        let tileMapPoints = MKMapSize.world.width / side
        return MKMapRect(
            x: Double(coordinate.x) * tileMapPoints,
            y: Double(coordinate.y) * tileMapPoints,
            width: tileMapPoints,
            height: tileMapPoints
        )
    }
}

/// Converts validator-produced WGS84 bounds into the smallest MapKit rectangle that
/// can contain the package. Installed packages without trustworthy bounds retain the
/// safe world-sized fallback, but validated district and basemap packages should
/// normally take this path.
nonisolated enum MBTilesGeographicCoverage {
    static func mapRect(from bounds: [Double]?) -> MKMapRect? {
        guard let bounds, bounds.count == 4 else { return nil }
        let west = bounds[0]
        let south = bounds[1]
        let east = bounds[2]
        let north = bounds[3]
        guard west.isFinite, south.isFinite, east.isFinite, north.isFinite,
              (-180...180).contains(west), (-180...180).contains(east),
              (-90...90).contains(south), (-90...90).contains(north),
              east > west, north > south else { return nil }

        let mercatorLimit = 85.051_128_78
        let northWest = MKMapPoint(CLLocationCoordinate2D(
            latitude: min(mercatorLimit, max(-mercatorLimit, north)),
            longitude: west
        ))
        let southEast = MKMapPoint(CLLocationCoordinate2D(
            latitude: min(mercatorLimit, max(-mercatorLimit, south)),
            longitude: east
        ))
        let rect = MKMapRect(
            x: min(northWest.x, southEast.x),
            y: min(northWest.y, southEast.y),
            width: abs(southEast.x - northWest.x),
            height: abs(southEast.y - northWest.y)
        )
        guard !rect.isNull, !rect.isEmpty,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite else { return nil }
        return rect.intersection(.world)
    }
}

/// Pure, testable resource policy shared by the MBTiles and Bristol Bay satellite
/// paths. It intentionally favors interaction continuity over throughput on devices
/// with four GiB of memory or fewer (including the ninth-generation iPad).
nonisolated struct MBTilesResourceProfile: Equatable, Sendable {
    enum ThermalPressure: Int, Sendable {
        case nominal, fair, serious, critical
    }

    let maximumActiveWork: Int
    let maximumSpeculativeWork: Int
    let maximumQueuedWork: Int
    let compressedCacheBytes: Int
    let generatedCacheBytes: Int
    let decodedCacheBytes: Int
    let continuityCacheBytes: Int
    let negativeCacheCount: Int
    let onlineSatelliteCacheBytes: Int
    let onlineSatelliteConnections: Int

    static func make(
        activeProcessorCount: Int,
        physicalMemory: UInt64,
        thermalPressure: ThermalPressure = .nominal,
        lowPowerMode: Bool = false,
        interactionActive: Bool = false
    ) -> MBTilesResourceProfile {
        let gibibyte = UInt64(1_024 * 1_024 * 1_024)
        let constrained = activeProcessorCount <= 4 || physicalMemory <= 4 * gibibyte
        let moderate = !constrained && physicalMemory <= 6 * gibibyte

        var active = constrained ? 2 : (moderate ? 3 : 4)
        var speculative = 1
        var queued = constrained ? 96 : (moderate ? 160 : 256)

        if lowPowerMode {
            active = min(active, 2)
            speculative = 0
            queued = min(queued, 96)
        }
        if interactionActive {
            // Rapid camera changes need headroom for MapKit and UIKit more than
            // maximum tile throughput. One lane is enough on constrained devices;
            // newer hardware keeps two so the foreground district and its
            // continuity underlay can both make progress.
            active = min(active, constrained ? 1 : 2)
            speculative = 0
            queued = min(queued, 96)
        }
        switch thermalPressure {
        case .nominal:
            break
        case .fair:
            active = min(active, 2)
            speculative = 0
            queued = min(queued, 96)
        case .serious, .critical:
            active = 1
            speculative = 0
            queued = min(queued, 48)
        }

        // Cache budgets adapt to persistent power/thermal state, but deliberately
        // do not fluctuate during each camera gesture. Repeatedly shrinking the
        // continuity cache while pinching was evicting the very native parents
        // needed to keep the basemap covered.
        var cachePercent = 100
        if lowPowerMode { cachePercent = min(cachePercent, 75) }
        switch thermalPressure {
        case .nominal:
            break
        case .fair:
            cachePercent = min(cachePercent, 75)
        case .serious:
            cachePercent = min(cachePercent, 50)
        case .critical:
            cachePercent = min(cachePercent, 33)
        }
        func scaledCacheLimit(_ base: Int, minimum: Int) -> Int {
            max(minimum, (base * cachePercent) / 100)
        }

        let compressedBase = constrained
            ? 16 * 1_024 * 1_024
            : (moderate ? 24 : 32) * 1_024 * 1_024
        let generatedBase = (constrained ? 4 : 8) * 1_024 * 1_024
        let decodedBase = (constrained ? 6 : 10) * 1_024 * 1_024
        let continuityBase = (constrained ? 12 : 16) * 1_024 * 1_024
        let negativeBase = constrained ? 1_024 : 2_048
        let onlineSatelliteBase = constrained
            ? 24 * 1_024 * 1_024
            : (moderate ? 36 : 48) * 1_024 * 1_024

        return MBTilesResourceProfile(
            maximumActiveWork: active,
            maximumSpeculativeWork: min(speculative, max(0, active - 1)),
            maximumQueuedWork: queued,
            compressedCacheBytes: scaledCacheLimit(compressedBase, minimum: 4 * 1_024 * 1_024),
            generatedCacheBytes: scaledCacheLimit(generatedBase, minimum: 1 * 1_024 * 1_024),
            decodedCacheBytes: scaledCacheLimit(decodedBase, minimum: 2 * 1_024 * 1_024),
            continuityCacheBytes: scaledCacheLimit(continuityBase, minimum: 6 * 1_024 * 1_024),
            negativeCacheCount: scaledCacheLimit(negativeBase, minimum: 256),
            onlineSatelliteCacheBytes: scaledCacheLimit(onlineSatelliteBase, minimum: 8 * 1_024 * 1_024),
            onlineSatelliteConnections: constrained ? 1 : (moderate ? 2 : 3)
        )
    }

    static func current(interactionActive: Bool = false) -> MBTilesResourceProfile {
        let info = ProcessInfo.processInfo
        return make(
            activeProcessorCount: info.activeProcessorCount,
            physicalMemory: info.physicalMemory,
            thermalPressure: thermalPressure(info.thermalState),
            lowPowerMode: info.isLowPowerModeEnabled,
            interactionActive: interactionActive
        )
    }

    private static func thermalPressure(_ state: ProcessInfo.ThermalState) -> ThermalPressure {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }
}

/// Converts a continuous MapKit camera scale into a stable scheduling bucket.
/// The hysteresis band prevents fractional zoom jitter from repeatedly flipping
/// between adjacent tile generations near a half-level boundary.
nonisolated enum MBTilesViewportZoomPolicy {
    static let transitionThreshold = 0.65

    static func bucket(
        for zoomLevel: Double,
        previous: Int?,
        minimum: Int,
        maximum: Int
    ) -> Int {
        let lower = min(minimum, maximum)
        let upper = max(minimum, maximum)
        guard zoomLevel.isFinite else { return min(upper, max(lower, previous ?? lower)) }
        let clampedZoom = min(Double(upper), max(Double(lower), zoomLevel))
        guard let previous else {
            return min(upper, max(lower, Int(clampedZoom.rounded())))
        }

        var result = min(upper, max(lower, previous))
        while result < upper,
              clampedZoom >= Double(result) + transitionThreshold {
            result += 1
        }
        while result > lower,
              clampedZoom <= Double(result) - transitionThreshold {
            result -= 1
        }
        return result
    }
}

/// Shared bounded retry timing for transient continuity-tile failures. Missing
/// tiles are terminal; only queue pressure, cancellation, or a temporary read
/// failure reaches this policy.
nonisolated enum MBTilesRetryPolicy {
    private static let delays: [TimeInterval] = [0.05, 0.15]
    static let cooldown: TimeInterval = 0.50
    private static let maximumCooldownCycle = 3

    static func delay(forRetry retry: Int) -> TimeInterval? {
        guard delays.indices.contains(retry) else { return nil }
        return delays[retry]
    }

    /// Persistent pressure backs off from 0.5 s to 4 s per coordinate. A bounded
    /// exponent avoids a redraw/retry storm while retaining eventual recovery.
    static func cooldown(forFailureCycle cycle: Int) -> TimeInterval {
        let boundedCycle = min(maximumCooldownCycle, max(0, cycle))
        return cooldown * Double(1 << boundedCycle)
    }
}

/// Lock-agnostic latest-value state used by the viewport queue. Callers provide
/// synchronization; this small value type makes the coalescing contract directly
/// testable without relying on thread timing.
nonisolated struct LatestOnlyWorkAccumulator<Value> {
    private var latest: Value?
    private(set) var isDrainScheduled = false

    mutating func submit(_ value: Value) -> Bool {
        latest = value
        guard !isDrainScheduled else { return false }
        isDrainScheduled = true
        return true
    }

    mutating func takeLatest() -> Value? {
        defer { latest = nil }
        return latest
    }

    @discardableResult
    mutating func finishDrainIfEmpty() -> Bool {
        guard latest == nil else { return false }
        isDrainScheduled = false
        return true
    }

    mutating func discardPending() {
        latest = nil
    }
}

nonisolated enum MBTilesError: LocalizedError {
    case invalidCoordinate
    case providerInvalidated
    case requestSuperseded
    case queueFull
    case openFailed(String)
    case malformedSchema
    case unsupportedScheme(String)
    case sqlite(String)
    case corruptTile

    var errorDescription: String? {
        switch self {
        case .invalidCoordinate: return "Invalid MBTiles coordinate."
        case .providerInvalidated: return "The offline map package is no longer active."
        case .requestSuperseded: return "The offline tile request was superseded by a newer map view."
        case .queueFull: return "The offline tile queue is full."
        case .openFailed(let message): return "The offline map could not be opened: \(message)"
        case .malformedSchema: return "The offline map has an unsupported SQLite schema."
        case .unsupportedScheme(let value): return "Unsupported MBTiles scheme: \(value)"
        case .sqlite(let message): return "SQLite tile lookup failed: \(message)"
        case .corruptTile: return "The offline map contains an invalid raster tile."
        }
    }
}

nonisolated struct MBTilesDiagnosticSnapshot: Sendable {
    let requests: UInt64
    let completions: UInt64
    let directHits: UInt64
    let trueMisses: UInt64
    let fallbackHits: UInt64
    let coalescedRequests: UInt64
    let sqliteLookups: UInt64
    let sqliteFailures: UInt64
    let corruptTiles: UInt64
    let coverageRejections: UInt64
    let mainThreadWorkViolations: UInt64
    let queuedWork: Int
    let activeWork: Int
    let highWaterQueuedWork: Int
    let saturatedQueueRejections: UInt64
    let displacedQueuedRequests: UInt64
    let staleQueuedCancellations: UInt64
    let compressedItems: Int
    let compressedCost: Int
    let compressedLimit: Int
    let generatedItems: Int
    let generatedCost: Int
    let generatedLimit: Int
    let decodedItems: Int
    let decodedCost: Int
    let decodedLimit: Int
    let negativeItems: Int
    let activeCacheIdentities: Int
    let evictions: UInt64
    let openReaders: Int
    let queueDelayP50Microseconds: UInt64
    let queueDelayP95Microseconds: UInt64
    let sqliteP50Microseconds: UInt64
    let sqliteP95Microseconds: UInt64
    let rasterP50Microseconds: UInt64
    let rasterP95Microseconds: UInt64
    let requestP50Microseconds: UInt64
    let requestP95Microseconds: UInt64

    var compactDescription: String {
        "requests=\(requests) completions=\(completions) direct=\(directHits) fallback=\(fallbackHits) misses=\(trueMisses) coalesced=\(coalescedRequests) coverageRejects=\(coverageRejections) work=\(activeWork)/\(queuedWork) highWater=\(highWaterQueuedWork) saturated=\(saturatedQueueRejections) displaced=\(displacedQueuedRequests) stale=\(staleQueuedCancellations) readers=\(openReaders) cache=\(compressedCost + generatedCost + decodedCost)/\(compressedLimit + generatedLimit + decodedLimit) activeCaches=\(activeCacheIdentities) evictions=\(evictions) p95us(queue/sql/raster/total)=\(queueDelayP95Microseconds)/\(sqliteP95Microseconds)/\(rasterP95Microseconds)/\(requestP95Microseconds) failures=\(sqliteFailures + corruptTiles)"
    }
}

nonisolated final class MBTilesDiagnostics {
    static let shared = MBTilesDiagnostics()

    private let lock = NSLock()
    private var requests: UInt64 = 0
    private var completions: UInt64 = 0
    private var directHits: UInt64 = 0
    private var trueMisses: UInt64 = 0
    private var fallbackHits: UInt64 = 0
    private var coalescedRequests: UInt64 = 0
    private var sqliteLookups: UInt64 = 0
    private var sqliteFailures: UInt64 = 0
    private var corruptTiles: UInt64 = 0
    private var coverageRejections: UInt64 = 0
    private var mainThreadWorkViolations: UInt64 = 0
    private var openReaders: Int = 0
    private var queueDelayTimings = TimingWindow()
    private var sqliteTimings = TimingWindow()
    private var rasterTimings = TimingWindow()
    private var requestTimings = TimingWindow()

    private struct TimingWindow {
        private static let capacity = 512
        private var values: [UInt64] = []
        private var replacementIndex = 0

        mutating func record(_ nanoseconds: UInt64) {
            if values.count < Self.capacity {
                values.append(nanoseconds)
            } else {
                values[replacementIndex] = nanoseconds
                replacementIndex = (replacementIndex + 1) % Self.capacity
            }
        }

        func percentile(_ fraction: Double) -> UInt64 {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
            return sorted[index] / 1_000
        }
    }

    enum Counter {
        case request, completion, directHit, trueMiss, fallbackHit, coalesced
        case sqliteLookup, sqliteFailure, corruptTile, coverageRejection, mainThreadWorkViolation
    }

    enum Timing {
        case queueDelay, sqlite, raster, request
    }

    func increment(_ counter: Counter, by amount: UInt64 = 1) {
        #if DEBUG
        lock.lock()
        switch counter {
        case .request: requests += amount
        case .completion: completions += amount
        case .directHit: directHits += amount
        case .trueMiss: trueMisses += amount
        case .fallbackHit: fallbackHits += amount
        case .coalesced: coalescedRequests += amount
        case .sqliteLookup: sqliteLookups += amount
        case .sqliteFailure: sqliteFailures += amount
        case .corruptTile: corruptTiles += amount
        case .coverageRejection: coverageRejections += amount
        case .mainThreadWorkViolation: mainThreadWorkViolations += amount
        }
        lock.unlock()
        #else
        _ = counter
        _ = amount
        #endif
    }

    func record(_ timing: Timing, nanoseconds: UInt64) {
        #if DEBUG
        lock.lock()
        switch timing {
        case .queueDelay: queueDelayTimings.record(nanoseconds)
        case .sqlite: sqliteTimings.record(nanoseconds)
        case .raster: rasterTimings.record(nanoseconds)
        case .request: requestTimings.record(nanoseconds)
        }
        lock.unlock()
        #else
        _ = timing
        _ = nanoseconds
        #endif
    }

    func readerOpened() {
        #if DEBUG
        lock.lock(); openReaders += 1; lock.unlock()
        #endif
    }

    func readerClosed() {
        #if DEBUG
        lock.lock(); openReaders = max(0, openReaders - 1); lock.unlock()
        #endif
    }

    func snapshot() -> MBTilesDiagnosticSnapshot {
        let work = MBTilesWorkScheduler.shared.snapshot()
        let cache = MBTilesTileCaches.shared.snapshot()
        lock.lock()
        defer { lock.unlock() }
        return MBTilesDiagnosticSnapshot(
            requests: requests,
            completions: completions,
            directHits: directHits,
            trueMisses: trueMisses,
            fallbackHits: fallbackHits,
            coalescedRequests: coalescedRequests,
            sqliteLookups: sqliteLookups,
            sqliteFailures: sqliteFailures,
            corruptTiles: corruptTiles,
            coverageRejections: coverageRejections,
            mainThreadWorkViolations: mainThreadWorkViolations,
            queuedWork: work.queued,
            activeWork: work.active,
            highWaterQueuedWork: work.highWater,
            saturatedQueueRejections: work.saturatedRejections,
            displacedQueuedRequests: work.displaced,
            staleQueuedCancellations: work.staleCancelled,
            compressedItems: cache.compressedItems,
            compressedCost: cache.compressedCost,
            compressedLimit: cache.compressedLimit,
            generatedItems: cache.generatedItems,
            generatedCost: cache.generatedCost,
            generatedLimit: cache.generatedLimit,
            decodedItems: cache.decodedItems,
            decodedCost: cache.decodedCost,
            decodedLimit: cache.decodedLimit,
            negativeItems: cache.negativeItems,
            activeCacheIdentities: cache.activeIdentities,
            evictions: cache.evictions,
            openReaders: openReaders,
            queueDelayP50Microseconds: queueDelayTimings.percentile(0.50),
            queueDelayP95Microseconds: queueDelayTimings.percentile(0.95),
            sqliteP50Microseconds: sqliteTimings.percentile(0.50),
            sqliteP95Microseconds: sqliteTimings.percentile(0.95),
            rasterP50Microseconds: rasterTimings.percentile(0.50),
            rasterP95Microseconds: rasterTimings.percentile(0.95),
            requestP50Microseconds: requestTimings.percentile(0.50),
            requestP95Microseconds: requestTimings.percentile(0.95)
        )
    }
}

nonisolated final class CostedLRU<Key: Hashable, Value> {
    private final class Node {
        let key: Key
        var value: Value
        var cost: Int
        weak var previous: Node?
        var next: Node?

        init(key: Key, value: Value, cost: Int) {
            self.key = key
            self.value = value
            self.cost = cost
        }
    }

    private(set) var costLimit: Int
    private(set) var countLimit: Int
    private var nodes: [Key: Node] = [:]
    private var mostRecent: Node?
    private var leastRecent: Node?
    private var totalCost = 0
    private(set) var evictions: UInt64 = 0
    private(set) var evictionUnlinkOperations: UInt64 = 0

    init(costLimit: Int, countLimit: Int = .max) {
        self.costLimit = costLimit
        self.countLimit = countLimit
    }

    var count: Int { nodes.count }
    var cost: Int { totalCost }

    /// The caller owns synchronization. Limits can contract under sustained
    /// system pressure and expand again after recovery without replacing caches.
    func updateLimits(costLimit: Int, countLimit: Int? = nil) {
        self.costLimit = max(0, costLimit)
        if let countLimit { self.countLimit = max(0, countLimit) }
        trim(toCost: self.costLimit, count: self.countLimit)
    }

    func value(for key: Key) -> Value? {
        guard let node = nodes[key] else { return nil }
        moveToMostRecent(node)
        return node.value
    }

    func insert(
        _ value: Value,
        for key: Key,
        cost: Int,
        preferringToKeep isProtected: (Key) -> Bool = { _ in false }
    ) {
        let boundedCost = max(0, cost)
        if let existing = nodes[key] {
            totalCost -= existing.cost
            existing.value = value
            existing.cost = boundedCost
            totalCost += boundedCost
            moveToMostRecent(existing)
        } else if boundedCost <= costLimit {
            let node = Node(key: key, value: value, cost: boundedCost)
            nodes[key] = node
            insertAtMostRecent(node)
            totalCost += boundedCost
        }
        guard boundedCost <= costLimit else {
            removeValue(for: key)
            return
        }
        trim(toCost: costLimit, count: countLimit, preferringToKeep: isProtected)
    }

    func removeAll(where shouldRemove: (Key) -> Bool) {
        let keys = nodes.keys.filter(shouldRemove)
        for key in keys {
            removeValue(for: key)
        }
    }

    func removeAll() {
        nodes.removeAll(keepingCapacity: false)
        mostRecent = nil
        leastRecent = nil
        totalCost = 0
    }

    func trim(
        toCost requestedCost: Int,
        count requestedCount: Int = .max,
        preferringToKeep isProtected: (Key) -> Bool = { _ in false }
    ) {
        let targetCost = max(0, min(requestedCost, costLimit))
        let targetCount = max(0, min(requestedCount, countLimit))
        // Eviction is deliberately a pure LRU operation. The previous implementation
        // scanned the full dictionary to prefer active identities, turning every miss
        // after the negative cache filled into O(n) work under the global cache lock.
        // Active layers naturally remain recent because they are the ones being read.
        _ = isProtected
        while totalCost > targetCost || nodes.count > targetCount {
            guard let oldest = leastRecent else { break }
            removeValue(for: oldest.key)
            evictions &+= 1
            evictionUnlinkOperations &+= 1
        }
    }

    private func moveToMostRecent(_ node: Node) {
        guard mostRecent !== node else { return }
        unlink(node)
        insertAtMostRecent(node)
    }

    private func insertAtMostRecent(_ node: Node) {
        node.previous = nil
        node.next = mostRecent
        mostRecent?.previous = node
        mostRecent = node
        if leastRecent == nil { leastRecent = node }
    }

    private func unlink(_ node: Node) {
        let previous = node.previous
        let next = node.next
        previous?.next = next
        next?.previous = previous
        if mostRecent === node { mostRecent = next }
        if leastRecent === node { leastRecent = previous }
        node.previous = nil
        node.next = nil
    }

    private func removeValue(for key: Key) {
        guard let node = nodes.removeValue(forKey: key) else { return }
        unlink(node)
        totalCost -= node.cost
    }
}

nonisolated private struct MBTilesOutputKey: Hashable {
    let identity: MBTilesOverlayIdentity
    let coordinate: MBTilesTileCoordinate
    let contentScaleBits: UInt64
}

nonisolated private struct MBTilesStoredKey: Hashable {
    let sourceIdentity: MBTilesSourceIdentity
    let coordinate: MBTilesTileCoordinate
}

/// One deterministic aggregate budget shared by every simultaneously active MBTiles
/// layer. Limits are intentionally conservative for the oldest supported devices.
nonisolated private final class MBTilesTileCaches {
    static let shared = MBTilesTileCaches()

    private let compressedLock = NSLock()
    private let generatedLock = NSLock()
    private let decodedLock = NSLock()
    private let backstopLock = NSLock()
    private let negativeLock = NSLock()
    private let identitiesLock = NSLock()
    private let compressed: CostedLRU<MBTilesStoredKey, Data>
    private let generated: CostedLRU<MBTilesOutputKey, Data>
    private let decoded: CostedLRU<MBTilesStoredKey, CGImage>
    private let backstop: CostedLRU<MBTilesOutputKey, CGImage>
    private let negative: CostedLRU<MBTilesOutputKey, Bool>
    private var activeIdentities: Set<MBTilesOverlayIdentity> = []

    private init() {
        let profile = MBTilesResourceProfile.current()
        compressed = CostedLRU(costLimit: profile.compressedCacheBytes)
        generated = CostedLRU(costLimit: profile.generatedCacheBytes)
        decoded = CostedLRU(costLimit: profile.decodedCacheBytes)
        backstop = CostedLRU(costLimit: profile.continuityCacheBytes)
        negative = CostedLRU(
            costLimit: profile.negativeCacheCount,
            countLimit: profile.negativeCacheCount
        )
    }

    struct Snapshot {
        let compressedItems: Int, compressedCost: Int, compressedLimit: Int
        let generatedItems: Int, generatedCost: Int, generatedLimit: Int
        let decodedItems: Int, decodedCost: Int, decodedLimit: Int
        let negativeItems: Int
        let activeIdentities: Int
        let evictions: UInt64
    }

    func compressedData(for key: MBTilesStoredKey) -> Data? {
        compressedLock.lock(); defer { compressedLock.unlock() }
        return compressed.value(for: key)
    }

    func insertCompressed(_ data: Data, for key: MBTilesStoredKey) {
        compressedLock.lock()
        compressed.insert(data, for: key, cost: data.count)
        compressedLock.unlock()
    }

    func generatedData(for key: MBTilesOutputKey) -> Data? {
        generatedLock.lock(); defer { generatedLock.unlock() }
        return generated.value(for: key)
    }

    func insertGenerated(_ data: Data, for key: MBTilesOutputKey) {
        generatedLock.lock()
        generated.insert(data, for: key, cost: data.count)
        generatedLock.unlock()
    }

    func decodedImage(for key: MBTilesStoredKey) -> CGImage? {
        decodedLock.lock(); defer { decodedLock.unlock() }
        return decoded.value(for: key)
    }

    func insertDecoded(_ image: CGImage, for key: MBTilesStoredKey) {
        let bytes = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        decodedLock.lock()
        let cost = bytes.overflow ? decoded.costLimit + 1 : bytes.partialValue
        decoded.insert(image, for: key, cost: cost)
        decodedLock.unlock()
    }

    func backstopImage(for key: MBTilesOutputKey) -> CGImage? {
        backstopLock.lock(); defer { backstopLock.unlock() }
        return backstop.value(for: key)
    }

    func insertBackstop(_ image: CGImage, for key: MBTilesOutputKey) {
        let bytes = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        backstopLock.lock()
        let cost = bytes.overflow ? backstop.costLimit + 1 : bytes.partialValue
        backstop.insert(image, for: key, cost: cost)
        backstopLock.unlock()
    }

    func isNegative(_ key: MBTilesOutputKey) -> Bool {
        negativeLock.lock(); defer { negativeLock.unlock() }
        return negative.value(for: key) != nil
    }

    func insertNegative(_ key: MBTilesOutputKey) {
        negativeLock.lock()
        negative.insert(true, for: key, cost: 1)
        negativeLock.unlock()
    }

    func setActive(_ identity: MBTilesOverlayIdentity, isActive: Bool) {
        identitiesLock.lock()
        if isActive { activeIdentities.insert(identity) }
        else { activeIdentities.remove(identity) }
        identitiesLock.unlock()
    }

    func invalidate(identity: MBTilesOverlayIdentity) {
        generatedLock.lock()
        generated.removeAll { $0.identity == identity }
        generatedLock.unlock()
        backstopLock.lock()
        backstop.removeAll { $0.identity == identity }
        backstopLock.unlock()
        negativeLock.lock()
        negative.removeAll { $0.identity == identity }
        negativeLock.unlock()
        identitiesLock.lock()
        activeIdentities.remove(identity)
        identitiesLock.unlock()
    }

    func invalidate(sourceIdentity: MBTilesSourceIdentity) {
        compressedLock.lock()
        compressed.removeAll { $0.sourceIdentity == sourceIdentity }
        compressedLock.unlock()
        decodedLock.lock()
        decoded.removeAll { $0.sourceIdentity == sourceIdentity }
        decodedLock.unlock()
    }

    func handleMemoryWarning() {
        decodedLock.lock()
        decoded.removeAll()
        decodedLock.unlock()
        // Preserve the most recently used native parents so a memory warning does
        // not immediately punch holes through to Apple Satellite during a gesture.
        backstopLock.lock()
        backstop.trim(toCost: min(8 * 1_024 * 1_024, (backstop.costLimit * 2) / 3))
        backstopLock.unlock()
        generatedLock.lock()
        generated.removeAll()
        generatedLock.unlock()
        negativeLock.lock()
        negative.removeAll()
        negativeLock.unlock()
        compressedLock.lock()
        compressed.trim(toCost: compressed.costLimit / 4)
        compressedLock.unlock()
    }

    func handleBackgrounding() {
        decodedLock.lock()
        decoded.removeAll()
        decodedLock.unlock()
        backstopLock.lock()
        backstop.trim(toCost: backstop.costLimit / 3)
        backstopLock.unlock()
        generatedLock.lock()
        generated.trim(toCost: generated.costLimit / 4)
        generatedLock.unlock()
        compressedLock.lock()
        compressed.trim(toCost: compressed.costLimit / 2)
        compressedLock.unlock()
    }

    /// Applies durable system-state budgets off the UI thread. Each tier has its
    /// own lock, so cache hits in unrelated tiers are never serialized behind one
    /// global resize operation.
    func applyResourceProfile(_ profile: MBTilesResourceProfile) {
        compressedLock.lock()
        compressed.updateLimits(costLimit: profile.compressedCacheBytes)
        compressedLock.unlock()
        generatedLock.lock()
        generated.updateLimits(costLimit: profile.generatedCacheBytes)
        generatedLock.unlock()
        decodedLock.lock()
        decoded.updateLimits(costLimit: profile.decodedCacheBytes)
        decodedLock.unlock()
        backstopLock.lock()
        backstop.updateLimits(costLimit: profile.continuityCacheBytes)
        backstopLock.unlock()
        negativeLock.lock()
        negative.updateLimits(
            costLimit: profile.negativeCacheCount,
            countLimit: profile.negativeCacheCount
        )
        negativeLock.unlock()
    }

    func snapshot() -> Snapshot {
        compressedLock.lock()
        let compressedSnapshot = (compressed.count, compressed.cost, compressed.costLimit, compressed.evictions)
        compressedLock.unlock()
        generatedLock.lock()
        let generatedSnapshot = (generated.count, generated.cost, generated.costLimit, generated.evictions)
        generatedLock.unlock()
        decodedLock.lock()
        let decodedSnapshot = (decoded.count, decoded.cost, decoded.costLimit, decoded.evictions)
        decodedLock.unlock()
        backstopLock.lock()
        let backstopSnapshot = (backstop.count, backstop.cost, backstop.costLimit, backstop.evictions)
        backstopLock.unlock()
        negativeLock.lock()
        let negativeSnapshot = (negative.count, negative.evictions)
        negativeLock.unlock()
        identitiesLock.lock()
        let activeIdentityCount = activeIdentities.count
        identitiesLock.unlock()
        return Snapshot(
            compressedItems: compressedSnapshot.0,
            compressedCost: compressedSnapshot.1,
            compressedLimit: compressedSnapshot.2,
            generatedItems: generatedSnapshot.0,
            generatedCost: generatedSnapshot.1,
            generatedLimit: generatedSnapshot.2,
            decodedItems: decodedSnapshot.0 + backstopSnapshot.0,
            decodedCost: decodedSnapshot.1 + backstopSnapshot.1,
            decodedLimit: decodedSnapshot.2 + backstopSnapshot.2,
            negativeItems: negativeSnapshot.0,
            activeIdentities: activeIdentityCount,
            evictions: compressedSnapshot.3 + generatedSnapshot.3 + decodedSnapshot.3
                + backstopSnapshot.3 + negativeSnapshot.1
        )
    }
}

/// Bounded, viewport-aware work shared by all local raster layers. MapKit does not
/// provide a cancellation token, so queued work carries its own exactly-once cancel
/// callback and old viewport generations are removed before they can delay visible tiles.
nonisolated final class MBTilesWorkScheduler: @unchecked Sendable {
    static let shared = MBTilesWorkScheduler()
    /// Absolute safety ceilings. The active device profile is usually lower on
    /// memory-constrained hardware and under power or thermal pressure.
    static let maximumActiveWork = 4
    static let maximumQueuedWork = 256

    private struct WorkItem {
        let workID: UUID
        let ownerID: UUID
        let generation: UInt64
        var priority: Int
        var isSpeculative: Bool
        let sequence: UInt64
        let enqueuedAt: UInt64
        let execute: () -> Void
        let cancel: () -> Void
    }

    enum Submission: Equatable { case accepted, superseded, saturated }

    private let stateQueue = DispatchQueue(label: "com.satchart.mbtiles.scheduler.state")
    private let visibleWorkerQueue = DispatchQueue(
        label: "com.satchart.mbtiles.scheduler.visible",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let speculativeWorkerQueue = DispatchQueue(
        label: "com.satchart.mbtiles.scheduler.speculative",
        qos: .utility,
        attributes: .concurrent
    )
    private let cancellationQueue = DispatchQueue(label: "com.satchart.mbtiles.scheduler.cancel", qos: .userInitiated)
    private var pending: [WorkItem] = []
    private var latestGenerationByOwner: [UUID: UInt64] = [:]
    private var oldestRetainedGenerationByOwner: [UUID: UInt64] = [:]
    private var sequence: UInt64 = 0
    private var serviceSequence: UInt64 = 0
    private var lastServiceByOwner: [UUID: UInt64] = [:]
    private var active = 0
    private var activeSpeculative = 0
    private let legacyInteractionOwnerID = UUID()
    private var interactionOwners: Set<UUID> = []
    private var resourceProfile = MBTilesResourceProfile.current()
    private var highWater = 0
    private var saturatedRejections: UInt64 = 0
    private var displaced: UInt64 = 0
    private var staleCancelled: UInt64 = 0

    struct Snapshot {
        let queued: Int
        let active: Int
        let highWater: Int
        let activeSpeculative: Int
        let maximumActive: Int
        let maximumSpeculative: Int
        let maximumQueued: Int
        let speculationSuspended: Bool
        let saturatedRejections: UInt64
        let displaced: UInt64
        let staleCancelled: UInt64
    }

    @discardableResult
    func submit(
        ownerID: UUID,
        generation: UInt64,
        workID: UUID = UUID(),
        priority: Int,
        isSpeculative: Bool = false,
        execute: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) -> Submission {
        var cancellations: [() -> Void] = []
        let result: Submission = stateQueue.sync {
            if isSpeculative && resourceProfile.maximumSpeculativeWork == 0 {
                return .superseded
            }
            let latestGeneration = latestGenerationByOwner[ownerID]
            let oldestRetainedGeneration = oldestRetainedGenerationByOwner[ownerID]
            if let oldestRetainedGeneration, generation < oldestRetainedGeneration {
                return .superseded
            }

            if let latestGeneration, generation > latestGeneration {
                latestGenerationByOwner[ownerID] = generation
                let oldest = generation > 0 ? generation - 1 : generation
                oldestRetainedGenerationByOwner[ownerID] = oldest
                cancellations.append(contentsOf: removePendingLocked {
                    $0.ownerID == ownerID && $0.generation < oldest
                })
                staleCancelled &+= UInt64(cancellations.count)
                demotePendingLocked(ownerID: ownerID, generation: oldest)
            } else if latestGeneration == nil {
                latestGenerationByOwner[ownerID] = generation
                oldestRetainedGenerationByOwner[ownerID] = generation
            }

            let effectivePriority = generation < (latestGenerationByOwner[ownerID] ?? generation)
                ? priority - 50_000
                : priority

            if pending.count >= resourceProfile.maximumQueuedWork {
                let speculativeIndices = pending.indices.filter { pending[$0].isSpeculative }
                let displacementCandidates = !isSpeculative && !speculativeIndices.isEmpty
                    ? speculativeIndices
                    : Array(pending.indices)
                guard let worstIndex = displacementCandidates.min(by: { lhs, rhs in
                    if pending[lhs].priority != pending[rhs].priority {
                        return pending[lhs].priority < pending[rhs].priority
                    }
                    return pending[lhs].sequence > pending[rhs].sequence
                }), (!isSpeculative && pending[worstIndex].isSpeculative)
                    || effectivePriority > pending[worstIndex].priority else {
                    saturatedRejections &+= 1
                    return .saturated
                }
                cancellations.append(pending.remove(at: worstIndex).cancel)
                displaced &+= 1
            }

            sequence &+= 1
            pending.append(WorkItem(
                workID: workID,
                ownerID: ownerID,
                generation: generation,
                priority: effectivePriority,
                isSpeculative: isSpeculative,
                sequence: sequence,
                enqueuedAt: DispatchTime.now().uptimeNanoseconds,
                execute: execute,
                cancel: cancel
            ))
            highWater = max(highWater, pending.count)
            drainLocked()
            return .accepted
        }
        deliverCancellations(cancellations)
        return result
    }

    func advanceGeneration(ownerID: UUID, to generation: UInt64, retainingPrevious: Bool = false) {
        var cancellations: [() -> Void] = []
        stateQueue.sync {
            cancellations = advanceGenerationLocked(
                ownerID: ownerID,
                to: generation,
                retainingPrevious: retainingPrevious
            )
        }
        deliverCancellations(cancellations)
    }

    /// Viewport reconciliation already runs off the main thread. Enqueueing the
    /// scheduler mutation preserves its ordering with a later session invalidation
    /// without making that reconciliation wait synchronously for scheduler state.
    func scheduleGenerationAdvance(
        ownerID: UUID,
        to generation: UInt64,
        retainingPrevious: Bool = false
    ) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            let cancellations = self.advanceGenerationLocked(
                ownerID: ownerID,
                to: generation,
                retainingPrevious: retainingPrevious
            )
            self.deliverCancellations(cancellations)
        }
    }

    private func advanceGenerationLocked(
        ownerID: UUID,
        to generation: UInt64,
        retainingPrevious: Bool
    ) -> [() -> Void] {
        guard generation > (latestGenerationByOwner[ownerID] ?? 0) else { return [] }
        latestGenerationByOwner[ownerID] = generation
        let oldest = retainingPrevious && generation > 0 ? generation - 1 : generation
        oldestRetainedGenerationByOwner[ownerID] = oldest
        let cancellations = removePendingLocked {
            $0.ownerID == ownerID && $0.generation < oldest
        }
        staleCancelled &+= UInt64(cancellations.count)
        if retainingPrevious { demotePendingLocked(ownerID: ownerID, generation: oldest) }
        drainLocked()
        return cancellations
    }

    func cancelQueuedWork(ownerID: UUID) {
        var cancellations: [() -> Void] = []
        stateQueue.sync {
            cancellations = removePendingLocked { $0.ownerID == ownerID }
            latestGenerationByOwner.removeValue(forKey: ownerID)
            oldestRetainedGenerationByOwner.removeValue(forKey: ownerID)
            lastServiceByOwner.removeValue(forKey: ownerID)
            drainLocked()
        }
        deliverCancellations(cancellations)
    }

    /// Cancels one admission without disturbing work submitted by a session that
    /// may already have been resumed with the same owner identifier.
    func cancelQueuedWork(ownerID: UUID, workID: UUID) {
        var cancellations: [() -> Void] = []
        stateQueue.sync {
            cancellations = removePendingLocked {
                $0.ownerID == ownerID && $0.workID == workID
            }
            drainLocked()
        }
        deliverCancellations(cancellations)
    }

    /// Memory pressure discards only work that has not started and was submitted
    /// as an optional viewport/backstop hint. Admitted MapKit demand is allowed to
    /// finish so its completion contract remains intact.
    func cancelSpeculativeWork() {
        var cancellations: [() -> Void] = []
        stateQueue.sync {
            cancellations = removePendingLocked { $0.isSpeculative }
            drainLocked()
        }
        deliverCancellations(cancellations)
    }

    /// A prefetch can become visible before it starts. Promote matching queued work
    /// in place so the visible callback is neither cancelled nor left at utility QoS.
    func promoteSpeculativeWork(workID: UUID, visiblePriority: Int) {
        stateQueue.sync {
            guard let index = pending.firstIndex(where: {
                $0.workID == workID && $0.isSpeculative
            }) else { return }
            pending[index].isSpeculative = false
            pending[index].priority = max(pending[index].priority, visiblePriority)
            drainLocked()
        }
    }

    /// Stops optional tile generation for the duration of an active camera gesture.
    /// Visible MapKit demand retains a dedicated lane and queued speculative callbacks
    /// are completed through their normal cancellation path.
    func setMapInteractionActive(_ isActive: Bool) {
        setMapInteractionActive(isActive, ownerID: legacyInteractionOwnerID)
    }

    /// Owner-scoped interaction state prevents one map from re-enabling speculative
    /// work while another map is still being manipulated. Repeated state updates from
    /// the same owner are idempotent, matching UIKit gesture lifecycle callbacks.
    func setMapInteractionActive(_ isActive: Bool, ownerID: UUID) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            let changed: Bool
            if isActive {
                changed = self.interactionOwners.insert(ownerID).inserted
            } else {
                changed = self.interactionOwners.remove(ownerID) != nil
            }
            guard changed else { return }
            let profile = MBTilesResourceProfile.current(
                interactionActive: !self.interactionOwners.isEmpty
            )
            let cancellations = self.applyResourceProfileLocked(profile)
            self.deliverCancellations(cancellations)
        }
    }

    /// Label-friendly equivalent for call sites that keep the owner token first.
    func setMapInteractionActive(ownerID: UUID, isActive: Bool) {
        setMapInteractionActive(isActive, ownerID: ownerID)
    }

    func refreshForSystemState() {
        var cancellations: [() -> Void] = []
        stateQueue.sync {
            let profile = MBTilesResourceProfile.current(
                interactionActive: !interactionOwners.isEmpty
            )
            cancellations = applyResourceProfileLocked(profile)
        }
        deliverCancellations(cancellations)
    }

    private func applyResourceProfileLocked(
        _ profile: MBTilesResourceProfile
    ) -> [() -> Void] {
        resourceProfile = profile
        var cancellations: [() -> Void] = []
        if profile.maximumSpeculativeWork == 0 {
            cancellations = removePendingLocked { $0.isSpeculative }
        }
        if pending.count > profile.maximumQueuedWork {
            let orderedForRemoval = pending.indices.sorted { lhs, rhs in
                if pending[lhs].isSpeculative != pending[rhs].isSpeculative {
                    return pending[lhs].isSpeculative
                }
                if pending[lhs].priority != pending[rhs].priority {
                    return pending[lhs].priority < pending[rhs].priority
                }
                return pending[lhs].sequence > pending[rhs].sequence
            }
            let removeCount = pending.count - profile.maximumQueuedWork
            let sequences = Set(orderedForRemoval.prefix(removeCount).map { pending[$0].sequence })
            cancellations.append(contentsOf: removePendingLocked { sequences.contains($0.sequence) })
        }
        drainLocked()
        return cancellations
    }

    func snapshot() -> Snapshot {
        stateQueue.sync {
            Snapshot(
                queued: pending.count,
                active: active,
                highWater: highWater,
                activeSpeculative: activeSpeculative,
                maximumActive: resourceProfile.maximumActiveWork,
                maximumSpeculative: resourceProfile.maximumSpeculativeWork,
                maximumQueued: resourceProfile.maximumQueuedWork,
                speculationSuspended: resourceProfile.maximumSpeculativeWork == 0,
                saturatedRejections: saturatedRejections,
                displaced: displaced,
                staleCancelled: staleCancelled
            )
        }
    }

    private func drainLocked() {
        while active < resourceProfile.maximumActiveWork, !pending.isEmpty {
            let canStartSpeculative = activeSpeculative < resourceProfile.maximumSpeculativeWork
            guard let nextIndex = nextWorkIndexLocked(allowingSpeculative: canStartSpeculative) else {
                break
            }
            let item = pending.remove(at: nextIndex)
            serviceSequence &+= 1
            lastServiceByOwner[item.ownerID] = serviceSequence
            active += 1
            if item.isSpeculative { activeSpeculative += 1 }
            let workerQueue = item.isSpeculative ? speculativeWorkerQueue : visibleWorkerQueue
            workerQueue.async { [weak self] in
                let delay = DispatchTime.now().uptimeNanoseconds &- item.enqueuedAt
                MBTilesDiagnostics.shared.record(.queueDelay, nanoseconds: delay)
                #if DEBUG
                os_signpost(.event, log: Self.log, name: "QueueDelay", "nanoseconds=%llu", delay)
                #endif
                autoreleasepool { item.execute() }
                self?.stateQueue.async {
                    guard let self else { return }
                    self.active = max(0, self.active - 1)
                    if item.isSpeculative {
                        self.activeSpeculative = max(0, self.activeSpeculative - 1)
                    }
                    self.drainLocked()
                }
            }
        }
    }

    /// Priority tiers keep live visible demand ahead of adjacent-zoom and prefetch
    /// work. Within the highest available tier, owners rotate least-recently-served
    /// so one busy district cannot permanently starve another active layer.
    private func nextWorkIndexLocked(allowingSpeculative: Bool) -> Int? {
        let runnable = pending.indices.filter {
            allowingSpeculative || !pending[$0].isSpeculative
        }
        guard !runnable.isEmpty else { return nil }
        let highestTier = runnable.map { priorityTier(pending[$0].priority) }.max() ?? Int.min
        let eligibleIndices = runnable.filter { priorityTier(pending[$0].priority) == highestTier }
        var firstSequenceByOwner: [UUID: UInt64] = [:]
        for index in eligibleIndices {
            let item = pending[index]
            firstSequenceByOwner[item.ownerID] = min(
                firstSequenceByOwner[item.ownerID] ?? UInt64.max,
                item.sequence
            )
        }
        let selectedOwner = firstSequenceByOwner.keys.min { lhs, rhs in
            let lhsService = lastServiceByOwner[lhs] ?? 0
            let rhsService = lastServiceByOwner[rhs] ?? 0
            if lhsService != rhsService { return lhsService < rhsService }
            return (firstSequenceByOwner[lhs] ?? UInt64.max)
                < (firstSequenceByOwner[rhs] ?? UInt64.max)
        }
        guard let selectedOwner else { return runnable.first }
        return eligibleIndices.filter { pending[$0].ownerID == selectedOwner }.max { lhs, rhs in
            if pending[lhs].priority != pending[rhs].priority {
                return pending[lhs].priority < pending[rhs].priority
            }
            return pending[lhs].sequence > pending[rhs].sequence
        } ?? runnable.first
    }

    private func priorityTier(_ priority: Int) -> Int {
        // 20k matches the engine's current-zoom versus adjacent-zoom spacing;
        // the -25k prefetch bias therefore remains strictly below visible demand.
        priority / 20_000
    }

    private func removePendingLocked(where shouldRemove: (WorkItem) -> Bool) -> [() -> Void] {
        var cancellations: [() -> Void] = []
        pending.removeAll { item in
            guard shouldRemove(item) else { return false }
            cancellations.append(item.cancel)
            return true
        }
        return cancellations
    }

    private func demotePendingLocked(ownerID: UUID, generation: UInt64) {
        for index in pending.indices where pending[index].ownerID == ownerID && pending[index].generation == generation {
            pending[index].priority -= 50_000
        }
    }

    private func deliverCancellations(_ cancellations: [() -> Void]) {
        guard !cancellations.isEmpty else { return }
        cancellationQueue.async {
            cancellations.forEach { $0() }
        }
    }

    #if DEBUG
    private static let log = OSLog(subsystem: "com.curraghfisheries.SatChart", category: "MBTilesScheduler")
    #endif
}

nonisolated private final class MBTilesMemoryPressureMonitor: @unchecked Sendable {
    static let shared = MBTilesMemoryPressureMonitor()
    private var observers: [NSObjectProtocol] = []
    private let maintenanceQueue = DispatchQueue(
        label: "com.satchart.mbtiles.memory-maintenance",
        qos: .utility
    )

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            MBTilesWorkScheduler.shared.cancelSpeculativeWork()
            self?.maintenanceQueue.async {
                MBTilesTileCaches.shared.handleMemoryWarning()
                #if DEBUG
                os_log(.info, log: Self.log, "MBTiles caches reduced for memory warning")
                #endif
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            MBTilesWorkScheduler.shared.cancelSpeculativeWork()
            self?.maintenanceQueue.async { MBTilesTileCaches.shared.handleBackgrounding() }
        })
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            MBTilesWorkScheduler.shared.refreshForSystemState()
            let state = ProcessInfo.processInfo.thermalState
            if state == .serious || state == .critical {
                MBTilesWorkScheduler.shared.cancelSpeculativeWork()
            }
            let profile = MBTilesResourceProfile.current()
            self?.maintenanceQueue.async {
                MBTilesTileCaches.shared.applyResourceProfile(profile)
            }
        })
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [weak self] _ in
            MBTilesWorkScheduler.shared.refreshForSystemState()
            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                MBTilesWorkScheduler.shared.cancelSpeculativeWork()
            }
            let profile = MBTilesResourceProfile.current()
            self?.maintenanceQueue.async {
                MBTilesTileCaches.shared.applyResourceProfile(profile)
            }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    #if DEBUG
    private static let log = OSLog(subsystem: "com.curraghfisheries.SatChart", category: "MBTiles")
    #endif
}

nonisolated private enum MBTilesLookupResult { case found(Data), missing, failure(Error) }

nonisolated private struct MBTilesStoredCoverageEnvelope {
    let minimumX: Int
    let maximumX: Int
    let minimumStoredY: Int
    let maximumStoredY: Int

    func contains(x: Int, storedY: Int) -> Bool {
        (minimumX...maximumX).contains(x)
            && (minimumStoredY...maximumStoredY).contains(storedY)
    }
}

nonisolated private struct MBTilesReaderConfiguration {
    let scheme: MBTilesStorageScheme
    let minimumZoom: Int
    let maximumZoom: Int
}

/// A single read-only connection and reusable prepared statement. The package session
/// serializes all calls, so neither the connection nor statement crosses threads at once.
nonisolated private final class MBTilesSQLiteReader {
    private let url: URL
    private let immutableFile: Bool
    private let storageSchemeOverride: MBTilesStorageScheme?
    private var database: OpaquePointer?
    private var tileStatement: OpaquePointer?
    private var configurationValue: MBTilesReaderConfiguration?
    private var coverageByZoom: [Int: MBTilesStoredCoverageEnvelope] = [:]
    private var checkedCoverageZooms: Set<Int> = []

    init(url: URL, immutableFile: Bool, storageSchemeOverride: MBTilesStorageScheme?) {
        self.url = url
        self.immutableFile = immutableFile
        self.storageSchemeOverride = storageSchemeOverride
    }

    deinit { close() }

    func configuration() throws -> MBTilesReaderConfiguration {
        try openIfNeeded()
        guard let configurationValue else { throw MBTilesError.malformedSchema }
        return configurationValue
    }

    func lookup(_ coordinate: MBTilesTileCoordinate) -> MBTilesLookupResult {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        defer {
            MBTilesDiagnostics.shared.record(
                .sqlite,
                nanoseconds: DispatchTime.now().uptimeNanoseconds &- startedAt
            )
        }
        #if DEBUG
        let signpostID = OSSignpostID(log: Self.log)
        os_signpost(.begin, log: Self.log, name: "SQLiteLookup", signpostID: signpostID)
        defer { os_signpost(.end, log: Self.log, name: "SQLiteLookup", signpostID: signpostID) }
        #endif
        do {
            try openIfNeeded()
            guard let database, let tileStatement, let configurationValue else {
                return .failure(MBTilesError.malformedSchema)
            }

            let storedY = coordinate.storedY(for: configurationValue.scheme)
            if let coverage = storedCoverage(at: coordinate.z, database: database),
               !coverage.contains(x: coordinate.x, storedY: storedY) {
                MBTilesDiagnostics.shared.increment(.coverageRejection)
                return .missing
            }

            MBTilesDiagnostics.shared.increment(.sqliteLookup)
            sqlite3_reset(tileStatement)
            sqlite3_clear_bindings(tileStatement)
            sqlite3_bind_int64(tileStatement, 1, sqlite3_int64(coordinate.z))
            sqlite3_bind_int64(tileStatement, 2, sqlite3_int64(coordinate.x))
            sqlite3_bind_int64(tileStatement, 3, sqlite3_int64(storedY))

            switch sqlite3_step(tileStatement) {
            case SQLITE_ROW:
                guard let bytes = sqlite3_column_blob(tileStatement, 0) else { return .failure(MBTilesError.corruptTile) }
                let byteCount = Int(sqlite3_column_bytes(tileStatement, 0))
                guard byteCount > 0 else { return .failure(MBTilesError.corruptTile) }
                return .found(Data(bytes: bytes, count: byteCount))
            case SQLITE_DONE:
                return .missing
            default:
                let message = String(cString: sqlite3_errmsg(database))
                MBTilesDiagnostics.shared.increment(.sqliteFailure)
                return .failure(MBTilesError.sqlite(message))
            }
        } catch {
            MBTilesDiagnostics.shared.increment(.sqliteFailure)
            return .failure(error)
        }
    }

    func close() {
        if let tileStatement { sqlite3_finalize(tileStatement) }
        tileStatement = nil
        if let database {
            sqlite3_close_v2(database)
            MBTilesDiagnostics.shared.readerClosed()
        }
        database = nil
        configurationValue = nil
        coverageByZoom.removeAll(keepingCapacity: false)
        checkedCoverageZooms.removeAll(keepingCapacity: false)
    }

    private func openIfNeeded() throws {
        if database != nil { return }

        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
        let openPath: String
        if immutableFile {
            let escaped = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
            openPath = "file:\(escaped)?mode=ro&immutable=1"
        } else {
            openPath = url.path
        }

        guard sqlite3_open_v2(openPath, &pointer, flags, nil) == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown open error"
            if let pointer { sqlite3_close(pointer) }
            throw MBTilesError.openFailed(message)
        }
        database = pointer
        MBTilesDiagnostics.shared.readerOpened()
        do {
        sqlite3_busy_timeout(pointer, 1_000)
        sqlite3_exec(pointer, "PRAGMA query_only=ON;", nil, nil, nil)
        sqlite3_exec(pointer, "PRAGMA cache_size=-2048;", nil, nil, nil)
        sqlite3_exec(pointer, "PRAGMA mmap_size=0;", nil, nil, nil)

        let tilesHasData = tableExists("tiles", database: pointer)
            && columnExists("tile_data", in: "tiles", database: pointer)
        let normalizedSchema = tableExists("tiles", database: pointer)
            && columnExists("tile_id", in: "tiles", database: pointer)
            && tableExists("images", database: pointer)
            && columnExists("tile_data", in: "images", database: pointer)
        guard tilesHasData || normalizedSchema else { throw MBTilesError.malformedSchema }

        let sql: String
        if tilesHasData {
            sql = "SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=? LIMIT 1;"
        } else {
            sql = """
            SELECT images.tile_data FROM tiles
            JOIN images ON tiles.tile_id=images.tile_id
            WHERE tiles.zoom_level=? AND tiles.tile_column=? AND tiles.tile_row=?
            LIMIT 1;
            """
        }
        guard sqlite3_prepare_v3(pointer, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &tileStatement, nil) == SQLITE_OK else {
            throw MBTilesError.sqlite(String(cString: sqlite3_errmsg(pointer)))
        }

        let scheme: MBTilesStorageScheme
        if let storageSchemeOverride {
            scheme = storageSchemeOverride
        } else {
            scheme = try MBTilesStorageScheme.metadataValue(metadata("scheme", database: pointer))
        }
        let dataMin = singleInt("SELECT MIN(zoom_level) FROM tiles;", database: pointer)
        let dataMax = singleInt("SELECT MAX(zoom_level) FROM tiles;", database: pointer)
        let metadataMin = metadata("minzoom", database: pointer).flatMap(Self.parseInteger)
        let metadataMax = metadata("maxzoom", database: pointer).flatMap(Self.parseInteger)
        guard let minimumZoom = dataMin ?? metadataMin, let maximumZoom = dataMax ?? metadataMax else {
            throw MBTilesError.malformedSchema
        }
        configurationValue = MBTilesReaderConfiguration(
            scheme: scheme,
            minimumZoom: minimumZoom,
            maximumZoom: maximumZoom
        )
        } catch {
            close()
            throw error
        }
    }

    nonisolated private static func parseInteger(_ value: String) -> Int? {
        if let intValue = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) { return intValue }
        return Double(value.trimmingCharacters(in: .whitespacesAndNewlines)).map { Int($0.rounded(.towardZero)) }
    }

    private func tableExists(_ table: String, database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name=? LIMIT 1;", -1, &statement, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(statement, 1, table, -1, mbtilesSQLiteTransient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func columnExists(_ column: String, in table: String, database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else { return false }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1), String(cString: name).caseInsensitiveCompare(column) == .orderedSame {
                return true
            }
        }
        return false
    }

    private func metadata(_ name: String, database: OpaquePointer) -> String? {
        guard tableExists("metadata", database: database) else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT value FROM metadata WHERE name=? LIMIT 1;", -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(statement, 1, name, -1, mbtilesSQLiteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private func singleInt(_ sql: String, database: OpaquePointer) -> Int? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func storedCoverage(at zoom: Int, database: OpaquePointer) -> MBTilesStoredCoverageEnvelope? {
        if checkedCoverageZooms.contains(zoom) { return coverageByZoom[zoom] }
        checkedCoverageZooms.insert(zoom)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
        SELECT MIN(tile_column), MAX(tile_column), MIN(tile_row), MAX(tile_row)
        FROM tiles WHERE zoom_level=?;
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(statement, 1, sqlite3_int64(zoom))
        guard sqlite3_step(statement) == SQLITE_ROW,
              (0..<4).allSatisfy({ sqlite3_column_type(statement, Int32($0)) != SQLITE_NULL }) else {
            return nil
        }
        let envelope = MBTilesStoredCoverageEnvelope(
            minimumX: Int(sqlite3_column_int64(statement, 0)),
            maximumX: Int(sqlite3_column_int64(statement, 1)),
            minimumStoredY: Int(sqlite3_column_int64(statement, 2)),
            maximumStoredY: Int(sqlite3_column_int64(statement, 3))
        )
        coverageByZoom[zoom] = envelope
        return envelope
    }

    #if DEBUG
    private static let log = OSLog(subsystem: "com.curraghfisheries.SatChart", category: "MBTilesSQLite")
    #endif
}

nonisolated private enum MBTilesRasterFormat { case png, jpeg }

nonisolated enum MBTilesBackstopLoadOutcome {
    case image(CGImage)
    case missing
    case transientFailure
    case cancelled

    var image: CGImage? {
        if case .image(let image) = self { return image }
        return nil
    }
}

/// Long-lived provider state. It can safely outlive an MKMapView and be reused by a
/// renderer created for a later view, while callbacks remain scoped to their request.
nonisolated final class MBTilesPackageSession: @unchecked Sendable {
    typealias Completion = (Data?, Error?) -> Void

    /// A small admission object bounds the closures retained ahead of scheduler
    /// reconciliation. Its queue is serial so cache/in-flight bookkeeping cannot
    /// arrive in an unbounded concurrent burst from MapKit draw workers.
    private final class BoundedRequestIngress: @unchecked Sendable {
        private let queue = DispatchQueue(
            label: "com.satchart.mbtiles.request-ingress",
            qos: .userInitiated
        )
        private let lock = NSLock()
        private let capacity: Int
        private let visibleReserve: Int
        private var outstanding = 0

        init(capacity: Int, visibleReserve: Int) {
            self.capacity = max(1, capacity)
            self.visibleReserve = min(max(0, visibleReserve), max(0, capacity - 1))
        }

        @discardableResult
        func submit(
            isSpeculative: Bool = false,
            _ work: @escaping () -> Void
        ) -> Bool {
            lock.lock()
            let admissionLimit = isSpeculative
                ? capacity - visibleReserve
                : capacity
            guard outstanding < admissionLimit else {
                lock.unlock()
                return false
            }
            outstanding += 1
            lock.unlock()

            queue.async { [self] in
                autoreleasepool { work() }
                lock.lock()
                outstanding = max(0, outstanding - 1)
                lock.unlock()
            }
            return true
        }
    }

    private struct InFlightKey: Hashable {
        let output: MBTilesOutputKey
        let generation: UInt64
        let lifecycleEpoch: UInt64
    }

    private struct BackstopInFlightKey: Hashable {
        let output: MBTilesOutputKey
        let generation: UInt64
        let lifecycleEpoch: UInt64
    }

    private struct PendingCallbacks {
        let startedAt: UInt64
        let schedulerWorkID: UUID
        var callbacks: [Completion]
        var isSpeculative: Bool
    }

    private struct PendingBackstopCallbacks {
        let schedulerWorkID: UUID
        var callbacks: [(MBTilesBackstopLoadOutcome) -> Void]
        var isSpeculative: Bool
    }

    private struct ViewportAnchor {
        let zoom: Int
        let x: Int
        let y: Int

        func isMeaningfullyDistant(from other: ViewportAnchor) -> Bool {
            guard zoom == other.zoom else { return true }
            let side = Int64(1) << Int64(zoom)
            let directX = abs(Int64(x) - Int64(other.x))
            let wrappedX = min(directX, side - directX)
            let yDistance = abs(Int64(y) - Int64(other.y))
            return max(wrappedX, yDistance) >= 2
        }
    }

    private struct PendingViewportUpdate {
        let zoomLevel: Double
        let centerCoordinate: CLLocationCoordinate2D
        let commitGeneration: Bool
        let lifecycleEpoch: UInt64
    }

    struct ViewportStateSnapshot: Equatable {
        let generation: UInt64
        let preferredZoom: Int?
        let committedZoom: Int?
    }

    let identity: MBTilesOverlayIdentity
    static let maximumRequestIngress = MBTilesWorkScheduler.maximumQueuedWork
    private static let requestIngress = BoundedRequestIngress(
        capacity: maximumRequestIngress,
        visibleReserve: 64
    )
    private static let prefetchSubmissionQueue = DispatchQueue(
        label: "com.satchart.mbtiles.prefetch-submission",
        qos: .utility
    )
    private static let viewportUpdateQueue = DispatchQueue(
        label: "com.satchart.mbtiles.viewport-updates",
        qos: .userInitiated
    )
    private static let lifecycleQueue = DispatchQueue(
        label: "com.satchart.mbtiles.lifecycle",
        qos: .utility
    )
    private static let callbackQueue = DispatchQueue(
        label: "com.satchart.mbtiles.lifecycle-callbacks",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let reader: MBTilesSQLiteReader
    private let schedulerOwnerID = UUID()
    private let processingLock = NSLock()
    private let rasterLock = NSLock()
    private let stateLock = NSLock()
    private let viewportUpdateLock = NSLock()
    private let cacheMutationGroup = DispatchGroup()
    private let teardownCondition = NSCondition()
    private var invalidated = false
    private var suspended = false
    private var lifecycleEpoch: UInt64 = 0
    private var teardownCompleted = false
    private var viewportGeneration: UInt64 = 0
    private var retainedViewportGeneration: UInt64?
    private var preferredZoom: Int?
    private var viewportCenter: CLLocationCoordinate2D?
    private var viewportAnchor: ViewportAnchor?
    private var viewportUpdates = LatestOnlyWorkAccumulator<PendingViewportUpdate>()
    private var inFlight: [InFlightKey: PendingCallbacks] = [:]
    private var prefetchedOutputs: Set<MBTilesOutputKey> = []
    private var backstopInFlight: [BackstopInFlightKey: PendingBackstopCallbacks] = [:]
    private var underlyingLookups: UInt64 = 0

    init(identity: MBTilesOverlayIdentity, immutableFile: Bool) {
        self.identity = identity
        self.reader = MBTilesSQLiteReader(
            url: URL(fileURLWithPath: identity.canonicalPath),
            immutableFile: immutableFile,
            storageSchemeOverride: identity.storageSchemeOverride
        )
        _ = MBTilesMemoryPressureMonitor.shared
    }

    deinit { reader.close() }

    private func lifecycleAdmission() -> (epoch: UInt64, error: MBTilesError?) {
        stateLock.lock(); defer { stateLock.unlock() }
        if invalidated { return (lifecycleEpoch, .providerInvalidated) }
        if suspended { return (lifecycleEpoch, .requestSuperseded) }
        return (lifecycleEpoch, nil)
    }

    func activeLifecycleEpoch() -> UInt64? {
        let admission = lifecycleAdmission()
        return admission.error == nil ? admission.epoch : nil
    }

    func isActive(lifecycleEpoch expectedLifecycleEpoch: UInt64) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return !invalidated
            && !suspended
            && lifecycleEpoch == expectedLifecycleEpoch
    }

    /// MapKit may call `loadTile` from a latency-sensitive internal queue. Crossing
    /// this boundary before cache/state locking guarantees that admission never
    /// blocks the caller while another request is being reconciled or evicted.
    func scheduleLoad(path: MKTileOverlayPath, completion: @escaping Completion) {
        let admissionStartedAt = DispatchTime.now().uptimeNanoseconds
        let admission = lifecycleAdmission()
        guard let admissionError = admission.error else {
            scheduleLoad(
                path: path,
                priorityBias: 0,
                isSpeculative: false,
                lifecycleEpoch: admission.epoch,
                completion: completion
            )
            return
        }
        MBTilesDiagnostics.shared.increment(.request)
        Self.callbackQueue.async { [self] in
            complete(
                completion,
                data: nil,
                error: admissionError,
                startedAt: admissionStartedAt
            )
        }
    }

    private func scheduleLoad(
        path: MKTileOverlayPath,
        priorityBias: Int,
        isSpeculative: Bool,
        lifecycleEpoch: UInt64,
        completion: @escaping Completion
    ) {
        let admissionStartedAt = DispatchTime.now().uptimeNanoseconds
        let admitted = Self.requestIngress.submit(isSpeculative: isSpeculative) { [self] in
            load(
                path: path,
                priorityBias: priorityBias,
                isSpeculative: isSpeculative,
                lifecycleEpoch: lifecycleEpoch,
                completion: completion
            )
        }
        guard !admitted else { return }
        // Rejection owns the callback just as accepted work does. Dispatching it
        // away from MapKit's caller avoids re-entrancy and guarantees one terminal
        // transient result without ever placing the closure on the ingress queue.
        MBTilesDiagnostics.shared.increment(.request)
        Self.callbackQueue.async { [self] in
            complete(
                completion,
                data: nil,
                error: MBTilesError.queueFull,
                startedAt: admissionStartedAt
            )
        }
    }

    /// Coalesces MapKit's high-frequency camera callbacks before touching session
    /// or scheduler state. The caller takes only this tiny dedicated lock, so a
    /// cache eviction or SQLite read can never stall the main thread.
    func updateViewport(
        zoomLevel: Double,
        centerCoordinate: CLLocationCoordinate2D,
        commitGeneration: Bool = true
    ) {
        guard zoomLevel.isFinite,
              CLLocationCoordinate2DIsValid(centerCoordinate) else { return }
        guard let lifecycleEpoch = activeLifecycleEpoch() else { return }
        viewportUpdateLock.lock()
        let shouldSchedule = viewportUpdates.submit(PendingViewportUpdate(
            zoomLevel: zoomLevel,
            centerCoordinate: centerCoordinate,
            commitGeneration: commitGeneration,
            lifecycleEpoch: lifecycleEpoch
        ))
        viewportUpdateLock.unlock()

        guard shouldSchedule else { return }
        Self.viewportUpdateQueue.async { [weak self] in
            self?.drainViewportUpdates()
        }
    }

    private func drainViewportUpdates() {
        while true {
            viewportUpdateLock.lock()
            guard let update = viewportUpdates.takeLatest() else {
                _ = viewportUpdates.finishDrainIfEmpty()
                viewportUpdateLock.unlock()
                return
            }
            viewportUpdateLock.unlock()
            applyViewportUpdate(update)
        }
    }

    private func applyViewportUpdate(_ update: PendingViewportUpdate) {
        stateLock.lock()
        guard !invalidated,
              !suspended,
              lifecycleEpoch == update.lifecycleEpoch else {
            stateLock.unlock()
            return
        }
        let zoom = MBTilesViewportZoomPolicy.bucket(
            for: update.zoomLevel,
            previous: preferredZoom,
            minimum: identity.minimumZoom,
            maximum: identity.maximumZoom
        )
        let anchor = Self.viewportAnchor(for: update.centerCoordinate, zoom: zoom)
        preferredZoom = zoom
        viewportCenter = update.centerCoordinate

        if update.commitGeneration {
            let viewportChanged = viewportAnchor.map {
                anchor.isMeaningfullyDistant(from: $0)
            } ?? false
            if viewportChanged {
                viewportGeneration &+= 1
                retainedViewportGeneration = viewportGeneration > 0
                    ? viewportGeneration - 1
                    : nil
                prefetchedOutputs.removeAll(keepingCapacity: true)
                MBTilesWorkScheduler.shared.scheduleGenerationAdvance(
                    ownerID: schedulerOwnerID,
                    to: viewportGeneration,
                    retainingPrevious: true
                )
            }
            // Continuous priority hints intentionally never overwrite this committed
            // anchor; otherwise the final settled update would appear unchanged.
            viewportAnchor = anchor
        }
        stateLock.unlock()
    }

    static func flushScheduledViewportUpdatesForTesting() {
        viewportUpdateQueue.sync {}
    }

    var viewportStateSnapshot: ViewportStateSnapshot {
        stateLock.lock(); defer { stateLock.unlock() }
        return ViewportStateSnapshot(
            generation: viewportGeneration,
            preferredZoom: preferredZoom,
            committedZoom: viewportAnchor?.zoom
        )
    }

    private static func viewportAnchor(
        for coordinate: CLLocationCoordinate2D,
        zoom: Int
    ) -> ViewportAnchor {
        let side = Double(Int64(1) << Int64(zoom))
        let longitude = min(180, max(-180, coordinate.longitude))
        let latitude = min(85.051_128_78, max(-85.051_128_78, coordinate.latitude))
        let latitudeRadians = latitude * .pi / 180
        let rawX = Int(floor((longitude + 180) / 360 * side))
        let rawY = Int(floor(
            (1 - Darwin.log(tan(latitudeRadians) + (1 / cos(latitudeRadians))) / .pi) / 2 * side
        ))
        let maximumIndex = max(0, Int(side) - 1)
        return ViewportAnchor(
            zoom: zoom,
            x: min(maximumIndex, max(0, rawX)),
            y: min(maximumIndex, max(0, rawY))
        )
    }

    func load(
        path: MKTileOverlayPath,
        priorityBias: Int = 0,
        isSpeculative: Bool = false,
        lifecycleEpoch lifecycleEpochTicket: UInt64? = nil,
        completion: @escaping Completion
    ) {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        MBTilesDiagnostics.shared.increment(.request)
        stateLock.lock()
        let initialInvalidated = invalidated
        let initialSuspended = suspended
        let admissionEpoch = lifecycleEpochTicket ?? lifecycleEpoch
        let initialEpochMismatch = admissionEpoch != lifecycleEpoch
        stateLock.unlock()
        if initialInvalidated {
            complete(completion, data: nil, error: MBTilesError.providerInvalidated, startedAt: startedAt)
            return
        }
        if initialSuspended || initialEpochMismatch {
            complete(completion, data: nil, error: MBTilesError.requestSuperseded, startedAt: startedAt)
            return
        }
        guard let coordinate = MBTilesTileCoordinate(z: path.z, x: path.x, y: path.y) else {
            complete(completion, data: nil, error: MBTilesError.invalidCoordinate, startedAt: startedAt)
            return
        }
        // MKTileOverlayPath has no scale component; output pixels are fixed by identity.tileSizePixels.
        let key = MBTilesOutputKey(identity: identity, coordinate: coordinate, contentScaleBits: 0)

        if let cached = MBTilesTileCaches.shared.generatedData(for: key) {
            MBTilesDiagnostics.shared.increment(.fallbackHit)
            complete(completion, data: cached, error: nil, startedAt: startedAt)
            return
        }
        let storedKey = MBTilesStoredKey(sourceIdentity: identity.sourceIdentity, coordinate: coordinate)
        if identity.visualSettings.isNeutral,
           let cached = MBTilesTileCaches.shared.compressedData(for: storedKey) {
            MBTilesDiagnostics.shared.increment(.directHit)
            complete(completion, data: cached, error: nil, startedAt: startedAt)
            return
        }
        if MBTilesTileCaches.shared.isNegative(key) {
            MBTilesDiagnostics.shared.increment(.trueMiss)
            complete(completion, data: nil, error: nil, startedAt: startedAt)
            return
        }

        stateLock.lock()
        if invalidated {
            stateLock.unlock()
            complete(completion, data: nil, error: MBTilesError.providerInvalidated, startedAt: startedAt)
            return
        }
        if suspended || lifecycleEpoch != admissionEpoch {
            stateLock.unlock()
            complete(completion, data: nil, error: MBTilesError.requestSuperseded, startedAt: startedAt)
            return
        }
        let generation = viewportGeneration
        let priority = schedulingPriority(for: coordinate, preferredZoom: preferredZoom, center: viewportCenter)
            + priorityBias
        let inFlightKey = InFlightKey(
            output: key,
            generation: generation,
            lifecycleEpoch: admissionEpoch
        )
        if var pending = inFlight[inFlightKey] {
            pending.callbacks.append(completion)
            let shouldPromote = pending.isSpeculative && !isSpeculative
            if shouldPromote { pending.isSpeculative = false }
            inFlight[inFlightKey] = pending
            stateLock.unlock()
            if shouldPromote {
                MBTilesWorkScheduler.shared.promoteSpeculativeWork(
                    workID: pending.schedulerWorkID,
                    visiblePriority: priority
                )
            }
            MBTilesDiagnostics.shared.increment(.coalesced)
            return
        }
        // The first request may have completed between the optimistic cache check
        // above and acquiring the in-flight lock. Check once more before creating
        // work so a late-arriving duplicate cannot start a second SQLite lookup.
        if let cached = MBTilesTileCaches.shared.generatedData(for: key) {
            stateLock.unlock()
            MBTilesDiagnostics.shared.increment(.fallbackHit)
            complete(completion, data: cached, error: nil, startedAt: startedAt)
            return
        }
        if identity.visualSettings.isNeutral,
           let cached = MBTilesTileCaches.shared.compressedData(for: storedKey) {
            stateLock.unlock()
            MBTilesDiagnostics.shared.increment(.directHit)
            complete(completion, data: cached, error: nil, startedAt: startedAt)
            return
        }
        if MBTilesTileCaches.shared.isNegative(key) {
            stateLock.unlock()
            MBTilesDiagnostics.shared.increment(.trueMiss)
            complete(completion, data: nil, error: nil, startedAt: startedAt)
            return
        }
        let schedulerWorkID = UUID()
        inFlight[inFlightKey] = PendingCallbacks(
            startedAt: startedAt,
            schedulerWorkID: schedulerWorkID,
            callbacks: [completion],
            isSpeculative: isSpeculative
        )
        underlyingLookups &+= 1
        stateLock.unlock()

        let submission = MBTilesWorkScheduler.shared.submit(
            ownerID: schedulerOwnerID,
            generation: generation,
            workID: schedulerWorkID,
            priority: priority,
            isSpeculative: isSpeculative,
            execute: { [self] in perform(key: inFlightKey) },
            cancel: { [weak self] in
                self?.finish(key: inFlightKey, data: nil, error: MBTilesError.requestSuperseded)
            }
        )
        switch submission {
        case .accepted:
            // Submission happens after releasing stateLock so the scheduler cannot
            // participate in a session-lock cycle. Recheck both terminal states:
            // retirement may suspend the session in that small admission window.
            stateLock.lock()
            let shouldCancelAfterSubmit = invalidated
                || suspended
                || lifecycleEpoch != admissionEpoch
            stateLock.unlock()
            if shouldCancelAfterSubmit {
                MBTilesWorkScheduler.shared.cancelQueuedWork(
                    ownerID: schedulerOwnerID,
                    workID: schedulerWorkID
                )
            }
        case .superseded:
            finish(key: inFlightKey, data: nil, error: MBTilesError.requestSuperseded)
        case .saturated:
            finish(key: inFlightKey, data: nil, error: MBTilesError.queueFull)
        }
    }

    /// Starts bounded, low-priority work for tiles bordering the current viewport.
    /// Each output is submitted only once per viewport generation; a real MapKit
    /// request still coalesces with it or reads the populated cache synchronously.
    private func prefetch(
        coordinates: [MBTilesTileCoordinate],
        lifecycleEpoch: UInt64
    ) {
        stateLock.lock()
        guard !invalidated,
              !suspended,
              self.lifecycleEpoch == lifecycleEpoch else {
            stateLock.unlock()
            return
        }
        let pending = coordinates.filter { prefetchedOutputs.insert(MBTilesOutputKey(
            identity: identity,
            coordinate: $0,
            contentScaleBits: 0
        )).inserted }
        stateLock.unlock()

        for coordinate in pending {
            let key = MBTilesOutputKey(identity: identity, coordinate: coordinate, contentScaleBits: 0)
            let path = MKTileOverlayPath(x: coordinate.x, y: coordinate.y, z: coordinate.z, contentScaleFactor: 1)
            scheduleLoad(
                path: path,
                priorityBias: -25_000,
                isSpeculative: true,
                lifecycleEpoch: lifecycleEpoch
            ) { [weak self] _, error in
                guard let self, let error = error as? MBTilesError else { return }
                switch error {
                case .queueFull, .requestSuperseded: break
                default: return
                }
                self.stateLock.lock()
                if self.lifecycleEpoch == lifecycleEpoch {
                    self.prefetchedOutputs.remove(key)
                }
                self.stateLock.unlock()
            }
        }
    }

    func schedulePrefetch(coordinates: [MBTilesTileCoordinate]) {
        guard !coordinates.isEmpty else { return }
        guard let lifecycleEpoch = activeLifecycleEpoch() else { return }
        Self.prefetchSubmissionQueue.async { [weak self] in
            self?.prefetch(
                coordinates: coordinates,
                lifecycleEpoch: lifecycleEpoch
            )
        }
    }

    func scheduleBackstopPrefetch(coordinates: [MBTilesTileCoordinate]) {
        guard !coordinates.isEmpty else { return }
        guard let lifecycleEpoch = activeLifecycleEpoch() else { return }
        Self.prefetchSubmissionQueue.async { [weak self] in
            guard let self else { return }
            guard self.isActive(lifecycleEpoch: lifecycleEpoch) else { return }
            coordinates.forEach { coordinate in
                self.scheduleBackstopOutcome(
                    for: coordinate,
                    isSpeculative: true,
                    lifecycleEpoch: lifecycleEpoch
                ) { _ in }
            }
        }
    }

    func cachedBackstopImage(for coordinate: MBTilesTileCoordinate) -> CGImage? {
        MBTilesTileCaches.shared.backstopImage(for: MBTilesOutputKey(
            identity: identity,
            coordinate: coordinate,
            contentScaleBits: 0
        ))
    }

    func isKnownMissingBackstopImage(for coordinate: MBTilesTileCoordinate) -> Bool {
        MBTilesTileCaches.shared.isNegative(MBTilesOutputKey(
            identity: identity,
            coordinate: coordinate,
            contentScaleBits: 0
        ))
    }

    /// Moves renderer-originated cache/state work away from MapKit's concurrent draw
    /// callbacks before joining the bounded visible-work lane.
    func scheduleBackstopImageLoad(
        for coordinate: MBTilesTileCoordinate,
        isSpeculative: Bool = false,
        completion: @escaping (CGImage?) -> Void
    ) {
        scheduleBackstopOutcome(
            for: coordinate,
            isSpeculative: isSpeculative
        ) { completion($0.image) }
    }

    func scheduleBackstopOutcome(
        for coordinate: MBTilesTileCoordinate,
        isSpeculative: Bool = false,
        lifecycleEpoch lifecycleEpochTicket: UInt64? = nil,
        completion: @escaping (MBTilesBackstopLoadOutcome) -> Void
    ) {
        let admission = lifecycleAdmission()
        let admissionEpoch = lifecycleEpochTicket ?? admission.epoch
        guard admission.error == nil, admissionEpoch == admission.epoch else {
            Self.callbackQueue.async { completion(.cancelled) }
            return
        }
        let admitted = Self.requestIngress.submit(isSpeculative: isSpeculative) { [self] in
            loadBackstopOutcome(
                for: coordinate,
                isSpeculative: isSpeculative,
                lifecycleEpoch: admissionEpoch,
                completion: completion
            )
        }
        guard !admitted else { return }
        Self.callbackQueue.async {
            completion(.transientFailure)
        }
    }

    /// Loads a native-detail image directly into the continuity cache. Unlike the
    /// MKTileOverlay byte path, this never encodes an adjusted or ancestor-derived
    /// image only to decode it again for drawing.
    func loadBackstopImage(
        for coordinate: MBTilesTileCoordinate,
        isSpeculative: Bool = false,
        completion: @escaping (CGImage?) -> Void
    ) {
        loadBackstopOutcome(
            for: coordinate,
            isSpeculative: isSpeculative
        ) { completion($0.image) }
    }

    func loadBackstopOutcome(
        for coordinate: MBTilesTileCoordinate,
        isSpeculative: Bool = false,
        lifecycleEpoch lifecycleEpochTicket: UInt64? = nil,
        completion: @escaping (MBTilesBackstopLoadOutcome) -> Void
    ) {
        let outputKey = MBTilesOutputKey(identity: identity, coordinate: coordinate, contentScaleBits: 0)
        stateLock.lock()
        let admissionEpoch = lifecycleEpochTicket ?? lifecycleEpoch
        let initiallyUnavailable = invalidated
            || suspended
            || admissionEpoch != lifecycleEpoch
        stateLock.unlock()
        if initiallyUnavailable {
            completion(.cancelled)
            return
        }
        if let cached = MBTilesTileCaches.shared.backstopImage(for: outputKey) {
            completion(.image(cached))
            return
        }
        if MBTilesTileCaches.shared.isNegative(outputKey) {
            completion(.missing)
            return
        }

        stateLock.lock()
        if invalidated || suspended || lifecycleEpoch != admissionEpoch {
            stateLock.unlock()
            completion(.cancelled)
            return
        }
        let generation = viewportGeneration
        let inFlightKey = BackstopInFlightKey(
            output: outputKey,
            generation: generation,
            lifecycleEpoch: admissionEpoch
        )
        let visiblePriority = schedulingPriority(
            for: coordinate,
            preferredZoom: preferredZoom,
            center: viewportCenter
        ) + (isSpeculative ? -25_000 : 5_000)
        if var pending = backstopInFlight[inFlightKey] {
            pending.callbacks.append(completion)
            let shouldPromote = pending.isSpeculative && !isSpeculative
            if shouldPromote { pending.isSpeculative = false }
            backstopInFlight[inFlightKey] = pending
            stateLock.unlock()
            if shouldPromote {
                MBTilesWorkScheduler.shared.promoteSpeculativeWork(
                    workID: pending.schedulerWorkID,
                    visiblePriority: visiblePriority
                )
            }
            return
        }
        let schedulerWorkID = UUID()
        backstopInFlight[inFlightKey] = PendingBackstopCallbacks(
            schedulerWorkID: schedulerWorkID,
            callbacks: [completion],
            isSpeculative: isSpeculative
        )
        stateLock.unlock()

        let submission = MBTilesWorkScheduler.shared.submit(
            ownerID: schedulerOwnerID,
            generation: generation,
            workID: schedulerWorkID,
            priority: visiblePriority,
            isSpeculative: isSpeculative,
            execute: { [self] in
                performBackstopImage(key: inFlightKey)
            },
            cancel: { [weak self] in
                guard let self else { return }
                let outcome = self.backstopTerminalOutcome(
                    for: inFlightKey.generation,
                    lifecycleEpoch: inFlightKey.lifecycleEpoch
                ) ?? .transientFailure
                self.finishBackstopImage(key: inFlightKey, outcome: outcome)
            }
        )
        switch submission {
        case .accepted:
            // Retirement can race the unlocked scheduler submission above. Fence
            // any work accepted after the session became inactive.
            stateLock.lock()
            let shouldCancelAfterSubmit = invalidated
                || suspended
                || lifecycleEpoch != admissionEpoch
            stateLock.unlock()
            if shouldCancelAfterSubmit {
                MBTilesWorkScheduler.shared.cancelQueuedWork(
                    ownerID: schedulerOwnerID,
                    workID: schedulerWorkID
                )
            }
        case .superseded, .saturated:
            let outcome = backstopTerminalOutcome(
                for: inFlightKey.generation,
                lifecycleEpoch: inFlightKey.lifecycleEpoch
            ) ?? .transientFailure
            finishBackstopImage(key: inFlightKey, outcome: outcome)
        }
    }

    private func performBackstopImage(
        key: BackstopInFlightKey
    ) {
        if Thread.isMainThread { MBTilesDiagnostics.shared.increment(.mainThreadWorkViolation) }
        if let outcome = backstopTerminalOutcome(
            for: key.generation,
            lifecycleEpoch: key.lifecycleEpoch
        ) {
            finishBackstopImage(key: key, outcome: outcome)
            return
        }

        processingLock.lock()
        if let outcome = backstopTerminalOutcome(
            for: key.generation,
            lifecycleEpoch: key.lifecycleEpoch
        ) {
            processingLock.unlock()
            finishBackstopImage(key: key, outcome: outcome)
            return
        }
        let resolved = resolveTileSource(for: key.output)
        processingLock.unlock()
        if let outcome = backstopTerminalOutcome(
            for: key.generation,
            lifecycleEpoch: key.lifecycleEpoch
        ) {
            finishBackstopImage(key: key, outcome: outcome)
            return
        }

        rasterLock.lock()
        if let outcome = backstopTerminalOutcome(
            for: key.generation,
            lifecycleEpoch: key.lifecycleEpoch
        ) {
            rasterLock.unlock()
            finishBackstopImage(key: key, outcome: outcome)
            return
        }
        let image = autoreleasepool {
            MBTilesTileCaches.shared.backstopImage(for: key.output)
                ?? renderedBackstopImage(from: resolved, for: key.output)
        }
        let confirmedMissing: Bool
        if case .missing = resolved { confirmedMissing = true }
        else { confirmedMissing = false }
        cacheIfValid {
            if let image { MBTilesTileCaches.shared.insertBackstop(image, for: key.output) }
            else if confirmedMissing { MBTilesTileCaches.shared.insertNegative(key.output) }
        }
        rasterLock.unlock()
        if let outcome = backstopTerminalOutcome(
            for: key.generation,
            lifecycleEpoch: key.lifecycleEpoch
        ) {
            finishBackstopImage(key: key, outcome: outcome)
            return
        }
        switch resolved {
        case .direct: MBTilesDiagnostics.shared.increment(.directHit)
        case .fallback: MBTilesDiagnostics.shared.increment(.fallbackHit)
        case .missing, .failure: break
        }
        let outcome: MBTilesBackstopLoadOutcome
        if let image { outcome = .image(image) }
        else if confirmedMissing { outcome = .missing }
        else { outcome = .transientFailure }
        finishBackstopImage(key: key, outcome: outcome)
    }

    private func finishBackstopImage(
        key: BackstopInFlightKey,
        outcome: MBTilesBackstopLoadOutcome
    ) {
        stateLock.lock()
        let callbacks = backstopInFlight.removeValue(forKey: key)?.callbacks ?? []
        let deliveredOutcome: MBTilesBackstopLoadOutcome
        if invalidated
            || suspended
            || lifecycleEpoch != key.lifecycleEpoch {
            deliveredOutcome = .cancelled
        } else if key.generation < viewportGeneration,
                  key.generation != retainedViewportGeneration {
            deliveredOutcome = .transientFailure
        } else {
            deliveredOutcome = outcome
        }
        stateLock.unlock()
        callbacks.forEach { $0(deliveredOutcome) }
    }

    func suspendQueuedWork() {
        viewportUpdateLock.lock()
        viewportUpdates.discardPending()
        viewportUpdateLock.unlock()
        stateLock.lock()
        guard !invalidated, !suspended else {
            stateLock.unlock()
            return
        }
        suspended = true
        lifecycleEpoch &+= 1
        prefetchedOutputs.removeAll(keepingCapacity: true)
        // Keep resume behind the owner-wide scheduler sweep. Admissions already
        // between registration and submit carry the old epoch and self-cancel.
        MBTilesWorkScheduler.shared.cancelQueuedWork(ownerID: schedulerOwnerID)
        stateLock.unlock()
    }

    func resume() {
        stateLock.lock()
        guard !invalidated else {
            stateLock.unlock()
            return
        }
        suspended = false
        stateLock.unlock()
    }

    func invalidate(
        purgeCaches: Bool = true,
        waitForTeardown: Bool = false
    ) {
        // Drop any latest-only camera hint that has not reached session state yet.
        // An already-running drain observes `invalidated` under stateLock below.
        viewportUpdateLock.lock()
        viewportUpdates.discardPending()
        viewportUpdateLock.unlock()

        stateLock.lock()
        guard !invalidated else {
            stateLock.unlock()
            if waitForTeardown { waitUntilTeardownCompletes() }
            return
        }
        invalidated = true
        let callbacks = inFlight.values.flatMap(\.callbacks)
        let backstopCallbacks = backstopInFlight.values.flatMap(\.callbacks)
        inFlight.removeAll()
        backstopInFlight.removeAll()
        prefetchedOutputs.removeAll()
        stateLock.unlock()

        MBTilesWorkScheduler.shared.cancelQueuedWork(ownerID: schedulerOwnerID)
        // Session retirement is often initiated by MapKit overlay removal on the
        // main thread. Cache scans and waiting for an active SQLite read therefore
        // belong on a lifecycle queue; logical invalidation above remains immediate.
        Self.callbackQueue.async { [self] in
            callbacks.forEach {
                complete($0, data: nil, error: MBTilesError.providerInvalidated)
            }
            backstopCallbacks.forEach { $0(.cancelled) }
        }
        let teardown: @Sendable () -> Void = { [self] in
            defer {
                teardownCondition.lock()
                teardownCompleted = true
                teardownCondition.broadcast()
                teardownCondition.unlock()
            }
            // Cache mutation tickets are entered while holding stateLock before
            // invalidation can begin. Waiting here guarantees that the purge is the
            // final mutation for this immutable provider identity.
            cacheMutationGroup.wait()
            if purgeCaches {
                rasterLock.lock()
                MBTilesTileCaches.shared.invalidate(identity: identity)
                rasterLock.unlock()
            }
            processingLock.lock()
            reader.close()
            processingLock.unlock()
        }
        if waitForTeardown { teardown() }
        else { Self.lifecycleQueue.async(execute: teardown) }
    }

    private func waitUntilTeardownCompletes() {
        teardownCondition.lock()
        while !teardownCompleted {
            teardownCondition.wait()
        }
        teardownCondition.unlock()
    }

    var underlyingLookupCount: UInt64 {
        stateLock.lock(); defer { stateLock.unlock() }
        return underlyingLookups
    }

    var inFlightCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return inFlight.count
    }

    var backstopInFlightCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return backstopInFlight.count
    }

    private func perform(key: InFlightKey) {
        #if DEBUG
        let signpostID = OSSignpostID(log: Self.log)
        os_signpost(.begin, log: Self.log, name: "TileRequest", signpostID: signpostID)
        defer { os_signpost(.end, log: Self.log, name: "TileRequest", signpostID: signpostID) }
        #endif
        if Thread.isMainThread { MBTilesDiagnostics.shared.increment(.mainThreadWorkViolation) }
        if let error = terminalError(
            for: key.generation,
            lifecycleEpoch: key.lifecycleEpoch
        ) {
            finish(key: key, data: nil, error: error)
            return
        }

        processingLock.lock()
        if let error = terminalError(
            for: key.generation,
            lifecycleEpoch: key.lifecycleEpoch
        ) {
            processingLock.unlock()
            finish(key: key, data: nil, error: error)
            return
        }
        let resolved = resolveTileSource(for: key.output)
        processingLock.unlock()
        if let error = terminalError(
            for: key.generation,
            lifecycleEpoch: key.lifecycleEpoch
        ) {
            finish(key: key, data: nil, error: error)
            return
        }
        let result = autoreleasepool {
            identity.visualSettings.isNeutral
                ? render(resolved, for: key.output)
                : renderAdjusted(
                    resolved,
                    for: key.output,
                    generation: key.generation,
                    lifecycleEpoch: key.lifecycleEpoch
                )
        }

        if let error = terminalError(
            for: key.generation,
            lifecycleEpoch: key.lifecycleEpoch
        ) {
            finish(key: key, data: nil, error: error)
            return
        }

        switch result {
        case .found(let data, let source):
            cacheIfValid {
                if identity.visualSettings.isNeutral {
                    switch source {
                    case .direct:
                        MBTilesTileCaches.shared.insertCompressed(
                            data,
                            for: MBTilesStoredKey(
                                sourceIdentity: identity.sourceIdentity,
                                coordinate: key.output.coordinate
                            )
                        )
                        MBTilesDiagnostics.shared.increment(.directHit)
                    case .fallback:
                        MBTilesTileCaches.shared.insertGenerated(data, for: key.output)
                        MBTilesDiagnostics.shared.increment(.fallbackHit)
                    }
                } else {
                    // Appearance is immutable provider state and part of the output
                    // identity, so adjusted and neutral bytes cannot share a cache key.
                    MBTilesTileCaches.shared.insertGenerated(data, for: key.output)
                    switch source {
                    case .direct: MBTilesDiagnostics.shared.increment(.directHit)
                    case .fallback: MBTilesDiagnostics.shared.increment(.fallbackHit)
                    }
                }
            }
            finish(key: key, data: data, error: nil)
        case .missing:
            cacheIfValid { MBTilesTileCaches.shared.insertNegative(key.output) }
            MBTilesDiagnostics.shared.increment(.trueMiss)
            finish(key: key, data: nil, error: nil)
        case .failure(let error):
            finish(key: key, data: nil, error: error)
        }
    }

    private func terminalError(
        for generation: UInt64,
        lifecycleEpoch expectedLifecycleEpoch: UInt64
    ) -> MBTilesError? {
        stateLock.lock(); defer { stateLock.unlock() }
        if invalidated { return .providerInvalidated }
        if suspended || lifecycleEpoch != expectedLifecycleEpoch {
            return .requestSuperseded
        }
        if generation < viewportGeneration,
           generation != retainedViewportGeneration {
            return .requestSuperseded
        }
        return nil
    }

    private func backstopTerminalOutcome(
        for generation: UInt64,
        lifecycleEpoch expectedLifecycleEpoch: UInt64
    ) -> MBTilesBackstopLoadOutcome? {
        stateLock.lock(); defer { stateLock.unlock() }
        // Invalidation and retirement are terminal for this renderer request.
        // Treating retirement as transient would keep retrying a detached overlay.
        if invalidated || suspended || lifecycleEpoch != expectedLifecycleEpoch {
            return .cancelled
        }
        if generation < viewportGeneration,
           generation != retainedViewportGeneration {
            return .transientFailure
        }
        return nil
    }

    private enum TileSource { case direct, fallback }
    private enum ProducedTile { case found(Data, TileSource), missing, failure(Error) }
    private enum ResolvedTile {
        case direct(Data)
        case fallback(sourceData: Data, sourceKey: MBTilesStoredKey, depth: Int)
        case missing
        case failure(Error)
    }

    /// Resolves compressed source bytes while the package's single SQLite reader is
    /// locked. Image validation, decoding, cropping, and encoding deliberately happen
    /// after this method returns so they can use the bounded concurrent worker pool.
    private func resolveTileSource(for key: MBTilesOutputKey) -> ResolvedTile {
        let configuration: MBTilesReaderConfiguration
        do { configuration = try reader.configuration() }
        catch { return .failure(error) }

        let nativeMaximum = identity.nativeDetailMaximumZoom
            .map { min(configuration.maximumZoom, $0) }
        let exactStoredKey = MBTilesStoredKey(
            sourceIdentity: identity.sourceIdentity,
            coordinate: key.coordinate
        )
        if nativeMaximum == nil || key.coordinate.z <= nativeMaximum! {
            if let cached = MBTilesTileCaches.shared.compressedData(for: exactStoredKey) {
                return .direct(cached)
            }

            switch reader.lookup(key.coordinate) {
            case .found(let data):
                return .direct(data)
            case .failure(let error): return .failure(error)
            case .missing: break
            }
        }

        let availableDepth = min(identity.maximumFallbackDepth, key.coordinate.z - configuration.minimumZoom)
        let firstDepth = nativeMaximum.map { max(1, key.coordinate.z - $0) } ?? 1
        guard availableDepth >= firstDepth else { return .missing }

        for depth in firstDepth...availableDepth {
            guard let ancestor = key.coordinate.ancestor(depth: depth) else { continue }
            let ancestorKey = MBTilesStoredKey(
                sourceIdentity: identity.sourceIdentity,
                coordinate: ancestor
            )
            let sourceData: Data
            if let cached = MBTilesTileCaches.shared.compressedData(for: ancestorKey) {
                sourceData = cached
            } else {
                switch reader.lookup(ancestor) {
                case .found(let data):
                    sourceData = data
                case .missing: continue
                case .failure(let error): return .failure(error)
                }
            }
            return .fallback(sourceData: sourceData, sourceKey: ancestorKey, depth: depth)
        }

        return .missing
    }

    private func render(_ resolved: ResolvedTile, for key: MBTilesOutputKey) -> ProducedTile {
        switch resolved {
        case .direct(let data):
            guard rasterDescription(data) != nil else {
                MBTilesDiagnostics.shared.increment(.corruptTile)
                return .failure(MBTilesError.corruptTile)
            }
            return .found(data, .direct)
        case .fallback(let sourceData, let sourceKey, let depth):
            guard let generated = renderFallback(
                sourceData: sourceData,
                sourceKey: sourceKey,
                requested: key.coordinate,
                depth: depth,
                outputPixels: identity.tileSizePixels
            ) else {
                MBTilesDiagnostics.shared.increment(.corruptTile)
                return .failure(MBTilesError.corruptTile)
            }
            cacheIfValid { MBTilesTileCaches.shared.insertCompressed(sourceData, for: sourceKey) }
            return .found(generated, .fallback)
        case .missing:
            return .missing
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Produces adjusted MapKit bytes from the same canonical CGImage consumed by the
    /// native-detail continuity renderer. Direct tiles are decoded and filtered once;
    /// ancestor tiles are cropped, filtered, and encoded once rather than taking the
    /// former encode -> decode -> filter -> encode path.
    private func renderAdjusted(
        _ resolved: ResolvedTile,
        for key: MBTilesOutputKey,
        generation: UInt64,
        lifecycleEpoch: UInt64
    ) -> ProducedTile {
        let source: TileSource
        let sourceData: Data
        switch resolved {
        case .direct(let data):
            source = .direct
            sourceData = data
        case .fallback(let data, _, _):
            source = .fallback
            sourceData = data
        case .missing:
            return .missing
        case .failure(let error):
            return .failure(error)
        }
        guard let format = rasterDescription(sourceData)?.format else {
            MBTilesDiagnostics.shared.increment(.corruptTile)
            return .failure(MBTilesError.corruptTile)
        }

        rasterLock.lock()
        defer { rasterLock.unlock() }
        if let error = terminalError(
            for: generation,
            lifecycleEpoch: lifecycleEpoch
        ) {
            return .failure(error)
        }
        let continuityZoom = min(
            identity.maximumZoom,
            max(
                identity.minimumZoom,
                identity.nativeDetailMaximumZoom ?? identity.maximumZoom
            )
        )
        let shouldPopulateContinuity = key.coordinate.z == continuityZoom
        let image = (shouldPopulateContinuity
            ? MBTilesTileCaches.shared.backstopImage(for: key)
            : nil) ?? renderedBackstopImage(from: resolved, for: key)
        guard let image else {
            MBTilesDiagnostics.shared.increment(.corruptTile)
            return .failure(MBTilesError.corruptTile)
        }
        if shouldPopulateContinuity {
            cacheIfValid { MBTilesTileCaches.shared.insertBackstop(image, for: key) }
        }
        guard let data = encodedRasterData(image, format: format) else {
            MBTilesDiagnostics.shared.increment(.corruptTile)
            return .failure(MBTilesError.corruptTile)
        }
        return .found(data, source)
    }

    private func renderedBackstopImage(
        from resolved: ResolvedTile,
        for key: MBTilesOutputKey
    ) -> CGImage? {
        let unadjusted: CGImage
        switch resolved {
        case .direct(let data):
            let sourceKey = MBTilesStoredKey(
                sourceIdentity: identity.sourceIdentity,
                coordinate: key.coordinate
            )
            guard let image = decodedSourceImage(from: data, sourceKey: sourceKey) else {
                MBTilesDiagnostics.shared.increment(.corruptTile)
                return nil
            }
            cacheIfValid { MBTilesTileCaches.shared.insertCompressed(data, for: sourceKey) }
            unadjusted = image
        case .fallback(let sourceData, let sourceKey, let depth):
            guard let image = renderFallbackImage(
                sourceData: sourceData,
                sourceKey: sourceKey,
                requested: key.coordinate,
                depth: depth,
                outputPixels: identity.tileSizePixels
            ) else {
                MBTilesDiagnostics.shared.increment(.corruptTile)
                return nil
            }
            cacheIfValid { MBTilesTileCaches.shared.insertCompressed(sourceData, for: sourceKey) }
            unadjusted = image
        case .missing, .failure:
            return nil
        }

        let settings = identity.visualSettings
        guard !settings.isNeutral else { return unadjusted }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        defer {
            MBTilesDiagnostics.shared.record(
                .raster,
                nanoseconds: DispatchTime.now().uptimeNanoseconds &- startedAt
            )
        }
        return DistrictMapImageAdjuster.renderedCGImage(
            from: CIImage(cgImage: unadjusted),
            settings: settings
        )
    }

    private func decodedSourceImage(
        from sourceData: Data,
        sourceKey: MBTilesStoredKey
    ) -> CGImage? {
        if let cached = MBTilesTileCaches.shared.decodedImage(for: sourceKey) {
            return cached
        }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(sourceData as CFData, options),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, options) else {
            return nil
        }
        cacheIfValid { MBTilesTileCaches.shared.insertDecoded(image, for: sourceKey) }
        return image
    }

    /// Reserves a teardown-visible cache mutation while holding only the brief
    /// session-state lock, then performs eviction/deallocation after releasing it.
    /// This prevents viewport updates on the main thread from waiting behind LRU
    /// work while preserving the invariant that a final teardown purge stays final.
    private func cacheIfValid(_ insertion: () -> Void) {
        stateLock.lock()
        guard !invalidated else {
            stateLock.unlock()
            return
        }
        cacheMutationGroup.enter()
        stateLock.unlock()
        defer { cacheMutationGroup.leave() }
        insertion()
    }

    private func encodedRasterData(
        _ renderedImage: CGImage,
        format: MBTilesRasterFormat
    ) -> Data? {
        let output = NSMutableData()
        let type: CFString = format == .png ? "public.png" as CFString : "public.jpeg" as CFString
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        let options: CFDictionary? = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
            : nil
        CGImageDestinationAddImage(destination, renderedImage, options)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private func renderFallback(sourceData: Data, sourceKey: MBTilesStoredKey, requested: MBTilesTileCoordinate, depth: Int, outputPixels: Int) -> Data? {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        defer {
            MBTilesDiagnostics.shared.record(
                .raster,
                nanoseconds: DispatchTime.now().uptimeNanoseconds &- startedAt
            )
        }
        #if DEBUG
        let signpostID = OSSignpostID(log: Self.log)
        os_signpost(.begin, log: Self.log, name: "AncestorFallback", signpostID: signpostID, "depth=%d", depth)
        defer { os_signpost(.end, log: Self.log, name: "AncestorFallback", signpostID: signpostID) }
        #endif
        guard let format = rasterDescription(sourceData)?.format,
              let image = renderFallbackImage(
                sourceData: sourceData,
                sourceKey: sourceKey,
                requested: requested,
                depth: depth,
                outputPixels: outputPixels
              ) else { return nil }

        let output = NSMutableData()
        let type: CFString = format == .png ? "public.png" as CFString : "public.jpeg" as CFString
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        let options: CFDictionary? = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary : nil
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private func renderFallbackImage(
        sourceData: Data,
        sourceKey: MBTilesStoredKey,
        requested: MBTilesTileCoordinate,
        depth: Int,
        outputPixels: Int
    ) -> CGImage? {
        guard depth > 0, depth < 31, outputPixels > 0,
              let sourceImage = decodedSourceImage(from: sourceData, sourceKey: sourceKey) else {
            return nil
        }

        let scale = 1 << depth
        guard scale <= sourceImage.width, scale <= sourceImage.height else { return nil }
        let descendantMask = scale - 1
        let childX = requested.x & descendantMask
        let childY = requested.y & descendantMask
        let cropWidth = sourceImage.width / scale
        let cropHeight = sourceImage.height / scale
        guard cropWidth > 0, cropHeight > 0 else { return nil }

        let cropRect = CGRect(
            x: childX * cropWidth,
            y: childY * cropHeight,
            width: cropWidth,
            height: cropHeight
        )
        guard let cropped = sourceImage.cropping(to: cropRect) else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: outputPixels,
            height: outputPixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.setAllowsAntialiasing(false)
        context.setShouldAntialias(false)
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: outputPixels, height: outputPixels))
        return context.makeImage()
    }

    private func rasterDescription(_ data: Data) -> (format: MBTilesRasterFormat, width: Int, height: Int)? {
        guard data.count >= 4 else { return nil }
        let format: MBTilesRasterFormat
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { format = .png }
        else if data.starts(with: [0xFF, 0xD8, 0xFF]) { format = .jpeg }
        else { return nil }

        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (format, width, height)
    }

    private func schedulingPriority(
        for coordinate: MBTilesTileCoordinate,
        preferredZoom: Int?,
        center: CLLocationCoordinate2D?
    ) -> Int {
        let zoomDelta = preferredZoom.map { abs(coordinate.z - $0) } ?? 0
        let zoomPriority = max(0, 100_000 - (zoomDelta * 20_000))
        let rolePriority: Int
        switch identity.role {
        case .district: rolePriority = 3_000
        case .basemap: rolePriority = 2_000
        case .shoreline: rolePriority = 1_000
        }
        guard let center else { return zoomPriority + rolePriority }

        let side = Double(Int64(1) << Int64(coordinate.z))
        let longitude = min(180, max(-180, center.longitude))
        let latitude = min(85.051_128_78, max(-85.051_128_78, center.latitude))
        let centerX = (longitude + 180) / 360 * side
        let latitudeRadians = latitude * .pi / 180
        let centerY = (1 - Darwin.log(tan(latitudeRadians) + (1 / cos(latitudeRadians))) / .pi) / 2 * side
        let directXDistance = abs((Double(coordinate.x) + 0.5) - centerX)
        let wrappedXDistance = min(directXDistance, side - directXDistance)
        let yDistance = abs((Double(coordinate.y) + 0.5) - centerY)
        let distancePenalty = min(10_000, Int((wrappedXDistance + yDistance) * 100))
        return zoomPriority + rolePriority - distancePenalty
    }

    private func finish(key: InFlightKey, data: Data?, error: Error?) {
        stateLock.lock()
        let pending = inFlight.removeValue(forKey: key)
        let deliveredData: Data?
        let deliveredError: Error?
        if invalidated {
            deliveredData = nil
            deliveredError = MBTilesError.providerInvalidated
        } else if suspended
                    || lifecycleEpoch != key.lifecycleEpoch
                    || (key.generation < viewportGeneration
                        && key.generation != retainedViewportGeneration) {
            deliveredData = nil
            deliveredError = MBTilesError.requestSuperseded
        } else {
            deliveredData = data
            deliveredError = error
        }
        stateLock.unlock()
        guard let pending else { return }
        MBTilesDiagnostics.shared.record(
            .request,
            nanoseconds: DispatchTime.now().uptimeNanoseconds &- pending.startedAt
        )
        pending.callbacks.forEach {
            complete($0, data: deliveredData, error: deliveredError)
        }
    }

    private func complete(
        _ callback: Completion,
        data: Data?,
        error: Error?,
        startedAt: UInt64? = nil
    ) {
        if let startedAt {
            MBTilesDiagnostics.shared.record(
                .request,
                nanoseconds: DispatchTime.now().uptimeNanoseconds &- startedAt
            )
        }
        MBTilesDiagnostics.shared.increment(.completion)
        callback(data, error)
    }

    #if DEBUG
    private static let log = OSLog(subsystem: "com.curraghfisheries.SatChart", category: "MBTilesRequest")
    #endif
}

/// A non-replacing native-detail raster underlay for a district or offline basemap.
/// MapKit's tile renderer can
/// temporarily discard the previous zoom while requesting the next one; this overlay
/// keeps the native parent tiles drawable underneath that transition instead of exposing
/// the Apple/standard base map. It activates only after its source package has proved it
/// can return real tile bytes, avoiding speculative work against unrelated districts.
nonisolated final class DistrictMapBackstopOverlay: NSObject, MKOverlay, @unchecked Sendable {
    struct VisibleCoverageReadiness {
        let expectedCount: Int
        let resolvedCount: Int
        let imageCount: Int
        let coversFullVisibleArea: Bool

        init(
            expectedCount: Int,
            resolvedCount: Int,
            imageCount: Int,
            coversFullVisibleArea: Bool = true
        ) {
            self.expectedCount = expectedCount
            self.resolvedCount = resolvedCount
            self.imageCount = imageCount
            self.coversFullVisibleArea = coversFullVisibleArea
        }

        var isReady: Bool {
            coversFullVisibleArea
                && (expectedCount == 0
                    || resolvedCount == expectedCount)
        }
    }

    private struct NativeCoordinatePlan {
        let coordinates: [MBTilesTileCoordinate]
        let isComplete: Bool
    }

    private final class CoverageAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private let expectedCount: Int
        private var remaining: Int
        private var resolvedCount = 0
        private var imageCount = 0

        init(expectedCount: Int) {
            self.expectedCount = expectedCount
            self.remaining = expectedCount
        }

        func record(_ outcome: MBTilesBackstopLoadOutcome) -> VisibleCoverageReadiness? {
            lock.lock()
            switch outcome {
            case .image:
                resolvedCount += 1
                imageCount += 1
            case .missing:
                resolvedCount += 1
            case .transientFailure:
                break
            case .cancelled:
                break
            }
            remaining -= 1
            let result = remaining == 0
                ? VisibleCoverageReadiness(
                    expectedCount: expectedCount,
                    resolvedCount: resolvedCount,
                    imageCount: imageCount
                )
                : nil
            lock.unlock()
            return result
        }
    }

    let slug: String
    let identity: MBTilesOverlayIdentity
    let packageSession: MBTilesPackageSession
    let nativeZoom: Int
    let continuity: RasterMapContinuity
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect

    private let stateLock = NSLock()
    private var active = false
    private static let maximumVisibleNativeCoordinateCount = 512
    private static let readinessRetryQueue = DispatchQueue(
        label: "com.satchart.mbtiles.readiness-retry",
        qos: .utility
    )

    init(
        slug: String,
        identity: MBTilesOverlayIdentity,
        packageSession: MBTilesPackageSession,
        boundingMapRect: MKMapRect? = nil
    ) {
        self.slug = slug
        self.identity = identity
        self.packageSession = packageSession
        self.nativeZoom = min(
            identity.maximumZoom,
            max(identity.minimumZoom, identity.nativeDetailMaximumZoom ?? identity.maximumZoom)
        )
        let resolvedBounds = boundingMapRect.flatMap { rect -> MKMapRect? in
            guard !rect.isNull, !rect.isEmpty else { return nil }
            let clipped = rect.intersection(.world)
            return clipped.isNull || clipped.isEmpty ? nil : clipped
        } ?? .world
        self.boundingMapRect = resolvedBounds
        self.continuity = RasterMapContinuity(
            bounds: resolvedBounds,
            minimumZoom: identity.minimumZoom,
            maximumZoom: min(identity.maximumZoom, identity.nativeDetailMaximumZoom ?? identity.maximumZoom)
        ) { coordinate, completion in
            packageSession.scheduleBackstopOutcome(for: coordinate, completion: completion)
        }
        self.coordinate = MKMapPoint(
            x: resolvedBounds.midX,
            y: resolvedBounds.midY
        ).coordinate
        super.init()
    }

    var isActive: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return active
    }

    /// Native-detail handoff threshold. The retained continuity renderer itself
    /// now draws at every scale using an adaptive, bounded pyramid level.
    var minimumDisplayZoom: Double { Double(nativeZoom) - 0.65 }

    func activate() {
        stateLock.lock()
        active = true
        stateLock.unlock()
    }

    func prefetch(in visibleMapRect: MKMapRect) {
        guard isActive else { return }
        let coordinates = visibleNativeCoordinates(in: visibleMapRect, ring: 1)
        packageSession.scheduleBackstopPrefetch(coordinates: coordinates)
    }

    /// Returns every native parent intersecting the clipped viewport when that set
    /// fits within the hard safety cap. Oversized or malformed rectangles return a
    /// center-biased subset without allowing the planner to enumerate the world.
    func visibleNativeCoordinates(
        in visibleMapRect: MKMapRect,
        ring: Int = 0
    ) -> [MBTilesTileCoordinate] {
        coordinatePlan(in: visibleMapRect, zoom: nativeZoom, ring: ring).coordinates
    }

    /// Complete visible coordinates at an ordinary pyramid zoom. Replacement
    /// handoff uses this below the native-continuity threshold so a predecessor is
    /// not retired after only one of several visible MapKit tiles becomes ready.
    func visibleCoordinates(
        in visibleMapRect: MKMapRect,
        zoom: Int,
        ring: Int = 0
    ) -> [MBTilesTileCoordinate] {
        coordinatePlan(in: visibleMapRect, zoom: zoom, ring: ring).coordinates
    }

    /// Resolves the native parent images for the currently visible footprint. This
    /// readiness latch is used when swapping versions or appearance settings so the
    /// previous known-good district remains installed until the replacement can fill
    /// the viewport rather than retiring after a single successful tile.
    func prepareVisibleCoverage(
        in visibleMapRect: MKMapRect,
        completion: @escaping (_ resolvedCount: Int, _ imageCount: Int) -> Void
    ) {
        prepareVisibleCoverageReadiness(in: visibleMapRect) {
            completion($0.resolvedCount, $0.imageCount)
        }
    }

    func prepareVisibleCoverageReadiness(
        in visibleMapRect: MKMapRect,
        zoom requestedZoom: Int? = nil,
        completion: @escaping (VisibleCoverageReadiness) -> Void
    ) {
        activate()
        let readinessZoom = min(
            identity.maximumZoom,
            max(identity.minimumZoom, requestedZoom ?? nativeZoom)
        )
        let plan = coordinatePlan(
            in: visibleMapRect,
            zoom: readinessZoom,
            ring: 0
        )
        guard plan.isComplete else {
            // A truncated sample must never retire a known-good predecessor.
            completion(VisibleCoverageReadiness(
                expectedCount: plan.coordinates.count,
                resolvedCount: 0,
                imageCount: 0,
                coversFullVisibleArea: false
            ))
            return
        }
        let coordinates = plan.coordinates
        guard !coordinates.isEmpty else {
            completion(VisibleCoverageReadiness(
                expectedCount: 0,
                resolvedCount: 0,
                imageCount: 0
            ))
            return
        }
        guard let lifecycleEpoch = packageSession.activeLifecycleEpoch() else {
            completion(VisibleCoverageReadiness(
                expectedCount: coordinates.count,
                resolvedCount: 0,
                imageCount: 0
            ))
            return
        }

        let accumulator = CoverageAccumulator(expectedCount: coordinates.count)
        for coordinate in coordinates {
            loadForVisibleReadiness(
                coordinate: coordinate,
                retry: 0,
                lifecycleEpoch: lifecycleEpoch
            ) { outcome in
                if let result = accumulator.record(outcome) { completion(result) }
            }
        }
    }

    private func coordinatePlan(
        in visibleMapRect: MKMapRect,
        zoom: Int,
        ring: Int
    ) -> NativeCoordinatePlan {
        let clipped = visibleMapRect
            .intersection(boundingMapRect)
            .intersection(.world)
        guard !clipped.isNull, !clipped.isEmpty,
              clipped.origin.x.isFinite, clipped.origin.y.isFinite,
              clipped.size.width.isFinite, clipped.size.height.isFinite,
              (0...30).contains(zoom) else {
            return NativeCoordinatePlan(coordinates: [], isComplete: true)
        }

        let side = Int64(1) << Int64(zoom)
        let tileMapPoints = MKMapSize.world.width / Double(side)
        let expandedRing = Int64(min(
            max(0, ring),
            Self.maximumVisibleNativeCoordinateCount
        ))
        let rawMinimumX = Int64(floor(clipped.minX / tileMapPoints)) - expandedRing
        let rawMaximumX = Int64(floor(clipped.maxX.nextDown / tileMapPoints)) + expandedRing
        let minimumY = max(
            0,
            Int64(floor(clipped.minY / tileMapPoints)) - expandedRing
        )
        let maximumY = min(
            side - 1,
            Int64(floor(clipped.maxY.nextDown / tileMapPoints)) + expandedRing
        )
        guard rawMaximumX >= rawMinimumX, maximumY >= minimumY else {
            return NativeCoordinatePlan(coordinates: [], isComplete: true)
        }

        let rawWidth = rawMaximumX - rawMinimumX + 1
        let rawHeight = maximumY - minimumY + 1
        let product = rawWidth.multipliedReportingOverflow(by: rawHeight)
        let maximumCount = Self.maximumVisibleNativeCoordinateCount
        let isComplete = !product.overflow && product.partialValue <= Int64(maximumCount)

        let candidates: [MBTilesTileCoordinate]
        if isComplete {
            candidates = MBTilesViewportTilePlanner.coordinates(
                in: clipped,
                zoom: zoom,
                ring: Int(expandedRing),
                maximumCount: maximumCount
            )
        } else {
            candidates = boundedCenterCoordinates(
                clipped: clipped,
                rawMinimumX: rawMinimumX,
                rawMaximumX: rawMaximumX,
                minimumY: minimumY,
                maximumY: maximumY,
                side: side,
                zoom: zoom,
                maximumCount: maximumCount
            )
        }
        let inCoverage = candidates.filter {
            MBTilesViewportTilePlanner.mapRect(for: $0).intersects(boundingMapRect)
        }
        return NativeCoordinatePlan(coordinates: inCoverage, isComplete: isComplete)
    }

    /// Selects at most `maximumCount` coordinates without iterating a pathological
    /// viewport-sized range. The resulting window is centered and then sorted using
    /// the same distance rule as the regular planner.
    private func boundedCenterCoordinates(
        clipped: MKMapRect,
        rawMinimumX: Int64,
        rawMaximumX: Int64,
        minimumY: Int64,
        maximumY: Int64,
        side: Int64,
        zoom: Int,
        maximumCount: Int
    ) -> [MBTilesTileCoordinate] {
        let rawWidth = rawMaximumX - rawMinimumX + 1
        let rawHeight = maximumY - minimumY + 1
        let countLimit = Int64(maximumCount)
        let initialWidth = max(1, Int64(Double(maximumCount).squareRoot().rounded(.up)))
        var windowWidth = min(rawWidth, initialWidth)
        var windowHeight = min(rawHeight, max(1, countLimit / windowWidth))
        windowWidth = min(rawWidth, max(1, countLimit / windowHeight))
        windowHeight = min(rawHeight, max(1, countLimit / windowWidth))

        let tileMapPoints = MKMapSize.world.width / Double(side)
        let rawCenterX = min(
            rawMaximumX,
            max(rawMinimumX, Int64(floor(clipped.midX / tileMapPoints)))
        )
        let centerYIndex = min(
            maximumY,
            max(minimumY, Int64(floor(clipped.midY / tileMapPoints)))
        )
        func centeredStart(center: Int64, count: Int64, minimum: Int64, maximum: Int64) -> Int64 {
            min(maximum - count + 1, max(minimum, center - count / 2))
        }
        let startX = centeredStart(
            center: rawCenterX,
            count: windowWidth,
            minimum: rawMinimumX,
            maximum: rawMaximumX
        )
        let startY = centeredStart(
            center: centerYIndex,
            count: windowHeight,
            minimum: minimumY,
            maximum: maximumY
        )

        var unique: Set<MBTilesTileCoordinate> = []
        unique.reserveCapacity(maximumCount)
        for rawY in startY..<(startY + windowHeight) {
            for rawX in startX..<(startX + windowWidth) {
                if let coordinate = MBTilesTileCoordinate(
                    z: zoom,
                    x: Int(rawX),
                    y: Int(rawY)
                ) {
                    unique.insert(coordinate)
                }
            }
        }

        let unwrappedCenterX = clipped.midX / tileMapPoints
        let centerX = unwrappedCenterX
            - floor(unwrappedCenterX / Double(side)) * Double(side)
        let centerY = clipped.midY / tileMapPoints
        return unique.sorted { lhs, rhs in
            let lhsDirectX = abs((Double(lhs.x) + 0.5) - centerX)
            let rhsDirectX = abs((Double(rhs.x) + 0.5) - centerX)
            let lhsX = min(lhsDirectX, Double(side) - lhsDirectX)
            let rhsX = min(rhsDirectX, Double(side) - rhsDirectX)
            let lhsDistance = lhsX + abs((Double(lhs.y) + 0.5) - centerY)
            let rhsDistance = rhsX + abs((Double(rhs.y) + 0.5) - centerY)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            return lhs.x < rhs.x
        }.prefix(maximumCount).map { $0 }
    }

    private func loadForVisibleReadiness(
        coordinate: MBTilesTileCoordinate,
        retry: Int,
        lifecycleEpoch: UInt64,
        completion: @escaping (MBTilesBackstopLoadOutcome) -> Void
    ) {
        packageSession.scheduleBackstopOutcome(
            for: coordinate,
            isSpeculative: true,
            lifecycleEpoch: lifecycleEpoch
        ) { [weak self] outcome in
            if case .transientFailure = outcome,
               let delay = MBTilesRetryPolicy.delay(forRetry: retry) {
                guard let self else {
                    completion(.transientFailure)
                    return
                }
                Self.readinessRetryQueue.asyncAfter(deadline: .now() + delay) {
                    [weak self] in
                    guard let self else {
                        completion(.transientFailure)
                        return
                    }
                    self.loadForVisibleReadiness(
                        coordinate: coordinate,
                        retry: retry + 1,
                        lifecycleEpoch: lifecycleEpoch,
                        completion: completion
                    )
                }
            } else {
                completion(outcome)
            }
        }
    }
}

/// Retains a coarse overview and complete viewport images at every display zoom.
/// This is the sole painter for district/shoreline/Bristol Bay sources; their
/// MKTileOverlay remains attached only as a package and lifecycle anchor.
nonisolated final class DistrictMapBackstopRenderer: RasterContinuityRenderer, @unchecked Sendable {
    private let backstop: DistrictMapBackstopOverlay

    init(overlay: DistrictMapBackstopOverlay) {
        backstop = overlay
        super.init(overlay: overlay, continuity: overlay.continuity)
    }

    override func canDraw(_ mapRect: MKMapRect, zoomScale: MKZoomScale) -> Bool {
        backstop.isActive && super.canDraw(mapRect, zoomScale: zoomScale)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard backstop.isActive else { return }
        super.draw(mapRect, zoomScale: zoomScale, in: context)
    }
}

nonisolated fileprivate final class MBTilesPackageFileReadLeaseState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// A cooperative lease for direct package readers such as thumbnail rendering.
/// Holders should release it with `defer` and check `isCancelled` between database
/// and raster stages so package deletion can complete promptly.
nonisolated final class MBTilesPackageFileReadLease: @unchecked Sendable {
    let fileURL: URL
    private let state: MBTilesPackageFileReadLeaseState
    private let releaseLock = NSLock()
    private var released = false
    private let releaseAction: () -> Void

    fileprivate init(
        fileURL: URL,
        state: MBTilesPackageFileReadLeaseState,
        releaseAction: @escaping () -> Void
    ) {
        self.fileURL = fileURL
        self.state = state
        self.releaseAction = releaseAction
    }

    var isCancelled: Bool { state.isCancelled }

    func release() {
        releaseLock.lock()
        guard !released else {
            releaseLock.unlock()
            return
        }
        released = true
        releaseLock.unlock()
        releaseAction()
    }

    deinit { release() }
}

nonisolated final class MBTilesPackageSessionRegistry {
    static let shared = MBTilesPackageSessionRegistry()
    private static let retainedSessionLimit = 8
    private let lock = NSLock()
    private var sessions: [MBTilesOverlayIdentity: MBTilesPackageSession] = [:]
    private var leaseCounts: [MBTilesOverlayIdentity: Int] = [:]
    private var recency: [MBTilesOverlayIdentity] = []
    private let fileReadLeaseCondition = NSCondition()
    private var fileReadLeases: [String: [UUID: MBTilesPackageFileReadLeaseState]] = [:]
    private var packageInvalidationCounts: [String: Int] = [:]

    /// Acquires a registry-managed lease before opening an MBTiles file directly.
    /// Returns nil while the same package is being invalidated. Recommended use:
    /// `guard let lease = registry.acquirePackageFileReadLease(at: url) else { ... }`
    /// followed immediately by `defer { lease.release() }`.
    func acquirePackageFileReadLease(at url: URL) -> MBTilesPackageFileReadLease? {
        let canonicalURL = url.standardizedFileURL
        let path = canonicalURL.path
        let leaseID = UUID()
        let state = MBTilesPackageFileReadLeaseState()

        fileReadLeaseCondition.lock()
        guard packageInvalidationCounts[path, default: 0] == 0 else {
            fileReadLeaseCondition.unlock()
            return nil
        }
        fileReadLeases[path, default: [:]][leaseID] = state
        fileReadLeaseCondition.unlock()

        return MBTilesPackageFileReadLease(
            fileURL: canonicalURL,
            state: state,
            releaseAction: { [weak self] in
                self?.releasePackageFileReadLease(path: path, leaseID: leaseID)
            }
        )
    }

    func session(for identity: MBTilesOverlayIdentity, immutableFile: Bool) -> MBTilesPackageSession {
        lock.lock()
        if let existing = sessions[identity] {
            leaseCounts[identity, default: 0] += 1
            touch(identity)
            existing.resume()
            MBTilesTileCaches.shared.setActive(identity, isActive: true)
            lock.unlock()
            return existing
        }
        let session = MBTilesPackageSession(identity: identity, immutableFile: immutableFile)
        sessions[identity] = session
        leaseCounts[identity] = 1
        touch(identity)
        MBTilesTileCaches.shared.setActive(identity, isActive: true)
        var evicted = evictSupersededAppearancesLocked(for: identity.sourceIdentity)
        evicted.append(contentsOf: evictInactiveSessionsIfNeededLocked())
        lock.unlock()
        evicted.forEach { $0.invalidate(purgeCaches: true) }
        return session
    }

    func retire(identity: MBTilesOverlayIdentity) {
        var remainsActive = false
        var sessionToSuspend: MBTilesPackageSession?
        lock.lock()
        guard sessions[identity] != nil else {
            lock.unlock()
            return
        }
        if let count = leaseCounts[identity], count > 0 {
            leaseCounts[identity] = count - 1
        }
        remainsActive = (leaseCounts[identity] ?? 0) > 0
        if !remainsActive { sessionToSuspend = sessions[identity] }
        touch(identity)
        MBTilesTileCaches.shared.setActive(identity, isActive: remainsActive)
        var evicted = evictSupersededAppearancesLocked(for: identity.sourceIdentity)
        evicted.append(contentsOf: evictInactiveSessionsIfNeededLocked())
        // Serialize suspension with session(for:)'s resume under the registry lock.
        // Otherwise a reacquire can resume between this unlock and a late suspend,
        // leaving a currently leased session unable to serve tiles.
        sessionToSuspend?.suspendQueuedWork()
        lock.unlock()
        evicted.forEach { $0.invalidate(purgeCaches: true) }
    }

    func invalidatePackage(at url: URL) {
        let path = url.standardizedFileURL.path
        beginPackageInvalidation(path: path)
        defer { endPackageInvalidation(path: path) }
        lock.lock()
        let matching = sessions.filter { $0.key.canonicalPath == path }
        let sourceIdentities = Set(matching.keys.map(\.sourceIdentity))
        matching.keys.forEach { sessions.removeValue(forKey: $0) }
        matching.keys.forEach { leaseCounts.removeValue(forKey: $0) }
        recency.removeAll { $0.canonicalPath == path }
        matching.keys.forEach { MBTilesTileCaches.shared.setActive($0, isActive: false) }
        lock.unlock()
        matching.values.forEach {
            $0.invalidate(purgeCaches: true, waitForTeardown: true)
        }
        sourceIdentities.forEach { MBTilesTileCaches.shared.invalidate(sourceIdentity: $0) }
    }

    private func releasePackageFileReadLease(path: String, leaseID: UUID) {
        fileReadLeaseCondition.lock()
        if var leases = fileReadLeases[path] {
            leases.removeValue(forKey: leaseID)
            if leases.isEmpty { fileReadLeases.removeValue(forKey: path) }
            else { fileReadLeases[path] = leases }
        }
        fileReadLeaseCondition.broadcast()
        fileReadLeaseCondition.unlock()
    }

    private func beginPackageInvalidation(path: String) {
        fileReadLeaseCondition.lock()
        packageInvalidationCounts[path, default: 0] += 1
        fileReadLeases[path]?.values.forEach { $0.cancel() }
        while !(fileReadLeases[path]?.isEmpty ?? true) {
            fileReadLeaseCondition.wait()
        }
        fileReadLeaseCondition.unlock()
    }

    private func endPackageInvalidation(path: String) {
        fileReadLeaseCondition.lock()
        let remaining = max(0, packageInvalidationCounts[path, default: 0] - 1)
        if remaining == 0 { packageInvalidationCounts.removeValue(forKey: path) }
        else { packageInvalidationCounts[path] = remaining }
        fileReadLeaseCondition.broadcast()
        fileReadLeaseCondition.unlock()
    }

    private func touch(_ identity: MBTilesOverlayIdentity) {
        recency.removeAll { $0 == identity }
        recency.append(identity)
    }

    private func evictInactiveSessionsIfNeededLocked() -> [MBTilesPackageSession] {
        var evicted: [MBTilesPackageSession] = []
        while sessions.count > Self.retainedSessionLimit,
              let oldestInactive = recency.first(where: { (leaseCounts[$0] ?? 0) == 0 }) {
            recency.removeAll { $0 == oldestInactive }
            leaseCounts.removeValue(forKey: oldestInactive)
            if let session = sessions.removeValue(forKey: oldestInactive) {
                evicted.append(session)
            }
        }
        return evicted
    }

    private func evictSupersededAppearancesLocked(
        for sourceIdentity: MBTilesSourceIdentity
    ) -> [MBTilesPackageSession] {
        let activeAppearanceExists = sessions.keys.contains {
            $0.sourceIdentity == sourceIdentity && (leaseCounts[$0] ?? 0) > 0
        }
        guard activeAppearanceExists else { return [] }
        let superseded = sessions.keys.filter {
            $0.sourceIdentity == sourceIdentity && (leaseCounts[$0] ?? 0) == 0
        }
        var evicted: [MBTilesPackageSession] = []
        for identity in superseded {
            recency.removeAll { $0 == identity }
            leaseCounts.removeValue(forKey: identity)
            if let session = sessions.removeValue(forKey: identity) {
                evicted.append(session)
            }
        }
        return evicted
    }
}

/// MKTileOverlay adapter. It owns no database connection or cache; those belong to a
/// versioned package session which can be reused if SwiftUI genuinely recreates MKMapView.
