import Foundation
import MapKit
import SQLite3
import CoreGraphics
import CoreImage
import ImageIO
import UIKit

// Needed for sqlite3_bind_text in Swift (equivalent to C's SQLITE_TRANSIENT)
nonisolated(unsafe) private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated struct DistrictMapVisualSettings: Codable, Equatable, Hashable, Sendable {
    nonisolated static let brightnessRange = -0.25...0.25
    nonisolated static let contrastRange = 0.50...1.75
    nonisolated static let gammaRange = 0.50...1.50
    nonisolated static let saturationRange = 0.00...1.50

    nonisolated static let neutral = DistrictMapVisualSettings(
        brightness: 0.00,
        contrast: 1.00,
        gamma: 1.00,
        saturation: 1.00
    )

    var brightness: Double
    var contrast: Double
    var gamma: Double
    var saturation: Double

    nonisolated init(
        brightness: Double,
        contrast: Double,
        gamma: Double,
        saturation: Double
    ) {
        self.brightness = Self.clamped(brightness, to: Self.brightnessRange, fallback: 0.00)
        self.contrast = Self.clamped(contrast, to: Self.contrastRange, fallback: 1.00)
        self.gamma = Self.clamped(gamma, to: Self.gammaRange, fallback: 1.00)
        self.saturation = Self.clamped(saturation, to: Self.saturationRange, fallback: 1.00)
    }

    nonisolated var normalized: DistrictMapVisualSettings {
        DistrictMapVisualSettings(
            brightness: brightness,
            contrast: contrast,
            gamma: gamma,
            saturation: saturation
        )
    }

    nonisolated var isNeutral: Bool {
        let value = normalized
        return abs(value.brightness) < 0.0001
            && abs(value.contrast - 1.0) < 0.0001
            && abs(value.gamma - 1.0) < 0.0001
            && abs(value.saturation - 1.0) < 0.0001
    }

    nonisolated private static func clamped(
        _ value: Double,
        to range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

enum DistrictMapImageAdjuster {
    nonisolated private static let context = CIContext(
        options: [.cacheIntermediates: false]
    )

    nonisolated static func adjustedImage(
        _ sourceImage: UIImage,
        settings: DistrictMapVisualSettings
    ) -> UIImage {
        let normalizedSettings = settings.normalized
        guard !normalizedSettings.isNeutral,
              let inputImage = CIImage(image: sourceImage, options: [.applyOrientationProperty: true]),
              let renderedImage = renderedCGImage(from: inputImage, settings: normalizedSettings) else {
            return sourceImage
        }

        return UIImage(cgImage: renderedImage, scale: sourceImage.scale, orientation: .up)
    }

    nonisolated static func renderedCGImage(
        from inputImage: CIImage,
        settings: DistrictMapVisualSettings
    ) -> CGImage? {
        let normalizedSettings = settings.normalized
        guard let colorControls = CIFilter(name: "CIColorControls") else { return nil }

        colorControls.setValue(inputImage, forKey: kCIInputImageKey)
        colorControls.setValue(normalizedSettings.brightness, forKey: kCIInputBrightnessKey)
        colorControls.setValue(normalizedSettings.contrast, forKey: kCIInputContrastKey)
        colorControls.setValue(normalizedSettings.saturation, forKey: kCIInputSaturationKey)

        guard let colorAdjustedImage = colorControls.outputImage,
              let gammaAdjust = CIFilter(name: "CIGammaAdjust") else {
            return nil
        }

        gammaAdjust.setValue(colorAdjustedImage, forKey: kCIInputImageKey)
        gammaAdjust.setValue(normalizedSettings.gamma, forKey: "inputPower")

        guard let outputImage = gammaAdjust.outputImage else { return nil }
        let extent = outputImage.extent.integral
        guard extent.width.isFinite,
              extent.height.isFinite,
              extent.width > 0,
              extent.height > 0 else {
            return nil
        }

        return context.createCGImage(outputImage, from: extent)
    }
}

/// MKTileOverlay that serves raster PNG/JPG tiles from an MBTiles (SQLite) file.
nonisolated final class MBTilesOverlay: MKTileOverlay {

    private struct TileCoordinateBounds {
        let minX: Int32
        let maxX: Int32
        let minY: Int32
        let maxY: Int32

        func contains(x: Int32, yXYZ: Int32) -> Bool {
            x >= minX && x <= maxX && yXYZ >= minY && yXYZ <= maxY
        }
    }

    let slug: String
    let identity: MBTilesOverlayIdentity
    let packageSession: MBTilesPackageSession
    /// The retained renderer is the sole painter when a district/backing overlay
    /// is attached. Keep this tile overlay as the package/lifecycle anchor only.
    var rendersThroughBackstop = false
    let nativeDetailMaximumZ: Int?
    private let coverageMapRect: MKMapRect

    override var boundingMapRect: MKMapRect { coverageMapRect }
    override var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: coverageMapRect.midX, y: coverageMapRect.midY).coordinate
    }

    private let readinessLock = NSLock()
    private var hasServedTile = false
    private var readinessHandlers: [() -> Void] = []

    private let mbtilesURL: URL
    private var db: OpaquePointer?

    private let queue = DispatchQueue(label: "MBTilesOverlay.sqlite.queue")
    private let visualSettingsLock = NSLock()
    private var storedVisualSettings: DistrictMapVisualSettings

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
    private var coverageTileBoundsByZoom: [Int32: TileCoordinateBounds] = [:]

    init(
        mbtilesURL: URL,
        slug: String,
        packageIdentifier: String? = nil,
        packageVersion: String? = nil,
        role: MBTilesLayerRole? = nil,
        storageSchemeOverride: MBTilesStorageScheme? = nil,
        minimumZoom: Int = 0,
        maximumZoom: Int = 15,
        tileSizePixels: Int = 256,
        maximumFallbackDepth: Int = 6,
        canReplaceMapContent: Bool = false,
        visualSettings: DistrictMapVisualSettings = .neutral,
        nativeDetailMaximumZ: Int? = nil,
        coverageMapRect: MKMapRect? = nil,
        immutableFile: Bool = false
    ) {
        self.mbtilesURL = mbtilesURL
        self.slug = slug
        self.storedVisualSettings = visualSettings.normalized
        self.nativeDetailMaximumZ = nativeDetailMaximumZ.map { max(0, $0) }
        self.coverageMapRect = coverageMapRect.flatMap { rect in
            guard !rect.isNull, !rect.isEmpty,
                  rect.origin.x.isFinite, rect.origin.y.isFinite,
                  rect.size.width.isFinite, rect.size.height.isFinite else { return nil }
            let clipped = rect.intersection(.world)
            return clipped.isNull || clipped.isEmpty ? nil : clipped
        } ?? .world
        let resolvedStorageScheme = storageSchemeOverride
            ?? MBTilesStorageScheme.explicitLegacyOverride(forPackageSlug: slug)
        self.identity = MBTilesOverlayIdentity(
            role: role ?? .inferred(from: slug),
            packageIdentifier: packageIdentifier ?? slug,
            packageVersion: packageVersion ?? slug,
            fileURL: mbtilesURL,
            storageSchemeOverride: resolvedStorageScheme,
            tileSizePixels: tileSizePixels,
            minimumZoom: minimumZoom,
            maximumZoom: maximumZoom,
            nativeDetailMaximumZoom: nativeDetailMaximumZ,
            maximumFallbackDepth: maximumFallbackDepth,
            visualSettings: visualSettings,
            canReplaceMapContent: canReplaceMapContent
        )
        self.packageSession = MBTilesPackageSessionRegistry.shared.session(
            for: identity,
            immutableFile: immutableFile
        )
        super.init(urlTemplate: nil)

        self.canReplaceMapContent = canReplaceMapContent
        self.tileSize = CGSize(width: tileSizePixels, height: tileSizePixels)
        self.minimumZ = minimumZoom
        self.maximumZ = maximumZoom
    }

    convenience init(mbtilesURL: URL, canReplaceMapContent: Bool = false) {
        let base = mbtilesURL.deletingPathExtension().lastPathComponent
        self.init(mbtilesURL: mbtilesURL, slug: base, canReplaceMapContent: canReplaceMapContent)
    }

    @discardableResult
    func updateVisualSettings(_ settings: DistrictMapVisualSettings) -> Bool {
        let normalizedSettings = settings.normalized
        visualSettingsLock.lock()
        guard normalizedSettings != storedVisualSettings else {
            visualSettingsLock.unlock()
            return false
        }
        storedVisualSettings = normalizedSettings
        visualSettingsLock.unlock()
        return true
    }

    nonisolated static func localPreviewImage(from mbtilesURL: URL) -> UIImage? {
        struct ZoomSummary {
            let zoom: Int32
            let tileCount: Int
            let minX: Int64
            let maxX: Int64
            let minY: Int64
            let maxY: Int64

            var columnCount: Int { Int(maxX - minX + 1) }
            var rowCount: Int { Int(maxY - minY + 1) }
            var gridArea: Int { columnCount * rowCount }
        }

        guard let fileLease = MBTilesPackageSessionRegistry.shared
            .acquirePackageFileReadLease(at: mbtilesURL) else { return nil }
        defer { fileLease.release() }
        guard !fileLease.isCancelled, !Task.isCancelled else { return nil }

        var previewDB: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(fileLease.fileURL.path, &previewDB, flags, nil) == SQLITE_OK,
              let previewDB else {
            if let previewDB { sqlite3_close(previewDB) }
            return nil
        }
        defer { sqlite3_close(previewDB) }

        func columnExists(table: String, column: String) -> Bool {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                previewDB,
                "PRAGMA table_info(\(table));",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else {
                return false
            }
            defer { sqlite3_finalize(statement) }

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let name = sqlite3_column_text(statement, 1) else { continue }
                if String(cString: name).caseInsensitiveCompare(column) == .orderedSame {
                    return true
                }
            }
            return false
        }

        let directTileData = columnExists(table: "tiles", column: "tile_data")
        let joinedImageData = !directTileData
            && columnExists(table: "tiles", column: "tile_id")
            && columnExists(table: "images", column: "tile_data")
        guard directTileData || joinedImageData else { return nil }

        guard !fileLease.isCancelled, !Task.isCancelled else { return nil }
        let pathComponents = fileLease.fileURL.standardizedFileURL.pathComponents
        let packageSlug: String = {
            if let versionsIndex = pathComponents.lastIndex(of: "versions"), versionsIndex > 0 {
                return pathComponents[versionsIndex - 1]
            }
            return fileLease.fileURL.deletingPathExtension().lastPathComponent
        }()
        var schemeStatement: OpaquePointer?
        var previewUsesTMS = MBTilesStorageScheme.explicitLegacyOverride(
            forPackageSlug: packageSlug
        ) != .xyz
        if sqlite3_prepare_v2(
            previewDB,
            "SELECT value FROM metadata WHERE name='scheme' LIMIT 1;",
            -1,
            &schemeStatement,
            nil
        ) == SQLITE_OK {
            if sqlite3_step(schemeStatement) == SQLITE_ROW,
               let value = sqlite3_column_text(schemeStatement, 0) {
                previewUsesTMS = String(cString: value).lowercased() != "xyz"
            }
        }
        sqlite3_finalize(schemeStatement)

        var summaryStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            previewDB,
            """
            SELECT zoom_level, COUNT(*),
                   MIN(tile_column), MAX(tile_column),
                   MIN(tile_row), MAX(tile_row)
            FROM tiles
            GROUP BY zoom_level
            ORDER BY zoom_level ASC;
            """,
            -1,
            &summaryStatement,
            nil
        ) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(summaryStatement) }

        var summaries: [ZoomSummary] = []
        while sqlite3_step(summaryStatement) == SQLITE_ROW {
            guard !fileLease.isCancelled, !Task.isCancelled else { return nil }
            guard sqlite3_column_type(summaryStatement, 0) != SQLITE_NULL,
                  sqlite3_column_type(summaryStatement, 1) != SQLITE_NULL,
                  sqlite3_column_type(summaryStatement, 2) != SQLITE_NULL,
                  sqlite3_column_type(summaryStatement, 3) != SQLITE_NULL,
                  sqlite3_column_type(summaryStatement, 4) != SQLITE_NULL,
                  sqlite3_column_type(summaryStatement, 5) != SQLITE_NULL else {
                continue
            }

            summaries.append(
                ZoomSummary(
                    zoom: sqlite3_column_int(summaryStatement, 0),
                    tileCount: Int(sqlite3_column_int64(summaryStatement, 1)),
                    minX: sqlite3_column_int64(summaryStatement, 2),
                    maxX: sqlite3_column_int64(summaryStatement, 3),
                    minY: sqlite3_column_int64(summaryStatement, 4),
                    maxY: sqlite3_column_int64(summaryStatement, 5)
                )
            )
        }
        guard !summaries.isEmpty else { return nil }

        let maximumPreviewTiles = 100
        let absoluteTileDecodeLimit = 400
        let selectedSummary = summaries.last {
            $0.tileCount <= maximumPreviewTiles
                && $0.gridArea <= maximumPreviewTiles
                && $0.columnCount <= 12
                && $0.rowCount <= 12
        } ?? summaries.min {
            if $0.gridArea != $1.gridArea { return $0.gridArea < $1.gridArea }
            return $0.zoom < $1.zoom
        }!
        guard selectedSummary.tileCount <= absoluteTileDecodeLimit else { return nil }

        let tileSQL: String = directTileData
            ? """
              SELECT tile_column, tile_row, tile_data
              FROM tiles
              WHERE zoom_level=?;
              """
            : """
              SELECT tiles.tile_column, tiles.tile_row, images.tile_data
              FROM tiles
              JOIN images ON tiles.tile_id = images.tile_id
              WHERE tiles.zoom_level=?;
              """

        var tileStatement: OpaquePointer?
        guard sqlite3_prepare_v2(previewDB, tileSQL, -1, &tileStatement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(tileStatement) }
        sqlite3_bind_int(tileStatement, 1, selectedSummary.zoom)

        var tiles: [(column: Int64, row: Int64, image: UIImage)] = []
        tiles.reserveCapacity(min(selectedSummary.tileCount, absoluteTileDecodeLimit))

        while sqlite3_step(tileStatement) == SQLITE_ROW {
            guard !fileLease.isCancelled, !Task.isCancelled else { return nil }
            guard let bytes = sqlite3_column_blob(tileStatement, 2) else { continue }
            let length = Int(sqlite3_column_bytes(tileStatement, 2))
            guard length > 0 else { continue }

            let data = Data(bytes: bytes, count: length)
            guard let image = UIImage(data: data) else { continue }
            tiles.append(
                (
                    column: sqlite3_column_int64(tileStatement, 0),
                    row: sqlite3_column_int64(tileStatement, 1),
                    image: image
                )
            )
        }
        guard !tiles.isEmpty else { return nil }

        // Composite directly into the bounded preview surface. A native-size mosaic
        // can be hundreds of megapixels for sparse/high-minzoom packages and was a
        // major older-iPad failure mode. Shared, rounded cell edges keep adjacent
        // tiles contiguous without allocating that intermediate image.
        let nativeTileSide: CGFloat = 256
        let nativeCanvasSize = CGSize(
            width: CGFloat(selectedSummary.columnCount) * nativeTileSide,
            height: CGFloat(selectedSummary.rowCount) * nativeTileSide
        )
        guard nativeCanvasSize.width > 0, nativeCanvasSize.height > 0 else { return nil }

        let maximumDimension: CGFloat = 900
        let largestNativeDimension = max(nativeCanvasSize.width, nativeCanvasSize.height)
        let previewScale = min(1, maximumDimension / largestNativeDimension)
        let previewSize = CGSize(
            width: max(1, floor(nativeCanvasSize.width * previewScale)),
            height: max(1, floor(nativeCanvasSize.height * previewScale))
        )
        let previewFormat = UIGraphicsImageRendererFormat.default()
        previewFormat.scale = 1
        previewFormat.opaque = false

        guard !fileLease.isCancelled, !Task.isCancelled else { return nil }
        let columnWidth = previewSize.width / CGFloat(selectedSummary.columnCount)
        let rowHeight = previewSize.height / CGFloat(selectedSummary.rowCount)
        let renderedPreview = UIGraphicsImageRenderer(size: previewSize, format: previewFormat).image { context in
            context.cgContext.interpolationQuality = previewScale < 1 ? .high : .none
            context.cgContext.setAllowsAntialiasing(false)
            context.cgContext.setShouldAntialias(false)
            for tile in tiles {
                guard !fileLease.isCancelled, !Task.isCancelled else { return }
                let columnIndex = CGFloat(tile.column - selectedSummary.minX)
                let rowIndex = CGFloat(
                    previewUsesTMS
                        ? selectedSummary.maxY - tile.row
                        : tile.row - selectedSummary.minY
                )
                let minX = floor(columnIndex * columnWidth)
                let maxX = ceil((columnIndex + 1) * columnWidth)
                let minY = floor(rowIndex * rowHeight)
                let maxY = ceil((rowIndex + 1) * rowHeight)
                tile.image.draw(
                    in: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                    blendMode: .copy,
                    alpha: 1
                )
            }
        }
        guard !fileLease.isCancelled, !Task.isCancelled else { return nil }
        return renderedPreview
    }

    deinit {
        MBTilesPackageSessionRegistry.shared.retire(identity: identity)
        // Every queued tile request retains this overlay until its work finishes,
        // so deinit only runs after the final request releases it. Closing directly
        // avoids dispatch_sync deadlocking when that final release occurs on queue.
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }

    // MARK: - MKTileOverlay

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        packageSession.scheduleLoad(path: path) { [weak self] data, error in
            if data != nil { self?.signalReady() }
            result(data, error)
        }
    }

    func updateViewport(
        zoomLevel: Double,
        centerCoordinate: CLLocationCoordinate2D,
        commitGeneration: Bool = true
    ) {
        packageSession.updateViewport(
            zoomLevel: zoomLevel,
            centerCoordinate: centerCoordinate,
            commitGeneration: commitGeneration
        )
    }

    var hasServedRealTile: Bool {
        readinessLock.lock(); defer { readinessLock.unlock() }
        return hasServedTile
    }

    /// Prewarms the visible viewport plus a one-tile border at the current and
    /// approaching zoom levels. Only proven district packages are allowed to call
    /// this so the shared queue is not filled by offscreen district misses.
    func prefetch(in visibleMapRect: MKMapRect, zoomLevels: [Int]) {
        guard hasServedRealTile else { return }
        let clippedRect = visibleMapRect.intersection(coverageMapRect)
        guard !clippedRect.isNull, !clippedRect.isEmpty else { return }
        var coordinates: Set<MBTilesTileCoordinate> = []
        for zoom in zoomLevels where (minimumZ...maximumZ).contains(zoom) {
            let planned = MBTilesViewportTilePlanner.coordinates(
                in: clippedRect,
                zoom: zoom,
                ring: 1,
                maximumCount: 64
            ).filter {
                MBTilesViewportTilePlanner.mapRect(for: $0).intersects(coverageMapRect)
            }
            coordinates.formUnion(planned)
        }
        packageSession.schedulePrefetch(coordinates: Array(coordinates))
    }

    /// A replacement overlay is considered ready only after it has produced real
    /// tile bytes for MapKit, so its last known-good predecessor can remain below it.
    func whenFirstTileIsReady(_ handler: @escaping () -> Void) {
        readinessLock.lock()
        if hasServedTile {
            readinessLock.unlock()
            handler()
        } else {
            readinessHandlers.append(handler)
            readinessLock.unlock()
        }
    }

    private func signalReady() {
        readinessLock.lock()
        guard !hasServedTile else { readinessLock.unlock(); return }
        hasServedTile = true
        let handlers = readinessHandlers
        readinessHandlers.removeAll()
        readinessLock.unlock()
        handlers.forEach { $0() }
    }

    #if DEBUG
    nonisolated static func diagnosticSnapshot() -> MBTilesDiagnosticSnapshot {
        MBTilesDiagnostics.shared.snapshot()
    }
    #endif

    // MARK: - Tile fetch helpers

    enum RasterTileFormat {
        case png
        case jpeg
    }

    private var visualSettings: DistrictMapVisualSettings {
        visualSettingsLock.lock()
        defer { visualSettingsLock.unlock() }
        return storedVisualSettings
    }

    private var effectiveSourceMaximumZoom: Int32? {
        guard let sourceMaxZoom else { return nil }
        guard let nativeDetailMaximumZ else { return sourceMaxZoom }
        return min(sourceMaxZoom, Int32(nativeDetailMaximumZ))
    }

    private func applyingVisualSettings(to sourceData: Data) -> Data {
        let settings = visualSettings
        guard !settings.isNeutral,
              let format = Self.rasterTileFormat(for: sourceData),
              let inputImage = CIImage(data: sourceData, options: [.applyOrientationProperty: true]),
              let renderedImage = DistrictMapImageAdjuster.renderedCGImage(
                from: inputImage,
                settings: settings
              ),
              let encodedData = Self.encodeTileData(renderedImage, as: format) else {
            return sourceData
        }

        return encodedData
    }

    private func fetchRequestedTileData(db: OpaquePointer, z: Int32, x: Int32, yXYZ: Int32) -> Data? {
        let tmsY: Int32 = {
            let maxY = (Int32(1) << z) - 1
            return maxY - yXYZ
        }()

        let storedY: Int32 = isTMS ? tmsY : yXYZ
        if let data = fetchTileData(db: db, z: z, x: x, y: storedY),
           Self.isValidRasterTile(data) {
            return data
        }

        return nil
    }

    private func fetchOverzoomedTileData(
        db: OpaquePointer,
        requestedZ: Int32,
        requestedX: Int32,
        requestedYXYZ: Int32,
        sourceZoom: Int32
    ) -> Data? {
        let delta = Int(requestedZ - sourceZoom)
        guard delta > 0, delta <= 8 else { return nil }

        let childScale = 1 << delta
        let ancestorX = Int32(Int(requestedX) >> delta)
        let ancestorYXYZ = Int32(Int(requestedYXYZ) >> delta)
        let childX = Int(requestedX) & (childScale - 1)
        let childY = Int(requestedYXYZ) & (childScale - 1)

        guard let sourceData = fetchRequestedTileData(
            db: db,
            z: sourceZoom,
            x: ancestorX,
            yXYZ: ancestorYXYZ
        ), let format = Self.rasterTileFormat(for: sourceData) else {
            return nil
        }

        return Self.overzoomedTileData(
            from: sourceData,
            childX: childX,
            childY: childY,
            childScale: childScale,
            format: format
        )
    }

    private func isWithinCoverage(z: Int32, x: Int32, yXYZ: Int32) -> Bool {
        guard z >= 0, z < 31 else { return false }
        let tilesPerSide = Int64(1) << Int64(z)
        guard x >= 0, yXYZ >= 0,
              Int64(x) < tilesPerSide,
              Int64(yXYZ) < tilesPerSide else {
            return false
        }

        if let bounds = coverageTileBoundsByZoom[z] {
            return bounds.contains(x: x, yXYZ: yXYZ)
        }

        guard let sourceZoom = effectiveSourceMaximumZoom,
              z > sourceZoom,
              let sourceBounds = coverageTileBoundsByZoom[sourceZoom] else {
            return true
        }

        let delta = Int(z - sourceZoom)
        guard delta > 0, delta <= 8 else { return false }
        let scale = Int64(1 << delta)
        let minX = Int64(sourceBounds.minX) * scale
        let maxX = (Int64(sourceBounds.maxX) + 1) * scale - 1
        let minY = Int64(sourceBounds.minY) * scale
        let maxY = (Int64(sourceBounds.maxY) + 1) * scale - 1
        return Int64(x) >= minX && Int64(x) <= maxX
            && Int64(yXYZ) >= minY && Int64(yXYZ) <= maxY
    }

    nonisolated static func overzoomedTileData(
        from sourceData: Data,
        childX: Int,
        childY: Int,
        childScale: Int,
        format: RasterTileFormat
    ) -> Data? {
        guard childScale > 1,
              childX >= 0, childX < childScale,
              childY >= 0, childY < childScale else {
            return childScale == 1 && childX == 0 && childY == 0
                ? sourceData
                : nil
        }

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

        let cropWidth = sourceWidth / childScale
        let cropHeight = sourceHeight / childScale
        let cropRect = CGRect(
            x: childX * cropWidth,
            y: childY * cropHeight,
            width: cropWidth,
            height: cropHeight
        )
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

        // The extra display zoom levels intentionally retain the native source
        // detail. Nearest-neighbor expansion makes every source pixel cover an
        // exact child-pixel block and prevents independent child tiles from
        // sampling across (or clamping against) their crop boundaries.
        context.interpolationQuality = .none
        context.draw(
            croppedImage,
            in: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        )

        guard let renderedImage = context.makeImage() else {
            return nil
        }

        return encodeTileData(renderedImage, as: format)
    }

    nonisolated static func encodeTileData(_ image: CGImage, as format: RasterTileFormat) -> Data? {
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

    nonisolated private static func isValidRasterTile(_ data: Data) -> Bool {
        rasterTileFormat(for: data) != nil
    }

    nonisolated static func rasterTileFormat(for data: Data) -> RasterTileFormat? {
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
            sqlite3_exec(db, "PRAGMA cache_size = -8000;", nil, nil, nil)
            self.detectSchemaLocked(db: self.db)
            self.readMetadataLocked(db: self.db)
        }
    }

    private func readMetadataLocked(db: OpaquePointer?) {
        guard let db else { return }

        let queriedMinZoom = selectSingleInt(db: db, sql: "SELECT MIN(zoom_level) FROM tiles;")
        let queriedMaxZoom = selectSingleInt(db: db, sql: "SELECT MAX(zoom_level) FROM tiles;")
        let metadataMinZoom = metadataString(db: db, name: "minzoom").flatMap(parseZoom(from:))
        let metadataMaxZoom = metadataString(db: db, name: "maxzoom").flatMap(parseZoom(from:))

        sourceMinZoom = queriedMinZoom ?? metadataMinZoom
        sourceMaxZoom = queriedMaxZoom ?? metadataMaxZoom

        if let scheme = metadataString(db: db, name: "scheme")?.lowercased() {
            isTMS = (scheme != "xyz")
            #if DEBUG
            print("🧭 MBTiles scheme:", scheme, "=> flipY(TMS)?", isTMS)
            #endif
        } else if let inferredIsTMS = inferredTileRowSchemeLocked(db: db) {
            isTMS = inferredIsTMS
            #if DEBUG
            print("🧭 MBTiles scheme: (missing) => inferred flipY(TMS)?", isTMS)
            #endif
        } else {
            isTMS = true
            #if DEBUG
            print("🧭 MBTiles scheme: (missing) => assuming TMS (flipY true)")
            #endif
        }

        coverageTileBoundsByZoom = readTileCoordinateBoundsLocked(db: db)

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

    /// All SatChart offline packs cover Bristol Bay, north of the equator. When
    /// an older pack omits `scheme`, the stored row half at its highest zoom
    /// distinguishes northern-hemisphere TMS rows from their XYZ mirrors.
    private func inferredTileRowSchemeLocked(db: OpaquePointer) -> Bool? {
        guard let zoom = sourceMaxZoom, zoom > 0, zoom < 31 else { return nil }

        let sql = "SELECT MIN(tile_row), MAX(tile_row) FROM tiles WHERE zoom_level=?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, zoom)
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL,
              sqlite3_column_type(statement, 1) != SQLITE_NULL else {
            return nil
        }

        return Self.inferredIsTMSForNorthernHemisphere(
            zoom: zoom,
            minimumStoredY: sqlite3_column_int(statement, 0),
            maximumStoredY: sqlite3_column_int(statement, 1)
        )
    }

    nonisolated static func inferredIsTMSForNorthernHemisphere(
        zoom: Int32,
        minimumStoredY: Int32,
        maximumStoredY: Int32
    ) -> Bool? {
        guard zoom > 0, zoom < 31,
              minimumStoredY >= 0,
              maximumStoredY >= minimumStoredY else {
            return nil
        }

        let tileCount = Int64(1) << Int64(zoom)
        guard Int64(maximumStoredY) < tileCount else { return nil }

        let doubledMidpoint = Int64(minimumStoredY) + Int64(maximumStoredY)
        guard doubledMidpoint != tileCount - 1 else { return nil }
        return doubledMidpoint > tileCount - 1
    }

    private func readTileCoordinateBoundsLocked(
        db: OpaquePointer
    ) -> [Int32: TileCoordinateBounds] {
        let sql = """
        SELECT zoom_level,
               MIN(tile_column), MAX(tile_column),
               MIN(tile_row), MAX(tile_row)
        FROM tiles
        GROUP BY zoom_level;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        var result: [Int32: TileCoordinateBounds] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let zoom = sqlite3_column_int(statement, 0)
            guard zoom >= 0, zoom < 31 else { continue }

            let minX = sqlite3_column_int(statement, 1)
            let maxX = sqlite3_column_int(statement, 2)
            let storedMinY = sqlite3_column_int(statement, 3)
            let storedMaxY = sqlite3_column_int(statement, 4)
            let largestIndex = (Int32(1) << zoom) - 1
            let minYXYZ = isTMS ? largestIndex - storedMaxY : storedMinY
            let maxYXYZ = isTMS ? largestIndex - storedMinY : storedMaxY

            result[zoom] = TileCoordinateBounds(
                minX: minX,
                maxX: maxX,
                minY: minYXYZ,
                maxY: maxYXYZ
            )
        }
        return result
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
