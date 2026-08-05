import Foundation
import CoreLocation
import FirebaseFirestore

enum RadioGroupRole: String, Codable {
    case owner
    case admin
    case member

    var canApprove: Bool {
        self == .owner || self == .admin
    }
}

struct RadioGroupSettings: Equatable {
    var requireApproval: Bool
    var allowLiveLocation: Bool
    var pinDefaultTTLSeconds: Int
    var waypointDefaultTTLSeconds: Int
    var affiliationCountVisibleToMembers: Bool

    static let productionDefault = RadioGroupSettings(
        requireApproval: true,
        allowLiveLocation: true,
        pinDefaultTTLSeconds: 6 * 60 * 60,
        waypointDefaultTTLSeconds: 14 * 24 * 60 * 60,
        affiliationCountVisibleToMembers: true
    )

    init(data: [String: Any] = [:]) {
        requireApproval = (data["requireApproval"] as? Bool) ?? true
        allowLiveLocation = (data["allowLiveLocation"] as? Bool) ?? true
        pinDefaultTTLSeconds = (data["pinDefaultTTLSeconds"] as? Int) ?? 6 * 60 * 60
        waypointDefaultTTLSeconds = (data["waypointDefaultTTLSeconds"] as? Int) ?? 14 * 24 * 60 * 60
        affiliationCountVisibleToMembers = (data["affiliationCountVisibleToMembers"] as? Bool) ?? true
    }

    init(
        requireApproval: Bool,
        allowLiveLocation: Bool,
        pinDefaultTTLSeconds: Int,
        waypointDefaultTTLSeconds: Int,
        affiliationCountVisibleToMembers: Bool
    ) {
        self.requireApproval = requireApproval
        self.allowLiveLocation = allowLiveLocation
        self.pinDefaultTTLSeconds = pinDefaultTTLSeconds
        self.waypointDefaultTTLSeconds = waypointDefaultTTLSeconds
        self.affiliationCountVisibleToMembers = affiliationCountVisibleToMembers
    }
}

struct RadioGroupSummary: Identifiable, Equatable {
    let id: String
    var name: String
    var createdByUid: String
    var memberCount: Int
    var active: Bool
    var inviteExpiresAt: Date?
    var settings: RadioGroupSettings

