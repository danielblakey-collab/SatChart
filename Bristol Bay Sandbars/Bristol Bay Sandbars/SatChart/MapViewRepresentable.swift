import SwiftUI
import MapKit
import CoreLocation
import UIKit
import Foundation

// MARK: - Waypoints model (FILE SCOPE so other views can use it)

struct Waypoint: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var notes: String
    var coordinate: CLLocationCoordinate2D
    var colorID: String

    /// When the waypoint was created on this device.
    var createdAt: Date

    /// UI state: whether the user has sent this waypoint to the Radio Group.
    var sentToGroup: Bool

    /// True if this waypoint was received from another Radio Group member (not created on this device).
    var isReceived: Bool

    /// Sender info for received waypoints (empty for local).
    var senderUid: String
    var senderName: String

    init(
        id: UUID = UUID(),
        name: String,
        notes: String = "",
        coordinate: CLLocationCoordinate2D,
        colorID: String = WaypointColorPreferences.ensureLocalDefaultColor().rawValue,
        createdAt: Date = Date(),
        sentToGroup: Bool = false,
        isReceived: Bool = false,
        senderUid: String = "",
        senderName: String = ""
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.coordinate = coordinate
        self.colorID = WaypointPinColor.safe(rawValue: colorID).rawValue
        self.createdAt = createdAt
        self.sentToGroup = sentToGroup
        self.isReceived = isReceived
        self.senderUid = senderUid
        self.senderName = senderName
    }

    var displayName: String { name }
    var pinColor: WaypointPinColor { WaypointPinColor.safe(rawValue: colorID) }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case notes
        case latitude
        case longitude
        case colorID
        case createdAt
        case sentToGroup
        case isReceived
        case senderUid
        case senderName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Waypoint"
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        let latitude = try container.decodeIfPresent(Double.self, forKey: .latitude) ?? 0
        let longitude = try container.decodeIfPresent(Double.self, forKey: .longitude) ?? 0
        coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let fallback = WaypointColorPreferences.ensureLocalDefaultColor()
        colorID = WaypointPinColor.safe(
            rawValue: try container.decodeIfPresent(String.self, forKey: .colorID),
            fallback: fallback
        ).rawValue
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        sentToGroup = try container.decodeIfPresent(Bool.self, forKey: .sentToGroup) ?? false
        isReceived = try container.decodeIfPresent(Bool.self, forKey: .isReceived) ?? false
        senderUid = try container.decodeIfPresent(String.self, forKey: .senderUid) ?? ""
        senderName = try container.decodeIfPresent(String.self, forKey: .senderName) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(notes, forKey: .notes)
        try container.encode(coordinate.latitude, forKey: .latitude)
        try container.encode(coordinate.longitude, forKey: .longitude)
        try container.encode(pinColor.rawValue, forKey: .colorID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(sentToGroup, forKey: .sentToGroup)
        try container.encode(isReceived, forKey: .isReceived)
        try container.encode(senderUid, forKey: .senderUid)
        try container.encode(senderName, forKey: .senderName)
    }

    static func == (lhs: Waypoint, rhs: Waypoint) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
// MARK: - Shared Waypoint Annotation (for Radio Group received waypoints)

final class SharedWaypointAnnotation: NSObject, MKAnnotation {
    let id: String
    dynamic var coordinate: CLLocationCoordinate2D
    dynamic var title: String?
    dynamic var subtitle: String?

    // Used for coloring + legend/callout
    var senderUid: String
    var senderName: String
    var colorID: String

    init(
        id: String,
        coordinate: CLLocationCoordinate2D,
        title: String?,
        subtitle: String?,
        senderUid: String,
        senderName: String,
        colorID: String
    ) {
        self.id = id
        self.coordinate = coordinate
        self.title = title
        self.subtitle = subtitle
        self.senderUid = senderUid
        self.senderName = senderName
        self.colorID = WaypointPinColor.safe(rawValue: colorID, fallback: WaypointPinColor.deterministicFallback(seed: senderUid)).rawValue
        super.init()
    }
}

struct MapViewRepresentable: UIViewRepresentable {

    let locationManager: LocationManager

    @Binding var distanceText: String
    @Binding var speedText: String
    @Binding var metersPerPoint: Double

    @Binding var followUserRequest: Int
    @Binding var recenterRequest: Int
    @Binding var isFollowingUser: Bool

    @Binding var selectedMapVersion: Int

    @Binding var cursorCoordinate: CLLocationCoordinate2D?
    @Binding var cursorDistanceText: String
    @Binding var cursorCoordText: String
    @Binding var cursorPanRequest: Int
    @Binding var isCursorTrackingUser: Bool

    @Binding var waypoints: [Waypoint]
    let receivedWaypoints: [RadioGroupStore.GroupWaypoint]
    let radioPins: [RadioGroupStore.Pin]
    let activeRadioGroupID: String?
    let radioMembers: [RadioGroupMember]

    @Binding var zoomInRequest: Int
    @Binding var zoomOutRequest: Int

    let basemapChoice: BasemapChoice
    let sstEnabled: Bool
    let sstOpacity: Double
    let sstSource: SeaSurfaceTemperatureSource
    let sstDateUTC: String
    let showPortMollerTestFisheryStations: Bool
    let showLiveLocationTrail: Bool
    let visibleFishingSets: [SmartFishingSetRecord]
    let onFishingSetDisplayPrompt: (UUID) -> Void

    init(
        locationManager: LocationManager,
        distanceText: Binding<String>,
        speedText: Binding<String>,
        metersPerPoint: Binding<Double>,
        followUserRequest: Binding<Int>,
        recenterRequest: Binding<Int>,
        isFollowingUser: Binding<Bool>,
        selectedMapVersion: Binding<Int>,
        cursorCoordinate: Binding<CLLocationCoordinate2D?>,
        cursorDistanceText: Binding<String>,
        cursorCoordText: Binding<String>,
        cursorPanRequest: Binding<Int>,
        isCursorTrackingUser: Binding<Bool>,
        waypoints: Binding<[Waypoint]>,
        receivedWaypoints: [RadioGroupStore.GroupWaypoint],
        radioPins: [RadioGroupStore.Pin],
        activeRadioGroupID: String?,
        radioMembers: [RadioGroupMember],
        zoomInRequest: Binding<Int>,
        zoomOutRequest: Binding<Int>,
        basemapChoice: BasemapChoice,
        sstEnabled: Bool,
        sstOpacity: Double,
        sstSource: SeaSurfaceTemperatureSource,
        sstDateUTC: String,
        showPortMollerTestFisheryStations: Bool,
        showLiveLocationTrail: Bool = true,
        visibleFishingSets: [SmartFishingSetRecord] = [],
        onFishingSetDisplayPrompt: @escaping (UUID) -> Void = { _ in }
        ) {
        self.locationManager = locationManager
        self._distanceText = distanceText
        self._speedText = speedText
        self._metersPerPoint = metersPerPoint
        self._followUserRequest = followUserRequest
        self._recenterRequest = recenterRequest
        self._isFollowingUser = isFollowingUser
        self._selectedMapVersion = selectedMapVersion
        self._cursorCoordinate = cursorCoordinate
        self._cursorDistanceText = cursorDistanceText
        self._cursorCoordText = cursorCoordText
        self._cursorPanRequest = cursorPanRequest
        self._isCursorTrackingUser = isCursorTrackingUser
        self._waypoints = waypoints
        self.receivedWaypoints = receivedWaypoints
        self.radioPins = radioPins
        self.activeRadioGroupID = activeRadioGroupID
        self.radioMembers = radioMembers
            self._zoomInRequest = zoomInRequest
            self._zoomOutRequest = zoomOutRequest
            self.basemapChoice = basemapChoice
            self.sstEnabled = sstEnabled
            self.sstOpacity = sstOpacity
            self.sstSource = sstSource
            self.sstDateUTC = sstDateUTC
            self.showPortMollerTestFisheryStations = showPortMollerTestFisheryStations
            self.showLiveLocationTrail = showLiveLocationTrail
            self.visibleFishingSets = visibleFishingSets
            self.onFishingSetDisplayPrompt = onFishingSetDisplayPrompt
    }

    // Zoom behavior
    private let minZForTiles: Int = 4
    private let maxZ: Double = 15
    private let maxZForTiles: Int = 15
    private let initialLaunchZoom: Double = 12.0

    // District map packs and shorelines that are available or discoverable locally.
    private var availablePacks: [OfflinePack] {
        OfflineMapsManager.shared.localOverlayCandidatePacks()
    }

