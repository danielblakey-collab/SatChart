import Foundation
import SQLite3

let dbPath = "/Users/danielblakey/satchart-etl/build/offline/offline.sqlite"

let districts = [
    "naknek_kvichak",
    "egegik",
    "ugashik",
    "nushagak",
    "togiak"
]

let years = Array(2015...2024)

enum DumpError: Error {
    case sqliteOpenFailed(String)
    case sqlitePrepareFailed(String)
}

func openDatabase(path: String) throws -> OpaquePointer {
    var db: OpaquePointer?
    if sqlite3_open(path, &db) != SQLITE_OK {
        let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite open error"
        if let db { sqlite3_close(db) }
        throw DumpError.sqliteOpenFailed(msg)
    }
    guard let db else {
        throw DumpError.sqliteOpenFailed("sqlite returned nil database pointer")
    }
    return db
}

func prepareStatement(db: OpaquePointer, sql: String) throws -> OpaquePointer {
    var stmt: OpaquePointer?
    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
        let msg = String(cString: sqlite3_errmsg(db))
        throw DumpError.sqlitePrepareFailed(msg + " | SQL: " + sql)
    }
    guard let stmt else {
        throw DumpError.sqlitePrepareFailed("sqlite returned nil statement")
    }
    return stmt
}

func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
    sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
}

func bindInt(_ stmt: OpaquePointer, _ index: Int32, _ value: Int) {
    sqlite3_bind_int(stmt, index, Int32(value))
}

func columnString(_ stmt: OpaquePointer, _ index: Int32) -> String? {
    guard let c = sqlite3_column_text(stmt, index) else { return nil }
    return String(cString: c)
}

func columnInt(_ stmt: OpaquePointer, _ index: Int32) -> Int? {
    if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
    return Int(sqlite3_column_int(stmt, index))
}

func columnDouble(_ stmt: OpaquePointer, _ index: Int32) -> Double? {
    if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
    return sqlite3_column_double(stmt, index)
}

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func loadDays(
    db: OpaquePointer,
    districtKey: String,
    year: Int,
    start: String,
    end: String
) throws -> [RegistrationEstimatorDay] {
    let opsSQL = """
        SELECT
            o.date,
            o.driftOpenHours,
            o.driftDeliveries,
            o.sockeye
        FROM ops_day o
        JOIN districts d ON d.id = o.districtId
        WHERE d.key = ?
          AND o.year = ?
          AND o.date >= ?
          AND o.date <= ?
        ORDER BY o.date
    """

    let regSQL = """
        SELECT
            r.date,
            r.driftPermits,
            r.dualPermits,
            r.driftBoats
        FROM registration_day r
        JOIN districts d ON d.id = r.districtId
        WHERE d.key = ?
          AND r.year = ?
          AND r.date >= ?
          AND r.date <= ?
        ORDER BY r.date
    """

    let regStmt = try prepareStatement(db: db, sql: regSQL)
    defer { sqlite3_finalize(regStmt) }

    bindText(regStmt, 1, districtKey)
    bindInt(regStmt, 2, year)
    bindText(regStmt, 3, start)
    bindText(regStmt, 4, end)

    var regMap: [String: RegSnapshot] = [:]

    while sqlite3_step(regStmt) == SQLITE_ROW {
        guard let date = columnString(regStmt, 0) else { continue }
        let reg = RegSnapshot(
            driftPermits: columnInt(regStmt, 1),
            dualPermits: columnInt(regStmt, 2),
            driftBoats: columnInt(regStmt, 3)
        )
        regMap[date] = reg
    }

    let opsStmt = try prepareStatement(db: db, sql: opsSQL)
    defer { sqlite3_finalize(opsStmt) }

    bindText(opsStmt, 1, districtKey)
    bindInt(opsStmt, 2, year)
    bindText(opsStmt, 3, start)
    bindText(opsStmt, 4, end)

    var days: [RegistrationEstimatorDay] = []

    while sqlite3_step(opsStmt) == SQLITE_ROW {
        guard let date = columnString(opsStmt, 0) else { continue }

        let ops = OpsSnapshot(
            driftOpenHours: columnDouble(opsStmt, 1),
            driftDeliveries: columnInt(opsStmt, 2),
            sockeyeDaily: columnInt(opsStmt, 3)
        )

        let day = RegistrationEstimatorDay(
            date: date,
            ops: ops,
            regObserved: regMap[date]
        )
        days.append(day)
    }

    return days
}

@main
struct RegistrationEstimatorDumpRunner {
    static func main() {
        do {
            let db = try openDatabase(path: dbPath)
            defer { sqlite3_close(db) }

            print("year,district,date,driftBoats,rawBoatEstimate,smoothedBoatEstimate,confidence,notes")

            for districtKey in districts {
                for year in years {
                    let start = String(format: "%04d-06-12", year)
                    let end   = String(format: "%04d-08-20", year)

                    let days = try loadDays(
                        db: db,
                        districtKey: districtKey,
                        year: year,
                        start: start,
                        end: end
                    )

                    let config = RegistrationEstimatorConfig.default()

                    let estimates = RegistrationEstimator.estimatePostWindowRegistration(
                        districtKey: districtKey,
                        year: year,
                        days: days,
                        config: config
                    )

                    for (date, e) in estimates.sorted(by: { $0.key < $1.key }) {
                        let notes = e.notes.joined(separator: "|")
                        print([
                            String(year),
                            districtKey,
                            date,
                            String(e.driftBoats),
                            String(format: "%.3f", e.rawBoatEstimate),
                            String(format: "%.3f", e.smoothedBoatEstimate),
                            String(format: "%.3f", e.confidence),
                            notes
                        ].joined(separator: ","))
                    }
                }
            }
        } catch {
            fputs("ERROR: \(error)\n", stderr)
            exit(1)
        }
    }
}
