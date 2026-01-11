import SwiftUI
import CoreLocation
import MapKit
import UIKit
import Combine
import Foundation
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


// MARK: - Shared Menu/Tab styling colors

private let bbMenuBlueUIColor_MV = UIColor(red: 0.03, green: 0.23, blue: 0.48, alpha: 1.0)
private let bbMenuBlue_MV = Color(uiColor: bbMenuBlueUIColor_MV)

// MARK: - MapView (main map screen)

struct MapView: View {

    @StateObject private var locationManager = LocationManager()
    @StateObject private var offline = OfflineMapsManager.shared

    @StateObject private var pinSettings = RadioGroupPinSettings()
    @StateObject private var radioGroup = RadioGroupStore()

    @State private var distanceText: String = "—"
    @State private var speedText: String = "—"
    @State private var metersPerPoint: Double = 0

    @State private var followReq: Int = 0
    @State private var recenterReq: Int = 0
    @State private var zoomInReq: Int = 0
    @State private var zoomOutReq: Int = 0

    @State private var tideBlend: Double = 0.0
    @State private var isFollowing: Bool = false

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

    // Sharing
    @AppStorage("radioPinDisplayName") private var radioPinDisplayName: String = ""
    @AppStorage("liveLocationUpdateOption") private var liveLocationUpdateOptionRaw: String = LiveLocationUpdateOption.oneMinute.rawValue

    @State private var showConfirmLiveShare: Bool = false
    @State private var showConfirmStopLiveShare: Bool = false
    @State private var showConfirmShareOnce: Bool = false
    @State private var shareOnceFlashUntil: Date? = nil

    @State private var toastMessage: String? = nil
    @State private var toastUntil: Date? = nil
    @State private var bigToastMessage: String? = nil
    @State private var bigToastUntil: Date? = nil

    @State private var liveShareTimer: AnyCancellable? = nil
    @State private var nowTick: Date = Date()

    private enum CoordField: Hashable {
        case latDeg, latMin, latHem
        case lonDeg, lonMin, lonHem
    }
    @FocusState private var focusedCoordField: CoordField?

    private var liveUpdateSeconds: TimeInterval {
        LiveLocationUpdateOption(rawValue: liveLocationUpdateOptionRaw)?.seconds
        ?? LiveLocationUpdateOption.oneMinute.seconds
    }

    // Waypoints
    @State private var waypoints: [Waypoint] = []

    // Menu sheet
    @State private var showMenu: Bool = false

    // Waypoint prompt
    @State private var showCreateWaypointPrompt: Bool = false
    @State private var pendingWaypointName: String = ""

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

    // MARK: - Sharing helpers

    private var liveShareStatusColor: Color {
        guard radioGroup.isLiveSharing else { return .red }
        if let last = radioGroup.lastLiveLocationSentAt {
            if nowTick.timeIntervalSince(last) > 5 * 60 { return .yellow }
            return .green
        }
        return .yellow
    }

