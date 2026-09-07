import Foundation
import MapKit

/// One published XYZ pyramid. The matching MBTiles uses the same pack slug.
struct OnlineDistrictMap {
    let pack: OfflinePack
    let minimumZoom: Int
    let maximumZoom: Int
    let bounds: MKMapRect

    var version: Int { pack.districtMapVersion! }
    var tilePrefix: String { "\(pack.slug)_xyz" }

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
    // Curate online maps independently: older downloadable packs have no XYZ pyramid.
    // These bounds and zooms match the published Egegik v4–v7 packages.
    static let maps: [OnlineDistrictMap] = {
        let northwest = MKMapPoint(CLLocationCoordinate2D(latitude: 58.343988015946486, longitude: -157.65951633453372))
        let southeast = MKMapPoint(CLLocationCoordinate2D(latitude: 58.147518599073585, longitude: -157.24748611450195))
        let bounds = MKMapRect(x: northwest.x, y: northwest.y,
                               width: southeast.x - northwest.x, height: southeast.y - northwest.y)
        return (4...7).map { version in
            OnlineDistrictMap(pack: OfflinePack(district: .egegik, slug: DistrictID.egegik.packSlug(forVersion: version)),
                              minimumZoom: 4, maximumZoom: 15, bounds: bounds)
        }
    }()

    static var versions: [Int] { Array(Set(maps.map(\.version))).sorted() }

    static func normalizedVersion(_ requested: Int) -> Int {
        versions.contains(requested) ? requested : (versions.first ?? 1)
    }

    static func nextVersion(after requested: Int) -> Int {
        let available = versions
        guard let index = available.firstIndex(of: normalizedVersion(requested)) else { return 1 }
        return available[(index + 1) % available.count]
    }

    /// Show one version per published district, falling back to its first available map.
    static func selectedMaps(version: Int) -> [OnlineDistrictMap] {
        DistrictID.allCases.compactMap { district in
            let available = maps.filter { $0.pack.district == district }.sorted { $0.version < $1.version }
            return available.first { $0.version == normalizedVersion(version) } ?? available.first
        }
    }
}

final class OnlineDistrictTileOverlay: MKTileOverlay {
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
        let continuity = RasterMapContinuity(bounds: source.bounds,
                                             minimumZoom: source.minimumZoom,
                                             maximumZoom: source.maximumZoom) { tile, completion in
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
