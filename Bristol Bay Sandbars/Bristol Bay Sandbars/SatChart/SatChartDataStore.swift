import Foundation
import FirebaseFirestore
import Combine

@MainActor
final class SatChartDataStore: ObservableObject {
  @Published var rows: [DailyDerivedRow] = []
  @Published var isLoading = false
  @Published var errorMessage: String?

  private let db = Firestore.firestore()

  private static func todayYYYYMMDD() -> String {
    let now = Date()
    let cal = Calendar(identifier: .gregorian)
    let fmt = DateFormatter()
    fmt.calendar = cal
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(secondsFromGMT: 0)
    fmt.dateFormat = "yyyy-MM-dd"
    return fmt.string(from: now)
  }

  /// Convenience overload: fetch rows for "today" (UTC day) when the caller doesn't specify a date.
  func fetchDailyDerived(year: Int) async {
    await fetchDailyDerived(year: year, date: Self.todayYYYYMMDD())
  }

  /// Fetch a range of dailyDerived rows between startDate and endDate (inclusive).
  /// NOTE: Requires Firestore composite index on (date) if you add additional filters.
  func fetchDailyDerived(year: Int, startDate: String, endDate: String) async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      let snap = try await db
        .collection("historical").document(String(year))
        .collection("dailyDerived")
        .whereField("date", isGreaterThanOrEqualTo: startDate)
        .whereField("date", isLessThanOrEqualTo: endDate)
        .order(by: "date")
        .getDocuments()

      let parsed: [DailyDerivedRow] = snap.documents.compactMap { doc in
        Self.parseDailyDerived(doc: doc)
      }
      self.rows = parsed.sorted { $0.districtKey.rawValue < $1.districtKey.rawValue }
    } catch {
      self.errorMessage = error.localizedDescription
      self.rows = []
    }
  }

  func fetchDailyDerived(year: Int, date: String) async {
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      let snap = try await db
        .collection("historical").document(String(year))
        .collection("dailyDerived")
        .whereField("date", isEqualTo: date)
        .getDocuments()

      let parsed: [DailyDerivedRow] = snap.documents.compactMap { doc in
        Self.parseDailyDerived(doc: doc)
      }
      self.rows = parsed.sorted { $0.districtKey.rawValue < $1.districtKey.rawValue }
    } catch {
      self.errorMessage = error.localizedDescription
      self.rows = []
    }
  }

  // NOTE: made internal (not private) so other files (e.g. DeepResearchView) can reuse it.
  static func parseDailyDerived(doc: QueryDocumentSnapshot) -> DailyDerivedRow? {
    let d = doc.data()

    guard
      let year = d["year"] as? Int,
      let date = d["date"] as? String,
      let dkStr = d["districtKey"] as? String,
      let districtKey = DistrictKey(rawValue: dkStr)
    else { return nil }

    func dbl(_ key: String) -> Double? {
      if let n = d[key] as? Double { return n }
      if let n = d[key] as? Int { return Double(n) }
      return nil
    }

    func int(_ key: String) -> Int? {
      if let n = d[key] as? Int { return n }
      if let n = d[key] as? Double { return Int(n) }
      return nil
    }

    let driftBoats = int("driftBoats") ?? 0
    let driftOpenHours = dbl("driftOpenHours") ?? 0
    let driftBoatHours = dbl("driftBoatHours") ?? 0

    let totalHarvest = dbl("totalHarvest")
    let sockeyeHarvest = dbl("sockeyeHarvest")

    let avgSockeyePerDriftBoat = dbl("avgSockeyePerDriftBoat") ?? dbl("avgCatchPerDriftBoat")
    let sockeyePerDriftBoatHour = dbl("sockeyePerDriftBoatHour") ?? dbl("fishPerDriftBoatHour")

    let bestDistrictKey = d["bestDistrictKey_avgSockeyePerDriftBoat"] as? String
      ?? d["bestDistrictKey_avgCatchPerDriftBoat"] as? String

    let bestValue = dbl("bestValue_avgSockeyePerDriftBoat") ?? dbl("bestValue_avgCatchPerDriftBoat")
    let teleportMOI = dbl("teleportMOI_avgSockeyePerDriftBoat") ?? dbl("teleportMOI_avgCatchPerDriftBoat")

    let flags = d["flags"] as? [String] ?? []
    let notes = d["notes"] as? [String] ?? []

    let escapementDetails: [EscapementPoint] =
      (d["escapementDetails"] as? [[String: Any]] ?? []).map { e in
        EscapementPoint(
          riverKey: e["riverKey"] as? String ?? "",
          method: e["method"] as? String ?? "",
          daily: (e["daily"] as? Double) ?? (e["daily"] as? Int).map(Double.init),
          cumulative: (e["cumulative"] as? Double) ?? (e["cumulative"] as? Int).map(Double.init),
          isOperational: e["isOperational"] as? Bool ?? false
        )
      }
      .sorted { $0.riverKey < $1.riverKey }

    return DailyDerivedRow(
      year: year,
      date: date,
      districtKey: districtKey,
      driftBoats: driftBoats,
      driftOpenHours: driftOpenHours,
      driftBoatHours: driftBoatHours,
      totalHarvest: totalHarvest,
      sockeyeHarvest: sockeyeHarvest,
      avgSockeyePerDriftBoat: avgSockeyePerDriftBoat,
      sockeyePerDriftBoatHour: sockeyePerDriftBoatHour,
      bestDistrictKey: bestDistrictKey,
      bestValue: bestValue,
      teleportMOI: teleportMOI,
      escapementDetails: escapementDetails,
      flags: flags,
      notes: notes
    )
  }
}
