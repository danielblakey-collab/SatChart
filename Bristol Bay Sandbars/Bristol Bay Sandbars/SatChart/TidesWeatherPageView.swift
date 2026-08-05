//
//  TidesWeatherPageView.swift
//  SatChart
//
//  Created by Daniel Blakey on 3/18/26.
//

import SwiftUI
import CoreLocation

struct TidesWeatherPageView: View {
    let selectedCoordinate: CLLocationCoordinate2D?

    private let service: any TidesWeatherService
    private let fallbackCoordinate = CLLocationCoordinate2D(latitude: 58.7, longitude: -157.5)

    @StateObject private var locationManager = LocationManager()
    @State private var snapshot: TidesWeatherSnapshot?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @AppStorage(TidesWeatherStationPreference.storageKey) private var preferredStationIDRaw: String = ""
    @State private var showNearbyStations = false
    @State private var selectedTidePoint: TideCurvePoint? = nil

    init(
        selectedCoordinate: CLLocationCoordinate2D? = nil,
        service: any TidesWeatherService = NOAACoopsTidesWeatherService()
    ) {
        self.selectedCoordinate = selectedCoordinate
        self.service = service
    }

    private static let fetchedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private var usingLiveLocation: Bool {
        selectedCoordinate == nil && locationManager.userLocation != nil
    }

    private var requestedCoordinate: CLLocationCoordinate2D {
        if let selectedCoordinate {
            return CLLocationCoordinate2D(
                latitude: rounded(selectedCoordinate.latitude, places: 2),
                longitude: rounded(selectedCoordinate.longitude, places: 2)
            )
        }

        if let coord = locationManager.userLocation {
            return CLLocationCoordinate2D(
                latitude: rounded(coord.latitude, places: 2),
                longitude: rounded(coord.longitude, places: 2)
            )
        }

        return fallbackCoordinate
    }

    private var preferredStationID: String? {
        TidesWeatherStationPreference.stationID(from: preferredStationIDRaw)
    }

