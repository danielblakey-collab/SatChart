import Testing
import XCTest
import Foundation
import UIKit
@testable import SatChart

struct FishTicketTallyOCRTests {
    private struct RealTallyFixture {
        let filename: String
        let expectedSummarySoldWeight: Int
        let rows: [SmartFishTicketTallyOCRTestRow]
    }

    @MainActor
    @Test func suppliedRealTallyPhotosMatchEveryRowField() async throws {
        var footprints: [UInt64] = []
        for fixture in Self.realTallyFixtures {
            let imageURL = try #require(
                Bundle(for: FishTicketTallyOCRFixtureBundleToken.self).url(
                    forResource: fixture.filename,
                    withExtension: "jpg"
                )
            )
            let image = try #require(UIImage(contentsOfFile: imageURL.path))
            let result: SmartFishTicketTallyOCRTestResult?
            do {
                result = try await SmartFishTicketTallyOCRTestSupport.extract(
                    images: [image],
                    expectedSummarySoldWeight: fixture.expectedSummarySoldWeight
                )
            } catch {
                Issue.record("OCR threw for \(fixture.filename): \(error)")
                SmartFishTicketTallyOCRTestSupport.clearOCRCaches()
                continue
            }
            #expect(result != nil, "OCR returned no rows for \(fixture.filename)")
            if let result {
                #expect(result.rows == fixture.rows, "OCR mismatch for \(fixture.filename): \(result.rows)")
            }
            SmartFishTicketTallyOCRTestSupport.clearOCRCaches()
            if let footprint = SmartFishTicketMemoryDiagnostics.physicalFootprintBytes {
                footprints.append(footprint)
            }
        }

