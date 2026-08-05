import Foundation
import Combine
import CryptoKit
import Gzip

enum OfflineInstallError: LocalizedError {
    case bundledManifestMissing
    case bundledPackMissing(String)
    case noPackFound
    case invalidPackURL(String)
    case manifestHTTPStatus(Int)
    case manifestInvalid(Error)
    case offlineDataUnavailable(Error)
    case shaMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .bundledManifestMissing:
            return "The bundled SatChart offline data manifest is missing."
        case .bundledPackMissing(let path):
            return "The bundled SatChart offline data pack is missing: \(path)"
        case .noPackFound:
            return "No compatible SatChart offline data pack was found."
        case .invalidPackURL(let url):
            return "The offline data pack URL is invalid: \(url)"
        case .manifestHTTPStatus(let statusCode):
            return "SatChart could not download the offline data manifest. Server returned HTTP \(statusCode)."
        case .manifestInvalid(let error):
            return "SatChart could not read the offline data manifest: \(error.localizedDescription)"
        case .offlineDataUnavailable(let error):
            return "Offline data is not installed yet. Connect to the internet once to install required SatChart data. Last error: \(error.localizedDescription)"
        case .shaMismatch(let expected, let actual):
            return "Offline data verification failed. Expected SHA-256 \(expected), got \(actual)."
        }
    }
}

enum OfflineInstallerState: Equatable {
    case checkingLocalData
    case usingInstalledData
    case downloadingManifest
    case downloadingPack
    case verifying
    case installing
    case installed
    case offlineDataUnavailable(String)
    case updateCheckFailedButLocalDataUsable(String)

    var status: String {
        switch self {
        case .checkingLocalData:
            return "Checking local data..."
        case .usingInstalledData:
            return "Using installed offline data."
        case .downloadingManifest:
            return "Downloading manifest..."
        case .downloadingPack:
            return "Downloading offline pack..."
        case .verifying:
            return "Verifying..."
        case .installing:
            return "Installing..."
        case .installed:
            return "Done"
        case .offlineDataUnavailable:
            return "Offline data is not installed yet."
        case .updateCheckFailedButLocalDataUsable:
            return "Using installed offline data."
        }
    }

    var detail: String? {
        switch self {
        case .offlineDataUnavailable(let message),
             .updateCheckFailedButLocalDataUsable(let message):
            return message
        default:
            return nil
        }
    }

    var isBlockingUnavailable: Bool {
        if case .offlineDataUnavailable = self {
            return true
        }
        return false
    }
}

@MainActor
final class SatChartOfflinePackInstaller: ObservableObject {
    @Published private(set) var state: OfflineInstallerState = .checkingLocalData
    @Published private(set) var status: String = OfflineInstallerState.checkingLocalData.status
    @Published private(set) var progress: Double = 0 // 0..1

    private let baseURL = URL(string: "https://satchart-1e916.web.app")!

    // MARK: - Version Tracking

    private let installedVersionKey = "offlinePackInstalledVersion"
    private let installedPackIdKey = "offlinePackInstalledId"
    private let installedPackSha256Key = "offlinePackInstalledSha256"

    private func getInstalledVersion() -> Int {
        UserDefaults.standard.integer(forKey: installedVersionKey)
    }

    private func getInstalledPackId() -> String {
        UserDefaults.standard.string(forKey: installedPackIdKey) ?? ""
    }

    private func getInstalledSha256() -> String {
        UserDefaults.standard.string(forKey: installedPackSha256Key) ?? ""
    }

    private func setInstalledVersion(_ version: Int, packId: String, sha256: String) {
        UserDefaults.standard.set(version, forKey: installedVersionKey)
        UserDefaults.standard.set(packId, forKey: installedPackIdKey)
        UserDefaults.standard.set(sha256, forKey: installedPackSha256Key)
    }

    private func clearInstalledVersion() {
        UserDefaults.standard.removeObject(forKey: installedVersionKey)
        UserDefaults.standard.removeObject(forKey: installedPackIdKey)
        UserDefaults.standard.removeObject(forKey: installedPackSha256Key)
    }

