import Foundation
import CoreLocation


enum TidesWeatherStationPreference {
    static let storageKey = "tidesWeatherPreferredStationID"
    static let nearestStationLabel = "Nearest Station"

    static func stationID(from rawValue: String?) -> String? {
        let trimmed = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var preferredStationID: String? {
        stationID(from: UserDefaults.standard.string(forKey: storageKey))
    }

    static func setNearestStation() {
        UserDefaults.standard.set("", forKey: storageKey)
    }

    static func setPreferredStationID(_ stationID: String) {
        let trimmed = stationID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            setNearestStation()
        } else {
            UserDefaults.standard.set(trimmed, forKey: storageKey)
        }
    }
}

protocol TidesWeatherService {
    func fetchSnapshot(latitude: Double, longitude: Double, preferredStationID: String?, referenceDate: Date) async throws -> TidesWeatherSnapshot
}

extension TidesWeatherService {
    func fetchSnapshot(latitude: Double, longitude: Double) async throws -> TidesWeatherSnapshot {
        try await fetchSnapshot(latitude: latitude, longitude: longitude, preferredStationID: nil, referenceDate: Date())
    }

    func fetchSnapshot(latitude: Double, longitude: Double, preferredStationID: String?) async throws -> TidesWeatherSnapshot {
        try await fetchSnapshot(latitude: latitude, longitude: longitude, preferredStationID: preferredStationID, referenceDate: Date())
    }
}

struct MockTidesWeatherService: TidesWeatherService {
    func fetchSnapshot(latitude: Double, longitude: Double, preferredStationID: String?, referenceDate: Date) async throws -> TidesWeatherSnapshot {
        let mock = TidesWeatherSnapshot.mock
        return TidesWeatherSnapshot(
            fetchedAt: referenceDate,
            location: mock.location,
            tides: mock.tides,
            weather: mock.weather
        )
    }
}

struct NOAACoopsTidesWeatherService: TidesWeatherService {
    private let session: URLSession
    private let applicationName: String
    private let decoder: JSONDecoder

