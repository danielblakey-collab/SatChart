import Foundation
import MapKit
import ImageIO

/// Owns drawable pixels independently of MapKit's zoom buffers and the evictable
/// source cache. One instance belongs to one immutable package/version/appearance.
nonisolated final class RasterMapContinuity: @unchecked Sendable {
    typealias Loader = (MBTilesTileCoordinate, @escaping (MBTilesBackstopLoadOutcome) -> Void) -> Void
    struct Frame {
        let coordinates: [MBTilesTileCoordinate]
        let images: [MBTilesTileCoordinate: CGImage]
        var mapRect: MKMapRect {
            coordinates.reduce(.null) { $0.union(MBTilesViewportTilePlanner.mapRect(for: $1)) }
        }
    }
    struct Snapshot {
        let overview: Frame?
        let detail: Frame?
        var isReady: Bool { overview != nil || detail != nil }
    }
    private struct Request {
        let coordinates: [MBTilesTileCoordinate]
        var completions: [(Bool) -> Void]
    }
    private final class Batch: @unchecked Sendable {
        let request: Request
        let overview: Bool
        var nextIndex = 0
        var active = 0
        var resolved = 0
        var images: [MBTilesTileCoordinate: CGImage] = [:]
        init(_ request: Request, overview: Bool) {
            self.request = request
            self.overview = overview
        }
    }

    let bounds: MKMapRect
    let minimumZoom: Int
    let maximumZoom: Int
    // At 256px, two detail generations (displayed + loading) cost at most 24 MiB.
    static let maximumDetailTiles = 48
    static let maximumOverviewTiles = 16
    private let loader: Loader
    private let queue = DispatchQueue(label: "com.satchart.raster-continuity", qos: .userInitiated)
    private let lock = NSLock()
    private var displayed = Snapshot(overview: nil, detail: nil)
    private var invalidation: ((MKMapRect) -> Void)?
    private var batch: Batch?
    private var pending: Request?
    private var overviewAttempted = false
    private var retryOverviewAfter: TimeInterval = 0
    private var lastFailure: TimeInterval = 0

    init(bounds: MKMapRect, minimumZoom: Int, maximumZoom: Int, loader: @escaping Loader) {
        self.bounds = bounds
        self.minimumZoom = minimumZoom
        self.maximumZoom = maximumZoom
        self.loader = loader
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return displayed
    }

    func setInvalidation(_ callback: @escaping (MKMapRect) -> Void) {
        lock.lock(); invalidation = callback; lock.unlock()
    }

    /// Choose a complete pyramid level, never a center-biased truncated tile set.
    func coordinates(in rect: MKMapRect, zoom: Int, limit: Int) -> [MBTilesTileCoordinate] {
        let clipped = rect.intersection(bounds).intersection(.world)
        guard !clipped.isNull, !clipped.isEmpty else { return [] }
        for level in stride(from: min(maximumZoom, max(minimumZoom, zoom)), through: minimumZoom, by: -1) {
            let width = MKMapSize.world.width / Double(1 << level)
            let columns = floor(clipped.maxX.nextDown / width) - floor(clipped.minX / width) + 1
            let rows = floor(clipped.maxY.nextDown / width) - floor(clipped.minY / width) + 1
            guard columns * rows <= Double(limit) else { continue }
            let tiles = MBTilesViewportTilePlanner.coordinates(
                in: clipped, zoom: level, ring: 0, maximumCount: limit + 1
            )
            if tiles.count <= limit { return tiles }
        }
        return []
    }

    /// Called at settled viewports and before button zooms, never from the
    /// continuous camera callback or the synchronous renderer draw method.
    func prepare(in rect: MKMapRect, zoom: Int, completion: @escaping (Bool) -> Void = { _ in }) {
        queue.async { [weak self] in
            guard let self else { completion(false); return }
            let tiles = self.coordinates(in: rect, zoom: zoom, limit: Self.maximumDetailTiles)
            if tiles.isEmpty {
                completion(!rect.intersects(self.bounds))
                return
            }
            if self.snapshot().detail?.coordinates == tiles {
                completion(true)
                return
            }
            if var pending = self.pending, pending.coordinates == tiles {
                // Only the current camera intent matters. Bound retained callbacks.
                if pending.completions.count < 16 { pending.completions.append(completion) }
                else { completion(false) }
                self.pending = pending
                return
            }
            self.pending?.completions.forEach { $0(false) }
            self.pending = Request(coordinates: tiles, completions: [completion])
            self.startNextIfNeeded()
        }
    }

    private func startNextIfNeeded() {
        guard batch == nil, pending != nil else { return }
        if !overviewAttempted, ProcessInfo.processInfo.systemUptime >= retryOverviewAfter {
            overviewAttempted = true
            let tiles = coordinates(in: bounds, zoom: maximumZoom, limit: Self.maximumOverviewTiles)
            if !tiles.isEmpty {
                start(Request(coordinates: tiles, completions: []), overview: true)
                return
            }
        }
        guard let request = pending else { return }
        pending = nil
        if snapshot().detail?.coordinates == request.coordinates {
            request.completions.forEach { $0(true) }
        } else if ProcessInfo.processInfo.systemUptime - lastFailure < 1 {
            request.completions.forEach { $0(false) }
        } else {
            start(request, overview: false)
        }
    }

    private func start(_ request: Request, overview: Bool) {
        let next = Batch(request, overview: overview)
        batch = next
        pump(next)
    }

    private func pump(_ work: Batch) {
        while work.active < 4, work.nextIndex < work.request.coordinates.count {
            let tile = work.request.coordinates[work.nextIndex]
            work.nextIndex += 1
            work.active += 1
            load(tile, work: work, attempt: 0)
        }
        guard work.active == 0, work.nextIndex == work.request.coordinates.count else { return }
        let ready = work.resolved == work.request.coordinates.count
        if ready {
            let frame = Frame(coordinates: work.request.coordinates, images: work.images)
            lock.lock()
            let dirtyRect = work.overview ? bounds : frame.mapRect.union(displayed.detail?.mapRect ?? .null)
            displayed = Snapshot(overview: work.overview ? frame : displayed.overview,
                                 detail: work.overview ? displayed.detail : frame)
            let notify = invalidation
            lock.unlock()
            notify?(dirtyRect)
        } else {
            // A transient error cannot replace known-good pixels with an empty frame.
            lastFailure = ProcessInfo.processInfo.systemUptime
            if work.overview {
                overviewAttempted = false
                retryOverviewAfter = lastFailure + 15
            }
        }
        batch = nil
        if !ready, !work.overview, pending == nil {
            pending = Request(coordinates: work.request.coordinates, completions: [])
        }
        work.request.completions.forEach { $0(ready) }
        if !ready {
            // Bound retry rate even when the network is offline or the scheduler is full.
            queue.asyncAfter(deadline: .now() + 1.1) { [weak self] in self?.startNextIfNeeded() }
        } else {
            startNextIfNeeded()
        }
    }

    private func load(_ tile: MBTilesTileCoordinate, work: Batch, attempt: Int) {
        loader(tile) { [weak self, weak work] outcome in
            guard let self, let work else { return }
            self.queue.async {
                guard self.batch === work else { return }
                switch outcome {
                case .image(let image):
                    work.images[tile] = work.overview ? Self.resized(image, maximumSide: 128) : Self.resized(image, maximumSide: 256)
                    work.resolved += 1
                case .missing:
                    work.resolved += 1
                case .transientFailure where attempt < 2:
                    self.queue.asyncAfter(deadline: .now() + (attempt == 0 ? 0.15 : 0.5)) { [weak self, weak work] in
                        guard let self, let work, self.batch === work else { return }
                        self.load(tile, work: work, attempt: attempt + 1)
                    }
                    return
                case .transientFailure, .cancelled:
                    break
                }
                work.active -= 1
                self.pump(work)
            }
        }
    }

    private static func resized(_ image: CGImage, maximumSide: Int) -> CGImage {
        guard image.width > maximumSide || image.height > maximumSide,
              let context = CGContext(data: nil, width: maximumSide, height: maximumSide, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: maximumSide, height: maximumSide))
        return context.makeImage() ?? image
    }

    static func prepareAll(_ sources: [RasterMapContinuity], in rect: MKMapRect, zoom: Int,
                           completion: @escaping @Sendable (Bool) -> Void) {
        guard !sources.isEmpty else { completion(true); return }
        let results = Readiness(count: sources.count, completion: completion)
        for source in sources {
            source.prepare(in: rect, zoom: zoom) { results.record($0) }
        }
    }

    private final class Readiness: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        private var ready = true
        private let completion: @Sendable (Bool) -> Void
        init(count: Int, completion: @escaping @Sendable (Bool) -> Void) {
            remaining = count
            self.completion = completion
        }
        func record(_ value: Bool) {
            lock.lock()
            ready = ready && value
            remaining -= 1
            let result = remaining == 0 ? ready : nil
            lock.unlock()
            if let result { completion(result) }
        }
    }

    private static let decodingQueue = DispatchQueue(label: "com.satchart.continuity-decode", qos: .userInitiated)

    static func decode(_ data: Data?, error: Error?, completion: @escaping (MBTilesBackstopLoadOutcome) -> Void) {
        decodingQueue.async {
            guard let data else {
                completion(error == nil || (error as? BristolBaySatelliteTileStoreError) == .notFound
                           ? .missing : .transientFailure)
                return
            }
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, options),
                  image.width == 256, image.height == 256 else {
                completion(.transientFailure)
                return
            }
            completion(.image(image))
        }
    }
}

