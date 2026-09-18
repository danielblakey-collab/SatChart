import XCTest
import MapKit
@testable import SatChart

@MainActor
final class OnlineDistrictDiscoveryTests: XCTestCase {
    nonisolated final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        var available: Set<String> = []
        var unavailable = false
        private(set) var requests: [URL] = []
        private(set) var peak = 0
        private var active = 0
        func set(_ prefixes: Set<String>, unavailable: Bool = false) {
            lock.lock(); self.available = prefixes; self.unavailable = unavailable; lock.unlock()
        }
        func begin(_ url: URL) -> OnlineDistrictMapAvailability.ProbeResult {
            lock.lock(); defer { lock.unlock() }
            requests.append(url); active += 1; peak = max(peak, active)
            if unavailable { return .unavailable }
            return available.contains(url.pathComponents[1]) ? .present : .missing
        }
        func end() { lock.lock(); active -= 1; lock.unlock() }
        func load(_ url: URL) async -> OnlineDistrictMapAvailability.ProbeResult {
            let result = begin(url)
            try? await Task.sleep(for: .milliseconds(1))
            end()
            return result
        }
    }

    private func defaults() -> UserDefaults {
        let name = "district-discovery-\(UUID())"
        let result = UserDefaults(suiteName: name)!
        addTeardownBlock { result.removePersistentDomain(forName: name) }
        return result
    }
    private func finish(_ store: OnlineDistrictMapAvailability) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isRefreshing && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isRefreshing)
    }

    func testAllDistrictsAcceptOneThroughFifteenWithSparseCoarseTiles() {
        for district in DistrictID.allCases {
            XCTAssertEqual(district.supportedLocalMapPacks.count, 15)
            for version in 1...15 {
                let candidates = OnlineDistrictMapCatalog.candidates(district: district, version: version)
                XCTAssertEqual(candidates.count, (version == 1 ? 2 : 1) * (district == .naknek_kvichak ? 2 : 1))
                for source in candidates {
                    XCTAssertEqual(source.version, version)
                    let urls = OnlineDistrictMapCatalog.discoveryURLs(for: source)
                    XCTAssertFalse(urls.isEmpty); XCTAssertLessThanOrEqual(urls.count, 2)
                    XCTAssertTrue(urls.allSatisfy { $0.path.contains("/4/") && $0.pathExtension == "png" })
                    XCTAssertEqual(source.minimumZoom, 4); XCTAssertEqual(source.maximumZoom, 15)
                    XCTAssertTrue(source.bounds.size.width > 0 && source.bounds.size.height > 0)
                }
            }
        }
        XCTAssertNil(DistrictID.egegik.mapVersion(forPackSlug: "egegik_v16"))
        let sources = DistrictID.allCases.map { OnlineDistrictMapCatalog.map(district: $0, version: 15) }
        XCTAssertEqual(OnlineDistrictMapCatalog.selectedMaps(version: 15, in: sources).count, 5)
        XCTAssertEqual(Set(sources.map { $0.cacheKey(for: MKTileOverlayPath(x: 1, y: 4, z: 4, contentScaleFactor: 1)) }).count, 5)
    }

    func testNewVersionsAndV1AliasesAreDiscoveredWithOnlyTwoWorkers() async throws {
        let probe = Probe()
        probe.set(["egegik_v15_xyz", "ugashik_v1_xyz", "togiak_xyz", "nushagak_v12_xyz", "naknek_kvichak_v8_xyz"])
        let store = OnlineDistrictMapAvailability(defaults: defaults(), initialMaps: [], probe: probe.load)
        store.refreshIfNeeded(); store.refreshIfNeeded(force: true)
        try await finish(store)
        XCTAssertEqual(Set(store.maps.map(\.tilePrefix)), probe.available)
        XCTAssertEqual(probe.peak, 2)
        XCTAssertLessThanOrEqual(probe.requests.count, 192)
        XCTAssertTrue(probe.requests.allSatisfy {
            $0.scheme == "https" && $0.host == OnlineTileDelivery.baseURL.host
        })
        XCTAssertEqual(OnlineDistrictMapCatalog.versions(in: store.maps), [1, 8, 12, 15])
        XCTAssertEqual(OnlineDistrictMapCatalog.nextVersion(after: 15, in: store.maps), 1)
        XCTAssertEqual(OnlineDistrictMapCatalog.selectedMaps(version: 15, in: store.maps).count, 5)
        let count = probe.requests.count
        store.refreshIfNeeded()
        XCTAssertEqual(probe.requests.count, count)
        XCTAssertFalse(store.isRefreshing)
    }

    func testNaknekShortPrefixesDiscoverAllVersionsAndRestoreWithoutDuplicates() async throws {
        let preferences = defaults(); let probe = Probe()
        let aliases = Set((1...15).map { "naknek_v\($0)_xyz" })
        probe.set(aliases.union(["naknek_kvichak_v4_xyz"]))
        let store = OnlineDistrictMapAvailability(defaults: preferences, initialMaps: [], probe: probe.load)
        store.refreshIfNeeded(); try await finish(store)
        XCTAssertEqual(store.maps.count, 15)
        XCTAssertEqual(Set(store.maps.map(\.pack.slug)), Set((1...15).map {
            DistrictID.naknek_kvichak.packSlug(forVersion: $0)
        }))
        XCTAssertEqual(store.maps.first { $0.version == 3 }?.tilePrefix, "naknek_v3_xyz")
        XCTAssertEqual(store.maps.first { $0.version == 4 }?.tilePrefix, "naknek_kvichak_v4_xyz")
        let restored = OnlineDistrictMapAvailability(defaults: preferences, initialMaps: [], probe: probe.load)
        XCTAssertEqual(restored.maps, store.maps)
        probe.set(aliases.union(["naknek_kvichak_v3_xyz", "naknek_kvichak_v4_xyz"]))
        restored.refreshIfNeeded(force: true); try await finish(restored)
        XCTAssertEqual(restored.maps, store.maps, "An already selected prefix remains preferred when both exist")
        XCTAssertEqual(probe.peak, 2)
    }

    func testSparseProbeCanFindSecondTileAndNoDataBodyIsRequired() async throws {
        let source = OnlineDistrictMapCatalog.map(district: .egegik, version: 15)
        let urls = OnlineDistrictMapCatalog.discoveryURLs(for: source)
        XCTAssertEqual(urls.count, 2)
        let valid = try XCTUnwrap(urls.last)
        let store = OnlineDistrictMapAvailability(defaults: defaults(), initialMaps: [], probe: {
            $0 == valid ? .present : .missing
        })
        store.refreshIfNeeded(); try await finish(store)
        XCTAssertEqual(store.maps.map(\.pack.slug), ["egegik_v15"])
        for (code, mime, length, expected) in [(200, "image/png", "100", "present"),
                                             (200, "text/html", "100", "unavailable"),
                                             (200, "image/png", "0", "unavailable"),
                                             (403, "text/plain", "12", "unavailable"),
                                             (429, "text/plain", "12", "unavailable"),
                                             (500, "text/plain", "12", "unavailable"),
                                             (404, "text/plain", "12", "missing"),
                                             (410, "text/plain", "12", "missing")] {
            let response = HTTPURLResponse(url: valid, statusCode: code, httpVersion: nil,
                                            headerFields: ["Content-Type": mime, "Content-Length": length])!
            XCTAssertEqual(String(describing: OnlineDistrictMapAvailability.classify(response)), expected)
        }
    }

    func testCacheSurvivesOfflineAndConfirmedRemovalSelectsFallback() async throws {
        let preferences = defaults(); let probe = Probe()
        probe.set(["egegik_v4_xyz", "egegik_v15_xyz", "ugashik_v6_xyz"])
        let store = OnlineDistrictMapAvailability(defaults: preferences, initialMaps: [], probe: probe.load)
        store.refreshIfNeeded(); try await finish(store)
        let restored = OnlineDistrictMapAvailability(defaults: preferences, initialMaps: [], probe: probe.load)
        XCTAssertEqual(restored.maps, store.maps)
        probe.set([], unavailable: true)
        restored.refreshIfNeeded(force: true); try await finish(restored)
        XCTAssertEqual(restored.maps, store.maps)
        probe.set(["egegik_v4_xyz", "ugashik_v6_xyz"])
        restored.refreshIfNeeded(force: true); try await finish(restored)
        XCTAssertEqual(Set(restored.maps.map(\.pack.slug)), ["egegik_v4", "ugashik_v6"])
        XCTAssertEqual(Set(OnlineDistrictMapCatalog.selectedMaps(version: 15, in: restored.maps).map(\.pack.slug)),
                       ["egegik_v4", "ugashik_v6"])
    }

    func testCancelledDiscoveryCannotPublishLateResults() async throws {
        let probe = Probe(); probe.set(["togiak_v15_xyz"])
        let store = OnlineDistrictMapAvailability(defaults: defaults(), initialMaps: [], probe: probe.load)
        store.refreshIfNeeded(); store.cancelRefresh()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(store.maps.isEmpty); XCTAssertFalse(store.isRefreshing)
        store.refreshIfNeeded(force: true); try await finish(store)
        XCTAssertEqual(store.maps.map(\.pack.slug), ["togiak_v15"])
    }
}

