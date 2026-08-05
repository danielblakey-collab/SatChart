import Foundation
import CoreLocation
import CryptoKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions

enum RadioGroupServiceError: LocalizedError {
    case signInRequired
    case invalidInviteCode
    case groupNotFound
    case invalidCoordinate
    case missingActiveGroup
    case locationSharingUnavailable
    case noWaypointPinColorsAvailable

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            return "Sign in is required for Radio Groups."
        case .invalidInviteCode:
            return "Invalid invite code. Ask the Radio Group owner for a fresh code."
        case .groupNotFound:
            return "Unable to find that Radio Group."
        case .invalidCoordinate:
            return "Unable to share that location."
        case .missingActiveGroup:
            return "Choose an active Radio Group first."
        case .locationSharingUnavailable:
            return "Live location sharing is unavailable for this Radio Group."
        case .noWaypointPinColorsAvailable:
            return "No waypoint pin colors are available for this group."
        }
    }
}

final class RadioGroupService {
    private enum LocalKey {
        static let firstName = "userFirstName"
        static let lastName = "userLastName"
        static let vesselName = "vesselName"
        static let radioDisplayName = "radioPinDisplayName"
    }

    private let auth: Auth
    private let db: Firestore
    private let functions: Functions
    private let defaults: UserDefaults
    private let allowsLocalCallableStubs: Bool

    init(
        auth: Auth = Auth.auth(),
        db: Firestore = Firestore.firestore(),
        functions: Functions = Functions.functions(),
        defaults: UserDefaults = .standard,
        allowsLocalCallableStubs: Bool? = nil
    ) {
        self.auth = auth
        self.db = db
        self.functions = functions
        self.defaults = defaults
        #if DEBUG
        self.allowsLocalCallableStubs = allowsLocalCallableStubs ?? true
        #else
        self.allowsLocalCallableStubs = allowsLocalCallableStubs ?? false
        #endif
    }

    var currentUser: User? {
        auth.currentUser
    }

    var hasProductionUser: Bool {
        guard let user = auth.currentUser else { return false }
        return !user.isAnonymous
    }

    func requireSignedInUser() throws -> User {
        guard let user = auth.currentUser, !user.isAnonymous else {
            throw RadioGroupServiceError.signInRequired
        }
        return user
    }

    func createRadioGroup(groupName: String, firstName: String, lastName: String, vesselName: String) async throws -> RadioGroupCreateResult {
        let user = try requireSignedInUser()
        let cleanGroupName = clean(groupName)
        let displayName = displayName(firstName: firstName, lastName: lastName, fallback: user)
        let vessel = clean(vesselName)
        let waypointColor = WaypointColorPreferences.ensureLocalDefaultColor()
        let memberLabel = memberDisplayLabel(firstName: firstName, lastName: lastName, vesselName: vessel, displayName: displayName)

        do {
            let result = try await callFunction("createRadioGroup", data: [
                "groupName": cleanGroupName,
                "displayName": displayName,
                "vesselName": vessel,
                "memberDisplayLabel": memberLabel,
                "waypointPinColorID": waypointColor.rawValue,
                "profile": profilePayload(firstName: firstName, lastName: lastName, vesselName: vessel, displayName: displayName)
            ])
            return RadioGroupCreateResult(
                groupId: (result["groupId"] as? String) ?? "",
                groupName: (result["groupName"] as? String) ?? cleanGroupName,
                inviteCode: (result["inviteCode"] as? String) ?? "",
                inviteExpiresAt: date(from: result["inviteExpiresAt"])
            )
        } catch {
            guard shouldUseLocalStub(after: error) else { throw friendly(error) }
            return try await localCreateRadioGroup(
                uid: user.uid,
                email: user.email ?? "",
                groupName: cleanGroupName,
                displayName: displayName,
                firstName: firstName,
                lastName: lastName,
                vesselName: vessel
            )
        }
    }

    func rotateInviteCode(groupId: String) async throws -> RadioGroupCreateResult {
        let user = try requireSignedInUser()
        let cleanGroupId = clean(groupId)

        do {
            let result = try await callFunction("rotateInviteCode", data: ["groupId": cleanGroupId])
            return RadioGroupCreateResult(
                groupId: (result["groupId"] as? String) ?? cleanGroupId,
                groupName: (result["groupName"] as? String) ?? "Radio Group",
                inviteCode: (result["inviteCode"] as? String) ?? "",
                inviteExpiresAt: date(from: result["inviteExpiresAt"])
            )
        } catch {
            guard shouldUseLocalStub(after: error) else { throw friendly(error) }
            return try await localRotateInviteCode(uid: user.uid, groupId: cleanGroupId)
        }
    }

    func requestJoinGroup(inviteCode: String, firstName: String, lastName: String, vesselName: String) async throws -> RadioGroupJoinResult {
        let user = try requireSignedInUser()
        let code = clean(inviteCode).uppercased()
        let displayName = displayName(firstName: firstName, lastName: lastName, fallback: user)
        let vessel = clean(vesselName)
        let waypointColor = WaypointColorPreferences.ensureLocalDefaultColor()
        let memberLabel = memberDisplayLabel(firstName: firstName, lastName: lastName, vesselName: vessel, displayName: displayName)

        do {
            let result = try await callFunction("requestJoinGroup", data: [
                "inviteCode": code,
                "displayName": displayName,
                "vesselName": vessel,
                "memberDisplayLabel": memberLabel,
                "waypointPinColorID": waypointColor.rawValue,
                "profile": profilePayload(firstName: firstName, lastName: lastName, vesselName: vessel, displayName: displayName)
            ])
            return RadioGroupJoinResult(
                groupId: (result["groupId"] as? String) ?? "",
                groupName: (result["groupName"] as? String) ?? "Radio Group",
                status: (result["status"] as? String) ?? "pending"
            )
        } catch {
            guard shouldUseLocalStub(after: error) else { throw friendly(error) }
            return try await localRequestJoinGroup(
                uid: user.uid,
                email: user.email ?? "",
                inviteCode: code,
                displayName: displayName,
                firstName: firstName,
                lastName: lastName,
                vesselName: vessel
            )
        }
    }

