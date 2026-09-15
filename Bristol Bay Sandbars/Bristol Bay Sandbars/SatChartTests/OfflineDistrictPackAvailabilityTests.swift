import XCTest
@testable import SatChart

@MainActor
final class OfflineDistrictPackAvailabilityTests: XCTestCase {
    nonisolated final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var available: Set<String> = []
        private var unavailable: Set<String> = []
        private var offline = false
        private var active = 0
        private(set) var peak = 0
        private(set) var requests: [URL] = []

        func set(_ filenames: Set<String>, unavailable: Set<String> = [], offline: Bool = false) {
            lock.lock(); defer { lock.unlock() }
            self.available = filenames; self.unavailable = unavailable; self.offline = offline
        }

        private func begin(_ url: URL) -> OfflineDistrictPackAvailability.ProbeResult {
            lock.lock(); defer { lock.unlock() }
            active += 1; peak = max(peak, active); requests.append(url)
            if offline || unavailable.contains(url.lastPathComponent) { return .unavailable }
            return available.contains(url.lastPathComponent) ? .present : .missing
        }

        private func end() { lock.lock(); active -= 1; lock.unlock() }

        func load(_ url: URL) async -> OfflineDistrictPackAvailability.ProbeResult {
            let result = begin(url)
            try? await Task.sleep(for: .milliseconds(1))
            end()
            return result
        }
    }

    private func defaults() -> UserDefaults {
        let name = "offline-district-discovery-\(UUID())"
        let result = UserDefaults(suiteName: name)!
        addTeardownBlock { result.removePersistentDomain(forName: name) }
        return result
    }

    private func finish(_ store: OfflineDistrictPackAvailability) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isRefreshing && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isRefreshing)
    }

    func testFirstLaunchHasNoGuessedCardsAndRequiresBothFiles() async throws {
        let probe = Probe()
        probe.set(["togiak.mbtiles", "togiak.jpg", "togiak_v2.jpg", "togiak_v3.mbtiles",
                   "egegik_v15.mbtiles", "egegik_v15.png"])
        let store = OfflineDistrictPackAvailability(defaults: defaults(), probe: { await probe.load($0) })
        XCTAssertTrue(store.packs.isEmpty)
        store.refreshIfNeeded(); store.refreshIfNeeded(force: true)
        try await finish(store)
        XCTAssertEqual(store.packs(for: .togiak).map(\.slug), ["togiak"])
        XCTAssertEqual(store.packs(for: .egegik).map(\.slug), ["egegik_v15"])
        XCTAssertEqual(store.packs.count, 2)
        XCTAssertEqual(probe.peak, 2)
        XCTAssertLessThan(probe.requests.count, 250)
        XCTAssertTrue(probe.requests.allSatisfy {
            $0.host == "pub-832b588ef9ec4a588045736b6ce409b9.r2.dev" && !$0.path.contains("_xyz")
        })
        let count = probe.requests.count
        store.refreshIfNeeded()
        XCTAssertEqual(probe.requests.count, count)
        XCTAssertFalse(store.isRefreshing)
    }

    func testAllDistrictsResolveAliasesAndRetainCanonicalInstalledIdentity() async throws {
        let probe = Probe()
        probe.set(["togiak_v1.mbtiles", "togiak_v1.jpg", "naknek_v4.mbtiles", "naknek_v4.jpeg",
                   "egegik-v7.mbtiles", "egegik-v7.png", "ugashik_v6.mbtiles", "ugashik_v6.jpg",
                   "nushagak_v15.mbtiles", "nushagak_v15.jpg"])
        let store = OfflineDistrictPackAvailability(defaults: defaults(), probe: { await probe.load($0) })
        store.refreshIfNeeded(); try await finish(store)
        XCTAssertEqual(Set(store.packs.map(\.slug)), ["togiak", "naknek_kvichak_v4", "egegik_v7", "ugashik_v6", "nushagak_v15"])
        let naknek = try XCTUnwrap(store.packs(for: .naknek_kvichak).first)
        XCTAssertEqual(store.mbtilesURLs(for: naknek).first?.lastPathComponent, "naknek_v4.mbtiles")
        XCTAssertEqual(store.previewURLs(for: naknek).first?.lastPathComponent, "naknek_v4.jpeg")
        let togiak = try XCTUnwrap(store.packs(for: .togiak).first)
        XCTAssertEqual(store.mbtilesURLs(for: togiak).first?.lastPathComponent, "togiak_v1.mbtiles")
        XCTAssertTrue(DistrictID.naknek_kvichak.defaultPack.remoteBasenameCandidates.contains("naknek_v1"))
    }

    func testVerifiedCacheSurvivesOfflineButConfirmedMissingPreviewRemovesCard() async throws {
        let preferences = defaults(); let probe = Probe()
        probe.set(["togiak.mbtiles", "togiak.jpg", "naknek_v4.mbtiles", "naknek_v4.jpg"])
        let store = OfflineDistrictPackAvailability(defaults: preferences, probe: { await probe.load($0) })
        store.refreshIfNeeded(); try await finish(store)
        let restored = OfflineDistrictPackAvailability(defaults: preferences, probe: { await probe.load($0) })
        XCTAssertEqual(restored.packs, store.packs)
        let naknek = try XCTUnwrap(restored.packs(for: .naknek_kvichak).first)
        XCTAssertEqual(restored.mbtilesURLs(for: naknek).first?.lastPathComponent, "naknek_v4.mbtiles")
        probe.set([], offline: true)
        restored.refreshIfNeeded(force: true); try await finish(restored)
        XCTAssertTrue(restored.discoveryUnavailable)
        XCTAssertEqual(restored.packs, store.packs)
        probe.set(["togiak.mbtiles", "naknek_v4.mbtiles", "naknek_v4.jpg"])
        restored.refreshIfNeeded(force: true); try await finish(restored)
        XCTAssertFalse(restored.discoveryUnavailable)
        XCTAssertEqual(restored.packs.map(\.slug), ["naknek_kvichak_v4"])
        XCTAssertEqual(OfflineDistrictPackAvailability(defaults: preferences).packs, restored.packs)
    }

    func testTransientErrorOnOneAliasDoesNotRemoveKnownPack() async throws {
        let probe = Probe()
        probe.set(["togiak.mbtiles", "togiak.jpg"])
        let store = OfflineDistrictPackAvailability(defaults: defaults(), probe: { await probe.load($0) })
        store.refreshIfNeeded(); try await finish(store)
        probe.set(["togiak.mbtiles"], unavailable: ["togiak.jpg"])
        store.refreshIfNeeded(force: true); try await finish(store)
        XCTAssertEqual(store.packs.map(\.slug), ["togiak"])
        XCTAssertTrue(store.discoveryUnavailable)
    }

    func testCancelledDiscoveryCannotPublishLateResultsAndCanRestart() async throws {
        let probe = Probe(); probe.set(["togiak.mbtiles", "togiak.jpg"])
        let store = OfflineDistrictPackAvailability(defaults: defaults(), probe: { await probe.load($0) })
        store.refreshIfNeeded(); store.cancelRefresh()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(store.packs.isEmpty)
        XCTAssertFalse(store.isRefreshing)
        store.refreshIfNeeded(force: true); try await finish(store)
        XCTAssertEqual(store.packs.map(\.slug), ["togiak"])
    }

    func testBudgetLimitedScansResumeAcrossDistrictsAndVersions() async throws {
        let probe = Probe()
        probe.set(["togiak.mbtiles", "togiak.jpg", "ugashik_v15.mbtiles", "ugashik_v15.jpg"])
        let store = OfflineDistrictPackAvailability(defaults: defaults(), scanDuration: 0.015, probe: { await probe.load($0) })
        for _ in 0..<40 {
            await store.refresh(force: true)
            if store.packs.contains(where: { $0.slug == "ugashik_v15" }) { break }
        }
        XCTAssertEqual(Set(store.packs.map(\.slug)), ["togiak", "ugashik_v15"],
                       "Repeated short budgets must reach later districts and versions despite the cached first pack")
        XCTAssertTrue(probe.requests.contains { $0.lastPathComponent == "ugashik_v15.mbtiles" })
        XCTAssertLessThanOrEqual(probe.peak, 2)
    }

    func testHeadClassificationRejectsErrorPagesAndRetainsNetworkUncertainty() {
        for (filename, code, mime, length, expected) in [
            ("togiak.mbtiles", 200, "application/octet-stream", "100", "present"),
            ("togiak.mbtiles", 200, "text/html", "100", "unavailable"),
            ("togiak.jpg", 200, "image/jpeg", "100", "present"),
            ("togiak.png", 200, "image/png", "100", "present"),
            ("togiak.jpg", 200, "image/jpeg", "0", "unavailable"),
            ("togiak.jpg", 200, "text/html", "100", "unavailable"),
            ("togiak.jpg", 403, "text/plain", "12", "unavailable"),
            ("togiak.jpg", 429, "text/plain", "12", "unavailable"),
            ("togiak.jpg", 500, "text/plain", "12", "unavailable"),
            ("togiak.jpg", 404, "text/plain", "12", "missing"),
            ("togiak.jpg", 410, "text/plain", "12", "missing")
        ] {
            let url = OfflineDistrictPackAvailability.baseURL.appendingPathComponent(filename)
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil,
                                           headerFields: ["Content-Type": mime, "Content-Length": length])!
            XCTAssertEqual(String(describing: OfflineDistrictPackAvailability.classify(response, for: url)), expected)
        }
    }
}