    func makeCoordinator() -> Coordinator {
        let followBinding = $isFollowingUser
        let cursorTrackingBinding = $isCursorTrackingUser

        return Coordinator(
            minZForTiles: minZForTiles,
            maxZ: maxZ,
            maxZForTiles: maxZForTiles,
            initialLaunchZoom: initialLaunchZoom,
            initialCursorTrackingUser: isCursorTrackingUser,
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
            },
            onCursorTrackingStateChanged: { isTrackingUser in
                DispatchQueue.main.async {
                    cursorTrackingBinding.wrappedValue = isTrackingUser
                }
            },
            onFishingSetDisplayPrompt: { setID in
                onFishingSetDisplayPrompt(setID)
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
        let cam = map.camera
        cam.heading = 0
        map.camera = cam

        // Custom follow
        map.userTrackingMode = .none

        // Boundaries + overlays
        context.coordinator.currentSelectedMapVersion = selectedMapVersion
        context.coordinator.lastSelectedMapVersion = selectedMapVersion
        installDistrictBoundaries(on: map, coordinator: context.coordinator)
        context.coordinator.basemapChoice = basemapChoice
        installOrRefreshAllMBTilesOverlays(on: map, coordinator: context.coordinator)
        context.coordinator.syncBasemap(on: map)
        context.coordinator.clampZoomIfNeeded(map)
        syncSSTOverlay(on: map, coordinator: context.coordinator)
        // Seed scale
        context.coordinator.updateScale(map)

        // Gestures + cursor tap
        context.coordinator.installGestureHooksIfNeeded(map)
        context.coordinator.installCursorTapIfNeeded(map)
        context.coordinator.installFishingSetLongPressIfNeeded(map)

        // ⚠️ MapKit sometimes doesn't have all gesture recognizers attached at makeUIView time.
        // Re-attach on next runloop to guarantee we see pan/zoom gestures.
        DispatchQueue.main.async { [weak map] in
            guard let map else { return }
            context.coordinator.installGestureHooksIfNeeded(map)
        }

        // Initial map-version state
        context.coordinator.applySelectedMapVersion(on: map, selectedMapVersion: selectedMapVersion)

        // Initial cursor/waypoints/radio pins
        context.coordinator.syncWaypointAnnotations(on: map, waypoints: waypoints)
        context.coordinator.syncSharedWaypointAnnotations(on: map, waypoints: receivedWaypoints)
        context.coordinator.syncActiveRadioGroupID(activeRadioGroupID, on: map)
        context.coordinator.syncLiveLocationTrailVisibility(showLiveLocationTrail, on: map)
        context.coordinator.syncRadioMemberColors(radioMembers, on: map)
        context.coordinator.syncRadioPinAnnotations(on: map, pins: radioPins)
        context.coordinator.syncPortMollerTestFisheryStations(
            on: map,
            isVisible: showPortMollerTestFisheryStations
        )
        context.coordinator.syncFishingSetOverlays(on: map, sets: visibleFishingSets)
        context.coordinator.syncCursorAnnotation(on: map, cursor: cursorCoordinate)
        context.coordinator.startPinFadeTimerIfNeeded()
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // keep tiles sticky after downloads/deletes
        installOrRefreshAllMBTilesOverlays(on: map, coordinator: context.coordinator)
        let previousBasemapChoice = context.coordinator.basemapChoice
        context.coordinator.basemapChoice = basemapChoice
        context.coordinator.syncBasemap(on: map)
        context.coordinator.clampZoomIfNeeded(map)
        syncSSTOverlay(on: map, coordinator: context.coordinator)
        let basemapChoiceChanged = previousBasemapChoice != basemapChoice

        // Keep gesture hooks attached in case MapKit adds recognizers after view creation.
        // Only re-run occasionally to avoid spamming logs.
        if context.coordinator.lastGestureHookRefresh != followUserRequest + recenterRequest + zoomInRequest + zoomOutRequest {
            context.coordinator.lastGestureHookRefresh = followUserRequest + recenterRequest + zoomInRequest + zoomOutRequest
            context.coordinator.installGestureHooksIfNeeded(map)
        }


        // map-version change
        if basemapChoiceChanged || context.coordinator.lastSelectedMapVersion != selectedMapVersion {
            context.coordinator.lastSelectedMapVersion = selectedMapVersion
            context.coordinator.currentSelectedMapVersion = selectedMapVersion
            context.coordinator.applySelectedMapVersion(on: map, selectedMapVersion: selectedMapVersion)
        }

        // cursor/waypoints/radio pins sync
        context.coordinator.syncWaypointAnnotations(on: map, waypoints: waypoints)
        context.coordinator.syncSharedWaypointAnnotations(on: map, waypoints: receivedWaypoints)
        context.coordinator.syncActiveRadioGroupID(activeRadioGroupID, on: map)
        context.coordinator.syncLiveLocationTrailVisibility(showLiveLocationTrail, on: map)
        context.coordinator.syncRadioMemberColors(radioMembers, on: map)
        context.coordinator.syncRadioPinAnnotations(on: map, pins: radioPins)
        context.coordinator.syncPortMollerTestFisheryStations(
            on: map,
            isVisible: showPortMollerTestFisheryStations
        )
        context.coordinator.syncFishingSetOverlays(on: map, sets: visibleFishingSets)
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
            #if DEBUG
            print("❌ District_Boundaries_Final.geojson not found in bundle")
            #endif
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
            #if DEBUG
            print("✅ District boundaries loaded:", polylines.count)
            #endif
        } catch {
            #if DEBUG
            print("❌ District boundaries GeoJSON error:", error)
            #endif
        }
    }

    // MARK: - MBTiles installs
    private func installOrRefreshAllMBTilesOverlays(on map: MKMapView, coordinator: Coordinator) {

        let offlineManager = OfflineMapsManager.shared
        var shouldHave: Set<OfflinePack> = []

        for pack in availablePacks {
            if offlineManager.firstExistingLocalMBTilesURL(for: pack) != nil {
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
                let aVersion = a.districtMapVersion ?? Int.max
                let bVersion = b.districtMapVersion ?? Int.max
                if aVersion != bVersion { return aVersion < bVersion }
                return a.slug < b.slug
            }

            for pack in toAdd {
                guard let url = offlineManager.firstExistingLocalMBTilesURL(for: pack) else { continue }
                let overlay = MBTilesOverlay(mbtilesURL: url, slug: pack.slug)
                overlay.minimumZ = minZForTiles
                overlay.maximumZ = maxZForTiles

                // Register before adding so rendererFor can immediately calculate the correct alpha.
                coordinator.tileOverlays[pack] = overlay
                coordinator.installedTilePacks.insert(pack)
                map.addOverlay(overlay, level: .aboveRoads)
            }

        }

        if !toAddSet.isEmpty || !toRemove.isEmpty {
            coordinator.applySelectedMapVersion(on: map, selectedMapVersion: coordinator.currentSelectedMapVersion)
            if let sstOverlay = coordinator.sstOverlay {
                map.removeOverlay(sstOverlay)
                map.addOverlay(sstOverlay, level: .aboveRoads)
            }
        }
    }

