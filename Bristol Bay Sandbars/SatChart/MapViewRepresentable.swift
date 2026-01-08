import SwiftUI
import MapKit
import CoreLocation
import UIKit
import Foundation


// MARK: - Waypoints model (FILE SCOPE so other views can use it)

struct Waypoint: Identifiable, Hashable {
    let id: UUID
    var name: String          // default: "1", "2", "3"...
    var notes: String
    var coordinate: CLLocationCoordinate2D

    init(id: UUID = UUID(), name: String, notes: String = "", coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.name = name
        self.notes = notes
        self.coordinate = coordinate
    }

    var displayName: String { name }

    static func == (lhs: Waypoint, rhs: Waypoint) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct MapViewRepresentable: UIViewRepresentable {

    let locationManager: LocationManager

    @Binding var distanceText: String
    @Binding var speedText: String
    @Binding var metersPerPoint: Double

    @Binding var followUserRequest: Int
    @Binding var recenterRequest: Int
    @Binding var isFollowingUser: Bool

    @Binding var tideBlend: Double

    @Binding var cursorCoordinate: CLLocationCoordinate2D?
    @Binding var cursorDistanceText: String
    @Binding var cursorCoordText: String
    @Binding var cursorPanRequest: Int

    @Binding var waypoints: [Waypoint]
    let radioPins: [RadioGroupStore.Pin]

    @Binding var zoomInRequest: Int
    @Binding var zoomOutRequest: Int


    // MARK: - Explicit init (matches call-site labels)
    init(
        locationManager: LocationManager,
        distanceText: Binding<String>,
        speedText: Binding<String>,
        metersPerPoint: Binding<Double>,
        followUserRequest: Binding<Int>,
        recenterRequest: Binding<Int>,
        isFollowingUser: Binding<Bool>,
        tideBlend: Binding<Double>,
        cursorCoordinate: Binding<CLLocationCoordinate2D?>,
        cursorDistanceText: Binding<String>,
        cursorCoordText: Binding<String>,
        cursorPanRequest: Binding<Int>,
        waypoints: Binding<[Waypoint]>,
        radioPins: [RadioGroupStore.Pin],
        zoomInRequest: Binding<Int>,
        zoomOutRequest: Binding<Int>
    ) {
        self.locationManager = locationManager
        self._distanceText = distanceText
        self._speedText = speedText
        self._metersPerPoint = metersPerPoint
        self._followUserRequest = followUserRequest
        self._recenterRequest = recenterRequest
        self._isFollowingUser = isFollowingUser
        self._tideBlend = tideBlend
        self._cursorCoordinate = cursorCoordinate
        self._cursorDistanceText = cursorDistanceText
        self._cursorCoordText = cursorCoordText
        self._cursorPanRequest = cursorPanRequest
        self._waypoints = waypoints
        self.radioPins = radioPins
        self._zoomInRequest = zoomInRequest
        self._zoomOutRequest = zoomOutRequest
    }

    // Zoom behavior
    private let minZForTiles: Int = 8
    private let maxZ: Double = 14
    private let maxZForTiles: Int = 14
    private let initialLaunchZoom: Double = 8.0

    // ✅ Packs available (base + v2)
    private var availablePacks: [OfflinePack] {
        var packs: [OfflinePack] = []

        for district in DistrictID.allCases {
            packs.append(OfflinePack(district: district, slug: district.rawValue))
        }

        packs.append(OfflinePack(district: .egegik, slug: "egegik_v2"))
        return packs
    }

    func makeCoordinator() -> Coordinator {
        let followBinding = $isFollowingUser

        return Coordinator(
            minZForTiles: minZForTiles,
            maxZ: maxZ,
            maxZForTiles: maxZForTiles,
            initialLaunchZoom: initialLaunchZoom,
            onDistanceText: { distanceText = $0 },
            onSpeedText: { speedText = $0 },
            onMetersPerPoint: { metersPerPoint = $0 },
            onFollowStateChanged: { newValue in
                DispatchQueue.main.async {
                    followBinding.wrappedValue = newValue
                }
            },
            onCursorUpdated: { coord, distText, coordText in
                cursorCoordinate = coord
                cursorDistanceText = distText
                cursorCoordText = coordText
            }
        )
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        context.coordinator.mapView = map
        map.delegate = context.coordinator

        map.mapType = .satellite
        map.showsUserLocation = true

        map.register(
            CourseTriangleUserView.self,
            forAnnotationViewWithReuseIdentifier: context.coordinator.userViewReuseID
        )

        // North-up lock
        map.isRotateEnabled = false
        var cam = map.camera
        cam.heading = 0
        map.camera = cam

        // Custom follow
        map.userTrackingMode = .none

        // Boundaries + overlays
        installDistrictBoundaries(on: map, coordinator: context.coordinator)
        installOrRefreshAllMBTilesOverlays(on: map, coordinator: context.coordinator)
        // Seed scale
        context.coordinator.updateScale(map)

        // Gestures + cursor tap
        context.coordinator.installGestureHooksIfNeeded(map)
        context.coordinator.installCursorTapIfNeeded(map)

        // ⚠️ MapKit sometimes doesn't have all gesture recognizers attached at makeUIView time.
        // Re-attach on next runloop to guarantee we see pan/zoom gestures.
        DispatchQueue.main.async { [weak map] in
            guard let map else { return }
            context.coordinator.installGestureHooksIfNeeded(map)
        }

        // Initial tide state
        context.coordinator.currentTideBlend = tideBlend
        context.coordinator.lastTideBlend = tideBlend
        context.coordinator.applyTideBlend(on: map, value: tideBlend)

        // Initial cursor/waypoints/radio pins
        context.coordinator.syncWaypointAnnotations(on: map, waypoints: waypoints)
        context.coordinator.syncRadioPinAnnotations(on: map, pins: radioPins)
        context.coordinator.syncCursorAnnotation(on: map, cursor: cursorCoordinate)
        context.coordinator.startPinFadeTimerIfNeeded()
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // keep tiles sticky after downloads/deletes
        installOrRefreshAllMBTilesOverlays(on: map, coordinator: context.coordinator)

        // Keep gesture hooks attached in case MapKit adds recognizers after view creation.
        // Only re-run occasionally to avoid spamming logs.
        if context.coordinator.lastGestureHookRefresh != followUserRequest + recenterRequest + zoomInRequest + zoomOutRequest {
            context.coordinator.lastGestureHookRefresh = followUserRequest + recenterRequest + zoomInRequest + zoomOutRequest
            context.coordinator.installGestureHooksIfNeeded(map)
        }


        // tide change
        if context.coordinator.lastTideBlend != tideBlend {
            context.coordinator.lastTideBlend = tideBlend
            context.coordinator.currentTideBlend = tideBlend
            context.coordinator.applyTideBlend(on: map, value: tideBlend)
        }

        // cursor/waypoints/radio pins sync
        context.coordinator.syncWaypointAnnotations(on: map, waypoints: waypoints)
        context.coordinator.syncRadioPinAnnotations(on: map, pins: radioPins)
        context.coordinator.syncCursorAnnotation(on: map, cursor: cursorCoordinate)

        // Cursor pan requests (ONE-SHOT center to the current cursorCoordinate)
        if context.coordinator.lastCursorPanReq != cursorPanRequest {
            context.coordinator.lastCursorPanReq = cursorPanRequest

            guard let c = cursorCoordinate else {
                context.coordinator.uiLog("CursorPan -> no cursor coordinate; abort")
                return
            }

            // User-entered cursor coordinate implies manual cursor mode.
            context.coordinator.cursorFollowsUser = false

            context.coordinator.uiLog("CursorPan -> setCenter(animated: true) to \(c.latitude), \(c.longitude)")
            context.coordinator.withProgrammaticRegionChange(timeout: 1.2) {
                map.setCenter(c, animated: true)
            }
        }

        // Zoom button requests
        if context.coordinator.lastZoomInReq != zoomInRequest {
            context.coordinator.lastZoomInReq = zoomInRequest
            context.coordinator.zoom(map, delta: +1)
        }
        if context.coordinator.lastZoomOutReq != zoomOutRequest {
            context.coordinator.lastZoomOutReq = zoomOutRequest
            context.coordinator.zoom(map, delta: -1)
        }

        // Follow button requests (toggle)
        if context.coordinator.lastFollowReq != followUserRequest {
            context.coordinator.lastFollowReq = followUserRequest

            context.coordinator.uiLog(
                "FollowButton tapped | swiftUI_isFollowingUser=\(isFollowingUser) coord_isFollowingUser(before)=\(context.coordinator.isFollowingUser) allowFollowNow=\(context.coordinator.allowFollowNow(on: map)) suppressUntil=\(context.coordinator.suppressFollowUntil)"
            )

            // Only the Follow button is allowed to change follow state.
            if isFollowingUser {
                // User is requesting Follow ON.
                if context.coordinator.allowFollowNow(on: map) {
                    context.coordinator.isFollowingUser = true
                    context.coordinator.onFollowStateChanged(true)
                    context.coordinator.uiLog("FollowButton result -> ON")
                } else {
                    context.coordinator.isFollowingUser = false
                    context.coordinator.onFollowStateChanged(false)
                    context.coordinator.uiLog("FollowButton result -> REFUSED (stayed OFF)")
                }
            } else {
                // User is requesting Follow OFF.
                context.coordinator.isFollowingUser = false
                context.coordinator.onFollowStateChanged(false)
                context.coordinator.uiLog("FollowButton result -> OFF")
            }

            // When Follow is toggled, optionally center once (only when turning ON)
            if let loc = map.userLocation.location?.coordinate, context.coordinator.isFollowingUser {
                context.coordinator.uiLog("FollowButton centerOnce -> setCenter(animated: true)")
                context.coordinator.withProgrammaticRegionChange(timeout: 1.2) {
                    map.setCenter(loc, animated: true)
                }
            } else {
                context.coordinator.uiLog("FollowButton centerOnce -> skipped (no loc or follow OFF)")
            }

            // Follow-taps re-pin the cursor
            context.coordinator.snapCursorToUser(on: map)
        }

        // Recenter button requests (ONE-SHOT center)
        // ✅ NEW: If recenter is pressed while Follow is ON, turn Follow OFF first.
        if context.coordinator.lastRecenterReq != recenterRequest {
            context.coordinator.lastRecenterReq = recenterRequest
            context.coordinator.uiLog(
                "RecenterButton tapped | coord_isFollowingUser(before)=\(context.coordinator.isFollowingUser) suppressUntil=\(context.coordinator.suppressFollowUntil)"
            )
            // If Follow is currently on, disengage it so we DON'T snap back on the next GPS tick.
            if context.coordinator.isFollowingUser {
                context.coordinator.uiLog("RecenterButton -> disengageFollow() then suppressFollowAfterUserAction()")
                // Turn Follow OFF when recenter is pressed so the next GPS tick can't snap back.
                // `disengageFollow()` will also update the SwiftUI binding via `onFollowStateChanged(false)`.
                context.coordinator.disengageFollow()
                // Give a little extra suppression to avoid an immediate re-center while the user starts panning.
                context.coordinator.suppressFollowAfterUserAction()
            }

            if map.userLocation.location?.coordinate == nil {
                context.coordinator.uiLog("RecenterButton -> no user location yet; abort")
            }

            guard let loc = map.userLocation.location?.coordinate else { return }

            context.coordinator.uiLog("RecenterButton -> setCenter(animated: true)")
            // One-shot center only
            context.coordinator.withProgrammaticRegionChange(timeout: 1.2) {
                map.setCenter(loc, animated: true)
            }

            // Optional: re-pin cursor on recenter
            context.coordinator.snapCursorToUser(on: map)
        }
    }

    // MARK: - Boundaries

    private func installDistrictBoundaries(on map: MKMapView, coordinator: Coordinator) {
        if coordinator.boundariesInstalled { return }
        coordinator.boundariesInstalled = true

        guard let boundariesURL = Bundle.main.url(forResource: "District_Boundaries_Final", withExtension: "geojson") else {
            print("❌ District_Boundaries_Final.geojson not found in bundle")
            return
        }

        do {
            let data = try Data(contentsOf: boundariesURL)
            let objects = try MKGeoJSONDecoder().decode(data)

            var polylines: [MKPolyline] = []

            for obj in objects {
                guard let feature = obj as? MKGeoJSONFeature else { continue }
                for geom in feature.geometry {
                    if let l = geom as? MKPolyline { polylines.append(l) }
                    else if let ml = geom as? MKMultiPolyline { polylines.append(contentsOf: ml.polylines) }
                }
            }

            coordinator.boundaryLines = polylines
            polylines.forEach { map.addOverlay($0, level: .aboveLabels) }
            print("✅ District boundaries loaded:", polylines.count)
        } catch {
            print("❌ District boundaries GeoJSON error:", error)
        }
    }

    // MARK: - MBTiles installs
    private func installOrRefreshAllMBTilesOverlays(on map: MKMapView, coordinator: Coordinator) {

        var shouldHave: Set<OfflinePack> = []

        for pack in availablePacks {
            let url = OfflineMapsManager.shared.localMBTilesURL(for: pack)
            if FileManager.default.fileExists(atPath: url.path) {
                shouldHave.insert(pack)
            }
        }

        // Remove missing
        let toRemove = coordinator.installedTilePacks.subtracting(shouldHave)
        if !toRemove.isEmpty {
            for pack in toRemove {
                if let overlay = coordinator.tileOverlays[pack] {
                    map.removeOverlay(overlay)
                }
                coordinator.tileOverlays[pack] = nil
            }
            coordinator.installedTilePacks.subtract(toRemove)
        }

        // Add new
        let toAddSet = shouldHave.subtracting(coordinator.installedTilePacks)
        if !toAddSet.isEmpty {

            let toAdd = toAddSet.sorted { a, b in
                if a.district.rawValue != b.district.rawValue { return a.district.rawValue < b.district.rawValue }
                let aIsBase = (a.slug == a.district.rawValue)
                let bIsBase = (b.slug == b.district.rawValue)
                if aIsBase != bIsBase { return aIsBase && !bIsBase }
                return a.slug < b.slug
            }

            for pack in toAdd {
                let url = OfflineMapsManager.shared.localMBTilesURL(for: pack)
                let overlay = MBTilesOverlay(mbtilesURL: url, slug: pack.slug)
                overlay.minimumZ = minZForTiles
                overlay.maximumZ = maxZForTiles
                map.addOverlay(overlay, level: .aboveRoads)

                coordinator.tileOverlays[pack] = overlay
                coordinator.installedTilePacks.insert(pack)
            }

            coordinator.applyTideBlend(on: map, value: coordinator.currentTideBlend)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {

        weak var mapView: MKMapView?

        let minZForTiles: Int
        let maxZ: Double
        let maxZForTiles: Int
        let initialLaunchZoom: Double

        func disengageFollow() {
            dlog("disengageFollow() called")
            suppressFollow(for: 1.0)
            mapView?.userTrackingMode = .none

            isFollowingUser = false
            onFollowStateChanged(false)

            // Reset smoothing so we don’t “ease back” after disabling follow.
            filteredFollowCoord = nil
            lastCameraCenterCoord = nil
            filteredCourseDegrees = nil
        }

        /// Returns true if it's safe to (re)engage Follow right now.
        /// We block Follow during gesture interaction and for a short suppression window
        /// to prevent "snap back" right after the user pans/zooms.
        func allowFollowNow(on mapView: MKMapView) -> Bool {
            if Date() <= suppressFollowUntil {
                dlog("allowFollowNow=false (suppressed) until=\(suppressFollowUntil)")
                return false
            }
            if regionChangeFromUserInteraction {
                dlog("allowFollowNow=false (regionChangeFromUserInteraction)")
                return false
            }
            if userIsInteracting(with: mapView) {
                dlog("allowFollowNow=false (userIsInteracting)")
                return false
            }
            return true
        }
        // MARK: - Debug logging
        private let followDebug = true

        private func dlog(_ msg: String) {
            guard followDebug else { return }
            print("🧭 FollowDebug | \(msg)")
        }
        // MARK: - UI-triggered logging (callable from updateUIView)
        func uiLog(_ msg: String) {
            dlog("UI | \(msg)")
        }

        private func grStateName(_ s: UIGestureRecognizer.State) -> String {
            switch s {
            case .possible: return "possible"
            case .began: return "began"
            case .changed: return "changed"
            case .ended: return "ended"
            case .cancelled: return "cancelled"
            case .failed: return "failed"
            @unknown default: return "unknown"
            }
        }
        
        var lastFollowReq: Int = 0
        var lastRecenterReq: Int = 0
        var lastZoomInReq: Int = 0
        var lastZoomOutReq: Int = 0
        var lastCursorPanReq: Int = 0
        
        private func userIsInteracting(with mapView: MKMapView) -> Bool {
            for gr in mapView.gestureRecognizers ?? [] {
                switch gr.state {
                case .began, .changed:
                    return true
                default:
                    continue
                }
            }
            return false
        }        // MARK: - Zoom buttons (+ / -)


        func zoom(_ mapView: MKMapView, delta: Int) {
            // delta: +1 zoom in, -1 zoom out
            let currentZoom = zoomLevel(for: mapView)

            // IMPORTANT:
            // - Do NOT clamp zoom-out to `minZForTiles`. That value is for tile visibility, not user zoom range.
            // - Allow zooming out to the full world (0.0). Keep the max zoom-in clamp for your app.
            let targetZoom = max(0.0, min(maxZ, currentZoom + Double(delta)))
            guard targetZoom.isFinite else { return }

            let center = mapView.centerCoordinate
            let rect = mapRect(center: center, zoom: targetZoom, in: mapView)
            mapView.setVisibleMapRect(rect, animated: false)

            // Kick the render loop so overlays update immediately
            DispatchQueue.main.async {
                mapView.setVisibleMapRect(mapView.visibleMapRect, animated: false)
                mapView.setNeedsLayout()
                mapView.layoutIfNeeded()
                mapView.setNeedsDisplay()
            }
        }


        var lastTideBlend: Double = -1
        var currentTideBlend: Double = 0.0

        private let onDistanceText: (String) -> Void
        private let onSpeedText: (String) -> Void
        private let onMetersPerPoint: (Double) -> Void
        let onFollowStateChanged: (Bool) -> Void
        private let onCursorUpdated: (CLLocationCoordinate2D?, String, String) -> Void

        var isFollowingUser: Bool = false

        // Cursor
        private var cursorTapInstalled = false
        private var cursorAnnotation: CursorAnnotation?
        
        var suppressFollowUntil: Date = .distantPast

        private func suppressFollow(for seconds: TimeInterval) {
            suppressFollowUntil = Date().addingTimeInterval(seconds)
        }

        /// Extra suppression after explicit user actions (like tapping Recenter) so the next GPS tick
        /// can't immediately snap the map back.
        func suppressFollowAfterUserAction() {
            suppressFollow(for: 2.0)
        }
        // Waypoints annotations keyed by id
        private var waypointAnnotations: [UUID: WaypointAnnotation] = [:]

        // Radio Group pin annotations keyed by id string
        private var radioPinAnnotations: [String: RadioPinAnnotation] = [:]
        // MARK: - Radio pin fade (all pins; live pins fade based on last update time)
        private var pinFadeTimer: Timer?

        func startPinFadeTimerIfNeeded() {
            guard pinFadeTimer == nil else { return }

            pinFadeTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
                guard let self, let mapView = self.mapView else { return }
                self.refreshRadioPinColors(on: mapView)
            }
            RunLoop.main.add(pinFadeTimer!, forMode: .common)
        }

        deinit {
            pinFadeTimer?.invalidate()
            pinFadeTimer = nil
        }

        private func mix(_ a: UIColor, _ b: UIColor, t: CGFloat) -> UIColor {
            let t = max(0, min(1, t))
            var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
            var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
            a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
            b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
            return UIColor(
                red: ar + (br - ar) * t,
                green: ag + (bg - ag) * t,
                blue: ab + (bb - ab) * t,
                alpha: aa + (ba - aa) * t
            )
        }

        private func tintColor(for pin: RadioPinAnnotation) -> UIColor {
            // Live pins fade too (based on pin.createdAt, which for live pins is set to last-updated time)

            // Pins fade in 6 steps (10 min each) -> fully gray at 60 min
            let age = max(0, Date().timeIntervalSince(pin.createdAt))
            let stepSeconds: TimeInterval = 10 * 60
            let steps: Double = 6
            let idx = min(Int(age / stepSeconds), Int(steps))
            let t = CGFloat(Double(idx) / steps) // 0.0 ... 1.0

            return mix(.systemGreen, .systemGray, t: t)
        }

        private func refreshRadioPinColors(on mapView: MKMapView) {
            for (_, ann) in radioPinAnnotations {
                if let v = mapView.view(for: ann) as? MKMarkerAnnotationView {
                    v.markerTintColor = tintColor(for: ann)
                }
            }
        }

        // Follow throttle
        private var lastFollowCenter: Date = .distantPast
        // One-time initial center/zoom on first good GPS fix
        var didLaunchCenter: Bool = false

        // Boundaries
        var boundariesInstalled: Bool = false
        var boundaryLines: [MKPolyline] = []
        var nearestLine: MKPolyline?
        private var lastNearestBoundaryCoord: CLLocationCoordinate2D?

        // Tiles installed
        var installedTilePacks: Set<OfflinePack> = []
        var tileOverlays: [OfflinePack: MKTileOverlay] = [:]

        // Scale output
        private(set) var metersPerPoint: Double = 0
        
        // Cursor behavior
        var cursorFollowsUser: Bool = true
        
        // MARK: - Follow smoothing
        // Smoothed coordinate used for camera follow + (optionally) cursor follow.
        private var filteredFollowCoord: CLLocationCoordinate2D?
        private var lastCameraCenterCoord: CLLocationCoordinate2D?

        // Smoothed course to reduce heading jitter at low speeds.
        private var filteredCourseDegrees: CLLocationDirection?

        private func knots(from speedMps: CLLocationSpeed) -> Double {
            let mps = max(speedMps, 0)
            let k = mps * 1.943844
            return k.isFinite ? k : 0
        }

        private func followAlpha(for speedKnots: Double) -> Double {
            // Smaller alpha = smoother but more lag.
            switch speedKnots {
            case ..<2:   return 0.08
            case ..<10:  return 0.15
            case ..<20:  return 0.25
            default:     return 0.35
            }
        }

        private func followDeadbandMeters(for speedKnots: Double) -> Double {
            // Prevent tiny GPS wiggles from moving the camera.
            switch speedKnots {
            case ..<2:   return 3.0
            case ..<10:  return 2.0
            case ..<20:  return 3.0
            default:     return 5.0
            }
        }

        private func followMinInterval(for speedKnots: Double) -> TimeInterval {
            // Target camera update rates:
            // <10 kn: ~4 Hz, 10–30 kn: ~5–6 Hz
            return (speedKnots < 10) ? 0.25 : 0.18
        }

        private func shouldUseFixForFollow(_ loc: CLLocation) -> Bool {
            // Block obviously bad fixes from moving the follow camera.
            if loc.horizontalAccuracy < 0 { return false }
            if loc.horizontalAccuracy > 30 { return false }
            if abs(loc.timestamp.timeIntervalSinceNow) > 5 { return false }
            return true
        }

        private func lowPass(old: Double, new: Double, alpha: Double) -> Double {
            old + alpha * (new - old)
        }

        private func smoothedFollowCoordinate(from loc: CLLocation) -> CLLocationCoordinate2D {
            let kts = knots(from: loc.speed)
            let a = followAlpha(for: kts)

            let raw = loc.coordinate
            guard let prev = filteredFollowCoord else {
                filteredFollowCoord = raw
                return raw
            }

            // If fix is bad, keep previous.
            guard shouldUseFixForFollow(loc) else {
                return prev
            }

            let lat = lowPass(old: prev.latitude, new: raw.latitude, alpha: a)
            let lon = lowPass(old: prev.longitude, new: raw.longitude, alpha: a)
            let out = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            filteredFollowCoord = out
            return out
        }

        private func shortestAngleDelta(from a: Double, to b: Double) -> Double {
            // returns delta in (-180, 180]
            var d = (b - a).truncatingRemainder(dividingBy: 360)
            if d <= -180 { d += 360 }
            if d > 180 { d -= 360 }
            return d
        }

        private func smoothedCourseDegrees(from loc: CLLocation) -> CLLocationDirection? {
            let kts = knots(from: loc.speed)
            // At very low speed, course is mostly noise.
            if kts < 1.5 { return nil }

            let raw = loc.course
            guard raw.isFinite, raw >= 0 else { return nil }

            // Smooth course a bit; more smoothing at lower speeds.
            let alpha: Double = (kts < 10) ? 0.20 : 0.35

            guard let prev = filteredCourseDegrees else {
                filteredCourseDegrees = raw
                return raw
            }

            let d = shortestAngleDelta(from: prev, to: raw)
            let next = (prev + alpha * d).truncatingRemainder(dividingBy: 360)
            let out = next < 0 ? next + 360 : next
            filteredCourseDegrees = out
            return out
        }
        
        // Distinguish our own setCenter/setVisibleMapRect calls from user gestures
        private var programmaticRegionChangeUntil: Date = .distantPast

        /// Wrap programmatic map region changes so `regionWillChange/DidChange` don't treat them as user gestures.
        /// For animated changes, MapKit callbacks can arrive after the next runloop tick, so we keep a timeout.
        func withProgrammaticRegionChange(timeout: TimeInterval = 1.0, _ block: () -> Void) {
            programmaticRegionChangeUntil = Date().addingTimeInterval(timeout)
            block()

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                if Date() >= self.programmaticRegionChangeUntil {
                    self.programmaticRegionChangeUntil = .distantPast
                }
            }
        }

        private var programmaticRegionChange: Bool {
            Date() <= programmaticRegionChangeUntil
        }
        func snapCursorToUser(on mapView: MKMapView) {
            guard let userLoc = mapView.userLocation.location else { return }
            cursorFollowsUser = true
            setCursor(userLoc.coordinate, on: mapView)
        }

        // Gestures
        private var gestureHooksInstalled = false
        private var regionChangeFromUserInteraction = false

        // Stable associated-object keys (must be pointer-stable)
        private static var bbFollowHookedKey: UInt8 = 0
        private static var bbFollowDetectorKey: UInt8 = 0
        var lastGestureHookRefresh: Int = 0

        // Annotation view ids
        let userViewReuseID = "CourseTriangleUserView"

        init(
            minZForTiles: Int,
            maxZ: Double,
            maxZForTiles: Int,
            initialLaunchZoom: Double,
            onDistanceText: @escaping (String) -> Void,
            onSpeedText: @escaping (String) -> Void,
            onMetersPerPoint: @escaping (Double) -> Void,
            onFollowStateChanged: @escaping (Bool) -> Void,
            onCursorUpdated: @escaping (CLLocationCoordinate2D?, String, String) -> Void
        ) {
            self.minZForTiles = minZForTiles
            self.maxZ = maxZ
            self.maxZForTiles = maxZForTiles
            self.initialLaunchZoom = initialLaunchZoom
            self.onDistanceText = onDistanceText
            self.onSpeedText = onSpeedText
            self.onMetersPerPoint = onMetersPerPoint
            self.onFollowStateChanged = onFollowStateChanged
            self.onCursorUpdated = onCursorUpdated
        }

        // MARK: - Cursor tap

        func installCursorTapIfNeeded(_ mapView: MKMapView) {
            guard !cursorTapInstalled else { return }
            cursorTapInstalled = true

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleCursorTap(_:)))
            tap.cancelsTouchesInView = false
            mapView.addGestureRecognizer(tap)
        }