        let postWarmupFootprints = Array(footprints.dropFirst(min(2, footprints.count)))
        if let minimum = postWarmupFootprints.min(),
           let maximum = postWarmupFootprints.max() {
            #expect(
                maximum - minimum < 192 * 1_024 * 1_024,
                "Sequential real-photo tally OCR retained too much memory: \(maximum - minimum) bytes"
            )
        }
    }

    @Test func oneRowMayEqualSummaryTotalWithoutBeingDiscarded() throws {
        let tokens = Self.tallyTokens(weights: [1_250])
        let result = try #require(
            SmartFishTicketTallyOCRTestSupport.parseTokens(
                tokens,
                expectedSummarySoldWeight: 1_250
            )
        )

        #expect(result.rows.count == 1)
        #expect(result.rows.map(\.soldWeight) == [1_250])
        #expect(result.rows[0].isInferredWeight == false)
    }

    @Test func oneRowCanBootstrapFromSemanticAndCountCues() throws {
        let tokens = Self.tallyTokens(weights: [1_250], omittedWeightRows: [0])
        let result = try #require(
            SmartFishTicketTallyOCRTestSupport.parseTokens(
                tokens,
                expectedSummarySoldWeight: 1_250
            )
        )

        #expect(result.rows.count == 1)
        #expect(result.rows[0].soldWeight == 1_250)
        #expect(result.rows[0].isInferredWeight)
        #expect(result.warnings.contains { $0.localizedCaseInsensitiveContains("inferred") })
    }

    @Test func twoRowSparseTallyPreservesBothRows() throws {
        let result = try #require(
            SmartFishTicketTallyOCRTestSupport.parseTokens(
                Self.tallyTokens(weights: [1_000, 250]),
                expectedSummarySoldWeight: 1_250
            )
        )

        #expect(result.rows.map(\.soldWeight) == [1_000, 250])
        #expect(result.rows.allSatisfy { !$0.species.isEmpty })
    }

    @Test func threeRowSparseTallyPreservesAllRows() throws {
        let result = try #require(
            SmartFishTicketTallyOCRTestSupport.parseTokens(
                Self.tallyTokens(weights: [700, 500, 100]),
                expectedSummarySoldWeight: 1_300
            )
        )

        #expect(result.rows.map(\.soldWeight) == [700, 500, 100])
    }

    @Test func sparseRowsSurviveShiftedAndScaledTableColumns() throws {
        let shiftedTokens = Self.tallyTokens(weights: [900, 325]).map { token in
            SmartFishTicketTallyOCRTestToken(
                text: token.text,
                boundingBox: CGRect(
                    x: 0.045 + (token.boundingBox.minX * 0.90),
                    y: token.boundingBox.minY,
                    width: token.boundingBox.width * 0.90,
                    height: token.boundingBox.height
                ),
                confidence: token.confidence
            )
        }
        let result = try #require(
            SmartFishTicketTallyOCRTestSupport.parseTokens(
                shiftedTokens,
                expectedSummarySoldWeight: 1_225
            )
        )

        #expect(result.rows.map(\.soldWeight) == [900, 325])
        #expect(result.rows.allSatisfy { !$0.species.isEmpty && !$0.deliveryCondition.isEmpty })
    }

    @Test func footerTotalIsNotDuplicatedAsADataRow() throws {
        let result = try #require(
            SmartFishTicketTallyOCRTestSupport.parseTokens(
                Self.tallyTokens(weights: [600]),
                expectedSummarySoldWeight: 600
            )
        )

        #expect(result.rows.map(\.soldWeight) == [600])
    }

    @Test func unsupportedNumericNoiseScoresBelowCleanSparseRows() throws {
        let cleanTokens = Self.tallyTokens(weights: [1_000])
        var noisyTokens = cleanTokens
        noisyTokens.append(Self.token("375", x: 0.53, y: 0.58, width: 0.07))

        let clean = try #require(
            SmartFishTicketTallyOCRTestSupport.parseTokens(
                cleanTokens,
                expectedSummarySoldWeight: nil
            )
        )
        let noisy = try #require(
            SmartFishTicketTallyOCRTestSupport.parseTokens(
                noisyTokens,
                expectedSummarySoldWeight: nil
            )
        )

        #expect(clean.score > noisy.score)
    }

    @Test func multiPageSelectionReconcilesTheCombinedSummaryTotal() throws {
        let pageOneCandidates = [
            Self.tallyTokens(weights: [400]),
            Self.tallyTokens(weights: [450])
        ]
        let pageTwoCandidates = [
            Self.tallyTokens(weights: [600]),
            Self.tallyTokens(weights: [650])
        ]

        let selected = SmartFishTicketTallyOCRTestSupport.selectTokenCandidates(
            [pageOneCandidates, pageTwoCandidates],
            expectedSummarySoldWeight: 1_000
        )

        #expect(selected.count == 2)
        #expect(selected.flatMap(\.rows).map(\.soldWeight) == [400, 600])
    }

    @Test func fiftySparseParserPassesDoNotAccumulateRowsOrLargeRetainedMemory() throws {
        let tokens = Self.tallyTokens(weights: [700, 500, 100])
        let startingFootprint = SmartFishTicketMemoryDiagnostics.physicalFootprintBytes

        for _ in 0..<50 {
            try autoreleasepool {
                let result = try #require(
                    SmartFishTicketTallyOCRTestSupport.parseTokens(
                        tokens,
                        expectedSummarySoldWeight: 1_300
                    )
                )
                #expect(result.rows.count == 3)
            }
        }

        if let startingFootprint,
           let endingFootprint = SmartFishTicketMemoryDiagnostics.physicalFootprintBytes {
            #expect(endingFootprint <= startingFootprint + 64 * 1_024 * 1_024)
        }
    }

    // Set SATCHART_RUN_TALLY_OCR_STRESS=1 on a physical-device test plan to run
    // the full Vision/Core Image path 50 times and watch physical footprint stability.
    @MainActor
    @Test func optInFiftyPassPhysicalDeviceOCRStress() async throws {
        guard ProcessInfo.processInfo.environment["SATCHART_RUN_TALLY_OCR_STRESS"] == "1" else {
            return
        }

        let image = Self.syntheticTallyImage(weights: [700, 500, 100])
        let requestedPassCount = Int(
            ProcessInfo.processInfo.environment["SATCHART_TALLY_OCR_STRESS_PASSES"] ?? ""
        )
        let passCount = max(1, requestedPassCount ?? 50)
        var footprints: [UInt64] = []
        for _ in 0..<passCount {
            let result = try await SmartFishTicketTallyOCRTestSupport.extract(
                images: [image],
                expectedSummarySoldWeight: 1_300
            )
            #expect(result?.rows.map(\.soldWeight).reduce(0, +) == 1_300)
            SmartFishTicketTallyOCRTestSupport.clearOCRCaches()
            if let footprint = SmartFishTicketMemoryDiagnostics.physicalFootprintBytes {
                footprints.append(footprint)
            }
        }

        let postWarmup = Array(footprints.dropFirst(min(5, max(0, footprints.count - 2))))
        if let minimum = postWarmup.min(), let maximum = postWarmup.max() {
            #expect(maximum - minimum < 192 * 1_024 * 1_024)
        }
    }

    @MainActor
    @Test func cameraLikeSparseTallyRetainsItsRows() async throws {
        let source = Self.syntheticTallyImage(weights: [900, 325])
        let image = Self.cameraLikeImage(from: source)
        let result = try await SmartFishTicketTallyOCRTestSupport.extract(
            images: [image],
            expectedSummarySoldWeight: 1_225
        )

        #expect(result?.rows.map(\.soldWeight).reduce(0, +) == 1_225)
        #expect(result?.rows.count == 2)
    }

    private static let realTallyFixtures: [RealTallyFixture] = [
        fixture("IMG_0052", total: 3_697, species: ["460 Salmon, Mixed", "460 Salmon, Mixed", "460 Salmon, Mixed", "460 Salmon, Mixed"], condition: "03 Bled", weights: [879, 840, 892, 1_086], brailers: [3, 3, 3, 3]),
        fixture("IMG_0053", total: 3_266, species: ["460 Salmon, Mixed", "460 Salmon, Mixed", "460 Salmon, Mixed", "460 Salmon, Mixed"], condition: "01 Whole", weights: [970, 792, 760, 744], brailers: [3, 3, 3, 3]),
        fixture("IMG_0054", total: 175, species: ["460 Salmon, Mixed", "460 Salmon, Mixed"], condition: "03 Bled", weights: [94, 81], brailers: [2, 2]),
        fixture("IMG_0055", total: 1_891, species: ["460 Salmon, Mixed", "460 Salmon, Mixed", "410 Kings"], condition: "01 Whole", weights: [1_084, 791, 16], brailers: [3, 3, nil]),
        fixture("IMG_0056", total: 922, species: ["460 Salmon, Mixed"], condition: "03 Bled", weights: [922], brailers: [3]),
        fixture("IMG_0057", total: 494, species: ["460 Salmon, Mixed"], condition: "03 Bled", weights: [494], brailers: [3]),
        fixture("IMG_0058", total: 899, species: ["460 Salmon, Mixed", "460 Salmon, Mixed"], condition: "01 Whole", weights: [479, 420], brailers: [3, 3]),
        fixture("IMG_0059", total: 775, species: ["460 Salmon, Mixed", "460 Salmon, Mixed"], condition: "03 Bled", weights: [371, 404], brailers: [3, 3]),
        fixture("IMG_0060", total: 916, species: ["460 Salmon, Mixed"], condition: "03 Bled", weights: [916], brailers: [3])
    ]

    private static func fixture(
        _ filename: String,
        total: Int,
        species: [String],
        condition: String,
        weights: [Int],
        brailers: [Int?]
    ) -> RealTallyFixture {
        precondition(species.count == weights.count && weights.count == brailers.count)
        return RealTallyFixture(
            filename: filename,
            expectedSummarySoldWeight: total,
            rows: weights.indices.map { index in
                SmartFishTicketTallyOCRTestRow(
                    species: species[index],
                    deliveryCondition: condition,
                    soldWeight: weights[index],
                    brailers: brailers[index],
                    isInferredWeight: false
                )
            }
        )
    }

    private static func tallyTokens(
        weights: [Int],
        omittedWeightRows: Set<Int> = []
    ) -> [SmartFishTicketTallyOCRTestToken] {
        var tokens: [SmartFishTicketTallyOCRTestToken] = [
            token("SPECIES", x: 0.05, y: 0.05, width: 0.09),
            token("DEL COND", x: 0.15, y: 0.05, width: 0.09),
            token("NUM", x: 0.29, y: 0.05, width: 0.05),
            token("POST TARE", x: 0.50, y: 0.05, width: 0.10),
            token("SOLD WEIGHT", x: 0.82, y: 0.05, width: 0.10),
            token("BRAILERS", x: 0.94, y: 0.05, width: 0.05)
        ]

        for (index, weight) in weights.enumerated() {
            let y = 0.23 + (CGFloat(index) * 0.11)
            tokens.append(token("460 SALMON", x: 0.04, y: y, width: 0.10))
            tokens.append(token("01 WHOLE", x: 0.15, y: y, width: 0.09))
            tokens.append(token(String(100 + index), x: 0.29, y: y, width: 0.06))
            if !omittedWeightRows.contains(index) {
                tokens.append(token(Self.formatted(weight), x: 0.52, y: y, width: 0.07))
                tokens.append(token(Self.formatted(weight), x: 0.84, y: y, width: 0.07))
            }
            tokens.append(token("2", x: 0.95, y: y, width: 0.02))
        }

        let total = weights.reduce(0, +)
        tokens.append(token("TOTAL", x: 0.43, y: 0.74, width: 0.07))
        tokens.append(token(Self.formatted(total), x: 0.52, y: 0.74, width: 0.07))
        return tokens
    }

    private static func token(
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat = 0.026
    ) -> SmartFishTicketTallyOCRTestToken {
        SmartFishTicketTallyOCRTestToken(
            text: text,
            boundingBox: CGRect(x: x, y: y, width: width, height: height)
        )
    }

    private static func formatted(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private static func syntheticTallyImage(weights: [Int]) -> UIImage {
        let size = CGSize(width: 1_700, height: 2_200)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setStroke()
            context.cgContext.setLineWidth(6)
            context.cgContext.stroke(CGRect(x: 18, y: 18, width: size.width - 36, height: size.height - 36))

            let crop = CGRect(x: 0.03, y: 0.16, width: 0.94, height: 0.48)
            func point(x: CGFloat, y: CGFloat) -> CGPoint {
                CGPoint(
                    x: (crop.minX + x * crop.width) * size.width,
                    y: (crop.minY + y * crop.height) * size.height
                )
            }
            func draw(_ text: String, x: CGFloat, y: CGFloat, size fontSize: CGFloat = 32) {
                text.draw(
                    at: point(x: x, y: y),
                    withAttributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
                        .foregroundColor: UIColor.black
                    ]
                )
            }

            draw("SPECIES", x: 0.04, y: 0.05)
            draw("DEL COND", x: 0.15, y: 0.05)
            draw("NUM", x: 0.29, y: 0.05)
            draw("POST TARE", x: 0.49, y: 0.05)
            draw("SOLD WEIGHT", x: 0.80, y: 0.05)
            draw("BRAILERS", x: 0.92, y: 0.05, size: 26)

            context.cgContext.setStrokeColor(UIColor.black.withAlphaComponent(0.72).cgColor)
            context.cgContext.setLineWidth(2)
            let boundaries: [CGFloat] = [0.035, 0.132, 0.215, 0.283, 0.385, 0.471, 0.573, 0.660, 0.772, 0.883, 0.972]
            let rowLines: [CGFloat] = [0.15, 0.20, 0.31, 0.42, 0.53, 0.64, 0.75, 0.86]
            for boundary in boundaries {
                let top = point(x: boundary, y: rowLines[0])
                let bottom = point(x: boundary, y: rowLines[rowLines.count - 1])
                context.cgContext.move(to: top)
                context.cgContext.addLine(to: bottom)
                context.cgContext.strokePath()
            }
            for rowLine in rowLines {
                let left = point(x: boundaries[0], y: rowLine)
                let right = point(x: boundaries[boundaries.count - 1], y: rowLine)
                context.cgContext.move(to: left)
                context.cgContext.addLine(to: right)
                context.cgContext.strokePath()
            }

            for (index, weight) in weights.enumerated() {
                let y = 0.23 + CGFloat(index) * 0.11
                draw("460 SALMON", x: 0.04, y: y)
                draw("01 WHOLE", x: 0.15, y: y)
                draw(String(100 + index), x: 0.29, y: y)
                draw(formatted(weight), x: 0.52, y: y)
                draw(formatted(weight), x: 0.84, y: y)
                draw("2", x: 0.95, y: y)
            }

            draw("TOTAL", x: 0.43, y: 0.74)
            draw(formatted(weights.reduce(0, +)), x: 0.52, y: 0.74)
        }
    }

    private static func cameraLikeImage(from source: UIImage) -> UIImage {
        let canvasSize = source.size
        return UIGraphicsImageRenderer(size: canvasSize).image { context in
            UIColor(white: 0.20, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: canvasSize))

            context.cgContext.saveGState()
            context.cgContext.translateBy(x: canvasSize.width / 2, y: canvasSize.height / 2)
            context.cgContext.rotate(by: 3.0 * .pi / 180)
            context.cgContext.scaleBy(x: 0.91, y: 0.91)
            source.draw(
                in: CGRect(
                    x: -canvasSize.width / 2,
                    y: -canvasSize.height / 2,
                    width: canvasSize.width,
                    height: canvasSize.height
                )
            )
            context.cgContext.restoreGState()

            let colors = [
                UIColor.black.withAlphaComponent(0.24).cgColor,
                UIColor.clear.cgColor,
                UIColor.white.withAlphaComponent(0.08).cgColor
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 0.58, 1]
            ) {
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: canvasSize.width, y: canvasSize.height),
                    options: []
                )
            }
        }
    }
}

