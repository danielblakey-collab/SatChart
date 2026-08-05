import Foundation
import SwiftUI
import UniformTypeIdentifiers

private let deepResearchTablesShellBlueUIColor = UIColor(red: 0.03, green: 0.23, blue: 0.48, alpha: 1.0)
private let deepResearchTablesShellBlue = Color(uiColor: deepResearchTablesShellBlueUIColor)
private let deepResearchTablesBackgroundTop = Color(red: 0.02, green: 0.15, blue: 0.30)
private let deepResearchTablesBackgroundBottom = Color(red: 0.01, green: 0.08, blue: 0.18)
private let deepResearchTablesNavBarColor = Color(red: 0.06, green: 0.24, blue: 0.55)
private let deepResearchTablesSelectorHeight: CGFloat = 33
private let deepResearchDistrictSelectedPill = Color(red: 0.10, green: 0.35, blue: 0.20)

private enum TableMetricSetMode {
    case dailyAndCumulative
    case seasonTotalsAndAverages
}

private struct TableMonthDayOption: Hashable, Identifiable {
    let month: Int
    let day: Int

    var id: String { String(format: "%02d-%02d", month, day) }
    var label: String { "\(month)/\(day)" }
}

private struct CSVExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
struct DeepResearchTablesView: View {
    @Environment(\.appDatabase) private var appDatabase
    @StateObject private var vm = DeepResearchTablesVM()

    @State private var showExportAlert = false
    @State private var exportAlertTitle = "CSV Export"
    @State private var exportAlertMessage = ""
    @State private var flashingPresetIDs: Set<String> = []
    @State private var metricSetMode: TableMetricSetMode = .dailyAndCumulative
    @State private var exportDocument: CSVExportDocument?
    @State private var isPresentingCSVExporter = false
    @State private var exportSuggestedFilename = "deep_research_table"
    private let availableYears = Array(2015...2025)
    private let allowedMonthDays = Self.buildAllowedMonthDays()

    private let maxDisplayRows = 5_000
    private let maxDisplayCells = 20_000