        @objc private func handleCursorTap(_ gr: UITapGestureRecognizer) {
            guard let mapView = self.mapView else { return }

            let pt = gr.location(in: mapView)
            let coord = mapView.convert(pt, toCoordinateFrom: mapView)

            // User manually placed cursor → stop following user
            cursorFollowsUser = false
            setCursor(coord, on: mapView)
        }

        private func setCursor(_ coord: CLLocationCoordinate2D, on mapView: MKMapView) {
            if let a = cursorAnnotation {
                a.coordinate = coord
            } else {
                let a = CursorAnnotation()
                a.coordinate = coord
                cursorAnnotation = a
                mapView.addAnnotation(a)
            }

            let distText: String
            if let userLoc = mapView.userLocation.location {
                let cursorLoc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                distText = formatDistance(userLoc.distance(from: cursorLoc))
            } else {
                distText = "—"
            }

            let coordText = degreesDecimalMinutes(coord)
            onCursorUpdated(coord, distText, coordText)
        }

        func syncCursorAnnotation(on mapView: MKMapView, cursor: CLLocationCoordinate2D?) {
            // If SwiftUI hasn't provided a cursor coordinate yet, treat that as
            // "cursor follows user" mode (default behavior). This prevents updateUIView
            // from removing the cursor annotation while didUpdate is trying to keep it
            // pinned to the user.
            guard let cursor else {
                // Ensure we have a valid user fix before snapping.
                if let userLoc = mapView.userLocation.location {
                    cursorFollowsUser = true
                    setCursor(userLoc.coordinate, on: mapView)
                } else {
                    // No user fix yet; keep UI placeholders.
                    onCursorUpdated(nil, "—", "—")
                }
                return
            }

            // If SwiftUI provides a coordinate, honor it (manual cursor placement).
            setCursor(cursor, on: mapView)
        }

