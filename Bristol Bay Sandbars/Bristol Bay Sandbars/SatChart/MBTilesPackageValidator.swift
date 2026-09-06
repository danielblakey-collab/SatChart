import Foundation
import SQLite3
import CryptoKit
import ImageIO

nonisolated struct MBTilesValidationExpectation: Sendable {
    let packageIdentifier: String
    let version: String
    let expectedByteCount: Int64?
    let expectedSHA256: String?
    let storageSchemeOverride: MBTilesStorageScheme?

    nonisolated init(
        packageIdentifier: String,
        version: String,
        expectedByteCount: Int64? = nil,
        expectedSHA256: String? = nil,
        storageSchemeOverride: MBTilesStorageScheme? = nil
    ) {
        self.packageIdentifier = packageIdentifier
        self.version = version
        self.expectedByteCount = expectedByteCount
        self.expectedSHA256 = expectedSHA256?.lowercased()
        self.storageSchemeOverride = storageSchemeOverride
            ?? MBTilesStorageScheme.explicitLegacyOverride(forPackageSlug: packageIdentifier)
    }
}

nonisolated struct MBTilesValidationReceipt: Codable, Sendable {
    let packageIdentifier: String
    let version: String
    let filename: String
    let byteCount: Int64
    let fileModificationTime: TimeInterval?
    let sha256: String
    let bounds: [Double]?
    let minimumZoom: Int
    let maximumZoom: Int
    let scheme: MBTilesStorageScheme
    let tileFormat: String
    let tileWidth: Int
    let tileHeight: Int
    let tileCount: Int64
    let tileCountsByZoom: [Int: Int64]
    let queryPlan: String
    let validatedAt: Date
    /// Version 1 means `bounds` came from the highest stored zoom's coordinate
    /// envelope rather than being copied from untrusted metadata.
    let coverageEnvelopeVersion: Int?

    nonisolated init(packageIdentifier: String, version: String, filename: String, byteCount: Int64, fileModificationTime: TimeInterval?, sha256: String, bounds: [Double]?, minimumZoom: Int, maximumZoom: Int, scheme: MBTilesStorageScheme, tileFormat: String, tileWidth: Int, tileHeight: Int, tileCount: Int64, tileCountsByZoom: [Int: Int64], queryPlan: String, validatedAt: Date, coverageEnvelopeVersion: Int? = 1) {
        self.packageIdentifier = packageIdentifier
        self.version = version
        self.filename = filename
        self.byteCount = byteCount
        self.fileModificationTime = fileModificationTime
        self.sha256 = sha256
        self.bounds = bounds
        self.minimumZoom = minimumZoom
        self.maximumZoom = maximumZoom
        self.scheme = scheme
        self.tileFormat = tileFormat
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.tileCount = tileCount
        self.tileCountsByZoom = tileCountsByZoom
        self.queryPlan = queryPlan
        self.validatedAt = validatedAt
        self.coverageEnvelopeVersion = coverageEnvelopeVersion
    }
}

nonisolated enum MBTilesValidationError: LocalizedError {
    case unreadable(String)
    case wrongByteCount(expected: Int64, actual: Int64)
    case checksumMismatch
    case invalidHeader
    case integrityCheck(String)
    case malformedSchema(String)
    case inefficientQueryPlan(String)
    case duplicateCoordinates
    case invalidCoordinates
    case invalidMetadata(String)
    case emptyPackage
    case unsupportedImage
    case inconsistentImages
    case identityMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail): return "The map package is unreadable: \(detail)"
        case .wrongByteCount(let expected, let actual): return "Map size mismatch (expected \(expected), received \(actual))."
        case .checksumMismatch: return "The map package checksum does not match its trusted manifest."
        case .invalidHeader: return "The map package does not have a valid SQLite header."
        case .integrityCheck(let detail): return "SQLite integrity validation failed: \(detail)"
        case .malformedSchema(let detail): return "The MBTiles schema is malformed: \(detail)"
        case .inefficientQueryPlan(let detail): return "The MBTiles coordinate query is not indexed: \(detail)"
        case .duplicateCoordinates: return "The map package contains duplicate tile coordinates."
        case .invalidCoordinates: return "The map package contains out-of-range tile coordinates."
        case .invalidMetadata(let detail): return "The MBTiles metadata is invalid: \(detail)"
        case .emptyPackage: return "The map package contains no tiles."
        case .unsupportedImage: return "The map package contains an unsupported or undecodable tile image."
        case .inconsistentImages: return "The map package mixes tile formats or dimensions unexpectedly."
        case .identityMismatch(let expected, let actual): return "Map identity mismatch (expected \(expected), found \(actual))."
        }
    }
}

