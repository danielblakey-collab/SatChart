import Foundation
import Combine
import os

nonisolated struct InstalledMBTilesRecord: Sendable {
    let slug: String
    let url: URL
    let byteCount: Int64
    let fileModificationTime: TimeInterval?
    let versionIdentity: String
    let minimumZoom: Int?
    let maximumZoom: Int?
    let storageScheme: MBTilesStorageScheme
    let tileWidth: Int
    let tileHeight: Int
    let bounds: [Double]?
    let isImmutableVersion: Bool
    let hasAuthoritativeSHA256: Bool

    nonisolated init(slug: String, url: URL, byteCount: Int64, fileModificationTime: TimeInterval?, versionIdentity: String, minimumZoom: Int?, maximumZoom: Int?, storageScheme: MBTilesStorageScheme, tileWidth: Int, tileHeight: Int, bounds: [Double]?, isImmutableVersion: Bool, hasAuthoritativeSHA256: Bool) {
        self.slug = slug
        self.url = url
        self.byteCount = byteCount
        self.fileModificationTime = fileModificationTime
        self.versionIdentity = versionIdentity
        self.minimumZoom = minimumZoom
        self.maximumZoom = maximumZoom
        self.storageScheme = storageScheme
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.bounds = bounds
        self.isImmutableVersion = isImmutableVersion
        self.hasAuthoritativeSHA256 = hasAuthoritativeSHA256
    }
}

