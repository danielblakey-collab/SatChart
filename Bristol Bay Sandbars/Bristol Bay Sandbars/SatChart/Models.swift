import Foundation

enum DistrictKey: String, CaseIterable, Identifiable {
  case naknekKvichak = "naknek-kvichak"
  case egegik = "egegik"
  case ugashik = "ugashik"
  case nushagak = "nushagak"
  case togiak = "togiak"

  var id: String { rawValue }

  var shortName: String {
    switch self {
    case .naknekKvichak: return "NK"
    case .egegik: return "Egegik"
    case .ugashik: return "Ugashik"
    case .nushagak: return "Nushagak"
    case .togiak: return "Togiak"
    }
  }
}

struct EscapementPoint: Hashable {
  let riverKey: String
  let method: String
  let daily: Double?
  let cumulative: Double?
  let isOperational: Bool
}

struct DailyDerivedRow: Identifiable, Hashable {
  var id: String { "\(date)__\(districtKey.rawValue)" }

  let year: Int
  let date: String
  let districtKey: DistrictKey

  let driftBoats: Int
  let driftOpenHours: Double
  let driftBoatHours: Double

  let totalHarvest: Double?
  let sockeyeHarvest: Double?

  let avgSockeyePerDriftBoat: Double?
  let sockeyePerDriftBoatHour: Double?

  let bestDistrictKey: String?
  let bestValue: Double?
  let teleportMOI: Double?

  // No “primary river” in the app:
  let escapementDetails: [EscapementPoint]

  let flags: [String]
  let notes: [String]
}
