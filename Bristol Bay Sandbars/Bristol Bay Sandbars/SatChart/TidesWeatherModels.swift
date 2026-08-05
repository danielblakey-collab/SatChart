import Foundation

enum WeatherLoadState: Equatable {
    case idle
    case loading
    case loaded(WeatherSnapshot)
    case failed(String)
}

struct WeatherSnapshot: Equatable {
    let locationName: String
    let updatedAt: Date?
    let current: WeatherPeriod
    let upcoming: [WeatherPeriod]
}

struct WeatherPeriod: Identifiable, Equatable {
    let id: Int
    let name: String
    let startTime: Date
    let endTime: Date
    let isDaytime: Bool
    let temperature: Int?
    let temperatureUnit: String
    let shortForecast: String
    let detailedForecast: String
    let windSpeed: String
    let windDirection: String
    let precipitationChance: Int?
    let iconURL: URL?

    init(_ period: NWSForecastPeriod) {
        id = period.number
        name = period.name
        startTime = period.startTime
        endTime = period.endTime
        isDaytime = period.isDaytime
        temperature = period.temperatureValue?.roundedInt
        temperatureUnit = period.temperatureUnit ?? "F"
        shortForecast = period.shortForecast
        detailedForecast = period.detailedForecast ?? period.shortForecast
        windSpeed = period.windSpeed ?? ""
        windDirection = period.windDirection ?? ""
        precipitationChance = period.probabilityOfPrecipitation?.roundedInt
        iconURL = URL.nwsURL(from: period.icon)
    }
}

struct NWSPointsResponse: Decodable {
    let properties: Properties

    struct Properties: Decodable {
        let forecast: String?
        let forecastHourly: String?
        let relativeLocation: RelativeLocation?
    }

    struct RelativeLocation: Decodable {
        let properties: RelativeLocationProperties
    }

    struct RelativeLocationProperties: Decodable {
        let city: String?
        let state: String?

        var displayName: String {
            [city, state]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }
    }
}

struct NWSForecastResponse: Decodable {
    let properties: Properties

    struct Properties: Decodable {
        let updateTime: Date?
        let periods: [NWSForecastPeriod]
    }
}

struct NWSForecastPeriod: Decodable {
    let number: Int
    let name: String
    let startTime: Date
    let endTime: Date
    let isDaytime: Bool
    let temperatureValue: QuantitativeOrInt?
    let temperatureUnit: String?
    let probabilityOfPrecipitation: NWSMeasurementValue?
    let windSpeed: String?
    let windDirection: String?
    let icon: String?
    let shortForecast: String
    let detailedForecast: String?

    enum CodingKeys: String, CodingKey {
        case number, name, startTime, endTime, isDaytime
        case temperatureValue = "temperature"
        case temperatureUnit
        case probabilityOfPrecipitation
        case windSpeed, windDirection, icon, shortForecast, detailedForecast
    }
}

struct NWSMeasurementValue: Decodable {
    let unitCode: String?
    let value: Double?

    var roundedInt: Int? {
        value.map { Int($0.rounded()) }
    }
}

enum QuantitativeOrInt: Decodable {
    case int(Int)
    case double(Double)
    case quantitativeValue(NWSMeasurementValue)

    var roundedInt: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value):
            return Int(value.rounded())
        case .quantitativeValue(let value):
            return value.roundedInt
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
            return
        }

        if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
            return
        }

        if let qvValue = try? container.decode(NWSMeasurementValue.self) {
            self = .quantitativeValue(qvValue)
            return
        }

        throw DecodingError.typeMismatch(
            QuantitativeOrInt.self,
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "Expected Int, Double, or QuantitativeValue"
            )
        )
    }
}

extension URL {
    static func nwsURL(from raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }

        if let absolute = URL(string: raw), absolute.scheme != nil {
            return absolute
        }

        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "https://api.weather.gov/\(trimmed)")
    }
}

