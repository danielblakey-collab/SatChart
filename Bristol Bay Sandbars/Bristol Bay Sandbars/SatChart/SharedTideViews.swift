import Foundation
import SwiftUI
import Charts

// Applies only to informational map readouts. Interactive button styles keep
// their normal backgrounds, borders, and status colors.
private struct NavigationReadoutBackgroundsVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var navigationReadoutBackgroundsVisible: Bool {
        get { self[NavigationReadoutBackgroundsVisibleKey.self] }
        set { self[NavigationReadoutBackgroundsVisibleKey.self] = newValue }
    }
}

enum TidePresentation {
    private static let compactTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let detailedTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static func compactEventLine(_ event: TideEvent) -> String {
        "\(event.kind.capitalized): \(compactTimeFormatter.string(from: event.time))"
    }

    static func detailedEventLine(_ event: TideEvent?) -> String {
        guard let event else { return "—" }

        let timeString = detailedTimeFormatter.string(from: event.time)
        if let height = event.heightFeet {
            return "\(timeString) • \(String(format: "%.1f", height)) ft"
        }
        return timeString
    }
}

struct SubtleHUDInlineButtonStyle: ButtonStyle {
    var backgroundOpacity: Double = 0.10
    var borderOpacity: Double = 0.16
    var horizontalPadding: CGFloat = 6
    var verticalPadding: CGFloat = 2

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(Color.white.opacity(configuration.isPressed ? backgroundOpacity * 1.35 : backgroundOpacity))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(
                        Color.white.opacity(configuration.isPressed ? borderOpacity * 1.1 : borderOpacity),
                        lineWidth: 1
                    )
            )
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .satChartPressFeedback(isPressed: configuration.isPressed)
    }
}

struct HUDStationToggleButtonStyle: ButtonStyle {
    let isOn: Bool
    var horizontalPadding: CGFloat = 6
    var verticalPadding: CGFloat = 2

    private var fillColor: Color {
        .black
    }

    private var foregroundColor: Color {
        isOn ? .green : .yellow
    }

    private var borderColor: Color {
        (isOn ? Color.green : Color.yellow).opacity(0.42)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(foregroundColor)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(fillColor.opacity(configuration.isPressed ? 0.82 : 0.96))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(borderColor, lineWidth: 0.8)
            )
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.94 : 1.0)
            .satChartPressFeedback(isPressed: configuration.isPressed)
    }
}

struct TideChartMarker: Identifiable {
    let date: Date
    let label: String
    var color: Color = .white.opacity(0.80)
    var annotationAlignment: Alignment = .leading

    var id: String {
        "\(date.timeIntervalSince1970)-\(label)"
    }
}

struct TideCurveChartView: View {
    @Environment(\.navigationReadoutBackgroundsVisible) private var showsBackgrounds
    let points: [TideCurvePoint]
    let referenceDate: Date
    var height: CGFloat = 150
    var showYAxis: Bool = true
    var showXAxis: Bool = true
    var labelColor: Color = .primary
    var gridColor: Color = .primary.opacity(0.14)
    var tickColor: Color = .primary.opacity(0.22)
    var axisLabelFont: Font = .caption2
    var emptyMessage: String = "24h tide chart unavailable"
    var emptyMessageColor: Color = .secondary
    var currentHeightLabel: String? = nil
    var currentHeightLabelFont: Font = .caption
    var currentHeightLabelColor: Color = .primary
    var selectedPoint: TideCurvePoint? = nil
    var selectedPointRuleColor: Color = .primary.opacity(0.45)
    var selectedPointMarkerColor: Color = .primary
    var onSelectPoint: ((TideCurvePoint?) -> Void)? = nil
    var showsReferenceRule: Bool = true
    var highlightedRange: ClosedRange<Date>? = nil
    var highlightedRangeColor: Color = .blue.opacity(0.12)
    var markers: [TideChartMarker] = []

