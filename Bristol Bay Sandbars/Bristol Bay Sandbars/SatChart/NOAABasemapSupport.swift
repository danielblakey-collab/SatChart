import Foundation
import MapKit
import CoreLocation
import CryptoKit
import ImageIO
import UIKit

nonisolated enum BasemapChoice: String, CaseIterable, Identifiable {
    case districtsOffline
    case appleSatellite
    case districtsOnline = "bristolBaySatelliteOnline" // Preserve the saved basemap preference.
    case bristolBaySatelliteOffline
    case topoOnline
    case noaaOffline
    case noaaOnline

    var id: String { rawValue }

    var label: String {
        switch self {
        case .districtsOffline: return "Districts Offline"
        case .appleSatellite: return "Satellite"
        case .districtsOnline: return "Districts Online"
        case .bristolBaySatelliteOffline: return "B-Bay Sat Offline"
        case .topoOnline: return "USGS Topo"
        case .noaaOffline: return "NOAA Charts Offline"
        case .noaaOnline: return "NOAA Charts Online"
        }
    }

    var symbolName: String {
        switch self {
        case .districtsOffline:
            return "map.fill"
        case .appleSatellite:
            return "globe.americas.fill"
        case .districtsOnline:
            return "photo.fill"
        case .bristolBaySatelliteOffline:
            return "photo.stack.fill"
        case .topoOnline:
            return "mountain.2.fill"
        case .noaaOffline:
            return "shippingbox.fill"
        case .noaaOnline:
            return "antenna.radiowaves.left.and.right"
        }
    }
}

nonisolated enum BasemapDefaultPolicy {
    static func shouldPreferBristolBaySatelliteOnline(rawValue: String, didMigrate: Bool) -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return !didMigrate && (trimmed.isEmpty || trimmed == BasemapChoice.appleSatellite.rawValue)
    }

    static func choice(rawValue: String, didMigrate: Bool) -> BasemapChoice {
        if shouldPreferBristolBaySatelliteOnline(rawValue: rawValue, didMigrate: didMigrate) {
            return .districtsOnline
        }
        return BasemapChoice(rawValue: rawValue) ?? .districtsOnline
    }
}

nonisolated enum BasemapLayerPolicy {
    private static let shorelineOverlaySlugs: Set<String> = [
        "egegik_to_ugashik_shoreline",
        "naknek_to_egegik_shoreline",
        "naknek_to_nushagak_shoreline"
    ]
    private static let districtMapBaseSlugs: [String] = [
        "togiak",
        "nushagak",
        "naknek_kvichak",
        "egegik",
        "ugashik"
    ]

    static func usesBristolBaySatelliteOnlineBase(_ choice: BasemapChoice) -> Bool {
        choice == .districtsOnline
    }

    nonisolated enum DistrictBristolSource: Equatable {
        case downloadedOffline
        case onlineFallback
    }

    static func districtBristolSource(hasDownloadedOfflinePackage: Bool) -> DistrictBristolSource {
        hasDownloadedOfflinePackage ? .downloadedOffline : .onlineFallback
    }

    static func usesAppleSatelliteBase(_ choice: BasemapChoice) -> Bool {
        choice == .appleSatellite || choice == .districtsOffline
    }

    static func isShorelineOverlay(slug: String) -> Bool {
        shorelineOverlaySlugs.contains(slug)
    }

    static func isDistrictOrShorelineOverlay(slug: String) -> Bool {
        isDistrictMapOverlay(slug: slug) || isShorelineOverlay(slug: slug)
    }

    static func tileAlpha(
        for slug: String,
        basemapChoice: BasemapChoice,
        selectedDistrictMapSlug: String?
    ) -> Double {
        guard basemapChoice == .districtsOffline else {
            return isDistrictOrShorelineOverlay(slug: slug) ? 0.0 : 1.0
        }

        if isShorelineOverlay(slug: slug) {
            return 1.0
        }

        guard isDistrictMapOverlay(slug: slug) else {
            return 1.0
        }

        return selectedDistrictMapSlug == slug ? 1.0 : 0.0
    }

    /// Mirrors `DistrictID.mapVersion(forPackSlug:)` without crossing the app's
    /// default MainActor boundary from this immutable, thread-safe policy.
    private static func isDistrictMapOverlay(slug: String) -> Bool {
        for districtSlug in districtMapBaseSlugs {
            if slug == districtSlug { return true }
            let versionPrefix = "\(districtSlug)_v"
            guard slug.hasPrefix(versionPrefix) else { continue }
            let suffix = slug.dropFirst(versionPrefix.count)
            if let version = Int(suffix), (1...12).contains(version) {
                return true
            }
        }
        return false
    }
}