        // MARK: - Waypoints sync

        func syncWaypointAnnotations(on mapView: MKMapView, waypoints: [Waypoint]) {
            let wanted = Set(waypoints.map { $0.id })
            let existing = Set(waypointAnnotations.keys)

            for id in existing.subtracting(wanted) {
                if let ann = waypointAnnotations[id] {
                    mapView.removeAnnotation(ann)
                }
                waypointAnnotations[id] = nil
            }

            for wp in waypoints {
                if let ann = waypointAnnotations[wp.id] {
                    // Update annotation in-place
                    ann.coordinate = wp.coordinate
                    ann.title = wp.displayName

                    // ✅ Ensure the visible label updates immediately when name changes
                    if let v = mapView.view(for: ann) as? WaypointAnnotationView {
                        v.setLabel(ann.title ?? "")
                    }
                } else {
                    let ann = WaypointAnnotation(id: wp.id)
                    ann.coordinate = wp.coordinate
                    ann.title = wp.displayName
                    waypointAnnotations[wp.id] = ann
                    mapView.addAnnotation(ann)

                    // ✅ After the view is created, set the label (MapKit may create it on the next runloop)
                    DispatchQueue.main.async {
                        if let v = mapView.view(for: ann) as? WaypointAnnotationView {
                            v.setLabel(ann.title ?? "")
                        }
                    }
                }
            }
        }

