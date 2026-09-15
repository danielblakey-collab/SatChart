import Testing
import Foundation
import MapKit
@testable import SatChart

@MainActor
struct OnlineDistrictMapsTests {
    // Match the renderer tests on this branch: keep MapKit views alive through test teardown.
    private static var retainedMapViews: [MKMapView] = []
    @Test func newVersionsAreDownloadableAndMatchPublishedOnlinePacks() {
        #expect(DistrictID.egegik.packs.compactMap(\.districtMapVersion) == Array(3...7))
        #expect(DistrictID.ugashik.packs.compactMap(\.districtMapVersion) == Array(4...6))
        #expect(DistrictID.togiak.packs.compactMap(\.districtMapVersion) == Array(1...15))
        for source in OnlineDistrictMapCatalog.maps {
            #expect(source.pack.district.packs.contains(source.pack))
            #expect(source.pack.remoteMBTilesFilenameCandidates.first == "\(source.pack.slug).mbtiles")
            #expect(source.pack.previewFilenameCandidates.first == "\(source.pack.slug).jpg")
        }
        #expect(Set(OnlineDistrictMapCatalog.maps.map(\.pack.district)) == [.egegik, .ugashik, .nushagak, .naknek_kvichak])
    }


    @Test func togiakLocalInventoryRecognizesAllSupportedPackageNames() {
        let packs = DistrictID.togiak.packs
        #expect(packs.map(\.slug) == ["togiak"] + (2...15).map { "togiak_v\($0)" })
        #expect(packs.map { $0.previewFilenameCandidates.first } == ["togiak.jpg"] + (2...15).map { "togiak_v\($0).jpg" })
        #expect(packs.map { $0.remoteMBTilesFilenameCandidates.first } == ["togiak.mbtiles"] + (2...15).map { "togiak_v\($0).mbtiles" })
    }

    @Test func onlineVersionSelectionUsesActualVersionsAndWraps() {
        #expect(OnlineDistrictMapCatalog.versions == [3, 4, 5, 6, 7])
        #expect(OnlineDistrictMapCatalog.normalizedVersion(1) == 3)
        #expect(OnlineDistrictMapCatalog.normalizedVersion(99) == 3)
        #expect(OnlineDistrictMapCatalog.nextVersion(after: 4) == 5)
        #expect(OnlineDistrictMapCatalog.nextVersion(after: 7) == 3)
        for version in 4...7 {
            #expect(OnlineDistrictMapCatalog.selectedMaps(version: version).map(\.pack.slug) == ["nushagak_v\(version <= 6 ? version : 3)", "naknek_kvichak_v\(version == 4 ? 4 : 3)", "egegik_v\(version)", "ugashik_v\(version <= 6 ? version : 4)"])
        }
    }

    @Test func nushagakOnlineCoversTheExpandedPublishedFootprint() {
        let southeastFlats = MKMapPoint(CLLocationCoordinate2D(latitude: 58.49, longitude: -158.22))
        for version in 3...6 {
            let source = OnlineDistrictMapCatalog.selectedMaps(version: version)
                .first { $0.pack.district == .nushagak }
            #expect(source?.version == version)
            #expect(source?.tilePrefix == "nushagak_v\(version)_xyz")
            #expect(source?.bounds.contains(southeastFlats) == true)
        }
        #expect(DistrictID.nushagak.packs.compactMap(\.districtMapVersion) == Array(3...6))
    }