struct TidesWeatherSnapshot: Codable, Equatable {
    let fetchedAt: Date
    let location: TideWeatherLocation
    let tides: TidesCardModel
    let weather: WeatherCardModel
}

struct TideWeatherLocation: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    let districtName: String?
}

struct TidesCardModel: Codable, Equatable {
    let stationID: String?
    let stationName: String
    let stationDistanceMiles: Double?
    let currentWaterLevelFeet: Double?
    let nextHigh: TideEvent?
    let nextLow: TideEvent?
    let todayEvents: [TideEvent]
    let tomorrowEvents: [TideEvent]
    let curvePoints: [TideCurvePoint]
    let nearbyStations: [NearbyTideStation]
    let sourceNote: String
}

struct NearbyTideStation: Codable, Equatable, Identifiable {
    let stationID: String
    let stationName: String
    let distanceMiles: Double

    var id: String { stationID }
}

struct TideCurvePoint: Codable, Equatable, Identifiable {
    let time: Date
    let heightFeet: Double

    var id: Date { time }
}

struct TideEvent: Codable, Equatable, Identifiable {
    let time: Date
    let heightFeet: Double?
    let kind: String

    var id: String {
        let h = heightFeet.map { String(format: "%.2f", $0) } ?? "nil"
        return "\(time.timeIntervalSince1970)-\(kind)-\(h)"
    }
}

struct WeatherCardModel: Codable, Equatable {
    let shortForecast: String
    let issuingContext: String?
    let windText: String?
    let gustText: String?
    let temperatureText: String?
    let pressureText: String?
    let pressureTendencyText: String?
    let waveHeightText: String?
    let dominantPeriodText: String?
    let waterTempText: String?
    let tonightForecast: WeatherDayForecast?
    let dailyForecasts: [WeatherDayForecast]
    let marineForecastSynopsis: String?
    let marineAdvisories: [String]
    let sourceNote: String
    let ndbcStationID: String?
    let marineZoneID: String?
    let marineZoneName: String?
    let marineZoneDefinition: String?
}

struct WeatherDayForecast: Codable, Equatable, Identifiable {
    let title: String
    let forecast: String
    let temperatureText: String?
    let windText: String?
    let gustText: String?
    let waveHeightText: String?

    var id: String { title }
}