        // MARK: - Radio Group pins sync

        func syncRadioPinAnnotations(on mapView: MKMapView, pins: [RadioGroupStore.Pin]) {
            // Use a string key so we don’t care if Pin.id is UUID/String/etc.
            let wanted = Set(pins.map { String(describing: $0.id) })
            let existing = Set(radioPinAnnotations.keys)

            // Remove old pins
            for id in existing.subtracting(wanted) {
                if let ann = radioPinAnnotations[id] {
                    mapView.removeAnnotation(ann)
                }
                radioPinAnnotations[id] = nil
            }

            // Add/update pins
            for p in pins {
                let id = String(describing: p.id)
                let coord = p.coordinate

                if let ann = radioPinAnnotations[id] {
                    ann.coordinate = coord
                    ann.title = p.titleText
                    ann.subtitle = p.subtitleText
                    ann.createdAt = p.createdAt
                    ann.isLivePin = p.isLive
                } else {
                    let ann = RadioPinAnnotation(id: id)
                    ann.coordinate = coord
                    ann.title = p.titleText
                    ann.subtitle = p.subtitleText
                    ann.createdAt = p.createdAt
                    ann.isLivePin = p.isLive
                    radioPinAnnotations[id] = ann
                    mapView.addAnnotation(ann)
                }
            }

            // Apply correct tint immediately (timer handles ongoing fades)
            refreshRadioPinColors(on: mapView)
        }
        
