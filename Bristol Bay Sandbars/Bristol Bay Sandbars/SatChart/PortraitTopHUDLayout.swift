import SwiftUI

/// Keeps the landscape HUD groups in the same relative positions on an iPad
/// in portrait. Children must use stable wrappers in this order: primary
/// controls, status readouts, sharing controls, location, tide, set/waypoint.
/// Presence flags reclaim space; callers omit the contents of hidden wrappers.
struct PortraitTopHUDLayout: Layout {
    var showReadouts = true
    var showSharing = true
    var showLocation = true
    var showTide = true
    var showActions = true
    /// The measured Location/Cursor label width. Both readouts use the same
    /// horizontal padding, so subtracting this label and its gap aligns the
    /// first latitude box with the visible Speed text.
    var locationLabelWidth: CGFloat? = nil
    var minimumHeight: CGFloat = 106
    var preferredTideWidth: CGFloat = 230
    var minimumTideWidth: CGFloat = 200
    var minimumReadoutWidth: CGFloat = 200
    var minimumLocationWidth: CGFloat = 220
    var horizontalSpacing: CGFloat = 10
    var verticalSpacing: CGFloat = 10
    var sharingLocationSpacing: CGFloat = 6

    enum Mode: Equatable {
        case inlineTide
        case tideBelow
    }

    struct Arrangement: Equatable {
        let mode: Mode
        let size: CGSize
        let primaryFrame: CGRect
        let readoutsFrame: CGRect
        let sharingFrame: CGRect
        let locationFrame: CGRect
        let tideFrame: CGRect
        let actionsFrame: CGRect