nonisolated enum OfflineMapStorage {
    nonisolated struct ActiveDescriptor: Codable {
        let formatVersion: Int
        let slug: String
        let versionDirectory: String
        let receipt: MBTilesValidationReceipt
        let authoritativeSHA256: Bool

        nonisolated init(formatVersion: Int, slug: String, versionDirectory: String, receipt: MBTilesValidationReceipt, authoritativeSHA256: Bool) {
            self.formatVersion = formatVersion
            self.slug = slug
            self.versionDirectory = versionDirectory
            self.receipt = receipt
            self.authoritativeSHA256 = authoritativeSHA256
        }
    }

    nonisolated(unsafe) private static let fileManager = FileManager.default
    private static let installLock = NSLock()
    nonisolated(unsafe) private static var destructiveMutationGeneration: UInt64 = 0
    private static let activationAuthorizationLock = NSLock()
    nonisolated(unsafe) private static var pendingActivationAuthorizations: Set<UUID> = []

    nonisolated static func rootURL() throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport.appendingPathComponent("OfflineMaps", isDirectory: true)
    }

    nonisolated static func legacyDirectoryURL() -> URL? {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MBTiles", isDirectory: true)
    }

    nonisolated static func discoverAndMigrateLegacy() throws -> [InstalledMBTilesRecord] {
        precondition(!Thread.isMainThread)
        let root = try rootURL()
        // Discovery reads active descriptors while delete/activation can replace or
        // remove them. Take one coherent snapshot, then release the mutation lock
        // before potentially expensive legacy validation/migration begins.
        installLock.lock()
        let discoverySnapshot: (records: [InstalledMBTilesRecord], generation: UInt64)
        do {
            try prepareDurableDirectory(root)
            try recoverInterruptedInstalls(in: root)
            discoverySnapshot = (
                try discoverVersioned(in: root),
                destructiveMutationGeneration
            )
            installLock.unlock()
        } catch {
            installLock.unlock()
            throw error
        }

        var records = discoverySnapshot.records
        let alreadyInstalled = Set(records.map(\.slug))
        if let legacy = legacyDirectoryURL(),
           let urls = try? fileManager.contentsOfDirectory(
               at: legacy,
               includingPropertiesForKeys: [.isRegularFileKey],
               options: [.skipsHiddenFiles]
           ) {
            for url in urls where url.pathExtension.lowercased() == "mbtiles" {
                let slug = url.deletingPathExtension().lastPathComponent
                guard !alreadyInstalled.contains(slug), !records.contains(where: { $0.slug == slug }) else { continue }
                do {
                    let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    guard hasInstallationHeadroom(for: fileSize) else {
                        records.append(try validatedLegacyRecord(url: url, slug: slug))
                        continue
                    }
                    let staged = try stageCopy(of: url, slug: slug)
                    let record = try validateAndActivate(
                        stagedFile: staged,
                        expectation: MBTilesValidationExpectation(packageIdentifier: slug, version: "legacy"),
                        authoritativeSHA256: false,
                        expectedStorageGeneration: discoverySnapshot.generation
                    )
                    records.append(record)
                } catch {
                    do {
                        // Low storage or a failed copy must not delete or hide a valid
                        // legacy download. It remains read-only and is retried next launch.
                        records.append(try validatedLegacyRecord(url: url, slug: slug))
                    } catch {
                        #if DEBUG
                        os_log(.error, log: log, "Legacy MBTiles migration rejected %{public}@: %{public}@", slug, error.localizedDescription)
                        #endif
                    }
                }
            }
        }
        return records.sorted { $0.slug < $1.slug }
    }

    nonisolated static func prepareDownloadedFile(from temporaryURL: URL, slug: String) throws -> URL {
        precondition(!Thread.isMainThread)
        let root = try rootURL()
        try prepareDurableDirectory(root)
        let stageDirectory = root.appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: stageDirectory, withIntermediateDirectories: true)
        let stagedFile = stageDirectory.appendingPathComponent("\(slug).part")
        do {
            try fileManager.moveItem(at: temporaryURL, to: stagedFile)
        } catch {
            try fileManager.copyItem(at: temporaryURL, to: stagedFile)
        }
        return stagedFile
    }

    nonisolated static func stageCopy(of source: URL, slug: String) throws -> URL {
        let root = try rootURL()
        let stageDirectory = root.appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: stageDirectory, withIntermediateDirectories: true)
        let stagedFile = stageDirectory.appendingPathComponent("\(slug).part")
        try fileManager.copyItem(at: source, to: stagedFile)
        return stagedFile
    }

    nonisolated static func hasInstallationHeadroom(for expectedBytes: Int64) -> Bool {
        guard expectedBytes > 0, let root = try? rootURL() else { return true }
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return true }
        let reserve: Int64 = 128 * 1_024 * 1_024
        return Int64(available) >= expectedBytes + reserve
    }

    /// Captures deletion state for a later serialized activation. If a delete wins
    /// the race before activation obtains `installLock`, the generation mismatch
    /// prevents the completed download from recreating the deleted package.
    nonisolated static func destructiveMutationSnapshot() -> UInt64 {
        installLock.lock()
        defer { installLock.unlock() }
        return destructiveMutationGeneration
    }

    /// Cancellation and active-descriptor publication share this independent lock.
    /// Whichever acquires it first becomes the linearized outcome: either Cancel
    /// revokes the operation, or the descriptor commit completes atomically.
    nonisolated static func authorizeActivation(_ operationID: UUID) {
        activationAuthorizationLock.lock()
        pendingActivationAuthorizations.insert(operationID)
        activationAuthorizationLock.unlock()
    }

    /// Returns true when a still-pending commit was successfully revoked. False
    /// means publication already won and its normal completion should be delivered.
    @discardableResult
    nonisolated static func cancelActivation(_ operationID: UUID) -> Bool {
        activationAuthorizationLock.lock()
        defer { activationAuthorizationLock.unlock() }
        return pendingActivationAuthorizations.remove(operationID) != nil
    }

    nonisolated static func finishActivationAuthorization(_ operationID: UUID) {
        activationAuthorizationLock.lock()
        pendingActivationAuthorizations.remove(operationID)
        activationAuthorizationLock.unlock()
    }

    nonisolated private static func validatedLegacyRecord(url: URL, slug: String) throws -> InstalledMBTilesRecord {
        let receipt = try MBTilesPackageValidator.validate(
            at: url,
            expectation: MBTilesValidationExpectation(packageIdentifier: slug, version: "legacy")
        )
        return InstalledMBTilesRecord(
            slug: slug,
            url: url,
            byteCount: receipt.byteCount,
            fileModificationTime: receipt.fileModificationTime,
            versionIdentity: "legacy-\(receipt.sha256.prefix(16))",
            minimumZoom: receipt.minimumZoom,
            maximumZoom: receipt.maximumZoom,
            storageScheme: receipt.scheme,
            tileWidth: receipt.tileWidth,
            tileHeight: receipt.tileHeight,
            bounds: receipt.bounds,
            isImmutableVersion: false,
            hasAuthoritativeSHA256: false
        )
    }

    nonisolated static func validateAndActivate(
        stagedFile: URL,
        expectation: MBTilesValidationExpectation,
        authoritativeSHA256: Bool,
        expectedStorageGeneration: UInt64? = nil,
        commitAuthorization: UUID? = nil
    ) throws -> InstalledMBTilesRecord {
        precondition(!Thread.isMainThread)
        installLock.lock()
        defer { installLock.unlock() }
        let stagingDirectory = stagedFile.deletingLastPathComponent()
        var newlyInstalledVersionDirectory: URL?
        do {
            if let expectedStorageGeneration,
               expectedStorageGeneration != destructiveMutationGeneration {
                throw CancellationError()
            }
            try Task.checkCancellation()
            let receipt = try MBTilesPackageValidator.validate(at: stagedFile, expectation: expectation)
            // Cancellation during hashing/SQLite validation must not publish the
            // staged package after the user has pressed Cancel or Delete.
            try Task.checkCancellation()
            let root = try rootURL()
            let packageRoot = root.appendingPathComponent(expectation.packageIdentifier, isDirectory: true)
            let versions = packageRoot.appendingPathComponent("versions", isDirectory: true)
            try prepareDurableDirectory(versions)

            let versionName = "\(sanitized(expectation.version))-\(receipt.sha256.prefix(16))"
            let versionDirectory = versions.appendingPathComponent(versionName, isDirectory: true)
            let mapInsideStage = stagingDirectory.appendingPathComponent("map.mbtiles")
            if stagedFile != mapInsideStage {
                try fileManager.moveItem(at: stagedFile, to: mapInsideStage)
            }
            let receiptData = try encoded(receipt)
            let receiptURL = stagingDirectory.appendingPathComponent("validation.json")
            try receiptData.write(to: receiptURL, options: [.atomic])
            try protectOfflineContent(at: stagingDirectory)
            try protectOfflineContent(at: mapInsideStage)
            try protectOfflineContent(at: receiptURL)

            if fileManager.fileExists(atPath: versionDirectory.path) {
                let existingReceiptURL = versionDirectory.appendingPathComponent("validation.json")
                let existingMapURL = versionDirectory.appendingPathComponent("map.mbtiles")
                guard let existingData = try? Data(contentsOf: existingReceiptURL),
                      let existingReceipt = try? decoder().decode(MBTilesValidationReceipt.self, from: existingData),
                      existingReceipt.packageIdentifier == receipt.packageIdentifier,
                      existingReceipt.version == receipt.version,
                      existingReceipt.byteCount == receipt.byteCount,
                      existingReceipt.sha256 == receipt.sha256,
                      quickReceiptCheck(
                        InstalledMBTilesRecord(
                            slug: expectation.packageIdentifier,
                            url: existingMapURL,
                            byteCount: existingReceipt.byteCount,
                            fileModificationTime: existingReceipt.fileModificationTime,
                            versionIdentity: versionName,
                            minimumZoom: existingReceipt.minimumZoom,
                            maximumZoom: existingReceipt.maximumZoom,
                            storageScheme: existingReceipt.scheme,
                            tileWidth: existingReceipt.tileWidth,
                            tileHeight: existingReceipt.tileHeight,
                            bounds: existingReceipt.bounds,
                            isImmutableVersion: true,
                            hasAuthoritativeSHA256: authoritativeSHA256
                        )
                      ) else {
                    throw MBTilesValidationError.checksumMismatch
                }
                try fileManager.removeItem(at: stagingDirectory)
            } else {
                try fileManager.moveItem(at: stagingDirectory, to: versionDirectory)
                newlyInstalledVersionDirectory = versionDirectory
            }

            let descriptor = ActiveDescriptor(
                formatVersion: 1,
                slug: expectation.packageIdentifier,
                versionDirectory: versionName,
                receipt: receipt,
                authoritativeSHA256: authoritativeSHA256
            )
            try Task.checkCancellation()
            try prepareDurableDirectory(packageRoot)
            let activeURL = packageRoot.appendingPathComponent("active.json")
            try Task.checkCancellation()
            let descriptorData = try encoded(descriptor)
            if let commitAuthorization {
                activationAuthorizationLock.lock()
                guard pendingActivationAuthorizations.remove(commitAuthorization) != nil else {
                    activationAuthorizationLock.unlock()
                    throw CancellationError()
                }
                do {
                    try descriptorData.write(to: activeURL, options: [.atomic])
                    activationAuthorizationLock.unlock()
                } catch {
                    activationAuthorizationLock.unlock()
                    throw error
                }
            } else {
                try descriptorData.write(to: activeURL, options: [.atomic])
            }
            // Publication is the commit point. Protection metadata is best-effort
            // afterward so a metadata failure cannot leave active.json pointing at
            // a version that rollback just removed.
            try? protectOfflineContent(at: packageRoot)
            try? protectOfflineContent(at: activeURL)
            return record(from: descriptor, packageRoot: packageRoot)
        } catch {
            if let commitAuthorization {
                finishActivationAuthorization(commitAuthorization)
            }
            if fileManager.fileExists(atPath: stagingDirectory.path) {
                try? fileManager.removeItem(at: stagingDirectory)
            }
            if let newlyInstalledVersionDirectory,
               fileManager.fileExists(atPath: newlyInstalledVersionDirectory.path) {
                try? fileManager.removeItem(at: newlyInstalledVersionDirectory)
            }
            throw error
        }
    }

    nonisolated static func delete(slugs: Set<String>, urls: [URL]) throws {
        precondition(!Thread.isMainThread)
        installLock.lock()
        defer { installLock.unlock() }
        destructiveMutationGeneration &+= 1

        let root = try rootURL()
        var filesToInvalidate = Set(urls.map { $0.standardizedFileURL })
        let legacy = legacyDirectoryURL()
        for slug in slugs {
            let versions = root.appendingPathComponent(slug, isDirectory: true)
                .appendingPathComponent("versions", isDirectory: true)
            let versionDirectories = (try? fileManager.contentsOfDirectory(
                at: versions,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for directory in versionDirectories {
                let mapURL = directory.appendingPathComponent("map.mbtiles")
                if fileManager.fileExists(atPath: mapURL.path) {
                    filesToInvalidate.insert(mapURL.standardizedFileURL)
                }
            }
            if let legacy {
                let legacyURL = legacy.appendingPathComponent("\(slug).mbtiles")
                if fileManager.fileExists(atPath: legacyURL.path) {
                    filesToInvalidate.insert(legacyURL.standardizedFileURL)
                }
            }
        }

        // Exact teardown waits for every active and registry-retained generation to
        // close SQLite before any containing directory is removed.
        for url in filesToInvalidate {
            MBTilesPackageSessionRegistry.shared.invalidatePackage(at: url)
        }
        for slug in slugs {
            let packageRoot = root.appendingPathComponent(slug, isDirectory: true)
            if fileManager.fileExists(atPath: packageRoot.path) { try fileManager.removeItem(at: packageRoot) }
        }
        if let legacy {
            for slug in slugs {
                let legacyURL = legacy.appendingPathComponent("\(slug).mbtiles")
                if fileManager.fileExists(atPath: legacyURL.path) { try fileManager.removeItem(at: legacyURL) }
            }
        }
    }

    nonisolated private static func discoverVersioned(in root: URL) throws -> [InstalledMBTilesRecord] {
        let packageRoots = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var records: [InstalledMBTilesRecord] = []
        for packageRoot in packageRoots {
            let activeURL = packageRoot.appendingPathComponent("active.json")
            if let data = try? Data(contentsOf: activeURL),
               let decodedDescriptor = try? decoder().decode(ActiveDescriptor.self, from: data),
               decodedDescriptor.formatVersion == 1,
               descriptorIsSafe(decodedDescriptor, packageRoot: packageRoot) {
                let descriptor = descriptorAddingDerivedBoundsIfNeeded(
                    decodedDescriptor,
                    packageRoot: packageRoot
                )
                if (decodedDescriptor.receipt.bounds == nil
                        || decodedDescriptor.receipt.coverageEnvelopeVersion != 1),
                   descriptor.receipt.bounds != nil {
                    persistCoverageUpgrade(
                        descriptor,
                        packageRoot: packageRoot,
                        activeURL: activeURL
                    )
                }
                let record = record(from: descriptor, packageRoot: packageRoot)
                if quickReceiptCheck(record) { records.append(record); continue }
            }

            // A crash between moving a bundle and replacing active.json is recovered by
            // selecting the newest intact validation receipt; staged `.part` files never qualify.
            if let recovered = try recoverKnownGoodVersion(packageRoot: packageRoot) {
                try encoded(recovered.descriptor).write(to: activeURL, options: [.atomic])
                records.append(recovered.record)
            }
        }
        return records
    }

    nonisolated private static func recoverKnownGoodVersion(packageRoot: URL) throws -> (descriptor: ActiveDescriptor, record: InstalledMBTilesRecord)? {
        let versions = packageRoot.appendingPathComponent("versions", isDirectory: true)
        guard let directories = try? fileManager.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        var candidates: [(ActiveDescriptor, InstalledMBTilesRecord)] = []
        for directory in directories {
            let receiptURL = directory.appendingPathComponent("validation.json")
            guard let data = try? Data(contentsOf: receiptURL),
                  let decodedReceipt = try? decoder().decode(MBTilesValidationReceipt.self, from: data),
                  decodedReceipt.packageIdentifier == packageRoot.lastPathComponent else { continue }
            let decodedDescriptor = ActiveDescriptor(
                formatVersion: 1,
                slug: decodedReceipt.packageIdentifier,
                versionDirectory: directory.lastPathComponent,
                receipt: decodedReceipt,
                authoritativeSHA256: false
            )
            guard descriptorIsSafe(decodedDescriptor, packageRoot: packageRoot) else { continue }
            let descriptor = descriptorAddingDerivedBoundsIfNeeded(
                decodedDescriptor,
                packageRoot: packageRoot
            )
            if (decodedReceipt.bounds == nil
                    || decodedReceipt.coverageEnvelopeVersion != 1),
               descriptor.receipt.bounds != nil {
                if let receiptData = try? encoded(descriptor.receipt) {
                    try? receiptData.write(to: receiptURL, options: [.atomic])
                    try? protectOfflineContent(at: receiptURL)
                }
            }
            let record = record(from: descriptor, packageRoot: packageRoot)
            if quickReceiptCheck(record) { candidates.append((descriptor, record)) }
        }
        return candidates.max { $0.0.receipt.validatedAt < $1.0.receipt.validatedAt }.map { ($0.0, $0.1) }
    }

    /// Active descriptors are local trust boundaries: never let a malformed sidecar
    /// escape its package root or alias another package's slug during discovery.
    nonisolated private static func descriptorIsSafe(
        _ descriptor: ActiveDescriptor,
        packageRoot: URL
    ) -> Bool {
        let packageSlug = packageRoot.lastPathComponent
        let versionName = descriptor.versionDirectory
        guard !packageSlug.isEmpty,
              descriptor.slug == packageSlug,
              descriptor.receipt.packageIdentifier == packageSlug,
              !versionName.isEmpty,
              versionName != ".",
              versionName != "..",
              URL(fileURLWithPath: versionName).lastPathComponent == versionName else {
            return false
        }
        let versionsRoot = packageRoot.appendingPathComponent("versions", isDirectory: true)
            .standardizedFileURL
        let versionURL = versionsRoot.appendingPathComponent(versionName, isDirectory: true)
            .standardizedFileURL
        return versionURL.deletingLastPathComponent() == versionsRoot
    }

    /// Validation receipts created before coordinate-backed geographic coverage
    /// was recorded are upgraded once, off-main, without rehashing or mutating the
    /// immutable MBTiles payload. Persisting the upgraded sidecars avoids a large
    /// MIN/MAX scan on every subsequent launch.
    nonisolated private static func descriptorAddingDerivedBoundsIfNeeded(
        _ descriptor: ActiveDescriptor,
        packageRoot: URL
    ) -> ActiveDescriptor {
        guard descriptor.receipt.bounds == nil
                || descriptor.receipt.coverageEnvelopeVersion != 1 else {
            return descriptor
        }
        let mapURL = packageRoot.appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(descriptor.versionDirectory, isDirectory: true)
            .appendingPathComponent("map.mbtiles")
        guard let bounds = MBTilesPackageValidator.derivedBounds(
            at: mapURL,
            maximumZoom: descriptor.receipt.maximumZoom,
            scheme: descriptor.receipt.scheme
        ) else { return descriptor }

        let receipt = MBTilesValidationReceipt(
            packageIdentifier: descriptor.receipt.packageIdentifier,
            version: descriptor.receipt.version,
            filename: descriptor.receipt.filename,
            byteCount: descriptor.receipt.byteCount,
            fileModificationTime: descriptor.receipt.fileModificationTime,
            sha256: descriptor.receipt.sha256,
            bounds: bounds,
            minimumZoom: descriptor.receipt.minimumZoom,
            maximumZoom: descriptor.receipt.maximumZoom,
            scheme: descriptor.receipt.scheme,
            tileFormat: descriptor.receipt.tileFormat,
            tileWidth: descriptor.receipt.tileWidth,
            tileHeight: descriptor.receipt.tileHeight,
            tileCount: descriptor.receipt.tileCount,
            tileCountsByZoom: descriptor.receipt.tileCountsByZoom,
            queryPlan: descriptor.receipt.queryPlan,
            validatedAt: descriptor.receipt.validatedAt,
            coverageEnvelopeVersion: 1
        )
        return ActiveDescriptor(
            formatVersion: descriptor.formatVersion,
            slug: descriptor.slug,
            versionDirectory: descriptor.versionDirectory,
            receipt: receipt,
            authoritativeSHA256: descriptor.authoritativeSHA256
        )
    }

    nonisolated private static func persistCoverageUpgrade(
        _ descriptor: ActiveDescriptor,
        packageRoot: URL,
        activeURL: URL
    ) {
        let receiptURL = packageRoot.appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(descriptor.versionDirectory, isDirectory: true)
            .appendingPathComponent("validation.json")
        if let receiptData = try? encoded(descriptor.receipt) {
            try? receiptData.write(to: receiptURL, options: [.atomic])
            try? protectOfflineContent(at: receiptURL)
        }
        if let descriptorData = try? encoded(descriptor) {
            try? descriptorData.write(to: activeURL, options: [.atomic])
            try? protectOfflineContent(at: activeURL)
        }
    }

    nonisolated private static func quickReceiptCheck(_ record: InstalledMBTilesRecord) -> Bool {
        guard let values = try? record.url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]),
              values.isRegularFile == true,
              Int64(values.fileSize ?? -1) == record.byteCount,
              let handle = try? FileHandle(forReadingFrom: record.url) else { return false }
        if let expected = record.fileModificationTime,
           let actual = values.contentModificationDate?.timeIntervalSince1970,
           abs(expected - actual) > 0.001 {
            return false
        }
        defer { try? handle.close() }
        let header = try? handle.read(upToCount: 16)
        return header == Data("SQLite format 3\0".utf8)
    }

    nonisolated private static func record(from descriptor: ActiveDescriptor, packageRoot: URL) -> InstalledMBTilesRecord {
        let url = packageRoot.appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(descriptor.versionDirectory, isDirectory: true)
            .appendingPathComponent("map.mbtiles")
        let bounds = descriptor.receipt.bounds ?? MBTilesPackageValidator.derivedBounds(
            at: url,
            maximumZoom: descriptor.receipt.maximumZoom,
            scheme: descriptor.receipt.scheme
        )
        return InstalledMBTilesRecord(
            slug: descriptor.slug,
            url: url,
            byteCount: descriptor.receipt.byteCount,
            fileModificationTime: descriptor.receipt.fileModificationTime,
            versionIdentity: descriptor.versionDirectory,
            minimumZoom: descriptor.receipt.minimumZoom,
            maximumZoom: descriptor.receipt.maximumZoom,
            storageScheme: descriptor.receipt.scheme,
            tileWidth: descriptor.receipt.tileWidth,
            tileHeight: descriptor.receipt.tileHeight,
            bounds: bounds,
            isImmutableVersion: true,
            hasAuthoritativeSHA256: descriptor.authoritativeSHA256
        )
    }

    nonisolated private static func recoverInterruptedInstalls(in root: URL) throws {
        let stagingRoot = root.appendingPathComponent(".staging", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let staleBefore = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let stages = (try? fileManager.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        for stage in stages {
            let modified = try? stage.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, modified < staleBefore { try? fileManager.removeItem(at: stage) }
        }
    }

    nonisolated private static func prepareDurableDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try protectOfflineContent(at: url)
    }

    nonisolated private static func protectOfflineContent(at url: URL) throws {
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    nonisolated private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    nonisolated private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    nonisolated private static func sanitized(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        return String(scalars)
    }

    #if DEBUG
    private static let log = OSLog(subsystem: "com.curraghfisheries.SatChart", category: "OfflineMapInstall")
    #endif
}

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
        let configuration = URLSessionConfiguration.background(
            withIdentifier: "com.curraghfisheries.SatChart.offline-mbtiles"
        )
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private lazy var headSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private var recordsBySlug: [String: InstalledMBTilesRecord] = [:]
    private var downloadTaskBySlug: [String: URLSessionDownloadTask] = [:]
    private var preflightTaskBySlug: [String: Task<Void, Never>] = [:]
    private var sizeProbeTaskBySlug: [String: Task<Void, Never>] = [:]
    private var activationTaskBySlug: [String: Task<Void, Never>] = [:]
    private var activationGenerationBySlug: [String: UUID] = [:]
    private var downloadOperationBySlug: [String: UUID] = [:]
    private var resolvedRemoteURLBySlug: [String: URL] = [:]
    private var expectedSHA256BySlug: [String: String] = [:]
    private var expectedETagBySlug: [String: String] = [:]
    private var expectedVersionBySlug: [String: String] = [:]
    private var backgroundEventsCompletionHandler: (() -> Void)?
    private var backgroundSessionFinishedEvents = false
    private var inventoryRefreshGeneration: UInt64 = 0

    private override init() {
        super.init()
        refreshInstalledInventory(reportFailures: false)
        reconnectBackgroundDownloads()
    }

    private struct RemoteProbeResult: Sendable {
        let url: URL
        let sizeBytes: Int64?
        let sha256: String?
        let eTag: String?
        let version: String?
    }

    nonisolated private struct RemoteManifestEnvelope: Decodable, Sendable {
        let valid: Bool
        let package: RemoteManifestPackage
    }

    nonisolated private struct RemoteManifestPackage: Decodable, Sendable {
        let id: String
        let version: String
        let filename: String
        let byteCount: Int64
        let sha256: String
    }

    nonisolated private struct DownloadTaskContext: Codable, Sendable {
        let slug: String
        let expectedByteCount: Int64?
        let expectedSHA256: String?
        let expectedETag: String?
        let version: String
        let operationID: UUID?
    }

    func installedRecordsSnapshot() -> [InstalledMBTilesRecord] {
        Array(recordsBySlug.values)
    }

    func isImmutableInstalledURL(_ url: URL) -> Bool {
        recordsBySlug.values.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL })?.isImmutableVersion == true
    }

    func installedVersionIdentity(for url: URL) -> String? {
        recordsBySlug.values.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL })?.versionIdentity
    }

    func localMBTilesURL(for pack: OfflinePack) -> URL {
        firstExistingLocalMBTilesURL(for: pack)
            ?? URL(fileURLWithPath: "/dev/null")
    }

    func localMBTilesURL(forSlug slug: String) -> URL {
        recordsBySlug[slug]?.url
            ?? URL(fileURLWithPath: "/dev/null")
    }

    func localMBTilesURLs(for pack: OfflinePack) -> [URL] {
        pack.remoteBasenameCandidates.compactMap { recordsBySlug[$0]?.url }
    }

    func isDownloaded(_ pack: OfflinePack) -> Bool { firstExistingRecord(for: pack) != nil }
    func isDownloaded(slug: String) -> Bool { recordsBySlug[slug] != nil }
    func firstExistingLocalMBTilesURL(for pack: OfflinePack) -> URL? { firstExistingRecord(for: pack)?.url }
    func localFileSizeBytes(_ pack: OfflinePack) -> Int64? { firstExistingRecord(for: pack)?.byteCount }

    private func firstExistingRecord(for pack: OfflinePack) -> InstalledMBTilesRecord? {
        pack.remoteBasenameCandidates.compactMap { recordsBySlug[$0] }.first
    }

    func downloadedDistrictMapPacks(for district: DistrictID) -> [OfflinePack] {
        district.supportedLocalMapPacks
            .filter { isDownloaded($0) }
            .sorted { lhs, rhs in
                let lhsVersion = lhs.districtMapVersion ?? Int.max
                let rhsVersion = rhs.districtMapVersion ?? Int.max
                return lhsVersion == rhsVersion ? lhs.slug < rhs.slug : lhsVersion < rhsVersion
            }
    }

    func maximumDownloadedDistrictMapVersionCount() -> Int {
        max(1, DistrictID.allCases.map { downloadedDistrictMapPacks(for: $0).count }.max() ?? 1)
    }

    func selectedDownloadedDistrictMapPack(for district: DistrictID, selectedMapVersion: Int) -> OfflinePack? {
        let packs = downloadedDistrictMapPacks(for: district)
        guard !packs.isEmpty else { return nil }
        return packs[(max(1, selectedMapVersion) - 1) % packs.count]
    }

    func preferredLocalDistrictMBTilesSlug(for district: DistrictID, selectedMapVersion: Int) -> String? {
        selectedDownloadedDistrictMapPack(for: district, selectedMapVersion: selectedMapVersion)?.slug
    }

    func preferredLocalDistrictMBTilesURL(for district: DistrictID, selectedMapVersion: Int) -> URL? {
        guard let pack = selectedDownloadedDistrictMapPack(for: district, selectedMapVersion: selectedMapVersion) else { return nil }
        return firstExistingLocalMBTilesURL(for: pack)
    }

    func localOverlayCandidatePacks() -> [OfflinePack] {
        var result: [OfflinePack] = []
        var seen: Set<String> = []
        func append(_ pack: OfflinePack) { if seen.insert(pack.slug).inserted { result.append(pack) } }
        for district in DistrictID.allCases {
            district.packs.forEach(append)
            downloadedDistrictMapPacks(for: district).forEach(append)
        }
        OfflinePack.shorelinePacks.forEach(append)
        return result
    }

    func delete(_ pack: OfflinePack) {
        cancel(pack)
        let slugs = Set(pack.remoteBasenameCandidates)
        // Delete is stronger than Cancel: even if descriptor publication just won,
        // prevent its delayed actor callback from republishing a record after the
        // package root has been removed.
        for slug in slugs {
            if let operationID = downloadOperationBySlug.removeValue(forKey: slug) {
                _ = OfflineMapStorage.cancelActivation(operationID)
            }
            activationTaskBySlug.removeValue(forKey: slug)?.cancel()
            activationGenerationBySlug.removeValue(forKey: slug)
            downloadTaskBySlug.removeValue(forKey: slug)?.cancel()
            preflightTaskBySlug.removeValue(forKey: slug)?.cancel()
        }
        completeBackgroundEventsIfReady()
        let urls = slugs.compactMap { recordsBySlug[$0]?.url }
        Task.detached(priority: .utility) { [weak self] in
            do {
                try OfflineMapStorage.delete(slugs: slugs, urls: urls)
                await self?.refreshInstalledInventoryAfterMutation(message: "Deleted \(pack.slug)")
            } catch {
                await self?.setFailure("Delete failed: \(error.localizedDescription)")
            }
        }
    }

    func cancel(_ pack: OfflinePack) {
        let slug = pack.slug
        if activationTaskBySlug[slug] != nil,
           let operationID = downloadOperationBySlug[slug],
           !OfflineMapStorage.cancelActivation(operationID) {
            // The durable descriptor commit already linearized ahead of Cancel.
            // Let the success callback publish the now-active package instead of
            // reporting a cancellation that would reappear on the next launch.
            status = "Finishing \(slug)…"
            return
        }
        downloadTaskBySlug.removeValue(forKey: slug)?.cancel()
        preflightTaskBySlug.removeValue(forKey: slug)?.cancel()
        sizeProbeTaskBySlug.removeValue(forKey: slug)?.cancel()
        activationTaskBySlug.removeValue(forKey: slug)?.cancel()
        activationGenerationBySlug.removeValue(forKey: slug)
        downloadOperationBySlug.removeValue(forKey: slug)
        clearRemoteProbeState(for: slug)
        isDownloading[slug] = false
        progress[slug] = 0
        downloadedBytes[slug] = 0
        totalBytes[slug] = 0
        if activePack?.slug == slug { activePack = nil }
        status = "Cancelled \(slug)"
        completeBackgroundEventsIfReady()
    }

    func download(pack: OfflinePack, from remoteURL: URL) { download(pack: pack, fromCandidates: [remoteURL]) }

    func download(pack: OfflinePack, fromCandidates remoteURLs: [URL]) {
        let slug = pack.slug
        if let active = activePack, active.slug != slug, isDownloading[active.slug] == true {
            status = "Already downloading \(active.slug). Cancel it first."
            return
        }
        guard isDownloading[slug] != true, downloadTaskBySlug[slug] == nil, preflightTaskBySlug[slug] == nil else {
            status = "\(slug) is already downloading."
            return
        }

        // A new user-requested attempt always performs a fresh conditional probe.
        // Reusing an old URL/ETag/hash can make every retry fail after the publisher
        // replaces a remote object in place.
        sizeProbeTaskBySlug.removeValue(forKey: slug)?.cancel()
        clearRemoteProbeState(for: slug)

        activePack = pack
        status = "Preparing \(slug)…"
        isDownloading[slug] = true
        progress[slug] = 0
        downloadedBytes[slug] = 0
        totalBytes[slug] = 0

        let operationID = UUID()
        downloadOperationBySlug[slug] = operationID

        let task = Task { [weak self] in
            guard let self else { return }
            let probe = await self.resolveRemoteMBTiles(forSlug: slug, candidateURLs: remoteURLs)
            guard !Task.isCancelled else { return }
            guard self.downloadOperationBySlug[slug] == operationID else { return }
            guard let probe else {
                self.finishDownloadState(slug: slug, message: "❌ Remote MBTiles not found for \(slug)")
                return
            }
            if let size = probe.sizeBytes {
                self.remoteBytes[slug] = size
                self.totalBytes[slug] = size
                let hasRoom = await Task.detached(priority: .utility) { OfflineMapStorage.hasInstallationHeadroom(for: size) }.value
                guard self.downloadOperationBySlug[slug] == operationID else { return }
                guard hasRoom else {
                    self.finishDownloadState(slug: slug, message: "❌ Not enough free storage to safely install \(slug)")
                    return
                }
            }
            self.resolvedRemoteURLBySlug[slug] = probe.url
            if let sha256 = probe.sha256 { self.expectedSHA256BySlug[slug] = sha256 }
            if let eTag = probe.eTag { self.expectedETagBySlug[slug] = eTag }
            if let version = probe.version { self.expectedVersionBySlug[slug] = version }
            self.preflightTaskBySlug[slug] = nil
            self.startDownload(pack: pack, from: probe.url, operationID: operationID)
        }
        preflightTaskBySlug[slug] = task
    }

    private func startDownload(pack: OfflinePack, from remoteURL: URL, operationID: UUID) {
        let slug = pack.slug
        guard isDownloading[slug] == true,
              downloadOperationBySlug[slug] == operationID else { return }
        status = "Downloading \(slug)…"
        var request = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.timeoutInterval = 60
        let task = session.downloadTask(with: request)
        let context = DownloadTaskContext(
            slug: slug,
            expectedByteCount: remoteBytes[slug],
            expectedSHA256: expectedSHA256BySlug[slug],
            expectedETag: expectedETagBySlug[slug],
            version: expectedVersionBySlug[slug] ?? slug,
            operationID: operationID
        )
        task.taskDescription = Self.encodedTaskContext(context)
        downloadTaskBySlug[slug] = task
        task.resume()
    }

    func handleBackgroundURLSessionEvents(completionHandler: @escaping () -> Void) {
        backgroundEventsCompletionHandler = completionHandler
        _ = session
        completeBackgroundEventsIfReady()
    }

    private func reconnectBackgroundDownloads() {
        session.getAllTasks { tasks in
            Task { @MainActor in
                let manager = OfflineMapsManager.shared
                for case let task as URLSessionDownloadTask in tasks {
                    guard let context = Self.taskContext(from: task) else { continue }
                    let operationID = context.operationID ?? UUID()
                    if context.operationID == nil {
                        task.taskDescription = Self.encodedTaskContext(DownloadTaskContext(
                            slug: context.slug,
                            expectedByteCount: context.expectedByteCount,
                            expectedSHA256: context.expectedSHA256,
                            expectedETag: context.expectedETag,
                            version: context.version,
                            operationID: operationID
                        ))
                    }
                    manager.downloadTaskBySlug[context.slug] = task
                    manager.downloadOperationBySlug[context.slug] = operationID
                    manager.isDownloading[context.slug] = task.state == .running || task.state == .suspended
                    manager.status = "Resuming \(context.slug)…"
                }
            }
        }
    }

    nonisolated private static func encodedTaskContext(_ context: DownloadTaskContext) -> String {
        guard let data = try? JSONEncoder().encode(context) else { return context.slug }
        return data.base64EncodedString()
    }

    nonisolated private static func taskContext(from task: URLSessionTask) -> DownloadTaskContext? {
        guard let description = task.taskDescription else { return nil }
        if let data = Data(base64Encoded: description),
           let context = try? JSONDecoder().decode(DownloadTaskContext.self, from: data) {
            return context
        }
        return DownloadTaskContext(
            slug: description,
            expectedByteCount: nil,
            expectedSHA256: nil,
            expectedETag: nil,
            version: description,
            operationID: nil
        )
    }

    func fetchRemoteSizeIfNeeded(pack: OfflinePack, url: URL) { fetchRemoteSizeIfNeeded(pack: pack, urls: [url]) }

    func fetchRemoteSizeIfNeeded(pack: OfflinePack, urls: [URL]) {
        let slug = pack.slug
        guard remoteBytes[slug] == nil, sizeProbeTaskBySlug[slug] == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            let probe = await self.resolveRemoteMBTiles(forSlug: slug, candidateURLs: urls)
            guard !Task.isCancelled else { return }
            if let probe {
                self.resolvedRemoteURLBySlug[slug] = probe.url
                if let size = probe.sizeBytes { self.remoteBytes[slug] = size }
                if let sha256 = probe.sha256 { self.expectedSHA256BySlug[slug] = sha256 }
                if let eTag = probe.eTag { self.expectedETagBySlug[slug] = eTag }
                if let version = probe.version { self.expectedVersionBySlug[slug] = version }
            }
            self.sizeProbeTaskBySlug[slug] = nil
        }
        sizeProbeTaskBySlug[slug] = task
    }

    private func resolveRemoteMBTiles(forSlug slug: String, candidateURLs: [URL]) async -> RemoteProbeResult? {
        if let cached = resolvedRemoteURLBySlug[slug] {
            return RemoteProbeResult(url: cached, sizeBytes: remoteBytes[slug], sha256: expectedSHA256BySlug[slug], eTag: expectedETagBySlug[slug], version: expectedVersionBySlug[slug])
        }
        var seen: Set<String> = []
        for url in candidateURLs where seen.insert(url.absoluteString).inserted {
            if Task.isCancelled { return nil }
            if let probe = await probeRemoteMBTiles(at: url, expectedSlug: slug) { return probe }
        }
        return nil
    }

    private func probeRemoteMBTiles(at url: URL, expectedSlug: String) async -> RemoteProbeResult? {
        let manifest = await remoteManifest(for: url, expectedSlug: expectedSlug)
        var head = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 12)
        head.httpMethod = "HEAD"
        do {
            let (_, response) = try await headSession.data(for: head)
            if let http = response as? HTTPURLResponse,
               (200...299).contains(http.statusCode),
               !contentTypeLooksLikeErrorDocument(http) {
                let headerBytes = totalSizeBytes(from: http)
                if let manifest, let headerBytes, headerBytes != manifest.byteCount { return nil }
                return RemoteProbeResult(
                    url: url,
                    sizeBytes: manifest?.byteCount ?? headerBytes,
                    sha256: manifest?.sha256.lowercased() ?? trustedSHA256(from: http),
                    eTag: http.value(forHTTPHeaderField: "ETag"),
                    version: manifest?.version
                )
            }
        } catch {}

        var range = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        range.httpMethod = "GET"
        range.setValue("bytes=0-15", forHTTPHeaderField: "Range")
        do {
            let (data, response) = try await headSession.data(for: range)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 206,
                  data.prefix(16) == Data("SQLite format 3\0".utf8) else { return nil }
            let headerBytes = totalSizeBytes(from: http)
            if let manifest, let headerBytes, headerBytes != manifest.byteCount { return nil }
            return RemoteProbeResult(
                url: url,
                sizeBytes: manifest?.byteCount ?? headerBytes,
                sha256: manifest?.sha256.lowercased() ?? trustedSHA256(from: http),
                eTag: http.value(forHTTPHeaderField: "ETag"),
                version: manifest?.version
            )
        } catch { return nil }
    }

    private func remoteManifest(for mbtilesURL: URL, expectedSlug: String) async -> RemoteManifestPackage? {
        let manifestURL = mbtilesURL.deletingPathExtension().appendingPathExtension("manifest.json")
        var request = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await headSession.data(for: request),
              data.count <= 256 * 1_024,
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let envelope = try? JSONDecoder().decode(RemoteManifestEnvelope.self, from: data),
              envelope.valid,
              envelope.package.filename == mbtilesURL.lastPathComponent,
              envelope.package.byteCount > 0,
              envelope.package.sha256.count == 64,
              envelope.package.sha256.allSatisfy({ $0.isHexDigit }),
              Self.compatibleRemoteIdentity(expectedSlug, envelope.package.id) else { return nil }
        return envelope.package
    }

    nonisolated private static func compatibleRemoteIdentity(_ expected: String, _ actual: String) -> Bool {
        MBTilesPackageValidator.normalizedPackageIdentity(expected)
            == MBTilesPackageValidator.normalizedPackageIdentity(actual)
    }

    private func trustedSHA256(from response: HTTPURLResponse) -> String? {
        for name in ["x-amz-meta-sha256", "x-satchart-sha256", "Digest"] {
            guard var value = response.value(forHTTPHeaderField: name)?.lowercased() else { continue }
            value = value.replacingOccurrences(of: "sha-256=", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if value.count == 64, value.allSatisfy({ $0.isHexDigit }) { return value }
        }
        return nil
    }

    private func contentTypeLooksLikeErrorDocument(_ response: HTTPURLResponse) -> Bool {
        let value = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        return value.contains("text/html") || value.contains("xml") || value.contains("json") || value.hasPrefix("text/")
    }

    private func totalSizeBytes(from response: HTTPURLResponse) -> Int64? {
        if let range = response.value(forHTTPHeaderField: "Content-Range"), let value = range.split(separator: "/").last, let total = Int64(value) { return total }
        if let length = response.value(forHTTPHeaderField: "Content-Length"), let total = Int64(length) { return total }
        return nil
    }

    private func refreshInstalledInventory(reportFailures: Bool) {
        inventoryRefreshGeneration &+= 1
        let refreshGeneration = inventoryRefreshGeneration
        Task.detached(priority: .utility) { [weak self] in
            do {
                let records = try OfflineMapStorage.discoverAndMigrateLegacy()
                await self?.acceptInventory(records, refreshGeneration: refreshGeneration)
            } catch {
                if reportFailures {
                    await self?.setInventoryFailure(
                        "Offline map recovery failed: \(error.localizedDescription)",
                        refreshGeneration: refreshGeneration
                    )
                }
            }
        }
    }

    private func acceptInventory(
        _ records: [InstalledMBTilesRecord],
        refreshGeneration: UInt64
    ) {
        guard refreshGeneration == inventoryRefreshGeneration else { return }
        // Discovery rejects malformed aliases, but reduce defensively so a damaged
        // on-device sidecar can never trap the app during launch.
        recordsBySlug = records.reduce(into: [:]) { result, record in
            if let current = result[record.slug] {
                if record.versionIdentity > current.versionIdentity {
                    result[record.slug] = record
                }
            } else {
                result[record.slug] = record
            }
        }
        downloadedTick &+= 1
    }

    private func setInventoryFailure(_ message: String, refreshGeneration: UInt64) {
        guard refreshGeneration == inventoryRefreshGeneration else { return }
        setFailure(message)
    }

    private func refreshInstalledInventoryAfterMutation(message: String) {
        status = message
        refreshInstalledInventory(reportFailures: true)
    }

    private func setFailure(_ message: String) { status = "❌ \(message)" }

    private func clearRemoteProbeState(for slug: String) {
        resolvedRemoteURLBySlug[slug] = nil
        expectedSHA256BySlug[slug] = nil
        expectedETagBySlug[slug] = nil
        expectedVersionBySlug[slug] = nil
        remoteBytes[slug] = nil
    }

    private func completeBackgroundEventsIfReady() {
        guard backgroundSessionFinishedEvents,
              activationTaskBySlug.isEmpty,
              let completion = backgroundEventsCompletionHandler else { return }
        backgroundSessionFinishedEvents = false
        backgroundEventsCompletionHandler = nil
        completion()
    }

    private func finishDownloadState(slug: String, message: String) {
        isDownloading[slug] = false
        progress[slug] = 0
        downloadedBytes[slug] = 0
        totalBytes[slug] = 0
        if activePack?.slug == slug { activePack = nil }
        preflightTaskBySlug[slug] = nil
        downloadTaskBySlug[slug] = nil
        activationTaskBySlug[slug] = nil
        activationGenerationBySlug[slug] = nil
        downloadOperationBySlug[slug] = nil
        clearRemoteProbeState(for: slug)
        status = message
        completeBackgroundEventsIfReady()
    }
}