final class BristolBaySatelliteTileOverlay: MKTileOverlay {
    let continuity: RasterMapContinuity
    static let nativeMaximumZ = 15

    /// Geographic footprint published in the Bristol Bay offline source metadata.
    /// The online pyramid is the matching source, so advertising this footprint keeps
    /// MapKit from issuing guaranteed 404 requests elsewhere in the world.
    static let coverageMapRect = MBTilesGeographicCoverage.mapRect(from: [
        -158.940_315_428_268_4,
        57.253_396_320_662_67,
        -156.727_710_805_028_3,
        59.283_382_128_638_735
    ]) ?? .world

    private static let baseURL = URL(string: "https://pub-832b588ef9ec4a588045736b6ce409b9.r2.dev")!
    private static let tilesPrefix = "tiles"
    private static let tileStore = BristolBaySatelliteTileStore.shared

    override var boundingMapRect: MKMapRect { Self.coverageMapRect }
    override var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: Self.coverageMapRect.midX, y: Self.coverageMapRect.midY).coordinate
    }

    init(
        replacesMapContent: Bool = false,
        displayMaximumZ: Int = BristolBaySatelliteTileOverlay.nativeMaximumZ
    ) {
        let baseURL = Self.baseURL.appendingPathComponent(Self.tilesPrefix)
        let store = Self.tileStore
        continuity = RasterMapContinuity(bounds: Self.coverageMapRect, minimumZoom: 0,
                                         maximumZoom: Self.nativeMaximumZ) { tile, completion in
            store.loadTile(url: baseURL.appendingPathComponent("\(tile.z)/\(tile.x)/\(tile.y).png"),
                           cacheKey: "z\(tile.z)/x\(tile.x)/y\(tile.y)") { data, error in
                RasterMapContinuity.decode(data, error: error, completion: completion)
            }
        }
        super.init(urlTemplate: nil)
        canReplaceMapContent = replacesMapContent
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0
        maximumZ = max(Self.nativeMaximumZ, displayMaximumZ)
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        Self.baseURL
            .appendingPathComponent(Self.tilesPrefix)
            .appendingPathComponent(String(path.z))
            .appendingPathComponent(String(path.x))
            .appendingPathComponent("\(path.y).png")
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        guard path.z > Self.nativeMaximumZ else {
            loadSourceTile(at: path, result: result)
            return
        }

        let delta = path.z - Self.nativeMaximumZ
        guard delta > 0, delta <= 8, path.x >= 0, path.y >= 0 else {
            result(nil, nil)
            return
        }

        let childScale = 1 << delta
        let sourcePath = MKTileOverlayPath(
            x: path.x >> delta,
            y: path.y >> delta,
            z: Self.nativeMaximumZ,
            contentScaleFactor: path.contentScaleFactor
        )
        let childX = path.x & (childScale - 1)
        let childY = path.y & (childScale - 1)
        let sourceURL = url(forTilePath: sourcePath)
        let sourceCacheKey = "z\(sourcePath.z)/x\(sourcePath.x)/y\(sourcePath.y)"
        let outputCacheKey = "overzoom/z\(path.z)/x\(path.x)/y\(path.y)"
        Self.tileStore.loadOverzoomedTile(
            sourceURL: sourceURL,
            sourceCacheKey: sourceCacheKey,
            outputCacheKey: outputCacheKey,
            childX: childX,
            childY: childY,
            childScale: childScale,
            result: result
        )
    }

    private func loadSourceTile(
        at path: MKTileOverlayPath,
        result: @escaping (Data?, Error?) -> Void
    ) {
        let url = url(forTilePath: path)
        let cacheKey = "z\(path.z)/x\(path.x)/y\(path.y)"
        Self.tileStore.loadTile(url: url, cacheKey: cacheKey, result: result)
    }

    /// Performs the smallest reusable validation needed by both cold disk reads and
    /// URLSession responses. `kCGImageSourceShouldCacheImmediately` forces ImageIO to
    /// decode the complete payload here, on the store's read/network worker, before
    /// bytes can enter either cache or reach MapKit.
    nonisolated static func isValidNativeTilePayload(
        _ data: Data,
        expectedPixelSize: Int = 256
    ) -> Bool {
        guard expectedPixelSize > 0,
              data.count >= 8,
              data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
                || (data.count >= 3 && data[0] == 0xff && data[1] == 0xd8 && data[2] == 0xff) else {
            return false
        }

        let metadataOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, metadataOptions),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                metadataOptions
              ) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == expectedPixelSize,
              height == expectedPixelSize else {
            return false
        }

        let decodeOptions = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, decodeOptions) else {
            return false
        }
        return decoded.width == expectedPixelSize && decoded.height == expectedPixelSize
    }
}