@MainActor
final class OnlineDistrictMultiMapTests: XCTestCase {
    private static var retainedMaps: [MKMapView] = []

    func testFiveDistrictsUseSeparatePyramidsAndRetainRendererDuringVersionFifteenHandoff() async throws {
        let coordinator = MapViewRepresentable.Coordinator(
            minZForTiles: 4, maxZ: 15, maxZForTiles: 15,
            extendedOfflineMaxZ: 17, extendedOfflineMaxZForTiles: 17,
            initialLaunchZoom: 12, initialCursorTrackingUser: true,
            onDistanceText: { _ in }, onSpeedText: { _ in }, onMetersPerPoint: { _ in },
            onFollowStateChanged: { _ in }, onCursorUpdated: { _, _, _ in },
            onCursorTrackingStateChanged: { _ in }, onFishingSetDisplayPrompt: { _ in })
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let tile = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).pngData {
            UIColor.red.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        coordinator.availableOnlineDistrictMaps = DistrictID.allCases.flatMap { district in
            [1, 15].map { OnlineDistrictMapCatalog.map(district: district, version: $0) }
        }
        coordinator.onlineDistrictOverlayFactory = { source in
            OnlineDistrictTileOverlay(source: source) { _, _, completion in completion(tile, nil) }
        }
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 810, height: 1080))
        Self.retainedMaps.append(map)
        coordinator.mapView = map
        coordinator.basemapChoice = .districtsOnline
        coordinator.currentSelectedMapVersion = 1
        map.setVisibleMapRect(OnlineDistrictMapCatalog.bounds(for: .egegik), animated: false)
        coordinator.syncBasemap(on: map)
        defer { coordinator.prepareForDismantle() }
        let overlays = map.overlays.compactMap { $0 as? OnlineDistrictTileOverlay }
        XCTAssertEqual(overlays.count, 5)
        XCTAssertEqual(Set(overlays.map { $0.source.tilePrefix }), Set(DistrictID.allCases.map { "\($0.rawValue)_xyz" }))
        let egegik = try XCTUnwrap(overlays.first { $0.source.pack.district == .egegik })
        let renderer = try XCTUnwrap(coordinator.mapView(map, rendererFor: egegik) as? RasterContinuityRenderer)
        let ready = await withCheckedContinuation { callback in
            egegik.continuity.prepare(in: map.visibleMapRect, zoom: 12) { callback.resume(returning: $0) }
        }
        XCTAssertTrue(ready)
        coordinator.currentSelectedMapVersion = 15
        coordinator.syncBasemap(on: map)
        let deadline = Date().addingTimeInterval(8)
        while egegik.source.version != 15 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(egegik.source.version, 15)
        XCTAssertTrue(coordinator.mapView(map, rendererFor: egegik) === renderer)
        XCTAssertEqual(map.overlays.compactMap { $0 as? OnlineDistrictTileOverlay }.count, 5)
        XCTAssertFalse(egegik.continuity.snapshot().detail?.images.isEmpty ?? true)
        XCTAssertLessThanOrEqual(OnlineDistrictTileOverlay.imageBudget.usage.current, 32 * 1024 * 1024)
        map.setVisibleMapRect(OnlineDistrictMapCatalog.bounds(for: .ugashik), animated: false)
        coordinator.syncBasemap(on: map)
        for _ in 0..<100 where egegik.continuity.snapshot().isReady { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(egegik.continuity.snapshot().isReady, "Leaving a district must release its retained pixels")
        XCTAssertEqual(map.overlays.compactMap { $0 as? OnlineDistrictTileOverlay }.count, 5)
    }

    func testAllFiveDistrictsShareOneImageBudget() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let tile = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).pngData {
            UIColor.blue.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        let overlays = DistrictID.allCases.map { district in
            OnlineDistrictTileOverlay(source: OnlineDistrictMapCatalog.map(district: district, version: 15)) {
                _, _, completion in completion(tile, nil)
            }
        }
        defer { overlays.forEach { $0.continuity.invalidate() } }
        for overlay in overlays {
            let ready = await withCheckedContinuation { callback in
                overlay.continuity.prepare(in: overlay.source.bounds, zoom: 15) { callback.resume(returning: $0) }
            }
            XCTAssertTrue(ready)
            XCTAssertFalse(overlay.continuity.snapshot().detail?.images.isEmpty ?? true)
            XCTAssertLessThanOrEqual(OnlineDistrictTileOverlay.imageBudget.usage.current, 32 * 1024 * 1024)
        }
        print("FIVE_DISTRICT_IMAGE_BUDGET", OnlineDistrictTileOverlay.imageBudget.usage.current)
    }
}