    func approveJoinRequest(groupId: String, requesterUid: String) async throws {
        let user = try requireSignedInUser()
        do {
            _ = try await callFunction("approveJoinRequest", data: ["groupId": groupId, "requesterUid": requesterUid])
        } catch {
            guard shouldUseLocalStub(after: error) else { throw friendly(error) }
            try await localApproveJoinRequest(actorUid: user.uid, groupId: groupId, requesterUid: requesterUid)
        }
    }

    func rejectJoinRequest(groupId: String, requesterUid: String) async throws {
        let user = try requireSignedInUser()
        do {
            _ = try await callFunction("rejectJoinRequest", data: ["groupId": groupId, "requesterUid": requesterUid])
        } catch {
            guard shouldUseLocalStub(after: error) else { throw friendly(error) }
            try await localRejectJoinRequest(actorUid: user.uid, groupId: groupId, requesterUid: requesterUid)
        }
    }

    func leaveGroup(groupId: String) async throws {
        let user = try requireSignedInUser()
        do {
            _ = try await callFunction("leaveGroup", data: ["groupId": groupId])
        } catch {
            guard shouldUseLocalStub(after: error) else { throw friendly(error) }
            try await localLeaveGroup(uid: user.uid, groupId: groupId)
        }
    }

    func updateMemberProfile(groupId: String? = nil, firstName: String, lastName: String, vesselName: String) async throws {
        let user = try requireSignedInUser()
        let displayName = displayName(firstName: firstName, lastName: lastName, fallback: user)
        let vessel = clean(vesselName)

        do {
            _ = try await callFunction("updateRadioGroupMemberProfile", data: [
                "groupId": groupId ?? "",
                "displayName": displayName,
                "vesselName": vessel,
                "profile": profilePayload(firstName: firstName, lastName: lastName, vesselName: vessel, displayName: displayName)
            ])
        } catch {
            guard shouldUseLocalStub(after: error) else { throw friendly(error) }
            try await localUpdateMemberProfile(uid: user.uid, groupId: groupId, firstName: firstName, lastName: lastName, vesselName: vessel, displayName: displayName)
        }
    }

    func updateWaypointPinColor(groupId: String?, colorID: String) async throws {
        let user = try requireSignedInUser()
        let color = WaypointPinColor.safe(rawValue: colorID)

        do {
            _ = try await callFunction("updateRadioGroupWaypointPinColor", data: [
                "groupId": groupId ?? "",
                "colorID": color.rawValue,
                "waypointPinColorID": color.rawValue
            ])
        } catch {
            guard shouldUseLocalStub(after: error) else { throw friendly(error) }
            try await localUpdateWaypointPinColor(uid: user.uid, groupId: groupId, color: color)
        }
    }

    func normalizeMemberColors(groupId: String) async throws {
        _ = try requireSignedInUser()

        do {
            _ = try await callFunction("normalizeRadioGroupMemberColors", data: ["groupId": groupId])
        } catch {
            guard shouldUseLocalStub(after: error) else { throw friendly(error) }
            try await localNormalizeMemberColors(groupId: groupId)
        }
    }

    func sendPin(groupId: String, coordinate: CLLocationCoordinate2D, displayName: String, ttlSeconds: Int) async throws {
        let user = try requireSignedInUser()
        try validate(coordinate)

        do {
            _ = try await callFunction("createRadioGroupPin", data: [
                "groupId": groupId,
                "lat": coordinate.latitude,
                "lon": coordinate.longitude,
                "displayName": clean(displayName),
                "ttlSeconds": ttlSeconds
            ])
        } catch {
            guard shouldUseLocalStub(after: error) else { throw friendly(error) }
            try await localSendPin(uid: user.uid, groupId: groupId, coordinate: coordinate, displayName: displayName, ttlSeconds: ttlSeconds)
        }
    }

    func upsertLiveLocation(
        groupId: String,
        coordinate: CLLocationCoordinate2D,
        displayName: String,
        accuracyMeters: Double? = nil,
        course: Double? = nil,
        speed: Double? = nil,
        ttlSeconds: Int = 5 * 60
    ) async throws {
        let user = try requireSignedInUser()
        try validate(coordinate)

        var payload: [String: Any] = [
            "groupId": groupId,
            "lat": coordinate.latitude,
            "lon": coordinate.longitude,
            "displayName": clean(displayName),
            "ttlSeconds": ttlSeconds
        ]
        if let accuracyMeters { payload["accuracyMeters"] = accuracyMeters }
        if let course { payload["course"] = course }
        if let speed { payload["speed"] = speed }

        do {
            _ = try await callFunction("upsertRadioGroupLiveLocation", data: payload)
        } catch {
            guard shouldUseLocalStub(after: error) else { throw friendly(error) }
            try await localUpsertLiveLocation(
                uid: user.uid,
                groupId: groupId,
                coordinate: coordinate,
                displayName: displayName,
                accuracyMeters: accuracyMeters,
                course: course,
                speed: speed,
                ttlSeconds: ttlSeconds
            )
        }
    }

