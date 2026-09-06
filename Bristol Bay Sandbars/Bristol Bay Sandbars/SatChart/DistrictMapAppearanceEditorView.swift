import SwiftUI
import UIKit
import Combine

private let districtAppearanceNavBlue = Color(red: 0.03, green: 0.23, blue: 0.48)
private let districtAppearanceBackgroundTop = Color(red: 0.02, green: 0.15, blue: 0.30)
private let districtAppearanceBackgroundBottom = Color(red: 0.01, green: 0.08, blue: 0.18)
private let districtAppearanceModifiedColor = Color(red: 0.43, green: 0.87, blue: 1.00)

@MainActor
private final class DistrictMapThumbnailLoader: ObservableObject {
    enum Phase {
        case loading(slug: String)
        case success(slug: String)
        case unavailable(slug: String)
    }

    @Published private(set) var phase: Phase = .loading(slug: "")
    @Published private(set) var previewImage: UIImage?

    private var loadTask: Task<Void, Never>?
    private var adjustmentTask: Task<Void, Never>?
    private var requestedSlug: String = ""
    private var requestedSettings: DistrictMapVisualSettings = .neutral
    private var sourceImage: UIImage?

    private static let sourceCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()

    deinit {
        loadTask?.cancel()
        adjustmentTask?.cancel()
    }

    func load(pack: OfflinePack, settings: DistrictMapVisualSettings) {
        let normalizedSettings = settings.normalized
        guard requestedSlug != pack.slug else {
            update(settings: normalizedSettings)
            return
        }

        requestedSlug = pack.slug
        requestedSettings = normalizedSettings
        loadTask?.cancel()
        adjustmentTask?.cancel()
        sourceImage = nil
        previewImage = nil
        phase = .loading(slug: pack.slug)

        guard let localURL = OfflineMapsManager.shared.firstExistingLocalMBTilesURL(for: pack) else {
            phase = .unavailable(slug: pack.slug)
            return
        }

        let cacheKey = Self.cacheKey(for: localURL)
        if let cachedImage = Self.sourceCache.object(forKey: cacheKey as NSString) {
            accept(sourceImage: cachedImage, slug: pack.slug)
            return
        }

        loadTask = Task { [weak self] in
            let renderingTask = Task.detached(priority: .userInitiated) {
                MBTilesOverlay.localPreviewImage(from: localURL)
            }
            let image = await withTaskCancellationHandler {
                await renderingTask.value
            } onCancel: {
                renderingTask.cancel()
            }

            guard !Task.isCancelled,
                  self?.requestedSlug == pack.slug else {
                return
            }
            if let image {
                let cost = Int(image.size.width * image.scale)
                    * Int(image.size.height * image.scale)
                    * 4
                Self.sourceCache.setObject(
                    image,
                    forKey: cacheKey as NSString,
                    cost: max(1, cost)
                )
                self?.accept(sourceImage: image, slug: pack.slug)
            } else {
                self?.phase = .unavailable(slug: pack.slug)
            }
        }
    }

    func update(settings: DistrictMapVisualSettings) {
        let normalizedSettings = settings.normalized
        guard normalizedSettings != requestedSettings else { return }
        requestedSettings = normalizedSettings
        renderAdjustedPreview()
    }

    private static func cacheKey(for url: URL) -> String {
        let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        )
        let size = values?.fileSize ?? -1
        let modifiedAt = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(size)|\(modifiedAt)"
    }

    private func accept(sourceImage: UIImage, slug: String) {
        guard requestedSlug == slug else { return }
        self.sourceImage = sourceImage
        previewImage = sourceImage
        phase = .success(slug: slug)
        renderAdjustedPreview()
    }

    private func renderAdjustedPreview() {
        adjustmentTask?.cancel()
        guard let sourceImage else { return }

        let settings = requestedSettings
        let slug = requestedSlug
        guard !settings.isNeutral else {
            previewImage = sourceImage
            return
        }

        adjustmentTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !Task.isCancelled else { return }

            let renderingTask = Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard !Task.isCancelled else { return nil }
                return DistrictMapImageAdjuster.adjustedImage(sourceImage, settings: settings)
            }
            let adjustedImage = await withTaskCancellationHandler {
                await renderingTask.value
            } onCancel: {
                renderingTask.cancel()
            }

            guard !Task.isCancelled,
                  self?.requestedSlug == slug,
                  self?.requestedSettings == settings else {
                return
            }
            self?.previewImage = adjustedImage
        }
    }
}