        // MARK: - Tide blending (egegik v1 <-> egegik_v2)

        func applyTideBlend(on mapView: MKMapView, value: Double) {
            let v = max(0.0, min(1.0, value))
            currentTideBlend = v

            let egegikOverlays: [MBTilesOverlay] = mapView.overlays
                .compactMap { $0 as? MBTilesOverlay }
                .filter { $0.slug == "egegik" || $0.slug == "egegik_v2" }

            for overlay in egegikOverlays {
                let alpha: CGFloat = (overlay.slug == "egegik") ? CGFloat(1.0 - v) : CGFloat(v)
                if let r = mapView.renderer(for: overlay) as? MKTileOverlayRenderer {
                    r.alpha = alpha
                    r.reloadData()
                    r.setNeedsDisplay()
                }
            }

            // Force redraw NOW (most reliable)
            if !egegikOverlays.isEmpty {
                egegikOverlays.forEach { mapView.removeOverlay($0) }
                egegikOverlays.forEach { mapView.addOverlay($0, level: .aboveRoads) }
            }

            DispatchQueue.main.async {
                mapView.setVisibleMapRect(mapView.visibleMapRect, animated: false)
                mapView.setNeedsLayout()
                mapView.layoutIfNeeded()
                mapView.setNeedsDisplay()
            }
        }

        // MARK: - Gesture hooks

        func installGestureHooksIfNeeded(_ mapView: MKMapView) {
            // MapKit may attach recognizers to subviews, so walk the full hierarchy.
            func allViews(from root: UIView) -> [UIView] {
                var out: [UIView] = [root]
                for v in root.subviews {
                    out.append(contentsOf: allViews(from: v))
                }
                return out
            }

            let views = allViews(from: mapView)

            // Count recognizers we can see (for debugging).
            let totalRecognizers = views.reduce(0) { $0 + ( $1.gestureRecognizers?.count ?? 0 ) }
            dlog("installGestureHooksIfNeeded views=\(views.count) totalRecognizers=\(totalRecognizers)")

            // Hook every recognizer we can find.
            for v in views {
                for gr in (v.gestureRecognizers ?? []) {
                    if objc_getAssociatedObject(gr, &Self.bbFollowHookedKey) as? Bool == true {
                        continue
                    }
                    gr.addTarget(self, action: #selector(handleGesture(_:)))
                    objc_setAssociatedObject(gr, &Self.bbFollowHookedKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                    dlog("hooked recognizer \(type(of: gr)) on \(type(of: v))")
                }
            }

            // Add our own detectors once (guarantees we see pans/zooms even if MapKit hides its recognizers).
            if objc_getAssociatedObject(mapView, &Self.bbFollowDetectorKey) as? Bool != true {
                let pan = UIPanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
                pan.cancelsTouchesInView = false
                pan.delegate = self

                let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
                pinch.cancelsTouchesInView = false
                pinch.delegate = self

                mapView.addGestureRecognizer(pan)
                mapView.addGestureRecognizer(pinch)

                objc_setAssociatedObject(mapView, &Self.bbFollowDetectorKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                dlog("added follow detector recognizers (pan+pinch)")
            }

            gestureHooksInstalled = true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc private func handleGesture(_ gr: UIGestureRecognizer) {
            dlog("handleGesture \(type(of: gr)) state=\(grStateName(gr.state)) isFollowing=\(isFollowingUser) suppressUntil=\(suppressFollowUntil)")
            if gr.state == .began || gr.state == .changed {
                regionChangeFromUserInteraction = true

                // Immediately disengage Follow on any user pan/zoom gesture.
                // This must also update the SwiftUI binding via onFollowStateChanged.
                if isFollowingUser {
                    disengageFollow()
                }

            } else if gr.state == .ended || gr.state == .cancelled || gr.state == .failed {

                // Keep follow suppressed through deceleration + next likely GPS tick.
                suppressFollow(for: 2.0)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                    self?.regionChangeFromUserInteraction = false
                }
            }
        }

        // MARK: - Map callbacks

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            dlog("regionWillChange programmatic=\(programmaticRegionChange) interacting=\(userIsInteracting(with: mapView)) isFollowing=\(isFollowingUser)")
            // MapKit can still be in a "programmatic" window when the user begins to pan
            // (e.g., right after an animated setCenter). So we must check the gesture states.
            if userIsInteracting(with: mapView) {
                regionChangeFromUserInteraction = true
                disengageFollow()   // user gesture => Follow OFF
            }
        }
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            dlog("didChangeVisibleRegion interacting=\(userIsInteracting(with: mapView)) isFollowing=\(isFollowingUser)")
            if userIsInteracting(with: mapView) {
                regionChangeFromUserInteraction = true
                if isFollowingUser {
                    disengageFollow()
                }
            }
            if mapView.camera.heading != 0 {
                var cam = mapView.camera
                cam.heading = 0
                withProgrammaticRegionChange(timeout: 0.3) {
                    mapView.camera = cam
                }
            }

            clampZoomIfNeeded(mapView)
            updateScale(mapView)
            refreshUserMarker(mapView)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // If a gesture caused this region change, suppress follow briefly after the gesture ends.
            if regionChangeFromUserInteraction {
                suppressFollow(for: 2.0)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.regionChangeFromUserInteraction = false
                }
            }

            clampZoomIfNeeded(mapView)
            updateScale(mapView)
            refreshUserMarker(mapView)
        }
        // MARK: - Scale

