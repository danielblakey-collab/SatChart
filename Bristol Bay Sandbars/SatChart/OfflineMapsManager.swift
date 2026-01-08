import Foundation
import Combine

/// Represents one downloadable MBTiles file + preview image.
/// `slug` is the filename WITHOUT extension (e.g. "egegik", "egegik_v2")
struct OfflinePack: Identifiable, Hashable {
    let district: DistrictID
    let slug: String

    var id: String { slug }
}

@MainActor
final class OfflineMapsManager: NSObject, ObservableObject {

    static let shared = OfflineMapsManager()

    // MARK: - Published UI state

    @Published var status: String = ""
    @Published var downloadedTick: Int = 0

    // keyed by slug
    @Published var isDownloading: [String: Bool] = [:]
    @Published var progress: [String: Double] = [:]           // 0...1
    @Published var downloadedBytes: [String: Int64] = [:]
    @Published var totalBytes: [String: Int64] = [:]

    @Published var remoteBytes: [String: Int64] = [:]

    /// Only ONE active download at a time
    @Published var activePack: OfflinePack? = nil

    // MARK: - Private

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    private lazy var headSession: URLSession = {
        URLSession(configuration: .default)
    }()

    /// Track tasks by slug so we can cancel
    private var downloadTaskBySlug: [String: URLSessionDownloadTask] = [:]

    private override init() {
        super.init()
    }

    // MARK: - Paths

    private func mbtilesDir() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("MBTiles", isDirectory: true)
    }

    func localMBTilesURL(for pack: OfflinePack) -> URL {
        mbtilesDir().appendingPathComponent("\(pack.slug).mbtiles")
    }

    func isDownloaded(_ pack: OfflinePack) -> Bool {
        FileManager.default.fileExists(atPath: localMBTilesURL(for: pack).path)
    }

    func localFileSizeBytes(_ pack: OfflinePack) -> Int64? {
        let url = localMBTilesURL(for: pack)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    private func ensureMBTilesDirExists() throws {
        let dir = mbtilesDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - Delete

    func delete(_ pack: OfflinePack) {
        cancel(pack)

        let url = localMBTilesURL(for: pack)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            downloadedTick += 1
            status = "Deleted \(pack.slug)"
        } catch {
            status = "❌ Delete failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Cancel

    func cancel(_ pack: OfflinePack) {
        let slug = pack.slug

        if let task = downloadTaskBySlug[slug] {
            task.cancel()
            downloadTaskBySlug[slug] = nil
        }

        isDownloading[slug] = false
        progress[slug] = 0
        downloadedBytes[slug] = 0
        totalBytes[slug] = 0

        if activePack?.slug == slug { activePack = nil }
        status = "Cancelled \(slug)"
    }

    // MARK: - Download (one at a time)

    func download(pack: OfflinePack, from remoteURL: URL) {
        let slug = pack.slug

        do { try ensureMBTilesDirExists() }
        catch {
            status = "❌ Can't create MBTiles folder: \(error.localizedDescription)"
            return
        }

        // Enforce ONE download at a time
        if let active = activePack, active.slug != slug {
            status = "Already downloading \(active.slug). Cancel it first."
            return
        }

        // Remove partial local file
        let dst = localMBTilesURL(for: pack)
        if FileManager.default.fileExists(atPath: dst.path) {
            try? FileManager.default.removeItem(at: dst)
        }

        activePack = pack
        status = "Downloading \(slug)…"

        isDownloading[slug] = true
        progress[slug] = 0
        downloadedBytes[slug] = 0
        totalBytes[slug] = 0

        let task = session.downloadTask(with: remoteURL)
        task.taskDescription = slug   // ✅ KEY: use this in delegate callbacks
        downloadTaskBySlug[slug] = task

        print("⬇️ Download start [\(slug)]: \(remoteURL.absoluteString)")
        task.resume()
    }

    // MARK: - Remote HEAD size

    func fetchRemoteSizeIfNeeded(pack: OfflinePack, url: URL) {
        let slug = pack.slug
        if remoteBytes[slug] != nil { return }

        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"

        print("📏 HEAD size [\(slug)]: \(url.absoluteString)")
        headSession.dataTask(with: req) { [weak self] _, resp, err in
            guard let self else { return }

            if let err = err {
                Task { @MainActor in
                    self.status = "❌ HEAD failed [\(slug)]: \(err.localizedDescription)"
                }
                return
            }

            guard let http = resp as? HTTPURLResponse,
                  let lenStr = http.value(forHTTPHeaderField: "Content-Length"),
                  let len = Int64(lenStr) else { return }

            Task { @MainActor in
                self.remoteBytes[slug] = len
            }
        }.resume()
    }

    // MARK: - Finalize

    private func finalizeDownloadedFile(stableTmp: URL, slug: String) throws {
        // quick SQLite sanity check
        let header = try Data(contentsOf: stableTmp, options: [.mappedIfSafe])
        if header.count < 16 ||
            String(data: header.prefix(16), encoding: .utf8)?.contains("SQLite format 3") != true {
            throw NSError(domain: "OfflineMaps", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid MBTiles (not SQLite)"])
        }

        // Destination is always slug.mbtiles
        let dst = mbtilesDir().appendingPathComponent("\(slug).mbtiles")
        let fm = FileManager.default

        try fm.createDirectory(at: dst.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.moveItem(at: stableTmp, to: dst)
    }
}

// MARK: - URLSessionDownloadDelegate
extension OfflineMapsManager: URLSessionDownloadDelegate {

    nonisolated private static func slug(from task: URLSessionTask) -> String? {
        task.taskDescription
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let slug = Self.slug(from: downloadTask) else { return }

        Task { @MainActor in
            self.downloadedBytes[slug] = totalBytesWritten
            self.totalBytes[slug] = max(totalBytesExpectedToWrite, 0)

            if totalBytesExpectedToWrite > 0 {
                self.progress[slug] = min(1.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
            } else {
                self.progress[slug] = 0
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let slug = Self.slug(from: downloadTask) else { return }

        // Move to stable temp first (delegate-provided URL can vanish after return)
        let fm = FileManager.default
        let stableTmp = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)_\(slug).mbtiles")

        do {
            if fm.fileExists(atPath: stableTmp.path) { try? fm.removeItem(at: stableTmp) }
            try fm.moveItem(at: location, to: stableTmp)
        } catch {
            Task { @MainActor in
                self.isDownloading[slug] = false
                self.progress[slug] = 0
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
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let slug = Self.slug(from: task) else { return }
        guard let error = error else { return }

        Task { @MainActor in
            if (error as NSError).code != NSURLErrorCancelled {
                self.isDownloading[slug] = false
                self.progress[slug] = 0
                self.status = "❌ Download failed [\(slug)]: \(error.localizedDescription)"
            }
            if self.activePack?.slug == slug { self.activePack = nil }
            self.downloadTaskBySlug[slug] = nil
        }
    }
}