    var body: some View {
        if points.isEmpty {
            Text(emptyMessage)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(emptyMessageColor)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .center)
        } else {
            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Height", point.heightFeet)
                    )
                    .interpolationMethod(.catmullRom)
                }

                if showsReferenceRule {
                    RuleMark(x: .value("Now", referenceDate))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }

                ForEach(markers) { marker in
                    RuleMark(x: .value(marker.label, marker.date))
                        .foregroundStyle(marker.color)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, alignment: marker.annotationAlignment) {
                            Text(marker.label)
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundColor(marker.color)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(showsBackgrounds ? 0.35 : 0))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                }

                if let selectedPoint {
                    RuleMark(x: .value("Selected", selectedPoint.time))
                        .foregroundStyle(selectedPointRuleColor)
                        .lineStyle(StrokeStyle(lineWidth: 1))

                    PointMark(
                        x: .value("Selected Time", selectedPoint.time),
                        y: .value("Selected Height", selectedPoint.heightFeet)
                    )
                    .foregroundStyle(selectedPointMarkerColor)
                    .symbolSize(50)
                }
            }
            .frame(height: height)
            .chartYAxis {
                if showYAxis {
                    AxisMarks(position: .leading)
                }
            }
            .chartXAxis {
                if showXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                        AxisGridLine()
                            .foregroundStyle(gridColor)
                        AxisTick()
                            .foregroundStyle(tickColor)
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date, format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)))
                                    .font(axisLabelFont)
                                    .foregroundColor(labelColor)
                            }
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    let plotRect = geometry[proxy.plotAreaFrame]

                    ZStack(alignment: .topLeading) {
                        if let highlightedRange,
                           let lowerX = proxy.position(forX: highlightedRange.lowerBound),
                           let upperX = proxy.position(forX: highlightedRange.upperBound) {
                            let minX = plotRect.minX + min(lowerX, upperX)
                            let maxX = plotRect.minX + max(lowerX, upperX)

                            Rectangle()
                                .fill(highlightedRangeColor)
                                .frame(width: max(maxX - minX, 2), height: plotRect.height)
                                .position(x: (minX + maxX) / 2, y: plotRect.midY)
                                .clipped()
                        }

                        if let currentHeightLabel,
                           showsReferenceRule,
                           let xPosition = proxy.position(forX: referenceDate) {
                            let clampedX = min(max(plotRect.minX + 30, plotRect.minX + xPosition), plotRect.maxX - 30)

                            Text(currentHeightLabel)
                                .font(currentHeightLabelFont)
                                .foregroundColor(currentHeightLabelColor)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.black.opacity(showsBackgrounds ? 0.35 : 0))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .position(x: clampedX, y: plotRect.minY + 10)
                        }

                        if onSelectPoint != nil {
                            Rectangle()
                                .fill(Color.clear)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onEnded { value in
                                            guard let onSelectPoint else { return }
                                            onSelectPoint(nearestPoint(at: value.location, proxy: proxy, geometry: geometry))
                                        }
                                )
                        }
                    }
                }
            }
        }
    }
    
    private func nearestPoint(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> TideCurvePoint? {
        guard !points.isEmpty else { return nil }

        let plotRect = geometry[proxy.plotAreaFrame]
        guard plotRect.contains(location) else { return nil }

        let relativeX = location.x - plotRect.minX
        guard let selectedDate = proxy.value(atX: relativeX, as: Date.self) else { return nil }

        return points.min { lhs, rhs in
            abs(lhs.time.timeIntervalSince(selectedDate)) < abs(rhs.time.timeIntervalSince(selectedDate))
        }
    }
}

struct MiniTideHUDBox: View {
    @Environment(\.navigationReadoutBackgroundsVisible) private var showsBackgrounds
    let snapshot: TidesWeatherSnapshot?
    let isLoading: Bool
    let errorMessage: String?
    var title: String = "Tides"
    var backgroundColor: Color = Color.white.opacity(0.08)
    var borderColor: Color = Color.white.opacity(0.10)
    var progressTint: Color = .white
    var chartHeight: CGFloat = 48
    var trailingStatusText: String? = nil
    var onTitleTap: (() -> Void)? = nil

    private var upcomingEvents: [TideEvent] {
        guard let snapshot else { return [] }
        return snapshot.upcomingTideEvents(limit: 2)
    }

