import SwiftUI
import CoreLocation
import MapKit
import UIKit

// MARK: - Shared Menu/Tab styling

/// Darker blue than `systemBlue` for consistent Menu + Waypoints nav/tab bars.
private let bbMenuBlueUIColor = UIColor(red: 0.03, green: 0.23, blue: 0.48, alpha: 1.0)
private let bbMenuBlue = Color(uiColor: bbMenuBlueUIColor)

private enum BBMenuAppearance {

    static func applyNavBar() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = bbMenuBlueUIColor
        nav.shadowColor = UIColor.black.withAlphaComponent(0.70) // thin black bottom line

        let titleFont = UIFont.systemFont(ofSize: 17, weight: .semibold)
        nav.titleTextAttributes = [
            .foregroundColor: UIColor.white,
            .font: titleFont
        ]
        nav.largeTitleTextAttributes = [
            .foregroundColor: UIColor.white,
            .font: UIFont.systemFont(ofSize: 34, weight: .bold)
        ]

        let bar = UINavigationBar.appearance()
        bar.standardAppearance = nav
        bar.scrollEdgeAppearance = nav
        bar.compactAppearance = nav
        bar.tintColor = .white
    }

    /// IMPORTANT: call this BEFORE the TabView is created (i.e., before presenting the sheet)
    static func applyTabBar() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = bbMenuBlueUIColor
        appearance.shadowColor = UIColor.black.withAlphaComponent(0.70) // thin black outline

        // Selection pill (slightly darker than the tab bar) + thin black stroke
        let indicatorFill = UIColor(red: 0.02, green: 0.18, blue: 0.40, alpha: 1.0)
        let indicator = UIImage.selectionIndicator(
            fill: indicatorFill,
            stroke: UIColor.black.withAlphaComponent(0.88),
            lineWidth: 1.5,
            size: CGSize(width: 82, height: 30),
            cornerRadius: 12
        )

        appearance.selectionIndicatorImage = indicator.resizableImage(
            withCapInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12),
            resizingMode: .stretch
        )

        let font = UIFont.systemFont(ofSize: 8, weight: .semibold)

        let layouts: [UITabBarItemAppearance] = [
            appearance.stackedLayoutAppearance,
            appearance.inlineLayoutAppearance,
            appearance.compactInlineLayoutAppearance
        ]

        for item in layouts {
            item.normal.iconColor = UIColor.white
            item.normal.titleTextAttributes = [
                .foregroundColor: UIColor.white,
                .font: font
            ]

            item.selected.iconColor = UIColor.white
            item.selected.titleTextAttributes = [
                .foregroundColor: UIColor.white,
                .font: font
            ]
        }

        let tabBar = UITabBar.appearance()
        tabBar.standardAppearance = appearance
        if #available(iOS 15.0, *) {
            tabBar.scrollEdgeAppearance = appearance
        }
        tabBar.isTranslucent = false
        tabBar.tintColor = UIColor.white
        tabBar.unselectedItemTintColor = UIColor.white

        // “Shorter” feel
        let item = UITabBarItem.appearance()
        item.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: -5)
        item.imageInsets = UIEdgeInsets(top: -3, left: 0, bottom: 3, right: 0)
    }

    static func applyAll() {
        applyNavBar()
        applyTabBar()
    }
}

// MARK: - MapView

struct MapView: View {

    @StateObject private var locationManager = LocationManager()
    @StateObject private var offline = OfflineMapsManager.shared

    @State private var distanceText: String = "—"
    @State private var speedText: String = "—"
    @State private var metersPerPoint: Double = 0

    @State private var followReq: Int = 0
    @State private var recenterReq: Int = 0

    @State private var zoomInReq: Int = 0
    @State private var zoomOutReq: Int = 0

    // 0 = Lowest (v1), 1 = Low (v2)
    @State private var tideBlend: Double = 0.0

    @State private var isFollowing: Bool = false

