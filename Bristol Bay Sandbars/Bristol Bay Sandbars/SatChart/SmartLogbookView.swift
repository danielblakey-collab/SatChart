import SwiftUI
import Foundation
import CoreLocation
import UIKit
import CoreImage
import ImageIO
@preconcurrency import Vision
import Combine
import GRDB
import Charts
import OSLog
import Darwin

private let smartLogbookBackgroundTop = Color(red: 0.02, green: 0.15, blue: 0.30)
private let smartLogbookBackgroundBottom = Color(red: 0.01, green: 0.08, blue: 0.18)
private let smartLogbookCardBackground = Color.white.opacity(0.08)
private let smartLogbookCardBorder = Color.white.opacity(0.10)
private let smartLogbookFieldBackground = Color.white.opacity(0.12)
private let smartLogbookFieldBackgroundSoft = Color.white.opacity(0.08)
private let smartLogbookAccent = Color(uiColor: UIColor(red: 0.03, green: 0.23, blue: 0.48, alpha: 1.0))
private let smartLogbookAccentSecondary = Color(red: 0.06, green: 0.24, blue: 0.55)
private let smartLogbookNavBarUIColor = UIColor(red: 0.02, green: 0.15, blue: 0.30, alpha: 1.0)
private let smartLogbookToggleBlue = Color(red: 0.39, green: 0.73, blue: 0.98)
private let smartLogbookGood = Color(red: 0.18, green: 0.76, blue: 0.34)
private let smartLogbookWarn = Color(red: 0.95, green: 0.72, blue: 0.18)
private let smartLogbookCaptureYellow = Color(uiColor: UIColor(red: 0.95, green: 0.78, blue: 0.18, alpha: 1.0))
private let smartLogbookCaptureYellowDisabled = Color(uiColor: UIColor(red: 0.95, green: 0.78, blue: 0.18, alpha: 0.38))
private let smartLogbookBad = Color(red: 0.88, green: 0.30, blue: 0.28)
private let smartLogbookCardCornerRadius: CGFloat = 14
private let smartLogbookSelectorHeight: CGFloat = 33
private let smartLogbookPrimaryButtonHeight: CGFloat = 42

private struct SmartLogbookHostingBackgroundFixer: UIViewRepresentable {
    let color: UIColor

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = color
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.backgroundColor = color
        uiView.superview?.backgroundColor = color
        uiView.superview?.superview?.backgroundColor = color
    }
}

private enum SmartLogbookNavAppearance {
    static func applyNavBar() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = smartLogbookNavBarUIColor
        nav.shadowColor = UIColor.black.withAlphaComponent(0.35)
        nav.titleTextAttributes = [.foregroundColor: UIColor.white]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white]

        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = .white
    }
}

@MainActor
struct SmartLogbookView: View {
    @StateObject private var store: SmartLogbookStore

    @State private var tenderDraftDate = Calendar.current.startOfDay(for: Date())
    @State private var tenderTenderName: String = ""
    @State private var tenderFuelGallonsText: String = ""
    @State private var tenderGroceriesDescription: String = ""
    @State private var tenderGroceriesAmountText: String = ""
    @State private var tenderMiscDescription: String = ""
    @State private var tenderMiscAmountText: String = ""

    @State private var isTenderServicesExpanded: Bool = false
    @State private var tenderEntryToastMessage: String? = nil
    @State private var tenderEntryToastUntil: Date? = nil

    @State private var emptySeasonSummaryExpanded: Bool = true
    @State private var seasonSummaryExpansionOverrides: [UUID: Bool] = [:]
    @State private var isPurchasesToDateExpanded: Bool = true

    @State private var showTenderReceiptCamera = false

    init(store: SmartLogbookStore? = nil) {
        let resolvedStore = store ?? SmartLogbookStore()
        _store = StateObject(wrappedValue: resolvedStore)
    }

    private var activeSeason: SmartLogbookSeason? { store.activeSeason }
    private var deliveryOpenings: [SmartLogbookOpening] {
        activeSeason?.deliveryOpenings ?? []
    }
    private var setDeliveryOptions: [SmartFishingSetDeliveryOption] {
        deliveryOpenings.enumerated().map { index, opening in
            SmartFishingSetDeliveryOption(
                openingID: opening.id,
                title: "Delivery Record \(index + 1)",
                subtitle: SmartLogbookFormat.dayMonth.string(from: opening.openingDate)
            )
        }
    }
    private var recordedSetCount: Int {
        activeSeason?.openings.reduce(0) { $0 + $1.fishingSets.count } ?? 0
    }
    private var tenderPurchaseCount: Int {
        activeSeason?.tenderEntries.count ?? 0
    }

    private var parsedTenderFuelGallons: Double? { SmartLogbookParse.decimal(from: tenderFuelGallonsText) }
    private var parsedTenderGroceriesAmount: Double? { SmartLogbookParse.decimal(from: tenderGroceriesAmountText) }
    private var parsedTenderMiscAmount: Double? { SmartLogbookParse.decimal(from: tenderMiscAmountText) }

    private var tenderGroceriesBinding: Binding<String> {
        Binding(
            get: { tenderGroceriesAmountText },
            set: { tenderGroceriesAmountText = SmartLogbookParse.currencyInput(from: $0) }
        )
    }

    private var tenderMiscAmountBinding: Binding<String> {
        Binding(
            get: { tenderMiscAmountText },
            set: { tenderMiscAmountText = SmartLogbookParse.currencyInput(from: $0) }
        )
    }

    private var tenderSubmitDisabled: Bool {
        let hasFuel = parsedTenderFuelGallons != nil
        let hasGroceries = !tenderGroceriesDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parsedTenderGroceriesAmount != nil
        let hasMisc = !tenderMiscDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parsedTenderMiscAmount != nil

        return !(hasFuel || hasGroceries || hasMisc)
    }

    private var tenderDraftCashTotal: Double {
        (parsedTenderGroceriesAmount ?? 0) + (parsedTenderMiscAmount ?? 0)
    }

    private var activeSeasonReceiptImages: [UIImage] {
        guard let activeSeason else { return [] }
        return activeSeason.tenderReceiptImageFilenames.compactMap { SmartTenderReceiptStorage.loadImage(named: $0) }
    }


    var body: some View {
        ZStack {
            smartLogbookBackgroundTop.ignoresSafeArea()
            SmartLogbookHostingBackgroundFixer(color: smartLogbookNavBarUIColor)
                .frame(width: 0, height: 0)

            LinearGradient(
                colors: [smartLogbookBackgroundTop, smartLogbookBackgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    headerView
                    if store.seasons.isEmpty {
                        seasonSummaryCard(nil)
                    } else {
                        ForEach(store.seasons) { season in
                            seasonSummaryCard(season)
                        }
                    }
                    logbookSubpagesCard
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }

            if let message = tenderEntryToastMessage,
               let until = tenderEntryToastUntil,
               Date() < until {
                VStack {
                    Spacer()
                    Text(message)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.88))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .padding(.bottom, 24)
                }
            }
        }
        .onAppear {
            if let activeSeason {
                tenderDraftDate = activeSeason.latestOpeningDate ?? activeSeason.splashDate
            }
        }
        .onChange(of: activeSeason?.id) { _ in
            if let activeSeason {
                tenderDraftDate = activeSeason.latestOpeningDate ?? activeSeason.splashDate
            }
        }
        .fullScreenCover(isPresented: $showTenderReceiptCamera) {
            SmartSinglePhotoCaptureView(
                sourceType: UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
            ) { image in
                handleTenderReceiptCapture(image)
            }
            .ignoresSafeArea()
        }
    }

    private var headerView: some View {
        VStack(alignment: .center, spacing: 6) {
            Text("Logbook")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .underline(true, color: .white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var logbookSubpagesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink {
                setsSubpage()
                    .menuChildPageChrome()
            } label: {
                LogbookLandingCard(
                    title: "Sets",
                    subtitle: "Review every recorded set and choose which ones appear on the navigation map.",
                    systemImage: "timer.circle.fill",
                    badgeText: recordedSetCount == 0 ? nil : "\(recordedSetCount)"
                )
            }
            .buttonStyle(SatChartPressFeedbackButtonStyle())

            NavigationLink {
                deliveriesSubpage()
                    .menuChildPageChrome()
            } label: {
                LogbookLandingCard(
                    title: "Deliveries",
                    subtitle: "OCR-first delivery cards for fish tickets and tally sheets.",
                    systemImage: "shippingbox.fill",
                    badgeText: deliveryOpenings.isEmpty ? nil : "\(deliveryOpenings.count)"
                )
            }
            .buttonStyle(SatChartPressFeedbackButtonStyle())

            NavigationLink {
                tenderPurchasesSubpage()
                    .menuChildPageChrome()
            } label: {
                LogbookLandingCard(
                    title: "Tender Purchases",
                    subtitle: "Log fuel, groceries, and tender-side purchases in one place.",
                    systemImage: "cart.fill",
                    badgeText: tenderPurchaseCount == 0 ? nil : "\(tenderPurchaseCount)"
                )
            }
            .buttonStyle(SatChartPressFeedbackButtonStyle())

            NavigationLink {
                LogbookExportCenterView(store: store)
                    .menuChildPageChrome()
            } label: {
                LogbookLandingCard(
                    title: "Export & Backup",
                    subtitle: "Export Garmin GPX, spreadsheets, photos, receipts, and full logbook backups.",
                    systemImage: "square.and.arrow.up.fill",
                    badgeText: nil
                )
            }
            .buttonStyle(SatChartPressFeedbackButtonStyle())
        }
    }

    private func logbookSubpageScaffold<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            smartLogbookBackgroundTop.ignoresSafeArea()
            SmartLogbookHostingBackgroundFixer(color: smartLogbookNavBarUIColor)
                .frame(width: 0, height: 0)

            LinearGradient(
                colors: [smartLogbookBackgroundTop, smartLogbookBackgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .underline(true, color: .white.opacity(0.55))
                            .frame(maxWidth: .infinity, alignment: .center)

                        Text(subtitle)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    content()
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(smartLogbookAccent, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var allSetEntries: [SmartFishingSetListEntry] {
        guard let activeSeason else { return [] }

        return activeSeason.openings
            .flatMap { opening in
                opening.fishingSets.map { set in
                    SmartFishingSetListEntry(
                        recordID: set.id,
                        startedAt: set.startedAt,
                        setNumber: set.setNumber
                    )
                }
            }
            .sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.setNumber < $1.setNumber
            }
    }

    private func emptyLogbookStateCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(0.76))
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .smartLogbookInsetStyle()
    }

    private func setsSubpage() -> some View {
        logbookSubpageScaffold(
            title: "Sets",
            subtitle: "Every recorded set lives here. Use Show Set to control map visibility."
        ) {
            setsSectionCard
        }
    }

    private func deliveriesSubpage() -> some View {
        logbookSubpageScaffold(
            title: "Deliveries",
            subtitle: "Add OCR delivery drafts here, then open each one for fish-ticket and tally-sheet capture."
        ) {
            simplifiedDeliveriesSectionCard
        }
    }

    private func tenderPurchasesSubpage() -> some View {
        logbookSubpageScaffold(
            title: "Tender Purchases",
            subtitle: "Add tender purchases, capture receipts, and review purchases to date."
        ) {
            tenderServicesCard
            if let activeSeason {
                purchasesToDateCard(activeSeason)
            } else {
                emptyLogbookStateCard("No season exists yet. The first dated delivery, purchase, or recorded set will create its calendar-year season automatically.")
            }
        }
    }

    private var setsSectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recorded Sets")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .underline(true, color: .white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .center)

            LogbookContextualExportButtons(store: store, context: .sets)

            if allSetEntries.isEmpty {
                Text("No sets recorded yet. Use Record Set on the navigation page to capture soak time, drift, tides, coordinates, catch, and notes.")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.76))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .smartLogbookInsetStyle()
            } else {
                ForEach(allSetEntries) { entry in
                    if let setBinding = store.bindingForFishingSet(setID: entry.recordID) {
                        SmartFishingSetListRow(
                            set: setBinding,
                            deliveryOptions: setDeliveryOptions,
                            onDelete: {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    store.deleteFishingSet(setID: entry.recordID)
                                }
                            }
                        )
                    }
                }
            }
        }
        .smartLogbookCardStyle()
    }

    private var simplifiedDeliveriesSectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Deliveries")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .underline(true, color: .white.opacity(0.55))

                Spacer(minLength: 0)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        _ = store.addOCRDeliveryDraft()
                        if let latestOpeningDate = store.activeSeason?.deliveryOpenings.last?.openingDate {
                            tenderDraftDate = latestOpeningDate
                        }
                    }
                } label: {
                    Label("Add Delivery", systemImage: "plus")
                }
                .smartLogbookSmallPillButtonStyle(fillColor: smartLogbookAccent)
            }

            LogbookContextualExportButtons(store: store, context: .fishTickets)

            if deliveryOpenings.isEmpty {
                emptyLogbookStateCard("No delivery cards yet. Add Delivery to create a new OCR draft.")
            }

            if let activeSeason {
                ForEach(deliveryOpenings) { opening in
                    if let openingBinding = store.bindingForOpening(openingID: opening.id) {
                        let index = deliveryOpenings.firstIndex(where: { $0.id == opening.id }) ?? 0
                        SmartDeliverySummaryRow(
                            opening: openingBinding,
                            entryIndex: index,
                            seasonBaseDistrict: activeSeason.district,
                            priorCatchLbs: store.catchToDate(beforeOpeningID: opening.id),
                            editDestination: AnyView(
                                deliveryDetailPage(
                                    opening: opening,
                                    openingBinding: openingBinding,
                                    index: index,
                                    activeSeason: activeSeason
                                )
                            ),
                            onDelete: {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    store.deleteOpening(opening.id)
                                }
                            }
                        )
                    }
                }
            }
        }
        .smartLogbookCardStyle()
    }

    private func deliveryDetailPage(
        opening: SmartLogbookOpening,
        openingBinding: Binding<SmartLogbookOpening>,
        index: Int,
        activeSeason: SmartLogbookSeason
    ) -> some View {
        logbookSubpageScaffold(
            title: "Delivery Record \(index + 1)",
            subtitle: "Fish-ticket OCR first, tally-sheet OCR second, and applied delivery fields below."
        ) {
            SmartLogbookOpeningCard(
                opening: openingBinding,
                store: store,
                entryIndex: index,
                seasonBaseDistrict: activeSeason.district,
                priorCatchLbs: store.catchToDate(beforeOpeningID: opening.id),
                canDelete: true,
                onDelete: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        store.deleteOpening(opening.id)
                    }
                },
                onCopyPreviousNotes: { store.copyNotesForward(into: opening.id) },
                hasPreviousOpening: index > 0
            )
        }
        .menuChildPageChrome()
    }

    private var tenderServicesCard: some View {
        let receiptCount = activeSeason?.tenderReceiptImageFilenames.count ?? 0

        return VStack(alignment: .leading, spacing: 12) {
            sectionActionField(
                title: "Tender Purchases",
                actionTitle: isTenderServicesExpanded ? "Collapse" : "Add",
                actionFillColor: isTenderServicesExpanded ? Color.white.opacity(0.10) : smartLogbookAccent
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isTenderServicesExpanded.toggle()
                }
            }

            if isTenderServicesExpanded {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        SmartLogbookDateField(
                            title: "Date",
                            selection: $tenderDraftDate,
                            showsContainer: false
                        )

                        SmartInlineTextFieldCompact(
                            title: "Tender",
                            text: $tenderTenderName,
                            placeholder: "Tender",
                            capitalization: .words
                        )
                    }
                    .frame(maxWidth: 170, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        SmartValueOnlyInputCard(
                            title: "Fuel",
                            valueText: $tenderFuelGallonsText,
                            valuePlaceholder: "Gallons",
                            keyboardType: .decimalPad
                        )

                        SmartAmountPairInputCard(
                            title: "Groceries",
                            descriptionText: $tenderGroceriesDescription,
                            descriptionPlaceholder: "Description",
                            amountText: tenderGroceriesBinding,
                            amountPlaceholder: "$0.00"
                        )

                        SmartAmountPairInputCard(
                            title: "Misc.",
                            descriptionText: $tenderMiscDescription,
                            descriptionPlaceholder: "Description",
                            amountText: tenderMiscAmountBinding,
                            amountPlaceholder: "$0.00",
                            footerText: "Draft total: \(SmartLogbookFormat.currency(tenderDraftCashTotal))"
                        )
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        submitTenderEntry()
                    } label: {
                        Text("Enter to Log")
                    }
                    .smartLogbookSmallPillButtonStyle(fillColor: tenderSubmitDisabled ? Color.white.opacity(0.14) : smartLogbookAccent)
                    .disabled(tenderSubmitDisabled)

                    Button {
                        cancelTenderEntry()
                    } label: {
                        Text("Cancel")
                    }
                    .smartLogbookSmallPillButtonStyle(fillColor: smartLogbookWarn, textColor: .black)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        Text("Tender Receipts")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        Spacer(minLength: 0)

                        Button {
                            showTenderReceiptCamera = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "camera.fill")
                                Text(receiptCount == 0 ? "Capture" : "Add")
                            }
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 28)
                            .background(smartLogbookAccent)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(SatChartPressFeedbackButtonStyle())
                    }

                    if !activeSeasonReceiptImages.isEmpty {
                        SmartImageThumbnailStrip(images: activeSeasonReceiptImages, height: 72)
                        Text("\(receiptCount) receipt(s) attached")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.72))
                    } else {
                        Text("Receipt thumbnails will show here after capture.")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.70))
                    }
                }
                .padding(10)
                .smartLogbookInsetStyle()
            }
        }
        .smartLogbookCardStyle()
    }

    private func seasonSummaryCard(_ season: SmartLogbookSeason?) -> some View {
        let year = season?.calendarYear
            ?? Calendar.current.component(.year, from: Date())
        let isExpanded = season.map(isSeasonSummaryExpanded) ?? emptySeasonSummaryExpanded
        let currentDistrictText = season?.currentDistrict.rawValue ?? "—"
        let deliveriesCount = season?.openings.filter(\.isDeliveryEntry).count ?? 0
        let catchToDate = season.map { store.totalCatch(for: $0) } ?? 0
        let fuelPurchased = season.map { store.totalFuelGallons(for: $0) } ?? 0
        let groceriesPurchased = season.map { store.totalGroceriesAmount(for: $0) } ?? 0

        return VStack(alignment: .leading, spacing: 12) {
            sectionActionField(
                title: "\(year) Season Summary",
                actionTitle: isExpanded ? "Collapse" : "Expand",
                actionFillColor: isExpanded ? Color.white.opacity(0.10) : smartLogbookAccent
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if let season {
                        store.setActiveSeason(season.id)
                        seasonSummaryExpansionOverrides[season.id] = !isExpanded
                    } else {
                        emptySeasonSummaryExpanded.toggle()
                    }
                }
            }

            if isExpanded {
                summaryLine(title: "Current District", value: currentDistrictText)
                summaryLine(title: "Deliveries", value: "\(deliveriesCount)")
                summaryLine(title: "Catch to Date", value: SmartLogbookFormat.number(catchToDate))
                summaryLine(title: "Total Fuel Purchased", value: "\(SmartLogbookFormat.decimal(fuelPurchased, maxFractionDigits: 1)) gal")
                summaryLine(title: "Total Groceries Purchased", value: SmartLogbookFormat.currency(groceriesPurchased))

                if season == nil {
                    Text("The first dated delivery, purchase, or recorded set will create its calendar-year season automatically.")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.80))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
        .smartLogbookCardStyle()
    }

    private func isSeasonSummaryExpanded(_ season: SmartLogbookSeason) -> Bool {
        seasonSummaryExpansionOverrides[season.id] ?? (season.id == store.activeSeasonID)
    }

    private func sectionActionField(
        title: String,
        actionTitle: String,
        actionFillColor: Color = Color.white.opacity(0.10),
        action: @escaping () -> Void
    ) -> some View {
        ZStack {
            HStack(spacing: 0) {
                Button(action: action) {
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SatChartPressFeedbackButtonStyle())
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(actionTitle, action: action)
                    .buttonStyle(SatChartPressFeedbackButtonStyle())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 24)
                    .background(actionFillColor)
                    .clipShape(Capsule())
                    .padding(.trailing, 10)
            }

            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 84)
                .frame(maxWidth: .infinity, alignment: .center)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, minHeight: 36)
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func purchasesToDateCard(_ season: SmartLogbookSeason) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .trailing) {
                Text("Purchases to Date")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .underline(true, color: .white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .center)

                Button(isPurchasesToDateExpanded ? "Collapse" : "Expand") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isPurchasesToDateExpanded.toggle()
                    }
                }
                .smartLogbookSmallSecondaryButtonStyle()
            }

            LogbookContextualExportButtons(store: store, context: .tenderPurchases)

            if isPurchasesToDateExpanded {
                if season.tenderEntries.isEmpty {
                    Text("No tender purchases logged yet.")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.76))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .smartLogbookInsetStyle()
                } else {
                    SmartPurchasesLedgerCard(
                        title: "Fuel",
                        rows: season.tenderEntries.compactMap { entry in
                            guard let gallons = entry.fuelGallons else { return nil }
                            return SmartTenderLedgerRowModel(
                                dateText: SmartLogbookFormat.dayMonth.string(from: entry.date),
                                primaryText: entry.tenderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Fuel purchase" : entry.tenderName,
                                secondaryText: "\(SmartLogbookFormat.decimal(gallons, maxFractionDigits: 1)) gal"
                            )
                        },
                        totalText: "Total: \(SmartLogbookFormat.decimal(store.totalFuelGallons(for: season), maxFractionDigits: 1)) gallons"
                    )

                    SmartPurchasesLedgerCard(
                        title: "Groceries",
                        rows: season.tenderEntries.compactMap { entry in
                            guard let amount = entry.groceriesAmount else { return nil }
                            let description = entry.groceriesDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                            return SmartTenderLedgerRowModel(
                                dateText: SmartLogbookFormat.dayMonth.string(from: entry.date),
                                primaryText: description.isEmpty ? "Groceries" : description,
                                secondaryText: SmartLogbookFormat.currency(amount)
                            )
                        },
                        totalText: "Total: \(SmartLogbookFormat.currency(store.totalGroceriesAmount(for: season)))"
                    )

                    SmartPurchasesLedgerCard(
                        title: "Misc.",
                        rows: season.tenderEntries.compactMap { entry in
                            guard let amount = entry.miscAmount else { return nil }
                            let description = entry.miscDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                            return SmartTenderLedgerRowModel(
                                dateText: SmartLogbookFormat.dayMonth.string(from: entry.date),
                                primaryText: description.isEmpty ? "Miscellaneous" : description,
                                secondaryText: SmartLogbookFormat.currency(amount)
                            )
                        },
                        totalText: "Total: \(SmartLogbookFormat.currency(store.totalMiscAmount(for: season)))"
                    )
                }
            }
        }
        .smartLogbookCardStyle()
    }

    private func summaryLine(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(title):")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.86))
            Spacer(minLength: 0)
        }
    }

    private func warningCard(
        text: String,
        continueAction: @escaping () -> Void,
        cancelAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Continue", action: continueAction)
                .buttonStyle(SatChartPressFeedbackButtonStyle())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(smartLogbookWarn.opacity(0.28))
                .clipShape(Capsule())

            Button("Cancel", action: cancelAction)
                .buttonStyle(SatChartPressFeedbackButtonStyle())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.10))
                .clipShape(Capsule())
        }
        .padding(10)
        .smartLogbookInsetStyle()
    }

    private func cancelTenderEntry() {
        tenderTenderName = ""
        tenderFuelGallonsText = ""
        tenderGroceriesDescription = ""
        tenderGroceriesAmountText = ""
        tenderMiscDescription = ""
        tenderMiscAmountText = ""
        withAnimation(.easeInOut(duration: 0.18)) {
            isTenderServicesExpanded = false
        }
    }

    private func submitTenderEntry() {
        let normalizedTenderName = tenderTenderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedGroceriesDescription = tenderGroceriesDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMiscDescription = tenderMiscDescription.trimmingCharacters(in: .whitespacesAndNewlines)

        store.addTenderEntry(
            date: tenderDraftDate,
            tenderName: normalizedTenderName,
            fuelGallons: parsedTenderFuelGallons,
            groceriesDescription: normalizedGroceriesDescription,
            groceriesAmount: parsedTenderGroceriesAmount,
            miscDescription: normalizedMiscDescription,
            miscAmount: parsedTenderMiscAmount
        )

        tenderTenderName = ""
        tenderFuelGallonsText = ""
        tenderGroceriesDescription = ""
        tenderGroceriesAmountText = ""
        tenderMiscDescription = ""
        tenderMiscAmountText = ""

        withAnimation(.easeInOut(duration: 0.18)) {
            isTenderServicesExpanded = false
        }

        let toastUntil = Date().addingTimeInterval(2.0)
        tenderEntryToastMessage = "Purchase Logged"
        tenderEntryToastUntil = toastUntil

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if tenderEntryToastUntil == toastUntil {
                tenderEntryToastMessage = nil
                tenderEntryToastUntil = nil
            }
        }
    }

    @MainActor
    private func handleTenderReceiptCapture(_ image: UIImage) {
        if let filename = SmartTenderReceiptStorage.saveImage(image) {
            store.addTenderReceiptImage(filename: filename, date: tenderDraftDate)
        }
    }

}

// MARK: - Fish ticket OCR quick entry screen

@MainActor
struct SmartFishTicketOCRQuickView: View {
    @ObservedObject var store: SmartLogbookStore

    private let autoCreateDraftOnAppear: Bool
    private let autoStartSummaryCapture: Bool

    @State private var selectedOpeningID: UUID?
    @State private var didPrepareInitialDraft = false

    init(
        store: SmartLogbookStore,
        autoCreateDraftOnAppear: Bool = false,
        autoStartSummaryCapture: Bool = false
    ) {
        self.store = store
        self.autoCreateDraftOnAppear = autoCreateDraftOnAppear
        self.autoStartSummaryCapture = autoStartSummaryCapture
    }

    private var activeSeason: SmartLogbookSeason? { store.activeSeason }

    var body: some View {
        ZStack {
            smartLogbookBackgroundTop.ignoresSafeArea()
            SmartLogbookHostingBackgroundFixer(color: smartLogbookNavBarUIColor)
                .frame(width: 0, height: 0)

            LinearGradient(
                colors: [smartLogbookBackgroundTop, smartLogbookBackgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    if let season = activeSeason {
                        if season.deliveryOpenings.isEmpty {
                            emptyStateCard("No deliveries exist yet. Add a delivery draft to start fish-ticket OCR.")
                        } else {
                            if !autoCreateDraftOnAppear {
                                openingSelectorCard(season)
                            }
                            selectedOCRCard(season)
                        }
                    } else {
                        emptyStateCard(autoCreateDraftOnAppear ? "Preparing a delivery draft…" : "No active delivery exists yet. Add one from Logbook or use the camera shortcut to create it automatically.")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Fish Ticket OCR")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(smartLogbookAccent, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            prepareInitialDraftIfNeeded()
            SmartLogbookNavAppearance.applyNavBar()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fish Ticket OCR")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .underline(true, color: .white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .center)

            Text("Fast camera entry for the active delivery. Capture the ticket first page, review the parsed fields, then capture the tally sheet.")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openingSelectorCard(_ season: SmartLogbookSeason) -> some View {
        let deliveries = season.deliveryOpenings

        return VStack(alignment: .leading, spacing: 10) {
            Text("Choose Delivery")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .center)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(deliveries.enumerated()), id: \.element.id) { index, opening in
                        Button {
                            selectedOpeningID = opening.id
                        } label: {
                            VStack(spacing: 2) {
                            Text("Delivery Record \(index + 1)")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                Text(SmartLogbookFormat.dayMonth.string(from: opening.openingDate))
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 36)
                            .background(opening.id == resolvedSelectedOpeningID(for: season) ? smartLogbookAccent : Color.white.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
                            )
                        }
                        .buttonStyle(SatChartPressFeedbackButtonStyle())
                    }
                }
            }
        }
        .smartLogbookCardStyle()
    }

    @ViewBuilder
    private func selectedOCRCard(_ season: SmartLogbookSeason) -> some View {
        let deliveries = season.deliveryOpenings
        if let selected = selectedOpening(for: season),
           let openingBinding = store.bindingForOpening(openingID: selected.id) {
            let index = deliveries.firstIndex(where: { $0.id == selected.id }) ?? 0

            SmartLogbookOpeningCard(
                opening: openingBinding,
                store: store,
                entryIndex: index,
                seasonBaseDistrict: season.district,
                priorCatchLbs: store.catchToDate(beforeOpeningID: selected.id),
                canDelete: false,
                autoStartSummaryCapture: autoStartSummaryCapture,
                onDelete: {},
                onCopyPreviousNotes: { store.copyNotesForward(into: selected.id) },
                hasPreviousOpening: index > 0
            )
        } else {
            emptyStateCard("Select a delivery to begin fish-ticket OCR.")
        }
    }

    private func emptyStateCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(0.76))
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .smartLogbookCardStyle()
    }

    private func resolvedSelectedOpeningID(for season: SmartLogbookSeason) -> UUID? {
        let deliveries = season.deliveryOpenings
        if let selectedOpeningID,
           deliveries.contains(where: { $0.id == selectedOpeningID }) {
            return selectedOpeningID
        }
        return deliveries.last?.id
    }

    private func selectedOpening(for season: SmartLogbookSeason) -> SmartLogbookOpening? {
        guard let resolvedID = resolvedSelectedOpeningID(for: season) else { return nil }
        return season.deliveryOpenings.first(where: { $0.id == resolvedID })
    }

    private func prepareInitialDraftIfNeeded() {
        store.reloadFromDisk()
        guard !didPrepareInitialDraft else {
            selectDefaultOpeningIfNeeded()
            return
        }

        didPrepareInitialDraft = true
        if autoCreateDraftOnAppear {
            let fallbackDistrict = store.activeSeason?.currentDistrict ?? store.draftDistrict
            selectedOpeningID = store.addOCRDeliveryDraft(on: Date(), fallbackDistrict: fallbackDistrict, reusingBlankDraft: true)
            store.reloadFromDisk()
        }
        selectDefaultOpeningIfNeeded()
    }

    private func selectDefaultOpeningIfNeeded() {
        guard let season = activeSeason else {
            selectedOpeningID = nil
            return
        }

        let deliveries = season.deliveryOpenings

        if let selectedOpeningID,
           deliveries.contains(where: { $0.id == selectedOpeningID }) {
            return
        }

        selectedOpeningID = deliveries.last?.id
    }
}

// MARK: - Navigation camera OCR launch flow

@MainActor
struct SmartFishTicketOCRLaunchFlowView: View {
    @ObservedObject var store: SmartLogbookStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedOpeningID: UUID?
    @State private var didPrepareDraft = false
    @State private var showTicketCapture = false
    @State private var shouldAutoStartTallyCapture = false
    @State private var stage: Stage = .launch

    private enum Stage {
        case launch
        case ticket
        case tallyPrompt
        case delivery
    }

    private var activeSeason: SmartLogbookSeason? {
        store.activeSeason
    }

    private var selectedOpening: SmartLogbookOpening? {
        guard let selectedOpeningID else { return nil }
        return activeSeason?.openings.first(where: { $0.id == selectedOpeningID })
    }

    private var selectedDeliveryIndex: Int {
        guard let selectedOpening else { return 0 }
        return activeSeason?.deliveryOpenings.firstIndex(where: { $0.id == selectedOpening.id }) ?? 0
    }

    var body: some View {
        ZStack {
            smartLogbookBackgroundTop.ignoresSafeArea()
            SmartLogbookHostingBackgroundFixer(color: smartLogbookNavBarUIColor)
                .frame(width: 0, height: 0)

            LinearGradient(
                colors: [smartLogbookBackgroundTop, smartLogbookBackgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    switch stage {
                    case .launch:
                        launchCard
                    case .ticket:
                        ticketCaptureCard
                    case .tallyPrompt:
                        tallyPromptCard
                    case .delivery:
                        deliveryReviewCard
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Fish Ticket OCR")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(smartLogbookAccent, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            prepareDraftIfNeeded()
            SmartLogbookNavAppearance.applyNavBar()
        }
        .onChange(of: showTicketCapture) { shouldShow in
            if shouldShow {
                stage = .ticket
            }
        }
    }

    private var launchCard: some View {
        VStack(spacing: 14) {
            Button {
                prepareDraftIfNeeded()
                showTicketCapture = true
                stage = .ticket
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "camera.fill")
                    Text("Capture Ticket")
                }
                .frame(maxWidth: .infinity)
            }
            .smartLogbookSmallPillButtonStyle(fillColor: smartLogbookCaptureYellow, textColor: .black)

            Text("Take a photo of your fish ticket to autofill to a delivery log.")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Fish ticket photos and extracted fields stay private on this device. SatChart does not upload them or view them unless you choose to export or share them.")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.74))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)

            Button {
                deleteDraftAndDismiss()
            } label: {
                Text("Delete & Exit")
                    .frame(maxWidth: .infinity)
            }
            .smartLogbookSmallSecondaryButtonStyle()
        }
        .smartLogbookCardStyle()
    }

    @ViewBuilder
    private var ticketCaptureCard: some View {
        if let card = selectedOpeningCard(
            autoStartSummaryCapture: showTicketCapture,
            showOnlyTicketCapture: true,
            showShortcutControls: false
        ) {
            card
        } else {
            flowUnavailableCard
        }
    }

    private var tallyPromptCard: some View {
        VStack(spacing: 14) {
            Button {
                showTicketCapture = false
                shouldAutoStartTallyCapture = true
                stage = .delivery
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "camera.fill")
                    Text("Capture Tally Sheet")
                }
                .frame(maxWidth: .infinity)
            }
            .smartLogbookSmallPillButtonStyle(fillColor: smartLogbookCaptureYellow, textColor: .black)

            Text("Take a photo of your tally sheet for detailed pick logs.")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showTicketCapture = false
                shouldAutoStartTallyCapture = false
                stage = .delivery
            } label: {
                Text("Maybe Later")
                    .frame(maxWidth: .infinity)
            }
            .smartLogbookSmallSecondaryButtonStyle()
        }
        .smartLogbookCardStyle()
    }

    @ViewBuilder
    private var deliveryReviewCard: some View {
        if let card = selectedOpeningCard(
            autoStartSummaryCapture: false,
            autoStartTallyCapture: shouldAutoStartTallyCapture,
            showOnlyTicketCapture: false,
            showShortcutControls: true
        ) {
            card
        } else {
            flowUnavailableCard
        }
    }

    private var flowUnavailableCard: some View {
        VStack(spacing: 12) {
            Text(store.lastDeliveryDraftError ?? "Delivery draft unavailable. SatChart could not prepare a new UUID-based delivery record.")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            Button {
                dismiss()
            } label: {
                Text("Back to Navigation")
                    .frame(maxWidth: .infinity)
            }
            .smartLogbookSmallPillButtonStyle(fillColor: smartLogbookAccent)
        }
        .smartLogbookCardStyle()
    }

    private func selectedOpeningCard(
        autoStartSummaryCapture: Bool,
        autoStartTallyCapture: Bool = false,
        showOnlyTicketCapture: Bool,
        showShortcutControls: Bool
    ) -> AnyView? {
        guard
            let season = activeSeason,
            let selectedOpening,
            let openingBinding = store.bindingForOpening(openingID: selectedOpening.id)
        else {
            return nil
        }

        let card = SmartLogbookOpeningCard(
            opening: openingBinding,
            store: store,
            entryIndex: selectedDeliveryIndex,
            seasonBaseDistrict: season.district,
            priorCatchLbs: store.catchToDate(beforeOpeningID: selectedOpening.id),
            canDelete: true,
            autoStartSummaryCapture: autoStartSummaryCapture,
            autoStartTallyCapture: autoStartTallyCapture,
            showOnlyTicketCapture: showOnlyTicketCapture,
            showShortcutControls: showShortcutControls,
            onDelete: {
                deleteDraftAndDismiss()
            },
            onCopyPreviousNotes: { store.copyNotesForward(into: selectedOpening.id) },
            hasPreviousOpening: selectedDeliveryIndex > 0,
            onTicketApplied: {
                showTicketCapture = false
                stage = .tallyPrompt
            },
            onTallyApplied: {
                showTicketCapture = false
                shouldAutoStartTallyCapture = false
                stage = .delivery
            },
            onBackToNavigation: {
                dismiss()
            }
        )

        return AnyView(card)
    }

    private func prepareDraftIfNeeded() {
        store.reloadFromDisk()

        if let selectedOpeningID,
           activeSeason?.openings.contains(where: { $0.id == selectedOpeningID }) == true {
            return
        }

        guard !didPrepareDraft else {
            selectedOpeningID = activeSeason?.deliveryOpenings.last?.id
            return
        }

        didPrepareDraft = true
        let fallbackDistrict = store.activeSeason?.currentDistrict ?? store.draftDistrict
        selectedOpeningID = store.addOCRDeliveryDraft(on: Date(), fallbackDistrict: fallbackDistrict, reusingBlankDraft: true)
        store.reloadFromDisk()
    }

    private func deleteDraftAndDismiss() {
        if let selectedOpeningID {
            store.deleteOpening(selectedOpeningID)
        }
        dismiss()
    }
}

// MARK: - Opening card

private struct SmartLogbookOpeningCard: View {
    private enum QCSheetCaptureMode {
        case append
        case replaceLast
    }

    @Binding var opening: SmartLogbookOpening
    @ObservedObject var store: SmartLogbookStore

    let entryIndex: Int
    let seasonBaseDistrict: District
    let priorCatchLbs: Int
    let canDelete: Bool
    var autoStartSummaryCapture: Bool = false
    var autoStartTallyCapture: Bool = false
    var showOnlyTicketCapture: Bool = false
    var showShortcutControls: Bool = false
    let onDelete: () -> Void
    let onCopyPreviousNotes: () -> Void
    let hasPreviousOpening: Bool
    var onTicketApplied: (() -> Void)? = nil
    var onTallyApplied: (() -> Void)? = nil
    var onBackToNavigation: (() -> Void)? = nil

    @State private var dashboardSnapshot: SmartLogbookDashboardSnapshot?
    @State private var environmentSnapshot: SmartLogbookEnvironmentSnapshot?
    @State private var dashboardStatusMessage: String = ""
    @State private var environmentStatusMessage: String = ""
    @State private var isLoadingDashboard = false
    @State private var isLoadingEnvironment = false
    @State private var showFishTicketSummaryCamera = false
    @State private var showFishTicketTallyCameraFlow = false
    @State private var showQCSheetCamera = false
    @State private var qcSheetCaptureMode: QCSheetCaptureMode = .append
    @State private var isSavingQCSheet = false
    @State private var qcSheetStatus: String? = nil
    @State private var showClearWarning = false
    @State private var showFishTicketSummaryCapturePrompt = false
    @State private var showFishTicketTallyCapturePrompt = false
    @State private var isExtractingFishTicket = false
    @State private var fishTicketProcessingTask: Task<Void, Never>? = nil
    @State private var fishTicketProcessingGeneration: UUID? = nil
    @State private var fishTicketExtractionStatus: String? = nil
    @State private var fishTicketReviewDraft: SmartFishTicketExtractionDraft? = nil
    @State private var fishTicketTallyReviewDraft: SmartFishTicketTallyExtractionDraft? = nil
    @State private var pendingDuplicateFishTicketDraft: SmartFishTicketExtractionDraft? = nil
    @State private var showDuplicateFishTicketWarning = false
    @State private var driftOpeningFallbackStart = Date()
    @State private var driftOpeningFallbackEnd = Date()
    @State private var openingDateMismatchToastMessage: String? = nil
    @State private var didAutoLaunchSummaryCapture = false
    @State private var didAutoLaunchTallyCapture = false

    private var effectiveDistrict: District {
        opening.openingDistrict ?? seasonBaseDistrict
    }

    private var assignedFishingSets: [SmartFishingSetRecord] {
        store.assignedFishingSets(forOpeningID: opening.id)
    }

    private var cardTitle: String {
        "Delivery Record \(entryIndex + 1)"
    }

    private var deleteDeliveryButton: some View {
        SatChartDeleteConfirmationButton(
            confirmationTitle: "Delete \(cardTitle)?",
            confirmationMessage: "This permanently deletes the delivery log.",
            onConfirm: onDelete
        ) { isFlashingRed in
            SatChartDeleteIcon(isFlashingRed: isFlashingRed, defaultColor: .white)
                .font(.system(size: 12, weight: .bold))
        }
        .smartLogbookIconButtonStyle()
        .accessibilityLabel("Delete \(cardTitle)")
    }

    private var openingDateText: String {
        let trimmedStartDate = opening.startDateCaughtText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedStartDate.isEmpty ? SmartLogbookFormat.dayMonth.string(from: opening.openingDate) : trimmedStartDate
    }

    private var catchBinding: Binding<String> {
        Binding(
            get: { opening.totalCatchLbs.map(String.init) ?? "" },
            set: { raw in
                let digits = raw.filter(\.isNumber)
                opening.totalCatchLbs = digits.isEmpty ? nil : Int(digits)
            }
        )
    }

    private var fishTempBinding: Binding<String> {
        Binding(get: { opening.fishTempF }, set: { opening.fishTempF = $0 })
    }

    private var statAreaBinding: Binding<String> {
        Binding(
            get: { opening.statAreaText },
            set: { handleStatAreaChange($0) }
        )
    }

    private var deliveryTenderBinding: Binding<String> {
        Binding(get: { opening.deliveryTender }, set: { opening.deliveryTender = $0 })
    }

    private var startDateCaughtBinding: Binding<String> {
        Binding(
            get: { opening.startDateCaughtText },
            set: { newValue in
                handleStartDateCaughtChange(newValue, shouldWarnOnMismatch: true)
            }
        )
    }

    private var dateLandedBinding: Binding<String> {
        Binding(
            get: { opening.dateLandedText },
            set: { handleDateLandedChange($0) }
        )
    }

    private var timeOfLandingBinding: Binding<String> {
        Binding(get: { opening.timeOfLandingText }, set: { opening.timeOfLandingText = $0 })
    }

    private var chillTypeBinding: Binding<String> {
        Binding(get: { opening.chillType }, set: { opening.chillType = $0 })
    }

    private var driftOpeningStartDate: Date {
        opening.driftOpeningStart ?? dashboardSnapshot?.driftOpeningStart ?? driftOpeningFallbackStart
    }

    private var driftOpeningEndDate: Date {
        if let savedEnd = opening.driftOpeningEnd {
            return savedEnd
        }
        if let dashboardEnd = dashboardSnapshot?.driftOpeningEnd {
            return dashboardEnd
        }
        return alignedDateKeepingTime(source: driftOpeningFallbackEnd, toMatchDayOf: driftOpeningStartDate)
    }

    private var normalizedDriftOpeningRange: ClosedRange<Date> {
        let start = driftOpeningStartDate
        var end = driftOpeningEndDate

        if end < start {
            if Calendar.current.isDate(start, inSameDayAs: end) {
                end = Calendar.current.date(byAdding: .day, value: 1, to: end) ?? start
            } else {
                end = start
            }
        }

        return start...end
    }

    private var driftOpeningReferenceDate: Date {
        let range = normalizedDriftOpeningRange
        if Calendar.current.isDate(range.lowerBound, inSameDayAs: range.upperBound) {
            return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: range.lowerBound) ?? range.lowerBound
        }
        return range.lowerBound.addingTimeInterval(range.upperBound.timeIntervalSince(range.lowerBound) / 2.0)
    }

    private var parsedStartDateCaught: Date? {
        resolvedFishTicketStartDate(from: opening.startDateCaughtText)
    }

    private var smartFieldReferenceDate: Date {
        parsedStartDateCaught ?? opening.openingDate
    }

    private var reloadKey: String {
        [
            effectiveDistrict.key,
            SmartLogbookFormat.dayKey.string(from: smartFieldReferenceDate),
            SmartLogbookFormat.dayKey.string(from: driftOpeningReferenceDate)
        ]
        .joined(separator: "__")
    }

    private var autoFieldDateTag: String {
        SmartLogbookFormat.dayMonth.string(from: smartFieldReferenceDate)
    }

    private var driftOpeningDateTag: String {
        SmartLogbookFormat.dayMonth.string(from: normalizedDriftOpeningRange.lowerBound)
    }

    private var driftOpeningStartBinding: Binding<Date> {
        Binding(
            get: { driftOpeningStartDate },
            set: { newValue in
                let previousStart = driftOpeningStartDate
                opening.driftOpeningStart = newValue
                driftOpeningFallbackStart = newValue

                let currentEnd = opening.driftOpeningEnd ?? dashboardSnapshot?.driftOpeningEnd ?? driftOpeningFallbackEnd
                if opening.driftOpeningEnd == nil || Calendar.current.isDate(currentEnd, inSameDayAs: previousStart) {
                    let updatedEnd = alignedDateKeepingTime(source: currentEnd, toMatchDayOf: newValue)
                    opening.driftOpeningEnd = updatedEnd
                    driftOpeningFallbackEnd = updatedEnd
                }
            }
        )
    }

    private var driftOpeningEndBinding: Binding<Date> {
        Binding(
            get: { driftOpeningEndDate },
            set: { newValue in
                opening.driftOpeningEnd = newValue
                driftOpeningFallbackEnd = newValue
            }
        )
    }

    private var driftOpeningRangeSummaryText: String {
        SmartLogbookFormat.driftOpeningSummary(
            start: normalizedDriftOpeningRange.lowerBound,
            end: normalizedDriftOpeningRange.upperBound
        )
    }

    private var fishTicketSummaryPreviewImage: UIImage? {
        guard let filename = opening.fishTicketSummaryImageFilename else { return nil }
        return SmartFishTicketStorage.loadPreviewImage(named: filename)
    }

    private var fishTicketSummaryPreviewImages: [UIImage] {
        fishTicketSummaryPreviewImage.map { [$0] } ?? []
    }

    private var fishTicketTallyPreviewImages: [UIImage] {
        opening.fishTicketTallyImageFilenames.compactMap {
            SmartFishTicketStorage.loadPreviewImage(named: $0)
        }
    }

    private var qcSheetPreviewImages: [UIImage] {
        opening.qcSheetImageFilenames.compactMap {
            SmartFishTicketStorage.loadPreviewImage(named: $0)
        }
    }

    private var openingHasAppliedFishTicketSummary: Bool {
        opening.totalCatchLbs != nil
            || !opening.statAreaText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !opening.startDateCaughtText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !opening.dateLandedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !opening.timeOfLandingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !opening.fishTempF.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !opening.deliveryTender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !opening.chillType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canCaptureFishTicketTally: Bool {
        opening.didCaptureFishTicket && openingHasAppliedFishTicketSummary
    }

    private func currentFishTicketValue(for field: SmartFishTicketField) -> String {
        switch field {
        case .postTare:
            return opening.totalCatchLbs.map(String.init) ?? ""
        case .statArea:
            return opening.statAreaText
        case .startDateCaught:
            return opening.startDateCaughtText
        case .dateLanded:
            return opening.dateLandedText
        case .timeOfLanding:
            return opening.timeOfLandingText
        case .tenderName:
            return opening.deliveryTender
        case .chillType:
            return opening.chillType
        case .temperature:
            return opening.fishTempF
        }
    }

    private func normalizedComparableFishTicketValue(_ raw: String, for field: SmartFishTicketField) -> String {
        switch field {
        case .postTare:
            return SmartLogbookParse.normalizedIntegerString(raw)
        case .statArea:
            return BristolBayStatAreaResolver.resolve(raw)?.normalizedStatArea ?? SmartLogbookParse.cleanedFishTicketValue(raw, for: field)
        case .startDateCaught, .dateLanded:
            return SmartLogbookParse.firstDateString(in: raw) ?? ""
        case .timeOfLanding:
            return SmartLogbookParse.first24HourTimeString(in: raw) ?? ""
        case .tenderName, .chillType:
            return SmartLogbookParse.normalizedAnchor(
                SmartLogbookParse.cleanedFishTicketValue(raw, for: field)
            )
        case .temperature:
            return SmartLogbookParse.firstDecimalString(in: raw) ?? ""
        }
    }

    private func summaryDraftDiffersFromCurrent(_ draft: SmartFishTicketExtractionDraft) -> Bool {
        if let draftSoldWeight = draft.postTareLbs, opening.totalCatchLbs != draftSoldWeight {
            return true
        }

        for field in SmartFishTicketField.allCases where field != .postTare {
            let draftValue = normalizedComparableFishTicketValue(draft.valueText(for: field), for: field)
            if draftValue.isEmpty { continue }

            let currentValue = normalizedComparableFishTicketValue(currentFishTicketValue(for: field), for: field)
            if draftValue != currentValue {
                return true
            }
        }

        return false
    }

    private func shouldPresentSummaryReview(summaryDraft: SmartFishTicketExtractionDraft?) -> Bool {
        guard let summaryDraft else { return false }
        guard openingHasAppliedFishTicketSummary else { return false }
        return summaryDraftDiffersFromCurrent(summaryDraft)
    }

    private var entryFieldsAreEmpty: Bool {
        catchBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && statAreaBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && startDateCaughtBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && dateLandedBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && timeOfLandingBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && fishTempBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && deliveryTenderBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && chillTypeBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && opening.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && opening.fishTicketImageFilenames.isEmpty
        && opening.qcSheetImageFilenames.isEmpty
        && opening.fishTicketTallyRows.isEmpty
    }

    private var catchSummaryText: String {
        guard let catchLbs = opening.totalCatchLbs else { return "—" }
        return "\(SmartLogbookFormat.number(catchLbs)) lb"
    }

    private var statAreaResolution: BristolBayStatAreaResolution? {
        BristolBayStatAreaResolver.resolve(opening.statAreaText)
    }

    private var appliedStatAreaText: String {
        let trimmed = opening.statAreaText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }

    private var appliedDistrictFishedText: String {
        statAreaResolution?.district.rawValue ?? "—"
    }

    private var appliedSectionText: String {
        let trimmed = opening.statAreaSectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }

    private var catchToDateDisplayedLbs: Int {
        priorCatchLbs + (opening.totalCatchLbs ?? 0)
    }

    private var hasVisibleDriftOpeningRange: Bool {
        opening.driftOpeningStart != nil
            || opening.driftOpeningEnd != nil
            || dashboardSnapshot?.driftOpeningStart != nil
            || dashboardSnapshot?.driftOpeningEnd != nil
            || opening.isDriftOpeningConfirmed
    }

    private var openingWindowSummaryText: String {
        if hasVisibleDriftOpeningRange {
            return driftOpeningRangeSummaryText
        }
        if let range = SmartLogbookParse.firstTimeRange(in: dashboardSnapshot?.openingText) {
            return range
        }
        if let openingText = dashboardSnapshot?.openingText, !openingText.isEmpty {
            return openingText
                .components(separatedBy: .newlines)
                .first?
                .replacingOccurrences(of: "Next: ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unavailable"
        }
        if let openingHours = opening.openingHours {
            return SmartLogbookFormat.hours(openingHours)
        }
        return "Unavailable"
    }

    private var collapsedOpeningPrimaryText: String {
        guard hasVisibleDriftOpeningRange else {
            return openingWindowSummaryText
        }

        let range = normalizedDriftOpeningRange
        return "Start: \(SmartLogbookFormat.compactOpeningDateTimeLine(range.lowerBound))"
    }

    private var collapsedOpeningSecondaryText: String? {
        guard hasVisibleDriftOpeningRange else { return nil }
        let range = normalizedDriftOpeningRange
        return "End: \(SmartLogbookFormat.compactOpeningDateTimeLine(range.upperBound))"
    }

    private var outcomeIconSystemName: String {
        opening.outcome?.compactThumbSystemName ?? "hand.thumbsup.fill"
    }

    private var outcomeIconRotation: Angle {
        opening.outcome?.compactThumbRotation ?? .degrees(90)
    }

    private var outcomeIconTint: Color {
        opening.outcome?.tint ?? .white.opacity(0.45)
    }

    private var isTodayOpening: Bool {
        Calendar.current.isDate(opening.openingDate, inSameDayAs: Date())
    }

    private func releaseStatus(for value: String?, loading: Bool = false) -> SmartFieldReleaseStatus? {
        guard isTodayOpening else { return nil }
        if loading { return .pendingRelease }
        let normalized = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty || normalized == "—" || normalized.contains("unavailable") || normalized.contains("not available") || normalized.contains("loading") {
            return .pendingRelease
        }
        return .releasedToday
    }

    private var tideChartMarkers: [SmartLogbookTideChartMarker] {
        let range = normalizedDriftOpeningRange
        let spansMultipleDays = !SmartLogbookFormat.alaskaCalendar.isDate(range.lowerBound, inSameDayAs: range.upperBound)

        return [
            SmartLogbookTideChartMarker(
                date: range.lowerBound,
                label: "Start: \(SmartLogbookFormat.timeLine(range.lowerBound))",
                color: .white.opacity(0.92),
                annotationAlignment: .leading
            ),
            SmartLogbookTideChartMarker(
                date: range.upperBound,
                label: spansMultipleDays
                    ? "End: \(SmartLogbookFormat.monthDayTimeLine(range.upperBound))"
                    : "End: \(SmartLogbookFormat.timeLine(range.upperBound))",
                color: .white.opacity(0.92),
                annotationAlignment: .trailing
            )
        ]
    }

    private var tideChartCaptionText: String? {
        let parts = [environmentSnapshot?.tideSecondaryText, environmentSnapshot?.sourceText]
            .compactMap { value -> String? in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }

        if !parts.isEmpty {
            return parts.joined(separator: " • ")
        }

        let fallback = environmentStatusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
    }

    private var driftOpeningEditorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("Drift Opening")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .underline(true, color: .white.opacity(0.50))

                Spacer(minLength: 0)

                Button {
                    if opening.isDriftOpeningConfirmed {
                        unlockDriftOpeningSelection()
                    } else {
                        confirmDriftOpeningSelection()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: opening.isDriftOpeningConfirmed ? "pencil" : "checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text(opening.isDriftOpeningConfirmed ? "Edit" : "Confirm")
                    }
                }
                .smartLogbookSmallPillButtonStyle(fillColor: smartLogbookAccent)
            }

            HStack(spacing: 8) {
                SmartLogbookDateTimePickerField(
                    title: "Opening Start Date",
                    selection: driftOpeningStartBinding,
                    displayedComponents: .date,
                    isLocked: opening.isDriftOpeningConfirmed,
                    showsContainer: false
                )

                SmartLogbookDateTimePickerField(
                    title: "Opening Start Time",
                    selection: driftOpeningStartBinding,
                    displayedComponents: .hourAndMinute,
                    isLocked: opening.isDriftOpeningConfirmed,
                    forcesAMPM: true,
                    showsContainer: false
                )
            }

            HStack(spacing: 8) {
                SmartLogbookDateTimePickerField(
                    title: "Opening End Date",
                    selection: driftOpeningEndBinding,
                    displayedComponents: .date,
                    isLocked: opening.isDriftOpeningConfirmed,
                    showsContainer: false
                )

                SmartLogbookDateTimePickerField(
                    title: "Opening End Time",
                    selection: driftOpeningEndBinding,
                    displayedComponents: .hourAndMinute,
                    isLocked: opening.isDriftOpeningConfirmed,
                    forcesAMPM: true,
                    showsContainer: false
                )
            }
        }
        .padding(10)
        .smartLogbookInsetStyle(highlighted: !opening.isDriftOpeningConfirmed)
    }

    private var fishingSetsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("Sets")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .underline(true, color: .white.opacity(0.50))

                Spacer(minLength: 0)

                Text("\(assignedFishingSets.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
            }

            if assignedFishingSets.isEmpty {
                Text("No sets recorded for this delivery yet. Use Record Set on the navigation page to capture soak time, drift, tides, and coordinates.")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(assignedFishingSets) { fishingSet in
                    if let setBinding = store.bindingForFishingSet(setID: fishingSet.id) {
                        SmartFishingSetDetailRow(set: setBinding)
                    }
                }
            }
        }
        .padding(10)
        .smartLogbookInsetStyle(highlighted: !assignedFishingSets.isEmpty)
    }

    private var tidesSmartFieldCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text("Tides")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.70))

                SmartAutoFieldDateTag(text: driftOpeningDateTag)

                if let status = releaseStatus(
                    for: environmentSnapshot?.tidePrimaryText ?? (environmentSnapshot?.tideCurvePoints.isEmpty == false ? "Tide chart available" : nil),
                    loading: isLoadingEnvironment
                ) {
                    SmartFieldStatusBadge(status: status)
                }

                Spacer(minLength: 0)
            }

            SmartLogbookTideCurveChartView(
                points: environmentSnapshot?.tideCurvePoints ?? [],
                referenceDate: driftOpeningReferenceDate,
                height: 104,
                showYAxis: false,
                showXAxis: false,
                labelColor: .white.opacity(0.72),
                gridColor: .white.opacity(0.14),
                tickColor: .white.opacity(0.22),
                axisLabelFont: .system(size: 8, weight: .semibold, design: .rounded),
                emptyMessage: isLoadingEnvironment ? "Loading tide chart…" : "Tide chart unavailable for this opening",
                emptyMessageColor: .white.opacity(0.72),
                currentHeightLabel: nil,
                showsReferenceRule: false,
                highlightedRange: normalizedDriftOpeningRange,
                highlightedRangeColor: Color(uiColor: UIColor(red: 0.03, green: 0.23, blue: 0.48, alpha: 0.18)),
                markers: tideChartMarkers
            )
            .frame(maxWidth: .infinity, minHeight: 104, maxHeight: 104)

            if let caption = tideChartCaptionText {
                Text(caption)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.64))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .smartLogbookInsetStyle()
    }

    private var fishTicketOCROnlyBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(showOnlyTicketCapture ? "Capture Ticket" : "Delivery Record \(entryIndex + 1)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Spacer(minLength: 0)

                if !showOnlyTicketCapture {
                    Text("\(openingDateText) • \(effectiveDistrict.rawValue)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.82))
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
            }

            fishTicketOCRCard

            if !showOnlyTicketCapture {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Applied Delivery Fields")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .underline(true, color: .white.opacity(0.50))

                        Spacer(minLength: 0)

                        Button("Edit") {
                            fishTicketReviewDraft = makeCurrentSummaryReviewDraft()
                        }
                        .smartLogbookSmallPillButtonStyle(fillColor: smartLogbookAccent)
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        SmartCompactDeliveryField(label: "Sold Weight", value: catchSummaryText)
                        SmartCompactDeliveryField(label: "Stat Area", value: appliedStatAreaText)
                        SmartCompactDeliveryField(label: "District Fished", value: appliedDistrictFishedText)
                        SmartCompactDeliveryField(label: "Section", value: appliedSectionText)
                        SmartCompactDeliveryField(label: "Start Date", value: opening.startDateCaughtText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "—" : opening.startDateCaughtText)
                        SmartCompactDeliveryField(label: "Opening Start Time", value: SmartLogbookFormat.dateTimeLine(driftOpeningStartDate))
                        SmartCompactDeliveryField(label: "Opening End Time", value: SmartLogbookFormat.dateTimeLine(driftOpeningEndDate))
                        SmartCompactDeliveryField(label: "Date Landed", value: opening.dateLandedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "—" : opening.dateLandedText)
                        SmartCompactDeliveryField(label: "Time Landed", value: opening.timeOfLandingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "—" : opening.timeOfLandingText)
                        SmartCompactDeliveryField(label: "Tender", value: opening.deliveryTender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "—" : opening.deliveryTender)
                        SmartCompactDeliveryField(label: "Chill", value: opening.chillType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "—" : opening.chillType)
                        SmartCompactDeliveryField(label: "Fish Temperature", value: opening.fishTempF.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "—" : opening.fishTempF)
                    }

                    if statAreaResolution == nil {
                        Text("District Fished stays blank until Stat Area matches a known Bristol Bay area.")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                }
                .padding(10)
                .smartLogbookInsetStyle()

                if !opening.fishTicketTallyRows.isEmpty {
                    SmartFishTicketTallyTableCard(
                        rows: opening.fishTicketTallyRows,
                        onEdit: {
                            fishTicketTallyReviewDraft = makeCurrentTallyReviewDraft()
                        }
                    )
                }
            }

            if showShortcutControls {
                HStack {
                    Spacer(minLength: 0)

                    Button {
                        onBackToNavigation?()
                    } label: {
                        Text("Save and Exit")
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                    }
                    .frame(maxWidth: 190)
                    .smartLogbookSmallPillButtonStyle(fillColor: smartLogbookAccent)

                    Spacer(minLength: 0)
                }
            }
        }
        .smartLogbookDeliveryCardStyle()
    }

    private var fishTicketOCRCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fish Ticket OCR")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fish Ticket")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text(opening.didCaptureFishTicket ? "1 summary photo saved" : "Required before tally sheet")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.68))
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 8) {
                        Button {
                            if opening.didCaptureFishTicket {
                                showFishTicketSummaryCamera = true
                            } else {
                                showFishTicketSummaryCapturePrompt = true
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "camera.fill")
                                Text(opening.didCaptureFishTicket ? "Retake Ticket" : "Capture Ticket")
                            }
                        }
                        .smartLogbookSmallPillButtonStyle(fillColor: smartLogbookCaptureYellow, textColor: .black)
                        .disabled(isExtractingFishTicket)

                        if !opening.fishTicketImageFilenames.isEmpty {
                            SatChartDeleteConfirmationButton(
                                confirmationTitle: "Delete saved fish-ticket photos?",
                                confirmationMessage: "Applied delivery fields and tally rows will stay as-is.",
                                onConfirm: deleteFishTicketPhotos
                            ) { isFlashingRed in
                                SatChartDeleteIcon(isFlashingRed: isFlashingRed, defaultColor: .white)
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .smartLogbookIconButtonStyle()
                            .disabled(isExtractingFishTicket)
                            .accessibilityLabel("Delete saved fish-ticket photos")
                        }
                    }
                }

                if let summaryImage = fishTicketSummaryPreviewImage {
                    SmartImageThumbnailStrip(images: [summaryImage], height: 92)
                } else if !showOnlyTicketCapture {
                    Text("Take a picture of the first page of the fish ticket. Sold Weight, Stat Area, Start Date Caught, Date Landed, Time of Landing, Fish Temperature, Tender Name, and Chill Type will autofill from this step.")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if opening.didCaptureFishTicket {
                    Button {
                        startFishTicketSummaryReread()
                    } label: {
                        Text("Re-Read Ticket")
                    }
                    .smartLogbookSmallSecondaryButtonStyle()
                    .disabled(isExtractingFishTicket)
                }
            }
            .padding(10)
            .smartLogbookInsetStyle(highlighted: !opening.didCaptureFishTicket)

            if !showOnlyTicketCapture {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tally Sheet")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text(opening.hasCapturedFishTicketTally ? "Tally photo saved" : (canCaptureFishTicketTally ? "Ready to capture" : "Available after ticket fields are applied"))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.68))
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 8) {
                        Button {
                            guard canCaptureFishTicketTally else { return }
                            if opening.hasCapturedFishTicketTally {
                                showFishTicketTallyCameraFlow = true
                            } else {
                                showFishTicketTallyCapturePrompt = true
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "camera.fill")
                                Text(opening.hasCapturedFishTicketTally ? "Retake Tally" : "Capture Tally Sheet")
                            }
                        }
                        .smartLogbookSmallPillButtonStyle(
                            fillColor: canCaptureFishTicketTally ? smartLogbookCaptureYellow : smartLogbookCaptureYellowDisabled,
                            textColor: .black
                        )
                        .disabled(!canCaptureFishTicketTally || isExtractingFishTicket)

                        if opening.hasCapturedFishTicketTally {
                            SatChartDeleteConfirmationButton(
                                confirmationTitle: "Delete saved tally-sheet photos?",
                                confirmationMessage: "Applied tally rows will stay as-is.",
                                onConfirm: deleteFishTicketTallyPhotos
                            ) { isFlashingRed in
                                SatChartDeleteIcon(isFlashingRed: isFlashingRed, defaultColor: .white)
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .smartLogbookIconButtonStyle()
                            .disabled(isExtractingFishTicket)
                            .accessibilityLabel("Delete saved tally-sheet photos")
                        }
                    }
                }

                if !canCaptureFishTicketTally {
                    Text("SatChart requires the first-page fish ticket to be parsed into the delivery fields before tally-sheet capture is enabled.")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                } else if fishTicketTallyPreviewImages.isEmpty {
                    Text("Now take a separate tally-sheet photo. This second OCR pass reads SPECIES, DEL. COND, Post Tare, and Brailers from the table only.")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    SmartImageThumbnailStrip(images: fishTicketTallyPreviewImages, height: 72)
                }

                if opening.hasCapturedFishTicketTally {
                    Button {
                        startFishTicketTallyReread()
                    } label: {
                        Text("Re-Read Tally")
                    }
                    .smartLogbookSmallSecondaryButtonStyle()
                    .disabled(isExtractingFishTicket)
                }
            }
            .padding(10)
            .smartLogbookInsetStyle(highlighted: canCaptureFishTicketTally && !opening.hasCapturedFishTicketTally)

            qcSheetCard
            }

            if isExtractingFishTicket {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)

                    Text("Running fish-ticket OCR…")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.78))
                }
            } else if let fishTicketExtractionStatus, !fishTicketExtractionStatus.isEmpty {
                Text(fishTicketExtractionStatus)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.74))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .smartLogbookInsetStyle(highlighted: entryFieldsAreEmpty)
    }

    private var qcSheetCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("QC Sheet")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text(opening.qcSheetImageFilenames.isEmpty
                         ? "Optional supporting photos"
                         : "\(opening.qcSheetImageFilenames.count) QC sheet photo\(opening.qcSheetImageFilenames.count == 1 ? "" : "s") saved")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.68))
                }

                Spacer(minLength: 0)

                if opening.qcSheetImageFilenames.isEmpty {
                    Button {
                        startQCSheetCapture(mode: .append)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "camera.fill")
                            Text("Capture QC Sheet")
                        }
                    }
                    .smartLogbookSmallPillButtonStyle(fillColor: smartLogbookCaptureYellow, textColor: .black)
                    .disabled(isExtractingFishTicket || isSavingQCSheet)
                }
            }

            if !qcSheetPreviewImages.isEmpty {
                SmartImageThumbnailStrip(images: qcSheetPreviewImages, height: 72)

                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            startQCSheetCapture(mode: .replaceLast)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "camera.fill")
                                Text("Retake QC Sheet")
                            }
                        }
                        .smartLogbookSmallPillButtonStyle(fillColor: smartLogbookCaptureYellow, textColor: .black)
                        .disabled(isExtractingFishTicket || isSavingQCSheet)

                        Button {
                            startQCSheetCapture(mode: .append)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                Text("Add QC Sheet")
                            }
                        }
                        .smartLogbookSmallPillButtonStyle(fillColor: smartLogbookCaptureYellow, textColor: .black)
                        .disabled(isExtractingFishTicket || isSavingQCSheet)
                    }

                    SatChartDeleteConfirmationButton(
                        confirmationTitle: "Delete saved QC sheet photos?",
                        confirmationMessage: "All photos displayed in the QC Sheet card will be deleted.",
                        onConfirm: deleteQCSheetPhotos
                    ) { isFlashingRed in
                        SatChartDeleteIcon(isFlashingRed: isFlashingRed, defaultColor: .white)
                            .font(.system(size: 12, weight: .bold))
                    }
                    .smartLogbookIconButtonStyle()
                    .disabled(isExtractingFishTicket || isSavingQCSheet)
                    .accessibilityLabel("Delete saved QC sheet photos")
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if let qcSheetStatus, !qcSheetStatus.isEmpty {
                Text(qcSheetStatus)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.70))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .smartLogbookInsetStyle()
    }

    private var openingDateMismatchToast: some View {
        Group {
            if let message = openingDateMismatchToastMessage {
                VStack {
                    Spacer(minLength: 0)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(message)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            Spacer(minLength: 0)

                            Button("Close") {
                                openingDateMismatchToastMessage = nil
                            }
                            .smartLogbookSmallPillButtonStyle(fillColor: smartLogbookAccent)
                        }
                    }
                    .padding(12)
                    .background(Color.black.opacity(0.94))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    var body: some View {
        fishTicketOCROnlyBody
        .overlay(alignment: .bottom) {
            openingDateMismatchToast
        }
        .onAppear {
            maybeAutoLaunchSummaryCapture()
            maybeAutoLaunchTallyCapture()
        }
        .onDisappear {
            cancelFishTicketProcessing()
            releaseFishTicketOCRResources()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            releaseFishTicketOCRResources()
        }
        .fullScreenCover(isPresented: $showFishTicketSummaryCamera) {
            SmartSinglePhotoCaptureView(
                sourceType: UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
            ) { image in
                handleFishTicketSummaryCapture(image)
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showFishTicketTallyCameraFlow) {
            SmartSinglePhotoCaptureView(
                sourceType: UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
            ) { image in
                handleFishTicketTallyCapture(image)
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showQCSheetCamera) {
            SmartSinglePhotoCaptureView(
                sourceType: UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
            ) { image in
                handleQCSheetCapture(image)
            }
            .ignoresSafeArea()
        }
        .alert("Fish Ticket", isPresented: $showFishTicketSummaryCapturePrompt) {
            Button("Cancel", role: .cancel) {}
            Button("Continue") {
                showFishTicketSummaryCamera = true
            }
        } message: {
            Text("Take a picture of the first page of the fish ticket. SatChart will parse it first and autofill the delivery fields before asking for the tally sheet.")
        }
        .alert("Tally Sheet", isPresented: $showFishTicketTallyCapturePrompt) {
            Button("Not Now", role: .cancel) {}
            Button("Continue") {
                showFishTicketTallyCameraFlow = true
            }
        } message: {
            Text("Now take a picture of the tally sheet. This second OCR pass only reads tally rows, which reduces parsing errors.")
        }
        .alert("This ticket has already been recorded. Record anyway?", isPresented: $showDuplicateFishTicketWarning) {
            Button("Cancel", role: .cancel) {
                pendingDuplicateFishTicketDraft = nil
                fishTicketExtractionStatus = "Duplicate ticket was not recorded. The captured photo remains saved."
            }
            Button("Record Anyway") {
                guard let pendingDuplicateFishTicketDraft else { return }
                self.pendingDuplicateFishTicketDraft = nil
                applyFishTicketExtraction(pendingDuplicateFishTicketDraft)
            }
        }
        .sheet(item: $fishTicketReviewDraft) { draft in
            SmartFishTicketReviewSheet(draft: draft) { approvedDraft in
                requestFishTicketExtractionApply(approvedDraft)
            }
        }
        .sheet(item: $fishTicketTallyReviewDraft) { draft in
            SmartFishTicketTallyReviewSheet(draft: draft) { approvedDraft in
                applyFishTicketTallyExtraction(approvedDraft)
            }
        }
    }

    private var collapsedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(cardTitle)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        Spacer(minLength: 0)

                        Image(systemName: outcomeIconSystemName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(outcomeIconTint)
                            .rotationEffect(outcomeIconRotation)
                    }

                    HStack(spacing: 8) {
                        SmartCompactDeliveryField(label: "District", value: effectiveDistrict.rawValue)
                        SmartCompactDeliveryField(label: "Date", value: openingDateText)
                    }

                    HStack(alignment: .top, spacing: 8) {
                        SmartCompactDeliveryField(
                            label: "Opening",
                            value: collapsedOpeningPrimaryText,
                            secondaryValue: collapsedOpeningSecondaryText,
                            minHeight: 64
                        )
                        SmartCompactDeliveryField(
                            label: "Catch",
                            value: catchSummaryText,
                            minHeight: 64
                        )
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        if canDelete {
                            deleteDeliveryButton
                        }

                        Button("Expand") {
                            opening.isCollapsed = false
                        }
                        .smartLogbookSmallPillButtonStyle(fillColor: smartLogbookAccent)
                    }

                }
            }
        }
        .smartLogbookDeliveryCardStyle(compact: true)
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(cardTitle)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text(openingDateText)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text(effectiveDistrict.rawValue)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.70))
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    if canDelete {
                        deleteDeliveryButton
                    }

                    if opening.isRecordedDelivery {
                        Button {
                            opening.isCollapsed = true
                        } label: {
                            Text("Collapse")
                        }
                        .smartLogbookSmallSecondaryButtonStyle()
                    } else {
                        Button {
                            showClearWarning = true
                        } label: {
                            Text("Clear")
                        }
                        .smartLogbookSmallSecondaryButtonStyle()
                    }
                }
            }

            if showClearWarning {
                SmartInlineWarningCard(
                    text: "Clear all Fisherman Entry values, fish-ticket and QC-sheet photos, and tally rows for this Delivery?",
                    continueAction: {
                        showClearWarning = false
                        clearDeliveryEntryFields()
                    },
                    cancelAction: {
                        showClearWarning = false
                    }
                )
            }

            driftOpeningEditorCard

            fishingSetsCard

            fishTicketOCRCard

            VStack(alignment: .leading, spacing: 10) {
                Text("Fisherman Entry")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .underline(true, color: .white.opacity(0.50))
                    .frame(maxWidth: .infinity, alignment: .center)

                HStack(spacing: 8) {
                    SmartTextFieldBox(
                        title: nil,
                        text: catchBinding,
                        placeholder: "Sold Weight",
                        keyboardType: .numberPad,
                        highlighted: entryFieldsAreEmpty,
                        textColor: .white,
                        placeholderColor: .white.opacity(0.70)
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Catch to Date: \(SmartLogbookFormat.number(catchToDateDisplayedLbs)) lbs")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .smartLogbookInsetStyle()
                }

                HStack(spacing: 8) {
                    SmartTextFieldBox(
                        title: nil,
                        text: startDateCaughtBinding,
                        placeholder: "Start Date Caught",
                        keyboardType: .numbersAndPunctuation,
                        highlighted: entryFieldsAreEmpty,
                        textColor: .white,
                        placeholderColor: .white.opacity(0.70)
                    )

                    SmartTextFieldBox(
                        title: nil,
                        text: dateLandedBinding,
                        placeholder: "Date Landed",
                        keyboardType: .numbersAndPunctuation,
                        highlighted: entryFieldsAreEmpty,
                        textColor: .white,
                        placeholderColor: .white.opacity(0.70)
                    )
                }

                HStack(spacing: 8) {
                    SmartTextFieldBox(
                        title: nil,
                        text: timeOfLandingBinding,
                        placeholder: "Time of Landing",
                        keyboardType: .numbersAndPunctuation,
                        highlighted: entryFieldsAreEmpty,
                        textColor: .white,
                        placeholderColor: .white.opacity(0.70)
                    )

                    SmartTextFieldBox(
                        title: nil,
                        text: fishTempBinding,
                        placeholder: "Fish Temperature",
                        keyboardType: .decimalPad,
                        highlighted: entryFieldsAreEmpty,
                        textColor: .white,
                        placeholderColor: .white.opacity(0.70)
                    )
                }

                HStack(spacing: 8) {
                    SmartTextFieldBox(
                        title: nil,
                        text: deliveryTenderBinding,
                        placeholder: "Tender Name",
                        keyboardType: .default,
                        capitalization: .words,
                        highlighted: entryFieldsAreEmpty,
                        textColor: .white,
                        placeholderColor: .white.opacity(0.70)
                    )

                    SmartTextFieldBox(
                        title: nil,
                        text: chillTypeBinding,
                        placeholder: "Chill Type",
                        keyboardType: .default,
                        capitalization: .words,
                        highlighted: entryFieldsAreEmpty,
                        textColor: .white,
                        placeholderColor: .white.opacity(0.70)
                    )
                }

                if !opening.fishTicketTallyRows.isEmpty {
                    SmartFishTicketTallyTableCard(rows: opening.fishTicketTallyRows)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("How did it fish?")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.70))

                    HStack(spacing: 8) {
                        ForEach(SmartLogbookOutcome.allCases) { outcome in
                            Button {
                                opening.outcomeRawValue = outcome.rawValue
                            } label: {
                                Text(outcome.title)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .frame(minHeight: 28)
                                    .background(opening.outcome == outcome ? outcome.tint : Color.white.opacity(0.08))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(SatChartPressFeedbackButtonStyle())
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.70))

                    TextEditor(text: $opening.notes)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 96)
                        .padding(8)
                        .background(smartLogbookFieldBackground)
                        .foregroundColor(.white)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                }

                if !opening.isRecordedDelivery {
                    Button {
                        opening.isRecordedDelivery = true
                        opening.isCollapsed = true
                    } label: {
                        Text("Record Delivery to Log")
                    }
                    .smartLogbookPrimaryButtonStyle()
                }
            }
            .padding(10)
            .smartLogbookInsetStyle(highlighted: entryFieldsAreEmpty)

            VStack(alignment: .leading, spacing: 8) {
                Text("Smart Fields")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .underline(true, color: .white.opacity(0.50))
                    .frame(maxWidth: .infinity, alignment: .center)

                tidesSmartFieldCard


                VStack(spacing: 6) {
                    SmartMetricListRow(title: "Daily Harvest", value: dashboardSnapshot?.dailyHarvest ?? "—", dateTag: autoFieldDateTag, status: releaseStatus(for: dashboardSnapshot?.dailyHarvest, loading: isLoadingDashboard))
                    SmartMetricListRow(title: "Cumulative Harvest", value: dashboardSnapshot?.cumulativeHarvest ?? "—", dateTag: autoFieldDateTag, status: releaseStatus(for: dashboardSnapshot?.cumulativeHarvest, loading: isLoadingDashboard))
                    SmartMetricListRow(title: "Daily Escapement", value: dashboardSnapshot?.dailyEscapement ?? "—", dateTag: autoFieldDateTag, status: releaseStatus(for: dashboardSnapshot?.dailyEscapement, loading: isLoadingDashboard))
                    SmartMetricListRow(title: "Cumulative Escapement", value: dashboardSnapshot?.cumulativeEscapement ?? "—", dateTag: autoFieldDateTag, status: releaseStatus(for: dashboardSnapshot?.cumulativeEscapement, loading: isLoadingDashboard))
                    SmartMetricListRow(title: "Drift Permits", value: dashboardSnapshot?.driftPermits ?? "—", dateTag: autoFieldDateTag, status: releaseStatus(for: dashboardSnapshot?.driftPermits, loading: isLoadingDashboard))
                    SmartMetricListRow(title: "Drift Boats", value: dashboardSnapshot?.driftBoats ?? "—", dateTag: autoFieldDateTag, status: releaseStatus(for: dashboardSnapshot?.driftBoats, loading: isLoadingDashboard))
                    SmartMetricListRow(title: "Cloud / Sky", value: environmentSnapshot?.cloudText ?? "—", dateTag: autoFieldDateTag, status: releaseStatus(for: environmentSnapshot?.cloudText, loading: isLoadingEnvironment))
                    SmartMetricListRow(title: "Wind / Temp", value: environmentSnapshot?.windTempText ?? "—", dateTag: autoFieldDateTag, status: releaseStatus(for: environmentSnapshot?.windTempText, loading: isLoadingEnvironment))
                }
            }

            if hasPreviousOpening {
                Button(action: onCopyPreviousNotes) {
                    Label("Copy previous notes forward", systemImage: "arrow.down.doc")
                }
                .smartLogbookSmallSecondaryButtonStyle()
            }
        }
        .smartLogbookDeliveryCardStyle()
    }

    @MainActor
    private func ensureDriftOpeningDatesSeeded() {
        if driftOpeningFallbackStart > driftOpeningFallbackEnd {
            driftOpeningFallbackEnd = driftOpeningFallbackStart
        }

        let defaultDay = smartFieldReferenceDate

        if opening.driftOpeningStart == nil {
            if let dashboardStart = dashboardSnapshot?.driftOpeningStart {
                opening.driftOpeningStart = dashboardStart
                driftOpeningFallbackStart = dashboardStart
            } else {
                let seededStart = alignedDateKeepingTime(source: driftOpeningFallbackStart, toMatchDayOf: defaultDay)
                opening.driftOpeningStart = seededStart
                driftOpeningFallbackStart = seededStart
            }
        }
        if opening.driftOpeningEnd == nil {
            if let dashboardEnd = dashboardSnapshot?.driftOpeningEnd {
                opening.driftOpeningEnd = dashboardEnd
                driftOpeningFallbackEnd = dashboardEnd
            } else {
                let syncedEnd = alignedDateKeepingTime(source: driftOpeningFallbackEnd, toMatchDayOf: opening.driftOpeningStart ?? defaultDay)
                opening.driftOpeningEnd = syncedEnd
                driftOpeningFallbackEnd = syncedEnd
            }
        }

        if let savedStart = opening.driftOpeningStart {
            driftOpeningFallbackStart = savedStart
        }
        if let savedEnd = opening.driftOpeningEnd {
            driftOpeningFallbackEnd = savedEnd
        }
    }

    @MainActor
    private func confirmDriftOpeningSelection() {
        ensureDriftOpeningDatesSeeded()
        let range = normalizedDriftOpeningRange
        opening.driftOpeningStart = range.lowerBound
        opening.driftOpeningEnd = range.upperBound
        opening.isDriftOpeningConfirmed = true
    }

    @MainActor
    private func unlockDriftOpeningSelection() {
        ensureDriftOpeningDatesSeeded()
        opening.isDriftOpeningConfirmed = false
    }

    @MainActor
    private func handleStartDateCaughtChange(_ raw: String, shouldWarnOnMismatch: Bool) {
        opening.startDateCaughtText = raw

        guard let parsedDate = resolvedFishTicketStartDate(from: raw) else { return }

        let previousStart = opening.driftOpeningStart ?? dashboardSnapshot?.driftOpeningStart
        let didMismatchConfirmedOpening = opening.isDriftOpeningConfirmed
            && previousStart.map { !Calendar.current.isDate($0, inSameDayAs: parsedDate) } == true

        opening.openingDate = parsedDate
        opening.driftOpeningStart = parsedDate
        driftOpeningFallbackStart = parsedDate

        let updatedEnd = Calendar.current.date(byAdding: .hour, value: 6, to: parsedDate)
            ?? parsedDate.addingTimeInterval(6 * 60 * 60)
        opening.driftOpeningEnd = updatedEnd
        driftOpeningFallbackEnd = updatedEnd

        if shouldWarnOnMismatch && didMismatchConfirmedOpening {
            openingDateMismatchToastMessage = "Opening date entered does not match fish ticket.  Please check before recording delivery."
        }
    }

    @MainActor
    private func handleDateLandedChange(_ raw: String) {
        opening.dateLandedText = raw
    }

    private func resolvedFishTicketStartDate(from raw: String) -> Date? {
        guard let date = SmartLogbookParse.fishTicketDate(from: raw) else { return nil }
        guard let timeText = SmartLogbookParse.first24HourTimeString(in: raw) else { return date }

        let parts = timeText.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else {
            return date
        }

        var calendar = SmartLogbookFormat.alaskaCalendar
        calendar.timeZone = TimeZone(identifier: "America/Anchorage") ?? calendar.timeZone
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components) ?? date
    }

    @MainActor
    private func handleStatAreaChange(_ raw: String) {
        let cleaned = SmartLogbookParse.cleanedFishTicketValue(raw, for: .statArea)
        opening.statAreaText = cleaned

        if let resolution = BristolBayStatAreaResolver.resolve(cleaned) {
            opening.statAreaText = resolution.normalizedStatArea
            opening.statAreaSectionText = resolution.sectionName
            opening.openingDistrictKey = resolution.district.key
        } else {
            opening.statAreaSectionText = ""
            opening.openingDistrictKey = nil
        }
    }

    @MainActor
    private func maybeAutoLaunchSummaryCapture() {
        guard autoStartSummaryCapture else { return }
        guard !didAutoLaunchSummaryCapture else { return }
        guard !opening.didCaptureFishTicket else { return }
        didAutoLaunchSummaryCapture = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard !showFishTicketSummaryCamera else { return }
            showFishTicketSummaryCamera = true
        }
    }

    @MainActor
    private func maybeAutoLaunchTallyCapture() {
        guard autoStartTallyCapture else { return }
        guard !didAutoLaunchTallyCapture else { return }
        guard canCaptureFishTicketTally else { return }
        guard !opening.hasCapturedFishTicketTally else { return }
        didAutoLaunchTallyCapture = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard canCaptureFishTicketTally else { return }
            guard !showFishTicketTallyCameraFlow else { return }
            showFishTicketTallyCameraFlow = true
        }
    }

    @MainActor
    private func startQCSheetCapture(mode: QCSheetCaptureMode) {
        guard !isExtractingFishTicket, !isSavingQCSheet else { return }
        qcSheetCaptureMode = mode
        showQCSheetCamera = true
    }

    private func alignedDateKeepingTime(source: Date, toMatchDayOf targetDay: Date) -> Date {
        let calendar = Calendar.current
        let dayComponents = calendar.dateComponents([.year, .month, .day], from: targetDay)
        let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: source)

        var components = DateComponents()
        components.year = dayComponents.year
        components.month = dayComponents.month
        components.day = dayComponents.day
        components.hour = timeComponents.hour
        components.minute = timeComponents.minute
        components.second = timeComponents.second

        return calendar.date(from: components) ?? targetDay
    }

    @MainActor
    private func cancelFishTicketProcessing() {
        fishTicketProcessingGeneration = nil
        fishTicketProcessingTask?.cancel()
        fishTicketProcessingTask = nil
        isExtractingFishTicket = false
        releaseFishTicketOCRResources()
    }

    private func releaseFishTicketOCRResources() {
        SmartFishTicketStorage.clearMemoryCache()
        SmartLogbookImageRendering.clearCaches()
    }

    @MainActor
    private func beginFishTicketProcessing(
        status: String,
        operation: @escaping @MainActor (UUID) async -> Void
    ) {
        fishTicketProcessingGeneration = nil
        fishTicketProcessingTask?.cancel()

        let generation = UUID()
        fishTicketProcessingGeneration = generation
        fishTicketExtractionStatus = status
        isExtractingFishTicket = true

        fishTicketProcessingTask = Task(priority: .userInitiated) { @MainActor in
            defer {
                finishFishTicketProcessing(generation: generation)
            }
            await operation(generation)
        }
    }

    @MainActor
    private func finishFishTicketProcessing(generation: UUID) {
        guard fishTicketProcessingGeneration == generation else { return }
        fishTicketProcessingGeneration = nil
        fishTicketProcessingTask = nil
        isExtractingFishTicket = false
        releaseFishTicketOCRResources()
    }

    @MainActor
    private func handleFishTicketSummaryCapture(_ image: UIImage) {
        fishTicketReviewDraft = nil
        fishTicketTallyReviewDraft = nil

        let previousSummaryFilename = opening.fishTicketSummaryImageFilename
        let existingTallyFilenames = opening.fishTicketTallyImageFilenames
        let capturedImages = SmartFishTicketCapturedImageBatch([image])

        beginFishTicketProcessing(status: "Saving fish-ticket photo…") { generation in
            let savedFilename = await capturedImages.saveFirstAndRelease()
            guard !Task.isCancelled else { return }

            guard let savedFilename else {
                fishTicketExtractionStatus = "I couldn’t save the fish-ticket photo."
                return
            }

            if let previousSummaryFilename, previousSummaryFilename != savedFilename {
                SmartFishTicketStorage.deleteImage(named: previousSummaryFilename)
            }

            opening.fishTicketImageFilenames = [savedFilename] + existingTallyFilenames

            guard !Task.isCancelled else { return }
            guard let ocrImage = SmartFishTicketStorage.loadOCRImage(
                named: savedFilename,
                maxDimension: SmartFishTicketOCRProfile.summaryMaxDimension
            ) else {
                fishTicketExtractionStatus = "Saved the ticket photo, but couldn’t prepare it for OCR."
                fishTicketReviewDraft = makeFallbackSummaryReviewDraft(sourcePageIndex: 0)
                return
            }
            await performFishTicketSummaryExtraction(using: ocrImage, generation: generation)
        }
    }

    @MainActor
    private func handleFishTicketTallyCapture(_ image: UIImage) {
        fishTicketTallyReviewDraft = nil

        let previousTallyFilenames = opening.fishTicketTallyImageFilenames
        let summaryFilename = opening.fishTicketSummaryImageFilename
        let capturedImages = SmartFishTicketCapturedImageBatch([image])

        beginFishTicketProcessing(status: "Saving tally-sheet photo…") { generation in
            let savedFilename = await capturedImages.saveFirstAndRelease()
            guard !Task.isCancelled else { return }

            guard let savedFilename else {
                fishTicketExtractionStatus = "I couldn’t save the tally-sheet photo."
                return
            }

            for filename in previousTallyFilenames where filename != savedFilename {
                SmartFishTicketStorage.deleteImage(named: filename)
            }

            if let summaryFilename {
                opening.fishTicketImageFilenames = [summaryFilename, savedFilename]
            } else {
                opening.fishTicketImageFilenames = [savedFilename]
            }

            guard !Task.isCancelled else { return }
            await performFishTicketTallyExtraction(usingFilenames: [savedFilename], generation: generation)
        }
    }

    @MainActor
    private func handleQCSheetCapture(_ image: UIImage) {
        let captureMode = qcSheetCaptureMode
        let capturedImages = SmartFishTicketCapturedImageBatch([image])
        isSavingQCSheet = true
        qcSheetStatus = "Saving QC sheet photo…"

        Task { @MainActor in
            let savedFilename = await capturedImages.saveFirstAndRelease()
            defer { isSavingQCSheet = false }

            guard let savedFilename else {
                qcSheetStatus = "I couldn’t save the QC sheet photo."
                return
            }

            switch captureMode {
            case .append:
                opening.qcSheetImageFilenames.append(savedFilename)
            case .replaceLast:
                if let previousFilename = opening.qcSheetImageFilenames.last {
                    opening.qcSheetImageFilenames[opening.qcSheetImageFilenames.count - 1] = savedFilename
                    if previousFilename != savedFilename {
                        SmartFishTicketStorage.deleteImage(named: previousFilename)
                    }
                } else {
                    opening.qcSheetImageFilenames.append(savedFilename)
                }
            }

            qcSheetStatus = captureMode == .append
                ? "QC sheet photo added."
                : "QC sheet photo retaken."
        }
    }

    @MainActor
    private func startFishTicketSummaryReread() {
        guard !isExtractingFishTicket else { return }
        beginFishTicketProcessing(status: "Reading first-page fish ticket…") { generation in
            guard let filename = opening.fishTicketSummaryImageFilename,
                  let image = SmartFishTicketStorage.loadOCRImage(
                    named: filename,
                    maxDimension: SmartFishTicketOCRProfile.summaryMaxDimension
                  ) else {
                fishTicketExtractionStatus = "I couldn’t load the saved fish-ticket photo."
                return
            }
            await performFishTicketSummaryExtraction(using: image, generation: generation)
        }
    }

    @MainActor
    private func performFishTicketSummaryExtraction(using image: UIImage, generation: UUID) async {
        fishTicketReviewDraft = nil
        fishTicketExtractionStatus = "Reading first-page fish ticket…"

        do {
            let extractedDraft = try await SmartFishTicketExtractor.extract(from: [image])
            guard !Task.isCancelled, fishTicketProcessingGeneration == generation else { return }

            let reviewDraft = extractedDraft ?? makeFallbackSummaryReviewDraft(sourcePageIndex: 0)

            if extractedDraft?.hasAnyValue == true {
                fishTicketExtractionStatus = "Fish-ticket fields parsed. Review them before applying and unlocking the tally-sheet step."
            } else {
                fishTicketExtractionStatus = "I couldn’t confidently parse the fish-ticket fields. Review the page, correct anything needed, and apply when ready."
            }

            fishTicketReviewDraft = reviewDraft
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            SmartFishTicketOCRDiagnostics.failed(kind: "summary", error: error)
            fishTicketExtractionStatus = "Saved the ticket photo, but OCR failed. Review the page manually before applying."
            fishTicketReviewDraft = makeFallbackSummaryReviewDraft(
                sourcePageIndex: 0,
                additionalWarnings: ["OCR failed: \(error.localizedDescription)"]
            )
        }
    }

    @MainActor
    private func startFishTicketTallyReread() {
        guard !isExtractingFishTicket else { return }
        let filenames = opening.fishTicketTallyImageFilenames
        guard !filenames.isEmpty else { return }

        beginFishTicketProcessing(status: "Reading tally sheet…") { generation in
            await performFishTicketTallyExtraction(usingFilenames: filenames, generation: generation)
        }
    }

    @MainActor
    private func performFishTicketTallyExtraction(usingFilenames filenames: [String], generation: UUID) async {
        fishTicketTallyReviewDraft = nil
        fishTicketExtractionStatus = "Reading tally sheet…"

        do {
            let extractedTallyDraft = try await SmartFishTicketTallyExtractor.extract(
                fromImageFilenames: filenames,
                startingPageIndex: 1,
                expectedSummarySoldWeight: opening.totalCatchLbs
            )
            guard !Task.isCancelled, fishTicketProcessingGeneration == generation else { return }

            let tallyDraft = extractedTallyDraft ?? makeFallbackTallyReviewDraft(pageCount: filenames.count, startingPageIndex: 1)

            fishTicketExtractionStatus = tallyDraft.hasAnyRows
                ? "Found \(tallyDraft.rows.count) tally row(s). Review before applying."
                : "I couldn’t confidently isolate tally rows yet. Review the tally sheet page and add rows manually if needed."
            fishTicketTallyReviewDraft = tallyDraft
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            SmartFishTicketOCRDiagnostics.failed(kind: "tally", error: error)
            fishTicketExtractionStatus = "Saved the tally-sheet photo(s), but OCR failed. Review the tally-sheet page manually before applying."
            fishTicketTallyReviewDraft = makeFallbackTallyReviewDraft(
                pageCount: filenames.count,
                startingPageIndex: 1,
                additionalWarnings: ["OCR failed: \(error.localizedDescription)"]
            )
        }
    }

    @MainActor
    private func requestFishTicketExtractionApply(_ draft: SmartFishTicketExtractionDraft) {
        guard let soldWeightLbs = draft.postTareLbs else {
            applyFishTicketExtraction(draft)
            return
        }

        let isDuplicate = store.hasDuplicateDelivery(
            soldWeightLbs: soldWeightLbs,
            dateLandedText: draft.valueText(for: .dateLanded),
            timeOfLandingText: draft.valueText(for: .timeOfLanding),
            excludingOpeningID: opening.id
        )

        guard isDuplicate else {
            applyFishTicketExtraction(draft)
            return
        }

        pendingDuplicateFishTicketDraft = draft
        fishTicketExtractionStatus = "A delivery with the same pounds, landing date, and landing time already exists."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard pendingDuplicateFishTicketDraft != nil else { return }
            showDuplicateFishTicketWarning = true
        }
    }

    @MainActor
    private func applyFishTicketExtraction(_ draft: SmartFishTicketExtractionDraft) {
        opening.isRecordedDelivery = true

        if let soldWeight = draft.postTareLbs {
            opening.totalCatchLbs = soldWeight
        }

        let statArea = draft.valueText(for: .statArea)
        handleStatAreaChange(statArea)

        let startDateCaught = draft.valueText(for: .startDateCaught)
        if !startDateCaught.isEmpty {
            handleStartDateCaughtChange(startDateCaught, shouldWarnOnMismatch: true)
        }

        let dateLanded = draft.valueText(for: .dateLanded)
        if !dateLanded.isEmpty {
            handleDateLandedChange(dateLanded)
        }

        let timeOfLanding = draft.valueText(for: .timeOfLanding)
        if !timeOfLanding.isEmpty {
            opening.timeOfLandingText = timeOfLanding
        }

        let tenderName = draft.valueText(for: .tenderName)
        if !tenderName.isEmpty {
            opening.deliveryTender = tenderName
        }

        let chillType = draft.valueText(for: .chillType)
        if !chillType.isEmpty {
            opening.chillType = chillType
        }

        let temperature = draft.valueText(for: .temperature)
        if !temperature.isEmpty {
            opening.fishTempF = temperature
        }

        if opening.hasCapturedFishTicketTally {
            fishTicketExtractionStatus = "Updated the fish-ticket fields from the first page."
        } else {
            fishTicketExtractionStatus = "Fish-ticket fields autofilled from page 1. Capture the tally sheet next."
            if let onTicketApplied {
                onTicketApplied()
            } else {
                maybePromptForTallyCaptureAfterSummary()
            }
        }
    }

    @MainActor
    private func applyFishTicketTallyExtraction(_ draft: SmartFishTicketTallyExtractionDraft) {
        opening.fishTicketTallyRows = draft.rows.map { SmartLogbookParse.cleanedFishTicketTallyRow($0) }.filter(\.hasAnyValue)
        fishTicketExtractionStatus = opening.fishTicketTallyRows.isEmpty
            ? "Saved the tally-sheet photo(s), but no tally rows were applied."
            : "Applied \(opening.fishTicketTallyRows.count) tally row(s)."
        onTallyApplied?()
    }

    private func makeFallbackSummaryReviewDraft(
        sourcePageIndex: Int = 0,
        additionalWarnings: [String] = []
    ) -> SmartFishTicketExtractionDraft {
        var warnings = ["I couldn’t confidently parse the first-page fish-ticket fields from this photo. Review and edit the values before applying."]
        warnings.append(contentsOf: additionalWarnings)

        let values = SmartFishTicketField.allCases.map { field in
            SmartFishTicketExtractedValue(
                field: field,
                value: SmartLogbookParse.cleanedFishTicketValue(currentFishTicketValue(for: field), for: field),
                confidence: 0
            )
        }

        return SmartFishTicketExtractionDraft(
            values: values,
            sourcePageIndex: sourcePageIndex,
            matchedAnchorCount: 0,
            warnings: warnings
        )
    }

    private func makeCurrentSummaryReviewDraft() -> SmartFishTicketExtractionDraft {
        SmartFishTicketExtractionDraft(
            values: SmartFishTicketField.allCases.map { field in
                SmartFishTicketExtractedValue(
                    field: field,
                    value: SmartLogbookParse.cleanedFishTicketValue(currentFishTicketValue(for: field), for: field),
                    confidence: 1
                )
            },
            sourcePageIndex: 0,
            matchedAnchorCount: SmartFishTicketField.allCases.count,
            warnings: []
        )
    }

    private func makeFallbackTallyReviewDraft(
        pageCount: Int,
        startingPageIndex: Int = 1,
        additionalWarnings: [String] = []
    ) -> SmartFishTicketTallyExtractionDraft {
        var warnings = ["I couldn’t confidently isolate tally rows on this page. Review the tally sheet and add pick rows manually if needed."]
        warnings.append(contentsOf: additionalWarnings)

        return SmartFishTicketTallyExtractionDraft(
            rows: [],
            sourcePageIndexes: (0..<max(0, pageCount)).map { startingPageIndex + $0 },
            warnings: warnings
        )
    }

    private func makeCurrentTallyReviewDraft() -> SmartFishTicketTallyExtractionDraft {
        SmartFishTicketTallyExtractionDraft(
            rows: opening.fishTicketTallyRows,
            sourcePageIndexes: opening.hasCapturedFishTicketTally ? [1] : [],
            warnings: []
        )
    }

    @MainActor
    private func maybePromptForTallyCaptureAfterSummary() {
        guard opening.didCaptureFishTicket else { return }
        guard !opening.hasCapturedFishTicketTally else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard opening.didCaptureFishTicket else { return }
            guard !opening.hasCapturedFishTicketTally else { return }
            showFishTicketTallyCapturePrompt = true
        }
    }

    @MainActor
    private func clearDeliveryEntryFields() {
        opening.totalCatchLbs = nil
        opening.statAreaText = ""
        opening.statAreaSectionText = ""
        opening.openingDistrictKey = nil
        opening.startDateCaughtText = ""
        opening.dateLandedText = ""
        opening.timeOfLandingText = ""
        opening.fishTempF = ""
        opening.deliveryTender = ""
        opening.chillType = ""
        opening.fishTicketTallyRows = []
        opening.outcomeRawValue = nil
        opening.notes = ""
        openingDateMismatchToastMessage = nil
        deleteFishTicketPhotos()
        deleteQCSheetPhotos()
    }

    @MainActor
    private func deleteFishTicketPhotos() {
        cancelFishTicketProcessing()
        opening.fishTicketImageFilenames.forEach { SmartFishTicketStorage.deleteImage(named: $0) }
        opening.fishTicketImageFilenames = []
        fishTicketReviewDraft = nil
        fishTicketTallyReviewDraft = nil
        fishTicketExtractionStatus = nil
    }

    @MainActor
    private func deleteFishTicketTallyPhotos() {
        cancelFishTicketProcessing()
        opening.fishTicketTallyImageFilenames.forEach { SmartFishTicketStorage.deleteImage(named: $0) }
        opening.fishTicketImageFilenames = opening.fishTicketSummaryImageFilename.map { [$0] } ?? []
        fishTicketTallyReviewDraft = nil
        fishTicketExtractionStatus = nil
    }

    @MainActor
    private func deleteQCSheetPhotos() {
        opening.qcSheetImageFilenames.forEach { SmartFishTicketStorage.deleteImage(named: $0) }
        opening.qcSheetImageFilenames = []
        qcSheetStatus = nil
    }

}

private struct SmartInlineWarningCard: View {
    let text: String
    let continueAction: () -> Void
    let cancelAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Continue", action: continueAction)
                .buttonStyle(SatChartPressFeedbackButtonStyle())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(smartLogbookWarn.opacity(0.28))
                .clipShape(Capsule())

            Button("Cancel", action: cancelAction)
                .buttonStyle(SatChartPressFeedbackButtonStyle())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.10))
                .clipShape(Capsule())
        }
        .padding(10)
        .smartLogbookInsetStyle()
    }
}

private struct SmartCompactDeliveryField: View {
    let label: String
    let value: String
    var secondaryValue: String? = nil
    var minHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: secondaryValue == nil ? 2 : 4) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.58))

            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(secondaryValue == nil ? 1 : 2)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if let secondaryValue, !secondaryValue.isEmpty {
                Text(secondaryValue)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .padding(.horizontal, 10)
        .padding(.vertical, secondaryValue == nil ? 8 : 10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct LogbookLandingCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let badgeText: String?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 52, height: 52)

                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    if let badgeText, !badgeText.isEmpty {
                        Text(badgeText)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                Text(subtitle)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.70))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white.opacity(0.65))
        }
        .padding(14)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

private struct SmartFishingSetListEntry: Identifiable {
    let recordID: UUID
    let startedAt: Date
    let setNumber: Int

    var id: UUID {
        recordID
    }
}

private struct SmartFishingSetDeliveryOption: Identifiable, Equatable {
    let openingID: UUID?
    let title: String
    let subtitle: String?

    var id: String {
        openingID?.uuidString ?? "unassigned"
    }
}

private struct SmartFishingSetListRow: View {
    @Binding var set: SmartFishingSetRecord
    let deliveryOptions: [SmartFishingSetDeliveryOption]
    let onDelete: () -> Void

    @State private var isEditingOptionalEntry = false
    @State private var catchPoundsText = ""
    @State private var fishCountText = ""
    @State private var pickingMinutes = -1
    @State private var notesDraft = ""
    @State private var displayOnMapDraft = false
    @State private var selectedDeliveryOpeningID: UUID?
    @State private var isAssignmentLocked = false

    private var durationText: String {
        SmartFishingSetDetailRow.durationText(set.duration)
    }

    private var driftText: String {
        String(format: "%.2f mi", set.driftMiles)
    }

    private var pickText: String {
        guard let minutes = set.pickingMinutes else { return "—" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    private var catchText: String {
        let trimmed = set.catchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }

    private var assignmentOptions: [SmartFishingSetDeliveryOption] {
        guard !deliveryOptions.isEmpty else { return [] }
        return [SmartFishingSetDeliveryOption(openingID: nil, title: "Unassigned", subtitle: nil)] + deliveryOptions
    }

    private var assignmentButtonTitle: String {
        isAssignmentLocked ? "Edit" : "Save"
    }

    private var assignmentSaveDisabled: Bool {
        guard !deliveryOptions.isEmpty else { return true }
        if isAssignmentLocked { return false }
        return selectedDeliveryOpeningID == nil && set.assignedDeliveryOpeningID == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set \(set.setNumber)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("\(SmartLogbookFormat.dayTitle.string(from: set.startedAt)) • \(set.displayLocationLabel)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Toggle("Show Set", isOn: $set.displayOnNavPage)
                    .toggleStyle(.switch)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .tint(smartLogbookToggleBlue)
                    .labelsHidden()
                    .disabled(isEditingOptionalEntry)

                Text("Show Set")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.84))

                Button {
                    beginEditing()
                } label: {
                    Text("Edit")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .smartLogbookSmallPillButtonStyle(fillColor: Color.white.opacity(0.10))

                SatChartDeleteConfirmationButton(
                    confirmationTitle: "Delete Set \(set.setNumber)?",
                    confirmationMessage: "This permanently removes the set from the logbook."
                ) {
                    cancelEditChanges()
                    onDelete()
                } label: { isFlashingRed in
                    SatChartDeleteIcon(isFlashingRed: isFlashingRed, defaultColor: .white)
                        .font(.system(size: 12, weight: .bold))
                }
                .smartLogbookIconButtonStyle()
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                SmartFishingSetMetricPill(label: "Start", value: SmartLogbookFormat.dateTimeLine(set.startedAt))
                SmartFishingSetMetricPill(label: "End", value: SmartLogbookFormat.dateTimeLine(set.endedAt))
                SmartFishingSetMetricPill(label: "Duration", value: durationText)
                SmartFishingSetMetricPill(label: "Drift", value: driftText)
                SmartFishingSetMetricPill(label: "Pick Time", value: pickText)
                SmartFishingSetMetricPill(label: "Catch", value: catchText)
            }

            HStack(spacing: 6) {
                Text("Tide:")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.70))
                SmartFishingSetTideLabel(tide: set.startTide)
                Text("–")
                    .foregroundColor(.white.opacity(0.70))
                SmartFishingSetTideLabel(tide: set.endTide)
                Spacer(minLength: 0)
            }

            if set.startTide != nil {
                SmartFishingSetStationLine(snapshot: set.startTide)
            }

            let notes = set.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !notes.isEmpty && !isEditingOptionalEntry {
                Text(notes)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }

            assignmentSection

            if isEditingOptionalEntry {
                VStack(alignment: .leading, spacing: 10) {
                    CompletedSetOptionalEntrySection(
                        catchPoundsText: $catchPoundsText,
                        fishCountText: $fishCountText,
                        pickingMinutes: $pickingMinutes,
                        notes: $notesDraft
                    )

                    CompletedSetCollectedDataSection(set: set)

                    CompletedSetShowSetToggleRow(displayOnMap: $displayOnMapDraft)

                    CompletedSetActionRow(
                        onSave: saveEditChanges,
                        onCancel: cancelEditChanges
                    )
                }
                .padding(10)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .onAppear {
            syncAssignmentState()
        }
        .onChange(of: set.id) { _ in
            syncAssignmentState()
            if !isEditingOptionalEntry {
                syncEditorDraft()
            }
        }
    }

    private var assignmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Assign to Delivery")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.72))

            if assignmentOptions.isEmpty {
                HStack(spacing: 8) {
                    Text("No deliveries yet")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.68))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 34)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    Spacer(minLength: 0)

                    Button("Save") {}
                        .smartLogbookSmallPillButtonStyle(fillColor: Color.white.opacity(0.10))
                        .disabled(true)
                }
            } else {
                HStack(alignment: .center, spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(assignmentOptions) { option in
                                Button {
                                    guard !isAssignmentLocked else { return }
                                    selectedDeliveryOpeningID = option.openingID
                                } label: {
                                    VStack(spacing: 2) {
                                        Text(option.title)
                                            .font(.system(size: 11, weight: .bold, design: .rounded))
                                        if let subtitle = option.subtitle {
                                            Text(subtitle)
                                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                        }
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(option.openingID == selectedDeliveryOpeningID ? smartLogbookAccent : Color.white.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                                    )
                                    .opacity(isAssignmentLocked ? 0.82 : 1)
                                }
                                .buttonStyle(SatChartPressFeedbackButtonStyle())
                                .disabled(isAssignmentLocked)
                            }
                        }
                    }

                    Button(assignmentButtonTitle) {
                        handleAssignmentButtonTap()
                    }
                    .smartLogbookSmallPillButtonStyle(
                        fillColor: assignmentSaveDisabled && !isAssignmentLocked ? Color.white.opacity(0.10) : smartLogbookAccent
                    )
                    .disabled(assignmentSaveDisabled && !isAssignmentLocked)
                }
            }
        }
        .padding(.top, 2)
    }

    private func beginEditing() {
        syncEditorDraft()
        isEditingOptionalEntry = true
    }

    private func saveEditChanges() {
        var updatedSet = set
        updatedSet.catchText = MapView.formattedSetCatchText(
            poundsText: catchPoundsText,
            fishCountText: fishCountText
        )
        updatedSet.pickingMinutes = pickingMinutes >= 0 ? pickingMinutes : nil
        updatedSet.notes = notesDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedSet.displayOnNavPage = displayOnMapDraft
        set = updatedSet
        isEditingOptionalEntry = false
    }

    private func cancelEditChanges() {
        syncEditorDraft()
        isEditingOptionalEntry = false
    }

    private func handleAssignmentButtonTap() {
        if isAssignmentLocked {
            isAssignmentLocked = false
            return
        }

        var updatedSet = set
        updatedSet.assignedDeliveryOpeningID = selectedDeliveryOpeningID
        set = updatedSet
        isAssignmentLocked = updatedSet.assignedDeliveryOpeningID != nil
    }

    private func syncAssignmentState() {
        selectedDeliveryOpeningID = set.assignedDeliveryOpeningID
        isAssignmentLocked = set.assignedDeliveryOpeningID != nil
    }

    private func syncEditorDraft() {
        let parsedCatch = Self.parseCatchText(set.catchText)
        catchPoundsText = parsedCatch.poundsText
        fishCountText = parsedCatch.fishCountText
        pickingMinutes = set.pickingMinutes ?? -1
        notesDraft = set.notes
        displayOnMapDraft = set.displayOnNavPage
    }

    private static func parseCatchText(_ catchText: String) -> (poundsText: String, fishCountText: String) {
        let raw = catchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return ("", "") }

        let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let poundsPattern = #"(\d+(?:\.\d+)?)\s*lbs"#
        let fishPattern = #"(\d+)\s*fish"#
        let poundsText = firstRegexCapture(pattern: poundsPattern, in: raw, nsRange: nsRange) ?? ""
        let fishCountText = firstRegexCapture(pattern: fishPattern, in: raw, nsRange: nsRange) ?? ""
        return (poundsText, fishCountText)
    }

    private static func firstRegexCapture(pattern: String, in raw: String, nsRange: NSRange) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        guard let match = regex.firstMatch(in: raw, options: [], range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: raw) else {
            return nil
        }
        return String(raw[range])
    }
}


private struct SmartDeliverySummaryRow: View {
    @Binding var opening: SmartLogbookOpening
    let entryIndex: Int
    let seasonBaseDistrict: District
    let priorCatchLbs: Int
    let editDestination: AnyView
    let onDelete: () -> Void

    @State private var isShowingFlagNotes = false
    @State private var flagNotesDraft = ""

    private var effectiveDistrict: District {
        opening.openingDistrict ?? seasonBaseDistrict
    }

    private var openingDateText: String {
        let landed = opening.dateLandedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !landed.isEmpty { return landed }
        let trimmedStartDate = opening.startDateCaughtText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedStartDate.isEmpty ? SmartLogbookFormat.dayMonth.string(from: opening.openingDate) : trimmedStartDate
    }

    private var catchText: String {
        guard let totalCatchLbs = opening.totalCatchLbs else { return "—" }
        return "\(SmartLogbookFormat.number(totalCatchLbs)) lb"
    }

    private var catchToDateText: String {
        SmartLogbookFormat.number(priorCatchLbs + (opening.totalCatchLbs ?? 0))
    }

    private var fishTicketStatusText: String {
        if opening.hasCapturedFishTicketTally { return "Ticket+Tally" }
        if opening.didCaptureFishTicket { return "Ticket captured" }
        return "No ticket"
    }

    private var deliveryConditionText: String {
        var seen: Set<String> = []
        let conditions = opening.fishTicketTallyRows.compactMap { row -> String? in
            let condition = row.deliveryConditionText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !condition.isEmpty else { return nil }
            let comparisonKey = condition.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(comparisonKey).inserted else { return nil }
            return condition
        }
        return conditions.isEmpty ? "—" : conditions.joined(separator: " • ")
    }

    private var fishTemperatureText: String {
        let temperature = opening.fishTempF.trimmingCharacters(in: .whitespacesAndNewlines)
        return temperature.isEmpty ? "—" : temperature
    }

    private var statAreaResolution: BristolBayStatAreaResolution? {
        BristolBayStatAreaResolver.resolve(opening.statAreaText)
    }

    private var statAreaText: String {
        let trimmed = opening.statAreaText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "—" : trimmed
    }

    private var districtFishedText: String {
        statAreaResolution?.district.rawValue ?? "—"
    }

    private var recordedStatusText: String {
        opening.isRecordedDelivery ? "Recorded" : "Draft"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                NavigationLink {
                    editDestination
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Delivery Record \(entryIndex + 1)")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        Text("\(openingDateText) • \(effectiveDistrict.rawValue)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.70))
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(SatChartPressFeedbackButtonStyle())

                Button {
                    beginFlagNotesEditing()
                } label: {
                    Image(systemName: opening.flagNotes == nil ? "flag" : "flag.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(opening.flagNotes == nil ? Color.white : Color.red)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SatChartPressFeedbackButtonStyle())
                .accessibilityLabel(opening.flagNotes == nil ? "Flag delivery" : "Edit flagged delivery notes")
                .popover(isPresented: $isShowingFlagNotes, arrowEdge: .top) {
                    SmartDeliveryFlagNotesPopover(
                        notes: $flagNotesDraft,
                        onSave: saveFlagNotes,
                        onDelete: deleteFlagNotes
                    )
                    .presentationCompactAdaptation(.popover)
                }

                NavigationLink {
                    editDestination
                } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white.opacity(0.65))
                            .frame(width: 30, height: 34)
                }
                .buttonStyle(SatChartPressFeedbackButtonStyle())
            }

            NavigationLink {
                editDestination
            } label: {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        SmartCompactDeliveryField(label: "Sold Weight", value: catchText)
                        SmartCompactDeliveryField(label: "Stat Area", value: statAreaText)
                        SmartCompactDeliveryField(label: "District Fished", value: districtFishedText)
                        SmartCompactDeliveryField(label: "Delivery Condition", value: deliveryConditionText)
                        SmartCompactDeliveryField(label: "Fish Temperature", value: fishTemperatureText)
                        SmartCompactDeliveryField(label: "OCR", value: fishTicketStatusText)
                    }
            }
            .buttonStyle(SatChartPressFeedbackButtonStyle())

            HStack(spacing: 8) {
                SmartDeliveryStatusPill(text: recordedStatusText, isHighlighted: opening.isRecordedDelivery)
                SmartDeliveryStatusPill(text: fishTicketStatusText, isHighlighted: opening.didCaptureFishTicket)

                Spacer(minLength: 0)

                SatChartDeleteConfirmationButton(
                    confirmationTitle: "Delete Delivery Record \(entryIndex + 1)?",
                    confirmationMessage: "This permanently deletes the delivery log.",
                    onConfirm: onDelete
                ) { isFlashingRed in
                    SatChartDeleteIcon(isFlashingRed: isFlashingRed, defaultColor: .white)
                        .font(.system(size: 12, weight: .bold))
                }
                .smartLogbookIconButtonStyle()
                .accessibilityLabel("Delete Delivery Record \(entryIndex + 1)")

                NavigationLink {
                    editDestination
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .smartLogbookSmallPillButtonStyle(fillColor: smartLogbookAccent)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func beginFlagNotesEditing() {
        flagNotesDraft = opening.flagNotes ?? ""
        if opening.flagNotes == nil {
            opening.flagNotes = ""
        }
        isShowingFlagNotes = true
    }

    private func saveFlagNotes() {
        opening.flagNotes = flagNotesDraft
        isShowingFlagNotes = false
    }

    private func deleteFlagNotes() {
        opening.flagNotes = nil
        flagNotesDraft = ""
        isShowingFlagNotes = false
    }
}

private struct SmartDeliveryFlagNotesPopover: View {
    @Binding var notes: String
    let onSave: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $notes)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .tint(.white)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )

                if notes.isEmpty {
                    Text("Add Notes")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 150)

            HStack(spacing: 10) {
                Button("Save", action: onSave)
                    .smartLogbookSmallPillButtonStyle(fillColor: smartLogbookAccent)

                Button("Delete", action: onDelete)
                    .smartLogbookSmallPillButtonStyle(fillColor: smartLogbookBad)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .frame(width: 310)
        .background(smartLogbookBackgroundBottom)
        .environment(\.colorScheme, .dark)
    }
}

private struct SmartDeliveryStatusPill: View {
    let text: String
    let isHighlighted: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isHighlighted ? smartLogbookGood.opacity(0.72) : Color.white.opacity(0.10))
            .clipShape(Capsule())
    }
}


private struct SmartFishingSetDetailRow: View {
    @Binding var set: SmartFishingSetRecord

    private var durationText: String {
        Self.durationText(set.duration)
    }

    private var driftText: String {
        String(format: "%.2f mi", set.driftMiles)
    }

    private var pickingText: String {
        guard let minutes = set.pickingMinutes else { return "—" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set \(set.setNumber)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("\(SmartLogbookFormat.dayTitle.string(from: set.startedAt)) • \(set.displayLocationLabel)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.70))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                displayToggle
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                SmartFishingSetMetricPill(label: "Start", value: SmartLogbookFormat.dateTimeLine(set.startedAt))
                SmartFishingSetMetricPill(label: "End", value: SmartLogbookFormat.dateTimeLine(set.endedAt))
                SmartFishingSetMetricPill(label: "Duration", value: durationText)
                SmartFishingSetMetricPill(label: "Drift", value: driftText)
                SmartFishingSetMetricPill(label: "Pick Time", value: pickingText)
                SmartFishingSetMetricPill(label: "Catch", value: set.catchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "—" : set.catchText)
            }

            HStack(spacing: 6) {
                Text("Tide:")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.70))
                SmartFishingSetTideLabel(tide: set.startTide)
                Text("–")
                    .foregroundColor(.white.opacity(0.70))
                SmartFishingSetTideLabel(tide: set.endTide)
                Spacer(minLength: 0)
            }

            if set.startTide != nil {
                SmartFishingSetStationLine(snapshot: set.startTide)
            }

            let notes = set.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !notes.isEmpty {
                Text(notes)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var displayToggle: some View {
        HStack(spacing: 6) {
            Text("Show Set")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.68))

            Toggle("Show Set", isOn: $set.displayOnNavPage)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(smartLogbookToggleBlue)
        }
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        if totalSeconds < 60 { return "\(totalSeconds)s" }
        let minutes = totalSeconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainderMinutes = minutes % 60
        return remainderMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainderMinutes)m"
    }
}

private struct SmartFishingSetMetricPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.58))
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct SmartFishingSetTideLabel: View {
    let tide: SmartFishingSetTideSnapshot?

    var body: some View {
        HStack(spacing: 3) {
            Text(tide?.heightFeet.map { String(format: "%.1f ft", $0) } ?? "— ft")
                .font(.system(size: 11, weight: .bold, design: .rounded))
            Image(systemName: (tide?.state ?? .unknown).arrowSystemName)
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundColor(.white)
    }
}

private struct SmartFishingSetStationLine: View {
    let snapshot: SmartFishingSetTideSnapshot?

    var body: some View {
        if let stationText = stationText {
            Text(stationText)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stationText: String? {
        guard let snapshot,
              let stationName = normalized(snapshot.stationName) else {
            return nil
        }

        if let distance = snapshot.stationDistanceMiles {
            return "Station: \(stationName) • \(String(format: "%.1f", distance)) mi from start"
        }

        return "Station: \(stationName)"
    }

    private func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct BristolBayStatAreaResolution: Equatable {
    let normalizedStatArea: String
    let compactStatArea: String
    let district: District
    let sectionName: String
}

private enum BristolBayStatAreaResolver {
    private struct Entry {
        let district: District
        let sectionName: String
    }

    private static let entries: [String: Entry] = [
        "32100": Entry(district: .ugashik, sectionName: "Ugashik District"),
        "32105": Entry(district: .ugashik, sectionName: "URSHA Drift"),
        "32110": Entry(district: .ugashik, sectionName: "Ugashik"),
        "32120": Entry(district: .ugashik, sectionName: "Ugashik"),
        "32130": Entry(district: .ugashik, sectionName: "Ugashik"),
        "32140": Entry(district: .ugashik, sectionName: "Ugashik"),
        "32150": Entry(district: .ugashik, sectionName: "Ugashik"),
        "32160": Entry(district: .ugashik, sectionName: "Ugashik"),
        "32170": Entry(district: .ugashik, sectionName: "Ugashik"),
        "32180": Entry(district: .ugashik, sectionName: "URSHA Set"),
        "32200": Entry(district: .egegik, sectionName: "Egegik District / ERSHA Drift"),
        "32210": Entry(district: .egegik, sectionName: "Egegik"),
        "32220": Entry(district: .egegik, sectionName: "Egegik"),
        "32230": Entry(district: .egegik, sectionName: "Egegik"),
        "32240": Entry(district: .egegik, sectionName: "Egegik"),
        "32250": Entry(district: .egegik, sectionName: "Egegik"),
        "32260": Entry(district: .egegik, sectionName: "Egegik"),
        "32270": Entry(district: .egegik, sectionName: "Egegik"),
        "32400": Entry(district: .naknekKvichak, sectionName: "Naknek-Kvichak District Drift"),
        "32411": Entry(district: .naknekKvichak, sectionName: "Naknek-Kvichak"),
        "32412": Entry(district: .naknekKvichak, sectionName: "Naknek-Kvichak"),
        "32413": Entry(district: .naknekKvichak, sectionName: "Naknek-Kvichak"),
        "32416": Entry(district: .naknekKvichak, sectionName: "ARSHA Drift"),
        "32417": Entry(district: .naknekKvichak, sectionName: "ARSHA Set"),
        "32418": Entry(district: .naknekKvichak, sectionName: "KRSHA Drift"),
        "32419": Entry(district: .naknekKvichak, sectionName: "KRSHA Set"),
        "32421": Entry(district: .naknekKvichak, sectionName: "Naknek-Kvichak"),
        "32422": Entry(district: .naknekKvichak, sectionName: "Naknek-Kvichak"),
        "32423": Entry(district: .naknekKvichak, sectionName: "Naknek-Kvichak"),
        "32425": Entry(district: .naknekKvichak, sectionName: "NRSHA Drift"),
        "32426": Entry(district: .naknekKvichak, sectionName: "NRSHA Set"),
        "32500": Entry(district: .nushagak, sectionName: "Nushagak District"),
        "32510": Entry(district: .nushagak, sectionName: "Igushik Section"),
        "32511": Entry(district: .nushagak, sectionName: "Igushik Section"),
        "32520": Entry(district: .nushagak, sectionName: "Snake Section"),
        "32521": Entry(district: .nushagak, sectionName: "Snake River Section"),
        "32530": Entry(district: .nushagak, sectionName: "Nushagak Section"),
        "32531": Entry(district: .nushagak, sectionName: "Nushagak Section"),
        "32532": Entry(district: .nushagak, sectionName: "Nushagak Section"),
        "32533": Entry(district: .nushagak, sectionName: "Nushagak Section"),
        "32534": Entry(district: .nushagak, sectionName: "Nushagak Section"),
        "32535": Entry(district: .nushagak, sectionName: "Nushagak Section"),
        "32540": Entry(district: .nushagak, sectionName: "WRSHA Drift"),
        "32541": Entry(district: .nushagak, sectionName: "WRSHA Set"),
        "32610": Entry(district: .togiak, sectionName: "Kulukak Section"),
        "32611": Entry(district: .togiak, sectionName: "Kulukak Inshore"),
        "32620": Entry(district: .togiak, sectionName: "Matogak Section"),
        "32621": Entry(district: .togiak, sectionName: "Matogak Inshore"),
        "32630": Entry(district: .togiak, sectionName: "Osviak Section"),
        "32631": Entry(district: .togiak, sectionName: "Osviak Inshore"),
        "32640": Entry(district: .togiak, sectionName: "Cape Peirce Section"),
        "32641": Entry(district: .togiak, sectionName: "Cape Peirce Inshore"),
        "32670": Entry(district: .togiak, sectionName: "Togiak Bay Section"),
        "32671": Entry(district: .togiak, sectionName: "Togiak River Section Inshore Eastside"),
        "32672": Entry(district: .togiak, sectionName: "Togiak River Section Inshore Westside")
    ]

    private static let labelPhrases = [
        "stat area",
        "stat. area",
        "statistical area",
        "stat area fished",
        "area fished",
        "fishing area",
        "district/stat area",
        "district / stat area"
    ]

    static var customWords: [String] {
        let areaCodes = entries.keys.flatMap { code -> [String] in
            let prefix = String(code.prefix(3))
            let suffix = String(code.suffix(2))
            return [code, "\(prefix)-\(suffix)", "\(prefix) \(suffix)", "\(prefix).\(suffix)"]
        }

        return [
            "STAT",
            "AREA",
            "STATISTICAL",
            "FISHED",
            "DISTRICT",
            "UGASHIK",
            "EGEGIK",
            "NAKNEK",
            "KVICHAK",
            "NUSHAGAK",
            "TOGIAK"
        ] + areaCodes
    }

    static func resolve(_ raw: String) -> BristolBayStatAreaResolution? {
        candidateResolutions(in: raw).first?.resolution
    }

    static func candidateResolutions(in raw: String) -> [(resolution: BristolBayStatAreaResolution, score: Int)] {
        let cleanedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedRaw.isEmpty else { return [] }

        let lines = cleanedRaw.components(separatedBy: .newlines)
        var ranked: [String: (resolution: BristolBayStatAreaResolution, score: Int)] = [:]

        for (lineIndex, line) in lines.enumerated() {
            let contexts = [lineIndex - 1, lineIndex, lineIndex + 1]
                .filter { lines.indices.contains($0) }
                .map { lines[$0] }
                .joined(separator: " ")
                .lowercased()

            let labelScore = labelPhrases.contains(where: contexts.contains) ? 100 : 10
            let lineMatches = compactCodes(in: line)

            for (matchIndex, compactCode) in lineMatches.enumerated() {
                guard let entry = entries[compactCode] else { continue }
                let normalized = normalizedDisplayCode(for: compactCode)
                let resolution = BristolBayStatAreaResolution(
                    normalizedStatArea: normalized,
                    compactStatArea: compactCode,
                    district: entry.district,
                    sectionName: entry.sectionName
                )
                let score = labelScore + max(0, 12 - (matchIndex * 2))
                if let current = ranked[compactCode] {
                    if score > current.score {
                        ranked[compactCode] = (resolution, score)
                    }
                } else {
                    ranked[compactCode] = (resolution, score)
                }
            }
        }

        if ranked.isEmpty {
            for compactCode in compactCodes(in: cleanedRaw) {
                guard let entry = entries[compactCode] else { continue }
                let normalized = normalizedDisplayCode(for: compactCode)
                ranked[compactCode] = (
                    BristolBayStatAreaResolution(
                        normalizedStatArea: normalized,
                        compactStatArea: compactCode,
                        district: entry.district,
                        sectionName: entry.sectionName
                    ),
                    5
                )
            }
        }

        return ranked.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.resolution.compactStatArea < $1.resolution.compactStatArea
        }
    }

    private static func compactCodes(in raw: String) -> [String] {
        let normalizedRaw = SmartLogbookParse.normalizedNumericOCRSource(raw.uppercased())
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<!\d)(321|322|324|325|326)\s*[-.\s]?\s*(\d{2})(?!\d)"#,
            options: []
        ) else {
            return []
        }

        let nsRange = NSRange(normalizedRaw.startIndex..<normalizedRaw.endIndex, in: normalizedRaw)
        return regex.matches(in: normalizedRaw, options: [], range: nsRange).compactMap { match in
            guard
                match.numberOfRanges >= 3,
                let prefixRange = Range(match.range(at: 1), in: normalizedRaw),
                let suffixRange = Range(match.range(at: 2), in: normalizedRaw)
            else {
                return nil
            }

            let compact = String(normalizedRaw[prefixRange]) + String(normalizedRaw[suffixRange])
            return entries[compact] == nil ? nil : compact
        }
    }

    private static func normalizedDisplayCode(for compactCode: String) -> String {
        let prefix = compactCode.prefix(3)
        let suffix = compactCode.suffix(2)
        return "\(prefix)-\(suffix)"
    }
}

private enum SmartFishTicketField: String, CaseIterable, Identifiable {
    case postTare
    case statArea
    case startDateCaught
    case dateLanded
    case timeOfLanding
    case tenderName
    case chillType
    case temperature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .postTare: return "Sold Weight"
        case .statArea: return "Stat Area"
        case .startDateCaught: return "Start Date Caught"
        case .dateLanded: return "Date Landed"
        case .timeOfLanding: return "Time of Landing"
        case .tenderName: return "Tender Name"
        case .chillType: return "Chill Type"
        case .temperature: return "Fish Temperature"
        }
    }

    var keyboardType: UIKeyboardType {
        switch self {
        case .postTare:
            return .numberPad
        case .statArea, .startDateCaught, .dateLanded, .timeOfLanding:
            return .numbersAndPunctuation
        case .temperature:
            return .decimalPad
        case .tenderName, .chillType:
            return .default
        }
    }

    var capitalization: TextInputAutocapitalization {
        switch self {
        case .tenderName, .chillType:
            return .words
        default:
            return .never
        }
    }
}

private struct SmartFishTicketExtractedValue: Identifiable {
    let field: SmartFishTicketField
    var value: String
    let confidence: Float

    var id: String { field.rawValue }

    func withValue(_ newValue: String) -> SmartFishTicketExtractedValue {
        SmartFishTicketExtractedValue(field: field, value: newValue, confidence: confidence)
    }
}

struct SmartFishTicketTallyRow: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var speciesText: String = ""
    var deliveryConditionText: String = ""
    var soldWeightText: String = ""
    var brailersText: String = ""

    var hasAnyValue: Bool {
        !speciesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !deliveryConditionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !soldWeightText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !brailersText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displaySpeciesText: String {
        let species = speciesText.trimmingCharacters(in: .whitespacesAndNewlines)
        let condition = deliveryConditionText.trimmingCharacters(in: .whitespacesAndNewlines)
        if species.isEmpty { return condition }
        if condition.isEmpty { return species }
        return "\(species) • \(condition)"
    }
}

private struct SmartFishTicketTallyExtractionDraft: Identifiable {
    let id = UUID()
    let rows: [SmartFishTicketTallyRow]
    let sourcePageIndexes: [Int]
    let warnings: [String]

    var hasAnyRows: Bool {
        rows.contains(where: \.hasAnyValue)
    }

    func withEditedRows(_ editedRows: [SmartFishTicketTallyRow]) -> SmartFishTicketTallyExtractionDraft {
        SmartFishTicketTallyExtractionDraft(
            rows: editedRows.map { SmartLogbookParse.cleanedFishTicketTallyRow($0) }.filter(\.hasAnyValue),
            sourcePageIndexes: sourcePageIndexes,
            warnings: warnings
        )
    }
}

private struct SmartFishTicketExtractionDraft: Identifiable {
    let id = UUID()
    let values: [SmartFishTicketExtractedValue]
    let sourcePageIndex: Int
    let matchedAnchorCount: Int
    let warnings: [String]

    func valueText(for field: SmartFishTicketField) -> String {
        values.first(where: { $0.field == field })?.value ?? ""
    }

    func confidence(for field: SmartFishTicketField) -> Float {
        values.first(where: { $0.field == field })?.confidence ?? 0
    }

    var postTareLbs: Int? {
        SmartLogbookParse.bestSoldWeightInteger(in: valueText(for: .postTare))
            ?? SmartLogbookParse.firstInteger(in: valueText(for: .postTare))
    }

    var statAreaResolution: BristolBayStatAreaResolution? {
        BristolBayStatAreaResolver.resolve(valueText(for: .statArea))
    }

    var hasAnyValue: Bool {
        values.contains { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func withEditedValues(_ editedValues: [SmartFishTicketField: String]) -> SmartFishTicketExtractionDraft {
        let mergedValues = SmartFishTicketField.allCases.map { field in
            let original = values.first(where: { $0.field == field })
            let edited = editedValues[field] ?? original?.value ?? ""
            return SmartFishTicketExtractedValue(
                field: field,
                value: SmartLogbookParse.cleanedFishTicketValue(edited, for: field),
                confidence: original?.confidence ?? 0
            )
        }

        return SmartFishTicketExtractionDraft(
            values: mergedValues,
            sourcePageIndex: sourcePageIndex,
            matchedAnchorCount: matchedAnchorCount,
            warnings: warnings
        )
    }
}

private struct SmartFishTicketReviewSheet: View {
    let draft: SmartFishTicketExtractionDraft
    let onApply: (SmartFishTicketExtractionDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editedValues: [SmartFishTicketField: String]

    init(
        draft: SmartFishTicketExtractionDraft,
        onApply: @escaping (SmartFishTicketExtractionDraft) -> Void
    ) {
        self.draft = draft
        self.onApply = onApply
        _editedValues = State(initialValue: Dictionary(uniqueKeysWithValues: SmartFishTicketField.allCases.map { field in
            (field, draft.valueText(for: field))
        }))
    }

    private var editedDraft: SmartFishTicketExtractionDraft {
        draft.withEditedValues(editedValues)
    }

    private var derivedResolution: BristolBayStatAreaResolution? {
        editedDraft.statAreaResolution
    }

    private var reviewWarnings: [String] {
        var warnings = draft.warnings
        let statArea = editedDraft.valueText(for: .statArea).trimmingCharacters(in: .whitespacesAndNewlines)
        if statArea.isEmpty {
            warnings.append("Stat Area was not detected. You can edit Stat Area before applying to populate District Fished and Section.")
        } else if derivedResolution == nil {
            warnings.append("District Fished and Section will stay blank until Stat Area matches a known Bristol Bay area. You can edit Stat Area before applying.")
        }
        var seen: Set<String> = []
        return warnings.filter { seen.insert($0).inserted }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Review Fish Ticket Fields")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)

                    Text("Review the parsed first-page fish-ticket fields before applying them. Applying this page unlocks the separate tally-sheet OCR step.")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)

                    if !draft.hasAnyValue {
                        Text("No first-page values were confidently detected yet. You can fill in the fields manually here or close the review and retake the fish-ticket photo.")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.80))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .background(smartLogbookFieldBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    ForEach(SmartFishTicketField.allCases) { field in
                        SmartFishTicketEditableReviewRow(
                            field: field,
                            value: Binding(
                                get: { editedValues[field] ?? "" },
                                set: { editedValues[field] = $0 }
                            ),
                            confidence: draft.confidence(for: field)
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Applied Delivery Fields")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                            SmartCompactDeliveryField(label: "Sold Weight", value: editedDraft.valueText(for: .postTare).isEmpty ? "—" : editedDraft.valueText(for: .postTare))
                            SmartCompactDeliveryField(label: "Stat Area", value: editedDraft.valueText(for: .statArea).isEmpty ? "—" : editedDraft.valueText(for: .statArea))
                            SmartCompactDeliveryField(label: "District Fished", value: derivedResolution?.district.rawValue ?? "—")
                            SmartCompactDeliveryField(label: "Section", value: derivedResolution?.sectionName ?? "—")
                            SmartCompactDeliveryField(label: "Start Date Caught", value: editedDraft.valueText(for: .startDateCaught).isEmpty ? "—" : editedDraft.valueText(for: .startDateCaught))
                            SmartCompactDeliveryField(label: "Date Landed", value: editedDraft.valueText(for: .dateLanded).isEmpty ? "—" : editedDraft.valueText(for: .dateLanded))
                            SmartCompactDeliveryField(label: "Time of Landing", value: editedDraft.valueText(for: .timeOfLanding).isEmpty ? "—" : editedDraft.valueText(for: .timeOfLanding))
                            SmartCompactDeliveryField(label: "Tender Name", value: editedDraft.valueText(for: .tenderName).isEmpty ? "—" : editedDraft.valueText(for: .tenderName))
                            SmartCompactDeliveryField(label: "Chill Type", value: editedDraft.valueText(for: .chillType).isEmpty ? "—" : editedDraft.valueText(for: .chillType))
                            SmartCompactDeliveryField(label: "Fish Temperature", value: editedDraft.valueText(for: .temperature).isEmpty ? "—" : editedDraft.valueText(for: .temperature))
                        }

                        if derivedResolution == nil {
                            Text("District Fished is shown as — until Stat Area matches a known Bristol Bay area.")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.78))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .background(smartLogbookFieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if !reviewWarnings.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Warnings")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)

                            ForEach(Array(reviewWarnings.enumerated()), id: \.offset) { entry in
                                Text("• \(entry.element)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.80))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(10)
                        .background(smartLogbookFieldBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(16)
            }
            .background(
                LinearGradient(
                    colors: [smartLogbookBackgroundTop, smartLogbookBackgroundBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        SatChartToolbarButtonLabel("Keep Photos Only")
                    }
                    .foregroundColor(.white)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onApply(editedDraft)
                        dismiss()
                    } label: {
                        SatChartToolbarButtonLabel("Apply")
                    }
                    .foregroundColor(.white)
                    .disabled(!editedDraft.hasAnyValue)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct SmartFishTicketEditableReviewRow: View {
    let field: SmartFishTicketField
    @Binding var value: String
    let confidence: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text(field.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.72))

                Spacer(minLength: 0)

                SmartFishTicketConfidenceBadge(confidence: confidence)
            }

            TextField("Not found", text: $value)
                .keyboardType(field.keyboardType)
                .textInputAutocapitalization(field.capitalization)
                .disableAutocorrection(true)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .tint(.white)
                .padding(.horizontal, 10)
                .frame(minHeight: 38)
                .background(smartLogbookFieldBackgroundSoft)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .padding(10)
        .background(smartLogbookFieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SmartFishTicketTallyReviewSheet: View {
    let draft: SmartFishTicketTallyExtractionDraft
    let onApply: (SmartFishTicketTallyExtractionDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editedRows: [SmartFishTicketTallyRow]

    init(
        draft: SmartFishTicketTallyExtractionDraft,
        onApply: @escaping (SmartFishTicketTallyExtractionDraft) -> Void
    ) {
        self.draft = draft
        self.onApply = onApply
        _editedRows = State(initialValue: draft.rows)
    }

    private var editedDraft: SmartFishTicketTallyExtractionDraft {
        draft.withEditedRows(editedRows)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Review Tally Sheet Fields")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)

                    Text("Review the parsed tally rows before applying them to the Delivery log. This review appears separately from the first-page fish-ticket review.")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)

                    if editedRows.isEmpty {
                        Text("No tally rows were detected yet.")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.74))
                    } else {
                        ForEach(editedRows.indices, id: \.self) { index in
                            SmartFishTicketTallyEditableRow(
                                pickNumber: index + 1,
                                row: $editedRows[index]
                            )
                        }
                    }

                    Button {
                        editedRows.append(SmartFishTicketTallyRow())
                    } label: {
                        Label("Add Pick Row", systemImage: "plus")
                    }
                    .smartLogbookSmallSecondaryButtonStyle()

                    if !draft.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Warnings")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)

                            ForEach(Array(draft.warnings.enumerated()), id: \.offset) { entry in
                                Text("• \(entry.element)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.80))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(10)
                        .background(smartLogbookFieldBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(16)
            }
            .background(
                LinearGradient(
                    colors: [smartLogbookBackgroundTop, smartLogbookBackgroundBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        SatChartToolbarButtonLabel("Keep Photos Only")
                    }
                    .foregroundColor(.white)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onApply(editedDraft)
                        dismiss()
                    } label: {
                        SatChartToolbarButtonLabel("Apply")
                    }
                    .foregroundColor(.white)
                    .disabled(!editedDraft.hasAnyRows)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private struct SmartFishTicketTallyEditableRow: View {
    let pickNumber: Int
    @Binding var row: SmartFishTicketTallyRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pick \(pickNumber)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.72))

            TextField("Species", text: $row.speciesText)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .tint(.white)
                .padding(.horizontal, 10)
                .frame(minHeight: 38)
                .background(smartLogbookFieldBackgroundSoft)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

            TextField("Del. Cond", text: $row.deliveryConditionText)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .tint(.white)
                .padding(.horizontal, 10)
                .frame(minHeight: 38)
                .background(smartLogbookFieldBackgroundSoft)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

            HStack(spacing: 8) {
                TextField("Post Tare", text: $row.soldWeightText)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .tint(.white)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 38)
                    .background(smartLogbookFieldBackgroundSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )

                TextField("Brailers", text: $row.brailersText)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .tint(.white)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 38)
                    .background(smartLogbookFieldBackgroundSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            }
        }
        .padding(10)
        .background(smartLogbookFieldBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SmartFishTicketTallyTableCard: View {
    let rows: [SmartFishTicketTallyRow]
    var onEdit: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Tally Sheet")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Spacer(minLength: 0)

                if let onEdit {
                    Button("Edit", action: onEdit)
                        .smartLogbookSmallPillButtonStyle(fillColor: smartLogbookAccent)
                }
            }

            ForEach(Array(rows.enumerated()), id: \.element.id) { entry in
                let row = entry.element
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Pick \(entry.offset + 1)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.68))

                        Spacer(minLength: 0)

                        Text(row.speciesText.isEmpty ? "Species —" : row.speciesText)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.trailing)
                    }

                    HStack(spacing: 8) {
                        tallyField("Del. Cond", value: row.deliveryConditionText)
                        tallyField("Post Tare", value: row.soldWeightText, trailing: true)
                        tallyField("Brailers", value: row.brailersText, trailing: true)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(smartLogbookFieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
            }
        }
        .padding(10)
        .smartLogbookInsetStyle()
    }

    private func tallyField(_ label: String, value: String, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.58))

            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }
}

private struct SmartFishTicketConfidenceBadge: View {

    let confidence: Float

    private var label: String {
        switch confidence {
        case 0.85...: return "High"
        case 0.55...: return "Med"
        case 0.01...: return "Low"
        default: return "—"
        }
    }

    private var tint: Color {
        switch confidence {
        case 0.85...: return smartLogbookGood
        case 0.55...: return smartLogbookWarn
        case 0.01...: return smartLogbookBad
        default: return Color.white.opacity(0.28)
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(tint.opacity(0.92))
            .clipShape(Capsule())
    }
}


private struct SmartFishTicketOCRLine {
    let text: String
    let boundingBox: CGRect
    let confidence: Float
}

private struct SmartFishTicketOCRToken {
    let text: String
    let boundingBox: CGRect
    let confidence: Float
}

private struct SmartFishTicketOCRRow {
    let text: String
    let normalizedText: String
    let boundingBox: CGRect
    let lines: [SmartFishTicketOCRLine]
    let tokens: [SmartFishTicketOCRToken]
}

private struct SmartFishTicketOCRPage {
    let pageIndex: Int
    let lines: [SmartFishTicketOCRLine]
    let tokens: [SmartFishTicketOCRToken]
    let rows: [SmartFishTicketOCRRow]
    let collapsedText: String
    let matchedAnchorCount: Int
    let pageScore: Int
    let isProbablyTallySheet: Bool
}

private enum SmartFishTicketOCRSupport {
    static func makeLinesAndTokens(
        from observations: [VNRecognizedTextObservation]
    ) -> (lines: [SmartFishTicketOCRLine], tokens: [SmartFishTicketOCRToken]) {
        var lines: [SmartFishTicketOCRLine] = []
        var tokens: [SmartFishTicketOCRToken] = []

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }

            let line = SmartFishTicketOCRLine(
                text: candidate.string,
                boundingBox: observation.boundingBox,
                confidence: candidate.confidence
            )
            lines.append(line)

            let tokenRanges = nonWhitespaceRanges(in: candidate.string)
            if tokenRanges.isEmpty {
                tokens.append(
                    SmartFishTicketOCRToken(
                        text: candidate.string,
                        boundingBox: observation.boundingBox,
                        confidence: candidate.confidence
                    )
                )
                continue
            }

            for range in tokenRanges {
                let tokenText = String(candidate.string[range])
                let tokenBox = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                tokens.append(
                    SmartFishTicketOCRToken(
                        text: tokenText,
                        boundingBox: tokenBox,
                        confidence: candidate.confidence
                    )
                )
            }
        }

        let sortedLines = lines.sorted {
            let yDelta = abs($0.boundingBox.midY - $1.boundingBox.midY)
            if yDelta > 0.018 {
                return $0.boundingBox.midY > $1.boundingBox.midY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }

        let sortedTokens = tokens.sorted {
            let yDelta = abs($0.boundingBox.midY - $1.boundingBox.midY)
            if yDelta > 0.018 {
                return $0.boundingBox.midY > $1.boundingBox.midY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }

        return (sortedLines, sortedTokens)
    }

    static func makeRows(
        lines: [SmartFishTicketOCRLine],
        tokens: [SmartFishTicketOCRToken]
    ) -> [SmartFishTicketOCRRow] {
        guard !lines.isEmpty else { return [] }

        var lineGroups: [[SmartFishTicketOCRLine]] = []

        for line in lines {
            if var currentGroup = lineGroups.last,
               let currentBox = unionBox(currentGroup.map(\.boundingBox)) {
                let tolerance = max(0.016, max(currentBox.height, line.boundingBox.height) * 0.85)
                if abs(line.boundingBox.midY - currentBox.midY) <= tolerance {
                    currentGroup.append(line)
                    lineGroups[lineGroups.count - 1] = currentGroup
                    continue
                }
            }
            lineGroups.append([line])
        }

        return lineGroups.compactMap { group in
            let sortedGroup = group.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            guard let rowBox = unionBox(sortedGroup.map(\.boundingBox)) else { return nil }

            let yTolerance = max(0.012, rowBox.height * 0.45)
            let rowTokens = tokens
                .filter { token in
                    token.boundingBox.midY >= rowBox.minY - yTolerance
                        && token.boundingBox.midY <= rowBox.maxY + yTolerance
                }
                .sorted { $0.boundingBox.minX < $1.boundingBox.minX }

            let text = SmartLogbookParse.collapsedWhitespace(sortedGroup.map(\.text).joined(separator: " "))
            guard !text.isEmpty else { return nil }

            return SmartFishTicketOCRRow(
                text: text,
                normalizedText: SmartLogbookParse.normalizedAnchor(text),
                boundingBox: rowBox,
                lines: sortedGroup,
                tokens: rowTokens
            )
        }
    }

    static func unionBox(_ rects: [CGRect]) -> CGRect? {
        guard var box = rects.first else { return nil }
        for rect in rects.dropFirst() {
            box = box.union(rect)
        }
        return box
    }

    static func containsAnyPhrase(_ normalizedText: String, phrases: [String]) -> Bool {
        phrases.contains { containsPhrase(normalizedText, phrase: $0) }
    }

    static func containsPhrase(_ normalizedText: String, phrase: String) -> Bool {
        let normalizedPhrase = SmartLogbookParse.normalizedAnchor(phrase)
        guard !normalizedPhrase.isEmpty else { return false }
        if normalizedText.contains(normalizedPhrase) {
            return true
        }

        let words = normalizedText.split(separator: " ").map(String.init)
        let phraseWords = normalizedPhrase.split(separator: " ").map(String.init)
        guard !words.isEmpty, !phraseWords.isEmpty, words.count >= phraseWords.count else {
            return false
        }

        for startIndex in 0...(words.count - phraseWords.count) {
            if Array(words[startIndex..<(startIndex + phraseWords.count)]) == phraseWords {
                return true
            }
        }
        return false
    }

    static func sliceText(
        in text: String,
        after anchorPhrases: [String],
        before stopPhrases: [String]
    ) -> String? {
        let words = tokenizedWords(in: text)
        let normalizedWords = words.map(\.normalized)
        guard let anchorRange = firstPhraseRange(in: normalizedWords, phrases: anchorPhrases) else {
            return nil
        }

        let stopRange = firstPhraseRange(
            in: normalizedWords,
            phrases: stopPhrases,
            startAt: anchorRange.upperBound
        )

        let endIndex = stopRange?.lowerBound ?? words.count
        guard anchorRange.upperBound < endIndex else { return nil }

        let candidate = words[anchorRange.upperBound..<endIndex].map(\.raw).joined(separator: " ")
        let collapsed = SmartLogbookParse.collapsedWhitespace(candidate)
        return collapsed.isEmpty ? nil : collapsed
    }

    static func textAfterPhrase(_ text: String, anchorPhrases: [String]) -> String? {
        sliceText(in: text, after: anchorPhrases, before: [])
    }

    private static func nonWhitespaceRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var currentStart: String.Index? = nil
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                if let start = currentStart {
                    ranges.append(start..<index)
                    currentStart = nil
                }
            } else if currentStart == nil {
                currentStart = index
            }
            index = text.index(after: index)
        }

        if let start = currentStart {
            ranges.append(start..<text.endIndex)
        }

        return ranges
    }

    private struct TokenizedWord {
        let raw: String
        let normalized: String
    }

    private static func tokenizedWords(in text: String) -> [TokenizedWord] {
        SmartLogbookParse.collapsedWhitespace(text)
            .split(separator: " ")
            .map { rawToken in
                let raw = String(rawToken)
                return TokenizedWord(raw: raw, normalized: SmartLogbookParse.normalizedAnchor(raw))
            }
    }

    private static func firstPhraseRange(
        in normalizedWords: [String],
        phrases: [String],
        startAt startIndex: Int = 0
    ) -> Range<Int>? {
        guard startIndex < normalizedWords.count else { return nil }

        var bestRange: Range<Int>? = nil
        for phrase in phrases {
            let phraseWords = SmartLogbookParse.normalizedAnchor(phrase)
                .split(separator: " ")
                .map(String.init)
            guard !phraseWords.isEmpty, normalizedWords.count >= phraseWords.count else { continue }

            for index in startIndex...(normalizedWords.count - phraseWords.count) {
                if Array(normalizedWords[index..<(index + phraseWords.count)]) == phraseWords {
                    let candidateRange = index..<(index + phraseWords.count)
                    if bestRange == nil || candidateRange.lowerBound < bestRange!.lowerBound {
                        bestRange = candidateRange
                    }
                    break
                }
            }
        }
        return bestRange
    }
}

private enum SmartFishTicketExtractorError: LocalizedError {
    case noImages
    case noRenderableImages

    var errorDescription: String? {
        switch self {
        case .noImages:
            return "No images were provided."
        case .noRenderableImages:
            return "The fish-ticket image could not be prepared for OCR."
        }
    }
}

private nonisolated enum SmartFishTicketOCRProfile {
    private static var hasLessThanFourGBMemory: Bool {
        ProcessInfo.processInfo.physicalMemory > 0
            && ProcessInfo.processInfo.physicalMemory <= 4 * 1024 * 1024 * 1024
    }

    private static var isBeforeIOS17: Bool {
        !ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 17, minorVersion: 0, patchVersion: 0)
        )
    }

    static var isConstrained: Bool {
        isBeforeIOS17 || hasLessThanFourGBMemory || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    static var storedImageMaxDimension: CGFloat {
        isConstrained ? 2200 : 2600
    }

    static var capturePreviewMaxDimension: CGFloat {
        isConstrained ? 2200 : 2600
    }

    static var summaryMaxDimension: CGFloat {
        isConstrained ? 2000 : 2400
    }

    static var tallyMaxDimension: CGFloat {
        isConstrained ? 2100 : 2600
    }

    static var includeBinaryVariants: Bool {
        !isConstrained
    }

    static var summaryVariantLimit: Int {
        isConstrained ? 2 : 3
    }

    static var tallyVariantLimit: Int {
        isConstrained ? 2 : 3
    }
}

private nonisolated enum SmartLogbookImageRendering {
    static let sharedCIContext = CIContext(options: [CIContextOption.useSoftwareRenderer: false])

    static func clearCaches() {
        sharedCIContext.clearCaches()
    }
}

private enum SmartFishTicketOCRDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SatChart",
        category: "FishTicketOCR"
    )

    static func started(kind: String, pageCount: Int) {
        let footprint = SmartFishTicketMemoryDiagnostics.physicalFootprintBytes ?? 0
        logger.info(
            "Started \(kind, privacy: .public) OCR for \(pageCount) page(s); thermalState=\(ProcessInfo.processInfo.thermalState.rawValue); footprintBytes=\(footprint)"
        )
    }

    static func completed(kind: String, pageCount: Int, startedAt: TimeInterval) {
        let duration = ProcessInfo.processInfo.systemUptime - startedAt
        logger.info(
            "Completed \(kind, privacy: .public) OCR for \(pageCount) page(s) in \(duration, format: .fixed(precision: 2)) seconds"
        )
    }

    static func failed(kind: String, error: Error) {
        logger.error(
            "\(kind, privacy: .public) OCR failed: \(error.localizedDescription, privacy: .public)"
        )
    }

    static func page(kind: String, pageIndex: Int, stage: String) {
        let footprint = SmartFishTicketMemoryDiagnostics.physicalFootprintBytes ?? 0
        logger.debug(
            "\(kind, privacy: .public) OCR page \(pageIndex, privacy: .public) \(stage, privacy: .public); footprintBytes=\(footprint)"
        )
    }

    static func tallyCandidate(
        pageIndex: Int,
        variant: String,
        headerAnchors: Int,
        rowCount: Int,
        unsupportedRows: Int,
        score: Int
    ) {
        logger.debug(
            "Tally candidate page=\(pageIndex, privacy: .public) variant=\(variant, privacy: .public) headerAnchors=\(headerAnchors, privacy: .public) rows=\(rowCount, privacy: .public) unsupportedRows=\(unsupportedRows, privacy: .public) score=\(score, privacy: .public)"
        )
    }
}

nonisolated enum SmartFishTicketMemoryDiagnostics {
    static var physicalFootprintBytes: UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    reboundPointer,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }
}

private nonisolated final class SmartFishTicketVisionCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var request: VNRequest?
    nonisolated(unsafe) private var cancelled = false

    nonisolated func install(_ request: VNRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else {
            request.cancel()
            return false
        }
        self.request = request
        return true
    }

    nonisolated func cancel() {
        lock.lock()
        cancelled = true
        let activeRequest = request
        lock.unlock()
        activeRequest?.cancel()
    }

    nonisolated func clear() {
        lock.lock()
        request = nil
        lock.unlock()
    }

    nonisolated var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private nonisolated enum SmartFishTicketOCRImageFactory {
    struct PreparedImage {
        let cgImage: CGImage
        let variantTag: String
    }

    static func normalizedImage(from image: UIImage, maxDimension: CGFloat) -> CGImage? {
        image.smartLogbookNormalizedCGImage(maxDimension: maxDimension)
    }

    static func variants(
        from image: UIImage,
        maxDimension: CGFloat,
        topLeftCropRect: CGRect? = nil,
        includeBinary: Bool = true,
        variantLimit: Int? = nil
    ) -> [PreparedImage] {
        guard let baseCGImage = image.smartLogbookNormalizedCGImage(
            maxDimension: maxDimension,
            topLeftCropRect: topLeftCropRect
        ) else {
            return []
        }

        return variants(from: baseCGImage, includeBinary: includeBinary, variantLimit: variantLimit)
    }

    static func variants(
        from cgImage: CGImage,
        includeBinary: Bool = true,
        includeSharpened: Bool = true,
        variantLimit: Int? = nil
    ) -> [PreparedImage] {
        if let variantLimit, variantLimit <= 0 {
            return []
        }

        let base = upscaledIfNeeded(cgImage)
        var results: [PreparedImage] = []
        var seenKeys: Set<String> = []

        func hasRoomForAnotherVariant() -> Bool {
            guard let variantLimit else { return true }
            return results.count < variantLimit
        }

        func append(_ prepared: PreparedImage) {
            guard hasRoomForAnotherVariant() else { return }
            let key = "\(prepared.variantTag)-\(prepared.cgImage.width)x\(prepared.cgImage.height)"
            guard seenKeys.insert(key).inserted else { return }
            results.append(prepared)
        }

        append(PreparedImage(cgImage: base, variantTag: "original"))

        if hasRoomForAnotherVariant(),
           let strongContrast = colorControlled(
            cgImage: base,
            saturation: 0,
            brightness: 0.02,
            contrast: 1.45
        ) {
            append(PreparedImage(cgImage: strongContrast, variantTag: "contrast"))
        }

        if hasRoomForAnotherVariant(),
           includeBinary,
           let binary = binarized(cgImage: base) {
            append(PreparedImage(cgImage: binary, variantTag: "binary"))
        }

        if hasRoomForAnotherVariant(),
           let mono = colorControlled(
            cgImage: base,
            saturation: 0,
            brightness: 0.01,
            contrast: 1.18
        ) {
            append(PreparedImage(cgImage: mono, variantTag: "mono"))
        }

        if hasRoomForAnotherVariant(),
           includeSharpened,
           let sharpened = sharpened(cgImage: base, sharpness: 0.55) {
            append(PreparedImage(cgImage: sharpened, variantTag: "sharpened"))
        }

        return results
    }

    static func variant(
        from cgImage: CGImage,
        includeBinary: Bool = true,
        includeSharpened: Bool = true,
        at index: Int
    ) -> PreparedImage? {
        guard index >= 0 else { return nil }
        let base = upscaledIfNeeded(cgImage)

        var builders: [(tag: String, makeImage: () -> CGImage?)] = [
            ("original", { base }),
            ("contrast", {
                colorControlled(
                    cgImage: base,
                    saturation: 0,
                    brightness: 0.02,
                    contrast: 1.45
                )
            })
        ]

        if includeBinary {
            builders.append(("binary", { binarized(cgImage: base) }))
        }

        builders.append(
            ("mono", {
                colorControlled(
                    cgImage: base,
                    saturation: 0,
                    brightness: 0.01,
                    contrast: 1.18
                )
            })
        )

        if includeSharpened {
            builders.append(("sharpened", { sharpened(cgImage: base, sharpness: 0.55) }))
        }

        guard builders.indices.contains(index), let image = builders[index].makeImage() else {
            return nil
        }
        return PreparedImage(cgImage: image, variantTag: builders[index].tag)
    }

    static func upscaledIfNeeded(_ cgImage: CGImage) -> CGImage {
        let maxSide = max(cgImage.width, cgImage.height)
        guard maxSide < 1500 else { return cgImage }

        let scale = min(3.0, 1800.0 / CGFloat(max(1, maxSide)))
        let targetWidth = max(1, Int((CGFloat(cgImage.width) * scale).rounded()))
        let targetHeight = max(1, Int((CGFloat(cgImage.height) * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return cgImage
        }

        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? cgImage
    }

    private static func colorControlled(
        cgImage: CGImage,
        saturation: CGFloat,
        brightness: CGFloat,
        contrast: CGFloat
    ) -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(saturation, forKey: kCIInputSaturationKey)
        filter.setValue(brightness, forKey: kCIInputBrightnessKey)
        filter.setValue(contrast, forKey: kCIInputContrastKey)

        guard let output = filter.outputImage else { return nil }
        let extent = output.extent.integral
        guard !extent.isEmpty else { return nil }
        return SmartLogbookImageRendering.sharedCIContext.createCGImage(output, from: extent)
    }

    private static func sharpened(
        cgImage: CGImage,
        sharpness: CGFloat
    ) -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CISharpenLuminance") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(sharpness, forKey: kCIInputSharpnessKey)

        guard let output = filter.outputImage else { return nil }
        let extent = output.extent.integral
        guard !extent.isEmpty else { return nil }
        return SmartLogbookImageRendering.sharedCIContext.createCGImage(output, from: extent)
    }

    private static func binarized(cgImage: CGImage) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width

        var grayscale = [UInt8](repeating: 0, count: width * height)
        guard let grayContext = CGContext(
            data: &grayscale,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        grayContext.interpolationQuality = .high
        grayContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let threshold = min(235, max(70, otsuThreshold(for: grayscale) + 6))
        var binary = [UInt8](repeating: 255, count: width * height)
        for index in binary.indices {
            binary[index] = grayscale[index] <= threshold ? 0 : 255
        }

        guard let context = CGContext(
            data: &binary,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .none
        return context.makeImage()
    }

    private static func otsuThreshold(for pixels: [UInt8]) -> Int {
        var histogram = [Int](repeating: 0, count: 256)
        for value in pixels {
            histogram[Int(value)] += 1
        }

        let totalCount = pixels.count
        guard totalCount > 0 else { return 170 }

        var sum = 0.0
        for index in 0..<256 {
            sum += Double(index * histogram[index])
        }

        var sumBackground = 0.0
        var weightBackground = 0.0
        var maximumVariance = 0.0
        var threshold = 170

        for index in 0..<256 {
            weightBackground += Double(histogram[index])
            if weightBackground == 0 { continue }

            let weightForeground = Double(totalCount) - weightBackground
            if weightForeground == 0 { break }

            sumBackground += Double(index * histogram[index])

            let meanBackground = sumBackground / weightBackground
            let meanForeground = (sum - sumBackground) / weightForeground
            let varianceBetween = weightBackground * weightForeground * pow(meanBackground - meanForeground, 2)

            if varianceBetween > maximumVariance {
                maximumVariance = varianceBetween
                threshold = index
            }
        }

        return threshold
    }
}


private enum SmartFishTicketExtractor {
    static func extract(from images: [UIImage]) async throws -> SmartFishTicketExtractionDraft? {
        guard !images.isEmpty else {
            throw SmartFishTicketExtractorError.noImages
        }

        guard let parsedPage = try await SmartFishTicketSandboxV3SummaryParser.parse(images: images) else {
            return nil
        }

        let summary = parsedPage.summary
        let values: [SmartFishTicketExtractedValue] = [
            SmartFishTicketExtractedValue(
                field: .postTare,
                value: summary.soldWeight.map(SmartLogbookFormat.number) ?? "",
                confidence: summary.soldWeight == nil ? 0 : 0.90
            ),
            SmartFishTicketExtractedValue(
                field: .statArea,
                value: summary.statArea ?? "",
                confidence: summary.statArea == nil ? 0 : 0.88
            ),
            SmartFishTicketExtractedValue(
                field: .startDateCaught,
                value: summary.startDateCaught ?? "",
                confidence: summary.startDateCaught == nil ? 0 : 0.86
            ),
            SmartFishTicketExtractedValue(
                field: .dateLanded,
                value: summary.dateLanded ?? "",
                confidence: summary.dateLanded == nil ? 0 : 0.86
            ),
            SmartFishTicketExtractedValue(
                field: .timeOfLanding,
                value: summary.timeOfLanding ?? "",
                confidence: summary.timeOfLanding == nil ? 0 : 0.84
            ),
            SmartFishTicketExtractedValue(
                field: .tenderName,
                value: summary.tenderName ?? "",
                confidence: summary.tenderName == nil ? 0 : 0.82
            ),
            SmartFishTicketExtractedValue(
                field: .chillType,
                value: summary.chillType ?? "",
                confidence: summary.chillType == nil ? 0 : 0.84
            ),
            SmartFishTicketExtractedValue(
                field: .temperature,
                value: summary.temperature ?? "",
                confidence: summary.temperature == nil ? 0 : 0.80
            )
        ]

        var warnings = parsedPage.warnings
        let missingFields = values
            .filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { $0.field.title }
        if !missingFields.isEmpty {
            warnings.append("These fields were not read confidently and should be reviewed: \(missingFields.joined(separator: ", ")).")
        }

        let draft = SmartFishTicketExtractionDraft(
            values: SmartFishTicketField.allCases.map { field in
                values.first(where: { $0.field == field }) ?? SmartFishTicketExtractedValue(field: field, value: "", confidence: 0)
            },
            sourcePageIndex: parsedPage.pageIndex,
            matchedAnchorCount: parsedPage.matchedAnchorCount,
            warnings: SmartFishTicketSandboxV3SummaryParser.deduplicatedWarnings(warnings)
        )

        return draft.hasAnyValue ? draft : nil
    }
}

private enum SmartFishTicketTallyExtractor {
    static func extract(
        from images: [UIImage],
        startingPageIndex: Int = 1,
        expectedSummarySoldWeight: Int? = nil
    ) async throws -> SmartFishTicketTallyExtractionDraft? {
        guard !images.isEmpty else {
            throw SmartFishTicketExtractorError.noImages
        }

        return try await SmartFishTicketSandboxV3TallyParser.parse(
            images: images,
            startingPageIndex: startingPageIndex,
            expectedSummarySoldWeight: expectedSummarySoldWeight
        )
    }

    static func extract(
        fromImageFilenames filenames: [String],
        startingPageIndex: Int = 1,
        expectedSummarySoldWeight: Int? = nil
    ) async throws -> SmartFishTicketTallyExtractionDraft? {
        guard !filenames.isEmpty else {
            throw SmartFishTicketExtractorError.noImages
        }

        return try await SmartFishTicketSandboxV3TallyParser.parse(
            imageFilenames: filenames,
            startingPageIndex: startingPageIndex,
            expectedSummarySoldWeight: expectedSummarySoldWeight
        )
    }
}

private nonisolated enum SmartFishTicketSandboxV3OCR {
    struct TextCandidate {
        let text: String
        let confidence: Float
    }

    struct RecognizedLine {
        let text: String
        let boundingBox: CGRect // top-left normalized coordinates
        let confidence: Float
    }

    struct RecognizedToken {
        let text: String
        let boundingBox: CGRect // top-left normalized coordinates
        let confidence: Float

        var minX: CGFloat { boundingBox.minX }
        var maxX: CGFloat { boundingBox.maxX }
        var topY: CGFloat { boundingBox.minY }
        var bottomY: CGFloat { boundingBox.maxY }
        var centerX: CGFloat { boundingBox.midX }
        var centerY: CGFloat { boundingBox.midY }
        var height: CGFloat { boundingBox.height }
    }

    struct RecognizedVariant {
        let text: String
        let lines: [RecognizedLine]
        let tokens: [RecognizedToken]
        let variantTag: String
        let cgImage: CGImage
    }

    private static let recognitionLanguages = ["en-US"]
    private static let recognitionQueue = DispatchQueue(
        label: "com.curraghfisheries.SatChart.fish-ticket-vision",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )

    static func recognizeVariants(
        from image: UIImage,
        cropRect: CGRect?,
        minimumTextHeight: Float,
        maxDimension: CGFloat,
        customWords: [String],
        includeBinary: Bool = true,
        variantLimit: Int? = nil
    ) async throws -> [RecognizedVariant] {
        try Task.checkCancellation()
        let preparedVariants = SmartFishTicketOCRImageFactory.variants(
            from: image,
            maxDimension: maxDimension,
            topLeftCropRect: cropRect,
            includeBinary: includeBinary,
            variantLimit: variantLimit
        )
        try Task.checkCancellation()

        var recognizedVariants: [RecognizedVariant] = []
        recognizedVariants.reserveCapacity(preparedVariants.count)

        for prepared in preparedVariants {
            try Task.checkCancellation()
            let recognized = try await recognize(
                cgImage: prepared.cgImage,
                minimumTextHeight: minimumTextHeight,
                customWords: customWords
            )
            try Task.checkCancellation()
            recognizedVariants.append(
                RecognizedVariant(
                    text: recognized.text,
                    lines: recognized.lines,
                    tokens: recognized.tokens,
                    variantTag: prepared.variantTag,
                    cgImage: prepared.cgImage
                )
            )
        }

        return recognizedVariants
    }

    static func recognizeVariants(
        from normalizedImage: CGImage,
        cropRect: CGRect?,
        minimumTextHeight: Float,
        customWords: [String],
        includeBinary: Bool = true,
        variantLimit: Int? = nil,
        variantStartIndex: Int = 0,
        recognitionLimit: Int? = nil
    ) async throws -> [RecognizedVariant] {
        try Task.checkCancellation()
        let croppedImage: CGImage
        if let cropRect {
            croppedImage = cropCGImage(normalizedImage, topLeftRect: cropRect) ?? normalizedImage
        } else {
            croppedImage = normalizedImage
        }
        let allPreparedVariants = SmartFishTicketOCRImageFactory.variants(
            from: croppedImage,
            includeBinary: includeBinary,
            variantLimit: variantLimit
        )
        let remainingVariants = allPreparedVariants.dropFirst(max(0, variantStartIndex))
        let preparedVariants: [SmartFishTicketOCRImageFactory.PreparedImage]
        if let recognitionLimit {
            preparedVariants = Array(remainingVariants.prefix(max(0, recognitionLimit)))
        } else {
            preparedVariants = Array(remainingVariants)
        }
        try Task.checkCancellation()

        var recognizedVariants: [RecognizedVariant] = []
        recognizedVariants.reserveCapacity(preparedVariants.count)
        for prepared in preparedVariants {
            try Task.checkCancellation()
            let recognized = try await recognize(
                cgImage: prepared.cgImage,
                minimumTextHeight: minimumTextHeight,
                customWords: customWords
            )
            try Task.checkCancellation()
            recognizedVariants.append(
                RecognizedVariant(
                    text: recognized.text,
                    lines: recognized.lines,
                    tokens: recognized.tokens,
                    variantTag: prepared.variantTag,
                    cgImage: prepared.cgImage
                )
            )
        }
        return recognizedVariants
    }

    static func preparedVariant(
        from normalizedImage: CGImage,
        cropRect: CGRect?,
        includeBinary: Bool,
        variantIndex: Int
    ) -> SmartFishTicketOCRImageFactory.PreparedImage? {
        let croppedImage: CGImage
        if let cropRect {
            croppedImage = cropCGImage(normalizedImage, topLeftRect: cropRect) ?? normalizedImage
        } else {
            croppedImage = normalizedImage
        }
        return SmartFishTicketOCRImageFactory.variant(
            from: croppedImage,
            includeBinary: includeBinary,
            at: variantIndex
        )
    }

    static func recognizeVariant(
        from normalizedImage: CGImage,
        cropRect: CGRect?,
        minimumTextHeight: Float,
        customWords: [String],
        includeBinary: Bool,
        variantIndex: Int
    ) async throws -> RecognizedVariant? {
        try Task.checkCancellation()
        guard let prepared = preparedVariant(
            from: normalizedImage,
            cropRect: cropRect,
            includeBinary: includeBinary,
            variantIndex: variantIndex
        ) else {
            return nil
        }

        let recognized = try await recognize(
            cgImage: prepared.cgImage,
            minimumTextHeight: minimumTextHeight,
            customWords: customWords
        )
        try Task.checkCancellation()
        return RecognizedVariant(
            text: recognized.text,
            lines: recognized.lines,
            tokens: recognized.tokens,
            variantTag: prepared.variantTag,
            cgImage: prepared.cgImage
        )
    }

    static func recognizeJoinedText(
        in cgImage: CGImage,
        minimumTextHeight: Float,
        customWords: [String],
        usesLanguageCorrection: Bool = false
    ) async throws -> String {
        try Task.checkCancellation()
        return try await recognize(
            cgImage: cgImage,
            minimumTextHeight: minimumTextHeight,
            customWords: customWords,
            usesLanguageCorrection: usesLanguageCorrection
        ).text
    }

    static func recognizeTextCandidates(
        in cgImage: CGImage,
        minimumTextHeight: Float,
        customWords: [String],
        usesLanguageCorrection: Bool,
        candidateLimit: Int = 3
    ) async throws -> [TextCandidate] {
        try Task.checkCancellation()
        let observations = try await recognizeObservations(
            cgImage: cgImage,
            minimumTextHeight: minimumTextHeight,
            customWords: customWords,
            usesLanguageCorrection: usesLanguageCorrection
        )
        try Task.checkCancellation()

        var candidates: [TextCandidate] = []
        var seen: Set<String> = []
        for observation in observations {
            for candidate in observation.topCandidates(max(1, candidateLimit)) {
                let text = collapsedWhitespace(candidate.string)
                guard !text.isEmpty, seen.insert(text).inserted else { continue }
                candidates.append(TextCandidate(text: text, confidence: candidate.confidence))
            }
        }
        return candidates.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            return lhs.text.count > rhs.text.count
        }
    }

    static func detectRectangles(in cgImage: CGImage) async throws -> [CGRect] {
        try Task.checkCancellation()
        let cancellationBox = SmartFishTicketVisionCancellationBox()

        let observations: [VNRectangleObservation] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                recognitionQueue.async {
                    autoreleasepool {
                        let request = VNDetectRectanglesRequest()
                        guard cancellationBox.install(request) else {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        defer { cancellationBox.clear() }

                        request.maximumObservations = 80
                        request.minimumConfidence = 0.35
                        request.minimumSize = 0.025
                        request.minimumAspectRatio = 0.15
                        request.maximumAspectRatio = 1.0
                        request.quadratureTolerance = 22

                        do {
                            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                            try handler.perform([request])
                            guard !cancellationBox.isCancelled else {
                                throw CancellationError()
                            }
                            continuation.resume(returning: request.results ?? [])
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        } onCancel: {
            cancellationBox.cancel()
        }

        return observations.map { convertedTopLeftRect($0.boundingBox) }
    }

    static func cropCGImage(_ cgImage: CGImage, topLeftRect: CGRect) -> CGImage? {
        let clampedRect = CGRect(
            x: max(0, min(1, topLeftRect.minX)),
            y: max(0, min(1, topLeftRect.minY)),
            width: max(0, min(1 - max(0, min(1, topLeftRect.minX)), topLeftRect.width)),
            height: max(0, min(1 - max(0, min(1, topLeftRect.minY)), topLeftRect.height))
        )

        guard clampedRect.width > 0, clampedRect.height > 0 else { return nil }

        let pixelRect = CGRect(
            x: clampedRect.minX * CGFloat(cgImage.width),
            y: clampedRect.minY * CGFloat(cgImage.height),
            width: clampedRect.width * CGFloat(cgImage.width),
            height: clampedRect.height * CGFloat(cgImage.height)
        ).integral

        guard pixelRect.width > 1, pixelRect.height > 1 else { return nil }
        return cgImage.cropping(to: pixelRect)
    }

    private static func recognize(
        cgImage: CGImage,
        minimumTextHeight: Float,
        customWords: [String],
        usesLanguageCorrection: Bool = false
    ) async throws -> (text: String, lines: [RecognizedLine], tokens: [RecognizedToken]) {
        try Task.checkCancellation()
        let observations = try await recognizeObservations(
            cgImage: cgImage,
            minimumTextHeight: minimumTextHeight,
            customWords: customWords,
            usesLanguageCorrection: usesLanguageCorrection
        )
        try Task.checkCancellation()

        let convertedLines = makeLines(from: observations)
        let convertedTokens = makeTokens(from: observations)
        let sortedLines = convertedLines.sorted { lhs, rhs in
            let delta = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
            if delta > 0.012 {
                return lhs.boundingBox.midY < rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        let sortedTokens = convertedTokens.sorted { lhs, rhs in
            let delta = abs(lhs.centerY - rhs.centerY)
            if delta > 0.012 {
                return lhs.centerY < rhs.centerY
            }
            return lhs.minX < rhs.minX
        }

        let text = sortedLines.map(\.text).joined(separator: "\n")
        return (text, sortedLines, sortedTokens)
    }

    private static func recognizeObservations(
        cgImage: CGImage,
        minimumTextHeight: Float,
        customWords: [String],
        usesLanguageCorrection: Bool = false
    ) async throws -> [VNRecognizedTextObservation] {
        try Task.checkCancellation()
        let cancellationBox = SmartFishTicketVisionCancellationBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                recognitionQueue.async {
                    autoreleasepool {
                        let request = VNRecognizeTextRequest()
                        guard cancellationBox.install(request) else {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        defer { cancellationBox.clear() }

                        do {
                            request.recognitionLevel = .accurate
                            request.usesLanguageCorrection = usesLanguageCorrection
                            request.minimumTextHeight = minimumTextHeight
                            request.recognitionLanguages = recognitionLanguages
                            request.customWords = customWords

                            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                            try handler.perform([request])
                            guard !cancellationBox.isCancelled else {
                                throw CancellationError()
                            }
                            continuation.resume(returning: request.results ?? [])
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        } onCancel: {
            cancellationBox.cancel()
        }
    }

    private static func makeLines(from observations: [VNRecognizedTextObservation]) -> [RecognizedLine] {
        observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedLine(
                text: collapsedWhitespace(candidate.string),
                boundingBox: convertedTopLeftRect(observation.boundingBox),
                confidence: candidate.confidence
            )
        }
        .filter { !$0.text.isEmpty }
    }

    private static func makeTokens(from observations: [VNRecognizedTextObservation]) -> [RecognizedToken] {
        var tokens: [RecognizedToken] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let tokenRanges = nonWhitespaceRanges(in: candidate.string)
            if tokenRanges.isEmpty {
                let fallbackText = collapsedWhitespace(candidate.string)
                if !fallbackText.isEmpty {
                    tokens.append(
                        RecognizedToken(
                            text: fallbackText,
                            boundingBox: convertedTopLeftRect(observation.boundingBox),
                            confidence: candidate.confidence
                        )
                    )
                }
                continue
            }

            for range in tokenRanges {
                let rawToken = String(candidate.string[range])
                let cleanedToken = collapsedWhitespace(rawToken)
                guard !cleanedToken.isEmpty else { continue }
                let box = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                tokens.append(
                    RecognizedToken(
                        text: cleanedToken,
                        boundingBox: convertedTopLeftRect(box),
                        confidence: candidate.confidence
                    )
                )
            }
        }
        return tokens
    }

    private static func convertedTopLeftRect(_ visionRect: CGRect) -> CGRect {
        CGRect(
            x: visionRect.minX,
            y: 1 - visionRect.maxY,
            width: visionRect.width,
            height: visionRect.height
        )
    }

    private static func nonWhitespaceRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var tokenStart: String.Index?
        var cursor = text.startIndex

        while cursor < text.endIndex {
            let character = text[cursor]
            if character.isWhitespace {
                if let start = tokenStart {
                    ranges.append(start..<cursor)
                    tokenStart = nil
                }
            } else if tokenStart == nil {
                tokenStart = cursor
            }
            cursor = text.index(after: cursor)
        }

        if let start = tokenStart {
            ranges.append(start..<text.endIndex)
        }
        return ranges
    }

    nonisolated static func collapsedWhitespace(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum SmartFishTicketSandboxV3SummaryParser {
    struct ParsedSummary {
        var soldWeight: Int?
        var statArea: String?
        var startDateCaught: String?
        var dateLanded: String?
        var timeOfLanding: String?
        var tenderName: String?
        var chillType: String?
        var temperature: String?

        var presentFieldCount: Int {
            [
                soldWeight == nil ? nil : "soldWeight",
                statArea,
                startDateCaught,
                dateLanded,
                timeOfLanding,
                tenderName,
                chillType,
                temperature
            ]
            .compactMap { $0 }
            .count
        }
    }

    struct ParsedPage {
        let pageIndex: Int
        let summary: ParsedSummary
        let matchedAnchorCount: Int
        let tallyAnchorCount: Int
        let warnings: [String]
    }

    private static let summaryCrops: [CGRect?] = [
        nil,
        CGRect(x: 0.28, y: 0.09, width: 0.62, height: 0.38),
        CGRect(x: 0.34, y: 0.12, width: 0.50, height: 0.28)
    ]

    private static let summaryAnchors: [String] = [
        "tender name",
        "chill type",
        "temperature",
        "stat area",
        "statistical area",
        "area fished",
        "start date caught",
        "date landed",
        "time of landing",
        "electronic salmon ticket",
        "statistical area worksheet"
    ]

    private static let tallyAnchors: [String] = [
        "electronic salmon tally sheet",
        "thumb drive id",
        "brailers",
        "sold weight"
    ]

    private static let summaryCustomWords: [String] = [
        "Tender Name",
        "Tender ADF&G No.",
        "Chill Type",
        "Temperature",
        "Stat Area",
        "Statistical Area",
        "Area Fished",
        "District Stat Area",
        "Start Date Caught",
        "Date Landed",
        "Time of Landing",
        "Landed Wt",
        "RSW",
        "CSW",
        "CHILLED",
        "KUSTATAN",
        "STARLING",
        "FARRAR",
        "SEA",
        "LOIS",
        "ANDERSON",
        "RAMBLIN",
        "ROSE",
        "GAMBLER",
        "VIKING",
        "QUEEN",
        "VICTORY"
    ] + BristolBayStatAreaResolver.customWords

    nonisolated private static let knownTenderNames: [String] = [
        "KUSTATAN",
        "STARLING S",
        "FARRAR SEA",
        "LOIS ANDERSON",
        "RAMBLIN ROSE",
        "GAMBLER",
        "VIKING QUEEN",
        "VICTORY"
    ]

    static func parse(images: [UIImage]) async throws -> ParsedPage? {
        guard !images.isEmpty else {
            throw SmartFishTicketExtractorError.noImages
        }
        let startedAt = ProcessInfo.processInfo.systemUptime
        SmartFishTicketOCRDiagnostics.started(kind: "summary", pageCount: images.count)
        defer {
            SmartFishTicketOCRDiagnostics.completed(
                kind: "summary",
                pageCount: images.count,
                startedAt: startedAt
            )
        }

        var parsedPages: [ParsedPage] = []
        parsedPages.reserveCapacity(images.count)

        for (pageIndex, image) in images.enumerated() {
            try Task.checkCancellation()
            if let parsedPage = try await parsePage(image: image, pageIndex: pageIndex) {
                parsedPages.append(parsedPage)
            }
        }

        guard !parsedPages.isEmpty else {
            throw SmartFishTicketExtractorError.noRenderableImages
        }

        return parsedPages.max { lhs, rhs in
            score(for: lhs) < score(for: rhs)
        }
    }

    private static func parsePage(image: UIImage, pageIndex: Int) async throws -> ParsedPage? {
        guard let normalizedImage = SmartFishTicketOCRImageFactory.normalizedImage(
            from: image,
            maxDimension: SmartFishTicketOCRProfile.summaryMaxDimension
        ) else {
            return nil
        }

        var selectedTexts: [String] = []

        for (cropIndex, crop) in summaryCrops.enumerated() {
            try Task.checkCancellation()
            if cropIndex == 0 {
                let primaryVariants = try await SmartFishTicketSandboxV3OCR.recognizeVariants(
                    from: normalizedImage,
                    cropRect: crop,
                    minimumTextHeight: 0.0042,
                    customWords: summaryCustomWords,
                    includeBinary: SmartFishTicketOCRProfile.includeBinaryVariants,
                    variantLimit: SmartFishTicketOCRProfile.summaryVariantLimit,
                    recognitionLimit: 1
                )
                try Task.checkCancellation()

                if let primaryText = bestCropText(from: primaryVariants),
                   isStrongSummaryText(primaryText) {
                    selectedTexts.append(primaryText)
                    break
                }

                let fallbackVariants = try await SmartFishTicketSandboxV3OCR.recognizeVariants(
                    from: normalizedImage,
                    cropRect: crop,
                    minimumTextHeight: 0.0042,
                    customWords: summaryCustomWords,
                    includeBinary: SmartFishTicketOCRProfile.includeBinaryVariants,
                    variantLimit: SmartFishTicketOCRProfile.summaryVariantLimit,
                    variantStartIndex: 1
                )
                try Task.checkCancellation()
                if let bestText = bestCropText(from: primaryVariants + fallbackVariants) {
                    selectedTexts.append(bestText)
                }
                continue
            }

            let recognizedVariants = try await SmartFishTicketSandboxV3OCR.recognizeVariants(
                from: normalizedImage,
                cropRect: crop,
                minimumTextHeight: 0.0042,
                customWords: summaryCustomWords,
                includeBinary: SmartFishTicketOCRProfile.includeBinaryVariants,
                variantLimit: SmartFishTicketOCRProfile.summaryVariantLimit
            )
            try Task.checkCancellation()
            if let bestText = bestCropText(from: recognizedVariants) {
                selectedTexts.append(bestText)
            }
        }

        let joinedText = normalizedSummarySource(selectedTexts)
        guard !joinedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let summary = parseSummary(from: joinedText)
        let statAreaCandidates = BristolBayStatAreaResolver.candidateResolutions(in: joinedText)
        let normalizedText = normalized(joinedText)
        let matchedAnchorCount = summaryAnchors.reduce(0) { partial, phrase in
            partial + (normalizedText.contains(normalized(phrase)) ? 1 : 0)
        }
        let tallyAnchorCount = tallyAnchors.reduce(0) { partial, phrase in
            partial + (normalizedText.contains(normalized(phrase)) ? 1 : 0)
        }

        var warnings: [String] = []
        if tallyAnchorCount > matchedAnchorCount {
            warnings.append("This page looked more like a tally sheet than a delivery summary page. Double-check the values before applying.")
        }
        if matchedAnchorCount < 3 {
            warnings.append("Only \(matchedAnchorCount) expected first-page labels were found. Double-check the parsed values before applying.")
        }
        if statAreaCandidates.count > 1 {
            warnings.append("More than one Bristol Bay stat-area candidate was detected. Confirm the Stat Area before applying.")
        } else if summary.statArea == nil, normalizedText.contains("stat") && normalizedText.contains("area") {
            warnings.append("A Stat Area label was seen, but the value did not match a known Bristol Bay area. Edit Stat Area before applying if needed.")
        }

        return ParsedPage(
            pageIndex: pageIndex,
            summary: summary,
            matchedAnchorCount: matchedAnchorCount,
            tallyAnchorCount: tallyAnchorCount,
            warnings: deduplicatedWarnings(warnings)
        )
    }

    private static func isStrongSummaryText(_ rawText: String) -> Bool {
        let parsedSummary = parseSummary(from: rawText)
        let normalizedText = normalized(rawText)
        let matchedAnchorCount = summaryAnchors.reduce(0) { partial, phrase in
            partial + (normalizedText.contains(normalized(phrase)) ? 1 : 0)
        }
        return parsedSummary.presentFieldCount >= 7 && matchedAnchorCount >= 3
    }

    private static func bestCropText(from variants: [SmartFishTicketSandboxV3OCR.RecognizedVariant]) -> String? {
        variants
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .max { lhs, rhs in
                cropTextScore(lhs.text) < cropTextScore(rhs.text)
            }?
            .text
    }

    private static func cropTextScore(_ rawText: String) -> Int {
        let normalizedText = normalized(rawText)
        let summaryHits = summaryAnchors.reduce(0) { partial, phrase in
            partial + (normalizedText.contains(normalized(phrase)) ? 1 : 0)
        }
        let tallyHits = tallyAnchors.reduce(0) { partial, phrase in
            partial + (normalizedText.contains(normalized(phrase)) ? 1 : 0)
        }

        let bonusLabels = [
            "tender name",
            "chill type",
            "temperature",
            "start date caught",
            "date landed",
            "time of landing",
            "total",
            "tare"
        ]
        .reduce(0) { partial, phrase in
            partial + (normalizedText.contains(normalized(phrase)) ? 1 : 0)
        }

        return (summaryHits * 12) + (bonusLabels * 5) - (tallyHits * 8)
    }

    private static func normalizedSummarySource(_ texts: [String]) -> String {
        var seen: Set<String> = []
        let deduped = texts.compactMap { rawText -> String? in
            let replaced = rawText
                .replacingOccurrences(of: "Tender N", with: "Tender Name")
                .replacingOccurrences(of: "ender Name", with: "Tender Name")
                .replacingOccurrences(of: "Tender  Name", with: "Tender Name")
            let key = normalized(replaced)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return replaced
        }
        return deduped.joined(separator: "\n")
    }

    private static func parseSummary(from text: String) -> ParsedSummary {
        var summary = ParsedSummary()
        let statAreaCandidates = BristolBayStatAreaResolver.candidateResolutions(in: text)

        if let bestStatArea = statAreaCandidates.first?.resolution {
            summary.statArea = bestStatArea.normalizedStatArea
        }

        summary.startDateCaught = capture(patterns: [
            #"Start\s*Date\s*Caugh?t\s*([0-9]{1,2}\s*[/-]\s*[0-9]{1,2}\s*[/-]\s*[0-9]{2,4})"#,
            #"Start\s*Date\s*Caugh?t\s*:?\s*([0-9]{1,2}\s*[/-]\s*[0-9]{1,2}\s*[/-]\s*[0-9]{2,4})"#
        ], in: text).map { SmartLogbookParse.normalizedFishTicketDate($0) }
            ?? anchoredDate(
                in: text,
                anchorPhrases: ["start date caught"],
                stopPhrases: ["end date caught", "date landed", "time of landing", "partial delivery", "dual permit", "double brailers", "fishing period"]
            )

        summary.dateLanded = capture(patterns: [
            #"Date\s*Landed\s*([0-9]{1,2}\s*[/-]\s*[0-9]{1,2}\s*[/-]\s*[0-9]{2,4})"#,
            #"Date\s*Landed\s*:?\s*([0-9]{1,2}\s*[/-]\s*[0-9]{1,2}\s*[/-]\s*[0-9]{2,4})"#
        ], in: text).map { SmartLogbookParse.normalizedFishTicketDate($0) }
            ?? anchoredDate(
                in: text,
                anchorPhrases: ["date landed"],
                stopPhrases: ["time of landing", "dual permit", "double brailers", "fishing period"]
            )

        summary.timeOfLanding = capture(patterns: [
            #"Time\s*of\s*Landing\s*([0-9]{1,2}\s*[:.\-]\s*[0-9]{2}|[0-9]{3,4})"#,
            #"Time\s*of\s*Landing\s*:?\s*([0-9]{1,2}\s*[:.\-]\s*[0-9]{2}|[0-9]{3,4})"#
        ], in: text).map { SmartLogbookParse.normalizedFishTicketTime($0) }
            ?? anchoredTime(
                in: text,
                anchorPhrases: ["time of landing"],
                stopPhrases: ["fishing period", "brailers", "criteria", "qa", "graph"]
            )

        summary.temperature = capture(patterns: [
            #"Temperature\s*([0-9]{1,4}(?:\s*[.]\s*[0-9])?)"#,
            #"Temp(?:erature)?\s*:?\s*([0-9]{1,4}(?:\s*[.]\s*[0-9])?)"#
        ], in: text).flatMap { SmartLogbookParse.firstTemperatureString(in: $0) }
            ?? anchoredTemperature(
                in: text,
                anchorPhrases: ["temperature", "temp"],
                stopPhrases: ["start date caught", "date landed", "time of landing", "fishing period", "partial delivery", "dual permit", "double brailers"]
            )

        summary.chillType = normalizeChill(capture(patterns: [
            #"Chill\s*Type\s*([A-Z]{1,10}(?:/[A-Z]{2,10})?)"#,
            #"Chill\s*Type\s*:?\s*([A-Z]{1,10}(?:/[A-Z]{2,10})?)"#,
            #"\b(RSW|CSW|ICE|CHILLED)\b"#
        ], in: text) ?? anchoredChillType(
            in: text,
            anchorPhrases: ["chill type"],
            stopPhrases: ["temperature", "temp", "start date caught", "date landed", "time of landing", "fishing period"]
        ))

        summary.tenderName = anchoredTenderCandidate(in: text) ?? bestTenderCandidate(in: text)

        if let soldWeight = parseSoldWeight(in: text) {
            summary.soldWeight = soldWeight
        }

        return summary
    }

    private static func anchoredDate(
        in text: String,
        anchorPhrases: [String],
        stopPhrases: [String]
    ) -> String? {
        guard let anchoredText = SmartFishTicketOCRSupport.sliceText(in: text, after: anchorPhrases, before: stopPhrases) else {
            return nil
        }
        return SmartLogbookParse.firstDateString(in: anchoredText)
    }

    private static func anchoredTime(
        in text: String,
        anchorPhrases: [String],
        stopPhrases: [String]
    ) -> String? {
        guard let anchoredText = SmartFishTicketOCRSupport.sliceText(in: text, after: anchorPhrases, before: stopPhrases) else {
            return nil
        }
        return SmartLogbookParse.first24HourTimeString(in: anchoredText)
    }

    private static func anchoredTemperature(
        in text: String,
        anchorPhrases: [String],
        stopPhrases: [String]
    ) -> String? {
        guard let anchoredText = SmartFishTicketOCRSupport.sliceText(in: text, after: anchorPhrases, before: stopPhrases) else {
            return nil
        }
        return SmartLogbookParse.firstTemperatureString(in: anchoredText)
    }

    private static func anchoredChillType(
        in text: String,
        anchorPhrases: [String],
        stopPhrases: [String]
    ) -> String? {
        guard let anchoredText = SmartFishTicketOCRSupport.sliceText(in: text, after: anchorPhrases, before: stopPhrases) else {
            return nil
        }

        let clipped = SmartLogbookParse.clipAtStopPhrases(in: anchoredText, stopPhrases: stopPhrases)
        if let tokenRange = clipped.range(of: #"\b(?:RSW|CSW|ICE|CHILLED)\b"#, options: [.regularExpression, .caseInsensitive]) {
            return String(clipped[tokenRange])
        }
        return SmartLogbookParse.firstRegexCapture(in: clipped, pattern: #"\b([A-Za-z]{2,10}(?:/[A-Za-z]{2,10})?)\b"#)
    }

    private static func anchoredTenderCandidate(in text: String) -> String? {
        guard let anchoredText = SmartFishTicketOCRSupport.sliceText(
            in: text,
            after: ["tender name"],
            before: ["chill type", "temperature", "temp", "start date caught", "date landed", "time of landing", "owner", "custom processor", "fishing period"]
        ) else {
            return nil
        }

        let cleanedCandidate = cleanupTenderCandidate(anchoredText)
        guard !cleanedCandidate.isEmpty else { return nil }
        let upperCandidate = cleanedCandidate.uppercased()
        guard !containsBannedTenderPhrase(upperCandidate) else { return nil }
        return canonicalTenderName(upperCandidate)
    }

    private static func parseSoldWeight(in text: String) -> Int? {
        if let totalRowWeight = SmartLogbookParse.bestSoldWeightInteger(in: text) {
            return totalRowWeight
        }

        if let landedWeightText = capture(patterns: [
            #"Landed\s*Wt\s*:?\s*([0-9][0-9,]*)"#,
            #"Sold\s*Weight\s*:?\s*([0-9][0-9,]*)"#
        ], in: text), let landedWeight = Int(landedWeightText.replacingOccurrences(of: ",", with: "")) {
            return landedWeight
        }

        return nil
    }

    private static func bestTenderCandidate(in text: String) -> String? {
        let patterns = [
            #"Tender\s*Name\s*([A-Z][A-Z0-9 .&'/-]{2,25}?)(?=\s+Chill\s*Type|\s+Temperature|\s+Start\s*Date\s*Caugh?t|\s+Date\s*Landed|\s+Time\s*of\s*Landing|$)"#,
            #"Tender\s*Name\s*([A-Z][A-Z0-9 .&'/-]{2,25})"#
        ]

        var candidateScores: [String: Int] = [:]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, options: [], range: nsRange) {
                guard match.numberOfRanges > 1,
                      let captureRange = Range(match.range(at: 1), in: text) else {
                    continue
                }

                let rawCandidate = String(text[captureRange])
                    .replacingOccurrences(of: #"[^A-Za-z0-9 .&'/-]"#, with: " ", options: .regularExpression)
                let cleanedCandidate = cleanupTenderCandidate(rawCandidate)
                let upperCandidate = cleanedCandidate.uppercased()

                guard !cleanedCandidate.isEmpty else { continue }
                guard upperCandidate.range(of: #"\d{3,}"#, options: .regularExpression) == nil else { continue }
                guard !containsBannedTenderPhrase(upperCandidate) else { continue }

                let wordCount = cleanedCandidate.split(separator: " ").count
                guard (1...4).contains(wordCount) else { continue }

                let alphaCount = upperCandidate.filter(\.isLetter).count
                let score = (alphaCount * 4) + upperCandidate.count - (cleanedCandidate.filter { $0 == " " }.count * 2)
                candidateScores[upperCandidate, default: 0] += max(score, 1)
            }
        }

        let bestCandidate = candidateScores.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key.count < rhs.key.count
        }?.key

        return bestCandidate.map(canonicalTenderName)
    }

    private static func cleanupTenderCandidate(_ raw: String) -> String {
        var value = raw.replacingOccurrences(of: #"^[^A-Za-z]*"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"^(?:NAME|AME|TENDER|N)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: #"\b(?:RSW|CSW|ICE|CHILLED)\b.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: #"\b(?:PARTIAL|DUAL|DOUBLE|FISHING|PERIOD|TEMP(?:ERATURE)?)\b.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: #"[^A-Za-z0-9 .&'/-]"#, with: " ", options: .regularExpression)
        var words = SmartFishTicketSandboxV3OCR.collapsedWhitespace(value)
            .split(separator: " ")
            .map(String.init)

        let allowedShortSuffixes: Set<String> = ["S", "II", "III", "IV", "V", "JR", "SR"]
        while let last = words.last {
            let upperLast = last.uppercased()
            let hasDigits = upperLast.range(of: #"\d"#, options: .regularExpression) != nil
            let letterCount = upperLast.filter(\.isLetter).count
            if hasDigits || ["AE", "Q", "C", "O", "D"].contains(upperLast) {
                words.removeLast()
                continue
            }
            if words.count >= 2, letterCount <= 2, !allowedShortSuffixes.contains(upperLast) {
                words.removeLast()
                continue
            }
            break
        }

        return SmartFishTicketSandboxV3OCR.collapsedWhitespace(words.joined(separator: " "))
    }

    nonisolated private static func canonicalTenderName(_ raw: String) -> String {
        let upperRaw = SmartFishTicketSandboxV3OCR.collapsedWhitespace(raw.uppercased())
        let normalizedRaw = upperRaw.replacingOccurrences(of: #"[^A-Z0-9]"#, with: "", options: .regularExpression)
        guard !normalizedRaw.isEmpty else { return upperRaw }

        var bestMatch: (name: String, score: Double)? = nil
        for candidate in knownTenderNames {
            let normalizedCandidate = candidate.replacingOccurrences(of: #"[^A-Z0-9]"#, with: "", options: .regularExpression)
            let score = tenderSimilarity(normalizedRaw, normalizedCandidate)
            if let currentBest = bestMatch {
                if score > currentBest.score {
                    bestMatch = (candidate, score)
                }
            } else {
                bestMatch = (candidate, score)
            }
        }

        if let bestMatch, bestMatch.score >= 0.86 {
            return bestMatch.name
        }
        return upperRaw
    }

    nonisolated private static func tenderSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsCharacters = Array(lhs)
        let rhsCharacters = Array(rhs)
        let maxLength = max(lhsCharacters.count, rhsCharacters.count)
        guard maxLength > 0 else { return 1 }

        var matrix = Array(
            repeating: Array(repeating: 0, count: rhsCharacters.count + 1),
            count: lhsCharacters.count + 1
        )

        for lhsIndex in 0...lhsCharacters.count {
            matrix[lhsIndex][0] = lhsIndex
        }
        for rhsIndex in 0...rhsCharacters.count {
            matrix[0][rhsIndex] = rhsIndex
        }

        if !lhsCharacters.isEmpty && !rhsCharacters.isEmpty {
            for lhsIndex in 1...lhsCharacters.count {
                for rhsIndex in 1...rhsCharacters.count {
                    let substitutionCost = lhsCharacters[lhsIndex - 1] == rhsCharacters[rhsIndex - 1] ? 0 : 1
                    matrix[lhsIndex][rhsIndex] = min(
                        matrix[lhsIndex - 1][rhsIndex] + 1,
                        matrix[lhsIndex][rhsIndex - 1] + 1,
                        matrix[lhsIndex - 1][rhsIndex - 1] + substitutionCost
                    )
                }
            }
        }

        let distance = matrix[lhsCharacters.count][rhsCharacters.count]
        return 1 - (Double(distance) / Double(maxLength))
    }

    private static func containsBannedTenderPhrase(_ uppercasedCandidate: String) -> Bool {
        [
            "ADFG",
            "OWNER",
            "VESSEL",
            "PERMIT",
            "CHILL TYPE",
            "TEMPERATURE",
            "START DATE",
            "DATE LANDED",
            "TIME OF LANDING",
            "MAG STRIPE",
            "READ"
        ]
        .contains { uppercasedCandidate.contains($0) }
    }

    private static func normalizeChill(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let uppercased = raw.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uppercased.isEmpty else { return nil }
        if uppercased == "SW" || uppercased.hasSuffix("SW") {
            return "RSW"
        }
        return uppercased
    }

    private static func capture(patterns: [String], in text: String) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
                  match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            let value = SmartFishTicketSandboxV3OCR.collapsedWhitespace(String(text[captureRange]))
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func integers(in text: String) -> [Int] {
        let normalizedText = text
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "o", with: "0")
            .replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "l", with: "1")
        guard let regex = try? NSRegularExpression(pattern: #"[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+"#, options: []) else {
            return []
        }
        let nsRange = NSRange(normalizedText.startIndex..<normalizedText.endIndex, in: normalizedText)
        return regex.matches(in: normalizedText, options: [], range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: normalizedText) else { return nil }
            return Int(normalizedText[range].replacingOccurrences(of: ",", with: ""))
        }
    }

    private static func score(for page: ParsedPage) -> Int {
        (page.summary.presentFieldCount * 30) + (page.matchedAnchorCount * 10) - (page.tallyAnchorCount * 12)
    }

    static func deduplicatedWarnings(_ warnings: [String]) -> [String] {
        var seen: Set<String> = []
        return warnings.filter { seen.insert($0).inserted }
    }

    private static func normalized(_ raw: String) -> String {
        SmartFishTicketSandboxV3OCR.collapsedWhitespace(
            raw.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        )
    }
}

#if DEBUG
struct SmartFishTicketTallyOCRTestToken: Sendable, Equatable {
    let text: String
    let boundingBox: CGRect
    let confidence: Float

    init(text: String, boundingBox: CGRect, confidence: Float = 0.99) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

struct SmartFishTicketTallyOCRTestRow: Sendable, Equatable {
    let species: String
    let deliveryCondition: String
    let soldWeight: Int
    let brailers: Int?
    let isInferredWeight: Bool
}

struct SmartFishTicketTallyOCRTestResult: Sendable, Equatable {
    let rows: [SmartFishTicketTallyOCRTestRow]
    let warnings: [String]
    let score: Int
}
#endif

private enum SmartFishTicketSandboxV3TallyParser {
    private struct TableGeometry {
        /// Actual OCR coordinates are mapped from the canonical tally form with:
        /// actualX = xOffset + (canonicalX * xScale).
        let xOffset: CGFloat
        let xScale: CGFloat
        let matchedHeaderAnchorCount: Int

        static let identity = TableGeometry(
            xOffset: 0,
            xScale: 1,
            matchedHeaderAnchorCount: 0
        )

        func canonicalized(
            _ token: SmartFishTicketSandboxV3OCR.RecognizedToken
        ) -> SmartFishTicketSandboxV3OCR.RecognizedToken {
            guard xScale > 0.001 else { return token }
            let rect = token.boundingBox
            return SmartFishTicketSandboxV3OCR.RecognizedToken(
                text: token.text,
                boundingBox: CGRect(
                    x: (rect.minX - xOffset) / xScale,
                    y: rect.minY,
                    width: rect.width / xScale,
                    height: rect.height
                ),
                confidence: token.confidence
            )
        }

        func actualRect(forCanonicalRect rect: CGRect) -> CGRect {
            CGRect(
                x: xOffset + (rect.minX * xScale),
                y: rect.minY,
                width: rect.width * xScale,
                height: rect.height
            )
        }
    }

    private struct Cluster {
        let centerY: CGFloat
        let soldWeight: Int
        let tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken]
        let isInferredWeight: Bool

        init(
            centerY: CGFloat,
            soldWeight: Int,
            tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
            isInferredWeight: Bool = false
        ) {
            self.centerY = centerY
            self.soldWeight = soldWeight
            self.tokens = tokens
            self.isInferredWeight = isInferredWeight
        }
    }

    private struct ParsedRow {
        var species: String
        var deliveryCondition: String
        var soldWeight: Int
        var brailers: Int?
        var isInferredWeight: Bool = false
    }

    private struct PageCandidate {
        let pageIndex: Int
        let cropRect: CGRect
        let variantIndex: Int
        let variantTag: String
        let tableGeometry: TableGeometry
        let rows: [ParsedRow]
        let clusterSum: Int
        let headerHits: Int
        let rowEvidenceScore: Int
        let unsupportedRowCount: Int
        let rowIntervals: [RowInterval]
        let tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken]
        let warnings: [String]

        func score(expectedSummarySoldWeight: Int?) -> Int {
            let totalDelta = expectedSummarySoldWeight.map { abs($0 - clusterSum) } ?? 0
            let exactTotalBonus = expectedSummarySoldWeight != nil && totalDelta == 0 ? 2400 : 0
            let nearTotalBonus = expectedSummarySoldWeight.map { _ in max(0, 900 - (totalDelta * 18)) } ?? 0
            let inferredWeightPenalty = rows.filter(\.isInferredWeight).count * 90
            let missingSemanticCellPenalty = rows.reduce(0) { partial, row in
                partial + (row.species.isEmpty ? 180 : 0) + (row.deliveryCondition.isEmpty ? 150 : 0)
            }
            let summaryOnlyPenalty: Int
            if let expectedSummarySoldWeight,
               rows.count == 1,
               clusterSum == expectedSummarySoldWeight,
               let row = rows.first,
               row.species.isEmpty,
               row.deliveryCondition.isEmpty {
                summaryOnlyPenalty = 6_000
            } else {
                summaryOnlyPenalty = 0
            }
            return exactTotalBonus
                + nearTotalBonus
                + (headerHits * 80)
                + rowEvidenceScore
                - (unsupportedRowCount * 360)
                - inferredWeightPenalty
                - missingSemanticCellPenalty
                - summaryOnlyPenalty
        }

        func isStrong(expectedSummarySoldWeight: Int?) -> Bool {
            guard headerHits >= 2, !rows.isEmpty, unsupportedRowCount == 0 else { return false }
            guard rowEvidenceScore >= rows.count * 230 else { return false }
            guard rows.allSatisfy({
                $0.soldWeight > 0 && !$0.species.isEmpty && !$0.deliveryCondition.isEmpty
            }) else {
                return false
            }
            if let expectedSummarySoldWeight {
                return clusterSum == expectedSummarySoldWeight
            }
            return true
        }

        var signature: String {
            let weights = rows.map { String($0.soldWeight) }.joined(separator: ",")
            let centers = rowIntervals.map { String(format: "%.3f", ($0.topY + $0.bottomY) / 2) }.joined(separator: ",")
            let crop = String(
                format: "%.3f,%.3f,%.3f,%.3f",
                cropRect.minX,
                cropRect.minY,
                cropRect.width,
                cropRect.height
            )
            return "\(pageIndex)|\(variantTag)|\(crop)|\(weights)|\(centers)"
        }
    }

    private struct SmallTailCandidate {
        let centerY: CGFloat
        let soldWeight: Int
        let score: Int
        let tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken]
    }

    private struct RecoveryCandidate {
        let centerY: CGFloat
        let soldWeight: Int
        let score: Int
        let tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken]
    }

    private struct HeaderAnchorMatch {
        let canonicalCenterX: CGFloat
        let token: SmartFishTicketSandboxV3OCR.RecognizedToken
    }

    private static let tallyCrops: [CGRect] = [
        CGRect(x: 0.03, y: 0.16, width: 0.94, height: 0.48),
        CGRect(x: 0.04, y: 0.18, width: 0.92, height: 0.40),
        CGRect(x: 0.04, y: 0.18, width: 0.92, height: 0.44),
        CGRect(x: 0.05, y: 0.19, width: 0.90, height: 0.41),
        CGRect(x: 0.04, y: 0.17, width: 0.92, height: 0.50)
    ]

    private static let boundaryRatios: [CGFloat] = [
        0.035, 0.132, 0.215, 0.283, 0.385, 0.471, 0.573, 0.660, 0.772, 0.883, 0.972
    ]

    private static let speciesColumnRange: ClosedRange<CGFloat> = 0.03...0.15
    private static let deliveryConditionColumnRange: ClosedRange<CGFloat> = 0.14...0.25
    private static let countColumnRange: ClosedRange<CGFloat> = 0.24...0.40
    private static let postTareColumnRange: ClosedRange<CGFloat> = 0.50...0.61
    private static let soldWeightColumnRange: ClosedRange<CGFloat> = 0.82...0.92
    private static let brailersColumnRange: ClosedRange<CGFloat> = 0.88...1.10

    private static let canonicalHeaderCenters: [(phrases: [String], centerX: CGFloat)] = [
        (["species"], 0.095),
        (["cond"], 0.195),
        (["num"], 0.315),
        (["post"], 0.550),
        (["sold"], 0.870),
        (["brailer"], 0.965)
    ]

    private static let headerPhrases: [String] = [
        "species",
        "del cond",
        "num",
        "scale wt",
        "tare",
        "post tare",
        "sold weight",
        "brailers"
    ]

    private static let tallyCustomWords: [String] = [
        "SPECIES",
        "DEL. COND",
        "NUM",
        "SCALE WT",
        "POST TARE WT",
        "SOLD WEIGHT",
        "BRAILERS",
        "TALLY SHEET",
        "KINGS",
        "SALMON",
        "WHOLE",
        "ROUND",
        "BLED"
    ]

    private static let footerTokenPattern = #"^(?:total:?|t\.?tare:?|landing|thumb|cfec)$"#
    private static let maxPageCandidates = 4
    private static let maxCombinationStates = 64

    private static func tableGeometry(
        in tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        maximumHeaderTopY: CGFloat = 0.24
    ) -> TableGeometry {
        let matches = headerAnchorMatches(in: tokens, maximumHeaderTopY: maximumHeaderTopY)
        guard !matches.isEmpty else { return .identity }

        if matches.count == 1, let match = matches.first {
            let offset = match.token.centerX - match.canonicalCenterX
            guard abs(offset) <= 0.12 else { return .identity }
            return TableGeometry(xOffset: offset, xScale: 1, matchedHeaderAnchorCount: 1)
        }

        let canonicalMean = matches.map(\.canonicalCenterX).reduce(0, +) / CGFloat(matches.count)
        let actualMean = matches.map(\.token.centerX).reduce(0, +) / CGFloat(matches.count)
        let denominator = matches.reduce(CGFloat(0)) { partial, match in
            let delta = match.canonicalCenterX - canonicalMean
            return partial + (delta * delta)
        }
        guard denominator > 0.0001 else { return .identity }

        let numerator = matches.reduce(CGFloat(0)) { partial, match in
            partial + ((match.canonicalCenterX - canonicalMean) * (match.token.centerX - actualMean))
        }
        let scale = numerator / denominator
        let offset = actualMean - (scale * canonicalMean)
        guard (0.60...1.40).contains(scale), abs(offset) <= 0.25 else { return .identity }

        return TableGeometry(
            xOffset: offset,
            xScale: scale,
            matchedHeaderAnchorCount: matches.count
        )
    }

    private static func headerAnchorMatches(
        in tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        maximumHeaderTopY: CGFloat
    ) -> [HeaderAnchorMatch] {
        let rawMatches: [HeaderAnchorMatch] = tokens.compactMap { token in
            guard token.topY <= maximumHeaderTopY else { return nil }
            let tokenText = normalized(token.text)
            guard let anchor = canonicalHeaderCenters.first(where: { anchor in
                anchor.phrases.contains(where: tokenText.contains)
            }) else {
                return nil
            }
            return HeaderAnchorMatch(canonicalCenterX: anchor.centerX, token: token)
        }
        guard !rawMatches.isEmpty else { return [] }

        let yTolerance: CGFloat = maximumHeaderTopY > 0.30 ? 0.045 : 0.060
        let candidateCenters = rawMatches.map(\.token.centerY)
        let bestCenter = candidateCenters.max { lhs, rhs in
            let lhsCount = rawMatches.filter { abs($0.token.centerY - lhs) <= yTolerance }.count
            let rhsCount = rawMatches.filter { abs($0.token.centerY - rhs) <= yTolerance }.count
            return lhsCount < rhsCount
        } ?? rawMatches[0].token.centerY

        var bestByCanonicalCenter: [Int: HeaderAnchorMatch] = [:]
        for match in rawMatches where abs(match.token.centerY - bestCenter) <= yTolerance {
            let key = Int((match.canonicalCenterX * 1000).rounded())
            if let existing = bestByCanonicalCenter[key], existing.token.confidence >= match.token.confidence {
                continue
            }
            bestByCanonicalCenter[key] = match
        }
        return bestByCanonicalCenter.values.sorted { $0.canonicalCenterX < $1.canonicalCenterX }
    }

    private static func adaptiveTallyCrop(in normalizedImage: CGImage) async throws -> CGRect? {
        guard let fullPageVariant = try await SmartFishTicketSandboxV3OCR.recognizeVariant(
            from: normalizedImage,
            cropRect: nil,
            minimumTextHeight: 0.0032,
            customWords: tallyCustomWords,
            includeBinary: false,
            variantIndex: 0
        ) else {
            return nil
        }

        let matches = headerAnchorMatches(in: fullPageVariant.tokens, maximumHeaderTopY: 0.52)
        guard matches.count >= 3 else { return nil }
        let geometry = tableGeometry(in: fullPageVariant.tokens, maximumHeaderTopY: 0.52)
        guard geometry.matchedHeaderAnchorCount >= 3 else { return nil }

        let headerTop = matches.map(\.token.topY).min() ?? 0.16
        let headerBottom = matches.map(\.token.bottomY).max() ?? (headerTop + 0.04)
        let totalTop = fullPageVariant.tokens
            .filter { token in
                token.topY > headerBottom + 0.08
                    && normalized(token.text).hasPrefix("total")
            }
            .map(\.topY)
            .min()

        // Header OCR can underestimate the outer columns on sparse sheets because
        // the last recognized anchor is often SOLD WEIGHT rather than BRAILERS.
        // Keep enough horizontal context to retain both edge columns for cell OCR.
        let minX = max(0, geometry.xOffset + (0.01 * geometry.xScale) - 0.08)
        let maxX = min(1, geometry.xOffset + (0.995 * geometry.xScale) + 0.12)
        let minY = max(0, headerTop - 0.025)
        let estimatedBottom = totalTop.map { min(1, $0 + 0.10) } ?? min(1, minY + 0.54)
        guard maxX - minX >= 0.55, estimatedBottom - minY >= 0.25 else { return nil }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: estimatedBottom - minY)
    }

    private static func deduplicatedCropRects(_ cropRects: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for cropRect in cropRects {
            let isDuplicate = result.contains { existing in
                abs(existing.minX - cropRect.minX) < 0.008
                    && abs(existing.minY - cropRect.minY) < 0.008
                    && abs(existing.width - cropRect.width) < 0.015
                    && abs(existing.height - cropRect.height) < 0.015
            }
            if !isDuplicate {
                result.append(cropRect)
            }
        }
        return result
    }

    static func parse(
        images: [UIImage],
        startingPageIndex: Int = 1,
        expectedSummarySoldWeight: Int? = nil
    ) async throws -> SmartFishTicketTallyExtractionDraft? {
        guard !images.isEmpty else {
            throw SmartFishTicketExtractorError.noImages
        }
        return try await parse(
            pageCount: images.count,
            startingPageIndex: startingPageIndex,
            expectedSummarySoldWeight: expectedSummarySoldWeight,
            loadImage: { images.indices.contains($0) ? images[$0] : nil }
        )
    }

    static func parse(
        imageFilenames: [String],
        startingPageIndex: Int = 1,
        expectedSummarySoldWeight: Int? = nil
    ) async throws -> SmartFishTicketTallyExtractionDraft? {
        guard !imageFilenames.isEmpty else {
            throw SmartFishTicketExtractorError.noImages
        }

        return try await parse(
            pageCount: imageFilenames.count,
            startingPageIndex: startingPageIndex,
            expectedSummarySoldWeight: expectedSummarySoldWeight,
            loadImage: { offset in
                guard imageFilenames.indices.contains(offset) else { return nil }
                return SmartFishTicketStorage.loadOCRImage(
                    named: imageFilenames[offset],
                    maxDimension: SmartFishTicketOCRProfile.tallyMaxDimension
                )
            }
        )
    }

    private static func parse(
        pageCount: Int,
        startingPageIndex: Int,
        expectedSummarySoldWeight: Int?,
        loadImage: (Int) -> UIImage?
    ) async throws -> SmartFishTicketTallyExtractionDraft? {
        let startedAt = ProcessInfo.processInfo.systemUptime
        SmartFishTicketOCRDiagnostics.started(kind: "tally", pageCount: pageCount)
        defer {
            SmartFishTicketOCRDiagnostics.completed(
                kind: "tally",
                pageCount: pageCount,
                startedAt: startedAt
            )
        }

        var candidatesByPage: [[PageCandidate]] = []
        var warnings: [String] = []

        for offset in 0..<pageCount {
            try Task.checkCancellation()
            let pageIndex = startingPageIndex + offset
            SmartFishTicketOCRDiagnostics.page(kind: "tally", pageIndex: pageIndex, stage: "scan-start")
            var pageImage: UIImage? = autoreleasepool { loadImage(offset) }
            guard let image = pageImage else {
                warnings.append("Tally page \(pageIndex + 1) could not be prepared for OCR.")
                candidatesByPage.append([])
                continue
            }

            let perPageExpectedWeight = pageCount == 1 ? expectedSummarySoldWeight : nil
            let candidates = try await parsePageCandidates(
                image: image,
                pageIndex: pageIndex,
                expectedSummarySoldWeight: perPageExpectedWeight
            )
            candidatesByPage.append(candidates)
            if candidates.isEmpty {
                warnings.append("No tally rows were confidently parsed on page \(pageIndex + 1).")
            }

            pageImage = nil
            SmartLogbookImageRendering.clearCaches()
            SmartFishTicketOCRDiagnostics.page(kind: "tally", pageIndex: pageIndex, stage: "scan-end")
        }

        let selectedCandidates = selectCandidateCombination(
            from: candidatesByPage.filter { !$0.isEmpty },
            expectedSummarySoldWeight: expectedSummarySoldWeight
        )
        guard !selectedCandidates.isEmpty else {
            throw SmartFishTicketExtractorError.noRenderableImages
        }

        var combinedRows: [ParsedRow] = []
        var sourcePageIndexes: [Int] = []

        for selectedCandidate in selectedCandidates {
            try Task.checkCancellation()
            SmartFishTicketOCRDiagnostics.page(
                kind: "tally",
                pageIndex: selectedCandidate.pageIndex,
                stage: "enrichment-start"
            )
            sourcePageIndexes.append(selectedCandidate.pageIndex)
            combinedRows.append(contentsOf: selectedCandidate.rows)
            warnings.append(contentsOf: selectedCandidate.warnings)

            SmartLogbookImageRendering.clearCaches()
            SmartFishTicketOCRDiagnostics.page(
                kind: "tally",
                pageIndex: selectedCandidate.pageIndex,
                stage: "enrichment-end"
            )
        }

        guard !combinedRows.isEmpty else { return nil }

        if let expectedSummarySoldWeight {
            let parsedTotal = combinedRows.reduce(0) { $0 + $1.soldWeight }
            if parsedTotal != expectedSummarySoldWeight {
                warnings.append("Tally row Post Tare total (\(parsedTotal)) did not exactly match the first-page Sold Weight (\(expectedSummarySoldWeight)).")
            }
        }

        let draftRows = combinedRows.map { row in
            SmartFishTicketTallyRow(
                speciesText: row.species,
                deliveryConditionText: row.deliveryCondition,
                soldWeightText: row.soldWeight > 0 ? SmartLogbookFormat.number(row.soldWeight) : "",
                brailersText: row.brailers.map(String.init) ?? ""
            )
        }

        return SmartFishTicketTallyExtractionDraft(
            rows: draftRows,
            sourcePageIndexes: sourcePageIndexes,
            warnings: deduplicatedWarnings(warnings)
        )
    }

    private static func parsePageCandidates(
        image: UIImage,
        pageIndex: Int,
        expectedSummarySoldWeight: Int?
    ) async throws -> [PageCandidate] {
        guard let preparedImage = SmartFishTicketOCRImageFactory.normalizedImage(
            from: image,
            maxDimension: SmartFishTicketOCRProfile.tallyMaxDimension
        ) else {
            return []
        }
        let normalizedImage = uprightTallyImage(preparedImage)

        var candidates: [PageCandidate] = []
        var cropRects = tallyCrops

        if let adaptiveCrop = try await adaptiveTallyCrop(in: normalizedImage) {
            cropRects.insert(adaptiveCrop, at: 0)
        }
        cropRects = deduplicatedCropRects(cropRects)

        cropLoop: for cropRect in cropRects {
            var detectedRowIntervals: [RowInterval] = []
            for variantIndex in 0..<SmartFishTicketOCRProfile.tallyVariantLimit {
                try Task.checkCancellation()
                guard let recognizedVariant = try await SmartFishTicketSandboxV3OCR.recognizeVariant(
                    from: normalizedImage,
                    cropRect: cropRect,
                    minimumTextHeight: 0.0035,
                    customWords: tallyCustomWords,
                    includeBinary: SmartFishTicketOCRProfile.includeBinaryVariants,
                    variantIndex: variantIndex
                ) else {
                    continue
                }

                if detectedRowIntervals.isEmpty, variantIndex <= 1 {
                    let rectangles = try await SmartFishTicketSandboxV3OCR.detectRectangles(
                        in: recognizedVariant.cgImage
                    )
                    detectedRowIntervals = gridRowIntervals(
                        from: rectangles,
                        tokens: recognizedVariant.tokens,
                        geometry: tableGeometry(in: recognizedVariant.tokens)
                    )
                }

                if let pageCandidate = makeCandidate(
                    recognizedVariant,
                    cropRect: cropRect,
                    variantIndex: variantIndex,
                    pageIndex: pageIndex,
                    expectedSummarySoldWeight: expectedSummarySoldWeight,
                    detectedRowIntervals: detectedRowIntervals
                ) {
                    insertCandidate(
                        pageCandidate,
                        into: &candidates,
                        expectedSummarySoldWeight: expectedSummarySoldWeight
                    )

                }
            }

            if let best = candidates.first,
               best.isStrong(expectedSummarySoldWeight: expectedSummarySoldWeight),
               candidates.count >= SmartFishTicketOCRProfile.tallyVariantLimit {
                break cropLoop
            }
        }

        var enrichedCandidates: [PageCandidate] = []
        for candidate in candidates.prefix(2) {
            try Task.checkCancellation()
            let enriched = try await enrichCandidate(
                candidate,
                normalizedImage: normalizedImage,
                expectedSummarySoldWeight: expectedSummarySoldWeight
            )
            SmartFishTicketOCRDiagnostics.tallyCandidate(
                pageIndex: enriched.pageIndex,
                variant: enriched.variantTag,
                headerAnchors: enriched.tableGeometry.matchedHeaderAnchorCount,
                rowCount: enriched.rows.count,
                unsupportedRows: enriched.unsupportedRowCount,
                score: enriched.score(expectedSummarySoldWeight: expectedSummarySoldWeight)
            )
            insertCandidate(
                enriched,
                into: &enrichedCandidates,
                expectedSummarySoldWeight: expectedSummarySoldWeight
            )
        }
        return enrichedCandidates.isEmpty ? candidates : enrichedCandidates
    }

    private static func makeCandidate(
        _ recognizedVariant: SmartFishTicketSandboxV3OCR.RecognizedVariant,
        cropRect: CGRect,
        variantIndex: Int,
        pageIndex: Int,
        expectedSummarySoldWeight: Int?,
        detectedRowIntervals: [RowInterval] = []
    ) -> PageCandidate? {
        let normalizedText = normalized(recognizedVariant.text)
        let headerHits = headerPhrases.reduce(0) { partial, phrase in
            partial + (normalizedText.contains(normalized(phrase)) ? 1 : 0)
        }

        guard headerHits >= 2 || !recognizedVariant.tokens.isEmpty else {
            return nil
        }

        let tableGeometry = tableGeometry(in: recognizedVariant.tokens)
        let canonicalTokens = recognizedVariant.tokens.map(tableGeometry.canonicalized)

        let footerTopY = footerTopY(in: canonicalTokens)
        let headerFloorY = headerBottomY(in: canonicalTokens)
        let clusters = weightClusters(
            in: canonicalTokens,
            footerTopY: footerTopY,
            headerBottomY: headerFloorY,
            expectedSummarySoldWeight: expectedSummarySoldWeight
        )
        var completedClusters = maybeAddSmallTail(
            to: clusters,
            from: canonicalTokens,
            footerTopY: footerTopY,
            expectedSummarySoldWeight: expectedSummarySoldWeight
        )

        var warnings: [String] = []

        let countAnchoredClusters = addMissingRowAnchorsFromCounts(
            to: completedClusters,
            from: canonicalTokens,
            footerTopY: footerTopY,
            headerBottomY: headerFloorY,
            expectedSummarySoldWeight: expectedSummarySoldWeight
        )
        if countAnchoredClusters.count > completedClusters.count {
            warnings.append("Recovered one or more missing tally row anchors from the count column.")
        }
        completedClusters = countAnchoredClusters

        let gridAnchoredClusters = addGridRowAnchors(
            to: completedClusters,
            intervals: detectedRowIntervals,
            tokens: canonicalTokens,
            expectedSummarySoldWeight: expectedSummarySoldWeight
        )
        if gridAnchoredClusters.count > completedClusters.count {
            warnings.append("Detected additional tally rows from the printed table grid.")
        }
        completedClusters = gridAnchoredClusters

        let recoveredClusterResult = recoverMissingWeightCluster(
            in: completedClusters,
            from: canonicalTokens,
            footerTopY: footerTopY,
            expectedSummarySoldWeight: expectedSummarySoldWeight
        )
        if recoveredClusterResult.clusters.count > completedClusters.count {
            warnings.append("Recovered a missing tally pick so the Post Tare can match the first-page Sold Weight.")
        }
        completedClusters = recoveredClusterResult.clusters
        warnings.append(contentsOf: recoveredClusterResult.warnings)

        let inferredClusterResult = inferSingleMissingWeight(
            in: completedClusters,
            tokens: canonicalTokens,
            expectedSummarySoldWeight: expectedSummarySoldWeight
        )
        completedClusters = inferredClusterResult.clusters
        warnings.append(contentsOf: inferredClusterResult.warnings)

        guard !completedClusters.isEmpty else { return nil }

        let rowIntervals = rowIntervals(
            from: completedClusters,
            tokens: canonicalTokens,
            footerTopY: footerTopY,
            headerBottomY: headerFloorY
        )
        guard rowIntervals.count == completedClusters.count else { return nil }

        var parsedRows: [ParsedRow] = []
        parsedRows.reserveCapacity(completedClusters.count)

        for (cluster, interval) in zip(completedClusters, rowIntervals) {
            let speciesText = textInColumns(
                canonicalTokens,
                xRange: speciesColumnRange,
                interval: interval
            )
            let deliveryConditionText = textInColumns(
                canonicalTokens,
                xRange: deliveryConditionColumnRange,
                interval: interval
            )

            let leftText = textInColumns(
                canonicalTokens,
                xRange: boundaryRatios[0]...boundaryRatios[2],
                interval: interval
            )

            let resolvedWeight = resolvedWeight(
                in: canonicalTokens,
                interval: interval,
                fallback: cluster.soldWeight
            )
            let boundedWeight: Int
            if let expectedSummarySoldWeight,
               resolvedWeight > expectedSummarySoldWeight {
                boundedWeight = cluster.soldWeight
            } else {
                boundedWeight = resolvedWeight
            }

            let brailers = brailersFromTokens(canonicalTokens, interval: interval)

            parsedRows.append(
                ParsedRow(
                    species: normalizeSpecies(speciesText.isEmpty ? leftText : speciesText),
                    deliveryCondition: normalizeCondition(deliveryConditionText.isEmpty ? leftText : deliveryConditionText),
                    soldWeight: boundedWeight,
                    brailers: brailers,
                    isInferredWeight: cluster.isInferredWeight
                )
            )
        }

        // Preserve direct OCR provenance until per-cell enrichment finishes. Filling
        // defaults here makes an empty grid row look semantically supported.
        let normalizedRows = parsedRows
        let rowSum = normalizedRows.reduce(0) { $0 + max(0, $1.soldWeight) }
        let evidence = candidateEvidence(
            rows: normalizedRows,
            centers: completedClusters.map(\.centerY),
            tokens: canonicalTokens
        )

        return PageCandidate(
            pageIndex: pageIndex,
            cropRect: cropRect,
            variantIndex: variantIndex,
            variantTag: recognizedVariant.variantTag,
            tableGeometry: tableGeometry,
            rows: normalizedRows,
            clusterSum: rowSum,
            headerHits: headerHits,
            rowEvidenceScore: evidence.score,
            unsupportedRowCount: evidence.unsupportedRowCount,
            rowIntervals: rowIntervals,
            tokens: canonicalTokens,
            warnings: deduplicatedWarnings(warnings),
        )
    }

    private struct CombinationState {
        let candidates: [PageCandidate]
        let totalWeight: Int
        let evidenceScore: Int
    }

    private static func insertCandidate(
        _ candidate: PageCandidate,
        into candidates: inout [PageCandidate],
        expectedSummarySoldWeight: Int?
    ) {
        if let existingIndex = candidates.firstIndex(where: { $0.signature == candidate.signature }) {
            if candidate.score(expectedSummarySoldWeight: expectedSummarySoldWeight)
                > candidates[existingIndex].score(expectedSummarySoldWeight: expectedSummarySoldWeight) {
                candidates[existingIndex] = candidate
            }
        } else {
            candidates.append(candidate)
        }

        candidates.sort {
            $0.score(expectedSummarySoldWeight: expectedSummarySoldWeight)
                > $1.score(expectedSummarySoldWeight: expectedSummarySoldWeight)
        }
        if candidates.count > maxPageCandidates {
            candidates.removeLast(candidates.count - maxPageCandidates)
        }
    }

    private static func selectCandidateCombination(
        from candidatesByPage: [[PageCandidate]],
        expectedSummarySoldWeight: Int?
    ) -> [PageCandidate] {
        guard !candidatesByPage.isEmpty else { return [] }

        var states = [CombinationState(candidates: [], totalWeight: 0, evidenceScore: 0)]
        for pageCandidates in candidatesByPage {
            var nextStates: [CombinationState] = []
            nextStates.reserveCapacity(states.count * pageCandidates.count)
            for state in states {
                for candidate in pageCandidates {
                    nextStates.append(
                        CombinationState(
                            candidates: state.candidates + [candidate],
                            totalWeight: state.totalWeight + candidate.clusterSum,
                            evidenceScore: state.evidenceScore + candidate.score(expectedSummarySoldWeight: nil)
                        )
                    )
                }
            }

            nextStates.sort {
                combinationScore($0, expectedSummarySoldWeight: expectedSummarySoldWeight)
                    > combinationScore($1, expectedSummarySoldWeight: expectedSummarySoldWeight)
            }
            if nextStates.count > maxCombinationStates {
                nextStates.removeLast(nextStates.count - maxCombinationStates)
            }
            states = nextStates
        }

        return states.max {
            combinationScore($0, expectedSummarySoldWeight: expectedSummarySoldWeight)
                < combinationScore($1, expectedSummarySoldWeight: expectedSummarySoldWeight)
        }?.candidates ?? []
    }

    private static func combinationScore(
        _ state: CombinationState,
        expectedSummarySoldWeight: Int?
    ) -> Int {
        guard let expectedSummarySoldWeight else { return state.evidenceScore }
        let delta = abs(expectedSummarySoldWeight - state.totalWeight)
        let exactBonus = delta == 0 ? 3600 : 0
        let nearBonus = max(0, 1400 - (delta * 20))
        let overagePenalty = state.totalWeight > expectedSummarySoldWeight ? delta * 25 : 0
        return state.evidenceScore + exactBonus + nearBonus - overagePenalty
    }

    private static func enrichCandidate(
        _ candidate: PageCandidate,
        normalizedImage: CGImage,
        expectedSummarySoldWeight: Int?
    ) async throws -> PageCandidate {
        guard let preparedVariant = SmartFishTicketSandboxV3OCR.preparedVariant(
            from: normalizedImage,
            cropRect: candidate.cropRect,
            includeBinary: SmartFishTicketOCRProfile.includeBinaryVariants,
            variantIndex: candidate.variantIndex
        ) else {
            return candidate
        }

        var enrichedRows = candidate.rows
        var enrichedWarnings = candidate.warnings
        for index in enrichedRows.indices where candidate.rowIntervals.indices.contains(index) {
            try Task.checkCancellation()
            let interval = candidate.rowIntervals[index]

            if enrichedRows[index].species.isEmpty || enrichedRows[index].deliveryCondition.isEmpty {
                let leftRect = CGRect(
                    x: 0,
                    y: max(0, interval.topY - 0.012),
                    width: 0.30,
                    height: min(1, interval.bottomY + 0.012) - max(0, interval.topY - 0.012)
                )

                if let leftCropImage = SmartFishTicketSandboxV3OCR.cropCGImage(
                    preparedVariant.cgImage,
                    topLeftRect: leftRect
                ) {
                    let enlargedLeftCrop = SmartFishTicketOCRImageFactory.upscaledIfNeeded(leftCropImage)
                    let leftText = try await SmartFishTicketSandboxV3OCR.recognizeJoinedText(
                        in: enlargedLeftCrop,
                        minimumTextHeight: 0.010,
                        customWords: ["KINGS", "SALMON", "WHOLE", "ROUND", "BLED", "410", "460"],
                        usesLanguageCorrection: true
                    )
                    if enrichedRows[index].species.isEmpty {
                        enrichedRows[index].species = normalizeSpecies(leftText)
                    }
                    if enrichedRows[index].deliveryCondition.isEmpty {
                        enrichedRows[index].deliveryCondition = normalizeCondition(leftText)
                    }
                }
            }

            let canonicalPostTareRect = CGRect(
                x: max(0, boundaryRatios[5] - 0.012),
                y: max(0, interval.topY - 0.010),
                width: min(1, boundaryRatios[6] + 0.018) - max(0, boundaryRatios[5] - 0.012),
                height: min(1, interval.bottomY + 0.010) - max(0, interval.topY - 0.010)
            )
            let canonicalSoldWeightRect = CGRect(
                x: max(0, boundaryRatios[8] - 0.012),
                y: max(0, interval.topY - 0.010),
                width: min(1, boundaryRatios[9] + 0.018) - max(0, boundaryRatios[8] - 0.012),
                height: min(1, interval.bottomY + 0.010) - max(0, interval.topY - 0.010)
            )
            let preferredWeight = enrichedRows[index].soldWeight
            let postTareWeight = try await numericCellValue(
                in: preparedVariant.cgImage,
                actualRect: candidate.tableGeometry.actualRect(forCanonicalRect: canonicalPostTareRect),
                preferredValue: preferredWeight,
                maximumValue: expectedSummarySoldWeight
            )
            let soldWeight: Int?
            if let postTareWeight {
                soldWeight = postTareWeight
            } else {
                soldWeight = try await numericCellValue(
                    in: preparedVariant.cgImage,
                    actualRect: candidate.tableGeometry.actualRect(forCanonicalRect: canonicalSoldWeightRect),
                    preferredValue: preferredWeight,
                    maximumValue: expectedSummarySoldWeight
                )
            }
            if let soldWeight, soldWeight > 0 {
                enrichedRows[index].soldWeight = soldWeight
                enrichedRows[index].isInferredWeight = false
            }

            let shouldVerifyBrailer = enrichedRows[index].brailers == nil || enrichedRows.count <= 2
            if shouldVerifyBrailer,
               !(enrichedRows[index].species == "410 Kings" && enrichedRows[index].soldWeight < 50) {
                try Task.checkCancellation()
                let canonicalRightRect = CGRect(
                    x: 0.92,
                    y: max(0, interval.topY - 0.010),
                    width: 0.08,
                    height: min(1, interval.bottomY + 0.010) - max(0, interval.topY - 0.010)
                )
                if let rightCropImage = SmartFishTicketSandboxV3OCR.cropCGImage(
                    preparedVariant.cgImage,
                    topLeftRect: canonicalRightRect
                ) {
                    enrichedRows[index].brailers = try await brailerCellValue(
                        in: rightCropImage,
                        existingValue: enrichedRows[index].brailers
                    )
                }
            }
        }

        if enrichedRows.count == 1 {
            let pageText = candidate.tokens.map(\.text).joined(separator: " ")
            if enrichedRows[0].species.isEmpty {
                enrichedRows[0].species = normalizeSpecies(pageText)
            }
            if enrichedRows[0].deliveryCondition.isEmpty {
                enrichedRows[0].deliveryCondition = normalizeCondition(pageText)
            }
            if enrichedRows[0].brailers == nil {
                enrichedRows[0].brailers = candidate.tokens
                    .filter { token in
                        token.centerX >= 0.65
                            && token.text.trimmingCharacters(in: .whitespacesAndNewlines)
                                .range(of: #"^[1-4]$"#, options: .regularExpression) != nil
                    }
                    .max(by: { $0.centerX < $1.centerX })
                    .flatMap { Int($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
        }

        let meaningfulIndexes = enrichedRows.indices.filter { index in
            guard candidate.rowIntervals.indices.contains(index),
                  candidate.rows.indices.contains(index) else { return false }
            let row = enrichedRows[index]
            if let expectedSummarySoldWeight,
               row.soldWeight > expectedSummarySoldWeight {
                return false
            }
            let interval = candidate.rowIntervals[index]
            let centerY = (interval.topY + interval.bottomY) / 2
            let hasSemanticCell = !row.species.isEmpty || !row.deliveryCondition.isEmpty
            let hasRawRowEvidence = candidate.rows[index].soldWeight > 0
                || rowCueScore(near: centerY, in: candidate.tokens, tolerance: 0.026) >= 2
                || hasNearbyCountToken(near: centerY, in: candidate.tokens, tolerance: 0.026)
            if row.soldWeight > 0 {
                return hasSemanticCell || hasRawRowEvidence
            }
            return hasSemanticCell && hasRawRowEvidence
        }
        enrichedRows = meaningfulIndexes.map { enrichedRows[$0] }
        var enrichedIntervals = meaningfulIndexes.compactMap { index in
            candidate.rowIntervals.indices.contains(index) ? candidate.rowIntervals[index] : nil
        }

        if let expectedSummarySoldWeight,
           let retainedIndexes = exactWeightSubsetIndexes(
               in: enrichedRows,
               expectedTotal: expectedSummarySoldWeight
           ), retainedIndexes.count < enrichedRows.count {
            enrichedRows = retainedIndexes.map { enrichedRows[$0] }
            enrichedIntervals = retainedIndexes.compactMap { index in
                enrichedIntervals.indices.contains(index) ? enrichedIntervals[index] : nil
            }
            enrichedWarnings.append("Ignored OCR rows outside the exact tally total after the individual rows reconciled to the first page.")
        }

        if let expectedSummarySoldWeight {
            let missingIndexes = enrichedRows.indices.filter { enrichedRows[$0].soldWeight <= 0 }
            let knownWeight = enrichedRows.reduce(0) { $0 + max(0, $1.soldWeight) }
            if missingIndexes.count == 1,
               knownWeight < expectedSummarySoldWeight {
                let missingIndex = missingIndexes[0]
                enrichedRows[missingIndex].soldWeight = expectedSummarySoldWeight - knownWeight
                enrichedRows[missingIndex].isInferredWeight = true
                enrichedWarnings.append("Inferred one missing tally-row weight after cell OCR. Confirm this row before applying.")
            }
        }

        if enrichedRows.isEmpty {
            return candidate
        }

        enrichedRows = fillRowDefaults(enrichedRows)
        let centers = enrichedIntervals.map { ($0.topY + $0.bottomY) / 2 }
        let evidence = candidateEvidence(rows: enrichedRows, centers: centers, tokens: candidate.tokens)
        return PageCandidate(
            pageIndex: candidate.pageIndex,
            cropRect: candidate.cropRect,
            variantIndex: candidate.variantIndex,
            variantTag: candidate.variantTag,
            tableGeometry: candidate.tableGeometry,
            rows: enrichedRows,
            clusterSum: enrichedRows.reduce(0) { $0 + max(0, $1.soldWeight) },
            headerHits: candidate.headerHits,
            rowEvidenceScore: evidence.score,
            unsupportedRowCount: evidence.unsupportedRowCount,
            rowIntervals: enrichedIntervals,
            tokens: candidate.tokens,
            warnings: deduplicatedWarnings(enrichedWarnings)
        )
    }

    private static func numericCellValue(
        in cgImage: CGImage,
        actualRect: CGRect,
        preferredValue: Int,
        maximumValue: Int?
    ) async throws -> Int? {
        guard let cellImage = SmartFishTicketSandboxV3OCR.cropCGImage(
            cgImage,
            topLeftRect: actualRect
        ) else {
            return nil
        }

        let candidates = try await SmartFishTicketSandboxV3OCR.recognizeTextCandidates(
            in: cellImage,
            minimumTextHeight: 0.015,
            customWords: [],
            usesLanguageCorrection: false,
            candidateLimit: 3
        )
        let scoredCandidates = candidates.compactMap { candidate -> (value: Int, score: Int)? in
            guard let value = parseNumberToken(candidate.text), value > 0 else { return nil }
            if let maximumValue, maximumValue > 0, value > maximumValue {
                return nil
            }
            if preferredValue > 0, value != preferredValue {
                let preferredDigitCount = String(preferredValue).count
                let candidateDigitCount = String(value).count
                guard candidateDigitCount >= preferredDigitCount else { return nil }
            }
            var score = Int((candidate.confidence * 100).rounded())
                + numericTokenScore(candidate.text, value: value)
            if preferredValue > 0, value == preferredValue {
                score += 120
            }
            return (value, score)
        }

        if let bestCandidate = scoredCandidates.max(by: { lhs, rhs in lhs.score < rhs.score }) {
            return bestCandidate.value
        }
        if preferredValue > 0 {
            if let maximumValue, maximumValue > 0, preferredValue > maximumValue {
                return nil
            }
            return preferredValue
        }
        return nil
    }

    private static func exactWeightSubsetIndexes(
        in rows: [ParsedRow],
        expectedTotal: Int
    ) -> [Int]? {
        guard expectedTotal > 0, !rows.isEmpty, rows.count <= 12 else { return nil }

        var bestIndexes: [Int]?
        var bestScore = Int.min
        let stateCount = 1 << rows.count
        for mask in 1..<stateCount {
            var indexes: [Int] = []
            var total = 0
            var evidenceScore = 0
            for index in rows.indices where mask & (1 << index) != 0 {
                let row = rows[index]
                guard row.soldWeight > 0 else { continue }
                indexes.append(index)
                total += row.soldWeight
                evidenceScore += 1_000
                if !row.species.isEmpty { evidenceScore += 120 }
                if !row.deliveryCondition.isEmpty { evidenceScore += 100 }
                if row.brailers != nil { evidenceScore += 40 }
                if row.isInferredWeight { evidenceScore -= 80 }
            }
            guard total == expectedTotal else { continue }
            if evidenceScore > bestScore {
                bestScore = evidenceScore
                bestIndexes = indexes
            }
        }
        return bestIndexes
    }

    private static func brailerCellValue(
        in cellImage: CGImage,
        existingValue: Int?
    ) async throws -> Int? {
        var votes: [(value: Int, confidence: Float)] = []
        for variantIndex in 0..<3 {
            try Task.checkCancellation()
            guard let variant = SmartFishTicketOCRImageFactory.variant(
                from: cellImage,
                includeBinary: true,
                at: variantIndex
            ) else {
                continue
            }
            let candidates = try await SmartFishTicketSandboxV3OCR.recognizeTextCandidates(
                in: variant.cgImage,
                minimumTextHeight: 0.012,
                customWords: ["1", "2", "3", "4"],
                usesLanguageCorrection: false,
                candidateLimit: 3
            )
            if let vote = candidates.lazy.compactMap({ candidate -> (Int, Float)? in
                guard let value = brailersFromText(candidate.text) else { return nil }
                return (value, candidate.confidence)
            }).first {
                votes.append((value: vote.0, confidence: vote.1))
            }
        }

        let groupedVotes = Dictionary(grouping: votes, by: \.value)
        if let majority = groupedVotes
            .map({ value, entries in
                (value: value, count: entries.count, confidence: entries.reduce(Float(0)) { $0 + $1.confidence })
            })
            .sorted(by: { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.confidence > rhs.confidence
            })
            .first,
           majority.count >= 2 {
            return majority.value
        }
        if let existingValue, votes.contains(where: { $0.value == existingValue }) {
            return existingValue
        }
        return votes.max(by: { $0.confidence < $1.confidence })?.value ?? existingValue
    }

    private static func uprightTallyImage(_ cgImage: CGImage) -> CGImage {
        guard cgImage.width > cgImage.height else { return cgImage }
        let orientedImage = CIImage(cgImage: cgImage).oriented(.right)
        let extent = orientedImage.extent.integral
        guard !extent.isEmpty else { return cgImage }
        return SmartLogbookImageRendering.sharedCIContext.createCGImage(
            orientedImage,
            from: extent
        ) ?? cgImage
    }

    private static func candidateEvidence(
        rows: [ParsedRow],
        centers: [CGFloat],
        tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken]
    ) -> (score: Int, unsupportedRowCount: Int) {
        var score = 0
        var unsupportedRowCount = 0

        for (index, row) in rows.enumerated() {
            guard centers.indices.contains(index) else {
                unsupportedRowCount += 1
                continue
            }
            let centerY = centers[index]
            let tolerance: CGFloat = 0.026
            let cueScore = rowCueScore(near: centerY, in: tokens, tolerance: tolerance)
            let hasCount = hasNearbyCountToken(near: centerY, in: tokens, tolerance: tolerance)
            let hasWeight = hasNearbyWeightToken(near: centerY, in: tokens, tolerance: tolerance)
            let hasSpeciesToken = tokens.contains { token in
                speciesColumnRange.contains(token.centerX)
                    && abs(token.centerY - centerY) <= tolerance
                    && !normalizeSpecies(token.text).isEmpty
            }
            let hasConditionToken = tokens.contains { token in
                deliveryConditionColumnRange.contains(token.centerX)
                    && abs(token.centerY - centerY) <= tolerance
                    && !normalizeCondition(token.text).isEmpty
            }

            var rowScore = cueScore * 22
            if row.soldWeight > 0 { rowScore += 110 }
            if hasWeight { rowScore += 70 }
            if hasCount { rowScore += 45 }
            if hasSpeciesToken || !row.species.isEmpty { rowScore += 70 }
            if hasConditionToken || !row.deliveryCondition.isEmpty { rowScore += 55 }
            if row.brailers != nil { rowScore += 30 }
            score += rowScore

            let hasSemanticCue = cueScore >= 2
                || hasSpeciesToken
                || hasConditionToken
                || !row.species.isEmpty
                || !row.deliveryCondition.isEmpty
            if row.soldWeight <= 0 || (!hasSemanticCue && !hasCount) {
                unsupportedRowCount += 1
            }
        }

        return (score, unsupportedRowCount)
    }

    private struct RowInterval {
        let topY: CGFloat
        let bottomY: CGFloat
    }

    private static func weightClusters(
        in tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        footerTopY: CGFloat,
        headerBottomY: CGFloat?,
        expectedSummarySoldWeight: Int?
    ) -> [Cluster] {
        let preferred = clusters(
            in: tokens,
            xRange: postTareColumnRange,
            footerTopY: footerTopY,
            headerBottomY: headerBottomY,
            expectedSummarySoldWeight: expectedSummarySoldWeight
        )
        let fallback = clusters(
            in: tokens,
            xRange: soldWeightColumnRange,
            footerTopY: footerTopY,
            headerBottomY: headerBottomY,
            expectedSummarySoldWeight: expectedSummarySoldWeight
        )

        return mergedClusters(primary: preferred, fallback: fallback)
    }

    private static func clusters(
        in tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        xRange: ClosedRange<CGFloat>,
        footerTopY: CGFloat,
        headerBottomY: CGFloat?,
        expectedSummarySoldWeight: Int?
    ) -> [Cluster] {
        let candidates = tokens.compactMap { token -> SmartFishTicketSandboxV3OCR.RecognizedToken? in
            guard xRange.contains(token.centerX) else { return nil }
            guard token.topY < footerTopY - 0.006 else { return nil }
            guard token.text.range(of: #"\d"#, options: .regularExpression) != nil else { return nil }
            guard let value = parseNumberToken(token.text) else { return nil }
            guard value >= 50 || looksLikeWeightToken(token.text, value: value) else { return nil }
            if let expectedSummarySoldWeight {
                guard value <= expectedSummarySoldWeight else { return nil }
                if value == expectedSummarySoldWeight {
                    if let headerBottomY, token.bottomY <= headerBottomY + 0.004 {
                        return nil
                    }
                    let tolerance = max(0.020, token.height * 1.8)
                    guard rowCueScore(near: token.centerY, in: tokens, tolerance: tolerance) >= 2
                        || hasNearbyCountToken(near: token.centerY, in: tokens, tolerance: tolerance) else {
                        return nil
                    }
                }
            }
            return token
        }
        .sorted { lhs, rhs in
            if lhs.centerY != rhs.centerY { return lhs.centerY < rhs.centerY }
            return lhs.minX < rhs.minX
        }

        guard !candidates.isEmpty else { return [] }

        let sortedHeights = candidates.map { $0.height }.sorted()
        let medianHeight = sortedHeights[sortedHeights.count / 2]
        let tolerance = max(0.014, medianHeight * 1.6)

        var clusteredTokens: [[SmartFishTicketSandboxV3OCR.RecognizedToken]] = []
        for candidate in candidates {
            if var lastCluster = clusteredTokens.last,
               let lastCenterY = lastCluster.last?.centerY,
               abs(candidate.centerY - lastCenterY) <= tolerance {
                lastCluster.append(candidate)
                clusteredTokens[clusteredTokens.count - 1] = lastCluster
            } else {
                clusteredTokens.append([candidate])
            }
        }

        return clusteredTokens.compactMap { clusterTokens -> Cluster? in
            let bestToken = clusterTokens.max { lhs, rhs in
                let lhsScore = numericTokenScore(lhs.text, value: parseNumberToken(lhs.text))
                let rhsScore = numericTokenScore(rhs.text, value: parseNumberToken(rhs.text))
                if lhsScore != rhsScore { return lhsScore < rhsScore }
                if lhs.confidence != rhs.confidence { return lhs.confidence < rhs.confidence }
                return (parseNumberToken(lhs.text) ?? 0) < (parseNumberToken(rhs.text) ?? 0)
            }
            guard let bestToken, let soldWeight = parseNumberToken(bestToken.text) else { return nil }
            let averageCenterY = clusterTokens.map(\.centerY).reduce(0, +) / CGFloat(clusterTokens.count)
            return Cluster(centerY: averageCenterY, soldWeight: soldWeight, tokens: clusterTokens)
        }
    }

    private static func mergedClusters(primary: [Cluster], fallback: [Cluster]) -> [Cluster] {
        guard !primary.isEmpty else { return fallback }
        guard !fallback.isEmpty else { return primary }

        let combinedHeights = (primary.flatMap(\.tokens) + fallback.flatMap(\.tokens)).map(\.height).sorted()
        let medianHeight = combinedHeights.isEmpty ? CGFloat(0.014) : combinedHeights[combinedHeights.count / 2]
        let tolerance = max(0.012, medianHeight * 1.1)

        var merged = primary

        for fallbackCluster in fallback {
            if let existingIndex = merged.firstIndex(where: { abs($0.centerY - fallbackCluster.centerY) <= tolerance }) {
                let existing = merged[existingIndex]
                let existingScore = numericTokenScore(existing.tokens.first?.text ?? "", value: existing.soldWeight)
                let fallbackScore = numericTokenScore(fallbackCluster.tokens.first?.text ?? "", value: fallbackCluster.soldWeight)
                let mergedTokens = existing.tokens + fallbackCluster.tokens
                let preferredWeight = fallbackScore > existingScore ? fallbackCluster.soldWeight : existing.soldWeight
                let preferredCenterY = (existing.centerY + fallbackCluster.centerY) / 2
                merged[existingIndex] = Cluster(centerY: preferredCenterY, soldWeight: preferredWeight, tokens: mergedTokens)
            } else {
                merged.append(fallbackCluster)
            }
        }

        return merged.sorted { $0.centerY < $1.centerY }
    }

    private static func maybeAddSmallTail(
        to clusters: [Cluster],
        from tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        footerTopY: CGFloat,
        expectedSummarySoldWeight: Int?
    ) -> [Cluster] {
        guard !clusters.isEmpty else { return clusters }

        let sortedHeights = tokens.map { $0.height }.sorted()
        let medianHeight = sortedHeights.isEmpty ? CGFloat(0.014) : sortedHeights[sortedHeights.count / 2]
        let tolerance = max(0.014, medianHeight * 1.6)

        var completedClusters = clusters
        let existingCenters = completedClusters.map(\.centerY)
        let lastClusterCenterY = completedClusters.last?.centerY ?? 0
        let expectedTailWeight = trailingSmallTailWeight(
            expectedSummarySoldWeight: expectedSummarySoldWeight,
            clusters: completedClusters
        )

        let smallTailCandidates = tokens.compactMap { token -> SmallTailCandidate? in
            guard postTareColumnRange.contains(token.centerX) || soldWeightColumnRange.contains(token.centerX) else { return nil }
            guard token.topY < footerTopY - 0.006 else { return nil }
            guard token.centerY > lastClusterCenterY + (tolerance * 0.35) else { return nil }
            guard existingCenters.contains(where: { abs($0 - token.centerY) <= tolerance }) == false else { return nil }
            guard let rawValue = parseNumberToken(token.text) else { return nil }
            guard let soldWeight = normalizedSmallTailWeight(rawValue, preferredValue: expectedTailWeight) else { return nil }

            let cueScore = rowCueScore(near: token.centerY, in: tokens, tolerance: tolerance)
            let matchesExpected = expectedTailWeight == soldWeight
            guard cueScore > 0 || matchesExpected else { return nil }

            var score = cueScore * 40
            if soldWeight < 50 { score += 140 }
            if matchesExpected { score += 360 }
            if rawValue == soldWeight { score += 110 }
            if looksLikeKingsRow(near: token.centerY, in: tokens, tolerance: tolerance) { score += 150 }
            if hasMatchingSmallWeightToken(
                near: token.centerY,
                value: soldWeight,
                in: tokens,
                tolerance: tolerance
            ) {
                score += 170
            }

            return SmallTailCandidate(
                centerY: token.centerY,
                soldWeight: soldWeight,
                score: score,
                tokens: [token]
            )
        }

        if let bestSmallTail = smallTailCandidates.max(by: { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return lhs.centerY < rhs.centerY
        }), bestSmallTail.score > 0 {
            completedClusters.append(
                Cluster(
                    centerY: bestSmallTail.centerY,
                    soldWeight: bestSmallTail.soldWeight,
                    tokens: bestSmallTail.tokens
                )
            )
            return completedClusters.sorted { $0.centerY < $1.centerY }
        }

        if let expectedTailWeight,
           let cueCenterY = trailingRowCueCenter(
                after: lastClusterCenterY,
                tokens: tokens,
                footerTopY: footerTopY,
                tolerance: tolerance
           ) {
            completedClusters.append(
                Cluster(
                    centerY: cueCenterY,
                    soldWeight: expectedTailWeight,
                    tokens: []
                )
            )
            return completedClusters.sorted { $0.centerY < $1.centerY }
        }

        return completedClusters.sorted { $0.centerY < $1.centerY }
    }

    private static func addMissingRowAnchorsFromCounts(
        to clusters: [Cluster],
        from tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        footerTopY: CGFloat,
        headerBottomY: CGFloat?,
        expectedSummarySoldWeight: Int?
    ) -> [Cluster] {
        if let expectedSummarySoldWeight {
            let currentSum = clusters.reduce(0) { $0 + max(0, $1.soldWeight) }
            guard currentSum < expectedSummarySoldWeight else { return clusters }
        }

        let rowAnchors = mergedClusters(
            primary: countClusters(
                in: tokens,
                footerTopY: footerTopY,
                headerBottomY: headerBottomY
            ),
            fallback: semanticRowClusters(
                in: tokens,
                footerTopY: footerTopY,
                headerBottomY: headerBottomY
            )
        )
        guard !rowAnchors.isEmpty else { return clusters }

        let combinedHeights = (clusters.flatMap(\.tokens) + rowAnchors.flatMap(\.tokens)).map(\.height).sorted()
        let medianHeight = combinedHeights.isEmpty ? CGFloat(0.014) : combinedHeights[combinedHeights.count / 2]
        let tolerance = max(0.014, medianHeight * 1.35)

        var augmented = clusters
        for anchor in rowAnchors {
            guard augmented.contains(where: { abs($0.centerY - anchor.centerY) <= tolerance }) == false else { continue }
            let cueScore = rowCueScore(near: anchor.centerY, in: tokens, tolerance: tolerance)
            let hasWeight = hasNearbyWeightToken(
                near: anchor.centerY,
                in: tokens,
                tolerance: tolerance * 1.25
            )
            let hasCount = hasNearbyCountToken(near: anchor.centerY, in: tokens, tolerance: tolerance)
            guard hasWeight || cueScore >= 4 || (expectedSummarySoldWeight != nil && hasCount && cueScore >= 2) else {
                continue
            }
            augmented.append(anchor)
        }

        return augmented.sorted { $0.centerY < $1.centerY }
    }

    private static func semanticRowClusters(
        in tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        footerTopY: CGFloat,
        headerBottomY: CGFloat?
    ) -> [Cluster] {
        let candidates = tokens.filter { token in
            guard token.centerX < postTareColumnRange.lowerBound else { return false }
            guard token.topY < footerTopY - 0.006 else { return false }
            if let headerBottomY, token.bottomY <= headerBottomY + 0.004 { return false }

            let value = normalized(token.text)
            return value.contains("410")
                || value.contains("460")
                || value.contains("king")
                || value.contains("salmon")
                || value.contains("mixed")
                || value.contains("whole")
                || value.contains("round")
                || value.contains("bled")
        }
        .sorted { $0.centerY < $1.centerY }

        guard !candidates.isEmpty else { return [] }
        let sortedHeights = candidates.map(\.height).sorted()
        let medianHeight = sortedHeights[sortedHeights.count / 2]
        let tolerance = max(0.016, medianHeight * 1.8)

        var groups: [[SmartFishTicketSandboxV3OCR.RecognizedToken]] = []
        for candidate in candidates {
            if let lastGroup = groups.last, !lastGroup.isEmpty {
                let lastCenter = lastGroup.map(\.centerY).reduce(0, +) / CGFloat(lastGroup.count)
                if abs(candidate.centerY - lastCenter) <= tolerance {
                    groups[groups.count - 1].append(candidate)
                    continue
                }
            }
            groups.append([candidate])
        }

        return groups.compactMap { group in
            guard !group.isEmpty else { return nil }
            let centerY = group.map(\.centerY).reduce(0, +) / CGFloat(group.count)
            guard rowCueScore(near: centerY, in: tokens, tolerance: tolerance) >= 4 else { return nil }
            return Cluster(centerY: centerY, soldWeight: 0, tokens: group)
        }
    }

    private static func countClusters(
        in tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        footerTopY: CGFloat,
        headerBottomY: CGFloat?
    ) -> [Cluster] {
        let candidates = tokens.compactMap { token -> SmartFishTicketSandboxV3OCR.RecognizedToken? in
            guard countColumnRange.contains(token.centerX) else { return nil }
            guard token.topY < footerTopY - 0.006 else { return nil }
            if let headerBottomY {
                guard token.bottomY > headerBottomY + 0.004 else { return nil }
            }
            guard token.text.range(of: #"\d"#, options: .regularExpression) != nil else { return nil }
            guard let value = parseNumberToken(token.text) else { return nil }
            guard value > 0, value <= 10000 else { return nil }
            return token
        }
        .sorted { lhs, rhs in
            if lhs.centerY != rhs.centerY { return lhs.centerY < rhs.centerY }
            return lhs.minX < rhs.minX
        }

        guard !candidates.isEmpty else { return [] }

        let sortedHeights = candidates.map(\.height).sorted()
        let medianHeight = sortedHeights[sortedHeights.count / 2]
        let tolerance = max(0.014, medianHeight * 1.5)

        var clusteredTokens: [[SmartFishTicketSandboxV3OCR.RecognizedToken]] = []
        for candidate in candidates {
            if var lastCluster = clusteredTokens.last,
               let lastCenterY = lastCluster.last?.centerY,
               abs(candidate.centerY - lastCenterY) <= tolerance {
                lastCluster.append(candidate)
                clusteredTokens[clusteredTokens.count - 1] = lastCluster
            } else {
                clusteredTokens.append([candidate])
            }
        }

        return clusteredTokens.compactMap { clusterTokens -> Cluster? in
            let averageCenterY = clusterTokens.map(\.centerY).reduce(0, +) / CGFloat(clusterTokens.count)
            return Cluster(centerY: averageCenterY, soldWeight: 0, tokens: clusterTokens)
        }
    }

    private static func gridRowIntervals(
        from rectangles: [CGRect],
        tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        geometry: TableGeometry
    ) -> [RowInterval] {
        guard !rectangles.isEmpty else { return [] }
        let canonicalTokens = tokens.map(geometry.canonicalized)
        let bodyTop = (headerBottomY(in: canonicalTokens) ?? 0.10) + 0.006
        let bodyBottom = footerTopY(in: canonicalTokens) - 0.006

        let cellRectangles = rectangles.filter { rect in
            guard rect.height >= 0.022, rect.height <= 0.18 else { return false }
            guard geometry.xScale > 0.001 else { return false }
            let canonicalMinX = (rect.minX - geometry.xOffset) / geometry.xScale
            let canonicalMaxX = (rect.maxX - geometry.xOffset) / geometry.xScale
            let canonicalWidth = canonicalMaxX - canonicalMinX
            return canonicalWidth >= 0.035
                && canonicalWidth <= 0.36
                && canonicalMaxX >= boundaryRatios[0]
                && canonicalMinX <= boundaryRatios[10]
                && rect.midY > bodyTop
                && rect.midY < bodyBottom
        }
        .sorted { $0.midY < $1.midY }
        guard !cellRectangles.isEmpty else { return [] }

        var groups: [[CGRect]] = []
        for rectangle in cellRectangles {
            if let last = groups.last, !last.isEmpty {
                let groupCenter = last.map(\.midY).reduce(0, +) / CGFloat(last.count)
                let tolerance = max(0.010, rectangle.height * 0.30)
                if abs(rectangle.midY - groupCenter) <= tolerance {
                    groups[groups.count - 1].append(rectangle)
                    continue
                }
            }
            groups.append([rectangle])
        }

        let intervals = groups.compactMap { group -> RowInterval? in
            let sortedMins = group.map(\.minY).sorted()
            let sortedMaxes = group.map(\.maxY).sorted()
            guard !sortedMins.isEmpty, !sortedMaxes.isEmpty else { return nil }
            let top = sortedMins[sortedMins.count / 2]
            let bottom = sortedMaxes[sortedMaxes.count / 2]
            let canonicalCoverage = group.reduce(CGFloat(0)) { partial, rect in
                partial + (rect.width / max(geometry.xScale, 0.001))
            }
            guard group.count >= 3 || canonicalCoverage >= 0.52 else { return nil }
            guard bottom - top >= 0.022, bottom - top <= 0.18 else { return nil }
            return RowInterval(topY: max(bodyTop, top), bottomY: min(bodyBottom, bottom))
        }
        .sorted { $0.topY < $1.topY }

        var deduplicated: [RowInterval] = []
        for interval in intervals {
            let center = (interval.topY + interval.bottomY) / 2
            if let existing = deduplicated.last {
                let existingCenter = (existing.topY + existing.bottomY) / 2
                if abs(existingCenter - center) <= 0.018 {
                    if interval.bottomY - interval.topY > existing.bottomY - existing.topY {
                        deduplicated[deduplicated.count - 1] = interval
                    }
                    continue
                }
            }
            deduplicated.append(interval)
        }
        return Array(deduplicated.prefix(12))
    }

    private static func addGridRowAnchors(
        to clusters: [Cluster],
        intervals: [RowInterval],
        tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        expectedSummarySoldWeight: Int?
    ) -> [Cluster] {
        guard !intervals.isEmpty else { return clusters }
        var augmented = clusters

        for interval in intervals {
            let centerY = (interval.topY + interval.bottomY) / 2
            let tolerance = max(0.018, (interval.bottomY - interval.topY) * 0.42)
            guard augmented.contains(where: { abs($0.centerY - centerY) <= tolerance }) == false else {
                continue
            }
            let rowTokens = tokens.filter { token in
                token.centerY >= interval.topY - 0.004
                    && token.centerY <= interval.bottomY + 0.004
                    && token.centerX >= boundaryRatios[0]
                    && token.centerX <= boundaryRatios[10]
            }
            guard !rowTokens.isEmpty else { continue }
            let cueScore = rowCueScore(near: centerY, in: tokens, tolerance: tolerance)
            let hasCount = hasNearbyCountToken(near: centerY, in: tokens, tolerance: tolerance)
            let hasWeight = hasNearbyWeightToken(near: centerY, in: tokens, tolerance: tolerance)
            let canBootstrapExpectedSingleRow = clusters.isEmpty
                && expectedSummarySoldWeight != nil
                && rowTokens.count >= 2
            guard hasWeight || (hasCount && cueScore >= 4) || canBootstrapExpectedSingleRow else { continue }
            augmented.append(Cluster(centerY: centerY, soldWeight: 0, tokens: rowTokens))
        }
        return augmented.sorted { $0.centerY < $1.centerY }
    }

    private static func recoverMissingWeightCluster(
        in clusters: [Cluster],
        from tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        footerTopY: CGFloat,
        expectedSummarySoldWeight: Int?
    ) -> (clusters: [Cluster], warnings: [String]) {
        guard !clusters.isEmpty else { return (clusters, []) }
        guard let expectedSummarySoldWeight else { return (clusters, []) }

        let currentSum = clusters.reduce(0) { $0 + max(0, $1.soldWeight) }
        let missingWeight = expectedSummarySoldWeight - currentSum
        guard missingWeight > 0 else { return (clusters, []) }

        let sortedHeights = tokens.map(\.height).sorted()
        let medianHeight = sortedHeights.isEmpty ? CGFloat(0.014) : sortedHeights[sortedHeights.count / 2]
        let tolerance = max(0.014, medianHeight * 1.6)
        let existingCenters = clusters.map(\.centerY)

        let candidates = tokens.compactMap { token -> RecoveryCandidate? in
            guard postTareColumnRange.contains(token.centerX) || soldWeightColumnRange.contains(token.centerX) else { return nil }
            guard token.topY < footerTopY - 0.006 else { return nil }
            guard existingCenters.contains(where: { abs($0 - token.centerY) <= tolerance }) == false else { return nil }
            guard let rawValue = parseNumberToken(token.text) else { return nil }

            let resolvedValue: Int?
            if missingWeight < 100 {
                resolvedValue = normalizedSmallTailWeight(rawValue, preferredValue: missingWeight)
            } else {
                resolvedValue = rawValue == missingWeight ? missingWeight : nil
            }

            guard resolvedValue == missingWeight else { return nil }

            let cueScore = rowCueScore(near: token.centerY, in: tokens, tolerance: tolerance)
            guard cueScore >= 2 || hasNearbyCountToken(near: token.centerY, in: tokens, tolerance: tolerance) else {
                return nil
            }

            var score = cueScore * 40
            if postTareColumnRange.contains(token.centerX) { score += 140 }
            if rawValue == missingWeight { score += 260 }
            if token.text.contains(",") { score += 50 }
            score += Int((token.confidence * 100).rounded())

            return RecoveryCandidate(
                centerY: token.centerY,
                soldWeight: missingWeight,
                score: score,
                tokens: [token]
            )
        }

        guard let bestCandidate = candidates.max(by: { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return lhs.centerY < rhs.centerY
        }) else {
            return (clusters, [])
        }

        var recoveredClusters = clusters
        recoveredClusters.append(
            Cluster(
                centerY: bestCandidate.centerY,
                soldWeight: bestCandidate.soldWeight,
                tokens: bestCandidate.tokens
            )
        )
        return (
            recoveredClusters.sorted { $0.centerY < $1.centerY },
            ["Recovered a missing tally pick using the difference between the tally total and the first-page Sold Weight."]
        )
    }

    private static func inferSingleMissingWeight(
        in clusters: [Cluster],
        tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        expectedSummarySoldWeight: Int?
    ) -> (clusters: [Cluster], warnings: [String]) {
        guard let expectedSummarySoldWeight, expectedSummarySoldWeight > 0 else {
            return (clusters, [])
        }

        let missingIndexes = clusters.indices.filter { clusters[$0].soldWeight <= 0 }
        guard missingIndexes.count == 1 else { return (clusters, []) }
        let knownTotal = clusters.reduce(0) { $0 + max(0, $1.soldWeight) }
        let inferredWeight = expectedSummarySoldWeight - knownTotal
        guard inferredWeight > 0 else { return (clusters, []) }

        let missingIndex = missingIndexes[0]
        let centerY = clusters[missingIndex].centerY
        let tolerance: CGFloat = 0.026
        let cueScore = rowCueScore(near: centerY, in: tokens, tolerance: tolerance)
        let hasCount = hasNearbyCountToken(near: centerY, in: tokens, tolerance: tolerance)
        guard cueScore >= 4 || (cueScore >= 2 && hasCount) else { return (clusters, []) }

        var inferredClusters = clusters
        let original = inferredClusters[missingIndex]
        inferredClusters[missingIndex] = Cluster(
            centerY: original.centerY,
            soldWeight: inferredWeight,
            tokens: original.tokens,
            isInferredWeight: true
        )
        return (
            inferredClusters,
            ["Inferred one missing tally-row weight from the reviewed first-page Sold Weight. Confirm this row before applying."]
        )
    }

    private static func rowIntervals(
        from clusters: [Cluster],
        tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        footerTopY: CGFloat,
        headerBottomY: CGFloat? = nil
    ) -> [RowInterval] {
        guard !clusters.isEmpty else { return [] }

        let rowTokenHeights = tokens
            .filter { $0.centerX >= boundaryRatios[0] && $0.centerX <= boundaryRatios[10] }
            .map(\.height)
            .sorted()
        let medianHeight = rowTokenHeights.isEmpty ? CGFloat(0.014) : rowTokenHeights[rowTokenHeights.count / 2]
        let evidenceTolerance = max(0.034, medianHeight * 2.6)

        return clusters.enumerated().compactMap { index, cluster in
            let previousCenterY = index > 0 ? clusters[index - 1].centerY : nil
            let nextCenterY = index + 1 < clusters.count ? clusters[index + 1].centerY : nil

            let hardTop = max(
                headerBottomY.map { $0 + 0.004 } ?? 0,
                previousCenterY.map { ($0 + cluster.centerY) / 2 + 0.002 } ?? 0
            )
            let hardBottom = min(
                footerTopY - 0.004,
                nextCenterY.map { (cluster.centerY + $0) / 2 - 0.002 } ?? (footerTopY - 0.004)
            )

            let evidenceTokens = tokens.filter { token in
                token.centerX >= boundaryRatios[0]
                    && token.centerX <= boundaryRatios[10]
                    && token.centerY >= hardTop
                    && token.centerY <= hardBottom
                    && abs(token.centerY - cluster.centerY) <= evidenceTolerance
            }

            let evidenceTop = evidenceTokens.map(\.topY).min() ?? cluster.centerY
            let evidenceBottom = evidenceTokens.map(\.bottomY).max() ?? cluster.centerY
            let topY = max(hardTop, min(cluster.centerY - 0.026, evidenceTop - 0.008))
            let bottomY = min(hardBottom, max(cluster.centerY + 0.022, evidenceBottom + 0.008))

            guard bottomY > topY else { return nil }
            return RowInterval(topY: topY, bottomY: bottomY)
        }
    }

    private static func footerTopY(in tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken]) -> CGFloat {
        let footerTokens = tokens.filter { token in
            token.text.range(of: footerTokenPattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return footerTokens.map(\.topY).min() ?? 0.98
    }

    private static func headerBottomY(in tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken]) -> CGFloat? {
        let headerTokens = tokens.filter { token in
            token.topY < 0.18
                && (
                    normalized(token.text).contains("species")
                        || normalized(token.text).contains("cond")
                        || normalized(token.text).contains("tare")
                        || normalized(token.text).contains("weight")
                        || normalized(token.text).contains("brailers")
                )
        }
        return headerTokens.map(\.bottomY).max()
    }

    private static func textInColumns(
        _ tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        xRange: ClosedRange<CGFloat>,
        interval: RowInterval
    ) -> String {
        let filteredTokens = tokens
            .filter { token in
                xRange.contains(token.centerX) && token.centerY >= interval.topY && token.centerY <= interval.bottomY
            }
            .sorted { lhs, rhs in
                let delta = abs(lhs.centerY - rhs.centerY)
                if delta > 0.010 {
                    return lhs.centerY < rhs.centerY
                }
                return lhs.minX < rhs.minX
            }
        return SmartFishTicketSandboxV3OCR.collapsedWhitespace(filteredTokens.map(\.text).joined(separator: " "))
    }

    private static func resolvedWeight(
        in tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        interval: RowInterval,
        fallback: Int
    ) -> Int {
        if (1..<50).contains(fallback) {
            let postTareSmallCandidates = smallWeightCandidates(
                in: tokens,
                xRange: postTareColumnRange,
                interval: interval,
                preferredValue: fallback
            )
            if let exactPostTareSmall = postTareSmallCandidates.first(where: { $0 == fallback }) {
                return exactPostTareSmall
            }

            let soldWeightSmallCandidates = smallWeightCandidates(
                in: tokens,
                xRange: soldWeightColumnRange,
                interval: interval,
                preferredValue: fallback
            )
            if let exactSoldWeightSmall = soldWeightSmallCandidates.first(where: { $0 == fallback }) {
                return exactSoldWeightSmall
            }

            if let bestSmallCandidate = (postTareSmallCandidates + soldWeightSmallCandidates).first {
                return bestSmallCandidate
            }

            return fallback
        }

        let postTareCandidates = weightCandidates(
            in: tokens,
            xRange: postTareColumnRange,
            interval: interval
        )
        if let bestPostTare = postTareCandidates.first {
            return bestPostTare
        }

        let soldWeightCandidates = weightCandidates(
            in: tokens,
            xRange: soldWeightColumnRange,
            interval: interval
        )
        if let bestSoldWeight = soldWeightCandidates.first {
            return bestSoldWeight
        }

        return fallback
    }

    private static func smallWeightCandidates(
        in tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        xRange: ClosedRange<CGFloat>,
        interval: RowInterval,
        preferredValue: Int
    ) -> [Int] {
        let intervalCenterY = (interval.topY + interval.bottomY) / 2

        return tokens
            .filter { token in
                xRange.contains(token.centerX)
                    && token.centerY >= interval.topY - 0.004
                    && token.centerY <= interval.bottomY + 0.004
            }
            .compactMap { token -> (score: Int, value: Int)? in
                guard let rawValue = parseNumberToken(token.text) else { return nil }
                guard let value = normalizedSmallTailWeight(rawValue, preferredValue: preferredValue) else { return nil }

                var score = 180 - Int((abs(token.centerY - intervalCenterY) * 2600).rounded())
                if value == preferredValue { score += 180 }
                if rawValue == value { score += 80 }
                return (score, value)
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.value > $1.value
            }
            .map { $0.value }
    }

    private static func weightCandidates(
        in tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        xRange: ClosedRange<CGFloat>,
        interval: RowInterval
    ) -> [Int] {
        let intervalCenterY = (interval.topY + interval.bottomY) / 2

        return tokens
            .filter { token in
                xRange.contains(token.centerX)
                    && token.centerY >= interval.topY - 0.004
                    && token.centerY <= interval.bottomY + 0.004
            }
            .compactMap { token -> (score: Int, value: Int)? in
                guard let value = parseNumberToken(token.text) else { return nil }
                guard value >= 50 || looksLikeWeightToken(token.text, value: value) else { return nil }
                let score = numericTokenScore(token.text, value: value)
                    - Int((abs(token.centerY - intervalCenterY) * 2400).rounded())
                return (score, value)
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.value > $1.value
            }
            .map { $0.value }
    }

    private static func brailersFromTokens(
        _ tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        interval: RowInterval
    ) -> Int? {
        tokens
            .filter { token in
                brailersColumnRange.contains(token.centerX)
                    && token.centerY >= interval.topY - 0.004
                    && token.centerY <= interval.bottomY + 0.004
            }
            .compactMap { token -> Int? in
                let trimmed = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.range(of: #"^[1-4]$"#, options: .regularExpression) != nil else { return nil }
                return Int(trimmed)
            }
            .first
    }

    private static func brailersFromText(_ rawText: String) -> Int? {
        let digits = rawText.filter(\.isNumber)
        guard digits.count == 1, let value = Int(digits), (1...4).contains(value) else { return nil }
        return value
    }

    private static func parseNumberToken(_ raw: String) -> Int? {
        let candidates = SmartLogbookParse.integerLikeTokens(in: raw).compactMap {
            Int($0.replacingOccurrences(of: ",", with: ""))
        }
        if let weight = candidates.first(where: { $0 >= 100 }) {
            return weight
        }
        return candidates.first
    }

    private static func looksLikeWeightToken(_ raw: String, value: Int) -> Bool {
        let digitCount = raw.filter(\.isNumber).count
        if value >= 100 { return true }
        if raw.contains(",") && value >= 10 { return true }
        return digitCount >= 3
    }

    private static func numericTokenScore(_ raw: String, value: Int?) -> Int {
        guard let value else { return 0 }
        let digitCount = raw.filter(\.isNumber).count
        var score = digitCount * 10
        if raw.contains(",") { score += 12 }
        if value >= 1000 { score += 18 }
        else if value >= 100 { score += 10 }
        if raw.contains("/") { score -= 6 }
        if raw.contains("*") { score -= 2 }
        return score
    }

    private static func looksLikeKingsRow(
        near centerY: CGFloat,
        in tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        tolerance: CGFloat
    ) -> Bool {
        tokens.contains { token in
            token.centerX < deliveryConditionColumnRange.upperBound
                && abs(token.centerY - centerY) <= max(0.014, tolerance)
                && (
                    normalized(token.text).contains("410")
                        || normalized(token.text).contains("king")
                )
        }
    }

    private static func trailingSmallTailWeight(
        expectedSummarySoldWeight: Int?,
        clusters: [Cluster]
    ) -> Int? {
        guard let expectedSummarySoldWeight else { return nil }
        let remainder = expectedSummarySoldWeight - clusters.reduce(0) { $0 + $1.soldWeight }
        guard (1...49).contains(remainder) else { return nil }
        return remainder
    }

    private static func normalizedSmallTailWeight(_ rawValue: Int, preferredValue: Int?) -> Int? {
        if let preferredValue, (1...49).contains(preferredValue) {
            let normalizedRaw = String(rawValue)
            let preferredSuffix = String(preferredValue)
            if rawValue == preferredValue || normalizedRaw.hasSuffix(preferredSuffix) {
                return preferredValue
            }
        }

        if (1...49).contains(rawValue) {
            return rawValue
        }

        return nil
    }

    private static func hasMatchingSmallWeightToken(
        near centerY: CGFloat,
        value: Int,
        in tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        tolerance: CGFloat
    ) -> Bool {
        tokens.contains { token in
            (postTareColumnRange.contains(token.centerX) || soldWeightColumnRange.contains(token.centerX))
                && abs(token.centerY - centerY) <= max(0.016, tolerance)
                && parseNumberToken(token.text).flatMap { normalizedSmallTailWeight($0, preferredValue: value) } == value
        }
    }

    private static func hasNearbyWeightToken(
        near centerY: CGFloat,
        in tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        tolerance: CGFloat
    ) -> Bool {
        tokens.contains { token in
            (postTareColumnRange.contains(token.centerX) || soldWeightColumnRange.contains(token.centerX))
                && abs(token.centerY - centerY) <= tolerance
                && parseNumberToken(token.text).map { $0 >= 50 || looksLikeWeightToken(token.text, value: $0) } == true
        }
    }

    private static func hasNearbyCountToken(
        near centerY: CGFloat,
        in tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        tolerance: CGFloat
    ) -> Bool {
        tokens.contains { token in
            countColumnRange.contains(token.centerX)
                && abs(token.centerY - centerY) <= tolerance
                && parseNumberToken(token.text).map { $0 > 0 && $0 <= 10000 } == true
        }
    }

    private static func rowCueScore(
        near centerY: CGFloat,
        in tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        tolerance: CGFloat
    ) -> Int {
        tokens.reduce(0) { partial, token in
            guard token.centerX < postTareColumnRange.lowerBound else { return partial }
            guard abs(token.centerY - centerY) <= max(0.020, tolerance * 1.35) else { return partial }

            let normalizedText = normalized(token.text)
            var score = 0

            if normalizedText.contains("410") || normalizedText.contains("king") {
                score += 8
            }
            if normalizedText.contains("460") {
                score += 5
            }
            if normalizedText.contains("whole")
                || normalizedText.contains("round")
                || normalizedText.contains("bled") {
                score += 4
            }
            if normalizedText.contains("salmon") || normalizedText.contains("mixed") {
                score += 3
            }
            if (0.26...0.40).contains(token.centerX),
               let countValue = parseNumberToken(token.text),
               countValue > 0,
               countValue <= 9999 {
                score += 2
            }

            return partial + score
        }
    }

    private static func trailingRowCueCenter(
        after lastClusterCenterY: CGFloat,
        tokens: [SmartFishTicketSandboxV3OCR.RecognizedToken],
        footerTopY: CGFloat,
        tolerance: CGFloat
    ) -> CGFloat? {
        let candidateTokens = tokens.filter { token in
            token.centerX < postTareColumnRange.lowerBound
                && token.centerY > lastClusterCenterY + (tolerance * 0.35)
                && token.topY < footerTopY - 0.006
                && rowCueScore(near: token.centerY, in: tokens, tolerance: tolerance) > 0
        }

        guard let lowestCenterY = candidateTokens.map(\.centerY).max() else {
            return nil
        }

        let groupedTokens = candidateTokens.filter { abs($0.centerY - lowestCenterY) <= max(0.020, tolerance * 1.35) }
        guard rowCueScore(near: lowestCenterY, in: tokens, tolerance: tolerance) >= 4 else {
            return nil
        }

        let summedCenterY = groupedTokens.reduce(CGFloat(0)) { $0 + $1.centerY }
        return groupedTokens.isEmpty ? nil : summedCenterY / CGFloat(groupedTokens.count)
    }

    private static func normalizeSpecies(_ rawText: String) -> String {
        let cleaned = rawText.uppercased().replacingOccurrences(of: #"[^A-Z0-9 ]+"#, with: " ", options: .regularExpression)
        let words = cleaned.split(separator: " ").map(String.init)
        if words.contains("410") || words.contains(where: { similarity($0, "KINGS") >= 0.65 }) {
            return "410 Kings"
        }
        if words.contains("460")
            || words.contains("60")
            || words.contains(where: { similarity($0, "SALMON") >= 0.55 })
            || words.contains(where: { similarity($0, "MIXED") >= 0.60 }) {
            return "460 Salmon, Mixed"
        }
        return ""
    }

    private static func normalizeCondition(_ rawText: String) -> String {
        var cleaned = rawText.uppercased().replacingOccurrences(of: #"[^A-Z0-9 ]+"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "O1", with: "01")
        cleaned = cleaned.replacingOccurrences(of: "0L", with: "01")
        cleaned = cleaned.replacingOccurrences(of: "OL", with: "01")
        cleaned = cleaned.replacingOccurrences(of: "O3", with: "03")
        cleaned = cleaned.replacingOccurrences(of: "OS", with: "03")
        let words = cleaned.split(separator: " ").map(String.init)

        if words.contains("03") {
            return "03 Bled"
        }
        if words.contains(where: { similarity($0, "WHOLE") >= 0.55 }) {
            return "01 Whole"
        }
        if words.contains(where: { similarity($0, "BLED") >= 0.55 }) {
            return "03 Bled"
        }
        if words.contains("01") {
            return "01 Whole"
        }
        if words.contains(where: { similarity($0, "ROUND") >= 0.60 }) {
            return "01 Round"
        }
        return ""
    }

    private static func fillRowDefaults(_ rows: [ParsedRow]) -> [ParsedRow] {
        var normalizedRows = rows

        let speciesDefault = mostCommonValue(
            in: normalizedRows.map(\.species).filter { !$0.isEmpty && $0 != "410 Kings" }
        ) ?? ""
        let conditionDefault = mostCommonValue(
            in: normalizedRows.map(\.deliveryCondition).filter { !$0.isEmpty }
        ) ?? ""

        let highBrailers = normalizedRows.compactMap { row -> Int? in
            guard let brailers = row.brailers, row.soldWeight >= 1000 else { return nil }
            return brailers
        }
        let lowBrailers = normalizedRows.compactMap { row -> Int? in
            guard let brailers = row.brailers, row.soldWeight >= 100, row.soldWeight < 1000 else { return nil }
            return brailers
        }
        let overallBrailers = normalizedRows.compactMap(\.brailers)

        let minimumBandSamples = normalizedRows.count <= 2 ? 1 : 2
        let highConsistent = Set(highBrailers).count == 1 && highBrailers.count >= minimumBandSamples
        let lowConsistent = Set(lowBrailers).count == 1 && lowBrailers.count >= minimumBandSamples
        let overallMinimumSamples = normalizedRows.count <= 2 ? 1 : max(2, normalizedRows.count / 2)
        let overallConsistent = Set(overallBrailers).count == 1 && overallBrailers.count >= overallMinimumSamples

        for index in normalizedRows.indices {
            if normalizedRows[index].species.isEmpty {
                if normalizedRows[index].soldWeight < 50 {
                    normalizedRows[index].species = "410 Kings"
                } else {
                    normalizedRows[index].species = speciesDefault
                }
            }

            if normalizedRows[index].deliveryCondition.isEmpty {
                if normalizedRows[index].species == "410 Kings" {
                    normalizedRows[index].deliveryCondition = "01 Whole"
                } else {
                    normalizedRows[index].deliveryCondition = conditionDefault
                }
            }

            if normalizedRows[index].brailers == nil {
                if normalizedRows[index].species == "410 Kings" && normalizedRows[index].soldWeight < 50 {
                    normalizedRows[index].brailers = nil
                } else if normalizedRows[index].soldWeight >= 1000, highConsistent {
                    normalizedRows[index].brailers = highBrailers.first
                } else if normalizedRows[index].soldWeight >= 100, normalizedRows[index].soldWeight < 1000, lowConsistent {
                    normalizedRows[index].brailers = lowBrailers.first
                } else if overallConsistent {
                    normalizedRows[index].brailers = overallBrailers.first
                }
            }
        }

        return normalizedRows
    }

    private static func mostCommonValue(in values: [String]) -> String? {
        var counts: [String: Int] = [:]
        for value in values where !value.isEmpty {
            counts[value, default: 0] += 1
        }
        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key < rhs.key
        }?.key
    }

    private static func deduplicatedWarnings(_ warnings: [String]) -> [String] {
        var seen: Set<String> = []
        return warnings.filter { seen.insert($0).inserted }
    }

    private static func normalized(_ raw: String) -> String {
        SmartFishTicketSandboxV3OCR.collapsedWhitespace(
            raw.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        )
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsCharacters = Array(lhs)
        let rhsCharacters = Array(rhs)
        let maxLength = max(lhsCharacters.count, rhsCharacters.count)
        guard maxLength > 0 else { return 1 }

        var matrix = Array(
            repeating: Array(repeating: 0, count: rhsCharacters.count + 1),
            count: lhsCharacters.count + 1
        )

        for lhsIndex in 0...lhsCharacters.count {
            matrix[lhsIndex][0] = lhsIndex
        }
        for rhsIndex in 0...rhsCharacters.count {
            matrix[0][rhsIndex] = rhsIndex
        }

        if !lhsCharacters.isEmpty && !rhsCharacters.isEmpty {
            for lhsIndex in 1...lhsCharacters.count {
                for rhsIndex in 1...rhsCharacters.count {
                    let substitutionCost = lhsCharacters[lhsIndex - 1] == rhsCharacters[rhsIndex - 1] ? 0 : 1
                    matrix[lhsIndex][rhsIndex] = min(
                        matrix[lhsIndex - 1][rhsIndex] + 1,
                        matrix[lhsIndex][rhsIndex - 1] + 1,
                        matrix[lhsIndex - 1][rhsIndex - 1] + substitutionCost
                    )
                }
            }
        }

        let distance = matrix[lhsCharacters.count][rhsCharacters.count]
        return 1 - (Double(distance) / Double(maxLength))
    }

    #if DEBUG
    static func testParseTokens(
        _ testTokens: [SmartFishTicketTallyOCRTestToken],
        expectedSummarySoldWeight: Int?
    ) -> SmartFishTicketTallyOCRTestResult? {
        guard let cgImage = testCGImage() else { return nil }
        let tokens = testTokens.map {
            SmartFishTicketSandboxV3OCR.RecognizedToken(
                text: $0.text,
                boundingBox: $0.boundingBox,
                confidence: $0.confidence
            )
        }
        let recognizedVariant = SmartFishTicketSandboxV3OCR.RecognizedVariant(
            text: tokens.map(\.text).joined(separator: "\n"),
            lines: [],
            tokens: tokens,
            variantTag: "test",
            cgImage: cgImage
        )
        guard let candidate = makeCandidate(
            recognizedVariant,
            cropRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            variantIndex: 0,
            pageIndex: 1,
            expectedSummarySoldWeight: expectedSummarySoldWeight
        ) else {
            return nil
        }
        return testResult(from: candidate, expectedSummarySoldWeight: expectedSummarySoldWeight)
    }

    static func testSelectTokenCandidates(
        _ testCandidatesByPage: [[[SmartFishTicketTallyOCRTestToken]]],
        expectedSummarySoldWeight: Int?
    ) -> [SmartFishTicketTallyOCRTestResult] {
        guard let cgImage = testCGImage() else { return [] }
        let candidatesByPage = testCandidatesByPage.enumerated().map { pageOffset, pageCandidates in
            pageCandidates.enumerated().compactMap { variantIndex, testTokens -> PageCandidate? in
                let tokens = testTokens.map {
                    SmartFishTicketSandboxV3OCR.RecognizedToken(
                        text: $0.text,
                        boundingBox: $0.boundingBox,
                        confidence: $0.confidence
                    )
                }
                let recognizedVariant = SmartFishTicketSandboxV3OCR.RecognizedVariant(
                    text: tokens.map(\.text).joined(separator: "\n"),
                    lines: [],
                    tokens: tokens,
                    variantTag: "test-\(variantIndex)",
                    cgImage: cgImage
                )
                return makeCandidate(
                    recognizedVariant,
                    cropRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                    variantIndex: variantIndex,
                    pageIndex: pageOffset + 1,
                    expectedSummarySoldWeight: nil
                )
            }
        }

        return selectCandidateCombination(
            from: candidatesByPage,
            expectedSummarySoldWeight: expectedSummarySoldWeight
        ).map { testResult(from: $0, expectedSummarySoldWeight: nil) }
    }

    static func testExtract(
        images: [UIImage],
        expectedSummarySoldWeight: Int?
    ) async throws -> SmartFishTicketTallyOCRTestResult? {
        guard let draft = try await parse(
            images: images,
            expectedSummarySoldWeight: expectedSummarySoldWeight
        ) else {
            return nil
        }

        let rows = draft.rows.map {
            SmartFishTicketTallyOCRTestRow(
                species: $0.speciesText,
                deliveryCondition: $0.deliveryConditionText,
                soldWeight: SmartLogbookParse.firstInteger(in: $0.soldWeightText) ?? 0,
                brailers: SmartLogbookParse.firstInteger(in: $0.brailersText),
                isInferredWeight: false
            )
        }
        return SmartFishTicketTallyOCRTestResult(rows: rows, warnings: draft.warnings, score: 0)
    }

    private static func testResult(
        from candidate: PageCandidate,
        expectedSummarySoldWeight: Int?
    ) -> SmartFishTicketTallyOCRTestResult {
        SmartFishTicketTallyOCRTestResult(
            rows: candidate.rows.map {
                SmartFishTicketTallyOCRTestRow(
                    species: $0.species,
                    deliveryCondition: $0.deliveryCondition,
                    soldWeight: $0.soldWeight,
                    brailers: $0.brailers,
                    isInferredWeight: $0.isInferredWeight
                )
            },
            warnings: candidate.warnings,
            score: candidate.score(expectedSummarySoldWeight: expectedSummarySoldWeight)
        )
    }

    private static func testCGImage() -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()
    }
    #endif

}

#if DEBUG
enum SmartFishTicketTallyOCRTestSupport {
    static func parseTokens(
        _ tokens: [SmartFishTicketTallyOCRTestToken],
        expectedSummarySoldWeight: Int?
    ) -> SmartFishTicketTallyOCRTestResult? {
        SmartFishTicketSandboxV3TallyParser.testParseTokens(
            tokens,
            expectedSummarySoldWeight: expectedSummarySoldWeight
        )
    }

    static func selectTokenCandidates(
        _ candidatesByPage: [[[SmartFishTicketTallyOCRTestToken]]],
        expectedSummarySoldWeight: Int?
    ) -> [SmartFishTicketTallyOCRTestResult] {
        SmartFishTicketSandboxV3TallyParser.testSelectTokenCandidates(
            candidatesByPage,
            expectedSummarySoldWeight: expectedSummarySoldWeight
        )
    }

    static func extract(
        images: [UIImage],
        expectedSummarySoldWeight: Int?
    ) async throws -> SmartFishTicketTallyOCRTestResult? {
        try await SmartFishTicketSandboxV3TallyParser.testExtract(
            images: images,
            expectedSummarySoldWeight: expectedSummarySoldWeight
        )
    }

    static func clearOCRCaches() {
        SmartLogbookImageRendering.clearCaches()
        SmartFishTicketStorage.clearMemoryCache()
    }

}
#endif

// MARK: - Smart Logbook cross-view notifications

extension Notification.Name {
    static let smartLogbookDidChange = Notification.Name("SmartLogbookDidChange")
}

// MARK: - Store

@MainActor
final class SmartLogbookStore: ObservableObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SatChart",
        category: "SmartLogbook"
    )

    @Published var draftSplashDate: Date
    @Published var draftDistrict: District
    @Published var firstOpeningDate: Date
    @Published var draftAutoCreateFromDriftAnnouncements: Bool
    @Published private(set) var seasons: [SmartLogbookSeason]
    @Published private(set) var activeSeasonID: UUID?
    @Published private(set) var lastDeliveryDraftError: String?

    private let persistenceURL: URL

    init(persistenceURL: URL? = nil) {
        let today = Calendar.current.startOfDay(for: Date())
        self.draftSplashDate = today
        self.draftDistrict = .nushagak
        self.firstOpeningDate = today
        self.draftAutoCreateFromDriftAnnouncements = false
        self.persistenceURL = persistenceURL ?? SmartLogbookStore.makePersistenceURL()
        var loadedSeasons = SmartLogbookStore.loadSeasons(from: self.persistenceURL)
        let didMigrateDeliveryOrder = SmartLogbookStore.migrateLegacyOpeningCreationDates(in: &loadedSeasons)
        let didNormalizeCalendarYears = SmartLogbookStore.normalizeCalendarYearSeasons(in: &loadedSeasons)
        self.seasons = loadedSeasons
        self.activeSeasonID = seasons.first?.id
        self.lastDeliveryDraftError = nil

        if let activeSeason = seasons.first {
            seedDraftFields(from: activeSeason)
        }

        if didMigrateDeliveryOrder || didNormalizeCalendarYears {
            Self.logger.notice("Migrated Smart Logbook data to calendar-year seasons")
            persist()
        }
        resolveMissingSetLocationsIfNeeded()
    }

    var activeSeason: SmartLogbookSeason? {
        guard let index = activeSeasonIndex else { return nil }
        return seasons[index]
    }

    func setActiveSeason(_ seasonID: UUID) {
        guard let season = seasons.first(where: { $0.id == seasonID }) else { return }
        activeSeasonID = season.id
        seedDraftFields(from: season)
    }

    func makeExportSnapshot() -> LogbookExportSnapshot {
        LogbookExportSnapshot(
            createdAt: Date(),
            seasons: seasons,
            activeSeasonID: activeSeasonID,
            sourceLogbookURL: persistenceURL
        )
    }

    private var activeSeasonIndex: Int? {
        if let activeSeasonID,
           let index = seasons.firstIndex(where: { $0.id == activeSeasonID }) {
            return index
        }
        return seasons.indices.first
    }

    func activeSeasonContainsOpening(on date: Date) -> Bool {
        guard let seasonIndex = seasonIndex(for: date) else { return false }
        return seasons[seasonIndex].openings.contains {
            Calendar.current.isDate($0.openingDate, inSameDayAs: date)
        }
    }

    func startNewSeasonFromDraft() {
        let normalizedOpeningDate = Calendar.current.startOfDay(for: firstOpeningDate)
        let seasonID = ensureCalendarYearSeason(
            for: normalizedOpeningDate,
            fallbackDistrict: draftDistrict
        )
        guard let seasonIndex = seasons.firstIndex(where: { $0.id == seasonID }) else { return }

        activeSeasonID = seasonID
        seasons[seasonIndex].smartLogDriftAutoCreateEnabled = draftAutoCreateFromDriftAnnouncements
        let districtKey = districtOverrideKey(for: draftDistrict, in: seasons[seasonIndex])
        if !openingExists(on: normalizedOpeningDate, districtKey: districtKey, seasonIndex: seasonIndex) {
            seasons[seasonIndex].openings.append(
                SmartLogbookOpening(openingDate: normalizedOpeningDate, districtKey: districtKey)
            )
            seasons[seasonIndex].openings.sort { $0.openingDate < $1.openingDate }
        }
        seedDraftFields(from: seasons[seasonIndex])
        persist()
    }

    func deleteActiveSeason() {
        guard let seasonIndex = activeSeasonIndex else { return }
        cleanup(seasons[seasonIndex])
        seasons.remove(at: seasonIndex)

        activeSeasonID = seasons.first?.id
        if let activeSeason = seasons.first {
            seedDraftFields(from: activeSeason)
        } else {
            resetDraftFields()
        }
        persist()
    }

    func addNextOpening() {
        _ = addOCRDeliveryDraft()
    }

    @discardableResult
    func addOCRDeliveryDraft(on date: Date = Date(), fallbackDistrict: District? = nil, reusingBlankDraft: Bool = false) -> UUID? {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        lastDeliveryDraftError = nil

        let seasonID = ensureCalendarYearSeason(
            for: startOfDay,
            fallbackDistrict: fallbackDistrict ?? draftDistrict
        )
        guard let seasonIndex = seasons.firstIndex(where: { $0.id == seasonID }) else {
            let message = "SatChart could not identify the active logbook season. Return to Logbook and select a season, then try again."
            lastDeliveryDraftError = message
            Self.logger.error("\(message, privacy: .public)")
            return nil
        }
        setActiveSeason(seasonID)
        let season = seasons[seasonIndex]

        if reusingBlankDraft,
           let reusableDraft = season.deliveryOpenings.last(where: { $0.isBlankOCRDeliveryDraft }) {
            Self.logger.info("Reusing blank OCR delivery draft \(reusableDraft.id, privacy: .public)")
            return reusableDraft.id
        }

        let currentDistrict = season.currentDistrict
        let resolvedDistrictKey = districtOverrideKey(for: currentDistrict, in: season)
        let latestCreationDate = season.openings.map(\.createdAt).max() ?? .distantPast
        let createdAt = max(Date(), latestCreationDate.addingTimeInterval(0.001))

        let opening = SmartLogbookOpening(
            createdAt: createdAt,
            openingDate: startOfDay,
            districtKey: resolvedDistrictKey,
            isRecordedDelivery: true,
            isCollapsed: false
        )
        seasons[seasonIndex].openings.append(opening)
        firstOpeningDate = opening.openingDate
        seedDraftFields(from: seasons[seasonIndex])
        persist()
        Self.logger.info("Created OCR delivery draft \(opening.id, privacy: .public)")
        return opening.id
    }

    /// Moves a delivery draft into the calendar-year season represented by its
    /// landed date. This is intentionally idempotent so text-field edits and OCR
    /// application can both call it safely.
    func routeDeliveryOpeningToCalendarYear(
        openingID: UUID,
        landingDate: Date,
        fallbackDistrict: District
    ) {
        guard let sourcePosition = openingPosition(for: openingID) else { return }
        let sourceSeasonID = seasons[sourcePosition.seasonIndex].id
        let targetYear = Calendar.current.component(.year, from: landingDate)

        if seasons[sourcePosition.seasonIndex].calendarYear == targetYear {
            setActiveSeason(sourceSeasonID)
            persist()
            return
        }

        let sourceDistrict = seasons[sourcePosition.seasonIndex].district
        var movedOpening = seasons[sourcePosition.seasonIndex].openings.remove(at: sourcePosition.openingIndex)
        let openingDistrict = movedOpening.openingDistrict ?? sourceDistrict
        let resolvedDistrict = movedOpening.openingDistrict ?? fallbackDistrict
        let targetSeasonID = ensureCalendarYearSeason(
            for: landingDate,
            fallbackDistrict: resolvedDistrict
        )

        guard let targetSeasonIndex = seasons.firstIndex(where: { $0.id == targetSeasonID }) else { return }
        movedOpening.districtKey = districtOverrideKey(for: openingDistrict, in: seasons[targetSeasonIndex])
        seasons[targetSeasonIndex].openings.append(movedOpening)

        if let sourceSeasonIndex = seasons.firstIndex(where: { $0.id == sourceSeasonID }),
           isCalendarYearSeasonEmpty(seasons[sourceSeasonIndex]) {
            seasons.remove(at: sourceSeasonIndex)
        }

        sortSeasonsByCalendarYear()
        activeSeasonID = targetSeasonID
        if let targetSeason = seasons.first(where: { $0.id == targetSeasonID }) {
            seedDraftFields(from: targetSeason)
        }
        persist()
    }

    func addTransferredOpening(district: District, legalDate: Date) {
        let startOfDay = Calendar.current.startOfDay(for: legalDate)
        let seasonID = ensureCalendarYearSeason(for: startOfDay, fallbackDistrict: district)
        guard let seasonIndex = seasons.firstIndex(where: { $0.id == seasonID }) else { return }
        setActiveSeason(seasonID)
        let districtKey = districtOverrideKey(for: district, in: seasons[seasonIndex])

        guard !openingExists(on: startOfDay, districtKey: districtKey, seasonIndex: seasonIndex) else { return }

        let newOpening = SmartLogbookOpening(
            openingDate: startOfDay,
            districtKey: districtKey
        )
        seasons[seasonIndex].openings.append(newOpening)
        seasons[seasonIndex].openings.sort { $0.openingDate < $1.openingDate }
        seedDraftFields(from: seasons[seasonIndex])
        persist()
    }

    func addTenderEntry(
        date: Date,
        tenderName: String,
        fuelGallons: Double?,
        groceriesDescription: String,
        groceriesAmount: Double?,
        miscDescription: String,
        miscAmount: Double?
    ) {
        let normalizedTenderName = tenderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedGroceriesDescription = groceriesDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMiscDescription = miscDescription.trimmingCharacters(in: .whitespacesAndNewlines)

        let entry = SmartLogbookTenderEntry(
            date: Calendar.current.startOfDay(for: date),
            tenderName: normalizedTenderName,
            fuelGallons: fuelGallons,
            groceriesDescription: normalizedGroceriesDescription,
            groceriesAmount: groceriesAmount,
            miscDescription: normalizedMiscDescription,
            miscAmount: miscAmount
        )

        guard entry.hasAnyValue else { return }

        let seasonID = ensureCalendarYearSeason(for: entry.date, fallbackDistrict: draftDistrict)
        guard let seasonIndex = seasons.firstIndex(where: { $0.id == seasonID }) else { return }
        activeSeasonID = seasonID

        seasons[seasonIndex].tenderEntries.append(entry)
        seasons[seasonIndex].tenderEntries.sort { $0.date < $1.date }
        seedDraftFields(from: seasons[seasonIndex])
        persist()
    }

    func addTenderReceiptImage(filename: String, date: Date) {
        let seasonID = ensureCalendarYearSeason(for: date, fallbackDistrict: draftDistrict)
        guard let seasonIndex = seasons.firstIndex(where: { $0.id == seasonID }) else { return }
        activeSeasonID = seasonID
        seasons[seasonIndex].tenderReceiptImageFilenames.append(filename)
        seedDraftFields(from: seasons[seasonIndex])
        persist()
    }

    func setActiveSeasonSmartLogDriftAutoCreateEnabled(_ isEnabled: Bool) {
        guard let seasonIndex = activeSeasonIndex else {
            draftAutoCreateFromDriftAnnouncements = isEnabled
            return
        }
        seasons[seasonIndex].smartLogDriftAutoCreateEnabled = isEnabled
        draftAutoCreateFromDriftAnnouncements = isEnabled
        persist()
    }

    @discardableResult
    func addSmartLogOpeningIfNeeded(on date: Date, district: District) -> Bool {
        let startOfDay = Calendar.current.startOfDay(for: date)
        let seasonID = ensureCalendarYearSeason(for: startOfDay, fallbackDistrict: district)
        guard let seasonIndex = seasons.firstIndex(where: { $0.id == seasonID }) else { return false }
        setActiveSeason(seasonID)

        let districtKey = districtOverrideKey(for: district, in: seasons[seasonIndex])
        guard !openingExists(on: startOfDay, districtKey: districtKey, seasonIndex: seasonIndex) else { return false }

        let opening = SmartLogbookOpening(
            openingDate: startOfDay,
            districtKey: districtKey,
            isRecordedDelivery: false,
            isCollapsed: false
        )
        seasons[seasonIndex].openings.append(opening)
        seasons[seasonIndex].openings.sort { $0.openingDate < $1.openingDate }
        firstOpeningDate = seasons[seasonIndex].openings.last?.openingDate ?? startOfDay
        seedDraftFields(from: seasons[seasonIndex])
        persist()
        return true
    }

    func reloadFromDisk() {
        let previousActiveSeasonID = activeSeasonID
        let previousActiveYear = activeSeason?.calendarYear
        var loadedSeasons = SmartLogbookStore.loadSeasons(from: persistenceURL)
        let didMigrateDeliveryOrder = SmartLogbookStore.migrateLegacyOpeningCreationDates(in: &loadedSeasons)
        let didNormalizeCalendarYears = SmartLogbookStore.normalizeCalendarYearSeasons(in: &loadedSeasons)
        seasons = loadedSeasons
        if let previousActiveSeasonID, seasons.contains(where: { $0.id == previousActiveSeasonID }) {
            activeSeasonID = previousActiveSeasonID
        } else if let previousActiveYear,
                  let sameYearSeason = seasons.first(where: { $0.calendarYear == previousActiveYear }) {
            activeSeasonID = sameYearSeason.id
        } else {
            activeSeasonID = seasons.first?.id
        }

        if let activeSeason {
            seedDraftFields(from: activeSeason)
        } else {
            resetDraftFields()
        }

        if didMigrateDeliveryOrder || didNormalizeCalendarYears {
            Self.logger.notice("Migrated Smart Logbook data to calendar-year seasons after reload")
            persist()
        }
        resolveMissingSetLocationsIfNeeded()
    }

    var displayedFishingSetsOnNavPage: [SmartFishingSetRecord] {
        seasons
            .flatMap { $0.openings }
            .flatMap { $0.fishingSets }
            .filter { $0.displayOnNavPage }
            .sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
                return lhs.setNumber < rhs.setNumber
            }
    }

    func setCountSinceLastRecordedDelivery() -> Int {
        guard let season = activeSeason else { return 0 }
        let lastRecordedIndex = season.openings.lastIndex(where: { $0.isRecordedDelivery })
        return season.openings.enumerated().reduce(0) { partial, entry in
            if let lastRecordedIndex, entry.offset <= lastRecordedIndex {
                return partial
            }
            return partial + entry.element.fishingSets.count
        }
    }

    @discardableResult
    func addFishingSet(_ set: SmartFishingSetRecord, fallbackDistrict: District) -> SmartFishingSetRecord? {
        let calendar = Calendar.current
        var savedSet = set
        applyResolvedLocationIfNeeded(to: &savedSet)
        let openingDate = calendar.startOfDay(for: savedSet.startedAt)
        let seasonDistrict = storageDistrict(for: savedSet, fallbackDistrict: fallbackDistrict)

        let seasonID = ensureCalendarYearSeason(for: openingDate, fallbackDistrict: seasonDistrict)
        guard let seasonIndex = seasons.firstIndex(where: { $0.id == seasonID }) else { return nil }
        setActiveSeason(seasonID)
        let openingIndex = storageOpeningIndex(
            for: openingDate,
            district: storageDistrict(for: savedSet, fallbackDistrict: seasonDistrict),
            seasonIndex: seasonIndex
        )
        savedSet.setNumber = seasons[seasonIndex].openings[openingIndex].fishingSets.count + 1
        seasons[seasonIndex].openings[openingIndex].fishingSets.append(savedSet)
        resequenceFishingSets(inSeasonAt: seasonIndex, openingIndex: openingIndex)
        if let updated = seasons[seasonIndex].openings[openingIndex].fishingSets.first(where: { $0.id == savedSet.id }) {
            savedSet = updated
        }
        firstOpeningDate = seasons[seasonIndex].openings.last?.openingDate ?? firstOpeningDate
        seedDraftFields(from: seasons[seasonIndex])
        persist()
        return savedSet
    }

    func updateFishingSetDisplayOnNav(setID: UUID, displayOnNavPage: Bool) {
        guard let position = fishingSetPosition(for: setID) else { return }
        seasons[position.seasonIndex].openings[position.openingIndex].fishingSets[position.setIndex].displayOnNavPage = displayOnNavPage
        persist()
    }

    func deleteFishingSet(setID: UUID) {
        guard let position = fishingSetPosition(for: setID) else { return }
        seasons[position.seasonIndex].openings[position.openingIndex].fishingSets.removeAll { $0.id == setID }
        resequenceFishingSets(inSeasonAt: position.seasonIndex, openingIndex: position.openingIndex)
        persist()
    }

    func previewFishingSetNumber(for startedAt: Date, fallbackDistrict: District) -> Int {
        let calendar = Calendar.current
        let openingDate = calendar.startOfDay(for: startedAt)

        guard let seasonIndex = seasonIndex(for: openingDate) else { return 1 }

        let districtKey = districtOverrideKey(for: fallbackDistrict, in: seasons[seasonIndex])
        let existingCount = seasons[seasonIndex].openings.first(where: { opening in
            calendar.isDate(opening.openingDate, inSameDayAs: openingDate)
                && opening.districtKey == districtKey
                && !opening.isRecordedDelivery
        })?.fishingSets.count ?? 0

        return existingCount + 1
    }

    func deleteOpening(_ openingID: UUID) {
        guard let seasonIndex = activeSeasonIndex else { return }
        guard let openingIndex = seasons[seasonIndex].openings.firstIndex(where: { $0.id == openingID }) else { return }
        let calendar = Calendar.current

        let opening = seasons[seasonIndex].openings[openingIndex]
        opening.fishTicketImageFilenames.forEach { SmartFishTicketStorage.deleteImage(named: $0) }
        opening.qcSheetImageFilenames.forEach { SmartFishTicketStorage.deleteImage(named: $0) }

        if opening.isDeliveryEntry, !opening.fishingSets.isEmpty {
            let fallbackDistrict = opening.openingDistrict ?? seasons[seasonIndex].district
            let legacySets = opening.fishingSets
            seasons[seasonIndex].openings[openingIndex].fishingSets.removeAll()

            for var set in legacySets {
                set.assignedDeliveryOpeningID = nil
                applyResolvedLocationIfNeeded(to: &set)
                let storageDistrict = storageDistrict(for: set, fallbackDistrict: fallbackDistrict)
                let targetOpeningIndex = storageOpeningIndex(
                    for: calendar.startOfDay(for: set.startedAt),
                    district: storageDistrict,
                    seasonIndex: seasonIndex
                )
                seasons[seasonIndex].openings[targetOpeningIndex].fishingSets.append(set)
                resequenceFishingSets(inSeasonAt: seasonIndex, openingIndex: targetOpeningIndex)
            }
        }

        clearFishingSetAssignments(toOpeningID: openingID, seasonIndex: seasonIndex)
        seasons[seasonIndex].openings.removeAll { $0.id == openingID }
        persist()
    }

    func updateFishingSet(_ set: SmartFishingSetRecord) {
        guard let position = fishingSetPosition(for: set.id) else { return }
        var updatedSet = set
        applyResolvedLocationIfNeeded(to: &updatedSet)
        seasons[position.seasonIndex].openings[position.openingIndex].fishingSets[position.setIndex] = updatedSet
        persist()
    }

    func assignFishingSet(setID: UUID, toOpeningID: UUID?) {
        guard let position = fishingSetPosition(for: setID) else { return }
        seasons[position.seasonIndex].openings[position.openingIndex].fishingSets[position.setIndex].assignedDeliveryOpeningID = toOpeningID
        persist()
    }

    func copyNotesForward(into openingID: UUID) {
        guard let seasonIndex = activeSeasonIndex else { return }
        let deliveries = seasons[seasonIndex].deliveryOpenings
        guard let deliveryIndex = deliveries.firstIndex(where: { $0.id == openingID }), deliveryIndex > 0,
              let openingIndex = seasons[seasonIndex].openings.firstIndex(where: { $0.id == openingID }) else {
            return
        }

        let previous = deliveries[deliveryIndex - 1]
        seasons[seasonIndex].openings[openingIndex].notes = previous.notes
        persist()
    }

    func catchToDate(beforeOpeningID openingID: UUID) -> Int {
        guard let season = activeSeason else { return 0 }
        var running = 0

        for opening in season.deliveryOpenings {
            if opening.id == openingID { break }
            running += opening.totalCatchLbs ?? 0
        }

        return running
    }

    func totalCatch(for season: SmartLogbookSeason) -> Int {
        season.openings.reduce(0) { $0 + ($1.totalCatchLbs ?? 0) }
    }

    func totalFuelGallons(for season: SmartLogbookSeason) -> Double {
        season.tenderEntries.reduce(0) { $0 + ($1.fuelGallons ?? 0) }
    }

    func totalGroceriesAmount(for season: SmartLogbookSeason) -> Double {
        season.tenderEntries.reduce(0) { $0 + ($1.groceriesAmount ?? 0) }
    }

    func totalMiscAmount(for season: SmartLogbookSeason) -> Double {
        season.tenderEntries.reduce(0) { $0 + ($1.miscAmount ?? 0) }
    }

    func totalOpeningHours(for season: SmartLogbookSeason) -> Double {
        season.openings.reduce(0) { $0 + ($1.openingHours ?? 0) }
    }

    func bindingForOpening(openingID: UUID) -> Binding<SmartLogbookOpening>? {
        Binding(
            get: {
                guard
                    let seasonIndex = self.activeSeasonIndex,
                    let openingIndex = self.seasons[seasonIndex].openings.firstIndex(where: { $0.id == openingID })
                else {
                    return SmartLogbookOpening(openingDate: self.firstOpeningDate)
                }
                return self.seasons[seasonIndex].openings[openingIndex]
            },
            set: { newValue in
                guard
                    let seasonIndex = self.activeSeasonIndex,
                    let openingIndex = self.seasons[seasonIndex].openings.firstIndex(where: { $0.id == openingID })
                else {
                    return
                }
                let fallbackDistrict = newValue.openingDistrict ?? self.seasons[seasonIndex].district
                self.seasons[seasonIndex].openings[openingIndex] = newValue
                if let landingDate = SmartLogbookParse.fishTicketDate(from: newValue.dateLandedText) {
                    self.routeDeliveryOpeningToCalendarYear(
                        openingID: openingID,
                        landingDate: landingDate,
                        fallbackDistrict: fallbackDistrict
                    )
                } else {
                    self.persist()
                }
            }
        )
    }

    func hasDuplicateDelivery(
        soldWeightLbs: Int,
        dateLandedText: String,
        timeOfLandingText: String,
        excludingOpeningID: UUID
    ) -> Bool {
        guard let candidateLandingDate = SmartLogbookParse.exactFishTicketLandingDate(
            dateText: dateLandedText,
            timeText: timeOfLandingText
        ) else {
            return false
        }

        return seasons.contains { season in
            season.deliveryOpenings.contains { existing in
                guard existing.id != excludingOpeningID,
                      existing.totalCatchLbs == soldWeightLbs,
                      let existingLandingDate = SmartLogbookParse.exactFishTicketLandingDate(
                        dateText: existing.dateLandedText,
                        timeText: existing.timeOfLandingText
                      ) else {
                    return false
                }
                return existingLandingDate == candidateLandingDate
            }
        }
    }

    func bindingForFishingSet(setID: UUID) -> Binding<SmartFishingSetRecord>? {
        Binding(
            get: {
                guard let position = self.fishingSetPosition(for: setID) else {
                    return SmartFishingSetRecord(
                        startedAt: Date(),
                        endedAt: Date(),
                        locations: []
                    )
                }
                return self.seasons[position.seasonIndex].openings[position.openingIndex].fishingSets[position.setIndex]
            },
            set: { newValue in
                guard let position = self.fishingSetPosition(for: setID) else { return }
                var updatedSet = newValue
                self.applyResolvedLocationIfNeeded(to: &updatedSet)
                self.seasons[position.seasonIndex].openings[position.openingIndex].fishingSets[position.setIndex] = updatedSet
                self.persist()
            }
        )
    }

    func assignedFishingSets(forOpeningID openingID: UUID) -> [SmartFishingSetRecord] {
        guard let activeSeason else { return [] }
        var seen: Set<UUID> = []

        return activeSeason.openings.flatMap { opening in
            opening.fishingSets.filter { set in
                if set.assignedDeliveryOpeningID == openingID {
                    return true
                }
                return opening.id == openingID && opening.isDeliveryEntry && set.assignedDeliveryOpeningID == nil
            }
        }
        .filter { seen.insert($0.id).inserted }
        .sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
            return lhs.setNumber < rhs.setNumber
        }
    }

    func resolveMissingSetLocationsIfNeeded() {
        var didMutate = false

        for seasonIndex in seasons.indices {
            for openingIndex in seasons[seasonIndex].openings.indices {
                let openingID = seasons[seasonIndex].openings[openingIndex].id
                let openingIsDelivery = seasons[seasonIndex].openings[openingIndex].isDeliveryEntry

                for setIndex in seasons[seasonIndex].openings[openingIndex].fishingSets.indices {
                    var set = seasons[seasonIndex].openings[openingIndex].fishingSets[setIndex]
                    let originalSet = set

                    if openingIsDelivery && set.assignedDeliveryOpeningID == nil {
                        set.assignedDeliveryOpeningID = openingID
                    }

                    applyResolvedLocationIfNeeded(to: &set)

                    if set != originalSet {
                        seasons[seasonIndex].openings[openingIndex].fishingSets[setIndex] = set
                        didMutate = true
                    }
                }
            }
        }

        if didMutate {
            persist()
        }
    }

    private func seasonIndex(for date: Date) -> Int? {
        let year = Calendar.current.component(.year, from: date)
        return seasons.firstIndex(where: { $0.calendarYear == year })
    }

    @discardableResult
    private func ensureCalendarYearSeason(for date: Date, fallbackDistrict: District) -> UUID {
        if let seasonIndex = seasonIndex(for: date) {
            return seasons[seasonIndex].id
        }

        let calendar = Calendar.current
        let year = calendar.component(.year, from: date)
        let yearStart = calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: year,
                month: 1,
                day: 1,
                hour: 12
            )
        ) ?? calendar.startOfDay(for: date)
        let season = SmartLogbookSeason(
            splashDate: yearStart,
            districtKey: fallbackDistrict.key,
            openings: [],
            tenderEntries: [],
            tenderReceiptImageFilenames: [],
            smartLogDriftAutoCreateEnabled: false
        )
        seasons.append(season)
        sortSeasonsByCalendarYear()
        return season.id
    }

    private func sortSeasonsByCalendarYear() {
        seasons.sort { lhs, rhs in
            if lhs.calendarYear != rhs.calendarYear {
                return lhs.calendarYear > rhs.calendarYear
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func isCalendarYearSeasonEmpty(_ season: SmartLogbookSeason) -> Bool {
        season.openings.isEmpty
            && season.tenderEntries.isEmpty
            && season.tenderReceiptImageFilenames.isEmpty
            && !season.smartLogDriftAutoCreateEnabled
    }

    private func openingPosition(for openingID: UUID) -> (seasonIndex: Int, openingIndex: Int)? {
        for seasonIndex in seasons.indices {
            if let openingIndex = seasons[seasonIndex].openings.firstIndex(where: { $0.id == openingID }) {
                return (seasonIndex, openingIndex)
            }
        }
        return nil
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(seasons)
            try data.write(to: persistenceURL, options: .atomic)
            NotificationCenter.default.post(name: .smartLogbookDidChange, object: nil)
        } catch {
            #if DEBUG
            print("⚠️ SmartLogbookStore persist failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func seedDraftFields(from season: SmartLogbookSeason) {
        draftSplashDate = season.splashDate
        draftDistrict = season.currentDistrict
        firstOpeningDate = season.latestOpeningDate ?? season.splashDate
        draftAutoCreateFromDriftAnnouncements = season.smartLogDriftAutoCreateEnabled
    }

    private func resetDraftFields() {
        let today = Calendar.current.startOfDay(for: Date())
        draftSplashDate = today
        draftDistrict = .nushagak
        firstOpeningDate = today
        draftAutoCreateFromDriftAnnouncements = false
    }

    private func districtOverrideKey(for district: District, in season: SmartLogbookSeason) -> String? {
        district.key == season.districtKey ? nil : district.key
    }

    private func openingExists(on date: Date, districtKey: String?, seasonIndex: Int) -> Bool {
        seasons[seasonIndex].openings.contains { opening in
            Calendar.current.isDate(opening.openingDate, inSameDayAs: date)
            && opening.districtKey == districtKey
            && !opening.isDeliveryEntry
        }
    }

    private func resequenceFishingSets(inSeasonAt seasonIndex: Int, openingIndex: Int) {
        seasons[seasonIndex].openings[openingIndex].fishingSets.sort { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
            return lhs.setNumber < rhs.setNumber
        }

        for index in seasons[seasonIndex].openings[openingIndex].fishingSets.indices {
            seasons[seasonIndex].openings[openingIndex].fishingSets[index].setNumber = index + 1
        }
    }

    private func fishingSetPosition(for setID: UUID) -> (seasonIndex: Int, openingIndex: Int, setIndex: Int)? {
        for seasonIndex in seasons.indices {
            for openingIndex in seasons[seasonIndex].openings.indices {
                if let setIndex = seasons[seasonIndex].openings[openingIndex].fishingSets.firstIndex(where: { $0.id == setID }) {
                    return (seasonIndex, openingIndex, setIndex)
                }
            }
        }
        return nil
    }

    private func clearFishingSetAssignments(toOpeningID openingID: UUID, seasonIndex: Int) {
        for openingIndex in seasons[seasonIndex].openings.indices {
            for setIndex in seasons[seasonIndex].openings[openingIndex].fishingSets.indices {
                if seasons[seasonIndex].openings[openingIndex].fishingSets[setIndex].assignedDeliveryOpeningID == openingID {
                    seasons[seasonIndex].openings[openingIndex].fishingSets[setIndex].assignedDeliveryOpeningID = nil
                }
            }
        }
    }

    private func applyResolvedLocationIfNeeded(to set: inout SmartFishingSetRecord) {
        let trimmedLabel = set.locationLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let needsLocationData = trimmedLabel.isEmpty || set.locationKind == nil || set.locationDistrictKey == nil
        guard needsLocationData, let resolved = set.resolvedSetLocation() else { return }

        if trimmedLabel.isEmpty {
            set.locationLabel = resolved.label
        }
        if set.locationKind == nil {
            set.locationKind = resolved.kind
        }
        if set.locationDistrictKey == nil {
            set.locationDistrictKey = resolved.districtKey
        }
    }

    private func storageDistrict(for set: SmartFishingSetRecord, fallbackDistrict: District) -> District {
        if let districtKey = set.locationDistrictKey ?? set.resolvedSetLocation()?.districtKey,
           let district = District(logbookKey: districtKey) {
            return district
        }
        return fallbackDistrict
    }

    private func storageOpeningIndex(for openingDate: Date, district: District, seasonIndex: Int) -> Int {
        let calendar = Calendar.current
        let districtKey = districtOverrideKey(for: district, in: seasons[seasonIndex])

        if let existingIndex = seasons[seasonIndex].openings.firstIndex(where: { opening in
            calendar.isDate(opening.openingDate, inSameDayAs: openingDate)
                && opening.districtKey == districtKey
                && !opening.isRecordedDelivery
        }) {
            return existingIndex
        }

        let opening = SmartLogbookOpening(
            openingDate: openingDate,
            districtKey: districtKey,
            isRecordedDelivery: false,
            isCollapsed: false
        )
        seasons[seasonIndex].openings.append(opening)
        seasons[seasonIndex].openings.sort { $0.openingDate < $1.openingDate }
        return seasons[seasonIndex].openings.firstIndex(where: { $0.id == opening.id }) ?? (seasons[seasonIndex].openings.count - 1)
    }

    private func cleanup(_ season: SmartLogbookSeason) {
        for opening in season.openings {
            opening.fishTicketImageFilenames.forEach { SmartFishTicketStorage.deleteImage(named: $0) }
            opening.qcSheetImageFilenames.forEach { SmartFishTicketStorage.deleteImage(named: $0) }
        }
        season.tenderReceiptImageFilenames.forEach { SmartTenderReceiptStorage.deleteImage(named: $0) }
    }

    private static func makePersistenceURL() -> URL {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return documents.appendingPathComponent("smart_logbook.json")
    }

    private static func loadSeasons(from url: URL) -> [SmartLogbookSeason] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([SmartLogbookSeason].self, from: data)
        } catch {
            #if DEBUG
            print("⚠️ SmartLogbookStore load failed: \(error.localizedDescription)")
            #endif
            return []
        }
    }

    /// Converts legacy, splash-date seasons into a single deterministic card
    /// for each Alaska calendar year without discarding any recorded content.
    @discardableResult
    private static func normalizeCalendarYearSeasons(in seasons: inout [SmartLogbookSeason]) -> Bool {
        let originalSeasons = seasons
        let calendar = Calendar.current
        var normalizedSeasons: [SmartLogbookSeason] = []
        var normalizedIndexByYear: [Int: Int] = [:]

        for var season in seasons {
            let year = calendar.component(.year, from: season.splashDate)
            season.splashDate = calendar.date(
                from: DateComponents(
                    calendar: calendar,
                    timeZone: calendar.timeZone,
                    year: year,
                    month: 1,
                    day: 1,
                    hour: 12
                )
            ) ?? calendar.startOfDay(for: season.splashDate)

            guard let targetIndex = normalizedIndexByYear[year] else {
                normalizedIndexByYear[year] = normalizedSeasons.count
                normalizedSeasons.append(season)
                continue
            }

            let targetDistrictKey = normalizedSeasons[targetIndex].districtKey
            var existingOpeningIDs = Set(normalizedSeasons[targetIndex].openings.map(\.id))
            for var opening in season.openings where existingOpeningIDs.insert(opening.id).inserted {
                if opening.districtKey == nil,
                   opening.openingDistrictKey == nil,
                   season.districtKey != targetDistrictKey {
                    opening.districtKey = season.districtKey
                }
                normalizedSeasons[targetIndex].openings.append(opening)
            }

            var existingTenderEntryIDs = Set(normalizedSeasons[targetIndex].tenderEntries.map(\.id))
            normalizedSeasons[targetIndex].tenderEntries.append(contentsOf: season.tenderEntries.filter {
                existingTenderEntryIDs.insert($0.id).inserted
            })

            var existingReceiptFilenames = Set(normalizedSeasons[targetIndex].tenderReceiptImageFilenames)
            normalizedSeasons[targetIndex].tenderReceiptImageFilenames.append(contentsOf: season.tenderReceiptImageFilenames.filter {
                existingReceiptFilenames.insert($0).inserted
            })
            normalizedSeasons[targetIndex].smartLogDriftAutoCreateEnabled =
                normalizedSeasons[targetIndex].smartLogDriftAutoCreateEnabled
                || season.smartLogDriftAutoCreateEnabled
        }

        for index in normalizedSeasons.indices {
            normalizedSeasons[index].tenderEntries.sort { $0.date < $1.date }
        }
        normalizedSeasons.sort { lhs, rhs in
            if lhs.calendarYear != rhs.calendarYear {
                return lhs.calendarYear > rhs.calendarYear
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        seasons = normalizedSeasons
        return seasons != originalSeasons
    }

    @discardableResult
    private static func migrateLegacyOpeningCreationDates(in seasons: inout [SmartLogbookSeason]) -> Bool {
        var didMigrate = false

        for seasonIndex in seasons.indices {
            let migrationBase = seasons[seasonIndex].splashDate
            for openingIndex in seasons[seasonIndex].openings.indices {
                guard seasons[seasonIndex].openings[openingIndex].createdAt == .distantPast else {
                    continue
                }

                // Preserve the legacy array order exactly; fish-ticket dates may
                // legitimately repeat or move backward after OCR review.
                seasons[seasonIndex].openings[openingIndex].createdAt = migrationBase.addingTimeInterval(
                    Double(openingIndex)
                )
                didMigrate = true
            }
        }

        return didMigrate
    }
}

// MARK: - Persistence models


enum SmartFishingSetTideState: String, Codable, Equatable {
    case flooding
    case ebbing
    case slack
    case unknown

    var arrowSystemName: String {
        switch self {
        case .flooding: return "arrow.up.circle.fill"
        case .ebbing: return "arrow.down.circle.fill"
        case .slack: return "minus.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    var compactArrow: String {
        switch self {
        case .flooding: return "↑"
        case .ebbing: return "↓"
        case .slack: return "–"
        case .unknown: return "?"
        }
    }

    var displayText: String {
        switch self {
        case .flooding: return "Flooding"
        case .ebbing: return "Ebbing"
        case .slack: return "Slack"
        case .unknown: return "Unknown"
        }
    }
}

struct SmartFishingSetTideSnapshot: Codable, Equatable {
    var stationID: String?
    var stationName: String
    var stationDistanceMiles: Double?
    var heightFeet: Double?
    var state: SmartFishingSetTideState

    enum CodingKeys: String, CodingKey {
        case stationID
        case stationName
        case stationDistanceMiles
        case heightFeet
        case state
    }

    init(
        stationID: String? = nil,
        stationName: String = "Nearest NOAA station",
        stationDistanceMiles: Double? = nil,
        heightFeet: Double? = nil,
        state: SmartFishingSetTideState = .unknown
    ) {
        self.stationID = stationID
        self.stationName = stationName
        self.stationDistanceMiles = stationDistanceMiles
        self.heightFeet = heightFeet
        self.state = state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stationID = try container.decodeIfPresent(String.self, forKey: .stationID)
        stationName = try container.decodeIfPresent(String.self, forKey: .stationName) ?? "Nearest NOAA station"
        stationDistanceMiles = try container.decodeIfPresent(Double.self, forKey: .stationDistanceMiles)
        heightFeet = try container.decodeIfPresent(Double.self, forKey: .heightFeet)
        state = try container.decodeIfPresent(SmartFishingSetTideState.self, forKey: .state) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(stationID, forKey: .stationID)
        try container.encode(stationName, forKey: .stationName)
        try container.encodeIfPresent(stationDistanceMiles, forKey: .stationDistanceMiles)
        try container.encodeIfPresent(heightFeet, forKey: .heightFeet)
        try container.encode(state, forKey: .state)
    }

    var compactDisplayText: String {
        guard let heightFeet else { return "— ft \(state.compactArrow)" }
        return String(format: "%.1f ft %@", heightFeet, state.compactArrow)
    }
}

struct SmartFishingSetLocation: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var recordedAt: Date
    var latitude: Double
    var longitude: Double

    init(id: UUID = UUID(), recordedAt: Date, latitude: Double, longitude: Double) {
        self.id = id
        self.recordedAt = recordedAt
        self.latitude = latitude
        self.longitude = longitude
    }

    init(recordedAt: Date, coordinate: CLLocationCoordinate2D) {
        self.id = UUID()
        self.recordedAt = recordedAt
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct SmartFishingSetRecord: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var setNumber: Int = 1
    var startedAt: Date
    var endedAt: Date
    var locations: [SmartFishingSetLocation]
    var startTide: SmartFishingSetTideSnapshot?
    var endTide: SmartFishingSetTideSnapshot?
    var locationLabel: String?
    var locationKind: SmartFishingSetLocationKind?
    var locationDistrictKey: String?
    var assignedDeliveryOpeningID: UUID?
    var catchText: String
    var pickingMinutes: Int?
    var notes: String
    var displayOnNavPage: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case setNumber
        case startedAt
        case endedAt
        case locations
        case startTide
        case endTide
        case locationLabel
        case locationKind
        case locationDistrictKey
        case assignedDeliveryOpeningID
        case catchText
        case pickingMinutes
        case notes
        case displayOnNavPage
    }

    init(
        id: UUID = UUID(),
        setNumber: Int = 1,
        startedAt: Date,
        endedAt: Date,
        locations: [SmartFishingSetLocation],
        startTide: SmartFishingSetTideSnapshot? = nil,
        endTide: SmartFishingSetTideSnapshot? = nil,
        locationLabel: String? = nil,
        locationKind: SmartFishingSetLocationKind? = nil,
        locationDistrictKey: String? = nil,
        assignedDeliveryOpeningID: UUID? = nil,
        catchText: String = "",
        pickingMinutes: Int? = nil,
        notes: String = "",
        displayOnNavPage: Bool = false
    ) {
        self.id = id
        self.setNumber = setNumber
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.locations = locations
        self.startTide = startTide
        self.endTide = endTide
        self.locationLabel = locationLabel
        self.locationKind = locationKind
        self.locationDistrictKey = locationDistrictKey
        self.assignedDeliveryOpeningID = assignedDeliveryOpeningID
        self.catchText = catchText
        self.pickingMinutes = pickingMinutes
        self.notes = notes
        self.displayOnNavPage = displayOnNavPage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        setNumber = try container.decodeIfPresent(Int.self, forKey: .setNumber) ?? 1
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        locations = try container.decodeIfPresent([SmartFishingSetLocation].self, forKey: .locations) ?? []
        startTide = try container.decodeIfPresent(SmartFishingSetTideSnapshot.self, forKey: .startTide)
        endTide = try container.decodeIfPresent(SmartFishingSetTideSnapshot.self, forKey: .endTide)
        locationLabel = try container.decodeIfPresent(String.self, forKey: .locationLabel)
        locationKind = try container.decodeIfPresent(SmartFishingSetLocationKind.self, forKey: .locationKind)
        locationDistrictKey = try container.decodeIfPresent(String.self, forKey: .locationDistrictKey)
        assignedDeliveryOpeningID = try container.decodeIfPresent(UUID.self, forKey: .assignedDeliveryOpeningID)
        catchText = try container.decodeIfPresent(String.self, forKey: .catchText) ?? ""
        pickingMinutes = try container.decodeIfPresent(Int.self, forKey: .pickingMinutes)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        displayOnNavPage = try container.decodeIfPresent(Bool.self, forKey: .displayOnNavPage) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(setNumber, forKey: .setNumber)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(locations, forKey: .locations)
        try container.encodeIfPresent(startTide, forKey: .startTide)
        try container.encodeIfPresent(endTide, forKey: .endTide)
        try container.encodeIfPresent(locationLabel, forKey: .locationLabel)
        try container.encodeIfPresent(locationKind, forKey: .locationKind)
        try container.encodeIfPresent(locationDistrictKey, forKey: .locationDistrictKey)
        try container.encodeIfPresent(assignedDeliveryOpeningID, forKey: .assignedDeliveryOpeningID)
        try container.encode(catchText, forKey: .catchText)
        try container.encodeIfPresent(pickingMinutes, forKey: .pickingMinutes)
        try container.encode(notes, forKey: .notes)
        try container.encode(displayOnNavPage, forKey: .displayOnNavPage)
    }

    var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }

    var driftMiles: Double {
        let orderedLocations = sortedLocations
        guard orderedLocations.count >= 2 else { return 0 }
        var totalMeters: CLLocationDistance = 0
        for pair in zip(orderedLocations, orderedLocations.dropFirst()) {
            let a = CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
            let b = CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude)
            totalMeters += a.distance(from: b)
        }
        return totalMeters / 1609.344
    }

    var sortedLocations: [SmartFishingSetLocation] {
        locations.sorted { $0.recordedAt < $1.recordedAt }
    }
}

struct SmartLogbookSeason: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var splashDate: Date
    var districtKey: String
    var openings: [SmartLogbookOpening]
    var tenderEntries: [SmartLogbookTenderEntry] = []
    var tenderReceiptImageFilenames: [String] = []
    var smartLogDriftAutoCreateEnabled: Bool = false

    enum CodingKeys: String, CodingKey {
        case id
        case splashDate
        case districtKey
        case openings
        case tenderEntries
        case tenderReceiptImageFilenames
        case smartLogDriftAutoCreateEnabled
    }

    init(
        id: UUID = UUID(),
        splashDate: Date,
        districtKey: String,
        openings: [SmartLogbookOpening],
        tenderEntries: [SmartLogbookTenderEntry] = [],
        tenderReceiptImageFilenames: [String] = [],
        smartLogDriftAutoCreateEnabled: Bool = false
    ) {
        self.id = id
        self.splashDate = splashDate
        self.districtKey = districtKey
        self.openings = openings
        self.tenderEntries = tenderEntries
        self.tenderReceiptImageFilenames = tenderReceiptImageFilenames
        self.smartLogDriftAutoCreateEnabled = smartLogDriftAutoCreateEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        splashDate = try container.decode(Date.self, forKey: .splashDate)
        districtKey = try container.decode(String.self, forKey: .districtKey)
        openings = try container.decodeIfPresent([SmartLogbookOpening].self, forKey: .openings) ?? []
        tenderEntries = try container.decodeIfPresent([SmartLogbookTenderEntry].self, forKey: .tenderEntries) ?? []
        tenderReceiptImageFilenames = try container.decodeIfPresent([String].self, forKey: .tenderReceiptImageFilenames) ?? []
        smartLogDriftAutoCreateEnabled = try container.decodeIfPresent(Bool.self, forKey: .smartLogDriftAutoCreateEnabled) ?? false
    }

    var district: District {
        District(logbookKey: districtKey) ?? .nushagak
    }

    var calendarYear: Int {
        Calendar.current.component(.year, from: splashDate)
    }

    var currentDistrict: District {
        openings.max(by: { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        })?.openingDistrict ?? district
    }

    var deliveryOpenings: [SmartLogbookOpening] {
        openings
            .filter(\.isDeliveryEntry)
            .sorted { lhs, rhs in
                switch (lhs.inferredLandingDate, rhs.inferredLandingDate) {
                case let (lhsDate?, rhsDate?):
                    if lhsDate != rhsDate { return lhsDate < rhsDate }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }

                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    var latestOpeningDate: Date? {
        openings.map(\.openingDate).max()
    }
}

struct SmartLogbookOpening: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var openingDate: Date
    var districtKey: String? = nil
    var openingDistrictKey: String? = nil
    var totalCatchLbs: Int? = nil
    var statAreaText: String = ""
    var statAreaSectionText: String = ""
    var startDateCaughtText: String = ""
    var dateLandedText: String = ""
    var timeOfLandingText: String = ""
    var fishTempF: String = ""
    var deliveryTender: String = ""
    var chillType: String = ""
    var driftOpeningStart: Date? = nil
    var driftOpeningEnd: Date? = nil
    var isDriftOpeningConfirmed: Bool = false
    var fishTicketImageFilenames: [String] = []
    var qcSheetImageFilenames: [String] = []
    var fishTicketTallyRows: [SmartFishTicketTallyRow] = []
    var outcomeRawValue: String? = nil
    var notes: String = ""
    /// `nil` means the delivery is not flagged. A non-nil empty string keeps a
    /// newly flagged delivery red while the user has not entered notes yet.
    var flagNotes: String? = nil
    var didDeliver: Bool = true
    var openingHours: Double? = nil
    var isRecordedDelivery: Bool = false
    var isCollapsed: Bool = false
    var fishingSets: [SmartFishingSetRecord] = []

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case openingDate
        case districtKey
        case openingDistrictKey
        case totalCatchLbs
        case statAreaText
        case statAreaSectionText
        case startDateCaughtText
        case dateLandedText
        case timeOfLandingText
        case fishTempF
        case deliveryTender
        case chillType
        case driftOpeningStart
        case driftOpeningEnd
        case isDriftOpeningConfirmed
        case fishTicketImageFilename
        case fishTicketImageFilenames
        case qcSheetImageFilenames
        case fishTicketTallyRows
        case outcomeRawValue
        case notes
        case flagNotes
        case didCaptureFishTicket
        case didDeliver
        case openingHours
        case isRecordedDelivery
        case isCollapsed
        case fishingSets
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        openingDate: Date,
        districtKey: String? = nil,
        openingDistrictKey: String? = nil,
        totalCatchLbs: Int? = nil,
        statAreaText: String = "",
        statAreaSectionText: String = "",
        startDateCaughtText: String = "",
        dateLandedText: String = "",
        timeOfLandingText: String = "",
        fishTempF: String = "",
        deliveryTender: String = "",
        chillType: String = "",
        driftOpeningStart: Date? = nil,
        driftOpeningEnd: Date? = nil,
        isDriftOpeningConfirmed: Bool = false,
        fishTicketImageFilenames: [String] = [],
        qcSheetImageFilenames: [String] = [],
        fishTicketTallyRows: [SmartFishTicketTallyRow] = [],
        outcomeRawValue: String? = nil,
        notes: String = "",
        flagNotes: String? = nil,
        didDeliver: Bool = true,
        openingHours: Double? = nil,
        isRecordedDelivery: Bool = false,
        isCollapsed: Bool = false,
        fishingSets: [SmartFishingSetRecord] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.openingDate = openingDate
        self.districtKey = districtKey
        self.openingDistrictKey = openingDistrictKey
        self.totalCatchLbs = totalCatchLbs
        self.statAreaText = statAreaText
        self.statAreaSectionText = statAreaSectionText
        self.startDateCaughtText = startDateCaughtText
        self.dateLandedText = dateLandedText
        self.timeOfLandingText = timeOfLandingText
        self.fishTempF = fishTempF
        self.deliveryTender = deliveryTender
        self.chillType = chillType
        self.driftOpeningStart = driftOpeningStart
        self.driftOpeningEnd = driftOpeningEnd
        self.isDriftOpeningConfirmed = isDriftOpeningConfirmed
        self.fishTicketImageFilenames = fishTicketImageFilenames
        self.qcSheetImageFilenames = qcSheetImageFilenames
        self.fishTicketTallyRows = fishTicketTallyRows
        self.outcomeRawValue = outcomeRawValue
        self.notes = notes
        self.flagNotes = flagNotes
        self.didDeliver = didDeliver
        self.openingHours = openingHours
        self.isRecordedDelivery = isRecordedDelivery
        self.isCollapsed = isCollapsed
        self.fishingSets = fishingSets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        openingDate = try container.decode(Date.self, forKey: .openingDate)
        districtKey = try container.decodeIfPresent(String.self, forKey: .districtKey)
        openingDistrictKey = try container.decodeIfPresent(String.self, forKey: .openingDistrictKey)
        totalCatchLbs = try container.decodeIfPresent(Int.self, forKey: .totalCatchLbs)
        statAreaText = try container.decodeIfPresent(String.self, forKey: .statAreaText) ?? ""
        statAreaSectionText = try container.decodeIfPresent(String.self, forKey: .statAreaSectionText) ?? ""
        startDateCaughtText = try container.decodeIfPresent(String.self, forKey: .startDateCaughtText) ?? ""
        dateLandedText = try container.decodeIfPresent(String.self, forKey: .dateLandedText) ?? ""
        timeOfLandingText = try container.decodeIfPresent(String.self, forKey: .timeOfLandingText) ?? ""
        fishTempF = try container.decodeIfPresent(String.self, forKey: .fishTempF) ?? ""
        deliveryTender = try container.decodeIfPresent(String.self, forKey: .deliveryTender) ?? ""
        chillType = try container.decodeIfPresent(String.self, forKey: .chillType) ?? ""
        driftOpeningStart = try container.decodeIfPresent(Date.self, forKey: .driftOpeningStart)
        driftOpeningEnd = try container.decodeIfPresent(Date.self, forKey: .driftOpeningEnd)
        isDriftOpeningConfirmed = try container.decodeIfPresent(Bool.self, forKey: .isDriftOpeningConfirmed) ?? false
        let imageArray = try container.decodeIfPresent([String].self, forKey: .fishTicketImageFilenames) ?? []
        if !imageArray.isEmpty {
            fishTicketImageFilenames = imageArray
        } else if let singleFilename = try container.decodeIfPresent(String.self, forKey: .fishTicketImageFilename) {
            fishTicketImageFilenames = [singleFilename]
        } else {
            fishTicketImageFilenames = []
        }
        qcSheetImageFilenames = try container.decodeIfPresent([String].self, forKey: .qcSheetImageFilenames) ?? []
        fishTicketTallyRows = try container.decodeIfPresent([SmartFishTicketTallyRow].self, forKey: .fishTicketTallyRows) ?? []
        outcomeRawValue = try container.decodeIfPresent(String.self, forKey: .outcomeRawValue)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        flagNotes = try container.decodeIfPresent(String.self, forKey: .flagNotes)
        didDeliver = try container.decodeIfPresent(Bool.self, forKey: .didDeliver) ?? true
        openingHours = try container.decodeIfPresent(Double.self, forKey: .openingHours)
        isRecordedDelivery = try container.decodeIfPresent(Bool.self, forKey: .isRecordedDelivery) ?? false
        isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        fishingSets = try container.decodeIfPresent([SmartFishingSetRecord].self, forKey: .fishingSets) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(openingDate, forKey: .openingDate)
        try container.encodeIfPresent(districtKey, forKey: .districtKey)
        try container.encodeIfPresent(openingDistrictKey, forKey: .openingDistrictKey)
        try container.encodeIfPresent(totalCatchLbs, forKey: .totalCatchLbs)
        try container.encode(statAreaText, forKey: .statAreaText)
        try container.encode(statAreaSectionText, forKey: .statAreaSectionText)
        try container.encode(startDateCaughtText, forKey: .startDateCaughtText)
        try container.encode(dateLandedText, forKey: .dateLandedText)
        try container.encode(timeOfLandingText, forKey: .timeOfLandingText)
        try container.encode(fishTempF, forKey: .fishTempF)
        try container.encode(deliveryTender, forKey: .deliveryTender)
        try container.encode(chillType, forKey: .chillType)
        try container.encodeIfPresent(driftOpeningStart, forKey: .driftOpeningStart)
        try container.encodeIfPresent(driftOpeningEnd, forKey: .driftOpeningEnd)
        try container.encode(isDriftOpeningConfirmed, forKey: .isDriftOpeningConfirmed)
        try container.encode(fishTicketImageFilenames, forKey: .fishTicketImageFilenames)
        try container.encode(qcSheetImageFilenames, forKey: .qcSheetImageFilenames)
        try container.encode(fishTicketTallyRows, forKey: .fishTicketTallyRows)
        try container.encodeIfPresent(fishTicketImageFilenames.first, forKey: .fishTicketImageFilename)
        try container.encode(didCaptureFishTicket, forKey: .didCaptureFishTicket)
        try container.encodeIfPresent(outcomeRawValue, forKey: .outcomeRawValue)
        try container.encode(notes, forKey: .notes)
        try container.encodeIfPresent(flagNotes, forKey: .flagNotes)
        try container.encode(didDeliver, forKey: .didDeliver)
        try container.encodeIfPresent(openingHours, forKey: .openingHours)
        try container.encode(isRecordedDelivery, forKey: .isRecordedDelivery)
        try container.encode(isCollapsed, forKey: .isCollapsed)
        try container.encode(fishingSets, forKey: .fishingSets)
    }

    var fishTicketSummaryImageFilename: String? {
        fishTicketImageFilenames.first
    }

    var fishTicketTallyImageFilenames: [String] {
        Array(fishTicketImageFilenames.dropFirst())
    }

    var didCaptureFishTicket: Bool {
        fishTicketSummaryImageFilename != nil
    }

    var hasCapturedFishTicketTally: Bool {
        !fishTicketTallyImageFilenames.isEmpty
    }

    var hasCapturedQCSheets: Bool {
        !qcSheetImageFilenames.isEmpty
    }

    /// Landing chronology is derived from OCR/user-entered landing fields rather
    /// than creation order. An incomplete record stays after dated deliveries
    /// until Date Landed is supplied, then automatically moves into place.
    var inferredLandingDate: Date? {
        SmartLogbookParse.fishTicketLandingDate(
            dateText: dateLandedText,
            timeText: timeOfLandingText
        )
    }

    var outcome: SmartLogbookOutcome? {
        outcomeRawValue.flatMap(SmartLogbookOutcome.init(rawValue:))
    }

    var hasAppliedDeliveryFields: Bool {
        totalCatchLbs != nil
            || !statAreaText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !startDateCaughtText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !dateLandedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !timeOfLandingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !fishTempF.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !deliveryTender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !chillType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || didCaptureFishTicket
            || hasCapturedQCSheets
            || !fishTicketTallyRows.isEmpty
    }

    var isBlankOCRDeliveryDraft: Bool {
        isRecordedDelivery
            && !hasAppliedDeliveryFields
            && fishingSets.isEmpty
            && notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && flagNotes == nil
            && driftOpeningStart == nil
            && driftOpeningEnd == nil
            && openingHours == nil
            && outcomeRawValue == nil
    }

    var isDeliveryEntry: Bool {
        isRecordedDelivery || hasAppliedDeliveryFields
    }

    var openingDistrict: District? {
        if let openingDistrictKey {
            return District(logbookKey: openingDistrictKey)
        }
        guard let districtKey else { return nil }
        return District(logbookKey: districtKey)
    }
}

struct SmartLogbookTenderEntry: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var date: Date
    var tenderName: String = ""
    var fuelGallons: Double?
    var groceriesDescription: String = ""
    var groceriesAmount: Double?
    var miscDescription: String = ""
    var miscAmount: Double?

    var hasAnyValue: Bool {
        fuelGallons != nil
            || (!groceriesDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && groceriesAmount != nil)
            || (!miscDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && miscAmount != nil)
    }
}

enum SmartLogbookOutcome: String, CaseIterable, Identifiable, Codable {
    case tough
    case steady
    case hot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tough: return "Tough"
        case .steady: return "Steady"
        case .hot: return "Hot"
        }
    }

    var tint: Color {
        switch self {
        case .tough: return smartLogbookBad
        case .steady: return smartLogbookWarn
        case .hot: return smartLogbookGood
        }
    }

    var compactThumbSystemName: String {
        "hand.thumbsup.fill"
    }

    var compactThumbRotation: Angle {
        switch self {
        case .hot: return .degrees(0)
        case .steady: return .degrees(90)
        case .tough: return .degrees(180)
        }
    }
}

// MARK: - Smart data providers

struct SmartLogbookDashboardSnapshot {
    let openingText: String
    let openingNote: String?
    let driftOpeningStart: Date?
    let driftOpeningEnd: Date?
    let dailyHarvest: String
    let cumulativeHarvest: String
    let dailyEscapement: String
    let cumulativeEscapement: String
    let driftPermits: String
    let driftBoats: String
    let freshnessText: String
    let openingHours: Double?
}


struct SmartLogbookTideCurvePoint: Equatable, Identifiable {
    let time: Date
    let heightFeet: Double

    var id: Date { time }
}

struct SmartLogbookTideChartMarker: Identifiable {
    let date: Date
    let label: String
    var color: Color = .white.opacity(0.80)
    var annotationAlignment: Alignment = .leading

    var id: String {
        "\(date.timeIntervalSince1970)-\(label)"
    }
}

struct SmartLogbookTideCurveChartView: View {
    let points: [SmartLogbookTideCurvePoint]
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
    var selectedPoint: SmartLogbookTideCurvePoint? = nil
    var selectedPointRuleColor: Color = .primary.opacity(0.45)
    var selectedPointMarkerColor: Color = .primary
    var onSelectPoint: ((SmartLogbookTideCurvePoint?) -> Void)? = nil
    var showsReferenceRule: Bool = true
    var highlightedRange: ClosedRange<Date>? = nil
    var highlightedRangeColor: Color = .blue.opacity(0.12)
    var markers: [SmartLogbookTideChartMarker] = []

    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.heightFeet).filter { $0.isFinite }
        guard let minValue = values.min(), let maxValue = values.max() else {
            return -1...1
        }

        if minValue == maxValue {
            return (minValue - 1)...(maxValue + 1)
        }

        let padding = max((maxValue - minValue) * 0.10, 0.25)
        return (minValue - padding)...(maxValue + padding)
    }

    var body: some View {
        if points.isEmpty {
            Text(emptyMessage)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(emptyMessageColor)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .center)
        } else {
            Chart {
                if let highlightedRange {
                    RectangleMark(
                        xStart: .value("Opening Start", highlightedRange.lowerBound),
                        xEnd: .value("Opening End", highlightedRange.upperBound),
                        yStart: .value("Low", yDomain.lowerBound),
                        yEnd: .value("High", yDomain.upperBound)
                    )
                    .foregroundStyle(highlightedRangeColor)
                }

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
                                .background(Color.black.opacity(0.35))
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
            .chartYScale(domain: yDomain)
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
        }
    }
}

struct SmartLogbookEnvironmentSnapshot {
    let tidePrimaryText: String
    let tideSecondaryText: String
    let tideCurvePoints: [SmartLogbookTideCurvePoint]
    let weatherPrimaryText: String
    let weatherSecondaryText: String?
    let cloudText: String
    let windTempText: String
    let sourceText: String
}

// MARK: - Reusable UI pieces
// MARK: - Reusable UI pieces

private struct SmartLogbookDateField: View {
    let title: String
    @Binding var selection: Date
    var minimumDate: Date? = nil
    var maximumDate: Date? = nil
    var showsContainer: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.70))

            Group {
                if let minimumDate, let maximumDate {
                    DatePicker(
                        "",
                        selection: $selection,
                        in: minimumDate...maximumDate,
                        displayedComponents: .date
                    )
                } else if let minimumDate {
                    DatePicker(
                        "",
                        selection: $selection,
                        in: minimumDate...Date.distantFuture,
                        displayedComponents: .date
                    )
                } else {
                    DatePicker(
                        "",
                        selection: $selection,
                        displayedComponents: .date
                    )
                }
            }
            .datePickerStyle(.compact)
            .labelsHidden()
            .tint(.white)
            .colorScheme(.dark)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, showsContainer ? 10 : 0)
            .frame(minHeight: smartLogbookSelectorHeight)
            .background(showsContainer ? AnyView(smartLogbookFieldBackground) : AnyView(Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SmartLogbookDateTimePickerField: View {
    let title: String
    @Binding var selection: Date
    let displayedComponents: DatePickerComponents
    var isLocked: Bool = false
    var forcesAMPM: Bool = false
    var showsContainer: Bool = true

    private var pickerLocale: Locale {
        forcesAMPM ? Locale(identifier: "en_US") : Locale.current
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.70))

            DatePicker(
                "",
                selection: $selection,
                displayedComponents: displayedComponents
            )
            .datePickerStyle(.compact)
            .labelsHidden()
            .tint(.white)
            .colorScheme(.dark)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, showsContainer ? 10 : 0)
            .frame(minHeight: smartLogbookSelectorHeight)
            .background(showsContainer ? AnyView(smartLogbookFieldBackground) : AnyView(Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(showsContainer ? Color.white.opacity(0.08) : Color.clear, lineWidth: 1)
            )
            .environment(\.locale, pickerLocale)
            .disabled(isLocked)
            .opacity(isLocked ? 0.78 : 1.0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SmartOptionalDistrictField: View {
    let title: String
    @Binding var selection: District?
    let placeholder: String
    var excluding: District? = nil

    private var availableDistricts: [District] {
        District.allCases.filter { $0 != excluding }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.70))

            Menu {
                ForEach(availableDistricts) { district in
                    Button(district.rawValue) {
                        selection = district
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selection?.rawValue ?? placeholder)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(selection == nil ? .white.opacity(0.55) : .white)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.65))
                }
                .padding(.horizontal, 10)
                .frame(minHeight: smartLogbookSelectorHeight)
                .background(smartLogbookFieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(SatChartPressFeedbackButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SmartLogbookDistrictField: View {
    let title: String
    @Binding var selection: District

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.70))

            Menu {
                ForEach(District.allCases) { district in
                    Button(district.rawValue) {
                        selection = district
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selection.rawValue)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.65))
                }
                .padding(.horizontal, 10)
                .frame(minHeight: smartLogbookSelectorHeight)
                .background(smartLogbookFieldBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(SatChartPressFeedbackButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SmartSummaryCapsule: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.62))
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.08))
        .clipShape(Capsule())
    }
}

private struct SmartSummaryRow: View {
    let title: String
    let value: String
    let caption: String?
    let systemImage: String
    let dateTag: String?
    var status: SmartFieldReleaseStatus? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .center, spacing: 8) {
                    Text(title)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.70))

                    if let dateTag {
                        SmartAutoFieldDateTag(text: dateTag)
                    }

                    if let status {
                        SmartFieldStatusBadge(status: status)
                    }

                    Spacer(minLength: 0)
                }

                Text(value)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)

                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.64))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .smartLogbookInsetStyle()
    }
}

private struct SmartMetricListRow: View {
    let title: String
    let value: String
    let dateTag: String?
    var status: SmartFieldReleaseStatus? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.72))
            Spacer(minLength: 0)
            if let status {
                SmartFieldStatusBadge(status: status)
            }
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
            if let dateTag {
                SmartAutoFieldDateTag(text: dateTag)
            }
        }
        .padding(10)
        .smartLogbookInsetStyle()
    }
}

private enum SmartFieldReleaseStatus {
    case releasedToday
    case pendingRelease

    var systemImage: String {
        switch self {
        case .releasedToday: return "checkmark.circle.fill"
        case .pendingRelease: return "clock.badge.exclamationmark"
        }
    }

    var tint: Color {
        switch self {
        case .releasedToday: return smartLogbookGood
        case .pendingRelease: return smartLogbookWarn
        }
    }
}

private struct SmartFieldStatusBadge: View {
    let status: SmartFieldReleaseStatus

    var body: some View {
        Image(systemName: status.systemImage)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(status.tint)
    }
}

private struct SmartStatusHintBadge: View {
    let systemImage: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(tint)
            Text(text)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.78))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.08))
        .clipShape(Capsule())
    }
}

private struct SmartLogAutomationToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button {
                isOn.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text(isOn ? "On" : "Off")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    ZStack(alignment: isOn ? .trailing : .leading) {
                        Capsule()
                            .fill((isOn ? smartLogbookGood : Color.white.opacity(0.16)))
                            .frame(width: 40, height: 22)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 18, height: 18)
                            .padding(2)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
            }
            .buttonStyle(SatChartPressFeedbackButtonStyle())
        }
        .padding(10)
        .smartLogbookInsetStyle()
    }
}

private struct SmartAutoFieldDateTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundColor(.white.opacity(0.90))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.10))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
    }
}

private struct SmartTextFieldBox: View {
    let title: String?
    @Binding var text: String
    let placeholder: String
    var keyboardType: UIKeyboardType = .default
    var capitalization: TextInputAutocapitalization = .never
    var highlighted: Bool = false
    var textColor: Color = .white
    var placeholderColor: Color = .white.opacity(0.70)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.70))
            }

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(placeholderColor)
                        .padding(.horizontal, 10)
                }

                TextField("", text: $text)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(capitalization)
                    .disableAutocorrection(true)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(textColor)
                    .tint(textColor)
                    .padding(.horizontal, 10)
            }
            .frame(minHeight: 38)
            .background(highlighted ? smartLogbookAccentSecondary.opacity(0.32) : smartLogbookFieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(highlighted ? smartLogbookAccentSecondary.opacity(0.65) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SmartInlineTextField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var keyboardType: UIKeyboardType = .default
    var capitalization: TextInputAutocapitalization = .never

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.70))

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.70))
                        .padding(.horizontal, 10)
                }

                TextField("", text: $text)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(capitalization)
                    .disableAutocorrection(true)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .tint(.white)
                    .padding(.horizontal, 10)
            }
            .frame(minHeight: smartLogbookSelectorHeight)
            .background(smartLogbookFieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SmartInlineTextFieldCompact: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var keyboardType: UIKeyboardType = .default
    var capitalization: TextInputAutocapitalization = .never

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            titleView
            inputField
        }
    }

    private var titleView: some View {
        Text(title)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundColor(.white.opacity(0.70))
    }

    private var inputField: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.68))
                    .padding(.horizontal, 10)
            }

            TextField("", text: $text)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(capitalization)
                .disableAutocorrection(true)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .tint(.white)
                .padding(.horizontal, 10)
        }
        .frame(minHeight: 30)
        .background(Color.white.opacity(0.08))
        .clipShape(Capsule())
    }
}

private struct SmartValueOnlyInputCard: View {
    let title: String
    @Binding var valueText: String
    let valuePlaceholder: String
    var keyboardType: UIKeyboardType = .decimalPad

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerView
            valueRow
        }
        .padding(10)
        .background(Color.black.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var headerView: some View {
        Text(title)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundColor(.white.opacity(0.72))
    }

    private var valueRow: some View {
        HStack(spacing: 8) {
            labelCapsule
                .layoutPriority(1)
            valueCapsule
        }
    }

    private var labelCapsule: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())
    }

    private var valueCapsule: some View {
        ZStack(alignment: .leading) {
            if valueText.isEmpty {
                Text(valuePlaceholder)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.68))
                    .padding(.horizontal, 10)
            }

            TextField("", text: $valueText)
                .keyboardType(keyboardType)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .tint(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
        }
        .frame(width: 78, height: 30)
        .background(Color.white.opacity(0.08))
        .clipShape(Capsule())
    }
}

private struct SmartAmountPairInputCard: View {
    let title: String
    @Binding var descriptionText: String
    let descriptionPlaceholder: String
    @Binding var amountText: String
    let amountPlaceholder: String
    var footerText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerView
            inputRow
            footerView
        }
        .padding(10)
        .background(Color.black.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var headerView: some View {
        Text(title)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundColor(.white.opacity(0.72))
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            descriptionField
                .layoutPriority(1)
            amountField
        }
    }

    private var descriptionField: some View {
        ZStack(alignment: .leading) {
            if descriptionText.isEmpty {
                Text(descriptionPlaceholder)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.68))
                    .padding(.horizontal, 10)
            }

            TextField("", text: $descriptionText)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .tint(.white)
                .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(Color.white.opacity(0.08))
        .clipShape(Capsule())
    }

    private var amountField: some View {
        ZStack(alignment: .leading) {
            if amountText.isEmpty {
                Text(amountPlaceholder)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.68))
                    .padding(.horizontal, 10)
            }

            TextField("", text: $amountText)
                .keyboardType(.decimalPad)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .tint(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
        }
        .frame(width: 78, height: 30)
        .background(Color.white.opacity(0.08))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var footerView: some View {
        if let footerText, !footerText.isEmpty {
            Text(footerText)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.82))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct SmartImageThumbnailStrip: View {
    let images: [UIImage]
    var height: CGFloat = 92

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { entry in
                    Image(uiImage: entry.element)
                        .resizable()
                        .scaledToFill()
                        .frame(width: height * 0.78, height: height)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        )
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct SmartTenderLedgerRowModel: Identifiable {
    let dateText: String
    let primaryText: String
    let secondaryText: String?

    var id: String {
        [dateText, primaryText, secondaryText ?? ""].joined(separator: "|")
    }
}

private struct SmartPurchasesLedgerCard: View {
    let title: String
    let rows: [SmartTenderLedgerRowModel]
    let totalText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            if rows.isEmpty {
                Text("No entries")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.70))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
            } else {
                ForEach(rows) { row in
                    SmartCompactLedgerRow(row: row)
                }
            }

            Text(totalText)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.90))
        }
        .padding(12)
        .background(Color.black.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct SmartCompactLedgerRow: View {
    let row: SmartTenderLedgerRowModel

    var body: some View {
        HStack(spacing: 8) {
            Text(row.dateText)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.80))
                .padding(.horizontal, 9)
                .frame(minHeight: 28)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())

            Text(row.primaryText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())

            if let secondaryText = row.secondaryText, !secondaryText.isEmpty {
                Text(secondaryText)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 28)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
            }
        }
    }
}

private struct SmartSinglePhotoCaptureView: View {
    let sourceType: UIImagePickerController.SourceType
    let onCapture: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SmartSystemImagePicker(
            sourceType: sourceType,
            onCancel: { dismiss() },
            onImagePicked: { image in
                dismiss()
                DispatchQueue.main.async {
                    onCapture(image.smartLogbookPreparedUIImage(maxDimension: SmartFishTicketOCRProfile.capturePreviewMaxDimension) ?? image)
                }
            }
        )
        .ignoresSafeArea()
    }
}

private struct SmartSystemImagePicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onCancel: () -> Void
    let onImagePicked: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        if sourceType == .camera {
            picker.cameraCaptureMode = .photo
        }
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCancel: onCancel, onImagePicked: onImagePicked)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onCancel: () -> Void
        let onImagePicked: (UIImage) -> Void

        init(onCancel: @escaping () -> Void, onImagePicked: @escaping (UIImage) -> Void) {
            self.onCancel = onCancel
            self.onImagePicked = onImagePicked
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImagePicked(image)
            } else {
                onCancel()
            }
        }
    }
}

private nonisolated final class SmartFishTicketCapturedImageBatch: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var images: [UIImage]

    init(_ images: [UIImage]) {
        self.images = images
    }

    private func takeImages() -> [UIImage] {
        lock.lock()
        defer { lock.unlock() }
        let ownedImages = images
        images.removeAll(keepingCapacity: false)
        return ownedImages
    }

    func saveAllAndRelease() async -> [String] {
        let ownedImages = takeImages()
        guard !ownedImages.isEmpty else { return [] }
        return await SmartFishTicketStorage.saveImagesAsync(ownedImages)
    }

    func saveFirstAndRelease() async -> String? {
        await saveAllAndRelease().first
    }
}

nonisolated enum SmartFishTicketStorage {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SatChart",
        category: "FishTicketStorage"
    )
    private static let previewMaxDimension = 720
    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 6
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    private static var folderURL: URL {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let folder = documents.appendingPathComponent("SmartLogbookFishTickets", isDirectory: true)

        if !fm.fileExists(atPath: folder.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
        }
        return folder
    }

    private static func cacheKey(for filename: String) -> NSString {
        filename as NSString
    }

    private static func previewCacheKey(for filename: String) -> NSString {
        "\(filename)#preview-\(previewMaxDimension)" as NSString
    }

    static func fileURL(named filename: String) -> URL {
        folderURL.appendingPathComponent(filename)
    }

    static func fileExists(named filename: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(named: filename).path)
    }

    static func loadData(named filename: String) -> Data? {
        try? Data(contentsOf: fileURL(named: filename))
    }

    static func saveImageAsync(_ image: UIImage) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                    continuation.resume(returning: saveImage(image))
                }
            }
        }
    }

    static func saveImagesAsync(_ images: [UIImage]) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                    continuation.resume(returning: images.compactMap { saveImage($0) })
                }
            }
        }
    }

    static func saveImage(_ image: UIImage) -> String? {
        let filename = UUID().uuidString + ".jpg"
        let url = folderURL.appendingPathComponent(filename)
        guard let data = image.smartLogbookJPEGData(maxDimension: SmartFishTicketOCRProfile.storedImageMaxDimension, compressionQuality: 0.78)
                ?? image.jpegData(compressionQuality: 0.80) else {
            return nil
        }

        do {
            try data.write(to: url, options: .atomic)
            imageCache.removeObject(forKey: cacheKey(for: filename))
            return filename
        } catch {
            logger.error(
                "Could not save fish-ticket image \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    static func saveImages(_ images: [UIImage]) -> [String] {
        images.compactMap { image in
            saveImage(image)
        }
    }

    static func loadImage(named filename: String) -> UIImage? {
        let key = cacheKey(for: filename)
        if let cached = imageCache.object(forKey: key) {
            return cached
        }

        let url = fileURL(named: filename)
        guard let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            return nil
        }

        imageCache.setObject(image, forKey: key, cost: image.smartLogbookApproximateMemoryCost)
        return image
    }

    static func loadOCRImage(named filename: String, maxDimension: CGFloat) -> UIImage? {
        let url = fileURL(named: filename)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxDimension.rounded())),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    static func loadPreviewImage(named filename: String) -> UIImage? {
        let key = previewCacheKey(for: filename)
        if let cached = imageCache.object(forKey: key) {
            return cached
        }

        let url = fileURL(named: filename)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: previewMaxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let image = UIImage(cgImage: cgImage)
        imageCache.setObject(image, forKey: key, cost: image.smartLogbookApproximateMemoryCost)
        return image
    }

    static func clearMemoryCache() {
        imageCache.removeAllObjects()
    }

    static func deleteImage(named filename: String) {
        imageCache.removeObject(forKey: cacheKey(for: filename))
        imageCache.removeObject(forKey: previewCacheKey(for: filename))
        try? FileManager.default.removeItem(at: fileURL(named: filename))
    }
}


private nonisolated extension UIImage {
    func smartLogbookNormalizedCGImage(
        maxDimension: CGFloat = 2400,
        topLeftCropRect: CGRect? = nil
    ) -> CGImage? {
        smartLogbookRenderedCGImage(
            maxDimension: maxDimension,
            topLeftCropRect: topLeftCropRect,
            applyPerspectiveCorrection: true
        )
    }

    func smartLogbookPreparedUIImage(maxDimension: CGFloat) -> UIImage? {
        guard let renderedCGImage = smartLogbookRenderedCGImage(
            maxDimension: maxDimension,
            topLeftCropRect: nil,
            applyPerspectiveCorrection: false
        ) else {
            return nil
        }

        return UIImage(cgImage: renderedCGImage, scale: 1, orientation: .up)
    }

    var smartLogbookApproximateMemoryCost: Int {
        if let cgImage {
            return max(1, cgImage.width * cgImage.height * 4)
        }

        let pixelWidth = max(1, Int((size.width * scale).rounded()))
        let pixelHeight = max(1, Int((size.height * scale).rounded()))
        return max(1, pixelWidth * pixelHeight * 4)
    }

    func smartLogbookJPEGData(
        maxDimension: CGFloat = 2800,
        compressionQuality: CGFloat = 0.82
    ) -> Data? {
        guard let renderedCGImage = smartLogbookRenderedCGImage(
            maxDimension: maxDimension,
            topLeftCropRect: nil,
            applyPerspectiveCorrection: false
        ) else {
            return jpegData(compressionQuality: compressionQuality)
        }

        let destinationData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            destinationData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ]
        CGImageDestinationAddImage(destination, renderedCGImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return destinationData as Data
    }

    private func smartLogbookRenderedCGImage(
        maxDimension: CGFloat,
        topLeftCropRect: CGRect?,
        applyPerspectiveCorrection: Bool
    ) -> CGImage? {
        guard let sourceCGImage = smartLogbookRenderableCGImage() else { return nil }

        var ciImage = CIImage(cgImage: sourceCGImage)
            .oriented(imageOrientation.smartLogbookCGImagePropertyOrientation)

        let initialExtent = ciImage.extent.integral
        guard !initialExtent.isEmpty else { return nil }

        let maxSide = max(initialExtent.width, initialExtent.height)
        if maxDimension > 0,
           maxSide > maxDimension,
           let scaleFilter = CIFilter(name: "CILanczosScaleTransform") {
            let scale = maxDimension / maxSide
            scaleFilter.setValue(ciImage, forKey: kCIInputImageKey)
            scaleFilter.setValue(scale, forKey: kCIInputScaleKey)
            scaleFilter.setValue(1.0, forKey: kCIInputAspectRatioKey)
            if let scaled = scaleFilter.outputImage {
                ciImage = scaled
            }
        }

        let renderedExtent = ciImage.extent.integral
        guard !renderedExtent.isEmpty,
              let renderedCGImage = SmartLogbookImageRendering.sharedCIContext.createCGImage(ciImage, from: renderedExtent) else {
            return nil
        }

        let baseCGImage = applyPerspectiveCorrection
            ? (renderedCGImage.smartLogbookPerspectiveCorrectedCGImage() ?? renderedCGImage)
            : renderedCGImage

        guard let topLeftCropRect else { return baseCGImage }

        let pixelRect = CGRect(
            x: max(0, min(CGFloat(baseCGImage.width), topLeftCropRect.minX * CGFloat(baseCGImage.width))),
            y: max(0, min(CGFloat(baseCGImage.height), topLeftCropRect.minY * CGFloat(baseCGImage.height))),
            width: max(1, min(CGFloat(baseCGImage.width), topLeftCropRect.width * CGFloat(baseCGImage.width))),
            height: max(1, min(CGFloat(baseCGImage.height), topLeftCropRect.height * CGFloat(baseCGImage.height)))
        ).integral

        return baseCGImage.cropping(to: pixelRect) ?? baseCGImage
    }

    private func smartLogbookRenderableCGImage() -> CGImage? {
        if let cgImage {
            return cgImage
        }

        if let ciImage {
            let extent = ciImage.extent.integral
            guard !extent.isEmpty else { return nil }
            return SmartLogbookImageRendering.sharedCIContext.createCGImage(ciImage, from: extent)
        }

        return nil
    }
}

private nonisolated extension UIImage.Orientation {
    var smartLogbookCGImagePropertyOrientation: CGImagePropertyOrientation {
        switch self {
        case .up:
            return .up
        case .down:
            return .down
        case .left:
            return .left
        case .right:
            return .right
        case .upMirrored:
            return .upMirrored
        case .downMirrored:
            return .downMirrored
        case .leftMirrored:
            return .leftMirrored
        case .rightMirrored:
            return .rightMirrored
        @unknown default:
            return .up
        }
    }
}

private nonisolated extension CGImage {
    func smartLogbookPerspectiveCorrectedCGImage() -> CGImage? {
        let ciImage = CIImage(cgImage: self)
        let detectorOptions: [String: Any] = [
            CIDetectorAccuracy: CIDetectorAccuracyHigh,
            CIDetectorMinFeatureSize: 0.25
        ]

        guard let detector = CIDetector(
            ofType: CIDetectorTypeRectangle,
            context: nil,
            options: detectorOptions
        ) else {
            return nil
        }

        let imageExtent = ciImage.extent
        let imageArea = imageExtent.width * imageExtent.height

        let rectangles = (detector.features(in: ciImage) as? [CIRectangleFeature]) ?? []
        let bestRectangle = rectangles
            .compactMap { feature -> (feature: CIRectangleFeature, score: CGFloat)? in
                let topWidth = hypot(feature.topRight.x - feature.topLeft.x, feature.topRight.y - feature.topLeft.y)
                let bottomWidth = hypot(feature.bottomRight.x - feature.bottomLeft.x, feature.bottomRight.y - feature.bottomLeft.y)
                let leftHeight = hypot(feature.topLeft.x - feature.bottomLeft.x, feature.topLeft.y - feature.bottomLeft.y)
                let rightHeight = hypot(feature.topRight.x - feature.bottomRight.x, feature.topRight.y - feature.bottomRight.y)

                let averageWidth = (topWidth + bottomWidth) / 2.0
                let averageHeight = (leftHeight + rightHeight) / 2.0
                guard averageWidth > 0, averageHeight > 0 else { return nil }

                let area = averageWidth * averageHeight
                let coverage = area / max(1.0, imageArea)
                let aspect = min(averageWidth, averageHeight) / max(averageWidth, averageHeight)

                guard coverage >= 0.35 else { return nil }
                guard aspect >= 0.55, aspect <= 0.90 else { return nil }

                let widthDenominator = max(max(topWidth, bottomWidth), 1.0)
                let heightDenominator = max(max(leftHeight, rightHeight), 1.0)
                let widthBalance = 1.0 - min(1.0, abs(topWidth - bottomWidth) / widthDenominator)
                let heightBalance = 1.0 - min(1.0, abs(leftHeight - rightHeight) / heightDenominator)
                let score = (coverage * 100.0) + (aspect * 20.0) + (widthBalance * 8.0) + (heightBalance * 8.0)
                return (feature, score)
            }
            .max(by: { $0.score < $1.score })?
            .feature

        guard let bestRectangle else { return nil }

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
            return nil
        }

        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: bestRectangle.topLeft), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: bestRectangle.topRight), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: bestRectangle.bottomRight), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: bestRectangle.bottomLeft), forKey: "inputBottomLeft")

        guard let outputImage = filter.outputImage else { return nil }
        let outputExtent = outputImage.extent.integral
        guard !outputExtent.isEmpty else { return nil }

        return SmartLogbookImageRendering.sharedCIContext.createCGImage(outputImage, from: outputExtent)
    }
}

enum SmartTenderReceiptStorage {
    private static var folderURL: URL {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let folder = documents.appendingPathComponent("SmartLogbookTenderReceipts", isDirectory: true)

        if !fm.fileExists(atPath: folder.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
        }
        return folder
    }

    static func fileURL(named filename: String) -> URL {
        folderURL.appendingPathComponent(filename)
    }

    static func fileExists(named filename: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(named: filename).path)
    }

    static func loadData(named filename: String) -> Data? {
        try? Data(contentsOf: fileURL(named: filename))
    }

    static func saveImage(_ image: UIImage) -> String? {
        let filename = UUID().uuidString + ".jpg"
        let url = fileURL(named: filename)
        guard let data = image.jpegData(compressionQuality: 0.82) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            return nil
        }
    }

    static func loadImage(named filename: String) -> UIImage? {
        guard let data = loadData(named: filename) else { return nil }
        return UIImage(data: data)
    }

    static func deleteImage(named filename: String) {
        try? FileManager.default.removeItem(at: fileURL(named: filename))
    }
}

// MARK: - Formatting helpers

private enum SmartLogbookFormat {
    static let alaskaCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Anchorage") ?? .current
        return calendar
    }()

    static let dayTitle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = TimeZone(identifier: "America/Anchorage")
        return formatter
    }()

    static let dayKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Anchorage")
        return formatter
    }()

    static let dayMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d/yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Anchorage")
        return formatter
    }()

    static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Anchorage")
        return formatter
    }()

    static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Anchorage")
        return formatter
    }()

    static func dateTimeLine(_ date: Date) -> String {
        "\(dayMonth.string(from: date)), \(clockFormatter.string(from: date))"
    }

    static func timeLine(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    static func monthDayTimeLine(_ date: Date) -> String {
        "\(monthDay.string(from: date)) \(clockFormatter.string(from: date))"
    }

    static func compactOpeningDateTimeLine(_ date: Date) -> String {
        monthDayTimeLine(date)
    }

    static func driftOpeningSummary(start: Date, end: Date) -> String {
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return "\(dayMonth.string(from: start)) \(clockFormatter.string(from: start))–\(clockFormatter.string(from: end))"
        }
        return "\(dayMonth.string(from: start)) \(clockFormatter.string(from: start))–\(dayMonth.string(from: end)) \(clockFormatter.string(from: end))"
    }

    static func alaskaDayKey(from date: Date) -> String {
        dayKey.string(from: date)
    }

    static func dateFromDayKey(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return dayKey.date(from: raw)
    }

    static func clockText(fromISO raw: String?) -> String? {
        guard let date = parseISO(raw) else { return nil }
        return clockFormatter.string(from: date)
    }

    static func parseISO(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }

        let base = ISO8601DateFormatter()
        if let date = base.date(from: raw) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }

        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.timeZone = TimeZone(secondsFromGMT: 0)
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return fallback.date(from: raw)
    }

    static func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func decimal(_ value: Double, maxFractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maxFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func currency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    static func hours(_ value: Double) -> String {
        if value == 0 { return "0 hr" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        let text = formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
        return "\(text) hr"
    }

}

private enum SmartLogbookParse {
    static func decimal(from raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let strippedCurrency = trimmed.replacingOccurrences(of: "$", with: "")
        let normalized: String
        if strippedCurrency.contains(".") {
            normalized = strippedCurrency.replacingOccurrences(of: ",", with: "")
        } else {
            normalized = strippedCurrency.replacingOccurrences(of: ",", with: ".")
        }

        return Double(normalized)
    }

    static func currencyInput(from raw: String) -> String {
        let digitsAndDecimal = raw.filter { $0.isNumber || $0 == "." }
        if digitsAndDecimal.isEmpty { return "" }
        return "$" + digitsAndDecimal
    }

    nonisolated static func collapsedWhitespace(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedAnchor(_ raw: String) -> String {
        let repaired = raw.lowercased()
            .replacingOccurrences(of: "chilltype", with: "chill type")
            .replacingOccurrences(of: "tendername", with: "tender name")
            .replacingOccurrences(of: "statarea", with: "stat area")
            .replacingOccurrences(of: "statisticalarea", with: "statistical area")
            .replacingOccurrences(of: "startdatecaught", with: "start date caught")
            .replacingOccurrences(of: "enddatecaught", with: "end date caught")
            .replacingOccurrences(of: "datelanded", with: "date landed")
            .replacingOccurrences(of: "timeoflanding", with: "time of landing")
            .replacingOccurrences(of: "soldweight", with: "sold weight")
            .replacingOccurrences(of: "posttare", with: "post tare")
            .replacingOccurrences(of: "delcond", with: "del cond")
            .replacingOccurrences(of: "fishtemperature", with: "fish temperature")
        return collapsedWhitespace(
            repaired
                .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        )
    }

    static func firstRegexCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard
            let match = regex.firstMatch(in: text, options: [], range: nsRange),
            match.numberOfRanges > 1,
            let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        return String(text[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func firstInteger(in raw: String) -> Int? {
        allIntegers(in: raw).first
    }

    static func integerLikeTokens(in raw: String) -> [String] {
        let normalizedRaw = normalizedNumericOCRSource(raw)
        guard let regex = try? NSRegularExpression(pattern: #"[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+"#, options: []) else {
            return []
        }
        let nsRange = NSRange(normalizedRaw.startIndex..<normalizedRaw.endIndex, in: normalizedRaw)
        return regex.matches(in: normalizedRaw, options: [], range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: normalizedRaw) else { return nil }
            return String(normalizedRaw[range])
        }
    }

    static func allIntegers(in raw: String) -> [Int] {
        integerLikeTokens(in: raw).compactMap { token in
            Int(token.replacingOccurrences(of: ",", with: ""))
        }
    }

    static func bestSoldWeightInteger(in raw: String) -> Int? {
        let collapsed = collapsedWhitespace(raw)
        let lowered = collapsed.lowercased()

        let directPatterns = [
            #"total\s*:?\s*([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)\s+([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)\s+t\.?\s*tare\b"#,
            #"total\s*:?\s*([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)\s+([0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)\b"#
        ]

        for pattern in directPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let nsRange = NSRange(collapsed.startIndex..<collapsed.endIndex, in: collapsed)
            guard let match = regex.firstMatch(in: collapsed, options: [], range: nsRange), match.numberOfRanges >= 3 else { continue }
            guard
                let firstRange = Range(match.range(at: 1), in: collapsed),
                let secondRange = Range(match.range(at: 2), in: collapsed)
            else {
                continue
            }

            let firstValue = Int(collapsed[firstRange].replacingOccurrences(of: ",", with: "")) ?? 0
            let secondValue = Int(collapsed[secondRange].replacingOccurrences(of: ",", with: "")) ?? 0
            if secondValue > firstValue {
                return secondValue
            }
        }

        guard let totalRange = lowered.range(of: "total") else {
            return firstInteger(in: collapsed)
        }

        var suffix = String(collapsed[totalRange.lowerBound...])
        for stopPhrase in ["t tare", "total tare", "landing report", "taxes", "thumb drive", "cfec serial"] {
            if let stopRange = suffix.lowercased().range(of: stopPhrase) {
                suffix = String(suffix[..<stopRange.lowerBound])
            }
        }

        let digitGroups = digitGroupTokens(in: suffix)
        if let bestPair = bestTotalRowNumberPair(from: digitGroups) {
            return bestPair.soldWeight
        }

        let integerTokens = integerLikeTokens(in: suffix).compactMap { Int($0.replacingOccurrences(of: ",", with: "")) }
        if integerTokens.count >= 2, integerTokens[1] > integerTokens[0] {
            return integerTokens[1]
        }

        return integerTokens.max()
    }

    private static func digitGroupTokens(in raw: String) -> [String] {
        let normalizedRaw = normalizedNumericOCRSource(raw)
        guard let regex = try? NSRegularExpression(pattern: #"[0-9]{1,3}"#, options: []) else {
            return []
        }
        let nsRange = NSRange(normalizedRaw.startIndex..<normalizedRaw.endIndex, in: normalizedRaw)
        return regex.matches(in: normalizedRaw, options: [], range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: normalizedRaw) else { return nil }
            return String(normalizedRaw[range])
        }
    }

    private static func bestTotalRowNumberPair(from digitGroups: [String]) -> (fishCount: Int, soldWeight: Int)? {
        guard !digitGroups.isEmpty else { return nil }

        let limitedGroups = Array(digitGroups.prefix(6))
        let partitions = groupedNumberPartitions(from: limitedGroups, maxNumbers: 3)
        let ranked = partitions.compactMap { groups -> (score: Double, fishCount: Int, soldWeight: Int)? in
            guard groups.count >= 2 else { return nil }
            let numbers = groups.compactMap { tokens -> Int? in
                let joined = tokens.joined()
                return Int(joined)
            }
            guard numbers.count == groups.count else { return nil }

            let fishCount = numbers[0]
            let soldWeight = numbers[1]
            guard fishCount > 0, soldWeight > 0 else { return nil }
            guard fishCount <= 10000, soldWeight <= 200000 else { return nil }

            var score = 0.0
            if soldWeight > fishCount { score += 80 } else { score -= 120 }
            if soldWeight >= 100 { score += 20 }
            if fishCount <= 10000 { score += 12 }
            if soldWeight <= 200000 { score += 8 }
            if groups.count >= 3 { score += 10 }

            if groups[0].count == 2 { score += 12 }
            if groups[1].count == 2 { score += 18 }

            if groups[0].count == 2, groups[0][1].count == 3 { score += 14 }
            if groups[1].count == 2, groups[1][1].count == 3 { score += 18 }

            if numbers.count >= 3 {
                let tare = numbers[2]
                if tare >= 0 && tare < soldWeight { score += 8 }
                if tare <= 1000 { score += 4 }
            }

            if soldWeight > fishCount * 2 { score += 8 }
            if fishCount < 50, soldWeight <= 50 { score -= 10 }
            if fishCount == 1, soldWeight > 1 { score += 6 }

            return (score, fishCount, soldWeight)
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.soldWeight > $1.soldWeight
        }

        guard let best = ranked.first, best.score > 0 else { return nil }
        return (best.fishCount, best.soldWeight)
    }

    private static func groupedNumberPartitions(from digitGroups: [String], maxNumbers: Int) -> [[[String]]] {
        guard !digitGroups.isEmpty, maxNumbers > 0 else { return [] }

        var results: [[[String]]] = []

        func walk(_ index: Int, _ current: [[String]]) {
            if index >= digitGroups.count || current.count >= maxNumbers {
                if !current.isEmpty {
                    results.append(current)
                }
                return
            }

            let remainingNumbersAllowed = maxNumbers - current.count
            guard remainingNumbersAllowed > 0 else { return }

            // Single-group number.
            walk(index + 1, current + [[digitGroups[index]]])

            // Two-group number, only when the trailing group looks like a 3-digit continuation.
            if index + 1 < digitGroups.count, digitGroups[index + 1].count == 3 {
                walk(index + 2, current + [[digitGroups[index], digitGroups[index + 1]]])
            }
        }

        walk(0, [])
        return results.filter { !$0.isEmpty && $0.count >= 2 }
    }

    static func digitGroupTokensForTotalRow(in raw: String) -> [String] {
        digitGroupTokens(in: raw)
    }

    static func bestTotalRowNumberPairForSoldWeight(in digitGroups: [String]) -> (fishCount: Int, soldWeight: Int)? {
        bestTotalRowNumberPair(from: digitGroups)
    }

    static func normalizedNumericOCRSource(_ raw: String) -> String {
        String(raw.map { character in
            switch character {
            case "O", "o", "Q", "q", "D": return "0"
            case "I", "i", "l", "|": return "1"
            case "Z", "z": return "2"
            case "S", "s": return "5"
            case "G", "g": return "6"
            case "B": return "8"
            default: return character
            }
        })
    }

    static func firstDecimalString(in raw: String) -> String? {
        firstTemperatureString(in: raw)
    }

    static func firstTemperatureString(in raw: String) -> String? {
        let collapsed = collapsedWhitespace(raw)
            .replacingOccurrences(of: #"\s*([.:])\s*"#, with: "$1", options: .regularExpression)
        guard !collapsed.isEmpty else { return nil }

        guard let regex = try? NSRegularExpression(pattern: #"[0-9]{1,4}(?:\.[0-9])?"#, options: []) else {
            return nil
        }

        let nsRange = NSRange(collapsed.startIndex..<collapsed.endIndex, in: collapsed)
        let matches = regex.matches(in: collapsed, options: [], range: nsRange)

        var ranked: [(score: Double, text: String)] = []
        ranked.reserveCapacity(matches.count * 6)

        func appendCandidate(_ value: Double, sourceText: String, bonus: Double = 0) {
            guard value >= 20, value <= 45 else { return }

            var score = 100.0 - (abs(value - 35.0) * 4.0)
            if (30...40).contains(value) { score += 12 }
            if sourceText.contains(".") { score += 6 }
            if sourceText.hasSuffix(".0") { score += 3 }
            score += bonus

            let roundedTenths = (value * 10).rounded() / 10
            ranked.append((score, String(format: "%.1f", roundedTenths)))
        }

        for match in matches {
            guard let range = Range(match.range, in: collapsed) else { continue }
            let token = String(collapsed[range])

            if let direct = Double(token) {
                appendCandidate(direct, sourceText: token, bonus: 10)
            }

            let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            let digitsOnly = token.replacingOccurrences(of: #"[^0-9]"#, with: "", options: .regularExpression)

            if parts.count == 2,
               let integerPart = parts.first,
               let fractionPart = parts.last,
               integerPart.count == 3,
               fractionPart.count == 1 {
                let digits = Array(integerPart)
                for removedIndex in digits.indices {
                    var reduced = digits
                    reduced.remove(at: removedIndex)
                    let candidateText = String(reduced) + "." + fractionPart
                    if let candidate = Double(candidateText) {
                        let middleDigitBonus = removedIndex == 1 ? 4.0 : 0
                        appendCandidate(candidate, sourceText: candidateText, bonus: middleDigitBonus)
                    }
                }
            }

            if digitsOnly.count == 3 {
                let compact = String(digitsOnly.prefix(2)) + "." + String(digitsOnly.suffix(1))
                if let candidate = Double(compact) {
                    appendCandidate(candidate, sourceText: compact, bonus: 5)
                }
            } else if digitsOnly.count == 4 {
                let digits = Array(digitsOnly)
                let first = String(digits[0...1]) + "." + String(digits[2])
                if let candidate = Double(first) {
                    appendCandidate(candidate, sourceText: first)
                }
                let second = String(digits[1...2]) + "." + String(digits[3])
                if let candidate = Double(second) {
                    appendCandidate(candidate, sourceText: second)
                }
            }
        }

        return ranked
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.text > $1.text
            }
            .first?
            .text
    }

    static func firstDateString(in raw: String) -> String? {
        let normalizedRaw = collapsedWhitespace(raw)
            .replacingOccurrences(of: #"\s*([\/\-])\s*"#, with: "$1", options: .regularExpression)
        guard let range = normalizedRaw.range(of: #"[0-9]{1,2}[\/\-][0-9]{1,2}[\/\-][0-9]{2,4}"#, options: .regularExpression) else {
            return nil
        }
        return normalizedFishTicketDate(String(normalizedRaw[range]))
    }

    static func first24HourTimeString(in raw: String) -> String? {
        let normalizedRaw = collapsedWhitespace(raw)
            .replacingOccurrences(of: #"\s*([:.\-])\s*"#, with: "$1", options: .regularExpression)
        if let range = normalizedRaw.range(of: #"(?:[01]?\d|2[0-3])[:.\-][0-5]\d"#, options: .regularExpression) {
            return normalizedFishTicketTime(String(normalizedRaw[range]))
        }
        if let range = normalizedRaw.range(of: #"\b[0-9]{3,4}\b"#, options: .regularExpression) {
            return normalizedFishTicketTime(String(normalizedRaw[range]))
        }
        return nil
    }

    static func normalizedFishTicketDate(_ raw: String) -> String {
        collapsedWhitespace(raw)
            .replacingOccurrences(of: #"\s*([\/\-])\s*"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "-", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: ":;- "))
    }

    static func fishTicketDate(from raw: String) -> Date? {
        let normalized = firstDateString(in: raw) ?? normalizedFishTicketDate(raw)
        let parts = normalized.split(separator: "/")
        guard parts.count == 3,
              let month = Int(parts[0]),
              let day = Int(parts[1]),
              let yearValue = Int(parts[2]) else {
            return nil
        }

        let resolvedYear: Int
        if parts[2].count == 2 {
            resolvedYear = 2000 + yearValue
        } else {
            resolvedYear = yearValue
        }

        var components = DateComponents()
        components.calendar = SmartLogbookFormat.alaskaCalendar
        components.timeZone = TimeZone(identifier: "America/Anchorage")
        components.year = resolvedYear
        components.month = month
        components.day = day
        components.hour = 12
        components.minute = 0
        components.second = 0
        return SmartLogbookFormat.alaskaCalendar.date(from: components)
    }

    static func fishTicketLandingDate(dateText: String, timeText: String) -> Date? {
        guard let landedDay = fishTicketDate(from: dateText) else { return nil }

        let calendar = SmartLogbookFormat.alaskaCalendar
        var components = calendar.dateComponents([.year, .month, .day], from: landedDay)
        components.calendar = calendar
        components.timeZone = calendar.timeZone

        if let landingTime = fishTicketTimeComponents(from: timeText) {
            components.hour = landingTime.hour
            components.minute = landingTime.minute
        } else {
            components.hour = 0
            components.minute = 0
        }
        components.second = 0
        return calendar.date(from: components)
    }

    /// Duplicate detection requires all three user-requested keys, including a
    /// valid landing time. Sorting intentionally remains more permissive through
    /// `fishTicketLandingDate`, which falls back to midnight when time is absent.
    static func exactFishTicketLandingDate(dateText: String, timeText: String) -> Date? {
        guard let landedDay = fishTicketDate(from: dateText),
              let landingTime = fishTicketTimeComponents(from: timeText) else {
            return nil
        }

        let calendar = SmartLogbookFormat.alaskaCalendar
        var components = calendar.dateComponents([.year, .month, .day], from: landedDay)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.hour = landingTime.hour
        components.minute = landingTime.minute
        components.second = 0
        return calendar.date(from: components)
    }

    private static func fishTicketTimeComponents(from raw: String) -> (hour: Int, minute: Int)? {
        let uppercased = collapsedWhitespace(raw).uppercased()
        guard !uppercased.isEmpty else { return nil }

        let isPM = uppercased.contains("PM") || uppercased.contains("P.M.")
        let isAM = uppercased.contains("AM") || uppercased.contains("A.M.")
        let timeOnly = uppercased
            .replacingOccurrences(of: "A.M.", with: "")
            .replacingOccurrences(of: "P.M.", with: "")
            .replacingOccurrences(of: "AM", with: "")
            .replacingOccurrences(of: "PM", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizedFishTicketTime(timeOnly)
        let parts = normalized.split(separator: ":")
        guard parts.count == 2,
              var hour = Int(parts[0]),
              let minute = Int(parts[1]),
              minute >= 0,
              minute < 60 else {
            return nil
        }

        if isPM {
            guard hour >= 1, hour <= 12 else { return nil }
            if hour < 12 { hour += 12 }
        } else if isAM {
            guard hour >= 1, hour <= 12 else { return nil }
            if hour == 12 { hour = 0 }
        } else {
            guard hour >= 0, hour <= 23 else { return nil }
        }

        return (hour, minute)
    }

    static func normalizedFishTicketTime(_ raw: String) -> String {
        let collapsed = collapsedWhitespace(raw)
            .replacingOccurrences(of: #"\s*([:.\-])\s*"#, with: "$1", options: .regularExpression)
        if let range = collapsed.range(of: #"(?:[01]?\d|2[0-3])[:.\-][0-5]\d"#, options: .regularExpression) {
            return String(collapsed[range])
                .replacingOccurrences(of: ".", with: ":")
                .replacingOccurrences(of: "-", with: ":")
        }

        let digits = collapsed.replacingOccurrences(of: #"[^0-9]"#, with: "", options: .regularExpression)
        if digits.count == 3 {
            let hour = digits.prefix(1)
            let minute = digits.suffix(2)
            return "0\(hour):\(minute)"
        }
        if digits.count == 4 {
            let hour = digits.prefix(2)
            let minute = digits.suffix(2)
            if let directHour = Int(hour), directHour <= 23 {
                return "\(hour):\(minute)"
            }

            let characters = Array(digits)
            if let firstDigit = Int(String(characters[0])),
               let secondDigit = Int(String(characters[1])),
               secondDigit <= 3 {
                let leadingCandidates: [Int]
                switch firstDigit {
                case 5...9:
                    leadingCandidates = [2, 1, 0]
                case 3...4:
                    leadingCandidates = [1, 2, 0]
                default:
                    leadingCandidates = [0, 1, 2]
                }

                for leading in leadingCandidates {
                    let candidateHour = (leading * 10) + secondDigit
                    if candidateHour <= 23 {
                        return String(format: "%02d:%@", candidateHour, String(minute))
                    }
                }
            }

            return "\(hour):\(minute)"
        }
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ":;- "))
    }

    static func textAfterAnchor(_ text: String, anchorPhrases: [String]) -> String? {
        let collapsed = collapsedWhitespace(text)
        let normalized = normalizedAnchor(collapsed)

        for phrase in anchorPhrases {
            guard let range = normalized.range(of: phrase) else { continue }
            let prefixNormalized = String(normalized[..<range.lowerBound])
            let prefixTokenCount = prefixNormalized.isEmpty ? 0 : prefixNormalized.split(separator: " ").count
            let tokens = collapsed.split(separator: " ", omittingEmptySubsequences: true)
            guard prefixTokenCount <= tokens.count else { continue }
            let suffixTokens = tokens.dropFirst(prefixTokenCount + phrase.split(separator: " ").count)
            if !suffixTokens.isEmpty {
                return suffixTokens.joined(separator: " ")
            }
        }

        return nil
    }

    static func cleanedFishTicketValue(_ raw: String, for field: SmartFishTicketField) -> String {
        let collapsed = collapsedWhitespace(raw)

        switch field {
        case .postTare:
            if let value = bestSoldWeightInteger(in: collapsed) {
                return SmartLogbookFormat.number(value)
            }
            if let value = firstInteger(in: collapsed) {
                return SmartLogbookFormat.number(value)
            }
            return collapsed

        case .statArea:
            if let resolution = BristolBayStatAreaResolver.resolve(collapsed) {
                return resolution.normalizedStatArea
            }
            let normalized = normalizedNumericOCRSource(collapsed)
                .replacingOccurrences(of: #"[^0-9.\-\s]"#, with: " ", options: .regularExpression)
            return collapsedWhitespace(normalized)

        case .startDateCaught, .dateLanded:
            return firstDateString(in: collapsed) ?? ""

        case .timeOfLanding:
            return first24HourTimeString(in: collapsed) ?? ""

        case .temperature:
            return firstTemperatureString(in: collapsed) ?? ""

        case .chillType:
            let clipped = clipAtStopPhrases(
                in: collapsed,
                stopPhrases: ["temperature", "temp", "start date caught", "date landed", "time of landing"]
            )
            if let tokenRange = clipped.range(of: #"\b[A-Za-z]{2,10}(?:\/[A-Za-z]{2,10})?\b"#, options: .regularExpression) {
                return clipped[tokenRange].uppercased()
            }
            return clipped.trimmingCharacters(in: CharacterSet(charactersIn: ":;- ")).uppercased()

        case .tenderName:
            var clipped = clipAtStopPhrases(
                in: collapsed,
                stopPhrases: [
                    "chill type",
                    "temperature",
                    "temp",
                    "start date caught",
                    "date landed",
                    "time of landing",
                    "owner",
                    "custom processor",
                    "permit",
                    "vessel",
                    "mag stripe",
                    "read",
                    "adf g",
                    "adfg"
                ]
            )
            clipped = clipped.replacingOccurrences(of: #"\bmag\s*stripe\b.*$"#, with: "", options: .regularExpression)
            clipped = clipped.replacingOccurrences(of: #"\bread\b.*$"#, with: "", options: .regularExpression)
            clipped = clipped.replacingOccurrences(of: #"[^A-Za-z0-9 .&'\/-]"#, with: " ", options: .regularExpression)
            clipped = collapsedWhitespace(clipped)

            let normalized = normalizedAnchor(clipped)
            let bannedPhrases = ["mag stripe", "permit", "owner", "vessel", "processor", "adfg", "adf g", "read"]
            if clipped.isEmpty || bannedPhrases.contains(where: { normalized.contains($0) }) {
                return ""
            }
            return clipped
        }
    }

    static func normalizedIntegerString(_ raw: String) -> String {
        guard let value = firstInteger(in: raw) else { return "" }
        return SmartLogbookFormat.number(value)
    }

    static func normalizedBrailersString(_ raw: String) -> String {
        let candidates = allIntegers(in: raw)
        if let value = candidates.first(where: { (1...4).contains($0) }) {
            return String(value)
        }
        return ""
    }

    nonisolated static func cleanedTallyText(_ raw: String) -> String {
        collapsedWhitespace(raw)
            .replacingOccurrences(of: #"[^A-Za-z0-9, .&'\/-]"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":;- "))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    static func cleanedFishTicketTallyRow(_ row: SmartFishTicketTallyRow) -> SmartFishTicketTallyRow {
        SmartFishTicketTallyRow(
            id: row.id,
            speciesText: cleanedTallyText(row.speciesText),
            deliveryConditionText: cleanedTallyText(row.deliveryConditionText),
            soldWeightText: normalizedIntegerString(row.soldWeightText),
            brailersText: normalizedBrailersString(row.brailersText)
        )
    }

    static func clipAtStopPhrases(in raw: String, stopPhrases: [String]) -> String {
        var bestIndex: String.Index? = nil
        let lower = raw.lowercased()
        for phrase in stopPhrases {
            if let range = lower.range(of: phrase) {
                if bestIndex == nil || range.lowerBound < bestIndex! {
                    bestIndex = range.lowerBound
                }
            }
        }
        if let bestIndex {
            return String(raw[..<bestIndex]).trimmingCharacters(in: CharacterSet(charactersIn: ":;- "))
        }
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: ":;- "))
    }

    static func firstTimeRange(in text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }

        let pattern = #"\b\d{1,2}(?::\d{2})?\s?[AP]M\s*[–-]\s*\d{1,2}(?::\d{2})?\s?[AP]M\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range]).replacingOccurrences(of: " - ", with: "–")
    }
}

// MARK: - JSON helpers

private extension Dictionary where Key == String, Value == Any {
    func stringValue(forKey key: String) -> String? {
        if let value = self[key] as? String { return value }
        if let value = self[key] as? NSNumber { return value.stringValue }
        return nil
    }

    func dictionaryValue(forKey key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func arrayOfDictionaries(forKey key: String) -> [[String: Any]] {
        self[key] as? [[String: Any]] ?? []
    }

    func nestedDisplayText(path: [String]) -> String? {
        var cursor: [String: Any] = self
        for step in path {
            guard let next = cursor[step] as? [String: Any] else { return nil }
            cursor = next
        }
        return cursor["displayText"] as? String
    }
}

// MARK: - District helpers

private extension District {
    init?(logbookKey: String) {
        switch logbookKey {
        case "naknek_kvichak": self = .naknekKvichak
        case "egegik": self = .egegik
        case "ugashik": self = .ugashik
        case "nushagak": self = .nushagak
        case "togiak": self = .togiak
        default: return nil
        }
    }

    var logbookAnchorCoordinate: CLLocationCoordinate2D {
        switch self {
        case .naknekKvichak:
            return CLLocationCoordinate2D(latitude: 58.74, longitude: -156.88)
        case .egegik:
            return CLLocationCoordinate2D(latitude: 58.22, longitude: -157.37)
        case .ugashik:
            return CLLocationCoordinate2D(latitude: 57.55, longitude: -157.67)
        case .nushagak:
            return CLLocationCoordinate2D(latitude: 58.70, longitude: -157.50)
        case .togiak:
            return CLLocationCoordinate2D(latitude: 59.06, longitude: -160.37)
        }
    }
}

// MARK: - Styling helpers

private extension View {
    func smartLogbookCardStyle() -> some View {
        self
            .padding(14)
            .background(smartLogbookCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: smartLogbookCardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: smartLogbookCardCornerRadius, style: .continuous)
                    .stroke(smartLogbookCardBorder, lineWidth: 1)
            )
    }

    func smartLogbookInsetStyle(highlighted: Bool = false) -> some View {
        self
            .background(highlighted ? smartLogbookAccentSecondary.opacity(0.18) : smartLogbookFieldBackgroundSoft)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(highlighted ? smartLogbookAccentSecondary.opacity(0.45) : Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    func smartLogbookDeliveryCardStyle(compact: Bool = false) -> some View {
        self
            .padding(compact ? 12 : 13)
            .background(Color.black.opacity(compact ? 0.12 : 0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    func smartLogbookPrimaryButtonStyle(disabled: Bool = false, fillColor: Color = smartLogbookAccent) -> some View {
        self
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: smartLogbookPrimaryButtonHeight)
            .background(disabled ? Color.white.opacity(0.10) : fillColor)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    func smartLogbookSecondaryButtonStyle(fillColor: Color = Color.white.opacity(0.10)) -> some View {
        self
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: smartLogbookPrimaryButtonHeight)
            .background(fillColor)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    func smartLogbookSmallAccentButtonStyle(disabled: Bool = false) -> some View {
        self
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(disabled ? Color.white.opacity(0.10) : smartLogbookAccent)
            .clipShape(Capsule())
            .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    func smartLogbookSmallSecondaryButtonStyle() -> some View {
        self
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(Color.white.opacity(0.10))
            .clipShape(Capsule())
            .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    func smartLogbookSmallPillButtonStyle(fillColor: Color, textColor: Color = .white) -> some View {
        self
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundColor(textColor)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(fillColor)
            .clipShape(Capsule())
            .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    func smartLogbookIconButtonStyle() -> some View {
        self
            .foregroundColor(.white)
            .padding(8)
            .background(Color.white.opacity(0.10))
            .clipShape(Circle())
            .buttonStyle(SatChartPressFeedbackButtonStyle())
    }
}


// Optional alias so the drop-in file can be referenced by the requested name.
typealias SmrtLogbookView = SmartLogbookView