nonisolated enum MBTilesPackageValidator {
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Lightweight compatibility path for validation receipts written before
    /// derived geographic bounds were recorded. Inventory discovery already runs
    /// off-main, so this performs one read-only aggregate without rehashing the pack.
    nonisolated static func derivedBounds(
        at url: URL,
        maximumZoom: Int,
        scheme: MBTilesStorageScheme
    ) -> [Double]? {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close_v2(database) }
            return nil
        }
        defer { sqlite3_close_v2(database) }
        sqlite3_exec(database, "PRAGMA query_only=ON;", nil, nil, nil)
        return derivedBounds(at: maximumZoom, scheme: scheme, database: database)
    }

    /// Validates a staged package without mutating it. This is intentionally synchronous;
    /// callers run it on a utility worker before publishing an active descriptor.
    nonisolated static func validate(at url: URL, expectation: MBTilesValidationExpectation) throws -> MBTilesValidationReceipt {
        guard !Thread.isMainThread else {
            throw MBTilesValidationError.unreadable("validation was incorrectly scheduled on the main thread")
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey])
        guard values.isRegularFile == true else { throw MBTilesValidationError.unreadable("not a regular file") }
        let byteCount = Int64(values.fileSize ?? 0)
        guard byteCount >= 100 else { throw MBTilesValidationError.invalidHeader }
        if let expected = expectation.expectedByteCount, expected > 0, byteCount != expected {
            throw MBTilesValidationError.wrongByteCount(expected: expected, actual: byteCount)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 16) ?? Data()
        guard header == Data("SQLite format 3\0".utf8) else { throw MBTilesValidationError.invalidHeader }
        try handle.seek(toOffset: 0)

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        try Task.checkCancellation()
        let sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let expected = expectation.expectedSHA256, !expected.isEmpty, sha256 != expected {
            throw MBTilesValidationError.checksumMismatch
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw MBTilesValidationError.unreadable("SQLite open failed")
        }
        defer { sqlite3_close(database) }
        sqlite3_exec(database, "PRAGMA query_only=ON;", nil, nil, nil)
        sqlite3_exec(database, "PRAGMA cache_size=-2048;", nil, nil, nil)
        sqlite3_exec(database, "PRAGMA mmap_size=0;", nil, nil, nil)

        try Task.checkCancellation()
        let integrity = try stringRows("PRAGMA quick_check;", database: database)
        try Task.checkCancellation()
        guard integrity == ["ok"] else {
            throw MBTilesValidationError.integrityCheck(integrity.joined(separator: "; "))
        }

        guard objectExists("tiles", database: database) else {
            throw MBTilesValidationError.malformedSchema("missing tiles table or view")
        }
        let direct = columnExists("tile_data", table: "tiles", database: database)
        let normalized = columnExists("tile_id", table: "tiles", database: database)
            && objectExists("images", database: database)
            && columnExists("tile_data", table: "images", database: database)
        guard direct || normalized else {
            throw MBTilesValidationError.malformedSchema("neither flat nor normalized tile storage is present")
        }
        for column in ["zoom_level", "tile_column", "tile_row"] where !columnExists(column, table: "tiles", database: database) {
            throw MBTilesValidationError.malformedSchema("missing tiles.\(column)")
        }

        let tileCount = try int64("SELECT COUNT(*) FROM tiles;", database: database)
        guard tileCount > 0 else { throw MBTilesValidationError.emptyPackage }
        let minimumZoom = Int(try int64("SELECT MIN(zoom_level) FROM tiles;", database: database))
        let maximumZoom = Int(try int64("SELECT MAX(zoom_level) FROM tiles;", database: database))
        guard minimumZoom >= 0, maximumZoom <= 30, minimumZoom <= maximumZoom else {
            throw MBTilesValidationError.invalidCoordinates
        }
        let invalidCount = try int64("""
            SELECT COUNT(*) FROM tiles
            WHERE zoom_level < 0 OR zoom_level > 30
               OR tile_column < 0 OR tile_row < 0
               OR tile_column >= (1 << zoom_level)
               OR tile_row >= (1 << zoom_level);
            """, database: database)
        guard invalidCount == 0 else { throw MBTilesValidationError.invalidCoordinates }

        let duplicateCount = try int64("""
            SELECT COUNT(*) FROM (
              SELECT 1 FROM tiles GROUP BY zoom_level,tile_column,tile_row HAVING COUNT(*) > 1
            );
            """, database: database)
        guard duplicateCount == 0 else { throw MBTilesValidationError.duplicateCoordinates }

        let dataExpression = direct ? "tile_data" : "images.tile_data"
        let fromExpression = direct ? "tiles" : "tiles JOIN images ON tiles.tile_id=images.tile_id"
        let tileSQL = "SELECT \(dataExpression) FROM \(fromExpression) WHERE tiles.zoom_level=? AND tiles.tile_column=? AND tiles.tile_row=? LIMIT 1;"
        let queryPlan = try explainPlan(tileSQL, database: database)
        let normalizedPlan = queryPlan.lowercased()
        let searchesCoordinateStore = normalizedPlan.contains("search tiles")
            || normalizedPlan.contains("search map")
        guard searchesCoordinateStore && (normalizedPlan.contains("using index") || normalizedPlan.contains("using covering index")) else {
            throw MBTilesValidationError.inefficientQueryPlan(queryPlan)
        }

        let counts = try zoomCounts(database: database)
        let declaredScheme = metadata("scheme", database: database)
        let scheme: MBTilesStorageScheme
        if let declaredScheme {
            scheme = try MBTilesStorageScheme.metadataValue(declaredScheme)
        } else {
            scheme = expectation.storageSchemeOverride ?? .tms
        }
        let declaredBounds = try parseBounds(metadata("bounds", database: database))
        let nativeBounds = derivedBounds(
            at: maximumZoom,
            scheme: scheme,
            database: database
        )
        let bounds = try validatedCoverageBounds(
            declared: declaredBounds,
            native: nativeBounds
        )
        if let metadataMin = metadata("minzoom", database: database).flatMap(parseZoom), metadataMin != minimumZoom {
            throw MBTilesValidationError.invalidMetadata("minzoom does not match stored tiles")
        }
        if let metadataMax = metadata("maxzoom", database: database).flatMap(parseZoom), metadataMax != maximumZoom {
            throw MBTilesValidationError.invalidMetadata("maxzoom does not match stored tiles")
        }
        if let declaredName = metadata("name", database: database)?.lowercased(),
           !declaredName.isEmpty,
           !identitiesAreCompatible(expected: expectation.packageIdentifier, actual: declaredName) {
            throw MBTilesValidationError.identityMismatch(expected: expectation.packageIdentifier, actual: declaredName)
        }

        let samples = try representativeTiles(direct: direct, database: database)
        guard !samples.isEmpty else { throw MBTilesValidationError.emptyPackage }
        var commonFormat: String?
        var commonWidth: Int?
        var commonHeight: Int?
        for data in samples {
            let image = try rasterDescription(data)
            if let commonFormat, commonFormat != image.format { throw MBTilesValidationError.inconsistentImages }
            if let commonWidth, commonWidth != image.width { throw MBTilesValidationError.inconsistentImages }
            if let commonHeight, commonHeight != image.height { throw MBTilesValidationError.inconsistentImages }
            commonFormat = image.format
            commonWidth = image.width
            commonHeight = image.height
        }
        guard let commonWidth, let commonHeight,
              commonWidth == commonHeight,
              commonWidth == 256 || commonWidth == 512 else {
            throw MBTilesValidationError.invalidMetadata(
                "raster tiles must be square 256 px or 512 px images"
            )
        }
        if let declared = metadata("format", database: database)?.lowercased(),
           let commonFormat,
           !declared.isEmpty,
           declared != commonFormat,
           !(declared == "jpg" && commonFormat == "jpeg") {
            throw MBTilesValidationError.invalidMetadata("format does not match sampled tiles")
        }

        return MBTilesValidationReceipt(
            packageIdentifier: expectation.packageIdentifier,
            version: expectation.version,
            filename: url.lastPathComponent,
            byteCount: byteCount,
            fileModificationTime: values.contentModificationDate?.timeIntervalSince1970,
            sha256: sha256,
            bounds: bounds,
            minimumZoom: minimumZoom,
            maximumZoom: maximumZoom,
            scheme: scheme,
            tileFormat: commonFormat ?? "unknown",
            tileWidth: commonWidth,
            tileHeight: commonHeight,
            tileCount: tileCount,
            tileCountsByZoom: counts,
            queryPlan: queryPlan,
            validatedAt: Date()
        )
    }

    private static func objectExists(_ name: String, database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name=? LIMIT 1;", -1, &statement, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(statement, 1, name, -1, sqliteTransient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func columnExists(_ name: String, table: String, database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else { return false }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 1), String(cString: value).caseInsensitiveCompare(name) == .orderedSame { return true }
        }
        return false
    }

    private static func metadata(_ name: String, database: OpaquePointer) -> String? {
        guard objectExists("metadata", database: database) else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT value FROM metadata WHERE name=? LIMIT 1;", -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(statement, 1, name, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private static func int64(_ sql: String, database: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw MBTilesValidationError.malformedSchema(String(cString: sqlite3_errmsg(database)))
        }
        return sqlite3_column_int64(statement, 0)
    }

    private static func stringRows(_ sql: String, database: OpaquePointer) throws -> [String] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MBTilesValidationError.malformedSchema(String(cString: sqlite3_errmsg(database)))
        }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) { rows.append(String(cString: value)) }
        }
        return rows
    }

    private static func explainPlan(_ sql: String, database: OpaquePointer) throws -> String {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "EXPLAIN QUERY PLAN \(sql)", -1, &statement, nil) == SQLITE_OK else {
            throw MBTilesValidationError.malformedSchema(String(cString: sqlite3_errmsg(database)))
        }
        sqlite3_bind_int(statement, 1, 0)
        sqlite3_bind_int(statement, 2, 0)
        sqlite3_bind_int(statement, 3, 0)
        var details: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 3) { details.append(String(cString: value)) }
        }
        return details.joined(separator: " | ")
    }

    private static func zoomCounts(database: OpaquePointer) throws -> [Int: Int64] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT zoom_level,COUNT(*) FROM tiles GROUP BY zoom_level ORDER BY zoom_level;", -1, &statement, nil) == SQLITE_OK else {
            throw MBTilesValidationError.malformedSchema(String(cString: sqlite3_errmsg(database)))
        }
        var result: [Int: Int64] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            result[Int(sqlite3_column_int(statement, 0))] = sqlite3_column_int64(statement, 1)
        }
        return result
    }

    private static func representativeTiles(direct: Bool, database: OpaquePointer) throws -> [Data] {
        let zooms = try zoomCounts(database: database).keys.sorted()
        let sql = direct
            ? "SELECT tile_data FROM tiles WHERE zoom_level=? LIMIT 1;"
            : "SELECT images.tile_data FROM tiles JOIN images ON tiles.tile_id=images.tile_id WHERE tiles.zoom_level=? LIMIT 1;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MBTilesValidationError.malformedSchema(String(cString: sqlite3_errmsg(database)))
        }
        var result: [Data] = []
        for zoom in zooms {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int(statement, 1, Int32(zoom))
            guard sqlite3_step(statement) == SQLITE_ROW else { continue }
            guard let bytes = sqlite3_column_blob(statement, 0) else { throw MBTilesValidationError.unsupportedImage }
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count > 0 else { throw MBTilesValidationError.unsupportedImage }
            result.append(Data(bytes: bytes, count: count))
        }
        return result
    }

    private static func rasterDescription(_ data: Data) throws -> (format: String, width: Int, height: Int) {
        let format: String
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47]) { format = "png" }
        else if data.starts(with: [0xff, 0xd8, 0xff]) { format = "jpeg" }
        else { throw MBTilesValidationError.unsupportedImage }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              image.width == width, image.height == height else { throw MBTilesValidationError.unsupportedImage }
        return (format, width, height)
    }

    private static func parseZoom(_ value: String) -> Int? {
        Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? Double(value.trimmingCharacters(in: .whitespacesAndNewlines)).map { Int($0.rounded(.towardZero)) }
    }

    private static func parseBounds(_ value: String?) throws -> [Double]? {
        guard let value, !value.isEmpty else { return nil }
        let values = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard values.count == 4,
              (-180...180).contains(values[0]), (-90...90).contains(values[1]),
              (-180...180).contains(values[2]), (-90...90).contains(values[3]),
              values[0] < values[2], values[1] < values[3] else {
            throw MBTilesValidationError.invalidMetadata("bounds")
        }
        return values
    }

    /// Older district packages do not always declare MBTiles metadata bounds. Derive
    /// a deterministic conservative footprint from the highest stored zoom so those
    /// already-valid rasters do not fall back to a world-sized MapKit overlay.
    private static func derivedBounds(
        at zoom: Int,
        scheme: MBTilesStorageScheme,
        database: OpaquePointer
    ) -> [Double]? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
        SELECT MIN(tile_column), MAX(tile_column), MIN(tile_row), MAX(tile_row)
        FROM tiles WHERE zoom_level=?;
        """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(statement, 1, sqlite3_int64(zoom))
        guard sqlite3_step(statement) == SQLITE_ROW,
              (0..<4).allSatisfy({ sqlite3_column_type(statement, Int32($0)) != SQLITE_NULL }) else {
            return nil
        }

        let minimumX = Int(sqlite3_column_int64(statement, 0))
        let maximumX = Int(sqlite3_column_int64(statement, 1))
        let minimumStoredY = Int(sqlite3_column_int64(statement, 2))
        let maximumStoredY = Int(sqlite3_column_int64(statement, 3))
        guard (0...30).contains(zoom) else { return nil }
        let side = Int64(1) << Int64(zoom)
        let minimumYXYZ: Int
        let maximumYXYZ: Int
        switch scheme {
        case .xyz:
            minimumYXYZ = minimumStoredY
            maximumYXYZ = maximumStoredY
        case .tms:
            minimumYXYZ = Int(side - 1 - Int64(maximumStoredY))
            maximumYXYZ = Int(side - 1 - Int64(minimumStoredY))
        }

        func longitude(edge: Int) -> Double {
            Double(edge) / Double(side) * 360.0 - 180.0
        }
        func latitude(edge: Int) -> Double {
            let mercator = Double.pi * (1.0 - 2.0 * Double(edge) / Double(side))
            return atan(sinh(mercator)) * 180.0 / Double.pi
        }

        let result = [
            longitude(edge: minimumX),
            latitude(edge: maximumYXYZ + 1),
            longitude(edge: maximumX + 1),
            latitude(edge: minimumYXYZ)
        ]
        return result.allSatisfy(\.isFinite) ? result : nil
    }

    /// The native tile envelope is authoritative for rendering. Lower zooms often
    /// contain broad ancestor tiles (sometimes z0/world), while metadata bounds can
    /// be stale or clip edge tiles. We still reject a completely unrelated declared
    /// footprint, but never let metadata expand or shrink the coordinate-backed AOI.
    private static func validatedCoverageBounds(
        declared: [Double]?,
        native: [Double]?
    ) throws -> [Double]? {
        guard let native else { return declared }
        guard let declared else { return native }

        let intersectsNative = declared[0] < native[2]
            && declared[2] > native[0]
            && declared[1] < native[3]
            && declared[3] > native[1]
        guard intersectsNative else {
            throw MBTilesValidationError.invalidMetadata(
                "bounds do not intersect the stored native-detail tiles"
            )
        }

        return native
    }

    private static func identitiesAreCompatible(expected: String, actual: String) -> Bool {
        func normalized(_ value: String) -> String {
            value.lowercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "ncds", with: "noaa")
        }
        let lhs = normalized(expected)
        let rhs = normalized(actual)
        return lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }
}
