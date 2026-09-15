import Foundation

/// Curated capture metadata, available even when the device is offline.
/// Egegik and the Togiak regional reference use half-cosine interpolation between NOAA high/low predictions;
/// Ugashik, Nushagak, and Naknek heights use NOAA's harmonic prediction at the exact capture minute.
/// Event labels separately describe the nearest high or low tide.
/// Sources and derivation: docs/{egegik,ugashik,nushagak,naknek,togiak}-capture-tides.md.
struct OfflineMapCaptureTide {
    let dateLabel: String
    let timeLabel: String
    let estimatedHeightFeet: Double // At capture, relative to MLLW; rounded to 0.1 ft.
    let stateLabel: String
    let relativeEventLabel: String
    let eventLabel: String
    let station: Station

    enum Station {
        case egegikRiverEntrance
        case dagoCreekMouth
        case clarksPoint
        case naknek
        case blackRock

        var id: String {
            switch self {
            case .egegikRiverEntrance: return "9464881"
            case .dagoCreekMouth: return "9464512"
            case .clarksPoint: return "9465261"
            case .naknek: return "9465203"
            case .blackRock: return "9465182"
            }
        }

        var name: String {
            switch self {
            case .egegikRiverEntrance: return "Egegik River Entrance"
            case .dagoCreekMouth: return "Dago Creek Mouth, Ugashik Bay"
            case .clarksPoint: return "Clarks Point, Nushagak Bay"
            case .naknek: return "Naknek, Naknek River"
            case .blackRock: return "Black Rock, Walrus Islands"
            }
        }

        var referenceNote: String? {
            self == .blackRock ? "Regional reference · Togiak’s local tide may differ." : nil
        }

        var label: String { "NOAA · \(name)" }
        var url: URL {
            URL(string: "https://tidesandcurrents.noaa.gov/noaatidepredictions.html?id=\(id)")!
        }
    }
}

