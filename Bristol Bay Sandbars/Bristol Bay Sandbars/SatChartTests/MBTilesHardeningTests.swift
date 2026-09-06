import Testing
import Foundation
import MapKit
import SQLite3
import CoreGraphics
import ImageIO
import CoreImage
import UIKit
import XCTest
@testable import SatChart

@Suite(.serialized)
struct MBTilesHardeningTests {
    // VectorKit's simulator renderer can tear down asynchronously after an
    // MKMapView deinit. Keep the two lightweight delegate-test views alive for
    // the test process so Thread Sanitizer observes SatChart work rather than
    // crashing in VectorKit's resource destructor between test cases.
    @MainActor private static var retainedMapViews: [MKMapView] = []

    @MainActor
    private final class OpacitySpy: MapRendererOpacityTarget {
        var alpha: CGFloat

        init(alpha: CGFloat) {
            self.alpha = alpha
        }

        var mapRendererAlpha: CGFloat {
            get { alpha }
            set { alpha = newValue }
        }
    }

    @MainActor
    private static func makeMapCoordinator() -> MapViewRepresentable.Coordinator {
        MapViewRepresentable.Coordinator(
            minZForTiles: 4,
            maxZ: 15,
            maxZForTiles: 15,
            extendedOfflineMaxZ: 17,
            extendedOfflineMaxZForTiles: 17,
            initialLaunchZoom: 12,
            initialCursorTrackingUser: true,
            onDistanceText: { _ in },
            onSpeedText: { _ in },
            onMetersPerPoint: { _ in },
            onFollowStateChanged: { _ in },
            onCursorUpdated: { _, _, _ in },
            onCursorTrackingStateChanged: { _ in },
            onFishingSetDisplayPrompt: { _ in }
        )
    }

    @Test func coordinatesUseOneCanonicalXYZSystem() throws {
        let coordinate = try #require(MBTilesTileCoordinate(z: 15, x: 32_768, y: 0))
        #expect(coordinate.x == 0)
        #expect(coordinate.storedY(for: .xyz) == 0)
        #expect(coordinate.storedY(for: .tms) == 32_767)
        #expect(MBTilesTileCoordinate(z: 15, x: 0, y: 32_767) != nil)
        #expect(MBTilesTileCoordinate(z: 15, x: 0, y: 32_768) == nil)
        #expect(MBTilesTileCoordinate(z: 31, x: 0, y: 0) == nil)
        #expect(try MBTilesStorageScheme.metadataValue(nil) == .tms)
        #expect(try MBTilesStorageScheme.metadataValue("xyz") == .xyz)
    }

    @Test func geographicBoundsProduceATightMapKitCoverageRect() throws {
        let bounds = [-159.75, 56.75, -156.25, 59.50]
        let rect = try #require(MBTilesGeographicCoverage.mapRect(from: bounds))
        let northWest = MKMapPoint(CLLocationCoordinate2D(latitude: bounds[3], longitude: bounds[0]))
        let southEast = MKMapPoint(CLLocationCoordinate2D(latitude: bounds[1], longitude: bounds[2]))

        #expect(rect.width < MKMapRect.world.width / 20)
        #expect(rect.height < MKMapRect.world.height / 20)
        #expect(abs(rect.minX - min(northWest.x, southEast.x)) < 1)
        #expect(abs(rect.maxX - max(northWest.x, southEast.x)) < 1)
        #expect(abs(rect.minY - min(northWest.y, southEast.y)) < 1)
        #expect(abs(rect.maxY - max(northWest.y, southEast.y)) < 1)
        #expect(MBTilesGeographicCoverage.mapRect(from: nil) == nil)
        #expect(MBTilesGeographicCoverage.mapRect(from: [-159, 57, -159, 58]) == nil)
        #expect(MBTilesGeographicCoverage.mapRect(from: [-181, 57, -158, 58]) == nil)
    }

    @Test func viewportPlannerAddsOneRingAndOrdersCenterFirst() throws {
        let tileMapPoints = MKMapSize.world.width / 4
        let visibleTile = MKMapRect(
            x: tileMapPoints,
            y: tileMapPoints,
            width: tileMapPoints,
            height: tileMapPoints
        )
        let coordinates = MBTilesViewportTilePlanner.coordinates(
            in: visibleTile,
            zoom: 2,
            ring: 1,
            maximumCount: 96
        )

        #expect(coordinates.count == 9)
        #expect(coordinates.first == MBTilesTileCoordinate(z: 2, x: 1, y: 1))
        #expect(Set(coordinates).contains(try #require(MBTilesTileCoordinate(z: 2, x: 0, y: 0))))
        #expect(Set(coordinates).contains(try #require(MBTilesTileCoordinate(z: 2, x: 2, y: 2))))
    }

    @Test func costedLRUEvictsTheTrueLeastRecentEntryWithOneUnlinkPerEviction() {
        let cache = CostedLRU<Int, String>(costLimit: 3, countLimit: 3)
        cache.insert("zero", for: 0, cost: 1)
        cache.insert("one", for: 1, cost: 1)
        cache.insert("two", for: 2, cost: 1)
        #expect(cache.value(for: 0) == "zero")

        cache.insert("three", for: 3, cost: 1)
        #expect(cache.value(for: 1) == nil)
        #expect(cache.value(for: 0) == "zero")
        #expect(cache.value(for: 2) == "two")
        #expect(cache.value(for: 3) == "three")
        #expect(cache.evictions == 1)
        #expect(cache.evictionUnlinkOperations == 1)

        let evictionsBeforeChurn = cache.evictions
        let unlinksBeforeChurn = cache.evictionUnlinkOperations
        for key in 4..<10_004 {
            cache.insert("value-\(key)", for: key, cost: 1)
        }
        #expect(cache.count == 3)
        #expect(cache.cost == 3)
        #expect(cache.evictions - evictionsBeforeChurn == 10_000)
        #expect(cache.evictionUnlinkOperations - unlinksBeforeChurn == 10_000)
    }

    @Test func resourceProfilesConstrainOldHardwareAndSuspendSpeculationDeterministically() {
        let gibibyte = UInt64(1_024 * 1_024 * 1_024)
        let ninthGenerationIPad = MBTilesResourceProfile.make(
            activeProcessorCount: 6,
            physicalMemory: 3 * gibibyte
        )
        #expect(ninthGenerationIPad.maximumActiveWork == 2)
        #expect(ninthGenerationIPad.maximumSpeculativeWork == 1)
        #expect(ninthGenerationIPad.maximumQueuedWork == 96)
        #expect(ninthGenerationIPad.compressedCacheBytes == 16 * 1_024 * 1_024)
        #expect(ninthGenerationIPad.onlineSatelliteCacheBytes == 24 * 1_024 * 1_024)
        #expect(ninthGenerationIPad.onlineSatelliteConnections == 1)

        let moderate = MBTilesResourceProfile.make(
            activeProcessorCount: 6,
            physicalMemory: 6 * gibibyte
        )
        #expect(moderate.maximumActiveWork == 3)
        #expect(moderate.onlineSatelliteConnections == 2)

        let modern = MBTilesResourceProfile.make(
            activeProcessorCount: 8,
            physicalMemory: 8 * gibibyte
        )
        #expect(modern.maximumActiveWork == 4)
        #expect(modern.maximumSpeculativeWork == 1)
        #expect(modern.maximumQueuedWork == 256)
        #expect(modern.onlineSatelliteConnections == 3)

        let interacting = MBTilesResourceProfile.make(
            activeProcessorCount: 8,
            physicalMemory: 8 * gibibyte,
            interactionActive: true
        )
        #expect(interacting.maximumActiveWork == 2)
        #expect(interacting.maximumSpeculativeWork == 0)
        #expect(interacting.maximumQueuedWork == 96)
        #expect(interacting.continuityCacheBytes == modern.continuityCacheBytes)

        let constrainedInteraction = MBTilesResourceProfile.make(
            activeProcessorCount: 6,
            physicalMemory: 3 * gibibyte,
            interactionActive: true
        )
        #expect(constrainedInteraction.maximumActiveWork == 1)
        #expect(constrainedInteraction.maximumSpeculativeWork == 0)
        #expect(constrainedInteraction.maximumQueuedWork == 96)
        #expect(
            constrainedInteraction.continuityCacheBytes
                == ninthGenerationIPad.continuityCacheBytes
        )

        let lowPower = MBTilesResourceProfile.make(
            activeProcessorCount: 8,
            physicalMemory: 8 * gibibyte,
            lowPowerMode: true
        )
        #expect(lowPower.maximumActiveWork == 2)
        #expect(lowPower.maximumSpeculativeWork == 0)
        #expect(lowPower.maximumQueuedWork == 96)