        var frames: [CGRect] {
            [primaryFrame, readoutsFrame, sharingFrame, locationFrame, tideFrame, actionsFrame]
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 6 else { return .zero }
        return measuredArrangement(width: resolvedWidth(proposal.width, subviews: subviews),
                                   subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 6 else { return }
        let plan = measuredArrangement(width: bounds.width, subviews: subviews)
        for (index, frame) in plan.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    /// Widths describe each group's ideal size. Heights describe its measured
    /// size at the allocated width, so longer readouts can grow the HUD.
    func arrangement(availableWidth: CGFloat,
                     primarySize: CGSize,
                     readoutsSize: CGSize,
                     sharingSize: CGSize,
                     locationSize: CGSize,
                     tideSize: CGSize,
                     actionsSize: CGSize) -> Arrangement {
        let width = nonnegative(availableWidth)
        let gap = nonnegative(horizontalSpacing)
        let rowGap = nonnegative(verticalSpacing)
        let locationGap = nonnegative(sharingLocationSpacing)
        let primaryWidth = min(width, nonnegative(primarySize.width))
        let sharingWidth = showSharing ? nonnegative(sharingSize.width) : 0
        let actionsWidth = showActions ? min(width, nonnegative(actionsSize.width)) : 0
        let actionsReserve = showActions ? actionsWidth + gap : 0
        let availableBesideActions = max(0, width - actionsReserve)

        let idealFirstRow = primaryWidth + (showReadouts ? gap + nonnegative(readoutsSize.width) : 0)
        let preferredLocationX = locationLeading(
            sharingWidth: sharingWidth,
            readoutsX: showReadouts ? primaryWidth + gap : nil
        )
        let idealSecondRow = showLocation
            ? preferredLocationX + nonnegative(locationSize.width)
            : sharingWidth
        let idealLeftWidth = max(idealFirstRow, idealSecondRow)
        let minimumFirstRow = primaryWidth + (showReadouts ? gap + nonnegative(minimumReadoutWidth) : 0)
        let minimumSecondRow = sharingWidth
            + (showSharing && showLocation ? locationGap : 0)
            + (showLocation ? nonnegative(minimumLocationWidth) : 0)
        let minimumLeftWidth = max(minimumFirstRow, minimumSecondRow)
        let tideMinimum = nonnegative(minimumTideWidth)
        let tidePreferred = max(tideMinimum, nonnegative(preferredTideWidth))
        let tideFitsBesideLeft = showTide && availableBesideActions >= minimumLeftWidth + gap + tideMinimum
        let mode: Mode = showTide && !tideFitsBesideLeft ? .tideBelow : .inlineTide
        let tideWidth: CGFloat
        let leftWidth: CGFloat
        if tideFitsBesideLeft {
            // Shrink only the tide panel first, preserving the left groups'
            // natural sizes when the available width permits it.
            tideWidth = min(tidePreferred, max(tideMinimum, availableBesideActions - gap - idealLeftWidth))
            leftWidth = max(0, availableBesideActions - gap - tideWidth)
        } else {
            tideWidth = showTide ? min(width, tidePreferred) : 0
            leftWidth = availableBesideActions
        }

        let primary = CGRect(x: 0, y: 0, width: min(leftWidth, primaryWidth),
                             height: nonnegative(primarySize.height))
        var readouts = CGRect.zero
        var sharing = CGRect.zero
        var location = CGRect.zero
        var tide = CGRect.zero
        let actions = showActions
            ? CGRect(x: width - actionsWidth, y: 0, width: actionsWidth, height: nonnegative(actionsSize.height))
            : .zero

        var leftBottom = primary.maxY
        if showReadouts {
            let remaining = leftWidth - primary.width - gap
            if remaining >= nonnegative(minimumReadoutWidth) {
                readouts = CGRect(x: primary.maxX + gap, y: 0, width: remaining,
                                  height: nonnegative(readoutsSize.height))
            } else {
                readouts = CGRect(x: 0, y: primary.maxY + rowGap, width: leftWidth,
                                  height: nonnegative(readoutsSize.height))
            }
            leftBottom = max(leftBottom, readouts.maxY)
        }

        if showSharing || showLocation {
            // When the readouts sit beside the primary buttons, their extra
            // height need only move a lower group that actually overlaps them.
            // A 30-point location row has nine points of clearance when it is
            // centered beside the 48-point sharing buttons.
            let readoutsBesidePrimary = showReadouts && readouts.minY == 0
            let secondRowY = (readoutsBesidePrimary ? primary.maxY : leftBottom) + rowGap
            let preferredLocationX = locationLeading(
                sharingWidth: sharingWidth,
                readoutsX: readoutsBesidePrimary ? readouts.minX : nil
            )
            let locationX = leftWidth >= preferredLocationX + nonnegative(minimumLocationWidth)
                ? preferredLocationX : 0
            let canShareRow = showSharing && showLocation
                && locationX >= sharingWidth + locationGap
                && leftWidth >= locationX + nonnegative(minimumLocationWidth)
            if canShareRow {
                let rowHeight = max(nonnegative(sharingSize.height), nonnegative(locationSize.height))
                let sharingInset = (rowHeight - nonnegative(sharingSize.height)) / 2
                let locationInset = (rowHeight - nonnegative(locationSize.height)) / 2
                var rowY = secondRowY
                if readoutsBesidePrimary {
                    if sharingWidth > readouts.minX {
                        rowY = max(rowY, readouts.maxY + rowGap - sharingInset)
                    }
                    if locationX < readouts.maxX && leftWidth > readouts.minX {
                        rowY = max(rowY, readouts.maxY + rowGap - locationInset)
                    }
                }
                sharing = CGRect(x: 0, y: rowY + sharingInset,
                                 width: sharingWidth, height: nonnegative(sharingSize.height))
                location = CGRect(x: locationX,
                                  y: rowY + locationInset,
                                  width: leftWidth - locationX,
                                  height: nonnegative(locationSize.height))
            } else {
                var nextY = secondRowY
                if showSharing {
                    if readoutsBesidePrimary && sharingWidth > readouts.minX {
                        nextY = max(nextY, readouts.maxY + rowGap)
                    }
                    sharing = CGRect(x: 0, y: nextY, width: min(leftWidth, sharingWidth),
                                     height: nonnegative(sharingSize.height))
                    nextY = sharing.maxY + rowGap
                }
                if showLocation {
                    if readoutsBesidePrimary {
                        nextY = max(nextY, readouts.maxY + rowGap)
                    }
                    location = CGRect(x: locationX, y: nextY, width: leftWidth - locationX,
                                      height: nonnegative(locationSize.height))
                }
            }
            leftBottom = max(leftBottom, sharing.maxY, location.maxY)
        }

        if showTide {
            if tideFitsBesideLeft {
                tide = CGRect(x: leftWidth + gap, y: 0, width: tideWidth, height: nonnegative(tideSize.height))
            } else {
                tide = CGRect(x: width - tideWidth, y: max(leftBottom, actions.maxY) + rowGap,
                              width: tideWidth, height: nonnegative(tideSize.height))
            }
        }

        return Arrangement(mode: mode,
                           size: CGSize(width: width, height: max(nonnegative(minimumHeight), leftBottom, tide.maxY, actions.maxY)),
                           primaryFrame: primary, readoutsFrame: readouts, sharingFrame: sharing,
                           locationFrame: location, tideFrame: tide, actionsFrame: actions)
    }

    private func measuredArrangement(width: CGFloat, subviews: Subviews) -> Arrangement {
        let visible = [true, showReadouts, showSharing, showLocation, showTide, showActions]
        let ideals = subviews.enumerated().map { index, subview in
            visible[index] ? subview.sizeThatFits(.unspecified) : .zero
        }
        var measured = ideals
        var effectiveLayout = self
        var plan = effectiveLayout.arrangement(availableWidth: width, sizes: measured)
        // A fixed-size child may need more width than the nominal minimum.
        // Remeasuring after a reflow avoids retaining the previous row's height.
        for _ in 0..<3 {
            for index in 0..<6 where visible[index] {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: plan.frames[index].width, height: nil))
                measured[index] = CGSize(width: ideals[index].width, height: size.height)
                if index == 1, size.width > plan.readoutsFrame.width + 0.5 {
                    effectiveLayout.minimumReadoutWidth = max(effectiveLayout.minimumReadoutWidth, size.width)
                }
                if index == 3, size.width > plan.locationFrame.width + 0.5 {
                    effectiveLayout.minimumLocationWidth = max(effectiveLayout.minimumLocationWidth, size.width)
                }
            }
            let updated = effectiveLayout.arrangement(availableWidth: width, sizes: measured)
            if updated == plan { return updated }
            plan = updated
        }
        return plan
    }

