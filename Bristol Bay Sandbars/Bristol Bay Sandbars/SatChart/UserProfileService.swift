import Foundation
import FirebaseAuth
import FirebaseFirestore

extension Notification.Name {
    static let satChartUserProfileDidChange = Notification.Name("SatChartUserProfileDidChange")
}

enum UserProfileServiceError: LocalizedError {
    case missingCurrentUser
    case missingDocumentSnapshot

    var errorDescription: String? {
        switch self {
        case .missingCurrentUser:
            return "No signed-in user is available."
        case .missingDocumentSnapshot:
            return "Unable to load account."
        }
    }
}

final class UserProfileService {
    private enum LocalKey {
        static let firstName = "userFirstName"
        static let lastName = "userLastName"
        static let vesselName = "vesselName"
        static let radioDisplayName = "radioPinDisplayName"
        static let radioGroupId = "radioGroupId"
    }

    private let auth: Auth
    private let db: Firestore
    private let defaults: UserDefaults

    init(
        auth: Auth = Auth.auth(),
        db: Firestore = Firestore.firestore(),
        defaults: UserDefaults = .standard
    ) {
        self.auth = auth
        self.db = db
        self.defaults = defaults
    }

    var currentUser: User? {
        auth.currentUser
    }

    func loadProfile() async throws -> UserProfile {
        guard let user = auth.currentUser else {
            throw UserProfileServiceError.missingCurrentUser
        }

        try await reload(user)

        guard let refreshed = auth.currentUser else {
            throw UserProfileServiceError.missingCurrentUser
        }

        let ref = userDocument(uid: refreshed.uid)
        let snapshot = try await getDocument(ref)
        let existingData = snapshot.data() ?? [:]
        var profile = UserProfile(user: refreshed, data: existingData)
        backfillProfileFromLocalCache(&profile)

        var updates: [String: Any] = [
            "uid": refreshed.uid,
            "email": refreshed.email ?? profile.email,
            "emailVerified": refreshed.isEmailVerified,
            "updatedAt": FieldValue.serverTimestamp()
        ]

        if !snapshot.exists {
            updates["createdAt"] = FieldValue.serverTimestamp()
        }

        if existingData["firstName"] == nil, !profile.firstName.isEmpty {
            updates["firstName"] = profile.firstName
        }

        if existingData["lastName"] == nil, !profile.lastName.isEmpty {
            updates["lastName"] = profile.lastName
        }

        if existingData["vesselName"] == nil, !profile.vesselName.isEmpty {
            updates["vesselName"] = profile.vesselName
        }

        if existingData["radioDisplayName"] == nil, !profile.radioDisplayName.isEmpty {
            updates["radioDisplayName"] = profile.radioDisplayName
        }

        if existingData["displayName"] == nil, !profile.fullName.isEmpty {
            updates["displayName"] = profile.fullName
        }

        profile.defaultWaypointPinColorID = WaypointColorPreferences.ensureDefaultColorFields(in: &updates, existingData: existingData).rawValue

        if existingData["termsVersionAccepted"] == nil,
           (existingData["legalAccepted"] as? Bool) == true {
            updates["termsVersionAccepted"] = SatChartReleaseConfiguration.termsVersion
        }

        if existingData["privacyVersionAccepted"] == nil,
           (existingData["legalAccepted"] as? Bool) == true {
            updates["privacyVersionAccepted"] = SatChartReleaseConfiguration.privacyVersion
        }

        if existingData["safetyNoticeVersionAccepted"] == nil,
           (existingData["legalAccepted"] as? Bool) == true {
            updates["safetyNoticeVersionAccepted"] = SatChartReleaseConfiguration.safetyNoticeVersion
        }

        try await setData(updates, on: ref, merge: true)
        let refreshedSnapshot = try await getDocument(ref)
        let refreshedProfile = UserProfile(user: refreshed, data: refreshedSnapshot.data() ?? existingData)
        syncLocalCache(from: refreshedProfile)
        AccountGateCache.shared.updateFromUserProfile(refreshedProfile)
        return refreshedProfile
    }

    func saveProfile(_ profile: UserProfile) async throws -> UserProfile {
        guard let user = auth.currentUser else {
            throw UserProfileServiceError.missingCurrentUser
        }

        let normalized = normalize(profile)
        try await updateDisplayName(normalized.fullName, for: user)

        let ref = userDocument(uid: user.uid)
        var data = normalized.firestoreDataForSave()
        data["profileCompleted"] = true
        if normalized.onboardingCompletedAt == nil {
            data["onboardingCompletedAt"] = FieldValue.serverTimestamp()
        }

        try await setData(data, on: ref, merge: true)
        let snapshot = try await getDocument(ref)
        let saved = UserProfile(user: user, data: snapshot.data() ?? data)
        syncLocalCache(from: saved)
        AccountGateCache.shared.updateFromUserProfile(saved)
        await MainActor.run {
            NotificationCenter.default.post(name: .satChartUserProfileDidChange, object: saved)
        }
        return saved
    }

    func sendVerificationEmail() async throws {
        guard let user = auth.currentUser else {
            throw UserProfileServiceError.missingCurrentUser
        }
        try await sendEmailVerification(to: user)
    }