    // Cursor
    @State private var cursorCoordinate: CLLocationCoordinate2D? = nil
    @State private var cursorDistanceText: String = "—"
    @State private var cursorCoordText: String = "—"
    // Cursor input fields (split into Degrees / Minutes / Hemisphere)
    @State private var cursorLatDegInput: String = ""
    @State private var cursorLatMinInput: String = ""
    @State private var cursorLatHemInput: String = "N"   // N or S

    @State private var cursorLonDegInput: String = ""
    @State private var cursorLonMinInput: String = ""
    @State private var cursorLonHemInput: String = "W"   // E or W
    @State private var cursorPanRequest: Int = 0

    private enum CoordField: Hashable {
        case latDeg, latMin, latHem
        case lonDeg, lonMin, lonHem
    }
    @FocusState private var focusedCoordField: CoordField?

    // Measured height of the top-right HUD stack (so cursor box can match it)
    @State private var topHUDHeight: CGFloat = 0

    // Waypoints
    @State private var waypoints: [Waypoint] = []

    // Menu (tabs) page
    @State private var showMenu: Bool = false

    // Create waypoint prompt
    @State private var showCreateWaypointPrompt: Bool = false
    @State private var pendingWaypointName: String = ""

    private struct HUDHeightPreferenceKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    // MARK: - Cursor coordinate lines (stack N over W)

    private var cursorLatLine: String { cursorLines(from: cursorCoordText).lat }
    private var cursorLonLine: String? { cursorLines(from: cursorCoordText).lon }

    private func cursorLines(from text: String) -> (lat: String, lon: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "—" else { return ("—", nil) }

        // Preferred format: "47° 41.301' N  122° 22.304' W"
        let halves = trimmed.components(separatedBy: "  ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if halves.count >= 2 { return (halves[0], halves[1]) }

        let parts = trimmed.split(separator: " ").map(String.init)
        if parts.count >= 6 {
            let lat = "\(parts[0]) \(parts[1]) \(parts[2])"
            let lon = "\(parts[3]) \(parts[4]) \(parts[5])"
            return (lat, lon)
        }

        return (trimmed, nil)
    }

    // MARK: - Cursor coordinate input (Degrees / Minutes / Hemisphere parsing + formatting)

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
        guard let lat = parseLatComponents(), let lon = parseLonComponents() else {
            return
        }
        cursorCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        cursorPanRequest += 1
    }

    // MARK: - View helpers (break up body for compiler)