private struct DistrictMapThumbnailPreview: View {
    let pack: OfflinePack
    let settings: DistrictMapVisualSettings
    let title: String

    @StateObject private var loader = DistrictMapThumbnailLoader()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.30)

            switch loader.phase {
            case .loading:
                ZStack {
                    Color.white.opacity(0.06)
                    ProgressView()
                        .tint(.white)
                }

            case .success(let slug):
                if slug == pack.slug, let previewImage = loader.previewImage {
                    Image(uiImage: previewImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

            case .unavailable:
                ZStack {
                    Color.white.opacity(0.06)
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 26, weight: .semibold))
                        Text("Preview unavailable")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(.white.opacity(0.70))
                }
            }

            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.68))
                .clipShape(Capsule())
                .padding(10)
        }
        .frame(maxWidth: .infinity)
        .onAppear { loader.load(pack: pack, settings: settings) }
        .onChange(of: settings) { newSettings in
            loader.update(settings: newSettings)
        }
    }
}

private struct DistrictMapPreviewBox: View {
    let pack: OfflinePack?
    let settings: DistrictMapVisualSettings
    let displayTitle: (OfflinePack) -> String

    var body: some View {
        Group {
            if let pack {
                DistrictMapThumbnailPreview(
                    pack: pack,
                    settings: settings,
                    title: displayTitle(pack)
                )
                .id(pack.slug)
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    Text("Download a district map to adjust its appearance.")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.70))
                        .multilineTextAlignment(.center)
                        .padding(24)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

struct DistrictMapAppearanceEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let downloadedPacks: [OfflinePack]
    let appliedSettingsBySlug: [String: DistrictMapVisualSettings]
    let onSelectionChange: (String) -> Void
    let onRestore: (String) -> Void
    let onApply: (String, DistrictMapVisualSettings) -> Void

    @State private var selectedSlug: String
    @State private var draftSettingsBySlug: [String: DistrictMapVisualSettings]
    @State private var currentAppliedSettingsBySlug: [String: DistrictMapVisualSettings]
    @State private var lastEditedSlug: String?
    @State private var didCommitForDismissal: Bool = false
    @State private var isSelectorExpanded: Bool = false

    init(
        downloadedPacks: [OfflinePack],
        appliedSettingsBySlug: [String: DistrictMapVisualSettings],
        initialSelectedSlug: String,
        onSelectionChange: @escaping (String) -> Void,
        onRestore: @escaping (String) -> Void,
        onApply: @escaping (String, DistrictMapVisualSettings) -> Void
    ) {
        self.downloadedPacks = downloadedPacks
        self.appliedSettingsBySlug = appliedSettingsBySlug
        self.onSelectionChange = onSelectionChange
        self.onRestore = onRestore
        self.onApply = onApply

        let selectedSlug = downloadedPacks.contains(where: { $0.slug == initialSelectedSlug })
            ? initialSelectedSlug
            : (downloadedPacks.first?.slug ?? "")
        _selectedSlug = State(initialValue: selectedSlug)

        var drafts: [String: DistrictMapVisualSettings] = [:]
        for pack in downloadedPacks {
            drafts[pack.slug] = appliedSettingsBySlug[pack.slug] ?? .neutral
        }
        _draftSettingsBySlug = State(initialValue: drafts)
        _currentAppliedSettingsBySlug = State(initialValue: appliedSettingsBySlug)
    }

    private var selectedPack: OfflinePack? {
        downloadedPacks.first { $0.slug == selectedSlug }
    }

    private var selectedSettings: DistrictMapVisualSettings {
        draftSettingsBySlug[selectedSlug] ?? .neutral
    }

    private var selectedTitle: String {
        return selectedPack.map(displayTitle) ?? "Select a district map"
    }

    private var selectedPackIsModified: Bool {
        guard let selectedPack else { return false }
        return isModified(slug: selectedPack.slug)
    }

    private var selectedSettingsDifferFromDefault: Bool {
        selectedPack != nil && !selectedSettings.normalized.isNeutral
    }

    private func displayTitle(for pack: OfflinePack) -> String {
        "\(pack.district.displayName) v\(pack.districtMapVersion ?? 1)"
    }

    private func isModified(slug: String) -> Bool {
        guard let settings = currentAppliedSettingsBySlug[slug] else { return false }
        return !settings.normalized.isNeutral
    }

    private func valueBinding(
        _ keyPath: WritableKeyPath<DistrictMapVisualSettings, Double>
    ) -> Binding<Double> {
        Binding(
            get: { selectedSettings[keyPath: keyPath] },
            set: { newValue in
                guard selectedPack != nil else { return }
                var settings = selectedSettings
                settings[keyPath: keyPath] = newValue
                draftSettingsBySlug[selectedSlug] = settings
                lastEditedSlug = selectedSlug
            }
        )
    }

    private func commit(slug: String, settings: DistrictMapVisualSettings) {
        guard !didCommitForDismissal,
              downloadedPacks.contains(where: { $0.slug == slug }) else {
            return
        }
        didCommitForDismissal = true
        onApply(slug, settings.normalized)
    }

    private func commitLastEditedMapIfNeeded() {
        guard !didCommitForDismissal,
              let lastEditedSlug,
              downloadedPacks.contains(where: { $0.slug == lastEditedSlug }) else {
            return
        }
        commit(
            slug: lastEditedSlug,
            settings: draftSettingsBySlug[lastEditedSlug] ?? .neutral
        )
    }

    private func choose(selection: String) {
        withAnimation(.easeInOut(duration: 0.16)) {
            selectedSlug = selection
            isSelectorExpanded = false
        }
    }

    private func resetSelectedDraft() {
        guard selectedPack != nil else { return }
        draftSettingsBySlug[selectedSlug] = .neutral
        lastEditedSlug = selectedSlug
    }

    private func restoreSelectedPack() {
        guard let selectedPack else { return }
        currentAppliedSettingsBySlug.removeValue(forKey: selectedPack.slug)
        draftSettingsBySlug[selectedPack.slug] = .neutral
        lastEditedSlug = selectedPack.slug
        onRestore(selectedPack.slug)
    }

    private func formattedValue(_ value: Double, showsSign: Bool) -> String {
        let displayValue = abs(value) < 0.005 ? 0.0 : value
        return String(format: showsSign ? "%+.2f" : "%.2f", displayValue)
    }

    private func adjustmentRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        showsSign: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 76, alignment: .leading)

