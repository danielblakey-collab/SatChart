import Foundation
import MapKit
import SQLite3

// Needed for sqlite3_bind_text in Swift (equivalent to C's SQLITE_TRANSIENT)
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// MKTileOverlay that serves raster PNG/JPG tiles from an MBTiles (SQLite) file.
final class MBTilesOverlay: MKTileOverlay {

    let slug: String   // ✅ add this

    private let mbtilesURL: URL
    private var db: OpaquePointer?

    private let queue = DispatchQueue(label: "MBTilesOverlay.sqlite.queue")

    /// MBTiles "scheme" is often "tms". If so we flip Y.
    private var isTMS: Bool = true

    /// Some MBTiles use the "images" table schema (tiles.tile_id -> images.tile_data)
    private var usesImagesSchema: Bool = false

    /// Some MBTiles store raster directly in tiles.tile_data
    private var tilesHasTileData: Bool = true

    init(mbtilesURL: URL, slug: String) {
        self.mbtilesURL = mbtilesURL
        self.slug = slug
        super.init(urlTemplate: nil)

        // Standard tile assumptions
        self.canReplaceMapContent = false
        self.tileSize = CGSize(width: 256, height: 256)

        openDB()
        readSchemeMetadata()
        detectSchema()
    }

    convenience init(mbtilesURL: URL) {
        let base = mbtilesURL.deletingPathExtension().lastPathComponent
        self.init(mbtilesURL: mbtilesURL, slug: base)
    }

    deinit {
        queue.sync {
            if db != nil {
                sqlite3_close(db)
                db = nil
            }
        }
    }

    // MARK: - MKTileOverlay

    /// MapKit calls this on its own threads; we bounce to a serial queue to keep SQLite safe.
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        queue.async {
            guard let db = self.db else {
                result(nil, NSError(domain: "MBTilesOverlay", code: -1, userInfo: [NSLocalizedDescriptionKey: "DB not open"]))
                return
            }

            let z = Int32(path.z)
            let x = Int32(path.x)
            let yXYZ = Int32(path.y)

            // Candidate Ys to try (helps when scheme metadata is missing/wrong)
            let tmsY: Int32 = {
                let maxY = (Int32(1) << z) - 1
                return maxY - yXYZ
            }()

            let primaryY: Int32 = self.isTMS ? tmsY : yXYZ
            let secondaryY: Int32 = self.isTMS ? yXYZ : tmsY

            // 1) Try scheme-indicated Y first
            if let data = self.fetchTileData(db: db, z: z, x: x, y: primaryY), self.isValidRasterTile(data) {
                result(data, nil)
                return
            }

            // 2) Fallback: try the other Y scheme (fixes mismatched metadata)
            if primaryY != secondaryY,
               let data = self.fetchTileData(db: db, z: z, x: x, y: secondaryY), self.isValidRasterTile(data) {
                result(data, nil)
                return
            }

            // No tile or not a raster tile (normal)
            result(nil, nil)
        }
    }

    // MARK: - Tile fetch helpers

    /// Returns tile bytes for z/x/y from either schema. Returns nil if no row.
    private func fetchTileData(db: OpaquePointer, z: Int32, x: Int32, y: Int32) -> Data? {
        if tilesHasTileData {
            let sql = "SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=? LIMIT 1;"
            return selectBlob(db: db, sql: sql, binds: [z, x, y])
        }

        // images schema: tiles.tile_id -> images.tile_data
        if usesImagesSchema {
            let sql = """
            SELECT images.tile_data
            FROM tiles
            JOIN images ON tiles.tile_id = images.tile_id
            WHERE tiles.zoom_level=? AND tiles.tile_column=? AND tiles.tile_row=?
            LIMIT 1;
            """
            return selectBlob(db: db, sql: sql, binds: [z, x, y])
        }

        return nil
    }

    /// Executes a SELECT that returns a single BLOB column.
    private func selectBlob(db: OpaquePointer, sql: String, binds: [Int32]) -> Data? {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        for (i, v) in binds.enumerated() {
            sqlite3_bind_int(stmt, Int32(i + 1), v)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
        let length = Int(sqlite3_column_bytes(stmt, 0))
        guard length > 0 else { return nil }
        return Data(bytes: bytes, count: length)
    }

    /// Filter out junk payloads (HTML error pages, vector tiles, etc.) so MapKit doesn't spam decode errors.
    private func isValidRasterTile(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }

        // PNG signature: 89 50 4E 47
        if data.count >= 4,
           data[0] == 0x89, data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47 {
            return true
        }

        // JPEG signature: FF D8 FF
        if data.count >= 3,
           data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF {
            return true
        }

        return false
    }

    // MARK: - SQLite

    private func openDB() {
        queue.sync {
            let path = mbtilesURL.path
            var dbPtr: OpaquePointer?

            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            if sqlite3_open_v2(path, &dbPtr, flags, nil) != SQLITE_OK {
                if let dbPtr { sqlite3_close(dbPtr) }
                db = nil
                print("❌ MBTiles sqlite open failed:", path)
                return
            }

            db = dbPtr
            print("✅ MBTiles sqlite opened:", mbtilesURL.lastPathComponent)

            // Helpful pragmas for speed
            sqlite3_exec(db, "PRAGMA query_only = 1;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA cache_size = -20000;", nil, nil, nil) // ~20MB
            // Detect schema once the DB is open
            self.detectSchemaLocked(db: self.db)
        }
    }

    private func readSchemeMetadata() {
        queue.async {
            guard let db = self.db else { return }

            var scheme: String?
            let sql = "SELECT value FROM metadata WHERE name='scheme' LIMIT 1;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
                // No metadata table or no scheme entry; default stays TMS
                self.isTMS = true
                return
            }
            defer { sqlite3_finalize(stmt) }

            if sqlite3_step(stmt) == SQLITE_ROW, let cstr = sqlite3_column_text(stmt, 0) {
                scheme = String(cString: cstr)
            }

            if let scheme = scheme?.lowercased() {
                self.isTMS = (scheme != "xyz")
                print("🧭 MBTiles scheme:", scheme, "=> flipY(TMS)?", self.isTMS)
            } else {
                self.isTMS = true
                print("🧭 MBTiles scheme: (missing) => assuming TMS (flipY true)")
            }
        }
    }

    private func detectSchema() {
        queue.async {
            guard let db = self.db else { return }
            self.detectSchemaLocked(db: db)
        }
    }

    /// Must be called on `queue`.
    private func detectSchemaLocked(db: OpaquePointer?) {
        guard let db else { return }
        // Check if tiles has tile_data
        self.tilesHasTileData = self.table(db: db, name: "tiles") && self.columnExists(db: db, table: "tiles", column: "tile_data")

        // Check if images schema exists
        let hasTilesId = self.table(db: db, name: "tiles") && self.columnExists(db: db, table: "tiles", column: "tile_id")
        let hasImages = self.table(db: db, name: "images") && self.columnExists(db: db, table: "images", column: "tile_data")
        self.usesImagesSchema = (!self.tilesHasTileData) && hasTilesId && hasImages

        print("🧩 MBTiles schema:",
              "tilesHasTileData=", self.tilesHasTileData,
              "usesImagesSchema=", self.usesImagesSchema)
    }

    private func table(db: OpaquePointer, name: String) -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func columnExists(db: OpaquePointer, table: String, column: String) -> Bool {
        let sql = "PRAGMA table_info(\(table));"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { return false }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 1) {
                let colName = String(cString: cstr)
                if colName.caseInsensitiveCompare(column) == .orderedSame {
                    return true
                }
            }
        }
        return false
    }
}
