import Foundation
import Combine

@MainActor
final class OfflineMapsManager: NSObject, ObservableObject {

    static let shared = OfflineMapsManager()

    @Published var status: String = ""
    @Published var downloadedTick: Int = 0
    @Published var isDownloading: [String: Bool] = [:]
    @Published var progress: [String: Double] = [:]
    @Published var downloadedBytes: [String: Int64] = [:]
    @Published var totalBytes: [String: Int64] = [:]
    @Published var remoteBytes: [String: Int64] = [:]
    @Published var activePack: OfflinePack? = nil

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    /// Lightweight session used for remote probes / size lookups.
    private lazy var headSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private var downloadTaskBySlug: [String: URLSessionDownloadTask] = [:]
    private var preflightTaskBySlug: [String: Task<Void, Never>] = [:]
    private var sizeProbeTaskBySlug: [String: Task<Void, Never>] = [:]
    private var resolvedRemoteURLBySlug: [String: URL] = [:]

    private override init() {
        super.init()
    }

    private struct RemoteProbeResult {
        let url: URL
        let sizeBytes: Int64?
    }

    private func mbtilesDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("MBTiles", isDirectory: true)
    }

    func localMBTilesURL(for pack: OfflinePack) -> URL {
        mbtilesDir().appendingPathComponent("\(pack.slug).mbtiles")
    }

    func localMBTilesURL(forSlug slug: String) -> URL {
        mbtilesDir().appendingPathComponent("\(slug).mbtiles")
    }

    func localMBTilesURLs(for pack: OfflinePack) -> [URL] {
        var seen: Set<String> = []
        return pack.remoteBasenameCandidates
            .map { localMBTilesURL(forSlug: $0) }
            .filter { seen.insert($0.path).inserted }
    }

    func isDownloaded(_ pack: OfflinePack) -> Bool {
        localMBTilesURLs(for: pack).contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    func isDownloaded(slug: String) -> Bool {
        FileManager.default.fileExists(atPath: localMBTilesURL(forSlug: slug).path)
    }

    func firstExistingLocalMBTilesURL(for pack: OfflinePack) -> URL? {
        localMBTilesURLs(for: pack).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func localFileSizeBytes(_ pack: OfflinePack) -> Int64? {
        for url in localMBTilesURLs(for: pack) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber else { continue }
            return size.int64Value
        }
        return nil
    }

    private func ensureMBTilesDirExists() throws {
        try FileManager.default.createDirectory(at: mbtilesDir(), withIntermediateDirectories: true)
    }

    func downloadedDistrictMapPacks(for district: DistrictID) -> [OfflinePack] {
        district.supportedLocalMapPacks
            .filter { isDownloaded($0) }
            .sorted { lhs, rhs in
                let lhsVersion = lhs.districtMapVersion ?? Int.max
                let rhsVersion = rhs.districtMapVersion ?? Int.max
                if lhsVersion != rhsVersion { return lhsVersion < rhsVersion }
                return lhs.slug < rhs.slug
            }
    }

    func maximumDownloadedDistrictMapVersionCount() -> Int {
        max(1, DistrictID.allCases.map { downloadedDistrictMapPacks(for: $0).count }.max() ?? 1)
    }

    func selectedDownloadedDistrictMapPack(for district: DistrictID, selectedMapVersion: Int) -> OfflinePack? {
        let downloadedPacks = downloadedDistrictMapPacks(for: district)
        guard !downloadedPacks.isEmpty else { return nil }

        let normalizedVersion = max(1, selectedMapVersion)
        let index = (normalizedVersion - 1) % downloadedPacks.count
        return downloadedPacks[index]
    }

    func preferredLocalDistrictMBTilesSlug(for district: DistrictID, selectedMapVersion: Int) -> String? {
        selectedDownloadedDistrictMapPack(for: district, selectedMapVersion: selectedMapVersion)?.slug
    }

    func preferredLocalDistrictMBTilesURL(for district: DistrictID, selectedMapVersion: Int) -> URL? {
        guard let pack = selectedDownloadedDistrictMapPack(for: district, selectedMapVersion: selectedMapVersion) else {
            return nil
        }
        return firstExistingLocalMBTilesURL(for: pack)
    }

    /// District maps and shoreline overlays that the map renderer should consider.
    /// This includes curated remote-download cards plus any locally present `_v#` files,
    /// so a newly downloaded map version can participate in the cycle immediately.
    func localOverlayCandidatePacks() -> [OfflinePack] {
        var result: [OfflinePack] = []
        var seen: Set<String> = []

        func append(_ pack: OfflinePack) {
            guard seen.insert(pack.slug).inserted else { return }
            result.append(pack)
        }

        for district in DistrictID.allCases {
            district.packs.forEach(append)
            downloadedDistrictMapPacks(for: district).forEach(append)
        }

        OfflinePack.shorelinePacks.forEach(append)
        return result
    }

    func delete(_ pack: OfflinePack) {
        cancel(pack)

        do {
            for url in localMBTilesURLs(for: pack) where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            downloadedTick += 1
            status = "Deleted \(pack.slug)"
        } catch {
            status = "❌ Delete failed: \(error.localizedDescription)"
        }
    }

    func cancel(_ pack: OfflinePack) {
        let slug = pack.slug

        if let task = downloadTaskBySlug[slug] {
            task.cancel()
            downloadTaskBySlug[slug] = nil
        }

        if let task = preflightTaskBySlug[slug] {
            task.cancel()
            preflightTaskBySlug[slug] = nil
        }

        if let task = sizeProbeTaskBySlug[slug] {
            task.cancel()
            sizeProbeTaskBySlug[slug] = nil
        }

        isDownloading[slug] = false
        progress[slug] = 0
        downloadedBytes[slug] = 0
        totalBytes[slug] = 0
        if activePack?.slug == slug { activePack = nil }
        status = "Cancelled \(slug)"
    }

    func download(pack: OfflinePack, from remoteURL: URL) {
        download(pack: pack, fromCandidates: [remoteURL])
    }

    func download(pack: OfflinePack, fromCandidates remoteURLs: [URL]) {
        let slug = pack.slug

        do { try ensureMBTilesDirExists() }
        catch {
            status = "❌ Can't create MBTiles folder: \(error.localizedDescription)"
            return
        }

        if let active = activePack, !(isDownloading[active.slug] ?? false) {
            activePack = nil
        }

        if let active = activePack, active.slug != slug, (isDownloading[active.slug] ?? false) {
            status = "Already downloading \(active.slug). Cancel it first."
            return
        }

        if isDownloading[slug] == true || downloadTaskBySlug[slug] != nil || preflightTaskBySlug[slug] != nil {
            status = "\(slug) is already downloading."
            return
        }

        activePack = pack
        status = "Preparing \(slug)…"
        isDownloading[slug] = true
        progress[slug] = 0
        downloadedBytes[slug] = 0
        totalBytes[slug] = 0

        let task = Task { [weak self] in
            guard let self else { return }

            let probe = await self.resolveRemoteMBTiles(forSlug: slug, candidateURLs: remoteURLs)

            guard !Task.isCancelled else { return }

            if let probe {
                if let size = probe.sizeBytes {
                    self.remoteBytes[slug] = size
                    self.totalBytes[slug] = size
                }
                self.resolvedRemoteURLBySlug[slug] = probe.url
                self.preflightTaskBySlug[slug] = nil
                self.startDownload(pack: pack, from: probe.url)
            } else {
                self.preflightTaskBySlug[slug] = nil
                self.isDownloading[slug] = false
                self.progress[slug] = 0
                self.downloadedBytes[slug] = 0
                self.totalBytes[slug] = 0
                if self.activePack?.slug == slug { self.activePack = nil }
                self.status = "❌ Remote MBTiles not found for \(slug)"
            }
        }

        preflightTaskBySlug[slug] = task
    }

    private func startDownload(pack: OfflinePack, from remoteURL: URL) {
        let slug = pack.slug
        guard isDownloading[slug] == true else { return }

        status = "Downloading \(slug)…"

        let task = session.downloadTask(with: remoteURL)
        task.taskDescription = slug
        downloadTaskBySlug[slug] = task

        #if DEBUG
        print("⬇️ Download start [\(slug)]: \(remoteURL.absoluteString)")
        #endif
        task.resume()
    }

    func fetchRemoteSizeIfNeeded(pack: OfflinePack, url: URL) {
        fetchRemoteSizeIfNeeded(pack: pack, urls: [url])
    }

    func fetchRemoteSizeIfNeeded(pack: OfflinePack, urls: [URL]) {
        let slug = pack.slug
        if remoteBytes[slug] != nil { return }
        if sizeProbeTaskBySlug[slug] != nil { return }

        let task = Task { [weak self] in
            guard let self else { return }

            let probe = await self.resolveRemoteMBTiles(forSlug: slug, candidateURLs: urls)
            guard !Task.isCancelled else { return }

            if let probe {
                self.resolvedRemoteURLBySlug[slug] = probe.url
                if let size = probe.sizeBytes {
                    self.remoteBytes[slug] = size
                }
            }

            self.sizeProbeTaskBySlug[slug] = nil
        }

        sizeProbeTaskBySlug[slug] = task
    }

    private func resolveRemoteMBTiles(forSlug slug: String, candidateURLs: [URL]) async -> RemoteProbeResult? {
        if let cachedURL = resolvedRemoteURLBySlug[slug] {
            return RemoteProbeResult(url: cachedURL, sizeBytes: remoteBytes[slug])
        }

        var seen: Set<String> = []
        let dedupedCandidates = candidateURLs.filter { seen.insert($0.absoluteString).inserted }

        for url in dedupedCandidates {
            if Task.isCancelled { return nil }
            if let probe = await probeRemoteMBTiles(at: url) {
                return probe
            }
        }

        return nil
    }

    private func probeRemoteMBTiles(at url: URL) async -> RemoteProbeResult? {
        // Try HEAD first because it is cheap and gives us the full size when supported.
        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"
        headRequest.timeoutInterval = 12
        headRequest.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (_, response) = try await headSession.data(for: headRequest)
            if let http = response as? HTTPURLResponse,
               (200...299).contains(http.statusCode),
               !contentTypeLooksLikeErrorDocument(http) {
                return RemoteProbeResult(
                    url: url,
                    sizeBytes: totalSizeBytes(from: http)
                )
            }
        } catch {
            // Fall through to the ranged GET probe below.
        }

        // Fallback: read just the SQLite header if the server blocks HEAD or returns an ambiguous type.
        var rangeRequest = URLRequest(url: url)
        rangeRequest.httpMethod = "GET"
        rangeRequest.timeoutInterval = 15
        rangeRequest.cachePolicy = .reloadIgnoringLocalCacheData
        rangeRequest.setValue("bytes=0-15", forHTTPHeaderField: "Range")

        do {
            let (data, response) = try await headSession.data(for: rangeRequest)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) || http.statusCode == 206,
                  data.count >= 16,
                  let headerString = String(data: data.prefix(16), encoding: .utf8),
                  headerString.contains("SQLite format 3") else {
                return nil
            }

            return RemoteProbeResult(
                url: url,
                sizeBytes: totalSizeBytes(from: http)
            )
        } catch {
            return nil
        }
    }

    private func contentTypeLooksLikeErrorDocument(_ http: HTTPURLResponse) -> Bool {
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard !contentType.isEmpty else { return false }
        return contentType.contains("text/html")
            || contentType.contains("application/xml")
            || contentType.contains("text/xml")
            || contentType.contains("application/json")
            || contentType.hasPrefix("text/")
    }

    private func totalSizeBytes(from http: HTTPURLResponse) -> Int64? {
        if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let totalComponent = contentRange.split(separator: "/").last,
           let total = Int64(totalComponent) {
            return total
        }

        if let contentLength = http.value(forHTTPHeaderField: "Content-Length"),
           let total = Int64(contentLength) {
            return total
        }

        return nil
    }

    private func replacementBackupURL(for slug: String) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return mbtilesDir().appendingPathComponent("\(slug).replaced-\(stamp).mbtiles")
    }

    private func finalizeDownloadedFile(stableTmp: URL, slug: String) throws {
        let handle = try FileHandle(forReadingFrom: stableTmp)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 16) ?? Data()
        guard header.count >= 16,
              let headerString = String(data: header, encoding: .utf8),
              headerString.contains("SQLite format 3") else {
            throw NSError(domain: "OfflineMaps", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid MBTiles (not SQLite)"])
        }

        let dst = mbtilesDir().appendingPathComponent("\(slug).mbtiles")
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) {
            let backup = replacementBackupURL(for: slug)
            try? fm.removeItem(at: backup)
            try fm.moveItem(at: dst, to: backup)
        }
        try fm.moveItem(at: stableTmp, to: dst)
    }
}