    private func handleMapAppear() {
        locationManager.requestPermission()
        locationManager.start()
        BBMenuAppearance.applyAll()
        if cursorLatDegInput.isEmpty || cursorLatMinInput.isEmpty || cursorLonDegInput.isEmpty || cursorLonMinInput.isEmpty {
            syncCursorInputsFromCursor()
        }
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
            zoomInRequest: $zoomInReq,
            zoomOutRequest: $zoomOutReq
        )
        .id("map-\(offline.downloadedTick)")
        .ignoresSafeArea()
        .onAppear(perform: handleMapAppear)
    }

    private var keyboardDoneToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") {
                applyCursorInputsAndPan()
                focusedCoordField = nil
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil,
                    from: nil,
                    for: nil
                )
            }
        }
    }

    // MARK: - Subviews (helps the SwiftUI type-checker)

    private var topHUD: some View {
        HStack(alignment: .top, spacing: 6) {

            // Cursor box
            VStack(alignment: .leading, spacing: 4) {
                Text("Cursor")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.95))

                if cursorCoordinate == nil {
                    Text("—")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                } else {
                    Text(cursorDistanceText == "—" ? "—" : cursorDistanceText)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)

                    // Editable coordinate fields (Degrees / Minutes / Hemisphere)
                    VStack(alignment: .leading, spacing: 6) {

                        // LAT
                        HStack(spacing: 6) {
                            TextField("Deg", text: $cursorLatDegInput)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                                .tint(.blue)
                                .autocorrectionDisabled(true)
                                .textInputAutocapitalization(.characters)
                                .keyboardType(.numbersAndPunctuation)
                                .submitLabel(.done)
                                .focused($focusedCoordField, equals: .latDeg)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .frame(width: 44, height: 22)
                                .background(Color.white.opacity(0.16))
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(focusedCoordField == .latDeg ? Color.blue : Color.white.opacity(0.12), lineWidth: 1)
                                )
                                .onTapGesture { focusedCoordField = .latDeg }
                                .onSubmit { applyCursorInputsAndPan(); focusedCoordField = nil }

                            TextField("Min", text: $cursorLatMinInput)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                                .tint(.blue)
                                .autocorrectionDisabled(true)
                                .textInputAutocapitalization(.characters)
                                .keyboardType(.numbersAndPunctuation)
                                .submitLabel(.done)
                                .focused($focusedCoordField, equals: .latMin)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .frame(width: 70, height: 22)
                                .background(Color.white.opacity(0.16))
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(focusedCoordField == .latMin ? Color.blue : Color.white.opacity(0.12), lineWidth: 1)
                                )
                                .onTapGesture { focusedCoordField = .latMin }
                                .onSubmit { applyCursorInputsAndPan(); focusedCoordField = nil }

                            TextField("N/S", text: $cursorLatHemInput)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                                .tint(.blue)
                                .autocorrectionDisabled(true)
                                .textInputAutocapitalization(.characters)
                                .keyboardType(.asciiCapable)
                                .submitLabel(.done)
                                .focused($focusedCoordField, equals: .latHem)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .frame(width: 38, height: 22)
                                .background(Color.white.opacity(0.16))
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(focusedCoordField == .latHem ? Color.blue : Color.white.opacity(0.12), lineWidth: 1)
                                )
                                .onTapGesture { focusedCoordField = .latHem }
                                .onSubmit { applyCursorInputsAndPan(); focusedCoordField = nil }
                        }

                        // LON
                        HStack(spacing: 6) {
                            TextField("Deg", text: $cursorLonDegInput)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                                .tint(.blue)
                                .autocorrectionDisabled(true)
                                .textInputAutocapitalization(.characters)
                                .keyboardType(.numbersAndPunctuation)
                                .submitLabel(.done)
                                .focused($focusedCoordField, equals: .lonDeg)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .frame(width: 44, height: 22)
                                .background(Color.white.opacity(0.16))
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(focusedCoordField == .lonDeg ? Color.blue : Color.white.opacity(0.12), lineWidth: 1)
                                )
                                .onTapGesture { focusedCoordField = .lonDeg }
                                .onSubmit { applyCursorInputsAndPan(); focusedCoordField = nil }

                            TextField("Min", text: $cursorLonMinInput)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                                .tint(.blue)
                                .autocorrectionDisabled(true)
                                .textInputAutocapitalization(.characters)
                                .keyboardType(.numbersAndPunctuation)
                                .submitLabel(.done)
                                .focused($focusedCoordField, equals: .lonMin)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .frame(width: 70, height: 22)
                                .background(Color.white.opacity(0.16))
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(focusedCoordField == .lonMin ? Color.blue : Color.white.opacity(0.12), lineWidth: 1)
                                )
                                .onTapGesture { focusedCoordField = .lonMin }
                                .onSubmit { applyCursorInputsAndPan(); focusedCoordField = nil }

                            TextField("E/W", text: $cursorLonHemInput)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                                .tint(.blue)
                                .autocorrectionDisabled(true)
                                .textInputAutocapitalization(.characters)
                                .keyboardType(.asciiCapable)
                                .submitLabel(.done)
                                .focused($focusedCoordField, equals: .lonHem)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .frame(width: 38, height: 22)
                                .background(Color.white.opacity(0.16))
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(focusedCoordField == .lonHem ? Color.blue : Color.white.opacity(0.12), lineWidth: 1)
                                )
                                .onTapGesture { focusedCoordField = .lonHem }
                                .onSubmit { applyCursorInputsAndPan(); focusedCoordField = nil }
                        }
                    }
                    .onAppear {
                        // Populate fields with the current cursor coordinate when the cursor becomes available.
                        if cursorLatDegInput.isEmpty || cursorLatMinInput.isEmpty || cursorLonDegInput.isEmpty || cursorLonMinInput.isEmpty {
                            syncCursorInputsFromCursor()
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .onChange(of: cursorCoordText) { _ in
                // Keep the text fields in sync whenever the cursor moves
                syncCursorInputsFromCursor()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: 205, height: topHUDHeight)
            .background(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            // Right stack
            VStack(alignment: .trailing, spacing: 6) {
                Text(locationText).hudBoxSmall()
                Text("Nearest boundary: \(distanceText)").hudBoxSmall()
                Text("Speed: \(speedText)").hudBoxSmall()
            }
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(key: HUDHeightPreferenceKey.self, value: geo.size.height)
                }
            )
        }
        .onPreferenceChange(HUDHeightPreferenceKey.self) { h in
            if h > 0 { topHUDHeight = h }
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private var bottomControls: some View {
        VStack {
            Spacer()

            VStack(spacing: 10) {

                HStack(alignment: .bottom) {
                    Spacer()

                    VStack(spacing: 10) {

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
                                    .foregroundColor(.red)
                                    .offset(x: 0, y: -6)
                            }
                        }
                        .buttonStyle(MapIconButtonStyle())

                        Button { zoomInReq += 1 } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .semibold))
                        }
                        .buttonStyle(MapIconButtonStyle())

                        Button { zoomOutReq += 1 } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 18, weight: .semibold))
                        }
                        .buttonStyle(MapIconButtonStyle())
                    }
                    .padding(.trailing, 10)
                }

                HStack(spacing: 10) {

                    Button {
                        isFollowing.toggle()
                        followReq += 1
                    } label: {
                        Image(systemName: isFollowing ? "location.fill" : "location")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .buttonStyle(MapIconButtonStyle(isActive: isFollowing))

                    Button { recenterReq += 1 } label: {
                        Image(systemName: "scope")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .buttonStyle(MapIconButtonStyle())

                    NavigationLink(destination: OfflineMapsView()) {
                        Image(systemName: "externaldrive")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .buttonStyle(MapIconButtonStyle())

                    Button {
                        BBMenuAppearance.applyAll()
                        showMenu = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 18, weight: .semibold))
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
                    .background(Color.black.opacity(0.60))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                }
                .padding(.leading, 10)

                HStack {
                    Spacer()
                    ThinScaleBar(metersPerPoint: metersPerPoint)
                    Spacer()
                }
                .padding(.top, 2)
            }
            .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private var waypointPromptOverlay: some View {
        if showCreateWaypointPrompt {
            CreateWaypointPrompt(
                name: $pendingWaypointName,
                onCreate: {
                    createWaypoint(named: pendingWaypointName)
                    showCreateWaypointPrompt = false
                },
                onCancel: {
                    showCreateWaypointPrompt = false
                }
            )
            .transition(.opacity)
            .zIndex(10)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                mapLayer
                topHUD
                bottomControls
                waypointPromptOverlay
            }
            .sheet(isPresented: $showMenu) {
                AppMenuTabsView(waypoints: $waypoints)
                    .onAppear { BBMenuAppearance.applyAll() }
            }
            .toolbar { keyboardDoneToolbar }
        }
    }

    // MARK: - Waypoint prompt

    private func prepareWaypointPrompt() {
        pendingWaypointName = "\(waypoints.count + 1)"
    }

    private func createWaypoint(named name: String) {
        let coord = cursorCoordinate ?? locationManager.userLocation
        guard let coord else { return }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "\(waypoints.count + 1)" : trimmed

        let wp = Waypoint(name: finalName, notes: "", coordinate: coord)
        waypoints.append(wp)
    }

    // MARK: - Location text

    private var locationText: String {
        if let coord = locationManager.userLocation {
            return degreesDecimalMinutes(coord)
        }
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

enum MenuTab: Hashable {
    case menu
    case waypoints
}

struct AppMenuTabsView: View {
    @Binding var waypoints: [Waypoint]
    @State private var selection: MenuTab = .menu

    init(waypoints: Binding<[Waypoint]>) {
        self._waypoints = waypoints
        BBMenuAppearance.applyAll()
    }

    var body: some View {
        TabView(selection: $selection) {
            MenuHomeTab(selection: $selection)
                .tabItem { Label("Menu", systemImage: "line.3.horizontal") }
                .tag(MenuTab.menu)

            NavigationStack {
                WaypointsView(waypoints: $waypoints)
            }
            .tabItem { Label("Waypoints", systemImage: "list.bullet") }
            .tag(MenuTab.waypoints)
        }
        .tint(.white)
        .modifier(TabBarBlueBackgroundModifier())
        .overlay(TabBarControllerConfigurator().frame(width: 0, height: 0))
        .onAppear {
            selection = .menu
            BBMenuAppearance.applyAll()
        }
    }
}

// Forces the *actual* UITabBarController created by SwiftUI TabView to adopt our appearance.
private struct TabBarControllerConfigurator: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { ConfigVC() }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    private final class ConfigVC: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyWithRetry()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            applyWithRetry()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            applyOnce()
        }

        private func applyWithRetry() {
            applyOnce()
            DispatchQueue.main.async { [weak self] in self?.applyOnce() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in self?.applyOnce() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.applyOnce() }
        }

        private func findTabBarController() -> UITabBarController? {
            if let tbc = self.tabBarController { return tbc }
            var p: UIViewController? = self.parent
            while let cur = p {
                if let tbc = cur as? UITabBarController { return tbc }
                if let tbc = cur.tabBarController { return tbc }
                p = cur.parent
            }
            return nil
        }

        private func applyOnce() {
            guard let tbc = findTabBarController() else { return }

            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = bbMenuBlueUIColor
            appearance.shadowColor = UIColor.black.withAlphaComponent(0.70)

            let indicatorFill = UIColor(red: 0.02, green: 0.18, blue: 0.40, alpha: 1.0)
            let indicator = UIImage.selectionIndicator(
                fill: indicatorFill,
                stroke: UIColor.black.withAlphaComponent(0.88),
                lineWidth: 1.5,
                size: CGSize(width: 82, height: 30),
                cornerRadius: 12
            )
            appearance.selectionIndicatorImage = indicator.resizableImage(
                withCapInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12),
                resizingMode: .stretch
            )

            let font = UIFont.systemFont(ofSize: 8, weight: .semibold)
            let layouts: [UITabBarItemAppearance] = [
                appearance.stackedLayoutAppearance,
                appearance.inlineLayoutAppearance,
                appearance.compactInlineLayoutAppearance
            ]
            for item in layouts {
                item.normal.iconColor = UIColor.white.withAlphaComponent(0.75)
                item.normal.titleTextAttributes = [
                    .foregroundColor: UIColor.white.withAlphaComponent(0.75),
                    .font: font
                ]
                item.selected.iconColor = UIColor.white
                item.selected.titleTextAttributes = [
                    .foregroundColor: UIColor.white,
                    .font: font
                ]
            }

            let tabBar = tbc.tabBar
            tabBar.isTranslucent = false
            tabBar.standardAppearance = appearance
            if #available(iOS 15.0, *) {
                tabBar.scrollEdgeAppearance = appearance
            }

            tabBar.backgroundColor = bbMenuBlueUIColor
            tabBar.barTintColor = bbMenuBlueUIColor
            tabBar.layer.backgroundColor = bbMenuBlueUIColor.cgColor

            tabBar.tintColor = .white
            tabBar.unselectedItemTintColor = UIColor.white.withAlphaComponent(0.75)

            for item in tabBar.items ?? [] {
                item.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: -5)
                item.imageInsets = UIEdgeInsets(top: -3, left: 0, bottom: 3, right: 0)
            }
        }
    }
}