    private func syncSSTOverlay(on map: MKMapView, coordinator: Coordinator) {
        let wantedKey = sstEnabled ? "\(sstSource.rawValue)|\(sstDateUTC)" : nil

        if wantedKey == nil {
            if let overlay = coordinator.sstOverlay {
                map.removeOverlay(overlay)
                coordinator.sstOverlay = nil
                coordinator.sstOverlayKey = nil
            }
            return
        }

        if coordinator.sstOverlayKey != wantedKey {
            if let overlay = coordinator.sstOverlay {
                map.removeOverlay(overlay)
            }

            let overlay = SeaSurfaceTemperatureOverlay(source: sstSource, dateUTC: sstDateUTC)
            overlay.minimumZ = 0
            overlay.maximumZ = sstSource.recommendedMaximumZ
            map.addOverlay(overlay, level: .aboveRoads)
            coordinator.sstOverlay = overlay
            coordinator.sstOverlayKey = wantedKey
        }

        let clampedOpacity = max(0.0, min(1.0, sstOpacity))
        if abs(coordinator.currentSSTOpacity - clampedOpacity) > 0.001 {
            coordinator.currentSSTOpacity = clampedOpacity
            if let overlay = coordinator.sstOverlay,
               let renderer = map.renderer(for: overlay) as? MKTileOverlayRenderer {
                renderer.alpha = CGFloat(clampedOpacity)
                renderer.setNeedsDisplay()
            }
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

        private func sharedWaypointTint(for senderUid: String) -> UIColor {
            WaypointPinColor.deterministicFallback(seed: senderUid).uiColor
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
        #if DEBUG
        private let followDebug = true
        #endif

        private func dlog(_ msg: String) {
            #if DEBUG
            guard followDebug else { return }
            print("🧭 FollowDebug | \(msg)")
            #endif
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
            let maximumZoom = currentMaximumZoom

            // IMPORTANT:
            // - Do NOT clamp zoom-out to `minZForTiles`. That value is for tile visibility, not user zoom range.
            // - Allow zooming out to the full world (0.0). Keep the max zoom-in clamp for the active basemap.
            let targetZoom = max(0.0, min(maximumZoom, currentZoom + Double(delta)))
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


        var lastSelectedMapVersion: Int = 0
        var currentSelectedMapVersion: Int = 1
        var sstOverlay: SeaSurfaceTemperatureOverlay?
        var sstOverlayKey: String?
        var currentSSTOpacity: Double = 0.0

        private var currentMaximumZoom: Double {
            switch basemapChoice {
            case .topoOnline:
                return max(maxZ, Double(USGSTopoOnlineTileOverlay.nativeMaximumZ))
            default:
                return maxZ
            }
        }

        private let onDistanceText: (String) -> Void
        private let onSpeedText: (String) -> Void
        private let onMetersPerPoint: (Double) -> Void
        let onFollowStateChanged: (Bool) -> Void
        private let onCursorUpdated: (CLLocationCoordinate2D?, String, String) -> Void
        private let onCursorTrackingStateChanged: (Bool) -> Void
        private let onFishingSetDisplayPrompt: (UUID) -> Void

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

        // Port Moller Test Fishery stations
        private var portMollerTestFisheryStationAnnotations: [Int: PortMollerTestFisheryStationAnnotation] = [:]
        private var portMollerTestFisheryTransectOverlay: MKPolyline?

        // Shared waypoints (received from other Radio Group members)
        private var sharedWaypointAnnotations: [String: SharedWaypointAnnotation] = [:]

        // Fishing set overlays/annotations keyed by saved set id
        private var fishingSetOverlays: [UUID: MKPolyline] = [:]
        private var fishingSetOverlaySignatures: [UUID: String] = [:]
        private var fishingSetPointAnnotations: [String: FishingSetPointAnnotation] = [:]
        private var fishingSetNumberAnnotations: [UUID: FishingSetNumberAnnotation] = [:]
        private var fishingSetLongPressInstalled = false

        // MARK: - Shared (received) waypoints sync
        func syncSharedWaypointAnnotations(on mapView: MKMapView, waypoints: [RadioGroupStore.GroupWaypoint]) {
            let wanted = Set(waypoints.map { $0.id })
            let existing = Set(sharedWaypointAnnotations.keys)

            // Remove missing
            for id in existing.subtracting(wanted) {
                if let ann = sharedWaypointAnnotations[id] {
                    mapView.removeAnnotation(ann)
                }
                sharedWaypointAnnotations[id] = nil
            }

            // Add/update
            for wp in waypoints {
                let coord = wp.coordinate

                let senderNameTrimmed = wp.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
                let senderName = senderNameTrimmed.isEmpty ? "Member" : senderNameTrimmed

                if let ann = sharedWaypointAnnotations[wp.id] {
                    ann.coordinate = coord
                    ann.title = wp.name
                    ann.subtitle = senderName
                    ann.senderUid = wp.senderUid
                    ann.senderName = senderName
                    ann.colorID = wp.colorID

                    // Refresh custom view immediately if it exists
                    if let v = mapView.view(for: ann) as? SharedWaypointAnnotationView {
                        v.setLabel(ann.title ?? "WP")
                        v.setDotColor(wp.pinColor.uiColor)
                    }
                } else {
                    let ann = SharedWaypointAnnotation(
                        id: wp.id,
                        coordinate: coord,
                        title: wp.name,
                        subtitle: senderName,
                        senderUid: wp.senderUid,
                        senderName: senderName,
                        colorID: wp.colorID
                    )
                    sharedWaypointAnnotations[wp.id] = ann
                    mapView.addAnnotation(ann)
                }
            }
        }

        // Radio Group pin annotations keyed by id string
        private var radioPinAnnotations: [String: RadioPinAnnotation] = [:]
        private var radioMemberColorIDsByUid: [String: String] = [:]
        private struct LiveTrailPoint {
            var coordinate: CLLocationCoordinate2D
            var timestamp: Date
        }

        private struct LiveTrailSegment {
            var id: String
            var ownerUid: String
            var colorID: String
            var start: CLLocationCoordinate2D
            var end: CLLocationCoordinate2D
            var createdAt: Date
        }

        private struct LiveTrailOverlayMetadata {
            var segmentID: String
            var ownerUid: String
            var colorID: String
            var createdAt: Date
        }

        private var activeRadioGroupID: String?
        private var liveTrailPointsByOwnerUid: [String: [LiveTrailPoint]] = [:]
        private var liveTrailSegmentsByOwnerUid: [String: [LiveTrailSegment]] = [:]
        private var liveTrailOverlaysBySegmentID: [String: MKPolyline] = [:]
        private var liveTrailMetadataByOverlayID: [ObjectIdentifier: LiveTrailOverlayMetadata] = [:]
        private var showLiveLocationTrail: Bool = true
        private let liveTrailLifetime: TimeInterval = 10 * 60
        private let liveTrailMaxOpacity: CGFloat = 0.85
        private let liveTrailDistanceThresholdMeters: CLLocationDistance = 10
        private let maxLiveTrailPointsPerOwner = 240
        private let maxLiveTrailSegmentsPerOwner = 240
        private let livePinFreshWindow: TimeInterval = 10 * 60
        private let livePinRenderLifetime: TimeInterval = LiveLocationSessionState.hideStalePinAfter
        // (removed duplicate syncWaypointAnnotations)
        // MARK: - Radio pin fade (all pins; live pins fade based on last update time)
        private var pinFadeTimer: Timer?

        func startPinFadeTimerIfNeeded() {
            guard pinFadeTimer == nil else { return }

            let timer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
                guard let self, let mapView = self.mapView else { return }
                self.refreshRadioPinColors(on: mapView)
                if self.showLiveLocationTrail {
                    self.refreshLiveTrailOverlays(on: mapView, now: Date())
                }
            }
            pinFadeTimer = timer
            RunLoop.main.add(timer, forMode: .common)
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
            // Location pins use the sender's waypoint color, then fade toward gray as they age.
            // For live pins, RadioGroupStore maps createdAt to updatedAt, so the fade resets on each live update.
            let baseColor = radioPinUIColor(ownerUid: pin.ownerUid, colorID: pin.colorID)

            if pin.isLivePin {
                let age = max(0, Date().timeIntervalSince(pin.createdAt))
                let minuteStep = min(60, max(0, Int(floor(age / 60))))
                if age < livePinFreshWindow {
                    return mix(baseColor, .systemGray, t: CGFloat(minuteStep) / 10.0)
                }
                return mix(.systemGray, .darkGray, t: CGFloat(max(0, minuteStep - 10)) / 50.0)
            }

            // Pins fade in 6 steps (10 min each) -> fully gray at 60 min
            let age = max(0, Date().timeIntervalSince(pin.createdAt))
            let stepSeconds: TimeInterval = 10 * 60
            let steps: Double = 6
            let idx = min(Int(age / stepSeconds), Int(steps))
            let t = CGFloat(Double(idx) / steps) // 0.0 ... 1.0

            return mix(baseColor, .systemGray, t: t)
        }

        private func refreshRadioPinColors(on mapView: MKMapView) {
            removeExpiredLivePinAnnotations(on: mapView, now: Date())
            for (_, ann) in radioPinAnnotations {
                if let v = mapView.view(for: ann) as? RadioPinAnnotationView {
                    v.setTint(tintColor(for: ann))
                } else if let v = mapView.view(for: ann) as? MKMarkerAnnotationView {
                    v.markerTintColor = tintColor(for: ann)
                }
            }
        }

        private func removeExpiredLivePinAnnotations(on mapView: MKMapView, now: Date) {
            let expired = radioPinAnnotations.filter { _, ann in
                ann.isLivePin && now.timeIntervalSince(ann.createdAt) >= livePinRenderLifetime
            }
            for (id, ann) in expired {
                mapView.removeAnnotation(ann)
                radioPinAnnotations[id] = nil
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
        private var nearestBoundaryHighlightSegment: MKPolyline?
        private var lastNearestBoundaryCoord: CLLocationCoordinate2D?
        private let nearestBoundaryHighlightLengthMeters: CLLocationDistance = 600.0 / 3.28084

        // Tiles installed
        // Tiles installed
        var installedTilePacks: Set<OfflinePack> = []
        var tileOverlays: [OfflinePack: MKTileOverlay] = [:]

        // Basemap
        var basemapChoice: BasemapChoice = .bristolBaySatelliteOnline
        private var noaaBasemapOverlay: MKTileOverlay?
        private var noaaBasemapKey: String?

        // Scale output
        private(set) var metersPerPoint: Double = 0

        // Cursor behavior
        var cursorFollowsUser: Bool = true {
            didSet {
                guard cursorFollowsUser != oldValue else { return }
                onCursorTrackingStateChanged(cursorFollowsUser)
            }
        }

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
            initialCursorTrackingUser: Bool,
            onDistanceText: @escaping (String) -> Void,
            onSpeedText: @escaping (String) -> Void,
            onMetersPerPoint: @escaping (Double) -> Void,
            onFollowStateChanged: @escaping (Bool) -> Void,
            onCursorUpdated: @escaping (CLLocationCoordinate2D?, String, String) -> Void,
            onCursorTrackingStateChanged: @escaping (Bool) -> Void,
            onFishingSetDisplayPrompt: @escaping (UUID) -> Void
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
            self.onCursorTrackingStateChanged = onCursorTrackingStateChanged
            self.onFishingSetDisplayPrompt = onFishingSetDisplayPrompt
            self.cursorFollowsUser = initialCursorTrackingUser
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
                    // No user fix yet; keep UI field hints.
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
                    ann.colorID = wp.colorID

                    // ✅ Ensure the visible label updates immediately when name changes
                    if let v = mapView.view(for: ann) as? WaypointAnnotationView {
                        v.setLabel(ann.title ?? "")
                        v.setDotColor(wp.pinColor.uiColor)
                    }
                } else {
                    let ann = WaypointAnnotation(id: wp.id, colorID: wp.colorID)
                    ann.coordinate = wp.coordinate
                    ann.title = wp.displayName
                    waypointAnnotations[wp.id] = ann
                    mapView.addAnnotation(ann)

                    // ✅ After the view is created, set the label (MapKit may create it on the next runloop)
                    DispatchQueue.main.async {
                        if let v = mapView.view(for: ann) as? WaypointAnnotationView {
                            v.setLabel(ann.title ?? "")
                            v.setDotColor(wp.pinColor.uiColor)
                        }
                    }
                }
            }
        }


        // MARK: - Fishing set overlays

        func syncFishingSetOverlays(on mapView: MKMapView, sets: [SmartFishingSetRecord]) {
            let visibleSets = sets.filter { $0.displayOnNavPage && !$0.sortedLocations.isEmpty }
            let wantedIDs = Set(visibleSets.map(\.id))
            let existingIDs = Set(fishingSetOverlaySignatures.keys)

            for id in existingIDs.subtracting(wantedIDs) {
                removeFishingSetOverlays(setID: id, from: mapView)
            }

            for set in visibleSets {
                let sortedLocations = set.sortedLocations
                let signature = sortedLocations
                    .map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }
                    .joined(separator: "|") + "|n\(set.setNumber)"

                if fishingSetOverlaySignatures[set.id] != signature {
                    removeFishingSetOverlays(setID: set.id, from: mapView)
                    fishingSetOverlaySignatures[set.id] = signature

                    let coordinates = sortedLocations.map(\.coordinate)
                    if coordinates.count >= 2 {
                        let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
                        fishingSetOverlays[set.id] = line
                        mapView.addOverlay(line, level: .aboveLabels)
                    }

                    for (index, location) in sortedLocations.enumerated() {
                        let key = fishingSetPointKey(setID: set.id, index: index)
                        let annotation = FishingSetPointAnnotation(id: key, setID: set.id, index: index, coordinate: location.coordinate)
                        fishingSetPointAnnotations[key] = annotation
                        mapView.addAnnotation(annotation)
                    }

                    if let firstLocation = sortedLocations.first {
                        let numberAnnotation = FishingSetNumberAnnotation(
                            setID: set.id,
                            setNumber: set.setNumber,
                            coordinate: firstLocation.coordinate
                        )
                        fishingSetNumberAnnotations[set.id] = numberAnnotation
                        mapView.addAnnotation(numberAnnotation)
                    }
                } else {
                    if let label = fishingSetNumberAnnotations[set.id] {
                        label.setNumber = set.setNumber
                        label.title = "Set \(set.setNumber)"
                    }
                }
            }
        }

        private func fishingSetPointKey(setID: UUID, index: Int) -> String {
            "\(setID.uuidString)-\(index)"
        }

        private func removeFishingSetOverlays(setID: UUID, from mapView: MKMapView) {
            if let overlay = fishingSetOverlays.removeValue(forKey: setID) {
                mapView.removeOverlay(overlay)
            }

            if let label = fishingSetNumberAnnotations.removeValue(forKey: setID) {
                mapView.removeAnnotation(label)
            }

            for key in Array(fishingSetPointAnnotations.keys) where key.hasPrefix(setID.uuidString) {
                if let annotation = fishingSetPointAnnotations.removeValue(forKey: key) {
                    mapView.removeAnnotation(annotation)
                }
            }

            fishingSetOverlaySignatures[setID] = nil
        }

        func installFishingSetLongPressIfNeeded(_ mapView: MKMapView) {
            guard !fishingSetLongPressInstalled else { return }
            fishingSetLongPressInstalled = true

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleFishingSetLongPress(_:)))
            longPress.minimumPressDuration = 0.55
            longPress.cancelsTouchesInView = false
            longPress.delegate = self
            mapView.addGestureRecognizer(longPress)
        }

        @objc private func handleFishingSetLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let mapView else { return }
            let point = recognizer.location(in: mapView)
            guard let setID = nearestFishingSetID(toScreenPoint: point, in: mapView) else { return }
            onFishingSetDisplayPrompt(setID)
        }

        private func nearestFishingSetID(toScreenPoint point: CGPoint, in mapView: MKMapView) -> UUID? {
            guard !fishingSetOverlays.isEmpty else { return nil }
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            let mapPoint = MKMapPoint(coordinate)
            let maxMeters = max(25.0, metersPerPoint * 44.0)

            var bestID: UUID?
            var bestDistance = CLLocationDistance.greatestFiniteMagnitude

            for (id, line) in fishingSetOverlays {
                guard let nearest = nearestPointOnPolyline(to: mapPoint, polyline: line) else { continue }
                if nearest.planarMeters < bestDistance {
                    bestDistance = nearest.planarMeters
                    bestID = id
                }
            }

            guard bestDistance <= maxMeters else { return nil }
            return bestID
        }

        // MARK: - Port Moller test fishery stations sync

        func syncPortMollerTestFisheryStations(on mapView: MKMapView, isVisible: Bool) {
            if !isVisible {
                for annotation in portMollerTestFisheryStationAnnotations.values {
                    mapView.removeAnnotation(annotation)
                }
                portMollerTestFisheryStationAnnotations.removeAll()

                if let overlay = portMollerTestFisheryTransectOverlay {
                    mapView.removeOverlay(overlay)
                    portMollerTestFisheryTransectOverlay = nil
                }
                return
            }

            let wantedStationNumbers = Set(portMollerTestFisheryStations.map(\.stationNumber))
            let existingStationNumbers = Set(portMollerTestFisheryStationAnnotations.keys)

            for stationNumber in existingStationNumbers.subtracting(wantedStationNumbers) {
                if let annotation = portMollerTestFisheryStationAnnotations[stationNumber] {
                    mapView.removeAnnotation(annotation)
                }
                portMollerTestFisheryStationAnnotations[stationNumber] = nil
            }

            for station in portMollerTestFisheryStations {
                if let annotation = portMollerTestFisheryStationAnnotations[station.stationNumber] {
                    annotation.coordinate = station.coordinate
                    annotation.title = station.name
                    annotation.subtitle = annotation.subtitleText(for: station)
                } else {
                    let annotation = PortMollerTestFisheryStationAnnotation(station: station)
                    portMollerTestFisheryStationAnnotations[station.stationNumber] = annotation
                    mapView.addAnnotation(annotation)
                }
            }

            if portMollerTestFisheryTransectOverlay == nil {
                let overlay = MKPolyline(
                    coordinates: portMollerTestFisheryStationCoordinates,
                    count: portMollerTestFisheryStationCoordinates.count
                )
                portMollerTestFisheryTransectOverlay = overlay
                mapView.addOverlay(overlay, level: .aboveLabels)
            }
        }

        // MARK: - Radio Group pins sync

        func syncActiveRadioGroupID(_ groupID: String?, on mapView: MKMapView) {
            let normalized = groupID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = (normalized?.isEmpty == false) ? normalized : nil
            guard resolved != activeRadioGroupID else { return }
            activeRadioGroupID = resolved
            radioMemberColorIDsByUid.removeAll()
            clearLiveTrailState(on: mapView)
        }

        func syncRadioMemberColors(_ members: [RadioGroupMember], on mapView: MKMapView) {
            var next: [String: String] = [:]
            next.reserveCapacity(members.count)
            for member in members {
                let uid = member.uid.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !uid.isEmpty else { continue }
                next[uid] = member.waypointPinColorID
            }

            guard next != radioMemberColorIDsByUid else { return }
            radioMemberColorIDsByUid = next
            refreshRadioPinColors(on: mapView)
            if showLiveLocationTrail {
                refreshLiveTrailOverlays(on: mapView, now: Date())
            }
        }

        func syncLiveLocationTrailVisibility(_ isVisible: Bool, on mapView: MKMapView) {
            guard showLiveLocationTrail != isVisible else { return }
            showLiveLocationTrail = isVisible
            if !isVisible {
                clearLiveTrailState(on: mapView)
            }
        }

        func syncRadioPinAnnotations(on mapView: MKMapView, pins: [RadioGroupStore.Pin]) {
            let now = Date()
            let validPins = pins.filter { isRenderableRadioPin($0, now: now) }
            let wanted = Set(validPins.map(radioPinAnnotationID))
            let existing = Set(radioPinAnnotations.keys)

            // Remove old pins
            for id in existing.subtracting(wanted) {
                if let ann = radioPinAnnotations[id] {
                    mapView.removeAnnotation(ann)
                }
                radioPinAnnotations[id] = nil
            }

            // Add/update pins
            for p in validPins {
                let id = radioPinAnnotationID(p)
                let coord = p.coordinate

                if let ann = radioPinAnnotations[id] {
                    ann.coordinate = coord
                    ann.title = p.titleText
                    ann.subtitle = p.subtitleText
                    ann.createdAt = p.createdAt
                    ann.isLivePin = p.isLive
                    ann.ownerUid = p.ownerUid
                    ann.colorID = p.colorID
                } else {
                    let ann = RadioPinAnnotation(id: id)
                    ann.coordinate = coord
                    ann.title = p.titleText
                    ann.subtitle = p.subtitleText
                    ann.createdAt = p.createdAt
                    ann.isLivePin = p.isLive
                    ann.ownerUid = p.ownerUid
                    ann.colorID = p.colorID
                    radioPinAnnotations[id] = ann
                    mapView.addAnnotation(ann)
                }
            }

            // Apply correct tint immediately (timer handles ongoing fades)
            refreshRadioPinColors(on: mapView)
            if showLiveLocationTrail {
                ingestLivePinUpdates(on: mapView, pins: validPins)
            } else {
                clearLiveTrailState(on: mapView)
            }
        }

        private func radioPinAnnotationID(_ pin: RadioGroupStore.Pin) -> String {
            let id = pin.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = pin.ownerUid.trimmingCharacters(in: .whitespacesAndNewlines)
            let stableID = id.isEmpty ? fallback : id
            let prefix = pin.isLive ? "live" : "pin"
            return "\(prefix)|\(stableID.isEmpty ? "unknown" : stableID)"
        }

        private func isValidRadioPinCoordinate(_ coordinate: CLLocationCoordinate2D) -> Bool {
            RadioGroupRecordParser.isValid(coordinate)
        }

        private func isRenderableRadioPin(_ pin: RadioGroupStore.Pin, now: Date) -> Bool {
            guard isValidRadioPinCoordinate(pin.coordinate) else { return false }
            if pin.isLive {
                return now.timeIntervalSince(pin.updatedAt) < livePinRenderLifetime
            }
            return true
        }

        private func ingestLivePinUpdates(on mapView: MKMapView, pins: [RadioGroupStore.Pin]) {
            let now = Date()
            pruneLiveTrailState(now: now)

            let livePins = pins
                .filter { $0.isLive && isValidRadioPinCoordinate($0.coordinate) }
                .sorted {
                    if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                    if $0.ownerUid != $1.ownerUid { return $0.ownerUid < $1.ownerUid }
                    return $0.id < $1.id
                }

            for pin in livePins {
                let ownerUid = pin.ownerUid.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ownerUid.isEmpty else { continue }

                let timestamp = pin.updatedAt
                var points = liveTrailPointsByOwnerUid[ownerUid] ?? []
                points.removeAll { now.timeIntervalSince($0.timestamp) >= liveTrailLifetime }

                if var last = points.last {
                    let distance = trailDistance(from: last.coordinate, to: pin.coordinate)
                    guard timestamp > last.timestamp else {
                        liveTrailPointsByOwnerUid[ownerUid] = points
                        continue
                    }

                    if distance >= liveTrailDistanceThresholdMeters {
                        let segment = LiveTrailSegment(
                            id: liveTrailSegmentID(ownerUid: ownerUid, start: last.coordinate, end: pin.coordinate, createdAt: timestamp),
                            ownerUid: ownerUid,
                            colorID: pin.colorID,
                            start: last.coordinate,
                            end: pin.coordinate,
                            createdAt: timestamp
                        )
                        liveTrailSegmentsByOwnerUid[ownerUid, default: []].append(segment)
                        points.append(LiveTrailPoint(coordinate: pin.coordinate, timestamp: timestamp))
                    } else {
                        last.timestamp = timestamp
                        points[points.count - 1] = last
                    }
                } else {
                    points.append(LiveTrailPoint(coordinate: pin.coordinate, timestamp: timestamp))
                }

                if points.count > maxLiveTrailPointsPerOwner {
                    points.removeFirst(points.count - maxLiveTrailPointsPerOwner)
                }
                liveTrailPointsByOwnerUid[ownerUid] = points

                if var segments = liveTrailSegmentsByOwnerUid[ownerUid], segments.count > maxLiveTrailSegmentsPerOwner {
                    segments.removeFirst(segments.count - maxLiveTrailSegmentsPerOwner)
                    liveTrailSegmentsByOwnerUid[ownerUid] = segments
                }
            }

            refreshLiveTrailOverlays(on: mapView, now: now)
        }

        private func clearLiveTrailState(on mapView: MKMapView) {
            for overlay in liveTrailOverlaysBySegmentID.values {
                mapView.removeOverlay(overlay)
            }
            liveTrailPointsByOwnerUid.removeAll()
            liveTrailSegmentsByOwnerUid.removeAll()
            liveTrailOverlaysBySegmentID.removeAll()
            liveTrailMetadataByOverlayID.removeAll()
        }

        private func refreshLiveTrailOverlays(on mapView: MKMapView, now: Date) {
            pruneLiveTrailState(now: now)
            let activeSegments = liveTrailSegmentsByOwnerUid.values.flatMap { $0 }
            let activeIDs = Set(activeSegments.map(\.id))

            for (segmentID, overlay) in liveTrailOverlaysBySegmentID where !activeIDs.contains(segmentID) {
                mapView.removeOverlay(overlay)
                liveTrailMetadataByOverlayID.removeValue(forKey: ObjectIdentifier(overlay))
            }
            liveTrailOverlaysBySegmentID = liveTrailOverlaysBySegmentID.filter { activeIDs.contains($0.key) }

            for segment in activeSegments {
                if let overlay = liveTrailOverlaysBySegmentID[segment.id] {
                    if mapView.overlays.contains(where: { ($0 as AnyObject) === overlay }),
                       let renderer = mapView.renderer(for: overlay) as? MKPolylineRenderer {
                        renderer.strokeColor = radioPinUIColor(ownerUid: segment.ownerUid, colorID: segment.colorID)
                            .withAlphaComponent(liveTrailOpacity(for: segment.createdAt, now: now))
                        renderer.setNeedsDisplay()
                    }
                    continue
                }

                var coordinates = [segment.start, segment.end]
                let overlay = MKPolyline(coordinates: &coordinates, count: coordinates.count)
                liveTrailOverlaysBySegmentID[segment.id] = overlay
                liveTrailMetadataByOverlayID[ObjectIdentifier(overlay)] = LiveTrailOverlayMetadata(
                    segmentID: segment.id,
                    ownerUid: segment.ownerUid,
                    colorID: segment.colorID,
                    createdAt: segment.createdAt
                )
                mapView.addOverlay(overlay, level: .aboveLabels)
            }
        }

        private func pruneLiveTrailState(now: Date) {
            for ownerUid in Array(liveTrailPointsByOwnerUid.keys) {
                liveTrailPointsByOwnerUid[ownerUid]?.removeAll { now.timeIntervalSince($0.timestamp) >= liveTrailLifetime }
                if liveTrailPointsByOwnerUid[ownerUid]?.isEmpty == true {
                    liveTrailPointsByOwnerUid.removeValue(forKey: ownerUid)
                }
            }

            for ownerUid in Array(liveTrailSegmentsByOwnerUid.keys) {
                liveTrailSegmentsByOwnerUid[ownerUid]?.removeAll { now.timeIntervalSince($0.createdAt) >= liveTrailLifetime }
                if liveTrailSegmentsByOwnerUid[ownerUid]?.isEmpty == true {
                    liveTrailSegmentsByOwnerUid.removeValue(forKey: ownerUid)
                }
            }
        }

        private func liveTrailOpacity(for createdAt: Date, now: Date = Date()) -> CGFloat {
            let age = max(0, now.timeIntervalSince(createdAt))
            guard age < liveTrailLifetime else { return 0 }
            let remainingFraction = max(0, min(1, 1 - (age / liveTrailLifetime)))
            return liveTrailMaxOpacity * CGFloat(remainingFraction)
        }

        private func liveTrailSegmentID(
            ownerUid: String,
            start: CLLocationCoordinate2D,
            end: CLLocationCoordinate2D,
            createdAt: Date
        ) -> String {
            let millis = Int((createdAt.timeIntervalSince1970 * 1000).rounded())
            return "\(ownerUid)|\(millis)|\(String(format: "%.5f", start.latitude)),\(String(format: "%.5f", start.longitude))|\(String(format: "%.5f", end.latitude)),\(String(format: "%.5f", end.longitude))"
        }

        private func isValidTrailCoordinate(_ coordinate: CLLocationCoordinate2D) -> Bool {
            isValidRadioPinCoordinate(coordinate)
        }

        private func trailDistance(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> CLLocationDistance {
            CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        }

        private func radioMemberUIColor(for ownerUid: String) -> UIColor {
            let uid = ownerUid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uid.isEmpty else { return UIColor.systemGreen }
            if let colorID = radioMemberColorIDsByUid[uid] {
                return WaypointPinColor.safe(
                    rawValue: colorID,
                    fallback: WaypointPinColor.deterministicFallback(seed: uid)
                ).uiColor
            }
            return scMemberUIColor(for: uid)
        }

        private func radioPinUIColor(ownerUid: String, colorID: String) -> UIColor {
            let rawColor = colorID.trimmingCharacters(in: .whitespacesAndNewlines)
            if let color = WaypointPinColor(rawValue: rawColor) {
                return color.uiColor
            }
            return radioMemberUIColor(for: ownerUid)
        }

        // MARK: - District map version cycling

        private func installedDistrictMapPacks(for district: DistrictID) -> [OfflinePack] {
            installedTilePacks
                .filter { $0.district == district && $0.isDistrictMapPack }
                .sorted { lhs, rhs in
                    let lhsVersion = lhs.districtMapVersion ?? Int.max
                    let rhsVersion = rhs.districtMapVersion ?? Int.max
                    if lhsVersion != rhsVersion { return lhsVersion < rhsVersion }
                    return lhs.slug < rhs.slug
                }
        }

        private func selectedDistrictMapSlug(for district: DistrictID) -> String? {
            let packs = installedDistrictMapPacks(for: district)
            guard !packs.isEmpty else { return nil }

            let normalizedVersion = max(1, currentSelectedMapVersion)
            let index = (normalizedVersion - 1) % packs.count
            return packs[index].slug
        }

        private func isShorelineOverlay(slug: String) -> Bool {
            BasemapLayerPolicy.isShorelineOverlay(slug: slug)
        }

        private func isDistrictOrShorelineOverlay(slug: String) -> Bool {
            BasemapLayerPolicy.isDistrictOrShorelineOverlay(slug: slug)
        }

        private func tileAlpha(for slug: String) -> CGFloat {
            let selectedSlug = DistrictID.district(forDistrictMapSlug: slug)
                .flatMap { selectedDistrictMapSlug(for: $0) }
            return CGFloat(BasemapLayerPolicy.tileAlpha(
                for: slug,
                basemapChoice: basemapChoice,
                selectedDistrictMapSlug: selectedSlug
            ))
        }

        func applySelectedMapVersion(on mapView: MKMapView, selectedMapVersion: Int) {
            currentSelectedMapVersion = max(1, selectedMapVersion)

            let districtOfflineOverlays: [MBTilesOverlay] = mapView.overlays
                .compactMap { $0 as? MBTilesOverlay }
                .filter { isDistrictOrShorelineOverlay(slug: $0.slug) }

            for overlay in districtOfflineOverlays {
                if let r = mapView.renderer(for: overlay) as? MKTileOverlayRenderer {
                    r.alpha = tileAlpha(for: overlay.slug)
                    r.reloadData()
                    r.setNeedsDisplay()
                }
            }

            if basemapChoice == .districtsOffline && !districtOfflineOverlays.isEmpty {
                districtOfflineOverlays.forEach { mapView.removeOverlay($0) }
                districtOfflineOverlays.forEach { mapView.addOverlay($0, level: .aboveRoads) }
            }

            if let sstOverlay = sstOverlay {
                mapView.removeOverlay(sstOverlay)
                mapView.addOverlay(sstOverlay, level: .aboveRoads)
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
                let cam = mapView.camera
                cam.heading = 0
                withProgrammaticRegionChange(timeout: 0.3) {
                    mapView.camera = cam
                }
            }

            clampZoomIfNeeded(mapView)
            updateScale(mapView)
            refreshUserMarker(mapView)
            syncBasemap(on: mapView)
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
            syncBasemap(on: mapView)
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


        // MARK: - Basemap

        func syncBasemap(on mapView: MKMapView) {
            switch basemapChoice {
            case .districtsOffline:
                syncOnlineBristolBaySatelliteBasemap(on: mapView)

            case .appleSatellite:
                if mapView.mapType != .satellite {
                    mapView.mapType = .satellite
                }
                removeNOAABasemap(from: mapView)

            case .bristolBaySatelliteOnline:
                syncOnlineBristolBaySatelliteBasemap(on: mapView)

            case .bristolBaySatelliteOffline:
                syncOfflineBristolBaySatelliteBasemap(on: mapView)

            case .topoOnline:
                syncUSGSTopoBasemap(on: mapView)

            case .noaaOffline:
                syncOfflineNOAABasemap(on: mapView)

            case .noaaOnline:
                syncOnlineNOAABasemap(on: mapView)
            }
        }

        private func syncOnlineBristolBaySatelliteBasemap(on mapView: MKMapView) {
            if mapView.mapType != .satellite {
                mapView.mapType = .satellite
            }

            let wantedKey = "bristol-bay-satellite:online-overlay"
            if noaaBasemapKey == wantedKey, noaaBasemapOverlay != nil {
                return
            }

            removeNOAABasemap(from: mapView)

            let overlay = BristolBaySatelliteTileOverlay(replacesMapContent: false)
            mapView.insertOverlay(overlay, at: 0, level: .aboveRoads)
            noaaBasemapOverlay = overlay
            noaaBasemapKey = wantedKey
        }

        private func syncOfflineBristolBaySatelliteBasemap(on mapView: MKMapView) {
            guard let package = OfflineMapsManager.shared.bestLocalBristolBaySatellitePackage(for: mapView.visibleMapRect) else {
                if mapView.mapType != .satellite {
                    mapView.mapType = .satellite
                }
                removeNOAABasemap(from: mapView)
                return
            }

            if mapView.mapType != .satellite {
                mapView.mapType = .satellite
            }

            let wantedKey = "bristol-bay-satellite:offline:\(package.slug)"
            if noaaBasemapKey == wantedKey, noaaBasemapOverlay != nil {
                return
            }

            removeNOAABasemap(from: mapView)

            let overlay = MBTilesOverlay(
                mbtilesURL: package.url,
                slug: package.slug,
                canReplaceMapContent: false
            )
            overlay.minimumZ = package.minZoom ?? 0
            overlay.maximumZ = maxZForTiles

            mapView.insertOverlay(overlay, at: 0, level: .aboveRoads)
            noaaBasemapOverlay = overlay
            noaaBasemapKey = wantedKey
        }


        private func syncUSGSTopoBasemap(on mapView: MKMapView) {
            if mapView.mapType != .standard {
                mapView.mapType = .standard
            }

            let wantedKey = "usgs-topo:online"
            if noaaBasemapKey == wantedKey, noaaBasemapOverlay != nil {
                return
            }

            removeNOAABasemap(from: mapView)

            let overlay = USGSTopoOnlineTileOverlay(replacesMapContent: true)
            mapView.insertOverlay(overlay, at: 0, level: .aboveRoads)
            noaaBasemapOverlay = overlay
            noaaBasemapKey = wantedKey
        }

        private func syncOfflineNOAABasemap(on mapView: MKMapView) {
            guard let package = OfflineMapsManager.shared.bestLocalNOAAChartPackage(for: mapView.visibleMapRect) else {
                if mapView.mapType != .satellite {
                    mapView.mapType = .satellite
                }
                removeNOAABasemap(from: mapView)
                return
            }

            if mapView.mapType != .satellite {
                mapView.mapType = .satellite
            }

            let wantedKey = "offline:\(package.slug)"
            if noaaBasemapKey == wantedKey, noaaBasemapOverlay != nil {
                return
            }

            removeNOAABasemap(from: mapView)

            let overlay = MBTilesOverlay(
                mbtilesURL: package.url,
                slug: package.slug,
                canReplaceMapContent: false
            )
            overlay.minimumZ = package.minZoom ?? 0
            overlay.maximumZ = package.maxZoom ?? 18

            mapView.insertOverlay(overlay, at: 0, level: .aboveRoads)
            noaaBasemapOverlay = overlay
            noaaBasemapKey = wantedKey
        }

        private func syncOnlineNOAABasemap(on mapView: MKMapView) {
            if mapView.mapType != .standard {
                mapView.mapType = .standard
            }

            let wantedKey = "online"
            if noaaBasemapKey == wantedKey, noaaBasemapOverlay != nil {
                return
            }

            removeNOAABasemap(from: mapView)

            let overlay = NOAAOnlineTileOverlay(replacesMapContent: true)
            mapView.insertOverlay(overlay, at: 0, level: .aboveRoads)
            noaaBasemapOverlay = overlay
            noaaBasemapKey = wantedKey
        }

        private func removeNOAABasemap(from mapView: MKMapView) {
            if let overlay = noaaBasemapOverlay {
                mapView.removeOverlay(overlay)
            }
            noaaBasemapOverlay = nil
            noaaBasemapKey = nil
        }

        // MARK: - Zoom clamp

        func clampZoomIfNeeded(_ mapView: MKMapView) {
            let currentZoom = zoomLevel(for: mapView)
            let maximumZoom = currentMaximumZoom
            guard currentZoom > maximumZoom else { return }

            let center = mapView.centerCoordinate
            let clampedRect = mapRect(center: center, zoom: maximumZoom, in: mapView)
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

        private struct NearestPolylineResult {
            let closestPoint: MKMapPoint
            let planarMeters: CLLocationDistance
            let segmentIndex: Int
            let segmentFraction: Double
        }

        private func updateNearestBoundary(to coord: CLLocationCoordinate2D, in mapView: MKMapView) {
            guard !boundaryLines.isEmpty else {
                removeNearestBoundaryHighlight(from: mapView)
                nearestLine = nil
                lastNearestBoundaryCoord = nil
                onDistanceText("—")
                return
            }

            let userPoint = MKMapPoint(coord)

            var bestLine: MKPolyline?
            var bestResult: NearestPolylineResult?

            for line in boundaryLines {
                guard let result = nearestPointOnPolyline(to: userPoint, polyline: line) else { continue }
                if bestResult == nil || result.planarMeters < (bestResult?.planarMeters ?? .greatestFiniteMagnitude) {
                    bestResult = result
                    bestLine = line
                }
            }

            guard let line = bestLine, let result = bestResult else {
                removeNearestBoundaryHighlight(from: mapView)
                nearestLine = nil
                lastNearestBoundaryCoord = nil
                onDistanceText("—")
                return
            }

            let closestCoord = result.closestPoint.coordinate
            let shouldRefreshHighlight: Bool = {
                guard nearestLine === line else { return true }
                guard let lastNearestBoundaryCoord else { return true }
                let previous = CLLocation(latitude: lastNearestBoundaryCoord.latitude, longitude: lastNearestBoundaryCoord.longitude)
                let current = CLLocation(latitude: closestCoord.latitude, longitude: closestCoord.longitude)
                return previous.distance(from: current) >= 1.0
            }()

            nearestLine = line
            lastNearestBoundaryCoord = closestCoord

            if shouldRefreshHighlight {
                let segment = makeNearestBoundaryHighlightSegment(
                    on: line,
                    closestPoint: result.closestPoint,
                    segmentIndex: result.segmentIndex,
                    totalLengthMeters: nearestBoundaryHighlightLengthMeters
                )
                replaceNearestBoundaryHighlight(with: segment, in: mapView)
            }

            // ✅ accurate geodesic distance from user to the closest point on the boundary line.
            let userLoc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            let boundaryLoc = CLLocation(latitude: closestCoord.latitude, longitude: closestCoord.longitude)
            let geodesicMeters = userLoc.distance(from: boundaryLoc)

            onDistanceText(formatDistance(geodesicMeters))
        }

        private func replaceNearestBoundaryHighlight(with segment: MKPolyline?, in mapView: MKMapView) {
            if let old = nearestBoundaryHighlightSegment {
                mapView.removeOverlay(old)
            }

            nearestBoundaryHighlightSegment = nil

            guard let segment else { return }
            nearestBoundaryHighlightSegment = segment
            mapView.addOverlay(segment, level: .aboveLabels)
        }

        private func removeNearestBoundaryHighlight(from mapView: MKMapView) {
            if let old = nearestBoundaryHighlightSegment {
                mapView.removeOverlay(old)
                nearestBoundaryHighlightSegment = nil
            }
        }

        private func nearestPointOnPolyline(to point: MKMapPoint, polyline: MKPolyline) -> NearestPolylineResult? {
            let points = mapPoints(for: polyline)
            guard points.count >= 2 else { return nil }

            var best: NearestPolylineResult?

            for i in 0..<(points.count - 1) {
                let res = nearestPointOnSegment(p: point, a: points[i], b: points[i + 1])
                if best == nil || res.planarMeters < (best?.planarMeters ?? .greatestFiniteMagnitude) {
                    best = NearestPolylineResult(
                        closestPoint: res.closestPoint,
                        planarMeters: res.planarMeters,
                        segmentIndex: i,
                        segmentFraction: res.segmentFraction
                    )
                }
            }

            return best
        }

        private func nearestPointOnSegment(
            p: MKMapPoint,
            a: MKMapPoint,
            b: MKMapPoint
        ) -> (closestPoint: MKMapPoint, planarMeters: CLLocationDistance, segmentFraction: Double) {
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
                return (a, d, 0.0)
            }

            var t = (apx * abx + apy * aby) / ab2
            t = max(0, min(1, t))

            let c = interpolatedPoint(from: a, to: b, fraction: t)
            return (c, p.distance(to: c), t)
        }

        private func makeNearestBoundaryHighlightSegment(
            on polyline: MKPolyline,
            closestPoint: MKMapPoint,
            segmentIndex: Int,
            totalLengthMeters: CLLocationDistance
        ) -> MKPolyline? {
            let points = mapPoints(for: polyline)
            guard points.count >= 2,
                  segmentIndex >= 0,
                  segmentIndex < points.count - 1 else {
                return nil
            }

            let halfLength = max(0, totalLengthMeters / 2.0)

            let backward = boundaryHighlightPoints(
                from: closestPoint,
                segmentIndex: segmentIndex,
                points: points,
                direction: -1,
                maxDistanceMeters: halfLength
            )

            let forward = boundaryHighlightPoints(
                from: closestPoint,
                segmentIndex: segmentIndex,
                points: points,
                direction: 1,
                maxDistanceMeters: halfLength
            )

            let segmentPoints = Array(backward.reversed()) + forward.dropFirst()
            guard segmentPoints.count >= 2 else { return nil }

            let coordinates = segmentPoints.map { $0.coordinate }
            return MKPolyline(coordinates: coordinates, count: coordinates.count)
        }

        private func boundaryHighlightPoints(
            from anchor: MKMapPoint,
            segmentIndex: Int,
            points: [MKMapPoint],
            direction: Int,
            maxDistanceMeters: CLLocationDistance
        ) -> [MKMapPoint] {
            var out: [MKMapPoint] = [anchor]
            var current = anchor
            var remaining = max(0, maxDistanceMeters)
            var nextIndex = direction < 0 ? segmentIndex : segmentIndex + 1

            while remaining > 0, nextIndex >= 0, nextIndex < points.count {
                let next = points[nextIndex]
                let distance = current.distance(to: next)

                if distance <= .ulpOfOne {
                    current = next
                    nextIndex += direction
                    continue
                }

                if distance >= remaining {
                    out.append(interpolatedPoint(from: current, to: next, distanceMeters: remaining, totalDistanceMeters: distance))
                    return out
                }

                out.append(next)
                remaining -= distance
                current = next
                nextIndex += direction
            }

            return out
        }

        private func mapPoints(for polyline: MKPolyline) -> [MKMapPoint] {
            let rawPoints = polyline.points()
            return (0..<polyline.pointCount).map { rawPoints[$0] }
        }

        private func interpolatedPoint(from a: MKMapPoint, to b: MKMapPoint, fraction: Double) -> MKMapPoint {
            let t = max(0, min(1, fraction))
            return MKMapPoint(
                x: a.x + (b.x - a.x) * t,
                y: a.y + (b.y - a.y) * t
            )
        }

        private func interpolatedPoint(
            from a: MKMapPoint,
            to b: MKMapPoint,
            distanceMeters: CLLocationDistance,
            totalDistanceMeters: CLLocationDistance
        ) -> MKMapPoint {
            guard totalDistanceMeters > 0 else { return a }
            return interpolatedPoint(from: a, to: b, fraction: distanceMeters / totalDistanceMeters)
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
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? RadioPinAnnotationView
                    ?? RadioPinAnnotationView(annotation: p, reuseIdentifier: id)

                v.annotation = p
                v.canShowCallout = true
                v.displayPriority = .required
                v.setTint(tintColor(for: p))
                v.rightCalloutAccessoryView = UIButton(type: .detailDisclosure)
                return v
            }

            if let stationAnnotation = annotation as? PortMollerTestFisheryStationAnnotation {
                let id = "PortMollerTestFisheryStationAnnotationView"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: stationAnnotation, reuseIdentifier: id)

                v.annotation = stationAnnotation
                v.canShowCallout = true
                v.displayPriority = .required
                v.clusteringIdentifier = nil
                v.markerTintColor = stationAnnotation.confidence == .documented
                    ? UIColor.systemTeal
                    : UIColor.systemBlue
                v.glyphText = "\(stationAnnotation.stationNumber)"
                return v
            }

            if annotation is MKUserLocation {
                let v = (mapView.dequeueReusableAnnotationView(
                    withIdentifier: userViewReuseID,
                    for: annotation
                ) as? CourseTriangleUserView)
                    ?? CourseTriangleUserView(annotation: annotation, reuseIdentifier: userViewReuseID)
                v.annotation = annotation
                v.update(
                    courseDegrees: mapView.userLocation.location.flatMap { self.smoothedCourseDegrees(from: $0) },
                    hasGoodFix: mapView.userLocation.location.map(isGoodFix) ?? false,
                    screenLinePoints: Double(mapView.bounds.width) * 0.30
                )
                return v
            }

            if annotation is FishingSetPointAnnotation {
                let id = "FishingSetPointAnnotationView"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? FishingSetPointAnnotationView
                    ?? FishingSetPointAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                return v
            }

            if let fishingSetNumber = annotation as? FishingSetNumberAnnotation {
                let id = "FishingSetNumberAnnotationView"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? FishingSetNumberAnnotationView
                    ?? FishingSetNumberAnnotationView(annotation: fishingSetNumber, reuseIdentifier: id)
                v.annotation = fishingSetNumber
                v.setLabel("\(fishingSetNumber.setNumber)")
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
                v.setDotColor(WaypointPinColor.safe(rawValue: w.colorID).uiColor)
                return v
            }

            if let sw = annotation as? SharedWaypointAnnotation {
                let id = "SharedWaypointAnnotationView"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? SharedWaypointAnnotationView
                    ?? SharedWaypointAnnotationView(annotation: sw, reuseIdentifier: id)

                v.annotation = sw
                v.canShowCallout = true
                v.displayPriority = .required

                // Match local waypoint pin size/style, but color-coded per sender
                v.setLabel(sw.title ?? "WP")
                v.setDotColor(WaypointPinColor.safe(rawValue: sw.colorID, fallback: WaypointPinColor.deterministicFallback(seed: sw.senderUid)).uiColor)

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

                if tile is SeaSurfaceTemperatureOverlay {
                    r.alpha = CGFloat(max(0.0, min(1.0, currentSSTOpacity)))
                } else if let mb = tile as? MBTilesOverlay {
                    r.alpha = tileAlpha(for: mb.slug)
                } else {
                    r.alpha = 1.0
                }

                return r
            }

            if let line = overlay as? MKPolyline,
               let trail = liveTrailMetadataByOverlayID[ObjectIdentifier(line)] {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = radioPinUIColor(ownerUid: trail.ownerUid, colorID: trail.colorID)
                    .withAlphaComponent(liveTrailOpacity(for: trail.createdAt))
                r.lineWidth = 2.0
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }

            if let line = overlay as? MKPolyline,
               fishingSetOverlays.values.contains(where: { $0 === line }) {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = UIColor.systemRed.withAlphaComponent(0.95)
                r.lineWidth = 2.2
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }

            if let line = overlay as? MKPolyline,
               let stationTransect = portMollerTestFisheryTransectOverlay,
               line === stationTransect {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = UIColor.systemTeal.withAlphaComponent(0.95)
                r.lineWidth = 2.5
                r.lineDashPattern = [6, 4]
                return r
            }

            if let line = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: line)

                if line === nearestBoundaryHighlightSegment {
                    r.strokeColor = UIColor.red.withAlphaComponent(0.95)
                    r.lineWidth = 4
                    r.lineCap = .round
                    r.lineJoin = .round
                } else {
                    r.strokeColor = .black
                    r.lineWidth = 2
                }

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
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
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
    var colorID: String

    init(id: UUID, colorID: String) {
        self.id = id
        self.coordinate = .init()
        self.colorID = WaypointPinColor.safe(rawValue: colorID).rawValue
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
    var ownerUid: String = ""
    var colorID: String = ""

    init(id: String) {
        self.id = id
        self.coordinate = .init()
        super.init()
    }
}

