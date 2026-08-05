import Foundation
import Combine
import FirebaseAuth
import FirebaseFirestore
import Network

enum AuthScreen {
    case welcome
    case createAccount
    case signIn
    case passwordRecovery
}

enum LaunchRoute: Equatable {
    case loading
    case welcome
    case createAccount
    case signIn
    case passwordRecovery
    case emailVerification
    case legalAcceptance
    case profileSetup
    case accountUnavailable
    case app
}

enum AccountGateSource: Equatable {
    case unknown
    case fresh
    case cachedOffline
    case missing
    case incomplete
    case authProblem
}

private enum AccountGateErrorClassification: Equatable, CustomStringConvertible {
    case fallbackSafe
    case fatal
    case unknown

    var description: String {
        switch self {
        case .fallbackSafe:
            return "fallbackSafe"
        case .fatal:
            return "fatal"
        case .unknown:
            return "unknown"
        }
    }
}

private struct AccountGateConnectivityStatus: Equatable {
    let isOnline: Bool
    let usesWiFi: Bool
}

@MainActor
final class AuthStateStore: ObservableObject {
    @Published private(set) var firebaseUser: User?
    @Published private(set) var userProfile: SatChartUserProfile?
    @Published private(set) var isResolvingAccount = true
    @Published private(set) var isWorking = false
    @Published var authScreen: AuthScreen = .welcome
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published private(set) var verificationEmailCooldownEndsAt: Date?
    @Published private(set) var accountGateSource: AccountGateSource = .unknown
    @Published private(set) var accountUnavailableTitle = "Connect once to finish setup"
    @Published private(set) var accountUnavailableSubtitle = "SatChart needs an internet connection the first time you sign in and finish account setup. After setup and offline data installation, you can open SatChart without service."
    @Published private var transientAccountGateBannerText: String?

