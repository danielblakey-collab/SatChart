import Foundation
import Combine

/// Discovers public XYZ pyramids without credentials or a bucket-listing endpoint.
/// Only HEAD requests are sent; the scan never downloads or decodes tile images.
@MainActor
final class OnlineDistrictMapAvailability: ObservableObject {
    static let shared = OnlineDistrictMapAvailability()
    @Published private(set) var maps: [OnlineDistrictMap]
    @Published private(set) var isRefreshing = false

    enum ProbeResult: Sendable { case present, missing, unavailable }
    typealias Probe = @Sendable (URL) async -> ProbeResult
    private struct Entry: Codable {
        let district: String
        let version: Int
        let prefix: String
    }
    private struct Candidate: Sendable {
        let source: OnlineDistrictMap
        let urls: [URL]
    }
    private enum Discovery: Sendable {
        case found(OnlineDistrictMap), missing(String), unavailable
    }
    private static let cacheKey = "onlineDistrictXYZAvailabilityV1"
    private let defaults: UserDefaults
    private let probe: Probe
    private let now: () -> Date
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
         initialMaps: [OnlineDistrictMap]? = nil,
         now: @escaping () -> Date = Date.init,
         probe: @escaping Probe = OnlineDistrictMapAvailability.head) {
        let initialMaps = initialMaps ?? OnlineDistrictMapCatalog.maps
        self.defaults = defaults
        self.probe = probe
        self.now = now
        if let data = defaults.data(forKey: Self.cacheKey), data.count <= 32_768,
           let entries = try? JSONDecoder().decode([Entry].self, from: data), entries.count <= 75 {
            let restored = entries.compactMap { entry -> OnlineDistrictMap? in
                guard let district = DistrictID(rawValue: entry.district),
                      OnlineDistrictMapCatalog.supportedVersions.contains(entry.version) else { return nil }
                return OnlineDistrictMapCatalog.candidates(district: district, version: entry.version)
                    .first { $0.tilePrefix == entry.prefix }
            }
            if restored.count == entries.count, Set(restored.map(\.pack.slug)).count == restored.count {
                maps = restored
            } else { maps = initialMaps }
        } else { maps = initialMaps }
    }

    /// Coalesce repeated appearances and refresh at most every five minutes.
    /// An interrupted/offline scan retains known maps and can retry after a minute.
    func refreshIfNeeded(force: Bool = false) {
        guard refreshTask == nil,
              force || (lastRefresh.map({ now().timeIntervalSince($0) >= 300 }) ?? true) else { return }
        generation += 1
        let ticket = generation
        isRefreshing = true
        let known = maps
        let probe = self.probe
        refreshTask = Task { [weak self] in
            let results = await Self.discover(known: known, probe: probe)
            guard let self, !Task.isCancelled, self.generation == ticket else { return }
            var merged = Dictionary(uniqueKeysWithValues: known.map { ($0.pack.slug, $0) })
            var hadFailure = false
            for result in results {
                switch result {
                case .found(let map): merged[map.pack.slug] = map
                case .missing(let slug): merged.removeValue(forKey: slug)
                case .unavailable: hadFailure = true
                }
            }
            let updated = merged.values.sorted {
                $0.pack.district.rawValue == $1.pack.district.rawValue
                    ? $0.version < $1.version : $0.pack.district.rawValue < $1.pack.district.rawValue
            }
            if self.maps != updated { self.maps = updated }
            let entries = updated.map { Entry(district: $0.pack.district.rawValue,
                                               version: $0.version, prefix: $0.tilePrefix) }
            if let data = try? JSONEncoder().encode(entries) { self.defaults.set(data, forKey: Self.cacheKey) }
            self.lastRefresh = self.now().addingTimeInterval(hadFailure ? -240 : 0)
            self.refreshTask = nil
            self.isRefreshing = false
        }
    }

    func cancelRefresh() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    private static func discover(known: [OnlineDistrictMap], probe: @escaping Probe) async -> [Discovery] {
        let candidates = DistrictID.allCases.flatMap { district in
            OnlineDistrictMapCatalog.supportedVersions.map { version -> [Candidate] in
                var alternatives = OnlineDistrictMapCatalog.candidates(district: district, version: version)
                if let preferred = known.first(where: { $0.pack.district == district && $0.version == version }),
                   let index = alternatives.firstIndex(where: { $0.tilePrefix == preferred.tilePrefix }) {
                    alternatives.insert(alternatives.remove(at: index), at: 0)
                }
                return alternatives.map { Candidate(source: $0, urls: OnlineDistrictMapCatalog.discoveryURLs(for: $0)) }
            }
        }
        let deadline = Date().addingTimeInterval(45)
        return await withTaskGroup(of: [Discovery].self) { group in
            // Exactly two workers, not 75 suspended network tasks.
            for worker in 0..<2 {
                group.addTask {
                    var results: [Discovery] = []
                    for index in stride(from: worker, to: candidates.count, by: 2) {
                        guard !Task.isCancelled, Date() < deadline else {
                            results.append(.unavailable); break
                        }
                        let alternatives = candidates[index]
                        var found: OnlineDistrictMap?
                        var uncertain = false
                        for candidate in alternatives {
                            for url in candidate.urls {
                                guard !Task.isCancelled, Date() < deadline else { uncertain = true; break }
                                switch await probe(url) {
                                case .present: found = candidate.source
                                case .missing: break
                                case .unavailable: uncertain = true
                                }
                                if found != nil { break }
                            }
                            if found != nil { break }
                        }
                        if let found { results.append(.found(found)) }
                        else if uncertain { results.append(.unavailable) }
                        else { results.append(.missing(alternatives[0].source.pack.slug)) }
                    }
                    return results
                }
            }
            var results: [Discovery] = []
            for await batch in group { results.append(contentsOf: batch) }
            return results
        }
    }

    nonisolated static func classify(_ response: URLResponse) -> ProbeResult {
        guard let http = response as? HTTPURLResponse else { return .unavailable }
        if http.statusCode == 404 || http.statusCode == 410 { return .missing }
        guard http.statusCode == 200, http.mimeType?.lowercased() == "image/png",
              http.expectedContentLength > 0 else { return .unavailable }
        return .present
    }

    nonisolated static func head(_ url: URL) async -> ProbeResult {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 6)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await session.data(for: request)
            return classify(response)
        } catch { return .unavailable }
    }
}
