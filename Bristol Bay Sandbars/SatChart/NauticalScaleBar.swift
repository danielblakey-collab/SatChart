import SwiftUI
import MapKit

/// Compact scale bar that fits in a HUD-height pill (similar to your top text boxes).
struct NauticalScaleBar: View {
    let metersPerPoint: Double

    // Target max width of the bar (not the container)
    private let maxBarWidth: CGFloat = 140
    private let minBarWidth: CGFloat = 70

    // Visual sizes (thin + compact)
    private let barHeight: CGFloat = 3
    private let containerHeight: CGFloat = 28

    var body: some View {
        let scale = niceScale(metersPerPoint: metersPerPoint, maxBarWidth: maxBarWidth)

        HStack(spacing: 8) {
            // thin bar
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: maxBarWidth, height: barHeight)

                Capsule()
                    .fill(Color.white)
                    .frame(width: max(scale.barWidth, minBarWidth), height: barHeight)
            }

            Text(scale.label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(height: containerHeight)
        .padding(.horizontal, 10)
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Scale selection

    private struct ScaleResult {
        let meters: Double
        let barWidth: CGFloat
        let label: String
    }

    /// Picks a "nice" distance (1/2/5 x 10^n) that fits in maxBarWidth.
    private func niceScale(metersPerPoint: Double, maxBarWidth: CGFloat) -> ScaleResult {
        let mpp = (metersPerPoint.isFinite && metersPerPoint > 0) ? metersPerPoint : 1

        // max distance we can represent with maxBarWidth
        let maxMeters = Double(maxBarWidth) * mpp
        let niceMeters = niceNumber(lessThanOrEqualTo: maxMeters)

        let width = CGFloat(niceMeters / mpp)

        return ScaleResult(
            meters: niceMeters,
            barWidth: min(max(width, minBarWidth), maxBarWidth),
            label: formatDistance(niceMeters)
        )
    }

    /// Returns 1/2/5 * 10^n <= x
    private func niceNumber(lessThanOrEqualTo x: Double) -> Double {
        guard x > 0, x.isFinite else { return 1 }

        let exp = floor(log10(x))
        let base = pow(10, exp)
        let f = x / base

        let niceF: Double
        if f >= 5 { niceF = 5 }
        else if f >= 2 { niceF = 2 }
        else { niceF = 1 }

        return niceF * base
    }

    private func formatDistance(_ meters: Double) -> String {
        if !meters.isFinite { return "—" }

        // nautical focus: show nm if large enough
        let nm = meters / 1852.0
        if nm >= 0.2 {
            if nm < 1 {
                return String(format: "%.2f nm", nm)
            } else {
                return String(format: "%.1f nm", nm)
            }
        }

        // otherwise feet
        let feet = meters * 3.28084
        if feet >= 1000 {
            let miles = meters / 1609.344
            return String(format: "%.2f mi", miles)
        } else {
            let rounded = (feet / 10.0).rounded() * 10.0
            return String(format: "%.0f ft", rounded)
        }
    }
}