    private let service: AuthService
    private let gateCache: AccountGateCache
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var accountLoadErrorMessage: String?
    private let verificationEmailCooldownSeconds: TimeInterval = 60
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "SatChart.AccountGate.NetworkMonitor")
    private var latestConnectivityStatus: AccountGateConnectivityStatus?
    private var isRefreshingCachedOfflineGate = false
    private var onlineBannerDismissTask: Task<Void, Never>?

    init(service: AuthService? = nil) {
        let service = service ?? AuthService()
        self.service = service
        gateCache = .shared
        authHandle = service.addAuthStateDidChangeListener { [weak self] user in
            Task { @MainActor in
                await self?.resolveAccount(for: user)
            }
        }
        startNetworkMonitor()
    }

    deinit {
        if let authHandle {
            Auth.auth().removeStateDidChangeListener(authHandle)
        }
        networkMonitor.cancel()
        onlineBannerDismissTask?.cancel()
    }

    var route: LaunchRoute {
        if isResolvingAccount {
            return .loading
        }

        guard let firebaseUser else {
            switch authScreen {
            case .welcome:
                return .welcome
            case .createAccount:
                return .createAccount
            case .signIn:
                return .signIn
            case .passwordRecovery:
                return .passwordRecovery
            }
        }

        if !isEmailVerifiedForGate(firebaseUser) {
            return .emailVerification
        }

        if accountLoadErrorMessage != nil && userProfile == nil {
            return .accountUnavailable
        }

        guard let userProfile else {
            return .loading
        }

        if !userProfile.legalAccepted {
            return .legalAcceptance
        }

        if !userProfile.profileCompleted {
            return .profileSetup
        }

        return .app
    }

    var activeEmail: String {
        firebaseUser?.email ?? userProfile?.email ?? ""
    }

    var accountLoadError: String? {
        accountLoadErrorMessage
    }

    var isUsingCachedOfflineAccountGate: Bool {
        accountGateSource == .cachedOffline
    }

    var offlineAccountBannerText: String? {
        if let transientAccountGateBannerText {
            return transientAccountGateBannerText
        }

        guard isUsingCachedOfflineAccountGate else { return nil }
        return "Offline mode: using your last verified SatChart account on this device."
    }

    func show(_ screen: AuthScreen) {
        clearMessages()
        authScreen = screen
    }

    func clearMessages() {
        errorMessage = nil
        infoMessage = nil
    }

    func createAccount(email: String, password: String, confirmPassword: String) async {
        let email = clean(email)
        guard validateEmail(email), validatePassword(password), validatePasswordMatch(password, confirmPassword) else {
            return
        }

        await runAuthTask {
            let user = try await service.createUser(email: email, password: password)
            _ = try await service.ensureUserDocument(for: user)
            try await service.sendEmailVerification(to: user)
            startVerificationEmailCooldown()
            firebaseUser = user
            userProfile = nil
            authScreen = .welcome
            infoMessage = "Verification email sent to \(email). Check your Inbox, Junk, Spam, Promotions, or Clutter folder."
        }
    }

    func signIn(email: String, password: String) async {
        let email = clean(email)
        guard validateEmail(email), validateNonEmpty(password, fieldName: "Password") else {
            return
        }

        await runAuthTask {
            let user = try await service.signIn(email: email, password: password)
            try await service.reload(user)

            guard let refreshed = service.currentUser else {
                throw AuthServiceError.missingCurrentUser
            }

            firebaseUser = refreshed

            if refreshed.isEmailVerified {
                userProfile = try await service.ensureUserDocument(for: refreshed)
                accountGateSource = .fresh
            } else {
                userProfile = nil
                infoMessage = "Please verify your email before continuing."
            }

            authScreen = .welcome
        }
    }

    func sendVerificationEmail() async {
        guard let user = service.currentUser else {
            errorMessage = AuthServiceError.missingCurrentUser.localizedDescription
            return
        }

        let seconds = verificationEmailCooldownRemaining()
        if seconds > 0 {
            infoMessage = "Please wait \(seconds) seconds before resending. Email delivery can take a minute or two."
            return
        }

        await runAuthTask {
            try await service.sendEmailVerification(to: user)
            startVerificationEmailCooldown()
            infoMessage = "Verification email sent to \(user.email ?? "your email address"). Check your Inbox, Junk, Spam, Promotions, or Clutter folder."
        }
    }

    func refreshEmailVerificationStatus() async {
        guard let user = service.currentUser else {
            errorMessage = AuthServiceError.missingCurrentUser.localizedDescription
            return
        }

        await runAuthTask {
            try await service.reload(user)

            guard let refreshed = service.currentUser else {
                throw AuthServiceError.missingCurrentUser
            }

            firebaseUser = refreshed

            if refreshed.isEmailVerified {
                userProfile = try await service.ensureUserDocument(for: refreshed)
                accountGateSource = .fresh
                infoMessage = "Email verified."
            } else {
                infoMessage = "That email is not verified yet. After tapping the verification link, return to SatChart and try again."
            }
        }
    }

    func sendPasswordReset(email: String) async {
        let email = clean(email)
        guard validateEmail(email) else {
            return
        }

        await runAuthTask {
            try await service.sendPasswordReset(email: email)
            infoMessage = "Password reset email sent to \(email)."
            authScreen = .signIn
        }
    }

    func acceptLegalNotice() async {
        guard let user = service.currentUser else {
            errorMessage = AuthServiceError.missingCurrentUser.localizedDescription
            return
        }

        await runAuthTask {
            userProfile = try await service.acceptLegalNotice(for: user)
            accountGateSource = .fresh
        }
    }

    func completeProfile(displayName: String, vesselName: String, role: String, homeDistrict: DistrictID) async {
        let displayName = clean(displayName)
        let vesselName = clean(vesselName)
        let role = clean(role)

        guard validateNonEmpty(displayName, fieldName: "Name"),
              validateNonEmpty(role, fieldName: "Role") else {
            return
        }

        guard let user = service.currentUser else {
            errorMessage = AuthServiceError.missingCurrentUser.localizedDescription
            return
        }

        await runAuthTask {
            let input = SatChartProfileInput(
                displayName: displayName,
                vesselName: vesselName,
                role: role,
                homeDistrict: homeDistrict
            )
            userProfile = try await service.completeProfile(for: user, input: input)
            accountGateSource = .fresh
        }
    }

    func retryAccountLoad() async {
        await resolveAccount(for: service.currentUser)
    }

    func signOut() async {
        await runAuthTask {
            try service.signOut()
            firebaseUser = nil
            userProfile = nil
            authScreen = .welcome
            accountLoadErrorMessage = nil
            accountGateSource = .missing
            infoMessage = nil
        }
    }

    private func resolveAccount(for user: User?) async {
        isResolvingAccount = true
        accountLoadErrorMessage = nil
        accountGateSource = .unknown
        transientAccountGateBannerText = nil
        onlineBannerDismissTask?.cancel()
        accountUnavailableTitle = "Connect once to finish setup"
        accountUnavailableSubtitle = "SatChart needs an internet connection the first time you sign in and finish account setup. After setup and offline data installation, you can open SatChart without service."
        clearMessages()

        defer {
            isResolvingAccount = false
        }

        guard let user else {
            firebaseUser = nil
            userProfile = nil
            authScreen = .welcome
            accountGateSource = .missing
            debugLogGate("no Firebase currentUser; routing to unauthenticated account flow")
            return
        }

        firebaseUser = user
        let initialSnapshot = gateCache.load()
        debugLogGate("""
        resolve start
          currentUser: yes
          uid: \(redactedUid(user.uid))
          email known: \(user.email?.isEmpty == false ? "yes" : "no")
          cached snapshot exists: \(initialSnapshot == nil ? "no" : "yes")
          cached snapshot age: \(snapshotAgeDescription(initialSnapshot))
        """)

        if let cachedProfile = await service.cachedUserProfile(for: user) {
            debugLogGate("Firestore cache profile found; using it as a local snapshot candidate")
            userProfile = cachedProfile
        } else {
            debugLogGate("Firestore cache profile unavailable")
        }

        do {
            debugLogGate("attempting FirebaseAuth user reload and Firestore profile refresh")
            try await service.reload(user)

            guard let refreshed = service.currentUser else {
                throw AuthServiceError.missingCurrentUser
            }

            firebaseUser = refreshed

            if refreshed.isEmailVerified {
                userProfile = try await service.ensureUserDocument(for: refreshed)
                accountGateSource = .fresh
                debugLogGate("remote account gate refresh succeeded; route source=fresh")
            } else {
                userProfile = nil
                accountGateSource = .fresh
                debugLogGate("remote account gate refresh succeeded; email not verified")
            }
        } catch {
            let currentUser = service.currentUser ?? user
            firebaseUser = currentUser
            let latestSnapshot = gateCache.load() ?? initialSnapshot
            let classification = classifyAccountGateError(error)
            debugLogGate("""
            remote account gate refresh failed
              classification: \(classification.description)
              firebase currentUser exists: yes
              cached snapshot exists: \(latestSnapshot == nil ? "no" : "yes")
              cached snapshot uid matches: \(latestSnapshot?.isForCurrentUser(uid: currentUser.uid) == true ? "yes" : "no")
              cached snapshot can open offline: \(latestSnapshot?.canOpenOfflineForCurrentUser(uid: currentUser.uid) == true ? "yes" : "no")
            """)

            if classification != .fatal,
               let latestSnapshot,
               latestSnapshot.canOpenOfflineForCurrentUser(uid: currentUser.uid) {
                userProfile = SatChartUserProfile(snapshot: latestSnapshot)
                accountGateSource = .cachedOffline
                accountLoadErrorMessage = nil
                debugLogGate("route selected: app via cached offline account gate")
                return
            }

            userProfile = nil
            configureBlockingAccountState(
                error: error,
                classification: classification,
                snapshot: latestSnapshot,
                currentUser: currentUser
            )
        }
    }

    private func isEmailVerifiedForGate(_ user: User) -> Bool {
        if user.isEmailVerified {
            return true
        }

        guard accountGateSource == .cachedOffline,
              let userProfile,
              userProfile.uid == user.uid else {
            return false
        }

        return userProfile.emailVerified
    }

    private func startNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let status = AccountGateConnectivityStatus(
                isOnline: path.status == .satisfied,
                usesWiFi: path.usesInterfaceType(.wifi)
            )
            Task { @MainActor [weak self] in
                self?.handleConnectivityStatus(status)
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    private func handleConnectivityStatus(_ status: AccountGateConnectivityStatus) {
        let previous = latestConnectivityStatus
        latestConnectivityStatus = status

        debugLogGate("""
        connectivity changed
          online: \(status.isOnline ? "yes" : "no")
          wifi: \(status.usesWiFi ? "yes" : "no")
          was online: \(previous?.isOnline == true ? "yes" : "no")
        """)

        guard status.isOnline else { return }
        guard isUsingCachedOfflineAccountGate else { return }
        guard previous?.isOnline != true else { return }

        Task { [weak self] in
            await self?.refreshCachedOfflineGateAfterConnectivityReturn(status: status)
        }
    }

    private func refreshCachedOfflineGateAfterConnectivityReturn(status: AccountGateConnectivityStatus) async {
        guard !isRefreshingCachedOfflineGate else { return }
        guard isUsingCachedOfflineAccountGate else { return }
        guard let user = service.currentUser ?? firebaseUser else { return }

        isRefreshingCachedOfflineGate = true
        defer { isRefreshingCachedOfflineGate = false }

        do {
            debugLogGate("network restored while using cached offline account gate; attempting silent remote refresh")
            try await service.reload(user)

            guard let refreshed = service.currentUser else {
                throw AuthServiceError.missingCurrentUser
            }

            firebaseUser = refreshed

            if refreshed.isEmailVerified {
                userProfile = try await service.ensureUserDocument(for: refreshed)
                accountGateSource = .fresh
                accountLoadErrorMessage = nil
                showOnlineFeaturesBanner(status: status)
                debugLogGate("silent account gate refresh succeeded after connectivity restored; route source=fresh")
            } else {
                userProfile = nil
                accountGateSource = .fresh
                accountLoadErrorMessage = nil
                transientAccountGateBannerText = nil
                onlineBannerDismissTask?.cancel()
                debugLogGate("silent account gate refresh succeeded after connectivity restored; email is not verified")
            }
        } catch {
            let classification = classifyAccountGateError(error)
            debugLogGate("""
            silent account gate refresh after connectivity restored failed
              classification: \(classification.description)
            """)

            if classification == .fatal {
                let currentUser = service.currentUser ?? user
                firebaseUser = currentUser
                configureBlockingAccountState(
                    error: error,
                    classification: classification,
                    snapshot: gateCache.load(),
                    currentUser: currentUser
                )
            }
        }
    }

    private func showOnlineFeaturesBanner(status: AccountGateConnectivityStatus) {
        onlineBannerDismissTask?.cancel()
        transientAccountGateBannerText = status.usesWiFi
            ? "Connected to Wi-Fi, online app features enabled"
            : "Connected, online app features enabled"

        onlineBannerDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.clearOnlineFeaturesBanner()
        }
    }

    private func clearOnlineFeaturesBanner() {
        transientAccountGateBannerText = nil
        onlineBannerDismissTask = nil
    }

    private func configureBlockingAccountState(
        error: Error,
        classification: AccountGateErrorClassification,
        snapshot: AccountGateSnapshot?,
        currentUser: User
    ) {
        if classification == .fatal {
            accountGateSource = .authProblem
            accountUnavailableTitle = "Account needs attention"
            accountUnavailableSubtitle = "SatChart could not verify this account. Connect to the internet and sign in again."
            accountLoadErrorMessage = "SatChart could not verify this account. Connect to the internet and sign in again."
            debugLogGate("route selected: blocking auth/account problem")
            return
        }

        if let snapshot, snapshot.isForCurrentUser(uid: currentUser.uid) {
            accountGateSource = .incomplete
            accountUnavailableTitle = "Account setup incomplete"
            accountUnavailableSubtitle = "Connect to the internet to finish account setup before using SatChart offline."
            accountLoadErrorMessage = "Connect to the internet to finish account setup before using SatChart offline."
            debugLogGate("route selected: blocking cached account snapshot is incomplete")
            return
        }

        accountGateSource = .missing
        accountUnavailableTitle = "Connect once to finish setup"
        accountUnavailableSubtitle = "SatChart needs an internet connection the first time you sign in and finish account setup. After setup and offline data installation, you can open SatChart without service."
        accountLoadErrorMessage = "SatChart needs an internet connection the first time you sign in and finish account setup. After setup and offline data installation, you can open SatChart without service."
        debugLogGate("route selected: blocking no usable cached account snapshot")
    }

    private func classifyAccountGateError(_ error: Error) -> AccountGateErrorClassification {
        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorDNSLookupFailed:
                return .fallbackSafe
            default:
                break
            }
        }

        if nsError.domain == AuthErrorDomain,
           let code = AuthErrorCode(rawValue: nsError.code) {
            switch code {
            case .networkError:
                return .fallbackSafe
            case .userNotFound, .userDisabled, .invalidUserToken, .userTokenExpired, .operationNotAllowed:
                return .fatal
            default:
                return .unknown
            }
        }

        if nsError.domain == FirestoreErrorDomain,
           let code = FirestoreErrorCode.Code(rawValue: nsError.code) {
            switch code {
            case .unavailable, .deadlineExceeded, .cancelled:
                return .fallbackSafe
            case .permissionDenied, .unauthenticated:
                return .fatal
            default:
                return .unknown
            }
        }

        return .unknown
    }

    private func runAuthTask(_ work: () async throws -> Void) async {
        guard !isWorking else { return }

        isWorking = true
        errorMessage = nil
        infoMessage = nil

        do {
            try await work()
        } catch {
            errorMessage = message(for: error)
        }

        isWorking = false
    }

    private func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validateEmail(_ email: String) -> Bool {
        guard !email.isEmpty else {
            errorMessage = "Enter your email address."
            return false
        }

        guard email.contains("@"), email.contains(".") else {
            errorMessage = "Enter a valid email address."
            return false
        }

        return true
    }

    private func validatePassword(_ password: String) -> Bool {
        guard password.count >= 6 else {
            errorMessage = "Use a password with at least 6 characters."
            return false
        }

        return true
    }

    private func validatePasswordMatch(_ password: String, _ confirmPassword: String) -> Bool {
        guard password == confirmPassword else {
            errorMessage = "Passwords do not match."
            return false
        }

        return true
    }

    private func validateNonEmpty(_ value: String, fieldName: String) -> Bool {
        guard !value.isEmpty else {
            errorMessage = "Enter your \(fieldName.lowercased())."
            return false
        }

        return true
    }

    private func startVerificationEmailCooldown() {
        verificationEmailCooldownEndsAt = Date().addingTimeInterval(verificationEmailCooldownSeconds)
    }

    func verificationEmailCooldownRemaining(now: Date = Date()) -> Int {
        guard let verificationEmailCooldownEndsAt else {
            return 0
        }

        let remaining = verificationEmailCooldownEndsAt.timeIntervalSince(now)
        return max(0, Int(ceil(remaining)))
    }

    private func snapshotAgeDescription(_ snapshot: AccountGateSnapshot?) -> String {
        guard let snapshot,
              let lastRefresh = snapshot.lastSuccessfulRemoteRefreshAt else {
            return "missing"
        }

        let age = max(0, Int(Date().timeIntervalSince(lastRefresh)))
        if age < 60 {
            return "\(age)s"
        }
        if age < 60 * 60 {
            return "\(age / 60)m"
        }
        if age < 24 * 60 * 60 {
            return "\(age / 3600)h"
        }
        return "\(age / 86400)d"
    }

    private func redactedUid(_ uid: String) -> String {
        guard uid.count > 6 else { return "..." }
        return "\(uid.prefix(3))...\(uid.suffix(3))"
    }

    private func debugLogGate(_ message: String) {
        #if DEBUG
        print("AccountGate: \(message)")
        #endif
    }

    private func message(for error: Error) -> String {
        let nsError = error as NSError

        if nsError.domain == AuthErrorDomain,
           let code = AuthErrorCode(rawValue: nsError.code) {
            switch code {
            case .networkError:
                return "Network connection failed. Check your connection and try again."
            case .tooManyRequests:
                return "Too many attempts. Please wait a few minutes before trying again."
            case .invalidEmail:
                return "Enter a valid email address."
            case .userNotFound, .wrongPassword, .invalidCredential:
                return "The email or password is incorrect."
            case .emailAlreadyInUse:
                return "An account already exists for that email. Try signing in instead."
            case .weakPassword:
                return "Use a stronger password."
            default:
                break
            }
        }

        let text = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return "Something went wrong. Try again or contact support@getsatchart.com."
        }

        return "Something went wrong. Try again or contact support@getsatchart.com."
    }
}