    @Test func naknekUploadsResolveWithoutChangingInstalledPackIdentity() throws {
        #expect(DistrictID.naknek_kvichak.packs.compactMap(\.districtMapVersion) == Array(3...4))
        for version in 3...4 {
            let source = try #require(OnlineDistrictMapCatalog.selectedMaps(version: version)
                .first { $0.pack.district == .naknek_kvichak })
            #expect(source.pack.slug == "naknek_kvichak_v\(version)")
            #expect(source.tilePrefix == "naknek_v\(version)_xyz")
            #expect(source.pack.remoteMBTilesFilenameCandidates.contains("naknek_v\(version).mbtiles"))
            #expect(source.pack.previewFilenameCandidates.contains("naknek_v\(version).jpg"))
            #expect(source.pack.remoteMBTilesFilenameCandidates.first == "naknek_kvichak_v\(version).mbtiles")
        }
        let shoreline = OfflinePack(district: .naknek_kvichak, slug: "naknek_to_egegik_shoreline")
        #expect(!shoreline.remoteBasenameCandidates.contains("naknek"))
        #expect(!DistrictID.egegik.defaultPack.remoteBasenameCandidates.contains("naknek"))
    }

    @Test func savedOnlineBasemapPreferenceKeepsWorking() {
        let choice = BasemapDefaultPolicy.choice(rawValue: "bristolBaySatelliteOnline", didMigrate: true)
        #expect(choice == .districtsOnline)
        #expect(choice.label == "Districts Online")
        #expect(BasemapChoice.allCases.filter { $0.label == "Districts Online" }.count == 1)
        #expect(BasemapDefaultPolicy.choice(rawValue: "districtsOffline", didMigrate: true) == .districtsOffline)
        #expect(BasemapLayerPolicy.tileAlpha(for: "egegik_v4", basemapChoice: .districtsOnline,
                                            selectedDistrictMapSlug: "egegik_v4") == 0)
    }

    @Test func xyzURLsDoNotFlipRowsAndCacheKeysSeparateVersions() throws {
        let path = MKTileOverlayPath(x: 16, y: 76, z: 8, contentScaleFactor: 2)
        var keys = Set<String>()
        for source in OnlineDistrictMapCatalog.maps {
            #expect(source.tileURL(for: path).absoluteString.hasSuffix("\(source.tilePrefix)/8/16/76.png"))
            keys.insert(source.cacheKey(for: path))
            let overlay = OnlineDistrictTileOverlay(source: source)
            #expect(overlay.minimumZ == 4 && overlay.maximumZ == 15)
            #expect(!overlay.isGeometryFlipped && !overlay.canReplaceMapContent)
            #expect(overlay.boundingMapRect.origin.x == source.bounds.origin.x)
            #expect(overlay.boundingMapRect.origin.y == source.bounds.origin.y)
            #expect(overlay.boundingMapRect.size.width == source.bounds.size.width)
            #expect(overlay.boundingMapRect.size.height == source.bounds.size.height)
        }
        #expect(keys.count == 14)
        #expect(!keys.contains("z8/x16/y76"))
    }

    @Test func requestsOutsideCoverageNeverReachTheNetwork() throws {
        let source = try #require(OnlineDistrictMapCatalog.maps.first)
        var networkRequests = 0
        var completions = 0
        let overlay = OnlineDistrictTileOverlay(source: source) { _, _, _ in networkRequests += 1 }
        for path in [MKTileOverlayPath(x: 0, y: 0, z: 8, contentScaleFactor: 1),
                     MKTileOverlayPath(x: 0, y: 0, z: 3, contentScaleFactor: 1),
                     MKTileOverlayPath(x: 0, y: 0, z: 16, contentScaleFactor: 1)] {
            overlay.loadTile(at: path) { data, error in
                completions += 1
                #expect(data == nil && error == nil)
            }
        }
        #expect(networkRequests == 0 && completions == 3)
    }

    @Test func coveredTilesLoadTheSelectedVersionAndForwardFailures() throws {
        let source = try #require(OnlineDistrictMapCatalog.maps.first { $0.pack.slug == "egegik_v7" })
        let width = MKMapRect.world.width / 256
        let path = MKTileOverlayPath(x: Int(source.bounds.midX / width), y: Int(source.bounds.midY / width),
                                     z: 8, contentScaleFactor: 1)
        #expect(source.containsTile(path))
        var requests = 0
        var completions = 0
        let overlay = OnlineDistrictTileOverlay(source: source) { url, key, result in
            requests += 1
            #expect(url.path.contains("egegik_v7_xyz/8/"))
            #expect(key.contains("egegik_v7_xyz/"))
            result(nil, URLError(.resourceUnavailable))
        }
        overlay.loadTile(at: path) { data, error in
            completions += 1
            #expect(data == nil)
            #expect((error as? URLError)?.code == .resourceUnavailable)
        }
        #expect(requests == 1 && completions == 1)
    }

    @Test func mapSwitchingReusesUnchangedOverlaysAndRemovesOldVersions() async throws {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 810, height: 1080))
        Self.retainedMapViews.append(map)
        let coordinator = MapViewRepresentable.Coordinator(
            minZForTiles: 4, maxZ: 15, maxZForTiles: 15,
            extendedOfflineMaxZ: 17, extendedOfflineMaxZForTiles: 17,
            initialLaunchZoom: 12, initialCursorTrackingUser: true,
            onDistanceText: { _ in }, onSpeedText: { _ in }, onMetersPerPoint: { _ in },
            onFollowStateChanged: { _ in }, onCursorUpdated: { _, _, _ in },
            onCursorTrackingStateChanged: { _ in }, onFishingSetDisplayPrompt: { _ in })
        defer { coordinator.prepareForDismantle() }
        coordinator.availableOnlineDistrictMaps = OnlineDistrictMapCatalog.maps.filter { $0.pack.district == .egegik && $0.version >= 4 }
        coordinator.mapView = map
        // Offscreen version changes need no network requests.
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                          span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)), animated: false)
        let appearance = DistrictMapVisualSettings(brightness: 0.05, contrast: 1.3, gamma: 1, saturation: 1)
        coordinator.currentDistrictMapVisualSettingsBySlug = ["egegik_v4": appearance]
        coordinator.basemapChoice = .districtsOnline
        coordinator.currentSelectedMapVersion = 4
        coordinator.syncBasemap(on: map)
        let first = try #require(map.overlays.compactMap { $0 as? OnlineDistrictTileOverlay }.first)
        #expect(first.source.pack.slug == "egegik_v4")
        // The background must remain available beneath online child zooms too.
        let backing = try #require(map.overlays.compactMap { $0 as? BristolBaySatelliteTileOverlay }.first)
        #expect(backing.maximumZ == 17)
        #expect(first.continuity.maximumZoom == 15)
        coordinator.syncBasemap(on: map)
        #expect(map.overlays.compactMap { $0 as? OnlineDistrictTileOverlay }.first === first)

        for version in [5, 6, 7, 4] {
            coordinator.currentSelectedMapVersion = version
            coordinator.syncBasemap(on: map)
            for _ in 0..<100 {
                if first.source.version == version { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let districts = map.overlays.compactMap { $0 as? OnlineDistrictTileOverlay }
            #expect(districts.first === first)
            #expect(districts.count == 1)
            #expect(districts.first?.source.pack.slug == "egegik_v\(version)")
            #expect(map.overlays.filter { $0 is BristolBaySatelliteTileOverlay }.count == 1)
        }
        #expect(coordinator.currentDistrictMapVisualSettingsBySlug["egegik_v4"] == appearance)
        coordinator.basemapChoice = .districtsOffline
        coordinator.syncBasemap(on: map)
        #expect(map.overlays.allSatisfy { !($0 is OnlineDistrictTileOverlay) })
        coordinator.basemapChoice = .appleSatellite
        coordinator.syncBasemap(on: map)
        #expect(map.overlays.isEmpty)
    }
}