nonisolated enum BristolBaySatelliteTileStoreError: LocalizedError {
    case notFound
    case saturated
    case invalidImageResponse

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "No tile is published at this coordinate."
        case .saturated:
            return "The Bristol Bay satellite tile queue is temporarily full."
        case .invalidImageResponse:
            return "The Bristol Bay satellite server did not return a valid raster tile."
        }
    }
}

/// A deliberately bounded pipeline for the online Bristol Bay pyramid. Source
/// bytes and derived overzoom children have independent coalescing tables so a
/// burst of repeated MapKit requests performs one disk/network read and one crop.
nonisolated final class BristolBaySatelliteTileStore: @unchecked Sendable {
    typealias Completion = (Data?, Error?) -> Void
    private static let maximumTilePayloadBytes = 4 * 1_024 * 1_024

    private struct NetworkRequest {
        let url: URL
        let cacheKey: String
    }

    private struct DiskEntry {
        let url: URL
        let byteCount: Int
        var lastAccess: Date
    }

    static let shared = BristolBaySatelliteTileStore()

    // All cache access is serialized by stateQueue, so the engine's strict-cost
    // LRU gives this path a real ceiling instead of NSCache's advisory limit.
    private let sourceMemoryCache = CostedLRU<String, Data>(
        costLimit: 4 * 1_024 * 1_024,
        countLimit: 64
    )
    private let derivedMemoryCache = CostedLRU<String, Data>(
        costLimit: 2 * 1_024 * 1_024,
        countLimit: 32
    )
    private let session: URLSession
    private let rootDirectory: URL
    private let stateQueue = DispatchQueue(
        label: "com.satchart.bristol-bay-satellite.state",
        qos: .userInitiated
    )
    private let completionQueue = DispatchQueue(
        label: "com.satchart.bristol-bay-satellite.completions",
        qos: .userInitiated
    )
    private let readOperations: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.satchart.bristol-bay-satellite.read"
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let cropOperations: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.satchart.bristol-bay-satellite.crop"
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let writeQueue = DispatchQueue(
        label: "com.satchart.bristol-bay-satellite.write",
        qos: .utility
    )

    // Accessed only on stateQueue after initialization.
    private var sourceInFlight: [String: [Completion]] = [:]
    private var derivedInFlight: [String: [Completion]] = [:]
    private var pendingNetworkRequests: [NetworkRequest] = []
    private var activeNetworkRequests = 0
    private var maximumNetworkRequests = 2
    private var maximumSourceKeys = 96
    private var maximumDerivedKeys = 96
    private var maximumCallbacksPerKey = 32
    private var observers: [NSObjectProtocol] = []
    private var chartOwners: Set<UUID> = []

    // Accessed only on writeQueue after initialization.
    private var diskEntries: [String: DiskEntry] = [:]
    private var diskByteCount = 0
    private var diskByteLimit = 96 * 1_024 * 1_024
    private var diskCountLimit = 2_048

    private init() {
        let profile = MBTilesResourceProfile.current()
        let configuration = URLSessionConfiguration.ephemeral
        // URLSession provides a second ceiling; the state-queue pump below can
        // lower concurrency dynamically for power and thermal pressure.
        configuration.httpMaximumConnectionsPerHost = profile.onlineSatelliteConnections
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)

        let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        rootDirectory = cachesRoot.appendingPathComponent("BristolBaySatelliteTiles/v1", isDirectory: true)

        applyResourceProfileLocked(profile)
        installObservers()
        let initialDiskLimits = Self.diskLimits(for: profile)
        writeQueue.async { [self] in
            diskByteLimit = initialDiskLimits.bytes
            diskCountLimit = initialDiskLimits.count
            rebuildDiskIndexAndTrim()
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        session.invalidateAndCancel()
    }

    func loadTile(url: URL, cacheKey: String, result: @escaping Completion) {
        // Register before any file I/O. This coalesces both a cold disk lookup and
        // the subsequent URL request, rather than only merging requests at the
        // network stage.
        stateQueue.async { [self] in
            beginSourceLoadLocked(url: url, cacheKey: cacheKey, result: result)
        }
    }

    func loadOverzoomedTile(
        sourceURL: URL,
        sourceCacheKey: String,
        outputCacheKey: String,
        childX: Int,
        childY: Int,
        childScale: Int,
        result: @escaping Completion
    ) {
        stateQueue.async { [self] in
            if let cached = derivedMemoryCache.value(for: outputCacheKey) {
                deliver([result], data: cached, error: nil)
                return
            }

            if var callbacks = derivedInFlight[outputCacheKey] {
                guard callbacks.count < maximumCallbacksPerKey else {
                    deliver([result], data: nil, error: BristolBaySatelliteTileStoreError.saturated)
                    return
                }
                callbacks.append(result)
                derivedInFlight[outputCacheKey] = callbacks
                return
            }

            guard derivedInFlight.count < maximumDerivedKeys else {
                deliver([result], data: nil, error: BristolBaySatelliteTileStoreError.saturated)
                return
            }
            derivedInFlight[outputCacheKey] = [result]

            loadTile(url: sourceURL, cacheKey: sourceCacheKey) { [self] sourceData, sourceError in
                guard let sourceData else {
                    stateQueue.async { [self] in
                        finishDerivedLocked(
                            cacheKey: outputCacheKey,
                            data: nil,
                            error: sourceError ?? BristolBaySatelliteTileStoreError.invalidImageResponse
                        )
                    }
                    return
                }

                cropOperations.addOperation { [self] in
                    let output = autoreleasepool { () -> Data? in
                        guard let format = MBTilesOverlay.rasterTileFormat(for: sourceData) else { return nil }
                        return MBTilesOverlay.overzoomedTileData(
                            from: sourceData,
                            childX: childX,
                            childY: childY,
                            childScale: childScale,
                            format: format
                        )
                    }
                    stateQueue.async { [self] in
                        if let output {
                            derivedMemoryCache.insert(output, for: outputCacheKey, cost: output.count)
                        }
                        finishDerivedLocked(
                            cacheKey: outputCacheKey,
                            data: output,
                            error: output == nil
                                ? BristolBaySatelliteTileStoreError.invalidImageResponse
                                : nil
                        )
                    }
                }
            }
        }
    }

    private func beginSourceLoadLocked(
        url: URL,
        cacheKey: String,
        result: @escaping Completion
    ) {
        if let cached = sourceMemoryCache.value(for: cacheKey) {
            deliver([result], data: cached, error: nil)
            return
        }

        if var callbacks = sourceInFlight[cacheKey] {
            guard callbacks.count < maximumCallbacksPerKey else {
                deliver([result], data: nil, error: BristolBaySatelliteTileStoreError.saturated)
                return
            }
            callbacks.append(result)
            sourceInFlight[cacheKey] = callbacks
            return
        }

        guard sourceInFlight.count < maximumSourceKeys else {
            deliver([result], data: nil, error: BristolBaySatelliteTileStoreError.saturated)
            return
        }
        sourceInFlight[cacheKey] = [result]

        readOperations.addOperation { [self] in
            let diskData = loadFromDisk(cacheKey: cacheKey)
            stateQueue.async { [self] in
                guard sourceInFlight[cacheKey] != nil else { return }
                if let diskData {
                    sourceMemoryCache.insert(diskData, for: cacheKey, cost: diskData.count)
                    finishSourceLocked(cacheKey: cacheKey, data: diskData, error: nil)
                } else {
                    pendingNetworkRequests.append(NetworkRequest(url: url, cacheKey: cacheKey))
                    pumpNetworkLocked()
                }
            }
        }
    }

    private func pumpNetworkLocked() {
        while activeNetworkRequests < maximumNetworkRequests,
              !pendingNetworkRequests.isEmpty {
            // Prefer the newest viewport demand when an earlier pan left a queue
            // behind. The queue remains bounded, and every older request still
            // retains its exactly-once completion while it waits.
            let pending = pendingNetworkRequests.removeLast()
            activeNetworkRequests += 1

            var request = URLRequest(url: pending.url)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("image/png,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("SatChart-BristolBaySatellite/1.0", forHTTPHeaderField: "User-Agent")

            session.dataTask(with: request) { [self] data, response, error in
                let validated = validatedImageData(data, response: response)
                stateQueue.async { [self] in
                    activeNetworkRequests = max(0, activeNetworkRequests - 1)
                    if let validated {
                        sourceMemoryCache.insert(validated, for: pending.cacheKey, cost: validated.count)
                        storeOnDisk(validated, cacheKey: pending.cacheKey)
                        finishSourceLocked(cacheKey: pending.cacheKey, data: validated, error: nil)
                    } else {
                        finishSourceLocked(
                            cacheKey: pending.cacheKey,
                            data: nil,
                            error: error ?? ((response as? HTTPURLResponse).map { [404, 410].contains($0.statusCode) } == true
                                ? BristolBaySatelliteTileStoreError.notFound
                                : BristolBaySatelliteTileStoreError.invalidImageResponse)
                        )
                    }
                    pumpNetworkLocked()
                }
            }.resume()
        }
    }

    private func finishSourceLocked(cacheKey: String, data: Data?, error: Error?) {
        let callbacks = sourceInFlight.removeValue(forKey: cacheKey) ?? []
        deliver(callbacks, data: data, error: error)
    }

    private func finishDerivedLocked(cacheKey: String, data: Data?, error: Error?) {
        let callbacks = derivedInFlight.removeValue(forKey: cacheKey) ?? []
        deliver(callbacks, data: data, error: error)
    }

    private func deliver(_ callbacks: [Completion], data: Data?, error: Error?) {
        guard !callbacks.isEmpty else { return }
        completionQueue.async {
            for callback in callbacks {
                callback(data, error)
            }
        }
    }

    private func loadFromDisk(cacheKey: String) -> Data? {
        assert(!Thread.isMainThread, "Bristol Bay satellite file I/O must remain off-main")
        let url = cacheFileURL(for: cacheKey)
        guard let diskData = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        guard validatedImageData(diskData, response: nil) != nil else {
            removeDiskEntry(at: url)
            return nil
        }
        recordDiskAccess(at: url, byteCount: diskData.count)
        return diskData
    }

    private func storeOnDisk(_ data: Data, cacheKey: String) {
        let url = cacheFileURL(for: cacheKey)
        writeQueue.async { [self] in
            do {
                try FileManager.default.createDirectory(
                    at: rootDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                try data.write(to: url, options: .atomic)
                let key = url.path
                if let previous = diskEntries[key] {
                    diskByteCount -= previous.byteCount
                }
                diskEntries[key] = DiskEntry(url: url, byteCount: data.count, lastAccess: Date())
                diskByteCount += data.count
                trimDiskCacheIfNeeded()
            } catch {
                // A cache write failure must never fail an already-loaded map tile.
            }
        }
    }

    private func recordDiskAccess(at url: URL, byteCount: Int) {
        writeQueue.async { [self] in
            let key = url.path
            if var entry = diskEntries[key] {
                entry.lastAccess = Date()
                diskEntries[key] = entry
            } else if FileManager.default.fileExists(atPath: key) {
                diskEntries[key] = DiskEntry(url: url, byteCount: byteCount, lastAccess: Date())
                diskByteCount += byteCount
                trimDiskCacheIfNeeded()
            }
        }
    }

    private func removeDiskEntry(at url: URL) {
        writeQueue.async { [self] in
            let key = url.path
            if let entry = diskEntries.removeValue(forKey: key) {
                diskByteCount = max(0, diskByteCount - entry.byteCount)
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func rebuildDiskIndexAndTrim() {
        try? FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []

        diskEntries.removeAll(keepingCapacity: true)
        diskByteCount = 0
        for url in urls where url.pathExtension == "tile" {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let byteCount = values.fileSize,
                  byteCount > 0 else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let entry = DiskEntry(
                url: url,
                byteCount: byteCount,
                lastAccess: values.contentModificationDate ?? .distantPast
            )
            diskEntries[url.path] = entry
            diskByteCount += byteCount
        }
        trimDiskCacheIfNeeded()
    }

    private func trimDiskCacheIfNeeded() {
        guard diskByteCount > diskByteLimit || diskEntries.count > diskCountLimit else { return }
        let oldestFirst = diskEntries.values.sorted { lhs, rhs in
            if lhs.lastAccess != rhs.lastAccess { return lhs.lastAccess < rhs.lastAccess }
            return lhs.url.path < rhs.url.path
        }
        for entry in oldestFirst {
            guard diskByteCount > diskByteLimit || diskEntries.count > diskCountLimit else { break }
            try? FileManager.default.removeItem(at: entry.url)
            diskEntries.removeValue(forKey: entry.url.path)
            diskByteCount = max(0, diskByteCount - entry.byteCount)
        }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleMemoryWarning()
        })
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleBackgrounding()
        })
        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.refreshResourceProfile()
        })
        observers.append(center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.refreshResourceProfile()
        })
    }

    private func handleMemoryWarning() {
        stateQueue.async { [self] in
            sourceMemoryCache.removeAll()
            derivedMemoryCache.removeAll()
            applyResourceProfileLocked(MBTilesResourceProfile.current())
            pumpNetworkLocked()
        }
    }

    private func handleBackgrounding() {
        stateQueue.async { [self] in
            derivedMemoryCache.removeAll()
            sourceMemoryCache.removeAll()
        }
        writeQueue.async { [self] in trimDiskCacheIfNeeded() }
    }

    private func refreshResourceProfile() {
        let profile = MBTilesResourceProfile.current()
        stateQueue.async { [self] in
            applyResourceProfileLocked(profile)
            pumpNetworkLocked()
        }
        let limits = Self.diskLimits(for: profile)
        writeQueue.async { [self] in
            diskByteLimit = limits.bytes
            diskCountLimit = limits.count
            trimDiskCacheIfNeeded()
        }
    }

    /// USGS/NOAA use the existing online allowance rather than adding their
    /// resident frames on top of a full, inactive satellite cache.
    func setChartModeActive(_ active: Bool, owner: UUID) {
        stateQueue.async { [self] in
            guard chartOwners.contains(owner) != active else { return }
            if active { chartOwners.insert(owner) } else { chartOwners.remove(owner) }
            applyResourceProfileLocked(MBTilesResourceProfile.current())
        }
    }

    private func applyResourceProfileLocked(_ profile: MBTilesResourceProfile) {
        let totalMemory = profile.onlineSatelliteCacheBytes
        let sourceMemory = chartOwners.isEmpty
            ? max(4 * 1_024 * 1_024, (totalMemory * 3) / 4) : 2 * 1_024 * 1_024
        let derivedMemory = chartOwners.isEmpty
            ? max(2 * 1_024 * 1_024, totalMemory - sourceMemory) : 0
        sourceMemoryCache.updateLimits(
            costLimit: sourceMemory,
            countLimit: max(64, sourceMemory / (64 * 1_024))
        )
        derivedMemoryCache.updateLimits(
            costLimit: derivedMemory,
            countLimit: max(32, derivedMemory / (64 * 1_024))
        )

        maximumSourceKeys = max(32, profile.maximumQueuedWork)
        maximumDerivedKeys = max(32, profile.maximumQueuedWork)
        maximumCallbacksPerKey = max(16, min(64, profile.maximumQueuedWork / 2))
        readOperations.maxConcurrentOperationCount = max(
            1,
            min(profile.onlineSatelliteConnections, profile.maximumActiveWork)
        )
        cropOperations.maxConcurrentOperationCount = max(
            1,
            min(profile.onlineSatelliteConnections, profile.maximumActiveWork)
        )
        maximumNetworkRequests = profile.maximumSpeculativeWork == 0
            ? max(1, min(profile.onlineSatelliteConnections, profile.maximumActiveWork))
            : max(1, profile.onlineSatelliteConnections)
    }

    private static func diskLimits(for profile: MBTilesResourceProfile) -> (bytes: Int, count: Int) {
        let bytes = max(
            32 * 1_024 * 1_024,
            min(192 * 1_024 * 1_024, profile.onlineSatelliteCacheBytes * 4)
        )
        let count = max(512, min(4_096, bytes / (48 * 1_024)))
        return (bytes, count)
    }

    private func validatedImageData(_ data: Data?, response: URLResponse?) -> Data? {
        guard let data,
              !data.isEmpty,
              data.count <= Self.maximumTilePayloadBytes else { return nil }

        if let http = response as? HTTPURLResponse {
            guard (200...299).contains(http.statusCode) else { return nil }

            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if contentType.contains("xml") || contentType.contains("html")
                || contentType.contains("text") || contentType.contains("json") {
                return nil
            }
        }

        return BristolBaySatelliteTileOverlay.isValidNativeTilePayload(
            data,
            expectedPixelSize: 256
        ) ? data : nil
    }

    private func cacheFileURL(for cacheKey: String) -> URL {
        let digest = SHA256.hash(data: Data(cacheKey.utf8))
        let fileName = digest.map { String(format: "%02x", $0) }.joined() + ".tile"
        return rootDirectory.appendingPathComponent(fileName)
    }
}

