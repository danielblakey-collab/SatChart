import SwiftUI
import Firebase
import CoreLocation
import MapKit
import UIKit
import Combine
import Foundation
import GRDB
import Charts
import AVFoundation
import UniformTypeIdentifiers
// MARK: - Shared options

enum LiveLocationUpdateOption: String, CaseIterable, Identifiable {
    case thirtySeconds = "30s"
    case oneMinute = "60s"
    case fiveMinutes = "300s"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .thirtySeconds: return "30 sec"
        case .oneMinute: return "1 min"
        case .fiveMinutes: return "5 min"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .thirtySeconds: return 30
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        }
    }
}

private struct ActiveFishingSetSession {
    let id: UUID
    let setNumber: Int
    let startedAt: Date
    var startTide: SmartFishingSetTideSnapshot?
    var locations: [SmartFishingSetLocation]
}

private final class KDLGRadioPlayer: ObservableObject {
    @Published private(set) var isOn: Bool = false
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var lastErrorMessage: String? = nil

    private let streamCandidates: [URL] = [
        URL(string: "https://peace.streamguys1.com:6095/kdlg-mp3")!,
        URL(string: "http://peace.str3am.com:6090/kdlg")!
    ]
    private let audioSession = AVAudioSession.sharedInstance()
    private let startupTimeout: TimeInterval = 10
    private let failureMessage = "KDLG stream unavailable right now."

    private var player: AVPlayer?
    private var playerTimeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var failedToPlayObserver: NSObjectProtocol?
    private var startupFallbackWorkItem: DispatchWorkItem?
    private var activeCandidateIndex: Int = 0
    private var hasConfirmedPlayback: Bool = false

    deinit {
        cleanupObservers()
        startupFallbackWorkItem?.cancel()
        player?.pause()
    }

    func togglePlayback() {
        if isOn {
            stop()
        } else {
            play()
        }
    }

    func play() {
        DispatchQueue.main.async {
            self.lastErrorMessage = nil
            self.isOn = true
            self.isPlaying = false
            self.hasConfirmedPlayback = false
            self.playCandidate(at: 0)
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.isOn = false
            self.isPlaying = false
            self.hasConfirmedPlayback = false
            self.lastErrorMessage = nil
            self.activeCandidateIndex = 0
            self.teardownPlayer(deactivateAudioSession: true)
        }
    }

    private func playCandidate(at index: Int) {
        guard streamCandidates.indices.contains(index) else {
            isOn = false
            isPlaying = false
            lastErrorMessage = failureMessage
            activeCandidateIndex = 0
            teardownPlayer(deactivateAudioSession: true)
            return
        }

        activeCandidateIndex = index
        isPlaying = false
        hasConfirmedPlayback = false
        teardownPlayer(deactivateAudioSession: false)

        let item = AVPlayerItem(url: streamCandidates[index])
        item.preferredForwardBufferDuration = 4

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player

        observe(player: player, item: item, candidateIndex: index)

        try? audioSession.setCategory(.playback, mode: .default, options: [.allowAirPlay])
        try? audioSession.setActive(true)

        player.play()
        scheduleStartupFallback(for: index)
    }

    private func observe(player: AVPlayer, item: AVPlayerItem, candidateIndex: Int) {
        playerTimeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.isOn, self.activeCandidateIndex == candidateIndex else { return }
                self.isPlaying = player.timeControlStatus == .playing
                if player.timeControlStatus == .playing {
                    self.hasConfirmedPlayback = true
                    self.startupFallbackWorkItem?.cancel()
                    self.startupFallbackWorkItem = nil
                }
            }
        }

        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard let self else { return }
            guard item.status == .failed else { return }
            DispatchQueue.main.async {
                self.handleCandidateFailure(candidateIndex: candidateIndex)
            }
        }

        failedToPlayObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.handleCandidateFailure(candidateIndex: candidateIndex)
        }
    }

    private func scheduleStartupFallback(for candidateIndex: Int) {
        startupFallbackWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isOn,
                  self.activeCandidateIndex == candidateIndex,
                  !self.hasConfirmedPlayback else { return }
            self.handleCandidateFailure(candidateIndex: candidateIndex)
        }

        startupFallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + startupTimeout, execute: workItem)
    }

    private func handleCandidateFailure(candidateIndex: Int) {
        guard isOn, activeCandidateIndex == candidateIndex else { return }

        let nextIndex = candidateIndex + 1
        guard streamCandidates.indices.contains(nextIndex) else {
            isOn = false
            isPlaying = false
            lastErrorMessage = failureMessage
            activeCandidateIndex = 0
            teardownPlayer(deactivateAudioSession: true)
            return
        }

        playCandidate(at: nextIndex)
    }

    private func teardownPlayer(deactivateAudioSession: Bool) {
        startupFallbackWorkItem?.cancel()
        startupFallbackWorkItem = nil
        isPlaying = false
        cleanupObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil

        if deactivateAudioSession {
            try? audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    private func cleanupObservers() {
        playerTimeControlObservation?.invalidate()
        playerTimeControlObservation = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil

        if let failedToPlayObserver {
            NotificationCenter.default.removeObserver(failedToPlayObserver)
            self.failedToPlayObserver = nil
        }
    }
}


// MARK: - Shared Menu/Tab styling colors

private let bbMenuBlueUIColor_MV = UIColor(red: 0.03, green: 0.23, blue: 0.48, alpha: 1.0)
private let bbMenuBlue_MV = Color(uiColor: bbMenuBlueUIColor_MV)
private let menuPageBackgroundTop_MV = Color(red: 0.02, green: 0.15, blue: 0.30)
private let menuPageBackgroundBottom_MV = Color(red: 0.01, green: 0.08, blue: 0.18)

private enum MapViewTideStationPreference {
    static let storageKey = "tidesWeatherPreferredStationID"

    static func stationID(from rawValue: String?) -> String? {
        let trimmed = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Keep each coordinate field's modifier chain behind a concrete view boundary.
/// This prevents SwiftUI from building one deeply nested generic type for all six
/// fields, which can overflow the Swift runtime metadata decoder on physical devices.
private struct HUDCoordinateInputField: View {
    @Environment(\.navigationReadoutBackgroundsVisible) private var showsBackgrounds
    let placeholder: String
    @Binding var text: String
    let width: CGFloat
    let keyboardType: UIKeyboardType
    let onSubmit: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .tint(.blue)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.characters)
            .keyboardType(keyboardType)
            .submitLabel(.done)
            .focused($isFocused)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .frame(width: width, height: 20)
            .background(Color.white.opacity(showsBackgrounds ? 0.16 : 0))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(showsBackgrounds ? (isFocused ? Color.blue : Color.white.opacity(0.12)) : Color.clear, lineWidth: 1)
            )
            .onSubmit {
                onSubmit()
                isFocused = false
            }
    }
}