    private var isShareOnceFlashing: Bool {
        if let until = shareOnceFlashUntil { return nowTick < until }
        return false
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

    private var isInRadioGroup: Bool {
        let gid = (UserDefaults.standard.string(forKey: "radioGroupId") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !gid.isEmpty
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

    private func sharingDisabledMessage() -> String {
        if !isInRadioGroup {
            return "Only Radio Group members can share location. Create or join to enable."
        }
        return "Location sharing is enabled when your active Radio Group has at least 2 members."
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
        guard radioGroup.isLiveSharing else { return }
        guard let coord = locationManager.userLocation else { return }
        radioGroup.upsertLivePin(coord, displayName: formattedPinName())
    }

    private func startLiveSharing() {
        guard radioGroup.canShareLocation else {
            showBigToast(sharingDisabledMessage(), seconds: 4.0)
            return
        }
        radioGroup.markLiveShared()
        maybeSendLivePin()
        liveShareTimer?.cancel()
        liveShareTimer = Timer.publish(every: liveUpdateSeconds, tolerance: 2, on: .main, in: .common)
            .autoconnect()
            .sink { _ in self.maybeSendLivePin() }
        showToast("Live location is now being shared.", seconds: 2.2)
    }

    private func stopLiveSharing() {
        liveShareTimer?.cancel()
        liveShareTimer = nil
        radioGroup.stopLiveSharing()
        showToast("Live location sharing stopped.", seconds: 1.8)
    }

    private func shareLocationOnce() {
        guard radioGroup.canShareLocation else {
            showBigToast(sharingDisabledMessage(), seconds: 4.0)
            return
        }
        guard let coord = locationManager.userLocation else { return }
        let until = Date().addingTimeInterval(5)
        shareOnceFlashUntil = until
        radioGroup.sendPin(coord, displayName: formattedPinName())
        showToast("Location pin sent.", seconds: 1.8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            if shareOnceFlashUntil == until { shareOnceFlashUntil = nil }
        }
    }

    // MARK: - Map layer

    private func handleMapAppear() {
        locationManager.requestPermission()
        locationManager.start()
        BBMenuAppearance.applyAll()
        syncCursorInputsFromCursor()
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
            tideBlend: $tideBlend,
            cursorCoordinate: $cursorCoordinate,
            cursorDistanceText: $cursorDistanceText,
            cursorCoordText: $cursorCoordText,
            cursorPanRequest: $cursorPanRequest,
            waypoints: $waypoints,
            receivedWaypoints: radioGroup.receivedWaypoints,
            radioPins: radioGroup.pins,
            zoomInRequest: $zoomInReq,
            zoomOutRequest: $zoomOutReq
        )
        .id("map-\(offline.downloadedTick)")
        .ignoresSafeArea()
        .onAppear(perform: handleMapAppear)
    }

    // MARK: - HUD + controls (unchanged UI)

    private var topHUD: some View {
        VStack(spacing: 0) { topHUDCard; Spacer(minLength: 0) }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var topHUDCard: some View {
        HStack(alignment: .top, spacing: 0) {
            topHUDShareButtons
            topHUDCursorContent
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 8)
        .background(scSurface.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .confirmationDialog("Share live location with Radio Group?", isPresented: $showConfirmLiveShare) {
            Button("Share Live") { startLiveSharing() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Stop sharing live location with Radio Group?", isPresented: $showConfirmStopLiveShare) {
            Button("Stop Sharing", role: .destructive) { stopLiveSharing() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Send Radio Group pin of current location?", isPresented: $showConfirmShareOnce) {
            Button("Send Pin") { shareLocationOnce() }
            Button("Cancel", role: .cancel) {}
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in nowTick = Date() }
        .onAppear { syncCursorInputsFromCursor() }
        .onChange(of: cursorCoordText) { _ in syncCursorInputsFromCursor() }
    }

    private var topHUDShareButtons: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Live share toggle
            Button {
                if radioGroup.isLiveSharing {
                    showConfirmStopLiveShare = true
                } else {
                    guard radioGroup.canShareLocation else {
                        showBigToast(sharingDisabledMessage(), seconds: 4.0)
                        return
                    }
                    showConfirmLiveShare = true
                }
            } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(MapIconButtonStyle(isActive: false, foreground: liveShareStatusColor))
            // Subtle disabled state (dim + desaturate) but keep enabled if live sharing is ON so user can stop.
            .opacity((radioGroup.canShareLocation || radioGroup.isLiveSharing) ? 1.0 : 0.35)
            .saturation((radioGroup.canShareLocation || radioGroup.isLiveSharing) ? 1.0 : 0.0)
            .disabled(!radioGroup.canShareLocation && !radioGroup.isLiveSharing)

            // One-time pin
            Button {
                guard radioGroup.canShareLocation else {
                    showBigToast(sharingDisabledMessage(), seconds: 4.0)
                    return
                }
                showToast("Confirm to send location pin.", seconds: 1.4)
                showConfirmShareOnce = true
            } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(MapIconButtonStyle(isActive: false, foreground: isShareOnceFlashing ? .green : .white))
            .opacity(radioGroup.canShareLocation ? 1.0 : 0.35)
            .saturation(radioGroup.canShareLocation ? 1.0 : 0.0)
            .disabled(!radioGroup.canShareLocation)
        }
        .padding(.leading, 2)
    }

    private var topHUDCursorContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            topHUDHeaderRow
            topHUDLatLonAndReadouts
            topHUDCurrentLocation
            if let msg = bigToastMessage, let until = bigToastUntil, Date() < until {
                Text(msg)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 10)
                    .background(scSurfaceAlt.opacity(0.92))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            }
            if let msg = toastMessage, let until = toastUntil, Date() < until {
                Text(msg)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(scTextPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
                    .padding(.top, -6)
            }
        }
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var topHUDHeaderRow: some View {
        HStack(spacing: 8) {
            Text("Cursor:")
                .padding(.leading, 12)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.95))
            Text(cursorCoordinate == nil ? "—" : (cursorDistanceText == "—" ? "—" : cursorDistanceText))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            Spacer(minLength: 0)
            Circle().fill(liveShareStatusColor).frame(width: 7, height: 7).opacity(0.95)
        }
    }

    private var topHUDLatLonAndReadouts: some View {
        HStack(alignment: .top, spacing: 12) { topHUDLatLonFields; Spacer(minLength: 0); topHUDRightReadouts }
    }

    private var topHUDRightReadouts: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text("Nearest boundary: \(distanceText)").hudBoxSmall()
            Text("Speed: \(speedText)").hudBoxSmall()
        }
        .layoutPriority(10)
        .padding(.trailing, 2)
    }

    private var topHUDCurrentLocation: some View {
        Text(locationText)
            .hudBoxSmall()
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(height: 34, alignment: .center)
            .padding(.leading, 12)
            .padding(.top, -16)
    }

    private var topHUDLatLonFields: some View {
        VStack(alignment: .leading, spacing: 6) { topHUDLatRow; topHUDLonRow }
    }

    private var topHUDLatRow: some View {
        HStack(spacing: 6) {
            coordTextField("Deg", text: $cursorLatDegInput, focused: .latDeg, width: 44)
            coordTextField("Min", text: $cursorLatMinInput, focused: .latMin, width: 70)
            hemTextField("N/S", text: $cursorLatHemInput, focused: .latHem)
        }
        .padding(.leading, 12)
    }

    private var topHUDLonRow: some View {
        HStack(spacing: 6) {
            coordTextField("Deg", text: $cursorLonDegInput, focused: .lonDeg, width: 44)
            coordTextField("Min", text: $cursorLonMinInput, focused: .lonMin, width: 70)
            hemTextField("E/W", text: $cursorLonHemInput, focused: .lonHem)
        }
        .padding(.leading, 12)
    }

    private func coordTextField(_ placeholder: String, text: Binding<String>, focused: CoordField, width: CGFloat) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .tint(.blue)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.characters)
            .keyboardType(.numbersAndPunctuation)
            .submitLabel(.done)
            .focused($focusedCoordField, equals: focused)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .frame(width: width, height: 20)
            .background(Color.white.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(focusedCoordField == focused ? Color.blue : Color.white.opacity(0.12), lineWidth: 1)
            )
            .onTapGesture { focusedCoordField = focused }
            .onSubmit { applyCursorInputsAndPan(); focusedCoordField = nil }
    }

    private func hemTextField(_ placeholder: String, text: Binding<String>, focused: CoordField) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .tint(.blue)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.characters)
            .keyboardType(.asciiCapable)
            .submitLabel(.done)
            .focused($focusedCoordField, equals: focused)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .frame(width: 38, height: 20)
            .background(Color.white.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(focusedCoordField == focused ? Color.blue : Color.white.opacity(0.12), lineWidth: 1)
            )
            .onTapGesture { focusedCoordField = focused }
            .onSubmit { applyCursorInputsAndPan(); focusedCoordField = nil }
    }

    private var bottomControls: some View {
        VStack { Spacer(); controlsStack }
    }

    private var controlsStack: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom) {
                Spacer()
                VStack(spacing: 10) {
                    Button { prepareWaypointPrompt(); showCreateWaypointPrompt = true } label: {
                        ZStack {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 18, weight: .semibold))
                                .symbolRenderingMode(.monochrome)
                                .foregroundColor(.white)
                            Image(systemName: "mappin.circle.fill")
                                .font(.system(size: 10, weight: .bold))
                                .symbolRenderingMode(.monochrome)
                                .foregroundColor(.red)
                                .offset(x: 0, y: -6)
                        }
                    }
                    .buttonStyle(MapIconButtonStyle())

                    Button { zoomInReq += 1 } label: { Image(systemName: "plus").font(.system(size: 18, weight: .semibold)) }
                        .buttonStyle(MapIconButtonStyle())
                    Button { zoomOutReq += 1 } label: { Image(systemName: "minus").font(.system(size: 18, weight: .semibold)) }
                        .buttonStyle(MapIconButtonStyle())
                }
                .padding(.trailing, 10)
            }

            HStack(spacing: 10) {
                Button { isFollowing.toggle(); followReq += 1 } label: {
                    Image(systemName: isFollowing ? "location.fill" : "location").font(.system(size: 18, weight: .semibold))
                }
                .buttonStyle(MapIconButtonStyle(isActive: isFollowing))

                Button { recenterReq += 1 } label: { Image(systemName: "scope").font(.system(size: 18, weight: .semibold)) }
                    .buttonStyle(MapIconButtonStyle())

                NavigationLink(destination: OfflineMapsView()) {
                    Image(systemName: "externaldrive").font(.system(size: 18, weight: .semibold))
                }
                .buttonStyle(MapIconButtonStyle())

                Button { BBMenuAppearance.applyAll(); showMenu = true } label: {
                    Image(systemName: "line.3.horizontal").font(.system(size: 18, weight: .semibold))
                }
                .buttonStyle(MapIconButtonStyle())

                Picker("", selection: $tideBlend) {
                    Text("Map1").tag(0.0)
                    Text("Map2").tag(1.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 160, height: 48)
                .tint(.blue)
                .foregroundColor(.white)
                .colorScheme(.dark)
                .background(scSurface.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1))
            }
            .padding(.leading, 10)

            HStack { Spacer(); ThinScaleBar(metersPerPoint: metersPerPoint); Spacer() }
                .padding(.top, 2)
        }
        .padding(.bottom, -6)
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

    var body: some View {
        NavigationStack {
            ZStack { mapLayer; topHUD; bottomControls; waypointPromptOverlay }
                .onDisappear { liveShareTimer?.cancel(); liveShareTimer = nil }
                .sheet(isPresented: $showMenu) {
                    AppMenuTabsView(waypoints: $waypoints)
                        .environmentObject(pinSettings)
                        .environmentObject(radioGroup)
                        .onAppear { BBMenuAppearance.applyAll() }
                }
        }
    }

    private func prepareWaypointPrompt() { pendingWaypointName = "\(waypoints.count + 1)" }

    private func createWaypoint(named name: String) {
        let coord = cursorCoordinate ?? locationManager.userLocation
        guard let coord else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "\(waypoints.count + 1)" : trimmed
        waypoints.append(Waypoint(name: finalName, notes: "", coordinate: coord, createdAt: Date()))
    }

    private var locationText: String {
        if let coord = locationManager.userLocation { return degreesDecimalMinutes(coord) }
        return "—"
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
}

