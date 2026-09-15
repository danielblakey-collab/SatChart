import XCTest
import MapKit
import SQLite3
@testable import SatChart

/// Exercises MapKit's actual compositing with the same renderer adapters used by
/// both district modes. Synthetic opaque tiles make a basemap flash measurable.
@MainActor
final class RasterContinuityPresentationTests: XCTestCase {
    private final class Delegate: NSObject, MKMapViewDelegate {
        let renderer: MKOverlayRenderer
        init(_ renderer: MKOverlayRenderer) { self.renderer = renderer }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer { renderer }
    }
    private static var retainedWindows: [UIWindow] = []

    func testOnlinePixelsPersistAcrossAnimatedZooms() async throws {
        let source = try XCTUnwrap(OnlineDistrictMapCatalog.maps.first)
        let png = Self.redPNG()
        let overlay = OnlineDistrictTileOverlay(source: source) { _, _, result in
            result(png, nil)
        }
        try await checkPresentation(overlay: overlay,
                                   renderer: RasterContinuityRenderer(overlay: overlay, continuity: overlay.continuity),
                                   continuity: overlay.continuity, name: "online")
    }

    nonisolated private final class NativeRequests: @unchecked Sendable {
        private let lock = NSLock()
        private var zooms: [Int] = []
        func record(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            zooms.append(Int(url.pathComponents.suffix(3).first!)!)
        }
        var levels: Set<Int> {
            lock.lock(); defer { lock.unlock() }
            return Set(zooms)
        }
    }
    private static var retainedCoordinators: [MapViewRepresentable.Coordinator] = []

    func testOnlineOverzoomKeepsNativePixelsBeyondDistrictDetail() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        Self.retainedWindows.append(window)
        let controller = UIViewController()
        let map = MKMapView(frame: window.bounds)
        controller.view = map
        window.rootViewController = controller
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        map.mapType = .satellite
        map.showsCompass = false
        map.pointOfInterestFilter = .excludingAll
        let coordinator = MapViewRepresentable.Coordinator(
            minZForTiles: 4, maxZ: 15, maxZForTiles: 15,
            extendedOfflineMaxZ: 17, extendedOfflineMaxZForTiles: 17,
            initialLaunchZoom: 15, initialCursorTrackingUser: true,
            onDistanceText: { _ in }, onSpeedText: { _ in }, onMetersPerPoint: { _ in },
            onFollowStateChanged: { _ in }, onCursorUpdated: { _, _, _ in },
            onCursorTrackingStateChanged: { _ in }, onFishingSetDisplayPrompt: { _ in })
        Self.retainedCoordinators.append(coordinator)
        coordinator.mapView = map
        coordinator.availableOnlineDistrictMaps = OnlineDistrictMapCatalog.maps.filter { $0.pack.district == .egegik && $0.version >= 4 }
        coordinator.basemapChoice = .districtsOnline
        defer {
            coordinator.prepareForDismantle()
            window.isHidden = true
            previousKey?.makeKey()
            map.delegate = nil
        }
        let source = try XCTUnwrap(OnlineDistrictMapCatalog.maps.first)
        let center = MKMapPoint(x: source.bounds.midX, y: source.bounds.midY)
        func rect(at zoom: Double) -> MKMapRect {
            let scale = MKMapSize.world.width / (256 * pow(2, zoom))
            let width = Double(map.bounds.width) * scale
            let height = Double(map.bounds.height) * scale
            return MKMapRect(x: center.x - width / 2, y: center.y - height / 2,
                             width: width, height: height)
        }
        func displayedZoom() -> Double {
            log2(MKMapSize.world.width * Double(map.bounds.width) / (256 * map.visibleMapRect.width))
        }
        map.setVisibleMapRect(rect(at: 15), animated: false)
        let requests = NativeRequests()
        let png = Self.redPNG()
        let overlay = OnlineDistrictTileOverlay(source: source) { url, _, result in
            requests.record(url)
            result(png, nil)
        }
        let renderer = coordinator.mapView(map, rendererFor: overlay)
        let delegate = Delegate(renderer)
        map.delegate = delegate
        map.addOverlay(overlay, level: .aboveLabels)
        let ready = await withCheckedContinuation { continuation in
            overlay.continuity.prepare(in: map.visibleMapRect, zoom: 15) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertTrue(ready)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(displayedZoom(), 15, accuracy: 0.05)
        XCTAssertGreaterThan(capture(map).redFraction, 0.99)
        var minimumCoverage = 1.0
        var previousZoom = displayedZoom()
        for (step, delta) in [1, 1, 1, 1, -1].enumerated() {
            let target = previousZoom + Double(delta)
            coordinator.zoom(map, delta: delta)
            for _ in 0..<24 {
                try await Task.sleep(for: .milliseconds(25))
                minimumCoverage = min(minimumCoverage, capture(map).redFraction)
            }
            let acceptedZoom = displayedZoom()
            if step == 3 {
                // This tap may reach MapKit's native limit below z19. Its
                // camera regression is covered separately; retain pixels here.
                XCTAssertGreaterThan(acceptedZoom, 18)
                XCTAssertLessThanOrEqual(acceptedZoom, target + 0.05)
            } else {
                XCTAssertEqual(acceptedZoom, target, accuracy: 0.05)
            }
            coordinator.clampZoomIfNeeded(map)
            XCTAssertEqual(displayedZoom(), acceptedZoom, accuracy: 0.05,
                           "Settling a pinch must preserve camera zoom above native district detail")
            previousZoom = acceptedZoom
            XCTAssertTrue(coordinator.mapView(map, rendererFor: overlay) === renderer)
            let detail = try XCTUnwrap(overlay.continuity.snapshot().detail)
            XCTAssertFalse(detail.images.isEmpty)
            XCTAssertTrue(detail.coordinates.allSatisfy { $0.z == 15 })
        }
        // Pinch gestures remain at the user's scale, just like the plus button.
        map.setVisibleMapRect(rect(at: 19), animated: false)
        try await Task.sleep(for: .milliseconds(500))
        let acceptedPinchZoom = displayedZoom()
        XCTAssertGreaterThan(acceptedPinchZoom, 18)
        coordinator.clampZoomIfNeeded(map)
        XCTAssertEqual(displayedZoom(), acceptedPinchZoom, accuracy: 0.05)
        XCTAssertEqual(requests.levels.max(), 15, "Overzoom must request only native parent tiles")
        XCTAssertGreaterThan(minimumCoverage, 0.99, "Child zooms must preserve district imagery")
        attach(capture(map).image, name: "online-native-parents-at-close-camera-zoom")
        print("ONLINE_CHILD_ZOOM", "120 sampled frames; minimum coverage:", minimumCoverage,
              "maximum source zoom:", requests.levels.max() ?? -1)
        _ = delegate
    }

