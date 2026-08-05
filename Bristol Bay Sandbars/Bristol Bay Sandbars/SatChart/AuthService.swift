import Foundation
import FirebaseAuth
import FirebaseFirestore

struct SatChartUserProfile {
    let uid: String
    let email: String
    let legalAccepted: Bool
    let profileCompleted: Bool
    let displayName: String
    let firstName: String
    let lastName: String
    let vesselName: String
    let radioDisplayName: String
    let role: String
    let homeDistrict: String
    let defaultWaypointPinColorID: String
    let emailVerified: Bool
    let termsVersionAccepted: String
    let privacyVersionAccepted: String
    let safetyNoticeVersionAccepted: String
    let onboardingCompletedAt: Date?
    let profileCompletedAt: Date?

    init(uid: String, email: String, data: [String: Any] = [:]) {
        self.uid = uid
        self.email = (data["email"] as? String) ?? email
        emailVerified = (data["emailVerified"] as? Bool) ?? false

        let hasLegalAcceptedAt = data["legalAcceptedAt"] != nil
        termsVersionAccepted = (data["termsVersionAccepted"] as? String) ?? (data["legalNoticeVersion"] as? String) ?? ""
        privacyVersionAccepted = (data["privacyVersionAccepted"] as? String) ?? ""
        safetyNoticeVersionAccepted = (data["safetyNoticeVersionAccepted"] as? String) ?? (data["legalNoticeVersion"] as? String) ?? ""
        onboardingCompletedAt = Self.date(from: data["onboardingCompletedAt"])
        profileCompletedAt = Self.date(from: data["profileCompletedAt"])
        let hasAcceptedCurrentVersions =
            !termsVersionAccepted.isEmpty &&
            !privacyVersionAccepted.isEmpty &&
            !safetyNoticeVersionAccepted.isEmpty
        let hasProfileCompletedAt = profileCompletedAt != nil || onboardingCompletedAt != nil

        legalAccepted = (data["legalAccepted"] as? Bool) ?? (hasLegalAcceptedAt || hasAcceptedCurrentVersions)
        profileCompleted = (data["profileCompleted"] as? Bool) ?? hasProfileCompletedAt
        firstName = (data["firstName"] as? String) ?? ""
        lastName = (data["lastName"] as? String) ?? ""
        let fullName = [firstName, lastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let resolvedDisplayName = (data["displayName"] as? String) ?? fullName
        displayName = resolvedDisplayName
        vesselName = (data["vesselName"] as? String) ?? ""
        radioDisplayName = (data["radioDisplayName"] as? String) ?? resolvedDisplayName
        role = (data["role"] as? String) ?? ""
        homeDistrict = (data["homeDistrict"] as? String) ?? ""
        defaultWaypointPinColorID = WaypointPinColor.safe(
            rawValue: (data["defaultWaypointPinColorID"] as? String) ?? (data["waypointPinColorID"] as? String),
            fallback: WaypointColorPreferences.ensureLocalDefaultColor()
        ).rawValue
    }

    private static func date(from value: Any?) -> Date? {
        if let timestamp = value as? Timestamp {
            return timestamp.dateValue()
        }

        if let date = value as? Date {
            return date
        }

        return nil
    }
}

struct SatChartProfileInput {
    let displayName: String
    let vesselName: String
    let role: String
    let homeDistrict: DistrictID
}

enum AuthServiceError: LocalizedError {
    case missingCurrentUser
    case missingAuthResult
    case missingDocumentSnapshot

    var errorDescription: String? {
        switch self {
        case .missingCurrentUser:
            return "No signed-in user is available."
        case .missingAuthResult:
            return "Firebase did not return an authenticated user."
        case .missingDocumentSnapshot:
            return "SatChart could not read the account record."
        }
    }
}

final class AuthService {
    static let legalNoticeVersion = SatChartReleaseConfiguration.safetyNoticeVersion

    private let auth: Auth
    private let db: Firestore
    private let gateCache: AccountGateCache

    init(auth: Auth = Auth.auth(), db: Firestore = Firestore.firestore(), gateCache: AccountGateCache = .shared) {
        self.auth = auth
        self.db = db
        self.gateCache = gateCache
    }

    var currentUser: User? {
        auth.currentUser
    }

    func addAuthStateDidChangeListener(_ listener: @escaping (User?) -> Void) -> AuthStateDidChangeListenerHandle {
        auth.addStateDidChangeListener { _, user in
            listener(user)
        }
    }