// MARK: - Menu Tabs

enum MenuTab: Hashable { case menu, waypoints, radioGroup }

struct AppMenuTabsView: View {
    @Binding var waypoints: [Waypoint]
    @EnvironmentObject var pinSettings: RadioGroupPinSettings
    @EnvironmentObject var radioGroup: RadioGroupStore
    @State private var selection: MenuTab = .menu

    init(waypoints: Binding<[Waypoint]>) {
        self._waypoints = waypoints
        BBMenuAppearance.applyAll()
    }

    var body: some View {
        TabView(selection: $selection) {
            MenuHomeTab(selection: $selection)
                .environmentObject(pinSettings)
                .tabItem { Label("Menu", systemImage: "line.3.horizontal") }
                .tag(MenuTab.menu)

            NavigationStack { WaypointsView(waypoints: $waypoints).environmentObject(radioGroup) }
                .tabItem { Label("Waypoints", systemImage: "list.bullet") }
                .tag(MenuTab.waypoints)

            NavigationStack {
                RadioGroupView()
                    .environmentObject(pinSettings)
                    .environmentObject(radioGroup)
            }
            .tabItem { Label("Radio Group", systemImage: "antenna.radiowaves.left.and.right") }
            .tag(MenuTab.radioGroup)
        }
        .background(scBackground.ignoresSafeArea())
        .tint(.white)
        .modifier(TabBarBlueBackgroundModifier())
        .overlay(TabBarControllerConfigurator().frame(width: 0, height: 0))
        .onAppear { selection = .menu; BBMenuAppearance.applyAll() }
    }
}


