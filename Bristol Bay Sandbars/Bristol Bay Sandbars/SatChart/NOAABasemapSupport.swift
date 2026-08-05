import Foundation
import MapKit
import SQLite3
import CoreLocation
import CryptoKit

enum BasemapChoice: String, CaseIterable, Identifiable {
    case districtsOffline
    case appleSatellite
    case bristolBaySatelliteOnline
    case bristolBaySatelliteOffline
    case topoOnline
    case noaaOffline
    case noaaOnline

    var id: String { rawValue }

    var label: String {
        switch self {
        case .districtsOffline: return "Districts Offline"
        case .appleSatellite: return "Satellite"
        case .bristolBaySatelliteOnline: return "B-Bay Sat. Online"
        case .bristolBaySatelliteOffline: return "B-Bay Sat Offline"
        case .topoOnline: return "USGS Topo"
        case .noaaOffline: return "NOAA Charts Offline"
        case .noaaOnline: return "NOAA Charts Online"
        }
    }

    var symbolName: String {
        switch self {
        case .districtsOffline:
            return "map.fill"
        case .appleSatellite:
            return "globe.americas.fill"
        case .bristolBaySatelliteOnline:
            return "photo.fill"
        case .bristolBaySatelliteOffline:
            return "photo.stack.fill"
        case .topoOnline:
            return "mountain.2.fill"
        case .noaaOffline:
            return "shippingbox.fill"
        case .noaaOnline:
            return "antenna.radiowaves.left.and.right"
        }
    }
}

enum BasemapDefaultPolicy {
    static func shouldPreferBristolBaySatelliteOnline(rawValue: String, didMigrate: Bool) -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return !didMigrate && (trimmed.isEmpty || trimmed == BasemapChoice.appleSatellite.rawValue)
    }

    static func choice(rawValue: String, didMigrate: Bool) -> BasemapChoice {
        if shouldPreferBristolBaySatelliteOnline(rawValue: rawValue, didMigrate: didMigrate) {
            return .bristolBaySatelliteOnline
        }
        return BasemapChoice(rawValue: rawValue) ?? .bristolBaySatelliteOnline
    }
}

enum BasemapLayerPolicy {
    static func usesBristolBaySatelliteOnlineBase(_ choice: BasemapChoice) -> Bool {
        choice == .bristolBaySatelliteOnline || choice == .districtsOffline
    }

    static func isShorelineOverlay(slug: String) -> Bool {
        OfflinePack.shorelinePacks.contains { $0.slug == slug }
    }

    static func isDistrictOrShorelineOverlay(slug: String) -> Bool {
        DistrictID.district(forDistrictMapSlug: slug) != nil || isShorelineOverlay(slug: slug)
    }

    static func tileAlpha(
        for slug: String,
        basemapChoice: BasemapChoice,
        selectedDistrictMapSlug: String?
    ) -> Double {
        guard basemapChoice == .districtsOffline else {
            return isDistrictOrShorelineOverlay(slug: slug) ? 0.0 : 1.0
        }

        if isShorelineOverlay(slug: slug) {
            return 1.0
        }

        guard DistrictID.district(forDistrictMapSlug: slug) != nil else {
            return 1.0
        }

        return selectedDistrictMapSlug == slug ? 1.0 : 0.0
    }
}

final class BristolBaySatelliteTileOverlay: MKTileOverlay {
    private static let baseURL = URL(string: "https://pub-832b588ef9ec4a588045736b6ce409b9.r2.dev")!
    private static let tilesPrefix = "tiles"
    private static let tileStore = BristolBaySatelliteTileStore.shared

    init(replacesMapContent: Bool = false) {
        super.init(urlTemplate: nil)
        canReplaceMapContent = replacesMapContent
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0
        maximumZ = 15
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        Self.baseURL
            .appendingPathComponent(Self.tilesPrefix)
            .appendingPathComponent(String(path.z))
            .appendingPathComponent(String(path.x))
            .appendingPathComponent("\(path.y).png")
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let url = url(forTilePath: path)
        let cacheKey = "z\(path.z)/x\(path.x)/y\(path.y)"
        Self.tileStore.loadTile(url: url, cacheKey: cacheKey, result: result)
    }
}

private final class BristolBaySatelliteTileStore {
    static let shared = BristolBaySatelliteTileStore()