final class NOAAOnlineTileOverlay: OnlineChartOverlay {
    init(replacesMapContent: Bool = false, store: OnlineChartTileStore = .shared) {
        super.init(source: .noaa, store: store)
    }
}

final class USGSTopoOnlineTileOverlay: OnlineChartOverlay {
    static let nativeMaximumZ: Int = 23
    init(replacesMapContent: Bool = false, store: OnlineChartTileStore = .shared) {
        super.init(source: .usgs, store: store)
    }
}

/// One validated locally-downloaded offline basemap package from the manager's
/// active Application Support inventory (or its controlled legacy fallback).
///
/// Naming conventions supported by the discovery code:
/// - noaa.mbtiles / ncds.mbtiles
/// - noaa_bristol_bay.mbtiles / ncds_bristol_bay.mbtiles
/// - noaa-bristol-bay.mbtiles / ncds-bristol-bay.mbtiles
/// - bristol_bay.mbtiles / bristol-bay.mbtiles
struct LocalNOAAChartPackage: Identifiable {
    let url: URL
    let slug: String
    let coverageMapRect: MKMapRect?
    let minZoom: Int?
    let maxZoom: Int?
    let storageScheme: MBTilesStorageScheme
    let tileWidth: Int
    let tileHeight: Int

    var id: String { slug }
}

