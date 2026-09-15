import Foundation
import Combine

/// The download catalog is verified independently of the online XYZ pyramids.
/// A district version is published here only when both its MBTiles and preview exist.
@MainActor
final class OfflineDistrictPackAvailability: ObservableObject {
    static let shared = OfflineDistrictPackAvailability()
    nonisolated static let baseURL = URL(string: "https://pub-832b588ef9ec4a588045736b6ce409b9.r2.dev")!

    @Published private(set) var packs: [OfflinePack] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var discoveryUnavailable = false

    enum ProbeResult: Sendable { case present, missing, unavailable }
    typealias Probe = @Sendable (URL) async -> ProbeResult

    private struct Entry: Codable, Equatable {
        let slug: String
        let mbtilesFilename: String
        let previewFilename: String
    }

    private struct Candidate: Sendable {
        let slug: String
        let mbtilesURLs: [URL]
        let previewURLs: [URL]
    }

    private enum Discovery: Sendable {
        case found(slug: String, mbtiles: String, preview: String)
        case missing(String)
        case unavailable(String)
    }

    private enum AssetDiscovery: Sendable {
        case found(URL), missing, unavailable
    }

    private static let cacheKey = "offlineDistrictPackAvailabilityV1"
    private let defaults: UserDefaults
    private let probe: Probe
    private let now: () -> Date
    private let scanDuration: TimeInterval
    private var resumeSlug: String?
    private var entriesBySlug: [String: Entry] = [:]
    private var lastRefresh: Date?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0

