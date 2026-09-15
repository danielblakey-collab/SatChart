import Foundation
import MapKit
import Testing
@testable import SatChart

@MainActor
@Suite(.serialized)
struct MapCameraZoomRegressionTests {
    // Match the existing MapKit delegate tests: VectorKit tears down asynchronously,
    // so retain test views until the process exits rather than between test cases.
    private static var retainedMapViews: [MKMapView] = []
    private static var retainedWindows: [UIWindow] = []
    nonisolated private static let affectedBasemaps: [BasemapChoice] = [
        .appleSatellite, .districtsOffline, .districtsOnline
    ]
    nonisolated private static let outsideDistricts = CLLocationCoordinate2D(latitude: 47.60, longitude: -122.33)

    private final class ImmediateMapView: MKMapView {
        var requestedRects: [MKMapRect] = []

        override func setVisibleMapRect(_ mapRect: MKMapRect, animated: Bool) {
            requestedRects.append(mapRect)
            // Exercise MapKit's real camera geometry without animation timing making
            // the button assertion depend on whether the test view has a window.
            super.setVisibleMapRect(mapRect, animated: false)
        }
    }

    private static func fixture(
        basemap: BasemapChoice,
        center: CLLocationCoordinate2D = outsideDistricts,
        zoom: Double = 17
    ) -> (MapViewRepresentable.Coordinator, ImmediateMapView) {
        let coordinator = MapViewRepresentable.Coordinator(
            minZForTiles: 4,
            maxZ: 15,
            maxZForTiles: 15,
            extendedOfflineMaxZ: 17,
            extendedOfflineMaxZForTiles: 17,
            initialLaunchZoom: 12,
            initialCursorTrackingUser: true,
            onDistanceText: { _ in },
            onSpeedText: { _ in },
            onMetersPerPoint: { _ in },
            onFollowStateChanged: { _ in },
            onCursorUpdated: { _, _, _ in },
            onCursorTrackingStateChanged: { _ in },
            onFishingSetDisplayPrompt: { _ in }
        )
        let map = ImmediateMapView(frame: CGRect(x: 0, y: 0, width: 810, height: 1080))
        retainedMapViews.append(map)
        map.mapType = .satellite
        coordinator.mapView = map
        coordinator.basemapChoice = basemap
        // These regressions deliberately exercise the missing district-coverage
        // case, independent of network or the installed offline package inventory.
        coordinator.availableOnlineDistrictMaps = []
        map.setVisibleMapRect(rect(center: center, zoom: zoom, in: map), animated: false)
        map.requestedRects.removeAll()
        return (coordinator, map)
    }

    private static func rect(
        center: CLLocationCoordinate2D,
        zoom: Double,
        in map: MKMapView
    ) -> MKMapRect {
        let centerPoint = MKMapPoint(center)
        let mapPointsPerPoint = MKMapSize.world.width / (256 * pow(2, zoom))
        let width = Double(map.bounds.width) * mapPointsPerPoint
        let height = Double(map.bounds.height) * mapPointsPerPoint
        return MKMapRect(x: centerPoint.x - width / 2, y: centerPoint.y - height / 2,
                         width: width, height: height)
    }

    private static func zoom(in map: MKMapView) -> Double {
        log2(MKMapSize.world.width * Double(map.bounds.width) / (256 * map.visibleMapRect.width))
    }

    @Test(arguments: affectedBasemaps)
    func zoomButtonReachesBeyondNativeTileDetailWithoutDistrictCoverage(basemap: BasemapChoice) {
        let (coordinator, map) = Self.fixture(basemap: basemap)
        defer { coordinator.prepareForDismantle() }
        #expect(OnlineDistrictMapCatalog.maps.allSatisfy { !$0.bounds.intersects(map.visibleMapRect) })

        coordinator.zoom(map, delta: 1)

        #expect(abs(Self.zoom(in: map) - 18) < 0.02)
        #expect(map.requestedRects.count == 1)
        coordinator.clampZoomIfNeeded(map)
        #expect(abs(Self.zoom(in: map) - 18) < 0.02)
        #expect(map.requestedRects.count == 1, "Refreshing the map must not undo the user's zoom.")
    }

    @Test(arguments: affectedBasemaps)
    func pinchCameraSurvivesDelayedSettledCallbacksWithoutDistrictCoverage(basemap: BasemapChoice) async throws {
        let (coordinator, map) = Self.fixture(basemap: basemap, zoom: 19)
        defer { coordinator.prepareForDismantle() }

        // A pinch changes MapKit's camera directly, then ends with this delegate
        // sequence. The original snap occurred in the delayed settled update.
        coordinator.mapView(map, regionWillChangeAnimated: false)
        coordinator.mapViewDidChangeVisibleRegion(map)
        coordinator.mapView(map, regionDidChangeAnimated: false)
        // Include the late visible-region ordering handled by the production gate.
        coordinator.mapViewDidChangeVisibleRegion(map)
        try await Task.sleep(for: .milliseconds(2_500))

        #expect(!coordinator.isCameraMovementActive)
        #expect(abs(Self.zoom(in: map) - 19) < 0.02)
        #expect(map.requestedRects.isEmpty, "Settling a pinch must not write a lower camera zoom.")
    }

