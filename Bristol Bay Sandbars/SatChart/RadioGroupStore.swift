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
        }

        ensureSignedIn()
        startPinsListener()
        startMembersListener()

        // Restart listeners when group selection changes.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.startPinsListener()
            self?.startMembersListener()
        }
    }

    deinit {
        pinsListener?.remove()
        pinsListener = nil

        membersListener?.remove()
        membersListener = nil
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
    }

    func markLiveShared() {
        isLiveSharing = true
        lastLiveLocationSentAt = Date()
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