extension OfflineMapsManager {

    /// Returns all active, validated NOAA/NCDS offline chart packages.
    ///
    /// This intentionally excludes the offline Bristol Bay satellite basemap so the
    /// two offline basemap choices do not alias each other.
    func localNOAAChartPackages() -> [LocalNOAAChartPackage] {
        localOfflineBasemapPackages(
            matching: Self.looksLikeNOAASlug,
            priority: Self.noaaSlugPriority
        )
    }

    /// Returns all locally-downloaded offline Bristol Bay satellite packages.
    func localBristolBaySatellitePackages() -> [LocalNOAAChartPackage] {
        localOfflineBasemapPackages(
            matching: Self.looksLikeBristolBaySatelliteSlug,
            priority: Self.bristolBaySatelliteSlugPriority
        )
    }

    /// Picks the best local NOAA chart package for the map's current visible rect.
    func bestLocalNOAAChartPackage(for visibleMapRect: MKMapRect) -> LocalNOAAChartPackage? {
        bestLocalOfflineBasemapPackage(
            from: localNOAAChartPackages(),
            for: visibleMapRect
        )
    }

    /// Picks the best local Bristol Bay satellite package for the map's current visible rect.
    func bestLocalBristolBaySatellitePackage(for visibleMapRect: MKMapRect) -> LocalNOAAChartPackage? {
        bestLocalOfflineBasemapPackage(
            from: localBristolBaySatellitePackages(),
            for: visibleMapRect
        )
    }