final class RadioPinAnnotationView: MKAnnotationView {
    private let dotLayer = CAShapeLayer()
    private let glyphView = UIImageView(image: UIImage(systemName: "dot.radiowaves.left.and.right"))

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        frame = CGRect(x: 0, y: 0, width: 18, height: 18)
        centerOffset = .zero
        canShowCallout = true
        displayPriority = .required
        collisionMode = .circle
        clusteringIdentifier = nil

        dotLayer.fillColor = UIColor.systemGreen.cgColor
        dotLayer.strokeColor = UIColor.white.withAlphaComponent(0.90).cgColor
        dotLayer.lineWidth = 1
        layer.addSublayer(dotLayer)

        glyphView.contentMode = .scaleAspectFit
        glyphView.tintColor = .white
        glyphView.alpha = 0.90
        addSubview(glyphView)

        redraw()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        redraw()
    }

    func setTint(_ color: UIColor) {
        dotLayer.fillColor = color.cgColor
    }

    private func redraw() {
        let dotRect = bounds.insetBy(dx: 3, dy: 3)
        dotLayer.path = UIBezierPath(ovalIn: dotRect).cgPath
        glyphView.frame = bounds.insetBy(dx: 4.8, dy: 4.8)
    }
}

final class PortMollerTestFisheryStationAnnotation: NSObject, MKAnnotation {
    let stationNumber: Int
    let confidence: PMTFStation.Confidence
    dynamic var coordinate: CLLocationCoordinate2D
    dynamic var title: String?
    dynamic var subtitle: String?

