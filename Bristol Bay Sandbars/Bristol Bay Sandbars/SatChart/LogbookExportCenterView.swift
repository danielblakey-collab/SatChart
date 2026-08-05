import SwiftUI
import UniformTypeIdentifiers

private let logbookExportBackgroundTop = Color(red: 0.02, green: 0.15, blue: 0.30)
private let logbookExportBackgroundBottom = Color(red: 0.01, green: 0.08, blue: 0.18)
private let logbookExportCardBackground = Color.white.opacity(0.08)
private let logbookExportCardBorder = Color.white.opacity(0.10)
private let logbookExportFieldBackground = Color.white.opacity(0.10)
private let logbookExportAccent = Color(uiColor: UIColor(red: 0.03, green: 0.23, blue: 0.48, alpha: 1.0))
private let logbookExportWarn = Color(red: 0.95, green: 0.72, blue: 0.18)
private let logbookExportGood = Color(red: 0.18, green: 0.76, blue: 0.34)

@MainActor
struct LogbookExportCenterView: View {
    @ObservedObject var store: SmartLogbookStore

    @State private var options = LogbookExportOptions()
    @State private var exportDocument: LogbookExportDocument?
    @State private var isPresentingExporter = false
    @State private var exportContentType: UTType = .data
    @State private var exportSuggestedFilename = "satchart_export"
    @State private var exportAlertTitle = "Export"
    @State private var exportAlertMessage = ""
    @State private var showExportAlert = false
    @State private var isPreparingExport = false
    @State private var preparingTitle = ""

    private var snapshot: LogbookExportSnapshot {
        store.makeExportSnapshot()
    }

    private var preview: LogbookExportPreview {
        LogbookExportService.preview(snapshot: snapshot, options: options)
    }

    private var customStartDate: Binding<Date> {
        Binding(
            get: { options.customStartDate ?? Date() },
            set: { options.customStartDate = $0 }
        )
    }