    private func removeItemIfExists(at url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func setState(_ state: OfflineInstallerState, progress value: Double) {
        self.state = state
        progress = value
        status = state.status
    }

    private func markInstalled(version: Int, packId: String, sha256: String) {
        setInstalledVersion(version, packId: packId, sha256: sha256)
        setState(.installed, progress: 1.0)
    }

    // MARK: - Install Logic

    func installedDatabaseExists() throws -> Bool {
        let dbURL = try OfflinePaths.offlineSQLiteURL()
        return FileManager.default.fileExists(atPath: dbURL.path)
    }

    func discardInstalledData() throws {
        let sqliteURL = try OfflinePaths.offlineSQLiteURL()
        let gzipURL = try OfflinePaths.offlineGzipURL()
        let tempURL = try OfflinePaths.offlineTempSQLiteURL()
        #if DEBUG
        print("""
        🧹 Offline DB fallback cleanup
          sqlite: \(sqliteURL.path)
          gzip: \(gzipURL.path)
          temp: \(tempURL.path)
        """)
        #endif
        removeItemIfExists(at: sqliteURL)
        removeItemIfExists(at: gzipURL)
        removeItemIfExists(at: tempURL)
        clearInstalledVersion()
        setState(.checkingLocalData, progress: 0)
    }

    func installIfNeeded() async throws {
        setState(.checkingLocalData, progress: 0.02)

        if try installedDatabaseExists() {
            setState(.usingInstalledData, progress: 1.0)
            return
        }

        do {
            try installBundledPackIfAvailable()
            return
        } catch {
            #if DEBUG
            print("⚠️ Bundled offline pack install failed:", error.localizedDescription)
            #endif
        }

        do {
            try await installRemotePackIfNeeded(localDataExists: false)
        } catch {
            setState(.offlineDataUnavailable(OfflineInstallError.offlineDataUnavailable(error).localizedDescription), progress: 0)
            throw error
        }
    }

    func checkForUpdatesIfInstalled() async {
        guard (try? installedDatabaseExists()) == true else {
            return
        }

        do {
            try await installRemotePackIfNeeded(localDataExists: true)
        } catch {
            let message = "Update check failed, but installed offline data is usable. \(error.localizedDescription)"
            setState(.updateCheckFailedButLocalDataUsable(message), progress: 1.0)
        }
    }

    func markInstalledDataInUse() {
        setState(.usingInstalledData, progress: 1.0)
    }

    func markOfflineDataUnavailable(_ error: Error) {
        setState(.offlineDataUnavailable(OfflineInstallError.offlineDataUnavailable(error).localizedDescription), progress: 0)
    }

    private func installRemotePackIfNeeded(localDataExists: Bool) async throws {
        setState(.downloadingManifest, progress: 0.05)
        let pack = try await fetchPack()

        let installedVersion = getInstalledVersion()
        let installedPackId = getInstalledPackId()
        let installedSha256 = getInstalledSha256()
        let dbExists = try installedDatabaseExists()

        if dbExists,
           installedPackId == pack.id,
           installedVersion >= pack.version,
           installedSha256 == pack.sha256 {
            setState(.usingInstalledData, progress: 1.0)
            return
        }

        setState(.downloadingPack, progress: localDataExists ? 0.20 : 0.10)

        let gzURL = try OfflinePaths.offlineGzipURL()
        try await download(to: gzURL, pack: pack)

        setState(.verifying, progress: 0.75)
        let actualSha = try sha256Hex(of: gzURL)
        guard actualSha == pack.sha256 else {
            throw OfflineInstallError.shaMismatch(expected: pack.sha256, actual: actualSha)
        }

        setState(.installing, progress: 0.85)
        let tmpDB = try OfflinePaths.offlineTempSQLiteURL()
        removeItemIfExists(at: tmpDB)
        try gunzip(source: gzURL, destination: tmpDB)

        setState(.installing, progress: 0.95)
        let dbURL = try OfflinePaths.offlineSQLiteURL()
        removeItemIfExists(at: dbURL)
        try FileManager.default.moveItem(at: tmpDB, to: dbURL)

        removeItemIfExists(at: gzURL)
        markInstalled(version: pack.version, packId: pack.id, sha256: pack.sha256)
    }

    private func installBundledPackIfAvailable() throws {
        let manifest = try bundledManifest()
        let pack = try selectCompatiblePack(from: manifest)
        let sourceGzipURL = try bundledPackURL(for: pack)
        #if DEBUG
        print("""
        📦 Installing offline DB fallback from bundled gzip
          expected resource: public\(pack.url)
          bundled seed found: true
          destination: \(try OfflinePaths.offlineSQLiteURL().path)
        """)
        #endif

        setState(.verifying, progress: 0.25)
        let actualSha = try sha256Hex(of: sourceGzipURL)
        guard actualSha == pack.sha256 else {
            throw OfflineInstallError.shaMismatch(expected: pack.sha256, actual: actualSha)
        }

        setState(.installing, progress: 0.55)
        let tmpDB = try OfflinePaths.offlineTempSQLiteURL()
        removeItemIfExists(at: tmpDB)
        try gunzip(source: sourceGzipURL, destination: tmpDB)

        setState(.installing, progress: 0.90)
        let dbURL = try OfflinePaths.offlineSQLiteURL()
        removeItemIfExists(at: dbURL)
        try FileManager.default.moveItem(at: tmpDB, to: dbURL)

        markInstalled(version: pack.version, packId: pack.id, sha256: pack.sha256)
    }

    // MARK: - Networking

    private func fetchPack() async throws -> Pack {
        let manifestURL = baseURL.appendingPathComponent("manifest.json")
        let request = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw OfflineInstallError.manifestHTTPStatus(httpResponse.statusCode)
        }

        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw OfflineInstallError.manifestInvalid(error)
        }