    func testOfflinePixelsPersistAcrossAnimatedZooms() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("continuity-\(UUID()).mbtiles")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db); try? FileManager.default.removeItem(at: url) }
        let hex = Self.redPNG().map { String(format: "%02x", $0) }.joined()
        let sql = "CREATE TABLE metadata(name TEXT,value TEXT); CREATE TABLE tiles(zoom_level INTEGER,tile_column INTEGER,tile_row INTEGER,tile_data BLOB); INSERT INTO metadata VALUES('scheme','tms'),('format','png'),('minzoom','0'),('maxzoom','0'); INSERT INTO tiles VALUES(0,0,0,X'\(hex)');"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let identity = MBTilesOverlayIdentity(role: .district, packageIdentifier: "presentation-test",
                                             packageVersion: UUID().uuidString, fileURL: url,
                                             minimumZoom: 0, maximumZoom: 8, nativeDetailMaximumZoom: 8,
                                             maximumFallbackDepth: 8)
        let session = MBTilesPackageSession(identity: identity, immutableFile: false)
        defer { session.invalidate(waitForTeardown: true) }
        let overlay = DistrictMapBackstopOverlay(slug: "egegik_v4", identity: identity,
                                                packageSession: session,
                                                boundingMapRect: OnlineDistrictMapCatalog.maps[0].bounds)
        overlay.activate()
        try await checkPresentation(overlay: overlay, renderer: DistrictMapBackstopRenderer(overlay: overlay),
                                   continuity: overlay.continuity, name: "offline")
    }

    private static func redPNG() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }
    }

    private func checkPresentation(overlay: MKOverlay, renderer: MKOverlayRenderer,
                                   continuity: RasterMapContinuity, name: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        Self.retainedWindows.append(window) // Avoid VectorKit asynchronous teardown races in simulator tests.
        let controller = UIViewController()
        let map = MKMapView(frame: window.bounds)
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view = map
        window.rootViewController = controller
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        let delegate = Delegate(renderer)
        map.delegate = delegate
        defer { window.isHidden = true; previousKey?.makeKey(); map.delegate = nil }
        map.mapType = .satellite
        map.showsCompass = false
        map.pointOfInterestFilter = .excludingAll
        let center = CLLocationCoordinate2D(latitude: 58.25, longitude: -157.45)
        map.setRegion(MKCoordinateRegion(center: center,
                                        span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.025)), animated: false)
        let ready = await withCheckedContinuation { continuation in
            continuity.prepare(in: map.visibleMapRect, zoom: 13) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(ready)
        map.addOverlay(overlay, level: .aboveLabels)
        try await Task.sleep(for: .seconds(2))
        let initial = capture(map)
        attach(initial.image, name: "\(name)-before")
        XCTAssertGreaterThan(initial.redFraction, 0.99, "Initial synthetic district should cover the center of the map")
        guard initial.redFraction > 0.99 else { return }
        var lowestCoverage = 1.0
        for factor in [0.5, 0.25, 0.5, 1.0] {
            // Deliberately do not load destination tiles. Only retained pixels can cover the animation.
            map.setRegion(MKCoordinateRegion(center: center,
                                            span: MKCoordinateSpan(latitudeDelta: 0.015 * factor,
                                                                   longitudeDelta: 0.025 * factor)), animated: true)
            for _ in 0..<16 {
                try await Task.sleep(for: .milliseconds(25))
                let frame = capture(map)
                if frame.redFraction < lowestCoverage {
                    lowestCoverage = frame.redFraction
                    attach(frame.image, name: "\(name)-minimum-coverage")
                }
            }
        }
        attach(capture(map).image, name: "\(name)-after")
        XCTAssertGreaterThan(lowestCoverage, 0.99, "Retained imagery must remain visible while zoom buffers change")
        print("CONTINUITY_PRESENTATION", name, "sampled frames: 64, minimum red coverage:", lowestCoverage)
        _ = delegate
    }

    private func capture(_ map: MKMapView) -> (image: UIImage, redFraction: Double) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: map.bounds, format: format).image { _ in
            map.drawHierarchy(in: map.bounds, afterScreenUpdates: false)
        }
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image.cgImage!, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        var red = 0
        var total = 0
        for y in 16..<48 {
            for x in 16..<48 {
                let offset = y * 256 + x * 4
                if bytes[offset] > 220, bytes[offset + 1] < 80, bytes[offset + 2] < 80 { red += 1 }
                total += 1
            }
        }
        return (image, Double(red) / Double(total))
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
