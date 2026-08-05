import Foundation
import CoreLocation
import Combine
import UIKit
import FirebaseAuth
import FirebaseFirestore

/// Firestore-backed shared Radio Group state (pins + live sharing state).
/// - One-time pins are stored under: groups/{groupId}/pins/{pinId}
/// - Live locations are stored under: groups/{groupId}/liveLocations/{uid}
/// - Active groupId is stored in UserDefaults key: "radioGroupId"
@MainActor
final class RadioGroupStore: ObservableObject {

    // MARK: - Public state consumed by SwiftUI

    @Published var isLiveSharing: Bool = false
    @Published var lastLiveLocationSentAt: Date? = nil
    @Published var activeGroupID: String? = nil
    @Published var activeGroupName: String = ""
    @Published var lastErrorMessage: String? = nil
    @Published var pins: [Pin] = []
    /// True only when the active group has at least 2 members (including this user).
    @Published var canShareLocation: Bool = false
    // Waypoints shared to the active group (received from other members).
    @Published var receivedWaypoints: [GroupWaypoint] = []
    @Published var activeMembers: [RadioGroupMember] = []
    /// Locally-hidden received waypoint ids (per active group). Used for "Delete received" without deleting for the whole group.
    @Published private(set) var hiddenReceivedWaypointIDs: Set<String> = []

    // MARK: - Local cache (Application Support)

    private struct CachedGroupWaypoint: Codable, Identifiable, Hashable {
        let id: String
        var name: String
        var notes: String
        var lat: Double
        var lon: Double
        var createdAt: Date
        var sentAt: Date
        var senderUid: String
        var senderName: String
        var colorID: String?
    }

