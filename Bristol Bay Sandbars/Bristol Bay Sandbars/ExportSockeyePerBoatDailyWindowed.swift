import Foundation
import SQLite3
import Darwin

// Windowed export of Sockeye/Boat Daily with a "known" period (default 06/12–07/16)
// and an "estimated" period (default 07/17–08/01).
//
// Compile together with RegistrationEstimator.swift so these types exist:
// - RegistrationEstimator / RegistrationEstimatorConfig
// - OpsSnapshot / RegSnapshot / RegistrationEstimatorDay
// - RegistrationEstimate

// MARK: - DB Row structs

private struct OpsRow {
    let date: String
    let driftOpenHours: Double?
    let driftDeliveries: Int?
    let sockeyeDaily: Int?
}

private struct RegRow {
    let date: String
    let driftPermits: Int?
    let dualPermits: Int?
    let driftBoats: Int?
}

// MARK: - CLI helpers

private func usageAndExit(_ msg: String? = nil) -> Never {
    if let msg { fputs("Error: \(msg)\n\n", stderr) }
    fputs(
"""
Usage:
  export_sockeye_per_boat_daily_windowed --db <offline.sqlite> --out <output.csv> \
    [--start-year 2015] [--end-year 2026] \
    [--start-mmdd 06-12] [--known-end-mmdd 07-16] [--end-mmdd 08-01]

Notes:
  - "period" is purely date-based: <= known-end-mmdd => known, else estimated.
  - For 06/12–07/16, driftBoats prefer registration_day.driftBoats (fallback driftPermits).
  - For 07/17–08/01, driftBoats are taken from RegistrationEstimator when available.

Example (single year):
  ./export_sockeye_per_boat_daily_windowed \
    --db /Users/danielblakey/satchart-etl/build/offline/offline.sqlite \
    --out /Users/danielblakey/satchart-etl/build/exports/sockeye_per_boat_daily_2026_0612_0801.csv \
    --start-year 2026 --end-year 2026

Example (range):
  ./export_sockeye_per_boat_daily_windowed \
    --db /Users/danielblakey/satchart-etl/build/offline/offline.sqlite \
    --out /Users/danielblakey/satchart-etl/build/exports/sockeye_per_boat_daily_2015_2026_0612_0801.csv \
    --start-year 2015 --end-year 2026
""",
        stderr
    )
    exit(1)
}

private func argValue(_ name: String) -> String? {
    if let idx = CommandLine.arguments.firstIndex(of: name), idx + 1 < CommandLine.arguments.count {
        return CommandLine.arguments[idx + 1]
    }
    let prefix = name + "="
    if let arg = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }) {
        return String(arg.dropFirst(prefix.count))
    }
    return nil
}

private func argInt(_ name: String, default def: Int) -> Int {
    if let s = argValue(name), let v = Int(s) { return v }
    return def
}

private func colInt(_ stmt: OpaquePointer?, _ idx: Int32) -> Int? {
    guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
    return Int(sqlite3_column_int64(stmt, idx))
}

private func colDouble(_ stmt: OpaquePointer?, _ idx: Int32) -> Double? {
    guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
    return sqlite3_column_double(stmt, idx)
}

private func colText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
    guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
    guard let c = sqlite3_column_text(stmt, idx) else { return nil }
    return String(cString: c)
}

private func sqliteErr(_ db: OpaquePointer?) -> String {
    guard let db, let c = sqlite3_errmsg(db) else { return "unknown sqlite error" }
    return String(cString: c)
}

private func fmt(_ x: Double, decimals: Int = 4) -> String {
    String(format: "%.\(decimals)f", x)
}

private func dateRangeStrings(from start: String, to end: String) -> [String] {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!

    let df = DateFormatter()
    df.calendar = cal
    df.timeZone = cal.timeZone
    df.locale = Locale(identifier: "en_US_POSIX")
    df.dateFormat = "yyyy-MM-dd"

    guard let s = df.date(from: start), let e = df.date(from: end) else { return [] }
    var out: [String] = []
    var cur = s
    while cur <= e {
        out.append(df.string(from: cur))
        cur = cal.date(byAdding: .day, value: 1, to: cur)!
    }
    return out
}

private func yearDate(_ year: Int, mmdd: String) -> String {
    String(format: "%04d-%@", year, mmdd)
}

private func driftShareFraction(driftPct: Double?, setPct: Double?) -> Double? {
    guard let driftRaw = driftPct else { return nil }

    // Normalize percent-style storage (e.g. 81 => 0.81)
    let drift = driftRaw > 1.0 ? (driftRaw / 100.0) : driftRaw

    // If setPct is missing, preserve the drift fraction as-is.
    guard let setRaw = setPct else { return drift }
    let set = setRaw > 1.0 ? (setRaw / 100.0) : setRaw

    let denom = drift + set
    guard denom > 0 else { return drift }
    return drift / denom
}

