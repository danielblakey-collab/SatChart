import Testing
import Foundation
import MapKit
import UIKit
@testable import SatChart

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RasterMapContinuityTests {
    nonisolated private final class Source: @unchecked Sendable {
        let image: CGImage
        private let lock = NSLock()
        private var pending: [(MBTilesBackstopLoadOutcome) -> Void] = []
        private var highZoomOutcome: MBTilesBackstopLoadOutcome?
        private var holdHighZoom = false
        private(set) var maximumWaiting = 0

        init() {
            let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            image = context.makeImage()!
        }
        func hold() { lock.lock(); holdHighZoom = true; lock.unlock() }
        func fail() { lock.lock(); highZoomOutcome = .transientFailure; lock.unlock() }
        func missing() { lock.lock(); highZoomOutcome = .missing; lock.unlock() }
        func load(_ tile: MBTilesTileCoordinate, completion: @escaping (MBTilesBackstopLoadOutcome) -> Void) {
            lock.lock()
            if tile.z >= 5, holdHighZoom {
                pending.append(completion)
                maximumWaiting = max(maximumWaiting, pending.count)
                lock.unlock()
                return
            }
            let outcome = tile.z >= 5 ? highZoomOutcome : nil
            lock.unlock()
            completion(outcome ?? .image(image))
        }
        func release() {
            lock.lock()
            holdHighZoom = false
            let callbacks = pending
            pending = []
            lock.unlock()
            callbacks.forEach { $0(.image(image)) }
        }
    }

    private static var bounds: MKMapRect {
        MBTilesViewportTilePlanner.mapRect(for: MBTilesTileCoordinate(z: 2, x: 1, y: 1)!)
    }
    private static var target: MKMapRect {
        let b = bounds
        return MKMapRect(x: b.midX, y: b.midY, width: b.width / 2, height: b.height / 2)
    }
    private func makeContinuity(_ source: Source) -> RasterMapContinuity {
        RasterMapContinuity(bounds: Self.bounds, minimumZoom: 2, maximumZoom: 8, loader: source.load)
    }
    private func prepare(_ source: RasterMapContinuity, rect: MKMapRect, zoom: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            source.prepare(in: rect, zoom: zoom) { continuation.resume(returning: $0) }
        }
    }

    @Test func plannerDowngradesHugeViewsBeforeEnumeratingCoordinates() {
        let source = RasterMapContinuity(bounds: .world, minimumZoom: 0, maximumZoom: 30) { _, result in result(.missing) }
        let tiles = source.coordinates(in: .world, zoom: 30, limit: 48)
        #expect(tiles.count == 16)
        #expect(tiles.allSatisfy { $0.z == 2 })
        #expect(Set(tiles).count == 16)
    }

    @Test func completeOldImagesRemainDrawableThroughoutDelayedZoom() async {
        let loader = Source()
        let source = makeContinuity(loader)
        #expect(await prepare(source, rect: Self.bounds, zoom: 4))
        let original = source.snapshot()
        #expect(original.overview?.images.count == 16)
        #expect(original.overview?.images.values.allSatisfy { $0.width == 128 } == true)
        loader.hold()
        let result = Task { await prepare(source, rect: Self.target, zoom: 5) }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(source.snapshot().detail?.coordinates == original.detail?.coordinates)
        let overlay = MKPolygon(points: [MKMapPoint(x: Self.bounds.minX, y: Self.bounds.minY),
                                         MKMapPoint(x: Self.bounds.maxX, y: Self.bounds.minY),
                                         MKMapPoint(x: Self.bounds.maxX, y: Self.bounds.maxY)], count: 3)
        let renderer = RasterContinuityRenderer(overlay: overlay, continuity: source)
        for zoom in 2...8 {
            let scale = MKZoomScale(256 * pow(2, Double(zoom)) / MKMapSize.world.width)
            #expect(renderer.canDraw(Self.target, zoomScale: scale))
            // Render actual retained pixels at each scale over a green stand-in basemap.
            let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                    bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            let projected = renderer.rect(for: Self.target)
            context.scaleBy(x: 64 / projected.width, y: 64 / projected.height)
            context.translateBy(x: -projected.minX, y: -projected.minY)
            renderer.draw(Self.target, zoomScale: scale, in: context)
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            let completelyCovered = (1..<63).allSatisfy { y in
                (1..<63).allSatisfy { x in
                    let offset = y * 256 + x * 4
                    return bytes[offset] > 220 && bytes[offset + 1] < 80 && bytes[offset + 2] < 80 && bytes[offset + 3] == 255
                }
            }
            #expect(completelyCovered)

        }
        loader.release()
        #expect(await result.value)
        #expect(source.snapshot().detail?.coordinates.allSatisfy { $0.z == 5 } == true)
        #expect(loader.maximumWaiting <= 4)
    }

    @Test func failedReplacementDoesNotClearTheCurrentFrame() async {
        let loader = Source()
        let source = makeContinuity(loader)
        #expect(await prepare(source, rect: Self.bounds, zoom: 4))
        let original = source.snapshot().detail?.coordinates
        loader.fail()
        #expect(!(await prepare(source, rect: Self.target, zoom: 5)))
        #expect(source.snapshot().detail?.coordinates == original)
        #expect(source.snapshot().overview != nil)
    }

    @Test func sparseMissingTilesResolveWithoutInventingOpaqueCoverage() async {
        let loader = Source()
        let source = makeContinuity(loader)
        #expect(await prepare(source, rect: Self.bounds, zoom: 4))
        loader.missing()
        #expect(await prepare(source, rect: Self.target, zoom: 5))
        #expect(source.snapshot().detail?.coordinates.count == 16)
        #expect(source.snapshot().detail?.images.isEmpty == true)
    }

    @Test func outsideCoverageRequestsCompleteWithoutLoading() async {
        let source = RasterMapContinuity(bounds: Self.bounds, minimumZoom: 2, maximumZoom: 8) { _, _ in
            Issue.record("Outside-coverage readiness must not request tiles")
        }
        #expect(await prepare(source, rect: MKMapRect(x: 0, y: 0, width: 10, height: 10), zoom: 8))
        #expect(!source.snapshot().isReady)
    }

    @Test func networkMissingAndTransientErrorsStayDistinct() async {
        let missing = await withCheckedContinuation { continuation in
            RasterMapContinuity.decode(nil, error: BristolBaySatelliteTileStoreError.notFound) {
                continuation.resume(returning: $0)
            }
        }
        guard case .missing = missing else { Issue.record("HTTP 404 must be terminal missing"); return }
        let failure = await withCheckedContinuation { continuation in
            RasterMapContinuity.decode(nil, error: URLError(.timedOut)) { continuation.resume(returning: $0) }
        }
        guard case .transientFailure = failure else { Issue.record("Timeout cannot erase imagery"); return }
    }

    @Test func onlineContinuityUsesSelectedXYZVersionForEveryLevel() async throws {
        let source = try #require(OnlineDistrictMapCatalog.maps.last)
        let png = try #require(UIImage(cgImage: Source().image).pngData())
        let overlay = OnlineDistrictTileOverlay(source: source) { url, key, completion in
            #expect(url.path.hasPrefix("/egegik_v7_xyz/"))
            #expect(key.hasPrefix("districts/egegik_v7_xyz/"))
            completion(png, nil)
        }
        #expect(await prepare(overlay.continuity, rect: source.bounds, zoom: 12))
        #expect(overlay.continuity.snapshot().overview?.images.isEmpty == false)
        #expect(overlay.continuity.snapshot().detail?.images.isEmpty == false)
    }

    @Test func buttonZoomWaitsForReadinessAndCommitsOnlyOnce() async {
        let gate = RasterZoomGate()
        var ready: (@Sendable (Bool) -> Void)?
        var commits = 0
        gate.request(targetZoom: 13, delay: 0.1, preload: { ready = $0 }) { commits += 1 }
        #expect(commits == 0 && gate.targetZoom == 13)
        ready?(true)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(commits == 1 && gate.targetZoom == nil)
        ready?(true)
        try? await Task.sleep(for: .milliseconds(10))
        #expect(commits == 1)
    }

    @Test func timeoutStillZoomsWhenNetworkFails() async {
        let gate = RasterZoomGate()
        var commits = 0
        gate.request(targetZoom: 13, delay: 0.03, preload: { $0(false) }) { commits += 1 }
        #expect(commits == 0)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(commits == 1)
    }

    @Test func rapidTapsAndCancellationRejectStalePreloads() async {
        let gate = RasterZoomGate()
        var first: (@Sendable (Bool) -> Void)?
        var second: (@Sendable (Bool) -> Void)?
        var commits: [Int] = []
        gate.request(targetZoom: 13, delay: 0.1, preload: { first = $0 }) { commits.append(13) }
        gate.request(targetZoom: (gate.targetZoom ?? 0) + 1, delay: 0.1, preload: { second = $0 }) { commits.append(14) }
        #expect(gate.targetZoom == 14)
        first?(true)
        try? await Task.sleep(for: .milliseconds(10))
        #expect(commits.isEmpty)
        gate.cancel() // Gesture, source/appearance change, or view teardown.
        second?(true)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(commits.isEmpty && gate.targetZoom == nil)
    }
}
