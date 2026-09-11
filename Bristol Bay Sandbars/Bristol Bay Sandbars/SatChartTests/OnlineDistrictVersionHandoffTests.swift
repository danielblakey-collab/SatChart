import XCTest
import MapKit
@testable import SatChart

@MainActor
final class OnlineDistrictVersionHandoffTests: XCTestCase {
    nonisolated private final class Network: @unchecked Sendable {
        enum Mode { case ready, held, failed, missing }
        private struct Request {
            let version: Int
            let data: Data?
            let completion: (Data?, Error?) -> Void
        }
        private let lock = NSLock()
        private let tiles: [String: Data]
        private var modes: [Int: Mode] = [:]
        private var pending: [Request] = []
        private var requestedVersions: [Int] = []

        init(tiles: [String: Data]) { self.tiles = tiles }
        func set(_ mode: Mode, version: Int) { lock.lock(); modes[version] = mode; lock.unlock() }
        func requestCount(version: Int) -> Int {
            lock.lock(); defer { lock.unlock() }
            return requestedVersions.filter { $0 == version }.count
        }
        func load(url: URL, key: String, completion: @escaping (Data?, Error?) -> Void) {
            let version = Int(url.pathComponents.first(where: { $0.hasPrefix("egegik_v") })!
                .replacingOccurrences(of: "egegik_v", with: "").replacingOccurrences(of: "_xyz", with: ""))!
            let tileName = url.pathComponents.suffix(3).joined(separator: "-")
            let data = tiles["v\(version)/\(tileName)"] ?? tiles[tileName]
            lock.lock()
            requestedVersions.append(version)
            let mode = modes[version] ?? .ready
            if mode == .held {
                pending.append(Request(version: version, data: data, completion: completion))
                lock.unlock()
                return
            }
            lock.unlock()
            switch mode {
            case .ready: completion(data, nil)
            case .failed: completion(nil, URLError(.timedOut))
            case .missing: completion(nil, BristolBaySatelliteTileStoreError.notFound)
            case .held: break
            }
        }
        func release(version: Int) {
            lock.lock()
            modes[version] = .ready
            let callbacks = pending.filter { $0.version == version }
            pending.removeAll { $0.version == version }
            lock.unlock()
            callbacks.forEach { $0.completion($0.data, nil) }
        }
    }
    private struct Harness {
        let coordinator: MapViewRepresentable.Coordinator
        let map: MKMapView
        let network: Network
        let overlay: OnlineDistrictTileOverlay
        let renderer: RasterContinuityRenderer
    }
    private static var retainedMaps: [MKMapView] = []