private func csvInt(_ x: Int?) -> String { x.map(String.init) ?? "" }
private func csvDouble(_ x: Double?, decimals: Int) -> String { x.map { fmt($0, decimals: decimals) } ?? "" }
private func median(_ values: [Double]) -> Double? {
    let clean = values.filter { $0.isFinite && $0 > 0 }.sorted()
    guard !clean.isEmpty else { return nil }
    let mid = clean.count / 2
    if clean.count % 2 == 1 { return clean[mid] }
    return 0.5 * (clean[mid - 1] + clean[mid])
}
// MARK: - Tool

@main
enum ExportSockeyePerBoatDailyWindowedTool {
    static func main() throws {
        try run()
    }

    static func run() throws {
        if argValue("--help") != nil || argValue("-h") != nil {
            usageAndExit()
        }

        guard let dbPath = argValue("--db") else { usageAndExit("Missing --db") }
        guard let outPath = argValue("--out") else { usageAndExit("Missing --out") }

        let startYear = argInt("--start-year", default: 2015)
        let endYear = argInt("--end-year", default: 2026)
        if startYear > endYear { usageAndExit("--start-year must be <= --end-year") }

        let startMMDD = argValue("--start-mmdd") ?? "06-12"
        let knownEndMMDD = argValue("--known-end-mmdd") ?? "07-16"
        let endMMDD = argValue("--end-mmdd") ?? "08-01"

        let wantedDistrictKeys: [String] = [
            "naknek_kvichak",
            "egegik",
            "ugashik",
            "nushagak",
            "togiak"
        ]

        var db: OpaquePointer?
        let rcOpen: Int32 = dbPath.withCString { cstr in
            sqlite3_open_v2(cstr, &db, SQLITE_OPEN_READONLY, nil)
        }
        guard rcOpen == SQLITE_OK else {
            usageAndExit("Could not open DB: \(dbPath)")
        }
        defer { sqlite3_close(db) }

        var districtIdByKey: [String: Int] = [:]
        var districtKeyById: [Int: String] = [:]
        do {
            var stmt: OpaquePointer?
            let sql = "SELECT id, key FROM districts"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                usageAndExit("Failed to query districts: \(sqliteErr(db))")
            }
            defer { sqlite3_finalize(stmt) }

            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int64(stmt, 0))
                let key = colText(stmt, 1) ?? ""
                if !key.isEmpty {
                    districtIdByKey[key] = id
                    districtKeyById[id] = key
                }
            }
        }

        var allocByYearDistrict: [String: (Double?, Double?)] = [:]
        do {
            var stmt: OpaquePointer?
            let sql = "SELECT year, districtId, driftPct, setPct FROM allocation_year"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(stmt) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let year = Int(sqlite3_column_int64(stmt, 0))
                    let districtId = Int(sqlite3_column_int64(stmt, 1))
                    let drift = colDouble(stmt, 2)
                    let set = colDouble(stmt, 3)
                    if let key = districtKeyById[districtId] {
                        allocByYearDistrict["\(year)|\(key)"] = (drift, set)
                    }
                }
            }
        }

        let outURL = URL(fileURLWithPath: outPath)
        try FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: outPath, contents: nil)
        let fh = try FileHandle(forWritingTo: outURL)
        defer { try? fh.close() }

        func writeLine(_ s: String) throws {
            guard let data = (s + "\n").data(using: .utf8) else { return }
            try fh.write(contentsOf: data)
        }
        
        try writeLine([
            "date",
            "year",
            "districtKey",
            "period",
            "sockeyeDaily",
            "driftOpenHours",
            "driftDeliveries",
            "driftPct",
            "setPct",
            "driftShareFraction",
            "driftSockeyeAllocAdj",
            "driftBoats",
            "registrationEstimatorDriftBoats",
            "boatsSource",
            "sockeyePerBoatRaw",
            "sockeyePerBoatAllocAdj"
        ].joined(separator: ","))

        var exportedRowCount = 0
        var warnedNoOpsCount = 0

        func loadOps(year: Int, districtId: Int, start: String, end: String) -> [String: OpsRow] {
            var out: [String: OpsRow] = [:]
            var stmt: OpaquePointer?
            let sql = """
              SELECT date, driftOpenHours, driftDeliveries, sockeye
              FROM ops_day
              WHERE year = ? AND districtId = ?
                AND date >= ? AND date <= ?
              ORDER BY date
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return out
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(year))
            sqlite3_bind_int(stmt, 2, Int32(districtId))
            sqlite3_bind_text(stmt, 3, (start as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (end as NSString).utf8String, -1, nil)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let date = colText(stmt, 0) ?? ""
                if date.isEmpty { continue }
                let hrs = colDouble(stmt, 1)
                let del = colInt(stmt, 2)
                let sock = colInt(stmt, 3)
                out[date] = OpsRow(date: date, driftOpenHours: hrs, driftDeliveries: del, sockeyeDaily: sock)
            }
            return out
        }

        func loadReg(year: Int, districtId: Int, start: String, end: String) -> [String: RegRow] {
            var out: [String: RegRow] = [:]
            var stmt: OpaquePointer?
            let sql = """
              SELECT date, driftPermits, dualPermits, driftBoats
              FROM registration_day
              WHERE year = ? AND districtId = ?
                AND date >= ? AND date <= ?
              ORDER BY date
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return out
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(year))
            sqlite3_bind_int(stmt, 2, Int32(districtId))
            sqlite3_bind_text(stmt, 3, (start as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (end as NSString).utf8String, -1, nil)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let date = colText(stmt, 0) ?? ""
                if date.isEmpty { continue }
                let p = colInt(stmt, 1)
                let d = colInt(stmt, 2)
                let b = colInt(stmt, 3)
                out[date] = RegRow(date: date, driftPermits: p, dualPermits: d, driftBoats: b)
            }
            return out
        }

        func fallbackBoatsEstimate(
            ops: OpsRow?,
            lastBoats: Int,
            observedDeliveriesPerBoat: Double?
        ) -> Int? {
            guard let ops else { return nil }

            let hrs = ops.driftOpenHours ?? 0
            let del = ops.driftDeliveries ?? 0

            // Only estimate boats when there was real drift activity.
            // Prevent fabricated drift sockeye/boat on zero-hour or zero-delivery days.
            guard hrs > 0, del > 0 else { return nil }

            if let dpb = observedDeliveriesPerBoat, dpb > 0 {
                let boats = Int(round(Double(del) / dpb))
                if boats > 0 { return boats }
            }

            // Do not carry forward or fabricate boats here.
            return nil
        }
        let estimatorConfig = RegistrationEstimatorConfig.default()

        for year in startYear...endYear {
            let windowStart = yearDate(year, mmdd: startMMDD)
            let windowEnd = yearDate(year, mmdd: endMMDD)
            let knownEnd = yearDate(year, mmdd: knownEndMMDD)

            for districtKey in wantedDistrictKeys {
                guard let districtId = districtIdByKey[districtKey] else { continue }

                let opsByDate = loadOps(year: year, districtId: districtId, start: windowStart, end: windowEnd)
                let regByDate = loadReg(year: year, districtId: districtId, start: windowStart, end: windowEnd)

                let observedDeliveriesPerBoat: Double? = {
                    var vals: [Double] = []
                    let observedDates = dateRangeStrings(from: windowStart, to: knownEnd)
                    vals.reserveCapacity(observedDates.count)

                    for dateStr in observedDates {
                        guard let ops = opsByDate[dateStr], let reg = regByDate[dateStr] else { continue }
                        let boats = reg.driftBoats ?? reg.driftPermits ?? 0
                        let del = ops.driftDeliveries ?? 0
                        guard boats > 0, del > 0 else { continue }
                        vals.append(Double(del) / Double(boats))
                    }

                    return median(vals)
                }()
                if opsByDate.isEmpty {
                    warnedNoOpsCount += 1
                    fputs("Warning: no ops_day rows for year=\(year) district=\(districtKey) in window \(windowStart) to \(windowEnd); skipping\n", stderr)
                    continue
                }

                let scaffold = dateRangeStrings(from: windowStart, to: windowEnd)

                let allocKey = "\(year)|\(districtKey)"
                let (driftPctRaw, setPctRaw) = allocByYearDistrict[allocKey] ?? (nil, nil)

                // Export raw allocation fields too so the CSV fully carries the allocation inputs.
                // Normalize percent-style storage (e.g. 83) to fractions (0.83) for export consistency.
                let driftPctOut: Double? = {
                    guard let v = driftPctRaw else { return nil }
                    return v > 1.0 ? (v / 100.0) : v
                }()
                let setPctOut: Double? = {
                    guard let v = setPctRaw else { return nil }
                    return v > 1.0 ? (v / 100.0) : v
                }()

                let driftShare = driftShareFraction(driftPct: driftPctRaw, setPct: setPctRaw)
                let driftShareOut = driftShare ?? 1.0

                let observedStartForReg = (districtKey == "togiak") ? yearDate(year, mmdd: "06-20") : windowStart

                let estimatorDays: [RegistrationEstimatorDay] = scaffold.map { dateStr in
                    let ops = opsByDate[dateStr]
                    let reg = regByDate[dateStr]

                    let opsSnap = OpsSnapshot(
                        driftOpenHours: ops?.driftOpenHours,
                        driftDeliveries: ops?.driftDeliveries,
                        sockeyeDaily: ops?.sockeyeDaily
                    )

                    let isInObservedRegWindow = (dateStr >= observedStartForReg && dateStr <= knownEnd)
                    let regSnap: RegSnapshot? = isInObservedRegWindow ? RegSnapshot(
                        driftPermits: reg?.driftPermits,
                        dualPermits: reg?.dualPermits,
                        driftBoats: reg?.driftBoats
                    ) : nil

                    return RegistrationEstimatorDay(date: dateStr, ops: opsSnap, regObserved: regSnap)
                }

                let regEstimatesByDate = RegistrationEstimator.estimatePostWindowRegistration(
                    districtKey: districtKey,
                    year: year,
                    days: estimatorDays,
                    config: estimatorConfig
                )

                var lastBoats: Int = 0

                for dateStr in scaffold {
                    let period = (dateStr <= knownEnd) ? "known" : "estimated"

                    let ops = opsByDate[dateStr]
                    let reg = regByDate[dateStr]

                    var boatsUsed: Int = 0
                    var boatsSource = ""
                    let driftBoatsFromDB: Int? = {
                        if let b = reg?.driftBoats { return max(0, b) }
                        if let p = reg?.driftPermits { return max(0, p) }
                        return nil
                    }()

                    let registrationEstimatorDriftBoats: Int? = {
                        guard let est = regEstimatesByDate[dateStr] else { return nil }
                        return max(0, est.driftBoats)
                    }()

                    // Prefer observed DB registration when available.
                    // Next prefer the RegistrationEstimator when it has a value.
                    // Finally, for days with ops activity but no registration row, use a fallback
                    // deliveries-based estimate so the exporter does not collapse to carryForward=0.

                    if let dbBoats = driftBoatsFromDB {
                        boatsUsed = dbBoats
                        boatsSource = (reg?.driftBoats != nil) ? "driftBoats" : "driftPermits"
                    } else if let estBoats = registrationEstimatorDriftBoats {
                        boatsUsed = estBoats
                        boatsSource = "registrationEstimator"
                    } else if let fallbackBoats = fallbackBoatsEstimate(
                        ops: ops,
                        lastBoats: lastBoats,
                        observedDeliveriesPerBoat: observedDeliveriesPerBoat
                    ) {
                        boatsUsed = fallbackBoats
                        boatsSource = "fallbackEstimator"
                    }

                    // Only remember a prior fleet size from days with real drift activity.
                    // Only remember a prior fleet size from days with real drift activity.
                    let hasRealDriftActivity = (ops?.driftOpenHours ?? 0) > 0 && (ops?.driftDeliveries ?? 0) > 0
                    if hasRealDriftActivity && boatsUsed > 0 {
                        lastBoats = boatsUsed
                    }

                    let sockeye0 = Double(ops?.sockeyeDaily ?? 0)
                    let driftSockeyeAllocAdj = sockeye0 * driftShareOut
                    let participating = (boatsUsed > 0) && hasRealDriftActivity
                    let boatsDen = Double(max(1, boatsUsed))
                    let sockeyePerBoatRaw = participating ? (sockeye0 / boatsDen) : 0.0
                    let sockeyePerBoatAdj = participating ? (driftSockeyeAllocAdj / boatsDen) : 0.0

                    let line = [
                        dateStr,
                        String(year),
                        districtKey,
                        period,
                        csvInt(ops?.sockeyeDaily),
                        csvDouble(ops?.driftOpenHours, decimals: 2),
                        csvInt(ops?.driftDeliveries),
                        csvDouble(driftPctOut, decimals: 4),
                        csvDouble(setPctOut, decimals: 4),
                        fmt(driftShareOut, decimals: 4),
                        fmt(driftSockeyeAllocAdj, decimals: 3),
                        String(boatsUsed),
                        csvInt(registrationEstimatorDriftBoats),
                        boatsSource,
                        fmt(sockeyePerBoatRaw, decimals: 3),
                        fmt(sockeyePerBoatAdj, decimals: 3)
                    ].joined(separator: ",")

                    try writeLine(line)
                    exportedRowCount += 1
                }
            }
        }

        if exportedRowCount == 0 {
            fputs("Warning: exported 0 data rows (header only). DB may not contain ops_day data for the requested years/window.\n", stderr)
        }
        if warnedNoOpsCount > 0 {
            fputs("Note: skipped \(warnedNoOpsCount) year/district windows due to missing ops_day data.\n", stderr)
        }
        print("Wrote:", outPath)
    }
}