    /// Convenience wrapper if you only want the URL.
    func bestLocalNOAAChartURL(for visibleMapRect: MKMapRect) -> URL? {
        bestLocalNOAAChartPackage(for: visibleMapRect)?.url
    }

    /// Convenience wrapper if you only want the URL.
    func bestLocalBristolBaySatelliteURL(for visibleMapRect: MKMapRect) -> URL? {
        bestLocalBristolBaySatellitePackage(for: visibleMapRect)?.url
    }

    private func localOfflineBasemapPackages(
        matching matchesSlug: @escaping (String) -> Bool,
        priority: @escaping (String) -> Int
    ) -> [LocalNOAAChartPackage] {
        return installedRecordsSnapshot()
            .filter { matchesSlug($0.slug) }
            .sorted {
                let lhsPriority = priority($0.slug)
                let rhsPriority = priority($1.slug)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                return $0.slug.localizedCaseInsensitiveCompare($1.slug) == .orderedAscending
            }
            .map { record in
                LocalNOAAChartPackage(
                    url: record.url,
                    slug: record.slug,
                    coverageMapRect: record.bounds.flatMap(Self.coverageRect(from:)),
                    minZoom: record.minimumZoom,
                    maxZoom: record.maximumZoom,
                    storageScheme: record.storageScheme,
                    tileWidth: record.tileWidth,
                    tileHeight: record.tileHeight
                )
            }
    }

