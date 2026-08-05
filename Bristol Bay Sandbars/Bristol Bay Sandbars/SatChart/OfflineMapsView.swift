import SwiftUI
import Combine
import UIKit

private let offlineMapsNavBlue = Color(red: 0.03, green: 0.23, blue: 0.48)

struct OfflineMapsView: View {

    private let r2BaseURL = URL(string: "https://pub-832b588ef9ec4a588045736b6ce409b9.r2.dev")!

    @StateObject private var offline = OfflineMapsManager.shared

    private var packsByDistrict: [DistrictID: [OfflinePack]] {
        var result: [DistrictID: [OfflinePack]] = [:]
        for district in DistrictID.allCases {
            result[district] = district.packs
        }
        return result
    }

    private var shorelinePacks: [OfflinePack] { OfflinePack.shorelinePacks }
    private var basemapPacks: [OfflinePack] { OfflinePack.basemapPacks }

    private func mbtilesURLs(for pack: OfflinePack) -> [URL] {
        pack.remoteMBTilesFilenameCandidates.map { r2BaseURL.appendingPathComponent($0) }
    }

    private func previewURLs(for pack: OfflinePack) -> [URL] {
        pack.previewFilenameCandidates.map { r2BaseURL.appendingPathComponent($0) }
    }

    @ViewBuilder
    private func packRows(_ packs: [OfflinePack]) -> some View {
        ForEach(packs) { pack in
            PackCard(
                pack: pack,
                previewURLs: previewURLs(for: pack),
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

                    ForEach(DistrictID.allCases, id: \.self) { district in
                        SectionHeader(title: district.displayName)
                        if let packs = packsByDistrict[district] { packRows(packs) }
                    }

                    if !shorelinePacks.isEmpty {
                        SectionHeader(title: "Shorelines")
                        packRows(shorelinePacks)
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

    func load(urls: [URL]) {
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

                    phase = .success(image)
                    return
                } catch {
                    continue
                }
            }

            phase = .failed
        }
    }
}

private struct RemotePackPreview: View {
    let urls: [URL]
    let fallbackLabel: String

    @StateObject private var loader = PackPreviewLoader()

    var body: some View {
        Group {
            switch loader.phase {
            case .success(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()

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
            loader.load(urls: urls)
        }
    }
}

private struct PackCard: View {
    @EnvironmentObject var offline: OfflineMapsManager

    let pack: OfflinePack
    let previewURLs: [URL]
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
            GeometryReader { geo in
                RemotePackPreview(
                    urls: previewURLs,
                    fallbackLabel: pack.previewFilenameCandidates.first ?? slug
                )
                .allowsHitTesting(false)
                .frame(width: geo.size.width, height: min(geo.size.height, 280))
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }
            .frame(height: 280)

            if let previewDateLabel = pack.previewDateLabel {
                Text(previewDateLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.78))
                    .accessibilityLabel("Map date \(previewDateLabel)")
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