    init(station: PMTFStation) {
        self.stationNumber = station.stationNumber
        self.confidence = station.confidence
        self.coordinate = station.coordinate
        self.title = station.name
        self.subtitle = nil
        super.init()
        self.subtitle = subtitleText(for: station)
    }

    func subtitleText(for station: PMTFStation) -> String {
        let confidenceText = station.confidence == .documented ? "Documented" : "Estimated"
        return "\(station.coordinateDMM) • \(confidenceText)"
    }
}

final class FishingSetPointAnnotation: NSObject, MKAnnotation {
    let id: String
    let setID: UUID
    let index: Int
    dynamic var coordinate: CLLocationCoordinate2D

    init(id: String, setID: UUID, index: Int, coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.setID = setID
        self.index = index
        self.coordinate = coordinate
        super.init()
    }
}

final class FishingSetNumberAnnotation: NSObject, MKAnnotation {
    let setID: UUID
    var setNumber: Int
    dynamic var coordinate: CLLocationCoordinate2D
    dynamic var title: String?

    init(setID: UUID, setNumber: Int, coordinate: CLLocationCoordinate2D) {
        self.setID = setID
        self.setNumber = setNumber
        self.coordinate = coordinate
        self.title = "Set \(setNumber)"
        super.init()
    }
}