// Ensures the TabView tab bar shows our dark-blue background when presented in a sheet (iOS 16+).
private struct TabBarBlueBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .toolbarBackground(bbMenuBlue, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
                .toolbarColorScheme(.dark, for: .tabBar)
        } else {
            content
        }
    }
}

private extension UIImage {
    static func selectionIndicator(
        fill: UIColor,
        stroke: UIColor,
        lineWidth: CGFloat,
        size: CGSize,
        cornerRadius: CGFloat
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)

            fill.setFill()
            path.fill()

            stroke.setStroke()
            path.lineWidth = lineWidth
            path.stroke()
        }
    }
}

struct MenuHomeTab: View {
    @Binding var selection: MenuTab

    var body: some View {
        NavigationStack {
            List {
                Button {
                    selection = .waypoints
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 16, weight: .semibold))

                        Text("Waypoints")
                            .font(.system(size: 14, weight: .semibold))

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .foregroundColor(.white)
                    .background(bbMenuBlue)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.black.opacity(0.85), lineWidth: 1)
                    )
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .toolbarBackground(bbMenuBlue, for: .navigationBar)
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
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }

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
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.black.opacity(0.15), lineWidth: 1)
                    )
                    .focused($isFocused)

                Button { onCreate() } label: { Text("Create Waypoint?") }
                    .buttonStyle(MapPromptActionButtonStyle(kind: .primary))

                Button { onCancel() } label: { Text("Cancel") }
                    .buttonStyle(MapPromptActionButtonStyle(kind: .secondary))
            }
            .padding(10)
            .background(Color.black.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .buttonStyle(.plain)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isFocused = true
                }
            }
        }
    }
}