    private func arrangement(availableWidth: CGFloat, sizes: [CGSize]) -> Arrangement {
        arrangement(availableWidth: availableWidth, primarySize: sizes[0], readoutsSize: sizes[1],
                    sharingSize: sizes[2], locationSize: sizes[3], tideSize: sizes[4], actionsSize: sizes[5])
    }

    private func resolvedWidth(_ proposed: CGFloat?, subviews: Subviews) -> CGFloat {
        if let proposed, proposed.isFinite { return max(0, proposed) }
        let gap = nonnegative(horizontalSpacing)
        let primary = nonnegative(subviews[0].sizeThatFits(.unspecified).width)
        let readouts = showReadouts ? max(nonnegative(minimumReadoutWidth), nonnegative(subviews[1].sizeThatFits(.unspecified).width)) : 0
        let sharing = showSharing ? nonnegative(subviews[2].sizeThatFits(.unspecified).width) : 0
        let location = showLocation ? max(nonnegative(minimumLocationWidth), nonnegative(subviews[3].sizeThatFits(.unspecified).width)) : 0
        let firstRow = primary + (showReadouts ? gap + readouts : 0)
        let locationX = locationLeading(sharingWidth: sharing,
                                        readoutsX: showReadouts ? primary + gap : nil)
        let secondRow = showLocation ? locationX + location : sharing
        let tide = showTide ? gap + max(nonnegative(minimumTideWidth), nonnegative(preferredTideWidth)) : 0
        let actions = showActions ? gap + nonnegative(subviews[5].sizeThatFits(.unspecified).width) : 0
        return max(firstRow, secondRow) + tide + actions
    }

    private func locationLeading(sharingWidth: CGFloat, readoutsX: CGFloat?) -> CGFloat {
        let gap = nonnegative(sharingLocationSpacing)
        let leading = showSharing ? sharingWidth + gap : 0
        guard let locationLabelWidth, let readoutsX else { return leading }
        return max(leading, readoutsX - nonnegative(locationLabelWidth) - gap)
    }

    private func nonnegative(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, value) : 0
    }
}
