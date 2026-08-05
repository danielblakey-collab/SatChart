import Foundation
import FirebaseFirestore

final class RadioGroupRepository {
    private let db: Firestore

    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    func listenMemberships(
        uid: String,
        onChange: @escaping ([RadioGroupMembership]) -> Void
    ) -> ListenerRegistration {
        db.collection("users").document(uid).collection("memberships")
            .addSnapshotListener { snapshot, _ in
                let memberships = (snapshot?.documents ?? [])
                    .map { RadioGroupMembership(id: $0.documentID, data: $0.data()) }
                    .filter(\.active)
                    .sorted { $0.groupName.localizedCaseInsensitiveCompare($1.groupName) == .orderedAscending }
                DispatchQueue.main.async {
                    onChange(memberships)
                }
            }
    }

    func listenGroup(
        groupId: String,
        onChange: @escaping (RadioGroupSummary?) -> Void
    ) -> ListenerRegistration {
        db.collection("groups").document(groupId)
            .addSnapshotListener { snapshot, _ in
                guard let snapshot, snapshot.exists else {
                    DispatchQueue.main.async { onChange(nil) }
                    return
                }
                let group = RadioGroupSummary(id: snapshot.documentID, data: snapshot.data() ?? [:])
                DispatchQueue.main.async {
                    onChange(group.active ? group : nil)
                }
            }
    }

    func listenMembers(
        groupId: String,
        onChange: @escaping ([RadioGroupMember]) -> Void
    ) -> ListenerRegistration {
        db.collection("groups").document(groupId).collection("members")
            .addSnapshotListener { snapshot, _ in
                let members = (snapshot?.documents ?? [])
                    .map { RadioGroupMember(id: $0.documentID, data: $0.data()) }
                    .filter(\.active)
                    .sorted { lhs, rhs in
                        let leftRank = Self.roleRank(lhs.role)
                        let rightRank = Self.roleRank(rhs.role)
                        if leftRank != rightRank { return leftRank < rightRank }
                        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                    }
                DispatchQueue.main.async {
                    onChange(members)
                }
            }
    }

    func listenPendingJoinRequests(
        groupId: String,
        onChange: @escaping ([RadioGroupJoinRequest]) -> Void
    ) -> ListenerRegistration {
        db.collection("groups").document(groupId).collection("joinRequests")
            .whereField("status", isEqualTo: "pending")
            .addSnapshotListener { snapshot, _ in
                let requests = (snapshot?.documents ?? [])
                    .map { RadioGroupJoinRequest(id: $0.documentID, data: $0.data()) }
                    .sorted { $0.createdAt > $1.createdAt }
                DispatchQueue.main.async {
                    onChange(requests)
                }
            }
    }

    func listenJoinRequest(
        groupId: String,
        uid: String,
        onChange: @escaping (RadioGroupJoinRequest?) -> Void
    ) -> ListenerRegistration {
        db.collection("groups").document(groupId).collection("joinRequests").document(uid)
            .addSnapshotListener { snapshot, _ in
                guard let snapshot, snapshot.exists else {
                    DispatchQueue.main.async { onChange(nil) }
                    return
                }
                let request = RadioGroupJoinRequest(id: snapshot.documentID, data: snapshot.data() ?? [:])
                DispatchQueue.main.async {
                    onChange(request)
                }
            }
    }

    func listenPins(
        groupId: String,
        onChange: @escaping ([RadioGroupPinRecord]) -> Void
    ) -> ListenerRegistration {
        db.collection("groups").document(groupId).collection("pins")
            .order(by: "createdAt", descending: true)
            .limit(to: 300)
            .addSnapshotListener { snapshot, _ in
                let pins = (snapshot?.documents ?? [])
                    .map { RadioGroupPinRecord(id: $0.documentID, data: $0.data()) }
                    .filter { !$0.isExpired && $0.hasValidCoordinate }
                DispatchQueue.main.async {
                    onChange(pins)
                }
            }
    }

    func listenLiveLocations(
        groupId: String,
        onChange: @escaping ([RadioGroupLiveLocationRecord]) -> Void,
        onError: ((Error) -> Void)? = nil
    ) -> ListenerRegistration {
        db.collection("groups").document(groupId).collection("liveLocations")
            .whereField("sharingEnabled", isEqualTo: true)
            .addSnapshotListener { snapshot, error in
                if let error {
                    DispatchQueue.main.async {
                        onError?(error)
                    }
                    return
                }

                let liveLocations = (snapshot?.documents ?? [])
                    .map { RadioGroupLiveLocationRecord(id: $0.documentID, data: $0.data()) }
                    .filter { !$0.isExpired && $0.hasValidCoordinate }
                    .sorted { $0.updatedAt > $1.updatedAt }
                DispatchQueue.main.async {
                    onChange(liveLocations)
                }
            }
    }

    func listenWaypoints(
        groupId: String,
        onChange: @escaping ([RadioGroupSharedWaypointRecord]) -> Void
    ) -> ListenerRegistration {
        db.collection("groups").document(groupId).collection("waypoints")
            .addSnapshotListener { snapshot, _ in
                let waypoints = (snapshot?.documents ?? [])
                    .map { RadioGroupSharedWaypointRecord(id: $0.documentID, data: $0.data()) }
                    .filter { !$0.isExpired }
                    .sorted { $0.sentAt > $1.sentAt }
                DispatchQueue.main.async {
                    onChange(waypoints)
                }
            }
    }

    private static func roleRank(_ role: RadioGroupRole) -> Int {
        switch role {
        case .owner: return 0
        case .admin: return 1
        case .member: return 2
        }
    }
}