    func removeAuthStateDidChangeListener(_ handle: AuthStateDidChangeListenerHandle) {
        auth.removeStateDidChangeListener(handle)
    }

    func createUser(email: String, password: String) async throws -> User {
        try await withCheckedThrowingContinuation { continuation in
            auth.createUser(withEmail: email, password: password) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let user = result?.user else {
                    continuation.resume(throwing: AuthServiceError.missingAuthResult)
                    return
                }

                continuation.resume(returning: user)
            }
        }
    }

    func signIn(email: String, password: String) async throws -> User {
        try await withCheckedThrowingContinuation { continuation in
            auth.signIn(withEmail: email, password: password) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let user = result?.user else {
                    continuation.resume(throwing: AuthServiceError.missingAuthResult)
                    return
                }

                continuation.resume(returning: user)
            }
        }
    }

    func signOut() throws {
        try auth.signOut()
        gateCache.clear()
    }

    func reload(_ user: User) async throws {
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

    func sendEmailVerification(to user: User) async throws {
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

    func sendPasswordReset(email: String) async throws {
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

    func ensureUserDocument(for user: User) async throws -> SatChartUserProfile {
        let ref = userDocument(uid: user.uid)
        let snapshot = try await getDocument(ref)

        if snapshot.exists {
            let data = snapshot.data() ?? [:]
            let email = user.email ?? (data["email"] as? String) ?? ""

            var updates: [String: Any] = [
                "uid": user.uid,
                "email": email,
                "emailVerified": user.isEmailVerified,
                "updatedAt": FieldValue.serverTimestamp()
            ]

            if data["legalAccepted"] == nil {
                updates["legalAccepted"] = data["legalAcceptedAt"] != nil
            }

            if data["profileCompleted"] == nil {
                updates["profileCompleted"] = data["profileCompletedAt"] != nil
            }

            let localProfile = localProfileBackfill()
            if data["firstName"] == nil, !localProfile.firstName.isEmpty {
                updates["firstName"] = localProfile.firstName
            }
            if data["lastName"] == nil, !localProfile.lastName.isEmpty {
                updates["lastName"] = localProfile.lastName
            }
            if data["vesselName"] == nil, !localProfile.vesselName.isEmpty {
                updates["vesselName"] = localProfile.vesselName
            }
            if data["radioDisplayName"] == nil, !localProfile.radioDisplayName.isEmpty {
                updates["radioDisplayName"] = localProfile.radioDisplayName
            }

            _ = WaypointColorPreferences.ensureDefaultColorFields(in: &updates, existingData: data)

            if (data["legalAccepted"] as? Bool) == true {
                if data["termsVersionAccepted"] == nil {
                    updates["termsVersionAccepted"] = SatChartReleaseConfiguration.termsVersion
                }
                if data["privacyVersionAccepted"] == nil {
                    updates["privacyVersionAccepted"] = SatChartReleaseConfiguration.privacyVersion
                }
                if data["safetyNoticeVersionAccepted"] == nil {
                    updates["safetyNoticeVersionAccepted"] = SatChartReleaseConfiguration.safetyNoticeVersion
                }
            }

            try await setData(updates, on: ref, merge: true)
            let refreshed = try await getDocument(ref)
            let profile = SatChartUserProfile(uid: user.uid, email: email, data: refreshed.data() ?? data)
            syncLocalProfileCache(from: profile)
            gateCache.updateFromFirestoreProfile(profile, user: user)
            return profile
        }

        let email = user.email ?? ""
        let localProfile = localProfileBackfill()
        try await setData([
            "uid": user.uid,
            "email": email,
            "emailVerified": user.isEmailVerified,
            "firstName": localProfile.firstName,
            "lastName": localProfile.lastName,
            "vesselName": localProfile.vesselName,
            "radioDisplayName": localProfile.radioDisplayName,
            "defaultWaypointPinColorID": WaypointColorPreferences.ensureLocalDefaultColor().rawValue,
            "legalAccepted": false,
            "profileCompleted": false,
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp()
        ], on: ref, merge: true)

        let created = try await getDocument(ref)
        let profile = SatChartUserProfile(uid: user.uid, email: email, data: created.data() ?? [:])
        syncLocalProfileCache(from: profile)
        gateCache.updateFromFirestoreProfile(profile, user: user)
        return profile
    }

    func cachedUserProfile(for user: User) async -> SatChartUserProfile? {
        let ref = userDocument(uid: user.uid)
        do {
            let snapshot = try await getDocument(ref, source: .cache)
            guard snapshot.exists else { return nil }
            let profile = SatChartUserProfile(uid: user.uid, email: user.email ?? "", data: snapshot.data() ?? [:])
            syncLocalProfileCache(from: profile)
            gateCache.updateFromFirestoreProfile(profile, user: user)
            return profile
        } catch {
            return nil
        }
    }

    func acceptLegalNotice(for user: User) async throws -> SatChartUserProfile {
        let ref = userDocument(uid: user.uid)
        try await setData([
            "uid": user.uid,
            "email": user.email ?? "",
            "emailVerified": user.isEmailVerified,
            "legalAccepted": true,
            "legalAcceptedAt": FieldValue.serverTimestamp(),
            "legalNoticeVersion": Self.legalNoticeVersion,
            "termsVersionAccepted": SatChartReleaseConfiguration.termsVersion,
            "privacyVersionAccepted": SatChartReleaseConfiguration.privacyVersion,
            "safetyNoticeVersionAccepted": SatChartReleaseConfiguration.safetyNoticeVersion,
            "privacyUrl": SatChartReleaseConfiguration.privacyPolicyURLString,
            "termsUrl": SatChartReleaseConfiguration.termsOfUseURLString,
            "safetyUrl": SatChartReleaseConfiguration.safetyURLString,
            "updatedAt": FieldValue.serverTimestamp()
        ], on: ref, merge: true)

        let snapshot = try await getDocument(ref)
        let profile = SatChartUserProfile(uid: user.uid, email: user.email ?? "", data: snapshot.data() ?? [:])
        syncLocalProfileCache(from: profile)
        gateCache.updateFromFirestoreProfile(profile, user: user)
        return profile
    }

    func completeProfile(for user: User, input: SatChartProfileInput) async throws -> SatChartUserProfile {
        try await updateDisplayName(input.displayName, for: user)

        let splitName = UserProfile.splitDisplayName(input.displayName)
        let radioDisplayName = input.vesselName.isEmpty ? input.displayName : input.vesselName
        let ref = userDocument(uid: user.uid)
        try await setData([
            "uid": user.uid,
            "email": user.email ?? "",
            "emailVerified": user.isEmailVerified,
            "displayName": input.displayName,
            "firstName": splitName.first,
            "lastName": splitName.last,
            "vesselName": input.vesselName,
            "radioDisplayName": radioDisplayName,
            "role": input.role,
            "homeDistrict": input.homeDistrict.rawValue,
            "defaultWaypointPinColorID": WaypointColorPreferences.ensureLocalDefaultColor().rawValue,
            "profileCompleted": true,
            "profileCompletedAt": FieldValue.serverTimestamp(),
            "onboardingCompletedAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp()
        ], on: ref, merge: true)

        let snapshot = try await getDocument(ref)
        let profile = SatChartUserProfile(uid: user.uid, email: user.email ?? "", data: snapshot.data() ?? [:])
        syncLocalProfileCache(from: profile)
        gateCache.updateFromFirestoreProfile(profile, user: user)
        return profile
    }

    private func syncLocalProfileCache(from profile: SatChartUserProfile) {
        let defaults = UserDefaults.standard
        defaults.set(profile.firstName, forKey: "userFirstName")
        defaults.set(profile.lastName, forKey: "userLastName")
        defaults.set(profile.vesselName, forKey: "vesselName")
        defaults.set(profile.radioDisplayName, forKey: "radioPinDisplayName")
        defaults.set(profile.defaultWaypointPinColorID, forKey: WaypointColorPreferences.storageKey)
    }

    private func localProfileBackfill() -> (firstName: String, lastName: String, vesselName: String, radioDisplayName: String) {
        let defaults = UserDefaults.standard
        return (
            clean(defaults.string(forKey: "userFirstName") ?? ""),
            clean(defaults.string(forKey: "userLastName") ?? ""),
            clean(defaults.string(forKey: "vesselName") ?? ""),
            clean(defaults.string(forKey: "radioPinDisplayName") ?? "")
        )
    }

    private func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func getDocument(_ ref: DocumentReference, source: FirestoreSource = .default) async throws -> DocumentSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            ref.getDocument(source: source) { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let snapshot else {
                    continuation.resume(throwing: AuthServiceError.missingDocumentSnapshot)
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
}