    private var currentHeightText: String? {
        guard let height = currentHeightFeet else { return nil }
        return String(format: "%.1f ft", height)
    }

    private var currentHeightFeet: Double? {
        guard let snapshot else { return nil }

        if let exactHeight = snapshot.tides.currentWaterLevelFeet {
            return exactHeight
        }

        let points = snapshot.tides.curvePoints.sorted { $0.time < $1.time }
        guard points.count >= 2 else { return nil }
        let now = snapshot.fetchedAt

        if now <= points[0].time { return points[0].heightFeet }
        if now >= points[points.count - 1].time { return points[points.count - 1].heightFeet }

        for index in 0..<(points.count - 1) {
            let a = points[index]
            let b = points[index + 1]
            guard now >= a.time, now <= b.time else { continue }

            let total = b.time.timeIntervalSince(a.time)
            guard total > 0 else { return a.heightFeet }

            let elapsed = now.timeIntervalSince(a.time)
            let fraction = elapsed / total
            return a.heightFeet + ((b.heightFeet - a.heightFeet) * fraction)
        }

        return nil
    }

    private var stationDistanceValueText: String {
        guard let distance = snapshot?.tides.stationDistanceMiles else { return "—" }
        return String(format: "%.1f mi", distance)
    }

    private var stationDistanceLine: String {
        "Dist. to Station: \(stationDistanceValueText)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let onTitleTap {
                    Button(action: onTitleTap) {
                        Text(title)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(SubtleHUDInlineButtonStyle(horizontalPadding: 6, verticalPadding: 2))
                } else {
                    Text(title)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }

                Spacer(minLength: 0)

                if isLoading, snapshot != nil {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(progressTint)
                }

                if let trailingStatusText {
                    Text(trailingStatusText)
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundColor(showsBackgrounds ? Color(red: 1.0, green: 0.86, blue: 0.48) : .white)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.black.opacity(showsBackgrounds ? 0.24 : 0))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color(red: 1.0, green: 0.86, blue: 0.48).opacity(showsBackgrounds ? 0.38 : 0), lineWidth: 0.8)
                        )
                        .accessibilityLabel(trailingStatusText)
                } else {
                    Text(stationDistanceLine)
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(showsBackgrounds ? 0.84 : 1))
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                }
            }

            chartBody

            if !upcomingEvents.isEmpty {
                HStack(alignment: .center, spacing: 6) {
                    ForEach(upcomingEvents) { event in
                        Text(TidePresentation.compactEventLine(event))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.80)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var chartBody: some View {
        if let snapshot {
            TideCurveChartView(
                points: snapshot.tides.curvePoints,
                referenceDate: snapshot.fetchedAt,
                height: chartHeight,
                showYAxis: false,
                showXAxis: false,
                labelColor: .white.opacity(showsBackgrounds ? 0.72 : 1),
                gridColor: .white.opacity(0.14),
                tickColor: .white.opacity(0.22),
                axisLabelFont: .system(size: 8, weight: .semibold, design: .rounded),
                emptyMessage: errorMessage == nil ? "Tide chart unavailable" : "Tides unavailable",
                emptyMessageColor: .white.opacity(showsBackgrounds ? 0.72 : 1),
                currentHeightLabel: currentHeightText,
                currentHeightLabelFont: .system(size: 11, weight: .semibold, design: .rounded),
                currentHeightLabelColor: .white
            )
            .frame(maxWidth: .infinity, minHeight: chartHeight, maxHeight: chartHeight)
        } else if isLoading {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)

                Text("Loading tide chart…")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(showsBackgrounds ? 0.80 : 1))
            }
            .frame(maxWidth: .infinity, minHeight: chartHeight, maxHeight: chartHeight, alignment: .center)
        } else {
            Text(errorMessage == nil ? "Tide chart unavailable" : "Tides unavailable")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(showsBackgrounds ? 0.72 : 1))
                .frame(maxWidth: .infinity, minHeight: chartHeight, maxHeight: chartHeight, alignment: .center)
        }
    }
}