final class FishingSetPointAnnotationView: MKAnnotationView {
    private let dot = CAShapeLayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 12, height: 12)
        centerOffset = .zero
        canShowCallout = false
        displayPriority = .required
        collisionMode = .circle
        clusteringIdentifier = nil

        dot.fillColor = UIColor.systemRed.cgColor
        dot.strokeColor = UIColor.white.withAlphaComponent(0.92).cgColor
        dot.lineWidth = 1
        layer.addSublayer(dot)
        redraw()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        redraw()
    }

    private func redraw() {
        dot.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).cgPath
    }
}

final class FishingSetNumberAnnotationView: MKAnnotationView {
    private let label = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 20, height: 18)
        canShowCallout = false
        displayPriority = .required
        collisionMode = .none
        clusteringIdentifier = nil
        backgroundColor = .clear

        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = .systemRed
        label.textAlignment = .center
        label.backgroundColor = .clear
        label.shadowColor = UIColor.white.withAlphaComponent(0.82)
        label.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
        centerOffset = CGPoint(x: 0, y: -15)
    }

    func setLabel(_ text: String) {
        label.text = text
        setNeedsLayout()
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
        shape.lineWidth = 2
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
        let r: CGFloat = 9   // or whatever you’re using

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

final class SharedWaypointAnnotationView: MKAnnotationView {
    private let dot = CAShapeLayer()
    private let label = UILabel()

    private let dotSize: CGFloat = 10
    private let dotX: CGFloat = 0
    private let dotY: CGFloat = 22

    private var dotUIColor: UIColor = .systemBlue

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        frame = CGRect(x: 0, y: 0, width: 140, height: 34)

        dot.fillColor = dotUIColor.cgColor
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

        // Keep received waypoint pins visible at low zoom
        // (match local waypoint style; avoid clustering so they don't disappear)
        displayPriority = .required
        collisionMode = .circle
        clusteringIdentifier = nil
        canShowCallout = true

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

    func setDotColor(_ color: UIColor) {
        dotUIColor = color
        dot.fillColor = dotUIColor.cgColor
        setNeedsLayout()
    }

    private func redraw() {
        let txt = (label.text ?? "").isEmpty ? "WP" : (label.text ?? "")
        label.text = txt

        label.sizeToFit()
        let labelW = min(max(label.bounds.width + 12, 36), 160)
        let labelH: CGFloat = 20

        let totalW = dotX + dotSize + 6 + labelW
        let totalH: CGFloat = 34
        bounds = CGRect(x: 0, y: 0, width: totalW, height: totalH)

        let dotRect = CGRect(x: dotX, y: dotY, width: dotSize, height: dotSize)
        dot.path = UIBezierPath(ovalIn: dotRect).cgPath

        label.frame = CGRect(
            x: dotX + dotSize + 6,
            y: 6,
            width: labelW,
            height: labelH
        )
        label.textAlignment = .center

        let dotCenter = CGPoint(x: dotRect.midX, y: dotRect.midY)
        centerOffset = CGPoint(
            x: (bounds.width / 2.0) - dotCenter.x,
            y: (bounds.height / 2.0) - dotCenter.y
        )
    }
}
final class WaypointAnnotationView: MKAnnotationView {
    private let dot = CAShapeLayer()
    private let label = UILabel()
    private var dotUIColor: UIColor = .systemRed

    // Constants for anchoring
    private let dotSize: CGFloat = 10
    private let dotX: CGFloat = 0            // dot sits at the left edge
    private let dotY: CGFloat = 22           // dot sits near the bottom (room for label above)

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        // Start with a reasonable size; we’ll resize dynamically in `redraw()`.
        frame = CGRect(x: 0, y: 0, width: 140, height: 34)

        dot.fillColor = dotUIColor.cgColor
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

    func setDotColor(_ color: UIColor) {
        dotUIColor = color
        dot.fillColor = dotUIColor.cgColor
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
