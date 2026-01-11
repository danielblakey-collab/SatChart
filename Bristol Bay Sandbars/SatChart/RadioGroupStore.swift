import Foundation
import CoreLocation
import Combine
import FirebaseAuth
import FirebaseFirestore

/// Firestore-backed shared Radio Group state (pins + live sharing state).
/// - Pins are stored under: groups/{groupId}/pins/{pinId}
/// - Active groupId is stored in UserDefaults key: "radioGroupId"
final class RadioGroupStore: ObservableObject {

    // MARK: - Public state consumed by SwiftUI

    @Published var isLiveSharing: Bool = false
    @Published var lastLiveLocationSentAt: Date? = nil
    @Published var pins: [Pin] = []
    /// True only when the active group has at least 2 members (including this user).
    @Published var canShareLocation: Bool = false
    // Waypoints shared to the active group (received from other members).
    @Published var receivedWaypoints: [GroupWaypoint] = []
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
                senderName: $0.senderName
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
                senderName: $0.senderName
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
    }

    // MARK: - Private

    private let db = Firestore.firestore()
    private var pinsListener: ListenerRegistration?
    private var membersListener: ListenerRegistration?
    private var waypointsListener: ListenerRegistration?
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var defaultsObserver: NSObjectProtocol?
    private let groupIdDefaultsKey = "radioGroupId"

    private var currentGroupId: String? {
        let g = (UserDefaults.standard.string(forKey: groupIdDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return g.isEmpty ? nil : g
    }

    private var uid: String? { Auth.auth().currentUser?.uid }

    // MARK: - Init / Deinit

    init() {
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, _ in
            self?.startPinsListener()
            self?.startMembersListener()
            self?.startWaypointsListener()
        }

        ensureSignedIn()
        startPinsListener()
        startMembersListener()
        startWaypointsListener()

        // Restart listeners when group selection changes.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.startPinsListener()
            self?.startMembersListener()
            self?.startWaypointsListener()
        }
    }

    deinit {
        pinsListener?.remove()
        pinsListener = nil

        membersListener?.remove()
        membersListener = nil
        
        waypointsListener?.remove()
        waypointsListener = nil

        if let authHandle {
            Auth.auth().removeStateDidChangeListener(authHandle)
        }
        authHandle = nil

        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        defaultsObserver = nil
    }

    // MARK: - Public API

    func setGroupId(_ groupId: String) {
        UserDefaults.standard.set(groupId, forKey: groupIdDefaultsKey)
        startPinsListener()
        startMembersListener()
        startWaypointsListener()
    }

    func markLiveShared() {
        isLiveSharing = true
        lastLiveLocationSentAt = Date()
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
        isLiveSharing = false
    }

    /// Share a one-time pin (creates a new doc).
    func sendPin(_ coord: CLLocationCoordinate2D, displayName: String) {
        guard let uid else {
            ensureSignedIn()
            return
        }
        guard let col = pinsCollection() else { return }

        let now = Date()
        lastLiveLocationSentAt = now

        col.document().setData([
            "lat": coord.latitude,
            "lon": coord.longitude,
            "displayName": displayName,
            "createdAt": Timestamp(date: now),
            "updatedAt": Timestamp(date: now),
            "isLive": false,
            "ownerUid": uid
        ], merge: true)
    }

    /// Share/update live pin (one stable doc per user, doc id = uid).
    func upsertLivePin(_ coord: CLLocationCoordinate2D, displayName: String) {
        guard let uid else {
            ensureSignedIn()
            return
        }
        guard let col = pinsCollection() else { return }

        let now = Date()
        lastLiveLocationSentAt = now

        col.document(uid).setData([
            "lat": coord.latitude,
            "lon": coord.longitude,
            "displayName": displayName,
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": Timestamp(date: now),
            "isLive": true,
            "ownerUid": uid
        ], merge: true)
    }

    /// Deletes the most recent *non-live* pin owned by THIS user.
    func deleteLastPin() {
        guard let uid else { return }
        guard let col = pinsCollection() else { return }

        col.whereField("ownerUid", isEqualTo: uid)
            .whereField("isLive", isEqualTo: false)
            .order(by: "createdAt", descending: true)
            .limit(to: 1)
            .getDocuments { snapshot, _ in
                guard let doc = snapshot?.documents.first else { return }
                doc.reference.delete()
            }
    }

    /// Deletes ALL pins owned by THIS user (including live).
    func deleteAllPins() {
        guard let uid else { return }
        guard let col = pinsCollection() else { return }

        col.whereField("ownerUid", isEqualTo: uid)
            .getDocuments { snapshot, _ in
                let docs = snapshot?.documents ?? []
                guard !docs.isEmpty else { return }
                let batch = self.db.batch()
                for d in docs { batch.deleteDocument(d.reference) }
                batch.commit(completion: nil)
            }
    }

    /// Shares a waypoint with the active Radio Group (writes to groups/{groupId}/waypoints/{waypointId}).
    /// Default behavior remains private: local waypoints stay local unless explicitly sent.
    func sendWaypointToActiveGroup(_ wp: Waypoint) {
        guard let uid else {
            ensureSignedIn()
            return
        }
        guard let gid = currentGroupId else { return }

        let ref = db.collection("groups").document(gid)
            .collection("waypoints")
            .document(wp.id.uuidString)

        let now = Date()
        let senderNameRaw = (UserDefaults.standard.string(forKey: "radioPinDisplayName") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let senderName = senderNameRaw.isEmpty ? "Member" : senderNameRaw

        ref.setData([
            "name": wp.name,
            "notes": wp.notes,
            "lat": wp.coordinate.latitude,
            "lon": wp.coordinate.longitude,
            "createdAt": Timestamp(date: wp.createdAt),
            "sentAt": Timestamp(date: now),
            "senderUid": uid,
            "senderName": senderName
        ], merge: true)
    }

    var lastSentText: String {
        guard let d = lastLiveLocationSentAt else { return "—" }
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: d)
    }

    // MARK: - Firestore plumbing

    private func pinsCollection() -> CollectionReference? {
        guard let gid = currentGroupId else { return nil }
        return db.collection("groups").document(gid).collection("pins")
    }

    private func waypointsCollection() -> CollectionReference? {
        guard let gid = currentGroupId else { return nil }
        return db.collection("groups").document(gid).collection("waypoints")
    }

    private func startWaypointsListener() {
        guard let myUid = uid else { return }

        // If no group selected, stop listening but keep last-known received waypoints.
        // (Prevents UI/map from “blinking” when radioGroupId is briefly empty during transitions.)
        guard let col = waypointsCollection(), let gid = currentGroupId else {
            waypointsListener?.remove()
            waypointsListener = nil
            return
        }

        // Load hidden IDs first (so both cache + live snapshots can filter).
        let hidden = loadHiddenReceivedWaypointIDs(groupId: gid)
        DispatchQueue.main.async { self.hiddenReceivedWaypointIDs = hidden }

        // Load cached received waypoints immediately so map doesn't blink.
        let cachedAll = loadCachedReceivedWaypoints(groupId: gid)
        let cached = cachedAll.filter { !hidden.contains($0.id) }
        if !cached.isEmpty {
            DispatchQueue.main.async { self.receivedWaypoints = cached }
        }

        waypointsListener?.remove()
        waypointsListener = col.addSnapshotListener { [weak self] snapshot, _ in
            guard let self else { return }
            let docs = snapshot?.documents ?? []

            var out: [GroupWaypoint] = []
            out.reserveCapacity(docs.count)

            for d in docs {
                let data = d.data()

                // Sender (support legacy field names from earlier builds)
                let senderUidRaw = (data["senderUid"] as? String)
                    ?? (data["createdByUid"] as? String)
                    ?? (data["requestedByUid"] as? String)
                    ?? (data["createdBy"] as? String)
                    ?? ""

                // If still missing, fall back to a stable synthetic uid so UI/legend can still render
                let senderUidTrim = senderUidRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                let senderUid = senderUidTrim.isEmpty ? "unknown-\(d.documentID)" : senderUidTrim

                // Received = other members only
                if senderUid == myUid { continue }

                // Respect local hide list (do not delete from Firestore)
                if hidden.contains(d.documentID) { continue }

                let senderNameRaw = (data["senderName"] as? String)
                    ?? (data["createdByName"] as? String)
                    ?? (data["requestedByName"] as? String)
                    ?? ""

                let senderNameTrim = senderNameRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                let senderName = senderNameTrim.isEmpty ? "Member \(senderUid.prefix(6))" : senderNameTrim

                // Waypoint fields
                let name = (data["name"] as? String) ?? "Waypoint"
                let notes = (data["notes"] as? String) ?? ""
                let lat = (data["lat"] as? Double) ?? 0
                let lon = (data["lon"] as? Double) ?? 0

                let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                let sentAt = (data["sentAt"] as? Timestamp)?.dateValue() ?? createdAt

                out.append(
                    GroupWaypoint(
                        id: d.documentID,
                        name: name,
                        notes: notes,
                        coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                        createdAt: createdAt,
                        sentAt: sentAt,
                        senderUid: senderUid,
                        senderName: senderName
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
        
    private func ensureSignedIn() {
        if Auth.auth().currentUser != nil { return }
        Auth.auth().signInAnonymously { _, _ in }
    }

    private func startMembersListener() {
        guard let gid = currentGroupId else {
            membersListener?.remove()
            membersListener = nil
            DispatchQueue.main.async { self.canShareLocation = false }
            return
        }

        membersListener?.remove()
        membersListener = db.collection("groups").document(gid).collection("members")
            .addSnapshotListener { [weak self] snap, _ in
                guard let self else { return }
                let count = snap?.documents.count ?? 0
                DispatchQueue.main.async {
                    self.canShareLocation = (count >= 2)
                }
            }
    }

    private func startPinsListener() {
        guard uid != nil else { return }

        // If no group selected, clear pins and stop listening
        guard let col = pinsCollection() else {
            pinsListener?.remove()
            pinsListener = nil
            DispatchQueue.main.async { self.pins = [] }
            return
        }

        pinsListener?.remove()
        pinsListener = col
            .order(by: "createdAt", descending: true)
            .limit(to: 300)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let self else { return }
                let docs = snapshot?.documents ?? []

                var out: [Pin] = []
                out.reserveCapacity(docs.count)

                for d in docs {
                    let data = d.data()

                    let lat = (data["lat"] as? Double) ?? 0
                    let lon = (data["lon"] as? Double) ?? 0
                    let displayName = (data["displayName"] as? String) ?? ""
                    let isLive = (data["isLive"] as? Bool) ?? false
                    let ownerUid = (data["ownerUid"] as? String) ?? ""

                    let createdAt: Date = (data["createdAt"] as? Timestamp)?.dateValue()
                        ?? (data["updatedAt"] as? Timestamp)?.dateValue()
                        ?? Date.distantPast
                    let updatedAt: Date = (data["updatedAt"] as? Timestamp)?.dateValue() ?? createdAt

                    if isLive {
                        // Only canonical live pin doc (docId == ownerUid)
                        if d.documentID != ownerUid { continue }
                    }

                    out.append(
                        Pin(
                            id: d.documentID,
                            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                            createdAt: (isLive ? updatedAt : createdAt),
                            displayName: displayName,
                            isLive: isLive,
                            ownerUid: ownerUid,
                            updatedAt: updatedAt
                        )
                    )
                }

                DispatchQueue.main.async { self.pins = out }
            }
    }
}