extension TidesWeatherSnapshot {
    static let mock: TidesWeatherSnapshot = {
        let now = Date()
        let calendar = Calendar.current
        let startToday = calendar.startOfDay(for: now)
        let startTomorrow = calendar.date(byAdding: .day, value: 1, to: startToday) ?? now

        let todayEvents: [TideEvent] = [
            TideEvent(time: startToday.addingTimeInterval(2 * 3600), heightFeet: 3.1, kind: "low"),
            TideEvent(time: startToday.addingTimeInterval(8 * 3600), heightFeet: 14.1, kind: "high"),
            TideEvent(time: startToday.addingTimeInterval(14 * 3600), heightFeet: 4.0, kind: "low"),
            TideEvent(time: startToday.addingTimeInterval(20 * 3600), heightFeet: 13.6, kind: "high")
        ]

        let tomorrowEvents: [TideEvent] = [
            TideEvent(time: startTomorrow.addingTimeInterval(3 * 3600), heightFeet: 3.4, kind: "low"),
            TideEvent(time: startTomorrow.addingTimeInterval(9 * 3600), heightFeet: 14.4, kind: "high"),
            TideEvent(time: startTomorrow.addingTimeInterval(15 * 3600), heightFeet: 4.2, kind: "low"),
            TideEvent(time: startTomorrow.addingTimeInterval(21 * 3600), heightFeet: 13.2, kind: "high")
        ]

        return TidesWeatherSnapshot(
            fetchedAt: now,
            location: TideWeatherLocation(
                latitude: 58.7,
                longitude: -157.5,
                districtName: "Nushagak"
            ),
            tides: TidesCardModel(
                stationID: "9465000",
                stationName: "Example NOAA Station",
                stationDistanceMiles: 12.4,
                currentWaterLevelFeet: 8.2,
                nextHigh: todayEvents.first(where: { $0.kind == "high" && $0.time >= now }),
                nextLow: todayEvents.first(where: { $0.kind == "low" && $0.time >= now }),
                todayEvents: todayEvents,
                tomorrowEvents: tomorrowEvents,
                curvePoints: makeMockCurve(around: now),
                nearbyStations: [
                    NearbyTideStation(stationID: "9465000", stationName: "Example NOAA Station", distanceMiles: 12.4),
                    NearbyTideStation(stationID: "9465001", stationName: "Second Nearby Station", distanceMiles: 31.8),
                    NearbyTideStation(stationID: "9465002", stationName: "Third Nearby Station", distanceMiles: 54.6)
                ],
                sourceNote: "Source: NOAA CO-OPS"
            ),
            weather: WeatherCardModel(
                shortForecast: "Cloudy with scattered showers",
                issuingContext: "Issued by NWS AJK",
                windText: "SE 15 kt",
                gustText: "20 kt",
                temperatureText: "48°F",
                pressureText: "1008 mb",
                pressureTendencyText: "+0.8 hPa/3hr",
                waveHeightText: "3-5 ft",
                dominantPeriodText: "7 s",
                waterTempText: "46°F",
                tonightForecast: WeatherDayForecast(title: "Tonight", forecast: "Partly cloudy", temperatureText: "42°F", windText: "NW 10 to 15 mph", gustText: "25 mph", waveHeightText: nil),
                dailyForecasts: [
                    WeatherDayForecast(title: "Today", forecast: "Cloudy with scattered showers", temperatureText: "48°F", windText: "SE 15 kt", gustText: "20 kt", waveHeightText: "3-5 ft"),
                    WeatherDayForecast(title: "Tomorrow", forecast: "Rain likely", temperatureText: "46°F", windText: "S 20 kt", gustText: "25 kt", waveHeightText: "4-6 ft"),
                    WeatherDayForecast(title: "Wednesday", forecast: "Breezy, showers", temperatureText: "44°F", windText: "SW 18 kt", gustText: "24 kt", waveHeightText: "4-5 ft"),
                    WeatherDayForecast(title: "Thursday", forecast: "Partly cloudy", temperatureText: "45°F", windText: "W 12 kt", gustText: "16 kt", waveHeightText: "2-3 ft")
                ],
                marineForecastSynopsis: nil,
                marineAdvisories: [],
                sourceNote: "Forecast: NWS • Marine observations: NDBC 46035",
                ndbcStationID: "46035",
                marineZoneID: "PKZ851",
                marineZoneName: "Bristol Bay",
                marineZoneDefinition: "Bristol Bay and approaches"
            )
        )
    }()

    private static func makeMockCurve(around date: Date) -> [TideCurvePoint] {
        stride(from: -12, through: 12, by: 1).map { hour in
            let time = date.addingTimeInterval(TimeInterval(hour * 3600))
            let radians = Double(hour) / 12.0 * .pi
            let height = 8.0 + sin(radians) * 4.5
            return TideCurvePoint(time: time, heightFeet: (height * 10).rounded() / 10)
        }
    }
}

extension TidesWeatherSnapshot {
    var upcomingTideEvents: [TideEvent] {
        (tides.todayEvents + tides.tomorrowEvents)
            .filter { $0.time >= fetchedAt }
            .sorted { $0.time < $1.time }
    }

    func upcomingTideEvents(limit: Int) -> [TideEvent] {
        Array(upcomingTideEvents.prefix(max(limit, 0)))
    }

    var remainingTodayTideEvents: [TideEvent] {
        tides.todayEvents
            .filter { $0.time >= fetchedAt }
            .sorted { $0.time < $1.time }
    }
}