        for thermal in [MBTilesResourceProfile.ThermalPressure.serious, .critical] {
            let pressured = MBTilesResourceProfile.make(
                activeProcessorCount: 8,
                physicalMemory: 8 * gibibyte,
                thermalPressure: thermal
            )
            #expect(pressured.maximumActiveWork == 1)
            #expect(pressured.maximumSpeculativeWork == 0)
            #expect(pressured.maximumQueuedWork == 48)
        }
    }

    @Test func viewportZoomBucketsUseHysteresisInsteadOfFlappingAtBoundaries() {
        #expect(MBTilesViewportZoomPolicy.bucket(
            for: 15.64,
            previous: 15,
            minimum: 0,
            maximum: 17
        ) == 15)
        #expect(MBTilesViewportZoomPolicy.bucket(
            for: 15.66,
            previous: 15,
            minimum: 0,
            maximum: 17
        ) == 16)
        #expect(MBTilesViewportZoomPolicy.bucket(
            for: 15.36,
            previous: 16,
            minimum: 0,
            maximum: 17
        ) == 16)
        #expect(MBTilesViewportZoomPolicy.bucket(
            for: 15.34,
            previous: 16,
            minimum: 0,
            maximum: 17
        ) == 15)
        #expect(MBTilesViewportZoomPolicy.bucket(
            for: 17,
            previous: 15,
            minimum: 0,
            maximum: 17
        ) == 17)
    }

    @Test func continuityRetryPolicyUsesTwoBoundedDelaysAndCooldown() {
        #expect(MBTilesRetryPolicy.delay(forRetry: 0) == 0.05)
        #expect(MBTilesRetryPolicy.delay(forRetry: 1) == 0.15)
        #expect(MBTilesRetryPolicy.delay(forRetry: 2) == nil)
        #expect(MBTilesRetryPolicy.cooldown == 0.50)
        #expect(MBTilesRetryPolicy.cooldown(forFailureCycle: -1) == 0.50)
        #expect(MBTilesRetryPolicy.cooldown(forFailureCycle: 0) == 0.50)
        #expect(MBTilesRetryPolicy.cooldown(forFailureCycle: 1) == 1.00)
        #expect(MBTilesRetryPolicy.cooldown(forFailureCycle: 2) == 2.00)
        #expect(MBTilesRetryPolicy.cooldown(forFailureCycle: 3) == 4.00)
        #expect(MBTilesRetryPolicy.cooldown(forFailureCycle: 8) == 4.00)
    }

    @Test func latestOnlyWorkAccumulatorCoalescesBeforeAndDuringADrain() {
        var accumulator = LatestOnlyWorkAccumulator<Int>()
        let firstDrainWasScheduled = accumulator.submit(1)
        #expect(firstDrainWasScheduled)
        for value in 2...100 {
            let duplicateDrainWasScheduled = accumulator.submit(value)
            #expect(!duplicateDrainWasScheduled)
        }
        #expect(accumulator.isDrainScheduled)
        #expect(accumulator.takeLatest() == 100)

        // A value offered while a drain is active replaces the pending value and
        // does not enqueue a second drain.
        let inDrainSubmissionWasScheduled = accumulator.submit(101)
        #expect(!inDrainSubmissionWasScheduled)
        #expect(accumulator.takeLatest() == 101)
        let drainFinished = accumulator.finishDrainIfEmpty()
        #expect(drainFinished)
        #expect(!accumulator.isDrainScheduled)
        let nextDrainWasScheduled = accumulator.submit(102)
        #expect(nextDrainWasScheduled)
    }

    @Test func noncommittingViewportHintsDoNotChurnCommittedGenerations() {
        let identity = MBTilesOverlayIdentity(
            role: .district,
            packageIdentifier: "viewport-hint-fixture",
            packageVersion: UUID().uuidString,
            fileURL: URL(fileURLWithPath: "/tmp/viewport-hint-fixture.mbtiles"),
            minimumZoom: 0,
            maximumZoom: 17,
            nativeDetailMaximumZoom: 15
        )
        let session = MBTilesPackageSession(identity: identity, immutableFile: false)
        defer { session.invalidate(waitForTeardown: true) }
        let center = CLLocationCoordinate2D(latitude: 58.2, longitude: -157.4)

        session.updateViewport(
            zoomLevel: 15,
            centerCoordinate: center,
            commitGeneration: true
        )
        MBTilesPackageSession.flushScheduledViewportUpdatesForTesting()
        #expect(session.viewportStateSnapshot.generation == 0)
        #expect(session.viewportStateSnapshot.committedZoom == 15)

        for index in 0..<100 {
            session.updateViewport(
                zoomLevel: 15 + (2 * Double(index) / 99),
                centerCoordinate: center,
                commitGeneration: false
            )
        }
        MBTilesPackageSession.flushScheduledViewportUpdatesForTesting()
        #expect(session.viewportStateSnapshot.generation == 0)
        #expect(session.viewportStateSnapshot.preferredZoom == 17)
        #expect(session.viewportStateSnapshot.committedZoom == 15)

        session.updateViewport(
            zoomLevel: 17,
            centerCoordinate: center,
            commitGeneration: true
        )
        MBTilesPackageSession.flushScheduledViewportUpdatesForTesting()
        #expect(session.viewportStateSnapshot.generation == 1)
        #expect(session.viewportStateSnapshot.committedZoom == 17)
    }

    @Test func invalidatedBackstopSessionReturnsATerminalOutcome() async throws {
        let identity = MBTilesOverlayIdentity(
            role: .district,
            packageIdentifier: "invalidated-backstop-fixture",
            packageVersion: UUID().uuidString,
            fileURL: URL(fileURLWithPath: "/tmp/invalidated-backstop-fixture.mbtiles")
        )
        let session = MBTilesPackageSession(identity: identity, immutableFile: false)
        session.invalidate(waitForTeardown: true)
        let coordinate = try #require(MBTilesTileCoordinate(z: 0, x: 0, y: 0))
        let outcome = await withCheckedContinuation { continuation in
            session.loadBackstopOutcome(for: coordinate) {
                continuation.resume(returning: $0)
            }
        }
        guard case .cancelled = outcome else {
            Issue.record("An invalidated continuity provider must not enter the retry loop")
            return
        }
    }

    @Test func continuityDisplayZoomUsesMapKitPointsFor512PixelPackages() {
        let identity = MBTilesOverlayIdentity(
            role: .district,
            packageIdentifier: "retina-continuity-fixture",
            packageVersion: UUID().uuidString,
            fileURL: URL(fileURLWithPath: "/tmp/retina-continuity-fixture.mbtiles"),
            tileSizePixels: 512,
            minimumZoom: 0,
            maximumZoom: 17,
            nativeDetailMaximumZoom: 15
        )
        let session = MBTilesPackageSession(identity: identity, immutableFile: false)
        defer { session.invalidate(waitForTeardown: true) }
        let overlay = DistrictMapBackstopOverlay(
            slug: "retina-continuity-fixture",
            identity: identity,
            packageSession: session
        )
        let scaleAtZoom15 = MKZoomScale(
            (256.0 * pow(2.0, 15.0)) / MKMapSize.world.width
        )

        #expect(identity.tileSizePixels == 512)
        #expect(abs(DistrictMapBackstopRenderer.displayZoom(for: scaleAtZoom15) - 15) < 0.000_1)
        #expect(
            DistrictMapBackstopRenderer.displayZoom(for: scaleAtZoom15)
                >= overlay.minimumDisplayZoom
        )
    }

    @Test func bristolNativeTilePayloadRequiresACompleteExpectedSquareRaster() throws {
        let png256 = try Self.rasterData(
            width: 256,
            height: 256,
            format: "png",
            solidColor: SIMD4(20, 40, 60, 255)
        )
        let jpeg256 = try Self.rasterData(
            width: 256,
            height: 256,
            format: "jpg",
            solidColor: SIMD4(70, 90, 110, 255)
        )
        let png512 = try Self.rasterData(
            width: 512,
            height: 512,
            format: "png",
            solidColor: SIMD4(10, 30, 50, 255)
        )
        let nonSquare = try Self.rasterData(
            width: 256,
            height: 128,
            format: "png",
            solidColor: SIMD4(80, 100, 120, 255)
        )
        let truncatedPNG = Data(png256.prefix(32))

        #expect(BristolBaySatelliteTileOverlay.isValidNativeTilePayload(png256))
        #expect(BristolBaySatelliteTileOverlay.isValidNativeTilePayload(jpeg256))
        #expect(!BristolBaySatelliteTileOverlay.isValidNativeTilePayload(truncatedPNG))
        #expect(!BristolBaySatelliteTileOverlay.isValidNativeTilePayload(png512))
        #expect(!BristolBaySatelliteTileOverlay.isValidNativeTilePayload(nonSquare))
        #expect(BristolBaySatelliteTileOverlay.isValidNativeTilePayload(
            png512,
            expectedPixelSize: 512
        ))
    }

    @Test func oneHundredDuplicateRequestsPerformOneLookupAndCompleteOnceEach() async throws {
        let fixture = try Self.makeFixture(scheme: .tms, includeIndex: true)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let session = Self.session(for: fixture, version: UUID().uuidString)
        defer { session.invalidate(waitForTeardown: true) }
        let path = MKTileOverlayPath(x: 0, y: 0, z: 0, contentScaleFactor: 1)
        let lookupsBefore = MBTilesOverlay.diagnosticSnapshot().sqliteLookups

        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    let response = await Self.load(session: session, path: path)
                    return response.0 != nil && response.1 == nil
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }

        #expect(successes == 100)
        #expect(session.underlyingLookupCount == 1)
        #expect(MBTilesOverlay.diagnosticSnapshot().sqliteLookups - lookupsBefore == 1)
        #expect(session.inFlightCount == 0)
    }

    @Test func invalidCoordinatesCompleteExactlyOnce() async throws {
        let fixture = try Self.makeFixture(scheme: .tms, includeIndex: true)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let session = Self.session(for: fixture, version: UUID().uuidString)
        defer { session.invalidate(waitForTeardown: true) }
        let response = await Self.load(
            session: session,
            path: MKTileOverlayPath(x: 0, y: 4, z: 1, contentScaleFactor: 1)
        )
        #expect(response.0 == nil)
        #expect(response.1 is MBTilesError)
        #expect(session.inFlightCount == 0)
    }

    @Test func tmsAndXYZExactRowsAreNotGuessed() async throws {
        let tms = try Self.makeFixture(scheme: .tms, includeIndex: true, exactZoomOneTopTile: true)
        let xyz = try Self.makeFixture(scheme: .xyz, includeIndex: true, exactZoomOneTopTile: true)
        defer {
            try? FileManager.default.removeItem(at: tms.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: xyz.deletingLastPathComponent())
        }
        let path = MKTileOverlayPath(x: 0, y: 0, z: 1, contentScaleFactor: 1)
        let tmsSession = Self.session(for: tms, version: "tms-\(UUID())")
        let xyzSession = Self.session(for: xyz, version: "xyz-\(UUID())")
        defer {
            tmsSession.invalidate(waitForTeardown: true)
            xyzSession.invalidate(waitForTeardown: true)
        }
        let diagnosticsBefore = MBTilesOverlay.diagnosticSnapshot()
        let tmsResponse = await Self.load(session: tmsSession, path: path)
        let xyzResponse = await Self.load(session: xyzSession, path: path)
        let tmsPixel = try Self.centerPixel(in: #require(tmsResponse.0))
        let xyzPixel = try Self.centerPixel(in: #require(xyzResponse.0))
        let diagnosticsAfter = MBTilesOverlay.diagnosticSnapshot()

        #expect(tmsResponse.1 == nil)
        #expect(xyzResponse.1 == nil)
        // The exact z1 tile is deliberately 20/40/60. If either scheme queried the
        // opposite stored row, ancestor fallback would instead return a red z0 crop.
        for pixel in [tmsPixel, xyzPixel] {
            #expect(abs(Int(pixel.x) - 20) <= 2)
            #expect(abs(Int(pixel.y) - 40) <= 2)
            #expect(abs(Int(pixel.z) - 60) <= 2)
            #expect(pixel.w == 255)
        }
        #expect(diagnosticsAfter.fallbackHits == diagnosticsBefore.fallbackHits)
    }

    @Test func fourColorAncestorProducesCorrectXYZQuadrantsAndAlpha() async throws {
        let fixture = try Self.makeFixture(scheme: .tms, includeIndex: true)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let session = Self.session(for: fixture, version: UUID().uuidString)
        defer { session.invalidate(waitForTeardown: true) }
        let expected: [(Int, Int, SIMD4<UInt8>)] = [
            (0, 0, SIMD4(255, 0, 0, 255)),
            (1, 0, SIMD4(0, 255, 0, 255)),
            // CIContext returns premultiplied RGBA for the half-alpha blue quadrant.
            (0, 1, SIMD4(0, 0, 128, 128)),
            (1, 1, SIMD4(255, 255, 0, 255))
        ]

        for (x, y, color) in expected {
            let response = await Self.load(session: session, path: MKTileOverlayPath(x: x, y: y, z: 1, contentScaleFactor: 1))
            let data = try #require(response.0)
            #expect(response.1 == nil)
            let sampled = try Self.centerPixel(in: data)
            #expect(abs(Int(sampled.x) - Int(color.x)) <= 2)
            #expect(abs(Int(sampled.y) - Int(color.y)) <= 2)
            #expect(abs(Int(sampled.z) - Int(color.z)) <= 2)
            #expect(abs(Int(sampled.w) - Int(color.w)) <= 2)
        }
    }

    @Test func nativeDetailCapForcesZ16AndZ17StyleAncestorFallback() async throws {
        let fixture = try Self.makeFixture(
            scheme: .tms,
            includeIndex: true,
            exactZoomOneTopTile: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let identity = MBTilesOverlayIdentity(
            role: .district,
            packageIdentifier: "fixture",
            packageVersion: UUID().uuidString,
            fileURL: fixture,
            minimumZoom: 0,
            maximumZoom: 2,
            nativeDetailMaximumZoom: 0,
            maximumFallbackDepth: 2
        )
        let session = MBTilesPackageSession(identity: identity, immutableFile: false)
        defer { session.invalidate(waitForTeardown: true) }

        // The fixture deliberately contains a different exact z1 tile. A native
        // cap of z0 must ignore it and generate the upper-left red child from z0.
        let response = await Self.load(
            session: session,
            path: MKTileOverlayPath(x: 0, y: 0, z: 1, contentScaleFactor: 1)
        )
        let sampled = try Self.centerPixel(in: #require(response.0))
        #expect(response.1 == nil)
        #expect(sampled.x >= 250)
        #expect(sampled.y <= 2)
        #expect(sampled.z <= 2)
    }

    @Test func multipleFallbackDepthsReuseTheDecodedAncestor() async throws {
        let fixture = try Self.makeFixture(scheme: .tms, includeIndex: true)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let session = Self.session(for: fixture, version: UUID().uuidString)
        defer { session.invalidate(waitForTeardown: true) }
        let expected: [(Int, Int, SIMD4<UInt8>)] = [
            (0, 0, SIMD4(255, 0, 0, 255)),
            (3, 0, SIMD4(0, 255, 0, 255)),
            (0, 3, SIMD4(0, 0, 128, 128)),
            (3, 3, SIMD4(255, 255, 0, 255))
        ]
        let before = MBTilesOverlay.diagnosticSnapshot()

        for (x, y, color) in expected {
            let response = await Self.load(
                session: session,
                path: MKTileOverlayPath(x: x, y: y, z: 2, contentScaleFactor: 1)
            )
            let sampled = try Self.centerPixel(in: #require(response.0))
            #expect(response.1 == nil)
            #expect(abs(Int(sampled.x) - Int(color.x)) <= 2)
            #expect(abs(Int(sampled.y) - Int(color.y)) <= 2)
            #expect(abs(Int(sampled.z) - Int(color.z)) <= 2)
            #expect(abs(Int(sampled.w) - Int(color.w)) <= 2)
        }

        let after = MBTilesOverlay.diagnosticSnapshot()
        // First request checks z2, z1, z0. The other descendants reuse the cached
        // z0 ancestor and check only their absent z2/z1 coordinates.
        #expect(after.sqliteLookups - before.sqliteLookups == 9)
        #expect(after.decodedItems - before.decodedItems == 1)
    }

    @Test func coverageEnvelopeSkipsImpossibleSQLiteLookupButStillFindsAncestor() async throws {
        let fixture = try Self.makeFixture(
            scheme: .tms,
            includeIndex: true,
            exactZoomOneTopTile: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let session = Self.session(for: fixture, version: UUID().uuidString)
        defer { session.invalidate(waitForTeardown: true) }
        let before = MBTilesOverlay.diagnosticSnapshot()

        // z1 contains only x0. Requesting x1 can bypass an impossible exact query,
        // then legitimately fall back to the root ancestor.
        let response = await Self.load(
            session: session,
            path: MKTileOverlayPath(x: 1, y: 0, z: 1, contentScaleFactor: 1)
        )
        let after = MBTilesOverlay.diagnosticSnapshot()

        #expect(response.0 != nil)
        #expect(response.1 == nil)
        #expect(after.coverageRejections - before.coverageRejections == 1)
        #expect(after.sqliteLookups - before.sqliteLookups == 1)
        #expect(after.sqliteP95Microseconds >= after.sqliteP50Microseconds)
        #expect(after.requestP95Microseconds >= after.requestP50Microseconds)
    }

    @Test func coverageEnvelopeRejectsImpossibleRowsForBothTMSAndXYZ() async throws {
        let before = MBTilesOverlay.diagnosticSnapshot()
        var completedSchemes = 0

        for scheme in [MBTilesStorageScheme.tms, .xyz] {
            let fixture = try Self.makeFixture(
                scheme: scheme,
                includeIndex: true,
                exactZoomOneTopTile: true
            )
            defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
            let session = Self.session(for: fixture, version: "row-envelope-\(scheme.rawValue)-\(UUID())")
            defer { session.invalidate(waitForTeardown: true) }

            // The fixture has only canonical XYZ row zero at z1. Row one is outside
            // the stored envelope in either scheme and must skip its exact SQL query,
            // while the z0 ancestor remains a valid fallback.
            let response = await Self.load(
                session: session,
                path: MKTileOverlayPath(x: 0, y: 1, z: 1, contentScaleFactor: 1)
            )
            #expect(response.0 != nil)
            #expect(response.1 == nil)
            #expect(session.underlyingLookupCount == 1)
            completedSchemes += 1
        }

        let after = MBTilesOverlay.diagnosticSnapshot()
        #expect(completedSchemes == 2)
        #expect(after.coverageRejections - before.coverageRejections == 2)
        #expect(after.sqliteLookups - before.sqliteLookups == 2)
    }

    @Test func schedulerCancelsStaleGenerationAndRunsHigherPriorityFirst() {
        let scheduler = MBTilesWorkScheduler.shared
        let maximumActive = scheduler.snapshot().maximumActive
        let blockingOwner = UUID()
        let viewportOwner = UUID()
        let blockerStarted = DispatchSemaphore(value: 0)
        let blockerGate = DispatchSemaphore(value: 0)
        let blockerFinished = DispatchSemaphore(value: 0)

        for _ in 0..<maximumActive {
            let submission = scheduler.submit(
                ownerID: blockingOwner,
                generation: 0,
                priority: 1_000,
                execute: {
                    blockerStarted.signal()
                    blockerGate.wait()
                    blockerFinished.signal()
                },
                cancel: {}
            )
            #expect(submission == .accepted)
        }
        for _ in 0..<maximumActive {
            #expect(blockerStarted.wait(timeout: .now() + 2) == .success)
        }

        let staleCancellation = LockedTestCounter()
        let staleExecution = LockedTestCounter()
        let staleCancellationDelivered = DispatchSemaphore(value: 0)
        #expect(scheduler.submit(
            ownerID: viewportOwner,
            generation: 0,
            priority: 10,
            execute: { staleExecution.increment() },
            cancel: {
                staleCancellation.increment()
                staleCancellationDelivered.signal()
            }
        ) == .accepted)

        scheduler.advanceGeneration(ownerID: viewportOwner, to: 1)
        #expect(staleCancellationDelivered.wait(timeout: .now() + 2) == .success)
        #expect(staleCancellation.value == 1)
        #expect(staleExecution.value == 0)
        #expect(scheduler.submit(
            ownerID: viewportOwner,
            generation: 0,
            priority: 100_000,
            execute: {},
            cancel: {}
        ) == .superseded)

        let lowPriorityExecuted = LockedTestCounter()
        let highRanBeforeLow = LockedTestCounter()
        let viewportWorkFinished = DispatchSemaphore(value: 0)
        #expect(scheduler.submit(
            ownerID: viewportOwner,
            generation: 1,
            priority: 10,
            execute: {
                lowPriorityExecuted.increment()
                viewportWorkFinished.signal()
            },
            cancel: {}
        ) == .accepted)
        #expect(scheduler.submit(
            ownerID: viewportOwner,
            generation: 1,
            priority: 100,
            execute: {
                if lowPriorityExecuted.value == 0 { highRanBeforeLow.increment() }
                viewportWorkFinished.signal()
            },
            cancel: {}
        ) == .accepted)

        // Free one worker. The scheduler must use it for the later high-priority
        // item, then the low-priority item, while the other lanes remain blocked.
        blockerGate.signal()
        #expect(viewportWorkFinished.wait(timeout: .now() + 2) == .success)
        #expect(viewportWorkFinished.wait(timeout: .now() + 2) == .success)
        #expect(highRanBeforeLow.value == 1)
        #expect(lowPriorityExecuted.value == 1)

        for _ in 0..<(maximumActive - 1) { blockerGate.signal() }
        for _ in 0..<maximumActive {
            #expect(blockerFinished.wait(timeout: .now() + 2) == .success)
        }
        scheduler.cancelQueuedWork(ownerID: blockingOwner)
        scheduler.cancelQueuedWork(ownerID: viewportOwner)
    }

    @Test func schedulerRetainsOnlyTheImmediatelyPreviousZoomGeneration() {
        let scheduler = MBTilesWorkScheduler.shared
        let maximumActive = scheduler.snapshot().maximumActive
        let blockingOwner = UUID()
        let viewportOwner = UUID()
        let blockerStarted = DispatchSemaphore(value: 0)
        let blockerGate = DispatchSemaphore(value: 0)
        let blockerFinished = DispatchSemaphore(value: 0)

        for _ in 0..<maximumActive {
            #expect(scheduler.submit(
                ownerID: blockingOwner,
                generation: 0,
                priority: 1_000,
                execute: {
                    blockerStarted.signal()
                    blockerGate.wait()
                    blockerFinished.signal()
                },
                cancel: {}
            ) == .accepted)
        }
        for _ in 0..<maximumActive {
            #expect(blockerStarted.wait(timeout: .now() + 2) == .success)
        }

        let oldestCancellation = LockedTestCounter()
        let oldestCancellationDelivered = DispatchSemaphore(value: 0)
        #expect(scheduler.submit(
            ownerID: viewportOwner,
            generation: 0,
            priority: 100_000,
            execute: {},
            cancel: {
                oldestCancellation.increment()
                oldestCancellationDelivered.signal()
            }
        ) == .accepted)
        scheduler.advanceGeneration(ownerID: viewportOwner, to: 1, retainingPrevious: true)
        #expect(oldestCancellation.value == 0)
        scheduler.advanceGeneration(ownerID: viewportOwner, to: 2, retainingPrevious: true)
        #expect(oldestCancellationDelivered.wait(timeout: .now() + 2) == .success)
        #expect(oldestCancellation.value == 1)
        #expect(scheduler.submit(
            ownerID: viewportOwner,
            generation: 0,
            priority: 200_000,
            execute: {},
            cancel: {}
        ) == .superseded)

        let executionOrder = LockedTestOrder()
        let workFinished = DispatchSemaphore(value: 0)
        #expect(scheduler.submit(
            ownerID: viewportOwner,
            generation: 1,
            priority: 100_000,
            execute: {
                executionOrder.append(1)
                workFinished.signal()
            },
            cancel: {}
        ) == .accepted)
        #expect(scheduler.submit(
            ownerID: viewportOwner,
            generation: 2,
            priority: 60_000,
            execute: {
                executionOrder.append(2)
                workFinished.signal()
            },
            cancel: {}
        ) == .accepted)

        blockerGate.signal()
        #expect(workFinished.wait(timeout: .now() + 2) == .success)
        #expect(workFinished.wait(timeout: .now() + 2) == .success)
        #expect(executionOrder.values == [2, 1])

        for _ in 0..<(maximumActive - 1) { blockerGate.signal() }
        for _ in 0..<maximumActive {
            #expect(blockerFinished.wait(timeout: .now() + 2) == .success)
        }
        scheduler.cancelQueuedWork(ownerID: blockingOwner)
        scheduler.cancelQueuedWork(ownerID: viewportOwner)
    }

    @Test func schedulerIsBoundedFairAcrossVisibleOwnersAndDefersPrefetch() {
        let scheduler = MBTilesWorkScheduler()
        let runtimeLimits = scheduler.snapshot()
        let maximumActive = runtimeLimits.maximumActive
        let permitsSpeculation = runtimeLimits.maximumSpeculative > 0
        let blockingOwner = UUID()
        let firstVisibleOwner = UUID()
        let secondVisibleOwner = UUID()
        let prefetchOwner = UUID()
        let blockerStarted = DispatchSemaphore(value: 0)
        let blockerGate = DispatchSemaphore(value: 0)
        let blockerFinished = DispatchSemaphore(value: 0)

        for _ in 0..<maximumActive {
            #expect(scheduler.submit(
                ownerID: blockingOwner,
                generation: 0,
                priority: 200_000,
                execute: {
                    blockerStarted.signal()
                    blockerGate.wait()
                    blockerFinished.signal()
                },
                cancel: {}
            ) == .accepted)
        }
        for _ in 0..<maximumActive {
            #expect(blockerStarted.wait(timeout: .now() + 2) == .success)
        }

        let executionOrder = LockedTestOrder()
        let workFinished = DispatchSemaphore(value: 0)
        #expect(scheduler.submit(
            ownerID: firstVisibleOwner,
            generation: 0,
            priority: 103_000,
            execute: {
                executionOrder.append(1)
                workFinished.signal()
            },
            cancel: {}
        ) == .accepted)
        #expect(scheduler.submit(
            ownerID: firstVisibleOwner,
            generation: 0,
            priority: 102_900,
            execute: {
                executionOrder.append(1)
                workFinished.signal()
            },
            cancel: {}
        ) == .accepted)
        #expect(scheduler.submit(
            ownerID: secondVisibleOwner,
            generation: 0,
            priority: 101_000,
            execute: {
                executionOrder.append(2)
                workFinished.signal()
            },
            cancel: {}
        ) == .accepted)
        let prefetchSubmission = scheduler.submit(
            ownerID: prefetchOwner,
            generation: 0,
            priority: 78_000,
            isSpeculative: true,
            execute: {
                executionOrder.append(3)
                workFinished.signal()
            },
            cancel: {}
        )
        #expect(prefetchSubmission == (permitsSpeculation ? .accepted : .superseded))

        let queued = scheduler.snapshot()
        let expectedOrder = permitsSpeculation ? [1, 2, 1, 3] : [1, 2, 1]
        #expect(queued.active == maximumActive)
        #expect(queued.queued == expectedOrder.count)
        #expect(queued.queued <= queued.maximumQueued)

        // One released lane deterministically drains queued work. Same-tier visible
        // owners rotate before one owner receives a second turn; optional prefetch
        // remains below all visible demand.
        blockerGate.signal()
        for _ in 0..<expectedOrder.count {
            #expect(workFinished.wait(timeout: .now() + 2) == .success)
        }
        #expect(executionOrder.values == expectedOrder)

        for _ in 0..<(maximumActive - 1) { blockerGate.signal() }
        for _ in 0..<maximumActive {
            #expect(blockerFinished.wait(timeout: .now() + 2) == .success)
        }
    }

    @Test func schedulerEnforcesGlobalActiveAndPendingBounds() {
        let scheduler = MBTilesWorkScheduler()
        let runtimeLimits = scheduler.snapshot()
        let maximumActive = runtimeLimits.maximumActive
        let maximumQueued = runtimeLimits.maximumQueued
        let blockingOwner = UUID()
        let queuedOwner = UUID()
        let blockerStarted = DispatchSemaphore(value: 0)
        let blockerGate = DispatchSemaphore(value: 0)
        let blockerFinished = DispatchSemaphore(value: 0)

        for _ in 0..<maximumActive {
            #expect(scheduler.submit(
                ownerID: blockingOwner,
                generation: 0,
                priority: 200_000,
                execute: {
                    blockerStarted.signal()
                    blockerGate.wait()
                    blockerFinished.signal()
                },
                cancel: {}
            ) == .accepted)
        }
        for _ in 0..<maximumActive {
            #expect(blockerStarted.wait(timeout: .now() + 2) == .success)
        }

        let attempted = maximumQueued + 64
        let terminalCount = LockedTestCounter()
        let terminalGroup = DispatchGroup()
        var accepted = 0
        var saturated = 0
        for _ in 0..<attempted {
            terminalGroup.enter()
            let submission = scheduler.submit(
                ownerID: queuedOwner,
                generation: 0,
                priority: 100_000,
                execute: {
                    terminalCount.increment()
                    terminalGroup.leave()
                },
                cancel: {
                    terminalCount.increment()
                    terminalGroup.leave()
                }
            )
            switch submission {
            case .accepted:
                accepted += 1
            case .saturated, .superseded:
                saturated += 1
                terminalCount.increment()
                terminalGroup.leave()
            }
        }

        let bounded = scheduler.snapshot()
        #expect(bounded.active == maximumActive)
        #expect(bounded.queued == maximumQueued)
        #expect(bounded.highWater == maximumQueued)
        #expect(accepted == maximumQueued)
        #expect(saturated == 64)

        for _ in 0..<maximumActive { blockerGate.signal() }
        #expect(terminalGroup.wait(timeout: .now() + 5) == .success)
        #expect(terminalCount.value == attempted)
        for _ in 0..<maximumActive {
            #expect(blockerFinished.wait(timeout: .now() + 2) == .success)
        }
    }

    @Test func schedulerMemoryPressureCancelsOnlyQueuedSpeculativeWork() {
        let scheduler = MBTilesWorkScheduler()
        let runtimeLimits = scheduler.snapshot()
        let maximumActive = runtimeLimits.maximumActive
        let permitsSpeculation = runtimeLimits.maximumSpeculative > 0
        let blockingOwner = UUID()
        let visibleOwner = UUID()
        let prefetchOwner = UUID()
        let blockerStarted = DispatchSemaphore(value: 0)
        let blockerGate = DispatchSemaphore(value: 0)
        let blockerFinished = DispatchSemaphore(value: 0)

        for _ in 0..<maximumActive {
            #expect(scheduler.submit(
                ownerID: blockingOwner,
                generation: 0,
                priority: 200_000,
                execute: {
                    blockerStarted.signal()
                    blockerGate.wait()
                    blockerFinished.signal()
                },
                cancel: {}
            ) == .accepted)
        }
        for _ in 0..<maximumActive {
            #expect(blockerStarted.wait(timeout: .now() + 2) == .success)
        }

        let visibleFinished = DispatchSemaphore(value: 0)
        let prefetchCancelled = DispatchSemaphore(value: 0)
        #expect(scheduler.submit(
            ownerID: visibleOwner,
            generation: 0,
            priority: 100_000,
            execute: { visibleFinished.signal() },
            cancel: {}
        ) == .accepted)
        let speculativeSubmission = scheduler.submit(
            ownerID: prefetchOwner,
            generation: 0,
            priority: 110_000,
            isSpeculative: true,
            execute: {},
            cancel: { prefetchCancelled.signal() }
        )
        #expect(speculativeSubmission == (permitsSpeculation ? .accepted : .superseded))

        scheduler.cancelSpeculativeWork()
        if permitsSpeculation {
            #expect(prefetchCancelled.wait(timeout: .now() + 2) == .success)
        } else {
            #expect(prefetchCancelled.wait(timeout: .now()) == .timedOut)
        }
        #expect(scheduler.snapshot().queued == 1)

        blockerGate.signal()
        #expect(visibleFinished.wait(timeout: .now() + 2) == .success)
        for _ in 0..<(maximumActive - 1) { blockerGate.signal() }
        for _ in 0..<maximumActive {
            #expect(blockerFinished.wait(timeout: .now() + 2) == .success)
        }
    }

    @Test func schedulerSuspendsSpeculationDuringMapInteractionWithoutBlockingVisibleWork() {
        let scheduler = MBTilesWorkScheduler()
        scheduler.setMapInteractionActive(true)
        let interacting = scheduler.snapshot()
        #expect(interacting.speculationSuspended)
        #expect(interacting.maximumSpeculative == 0)
        #expect(
            interacting.maximumActive
                == MBTilesResourceProfile.current(interactionActive: true).maximumActiveWork
        )

        let speculativeExecution = LockedTestCounter()
        let speculativeResult = scheduler.submit(
            ownerID: UUID(),
            generation: 0,
            priority: 200_000,
            isSpeculative: true,
            execute: { speculativeExecution.increment() },
            cancel: {}
        )
        #expect(speculativeResult == .superseded)
        #expect(speculativeExecution.value == 0)

        let visibleFinished = DispatchSemaphore(value: 0)
        #expect(scheduler.submit(
            ownerID: UUID(),
            generation: 0,
            priority: 100_000,
            execute: { visibleFinished.signal() },
            cancel: {}
        ) == .accepted)
        #expect(visibleFinished.wait(timeout: .now() + 2) == .success)

        scheduler.setMapInteractionActive(false)
        let restored = scheduler.snapshot()
        let currentSystemProfile = MBTilesResourceProfile.current()
        #expect(restored.maximumActive == currentSystemProfile.maximumActiveWork)
        #expect(restored.maximumSpeculative == currentSystemProfile.maximumSpeculativeWork)
        #expect(restored.maximumQueued == currentSystemProfile.maximumQueuedWork)
    }

    @Test func schedulerReservesVisibleCapacityAndHonorsTheRuntimeSpeculativeLimit() {
        let scheduler = MBTilesWorkScheduler()
        let limits = scheduler.snapshot()
        guard limits.maximumSpeculative > 0 else {
            let result = scheduler.submit(
                ownerID: UUID(),
                generation: 0,
                priority: 50_000,
                isSpeculative: true,
                execute: {},
                cancel: {}
            )
            #expect(result == .superseded)
            #expect(scheduler.snapshot().activeSpeculative == 0)
            return
        }

        let speculativeStarted = DispatchSemaphore(value: 0)
        let speculativeGate = DispatchSemaphore(value: 0)
        let speculativeFinished = DispatchSemaphore(value: 0)
        for _ in 0..<limits.maximumSpeculative {
            #expect(scheduler.submit(
                ownerID: UUID(),
                generation: 0,
                priority: 50_000,
                isSpeculative: true,
                execute: {
                    speculativeStarted.signal()
                    speculativeGate.wait()
                    speculativeFinished.signal()
                },
                cancel: {}
            ) == .accepted)
        }
        for _ in 0..<limits.maximumSpeculative {
            #expect(speculativeStarted.wait(timeout: .now() + 2) == .success)
        }

        let whileSpeculating = scheduler.snapshot()
        #expect(whileSpeculating.activeSpeculative == limits.maximumSpeculative)
        #expect(whileSpeculating.activeSpeculative < whileSpeculating.maximumActive)

        let visibleFinished = DispatchSemaphore(value: 0)
        #expect(scheduler.submit(
            ownerID: UUID(),
            generation: 0,
            priority: 100_000,
            execute: { visibleFinished.signal() },
            cancel: {}
        ) == .accepted)
        #expect(visibleFinished.wait(timeout: .now() + 2) == .success)

        for _ in 0..<limits.maximumSpeculative { speculativeGate.signal() }
        for _ in 0..<limits.maximumSpeculative {
            #expect(speculativeFinished.wait(timeout: .now() + 2) == .success)
        }
    }

    @Test func missingSchemeUsesDocumentedLegacyTMSRule() async throws {
        let fixture = try Self.makeFixture(
            scheme: .tms,
            includeIndex: true,
            exactZoomOneTopTile: true,
            omitSchemeMetadata: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let session = Self.session(for: fixture, version: UUID().uuidString)
        defer { session.invalidate(waitForTeardown: true) }
        let response = await Self.load(
            session: session,
            path: MKTileOverlayPath(x: 0, y: 0, z: 1, contentScaleFactor: 1)
        )
        #expect(response.0 != nil)
        #expect(response.1 == nil)
    }

    @Test func packageRegistryReusesAProviderAcrossMapViewRecreation() {
        let identity = MBTilesOverlayIdentity(
            role: .district,
            packageIdentifier: "recreated-map",
            packageVersion: UUID().uuidString,
            fileURL: URL(fileURLWithPath: "/tmp/recreated-map.mbtiles")
        )
        defer {
            MBTilesPackageSessionRegistry.shared.retire(identity: identity)
            MBTilesPackageSessionRegistry.shared.retire(identity: identity)
        }
        let first = MBTilesPackageSessionRegistry.shared.session(for: identity, immutableFile: false)
        let second = MBTilesPackageSessionRegistry.shared.session(for: identity, immutableFile: false)
        #expect(first === second)
    }

    @Test func retiredRegistrySessionResumesBeforeServingItsNextMapView() async throws {
        let fixture = try Self.makeFixture(scheme: .tms, includeIndex: true)
        let directory = fixture.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = MBTilesOverlayIdentity(
            role: .district,
            packageIdentifier: "resume-fixture",
            packageVersion: UUID().uuidString,
            fileURL: fixture,
            minimumZoom: 0,
            maximumZoom: 15
        )
        let registry = MBTilesPackageSessionRegistry()
        let first = registry.session(for: identity, immutableFile: false)
        registry.retire(identity: identity)
        let reacquired = registry.session(for: identity, immutableFile: false)
        defer {
            registry.retire(identity: identity)
            registry.invalidatePackage(at: fixture)
        }

        #expect(first === reacquired)
        let response = await Self.load(
            session: reacquired,
            path: MKTileOverlayPath(x: 0, y: 0, z: 0, contentScaleFactor: 1)
        )
        #expect(response.0 != nil)
        #expect(response.1 == nil)
    }

    @Test func suspendedSessionRejectsNewWorkWithoutTouchingSQLiteThenResumes() async throws {
        let fixture = try Self.makeFixture(scheme: .tms, includeIndex: true)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let session = Self.session(for: fixture, version: "suspension-\(UUID())")
        defer { session.invalidate(waitForTeardown: true) }
        let path = MKTileOverlayPath(x: 0, y: 0, z: 0, contentScaleFactor: 1)
        let coordinate = try #require(MBTilesTileCoordinate(z: 0, x: 0, y: 0))
        let originalLifecycleEpoch = try #require(session.activeLifecycleEpoch())
        let lookupsBefore = session.underlyingLookupCount

        session.suspendQueuedWork()
        let response = await Self.load(session: session, path: path)
        #expect(response.0 == nil)
        if case .requestSuperseded? = response.1 as? MBTilesError {
            // Expected terminal result for detached MapKit demand.
        } else {
            Issue.record("A suspended session must reject tile demand as superseded")
        }
        let backstopOutcome = await withCheckedContinuation { continuation in
            session.loadBackstopOutcome(for: coordinate) {
                continuation.resume(returning: $0)
            }
        }
        guard case .cancelled = backstopOutcome else {
            Issue.record("A suspended continuity request must terminate without retrying")
            return
        }
        #expect(session.underlyingLookupCount == lookupsBefore)
        #expect(session.inFlightCount == 0)
        #expect(session.backstopInFlightCount == 0)

        session.resume()
        let staleResponse = await withCheckedContinuation { continuation in
            session.load(path: path, lifecycleEpoch: originalLifecycleEpoch) {
                data, error in
                continuation.resume(returning: (data, error))
            }
        }
        #expect(staleResponse.0 == nil)
        if case .requestSuperseded? = staleResponse.1 as? MBTilesError {
            // Work queued by the previous map lifecycle cannot inherit the resume.
        } else {
            Issue.record("An old ingress lifecycle ticket must remain superseded after resume")
        }
        let staleBackstop = await withCheckedContinuation { continuation in
            session.loadBackstopOutcome(
                for: coordinate,
                lifecycleEpoch: originalLifecycleEpoch
            ) { continuation.resume(returning: $0) }
        }
        guard case .cancelled = staleBackstop else {
            Issue.record("Old continuity ingress must remain terminal after resume")
            return
        }
        #expect(session.underlyingLookupCount == lookupsBefore)

        let resumed = await Self.load(session: session, path: path)
        #expect(resumed.0 != nil)
        #expect(resumed.1 == nil)
    }

    @Test func queuedBackstopCancellationIsTerminalAndCompletesExactlyOnce() async throws {
        let fixture = try Self.makeFixture(scheme: .tms, includeIndex: true)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let session = Self.session(for: fixture, version: "queued-suspension-\(UUID())")
        defer { session.invalidate(waitForTeardown: true) }
        let coordinate = try #require(MBTilesTileCoordinate(z: 0, x: 0, y: 0))
        let scheduler = MBTilesWorkScheduler.shared
        let schedulerWasIdle = await Self.waitUntil {
            let snapshot = scheduler.snapshot()
            return snapshot.active == 0 && snapshot.queued == 0
        }
        guard schedulerWasIdle else {
            Issue.record("The shared tile scheduler did not become idle before the cancellation test")
            return
        }
        let activeLimit = scheduler.snapshot().maximumActive
        let blockerOwnerID = UUID()
        let blockerGate = DispatchSemaphore(value: 0)
        let blockerStarted = DispatchSemaphore(value: 0)
        let blockerFinished = DispatchSemaphore(value: 0)
        defer {
            for _ in 0..<activeLimit { blockerGate.signal() }
            scheduler.cancelQueuedWork(ownerID: blockerOwnerID)
        }

        for _ in 0..<activeLimit {
            try #require(scheduler.submit(
                ownerID: blockerOwnerID,
                generation: 0,
                priority: 1_000_000,
                execute: {
                    blockerStarted.signal()
                    blockerGate.wait()
                    blockerFinished.signal()
                },
                cancel: {}
            ) == .accepted)
        }
        for _ in 0..<activeLimit {
            #expect(await Self.wait(for: blockerStarted, timeout: 2))
        }

        let completions = LockedTestCounter()
        let outcome = LockedTestValue<MBTilesBackstopLoadOutcome>()
        let outcomeReady = DispatchSemaphore(value: 0)
        session.scheduleBackstopOutcome(for: coordinate) { result in
            completions.increment()
            outcome.store(result)
            outcomeReady.signal()
        }
        let requestWasQueued = await Self.waitUntil {
            session.backstopInFlightCount == 1
        }
        #expect(requestWasQueued)
        session.suspendQueuedWork()
        let callbackArrived = await Self.wait(for: outcomeReady, timeout: 2)
        #expect(callbackArrived)

        guard case .cancelled? = outcome.value else {
            Issue.record("Retiring a queued continuity request must not start its retry loop")
            return
        }
        #expect(completions.value == 1)
        #expect(session.backstopInFlightCount == 0)

        for _ in 0..<activeLimit { blockerGate.signal() }
        for _ in 0..<activeLimit {
            #expect(await Self.wait(for: blockerFinished, timeout: 2))
        }
        let schedulerDrained = await Self.waitUntil {
            let snapshot = scheduler.snapshot()
            return snapshot.active == 0 && snapshot.queued == 0
        }
        #expect(schedulerDrained)
        #expect(completions.value == 1)
        guard case .cancelled? = outcome.value else {
            Issue.record("A stale worker changed the terminal cancellation outcome")
            return
        }
    }

    @Test func registryLeaseProtectsOnlyActivelyInstalledCacheIdentity() {
        let identity = MBTilesOverlayIdentity(
            role: .district,
            packageIdentifier: "active-cache-fixture",
            packageVersion: UUID().uuidString,
            fileURL: URL(fileURLWithPath: "/tmp/active-cache-fixture.mbtiles")
        )
        let before = MBTilesOverlay.diagnosticSnapshot().activeCacheIdentities
        _ = MBTilesPackageSessionRegistry.shared.session(for: identity, immutableFile: false)
        let whileLeased = MBTilesOverlay.diagnosticSnapshot().activeCacheIdentities
        MBTilesPackageSessionRegistry.shared.retire(identity: identity)
        let afterRetirement = MBTilesOverlay.diagnosticSnapshot().activeCacheIdentities

        #expect(whileLeased == before + 1)
        #expect(afterRetirement == before)
    }

    @Test func previewFileLeaseBlocksInvalidationAndRejectsNewReadersUntilRelease() async throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-lease-\(UUID()).mbtiles")
        let registry = MBTilesPackageSessionRegistry.shared
        let lease = try #require(registry.acquirePackageFileReadLease(at: packageURL))
        defer { lease.release() }
        let invalidationFinished = LockedTestCounter()

        let invalidation = Task.detached {
            registry.invalidatePackage(at: packageURL)
            invalidationFinished.increment()
        }

        let invalidationStarted = await Self.waitUntil {
            lease.isCancelled
        }
        #expect(invalidationStarted)
        #expect(invalidationFinished.value == 0)
        #expect(registry.acquirePackageFileReadLease(at: packageURL) == nil)

        lease.release()
        await invalidation.value
        #expect(invalidationFinished.value == 1)

        let replacementLease = try #require(
            registry.acquirePackageFileReadLease(at: packageURL)
        )
        #expect(!replacementLease.isCancelled)
        replacementLease.release()
    }

    @Test func retiringOneMapViewLeaseDoesNotInvalidateAnotherMapView() async throws {
        let fixture = try Self.makeFixture(scheme: .tms, includeIndex: true)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let identity = MBTilesOverlayIdentity(
            role: .district,
            packageIdentifier: "shared-fixture",
            packageVersion: UUID().uuidString,
            fileURL: fixture
        )
        let first = MBTilesPackageSessionRegistry.shared.session(for: identity, immutableFile: false)
        let second = MBTilesPackageSessionRegistry.shared.session(for: identity, immutableFile: false)
        defer {
            MBTilesPackageSessionRegistry.shared.retire(identity: identity)
            MBTilesPackageSessionRegistry.shared.invalidatePackage(at: fixture)
        }
        #expect(first === second)

        MBTilesPackageSessionRegistry.shared.retire(identity: identity)
        let response = await Self.load(
            session: second,
            path: MKTileOverlayPath(x: 0, y: 0, z: 0, contentScaleFactor: 1)
        )
        #expect(response.0 != nil)
        #expect(response.1 == nil)
    }

    @Test func replacementReadinessFiresOnceOnlyAfterServingRealTileBytes() async throws {
        let fixture = try Self.makeFixture(scheme: .tms, includeIndex: true)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let overlay = MBTilesOverlay(
            mbtilesURL: fixture,
            slug: "fixture",
            packageVersion: UUID().uuidString,
            role: .district,
            minimumZoom: 0,
            maximumZoom: 15,
            immutableFile: false
        )
        defer {
            MBTilesPackageSessionRegistry.shared.retire(identity: overlay.identity)
            MBTilesPackageSessionRegistry.shared.invalidatePackage(at: fixture)
        }
        let readiness = LockedTestCounter()
        overlay.whenFirstTileIsReady { readiness.increment() }
        #expect(readiness.value == 0)

        let path = MKTileOverlayPath(x: 0, y: 0, z: 0, contentScaleFactor: 1)
        let first = await Self.load(overlay: overlay, path: path)
        let second = await Self.load(overlay: overlay, path: path)
        #expect(first.0 != nil && first.1 == nil)
        #expect(second.0 != nil && second.1 == nil)
        #expect(readiness.value == 1)
    }

    @MainActor
    @Test func districtTileOverlayStopsAtZ15AndSharesItsTightBoundsWithTheNativeUnderlay() throws {
        let fixture = try Self.makeFixture(scheme: .tms, includeIndex: true)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let coverage = try #require(MBTilesGeographicCoverage.mapRect(
            from: [-159.75, 56.75, -156.25, 59.50]
        ))
        let overlay = MBTilesOverlay(
            mbtilesURL: fixture,
            slug: "fixture",
            packageVersion: UUID().uuidString,
            role: .district,
            minimumZoom: 0,
            maximumZoom: 15,
            nativeDetailMaximumZ: 15,
            coverageMapRect: coverage,
            immutableFile: false
        )
        defer {
            MBTilesPackageSessionRegistry.shared.retire(identity: overlay.identity)
            MBTilesPackageSessionRegistry.shared.invalidatePackage(at: fixture)
        }
        let underlay = DistrictMapBackstopOverlay(
            slug: overlay.slug,
            identity: overlay.identity,
            packageSession: overlay.packageSession,
            boundingMapRect: coverage
        )

        #expect(overlay.maximumZ == 15)
        #expect(overlay.nativeDetailMaximumZ == 15)
        #expect(overlay.identity.maximumZoom == 15)
        #expect(underlay.nativeZoom == 15)
        #expect(abs(overlay.boundingMapRect.minX - coverage.minX) < 0.5)
        #expect(abs(overlay.boundingMapRect.maxX - coverage.maxX) < 0.5)
        #expect(abs(underlay.boundingMapRect.minY - coverage.minY) < 0.5)
        #expect(abs(underlay.boundingMapRect.maxY - coverage.maxY) < 0.5)
        #expect(abs(MKMapPoint(underlay.coordinate).x - coverage.midX) < 0.5)
        #expect(abs(MKMapPoint(underlay.coordinate).y - coverage.midY) < 0.5)
    }

    @Test func replacementReadinessChecksTheCompleteCurrentZoomViewportBelowNativeScale() async throws {
        let fixture = try Self.makeFixture(
            scheme: .tms,
            includeIndex: true,
            exactZoomOneTopTile: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let identity = MBTilesOverlayIdentity(
            role: .district,
            packageIdentifier: "fixture",
            packageVersion: UUID().uuidString,
            fileURL: fixture,
            minimumZoom: 0,
            maximumZoom: 15,
            nativeDetailMaximumZoom: 15
        )
        let session = MBTilesPackageSession(identity: identity, immutableFile: false)
        defer { session.invalidate(waitForTeardown: true) }
        let backstop = DistrictMapBackstopOverlay(
            slug: "fixture",
            identity: identity,
            packageSession: session,
            boundingMapRect: .world
        )
        let visibleRect = MBTilesViewportTilePlanner.mapRect(
            for: try #require(MBTilesTileCoordinate(z: 1, x: 0, y: 0))
        )

        let planned = backstop.visibleCoordinates(in: visibleRect, zoom: 1)
        #expect(planned == [MBTilesTileCoordinate(z: 1, x: 0, y: 0)])
        let readiness = await withCheckedContinuation { continuation in
            backstop.prepareVisibleCoverageReadiness(
                in: visibleRect,
                zoom: 1
            ) { continuation.resume(returning: $0) }
        }
        #expect(readiness.expectedCount == 1)
        #expect(readiness.resolvedCount == 1)
        #expect(readiness.imageCount == 1)
        #expect(readiness.isReady)
    }

    @MainActor
    @Test func tileOverlayAdmissionKeepsSQLiteAndRasterWorkOffTheMainActor() async throws {
        let fixture = try Self.makeFixture(scheme: .tms, includeIndex: true)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let overlay = MBTilesOverlay(
            mbtilesURL: fixture,
            slug: "fixture",
            packageVersion: UUID().uuidString,
            role: .district,
            minimumZoom: 0,
            maximumZoom: 15,
            nativeDetailMaximumZ: 15,
            immutableFile: false
        )
        defer {
            MBTilesPackageSessionRegistry.shared.retire(identity: overlay.identity)
            MBTilesPackageSessionRegistry.shared.invalidatePackage(at: fixture)
        }
        let violationsBefore = MBTilesOverlay.diagnosticSnapshot().mainThreadWorkViolations

        let response = await Self.load(
            overlay: overlay,
            path: MKTileOverlayPath(x: 0, y: 0, z: 0, contentScaleFactor: 1)
        )
        #expect(response.0 != nil)
        #expect(response.1 == nil)
        #expect(MBTilesOverlay.diagnosticSnapshot().mainThreadWorkViolations == violationsBefore)
    }

    @Test func nativeBackstopDecodesOnceAndReusesItsBoundedImageCache() async throws {
        let fixture = try Self.makeFixture(scheme: .tms, includeIndex: true)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let session = Self.session(for: fixture, version: "backstop-\(UUID())")
        defer { session.invalidate(waitForTeardown: true) }
        let coordinate = try #require(MBTilesTileCoordinate(z: 0, x: 0, y: 0))

        let first = await withCheckedContinuation { continuation in
            session.loadBackstopImage(for: coordinate) { continuation.resume(returning: $0) }
        }
        let lookupsAfterFirst = session.underlyingLookupCount
        let second = await withCheckedContinuation { continuation in
            session.loadBackstopImage(for: coordinate) { continuation.resume(returning: $0) }
        }

        #expect(first?.width == 256)
        #expect(first?.height == 256)
        #expect(second != nil)
        #expect(session.underlyingLookupCount == lookupsAfterFirst)
    }

    @Test func nativeImagePathSharesRawSourceButSeparatesAppearanceOutputCaches() async throws {
        let fixture = try Self.makeFixture(
            scheme: .tms,
            includeIndex: true,
            solidColor: SIMD4(90, 110, 130, 255)
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let version = UUID().uuidString
        let neutralIdentity = MBTilesOverlayIdentity(
            role: .district,
            packageIdentifier: "fixture",
            packageVersion: version,
            fileURL: fixture,
            minimumZoom: 0,
            maximumZoom: 15,
            nativeDetailMaximumZoom: 15,
            visualSettings: .neutral
        )
        let adjustedIdentity = MBTilesOverlayIdentity(
            role: .district,
            packageIdentifier: "fixture",
            packageVersion: version,
            fileURL: fixture,
            minimumZoom: 0,
            maximumZoom: 15,
            nativeDetailMaximumZoom: 15,
            visualSettings: DistrictMapVisualSettings(
                brightness: 0.15,
                contrast: 1.38,
                gamma: 0.78,
                saturation: 1.12
            )
        )
        let neutralSession = MBTilesPackageSession(identity: neutralIdentity, immutableFile: false)
        let adjustedSession = MBTilesPackageSession(identity: adjustedIdentity, immutableFile: false)
        defer {
            neutralSession.invalidate(waitForTeardown: true)
            adjustedSession.invalidate(waitForTeardown: true)
        }
        let coordinate = try #require(MBTilesTileCoordinate(z: 0, x: 0, y: 0))
        let diagnosticsBefore = MBTilesOverlay.diagnosticSnapshot()

        let neutralImage = try #require(await Self.loadBackstopImage(
            session: neutralSession,
            coordinate: coordinate
        ))
        let diagnosticsAfterNeutral = MBTilesOverlay.diagnosticSnapshot()
        #expect(diagnosticsAfterNeutral.sqliteLookups - diagnosticsBefore.sqliteLookups == 1)
        #expect(neutralIdentity.sourceIdentity == adjustedIdentity.sourceIdentity)
        #expect(neutralIdentity != adjustedIdentity)

        let adjustedImage = try #require(await Self.loadBackstopImage(
            session: adjustedSession,
            coordinate: coordinate
        ))
        let diagnosticsAfterAdjusted = MBTilesOverlay.diagnosticSnapshot()
        #expect(diagnosticsAfterAdjusted.sqliteLookups == diagnosticsAfterNeutral.sqliteLookups)
        #expect(try Self.centerPixel(in: neutralImage) != Self.centerPixel(in: adjustedImage))
        #expect(diagnosticsAfterAdjusted.generatedCost == diagnosticsBefore.generatedCost)

        _ = await Self.loadBackstopImage(session: adjustedSession, coordinate: coordinate)
        let diagnosticsAfterCacheHit = MBTilesOverlay.diagnosticSnapshot()
        #expect(diagnosticsAfterCacheHit.sqliteLookups == diagnosticsAfterAdjusted.sqliteLookups)
        #expect(diagnosticsAfterCacheHit.generatedCost == diagnosticsBefore.generatedCost)
    }

    @Test func nativeUnderlayReadinessCoversEveryVisibleParentAndClipsOutsideItsBounds() async throws {
        let fixture = try Self.makeFixture(
            scheme: .tms,
            includeIndex: true,
            includeZoomTwoCoverageTiles: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let identity = MBTilesOverlayIdentity(
            role: .district,
            packageIdentifier: "fixture",
            packageVersion: UUID().uuidString,
            fileURL: fixture,
            minimumZoom: 0,
            maximumZoom: 15,
            nativeDetailMaximumZoom: 2,
            visualSettings: .neutral
        )
        let session = MBTilesPackageSession(identity: identity, immutableFile: false)
        defer { session.invalidate(waitForTeardown: true) }
        let bounds = try #require(MBTilesPackageValidator.derivedBounds(
            at: fixture,
            maximumZoom: 2,
            scheme: .tms
        ))
        let coverage = try #require(MBTilesGeographicCoverage.mapRect(from: bounds))
        let underlay = DistrictMapBackstopOverlay(
            slug: "fixture",
            identity: identity,
            packageSession: session,
            boundingMapRect: coverage
        )

        let outside = MKMapRect(
            x: MKMapRect.world.width * 0.75,
            y: MKMapRect.world.height * 0.75,
            width: 1_024,
            height: 1_024
        )
        let outsideResult = await withCheckedContinuation { continuation in
            underlay.prepareVisibleCoverage(in: outside) { resolved, images in
                continuation.resume(returning: (resolved, images))
            }
        }
        #expect(outsideResult.0 == 0)
        #expect(outsideResult.1 == 0)

        let visibleResult = await withCheckedContinuation { continuation in
            underlay.prepareVisibleCoverage(in: coverage) { resolved, images in
                continuation.resume(returning: (resolved, images))
            }
        }
        #expect(visibleResult.0 == 2)
        #expect(visibleResult.1 == 2)
        #expect(underlay.isActive)
        let upperCoordinate = try #require(MBTilesTileCoordinate(z: 2, x: 1, y: 0))
        let lowerCoordinate = try #require(MBTilesTileCoordinate(z: 2, x: 1, y: 1))
        #expect(session.cachedBackstopImage(for: upperCoordinate) != nil)
        #expect(session.cachedBackstopImage(for: lowerCoordinate) != nil)
    }

    @Test func nativeUnderlayTreatsFullyResolvedSparseCoverageAsReady() async throws {
        let fixture = try Self.makeFixture(
            scheme: .tms,
            includeIndex: true,
            nativeOnlyTileAtZoomTwo: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let identity = MBTilesOverlayIdentity(
            role: .district,
            packageIdentifier: "sparse-fixture",
            packageVersion: UUID().uuidString,
            fileURL: fixture,
            minimumZoom: 2,
            maximumZoom: 2,
            nativeDetailMaximumZoom: 2,
            maximumFallbackDepth: 6,
            visualSettings: .neutral
        )
        let session = MBTilesPackageSession(identity: identity, immutableFile: false)
        defer { session.invalidate(waitForTeardown: true) }
        let missingCoordinate = try #require(MBTilesTileCoordinate(z: 2, x: 1, y: 1))
        let missingTileRect = MBTilesViewportTilePlanner.mapRect(for: missingCoordinate)
        let underlay = DistrictMapBackstopOverlay(
            slug: "sparse-fixture",
            identity: identity,
            packageSession: session,
            boundingMapRect: missingTileRect
        )

        let readiness = await withCheckedContinuation { continuation in
            underlay.prepareVisibleCoverageReadiness(in: missingTileRect) {
                continuation.resume(returning: $0)
            }
        }

        #expect(readiness.expectedCount == 1)
        #expect(readiness.resolvedCount == 1)
        #expect(readiness.imageCount == 0)
        #expect(readiness.coversFullVisibleArea)
        #expect(readiness.isReady)
        #expect(session.isKnownMissingBackstopImage(for: missingCoordinate))
    }

    @Test func cacheIdentityPreventsVersionContamination() async throws {
        let fixtureA = try Self.makeFixture(scheme: .tms, includeIndex: true, solidColor: SIMD4(255, 0, 0, 255))
        let fixtureB = try Self.makeFixture(scheme: .tms, includeIndex: true, solidColor: SIMD4(0, 255, 0, 255))
        defer {
            try? FileManager.default.removeItem(at: fixtureA.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: fixtureB.deletingLastPathComponent())
        }
        let path = MKTileOverlayPath(x: 0, y: 0, z: 0, contentScaleFactor: 1)
        let firstSession = Self.session(for: fixtureA, version: "v1")
        let secondSession = Self.session(for: fixtureB, version: "v2")
        defer {
            firstSession.invalidate(waitForTeardown: true)
            secondSession.invalidate(waitForTeardown: true)
        }
        let first = try #require(await Self.load(session: firstSession, path: path).0)
        let second = try #require(await Self.load(session: secondSession, path: path).0)
        #expect(try Self.centerPixel(in: first).x > 250)
        #expect(try Self.centerPixel(in: second).y > 250)
    }

    @Test func corruptTileFailureIsNotPermanentlyNegativeCached() async throws {
        let fixture = try Self.makeFixture(scheme: .tms, includeIndex: true, corruptRootTile: true)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let session = Self.session(for: fixture, version: UUID().uuidString)
        defer { session.invalidate(waitForTeardown: true) }
        let path = MKTileOverlayPath(x: 0, y: 0, z: 0, contentScaleFactor: 1)
        let first = await Self.load(session: session, path: path)
        let second = await Self.load(session: session, path: path)
        #expect(first.0 == nil && first.1 is MBTilesError)
        #expect(second.0 == nil && second.1 is MBTilesError)
        #expect(session.underlyingLookupCount == 2)
        #expect(session.inFlightCount == 0)
    }

    @Test func invalidatedProviderStillCompletesNewCallbacks() async throws {
        let fixture = try Self.makeFixture(scheme: .tms, includeIndex: true)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let session = Self.session(for: fixture, version: UUID().uuidString)
        session.invalidate(waitForTeardown: true)
        let response = await Self.load(session: session, path: MKTileOverlayPath(x: 0, y: 0, z: 0, contentScaleFactor: 1))
        #expect(response.0 == nil)
        #expect(response.1 is MBTilesError)
        #expect(session.inFlightCount == 0)
    }

    @Test func repeatedInvalidationCanSynchronouslyJoinSQLiteTeardown() async throws {
        let fixture = try Self.makeFixture(scheme: .tms, includeIndex: true)
        let directory = fixture.deletingLastPathComponent()
        let session = Self.session(for: fixture, version: UUID().uuidString)
        _ = await Self.load(
            session: session,
            path: MKTileOverlayPath(x: 0, y: 0, z: 0, contentScaleFactor: 1)
        )

        session.invalidate()
        session.invalidate(waitForTeardown: true)
        try FileManager.default.removeItem(at: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func invalidationAndMemoryPressureCompleteConcurrentCallbacksWithoutPoisoningNewVersion() async throws {
        let fixture = try Self.makeFixture(scheme: .tms, includeIndex: true)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let oldSession = Self.session(for: fixture, version: "old-\(UUID())")
        defer { oldSession.invalidate(waitForTeardown: true) }
        let path = MKTileOverlayPath(x: 0, y: 0, z: 0, contentScaleFactor: 1)
        let requests = Task {
            await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for _ in 0..<100 {
                    group.addTask {
                        let response = await Self.load(session: oldSession, path: path)
                        return response.0 != nil || response.1 != nil
                    }
                }
                var completions = 0
                for await didComplete in group where didComplete { completions += 1 }
                return completions
            }
        }
        await Task.yield()
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        oldSession.invalidate(waitForTeardown: true)
        #expect(await requests.value == 100)
        #expect(oldSession.inFlightCount == 0)

        let newSession = Self.session(for: fixture, version: "new-\(UUID())")
        defer { newSession.invalidate(waitForTeardown: true) }
        let newResponse = await Self.load(session: newSession, path: path)
        #expect(newResponse.0 != nil)
        #expect(newResponse.1 == nil)
    }

    @Test func memoryWarningPurgesDecodedAndGeneratedFallbackCaches() async throws {
        let fixture = try Self.makeFixture(scheme: .tms, includeIndex: true)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let session = Self.session(for: fixture, version: UUID().uuidString)
        defer { session.invalidate(waitForTeardown: true) }
        let response = await Self.load(session: session, path: MKTileOverlayPath(x: 1, y: 1, z: 1, contentScaleFactor: 1))
        #expect(response.0 != nil)
        let before = MBTilesOverlay.diagnosticSnapshot()
        #expect(before.generatedCost > 0)
        #expect(before.decodedCost > 0)
        let profile = MBTilesResourceProfile.current()
        let retainedContinuityLimit = min(
            8 * 1_024 * 1_024,
            (profile.continuityCacheBytes * 2) / 3
        )
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        let maintenanceFinished = await Self.waitUntil {
            let snapshot = MBTilesOverlay.diagnosticSnapshot()
            return snapshot.generatedCost == 0
                && snapshot.decodedCost <= retainedContinuityLimit
                && snapshot.compressedCost <= snapshot.compressedLimit / 4
                && snapshot.negativeItems == 0
        }
        let after = MBTilesOverlay.diagnosticSnapshot()
        let workLimits = MBTilesWorkScheduler.shared.snapshot()
        #expect(maintenanceFinished)
        #expect(after.generatedCost == 0)
        // The decoded source tier is cleared. The aggregate diagnostic can still
        // contain the separately-budgeted continuity tier's last-good native parents.
        #expect(after.decodedCost <= retainedContinuityLimit)
        #expect(after.compressedCost <= after.compressedLimit / 4)
        #expect(after.negativeItems == 0)
        #expect(after.activeWork <= workLimits.maximumActive)
        #expect(after.queuedWork <= workLimits.maximumQueued)
    }

    @MainActor
    @Test func reconciliationIsIdempotentAcrossOneThousandUpdates() {
        let url = URL(fileURLWithPath: "/tmp/reconcile.mbtiles")
        let first = MBTilesOverlayIdentity(role: .district, packageIdentifier: "egegik", packageVersion: "v1", fileURL: url)
        let shoreline = MBTilesOverlayIdentity(role: .shoreline, packageIdentifier: "egegik_to_ugashik_shoreline", packageVersion: "v1", fileURL: URL(fileURLWithPath: "/tmp/shoreline.mbtiles"))
        var installed: Set<MBTilesOverlayIdentity> = [first, shoreline]
        var additions = 0
        var removals = 0
        var reorders = 0
        let rendererCreations = 0
        let reloads = 0
        let opacity = MapRendererOpacityController()
        let renderer = OpacitySpy(alpha: 0.65)
        _ = opacity.apply(0.65, to: renderer)
        let opacityBefore = opacity.snapshot()

        for _ in 0..<1_000 {
            let plan = MBTilesOverlayReconciliationPlan(current: installed, desired: [first, shoreline])
            additions += plan.additions.count
            removals += plan.removals.count
            installed.formUnion(plan.additions)
            installed.subtract(plan.removals)
            if !plan.isNoOp { reorders += 1 }
            _ = opacity.apply(0.65, to: renderer)
        }
        #expect(installed == [first, shoreline])
        #expect(additions == 0)
        #expect(removals == 0)
        #expect(reorders == 0)
        #expect(rendererCreations == 0)
        #expect(reloads == 0)
        #expect(opacity.snapshot().writes == opacityBefore.writes)

        let second = MBTilesOverlayIdentity(role: .district, packageIdentifier: "egegik", packageVersion: "v2", fileURL: URL(fileURLWithPath: "/tmp/reconcile-v2.mbtiles"))
        let change = MBTilesOverlayReconciliationPlan(current: installed, desired: [second, shoreline])
        #expect(change.additions == [second])
        #expect(change.removals == [first])
        #expect(!change.removals.contains(shoreline))
    }

    @MainActor
    @Test func oneThousandContinuousCameraCallbacksPerformNoMapMutations() {
        let coordinator = Self.makeMapCoordinator()
        defer { coordinator.prepareForDismantle() }
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        Self.retainedMapViews.append(mapView)
        coordinator.mapView = mapView
        let diagnosticsBefore = MapStabilityDiagnostics.shared.snapshot()
        let opacityBefore = coordinator.rendererOpacityController.snapshot()
        let attachmentsBefore = coordinator.overlayAttachmentCount
        let removalsBefore = coordinator.overlayRemovalCount
        let renderersBefore = coordinator.rendererCreationCount
        let reloadsBefore = coordinator.reloadDataCallCount

        var measuredTotalNanoseconds: UInt64 = 0
        var measuredMaximumNanoseconds: UInt64 = 0
        for _ in 0..<1_000 {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            coordinator.mapViewDidChangeVisibleRegion(mapView)
            let duration = DispatchTime.now().uptimeNanoseconds &- startedAt
            measuredTotalNanoseconds &+= duration
            measuredMaximumNanoseconds = max(measuredMaximumNanoseconds, duration)
        }

        let diagnosticsAfter = MapStabilityDiagnostics.shared.snapshot()
        #expect(coordinator.overlayAttachmentCount == attachmentsBefore)
        #expect(coordinator.overlayRemovalCount == removalsBefore)
        #expect(coordinator.rendererCreationCount == renderersBefore)
        #expect(coordinator.reloadDataCallCount == reloadsBefore)
        #expect(coordinator.rendererOpacityController.snapshot() == opacityBefore)
        #expect(diagnosticsAfter.overlayAdditions == diagnosticsBefore.overlayAdditions)
        #expect(diagnosticsAfter.overlayRemovals == diagnosticsBefore.overlayRemovals)
        #expect(diagnosticsAfter.overlayReorders == diagnosticsBefore.overlayReorders)
        #expect(diagnosticsAfter.rendererCreations == diagnosticsBefore.rendererCreations)
        #expect(diagnosticsAfter.reloadDataCalls == diagnosticsBefore.reloadDataCalls)
        #expect(diagnosticsAfter.alphaWrites == diagnosticsBefore.alphaWrites)
        #expect(diagnosticsAfter.visibleRegionCount - diagnosticsBefore.visibleRegionCount == 1_000)
        #expect(measuredMaximumNanoseconds < 100_000_000)
        print(
            "MAP_STABILITY_1000_CALLBACKS totalUs=\(measuredTotalNanoseconds / 1_000) "
                + "averageUs=\(measuredTotalNanoseconds / 1_000_000) "
                + "maxUs=\(measuredMaximumNanoseconds / 1_000)"
        )
    }

    @MainActor
    @Test func lateVisibleRegionCallbackStillReachesOneSettledCommit() async {
        let coordinator = Self.makeMapCoordinator()
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        Self.retainedMapViews.append(mapView)
        mapView.mapType = .satellite
        coordinator.basemapChoice = .appleSatellite
        coordinator.mapView = mapView

        coordinator.mapView(mapView, regionWillChangeAnimated: false)
        coordinator.mapView(mapView, regionDidChangeAnimated: false)
        // Reproduce the problematic ordering: the final visible callback arrives
        // after did-change and must replace, not merely cancel, the pending settle.
        coordinator.mapViewDidChangeVisibleRegion(mapView)
        #expect(coordinator.isCameraMovementActive)

        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(!coordinator.isCameraMovementActive)
        coordinator.prepareForDismantle()

        // Queued recognizer/delegate callbacks after teardown are harmless and
        // cannot reactivate the camera lifecycle.
        coordinator.mapViewDidChangeVisibleRegion(mapView)
        #expect(!coordinator.isCameraMovementActive)
    }

    @MainActor
    @Test func rendererOpacityIsClampedIdempotentAndPreservesIdentity() {
        let controller = MapRendererOpacityController()
        let renderer = OpacitySpy(alpha: 1)
        let identity = ObjectIdentifier(renderer)

        #expect(controller.apply(0.5, to: renderer))
        #expect(!controller.apply(0.5, to: renderer))
        #expect(!controller.apply(0.5 + MapRendererOpacityController.epsilon / 2, to: renderer))
        #expect(controller.apply(2, to: renderer))
        #expect(renderer.alpha == 1)
        #expect(ObjectIdentifier(renderer) == identity)
        #expect(controller.snapshot() == .init(attempts: 4, writes: 2, trackedRenderers: 1))
    }

    @Test func cameraEqualityAndFeedbackGuardSuppressLoops() {
        let current = MapCameraState(
            latitude: 58.70,
            longitude: -157.00,
            zoom: 12,
            heading: 0,
            pitch: 0
        )
        let effectivelyEqual = MapCameraState(
            latitude: current.latitude + 0.000_001,
            longitude: current.longitude,
            zoom: current.zoom + 0.000_5,
            heading: 359.95,
            pitch: 0.05
        )
        let requested = MapCameraState(
            latitude: 58.71,
            longitude: -157.01,
            zoom: 13,
            heading: 0,
            pitch: 0
        )
        var guardState = MapCameraFeedbackGuard()

        #expect(current.isEffectivelyEqual(to: effectivelyEqual))
        let equalRequestWasApplied = guardState.shouldApplyProgrammaticRequest(
            effectivelyEqual,
            current: current
        )
        let changedRequestWasApplied = guardState.shouldApplyProgrammaticRequest(
            requested,
            current: current
        )
        let duplicateRequestWasApplied = guardState.shouldApplyProgrammaticRequest(
            requested,
            current: current
        )
        let changedEmissionWasPublished = guardState.recordMapKitEmission(requested)
        let duplicateEmissionWasPublished = guardState.recordMapKitEmission(requested)
        let currentEmissionWasPublished = guardState.recordMapKitEmission(current)
        let requestAfterFeedbackWasApplied = guardState.shouldApplyProgrammaticRequest(
            requested,
            current: current
        )

        #expect(!equalRequestWasApplied)
        #expect(changedRequestWasApplied)
        #expect(!duplicateRequestWasApplied)
        #expect(changedEmissionWasPublished)
        #expect(!duplicateEmissionWasPublished)
        #expect(currentEmissionWasPublished)
        #expect(requestAfterFeedbackWasApplied)
    }

    @Test func newerMovementGenerationInvalidatesOlderSettledWork() throws {
        var gate = MapSettledUpdateGate()
        let first = gate.beginMovement()
        #expect(gate.consumeSettledGeneration() == first)
        #expect(gate.consumeSettledGeneration() == nil)

        let second = gate.beginMovement()
        #expect(second != first)
        #expect(!gate.isCurrent(first))
        #expect(gate.isCurrent(second))
        gate.noteContinuousMovement()
        #expect(gate.consumeSettledGeneration() == second)
    }

    @Test func appearanceAndNativeDetailArePartOfImmutableTileIdentity() {
        let url = URL(fileURLWithPath: "/tmp/egegik-v2.mbtiles")
        let neutral = MBTilesOverlayIdentity(
            role: .district,
            packageIdentifier: "egegik",
            packageVersion: "v2",
            fileURL: url,
            maximumZoom: 17,
            nativeDetailMaximumZoom: 15,
            maximumFallbackDepth: 6,
            visualSettings: .neutral
        )
        let adjusted = MBTilesOverlayIdentity(
            role: .district,
            packageIdentifier: "egegik",
            packageVersion: "v2",
            fileURL: url,
            maximumZoom: 17,
            nativeDetailMaximumZoom: 15,
            maximumFallbackDepth: 6,
            visualSettings: DistrictMapVisualSettings(
                brightness: 0.08,
                contrast: 1.20,
                gamma: 0.88,
                saturation: 1.08
            )
        )

        #expect(neutral != adjusted)
        #expect(neutral.maximumZoom == 17)
        #expect(neutral.nativeDetailMaximumZoom == 15)
        #expect(neutral.maximumFallbackDepth >= 2)
    }

    @Test func adjustedAndNeutralTileBytesCannotCollideInCache() async throws {
        let fixture = try Self.makeFixture(
            scheme: .tms,
            includeIndex: true,
            solidColor: SIMD4(90, 110, 130, 255)
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let commonVersion = UUID().uuidString
        let neutralIdentity = MBTilesOverlayIdentity(
            role: .district,
            packageIdentifier: "fixture",
            packageVersion: commonVersion,
            fileURL: fixture,
            visualSettings: .neutral
        )
        let adjustedIdentity = MBTilesOverlayIdentity(
            role: .district,
            packageIdentifier: "fixture",
            packageVersion: commonVersion,
            fileURL: fixture,
            visualSettings: DistrictMapVisualSettings(
                brightness: 0.15,
                contrast: 1.38,
                gamma: 0.78,
                saturation: 1.12
            )
        )
        let neutralSession = MBTilesPackageSession(identity: neutralIdentity, immutableFile: false)
        let adjustedSession = MBTilesPackageSession(identity: adjustedIdentity, immutableFile: false)
        defer {
            neutralSession.invalidate(waitForTeardown: true)
            adjustedSession.invalidate(waitForTeardown: true)
        }
        let path = MKTileOverlayPath(x: 0, y: 0, z: 0, contentScaleFactor: 1)
        let neutralData = try #require(await Self.load(session: neutralSession, path: path).0)
        let adjustedData = try #require(await Self.load(session: adjustedSession, path: path).0)
        let neutralPixel = try Self.centerPixel(in: neutralData)
        let adjustedPixel = try Self.centerPixel(in: adjustedData)

        #expect(neutralData != adjustedData)
        #expect(neutralPixel != adjustedPixel)
    }

    @Test func validatorRequiresAnIndexedCoordinateLookup() async throws {
        let valid = try Self.makeFixture(scheme: .tms, includeIndex: true)
        let unindexed = try Self.makeFixture(scheme: .tms, includeIndex: false)
        defer {
            try? FileManager.default.removeItem(at: valid.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: unindexed.deletingLastPathComponent())
        }
        let receipt = try await Task.detached {
            try MBTilesPackageValidator.validate(at: valid, expectation: .init(packageIdentifier: "fixture", version: "v1"))
        }.value
        #expect(receipt.tileCount >= 1)
        #expect(receipt.scheme == .tms)

        await #expect(throws: MBTilesValidationError.self) {
            try await Task.detached {
                try MBTilesPackageValidator.validate(at: unindexed, expectation: .init(packageIdentifier: "fixture", version: "v1"))
            }.value
        }
    }

    @Test func normalizedTilesImagesSchemaValidatesAndLoadsThroughTheRuntimeReader() async throws {
        let fixture = try Self.makeFixture(
            scheme: .tms,
            includeIndex: true,
            solidColor: SIMD4(12, 34, 56, 255),
            normalizedSchema: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let receipt = try await Task.detached {
            try MBTilesPackageValidator.validate(
                at: fixture,
                expectation: .init(packageIdentifier: "fixture", version: "normalized")
            )
        }.value
        #expect(receipt.tileCount == 1)
        #expect(receipt.queryPlan.lowercased().contains("search tiles"))
        #expect(receipt.queryPlan.lowercased().contains("search images"))

        let session = Self.session(for: fixture, version: "normalized-\(UUID())")
        defer { session.invalidate(waitForTeardown: true) }
        let response = await Self.load(
            session: session,
            path: MKTileOverlayPath(x: 0, y: 0, z: 0, contentScaleFactor: 1)
        )
        let pixel = try Self.centerPixel(in: #require(response.0))
        #expect(response.1 == nil)
        #expect(abs(Int(pixel.x) - 12) <= 2)
        #expect(abs(Int(pixel.y) - 34) <= 2)
        #expect(abs(Int(pixel.z) - 56) <= 2)
        #expect(pixel.w == 255)
    }

    @Test func validatorDerivesTheSameCanonicalBoundsForTMSAndXYZPackages() async throws {
        let tms = try Self.makeFixture(
            scheme: .tms,
            includeIndex: true,
            includeZoomTwoCoverageTiles: true
        )
        let xyz = try Self.makeFixture(
            scheme: .xyz,
            includeIndex: true,
            includeZoomTwoCoverageTiles: true
        )
        defer {
            try? FileManager.default.removeItem(at: tms.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: xyz.deletingLastPathComponent())
        }

        let receipts = try await Task.detached { () -> (MBTilesValidationReceipt, MBTilesValidationReceipt) in
            let tmsReceipt = try MBTilesPackageValidator.validate(
                at: tms,
                expectation: .init(packageIdentifier: "fixture", version: "tms")
            )
            let xyzReceipt = try MBTilesPackageValidator.validate(
                at: xyz,
                expectation: .init(packageIdentifier: "fixture", version: "xyz")
            )
            return (tmsReceipt, xyzReceipt)
        }.value
        let tmsBounds = try #require(receipts.0.bounds)
        let xyzBounds = try #require(receipts.1.bounds)
        let expected = [-90.0, 0.0, 0.0, 85.051_128_78]

        #expect(receipts.0.scheme == .tms)
        #expect(receipts.1.scheme == .xyz)
        for index in expected.indices {
            #expect(abs(tmsBounds[index] - expected[index]) < 0.000_001)
            #expect(abs(xyzBounds[index] - expected[index]) < 0.000_001)
            #expect(abs(tmsBounds[index] - xyzBounds[index]) < 0.000_001)
        }

        let compatibilityBounds = try #require(MBTilesPackageValidator.derivedBounds(
            at: tms,
            maximumZoom: 2,
            scheme: .tms
        ))
        #expect(compatibilityBounds.count == expected.count)
        for index in expected.indices {
            #expect(abs(compatibilityBounds[index] - expected[index]) < 0.000_001)
        }
        let mapRect = try #require(MBTilesGeographicCoverage.mapRect(from: tmsBounds))
        let expectedMapRect = try #require(MBTilesGeographicCoverage.mapRect(from: expected))
        #expect(abs(mapRect.minX - expectedMapRect.minX) < 1)
        #expect(abs(mapRect.minY - expectedMapRect.minY) < 1)
        #expect(abs(mapRect.width - expectedMapRect.width) < 1)
        #expect(abs(mapRect.height - expectedMapRect.height) < 1)
    }

    @Test func validatorUsesNativeTileEnvelopeAndRejectsUnrelatedDeclaredBounds() async throws {
        let broad = try Self.makeFixture(
            scheme: .tms,
            includeIndex: true,
            includeZoomTwoCoverageTiles: true,
            boundsMetadata: "-180,-85,180,85"
        )
        let unrelated = try Self.makeFixture(
            scheme: .tms,
            includeIndex: true,
            includeZoomTwoCoverageTiles: true,
            boundsMetadata: "10,10,20,20"
        )
        defer {
            try? FileManager.default.removeItem(at: broad.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: unrelated.deletingLastPathComponent())
        }

        let receipt = try await Task.detached {
            try MBTilesPackageValidator.validate(
                at: broad,
                expectation: .init(packageIdentifier: "fixture", version: "broad")
            )
        }.value
        let bounds = try #require(receipt.bounds)
        let expected = [-90.0, 0.0, 0.0, 85.051_128_78]
        for index in expected.indices {
            #expect(abs(bounds[index] - expected[index]) < 0.000_001)
        }

        await #expect(throws: MBTilesValidationError.self) {
            try await Task.detached {
                try MBTilesPackageValidator.validate(
                    at: unrelated,
                    expectation: .init(packageIdentifier: "fixture", version: "unrelated")
                )
            }.value
        }
    }

    @Test func legacyReceiptWithoutCoverageEnvelopeVersionRemainsDecodable() async throws {
        let fixture = try Self.makeFixture(
            scheme: .tms,
            includeIndex: true,
            nativeOnlyTileAtZoomTwo: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let receipt = try await Task.detached {
            try MBTilesPackageValidator.validate(
                at: fixture,
                expectation: .init(packageIdentifier: "fixture", version: "legacy-receipt")
            )
        }.value
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt))
                as? [String: Any]
        )
        object.removeValue(forKey: "coverageEnvelopeVersion")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(MBTilesValidationReceipt.self, from: legacyData)

        #expect(decoded.bounds == receipt.bounds)
        #expect(decoded.coverageEnvelopeVersion == nil)
    }

    @Test func validatorRejectsCorruptImagesDuplicateCoordinatesAndInvalidCoordinates() async throws {
        let corrupt = try Self.makeFixture(scheme: .tms, includeIndex: true, corruptRootTile: true)
        let duplicate = try Self.makeFixture(scheme: .tms, includeIndex: false, duplicateRootTile: true)
        let invalidCoordinate = try Self.makeFixture(scheme: .tms, includeIndex: true, includeInvalidCoordinate: true)
        defer {
            try? FileManager.default.removeItem(at: corrupt.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: duplicate.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: invalidCoordinate.deletingLastPathComponent())
        }

        for (url, version) in [(corrupt, "corrupt"), (duplicate, "duplicate"), (invalidCoordinate, "invalid-coordinate")] {
            await #expect(throws: MBTilesValidationError.self) {
                try await Task.detached {
                    try MBTilesPackageValidator.validate(
                        at: url,
                        expectation: .init(packageIdentifier: "fixture", version: version)
                    )
                }.value
            }
        }
    }

    @Test func validatorAcceptsSquare512JPEGAndRejectsNonSquareRasterTiles() async throws {
        let jpeg512 = try Self.makeFixture(
            scheme: .tms,
            includeIndex: true,
            solidColor: SIMD4(70, 110, 150, 255),
            tileWidth: 512,
            tileHeight: 512,
            tileFormat: "jpg"
        )
        let nonSquare = try Self.makeFixture(
            scheme: .tms,
            includeIndex: true,
            tileWidth: 512,
            tileHeight: 256,
            tileFormat: "png"
        )
        defer {
            try? FileManager.default.removeItem(at: jpeg512.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: nonSquare.deletingLastPathComponent())
        }

        let receipt = try await Task.detached {
            try MBTilesPackageValidator.validate(
                at: jpeg512,
                expectation: .init(packageIdentifier: "fixture", version: "jpeg-512")
            )
        }.value
        #expect(receipt.tileFormat == "jpeg")
        #expect(receipt.tileWidth == 512)
        #expect(receipt.tileHeight == 512)

        await #expect(throws: MBTilesValidationError.self) {
            try await Task.detached {
                try MBTilesPackageValidator.validate(
                    at: nonSquare,
                    expectation: .init(packageIdentifier: "fixture", version: "non-square")
                )
            }.value
        }
    }

    @Test func validatorRejectsTruncatedAndMalformedSQLite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mbtiles-invalid-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let truncated = directory.appendingPathComponent("truncated.mbtiles")
        try Data("SQLite format 3\0partial".utf8).write(to: truncated)
        let malformed = directory.appendingPathComponent("malformed.mbtiles")
        var database: OpaquePointer?
        guard sqlite3_open(malformed.path, &database) == SQLITE_OK, let database else { throw FixtureError.sqlite }
        guard sqlite3_exec(database, "CREATE TABLE metadata(name TEXT,value TEXT);", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw FixtureError.sqlite
        }
        sqlite3_close(database)

        for (url, version) in [(truncated, "truncated"), (malformed, "malformed")] {
            await #expect(throws: MBTilesValidationError.self) {
                try await Task.detached {
                    try MBTilesPackageValidator.validate(
                        at: url,
                        expectation: .init(packageIdentifier: "fixture", version: version)
                    )
                }.value
            }
        }
    }

    @Test func failedVersionActivationPreservesPreviousKnownGoodPackage() async throws {
        let slug = "fixture_\(UUID().uuidString.lowercased())"
        let firstFixture = try Self.makeFixture(scheme: .tms, includeIndex: true, solidColor: SIMD4(255, 0, 0, 255), packageName: slug)
        let secondFixture = try Self.makeFixture(scheme: .tms, includeIndex: true, solidColor: SIMD4(0, 255, 0, 255), packageName: slug)
        let packageRoot = try await Task.detached { try OfflineMapStorage.rootURL().appendingPathComponent(slug, isDirectory: true) }.value
        defer {
            try? FileManager.default.removeItem(at: firstFixture.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondFixture.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: packageRoot)
        }

        let firstRecord = try await Task.detached {
            let staged = try OfflineMapStorage.stageCopy(of: firstFixture, slug: slug)
            return try OfflineMapStorage.validateAndActivate(
                stagedFile: staged,
                expectation: .init(packageIdentifier: slug, version: "v1"),
                authoritativeSHA256: false
            )
        }.value
        #expect(FileManager.default.fileExists(atPath: firstRecord.url.path))

        var rejected = false
        do {
            _ = try await Task.detached {
                let staged = try OfflineMapStorage.stageCopy(of: secondFixture, slug: slug)
                return try OfflineMapStorage.validateAndActivate(
                    stagedFile: staged,
                    expectation: .init(packageIdentifier: slug, version: "v2", expectedSHA256: String(repeating: "0", count: 64)),
                    authoritativeSHA256: true
                )
            }.value
        } catch {
            rejected = true
        }
        #expect(rejected)

        let discovered = try await Task.detached { try OfflineMapStorage.discoverAndMigrateLegacy() }.value
        let active = try #require(discovered.first(where: { $0.slug == slug }))
        #expect(active.url == firstRecord.url)
        #expect(FileManager.default.fileExists(atPath: firstRecord.url.path))
    }

    @Test func successfulActivationIsAtomicAndRetainsThePreviousVersion() async throws {
        let slug = "fixture_\(UUID().uuidString.lowercased())"
        let firstFixture = try Self.makeFixture(scheme: .tms, includeIndex: true, solidColor: SIMD4(255, 0, 0, 255), packageName: slug)
        let secondFixture = try Self.makeFixture(scheme: .tms, includeIndex: true, solidColor: SIMD4(0, 255, 0, 255), packageName: slug)
        let packageRoot = try await Task.detached { try OfflineMapStorage.rootURL().appendingPathComponent(slug, isDirectory: true) }.value
        defer {
            try? FileManager.default.removeItem(at: firstFixture.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondFixture.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: packageRoot)
        }

        let records = try await Task.detached { () -> (InstalledMBTilesRecord, InstalledMBTilesRecord) in
            let firstStage = try OfflineMapStorage.stageCopy(of: firstFixture, slug: slug)
            let first = try OfflineMapStorage.validateAndActivate(
                stagedFile: firstStage,
                expectation: .init(packageIdentifier: slug, version: "v1"),
                authoritativeSHA256: false
            )
            let secondStage = try OfflineMapStorage.stageCopy(of: secondFixture, slug: slug)
            let second = try OfflineMapStorage.validateAndActivate(
                stagedFile: secondStage,
                expectation: .init(packageIdentifier: slug, version: "v2"),
                authoritativeSHA256: false
            )
            return (first, second)
        }.value

        #expect(records.0.url != records.1.url)
        #expect(FileManager.default.fileExists(atPath: records.0.url.path))
        #expect(FileManager.default.fileExists(atPath: records.1.url.path))
        let discovered = try await Task.detached { try OfflineMapStorage.discoverAndMigrateLegacy() }.value
        #expect(discovered.first(where: { $0.slug == slug })?.url == records.1.url)
    }

    @Test func corruptActiveDescriptorRecoversKnownGoodAndIgnoresIncompleteStage() async throws {
        let slug = "fixture_\(UUID().uuidString.lowercased())"
        let fixture = try Self.makeFixture(scheme: .tms, includeIndex: true, packageName: slug)
        let root = try await Task.detached { try OfflineMapStorage.rootURL() }.value
        let packageRoot = root.appendingPathComponent(slug, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: packageRoot)
        }

        let installed = try await Task.detached { () -> InstalledMBTilesRecord in
            let stage = try OfflineMapStorage.stageCopy(of: fixture, slug: slug)
            return try OfflineMapStorage.validateAndActivate(
                stagedFile: stage,
                expectation: .init(packageIdentifier: slug, version: "v1"),
                authoritativeSHA256: false
            )
        }.value
        let incompleteStage = try await Task.detached { try OfflineMapStorage.stageCopy(of: fixture, slug: "\(slug)_incomplete") }.value
        defer { try? FileManager.default.removeItem(at: incompleteStage.deletingLastPathComponent()) }
        try Data("not a descriptor".utf8).write(to: packageRoot.appendingPathComponent("active.json"), options: .atomic)

        let recovered = try await Task.detached { try OfflineMapStorage.discoverAndMigrateLegacy() }.value
        #expect(recovered.first(where: { $0.slug == slug })?.url == installed.url)
        #expect(!recovered.contains(where: { $0.slug == "\(slug)_incomplete" }))
        #expect(FileManager.default.fileExists(atPath: installed.url.path))
    }

    @Test func malformedActiveDescriptorsCannotAliasOrEscapeAnotherPackage() async throws {
        let targetSlug = "fixture_target_\(UUID().uuidString.lowercased())"
        let aliasSlug = "fixture_alias_\(UUID().uuidString.lowercased())"
        let escapeSlug = "fixture_escape_\(UUID().uuidString.lowercased())"
        let fixture = try Self.makeFixture(
            scheme: .tms,
            includeIndex: true,
            packageName: targetSlug
        )
        let roots = try await Task.detached { () -> (URL, URL, URL) in
            let stage = try OfflineMapStorage.stageCopy(of: fixture, slug: targetSlug)
            let installed = try OfflineMapStorage.validateAndActivate(
                stagedFile: stage,
                expectation: .init(packageIdentifier: targetSlug, version: "v1"),
                authoritativeSHA256: false
            )
            let targetRoot = installed.url
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let activeData = try Data(contentsOf: targetRoot.appendingPathComponent("active.json"))
            let root = try OfflineMapStorage.rootURL()
            let aliasRoot = root.appendingPathComponent(aliasSlug, isDirectory: true)
            let escapeRoot = root.appendingPathComponent(escapeSlug, isDirectory: true)
            try FileManager.default.createDirectory(at: aliasRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: escapeRoot, withIntermediateDirectories: true)

            // Copying another package's otherwise-valid descriptor must not alias it
            // under a different package root.
            try activeData.write(
                to: aliasRoot.appendingPathComponent("active.json"),
                options: .atomic
            )

            // A descriptor whose declared identities match its root must still be
            // rejected when its version path attempts to escape that root.
            guard var escapedObject = try JSONSerialization.jsonObject(with: activeData) as? [String: Any],
                  var escapedReceipt = escapedObject["receipt"] as? [String: Any] else {
                throw FixtureError.invalidJSON
            }
            escapedObject["slug"] = escapeSlug
            escapedObject["versionDirectory"] = "../../\(targetSlug)/versions/escaped"
            escapedReceipt["packageIdentifier"] = escapeSlug
            escapedObject["receipt"] = escapedReceipt
            let escapedData = try JSONSerialization.data(withJSONObject: escapedObject)
            try escapedData.write(
                to: escapeRoot.appendingPathComponent("active.json"),
                options: .atomic
            )
            return (targetRoot, aliasRoot, escapeRoot)
        }.value
        defer {
            try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: roots.0)
            try? FileManager.default.removeItem(at: roots.1)
            try? FileManager.default.removeItem(at: roots.2)
        }

        let discovered = try await Task.detached {
            try OfflineMapStorage.discoverAndMigrateLegacy()
        }.value
        #expect(discovered.contains(where: { $0.slug == targetSlug }))
        #expect(!discovered.contains(where: { $0.slug == aliasSlug }))
        #expect(!discovered.contains(where: { $0.slug == escapeSlug }))
    }

    @Test func deletingAPackageInvalidatesReadersForEveryRetainedVersionFirst() async throws {
        let slug = "fixture_\(UUID().uuidString.lowercased())"
        let firstFixture = try Self.makeFixture(
            scheme: .tms,
            includeIndex: true,
            solidColor: SIMD4(255, 0, 0, 255),
            packageName: slug
        )
        let secondFixture = try Self.makeFixture(
            scheme: .tms,
            includeIndex: true,
            solidColor: SIMD4(0, 255, 0, 255),
            packageName: slug
        )
        let packageRoot = try await Task.detached {
            try OfflineMapStorage.rootURL().appendingPathComponent(slug, isDirectory: true)
        }.value
        defer {
            try? FileManager.default.removeItem(at: firstFixture.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondFixture.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: packageRoot)
        }

        let records = try await Task.detached { () -> (InstalledMBTilesRecord, InstalledMBTilesRecord) in
            let firstStage = try OfflineMapStorage.stageCopy(of: firstFixture, slug: slug)
            let first = try OfflineMapStorage.validateAndActivate(
                stagedFile: firstStage,
                expectation: .init(packageIdentifier: slug, version: "v1"),
                authoritativeSHA256: false
            )
            let secondStage = try OfflineMapStorage.stageCopy(of: secondFixture, slug: slug)
            let second = try OfflineMapStorage.validateAndActivate(
                stagedFile: secondStage,
                expectation: .init(packageIdentifier: slug, version: "v2"),
                authoritativeSHA256: false
            )
            return (first, second)
        }.value

        func retainedSession(for record: InstalledMBTilesRecord) -> (
            identity: MBTilesOverlayIdentity,
            session: MBTilesPackageSession
        ) {
            let identity = MBTilesOverlayIdentity(
                role: .district,
                packageIdentifier: slug,
                packageVersion: record.versionIdentity,
                fileURL: record.url,
                minimumZoom: 0,
                maximumZoom: 15
            )
            return (
                identity,
                MBTilesPackageSessionRegistry.shared.session(
                    for: identity,
                    immutableFile: true
                )
            )
        }
        let first = retainedSession(for: records.0)
        let second = retainedSession(for: records.1)
        defer {
            MBTilesPackageSessionRegistry.shared.retire(identity: first.identity)
            MBTilesPackageSessionRegistry.shared.retire(identity: second.identity)
        }
        let path = MKTileOverlayPath(x: 0, y: 0, z: 0, contentScaleFactor: 1)
        #expect(await Self.load(session: first.session, path: path).0 != nil)
        #expect(await Self.load(session: second.session, path: path).0 != nil)

        try await Task.detached {
            try OfflineMapStorage.delete(slugs: [slug], urls: [records.1.url])
        }.value

        #expect(!FileManager.default.fileExists(atPath: packageRoot.path))
        for session in [first.session, second.session] {
            let response = await Self.load(session: session, path: path)
            #expect(response.0 == nil)
            #expect(response.1 is MBTilesError)
        }
    }

    @Test func cancelledValidationCannotPublishAStagedPackage() async throws {
        let slug = "fixture_\(UUID().uuidString.lowercased())"
        let fixture = try Self.makeFixture(
            scheme: .tms,
            includeIndex: true,
            packageName: slug
        )
        let packageRoot = try await Task.detached {
            try OfflineMapStorage.rootURL().appendingPathComponent(slug, isDirectory: true)
        }.value
        let staged = try await Task.detached {
            try OfflineMapStorage.stageCopy(of: fixture, slug: slug)
        }.value
        defer {
            try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: packageRoot)
        }

        let gate = AsyncTestGate()
        let activation = Task.detached { () throws -> InstalledMBTilesRecord in
            await gate.wait()
            return try OfflineMapStorage.validateAndActivate(
                stagedFile: staged,
                expectation: .init(packageIdentifier: slug, version: "cancelled"),
                authoritativeSHA256: false
            )
        }
        activation.cancel()
        await gate.open()

        await #expect(throws: CancellationError.self) {
            _ = try await activation.value
        }
        #expect(!FileManager.default.fileExists(atPath: packageRoot.path))
    }

    @Test func revokedActivationAuthorizationCannotPublishAtTheCommitPoint() async throws {
        let slug = "fixture_\(UUID().uuidString.lowercased())"
        let fixture = try Self.makeFixture(
            scheme: .tms,
            includeIndex: true,
            packageName: slug
        )
        let packageRoot = try await Task.detached {
            try OfflineMapStorage.rootURL().appendingPathComponent(slug, isDirectory: true)
        }.value
        let staged = try await Task.detached {
            try OfflineMapStorage.stageCopy(of: fixture, slug: slug)
        }.value
        let operationID = UUID()
        OfflineMapStorage.authorizeActivation(operationID)
        #expect(OfflineMapStorage.cancelActivation(operationID))
        defer {
            OfflineMapStorage.finishActivationAuthorization(operationID)
            try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: packageRoot)
        }

        await #expect(throws: CancellationError.self) {
            try await Task.detached {
                try OfflineMapStorage.validateAndActivate(
                    stagedFile: staged,
                    expectation: .init(packageIdentifier: slug, version: "cancelled-at-commit"),
                    authoritativeSHA256: false,
                    commitAuthorization: operationID
                )
            }.value
        }

        #expect(!FileManager.default.fileExists(
            atPath: packageRoot.appendingPathComponent("active.json").path
        ))
        let discovered = try await Task.detached {
            try OfflineMapStorage.discoverAndMigrateLegacy()
        }.value
        #expect(!discovered.contains(where: { $0.slug == slug }))
    }

    fileprivate static func session(for url: URL, version: String) -> MBTilesPackageSession {
        let identity = MBTilesOverlayIdentity(
            role: .district,
            packageIdentifier: "fixture",
            packageVersion: version,
            fileURL: url,
            minimumZoom: 0,
            maximumZoom: 15
        )
        return MBTilesPackageSession(identity: identity, immutableFile: false)
    }

    private static func load(session: MBTilesPackageSession, path: MKTileOverlayPath) async -> (Data?, Error?) {
        await withCheckedContinuation { continuation in
            session.load(path: path) { data, error in continuation.resume(returning: (data, error)) }
        }
    }

    private static func load(overlay: MBTilesOverlay, path: MKTileOverlayPath) async -> (Data?, Error?) {
        await withCheckedContinuation { continuation in
            overlay.loadTile(at: path) { data, error in continuation.resume(returning: (data, error)) }
        }
    }

    private static func loadBackstopImage(
        session: MBTilesPackageSession,
        coordinate: MBTilesTileCoordinate
    ) async -> CGImage? {
        await withCheckedContinuation { continuation in
            session.loadBackstopImage(for: coordinate) {
                continuation.resume(returning: $0)
            }
        }
    }

    private static func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: () -> Bool
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private static func wait(
        for semaphore: DispatchSemaphore,
        timeout: TimeInterval
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: semaphore.wait(timeout: .now() + timeout) == .success
                )
            }
        }
    }

    fileprivate static func makeFixture(
        scheme: MBTilesStorageScheme,
        includeIndex: Bool,
        exactZoomOneTopTile: Bool = false,
        includeZoomTwoCoverageTiles: Bool = false,
        solidColor: SIMD4<UInt8>? = nil,
        corruptRootTile: Bool = false,
        omitSchemeMetadata: Bool = false,
        duplicateRootTile: Bool = false,
        includeInvalidCoordinate: Bool = false,
        packageName: String = "fixture",
        tileWidth: Int = 256,
        tileHeight: Int = 256,
        tileFormat: String = "png",
        nativeOnlyTileAtZoomTwo: Bool = false,
        normalizedSchema: Bool = false,
        boundsMetadata: String? = nil
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mbtiles-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fixture.mbtiles")
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw FixtureError.sqlite }
        defer { sqlite3_close(database) }
        let schemaSQL = normalizedSchema
            ? "CREATE TABLE metadata(name TEXT,value TEXT); CREATE TABLE tiles(zoom_level INTEGER,tile_column INTEGER,tile_row INTEGER,tile_id TEXT); CREATE TABLE images(tile_id TEXT PRIMARY KEY,tile_data BLOB);"
            : "CREATE TABLE metadata(name TEXT,value TEXT); CREATE TABLE tiles(zoom_level INTEGER,tile_column INTEGER,tile_row INTEGER,tile_data BLOB);"
        guard sqlite3_exec(database, schemaSQL, nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }
        if includeIndex {
            guard sqlite3_exec(database, "CREATE UNIQUE INDEX tile_index ON tiles(zoom_level,tile_column,tile_row);", nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }
        } else if duplicateRootTile {
            guard sqlite3_exec(database, "CREATE INDEX tile_index ON tiles(zoom_level,tile_column,tile_row);", nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }
        }
        try insertMetadata(database, name: "name", value: packageName)
        if !omitSchemeMetadata {
            try insertMetadata(database, name: "scheme", value: scheme.rawValue)
        }
        try insertMetadata(database, name: "format", value: tileFormat)
        if let boundsMetadata {
            try insertMetadata(database, name: "bounds", value: boundsMetadata)
        }
        try insertMetadata(database, name: "minzoom", value: nativeOnlyTileAtZoomTwo ? "2" : "0")
        let maximumZoom = nativeOnlyTileAtZoomTwo
            ? 2
            : (includeZoomTwoCoverageTiles ? 2 : (exactZoomOneTopTile ? 1 : 0))
        try insertMetadata(database, name: "maxzoom", value: String(maximumZoom))
        let rootData = corruptRootTile
            ? Data([0x89, 0x50, 0x4e, 0x47, 0x00])
            : try rasterData(
                width: tileWidth,
                height: tileHeight,
                format: tileFormat,
                solidColor: solidColor
            )
        var nextNormalizedTileID = 0
        func insertFixtureTile(z: Int, x: Int, storedY: Int, data: Data) throws {
            defer { nextNormalizedTileID += 1 }
            try Self.insertTile(
                database,
                z: z,
                x: x,
                storedY: storedY,
                data: data,
                normalizedTileID: normalizedSchema ? "tile-\(nextNormalizedTileID)" : nil
            )
        }
        if nativeOnlyTileAtZoomTwo {
            let storedY = scheme == .tms ? 3 : 0
            try insertFixtureTile(z: 2, x: 0, storedY: storedY, data: rootData)
        } else {
            try insertFixtureTile(z: 0, x: 0, storedY: 0, data: rootData)
        }
        if duplicateRootTile {
            try insertFixtureTile(z: 0, x: 0, storedY: 0, data: rootData)
        }
        if includeInvalidCoordinate {
            try insertFixtureTile(z: 1, x: 2, storedY: 0, data: try pngData(solidColor: SIMD4(10, 20, 30, 255)))
        }
        if exactZoomOneTopTile {
            let storedY = scheme == .tms ? 1 : 0
            try insertFixtureTile(z: 1, x: 0, storedY: storedY, data: try pngData(solidColor: SIMD4(20, 40, 60, 255)))
        }
        if includeZoomTwoCoverageTiles {
            let tileData = try pngData(solidColor: SIMD4(40, 60, 80, 255))
            for canonicalY in 0...1 {
                let storedY = scheme == .tms ? 3 - canonicalY : canonicalY
                try insertFixtureTile(z: 2, x: 1, storedY: storedY, data: tileData)
            }
        }
        return url
    }

    private static func insertMetadata(_ database: OpaquePointer, name: String, value: String) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "INSERT INTO metadata(name,value) VALUES(?,?);", -1, &statement, nil) == SQLITE_OK else { throw FixtureError.sqlite }
        sqlite3_bind_text(statement, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 2, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.sqlite }
    }

    private static func insertTile(
        _ database: OpaquePointer,
        z: Int,
        x: Int,
        storedY: Int,
        data: Data,
        normalizedTileID: String?
    ) throws {
        if let normalizedTileID {
            var imageStatement: OpaquePointer?
            defer { sqlite3_finalize(imageStatement) }
            guard sqlite3_prepare_v2(
                database,
                "INSERT INTO images(tile_id,tile_data) VALUES(?,?);",
                -1,
                &imageStatement,
                nil
            ) == SQLITE_OK else { throw FixtureError.sqlite }
            sqlite3_bind_text(
                imageStatement,
                1,
                normalizedTileID,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
            _ = data.withUnsafeBytes {
                sqlite3_bind_blob(
                    imageStatement,
                    2,
                    $0.baseAddress,
                    Int32(data.count),
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
            guard sqlite3_step(imageStatement) == SQLITE_DONE else { throw FixtureError.sqlite }
        }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO tiles VALUES(?,?,?,?);",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { throw FixtureError.sqlite }
        sqlite3_bind_int(statement, 1, Int32(z))
        sqlite3_bind_int(statement, 2, Int32(x))
        sqlite3_bind_int(statement, 3, Int32(storedY))
        if let normalizedTileID {
            sqlite3_bind_text(
                statement,
                4,
                normalizedTileID,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        } else {
            _ = data.withUnsafeBytes {
                sqlite3_bind_blob(
                    statement,
                    4,
                    $0.baseAddress,
                    Int32(data.count),
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.sqlite }
    }

    private static func pngData(solidColor: SIMD4<UInt8>?) throws -> Data {
        try rasterData(
            width: 256,
            height: 256,
            format: "png",
            solidColor: solidColor
        )
    }

    private static func rasterData(
        width: Int,
        height: Int,
        format: String,
        solidColor: SIMD4<UInt8>?
    ) throws -> Data {
        guard width > 0, height > 0 else { throw FixtureError.image }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = solidColor ?? (y < height / 2
                    ? (x < width / 2 ? SIMD4(255, 0, 0, 255) : SIMD4(0, 255, 0, 255))
                    : (x < width / 2 ? SIMD4(0, 0, 255, 128) : SIMD4(255, 255, 0, 255)))
                let index = (y * width + x) * 4
                pixels[index] = color.x
                pixels[index + 1] = color.y
                pixels[index + 2] = color.z
                pixels[index + 3] = color.w
            }
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let image = pixels.withUnsafeBytes { bytes -> CGImage? in
            guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        let output = NSMutableData()
        let normalizedFormat = format.lowercased()
        let destinationType = (normalizedFormat == "jpg" || normalizedFormat == "jpeg")
            ? "public.jpeg"
            : "public.png"
        guard let image,
              let destination = CGImageDestinationCreateWithData(
                output,
                destinationType as CFString,
                1,
                nil
              ) else { throw FixtureError.image }
        let options: CFDictionary? = destinationType == "public.jpeg"
            ? [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
            : nil
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.image }
        return output as Data
    }

    private static func centerPixel(in data: Data) throws -> SIMD4<UInt8> {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw FixtureError.image }
        return try centerPixel(in: image)
    }

    private static func centerPixel(in image: CGImage) throws -> SIMD4<UInt8> {
        let ciImage = CIImage(cgImage: image)
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.cacheIntermediates: false]).render(
            ciImage,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return SIMD4(pixel[0], pixel[1], pixel[2], pixel[3])
    }

    private enum FixtureError: Error { case sqlite, image, invalidJSON }
}

nonisolated private final class LockedTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }
}

nonisolated private final class LockedTestValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value?

    var value: Value? {
        lock.lock(); defer { lock.unlock() }
        return storedValue
    }

    func store(_ value: Value) {
        lock.lock(); storedValue = value; lock.unlock()
    }
}

nonisolated private final class LockedTestOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Int] = []

    var values: [Int] {
        lock.lock(); defer { lock.unlock() }
        return storedValues
    }

    func append(_ value: Int) {
        lock.lock(); storedValues.append(value); lock.unlock()
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

final class MBTilesPerformanceTests: XCTestCase {
    func testOneHundredWarmCacheCallbacksCPUAndMemory() throws {
        let fixture = try MBTilesHardeningTests.makeFixture(scheme: .tms, includeIndex: true)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let session = MBTilesHardeningTests.session(for: fixture, version: UUID().uuidString)
        let path = MKTileOverlayPath(x: 0, y: 0, z: 0, contentScaleFactor: 1)
        let ready = expectation(description: "warm cache")
        session.load(path: path) { data, error in
            XCTAssertNotNil(data)
            XCTAssertNil(error)
            ready.fulfill()
        }
        wait(for: [ready], timeout: 5)

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {
            var completions = 0
            for _ in 0..<100 {
                session.load(path: path) { data, error in
                    XCTAssertNotNil(data)
                    XCTAssertNil(error)
                    completions += 1
                }
            }
            XCTAssertEqual(completions, 100)
        }
    }
}
