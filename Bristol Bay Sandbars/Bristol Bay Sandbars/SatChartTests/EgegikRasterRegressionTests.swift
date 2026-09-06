import XCTest
import MapKit
@testable import SatChart

@MainActor
final class EgegikRasterRegressionTests: XCTestCase {
    private var bounds: MKMapRect { OnlineDistrictMapCatalog.maps[0].bounds }

    private func online() -> OnlineDistrictTileOverlay {
        let original = OnlineDistrictMapCatalog.maps[0]
        let source = OnlineDistrictMap(pack: original.pack, minimumZoom: 11, maximumZoom: 12, bounds: original.bounds)
        let bundle = Bundle(for: Self.self)
        return OnlineDistrictTileOverlay(source: source) { url, _, completion in
            let parts = url.pathComponents.suffix(3)
            let filename = "egegik-v4-xyz-" + parts.joined(separator: "-").replacingOccurrences(of: ".png", with: "")
            let data = bundle.url(forResource: filename, withExtension: "png").flatMap { try? Data(contentsOf: $0) }
            completion(data, nil)
        }
    }

    func testActualOnlineEgegikTransparencyPreservesBackingPixels() async throws {
        let overlay = online()
        try await checkTransparency(continuity: overlay.continuity,
                                    renderer: RasterContinuityRenderer(overlay: overlay, continuity: overlay.continuity))
    }

