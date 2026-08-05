import SwiftUI
import Combine
import GRDB
import FirebaseAuth
import FirebaseCore

private enum BetaDiagnosticStatus: Equatable {
    case pass
    case warning
    case fail
    case info

    var title: String {
        switch self {
        case .pass: return "Pass"
        case .warning: return "Warning"
        case .fail: return "Fail"
        case .info: return "Info"
        }
    }

    var symbolName: String {
        switch self {
        case .pass: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .pass: return Color.green
        case .warning: return Color.orange
        case .fail: return Color.red
        case .info: return Color.blue
        }
    }
}

private struct BetaDiagnosticCheck: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let status: BetaDiagnosticStatus
    let isCritical: Bool
}

private struct BetaDiagnosticLine: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
    let status: BetaDiagnosticStatus?
}

private struct BetaDiagnosticsSnapshot: Equatable {
    let generatedAt: String
    let appLines: [BetaDiagnosticLine]
    let authLines: [BetaDiagnosticLine]
    let offlineLines: [BetaDiagnosticLine]
    let validationChecks: [BetaDiagnosticCheck]

    var isOfflineDBComplete: Bool {
        validationChecks
            .filter(\.isCritical)
            .allSatisfy { $0.status == .pass }
    }

    static let empty = BetaDiagnosticsSnapshot(
        generatedAt: "Not refreshed",
        appLines: [],
        authLines: [],
        offlineLines: [],
        validationChecks: [
            BetaDiagnosticCheck(
                id: "not-refreshed",
                title: "Diagnostics not refreshed",
                detail: "Open this screen to run beta validation.",
                status: .info,
                isCritical: false
            )
        ]
    )
}

@MainActor
private final class BetaDiagnosticsViewModel: ObservableObject {
    @Published private(set) var snapshot: BetaDiagnosticsSnapshot = .empty
    @Published private(set) var isRefreshing = false

    func refresh(appDB: AppDatabase?, authStore: AuthStateStore) {
        isRefreshing = true
        defer { isRefreshing = false }

        snapshot = BetaDiagnosticsBuilder.build(appDB: appDB, authStore: authStore)
    }
}

struct BetaDiagnosticsView: View {
    @Environment(\.appDatabase) private var appDatabase
    @EnvironmentObject private var authStore: AuthStateStore
    @StateObject private var viewModel = BetaDiagnosticsViewModel()