    init(session: URLSession = .shared, applicationName: String = "SatChart") {
        self.session = session
        self.applicationName = applicationName

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func fetchSnapshot(latitude: Double, longitude: Double, preferredStationID: String?, referenceDate: Date) async throws -> TidesWeatherSnapshot {
        let stations = try await COOPSStationCatalogCache.shared.stations(loader: {
            try await fetchStationCatalog()
        })

        let effectivePreferredStationID = preferredStationID ?? TidesWeatherStationPreference.preferredStationID

        let selectedStation: COOPSStation
        if let effectivePreferredStationID,
           let station = stations.first(where: { $0.id == effectivePreferredStationID }) {
            selectedStation = station
        } else if let nearest = nearestStation(
            to: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            from: stations
        ) {
            selectedStation = nearest
        } else {
            throw TidesWeatherServiceError.noStationsFound
        }

        let nearbyStations = stationsWithinRadius(
            of: 75,
            from: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            stations: stations
        )

        let predictions = try await fetchHiLoPredictions(stationID: selectedStation.id, referenceDate: referenceDate)
        let waterLevel = try? await fetchLatestWaterLevel(stationID: selectedStation.id)

        let rawCurvePoints = (try? await fetchTideCurve24Hours(stationID: selectedStation.id, referenceDate: referenceDate)) ?? []
        let curvePoints = rawCurvePoints.isEmpty
            ? synthesizedCurvePoints(from: predictions, referenceDate: referenceDate)
            : rawCurvePoints

        let tidesModel = buildTidesCardModel(
            station: selectedStation,
            userLatitude: latitude,
            userLongitude: longitude,
            predictions: predictions,
            latestWaterLevelFeet: waterLevel,
            curvePoints: curvePoints,
            nearbyStations: nearbyStations,
            referenceDate: referenceDate
        )

        let latestObservation = try? await fetchNDBCLatestObservation(latitude: latitude, longitude: longitude)

        let weatherModel: WeatherCardModel
        do {
            let point = try await fetchNOAAServicePointMetadata(latitude: latitude, longitude: longitude)
            let isMarinePoint = point.forecastZoneURL.map(isMarineForecastZoneURL) ?? false

            if isMarinePoint {
                let gridForecast = try? await fetchGridMarineForecastBundle(from: point.forecastGridDataURL)
                weatherModel = buildGridMarineWeatherCardModel(
                    gridForecast: gridForecast,
                    pointMetadata: point,
                    ndbcObservation: latestObservation
                )
            } else {
                let forecast = try? await fetchSharedNWSForecastBundle(
                    forecastURL: point.forecastURL,
                    forecastHourlyURL: point.forecastHourlyURL
                )
                let waveHeightsByDay = (try? await fetchNWSGridWaveHeights(from: point.forecastGridDataURL)) ?? []
                let marine = try? await fetchMarineZoneContext(
                    latitude: latitude,
                    longitude: longitude,
                    fallbackForecastZoneURL: point.forecastZoneURL
                )

                weatherModel = buildWeatherCardModel(
                    currentPeriod: forecast?.current,
                    tonightPeriod: forecast?.tonight,
                    dailyPeriods: forecast?.daily ?? [],
                    pointMetadata: point,
                    ndbcObservation: latestObservation,
                    marineZoneContext: marine,
                    gridWaveHeightsByDay: waveHeightsByDay
                )
            }
        } catch {
            #if DEBUG
            print("🌊 Weather fetch failed | \(error.localizedDescription)")
            #endif
            weatherModel = buildWeatherCardModel(
                currentPeriod: nil,
                tonightPeriod: nil,
                dailyPeriods: [],
                pointMetadata: nil,
                ndbcObservation: latestObservation,
                marineZoneContext: nil,
                gridWaveHeightsByDay: []
            )
        }

        return TidesWeatherSnapshot(
            fetchedAt: referenceDate,
            location: TideWeatherLocation(
                latitude: latitude,
                longitude: longitude,
                districtName: selectedStation.name
            ),
            tides: tidesModel,
            weather: weatherModel
        )
    }

    private func fetchStationCatalog() async throws -> [COOPSStation] {
        var components = URLComponents(string: "https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/stations.json")!
        components.queryItems = [
            URLQueryItem(name: "type", value: "tidepredictions")
        ]

        let response: COOPSStationListResponse = try await loadJSON(from: components.url!)
        return response.stationList.compactMap { record in
            guard let latitude = record.latValue,
                  let longitude = record.lngValue else {
                return nil
            }

            return COOPSStation(
                id: record.id,
                name: record.name,
                latitude: latitude,
                longitude: longitude
            )
        }
    }

    private func nearestStation(to coordinate: CLLocationCoordinate2D, from stations: [COOPSStation]) -> COOPSStation? {
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return stations.min { a, b in
            let distanceA = target.distance(from: CLLocation(latitude: a.latitude, longitude: a.longitude))
            let distanceB = target.distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            return distanceA < distanceB
        }
    }

    private func stationsWithinRadius(
        of radiusMiles: Double,
        from coordinate: CLLocationCoordinate2D,
        stations: [COOPSStation]
    ) -> [NearbyTideStation] {
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return stations.compactMap { station in
            let stationLocation = CLLocation(latitude: station.latitude, longitude: station.longitude)
            let distanceMiles = origin.distance(from: stationLocation) / 1609.344
            guard distanceMiles <= radiusMiles else { return nil }
            return NearbyTideStation(
                stationID: station.id,
                stationName: station.name,
                distanceMiles: distanceMiles
            )
        }
        .sorted { $0.distanceMiles < $1.distanceMiles }
    }

    private func fetchHiLoPredictions(stationID: String, referenceDate: Date) async throws -> [COOPSPrediction] {
        let now = referenceDate
        let start = now.addingTimeInterval(-18 * 3600)
        let end = now.addingTimeInterval(60 * 3600)

        var components = URLComponents(string: "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter")!
        components.queryItems = [
            URLQueryItem(name: "begin_date", value: Self.apiDateTimeString(from: start)),
            URLQueryItem(name: "end_date", value: Self.apiDateTimeString(from: end)),
            URLQueryItem(name: "station", value: stationID),
            URLQueryItem(name: "product", value: "predictions"),
            URLQueryItem(name: "datum", value: "MLLW"),
            URLQueryItem(name: "time_zone", value: "gmt"),
            URLQueryItem(name: "interval", value: "hilo"),
            URLQueryItem(name: "units", value: "english"),
            URLQueryItem(name: "application", value: applicationName),
            URLQueryItem(name: "format", value: "json")
        ]

        let response: COOPSPredictionsResponse = try await loadJSON(from: components.url!)
        if let apiError = response.error?.message {
            throw TidesWeatherServiceError.apiError(apiError)
        }

        return (response.predictions ?? []).compactMap { record in
            guard let rawTime = record.t,
                  let time = Self.parseCOOPSTime(rawTime) else {
                return nil
            }

            let kind: String
            switch (record.type ?? "").uppercased() {
            case "H": kind = "high"
            case "L": kind = "low"
            default: kind = "unknown"
            }

            return COOPSPrediction(
                time: time,
                heightFeet: parseDouble(record.v),
                kind: kind
            )
        }
        .sorted { $0.time < $1.time }
    }

    private func fetchLatestWaterLevel(stationID: String) async throws -> Double? {
        var components = URLComponents(string: "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter")!
        components.queryItems = [
            URLQueryItem(name: "date", value: "latest"),
            URLQueryItem(name: "station", value: stationID),
            URLQueryItem(name: "product", value: "water_level"),
            URLQueryItem(name: "datum", value: "MLLW"),
            URLQueryItem(name: "time_zone", value: "gmt"),
            URLQueryItem(name: "units", value: "english"),
            URLQueryItem(name: "application", value: applicationName),
            URLQueryItem(name: "format", value: "json")
        ]

        let response: COOPSWaterLevelResponse = try await loadJSON(from: components.url!)
        if let apiError = response.error?.message {
            throw TidesWeatherServiceError.apiError(apiError)
        }

        return parseDouble(response.data?.first?.v)
    }

    private func fetchTideCurve24Hours(stationID: String, referenceDate: Date) async throws -> [TideCurvePoint] {
        let now = referenceDate
        let queryStart = now.addingTimeInterval(-18 * 3600)
        let queryEnd = now.addingTimeInterval(18 * 3600)
        let displayStart = now.addingTimeInterval(-12 * 3600)
        let displayEnd = now.addingTimeInterval(12 * 3600)

        var components = URLComponents(string: "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter")!
        components.queryItems = [
            URLQueryItem(name: "begin_date", value: Self.apiDateTimeString(from: queryStart)),
            URLQueryItem(name: "end_date", value: Self.apiDateTimeString(from: queryEnd)),
            URLQueryItem(name: "station", value: stationID),
            URLQueryItem(name: "product", value: "predictions"),
            URLQueryItem(name: "datum", value: "MLLW"),
            URLQueryItem(name: "time_zone", value: "gmt"),
            URLQueryItem(name: "interval", value: "30"),
            URLQueryItem(name: "units", value: "english"),
            URLQueryItem(name: "application", value: applicationName),
            URLQueryItem(name: "format", value: "json")
        ]

        let response: COOPSPredictionsResponse = try await loadJSON(from: components.url!)
        if let apiError = response.error?.message {
            throw TidesWeatherServiceError.apiError(apiError)
        }

        let points = (response.predictions ?? []).compactMap { record -> TideCurvePoint? in
            guard let rawTime = record.t,
                  let time = Self.parseCOOPSTime(rawTime),
                  time >= displayStart,
                  time <= displayEnd,
                  let height = parseDouble(record.v) else {
                return nil
            }

            return TideCurvePoint(time: time, heightFeet: height)
        }
        .sorted { $0.time < $1.time }

        if !points.isEmpty {
            return points
        }

        throw TidesWeatherServiceError.apiError("No 24h tide curve points returned")
    }

    private func synthesizedCurvePoints(from predictions: [COOPSPrediction], referenceDate: Date) -> [TideCurvePoint] {
        let displayStart = referenceDate.addingTimeInterval(-12 * 3600)
        let displayEnd = referenceDate.addingTimeInterval(12 * 3600)

        let turningPoints = predictions
            .filter { ($0.kind == "high" || $0.kind == "low") && $0.heightFeet != nil }
            .sorted { $0.time < $1.time }

        guard turningPoints.count >= 2 else { return [] }

        var synthesized: [TideCurvePoint] = []
        var cursor = displayStart

        while cursor <= displayEnd {
            if let height = interpolatedHeight(at: cursor, from: turningPoints) {
                synthesized.append(TideCurvePoint(time: cursor, heightFeet: height))
            }
            cursor = cursor.addingTimeInterval(30 * 60)
        }

        return synthesized
    }

    private func interpolatedHeight(at date: Date, from turningPoints: [COOPSPrediction]) -> Double? {
        guard turningPoints.count >= 2 else { return nil }

        if let first = turningPoints.first,
           date <= first.time,
           let firstHeight = first.heightFeet {
            return firstHeight
        }

        if let last = turningPoints.last,
           date >= last.time,
           let lastHeight = last.heightFeet {
            return lastHeight
        }

        for index in 0..<(turningPoints.count - 1) {
            let left = turningPoints[index]
            let right = turningPoints[index + 1]

            guard let leftHeight = left.heightFeet,
                  let rightHeight = right.heightFeet,
                  date >= left.time,
                  date <= right.time else {
                continue
            }

            let duration = right.time.timeIntervalSince(left.time)
            guard duration > 0 else { return leftHeight }

            let progress = date.timeIntervalSince(left.time) / duration
            let eased = 0.5 - 0.5 * cos(progress * .pi)
            return leftHeight + ((rightHeight - leftHeight) * eased)
        }

        return nil
    }

    private func buildTidesCardModel(
        station: COOPSStation,
        userLatitude: Double,
        userLongitude: Double,
        predictions: [COOPSPrediction],
        latestWaterLevelFeet: Double?,
        curvePoints: [TideCurvePoint],
        nearbyStations: [NearbyTideStation],
        referenceDate: Date
    ) -> TidesCardModel {
        let now = referenceDate
        let calendar = Calendar.current
        let startToday = calendar.startOfDay(for: now)
        let startTomorrow = calendar.date(byAdding: .day, value: 1, to: startToday) ?? now
        let startDayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: startToday) ?? now

        let tideEvents = predictions.filter { $0.kind == "high" || $0.kind == "low" }
        let futureEvents = tideEvents.filter { $0.time >= now }

        let nextHigh = futureEvents.first(where: { $0.kind == "high" }).map {
            TideEvent(time: $0.time, heightFeet: $0.heightFeet, kind: $0.kind)
        }
        let nextLow = futureEvents.first(where: { $0.kind == "low" }).map {
            TideEvent(time: $0.time, heightFeet: $0.heightFeet, kind: $0.kind)
        }
        let todayEvents = tideEvents
            .filter { $0.time >= startToday && $0.time < startTomorrow }
            .map { TideEvent(time: $0.time, heightFeet: $0.heightFeet, kind: $0.kind) }
        let tomorrowEvents = tideEvents
            .filter { $0.time >= startTomorrow && $0.time < startDayAfterTomorrow }
            .map { TideEvent(time: $0.time, heightFeet: $0.heightFeet, kind: $0.kind) }

        let userLocation = CLLocation(latitude: userLatitude, longitude: userLongitude)
        let stationLocation = CLLocation(latitude: station.latitude, longitude: station.longitude)
        let distanceMiles = userLocation.distance(from: stationLocation) / 1609.344

        return TidesCardModel(
            stationID: station.id,
            stationName: station.name,
            stationDistanceMiles: distanceMiles,
            currentWaterLevelFeet: latestWaterLevelFeet,
            nextHigh: nextHigh,
            nextLow: nextLow,
            todayEvents: todayEvents,
            tomorrowEvents: tomorrowEvents,
            curvePoints: curvePoints,
            nearbyStations: nearbyStations,
            sourceNote: "Source: NOAA CO-OPS"
        )
    }

    private func fetchNOAAServicePointMetadata(latitude: Double, longitude: Double) async throws -> NOAAServicePointMetadata {
        let url = URL(string: "https://api.weather.gov/points/\(latitude),\(longitude)")!
        let response: NOAAServicePointsResponse = try await loadJSON(from: nwsRequest(url: url))

        let metadata = NOAAServicePointMetadata(
            forecastURL: response.properties.forecast,
            forecastHourlyURL: response.properties.forecastHourly,
            forecastGridDataURL: response.properties.forecastGridData,
            forecastZoneURL: response.properties.forecastZone,
            cwa: response.properties.cwa
        )

        #if DEBUG
        print("🌊 NWS points metadata | grid=\(metadata.forecastGridDataURL) zone=\(metadata.forecastZoneURL ?? "nil") cwa=\(metadata.cwa ?? "nil")")
        #endif
        return metadata
    }

    private func fetchSharedNWSForecastBundle(
        forecastURL: String,
        forecastHourlyURL: String
    ) async throws -> SharedNWSForecastBundle {
        guard let dailyURL = sanitizedURL(from: forecastURL) else {
            throw TidesWeatherServiceError.invalidForecastURL
        }

        let dailyResponse: NWSForecastResponse = try await loadJSON(from: nwsRequest(url: dailyURL))
        let allDailyPeriods = dailyResponse.properties.periods
        let normalizedDaily = Self.normalizedDailyPeriods(from: allDailyPeriods)
        let tonight = Self.forecastPeriodNamedTonight(in: allDailyPeriods)
        let current = try? await fetchNWSHourlyForecast(from: forecastHourlyURL)

        #if DEBUG
        print("🌊 NWS forecast bundle | hourly=\(current != nil) dailyCount=\(normalizedDaily.count) tonight=\(tonight?.name ?? "nil")")
        #endif

        return SharedNWSForecastBundle(
            current: current,
            tonight: tonight,
            daily: normalizedDaily
        )
    }