        func updateScale(_ mapView: MKMapView) {
            let viewW = Double(max(mapView.bounds.size.width, 1))
            let mapPointsPerPoint = mapView.visibleMapRect.size.width / viewW

            let lat = mapView.centerCoordinate.latitude
            let metersPerMapPoint = MKMetersPerMapPointAtLatitude(lat)

            let mpp = mapPointsPerPoint * metersPerMapPoint
            let safe = (mpp.isFinite && mpp > 0) ? mpp : 0

            if abs(safe - metersPerPoint) > 1e-9 {
                metersPerPoint = safe
                onMetersPerPoint(safe)
            }
        }

        // MARK: - Zoom clamp

        private func clampZoomIfNeeded(_ mapView: MKMapView) {
            let currentZoom = zoomLevel(for: mapView)
            guard currentZoom > maxZ else { return }

            let center = mapView.centerCoordinate
            let clampedRect = mapRect(center: center, zoom: maxZ, in: mapView)
            withProgrammaticRegionChange(timeout: 0.6) {
                mapView.setVisibleMapRect(clampedRect, animated: false)
            }
        }

        private func zoomLevel(for mapView: MKMapView) -> Double {
            let mapRectWidth = mapView.visibleMapRect.size.width
            let viewWidth = Double(max(mapView.bounds.size.width, 1))
            let zoomScale = mapRectWidth / viewWidth

            let worldWidth = MKMapSize.world.width
            let z = log2(worldWidth / (256.0 * zoomScale))
            return z.isFinite ? z : 0
        }

        private func mapRect(center: CLLocationCoordinate2D, zoom: Double, in mapView: MKMapView) -> MKMapRect {
            let centerPoint = MKMapPoint(center)

            let worldWidth = MKMapSize.world.width
            let desiredZoomScale = worldWidth / (256.0 * pow(2.0, zoom))

            let viewW = Double(max(mapView.bounds.size.width, 1))
            let viewH = Double(max(mapView.bounds.size.height, 1))

            let rectW = desiredZoomScale * viewW
            let rectH = desiredZoomScale * viewH

            let origin = MKMapPoint(
                x: centerPoint.x - rectW / 2.0,
                y: centerPoint.y - rectH / 2.0
            )

            return MKMapRect(origin: origin, size: MKMapSize(width: rectW, height: rectH))
        }

        // MARK: - User updates

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard let loc = userLocation.location else {
                refreshUserMarker(mapView)
                return
            }

            dlog("didUpdateUserLocation isFollowing=\(isFollowingUser) allowFollowNow=\(allowFollowNow(on: mapView)) acc=\(loc.horizontalAccuracy) age=\(abs(loc.timestamp.timeIntervalSinceNow))")

            // ✅ One-time initial center/zoom when we get our first good fix
            if !didLaunchCenter {
                didLaunchCenter = true
                let rect = mapRect(center: loc.coordinate, zoom: initialLaunchZoom, in: mapView)
                withProgrammaticRegionChange(timeout: 1.2) {
                    mapView.setVisibleMapRect(rect, animated: false)
                }
            }

            // Follow behavior (GPS tick):
            // Only recenter when Follow is ON *and* it's safe (not suppressed, not interacting).
            if isFollowingUser && allowFollowNow(on: mapView) {
                let kts = knots(from: loc.speed)
                let minInterval = followMinInterval(for: kts)

                let now = Date()
                if now.timeIntervalSince(lastFollowCenter) >= minInterval {
                    let target = smoothedFollowCoordinate(from: loc)
                    let deadband = followDeadbandMeters(for: kts)

                    let shouldMove: Bool
                    if let last = lastCameraCenterCoord {
                        let a = CLLocation(latitude: last.latitude, longitude: last.longitude)
                        let b = CLLocation(latitude: target.latitude, longitude: target.longitude)
                        shouldMove = a.distance(from: b) >= deadband
                    } else {
                        shouldMove = true
                    }

                    if shouldMove {
                        lastFollowCenter = now
                        lastCameraCenterCoord = target
                        withProgrammaticRegionChange {
                            mapView.setCenter(target, animated: true)
                        }
                    }
                }
            }

            let kts = knots(from: loc.speed)
            let spd = kts.isFinite ? String(format: "%.1f kn", kts) : "—"
            onSpeedText(spd)

            updateNearestBoundary(to: loc.coordinate, in: mapView)
            refreshUserMarker(mapView)