struct MenuHomeTab: View {
    @Binding var selection: MenuTab

    var body: some View {
        NavigationStack {
            List {
                Button { selection = .waypoints } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "list.bullet").font(.system(size: 16, weight: .semibold))
                        Text("Waypoints").font(.system(size: 14, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .foregroundColor(.white)
                    .background(scSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Button { selection = .radioGroup } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 16, weight: .semibold))
                        Text("Radio Group").font(.system(size: 14, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .foregroundColor(.white)
                    .background(scSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .scrollContentBackground(.hidden)
            .background(scBackground)
            .listStyle(.plain)
            .toolbarBackground(bbMenuBlue_MV, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Menu").font(.system(size: 17, weight: .semibold)).foregroundColor(.white).underline()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { BBMenuAppearance.applyNavBar() }
        }
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
            .buttonStyle(.plain)
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { isFocused = true } }
        }
    }
}

// MARK: - Thin scale bar wrapper

struct ThinScaleBar: View {
    let metersPerPoint: Double
    var body: some View { NauticalScaleBar(metersPerPoint: metersPerPoint).scaleEffect(0.9).opacity(0.95) }
}

// MARK: - Button styles

struct MapIconButtonStyle: ButtonStyle {
    var isActive: Bool = false
    var foreground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        let base = Color.black.opacity(0.60)
        let active = Color.blue.opacity(0.55)
        let pressed = Color.blue.opacity(0.35)

        return configuration.label
            .frame(width: 48, height: 48)
            .background(configuration.isPressed ? pressed : (isActive ? active : base))
            .foregroundColor(foreground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}

struct MapPromptActionButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        let base = Color.black.opacity(0.60)
        let primaryBase = Color.blue.opacity(0.55)
        let pressed = Color.blue.opacity(0.35)

        return configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .frame(height: 36)
            .padding(.horizontal, 10)
            .background(configuration.isPressed ? pressed : (kind == .primary ? primaryBase : base))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}

// Note: `hudBoxSmall()` is used by MapView HUD readouts; WaypointsView has its own styling below.
private extension View {
    func hudBoxSmall() -> some View {
        self
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(scSurface.opacity(0.70))
            .foregroundColor(scTextPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct WaypointsView: View {

    @Binding var waypoints: [Waypoint]

    @EnvironmentObject var radioGroup: RadioGroupStore
    @AppStorage("radioGroupId") private var radioGroupId: String = ""

    @State private var pendingDeleteOwn: Waypoint? = nil
    @State private var pendingDeleteReceivedID: String? = nil
    @FocusState private var focusedWaypointID: UUID?

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

    // Legend
    @AppStorage("radioPinDisplayName") private var radioPinDisplayName: String = ""

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

            // Flip local UI flag (black plane appears next to green)
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

        radioGroup.sendWaypointToActiveGroup(wp)
        showToast("Waypoint shared.", seconds: 2.0)
    }

    private func shareIconView(for wp: Waypoint) -> some View {
        let disabled = !canShareWaypoints
        let animating = animatingSendIDs.contains(wp.id)

        return HStack(spacing: 4) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(disabled ? Color.gray : Color.green)

            if wp.sentToGroup {
                Image(systemName: "paperplane")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .frame(width: 60, height: 28)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .scaleEffect(animating ? 0.92 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: animating)
        .opacity(disabled ? 0.75 : 1.0)
    }

    private func pinColorForSender(_ senderUid: String) -> Color {
        // Stable, deterministic palette by sender uid
        let palette: [Color] = [.green, .orange, .yellow, .pink, .purple, .cyan, .mint]
        let h = abs(senderUid.hashValue)
        return palette[h % palette.count]
    }

    private func receivedNameBinding(for id: String, fallback: String) -> Binding<String> {
        Binding<String>(
            get: { receivedNameOverrides[id] ?? fallback },
            set: { receivedNameOverrides[id] = $0 }
        )
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            Text("Name")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(scTextPrimary)
                .frame(width: 120, alignment: .leading)

            Text("Date")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(scTextPrimary)
                .frame(width: 78, alignment: .leading)

            Text("Share")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(scTextPrimary)
                .frame(width: 70, alignment: .center)

            Text("Delete")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(scTextPrimary)
                .frame(width: 70, alignment: .trailing)
        }
        .frame(height: 44)
        .padding(.horizontal, 14)
        .background(bbMenuBlue_MV)
        .overlay(Rectangle().stroke(Color.black.opacity(0.70), lineWidth: 1))
    }

    // Card surface and border for each row
    private var rowSurface: Color { scSurface }
    private var rowStroke: Color { Color.white.opacity(0.18) }

    private func ownRow(_ wp: Binding<Waypoint>) -> some View {
        let w = wp.wrappedValue
        return HStack(spacing: 10) {
            // Colored pin (own = red)
            Image(systemName: "mappin")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.red)
                .frame(width: 14, alignment: .center)

            TextField("Name", text: wp.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.black)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(width: 108)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.black.opacity(0.20), lineWidth: 1)
                )
                .focused($focusedWaypointID, equals: w.id)
                .tint(.black)

            Text(formattedDate(w.createdAt))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(width: 74, alignment: .leading)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.black.opacity(0.20), lineWidth: 1)
                )

            Button { sendWaypointToGroup(w) } label: {
                shareIconView(for: w)
            }
            .buttonStyle(.plain)

            Button(role: .destructive) { pendingDeleteOwn = w } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.red)
                    .frame(width: 34, height: 28)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.black.opacity(0.20), lineWidth: 1)
                    )
            }
            .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowBackground(Color.clear)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(rowSurface.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(rowStroke, lineWidth: 1.2)
        )
    }

    private func receivedRow(_ r: RadioGroupStore.GroupWaypoint) -> some View {
        return HStack(spacing: 10) {
            Image(systemName: "mappin")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(pinColorForSender(r.senderUid))
                .frame(width: 14, alignment: .center)

            TextField("Name", text: receivedNameBinding(for: r.id, fallback: r.name))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.black)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(width: 108)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.black.opacity(0.20), lineWidth: 1)
                )
                .tint(.black)

            Text(formattedDate(r.createdAt))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(width: 74, alignment: .leading)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.black.opacity(0.20), lineWidth: 1)
                )

            // Not shareable from here
            HStack(spacing: 4) {
                Image(systemName: "paperplane")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.gray)
            }
            .frame(width: 60, height: 28)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.20), lineWidth: 1)
            )

            Button(role: .destructive) {
                pendingDeleteReceivedID = r.id
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.red)
                    .frame(width: 34, height: 28)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.black.opacity(0.20), lineWidth: 1)
                    )
            }
            .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowBackground(Color.clear)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(rowSurface.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(rowStroke, lineWidth: 1.2)
        )
    }

    private var footerButtons: some View {
        VStack(spacing: 10) {
            Button(role: .destructive) {
                showConfirmDeleteAllReceived = true
            } label: {
                Text("Delete All Waypoints Received")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.gray)

            Button(role: .destructive) {
                showConfirmDeleteAll = true
            } label: {
                Text("Delete All Waypoints")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.gray)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .listRowBackground(Color.clear)
    }

    private var legendView: some View {
        let meNameRaw = radioPinDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let meName = meNameRaw.isEmpty ? "Me" : meNameRaw

        // Only include visible (not hidden) received waypoints.
        let visibleReceived = radioGroup.receivedWaypoints
            .filter { !radioGroup.hiddenReceivedWaypointIDs.contains($0.id) }

        // Unique senders currently present in the received list.
        // If senderName is missing, fall back to a stable short id.
        let senders: [(uid: String, name: String)] = {
            var bestNameByUid: [String: String] = [:]
            for wp in visibleReceived {
                let uid = wp.senderUid.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !uid.isEmpty else { continue }

                let nm = wp.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !nm.isEmpty {
                    bestNameByUid[uid] = nm
                } else if bestNameByUid[uid] == nil {
                    bestNameByUid[uid] = "Member \(uid.prefix(6))"
                }
            }

            return bestNameByUid
                .map { (uid: $0.key, name: $0.value) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }()

        return VStack(alignment: .leading, spacing: 8) {
            Text("Location Pin Legend")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(scTextPrimary)

            HStack(spacing: 8) {
                Image(systemName: "mappin")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.red)
                Text(meName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(scTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(senders, id: \.uid) { s in
                HStack(spacing: 8) {
                    Image(systemName: "mappin")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(pinColorForSender(s.uid))
                    Text(s.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(scTextPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(scSurface.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1.2)
        )
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 10, trailing: 12))
        .listRowBackground(Color.clear)
    }

    private var listView: some View {
        List {
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

            Section {
                legendView
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .listRowBackground(Color.clear)
        .background(scBackground)
        .ignoresSafeArea(.container, edges: .bottom)
    }

    var body: some View {
        ZStack {
            scBackground.ignoresSafeArea()

            // Match RadioGroupView: force the underlying hosting/container backgrounds to the theme color
            HostingBackgroundFixer(color: UIColor(scBackground))
                .frame(width: 0, height: 0)

            VStack(spacing: 0) {
                headerRow
                listView
            }
        }
        .navigationTitle("Waypoints")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(bbMenuBlue_MV, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Waypoints")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .underline()
            }
        }
        .onAppear { BBMenuAppearance.applyNavBar() }
        .confirmationDialog(
            "Delete waypoint?",
            isPresented: Binding(
                get: { pendingDeleteOwn != nil },
                set: { if !$0 { pendingDeleteOwn = nil } }
            )
        ) {
            Button("Confirm Delete", role: .destructive) {
                guard let del = pendingDeleteOwn else { return }
                waypoints.removeAll { $0.id == del.id }
                pendingDeleteOwn = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteOwn = nil }
        }
        .confirmationDialog(
            "Remove received waypoint from your view?",
            isPresented: Binding(
                get: { pendingDeleteReceivedID != nil },
                set: { if !$0 { pendingDeleteReceivedID = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                guard let id = pendingDeleteReceivedID else { return }
                radioGroup.hideReceivedWaypoint(id: id)
                pendingDeleteReceivedID = nil
                showToast("Removed from your view.", seconds: 2.0)
            }
            Button("Cancel", role: .cancel) { pendingDeleteReceivedID = nil }
        }
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
                radioGroup.hideAllReceivedWaypoints()
                showToast("Deleted all waypoints (local).", seconds: 2.0)
            }
            Button("Cancel", role: .cancel) {}
        }
        .overlay(
            Group {
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
        )
        .overlay(
            Group {
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
                                .buttonStyle(.plain)

                                Button {
                                    // Send again
                                    pendingReshare = nil
                                    resendWaypointToGroup(wp)
                                } label: {
                                    Text("Send Again")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.green)
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.plain)
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
        )
    }
}