    private func sanitizedURL(from rawString: String) -> URL? {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    private static func normalizedDailyPeriods(from periods: [NWSForecastPeriod]) -> [NWSForecastPeriod] {
        let populatedPeriods = periods.filter { period in
            let short = period.shortForecast.trimmingCharacters(in: .whitespacesAndNewlines)
            let detailed = (period.detailedForecast ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !short.isEmpty || !detailed.isEmpty
        }

        let daytimePeriods = populatedPeriods.filter { $0.isDaytime }
        let selected = daytimePeriods.isEmpty
            ? populatedPeriods.filter { !isNightForecastPeriodName($0.name) }
            : daytimePeriods

        let finalPeriods = selected.isEmpty ? populatedPeriods : selected
        return Array(finalPeriods.prefix(5))
    }

    private static func forecastPeriodNamedTonight(in periods: [NWSForecastPeriod]) -> NWSForecastPeriod? {
        if let tonight = periods.first(where: { period in
            period.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "tonight"
        }) {
            return tonight
        }

        return periods.first(where: { isNightForecastPeriodName($0.name) })
    }

    private static func isNightForecastPeriodName(_ name: String) -> Bool {
        let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered == "tonight" || lowered == "overnight" || lowered.contains("night")
    }


    private func fetchNWSHourlyForecast(from forecastHourlyURL: String) async throws -> NWSForecastPeriod? {
        guard let url = sanitizedURL(from: forecastHourlyURL) else {
            throw TidesWeatherServiceError.invalidForecastURL
        }

        let response: NWSForecastResponse = try await loadJSON(from: nwsRequest(url: url))
        return response.properties.periods.first
    }

    private func fetchNWSDailyForecast(from forecastURL: String) async throws -> [NWSForecastPeriod] {
        guard let url = sanitizedURL(from: forecastURL) else {
            throw TidesWeatherServiceError.invalidForecastURL
        }

        let response: NWSForecastResponse = try await loadJSON(from: nwsRequest(url: url))
        return Self.normalizedDailyPeriods(from: response.properties.periods)
    }

    private func fetchNWSTonightForecast(from forecastURL: String) async throws -> NWSForecastPeriod? {
        guard let url = sanitizedURL(from: forecastURL) else {
            throw TidesWeatherServiceError.invalidForecastURL
        }

        let response: NWSForecastResponse = try await loadJSON(from: nwsRequest(url: url))
        return Self.forecastPeriodNamedTonight(in: response.properties.periods)
    }
    
    private func fetchNWSGridWaveHeights(from forecastGridDataURL: String) async throws -> [String?] {
        guard let url = URL(string: forecastGridDataURL) else {
            throw TidesWeatherServiceError.invalidForecastURL
        }

        let response: NOAAServiceGridDataResponse = try await loadJSON(from: nwsRequest(url: url))
        let layer = response.properties.waveHeight
        #if DEBUG
        let preview = Array((layer?.values ?? []).prefix(3)).map { entry in
            "\(entry.validTime)=\(String(describing: entry.value))"
        }
        #endif
        let daily = Self.dailyWaveHeightTexts(from: layer)

        #if DEBUG
        print("🌊 NWS grid waveHeight | exists=\(layer != nil) uom=\(layer?.uom ?? "nil") count=\(layer?.values.count ?? 0) preview=\(preview)")
        print("🌊 NWS grid normalized daily wave heights | \(daily)")
        #endif

        return daily
    }
    
    private func fetchGridMarineForecastBundle(from forecastGridDataURL: String) async throws -> GridMarineForecastBundle {
        guard let url = sanitizedURL(from: forecastGridDataURL) else {
            throw TidesWeatherServiceError.invalidForecastURL
        }

        let response: NOAAServiceGridDataResponse = try await loadJSON(from: nwsRequest(url: url))
        let bundle = Self.buildGridMarineForecastBundle(from: response.properties)

        #if DEBUG
        print("🌊 NWS marine grid forecast | dailyCount=\(bundle.daily.count) current=\(bundle.current?.forecast ?? "nil")")
        #endif
        return bundle
    }

    private func buildGridMarineWeatherCardModel(
        gridForecast: GridMarineForecastBundle?,
        pointMetadata: NOAAServicePointMetadata?,
        ndbcObservation: NDBCLatestObservation?
    ) -> WeatherCardModel {
        let pressureText = ndbcObservation?.pressureHpa.map { "\(Int($0.rounded())) mb" }
        let pressureTendencyText = ndbcObservation?.pressureTendencyHpa.map {
            String(format: "%@%.1f hPa/3hr", $0 >= 0 ? "+" : "", $0)
        }
        let dominantPeriodText = ndbcObservation?.dominantPeriodSeconds.map { "\(Int($0.rounded())) s" }
        let waterTempText = ndbcObservation?.waterTempCelsius.map {
            let fahrenheit = ($0 * 9.0 / 5.0) + 32.0
            return "\(Int(fahrenheit.rounded()))°F"
        }

        let current = gridForecast?.current ?? gridForecast?.daily.first
        let shortForecast = current?.forecast ?? (ndbcObservation != nil ? "Marine observations available" : "Marine forecast unavailable")
        let marineZoneID = Self.zoneIdentifier(from: pointMetadata?.forecastZoneURL)

        let sourceNote: String
        if let stationID = ndbcObservation?.stationID {
            sourceNote = "Forecast: NWS grid data • Marine observations: NDBC \(stationID)"
        } else {
            sourceNote = "Forecast: NWS grid data • Marine observations: NDBC unavailable"
        }

        return WeatherCardModel(
            shortForecast: shortForecast,
            issuingContext: pointMetadata?.cwa.map { "Issued by NWS \($0)" },
            windText: current?.windText,
            gustText: current?.gustText,
            temperatureText: current?.temperatureText,
            pressureText: pressureText,
            pressureTendencyText: pressureTendencyText,
            waveHeightText: current?.waveHeightText,
            dominantPeriodText: dominantPeriodText,
            waterTempText: waterTempText,
            tonightForecast: gridForecast?.tonight,
            dailyForecasts: gridForecast?.daily ?? [],
            marineForecastSynopsis: nil,
            marineAdvisories: [],
            sourceNote: sourceNote,
            ndbcStationID: ndbcObservation?.stationID,
            marineZoneID: marineZoneID,
            marineZoneName: nil,
            marineZoneDefinition: nil
        )
    }

    private static func buildGridMarineForecastBundle(from properties: NOAAServiceGridDataProperties) -> GridMarineForecastBundle {
        let calendar = Calendar.current
        let startToday = calendar.startOfDay(for: Date())

        let dailyForecasts: [WeatherDayForecast] = (0..<5).compactMap { dayIndex in
            let date = calendar.date(byAdding: .day, value: dayIndex, to: startToday)
            let forecast = gridWeatherSummary(forDayIndex: dayIndex, from: properties.weather) ?? "Marine forecast"
            let windText = gridWindText(
                forDayIndex: dayIndex,
                speedLayer: properties.windSpeed,
                directionLayer: properties.windDirection
            )
            let gustText = gridGustText(forDayIndex: dayIndex, from: properties.windGust)
            let temperatureText = gridTemperatureText(
                forDayIndex: dayIndex,
                maxLayer: properties.maxTemperature,
                minLayer: properties.minTemperature,
                tempLayer: properties.temperature
            )
            let waveHeightText = gridWaveHeightText(forDayIndex: dayIndex, from: properties.waveHeight)

            let hasMeaningfulData =
                forecast != "Marine forecast" ||
                windText != nil ||
                gustText != nil ||
                temperatureText != nil ||
                waveHeightText != nil

            guard hasMeaningfulData else { return nil }

            return WeatherDayForecast(
                title: dailyLabel(from: date, index: dayIndex),
                forecast: forecast,
                temperatureText: temperatureText,
                windText: windText,
                gustText: gustText,
                waveHeightText: waveHeightText
            )
        }

        return GridMarineForecastBundle(
            current: dailyForecasts.first,
            tonight: nil,
            daily: dailyForecasts
        )
    }

    private static func gridWeatherSummary(forDayIndex dayIndex: Int, from layer: NOAAServiceWeatherGridValueLayer?) -> String? {
        guard let layer else { return nil }
        let calendar = Calendar.current
        let startToday = calendar.startOfDay(for: Date())

        for entry in layer.values {
            guard let start = parseISO8601IntervalStart(entry.validTime) else { continue }
            let normalizedDay = calendar.startOfDay(for: start)
            let index = calendar.dateComponents([.day], from: startToday, to: normalizedDay).day ?? -1
            guard index == dayIndex else { continue }
            if let summary = weatherSummary(from: entry.value) {
                return summary
            }
        }

        return nil
    }

    private static func gridWindText(
        forDayIndex dayIndex: Int,
        speedLayer: NOAAServiceGridValueLayer?,
        directionLayer: NOAAServiceDirectionalGridValueLayer?
    ) -> String? {
        guard let speedLayer,
              let speed = maxNumericValue(forDayIndex: dayIndex, from: speedLayer) else {
            return nil
        }

        let speedText = formatMarineSpeed(speed, uom: speedLayer.uom)
        if let direction = firstDirectionText(forDayIndex: dayIndex, from: directionLayer), !direction.isEmpty {
            return "\(direction) \(speedText)"
        }
        return speedText
    }

    private static func gridGustText(forDayIndex dayIndex: Int, from layer: NOAAServiceGridValueLayer?) -> String? {
        guard let layer,
              let gust = maxNumericValue(forDayIndex: dayIndex, from: layer) else {
            return nil
        }
        return formatMarineSpeed(gust, uom: layer.uom)
    }

    private static func gridTemperatureText(
        forDayIndex dayIndex: Int,
        maxLayer: NOAAServiceGridValueLayer?,
        minLayer: NOAAServiceGridValueLayer?,
        tempLayer: NOAAServiceGridValueLayer?
    ) -> String? {
        if let maxLayer,
           let maxTemp = maxNumericValue(forDayIndex: dayIndex, from: maxLayer) {
            return formatTemperature(maxTemp, uom: maxLayer.uom)
        }
        if let tempLayer,
           let temp = maxNumericValue(forDayIndex: dayIndex, from: tempLayer) {
            return formatTemperature(temp, uom: tempLayer.uom)
        }
        if let minLayer,
           let minTemp = maxNumericValue(forDayIndex: dayIndex, from: minLayer) {
            return formatTemperature(minTemp, uom: minLayer.uom)
        }
        return nil
    }

    private static func gridWaveHeightText(forDayIndex dayIndex: Int, from layer: NOAAServiceGridValueLayer?) -> String? {
        guard let layer else { return nil }
        let values = numericValues(forDayIndex: dayIndex, from: layer).map { convertWaveHeightToFeet($0, uom: layer.uom) }
        guard let minValue = values.min(), let maxValue = values.max(), maxValue >= 0.5 else { return nil }
        return normalizedWaveHeightText(minFeet: minValue, maxFeet: maxValue)
    }

    private static func numericValues(forDayIndex dayIndex: Int, from layer: NOAAServiceGridValueLayer) -> [Double] {
        let calendar = Calendar.current
        let startToday = calendar.startOfDay(for: Date())

        return layer.values.compactMap { entry in
            guard let value = entry.value,
                  let start = parseISO8601IntervalStart(entry.validTime) else {
                return nil
            }
            let normalizedDay = calendar.startOfDay(for: start)
            let index = calendar.dateComponents([.day], from: startToday, to: normalizedDay).day ?? -1
            guard index == dayIndex else { return nil }
            return value
        }
    }

    private static func maxNumericValue(forDayIndex dayIndex: Int, from layer: NOAAServiceGridValueLayer) -> Double? {
        numericValues(forDayIndex: dayIndex, from: layer).max()
    }

    private static func firstDirectionText(forDayIndex dayIndex: Int, from layer: NOAAServiceDirectionalGridValueLayer?) -> String? {
        guard let layer else { return nil }
        let calendar = Calendar.current
        let startToday = calendar.startOfDay(for: Date())

        for entry in layer.values {
            guard let start = parseISO8601IntervalStart(entry.validTime) else { continue }
            let normalizedDay = calendar.startOfDay(for: start)
            let index = calendar.dateComponents([.day], from: startToday, to: normalizedDay).day ?? -1
            guard index == dayIndex else { continue }

            if let stringValue = entry.stringValue, !stringValue.isEmpty {
                let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if let degrees = Double(trimmed) {
                    return compassDirection(from: degrees)
                }
                return abbreviatedWindDirection(trimmed)
            }
            if let degrees = entry.doubleValue {
                return compassDirection(from: degrees)
            }
        }

        return nil
    }

    private static func weatherSummary(from conditions: [NOAAServiceWeatherCondition]) -> String? {
        let summaries = conditions.compactMap { condition -> String? in
            let parts = [condition.coverage, condition.intensity, condition.weather]
                .compactMap { prettifyWeatherToken($0) }
                .filter { !$0.isEmpty }

            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: " ")
        }

        guard !summaries.isEmpty else { return nil }
        let joined = summaries.joined(separator: ", ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    private static func prettifyWeatherToken(_ token: String?) -> String? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "none" else { return nil }
        return trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .lowercased()
    }

    private static func formatMarineSpeed(_ value: Double, uom: String?) -> String {
        let knots: Double
        let lowered = uom?.lowercased() ?? ""

        if lowered.contains("km_h") {
            knots = value * 0.539957
        } else if lowered.contains("m_s") {
            knots = value * 1.94384
        } else if lowered.contains("mi_h") || lowered.contains("mph") {
            knots = value * 0.868976
        } else {
            knots = value
        }

        return "\(Int(knots.rounded())) kt"
    }

    private static func formatTemperature(_ value: Double, uom: String?) -> String {
        let lowered = uom?.lowercased() ?? ""
        let fahrenheit: Double

        if lowered.contains("degc") || lowered.hasSuffix(":c") || lowered == "c" {
            fahrenheit = (value * 9.0 / 5.0) + 32.0
        } else {
            fahrenheit = value
        }

        return "\(Int(fahrenheit.rounded()))°F"
    }

    private static func compassDirection(from degrees: Double) -> String {
        let directions = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        let index = Int(((normalized + 11.25) / 22.5).rounded(.down)) % directions.count
        return directions[index]
    }

    private static func zoneIdentifier(from urlString: String?) -> String? {
        guard let urlString,
              let url = URL(string: urlString) else {
            return nil
        }
        let candidate = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }

    private func fetchMarineZoneContext(
        latitude: Double,
        longitude: Double,
        fallbackForecastZoneURL: String?
    ) async throws -> MarineZoneContext? {
        let metaURL: URL?

        if let resolvedMarineZoneURL = try await fetchMarineForecastZoneURL(latitude: latitude, longitude: longitude) {
            metaURL = resolvedMarineZoneURL
        } else if let fallbackForecastZoneURL,
                  isMarineForecastZoneURL(fallbackForecastZoneURL),
                  let fallbackURL = URL(string: fallbackForecastZoneURL) {
            metaURL = fallbackURL
        } else {
            metaURL = nil
        }

        guard let metaURL else { return nil }
        let forecastURL = metaURL.appendingPathComponent("forecast")

        let meta: NOAAServiceZoneResponse = try await loadJSON(from: nwsRequest(url: metaURL))
        let forecast: NOAAServiceZoneForecastResponse = try await loadJSON(from: nwsRequest(url: forecastURL))

        let dailyWaveHeightTexts = Self.marineDayWaveHeights(from: forecast.properties.periods)
        #if DEBUG
        let preview = Array(forecast.properties.periods.prefix(3)).map { period in
            let extracted = Self.extractWaveHeightText(from: period.detailedForecast ?? period.shortForecast) ?? "nil"
            return "\(period.name ?? "nil")=\(extracted)"
        }
        #endif
        let resolvedZoneID = meta.properties.id ?? metaURL.lastPathComponent

        #if DEBUG
        print("🌊 NWS marine zone context | zoneID=\(resolvedZoneID) name=\(meta.properties.name ?? "nil") preview=\(preview)")
        print("🌊 NWS marine zone daily wave heights | \(dailyWaveHeightTexts)")
        #endif

        return MarineZoneContext(
            zoneID: resolvedZoneID,
            zoneName: meta.properties.name,
            zoneDefinition: meta.properties.areaDesc,
            waveHeightText: Self.firstNonEmptyWaveHeight(from: dailyWaveHeightTexts),
            dailyWaveHeightTexts: dailyWaveHeightTexts,
            forecastPeriods: forecast.properties.periods
        )
    }

    private func fetchMarineForecastZoneURL(latitude: Double, longitude: Double) async throws -> URL? {
        var components = URLComponents(string: "https://api.weather.gov/zones")!
        components.queryItems = [
            URLQueryItem(name: "type", value: "marine"),
            URLQueryItem(name: "point", value: "\(latitude),\(longitude)"),
            URLQueryItem(name: "include_geometry", value: "false")
        ]

        let response: NOAAServiceMarineZonesLookupResponse = try await loadJSON(from: nwsRequest(url: components.url!))
        #if DEBUG
        let featureIDs = Array(response.features.prefix(3)).map { $0.zoneID ?? "nil" }
        print("🌊 NWS marine zone lookup | featureIDs=\(featureIDs)")
        #endif

        guard let zoneID = response.features.first?.zoneID else {
            #if DEBUG
            print("🌊 NWS marine zone lookup | resolved no zone")
            #endif
            return nil
        }

        let resolvedURL = URL(string: "https://api.weather.gov/zones/forecast/\(zoneID)")
        #if DEBUG
        print("🌊 NWS marine zone lookup | resolved zoneID=\(zoneID) url=\(resolvedURL?.absoluteString ?? "nil")")
        #endif
        return resolvedURL
    }

    private func isMarineForecastZoneURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        let zoneID = url.lastPathComponent.uppercased()
        let marinePrefixes = ["AMZ", "ANZ", "GMZ", "LEZ", "LHZ", "LMZ", "LOZ", "PHZ", "PKZ", "PMZ", "PSZ", "PZZ", "SLZ"]
        return marinePrefixes.contains { zoneID.hasPrefix($0) }
    }

    private func buildWeatherCardModel(
        currentPeriod: NWSForecastPeriod?,
        tonightPeriod: NWSForecastPeriod?,
        dailyPeriods: [NWSForecastPeriod],
        pointMetadata: NOAAServicePointMetadata?,
        ndbcObservation: NDBCLatestObservation?,
        marineZoneContext: MarineZoneContext?,
        gridWaveHeightsByDay: [String?]
    ) -> WeatherCardModel {
        let pressureText = ndbcObservation?.pressureHpa.map { "\(Int($0.rounded())) mb" }
        let pressureTendencyText = ndbcObservation?.pressureTendencyHpa.map {
            String(format: "%@%.1f hPa/3hr", $0 >= 0 ? "+" : "", $0)
        }
        let dominantPeriodText = ndbcObservation?.dominantPeriodSeconds.map { "\(Int($0.rounded())) s" }
        let waterTempText = ndbcObservation?.waterTempCelsius.map {
            let fahrenheit = ($0 * 9.0 / 5.0) + 32.0
            return "\(Int(fahrenheit.rounded()))°F"
        }

        let fallbackWaveHeight = ndbcObservation?.waveHeightMeters.map {
            "\(String(format: "%.1f", $0 * 3.28084)) ft"
        }

        let marineWaveHeights = marineZoneContext?.dailyWaveHeightTexts ?? []
        let marineFallback = buildMarineForecastFallback(from: marineZoneContext?.forecastPeriods ?? [])

        let resolvedDailyPeriods: [NWSForecastPeriod]
        if dailyPeriods.isEmpty, let currentPeriod {
            resolvedDailyPeriods = [currentPeriod]
        } else {
            resolvedDailyPeriods = dailyPeriods
        }

        let effectiveCurrentPeriod = currentPeriod ?? resolvedDailyPeriods.first

        let standardTonightForecast = tonightPeriod.map { period in
            WeatherDayForecast(
                title: period.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Tonight" : period.name,
                forecast: period.shortForecast,
                temperatureText: Self.temperatureText(from: period),
                windText: Self.windText(from: period),
                gustText: Self.windGustText(from: period),
                waveHeightText: nil
            )
        }

        let standardDailyForecasts = resolvedDailyPeriods.enumerated().map { index, period in
            let marineHeight: String? = index < marineWaveHeights.count ? marineWaveHeights[index] : nil
            let gridHeight: String? = index < gridWaveHeightsByDay.count ? gridWaveHeightsByDay[index] : nil
            let fallbackHeight: String? = index == 0 ? fallbackWaveHeight : nil

            let resolvedWaveHeight = Self.preferredWaveHeightText(
                marine: marineHeight,
                grid: gridHeight,
                fallback: fallbackHeight
            )

            return WeatherDayForecast(
                title: Self.dailyLabel(from: period.startTime, index: index),
                forecast: period.shortForecast,
                temperatureText: Self.temperatureText(from: period),
                windText: Self.windText(from: period),
                gustText: Self.windGustText(from: period),
                waveHeightText: resolvedWaveHeight
            )
        }

        let dailyForecasts = standardDailyForecasts.isEmpty ? marineFallback.daily : standardDailyForecasts
        let tonightForecast = standardTonightForecast ?? marineFallback.tonight
        let marineCurrentFallback = marineFallback.current ?? dailyForecasts.first ?? tonightForecast

        let topGridHeight: String? = gridWaveHeightsByDay.isEmpty ? nil : gridWaveHeightsByDay[0]

        let resolvedTopWaveHeight = Self.preferredWaveHeightText(
            marine: marineZoneContext?.waveHeightText,
            grid: topGridHeight,
            fallback: fallbackWaveHeight
        )

        #if DEBUG
        let resolvedPerDay = dailyForecasts.map { "\($0.title)=\($0.waveHeightText ?? "nil")" }
        print("🌊 Weather model wave heights | marine=\(marineZoneContext?.dailyWaveHeightTexts ?? []) grid=\(gridWaveHeightsByDay) top=\(resolvedTopWaveHeight ?? "nil") perDay=\(resolvedPerDay)")
        #endif

        let sourceNote: String
        if let stationID = ndbcObservation?.stationID {
            sourceNote = "Forecast: NWS • Marine observations: NDBC \(stationID)"
        } else {
            sourceNote = "Forecast: NWS • Marine observations: NDBC unavailable"
        }

        let resolvedShortForecast =
            dailyForecasts.first?.forecast ??
            effectiveCurrentPeriod?.shortForecast ??
            tonightForecast?.forecast ??
            marineCurrentFallback?.forecast ??
            (ndbcObservation != nil ? "Marine observations available" : "Weather unavailable")

        return WeatherCardModel(
            shortForecast: resolvedShortForecast,
            issuingContext: pointMetadata?.cwa.map { "Issued by NWS \($0)" },
            windText: Self.windText(from: effectiveCurrentPeriod) ?? marineCurrentFallback?.windText,
            gustText: Self.windGustText(from: effectiveCurrentPeriod) ?? marineCurrentFallback?.gustText,
            temperatureText: Self.temperatureText(from: effectiveCurrentPeriod) ?? marineCurrentFallback?.temperatureText,
            pressureText: pressureText,
            pressureTendencyText: pressureTendencyText,
            waveHeightText: resolvedTopWaveHeight,
            dominantPeriodText: dominantPeriodText,
            waterTempText: waterTempText,
            tonightForecast: tonightForecast,
            dailyForecasts: dailyForecasts,
            marineForecastSynopsis: marineFallback.synopsis,
            marineAdvisories: [],
            sourceNote: sourceNote,
            ndbcStationID: ndbcObservation?.stationID,
            marineZoneID: marineZoneContext?.zoneID,
            marineZoneName: marineZoneContext?.zoneName,
            marineZoneDefinition: marineZoneContext?.zoneDefinition
        )
    }

    private func fetchNDBCLatestObservation(latitude: Double, longitude: Double) async throws -> NDBCLatestObservation? {
        let url = URL(string: "https://www.ndbc.noaa.gov/data/latest_obs/latest_obs.txt")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw TidesWeatherServiceError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw TidesWeatherServiceError.httpError(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw TidesWeatherServiceError.decodingFailed("Unable to decode NDBC text feed")
        }

        let observations = parseNDBCLatestObs(text)
        let target = CLLocation(latitude: latitude, longitude: longitude)
        let candidates = observations.filter {
            $0.pressureHpa != nil || $0.pressureTendencyHpa != nil || $0.waveHeightMeters != nil || $0.dominantPeriodSeconds != nil || $0.waterTempCelsius != nil
        }

        return candidates.min { a, b in
            let distanceA = target.distance(from: CLLocation(latitude: a.latitude, longitude: a.longitude))
            let distanceB = target.distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            return distanceA < distanceB
        }
    }

    private func parseNDBCLatestObs(_ text: String) -> [NDBCLatestObservation] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let headerLine = lines.first(where: { $0.hasPrefix("#STN") }) else {
            return []
        }

        let headers = headerLine
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        let dataLines = lines.filter { !$0.hasPrefix("#") }

        return dataLines.compactMap { line in
            let parts = line
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard parts.count >= headers.count else { return nil }

            var values: [String: String] = [:]
            for (index, header) in headers.enumerated() where index < parts.count {
                values[header] = parts[index]
            }

            guard let stationID = values["#STN"],
                  let latitude = parseDouble(values["LAT"]),
                  let longitude = parseDouble(values["LON"]) else {
                return nil
            }

            return NDBCLatestObservation(
                stationID: stationID,
                latitude: latitude,
                longitude: longitude,
                pressureHpa: parseDouble(values["PRES"]),
                pressureTendencyHpa: parseDouble(values["PTDY"]),
                waveHeightMeters: parseDouble(values["WVHT"]),
                dominantPeriodSeconds: parseDouble(values["DPD"]),
                waterTempCelsius: parseDouble(values["WTMP"])
            )
        }
    }

