import Foundation
import GRDB
import Combine

enum OfflineDatabaseResource {
    static let resourceName = "offline"
    static let resourceExtension = "sqlite"
    static let subdirectory = "public/packs"

    static var displayName: String {
        "\(resourceName).\(resourceExtension)"
    }

    static func bundledSQLiteURL(bundle: Bundle = .main) -> URL? {
        bundle.url(
            forResource: resourceName,
            withExtension: resourceExtension,
            subdirectory: subdirectory
        )
    }

    static func expectedBundlePathDescription(bundle: Bundle = .main) -> String {
        bundle.bundleURL
            .appendingPathComponent(subdirectory, isDirectory: true)
            .appendingPathComponent(displayName)
            .path
    }
}

enum AppDatabaseOpenError: LocalizedError {
    case missingDatabase(expectedBundlePath: String, appSupportPath: String)
    case missingRequiredTable(String)
    case missingRequiredColumn(table: String, column: String)
    case emptyRequiredTable(String)
    case invalidDistrictKeys([String])
    case integrityCheckFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingDatabase(let expectedBundlePath, let appSupportPath):
            return "Offline database was not found. Expected bundled resource at \(expectedBundlePath), or fallback copy at \(appSupportPath)."
        case .missingRequiredTable(let table):
            return "Offline database is missing required table: \(table)"
        case .missingRequiredColumn(let table, let column):
            return "Offline database table \(table) is missing required column: \(column)"
        case .emptyRequiredTable(let table):
            return "Offline database required table is empty: \(table)"
        case .invalidDistrictKeys(let keys):
            return "Offline database has unexpected district keys: \(keys.joined(separator: ", "))"
        case .integrityCheckFailed(let result):
            return "Offline database integrity check failed: \(result)"
        }
    }
}

final class AppDatabase {
    let dbQueue: DatabaseQueue
    let databaseURL: URL
    let sourceDescription: String

    private init(dbQueue: DatabaseQueue, databaseURL: URL, sourceDescription: String) {
        self.dbQueue = dbQueue
        self.databaseURL = databaseURL
        self.sourceDescription = sourceDescription
    }

    /// Open the already-installed offline sqlite DB.
    /// The bundled read-only SQLite is preferred for TestFlight/App Store installs.
    /// Application Support is only a fallback for legacy downloaded/unpacked copies.
    static func open() throws -> AppDatabase {
        let bundledURL = OfflineDatabaseResource.bundledSQLiteURL()
        let appSupportURL = try OfflinePaths.offlineSQLiteURL()
        let appSupportExists = FileManager.default.fileExists(atPath: appSupportURL.path)
        let expectedBundlePath = OfflineDatabaseResource.expectedBundlePathDescription()

        #if DEBUG
        print("""
        🔎 Offline DB lookup
          resource: \(OfflineDatabaseResource.displayName)
          bundle expected: \(expectedBundlePath)
          bundled seed found: \(bundledURL != nil)
          app support fallback: \(appSupportURL.path)
          app support fallback exists: \(appSupportExists)
          fresh install fallback state: \(appSupportExists ? "existing fallback copy" : "no fallback copy")
        """)
        #endif

        var bundledOpenError: Error?
        if let bundledURL {
            do {
                return try openReadOnly(at: bundledURL, source: "bundled read-only resource")
            } catch {
                bundledOpenError = error
                #if DEBUG
                print("⚠️ Offline DB bundled resource failed to open: \(error.localizedDescription)")
                #endif
            }
        }

        if appSupportExists {
            return try openReadOnly(at: appSupportURL, source: "Application Support fallback")
        }

        if let bundledOpenError {
            throw bundledOpenError
        }

        throw AppDatabaseOpenError.missingDatabase(
            expectedBundlePath: expectedBundlePath,
            appSupportPath: appSupportURL.path
        )
    }

    static func bundledDatabaseExists() -> Bool {
        OfflineDatabaseResource.bundledSQLiteURL() != nil
    }

    private static func openReadOnly(at url: URL, source: String) throws -> AppDatabase {
        var config = Configuration()
        config.readonly = true

        let queue = try DatabaseQueue(path: url.path, configuration: config)
        try validate(queue)
        #if DEBUG
        print("✅ Offline DB opened from \(source): \(url.lastPathComponent)")
        #endif
        return AppDatabase(dbQueue: queue, databaseURL: url, sourceDescription: source)
    }

    private static func validate(_ queue: DatabaseQueue) throws {
        try queue.read { db in
            let integrity = try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "missing result"
            guard integrity == "ok" else {
                throw AppDatabaseOpenError.integrityCheckFailed(integrity)
            }

            let requiredTables = [
                "meta",
                "districts",
                "rivers",
                "ops_day",
                "registration_day",
                "river_day",
                "district_year_adjustment",
                "allocation_year",
                "river_system_fva",
                "exporter_sockeye_per_boat_daily",
                "run_timing_river_lag",
                "district_run_timing_day",
                "district_run_timing_summary",
                "district_run_timing_reference_day",
                "district_season_metrics",
                "optimal_transfer_plan_day"
            ]

            for table in requiredTables {
                let tableCount = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*)
                    FROM sqlite_master
                    WHERE type IN ('table', 'view')
                      AND name = ?
                """, arguments: [table]) ?? 0

                guard tableCount > 0 else {
                    throw AppDatabaseOpenError.missingRequiredTable(table)
                }
            }

            for table in [
                "districts",
                "rivers",
                "ops_day",
                "registration_day",
                "river_day",
                "allocation_year",
                "exporter_sockeye_per_boat_daily",
                "run_timing_river_lag",
                "district_run_timing_day",
                "district_run_timing_summary",
                "district_run_timing_reference_day",
                "district_season_metrics",
                "optimal_transfer_plan_day"
            ] {
                let rowCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
                guard rowCount > 0 else {
                    throw AppDatabaseOpenError.emptyRequiredTable(table)
                }
            }

            let optimalRequiredColumns = [
                "year",
                "date",
                "district_key",
                "sockeye_per_boat_daily",
                "status",
                "is_cooldown_day",
                "transfer",
                "transfer_to",
                "penalty_days_applied",
                "cumulative_sockeye_per_boat_to_date"
            ]
            let optimalColumns = Set(try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('optimal_transfer_plan_day')"))
            for column in optimalRequiredColumns {
                guard optimalColumns.contains(column) else {
                    throw AppDatabaseOpenError.missingRequiredColumn(table: "optimal_transfer_plan_day", column: column)
                }
            }

            let districtKeys = try String.fetchAll(db, sql: "SELECT key FROM districts ORDER BY key")
            let expectedDistrictKeys = ["egegik", "naknek_kvichak", "nushagak", "togiak", "ugashik"]
            guard districtKeys == expectedDistrictKeys else {
                throw AppDatabaseOpenError.invalidDistrictKeys(districtKeys)
            }
        }
    }
}
