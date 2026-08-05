import SwiftUI

struct FisheryResourcesDownloadsView: View {
    @StateObject private var store = FisheryResourceCatalogStore.shared

    private let resourceCategories: [FisheryResourceCategory] = [
        .friInseasonReports,
        .portMollerTestFishing,
        .historicalFMR,
        .districtBoundariesMaps
    ]

    var body: some View {
        SatChartAccountScaffold(title: "Fishery Resources & Downloads") {
            disclaimerCard
            FisheryResourceCatalogStatusCard(store: store)

            ForEach(resourceCategories) { category in
                resourceCard(for: category)
            }
        }
        .task {
            await store.loadIfNeeded()
        }
        .refreshable {
            await store.reload()
        }
    }

    private var disclaimerCard: some View {
        SatChartAccountCard(title: "Official Source Notice") {
            Text("Official source links are provided for convenience. SatChart may cache or summarize links, but users should verify openings, closures, emergency orders, regulations, weather, and safety information directly with official sources.")
                .font(.footnote)
                .foregroundStyle(scTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("SatChart is not the official source. ADF&G, BBSRI, FRI, and Alaska Salmon Program names remain property of their owners and do not imply endorsement.")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.yellow.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resourceCard(for category: FisheryResourceCategory) -> some View {
        SatChartAccountCard(title: category.title) {
            let items = resourceItems(for: category)
            if items.isEmpty {
                Text(category.emptyMessage)
                    .font(.footnote)
                    .foregroundStyle(scTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(items) { item in
                    FisheryResourceRow(item: item)
                }
            }
        }
    }

    private func resourceItems(for category: FisheryResourceCategory) -> [FisheryResourceItem] {
        let items = store.items(for: category)
        switch category {
        case .friInseasonReports:
            let directBristolBayItems = items.filter(Self.isDirectBristolBayFRILink)
            let directIDs = Set(directBristolBayItems.map(\.id))
            return directBristolBayItems + items.filter { !directIDs.contains($0.id) }
        case .portMollerTestFishing:
            let resultLinks = items.filter(Self.isPortMollerResultsLink)
            return resultLinks.isEmpty ? items : resultLinks
        case .historicalFMR, .districtBoundariesMaps:
            return items
        case .adfgAnnouncements:
            return []
        }
    }

    private nonisolated static func isDirectBristolBayFRILink(_ item: FisheryResourceItem) -> Bool {
        let url = item.urlString.lowercased()
        return url.contains("alaskasalmonprogram.org/bristol-bay-daily-updates")
    }

    private nonisolated static func isPortMollerResultsLink(_ item: FisheryResourceItem) -> Bool {
        let title = item.title.lowercased()
        let subtitle = item.subtitle?.lowercased() ?? ""
        let notes = item.notes?.lowercased() ?? ""
        let releaseType = item.releaseType?.lowercased() ?? ""
        let url = item.urlString.lowercased()
        let searchableText = [title, subtitle, notes, releaseType].joined(separator: " ")

        if searchableText.contains("project page")
            || searchableText.contains("project link")
            || searchableText.contains("program page")
            || url.contains("/pmtf")
            || url.contains("/2025-inseason-data") {
            return false
        }

        return true
    }
}

struct FisheryAnnouncementsView: View {
    @StateObject private var store = FisheryResourceCatalogStore.shared
    @State private var announcementFilter = FisheryResourceDistrict.allFilterID

    var body: some View {
        SatChartAccountScaffold(title: "Announcements") {
            announcementNoticeCard
            FisheryResourceCatalogStatusCard(store: store)
            announcementsCard
        }
        .task {
            await store.loadIfNeeded()
        }
        .refreshable {
            await store.reload()
        }
    }

    private var announcementNoticeCard: some View {
        SatChartAccountCard(title: "ADF&G Bristol Bay Announcements") {
            Text("This page only shows ADF&G links that directly display Bristol Bay fishery advisory announcements, emergency orders, or the Bristol Bay salmon announcement feed.")
                .font(.footnote)
                .foregroundStyle(scTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Always verify openings, closures, and emergency orders directly with ADF&G before acting on them.")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.yellow.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var announcementsCard: some View {
        SatChartAccountCard(title: FisheryResourceCategory.adfgAnnouncements.title) {
            Text("Filter Bristol Bay announcement links by district. Baywide links remain visible for district filters.")
                .font(.footnote)
                .foregroundStyle(scTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FisheryResourceDistrict.filters, id: \.id) { filter in
                        Button {
                            announcementFilter = filter.id
                        } label: {
                            Text(filter.title)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(announcementFilter == filter.id ? Color.black : scTextPrimary)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .background(announcementFilter == filter.id ? scAccent : scSurfaceAlt)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(SatChartPressFeedbackButtonStyle())
                    }
                }
            }

            SatChartAccountButton(
                title: store.isLoading ? "Refreshing..." : "Refresh",
                systemImage: "arrow.clockwise",
                style: .secondary,
                isLoading: store.isLoading
            ) {
                Task { await store.reload() }
            }

            let filteredItems = filteredAnnouncementItems
            if filteredItems.isEmpty {
                Text(FisheryResourceCategory.adfgAnnouncements.emptyMessage)
                    .font(.footnote)
                    .foregroundStyle(scTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(filteredItems) { item in
                    FisheryResourceRow(item: item)
                }
            }
        }
    }

    private var filteredAnnouncementItems: [FisheryResourceItem] {
        let items = store.items(for: .adfgAnnouncements)
            .filter(Self.isDirectBristolBayAnnouncementLink)

        guard announcementFilter != FisheryResourceDistrict.allFilterID else {
            return items
        }

        return items.filter { item in
            item.districtKeys.contains(announcementFilter) || item.districtKeys.contains("baywide")
        }
    }

    private nonisolated static func isDirectBristolBayAnnouncementLink(_ item: FisheryResourceItem) -> Bool {
        let url = item.urlString.lowercased()
        let title = item.title.lowercased()
        let documentType = item.documentType?.lowercased() ?? ""
        let releaseType = item.releaseType?.lowercased() ?? ""
        let bristolDistrictKeys: Set<String> = [
            "baywide",
            "naknek_kvichak",
            "egegik",
            "ugashik",
            "nushagak",
            "togiak"
        ]
        let isBristolScoped = item.districtKeys.contains { bristolDistrictKeys.contains($0) }

        guard url.contains("adfg.alaska.gov"), isBristolScoped else {
            return false
        }

        let isRSSItem = documentType == "rss_item" || releaseType == "rss_item"
        let isDynamicWebLink = documentType == "web_link" || releaseType == "dynamic_page_link"

        if url.contains("static/applications/web/rss/bristolsalmon.xml") {
            return true
        }

        if url.contains("commercialbyareabristolbay.salmon#fishery") {
            return true
        }

        if isRSSItem {
            return true
        }

        let looksLikeAnnouncement = title.contains("announcement")
            || title.contains("emergency order")
            || title.contains("opening")
            || title.contains("closure")
            || title.contains("extension")
            || title.contains("update")
            || title.contains("outlook")

        if url.contains("/static/applications/dcfnewsrelease/") {
            return (documentType.isEmpty || documentType == "pdf" || isDynamicWebLink) && looksLikeAnnouncement
        }

        return isDynamicWebLink && looksLikeAnnouncement
    }
}

private struct FisheryResourceCatalogStatusCard: View {
    @ObservedObject var store: FisheryResourceCatalogStore

    var body: some View {
        SatChartAccountCard(title: "Catalog Status") {
            HStack(alignment: .center, spacing: 10) {
                if store.isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: store.loadedSource == .firestore ? "checkmark.circle.fill" : "externaldrive")
                        .foregroundStyle(store.loadedSource == .firestore ? Color.green : Color.orange)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(store.dataStatusSummary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(scTextPrimary)
                    Text("Collection: fisheryResources/{category}/items/{itemId}")
                        .font(.caption)
                        .foregroundStyle(scTextSecondary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 8)
            }

            if let errorMessage = store.errorMessage {
                SatChartAccountMessage(text: errorMessage, isError: true)
            }

            SatChartAccountButton(
                title: store.isLoading ? "Refreshing..." : "Refresh",
                systemImage: "arrow.clockwise",
                style: .secondary,
                isLoading: store.isLoading
            ) {
                Task { await store.reload() }
            }
        }
    }
}

private struct FisheryResourceRow: View {
    let item: FisheryResourceItem

    var body: some View {
        if let url = item.url {
            Link(destination: url) {
                rowContent(accessorySystemImage: "arrow.up.right")
            }
            .buttonStyle(SatChartPressFeedbackButtonStyle())
        } else {
            rowContent(accessorySystemImage: "exclamationmark.triangle.fill")
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.orange.opacity(0.65), lineWidth: 1)
                )
        }
    }

    private func rowContent(accessorySystemImage: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(scTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if item.isOfficialSource {
                        Text("Official")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.green.opacity(0.92))
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .background(Color.green.opacity(0.14))
                            .clipShape(Capsule())
                    }
                }

                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(scTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 7) {
                    Text(item.sourceName)
                    if let publishedAt = item.publishedAt {
                        Text(Self.dateFormatter.string(from: publishedAt))
                    }
                    if let year = item.seasonYear ?? item.year {
                        Text(String(year))
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(scTextSecondary)

                if !item.districtKeys.isEmpty {
                    FlowTagRow(tags: item.districtKeys.map(FisheryResourceDistrict.displayName(for:)))
                }

                if item.url == nil {
                    Text("This resource URL is invalid. Please contact \(SatChartReleaseConfiguration.supportEmail).")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(item.urlString)
                        .font(.caption2)
                        .foregroundStyle(scTextSecondary.opacity(0.85))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: accessorySystemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(item.url == nil ? Color.orange : scTextSecondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(scSurfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

private struct FlowTagRow: View {
    let tags: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                tagViews
            }

            VStack(alignment: .leading, spacing: 6) {
                tagViews
            }
        }
    }

    private var tagViews: some View {
        ForEach(tags, id: \.self) { tag in
            Text(tag)
                .font(.caption2.weight(.bold))
                .foregroundStyle(scTextPrimary)
                .padding(.vertical, 3)
                .padding(.horizontal, 7)
                .background(Color.white.opacity(0.10))
                .clipShape(Capsule())
        }
    }
}