private struct HUDCoordinateEntryFields: View {
    @Binding var latitudeDegrees: String
    @Binding var latitudeMinutes: String
    @Binding var latitudeHemisphere: String
    @Binding var longitudeDegrees: String
    @Binding var longitudeMinutes: String
    @Binding var longitudeHemisphere: String
    let onSubmit: () -> Void
    var stacked = false
    var scrollsHorizontally = true

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: 4) {
                coordinateGroup(
                    degrees: $latitudeDegrees,
                    minutes: $latitudeMinutes,
                    hemisphere: $latitudeHemisphere,
                    hemispherePlaceholder: "N/S"
                )
                coordinateGroup(
                    degrees: $longitudeDegrees,
                    minutes: $longitudeMinutes,
                    hemisphere: $longitudeHemisphere,
                    hemispherePlaceholder: "E/W"
                )
            }
            .fixedSize(horizontal: true, vertical: true)
        } else {
            inlineFields
        }
    }

    @ViewBuilder
    private var inlineFields: some View {
        if scrollsHorizontally {
            // Prefer the fields' natural width so the surrounding background
            // hugs the coordinates. Keep scrolling for constrained layouts.
            ViewThatFits(in: .horizontal) {
                coordinateRow
                ScrollView(.horizontal, showsIndicators: false) {
                    coordinateRow
                }
            }
        } else {
            coordinateRow
        }
    }

    private var coordinateRow: some View {
        HStack(spacing: 6) {
            coordinateGroup(
                degrees: $latitudeDegrees,
                minutes: $latitudeMinutes,
                hemisphere: $latitudeHemisphere,
                hemispherePlaceholder: "N/S"
            )

            coordinateGroup(
                degrees: $longitudeDegrees,
                minutes: $longitudeMinutes,
                hemisphere: $longitudeHemisphere,
                hemispherePlaceholder: "E/W"
            )
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func coordinateGroup(
        degrees: Binding<String>,
        minutes: Binding<String>,
        hemisphere: Binding<String>,
        hemispherePlaceholder: String
    ) -> some View {
        HStack(spacing: 3) {
            HUDCoordinateInputField(
                placeholder: "Deg",
                text: degrees,
                width: 34,
                keyboardType: .numbersAndPunctuation,
                onSubmit: onSubmit
            )
            HUDCoordinateInputField(
                placeholder: "Min",
                text: minutes,
                width: 57,
                keyboardType: .numbersAndPunctuation,
                onSubmit: onSubmit
            )
            HUDCoordinateInputField(
                placeholder: hemispherePlaceholder,
                text: hemisphere,
                width: 30,
                keyboardType: .asciiCapable,
                onSubmit: onSubmit
            )
        }
    }
}

// MARK: - MapView (main map screen)

struct MapView: View {

    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var locationManager = LocationManager()
    @StateObject private var offline = OfflineMapsManager.shared
    @StateObject private var onlineDistrictAvailability = OnlineDistrictMapAvailability.shared

    @StateObject private var pinSettings = RadioGroupPinSettings()
    @EnvironmentObject private var authStore: AuthStateStore
    @EnvironmentObject private var radioGroup: RadioGroupStore
    @StateObject private var sstAvailability = SeaSurfaceTemperatureAvailabilityStore()
    @StateObject private var kdlgRadioPlayer = KDLGRadioPlayer()
    @StateObject private var smartLogbookStore = SmartLogbookStore()

    @State private var distanceText: String = "—"
    @State private var speedText: String = "—"
    @State private var metersPerPoint: Double = 0

    @State private var followReq: Int = 0
    @State private var recenterReq: Int = 0
    @State private var zoomInReq: Int = 0
    @State private var zoomOutReq: Int = 0

    @AppStorage("selectedMapVersion") private var selectedMapVersion: Int = 1
    @AppStorage("selectedOnlineMapVersion") private var selectedOnlineMapVersion: Int = 4
    @AppStorage("districtMapVisualSettingsBySlugV1") private var districtMapVisualSettingsBySlugRaw: String = "{}"
    @AppStorage("districtMapAppearanceSelectedSlug") private var districtMapAppearanceSelectedSlug: String = ""
    @State private var isFollowing: Bool = false

    private let tidesWeatherService = NOAACoopsTidesWeatherService()
    private let tideHUDFallbackCoordinate = CLLocationCoordinate2D(latitude: 58.7, longitude: -157.5)

    @State private var tideHUDSnapshot: TidesWeatherSnapshot? = nil
    @State private var tideHUDIsLoading: Bool = false
    @State private var tideHUDErrorMessage: String? = nil
    @State private var showTidesWeatherPage: Bool = false

    // Cursor
    @State private var cursorCoordinate: CLLocationCoordinate2D? = nil
    @State private var cursorDistanceText: String = "—"
    @State private var cursorCoordText: String = "—"

    @State private var cursorLatDegInput: String = ""
    @State private var cursorLatMinInput: String = ""
    @State private var cursorLatHemInput: String = "N"
    @State private var cursorLonDegInput: String = ""
    @State private var cursorLonMinInput: String = ""
    @State private var cursorLonHemInput: String = "W"
    @State private var cursorPanRequest: Int = 0
    @State private var isCursorTrackingUser: Bool = true

    // Sharing
    @AppStorage("radioPinDisplayName") private var radioPinDisplayName: String = ""
    @AppStorage("defaultWaypointPinColorID") private var defaultWaypointPinColorID: String = ""
    @AppStorage("liveLocationUpdateOption") private var liveLocationUpdateOptionRaw: String = LiveLocationUpdateOption.oneMinute.rawValue
    @AppStorage("basemapChoice") private var basemapChoiceRaw: String = BasemapChoice.districtsOnline.rawValue
    @AppStorage("didMigrateDefaultBasemapToBristolBaySatelliteV1") private var didMigrateDefaultBasemapToBristolBaySatelliteV1: Bool = false
    @AppStorage("sstEnabled") private var sstEnabled: Bool = false
    @AppStorage("sstOpacity") private var sstOpacity: Double = 0.55
    @AppStorage("sstSource") private var sstSourceRaw: String = SeaSurfaceTemperatureSource.gibsMURHighDetail.rawValue
    @AppStorage("sstDateUTC") private var sstDateUTC: String = SeaSurfaceTemperatureOverlay.defaultDateUTC()
    @AppStorage("showPortMollerTestFisheryStations") private var showPortMollerTestFisheryStations: Bool = true
    @AppStorage("navShowTopHUDDisplay") private var showNavTopHUDDisplay: Bool = true
    @AppStorage("navTopHUDOpacity") private var showNavTopHUDOpacity: Bool = true
    @AppStorage("navTopHUDCollapsed") private var isTopHUDCollapsed: Bool = false
    @AppStorage("navShowTideHUD") private var showNavTideHUD: Bool = true
    @AppStorage("navShowLocationReadout") private var showNavLocationReadout: Bool = true
    @AppStorage("navShowBoundaryReadout") private var showNavBoundaryReadout: Bool = true
    @AppStorage("navShowSpeedReadout") private var showNavSpeedReadout: Bool = true
    @AppStorage("navShowWindReadout") private var showNavWindReadout: Bool = true
    @AppStorage("navShowKDLGButton") private var showNavKDLGButton: Bool = true
    @AppStorage("navShowScaleBar") private var showNavScaleBar: Bool = true
    @AppStorage("navShowOceanLayerLegend") private var showNavOceanLayerLegend: Bool = true
    @AppStorage("navShowFollowUserButton") private var showNavFollowUserButton: Bool = true
    @AppStorage("navShowRecenterButton") private var showNavRecenterButton: Bool = true
    @AppStorage("navShowBasemapButton") private var showNavBasemapButton: Bool = true
    @AppStorage("navShowMainMenuButton") private var showNavMainMenuButton: Bool = true
    @AppStorage("navShowOceanLayersButton") private var showNavOceanLayersButton: Bool = true
    @AppStorage("navShowShareLiveButton") private var showNavShareLiveButton: Bool = true
    @AppStorage("navShowLiveLocationTrail") private var showNavLiveLocationTrail: Bool = true
    @AppStorage("navShowSendLocationButton") private var showNavSendLocationButton: Bool = true
    @AppStorage("navShowRecordSetButton") private var showNavRecordSetButton: Bool = true
    @AppStorage("navShowCreateWaypointButton") private var showNavCreateWaypointButton: Bool = true
    @AppStorage("navShowZoomInButton") private var showNavZoomInButton: Bool = true
    @AppStorage("navShowZoomOutButton") private var showNavZoomOutButton: Bool = true
    @AppStorage("navShowMapSelector") private var showNavMapSelector: Bool = true
    @AppStorage(MapViewTideStationPreference.storageKey) private var tidesWeatherPreferredStationIDRaw: String = ""

    @State private var showConfirmLiveShare: Bool = false
    @State private var showConfirmStopLiveShare: Bool = false
    @State private var showConfirmShareOnce: Bool = false
    @State private var shareOnceFlashUntil: Date? = nil

    @State private var toastMessage: String? = nil
    @State private var toastUntil: Date? = nil
    @State private var bigToastMessage: String? = nil
    @State private var bigToastUntil: Date? = nil

    @State private var liveShareTimer: AnyCancellable? = nil
    @State private var isStartingLiveSharing: Bool = false
    @State private var isSendingLiveLocation: Bool = false
    @State private var showLiveShareResumeBanner: Bool = false
    @State private var liveShareResumeBannerUntil: Date? = nil
    @State private var nowTick: Date = Date()
    @State private var lastExpiredOwnPinCleanupAt: Date? = nil

    private var liveUpdateSeconds: TimeInterval {
        LiveLocationUpdateOption(rawValue: liveLocationUpdateOptionRaw)?.seconds
        ?? LiveLocationUpdateOption.oneMinute.seconds
    }

    private func debugLiveShareLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[LiveShare][MapView] \(message())")
        #endif
    }

    private var shouldPreferBristolBaySatelliteDefault: Bool {
        BasemapDefaultPolicy.shouldPreferBristolBaySatelliteOnline(
            rawValue: basemapChoiceRaw,
            didMigrate: didMigrateDefaultBasemapToBristolBaySatelliteV1
        )
    }

    private var basemapChoice: BasemapChoice {
        BasemapDefaultPolicy.choice(
            rawValue: basemapChoiceRaw,
            didMigrate: didMigrateDefaultBasemapToBristolBaySatelliteV1
        )
    }

    private var districtMapVisualSettingsBySlug: [String: DistrictMapVisualSettings] {
        guard let data = districtMapVisualSettingsBySlugRaw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(
                [String: DistrictMapVisualSettings].self,
                from: data
              ) else {
            return [:]
        }

        return decoded.reduce(into: [:]) { result, entry in
            guard DistrictID.district(forDistrictMapSlug: entry.key) != nil else { return }
            let normalizedSettings = entry.value.normalized
            if !normalizedSettings.isNeutral {
                result[entry.key] = normalizedSettings
            }
        }
    }

    private var downloadedDistrictMapPacks: [OfflinePack] {
        DistrictID.allCases.flatMap { offline.downloadedDistrictMapPacks(for: $0) }
    }

    private func persistDistrictMapVisualSettings(
        _ settings: DistrictMapVisualSettings,
        forSlug slug: String
    ) {
        guard DistrictID.district(forDistrictMapSlug: slug) != nil else { return }

        var settingsBySlug = districtMapVisualSettingsBySlug
        let normalizedSettings = settings.normalized
        if normalizedSettings.isNeutral {
            settingsBySlug.removeValue(forKey: slug)
        } else {
            settingsBySlug[slug] = normalizedSettings
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(settingsBySlug),
              let storageValue = String(data: data, encoding: .utf8) else {
            return
        }
        districtMapVisualSettingsBySlugRaw = storageValue
    }

    private func presentDistrictMapAppearanceEditor() {
        let downloadedPacks = downloadedDistrictMapPacks
        if !downloadedPacks.contains(where: { $0.slug == districtMapAppearanceSelectedSlug }) {
            districtMapAppearanceSelectedSlug = downloadedPacks.first?.slug ?? ""
        }
        showDistrictMapAppearanceEditor = true
    }

    private var basemapChoiceBinding: Binding<BasemapChoice> {
        Binding(
            get: { basemapChoice },
            set: {
                basemapChoiceRaw = $0.rawValue
                didMigrateDefaultBasemapToBristolBaySatelliteV1 = true
            }
            )
        }

    private var globalMapVersionCount: Int {
        basemapChoice == .districtsOnline
            ? OnlineDistrictMapCatalog.versions(in: onlineDistrictAvailability.maps).count
            : offline.maximumDownloadedDistrictMapVersionCount()
    }

    private var selectedMapCycleVersion: Int {
        basemapChoice == .districtsOnline
            ? OnlineDistrictMapCatalog.normalizedVersion(selectedOnlineMapVersion, in: onlineDistrictAvailability.maps)
            : max(1, min(selectedMapVersion, globalMapVersionCount))
    }

    private var selectedMapVersionBinding: Binding<Int> {
        Binding(
            get: { selectedMapCycleVersion },
            set: {
                if basemapChoice == .districtsOnline {
                    selectedOnlineMapVersion = OnlineDistrictMapCatalog.normalizedVersion($0, in: onlineDistrictAvailability.maps)
                } else {
                    selectedMapVersion = max(1, $0)
                }
            }
        )
    }

    private var mapVersionButtonLabel: String {
        "Map v\(selectedMapCycleVersion)"
    }

    private func cycleToNextMapVersion() {
        if basemapChoice == .districtsOnline {
            selectedOnlineMapVersion = OnlineDistrictMapCatalog.nextVersion(after: selectedMapCycleVersion, in: onlineDistrictAvailability.maps)
            return
        }
        let maxVersion = globalMapVersionCount
        selectedMapVersion = selectedMapCycleVersion >= maxVersion ? 1 : selectedMapCycleVersion + 1
    }

    private var sstSource: SeaSurfaceTemperatureSource {
        guard let source = SeaSurfaceTemperatureSource(rawValue: sstSourceRaw),
              SeaSurfaceTemperatureSource.selectableCases.contains(source) else {
            return .gibsMURHighDetail
        }
        return source
    }

    // Waypoints
    @State private var waypoints: [Waypoint] = []
    @State private var didLoadPersistedWaypoints: Bool = false

    // Menu sheet
    @State private var showMenu: Bool = false
    @State private var showSSTControls: Bool = false
    @State private var showDistrictMapAppearanceEditor: Bool = false

    // Waypoint prompt
    @State private var showCreateWaypointPrompt: Bool = false
    @State private var pendingWaypointName: String = ""

    // Fishing set recorder
    @State private var showStartSetPrompt: Bool = false
    @State private var recordingSetFlashUntil: Date? = nil
    @State private var activeSetSession: ActiveFishingSetSession? = nil
    @State private var setTrackingTimer: AnyCancellable? = nil
    @State private var completedSetDraft: SmartFishingSetRecord? = nil
    @State private var showCompletedSetPrompt: Bool = false
    @State private var setCatchPoundsText: String = ""
    @State private var setCatchFishCountText: String = ""
    @State private var setNotesText: String = ""
    @State private var setPickingMinutes: Int = -1
    @State private var setDisplayOnMap: Bool = false
    @State private var isResolvingSetTide: Bool = false
    @State private var showFishTicketOCRScreen: Bool = false

    // MARK: - Cursor input helpers

    private func splitLat(_ c: CLLocationCoordinate2D) -> (deg: Int, min: Double, hem: String) {
        let hem = c.latitude >= 0 ? "N" : "S"
        let absDeg = abs(c.latitude)
        let d = Int(absDeg)
        let minutes = (absDeg - Double(d)) * 60.0
        return (d, minutes, hem)
    }

    private func splitLon(_ c: CLLocationCoordinate2D) -> (deg: Int, min: Double, hem: String) {
        let hem = c.longitude >= 0 ? "E" : "W"
        let absDeg = abs(c.longitude)
        let d = Int(absDeg)
        let minutes = (absDeg - Double(d)) * 60.0
        return (d, minutes, hem)
    }

    private func parseLatComponents() -> Double? {
        let dStr = cursorLatDegInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let mStr = cursorLatMinInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let h = cursorLatHemInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        guard let d = Int(dStr) else { return nil }
        guard let m = Double(mStr.replacingOccurrences(of: ",", with: ".")) else { return nil }
        guard d >= 0, d <= 90, m >= 0, m < 60 else { return nil }
        guard h == "N" || h == "S" else { return nil }

        var value = Double(d) + (m / 60.0)
        if h == "S" { value = -value }
        return value
    }

    private func parseLonComponents() -> Double? {
        let dStr = cursorLonDegInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let mStr = cursorLonMinInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let h = cursorLonHemInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        guard let d = Int(dStr) else { return nil }
        guard let m = Double(mStr.replacingOccurrences(of: ",", with: ".")) else { return nil }
        guard d >= 0, d <= 180, m >= 0, m < 60 else { return nil }
        guard h == "E" || h == "W" else { return nil }

        var value = Double(d) + (m / 60.0)
        if h == "W" { value = -value }
        return value
    }

    private func syncCursorInputsFromCursor() {
        guard let c = cursorCoordinate else { return }
        let lat = splitLat(c)
        cursorLatDegInput = "\(lat.deg)"
        cursorLatMinInput = String(format: "%.3f", lat.min)
        cursorLatHemInput = lat.hem
        let lon = splitLon(c)
        cursorLonDegInput = "\(lon.deg)"
        cursorLonMinInput = String(format: "%.3f", lon.min)
        cursorLonHemInput = lon.hem
    }

    private func applyCursorInputsAndPan() {
        guard let lat = parseLatComponents(), let lon = parseLonComponents() else { return }
        cursorCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        cursorPanRequest += 1
    }

    private func rounded(_ value: Double, places: Int) -> Double {
        let power = pow(10.0, Double(places))
        return (value * power).rounded() / power
    }

    private var tideHUDRequestedCoordinate: CLLocationCoordinate2D {
        if let coord = locationManager.userLocation {
            return CLLocationCoordinate2D(
                latitude: rounded(coord.latitude, places: 2),
                longitude: rounded(coord.longitude, places: 2)
            )
        }
        return tideHUDFallbackCoordinate
    }

    private var tideHUDPreferredStationID: String? {
        MapViewTideStationPreference.stationID(from: tidesWeatherPreferredStationIDRaw)
    }

    private var tideHUDRequestKey: String {
        let coord = tideHUDRequestedCoordinate
        return "\(coord.latitude),\(coord.longitude),\(tideHUDPreferredStationID ?? "nearest")"
    }


    @MainActor
    private func loadTideHUDSnapshot(latitude: Double, longitude: Double) async {
        tideHUDIsLoading = true
        tideHUDErrorMessage = nil

        do {
            tideHUDSnapshot = try await tidesWeatherService.fetchSnapshot(
                latitude: latitude,
                longitude: longitude,
                preferredStationID: tideHUDPreferredStationID
            )
        } catch {
            tideHUDErrorMessage = error.localizedDescription
        }

        tideHUDIsLoading = false
    }

    // MARK: - Sharing helpers

    private var liveShareStatusColor: Color {
        if radioGroup.isLiveSharing {
            return .green
        }

        if radioGroup.canShareLocation, radioGroup.activeGroupID != nil {
            return .red
        }

        return .white
    }

    private var isShareOnceFlashing: Bool {
        if let until = shareOnceFlashUntil { return nowTick < until }
        return false
    }

    private var liveIndicatorOpacity: Double {
        Int(nowTick.timeIntervalSinceReferenceDate / 2).isMultiple(of: 2) ? 1.0 : 0.35
    }

    private func isPinExpired(_ pin: RadioGroupStore.Pin, now: Date) -> Bool {
        guard let ttl = pinSettings.expiry.ttlSeconds else { return false }
        return now.timeIntervalSince(pin.createdAt) >= ttl
    }

    private var activeOwnSharedLocationPinCount: Int {
        guard let uid = radioGroup.currentUserID else { return 0 }
        return radioGroup.pins.filter { pin in
            guard !pin.isLive else { return false }
            guard pin.ownerUid == uid else { return false }
            return !isPinExpired(pin, now: nowTick)
        }.count
    }

    private func cleanupExpiredOwnPinsIfNeeded(force: Bool = false) {
        guard pinSettings.expiry.ttlSeconds != nil else { return }
        if !force,
           let lastExpiredOwnPinCleanupAt,
           nowTick.timeIntervalSince(lastExpiredOwnPinCleanupAt) < 60 {
            return
        }
        lastExpiredOwnPinCleanupAt = nowTick
        radioGroup.deleteExpiredOwnPins(expiry: pinSettings.expiry, now: nowTick)
    }

    private func showToast(_ message: String, seconds: TimeInterval = 2.5) {
        toastMessage = ">>> \(message) <<<"
        let until = Date().addingTimeInterval(seconds)
        toastUntil = until
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if toastUntil == until {
                toastMessage = nil
                toastUntil = nil
            }
        }
    }

    private func showBigToast(_ message: String, seconds: TimeInterval = 4.0) {
        bigToastMessage = message
        let until = Date().addingTimeInterval(seconds)
        bigToastUntil = until

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if bigToastUntil == until {
                bigToastMessage = nil
                bigToastUntil = nil
            }
        }
    }

    private var shareLocationPinUnavailableMessage: String {
        "Must be part of an active Radio Group/enable Location sharing to send location pin"
    }

    private var shareLiveLocationUnavailableMessage: String {
        "Must be part of an active Radio Group or enable location sharing to Share Live Location"
    }

    private func showShareLocationPinUnavailableToast() {
        showBigToast(shareLocationPinUnavailableMessage, seconds: 4.0)
    }

    private func showShareLiveLocationUnavailableToast() {
        showBigToast(shareLiveLocationUnavailableMessage, seconds: 4.0)
    }

    private func showLocationUnavailableToast() {
        showBigToast("Location unavailable. Check location permission or GPS signal.", seconds: 4.0)
    }

    private func currentShareCoordinate(showToastOnFailure: Bool = true) -> CLLocationCoordinate2D? {
        let authorizationStatus = locationManager.clManager.authorizationStatus
        if authorizationStatus == .denied || authorizationStatus == .restricted {
            if showToastOnFailure {
                showLocationUnavailableToast()
            }
            return nil
        }

        guard let coord = locationManager.userLocation,
              coord.latitude.isFinite,
              coord.longitude.isFinite,
              coord.latitude >= -90,
              coord.latitude <= 90,
              coord.longitude >= -180,
              coord.longitude <= 180 else {
            if showToastOnFailure {
                showLocationUnavailableToast()
            }
            return nil
        }

        return coord
    }

    private func showRadioGroupFailureToast(_ error: Error, unavailableToast: () -> Void) {
        if let radioError = error as? RadioGroupServiceError {
            switch radioError {
            case .missingActiveGroup, .locationSharingUnavailable:
                unavailableToast()
            case .invalidCoordinate:
                showLocationUnavailableToast()
            case .signInRequired:
                showBigToast(RadioGroupService.friendlyMessage(for: radioError), seconds: 4.0)
            default:
                showBigToast(RadioGroupService.friendlyMessage(for: radioError), seconds: 4.0)
            }
            return
        }

        showBigToast(RadioGroupService.friendlyMessage(for: error), seconds: 4.0)
    }

    private func formattedPinName(now: Date = Date()) -> String {
        let trimmed = radioPinDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Me" : trimmed
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return "\(base), \(f.string(from: now))"
    }

    private func maybeSendLivePin() {
        guard radioGroup.isLiveSharing else {
            debugLiveShareLog("timer tick found sharing off; cancelling foreground timer")
            cancelLiveShareTimer(reason: "sharing off before live pin send")
            return
        }
        guard radioGroup.canShareLocation, radioGroup.activeGroupID != nil else {
            debugLiveShareLog("live pin send stopped because active group/share state is invalid")
            stopLiveSharing(showUnavailableToast: true, reason: "live pin send found invalid group/share state")
            return
        }
        guard !isSendingLiveLocation else { return }
        guard let coord = currentShareCoordinate(showToastOnFailure: false) else { return }

        isSendingLiveLocation = true
        Task { @MainActor in
            let result = await radioGroup.upsertLivePin(coord, displayName: formattedPinName())
            isSendingLiveLocation = false

            switch result {
            case .success:
                LiveLocationSessionState.markActive(
                    lastSentAt: radioGroup.lastLiveLocationSentAt ?? Date(),
                    groupId: radioGroup.activeGroupID
                )
            case .failure(let error):
                debugLiveShareLog("live pin upsert failed: \(error.localizedDescription)")
                LiveLocationSessionState.clear()
                cancelLiveShareTimer(reason: "live pin upsert failed")
                showRadioGroupFailureToast(error, unavailableToast: showShareLiveLocationUnavailableToast)
            }
        }
    }

    private func startLiveSharing(showSuccessToast: Bool = true) {
        guard !isStartingLiveSharing else { return }
        guard radioGroup.canShareLocation, radioGroup.activeGroupID != nil else {
            debugLiveShareLog("manual start unavailable: canShare=\(radioGroup.canShareLocation), group=\(radioGroup.activeGroupID ?? "nil")")
            showShareLiveLocationUnavailableToast()
            return
        }
        guard let coord = currentShareCoordinate() else { return }

        isStartingLiveSharing = true
        cancelLiveShareTimer(reason: "manual start resetting foreground timer")
        debugLiveShareLog("manual start requested for group=\(radioGroup.activeGroupID ?? "nil")")

        Task { @MainActor in
            let result = await radioGroup.upsertLivePin(coord, displayName: formattedPinName())
            isStartingLiveSharing = false

            switch result {
            case .success:
                showLiveShareResumeBanner = false
                LiveLocationSessionState.markActive(
                    lastSentAt: radioGroup.lastLiveLocationSentAt ?? Date(),
                    groupId: radioGroup.activeGroupID
                )
                startLiveShareTimer(reason: "manual start succeeded")
                if showSuccessToast {
                    showToast("Live location sharing started.", seconds: 1.8)
                }
            case .failure(let error):
                debugLiveShareLog("manual start failed: \(error.localizedDescription)")
                LiveLocationSessionState.clear()
                cancelLiveShareTimer(reason: "manual start failed")
                showRadioGroupFailureToast(error, unavailableToast: showShareLiveLocationUnavailableToast)
            }
        }
    }

    private func startLiveShareTimer(reason: String) {
        guard liveShareTimer == nil else {
            debugLiveShareLog("foreground timer already running; skip duplicate start (\(reason))")
            return
        }
        debugLiveShareLog("starting foreground timer every \(Int(liveUpdateSeconds))s (\(reason))")
        liveShareTimer = Timer.publish(every: liveUpdateSeconds, tolerance: 2, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                maybeSendLivePin()
            }
    }

    private func cancelLiveShareTimer(reason: String) {
        if liveShareTimer != nil {
            debugLiveShareLog("cancelling foreground timer (\(reason))")
        }
        liveShareTimer?.cancel()
        liveShareTimer = nil
        isSendingLiveLocation = false
    }

    private func stopLiveSharing(showUnavailableToast: Bool = false, reason: String = "manual stop") {
        debugLiveShareLog("stopping live sharing (\(reason))")
        cancelLiveShareTimer(reason: reason)
        isStartingLiveSharing = false
        showLiveShareResumeBanner = false
        LiveLocationSessionState.clear()
        radioGroup.stopLiveSharing()
        if showUnavailableToast {
            showShareLiveLocationUnavailableToast()
        }
    }

    private func suspendLiveSharingForBackground() {
        guard radioGroup.isLiveSharing || liveShareTimer != nil else { return }
        debugLiveShareLog("suspending live sharing locally for app background/inactive")
        LiveLocationSessionState.recordBackgrounded(
            backgroundedAt: Date(),
            lastSentAt: radioGroup.lastLiveLocationSentAt,
            groupId: radioGroup.activeGroupID
        )
        cancelLiveShareTimer(reason: "app background/inactive")
        showLiveShareResumeBanner = false
    }

    @discardableResult
    private func evaluateLiveSharingResumeState() -> LiveLocationResumeAction {
        guard scenePhase == .active else { return .none }
        guard let snapshot = LiveLocationSessionState.snapshot() else { return .none }

        let action = LiveLocationSessionState.resumeAction(for: snapshot, now: Date())
        debugLiveShareLog("resume evaluation action=\(action)")

        switch action {
        case .none:
            return action

        case .restore:
            restoreLiveSharingFromResume(snapshot: snapshot)

        case .prompt:
            cancelLiveShareTimer(reason: "resume prompt required")
            radioGroup.pauseLiveSharingLocally()
            showLiveShareResumePrompt(snapshot: snapshot)

        case .expired:
            cancelLiveShareTimer(reason: "resume window expired")
            radioGroup.pauseLiveSharingLocally()
            LiveLocationSessionState.clear()
            showLiveShareResumeBanner = false
        }

        return action
    }

    private func restoreLiveSharingFromResume(snapshot: LiveLocationSessionSnapshot) {
        if let expectedGroupID = snapshot.groupId,
           let activeGroupID = radioGroup.activeGroupID,
           expectedGroupID != activeGroupID {
            debugLiveShareLog("resume discarded because group changed from \(expectedGroupID) to \(activeGroupID)")
            LiveLocationSessionState.clear()
            cancelLiveShareTimer(reason: "resume group changed")
            radioGroup.pauseLiveSharingLocally()
            return
        }

        guard radioGroup.canShareLocation, radioGroup.activeGroupID != nil else {
            debugLiveShareLog("resume deferred: canShare=\(radioGroup.canShareLocation), group=\(radioGroup.activeGroupID ?? "nil")")
            return
        }

        switch radioGroup.markLiveShared() {
        case .success:
            LiveLocationSessionState.markActive(
                lastSentAt: radioGroup.lastLiveLocationSentAt ?? snapshot.lastSentAt,
                groupId: radioGroup.activeGroupID
                )
            showLiveShareResumeBanner = false
            if liveShareTimer == nil {
                startLiveShareTimer(reason: "restored within app-closed window")
            }
            maybeSendLivePin()

        case .failure(let error):
            debugLiveShareLog("resume failed: \(error.localizedDescription)")
            cancelLiveShareTimer(reason: "resume failed")
        }
    }

    private func reconcileForegroundLiveSharing(reason: String) {
        guard scenePhase == .active else { return }
        let resumeAction = evaluateLiveSharingResumeState()
        guard resumeAction == .none else { return }
        guard radioGroup.isLiveSharing else { return }

        guard radioGroup.canShareLocation, radioGroup.activeGroupID != nil else {
            debugLiveShareLog("foreground reconcile deferred: canShare=\(radioGroup.canShareLocation), group=\(radioGroup.activeGroupID ?? "nil")")
            return
        }

        debugLiveShareLog("foreground reconcile keeps existing share active (\(reason))")
        showLiveShareResumeBanner = false
        LiveLocationSessionState.markActive(
            lastSentAt: radioGroup.lastLiveLocationSentAt,
            groupId: radioGroup.activeGroupID
        )
        startLiveShareTimer(reason: reason)
        maybeSendLivePin()
    }

    private func showLiveShareResumePrompt(snapshot: LiveLocationSessionSnapshot) {
        guard let backgroundedAt = snapshot.backgroundedAt else { return }
        guard !showLiveShareResumeBanner else { return }

        LiveLocationSessionState.markPromptShown(backgroundedAt: backgroundedAt)
        showLiveShareResumeBanner = true
        let until = Date().addingTimeInterval(4)
        liveShareResumeBannerUntil = until
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if liveShareResumeBannerUntil == until {
                showLiveShareResumeBanner = false
            }
        }
    }

    private func dismissLiveShareResumePrompt(clearResumeState: Bool) {
        showLiveShareResumeBanner = false
        liveShareResumeBannerUntil = nil
        if clearResumeState {
            LiveLocationSessionState.clear()
        }
    }

    private func shareLocationOnce() {
        guard radioGroup.canShareLocation, radioGroup.activeGroupID != nil else {
            showShareLocationPinUnavailableToast()
            return
        }
        guard let coord = currentShareCoordinate() else { return }

        Task { @MainActor in
            let result = await radioGroup.sendPin(coord, displayName: formattedPinName())
            switch result {
            case .success:
                let until = Date().addingTimeInterval(5)
                shareOnceFlashUntil = until
                showToast("Location pin sent.", seconds: 1.8)
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    if shareOnceFlashUntil == until { shareOnceFlashUntil = nil }
                }
            case .failure(let error):
                showRadioGroupFailureToast(error, unavailableToast: showShareLocationPinUnavailableToast)
            }
        }
    }

    // MARK: - Map layer

    private var sstLatestAvailableUTC: String {
        sstAvailability.latestAvailableOrFallback(for: sstSource)
    }

    private func refreshSSTAvailability(force: Bool = false, for source: SeaSurfaceTemperatureSource? = nil) {
        sstAvailability.refreshIfNeeded(for: source ?? sstSource, force: force)
    }

    private func normalizeSSTSettings() {
        guard let normalizedSource = SeaSurfaceTemperatureSource(rawValue: sstSourceRaw),
              SeaSurfaceTemperatureSource.selectableCases.contains(normalizedSource) else {
            sstSourceRaw = SeaSurfaceTemperatureSource.gibsMURHighDetail.rawValue
            sstOpacity = min(max(sstOpacity, 0.15), 0.85)
            sstDateUTC = SeaSurfaceTemperatureOverlay.clampedDateUTC(
                sstDateUTC,
                for: .gibsMURHighDetail,
                latestAvailableUTC: sstAvailability.latestAvailableOrFallback(for: .gibsMURHighDetail)
            )
            return
        }

        sstOpacity = min(max(sstOpacity, 0.15), 0.85)
        sstDateUTC = SeaSurfaceTemperatureOverlay.clampedDateUTC(
            sstDateUTC,
            for: normalizedSource,
            latestAvailableUTC: sstAvailability.latestAvailableOrFallback(for: normalizedSource)
        )
    }

    private func migrateDefaultBasemapIfNeeded() {
        guard shouldPreferBristolBaySatelliteDefault else { return }
        basemapChoiceRaw = BasemapChoice.districtsOnline.rawValue
        didMigrateDefaultBasemapToBristolBaySatelliteV1 = true
    }

    private func handleMapAppear() {
        locationManager.requestPermission()
        locationManager.start()
        BBMenuAppearance.applyAll()
        migrateDefaultBasemapIfNeeded()
        syncCursorInputsFromCursor()
        normalizeSSTSettings()
        refreshSSTAvailability()
        if basemapChoice == .districtsOnline { onlineDistrictAvailability.refreshIfNeeded() }
        smartLogbookStore.reloadFromDisk()
        ensureWaypointDefaultsAndLoad()
    }

    private func ensureWaypointDefaultsAndLoad() {
        let color = WaypointColorPreferences.ensureLocalDefaultColor()
        defaultWaypointPinColorID = color.rawValue
        radioGroup.ensureDefaultWaypointColorAssigned()

        guard !didLoadPersistedWaypoints else { return }
        didLoadPersistedWaypoints = true
        waypoints = WaypointLocalStore.load(defaultColorID: color.rawValue)
    }

    private var mapLayer: some View {
        MapViewRepresentable(
            locationManager: locationManager,
            distanceText: $distanceText,
            speedText: $speedText,
            metersPerPoint: $metersPerPoint,
            followUserRequest: $followReq,
            recenterRequest: $recenterReq,
            isFollowingUser: $isFollowing,
            selectedMapVersion: selectedMapVersionBinding,
            cursorCoordinate: $cursorCoordinate,
            cursorDistanceText: $cursorDistanceText,
            cursorCoordText: $cursorCoordText,
            cursorPanRequest: $cursorPanRequest,
            isCursorTrackingUser: $isCursorTrackingUser,
            waypoints: $waypoints,
            receivedWaypoints: radioGroup.receivedWaypoints,
            radioPins: radioGroup.pins,
            activeRadioGroupID: radioGroup.activeGroupID,
            radioMembers: radioGroup.activeMembers,
            zoomInRequest: $zoomInReq,
            zoomOutRequest: $zoomOutReq,
            basemapChoice: basemapChoice,
            offlineInventoryRevision: offline.downloadedTick,
            onlineDistrictMaps: onlineDistrictAvailability.maps,
            districtMapVisualSettingsBySlug: districtMapVisualSettingsBySlug,
            sstEnabled: sstEnabled,
            sstOpacity: sstOpacity,
            sstSource: sstSource,
            sstDateUTC: sstDateUTC,
            showPortMollerTestFisheryStations: showPortMollerTestFisheryStations,
            showLiveLocationTrail: showNavLiveLocationTrail,
            visibleFishingSets: smartLogbookStore.displayedFishingSetsOnNavPage.filter { $0.displayOnNavPage },
            onFishingSetDisplayPrompt: { _ in }
        )
        .ignoresSafeArea()
        .onAppear(perform: handleMapAppear)
        .onChange(of: basemapChoiceRaw) { _ in
            if basemapChoice == .districtsOnline { onlineDistrictAvailability.refreshIfNeeded() }
            else { onlineDistrictAvailability.cancelRefresh() }
        }
    }

    // MARK: - HUD + controls (unchanged UI)

    private var landscapeHUDOuterHorizontalPadding: CGFloat {
        // Landscape top HUD keeps a small safe-area cushion while staying wide.
        UIDevice.current.userInterfaceIdiom == .pad ? 14 : 6
    }

    private var landscapeBottomHUDOuterHorizontalPadding: CGFloat {
        // The landscape bottom HUD needs maximum width because the scale bar,
        // navigation buttons, zoom controls, Record Set, Create Waypoint, and
        // map-version button now live in a single compact row.
        UIDevice.current.userInterfaceIdiom == .pad ? 10 : 2
    }

    private var topHUDOuterHorizontalPadding: CGFloat {
        isLandscapeMode ? landscapeHUDOuterHorizontalPadding : 10
    }

    private var bottomHUDOuterHorizontalPadding: CGFloat {
        isLandscapeMode ? landscapeBottomHUDOuterHorizontalPadding : 10
    }

    private var topHUD: some View {
        GeometryReader { proxy in
            let landscape = responsiveIsLandscape(proxy.size)

            Group {
                if landscape {
                    let hudWidth = landscapeTopHUDCenteredWidth(
                        screenWidth: proxy.size.width,
                        safeAreaInsets: proxy.safeAreaInsets
                    )

                    VStack(alignment: .center, spacing: 8) {
                        if hasVisibleTopHUDContent {
                            responsiveTopHUDCard(availableWidth: hudWidth, landscape: true)
                        } else {
                            hiddenTopHUDControlRow(availableWidth: hudWidth)
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(width: hudWidth, alignment: .center)
                    .padding(.top, 2)
                    .offset(x: landscapeHUDCenteringOffset(safeAreaInsets: proxy.safeAreaInsets))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    let horizontalInsets = mapHorizontalInsets(
                        safeAreaInsets: proxy.safeAreaInsets,
                        base: 10
                    )
                    let availableWidth = max(0, proxy.size.width - horizontalInsets.leading - horizontalInsets.trailing)

                    VStack(alignment: .leading, spacing: 8) {
                        if hasVisibleTopHUDContent {
                            responsiveTopHUDCard(availableWidth: availableWidth, landscape: false)
                        } else {
                            hiddenTopHUDControlRow(availableWidth: availableWidth)
                        }

                        // Expanded iPad portrait keeps sharing and action controls
                        // inside the HUD, in the same groups as landscape.
                        if UIDevice.current.userInterfaceIdiom != .pad
                            && showNavTopHUDDisplay && hasVisibleTopActionRow {
                            responsiveTopHUDShareButtons(landscape: false)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)
                    .padding(.leading, horizontalInsets.leading)
                    .padding(.trailing, horizontalInsets.trailing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .confirmationDialog("Share live location with Radio Group?", isPresented: $showConfirmLiveShare) {
            Button("Share Live") { startLiveSharing() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Stop sharing live location with Radio Group?", isPresented: $showConfirmStopLiveShare) {
            Button("Stop Sharing", role: .destructive) { stopLiveSharing(reason: "manual stop confirmation") }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Send Radio Group pin of current location?", isPresented: $showConfirmShareOnce) {
            Button("Send Pin") { shareLocationOnce() }
            Button("Cancel", role: .cancel) {}
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            nowTick = Date()
            cleanupExpiredOwnPinsIfNeeded()
        }
        .onAppear {
            syncCursorInputsFromCursor()
            evaluateLiveSharingResumeState()
        }
        .onChange(of: cursorCoordText) { _ in syncCursorInputsFromCursor() }
        .onChange(of: pinSettings.expiry) { _ in cleanupExpiredOwnPinsIfNeeded(force: true) }
    }

    private func mapHorizontalInsets(safeAreaInsets: EdgeInsets, base: CGFloat) -> EdgeInsets {
        let extraSafeGap: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 8 : 4
        return EdgeInsets(
            top: 0,
            leading: max(base, safeAreaInsets.leading + extraSafeGap),
            bottom: 0,
            trailing: max(base, safeAreaInsets.trailing + extraSafeGap)
        )
    }

    private func centeredMapHorizontalInsets(safeAreaInsets: EdgeInsets, base: CGFloat) -> EdgeInsets {
        let extraSafeGap: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 8 : 4
        let side = max(base, max(safeAreaInsets.leading, safeAreaInsets.trailing) + extraSafeGap)
        return EdgeInsets(top: 0, leading: side, bottom: 0, trailing: side)
    }

    private func landscapeTopHUDCenteredWidth(screenWidth: CGFloat, safeAreaInsets: EdgeInsets) -> CGFloat {
        let extraSafeGap: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 8 : 4
        let sideInset = max(
            landscapeBottomHUDOuterHorizontalPadding,
            max(safeAreaInsets.leading, safeAreaInsets.trailing) + extraSafeGap
        )
        return max(0, screenWidth - (sideInset * 2))
    }

    private func landscapeHUDCenteringOffset(safeAreaInsets: EdgeInsets) -> CGFloat {
        // Keep the landscape HUD centered on the physical screen rather than drifting with
        // asymmetric notch/safe-area insets. The HUD width itself remains safe-area aware.
        0
    }

    private func portraitBottomSymmetricHorizontalInsets(safeAreaInsets: EdgeInsets, base: CGFloat) -> EdgeInsets {
        let extraSafeGap: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 8 : 4
        let side = max(base, max(safeAreaInsets.leading, safeAreaInsets.trailing) + extraSafeGap)
        return EdgeInsets(top: 0, leading: side, bottom: 0, trailing: side)
    }

    private func mapBottomHorizontalInsets(safeAreaInsets: EdgeInsets, base: CGFloat) -> EdgeInsets {
        let extraSafeGap: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 6 : 2
        return EdgeInsets(
            top: 0,
            leading: max(base, safeAreaInsets.leading + extraSafeGap),
            bottom: 0,
            trailing: max(base, safeAreaInsets.trailing + extraSafeGap)
        )
    }

    private var isOfflineAccountMode: Bool {
        authStore.isUsingCachedOfflineAccountGate
    }

    private var offlineModeHUDText: String? {
        isOfflineAccountMode ? "Offline mode" : nil
    }

    private var showOfflineModeInTopHUDLocation: Bool {
        showNavTopHUDDisplay && isOfflineAccountMode && !showNavTideHUD
    }

    private var showFloatingOfflineModeBadge: Bool {
        isOfflineAccountMode && !showNavTopHUDDisplay
    }

    private var hasVisibleTopHUDContent: Bool {
        showNavTopHUDDisplay
    }

    private var hasVisibleTopHUDLocationSpeedRow: Bool {
        showNavLocationReadout || showNavSpeedReadout
    }

    private var hasVisibleTopHUDSecondaryReadouts: Bool {
        showNavBoundaryReadout || showNavKDLGButton || showNavWindReadout
    }

    private var hasVisibleTopHUDShareControls: Bool {
        (!showNavTopHUDDisplay || !isTopHUDCollapsed)
            && (showNavShareLiveButton || showNavSendLocationButton)
    }

    private var hasVisibleTopHUDActionControls: Bool {
        showNavRecordSetButton || showNavCreateWaypointButton
    }

    private var hasVisibleTopActionRow: Bool {
        if showNavTopHUDDisplay && isTopHUDCollapsed {
            return false
        }
        return hasVisibleTopHUDShareControls || hasVisibleTopHUDActionControls
    }

    private var visibleBottomMainButtonCount: Int {
        [
            showNavFollowUserButton,
            showNavRecenterButton,
            showNavBasemapButton,
            showNavMainMenuButton,
            showNavOceanLayersButton
        ].filter { $0 }.count
    }

    private var visibleZoomButtonCount: Int {
        [showNavZoomInButton, showNavZoomOutButton].filter { $0 }.count
    }

    private func buttonGroupWidth(count: Int, spacing: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return (CGFloat(count) * mapControlButtonSize) + (CGFloat(max(count - 1, 0)) * spacing)
    }

    private func responsiveIsLandscape(_ size: CGSize) -> Bool {
        size.width > size.height
    }

    private func portraitHUDPanelWidth(for availableWidth: CGFloat) -> CGFloat {
        let contentWidth = max(0, availableWidth - 8)
        let spacing = portraitHUDPanelSpacing(for: contentWidth)
        let maxPanelWidth: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 230 : 214
        let calculated = (contentWidth - spacing) / 2.0
        return min(max(calculated, 124), maxPanelWidth)
    }

    private func portraitHUDPanelSpacing(for availableWidth: CGFloat) -> CGFloat {
        min(max(availableWidth * 0.025, 8), 12)
    }

    private func responsiveLandscapeHUDPanelWidth(for availableWidth: CGFloat) -> CGFloat {
        let reservedForReadoutsAndActions: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 400 : 330
        let calculated = (availableWidth - reservedForReadoutsAndActions) / 2.0
        return min(max(calculated, 134), UIDevice.current.userInterfaceIdiom == .pad ? 230 : 204)
    }

    private func responsiveLandscapeHUDClusterWidth(for availableWidth: CGFloat) -> CGFloat {
        let panelWidth = responsiveLandscapeHUDPanelWidth(for: availableWidth)
        return (panelWidth * 2) + 8
    }

    private func responsiveTopHUDCard(availableWidth: CGFloat, landscape: Bool) -> some View {
        let usesPortraitIPadLayout = UIDevice.current.userInterfaceIdiom == .pad && !landscape

        return VStack(alignment: .leading, spacing: 4) {
            if isTopHUDCollapsed {
                topHUDControlRow
            } else {
                if landscape {
                    landscapeExpandedTopHUD(availableWidth: availableWidth)
                } else if usesPortraitIPadLayout {
                    portraitExpandedTopHUD
                } else {
                    compactExpandedTopHUDHeader(availableWidth: availableWidth, landscape: false)

                    if showNavSpeedReadout || showNavWindReadout {
                        compactTopHUDStatusRow(availableWidth: availableWidth, landscape: false)
                    }

                    if showNavLocationReadout || showNavKDLGButton {
                        compactTopHUDLocationRow
                    }
                }

                if showLiveShareResumeBanner {
                    liveShareResumeBanner
                }

                if let msg = bigToastMessage, let until = bigToastUntil, Date() < until {
                    Text(msg)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.82)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 10)
                        .background(showNavTopHUDOpacity ? scSurfaceAlt.opacity(0.92) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(showNavTopHUDOpacity ? 0.12 : 0), lineWidth: 1)
                        )
                }

                if let msg = toastMessage, let until = toastUntil, Date() < until {
                    Text(msg)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(showNavTopHUDOpacity ? scTextPrimary : .white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .frame(maxWidth: .infinity)
                        .padding(.top, -2)
                }
            }
        }
        .padding(.horizontal, isTopHUDCollapsed ? 0 : 4)
        .padding(.vertical, isTopHUDCollapsed ? 0 : 4)
        .frame(width: availableWidth, alignment: .topLeading)
        .background(isTopHUDCollapsed || !showNavTopHUDOpacity
                    ? Color.clear : scSurface.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// Portrait uses the landscape groups, with a narrower tide panel. The
    /// layout measures the readouts so small windows can add rows without
    /// shrinking buttons or hiding any coordinate fields.
    private var portraitExpandedTopHUD: some View {
        let hasReadouts = showNavWindReadout || showNavSpeedReadout || showNavBoundaryReadout
        let hasTide = showNavTideHUD || showOfflineModeInTopHUDLocation

        return PortraitTopHUDLayout(
            showReadouts: hasReadouts,
            showSharing: hasVisibleTopHUDShareControls,
            showLocation: showNavLocationReadout,
            showTide: hasTide,
            showActions: hasVisibleTopHUDActionControls,
            locationLabelWidth: showNavSpeedReadout ? topHUDLocationLabelWidth : nil
        ) {
            VStack(alignment: .leading, spacing: 0) {
                landscapeTopHUDPrimaryButtons
            }

            VStack(alignment: .leading, spacing: 0) {
                if hasReadouts { portraitTopHUDReadouts }
            }

            VStack(alignment: .leading, spacing: 0) {
                if hasVisibleTopHUDShareControls { landscapeTopHUDShareButtons }
            }

            VStack(alignment: .leading, spacing: 0) {
                if showNavLocationReadout { portraitTopHUDLocation }
            }

            VStack(alignment: .leading, spacing: 0) {
                if showNavTideHUD {
                    tideHUDBox(
                        height: landscapeTopHUDBoxHeight,
                        chartHeight: landscapeTopHUDMiniTideChartHeight
                    )
                } else if showOfflineModeInTopHUDLocation {
                    offlineModeHUDPlaceholder
                        .frame(height: landscapeTopHUDBoxHeight)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                if hasVisibleTopHUDActionControls { landscapeTopHUDActionButtons }
            }
        }
        .accessibilityIdentifier("navigationPortraitTopHUD")
    }

    private var portraitTopHUDReadouts: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showNavWindReadout { topHUDWindForecast }

            if showNavSpeedReadout || showNavBoundaryReadout {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        if showNavSpeedReadout { topHUDSpeedReadout }
                        if showNavBoundaryReadout { topHUDBoundaryReadout }
                    }
                    .fixedSize(horizontal: true, vertical: true)

                    VStack(alignment: .leading, spacing: 4) {
                        if showNavSpeedReadout { topHUDSpeedReadout }
                        if showNavBoundaryReadout { topHUDBoundaryReadout }
                    }
                    .fixedSize(horizontal: true, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("navigationPortraitHUDReadouts")
    }

    private var portraitTopHUDLocation: some View {
        ViewThatFits(in: .horizontal) {
            portraitLocationReadout(stacked: false)
            portraitLocationReadout(stacked: true)
        }
        .accessibilityElement(children: .contain)
    }

    private var topHUDLocationLabelWidth: CGFloat {
        let title = isCursorTrackingUser ? "Location:" : "Cursor:"
        let font = UIFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        return (title as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    private func portraitLocationReadout(stacked: Bool) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isCursorTrackingUser ? "Location:" : "Cursor:")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
                if stacked { liveCursorStatusIndicator }
            }
            .frame(width: topHUDLocationLabelWidth, alignment: .leading)

            HUDCoordinateEntryFields(
                latitudeDegrees: $cursorLatDegInput,
                latitudeMinutes: $cursorLatMinInput,
                latitudeHemisphere: $cursorLatHemInput,
                longitudeDegrees: $cursorLonDegInput,
                longitudeMinutes: $cursorLonMinInput,
                longitudeHemisphere: $cursorLonHemInput,
                onSubmit: applyCursorInputsAndPan,
                stacked: stacked,
                scrollsHorizontally: false
            )

            if !stacked && radioGroup.isLiveSharing { liveCursorStatusIndicator }
        }
        .fixedSize(horizontal: true, vertical: true)
        .hudBoxSmall()
    }

    private func compactExpandedTopHUDHeader(availableWidth: CGFloat, landscape: Bool) -> some View {
        let controlWidth = buttonGroupWidth(count: 3, spacing: mapControlDefaultSpacing)
        let tideWidth = compactExpandedTideWidth(
            availableWidth: availableWidth,
            landscape: landscape,
            controlWidth: controlWidth
        )

        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                topHUDExpandedControlButtons

                if showNavBoundaryReadout {
                    topHUDBoundaryReadout
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(width: controlWidth, alignment: .leading)
                }
            }
            .frame(width: controlWidth, alignment: .topLeading)

            Spacer(minLength: 8)

            if showNavTideHUD {
                tideHUDBox
                    .frame(width: tideWidth, height: topHUDBoxHeight, alignment: .topLeading)
            } else if showOfflineModeInTopHUDLocation {
                offlineModeHUDPlaceholder
                    .frame(width: tideWidth, height: topHUDBoxHeight, alignment: .topTrailing)
            }

        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func compactExpandedTideWidth(
        availableWidth: CGFloat,
        landscape: Bool,
        controlWidth: CGFloat
    ) -> CGFloat {
        let previousWidth: CGFloat
        if landscape {
            previousWidth = landscapeInlineTidePanelWidth(for: availableWidth)
        } else {
            previousWidth = min(
                max(availableWidth, 0),
                UIDevice.current.userInterfaceIdiom == .pad ? 460 : 430
            )
        }

        let contentWidth = max(0, availableWidth - 8)
        let inlineAvailableWidth = max(0, contentWidth - controlWidth - 8)
        return min(previousWidth * 0.5, inlineAvailableWidth)
    }

    private func compactTopHUDStatusRow(availableWidth: CGFloat, landscape: Bool) -> some View {
        let controlWidth = buttonGroupWidth(count: 3, spacing: mapControlDefaultSpacing)
        let tideWidth = compactExpandedTideWidth(
            availableWidth: availableWidth,
            landscape: landscape,
            controlWidth: controlWidth
        )

        return HStack(alignment: .center, spacing: 0) {
            if showNavSpeedReadout {
                topHUDSpeedReadout
                    .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 6)

            if showNavWindReadout {
                topHUDWindForecast
                    .frame(width: tideWidth, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private var compactTopHUDLocationRow: some View {
        HStack(alignment: .center, spacing: 6) {
            if showNavLocationReadout {
                topHUDCurrentLocation
                    .frame(width: topHUDLocationFixedWidth, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }

            if showNavKDLGButton {
                topHUDKDLGButton
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var topHUDLocationFixedWidth: CGFloat {
        let shortScreenSide = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        let portraitOuterInsets: CGFloat = 20
        let expandedCardInsets: CGFloat = 8
        let kdlgAllowance: CGFloat = 46
        let available = shortScreenSide - portraitOuterInsets - expandedCardInsets - kdlgAllowance
        let maximum: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 430 : 340
        return min(max(available, 220), maximum)
    }

    @ViewBuilder
    private func landscapeExpandedTopHUD(availableWidth: CGFloat) -> some View {
        let contentWidth = max(0, availableWidth - 8)
        let showsTideColumn = showNavTideHUD || showOfflineModeInTopHUDLocation
        let showsActionColumn = hasVisibleTopHUDActionControls
        let actionColumnWidth = showsActionColumn ? mapControlButtonSize : 0
        let primaryButtonCount = 3 + (showNavKDLGButton ? 1 : 0)
        let primaryButtonWidth = buttonGroupWidth(
            count: primaryButtonCount,
            spacing: mapControlDefaultSpacing
        )
        let shareButtonWidth = hasVisibleTopHUDShareControls
            ? buttonGroupWidth(count: 2, spacing: mapControlDefaultSpacing)
            : 0
        let defaultLocationLeading = shareButtonWidth
            + (hasVisibleTopHUDShareControls && showNavLocationReadout ? 6 : 0)
        // Match portrait: latitude's first box shares the visible Speed text
        // anchor. Both readouts have the same outer horizontal padding.
        let locationLeading = UIDevice.current.userInterfaceIdiom == .pad && showNavSpeedReadout
            ? max(defaultLocationLeading,
                  primaryButtonWidth + mapControlDefaultSpacing - topHUDLocationLabelWidth - 6)
            : defaultLocationLeading
        let desiredLocationTrailing = showNavLocationReadout
            ? locationLeading + topHUDLocationFixedWidth
            : 0
        let desiredReadoutTrailing = primaryButtonWidth
            + mapControlDefaultSpacing
            + (showNavWindReadout ? landscapeWindReadoutWidth : 0)
        let desiredLeftWidth = max(
            primaryButtonWidth,
            desiredLocationTrailing,
            desiredReadoutTrailing
        )
        let actionReserve = actionColumnWidth
            + (showsActionColumn ? mapControlDefaultSpacing : 0)
        let widthBeforeActionColumn = max(0, contentWidth - actionReserve)
        let tideSpacing = showsTideColumn ? mapControlDefaultSpacing : 0
        let maximumLeftWidth = max(
            0,
            widthBeforeActionColumn
                - tideSpacing
                - (showsTideColumn ? landscapeMinimumTideWidth : 0)
        )
        let leftWidth = min(
            desiredLeftWidth,
            showsTideColumn ? maximumLeftWidth : widthBeforeActionColumn
        )
        let tideWidth = showsTideColumn
            ? max(0, widthBeforeActionColumn - leftWidth - tideSpacing)
            : 0
        let locationWidth = min(
            topHUDLocationFixedWidth,
            max(0, leftWidth - locationLeading)
        )
        let centerReadoutLeading = primaryButtonWidth + mapControlDefaultSpacing
        let centerReadoutWidth = max(0, leftWidth - centerReadoutLeading)
        let windReadoutWidth = min(landscapeWindReadoutWidth, centerReadoutWidth)

        if UIDevice.current.userInterfaceIdiom == .pad && showNavLocationReadout
            && showNavSpeedReadout && locationWidth < topHUDLocationFixedWidth {
            // Narrow landscape windows use the same measured groups as
            // portrait so moving the fields never hides the longitude or Live.
            portraitExpandedTopHUD
        } else {
            HStack(alignment: .top, spacing: mapControlDefaultSpacing) {
                ZStack(alignment: .topLeading) {
                    landscapeTopHUDPrimaryButtons
                        .zIndex(2)

                    if hasVisibleTopHUDShareControls || showNavLocationReadout {
                        HStack(alignment: .center, spacing: 6) {
                            if hasVisibleTopHUDShareControls {
                                landscapeTopHUDShareButtons
                            }

                            if showNavLocationReadout {
                                topHUDCurrentLocation
                                    .frame(width: locationWidth, alignment: .leading)
                                    .padding(.leading, locationLeading - defaultLocationLeading)
                            }
                        }
                        .offset(y: mapControlButtonSize + mapControlDefaultSpacing)
                    }

                    if showNavWindReadout || showNavSpeedReadout || showNavBoundaryReadout {
                        VStack(alignment: .leading, spacing: 4) {
                            if showNavWindReadout {
                                topHUDWindForecast
                                    .frame(width: windReadoutWidth, alignment: .leading)
                            }

                            if showNavSpeedReadout || showNavBoundaryReadout {
                                HStack(alignment: .center, spacing: 6) {
                                    if showNavSpeedReadout {
                                        topHUDSpeedReadout
                                            .fixedSize(horizontal: true, vertical: false)
                                    }

                                    if showNavBoundaryReadout {
                                        topHUDBoundaryReadout
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.65)
                                    }
                                }
                                .frame(width: centerReadoutWidth, alignment: .leading)
                            }
                        }
                        .frame(width: centerReadoutWidth, alignment: .topLeading)
                        .offset(x: centerReadoutLeading)
                    }
                }
                .frame(width: leftWidth, height: landscapeTopHUDBoxHeight, alignment: .topLeading)

                if showNavTideHUD {
                    tideHUDBox(
                        height: landscapeTopHUDBoxHeight,
                        chartHeight: landscapeTopHUDMiniTideChartHeight
                    )
                    .frame(width: tideWidth, height: landscapeTopHUDBoxHeight, alignment: .topLeading)
                } else if showOfflineModeInTopHUDLocation {
                    offlineModeHUDPlaceholder
                        .frame(width: tideWidth, height: landscapeTopHUDBoxHeight, alignment: .topTrailing)
                }

                if showsActionColumn {
                    landscapeTopHUDActionButtons
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: landscapeTopHUDBoxHeight,
                maxHeight: landscapeTopHUDBoxHeight,
                alignment: .topLeading
            )
        }
    }

    private var landscapeTopHUDPrimaryButtons: some View {
        HStack(spacing: mapControlDefaultSpacing) {
            topHUDExpandCollapseButton
            fishTicketOCRButton
            mapAppearanceButton

            if showNavKDLGButton {
                topHUDKDLGMapButton
            }
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private var landscapeTopHUDShareButtons: some View {
        HStack(spacing: mapControlDefaultSpacing) {
            if showNavShareLiveButton {
                liveShareToggleButton
            } else {
                Color.clear
                    .frame(width: mapControlButtonSize, height: mapControlButtonSize)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }

            if showNavSendLocationButton {
                sendLocationPinButton
            }
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private var landscapeTopHUDActionButtons: some View {
        VStack(spacing: mapControlDefaultSpacing) {
            if showNavRecordSetButton {
                recordSetButton
            }

            if showNavCreateWaypointButton {
                createWaypointButton
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .frame(
            width: mapControlButtonSize,
            height: landscapeTopHUDBoxHeight,
            alignment: .topTrailing
        )
    }

    private var landscapeWindReadoutWidth: CGFloat {
        112
    }

    private var topHUDKDLGMapButton: some View {
        Button {
            kdlgRadioPlayer.togglePlayback()
        } label: {
            Text("KDLG")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .buttonStyle(
            MapIconButtonStyle(
                isActive: false,
                foreground: kdlgRadioPlayer.isPlaying ? .green : .yellow
            )
        )
        .accessibilityLabel(kdlgRadioPlayer.isOn ? "Stop KDLG radio" : "Play KDLG radio")
    }

    private var landscapeMinimumTideWidth: CGFloat {
        let shortScreenSide = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        let portraitAvailableWidth = max(0, shortScreenSide - 20)
        let controlWidth = buttonGroupWidth(count: 3, spacing: mapControlDefaultSpacing)
        let previousWidth = compactExpandedTideWidth(
            availableWidth: portraitAvailableWidth,
            landscape: false,
            controlWidth: controlWidth
        )

        if UIDevice.current.userInterfaceIdiom == .pad {
            return previousWidth
        }

        return min(previousWidth, 164)
    }

    private func responsiveTopHUDLandscapeTopRow(availableWidth: CGFloat) -> some View {
        landscapeInlineTideHUDRow(availableWidth: availableWidth)
    }

    private func landscapeInlineTidePanelWidth(for availableWidth: CGFloat) -> CGFloat {
        let minimumReadoutWidth: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 380 : 285
        let availableForTwoPanels = max(0, availableWidth - minimumReadoutWidth - 16)
        let calculated = availableForTwoPanels / 2.0
        let maximum: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 242 : 204
        return min(max(calculated, 128), maximum)
    }

    private func landscapeInlineTideHUDRow(availableWidth: CGFloat) -> some View {
        let panelWidth = landscapeInlineTidePanelWidth(for: availableWidth)
        let showOfflineModePlaceholder = showOfflineModeInTopHUDLocation
        let visiblePanelCount = (showNavTideHUD || showOfflineModePlaceholder) ? 1 : 0
        let visibleReadoutStack = showNavLocationReadout
            || showNavBoundaryReadout
            || showNavSpeedReadout
            || showNavWindReadout
            || showNavKDLGButton
        let usedPanelWidth = CGFloat(visiblePanelCount) * panelWidth
        let usedPanelSpacing = CGFloat(max(0, visiblePanelCount - 1)) * 8
        let readoutGap: CGFloat = visiblePanelCount > 0 && visibleReadoutStack ? 8 : 0
        let readoutWidth = max(0, availableWidth - usedPanelWidth - usedPanelSpacing - readoutGap)

        return HStack(alignment: .top, spacing: 8) {
            if showNavTideHUD {
                tideHUDBox
                    .frame(width: panelWidth, height: topHUDBoxHeight, alignment: .topLeading)
                    .layoutPriority(1)
            }

            if showOfflineModePlaceholder {
                offlineModeHUDPlaceholder
                    .frame(width: panelWidth, height: topHUDBoxHeight, alignment: .topTrailing)
                    .layoutPriority(1)
            }

            if visibleReadoutStack {
                landscapeTopHUDReadoutStack(availableWidth: readoutWidth)
                    .frame(maxWidth: .infinity, minHeight: topHUDBoxHeight, maxHeight: topHUDBoxHeight, alignment: .topLeading)
                    .layoutPriority(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func landscapeTopHUDLocationBar(width: CGFloat) -> some View {
        topHUDCurrentLocation
            .frame(width: max(width, 0), alignment: .leading)
    }

    private func landscapeTopHUDReadoutStack(availableWidth: CGFloat) -> some View {
        let readoutWidth = max(0, availableWidth)

        return VStack(alignment: .leading, spacing: 4) {
            if showNavLocationReadout {
                landscapeTopHUDLocationBar(width: readoutWidth)
                    .layoutPriority(2)
            }

            if showNavBoundaryReadout || showNavSpeedReadout {
                HStack(alignment: .center, spacing: 6) {
                    if showNavBoundaryReadout {
                        topHUDBoundaryReadout
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)
                            .layoutPriority(1)
                    }

                    if showNavSpeedReadout {
                        topHUDSpeedReadout
                            .lineLimit(1)
                            .minimumScaleFactor(0.74)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .frame(width: readoutWidth, alignment: .leading)
            }

            if showNavKDLGButton || showNavWindReadout {
                HStack(alignment: .center, spacing: 6) {
                    if showNavKDLGButton {
                        topHUDKDLGButton
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    if showNavWindReadout {
                        topHUDWindForecast
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .clipped()
                    }
                }
                .frame(width: readoutWidth, alignment: .leading)
            }
        }
        .frame(width: readoutWidth, height: topHUDBoxHeight, alignment: .topLeading)
        .clipped()
    }

    private func responsiveTopHUDLocationReadouts(tideBoxWidth: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 0) {
            if showNavBoundaryReadout {
                topHUDBoundaryReadout
                    .layoutPriority(1)
            }

            if showNavBoundaryReadout && (showNavKDLGButton || showNavWindReadout) {
                Spacer(minLength: 0)
            }

            if showNavKDLGButton {
                topHUDKDLGButton
            }

            if showNavKDLGButton && showNavWindReadout {
                Spacer(minLength: 0)
            }

            if showNavWindReadout {
                topHUDWindForecast
                    .frame(width: tideBoxWidth, alignment: .leading)
                    .minimumScaleFactor(0.82)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // These tools remain available even when the informational HUD is hidden.
    private func hiddenTopHUDControlRow(availableWidth: CGFloat) -> some View {
        let buttonCount = 2
            + (showNavShareLiveButton ? 1 : 0)
            + (showNavSendLocationButton ? 1 : 0)
            + (showNavRecordSetButton ? 1 : 0)
            + (showNavCreateWaypointButton ? 1 : 0)
        let gapCount = buttonCount - 1 + (hasVisibleTopHUDActionControls ? 1 : 0)
        let spacing = min(mapControlDefaultSpacing, max(
            0,
            (availableWidth - CGFloat(buttonCount) * mapControlButtonSize) / CGFloat(gapCount)
        ))

        return HStack(spacing: spacing) {
            fishTicketOCRButton
            mapAppearanceButton
            if showNavShareLiveButton { liveShareToggleButton }
            if showNavSendLocationButton { sendLocationPinButton }

            if hasVisibleTopHUDActionControls {
                Spacer(minLength: 0)
                if showNavRecordSetButton { recordSetButton }
                if showNavCreateWaypointButton { createWaypointButton }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("navigationTopHUDHiddenControlRow")
    }

    @ViewBuilder
    private func responsiveTopHUDShareButtons(landscape: Bool) -> some View {
        if landscape {
            HStack(spacing: mapControlDefaultSpacing) {
                if hasVisibleTopHUDShareControls {
                    HStack(spacing: mapControlDefaultSpacing) {
                        if showNavShareLiveButton { liveShareToggleButton }
                        if showNavSendLocationButton { sendLocationPinButton }
                    }
                    .fixedSize(horizontal: true, vertical: true)
                }

                Spacer(minLength: mapControlDefaultSpacing)

                if hasVisibleTopHUDActionControls {
                    HStack(spacing: mapControlDefaultSpacing) {
                        if showNavRecordSetButton {
                            recordSetButton
                        }
                        if showNavCreateWaypointButton { createWaypointButton }
                    }
                    .fixedSize(horizontal: true, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 10) {
                if showNavShareLiveButton { liveShareToggleButton }
                if showNavSendLocationButton { sendLocationPinButton }

                Spacer(minLength: 8)

                if showNavRecordSetButton {
                    recordSetButton
                }
                if showNavCreateWaypointButton { createWaypointButton }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var recordSetButton: some View {
        let isRecording = activeSetSession != nil
        let fallbackDistrict = preferredFishingSetDistrict(for: locationManager.userLocation)
        let nextSetNumber = smartLogbookStore.previewFishingSetNumber(for: Date(), fallbackDistrict: fallbackDistrict)
        return Button {
            if isRecording {
                finishRecordingSet()
            } else {
                showStartSetPrompt = true
            }
        } label: {
            if let activeSetSession {
                TimelineView(.periodic(from: activeSetSession.startedAt, by: 1)) { timeline in
                    activeRecordSetButtonLabel(session: activeSetSession, now: timeline.date)
                }
            } else {
                inactiveRecordSetButtonLabel(nextSetNumber: nextSetNumber)
            }
        }
        .buttonStyle(
            MapIconButtonStyle(
                isActive: false,
                foreground: isRecording ? .orange : .white
            )
        )
    }

    private var topHUDControlRow: some View {
        HStack(spacing: 0) {
            topHUDExpandCollapseButton

            if showNavShareLiveButton || showNavSendLocationButton {
                Spacer()
                    .frame(width: mapControlButtonSize)

                HStack(spacing: mapControlDefaultSpacing) {
                    if showNavShareLiveButton {
                        liveShareToggleButton
                    }
                    if showNavSendLocationButton {
                        sendLocationPinButton
                    }
                }
                .fixedSize(horizontal: true, vertical: true)
            }

            Spacer(minLength: mapControlDefaultSpacing)

            if showNavRecordSetButton || showNavCreateWaypointButton {
                HStack(spacing: mapControlDefaultSpacing) {
                    if showNavRecordSetButton {
                        recordSetButton
                    }
                    if showNavCreateWaypointButton {
                        createWaypointButton
                    }
                }
                .fixedSize(horizontal: true, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var topHUDExpandedControlButtons: some View {
        HStack(spacing: mapControlDefaultSpacing) {
            topHUDExpandCollapseButton
            fishTicketOCRButton
            mapAppearanceButton
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private var topHUDExpandCollapseButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.20)) {
                isTopHUDCollapsed.toggle()
            }
        } label: {
            Image(
                systemName: isTopHUDCollapsed
                    ? "arrow.up.left.and.arrow.down.right"
                    : "arrow.down.right.and.arrow.up.left"
            )
            .font(.system(size: 18, weight: .bold))
        }
        .buttonStyle(MapIconButtonStyle(isActive: false, foreground: .white))
        .contentShape(Rectangle())
        .zIndex(10)
        .accessibilityIdentifier("navigationTopHUDExpandCollapseButton")
        .accessibilityLabel(isTopHUDCollapsed ? "Expand top navigation HUD" : "Collapse top navigation HUD")
    }


    private var fishTicketOCRButton: some View {
        Button {
            smartLogbookStore.reloadFromDisk()
            showFishTicketOCRScreen = true
        } label: {
            Image(systemName: "camera.fill")
                .font(.system(size: 19, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundColor(.white)
        }
        .buttonStyle(
            MapIconButtonStyle(
                isActive: false,
                foreground: .white
            )
        )
        .accessibilityLabel("Open fish ticket OCR")
    }

    private var mapAppearanceButton: some View {
        Button(action: presentDistrictMapAppearanceEditor) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 19, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundColor(.white)
        }
        .buttonStyle(
            MapIconButtonStyle(
                isActive: districtMapVisualSettingsBySlug.values.contains { !$0.isNeutral },
                foreground: .white
            )
        )
        .accessibilityLabel("District map appearance")
        .accessibilityValue(districtMapVisualSettingsBySlug.isEmpty ? "Original colors" : "Custom settings applied")
        .accessibilityHint("Opens brightness, contrast, gamma, and saturation controls")
    }

    private func activeRecordSetButtonLabel(session: ActiveFishingSetSession, now: Date) -> some View {
        VStack(spacing: 0) {
            Text("\(session.setNumber)")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .lineLimit(1)

            HStack(spacing: 2) {
                Image(systemName: "timer.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .symbolRenderingMode(.monochrome)

                Text(Self.recordSetButtonElapsedText(from: session.startedAt, to: now))
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .minimumScaleFactor(0.64)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func inactiveRecordSetButtonLabel(nextSetNumber: Int) -> some View {
        VStack(spacing: 0) {
            Text("\(nextSetNumber)")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .lineLimit(1)

            Image(systemName: "timer.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.monochrome)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var createWaypointButton: some View {
        Button {
            prepareWaypointPrompt()
            showCreateWaypointPrompt = true
        } label: {
            ZStack {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 18, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundColor(.white)
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundColor(WaypointPinColor.safe(rawValue: defaultWaypointPinColorID).swiftUIColor)
                    .offset(x: 0, y: -6)
            }
        }
        .buttonStyle(MapIconButtonStyle())
    }

    private var liveShareToggleButton: some View {
        Button {
            if radioGroup.isLiveSharing {
                showConfirmStopLiveShare = true
            } else {
                guard radioGroup.canShareLocation, radioGroup.activeGroupID != nil else {
                    showShareLiveLocationUnavailableToast()
                    return
                }
                showConfirmLiveShare = true
            }
        } label: {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 18, weight: .semibold))
        }
        .buttonStyle(MapIconButtonStyle(isActive: false, foreground: liveShareStatusColor))
        .accessibilityLabel(radioGroup.isLiveSharing ? "Stop sharing live location" : "Share live location")
    }

    private var liveShareResumeBanner: some View {
        HStack(spacing: 8) {
            Text("Live Sharing is off, turn back on?")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.78)

            Spacer(minLength: 4)

            Button("Turn on") {
                dismissLiveShareResumePrompt(clearResumeState: false)
                startLiveSharing()
            }
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .foregroundColor(.black)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            Button("No") {
                dismissLiveShareResumePrompt(clearResumeState: true)
                radioGroup.pauseLiveSharingLocally()
                cancelLiveShareTimer(reason: "resume prompt declined")
            }
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .foregroundColor(.white.opacity(0.92))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(showNavTopHUDOpacity ? scSurfaceAlt.opacity(0.94) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(showNavTopHUDOpacity ? 0.16 : 0), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private var sendLocationPinButtonLabel: some View {
        VStack(spacing: 0) {
            if activeOwnSharedLocationPinCount > 0 {
                Text("\(activeOwnSharedLocationPinCount)")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .foregroundColor(.green)
            } else {
                Text("")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .lineLimit(1)
            }

            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundColor(isShareOnceFlashing ? .green : .white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sendLocationPinButton: some View {
        Button {
            guard radioGroup.canShareLocation, radioGroup.activeGroupID != nil else {
                showShareLocationPinUnavailableToast()
                return
            }
            showToast("Confirm to send location pin.", seconds: 1.4)
            showConfirmShareOnce = true
        } label: {
            sendLocationPinButtonLabel
        }
        .buttonStyle(MapIconButtonStyle(isActive: false, foreground: .white))
        .accessibilityLabel("Send location pin")
        .accessibilityValue("\(activeOwnSharedLocationPinCount) active shared location pins")
    }

    private var liveCursorStatusIndicator: some View {
        Group {
            if radioGroup.isLiveSharing {
                HStack(spacing: 3) {
                    Image(systemName: "smallcircle.filled.circle")
                        .font(.system(size: 8, weight: .bold))
                    Text("Live")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                }
                .foregroundColor(.green)
                .opacity(liveIndicatorOpacity)
                .animation(.easeInOut(duration: 0.35), value: liveIndicatorOpacity)
                .accessibilityLabel("Live location sharing active")
            }
        }
    }


    private var tideHUDBoxWidth: CGFloat {
        let outerInset = topHUDOuterHorizontalPadding * 2
        let cardContentInset: CGFloat = 8
        let panelSpacing: CGFloat = 12
        let availableWidth = UIScreen.main.bounds.width - outerInset - cardContentInset - panelSpacing
        return min(max(availableWidth / 2, 140), 230)
    }

    private var topHUDBoxHeight: CGFloat {
        84
    }

    private var topHUDMiniTideChartHeight: CGFloat {
        // Keeps the tide chart, title row, and event row inside the compact 84-pt visual height.
        UIDevice.current.userInterfaceIdiom == .pad ? 32 : 31
    }

    private var landscapeTopHUDBoxHeight: CGFloat {
        (mapControlButtonSize * 2) + mapControlDefaultSpacing
    }

    private var landscapeTopHUDMiniTideChartHeight: CGFloat {
        topHUDMiniTideChartHeight + (landscapeTopHUDBoxHeight - topHUDBoxHeight)
    }

    private var isLandscapeMode: Bool {
        UIScreen.main.bounds.width > UIScreen.main.bounds.height
    }

    private var topHUDCurrentLocationAndSpeedRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showNavLocationReadout {
                topHUDCurrentLocation
            }

            if showNavSpeedReadout {
                topHUDSpeedReadout
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var offlineModeHUDBadge: some View {
        Text("Offline mode")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundColor(showNavTopHUDOpacity ? Color(red: 1.0, green: 0.86, blue: 0.48) : .white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(showNavTopHUDOpacity ? scSurface.opacity(0.86) : Color.clear)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color(red: 1.0, green: 0.86, blue: 0.48).opacity(showNavTopHUDOpacity ? 0.40 : 0), lineWidth: 0.9)
            )
            .accessibilityLabel("Offline mode")
    }

    private var offlineModeHUDPlaceholder: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                offlineModeHUDBadge
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private var tideHUDBox: some View {
        tideHUDBox(height: topHUDBoxHeight, chartHeight: topHUDMiniTideChartHeight)
    }

    private func tideHUDBox(height: CGFloat, chartHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(showNavTopHUDOpacity ? scSurface.opacity(0.70) : Color.clear)

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(showNavTopHUDOpacity ? 0.12 : 0), lineWidth: 1)

            MiniTideHUDBox(
                snapshot: tideHUDSnapshot,
                isLoading: tideHUDIsLoading,
                errorMessage: tideHUDErrorMessage,
                backgroundColor: .clear,
                borderColor: .clear,
                progressTint: .white.opacity(0.75),
                chartHeight: chartHeight,
                trailingStatusText: offlineModeHUDText,
                onTitleTap: { showTidesWeatherPage = true }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipped()
    }

    private var topHUDLocationReadouts: some View {
        HStack(alignment: .center, spacing: 0) {
            if showNavBoundaryReadout {
                topHUDBoundaryReadout
                    .layoutPriority(1)
            }

            if showNavBoundaryReadout && (showNavKDLGButton || showNavWindReadout) {
                Spacer(minLength: 0)
            }

            if showNavKDLGButton {
                topHUDKDLGButton
            }

            if showNavKDLGButton && showNavWindReadout {
                Spacer(minLength: 0)
            }

            if showNavWindReadout {
                topHUDWindForecast
                    .frame(width: tideHUDBoxWidth, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var formattedDistanceText: String {
        formatNumericSubstrings(in: distanceText)
    }

    private func formatNumericSubstrings(in text: String) -> String {
        guard text != "—" else { return text }
        guard let regex = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#) else { return text }

        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale.current
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0

        var result = text
        for match in matches.reversed() {
            let token = source.substring(with: match.range)
            guard let value = Double(token) else { continue }

            let decimalDigits: Int
            if let dotIndex = token.firstIndex(of: ".") {
                decimalDigits = token.distance(from: token.index(after: dotIndex), to: token.endIndex)
            } else {
                decimalDigits = 0
            }

            formatter.maximumFractionDigits = decimalDigits

            guard let formatted = formatter.string(from: NSNumber(value: value)),
                  let range = Range(match.range, in: result) else { continue }

            result.replaceSubrange(range, with: formatted)
        }

        return result
    }


    private var topHUDBoundaryReadout: some View {
        Text("Boundary: \(formattedDistanceText)")
            .hudBoxSmall()
            .lineLimit(1)
    }

    private var topHUDSpeedReadout: some View {
        Text("Speed: \(speedText)")
            .hudBoxSmall()
    }

    private var topHUDKDLGButton: some View {
        Button {
            kdlgRadioPlayer.togglePlayback()
        } label: {
            Text("KDLG")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(HUDStationToggleButtonStyle(isOn: kdlgRadioPlayer.isPlaying, horizontalPadding: 5, verticalPadding: 2))
        .accessibilityLabel(kdlgRadioPlayer.isOn ? "Stop KDLG radio" : "Play KDLG radio")
    }

    private var topHUDCurrentLocation: some View {
        HStack(spacing: 6) {
            Text(isCursorTrackingUser ? "Location:" : "Cursor:")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(showNavTopHUDOpacity ? scTextPrimary : .white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: UIDevice.current.userInterfaceIdiom == .pad ? topHUDLocationLabelWidth : nil,
                       alignment: .leading)

            HUDCoordinateEntryFields(
                latitudeDegrees: $cursorLatDegInput,
                latitudeMinutes: $cursorLatMinInput,
                latitudeHemisphere: $cursorLatHemInput,
                longitudeDegrees: $cursorLonDegInput,
                longitudeMinutes: $cursorLonMinInput,
                longitudeHemisphere: $cursorLonHemInput,
                onSubmit: applyCursorInputsAndPan
            )

            if radioGroup.isLiveSharing { liveCursorStatusIndicator }
        }
        .hudBoxSmall()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var topHUDWindForecast: some View {
        HStack(spacing: 4) {
            Button {
                showTidesWeatherPage = true
            } label: {
                Text("Wind")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(SubtleHUDInlineButtonStyle(horizontalPadding: 6, verticalPadding: 2))

            ForEach(Array(topHUDWindPeriodTexts.enumerated()), id: \.offset) { index, windText in
                if index > 0 {
                    Text(",")
                }

                Image(systemName: "wind")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(topHUDWindIconColor(for: windText))
            }
        }
        .hudBoxSmall()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var topHUDWindPeriodTexts: [String] {
        guard let snapshot = tideHUDSnapshot else {
            return Array(repeating: "—", count: 5)
        }

        var periods = snapshot.weather.dailyForecasts
            .prefix(5)
            .map { $0.windText ?? "—" }

        if periods.isEmpty {
            periods.append(snapshot.weather.windText ?? "—")
        } else if periods[0] == "—",
                  let currentWindText = snapshot.weather.windText,
                  !currentWindText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            periods[0] = currentWindText
        }

        while periods.count < 5 {
            periods.append("—")
        }

        return Array(periods.prefix(5))
    }

    private func topHUDWindIconColor(for windText: String?) -> Color {
        guard let mph = topHUDMaxWindSpeedMPH(from: windText) else {
            return .white.opacity(0.55)
        }

        switch mph {
        case ...10:
            return .green
        case 10...20:
            return .yellow
        case 20...30:
            return .orange
        case 30...35:
            return .red
        default:
            return .purple
        }
    }

    private func topHUDMaxWindSpeedMPH(from windText: String?) -> Double? {
        guard let windText,
              !windText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              windText != "—" else {
            return nil
        }

        guard let regex = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#) else {
            return nil
        }

        let range = NSRange(windText.startIndex..<windText.endIndex, in: windText)
        let numbers = regex.matches(in: windText, range: range).compactMap { match -> Double? in
            guard let matchRange = Range(match.range, in: windText) else { return nil }
            return Double(windText[matchRange])
        }

        guard let maxValue = numbers.max() else { return nil }

        let lowered = windText.lowercased()
        if lowered.contains("kt") || lowered.contains("knot") {
            return maxValue * 1.15078
        }
        if lowered.contains("m/s") {
            return maxValue * 2.23694
        }
        if lowered.contains("km/h") || lowered.contains("kmh") {
            return maxValue * 0.621371
        }

        return maxValue
    }
    private var bottomControls: some View {
        GeometryReader { proxy in
            VStack {
                Spacer(minLength: 0)
                controlsStack(size: proxy.size, safeAreaInsets: proxy.safeAreaInsets)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private var sstControlsButton: some View {
        Button {
            normalizeSSTSettings()
            refreshSSTAvailability()
            showSSTControls = true
        } label: {
            Image(systemName: "square.3.layers.3d.top.filled")
                .font(.system(size: 18, weight: .semibold))
        }
        .buttonStyle(MapIconButtonStyle(isActive: sstEnabled, foreground: sstEnabled ? .cyan : .white))
        .accessibilityLabel("Ocean layers")
    }

    private var followUserButton: some View {
        Button { isFollowing.toggle(); followReq += 1 } label: {
            Image(systemName: isFollowing ? "location.fill" : "location")
                .font(.system(size: 18, weight: .semibold))
        }
        .buttonStyle(MapIconButtonStyle(isActive: isFollowing))
        .accessibilityLabel(isFollowing ? "Stop following user location" : "Follow user location")
    }

    private var recenterMapButton: some View {
        Button { recenterReq += 1 } label: {
            Image(systemName: "scope")
                .font(.system(size: 18, weight: .semibold))
        }
        .buttonStyle(MapIconButtonStyle())
        .accessibilityLabel("Recenter map")
    }

    private var basemapMenuButton: some View {
        Menu {
            Picker("Basemap", selection: basemapChoiceBinding) {
                ForEach(BasemapChoice.allCases) { choice in
                    HStack(spacing: 8) {
                        basemapIcon(for: choice, size: 18)
                        Text(choice.label)
                    }
                    .tag(choice)
                }
            }
        } label: {
            basemapIcon(for: basemapChoice, size: 18)
        }
        .buttonStyle(MapIconButtonStyle())
        .accessibilityLabel("Choose basemap")
    }

    private var appMenuButton: some View {
        Button { BBMenuAppearance.applyAll(); showMenu = true } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 18, weight: .semibold))
        }
        .buttonStyle(MapIconButtonStyle())
        .accessibilityLabel("Open menu")
    }

    private var zoomButtonsHorizontal: some View {
        HStack(spacing: 10) {
            Button { zoomInReq += 1 } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(MapIconButtonStyle())
            .accessibilityLabel("Zoom in")

            Button { zoomOutReq += 1 } label: {
                Image(systemName: "minus")
                    .font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(MapIconButtonStyle())
            .accessibilityLabel("Zoom out")
        }
    }

    private var zoomInButton: some View {
        Button { zoomInReq += 1 } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
        }
        .buttonStyle(MapIconButtonStyle())
        .accessibilityLabel("Zoom in")
    }

    private var zoomOutButton: some View {
        Button { zoomOutReq += 1 } label: {
            Image(systemName: "minus")
                .font(.system(size: 18, weight: .semibold))
        }
        .buttonStyle(MapIconButtonStyle())
        .accessibilityLabel("Zoom out")
    }

    private var portraitZoomStackHeight: CGFloat {
        let count = visibleZoomButtonCount
        guard count > 0 else { return 0 }
        return (mapControlButtonSize * CGFloat(count)) + (10 * CGFloat(max(count - 1, 0)))
    }

    private var portraitSSTLegendHeight: CGFloat {
        max(52, portraitZoomStackHeight / 2)
    }

    private func landscapeCompactSSTLegendWidth(for availableWidth: CGFloat) -> CGFloat {
        let widthFactor: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 0.26 : 0.34
        return min(max(availableWidth * widthFactor, 220), 300)
    }

    private var portraitZoomButtons: some View {
        VStack(spacing: 10) {
            if showNavZoomInButton { zoomInButton }
            if showNavZoomOutButton { zoomOutButton }
        }
    }

    private func portraitSSTLegendAndZoomRow(safeAreaInsets: EdgeInsets) -> some View {
        let horizontalInsets = mapHorizontalInsets(safeAreaInsets: safeAreaInsets, base: 10)

        return GeometryReader { proxy in
            let legendGapWidth: CGFloat = 48
            let zoomStackWidth: CGFloat = 48
            let availableWidth = max(0, proxy.size.width - horizontalInsets.leading - horizontalInsets.trailing)
            let legendWidth = max(0, availableWidth - zoomStackWidth - legendGapWidth)

            HStack(alignment: .bottom, spacing: 0) {
                if sstEnabled {
                    SSTLegendCard(
                        source: sstSource,
                        dateUTC: sstDateUTC,
                        onExit: { sstEnabled = false },
                        preferredWidth: legendWidth,
                        preferredHeight: portraitSSTLegendHeight
                    )
                    .frame(width: legendWidth, height: portraitSSTLegendHeight, alignment: .topLeading)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }

                Spacer(minLength: legendGapWidth)

                portraitZoomButtons
                    .frame(width: zoomStackWidth, height: portraitZoomStackHeight, alignment: .top)
            }
            .padding(.leading, horizontalInsets.leading)
            .padding(.trailing, horizontalInsets.trailing)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(height: portraitZoomStackHeight)
        .animation(.easeInOut(duration: 0.2), value: sstEnabled)
    }

    @ViewBuilder
    private var sstLegendOverlay: some View {
        GeometryReader { proxy in
            let landscape = responsiveIsLandscape(proxy.size)
            let horizontalInsets = mapHorizontalInsets(
                safeAreaInsets: proxy.safeAreaInsets,
                base: landscape ? landscapeHUDOuterHorizontalPadding : 10
            )
            let availableWidth = max(0, proxy.size.width - horizontalInsets.leading - horizontalInsets.trailing)

            if sstEnabled && showNavOceanLayerLegend && landscape {
                VStack {
                    Spacer()

                    HStack(alignment: .bottom, spacing: 0) {
                        SSTLegendCard(
                            source: sstSource,
                            dateUTC: sstDateUTC,
                            onExit: { sstEnabled = false },
                            preferredWidth: landscapeCompactSSTLegendWidth(for: availableWidth),
                            preferredHeight: portraitSSTLegendHeight
                        )
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, horizontalInsets.leading)
                    .padding(.trailing, horizontalInsets.trailing)
                    .padding(.bottom, 118)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: sstEnabled)
                .animation(.easeInOut(duration: 0.2), value: landscape)
            }
        }
    }

    private var mapControlButtonSize: CGFloat { 48 }
    private var mapControlDefaultSpacing: CGFloat { 10 }

    private var mapVersionButtonWidth: CGFloat {
        (mapControlButtonSize * 2) + mapControlDefaultSpacing
    }

    private func compactBottomControlSpacing(for availableWidth: CGFloat) -> CGFloat {
        if availableWidth < 370 { return 3 }
        if availableWidth < 390 { return 5 }
        return 10
    }

    private func compactMapSelectorWidth(availableWidth: CGFloat, spacing: CGFloat) -> CGFloat {
        guard showNavMapSelector else { return 0 }

        let mainCount = CGFloat(visibleBottomMainButtonCount)
        let mainSpacingCount = max(0, mainCount - 1)
        let mainButtonWidth = (mapControlButtonSize * mainCount) + (spacing * mainSpacingCount)
        let maximum = mapVersionButtonWidth

        // Size the wider Map v# button from the actual visible row content so
        // hiding any individual bottom button frees space instead of leaving a
        // phantom five-button reservation.
        let remaining = availableWidth - mainButtonWidth - spacing
        return max(0, min(remaining, maximum))
    }

    private func bottomControlBottomPadding(_ safeAreaInsets: EdgeInsets) -> CGFloat {
        max(2, min(safeAreaInsets.bottom * 0.20, 6))
    }

    private func landscapeBottomControlBottomPadding(_ safeAreaInsets: EdgeInsets) -> CGFloat {
        if UIDevice.current.userInterfaceIdiom == .pad {
            // Give the entire button/scale row a visible lift above the bottom
            // edge, including iPads whose bottom safe-area inset is zero.
            return bottomControlBottomPadding(safeAreaInsets) + 16
        }
        return max(0, min(safeAreaInsets.bottom * 0.08, 2))
    }

    private func controlsStack(size: CGSize, safeAreaInsets: EdgeInsets) -> some View {
        let landscape = responsiveIsLandscape(size)
        let baseHorizontalPadding = landscape ? landscapeBottomHUDOuterHorizontalPadding : 10
        let horizontalInsets = landscape
            ? centeredMapHorizontalInsets(safeAreaInsets: safeAreaInsets, base: baseHorizontalPadding)
            : portraitBottomSymmetricHorizontalInsets(safeAreaInsets: safeAreaInsets, base: baseHorizontalPadding)
        let availableWidth = max(0, size.width - horizontalInsets.leading - horizontalInsets.trailing)

        return VStack(spacing: 5) {
            if landscape {
                landscapeControls(availableWidth: availableWidth, horizontalInsets: horizontalInsets, safeAreaInsets: safeAreaInsets)
            } else {
                portraitControls(availableWidth: availableWidth, horizontalInsets: horizontalInsets, safeAreaInsets: safeAreaInsets)
            }
        }
        .padding(.bottom, landscape ? landscapeBottomControlBottomPadding(safeAreaInsets) : bottomControlBottomPadding(safeAreaInsets))
    }

    private func mapVersionCycleButton(width: CGFloat) -> some View {
        Button {
            cycleToNextMapVersion()
        } label: {
            Text(mapVersionButtonLabel)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
        .frame(width: width, height: mapControlButtonSize)
        .background(scSurface.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(globalMapVersionCount > 1 ? 1.0 : 0.72)
        .contextMenu {
            if basemapChoice == .districtsOnline {
                Button("Refresh online map versions", systemImage: "arrow.clockwise") {
                    onlineDistrictAvailability.refreshIfNeeded(force: true)
                }
            }
        }
        .accessibilityLabel(basemapChoice == .districtsOnline ? "Cycle online district map version" : "Cycle downloaded map version")
        .accessibilityValue(basemapChoice == .districtsOnline
            ? "Map version \(selectedMapCycleVersion), \(globalMapVersionCount) online versions available"
            : "Map version \(selectedMapCycleVersion) of \(globalMapVersionCount)")
    }

    private var bottomMainButtons: some View {
        bottomMainButtons(spacing: mapControlDefaultSpacing)
    }

    @ViewBuilder
    private func bottomMainButtons(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            if showNavFollowUserButton {
                followUserButton
            }

            if showNavRecenterButton {
                recenterMapButton
            }

            if showNavBasemapButton {
                basemapMenuButton
            }

            if showNavMainMenuButton {
                appMenuButton
            }

            if showNavOceanLayersButton {
                sstControlsButton
            }
        }
    }

    @ViewBuilder
    private func scaleBarBottomRow(horizontalInsets: EdgeInsets) -> some View {
        if showNavScaleBar {
            HStack {
                Spacer(minLength: 0)
                ThinScaleBar(metersPerPoint: metersPerPoint)
                Spacer(minLength: 0)
            }
            .padding(.top, -1)
            .padding(.leading, horizontalInsets.leading)
            .padding(.trailing, horizontalInsets.trailing)
        }
    }

    private func portraitUpperUtilityRow(
        availableWidth: CGFloat,
        horizontalInsets: EdgeInsets,
        selectorWidth: CGFloat
    ) -> some View {
        let hasVisibleZoomButtons = visibleZoomButtonCount > 0
        let showLegend = sstEnabled && showNavOceanLayerLegend
        let zoomColumnWidth: CGFloat = hasVisibleZoomButtons ? max(mapControlButtonSize, selectorWidth) : 0
        let gapWidth: CGFloat = showLegend && hasVisibleZoomButtons ? mapControlDefaultSpacing : 0
        let leftWidth = max(0, availableWidth - zoomColumnWidth - gapWidth)
        let zoomHeight = max(
            mapControlButtonSize,
            (mapControlButtonSize * CGFloat(visibleZoomButtonCount)) + (10 * CGFloat(max(0, visibleZoomButtonCount - 1)))
        )

        return HStack(alignment: .bottom, spacing: gapWidth) {
            if showLegend {
                SSTLegendCard(
                    source: sstSource,
                    dateUTC: sstDateUTC,
                    onExit: { sstEnabled = false },
                    preferredWidth: leftWidth,
                    preferredHeight: portraitSSTLegendHeight
                )
                .frame(width: leftWidth, height: portraitSSTLegendHeight, alignment: .topLeading)
                .transition(.opacity.combined(with: .move(edge: .leading)))
            } else {
                Spacer(minLength: 0)
            }

            if hasVisibleZoomButtons {
                portraitZoomButtons
                    .frame(width: zoomColumnWidth, height: zoomHeight, alignment: .trailing)
            }
        }
        .padding(.leading, horizontalInsets.leading)
        .padding(.trailing, horizontalInsets.trailing)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .animation(.easeInOut(duration: 0.2), value: sstEnabled)
        .animation(.easeInOut(duration: 0.2), value: showNavOceanLayerLegend)
    }

    private func bottomSelectorRow(
        availableWidth: CGFloat,
        horizontalInsets: EdgeInsets,
        selectorWidth: CGFloat,
        spacing: CGFloat,
        includesSetButtons: Bool
    ) -> some View {
        HStack(spacing: 0) {
            bottomMainButtons(spacing: spacing)

            if showNavMapSelector || (includesSetButtons && (showNavRecordSetButton || showNavCreateWaypointButton)) {
                Spacer(minLength: spacing)
            }

            if includesSetButtons {
                HStack(spacing: spacing) {
                    if showNavRecordSetButton {
                        recordSetButton
                    }
                    if showNavCreateWaypointButton { createWaypointButton }
                    if showNavMapSelector { mapVersionCycleButton(width: selectorWidth) }
                }
            } else if showNavMapSelector {
                mapVersionCycleButton(width: selectorWidth)
            }
        }
        .frame(width: availableWidth, alignment: .leading)
        .padding(.leading, horizontalInsets.leading)
        .padding(.trailing, horizontalInsets.trailing)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func landscapeSelectorWidth(availableWidth: CGFloat, includesSetButtons: Bool) -> CGFloat {
        let setButtonCount = includesSetButtons ? ((showNavRecordSetButton ? 1 : 0) + (showNavCreateWaypointButton ? 1 : 0)) : 0
        let setButtonAllowance: CGFloat = setButtonCount > 0
            ? (CGFloat(setButtonCount) * mapControlButtonSize) + (CGFloat(max(setButtonCount - 1, 0)) * mapControlDefaultSpacing)
            : 0
        let minimumLeftControls = (mapControlButtonSize * 5) + (mapControlDefaultSpacing * 4) + setButtonAllowance
        let remaining = availableWidth - minimumLeftControls - mapControlDefaultSpacing
        return min(max(remaining, 98), mapVersionButtonWidth)
    }

    private var landscapeCompactControlScale: CGFloat {
        1.0
    }

    private var landscapeCompactControlSize: CGFloat {
        mapControlButtonSize
    }

    private func landscapeInlineControlSpacing(for availableWidth: CGFloat) -> CGFloat {
        // Keep adjacent landscape HUD buttons evenly spaced in both the
        // top action row and the bottom control row. Very narrow devices
        // can still use the horizontal scroll fallback below instead of
        // squeezing the controls into inconsistent gaps.
        mapControlDefaultSpacing
    }

    private func landscapeCompressedControl<Content: View>(_ content: Content) -> some View {
        content
            .scaleEffect(landscapeCompactControlScale)
            .frame(width: landscapeCompactControlSize, height: landscapeCompactControlSize)
    }

    private func landscapeInlineScaleBarWidth(for availableWidth: CGFloat) -> CGFloat {
        // Landscape uses a custom compact scale bar whose visual bar length is
        // 30% shorter than the standard NauticalScaleBar line (140 pt -> 98 pt).
        // Keep the row footprint large enough for the distance label so the
        // numbers remain readable while the bar itself is less dominant.
        if UIDevice.current.userInterfaceIdiom == .pad { return 176 }
        if availableWidth < 735 { return 136 }
        if availableWidth < 800 { return 148 }
        return 160
    }

    private func landscapeInlineScaleBar(availableWidth: CGFloat) -> some View {
        LandscapeCompactScaleBar(metersPerPoint: metersPerPoint)
            .fixedSize(horizontal: true, vertical: true)
            .frame(
                width: landscapeInlineScaleBarWidth(for: availableWidth),
                height: 32,
                alignment: .center
            )
    }

    private func landscapeInlineSelector(width: CGFloat) -> some View {
        mapVersionCycleButton(width: width)
            .scaleEffect(landscapeCompactControlScale)
            .frame(width: width * landscapeCompactControlScale, height: landscapeCompactControlSize)
    }

    private func landscapeInlineSelectorWidth(for availableWidth: CGFloat) -> CGFloat {
        mapVersionButtonWidth
    }

    private func landscapeSetButtonGapWidth(spacing: CGFloat) -> CGFloat {
        // HStack adds spacing on both sides of this invisible gap; subtract those
        // two spacings so the visual empty area is approximately one button wide.
        max(0, landscapeCompactControlSize - (spacing * 2))
    }

    private func landscapeControlsRequiredWidth(
        availableWidth: CGFloat,
        selectorWidth: CGFloat,
        spacing: CGFloat
    ) -> CGFloat {
        let mainWidth = buttonGroupWidth(count: visibleBottomMainButtonCount, spacing: spacing)
        let zoomWidth = buttonGroupWidth(count: visibleZoomButtonCount, spacing: spacing)
        let selectorLayoutWidth = showNavMapSelector ? (selectorWidth * landscapeCompactControlScale) : 0
        let scaleWidth = showNavScaleBar ? landscapeInlineScaleBarWidth(for: availableWidth) : 0
        let visibleGroups = [
            visibleBottomMainButtonCount > 0,
            showNavScaleBar,
            showNavMapSelector,
            visibleZoomButtonCount > 0
        ].filter { $0 }.count
        let minimumSpacing = CGFloat(max(visibleGroups - 1, 0)) * spacing

        return mainWidth + scaleWidth + selectorLayoutWidth + zoomWidth + minimumSpacing
    }

    @ViewBuilder
    private func landscapeControls(availableWidth: CGFloat, horizontalInsets: EdgeInsets, safeAreaInsets: EdgeInsets) -> some View {
        let spacing = landscapeInlineControlSpacing(for: availableWidth)
        let selectorWidth = landscapeInlineSelectorWidth(for: availableWidth)
        let rowWidth = max(availableWidth, landscapeControlsRequiredWidth(
            availableWidth: availableWidth,
            selectorWidth: selectorWidth,
            spacing: spacing
        ))
        let containerWidth = availableWidth
        let landscapeOffset = landscapeHUDCenteringOffset(safeAreaInsets: safeAreaInsets)

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: spacing) {
                if showNavFollowUserButton {
                    landscapeCompressedControl(followUserButton)
                }

                if showNavRecenterButton {
                    landscapeCompressedControl(recenterMapButton)
                }

                if showNavBasemapButton {
                    landscapeCompressedControl(basemapMenuButton)
                }

                if showNavMainMenuButton {
                    landscapeCompressedControl(appMenuButton)
                }

                if showNavOceanLayersButton {
                    landscapeCompressedControl(sstControlsButton)
                }

                if showNavScaleBar {
                    Spacer(minLength: 0)
                    landscapeInlineScaleBar(availableWidth: availableWidth)
                    Spacer(minLength: 0)
                }

                if showNavMapSelector {
                    landscapeInlineSelector(width: selectorWidth)
                }

                if showNavZoomInButton {
                    landscapeCompressedControl(zoomInButton)
                }

                if showNavZoomOutButton {
                    landscapeCompressedControl(zoomOutButton)
                }
            }
            .frame(width: rowWidth, alignment: .center)
        }
        .frame(width: containerWidth, alignment: .center)
        .offset(x: landscapeOffset)
        .frame(maxWidth: .infinity, alignment: .bottom)
    }

    private func portraitControls(availableWidth: CGFloat, horizontalInsets: EdgeInsets, safeAreaInsets: EdgeInsets) -> some View {
        let rowSpacing = compactBottomControlSpacing(for: availableWidth)
        let selectorWidth = compactMapSelectorWidth(availableWidth: availableWidth, spacing: rowSpacing)

        return VStack(spacing: 5) {
            if (sstEnabled && showNavOceanLayerLegend) || visibleZoomButtonCount > 0 {
                portraitUpperUtilityRow(
                    availableWidth: availableWidth,
                    horizontalInsets: horizontalInsets,
                    selectorWidth: selectorWidth
                )
            }

            bottomSelectorRow(
                availableWidth: availableWidth,
                horizontalInsets: horizontalInsets,
                selectorWidth: selectorWidth,
                spacing: rowSpacing,
                includesSetButtons: false
            )

            if showNavScaleBar {
                scaleBarBottomRow(horizontalInsets: horizontalInsets)
            }
        }
    }

    @ViewBuilder
    private func basemapIcon(for choice: BasemapChoice, size: CGFloat) -> some View {
        switch choice {
        case .districtsOffline:
            ZStack {
                Image(systemName: "map.fill")
                    .font(.system(size: size + 1, weight: .semibold))

                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: size - 1, weight: .bold))
                    .foregroundColor(.green)
                    .background(
                        Circle()
                            .fill(Color(.systemBackground))
                            .frame(width: size - 1, height: size - 1)
                    )
                    .offset(x: size * 0.42, y: size * 0.36)
            }
            .frame(width: size + 10, height: size + 10)

        case .appleSatellite:
            Image(systemName: "globe.americas.fill")
                .font(.system(size: size, weight: .semibold))

        case .districtsOnline:
            ZStack {
                Image(systemName: "globe.americas.fill")
                    .font(.system(size: size + 1, weight: .semibold))

                Image(systemName: "photo.fill")
                    .font(.system(size: size - 3, weight: .bold))
                    .foregroundColor(.white)
                    .background(
                        Circle()
                            .fill(Color(.systemBackground))
                            .frame(width: size - 1, height: size - 1)
                    )
                    .offset(x: size * 0.36, y: size * 0.28)
            }
            .frame(width: size + 10, height: size + 10)

        case .bristolBaySatelliteOffline:
            ZStack {
                Image(systemName: "globe.americas.fill")
                    .font(.system(size: size + 1, weight: .semibold))

                Image(systemName: "photo.fill")
                    .font(.system(size: size - 4, weight: .bold))
                    .foregroundColor(.white)
                    .background(
                        Circle()
                            .fill(Color(.systemBackground))
                            .frame(width: size - 1, height: size - 1)
                    )
                    .offset(x: size * 0.26, y: size * 0.18)

                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: size - 1, weight: .bold))
                    .foregroundColor(.green)
                    .background(
                        Circle()
                            .fill(Color(.systemBackground))
                            .frame(width: size - 1, height: size - 1)
                    )
                    .offset(x: size * 0.44, y: size * 0.42)
            }
            .frame(width: size + 10, height: size + 10)

        case .topoOnline:
            ZStack {
                Image(systemName: "mountain.2")
                    .font(.system(size: size + 1, weight: .semibold))

                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: size - 2, weight: .bold))
                    .foregroundColor(.orange)
                    .background(
                        Circle()
                            .fill(Color(.systemBackground))
                            .frame(width: size - 1, height: size - 1)
                    )
                    .offset(x: size * 0.38, y: size * 0.28)
            }
            .frame(width: size + 10, height: size + 10)

        case .noaaOffline:
            ZStack {
                Image(systemName: "map")
                    .font(.system(size: size + 2, weight: .semibold))

                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: size - 1, weight: .bold))
                    .foregroundColor(.green)
                    .background(
                        Circle()
                            .fill(Color(.systemBackground))
                            .frame(width: size - 1, height: size - 1)
                    )
                    .offset(x: size * 0.42, y: size * 0.36)
            }
            .frame(width: size + 10, height: size + 10)

        case .noaaOnline:
            ZStack {
                Image(systemName: "map")
                    .font(.system(size: size + 2, weight: .semibold))

                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: size - 1, weight: .bold))
                    .foregroundColor(.blue)
                    .background(
                        Circle()
                            .fill(Color(.systemBackground))
                            .frame(width: size - 1, height: size - 1)
                    )
                    .offset(x: 0, y: -size * 0.10)
            }
            .frame(width: size + 10, height: size + 10)
        }
    }
    private var sstControlsSheet: some View {
        SSTControlsSheetView(
            isPresented: $showSSTControls,
            availability: sstAvailability,
            initialEnabled: sstEnabled,
            initialOpacity: sstOpacity,
            initialSource: sstSource,
            initialDateUTC: sstDateUTC
        ) { enabled, opacity, source, dateUTC in
            sstEnabled = enabled
            sstOpacity = opacity
            sstSourceRaw = source.rawValue
            sstDateUTC = dateUTC
            normalizeSSTSettings()
        }
    }

    @ViewBuilder
    private var waypointPromptOverlay: some View {
        if showCreateWaypointPrompt {
            CreateWaypointPrompt(
                name: $pendingWaypointName,
                onCreate: { createWaypoint(named: pendingWaypointName); showCreateWaypointPrompt = false },
                onCancel: { showCreateWaypointPrompt = false }
            )
            .transition(.opacity)
            .zIndex(10)
        }
    }

    @ViewBuilder
    private var setPromptOverlay: some View {
        if showStartSetPrompt {
            StartSetPrompt(
                onStart: { startRecordingSet() },
                onCancel: { showStartSetPrompt = false }
            )
            .transition(.opacity)
            .zIndex(12)
        }

        if let flashUntil = recordingSetFlashUntil, Date() < flashUntil {
            RecordingSetFlashPrompt()
                .transition(.opacity)
                .zIndex(13)
        }

        if showCompletedSetPrompt, let completedSetDraft {
            CompletedSetPrompt(
                set: completedSetDraft,
                catchPoundsText: $setCatchPoundsText,
                fishCountText: $setCatchFishCountText,
                pickingMinutes: $setPickingMinutes,
                notes: $setNotesText,
                displayOnMap: $setDisplayOnMap,
                isResolvingTide: isResolvingSetTide,
                onSave: { saveCompletedSetAndExit() },
                onCancel: { discardCompletedSetDraft() }
            )
            .transition(.opacity)
            .zIndex(14)
        }
    }

    private var mapScreenContent: some View {
        Group {
            if showFishTicketOCRScreen {
                Color.black
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            } else {
                ZStack {
                    mapLayer
                    topHUD
                    bottomControls
                    waypointPromptOverlay
                    setPromptOverlay
                }
            }
        }
    }

    private var configuredMapScreen: some View {
        mapScreenContent
            .overlay(alignment: .bottomLeading) {
                sstLegendOverlay
            }
            .overlay(alignment: .topTrailing) {
                if showFloatingOfflineModeBadge {
                    offlineModeHUDBadge
                        .padding(.top, mapControlButtonSize + 12)
                        .padding(.trailing, 12)
                }
            }
            .environment(\.navigationReadoutBackgroundsVisible, showNavTopHUDOpacity)
            .navigationDestination(isPresented: $showTidesWeatherPage) {
                TidesWeatherPageView()
            }
            .navigationDestination(isPresented: $showFishTicketOCRScreen) {
                SmartFishTicketOCRLaunchFlowView(store: smartLogbookStore)
            }
            .task(id: tideHUDRequestKey) {
                await loadTideHUDSnapshot(
                    latitude: tideHUDRequestedCoordinate.latitude,
                    longitude: tideHUDRequestedCoordinate.longitude
                )
            }
            .onAppear {
                reconcileForegroundLiveSharing(reason: "navigation appeared")
            }
            .onDisappear {
                if scenePhase == .active {
                    debugLiveShareLog("navigation disappeared while scene active; preserving live sharing")
                } else {
                    suspendLiveSharingForBackground()
                }
            }
            .sheet(isPresented: $showSSTControls) {
                sstControlsSheet
            }
            .sheet(isPresented: $showDistrictMapAppearanceEditor) {
                DistrictMapAppearanceEditorView(
                    downloadedPacks: downloadedDistrictMapPacks,
                    appliedSettingsBySlug: districtMapVisualSettingsBySlug,
                    initialSelectedSlug: districtMapAppearanceSelectedSlug,
                    onSelectionChange: { slug in
                        districtMapAppearanceSelectedSlug = slug
                    },
                    onRestore: { slug in
                        persistDistrictMapVisualSettings(.neutral, forSlug: slug)
                    },
                    onApply: { slug, settings in
                        persistDistrictMapVisualSettings(settings, forSlug: slug)
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .onChange(of: sstSourceRaw) { _ in
                refreshSSTAvailability(for: sstSource)
                normalizeSSTSettings()
            }
            .onChange(of: sstLatestAvailableUTC) { _ in
                normalizeSSTSettings()
            }
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .background:
                    onlineDistrictAvailability.cancelRefresh()
                    kdlgRadioPlayer.stop()
                    suspendLiveSharingForBackground()
                case .inactive:
                    suspendLiveSharingForBackground()
                case .active:
                    if basemapChoice == .districtsOnline { onlineDistrictAvailability.refreshIfNeeded() }
                    reconcileForegroundLiveSharing(reason: "scene became active")
                @unknown default:
                    break
                }
            }
            .onChange(of: radioGroup.canShareLocation) { canShare in
                if !canShare, radioGroup.isLiveSharing || liveShareTimer != nil {
                    stopLiveSharing(showUnavailableToast: true, reason: "sharing permission became invalid")
                } else if canShare {
                    reconcileForegroundLiveSharing(reason: "sharing permission became available")
                }
            }
            .onChange(of: radioGroup.activeGroupID) { _ in
                if radioGroup.isLiveSharing || liveShareTimer != nil {
                    stopLiveSharing(showUnavailableToast: true, reason: "active radio group changed")
                } else {
                    reconcileForegroundLiveSharing(reason: "active radio group changed")
                }
            }
            .onChange(of: radioGroup.isLiveSharing) { isLiveSharing in
                if !isLiveSharing {
                    cancelLiveShareTimer(reason: "store reported sharing off")
                } else if !isStartingLiveSharing && liveShareTimer == nil {
                    reconcileForegroundLiveSharing(reason: "store reported sharing on")
                }
            }
            .onChange(of: kdlgRadioPlayer.lastErrorMessage) { message in
                guard let message else { return }
                showToast(message, seconds: 2.6)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                kdlgRadioPlayer.stop()
                suspendLiveSharingForBackground()
            }
            .onReceive(NotificationCenter.default.publisher(for: .smartLogbookDidChange)) { _ in
                smartLogbookStore.reloadFromDisk()
            }
            .fullScreenCover(isPresented: $showMenu) {
                AppMenuTabsView(waypoints: $waypoints)
                    .environmentObject(pinSettings)
                    .environmentObject(radioGroup)
                    .onAppear { BBMenuAppearance.applyAll() }
            }
    }

    var body: some View {
        NavigationStack {
            configuredMapScreen
        }
        .onChange(of: waypoints) { newValue in
            guard didLoadPersistedWaypoints else { return }
            WaypointLocalStore.save(newValue)
        }
    }

    private func prepareWaypointPrompt() { pendingWaypointName = "\(waypoints.count + 1)" }

    private func createWaypoint(named name: String) {
        let coord = cursorCoordinate ?? locationManager.userLocation
        guard let coord else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "\(waypoints.count + 1)" : trimmed
        let color = WaypointPinColor.safe(
            rawValue: defaultWaypointPinColorID,
            fallback: WaypointColorPreferences.ensureLocalDefaultColor()
        )
        defaultWaypointPinColorID = color.rawValue
        waypoints.append(Waypoint(name: finalName, notes: "", coordinate: coord, colorID: color.rawValue, createdAt: Date()))
    }

    @MainActor
    private func startRecordingSet() {
        showStartSetPrompt = false
        smartLogbookStore.reloadFromDisk()

        guard let coordinate = locationManager.userLocation else {
            showBigToast("GPS location is required to start recording a set.", seconds: 2.8)
            return
        }

        let startedAt = Date()
        let sessionID = UUID()
        let firstLocation = SmartFishingSetLocation(recordedAt: startedAt, coordinate: coordinate)
        let fallbackDistrict = preferredFishingSetDistrict(for: coordinate)
        let setNumber = smartLogbookStore.previewFishingSetNumber(for: startedAt, fallbackDistrict: fallbackDistrict)

        activeSetSession = ActiveFishingSetSession(
            id: sessionID,
            setNumber: setNumber,
            startedAt: startedAt,
            startTide: nil,
            locations: [firstLocation]
        )

        let flashUntil = Date().addingTimeInterval(3)
        recordingSetFlashUntil = flashUntil
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if recordingSetFlashUntil == flashUntil {
                recordingSetFlashUntil = nil
            }
        }

        setTrackingTimer?.cancel()
        setTrackingTimer = Timer.publish(every: 180, tolerance: 8, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                Task { @MainActor in
                    appendSetLocationSample(recordedAt: Date())
                }
            }

        Task {
            let tide = await fishingSetTideSnapshot(for: coordinate, at: startedAt)
            await MainActor.run {
                if activeSetSession?.id == sessionID {
                    activeSetSession?.startTide = tide
                }
            }
        }
    }

    @MainActor
    private func appendSetLocationSample(recordedAt: Date = Date()) {
        guard var session = activeSetSession,
              let coordinate = locationManager.userLocation else { return }

        // Keep every timed sample, but avoid immediate double-taps writing the exact same fix.
        if let last = session.locations.last {
            let deltaSeconds = recordedAt.timeIntervalSince(last.recordedAt)
            let lastLocation = CLLocation(latitude: last.latitude, longitude: last.longitude)
            let nextLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if deltaSeconds < 20 && lastLocation.distance(from: nextLocation) < 3 {
                return
            }
        }

        session.locations.append(SmartFishingSetLocation(recordedAt: recordedAt, coordinate: coordinate))
        activeSetSession = session
    }

    @MainActor
    private func finishRecordingSet() {
        guard activeSetSession != nil else { return }

        appendSetLocationSample(recordedAt: Date())
        guard var session = activeSetSession else { return }

        let endedAt = Date()
        let endCoordinate = locationManager.userLocation ?? session.locations.last?.coordinate
        if let endCoordinate {
            let lastCoordinate = session.locations.last?.coordinate
            let shouldAppendEnd: Bool = {
                guard let lastCoordinate else { return true }
                let lastLocation = CLLocation(latitude: lastCoordinate.latitude, longitude: lastCoordinate.longitude)
                let endLocation = CLLocation(latitude: endCoordinate.latitude, longitude: endCoordinate.longitude)
                return endLocation.distance(from: lastLocation) > 3
                    || endedAt.timeIntervalSince(session.locations.last?.recordedAt ?? endedAt) > 20
            }()

            if shouldAppendEnd {
                session.locations.append(SmartFishingSetLocation(recordedAt: endedAt, coordinate: endCoordinate))
            }
        }

        setTrackingTimer?.cancel()
        setTrackingTimer = nil
        activeSetSession = nil
        isResolvingSetTide = true

        Task {
            let resolvedStartTide: SmartFishingSetTideSnapshot?
            if let existingStartTide = session.startTide {
                resolvedStartTide = existingStartTide
            } else {
                resolvedStartTide = await fishingSetTideSnapshot(for: session.locations.first?.coordinate, at: session.startedAt)
            }

            let resolvedEndTide = await fishingSetTideSnapshot(for: endCoordinate, at: endedAt)
            let resolvedLocation: SmartFishingSetResolvedLocation?
            if let startCoordinate = session.locations.first?.coordinate {
                resolvedLocation = SmartFishingSetLocationResolver.shared.resolve(
                    startCoordinate: startCoordinate,
                    tideSnapshot: resolvedStartTide
                )
            } else {
                resolvedLocation = nil
            }

            let finalSet = SmartFishingSetRecord(
                id: session.id,
                setNumber: session.setNumber,
                startedAt: session.startedAt,
                endedAt: endedAt,
                locations: session.locations,
                startTide: resolvedStartTide,
                endTide: resolvedEndTide,
                locationLabel: resolvedLocation?.label,
                locationKind: resolvedLocation?.kind,
                locationDistrictKey: resolvedLocation?.districtKey,
                catchText: "",
                pickingMinutes: nil,
                notes: "",
                displayOnNavPage: false
            )

            await MainActor.run {
                completedSetDraft = finalSet
                setCatchPoundsText = ""
                setCatchFishCountText = ""
                setNotesText = ""
                setPickingMinutes = -1
                setDisplayOnMap = false
                showCompletedSetPrompt = true
                isResolvingSetTide = false
            }
        }
    }

    @MainActor
    private func saveCompletedSetAndExit() {
        guard var completedSetDraft else { return }

        completedSetDraft.catchText = Self.formattedSetCatchText(
            poundsText: setCatchPoundsText,
            fishCountText: setCatchFishCountText
        )
        completedSetDraft.notes = setNotesText.trimmingCharacters(in: .whitespacesAndNewlines)
        completedSetDraft.pickingMinutes = setPickingMinutes >= 0 ? setPickingMinutes : nil
        completedSetDraft.displayOnNavPage = setDisplayOnMap

        smartLogbookStore.reloadFromDisk()
        let fallbackDistrict = smartLogbookDistrict(from: completedSetDraft.locationDistrictKey)
            ?? preferredFishingSetDistrict(for: completedSetDraft.startCoordinate)

        if let savedSet = smartLogbookStore.addFishingSet(completedSetDraft, fallbackDistrict: fallbackDistrict) {
            showToast("Set \(savedSet.setNumber) saved.", seconds: 2.4)
        } else {
            showBigToast("Set could not be saved to the logbook.", seconds: 2.8)
        }

        discardCompletedSetDraft()
    }

    private func preferredFishingSetDistrict(for coordinate: CLLocationCoordinate2D?) -> District {
        if let coordinate,
           let resolvedDistrictKey = SmartFishingSetLocationResolver.shared
                .resolve(startCoordinate: coordinate, tideSnapshot: nil)
                .districtKey,
           let resolvedDistrict = smartLogbookDistrict(from: resolvedDistrictKey) {
            return resolvedDistrict
        }

        return smartLogbookStore.activeSeason?.currentDistrict ?? smartLogbookStore.draftDistrict
    }

    private func smartLogbookDistrict(from key: String?) -> District? {
        switch key {
        case "naknek_kvichak":
            return .naknekKvichak
        case "egegik":
            return .egegik
        case "ugashik":
            return .ugashik
        case "nushagak":
            return .nushagak
        case "togiak":
            return .togiak
        default:
            return nil
        }
    }

    static func formattedSetCatchText(poundsText: String, fishCountText: String) -> String {
        let pounds = poundsText.trimmingCharacters(in: .whitespacesAndNewlines)
        let fishCount = fishCountText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !pounds.isEmpty && !fishCount.isEmpty {
            return "\(pounds) lbs / \(fishCount) fish"
        }
        if !pounds.isEmpty { return "\(pounds) lbs" }
        if !fishCount.isEmpty { return "\(fishCount) fish" }
        return ""
    }

    @MainActor
    private func discardCompletedSetDraft() {
        completedSetDraft = nil
        showCompletedSetPrompt = false
        setCatchPoundsText = ""
        setCatchFishCountText = ""
        setNotesText = ""
        setPickingMinutes = -1
        setDisplayOnMap = false
        isResolvingSetTide = false
    }

    @MainActor
    private func fishingSetTideSnapshot(
        for coordinate: CLLocationCoordinate2D?,
        at date: Date
    ) async -> SmartFishingSetTideSnapshot? {
        guard let coordinate else {
            return SmartFishingSetTideSnapshot(
                stationName: "Location unavailable",
                heightFeet: nil,
                state: .unknown
            )
        }

        do {
            let snapshot = try await tidesWeatherService.fetchSnapshot(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                preferredStationID: tideHUDPreferredStationID,
                referenceDate: date
            )

            let isNearLiveSample = abs(date.timeIntervalSince(Date())) < (2 * 3600)
            let height = (isNearLiveSample ? snapshot.tides.currentWaterLevelFeet : nil)
                ?? Self.interpolatedTideHeight(from: snapshot.tides.curvePoints, at: date)
                ?? snapshot.tides.currentWaterLevelFeet
            let state = Self.tideState(from: snapshot.tides.curvePoints, at: date)

            return SmartFishingSetTideSnapshot(
                stationID: snapshot.tides.stationID,
                stationName: snapshot.tides.stationName,
                stationDistanceMiles: snapshot.tides.stationDistanceMiles,
                heightFeet: height,
                state: state
            )
        } catch {
            return SmartFishingSetTideSnapshot(
                stationName: "Nearest NOAA station unavailable",
                heightFeet: nil,
                state: .unknown
            )
        }
    }

    private static func interpolatedTideHeight(from points: [TideCurvePoint], at date: Date) -> Double? {
        let sorted = points.sorted { $0.time < $1.time }
        guard !sorted.isEmpty else { return nil }

        if let exact = sorted.first(where: { abs($0.time.timeIntervalSince(date)) < 1 }) {
            return exact.heightFeet
        }

        if let before = sorted.last(where: { $0.time <= date }),
           let after = sorted.first(where: { $0.time >= date }) {
            let span = after.time.timeIntervalSince(before.time)
            guard span > 0 else { return before.heightFeet }
            let fraction = date.timeIntervalSince(before.time) / span
            return before.heightFeet + ((after.heightFeet - before.heightFeet) * fraction)
        }

        return sorted.min { lhs, rhs in
            abs(lhs.time.timeIntervalSince(date)) < abs(rhs.time.timeIntervalSince(date))
        }?.heightFeet
    }

    private static func tideState(from points: [TideCurvePoint], at date: Date) -> SmartFishingSetTideState {
        guard !points.isEmpty else { return .unknown }
        let beforeDate = date.addingTimeInterval(-10 * 60)
        let afterDate = date.addingTimeInterval(10 * 60)
        guard let before = interpolatedTideHeight(from: points, at: beforeDate),
              let after = interpolatedTideHeight(from: points, at: afterDate) else {
            return .unknown
        }

        let delta = after - before
        if abs(delta) < 0.03 { return .slack }
        return delta > 0 ? .flooding : .ebbing
    }

    private static func elapsedText(from start: Date, to end: Date) -> String {
        let totalSeconds = max(0, Int(end.timeIntervalSince(start).rounded()))
        if totalSeconds < 60 { return "\(totalSeconds)s" }
        let minutes = totalSeconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainderMinutes = minutes % 60
        if hours < 24 { return remainderMinutes == 0 ? "\(hours)h" : "\(hours)h\(remainderMinutes)m" }
        let days = hours / 24
        let remainderHours = hours % 24
        return remainderHours == 0 ? "\(days)d" : "\(days)d\(remainderHours)h"
    }

    private static func recordSetButtonElapsedText(from start: Date, to end: Date) -> String {
        let totalSeconds = max(0, Int(end.timeIntervalSince(start).rounded()))
        if totalSeconds < 60 { return "\(totalSeconds)s" }

        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes < 60 {
            return String(format: "%d:%02d", minutes, seconds)
        }

        let hours = minutes / 60
        let remainderMinutes = minutes % 60
        if hours < 24 {
            return String(format: "%dh%02dm", hours, remainderMinutes)
        }

        let days = hours / 24
        let remainderHours = hours % 24
        return remainderHours == 0 ? "\(days)d" : "\(days)d\(remainderHours)h"
    }

}


private struct SSTControlsSheetView: View {
    @Binding var isPresented: Bool
    @ObservedObject var availability: SeaSurfaceTemperatureAvailabilityStore

    let initialEnabled: Bool
    let initialOpacity: Double
    let initialSource: SeaSurfaceTemperatureSource
    let initialDateUTC: String
    let onApply: (_ enabled: Bool, _ opacity: Double, _ source: SeaSurfaceTemperatureSource, _ dateUTC: String) -> Void

    @State private var isEnabledDraft: Bool
    @State private var opacityDraft: Double
    @State private var sourceDraft: SeaSurfaceTemperatureSource
    @State private var dateUTCDraft: String
    @State private var displayDateDraft: Date

    init(
        isPresented: Binding<Bool>,
        availability: SeaSurfaceTemperatureAvailabilityStore,
        initialEnabled: Bool,
        initialOpacity: Double,
        initialSource: SeaSurfaceTemperatureSource,
        initialDateUTC: String,
        onApply: @escaping (_ enabled: Bool, _ opacity: Double, _ source: SeaSurfaceTemperatureSource, _ dateUTC: String) -> Void
    ) {
        self._isPresented = isPresented
        self.availability = availability
        self.initialEnabled = initialEnabled

        let clampedOpacity = min(max(initialOpacity, 0.15), 0.85)
        let latestAvailableUTC = availability.latestAvailableOrFallback(for: initialSource)
        let clampedDateUTC = SeaSurfaceTemperatureOverlay.clampedDateUTC(
            initialDateUTC,
            for: initialSource,
            latestAvailableUTC: latestAvailableUTC
        )

        self.initialOpacity = clampedOpacity
        self.initialSource = initialSource
        self.initialDateUTC = clampedDateUTC
        self.onApply = onApply

        _isEnabledDraft = State(initialValue: initialEnabled)
        _opacityDraft = State(initialValue: clampedOpacity)
        _sourceDraft = State(initialValue: initialSource)
        _dateUTCDraft = State(initialValue: clampedDateUTC)
        _displayDateDraft = State(
            initialValue: SeaSurfaceTemperatureOverlay.displayDate(
                forUTCDate: clampedDateUTC,
                source: initialSource,
                latestAvailableUTC: latestAvailableUTC
            )
        )
    }

    private var latestAvailableUTC: String {
        availability.latestAvailableOrFallback(for: sourceDraft)
    }

    private var dateRange: ClosedRange<Date> {
        SeaSurfaceTemperatureOverlay.displayDateRange(
            for: sourceDraft,
            latestAvailableUTC: latestAvailableUTC
        )
    }

    private var isAtLatestDate: Bool {
        dateUTCDraft == SeaSurfaceTemperatureOverlay.latestAllowedDateUTC(
            for: sourceDraft,
            latestAvailableUTC: latestAvailableUTC
        )
    }

    private var opacityBinding: Binding<Double> {
        Binding(
            get: { opacityDraft },
            set: { opacityDraft = min(max($0, 0.15), 0.85) }
        )
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { displayDateDraft },
            set: { newDate in
                let clampedUTC = SeaSurfaceTemperatureOverlay.utcDateString(
                    fromDisplayDate: newDate,
                    for: sourceDraft,
                    latestAvailableUTC: latestAvailableUTC
                )
                dateUTCDraft = clampedUTC
                displayDateDraft = SeaSurfaceTemperatureOverlay.displayDate(
                    forUTCDate: clampedUTC,
                    source: sourceDraft,
                    latestAvailableUTC: latestAvailableUTC
                )
            }
        )
    }

    private func setDateUTC(_ newValue: String) {
        let clampedUTC = SeaSurfaceTemperatureOverlay.clampedDateUTC(
            newValue,
            for: sourceDraft,
            latestAvailableUTC: latestAvailableUTC
        )
        dateUTCDraft = clampedUTC
        displayDateDraft = SeaSurfaceTemperatureOverlay.displayDate(
            forUTCDate: clampedUTC,
            source: sourceDraft,
            latestAvailableUTC: latestAvailableUTC
        )
    }

    private func shiftDate(by days: Int) {
        setDateUTC(
            SeaSurfaceTemperatureOverlay.shiftDateUTC(
                dateUTCDraft,
                byDays: days,
                for: sourceDraft,
                latestAvailableUTC: latestAvailableUTC
            )
        )
    }

    private func refreshForSource(_ newSource: SeaSurfaceTemperatureSource) {
        availability.refreshIfNeeded(for: newSource)
        let latestForSource = availability.latestAvailableOrFallback(for: newSource)
        let clampedUTC = SeaSurfaceTemperatureOverlay.clampedDateUTC(
            dateUTCDraft,
            for: newSource,
            latestAvailableUTC: latestForSource
        )
        sourceDraft = newSource
        dateUTCDraft = clampedUTC
        displayDateDraft = SeaSurfaceTemperatureOverlay.displayDate(
            forUTCDate: clampedUTC,
            source: newSource,
            latestAvailableUTC: latestForSource
        )
    }

    private func applyDraft() {
        let clampedOpacity = min(max(opacityDraft, 0.15), 0.85)
        let clampedDateUTC = SeaSurfaceTemperatureOverlay.clampedDateUTC(
            dateUTCDraft,
            for: sourceDraft,
            latestAvailableUTC: latestAvailableUTC
        )
        opacityDraft = clampedOpacity
        dateUTCDraft = clampedDateUTC
        onApply(isEnabledDraft, clampedOpacity, sourceDraft, clampedDateUTC)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Show selected layer", isOn: $isEnabledDraft)

                    Picker("Layer", selection: $sourceDraft) {
                        ForEach(SeaSurfaceTemperatureSource.selectableCases) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .onChange(of: sourceDraft) { newSource in
                        refreshForSource(newSource)
                    }

                    HStack {
                        Text("Latest available")
                        Spacer(minLength: 8)

                        if availability.isRefreshing(sourceDraft) {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Text(latestAvailableUTC)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        availability.refreshIfNeeded(for: sourceDraft, force: true)
                    } label: {
                        Label("Refresh latest available date", systemImage: "arrow.clockwise")
                    }

                    if let availabilityMessage = availability.lastErrorMessage(for: sourceDraft) {
                        Text(availabilityMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Date")
                            Spacer(minLength: 8)
                            Text(dateUTCDraft)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        DatePicker(
                            "",
                            selection: dateBinding,
                            in: dateRange,
                            displayedComponents: .date
                        )
                        .datePickerStyle(WheelDatePickerStyle())
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .clipped()
                    }

                    HStack(spacing: 12) {
                        Button("Latest") {
                            setDateUTC(
                                SeaSurfaceTemperatureOverlay.latestAllowedDateUTC(
                                    for: sourceDraft,
                                    latestAvailableUTC: latestAvailableUTC
                                )
                            )
                        }

                        Spacer(minLength: 0)

                        Button("-1 day") {
                            shiftDate(by: -1)
                        }

                        Button("+1 day") {
                            shiftDate(by: 1)
                        }
                        .disabled(isAtLatestDate)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Opacity")
                            Spacer(minLength: 0)
                            Text("\(Int((opacityDraft * 100).rounded()))%")
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: opacityBinding, in: 0.15...0.85)
                    }
                } footer: {
                    Text(sourceDraft.detail)
                }

                Section {
                    OceanLayersNoteView(
                        title: "GIBS MUR 1 km SST",
                        bodyText: "NASA’s GIBS browse layer for the GHRSST Level 4 JPL MUR Global Foundation SST analysis. It is a daily ~1 km SST field built from multiple satellite infrared and microwave observations plus in-situ data, and it is useful for spotting temperature breaks, plume edges, fronts, and day-to-day warming or cooling."
                    )

                    OceanLayersNoteView(
                        title: "SST anomaly",
                        bodyText: "Shows how much warmer or cooler the current MUR SST is than the MUR climatology. In this dataset, the anomaly is referenced to the day-of-year average from 2003–2014, so positive values are warmer than baseline and negative values are cooler."
                    )
                } header: {
                    Text("Notes")
                } footer: {
                    Text("Use Apply after browsing dates so the map only reloads once.")
                }
            }
            .navigationTitle("Ocean layers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        isPresented = false
                    } label: {
                        SatChartToolbarButtonLabel("Cancel")
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        applyDraft()
                        isPresented = false
                    } label: {
                        SatChartToolbarButtonLabel("Apply")
                    }
                }
            }
        }
        .task {
            availability.refreshIfNeeded(for: sourceDraft)
        }
        .onChange(of: latestAvailableUTC) { _ in
            setDateUTC(dateUTCDraft)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct OceanLayersNoteView: View {
    let title: String
    let bodyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))

            Text(bodyText)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

private extension SeaSurfaceTemperatureSource {
    var legendTitle: String {
        switch self {
        case .gibsMURHighDetail:
            return "SST °C"
        case .gibsMURSSTAnomaly:
            return "SST anomaly Δ °C"
        case .thermalFronts:
            return "Fronts K/km"
        case .chlorophyll:
            return "Chl-a mg/m³"
        case .seaSurfaceHeightAnomaly:
            return "SSH Δ m"
        }
    }

    var legendSubtitle: String? {
        switch self {
        case .gibsMURSSTAnomaly:
            return "Temp. vs 2003–2014 day-of-year avg"
        default:
            return nil
        }
    }

    var legendColors: [Color] {
        switch self {
        case .gibsMURHighDetail:
            return [
                Color(red: 0.38, green: 0.00, blue: 0.58),
                Color(red: 0.10, green: 0.18, blue: 0.86),
                Color(red: 0.00, green: 0.52, blue: 1.00),
                Color(red: 0.00, green: 0.80, blue: 0.92),
                Color(red: 0.00, green: 0.72, blue: 0.28),
                Color(red: 0.95, green: 0.90, blue: 0.10),
                Color(red: 0.98, green: 0.56, blue: 0.10),
                Color(red: 0.82, green: 0.06, blue: 0.10)
            ]
        case .gibsMURSSTAnomaly:
            return [
                Color(red: 0.05, green: 0.16, blue: 0.58),
                Color(red: 0.13, green: 0.43, blue: 0.94),
                Color.white,
                Color(red: 0.98, green: 0.72, blue: 0.16),
                Color(red: 0.78, green: 0.10, blue: 0.14)
            ]
        case .thermalFronts:
            return [
                Color(red: 0.03, green: 0.10, blue: 0.28),
                Color(red: 0.06, green: 0.35, blue: 0.76),
                Color(red: 0.00, green: 0.76, blue: 0.88),
                Color(red: 0.95, green: 0.90, blue: 0.12),
                Color(red: 0.85, green: 0.18, blue: 0.12)
            ]
        case .chlorophyll:
            return [
                Color(red: 0.18, green: 0.00, blue: 0.45),
                Color(red: 0.12, green: 0.20, blue: 0.82),
                Color(red: 0.00, green: 0.58, blue: 0.86),
                Color(red: 0.00, green: 0.72, blue: 0.34),
                Color(red: 0.92, green: 0.88, blue: 0.16),
                Color(red: 0.96, green: 0.47, blue: 0.08)
            ]
        case .seaSurfaceHeightAnomaly:
            return [
                Color(red: 0.18, green: 0.05, blue: 0.46),
                Color(red: 0.12, green: 0.39, blue: 0.92),
                Color.white,
                Color(red: 0.99, green: 0.72, blue: 0.19),
                Color(red: 0.76, green: 0.12, blue: 0.14)
            ]
        }
    }

    var legendTicks: [Double] {
        switch self {
        case .gibsMURHighDetail:
            return [0, 8, 16, 24, 32]
        case .gibsMURSSTAnomaly:
            return [-5, -2, 0, 2, 5]
        case .thermalFronts:
            return [0.00, 0.05, 0.10, 0.20, 0.40]
        case .chlorophyll:
            return [0.03, 0.10, 0.30, 1.0, 3.0, 10.0]
        case .seaSurfaceHeightAnomaly:
            return [-1.0, -0.5, 0.0, 0.5, 1.0]
        }
    }
}

private struct SSTLegendCard: View {
    @Environment(\.navigationReadoutBackgroundsVisible) private var showsBackgrounds
    let source: SeaSurfaceTemperatureSource
    let dateUTC: String
    var onExit: (() -> Void)? = nil
    var preferredWidth: CGFloat? = nil
    var preferredHeight: CGFloat? = nil

    private let defaultGradientWidth: CGFloat = 176

    private var usesFixedHeight: Bool {
        preferredHeight != nil
    }

    private var usesCompactFixedLayout: Bool {
        usesFixedHeight
    }

    private var gradientHeight: CGFloat {
        usesCompactFixedLayout ? 8 : 14
    }

    private var horizontalInset: CGFloat {
        usesCompactFixedLayout ? 8 : 12
    }

    private var verticalInset: CGFloat {
        usesCompactFixedLayout ? 4 : 10
    }

    private var contentSpacing: CGFloat {
        usesCompactFixedLayout ? 2 : 6
    }

    private var titleFont: Font {
        .system(size: usesCompactFixedLayout ? 11 : 13, weight: .bold, design: .rounded)
    }

    private var metadataFont: Font {
        .system(size: usesCompactFixedLayout ? 8 : 9.5, weight: .semibold, design: .monospaced)
    }

    private var subtitleFont: Font {
        .system(size: usesCompactFixedLayout ? 7.2 : 10, weight: .semibold, design: .rounded)
    }

    private var tickFont: Font {
        .system(size: usesCompactFixedLayout ? 7.4 : 9.4, weight: .semibold, design: .monospaced)
    }

    private var compactSourceLabel: String {
        source.shortLabel
    }

    private var contentWidth: CGFloat {
        if let preferredWidth {
            return max(150, preferredWidth - (horizontalInset * 2))
        }
        return defaultGradientWidth
    }

    var body: some View {
        Group {
            if usesCompactFixedLayout {
                compactBody
            } else {
                regularBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, horizontalInset)
        .padding(.vertical, verticalInset)
        .frame(width: preferredWidth, height: preferredHeight, alignment: .topLeading)
        .background(Color.black.opacity(showsBackgrounds ? 0.70 : 0))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(showsBackgrounds ? 0.12 : 0), lineWidth: 1)
        )
        .shadow(color: .black.opacity(showsBackgrounds ? 0.24 : 0), radius: 6, y: 3)
        .fixedSize(horizontal: preferredWidth == nil, vertical: preferredHeight == nil)
    }

    private var regularBody: some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(source.legendTitle)
                    .font(titleFont)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)

                Spacer(minLength: 4)

                Text("\(compactSourceLabel) • \(dateUTC)")
                    .font(metadataFont)
                    .foregroundColor(.white.opacity(showsBackgrounds ? 0.74 : 1))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }

            legendGradient

            if let legendSubtitle = source.legendSubtitle {
                Text(legendSubtitle)
                    .font(subtitleFont)
                    .foregroundColor(.white.opacity(showsBackgrounds ? 0.80 : 1))
                    .frame(width: contentWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            legendTicks

            if let onExit {
                HStack {
                    Spacer(minLength: 0)

                    Button(action: onExit) {
                        Text("Exit")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(SubtleHUDInlineButtonStyle(horizontalPadding: 6, verticalPadding: 2))
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(source.legendTitle)
                    .font(titleFont)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 4)

                Text("\(compactSourceLabel) • \(dateUTC)")
                    .font(metadataFont)
                    .foregroundColor(.white.opacity(showsBackgrounds ? 0.70 : 1))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                if let onExit {
                    Button(action: onExit) {
                        Text("Exit")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(SubtleHUDInlineButtonStyle(horizontalPadding: 5, verticalPadding: 1))
                }
            }

            legendGradient

            if let legendSubtitle = source.legendSubtitle {
                Text(legendSubtitle)
                    .font(subtitleFont)
                    .foregroundColor(.white.opacity(showsBackgrounds ? 0.80 : 1))
                    .frame(width: contentWidth, alignment: .leading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            legendTicks
        }
    }

    private var legendGradient: some View {
        LinearGradient(gradient: Gradient(colors: source.legendColors), startPoint: .leading, endPoint: .trailing)
            .frame(width: contentWidth, height: gradientHeight)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.white.opacity(0.24), lineWidth: 1)
            )
    }

    private var legendTicks: some View {
        HStack(spacing: 0) {
            ForEach(Array(source.legendTicks.enumerated()), id: \.offset) { _, tick in
                Text(Self.tickLabel(for: tick, source: source))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(width: contentWidth)
        .font(tickFont)
        .foregroundColor(.white.opacity(showsBackgrounds ? 0.76 : 1))
    }

    private static func tickLabel(for tick: Double, source: SeaSurfaceTemperatureSource) -> String {
        switch source {
        case .chlorophyll:
            if tick >= 1 {
                if tick.rounded(.towardZero) == tick {
                    return String(Int(tick))
                }
                return String(format: "%.1f", tick)
            }
            return String(format: "%.2f", tick)
        case .thermalFronts:
            return String(format: "%.2f", tick)
        case .gibsMURSSTAnomaly, .seaSurfaceHeightAnomaly:
            if tick.rounded(.towardZero) == tick {
                return String(Int(tick))
            }
            return String(format: "%.1f", tick)
        case .gibsMURHighDetail:
            if tick.rounded(.towardZero) == tick {
                return String(Int(tick))
            }
            return String(format: "%.1f", tick)
        }
    }
}


// MARK: - Menu Tabs

enum MenuTab: Hashable {
    case menu
    case howToUse
    case waypoints
    case radioGroup
    case deepResearch
    case logbook
    case tidesWeather
    case offlineMaps
    case announcements
    case fisheryResources
    case settings
}

private extension Notification.Name {
    static let menuChildPageVisibilityDidChange = Notification.Name("menuChildPageVisibilityDidChange")
}

struct AppMenuTabsView: View {
    @Binding var waypoints: [Waypoint]
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var pinSettings: RadioGroupPinSettings
    @EnvironmentObject var radioGroup: RadioGroupStore
    @State private var selection: MenuTab = .menu
    @State private var menuChildPageDepth: Int = 0

    init(waypoints: Binding<[Waypoint]>) {
        self._waypoints = waypoints
        BBMenuAppearance.applyAll()
    }

    var body: some View {
        ZStack {
            bbMenuBlue_MV.ignoresSafeArea()

            HostingBackgroundFixer(color: bbMenuBlueUIColor_MV)
                .frame(width: 0, height: 0)

            currentPageView
        }
        .tint(.white)
        .overlay(alignment: .topLeading) {
            if selection != .deepResearch && menuChildPageDepth == 0 {
                Button {
                    selection = .menu
                } label: {
                    Image(systemName: "line.3.horizontal.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white, Color.white.opacity(0.18))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .opacity(selection == .menu ? 0.65 : 1.0)
                }
                .buttonStyle(SatChartPressFeedbackButtonStyle())
                .accessibilityLabel("Menu")
                .padding(.top, 4)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white, Color.white.opacity(0.18))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .buttonStyle(SatChartPressFeedbackButtonStyle())
            .accessibilityLabel("Exit menu")
            .padding(.top, 4)
        }
        .onAppear {
            selection = .menu
            menuChildPageDepth = 0
            BBMenuAppearance.applyAll()
        }
        .onChange(of: selection) { _ in
            menuChildPageDepth = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuChildPageVisibilityDidChange)) { note in
            guard let active = note.object as? Bool else { return }
            if active {
                menuChildPageDepth += 1
            } else {
                menuChildPageDepth = max(0, menuChildPageDepth - 1)
            }
        }
    }

    @ViewBuilder
    private var currentPageView: some View {
        switch selection {
        case .menu:
            MenuHomeTab(
                selection: $selection,
                onBackToNavigation: { dismiss() }
            )
            .environmentObject(pinSettings)

        case .howToUse:
            ZStack {
                bbMenuBlue_MV.ignoresSafeArea()
                HostingBackgroundFixer(color: bbMenuBlueUIColor_MV)
                    .frame(width: 0, height: 0)

                NavigationStack {
                    HowToUseSatChartPageView()
                }
            }

        case .waypoints:
            ZStack {
                bbMenuBlue_MV.ignoresSafeArea()
                HostingBackgroundFixer(color: bbMenuBlueUIColor_MV)
                    .frame(width: 0, height: 0)

                NavigationStack {
                    WaypointsView(waypoints: $waypoints)
                        .environmentObject(radioGroup)
                }
            }

        case .radioGroup:
            ZStack {
                bbMenuBlue_MV.ignoresSafeArea()
                HostingBackgroundFixer(color: bbMenuBlueUIColor_MV)
                    .frame(width: 0, height: 0)

                NavigationStack {
                    RadioGroupView()
                        .environmentObject(pinSettings)
                        .environmentObject(radioGroup)
                }
            }

        case .deepResearch:
            ZStack {
                bbMenuBlue_MV.ignoresSafeArea()
                HostingBackgroundFixer(color: bbMenuBlueUIColor_MV)
                    .frame(width: 0, height: 0)

                NavigationStack {
                    DeepResearchPageView(
                        showsMenuButton: menuChildPageDepth == 0,
                        onMenuTap: { selection = .menu }
                    )
                }
            }

        case .logbook:
            ZStack {
                bbMenuBlue_MV.ignoresSafeArea()
                HostingBackgroundFixer(color: bbMenuBlueUIColor_MV)
                    .frame(width: 0, height: 0)

                NavigationStack {
                    LogbookPageView()
                }
            }

        case .tidesWeather:
            ZStack {
                bbMenuBlue_MV.ignoresSafeArea()
                HostingBackgroundFixer(color: bbMenuBlueUIColor_MV)
                    .frame(width: 0, height: 0)

                NavigationStack {
                    TidesWeatherPageView()
                }
            }

        case .offlineMaps:
            ZStack {
                bbMenuBlue_MV.ignoresSafeArea()
                HostingBackgroundFixer(color: bbMenuBlueUIColor_MV)
                    .frame(width: 0, height: 0)

                NavigationStack {
                    OfflineMapsMenuPageView()
                }
            }

        case .announcements:
            ZStack {
                bbMenuBlue_MV.ignoresSafeArea()
                HostingBackgroundFixer(color: bbMenuBlueUIColor_MV)
                    .frame(width: 0, height: 0)

                NavigationStack {
                    FisheryAnnouncementsView()
                }
            }

        case .fisheryResources:
            ZStack {
                bbMenuBlue_MV.ignoresSafeArea()
                HostingBackgroundFixer(color: bbMenuBlueUIColor_MV)
                    .frame(width: 0, height: 0)

                NavigationStack {
                    FisheryResourcesDownloadsView()
                }
            }

        case .settings:
            ZStack {
                bbMenuBlue_MV.ignoresSafeArea()
                HostingBackgroundFixer(color: bbMenuBlueUIColor_MV)
                    .frame(width: 0, height: 0)

                NavigationStack {
                    SettingsPageView()
                        .environmentObject(pinSettings)
                        .environmentObject(radioGroup)
                }
            }
        }
    }
}

struct MenuHomeTab: View {
    @Binding var selection: MenuTab
    let onBackToNavigation: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                bbMenuBlue_MV.ignoresSafeArea()
                HostingBackgroundFixer(color: bbMenuBlueUIColor_MV)
                    .frame(width: 0, height: 0)

                LinearGradient(
                    colors: [menuPageBackgroundTop_MV, menuPageBackgroundBottom_MV],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: [.top, .leading, .trailing])

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 12) {
                        menuButton(
                            title: "How to Use SatChart",
                            systemImage: "questionmark.circle"
                        ) {
                            selection = .howToUse
                        }

                        menuButton(
                            title: "Waypoints",
                            systemImage: "list.bullet"
                        ) {
                            selection = .waypoints
                        }

                        menuButton(
                            title: "Radio Group",
                            systemImage: "antenna.radiowaves.left.and.right"
                        ) {
                            selection = .radioGroup
                        }

                        menuButton(
                            title: "Deep Research",
                            systemImage: "chart.bar.doc.horizontal"
                        ) {
                            selection = .deepResearch
                        }

                        menuButton(
                            title: "Logbook",
                            systemImage: "book.closed"
                        ) {
                            selection = .logbook
                        }

                        menuButton(
                            title: "Tides & Weather",
                            systemImage: "water.waves"
                        ) {
                            selection = .tidesWeather
                        }

                        menuButton(
                            title: "Download Offline Maps",
                            systemImage: "arrow.down.circle"
                        ) {
                            selection = .offlineMaps
                        }

                        menuButton(
                            title: "Announcements",
                            systemImage: "megaphone"
                        ) {
                            selection = .announcements
                        }

                        menuButton(
                            title: "Fishery Resources & Downloads",
                            systemImage: "folder"
                        ) {
                            selection = .fisheryResources
                        }

                        menuButton(
                            title: "Settings",
                            systemImage: "wrench.adjustable"
                        ) {
                            selection = .settings
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 0)
                }
                .background(Color.clear)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .toolbarBackground(bbMenuBlue_MV, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Menu")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .underline()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                BBMenuAppearance.applyNavBar()
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer(minLength: 0)

                    Button(action: onBackToNavigation) {
                        Text("Back to Navigation")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(SubtleHUDInlineButtonStyle(horizontalPadding: 10, verticalPadding: 6))

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 10)
            }
        }
    }

    private func menuButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))

                Text(title)
                    .font(.system(size: 14, weight: .semibold))

                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .foregroundColor(.white)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
    }
}

// MARK: - Deep Research wrappers

struct DeepResearchPageView: View {
    let showsMenuButton: Bool
    let onMenuTap: () -> Void

    var body: some View {
        ZStack {
            bbMenuBlue_MV.ignoresSafeArea()
            HostingBackgroundFixer(color: bbMenuBlueUIColor_MV)
                .frame(width: 0, height: 0)

            DeepResearchHomeView()
        }
        .navigationTitle("Deep Research")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(bbMenuBlue_MV, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if showsMenuButton {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onMenuTap) {
                        Image(systemName: "line.3.horizontal.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white, Color.white.opacity(0.18))
                    }
                    .buttonStyle(SatChartPressFeedbackButtonStyle())
                    .accessibilityLabel("Menu")
                }
            }
        }
        .onAppear { BBMenuAppearance.applyNavBar() }
    }
}

struct LogbookPageView: View {
    var body: some View {
        ZStack {
            bbMenuBlue_MV.ignoresSafeArea()
            HostingBackgroundFixer(color: bbMenuBlueUIColor_MV)
                .frame(width: 0, height: 0)

            SmartLogbookView()
        }
    }
}

struct OfflineMapsMenuPageView: View {
    var body: some View {
        ZStack {
            bbMenuBlue_MV.ignoresSafeArea()
            HostingBackgroundFixer(color: bbMenuBlueUIColor_MV)
                .frame(width: 0, height: 0)

            OfflineMapsView()
        }
        .navigationTitle("Download Offline Maps")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(bbMenuBlue_MV, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Download Offline Maps")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .underline()
            }
        }
        .onAppear { BBMenuAppearance.applyNavBar() }
    }
}
struct MenuChildPageChromeModifier: ViewModifier {
    @State private var didPostVisible = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !didPostVisible else { return }
                didPostVisible = true
                NotificationCenter.default.post(name: .menuChildPageVisibilityDidChange, object: true)
            }
            .onDisappear {
                guard didPostVisible else { return }
                didPostVisible = false
                NotificationCenter.default.post(name: .menuChildPageVisibilityDidChange, object: false)
            }
    }
}

extension View {
    func menuChildPageChrome() -> some View {
        modifier(MenuChildPageChromeModifier())
    }

    func settingsChildPageChrome() -> some View {
        menuChildPageChrome()
    }
}

struct SettingsDownloadsPageView: View {
    var body: some View {
        OfflineMapsView()
    }
}

private enum SettingsAppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    static var versionBuild: String {
        "Version \(version) (\(build))"
    }

    static var viewedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date())
    }
}

private struct SettingsDetailPageScaffold<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            bbMenuBlue_MV.ignoresSafeArea()
            HostingBackgroundFixer(color: bbMenuBlueUIColor_MV)
                .frame(width: 0, height: 0)

            LinearGradient(
                colors: [menuPageBackgroundTop_MV, menuPageBackgroundBottom_MV],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: [.top, .leading, .trailing])

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    content()
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 18)
            }
            .background(Color.clear)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(bbMenuBlue_MV, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .underline()
            }
        }
        .onAppear { BBMenuAppearance.applyNavBar() }
    }
}

private struct SettingsInfoCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .underline(true, color: Color.white.opacity(0.55))

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

private struct SettingsBodyText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(0.88))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsBulletList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.88))
                    Text(item)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct HowToUseSatChartPageView: View {
    private static let navigationButtons: [HowToUseNavigationButton] = [
        HowToUseNavigationButton(title: "Follow Location", detail: "Keeps the map following your current position. Tap again to stop following while you pan around.", preview: .symbol("location", .white)),
        HowToUseNavigationButton(title: "Recenter Map", detail: "Recenters the map on your current location without changing the follow setting.", preview: .symbol("scope", .white)),
        HowToUseNavigationButton(title: "Basemap", detail: "Switches between available basemaps such as satellite, NOAA chart, topo, and downloaded district map layers.", preview: .symbol("map.fill", .white)),
        HowToUseNavigationButton(title: "Main Menu", detail: "Opens the SatChart menu for Waypoints, Radio Group, Deep Research, Logbook, Tides & Weather, offline maps, settings, and this guide.", preview: .symbol("line.3.horizontal", .white)),
        HowToUseNavigationButton(title: "Ocean Layers", detail: "Opens sea-surface temperature and ocean-layer controls. Enabled ocean layers can show an on-map legend.", preview: .symbol("square.3.layers.3d.top.filled", .cyan)),
        HowToUseNavigationButton(title: "Zoom In", detail: "Zooms the map in one step.", preview: .symbol("plus", .white)),
        HowToUseNavigationButton(title: "Zoom Out", detail: "Zooms the map out one step.", preview: .symbol("minus", .white)),
        HowToUseNavigationButton(title: "KDLG", detail: "Starts or stops the KDLG audio stream from the navigation HUD.", preview: .text("KDLG")),
        HowToUseNavigationButton(title: "Wind", detail: "Opens Tides & Weather from the compact wind readout. Wind icons color up as forecast speeds increase.", preview: .symbol("wind", .white)),
        HowToUseNavigationButton(title: "Share Live", detail: "Shares your live location with the active Radio Group after confirmation. Tap again to stop sharing.", preview: .symbol("antenna.radiowaves.left.and.right", .green)),
        HowToUseNavigationButton(title: "Send Location Pin", detail: "Sends a one-time current-location pin to the active Radio Group after confirmation.", preview: .symbol("dot.radiowaves.left.and.right", .white)),
        HowToUseNavigationButton(title: "Record Set", detail: "Starts a fishing set timer. Tap again when the set is complete to save set details to the Logbook.", preview: .recordSet),
        HowToUseNavigationButton(title: "Fish Ticket OCR", detail: "Opens the camera flow for fish ticket capture. Ticket photos and extracted fields stay on the device unless you export or share them.", preview: .symbol("camera.fill", Color(uiColor: UIColor(red: 0.95, green: 0.78, blue: 0.18, alpha: 1.0)))),
        HowToUseNavigationButton(title: "Create Waypoint", detail: "Drops a waypoint at the map cursor/current target. Waypoints can be renamed, exported, or shared to a Radio Group.", preview: .waypoint),
        HowToUseNavigationButton(title: "Map Version", detail: "Tap Map v# to compare available versions in Districts Online or downloaded versions in Districts Offline.", preview: .text("Map v2"))
    ]

    var body: some View {
        SettingsDetailPageScaffold(title: "How to Use SatChart") {
            SettingsInfoCard(title: "Navigation Buttons") {
                VStack(spacing: 10) {
                    ForEach(Self.navigationButtons) { button in
                        HowToUseNavigationButtonRow(button: button)
                    }
                }
            }

            SettingsInfoCard(title: "Radio Groups") {
                SettingsBodyText(text: "Radio Groups let boats share live location, one-time location pins, and waypoints with a private group.")
                SettingsBulletList(items: [
                    "Open Menu > Radio Group to create a group or join one with an invite code.",
                    "The person who creates a Radio Group is the founder/admin. Admins review and approve new member requests before those users can join.",
                    "A new member enters the invite code and sends a join request. The request remains pending until an admin approves or rejects it.",
                    "Choose an active Radio Group before using Share Live, Send Location Pin, or shared waypoint features.",
                    "Live location sharing is voluntary. Turn it on when you want the group to see you, and turn it off when you are done."
                ])
            }

            SettingsInfoCard(title: "Offline Maps") {
                SettingsBulletList(items: [
                    "Open Menu > Download Offline Maps while you have a reliable connection.",
                    "Download the district map packs you expect to need before leaving service.",
                    "Use the basemap button on the navigation screen to switch to downloaded/offline layers.",
                    "Tap Map v# to cycle published versions in Districts Online without downloading. In Districts Offline, it cycles your downloaded versions.",
                    "Offline maps are planning and situational-awareness layers. Verify navigation decisions with official charts and onboard equipment."
                ])
            }

            SettingsInfoCard(title: "Logbook and Fish Tickets") {
                SettingsBulletList(items: [
                    "Use Record Set on the navigation screen to capture set timing, location, tide context, and notes.",
                    "Use the Fish Ticket OCR camera to create delivery cards from fish ticket photos. Review extracted fields before relying on them.",
                    "Delivery cards, set records, tender entries, notes, and fish ticket data are stored on device unless you export or share them.",
                    "Use the Logbook page to review deliveries, attach tally sheets, edit fields, and export logbook records."
                ])
            }

            SettingsInfoCard(title: "Waypoints") {
                SettingsBulletList(items: [
                    "Create waypoints from the navigation screen or manage them from Menu > Waypoints.",
                    "Rename waypoints so they are useful on the water.",
                    "Share selected waypoints with the active Radio Group or export them as GPX when needed.",
                    "Received Radio Group waypoints can be hidden locally without deleting them for other group members."
                ])
            }

            SettingsInfoCard(title: "Tides, Weather, and Ocean Context") {
                SettingsBulletList(items: [
                    "Open Tides & Weather from the menu or from the Wind readout to review nearby tide and weather context.",
                    "The navigation HUD can show tide, wind, speed, location, boundary distance, and scale-bar readouts.",
                    "Ocean layers can add sea-surface temperature or related imagery when available."
                ])
            }

            SettingsInfoCard(title: "Deep Research and Fishery Data") {
                SettingsBulletList(items: [
                    "Deep Research provides historical Bristol Bay charts, tables, rankings, and derived metrics for comparison and planning.",
                    "Menu > Fishery Resources & Downloads links to source/download status for fishery resources.",
                    "Some SatChart values are derived or estimated. Treat them as planning context, not official management determinations."
                ])
            }

            SettingsInfoCard(title: "Customize the Navigation Screen") {
                SettingsBodyText(text: "Open Menu > Settings > Screen Layout & Options to show or hide navigation buttons, HUD readouts, ocean legends, the map version selector, and other on-screen controls.")
            }
        }
    }
}

private struct HowToUseNavigationButton: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let preview: HowToUseNavigationButtonPreview
}

private enum HowToUseNavigationButtonPreview {
    case symbol(String, Color)
    case text(String)
    case recordSet
    case waypoint
}

private struct HowToUseNavigationButtonRow: View {
    let button: HowToUseNavigationButton

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            preview

            VStack(alignment: .leading, spacing: 4) {
                Text(button.title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text(button.detail)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var preview: some View {
        switch button.preview {
        case .symbol(let systemName, let color):
            helpButtonShell {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundColor(color)
            }
        case .text(let text):
            helpButtonShell {
                Text(text)
                    .font(.system(size: text.count > 4 ? 11 : 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
            }
        case .recordSet:
            helpButtonShell {
                VStack(spacing: 0) {
                    Text("1")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                    Image(systemName: "timer.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.orange)
                }
            }
        case .waypoint:
            helpButtonShell {
                ZStack {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.orange)
                        .offset(y: -6)
                }
            }
        }
    }

    private func helpButtonShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: 48, height: 48)
            .background(scSurface.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
    }
}

private struct SettingsActionRow: View {
    let title: String
    let detail: String
    var systemImage: String = "info.circle"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white.opacity(0.88))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(detail)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.76))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SettingsExternalLinkRow: View {
    let title: String
    let urlString: String

    var body: some View {
        if let url = SatChartReleaseConfiguration.validURL(from: urlString) {
            Link(destination: url) {
                rowContent(detail: url.absoluteString, image: "arrow.up.right.square")
            }
            .buttonStyle(SatChartPressFeedbackButtonStyle())
        } else {
            rowContent(detail: "Link unavailable. Contact support for assistance.", image: "exclamationmark.triangle.fill")
        }
    }

    private func rowContent(detail: String, image: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: image)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white.opacity(0.88))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(detail)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.76))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SettingsWarningCard: View {
    let title: String
    let warnings: [String]

    var body: some View {
        if !warnings.isEmpty {
            SettingsInfoCard(title: title) {
                SettingsBulletList(items: warnings)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.yellow.opacity(0.35), lineWidth: 1)
            )
        }
    }
}

private struct SettingsStatusRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.76))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SettingsAboutPageView: View {
    var body: some View {
        SettingsDetailPageScaffold(title: "About SatChart") {
            SettingsInfoCard(title: "About SatChart") {
                SettingsBodyText(text: "SatChart is a Bristol Bay fishing and situational-awareness app built for on-the-water planning, fishing operations, offline map access, tide and weather review, waypoints, Radio Group coordination, logbook records, and historical fishery analysis.")
                SettingsBodyText(text: "SatChart combines navigation-map tools, waypoints, pins, distance readouts, offline map packs, Radio Group location and waypoint sharing, tides, weather, marine observations, ocean-layer context, fishing logbook tools, and Deep Research charts and tables.")
                SettingsBodyText(text: "SatChart is designed to help users organize information and make better-informed decisions. It is not a substitute for official navigation equipment, official nautical charts, official weather warnings, official fishery announcements, agency emergency orders, or the judgment of the operator.")
                SettingsBodyText(text: "Always verify important information with official sources, onboard instruments, appropriate paper or electronic charts, notices to mariners, and applicable Alaska Department of Fish and Game communications before making navigation, weather, safety, fishing, or business decisions.")
            }
            SettingsInfoCard(title: "App") {
                SettingsStatusRow(title: "App version", value: SettingsAppInfo.version)
                SettingsStatusRow(title: "Build number", value: SettingsAppInfo.build)
                SettingsExternalLinkRow(title: "Website", urlString: SatChartReleaseConfiguration.websiteURLString)
                SettingsExternalLinkRow(title: "Privacy Policy", urlString: SatChartReleaseConfiguration.privacyPolicyURLString)
                SettingsExternalLinkRow(title: "Terms of Use", urlString: SatChartReleaseConfiguration.termsOfUseURLString)
                SettingsExternalLinkRow(title: "Data Collection", urlString: SatChartReleaseConfiguration.dataCollectionURLString)
                SettingsStatusRow(title: "Support email", value: SatChartReleaseConfiguration.supportEmail)
                SettingsExternalLinkRow(title: "Support website", urlString: SatChartReleaseConfiguration.supportWebsiteURLString)
            }
        }
    }
}

private struct SettingsSafetyUseNoticePageView: View {
    var body: some View {
        SettingsDetailPageScaffold(title: "Safety & Use Notice") {
            SettingsInfoCard(title: "Safety & Use Notice") {
                SettingsBodyText(text: "SatChart is an informational planning and situational-awareness tool. It is not an official chart plotter, ECDIS, official nautical chart, official navigation system, official weather warning source, official tide or current table, official fishery-management decision product, or emergency communication system.")
                SettingsBodyText(text: "Maps, boundaries, satellite layers, offline packs, tides, weather, ocean imagery, fishery reports, derived metrics, Radio Group pins, live locations, waypoints, and logbook values may be delayed, cached, estimated, interpolated, incomplete, inaccurate, unavailable, or corrected after publication.")
                SettingsBodyText(text: "You are responsible for safe navigation, safe vessel operation, compliance with law, and verification of important information. Use SatChart as one reference among many, not as the sole source for navigation, weather, safety, fishing, legal, or financial decisions.")
                SettingsBulletList(items: [
                    "Verify navigation with official charts and onboard equipment.",
                    "Verify weather and marine hazards with official NOAA/NWS sources.",
                    "Verify fishery openings, closures, emergency orders, and district/section rules with ADF&G.",
                    "Do not rely on Radio Group live pins for emergency response or rescue.",
                    "Do not rely on OCR/logbook outputs until reviewed and corrected by the user."
                ])
                SettingsExternalLinkRow(title: "Open Safety Notice", urlString: SatChartReleaseConfiguration.safetyURLString)
            }
        }
    }
}

private struct SettingsDataStatusPageView: View {
    @StateObject private var fisheryResources = FisheryResourceCatalogStore.shared
    private let fileManager = FileManager.default

    var body: some View {
        SettingsDetailPageScaffold(title: "Data Status") {
            SettingsInfoCard(title: "Data Freshness") {
                SettingsBodyText(text: "This page is the production home for live source freshness, last-fetched timestamps, provider warnings, and offline-pack status. SatChart does not label data current unless a source-specific timestamp or stored fetch record supports that claim.")
                SettingsStatusRow(title: "Viewed", value: SettingsAppInfo.viewedDate)
                SettingsStatusRow(title: "App", value: SettingsAppInfo.versionBuild)
            }
            SettingsInfoCard(title: "Local Status") {
                ForEach(rows, id: \.title) { row in
                    SettingsStatusRow(title: row.title, value: row.value)
                }
            }
            SettingsInfoCard(title: "Fishery Resources") {
                SettingsStatusRow(title: "Catalog source", value: fisheryResources.loadedSource.title)
                SettingsStatusRow(title: "Resources loaded", value: "\(fisheryResources.resourceCount)")
                SettingsStatusRow(title: "Latest fetch", value: latestFisheryFetchStatus)
                if let errorMessage = fisheryResources.errorMessage {
                    SettingsBodyText(text: errorMessage)
                }
            }
        }
        .task {
            await fisheryResources.loadIfNeeded()
        }
    }

    private var rows: [(title: String, value: String)] {
        [
            ("Offline database", offlineDatabaseStatus),
            ("Offline map packs", "Status shown in Offline Maps"),
            ("Tides / NOAA CO-OPS", "Available in Tides & Weather"),
            ("Weather / NOAA/NWS/NDBC", "Available in Tides & Weather"),
            ("Ocean/SST layers", "Available on the map when enabled"),
            ("Fishery reports and announcements", fisheryResources.dataStatusSummary),
            ("Deep Research/offline historical database", offlineDatabaseStatus)
        ]
    }

    private var latestFisheryFetchStatus: String {
        if fisheryResources.isLoading {
            return "Loading..."
        }
        guard let latestFetchedAt = fisheryResources.latestFetchedAt else {
            return fisheryResources.loadedSource == .bundledFallback ? "Using bundled fallback JSON" : "No fetch timestamp"
        }
        return FisheryResourceCatalogStore.shortDateFormatter.string(from: latestFetchedAt)
    }

    private var offlineDatabaseStatus: String {
        if let bundledURL = OfflineDatabaseResource.bundledSQLiteURL() {
            return "Bundled resource: \(bundledURL.lastPathComponent)"
        }

        guard let url = try? OfflinePaths.offlineSQLiteURL() else { return "Path unavailable" }
        return fileManager.fileExists(atPath: url.path) ? "Fallback copy: \(url.lastPathComponent)" : "Not installed"
    }
}

private struct SettingsModelsDerivedMetricsPageView: View {
    var body: some View {
        SettingsDetailPageScaffold(title: "Models & Derived Metrics") {
            SettingsInfoCard(title: "Models & Derived Metrics") {
                SettingsBodyText(text: "SatChart includes charts, tables, dashboard fields, and logbook smart fields that may use derived metrics, estimates, interpolations, allocation adjustments, and app-calculated values. These values are provided for planning, comparison, and review only. They are not official agency values and should not be treated as fishery-management determinations.")
                SettingsBodyText(text: "Some values are direct observed values. Others are calculated by SatChart. Asterisks, dashed chart lines, notes, captions, or labels may indicate values that are estimated, modeled, allocation-adjusted, interpolated, carried forward, or otherwise derived.")
            }
            SettingsInfoCard(title: "Metric Notes") {
                SettingsBulletList(items: [
                    "Drift Boats / Registration: Observed registration is used when available. When unavailable, SatChart may estimate drift boats using available operational signals such as drift hours, deliveries, sockeye harvest, recent observed registration, and district-specific settings.",
                    "Drift Boat-Hours: Calculated from drift boats multiplied by drift open hours when both inputs are available or estimated.",
                    "Sockeye per Drift Boat - Daily: A daily efficiency metric based on drift-adjusted sockeye harvest divided by drift boats.",
                    "Sockeye per Drift Boat - Cumulative: A to-date efficiency index built from daily sockeye-per-drift-boat values. It is for trend review, not official vessel accounting.",
                    "Sockeye per Boat-Hour: Calculated from drift-adjusted sockeye harvest divided by estimated or observed drift boat-hours.",
                    "Escapement Metrics: District escapement may combine one or more reporting rivers. River coverage and operating status can vary by date, year, and district.",
                    "Tides and Weather Values: Tide and weather displays may include predictions, observations, nearby-station selection, interpolated curve points, forecast periods, and marine observations.",
                    "OCR and Logbook Smart Fields: OCR extraction can be wrong. Users must review and correct extracted values before relying on them.",
                    "Limitations: Missing records, delayed reports, district-specific reporting practices, confidential data handling, late-season gaps, provider outages, and source corrections can affect displayed values.",
                    "Not Official: No derived metric, estimate, chart, table, ranking, model output, or OCR output in SatChart is an official ADF&G, NOAA, NASA, NWS, NDBC, Copernicus, FRI, or other agency product unless explicitly stated by that source."
                ])
            }
        }
    }
}

private struct SettingsPrivacyPolicyPageView: View {
    var body: some View {
        SettingsDetailPageScaffold(title: "Privacy Policy") {
            SettingsInfoCard(title: "Privacy Policy") {
                SettingsBodyText(text: "Effective date: \(SatChartReleaseConfiguration.legalEffectiveDate)")
                SettingsBodyText(text: "This Privacy Policy explains how SatChart handles information when you use the app.")
                SettingsExternalLinkRow(title: "Open Privacy Policy", urlString: SatChartReleaseConfiguration.privacyPolicyURLString)
            }
            SettingsInfoCard(title: "Information SatChart May Process") {
                SettingsBulletList(items: [
                    "Location data: Used for map position, navigation display, waypoints, set recording, tide/weather lookup, and Radio Group live sharing when enabled.",
                    "Radio Group data: Group IDs, invite/join status, member display names, vessel names, pins, shared waypoints, live-location updates, and timestamps may be stored or transmitted through backend services.",
                    "Waypoints and map data: User-created waypoints, notes, coordinates, hidden received waypoints, and offline/cached map data may be stored locally and/or synced when explicitly shared.",
                    "Logbook data: Sets, deliveries, tender purchases, notes, fish ticket fields, tally rows, receipt/fish-ticket images, OCR outputs, and related timestamps may be stored on device.",
                    "Photos/OCR: Images captured for fish tickets, tally sheets, and receipts may be processed to extract text. OCR can be inaccurate and should be reviewed.",
                    "Device/app data: App version, build number, settings, cache state, diagnostics, and support information may be used to operate and improve the app.",
                    "Third-party services: SatChart may use services such as Firebase/Firestore, NOAA, NWS, NDBC, NOAA CO-OPS, NASA, map tile providers, and other data providers depending on enabled features."
                ])
            }
            SettingsInfoCard(title: "How Information Is Used") {
                SettingsBulletList(items: [
                    "Provide navigation and situational-awareness features.",
                    "Store and display user-created records.",
                    "Share pins, waypoints, and live location within Radio Groups when the user chooses to do so.",
                    "Load maps, tides, weather, ocean layers, reports, and historical datasets.",
                    "Troubleshoot, support, secure, and improve the app."
                ])
            }
            SettingsInfoCard(title: "Local, Cloud, Choices, Retention") {
                SettingsBodyText(text: "Some data stays on the device. Shared Radio Group data and any cloud-enabled/account features may be transmitted to backend services. Users should assume shared pins, live locations, shared waypoints, group membership, and cloud/account data can be accessible to authorized group members and service infrastructure.")
                SettingsBulletList(items: [
                    "Users can control location permission in iOS Settings.",
                    "Users can choose whether to share live location.",
                    "Users can stop live sharing.",
                    "Users can delete local data and request deletion/export of cloud data through Manage My Data or support.",
                    "Account deletion can be started from My Account or Manage My Data."
                ])
                SettingsBodyText(text: "Some cloud cleanup may be completed through backend support workflow. Shared Radio Group content may not be removed immediately.")
                SettingsBodyText(text: "SatChart is intended for commercial fishing and maritime users and is not designed for children.")
                SettingsStatusRow(title: "Support email", value: SatChartReleaseConfiguration.supportEmail)
                SettingsExternalLinkRow(title: "Support website", urlString: SatChartReleaseConfiguration.supportWebsiteURLString)
            }
        }
    }
}

private struct SettingsTermsOfUsePageView: View {
    private let sections: [(String, String)] = [
        ("1. Informational use only", "SatChart is an informational planning and situational-awareness tool. It is not a chart plotter, ECDIS, official nautical chart, official navigation system, official weather warning source, official tide or current table, official fishery-management decision product, emergency alert system, or replacement for operator judgment."),
        ("2. No substitute for official sources", "SatChart may display or summarize maps, tides, weather, ocean imagery, fishery information, historical data, derived metrics, and user-created records. This information may be delayed, cached, estimated, interpolated, incomplete, inaccurate, corrected after publication, unavailable, or affected by internet/device limitations. Verify critical information with official sources."),
        ("3. Maps, charts, and location", "Map layers, offline packs, satellite imagery, NOAA chart layers, basemaps, waypoints, pins, location readouts, and boundaries are for reference only. They may contain errors, omissions, scale limits, outdated information, or display differences caused by GPS accuracy, projection, zoom level, offline coverage, or provider availability."),
        ("4. Tides, weather, ocean, and environmental data", "Tide predictions, tide curves, observed water levels, weather forecasts, marine observations, ocean imagery, sea-surface-temperature layers, anomaly layers, and related environmental data may come from third-party services. These services can change, delay, correct, or discontinue data at any time."),
        ("5. Fishery data and derived metrics", "SatChart may display public fishery data, historical records, modeled values, estimated values, derived metrics, rankings, charts, and tables. These are for planning and analysis only and are not official fishery-management determinations."),
        ("6. Radio Groups and live location sharing", "Users are responsible for choosing when to share location and with whom. Do not share another person's location or sensitive information without permission. Do not use Radio Group features to harass, track, threaten, impersonate, interfere with, or endanger others. Live location and shared data may be delayed, fail to transmit, fail to update, or remain visible longer than expected because of connectivity, device settings, server behavior, cache behavior, or app limitations."),
        ("7. User content and records", "Users are responsible for waypoints, logbook entries, delivery records, tender purchases, notes, photos, OCR outputs, and other content they create or store. OCR and parsing may be wrong. Users must review and correct extracted values before relying on or saving them."),
        ("8. Accounts and data", "Some features may use local device storage, Firebase/Firestore, or other backend services. Use is also subject to the Privacy Policy."),
        ("9. Third-party services and data providers", "Third-party providers do not sponsor, endorse, certify, or warrant SatChart unless expressly stated in writing. Third-party services may change, become unavailable, require attribution, impose license restrictions, or return incomplete/delayed data."),
        ("10. App license", "SatChart is licensed, not sold. If distributed through the Apple App Store and no custom license agreement is provided, Apple's Standard End User License Agreement applies to the app license. If a custom license is provided, that license may apply instead."),
        ("11. Prohibited use", "Do not use SatChart for unlawful activity, unauthorized access, interfering with backend services or users, sharing harmful/deceptive/abusive/unlawful content, reverse engineering or redistributing protected map packs/imagery/data except where allowed by licenses, or using SatChart in a way that endangers people, vessels, property, or the fishery."),
        ("12. No warranties", "SatChart is provided \"as is\" and \"as available.\" To the maximum extent permitted by law, SatChart makes no warranties about accuracy, availability, completeness, fitness for a particular purpose, non-infringement, merchantability, uptime, data freshness, or suitability for navigation, fishing, weather, safety, legal, or financial decisions."),
        ("13. Limitation of liability", "To the maximum extent permitted by law, SatChart and its owners, developers, contributors, licensors, and service providers are not liable for losses or damages arising from use of the app, inability to use the app, data errors, missing/delayed data, incorrect location/weather/tide information, map errors, fishery data errors, derived metrics, Radio Group sharing, logbook records, OCR output, or decisions made in reliance on SatChart."),
        ("14. Changes", "SatChart features, data sources, models, map packs, services, and Terms may change over time. Continued use after updates means the user accepts the updated Terms.")
    ]

    var body: some View {
        SettingsDetailPageScaffold(title: "Terms of Use") {
            SettingsInfoCard(title: "Terms of Use") {
                SettingsBodyText(text: "Effective date: \(SatChartReleaseConfiguration.legalEffectiveDate)")
                SettingsBodyText(text: "These Terms of Use govern your use of SatChart. By using SatChart, you agree to these Terms. If you do not agree, do not use the app.")
                SettingsExternalLinkRow(title: "Open Terms of Use", urlString: SatChartReleaseConfiguration.termsOfUseURLString)
            }
            ForEach(sections, id: \.0) { section in
                SettingsInfoCard(title: section.0) {
                    SettingsBodyText(text: section.1)
                }
            }
            SettingsInfoCard(title: "15. Contact") {
                SettingsStatusRow(title: "Support email", value: SatChartReleaseConfiguration.supportEmail)
                SettingsExternalLinkRow(title: "Support website", urlString: SatChartReleaseConfiguration.supportWebsiteURLString)
            }
        }
    }
}

private struct SettingsSupportPageView: View {
    private var template: String {
        """
        App version: \(SettingsAppInfo.version)
        Build: \(SettingsAppInfo.build)
        iOS version:
        Device:
        Feature/page:
        Expected result:
        Actual result:
        Steps to reproduce:
        Screenshot/video attached:
        Approximate time:
        Offline/online state:
        District/map pack/source involved:
        """
    }

    var body: some View {
        SettingsDetailPageScaffold(title: "Support / Report a Problem") {
            SettingsInfoCard(title: "Contact") {
                SettingsStatusRow(title: "Support email", value: SatChartReleaseConfiguration.supportEmail)
                SettingsExternalLinkRow(title: "Website", urlString: SatChartReleaseConfiguration.supportWebsiteURLString)
                SettingsExternalLinkRow(title: "Privacy Policy", urlString: SatChartReleaseConfiguration.privacyPolicyURLString)
                SettingsExternalLinkRow(title: "Terms of Use", urlString: SatChartReleaseConfiguration.termsOfUseURLString)
                SettingsExternalLinkRow(title: "Data Collection", urlString: SatChartReleaseConfiguration.dataCollectionURLString)
                SettingsStatusRow(title: "App", value: SettingsAppInfo.versionBuild)
            }
            SettingsInfoCard(title: "Report Template") {
                Text(template)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.88))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsPermissionsDeviceAccessPageView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        SettingsDetailPageScaffold(title: "Permissions & Device Access") {
            SettingsInfoCard(title: "Current Permission Status") {
                SettingsStatusRow(title: "Location", value: locationStatus)
                SettingsStatusRow(title: "Camera", value: cameraStatus)
                SettingsStatusRow(title: "Photo Library", value: "Only requested when photo library source is used.")
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    SettingsActionRow(title: "Open iOS App Settings", detail: "Review or change SatChart permissions in iOS Settings.", systemImage: "gearshape.fill")
                }
                .buttonStyle(SatChartPressFeedbackButtonStyle())
            }
            SettingsInfoCard(title: "How Permissions Are Used") {
                SettingsBulletList(items: [
                    "Location is used for map position, set recording, tide/weather lookup, waypoints, and optional Radio Group live sharing.",
                    "Camera/photo access is used for fish ticket/tally/receipt capture and OCR.",
                    "Network is used for maps, reports, tides, weather, ocean layers, Firebase/Radio Groups, and support."
                ])
            }
        }
    }

    private var locationStatus: String {
        let status: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            status = CLLocationManager().authorizationStatus
        } else {
            status = CLLocationManager.authorizationStatus()
        }

        switch status {
        case .notDetermined: return "Not determined"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .authorizedAlways: return "Authorized always"
        case .authorizedWhenInUse: return "Authorized when in use"
        @unknown default: return "Unknown"
        }
    }

    private var cameraStatus: String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: return "Not determined"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .authorized: return "Authorized"
        @unknown default: return "Unknown"
        }
    }
}

private struct SettingsStorageOfflineDataPageView: View {
    @ObservedObject private var offline = OfflineMapsManager.shared
    @State private var snapshot: StorageUsageSnapshot?
    @State private var isScanning = false
    @State private var isClearingCaches = false
    @State private var cacheMessage: String? = nil

    var body: some View {
        SettingsDetailPageScaffold(title: "Storage & Offline Data") {
            if isScanning && snapshot == nil {
                SettingsInfoCard(title: "Scanning Storage") {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(.white)
                        SettingsBodyText(text: "Calculating local storage used by offline data, map downloads, documents, app support data, caches, and temporary files.")
                    }
                }
            }

            if let snapshot {
                ForEach(snapshot.sections) { section in
                    SettingsStorageSectionView(section: section)
                }

                SettingsInfoCard(title: "Last Refreshed") {
                    SettingsStatusRow(title: "Measured", value: Self.refreshedFormatter.string(from: snapshot.generatedAt))
                    Button {
                        Task { await loadStorageUsage() }
                    } label: {
                        SettingsInlineButtonLabel(
                            title: isScanning ? "Refreshing..." : "Refresh Storage",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(SatChartPressFeedbackButtonStyle())
                    .disabled(isScanning)
                }
            }

            SettingsInfoCard(title: "Offline Packs vs Online Caches") {
                SettingsBodyText(text: "Offline packs are deliberate downloads intended for use without service. Online tile caches are transient map and ocean-layer files that can be recreated from providers when network access is available.")
                SettingsBodyText(text: "This page only offers an online tile cache cleanup action. It does not delete user logbook records, waypoints, Radio Group cloud data, offline databases, documents, or offline map downloads.")
                SatChartDeleteConfirmationButton(
                    confirmationTitle: "Delete online tile caches?",
                    confirmationMessage: "Only recreatable online map and ocean-layer cache files will be deleted."
                ) {
                    Task {
                        await clearOnlineTileCaches()
                    }
                } label: { isFlashingRed in
                    HStack(spacing: 8) {
                        SatChartDeleteIcon(isFlashingRed: isFlashingRed, defaultColor: .white)
                            .font(.system(size: 13, weight: .bold))
                        Text(isClearingCaches ? "Clearing..." : "Clear Online Tile Caches Only")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(Color.white.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(SatChartPressFeedbackButtonStyle())
                .disabled(isClearingCaches)
                if let cacheMessage {
                    SettingsBodyText(text: cacheMessage)
                }
            }
        }
        .task {
            await loadStorageUsage()
        }
        .refreshable {
            await loadStorageUsage()
        }
        .onReceive(offline.$downloadedTick.dropFirst()) { _ in
            Task { await loadStorageUsage() }
        }
    }

    @MainActor
    private func loadStorageUsage() async {
        isScanning = true
        let newSnapshot = await StorageUsageService.snapshot()
        snapshot = newSnapshot
        isScanning = false
    }

    @MainActor
    private func clearOnlineTileCaches() async {
        isClearingCaches = true
        cacheMessage = await StorageUsageService.clearKnownOnlineTileCaches()
        isClearingCaches = false
        await loadStorageUsage()
    }

    private static let refreshedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct SettingsStorageSectionView: View {
    let section: StorageUsageSection

    var body: some View {
        SettingsInfoCard(title: section.title) {
            if let subtitle = section.subtitle {
                SettingsBodyText(text: subtitle)
            }

            if section.id != "summary" {
                SettingsStatusRow(title: "Total", value: StorageUsageService.formattedByteCount(section.bytes))
            }

            ForEach(section.items) { item in
                SettingsStorageItemRow(item: item)
            }
        }
    }
}

private struct SettingsStorageItemRow: View {
    let item: StorageUsageItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.66))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 8)

            Text(StorageUsageService.formattedByteCount(item.bytes))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.82))
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .textSelection(.enabled)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SettingsInlineButtonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
        }
        .foregroundColor(.white)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.white.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SettingsManageMyDataPageView: View {
    var body: some View {
        ManageMyDataView()
    }
}

private struct SettingsMyAccountPageView: View {
    var body: some View {
        MyAccountView()
    }
}

private struct SettingsDownloadResourcePageView: View {
    let title: String
    let summary: String
    let releaseNotes: [String]

    var body: some View {
        SettingsDetailPageScaffold(title: title) {
            SettingsInfoCard(title: "Resource Status") {
                SettingsBodyText(text: "This resource area is available for source and download status as SatChart expands in-app data downloads. Contact support for help locating a source or reporting a stale resource.")
                SettingsExternalLinkRow(title: "Support", urlString: SatChartReleaseConfiguration.supportWebsiteURLString)
            }
            SettingsInfoCard(title: title) {
                SettingsBodyText(text: summary)
                SettingsBulletList(items: releaseNotes)
            }
        }
    }
}

private struct SettingsAcknowledgmentLink: Identifiable {
    let title: String
    let urlString: String

    var id: String { urlString }
    var url: URL? { URL(string: urlString) }
}

private struct SettingsAcknowledgmentItem: Identifiable {
    let title: String
    let summary: String
    let links: [SettingsAcknowledgmentLink]

    var id: String { title }
}

struct SettingsDataAcknowledgmentsPageView: View {
    private let items: [SettingsAcknowledgmentItem] = [
        SettingsAcknowledgmentItem(
            title: "NOAA CO-OPS tides and water levels",
            summary: "Tide station metadata, nearby-station selection, predicted tides, tide-curve points, and observed water-level samples are provided by the NOAA National Ocean Service Center for Operational Oceanographic Products and Services (CO-OPS). SatChart may interpolate tide heights between returned API points for compact displays and set-record summaries.",
            links: [
                SettingsAcknowledgmentLink(title: "NOAA CO-OPS Data API", urlString: "https://api.tidesandcurrents.noaa.gov/api/prod/"),
                SettingsAcknowledgmentLink(title: "NOAA CO-OPS Metadata API", urlString: "https://api.tidesandcurrents.noaa.gov/mdapi/prod/")
            ]
        ),
        SettingsAcknowledgmentItem(
            title: "NOAA National Weather Service forecasts",
            summary: "Weather, wind, marine-zone, hourly, and grid forecast information is provided by the NOAA National Weather Service through api.weather.gov. Forecasts may update, expire, be corrected, or be unavailable without notice.",
            links: [
                SettingsAcknowledgmentLink(title: "NWS API documentation", urlString: "https://www.weather.gov/documentation/services-web-api")
            ]
        ),
        SettingsAcknowledgmentItem(
            title: "NOAA National Data Buoy Center observations",
            summary: "Marine observations such as pressure, wave height, dominant period, and water temperature may be provided by the NOAA National Data Buoy Center (NDBC) from nearby buoy, C-MAN, and marine observation stations.",
            links: [
                SettingsAcknowledgmentLink(title: "NOAA NDBC", urlString: "https://www.ndbc.noaa.gov/"),
                SettingsAcknowledgmentLink(title: "NDBC latest observations", urlString: "https://www.ndbc.noaa.gov/data/latest_obs/latest_obs.txt")
            ]
        ),
        SettingsAcknowledgmentItem(
            title: "NOAA NCEI historical weather",
            summary: "Historical weather context used in logbook or season-analysis views may be derived from NOAA National Centers for Environmental Information Global Historical Climatology Network hourly (GHCNh) station data. GHCNh is a multi-source archive of surface weather observations; station availability and observation quality vary by date and location.",
            links: [
                SettingsAcknowledgmentLink(title: "NOAA NCEI GHCNh", urlString: "https://www.ncei.noaa.gov/products/global-historical-climatology-network-hourly")
            ]
        ),
        SettingsAcknowledgmentItem(
            title: "NASA EOSDIS GIBS and GHRSST MUR ocean imagery",
            summary: "Sea-surface-temperature and anomaly map overlays use NASA EOSDIS Global Imagery Browse Services (GIBS) browse imagery, including GHRSST Level 4 JPL MUR Global Foundation SST analysis products. These imagery layers are intended for informational ocean-situational awareness and are not real-time navigation products.",
            links: [
                SettingsAcknowledgmentLink(title: "NASA GIBS", urlString: "https://www.earthdata.nasa.gov/engage/open-data-services-software/earthdata-developer-portal/gibs-api"),
                SettingsAcknowledgmentLink(title: "NASA Earthdata", urlString: "https://www.earthdata.nasa.gov/")
            ]
        ),
        SettingsAcknowledgmentItem(
            title: "NOAA CoastWatch ocean products",
            summary: "Additional ocean layers, when enabled, may use NOAA CoastWatch / OceanWatch / PolarWatch products and ERDDAP or WMS services, including satellite-derived sea-surface-temperature products and thermal-front products.",
            links: [
                SettingsAcknowledgmentLink(title: "NOAA CoastWatch", urlString: "https://coastwatch.noaa.gov/"),
                SettingsAcknowledgmentLink(title: "NOAA CoastWatch ERDDAP", urlString: "https://coastwatch.noaa.gov/erddap/")
            ]
        ),
        SettingsAcknowledgmentItem(
            title: "NOAA Office of Coast Survey nautical chart data",
            summary: "NOAA nautical chart online and offline map layers are based on NOAA Office of Coast Survey / NOAA Chart Display Service and NOAA Electronic Navigational Chart data. NOAA chart display imagery in SatChart is for reference only, is not certified for navigation, and does not satisfy chart-carriage requirements for regulated vessels.",
            links: [
                SettingsAcknowledgmentLink(title: "NOAA nautical charts", urlString: "https://nauticalcharts.noaa.gov/"),
                SettingsAcknowledgmentLink(title: "NOAA Chart Display Service", urlString: "https://www.arcgis.com/home/item.html?id=e9ca225657354ce4a8a64a1c1b0b60ba")
            ]
        ),
        SettingsAcknowledgmentItem(
            title: "USGS topographic map service",
            summary: "The online USGS Topo basemap uses U.S. Geological Survey / The National Map services. USGS-authored data and information are generally public domain, but SatChart credits USGS as the source where that map layer is shown.",
            links: [
                SettingsAcknowledgmentLink(title: "USGS Topo MapServer", urlString: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer"),
                SettingsAcknowledgmentLink(title: "USGS data policies", urlString: "https://www.usgs.gov/information-policies-and-instructions/copyrights-and-credits")
            ]
        ),
        SettingsAcknowledgmentItem(
            title: "Apple Maps and MapKit",
            summary: "Apple satellite/base map imagery and map-display functionality may be provided through Apple Maps and MapKit. Apple and its data providers retain all rights in Apple map content, and use is governed by Apple terms and developer requirements.",
            links: [
                SettingsAcknowledgmentLink(title: "Apple Maps for Developers", urlString: "https://developer.apple.com/maps/"),
                SettingsAcknowledgmentLink(title: "MapKit documentation", urlString: "https://developer.apple.com/documentation/mapkit/")
            ]
        ),
        SettingsAcknowledgmentItem(
            title: "Copernicus Sentinel satellite imagery",
            summary: "SatChart Bristol Bay satellite imagery is produced from Copernicus Sentinel satellite imagery. In-app satellite tiles, preview images, and offline satellite MBTiles may be processed, color-corrected, mosaicked, tiled, cached, blended, cropped, or otherwise modified for SatChart display. Required source notice for modified Sentinel imagery: ‘Contains modified Copernicus Sentinel data [Year].’ Sentinel data are provided under the Copernicus Sentinel Data legal notice; the European Union, ESA, Copernicus, and Sentinel data providers do not sponsor, endorse, certify, or warrant SatChart or any SatChart-derived map product.",
            links: [
                SettingsAcknowledgmentLink(title: "Copernicus Sentinel Data Legal Notice", urlString: "https://sentinels.copernicus.eu/documents/247904/690755/Sentinel_Data_Legal_Notice"),
                SettingsAcknowledgmentLink(title: "Copernicus Data Space Terms", urlString: "https://dataspace.copernicus.eu/terms-and-conditions"),
                SettingsAcknowledgmentLink(title: "Copernicus Data Space FAQ", urlString: "https://documentation.dataspace.copernicus.eu/FAQ.html")
            ]
        ),
        SettingsAcknowledgmentItem(
            title: "Bristol Bay satellite and offline map packs",
            summary: "Bristol Bay satellite tiles, shoreline packs, preview images, and offline MBTiles packs are hosted or distributed by SatChart. SatChart satellite imagery is produced from Copernicus Sentinel imagery unless a specific map pack states otherwise; underlying rights remain with the original provider. Tiles and MBTiles are provided for in-app use and should not be extracted, redistributed, or reused outside SatChart unless the original data license permits it.",
            links: []
        ),
        SettingsAcknowledgmentItem(
            title: "Fisheries reports, forecasts, and derived metrics",
            summary: "Fishery forecasts, harvest, escapement, registration, permit, district, boundary, report, and Port Moller test-fishery references may be based on public fishery-management reports, datasets, and updates from agencies and research organizations such as the Alaska Department of Fish and Game, the University of Washington Alaska Salmon Program / Fisheries Research Institute, BBSRI, BBFC, and related report publishers. SatChart-derived metrics are app calculations and are not official agency determinations.",
            links: [
                SettingsAcknowledgmentLink(title: "ADF&G Bristol Bay commercial fishing", urlString: "https://www.adfg.alaska.gov/index.cfm?adfg=commercialbyareabristolbay.main"),
                SettingsAcknowledgmentLink(title: "ADF&G Bristol Bay harvest summary", urlString: "https://www.adfg.alaska.gov/index.cfm?adfg=commercialbyareabristolbay.salmon_harvest"),
                SettingsAcknowledgmentLink(title: "UW Alaska Salmon Program inseason reports", urlString: "https://alaskasalmonprogram.org/inseason-reports/"),
                SettingsAcknowledgmentLink(title: "BBSRI inseason project data", urlString: "https://www.bbsri.org/inseason-data")
            ]
        ),
        SettingsAcknowledgmentItem(
            title: "KDLG radio stream",
            summary: "The KDLG audio feature is an in-app playback shortcut to publicly reachable KDLG stream endpoints. KDLG programming, radio content, trademarks, and stream availability are controlled by KDLG and its licensors or streaming providers. SatChart does not own the stream content.",
            links: [
                SettingsAcknowledgmentLink(title: "KDLG", urlString: "https://www.kdlg.org/"),
                SettingsAcknowledgmentLink(title: "Bristol Bay Fisheries Report", urlString: "https://www.kdlg.org/show/bristol-bay-fisheries-report")
            ]
        ),
        SettingsAcknowledgmentItem(
            title: "Google Firebase and Firestore services",
            summary: "SatChart uses Google Firebase / Firestore services for app backend features such as shared radio-group state, live location sharing, pins, and hosted app data. User-created waypoints, logbook entries, and live-location records are user/app data rather than third-party source data, but Google service terms apply to the backend services used to store and transmit them.",
            links: [
                SettingsAcknowledgmentLink(title: "Firebase", urlString: "https://firebase.google.com/")
            ]
        )
    ]

    var body: some View {
        ZStack {
            bbMenuBlue_MV.ignoresSafeArea()
            HostingBackgroundFixer(color: bbMenuBlueUIColor_MV)
                .frame(width: 0, height: 0)

            LinearGradient(
                colors: [menuPageBackgroundTop_MV, menuPageBackgroundBottom_MV],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: [.top, .leading, .trailing])

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    noticeCard
                    ForEach(items) { item in
                        acknowledgmentCard(item)
                    }
                    softwareNoticeCard
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 18)
            }
            .background(Color.clear)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationTitle("Data Acknowledgments")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(bbMenuBlue_MV, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Data Acknowledgments")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .underline()
            }
        }
        .onAppear { BBMenuAppearance.applyNavBar() }
    }

    private var noticeCard: some View {
        settingsAcknowledgmentCard(title: "Important Use Notice") {
            VStack(alignment: .leading, spacing: 8) {
                Text("SatChart uses third-party data and services to display maps, tides, weather, ocean imagery, radio audio, and fisheries information. All third-party names, trademarks, data, imagery, streams, and services remain the property of their respective owners.")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)

                Text("Source names and trademarks belong to their respective owners. Third-party providers do not sponsor, endorse, certify, or warrant SatChart unless expressly stated.")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)

                Text("SatChart is an informational planning and situational-awareness tool. It is not a chart plotter, ECDIS, official nautical chart, official weather warning source, official tide/current table, or fishery-management decision product. Data may be delayed, cached, interpolated, estimated, incomplete, or unavailable. Always verify critical information with official sources and appropriate onboard instruments before navigation, weather, safety, or fishing decisions.")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)

                Text("No data provider listed here endorses SatChart unless an endorsement is expressly stated in writing.")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(Color.yellow.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)

                SettingsExternalLinkRow(title: "Open Data Acknowledgments", urlString: SatChartReleaseConfiguration.acknowledgmentsURLString)
            }
        }
    }

    private var softwareNoticeCard: some View {
        settingsAcknowledgmentCard(title: "Third-Party Software Notices") {
            VStack(alignment: .leading, spacing: 8) {
                Text("This page focuses on third-party data and data services. SatChart also uses third-party SDKs and software libraries. Open-source library license notices should be included separately in the app bundle or another Settings page when required by their licenses.")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func acknowledgmentCard(_ item: SettingsAcknowledgmentItem) -> some View {
        settingsAcknowledgmentCard(title: item.title) {
            VStack(alignment: .leading, spacing: 9) {
                Text(item.summary)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)

                if !item.links.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(item.links) { link in
                            acknowledgmentLinkRow(link)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func acknowledgmentLinkRow(_ link: SettingsAcknowledgmentLink) -> some View {
        if let url = link.url {
            Link(destination: url) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 12, weight: .bold))
                    Text(link.title)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(Color.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(SatChartPressFeedbackButtonStyle())
        }
    }

    private func settingsAcknowledgmentCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .underline(true, color: Color.white.opacity(0.55))

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

struct SettingsScreenLayoutOptionsPageView: View {
    @AppStorage("showPortMollerTestFisheryStations") private var showPortMollerTestFisheryStations: Bool = true
    @AppStorage("navShowTopHUDDisplay") private var showNavTopHUDDisplay: Bool = true
    @AppStorage("navTopHUDOpacity") private var showNavTopHUDOpacity: Bool = true
    @AppStorage("navShowTideHUD") private var showNavTideHUD: Bool = true
    @AppStorage("navShowLocationReadout") private var showNavLocationReadout: Bool = true
    @AppStorage("navShowBoundaryReadout") private var showNavBoundaryReadout: Bool = true
    @AppStorage("navShowSpeedReadout") private var showNavSpeedReadout: Bool = true
    @AppStorage("navShowWindReadout") private var showNavWindReadout: Bool = true
    @AppStorage("navShowKDLGButton") private var showNavKDLGButton: Bool = true
    @AppStorage("navShowScaleBar") private var showNavScaleBar: Bool = true
    @AppStorage("navShowOceanLayerLegend") private var showNavOceanLayerLegend: Bool = true
    @AppStorage("navShowFollowUserButton") private var showNavFollowUserButton: Bool = true
    @AppStorage("navShowRecenterButton") private var showNavRecenterButton: Bool = true
    @AppStorage("navShowBasemapButton") private var showNavBasemapButton: Bool = true
    @AppStorage("navShowMainMenuButton") private var showNavMainMenuButton: Bool = true
    @AppStorage("navShowOceanLayersButton") private var showNavOceanLayersButton: Bool = true
    @AppStorage("navShowShareLiveButton") private var showNavShareLiveButton: Bool = true
    @AppStorage("navShowLiveLocationTrail") private var showNavLiveLocationTrail: Bool = true
    @AppStorage("navShowSendLocationButton") private var showNavSendLocationButton: Bool = true
    @AppStorage("navShowRecordSetButton") private var showNavRecordSetButton: Bool = true
    @AppStorage("navShowCreateWaypointButton") private var showNavCreateWaypointButton: Bool = true
    @AppStorage("navShowZoomInButton") private var showNavZoomInButton: Bool = true
    @AppStorage("navShowZoomOutButton") private var showNavZoomOutButton: Bool = true
    @AppStorage("navShowMapSelector") private var showNavMapSelector: Bool = true

    var body: some View {
        ZStack {
            bbMenuBlue_MV.ignoresSafeArea()
            HostingBackgroundFixer(color: bbMenuBlueUIColor_MV)
                .frame(width: 0, height: 0)

            LinearGradient(
                colors: [menuPageBackgroundTop_MV, menuPageBackgroundBottom_MV],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: [.top, .leading, .trailing])

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    hudDisplaySection
                    navigationButtonsSection
                    mapLayersSection
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .background(Color.clear)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationTitle("Screen Layout & Options")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(bbMenuBlue_MV, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Screen Layout & Options")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .underline()
            }
        }
        .onAppear { BBMenuAppearance.applyNavBar() }
    }

    private var hudDisplaySection: some View {
        settingsSectionCard(title: "Top HUD") {
            VStack(spacing: 8) {
                settingsToggle(
                    title: "Top HUD Display",
                    subtitle: "Shows the top HUD readouts. When off, fish-ticket OCR, map appearance, and enabled share and action buttons remain in one row at the top.",
                    isOn: $showNavTopHUDDisplay
                )
                settingsToggle(
                    title: "Top HUD Opacity",
                    subtitle: "Shows backgrounds behind the HUD and other navigation readouts. Turn off for white text over the map. Buttons keep their existing appearance.",
                    isOn: $showNavTopHUDOpacity
                )
                settingsToggle(title: "Tides HUD", subtitle: "Shows the compact tide chart and tide event summary.", isOn: $showNavTideHUD)
                settingsToggle(title: "Location Readout", subtitle: "Shows the editable user-location or cursor latitude/longitude row.", isOn: $showNavLocationReadout)
                settingsToggle(title: "Boundary Readout", subtitle: "Shows the distance-to-boundary readout.", isOn: $showNavBoundaryReadout)
                settingsToggle(title: "Speed Readout", subtitle: "Shows vessel/user speed in the top HUD.", isOn: $showNavSpeedReadout)
                settingsToggle(title: "Wind Readout", subtitle: "Shows the compact wind forecast indicator.", isOn: $showNavWindReadout)
                settingsToggle(title: "KDLG Button", subtitle: "Shows the KDLG audio toggle in the top HUD.", isOn: $showNavKDLGButton)
                settingsToggle(title: "Scale Bar", subtitle: "Shows the distance scale bar near the bottom controls.", isOn: $showNavScaleBar)
                settingsToggle(title: "Ocean Layer Legend", subtitle: "Shows the SST/ocean layer legend when an ocean layer is enabled.", isOn: $showNavOceanLayerLegend)
            }
        }
    }

    private var navigationButtonsSection: some View {
        settingsSectionCard(title: "Navigation Buttons") {
            VStack(spacing: 8) {
                settingsToggle(title: "Follow User Button", subtitle: "Shows the location-follow button.", isOn: $showNavFollowUserButton)
                settingsToggle(title: "Recenter Button", subtitle: "Shows the map recenter button.", isOn: $showNavRecenterButton)
                settingsToggle(title: "Basemap Button", subtitle: "Shows the satellite/chart basemap picker.", isOn: $showNavBasemapButton)
                settingsToggle(title: "Main Menu Button", subtitle: "Shows the main SatChart menu button.", isOn: $showNavMainMenuButton)
                settingsToggle(title: "Ocean Layers Button", subtitle: "Shows the SST/ocean layer control button.", isOn: $showNavOceanLayersButton)
                settingsToggle(title: "Share Live Button", subtitle: "Shows the live location sharing button, including when Top HUD Display is off.", isOn: $showNavShareLiveButton)
                settingsToggle(title: "Live Share Trail", subtitle: "Shows the fading trail behind Radio Group live location pins.", isOn: $showNavLiveLocationTrail)
                settingsToggle(title: "Send Location Button", subtitle: "Shows the one-time location pin button, including when Top HUD Display is off.", isOn: $showNavSendLocationButton)
                settingsToggle(title: "Record Set Button", subtitle: "Shows the Record Set recorder.", isOn: $showNavRecordSetButton)
                settingsToggle(title: "Create Waypoint Button", subtitle: "Shows the create waypoint button.", isOn: $showNavCreateWaypointButton)
                settingsToggle(title: "Zoom In Button", subtitle: "Shows the map zoom-in button.", isOn: $showNavZoomInButton)
                settingsToggle(title: "Zoom Out Button", subtitle: "Shows the map zoom-out button.", isOn: $showNavZoomOutButton)
                settingsToggle(title: "Map Version Selector", subtitle: "Shows the Map v# button for online and downloaded district map versions.", isOn: $showNavMapSelector)
            }
        }
    }

    private var mapLayersSection: some View {
        settingsSectionCard(title: "Map Layers") {
            VStack(spacing: 8) {
                settingsToggle(
                    title: "Show Port Moller test fishing stations",
                    subtitle: "Adds or removes the Port Moller test fishery stations and transect on the main map. Default is On.",
                    isOn: $showPortMollerTestFisheryStations
                )
            }
        }
    }

    private func settingsToggle(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                Text(subtitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(.blue)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.white.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func settingsSectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .underline(true, color: Color.white.opacity(0.55))

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

struct SettingsPageView: View {
    @AppStorage("keepDisplayOnWhileAppInUse") private var keepDisplayOnWhileAppInUse: Bool = true

    var body: some View {
        ZStack {
            bbMenuBlue_MV.ignoresSafeArea()
            HostingBackgroundFixer(color: bbMenuBlueUIColor_MV)
                .frame(width: 0, height: 0)

            LinearGradient(
                colors: [menuPageBackgroundTop_MV, menuPageBackgroundBottom_MV],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: [.top, .leading, .trailing])

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    systemSettingsCard
                    appInformationCard
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .background(Color.clear)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(bbMenuBlue_MV, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Settings")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .underline()
            }
        }
        .onAppear { BBMenuAppearance.applyNavBar() }
    }

    private var systemSettingsCard: some View {
        settingsSectionCard(title: "System Settings") {
            settingsLinkRow(
                title: "Screen Layout & Options",
                destination: SettingsScreenLayoutOptionsPageView()
            )
            settingsLinkRow(
                title: "Permissions & Device Access",
                destination: SettingsPermissionsDeviceAccessPageView()
            )
            settingsToggleRow(
                title: "Keep Display On",
                detail: "Prevents Auto-Lock while SatChart is open and active. Uses more battery.",
                isOn: $keepDisplayOnWhileAppInUse
            )
            settingsLinkRow(
                title: "Storage & Offline Data",
                destination: SettingsStorageOfflineDataPageView()
            )
            settingsLinkRow(
                title: "Beta Diagnostics",
                destination: BetaDiagnosticsView()
            )
            settingsLinkRow(
                title: "Manage My Data",
                destination: SettingsManageMyDataPageView()
            )
            settingsLinkRow(
                title: "My Account",
                destination: SettingsMyAccountPageView()
            )
        }
    }

    private var appInformationCard: some View {
        settingsSectionCard(title: "App & Information") {
            settingsLinkRow(
                title: "About",
                destination: SettingsAboutPageView()
            )
            settingsLinkRow(
                title: "Safety & Use Notice",
                destination: SettingsSafetyUseNoticePageView()
            )
            settingsLinkRow(
                title: "Data Status",
                destination: SettingsDataStatusPageView()
            )
            settingsLinkRow(
                title: "Data Acknowledgments",
                destination: SettingsDataAcknowledgmentsPageView()
            )
            settingsLinkRow(
                title: "Models & Derived Metrics",
                destination: SettingsModelsDerivedMetricsPageView()
            )
            settingsLinkRow(
                title: "Privacy Policy",
                destination: SettingsPrivacyPolicyPageView()
            )
            settingsLinkRow(
                title: "Terms of Use",
                destination: SettingsTermsOfUsePageView()
            )
            settingsLinkRow(
                title: "Support / Report a Problem",
                destination: SettingsSupportPageView()
            )
        }
    }

    private func settingsSectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .underline(true, color: Color.white.opacity(0.55))

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func settingsLinkRow<Destination: View>(title: String, destination: Destination) -> some View {
        NavigationLink(destination: destination.settingsChildPageChrome()) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Color.white.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    private func settingsToggleRow(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text(detail)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.76))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(.blue)
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
// MARK: - Create Waypoint Prompt

struct CreateWaypointPrompt: View {
    @Binding var name: String
    var onCreate: () -> Void
    var onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            scBackground.opacity(0.55).ignoresSafeArea().onTapGesture { onCancel() }

            HStack(alignment: .center, spacing: 10) {
                TextField("Waypoint name", text: $name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.black)
                    .tint(.blue)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 10)
                    .frame(width: 170, height: 36)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.black.opacity(0.15), lineWidth: 1))
                    .focused($isFocused)

                Button { onCreate() } label: { Text("Create Waypoint?") }
                    .buttonStyle(MapPromptActionButtonStyle(kind: .primary))

                Button { onCancel() } label: { Text("Cancel") }
                    .buttonStyle(MapPromptActionButtonStyle(kind: .secondary))
            }
            .padding(10)
            .background(scSurface.opacity(0.95))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 1))
            .padding(.horizontal, 16)
            .buttonStyle(SatChartPressFeedbackButtonStyle())
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { isFocused = true } }
        }
    }
}


// MARK: - Fishing Set Prompts

private struct StartSetPrompt: View {
    var onStart: () -> Void
    var onCancel: () -> Void

    var body: some View {
        ZStack {
            scBackground.opacity(0.55).ignoresSafeArea().onTapGesture { onCancel() }

            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "timer.circle.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.orange)
                    Text("Record Set")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }

                Text("Start recording the current GPS position, tide, start time, and 3-minute drift samples.")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.76))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button { onStart() } label: { Text("Start Recording Set") }
                        .buttonStyle(MapPromptActionButtonStyle(kind: .primary))

                    Button { onCancel() } label: { Text("Cancel") }
                        .buttonStyle(MapPromptActionButtonStyle(kind: .secondary))
                }
            }
            .padding(14)
            .background(scSurface.opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 1))
            .padding(.horizontal, 22)
        }
    }
}

private struct RecordingSetFlashPrompt: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.16).ignoresSafeArea()
            Text("Recording Set")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundColor(.black)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(Color.orange.opacity(0.96))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.22), lineWidth: 1))
        }
    }
}