extension OfflineMapsManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let taskContext = Self.taskContext(from: downloadTask) else { return }
        let slug = taskContext.slug
        Task { @MainActor in
            guard let operationID = taskContext.operationID,
                  self.downloadOperationBySlug[slug] == operationID,
                  self.downloadTaskBySlug[slug] === downloadTask,
                  self.isDownloading[slug] == true else { return }
            self.downloadedBytes[slug] = totalBytesWritten
            self.totalBytes[slug] = max(totalBytesExpectedToWrite, 0)
            self.progress[slug] = totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : 0
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let taskContext = Self.taskContext(from: downloadTask) else { return }
        let slug = taskContext.slug
        // Capture deletion state before crossing back to the main actor. A later
        // delete increments this value, causing serialized activation to abort.
        let storageGeneration = OfflineMapStorage.destructiveMutationSnapshot()
        let response = downloadTask.response as? HTTPURLResponse
        guard let response, (200...299).contains(response.statusCode) else {
            Task { @MainActor in
                guard let operationID = taskContext.operationID,
                      self.downloadOperationBySlug[slug] == operationID,
                      self.downloadTaskBySlug[slug] === downloadTask else { return }
                self.finishDownloadState(
                    slug: slug,
                    message: "❌ Download returned an invalid HTTP response for \(slug)"
                )
            }
            return
        }

        let stagedFile: URL
        do { stagedFile = try OfflineMapStorage.prepareDownloadedFile(from: location, slug: slug) }
        catch {
            Task { @MainActor in
                guard let operationID = taskContext.operationID,
                      self.downloadOperationBySlug[slug] == operationID,
                      self.downloadTaskBySlug[slug] === downloadTask else { return }
                self.finishDownloadState(
                    slug: slug,
                    message: "❌ Could not stage \(slug): \(error.localizedDescription)"
                )
            }
            return
        }

        Task { @MainActor in
            guard let downloadOperation = taskContext.operationID,
                  self.downloadOperationBySlug[slug] == downloadOperation,
                  self.downloadTaskBySlug[slug] === downloadTask,
                  self.isDownloading[slug] == true else {
                Task.detached(priority: .utility) {
                    try? FileManager.default.removeItem(at: stagedFile.deletingLastPathComponent())
                }
                return
            }
            let expectedBytes = taskContext.expectedByteCount ?? (response.expectedContentLength > 0 ? response.expectedContentLength : nil)
            let expectedSHA = taskContext.expectedSHA256
            let expectedVersion = taskContext.version
            let expectedETag = taskContext.expectedETag
            let actualETag = response.value(forHTTPHeaderField: "ETag")
            guard expectedETag == nil || actualETag == expectedETag else {
                Task.detached(priority: .utility) {
                    try? FileManager.default.removeItem(at: stagedFile.deletingLastPathComponent())
                }
                self.finishDownloadState(slug: slug, message: "❌ The remote map changed during download; retry \(slug)")
                return
            }
            self.status = "Validating \(slug)…"
            self.activationTaskBySlug[slug]?.cancel()
            let activationGeneration = UUID()
            self.activationGenerationBySlug[slug] = activationGeneration
            OfflineMapStorage.authorizeActivation(downloadOperation)
            let activationTask = Task.detached(priority: .utility) { [weak self] in
                do {
                    try Task.checkCancellation()
                    let record = try OfflineMapStorage.validateAndActivate(
                        stagedFile: stagedFile,
                        expectation: MBTilesValidationExpectation(packageIdentifier: slug, version: expectedVersion, expectedByteCount: expectedBytes, expectedSHA256: expectedSHA),
                        authoritativeSHA256: expectedSHA != nil,
                        expectedStorageGeneration: storageGeneration,
                        commitAuthorization: downloadOperation
                    )
                    try Task.checkCancellation()
                    await self?.downloadActivated(
                        record,
                        activationGeneration: activationGeneration,
                        downloadOperation: downloadOperation
                    )
                } catch is CancellationError {
                    OfflineMapStorage.finishActivationAuthorization(downloadOperation)
                    try? FileManager.default.removeItem(at: stagedFile.deletingLastPathComponent())
                } catch {
                    OfflineMapStorage.finishActivationAuthorization(downloadOperation)
                    try? FileManager.default.removeItem(at: stagedFile.deletingLastPathComponent())
                    await self?.finishActivationFailure(
                        slug: slug,
                        activationGeneration: activationGeneration,
                        downloadOperation: downloadOperation,
                        message: "❌ Validation failed [\(slug)]: \(error.localizedDescription)"
                    )
                }
            }
            self.activationTaskBySlug[slug] = activationTask
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let taskContext = Self.taskContext(from: task), let error else { return }
        let slug = taskContext.slug
        Task { @MainActor in
            if (error as NSError).code != NSURLErrorCancelled,
               let operationID = taskContext.operationID,
               self.downloadOperationBySlug[slug] == operationID,
               self.downloadTaskBySlug[slug] === task {
                self.finishDownloadState(slug: slug, message: "❌ Download failed [\(slug)]: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundSessionFinishedEvents = true
            self.completeBackgroundEventsIfReady()
        }
    }

    private func downloadActivated(
        _ record: InstalledMBTilesRecord,
        activationGeneration: UUID,
        downloadOperation: UUID
    ) {
        guard activationGenerationBySlug[record.slug] == activationGeneration,
              downloadOperationBySlug[record.slug] == downloadOperation else { return }
        recordsBySlug[record.slug] = record
        isDownloading[record.slug] = false
        progress[record.slug] = 1
        status = "✅ Downloaded and validated \(record.slug)"
        downloadedTick &+= 1
        if activePack?.slug == record.slug { activePack = nil }
        downloadTaskBySlug[record.slug] = nil
        preflightTaskBySlug[record.slug] = nil
        activationTaskBySlug[record.slug] = nil
        activationGenerationBySlug[record.slug] = nil
        downloadOperationBySlug[record.slug] = nil
        clearRemoteProbeState(for: record.slug)
        completeBackgroundEventsIfReady()
    }

    private func finishActivationFailure(
        slug: String,
        activationGeneration: UUID,
        downloadOperation: UUID,
        message: String
    ) {
        guard activationGenerationBySlug[slug] == activationGeneration,
              downloadOperationBySlug[slug] == downloadOperation else { return }
        finishDownloadState(slug: slug, message: message)
    }
}