            Slider(value: value, in: range, step: 0.01)
                .tint(.cyan)
                .accessibilityLabel(title)
                .accessibilityValue(formattedValue(value.wrappedValue, showsSign: showsSign))

            Text(formattedValue(value.wrappedValue, showsSign: showsSign))
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 54, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func selectorOption(
        title: String,
        selection: String,
        isModified: Bool = false
    ) -> some View {
        Button {
            choose(selection: selection)
        } label: {
            HStack(spacing: 9) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(isModified ? districtAppearanceModifiedColor : .white)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if isModified {
                    Circle()
                        .fill(districtAppearanceModifiedColor)
                        .frame(width: 6, height: 6)
                }

                if selectedSlug == selection {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.cyan)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                selectedSlug == selection
                    ? Color.white.opacity(0.09)
                    : Color.clear
            )
        }
        .buttonStyle(.plain)
        .accessibilityValue(isModified ? "Adjusted" : "Default")
    }

    private var mapSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Downloaded District Map")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.72))

            if downloadedPacks.isEmpty {
                Text("No downloaded district maps")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.65))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
            } else {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isSelectorExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(selectedTitle)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundColor(
                                    selectedPackIsModified
                                        ? districtAppearanceModifiedColor
                                        : .white
                                )
                                .lineLimit(1)

                            Spacer(minLength: 4)

                            Image(systemName: isSelectorExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white.opacity(0.75))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if selectedPackIsModified {
                        Button("Restore to Default") {
                            restoreSelectedPack()
                        }
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(districtAppearanceNavBlue.opacity(0.95))
                        .clipShape(Capsule())
                        .buttonStyle(.plain)
                        .accessibilityHint("Immediately restores this map's original appearance")
                    }
                }

                if isSelectorExpanded {
                    Divider()
                        .overlay(Color.white.opacity(0.14))

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(downloadedPacks) { pack in
                                selectorOption(
                                    title: displayTitle(for: pack),
                                    selection: pack.slug,
                                    isModified: isModified(slug: pack.slug)
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .background(Color.black.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
    }

    private var actionBar: some View {
        Button {
            guard selectedPack != nil else { return }
            commit(slug: selectedSlug, settings: selectedSettings)
            dismiss()
        } label: {
            Text("Apply Changes to Selected Map")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(selectedPack == nil)
        .opacity(selectedPack == nil ? 0.45 : 1)
        .accessibilityHint("Saves these settings and refreshes the selected district map")
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [districtAppearanceBackgroundTop, districtAppearanceBackgroundBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        mapSelector

                        DistrictMapPreviewBox(
                            pack: selectedPack,
                            settings: selectedSettings
                        ) { pack in
                            displayTitle(for: pack)
                        }
                        .id(selectedSlug)

                        if selectedPack != nil {
                            Text("Slider changes update this downloaded map preview immediately. The last map edited is applied automatically when this page closes.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.70))
                                .fixedSize(horizontal: false, vertical: true)

                            adjustmentRow(
                                title: "Brightness",
                                value: valueBinding(\.brightness),
                                range: DistrictMapVisualSettings.brightnessRange,
                                showsSign: true
                            )
                            adjustmentRow(
                                title: "Contrast",
                                value: valueBinding(\.contrast),
                                range: DistrictMapVisualSettings.contrastRange
                            )
                            adjustmentRow(
                                title: "Gamma",
                                value: valueBinding(\.gamma),
                                range: DistrictMapVisualSettings.gammaRange
                            )
                            adjustmentRow(
                                title: "Saturation",
                                value: valueBinding(\.saturation),
                                range: DistrictMapVisualSettings.saturationRange
                            )

                            Button {
                                resetSelectedDraft()
                            } label: {
                                Text("Reset")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundColor(
                                        selectedSettingsDifferFromDefault
                                            ? .white
                                            : .white.opacity(0.72)
                                    )
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .background(
                                        selectedSettingsDifferFromDefault
                                            ? Color.blue
                                            : Color.white.opacity(0.10)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(!selectedSettingsDifferFromDefault)
                            .animation(
                                .easeInOut(duration: 0.16),
                                value: selectedSettingsDifferFromDefault
                            )
                            .accessibilityHint("Returns the sliders to their default values without closing this page")

                            Text("Reset returns the sliders to Brightness 0.00, Contrast 1.00, Gamma 1.00, and Saturation 1.00 without closing this page.")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.58))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(16)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionBar
            }
            .navigationTitle("District Map Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        commitLastEditedMapIfNeeded()
                        dismiss()
                    } label: {
                        SatChartToolbarButtonLabel("Close")
                    }
                }
            }
            .onChange(of: selectedSlug) { newSlug in
                guard !newSlug.isEmpty else { return }
                onSelectionChange(newSlug)
            }
            .onDisappear {
                commitLastEditedMapIfNeeded()
            }
        }
    }
}