    func sendPasswordReset() async throws {
        guard let email = auth.currentUser?.email, !email.isEmpty else {
            throw UserProfileServiceError.missingCurrentUser
        }
        try await sendPasswordReset(email: email)
    }

    func signOut() throws {
        try auth.signOut()
        AccountGateCache.shared.clear()
    }

    func requestAccountDeletion() async throws {
        guard let user = auth.currentUser else {
            throw UserProfileServiceError.missingCurrentUser
        }

        let userRef = userDocument(uid: user.uid)
        let deletionRef = userRef.collection("deletionRequests").document("latest")
        let appBuild = "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"))"

        try await setData([
            "requestedAt": FieldValue.serverTimestamp(),
            "status": "requested",
            "email": user.email ?? "",
            "appBuild": appBuild
        ], on: deletionRef, merge: true)

        try await setData([
            "deletionRequestedAt": FieldValue.serverTimestamp(),
            "deletionStatus": "requested",
            "updatedAt": FieldValue.serverTimestamp()
        ], on: userRef, merge: true)
    }

    func deleteCurrentAuthAccount() async throws {
        guard let user = auth.currentUser else {
            throw UserProfileServiceError.missingCurrentUser
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            user.delete { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            }
        }
    }

    func reauthenticate(email: String, password: String) async throws {
        guard let user = auth.currentUser else {
            throw UserProfileServiceError.missingCurrentUser
        }

        let credential = EmailAuthProvider.credential(withEmail: email, password: password)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            user.reauthenticate(with: credential) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            }
        }
    }

    func clearLocalProfileCache() {
        Self.clearLocalProfileCache(defaults: defaults)
    }

    static func clearLocalProfileCache(defaults: UserDefaults = .standard) {
        [
            LocalKey.firstName,
            LocalKey.lastName,
            LocalKey.vesselName,
            LocalKey.radioDisplayName
        ].forEach { defaults.removeObject(forKey: $0) }
    }

    static func friendlyMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == AuthErrorDomain,
           let code = AuthErrorCode(rawValue: nsError.code) {
            switch code {
            case .requiresRecentLogin:
                return "For your security, please sign in again before deleting your account."
            case .networkError:
                return "Please check your internet connection."
            case .tooManyRequests:
                return "Too many attempts. Please wait a few minutes before trying again."
            case .wrongPassword, .invalidCredential:
                return "The email or password is incorrect."
            default:
                break
            }
        }

        if error is UserProfileServiceError {
            return error.localizedDescription
        }

        return "Something went wrong. Please contact \(SatChartReleaseConfiguration.supportEmail)."
    }

    static func isRecentLoginError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == AuthErrorDomain,
              let code = AuthErrorCode(rawValue: nsError.code) else {
            return false
        }
        return code == .requiresRecentLogin
    }

    private func normalize(_ profile: UserProfile) -> UserProfile {
        var normalized = profile
        normalized.firstName = clean(profile.firstName)
        normalized.lastName = clean(profile.lastName)
        normalized.vesselName = clean(profile.vesselName)
        normalized.radioDisplayName = clean(profile.radioDisplayName)
        normalized.email = clean(profile.email)
        return normalized
    }

    private func backfillProfileFromLocalCache(_ profile: inout UserProfile) {
        if profile.firstName.isEmpty {
            profile.firstName = clean(defaults.string(forKey: LocalKey.firstName) ?? "")
        }
        if profile.lastName.isEmpty {
            profile.lastName = clean(defaults.string(forKey: LocalKey.lastName) ?? "")
        }
        if profile.vesselName.isEmpty {
            profile.vesselName = clean(defaults.string(forKey: LocalKey.vesselName) ?? "")
        }
        if profile.radioDisplayName.isEmpty {
            profile.radioDisplayName = clean(defaults.string(forKey: LocalKey.radioDisplayName) ?? "")
        }
    }

    private func syncLocalCache(from profile: UserProfile) {
        defaults.set(profile.firstName, forKey: LocalKey.firstName)
        defaults.set(profile.lastName, forKey: LocalKey.lastName)
        defaults.set(profile.vesselName, forKey: LocalKey.vesselName)
        defaults.set(profile.radioDisplayName, forKey: LocalKey.radioDisplayName)
        defaults.set(profile.defaultWaypointPinColorID, forKey: WaypointColorPreferences.storageKey)
    }

    private func reload(_ user: User) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            user.reload { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            }
        }
    }

    private func sendEmailVerification(to user: User) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            user.sendEmailVerification { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            }
        }
    }

    private func sendPasswordReset(email: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            auth.sendPasswordReset(withEmail: email) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            }
        }
    }

    private func updateDisplayName(_ displayName: String, for user: User) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let request = user.createProfileChangeRequest()
            request.displayName = displayName
            request.commitChanges { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            }
        }
    }

    private func userDocument(uid: String) -> DocumentReference {
        db.collection("users").document(uid)
    }

    private func getDocument(_ ref: DocumentReference) async throws -> DocumentSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            ref.getDocument { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let snapshot else {
                    continuation.resume(throwing: UserProfileServiceError.missingDocumentSnapshot)
                    return
                }
                continuation.resume(returning: snapshot)
            }
        }
    }

    private func setData(_ data: [String: Any], on ref: DocumentReference, merge: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ref.setData(data, merge: merge) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            }
        }
    }

    private func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
