import Foundation

struct AccountGateSnapshot: Codable, Equatable {
    static let currentSchemaVersion = 1

    var uid: String
    var email: String?
    var emailVerified: Bool
    var firstName: String?
    var lastName: String?
    var vesselName: String?
    var radioDisplayName: String?
    var termsVersionAccepted: String?
    var privacyVersionAccepted: String?
    var safetyNoticeVersionAccepted: String?
    var onboardingCompletedAt: Date?
    var profileCompletedAt: Date?
    var lastSuccessfulRemoteRefreshAt: Date?
    var lastSuccessfulAuthAt: Date?
    var lastKnownEntitlementStatus: String?
    var lastKnownEntitlementExpiresAt: Date?
    var schemaVersion: Int

    func hasCompletedRequiredLegal(
        currentTermsVersion: String = SatChartReleaseConfiguration.termsVersion,
        currentPrivacyVersion: String = SatChartReleaseConfiguration.privacyVersion,
        currentSafetyVersion: String = SatChartReleaseConfiguration.safetyNoticeVersion
    ) -> Bool {
        termsVersionAccepted == currentTermsVersion &&
        privacyVersionAccepted == currentPrivacyVersion &&
        safetyNoticeVersionAccepted == currentSafetyVersion
    }

    var hasCompletedProfile: Bool {
        onboardingCompletedAt != nil || profileCompletedAt != nil
    }

    var needsOnlineRefreshWarning: Bool {
        guard let lastSuccessfulRemoteRefreshAt else { return true }
        return Date().timeIntervalSince(lastSuccessfulRemoteRefreshAt) > 7 * 24 * 60 * 60
    }

    func isForCurrentUser(uid currentUid: String) -> Bool {
        uid == currentUid
    }

    func canOpenOfflineForCurrentUser(uid currentUid: String) -> Bool {
        isForCurrentUser(uid: currentUid) &&
        emailVerified &&
        hasCompletedRequiredLegal() &&
        hasCompletedProfile
    }
}

extension AccountGateSnapshot {
    init(user: FirebaseAccountGateUser, profile: SatChartUserProfile, existing: AccountGateSnapshot? = nil) {
        uid = user.uid
        email = user.email ?? profile.email
        emailVerified = user.emailVerified || profile.emailVerified
        firstName = profile.firstName
        lastName = profile.lastName
        vesselName = profile.vesselName
        radioDisplayName = profile.radioDisplayName
        termsVersionAccepted = profile.termsVersionAccepted
        privacyVersionAccepted = profile.privacyVersionAccepted
        safetyNoticeVersionAccepted = profile.safetyNoticeVersionAccepted
        onboardingCompletedAt = profile.onboardingCompletedAt
        profileCompletedAt = profile.profileCompletedAt
        lastSuccessfulRemoteRefreshAt = Date()
        lastSuccessfulAuthAt = existing?.lastSuccessfulAuthAt ?? Date()
        lastKnownEntitlementStatus = existing?.lastKnownEntitlementStatus
        lastKnownEntitlementExpiresAt = existing?.lastKnownEntitlementExpiresAt
        schemaVersion = Self.currentSchemaVersion
    }

    init(userProfile profile: UserProfile, existing: AccountGateSnapshot? = nil) {
        uid = profile.uid
        email = profile.email
        emailVerified = profile.emailVerified
        firstName = profile.firstName
        lastName = profile.lastName
        vesselName = profile.vesselName
        radioDisplayName = profile.radioDisplayName
        termsVersionAccepted = profile.termsVersionAccepted
        privacyVersionAccepted = profile.privacyVersionAccepted
        safetyNoticeVersionAccepted = profile.safetyNoticeVersionAccepted
        onboardingCompletedAt = profile.onboardingCompletedAt
        profileCompletedAt = existing?.profileCompletedAt ?? profile.onboardingCompletedAt
        lastSuccessfulRemoteRefreshAt = Date()
        lastSuccessfulAuthAt = existing?.lastSuccessfulAuthAt ?? Date()
        lastKnownEntitlementStatus = existing?.lastKnownEntitlementStatus
        lastKnownEntitlementExpiresAt = existing?.lastKnownEntitlementExpiresAt
        schemaVersion = Self.currentSchemaVersion
    }
}

protocol FirebaseAccountGateUser {
    var uid: String { get }
    var email: String? { get }
    var emailVerified: Bool { get }
}

extension SatChartUserProfile {
    init(snapshot: AccountGateSnapshot) {
        uid = snapshot.uid
        email = snapshot.email ?? ""
        emailVerified = snapshot.emailVerified
        termsVersionAccepted = snapshot.termsVersionAccepted ?? ""
        privacyVersionAccepted = snapshot.privacyVersionAccepted ?? ""
        safetyNoticeVersionAccepted = snapshot.safetyNoticeVersionAccepted ?? ""
        onboardingCompletedAt = snapshot.onboardingCompletedAt
        profileCompletedAt = snapshot.profileCompletedAt
        legalAccepted = snapshot.hasCompletedRequiredLegal()
        profileCompleted = snapshot.hasCompletedProfile
        firstName = snapshot.firstName ?? ""
        lastName = snapshot.lastName ?? ""
        displayName = [firstName, lastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        vesselName = snapshot.vesselName ?? ""
        radioDisplayName = snapshot.radioDisplayName ?? displayName
        role = ""
        homeDistrict = ""
        defaultWaypointPinColorID = WaypointColorPreferences.ensureLocalDefaultColor().rawValue
    }
}
