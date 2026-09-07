import SwiftUI
import MapKit
import CoreLocation
import UIKit
import Foundation
import os

// MARK: - Map rendering stability primitives

nonisolated struct MapStabilityDiagnosticSnapshot: Sendable, Equatable {
    let updateUIViewCount: UInt64
    let deferredUpdateUIViewCount: UInt64
    let visibleRegionCount: UInt64
    let movementIntervalCount: UInt64
    let settledUpdateCount: UInt64
    let reconciliationCount: UInt64
    let overlayAdditions: UInt64
    let overlayRemovals: UInt64
    let overlayReorders: UInt64
    let rendererCreations: UInt64
    let reloadDataCalls: UInt64
    let alphaAttempts: UInt64
    let alphaWrites: UInt64
    let programmaticCameraApplies: UInt64
    let programmaticCameraSkips: UInt64
    let mainThreadViolations: UInt64
    let updateUIViewTotalNanoseconds: UInt64
    let updateUIViewMaximumNanoseconds: UInt64
    let visibleRegionTotalNanoseconds: UInt64
    let visibleRegionMaximumNanoseconds: UInt64
    let movementIntervalTotalNanoseconds: UInt64
    let movementIntervalMaximumNanoseconds: UInt64
    let settledUpdateTotalNanoseconds: UInt64
    let settledUpdateMaximumNanoseconds: UInt64
    let reconciliationTotalNanoseconds: UInt64
    let reconciliationMaximumNanoseconds: UInt64

    var compactDescription: String {
        "updates=\(updateUIViewCount) deferred=\(deferredUpdateUIViewCount) visible=\(visibleRegionCount) movements=\(movementIntervalCount) settled=\(settledUpdateCount) reconcile=\(reconciliationCount) overlays=+\(overlayAdditions)/-\(overlayRemovals)/r\(overlayReorders) renderers=\(rendererCreations) reloads=\(reloadDataCalls) alpha=\(alphaWrites)/\(alphaAttempts) camera=\(programmaticCameraApplies)/\(programmaticCameraSkips) mainViolations=\(mainThreadViolations) maxUs(update/visible/movement/settled/reconcile)=\(updateUIViewMaximumNanoseconds / 1_000)/\(visibleRegionMaximumNanoseconds / 1_000)/\(movementIntervalMaximumNanoseconds / 1_000)/\(settledUpdateMaximumNanoseconds / 1_000)/\(reconciliationMaximumNanoseconds / 1_000)"
    }
}

/// Aggregate-only diagnostics for the MapKit bridge. No coordinates, vessel data,
/// waypoint data, or radio-group identifiers are recorded.
nonisolated final class MapStabilityDiagnostics: @unchecked Sendable {
    static let shared = MapStabilityDiagnostics()

    enum Timing { case updateUIView, visibleRegion, movementInterval, settledUpdate, reconciliation }
    enum Counter {
        case deferredUpdateUIView, overlayAddition, overlayRemoval, overlayReorder
        case rendererCreation, reloadData, alphaAttempt, alphaWrite
        case programmaticCameraApply, programmaticCameraSkip, mainThreadViolation
    }

    private let lock = NSLock()
    private var updateUIViewCount: UInt64 = 0
    private var deferredUpdateUIViewCount: UInt64 = 0
    private var visibleRegionCount: UInt64 = 0
    private var movementIntervalCount: UInt64 = 0
    private var settledUpdateCount: UInt64 = 0
    private var reconciliationCount: UInt64 = 0
    private var overlayAdditions: UInt64 = 0
    private var overlayRemovals: UInt64 = 0
    private var overlayReorders: UInt64 = 0
    private var rendererCreations: UInt64 = 0
    private var reloadDataCalls: UInt64 = 0
    private var alphaAttempts: UInt64 = 0
    private var alphaWrites: UInt64 = 0
    private var programmaticCameraApplies: UInt64 = 0
    private var programmaticCameraSkips: UInt64 = 0
    private var mainThreadViolations: UInt64 = 0
    private var updateUIViewTotalNanoseconds: UInt64 = 0
    private var updateUIViewMaximumNanoseconds: UInt64 = 0
    private var visibleRegionTotalNanoseconds: UInt64 = 0
    private var visibleRegionMaximumNanoseconds: UInt64 = 0
    private var movementIntervalTotalNanoseconds: UInt64 = 0
    private var movementIntervalMaximumNanoseconds: UInt64 = 0
    private var settledUpdateTotalNanoseconds: UInt64 = 0
    private var settledUpdateMaximumNanoseconds: UInt64 = 0
    private var reconciliationTotalNanoseconds: UInt64 = 0
    private var reconciliationMaximumNanoseconds: UInt64 = 0

    func record(_ timing: Timing, nanoseconds: UInt64) {
        #if DEBUG
        lock.lock()
        switch timing {
        case .updateUIView:
            updateUIViewCount &+= 1
            updateUIViewTotalNanoseconds &+= nanoseconds
            updateUIViewMaximumNanoseconds = max(updateUIViewMaximumNanoseconds, nanoseconds)
        case .visibleRegion:
            visibleRegionCount &+= 1
            visibleRegionTotalNanoseconds &+= nanoseconds
            visibleRegionMaximumNanoseconds = max(visibleRegionMaximumNanoseconds, nanoseconds)
        case .movementInterval:
            movementIntervalCount &+= 1
            movementIntervalTotalNanoseconds &+= nanoseconds
            movementIntervalMaximumNanoseconds = max(movementIntervalMaximumNanoseconds, nanoseconds)
        case .settledUpdate:
            settledUpdateCount &+= 1
            settledUpdateTotalNanoseconds &+= nanoseconds
            settledUpdateMaximumNanoseconds = max(settledUpdateMaximumNanoseconds, nanoseconds)
        case .reconciliation:
            reconciliationCount &+= 1
            reconciliationTotalNanoseconds &+= nanoseconds
            reconciliationMaximumNanoseconds = max(reconciliationMaximumNanoseconds, nanoseconds)
        }
        lock.unlock()
        #endif
    }

    func increment(_ counter: Counter) {
        #if DEBUG
        lock.lock()
        switch counter {
        case .deferredUpdateUIView: deferredUpdateUIViewCount &+= 1
        case .overlayAddition: overlayAdditions &+= 1
        case .overlayRemoval: overlayRemovals &+= 1
        case .overlayReorder: overlayReorders &+= 1
        case .rendererCreation: rendererCreations &+= 1
        case .reloadData: reloadDataCalls &+= 1
        case .alphaAttempt: alphaAttempts &+= 1
        case .alphaWrite: alphaWrites &+= 1
        case .programmaticCameraApply: programmaticCameraApplies &+= 1
        case .programmaticCameraSkip: programmaticCameraSkips &+= 1
        case .mainThreadViolation: mainThreadViolations &+= 1
        }
        lock.unlock()
        #endif
    }

    func snapshot() -> MapStabilityDiagnosticSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return MapStabilityDiagnosticSnapshot(
            updateUIViewCount: updateUIViewCount,
            deferredUpdateUIViewCount: deferredUpdateUIViewCount,
            visibleRegionCount: visibleRegionCount,
            movementIntervalCount: movementIntervalCount,
            settledUpdateCount: settledUpdateCount,
            reconciliationCount: reconciliationCount,
            overlayAdditions: overlayAdditions,
            overlayRemovals: overlayRemovals,
            overlayReorders: overlayReorders,
            rendererCreations: rendererCreations,
            reloadDataCalls: reloadDataCalls,
            alphaAttempts: alphaAttempts,
            alphaWrites: alphaWrites,
            programmaticCameraApplies: programmaticCameraApplies,
            programmaticCameraSkips: programmaticCameraSkips,
            mainThreadViolations: mainThreadViolations,
            updateUIViewTotalNanoseconds: updateUIViewTotalNanoseconds,
            updateUIViewMaximumNanoseconds: updateUIViewMaximumNanoseconds,
            visibleRegionTotalNanoseconds: visibleRegionTotalNanoseconds,
            visibleRegionMaximumNanoseconds: visibleRegionMaximumNanoseconds,
            movementIntervalTotalNanoseconds: movementIntervalTotalNanoseconds,
            movementIntervalMaximumNanoseconds: movementIntervalMaximumNanoseconds,
            settledUpdateTotalNanoseconds: settledUpdateTotalNanoseconds,
            settledUpdateMaximumNanoseconds: settledUpdateMaximumNanoseconds,
            reconciliationTotalNanoseconds: reconciliationTotalNanoseconds,
            reconciliationMaximumNanoseconds: reconciliationMaximumNanoseconds
        )
    }

    #if DEBUG
    func logSnapshot() {
        os_log(.info, log: Self.log, "%{public}@", snapshot().compactDescription)
    }

    private static let log = OSLog(
        subsystem: "com.curraghfisheries.SatChart",
        category: "MapStability"
    )
    #endif
}

@MainActor protocol MapRendererOpacityTarget: AnyObject {
    var mapRendererAlpha: CGFloat { get set }
}

extension MKOverlayRenderer: MapRendererOpacityTarget {
    var mapRendererAlpha: CGFloat {
        get { alpha }
        set { alpha = newValue }
    }
}

@MainActor final class MapRendererOpacityController {
    /// MapKit opacity is perceptually unchanged below one thousandth, while
    /// avoiding redundant floating-point writes implicated in iOS 18 tile stalls.
    static let epsilon: CGFloat = 0.001

    struct Snapshot: Equatable {
        let attempts: UInt64
        let writes: UInt64
        let trackedRenderers: Int
    }

    private var lastAppliedByRenderer: [ObjectIdentifier: CGFloat] = [:]
    private(set) var attempts: UInt64 = 0
    private(set) var writes: UInt64 = 0

    @discardableResult
    func apply(_ requestedOpacity: CGFloat, to renderer: MapRendererOpacityTarget) -> Bool {
        attempts &+= 1
        MapStabilityDiagnostics.shared.increment(.alphaAttempt)
        let opacity = Self.normalized(requestedOpacity)
        let id = ObjectIdentifier(renderer)
        let previous = lastAppliedByRenderer[id] ?? Self.normalized(renderer.mapRendererAlpha)
        guard abs(previous - opacity) > Self.epsilon else {
            lastAppliedByRenderer[id] = previous
            return false
        }
        renderer.mapRendererAlpha = opacity
        lastAppliedByRenderer[id] = opacity
        writes &+= 1
        MapStabilityDiagnostics.shared.increment(.alphaWrite)
        return true
    }

    func retire(_ renderer: MapRendererOpacityTarget) {
        lastAppliedByRenderer.removeValue(forKey: ObjectIdentifier(renderer))
    }

    func snapshot() -> Snapshot {
        Snapshot(attempts: attempts, writes: writes, trackedRenderers: lastAppliedByRenderer.count)
    }

    static func normalized(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        return min(1, max(0, value))
    }
}

nonisolated struct MapCameraState: Equatable, Sendable {
    static let centerToleranceMeters = 0.75
    static let zoomTolerance = 0.002
    static let angleTolerance = 0.1

    let latitude: Double
    let longitude: Double
    let zoom: Double
    let heading: Double
    let pitch: Double

    func isEffectivelyEqual(to other: MapCameraState) -> Bool {
        guard latitude.isFinite, longitude.isFinite, zoom.isFinite, heading.isFinite, pitch.isFinite,
              other.latitude.isFinite, other.longitude.isFinite, other.zoom.isFinite,
              other.heading.isFinite, other.pitch.isFinite else { return false }
        let meanLatitudeRadians = ((latitude + other.latitude) * 0.5) * .pi / 180
        let latitudeMeters = abs(latitude - other.latitude) * 111_320
        let longitudeMeters = abs(longitude - other.longitude) * 111_320 * max(0.01, abs(cos(meanLatitudeRadians)))
        return hypot(latitudeMeters, longitudeMeters) <= Self.centerToleranceMeters
            && abs(zoom - other.zoom) <= Self.zoomTolerance
            && Self.angularDistance(heading, other.heading) <= Self.angleTolerance
            && abs(pitch - other.pitch) <= Self.angleTolerance
    }

    private static func angularDistance(_ lhs: Double, _ rhs: Double) -> Double {
        let delta = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
        return min(delta, 360 - delta)
    }
}