    @Test(arguments: affectedBasemaps)
    func movingOutsideDistrictBoundsDoesNotLowerTheCameraZoom(basemap: BasemapChoice) async throws {
        let bounds = OnlineDistrictMapCatalog.bounds(for: .egegik)
        let center = MKMapPoint(x: bounds.midX, y: bounds.midY).coordinate
        let (coordinator, map) = Self.fixture(basemap: basemap, center: center, zoom: 19)
        defer { coordinator.prepareForDismantle() }
        #expect(bounds.contains(map.visibleMapRect))
        coordinator.clampZoomIfNeeded(map)
        #expect(abs(Self.zoom(in: map) - 19) < 0.02)

        coordinator.mapView(map, regionWillChangeAnimated: false)
        map.setVisibleMapRect(Self.rect(center: Self.outsideDistricts, zoom: 19, in: map), animated: false)
        map.requestedRects.removeAll()
        coordinator.mapViewDidChangeVisibleRegion(map)
        coordinator.mapView(map, regionDidChangeAnimated: false)
        try await Task.sleep(for: .milliseconds(2_500))

        #expect(!coordinator.isCameraMovementActive)
        #expect(abs(Self.zoom(in: map) - 19) < 0.02)
        #expect(map.requestedRects.isEmpty, "Leaving district coverage must preserve the user's camera scale.")
    }

    @Test(arguments: [BasemapChoice.bristolBaySatelliteOffline, .noaaOffline, .noaaOnline])
    func unrelatedBasemapCameraCeilingsRemainUnchanged(basemap: BasemapChoice) {
        let (coordinator, map) = Self.fixture(basemap: basemap, zoom: 19)
        defer { coordinator.prepareForDismantle() }
        let expectedMaximum = basemap == .bristolBaySatelliteOffline ? 17.0 : 15.0
        coordinator.clampZoomIfNeeded(map)
        #expect(abs(Self.zoom(in: map) - expectedMaximum) < 0.02)
        coordinator.zoom(map, delta: 4)
        #expect(abs(Self.zoom(in: map) - expectedMaximum) < 0.02)
    }

    @Test(arguments: affectedBasemaps)
    func hostedNativeCameraAndZoomButtonKeepHighZoomOutsideDistricts(basemap: BasemapChoice) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        Self.retainedWindows.append(window)
        let controller = UIViewController()
        let map = MKMapView(frame: window.bounds)
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        Self.retainedMapViews.append(map)
        controller.view = map
        window.rootViewController = controller
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        let (coordinator, _) = Self.fixture(basemap: basemap)
        coordinator.mapView = map
        map.mapType = .satellite
        map.showsCompass = false
        map.pointOfInterestFilter = .excludingAll
        map.delegate = coordinator
        defer {
            map.delegate = nil
            coordinator.prepareForDismantle()
            window.isHidden = true
            previousKey?.makeKey()
        }
        let locations: [(String, CLLocationCoordinate2D)] = [
            ("Seattle", Self.outsideDistricts),
            ("Bristol Bay outside district maps", .init(latitude: 58.0, longitude: -158.5))
        ]
        for (name, center) in locations {
            map.setVisibleMapRect(Self.rect(center: center, zoom: 17, in: map), animated: false)
            coordinator.syncBasemap(on: map)
            try await Task.sleep(for: .milliseconds(500))
            #expect(OnlineDistrictMapCatalog.maps.allSatisfy { !$0.bounds.intersects(map.visibleMapRect) })
            print("ZOOM_REGRESSION", basemap.label, name, "beforePlus", Self.zoom(in: map), "altitude", map.camera.altitude)
            coordinator.zoom(map, delta: 1)
            try await Task.sleep(for: .milliseconds(2_500))
            print("ZOOM_REGRESSION", basemap.label, name, "afterPlus", Self.zoom(in: map), "altitude", map.camera.altitude)
            #expect(abs(Self.zoom(in: map) - 18) < 0.03)

            // MapKit itself can retain this camera. Reattach SatChart's delegate
            // and settle afterward to distinguish app clamping from a native cap.
            map.delegate = nil
            map.setVisibleMapRect(Self.rect(center: center, zoom: 19, in: map), animated: false)
            try await Task.sleep(for: .milliseconds(500))
            let nativePinchZoom = Self.zoom(in: map)
            print("ZOOM_NATIVE_WITHOUT_DELEGATE", basemap.label, name, nativePinchZoom, "altitude", map.camera.altitude)
            #expect(nativePinchZoom > 18, "MapKit must permit zoom beyond the former application ceiling.")
            map.delegate = coordinator
            coordinator.mapView(map, regionWillChangeAnimated: false)
            coordinator.mapViewDidChangeVisibleRegion(map)
            coordinator.mapView(map, regionDidChangeAnimated: false)
            try await Task.sleep(for: .milliseconds(2_500))
            print("ZOOM_REGRESSION", basemap.label, name, "afterDirectZoomAndSettle", Self.zoom(in: map), "altitude", map.camera.altitude)
            #expect(abs(Self.zoom(in: map) - nativePinchZoom) < 0.03,
                    "SatChart must preserve the camera scale accepted by MapKit.")
        }

        // Requests beyond MapKit's own limit must not leave a stale desired zoom
        // behind that makes the next minus-button press ineffective.
        map.delegate = nil
        map.setVisibleMapRect(Self.rect(center: Self.outsideDistricts, zoom: 30, in: map), animated: false)
        try await Task.sleep(for: .milliseconds(500))
        let nativeMaximum = Self.zoom(in: map)
        #expect(nativeMaximum.isFinite && nativeMaximum > 18)
        map.delegate = coordinator
        coordinator.zoom(map, delta: 1)
        try await Task.sleep(for: .milliseconds(1_250))
        #expect(abs(Self.zoom(in: map) - nativeMaximum) < 0.05)
        coordinator.zoom(map, delta: -1)
        try await Task.sleep(for: .milliseconds(1_250))
        #expect(abs(Self.zoom(in: map) - (nativeMaximum - 1)) < 0.05)
    }
}