    func testActualOfflineEgegikTransparencyPreservesBackingPixels() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "egegik-v4-rendering-fixture", withExtension: "mbtiles"))
        let identity = MBTilesOverlayIdentity(role: .district, packageIdentifier: "egegik-real-fixture",
                                             packageVersion: "v4", fileURL: url,
                                             minimumZoom: 11, maximumZoom: 12, nativeDetailMaximumZoom: 12)
        let session = MBTilesPackageSession(identity: identity, immutableFile: true)
        defer { session.invalidate(waitForTeardown: true) }
        let overlay = DistrictMapBackstopOverlay(slug: "egegik_v4", identity: identity,
                                                packageSession: session, boundingMapRect: bounds)
        overlay.activate()
        try await checkTransparency(continuity: overlay.continuity, renderer: DistrictMapBackstopRenderer(overlay: overlay))
    }

    private func checkTransparency(continuity: RasterMapContinuity, renderer: RasterContinuityRenderer) async throws {
        let ready = await withCheckedContinuation { continuation in
            continuity.prepare(in: bounds, zoom: 11) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(continuity.snapshot().detail?.images.count, 6)
        let actual = try makeContext()
        let expected = try makeContext()
        for context in [actual, expected] {
            context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
            let projection = renderer.rect(for: bounds)
            context.scaleBy(x: 512 / projection.width, y: 512 / projection.height)
            context.translateBy(x: -projection.minX, y: -projection.minY)
            context.clip(to: projection)
            context.interpolationQuality = .medium
        }
        let scale = MKZoomScale(256 * pow(2, 11) / MKMapSize.world.width)
        renderer.draw(bounds, zoomScale: scale, in: actual)
        UIGraphicsPushContext(expected)
        for (tile, image) in continuity.snapshot().detail!.images {
            UIImage(cgImage: image).draw(in: renderer.rect(for: MBTilesViewportTilePlanner.mapRect(for: tile)),
                                        blendMode: .normal, alpha: 1)
        }
        UIGraphicsPopContext()
        let actualBytes = actual.data!.assumingMemoryBound(to: UInt8.self)
        let expectedBytes = expected.data!.assumingMemoryBound(to: UInt8.self)
        var damagedBackingPixels = 0
        var checkedTransparentPixels = 0
        for offset in stride(from: 0, to: 512 * 512 * 4, by: 4) {
            if expectedBytes[offset] < 40, expectedBytes[offset + 1] > 220, expectedBytes[offset + 2] < 40 {
                checkedTransparentPixels += 1
                if actualBytes[offset + 3] < 255 || actualBytes[offset + 1] < 220 { damagedBackingPixels += 1 }
            }
        }
        XCTAssertGreaterThan(checkedTransparentPixels, 50_000, "Fixture must exercise the irregular transparent shoreline")
        let attachment = XCTAttachment(image: UIImage(cgImage: try XCTUnwrap(actual.makeImage())))
        attachment.name = "Actual Egegik over a green backing layer"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(damagedBackingPixels, 0, "District drawing must not erase the Bristol Bay surface inside a rectangular tile footprint")
    }

    func testArrivingEgegikTilesDoNotInvalidateOrChangeAnActiveZoom() async throws {
        let overlay = online()
        let source = overlay.continuity
        let renderer = RasterContinuityRenderer(overlay: overlay, continuity: source)
        let initialReady = await withCheckedContinuation { continuation in
            source.prepare(in: bounds, zoom: 11) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(initialReady)
        try await Task.sleep(for: .milliseconds(100))
        let before = try pixels(renderer)
        let initialInvalidations = renderer.invalidationFlushCount
        renderer.setCameraMovementActive(true)
        let detailReady = await withCheckedContinuation { continuation in
            source.prepare(in: bounds, zoom: 12) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(detailReady)
        XCTAssertEqual(source.snapshot().detail?.images.count, 17)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(renderer.invalidationFlushCount, initialInvalidations)
        XCTAssertEqual(try pixels(renderer), before, "A late completion must not replace pixels during zoom")
        renderer.setCameraMovementActive(false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(renderer.invalidationFlushCount, initialInvalidations + 1)
        XCTAssertNotEqual(try pixels(renderer), before, "Sharper real tiles must become visible after settling")
    }

    private func pixels(_ renderer: RasterContinuityRenderer) throws -> Data {
        let context = try makeContext()
        let projection = renderer.rect(for: bounds)
        context.scaleBy(x: 512 / projection.width, y: 512 / projection.height)
        context.translateBy(x: -projection.minX, y: -projection.minY)
        renderer.draw(bounds, zoomScale: MKZoomScale(256 * pow(2, 12) / MKMapSize.world.width), in: context)
        return Data(bytes: context.data!, count: 512 * 512 * 4)
    }

    private final class LiveDelegate: NSObject, MKMapViewDelegate {
        let renderer: RasterContinuityRenderer
        let background: MKPolygon
        private var settle: DispatchWorkItem?
        init(renderer: RasterContinuityRenderer, background: MKPolygon) {
            self.renderer = renderer
            self.background = background
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if overlay === background {
                let fill = MKPolygonRenderer(polygon: background)
                fill.fillColor = .green
                return fill
            }
            return renderer
        }
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            settle?.cancel()
            renderer.setCameraMovementActive(true)
        }
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let next = DispatchWorkItem { [weak self] in self?.renderer.setCameraMovementActive(false) }
            settle = next
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: next)
        }
    }
    private static var retainedWindows: [UIWindow] = []

    func testActualOnlineEgegikInMapKitWithTilesArrivingDuringZoom() async throws {
        let overlay = online()
        try await checkLiveMap(overlay: overlay,
                              renderer: RasterContinuityRenderer(overlay: overlay, continuity: overlay.continuity),
                              name: "Online")
    }

    func testActualOfflineEgegikInMapKitWithTilesArrivingDuringZoom() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "egegik-v4-rendering-fixture", withExtension: "mbtiles"))
        let identity = MBTilesOverlayIdentity(role: .district, packageIdentifier: "egegik-live-fixture",
                                             packageVersion: "v4", fileURL: url,
                                             minimumZoom: 11, maximumZoom: 12, nativeDetailMaximumZoom: 12)
        let session = MBTilesPackageSession(identity: identity, immutableFile: true)
        defer { session.invalidate(waitForTeardown: true) }
        let overlay = DistrictMapBackstopOverlay(slug: "egegik_v4", identity: identity,
                                                packageSession: session, boundingMapRect: bounds)
        overlay.activate()
        try await checkLiveMap(overlay: overlay, renderer: DistrictMapBackstopRenderer(overlay: overlay), name: "Offline")
    }

    private func checkLiveMap(overlay: MKOverlay, renderer: RasterContinuityRenderer, name: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        Self.retainedWindows.append(window)
        let controller = UIViewController()
        let map = MKMapView(frame: window.bounds)
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.mapType = .satellite
        map.showsCompass = false
        map.pointOfInterestFilter = .excludingAll
        controller.view = map
        window.rootViewController = controller
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKey?.makeKey(); map.delegate = nil }
        let backingRect = bounds.insetBy(dx: -bounds.width * 2, dy: -bounds.height * 2)
        let background = MKPolygon(points: [MKMapPoint(x: backingRect.minX, y: backingRect.minY),
                                            MKMapPoint(x: backingRect.maxX, y: backingRect.minY),
                                            MKMapPoint(x: backingRect.maxX, y: backingRect.maxY),
                                            MKMapPoint(x: backingRect.minX, y: backingRect.maxY)], count: 4)
        let delegate = LiveDelegate(renderer: renderer, background: background)
        map.setVisibleMapRect(bounds.insetBy(dx: -bounds.width * 0.2, dy: -bounds.height * 0.2), animated: false)
        let initialReady = await withCheckedContinuation { continuation in
            renderer.continuity.prepare(in: bounds, zoom: 11) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(initialReady)
        map.delegate = delegate
        map.addOverlay(background, level: .aboveRoads)
        map.addOverlay(overlay, level: .aboveRoads)
        try await Task.sleep(for: .seconds(2))
        let startingRect = map.visibleMapRect
        let artworkPoint = CLLocationCoordinate2D(latitude: 58.25, longitude: -157.6)
        let transparentPoint = CLLocationCoordinate2D(latitude: 58.25, longitude: -157.4)
        var failures = 0
        for (index, factor) in [0.9, 0.75, 1.0, 0.85].enumerated() {
            let next = MKMapRect(x: startingRect.midX - startingRect.width * factor / 2,
                                 y: startingRect.midY - startingRect.height * factor / 2,
                                 width: startingRect.width * factor, height: startingRect.height * factor)
            renderer.setCameraMovementActive(true)
            map.setVisibleMapRect(next, animated: true)
            // Exercise the missing case in the earlier all-red tests: replacement
            // images arrive and request invalidation while the camera is moving.
            renderer.continuity.prepare(in: bounds, zoom: index.isMultiple(of: 2) ? 12 : 11)
            for sample in 0..<16 {
                try await Task.sleep(for: .milliseconds(25))
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let frame = UIGraphicsImageRenderer(bounds: map.bounds, format: format).image { _ in
                    map.drawHierarchy(in: map.bounds, afterScreenUpdates: false)
                }
                let hasBox = !isGreen(frame, at: map.convert(transparentPoint, toPointTo: map))
                let hasHole = isGreen(frame, at: map.convert(artworkPoint, toPointTo: map))
                if hasBox || hasHole { failures += 1 }
                if (index == 0 && sample == 0) || (hasBox || hasHole) && failures == 1 {
                    let attachment = XCTAttachment(image: frame)
                    attachment.name = "\(name) real Egegik shoreline during zoom"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
        XCTAssertEqual(failures, 0, "Real imagery must stay visible and its transparent shore must preserve the backing map")
        print("EGEGIK_LIVE_PRESENTATION", name, "64 sampled frames; damaged frames:", failures)
        _ = delegate
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

    private func makeContext() throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8,
                               bytesPerRow: 512 * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }
}