private struct CompletedSetPrompt: View {
    let set: SmartFishingSetRecord
    @Binding var catchPoundsText: String
    @Binding var fishCountText: String
    @Binding var pickingMinutes: Int
    @Binding var notes: String
    @Binding var displayOnMap: Bool
    let isResolvingTide: Bool
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        ZStack {
            scBackground.opacity(0.62).ignoresSafeArea()

            CompletedSetPromptCard(
                set: set,
                catchPoundsText: $catchPoundsText,
                fishCountText: $fishCountText,
                pickingMinutes: $pickingMinutes,
                notes: $notes,
                displayOnMap: $displayOnMap,
                isResolvingTide: isResolvingTide,
                onSave: onSave,
                onCancel: onCancel
            )
        }
    }
}

private struct CompletedSetPromptCard: View {
    let set: SmartFishingSetRecord
    @Binding var catchPoundsText: String
    @Binding var fishCountText: String
    @Binding var pickingMinutes: Int
    @Binding var notes: String
    @Binding var displayOnMap: Bool
    let isResolvingTide: Bool
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                CompletedSetHeaderRow(setNumber: set.setNumber, isResolvingTide: isResolvingTide)

                CompletedSetOptionalEntrySection(
                    catchPoundsText: $catchPoundsText,
                    fishCountText: $fishCountText,
                    pickingMinutes: $pickingMinutes,
                    notes: $notes
                )