    private func nwsRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/geo+json, application/json;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue("\(applicationName)/1.0 (weather support)", forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        return request
    }

    private func loadJSON<T: Decodable>(from url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        return try decodeResponse(data: data, response: response)
    }

    private func loadJSON<T: Decodable>(from request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        return try decodeResponse(data: data, response: response)
    }

    private func decodeResponse<T: Decodable>(data: Data, response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else {
            throw TidesWeatherServiceError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw TidesWeatherServiceError.httpError(http.statusCode)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch let decodingError as DecodingError {
            throw TidesWeatherServiceError.decodingFailed(Self.describe(decodingError))
        } catch {
            throw TidesWeatherServiceError.decodingFailed(error.localizedDescription)
        }
    }

    private static func apiDateTimeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd HH:mm"
        return formatter.string(from: date)
    }

    private static func parseCOOPSTime(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: string)
    }

    private static func dailyLabel(from date: Date?, index: Int) -> String {
        guard let date else {
            return index == 0 ? "Today" : (index == 1 ? "Tomorrow" : "Day \(index + 1)")
        }

        if index == 0 { return "Today" }
        if index == 1 { return "Tomorrow" }

        let weekday = DateFormatter()
        weekday.locale = Locale.current
        weekday.dateFormat = "EEEE"
        return weekday.string(from: date)
    }

    private static func temperatureText(from period: NWSForecastPeriod?) -> String? {
        guard let period,
              let temperature = period.temperatureValue?.roundedInt else {
            return nil
        }
        return "\(temperature)°\(period.temperatureUnit ?? "F")"
    }

    private static func windText(from period: NWSForecastPeriod?) -> String? {
        guard let period,
              let speed = period.windSpeed,
              !speed.isEmpty else {
            return nil
        }
        if let direction = period.windDirection, !direction.isEmpty {
            return "\(direction) \(speed)"
        }
        return speed
    }

    private static func windGustText(from period: NWSForecastPeriod?) -> String? {
        guard let period else { return nil }
        let source = period.detailedForecast ?? period.shortForecast
        return extractWindGustText(from: source)
    }

    private func buildMarineForecastFallback(from periods: [NOAAServiceMarineForecastPeriod]) -> MarineForecastFallback {
        let trimmedPeriods = periods.filter { period in
            let short = period.shortForecast.trimmingCharacters(in: .whitespacesAndNewlines)
            let detailed = (period.detailedForecast ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !short.isEmpty || !detailed.isEmpty
        }

        let sourcePeriods = trimmedPeriods.isEmpty ? periods : trimmedPeriods
        guard !sourcePeriods.isEmpty else {
            return MarineForecastFallback(current: nil, tonight: nil, daily: [], synopsis: nil)
        }

        let tonightPeriod = sourcePeriods.first(where: { Self.isNightMarinePeriodName($0.name) })
        let daytimePeriods = sourcePeriods.filter { !Self.isNightMarinePeriodName($0.name) }
        let selectedDailyPeriods = daytimePeriods.isEmpty ? sourcePeriods.filter { !Self.isNightMarinePeriodName($0.name) } : daytimePeriods

        let dailyForecasts = Array(selectedDailyPeriods.prefix(5)).enumerated().map { index, period in
            WeatherDayForecast(
                title: Self.marineForecastTitle(for: period.name, index: index),
                forecast: period.shortForecast,
                temperatureText: nil,
                windText: Self.marineWindText(from: period),
                gustText: Self.extractWindGustText(from: period.detailedForecast ?? period.shortForecast),
                waveHeightText: Self.extractWaveHeightText(from: period.detailedForecast ?? period.shortForecast)
            )
        }

        let tonightForecast = tonightPeriod.map { period in
            WeatherDayForecast(
                title: Self.marineForecastTitle(for: period.name, index: 1),
                forecast: period.shortForecast,
                temperatureText: nil,
                windText: Self.marineWindText(from: period),
                gustText: Self.extractWindGustText(from: period.detailedForecast ?? period.shortForecast),
                waveHeightText: Self.extractWaveHeightText(from: period.detailedForecast ?? period.shortForecast)
            )
        }

        let current = dailyForecasts.first ?? tonightForecast
        let synopsis = sourcePeriods.first?.detailedForecast ?? sourcePeriods.first?.shortForecast

        return MarineForecastFallback(
            current: current,
            tonight: tonightForecast,
            daily: dailyForecasts,
            synopsis: synopsis
        )
    }

    private static func marineForecastTitle(for name: String?, index: Int) -> String {
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if index == 0 { return "Today" }
        if index == 1 { return "Tomorrow" }
        return "Day \(index + 1)"
    }

    private static func marineWindText(from period: NOAAServiceMarineForecastPeriod) -> String? {
        extractWindText(from: period.detailedForecast ?? period.shortForecast)
    }

    private static func extractWindText(from text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }

        let directionWords = "north|south|east|west|northeast|northwest|southeast|southwest|n|s|e|w|ne|nw|se|sw|nne|ene|ese|sse|ssw|wsw|wnw|nnw|variable|light"
        let directionalPattern = "(?i)\\b((?:" + directionWords + ")(?:\\s+to\\s+(?:" + directionWords + "))?)\\s+winds?\\s+((?:less than\\s+)?\\d+(?:\\.\\d+)?(?:\\s*(?:to|-)\\s*\\d+(?:\\.\\d+)?)?)\\s*(mph|kt|kts|knots)\\b"
        let genericPattern = "(?i)\\bwinds?\\s+((?:less than\\s+)?\\d+(?:\\.\\d+)?(?:\\s*(?:to|-)\\s*\\d+(?:\\.\\d+)?)?)\\s*(mph|kt|kts|knots)\\b"

        if let regex = try? NSRegularExpression(pattern: directionalPattern) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: range) {
                let direction = Self.capturedString(match: match, index: 1, in: text) ?? ""
                let speed = Self.capturedString(match: match, index: 2, in: text) ?? ""
                let unit = Self.capturedString(match: match, index: 3, in: text) ?? "kt"
                let normalizedSpeed = speed.replacingOccurrences(of: " to ", with: "-")
                return "\(Self.abbreviatedWindDirection(direction)) \(normalizedSpeed) \(Self.normalizedWindUnit(unit))"
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let regex = try? NSRegularExpression(pattern: genericPattern) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: range) {
                let speed = Self.capturedString(match: match, index: 1, in: text) ?? ""
                let unit = Self.capturedString(match: match, index: 2, in: text) ?? "kt"
                let normalizedSpeed = speed.replacingOccurrences(of: " to ", with: "-")
                return "\(normalizedSpeed) \(Self.normalizedWindUnit(unit))"
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

    private static func abbreviatedWindDirection(_ raw: String) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let degrees = Double(cleaned) {
            return compassDirection(from: degrees)
        }
        let map: [String: String] = [
            "north": "N",
            "south": "S",
            "east": "E",
            "west": "W",
            "northeast": "NE",
            "northwest": "NW",
            "southeast": "SE",
            "southwest": "SW",
            "n": "N",
            "s": "S",
            "e": "E",
            "w": "W",
            "ne": "NE",
            "nw": "NW",
            "se": "SE",
            "sw": "SW",
            "nne": "NNE",
            "ene": "ENE",
            "ese": "ESE",
            "sse": "SSE",
            "ssw": "SSW",
            "wsw": "WSW",
            "wnw": "WNW",
            "nnw": "NNW",
            "variable": "Variable",
            "light": "Light"
        ]

        if cleaned.contains(" to ") {
            let parts = cleaned.components(separatedBy: " to ")
            let abbreviated = parts.map { map[$0] ?? $0.uppercased() }
            return abbreviated.joined(separator: "-")
        }

        return map[cleaned] ?? raw.uppercased()
    }

    private static func extractWindGustText(from text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }

        let patterns = [
            #"(?i)gusts?\s+(?:as\s+high\s+as\s+|up\s+to\s+|to\s+|around\s+)?(\d+(?:\.\d+)?)\s*(mph|kt|kts|knots)"#,
            #"(?i)gusts?\s+(\d+(?:\.\d+)?)\s*(?:to|-)\s*(\d+(?:\.\d+)?)\s*(mph|kt|kts|knots)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range) else { continue }

            let first = Self.capturedString(match: match, index: 1, in: text)
            let second = Self.capturedString(match: match, index: 2, in: text)
            let unitIndex = match.numberOfRanges > 3 ? 3 : 2
            let unit = Self.capturedString(match: match, index: unitIndex, in: text) ?? ""

            if let first, let second, unitIndex == 3 {
                return "\(first)-\(second) \(normalizedWindUnit(unit))"
            }
            if let first {
                return "\(first) \(normalizedWindUnit(unit))"
            }
        }

        return nil
    }

    private static func normalizedWindUnit(_ unit: String) -> String {
        let lowered = unit.lowercased()
        if lowered == "knots" || lowered == "kts" { return "kt" }
        return lowered
    }

    private static func extractWaveHeightText(from text: String) -> String? {
        let patterns = [
            #"(?i)(?:combined\s+)?seas?\s+(?:around\s+)?(\d+(?:\.\d+)?)\s*(?:to|-)?\s*(\d+(?:\.\d+)?)?\s*ft"#,
            #"(?i)waves?\s+(?:around\s+)?(\d+(?:\.\d+)?)\s*(?:to|-)?\s*(\d+(?:\.\d+)?)?\s*ft"#,
            #"(?i)wind\s+waves?\s+(?:around\s+)?(\d+(?:\.\d+)?)\s*(?:to|-)?\s*(\d+(?:\.\d+)?)?\s*ft"#,
            #"(?i)seas?\s+(\d+(?:\.\d+)?)\s*ft\s+or\s+less"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range) else { continue }

            let first = Self.capturedString(match: match, index: 1, in: text)
            let second = Self.capturedString(match: match, index: 2, in: text)

            if let first, let second, !second.isEmpty {
                return "\(first)-\(second) ft"
            }
            if let first {
                return "\(first) ft"
            }
        }

        return nil
    }

    private static func capturedString(match: NSTextCheckingResult, index: Int, in text: String) -> String? {
        guard match.numberOfRanges > index else { return nil }
        let nsRange = match.range(at: index)
        guard nsRange.location != NSNotFound,
              let range = Range(nsRange, in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func marineDayWaveHeights(from periods: [NOAAServiceMarineForecastPeriod]) -> [String?] {
        let daytimePeriods = periods.filter { !isNightMarinePeriodName($0.name) }
        let selectedPeriods = daytimePeriods.isEmpty ? periods : daytimePeriods

        return Array(selectedPeriods.prefix(4)).map { period in
            extractWaveHeightText(from: period.detailedForecast ?? period.shortForecast)
        }
    }

    private static func isNightMarinePeriodName(_ name: String?) -> Bool {
        guard let name else { return false }
        let lowered = name.lowercased()
        return lowered.contains("night") || lowered.contains("tonight")
    }

    private static func firstNonEmptyWaveHeight(from values: [String?]) -> String? {
        values.first { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? nil
    }

    private static func preferredWaveHeightText(
        marine: String?,
        grid: String?,
        fallback: String?
    ) -> String? {
        if let marine, isMeaningfulWaveHeightText(marine) {
            return marine
        }
        if let grid, isMeaningfulWaveHeightText(grid) {
            return grid
        }
        if let fallback, isMeaningfulWaveHeightText(fallback) {
            return fallback
        }
        return nil
    }

    private static func isMeaningfulWaveHeightText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let pattern = #"\d+(?:\.\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return true
        }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let numbers = regex.matches(in: trimmed, range: range).compactMap { match -> Double? in
            guard let string = Self.capturedString(match: match, index: 0, in: trimmed) else { return nil }
            return Double(string)
        }

        guard let maxNumber = numbers.max() else { return false }
        return maxNumber >= 1.0
    }

    private static func dailyWaveHeightTexts(from layer: NOAAServiceGridValueLayer?) -> [String?] {
        guard let layer else { return [] }

        let calendar = Calendar.current
        let startToday = calendar.startOfDay(for: Date())
        var buckets: [[Double]] = Array(repeating: [], count: 4)

        for entry in layer.values {
            guard let rawValue = entry.value,
                  let start = parseISO8601IntervalStart(entry.validTime) else {
                continue
            }

            let dayIndex = calendar.dateComponents(
                [.day],
                from: startToday,
                to: calendar.startOfDay(for: start)
            ).day ?? -1

            guard (0..<4).contains(dayIndex) else { continue }

            let feet = convertWaveHeightToFeet(rawValue, uom: layer.uom)
            buckets[dayIndex].append(feet)
        }

        return buckets.map { values in
            guard let minValue = values.min(),
                  let maxValue = values.max() else {
                return nil
            }

            guard maxValue >= 0.5 else { return nil }
            return normalizedWaveHeightText(minFeet: minValue, maxFeet: maxValue)
        }
    }

    private static func parseISO8601IntervalStart(_ validTime: String) -> Date? {
        let startString = validTime.split(separator: "/").first.map(String.init) ?? validTime
        let formatterWithFractional = ISO8601DateFormatter()
        formatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatterWithFractional.date(from: startString) ?? formatter.date(from: startString)
    }

    private static func convertWaveHeightToFeet(_ value: Double, uom: String?) -> Double {
        guard let uom = uom?.lowercased() else { return value }
        if uom.contains("wmounit:m") || uom.hasSuffix(":m") || uom == "m" {
            return value * 3.28084
        }
        return value
    }

    private static func normalizedWaveHeightText(minFeet: Double, maxFeet: Double) -> String {
        let low = Int(floor(minFeet))
        let high = Int(ceil(maxFeet))
        if low >= high {
            return "\(max(0, high)) ft"
        }
        return "\(max(0, low))-\(max(0, high)) ft"
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(let type, let context):
            return "Type mismatch for \(type) at \(codingPathString(context.codingPath)): \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "Value not found for \(type) at \(codingPathString(context.codingPath)): \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "Missing key '\(key.stringValue)' at \(codingPathString(context.codingPath)): \(context.debugDescription)"
        case .dataCorrupted(let context):
            return "Data corrupted at \(codingPathString(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func codingPathString(_ codingPath: [CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "<root>" }
        return codingPath.map { $0.stringValue }.joined(separator: ".")
    }

    private func parseDouble(_ string: String?) -> Double? {
        guard let string, string != "MM" else { return nil }
        return Double(string)
    }
}

