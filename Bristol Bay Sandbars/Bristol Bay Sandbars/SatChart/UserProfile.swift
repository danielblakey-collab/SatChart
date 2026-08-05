import Foundation
import FirebaseAuth
import FirebaseFirestore

struct UserProfile: Identifiable, Equatable {
    let uid: String
    var email: String
    var emailVerified: Bool
    var firstName: String
    var lastName: String
    var vesselName: String
    var radioDisplayName: String
    var createdAt: Date?
    var updatedAt: Date?
    var termsVersionAccepted: String
    var privacyVersionAccepted: String
    var safetyNoticeVersionAccepted: String
    var onboardingCompletedAt: Date?
    var defaultWaypointPinColorID: String

    var id: String { uid }

    var fullName: String {
        [firstName, lastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    init(
        uid: String,
        email: String,
        emailVerified: Bool,
        firstName: String = "",
        lastName: String = "",
        vesselName: String = "",
        radioDisplayName: String = "",
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        termsVersionAccepted: String = "",
        privacyVersionAccepted: String = "",
        safetyNoticeVersionAccepted: String = "",
        onboardingCompletedAt: Date? = nil,
        defaultWaypointPinColorID: String = WaypointColorPreferences.ensureLocalDefaultColor().rawValue
    ) {
        self.uid = uid
        self.email = email
        self.emailVerified = emailVerified
        self.firstName = firstName
        self.lastName = lastName
        self.vesselName = vesselName
        self.radioDisplayName = radioDisplayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.termsVersionAccepted = termsVersionAccepted
        self.privacyVersionAccepted = privacyVersionAccepted
        self.safetyNoticeVersionAccepted = safetyNoticeVersionAccepted
        self.onboardingCompletedAt = onboardingCompletedAt
        self.defaultWaypointPinColorID = WaypointPinColor.safe(rawValue: defaultWaypointPinColorID).rawValue
    }

    init(user: User, data: [String: Any] = [:]) {
        uid = user.uid
        email = (data["email"] as? String) ?? user.email ?? ""
        emailVerified = (data["emailVerified"] as? Bool) ?? user.isEmailVerified

        let storedFirst = (data["firstName"] as? String) ?? ""
        let storedLast = (data["lastName"] as? String) ?? ""
        let displayName = (data["displayName"] as? String) ?? user.displayName ?? ""
        let split = Self.splitDisplayName(displayName)

        firstName = storedFirst.isEmpty ? split.first : storedFirst
        lastName = storedLast.isEmpty ? split.last : storedLast
        let storedVesselName = (data["vesselName"] as? String) ?? ""
        vesselName = storedVesselName
        radioDisplayName = (data["radioDisplayName"] as? String) ?? (data["displayName"] as? String) ?? storedVesselName
        createdAt = Self.date(from: data["createdAt"])
        updatedAt = Self.date(from: data["updatedAt"])
        termsVersionAccepted = (data["termsVersionAccepted"] as? String) ?? (data["legalNoticeVersion"] as? String) ?? ""
        privacyVersionAccepted = (data["privacyVersionAccepted"] as? String) ?? ""
        safetyNoticeVersionAccepted = (data["safetyNoticeVersionAccepted"] as? String) ?? (data["legalNoticeVersion"] as? String) ?? ""
        onboardingCompletedAt = Self.date(from: data["onboardingCompletedAt"]) ?? Self.date(from: data["profileCompletedAt"])
        defaultWaypointPinColorID = WaypointPinColor.safe(
            rawValue: (data["defaultWaypointPinColorID"] as? String) ?? (data["waypointPinColorID"] as? String),
            fallback: WaypointColorPreferences.ensureLocalDefaultColor()
        ).rawValue
    }

    func firestoreDataForSave() -> [String: Any] {
        [
            "uid": uid,
            "email": email,
            "emailVerified": emailVerified,
            "firstName": firstName,
            "lastName": lastName,
            "displayName": fullName,
            "vesselName": vesselName,
            "radioDisplayName": radioDisplayName,
            "defaultWaypointPinColorID": WaypointPinColor.safe(rawValue: defaultWaypointPinColorID).rawValue,
            "updatedAt": FieldValue.serverTimestamp()
        ]
    }

    static func splitDisplayName(_ displayName: String) -> (first: String, last: String) {
        let parts = displayName
            .split(separator: " ")
            .map(String.init)

        guard let first = parts.first else { return ("", "") }
        let last = parts.dropFirst().joined(separator: " ")
        return (first, last)
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
