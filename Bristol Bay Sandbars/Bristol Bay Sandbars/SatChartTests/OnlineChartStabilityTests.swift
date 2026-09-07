import XCTest
import MapKit
@testable import SatChart

nonisolated final class ChartProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var status = 200; var type = "image/png"; var data = Data(); var delay = 0.0 }
    private static let lock = NSLock()
    private static var handler: ((URL) -> Reply)?
    private static var requests: [URL] = []
    private static var running = 0
    private static var peak = 0
    private var stopped = false
    static func reset(_ handler: @escaping (URL) -> Reply) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler; requests = []; running = 0; peak = 0
    }
    static var observations: (urls: [URL], peak: Int) {
        lock.lock(); defer { lock.unlock() }
        return (requests, peak)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.running += 1; Self.peak = max(Self.peak, Self.running)
        Self.requests.append(request.url!)
        let reply = Self.handler!(request.url!)
        Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            Self.lock.lock()
            let cancelled = stopped
            if !cancelled { stopped = true; Self.running -= 1 }
            Self.lock.unlock()
            guard !cancelled else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status,
                httpVersion: nil, headerFields: ["Content-Type": reply.type])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if !stopped { stopped = true; Self.running -= 1 }
    }
}

@MainActor
final class OnlineChartStabilityTests: XCTestCase {
    private var stores: [OnlineChartTileStore] = []
    private var directories: [URL] = []
    override func tearDown() {
        stores.forEach { $0.shutdown() }
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        stores = []; directories = []
        super.tearDown()
    }
    private func store(pixels: Int = 256) -> OnlineChartTileStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChartProtocol.self]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chart-test-\(UUID())")
        directories.append(dir)
        let store = OnlineChartTileStore(configuration: config, directory: dir, pixelSize: pixels, imageByteLimit: OnlineChartTileStore.imageLimit, observeSystem: false)
        stores.append(store)
        return store
    }
    private func png(side: Int = 256, transparent: Bool = false) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).pngData {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: transparent ? side / 2 : side, height: side))
        }
    }
    private func load(_ store: OnlineChartTileStore, source: OnlineChartSource = .noaa,
                      tile: MBTilesTileCoordinate, owner: UUID = UUID()) async -> MBTilesBackstopLoadOutcome {
        await withCheckedContinuation { continuation in
            store.load(source: source, tile: tile, owner: owner) { continuation.resume(returning: $0) }
        }
    }
    private func prepare(_ continuity: RasterMapContinuity, rect: MKMapRect, zoom: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            continuity.prepare(in: rect, zoom: zoom) { continuation.resume(returning: $0) }
        }
    }
    private func isImage(_ outcome: MBTilesBackstopLoadOutcome) -> Bool {
        if case .image = outcome { return true }; return false
    }

    func testSourcesUseCachedXYZRowsAndScaleCorrectExports() throws {
        let tile = try XCTUnwrap(MBTilesTileCoordinate(z: 15, x: 2052, y: 9826))
        XCTAssertTrue(OnlineChartSource.usgs.cachedURL(tile).path.hasSuffix("/tile/15/9826/2052"))
        for pixels in [256, 512] {
            let url = OnlineChartSource.noaa.exportURL(tile, pixels: pixels)
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
                .queryItems!.map { ($0.name, $0.value!) })
            XCTAssertEqual(query["size"], "\(pixels),\(pixels)")
            XCTAssertEqual(query["dpi"], "\(96 * pixels / 256)")
            XCTAssertEqual(query["transparent"], "true")
            XCTAssertNotEqual(OnlineChartSource.noaa.key(tile, pixels: pixels), OnlineChartSource.usgs.key(tile, pixels: pixels))
        }
    }

    func testUSGSMissingCacheFallsBackToExportAndCachesTheResult() async throws {
        let bytes = png()
        ChartProtocol.reset { url in
            url.path.contains("/tile/") ? .init(status: 404) : .init(data: bytes)
        }
        let store = store()
        let tile = try XCTUnwrap(MBTilesTileCoordinate(z: 17, x: 8210, y: 39305))
        let first = await load(store, source: .usgs, tile: tile)
        let second = await load(store, source: .usgs, tile: tile)
        XCTAssertTrue(isImage(first)); XCTAssertTrue(isImage(second))
        let urls = ChartProtocol.observations.urls
        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls[0].path.contains("/tile/")); XCTAssertTrue(urls[1].path.hasSuffix("/export"))
    }

    func testDuplicateRequestsCoalesceAndNetworkWorkStaysSerial() async throws {
        let bytes = png()
        ChartProtocol.reset { _ in .init(data: bytes, delay: 0.05) }
        let store = store()
        let tile = try XCTUnwrap(MBTilesTileCoordinate(z: 8, x: 16, y: 76))
        let done = expectation(description: "Every coalesced caller completes")
        done.expectedFulfillmentCount = 12
        for _ in 0..<12 {
            store.load(source: .noaa, tile: tile, owner: UUID()) { outcome in
                if case .image = outcome {} else { XCTFail("Missing coalesced image") }
                done.fulfill()
            }
        }
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(ChartProtocol.observations.urls.count, 1)
        XCTAssertEqual(ChartProtocol.observations.peak, 1)
    }

    func testOversizedAndErrorResponsesAreNotCachedAsBlankCharts() async throws {
        let store = store()
        let tile = try XCTUnwrap(MBTilesTileCoordinate(z: 8, x: 16, y: 76))
        ChartProtocol.reset { _ in .init(data: Data(repeating: 0, count: OnlineChartTileStore.payloadLimit + 1)) }
        let tooLarge = await load(store, tile: tile)
        if case .transientFailure = tooLarge {} else { XCTFail("Oversized response was admitted") }
        ChartProtocol.reset { _ in .init(type: "application/json", data: Data("{\"error\":500}".utf8)) }
        let error = await load(store, tile: tile)
        if case .transientFailure = error {} else { XCTFail("Service error became a chart") }
        let bytes = png()
        ChartProtocol.reset { _ in .init(data: bytes) }
        let recovered = await load(store, tile: tile)
        XCTAssertTrue(isImage(recovered))
        XCTAssertEqual(ChartProtocol.observations.urls.count, 1)
    }

    func testCancelledOwnerCompletesOnceAndNewViewportDoesNotWaitForIt() async throws {
        let bytes = png()
        ChartProtocol.reset { _ in .init(data: bytes, delay: 0.3) }
        let store = store()
        let owner = UUID()
        let tile = try XCTUnwrap(MBTilesTileCoordinate(z: 8, x: 16, y: 76))
        let cancelled = expectation(description: "Cancelled once")
        cancelled.assertForOverFulfill = true
        store.load(source: .noaa, tile: tile, owner: owner) { outcome in
            if case .cancelled = outcome {} else { XCTFail("Obsolete owner received an image") }
            cancelled.fulfill()
        }
        try await Task.sleep(for: .milliseconds(20))
        store.cancel(owner: owner)
        let fresh = await load(store, tile: tile)
        XCTAssertTrue(isImage(fresh))
        await fulfillment(of: [cancelled], timeout: 1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(ChartProtocol.observations.peak, 1)
    }

    func testDiskCacheExpiresNOAAExports() async throws {
        let bytes = png()
        ChartProtocol.reset { _ in .init(data: bytes) }
        let store = store()
        let tile = try XCTUnwrap(MBTilesTileCoordinate(z: 8, x: 16, y: 76))
        let first = await load(store, tile: tile)
        XCTAssertTrue(isImage(first))
        store.purge(suspend: false) // Clears only memory, so next read exercises disk.
        let cached = await load(store, tile: tile)
        XCTAssertTrue(isImage(cached)); XCTAssertEqual(ChartProtocol.observations.urls.count, 1)
        store.purge(suspend: false)
        let files = try FileManager.default.contentsOfDirectory(at: directories[0], includingPropertiesForKeys: nil)
        for file in files {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7 * 3_600)], ofItemAtPath: file.path)
        }
        let refreshed = await load(store, tile: tile)
        XCTAssertTrue(isImage(refreshed)); XCTAssertEqual(ChartProtocol.observations.urls.count, 2)
    }

    func testImageReservationsIncludeFrozenFramesAndRefuseOverBudgetAdmission() {
        let budget = RasterImageBudget(limit: 1_024)
        var current = budget.reserve(768)
        var frozen = current
        current = nil
        XCTAssertEqual(budget.usage.current, 768)
        XCTAssertNil(budget.reserve(512))
        XCTAssertNotNil(frozen)
        frozen = nil
        XCTAssertEqual(budget.usage.current, 0)
        XCTAssertNotNil(budget.reserve(1_024))
        XCTAssertEqual(budget.usage.peak, 1_024)
    }

    func testLocalFallbackAndRapidViewportChangesStayInsideSharedImageBudget() async throws {
        let bytes = png()
        ChartProtocol.reset { _ in .init(data: bytes) }
        let store = store()
        let overlay = NOAAOnlineTileOverlay(store: store)
        let renderer = RasterContinuityRenderer(overlay: overlay, continuity: overlay.continuity)
        defer { overlay.stopLoading() }
        let footprint = try XCTUnwrap(MBTilesTileCoordinate(z: 11, x: 127, y: 614))
        let tileRect = MBTilesViewportTilePlanner.mapRect(for: footprint)
        for n in 0..<12 {
            let rect = tileRect.offsetBy(dx: Double(n % 3) * tileRect.width / 8, dy: 0)
            if n == 3 { renderer.setCameraMovementActive(true) }
            if n == 7 { renderer.setCameraMovementActive(false) }
            let ready = await prepare(overlay.continuity, rect: rect, zoom: 13 + n % 2)
            XCTAssertTrue(ready)
            let snapshot = overlay.continuity.snapshot()
            let overview = try XCTUnwrap(snapshot.overview)
            XCTAssertLessThan(overview.mapRect.width, MKMapSize.world.width / 100,
                              "Charts must not fetch a world overview")
            XCTAssertTrue(renderer.canDraw(rect, zoomScale: 1))
            XCTAssertLessThanOrEqual(store.imageBudget.usage.current, store.imageBudget.limit)
        }
        renderer.setCameraMovementActive(false)
        XCTAssertLessThanOrEqual(store.imageBudget.usage.peak, store.imageBudget.limit)
        print("ONLINE_CHART_IMAGE_BUDGET", store.imageBudget.usage.peak, "/", store.imageBudget.limit)
    }

    private static var retainedMaps: [MKMapView] = []
    private func coordinator(using store: OnlineChartTileStore) -> (MapViewRepresentable.Coordinator, MKMapView) {
        let coordinator = MapViewRepresentable.Coordinator(
            minZForTiles: 4, maxZ: 15, maxZForTiles: 15,
            extendedOfflineMaxZ: 17, extendedOfflineMaxZForTiles: 17,
            initialLaunchZoom: 12, initialCursorTrackingUser: true,
            onDistanceText: { _ in }, onSpeedText: { _ in }, onMetersPerPoint: { _ in },
            onFollowStateChanged: { _ in }, onCursorUpdated: { _, _, _ in },
            onCursorTrackingStateChanged: { _ in }, onFishingSetDisplayPrompt: { _ in })
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 810, height: 1080))
        Self.retainedMaps.append(map)
        map.setVisibleMapRect(OnlineDistrictMapCatalog.maps[0].bounds, animated: false)
        coordinator.mapView = map
        coordinator.onlineChartOverlayFactory = { OnlineChartOverlay(source: $0, store: store) }
        return (coordinator, map)
    }
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Chart lifecycle operation did not complete")
    }

    func testServiceSwitchKeepsReadyPredecessorThenReleasesItsImages() async throws {
        let bytes = png()
        ChartProtocol.reset { url in .init(data: bytes, delay: url.host!.contains("usgs") || url.host!.contains("nationalmap") ? 0.01 : 0) }
        let store = store()
        let (coordinator, map) = coordinator(using: store)
        defer { coordinator.prepareForDismantle() }
        coordinator.basemapChoice = .noaaOnline
        coordinator.syncBasemap(on: map)
        let previous = try XCTUnwrap(map.overlays.compactMap { $0 as? OnlineChartOverlay }.first)
        let oldReady = await prepare(previous.continuity, rect: map.visibleMapRect, zoom: 12)
        XCTAssertTrue(oldReady)
        coordinator.basemapChoice = .topoOnline
        coordinator.syncBasemap(on: map)
        XCTAssertEqual(map.overlays.compactMap { $0 as? OnlineChartOverlay }.count, 2)
        XCTAssertTrue(previous.continuity.snapshot().isReady)
        try await until { map.overlays.compactMap { $0 as? OnlineChartOverlay }.count == 1 }
        let current = try XCTUnwrap(map.overlays.compactMap { $0 as? OnlineChartOverlay }.first)
        XCTAssertEqual(current.source, .usgs)
        XCTAssertTrue(current.continuity.snapshot().isReady)
        try await until { !previous.continuity.snapshot().isReady }
        coordinator.basemapChoice = .appleSatellite
        coordinator.syncBasemap(on: map)
        try await until { store.imageBudget.usage.current == 0 }
    }

    func testLeavingChartModeCancelsColdLoadsWithoutResurrectingTheOverlay() async throws {
        let bytes = png()
        ChartProtocol.reset { _ in .init(data: bytes, delay: 0.2) }
        let store = store()
        let (coordinator, map) = coordinator(using: store)
        defer { coordinator.prepareForDismantle() }
        coordinator.basemapChoice = .noaaOnline
        coordinator.syncBasemap(on: map)
        let overlay = try XCTUnwrap(map.overlays.compactMap { $0 as? OnlineChartOverlay }.first)
        _ = coordinator.mapView(map, rendererFor: overlay)
        try await Task.sleep(for: .milliseconds(20))
        coordinator.basemapChoice = .appleSatellite
        coordinator.syncBasemap(on: map)
        try await until { store.imageBudget.usage.current == 0 }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(map.overlays.isEmpty)
        XCTAssertFalse(overlay.continuity.snapshot().isReady)
    }

    func testLatestViewportDiscardsAnObsoleteLoadingBatch() async throws {
        let bytes = png()
        ChartProtocol.reset { _ in .init(data: bytes, delay: 0.01) }
        let store = store()
        let overlay = NOAAOnlineTileOverlay(store: store)
        defer { overlay.stopLoading() }
        let a = MBTilesViewportTilePlanner.mapRect(for: try XCTUnwrap(MBTilesTileCoordinate(z: 12, x: 254, y: 1228)))
        let b = a.offsetBy(dx: a.width * 100, dy: 0)
        let superseded = expectation(description: "Obsolete batch completes once")
        superseded.assertForOverFulfill = true
        overlay.continuity.prepare(in: a, zoom: 13) { ready in
            XCTAssertFalse(ready); superseded.fulfill()
        }
        try await Task.sleep(for: .milliseconds(2))
        let ready = await prepare(overlay.continuity, rect: b, zoom: 13)
        XCTAssertTrue(ready)
        await fulfillment(of: [superseded], timeout: 2)
        let frame = try XCTUnwrap(overlay.continuity.snapshot().detail)
        XCTAssertTrue(frame.mapRect.contains(b))
        XCTAssertFalse(frame.mapRect.intersects(a))
    }

    func testMemoryPurgeCancelsTheRestOfTheBatchBeforeRetrying() async throws {
        let bytes = png()
        ChartProtocol.reset { _ in .init(data: bytes, delay: 0.2) }
        let store = store()
        let overlay = NOAAOnlineTileOverlay(store: store)
        defer { overlay.stopLoading() }
        let done = expectation(description: "Purged batch completes")
        overlay.continuity.prepare(in: OnlineDistrictMapCatalog.maps[0].bounds, zoom: 13) { ready in
            XCTAssertFalse(ready); done.fulfill()
        }
        try await until { !ChartProtocol.observations.urls.isEmpty }
        store.purge(suspend: false)
        await fulfillment(of: [done], timeout: 1)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(ChartProtocol.observations.urls.count, 1, "A purge must not immediately refill its queue")
        XCTAssertEqual(store.imageBudget.usage.current, 0)
    }

    func testDecoderPreservesAlphaAndBoundsRetinaImageAllocation() throws {
        let bytes = png(side: 512, transparent: true)
        let image = try XCTUnwrap(OnlineChartTileStore.decode(bytes, maximumSide: 256))
        XCTAssertEqual(image.width, 256); XCTAssertEqual(image.height, 256)
        XCTAssertEqual(image.bytesPerRow * image.height, 256 * 256 * 4)
        let data = try XCTUnwrap(image.dataProvider?.data)
        let pointer = CFDataGetBytePtr(data)!
        XCTAssertEqual(pointer[128 * image.bytesPerRow + 200 * 4 + 3], 0)
        XCTAssertEqual(pointer[128 * image.bytesPerRow + 50 * 4 + 3], 255)
    }
}