// MARK: - Thin scale bar wrapper

struct ThinScaleBar: View {
    let metersPerPoint: Double

    var body: some View {
        NauticalScaleBar(metersPerPoint: metersPerPoint)
            .scaleEffect(0.9, anchor: .center)
            .opacity(0.95)
    }
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
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
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
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
    }
}

// MARK: - HUD styling

private extension View {
    func hudBoxSmall() -> some View {
        self
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.55))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Waypoints page

struct WaypointsView: View {

    @Binding var waypoints: [Waypoint]

    @State private var pendingDelete: Waypoint? = nil
    @FocusState private var focusedWaypointID: UUID?

    var body: some View {
        VStack(spacing: 0) {

            HStack(spacing: 12) {
                Text("Name")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 90, alignment: .leading)

                Text("Notes")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Delete")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 70, alignment: .trailing)
            }
            .frame(height: 44)
            .padding(.horizontal, 14)
            .background(bbMenuBlue)
            .overlay(Rectangle().stroke(Color.black.opacity(0.70), lineWidth: 1))

            List {
                ForEach($waypoints) { $wp in

                    HStack(spacing: 10) {

                        // Name (compact + outlined)
                        TextField("Name", text: $wp.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.black)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(width: 88)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.black.opacity(0.20), lineWidth: 1)
                            )
                            .focused($focusedWaypointID, equals: wp.id)
                            .tint(.black)
                            .onAppear {
                                UITextField.appearance().attributedPlaceholder = NSAttributedString(
                                    string: "Name",
                                    attributes: [.foregroundColor: UIColor.systemGray]
                                )
                            }

                        // Notes (compact + outlined)
                        TextField("Notes", text: $wp.notes)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.black)
                            .textInputAutocapitalization(.sentences)
                            .autocorrectionDisabled(true)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.black.opacity(0.20), lineWidth: 1)
                            )
                            .tint(.black)
                            .onAppear {
                                UITextField.appearance().attributedPlaceholder = NSAttributedString(
                                    string: "Notes",
                                    attributes: [.foregroundColor: UIColor.systemGray]
                                )
                            }

                        // Delete (outlined icon button)
                        Button(role: .destructive) {
                            pendingDelete = wp
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
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
        .navigationTitle("Waypoints")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(bbMenuBlue, for: .navigationBar)
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
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Confirm Delete", role: .destructive) {
                guard let del = pendingDelete else { return }
                waypoints.removeAll { $0.id == del.id }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        }
    }
}