    private let memoryCache = NSCache<NSString, NSData>()
    private let session: URLSession
    private let rootDirectory: URL
    private let lock = NSLock()
    private var inFlight: [String: [(Data?, Error?) -> Void]] = [:]

    private init() {
        memoryCache.totalCostLimit = 128 * 1024 * 1024
        memoryCache.countLimit = 1600

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)

        let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        rootDirectory = cachesRoot.appendingPathComponent("BristolBaySatelliteTiles/v1", isDirectory: true)

        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true, attributes: nil)
    }

    func loadTile(url: URL, cacheKey: String, result: @escaping (Data?, Error?) -> Void) {
        if let cached = loadFromCache(cacheKey: cacheKey) {
            result(cached, nil)
            return
        }

        lock.lock()
        if var callbacks = inFlight[cacheKey] {
            callbacks.append(result)
            inFlight[cacheKey] = callbacks
            lock.unlock()
            return
        } else {
            inFlight[cacheKey] = [result]
            lock.unlock()
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("image/png,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("SatChart-BristolBaySatellite/1.0", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else {
                result(nil, error)
                return
            }

            if let validated = self.validatedImageData(data, response: response) {
                self.storeInCache(validated, cacheKey: cacheKey)
                self.finish(cacheKey: cacheKey, data: validated, error: nil)
                return
            }

            self.finish(cacheKey: cacheKey, data: nil, error: error)
        }.resume()
    }

    private func loadFromCache(cacheKey: String) -> Data? {
        let nsKey = cacheKey as NSString
        if let cached = memoryCache.object(forKey: nsKey) {
            return cached as Data
        }

        let url = cacheFileURL(for: cacheKey)
        if let diskData = try? Data(contentsOf: url) {
            memoryCache.setObject(diskData as NSData, forKey: nsKey, cost: diskData.count)
            return diskData
        }

        return nil
    }

    private func storeInCache(_ data: Data, cacheKey: String) {
        memoryCache.setObject(data as NSData, forKey: cacheKey as NSString, cost: data.count)

        let url = cacheFileURL(for: cacheKey)
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try? data.write(to: url, options: .atomic)
        }
    }

    private func validatedImageData(_ data: Data?, response: URLResponse?) -> Data? {
        guard let data, !data.isEmpty else { return nil }

        if let http = response as? HTTPURLResponse {
            guard (200...299).contains(http.statusCode) else { return nil }

            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if contentType.contains("image/png") || contentType.contains("image/jpeg") {
                return data
            }
            if contentType.contains("xml") || contentType.contains("html") || contentType.contains("text") || contentType.contains("json") {
                return nil
            }
        }

        return Self.looksLikePNG(data) || Self.looksLikeJPEG(data) ? data : nil
    }

    private static func looksLikePNG(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        return Array(data.prefix(8)) == signature
    }

    private static func looksLikeJPEG(_ data: Data) -> Bool {
        guard data.count >= 3 else { return false }
        return data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF
    }

    private func finish(cacheKey: String, data: Data?, error: Error?) {
        let callbacks: [(Data?, Error?) -> Void]
        lock.lock()
        callbacks = inFlight.removeValue(forKey: cacheKey) ?? []
        lock.unlock()

        for callback in callbacks {
            callback(data, error)
        }
    }

    private func cacheFileURL(for cacheKey: String) -> URL {
        let digest = SHA256.hash(data: Data(cacheKey.utf8))
        let fileName = digest.map { String(format: "%02x", $0) }.joined() + ".tile"
        return rootDirectory.appendingPathComponent(fileName)
    }
}

final class NOAAOnlineTileOverlay: MKTileOverlay {
    private static let exportBaseURL = URL(string:
        "https://gis.charttools.noaa.gov/arcgis/rest/services/MCS/NOAAChartDisplay/MapServer/exts/MaritimeChartService/MapServer/export"
    )!

    private static let worldHalfWidth: Double = 20_037_508.342789244

