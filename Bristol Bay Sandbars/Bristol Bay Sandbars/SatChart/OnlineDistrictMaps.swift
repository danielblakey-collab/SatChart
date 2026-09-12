import Foundation
import MapKit

/// One published XYZ pyramid. The matching MBTiles uses the same pack slug.
struct OnlineDistrictMap: Equatable, @unchecked Sendable {
    let pack: OfflinePack
    let minimumZoom: Int
    let maximumZoom: Int
    let bounds: MKMapRect
    var xyzPrefix: String? = nil

    var version: Int { pack.districtMapVersion! }
    var tilePrefix: String { xyzPrefix ?? "\(pack.slug)_xyz" }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pack == rhs.pack && lhs.minimumZoom == rhs.minimumZoom
            && lhs.maximumZoom == rhs.maximumZoom && lhs.tilePrefix == rhs.tilePrefix
            && MKMapRectEqualToRect(lhs.bounds, rhs.bounds)
    }

    func tileURL(for path: MKTileOverlayPath) -> URL {
        URL(string: "https://pub-832b588ef9ec4a588045736b6ce409b9.r2.dev")!
            .appendingPathComponent(tilePrefix)
            .appendingPathComponent(String(path.z))
            .appendingPathComponent(String(path.x))
            .appendingPathComponent("\(path.y).png")
    }

    func cacheKey(for path: MKTileOverlayPath) -> String {
        "districts/\(tilePrefix)/z\(path.z)/x\(path.x)/y\(path.y)"
    }

    func containsTile(_ path: MKTileOverlayPath) -> Bool {
        guard (minimumZoom...maximumZoom).contains(path.z) else { return false }
        let count = 1 << path.z
        guard (0..<count).contains(path.x), (0..<count).contains(path.y) else { return false }
        let width = MKMapRect.world.width / Double(count)
        let tileRect = MKMapRect(x: Double(path.x) * width, y: Double(path.y) * width,
                                 width: width, height: width)
        return bounds.intersects(tileRect)
    }
}

enum OnlineDistrictMapCatalog {
    static let supportedVersions = 1...15

    /// Verified bootstrap maps for first launch; subsequent availability comes from R2.
    static let maps: [OnlineDistrictMap] =
        ([4, 5, 6, 7, 3].map { map(district: .egegik, version: $0) }
         + [4, 5, 6].map { map(district: .ugashik, version: $0) }
         + [3, 4, 5, 6].map { map(district: .nushagak, version: $0) }
         + [3, 4].map { map(district: .naknek_kvichak, version: $0, prefix: "naknek_v\($0)_xyz") })

    static func map(district: DistrictID, version: Int, prefix: String? = nil) -> OnlineDistrictMap {
        precondition(supportedVersions.contains(version))
        return OnlineDistrictMap(pack: OfflinePack(district: district, slug: district.packSlug(forVersion: version)),
                                 minimumZoom: 4, maximumZoom: 15, bounds: bounds(for: district), xyzPrefix: prefix)
    }

    /// All prefixes that may be published without a new app release. v1 accepts
    /// the established base slug and the explicit `_v1` naming convention.
    static func candidates(district: DistrictID, version: Int) -> [OnlineDistrictMap] {
        let standard = map(district: district, version: version)
        var sources = [standard]
        if version == 1 {
            sources.append(map(district: district, version: 1, prefix: "\(district.rawValue)_v1_xyz"))
        }
        if district == .naknek_kvichak {
            // Accept the published short name for every supported version.
            let alias = version == 1 ? "naknek" : "naknek_v\(version)"
            sources.append(map(district: district, version: version, prefix: "\(alias)_xyz"))
            if version == 1 {
                sources.append(map(district: district, version: 1, prefix: "naknek_v1_xyz"))
            }
        }
        return sources
    }

    /// Fixed union geometry for every version of each district. These are the
    /// bundled AOI extents, padded by one native z15 pixel for raster rounding.
    static func bounds(for district: DistrictID) -> MKMapRect {
        let box: (west: Double, south: Double, east: Double, north: Double)
        switch district {
        case .egegik:
            // Preserve the geometry used by existing Egegik renderers and fixtures.
            box = (-157.65951633453372, 58.147518599073585, -157.24748611450195, 58.343988015946486)
        case .ugashik: box = (-157.94939102467816, 57.466121825020906, -157.4705730997837, 57.74650912748231)
        case .naknek_kvichak: box = (-157.78671968849454, 58.56111990902738, -155.8706031831495, 59.343279875417764)
        case .nushagak:
            // v3–v6 use the expanded nushagak_new AOI, including its southern/eastern flats.
            box = (-158.940110206604, 58.466681049701975, -158.19475650787356, 59.283421786680577)
        case .togiak: box = (-162.21512291641795, 58.5332571126732, -159.57720728570442, 59.13850435325093)
        }
        let nw = MKMapPoint(CLLocationCoordinate2D(latitude: box.north, longitude: box.west))
        let se = MKMapPoint(CLLocationCoordinate2D(latitude: box.south, longitude: box.east))
        let rect = MKMapRect(x: nw.x, y: nw.y, width: se.x - nw.x, height: se.y - nw.y)
        let pixel = MKMapRect.world.width / Double((1 << 15) * 256)
        return district == .egegik ? rect : rect.insetBy(dx: -pixel, dy: -pixel)
    }

