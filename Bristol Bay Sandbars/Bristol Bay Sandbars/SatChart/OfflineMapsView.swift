import SwiftUI
import Combine
import UIKit

private let offlineMapsNavBlue = Color(red: 0.03, green: 0.23, blue: 0.48)

struct OfflineMapsView: View {

    @StateObject private var offline = OfflineMapsManager.shared
    @StateObject private var availability = OfflineDistrictPackAvailability.shared
    @State private var previewRetryGeneration = 0

    /// Keep installed files and in-flight downloads manageable even if R2 removes a version.
    private func retainedPacks(for district: DistrictID) -> [OfflinePack] {
        let published = Set(availability.packs(for: district))
        var retained = offline.downloadedDistrictMapPacks(for: district).filter { !published.contains($0) }
        for pack in district.supportedLocalMapPacks where offline.isDownloading[pack.slug] == true {
            if !published.contains(pack), !retained.contains(pack) { retained.append(pack) }
        }
        if let active = offline.activePack, active.isDistrictMapPack,
           active.district == district, !published.contains(active), !retained.contains(active) {
            retained.append(active)
        }
        return retained.sorted { ($0.districtMapVersion ?? 0) < ($1.districtMapVersion ?? 0) }
    }

    private var basemapPacks: [OfflinePack] { OfflinePack.basemapPacks }

    private func mbtilesURLs(for pack: OfflinePack) -> [URL] {
        availability.mbtilesURLs(for: pack)
    }

    private func previewURLs(for pack: OfflinePack) -> [URL] {
        availability.previewURLs(for: pack)
    }

    @ViewBuilder
    private func packRows(_ packs: [OfflinePack], showsPreview: Bool = true) -> some View {
        ForEach(packs) { pack in
            PackCard(
                pack: pack,
                previewURLs: previewURLs(for: pack),
                showsPreview: showsPreview,
                previewRetryGeneration: previewRetryGeneration,
                onAppear: {
                    offline.fetchRemoteSizeIfNeeded(pack: pack, urls: mbtilesURLs(for: pack))
                },
                onDownload: {
                    let urls = mbtilesURLs(for: pack)
                    #if DEBUG
                    print("⬇️ Download candidates [\(pack.slug)]: \(urls.map(\.absoluteString).joined(separator: ", "))")
                    #endif
                    offline.download(pack: pack, fromCandidates: urls)
                },
                onDelete: { offline.delete(pack) },
                onCancel: { offline.cancel(pack) }
            )
            .environmentObject(offline)
            .padding(.horizontal, 16)
        }
    }

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.07, blue: 0.09)
                .ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !offline.status.isEmpty {
                        Text(offline.status)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)
                    }

                    if availability.isRefreshing {
                        ProgressView("Checking available district maps…")
                            .font(.footnote)
                            .padding(.horizontal, 16)
                    }
                    if availability.discoveryUnavailable {
                        Text(availability.packs.isEmpty
                             ? "Connect to the internet to check available district maps."
                             : "Couldn’t check for new district maps. Showing previously verified versions.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                    }

                    ForEach(DistrictID.allCases, id: \.self) { district in
                        let published = availability.packs(for: district)
                        let retained = retainedPacks(for: district)
                        if !published.isEmpty || !retained.isEmpty {
                            SectionHeader(title: district.displayName)
                            packRows(published)
                            if !retained.isEmpty {
                                Text("Downloads on this device")
                                    .font(.footnote.weight(.semibold))
                                    .padding(.horizontal, 16)
                                packRows(retained, showsPreview: false)
                            }
                        }
                    }

                    if !basemapPacks.isEmpty {
                        SectionHeader(title: "Basemaps")
                        packRows(basemapPacks)
                    }

                    Spacer(minLength: 20)
                }
                .padding(.top, 12)
            }
        }
        .task {
            await availability.refresh()
            previewRetryGeneration += 1
        }
        .refreshable {
            await availability.refresh(force: true)
            previewRetryGeneration += 1
        }
        .environment(\.colorScheme, .dark)
        .foregroundColor(.white)
        .navigationTitle("Offline Maps")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(offlineMapsNavBlue, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Offline Maps")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .underline()
            }
        }
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundColor(.white)
            .underline(true, color: Color.white.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.top, 8)
    }
}

@MainActor
private final class PackPreviewLoader: ObservableObject {
    enum Phase {
        case idle
        case loading
        case success(UIImage)
        case failed
    }

    @Published var phase: Phase = .idle
    private var hasStarted = false

    func retryFailed(urls: [URL], usesBlackBackground: Bool) {
        guard case .failed = phase else { return }
        hasStarted = false
        load(urls: urls, usesBlackBackground: usesBlackBackground)
    }

