import Foundation
import MapKit
import ImageIO
import CryptoKit
import UIKit

/// Reservations travel with frames (including a renderer's frozen frame). Sharing
/// a frame does not double-charge it; dropping the last reference releases bytes.
nonisolated final class RasterImageBudget: @unchecked Sendable {
    final class Lease: @unchecked Sendable {
        let bytes: Int
        private let owner: RasterImageBudget
        fileprivate init(bytes: Int, owner: RasterImageBudget) { self.bytes = bytes; self.owner = owner }
        deinit { owner.release(bytes) }
    }
    let limit: Int
    private let lock = NSLock()
    private var used = 0
    private var peak = 0
    init(limit: Int) { self.limit = limit }
    func reserve(_ bytes: Int) -> Lease? {
        lock.lock(); defer { lock.unlock() }
        guard bytes > 0, bytes <= limit - used else { return nil }
        used += bytes; peak = max(peak, used)
        return Lease(bytes: bytes, owner: self)
    }
    private func release(_ bytes: Int) { lock.lock(); used -= bytes; lock.unlock() }
    var usage: (current: Int, peak: Int) {
        lock.lock(); defer { lock.unlock() }
        return (used, peak)
    }
}

nonisolated enum OnlineChartSource: String, Sendable {
    case usgs, noaa
    var maximumZoom: Int { self == .usgs ? 23 : 18 }
    var lifetime: TimeInterval { self == .usgs ? 7 * 86_400 : 6 * 3_600 }
    var exportBase: String {
        self == .usgs
            ? "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/export"
            : "https://gis.charttools.noaa.gov/arcgis/rest/services/MCS/NOAAChartDisplay/MapServer/exts/MaritimeChartService/MapServer/export"
    }
    func key(_ tile: MBTilesTileCoordinate, pixels: Int) -> String {
        "charts-v1/\(rawValue)/\(pixels)/\(tile.z)/\(tile.x)/\(tile.y)"
    }
    func cachedURL(_ tile: MBTilesTileCoordinate) -> URL {
        URL(string: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/\(tile.z)/\(tile.y)/\(tile.x)?blankTile=false")!
    }
    func exportURL(_ tile: MBTilesTileCoordinate, pixels: Int) -> URL {
        let half = 20_037_508.342789244
        let width = half * 2 / Double(1 << tile.z)
        let left = -half + Double(tile.x) * width
        let top = half - Double(tile.y) * width
        var url = URLComponents(string: exportBase)!
        url.queryItems = [
            .init(name: "bbox", value: "\(left),\(top - width),\(left + width),\(top)"),
            .init(name: "bboxSR", value: "102100"), .init(name: "imageSR", value: "102100"),
            .init(name: "size", value: "\(pixels),\(pixels)"),
            .init(name: "dpi", value: "\(96 * pixels / 256)"),
            .init(name: "transparent", value: self == .noaa ? "true" : "false"),
            .init(name: "format", value: "png32"), .init(name: "f", value: "image")
        ]
        return url.url!
    }
}

/// USGS/NOAA share this store and image allowance. No decoded-image cache is
/// stacked beneath the retained renderer. Network, disk reads and decoding use
/// one lane; streamed responses stop at 1 MiB before a large body can accumulate.
nonisolated final class OnlineChartTileStore: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Completion = (MBTilesBackstopLoadOutcome) -> Void
    static let shared = OnlineChartTileStore()
    static let payloadLimit = 1_024 * 1_024
    static let compressedLimit = 2 * 1_024 * 1_024
    static let imageLimit = 16 * 1_024 * 1_024
    let imageBudget: RasterImageBudget
    let pixelSize: Int
    private struct Entry { let data: Data; let date: Date }
    private struct Listener { let owner: UUID; let completion: Completion }
    private final class Job {
        let source: OnlineChartSource
        let tile: MBTilesTileCoordinate
        let pixels: Int
        let key: String
        var listeners: [Listener]
        var exporting: Bool
        init(source: OnlineChartSource, tile: MBTilesTileCoordinate, pixels: Int, owner: UUID,
             completion: @escaping Completion) {
            self.source = source; self.tile = tile; self.pixels = pixels
            key = source.key(tile, pixels: pixels)
            exporting = source == .noaa
            listeners = [Listener(owner: owner, completion: completion)]
        }
        var url: URL { exporting ? source.exportURL(tile, pixels: pixels) : source.cachedURL(tile) }
    }
    private let queue = DispatchQueue(label: "com.satchart.online-charts", qos: .userInitiated)
    private let cache = CostedLRU<String, Entry>(costLimit: OnlineChartTileStore.compressedLimit, countLimit: 64)
    private var jobs: [Job] = []
    private var active: Job?
    private var task: URLSessionDataTask?
    private var exportAfterCancellation = false
    private var body = Data()
    private var observers: [NSObjectProtocol] = []
    private var suspended = false
    private var retryAfter: [String: Date] = [:]
    private var absentCacheTiles: [String: Date] = [:]
    private let directory: URL
    private let configuration: URLSessionConfiguration
    private var _session: URLSession?
    private var session: URLSession {
        if let existing = _session { return existing }
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        _session = session
        return session
    }

    // Injectable URLSession configuration and cache root keep tests deterministic.
    init(configuration: URLSessionConfiguration = .ephemeral, directory: URL? = nil,
         pixelSize: Int? = nil, imageByteLimit: Int? = nil, observeSystem: Bool = true) {
        let profile = MBTilesResourceProfile.current()
        self.pixelSize = pixelSize ?? (profile.onlineSatelliteConnections < 3 ? 256 : 512)
        imageBudget = RasterImageBudget(limit: imageByteLimit ?? max(Self.imageLimit, profile.onlineSatelliteCacheBytes - 8 * 1_024 * 1_024))
        self.configuration = configuration
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OnlineChartTiles/v1", isDirectory: true)
        super.init()
        queue.async { [self] in trimDisk() }
        if observeSystem {
            let center = NotificationCenter.default
            for notification in [ProcessInfo.thermalStateDidChangeNotification,
                                 Notification.Name.NSProcessInfoPowerStateDidChange] {
                observers.append(center.addObserver(forName: notification, object: nil, queue: nil) { [weak self] _ in
                    self?.purge(suspend: false)
                })
            }
            observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                 object: nil, queue: nil) { [weak self] _ in
                self?.purge(suspend: false)
            })
            observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                 object: nil, queue: nil) { [weak self] _ in
                self?.purge(suspend: true)
            })
            observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                 object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in self?.suspended = false }
            })
        }
    }

    func load(source: OnlineChartSource, tile: MBTilesTileCoordinate, owner: UUID,
              completion: @escaping Completion) {
        queue.async { [self] in
            guard !suspended else { completion(.cancelled); return }
            let pixels = MBTilesResourceProfile.current().maximumSpeculativeWork == 0 ? 256 : pixelSize
            let key = source.key(tile, pixels: pixels)
            if let matching = ([active].compactMap { $0 } + jobs).first(where: { $0.key == key }) {
                guard matching.listeners.count < 16 else { completion(.transientFailure); return }
                matching.listeners.append(Listener(owner: owner, completion: completion))
                return
            }
            guard jobs.count < 48 else { completion(.transientFailure); return }
            jobs.append(Job(source: source, tile: tile, pixels: pixels, owner: owner, completion: completion))
            pump()
        }
    }

    func cancel(owner: UUID) {
        queue.async { [self] in
            for job in jobs + [active].compactMap({ $0 }) {
                let cancelled = job.listeners.filter { $0.owner == owner }
                job.listeners.removeAll { $0.owner == owner }
                cancelled.forEach { $0.completion(.cancelled) }
            }
            jobs.removeAll { $0.listeners.isEmpty }
            if active?.listeners.isEmpty == true {
                task?.cancel(); active = nil; body = Data(); exportAfterCancellation = false
            }
            pump()
        }
    }

    func purge(suspend: Bool) {
        queue.async { [self] in
            suspended = suspended || suspend
            cache.removeAll(); absentCacheTiles.removeAll(); retryAfter.removeAll()
            task?.cancel(); body = Data(); exportAfterCancellation = false
            let cancelled = jobs + [active].compactMap { $0 }
            jobs.removeAll(); active = nil
            cancelled.flatMap(\.listeners).forEach { $0.completion(.cancelled) }
        }
    }
    func shutdown() {
        purge(suspend: true)
        queue.async { [self] in _session?.invalidateAndCancel(); _session = nil }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func pump() {
        guard active == nil, task == nil, !suspended, !jobs.isEmpty else { return }
        let job = jobs.removeLast() // Newest viewport first, with bounded admission.
        active = job
        if let entry = cache.value(for: job.key), Date().timeIntervalSince(entry.date) < job.source.lifetime,
           let image = Self.decode(entry.data, maximumSide: job.pixels) {
            finish(.image(image)); return
        }
        let url = fileURL(job.key)
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
           let size = values.fileSize, size > 0, size <= Self.payloadLimit,
           Date().timeIntervalSince(values.contentModificationDate ?? .distantPast) < job.source.lifetime,
           let data = try? Data(contentsOf: url), let image = Self.decode(data, maximumSide: job.pixels) {
            cache.insert(Entry(data: data, date: values.contentModificationDate!), for: job.key, cost: data.count)
            finish(.image(image)); return
        }
        if let missingUntil = absentCacheTiles[job.key], missingUntil > Date() { job.exporting = true }
        beginNetwork(job)
    }

    private func beginNetwork(_ job: Job) {
        if let until = retryAfter[job.url.host ?? ""], until > Date() { finish(.transientFailure); return }
        body = Data()
        var request = URLRequest(url: job.url)
        request.setValue("image/png,image/jpeg", forHTTPHeaderField: "Accept")
        task = session.dataTask(with: request)
        task?.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard task === dataTask, let job = active, let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); return
        }
        let missing = [204, 404, 410].contains(http.statusCode)
            || http.value(forHTTPHeaderField: "blank-tile")?.lowercased() == "true"
        if missing, job.source == .usgs, !job.exporting {
            completionHandler(.cancel)
            if absentCacheTiles.count >= 1_024 { absentCacheTiles.removeAll() }
            absentCacheTiles[job.key] = Date().addingTimeInterval(3_600)
            job.exporting = true
            exportAfterCancellation = true
            return
        }
        let mime = (http.mimeType ?? "").lowercased()
        guard (200...299).contains(http.statusCode), !missing,
              ["image/png", "image/jpeg"].contains(mime),
              response.expectedContentLength <= Int64(Self.payloadLimit) else {
            if http.statusCode == 429 || http.statusCode == 503 {
                let delay = TimeInterval(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
                retryAfter[job.url.host ?? ""] = Date().addingTimeInterval(min(60, max(1, delay)))
            }
            completionHandler(.cancel)
            finish(missing ? .missing : .transientFailure)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard task === dataTask else { return }
        guard data.count <= Self.payloadLimit - body.count else {
            dataTask.cancel(); finish(.transientFailure); return
        }
        body.append(data)
    }
    func urlSession(_ session: URLSession, task completedTask: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === completedTask else { return }
        task = nil
        guard let job = active else { exportAfterCancellation = false; pump(); return }
        if exportAfterCancellation {
            exportAfterCancellation = false
            beginNetwork(job)
            return
        }
        guard error == nil, let image = Self.decode(body, maximumSide: job.pixels) else {
            finish(.transientFailure); return
        }
        cache.insert(Entry(data: body, date: Date()), for: job.key, cost: body.count)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? body.write(to: fileURL(job.key), options: .atomic)
        trimDisk()
        finish(.image(image))
    }
    private func finish(_ outcome: MBTilesBackstopLoadOutcome) {
        let listeners = active?.listeners ?? []
        active = nil; body = Data()
        // URLSession cancellation is asynchronous. Keep its slot occupied until
        // didComplete arrives, rather than briefly running two large responses.
        task?.cancel()
        listeners.forEach { $0.completion(outcome) }
        // Do not recursively decode a long run of cache hits on one stack.
        queue.async { [weak self] in self?.pump() }
    }

    static func decode(_ data: Data, maximumSide: Int) -> CGImage? {
        guard !data.isEmpty, data.count <= payloadLimit,
              let source = CGImageSourceCreateWithData(data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width == height, [256, 512].contains(width),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumSide,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        // Canonical 8-bit RGBA storage makes reservation costs predictable.
        let side = min(width, maximumSide)
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }
    private func fileURL(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".tile")
    }
    private func trimDisk() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        var entries: [(URL, Int, Date)] = []
        for url in urls where url.pathExtension == "tile" {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                entries.append((url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
            }
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        var count = entries.count
        for entry in entries.sorted(by: { $0.2 < $1.2 }) {
            guard total > 64 * 1_024 * 1_024 || count > 1_024 else { break }
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1; count -= 1
        }
    }
}

/// One retained painter, as for the district maps. Source requests stay separate
/// from presentation so MapKit never owns a second, competing tile renderer.
class OnlineChartOverlay: MKTileOverlay {
    let source: OnlineChartSource
    let continuity: RasterMapContinuity
    private let store: OnlineChartTileStore
    private let owner = UUID()

    init(source: OnlineChartSource, store: OnlineChartTileStore = .shared) {
        self.source = source
        self.store = store
        let owner = self.owner
        var policy = RasterMapContinuity.Policy()
        policy.detailTiles = store.pixelSize == 256 ? 28 : 18
        policy.detailPixelSize = store.pixelSize
        policy.localOverview = true
        policy.overviewTiles = 9
        policy.concurrentLoads = 1
        policy.imageBudget = store.imageBudget
        policy.cancelLoads = { store.cancel(owner: owner) }
        continuity = RasterMapContinuity(bounds: .world, minimumZoom: 0,
                                         maximumZoom: source.maximumZoom, policy: policy) { tile, completion in
            store.load(source: source, tile: tile, owner: owner, completion: completion)
        }
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0
        maximumZ = source.maximumZoom
    }
    func stopLoading(keepVisibleFrame: Bool = false) { continuity.invalidate(keepVisibleFrame: keepVisibleFrame) }
    deinit { store.cancel(owner: owner) }
    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        guard let tile = MBTilesTileCoordinate(z: path.z, x: path.x, y: path.y) else {
            return URL(string: source.exportBase)!
        }
        return source == .usgs ? source.cachedURL(tile) : source.exportURL(tile, pixels: store.pixelSize)
    }
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        // The coordinator always supplies RasterContinuityRenderer. Reject an
        // accidental ordinary renderer rather than bypassing the shared budgets.
        result(nil, nil)
    }
}