    var body: some View {
        ZStack {
            scBackground.ignoresSafeArea()
            HostingBackgroundFixer(color: scBackgroundUIColor)
                .frame(width: 0, height: 0)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    summaryCard
                    diagnosticsSection(title: "App & Firebase", lines: viewModel.snapshot.appLines)
                    diagnosticsSection(title: "Auth & Backend", lines: viewModel.snapshot.authLines)
                    diagnosticsSection(title: "Offline Pack", lines: viewModel.snapshot.offlineLines)
                    validationSection
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 18)
            }
        }
        .navigationTitle("Beta Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(bbMenuBlue, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    viewModel.refresh(appDB: appDatabase, authStore: authStore)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isRefreshing)
            }
        }
        .onAppear {
            BBMenuAppearance.applyNavBar()
            viewModel.refresh(appDB: appDatabase, authStore: authStore)
        }
    }

    private var summaryCard: some View {
        let complete = viewModel.snapshot.isOfflineDBComplete
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: complete ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundColor(complete ? .green : .red)

                VStack(alignment: .leading, spacing: 3) {
                    Text(complete ? "Offline DB Complete" : "Offline DB Incomplete")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("Last checked: \(viewModel.snapshot.generatedAt)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.70))
                }

                Spacer(minLength: 0)
            }

            Text(complete ? "Beta-critical tables and 2015-2025 Deep Research coverage are present." : "One or more beta-critical offline database checks failed. Reinstall or rebuild the offline pack before uploading this build.")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func diagnosticsSection(title: String, lines: [BetaDiagnosticLine]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .underline(true, color: Color.white.opacity(0.55))

            ForEach(lines) { line in
                diagnosticLine(line)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var validationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Database Validation")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .underline(true, color: Color.white.opacity(0.55))

            ForEach(viewModel.snapshot.validationChecks) { check in
                validationRow(check)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func diagnosticLine(_ line: BetaDiagnosticLine) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let status = line.status {
                Image(systemName: status.symbolName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(status.color)
                    .frame(width: 18)
            } else {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundColor(.white.opacity(0.35))
                    .frame(width: 18)
                    .padding(.top, 5)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(line.title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text(line.value.isEmpty ? "Not available" : line.value)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.76))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func validationRow(_ check: BetaDiagnosticCheck) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.status.symbolName)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(check.status.color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(check.title)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    if check.isCritical {
                        Text("critical")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }

                Text(check.detail)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.76))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

@MainActor
private enum BetaDiagnosticsBuilder {
    static func build(appDB: AppDatabase?, authStore: AuthStateStore) -> BetaDiagnosticsSnapshot {
        let generatedAt = timestampFormatter.string(from: Date())
        let appLines = buildAppLines()
        let authLines = buildAuthLines(authStore: authStore)
        let offlineLines = buildOfflineLines(appDB: appDB)
        let validationChecks = OfflineDatabaseBetaValidator.validationChecks(appDB: appDB)

        return BetaDiagnosticsSnapshot(
            generatedAt: generatedAt,
            appLines: appLines,
            authLines: authLines,
            offlineLines: offlineLines,
            validationChecks: validationChecks
        )
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private static func buildAppLines() -> [BetaDiagnosticLine] {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info["CFBundleVersion"] as? String ?? "Unknown"
        let firebaseOptions = FirebaseApp.app()?.options

        return [
            BetaDiagnosticLine(id: "app-version", title: "App Version / Build", value: "\(version) (\(build))", status: nil),
            BetaDiagnosticLine(id: "firebase-project", title: "Firebase Project", value: firebaseOptions?.projectID ?? plistValue("PROJECT_ID"), status: .info),
            BetaDiagnosticLine(id: "firebase-app-id", title: "Firebase App ID", value: firebaseOptions?.googleAppID ?? plistValue("GOOGLE_APP_ID"), status: nil),
            BetaDiagnosticLine(id: "bundle-id", title: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "Unknown", status: nil)
        ]
    }

    private static func buildAuthLines(authStore: AuthStateStore) -> [BetaDiagnosticLine] {
        let user = Auth.auth().currentUser
        let authState: String
        if let user {
            if user.isAnonymous {
                authState = "Signed in anonymously"
            } else if user.isEmailVerified {
                authState = "Signed in, email verified"
            } else {
                authState = "Signed in, email not verified"
            }
        } else {
            authState = "Signed out"
        }

        return [
            BetaDiagnosticLine(id: "auth-state", title: "Auth State", value: authState, status: user == nil ? .warning : .pass),
            BetaDiagnosticLine(id: "auth-route", title: "Launch Route", value: authStore.route.betaDiagnosticsLabel, status: nil),
            BetaDiagnosticLine(id: "account-gate", title: "Account Gate Source", value: authStore.accountGateSource.betaDiagnosticsLabel, status: authStore.isUsingCachedOfflineAccountGate ? .warning : .info),
            BetaDiagnosticLine(id: "uid", title: "User UID", value: user?.uid ?? authStore.userProfile?.uid ?? "", status: nil),
            BetaDiagnosticLine(id: "email", title: "Email", value: user?.email ?? authStore.userProfile?.email ?? authStore.activeEmail, status: nil),
            BetaDiagnosticLine(id: "radio-group", title: "Radio Group ID", value: UserDefaults.standard.string(forKey: "radioGroupId") ?? "", status: nil)
        ]
    }

    private static func buildOfflineLines(appDB: AppDatabase?) -> [BetaDiagnosticLine] {
        let bundledURL = OfflineDatabaseResource.bundledSQLiteURL()
        let appSupportURL = try? OfflinePaths.offlineSQLiteURL()
        let appSupportExists = appSupportURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let manifestPack = bundledManifestPack()
        let defaults = UserDefaults.standard
        let installedVersion = defaults.object(forKey: "offlinePackInstalledVersion") as? Int
        let installedPackId = defaults.string(forKey: "offlinePackInstalledId") ?? ""
        let installedSha = defaults.string(forKey: "offlinePackInstalledSha256") ?? ""
        let metadata = offlineMetadata(appDB: appDB)

        let installState: String
        let installStatus: BetaDiagnosticStatus
        if let appDB {
            installState = "Ready - \(appDB.sourceDescription)"
            installStatus = .pass
        } else if bundledURL != nil || appSupportExists {
            installState = "Present on disk but not open"
            installStatus = .warning
        } else {
            installState = "Missing"
            installStatus = .fail
        }

        return [
            BetaDiagnosticLine(id: "install-state", title: "Offline DB Install State", value: installState, status: installStatus),
            BetaDiagnosticLine(id: "db-source", title: "Active DB Source", value: appDB?.sourceDescription ?? "", status: nil),
            BetaDiagnosticLine(id: "db-path", title: "Active DB Path", value: appDB?.databaseURL.path ?? "", status: nil),
            BetaDiagnosticLine(id: "db-size", title: "Active DB Size", value: appDB.map { fileSizeText(at: $0.databaseURL) } ?? "", status: nil),
            BetaDiagnosticLine(id: "db-schema-version", title: "Offline DB Version", value: metadata["schemaVersion"] ?? "", status: metadata["schemaVersion"] == nil ? .warning : .pass),
            BetaDiagnosticLine(id: "db-source-years", title: "Source Data Years", value: metadata["source_data_years"] ?? "", status: metadata["source_data_years"] == "2015-2025" ? .pass : .warning),
            BetaDiagnosticLine(id: "db-built-at", title: "Offline DB Built At", value: metadata["builtAt"] ?? "", status: nil),
            BetaDiagnosticLine(id: "bundled-sqlite", title: "Bundled SQLite", value: bundledURL?.path ?? "Not bundled", status: bundledURL == nil ? .warning : .pass),
            BetaDiagnosticLine(id: "app-support-sqlite", title: "Installed Fallback SQLite", value: appSupportExists ? (appSupportURL?.path ?? "Installed") : "Not installed", status: appSupportExists ? .pass : .info),
            BetaDiagnosticLine(id: "manifest-pack", title: "Bundled Manifest Pack", value: manifestPack.map { "\($0.id) v\($0.version)" } ?? "Not found", status: manifestPack == nil ? .warning : .pass),
            BetaDiagnosticLine(id: "manifest-sha", title: "Bundled Pack SHA-256", value: manifestPack?.sha256 ?? "", status: nil),
            BetaDiagnosticLine(id: "manifest-sqlite-sha", title: "Bundled SQLite SHA-256", value: manifestPack?.sqliteSha256 ?? "", status: nil),
            BetaDiagnosticLine(id: "installed-pack-id", title: "Installed Pack ID", value: installedPackId, status: installedPackId.isEmpty ? .info : .pass),
            BetaDiagnosticLine(id: "installed-pack-version", title: "Installed Pack Version", value: installedVersion.map(String.init) ?? "", status: installedVersion == nil ? .info : .pass),
            BetaDiagnosticLine(id: "installed-pack-sha", title: "Installed Pack SHA-256", value: installedSha, status: installedSha.isEmpty ? .info : .pass)
        ]
    }

    private static func offlineMetadata(appDB: AppDatabase?) -> [String: String] {
        guard let appDB else { return [:] }
        do {
            return try appDB.dbQueue.read { db in
                var values: [String: String] = [:]
                let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM meta")
                for row in rows {
                    let key: String = row["key"]
                    let value: String = row["value"]
                    values[key] = value
                }
                return values
            }
        } catch {
            #if DEBUG
            print("BetaDiagnostics metadata load failed: \(error)")
            #endif
            return [:]
        }
    }

    private static func bundledManifestPack() -> Pack? {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "public"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return nil
        }

        return manifest.packs
            .filter { $0.type == "all" && $0.format == "sqlite+gzip" }
            .max { lhs, rhs in
                if lhs.version != rhs.version {
                    return lhs.version < rhs.version
                }
                return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }
    }

    private static func plistValue(_ key: String) -> String {
        guard let url = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"),
              let dictionary = NSDictionary(contentsOf: url) as? [String: Any] else {
            return ""
        }
        return dictionary[key] as? String ?? ""
    }

    private static func fileSizeText(at url: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else {
            return ""
        }

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: number.int64Value)
    }
}

private enum OfflineDatabaseBetaValidator {
    private static let expectedYears = Array(2015...2025)
    private static let expectedDistrictKeys = ["egegik", "naknek_kvichak", "nushagak", "togiak", "ugashik"]
    private static let keyTables = [
        "ops_day",
        "registration_day",
        "river_day",
        "district_run_timing_day",
        "optimal_transfer_plan_day"
    ]
    private static let deepResearchYearTables = [
        "ops_day",
        "registration_day",
        "river_day",
        "district_run_timing_day",
        "optimal_transfer_plan_day",
        "exporter_sockeye_per_boat_daily",
        "district_season_metrics"
    ]
    private static let optimalRequiredColumns = [
        "year",
        "date",
        "district_key",
        "sockeye_per_boat_daily",
        "status",
        "is_cooldown_day",
        "transfer",
        "transfer_to",
        "penalty_days_applied",
        "cumulative_sockeye_per_boat_to_date"
    ]

    static func validationChecks(appDB: AppDatabase?) -> [BetaDiagnosticCheck] {
        guard let appDB else {
            return [
                BetaDiagnosticCheck(
                    id: "db-open",
                    title: "Offline database open",
                    detail: "The app does not have an open offline database.",
                    status: .fail,
                    isCritical: true
                )
            ]
        }

        do {
            return try appDB.dbQueue.read { db in
                var checks: [BetaDiagnosticCheck] = []
                checks.append(try integrityCheck(db))
                checks.append(try districtKeysCheck(db))
                checks.append(contentsOf: try keyTableChecks(db))
                checks.append(contentsOf: try data2025Checks(db))
                checks.append(try deepResearchYearRangeCheck(db))
                checks.append(try optimalTransferColumnsCheck(db))
                return checks
            }
        } catch {
            #if DEBUG
            print("BetaDiagnostics validation failed: \(error)")
            #endif
            return [
                BetaDiagnosticCheck(
                    id: "validation-error",
                    title: "Offline database validation",
                    detail: "SatChart could not complete diagnostics for the offline database.",
                    status: .fail,
                    isCritical: true
                )
            ]
        }
    }

    private static func integrityCheck(_ db: Database) throws -> BetaDiagnosticCheck {
        let result = try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "missing result"
        return BetaDiagnosticCheck(
            id: "integrity",
            title: "SQLite integrity check",
            detail: result == "ok" ? "PRAGMA integrity_check returned ok." : "PRAGMA integrity_check returned \(result).",
            status: result == "ok" ? .pass : .fail,
            isCritical: true
        )
    }

    private static func districtKeysCheck(_ db: Database) throws -> BetaDiagnosticCheck {
        guard try tableExists(db, named: "districts") else {
            return BetaDiagnosticCheck(
                id: "district-keys",
                title: "District keys",
                detail: "districts table is missing.",
                status: .fail,
                isCritical: true
            )
        }

        let keys = try String.fetchAll(db, sql: "SELECT key FROM districts ORDER BY key")
        return BetaDiagnosticCheck(
            id: "district-keys",
            title: "District keys",
            detail: keys == expectedDistrictKeys ? keys.joined(separator: ", ") : "Expected \(expectedDistrictKeys.joined(separator: ", ")); found \(keys.joined(separator: ", ")).",
            status: keys == expectedDistrictKeys ? .pass : .fail,
            isCritical: true
        )
    }

    private static func keyTableChecks(_ db: Database) throws -> [BetaDiagnosticCheck] {
        try keyTables.map { table in
            guard try tableExists(db, named: table) else {
                return BetaDiagnosticCheck(
                    id: "table-\(table)",
                    title: table,
                    detail: "Required table is missing.",
                    status: .fail,
                    isCritical: true
                )
            }

            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            return BetaDiagnosticCheck(
                id: "table-\(table)",
                title: table,
                detail: "Rows: \(count)",
                status: count > 0 ? .pass : .fail,
                isCritical: true
            )
        }
    }

    private static func data2025Checks(_ db: Database) throws -> [BetaDiagnosticCheck] {
        let checks: [(id: String, title: String, table: String, predicate: String, positivePredicate: String?)] = [
            ("2025-ops", "2025 ops data", "ops_day", "year = 2025", "year = 2025 AND COALESCE(sockeye, 0) > 0"),
            ("2025-rivers", "2025 river data", "river_day", "year = 2025", "year = 2025 AND COALESCE(dailyEscapement, 0) > 0"),
            ("2025-registrations", "2025 registration data", "registration_day", "year = 2025", "year = 2025 AND driftBoats IS NOT NULL"),
            ("2025-run-timing", "2025 run timing data", "district_run_timing_day", "year = 2025", "year = 2025 AND COALESCE(totalPassage, 0) > 0"),
            ("2025-optimal", "2025 optimal transfer plans", "optimal_transfer_plan_day", "year = 2025", "year = 2025 AND COALESCE(cumulative_sockeye_per_boat_to_date, 0) > 0")
        ]

        return try checks.map { check in
            guard try tableExists(db, named: check.table) else {
                return BetaDiagnosticCheck(
                    id: check.id,
                    title: check.title,
                    detail: "\(check.table) is missing.",
                    status: .fail,
                    isCritical: true
                )
            }

            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(check.table) WHERE \(check.predicate)") ?? 0
            let positiveCount: Int?
            if let positivePredicate = check.positivePredicate {
                positiveCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(check.table) WHERE \(positivePredicate)") ?? 0
            } else {
                positiveCount = nil
            }

            let passed = count > 0 && (positiveCount ?? 1) > 0
            let positiveDetail = positiveCount.map { ", positive/usable rows: \($0)" } ?? ""
            return BetaDiagnosticCheck(
                id: check.id,
                title: check.title,
                detail: "Rows: \(count)\(positiveDetail)",
                status: passed ? .pass : .fail,
                isCritical: true
            )
        }
    }

    private static func deepResearchYearRangeCheck(_ db: Database) throws -> BetaDiagnosticCheck {
        var failures: [String] = []
        var summaries: [String] = []

        for table in deepResearchYearTables {
            guard try tableExists(db, named: table) else {
                failures.append("\(table): missing")
                continue
            }

            let years = try Int.fetchAll(db, sql: "SELECT DISTINCT year FROM \(table) ORDER BY year")
            if years == expectedYears {
                summaries.append("\(table): 2015-2025")
            } else {
                failures.append("\(table): \(yearSummary(years))")
            }
        }

        let detail = failures.isEmpty ? summaries.joined(separator: "\n") : failures.joined(separator: "\n")
        return BetaDiagnosticCheck(
            id: "deep-research-year-range",
            title: "Deep Research year range",
            detail: detail,
            status: failures.isEmpty ? .pass : .fail,
            isCritical: true
        )
    }

    private static func optimalTransferColumnsCheck(_ db: Database) throws -> BetaDiagnosticCheck {
        guard try tableExists(db, named: "optimal_transfer_plan_day") else {
            return BetaDiagnosticCheck(
                id: "optimal-columns",
                title: "Optimal transfer columns",
                detail: "optimal_transfer_plan_day is missing.",
                status: .fail,
                isCritical: true
            )
        }

        let columns = Set(try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('optimal_transfer_plan_day')"))
        let missing = optimalRequiredColumns.filter { !columns.contains($0) }
        return BetaDiagnosticCheck(
            id: "optimal-columns",
            title: "Optimal transfer columns",
            detail: missing.isEmpty ? "All required optimal transfer columns are present." : "Missing: \(missing.joined(separator: ", "))",
            status: missing.isEmpty ? .pass : .fail,
            isCritical: true
        )
    }

    private static func tableExists(_ db: Database, named tableName: String) throws -> Bool {
        let count = try Int.fetchOne(db, sql: """
            SELECT COUNT(*)
            FROM sqlite_master
            WHERE type IN ('table', 'view')
              AND name = ?
        """, arguments: [tableName]) ?? 0
        return count > 0
    }

    private static func yearSummary(_ years: [Int]) -> String {
        guard let first = years.first, let last = years.last else { return "none" }
        if years.count <= 4 {
            return years.map(String.init).joined(separator: ", ")
        }
        return "\(first)-\(last) (\(years.count) years)"
    }
}

private extension AccountGateSource {
    var betaDiagnosticsLabel: String {
        switch self {
        case .unknown: return "Unknown"
        case .fresh: return "Fresh online verification"
        case .cachedOffline: return "Cached offline account gate"
        case .missing: return "Missing profile or gate"
        case .incomplete: return "Account setup incomplete"
        case .authProblem: return "Auth problem"
        }
    }
}

private extension LaunchRoute {
    var betaDiagnosticsLabel: String {
        switch self {
        case .loading: return "Loading"
        case .welcome: return "Welcome"
        case .createAccount: return "Create account"
        case .signIn: return "Sign in"
        case .passwordRecovery: return "Password recovery"
        case .emailVerification: return "Email verification"
        case .legalAcceptance: return "Legal acceptance"
        case .profileSetup: return "Profile setup"
        case .accountUnavailable: return "Account unavailable"
        case .app: return "App"
        }
    }
}