    func load(urls: [URL], usesBlackBackground: Bool) {
        guard !hasStarted else { return }
        hasStarted = true

        Task {
            phase = .loading

            for url in urls {
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    guard let http = response as? HTTPURLResponse,
                          (200...299).contains(http.statusCode),
                          let image = UIImage(data: data) else {
                        continue
                    }

                    if usesBlackBackground {
                        let preview = await Task.detached(priority: .utility) {
                            OfflineBasemapPreview.image(from: data)
                        }.value
                        phase = .success(preview ?? image)
                    } else {
                        phase = .success(image)
                    }
                    return
                } catch {
                    continue
                }
            }

            phase = .failed
        }
    }
}

private extension OfflinePack {
    /// Source-image regions matched to the supplied Naknek/Nushagak references.
    /// Normalized coordinates keep the same geographic crop across map versions.
    func thumbnailCrop(for idiom: UIUserInterfaceIdiom) -> CGRect? {
        // Fit the complete image on iPad, using the same centered, black-backed
        // framing as Naknek/Nushagak instead of filling a wide 280-point card.
        if idiom == .pad {
            let fitsDistrict = isDistrictMapPack && (district == .egegik || district == .ugashik)
            let fitsBasemap = Self.basemapPacks.contains { basemap in
                basemap.remoteBasenameCandidates.contains(slug)
            }
            if fitsDistrict || fitsBasemap {
                return CGRect(x: 0, y: 0, width: 1, height: 1)
            }
        }

        guard isDistrictMapPack else { return nil }
        switch district {
        case .naknek_kvichak:
            // Lower bay crop: (0, 639, 715, 627) in the 1600 × 1266 previews.
            return CGRect(x: 0, y: 639.0 / 1266.0,
                          width: 715.0 / 1600.0, height: 627.0 / 1266.0)
        case .nushagak:
            // Bay/flats crop: (0, 1032, 1600, 2008) in the 1600 × 3392 previews.
            return CGRect(x: 0, y: 1032.0 / 3392.0,
                          width: 1, height: 2008.0 / 3392.0)
        default:
            return nil
        }
    }
}

private struct PackPreviewImage: View {
    let image: UIImage
    let crop: CGRect?

    var body: some View {
        if let crop, image.size.width > 0, image.size.height > 0 {
            GeometryReader { geometry in
                let cropSize = CGSize(width: image.size.width * crop.width,
                                      height: image.size.height * crop.height)
                let scale = min(geometry.size.width / cropSize.width,
                                geometry.size.height / cropSize.height)
                let imageSize = CGSize(width: image.size.width * scale,
                                       height: image.size.height * scale)

                Image(uiImage: image)
                    .resizable()
                    .frame(width: imageSize.width, height: imageSize.height)
                    .offset(x: -crop.minX * imageSize.width,
                            y: -crop.minY * imageSize.height)
                    .frame(width: cropSize.width * scale, height: cropSize.height * scale,
                           alignment: .topLeading)
                    .clipped()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .background(Color.black)
        } else {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        }
    }
}

private struct RemotePackPreview: View {
    let urls: [URL]
    let fallbackLabel: String
    let crop: CGRect?
    let usesBlackBackground: Bool
    let retryGeneration: Int

    @StateObject private var loader = PackPreviewLoader()

    var body: some View {
        Group {
            switch loader.phase {
            case .success(let image):
                PackPreviewImage(image: image, crop: crop)

            case .idle, .loading:
                ZStack {
                    Color.gray.opacity(0.15)
                    ProgressView()
                }

            case .failed:
                ZStack {
                    Color.gray.opacity(0.25)
                    Text("No preview\n\(fallbackLabel)")
                        .font(.footnote.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.75))
                        .padding()
                }
            }
        }
        .onAppear {
            loader.load(urls: urls, usesBlackBackground: usesBlackBackground)
        }
        .onChange(of: retryGeneration) { _ in
            loader.retryFailed(urls: urls, usesBlackBackground: usesBlackBackground)
        }
    }
}

private struct PackCard: View {
    @EnvironmentObject var offline: OfflineMapsManager

    let pack: OfflinePack
    let previewURLs: [URL]
    let showsPreview: Bool
    let previewRetryGeneration: Int
    let onAppear: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    private func formatBytes(_ bytes: Int64) -> String {
        let value = Double(max(bytes, 0))
        if value >= 1_073_741_824 { return String(format: "%.2f GB", value / 1_073_741_824) }
        if value >= 1_048_576 { return String(format: "%.1f MB", value / 1_048_576) }
        if value >= 1024 { return String(format: "%.0f KB", value / 1024) }
        return String(format: "%.0f B", value)
    }

    private var displayTitle: String { pack.displayTitle }