        return try selectCompatiblePack(from: manifest)
    }

    private func selectCompatiblePack(from manifest: Manifest) throws -> Pack {
        let compatiblePacks = manifest.packs.filter { pack in
            pack.type == "all" && pack.format == "sqlite+gzip"
        }

        guard let pack = compatiblePacks.max(by: { lhs, rhs in
            if lhs.version != rhs.version {
                return lhs.version < rhs.version
            }
            return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }) else {
            throw OfflineInstallError.noPackFound
        }
        return pack
    }

    private func download(to destination: URL, pack: Pack) async throws {
        removeItemIfExists(at: destination)
        let remoteURL = try remotePackURL(pack.url)
        let request = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)

        let (tmpURL, _) = try await URLSession.shared.download(for: request)
        try FileManager.default.moveItem(at: tmpURL, to: destination)
    }

    private func remotePackURL(_ urlString: String) throws -> URL {
        if let absoluteURL = URL(string: urlString), absoluteURL.scheme != nil {
            return absoluteURL
        }

        guard let relativeURL = URL(string: urlString, relativeTo: baseURL)?.absoluteURL else {
            throw OfflineInstallError.invalidPackURL(urlString)
        }

        return relativeURL
    }

    private func bundledManifest() throws -> Manifest {
        guard let manifestURL = Bundle.main.url(
            forResource: "manifest",
            withExtension: "json",
            subdirectory: "public"
        ) else {
            throw OfflineInstallError.bundledManifestMissing
        }

        let data = try Data(contentsOf: manifestURL)
        do {
            return try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw OfflineInstallError.manifestInvalid(error)
        }
    }

    private func bundledPackURL(for pack: Pack) throws -> URL {
        let normalizedPath = pack.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathComponents = normalizedPath.split(separator: "/").map(String.init)
        let fileName = pathComponents.last ?? "offline.sqlite.gz"
        let subdirectory = (["public"] + pathComponents.dropLast()).joined(separator: "/")

        guard let bundledURL = Bundle.main.url(
            forResource: fileName,
            withExtension: nil,
            subdirectory: subdirectory
        ) else {
            throw OfflineInstallError.bundledPackMissing("public/\(normalizedPath)")
        }

        return bundledURL
    }

    // MARK: - Utilities

    private func sha256Hex(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func gunzip(source: URL, destination: URL) throws {
        let compressed = try Data(contentsOf: source)
        let decompressed = try compressed.gunzipped()
        try decompressed.write(to: destination, options: .atomic)
    }
}
