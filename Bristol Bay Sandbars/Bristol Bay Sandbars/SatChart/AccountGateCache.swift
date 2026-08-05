import Foundation
import FirebaseAuth

extension User: FirebaseAccountGateUser {
    var emailVerified: Bool { isEmailVerified }
}

final class AccountGateCache {
    static let shared = AccountGateCache()

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func save(snapshot: AccountGateSnapshot) {
        do {
            let url = try snapshotURL()
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            log("saved updated snapshot")
        } catch {
            log("failed to save snapshot: \(error.localizedDescription)")
        }
    }

    func load() -> AccountGateSnapshot? {
        do {
            let url = try snapshotURL(createDirectory: false)
            guard fileManager.fileExists(atPath: url.path) else {
                log("no snapshot")
                return nil
            }

            let data = try Data(contentsOf: url)
            let snapshot = try decoder.decode(AccountGateSnapshot.self, from: data)
            log("loaded snapshot for uid \(redactedUid(snapshot.uid))")
            return snapshot
        } catch {
            log("no usable snapshot: \(error.localizedDescription)")
            return nil
        }
    }

    func clear() {
        do {
            let url = try snapshotURL(createDirectory: false)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            log("cleared on sign out")
        } catch {
            log("failed to clear snapshot: \(error.localizedDescription)")
        }
    }

    func isSnapshotUsable(_ snapshot: AccountGateSnapshot?, currentUser: User?) -> Bool {
        guard let snapshot else {
            log("no snapshot")
            return false
        }

        guard let currentUser else {
            log("snapshot ignored because there is no Firebase currentUser")
            return false
        }

        guard snapshot.isForCurrentUser(uid: currentUser.uid) else {
            log("snapshot uid mismatch")
            return false
        }

        let usable = snapshot.canOpenOfflineForCurrentUser(uid: currentUser.uid)
        log("snapshot usable for offline gate: \(usable ? "yes" : "no")")
        return usable
    }

    func updateFromFirestoreProfile(_ profile: SatChartUserProfile, user: User) {
        let snapshot = AccountGateSnapshot(user: user, profile: profile, existing: load())
        save(snapshot: snapshot)
    }

    func updateFromUserProfile(_ profile: UserProfile) {
        let snapshot = AccountGateSnapshot(userProfile: profile, existing: load())
        save(snapshot: snapshot)
    }

    private func snapshotURL(createDirectory: Bool = true) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createDirectory
        )
        let directory = appSupport.appendingPathComponent("SatChart", isDirectory: true)
        if createDirectory {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try excludeFromBackup(url: directory)
        }
        return directory.appendingPathComponent("account_gate_snapshot.json")
    }

    private func excludeFromBackup(url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private func redactedUid(_ uid: String) -> String {
        guard uid.count > 6 else { return "..." }
        return "\(uid.prefix(3))...\(uid.suffix(3))"
    }

    private func log(_ message: String) {
        #if DEBUG
        print("AccountGateCache: \(message)")
        #endif
    }
}