    private func makeHarness(live: Bool = false) async throws -> Harness {
        let bundle = Bundle(for: Self.self)
        var tiles: [String: Data] = [:]
        for url in bundle.urls(forResourcesWithExtension: "png", subdirectory: nil) ?? [] {
            for version in [4, 5] {
                let prefix = "egegik-v\(version)-xyz-"
                guard url.lastPathComponent.hasPrefix(prefix) else { continue }
                let key = (version == 5 ? "v5/" : "") + String(url.lastPathComponent.dropFirst(prefix.count))
                tiles[key] = try Data(contentsOf: url)
            }
        }
        XCTAssertEqual(tiles.count, 29)
        let network = Network(tiles: tiles)
        let coordinator = MapViewRepresentable.Coordinator(
            minZForTiles: 4, maxZ: 15, maxZForTiles: 15,
            extendedOfflineMaxZ: 17, extendedOfflineMaxZForTiles: 17,
            initialLaunchZoom: 12, initialCursorTrackingUser: true,
            onDistanceText: { _ in }, onSpeedText: { _ in }, onMetersPerPoint: { _ in },
            onFollowStateChanged: { _ in }, onCursorUpdated: { _, _, _ in },
            onCursorTrackingStateChanged: { _ in }, onFishingSetDisplayPrompt: { _ in }
        )
        coordinator.availableOnlineDistrictMaps = OnlineDistrictMapCatalog.maps.filter { $0.pack.district == .egegik && $0.version >= 4 }
        coordinator.onlineDistrictOverlayFactory = { source in
            let fixture = OnlineDistrictMap(pack: source.pack, minimumZoom: 11,
                                            maximumZoom: source.version == 5 ? 11 : 12, bounds: source.bounds)
            return OnlineDistrictTileOverlay(source: fixture, tileLoader: network.load)
        }
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 810, height: 1080))
        Self.retainedMaps.append(map)
        map.setVisibleMapRect(OnlineDistrictMapCatalog.maps[0].bounds, animated: false)
        coordinator.mapView = map
        if live {
            let delegate = LiveDelegate(coordinator)
            Self.retainedLiveDelegates.append(delegate)
            // MapKit asks for renderers when overlays are attached; configure
            // the delegate before syncBasemap installs the first version.
            map.delegate = delegate
        }
        coordinator.basemapChoice = .districtsOnline
        coordinator.currentSelectedMapVersion = 4
        coordinator.syncBasemap(on: map)
        let overlay = try XCTUnwrap(map.overlays.compactMap { $0 as? OnlineDistrictTileOverlay }.first)
        let renderer = try XCTUnwrap(coordinator.mapView(map, rendererFor: overlay) as? RasterContinuityRenderer)
        let ready = await withCheckedContinuation { continuation in
            overlay.continuity.prepare(in: map.visibleMapRect, zoom: 11) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(ready)
        return Harness(coordinator: coordinator, map: map, network: network, overlay: overlay, renderer: renderer)
    }

    private func select(_ version: Int, in h: Harness) {
        h.coordinator.currentSelectedMapVersion = version
        h.coordinator.syncBasemap(on: h.map)
    }
    private func waitUntil(_ condition: () -> Bool, seconds: Double = 4) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Asynchronous version transition did not finish")
    }

    private final class BackingRenderer: MKOverlayRenderer {
        override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
            context.setFillColor(UIColor.green.cgColor)
            context.fill(rect(for: mapRect))
        }
    }
    private final class LiveDelegate: NSObject, MKMapViewDelegate {
        let coordinator: MapViewRepresentable.Coordinator
        init(_ coordinator: MapViewRepresentable.Coordinator) { self.coordinator = coordinator }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if overlay is BristolBaySatelliteTileOverlay { return BackingRenderer(overlay: overlay) }
            return coordinator.mapView(mapView, rendererFor: overlay)
        }
    }
    private static var retainedWindows: [UIWindow] = []
    private static var retainedLiveDelegates: [LiveDelegate] = []

    func testLiveMapKitSwitchesRealVersionsWithoutExposingBackingPixels() async throws {
        let h = try await makeHarness(live: true)
        defer { h.coordinator.prepareForDismantle() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        Self.retainedWindows.append(window)
        let controller = UIViewController()
        controller.view = h.map
        window.rootViewController = controller
        window.windowLevel = .normal + 1
        h.map.showsCompass = false
        h.map.pointOfInterestFilter = .excludingAll
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKey?.makeKey(); h.map.delegate = nil }
        try await Task.sleep(for: .seconds(2))
        let layerIDs = h.map.overlays.map { ObjectIdentifier($0) }
        let artwork = CLLocationCoordinate2D(latitude: 58.25, longitude: -157.6)
        let shore = CLLocationCoordinate2D(latitude: 58.25, longitude: -157.4)
        var badFrames = 0
        var frames = 0
        var verifiedFrames = 0
        let originalSource = h.overlay.continuity
        for version in [5, 4, 5, 4] {
            let before = h.network.requestCount(version: version)
            let displayedVersion = h.overlay.source.version
            h.network.set(.held, version: version)
            select(version, in: h)
            try await waitUntil { h.network.requestCount(version: version) > before }
            for sample in 0..<24 {
                if sample == 8 { h.network.release(version: version) }
                if sample < 8 { XCTAssertEqual(h.overlay.source.version, displayedVersion) }
                try await Task.sleep(for: .milliseconds(16))
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let frame = UIGraphicsImageRenderer(bounds: h.map.bounds, format: format).image { _ in
                    h.map.drawHierarchy(in: h.map.bounds, afterScreenUpdates: false)
                }
                let imagePoint = h.map.convert(artwork, toPointTo: h.map)
                let shorePoint = h.map.convert(shore, toPointTo: h.map)
                XCTAssertTrue(h.map.bounds.insetBy(dx: 4, dy: 4).contains(imagePoint))
                XCTAssertTrue(h.map.bounds.insetBy(dx: 4, dy: 4).contains(shorePoint))
                let imageIsMissing = isGreen(frame, at: imagePoint)
                let shoreIsErased = !isGreen(frame, at: shorePoint)
                frames += 1
                if imageIsMissing || shoreIsErased { badFrames += 1 }
                if h.overlay.source.version == version { verifiedFrames += 1 }
                if sample == 0 || sample == 23 || (imageIsMissing || shoreIsErased) && badFrames == 1 {
                    let attachment = XCTAttachment(image: frame)
                    attachment.name = "Egegik v\(displayedVersion) to v\(version), frame \(sample)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                XCTAssertEqual(h.map.overlays.map { ObjectIdentifier($0) }, layerIDs)
            }
            try await waitUntil { h.overlay.source.version == version }
            XCTAssertTrue(h.coordinator.mapView(h.map, rendererFor: h.overlay) === h.renderer)
        }
        XCTAssertFalse(h.renderer.continuity === originalSource)
        XCTAssertGreaterThan(verifiedFrames, 20, "Samples must include the newly displayed versions")
        XCTAssertEqual(badFrames, 0, "A version switch must retain district imagery and preserve shoreline transparency")
        print("ONLINE_VERSION_HANDOFF", frames, "real v4/v5 frames; damaged frames:", badFrames)
    }

    private func isGreen(_ image: UIImage, at point: CGPoint) -> Bool {
        guard let crop = image.cgImage?.cropping(to: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)),
              let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return bytes[20] < 70 && bytes[21] > 200 && bytes[22] < 70
    }

    func testSlowVersionKeepsCurrentPixelsAndReusesOverlayAndRenderer() async throws {
        let h = try await makeHarness()
        defer { h.coordinator.prepareForDismantle() }
        let oldSource = h.renderer.continuity
        let layers = h.map.overlays.map { ObjectIdentifier($0) }
        h.network.set(.held, version: 5)
        select(5, in: h)
        try await waitUntil { h.network.requestCount(version: 5) > 0 }
        XCTAssertEqual(h.overlay.source.version, 4)
        XCTAssertTrue(h.renderer.continuity === oldSource)
        XCTAssertTrue(h.renderer.canDraw(h.map.visibleMapRect, zoomScale: 1))
        XCTAssertEqual(h.map.overlays.map { ObjectIdentifier($0) }, layers)
        h.network.release(version: 5)
        try await waitUntil { h.overlay.source.version == 5 }
        XCTAssertTrue(h.coordinator.mapView(h.map, rendererFor: h.overlay) === h.renderer)
        XCTAssertFalse(h.renderer.continuity === oldSource)
        XCTAssertTrue(h.renderer.continuity === h.overlay.continuity)
        XCTAssertEqual(h.map.overlays.map { ObjectIdentifier($0) }, layers)
    }

    func testRapidSelectionsIgnoreAnOlderDownloadCompletion() async throws {
        let h = try await makeHarness()
        defer { h.coordinator.prepareForDismantle() }
        h.network.set(.held, version: 5)
        h.network.set(.held, version: 6)
        select(5, in: h)
        try await waitUntil { h.network.requestCount(version: 5) > 0 }
        select(6, in: h)
        try await waitUntil { h.network.requestCount(version: 6) > 0 }
        h.network.release(version: 5)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(h.overlay.source.version, 4)
        h.network.release(version: 6)
        try await waitUntil { h.overlay.source.version == 6 }
        XCTAssertEqual(h.map.overlays.filter { $0 is OnlineDistrictTileOverlay }.count, 1)
    }

    func testReturningToCurrentVersionCancelsTheReplacement() async throws {
        let h = try await makeHarness()
        defer { h.coordinator.prepareForDismantle() }
        let original = h.renderer.continuity
        h.network.set(.held, version: 5)
        select(5, in: h)
        try await waitUntil { h.network.requestCount(version: 5) > 0 }
        select(4, in: h)
        h.network.release(version: 5)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(h.overlay.source.version, 4)
        XCTAssertTrue(h.renderer.continuity === original)
    }

    func testMissingPyramidDoesNotReplaceWorkingImageryWithEmptyTiles() async throws {
        let h = try await makeHarness()
        defer { h.coordinator.prepareForDismantle() }
        let original = h.renderer.continuity
        h.network.set(.missing, version: 5)
        select(5, in: h)
        try await waitUntil { h.network.requestCount(version: 5) >= 6 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(h.overlay.source.version, 4)
        XCTAssertTrue(h.renderer.continuity === original)
        select(6, in: h)
        try await waitUntil { h.overlay.source.version == 6 }
    }

    func testTransientNetworkFailureRecoversWithoutRemovingCurrentVersion() async throws {
        let h = try await makeHarness()
        defer { h.coordinator.prepareForDismantle() }
        h.network.set(.failed, version: 5)
        select(5, in: h)
        try await Task.sleep(for: .milliseconds(1600))
        XCTAssertEqual(h.overlay.source.version, 4)
        h.network.set(.ready, version: 5)
        try await waitUntil({ h.overlay.source.version == 5 }, seconds: 6)
    }

    func testLeavingOnlineModeCancelsPendingVersionAndDoesNotResurrectLayers() async throws {
        let h = try await makeHarness()
        defer { h.coordinator.prepareForDismantle() }
        h.network.set(.held, version: 5)
        select(5, in: h)
        try await waitUntil { h.network.requestCount(version: 5) > 0 }
        h.coordinator.basemapChoice = .appleSatellite
        h.coordinator.syncBasemap(on: h.map)
        h.network.release(version: 5)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(h.map.overlays.isEmpty)
        XCTAssertEqual(h.overlay.source.version, 4)
    }

    func testDismantlingRejectsPendingCompletion() async throws {
        let h = try await makeHarness()
        h.network.set(.held, version: 5)
        select(5, in: h)
        try await waitUntil { h.network.requestCount(version: 5) > 0 }
        h.coordinator.prepareForDismantle()
        h.network.release(version: 5)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(h.overlay.source.version, 4)
    }

    func testCameraMovementDefersHandoffAndChecksTheNewViewport() async throws {
        let h = try await makeHarness()
        defer { h.coordinator.prepareForDismantle() }
        h.network.set(.held, version: 5)
        select(5, in: h)
        try await waitUntil { h.network.requestCount(version: 5) > 0 }
        h.coordinator.mapView(h.map, regionWillChangeAnimated: true)
        let target = OnlineDistrictMapCatalog.maps[0].bounds
        h.map.setVisibleMapRect(MKMapRect(x: target.midX, y: target.midY,
                                         width: target.width / 3, height: target.height / 3), animated: false)
        h.network.release(version: 5)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(h.overlay.source.version, 4)
        h.coordinator.mapView(h.map, regionDidChangeAnimated: true)
        try await waitUntil { h.overlay.source.version == 5 }
        let zoom = Int(log2(MKMapSize.world.width / (256 * h.map.visibleMapRect.width / Double(h.map.bounds.width))).rounded())
        let expected = h.overlay.continuity.coordinates(in: h.map.visibleMapRect, zoom: zoom,
                                                       limit: RasterMapContinuity.maximumDetailTiles)
        XCTAssertEqual(h.overlay.continuity.snapshot().detail?.coordinates, expected)
    }
}