    func stopLiveLocation(groupId: String) async throws {
        let user = try requireSignedInUser()
        do {
            _ = try await callFunction("stopRadioGroupLiveLocation", data: ["groupId": groupId])
        } catch {
            guard shouldUseLocalStub(after: error) else { throw friendly(error) }
            try await localStopLiveLocation(uid: user.uid, groupId: groupId)
        }
    }

    func deleteLastPin(groupId: String) async throws {
        let user = try requireSignedInUser()
        do {
            _ = try await callFunction("deleteLastRadioGroupPin", data: ["groupId": groupId])
        } catch {
            guard shouldUseLocalStub(after: error) else { throw friendly(error) }
            try await localDeleteLastPin(uid: user.uid, groupId: groupId)
        }
    }

    func deleteAllPins(groupId: String) async throws {
        let user = try requireSignedInUser()
        do {
            _ = try await callFunction("deleteAllRadioGroupPins", data: ["groupId": groupId])
        } catch {
            guard shouldUseLocalStub(after: error) else { throw friendly(error) }
            try await localDeleteAllPins(uid: user.uid, groupId: groupId)
        }
    }

    func sendWaypoint(groupId: String, waypoint: Waypoint, senderName: String, forceNewDoc: Bool) async throws {
        let user = try requireSignedInUser()
        try validate(waypoint.coordinate)

        do {
            _ = try await callFunction("shareRadioGroupWaypoint", data: [
                "groupId": groupId,
                "waypointId": waypoint.id.uuidString,
                "forceNewDoc": forceNewDoc,
                "name": clean(waypoint.name),
                "notes": clean(waypoint.notes, maxLength: 1200),
                "lat": waypoint.coordinate.latitude,
                "lon": waypoint.coordinate.longitude,
                "createdAtEpoch": waypoint.createdAt.timeIntervalSince1970,
                "senderName": clean(senderName),
                "colorID": waypoint.pinColor.rawValue,
                "waypointPinColorID": waypoint.pinColor.rawValue
            ])
        } catch {
            guard shouldUseLocalStub(after: error) else { throw friendly(error) }
            try await localSendWaypoint(uid: user.uid, groupId: groupId, waypoint: waypoint, senderName: senderName, forceNewDoc: forceNewDoc)
        }
    }

    static func friendlyMessage(for error: Error) -> String {
        if let radioError = error as? RadioGroupServiceError {
            return radioError.localizedDescription
        }

        let nsError = error as NSError
        if nsError.domain == AuthErrorDomain,
           let code = AuthErrorCode(rawValue: nsError.code) {
            switch code {
            case .requiresRecentLogin:
                return "For your security, please sign in again before making this Radio Group change."
            case .networkError:
                return "Please check your internet connection."
            case .tooManyRequests:
                return "Too many attempts. Please wait a few minutes before trying again."
            default:
                break
            }
        }

        if nsError.domain == FunctionsErrorDomain,
           let code = FunctionsErrorCode(rawValue: nsError.code) {
            let detail = (nsError.userInfo[NSLocalizedDescriptionKey] as? String ?? nsError.localizedDescription).lowercased()
            switch code {
            case .unauthenticated:
                return "Sign in is required for Radio Groups."
            case .permissionDenied:
                return "You do not have permission to make that Radio Group change."
            case .notFound:
                return "Unable to find that Radio Group or invite code."
            case .invalidArgument:
                return "Please check the details and try again."
            case .failedPrecondition:
                if detail.contains("expired") {
                    return "That invite code has expired. Ask the Radio Group owner for a fresh code."
                }
                return "For your security, please sign in again before making this Radio Group change."
            case .unavailable:
                return "Please check your internet connection."
            case .resourceExhausted:
                return "Too many attempts. Please wait a few minutes before trying again."
            case .alreadyExists:
                if detail.contains("color") {
                    return "That waypoint pin color is already in use by another member."
                }
                return "That Radio Group item already exists."
            default:
                break
            }
        }

        if nsError.domain == "RadioGroupService",
           let message = nsError.userInfo[NSLocalizedDescriptionKey] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }

        return "Unable to update Radio Group. Please contact \(SatChartReleaseConfiguration.supportEmail)."
    }

    private func friendly(_ error: Error) -> Error {
        NSError(
            domain: "RadioGroupService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: Self.friendlyMessage(for: error)]
        )
    }

    private func shouldUseLocalStub(after error: Error) -> Bool {
        guard allowsLocalCallableStubs else { return false }
        let nsError = error as NSError
        guard nsError.domain == FunctionsErrorDomain,
              let code = FunctionsErrorCode(rawValue: nsError.code) else {
            return false
        }
        return code == .notFound || code == .unimplemented || code == .unavailable
    }

    private func callFunction(_ name: String, data: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            functions.httpsCallable(name).call(data) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let dictionary = result?.data as? [String: Any] {
                    continuation.resume(returning: dictionary)
                    return
                }

                if let dictionary = result?.data as? NSDictionary {
                    continuation.resume(returning: dictionary as? [String: Any] ?? [:])
                    return
                }

                continuation.resume(returning: [:])
            }
        }
    }

    private func localCreateRadioGroup(
        uid: String,
        email: String,
        groupName: String,
        displayName: String,
        firstName: String,
        lastName: String,
        vesselName: String
    ) async throws -> RadioGroupCreateResult {
        let groupRef = db.collection("groups").document()
        let inviteCode = Self.generateInviteCode()
        let inviteExpiresAt = Date().addingTimeInterval(14 * 24 * 60 * 60)
        let settings = RadioGroupSettings.productionDefault
        let groupId = groupRef.documentID

        try await setData([
            "uid": uid,
            "email": email,
            "firstName": clean(firstName),
            "lastName": clean(lastName),
            "displayName": displayName,
            "vesselName": vesselName,
            "radioDisplayName": displayName,
            "defaultWaypointPinColorID": WaypointColorPreferences.ensureLocalDefaultColor().rawValue,
            "radioGroupAffiliationVisibility": "members",
            "updatedAt": FieldValue.serverTimestamp()
        ], on: userRef(uid), merge: true)

        let batch = db.batch()
        batch.setData([
            "name": groupName,
            "createdByUid": uid,
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp(),
            "memberCount": 1,
            "active": true,
            "inviteCodeHash": Self.hashInviteCode(inviteCode),
            "inviteExpiresAt": Timestamp(date: inviteExpiresAt),
            "settings": [
                "requireApproval": settings.requireApproval,
                "allowLiveLocation": settings.allowLiveLocation,
                "pinDefaultTTLSeconds": settings.pinDefaultTTLSeconds,
                "waypointDefaultTTLSeconds": settings.waypointDefaultTTLSeconds,
                "affiliationCountVisibleToMembers": settings.affiliationCountVisibleToMembers
            ],
            "audit": ["lastActionAt": FieldValue.serverTimestamp()]
        ], forDocument: groupRef, merge: true)

        batch.setData(memberData(
            uid: uid,
            displayName: displayName,
            vesselName: vesselName,
            role: .owner,
            approvedBy: uid,
            publicMembershipCount: 1,
            waypointPinColorID: WaypointColorPreferences.ensureLocalDefaultColor().rawValue
        ), forDocument: groupRef.collection("members").document(uid), merge: true)

        batch.setData(membershipData(
            groupId: groupId,
            groupName: groupName,
            role: .owner,
            approvedBy: uid
        ), forDocument: userRef(uid).collection("memberships").document(groupId), merge: true)

        let auditRef = groupRef.collection("auditEvents").document()
        batch.setData(auditData(actorUid: uid, action: "createRadioGroup"), forDocument: auditRef, merge: true)

        try await commit(batch)
        try await refreshMembershipCounts(for: uid)

        return RadioGroupCreateResult(groupId: groupId, groupName: groupName, inviteCode: inviteCode, inviteExpiresAt: inviteExpiresAt)
    }

    private func localRotateInviteCode(uid: String, groupId: String) async throws -> RadioGroupCreateResult {
        let groupRef = db.collection("groups").document(groupId)
        let group = try await getDocument(groupRef)
        guard group.exists else { throw RadioGroupServiceError.groupNotFound }
        try await requireCanInvite(uid: uid, groupId: groupId)

        let inviteCode = Self.generateInviteCode()
        let inviteExpiresAt = Date().addingTimeInterval(14 * 24 * 60 * 60)
        let batch = db.batch()
        batch.setData([
            "inviteCodeHash": Self.hashInviteCode(inviteCode),
            "inviteExpiresAt": Timestamp(date: inviteExpiresAt),
            "updatedAt": FieldValue.serverTimestamp(),
            "audit.lastActionAt": FieldValue.serverTimestamp()
        ], forDocument: groupRef, merge: true)
        batch.setData(auditData(actorUid: uid, action: "rotateInviteCode"), forDocument: groupRef.collection("auditEvents").document(), merge: true)
        try await commit(batch)

        let groupName = (group.data()?["name"] as? String) ?? "Radio Group"
        return RadioGroupCreateResult(groupId: groupId, groupName: groupName, inviteCode: inviteCode, inviteExpiresAt: inviteExpiresAt)
    }

    private func localRequestJoinGroup(
        uid: String,
        email: String,
        inviteCode: String,
        displayName: String,
        firstName: String,
        lastName: String,
        vesselName: String
    ) async throws -> RadioGroupJoinResult {
        guard !inviteCode.isEmpty else { throw RadioGroupServiceError.invalidInviteCode }
        let hash = Self.hashInviteCode(inviteCode)
        let snapshot = try await getDocuments(
            db.collection("groups")
                .whereField("inviteCodeHash", isEqualTo: hash)
                .whereField("active", isEqualTo: true)
                .limit(to: 1)
        )
        guard let groupDoc = snapshot.documents.first else {
            throw RadioGroupServiceError.invalidInviteCode
        }

        let data = groupDoc.data()
        if let expiresAt = (data["inviteExpiresAt"] as? Timestamp)?.dateValue(), expiresAt <= Date() {
            throw RadioGroupServiceError.invalidInviteCode
        }

        let groupId = groupDoc.documentID
        let groupName = (data["name"] as? String) ?? "Radio Group"
        let requestRef = groupDoc.reference.collection("joinRequests").document(uid)

        try await setData([
            "uid": uid,
            "email": email,
            "firstName": clean(firstName),
            "lastName": clean(lastName),
            "displayName": displayName,
            "vesselName": vesselName,
            "radioDisplayName": displayName,
            "defaultWaypointPinColorID": WaypointColorPreferences.ensureLocalDefaultColor().rawValue,
            "radioGroupAffiliationVisibility": "members",
            "updatedAt": FieldValue.serverTimestamp()
        ], on: userRef(uid), merge: true)

        let requestedColor = WaypointColorPreferences.ensureLocalDefaultColor()
        let batch = db.batch()
        batch.setData([
            "requestedByUid": uid,
            "requestedByName": displayName,
            "requestedVesselName": vesselName,
            "waypointPinColorID": requestedColor.rawValue,
            "status": "pending",
            "createdAt": FieldValue.serverTimestamp()
        ], forDocument: requestRef, merge: true)
        batch.setData(auditData(actorUid: uid, action: "requestJoinGroup", targetUid: uid), forDocument: groupDoc.reference.collection("auditEvents").document(), merge: true)
        try await commit(batch)

        return RadioGroupJoinResult(groupId: groupId, groupName: groupName, status: "pending")
    }

    private func localApproveJoinRequest(actorUid: String, groupId: String, requesterUid: String) async throws {
        try await requireCanApprove(uid: actorUid, groupId: groupId)
        let groupRef = db.collection("groups").document(groupId)
        let group = try await getDocument(groupRef)
        guard group.exists else { throw RadioGroupServiceError.groupNotFound }
        let groupName = (group.data()?["name"] as? String) ?? "Radio Group"
        let requestRef = groupRef.collection("joinRequests").document(requesterUid)
        let request = try await getDocument(requestRef)
        let requestData = request.data() ?? [:]
        let displayName = (requestData["requestedByName"] as? String) ?? "Member"
        let vesselName = (requestData["requestedVesselName"] as? String) ?? ""
        let requestedColor = WaypointPinColor.safe(
            rawValue: (requestData["waypointPinColorID"] as? String) ?? (requestData["defaultWaypointPinColorID"] as? String),
            fallback: WaypointPinColor.deterministicFallback(seed: requesterUid)
        )
        let membersSnapshot = try await getDocuments(groupRef.collection("members").whereField("active", isEqualTo: true))
        let usedColors = Set(membersSnapshot.documents.map { RadioGroupMember(id: $0.documentID, data: $0.data()).waypointPinColor })
        let assignedColor: WaypointPinColor
        if !usedColors.contains(requestedColor) {
            assignedColor = requestedColor
        } else if let available = WaypointPinColor.firstAvailable(excluding: usedColors) {
            assignedColor = available
        } else {
            throw RadioGroupServiceError.noWaypointPinColorsAvailable
        }

        let priorCount = try await activeMembershipCount(uid: requesterUid)
        let publicCount = max(1, priorCount + 1)
        let batch = db.batch()
        batch.setData([
            "status": "approved",
            "decidedAt": FieldValue.serverTimestamp(),
            "decidedBy": actorUid
        ], forDocument: requestRef, merge: true)
        batch.setData(memberData(
            uid: requesterUid,
            displayName: displayName,
            vesselName: vesselName,
            role: .member,
            approvedBy: actorUid,
            publicMembershipCount: publicCount,
            waypointPinColorID: assignedColor.rawValue
        ), forDocument: groupRef.collection("members").document(requesterUid), merge: true)
        batch.setData(membershipData(
            groupId: groupId,
            groupName: groupName,
            role: .member,
            approvedBy: actorUid
        ), forDocument: userRef(requesterUid).collection("memberships").document(groupId), merge: true)
        batch.setData([
            "memberCount": FieldValue.increment(Int64(1)),
            "updatedAt": FieldValue.serverTimestamp(),
            "audit.lastActionAt": FieldValue.serverTimestamp()
        ], forDocument: groupRef, merge: true)
        batch.setData(auditData(actorUid: actorUid, action: "approveJoinRequest", targetUid: requesterUid), forDocument: groupRef.collection("auditEvents").document(), merge: true)
        try await commit(batch)
        try await refreshMembershipCounts(for: requesterUid)
    }

    private func localRejectJoinRequest(actorUid: String, groupId: String, requesterUid: String) async throws {
        try await requireCanApprove(uid: actorUid, groupId: groupId)
        let groupRef = db.collection("groups").document(groupId)
        let batch = db.batch()
        batch.setData([
            "status": "rejected",
            "decidedAt": FieldValue.serverTimestamp(),
            "decidedBy": actorUid
        ], forDocument: groupRef.collection("joinRequests").document(requesterUid), merge: true)
        batch.setData(auditData(actorUid: actorUid, action: "rejectJoinRequest", targetUid: requesterUid), forDocument: groupRef.collection("auditEvents").document(), merge: true)
        try await commit(batch)
    }

    private func localLeaveGroup(uid: String, groupId: String) async throws {
        let groupRef = db.collection("groups").document(groupId)
        let batch = db.batch()
        batch.setData(["active": false, "lastSeenAt": FieldValue.serverTimestamp()], forDocument: groupRef.collection("members").document(uid), merge: true)
        batch.setData(["active": false, "lastSeenAt": FieldValue.serverTimestamp()], forDocument: userRef(uid).collection("memberships").document(groupId), merge: true)
        batch.setData([
            "memberCount": FieldValue.increment(Int64(-1)),
            "updatedAt": FieldValue.serverTimestamp(),
            "audit.lastActionAt": FieldValue.serverTimestamp()
        ], forDocument: groupRef, merge: true)
        batch.setData([
            "sharingEnabled": false,
            "expiresAt": Timestamp(date: Date()),
            "updatedAt": FieldValue.serverTimestamp()
        ], forDocument: groupRef.collection("liveLocations").document(uid), merge: true)
        batch.setData(auditData(actorUid: uid, action: "leaveGroup", targetUid: uid), forDocument: groupRef.collection("auditEvents").document(), merge: true)
        try await commit(batch)
        try await refreshMembershipCounts(for: uid)
    }

    private func localUpdateMemberProfile(uid: String, groupId: String?, firstName: String, lastName: String, vesselName: String, displayName: String) async throws {
        try await setData([
            "firstName": clean(firstName),
            "lastName": clean(lastName),
            "displayName": displayName,
            "vesselName": vesselName,
            "radioDisplayName": displayName,
            "defaultWaypointPinColorID": WaypointColorPreferences.ensureLocalDefaultColor().rawValue,
            "radioGroupAffiliationVisibility": "members",
            "updatedAt": FieldValue.serverTimestamp()
        ], on: userRef(uid), merge: true)

        let groupIds: [String]
        if let groupId, !groupId.isEmpty {
            groupIds = [groupId]
        } else {
            groupIds = try await activeMembershipIds(uid: uid)
        }

        let batch = db.batch()
        for id in groupIds {
            batch.setData([
                "displayName": displayName,
                "name": displayName,
                "vesselName": vesselName,
                "lastSeenAt": FieldValue.serverTimestamp()
            ], forDocument: db.collection("groups").document(id).collection("members").document(uid), merge: true)
        }
        try await commit(batch)
    }

    private func localUpdateWaypointPinColor(uid: String, groupId: String?, color: WaypointPinColor) async throws {
        try await WaypointColorPreferences.updateCloudDefaultColor(uid: uid, colorID: color.rawValue, db: db)

        guard let groupId, !groupId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let groupRef = db.collection("groups").document(groupId)

        let membersSnapshot = try await getDocuments(groupRef.collection("members").whereField("active", isEqualTo: true))
        let activeMembers = membersSnapshot.documents.map { RadioGroupMember(id: $0.documentID, data: $0.data()) }
        if activeMembers.contains(where: { $0.uid != uid && $0.waypointPinColor == color }) {
            throw NSError(
                domain: "RadioGroupService",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey: "That waypoint pin color is already in use by another member."]
            )
        }

        let batch = db.batch()
        batch.setData([
            "waypointPinColorID": color.rawValue,
            "colorID": color.rawValue,
            "updatedAt": FieldValue.serverTimestamp()
        ], forDocument: groupRef.collection("members").document(uid), merge: true)

        let ownerDocs = try await getDocuments(groupRef.collection("waypoints").whereField("ownerUid", isEqualTo: uid))
        let senderDocs = try await getDocuments(groupRef.collection("waypoints").whereField("senderUid", isEqualTo: uid))
        var seen: Set<String> = []
        for doc in ownerDocs.documents + senderDocs.documents where seen.insert(doc.documentID).inserted {
            batch.setData([
                "colorID": color.rawValue,
                "waypointPinColorID": color.rawValue,
                "updatedAt": FieldValue.serverTimestamp()
            ], forDocument: doc.reference, merge: true)
        }

        try await commit(batch)
    }

    private func localNormalizeMemberColors(groupId: String) async throws {
        let groupRef = db.collection("groups").document(groupId)
        let membersSnapshot = try await getDocuments(groupRef.collection("members").whereField("active", isEqualTo: true))
        let activeMembers = membersSnapshot.documents
            .map { (document: $0, member: RadioGroupMember(id: $0.documentID, data: $0.data())) }
            .sorted {
                let lhsRank = roleRank($0.member.role)
                let rhsRank = roleRank($1.member.role)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                let lhsJoined = $0.member.joinedAt ?? .distantPast
                let rhsJoined = $1.member.joinedAt ?? .distantPast
                if lhsJoined != rhsJoined { return lhsJoined < rhsJoined }
                return $0.member.uid < $1.member.uid
            }

        var used: Set<WaypointPinColor> = []
        var updates: [(DocumentReference, WaypointPinColor)] = []

        for item in activeMembers {
            let current = item.member.waypointPinColor
            let resolved: WaypointPinColor?
            if !used.contains(current) {
                resolved = current
            } else {
                let deterministic = WaypointPinColor.deterministicFallback(seed: item.member.uid)
                resolved = !used.contains(deterministic)
                    ? deterministic
                    : WaypointPinColor.firstAvailable(excluding: used)
            }

            guard let color = resolved else { continue }
            used.insert(color)
            if item.member.waypointPinColor != color {
                updates.append((item.document.reference, color))
            }
        }

        guard !updates.isEmpty else { return }
        let batch = db.batch()
        for update in updates {
            batch.setData([
                "waypointPinColorID": update.1.rawValue,
                "colorID": update.1.rawValue,
                "updatedAt": FieldValue.serverTimestamp()
            ], forDocument: update.0, merge: true)
        }
        try await commit(batch)
    }

    private func roleRank(_ role: RadioGroupRole) -> Int {
        switch role {
        case .owner: return 0
        case .admin: return 1
        case .member: return 2
        }
    }

    private func localSendPin(uid: String, groupId: String, coordinate: CLLocationCoordinate2D, displayName: String, ttlSeconds: Int) async throws {
        let now = Date()
        let colorID = try await localMemberWaypointColorID(uid: uid, groupId: groupId)
        let ref = db.collection("groups").document(groupId).collection("pins").document()
        try await setData([
            "ownerUid": uid,
            "lat": coordinate.latitude,
            "lon": coordinate.longitude,
            "displayName": clean(displayName),
            "createdAt": Timestamp(date: now),
            "updatedAt": Timestamp(date: now),
            "expiresAt": Timestamp(date: now.addingTimeInterval(TimeInterval(max(60, ttlSeconds)))),
            "source": "one_time_pin",
            "colorID": colorID,
            "waypointPinColorID": colorID
        ], on: ref, merge: true)
    }

    private func localUpsertLiveLocation(
        uid: String,
        groupId: String,
        coordinate: CLLocationCoordinate2D,
        displayName: String,
        accuracyMeters: Double?,
        course: Double?,
        speed: Double?,
        ttlSeconds: Int
    ) async throws {
        let now = Date()
        let colorID = try await localMemberWaypointColorID(uid: uid, groupId: groupId)
        var payload: [String: Any] = [
            "ownerUid": uid,
            "lat": coordinate.latitude,
            "lon": coordinate.longitude,
            "displayName": clean(displayName),
            "updatedAt": Timestamp(date: now),
            "expiresAt": Timestamp(date: now.addingTimeInterval(TimeInterval(max(60, ttlSeconds)))),
            "sharingEnabled": true,
            "colorID": colorID,
            "waypointPinColorID": colorID
        ]
        if let accuracyMeters { payload["accuracyMeters"] = accuracyMeters }
        if let course { payload["course"] = course }
        if let speed { payload["speed"] = speed }
        try await setData(payload, on: db.collection("groups").document(groupId).collection("liveLocations").document(uid), merge: true)
    }

    private func localMemberWaypointColorID(uid: String, groupId: String) async throws -> String {
        let ref = db.collection("groups").document(groupId).collection("members").document(uid)
        let snapshot = try await getDocument(ref)
        let data = snapshot.data() ?? [:]
        return WaypointPinColor.safe(
            rawValue: (data["waypointPinColorID"] as? String)
                ?? (data["colorID"] as? String)
                ?? (data["defaultWaypointPinColorID"] as? String),
            fallback: WaypointPinColor.deterministicFallback(seed: uid)
        ).rawValue
    }

    private func localStopLiveLocation(uid: String, groupId: String) async throws {
        try await setData([
            "ownerUid": uid,
            "sharingEnabled": false,
            "updatedAt": FieldValue.serverTimestamp(),
            "expiresAt": Timestamp(date: Date())
        ], on: db.collection("groups").document(groupId).collection("liveLocations").document(uid), merge: true)
    }

    private func localDeleteLastPin(uid: String, groupId: String) async throws {
        let snapshot = try await getDocuments(
            db.collection("groups").document(groupId).collection("pins")
                .whereField("ownerUid", isEqualTo: uid)
                .order(by: "createdAt", descending: true)
                .limit(to: 1)
        )
        guard let doc = snapshot.documents.first else { return }
        try await setData(["deletedAt": FieldValue.serverTimestamp(), "updatedAt": FieldValue.serverTimestamp()], on: doc.reference, merge: true)
    }

    private func localDeleteAllPins(uid: String, groupId: String) async throws {
        let snapshot = try await getDocuments(
            db.collection("groups").document(groupId).collection("pins")
                .whereField("ownerUid", isEqualTo: uid)
        )
        let batch = db.batch()
        for doc in snapshot.documents {
            batch.setData(["deletedAt": FieldValue.serverTimestamp(), "updatedAt": FieldValue.serverTimestamp()], forDocument: doc.reference, merge: true)
        }
        try await commit(batch)
    }

    private func localSendWaypoint(uid: String, groupId: String, waypoint: Waypoint, senderName: String, forceNewDoc: Bool) async throws {
        let now = Date()
        let docId = forceNewDoc ? UUID().uuidString : waypoint.id.uuidString
        try await setData([
            "ownerUid": uid,
            "senderName": clean(senderName),
            "name": clean(waypoint.name),
            "notes": clean(waypoint.notes, maxLength: 1200),
            "lat": waypoint.coordinate.latitude,
            "lon": waypoint.coordinate.longitude,
            "createdAt": Timestamp(date: waypoint.createdAt),
            "sentAt": Timestamp(date: now),
            "expiresAt": Timestamp(date: now.addingTimeInterval(14 * 24 * 60 * 60)),
            "originalWaypointId": waypoint.id.uuidString,
            "senderUid": uid,
            "colorID": waypoint.pinColor.rawValue,
            "waypointPinColorID": waypoint.pinColor.rawValue
        ], on: db.collection("groups").document(groupId).collection("waypoints").document(docId), merge: true)
    }

    private func refreshMembershipCounts(for uid: String) async throws {
        let memberships = try await activeMembershipIds(uid: uid)
        let count = memberships.count
        try await setData([
            "radioGroupMembershipCount": count,
            "radioGroupAffiliationVisibility": "members",
            "updatedAt": FieldValue.serverTimestamp()
        ], on: userRef(uid), merge: true)

        let batch = db.batch()
        for groupId in memberships {
            batch.setData(["publicMembershipCount": count], forDocument: db.collection("groups").document(groupId).collection("members").document(uid), merge: true)
        }
        try await commit(batch)
    }

    private func activeMembershipIds(uid: String) async throws -> [String] {
        let snapshot = try await getDocuments(userRef(uid).collection("memberships"))
        return snapshot.documents.compactMap { doc in
            let membership = RadioGroupMembership(id: doc.documentID, data: doc.data())
            return membership.active ? membership.groupId : nil
        }
    }

    private func activeMembershipCount(uid: String) async throws -> Int {
        try await activeMembershipIds(uid: uid).count
    }

    private func requireCanInvite(uid: String, groupId: String) async throws {
        let member = try await getDocument(db.collection("groups").document(groupId).collection("members").document(uid))
        let data = member.data() ?? [:]
        let parsed = RadioGroupMember(id: uid, data: data)
        guard parsed.active, parsed.canInvite || parsed.role.canApprove else {
            throw RadioGroupServiceError.groupNotFound
        }
    }

    private func requireCanApprove(uid: String, groupId: String) async throws {
        let member = try await getDocument(db.collection("groups").document(groupId).collection("members").document(uid))
        let data = member.data() ?? [:]
        let parsed = RadioGroupMember(id: uid, data: data)
        guard parsed.active, parsed.canApprove || parsed.role.canApprove else {
            throw RadioGroupServiceError.groupNotFound
        }
    }

    private func profilePayload(firstName: String, lastName: String, vesselName: String, displayName: String) -> [String: Any] {
        [
            "firstName": clean(firstName),
            "lastName": clean(lastName),
            "vesselName": clean(vesselName),
            "radioDisplayName": displayName,
            "defaultWaypointPinColorID": WaypointColorPreferences.ensureLocalDefaultColor().rawValue,
            "radioGroupAffiliationVisibility": "members"
        ]
    }

    private func memberDisplayLabel(firstName: String, lastName: String, vesselName: String, displayName: String) -> String {
        let callsign = clean(defaults.string(forKey: "callsign") ?? defaults.string(forKey: "callSign") ?? "")
        if !callsign.isEmpty { return callsign }

        let vessel = clean(vesselName)
        if !vessel.isEmpty { return vessel }

        let radioName = clean(defaults.string(forKey: LocalKey.radioDisplayName) ?? "")
        if !radioName.isEmpty { return radioName }

        let fullName = [clean(firstName), clean(lastName)].filter { !$0.isEmpty }.joined(separator: " ")
        if !fullName.isEmpty { return fullName }

        let display = clean(displayName)
        return display.isEmpty ? "Member" : display
    }

    private func displayName(firstName: String, lastName: String, fallback user: User) -> String {
        let joined = [clean(firstName), clean(lastName)].filter { !$0.isEmpty }.joined(separator: " ")
        if !joined.isEmpty { return joined }
        if let displayName = user.displayName, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return displayName
        }
        let local = clean(defaults.string(forKey: LocalKey.radioDisplayName) ?? "")
        if !local.isEmpty { return local }
        return user.email?.components(separatedBy: "@").first ?? "Member"
    }

    private func clean(_ value: String, maxLength: Int = 160) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
    }

    private func validate(_ coordinate: CLLocationCoordinate2D) throws {
        guard RadioGroupRecordParser.isValid(coordinate) else {
            throw RadioGroupServiceError.invalidCoordinate
        }
    }

    private static func generateInviteCode() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<8).compactMap { _ in chars.randomElement() })
    }

    private static func hashInviteCode(_ code: String) -> String {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func date(from value: Any?) -> Date? {
        if let timestamp = value as? Timestamp { return timestamp.dateValue() }
        if let seconds = value as? TimeInterval { return Date(timeIntervalSince1970: seconds) }
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        if let date = value as? Date { return date }
        return nil
    }

    private func userRef(_ uid: String) -> DocumentReference {
        db.collection("users").document(uid)
    }

    private func memberData(
        uid: String,
        displayName: String,
        vesselName: String,
        role: RadioGroupRole,
        approvedBy: String,
        publicMembershipCount: Int,
        waypointPinColorID: String
    ) -> [String: Any] {
        [
            "uid": uid,
            "displayName": displayName,
            "name": displayName,
            "vesselName": vesselName,
            "waypointPinColorID": WaypointPinColor.safe(rawValue: waypointPinColorID).rawValue,
            "role": role.rawValue,
            "active": true,
            "joinedAt": FieldValue.serverTimestamp(),
            "approvedBy": approvedBy,
            "canShareLocation": true,
            "canInvite": role.canApprove,
            "canApprove": role.canApprove,
            "publicMembershipCount": publicMembershipCount,
            "lastSeenAt": FieldValue.serverTimestamp()
        ]
    }

    private func membershipData(groupId: String, groupName: String, role: RadioGroupRole, approvedBy: String) -> [String: Any] {
        [
            "groupId": groupId,
            "groupName": groupName,
            "role": role.rawValue,
            "active": true,
            "joinedAt": FieldValue.serverTimestamp(),
            "approvedBy": approvedBy,
            "lastSeenAt": FieldValue.serverTimestamp()
        ]
    }

    private func auditData(actorUid: String, action: String, targetUid: String? = nil, metadata: [String: Any] = [:]) -> [String: Any] {
        var data: [String: Any] = [
            "actorUid": actorUid,
            "action": action,
            "createdAt": FieldValue.serverTimestamp(),
            "metadata": metadata
        ]
        if let targetUid { data["targetUid"] = targetUid }
        return data
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

    private func getDocument(_ ref: DocumentReference) async throws -> DocumentSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            ref.getDocument { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let snapshot else {
                    continuation.resume(throwing: RadioGroupServiceError.groupNotFound)
                    return
                }
                continuation.resume(returning: snapshot)
            }
        }
    }

    private func getDocuments(_ query: Query) async throws -> QuerySnapshot {
        try await withCheckedThrowingContinuation { continuation in
            query.getDocuments { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let snapshot else {
                    continuation.resume(throwing: RadioGroupServiceError.groupNotFound)
                    return
                }
                continuation.resume(returning: snapshot)
            }
        }
    }

    private func commit(_ batch: WriteBatch) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            batch.commit { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            }
        }
    }
}