    /// At z4 these small AOIs occupy at most two tiles. Check every intersecting
    /// tile so a sparse pyramid need not contain the AOI center tile.
    static func discoveryURLs(for source: OnlineDistrictMap) -> [URL] {
        MBTilesViewportTilePlanner.coordinates(in: source.bounds, zoom: 4, ring: 0, maximumCount: 4).map {
            source.tileURL(for: MKTileOverlayPath(x: $0.x, y: $0.y, z: $0.z, contentScaleFactor: 1))
        }
    }

    static var versions: [Int] { versions(in: maps) }
    static func versions(in maps: [OnlineDistrictMap]) -> [Int] { Array(Set(maps.map(\.version))).sorted() }

    static func normalizedVersion(_ requested: Int, in maps: [OnlineDistrictMap] = OnlineDistrictMapCatalog.maps) -> Int {
        let available = versions(in: maps)
        return available.contains(requested) ? requested : (available.first ?? 1)
    }

    static func nextVersion(after requested: Int, in maps: [OnlineDistrictMap] = OnlineDistrictMapCatalog.maps) -> Int {
        let available = versions(in: maps)
        guard let index = available.firstIndex(of: normalizedVersion(requested, in: maps)) else { return 1 }
        return available[(index + 1) % available.count]
    }

    /// Show one version per published district, falling back to its first available map.
    static func selectedMaps(version: Int, in maps: [OnlineDistrictMap] = OnlineDistrictMapCatalog.maps) -> [OnlineDistrictMap] {
        DistrictID.allCases.compactMap { district in
            let available = maps.filter { $0.pack.district == district }.sorted { $0.version < $1.version }
            return available.first { $0.version == version } ?? available.first
        }
    }
}

final class OnlineDistrictTileOverlay: MKTileOverlay {
    static let imageBudget = RasterImageBudget(limit: 32 * 1024 * 1024)

    typealias TileLoader = (URL, String, @escaping (Data?, Error?) -> Void) -> Void

    private struct LoadedVersion {
        let source: OnlineDistrictMap
        let continuity: RasterMapContinuity
        let tileLoader: TileLoader
    }
    private let stateLock = NSLock()
    private var loadedVersion: LoadedVersion
    private let coverageBounds: MKMapRect

    var source: OnlineDistrictMap { activeVersion().source }
    var continuity: RasterMapContinuity { activeVersion().continuity }

    private func activeVersion() -> LoadedVersion {
        stateLock.lock(); defer { stateLock.unlock() }
        return loadedVersion
    }

    /// Keep the installed overlay's identity/geometry while changing its prepared
    /// source. In-flight requests continue to use the version they started with.
    func adoptPreparedVersion(from replacement: OnlineDistrictTileOverlay) {
        let next = replacement.activeVersion()
        precondition(next.source.pack.district == source.pack.district)
        stateLock.lock()
        loadedVersion = next
        stateLock.unlock()
    }

    init(source: OnlineDistrictMap, tileLoader: TileLoader? = nil) {
        let load = tileLoader ?? { url, key, result in
            BristolBaySatelliteTileStore.shared.loadTile(url: url, cacheKey: key, result: result)
        }
        let prefix = source.tilePrefix
        let baseURL = source.tileURL(for: MKTileOverlayPath(x: 0, y: 0, z: 0, contentScaleFactor: 1))
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var policy = RasterMapContinuity.Policy()
        policy.imageBudget = Self.imageBudget
        // Five retained districts fit below the shared cap, leaving room for a
        // coarse replacement even when all five are visible. Admission further
        // reduces detail while old/new versions overlap during a handoff.
        policy.detailTiles = 24
        policy.overviewTiles = 4
        policy.concurrentLoads = 2
        let continuity = RasterMapContinuity(bounds: source.bounds,
                                             minimumZoom: source.minimumZoom,
                                             maximumZoom: source.maximumZoom, policy: policy) { tile, completion in
            let url = baseURL.appendingPathComponent("\(tile.z)/\(tile.x)/\(tile.y).png")
            let key = "districts/\(prefix)/z\(tile.z)/x\(tile.x)/y\(tile.y)"
            load(url, key) { data, error in
                RasterMapContinuity.decode(data, error: error, completion: completion)
            }
        }
        loadedVersion = LoadedVersion(source: source, continuity: continuity, tileLoader: load)
        let published = OnlineDistrictMapCatalog.maps.filter { $0.pack.district == source.pack.district }
        coverageBounds = published.reduce(source.bounds) { $0.union($1.bounds) }
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = min(source.minimumZoom, published.map(\.minimumZoom).min() ?? source.minimumZoom)
        // This is the native request limit. RasterContinuityRenderer scales the
        // retained parents at display zooms 16–17, just like the offline backstop,
        // without requesting nonexistent XYZ children or changing tile identity.
        maximumZ = max(source.maximumZoom, published.map(\.maximumZoom).max() ?? source.maximumZoom)
        isGeometryFlipped = false // Published folders are XYZ, unlike the TMS MBTiles rows.
    }

    override var boundingMapRect: MKMapRect { coverageBounds }
    override var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: coverageBounds.midX, y: coverageBounds.midY).coordinate
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        source.tileURL(for: path)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let version = activeVersion()
        guard version.source.containsTile(path) else {
            result(nil, nil)
            return
        }
        version.tileLoader(version.source.tileURL(for: path), version.source.cacheKey(for: path), result)
    }
}