nonisolated struct MapCameraFeedbackGuard {
    private(set) var lastMapKitEmission: MapCameraState?
    private(set) var lastProgrammaticRequest: MapCameraState?

    mutating func shouldApplyProgrammaticRequest(
        _ requested: MapCameraState,
        current: MapCameraState
    ) -> Bool {
        if requested.isEffectivelyEqual(to: current)
            || lastProgrammaticRequest?.isEffectivelyEqual(to: requested) == true {
            return false
        }
        lastProgrammaticRequest = requested
        return true
    }

    /// Returns true only when a camera binding would need publication.
    mutating func recordMapKitEmission(_ emitted: MapCameraState) -> Bool {
        if let request = lastProgrammaticRequest,
           !request.isEffectivelyEqual(to: emitted) {
            lastProgrammaticRequest = nil
        }
        guard lastMapKitEmission?.isEffectivelyEqual(to: emitted) != true else { return false }
        lastMapKitEmission = emitted
        return true
    }
}

nonisolated struct MapSettledUpdateGate {
    private(set) var generation: UInt64 = 0
    private(set) var isMoving = false
    private var lastSettledGeneration: UInt64?

    @discardableResult
    mutating func beginMovement() -> UInt64 {
        if !isMoving {
            generation &+= 1
            isMoving = true
        }
        return generation
    }

    mutating func noteContinuousMovement() {
        _ = beginMovement()
    }

    mutating func consumeSettledGeneration() -> UInt64? {
        isMoving = false
        guard lastSettledGeneration != generation else { return nil }
        lastSettledGeneration = generation
        return generation
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == generation
    }
}

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
    let offlineInventoryRevision: Int
    let districtMapVisualSettingsBySlug: [String: DistrictMapVisualSettings]
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
        offlineInventoryRevision: Int,
        districtMapVisualSettingsBySlug: [String: DistrictMapVisualSettings],
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
            self.offlineInventoryRevision = offlineInventoryRevision
            self.districtMapVisualSettingsBySlug = districtMapVisualSettingsBySlug.mapValues {
                $0.normalized
            }
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
    private let extendedOfflineMaxZ: Double = 17
    private let extendedOfflineMaxZForTiles: Int = 17
    private let initialLaunchZoom: Double = 12.0

    static func desiredDistrictMapSlugs(
        from packs: [OfflinePack]
    ) -> [DistrictID: String] {
        Dictionary(
            uniqueKeysWithValues: packs.compactMap { pack in
                guard pack.isDistrictMapPack else { return nil }
                return (pack.district, pack.slug)
            }
        )
    }

    func makeCoordinator() -> Coordinator {
        let followBinding = $isFollowingUser
        let cursorTrackingBinding = $isCursorTrackingUser

        let coordinator = Coordinator(
            minZForTiles: minZForTiles,
            maxZ: maxZ,
            maxZForTiles: maxZForTiles,
            extendedOfflineMaxZ: extendedOfflineMaxZ,
            extendedOfflineMaxZForTiles: extendedOfflineMaxZForTiles,
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
        coordinator.currentDistrictMapVisualSettingsBySlug = districtMapVisualSettingsBySlug.mapValues {
            $0.normalized
        }
        // Request counters live in the parent SwiftUI view. A newly created map
        // coordinator must start at the current values or it will replay every zoom
        // tap from the prior MKMapView lifecycle.
        coordinator.lastZoomInReq = zoomInRequest
        coordinator.lastZoomOutReq = zoomOutRequest
        return coordinator
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
        context.coordinator.updateMBTilesViewportHints(map)
        syncSSTOverlay(on: map, coordinator: context.coordinator)
        context.coordinator.lastOfflineInventoryRevision = offlineInventoryRevision
        context.coordinator.hasSynchronizedSwiftUIMapPresentation = true
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
        #if DEBUG
        let startedAt = DispatchTime.now().uptimeNanoseconds
        defer {
            MapStabilityDiagnostics.shared.record(
                .updateUIView,
                nanoseconds: DispatchTime.now().uptimeNanoseconds &- startedAt
            )
        }
        #endif
        #if DEBUG
        if !Thread.isMainThread {
            MapStabilityDiagnostics.shared.increment(.mainThreadViolation)
        }
        #endif

        let coordinator = context.coordinator
        if coordinator.isCameraMovementActive {
            MapStabilityDiagnostics.shared.increment(.deferredUpdateUIView)
            coordinator.deferSwiftUIUpdate { [weak map, weak coordinator] in
                guard let map, let coordinator, coordinator.mapView === map else { return }
                self.applyUpdateUIView(to: map, coordinator: coordinator)
            }
            return
        }

        applyUpdateUIView(to: map, coordinator: coordinator)
    }

    private func applyUpdateUIView(to map: MKMapView, coordinator: Coordinator) {
        // Preserve the existing implementation's `context.coordinator` spelling
        // while allowing the latest SwiftUI value snapshot to be deferred as one
        // replaceable closure during continuous camera movement.
        struct CoordinatorProxy {
            let coordinator: Coordinator
        }
        let context = CoordinatorProxy(coordinator: coordinator)
        let districtAppearanceChanged = context.coordinator.applyDistrictMapVisualSettings(
            districtMapVisualSettingsBySlug,
            on: map
        )

        let previousBasemapChoice = context.coordinator.basemapChoice
        context.coordinator.basemapChoice = basemapChoice
        let basemapChoiceChanged = previousBasemapChoice != basemapChoice

        let selectedMapVersionChanged = context.coordinator.lastSelectedMapVersion
            != selectedMapVersion
        if selectedMapVersionChanged {
            context.coordinator.lastSelectedMapVersion = selectedMapVersion
            context.coordinator.currentSelectedMapVersion = selectedMapVersion
        }

        let offlineInventoryChanged = context.coordinator.lastOfflineInventoryRevision
            != offlineInventoryRevision
        if offlineInventoryChanged {
            context.coordinator.lastOfflineInventoryRevision = offlineInventoryRevision
        }

        let offlinePresentationChanged = districtAppearanceChanged
            || basemapChoiceChanged
            || selectedMapVersionChanged
            || offlineInventoryChanged
            || !context.coordinator.hasSynchronizedSwiftUIMapPresentation
        if offlinePresentationChanged {
            // Keep only the selected version for each district installed, and only
            // while the district basemap is active. Unrelated SwiftUI updates never
            // recalculate the catalog or reconcile these overlays.
            installOrRefreshAllMBTilesOverlays(on: map, coordinator: context.coordinator)
            context.coordinator.syncBasemap(on: map)
            context.coordinator.clampZoomIfNeeded(map)
            context.coordinator.updateMBTilesViewportHints(map)
            context.coordinator.hasSynchronizedSwiftUIMapPresentation = true
        }

        let wantedSSTKey = sstEnabled ? "\(sstSource.rawValue)|\(sstDateUTC)" : nil
        let normalizedSSTOpacity = max(0.0, min(1.0, sstOpacity.isFinite ? sstOpacity : 1.0))
        let sstPresentationChanged = context.coordinator.sstOverlayKey != wantedSSTKey
            || abs(context.coordinator.currentSSTOpacity - normalizedSSTOpacity)
                > Double(MapRendererOpacityController.epsilon)
            || (wantedSSTKey != nil && context.coordinator.sstOverlay == nil)
        if sstPresentationChanged {
            syncSSTOverlay(on: map, coordinator: context.coordinator)
        }

        // Keep gesture hooks attached in case MapKit adds recognizers after view creation.
        // Only re-run occasionally to avoid spamming logs.
        let gestureHookRefreshRequest = followUserRequest + recenterRequest
        if context.coordinator.lastGestureHookRefresh != gestureHookRefreshRequest {
            context.coordinator.lastGestureHookRefresh = gestureHookRefreshRequest
            context.coordinator.installGestureHooksIfNeeded(map)
        }


        // map-version change
        if basemapChoiceChanged || selectedMapVersionChanged {
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

            context.coordinator.uiLog("CursorPan -> apply programmatic center")
            context.coordinator.setCenterIfNeeded(c, on: map, animated: true, timeout: 1.2)
        }

        // Zoom button requests. SwiftUI updates are deliberately coalesced while
        // MapKit is animating, so consume the full counter delta rather than turning
        // a burst of taps into a single level or two competing animations.
        let zoomInDelta = max(0, zoomInRequest - context.coordinator.lastZoomInReq)
        let zoomOutDelta = max(0, zoomOutRequest - context.coordinator.lastZoomOutReq)
        context.coordinator.lastZoomInReq = zoomInRequest
        context.coordinator.lastZoomOutReq = zoomOutRequest
        let netZoomDelta = zoomInDelta - zoomOutDelta
        if netZoomDelta != 0 {
            context.coordinator.zoom(map, delta: netZoomDelta)
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
                context.coordinator.setCenterIfNeeded(loc, on: map, animated: true, timeout: 1.2)
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
            context.coordinator.setCenterIfNeeded(loc, on: map, animated: true, timeout: 1.2)

            // Optional: re-pin cursor on recenter
            context.coordinator.snapCursorToUser(on: map)
        }
    }

    static func dismantleUIView(_ uiView: MKMapView, coordinator: Coordinator) {
        coordinator.prepareForDismantle()
        uiView.delegate = nil
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

        DispatchQueue.global(qos: .utility).async { [weak map, weak coordinator] in
            do {
                let data = try Data(contentsOf: boundariesURL)
                let objects = try MKGeoJSONDecoder().decode(data)
                var polylines: [MKPolyline] = []
                for obj in objects {
                    guard let feature = obj as? MKGeoJSONFeature else { continue }
                    for geometry in feature.geometry {
                        if let line = geometry as? MKPolyline { polylines.append(line) }
                        else if let multiLine = geometry as? MKMultiPolyline {
                            polylines.append(contentsOf: multiLine.polylines)
                        }
                    }
                }
                DispatchQueue.main.async {
                    guard let map, let coordinator, coordinator.mapView === map else { return }
                    coordinator.boundaryLines = polylines
                    polylines.forEach {
                        map.addOverlay($0, level: .aboveLabels)
                        MapStabilityDiagnostics.shared.increment(.overlayAddition)
                    }
                }
            } catch {
                #if DEBUG
                os_log(.error, "District boundaries GeoJSON error: %{public}@", error.localizedDescription)
                #endif
            }
        }
    }

    // MARK: - MBTiles installs
    private func installOrRefreshAllMBTilesOverlays(on map: MKMapView, coordinator: Coordinator) {
        #if DEBUG
        let startedAt = DispatchTime.now().uptimeNanoseconds
        defer {
            MapStabilityDiagnostics.shared.record(
                .reconciliation,
                nanoseconds: DispatchTime.now().uptimeNanoseconds &- startedAt
            )
        }
        #endif
        #if DEBUG
        if !Thread.isMainThread {
            MapStabilityDiagnostics.shared.increment(.mainThreadViolation)
        }
        #endif
        let offlineManager = OfflineMapsManager.shared
        var desired: [(
            pack: OfflinePack,
            url: URL,
            record: InstalledMBTilesRecord?
        )] = []
        var installedRecordsByPath: [String: InstalledMBTilesRecord] = [:]
        for record in offlineManager.installedRecordsSnapshot() {
            installedRecordsByPath[record.url.standardizedFileURL.path] = record
        }

        func desiredEntry(pack: OfflinePack, url: URL) -> (
            pack: OfflinePack,
            url: URL,
            record: InstalledMBTilesRecord?
        ) {
            (pack, url, installedRecordsByPath[url.standardizedFileURL.path])
        }

        // Hidden alpha-zero overlays still generate MapKit tile traffic. Attach only the
        // selected district versions and shoreline layers while that mode is visible.
        if coordinator.basemapChoice == .districtsOffline {
            for district in DistrictID.allCases {
                guard let pack = offlineManager.selectedDownloadedDistrictMapPack(
                    for: district,
                    selectedMapVersion: coordinator.currentSelectedMapVersion
                ), let url = offlineManager.firstExistingLocalMBTilesURL(for: pack) else { continue }
                desired.append(desiredEntry(pack: pack, url: url))
            }
            for pack in OfflinePack.shorelinePacks {
                if let url = offlineManager.firstExistingLocalMBTilesURL(for: pack) {
                    desired.append(desiredEntry(pack: pack, url: url))
                }
            }
        }

        let desiredOverlays: [(
            identity: MBTilesOverlayIdentity,
            pack: OfflinePack,
            url: URL,
            coverageMapRect: MKMapRect?
        )] = desired.map { item in
            let role = MBTilesLayerRole.inferred(from: item.pack.slug)
            let minimumZoom = item.record?.minimumZoom ?? minZForTiles
            let storedMaximumZoom = item.record?.maximumZoom ?? maxZForTiles
            let nativeMaximumZoom = max(
                minimumZoom,
                min(maxZForTiles, storedMaximumZoom)
            )
            let tileSizePixels = item.record.map { record in
                record.tileWidth == record.tileHeight
                    && (record.tileWidth == 256 || record.tileWidth == 512)
                    ? record.tileWidth
                    : 256
            } ?? 256
            let identity = MBTilesOverlayIdentity(
                role: role,
                packageIdentifier: item.pack.isDistrictMapPack ? item.pack.district.rawValue : item.pack.slug,
                packageVersion: offlineManager.installedVersionIdentity(for: item.url) ?? item.pack.slug,
                fileURL: item.url,
                storageSchemeOverride: item.record?.storageScheme
                    ?? MBTilesStorageScheme.explicitLegacyOverride(
                        forPackageSlug: item.pack.slug
                    ),
                tileSizePixels: tileSizePixels,
                minimumZoom: minimumZoom,
                // Offline district and shoreline images above native z15 are drawn
                // directly by the continuity renderer. The camera still reaches z17,
                // but MapKit no longer manufactures 4/16 child requests per parent.
                maximumZoom: role == .district || role == .shoreline
                    ? nativeMaximumZoom
                    : min(extendedOfflineMaxZForTiles, storedMaximumZoom),
                nativeDetailMaximumZoom: nativeMaximumZoom,
                maximumFallbackDepth: 6,
                visualSettings: item.pack.isDistrictMapPack
                    ? (coordinator.currentDistrictMapVisualSettingsBySlug[item.pack.slug] ?? .neutral)
                    : .neutral,
                canReplaceMapContent: false
            )
            return (
                identity,
                item.pack,
                item.url,
                MBTilesGeographicCoverage.mapRect(from: item.record?.bounds)
            )
        }
        // Keep selection truth separate from the temporary installed-overlay set.
        // During a readiness-gated replacement both the old and new versions are
        // installed. Deriving the selected slug from that transient set made a v3
        // selection wrap modulo two entries back to v2, so the new renderer received
        // alpha zero and could never complete its first-tile handoff.
        coordinator.desiredDistrictMapSlugByDistrict = Self.desiredDistrictMapSlugs(
            from: desired.map(\.pack)
        )
        let plan = MBTilesOverlayReconciliationPlan(
            current: Set(coordinator.installedMBTilesOverlays.keys),
            desired: desiredOverlays.map(\.identity)
        )
        guard !plan.isNoOp else { return }
        let additions = Set(plan.additions)
        let removals = Set(plan.removals)
        func logicalLayerKey(_ identity: MBTilesOverlayIdentity) -> String {
            "\(identity.role.rawValue)|\(identity.packageIdentifier)"
        }

        // If a not-yet-ready replacement is itself superseded, carry its last known-good
        // predecessor forward and retire the intermediate overlay instead of stacking versions.
        var carriedRetirements: [String: Set<MBTilesOverlayIdentity>] = [:]
        for (replacement, predecessors) in Array(coordinator.pendingMBTilesRetirements) where removals.contains(replacement) {
            carriedRetirements[logicalLayerKey(replacement), default: []].formUnion(predecessors)
            coordinator.pendingMBTilesRetirements.removeValue(forKey: replacement)
        }

        // Attach validated replacement identities first so a working layer does not
        // disappear between versions. Its predecessor stays below it until MapKit receives
        // real bytes from the replacement; no arbitrary delay or viewport reset is involved.
        for (desiredIndex, item) in desiredOverlays.enumerated() where additions.contains(item.identity) {
            let overlay = MBTilesOverlay(
                mbtilesURL: item.url,
                slug: item.pack.slug,
                packageIdentifier: item.identity.packageIdentifier,
                packageVersion: item.identity.packageVersion,
                role: item.identity.role,
                storageSchemeOverride: item.identity.storageSchemeOverride,
                minimumZoom: item.identity.minimumZoom,
                maximumZoom: item.identity.maximumZoom,
                tileSizePixels: item.identity.tileSizePixels,
                maximumFallbackDepth: item.identity.maximumFallbackDepth,
                canReplaceMapContent: false,
                visualSettings: item.identity.visualSettings,
                nativeDetailMaximumZ: item.identity.nativeDetailMaximumZoom,
                coverageMapRect: item.coverageMapRect,
                immutableFile: offlineManager.isImmutableInstalledURL(item.url)
            )
            let usesNativeContinuity = item.identity.role == .district
                || item.identity.role == .shoreline
            let backstop: DistrictMapBackstopOverlay? = usesNativeContinuity
                ? DistrictMapBackstopOverlay(
                    slug: item.pack.slug,
                    identity: item.identity,
                    packageSession: overlay.packageSession,
                    boundingMapRect: item.coverageMapRect
                )
                : nil
            overlay.rendersThroughBackstop = backstop != nil
            if let backstop {
                coordinator.districtBackstopOverlays[item.identity] = backstop
                backstop.activate()
            }
            // Publish the replacement identity before beginning readiness work.
            // Empty/off-coverage readiness can complete synchronously.
            coordinator.installedMBTilesOverlays[item.identity] = overlay
            let logicalKey = logicalLayerKey(item.identity)
            let directPredecessors = Set(plan.removals.filter { logicalLayerKey($0) == logicalKey })
            let predecessors = carriedRetirements[logicalKey] ?? directPredecessors
            if !predecessors.isEmpty {
                coordinator.pendingMBTilesRetirements[item.identity] = predecessors
                let retirePredecessors = { [weak map, weak coordinator, weak overlay] in
                    DispatchQueue.main.async {
                        guard let map, let coordinator, let overlay,
                              coordinator.mapView === map,
                              coordinator.installedMBTilesOverlays[item.identity] === overlay else { return }
                        let retired = coordinator.pendingMBTilesRetirements.removeValue(forKey: item.identity) ?? []
                        for identity in retired {
                            guard let predecessor = coordinator.installedMBTilesOverlays.removeValue(forKey: identity) else { continue }
                            coordinator.discardRenderer(for: predecessor)
                            map.removeOverlay(predecessor)
                            MapStabilityDiagnostics.shared.increment(.overlayRemoval)
                            if let retiredBackstop = coordinator.districtBackstopOverlays.removeValue(forKey: identity) {
                                coordinator.discardRenderer(for: retiredBackstop)
                                map.removeOverlay(retiredBackstop)
                                MapStabilityDiagnostics.shared.increment(.overlayRemoval)
                            }
                            coordinator.overlayRemovalCount += 1
                        }
                        if !retired.isEmpty { coordinator.overlayReplacementCount += 1 }
                        #if DEBUG
                        os_log(.info, "Activated ready MBTiles replacement %{public}@", item.identity.description)
                        #endif
                    }
                }
                if let backstop {
                    coordinator.retireAfterCurrentVisibleCoverageIsReady(
                        backstop: backstop,
                        on: map,
                        stillValid: { [weak coordinator, weak overlay] in
                            guard let coordinator, let overlay else { return false }
                            return coordinator.installedMBTilesOverlays[item.identity] === overlay
                        },
                        completion: retirePredecessors
                    )
                } else {
                    overlay.whenFirstTileIsReady(retirePredecessors)
                }
            }
            coordinator.overlayAttachmentCount += 1
            #if DEBUG
            os_log(.info, "Attaching MBTiles overlay %{public}@", item.identity.description)
            #endif
            let nextInstalledOverlay = desiredOverlays.dropFirst(desiredIndex + 1).lazy
                .compactMap { coordinator.installedMBTilesOverlays[$0.identity] }
                .first
            if let nextInstalledOverlay {
                map.insertOverlay(overlay, below: nextInstalledOverlay)
            } else if let sstOverlay = coordinator.sstOverlay {
                map.insertOverlay(overlay, below: sstOverlay)
            } else {
                map.addOverlay(overlay, level: .aboveRoads)
            }
            MapStabilityDiagnostics.shared.increment(.overlayAddition)
            if let backstop {
                map.insertOverlay(backstop, below: overlay)
                MapStabilityDiagnostics.shared.increment(.overlayAddition)
            }
        }

        let protectedPredecessors = coordinator.pendingMBTilesRetirements.values.reduce(into: Set<MBTilesOverlayIdentity>()) {
            $0.formUnion($1)
        }
        for identity in plan.removals where !protectedPredecessors.contains(identity) {
            guard let overlay = coordinator.installedMBTilesOverlays.removeValue(forKey: identity) else { continue }
            coordinator.discardRenderer(for: overlay)
            map.removeOverlay(overlay)
            MapStabilityDiagnostics.shared.increment(.overlayRemoval)
            if let backstop = coordinator.districtBackstopOverlays.removeValue(forKey: identity) {
                coordinator.discardRenderer(for: backstop)
                map.removeOverlay(backstop)
                MapStabilityDiagnostics.shared.increment(.overlayRemoval)
            }
            coordinator.overlayRemovalCount += 1
            #if DEBUG
            os_log(.info, "Removing MBTiles overlay %{public}@", identity.description)
            #endif
        }
    }

    private func syncSSTOverlay(on map: MKMapView, coordinator: Coordinator) {
        let wantedKey = sstEnabled ? "\(sstSource.rawValue)|\(sstDateUTC)" : nil

        if wantedKey == nil {
            if let overlay = coordinator.sstOverlay {
                coordinator.discardRenderer(for: overlay)
                map.removeOverlay(overlay)
                MapStabilityDiagnostics.shared.increment(.overlayRemoval)
                coordinator.sstOverlay = nil
                coordinator.sstOverlayKey = nil
            }
            return
        }

        if coordinator.sstOverlayKey != wantedKey {
            if let overlay = coordinator.sstOverlay {
                coordinator.discardRenderer(for: overlay)
                map.removeOverlay(overlay)
                MapStabilityDiagnostics.shared.increment(.overlayRemoval)
            }

            let overlay = SeaSurfaceTemperatureOverlay(source: sstSource, dateUTC: sstDateUTC)
            overlay.minimumZ = 0
            overlay.maximumZ = sstSource.recommendedMaximumZ
            map.addOverlay(overlay, level: .aboveRoads)
            MapStabilityDiagnostics.shared.increment(.overlayAddition)
            coordinator.sstOverlay = overlay
            coordinator.sstOverlayKey = wantedKey
        }

        let clampedOpacity = Double(MapRendererOpacityController.normalized(CGFloat(sstOpacity)))
        if abs(coordinator.currentSSTOpacity - clampedOpacity)
            > Double(MapRendererOpacityController.epsilon) {
            coordinator.currentSSTOpacity = clampedOpacity
            if let overlay = coordinator.sstOverlay,
               let renderer = map.renderer(for: overlay) as? MKTileOverlayRenderer {
                _ = coordinator.rendererOpacityController.apply(
                    CGFloat(clampedOpacity),
                    to: renderer
                )
            }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {

        weak var mapView: MKMapView?

        let minZForTiles: Int
        let maxZ: Double
        let maxZForTiles: Int
        let extendedOfflineMaxZ: Double
        let extendedOfflineMaxZForTiles: Int
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
            let currentZoom = zoomGate.targetZoom ?? zoomLevel(for: mapView)
            let maximumZoom = currentMaximumZoom

            // IMPORTANT:
            // - Do NOT clamp zoom-out to `minZForTiles`. That value is for tile visibility, not user zoom range.
            // - Allow zooming out to the full world (0.0). Keep the max zoom-in clamp for the active basemap.
            let targetZoom = max(0.0, min(maximumZoom, currentZoom + Double(delta)))
            guard targetZoom.isFinite else { return }

            let center = mapView.centerCoordinate
            let rect = mapRect(center: center, zoom: targetZoom, in: mapView)
            let sources = activeRasterContinuities(on: mapView)
            let commit: @MainActor @Sendable () -> Void = { [weak self, weak mapView] in
                guard let self, let mapView, !self.isDismantled else { return }
                self.setVisibleMapRectIfNeeded(rect, on: mapView, animated: true, timeout: 0.8)
            }
            guard !sources.isEmpty else { commit(); return }
            zoomGate.request(targetZoom: targetZoom, preload: { ready in
                RasterMapContinuity.prepareAll(sources, in: rect,
                                               zoom: Int(targetZoom.rounded()), completion: ready)
            }, commit: commit)
        }


        var lastSelectedMapVersion: Int = 0
        private let zoomGate = RasterZoomGate()
        var currentSelectedMapVersion: Int = 1 {
            didSet { if oldValue != currentSelectedMapVersion { zoomGate.cancel() } }
        }
        var currentDistrictMapVisualSettingsBySlug: [String: DistrictMapVisualSettings] = [:]
        var sstOverlay: SeaSurfaceTemperatureOverlay?
        var sstOverlayKey: String?
        var currentSSTOpacity: Double = 0.0

        private var currentMaximumZoom: Double {
            switch basemapChoice {
            case .topoOnline:
                return max(maxZ, Double(USGSTopoOnlineTileOverlay.nativeMaximumZ))
            case .districtsOnline, .districtsOffline, .appleSatellite, .bristolBaySatelliteOffline:
                return extendedOfflineMaxZ
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

        // Stable desired-versus-installed state for local MBTiles overlays.
        var installedMBTilesOverlays: [MBTilesOverlayIdentity: MBTilesOverlay] = [:]
        var districtBackstopOverlays: [MBTilesOverlayIdentity: DistrictMapBackstopOverlay] = [:]
        var pendingMBTilesRetirements: [MBTilesOverlayIdentity: Set<MBTilesOverlayIdentity>] = [:]
        var desiredDistrictMapSlugByDistrict: [DistrictID: String] = [:]
        var rendererByOverlayID: [ObjectIdentifier: MKOverlayRenderer] = [:]
        var overlayAttachmentCount = 0
        var overlayRemovalCount = 0
        var overlayReplacementCount = 0
        var reloadDataCallCount = 0
        private(set) var rendererCreationCount = 0
        let rendererOpacityController = MapRendererOpacityController()
        var hasSynchronizedSwiftUIMapPresentation = false
        var lastOfflineInventoryRevision: Int?
        let schedulerInteractionOwnerID = UUID()

        private var settledUpdateGate = MapSettledUpdateGate()
        #if DEBUG
        private var movementStartedAt: UInt64?
        #endif
        private var cameraFeedbackGuard = MapCameraFeedbackGuard()
        private var deferredSwiftUIUpdate: (() -> Void)?
        private var interactionClearWorkItem: DispatchWorkItem?
        private var cameraSettleWorkItem: DispatchWorkItem?
        private var lastCameraActivityUptime: TimeInterval = 0
        private var deferredCoverageReadiness: [ObjectIdentifier: () -> Void] = [:]
        private var coverageReadinessDrain: [() -> Void] = []
        private var coverageReadinessDrainScheduled = false
        private var schedulerInteractionActive = false
        private var isDismantled = false
        private var lastContinuousViewportHintUptime: TimeInterval = 0
        private let continuousViewportHintInterval: TimeInterval = 0.125
        private let cameraSettleDelay: TimeInterval = 0.150

        var isCameraMovementActive: Bool {
            settledUpdateGate.isMoving
        }

        private func beginCameraMovement() {
            guard !isDismantled else { return }
            #if DEBUG
            if !settledUpdateGate.isMoving {
                movementStartedAt = DispatchTime.now().uptimeNanoseconds
            }
            #endif
            if !settledUpdateGate.isMoving {
                setRasterCameraMovementActive(true)
            }
            lastCameraActivityUptime = ProcessInfo.processInfo.systemUptime
            setSchedulerInteractionActive(true)
            settledUpdateGate.beginMovement()
        }

        private func noteContinuousCameraMovement() {
            beginCameraMovement()
        }

        func deferSwiftUIUpdate(_ update: @escaping () -> Void) {
            // Replace, rather than enqueue, so a rapid stream of unrelated SwiftUI
            // changes retains only the newest value snapshot during a gesture.
            deferredSwiftUIUpdate = update
        }

        private func performDeferredSwiftUIUpdateIfNeeded() {
            let update = deferredSwiftUIUpdate
            deferredSwiftUIUpdate = nil
            update?()
        }

        private func setSchedulerInteractionActive(_ isActive: Bool) {
            guard schedulerInteractionActive != isActive else { return }
            schedulerInteractionActive = isActive
            MBTilesWorkScheduler.shared.setMapInteractionActive(
                isActive,
                ownerID: schedulerInteractionOwnerID
            )
        }

        func prepareForDismantle() {
            isDismantled = true
            zoomGate.cancel()
            setRasterCameraMovementActive(false)
            (noaaBasemapOverlay as? OnlineChartOverlay)?.stopLoading()
            (pendingBasemapPredecessor as? OnlineChartOverlay)?.stopLoading()
            BristolBaySatelliteTileStore.shared.setChartModeActive(false, owner: schedulerInteractionOwnerID)
            chartHandoffRetry?.cancel()
            chartHandoffRetry = nil
            pendingOnlineDistrictVersions.values.forEach { $0.retry?.cancel() }
            pendingOnlineDistrictVersions.removeAll()
            deferredSwiftUIUpdate = nil
            deferredCoverageReadiness.removeAll()
            coverageReadinessDrain.removeAll()
            coverageReadinessDrainScheduled = false
            interactionClearWorkItem?.cancel()
            interactionClearWorkItem = nil
            cameraSettleWorkItem?.cancel()
            cameraSettleWorkItem = nil
            lastCameraActivityUptime = 0
            settledUpdateGate = MapSettledUpdateGate()
            #if DEBUG
            movementStartedAt = nil
            #endif
            setSchedulerInteractionActive(false)
            lastContinuousViewportHintUptime = 0
            programmaticGuardClearWorkItem?.cancel()
            programmaticGuardClearWorkItem = nil
            programmaticRegionChangeUntil = .distantPast
            mapView = nil
        }

        var onlineChartOverlayFactory: (OnlineChartSource) -> OnlineChartOverlay = { source in
            source == .usgs ? USGSTopoOnlineTileOverlay() : NOAAOnlineTileOverlay()
        }
        private var chartHandoffLoading = false
        private var chartHandoffRetry: DispatchWorkItem?
        private var onlineDistrictOverlays: [String: OnlineDistrictTileOverlay] = [:]
        private final class OnlineVersionPreparation {
            let overlay: OnlineDistrictTileOverlay
            var isLoading = false
            var retry: DispatchWorkItem?
            var failures = 0
            init(overlay: OnlineDistrictTileOverlay) { self.overlay = overlay }
            deinit { retry?.cancel() }
        }
        private var pendingOnlineDistrictVersions: [DistrictID: OnlineVersionPreparation] = [:]
        var onlineDistrictOverlayFactory: (OnlineDistrictMap) -> OnlineDistrictTileOverlay = {
            OnlineDistrictTileOverlay(source: $0)
        }

        // Basemap
        var basemapChoice: BasemapChoice = .districtsOnline {
            didSet { if oldValue != basemapChoice { zoomGate.cancel() } }
        }
        private var noaaBasemapOverlay: MKTileOverlay?
        private var pendingBasemapPredecessor: MKTileOverlay?
        private var basemapBackstopByOverlayID: [ObjectIdentifier: DistrictMapBackstopOverlay] = [:]
        private var noaaBasemapKey: String?
        private var lastMBTilesViewportZoom: Double?
        private var lastMBTilesPrefetchAnchor: MBTilesTileCoordinate?
        private var lastMBTilesPrefetchZooms: [Int] = []
        private var lastMBTilesPrefetchIdentities: Set<MBTilesOverlayIdentity> = []

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
        private var programmaticGuardGeneration: UInt64 = 0
        private var programmaticGuardClearWorkItem: DispatchWorkItem?

        /// Wrap programmatic map region changes so `regionWillChange/DidChange` don't treat them as user gestures.
        /// For animated changes, MapKit callbacks can arrive after the next runloop tick, so we keep a timeout.
        func withProgrammaticRegionChange(timeout: TimeInterval = 1.0, _ block: () -> Void) {
            programmaticGuardGeneration &+= 1
            let generation = programmaticGuardGeneration
            programmaticRegionChangeUntil = Date().addingTimeInterval(timeout)
            programmaticGuardClearWorkItem?.cancel()
            block()

            let clear = DispatchWorkItem { [weak self] in
                guard let self,
                      self.programmaticGuardGeneration == generation else { return }
                self.programmaticRegionChangeUntil = .distantPast
                self.programmaticGuardClearWorkItem = nil
            }
            programmaticGuardClearWorkItem = clear
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: clear)
        }

        private var programmaticRegionChange: Bool {
            Date() <= programmaticRegionChangeUntil
        }

        private func cameraState(for mapView: MKMapView) -> MapCameraState {
            MapCameraState(
                latitude: mapView.centerCoordinate.latitude,
                longitude: mapView.centerCoordinate.longitude,
                zoom: zoomLevel(for: mapView),
                heading: mapView.camera.heading,
                pitch: mapView.camera.pitch
            )
        }

        private func cameraState(for rect: MKMapRect, in mapView: MKMapView) -> MapCameraState {
            let center = MKMapPoint(
                x: rect.midX,
                y: rect.midY
            ).coordinate
            let viewWidth = Double(max(mapView.bounds.width, 1))
            let mapPointsPerPoint = rect.size.width / viewWidth
            let zoom = log2(MKMapSize.world.width / (256 * mapPointsPerPoint))
            return MapCameraState(
                latitude: center.latitude,
                longitude: center.longitude,
                zoom: zoom.isFinite ? zoom : 0,
                heading: mapView.camera.heading,
                pitch: mapView.camera.pitch
            )
        }

        @discardableResult
        func setCenterIfNeeded(
            _ center: CLLocationCoordinate2D,
            on mapView: MKMapView,
            animated: Bool,
            timeout: TimeInterval = 1.0
        ) -> Bool {
            guard CLLocationCoordinate2DIsValid(center) else {
                MapStabilityDiagnostics.shared.increment(.programmaticCameraSkip)
                return false
            }
            let current = cameraState(for: mapView)
            let requested = MapCameraState(
                latitude: center.latitude,
                longitude: center.longitude,
                zoom: current.zoom,
                heading: current.heading,
                pitch: current.pitch
            )
            guard cameraFeedbackGuard.shouldApplyProgrammaticRequest(
                requested,
                current: current
            ) else {
                MapStabilityDiagnostics.shared.increment(.programmaticCameraSkip)
                return false
            }
            MapStabilityDiagnostics.shared.increment(.programmaticCameraApply)
            withProgrammaticRegionChange(timeout: timeout) {
                mapView.setCenter(center, animated: animated)
            }
            return true
        }

        @discardableResult
        func setVisibleMapRectIfNeeded(
            _ rect: MKMapRect,
            on mapView: MKMapView,
            animated: Bool,
            timeout: TimeInterval = 1.0
        ) -> Bool {
            guard !rect.isNull, !rect.isEmpty,
                  rect.origin.x.isFinite, rect.origin.y.isFinite,
                  rect.size.width.isFinite, rect.size.height.isFinite else {
                MapStabilityDiagnostics.shared.increment(.programmaticCameraSkip)
                return false
            }
            let current = cameraState(for: mapView)
            let requested = cameraState(for: rect, in: mapView)
            guard cameraFeedbackGuard.shouldApplyProgrammaticRequest(
                requested,
                current: current
            ) else {
                MapStabilityDiagnostics.shared.increment(.programmaticCameraSkip)
                return false
            }
            MapStabilityDiagnostics.shared.increment(.programmaticCameraApply)
            withProgrammaticRegionChange(timeout: timeout) {
                mapView.setVisibleMapRect(rect, animated: animated)
            }
            return true
        }

        private func restoreNorthUpIfNeeded(on mapView: MKMapView) {
            let current = cameraState(for: mapView)
            let requested = MapCameraState(
                latitude: current.latitude,
                longitude: current.longitude,
                zoom: current.zoom,
                heading: 0,
                pitch: current.pitch
            )
            guard cameraFeedbackGuard.shouldApplyProgrammaticRequest(
                requested,
                current: current
            ) else { return }
            let camera = mapView.camera
            camera.heading = 0
            MapStabilityDiagnostics.shared.increment(.programmaticCameraApply)
            withProgrammaticRegionChange(timeout: 0.3) {
                mapView.camera = camera
            }
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
            extendedOfflineMaxZ: Double,
            extendedOfflineMaxZForTiles: Int,
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
            self.extendedOfflineMaxZ = extendedOfflineMaxZ
            self.extendedOfflineMaxZForTiles = extendedOfflineMaxZForTiles
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
                        MapStabilityDiagnostics.shared.increment(.overlayAddition)
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
                discardRenderer(for: overlay)
                mapView.removeOverlay(overlay)
                MapStabilityDiagnostics.shared.increment(.overlayRemoval)
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
                    discardRenderer(for: overlay)
                    mapView.removeOverlay(overlay)
                    MapStabilityDiagnostics.shared.increment(.overlayRemoval)
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
                MapStabilityDiagnostics.shared.increment(.overlayAddition)
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
                discardRenderer(for: overlay)
                mapView.removeOverlay(overlay)
                MapStabilityDiagnostics.shared.increment(.overlayRemoval)
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
                discardRenderer(for: overlay)
                mapView.removeOverlay(overlay)
                MapStabilityDiagnostics.shared.increment(.overlayRemoval)
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
                MapStabilityDiagnostics.shared.increment(.overlayAddition)
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

        private func selectedDistrictMapSlug(for district: DistrictID) -> String? {
            desiredDistrictMapSlugByDistrict[district]
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
        }

        func applyDistrictMapVisualSettings(
            _ settingsBySlug: [String: DistrictMapVisualSettings],
            on mapView: MKMapView
        ) -> Bool {
            let normalized = settingsBySlug.mapValues { $0.normalized }
            guard normalized != currentDistrictMapVisualSettingsBySlug else { return false }
            zoomGate.cancel()
            currentDistrictMapVisualSettingsBySlug = normalized
            // These adjustments alter tile bytes, so identity reconciliation performs
            // a readiness-gated generation handoff. A broad map redraw here would race
            // that handoff and add main-thread work without changing the output.
            _ = mapView
            return true
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
            guard !isDismantled else { return }
            if gr.state == .began {
                dlog("handleGesture began type=\(type(of: gr))")
                beginCameraMovement()
                regionChangeFromUserInteraction = true

                // Immediately disengage Follow on any user pan/zoom gesture.
                // This must also update the SwiftUI binding via onFollowStateChanged.
                if isFollowingUser {
                    disengageFollow()
                }

            } else if gr.state == .changed {
                // Constant-time gesture state only. MapKit's asynchronous tile
                // requests continue independently through the bounded tile engine.
                noteContinuousCameraMovement()
                regionChangeFromUserInteraction = true
            } else if gr.state == .ended || gr.state == .cancelled || gr.state == .failed {

                // Keep follow suppressed through deceleration + next likely GPS tick.
                suppressFollow(for: 2.0)
                scheduleInteractionClear(after: 0.20)
                if let mapView { scheduleCameraSettle(on: mapView) }
            }
        }

        private func scheduleInteractionClear(after delay: TimeInterval) {
            interactionClearWorkItem?.cancel()
            let clear = DispatchWorkItem { [weak self] in
                self?.regionChangeFromUserInteraction = false
                self?.interactionClearWorkItem = nil
            }
            interactionClearWorkItem = clear
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: clear)
        }

        // MARK: - Map callbacks

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            dlog("regionWillChange programmatic=\(programmaticRegionChange) interacting=\(userIsInteracting(with: mapView)) isFollowing=\(isFollowingUser)")
            zoomGate.cancel()
            beginCameraMovement()
            scheduleCameraSettle(on: mapView)
            // MapKit can still be in a "programmatic" window when the user begins to pan
            // (e.g., right after an animated setCenter). So we must check the gesture states.
            if userIsInteracting(with: mapView) {
                regionChangeFromUserInteraction = true
                disengageFollow()   // user gesture => Follow OFF
            }
        }
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            #if DEBUG
            let startedAt = DispatchTime.now().uptimeNanoseconds
            defer {
                MapStabilityDiagnostics.shared.record(
                    .visibleRegion,
                    nanoseconds: DispatchTime.now().uptimeNanoseconds &- startedAt
                )
            }
            #endif
            #if DEBUG
            if !Thread.isMainThread {
                MapStabilityDiagnostics.shared.increment(.mainThreadViolation)
            }
            #endif
            // This is deliberately the entire continuous-camera fast path.
            // No SwiftUI publication, renderer mutation, overlay reconciliation,
            // file/database/image work, camera assignment, or prefetch occurs here.
            noteContinuousCameraMovement()
            // MapKit can enqueue destination tiles before the settled callback. Give
            // the scheduler a tiny, throttled center/zoom hint so those visible
            // requests are stamped with the destination generation instead of being
            // cancelled as stale the instant the gesture settles.
            scheduleCameraSettle(on: mapView)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastContinuousViewportHintUptime >= continuousViewportHintInterval {
                lastContinuousViewportHintUptime = now
                updateMBTilesViewportHints(
                    mapView,
                    allowPrefetch: false,
                    commitGeneration: false
                )
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            scheduleCameraSettle(on: mapView)
        }

        /// MapKit may emit visible-region callbacks at display cadence. Keep one
        /// trailing-edge deadline pump alive instead of allocating and cancelling a
        /// delayed work item for every frame. The pump settles only after a full quiet
        /// interval, so intermediate cameras never commit tile generations.
        private func scheduleCameraSettle(on mapView: MKMapView) {
            guard !isDismantled else { return }
            lastCameraActivityUptime = ProcessInfo.processInfo.systemUptime
            enqueueCameraSettleCheck(on: mapView, after: cameraSettleDelay)
        }

        private func enqueueCameraSettleCheck(
            on mapView: MKMapView,
            after delay: TimeInterval
        ) {
            guard !isDismantled, cameraSettleWorkItem == nil else { return }

            let settle = DispatchWorkItem { [weak self, weak mapView] in
                guard let self else { return }
                self.cameraSettleWorkItem = nil
                guard !self.isDismantled,
                      let mapView,
                      self.mapView === mapView else { return }
                if self.userIsInteracting(with: mapView) {
                    self.enqueueCameraSettleCheck(
                        on: mapView,
                        after: self.cameraSettleDelay
                    )
                    return
                }
                let quietDuration = ProcessInfo.processInfo.systemUptime
                    - self.lastCameraActivityUptime
                if quietDuration < self.cameraSettleDelay {
                    self.enqueueCameraSettleCheck(
                        on: mapView,
                        after: max(0.01, self.cameraSettleDelay - quietDuration)
                    )
                    return
                }
                self.performSettledCameraUpdate(on: mapView)
            }
            cameraSettleWorkItem = settle
            DispatchQueue.main.asyncAfter(
                deadline: .now() + max(0.01, delay),
                execute: settle
            )
        }

        private func performSettledCameraUpdate(on mapView: MKMapView) {
            guard let settledGeneration = settledUpdateGate.consumeSettledGeneration(),
                  settledUpdateGate.isCurrent(settledGeneration) else {
                setSchedulerInteractionActive(false)
                return
            }
            #if DEBUG
            let startedAt = DispatchTime.now().uptimeNanoseconds
            defer {
                MapStabilityDiagnostics.shared.record(
                    .settledUpdate,
                    nanoseconds: DispatchTime.now().uptimeNanoseconds &- startedAt
                )
            }
            #endif
            #if DEBUG
            if let movementStartedAt {
                MapStabilityDiagnostics.shared.record(
                    .movementInterval,
                    nanoseconds: DispatchTime.now().uptimeNanoseconds &- movementStartedAt
                )
                self.movementStartedAt = nil
            }
            #endif

            // If a gesture caused this region change, suppress follow briefly after the gesture ends.
            if regionChangeFromUserInteraction {
                suppressFollow(for: 2.0)
                scheduleInteractionClear(after: 0.25)
            }

            performDeferredSwiftUIUpdateIfNeeded()
            restoreNorthUpIfNeeded(on: mapView)
            clampZoomIfNeeded(mapView)
            updateScale(mapView)
            refreshUserMarker(mapView)
            syncBasemap(on: mapView)
            // A deferred update, north-up correction, or zoom clamp above can begin
            // another MapKit camera generation synchronously. Only the generation
            // that is still settled may commit tile cancellation state.
            guard !settledUpdateGate.isMoving,
                  settledUpdateGate.isCurrent(settledGeneration) else { return }
            setRasterCameraMovementActive(false)
            updateMBTilesViewportHints(mapView)
            _ = cameraFeedbackGuard.recordMapKitEmission(cameraState(for: mapView))
            setSchedulerInteractionActive(false)
            performDeferredCoverageReadinessIfNeeded()

            if programmaticRegionChange {
                programmaticGuardClearWorkItem?.cancel()
                programmaticGuardClearWorkItem = nil
                programmaticRegionChangeUntil = .distantPast
            }

            #if DEBUG
            if MapStabilityDiagnostics.shared.snapshot().settledUpdateCount % 25 == 0 {
                MapStabilityDiagnostics.shared.logSnapshot()
            }
            #endif
        }

        private func performDeferredCoverageReadinessIfNeeded() {
            let pending = Array(deferredCoverageReadiness.values)
            deferredCoverageReadiness.removeAll(keepingCapacity: true)
            coverageReadinessDrain.append(contentsOf: pending)
            scheduleNextCoverageReadinessDrain()
        }

        private func scheduleNextCoverageReadinessDrain() {
            guard !isDismantled,
                  !coverageReadinessDrainScheduled,
                  !coverageReadinessDrain.isEmpty else { return }
            coverageReadinessDrainScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.coverageReadinessDrainScheduled = false
                guard !self.isDismantled,
                      !self.coverageReadinessDrain.isEmpty else { return }
                let next = self.coverageReadinessDrain.removeFirst()
                next()
                self.scheduleNextCoverageReadinessDrain()
            }
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
            BristolBaySatelliteTileStore.shared.setChartModeActive(
                basemapChoice == .topoOnline || basemapChoice == .noaaOnline,
                owner: schedulerInteractionOwnerID
            )
            switch basemapChoice {
            case .districtsOffline:
                // Apple Satellite remains the broad backing map. The Bristol Bay
                // imagery is inserted above it but below every downloaded district
                // overlay, so it fills its coverage area without hiding district maps.
                let hasOfflineBristol = !OfflineMapsManager.shared
                    .localBristolBaySatellitePackages().isEmpty
                switch BasemapLayerPolicy.districtBristolSource(
                    hasDownloadedOfflinePackage: hasOfflineBristol
                ) {
                case .downloadedOffline:
                    syncOfflineBristolBaySatelliteBasemap(on: mapView)
                case .onlineFallback:
                    syncOnlineBristolBaySatelliteBasemap(on: mapView)
                }

            case .appleSatellite:
                if mapView.mapType != .satellite {
                    mapView.mapType = .satellite
                }
                removeNOAABasemap(from: mapView)

            case .districtsOnline:
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
            syncOnlineDistrictMaps(on: mapView)
            if let chart = noaaBasemapOverlay as? OnlineChartOverlay, pendingBasemapPredecessor != nil {
                prepareChartHandoff(chart, on: mapView)
            }
        }

        private func syncOnlineDistrictMaps(on mapView: MKMapView) {
            let desired = basemapChoice == .districtsOnline
                ? OnlineDistrictMapCatalog.selectedMaps(version: currentSelectedMapVersion)
                : []
            let wantedDistricts = Set(desired.map { $0.pack.district })
            for (district, pending) in Array(pendingOnlineDistrictVersions)
                where !wantedDistricts.contains(district) {
                pending.retry?.cancel()
                pendingOnlineDistrictVersions.removeValue(forKey: district)
            }
            for (slug, overlay) in Array(onlineDistrictOverlays)
                where !wantedDistricts.contains(overlay.source.pack.district) {
                onlineDistrictOverlays.removeValue(forKey: slug)
                discardRenderer(for: overlay)
                mapView.removeOverlay(overlay)
                MapStabilityDiagnostics.shared.increment(.overlayRemoval)
            }
            for source in desired {
                let district = source.pack.district
                if let current = onlineDistrictOverlays.values.first(where: { $0.source.pack.district == district }) {
                    if current.source.pack.slug == source.pack.slug {
                        pendingOnlineDistrictVersions.removeValue(forKey: district)?.retry?.cancel()
                        continue
                    }
                    if pendingOnlineDistrictVersions[district]?.overlay.source.pack.slug != source.pack.slug {
                        pendingOnlineDistrictVersions[district]?.retry?.cancel()
                        pendingOnlineDistrictVersions[district] = OnlineVersionPreparation(
                            overlay: onlineDistrictOverlayFactory(source)
                        )
                    }
                    prepareOnlineDistrictVersion(district, on: mapView)
                    continue
                }
                let overlay = onlineDistrictOverlayFactory(source)
                onlineDistrictOverlays[source.pack.slug] = overlay
                MapStabilityDiagnostics.shared.increment(.overlayAddition)
                if let basemap = noaaBasemapOverlay {
                    mapView.insertOverlay(overlay, above: basemap)
                } else {
                    mapView.insertOverlay(overlay, at: 0, level: .aboveRoads)
                }
            }
        }

        private func prepareOnlineDistrictVersion(_ district: DistrictID, on mapView: MKMapView) {
            guard !isDismantled, self.mapView === mapView, basemapChoice == .districtsOnline,
                  !isCameraMovementActive,
                  let pending = pendingOnlineDistrictVersions[district],
                  !pending.isLoading, pending.retry == nil else { return }
            pending.isLoading = true
            let rect = mapView.visibleMapRect
            let zoom = Int(zoomLevel(for: mapView).rounded())
            pending.overlay.continuity.prepare(in: rect, zoom: zoom) {
                [weak self, weak mapView, weak pending] ready in
                DispatchQueue.main.async {
                    guard let self, let mapView, let pending,
                          !self.isDismantled, self.mapView === mapView,
                          self.basemapChoice == .districtsOnline,
                          self.pendingOnlineDistrictVersions[district] === pending else { return }
                    pending.isLoading = false
                    // SwiftUI may have recorded a newer selection before its deferred
                    // reconciliation runs. That makes this completion obsolete too.
                    guard OnlineDistrictMapCatalog.selectedMaps(version: self.currentSelectedMapVersion)
                        .contains(where: { $0.pack.slug == pending.overlay.source.pack.slug }) else { return }
                    // Settling invokes syncBasemap again for the new viewport.
                    guard !self.isCameraMovementActive else { return }
                    let candidate = pending.overlay.continuity
                    let candidateFrame = candidate.snapshot()
                    let hasImagery = candidateFrame.detail?.images.isEmpty == false
                        || candidateFrame.overview?.images.isEmpty == false
                    let isOffscreen = !mapView.visibleMapRect.intersects(candidate.bounds)
                    // A missing/unpublished pyramid is not a replacement map.
                    // Sparse transparent tiles within a real pyramid remain valid.
                    if !ready || (!isOffscreen && !hasImagery) {
                        pending.failures += 1
                        let retry = DispatchWorkItem { [weak self, weak mapView, weak pending] in
                            guard let self, let mapView, let pending,
                                  self.pendingOnlineDistrictVersions[district] === pending else { return }
                            pending.retry = nil
                            self.prepareOnlineDistrictVersion(district, on: mapView)
                        }
                        pending.retry = retry
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + min(2, 0.25 * pow(2, Double(min(pending.failures, 3)))),
                            execute: retry
                        )
                        return
                    }
                    let replacement = pending.overlay.continuity
                    let currentRect = mapView.visibleMapRect
                    let currentZoom = Int(self.zoomLevel(for: mapView).rounded())
                    let expected = replacement.coordinates(in: currentRect, zoom: currentZoom,
                                                           limit: RasterMapContinuity.maximumDetailTiles)
                    let prepared = replacement.snapshot().detail?.coordinates
                    let outsideCoverage = !currentRect.intersects(replacement.bounds)
                    guard outsideCoverage || (!expected.isEmpty && prepared == expected) else {
                        self.prepareOnlineDistrictVersion(district, on: mapView)
                        return
                    }
                    guard let current = self.onlineDistrictOverlays.values.first(where: {
                        $0.source.pack.district == district
                    }) else { return }
                    if let renderer = self.rendererByOverlayID[ObjectIdentifier(current)] as? RasterContinuityRenderer {
                        guard renderer.replacePreparedContinuity(with: replacement) else { return }
                    }
                    let oldSlug = current.source.pack.slug
                    current.adoptPreparedVersion(from: pending.overlay)
                    self.onlineDistrictOverlays.removeValue(forKey: oldSlug)
                    self.onlineDistrictOverlays[current.source.pack.slug] = current
                    self.pendingOnlineDistrictVersions.removeValue(forKey: district)
                }
            }
        }

        func updateMBTilesViewportHints(
            _ mapView: MKMapView,
            allowPrefetch: Bool = true,
            commitGeneration: Bool = true
        ) {
            let zoom = zoomLevel(for: mapView)
            let center = mapView.centerCoordinate
            if allowPrefetch {
                for continuity in activeRasterContinuities(on: mapView) {
                    continuity.prepare(in: mapView.visibleMapRect, zoom: Int(zoom.rounded()))
                }
            }
            var updatedSessions: Set<ObjectIdentifier> = []

            func update(_ overlay: MKTileOverlay?) {
                guard let overlay = overlay as? MBTilesOverlay else { return }
                let sessionID = ObjectIdentifier(overlay.packageSession)
                guard updatedSessions.insert(sessionID).inserted else { return }
                overlay.updateViewport(
                    zoomLevel: zoom,
                    centerCoordinate: center,
                    commitGeneration: commitGeneration
                )
            }

            installedMBTilesOverlays.values.forEach { update($0) }
            update(noaaBasemapOverlay)
            update(pendingBasemapPredecessor)

            if allowPrefetch {
                let basemapCandidates = [noaaBasemapOverlay, pendingBasemapPredecessor]
                    .compactMap { $0 }
                var prefetchedBasemapBackstops: Set<ObjectIdentifier> = []
                for basemap in basemapCandidates {
                    guard let backstop = basemapBackstopByOverlayID[ObjectIdentifier(basemap)],
                          prefetchedBasemapBackstops.insert(ObjectIdentifier(backstop)).inserted,
                          zoom >= backstop.minimumDisplayZoom else { continue }
                    backstop.prefetch(in: mapView.visibleMapRect)
                }
            }

            guard allowPrefetch, basemapChoice == .districtsOffline else {
                if basemapChoice != .districtsOffline {
                    lastMBTilesViewportZoom = nil
                    lastMBTilesPrefetchAnchor = nil
                    lastMBTilesPrefetchZooms = []
                    lastMBTilesPrefetchIdentities = []
                }
                return
            }
            let zoomDirection = lastMBTilesViewportZoom.map { zoom - $0 } ?? 0
            lastMBTilesViewportZoom = zoom
            let currentZoom = Int(zoom.rounded())
            let approachingZoom = zoomDirection < -0.01 ? currentZoom - 1 : currentZoom + 1
            let prefetchZooms = Array(Set([currentZoom, approachingZoom])).sorted()
            let continuityEntries = installedMBTilesOverlays.filter {
                $0.key.role == .district || $0.key.role == .shoreline
            }
            let identities = Set(continuityEntries.map(\.key))
            guard !continuityEntries.isEmpty,
                  let anchor = MBTilesViewportTilePlanner.coordinates(
                    in: mapView.visibleMapRect,
                    zoom: currentZoom,
                    ring: 0,
                    maximumCount: 1
                  ).first else { return }
            guard anchor != lastMBTilesPrefetchAnchor
                    || prefetchZooms != lastMBTilesPrefetchZooms
                    || identities != lastMBTilesPrefetchIdentities else { return }
            lastMBTilesPrefetchAnchor = anchor
            lastMBTilesPrefetchZooms = prefetchZooms
            lastMBTilesPrefetchIdentities = identities

            for (identity, overlay) in continuityEntries {
                if overlay.hasServedRealTile {
                    overlay.prefetch(in: mapView.visibleMapRect, zoomLevels: prefetchZooms)
                }
                if let backstop = districtBackstopOverlays[identity],
                   zoom >= backstop.minimumDisplayZoom {
                    backstop.prefetch(in: mapView.visibleMapRect)
                }
            }
        }

        private func setRasterCameraMovementActive(_ active: Bool) {
            for renderer in rendererByOverlayID.values {
                (renderer as? RasterContinuityRenderer)?.setCameraMovementActive(active)
            }
        }

        private func activeRasterContinuities(on mapView: MKMapView) -> [RasterMapContinuity] {
            mapView.overlays.compactMap { overlay in
                if overlay === pendingBasemapPredecessor, overlay is OnlineChartOverlay { return nil }
                if let backstop = overlay as? DistrictMapBackstopOverlay, backstop.isActive {
                    return backstop.continuity
                }
                if let online = overlay as? OnlineDistrictTileOverlay { return online.continuity }
                if let bay = overlay as? BristolBaySatelliteTileOverlay { return bay.continuity }
                if let chart = overlay as? OnlineChartOverlay { return chart.continuity }
                return nil
            }
        }

        private func syncOnlineBristolBaySatelliteBasemap(on mapView: MKMapView) {
            if mapView.mapType != .satellite {
                mapView.mapType = .satellite
            }

            // Both district modes display native zoom-15 parents at zooms 16–17.
            // Keep the baywide backing imagery available at the same display zooms.
            let displayMaximumZ = basemapChoice == .districtsOffline || basemapChoice == .districtsOnline
                ? extendedOfflineMaxZForTiles
                : maxZForTiles
            let wantedKey = "bristol-bay-satellite:online-overlay:z\(displayMaximumZ)"
            if noaaBasemapKey == wantedKey, noaaBasemapOverlay != nil {
                return
            }

            let overlay = BristolBaySatelliteTileOverlay(
                replacesMapContent: false,
                displayMaximumZ: displayMaximumZ
            )
            insertBasemapOverlay(overlay, on: mapView)
            adoptAttachedBasemap(overlay, key: wantedKey, waitForFirstTile: false, on: mapView)
        }

        private func syncOfflineBristolBaySatelliteBasemap(on mapView: MKMapView) {
            guard let package = OfflineMapsManager.shared.bestLocalBristolBaySatellitePackage(for: mapView.visibleMapRect) else {
                if mapView.mapType != .satellite {
                    mapView.mapType = .satellite
                }
                removeNOAABasemap(from: mapView)
                return
            }

            // Apple Satellite remains the worldwide backing surface. Precise MBTiles
            // bounds keep this downloaded Bristol Bay raster confined to its coverage.
            if mapView.mapType != .satellite {
                mapView.mapType = .satellite
            }

            let packageVersion = OfflineMapsManager.shared.installedVersionIdentity(for: package.url)
                ?? package.url.deletingLastPathComponent().lastPathComponent
            let wantedKey = "bristol-bay-satellite:offline:\(package.url.standardizedFileURL.path):\(packageVersion)"
            if noaaBasemapKey == wantedKey, noaaBasemapOverlay != nil {
                return
            }

            let minimumZoom = package.minZoom ?? 0
            let nativeMaximumZoom = max(
                minimumZoom,
                min(maxZForTiles, package.maxZoom ?? maxZForTiles)
            )
            let overlay = MBTilesOverlay(
                mbtilesURL: package.url,
                slug: package.slug,
                packageVersion: packageVersion,
                role: .basemap,
                storageSchemeOverride: package.storageScheme,
                minimumZoom: minimumZoom,
                // The camera remains free to reach z17, but native z15 parents are
                // drawn by the continuity renderer instead of manufacturing 4/16
                // encoded children for every downloaded Bristol Bay tile.
                maximumZoom: nativeMaximumZoom,
                tileSizePixels: package.tileWidth,
                maximumFallbackDepth: 6,
                canReplaceMapContent: false,
                nativeDetailMaximumZ: nativeMaximumZoom,
                coverageMapRect: package.coverageMapRect,
                immutableFile: OfflineMapsManager.shared.isImmutableInstalledURL(package.url)
            )
            overlay.rendersThroughBackstop = true
            insertBasemapOverlay(overlay, on: mapView)
            let backstop = DistrictMapBackstopOverlay(
                slug: package.slug,
                identity: overlay.identity,
                packageSession: overlay.packageSession,
                boundingMapRect: package.coverageMapRect
            )
            backstop.activate()
            basemapBackstopByOverlayID[ObjectIdentifier(overlay)] = backstop
            mapView.insertOverlay(backstop, below: overlay)
            MapStabilityDiagnostics.shared.increment(.overlayAddition)
            adoptAttachedBasemap(overlay, key: wantedKey, waitForFirstTile: true, on: mapView)
        }


        private func syncUSGSTopoBasemap(on mapView: MKMapView) {
            if mapView.mapType != .standard {
                mapView.mapType = .standard
            }

            let wantedKey = "usgs-topo:online"
            if noaaBasemapKey == wantedKey, noaaBasemapOverlay != nil {
                return
            }

            let overlay = onlineChartOverlayFactory(.usgs)
            insertBasemapOverlay(overlay, on: mapView)
            adoptAttachedBasemap(overlay, key: wantedKey, waitForFirstTile: false, on: mapView)
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

            let packageVersion = OfflineMapsManager.shared.installedVersionIdentity(for: package.url)
                ?? package.url.deletingLastPathComponent().lastPathComponent
            let wantedKey = "offline:\(package.url.standardizedFileURL.path):\(packageVersion)"
            if noaaBasemapKey == wantedKey, noaaBasemapOverlay != nil {
                return
            }

            let overlay = MBTilesOverlay(
                mbtilesURL: package.url,
                slug: package.slug,
                packageVersion: packageVersion,
                role: .basemap,
                storageSchemeOverride: package.storageScheme,
                minimumZoom: package.minZoom ?? 0,
                maximumZoom: package.maxZoom ?? 18,
                tileSizePixels: package.tileWidth,
                canReplaceMapContent: false,
                coverageMapRect: package.coverageMapRect,
                immutableFile: OfflineMapsManager.shared.isImmutableInstalledURL(package.url)
            )
            insertBasemapOverlay(overlay, on: mapView)
            adoptAttachedBasemap(overlay, key: wantedKey, waitForFirstTile: true, on: mapView)
        }

        private func syncOnlineNOAABasemap(on mapView: MKMapView) {
            if mapView.mapType != .standard {
                mapView.mapType = .standard
            }

            let wantedKey = "online"
            if noaaBasemapKey == wantedKey, noaaBasemapOverlay != nil {
                return
            }

            // NOAA chart tiles contain transparent water/background pixels. Keeping
            // MapKit's standard surface alive prevents those pixels from becoming
            // black or briefly exposing an unrelated replacement surface.
            let overlay = onlineChartOverlayFactory(.noaa)
            insertBasemapOverlay(overlay, on: mapView)
            adoptAttachedBasemap(overlay, key: wantedKey, waitForFirstTile: false, on: mapView)
        }

        private func insertBasemapOverlay(_ overlay: MKTileOverlay, on mapView: MKMapView) {
            if let current = noaaBasemapOverlay {
                mapView.insertOverlay(overlay, above: current)
            } else {
                mapView.insertOverlay(overlay, at: 0, level: .aboveRoads)
            }
            MapStabilityDiagnostics.shared.increment(.overlayAddition)
        }

        private func adoptAttachedBasemap(
            _ replacement: MKTileOverlay,
            key: String,
            waitForFirstTile: Bool,
            on mapView: MKMapView
        ) {
            chartHandoffRetry?.cancel()
            chartHandoffRetry = nil
            chartHandoffLoading = false
            let lastKnownGood = pendingBasemapPredecessor ?? noaaBasemapOverlay
            if let superseded = noaaBasemapOverlay,
               superseded !== lastKnownGood,
               superseded !== replacement {
                removeBasemapOverlay(superseded, from: mapView)
            }
            pendingBasemapPredecessor = nil
            noaaBasemapOverlay = replacement
            noaaBasemapKey = key

            if replacement is OnlineChartOverlay, let lastKnownGood, lastKnownGood !== replacement {
                pendingBasemapPredecessor = lastKnownGood
                (lastKnownGood as? OnlineChartOverlay)?.stopLoading(keepVisibleFrame: true)
                return // syncBasemap starts a current-viewport readiness handoff.
            }

            guard waitForFirstTile,
                  let replacement = replacement as? MBTilesOverlay,
                  let lastKnownGood,
                  lastKnownGood !== replacement else {
                if let lastKnownGood, lastKnownGood !== replacement {
                    removeBasemapOverlay(lastKnownGood, from: mapView)
                }
                return
            }

            pendingBasemapPredecessor = lastKnownGood
            let retirePredecessor = { [weak self, weak mapView, weak replacement] in
                DispatchQueue.main.async {
                    guard let self, let mapView, let replacement,
                          self.mapView === mapView,
                          self.noaaBasemapOverlay === replacement else { return }
                    if let predecessor = self.pendingBasemapPredecessor {
                        self.removeBasemapOverlay(predecessor, from: mapView)
                    }
                    self.pendingBasemapPredecessor = nil
                    #if DEBUG
                    os_log(.info, "Activated ready offline basemap %{public}@", replacement.identity.description)
                    #endif
                }
            }
            if let backstop = basemapBackstopByOverlayID[ObjectIdentifier(replacement)] {
                retireAfterCurrentVisibleCoverageIsReady(
                    backstop: backstop,
                    on: mapView,
                    stillValid: { [weak self, weak replacement] in
                        guard let self, let replacement else { return false }
                        return self.noaaBasemapOverlay === replacement
                    },
                    completion: retirePredecessor
                )
                return
            }
            replacement.whenFirstTileIsReady(retirePredecessor)
        }

        private func prepareChartHandoff(_ chart: OnlineChartOverlay, on mapView: MKMapView) {
            guard !isDismantled, self.mapView === mapView, !isCameraMovementActive,
                  noaaBasemapOverlay === chart, !chartHandoffLoading, chartHandoffRetry == nil else { return }
            chartHandoffLoading = true
            let requestedRect = mapView.visibleMapRect
            chart.continuity.prepare(in: requestedRect, zoom: Int(zoomLevel(for: mapView).rounded())) {
                [weak self, weak chart, weak mapView] ready in
                DispatchQueue.main.async {
                    guard let self, let chart, let mapView, !self.isDismantled,
                          self.mapView === mapView, self.noaaBasemapOverlay === chart else { return }
                    self.chartHandoffLoading = false
                    guard !self.isCameraMovementActive else { return }
                    let drawn = mapView.window == nil ||
                        (self.rendererByOverlayID[ObjectIdentifier(chart)] as? RasterContinuityRenderer)?
                            .hasDrawnReadyCoverage(in: mapView.visibleMapRect) == true
                    guard ready, drawn, requestedRect.contains(mapView.visibleMapRect) else {
                        let retry = DispatchWorkItem { [weak self, weak chart, weak mapView] in
                            guard let self, let chart, let mapView else { return }
                            self.chartHandoffRetry = nil
                            self.prepareChartHandoff(chart, on: mapView)
                        }
                        self.chartHandoffRetry = retry
                        DispatchQueue.main.asyncAfter(deadline: .now() + (ready ? 0.1 : 1), execute: retry)
                        return
                    }
                    if let previous = self.pendingBasemapPredecessor {
                        self.removeBasemapOverlay(previous, from: mapView)
                    }
                    self.pendingBasemapPredecessor = nil
                }
            }
        }

        /// A replacement retires its known-good predecessor only when every tile
        /// needed for the *current* viewport is terminal: ordinary pyramid tiles at
        /// lower scales and native parents while overzoomed. Camera changes restart
        /// the check so an obsolete readiness snapshot cannot expose a partial layer.
        func retireAfterCurrentVisibleCoverageIsReady(
            backstop: DistrictMapBackstopOverlay,
            on mapView: MKMapView,
            stillValid: @escaping () -> Bool,
            completion: @escaping () -> Void
        ) {
            prepareCurrentVisibleCoverage(
                backstop: backstop,
                on: mapView,
                attempt: 0,
                maximumAttempts: 12,
                stillValid: stillValid,
                completion: completion
            )
        }

        private func prepareCurrentVisibleCoverage(
            backstop: DistrictMapBackstopOverlay,
            on mapView: MKMapView,
            attempt: Int,
            maximumAttempts: Int,
            stillValid: @escaping () -> Bool,
            completion: @escaping () -> Void
        ) {
            let readinessKey = ObjectIdentifier(backstop)
            guard self.mapView === mapView, stillValid() else {
                deferredCoverageReadiness.removeValue(forKey: readinessKey)
                return
            }
            // A readiness snapshot taken while the camera is moving is obsolete by
            // definition. Wait for the same quiet period used by the camera commit;
            // this keeps a replacement overlay from launching hundreds of requests
            // for a footprint that has already moved away.
            guard !isCameraMovementActive else {
                deferredCoverageReadiness[readinessKey] = {
                    [weak self, weak mapView, weak backstop] in
                    guard let self, let mapView, let backstop else { return }
                    self.prepareCurrentVisibleCoverage(
                        backstop: backstop,
                        on: mapView,
                        attempt: attempt,
                        maximumAttempts: maximumAttempts,
                        stillValid: stillValid,
                        completion: completion
                    )
                }
                return
            }
            deferredCoverageReadiness.removeValue(forKey: readinessKey)
            let mapZoom = Darwin.log2(
                MKMapSize.world.width
                    / (256.0 * (mapView.visibleMapRect.width / Double(max(mapView.bounds.width, 1))))
            )
            let readinessZoom = mapZoom >= backstop.minimumDisplayZoom
                ? backstop.nativeZoom
                : min(
                    backstop.identity.maximumZoom,
                    max(backstop.identity.minimumZoom, Int(mapZoom.rounded()))
                )
            let expectedCoordinates = Set(
                backstop.visibleCoordinates(
                    in: mapView.visibleMapRect,
                    zoom: readinessZoom
                )
            )
            backstop.prepareVisibleCoverageReadiness(
                in: mapView.visibleMapRect,
                zoom: readinessZoom
            ) {
                [weak self, weak mapView] readiness in
                DispatchQueue.main.async {
                    guard let self, let mapView,
                          self.mapView === mapView,
                          stillValid() else { return }
                    // A result launched for the settled camera cannot retire the
                    // last-known-good layer after a new gesture has begun, even when
                    // that gesture remains inside the same tile-coordinate set.
                    if self.isCameraMovementActive {
                        self.prepareCurrentVisibleCoverage(
                            backstop: backstop,
                            on: mapView,
                            attempt: attempt,
                            maximumAttempts: maximumAttempts,
                            stillValid: stillValid,
                            completion: completion
                        )
                        return
                    }
                    let currentMapZoom = Darwin.log2(
                        MKMapSize.world.width
                            / (256.0 * (mapView.visibleMapRect.width / Double(max(mapView.bounds.width, 1))))
                    )
                    let currentReadinessZoom = currentMapZoom >= backstop.minimumDisplayZoom
                        ? backstop.nativeZoom
                        : min(
                            backstop.identity.maximumZoom,
                            max(backstop.identity.minimumZoom, Int(currentMapZoom.rounded()))
                        )
                    let currentCoordinates = Set(
                        backstop.visibleCoordinates(
                            in: mapView.visibleMapRect,
                            zoom: currentReadinessZoom
                        )
                    )
                    if currentReadinessZoom != readinessZoom
                        || currentCoordinates != expectedCoordinates {
                        self.prepareCurrentVisibleCoverage(
                            backstop: backstop,
                            on: mapView,
                            attempt: attempt,
                            maximumAttempts: maximumAttempts,
                            stillValid: stillValid,
                            completion: completion
                        )
                    } else if readiness.isReady {
                        completion()
                    } else if attempt + 1 < maximumAttempts {
                        // Retry transient queue/SQLite failures without requiring a
                        // camera gesture. Exponential backoff is capped so the chain
                        // remains responsive but cannot become a hot retry loop.
                        let retryDelay = min(
                            2.0,
                            0.10 * pow(2.0, Double(attempt))
                        )
                        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self, weak mapView] in
                            guard let self, let mapView else { return }
                            self.prepareCurrentVisibleCoverage(
                                backstop: backstop,
                                on: mapView,
                                attempt: attempt + 1,
                                maximumAttempts: maximumAttempts,
                                stillValid: stillValid,
                                completion: completion
                            )
                        }
                    }
                }
            }
        }

        private func removeBasemapOverlay(_ overlay: MKTileOverlay, from mapView: MKMapView) {
            (overlay as? OnlineChartOverlay)?.stopLoading()
            discardRenderer(for: overlay)
            mapView.removeOverlay(overlay)
            MapStabilityDiagnostics.shared.increment(.overlayRemoval)
            if let backstop = basemapBackstopByOverlayID.removeValue(
                forKey: ObjectIdentifier(overlay)
            ) {
                discardRenderer(for: backstop)
                mapView.removeOverlay(backstop)
                MapStabilityDiagnostics.shared.increment(.overlayRemoval)
            }
        }

        private func removeNOAABasemap(from mapView: MKMapView) {
            if let overlay = noaaBasemapOverlay {
                removeBasemapOverlay(overlay, from: mapView)
            }
            if let predecessor = pendingBasemapPredecessor,
               predecessor !== noaaBasemapOverlay {
                removeBasemapOverlay(predecessor, from: mapView)
            }
            noaaBasemapOverlay = nil
            pendingBasemapPredecessor = nil
            noaaBasemapKey = nil
        }

        // MARK: - Zoom clamp

        func clampZoomIfNeeded(_ mapView: MKMapView) {
            let currentZoom = zoomLevel(for: mapView)
            let maximumZoom = currentMaximumZoom
            guard currentZoom > maximumZoom else { return }

            let center = mapView.centerCoordinate
            let clampedRect = mapRect(center: center, zoom: maximumZoom, in: mapView)
            setVisibleMapRectIfNeeded(
                clampedRect,
                on: mapView,
                animated: false,
                timeout: 0.6
            )
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
                setVisibleMapRectIfNeeded(
                    rect,
                    on: mapView,
                    animated: false,
                    timeout: 1.2
                )
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
                        setCenterIfNeeded(target, on: mapView, animated: true)
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
                discardRenderer(for: old)
                mapView.removeOverlay(old)
                MapStabilityDiagnostics.shared.increment(.overlayRemoval)
            }

            nearestBoundaryHighlightSegment = nil

            guard let segment else { return }
            nearestBoundaryHighlightSegment = segment
            mapView.addOverlay(segment, level: .aboveLabels)
            MapStabilityDiagnostics.shared.increment(.overlayAddition)
        }

        private func removeNearestBoundaryHighlight(from mapView: MKMapView) {
            if let old = nearestBoundaryHighlightSegment {
                discardRenderer(for: old)
                mapView.removeOverlay(old)
                MapStabilityDiagnostics.shared.increment(.overlayRemoval)
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

        @discardableResult
        private func retainRenderer(
            _ renderer: MKOverlayRenderer,
            for overlayID: ObjectIdentifier
        ) -> MKOverlayRenderer {
            rendererCreationCount += 1
            MapStabilityDiagnostics.shared.increment(.rendererCreation)
            rendererByOverlayID[overlayID] = renderer
            return renderer
        }

        func discardRenderer(for overlay: MKOverlay) {
            guard let renderer = rendererByOverlayID.removeValue(
                forKey: ObjectIdentifier(overlay as AnyObject)
            ) else { return }
            rendererOpacityController.retire(renderer)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {

            let overlayID = ObjectIdentifier(overlay as AnyObject)
            if let existing = rendererByOverlayID[overlayID] {
                return existing
            }

            if let backstop = overlay as? DistrictMapBackstopOverlay {
                let renderer = DistrictMapBackstopRenderer(overlay: backstop)
                renderer.setCameraMovementActive(isCameraMovementActive)
                backstop.continuity.prepare(in: mapView.visibleMapRect, zoom: Int(zoomLevel(for: mapView).rounded()))
                _ = rendererOpacityController.apply(tileAlpha(for: backstop.slug), to: renderer)
                return retainRenderer(renderer, for: overlayID)
            }

            if let continuity = (overlay as? OnlineDistrictTileOverlay)?.continuity
                ?? (overlay as? BristolBaySatelliteTileOverlay)?.continuity
                ?? (overlay as? OnlineChartOverlay)?.continuity {
                let renderer = RasterContinuityRenderer(overlay: overlay, continuity: continuity)
                renderer.setCameraMovementActive(isCameraMovementActive)
                continuity.prepare(in: mapView.visibleMapRect, zoom: Int(zoomLevel(for: mapView).rounded()))
                _ = rendererOpacityController.apply(1.0, to: renderer)
                return retainRenderer(renderer, for: overlayID)
            }

            if let source = overlay as? MBTilesOverlay, source.rendersThroughBackstop {
                // Drawing the ordinary tile renderer over the retained renderer
                // doubles translucent edge pixels and reintroduces zoom flashes.
                return retainRenderer(MKOverlayRenderer(overlay: source), for: overlayID)
            }

            if let tile = overlay as? MKTileOverlay {
                let r = MKTileOverlayRenderer(tileOverlay: tile)

                if tile is SeaSurfaceTemperatureOverlay {
                    _ = rendererOpacityController.apply(CGFloat(currentSSTOpacity), to: r)
                } else if let mb = tile as? MBTilesOverlay {
                    _ = rendererOpacityController.apply(tileAlpha(for: mb.slug), to: r)
                } else {
                    _ = rendererOpacityController.apply(1.0, to: r)
                }

                return retainRenderer(r, for: overlayID)
            }

            if let line = overlay as? MKPolyline,
               let trail = liveTrailMetadataByOverlayID[ObjectIdentifier(line)] {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = radioPinUIColor(ownerUid: trail.ownerUid, colorID: trail.colorID)
                    .withAlphaComponent(liveTrailOpacity(for: trail.createdAt))
                r.lineWidth = 2.0
                r.lineCap = .round
                r.lineJoin = .round
                return retainRenderer(r, for: overlayID)
            }

            if let line = overlay as? MKPolyline,
               fishingSetOverlays.values.contains(where: { $0 === line }) {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = UIColor.systemRed.withAlphaComponent(0.95)
                r.lineWidth = 2.2
                r.lineCap = .round
                r.lineJoin = .round
                return retainRenderer(r, for: overlayID)
            }

            if let line = overlay as? MKPolyline,
               let stationTransect = portMollerTestFisheryTransectOverlay,
               line === stationTransect {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = UIColor.systemTeal.withAlphaComponent(0.95)
                r.lineWidth = 2.5
                r.lineDashPattern = [6, 4]
                return retainRenderer(r, for: overlayID)
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

                return retainRenderer(r, for: overlayID)
            }

            return retainRenderer(MKOverlayRenderer(overlay: overlay), for: overlayID)
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