private actor COOPSStationCatalogCache {
    static let shared = COOPSStationCatalogCache()

    private var cachedStations: [COOPSStation] = []
    private var fetchedAt: Date?
    private let ttl: TimeInterval = 12 * 3600

    func stations(loader: () async throws -> [COOPSStation]) async throws -> [COOPSStation] {
        if let fetchedAt,
           !cachedStations.isEmpty,
           Date().timeIntervalSince(fetchedAt) < ttl {
            return cachedStations
        }

        let stations = try await loader()
        cachedStations = stations
        self.fetchedAt = Date()
        return stations
    }
}

@MainActor
final class TidesWeatherLaunchPrefetch {
    static let shared = TidesWeatherLaunchPrefetch()

    private var hasPrefetched = false

    private init() {}

    func prefetchIfNeeded() async {
        guard !hasPrefetched else { return }
        hasPrefetched = true

        let manager = CLLocationManager()
        let coordinate = manager.location?.coordinate ?? CLLocationCoordinate2D(latitude: 58.7, longitude: -157.5)

        let service = NOAACoopsTidesWeatherService()
        _ = try? await service.fetchSnapshot(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            preferredStationID: TidesWeatherStationPreference.preferredStationID
        )
    }
}

private struct COOPSStation: Equatable, Sendable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
}

