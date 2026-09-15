import Testing
import SwiftUI
@testable import SatChart

@MainActor
struct PortraitTopHUDLayoutTests {
    private let fullPortraitWidths: [CGFloat] = [716, 740, 782, 806, 996]
    private let narrowWidths: [CGFloat] = [292, 347, 572]

    private func plan(width: CGFloat,
                      layout: PortraitTopHUDLayout = PortraitTopHUDLayout(),
                      readoutsHeight: CGFloat = 53.5,
                      locationHeight: CGFloat = 30) -> PortraitTopHUDLayout.Arrangement {
        layout.arrangement(availableWidth: width,
                           primarySize: CGSize(width: 222, height: 48),
                           readoutsSize: CGSize(width: 272, height: readoutsHeight),
                           sharingSize: CGSize(width: 106, height: 48),
                           locationSize: CGSize(width: 350, height: locationHeight),
                           tideSize: CGSize(width: 230, height: 106),
                           actionsSize: CGSize(width: 48, height: 106))
    }

    private func expectContentFits(_ result: PortraitTopHUDLayout.Arrangement) {
        let bounds = CGRect(origin: .zero, size: result.size)
        let frames = result.frames.filter { !$0.isEmpty }
        for frame in frames {
            #expect(bounds.contains(frame), "Every visible group must remain inside the HUD")
        }
        for first in frames.indices {
            for second in frames.indices where second > first {
                #expect(!frames[first].intersects(frames[second]), "HUD groups must never overlap")
            }
        }
    }

    @Test func approvedPortraitUsesTheLandscapePositionsAndNarrowsTideFirst() {
        let result = plan(width: 782)
        #expect(result.mode == .inlineTide)
        #expect(result.size == CGSize(width: 782, height: 106))
        #expect(result.primaryFrame == CGRect(x: 0, y: 0, width: 222, height: 48))
        #expect(result.readoutsFrame == CGRect(x: 232, y: 0, width: 272, height: 53.5))
        #expect(result.sharingFrame == CGRect(x: 0, y: 58, width: 106, height: 48))
        #expect(result.locationFrame == CGRect(x: 112, y: 67, width: 392, height: 30))
        #expect(result.tideFrame == CGRect(x: 514, y: 0, width: 210, height: 106))
        #expect(result.actionsFrame == CGRect(x: 734, y: 0, width: 48, height: 106))
        expectContentFits(result)

        for width in fullPortraitWidths {
            let plan = plan(width: width)
            #expect(plan.mode == .inlineTide)
            #expect(plan.primaryFrame.size == CGSize(width: 222, height: 48))
            #expect(plan.readoutsFrame.width >= 200)
            #expect(plan.actionsFrame.maxX == width && plan.actionsFrame.minY == 0)
            #expect(plan.tideFrame.width >= 200 && plan.tideFrame.width <= 230)
            #expect(plan.tideFrame.minY == 0)
            expectContentFits(plan)
        }
        #expect(plan(width: 806).tideFrame.width == 230)
    }

    @Test func narrowWindowsMoveTideBelowAndKeepFullSizeControls() {
        for width in narrowWidths {
            let result = plan(width: width)
            #expect(result.mode == .tideBelow)
            #expect(result.primaryFrame == CGRect(x: 0, y: 0, width: 222, height: 48))
            #expect(result.sharingFrame.size == CGSize(width: 106, height: 48))
            #expect(result.actionsFrame.size == CGSize(width: 48, height: 106))
            #expect(result.actionsFrame.maxX == width && result.actionsFrame.minY == 0)
            #expect(result.tideFrame.width == 230 && result.tideFrame.maxX == width)
            #expect(result.tideFrame.minY > result.locationFrame.maxY)
            #expect(result.tideFrame.minY > result.actionsFrame.maxY)
            expectContentFits(result)
        }
        #expect(plan(width: 347).readoutsFrame.minY > plan(width: 347).primaryFrame.maxY)
        #expect(plan(width: 347).locationFrame.minY > plan(width: 347).sharingFrame.maxY)
        #expect(plan(width: 572).readoutsFrame.minY == 0)
        #expect(plan(width: 572).sharingFrame.midY == plan(width: 572).locationFrame.midY)
    }

    @Test func longerReadoutsGrowRowsAndKeepTheTopControlsAnchored() {
        for width in fullPortraitWidths + narrowWidths {
            let ordinary = plan(width: width)
            let expanded = plan(width: width, readoutsHeight: 110, locationHeight: 85)
            #expect(expanded.size.height > ordinary.size.height)
            #expect(expanded.primaryFrame == ordinary.primaryFrame)
            #expect(expanded.actionsFrame == ordinary.actionsFrame)
            #expect(expanded.readoutsFrame.height == 110)
            #expect(expanded.locationFrame.height == 85)
            #expect(expanded.sharingFrame.minY > expanded.readoutsFrame.maxY)
            expectContentFits(expanded)
        }

        let sharingOnly = plan(width: 782, layout: PortraitTopHUDLayout(showLocation: false),
                               readoutsHeight: 110)
        #expect(sharingOnly.sharingFrame.minY == 58,
                "Sharing stays below the primary buttons when it does not overlap taller readouts")
        expectContentFits(sharingOnly)

        let locationOnly = plan(width: 782, layout: PortraitTopHUDLayout(showSharing: false))
        #expect(locationOnly.locationFrame.minY == 63.5,
                "Without sharing buttons, location clears the full height of the readouts")
        expectContentFits(locationOnly)
    }

    @Test func hiddenGroupsReleaseSpaceWithoutChangingOtherAnchors() {
        for width: CGFloat in [292, 572, 716, 782] {
            for mask in 0..<32 {
                let visible = (0..<5).map { mask & (1 << $0) != 0 }
                let layout = PortraitTopHUDLayout(showReadouts: visible[0], showSharing: visible[1],
                                                  showLocation: visible[2], showTide: visible[3], showActions: visible[4])
                let result = plan(width: width, layout: layout)
                #expect(result.primaryFrame == CGRect(x: 0, y: 0, width: 222, height: 48))
                for index in 0..<5 where !visible[index] {
                    #expect(result.frames[index + 1] == .zero)
                }
                if visible[4] { #expect(result.actionsFrame.maxX == width && result.actionsFrame.minY == 0) }
                expectContentFits(result)
            }
        }
        let full = plan(width: 782)
        let noTide = plan(width: 782, layout: PortraitTopHUDLayout(showTide: false))
        #expect(noTide.readoutsFrame.width > full.readoutsFrame.width)
        #expect(noTide.locationFrame.width > full.locationFrame.width)
        let noSharing = plan(width: 782, layout: PortraitTopHUDLayout(showSharing: false))
        #expect(noSharing.locationFrame.minX == 0)
        #expect(noSharing.locationFrame.width > full.locationFrame.width)
    }
}
