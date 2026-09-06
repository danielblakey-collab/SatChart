//
//  SatChartTests.swift
//  SatChartTests
//
//  Created by Daniel Blakey on 3/1/26.
//

import Testing
import Foundation
import CoreLocation
import CoreImage
import MapKit
import UIKit
import FirebaseFirestore
import SwiftUI
@testable import SatChart

struct SatChartTests {
    @MainActor private static var retainedMapViews: [MKMapView] = []

    @MainActor
    @Test func launchBrandUsesAResolvableAppIconAsset() {
        let icon = SatChartBrandAssets.appIcon
        #expect(SatChartBrandAssets.tagline == "Know more.  Fish Smarter")
        #expect(icon != nil)
        #expect((icon?.size.width ?? 0) > 0)
        #expect((icon?.size.height ?? 0) > 0)
    }

    @Test func bundledOfflineDatabaseResourceCanBeOpened() throws {
        let url = OfflineDatabaseResource.bundledSQLiteURL()
        #expect(url != nil)

        if let url {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }

        _ = try AppDatabase.open()
    }

    @Test func basemapDefaultPrefersBristolBaySatelliteOnline() {
        #expect(BasemapDefaultPolicy.choice(rawValue: "", didMigrate: false).rawValue == BasemapChoice.districtsOnline.rawValue)
        #expect(BasemapDefaultPolicy.choice(rawValue: BasemapChoice.appleSatellite.rawValue, didMigrate: false).rawValue == BasemapChoice.districtsOnline.rawValue)
        #expect(BasemapDefaultPolicy.choice(rawValue: BasemapChoice.districtsOffline.rawValue, didMigrate: true).rawValue == BasemapChoice.districtsOffline.rawValue)
    }

    @Test func missingMBTilesSchemeUsesDocumentedLegacyTMSDefault() throws {
        #expect(try MBTilesStorageScheme.metadataValue(nil) == .tms)
        #expect(try MBTilesStorageScheme.metadataValue("") == .tms)
        #expect(try MBTilesStorageScheme.metadataValue("xyz") == .xyz)
        #expect(MBTilesStorageScheme.explicitLegacyOverride(forPackageSlug: "egegik_v2") == .xyz)
        #expect(MBTilesStorageScheme.explicitLegacyOverride(forPackageSlug: "egegik_v3") == nil)
    }

    @MainActor
    @Test func districtSatelliteBackingLayerSupportsExtendedDisplayZoom() {
        let standard = BristolBaySatelliteTileOverlay()
        let extended = BristolBaySatelliteTileOverlay(displayMaximumZ: 17)

        #expect(standard.maximumZ == 15)
        #expect(extended.maximumZ == 17)
    }

    @MainActor
    @Test func rasterTilesCanOverzoomTwoLevelsWithoutNewDetail() throws {
        let rendererFormat = UIGraphicsImageRendererFormat.default()
        rendererFormat.scale = 1
        let sourceImage = UIGraphicsImageRenderer(
            size: CGSize(width: 256, height: 256),
            format: rendererFormat
        ).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            UIColor.green.setFill()
            $0.fill(CGRect(x: 128, y: 0, width: 128, height: 128))
            UIColor.blue.setFill()
            $0.fill(CGRect(x: 0, y: 128, width: 128, height: 128))
            UIColor.yellow.setFill()
            $0.fill(CGRect(x: 128, y: 128, width: 128, height: 128))
        }
        let sourceData = try #require(sourceImage.pngData())
        let format = try #require(MBTilesOverlay.rasterTileFormat(for: sourceData))