                CompletedSetCollectedDataSection(set: set)

                CompletedSetShowSetToggleRow(displayOnMap: $displayOnMap)

                CompletedSetActionRow(onSave: onSave, onCancel: onCancel)
            }
            .padding(14)
        }
        .frame(maxWidth: 520, maxHeight: 620)
        .background(scSurface.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
    }
}

private struct CompletedSetHeaderRow: View {
    let setNumber: Int
    let isResolvingTide: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.orange)
            Text("Set #\(setNumber)")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Spacer(minLength: 0)
            if isResolvingTide {
                ProgressView()
                    .tint(.white)
            }
        }
    }
}

private struct CompletedSetCatchChoiceFields: View {
    @Binding var catchPoundsText: String
    @Binding var fishCountText: String

    private var poundsBinding: Binding<String> {
        Binding(
            get: { catchPoundsText },
            set: { newValue in
                catchPoundsText = newValue
                if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fishCountText = ""
                }
            }
        )
    }

    private var fishCountBinding: Binding<String> {
        Binding(
            get: { fishCountText },
            set: { newValue in
                fishCountText = newValue
                if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    catchPoundsText = ""
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Catch estimate — choose one")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.72))

            HStack(spacing: 8) {
                CompletedSetCatchEntryField(
                    title: "Catch in lbs",
                    placeholder: "lbs",
                    text: poundsBinding,
                    keyboardType: .decimalPad
                )

                CompletedSetCatchEntryField(
                    title: "Number of Fish",
                    placeholder: "fish",
                    text: fishCountBinding,
                    keyboardType: .numberPad
                )
            }

            Text("Use whichever estimate is easiest; entering one clears the other.")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.58))
        }
    }
}