            // Cursor behavior:
            // - If we're in "follow cursor" mode, keep cursor pinned to the user's location as they move.
            // - If user has tapped the map (manual cursor mode), just keep updating the distance readout as they move.
            if cursorFollowsUser {
                setCursor(loc.coordinate, on: mapView)   // also updates cursorDistanceText + cursorCoordText
            } else if let c = cursorAnnotation?.coordinate {
                let cursorLoc = CLLocation(latitude: c.latitude, longitude: c.longitude)
                let distText = formatDistance(loc.distance(from: cursorLoc))
                onCursorUpdated(c, distText, degreesDecimalMinutes(c))
            }
        }

        private func isGoodFix(_ loc: CLLocation) -> Bool {
            if loc.horizontalAccuracy < 0 { return false }
            if loc.horizontalAccuracy > 50 { return false }
            if abs(loc.timestamp.timeIntervalSinceNow) > 5 { return false }
            return true
        }

        // MARK: - Nearest boundary

        private func updateNearestBoundary(to coord: CLLocationCoordinate2D, in mapView: MKMapView) {
            guard !boundaryLines.isEmpty else {
                // Clear highlight if no boundaries
                if let old = nearestLine, let r = mapView.renderer(for: old) as? MKPolylineRenderer {
                    r.strokeColor = .black
                    r.setNeedsDisplay()
                }
                nearestLine = nil
                lastNearestBoundaryCoord = nil
                onDistanceText("—")
                return
            }

            let p = MKMapPoint(coord)

            var bestLine: MKPolyline?
            var bestClosestPoint: MKMapPoint?
            var bestPlanarMeters = Double.greatestFiniteMagnitude

            for line in boundaryLines {
                let res = nearestPointOnPolyline(to: p, polyline: line)
                if res.planarMeters < bestPlanarMeters {
                    bestPlanarMeters = res.planarMeters
                    bestLine = line
                    bestClosestPoint = res.closestPoint
                }
            }

            // Highlight the closest boundary line
            if let newLine = bestLine, nearestLine !== newLine {
                // revert old highlight
                if let old = nearestLine, let r = mapView.renderer(for: old) as? MKPolylineRenderer {
                    r.strokeColor = .black
                    r.setNeedsDisplay()
                }

                nearestLine = newLine

                // apply new highlight
                if let r = mapView.renderer(for: newLine) as? MKPolylineRenderer {
                    r.strokeColor = .red
                    r.setNeedsDisplay()
                } else {
                    mapView.setNeedsDisplay()
                }
            }

            guard let closestPoint = bestClosestPoint else {
                lastNearestBoundaryCoord = nil
                onDistanceText("—")
                return
            }

            let closestCoord = closestPoint.coordinate
            lastNearestBoundaryCoord = closestCoord

            // ✅ accurate geodesic distance
            let userLoc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            let boundaryLoc = CLLocation(latitude: closestCoord.latitude, longitude: closestCoord.longitude)
            let geodesicMeters = userLoc.distance(from: boundaryLoc)

            onDistanceText(formatDistance(geodesicMeters))
        }

        private func nearestPointOnPolyline(to point: MKMapPoint, polyline: MKPolyline) -> (closestPoint: MKMapPoint, planarMeters: Double) {
            let pts = polyline.points()
            let n = polyline.pointCount
            guard n >= 2 else { return (point, .greatestFiniteMagnitude) }

            var bestPoint = point
            var best = Double.greatestFiniteMagnitude

            for i in 0..<(n - 1) {
                let a = pts[i]
                let b = pts[i + 1]
                let res = nearestPointOnSegment(p: point, a: a, b: b)
                if res.planarMeters < best {
                    best = res.planarMeters
                    bestPoint = res.closestPoint
                }
            }
            return (bestPoint, best)
        }
        private func nearestPointOnSegment(p: MKMapPoint, a: MKMapPoint, b: MKMapPoint) -> (closestPoint: MKMapPoint, planarMeters: Double) {
            let ax = a.x, ay = a.y
            let bx = b.x, by = b.y
            let px = p.x, py = p.y

            let abx = bx - ax
            let aby = by - ay
            let apx = px - ax
            let apy = py - ay

            let ab2 = abx * abx + aby * aby
            if ab2 == 0 {
                let d = p.distance(to: a)
                return (a, d)
            }

            var t = (apx * abx + apy * aby) / ab2
            t = max(0, min(1, t))

            let cx = ax + t * abx
            let cy = ay + t * aby
            let c = MKMapPoint(x: cx, y: cy)

            return (c, p.distance(to: c))
        }

        private func formatDistance(_ meters: Double) -> String {
            if !meters.isFinite { return "—" }

            let feet = meters * 3.28084
            let miles = meters / 1609.344

            if miles >= 0.1 {
                return String(format: "%.1f mi", miles)
            } else {
                let rounded = (feet / 10.0).rounded() * 10.0
                return String(format: "%.0f ft", rounded)
            }
        }

        private func degreesDecimalMinutes(_ c: CLLocationCoordinate2D) -> String {
            func format(_ deg: Double, pos: String, neg: String) -> String {
                let hemisphere = deg >= 0 ? pos : neg
                let absDeg = abs(deg)
                let d = Int(absDeg)
                let minutes = (absDeg - Double(d)) * 60.0
                return String(format: "%d° %.3f' %@", d, minutes, hemisphere)
            }
            return "\(format(c.latitude, pos: "N", neg: "S"))  \(format(c.longitude, pos: "E", neg: "W"))"
        }

        // MARK: - Annotation views

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let p = annotation as? RadioPinAnnotation {
                let id = "RadioPinAnnotationView"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: p, reuseIdentifier: id)

                v.annotation = p
                v.canShowCallout = true
                v.displayPriority = .required
                v.markerTintColor = tintColor(for: p)
                v.glyphImage = UIImage(systemName: "antenna.radiowaves.left.and.right")
                v.rightCalloutAccessoryView = UIButton(type: .detailDisclosure)
                return v
            }

            if annotation is MKUserLocation {
                let v = mapView.dequeueReusableAnnotationView(
                    withIdentifier: userViewReuseID,
                    for: annotation
                ) as! CourseTriangleUserView
                v.annotation = annotation
                v.update(
                    courseDegrees: mapView.userLocation.location.flatMap { self.smoothedCourseDegrees(from: $0) },
                    hasGoodFix: mapView.userLocation.location.map(isGoodFix) ?? false,
                    screenLinePoints: Double(mapView.bounds.width) * 0.30
                )
                return v
            }

            if annotation is CursorAnnotation {
                let id = "CursorAnnotationView"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? CursorAnnotationView
                    ?? CursorAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                return v
            }

            if let w = annotation as? WaypointAnnotation {
                let id = "WaypointAnnotationView"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? WaypointAnnotationView
                    ?? WaypointAnnotationView(annotation: w, reuseIdentifier: id)
                v.annotation = w
                v.setLabel(w.title ?? "")
                return v
            }

            return nil
        }

        private func refreshUserMarker(_ mapView: MKMapView) {
            guard let v = mapView.view(for: mapView.userLocation) as? CourseTriangleUserView else { return }
            v.update(
                courseDegrees: mapView.userLocation.location?.course,
                hasGoodFix: mapView.userLocation.location.map(isGoodFix) ?? false,
                screenLinePoints: Double(mapView.bounds.width) * 0.30
            )
        }

        // MARK: - Renderers

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {

            if let tile = overlay as? MKTileOverlay {
                let r = MKTileOverlayRenderer(tileOverlay: tile)

                if let mb = tile as? MBTilesOverlay {
                    let v = max(0.0, min(1.0, currentTideBlend))
                    if mb.slug == "egegik" { r.alpha = CGFloat(1.0 - v) }
                    else if mb.slug == "egegik_v2" { r.alpha = CGFloat(v) }
                    else { r.alpha = 1.0 }
                }

                return r
            }

            if let line = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = (line === nearestLine) ? .red : .black
                r.lineWidth = 2
                return r
            }

            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - User Location View (unchanged)

final class CourseTriangleUserView: MKAnnotationView {

    private let triangleLayer = CAShapeLayer()
    private let courseLayer = CAShapeLayer()
    private var isFlashing = false

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        centerOffset = .zero

        triangleLayer.fillColor = UIColor(red: 0.05, green: 0.20, blue: 0.55, alpha: 1.0).cgColor
        triangleLayer.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        triangleLayer.lineWidth = 1.0