private struct COOPSPrediction: Equatable, Sendable {
    let time: Date
    let heightFeet: Double?
    let kind: String
}

private struct COOPSStationListResponse: Decodable, Sendable {
    let stationList: [COOPSStationRecord]

    private enum CodingKeys: String, CodingKey {
        case stationList
        case stations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let list = try container.decodeIfPresent([COOPSStationRecord].self, forKey: .stationList) {
            self.stationList = list
        } else if let list = try container.decodeIfPresent([COOPSStationRecord].self, forKey: .stations) {
            self.stationList = list
        } else {
            self.stationList = []
        }
    }
}

private struct COOPSStationRecord: Decodable, Sendable {
    let id: String
    let name: String
    let latValue: Double?
    let lngValue: Double?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case lat
        case lng
        case latitude
        case longitude
        case lon
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.latValue = Self.decodeFlexibleDouble(from: container, primary: .lat, fallbacks: [.latitude])
        self.lngValue = Self.decodeFlexibleDouble(from: container, primary: .lng, fallbacks: [.longitude, .lon])
    }

    private static func decodeFlexibleDouble(
        from container: KeyedDecodingContainer<CodingKeys>,
        primary: CodingKeys,
        fallbacks: [CodingKeys]
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: primary) {
            return value
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: primary),
           let parsed = Double(value) {
            return parsed
        }
        for key in fallbacks {
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let parsed = Double(value) {
                return parsed
            }
        }
        return nil
    }
}