private struct CompletedSetCatchEntryField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let keyboardType: UIKeyboardType

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.78))

            TextField(placeholder, text: $text)
                .keyboardType(keyboardType)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.black)
                .tint(.blue)
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CompletedSetOptionalEntrySection: View {
    @Binding var catchPoundsText: String
    @Binding var fishCountText: String
    @Binding var pickingMinutes: Int
    @Binding var notes: String

    private let pickingOptions: [Int] = Array(stride(from: 5, through: 720, by: 5))

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Optional Entry")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.72))

            CompletedSetCatchChoiceFields(
                catchPoundsText: $catchPoundsText,
                fishCountText: $fishCountText
            )

            pickingTimePicker
            notesEditor
        }
    }

    private var pickingTimePicker: some View {
        Picker("Picking Time", selection: $pickingMinutes) {
            Text("Picking Time: —").tag(-1)
            ForEach(pickingOptions, id: \.self) { minutes in
                Text("Picking Time: \(Self.pickingLabel(minutes))").tag(minutes)
            }
        }
        .pickerStyle(.menu)
        .tint(.white)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.72))
            TextEditor(text: $notes)
                .scrollContentBackground(.hidden)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .frame(minHeight: 82)
                .padding(8)
                .background(Color.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private static func pickingLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }
}

