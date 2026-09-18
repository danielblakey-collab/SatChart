import XCTest
import MapKit
import UIKit
@testable import SatChart

@MainActor
final class OnlineDistrictCancellationTests: XCTestCase {
    nonisolated private final class Network: @unchecked Sendable {
        struct Job {
            let request: URLRequest
            var completion: ((Data?, URLResponse?, Error?) -> Void)?
            var cancelled = false
        }
        private let lock = NSLock()
        private var jobs: [Job] = []
        func start(_ request: URLRequest, completion: @escaping (Data?, URLResponse?, Error?) -> Void) -> (() -> Void) {
            lock.lock()
            let index = jobs.count
            jobs.append(Job(request: request, completion: completion))
            lock.unlock()
            return { [self] in
                lock.lock(); jobs[index].cancelled = true; lock.unlock()
            }
        }
        var requests: [String] {
            lock.lock(); defer { lock.unlock() }
            return jobs.map { $0.request.url!.lastPathComponent }
        }
        func isCancelled(_ index: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return jobs.indices.contains(index) && jobs[index].cancelled
        }
        /// Cancellation is deliberately acknowledged later, as URLSession does.
        /// A racing successful response after cancel exercises stale identity guards.
        func finish(_ index: Int, data: Data? = nil, error: Error? = nil) {
            lock.lock()
            let job = jobs[index]
            // Keep request history without retaining the completed store callback.
            jobs[index].completion = nil
            lock.unlock()
            guard let completion = job.completion else { return }
            let response = HTTPURLResponse(url: job.request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
            completion(data, response, error)
        }
    }

    nonisolated private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: [(Data?, Error?)]] = [:]
        func record(_ name: String, data: Data?, error: Error?) {
            lock.lock(); values[name, default: []].append((data, error)); lock.unlock()
        }
        func entries(_ name: String) -> [(Data?, Error?)] {
            lock.lock(); defer { lock.unlock() }
            return values[name] ?? []
        }
    }

    private enum WaitFailure: Error { case timedOut }
    private func until(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()) {
            guard Date() < deadline else { XCTFail("Condition never became true"); throw WaitFailure.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private func image(_ color: UIColor = .red) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).pngData {
            color.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }
    }
    private func makeStore(_ network: Network) -> (BristolBaySatelliteTileStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("district-cancel-\(UUID())")
        let profile = MBTilesResourceProfile.make(activeProcessorCount: 4, physicalMemory: 4 * 1_024 * 1_024 * 1_024)
        return (BristolBaySatelliteTileStore(directory: directory, profile: profile, observeSystem: false,
            transport: network.start), directory)
    }
    private func load(_ key: String, owner: UUID?, store: BristolBaySatelliteTileStore,
                      results: Results, name: String? = nil) {
        store.loadTile(url: URL(string: "https://tiles.test/\(key)")!, cacheKey: key, owner: owner) {
            results.record(name ?? key, data: $0, error: $1)
        }
    }
    private func assertCancelled(_ result: [(Data?, Error?)], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.count, 1, file: file, line: line)
        XCTAssertNil(result.first?.0, file: file, line: line)
        XCTAssertEqual((result.first?.1 as? URLError)?.code, .cancelled, file: file, line: line)
    }

    func testCancellingQueuedViewportDoesNotFetchItsTiles() async throws {
        let network = Network(); let results = Results()
        let (store, directory) = makeStore(network)
        defer { try? FileManager.default.removeItem(at: directory) }
        load("blocker", owner: nil, store: store, results: results)
        try await until { network.requests == ["blocker"] }
        let staleOwner = UUID()
        load("stale", owner: staleOwner, store: store, results: results)
        try await until { (await store.workSnapshot()).pendingKeys.contains("stale") }
        store.cancel(owner: staleOwner)
        load("visible", owner: UUID(), store: store, results: results)
        try await until { (await store.workSnapshot()).pendingKeys == ["visible"] }
        try await until { results.entries("stale").count == 1 }
        assertCancelled(results.entries("stale"))
        network.finish(0, data: image())
        try await until { network.requests.count == 2 }
        XCTAssertEqual(network.requests, ["blocker", "visible"])
        network.finish(1, data: image())
        try await until { results.entries("visible").count == 1 }
        XCTAssertEqual(results.entries("stale").count, 1)
        let limits = await store.workSnapshot()
        XCTAssertEqual(limits.maximumNetworkCount, 1)
        XCTAssertEqual(limits.maximumSourceKeys, 96)
        XCTAssertEqual(OnlineDistrictTileOverlay.imageBudget.limit, 32 * 1_024 * 1_024)
    }

    func testCancelledActiveRequestKeepsItsSlotUntilAcknowledged() async throws {
        let network = Network(); let results = Results()
        let (store, directory) = makeStore(network)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = UUID()
        load("old", owner: owner, store: store, results: results)
        try await until { network.requests.count == 1 }
        store.cancel(owner: owner)
        load("new", owner: UUID(), store: store, results: results)
        try await until { (await store.workSnapshot()).pendingKeys.contains("new") }
        XCTAssertTrue(network.isCancelled(0))
        XCTAssertEqual(network.requests, ["old"])
        let waiting = await store.workSnapshot()
        XCTAssertEqual(waiting.activeNetworkCount, 1)
        try await until { results.entries("old").count == 1 }
        assertCancelled(results.entries("old"))
        network.finish(0, error: URLError(.cancelled))
        try await until { network.requests.count == 2 }
        network.finish(1, data: image())
        try await until { results.entries("new").count == 1 }
        XCTAssertEqual(results.entries("old").count, 1)
        XCTAssertNotNil(results.entries("new").first?.0)
    }

    func testCoalescedOtherOwnerAndAnonymousConsumerSurviveCancellation() async throws {
        let network = Network(); let results = Results()
        let (store, directory) = makeStore(network)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = UUID()
        load("shared", owner: owner, store: store, results: results, name: "cancelled")
        try await until { network.requests.count == 1 }
        load("shared", owner: UUID(), store: store, results: results, name: "other")
        load("shared", owner: nil, store: store, results: results, name: "anonymous")
        store.cancel(owner: owner)
        try await until { results.entries("cancelled").count == 1 }
        XCTAssertFalse(network.isCancelled(0))
        XCTAssertEqual(network.requests.count, 1)
        let png = image()
        network.finish(0, data: png)
        try await until { results.entries("other").count == 1 && results.entries("anonymous").count == 1 }
        assertCancelled(results.entries("cancelled"))
        XCTAssertEqual(results.entries("other").first?.0, png)
        XCTAssertEqual(results.entries("anonymous").first?.0, png)
    }

    func testCancelThenRequestSameKeyIgnoresOldSuccessfulCompletion() async throws {
        let network = Network(); let results = Results()
        let (store, directory) = makeStore(network)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = UUID()
        load("same", owner: owner, store: store, results: results, name: "old")
        try await until { network.requests.count == 1 }
        store.cancel(owner: owner)
        load("same", owner: owner, store: store, results: results, name: "new")
        try await until { (await store.workSnapshot()).pendingKeys.contains("same") }
        network.finish(0, data: image(.red))
        try await until { network.requests.count == 2 }
        XCTAssertTrue(results.entries("new").isEmpty)
        let blue = image(.blue)
        network.finish(1, data: blue)
        try await until { results.entries("new").count == 1 && results.entries("old").count == 1 }
        assertCancelled(results.entries("old"))
        XCTAssertEqual(results.entries("new").first?.0, blue)
        // Only the current generation may populate the shared cache.
        load("same", owner: nil, store: store, results: results, name: "cached")
        try await until { results.entries("cached").count == 1 }
        XCTAssertEqual(results.entries("cached").first?.0, blue)
        XCTAssertEqual(network.requests.count, 2)
    }

    func testCancellationDoesNotBypassImageValidation() async throws {
        let network = Network(); let results = Results()
        let (store, directory) = makeStore(network)
        defer { try? FileManager.default.removeItem(at: directory) }
        load("bad", owner: UUID(), store: store, results: results)
        try await until { network.requests.count == 1 }
        network.finish(0, data: Data("not an image".utf8))
        try await until { results.entries("bad").count == 1 }
        XCTAssertNil(results.entries("bad").first?.0)
        XCTAssertEqual(results.entries("bad").first?.1 as? BristolBaySatelliteTileStoreError, .invalidImageResponse)
    }
}

