import Foundation
import UIKit
import ImageIO

/// Display-only cleanup of the solid gray outside the two legacy basemap previews.
/// Flooding from the border preserves enclosed gray chart details and never edits map tiles.
enum OfflineBasemapPreview {
    static func usesBlackBackground(for pack: OfflinePack) -> Bool {
        OfflinePack.basemapPacks.contains { $0.remoteBasenameCandidates.contains(pack.slug) }
    }

    nonisolated static func image(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary) else { return UIImage(data: data) }
        return UIImage(cgImage: replacingOuterGray(in: image))
    }

    nonisolated static func replacingOuterGray(in image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 1, height > 1, width <= 4096, height <= 4096,
              width * height <= 4_194_304 else { return image }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let decoded = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: colorSpace, bitmapInfo: bitmapInfo) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard decoded else { return image }

        func neutralValue(at index: Int) -> Int? {
            let offset = index * 4
            let rgb = (0..<3).map { Int(pixels[offset + $0]) }
            guard pixels[offset + 3] == 255, rgb.max()! - rgb.min()! <= 8 else { return nil }
            return rgb.reduce(0, +) / 3
        }

        func uniformGray(at indices: [Int]) -> Int? {
            let values = indices.compactMap { neutralValue(at: $0) }
            guard values.count == indices.count,
                  values.max()! - values.min()! <= 12 else { return nil }
            return values.sorted()[values.count / 2]
        }

        let corners = [0, width - 1, (height - 1) * width, width * height - 1]
        let inset = min(8, (min(width, height) - 1) / 4)
        let insetCorners = [inset * width + inset, inset * width + width - 1 - inset,
                            (height - 1 - inset) * width + inset,
                            (height - 1 - inset) * width + width - 1 - inset]
        // The NOAA export includes a thin gray shadow along its top edge.
        // Sample just inside it when the outer corners disagree.
        guard let gray = uniformGray(at: corners) ?? uniformGray(at: insetCorners),
              (64...240).contains(gray) else { return image }

        var grayByRow = [Int](repeating: gray, count: height)
        for row in 0..<height where row < inset || row >= height - inset {
            if let edgeGray = uniformGray(at: [row * width, row * width + width - 1]),
               (gray - 48...gray + 12).contains(edgeGray) {
                grayByRow[row] = edgeGray
            }
        }

        func isBackground(_ index: Int) -> Bool {
            let offset = index * 4
            let gray = grayByRow[index / width]
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            return pixels[offset + 3] == 255
                && max(red, green, blue) - min(red, green, blue) <= 8
                && abs(red - gray) <= 12 && abs(green - gray) <= 12 && abs(blue - gray) <= 12
        }

        var seeds = [Int]()
        for x in 0..<width {
            seeds.append(x)
            seeds.append((height - 1) * width + x)
        }
        for y in 1..<(height - 1) {
            seeds.append(y * width)
            seeds.append(y * width + width - 1)
        }

        // Fill horizontal spans to keep the work queue small even on large JPGs.
        while let seed = seeds.popLast() {
            guard isBackground(seed) else { continue }
            let row = seed / width
            let rowStart = row * width
            var left = seed
            var right = seed
            while left > rowStart && isBackground(left - 1) { left -= 1 }
            while right < rowStart + width - 1 && isBackground(right + 1) { right += 1 }
            for index in left...right {
                let offset = index * 4
                pixels[offset] = 0
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
            }
            for nextRow in [row - 1, row + 1] where (0..<height).contains(nextRow) {
                var inRun = false
                let delta = (nextRow - row) * width
                for index in left...right {
                    let matches = isBackground(index + delta)
                    if matches && !inRun { seeds.append(index + delta) }
                    inRun = matches
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let result = CGImage(width: width, height: height, bitsPerComponent: 8,
                                   bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: colorSpace,
                                   bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                                   decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return image }
        return result
    }
}