    init(replacesMapContent: Bool = true) {
        super.init(urlTemplate: nil)
        canReplaceMapContent = replacesMapContent
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0
        maximumZ = 18
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let scale = max(1, Int(path.contentScaleFactor.rounded()))
        let pixelSize = 256 * scale
        let dpi = 96 * scale

        let bbox = Self.webMercatorBBox(for: path)

        var comps = URLComponents(url: Self.exportBaseURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "bbox", value: "\(bbox.minX),\(bbox.minY),\(bbox.maxX),\(bbox.maxY)"),
            URLQueryItem(name: "bboxSR", value: "102100"),
            URLQueryItem(name: "imageSR", value: "102100"),
            URLQueryItem(name: "size", value: "\(pixelSize),\(pixelSize)"),
            URLQueryItem(name: "dpi", value: "\(dpi)"),
            URLQueryItem(name: "transparent", value: "true"),
            URLQueryItem(name: "format", value: "png32"),
            URLQueryItem(name: "f", value: "image")
        ]
        return comps.url!
    }

    private static func webMercatorBBox(for path: MKTileOverlayPath) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let z = path.z
        let tilesPerSide = Double(1 << z)
        let worldWidth = worldHalfWidth * 2.0
        let tileWidth = worldWidth / tilesPerSide

        let minX = -worldHalfWidth + (Double(path.x) * tileWidth)
        let maxX = minX + tileWidth
        let maxY = worldHalfWidth - (Double(path.y) * tileWidth)
        let minY = maxY - tileWidth

        return (minX, minY, maxX, maxY)
    }
}


final class USGSTopoOnlineTileOverlay: MKTileOverlay {
    static let nativeMaximumZ: Int = 23

    private static let exportBaseURL = URL(string:
        "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/export"
    )!

    private static let worldHalfWidth: Double = 20_037_508.342789244

    init(replacesMapContent: Bool = true) {
        super.init(urlTemplate: nil)
        canReplaceMapContent = replacesMapContent
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0
        maximumZ = Self.nativeMaximumZ
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let scale = max(1, Int(path.contentScaleFactor.rounded()))
        let pixelSize = 256 * scale
        let dpi = 96 * scale

        let bbox = Self.webMercatorBBox(for: path)

        var comps = URLComponents(url: Self.exportBaseURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "bbox", value: "\(bbox.minX),\(bbox.minY),\(bbox.maxX),\(bbox.maxY)"),
            URLQueryItem(name: "bboxSR", value: "102100"),
            URLQueryItem(name: "imageSR", value: "102100"),
            URLQueryItem(name: "size", value: "\(pixelSize),\(pixelSize)"),
            URLQueryItem(name: "dpi", value: "\(dpi)"),
            URLQueryItem(name: "transparent", value: "false"),
            URLQueryItem(name: "format", value: "png32"),
            URLQueryItem(name: "f", value: "image")
        ]
        return comps.url!
    }

    private static func webMercatorBBox(for path: MKTileOverlayPath) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let z = path.z
        let tilesPerSide = Double(1 << z)
        let worldWidth = worldHalfWidth * 2.0
        let tileWidth = worldWidth / tilesPerSide

        let minX = -worldHalfWidth + (Double(path.x) * tileWidth)
        let maxX = minX + tileWidth
        let maxY = worldHalfWidth - (Double(path.y) * tileWidth)
        let minY = maxY - tileWidth

        return (minX, minY, maxX, maxY)
    }
}

/// One locally-downloaded offline basemap package discovered in Documents/MBTiles.
///
/// Naming conventions supported by the discovery code:
/// - noaa.mbtiles / ncds.mbtiles
/// - noaa_bristol_bay.mbtiles / ncds_bristol_bay.mbtiles
/// - noaa-bristol-bay.mbtiles / ncds-bristol-bay.mbtiles
/// - bristol_bay.mbtiles / bristol-bay.mbtiles
struct LocalNOAAChartPackage: Identifiable {
    let url: URL
    let slug: String
    let coverageMapRect: MKMapRect?
    let minZoom: Int?
    let maxZoom: Int?

    var id: String { slug }
}

extension OfflineMapsManager {

    /// Returns all locally-downloaded NOAA/NCDS offline chart packages currently stored in Documents/MBTiles.
    ///
    /// This intentionally excludes the offline Bristol Bay satellite basemap so the
    /// two offline basemap choices do not alias each other.
    func localNOAAChartPackages() -> [LocalNOAAChartPackage] {
        localOfflineBasemapPackages(
            matching: Self.looksLikeNOAASlug,
            priority: Self.noaaSlugPriority
        )
    }

    /// Returns all locally-downloaded offline Bristol Bay satellite packages.
    func localBristolBaySatellitePackages() -> [LocalNOAAChartPackage] {
        localOfflineBasemapPackages(
            matching: Self.looksLikeBristolBaySatelliteSlug,
            priority: Self.bristolBaySatelliteSlugPriority
        )
    }