@MainActor
final class DistrictContinuityCancellationTests: XCTestCase {
    nonisolated private final class Loader: @unchecked Sendable {
        private let lock = NSLock()
        let image: CGImage
        private var held = false
        private var pending: [(MBTilesTileCoordinate, (MBTilesBackstopLoadOutcome) -> Void)] = []
        private var cancelled: [(MBTilesBackstopLoadOutcome) -> Void] = []
        private var _cancelCount = 0
        init() {
            let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            image = context.makeImage()!
        }
        func hold() { lock.lock(); held = true; lock.unlock() }
        func load(_ tile: MBTilesTileCoordinate, completion: @escaping (MBTilesBackstopLoadOutcome) -> Void) {
            lock.lock()
            if held { pending.append((tile, completion)); lock.unlock() }
            else { lock.unlock(); completion(.image(image)) }
        }
        func cancel() {
            lock.lock()
            _cancelCount += 1
            cancelled.append(contentsOf: pending.map { $0.1 })
            pending = []
            lock.unlock()
        }
        var coordinates: [MBTilesTileCoordinate] {
            lock.lock(); defer { lock.unlock() }
            return pending.map { $0.0 }
        }
        var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return _cancelCount }
        func releaseCurrent() {
            lock.lock(); held = false
            let callbacks = pending.map { $0.1 }; pending = []
            lock.unlock()
            callbacks.forEach { $0(.image(image)) }
        }
        func releaseCancelled() {
            lock.lock(); let callbacks = cancelled; cancelled = []; lock.unlock()
            callbacks.forEach { $0(.image(image)) }
        }
    }
    private var bounds: MKMapRect { rect(z: 2, x: 1, y: 1) }
    private func rect(z: Int, x: Int, y: Int) -> MKMapRect {
        MBTilesViewportTilePlanner.mapRect(for: MBTilesTileCoordinate(z: z, x: x, y: y)!)
    }
    private func source(_ loader: Loader, budget: RasterImageBudget) -> RasterMapContinuity {
        var policy = RasterMapContinuity.Policy()
        policy.cancelsSupersededLoads = true
        policy.detailTiles = 4; policy.overviewTiles = 1; policy.concurrentLoads = 1
        policy.imageBudget = budget; policy.cancelLoads = loader.cancel
        return RasterMapContinuity(bounds: bounds, minimumZoom: 2, maximumZoom: 8,
            policy: policy, loader: loader.load)
    }
    private func prepare(_ source: RasterMapContinuity, rect: MKMapRect, zoom: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            source.prepare(in: rect, zoom: zoom) { continuation.resume(returning: $0) }
        }
    }
    private enum WaitFailure: Error { case timedOut }
    private func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { XCTFail("Condition never became true"); throw WaitFailure.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func testNewViewportCancelsOldDetailWithoutPublishingItsLatePixels() async throws {
        let loader = Loader(); let budget = RasterImageBudget(limit: 8 * 1_024 * 1_024)
        let source = source(loader, budget: budget)
        let prepared = await prepare(source, rect: bounds, zoom: 3)
        XCTAssertTrue(prepared)
        let oldFrame = source.snapshot().detail?.id
        loader.hold()
        let obsolete = Task { await self.prepare(source, rect: self.rect(z: 5, x: 8, y: 8), zoom: 5) }
        try await until { loader.coordinates.contains(MBTilesTileCoordinate(z: 5, x: 8, y: 8)!) }
        let latest = Task { await self.prepare(source, rect: self.rect(z: 5, x: 9, y: 8), zoom: 5) }
        try await until { loader.coordinates.contains(MBTilesTileCoordinate(z: 5, x: 9, y: 8)!) }
        let obsoleteReady = await obsolete.value
        XCTAssertFalse(obsoleteReady)
        XCTAssertEqual(loader.cancelCount, 1)
        XCTAssertEqual(source.snapshot().detail?.id, oldFrame)
        loader.releaseCancelled()
        loader.releaseCurrent()
        let latestReady = await latest.value
        XCTAssertTrue(latestReady)
        XCTAssertEqual(source.snapshot().detail?.coordinates, [MBTilesTileCoordinate(z: 5, x: 9, y: 8)!])
        XCTAssertLessThanOrEqual(budget.usage.peak, budget.limit)
        source.invalidate()
    }

    func testLeavingCoverageCancelsAndReleasesLoadingFrameButKeepsDisplayedFrame() async throws {
        let loader = Loader(); let budget = RasterImageBudget(limit: 8 * 1_024 * 1_024)
        let source = source(loader, budget: budget)
        let prepared = await prepare(source, rect: bounds, zoom: 3)
        XCTAssertTrue(prepared)
        let displayed = source.snapshot()
        let baseline = budget.usage.current
        loader.hold()
        let obsolete = Task { await self.prepare(source, rect: self.rect(z: 5, x: 8, y: 8), zoom: 5) }
        try await until { !loader.coordinates.isEmpty }
        XCTAssertGreaterThan(budget.usage.current, baseline)
        let outsideReady = await prepare(source, rect: rect(z: 5, x: 0, y: 0), zoom: 5)
        XCTAssertTrue(outsideReady)
        let obsoleteReady = await obsolete.value
        XCTAssertFalse(obsoleteReady)
        try await until { budget.usage.current == baseline }
        XCTAssertEqual(source.snapshot().detail?.id, displayed.detail?.id)
        XCTAssertEqual(loader.cancelCount, 1)
        loader.releaseCancelled()
        source.invalidate()
    }

    func testGlobalOverviewSurvivesPanAndPreparesOnlyLatestDetail() async throws {
        let loader = Loader(); let budget = RasterImageBudget(limit: 8 * 1_024 * 1_024)
        let source = source(loader, budget: budget)
        loader.hold()
        let obsolete = Task { await self.prepare(source, rect: self.rect(z: 5, x: 8, y: 8), zoom: 5) }
        try await until { loader.coordinates == [MBTilesTileCoordinate(z: 2, x: 1, y: 1)!] }
        let latest = Task { await self.prepare(source, rect: self.rect(z: 5, x: 9, y: 8), zoom: 5) }
        let obsoleteReady = await obsolete.value
        XCTAssertFalse(obsoleteReady)
        XCTAssertEqual(loader.cancelCount, 0)
        XCTAssertEqual(loader.coordinates, [MBTilesTileCoordinate(z: 2, x: 1, y: 1)!])
        loader.releaseCurrent()
        let latestReady = await latest.value
        XCTAssertTrue(latestReady)
        XCTAssertNotNil(source.snapshot().overview)
        XCTAssertEqual(source.snapshot().detail?.coordinates, [MBTilesTileCoordinate(z: 5, x: 9, y: 8)!])
        source.invalidate()
    }

    func testDeinitAloneCancelsAndCompletesActiveAndPendingReadiness() async throws {
        // With no overview, readiness is queued behind the overview batch. With
        // an existing overview, readiness belongs to the active detail batch.
        for needsOverview in [true, false] {
            let loader = Loader(); let budget = RasterImageBudget(limit: 8 * 1_024 * 1_024)
            var source: RasterMapContinuity? = source(loader, budget: budget)
            if !needsOverview {
                let prepared = await prepare(source!, rect: bounds, zoom: 3)
                XCTAssertTrue(prepared)
            }
            loader.hold()
            let callback = expectation(description: needsOverview ? "queued deinit readiness" : "active deinit readiness")
            callback.assertForOverFulfill = true
            source?.prepare(in: rect(z: 5, x: 8, y: 8), zoom: 5) { ready in
                XCTAssertFalse(ready); callback.fulfill()
            }
            try await until { !loader.coordinates.isEmpty }
            XCTAssertGreaterThan(budget.usage.current, 0)
            weak var retired = source
            source = nil // Deliberately do not call invalidate().
            await fulfillment(of: [callback], timeout: 3)
            try await until { retired == nil && budget.usage.current == 0 }
            XCTAssertEqual(loader.cancelCount, 1)
            loader.releaseCancelled() // Late tile completion cannot deliver readiness again.
            XCTAssertEqual(budget.usage.current, 0)
        }
    }

    func testRetiringContinuityCancelsPendingLoadsAndCompletesReadinessOnce() async throws {
        let loader = Loader(); let budget = RasterImageBudget(limit: 8 * 1_024 * 1_024)
        var source: RasterMapContinuity? = source(loader, budget: budget)
        loader.hold()
        let callback = expectation(description: "retired readiness"); callback.assertForOverFulfill = true
        source?.prepare(in: bounds, zoom: 3) { ready in
            XCTAssertFalse(ready); callback.fulfill()
        }
        try await until { !loader.coordinates.isEmpty }
        source?.invalidate()
        await fulfillment(of: [callback], timeout: 3)
        loader.releaseCancelled()
        source = nil
        try await until { budget.usage.current == 0 }
        XCTAssertGreaterThanOrEqual(loader.cancelCount, 1)
    }
}
