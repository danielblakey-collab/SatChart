import SwiftUI

struct BootstrapView: View {
    @StateObject private var installer = SatChartOfflinePackInstaller()
    @State private var appDB: AppDatabase?
    @State private var isBootstrapping = false

    var body: some View {
        Group {
            if let appDB {
                ContentView()
                    .environment(\.appDatabase, appDB)
                    .overlay(alignment: .top) {
                        nonFatalInstallerStatusView
                    }
            } else {
                bootstrapStatusView
            }
        }
        .task {
            await bootstrapIfNeeded()
        }
    }

    private var bootstrapStatusView: some View {
        ZStack {
            scBackground
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text(installer.status)
                    .font(.headline)
                    .foregroundStyle(scTextPrimary)
                    .multilineTextAlignment(.center)

                if let detail = installer.state.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(scTextSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !installer.state.isBlockingUnavailable {
                    ProgressView(value: installer.progress)
                        .tint(scAccent)
                        .frame(maxWidth: 260)
                }

                if installer.state.isBlockingUnavailable {
                    Button {
                        Task { await bootstrap(force: true) }
                    } label: {
                        HStack(spacing: 8) {
                            if isBootstrapping {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }

                            Text("Retry")
                                .font(.headline)
                        }
                        .frame(maxWidth: 220)
                        .frame(minHeight: 46)
                        .foregroundStyle(.white)
                        .background(isBootstrapping ? scSurfaceAlt : scAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(SatChartPressFeedbackButtonStyle())
                    .disabled(isBootstrapping)

                    Text("Offline data is required for SatChart's fisheries analytics.")
                        .font(.caption)
                        .foregroundStyle(scTextSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .frame(maxWidth: 420)
        }
    }

    @ViewBuilder
    private var nonFatalInstallerStatusView: some View {
        if case .updateCheckFailedButLocalDataUsable(let message) = installer.state {
            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(scTextPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(scSurface.opacity(0.96))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 18)
                .padding(.top, 12)
        }
    }

    private func bootstrapIfNeeded() async {
        guard appDB == nil, !isBootstrapping else { return }
        await bootstrap()
    }

    private func bootstrap(force: Bool = false) async {
        guard force || !isBootstrapping else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }

        do {
            do {
                let openedDB = try AppDatabase.open()
                installer.markInstalledDataInUse()
                appDB = openedDB
                return
            } catch {
                #if DEBUG
                print("⚠️ BootstrapView: bundled/read-only offline DB open failed, trying fallback installer:", error.localizedDescription)
                #endif
            }

            let hadLocalData = try installer.installedDatabaseExists()
            if hadLocalData {
                try installer.discardInstalledData()
            }
            try await installer.installIfNeeded()

            let openedDB = try AppDatabase.open()
            appDB = openedDB

            if hadLocalData || !AppDatabase.bundledDatabaseExists() {
                Task {
                    await installer.checkForUpdatesIfInstalled()
                }
            }
        } catch {
            installer.markOfflineDataUnavailable(error)
        }
    }
}
