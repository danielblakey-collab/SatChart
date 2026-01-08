import SwiftUI
import UIKit

struct OfflineMapsView: View {

    private let r2BaseURL = URL(string: "https://pub-832b588ef9ec4a588045736b6ce409b9.r2.dev")!

    @StateObject private var offline = OfflineMapsManager.shared

    // MARK: - Packs (add more variants here over time)

    private var packsByDistrict: [DistrictID: [OfflinePack]] {
        var d: [DistrictID: [OfflinePack]] = [:]

        for district in DistrictID.allCases {
            var packs: [OfflinePack] = [
                OfflinePack(district: district, slug: district.rawValue) // e.g. "egegik"
            ]

            // Add known variants
            if district == .egegik {
                packs.append(OfflinePack(district: district, slug: "egegik_v2"))
            }

            d[district] = packs
        }

        return d
    }

    // MARK: - URLs

    private func mbtilesURL(for pack: OfflinePack) -> URL {
        r2BaseURL.appendingPathComponent("\(pack.slug).mbtiles")
    }

    private func previewURL(for pack: OfflinePack) -> URL {
        // you said: egegik.jpg, egegik_v2.jpg (no folders)
        r2BaseURL.appendingPathComponent("\(pack.slug).jpg")
    }

    // MARK: - UI

    var body: some View {
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

                    if let packs = packsByDistrict[district] {
                        ForEach(packs) { pack in
                            PackCard(
                                pack: pack,
                                previewURL: previewURL(for: pack),
                                onAppear: {
                                    offline.fetchRemoteSizeIfNeeded(pack: pack, url: mbtilesURL(for: pack))
                                },
                                onDownload: {
                                    let url = mbtilesURL(for: pack)
                                    print("⬇️ Download URL [\(pack.slug)]: \(url.absoluteString)")
                                    offline.download(pack: pack, from: url)
                                },
                                onDelete: { offline.delete(pack) },
                                onCancel: { offline.cancel(pack) }
                            )
                            .environmentObject(offline)
                            .padding(.horizontal, 16)
                        }
                    }
                }

                Spacer(minLength: 20)
            }
            .padding(.top, 12)
        }
        .navigationTitle("Offline Maps")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Pieces

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.top, 8)
    }
}

private struct PackCard: View {
    @EnvironmentObject var offline: OfflineMapsManager

    let pack: OfflinePack
    let previewURL: URL

    let onAppear: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    private func formatBytes(_ bytes: Int64) -> String {
        let b = Double(max(bytes, 0))
        if b >= 1_073_741_824 { return String(format: "%.2f GB", b / 1_073_741_824) }
        if b >= 1_048_576     { return String(format: "%.1f MB", b / 1_048_576) }
        if b >= 1024          { return String(format: "%.0f KB", b / 1024) }
        return String(format: "%.0f B", b)
    }

    var body: some View {
        let slug = pack.slug
        let downloaded = offline.isDownloaded(pack)
        let downloading = offline.isDownloading[slug] ?? false
        let someoneElseDownloading = {
            if let active = offline.activePack?.slug {
                return active != slug
            }
            return false
        }()

        let prog = offline.progress[slug] ?? 0
        let done = offline.downloadedBytes[slug] ?? 0
        let expected = offline.totalBytes[slug] ?? 0

        let localSize = offline.localFileSizeBytes(pack)
        let remoteSize = offline.remoteBytes[slug]
        let sizeToShow = localSize ?? remoteSize ?? (expected > 0 ? expected : nil)

        VStack(alignment: .leading, spacing: 10) {

            // Big preview (about half the screen height)
            GeometryReader { geo in
                AsyncImage(url: previewURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ZStack { Color.gray.opacity(0.15); ProgressView() }
                    default:
                        ZStack {
                            Color.gray.opacity(0.25)
                            Text("No preview\n\(slug).jpg")
                                .font(.footnote.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .foregroundColor(.secondary)
                                .padding()
                        }
                    }
                }
                .frame(width: geo.size.width, height: min(geo.size.height, 280))
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }
            .frame(height: 280)

            // Title + size
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(slug)
                        .font(.headline)
                    Text("Size: \(sizeToShow.map(formatBytes) ?? "—")")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            // Buttons underneath
            HStack(spacing: 10) {

                if downloaded {
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)

                } else if downloading {
                    Button(action: onCancel) {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.gray)

                } else {
                    Button(action: onDownload) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.blue)
                    .disabled(someoneElseDownloading)
                }

                Spacer()

                if someoneElseDownloading && !downloading && !downloaded {
                    Text("Another download is active")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Progress bar under buttons
            if downloading {
                ProgressView(value: prog)
                    .progressViewStyle(.linear)

                Text("\(Int(prog * 100))%  •  \(formatBytes(done)) / \(expected > 0 ? formatBytes(expected) : "—")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if downloaded {
                Text("Downloaded")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .onAppear(perform: onAppear)
    }
}