    var body: some View {
        ZStack {
            deepResearchTablesShellBlue.ignoresSafeArea()
            HostingBackgroundFixer(color: deepResearchTablesShellBlueUIColor)
                .frame(width: 0, height: 0)

            LinearGradient(
                colors: [deepResearchTablesBackgroundTop, deepResearchTablesBackgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: [.top, .leading, .trailing])

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    headerCard
                    metricsControlCard
                    dateRangeCard
                    districtsCard

                    ForEach(visibleMetricGroups, id: \.self) { group in
                        metricGroupCard(group)
                    }

                    if vm.filters.selectedMetrics.isEmpty {
                        noMetricsSelectedMessage
                    }

                    outputCard

                    if let preview = vm.preview {
                        querySummaryCard(preview)
                        columnsPreviewCard
                        resultsTableCard
                    } else {
                        resultsPlaceholderCard
                    }

                    if let errorMessage = vm.errorMessage, !errorMessage.isEmpty {
                        errorCard(errorMessage)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 0)
            }
            .background(Color.clear)
        }
        .navigationTitle("Tables")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(deepResearchTablesNavBarColor, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            BBMenuAppearance.applyNavBar()
            clampFiltersToAllowedRange()
        }
        .alert(exportAlertTitle, isPresented: $showExportAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportAlertMessage)
        }
        .fileExporter(
            isPresented: $isPresentingCSVExporter,
            document: exportDocument ?? CSVExportDocument(data: Data()),
            contentType: .commaSeparatedText,
            defaultFilename: exportSuggestedFilename
        ) { result in
            switch result {
            case .success:
                break
            case .failure(let error):
                exportAlertTitle = "CSV Export Error"
                exportAlertMessage = error.localizedDescription
                showExportAlert = true
            }
        }
    }

    private var headerCard: some View {
        VStack(spacing: 8) {
            Text("Deep Research — Tables")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .center)

            Text("Generate date-range tables across districts, derived metrics, raw inputs and optional river-level escapement detail.")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(14)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var dateRangeCard: some View {
        TablesSectionCard(title: dateRangeSectionTitle) {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: "Allowed range: 6/12–8/20 • \(String(availableYears.first ?? 2015))–\(String(availableYears.last ?? 2025))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.68))

                dateSelectorRow(
                    title: "Start",
                    year: startYear,
                    monthDay: startMonthDay,
                    showMonthDay: metricSetMode == .dailyAndCumulative,
                    onYearSelect: { updateDate(isStart: true, year: $0, monthDay: nil) },
                    onMonthDaySelect: { updateDate(isStart: true, year: nil, monthDay: $0) }
                )

                dateSelectorRow(
                    title: "End",
                    year: endYear,
                    monthDay: endMonthDay,
                    showMonthDay: metricSetMode == .dailyAndCumulative,
                    onYearSelect: { updateDate(isStart: false, year: $0, monthDay: nil) },
                    onMonthDaySelect: { updateDate(isStart: false, year: nil, monthDay: $0) }
                )

                HStack(spacing: 8) {
                    presetActionButton(title: "Same Year", id: "sameYear") {
                        updateFilters { filters in
                            let year = clampedYear(from: filters.startDate)
                            let currentEnd = monthDayOption(for: filters.endDate)
                            filters.endDate = makeDate(year: year, month: currentEnd.month, day: currentEnd.day) ?? filters.endDate
                            normalizeDateRange(&filters)
                        }
                    }

                    if metricSetMode == .dailyAndCumulative {
                        presetActionButton(title: "Full Season", id: "fullSeason") {
                            updateFilters { filters in
                                let startYear = clampedYear(from: filters.startDate)
                                let endYear = clampedYear(from: filters.endDate)
                                filters.startDate = makeDate(year: startYear, month: 6, day: 12) ?? filters.startDate
                                filters.endDate = makeDate(year: endYear, month: 8, day: 20) ?? filters.endDate
                                normalizeDateRange(&filters)
                            }
                        }
                    }
                }
            }
        }
    }

    private var districtsCard: some View {
        TablesSectionCard(title: "Districts") {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    smallActionButton("All") {
                        updateFilters { filters in
                            filters.selectedDistricts = Set(District.allCases)
                            for district in filters.selectedDistricts {
                                if filters.selectedRiversByDistrict[district] == nil {
                                    filters.selectedRiversByDistrict[district] = Set(vm.riverOptions(for: district).map(\.key))
                                }
                            }
                        }
                    }

                    smallActionButton("Clear") {
                        updateFilters {
                            $0.selectedDistricts = []
                            $0.selectedRiversByDistrict = [:]
                        }
                    }

                    Spacer(minLength: 0)
                }

                LazyVGrid(columns: buttonGridColumns(count: 3), spacing: 8) {
                    ForEach(District.allCases) { district in
                        districtChip(district)
                    }
                }
            }
        }
    }


    private var metricsControlCard: some View {
        TablesSectionCard(title: "Metric Sets") {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: buttonGridColumns(count: 2), spacing: 8) {
                    metricModeButton(
                        title: "Daily Metrics",
                        isSelected: metricSetMode == .dailyAndCumulative,
                        isDimmed: metricSetMode == .seasonTotalsAndAverages
                    ) {
                        setMetricSetMode(.dailyAndCumulative)
                    }

                    metricModeButton(
                        title: "Seasonal Metrics",
                        isSelected: metricSetMode == .seasonTotalsAndAverages,
                        isDimmed: metricSetMode == .dailyAndCumulative
                    ) {
                        setMetricSetMode(.seasonTotalsAndAverages)
                    }
                }

                Text(metricSetModeDescription)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.78))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Metrics derived from models are displayed in italics.")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.68))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func metricGroupCard(_ group: DeepResearchTableMetricGroup) -> some View {
        let sectionMetrics = visibleMetrics(for: group)

        return TablesSectionCard(title: group.title) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    smallActionButton("All") {
                        updateFilters { filters in
                            filters.selectedMetrics.formUnion(sectionMetrics)
                        }
                    }

                    smallActionButton("Clear") {
                        updateFilters { filters in
                            filters.selectedMetrics.subtract(sectionMetrics)
                        }
                    }

                    Spacer(minLength: 0)

                    Text("\(selectedCount(in: group))/\(sectionMetrics.count)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.65))
                }

                LazyVGrid(columns: metricGridColumns, spacing: 8) {
                    ForEach(sectionMetrics) { metric in
                        metricChip(metric)
                    }
                }

                if group == .outcome &&
                    (
                        metricSetMode == .dailyAndCumulative ||
                        (metricSetMode == .seasonTotalsAndAverages && vm.filters.selectedMetrics.contains(.totalEscapement))
                    ) {
                    outcomeEscapementDetailPanel
                }

                sectionFootnotes(for: group)
            }
        }
    }

    private var outcomeEscapementDetailPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            Text("Escapement Detail")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .underline(true, color: Color.white.opacity(0.55))

            Toggle(isOn: includeRiverEscapementBreakdownBinding) {
                Text("River-level escapement")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            }
            .tint(.blue)

            if vm.filters.includeRiverEscapementBreakdown {
                if metricSetMode == .dailyAndCumulative {
                    VStack(spacing: 8) {
                        Toggle(isOn: includeRiverDailyEscColumnsBinding) {
                            Text("River Daily Escapement")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                        }
                        .tint(.blue)

                        Toggle(isOn: includeRiverCumulativeEscColumnsBinding) {
                            Text("River Cumulative Escapement")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                        }
                        .tint(.blue)
                    }

                    if !hasEscapementMetricsSelected {
                        Text("Select Daily Escapement or Cumulative Escapement above to make river-level columns meaningful.")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.68))
                    }
                }

                ForEach(selectedDistrictList, id: \.self) { district in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(vm.districtLabel(district))
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundColor(.white)

                            Spacer(minLength: 0)

                            smallActionButton("All") {
                                let all = Set(vm.riverOptions(for: district).map(\.key))
                                updateFilters { $0.selectedRiversByDistrict[district] = all }
                            }

                            smallActionButton("Clear") {
                                updateFilters { $0.selectedRiversByDistrict[district] = [] }
                            }
                        }

                        LazyVGrid(columns: metricGridColumns, spacing: 8) {
                            ForEach(vm.riverOptions(for: district)) { river in
                                riverChip(river, district: district)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    private var outputCard: some View {
        TablesSectionCard(title: "Output") {
            VStack(spacing: 10) {
                Picker("Output", selection: outputModeBinding) {
                    ForEach(DeepResearchTablesOutputMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 8) {
                    Button {
                        generateTableTapped()
                    } label: {
                        Text(vm.isLoading ? "Generating…" : "Generate Table")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: deepResearchTablesSelectorHeight, maxHeight: deepResearchTablesSelectorHeight)
                            .background(generateButtonBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(SatChartPressFeedbackButtonStyle())
                    .disabled(!canGenerateDisplay)

                    Button {
                        exportCSVTapped()
                    } label: {
                        Text(vm.isLoading ? "Preparing…" : "Export CSV")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: deepResearchTablesSelectorHeight, maxHeight: deepResearchTablesSelectorHeight)
                            .background(exportButtonBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(SatChartPressFeedbackButtonStyle())
                    .disabled(!canExportCSV)
                }

                if vm.filters.outputMode == .display && isDisplayRequestTooLarge {
                    Text(displayLimitMessage)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.red.opacity(0.95))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if vm.filters.outputMode == .csv {
                    Text("CSV Export will prompt you to choose a save location and file name without rendering the full table in-app. CSV Export supports large file sizes.")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.68))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !vm.canGenerate {
                    Text("Select at least one district, one metric, and a valid date range to generate a table.")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.68))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var resultsPlaceholderCard: some View {
        TablesSectionCard(title: "Results") {
            VStack(spacing: 8) {
                Text("No table generated yet.")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)

                Text("Choose a date range, districts, and metrics, then tap Generate Table.")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }

    private func querySummaryCard(_ preview: DeepResearchTablesPreview) -> some View {
        TablesSectionCard(title: "Query Summary") {
            VStack(alignment: .leading, spacing: 10) {
                if metricSetMode == .seasonTotalsAndAverages {
                    LazyVGrid(columns: summaryGridColumns, alignment: .leading, spacing: 6) {
                        compactSummaryText("Rows: \(vm.rows.count)")
                        compactSummaryText("Columns: \(vm.columns.count)")
                        compactSummaryText("Districts: \(preview.districtCount)")
                        compactSummaryText("Years: \(startYear)–\(endYear)")
                    }
                } else {
                    LazyVGrid(columns: summaryGridColumns, alignment: .leading, spacing: 6) {
                        compactSummaryText("Rows: \(vm.rows.count)")
                        compactSummaryText("Columns: \(vm.columns.count)")
                        compactSummaryText("Cell Count: \(estimatedCellCount)")
                        compactSummaryText("Districts: \(preview.districtCount)")
                    }

                    Text("Date Range: \(preview.dateRangeLabel)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.78))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    private var columnsPreviewCard: some View {
        TablesSectionCard(title: "Selected Columns") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Date and District are always included. The metrics below reflect the current selections.")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.68))

                LazyVGrid(columns: summaryGridColumns, alignment: .leading, spacing: 6) {
                    ForEach(displayMetricColumns, id: \.id) { column in
                        Text(column.title)
                            .font(previewFont(for: column.id))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
    private var resultsTableCard: some View {
        TablesSectionCard(title: "Result Table") {
            VStack(alignment: .leading, spacing: 10) {
                if vm.rows.isEmpty || vm.columns.isEmpty {
                    Text("No rows returned for the current selection.")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.72))
                } else {
                    Text("Displaying all \(vm.rows.count) rows.")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.68))

                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(spacing: 0) {
                            tableHeaderRow
                            ForEach(vm.rows) { row in
                                tableDataRow(row)
                            }
                        }
                    }
                }
            }
        }
    }

    private var tableHeaderRow: some View {
        HStack(spacing: 0) {
            ForEach(vm.columns) { column in
                Text(column.title)
                    .font(headerFont(for: column.id))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .frame(width: width(for: column), height: 34)
                    .padding(.horizontal, 6)
                    .background(Color.white.opacity(0.14))
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 1)
                    }
            }
        }
    }

    private func tableDataRow(_ row: DeepResearchTableRow) -> some View {
        HStack(spacing: 0) {
            ForEach(vm.columns) { column in
                Text(row.values[column.id] ?? "")
                    .font(valueFont(for: column.id, row: row))
                    .foregroundColor(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .frame(width: width(for: column), height: 30)
                    .padding(.horizontal, 6)
                    .background(Color.white.opacity(0.04))
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Color.white.opacity(0.05))
                            .frame(width: 1)
                    }
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.white.opacity(0.05))
                            .frame(height: 1)
                    }
            }
        }
    }

    private func districtChip(_ district: District) -> some View {
        let selected = vm.filters.selectedDistricts.contains(district)

        return Button {
            updateFilters { filters in
                if filters.selectedDistricts.contains(district) {
                    filters.selectedDistricts.remove(district)
                    filters.selectedRiversByDistrict[district] = nil
                } else {
                    filters.selectedDistricts.insert(district)
                    filters.selectedRiversByDistrict[district] = Set(vm.riverOptions(for: district).map(\.key))
                }
            }
        } label: {
            Text(vm.districtLabel(district))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: deepResearchTablesSelectorHeight, maxHeight: deepResearchTablesSelectorHeight)
                .background(selected ? deepResearchDistrictSelectedPill : Color.white.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    private func metricChip(_ metric: DeepResearchTableMetric) -> some View {
        let selected = vm.filters.selectedMetrics.contains(metric)

        return Button {
            updateFilters { filters in
                if filters.selectedMetrics.contains(metric) {
                    filters.selectedMetrics.remove(metric)
                } else {
                    filters.selectedMetrics.insert(metric)
                }
            }
        } label: {
            Text(metric.buttonTitle)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(selected ? .black : .white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: deepResearchTablesSelectorHeight, maxHeight: deepResearchTablesSelectorHeight)
                .padding(.horizontal, 8)
                .background(selected ? Color.white : Color.white.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    private func riverChip(_ river: TableRiverOption, district: District) -> some View {
        let selection = vm.filters.selectedRiversByDistrict[district] ?? Set(vm.riverOptions(for: district).map(\.key))
        let selected = selection.contains(river.key)

        return Button {
            updateFilters { filters in
                let current = filters.selectedRiversByDistrict[district] ?? Set(vm.riverOptions(for: district).map(\.key))
                var updated = current
                if updated.contains(river.key) {
                    if updated.count > 1 {
                        updated.remove(river.key)
                    }
                } else {
                    updated.insert(river.key)
                }
                filters.selectedRiversByDistrict[district] = updated
            }
        } label: {
            Text(river.label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: deepResearchTablesSelectorHeight, maxHeight: deepResearchTablesSelectorHeight)
                .padding(.horizontal, 8)
                .background(selected ? deepResearchDistrictSelectedPill : Color.white.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    private var visibleMetricGroups: [DeepResearchTableMetricGroup] {
        DeepResearchTableMetricGroup.allCases.filter { !visibleMetrics(for: $0).isEmpty }
    }

    private var seasonTotalsAndAveragesMetrics: Set<DeepResearchTableMetric> {
        [
            .totalDriftHours,
            .totalSetHours,
            .maxDriftBoats,
            .maxDriftPermits,
            .averageDriftBoats,
            .averageDriftPermits,
            .totalSockeyePerBoat,
            .averageSockeyePerBoatPerDay,
            .averageSockeyePerBoatPerHour,
            .totalHarvest,
            .totalEscapement,
            .totalRun,
            .totalSockeyeDrift,
            .totalSockeyeSet,
            .totalChumPct,
            .meanSockeyeWeight,
            .forecastedRun,
            .runPctDeviation,
            .escapementGoalMinimum,
            .escapementGoalMaximum,
            .projectedHarvest,
            .harvestPctDeviation,
            .peakTimingDeviationFromMedian
        ]
    }
    private var hiddenFromDailyAndCumulativeMetrics: Set<DeepResearchTableMetric> {
        [
            .actualRun,
            .actualHarvest,
            .actualEscapement,
            .totalEscapementNaknek,
            .totalEscapementKvichak,
            .totalEscapementAlagnak,
            .totalEscapementEgegik,
            .totalEscapementUgashik,
            .totalEscapementWood,
            .totalEscapementIgushik,
            .totalEscapementNushagak,
            .totalEscapementTogiak
        ]
    }
    private var singleStarMetrics: Set<DeepResearchTableMetric> {
        [
            .totalDriftHours,
            .totalSetHours,
            .averageDriftBoats,
            .averageDriftPermits,
            .averageSockeyePerBoatPerDay,
            .averageSockeyePerBoatPerHour
        ]
    }

    private var doubleStarMetrics: Set<DeepResearchTableMetric> {
        [.totalSockeyePerBoat]
    }

    private var allowedMetricsForCurrentMode: Set<DeepResearchTableMetric> {
        switch metricSetMode {
        case .dailyAndCumulative:
            return Set(DeepResearchTableMetric.allCases)
                .subtracting(seasonTotalsAndAveragesMetrics)
                .subtracting(hiddenFromDailyAndCumulativeMetrics)
        case .seasonTotalsAndAverages:
            return seasonTotalsAndAveragesMetrics
        }
    }

    private func visibleMetrics(for group: DeepResearchTableMetricGroup) -> [DeepResearchTableMetric] {
        DeepResearchTableMetric.allCases.filter { $0.group == group && allowedMetricsForCurrentMode.contains($0) }
    }

    private func selectedCount(in group: DeepResearchTableMetricGroup) -> Int {
        visibleMetrics(for: group).filter { vm.filters.selectedMetrics.contains($0) }.count
    }

    @ViewBuilder
    private func sectionFootnotes(for group: DeepResearchTableMetricGroup) -> some View {
        let visible = visibleMetrics(for: group)
        let hasSingleStar = visible.contains { singleStarMetrics.contains($0) }
        let hasDoubleStar = visible.contains { doubleStarMetrics.contains($0) }
        let showPressureDailyMetricsFootnote = group == .pressure && metricSetMode == .dailyAndCumulative
        let showDriftPermitsDailyFootnote = group == .pressure && metricSetMode == .dailyAndCumulative && vm.filters.selectedMetrics.contains(.driftPermits)

        if showPressureDailyMetricsFootnote || showDriftPermitsDailyFootnote || hasSingleStar || hasDoubleStar {
            VStack(alignment: .leading, spacing: 4) {
                if showPressureDailyMetricsFootnote {
                    Text("**The date range 6/12-8/1 was used.  Some values may include model derived data and are italicized.")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.70))
                }
                if showDriftPermitsDailyFootnote {
                    Text("*Only data from 6/12-7/16 was used in this calculation.")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.70))
                }
                if hasSingleStar {
                    Text("* Only data from 6/12-7/16 was used in this calculation.")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.70))
                }
                if hasDoubleStar {
                    Text("** Data from 6/12-8/1 was used in this calculation and includes data derived from models.")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.70))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        }
    }

    private func setMetricSetMode(_ mode: TableMetricSetMode) {
        metricSetMode = mode
        let allowed = allowedMetricsForCurrentMode
        updateFilters { filters in
            filters.selectedMetrics = Set(filters.selectedMetrics.filter { allowed.contains($0) })
        }
    }

    private func metricModeButton(title: String, isSelected: Bool, isDimmed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(isSelected ? .black : Color.white.opacity(isDimmed ? 0.45 : 0.85))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: deepResearchTablesSelectorHeight, maxHeight: deepResearchTablesSelectorHeight)
                .padding(.horizontal, 8)
                .background(isSelected ? Color.white : Color.white.opacity(isDimmed ? 0.08 : 0.14))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    private func headerFont(for columnID: String) -> Font {
        Font.system(size: 10, weight: .bold, design: .rounded)
    }

    private func valueFont(for columnID: String, row: DeepResearchTableRow) -> Font {
        let base = Font.system(size: 10, weight: .semibold, design: .rounded)
        return shouldItalicizeValue(columnID: columnID, row: row) ? base.italic() : base
    }

    private func previewFont(for columnID: String) -> Font {
        Font.system(size: 10, weight: .bold, design: .rounded)
    }
    
    private var post716ModeledColumnIDs: Set<String> {
        [
            DeepResearchTableMetric.driftBoats.rawValue,
            DeepResearchTableMetric.cumulativeBoatHours.rawValue,
            DeepResearchTableMetric.sockeyePerBoatCumulative.rawValue,
            DeepResearchTableMetric.sockeyePerBoatDaily.rawValue,
            DeepResearchTableMetric.sockeyePerBoatDailyTopDistrict.rawValue,
            DeepResearchTableMetric.topDistrictTenYearMeanDaily.rawValue,
            DeepResearchTableMetric.sockeyePerBoatHourly.rawValue
        ]
    }

    private func shouldItalicizeValue(columnID: String, row: DeepResearchTableRow) -> Bool {
        guard post716ModeledColumnIDs.contains(columnID) else { return false }
        return isPost716(dateString: row.date)
    }

    private func isPost716(dateString: String) -> Bool {
        let parts = dateString.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return false
        }

        return month > 7 || (month == 7 && day >= 17)
    }
    
    private var estimatedRowCount: Int {
        guard vm.canGenerate else { return 0 }

        let startYear = clampedYear(from: vm.filters.startDate)
        let endYear = clampedYear(from: vm.filters.endDate)
        let yearsSelected = max(0, endYear - startYear) + 1
        let districtCount = max(1, vm.filters.selectedDistricts.count)

        if metricSetMode == .seasonTotalsAndAverages {
            return yearsSelected * districtCount
        }

        let startMonthDay = monthDayOption(for: vm.filters.startDate)
        let endMonthDay = monthDayOption(for: vm.filters.endDate)

        guard let startAnchor = makeDate(year: 2001, month: startMonthDay.month, day: startMonthDay.day),
              let endAnchor = makeDate(year: 2001, month: endMonthDay.month, day: endMonthDay.day) else {
            return 0
        }

        let dayCountPerYear = max(0, calendar.dateComponents([.day], from: startAnchor, to: endAnchor).day ?? 0) + 1
        let hasTopDistrictDailyMetric = vm.filters.selectedMetrics.contains(.sockeyePerBoatDailyTopDistrict) ||
            vm.filters.selectedMetrics.contains(.topDistrictTenYearMeanDaily)
        let rowMultiplier = hasTopDistrictDailyMetric ? 1 : districtCount
        return yearsSelected * dayCountPerYear * rowMultiplier
    }

    private var estimatedRiverColumnCount: Int {
        guard vm.filters.includeRiverEscapementBreakdown && hasEscapementMetricsSelected else { return 0 }

        let perRiverCount: Int
        if metricSetMode == .seasonTotalsAndAverages {
            guard vm.filters.selectedMetrics.contains(.totalEscapement) else { return 0 }
            perRiverCount = 1
        } else {
            let dailyCount = vm.filters.includeRiverDailyEscColumns ? 1 : 0
            let cumulativeCount = vm.filters.includeRiverCumulativeEscColumns ? 1 : 0
            perRiverCount = dailyCount + cumulativeCount
            guard perRiverCount > 0 else { return 0 }
        }

        var total = 0
        for district in selectedDistrictList {
            let selectedKeys = vm.filters.selectedRiversByDistrict[district] ?? Set(vm.riverOptions(for: district).map(\.key))
            total += selectedKeys.count * perRiverCount
        }
        return total
    }

    private var estimatedColumnCount: Int {
        2 + vm.filters.selectedMetrics.count + estimatedRiverColumnCount
    }

    private var estimatedCellCount: Int {
        estimatedRowCount * estimatedColumnCount
    }
    private var isDisplayRequestTooLarge: Bool {
        estimatedRowCount > maxDisplayRows || estimatedCellCount > maxDisplayCells
    }

    private var displayLimitMessage: String {
        "Selections exceed the 5,000 data row or 20,000 cell maximum.  Please reduce metrics, districts or date range to generate a table."
    }

    private func generateTableTapped() {
        if vm.filters.outputMode == .display && isDisplayRequestTooLarge {
            exportAlertTitle = "Display Limit"
            exportAlertMessage = displayLimitMessage
            showExportAlert = true
            return
        }

        Task { @MainActor in
            await vm.generate(appDB: appDatabase)
        }
    }


    private func exportCSVTapped() {
        Task {
            do {
                guard let url = try await vm.exportCSV(appDB: appDatabase) else {
                    await MainActor.run {
                        exportAlertTitle = "CSV Export"
                        exportAlertMessage = "Unable to export CSV for the current request."
                        showExportAlert = true
                    }
                    return
                }

                let data = try Data(contentsOf: url)
                let suggestedName = url.deletingPathExtension().lastPathComponent

                await MainActor.run {
                    exportDocument = CSVExportDocument(data: data)
                    exportSuggestedFilename = suggestedName
                    isPresentingCSVExporter = true
                }
            } catch {
                DeepResearchBetaError.debugLog(error, context: "Deep Research Tables CSV export")
                await MainActor.run {
                    exportAlertTitle = "CSV Export Error"
                    exportAlertMessage = DeepResearchBetaError.userFacingMessage(for: error, feature: "Deep Research Tables")
                    showExportAlert = true
                }
            }
        }
    }
    private func dateSelectorRow(
        title: String,
        year: Int,
        monthDay: TableMonthDayOption,
        showMonthDay: Bool,
        onYearSelect: @escaping (Int) -> Void,
        onMonthDaySelect: @escaping (TableMonthDayOption) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 42, alignment: .leading)

            Menu {
                ForEach(availableYears, id: \.self) { yearOption in
                    Button(String(yearOption)) {
                        onYearSelect(yearOption)
                    }
                }
            } label: {
                dateSelectorPill(label: "Year", value: String(year))
            }

            if showMonthDay {
                Menu {
                    ForEach(allowedMonthDays) { option in
                        Button(option.label) {
                            onMonthDaySelect(option)
                        }
                    }
                } label: {
                    dateSelectorPill(label: "M/D", value: monthDay.label)
                }
            }
        }
    }

    private func dateSelectorPill(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.65))

            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            Spacer(minLength: 0)

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.65))
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: deepResearchTablesSelectorHeight, maxHeight: deepResearchTablesSelectorHeight)
        .background(Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func presetActionButton(title: String, id: String, action: @escaping () -> Void) -> some View {
        let flashing = flashingPresetIDs.contains(id)

        return Button {
            action()
            flashPreset(id)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(flashing ? .black : .white)
                .frame(maxWidth: .infinity, minHeight: deepResearchTablesSelectorHeight, maxHeight: deepResearchTablesSelectorHeight)
                .background(flashing ? Color.white : Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    private func smallActionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .frame(minHeight: 24)
                .background(Color.white.opacity(0.10))
                .clipShape(Capsule())
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    private func compactSummaryText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorCard(_ message: String) -> some View {
        TablesSectionCard(title: "Error") {
            Text(message)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.red.opacity(0.95))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var selectedDistrictList: [District] {
        District.allCases.filter { vm.filters.selectedDistricts.contains($0) }
    }

    private var hasEscapementMetricsSelected: Bool {
        vm.filters.selectedMetrics.contains(.dailyEscapement) ||
        vm.filters.selectedMetrics.contains(.cumulativeEscapement) ||
        vm.filters.selectedMetrics.contains(.totalEscapement)
    }

    private var metricGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 118), spacing: 8)]
    }

    private var summaryGridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 16, alignment: .leading),
            GridItem(.flexible(), spacing: 16, alignment: .leading)
        ]
    }

    private var displayMetricColumns: [DeepResearchTableColumn] {
        vm.columns.filter { $0.id != "date" && $0.id != "district" && $0.id != "year" }
    }
    
    private var metricSetModeDescription: String {
        switch metricSetMode {
        case .dailyAndCumulative:
            return "Daily metrics use date-level rows across the selected date range."
        case .seasonTotalsAndAverages:
            return "Seasonal metrics use one row per district-year."
        }
    }

    private var dateRangeSectionTitle: String {
        metricSetMode == .seasonTotalsAndAverages ? "Year Range" : "Date Range"
    }

    private var noMetricsSelectedMessage: some View {
        Text("Select one or more metrics to generate a table.")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(0.78))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
    private var calendar: Calendar {
        Calendar(identifier: .gregorian)
    }

    private var startYear: Int { clampedYear(from: vm.filters.startDate) }
    private var endYear: Int { clampedYear(from: vm.filters.endDate) }

    private var startMonthDay: TableMonthDayOption { monthDayOption(for: vm.filters.startDate) }
    private var endMonthDay: TableMonthDayOption { monthDayOption(for: vm.filters.endDate) }

    private var outputModeBinding: Binding<DeepResearchTablesOutputMode> {
        Binding(
            get: { vm.filters.outputMode },
            set: { newValue in updateFilters { $0.outputMode = newValue } }
        )
    }

    private var includeRiverEscapementBreakdownBinding: Binding<Bool> {
        Binding(
            get: { vm.filters.includeRiverEscapementBreakdown },
            set: { newValue in
                updateFilters { filters in
                    filters.includeRiverEscapementBreakdown = newValue
                    if newValue {
                        for district in filters.selectedDistricts {
                            if filters.selectedRiversByDistrict[district] == nil {
                                filters.selectedRiversByDistrict[district] = Set(vm.riverOptions(for: district).map(\.key))
                            }
                        }
                    }
                }
            }
        )
    }

    private var includeRiverDailyEscColumnsBinding: Binding<Bool> {
        Binding(
            get: { vm.filters.includeRiverDailyEscColumns },
            set: { newValue in updateFilters { $0.includeRiverDailyEscColumns = newValue } }
        )
    }

    private var includeRiverCumulativeEscColumnsBinding: Binding<Bool> {
        Binding(
            get: { vm.filters.includeRiverCumulativeEscColumns },
            set: { newValue in updateFilters { $0.includeRiverCumulativeEscColumns = newValue } }
        )
    }

    private var canGenerateDisplay: Bool {
        vm.filters.outputMode == .display && vm.canGenerate && !vm.isLoading && !isDisplayRequestTooLarge
    }

    private var canExportCSV: Bool {
        vm.filters.outputMode == .csv && vm.canGenerate && !vm.isLoading
    }

    private var generateButtonBackground: Color {
        canGenerateDisplay ? Color.blue.opacity(0.85) : Color.white.opacity(0.10)
    }

    private var exportButtonBackground: Color {
        canExportCSV ? Color.blue.opacity(0.85) : Color.white.opacity(0.10)
    }

    private func buttonGridColumns(count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
    }

    private func updateDate(isStart: Bool, year: Int?, monthDay: TableMonthDayOption?) {
        updateFilters { filters in
            let current = isStart ? filters.startDate : filters.endDate
            let currentYear = clampedYear(from: current)
            let currentOption = monthDayOption(for: current)

            let finalYear = year ?? currentYear
            let finalOption = monthDay ?? currentOption
            let newDate = makeDate(year: finalYear, month: finalOption.month, day: finalOption.day) ?? current

            if isStart {
                filters.startDate = newDate
            } else {
                filters.endDate = newDate
            }

            normalizeDateRange(&filters)
        }
    }

    private func monthDayOption(for date: Date) -> TableMonthDayOption {
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)

        if let exact = allowedMonthDays.first(where: { $0.month == month && $0.day == day }) {
            return exact
        }

        return allowedMonthDays.first ?? TableMonthDayOption(month: 6, day: 12)
    }

    private func normalizeDateRange(_ filters: inout DeepResearchTablesFilters) {
        filters.startDate = clampedDate(filters.startDate)
        filters.endDate = clampedDate(filters.endDate)

        if filters.endDate < filters.startDate {
            filters.endDate = filters.startDate
        }
    }

    private func clampedDate(_ date: Date) -> Date {
        let year = clampedYear(from: date)
        let option = monthDayOption(for: date)
        return makeDate(year: year, month: option.month, day: option.day) ?? date
    }

    private func clampedYear(from date: Date) -> Int {
        let year = calendar.component(.year, from: date)
        return min(max(year, availableYears.first ?? 2015), availableYears.last ?? 2025)
    }

    private func makeDate(year: Int, month: Int, day: Int) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private func clampFiltersToAllowedRange() {
        updateFilters { filters in
            normalizeDateRange(&filters)
        }
    }

    private func updateFilters(_ mutate: (inout DeepResearchTablesFilters) -> Void) {
        var updated = vm.filters
        mutate(&updated)
        vm.filters = updated
    }

    private func width(for column: DeepResearchTableColumn) -> CGFloat {
        switch column.id {
        case "date": return 78
        case "district": return 96
        case DeepResearchTableMetric.sockeyePerBoatDailyTopDistrict.rawValue:
            return 170
        case DeepResearchTableMetric.topDistrictTenYearMeanDaily.rawValue:
            return 250
        default:
            return max(118, CGFloat(column.title.count * 7))
        }
    }

    private func flashPreset(_ id: String) {
        flashingPresetIDs.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            flashingPresetIDs.remove(id)
        }
    }

    private static func buildAllowedMonthDays() -> [TableMonthDayOption] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!

        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.timeZone = cal.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        guard let start = formatter.date(from: "2001-06-12"),
              let end = formatter.date(from: "2001-08-20") else {
            return []
        }

        var out: [TableMonthDayOption] = []
        var current = start

        while current <= end {
            let parts = cal.dateComponents([.month, .day], from: current)
            if let month = parts.month, let day = parts.day {
                out.append(TableMonthDayOption(month: month, day: day))
            }
            current = cal.date(byAdding: .day, value: 1, to: current) ?? current
        }

        return out
    }
}

private struct TablesSectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .underline(true, color: Color.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .center)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}