    /// Picks the best local NOAA chart package for the map's current visible rect.
    func bestLocalNOAAChartPackage(for visibleMapRect: MKMapRect) -> LocalNOAAChartPackage? {
        bestLocalOfflineBasemapPackage(
            from: localNOAAChartPackages(),
            for: visibleMapRect
        )
    }

    /// Picks the best local Bristol Bay satellite package for the map's current visible rect.
    func bestLocalBristolBaySatellitePackage(for visibleMapRect: MKMapRect) -> LocalNOAAChartPackage? {
        bestLocalOfflineBasemapPackage(
            from: localBristolBaySatellitePackages(),
            for: visibleMapRect
        )
    }

    /// Convenience wrapper if you only want the URL.
    func bestLocalNOAAChartURL(for visibleMapRect: MKMapRect) -> URL? {
        bestLocalNOAAChartPackage(for: visibleMapRect)?.url
    }

    /// Convenience wrapper if you only want the URL.
    func bestLocalBristolBaySatelliteURL(for visibleMapRect: MKMapRect) -> URL? {
        bestLocalBristolBaySatellitePackage(for: visibleMapRect)?.url
    }

    private func localOfflineBasemapPackages(
        matching matchesSlug: @escaping (String) -> Bool,
        priority: @escaping (String) -> Int
    ) -> [LocalNOAAChartPackage] {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MBTiles", isDirectory: true)

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension.lowercased() == "mbtiles" }
            .filter { matchesSlug($0.deletingPathExtension().lastPathComponent) }
            .sorted {
                let lhsSlug = $0.deletingPathExtension().lastPathComponent
                let rhsSlug = $1.deletingPathExtension().lastPathComponent
                let lhsPriority = priority(lhsSlug)
                let rhsPriority = priority(rhsSlug)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                return $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
            }
            .map { url in
                NOAAMBTilesMetadataReader.readPackage(at: url)
                ?? LocalNOAAChartPackage(
                    url: url,
                    slug: url.deletingPathExtension().lastPathComponent,
                    coverageMapRect: nil,
                    minZoom: nil,
                    maxZoom: nil
                )
            }
    }

    private func bestLocalOfflineBasemapPackage(
        from packages: [LocalNOAAChartPackage],
        for visibleMapRect: MKMapRect
    ) -> LocalNOAAChartPackage? {
        guard !packages.isEmpty else { return nil }
        guard packages.count > 1 else { return packages[0] }

        let visible = Self.normalizedVisibleRect(visibleMapRect)

        var bestIntersecting: (package: LocalNOAAChartPackage, score: Double)?
        for package in packages {
            guard let coverage = package.coverageMapRect else { continue }
            let score = Self.intersectionArea(coverage, visible)
            guard score > 0 else { continue }

            if let best = bestIntersecting {
                if score > best.score {
                    bestIntersecting = (package, score)
                }
            } else {
                bestIntersecting = (package, score)
            }
        }

        if let bestIntersecting {
            return bestIntersecting.package
        }

        let visibleCenter = Self.centerCoordinate(of: visible)
        var nearestPackage: (package: LocalNOAAChartPackage, distanceMeters: CLLocationDistance)?

        for package in packages {
            guard let coverage = package.coverageMapRect else { continue }
            let packageCenter = Self.centerCoordinate(of: coverage)
            let a = CLLocation(latitude: visibleCenter.latitude, longitude: visibleCenter.longitude)
            let b = CLLocation(latitude: packageCenter.latitude, longitude: packageCenter.longitude)
            let distance = a.distance(from: b)

            if let nearest = nearestPackage {
                if distance < nearest.distanceMeters {
                    nearestPackage = (package, distance)
                }
            } else {
                nearestPackage = (package, distance)
            }
        }

        return nearestPackage?.package ?? packages[0]
    }

    private static func looksLikeNOAASlug(_ slug: String) -> Bool {
        let s = slug.lowercased()
        return s == "noaa"
            || s == "ncds"
            || s.hasPrefix("noaa_")
            || s.hasPrefix("noaa-")
            || s.hasPrefix("ncds_")
            || s.hasPrefix("ncds-")
    }

    private static func looksLikeBristolBaySatelliteSlug(_ slug: String) -> Bool {
        let s = slug.lowercased()
        return s == "bristol_bay" || s == "bristol-bay"
    }

    private static func noaaSlugPriority(_ slug: String) -> Int {
        let s = slug.lowercased()
        if s.hasPrefix("ncds") {
            return 0
        }
        if s.hasPrefix("noaa") {
            return 1
        }
        return 2
    }

    private static func bristolBaySatelliteSlugPriority(_ slug: String) -> Int {
        let s = slug.lowercased()
        if s == "bristol_bay" {
            return 0
        }
        if s == "bristol-bay" {
            return 1
        }
        return 2
    }

    private static func normalizedVisibleRect(_ rect: MKMapRect) -> MKMapRect {
        if rect.isNull || rect.size.width <= 0 || rect.size.height <= 0 {
            return MKMapRect(origin: MKMapPoint(x: 0, y: 0), size: MKMapSize.world)
        }
        return rect
    }

    private static func centerCoordinate(of rect: MKMapRect) -> CLLocationCoordinate2D {
        let center = MKMapPoint(
            x: rect.origin.x + rect.size.width / 2.0,
            y: rect.origin.y + rect.size.height / 2.0
        )
        return center.coordinate
    }

    private static func intersectionArea(_ a: MKMapRect, _ b: MKMapRect) -> Double {
        let aMinX = a.origin.x
        let aMaxX = a.origin.x + a.size.width
        let aMinY = a.origin.y
        let aMaxY = a.origin.y + a.size.height

        let bMinX = b.origin.x
        let bMaxX = b.origin.x + b.size.width
        let bMinY = b.origin.y
        let bMaxY = b.origin.y + b.size.height

        let width = min(aMaxX, bMaxX) - max(aMinX, bMinX)
        let height = min(aMaxY, bMaxY) - max(aMinY, bMinY)

        guard width > 0, height > 0 else { return 0 }
        return width * height
    }

}

