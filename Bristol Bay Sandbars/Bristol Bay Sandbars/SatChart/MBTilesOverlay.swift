import Foundation
import MapKit
import SQLite3
import CoreGraphics
import ImageIO

// Needed for sqlite3_bind_text in Swift (equivalent to C's SQLITE_TRANSIENT)
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// MKTileOverlay that serves raster PNG/JPG tiles from an MBTiles (SQLite) file.
final class MBTilesOverlay: MKTileOverlay {

    let slug: String

    private let mbtilesURL: URL
    private var db: OpaquePointer?

    private let queue = DispatchQueue(label: "MBTilesOverlay.sqlite.queue")

    /// MBTiles "scheme" is often "tms". If so we flip Y.
    private var isTMS: Bool = true

    /// Some MBTiles use the "images" table schema (tiles.tile_id -> images.tile_data)
    private var usesImagesSchema: Bool = false

    /// Some MBTiles store raster directly in tiles.tile_data
    private var tilesHasTileData: Bool = true

    /// Source zoom metadata used for runtime raster overzoom when MapKit requests
    /// tiles above the native max zoom stored in the MBTiles file.
    private var sourceMinZoom: Int32?
    private var sourceMaxZoom: Int32?

    init(mbtilesURL: URL, slug: String, canReplaceMapContent: Bool = false) {
        self.mbtilesURL = mbtilesURL
        self.slug = slug
        super.init(urlTemplate: nil)

        self.canReplaceMapContent = canReplaceMapContent
        self.tileSize = CGSize(width: 256, height: 256)

        openDB()
    }

    convenience init(mbtilesURL: URL, canReplaceMapContent: Bool = false) {
        let base = mbtilesURL.deletingPathExtension().lastPathComponent
        self.init(mbtilesURL: mbtilesURL, slug: base, canReplaceMapContent: canReplaceMapContent)
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

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        queue.async {
            guard let db = self.db else {
                result(nil, NSError(domain: "MBTilesOverlay", code: -1, userInfo: [NSLocalizedDescriptionKey: "DB not open"]))
                return
            }

            let requestedZ = Int32(path.z)
            let requestedX = Int32(path.x)
            let requestedYXYZ = Int32(path.y)

            if let data = self.fetchRequestedTileData(
                db: db,
                z: requestedZ,
                x: requestedX,
                yXYZ: requestedYXYZ
            ) {
                result(data, nil)
                return
            }

            if let data = self.fetchOverzoomedTileData(
                db: db,
                requestedZ: requestedZ,
                requestedX: requestedX,
                requestedYXYZ: requestedYXYZ
            ) {
                result(data, nil)
                return
            }

            result(nil, nil)
        }
    }

    // MARK: - Tile fetch helpers

    private enum RasterTileFormat {
        case png
        case jpeg
    }

    private func fetchRequestedTileData(db: OpaquePointer, z: Int32, x: Int32, yXYZ: Int32) -> Data? {
        let tmsY: Int32 = {
            let maxY = (Int32(1) << z) - 1
            return maxY - yXYZ
        }()

        let primaryY: Int32 = isTMS ? tmsY : yXYZ
        let secondaryY: Int32 = isTMS ? yXYZ : tmsY

        if let data = fetchTileData(db: db, z: z, x: x, y: primaryY), isValidRasterTile(data) {
            return data
        }

        if primaryY != secondaryY,
           let data = fetchTileData(db: db, z: z, x: x, y: secondaryY),
           isValidRasterTile(data) {
            return data
        }

        return nil
    }

    private func fetchOverzoomedTileData(
        db: OpaquePointer,
        requestedZ: Int32,
        requestedX: Int32,
        requestedYXYZ: Int32
    ) -> Data? {
        guard let sourceMaxZoom else {
            return nil
        }

        let ancestorFloor = sourceMinZoom ?? 0
        let ancestorCeiling = min(requestedZ - 1, sourceMaxZoom)
        guard ancestorCeiling >= ancestorFloor else {
            return nil
        }

        for candidateZoom in stride(from: ancestorCeiling, through: ancestorFloor, by: -1) {
            let delta = Int(requestedZ - candidateZoom)
            guard delta > 0 else { continue }

            let childScale = 1 << delta
            let ancestorX = Int32(Int(requestedX) >> delta)
            let ancestorYXYZ = Int32(Int(requestedYXYZ) >> delta)
            let childX = Int(requestedX) & (childScale - 1)
            let childY = Int(requestedYXYZ) & (childScale - 1)

            guard let sourceData = fetchRequestedTileData(
                db: db,
                z: candidateZoom,
                x: ancestorX,
                yXYZ: ancestorYXYZ
            ), let format = rasterTileFormat(for: sourceData) else {
                continue
            }

            return overzoomedTileData(
                from: sourceData,
                childX: childX,
                childY: childY,
                childScale: childScale,
                format: format
            )
        }

        return nil
    }