    nonisolated private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        return URLSession(configuration: config)
    }()

    init(defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         scanDuration: TimeInterval = 45,
         probe: @escaping Probe = { await OfflineDistrictPackAvailability.head($0) }) {
        self.defaults = defaults
        self.now = now
        self.scanDuration = scanDuration
        self.probe = probe

        // There are no guessed bootstrap cards. Only previously verified pairs
        // can be restored while offline, and cached names must match our aliases.
        if let data = defaults.data(forKey: Self.cacheKey), data.count <= 65_536,
           let entries = try? JSONDecoder().decode([Entry].self, from: data),
           entries.count <= DistrictID.allCases.count * DistrictID.maximumSupportedPackVersion,
           Set(entries.map(\.slug)).count == entries.count,
           entries.allSatisfy({ entry in
               guard let district = DistrictID.district(forDistrictMapSlug: entry.slug) else { return false }
               let pack = OfflinePack(district: district, slug: entry.slug)
               return pack.remoteMBTilesFilenameCandidates.contains(entry.mbtilesFilename)
                   && pack.previewFilenameCandidates.contains(entry.previewFilename)
           }) {
            entriesBySlug = Dictionary(uniqueKeysWithValues: entries.map { ($0.slug, $0) })
            publishPacks()
        }
    }

    func packs(for district: DistrictID) -> [OfflinePack] {
        packs.filter { $0.district == district }
    }

    /// Prefer the exact object that was verified, retaining fallbacks for aliases
    /// and the non-district basemaps, which use the same URL helpers.
    func mbtilesURLs(for pack: OfflinePack) -> [URL] {
        urls(pack.remoteMBTilesFilenameCandidates, preferred: entriesBySlug[pack.slug]?.mbtilesFilename)
    }

    func previewURLs(for pack: OfflinePack) -> [URL] {
        urls(pack.previewFilenameCandidates, preferred: entriesBySlug[pack.slug]?.previewFilename)
    }

    /// Coalesce appearances, including forced refreshes during an active scan.
    /// A complete scan is reused for five minutes; a network failure retries after one.
    func refreshIfNeeded(force: Bool = false) {
        guard refreshTask == nil,
              force || (lastRefresh.map({ now().timeIntervalSince($0) >= 300 }) ?? true) else { return }
        generation += 1
        let ticket = generation
        isRefreshing = true
        discoveryUnavailable = false
        let candidates = orderedCandidates()
        let probe = self.probe
        let scanDuration = self.scanDuration
        refreshTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(scanDuration)
            var stoppedAtDeadline = false
            await withTaskGroup(of: Discovery.self) { group in
                // Two in-flight HEAD requests at most; each completed candidate
                // publishes immediately, so one slow object cannot hide other cards.
                var nextIndex = 0
                for _ in 0..<min(2, candidates.count) {
                    let candidate = candidates[nextIndex]
                    group.addTask { await Self.discover(candidate, deadline: deadline, probe: probe) }
                    nextIndex += 1
                }
                while let result = await group.next() {
                    guard let self, !Task.isCancelled, self.generation == ticket else {
                        group.cancelAll()
                        return
                    }
                    switch result {
                    case .found(let slug, let mbtiles, let preview):
                        self.entriesBySlug[slug] = Entry(slug: slug, mbtilesFilename: mbtiles, previewFilename: preview)
                    case .missing(let slug): self.entriesBySlug.removeValue(forKey: slug)
                    case .unavailable(let slug):
                        self.discoveryUnavailable = true
                        if Date() >= deadline, !stoppedAtDeadline {
                            stoppedAtDeadline = true
                            self.resumeSlug = nextIndex < candidates.count ? candidates[nextIndex].slug : slug
                        }
                    }
                    self.publishPacks()
                    if nextIndex < candidates.count {
                        if Date() < deadline {
                            let candidate = candidates[nextIndex]
                            group.addTask { await Self.discover(candidate, deadline: deadline, probe: probe) }
                            nextIndex += 1
                        } else {
                            self.discoveryUnavailable = true
                            stoppedAtDeadline = true
                            self.resumeSlug = candidates[nextIndex].slug
                        }
                    }
                }
            }
            guard let self, !Task.isCancelled, self.generation == ticket else { return }
            if !stoppedAtDeadline { self.resumeSlug = nil }
            self.saveCache()
            self.lastRefresh = self.now().addingTimeInterval(self.discoveryUnavailable ? -240 : 0)
            self.refreshTask = nil
            self.isRefreshing = false
        }
    }

    func cancelRefresh() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        // Completed positive checks remain useful even if the user leaves mid-scan.
        saveCache()
    }

    /// Lets pull-to-refresh remain active until the current coalesced scan finishes.
    func refresh(force: Bool = false) async {
        refreshIfNeeded(force: force)
        await refreshTask?.value
    }

    private func orderedCandidates() -> [Candidate] {
        // Interleave districts so an initial slow connection does not spend its
        // entire budget scanning one district. Refresh verified pairs first.
        let allPacks = (1...DistrictID.maximumSupportedPackVersion).flatMap { version in
            DistrictID.allCases.map { OfflinePack(district: $0, slug: $0.packSlug(forVersion: version)) }
        }
        var ordered = allPacks.filter { entriesBySlug[$0.slug] != nil }
            + allPacks.filter { entriesBySlug[$0.slug] == nil }
        // On a budget-limited scan, continue with the next unvisited candidate.
        // Rotating the whole list also prevents cached packs from starving new uploads.
        if let resumeSlug, let index = ordered.firstIndex(where: { $0.slug == resumeSlug }) {
            ordered = Array(ordered[index...]) + Array(ordered[..<index])
        }
        return ordered.map { pack in
            Candidate(slug: pack.slug, mbtilesURLs: mbtilesURLs(for: pack), previewURLs: previewURLs(for: pack))
        }
    }

    private func publishPacks() {
        let updated = DistrictID.allCases.flatMap { district in
            district.supportedLocalMapPacks.filter { entriesBySlug[$0.slug] != nil }
        }
        if packs != updated { packs = updated }
    }

    private func saveCache() {
        let entries = entriesBySlug.values.sorted { $0.slug < $1.slug }
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.cacheKey) }
    }

    private func urls(_ filenames: [String], preferred: String?) -> [URL] {
        var ordered = filenames
        if let preferred, let index = ordered.firstIndex(of: preferred) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        return ordered.map { Self.baseURL.appendingPathComponent($0) }
    }

    nonisolated private static func discover(_ candidate: Candidate, deadline: Date, probe: Probe) async -> Discovery {
        let mbtiles = await findAsset(candidate.mbtilesURLs, deadline: deadline, probe: probe)
        switch mbtiles {
        case .missing: return .missing(candidate.slug)
        case .unavailable: return .unavailable(candidate.slug)
        case .found(let mbtilesURL):
            switch await findAsset(candidate.previewURLs, deadline: deadline, probe: probe) {
            case .found(let previewURL):
                return .found(slug: candidate.slug, mbtiles: mbtilesURL.lastPathComponent, preview: previewURL.lastPathComponent)
            case .missing: return .missing(candidate.slug)
            case .unavailable: return .unavailable(candidate.slug)
            }
        }
    }

    nonisolated private static func findAsset(_ urls: [URL], deadline: Date, probe: Probe) async -> AssetDiscovery {
        var uncertain = false
        for url in urls {
            guard !Task.isCancelled, Date() < deadline else { return .unavailable }
            switch await probe(url) {
            case .present: return .found(url)
            case .missing: break
            case .unavailable: uncertain = true
            }
        }
        return uncertain ? .unavailable : .missing
    }

    nonisolated static func classify(_ response: URLResponse, for url: URL) -> ProbeResult {
        guard let http = response as? HTTPURLResponse else { return .unavailable }
        if http.statusCode == 404 || http.statusCode == 410 { return .missing }
        guard http.statusCode == 200, http.expectedContentLength > 0 else { return .unavailable }
        let mime = http.mimeType?.lowercased() ?? ""
        if url.pathExtension == "mbtiles" {
            // R2 serves the published SQLite files as application/octet-stream.
            let types = ["application/octet-stream", "application/x-sqlite3", "application/vnd.sqlite3", "application/x-sqlite2"]
            return types.contains(mime) ? .present : .unavailable
        }
        return ["image/jpeg", "image/png"].contains(mime) ? .present : .unavailable
    }

    nonisolated static func head(_ url: URL) async -> ProbeResult {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 6)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await session.data(for: request)
            return classify(response, for: url)
        } catch { return .unavailable }
    }
}