        courseLayer.strokeColor = UIColor(red: 0.05, green: 0.20, blue: 0.55, alpha: 0.95).cgColor
        courseLayer.lineWidth = 2.0
        courseLayer.lineCap = .round

        layer.addSublayer(courseLayer)
        layer.addSublayer(triangleLayer)

        redraw(linePoints: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(courseDegrees: CLLocationDirection?, hasGoodFix: Bool, screenLinePoints: Double) {
        let course = (courseDegrees ?? -1)
        if course.isFinite, course >= 0 {
            transform = CGAffineTransform(rotationAngle: CGFloat(course * .pi / 180.0))
            courseLayer.isHidden = false
        } else {
            transform = .identity
            courseLayer.isHidden = true
        }

        if hasGoodFix { stopFlashing() } else { startFlashing() }
        redraw(linePoints: max(0, min(screenLinePoints, 900)))
    }

    private func redraw(linePoints: Double) {
        let cx = bounds.width / 2
        let cy = bounds.height / 2

        let tip = CGPoint(x: cx, y: cy - 10)
        let left = CGPoint(x: cx - 8, y: cy + 10)
        let right = CGPoint(x: cx + 8, y: cy + 10)

        let tri = UIBezierPath()
        tri.move(to: tip)
        tri.addLine(to: left)
        tri.addLine(to: right)
        tri.close()
        triangleLayer.path = tri.cgPath

        let line = UIBezierPath()
        line.move(to: tip)
        line.addLine(to: CGPoint(x: tip.x, y: tip.y - linePoints))
        courseLayer.path = line.cgPath
    }

    private func startFlashing() {
        guard !isFlashing else { return }
        isFlashing = true

        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.25
        anim.duration = 0.6
        anim.autoreverses = true
        anim.repeatCount = .infinity
        layer.add(anim, forKey: "gpsFlash")
    }

    private func stopFlashing() {
        guard isFlashing else { return }
        isFlashing = false
        layer.removeAnimation(forKey: "gpsFlash")
        layer.opacity = 1.0
    }
}

// MARK: - Cursor + Waypoint + Radio Pin Annotations

final class CursorAnnotation: NSObject, MKAnnotation {
    dynamic var coordinate: CLLocationCoordinate2D = .init()
}

final class WaypointAnnotation: NSObject, MKAnnotation {
    let id: UUID
    dynamic var coordinate: CLLocationCoordinate2D
    dynamic var title: String?

    init(id: UUID) {
        self.id = id
        self.coordinate = .init()
        super.init()
    }
}

final class RadioPinAnnotation: NSObject, MKAnnotation {
    let id: String
    dynamic var coordinate: CLLocationCoordinate2D
    dynamic var title: String?
    dynamic var subtitle: String?

    // Used for fade logic
    var createdAt: Date = Date()
    var isLivePin: Bool = false

    init(id: String) {
        self.id = id
        self.coordinate = .init()
        super.init()
    }
}

final class CursorAnnotationView: MKAnnotationView {
    private let shape = CAShapeLayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        canShowCallout = false
        backgroundColor = .clear
        isOpaque = false

        frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        centerOffset = .zero

        // ✅ BLACK crosshairs, NO halo/shadow
        shape.strokeColor = UIColor.black.cgColor
        shape.fillColor = UIColor.clear.cgColor
        shape.lineWidth = 1
        shape.lineCap = .butt
        shape.lineJoin = .miter
        shape.contentsScale = UIScreen.main.scale
        shape.allowsEdgeAntialiasing = false

        layer.addSublayer(shape)

        // ✅ Hard kill any shadow
        layer.shadowOpacity = 0
        layer.shadowRadius = 0
        layer.shadowOffset = .zero
        layer.shadowColor = nil
        layer.shadowPath = nil

        // ✅ Avoid blur/halo from rasterization
        layer.shouldRasterize = false

        redraw()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // Make sure reuse never reintroduces shadow
        layer.shadowOpacity = 0
        layer.shadowRadius = 0
        layer.shadowOffset = .zero
        layer.shadowColor = nil
        layer.shadowPath = nil
        layer.shouldRasterize = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shape.contentsScale = UIScreen.main.scale
        shape.allowsEdgeAntialiasing = false
        redraw()
    }

    private func redraw() {
        let b = bounds
        let cx = b.midX
        let cy = b.midY
        let r: CGFloat = 8   // or whatever you’re using

        let p = UIBezierPath()

        // horizontal line
        p.move(to: CGPoint(x: cx - r, y: cy))
        p.addLine(to: CGPoint(x: cx + r, y: cy))

        // vertical line
        p.move(to: CGPoint(x: cx, y: cy - r))
        p.addLine(to: CGPoint(x: cx, y: cy + r))

        shape.path = p.cgPath
    }
}

private extension RadioGroupStore.Pin {
    var titleText: String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        let t = f.string(from: createdAt)

        let n = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return "Live location" }
        return "\(n), \(t)"
    }

    var subtitleText: String { "" }
}
final class WaypointAnnotationView: MKAnnotationView {
    private let dot = CAShapeLayer()
    private let label = UILabel()
    
    // Constants for anchoring
    private let dotSize: CGFloat = 10
    private let dotX: CGFloat = 0            // dot sits at the left edge
    private let dotY: CGFloat = 22           // dot sits near the bottom (room for label above)
    
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        
        // Start with a reasonable size; we’ll resize dynamically in `redraw()`.
        frame = CGRect(x: 0, y: 0, width: 140, height: 34)
        
        dot.fillColor = UIColor.systemRed.cgColor
        dot.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        dot.lineWidth = 1
        layer.addSublayer(dot)
        
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        label.layer.cornerRadius = 6
        label.layer.masksToBounds = true
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        
        redraw()
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        redraw()
    }
    
    func setLabel(_ text: String) {
        label.text = text
        setNeedsLayout()
    }
    
    private func redraw() {
        // Ensure we always have something to show.
        let txt = (label.text ?? "").isEmpty ? "WP" : (label.text ?? "")
        label.text = txt
        
        // Size label to content.
        label.sizeToFit()
        let labelW = min(max(label.bounds.width + 12, 36), 160)
        let labelH: CGFloat = 20
        
        // View sizing: dot on left, label to the right.
        let totalW = dotX + dotSize + 6 + labelW
        let totalH: CGFloat = 34
        
        // Update our own bounds (important for correct anchoring).
        bounds = CGRect(x: 0, y: 0, width: totalW, height: totalH)
        
        // Draw dot at left/bottom-ish.
        let dotRect = CGRect(x: dotX, y: dotY, width: dotSize, height: dotSize)
        dot.path = UIBezierPath(ovalIn: dotRect).cgPath
        
        // Place label to the right of the dot.
        label.frame = CGRect(
            x: dotX + dotSize + 6,
            y: 6,
            width: labelW,
            height: labelH
        )
        label.textAlignment = .center
        
        // ✅ CRITICAL FIX:
        // Anchor the coordinate to the DOT center (not the view center).
        let dotCenter = CGPoint(x: dotRect.midX, y: dotRect.midY)
        centerOffset = CGPoint(
            x: (bounds.width / 2.0) - dotCenter.x,
            y: (bounds.height / 2.0) - dotCenter.y
        )
        
        canShowCallout = false
    }
}