private struct COOPSPredictionsResponse: Decodable, Sendable {
    let predictions: [COOPSPredictionRecord]?
    let error: COOPSAPIError?
}

private struct COOPSPredictionRecord: Decodable, Sendable {
    let t: String?
    let v: String?
    let type: String?
}

private struct COOPSWaterLevelResponse: Decodable, Sendable {
    let data: [COOPSWaterLevelRecord]?
    let error: COOPSAPIError?
}

private struct COOPSWaterLevelRecord: Decodable, Sendable {
    let t: String?
    let v: String?
}

private struct COOPSAPIError: Decodable, Sendable {
    let message: String?
}

private struct NOAAServicePointMetadata: Sendable {
    let forecastURL: String
    let forecastHourlyURL: String
    let forecastGridDataURL: String
    let forecastZoneURL: String?
    let cwa: String?
}

private struct SharedNWSForecastBundle: Sendable {
    let current: NWSForecastPeriod?
    let tonight: NWSForecastPeriod?
    let daily: [NWSForecastPeriod]
}

private struct NOAAServiceForecastBundle: Sendable {
    let current: NOAAServiceForecastPeriod?
    let tonight: NOAAServiceForecastPeriod?
    let daily: [NOAAServiceForecastPeriod]
}

private struct NOAAServicePointsResponse: Decodable, Sendable {
    let properties: NOAAServicePointsProperties
}