    private func bestLocalOfflineBasemapPackage(
        from packages: [LocalNOAAChartPackage],
        for visibleMapRect: MKMapRect
    ) -> LocalNOAAChartPackage? {
        guard !packages.isEmpty else { return nil }
        guard packages.count > 1 else { return packages[0] }

        let visible = Self.normalizedVisibleRect(visibleMapRect)

        var bestIntersecting: (package: LocalNOAAChartPackage, score: Double)?
        for package in packages {
            guard let coverage = package.coverageMapRect else { continue }
            let score = Self.intersectionArea(coverage, visible)
            guard score > 0 else { continue }

            if let best = bestIntersecting {
                if score > best.score {
                    bestIntersecting = (package, score)
                }
            } else {
                bestIntersecting = (package, score)
            }
        }

        if let bestIntersecting {
            return bestIntersecting.package
        }

        let visibleCenter = Self.centerCoordinate(of: visible)
        var nearestPackage: (package: LocalNOAAChartPackage, distanceMeters: CLLocationDistance)?

        for package in packages {
            guard let coverage = package.coverageMapRect else { continue }
            let packageCenter = Self.centerCoordinate(of: coverage)
            let a = CLLocation(latitude: visibleCenter.latitude, longitude: visibleCenter.longitude)
            let b = CLLocation(latitude: packageCenter.latitude, longitude: packageCenter.longitude)
            let distance = a.distance(from: b)

            if let nearest = nearestPackage {
                if distance < nearest.distanceMeters {
                    nearestPackage = (package, distance)
                }
            } else {
                nearestPackage = (package, distance)
            }
        }

        return nearestPackage?.package ?? packages[0]
    }