struct CompletedSetCollectedDataSection: View {
    let set: SmartFishingSetRecord

    private let gridColumns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Collected Data")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.72))

            LazyVGrid(columns: gridColumns, spacing: 8) {
                SetDataPill(label: "Start Time", value: MapFishingSetFormat.dateTime(set.startedAt))
                SetDataPill(label: "End Time", value: MapFishingSetFormat.dateTime(set.endedAt))
                SetDataPill(label: "Duration", value: MapFishingSetFormat.duration(set.duration))
                SetDataPill(label: "Drift", value: String(format: "%.2f mi", set.driftMiles))
            }

            CompletedSetTideCard(startTide: set.startTide, endTide: set.endTide)
            CompletedSetCoordinatesCard(locations: set.sortedLocations)
        }
    }
}

private struct CompletedSetTideCard: View {
    let startTide: SmartFishingSetTideSnapshot?
    let endTide: SmartFishingSetTideSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tide")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.58))
            HStack(spacing: 5) {
                TideSnapshotLabel(snapshot: startTide)
                Text("–")
                    .foregroundColor(.white.opacity(0.72))
                TideSnapshotLabel(snapshot: endTide)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct CompletedSetCoordinateDisplayRow: Identifiable {
    let id: UUID
    let index: Int
    let location: SmartFishingSetLocation
}

private struct CompletedSetCoordinatesCard: View {
    let locations: [SmartFishingSetLocation]

    private var rows: [CompletedSetCoordinateDisplayRow] {
        locations.enumerated().map { entry in
            CompletedSetCoordinateDisplayRow(
                id: entry.element.id,
                index: entry.offset + 1,
                location: entry.element
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Coordinates")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.58))

            ForEach(rows) { row in
                CompletedSetCoordinateText(row: row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct CompletedSetShowSetToggleRow: View {
    @Binding var displayOnMap: Bool

    private let toggleTint = Color(red: 0.39, green: 0.73, blue: 0.98)

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Show Set")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text("Turn this on if you want this set visible on the navigation map.")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.66))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Toggle("Show Set", isOn: $displayOnMap)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(toggleTint)
        }
        .padding(10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct CompletedSetCoordinateText: View {
    let row: CompletedSetCoordinateDisplayRow

    var body: some View {
        Text(coordinateLine)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.82))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
    }

    private var coordinateLine: String {
        let coordinate = MapFishingSetFormat.coordinate(row.location.coordinate)
        let time = MapFishingSetFormat.time(row.location.recordedAt)
        return "\(row.index). \(coordinate) • \(time)"
    }
}

struct CompletedSetActionRow: View {
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button { onSave() } label: { Text("Save & Exit") }
                .buttonStyle(MapPromptActionButtonStyle(kind: .primary))

            Button { onCancel() } label: { Text("Cancel") }
                .buttonStyle(MapPromptActionButtonStyle(kind: .secondary))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct SetDataPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.58))
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct TideSnapshotLabel: View {
    let snapshot: SmartFishingSetTideSnapshot?

    var body: some View {
        HStack(spacing: 3) {
            Text(MapFishingSetFormat.tideHeight(snapshot))
            Image(systemName: (snapshot?.state ?? .unknown).arrowSystemName)
                .font(.system(size: 10, weight: .bold))
        }
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .foregroundColor(.white)
    }
}

private enum MapFishingSetFormat {
    static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static func dateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        if totalSeconds < 60 { return "\(totalSeconds)s" }
        let minutes = totalSeconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours < 24 { return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m" }
        let days = hours / 24
        let remainderHours = hours % 24
        return remainderHours == 0 ? "\(days)d" : "\(days)d \(remainderHours)h"
    }

    static func tideHeight(_ snapshot: SmartFishingSetTideSnapshot?) -> String {
        guard let height = snapshot?.heightFeet else { return "— ft" }
        return String(format: "%.1f ft", height)
    }

    static func coordinate(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }
}

// MARK: - Thin scale bar wrapper

struct ThinScaleBar: View {
    let metersPerPoint: Double
    var body: some View { NauticalScaleBar(metersPerPoint: metersPerPoint).scaleEffect(0.9).opacity(0.95) }
}

struct LandscapeCompactScaleBar: View {
    @Environment(\.navigationReadoutBackgroundsVisible) private var showsBackgrounds
    let metersPerPoint: Double

    // 30% shorter than NauticalScaleBar's standard 140 pt bar length.
    private let maxBarWidth: CGFloat = 98
    private let minBarWidth: CGFloat = 49
    private let barHeight: CGFloat = 3
    private let containerHeight: CGFloat = 28

    var body: some View {
        let scale = niceScale(metersPerPoint: metersPerPoint, maxBarWidth: maxBarWidth)

        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: maxBarWidth, height: barHeight)

                Capsule()
                    .fill(Color.white)
                    .frame(width: max(scale.barWidth, minBarWidth), height: barHeight)
            }

            Text(scale.label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(height: containerHeight)
        .padding(.horizontal, 8)
        .background(Color.black.opacity(showsBackgrounds ? 0.55 : 0))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(showsBackgrounds ? 0.12 : 0), lineWidth: 1)
        )
    }

    private struct ScaleResult {
        let meters: Double
        let barWidth: CGFloat
        let label: String
    }

    private func niceScale(metersPerPoint: Double, maxBarWidth: CGFloat) -> ScaleResult {
        let mpp = (metersPerPoint.isFinite && metersPerPoint > 0) ? metersPerPoint : 1
        let maxMeters = Double(maxBarWidth) * mpp
        let niceMeters = niceNumber(lessThanOrEqualTo: maxMeters)
        let width = CGFloat(niceMeters / mpp)

        return ScaleResult(
            meters: niceMeters,
            barWidth: min(max(width, minBarWidth), maxBarWidth),
            label: formatDistance(niceMeters)
        )
    }

    private func niceNumber(lessThanOrEqualTo x: Double) -> Double {
        guard x > 0, x.isFinite else { return 1 }

        let exp = floor(log10(x))
        let base = pow(10, exp)
        let f = x / base

        let niceF: Double
        if f >= 5 { niceF = 5 }
        else if f >= 2 { niceF = 2 }
        else { niceF = 1 }

        return niceF * base
    }

    private func formatDistance(_ meters: Double) -> String {
        if !meters.isFinite { return "—" }
        let nauticalMiles = meters / 1852.0
        if nauticalMiles >= 0.1 {
            return nauticalMiles >= 10
                ? String(format: "%.0f nm", nauticalMiles)
                : String(format: "%.1f nm", nauticalMiles)
        }

        let feet = meters * 3.28084
        if feet >= 1000 { return String(format: "%.0f ft", feet.rounded(toNearest: 100)) }
        return String(format: "%.0f ft", feet.rounded(toNearest: 10))
    }
}

private extension Double {
    func rounded(toNearest step: Double) -> Double {
        guard step > 0 else { return self }
        return (self / step).rounded() * step
    }
}

// MARK: - Button styles

struct MapIconButtonStyle: ButtonStyle {
    var isActive: Bool = false
    var foreground: Color = .white
    var background: Color? = nil

    func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        let base = background ?? Color.black.opacity(0.60)
        let active = background ?? Color(red: 0.39, green: 0.73, blue: 0.98).opacity(0.78)
        let pressed = background?.opacity(0.82) ?? Color(red: 0.39, green: 0.73, blue: 0.98).opacity(0.50)

        return configuration.label
            .frame(width: 48, height: 48)
            .background(configuration.isPressed ? pressed : (isActive ? active : base))
            .foregroundColor(foreground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
            .satChartPressFeedback(isPressed: configuration.isPressed)
    }
}

struct MapPromptActionButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind

    func makeBody(configuration: ButtonStyle.Configuration) -> some View {
        let base = Color.black.opacity(0.60)
        let primaryBase = Color(red: 0.39, green: 0.73, blue: 0.98).opacity(0.78)
        let pressed = Color(red: 0.39, green: 0.73, blue: 0.98).opacity(0.50)

        return configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .frame(height: 36)
            .padding(.horizontal, 10)
            .background(configuration.isPressed ? pressed : (kind == .primary ? primaryBase : base))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
            .satChartPressFeedback(isPressed: configuration.isPressed)
    }
}

// Note: `hudBoxSmall()` is used by MapView HUD readouts; WaypointsView has its own styling below.
private struct NavigationHUDReadoutStyle: ViewModifier {
    @Environment(\.navigationReadoutBackgroundsVisible) private var showsBackgrounds

    func body(content: Content) -> some View {
        content
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(showsBackgrounds ? scSurface.opacity(0.70) : Color.clear)
            .foregroundColor(showsBackgrounds ? scTextPrimary : .white)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private extension View {
    func hudBoxSmall() -> some View {
        modifier(NavigationHUDReadoutStyle())
    }
}

struct WaypointsView: View {

    @Binding var waypoints: [Waypoint]

    @EnvironmentObject var radioGroup: RadioGroupStore
    @AppStorage("radioGroupId") private var radioGroupId: String = ""
    @AppStorage("defaultWaypointPinColorID") private var defaultWaypointPinColorID: String = ""
    @AppStorage("vesselName") private var vesselName: String = ""

    @FocusState private var focusedWaypointID: UUID?
    @FocusState private var focusedReceivedWaypointID: String?

    // MARK: - Shared layout styling (matched to Tables page)
    private let sectionCornerRadius: CGFloat = 16
    private let sectionBackground = Color.white.opacity(0.08)
    private let sectionBorder = Color.white.opacity(0.10)
    private let selectorHeight: CGFloat = 33
    private let waypointCardHorizontalPadding: CGFloat = 12
    private let waypointCardContentPadding: CGFloat = 14
    private let waypointActionBoxWidth: CGFloat = 36
    private let waypointActionBoxHeight: CGFloat = 33
    private let waypointRowSpacing: CGFloat = 8
    private let waypointPinColumnWidth: CGFloat = 14
    private let waypointNameFieldWidth: CGFloat = 84
    private let waypointExportCheckboxWidth: CGFloat = 36
    // Toast
    @State private var toastText: String? = nil
    @State private var toastHideWork: DispatchWorkItem? = nil

    // Send animation state
    @State private var animatingSendIDs: Set<UUID> = []

    // Local-only rename overrides for received waypoints (do NOT write back to Firestore)
    @State private var receivedNameOverrides: [String: String] = [:]

    // Re-share confirmation (when user taps Share on an already-shared waypoint)
    @State private var pendingReshare: Waypoint? = nil

    // Bulk delete confirmations
    @State private var showConfirmDeleteAllReceived: Bool = false
    @State private var showConfirmDeleteAll: Bool = false

    // GPX export
    @State private var selectedWaypointExportIDs: Set<UUID> = []
    @State private var exportDocument: WaypointGPXExportDocument?
    @State private var isPresentingGPXExporter: Bool = false
    @State private var exportSuggestedFilename: String = WaypointGPXBuilder.defaultFilename()
    @State private var showExportAlert: Bool = false
    @State private var exportAlertMessage: String = ""

    // Legend
    @AppStorage("radioPinDisplayName") private var radioPinDisplayName: String = ""

    private var currentWaypointColor: WaypointPinColor {
        WaypointPinColor.safe(
            rawValue: defaultWaypointPinColorID,
            fallback: WaypointColorPreferences.ensureLocalDefaultColor()
        )
    }

    private var currentUserLabel: String {
        let candidates = [vesselName, radioPinDisplayName]
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "Me"
    }

    private var canExportGPX: Bool {
        !selectedWaypointExportIDs.isEmpty
    }

    private var exportButtonBackground: Color {
        canExportGPX ? Color.blue.opacity(0.85) : Color.white.opacity(0.10)
    }

    private func showToast(_ text: String, seconds: TimeInterval = 3.0) {
        toastHideWork?.cancel()
        toastText = text
        let work = DispatchWorkItem { toastText = nil }
        toastHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM/dd/yy"
        return f.string(from: date)
    }

    private var canShareWaypoints: Bool {
        radioGroup.canShareLocation && !radioGroupId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func memberUsing(color: WaypointPinColor) -> RadioGroupMember? {
        radioGroup.colorUsedByOtherActiveMember(color)
    }

    private func selectWaypointColor(_ color: WaypointPinColor) {
        if let member = memberUsing(color: color) {
            showToast("Color already in use by \(member.waypointDisplayLabel).", seconds: 2.4)
            return
        }

        defaultWaypointPinColorID = color.rawValue
        WaypointColorPreferences.mirrorToLocal(color)

        for index in waypoints.indices where !waypoints[index].isReceived {
            waypoints[index].colorID = color.rawValue
        }

        radioGroup.updateWaypointPinColorForCurrentUser(colorID: color.rawValue) { result in
            switch result {
            case .success:
                showToast("Waypoint color updated.", seconds: 2.0)
            case .failure:
                showToast("Unable to update Radio Group color.", seconds: 2.8)
            }
        }
    }

    private func toggleExportSelection(for id: UUID) {
        if selectedWaypointExportIDs.contains(id) {
            selectedWaypointExportIDs.remove(id)
        } else {
            selectedWaypointExportIDs.insert(id)
        }
    }

    private func exportGPXTapped() {
        let selected = waypoints
            .filter { selectedWaypointExportIDs.contains($0.id) && !$0.isReceived }
            .sorted { $0.createdAt < $1.createdAt }

        guard !selected.isEmpty else {
            exportAlertMessage = "Select at least one waypoint to export."
            showExportAlert = true
            return
        }

        exportDocument = WaypointGPXExportDocument(data: WaypointGPXBuilder.makeData(for: selected))
        exportSuggestedFilename = WaypointGPXBuilder.defaultFilename()
        isPresentingGPXExporter = true
    }

    private func sendWaypointToGroup(_ wp: Waypoint) {
        guard canShareWaypoints else {
            showToast("Must be part of a Radio Group to send", seconds: 3.0)
            return
        }

        if wp.sentToGroup {
            pendingReshare = wp
            return
        }

        func performSend(_ w: Waypoint) {
            // Visual tap animation
            animatingSendIDs.insert(w.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                animatingSendIDs.remove(w.id)
            }

            radioGroup.sendWaypointToActiveGroup(w)

            // Flip local UI flag so the shared status icon turns white on black.
            if let idx = waypoints.firstIndex(where: { $0.id == w.id }) {
                waypoints[idx].sentToGroup = true
            }

            showToast("Waypoint shared.", seconds: 2.0)
        }
        performSend(wp)
    }

    private func resendWaypointToGroup(_ wp: Waypoint) {
        guard canShareWaypoints else {
            showToast("Must be part of a Radio Group to send", seconds: 3.0)
            return
        }

        // Visual tap animation
        animatingSendIDs.insert(wp.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            animatingSendIDs.remove(wp.id)
        }

        // IMPORTANT: re-share as a NEW Firestore document so receivers who previously hid the old one
        // will still see this resend.
        radioGroup.sendWaypointToActiveGroup(wp, forceNewDoc: true)
        showToast("Waypoint shared.", seconds: 2.0)
    }

    private func shareIconView(for wp: Waypoint) -> some View {
        let disabled = !canShareWaypoints
        let animating = animatingSendIDs.contains(wp.id)
        let iconColor: Color = {
            if disabled { return .gray }
            return wp.sentToGroup ? .white : wp.pinColor.swiftUIColor
        }()

        return ZStack {
            Image(systemName: wp.sentToGroup ? "paperplane" : "paperplane.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(iconColor)
        }
        .frame(width: waypointActionBoxWidth, height: waypointActionBoxHeight)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: waypointActionCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: waypointActionCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .scaleEffect(animating ? 0.92 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: animating)
        .opacity(disabled ? 0.75 : 1.0)
    }

    private func receivedNameBinding(for id: String, fallback: String) -> Binding<String> {
        Binding<String>(
            get: { receivedNameOverrides[id] ?? fallback },
            set: { receivedNameOverrides[id] = $0 }
        )
    }

    private var waypointActionCornerRadius: CGFloat { 10 }

    private func waypointNameField(
        _ placeholder: String,
        text: Binding<String>,
        isFocused: Bool,
        focusAction: @escaping () -> Void
    ) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: waypointNameFieldWidth, height: selectorHeight)
            .background(isFocused ? Color.white : Color.white.opacity(0.14))
            .foregroundColor(isFocused ? Color.black : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
            .tint(isFocused ? .black : .white)
            .onTapGesture(perform: focusAction)
    }

    private func waypointDateBox(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundColor(scTextPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: selectorHeight, maxHeight: selectorHeight, alignment: .leading)
            .background(Color.white.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
            .allowsHitTesting(false)
            .layoutPriority(1)
    }

    private func actionBoxBackground(opacity: Double = 0.14, borderOpacity: Double = 0.10) -> some View {
        RoundedRectangle(cornerRadius: waypointActionCornerRadius, style: .continuous)
            .fill(Color.white.opacity(opacity))
            .overlay(
                RoundedRectangle(cornerRadius: waypointActionCornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(borderOpacity), lineWidth: 1)
            )
    }

    private func waypointExportCheckbox(for waypoint: Waypoint) -> some View {
        Image(systemName: selectedWaypointExportIDs.contains(waypoint.id) ? "checkmark.square.fill" : "square")
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundColor(selectedWaypointExportIDs.contains(waypoint.id) ? .white : .white.opacity(0.72))
            .frame(width: waypointExportCheckboxWidth, height: waypointActionBoxHeight)
            .background(actionBoxBackground())
    }

    private func receivedExportPlaceholder() -> some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundColor(.white.opacity(0.42))
            .frame(width: waypointExportCheckboxWidth, height: waypointActionBoxHeight)
            .background(actionBoxBackground(opacity: 0.08, borderOpacity: 0.08))
    }

    private func deleteActionBox(isFlashingRed: Bool) -> some View {
        SatChartDeleteIcon(isFlashingRed: isFlashingRed, defaultColor: .white)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .frame(width: waypointActionBoxWidth, height: waypointActionBoxHeight)
            .background(actionBoxBackground())
    }

    private var headerRow: some View {
        HStack(spacing: waypointRowSpacing) {
            Text("Name")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(
                    width: waypointPinColumnWidth + waypointRowSpacing + waypointNameFieldWidth,
                    alignment: .leading
                )

            Text("Date")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: waypointRowSpacing) {
                Text("Share")
                    .frame(width: waypointActionBoxWidth)
                Text("GPX")
                    .frame(width: waypointExportCheckboxWidth)
                Text("Del")
                    .frame(width: waypointActionBoxWidth)
            }
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .minimumScaleFactor(0.70)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
        }
        .frame(height: 44)
        .padding(.horizontal, waypointCardContentPadding)
        .background(sectionBackground)
        .clipShape(RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous)
                .stroke(sectionBorder, lineWidth: 1)
        )
        .padding(.horizontal, waypointCardHorizontalPadding)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
    // Card surface and border for each row
    private var rowSurface: Color { sectionBackground }
    private var rowStroke: Color { sectionBorder }

    private func ownRow(_ wp: Binding<Waypoint>) -> some View {
        let w = wp.wrappedValue
        return HStack(spacing: waypointRowSpacing) {
            Image(systemName: "mappin")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(w.pinColor.swiftUIColor)
                .frame(width: waypointPinColumnWidth, alignment: .center)

            waypointNameField(
                "Name",
                text: wp.name,
                isFocused: focusedWaypointID == w.id,
                focusAction: { focusedWaypointID = w.id }
            )
                .focused($focusedWaypointID, equals: w.id)
                .onSubmit { focusedWaypointID = nil }

            waypointDateBox(formattedDate(w.createdAt))

            Spacer(minLength: 0)

            HStack(spacing: waypointRowSpacing) {
                Button { sendWaypointToGroup(w) } label: {
                    shareIconView(for: w)
                }
                .buttonStyle(SatChartPressFeedbackButtonStyle())

                Button {
                    toggleExportSelection(for: w.id)
                } label: {
                    waypointExportCheckbox(for: w)
                }
                .buttonStyle(SatChartPressFeedbackButtonStyle())

                SatChartDeleteConfirmationButton(
                    confirmationTitle: "Delete waypoint?",
                    confirmationMessage: "\(w.name.isEmpty ? "This waypoint" : w.name) will be permanently removed from this device."
                ) {
                    waypoints.removeAll { $0.id == w.id }
                    selectedWaypointExportIDs.remove(w.id)
                } label: { isFlashingRed in
                    deleteActionBox(isFlashingRed: isFlashingRed)
                }
                .buttonStyle(SatChartPressFeedbackButtonStyle())
            }
            .fixedSize(horizontal: true, vertical: true)
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 4, leading: waypointCardHorizontalPadding, bottom: 4, trailing: waypointCardHorizontalPadding))
        .listRowBackground(Color.clear)
        .padding(.horizontal, waypointCardContentPadding)
        .padding(.vertical, 8)
        .background(rowSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(rowStroke, lineWidth: 1)
        )
    }

    private func receivedRow(_ r: RadioGroupStore.GroupWaypoint) -> some View {
        return HStack(spacing: waypointRowSpacing) {
            Image(systemName: "mappin")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(r.pinColor.swiftUIColor)
                .frame(width: waypointPinColumnWidth, alignment: .center)

            waypointNameField(
                "Name",
                text: receivedNameBinding(for: r.id, fallback: r.name),
                isFocused: focusedReceivedWaypointID == r.id,
                focusAction: { focusedReceivedWaypointID = r.id }
            )
                .focused($focusedReceivedWaypointID, equals: r.id)
                .onSubmit { focusedReceivedWaypointID = nil }

            waypointDateBox(formattedDate(r.createdAt))

            Spacer(minLength: 0)

            HStack(spacing: waypointRowSpacing) {
                Button {
                    showToast("Cannot share a received waypoint", seconds: 2.5)
                } label: {
                    ZStack {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(r.pinColor.swiftUIColor)
                    }
                    .frame(width: waypointActionBoxWidth, height: waypointActionBoxHeight)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: waypointActionCornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: waypointActionCornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
                }
                .buttonStyle(SatChartPressFeedbackButtonStyle())

                Button {
                    showToast("Received waypoints cannot be exported.", seconds: 2.2)
                } label: {
                    receivedExportPlaceholder()
                }
                .buttonStyle(SatChartPressFeedbackButtonStyle())

                SatChartDeleteConfirmationButton(
                    confirmationTitle: "Delete received waypoint from your view?",
                    confirmationMessage: "This only hides the received waypoint on this device."
                ) {
                    radioGroup.hideReceivedWaypoint(id: r.id)
                    showToast("Removed from your view.", seconds: 2.0)
                } label: { isFlashingRed in
                    deleteActionBox(isFlashingRed: isFlashingRed)
                }
                .buttonStyle(SatChartPressFeedbackButtonStyle())
            }
            .fixedSize(horizontal: true, vertical: true)
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 4, leading: waypointCardHorizontalPadding, bottom: 4, trailing: waypointCardHorizontalPadding))
        .listRowBackground(Color.clear)
        .padding(.horizontal, waypointCardContentPadding)
        .padding(.vertical, 8)
        .background(rowSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(rowStroke, lineWidth: 1)
        )
    }

private var footerButtons: some View {
    VStack(spacing: 10) {
        Button {
            exportGPXTapped()
        } label: {
            Text("Export GPX")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: selectorHeight, maxHeight: selectorHeight)
                .background(exportButtonBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
        .disabled(!canExportGPX)

        Button(role: .destructive) {
            showConfirmDeleteAllReceived = true
        } label: {
            Text("Delete All Waypoints Received")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, minHeight: selectorHeight, maxHeight: selectorHeight, alignment: .center)
                .padding(.horizontal, 12)
                .background(Color.white.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())

        Button(role: .destructive) {
            showConfirmDeleteAll = true
        } label: {
            Text("Delete All Waypoints")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, minHeight: selectorHeight, maxHeight: selectorHeight, alignment: .center)
                .padding(.horizontal, 12)
                .background(Color.white.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
    }
    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    .listRowBackground(Color.clear)
}
private var legendView: some View {
    return VStack(alignment: .leading, spacing: 10) {
        Text("Location Pin Legend")
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .underline(true, color: Color.white.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .center)

        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(WaypointPinColor.selectableCases) { color in
                legendColorRow(color)
            }
        }
    }
    .padding(14)
    .background(sectionBackground)
    .clipShape(RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous))
    .overlay(
        RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous)
            .stroke(sectionBorder, lineWidth: 1)
    )
    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 10, trailing: 12))
    .listRowBackground(Color.clear)
}

    private func legendColorRow(_ color: WaypointPinColor) -> some View {
        let myUid = radioGroup.currentUserID
        let currentMember = radioGroup.activeMembers.first { $0.uid == myUid && $0.waypointPinColor == color }
        let otherMember = radioGroup.activeMembers.first { member in
            member.uid != myUid && member.waypointPinColor == color
        }
        let isCurrent = color == currentWaypointColor
        let label: String? = {
            if let currentMember { return currentMember.waypointDisplayLabel }
            if isCurrent { return currentUserLabel }
            if let otherMember { return otherMember.waypointDisplayLabel }
            return nil
        }()
        let isReservedByOther = otherMember != nil

        return HStack(spacing: 7) {
            Image(systemName: "mappin")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(color.swiftUIColor)
                .frame(width: 14)

            Text(label ?? color.label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(isReservedByOther ? .white.opacity(0.78) : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.70)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isReservedByOther {
                EmptyView()
                    .frame(width: 18, height: 18)
            } else {
                Button {
                    selectWaypointColor(color)
                } label: {
                    Image(systemName: isCurrent ? "checkmark.square.fill" : "square")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(isCurrent ? .white : .white.opacity(0.62))
                }
                .buttonStyle(SatChartPressFeedbackButtonStyle())
                .frame(width: 18, height: 18)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Color.white.opacity(isCurrent ? 0.16 : 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isCurrent ? Color.white.opacity(0.24) : Color.white.opacity(0.08), lineWidth: 1)
        )
    }
    private var listView: some View {
        List {
            Section {
                legendView
            }

            Section {
                ForEach($waypoints) { $wp in
                    ownRow($wp)
                }
            }

            Section {
                ForEach(radioGroup.receivedWaypoints.filter { !radioGroup.hiddenReceivedWaypointIDs.contains($0.id) }) { r in
                    receivedRow(r)
                }
            }

            Section {
                footerButtons
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .listRowBackground(Color.clear)
        .background(Color.clear)
    }

    private var waypointScreenBase: some View {
        ZStack {
            bbMenuBlue_MV.ignoresSafeArea()

            // Match the menu shell so exposed area above the tab bar stays menu blue.
            HostingBackgroundFixer(color: bbMenuBlueUIColor_MV)
                .frame(width: 0, height: 0)

            LinearGradient(
                colors: [menuPageBackgroundTop_MV, menuPageBackgroundBottom_MV],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: [.top, .leading, .trailing])

            VStack(spacing: 0) {
                headerRow
                listView
            }
            .background(Color.clear)
        }
    }

    @ViewBuilder
    private var waypointToastOverlay: some View {
        if let text = toastText {
            VStack {
                Spacer()
                Text(text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.bottom, 30)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var waypointReshareOverlay: some View {
        if let wp = pendingReshare {
            ZStack {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { pendingReshare = nil }

                VStack(spacing: 12) {
                    Text("Waypoint already shared, share again?")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 14) {
                        Button {
                            pendingReshare = nil
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SatChartPressFeedbackButtonStyle())

                        Button {
                            pendingReshare = nil
                            resendWaypointToGroup(wp)
                        } label: {
                            Text("Send Again")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.green)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SatChartPressFeedbackButtonStyle())
                    }
                }
                .padding(14)
                .frame(maxWidth: 320)
                .background(Color.black.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .padding(.horizontal, 24)
            }
            .transition(.opacity)
        }
    }

    var body: some View {
        waypointScreenBase
            .navigationTitle("Waypoints")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(bbMenuBlue_MV, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Waypoints")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .underline(true, color: Color.white.opacity(0.55))
                }
            }
            .onAppear { BBMenuAppearance.applyNavBar() }
            .confirmationDialog(
                "Delete all received waypoints from your view?",
                isPresented: $showConfirmDeleteAllReceived,
                titleVisibility: .visible
            ) {
                Button("Confirm Delete", role: .destructive) {
                    radioGroup.hideAllReceivedWaypoints()
                    showToast("Deleted all received waypoints (local).", seconds: 2.0)
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Delete ALL waypoints?",
                isPresented: $showConfirmDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Confirm Delete", role: .destructive) {
                    waypoints.removeAll()
                    selectedWaypointExportIDs.removeAll()
                    radioGroup.hideAllReceivedWaypoints()
                    showToast("Deleted all waypoints (local).", seconds: 2.0)
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("GPX Export", isPresented: $showExportAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportAlertMessage)
            }
            .fileExporter(
                isPresented: $isPresentingGPXExporter,
                document: exportDocument ?? WaypointGPXExportDocument(data: Data()),
                contentType: WaypointGPXExportDocument.gpxContentType,
                defaultFilename: exportSuggestedFilename
            ) { result in
                switch result {
                case .success:
                    break
                case .failure(let error):
                    exportAlertMessage = error.localizedDescription
                    showExportAlert = true
                }
            }
            .overlay { waypointToastOverlay }
            .overlay { waypointReshareOverlay }
    }
}
