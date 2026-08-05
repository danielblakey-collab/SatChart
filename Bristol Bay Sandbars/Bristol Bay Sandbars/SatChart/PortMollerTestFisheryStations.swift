import Foundation
import MapKit

struct PMTFStation: Identifiable, Hashable {
    enum Confidence: String, Codable, Hashable {
        case documented
        case estimated
    }

    let stationNumber: Int
    let name: String
    let latitude: Double
    let longitude: Double
    let coordinateDMM: String
    let confidence: Confidence

    var id: Int { stationNumber }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

let portMollerTestFisheryStations: [PMTFStation] = [
    PMTFStation(
        stationNumber: 2,
        name: "Station 2",
        latitude: 56.424667,
        longitude: -160.748000,
        coordinateDMM: "56° 25.480' N, 160° 44.880' W",
        confidence: .documented
    ),
    PMTFStation(
        stationNumber: 4,
        name: "Station 4",
        latitude: 56.585833,
        longitude: -160.845167,
        coordinateDMM: "56° 35.150' N, 160° 50.710' W",
        confidence: .documented
    ),
    PMTFStation(
        stationNumber: 6,
        name: "Station 6",
        latitude: 56.751167,
        longitude: -160.949333,
        coordinateDMM: "56° 45.070' N, 160° 56.960' W",
        confidence: .documented
    ),
    PMTFStation(
        stationNumber: 8,
        name: "Station 8",
        latitude: 56.907167,
        longitude: -161.032667,
        coordinateDMM: "56° 54.430' N, 161° 01.960' W",
        confidence: .documented
    ),
    PMTFStation(
        stationNumber: 10,
        name: "Station 10",
        latitude: 57.064333,
        longitude: -161.130500,
        coordinateDMM: "57° 03.860' N, 161° 07.830' W",
        confidence: .documented
    ),
    PMTFStation(
        stationNumber: 12,
        name: "Station 12",
        latitude: 57.224054,
        longitude: -161.228185,
        coordinateDMM: "57° 13.443' N, 161° 13.691' W",
        confidence: .estimated
    ),
    PMTFStation(
        stationNumber: 14,
        name: "Station 14",
        latitude: 57.383693,
        longitude: -161.326718,
        coordinateDMM: "57° 23.022' N, 161° 19.603' W",
        confidence: .estimated
    ),
    PMTFStation(
        stationNumber: 16,
        name: "Station 16",
        latitude: 57.543251,
        longitude: -161.426110,
        coordinateDMM: "57° 32.595' N, 161° 25.567' W",
        confidence: .estimated
    ),
    PMTFStation(
        stationNumber: 18,
        name: "Station 18",
        latitude: 57.702726,
        longitude: -161.526375,
        coordinateDMM: "57° 42.164' N, 161° 31.582' W",
        confidence: .estimated
    ),
    PMTFStation(
        stationNumber: 20,
        name: "Station 20",
        latitude: 57.862117,
        longitude: -161.627525,
        coordinateDMM: "57° 51.727' N, 161° 37.651' W",
        confidence: .estimated
    ),
    PMTFStation(
        stationNumber: 22,
        name: "Station 22",
        latitude: 58.021422,
        longitude: -161.729572,
        coordinateDMM: "58° 01.285' N, 161° 43.774' W",
        confidence: .estimated
    ),
    PMTFStation(
        stationNumber: 24,
        name: "Station 24",
        latitude: 58.180641,
        longitude: -161.832531,
        coordinateDMM: "58° 10.838' N, 161° 49.952' W",
        confidence: .estimated
    ),
    PMTFStation(
        stationNumber: 26,
        name: "Station 26",
        latitude: 58.339772,
        longitude: -161.936414,
        coordinateDMM: "58° 20.386' N, 161° 56.185' W",
        confidence: .estimated
    )
]

let portMollerTestFisheryStationCoordinates: [CLLocationCoordinate2D] =
    portMollerTestFisheryStations.map(\.coordinate)

let portMollerTestFisheryTransect = MKPolyline(coordinates: portMollerTestFisheryStationCoordinates, count: portMollerTestFisheryStationCoordinates.count)