private enum NOAAMBTilesMetadataReader {

    nonisolated static func readPackage(at url: URL) -> LocalNOAAChartPackage? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX

        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            if let db {
                sqlite3_close(db)
            }
            return nil
        }
        defer { sqlite3_close(db) }

        let slug = url.deletingPathExtension().lastPathComponent
        let boundsRect = metadataString(db: db, name: "bounds").flatMap(coverageRect(from:))
        let minZoom = metadataString(db: db, name: "minzoom").flatMap(parseZoom(from:))
        let maxZoom = metadataString(db: db, name: "maxzoom").flatMap(parseZoom(from:))

        return LocalNOAAChartPackage(
            url: url,
            slug: slug,
            coverageMapRect: boundsRect,
            minZoom: minZoom,
            maxZoom: maxZoom
        )
    }

    nonisolated private static func metadataString(db: OpaquePointer, name: String) -> String? {
        let sql = "SELECT value FROM metadata WHERE name=? LIMIT 1;"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, name, -1, sqliteTransient)

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cstr = sqlite3_column_text(stmt, 0) else {
            return nil
        }

        return String(cString: cstr)
    }

    nonisolated private static func parseZoom(from string: String) -> Int? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let intValue = Int(trimmed) {
            return intValue
        }
        if let doubleValue = Double(trimmed) {
            return Int(doubleValue.rounded(.towardZero))
        }
        return nil
    }

    /// MBTiles bounds metadata is: minLon,minLat,maxLon,maxLat
    nonisolated private static func coverageRect(from boundsString: String) -> MKMapRect? {
        let parts = boundsString
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        guard parts.count == 4,
              let minLon = Double(parts[0]),
              let minLat = Double(parts[1]),
              let maxLon = Double(parts[2]),
              let maxLat = Double(parts[3]),
              minLon < maxLon,
              minLat < maxLat else {
            return nil
        }

        let southWest = CLLocationCoordinate2D(latitude: minLat, longitude: minLon)
        let northEast = CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon)

        guard CLLocationCoordinate2DIsValid(southWest), CLLocationCoordinate2DIsValid(northEast) else {
            return nil
        }

        let a = MKMapPoint(southWest)
        let b = MKMapPoint(northEast)
        let origin = MKMapPoint(x: min(a.x, b.x), y: min(a.y, b.y))
        let size = MKMapSize(width: abs(a.x - b.x), height: abs(a.y - b.y))

        guard size.width > 0, size.height > 0 else { return nil }
        return MKMapRect(origin: origin, size: size)
    }
}