    private func appSupportDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SatChart", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        return dir
    }

    private func receivedWaypointsFileURL(groupId: String) -> URL {
        appSupportDir().appendingPathComponent("received_waypoints_\(groupId).json")
    }

    private func saveCachedReceivedWaypoints(_ items: [GroupWaypoint], groupId: String) {
        let cached: [CachedGroupWaypoint] = items.map {
            CachedGroupWaypoint(
                id: $0.id,
                name: $0.name,
                notes: $0.notes,
                lat: $0.coordinate.latitude,
                lon: $0.coordinate.longitude,
                createdAt: $0.createdAt,
                sentAt: $0.sentAt,
                senderUid: $0.senderUid,
                senderName: $0.senderName,
                colorID: $0.colorID
            )
        }

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601

        let url = receivedWaypointsFileURL(groupId: groupId)
        if let data = try? enc.encode(cached) {
            try? data.write(to: url, options: [.atomic])
        }
    }
    private func hiddenReceivedWaypointsFileURL(groupId: String) -> URL {
        appSupportDir().appendingPathComponent("hidden_received_waypoints_\(groupId).json")
    }

    private func saveHiddenReceivedWaypointIDs(_ ids: Set<String>, groupId: String) {
        let url = hiddenReceivedWaypointsFileURL(groupId: groupId)
        let enc = JSONEncoder()
        if let data = try? enc.encode(Array(ids)) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private func loadHiddenReceivedWaypointIDs(groupId: String) -> Set<String> {
        let url = hiddenReceivedWaypointsFileURL(groupId: groupId)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        if let arr = try? dec.decode([String].self, from: data) {
            return Set(arr)
        }
        return []
    }
    private func loadCachedReceivedWaypoints(groupId: String) -> [GroupWaypoint] {
        let url = receivedWaypointsFileURL(groupId: groupId)
        guard let data = try? Data(contentsOf: url) else { return [] }

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601

        guard let cached = try? dec.decode([CachedGroupWaypoint].self, from: data) else {
            return []
        }

        return cached.map {
            GroupWaypoint(
                id: $0.id,
                name: $0.name,
                notes: $0.notes,
                coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon),
                createdAt: $0.createdAt,
                sentAt: $0.sentAt,
                senderUid: $0.senderUid,
                senderName: $0.senderName,
                colorID: $0.colorID ?? WaypointPinColor.deterministicFallback(seed: $0.senderUid).rawValue
            )
        }
    }

    struct GroupWaypoint: Identifiable, Hashable {
        let id: String                 // Firestore doc id
        var name: String
        var notes: String
        var coordinate: CLLocationCoordinate2D
        var createdAt: Date
        var sentAt: Date
        var senderUid: String
        var senderName: String
        var colorID: String

        var pinColor: WaypointPinColor {
            WaypointPinColor.safe(rawValue: colorID, fallback: WaypointPinColor.deterministicFallback(seed: senderUid))
        }

        // We treat Firestore doc id as the identity. This avoids Hashable/Equatable issues
        // with CLLocationCoordinate2D (which is not Hashable/Equatable).
        static func == (lhs: GroupWaypoint, rhs: GroupWaypoint) -> Bool {
            lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    // MARK: - Types

    struct Pin: Identifiable {
        /// Firestore document id (stable across updates)
        let id: String
        var coordinate: CLLocationCoordinate2D
        /// Used for fading; for live pins this is set to last-updated time.
        var createdAt: Date
        var displayName: String
        var isLive: Bool
        var ownerUid: String
        var updatedAt: Date
        var colorID: String

        var pinColor: WaypointPinColor {
            WaypointPinColor.safe(rawValue: colorID, fallback: WaypointPinColor.deterministicFallback(seed: ownerUid))
        }
    }

    // MARK: - Private

    private let db = Firestore.firestore()
    private let repository = RadioGroupRepository()
    private let service = RadioGroupService()
    private var pinsListener: ListenerRegistration?
    private var liveLocationsListener: ListenerRegistration?
    private var membersListener: ListenerRegistration?
    private var waypointsListener: ListenerRegistration?
    private var activeGroupListener: ListenerRegistration?
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var defaultsObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private let groupIdDefaultsKey = "radioGroupId"
    private var oneTimePins: [Pin] = []
    private var liveLocationPins: [Pin] = []
    private var optimisticLiveLocationPin: Pin?
    private var liveSharingGroupIDSnapshot: String?
    private var activeGroupAllowsLiveLocation: Bool = false

    private var currentGroupId: String? {
        let g = (UserDefaults.standard.string(forKey: groupIdDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return g.isEmpty ? nil : g
    }

    private func debugLiveShareLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[LiveShare][Store] \(message())")
        #endif
    }

    private func refreshActiveGroupID() {
        let gid = currentGroupId
        if activeGroupID != gid {
            if isLiveSharing {
                debugLiveShareLog("active group changed from \(activeGroupID ?? "nil") to \(gid ?? "nil"); stopping live sharing")
                stopLiveSharing()
            }
            activeGroupID = gid
            activeGroupName = ""
            activeMembers = []
            activeGroupAllowsLiveLocation = false
            canShareLocation = false
        }
    }

    private func recomputeCanShareLocation() {
        guard let user = Auth.auth().currentUser,
              !user.isAnonymous,
              let currentMember = activeMembers.first(where: { $0.uid == user.uid }) else {
            canShareLocation = false
            if isLiveSharing {
                debugLiveShareLog("current user is no longer an active share-capable member; stopping live sharing")
                stopLiveSharing()
            }
            return
        }

        let nextValue = activeGroupAllowsLiveLocation
            && currentMember.canShareLocation
            && activeMembers.count >= 2
        canShareLocation = nextValue

        if !nextValue, isLiveSharing {
            debugLiveShareLog("group live-location permission/member count no longer permits sharing; stopping live sharing")
            stopLiveSharing()
        }
    }

    private var uid: String? {
        guard let user = Auth.auth().currentUser, !user.isAnonymous else { return nil }
        return user.uid
    }

    var currentUserID: String? {
        Auth.auth().currentUser?.uid
    }

    // MARK: - Init / Deinit

    init() {
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshActiveGroupID()
                if self.uid == nil {
                    self.debugLiveShareLog("auth state has no signed-in non-anonymous user; stopping live sharing")
                    self.stopLiveSharing()
                    self.clearListenersAndState()
                }
                self.ensureDefaultWaypointColorAssigned()
                self.startPinsListener()
                self.startMembersListener()
                self.startWaypointsListener()
                self.startActiveGroupListener()
            }
        }

        refreshActiveGroupID()
        startPinsListener()
        startMembersListener()
        startWaypointsListener()
        startActiveGroupListener()
        ensureDefaultWaypointColorAssigned()

        // Restart listeners when group selection changes.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshActiveGroupID()
                self?.startPinsListener()
                self?.startMembersListener()
                self?.startWaypointsListener()
                self?.startActiveGroupListener()
            }
        }

        // MapView owns foreground live-share timers and resume prompts. The store
        // intentionally does not remote-stop live sharing on app background.
    }

    deinit {
        pinsListener?.remove()
        pinsListener = nil

        liveLocationsListener?.remove()
        liveLocationsListener = nil

        membersListener?.remove()
        membersListener = nil

        waypointsListener?.remove()
        waypointsListener = nil

        activeGroupListener?.remove()
        activeGroupListener = nil

        if let authHandle {
            Auth.auth().removeStateDidChangeListener(authHandle)
        }
        authHandle = nil

        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        defaultsObserver = nil

        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
    }

    // MARK: - Public API

    private func liveSharingGroupID() throws -> String {
        refreshActiveGroupID()

        guard let gid = currentGroupId else {
            throw RadioGroupServiceError.missingActiveGroup
        }

        guard let authUid = Auth.auth().currentUser?.uid,
              Auth.auth().currentUser?.isAnonymous == false else {
            throw RadioGroupServiceError.signInRequired
        }

        let isActiveMember = activeMembers.contains { $0.uid == authUid }
        guard canShareLocation, isActiveMember else {
            throw RadioGroupServiceError.locationSharingUnavailable
        }

        return gid
    }

    private func liveSharingUserID() throws -> String {
        guard let authUid = Auth.auth().currentUser?.uid,
              Auth.auth().currentUser?.isAnonymous == false else {
            throw RadioGroupServiceError.signInRequired
        }
        return authUid
    }

    func setGroupId(_ groupId: String) {
        UserDefaults.standard.set(groupId, forKey: groupIdDefaultsKey)
        refreshActiveGroupID()
        startPinsListener()
        startMembersListener()
        startWaypointsListener()
        startActiveGroupListener()
    }

    func ensureDefaultWaypointColorAssigned() {
        guard let authUid = Auth.auth().currentUser?.uid else {
            _ = WaypointColorPreferences.ensureLocalDefaultColor()
            return
        }

        Task {
            do {
                _ = try await WaypointColorPreferences.ensureCloudDefaultColor(uid: authUid, db: db)
            } catch {
                _ = WaypointColorPreferences.ensureLocalDefaultColor()
                #if DEBUG
                print("Waypoint default color ensure failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    func colorUsedByOtherActiveMember(_ color: WaypointPinColor) -> RadioGroupMember? {
        guard let myUid = currentUserID else { return nil }
        return activeMembers.first { member in
            member.uid != myUid && member.waypointPinColor == color
        }
    }

    func updateWaypointPinColorForCurrentUser(colorID: String, completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard let authUid = Auth.auth().currentUser?.uid else {
            let color = WaypointPinColor.safe(rawValue: colorID)
            WaypointColorPreferences.mirrorToLocal(color)
            completion?(.success(()))
            return
        }

        let color = WaypointPinColor.safe(rawValue: colorID)
        WaypointColorPreferences.mirrorToLocal(color)

        Task {
            do {
                try await updateWaypointPinColor(uid: authUid, color: color)
                await MainActor.run {
                    completion?(.success(()))
                }
            } catch {
                await MainActor.run {
                    self.lastErrorMessage = RadioGroupService.friendlyMessage(for: error)
                    completion?(.failure(error))
                }
            }
        }
    }

    @discardableResult
    func markLiveShared() -> Result<Void, Error> {
        do {
            let gid = try liveSharingGroupID()
            debugLiveShareLog("marking live sharing active for group=\(gid)")
            isLiveSharing = true
            lastLiveLocationSentAt = Date()
            liveSharingGroupIDSnapshot = gid
            return .success(())
        } catch {
            debugLiveShareLog("mark live sharing active failed: \(error.localizedDescription)")
            isLiveSharing = false
            liveSharingGroupIDSnapshot = nil
            lastErrorMessage = RadioGroupService.friendlyMessage(for: error)
            return .failure(error)
        }
    }

    func pauseLiveSharingLocally() {
        debugLiveShareLog("pausing live sharing locally without remote stop")
        isLiveSharing = false
        liveSharingGroupIDSnapshot = nil
        optimisticLiveLocationPin = nil
        publishPins()
    }

    /// Hide a received waypoint locally (does not delete from Firestore; only hides on this device).
    func hideReceivedWaypoint(id: String) {
        guard let gid = currentGroupId else { return }
        hiddenReceivedWaypointIDs.insert(id)
        saveHiddenReceivedWaypointIDs(hiddenReceivedWaypointIDs, groupId: gid)
        receivedWaypoints.removeAll { $0.id == id }
        // Also update the cache so hidden waypoints don't reappear from cache
        if let gid = currentGroupId {
            saveCachedReceivedWaypoints(receivedWaypoints, groupId: gid)
        }
    }

    /// Hide ALL received waypoints locally for the active group.
    func hideAllReceivedWaypoints() {
        guard let gid = currentGroupId else { return }
        for wp in receivedWaypoints { hiddenReceivedWaypointIDs.insert(wp.id) }
        saveHiddenReceivedWaypointIDs(hiddenReceivedWaypointIDs, groupId: gid)
        receivedWaypoints.removeAll()
        // Also update the cache so hidden waypoints don't reappear from cache
        if let gid = currentGroupId {
            saveCachedReceivedWaypoints([], groupId: gid)
        }
    }

    func stopLiveSharing() {
        let shouldStopRemote = isLiveSharing || liveSharingGroupIDSnapshot != nil
        isLiveSharing = false
        let stoppedGroupID = liveSharingGroupIDSnapshot ?? currentGroupId
        liveSharingGroupIDSnapshot = nil
        optimisticLiveLocationPin = nil
        publishPins()
        debugLiveShareLog("stopping live sharing; remoteStop=\(shouldStopRemote), group=\(stoppedGroupID ?? "nil")")
        guard shouldStopRemote, let gid = stoppedGroupID, uid != nil else { return }
        Task {
            do {
                try await service.stopLiveLocation(groupId: gid)
            } catch {
                await MainActor.run {
                    self.lastErrorMessage = RadioGroupService.friendlyMessage(for: error)
                }
            }
        }
    }

    /// Share a one-time pin (creates a new doc).
    func sendPin(_ coord: CLLocationCoordinate2D, displayName: String) async -> Result<Void, Error> {
        do {
            let gid = try await MainActor.run {
                try self.liveSharingGroupID()
            }
            try await service.sendPin(
                groupId: gid,
                coordinate: coord,
                displayName: displayName,
                ttlSeconds: 6 * 60 * 60
            )
            await MainActor.run {
                self.lastLiveLocationSentAt = Date()
            }
            return .success(())
        } catch {
            await MainActor.run {
                self.lastErrorMessage = RadioGroupService.friendlyMessage(for: error)
            }
            #if DEBUG
            print("Radio Group send pin failed: \(error.localizedDescription)")
            #endif
            return .failure(error)
        }
    }

    /// Share/update live pin (one stable doc per user, doc id = uid).
    func upsertLivePin(_ coord: CLLocationCoordinate2D, displayName: String) async -> Result<Void, Error> {
        do {
            let (gid, ownerUid) = try await MainActor.run {
                (try self.liveSharingGroupID(), try self.liveSharingUserID())
            }
            try await service.upsertLiveLocation(
                groupId: gid,
                coordinate: coord,
                displayName: displayName,
                ttlSeconds: Int(LiveLocationSessionState.hideStalePinAfter)
            )
            await MainActor.run {
                let sentAt = Date()
                self.isLiveSharing = true
                self.lastLiveLocationSentAt = sentAt
                self.liveSharingGroupIDSnapshot = gid
                self.optimisticLiveLocationPin = Pin(
                    id: ownerUid,
                    coordinate: coord,
                    createdAt: sentAt,
                    displayName: displayName,
                    isLive: true,
                    ownerUid: ownerUid,
                    updatedAt: sentAt,
                    colorID: self.pinColorID(for: ownerUid, recordColorID: nil)
                )
                self.publishPins()
            }
            return .success(())
        } catch {
            await MainActor.run {
                self.isLiveSharing = false
                self.liveSharingGroupIDSnapshot = nil
                self.optimisticLiveLocationPin = nil
                self.publishPins()
                self.lastErrorMessage = RadioGroupService.friendlyMessage(for: error)
                self.debugLiveShareLog("live location upsert failed: \(error.localizedDescription)")
            }
            #if DEBUG
            print("Radio Group live location upsert failed: \(error.localizedDescription)")
            #endif
            return .failure(error)
        }
    }

    /// Deletes the most recent *non-live* pin owned by THIS user.
    func deleteLastPin() {
        guard let gid = currentGroupId else { return }
        Task {
            do {
                try await service.deleteLastPin(groupId: gid)
            } catch {
                await MainActor.run {
                    self.lastErrorMessage = RadioGroupService.friendlyMessage(for: error)
                }
            }
        }
    }

    /// Deletes ALL one-time pins owned by THIS user and clears live sharing state.
    func deleteAllPins() {
        guard let gid = currentGroupId else { return }
        debugLiveShareLog("delete all pins requested; clearing live sharing state")
        isLiveSharing = false
        lastLiveLocationSentAt = nil
        liveSharingGroupIDSnapshot = nil
        optimisticLiveLocationPin = nil
        publishPins()
        Task {
            do {
                try await service.deleteAllPins(groupId: gid)
                try await service.stopLiveLocation(groupId: gid)
            } catch {
                await MainActor.run {
                    self.lastErrorMessage = RadioGroupService.friendlyMessage(for: error)
                }
            }
        }
    }

    func deleteExpiredOwnPins(expiry: PinExpiryOption, now: Date = Date()) {
        guard let ttl = expiry.ttlSeconds,
              let gid = currentGroupId,
              let currentUserID
        else {
            return
        }

        let expired = pins.filter { pin in
            !pin.isLive &&
            pin.ownerUid == currentUserID &&
            now.timeIntervalSince(pin.createdAt) >= ttl
        }
        guard !expired.isEmpty else { return }

        Task {
            do {
                let batch = db.batch()
                let groupRef = db.collection("groups").document(gid)
                for pin in expired {
                    batch.setData([
                        "deletedAt": FieldValue.serverTimestamp(),
                        "updatedAt": FieldValue.serverTimestamp()
                    ], forDocument: groupRef.collection("pins").document(pin.id), merge: true)
                }
                try await commit(batch)
            } catch {
                #if DEBUG
                print("Expired Radio Group pin cleanup failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// Shares a waypoint with the active Radio Group (writes to groups/{groupId}/waypoints/{docId}).
    /// Default behavior remains private: local waypoints stay local unless explicitly sent.
    /// - If `forceNewDoc` is true, a NEW Firestore document is created (so receivers who previously hid the old docId
    ///   will still see this re-share as a new item).
    func sendWaypointToActiveGroup(_ wp: Waypoint, forceNewDoc: Bool = false) {
        guard let gid = currentGroupId else { return }

        guard uid != nil else {
            lastErrorMessage = RadioGroupServiceError.signInRequired.localizedDescription
            return
        }

        let senderNameRaw = (UserDefaults.standard.string(forKey: "radioPinDisplayName") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let senderName = senderNameRaw.isEmpty ? "Member" : senderNameRaw

        Task {
            do {
                try await service.sendWaypoint(groupId: gid, waypoint: wp, senderName: senderName, forceNewDoc: forceNewDoc)
            } catch {
                await MainActor.run {
                    self.lastErrorMessage = RadioGroupService.friendlyMessage(for: error)
                }
            }
        }
    }
    var lastSentText: String {
        guard let d = lastLiveLocationSentAt else { return "—" }
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: d)
    }

    // MARK: - Firestore plumbing

    private func startWaypointsListener() {
        guard let myUid = uid else { return }

        // If no group selected, stop listening but keep last-known received waypoints.
        // (Prevents UI/map from “blinking” when radioGroupId is briefly empty during transitions.)
        guard let gid = currentGroupId else {
            waypointsListener?.remove()
            waypointsListener = nil
            return
        }

        // Load hidden IDs first (so both cache + live snapshots can filter).
        let hidden = loadHiddenReceivedWaypointIDs(groupId: gid)

        // Apply hidden IDs immediately (used by both cache + live snapshots).
        DispatchQueue.main.async {
            self.hiddenReceivedWaypointIDs = hidden
        }

        // Load cached received waypoints immediately so map doesn't blink.
        let cachedAll = loadCachedReceivedWaypoints(groupId: gid)
        let cachedVisible = cachedAll.filter { !hidden.contains($0.id) }
        if !cachedVisible.isEmpty {
            DispatchQueue.main.async {
                self.receivedWaypoints = cachedVisible
            }
        }

        waypointsListener?.remove()
        waypointsListener = repository.listenWaypoints(groupId: gid) { [weak self] records in
            guard let self else { return }
            guard self.currentGroupId == gid else { return }
            // Always use the latest hidden set (it can change while this listener is active).
            let hiddenNow = self.hiddenReceivedWaypointIDs
            var memberColorByUid: [String: String] = [:]
            memberColorByUid.reserveCapacity(self.activeMembers.count)
            for member in self.activeMembers {
                let memberUid = member.uid.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !memberUid.isEmpty else { continue }
                memberColorByUid[memberUid] = member.waypointPinColorID
            }

            var out: [GroupWaypoint] = []
            out.reserveCapacity(records.count)

            for record in records {
                let senderUidTrim = record.ownerUid.trimmingCharacters(in: .whitespacesAndNewlines)
                let senderUid = senderUidTrim.isEmpty ? "unknown-\(record.id)" : senderUidTrim
                // Received = other members only
                if senderUid == myUid { continue }

                // Respect local hide list (do not delete from Firestore)
                if hiddenNow.contains(record.id) { continue }

                let senderNameTrim = record.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
                let senderName = senderNameTrim.isEmpty ? "Member \(senderUid.prefix(6))" : senderNameTrim
                let colorID = WaypointPinColor.safe(
                    rawValue: record.colorID.isEmpty ? memberColorByUid[senderUid] : record.colorID,
                    fallback: WaypointPinColor.deterministicFallback(seed: senderUid)
                ).rawValue

                out.append(
                    GroupWaypoint(
                        id: record.id,
                        name: record.name,
                        notes: record.notes,
                        coordinate: record.coordinate,
                        createdAt: record.createdAt,
                        sentAt: record.sentAt,
                        senderUid: senderUid,
                        senderName: senderName,
                        colorID: colorID
                    )
                )
            }

            out.sort { $0.sentAt > $1.sentAt }

            // Persist to Application Support so the map can restore even if listener restarts.
            self.saveCachedReceivedWaypoints(out, groupId: gid)

            DispatchQueue.main.async {
                self.receivedWaypoints = out
            }
        }
    }

    private func startMembersListener() {
        guard let gid = currentGroupId else {
            membersListener?.remove()
            membersListener = nil
            DispatchQueue.main.async {
                self.canShareLocation = false
                self.activeMembers = []
            }
            return
        }

        membersListener?.remove()
        membersListener = repository.listenMembers(groupId: gid) { [weak self] members in
                guard let self else { return }
                guard self.currentGroupId == gid else { return }
                self.activeMembers = members
                self.recomputeCanShareLocation()
                self.ensureMemberColorsIfNeeded(members: members, groupId: gid)
        }
    }

    private func startPinsListener() {
        guard uid != nil else {
            pinsListener?.remove()
            pinsListener = nil
            liveLocationsListener?.remove()
            liveLocationsListener = nil
            oneTimePins = []
            liveLocationPins = []
            DispatchQueue.main.async { self.pins = [] }
            return
        }

        // If no group selected, clear pins and stop listening
        guard let gid = currentGroupId else {
            pinsListener?.remove()
            pinsListener = nil
            liveLocationsListener?.remove()
            liveLocationsListener = nil
            oneTimePins = []
            liveLocationPins = []
            DispatchQueue.main.async { self.pins = [] }
            return
        }

        pinsListener?.remove()
        pinsListener = repository.listenPins(groupId: gid) { [weak self] records in
            guard let self else { return }
            guard self.currentGroupId == gid else { return }
            self.oneTimePins = records.map {
                Pin(
                    id: $0.id,
                    coordinate: $0.coordinate,
                    createdAt: $0.createdAt,
                    displayName: $0.displayName,
                    isLive: false,
                    ownerUid: $0.ownerUid,
                    updatedAt: $0.updatedAt,
                    colorID: self.pinColorID(for: $0.ownerUid, recordColorID: $0.colorID)
                )
            }
            self.publishPins()
        }

        liveLocationsListener?.remove()
        liveLocationsListener = repository.listenLiveLocations(groupId: gid) { [weak self] records in
            guard let self else { return }
            guard self.currentGroupId == gid else { return }
            self.liveLocationPins = records.map {
                Pin(
                    id: $0.id,
                    coordinate: $0.coordinate,
                    createdAt: $0.updatedAt,
                    displayName: $0.displayName,
                    isLive: true,
                    ownerUid: $0.ownerUid,
                    updatedAt: $0.updatedAt,
                    colorID: self.pinColorID(for: $0.ownerUid, recordColorID: $0.colorID)
                )
            }
            self.publishPins()
        } onError: { [weak self] error in
            guard let self else { return }
            guard self.currentGroupId == gid else { return }
            self.lastErrorMessage = RadioGroupService.friendlyMessage(for: error)
            #if DEBUG
            print("[LiveShare][Store] live location listener failed for group=\(gid): \(error.localizedDescription)")
            #endif
        }
    }

    private func startActiveGroupListener() {
        guard let gid = currentGroupId else {
            activeGroupListener?.remove()
            activeGroupListener = nil
            activeGroupName = ""
            activeGroupAllowsLiveLocation = false
            recomputeCanShareLocation()
            return
        }

        activeGroupListener?.remove()
        activeGroupListener = repository.listenGroup(groupId: gid) { [weak self] group in
            guard let self else { return }
            guard self.currentGroupId == gid else { return }
            guard let group else {
                self.activeGroupName = ""
                self.activeMembers = []
                self.activeGroupAllowsLiveLocation = false
                self.recomputeCanShareLocation()
                return
            }
            self.activeGroupName = group.name
            self.activeGroupAllowsLiveLocation = group.settings.allowLiveLocation
            self.recomputeCanShareLocation()
        }
    }

    private func publishPins() {
        var livePinsByID: [String: Pin] = [:]
        livePinsByID.reserveCapacity(liveLocationPins.count + (optimisticLiveLocationPin == nil ? 0 : 1))
        for pin in liveLocationPins {
            let pinID = pin.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = pinID.isEmpty ? pin.ownerUid.trimmingCharacters(in: .whitespacesAndNewlines) : pinID
            guard !key.isEmpty else { continue }
            if let existing = livePinsByID[key] {
                if pin.updatedAt >= existing.updatedAt {
                    livePinsByID[key] = pin
                }
            } else {
                livePinsByID[key] = pin
            }
        }
        if let optimisticLiveLocationPin {
            let optimisticID = optimisticLiveLocationPin.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let optimisticKey = optimisticID.isEmpty ? optimisticLiveLocationPin.ownerUid.trimmingCharacters(in: .whitespacesAndNewlines) : optimisticID
            if !optimisticKey.isEmpty {
                if let existing = livePinsByID[optimisticKey] {
                    if optimisticLiveLocationPin.updatedAt >= existing.updatedAt {
                        livePinsByID[optimisticKey] = optimisticLiveLocationPin
                    }
                } else {
                    livePinsByID[optimisticKey] = optimisticLiveLocationPin
                }
            }
        }

        pins = (oneTimePins + Array(livePinsByID.values))
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func pinColorID(for ownerUid: String, recordColorID: String?) -> String {
        let rawRecordColor = recordColorID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let color = WaypointPinColor(rawValue: rawRecordColor) {
            return color.rawValue
        }

        let uid = ownerUid.trimmingCharacters(in: .whitespacesAndNewlines)
        if let member = activeMembers.first(where: { $0.uid == uid }) {
            return member.waypointPinColorID
        }

        return ""
    }

    private func clearListenersAndState() {
        pinsListener?.remove()
        pinsListener = nil
        liveLocationsListener?.remove()
        liveLocationsListener = nil
        membersListener?.remove()
        membersListener = nil
        waypointsListener?.remove()
        waypointsListener = nil
        activeGroupListener?.remove()
        activeGroupListener = nil

        pins = []
        oneTimePins = []
        liveLocationPins = []
        receivedWaypoints = []
        activeMembers = []
        activeGroupAllowsLiveLocation = false
        liveSharingGroupIDSnapshot = nil
        optimisticLiveLocationPin = nil
        canShareLocation = false
        activeGroupID = nil
        activeGroupName = ""
    }

    private func ensureMemberColorsIfNeeded(members: [RadioGroupMember], groupId: String) {
        guard !members.isEmpty else { return }

        var used: Set<WaypointPinColor> = []
        var needsNormalization = false

        for member in members {
            let raw = member.waypointPinColorID.trimmingCharacters(in: .whitespacesAndNewlines)
            if let color = WaypointPinColor(rawValue: raw), !used.contains(color) {
                used.insert(color)
                continue
            }

            needsNormalization = true
            break
        }

        guard needsNormalization else { return }

        Task {
            do {
                try await service.normalizeMemberColors(groupId: groupId)
            } catch {
                #if DEBUG
                print("Radio group member waypoint color normalization failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    private func updateWaypointPinColor(uid: String, color: WaypointPinColor) async throws {
        try await service.updateWaypointPinColor(groupId: currentGroupId, colorID: color.rawValue)
    }

    private func getDocuments(_ query: Query) async throws -> QuerySnapshot {
        try await withCheckedThrowingContinuation { continuation in
            query.getDocuments { snapshot, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let snapshot else {
                    continuation.resume(throwing: NSError(domain: "RadioGroupStore", code: 1))
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
