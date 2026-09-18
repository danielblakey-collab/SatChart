import Foundation

/// One delivery host for district imagery, its discovery probes, and the bay
/// underlay. Tile cache identities deliberately remain independent of the host.
nonisolated enum OnlineTileDelivery {
    // R2 custom domain verified to return identical imagery with Cloudflare cache hits.
    static let baseURL = URL(string: "https://tiles.getsatchart.com")!
}
