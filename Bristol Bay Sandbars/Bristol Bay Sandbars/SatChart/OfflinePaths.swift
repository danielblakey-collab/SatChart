import Foundation

enum OfflinePaths {
    static func databaseDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dbDir = appSupport.appendingPathComponent("Database", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        try excludeFromBackup(url: dbDir)
        return dbDir
    }

    static func offlineSQLiteURL() throws -> URL {
        try databaseDirectory().appendingPathComponent("offline.sqlite")
    }

    static func offlineGzipURL() throws -> URL {
        try databaseDirectory().appendingPathComponent("offline.sqlite.gz")
    }

    static func offlineTempSQLiteURL() throws -> URL {
        try databaseDirectory().appendingPathComponent("offline.tmp.sqlite")
    }

    private static func excludeFromBackup(url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}