/// A stable overlay renderer can synchronously repaint retained parent pixels at
/// every scale. Its draw path does no database, network, image decoding, or prefetch.
nonisolated class RasterContinuityRenderer: MKOverlayRenderer, @unchecked Sendable {
    let continuity: RasterMapContinuity
    private let stateLock = NSLock()
    private var frozenSnapshot: RasterMapContinuity.Snapshot?
    private var cameraMoving = false
    private var dirtyRect: MKMapRect = .null
    private var invalidationScheduled = false
    private var invalidationCount = 0

    init(overlay: MKOverlay, continuity: RasterMapContinuity) {
        self.continuity = continuity
        super.init(overlay: overlay)
        continuity.setInvalidation { [weak self] rect in self?.receivedImages(in: rect) }
    }

    /// Freeze both the pixels and invalidations for the duration of a gesture or
    /// animation. Late completions must not discard the zoom buffers in use.
    func setCameraMovementActive(_ active: Bool) {
        stateLock.lock()
        guard cameraMoving != active else { stateLock.unlock(); return }
        cameraMoving = active
        frozenSnapshot = active ? continuity.snapshot() : nil
        stateLock.unlock()
        if !active { scheduleInvalidationIfNeeded() }
    }

    var invalidationFlushCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return invalidationCount
    }

    private func drawingSnapshot() -> RasterMapContinuity.Snapshot {
        stateLock.lock(); defer { stateLock.unlock() }
        return frozenSnapshot ?? continuity.snapshot()
    }

    private func receivedImages(in rect: MKMapRect) {
        stateLock.lock()
        dirtyRect = dirtyRect.union(rect)
        // Capture a cold layer's first ready frame for any new MapKit draw requests;
        // explicit invalidation still waits until the camera settles.
        if cameraMoving, frozenSnapshot?.isReady == false {
            frozenSnapshot = continuity.snapshot()
        }
        stateLock.unlock()
        scheduleInvalidationIfNeeded()
    }

    private func scheduleInvalidationIfNeeded() {
        stateLock.lock()
        guard !cameraMoving, !dirtyRect.isNull, !invalidationScheduled else {
            stateLock.unlock(); return
        }
        invalidationScheduled = true
        stateLock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.invalidationScheduled = false
            guard !self.cameraMoving else { self.stateLock.unlock(); return }
            let rect = self.dirtyRect
            self.dirtyRect = .null
            self.invalidationCount += 1
            self.stateLock.unlock()
            // Limit invalidation to the replaced footprint. Never flush every
            // zoom buffer over the entire district/Bristol Bay overlay.
            if !rect.isNull { self.setNeedsDisplay(rect) }
        }
    }

    override func canDraw(_ mapRect: MKMapRect, zoomScale: MKZoomScale) -> Bool {
        drawingSnapshot().isReady
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let snapshot = drawingSnapshot()
        let clipped = mapRect.intersection(continuity.bounds)
        guard !clipped.isNull, !clipped.isEmpty else { return }
        context.saveGState()
        context.clip(to: rect(for: clipped))
        context.interpolationQuality = .medium
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext(); context.restoreGState() }

        func drawImages(_ frame: RasterMapContinuity.Frame) {
            for tile in frame.coordinates {
                let tileRect = MBTilesViewportTilePlanner.mapRect(for: tile)
                guard tileRect.intersects(clipped), let image = frame.images[tile] else { continue }
                UIImage(cgImage: image).draw(in: rect(for: tileRect), blendMode: .normal, alpha: 1)
            }
        }

        if let overview = snapshot.overview {
            context.saveGState()
            // Draw exactly one resolution at each point. Punch holes in the clip,
            // not in MapKit's shared drawing surface: transparent district pixels
            // must preserve the Bristol Bay layer underneath them.
            context.addRect(rect(for: clipped))
            for tile in snapshot.detail?.coordinates ?? [] {
                let tileRect = MBTilesViewportTilePlanner.mapRect(for: tile).intersection(clipped)
                if !tileRect.isNull, !tileRect.isEmpty { context.addRect(rect(for: tileRect)) }
            }
            context.clip(using: .evenOdd)
            drawImages(overview)
            context.restoreGState()
        }
        if let detail = snapshot.detail { drawImages(detail) }
    }

    static func displayZoom(for zoomScale: MKZoomScale) -> Double {
        Darwin.log2(Double(zoomScale) * MKMapSize.world.width / 256)
    }
}

/// A bounded, cancellable wait for button zooms. Pinch gestures never use this gate.
@MainActor
final class RasterZoomGate {
    private(set) var targetZoom: Double?
    private var generation: UInt64 = 0
    private var timeout: DispatchWorkItem?

    func cancel() {
        generation &+= 1
        timeout?.cancel()
        timeout = nil
        targetZoom = nil
    }

    func request(targetZoom: Double, delay: TimeInterval = 0.35,
                 preload: (@escaping @Sendable (Bool) -> Void) -> Void,
                 commit: @escaping @MainActor @Sendable () -> Void) {
        cancel()
        self.targetZoom = targetZoom
        let token = generation
        let finish: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.generation == token, self.targetZoom != nil else { return }
            self.cancel()
            commit()
        }
        let work = DispatchWorkItem(block: finish)
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        preload { ready in if ready { DispatchQueue.main.async(execute: finish) } }
    }
}