    private static func looksLikeNOAASlug(_ slug: String) -> Bool {
        let s = slug.lowercased()
        return s == "noaa"
            || s == "ncds"
            || s.hasPrefix("noaa_")
            || s.hasPrefix("noaa-")
            || s.hasPrefix("ncds_")
            || s.hasPrefix("ncds-")
    }

    private static func looksLikeBristolBaySatelliteSlug(_ slug: String) -> Bool {
        let s = slug.lowercased()
        return s == "bristol_bay" || s == "bristol-bay"
            || s.hasPrefix("bristol_bay_v") || s.hasPrefix("bristol-bay-v")
    }

    private static func noaaSlugPriority(_ slug: String) -> Int {
        let s = slug.lowercased()
        if s.hasPrefix("ncds") {
            return 0
        }
        if s.hasPrefix("noaa") {
            return 1
        }
        return 2
    }

    private static func bristolBaySatelliteSlugPriority(_ slug: String) -> Int {
        let s = slug.lowercased()
        if s == "bristol_bay" {
            return 0
        }
        if s == "bristol-bay" {
            return 1
        }
        if s.hasPrefix("bristol_bay_v") {
            return 2
        }
        if s.hasPrefix("bristol-bay-v") {
            return 3
        }
        return 2
    }

    private static func normalizedVisibleRect(_ rect: MKMapRect) -> MKMapRect {
        if rect.isNull || rect.size.width <= 0 || rect.size.height <= 0 {
            return MKMapRect(origin: MKMapPoint(x: 0, y: 0), size: MKMapSize.world)
        }
        return rect
    }

    private static func centerCoordinate(of rect: MKMapRect) -> CLLocationCoordinate2D {
        let center = MKMapPoint(
            x: rect.origin.x + rect.size.width / 2.0,
            y: rect.origin.y + rect.size.height / 2.0
        )
        return center.coordinate
    }

    private static func intersectionArea(_ a: MKMapRect, _ b: MKMapRect) -> Double {
        let aMinX = a.origin.x
        let aMaxX = a.origin.x + a.size.width
        let aMinY = a.origin.y
        let aMaxY = a.origin.y + a.size.height

        let bMinX = b.origin.x
        let bMaxX = b.origin.x + b.size.width
        let bMinY = b.origin.y
        let bMaxY = b.origin.y + b.size.height

        let width = min(aMaxX, bMaxX) - max(aMinX, bMinX)
        let height = min(aMaxY, bMaxY) - max(aMinY, bMinY)

        guard width > 0, height > 0 else { return 0 }
        return width * height
    }

    private static func coverageRect(from bounds: [Double]) -> MKMapRect? {
        MBTilesGeographicCoverage.mapRect(from: bounds)
    }

}
