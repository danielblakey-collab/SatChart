import Testing
import CoreGraphics
import Foundation
@testable import SatChart

struct OfflineBasemapPreviewTests {
    @Test func turnsOnlyBorderConnectedGrayBlack() throws {
        let side = 9
        var pixels = [UInt8](repeating: 221, count: side * side * 4)
        for pixel in 0..<(side * side) { pixels[pixel * 4 + 3] = 255 }
        // A colored chart boundary encloses gray details that must stay gray.
        for y in 2...6 {
            for x in 2...6 where x == 2 || x == 6 || y == 2 || y == 6 {
                let offset = (y * side + x) * 4
                pixels[offset] = 80
                pixels[offset + 1] = 140
                pixels[offset + 2] = 170
            }
        }
        let image = try makeImage(pixels, side: side)
        let result = OfflineBasemapPreview.replacingOuterGray(in: image)
        let data = try #require(result.dataProvider?.data)
        let actual = [UInt8](data as Data)
        #expect(Array(actual[0..<4]) == [0, 0, 0, 255])
        let center = (4 * side + 4) * 4
        #expect(Array(actual[center..<(center + 4)]) == [221, 221, 221, 255])
        for y in 2...6 {
            for x in 2...6 {
                let offset = (y * side + x) * 4
                #expect(Array(actual[offset..<(offset + 4)]) == Array(pixels[offset..<(offset + 4)]))
            }
        }
    }

    @Test func removesNOAAExportShadowWithoutChangingColoredEdgeDetail() throws {
        let side = 32
        let shadow = [115, 129, 137, 143]
        var pixels = [UInt8](repeating: 150, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let offset = (y * side + x) * 4
                let gray = UInt8(y < shadow.count ? shadow[y] : 150)
                pixels[offset] = gray
                pixels[offset + 1] = gray
                pixels[offset + 2] = gray
                pixels[offset + 3] = 255
            }
        }
        // Asymmetric colored detail touching the top edge stays in place.
        let detail = 19 * 4
        pixels[detail] = 80
        pixels[detail + 1] = 160
        pixels[detail + 2] = 200
        let image = try makeImage(pixels, side: side)
        let output = OfflineBasemapPreview.replacingOuterGray(in: image)
        let actual = [UInt8](try #require(output.dataProvider?.data) as Data)
        for index in 0..<(side * side) {
            let offset = index * 4
            #expect(Array(actual[offset..<(offset + 4)]) ==
                    (offset == detail ? [80, 160, 200, 255] : [0, 0, 0, 255]))
        }
    }

    @Test func leavesNewPreviewsWithoutUniformGrayCornersUnchanged() throws {
        let pixels: [UInt8] = [30, 70, 120, 255, 149, 149, 149, 255,
                              149, 149, 149, 255, 149, 149, 149, 255]
        let image = try makeImage(pixels, side: 2)
        let result = OfflineBasemapPreview.replacingOuterGray(in: image)
        #expect(result === image)
    }

    @MainActor @Test func cleanupIsLimitedToBasemapNamesAndAliases() {
        for slug in ["bristol_bay", "bristol-bay", "noaa_bristol_bay", "ncds-bristol-bay", "noaa", "ncds"] {
            #expect(OfflineBasemapPreview.usesBlackBackground(for: .init(district: .togiak, slug: slug)))
        }
        for pack in [OfflinePack(district: .togiak, slug: "togiak"),
                     OfflinePack(district: .egegik, slug: "egegik_v4"),
                     OfflinePack(district: .togiak, slug: "naknek_to_egegik_shoreline")] {
            #expect(!OfflineBasemapPreview.usesBlackBackground(for: pack))
        }
    }

    private func makeImage(_ pixels: [UInt8], side: Int) throws -> CGImage {
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(width: side, height: side, bitsPerComponent: 8,
                                   bitsPerPixel: 32, bytesPerRow: side * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                                                          | CGImageAlphaInfo.premultipliedLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false,
                                   intent: .defaultIntent))
    }
}