extension OfflineMapsManager: URLSessionDownloadDelegate {
    nonisolated private static func slug(from task: URLSessionTask) -> String? { task.taskDescription }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let slug = Self.slug(from: downloadTask) else { return }
        Task { @MainActor in
            self.downloadedBytes[slug] = totalBytesWritten
            self.totalBytes[slug] = max(totalBytesExpectedToWrite, 0)
            self.progress[slug] = totalBytesExpectedToWrite > 0 ? min(1.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : 0
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let slug = Self.slug(from: downloadTask) else { return }
        let fm = FileManager.default
        let stableTmp = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)_\(slug).mbtiles")
        do {
            if fm.fileExists(atPath: stableTmp.path) { try? fm.removeItem(at: stableTmp) }
            try fm.moveItem(at: location, to: stableTmp)
        } catch {
            Task { @MainActor in
                self.isDownloading[slug] = false
                self.status = "❌ Temp move failed [\(slug)]: \(error.localizedDescription)"
                if self.activePack?.slug == slug { self.activePack = nil }
                self.downloadTaskBySlug[slug] = nil
            }
            return
        }

        Task { @MainActor in
            do {
                try self.finalizeDownloadedFile(stableTmp: stableTmp, slug: slug)
                self.isDownloading[slug] = false
                self.progress[slug] = 1.0
                self.status = "✅ Downloaded \(slug)"
                self.downloadedTick += 1
            } catch {
                self.isDownloading[slug] = false
                self.progress[slug] = 0
                self.status = "❌ Finalize failed [\(slug)]: \(error.localizedDescription)"
                try? FileManager.default.removeItem(at: stableTmp)
            }
            if self.activePack?.slug == slug { self.activePack = nil }
            self.downloadTaskBySlug[slug] = nil
            self.preflightTaskBySlug[slug] = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let slug = Self.slug(from: task), let error = error else { return }
        Task { @MainActor in
            if (error as NSError).code != NSURLErrorCancelled {
                self.isDownloading[slug] = false
                self.progress[slug] = 0
                self.status = "❌ Download failed [\(slug)]: \(error.localizedDescription)"
            }
            if self.activePack?.slug == slug { self.activePack = nil }
            self.downloadTaskBySlug[slug] = nil
            self.preflightTaskBySlug[slug] = nil
        }
    }
}