extension OfflinePack {
    var captureTide: OfflineMapCaptureTide? {
        switch (district, slug) {
        case (.togiak, "togiak"):
            return OfflineMapCaptureTide(
                dateLabel: "9/27/25", timeLabel: "2:05 PM AKDT",
                estimatedHeightFeet: 0.9,
                stateLabel: "Falling",
                relativeEventLabel: "2 min before low tide",
                eventLabel: "Low: 2:07 PM AKDT · 0.9 ft MLLW",
                station: .blackRock)
        case (.egegik, "egegik_v3"):
            return OfflineMapCaptureTide(
                dateLabel: "9/14/25", timeLabel: "1:55 PM AKDT",
                estimatedHeightFeet: -1.9,
                stateLabel: "Falling",
                relativeEventLabel: "26 min before low tide",
                eventLabel: "Low: 2:21 PM AKDT · −2.1 ft MLLW",
                station: .egegikRiverEntrance)
        case (.egegik, "egegik_v4"):
            return OfflineMapCaptureTide(
                dateLabel: "8/7/26", timeLabel: "1:45 PM AKDT",
                estimatedHeightFeet: 1.1,
                stateLabel: "Falling",
                relativeEventLabel: "1 hr 57 min before low tide",
                eventLabel: "Low: 3:42 PM AKDT · −1.5 ft MLLW",
                station: .egegikRiverEntrance)
        case (.egegik, "egegik_v5"):
            return OfflineMapCaptureTide(
                dateLabel: "6/23/26", timeLabel: "1:45 PM AKDT",
                estimatedHeightFeet: 6.1,
                stateLabel: "Falling",
                relativeEventLabel: "3 hr 1 min before low tide",
                eventLabel: "Low: 4:46 PM AKDT · −0.4 ft MLLW",
                station: .egegikRiverEntrance)
        case (.egegik, "egegik_v6"):
            return OfflineMapCaptureTide(
                dateLabel: "5/9/26", timeLabel: "9:45 PM AKDT",
                estimatedHeightFeet: 9.3,
                stateLabel: "Falling",
                relativeEventLabel: "1 hr 56 min after high tide",
                eventLabel: "High: 7:49 PM AKDT · 11.1 ft MLLW",
                station: .egegikRiverEntrance)
        case (.egegik, "egegik_v7"):
            return OfflineMapCaptureTide(
                dateLabel: "7/26/26", timeLabel: "1:55 PM AKDT",
                estimatedHeightFeet: 9.7,
                stateLabel: "Falling",
                relativeEventLabel: "2 hr 47 min after high tide",
                eventLabel: "High: 11:08 AM AKDT · 13.4 ft MLLW",
                station: .egegikRiverEntrance)
        case (.ugashik, "ugashik_v4"):
            return OfflineMapCaptureTide(
                dateLabel: "9/14/25", timeLabel: "1:55 PM AKDT",
                estimatedHeightFeet: -1.8,
                stateLabel: "Rising",
                relativeEventLabel: "9 min after low tide",
                eventLabel: "Low: 1:46 PM AKDT · −1.8 ft MLLW",
                station: .dagoCreekMouth)
        case (.ugashik, "ugashik_v5"):
            return OfflineMapCaptureTide(
                dateLabel: "8/7/26", timeLabel: "1:45 PM AKDT",
                estimatedHeightFeet: -0.3,
                stateLabel: "Falling",
                relativeEventLabel: "1 hr 17 min before low tide",
                eventLabel: "Low: 3:02 PM AKDT · −0.9 ft MLLW",
                station: .dagoCreekMouth)
        case (.ugashik, "ugashik_v6"):
            return OfflineMapCaptureTide(
                dateLabel: "7/26/26", timeLabel: "1:55 PM AKDT",
                estimatedHeightFeet: 5.9,
                stateLabel: "Falling",
                relativeEventLabel: "2 hr 51 min after high tide",
                eventLabel: "High: 11:04 AM AKDT · 9.5 ft MLLW",
                station: .dagoCreekMouth)
        case (.nushagak, "nushagak_v3"):
            return OfflineMapCaptureTide(
                dateLabel: "9/27/25", timeLabel: "2:05 PM AKDT",
                estimatedHeightFeet: 2.7,
                stateLabel: "Falling",
                relativeEventLabel: "7 min before low tide",
                eventLabel: "Low: 2:12 PM AKDT · 2.7 ft MLLW",
                station: .clarksPoint)
        case (.nushagak, "nushagak_v4"):
            return OfflineMapCaptureTide(
                dateLabel: "9/14/25", timeLabel: "1:55 PM AKDT",
                estimatedHeightFeet: 0.5,
                stateLabel: "Falling",
                relativeEventLabel: "1 hr 32 min before low tide",
                eventLabel: "Low: 3:27 PM AKDT · −2.1 ft MLLW",
                station: .clarksPoint)
        case (.nushagak, "nushagak_v5"):
            return OfflineMapCaptureTide(
                dateLabel: "8/15/25", timeLabel: "1:55 PM AKDT",
                estimatedHeightFeet: 1.0,
                stateLabel: "Falling",
                relativeEventLabel: "1 hr 6 min before low tide",
                eventLabel: "Low: 3:01 PM AKDT · −0.3 ft MLLW",
                station: .clarksPoint)
        case (.nushagak, "nushagak_v6"):
            return OfflineMapCaptureTide(
                dateLabel: "10/12/25", timeLabel: "2:05 PM AKDT",
                estimatedHeightFeet: -2.6,
                stateLabel: "Falling",
                relativeEventLabel: "2 min before low tide",
                eventLabel: "Low: 2:07 PM AKDT · −2.6 ft MLLW",
                station: .clarksPoint)
        case (.naknek_kvichak, "naknek_kvichak_v3"):
            return OfflineMapCaptureTide(
                dateLabel: "9/29/25", timeLabel: "1:55 PM AKDT",
                estimatedHeightFeet: 3.3,
                stateLabel: "Falling",
                relativeEventLabel: "2 hr 14 min before low tide",
                eventLabel: "Low: 4:09 PM AKDT · 2.0 ft MLLW",
                station: .naknek)
        case (.naknek_kvichak, "naknek_kvichak_v4"):
            return OfflineMapCaptureTide(
                dateLabel: "10/26/25", timeLabel: "1:46 PM AKDT",
                estimatedHeightFeet: 1.8,
                stateLabel: "Falling",
                relativeEventLabel: "18 min before low tide",
                eventLabel: "Low: 2:04 PM AKDT · 1.8 ft MLLW",
                station: .naknek)
        default:
            return nil
        }
    }
}
