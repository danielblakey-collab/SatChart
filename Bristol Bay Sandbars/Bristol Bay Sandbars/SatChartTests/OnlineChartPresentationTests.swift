import XCTest
import MapKit
@testable import SatChart

@MainActor
final class OnlineChartPresentationTests: XCTestCase {
    private final class Delegate: NSObject, MKMapViewDelegate {
        let coordinator: MapViewRepresentable.Coordinator
        let background: MKPolygon
        init(_ coordinator: MapViewRepresentable.Coordinator, _ background: MKPolygon) {
            self.coordinator = coordinator; self.background = background
        }
        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if overlay === background {
                let fill = MKPolygonRenderer(polygon: background); fill.fillColor = .green; return fill
            }
            return coordinator.mapView(map, rendererFor: overlay)
        }
        func mapView(_ map: MKMapView, regionWillChangeAnimated animated: Bool) {
            coordinator.mapView(map, regionWillChangeAnimated: animated)
        }
        func mapView(_ map: MKMapView, regionDidChangeAnimated animated: Bool) {
            coordinator.mapView(map, regionDidChangeAnimated: animated)
        }
        func mapViewDidChangeVisibleRegion(_ map: MKMapView) {
            coordinator.mapViewDidChangeVisibleRegion(map)
        }
    }
    private static var retainedWindows: [UIWindow] = []
    private static var retainedDelegates: [Delegate] = []

    func testUSGSRetainsPixelsDuringZooms() async throws { try await check(source: .usgs) }
    func testNOAAPreservesTransparencyDuringZooms() async throws { try await check(source: .noaa) }

    private func check(source: OnlineChartSource) async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).pngData {
            UIColor.red.withAlphaComponent(source == .noaa ? 0.5 : 1).setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        ChartProtocol.reset { _ in .init(data: png, delay: 0.015) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChartProtocol.self]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chart-live-\(UUID())")
        let store = OnlineChartTileStore(configuration: config, directory: directory, pixelSize: 256,
                                         imageByteLimit: OnlineChartTileStore.imageLimit, observeSystem: false)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        Self.retainedWindows.append(window)
        let controller = UIViewController()
        let map = MKMapView(frame: window.bounds)
        controller.view = map; window.rootViewController = controller
        window.windowLevel = .normal + 1; window.makeKeyAndVisible()
        let coordinator = MapViewRepresentable.Coordinator(
            minZForTiles: 4, maxZ: 15, maxZForTiles: 15,
            extendedOfflineMaxZ: 17, extendedOfflineMaxZForTiles: 17,
            initialLaunchZoom: 13, initialCursorTrackingUser: true,
            onDistanceText: { _ in }, onSpeedText: { _ in }, onMetersPerPoint: { _ in },
            onFollowStateChanged: { _ in }, onCursorUpdated: { _, _, _ in },
            onCursorTrackingStateChanged: { _ in }, onFishingSetDisplayPrompt: { _ in })
        coordinator.onlineChartOverlayFactory = { OnlineChartOverlay(source: $0, store: store) }
        coordinator.mapView = map
        coordinator.basemapChoice = source == .usgs ? .topoOnline : .noaaOnline
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 58.25, longitude: -157.45),
                                         span: MKCoordinateSpan(latitudeDelta: 0.06, longitudeDelta: 0.08)), animated: false)
        let backingRect = map.visibleMapRect.insetBy(dx: -map.visibleMapRect.width * 5, dy: -map.visibleMapRect.height * 5)
        let background = MKPolygon(points: [MKMapPoint(x: backingRect.minX, y: backingRect.minY),
                                            MKMapPoint(x: backingRect.maxX, y: backingRect.minY),
                                            MKMapPoint(x: backingRect.maxX, y: backingRect.maxY),
                                            MKMapPoint(x: backingRect.minX, y: backingRect.maxY)], count: 4)
        let delegate = Delegate(coordinator, background)
        Self.retainedDelegates.append(delegate)
        map.delegate = delegate
        coordinator.syncBasemap(on: map)
        let overlay = try XCTUnwrap(map.overlays.compactMap { $0 as? OnlineChartOverlay }.first)
        map.insertOverlay(background, below: overlay)
        let renderer = try XCTUnwrap(coordinator.mapView(map, rendererFor: overlay) as? RasterContinuityRenderer)
        defer {
            coordinator.prepareForDismantle(); renderer.setCameraMovementActive(false)
            window.isHidden = true; previousKey?.makeKey(); map.delegate = nil
        }
        try await Task.sleep(for: .seconds(2))
        let initial = capture(map)
        let reference = average(initial)
        XCTAssertGreaterThan(reference.0, 100)
        if source == .noaa { XCTAssertGreaterThan(reference.1, 80) }
        else { XCTAssertLessThan(reference.1, 80) }
        let baselineFootprint = SmartFishTicketMemoryDiagnostics.physicalFootprintBytes ?? 0
        var peakFootprint = baselineFootprint
        var damaged = 0
        for delta in [1, 1, -1, -1] {
            coordinator.zoom(map, delta: delta)
            for sample in 0..<24 {
                try await Task.sleep(for: .milliseconds(25))
                let frame = capture(map)
                let color = average(frame)
                let deviation = max(abs(color.0-reference.0), abs(color.1-reference.1), abs(color.2-reference.2))
                if deviation > 15 { damaged += 1 }
                if damaged == 1 || sample == 23 {
                    let attachment = XCTAttachment(image: frame)
                    attachment.name = "\(source.rawValue) zoom \(delta), sample \(sample)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                peakFootprint = max(peakFootprint, SmartFishTicketMemoryDiagnostics.physicalFootprintBytes ?? 0)
                XCTAssertLessThanOrEqual(store.imageBudget.usage.current, OnlineChartTileStore.imageLimit)
            }
            XCTAssertTrue(coordinator.mapView(map, rendererFor: overlay) === renderer)
        }
        // Switching service must wait for a drawn replacement, not just downloaded bytes.
        coordinator.basemapChoice = source == .noaa ? .topoOnline : .noaaOnline
        coordinator.syncBasemap(on: map)
        for _ in 0..<48 {
            try await Task.sleep(for: .milliseconds(25))
            XCTAssertGreaterThan(average(capture(map)).0, 100, "Mode handoff exposed the green backing surface")
        }
        let charts = map.overlays.compactMap { $0 as? OnlineChartOverlay }
        XCTAssertEqual(charts.count, 1, "A drawn replacement should retire the predecessor")
        let replacement = try XCTUnwrap(charts.first)
        let replacementRenderer = try XCTUnwrap(coordinator.mapView(map, rendererFor: replacement) as? RasterContinuityRenderer)
        XCTAssertTrue(replacementRenderer.hasDrawnReadyCoverage(in: map.visibleMapRect))
        XCTAssertEqual(damaged, 0, "Opaque imagery and NOAA's alpha must survive animated zooms")
        print("ONLINE_CHART_PRESENTATION", source.rawValue, "96 frames; damaged:", damaged,
              "image peak:", store.imageBudget.usage.peak,
              "process baseline/peak (includes screenshots and MapKit):", baselineFootprint, peakFootprint)
        _ = delegate
    }
    private func capture(_ map: MKMapView) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(bounds: map.bounds, format: format).image { _ in
            map.drawHierarchy(in: map.bounds, afterScreenUpdates: false)
        }
    }
    private func average(_ image: UIImage) -> (Double, Double, Double) {
        let cg = image.cgImage!
        let center = cg.cropping(to: CGRect(x: cg.width / 4, y: cg.height / 4,
                                            width: cg.width / 2, height: cg.height / 2))!
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(center, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        var r = 0; var g = 0; var b = 0
        for n in 0..<256 { r += Int(bytes[n*4]); g += Int(bytes[n*4+1]); b += Int(bytes[n*4+2]) }
        return (Double(r)/256, Double(g)/256, Double(b)/256)
    }
}