    private var customEndDate: Binding<Date> {
        Binding(
            get: { options.customEndDate ?? Date() },
            set: { options.customEndDate = $0 }
        )
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [logbookExportBackgroundTop, logbookExportBackgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    scopeSection
                    dataSection
                    setsSection
                    fishTicketsSection
                    tenderPurchasesSection
                    previewSection
                    exportButtonsSection
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Export & Backup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(logbookExportAccent, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear(perform: seedCustomDatesIfNeeded)
        .fileExporter(
            isPresented: $isPresentingExporter,
            document: exportDocument ?? LogbookExportDocument(data: Data()),
            contentType: exportContentType,
            defaultFilename: exportSuggestedFilename
        ) { result in
            if case .failure(let error) = result {
                exportAlertTitle = "Export Error"
                exportAlertMessage = error.localizedDescription
                showExportAlert = true
            }
        }
        .alert(exportAlertTitle, isPresented: $showExportAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportAlertMessage)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Export & Backup")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .underline(true, color: .white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .center)

            Text("Create Garmin files, spreadsheets, photo archives, and SatChart backups from your logbook.")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scopeSection: some View {
        section("Export Scope") {
            HStack(spacing: 8) {
                ForEach(LogbookExportScope.allCases) { scope in
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            options.scope = scope
                            seedCustomDatesIfNeeded()
                        }
                    } label: {
                        Text(scope.title)
                            .frame(maxWidth: .infinity)
                    }
                    .logbookExportPillStyle(selected: options.scope == scope)
                }
            }

            if options.scope == .customDateRange {
                HStack(spacing: 10) {
                    exportDatePicker("Start", selection: customStartDate)
                    exportDatePicker("End", selection: customEndDate)
                }
            }
        }
    }

    private var dataSection: some View {
        section("Data") {
            exportToggle("Sets", isOn: $options.includeSets)
            exportToggle("Fish Tickets", isOn: $options.includeFishTickets)
            exportToggle("Tender Purchases", isOn: $options.includeTenderPurchases)
            exportToggle("Raw JSON Backup", isOn: $options.includeRawJSONBackup)
        }
    }

    @ViewBuilder
    private var setsSection: some View {
        if options.includeSets {
            section("Sets Files") {
                exportToggle("Garmin GPX", isOn: $options.includeGarminGPX)
                exportToggle("Sets CSV", isOn: $options.includeSetsCSV)
                exportToggle("Include full set tracks", isOn: $options.includeSetTracks)
                exportToggle("Include start/end waypoints", isOn: $options.includeSetStartEndWaypoints)
                exportToggle("Only sets shown on navigation map", isOn: $options.includeOnlySetsShownOnMap)
            }
        }
    }

    @ViewBuilder
    private var fishTicketsSection: some View {
        if options.includeFishTickets {
            section("Fish Ticket Files") {
                exportToggle("Fish Tickets CSV", isOn: $options.includeFishTicketsCSV)
                exportToggle("Tally Rows CSV", isOn: $options.includeFishTicketTallyRows)
                exportToggle("Include linked set numbers", isOn: $options.includeLinkedSetNumbers)
                exportToggle("Include fish-ticket and QC-sheet photos in ZIP archive", isOn: $options.includeFishTicketPhotos)
            }
        }
    }

    @ViewBuilder
    private var tenderPurchasesSection: some View {
        if options.includeTenderPurchases {
            section("Tender Purchase Files") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Format")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.70))

                    Picker("Format", selection: $options.tenderCSVShape) {
                        ForEach(TenderPurchasesCSVShape.allCases) { shape in
                            Text(shape.title).tag(shape)
                        }
                    }
                    .pickerStyle(.segmented)
                    .colorScheme(.dark)
                }

                exportToggle("Include tender receipt photos in ZIP archive", isOn: $options.includeTenderReceiptPhotos)
            }
        }
    }

    private var previewSection: some View {
        section("Preview") {
            previewRow("Scope", value: options.scope.title)
            previewRow("Seasons", value: "\(preview.seasonCount)")
            previewRow("Sets", value: "\(preview.setCount)")
            previewRow("GPX-ready sets", value: "\(preview.gpxEligibleSetCount)")
            previewRow("Fish tickets", value: "\(preview.fishTicketCount)")
            previewRow("Tally rows", value: "\(preview.fishTicketTallyRowCount)")
            previewRow("Tender purchases", value: "\(preview.tenderPurchaseCount)")
            previewRow("Ticket / QC photos", value: "\(preview.fishTicketPhotoCount)")
            previewRow("Tender receipts", value: "\(preview.tenderReceiptPhotoCount)")

            ForEach(preview.warnings, id: \.self) { warning in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(logbookExportWarn)
                    Text(warning)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.80))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var exportButtonsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                prepareSingle(.setsGPX)
            } label: {
                exportButtonLabel("Export Garmin GPX", systemImage: "location.north.line.fill")
            }
            .logbookExportPrimaryButtonStyle(disabled: !canExportGPX)
            .disabled(!canExportGPX || isPreparingExport)

            Button {
                prepareSingle(.setsCSV)
            } label: {
                exportButtonLabel("Export Sets CSV", systemImage: "tablecells.fill")
            }
            .logbookExportPrimaryButtonStyle(disabled: !canExportSetsCSV)
            .disabled(!canExportSetsCSV || isPreparingExport)

            Button {
                prepareSingle(.fishTicketsCSV)
            } label: {
                exportButtonLabel("Export Fish Tickets CSV", systemImage: "shippingbox.fill")
            }
            .logbookExportPrimaryButtonStyle(disabled: !canExportFishTicketsCSV)
            .disabled(!canExportFishTicketsCSV || isPreparingExport)

            Button {
                prepareSingle(.fishTicketTallyCSV)
            } label: {
                exportButtonLabel("Export Tally Rows CSV", systemImage: "list.bullet.rectangle.fill")
            }
            .logbookExportPrimaryButtonStyle(disabled: !canExportTallyCSV)
            .disabled(!canExportTallyCSV || isPreparingExport)

            Button {
                prepareSingle(.tenderPurchasesCSV)
            } label: {
                exportButtonLabel("Export Tender Purchases CSV", systemImage: "cart.fill")
            }
            .logbookExportPrimaryButtonStyle(disabled: !canExportTenderCSV)
            .disabled(!canExportTenderCSV || isPreparingExport)

            Button {
                prepareArchive()
            } label: {
                exportButtonLabel("Export Full Archive ZIP", systemImage: "externaldrive.fill")
            }
            .logbookExportPrimaryButtonStyle(disabled: !canExportArchive, fillColor: logbookExportGood)
            .disabled(!canExportArchive || isPreparingExport)

            if isPreparingExport {
                Text(preparingTitle.isEmpty ? "Preparing..." : "Preparing \(preparingTitle)...")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.76))
            } else if let disabledReason {
                Text(disabledReason)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .logbookExportCardStyle()
    }

    private var canExportGPX: Bool {
        options.includeSets && options.includeGarminGPX && preview.gpxEligibleSetCount > 0
    }

    private var canExportSetsCSV: Bool {
        options.includeSets && options.includeSetsCSV && preview.setCount > 0
    }

    private var canExportFishTicketsCSV: Bool {
        options.includeFishTickets && options.includeFishTicketsCSV && preview.fishTicketCount > 0
    }

    private var canExportTallyCSV: Bool {
        options.includeFishTickets && options.includeFishTicketTallyRows && preview.fishTicketTallyRowCount > 0
    }

    private var canExportTenderCSV: Bool {
        options.includeTenderPurchases && options.includeTenderPurchasesCSV && preview.tenderPurchaseCount > 0
    }

    private var canExportArchive: Bool {
        preview.hasAnyExportableData || options.includeRawJSONBackup
    }

    private var disabledReason: String? {
        if options.scope == .activeSeason && preview.seasonCount == 0 {
            return "No active season is available."
        }
        if !preview.hasAnyExportableData && !options.includeRawJSONBackup {
            return "No exportable logbook data is available for the selected scope."
        }
        return nil
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            content()
        }
        .logbookExportCardStyle()
    }

    private func exportToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        }
        .toggleStyle(.switch)
        .tint(logbookExportGood)
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
        .background(logbookExportFieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func exportDatePicker(_ title: String, selection: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.70))

            DatePicker("", selection: selection, displayedComponents: .date)
                .datePickerStyle(.compact)
                .labelsHidden()
                .colorScheme(.dark)
                .tint(.white)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .background(logbookExportFieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func previewRow(_ title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.72))
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 30)
        .background(logbookExportFieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func exportButtonLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(isPreparingExport && preparingTitle == title ? "Preparing..." : title)
        }
    }

    private func seedCustomDatesIfNeeded() {
        if options.customStartDate == nil {
            options.customStartDate = store.activeSeason?.splashDate ?? Date()
        }
        if options.customEndDate == nil {
            let latestOpening = store.activeSeason?.openings.map(\.openingDate).max()
            options.customEndDate = latestOpening ?? Date()
        }
    }

    private func prepareSingle(_ kind: LogbookSingleExportKind) {
        Task {
            isPreparingExport = true
            preparingTitle = title(for: kind)
            defer {
                isPreparingExport = false
                preparingTitle = ""
            }

            do {
                let prepared = try LogbookExportService.prepareSingleExport(
                    snapshot: store.makeExportSnapshot(),
                    request: LogbookSingleExportRequest(kind: kind, options: options)
                )
                present(prepared)
            } catch {
                show(error)
            }
        }
    }

    private func prepareArchive() {
        Task {
            isPreparingExport = true
            preparingTitle = "Export Full Archive ZIP"
            defer {
                isPreparingExport = false
                preparingTitle = ""
            }

            do {
                let prepared = try LogbookExportService.prepareArchive(snapshot: store.makeExportSnapshot(), options: options)
                present(prepared)
            } catch {
                show(error)
            }
        }
    }

    private func present(_ prepared: LogbookPreparedExport) {
        exportDocument = LogbookExportDocument(data: prepared.data)
        exportContentType = prepared.contentType
        exportSuggestedFilename = prepared.defaultFilename
        isPresentingExporter = true
    }

    private func show(_ error: Error) {
        exportAlertTitle = "Export Error"
        exportAlertMessage = error.localizedDescription
        showExportAlert = true
    }

    private func title(for kind: LogbookSingleExportKind) -> String {
        switch kind {
        case .setsGPX: return "Export Garmin GPX"
        case .setsCSV: return "Export Sets CSV"
        case .fishTicketsCSV: return "Export Fish Tickets CSV"
        case .fishTicketTallyCSV: return "Export Tally Rows CSV"
        case .tenderPurchasesCSV: return "Export Tender Purchases CSV"
        case .rawJSONBackup: return "Export Raw JSON Backup"
        }
    }
}