    private var requestLocationKey: String {
        let c = requestedCoordinate
        let stationKey = preferredStationID ?? "nearest"
        return "\(c.latitude),\(c.longitude),\(stationKey)"
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.15, blue: 0.30),
                    Color(red: 0.01, green: 0.08, blue: 0.18)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    if let snapshot {
                        headerCard(snapshot)
                        tidesCard(snapshot)
                        weatherCard(snapshot)
                    } else if isLoading {
                        loadingCard
                    } else if let errorMessage {
                        errorCard(errorMessage)
                    } else {
                        loadingCard
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
        .navigationTitle("Tides & Weather")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if selectedCoordinate == nil {
                locationManager.requestPermission()
                locationManager.start()
            }
        }
        .task(id: requestLocationKey) {
            await loadSnapshot(
                latitude: requestedCoordinate.latitude,
                longitude: requestedCoordinate.longitude,
                preferredStationID: preferredStationID
            )
        }
    }

    @MainActor
    private func loadSnapshot(latitude: Double, longitude: Double, preferredStationID: String?) async {
        isLoading = true
        errorMessage = nil
        selectedTidePoint = nil
        showNearbyStations = false

        do {
            snapshot = try await service.fetchSnapshot(
                latitude: latitude,
                longitude: longitude,
                preferredStationID: preferredStationID
            )
        } catch {
            snapshot = nil
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private var headerLocationSourceText: String {
        if selectedCoordinate != nil {
            return "Using selected map location"
        }
        if usingLiveLocation {
            return "Using device location"
        }
        return "Using default location until GPS is available"
    }

    private func headerCard(_ snapshot: TidesWeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snapshot.location.districtName ?? "Tides & Weather")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            Text("Lat \(formatCoordinate(snapshot.location.latitude)), Lon \(formatCoordinate(snapshot.location.longitude))")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.82))

            Text(headerLocationSourceText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.72))

            Text("Updated \(Self.fetchedFormatter.string(from: snapshot.fetchedAt))")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.72))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func tidesCard(_ snapshot: TidesWeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tides")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .underline(true, color: Color.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 8) {
                Text(snapshot.tides.stationName)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                if let distance = snapshot.tides.stationDistanceMiles {
                    Text("• \(String(format: "%.1f", distance)) mi")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.82))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            metricRow("Current level", value: currentWaterLevelLine(snapshot))

            if let nextEvent = snapshot.upcomingTideEvents.first {
                metricRow(nextEvent.kind == "high" ? "Next High" : "Next Low", value: TidePresentation.detailedEventLine(nextEvent))
            }

            if snapshot.upcomingTideEvents.count > 1 {
                let followingEvent = snapshot.upcomingTideEvents[1]
                metricRow(followingEvent.kind == "high" ? "Following High" : "Following Low", value: TidePresentation.detailedEventLine(followingEvent))
            }

            tideChart(snapshot)
            selectedTideStateRow(snapshot)
            tideSection(title: "Today", events: snapshot.remainingTodayTideEvents)
            tideSection(title: tomorrowTitle(snapshot), events: snapshot.tides.tomorrowEvents)
            nearbyStationsSection(snapshot)

            Text(snapshot.tides.sourceNote)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.72))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func tideSection(title: String, events: [TideEvent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .underline(true, color: Color.white.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)

            if events.isEmpty {
                Text("No tide events available")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.72))
            } else {
                ForEach(events) { event in
                    metricRow(event.kind.capitalized, value: TidePresentation.detailedEventLine(event))
                }
            }
        }
        .padding(.top, 6)
    }

    private func nearbyStationsSection(_ snapshot: TidesWeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showNearbyStations.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tide Station")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.62))

                        Text(stationSelectorTitle(snapshot))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: showNearbyStations ? "chevron.down" : "chevron.right")
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

            if showNearbyStations {
                VStack(alignment: .leading, spacing: 8) {
                    stationOptionButton(
                        title: TidesWeatherStationPreference.nearestStationLabel,
                        subtitle: nearestStationSubtitle(snapshot),
                        isSelected: preferredStationID == nil
                    ) {
                        TidesWeatherStationPreference.setNearestStation()
                        preferredStationIDRaw = ""
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showNearbyStations = false
                        }
                    }

                    let otherStations = otherStationOptions(snapshot)
                    if otherStations.isEmpty {
                        Text("No other tide stations within 75 miles")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.72))
                            .padding(.horizontal, 4)
                    } else {
                        ForEach(otherStations) { station in
                            stationOptionButton(
                                title: station.stationName,
                                subtitle: String(format: "%.1f mi", station.distanceMiles),
                                isSelected: preferredStationID == station.stationID
                            ) {
                                TidesWeatherStationPreference.setPreferredStationID(station.stationID)
                                preferredStationIDRaw = station.stationID
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    showNearbyStations = false
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(.top, 6)
    }

    private func stationSelectorTitle(_ snapshot: TidesWeatherSnapshot) -> String {
        guard let preferredStationID else {
            return TidesWeatherStationPreference.nearestStationLabel
        }

        if let station = snapshot.tides.nearbyStations.first(where: { $0.stationID == preferredStationID }) {
            return station.stationName
        }

        return snapshot.tides.stationName
    }

    private func nearestStationSubtitle(_ snapshot: TidesWeatherSnapshot) -> String {
        if let nearest = snapshot.tides.nearbyStations.first {
            return "\(nearest.stationName) • \(String(format: "%.1f mi", nearest.distanceMiles))"
        }
        if let distance = snapshot.tides.stationDistanceMiles {
            return "Current nearest • \(String(format: "%.1f mi", distance))"
        }
        return "Automatically choose the closest station"
    }

    private func otherStationOptions(_ snapshot: TidesWeatherSnapshot) -> [NearbyTideStation] {
        guard let nearestStationID = snapshot.tides.nearbyStations.first?.stationID else {
            return snapshot.tides.nearbyStations
        }
        return snapshot.tides.nearbyStations.filter { $0.stationID != nearestStationID }
    }

    private func stationOptionButton(
        title: String,
        subtitle: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(subtitle)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.72))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.90))
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.white.opacity(0.14) : Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    private func tideChart(_ snapshot: TidesWeatherSnapshot) -> some View {
        TideCurveChartView(
            points: snapshot.tides.curvePoints,
            referenceDate: snapshot.fetchedAt,
            height: 150,
            showYAxis: true,
            labelColor: .white.opacity(0.82),
            gridColor: .white.opacity(0.18),
            tickColor: .white.opacity(0.26),
            axisLabelFont: .system(size: 11, weight: .semibold, design: .rounded),
            emptyMessage: "24h tide chart unavailable",
            emptyMessageColor: .white.opacity(0.72),
            selectedPoint: selectedTidePoint,
            selectedPointRuleColor: .white.opacity(0.38),
            selectedPointMarkerColor: .white,
            onSelectPoint: { point in
                selectedTidePoint = point
            }
        )
        .padding(.top, 4)
    }

    @ViewBuilder
    private func selectedTideStateRow(_ snapshot: TidesWeatherSnapshot) -> some View {
        if let selectedTidePoint {
            metricRow("Selected", value: selectedTidePointLine(selectedTidePoint, snapshot: snapshot))
        } else {
            Text("Tap the tide chart to inspect the tide state at that point")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.72))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
    }

    private func selectedTidePointLine(_ point: TideCurvePoint, snapshot: TidesWeatherSnapshot) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short

        return "\(formatter.string(from: point.time)) • \(String(format: "%.1f", point.heightFeet)) ft • \(tideStateDescription(for: point, snapshot: snapshot))"
    }

    private func tideStateDescription(for point: TideCurvePoint, snapshot: TidesWeatherSnapshot) -> String {
        let points = snapshot.tides.curvePoints.sorted { $0.time < $1.time }
        guard let index = points.firstIndex(where: { $0.id == point.id }) else { return "Unknown" }

        let previous = index > 0 ? points[index - 1] : nil
        let next = index + 1 < points.count ? points[index + 1] : nil

        if let previous, let next {
            if point.heightFeet >= previous.heightFeet && point.heightFeet >= next.heightFeet {
                return "High"
            }
            if point.heightFeet <= previous.heightFeet && point.heightFeet <= next.heightFeet {
                return "Low"
            }
        }

        if let next {
            if next.heightFeet > point.heightFeet { return "Rising" }
            if next.heightFeet < point.heightFeet { return "Falling" }
        }

        if let previous {
            if point.heightFeet > previous.heightFeet { return "Rising" }
            if point.heightFeet < previous.heightFeet { return "Falling" }
        }

        return "Slack"
    }

    private func weatherCard(_ snapshot: TidesWeatherSnapshot) -> some View {
        let todayForecast = snapshot.weather.dailyForecasts.first

        return VStack(alignment: .leading, spacing: 10) {
            Text("Weather")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .underline(true, color: Color.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .center)

            weatherSection(
                title: "Today",
                forecast: todayForecast?.forecast ?? snapshot.weather.shortForecast,
                wind: snapshot.weather.windText ?? todayForecast?.windText,
                gust: snapshot.weather.gustText ?? todayForecast?.gustText,
                temp: snapshot.weather.temperatureText ?? todayForecast?.temperatureText,
                pressure: snapshot.weather.pressureText,
                pressureTendency: snapshot.weather.pressureTendencyText,
                waveHeight: todayForecast?.waveHeightText ?? snapshot.weather.waveHeightText,
                dominantPeriod: snapshot.weather.dominantPeriodText,
                waterTemp: snapshot.weather.waterTempText,
                issuingContext: snapshot.weather.issuingContext
            )

            if let tonight = snapshot.weather.tonightForecast {
                weatherSection(
                    title: tonight.title,
                    forecast: tonight.forecast,
                    wind: tonight.windText,
                    gust: tonight.gustText,
                    temp: tonight.temperatureText,
                    pressure: nil,
                    pressureTendency: nil,
                    waveHeight: nil,
                    dominantPeriod: nil,
                    waterTemp: nil,
                    issuingContext: nil
                )
            }

            ForEach(Array(snapshot.weather.dailyForecasts.dropFirst().prefix(4))) { day in
                weatherSection(
                    title: day.title,
                    forecast: day.forecast,
                    wind: day.windText,
                    gust: day.gustText,
                    temp: day.temperatureText,
                    pressure: nil,
                    pressureTendency: nil,
                    waveHeight: day.waveHeightText,
                    dominantPeriod: nil,
                    waterTemp: nil,
                    issuingContext: nil
                )
            }

            if let issuingContext = snapshot.weather.issuingContext,
               !issuingContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(issuingContext)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

            Text(snapshot.weather.sourceNote)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.72))

            if let zoneFootnote = marineZoneFootnote(snapshot.weather) {
                Text(zoneFootnote)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }

            windIconColorLegend
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var windLegendColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 92), spacing: 8, alignment: .leading)]
    }

    private var windIconColorLegend: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wind Icon Legend")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(columns: windLegendColumns, alignment: .leading, spacing: 8) {
                windLegendEntry(label: "≤10 mph", color: .green)
                windLegendEntry(label: "11–20 mph", color: .yellow)
                windLegendEntry(label: "21–30 mph", color: .orange)
                windLegendEntry(label: "31–35 mph", color: .red)
                windLegendEntry(label: "36+ mph", color: .purple)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func windLegendEntry(label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "wind")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(color)

            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.90))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func weatherSection(
        title: String,
        forecast: String,
        wind: String?,
        gust: String?,
        temp: String?,
        pressure: String?,
        pressureTendency: String?,
        waveHeight: String?,
        dominantPeriod: String?,
        waterTemp: String?,
        issuingContext: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .underline(true, color: Color.white.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(forecast)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.92))

            windMetricRow(value: wind ?? "—")
            if let gust,
               !gust.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                metricRow("Gusts", value: gust)
            }
            metricRow("Temp", value: temp ?? "—")
            if let pressure { metricRow("Pressure", value: pressure) }
            if let pressureTendency,
               !pressureTendency.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                metricRow("PTDY", value: pressureTendency)
            }
            if let waveHeight,
               !waveHeight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                metricRow("Wave Height", value: waveHeight)
            }
            if let dominantPeriod { metricRow("Dominant Period", value: dominantPeriod) }
            if let waterTemp { metricRow("Water Temp", value: waterTemp) }
        }
        .padding(.top, 6)
    }


    private func windMetricRow(value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("Wind")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 108, alignment: .leading)

            HStack(spacing: 6) {
                windIcon(for: value, fontSize: 13)

                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.90))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func windIcon(for windText: String, fontSize: CGFloat) -> some View {
        Image(systemName: "wind")
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .foregroundColor(windIconColor(for: windText))
    }

    private func windIconColor(for windText: String?) -> Color {
        guard let mph = maxWindSpeedMPH(from: windText) else {
            return .white.opacity(0.55)
        }

        switch mph {
        case ...10:
            return .green
        case 11...20:
            return .yellow
        case 21...30:
            return .orange
        case 31...35:
            return .red
        default:
            return .purple
        }
    }

    private func maxWindSpeedMPH(from windText: String?) -> Double? {
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



    private var loadingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Loading tide and weather data…")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            ProgressView()
                .tint(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Unable to load tide and weather data")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            Text(message)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func marineZoneFootnote(_ weather: WeatherCardModel) -> String? {
        guard let zoneID = weather.marineZoneID ?? weather.marineZoneName else { return nil }
        if let definition = weather.marineZoneDefinition, !definition.isEmpty {
            return "Marine zone: \(zoneID) — \(definition)"
        }
        return "Marine zone: \(zoneID)"
    }

    private func tomorrowTitle(_ _: TidesWeatherSnapshot) -> String {
        "Tomorrow"
    }

    private func currentWaterLevelLine(_ snapshot: TidesWeatherSnapshot) -> String {
        guard let level = currentLevelFeet(snapshot) else { return "—" }
        return "\(String(format: "%.1f", level)) ft"
    }

    private func currentLevelFeet(_ snapshot: TidesWeatherSnapshot) -> Double? {
        if let exactLevel = snapshot.tides.currentWaterLevelFeet {
            return exactLevel
        }

        let points = snapshot.tides.curvePoints.sorted { $0.time < $1.time }
        guard points.count >= 2 else { return nil }
        let now = snapshot.fetchedAt

        if now <= points[0].time { return points[0].heightFeet }
        if now >= points[points.count - 1].time { return points[points.count - 1].heightFeet }

        for index in 0..<(points.count - 1) {
            let a = points[index]
            let b = points[index + 1]
            guard now >= a.time, now <= b.time else { continue }

            let total = b.time.timeIntervalSince(a.time)
            guard total > 0 else { return a.heightFeet }

            let elapsed = now.timeIntervalSince(a.time)
            let fraction = elapsed / total
            return a.heightFeet + ((b.heightFeet - a.heightFeet) * fraction)
        }

        return nil
    }

    private func metricRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 108, alignment: .leading)

            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.90))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formatCoordinate(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private func rounded(_ value: Double, places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (value * divisor).rounded() / divisor
    }
}