    var body: some View {
        let slug = pack.slug
        let downloaded = offline.isDownloaded(pack)
        let downloading = offline.isDownloading[slug] ?? false
        let someoneElseDownloading: Bool = {
            if let active = offline.activePack?.slug {
                return active != slug && (offline.isDownloading[active] ?? false)
            }
            return false
        }()

        let progress = offline.progress[slug] ?? 0
        let done = offline.downloadedBytes[slug] ?? 0
        let expected = offline.totalBytes[slug] ?? 0
        let localSize = offline.localFileSizeBytes(pack)
        let remoteSize = offline.remoteBytes[slug]
        let sizeToShow = localSize ?? remoteSize ?? (expected > 0 ? expected : nil)

        VStack(alignment: .leading, spacing: 10) {
            if showsPreview {
                GeometryReader { geo in
                    RemotePackPreview(
                        urls: previewURLs,
                        fallbackLabel: pack.previewFilenameCandidates.first ?? slug,
                        crop: pack.thumbnailCrop(for: UIDevice.current.userInterfaceIdiom),
                        usesBlackBackground: OfflineBasemapPreview.usesBlackBackground(for: pack),
                        retryGeneration: previewRetryGeneration
                    )
                    .id(previewURLs)
                    .allowsHitTesting(false)
                    .frame(width: geo.size.width, height: min(geo.size.height, 280))
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                }
                .frame(height: 280)

                if let captureTide = pack.captureTide {
                    OfflineMapCaptureTideCaption(tide: captureTide)
                } else if let previewDateLabel = pack.previewDateLabel {
                    Text(previewDateLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.78))
                        .accessibilityLabel("Map date \(previewDateLabel)")
                }

            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .font(.headline)
                        .foregroundColor(.white)

                    Text("Size: \(sizeToShow.map(formatBytes) ?? "—")")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                if downloaded {
                    SatChartDeleteConfirmationButton(
                        confirmationTitle: "Delete \(displayTitle)?",
                        confirmationMessage: "The downloaded offline map pack will be removed from this device.",
                        onConfirm: onDelete
                    ) { isFlashingRed in
                        HStack(spacing: 6) {
                            SatChartDeleteIcon(isFlashingRed: isFlashingRed, defaultColor: .white)
                            Text("Delete")
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.bordered)
                    .satChartExistingButtonFeedback()
                    .controlSize(.small)
                    .tint(.gray)
                } else if downloading {
                    Button(action: onCancel) {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .satChartExistingButtonFeedback()
                    .controlSize(.small)
                    .tint(.gray)
                } else {
                    Button {
                        #if DEBUG
                        print("🟦 tap [\(slug)] downloaded=\(downloaded) downloading=\(downloading) someoneElseDownloading=\(someoneElseDownloading)")
                        #endif
                        if someoneElseDownloading {
                            let active = offline.activePack?.slug ?? "another pack"
                            #if DEBUG
                            print("⚠️ Blocked download [\(slug)] because \(active) is active")
                            #endif
                            offline.status = "Already downloading \(active). Cancel it first."
                        } else {
                            onDownload()
                        }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .satChartExistingButtonFeedback()
                    .controlSize(.small)
                    .tint(.blue)
                }

                Spacer()

                if someoneElseDownloading && !downloading && !downloaded {
                    Text("Another download is active")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .zIndex(1)

            if downloading {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)

                Text("\(Int(progress * 100))%  •  \(formatBytes(done)) / \(expected > 0 ? formatBytes(expected) : "—")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if downloaded {
                Text("Downloaded")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(Color.black.opacity(0.35))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .onAppear(perform: onAppear)
    }
}

private struct OfflineMapCaptureTideCaption: View {
    let tide: OfflineMapCaptureTide

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(tide.dateLabel) · \(tide.timeLabel)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .accessibilityLabel("Image captured \(tide.dateLabel) at \(tide.timeLabel)")

            Text("Estimated height at capture: \(tide.estimatedHeightFeet, specifier: "%.1f") ft MLLW")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .accessibilityLabel("Estimated tide height when image was captured: \(tide.estimatedHeightFeet, specifier: "%.1f") feet relative to Mean Lower Low Water")

            Text("Predicted tide: \(tide.stateLabel)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)

            Text(tide.relativeEventLabel)
                .foregroundStyle(.white.opacity(0.85))
            Text(tide.eventLabel)
                .foregroundStyle(.white.opacity(0.78))

            if let referenceNote = tide.station.referenceNote {
                Text(referenceNote)
                    .foregroundStyle(.white.opacity(0.78))
            }

            Link(tide.station.label, destination: tide.station.url)
                .foregroundStyle(Color(red: 0.50, green: 0.75, blue: 1))
                .padding(.vertical, 4)
                .accessibilityLabel("NOAA tide predictions, \(tide.station.name), station \(tide.station.id)")
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }
}