private final class FishTicketTallyOCRFixtureBundleToken: NSObject {}

@MainActor
final class FishTicketTallyOCRMemoryMetricTests: XCTestCase {
    func testFiftySparseParserPassesWithXCTMemoryMetric() {
        let tokens: [SmartFishTicketTallyOCRTestToken] = [
            .init(text: "SPECIES", boundingBox: CGRect(x: 0.05, y: 0.05, width: 0.09, height: 0.026)),
            .init(text: "DEL COND", boundingBox: CGRect(x: 0.15, y: 0.05, width: 0.09, height: 0.026)),
            .init(text: "POST TARE", boundingBox: CGRect(x: 0.50, y: 0.05, width: 0.10, height: 0.026)),
            .init(text: "460 SALMON", boundingBox: CGRect(x: 0.04, y: 0.23, width: 0.10, height: 0.026)),
            .init(text: "01 WHOLE", boundingBox: CGRect(x: 0.15, y: 0.23, width: 0.09, height: 0.026)),
            .init(text: "100", boundingBox: CGRect(x: 0.29, y: 0.23, width: 0.06, height: 0.026)),
            .init(text: "1,300", boundingBox: CGRect(x: 0.52, y: 0.23, width: 0.07, height: 0.026)),
            .init(text: "TOTAL", boundingBox: CGRect(x: 0.43, y: 0.74, width: 0.07, height: 0.026))
        ]
        let options = XCTMeasureOptions()
        options.iterationCount = 1

        measure(metrics: [XCTMemoryMetric()], options: options) {
            for _ in 0..<50 {
                autoreleasepool {
                    let result = SmartFishTicketTallyOCRTestSupport.parseTokens(
                        tokens,
                        expectedSummarySoldWeight: 1_300
                    )
                    XCTAssertEqual(result?.rows.map(\.soldWeight), [1_300])
                }
            }
        }
    }
}