enum LogbookContextualExportContext {
    case sets
    case fishTickets
    case tenderPurchases
}

@MainActor
struct LogbookContextualExportButtons: View {
    @ObservedObject var store: SmartLogbookStore
    let context: LogbookContextualExportContext

    @State private var exportDocument: LogbookExportDocument?
    @State private var isPresentingExporter = false
    @State private var exportContentType: UTType = .data
    @State private var exportSuggestedFilename = "satchart_export"
    @State private var exportAlertTitle = "Export"
    @State private var exportAlertMessage = ""
    @State private var showExportAlert = false
    @State private var isPreparingExport = false

    private var preview: LogbookExportPreview {
        LogbookExportService.preview(snapshot: store.makeExportSnapshot(), options: baseOptions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(buttons, id: \.title) { button in
                    Button {
                        prepare(button)
                    } label: {
                        Label(button.title, systemImage: button.systemImage)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }
                    .logbookExportSmallButtonStyle(disabled: !button.isEnabled(preview))
                    .disabled(!button.isEnabled(preview) || isPreparingExport)
                }
            }

            if isPreparingExport {
                Text("Preparing...")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.70))
            }
        }
        .fileExporter(
            isPresented: $isPresentingExporter,
            document: exportDocument ?? LogbookExportDocument(data: Data()),
            contentType: exportContentType,
            defaultFilename: exportSuggestedFilename
        ) { result in
            if case .failure(let error) = result {
                exportAlertTitle = "Export Error"
                exportAlertMessage = error.localizedDescription
                showExportAlert = true
            }
        }
        .alert(exportAlertTitle, isPresented: $showExportAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportAlertMessage)
        }
    }

    private var baseOptions: LogbookExportOptions {
        var options = LogbookExportOptions()
        options.scope = .activeSeason
        switch context {
        case .sets:
            options.includeSets = true
            options.includeFishTickets = false
            options.includeTenderPurchases = false
        case .fishTickets:
            options.includeSets = false
            options.includeFishTickets = true
            options.includeTenderPurchases = false
        case .tenderPurchases:
            options.includeSets = false
            options.includeFishTickets = false
            options.includeTenderPurchases = true
        }
        return options
    }

    private var buttons: [ContextualExportButton] {
        switch context {
        case .sets:
            return [
                ContextualExportButton(title: "Export Garmin GPX", systemImage: "location.north.line.fill", kind: .single(.setsGPX)) { $0.gpxEligibleSetCount > 0 },
                ContextualExportButton(title: "Export Sets CSV", systemImage: "tablecells.fill", kind: .single(.setsCSV)) { $0.setCount > 0 }
            ]
        case .fishTickets:
            return [
                ContextualExportButton(title: "Export Fish Tickets CSV", systemImage: "shippingbox.fill", kind: .single(.fishTicketsCSV)) { $0.fishTicketCount > 0 },
                ContextualExportButton(title: "Export Fish Ticket Archive", systemImage: "archivebox.fill", kind: .archive(.fishTickets)) { $0.fishTicketCount > 0 || $0.fishTicketPhotoCount > 0 }
            ]
        case .tenderPurchases:
            return [
                ContextualExportButton(title: "Export Purchases CSV", systemImage: "cart.fill", kind: .single(.tenderPurchasesCSV)) { $0.tenderPurchaseCount > 0 },
                ContextualExportButton(title: "Export Purchases Archive", systemImage: "archivebox.fill", kind: .archive(.tenderPurchases)) { $0.tenderPurchaseCount > 0 || $0.tenderReceiptPhotoCount > 0 }
            ]
        }
    }

    private func prepare(_ button: ContextualExportButton) {
        Task {
            isPreparingExport = true
            defer { isPreparingExport = false }
            do {
                let snapshot = store.makeExportSnapshot()
                let prepared: LogbookPreparedExport
                switch button.kind {
                case .single(let kind):
                    var options = baseOptions
                    if context == .tenderPurchases {
                        options.tenderCSVShape = .wide
                    }
                    prepared = try LogbookExportService.prepareSingleExport(
                        snapshot: snapshot,
                        request: LogbookSingleExportRequest(kind: kind, options: options)
                    )
                case .archive(let archiveContext):
                    prepared = try LogbookExportService.prepareArchive(
                        snapshot: snapshot,
                        options: archiveOptions(for: archiveContext)
                    )
                }
                present(prepared)
            } catch {
                show(error)
            }
        }
    }

    private func archiveOptions(for archiveContext: ContextualArchiveContext) -> LogbookExportOptions {
        var options = LogbookExportOptions()
        options.scope = .activeSeason
        options.includeSets = false
        options.includeFishTickets = archiveContext == .fishTickets
        options.includeTenderPurchases = archiveContext == .tenderPurchases
        options.includeRawJSONBackup = false
        options.includeFishTicketPhotos = archiveContext == .fishTickets
        options.includeTenderReceiptPhotos = archiveContext == .tenderPurchases
        options.tenderCSVShape = .both
        return options
    }

    private func present(_ prepared: LogbookPreparedExport) {
        exportDocument = LogbookExportDocument(data: prepared.data)
        exportContentType = prepared.contentType
        exportSuggestedFilename = prepared.defaultFilename
        isPresentingExporter = true
    }

    private func show(_ error: Error) {
        exportAlertTitle = "Export Error"
        exportAlertMessage = error.localizedDescription
        showExportAlert = true
    }
}

private enum ContextualArchiveContext {
    case fishTickets
    case tenderPurchases
}

private enum ContextualExportKind {
    case single(LogbookSingleExportKind)
    case archive(ContextualArchiveContext)
}

private struct ContextualExportButton {
    let title: String
    let systemImage: String
    let kind: ContextualExportKind
    let isEnabled: (LogbookExportPreview) -> Bool
}

private extension View {
    func logbookExportCardStyle() -> some View {
        self
            .padding(14)
            .background(logbookExportCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(logbookExportCardBorder, lineWidth: 1)
            )
    }

    func logbookExportPillStyle(selected: Bool) -> some View {
        self
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(selected ? logbookExportAccent : Color.white.opacity(0.10))
            .clipShape(Capsule())
            .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    func logbookExportPrimaryButtonStyle(disabled: Bool = false, fillColor: Color = logbookExportAccent) -> some View {
        self
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 42)
            .background(disabled ? Color.white.opacity(0.10) : fillColor)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    func logbookExportSmallButtonStyle(disabled: Bool = false) -> some View {
        self
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 30)
            .background(disabled ? Color.white.opacity(0.08) : logbookExportAccent)
            .clipShape(Capsule())
            .buttonStyle(SatChartPressFeedbackButtonStyle())
    }
}