    private func overzoomedTileData(
        from sourceData: Data,
        childX: Int,
        childY: Int,
        childScale: Int,
        format: RasterTileFormat
    ) -> Data? {
        guard childScale > 1 else { return sourceData }

        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(sourceData as CFData, imageSourceOptions),
              let sourceImage = CGImageSourceCreateImageAtIndex(imageSource, 0, imageSourceOptions) else {
            return nil
        }

        let sourceWidth = sourceImage.width
        let sourceHeight = sourceImage.height
        guard sourceWidth > 0, sourceHeight > 0,
              childScale <= sourceWidth, childScale <= sourceHeight else {
            return nil
        }

        let cropWidth = max(1, sourceWidth / childScale)
        let cropHeight = max(1, sourceHeight / childScale)
        let cropX = min(sourceWidth - cropWidth, childX * cropWidth)
        let cropY = min(sourceHeight - cropHeight, childY * cropHeight)
        let cropRect = CGRect(
            x: CGFloat(cropX),
            y: CGFloat(cropY),
            width: CGFloat(cropWidth),
            height: CGFloat(cropHeight)
        ).integral

        guard let croppedImage = sourceImage.cropping(to: cropRect) else {
            return nil
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: sourceWidth,
            height: sourceHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(sourceHeight))
        context.scaleBy(x: 1, y: -1)
        context.draw(
            croppedImage,
            in: CGRect(x: 0, y: 0, width: CGFloat(sourceWidth), height: CGFloat(sourceHeight))
        )

        guard let renderedImage = context.makeImage() else {
            return nil
        }

        return encodeTileData(renderedImage, as: format)
    }

    private func encodeTileData(_ image: CGImage, as format: RasterTileFormat) -> Data? {
        let mutableData = NSMutableData()
        let destinationType: CFString = {
            switch format {
            case .png: return "public.png" as CFString
            case .jpeg: return "public.jpeg" as CFString
            }
        }()

        guard let destination = CGImageDestinationCreateWithData(mutableData, destinationType, 1, nil) else {
            return nil
        }

        let options: CFDictionary?
        switch format {
        case .png:
            options = nil
        case .jpeg:
            options = [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        }

        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return mutableData as Data
    }

    private func fetchTileData(db: OpaquePointer, z: Int32, x: Int32, y: Int32) -> Data? {
        if tilesHasTileData {
            let sql = "SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=? LIMIT 1;"
            return selectBlob(db: db, sql: sql, binds: [z, x, y])
        }

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

    private func isValidRasterTile(_ data: Data) -> Bool {
        rasterTileFormat(for: data) != nil
    }

    private func rasterTileFormat(for data: Data) -> RasterTileFormat? {
        guard data.count >= 4 else { return nil }

        if data[0] == 0x89, data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47 {
            return .png
        }

        if data.count >= 3,
           data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF {
            return .jpeg
        }

        return nil
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
                #if DEBUG
                print("❌ MBTiles sqlite open failed:", path)
                #endif
                return
            }

            db = dbPtr
            #if DEBUG
            print("✅ MBTiles sqlite opened:", mbtilesURL.lastPathComponent)
            #endif

            sqlite3_exec(db, "PRAGMA query_only = 1;", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA cache_size = -20000;", nil, nil, nil)
            self.detectSchemaLocked(db: self.db)
            self.readMetadataLocked(db: self.db)
        }
    }

    private func readMetadataLocked(db: OpaquePointer?) {
        guard let db else { return }

        if let scheme = metadataString(db: db, name: "scheme")?.lowercased() {
            isTMS = (scheme != "xyz")
            #if DEBUG
            print("🧭 MBTiles scheme:", scheme, "=> flipY(TMS)?", isTMS)
            #endif
        } else {
            isTMS = true
            #if DEBUG
            print("🧭 MBTiles scheme: (missing) => assuming TMS (flipY true)")
            #endif
        }

        let queriedMinZoom = selectSingleInt(db: db, sql: "SELECT MIN(zoom_level) FROM tiles;")
        let queriedMaxZoom = selectSingleInt(db: db, sql: "SELECT MAX(zoom_level) FROM tiles;")
        let metadataMinZoom = metadataString(db: db, name: "minzoom").flatMap(parseZoom(from:))
        let metadataMaxZoom = metadataString(db: db, name: "maxzoom").flatMap(parseZoom(from:))

        sourceMinZoom = queriedMinZoom ?? metadataMinZoom
        sourceMaxZoom = queriedMaxZoom ?? metadataMaxZoom

        #if DEBUG
        print(
            "🗺️ MBTiles zoom range:",
            "min=", sourceMinZoom.map { String($0) } ?? "nil",
            "max=", sourceMaxZoom.map { String($0) } ?? "nil"
        )
        #endif
    }

    private func metadataString(db: OpaquePointer, name: String) -> String? {
        let sql = "SELECT value FROM metadata WHERE name=? LIMIT 1;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cstr = sqlite3_column_text(stmt, 0) else {
            return nil
        }

        return String(cString: cstr)
    }

    private func parseZoom(from raw: String) -> Int32? {
        Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func selectSingleInt(db: OpaquePointer, sql: String) -> Int32? {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else {
            return nil
        }

        return Int32(sqlite3_column_int(stmt, 0))
    }


    private func detectSchemaLocked(db: OpaquePointer?) {
        guard let db else { return }
        self.tilesHasTileData = self.table(db: db, name: "tiles") && self.columnExists(db: db, table: "tiles", column: "tile_data")

        let hasTilesId = self.table(db: db, name: "tiles") && self.columnExists(db: db, table: "tiles", column: "tile_id")
        let hasImages = self.table(db: db, name: "images") && self.columnExists(db: db, table: "images", column: "tile_data")
        self.usesImagesSchema = (!self.tilesHasTileData) && hasTilesId && hasImages

        #if DEBUG
        print("🧩 MBTiles schema:",
              "tilesHasTileData=", self.tilesHasTileData,
              "usesImagesSchema=", self.usesImagesSchema)
        #endif
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