    init(id: String, data: [String: Any]) {
        self.id = id
        name = (data["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Radio Group"
        createdByUid = (data["createdByUid"] as? String) ?? (data["createdBy"] as? String) ?? ""
        memberCount = (data["memberCount"] as? Int) ?? 0
        active = (data["active"] as? Bool) ?? true
        inviteExpiresAt = Self.date(from: data["inviteExpiresAt"])
        settings = RadioGroupSettings(data: data["settings"] as? [String: Any] ?? [:])
    }

    private static func date(from value: Any?) -> Date? {
        if let timestamp = value as? Timestamp { return timestamp.dateValue() }
        if let date = value as? Date { return date }
        return nil
    }
}

struct RadioGroupMembership: Identifiable, Equatable {
    let id: String
    var groupId: String
    var groupName: String
    var role: RadioGroupRole
    var active: Bool
    var joinedAt: Date?
    var approvedBy: String
    var lastSeenAt: Date?

    init(id: String, data: [String: Any]) {
        self.id = id
        groupId = (data["groupId"] as? String) ?? id
        groupName = (data["groupName"] as? String) ?? "Radio Group"
        role = RadioGroupRole(rawValue: (data["role"] as? String) ?? "") ?? .member
        active = (data["active"] as? Bool) ?? true
        joinedAt = Self.date(from: data["joinedAt"])
        approvedBy = (data["approvedBy"] as? String) ?? ""
        lastSeenAt = Self.date(from: data["lastSeenAt"])
    }

    private static func date(from value: Any?) -> Date? {
        if let timestamp = value as? Timestamp { return timestamp.dateValue() }
        if let date = value as? Date { return date }
        return nil
    }
}

struct RadioGroupMember: Identifiable, Hashable {
    let id: String
    var uid: String
    var displayName: String
    var vesselName: String
    var role: RadioGroupRole
    var active: Bool
    var joinedAt: Date?
    var approvedBy: String
    var canShareLocation: Bool
    var canInvite: Bool
    var canApprove: Bool
    var publicMembershipCount: Int
    var lastSeenAt: Date?
    var waypointPinColorID: String

    init(id: String, data: [String: Any]) {
        self.id = id
        uid = (data["uid"] as? String) ?? id
        let name = (data["displayName"] as? String) ?? (data["name"] as? String) ?? ""
        displayName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Member" : name
        vesselName = ((data["vesselName"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        role = RadioGroupRole(rawValue: (data["role"] as? String) ?? "") ?? .member
        active = (data["active"] as? Bool) ?? true
        joinedAt = Self.date(from: data["joinedAt"])
        approvedBy = (data["approvedBy"] as? String) ?? ""
        canShareLocation = (data["canShareLocation"] as? Bool) ?? true
        canInvite = (data["canInvite"] as? Bool) ?? role.canApprove
        canApprove = (data["canApprove"] as? Bool) ?? role.canApprove
        publicMembershipCount = max(0, (data["publicMembershipCount"] as? Int) ?? 0)
        lastSeenAt = Self.date(from: data["lastSeenAt"])
        let rawColor = (data["waypointPinColorID"] as? String)
            ?? (data["defaultWaypointPinColorID"] as? String)
            ?? (data["colorID"] as? String)
        waypointPinColorID = WaypointPinColor.safe(rawValue: rawColor, fallback: WaypointPinColor.deterministicFallback(seed: uid)).rawValue
    }

    var waypointPinColor: WaypointPinColor {
        WaypointPinColor.safe(rawValue: waypointPinColorID, fallback: WaypointPinColor.deterministicFallback(seed: uid))
    }

    var waypointDisplayLabel: String {
        let vessel = vesselName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vessel.isEmpty { return vessel }
        let display = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return display.isEmpty ? "Member" : display
    }

    private static func date(from value: Any?) -> Date? {
        if let timestamp = value as? Timestamp { return timestamp.dateValue() }
        if let date = value as? Date { return date }
        return nil
    }
}

struct RadioGroupJoinRequest: Identifiable, Hashable {
    let id: String
    var requestedByUid: String
    var requestedByName: String
    var requestedVesselName: String
    var status: String
    var createdAt: Date
    var decidedAt: Date?
    var decidedBy: String
    var waypointPinColorID: String

    init(id: String, data: [String: Any]) {
        self.id = id
        requestedByUid = (data["requestedByUid"] as? String) ?? id
        requestedByName = ((data["requestedByName"] as? String) ?? "Member").trimmingCharacters(in: .whitespacesAndNewlines)
        requestedVesselName = ((data["requestedVesselName"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        status = (data["status"] as? String) ?? "pending"
        createdAt = Self.date(from: data["createdAt"]) ?? Date()
        decidedAt = Self.date(from: data["decidedAt"])
        decidedBy = (data["decidedBy"] as? String) ?? ""
        waypointPinColorID = WaypointPinColor.safe(
            rawValue: (data["waypointPinColorID"] as? String) ?? (data["defaultWaypointPinColorID"] as? String),
            fallback: WaypointPinColor.deterministicFallback(seed: requestedByUid)
        ).rawValue
    }

    private static func date(from value: Any?) -> Date? {
        if let timestamp = value as? Timestamp { return timestamp.dateValue() }
        if let date = value as? Date { return date }
        return nil
    }
}

enum RadioGroupRecordParser {
    static func double(from value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Float:
            return Double(value)
        case let value as Int:
            return Double(value)
        case let value as Int64:
            return Double(value)
        case let value as NSNumber where !(value is Bool):
            return value.doubleValue
        case let value as String:
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    static func coordinate(lat: Any?, lon: Any?) -> CLLocationCoordinate2D? {
        guard let latitude = double(from: lat),
              let longitude = double(from: lon),
              isValid(latitude: latitude, longitude: longitude) else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static func isValid(_ coordinate: CLLocationCoordinate2D) -> Bool {
        isValid(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    static func isValid(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite
            && longitude.isFinite
            && (-90...90).contains(latitude)
            && (-180...180).contains(longitude)
    }

    static func date(from value: Any?) -> Date? {
        if let timestamp = value as? Timestamp { return timestamp.dateValue() }
        if let date = value as? Date { return date }
        if let seconds = double(from: value) { return Date(timeIntervalSince1970: seconds) }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let iso8601WithFractionalSeconds = ISO8601DateFormatter()
            iso8601WithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso8601WithFractionalSeconds.date(from: trimmed) { return date }
            let iso8601 = ISO8601DateFormatter()
            if let date = iso8601.date(from: trimmed) { return date }
        }
        return nil
    }
}

struct LiveLocationSessionSnapshot: Equatable {
    var isActiveIntent: Bool
    var backgroundedAt: Date?
    var lastSentAt: Date?
    var groupId: String?
    var promptShownForBackgroundedAt: Date?
}

enum LiveLocationResumeAction: Equatable {
    case none
    case restore
    case prompt
    case expired
}

enum LiveLocationSessionState {
    static let autoRestoreWindow: TimeInterval = 10 * 60
    static let promptWindow: TimeInterval = 60 * 60
    static let hideStalePinAfter: TimeInterval = 60 * 60

    private enum Key {
        static let isActiveIntent = "liveLocationSession.isActiveIntent"
        static let backgroundedAt = "liveLocationSession.backgroundedAt"
        static let lastSentAt = "liveLocationSession.lastSentAt"
        static let groupId = "liveLocationSession.groupId"
        static let promptShownForBackgroundedAt = "liveLocationSession.promptShownForBackgroundedAt"
    }

    static func markActive(
        defaults: UserDefaults = .standard,
        lastSentAt: Date?,
        groupId: String?
    ) {
        defaults.set(true, forKey: Key.isActiveIntent)
        set(date: lastSentAt, forKey: Key.lastSentAt, defaults: defaults)
        set(string: groupId, forKey: Key.groupId, defaults: defaults)
        defaults.removeObject(forKey: Key.backgroundedAt)
        defaults.removeObject(forKey: Key.promptShownForBackgroundedAt)
    }

    static func recordBackgrounded(
        defaults: UserDefaults = .standard,
        backgroundedAt: Date,
        lastSentAt: Date?,
        groupId: String?
    ) {
        let existing = snapshot(defaults: defaults)
        defaults.set(true, forKey: Key.isActiveIntent)
        set(date: existing?.backgroundedAt ?? backgroundedAt, forKey: Key.backgroundedAt, defaults: defaults)
        set(date: lastSentAt, forKey: Key.lastSentAt, defaults: defaults)
        set(string: groupId, forKey: Key.groupId, defaults: defaults)
    }

    static func markPromptShown(defaults: UserDefaults = .standard, backgroundedAt: Date) {
        set(date: backgroundedAt, forKey: Key.promptShownForBackgroundedAt, defaults: defaults)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Key.isActiveIntent)
        defaults.removeObject(forKey: Key.backgroundedAt)
        defaults.removeObject(forKey: Key.lastSentAt)
        defaults.removeObject(forKey: Key.groupId)
        defaults.removeObject(forKey: Key.promptShownForBackgroundedAt)
    }

    static func snapshot(defaults: UserDefaults = .standard) -> LiveLocationSessionSnapshot? {
        guard defaults.bool(forKey: Key.isActiveIntent) else { return nil }
        return LiveLocationSessionSnapshot(
            isActiveIntent: true,
            backgroundedAt: date(forKey: Key.backgroundedAt, defaults: defaults),
            lastSentAt: date(forKey: Key.lastSentAt, defaults: defaults),
            groupId: string(forKey: Key.groupId, defaults: defaults),
            promptShownForBackgroundedAt: date(forKey: Key.promptShownForBackgroundedAt, defaults: defaults)
        )
    }

    static func resumeAction(
        for snapshot: LiveLocationSessionSnapshot?,
        now: Date
    ) -> LiveLocationResumeAction {
        guard let snapshot, snapshot.isActiveIntent else { return .none }
        guard let backgroundedAt = snapshot.backgroundedAt else { return .none }

        let elapsed = now.timeIntervalSince(backgroundedAt)
        if elapsed < autoRestoreWindow {
            return .restore
        }
        if elapsed < promptWindow {
            if let shownAt = snapshot.promptShownForBackgroundedAt,
               abs(shownAt.timeIntervalSince(backgroundedAt)) < 0.001 {
                return .none
            }
            return .prompt
        }
        return .expired
    }

    private static func set(date: Date?, forKey key: String, defaults: UserDefaults) {
        if let date {
            defaults.set(date.timeIntervalSince1970, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func date(forKey key: String, defaults: UserDefaults) -> Date? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: key))
    }

    private static func set(string: String?, forKey key: String, defaults: UserDefaults) {
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
    }

    private static func string(forKey key: String, defaults: UserDefaults) -> String? {
        let trimmed = (defaults.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct RadioGroupPinRecord: Identifiable, Hashable {
    let id: String
    var ownerUid: String
    var coordinate: CLLocationCoordinate2D
    var displayName: String
    var createdAt: Date
    var updatedAt: Date
    var expiresAt: Date?
    var source: String
    var deletedAt: Date?
    var hasValidCoordinate: Bool
    var colorID: String

    init(id: String, data: [String: Any]) {
        self.id = id
        ownerUid = ((data["ownerUid"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedCoordinate = RadioGroupRecordParser.coordinate(lat: data["lat"], lon: data["lon"])
        coordinate = parsedCoordinate ?? CLLocationCoordinate2D(latitude: .nan, longitude: .nan)
        hasValidCoordinate = parsedCoordinate != nil
        let rawDisplayName = ((data["displayName"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = rawDisplayName.isEmpty ? "Member" : rawDisplayName
        createdAt = RadioGroupRecordParser.date(from: data["createdAt"]) ?? Date.distantPast
        updatedAt = RadioGroupRecordParser.date(from: data["updatedAt"]) ?? createdAt
        expiresAt = RadioGroupRecordParser.date(from: data["expiresAt"])
        source = (data["source"] as? String) ?? "one_time_pin"
        deletedAt = RadioGroupRecordParser.date(from: data["deletedAt"])
        colorID = ((data["colorID"] as? String) ?? (data["waypointPinColorID"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isExpired: Bool {
        if deletedAt != nil { return true }
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    static func == (lhs: RadioGroupPinRecord, rhs: RadioGroupPinRecord) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct RadioGroupLiveLocationRecord: Identifiable, Hashable {
    let id: String
    var ownerUid: String
    var coordinate: CLLocationCoordinate2D
    var accuracyMeters: Double?
    var course: Double?
    var speed: Double?
    var displayName: String
    var updatedAt: Date
    var expiresAt: Date?
    var sharingEnabled: Bool
    var hasValidCoordinate: Bool
    var colorID: String

    init(id: String, data: [String: Any]) {
        self.id = id
        let rawOwnerUid = ((data["ownerUid"] as? String) ?? id).trimmingCharacters(in: .whitespacesAndNewlines)
        ownerUid = rawOwnerUid.isEmpty ? id : rawOwnerUid
        let parsedCoordinate = RadioGroupRecordParser.coordinate(lat: data["lat"], lon: data["lon"])
        coordinate = parsedCoordinate ?? CLLocationCoordinate2D(latitude: .nan, longitude: .nan)
        hasValidCoordinate = parsedCoordinate != nil
        accuracyMeters = RadioGroupRecordParser.double(from: data["accuracyMeters"])
        course = RadioGroupRecordParser.double(from: data["course"])
        speed = RadioGroupRecordParser.double(from: data["speed"])
        let rawDisplayName = ((data["displayName"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = rawDisplayName.isEmpty ? "Member" : rawDisplayName
        updatedAt = RadioGroupRecordParser.date(from: data["updatedAt"]) ?? Date.distantPast
        expiresAt = RadioGroupRecordParser.date(from: data["expiresAt"])
        sharingEnabled = (data["sharingEnabled"] as? Bool) ?? true
        colorID = ((data["colorID"] as? String) ?? (data["waypointPinColorID"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isExpired: Bool {
        if !sharingEnabled { return true }
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    static func == (lhs: RadioGroupLiveLocationRecord, rhs: RadioGroupLiveLocationRecord) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct RadioGroupSharedWaypointRecord: Identifiable, Hashable {
    let id: String
    var ownerUid: String
    var senderName: String
    var name: String
    var notes: String
    var coordinate: CLLocationCoordinate2D
    var createdAt: Date
    var sentAt: Date
    var expiresAt: Date?
    var deletedByOwnerAt: Date?
    var originalWaypointId: String
    var colorID: String

    init(id: String, data: [String: Any]) {
        self.id = id
        ownerUid = (data["ownerUid"] as? String)
            ?? (data["senderUid"] as? String)
            ?? (data["createdByUid"] as? String)
            ?? (data["requestedByUid"] as? String)
            ?? (data["createdBy"] as? String)
            ?? ""
        senderName = ((data["senderName"] as? String)
            ?? (data["createdByName"] as? String)
            ?? (data["requestedByName"] as? String)
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        name = (data["name"] as? String) ?? "Waypoint"
        notes = (data["notes"] as? String) ?? ""
        coordinate = CLLocationCoordinate2D(
            latitude: (data["lat"] as? Double) ?? 0,
            longitude: (data["lon"] as? Double) ?? 0
        )
        createdAt = Self.date(from: data["createdAt"]) ?? Date()
        sentAt = Self.date(from: data["sentAt"]) ?? createdAt
        expiresAt = Self.date(from: data["expiresAt"])
        deletedByOwnerAt = Self.date(from: data["deletedByOwnerAt"])
        originalWaypointId = (data["originalWaypointId"] as? String) ?? ""
        colorID = WaypointPinColor.safe(
            rawValue: (data["colorID"] as? String) ?? (data["waypointPinColorID"] as? String),
            fallback: WaypointPinColor.deterministicFallback(seed: ownerUid.isEmpty ? id : ownerUid)
        ).rawValue
    }

    var pinColor: WaypointPinColor {
        WaypointPinColor.safe(rawValue: colorID, fallback: WaypointPinColor.deterministicFallback(seed: ownerUid.isEmpty ? id : ownerUid))
    }

    var isExpired: Bool {
        if deletedByOwnerAt != nil { return true }
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    private static func date(from value: Any?) -> Date? {
        if let timestamp = value as? Timestamp { return timestamp.dateValue() }
        if let date = value as? Date { return date }
        return nil
    }

    static func == (lhs: RadioGroupSharedWaypointRecord, rhs: RadioGroupSharedWaypointRecord) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct RadioGroupCreateResult: Equatable {
    let groupId: String
    let groupName: String
    let inviteCode: String
    let inviteExpiresAt: Date?
}

struct RadioGroupJoinResult: Equatable {
    let groupId: String
    let groupName: String
    let status: String
}