        for childScale in [2, 4] {
            let children = try [
                (0, 0, [UInt8(255), 0, 0]),
                (childScale - 1, 0, [0, UInt8(255), 0]),
                (0, childScale - 1, [0, 0, UInt8(255)]),
                (childScale - 1, childScale - 1, [UInt8(255), UInt8(255), 0])
            ].map { childX, childY, expectedRGB in
                let outputData = try #require(MBTilesOverlay.overzoomedTileData(
                    from: sourceData,
                    childX: childX,
                    childY: childY,
                    childScale: childScale,
                    format: format
                ))
                let outputImage = try #require(UIImage(data: outputData))
                #expect(outputImage.cgImage?.width == 256)
                #expect(outputImage.cgImage?.height == 256)
                return (outputImage, expectedRGB)
            }

            for (outputImage, expectedRGB) in children {
                let actualRGB = try Self.averageRGB(of: outputImage)
                #expect(abs(Int(actualRGB[0]) - Int(expectedRGB[0])) <= 2)
                #expect(abs(Int(actualRGB[1]) - Int(expectedRGB[1])) <= 2)
                #expect(abs(Int(actualRGB[2]) - Int(expectedRGB[2])) <= 2)
            }
        }
    }

    @MainActor
    @Test func overzoomedRasterChildrenPreserveTopToBottomOrientation() throws {
        let rendererFormat = UIGraphicsImageRendererFormat.default()
        rendererFormat.scale = 1
        let sourceImage = UIGraphicsImageRenderer(
            size: CGSize(width: 256, height: 256),
            format: rendererFormat
        ).image {
            for (index, color) in [UIColor.red, .green, .blue, .yellow].enumerated() {
                color.setFill()
                $0.fill(CGRect(x: 0, y: index * 64, width: 256, height: 64))
            }
        }
        let sourceData = try #require(sourceImage.pngData())
        let format = try #require(MBTilesOverlay.rasterTileFormat(for: sourceData))

        let upperData = try #require(MBTilesOverlay.overzoomedTileData(
            from: sourceData,
            childX: 0,
            childY: 0,
            childScale: 2,
            format: format
        ))
        let lowerData = try #require(MBTilesOverlay.overzoomedTileData(
            from: sourceData,
            childX: 0,
            childY: 1,
            childScale: 2,
            format: format
        ))
        let upper = try #require(UIImage(data: upperData))
        let lower = try #require(UIImage(data: lowerData))

        let upperTop = try Self.averageRGB(of: upper, normalizedY: 0.15)
        let upperBottom = try Self.averageRGB(of: upper, normalizedY: 0.85)
        let lowerTop = try Self.averageRGB(of: lower, normalizedY: 0.15)
        let lowerBottom = try Self.averageRGB(of: lower, normalizedY: 0.85)
        #expect(upperTop == [255, 0, 0])
        #expect(upperBottom == [0, 255, 0])
        #expect(lowerTop == [0, 0, 255])
        #expect(lowerBottom == [255, 255, 0])
    }

    @MainActor
    private static func averageRGB(of image: UIImage) throws -> [UInt8] {
        let inputImage = try #require(CIImage(image: image))
        let filter = try #require(CIFilter(name: "CIAreaAverage"))
        filter.setValue(inputImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: inputImage.extent), forKey: kCIInputExtentKey)
        let outputImage = try #require(filter.outputImage)

        var bytes = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.cacheIntermediates: false]).render(
            outputImage,
            toBitmap: &bytes,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return Array(bytes.prefix(3))
    }

    @MainActor
    private static func averageRGB(of image: UIImage, normalizedY: CGFloat) throws -> [UInt8] {
        let inputImage = try #require(CIImage(image: image))
        let sampleY = inputImage.extent.minY
            + (1 - normalizedY) * inputImage.extent.height
        let sampleRect = CGRect(
            x: inputImage.extent.midX - 4,
            y: sampleY - 4,
            width: 8,
            height: 8
        )
        let filter = try #require(CIFilter(name: "CIAreaAverage"))
        filter.setValue(inputImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: sampleRect), forKey: kCIInputExtentKey)
        let outputImage = try #require(filter.outputImage)

        var bytes = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.cacheIntermediates: false]).render(
            outputImage,
            toBitmap: &bytes,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return Array(bytes.prefix(3))
    }

    @MainActor
    @Test func ocrDeliveryDraftCreationReusesBlankDraftWhenRequested() throws {
        let persistenceURL = Self.tempLogbookURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL) }

        let store = SmartLogbookStore(persistenceURL: persistenceURL)
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 14)))

        let firstID = try #require(store.addOCRDeliveryDraft(on: date, fallbackDistrict: .egegik, reusingBlankDraft: true))
        let secondID = try #require(store.addOCRDeliveryDraft(on: date, fallbackDistrict: .egegik, reusingBlankDraft: true))

        #expect(secondID == firstID)
        #expect(store.activeSeason?.openings.filter(\.isDeliveryEntry).count == 1)
    }

    @MainActor
    @Test func manualDeliveryDraftCreationStillAppendsNewDelivery() throws {
        let persistenceURL = Self.tempLogbookURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL) }

        let store = SmartLogbookStore(persistenceURL: persistenceURL)
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 14)))

        let firstID = try #require(store.addOCRDeliveryDraft(on: date, fallbackDistrict: .egegik))
        let secondID = try #require(store.addOCRDeliveryDraft(on: date, fallbackDistrict: .egegik))

        #expect(secondID != firstID)
        #expect(store.activeSeason?.openings.filter(\.isDeliveryEntry).count == 2)
        #expect(store.activeSeason?.deliveryOpenings.map(\.openingDate) == [date, date])
    }

    @MainActor
    @Test func assignedSetAppearsOnDeliveryAndShowSetUpdatesNavigationMap() throws {
        let persistenceURL = Self.tempLogbookURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL) }

        let store = SmartLogbookStore(persistenceURL: persistenceURL)
        let startedAt = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 18, hour: 8)))
        let deliveryID = try #require(store.addOCRDeliveryDraft(on: startedAt, fallbackDistrict: .nushagak))
        let savedSet = try #require(
            store.addFishingSet(
                SmartFishingSetRecord(
                    startedAt: startedAt,
                    endedAt: startedAt.addingTimeInterval(3_600),
                    locations: [],
                    locationLabel: "Test Set",
                    assignedDeliveryOpeningID: deliveryID,
                    catchText: "1,250 lbs",
                    pickingMinutes: 45,
                    notes: "Strong ebb",
                    displayOnNavPage: false
                ),
                fallbackDistrict: .nushagak
            )
        )

        let linkedSet = try #require(store.assignedFishingSets(forOpeningID: deliveryID).first)
        #expect(linkedSet.id == savedSet.id)
        #expect(linkedSet.catchText == "1,250 lbs")
        #expect(linkedSet.pickingMinutes == 45)
        #expect(linkedSet.notes == "Strong ebb")
        #expect(store.displayedFishingSetsOnNavPage.isEmpty)

        let setBinding = try #require(store.bindingForFishingSet(setID: savedSet.id))
        setBinding.wrappedValue.displayOnNavPage = true

        #expect(store.assignedFishingSets(forOpeningID: deliveryID).first?.displayOnNavPage == true)
        #expect(store.displayedFishingSetsOnNavPage.map(\.id) == [savedSet.id])
    }

    @MainActor
    @Test func oneHundredSameDayDeliveryDraftsRemainCreatableAndOrdered() throws {
        let persistenceURL = Self.tempLogbookURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL) }

        let store = SmartLogbookStore(persistenceURL: persistenceURL)
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 3)))
        var createdIDs: [UUID] = []

        for _ in 0..<100 {
            createdIDs.append(
                try #require(store.addOCRDeliveryDraft(on: date, fallbackDistrict: .nushagak))
            )
        }

        let deliveries = try #require(store.activeSeason?.deliveryOpenings)
        #expect(deliveries.count == 100)
        #expect(deliveries.map(\.id) == createdIDs)
        #expect(Set(deliveries.map(\.id)).count == 100)
        #expect(deliveries.allSatisfy { Calendar.current.isDate($0.openingDate, inSameDayAs: date) })
        #expect(
            zip(deliveries, deliveries.dropFirst()).allSatisfy { pair in
                pair.0.createdAt < pair.1.createdAt
            }
        )
    }

    @MainActor
    @Test func legacyDeliveryOrderMigratesWithoutUsingFishTicketDates() throws {
        let persistenceURL = Self.tempLogbookURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL) }

        let firstID = UUID()
        let secondID = UUID()
        let legacyJSON = """
        [
          {
            "id": "\(UUID().uuidString)",
            "splashDate": "2026-06-15T00:00:00Z",
            "districtKey": "nushagak",
            "openings": [
              {
                "id": "\(firstID.uuidString)",
                "openingDate": "2026-07-03T00:00:00Z",
                "isRecordedDelivery": true
              },
              {
                "id": "\(secondID.uuidString)",
                "openingDate": "2026-07-02T00:00:00Z",
                "isRecordedDelivery": true
              }
            ]
          }
        ]
        """
        try Data(legacyJSON.utf8).write(to: persistenceURL, options: .atomic)

        let store = SmartLogbookStore(persistenceURL: persistenceURL)
        let migrated = try #require(store.activeSeason?.deliveryOpenings)

        #expect(migrated.map(\.id) == [firstID, secondID])
        #expect(migrated[0].createdAt < migrated[1].createdAt)

        let sameDay = try Self.utcDate("2026-07-02")
        let thirdID = try #require(store.addOCRDeliveryDraft(on: sameDay, fallbackDistrict: .nushagak))
        #expect(store.activeSeason?.deliveryOpenings.map(\.id) == [firstID, secondID, thirdID])
    }

    @MainActor
    @Test func deliveriesResequenceByLandingDateAndTimeRegardlessOfEntryOrder() throws {
        let persistenceURL = Self.tempLogbookURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL) }

        let store = SmartLogbookStore(persistenceURL: persistenceURL)
        let draftDate = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 8)))
        let lateID = try #require(store.addOCRDeliveryDraft(on: draftDate, fallbackDistrict: .nushagak))
        let earlyID = try #require(store.addOCRDeliveryDraft(on: draftDate, fallbackDistrict: .nushagak))
        let middleID = try #require(store.addOCRDeliveryDraft(on: draftDate, fallbackDistrict: .nushagak))
        let incompleteID = try #require(store.addOCRDeliveryDraft(on: draftDate, fallbackDistrict: .nushagak))

        func configure(_ id: UUID, date: String, time: String, weight: Int) throws {
            let binding = try #require(store.bindingForOpening(openingID: id))
            var opening = binding.wrappedValue
            opening.dateLandedText = date
            opening.timeOfLandingText = time
            opening.totalCatchLbs = weight
            binding.wrappedValue = opening
        }

        try configure(lateID, date: "07/05/2026", time: "6:30 PM", weight: 400)
        try configure(earlyID, date: "07/03/2026", time: "20:15", weight: 200)
        try configure(middleID, date: "07/05/2026", time: "5:45 AM", weight: 300)

        #expect(store.activeSeason?.deliveryOpenings.map(\.id) == [earlyID, middleID, lateID, incompleteID])
        #expect(store.catchToDate(beforeOpeningID: lateID) == 500)

        let reloadedStore = SmartLogbookStore(persistenceURL: persistenceURL)
        #expect(reloadedStore.activeSeason?.deliveryOpenings.map(\.id) == [earlyID, middleID, lateID, incompleteID])
    }

    @MainActor
    @Test func pastYearTenderPurchasesCreateAndReuseCalendarYearSeason() throws {
        let persistenceURL = Self.tempLogbookURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL) }

        let store = SmartLogbookStore(persistenceURL: persistenceURL)
        let currentYearDate = try Self.alaskaDate(year: 2026, month: 6, day: 18)
        let pastYearFuelDate = try Self.alaskaDate(year: 2024, month: 7, day: 2)
        let pastYearGroceriesDate = try Self.alaskaDate(year: 2024, month: 7, day: 3)

        _ = try #require(store.addOCRDeliveryDraft(on: currentYearDate, fallbackDistrict: .nushagak))
        store.addTenderEntry(
            date: pastYearFuelDate,
            tenderName: "Tender A",
            fuelGallons: 125,
            groceriesDescription: "",
            groceriesAmount: nil,
            miscDescription: "",
            miscAmount: nil
        )
        store.addTenderEntry(
            date: pastYearGroceriesDate,
            tenderName: "Tender B",
            fuelGallons: nil,
            groceriesDescription: "Crew groceries",
            groceriesAmount: 240,
            miscDescription: "",
            miscAmount: nil
        )

        #expect(store.seasons.map(\.calendarYear) == [2026, 2024])
        let pastSeason = try #require(store.seasons.first(where: { $0.calendarYear == 2024 }))
        #expect(pastSeason.tenderEntries.count == 2)
        #expect(pastSeason.openings.isEmpty)
        #expect(store.activeSeason?.calendarYear == 2024)

        let reloadedStore = SmartLogbookStore(persistenceURL: persistenceURL)
        #expect(reloadedStore.seasons.map(\.calendarYear) == [2026, 2024])
        #expect(reloadedStore.seasons.first(where: { $0.calendarYear == 2024 })?.tenderEntries.count == 2)
    }

    @MainActor
    @Test func deliveryLandingYearMovesDraftIntoMatchingCalendarYearSeason() throws {
        let persistenceURL = Self.tempLogbookURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL) }

        let store = SmartLogbookStore(persistenceURL: persistenceURL)
        let draftDate = try Self.alaskaDate(year: 2026, month: 6, day: 18)
        let deliveryID = try #require(store.addOCRDeliveryDraft(on: draftDate, fallbackDistrict: .egegik))
        let binding = try #require(store.bindingForOpening(openingID: deliveryID))
        var opening = binding.wrappedValue
        opening.dateLandedText = "07/08/2023"
        binding.wrappedValue = opening

        #expect(store.seasons.map(\.calendarYear) == [2023])
        #expect(store.activeSeason?.deliveryOpenings.map(\.id) == [deliveryID])
        #expect(store.activeSeason?.calendarYear == 2023)

        let reloadedStore = SmartLogbookStore(persistenceURL: persistenceURL)
        #expect(reloadedStore.activeSeason?.calendarYear == 2023)
        #expect(reloadedStore.activeSeason?.deliveryOpenings.map(\.id) == [deliveryID])
    }

    @MainActor
    @Test func datedDeliveriesCreateOneSeasonCardPerCalendarYear() throws {
        let persistenceURL = Self.tempLogbookURL()
        defer { try? FileManager.default.removeItem(at: persistenceURL) }

        let store = SmartLogbookStore(persistenceURL: persistenceURL)
        let currentDate = try Self.alaskaDate(year: 2026, month: 7, day: 1)
        let firstPastDate = try Self.alaskaDate(year: 2022, month: 6, day: 30)
        let secondPastDate = try Self.alaskaDate(year: 2022, month: 7, day: 1)

        _ = try #require(store.addOCRDeliveryDraft(on: currentDate, fallbackDistrict: .ugashik))
        _ = try #require(store.addOCRDeliveryDraft(on: firstPastDate, fallbackDistrict: .ugashik))
        _ = try #require(store.addOCRDeliveryDraft(on: secondPastDate, fallbackDistrict: .ugashik))

        #expect(store.seasons.map(\.calendarYear) == [2026, 2022])
        #expect(store.seasons.first(where: { $0.calendarYear == 2022 })?.deliveryOpenings.count == 2)
    }

    @Test func districtsOfflineStacksDistrictsOverBristolBayAndAppleSatellite() {
        #expect(BasemapLayerPolicy.usesAppleSatelliteBase(.districtsOffline))
        #expect(BasemapLayerPolicy.usesAppleSatelliteBase(.appleSatellite))
        #expect(!BasemapLayerPolicy.usesBristolBaySatelliteOnlineBase(.districtsOffline))
        #expect(BasemapLayerPolicy.usesBristolBaySatelliteOnlineBase(.districtsOnline))
        #expect(BasemapLayerPolicy.districtBristolSource(
            hasDownloadedOfflinePackage: true
        ) == .downloadedOffline)
        #expect(BasemapLayerPolicy.districtBristolSource(
            hasDownloadedOfflinePackage: false
        ) == .onlineFallback)

        #expect(BasemapLayerPolicy.tileAlpha(
            for: "egegik_v2",
            basemapChoice: .districtsOffline,
            selectedDistrictMapSlug: "egegik_v2"
        ) == 1.0)
        #expect(BasemapLayerPolicy.tileAlpha(
            for: "egegik",
            basemapChoice: .districtsOffline,
            selectedDistrictMapSlug: "egegik_v2"
        ) == 0.0)
        #expect(BasemapLayerPolicy.tileAlpha(
            for: "egegik_to_ugashik_shoreline",
            basemapChoice: .districtsOffline,
            selectedDistrictMapSlug: nil
        ) == 1.0)
    }

    @MainActor
    @Test func onlineDistrictsStackAboveBristolBayAndBelowOtherOverlays() {
        let coordinator = MapViewRepresentable.Coordinator(
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
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        Self.retainedMapViews.append(mapView)
        let downloadedDistrict = MKTileOverlay(urlTemplate: nil)
        downloadedDistrict.canReplaceMapContent = false
        mapView.mapType = .standard
        mapView.addOverlay(downloadedDistrict, level: .aboveRoads)
        coordinator.mapView = mapView
        // Keep this renderer-order test independent of the device's downloaded-map
        // inventory. Offline-vs-online selection is covered by the pure policy test.
        coordinator.basemapChoice = .districtsOnline

        coordinator.syncBasemap(on: mapView)

        let rasters = mapView.overlays(in: .aboveRoads)
        #expect(mapView.mapType == .satellite)
        #expect(rasters.count == 3)
        #expect(rasters.first is BristolBaySatelliteTileOverlay)
        #expect((rasters[1] as? OnlineDistrictTileOverlay)?.source.pack.slug == "egegik_v4")
        #expect((rasters.last as AnyObject) === downloadedDistrict)
    }

    @MainActor
    @Test func everyDistrictV3ReplacementUsesDesiredSelectionNotTemporaryOverlayCount() {
        let v3Packs = DistrictID.allCases.map { district in
            OfflinePack(district: district, slug: district.packSlug(forVersion: 3))
        }
        let desiredSlugs = MapViewRepresentable.desiredDistrictMapSlugs(
            from: v3Packs
        )

        for district in DistrictID.allCases {
            let expectedSlug = district.packSlug(forVersion: 3)
            #expect(desiredSlugs[district] == expectedSlug)
            #expect(BasemapLayerPolicy.tileAlpha(
                for: expectedSlug,
                basemapChoice: .districtsOffline,
                selectedDistrictMapSlug: desiredSlugs[district]
            ) == 1.0)
        }
    }

    @Test func nonDistrictBasemapsHideDistrictOfflineOverlays() {
        #expect(BasemapLayerPolicy.tileAlpha(
            for: "egegik_v2",
            basemapChoice: .topoOnline,
            selectedDistrictMapSlug: "egegik_v2"
        ) == 0.0)
        #expect(BasemapLayerPolicy.tileAlpha(
            for: "egegik_to_ugashik_shoreline",
            basemapChoice: .noaaOnline,
            selectedDistrictMapSlug: nil
        ) == 0.0)
        #expect(BasemapLayerPolicy.tileAlpha(
            for: "bristol_bay",
            basemapChoice: .noaaOnline,
            selectedDistrictMapSlug: nil
        ) == 1.0)
    }

    @Test func topDistrictTenYearMeanDailySelectsHighestPriorTenYearMean() {
        var samples: [TopDistrictTenYearMeanDailySample] = [
            .init(district: .egegik, year: 2014, monthDay: "07-01", sockeyePerBoatDaily: 100_000),
            .init(district: .egegik, year: 2025, monthDay: "07-01", sockeyePerBoatDaily: 100_000)
        ]

        for year in 2015...2024 {
            samples.append(.init(district: .egegik, year: year, monthDay: "07-01", sockeyePerBoatDaily: 1_000))
            samples.append(.init(district: .ugashik, year: year, monthDay: "07-01", sockeyePerBoatDaily: 2_000))
        }

        let result = TopDistrictTenYearMeanDailyCalculator.topDistrict(
            for: "2025-07-01",
            districts: [.egegik, .ugashik],
            samplesByDistrictMonthDay: TopDistrictTenYearMeanDailyCalculator.groupedSamples(samples)
        )

        #expect(result?.district == .ugashik)
        #expect(result?.yearsUsed == 10)
        #expect(abs((result?.meanSockeyePerBoatDaily ?? 0) - 2_000) < 0.0001)
    }

    @Test func topDistrictTenYearMeanDailyUsesAvailablePriorYearsWhenFewerThanTenExist() {
        let samples: [TopDistrictTenYearMeanDailySample] = [
            .init(district: .egegik, year: 2022, monthDay: "07-02", sockeyePerBoatDaily: 200),
            .init(district: .egegik, year: 2023, monthDay: "07-02", sockeyePerBoatDaily: 400),
            .init(district: .ugashik, year: 2024, monthDay: "07-02", sockeyePerBoatDaily: 250)
        ]

        let result = TopDistrictTenYearMeanDailyCalculator.topDistrict(
            for: "2025-07-02",
            districts: [.egegik, .ugashik],
            samplesByDistrictMonthDay: TopDistrictTenYearMeanDailyCalculator.groupedSamples(samples)
        )

        #expect(result?.district == .egegik)
        #expect(result?.yearsUsed == 2)
        #expect(abs((result?.meanSockeyePerBoatDaily ?? 0) - 300) < 0.0001)
    }

    @Test func topDistrictTenYearMeanDailyIgnoresMissingAndUnavailableValues() {
        let samples: [TopDistrictTenYearMeanDailySample] = [
            .init(district: .egegik, year: 2024, monthDay: "07-03", sockeyePerBoatDaily: nil),
            .init(district: .egegik, year: 2023, monthDay: "07-03", sockeyePerBoatDaily: 500),
            .init(district: .ugashik, year: 2024, monthDay: "07-03", sockeyePerBoatDaily: 400),
            .init(district: .nushagak, year: 2024, monthDay: "07-03", sockeyePerBoatDaily: .infinity)
        ]

        let result = TopDistrictTenYearMeanDailyCalculator.topDistrict(
            for: "2025-07-03",
            districts: [.egegik, .ugashik, .nushagak],
            samplesByDistrictMonthDay: TopDistrictTenYearMeanDailyCalculator.groupedSamples(samples)
        )

        #expect(result?.district == .egegik)
        #expect(result?.yearsUsed == 1)
        #expect(abs((result?.meanSockeyePerBoatDaily ?? 0) - 500) < 0.0001)
    }

    @Test func topDistrictTenYearMeanDailyMetricMetadataFeedsDailyCSVColumn() {
        let metric = DeepResearchTableMetric.topDistrictTenYearMeanDaily

        #expect(metric.group == .efficiency)
        #expect(metric.isSeasonAggregate == false)
        #expect(metric.buttonTitle == "Top District\n10-year Mean\nDaily")
        #expect(metric.columnTitle == "Top District 10-year Mean Daily")
        #expect(metric.sortOrder > DeepResearchTableMetric.sockeyePerBoatDailyTopDistrict.sortOrder)
        #expect(metric.sortOrder < DeepResearchTableMetric.sockeyePerBoatHourly.sortOrder)
    }

    @MainActor
    @Test func dailyCumulativeTableMetricsResetPerDistrictYearAndCSVMatchesDisplay() async throws {
        let appDB = try AppDatabase.open()
        let viewModel = DeepResearchTablesVM()
        viewModel.filters = DeepResearchTablesFilters(
            startDate: try Self.utcDate("2024-07-01"),
            endDate: try Self.utcDate("2025-07-01"),
            selectedDistricts: [.ugashik, .nushagak],
            selectedMetrics: [
                .cumulativeDriftHours,
                .dailyDriftHours,
                .cumulativeSetHours,
                .dailySetHours,
                .cumulativeHarvest,
                .dailyHarvest,
                .cumulativeEscapement,
                .dailyEscapement,
                .sockeyePerBoatCumulative,
                .sockeyePerBoatDaily
            ],
            includeRiverEscapementBreakdown: true,
            includeRiverDailyEscColumns: true,
            includeRiverCumulativeEscColumns: true,
            selectedRiversByDistrict: [
                .ugashik: ["ugashik"],
                .nushagak: ["wood"]
            ],
            outputMode: .display
        )

        await viewModel.generate(appDB: appDB)

        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.rows.count == 4)

        var rowsByID: [String: DeepResearchTableRow] = [:]
        for row in viewModel.rows {
            rowsByID[row.id] = row
        }
        let ugashik2024 = try #require(rowsByID["2024-07-01|ugashik"])
        let ugashik2025 = try #require(rowsByID["2025-07-01|ugashik"])
        let nushagak2024 = try #require(rowsByID["2024-07-01|nushagak"])
        let nushagak2025 = try #require(rowsByID["2025-07-01|nushagak"])

        for row in [ugashik2024, ugashik2025, nushagak2024, nushagak2025] {
            Self.expectEqualFormattedValues(row, .cumulativeDriftHours, .dailyDriftHours)
            Self.expectEqualFormattedValues(row, .cumulativeSetHours, .dailySetHours)
            Self.expectEqualFormattedValues(row, .cumulativeHarvest, .dailyHarvest)
            Self.expectEqualFormattedValues(row, .cumulativeEscapement, .dailyEscapement)
            Self.expectEqualFormattedValues(row, .sockeyePerBoatCumulative, .sockeyePerBoatDaily)
        }

        Self.expectEqualRawValues(ugashik2024, cumulativeKey: "river_cum_ugashik_ugashik", dailyKey: "river_daily_ugashik_ugashik")
        Self.expectEqualRawValues(ugashik2025, cumulativeKey: "river_cum_ugashik_ugashik", dailyKey: "river_daily_ugashik_ugashik")
        Self.expectEqualRawValues(nushagak2024, cumulativeKey: "river_cum_nushagak_wood", dailyKey: "river_daily_nushagak_wood")
        Self.expectEqualRawValues(nushagak2025, cumulativeKey: "river_cum_nushagak_wood", dailyKey: "river_daily_nushagak_wood")

        let exportURL = try #require(try await viewModel.exportCSV(appDB: appDB))
        defer { try? FileManager.default.removeItem(at: exportURL) }
        let csv = try String(contentsOf: exportURL, encoding: .utf8)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count >= viewModel.rows.count + 1)

        let headers = Self.parseCSVLine(lines[0])
        let csvRows = lines.dropFirst().filter { !$0.isEmpty }.map(Self.parseCSVLine)
        #expect(csvRows.count == viewModel.rows.count)

        let dateIndex = try #require(headers.firstIndex(of: "Date"))
        let districtIndex = try #require(headers.firstIndex(of: "District"))
        let harvestCumulativeIndex = try #require(headers.firstIndex(of: DeepResearchTableMetric.cumulativeHarvest.columnTitle))
        let harvestDailyIndex = try #require(headers.firstIndex(of: DeepResearchTableMetric.dailyHarvest.columnTitle))
        let ugashik2025CSV = try #require(csvRows.first {
            $0.indices.contains(dateIndex) &&
            $0.indices.contains(districtIndex) &&
            $0[dateIndex] == "7/1/25" &&
            $0[districtIndex] == "Ugashik"
        })
        let requiredCSVIndex = max(harvestCumulativeIndex, harvestDailyIndex)
        #expect(ugashik2025CSV.count > requiredCSVIndex)
        guard ugashik2025CSV.count > requiredCSVIndex else { return }

        #expect(ugashik2025CSV[harvestCumulativeIndex] == ugashik2025CSV[harvestDailyIndex])
        #expect(ugashik2025CSV[harvestCumulativeIndex] == ugashik2025.values[DeepResearchTableMetric.cumulativeHarvest.rawValue])
    }

    @Test func radioGroupPinRecordParsesValidOneTimePin() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let record = RadioGroupPinRecord(id: "pin-1", data: [
            "ownerUid": "member-a",
            "lat": 58.75,
            "lon": -157.25,
            "displayName": "F/V Test",
            "createdAt": Timestamp(date: now),
            "updatedAt": Timestamp(date: now.addingTimeInterval(5)),
            "source": "one_time_pin"
        ])

        #expect(record.hasValidCoordinate)
        #expect(record.coordinate.latitude == 58.75)
        #expect(record.coordinate.longitude == -157.25)
        #expect(record.displayName == "F/V Test")
        #expect(record.ownerUid == "member-a")
        #expect(record.createdAt == now)
    }

    @Test func radioGroupLiveLocationRecordParsesValidLivePin() {
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let record = RadioGroupLiveLocationRecord(id: "member-b", data: [
            "ownerUid": "member-b",
            "lat": 59.1,
            "lon": -158.2,
            "displayName": "Live Member",
            "updatedAt": Timestamp(date: now),
            "sharingEnabled": true
        ])

        #expect(record.hasValidCoordinate)
        #expect(record.coordinate.latitude == 59.1)
        #expect(record.coordinate.longitude == -158.2)
        #expect(record.displayName == "Live Member")
        #expect(record.ownerUid == "member-b")
        #expect(record.updatedAt == now)
        #expect(record.isExpired == false)
    }

    @Test func radioGroupPinRecordMarksMissingCoordinatesInvalid() {
        let record = RadioGroupPinRecord(id: "missing-coordinate", data: [
            "ownerUid": "member-a",
            "displayName": "Bad Pin"
        ])

        #expect(record.hasValidCoordinate == false)
        #expect(record.coordinate.latitude.isNaN)
        #expect(record.coordinate.longitude.isNaN)
    }

    @Test func radioGroupLiveLocationRecordAcceptsIntegerCoordinates() {
        let record = RadioGroupLiveLocationRecord(id: "integer-coordinate", data: [
            "ownerUid": "member-c",
            "lat": 58,
            "lon": -157,
            "updatedAt": Date(timeIntervalSince1970: 1_800_000_200)
        ])

        #expect(record.hasValidCoordinate)
        #expect(record.coordinate.latitude == 58)
        #expect(record.coordinate.longitude == -157)
    }

    @Test func radioGroupRecordsUseSafeFallbacksForMissingDisplayNameAndTimestamps() {
        let pin = RadioGroupPinRecord(id: "missing-display", data: [
            "ownerUid": "member-d",
            "lat": 58.5,
            "lon": -157.5
        ])
        let live = RadioGroupLiveLocationRecord(id: "live-missing-display", data: [
            "ownerUid": "member-e",
            "lat": 58.6,
            "lon": -157.6
        ])

        #expect(pin.displayName == "Member")
        #expect(pin.createdAt == Date.distantPast)
        #expect(pin.updatedAt == Date.distantPast)
        #expect(live.displayName == "Member")
        #expect(live.updatedAt == Date.distantPast)
    }

    @Test func radioGroupLiveLocationRecordToleratesMalformedOwnerUid() {
        let record = RadioGroupLiveLocationRecord(id: "fallback-owner", data: [
            "ownerUid": "   ",
            "lat": "58.25",
            "lon": "-157.75"
        ])

        #expect(record.ownerUid == "fallback-owner")
        #expect(record.hasValidCoordinate)
        #expect(record.coordinate.latitude == 58.25)
        #expect(record.coordinate.longitude == -157.75)
    }

    @Test func radioGroupRecordsRejectNonFiniteCoordinates() {
        let pin = RadioGroupPinRecord(id: "nan-pin", data: [
            "ownerUid": "member-f",
            "lat": Double.nan,
            "lon": -157.5
        ])
        let live = RadioGroupLiveLocationRecord(id: "inf-live", data: [
            "ownerUid": "member-g",
            "lat": 58.5,
            "lon": Double.infinity
        ])

        #expect(pin.hasValidCoordinate == false)
        #expect(live.hasValidCoordinate == false)
    }

    @Test func liveLocationSessionRestoresWithinTenMinutes() {
        let now = Date(timeIntervalSince1970: 1_800_010_000)
        let snapshot = LiveLocationSessionSnapshot(
            isActiveIntent: true,
            backgroundedAt: now.addingTimeInterval(-9 * 60),
            lastSentAt: now.addingTimeInterval(-9 * 60),
            groupId: "group-a",
            promptShownForBackgroundedAt: nil
        )

        #expect(liveLocationResumeActionLabel(LiveLocationSessionState.resumeAction(for: snapshot, now: now)) == "restore")
    }

    @Test func liveLocationSessionPromptsOnceBetweenTenAndSixtyMinutes() {
        let now = Date(timeIntervalSince1970: 1_800_020_000)
        let backgroundedAt = now.addingTimeInterval(-20 * 60)
        let snapshot = LiveLocationSessionSnapshot(
            isActiveIntent: true,
            backgroundedAt: backgroundedAt,
            lastSentAt: backgroundedAt,
            groupId: "group-a",
            promptShownForBackgroundedAt: nil
        )
        let shownSnapshot = LiveLocationSessionSnapshot(
            isActiveIntent: true,
            backgroundedAt: backgroundedAt,
            lastSentAt: backgroundedAt,
            groupId: "group-a",
            promptShownForBackgroundedAt: backgroundedAt
        )

        #expect(liveLocationResumeActionLabel(LiveLocationSessionState.resumeAction(for: snapshot, now: now)) == "prompt")
        #expect(liveLocationResumeActionLabel(LiveLocationSessionState.resumeAction(for: shownSnapshot, now: now)) == "none")
    }

    @Test func liveLocationSessionExpiresAtSixtyMinutes() {
        let now = Date(timeIntervalSince1970: 1_800_030_000)
        let snapshot = LiveLocationSessionSnapshot(
            isActiveIntent: true,
            backgroundedAt: now.addingTimeInterval(-60 * 60),
            lastSentAt: now.addingTimeInterval(-60 * 60),
            groupId: "group-a",
            promptShownForBackgroundedAt: nil
        )

        #expect(liveLocationResumeActionLabel(LiveLocationSessionState.resumeAction(for: snapshot, now: now)) == "expired")
    }

    @Test func liveLocationSessionManualStopClearsResumeState() throws {
        let suiteName = "LiveLocationSessionStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        LiveLocationSessionState.recordBackgrounded(
            defaults: defaults,
            backgroundedAt: Date(timeIntervalSince1970: 1_800_040_000),
            lastSentAt: Date(timeIntervalSince1970: 1_800_039_000),
            groupId: "group-a"
        )
        #expect(LiveLocationSessionState.snapshot(defaults: defaults) != nil)

        LiveLocationSessionState.clear(defaults: defaults)

        #expect(LiveLocationSessionState.snapshot(defaults: defaults) == nil)
    }

    private func liveLocationResumeActionLabel(_ action: LiveLocationResumeAction) -> String {
        switch action {
        case .none:
            return "none"
        case .restore:
            return "restore"
        case .prompt:
            return "prompt"
        case .expired:
            return "expired"
        }
    }

    private static func tempLogbookURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("satchart-logbook-\(UUID().uuidString)")
            .appendingPathExtension("json")
    }

    private static func utcDate(_ dateString: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return try #require(formatter.date(from: dateString))
    }

    private static func alaskaDate(year: Int, month: Int, day: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Anchorage"))
        return try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
    }

    private static func expectEqualFormattedValues(
        _ row: DeepResearchTableRow,
        _ cumulativeMetric: DeepResearchTableMetric,
        _ dailyMetric: DeepResearchTableMetric
    ) {
        let cumulative = row.values[cumulativeMetric.rawValue] ?? ""
        let daily = row.values[dailyMetric.rawValue] ?? ""
        if !daily.isEmpty {
            #expect(cumulative == daily)
        }
    }

    private static func expectEqualRawValues(
        _ row: DeepResearchTableRow,
        cumulativeKey: String,
        dailyKey: String
    ) {
        #expect(row.values[cumulativeKey] == row.values[dailyKey])
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var isQuoted = false
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let next = line.index(after: index)
                if isQuoted, next < line.endIndex, line[next] == "\"" {
                    current.append("\"")
                    index = line.index(after: next)
                    continue
                }
                isQuoted.toggle()
            } else if character == ",", !isQuoted {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }

        fields.append(current)
        return fields
    }
}