private struct NOAAServicePointsProperties: Decodable, Sendable {
    let forecast: String
    let forecastHourly: String
    let forecastGridData: String
    let forecastZone: String?
    let cwa: String?
}

private struct NOAAServiceForecastResponse: Decodable, Sendable {
    let properties: NOAAServiceForecastProperties
}

private struct NOAAServiceForecastProperties: Decodable, Sendable {
    let periods: [NOAAServiceForecastPeriod]

    private enum CodingKeys: String, CodingKey {
        case periods
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.periods = (try? container.decode([NOAAServiceForecastPeriod].self, forKey: .periods)) ?? []
    }
}

private struct NOAAServiceGridDataResponse: Decodable, Sendable {
    let properties: NOAAServiceGridDataProperties
}

private struct NOAAServiceGridDataProperties: Decodable, Sendable {
    let waveHeight: NOAAServiceGridValueLayer?
    let temperature: NOAAServiceGridValueLayer?
    let maxTemperature: NOAAServiceGridValueLayer?
    let minTemperature: NOAAServiceGridValueLayer?
    let windSpeed: NOAAServiceGridValueLayer?
    let windGust: NOAAServiceGridValueLayer?
    let windDirection: NOAAServiceDirectionalGridValueLayer?
    let weather: NOAAServiceWeatherGridValueLayer?
}

private struct NOAAServiceGridValueLayer: Decodable, Sendable {
    let uom: String?
    let values: [NOAAServiceGridValue]
}

private struct NOAAServiceGridValue: Decodable, Sendable {
    let validTime: String
    let value: Double?

    private enum CodingKeys: String, CodingKey {
        case validTime
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.validTime = container.decodeFlexibleString(forKey: .validTime) ?? ""
        self.value = container.decodeFlexibleDouble(forKey: .value)
    }
}

private struct NOAAServiceDirectionalGridValueLayer: Decodable, Sendable {
    let uom: String?
    let values: [NOAAServiceDirectionalGridValue]
}

private struct NOAAServiceDirectionalGridValue: Decodable, Sendable {
    let validTime: String
    let stringValue: String?
    let doubleValue: Double?

    private enum CodingKeys: String, CodingKey {
        case validTime
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.validTime = container.decodeFlexibleString(forKey: .validTime) ?? ""
        self.stringValue = container.decodeFlexibleString(forKey: .value)
        self.doubleValue = container.decodeFlexibleDouble(forKey: .value)
    }
}

private struct NOAAServiceWeatherGridValueLayer: Decodable, Sendable {
    let values: [NOAAServiceWeatherGridValue]
}

private struct NOAAServiceWeatherGridValue: Decodable, Sendable {
    let validTime: String
    let value: [NOAAServiceWeatherCondition]

    private enum CodingKeys: String, CodingKey {
        case validTime
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.validTime = container.decodeFlexibleString(forKey: .validTime) ?? ""
        self.value = (try? container.decode([NOAAServiceWeatherCondition].self, forKey: .value)) ?? []
    }
}

private struct NOAAServiceWeatherCondition: Decodable, Sendable {
    let coverage: String?
    let weather: String?
    let intensity: String?
}

private struct NOAAServiceForecastPeriod: Decodable, Sendable {
    let name: String?
    let startTime: String?
    let endTime: String?
    let isDaytime: Bool?
    let temperature: Int?
    let temperatureUnit: String?
    let windSpeed: String?
    let windDirection: String?
    let shortForecast: String
    let detailedForecast: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case startTime
        case endTime
        case isDaytime
        case temperature
        case temperatureUnit
        case windSpeed
        case windDirection
        case shortForecast
        case detailedForecast
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = container.decodeFlexibleString(forKey: .name)
        self.startTime = container.decodeFlexibleString(forKey: .startTime)
        self.endTime = container.decodeFlexibleString(forKey: .endTime)
        self.isDaytime = container.decodeFlexibleBool(forKey: .isDaytime)
        self.temperature = container.decodeFlexibleInt(forKey: .temperature)
        self.temperatureUnit = container.decodeFlexibleString(forKey: .temperatureUnit)
        self.windSpeed = container.decodeFlexibleString(forKey: .windSpeed)
        self.windDirection = container.decodeFlexibleString(forKey: .windDirection)
        self.detailedForecast = container.decodeFlexibleString(forKey: .detailedForecast)
        self.shortForecast =
            container.decodeFlexibleString(forKey: .shortForecast) ??
            self.detailedForecast ??
            "Weather unavailable"
    }
}

private struct NOAAServiceZoneResponse: Decodable, Sendable {
    let properties: NOAAServiceZoneProperties
}

private struct NOAAServiceZoneProperties: Decodable, Sendable {
    let id: String?
    let name: String?
    let areaDesc: String?
}

private struct NOAAServiceZoneForecastResponse: Decodable, Sendable {
    let properties: NOAAServiceZoneForecastProperties
}

private struct NOAAServiceZoneForecastProperties: Decodable, Sendable {
    let periods: [NOAAServiceMarineForecastPeriod]

    private enum CodingKeys: String, CodingKey {
        case periods
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.periods = (try? container.decode([NOAAServiceMarineForecastPeriod].self, forKey: .periods)) ?? []
    }
}

private struct NOAAServiceMarineZonesLookupResponse: Decodable, Sendable {
    let features: [NOAAServiceMarineZoneFeature]
}

private struct NOAAServiceMarineZoneFeature: Decodable, Sendable {
    let id: String?
    let properties: NOAAServiceMarineZoneFeatureProperties?

    var zoneID: String? {
        let raw = properties?.id ?? id
        guard let raw else { return nil }

        if let url = URL(string: raw) {
            let candidate = url.lastPathComponent
            if !candidate.isEmpty {
                return candidate
            }
        }

        return raw.split(separator: "/").last.map(String.init)
    }
}

private struct NOAAServiceMarineZoneFeatureProperties: Decodable, Sendable {
    let id: String?
}

private struct NOAAServiceMarineForecastPeriod: Decodable, Sendable {
    let name: String?
    let detailedForecast: String?
    let shortForecast: String

    private enum CodingKeys: String, CodingKey {
        case name
        case detailedForecast
        case shortForecast
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = container.decodeFlexibleString(forKey: .name)
        self.detailedForecast = container.decodeFlexibleString(forKey: .detailedForecast)
        self.shortForecast =
            container.decodeFlexibleString(forKey: .shortForecast) ??
            self.detailedForecast ??
            "Marine forecast unavailable"
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleString(forKey key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            if value.rounded() == value {
                return String(Int(value))
            }
            return String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? "true" : "false"
        }
        return nil
    }

    func decodeFlexibleInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value.rounded())
        }
        if let value = decodeFlexibleString(forKey: key) {
            if let intValue = Int(value) {
                return intValue
            }
            if let doubleValue = Double(value) {
                return Int(doubleValue.rounded())
            }
        }
        return nil
    }

    func decodeFlexibleDouble(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = decodeFlexibleString(forKey: key) {
            return Double(value)
        }
        return nil
    }

    func decodeFlexibleBool(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = decodeFlexibleString(forKey: key)?.lowercased() {
            switch value {
            case "true", "yes", "y", "1":
                return true
            case "false", "no", "n", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}

private struct NDBCLatestObservation: Sendable {
    let stationID: String
    let latitude: Double
    let longitude: Double
    let pressureHpa: Double?
    let pressureTendencyHpa: Double?
    let waveHeightMeters: Double?
    let dominantPeriodSeconds: Double?
    let waterTempCelsius: Double?
}

private struct GridMarineForecastBundle: Sendable {
    let current: WeatherDayForecast?
    let tonight: WeatherDayForecast?
    let daily: [WeatherDayForecast]
}
private struct MarineZoneContext: Sendable {
    let zoneID: String
    let zoneName: String?
    let zoneDefinition: String?
    let waveHeightText: String?
    let dailyWaveHeightTexts: [String?]
    let forecastPeriods: [NOAAServiceMarineForecastPeriod]
}

private struct MarineForecastFallback: Sendable {
    let current: WeatherDayForecast?
    let tonight: WeatherDayForecast?
    let daily: [WeatherDayForecast]
    let synopsis: String?
}

private enum TidesWeatherServiceError: LocalizedError {
    case noStationsFound
    case invalidResponse
    case httpError(Int)
    case apiError(String)
    case decodingFailed(String)
    case invalidForecastURL

    var errorDescription: String? {
        switch self {
        case .noStationsFound:
            return "No NOAA CO-OPS tide stations were found."
        case .invalidResponse:
            return "The NOAA service returned an invalid response."
        case .httpError(let code):
            return "The NOAA service returned HTTP \(code)."
        case .apiError(let message):
            return message
        case .decodingFailed(let message):
            return "Failed to decode NOAA response: \(message)"
        case .invalidForecastURL:
            return "The NWS forecast URL was invalid."
        }
    }
}
