import SwiftUI
import UIKit
import FirebaseAuth
import FirebaseFirestore

struct RadioGroupView: View {

    // MARK: - Firestore
    private let db = Firestore.firestore()

    // MARK: - Shared dependencies
    @EnvironmentObject var pinSettings: RadioGroupPinSettings
    @EnvironmentObject var radioGroup: RadioGroupStore

    // MARK: - Persisted user/device state
    @AppStorage("radioGroupId") private var radioGroupId: String = ""                 // active group for pins
    @AppStorage("pendingJoinGroupId") private var pendingJoinGroupId: String = ""
    @AppStorage("pendingJoinGroupName") private var pendingJoinGroupName: String = ""

    // Join result popup state (persisted so it can show next time the page opens)
    @AppStorage("joinSuccessUntilEpoch") private var joinSuccessUntilEpoch: Double = 0
    @AppStorage("joinResultIsSuccess") private var joinResultIsSuccess: Bool = true
    @AppStorage("joinSuccessGroupName") private var joinSuccessGroupName: String = ""

    // User info (editable fields)
    @AppStorage("userFirstName") private var userFirstName: String = ""
    @AppStorage("userLastName") private var userLastName: String = ""
    @AppStorage("userFirstNameLocked") private var userFirstNameLocked: Bool = false
    @AppStorage("userLastNameLocked") private var userLastNameLocked: Bool = false

    // Vessel name drives pin display name
    @AppStorage("radioPinDisplayName") private var radioPinDisplayName: String = ""
    @AppStorage("vesselName") private var vesselName: String = ""
    @AppStorage("vesselNameLocked") private var vesselNameLocked: Bool = false

    @AppStorage("liveLocationUpdateOption") private var liveLocationUpdateOptionRaw: String = LiveLocationUpdateOption.oneMinute.rawValue

    // MARK: - Focus
    @FocusState private var isVesselNameFocused: Bool
    @FocusState private var isFirstNameFocused: Bool
    @FocusState private var isLastNameFocused: Bool

    // MARK: - UI state
    @State private var toastText: String? = nil
    @State private var toastHideWork: DispatchWorkItem? = nil

    @State private var showInviteCode: Bool = false
    @State private var inviteCodeToShow: String = ""

    @State private var showCreateFlow: Bool = false
    @State private var showJoinFlow: Bool = false

    @State private var createGroupNameInput: String = ""
    @State private var createAdminFirstNameInput: String = ""
    @State private var createAdminLastNameInput: String = ""

    @State private var joinMemberFirstNameInput: String = ""
    @State private var joinMemberLastNameInput: String = ""
    @State private var joinCodeInput: String = ""

    @State private var showConfirmDeleteLastPin: Bool = false
    @State private var showConfirmDeleteAllPins: Bool = false
    @State private var confirmLeaveGroupId: String? = nil
    @State private var confirmDeleteGroupId: String? = nil

    // MARK: - Multi-group state
    private struct RGMember: Identifiable, Hashable {
        let id: String
        var name: String
        var role: String
    }

    private struct RGGroup: Identifiable, Hashable {
        let id: String
        var name: String
        var inviteCode: String
        var members: [RGMember]
    }

    @State private var myGroupIds: [String] = []
    @State private var groupsById: [String: RGGroup] = [:]

    @State private var memberGroupCounts: [String: Int] = [:]

    @State private var myMembershipsListener: ListenerRegistration? = nil
    @State private var groupDocListeners: [String: ListenerRegistration] = [:]
    @State private var groupMembersListeners: [String: ListenerRegistration] = [:]
    @State private var memberCountListeners: [String: ListenerRegistration] = [:]
    @State private var pendingJoinRequestsByGroup: [String: [JoinRequestRow]] = [:]
    @State private var groupJoinRequestsListeners: [String: ListenerRegistration] = [:]
    @State private var myJoinRequestListener: ListenerRegistration? = nil

    private struct JoinRequestRow: Identifiable, Hashable {
        let id: String       // requester uid
        var requestedByName: String
        var createdAt: Date
    }

    // MARK: - Colors (self-contained)
    private let menuBlueUIColor = UIColor(red: 0.03, green: 0.23, blue: 0.48, alpha: 1.0)
    private var menuBlue: Color { Color(uiColor: menuBlueUIColor) }

    // MARK: - Helpers

    private func erased<V: View>(_ view: V) -> AnyView { AnyView(view) }

    private func showToast(_ text: String, seconds: TimeInterval = 3.0) {
        toastHideWork?.cancel()
        toastText = text
        let work = DispatchWorkItem { toastText = nil }
        toastHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func ensureAnonAuth(_ done: (() -> Void)? = nil) {
        if Auth.auth().currentUser != nil {
            done?()
            return
        }
        Auth.auth().signInAnonymously { _, _ in done?() }
    }

    private func currentUid() -> String? { Auth.auth().currentUser?.uid }

    private var isPendingJoin: Bool {
        !pendingJoinGroupId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSubmitCreateFlow: Bool {
        !createGroupNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !createAdminFirstNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !createAdminLastNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSubmitJoinFlow: Bool {
        !joinMemberFirstNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !joinMemberLastNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !joinCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func fullName(first: String, last: String) -> String {
        "\(first.trimmingCharacters(in: .whitespacesAndNewlines)) \(last.trimmingCharacters(in: .whitespacesAndNewlines))"
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func nameWithCount(uid: String, name: String) -> String {
        let n = memberGroupCounts[uid] ?? 0
        if n <= 0 { return name }
        return "\(name), \(n) Radio Groups"
    }

    private func generateInviteCodeValue() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).compactMap { _ in chars.randomElement() })
    }

    private func showJoinResultPopup(isSuccess: Bool, groupName: String) {
        let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)

        joinResultIsSuccess = isSuccess
        joinSuccessGroupName = trimmed

        let until = Date().addingTimeInterval(5).timeIntervalSince1970
        joinSuccessUntilEpoch = until

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.1) {
            DispatchQueue.main.async {
                if joinSuccessUntilEpoch == until {
                    joinSuccessUntilEpoch = 0
                    joinSuccessGroupName = ""
                }
            }
        }
    }

    // MARK: - Listeners

    private func startMyMembershipsListener() {
        ensureAnonAuth {
            guard let uid = currentUid() else { return }

            myMembershipsListener?.remove()
            myMembershipsListener = db.collection("users").document(uid).collection("memberships")
                .addSnapshotListener { snap, _ in
                    let ids = (snap?.documents ?? []).map { $0.documentID }.sorted()
                    myGroupIds = ids

                    for gid in ids { startGroupListeners(groupId: gid) }

                    let keep = Set(ids)
                    for (gid, l) in groupDocListeners where !keep.contains(gid) { l.remove(); groupDocListeners[gid] = nil }
                    for (gid, l) in groupMembersListeners where !keep.contains(gid) { l.remove(); groupMembersListeners[gid] = nil }
                    for (gid, l) in groupJoinRequestsListeners where !keep.contains(gid) { l.remove(); groupJoinRequestsListeners[gid] = nil }
                    for gid in Array(groupsById.keys) where !keep.contains(gid) { groupsById[gid] = nil }
                    for gid in Array(pendingJoinRequestsByGroup.keys) where !keep.contains(gid) { pendingJoinRequestsByGroup[gid] = nil }
                }
        }
    }

    private func startGroupListeners(groupId gid: String) {
        if groupDocListeners[gid] == nil {
            groupDocListeners[gid] = db.collection("groups").document(gid)
                .addSnapshotListener { snap, _ in
                    let data = snap?.data() ?? [:]
                    let name = (data["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Radio Group"
                    let code = (data["inviteCode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    var g = groupsById[gid] ?? RGGroup(id: gid, name: name, inviteCode: code, members: [])
                    g.name = name
                    g.inviteCode = code
                    groupsById[gid] = g
                }
        }

        if groupMembersListeners[gid] == nil {
            groupMembersListeners[gid] = db.collection("groups").document(gid).collection("members")
                .addSnapshotListener { snap, _ in
                    let docs = snap?.documents ?? []
                    let members: [RGMember] = docs.map { d in
                        let data = d.data()
                        let nm = (data["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Member"
                        let role = (data["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "member"
                        return RGMember(id: d.documentID, name: nm, role: role)
                    }.sorted { $0.name.lowercased() < $1.name.lowercased() }

                    var g = groupsById[gid] ?? RGGroup(id: gid, name: "Radio Group", inviteCode: "", members: [])
                    g.members = members
                    groupsById[gid] = g

                    for m in members { startMemberCountListener(uid: m.id) }
                    startJoinRequestsListener(groupId: gid)
                }
        }
    }

    private func startJoinRequestsListener(groupId gid: String) {
        guard groupJoinRequestsListeners[gid] == nil else { return }

        groupJoinRequestsListeners[gid] = db.collection("groups").document(gid).collection("joinRequests")
            .whereField("status", isEqualTo: "pending")
            .addSnapshotListener { snap, _ in
                let docs = snap?.documents ?? []
                let mapped: [JoinRequestRow] = docs.map { d in
                    let data = d.data()
                    let nm = (data["requestedByName"] as? String) ?? "Member"
                    let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
                    return JoinRequestRow(id: d.documentID, requestedByName: nm, createdAt: createdAt)
                }.sorted { $0.createdAt > $1.createdAt }
                pendingJoinRequestsByGroup[gid] = mapped
            }
    }

    private func startMemberCountListener(uid: String) {
        guard memberCountListeners[uid] == nil else { return }
        memberCountListeners[uid] = db.collection("users").document(uid).collection("memberships")
            .addSnapshotListener { snap, _ in
                memberGroupCounts[uid] = snap?.documents.count ?? 0
            }
    }

    private func attachMyJoinRequestListener() {
        myJoinRequestListener?.remove()
        myJoinRequestListener = nil

        let gid = pendingJoinGroupId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gid.isEmpty else { return }

        ensureAnonAuth {
            guard let uid = currentUid() else { return }

            myJoinRequestListener = db.collection("groups").document(gid)
                .collection("joinRequests").document(uid)
                .addSnapshotListener { snap, _ in
                    guard let data = snap?.data() else { return }
                    let status = (data["status"] as? String) ?? "pending"

                    DispatchQueue.main.async {
                        if status == "approved" {
                            let joinedName = pendingJoinGroupName
                            pendingJoinGroupId = ""
                            pendingJoinGroupName = ""
                            showJoinResultPopup(isSuccess: true, groupName: joinedName)
                            setActivePinsGroup(gid)
                        } else if status == "rejected" {
                            let rejectedName = pendingJoinGroupName
                            pendingJoinGroupId = ""
                            pendingJoinGroupName = ""
                            showJoinResultPopup(isSuccess: false, groupName: rejectedName)
                        }
                    }
                }
        }
    }

    // MARK: - Actions

    private func setActivePinsGroup(_ gid: String) {
        radioGroupId = gid
        radioGroup.setGroupId(gid)
        showToast("Active group set.", seconds: 2.0)
    }

    private func createRadioGroup() {
        ensureAnonAuth {
            guard let uid = currentUid() else { return }

            let groupName = createGroupNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let adminName = fullName(first: createAdminFirstNameInput, last: createAdminLastNameInput)
            guard !groupName.isEmpty, !adminName.isEmpty else { return }

            let gid = UUID().uuidString
            let inviteCode = generateInviteCodeValue()
            let groupRef = db.collection("groups").document(gid)

            groupRef.setData([
                "name": groupName,
                "inviteCode": inviteCode,
                "createdAt": FieldValue.serverTimestamp(),
                "createdBy": uid
            ])

            groupRef.collection("members").document(uid).setData([
                "name": adminName,
                "role": "admin",
                "joinedAt": FieldValue.serverTimestamp()
            ])

            db.collection("users").document(uid).collection("memberships").document(gid).setData([
                "joinedAt": FieldValue.serverTimestamp()
            ], merge: true)

            userFirstName = createAdminFirstNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
            userLastName = createAdminLastNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
            userFirstNameLocked = true
            userLastNameLocked = true
            if !vesselName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { vesselNameLocked = true }

            setActivePinsGroup(gid)

            inviteCodeToShow = inviteCode
            showInviteCode = true
            showToast("Radio Group created.", seconds: 3.0)
        }
    }

    private func submitJoinRequestFirestore() {
        let code = joinCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let name = fullName(first: joinMemberFirstNameInput, last: joinMemberLastNameInput)
        guard !code.isEmpty, !name.isEmpty else { return }

        ensureAnonAuth {
            guard let uid = currentUid() else { return }

            db.collection("groups")
                .whereField("inviteCode", isEqualTo: code)
                .limit(to: 1)
                .getDocuments { snap, _ in
                    guard let doc = snap?.documents.first else {
                        DispatchQueue.main.async {
                            showToast("Invalid code! Contact Radio Group for invite code.", seconds: 4.0)
                        }
                        return
                    }

                    let gid = doc.documentID
                    let gName = (doc.data()["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Radio Group"

                    DispatchQueue.main.async {
                        pendingJoinGroupId = gid
                        pendingJoinGroupName = gName

                        userFirstName = joinMemberFirstNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        userLastName = joinMemberLastNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        userFirstNameLocked = true
                        userLastNameLocked = true
                        if !vesselName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { vesselNameLocked = true }
                    }

                    let reqRef = db.collection("groups").document(gid).collection("joinRequests").document(uid)
                    reqRef.setData([
                        "requestedByUid": uid,
                        "requestedByName": name,
                        "status": "pending",
                        "createdAt": FieldValue.serverTimestamp()
                    ], merge: true) { _ in
                        DispatchQueue.main.async {
                            attachMyJoinRequestListener()
                            showToast("Your request has been sent to the Radio Group for approval", seconds: 4.0)
                        }
                    }
                }
        }
    }

    private func approve(reqID: String, groupId gid: String, requesterName: String) {
        ensureAnonAuth {
            let groupId = gid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !groupId.isEmpty else { return }

            db.collection("groups").document(groupId).collection("joinRequests").document(reqID)
                .setData(["status": "approved"], merge: true)

            db.collection("groups").document(groupId).collection("members").document(reqID)
                .setData([
                    "name": requesterName,
                    "role": "member",
                    "joinedAt": FieldValue.serverTimestamp()
                ], merge: true)

            db.collection("users").document(reqID).collection("memberships").document(groupId)
                .setData(["joinedAt": FieldValue.serverTimestamp()], merge: true)

            DispatchQueue.main.async { showToast("Approved.", seconds: 2.5) }
        }
    }

    private func reject(reqID: String, groupId gid: String) {
        ensureAnonAuth {
            let groupId = gid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !groupId.isEmpty else { return }

            db.collection("groups").document(groupId).collection("joinRequests").document(reqID)
                .setData(["status": "rejected"], merge: true)

            db.collection("users").document(reqID).collection("memberships").document(groupId).delete()

            DispatchQueue.main.async { showToast("Rejected.", seconds: 2.5) }
        }
    }

    private func leaveGroup(gid: String) {
        ensureAnonAuth {
            guard let uid = currentUid() else { return }

            db.collection("users").document(uid).collection("memberships").document(gid).delete()
            db.collection("groups").document(gid).collection("members").document(uid).delete()

            if radioGroupId == gid {
                radioGroupId = ""
                radioGroup.setGroupId("")
            }
            showToast("Left Radio Group.", seconds: 3.0)
        }
    }

    private func deleteGroup(gid: String) {
        ensureAnonAuth {
            db.collection("groups").document(gid).delete()
            leaveGroup(gid: gid)
            showToast("Radio Group deleted.", seconds: 3.0)
        }
    }

    // MARK: - Info Row Helper

    @ViewBuilder
    private func infoRow(
        label: String,
        text: Binding<String>,
        locked: Binding<Bool>,
        focus: FocusState<Bool>.Binding,
        onLock: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)

            TextField("", text: text, prompt: Text("Enter \(label.lowercased())").foregroundColor(.gray))
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(true)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(locked.wrappedValue ? .white : .black)
                .tint(locked.wrappedValue ? .white : .black)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(locked.wrappedValue ? Color.black.opacity(0.60) : Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.black.opacity(locked.wrappedValue ? 0.0 : 0.15), lineWidth: 1)
                )
                .disabled(locked.wrappedValue)
                .focused(focus)

            Button {
                let willUnlock = locked.wrappedValue
                withAnimation(.easeInOut(duration: 0.18)) {
                    locked.wrappedValue.toggle()
                }

                if willUnlock {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        focus.wrappedValue = true
                    }
                } else {
                    focus.wrappedValue = false
                    onLock?()
                }
            } label: {
                Text(locked.wrappedValue ? "Edit" : "Enter")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 36)
                    .background(locked.wrappedValue ? Color.gray.opacity(0.70) : Color.blue.opacity(0.70))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .underline()
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
    }

    @ViewBuilder
    private var myInfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("My Information")
            infoRow(
                label: "Vessel Name",
                text: $vesselName,
                locked: $vesselNameLocked,
                focus: $isVesselNameFocused,
                onLock: {
                    let trimmed = vesselName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { radioPinDisplayName = trimmed }
                }
            )
            infoRow(
                label: "First Name",
                text: $userFirstName,
                locked: $userFirstNameLocked,
                focus: $isFirstNameFocused
            )
            infoRow(
                label: "Last Name",
                text: $userLastName,
                locked: $userLastNameLocked,
                focus: $isLastNameFocused
            )
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("My Status")
            HStack {
                Text("Live sharing")
                Spacer()
                Text(radioGroup.isLiveSharing ? "ON" : "OFF")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(radioGroup.isLiveSharing ? .green : .red)
            }
            HStack {
                Text("Last location sent")
                Spacer()
                Text(radioGroup.lastSentText)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    @ViewBuilder
    private var pinsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Location Pins and Live Location")
            Picker("Location Pin Expires After", selection: $pinSettings.expiry) {
                ForEach(PinExpiryOption.allCases) { opt in
                    Text(opt.label).tag(opt)
                }
            }
            .pickerStyle(.menu)
            Picker("Live Location Sharing Updated", selection: $liveLocationUpdateOptionRaw) {
                ForEach(LiveLocationUpdateOption.allCases) { opt in
                    Text(opt.label).tag(opt.rawValue)
                }
            }
            .pickerStyle(.menu)
            Button(role: .destructive) { showConfirmDeleteLastPin = true } label: {
                Label("Delete last pin", systemImage: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.red)
            }
            Button(role: .destructive) { showConfirmDeleteAllPins = true } label: {
                Label("Delete all pins", systemImage: "trash.slash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    @ViewBuilder
    private var joinBannerSection: some View {
        if isPendingJoin {
            VStack(alignment: .leading, spacing: 10) {
                Text("Request Pending to join \"\(pendingJoinGroupName.isEmpty ? "Radio Group" : pendingJoinGroupName)\"")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.yellow)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
        }
    }

    @ViewBuilder
    private func groupCard(for gid: String) -> some View {
        if let g = groupsById[gid] {
            VStack(alignment: .leading, spacing: 10) {

                Button {
                    setActivePinsGroup(gid)
                } label: {
                    HStack {
                        Text(g.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.blue)

                        Spacer()

                        let isSelected = (radioGroupId == gid)
                        let isEligible = (g.members.count >= 2)

                        if isSelected && isEligible {
                            Text("Active")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.green.opacity(0.80))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            Text("Inactive")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.red.opacity(0.80))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Members")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))

                    ForEach(g.members) { m in
                        Text(nameWithCount(uid: m.id, name: m.name))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.90))
                    }
                }

                if let uid = currentUid(),
                   let me = g.members.first(where: { $0.id == uid }),
                   me.role == "admin",
                   let pending = pendingJoinRequestsByGroup[gid],
                   !pending.isEmpty {

                    Text("Pending join requests")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))

                    ForEach(pending) { req in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(req.requestedByName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)

                            HStack(spacing: 10) {
                                Button {
                                    approve(reqID: req.id, groupId: gid, requesterName: req.requestedByName)
                                } label: {
                                    Text("Approve").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)

                                Button {
                                    reject(reqID: req.id, groupId: gid)
                                } label: {
                                    Text("Reject").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Button {
                    let code = generateInviteCodeValue()
                    db.collection("groups").document(gid).setData(["inviteCode": code], merge: true)
                    inviteCodeToShow = code
                    showInviteCode = true
                    showToast("Invite code created.", seconds: 2.2)
                } label: {
                    Text("Invite New Member").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                Button {
                    confirmLeaveGroupId = gid
                } label: {
                    Text("Leave Radio Group")
                        .frame(maxWidth: .infinity)
                        .foregroundColor(.yellow)
                }
                .buttonStyle(.bordered)
                .tint(.gray)

                if let uid = currentUid(),
                   let me = g.members.first(where: { $0.id == uid }),
                   me.role == "admin" {

                    Button {
                        confirmDeleteGroupId = gid
                    } label: {
                        Text("Delete Radio Group")
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.bordered)
                    .tint(.gray)
                }
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var myGroupsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("My Radio Groups")
            if myGroupIds.isEmpty {
                Text("You are not currently in any Radio Groups.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(myGroupIds, id: \.self) { gid in
                    groupCard(for: gid)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    @ViewBuilder
    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Actions")
            Button {
                createGroupNameInput = ""
                createAdminFirstNameInput = userFirstName
                createAdminLastNameInput = userLastName
                showCreateFlow = true
            } label: {
                Text("Create Radio Group").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            Button {
                joinMemberFirstNameInput = userFirstName
                joinMemberLastNameInput = userLastName
                joinCodeInput = ""
                showJoinFlow = true
            } label: {
                Text("Join Existing Radio Group").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    private var listBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                myInfoSection
                statusSection
                pinsSection
                joinBannerSection
                myGroupsSection
                actionsSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(HideScrollIndicatorsIfAvailable())
    }

    // Helper modifier to hide scroll indicators if available (iOS 16+)
    private struct HideScrollIndicatorsIfAvailable: ViewModifier {
        func body(content: Content) -> some View {
            if #available(iOS 16.0, *) {
                content.scrollIndicators(.hidden)
            } else {
                content
            }
        }
    }

    private var baseChrome: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            listBody
        }
        .environment(\.colorScheme, .dark)
        .foregroundColor(.white)
        .navigationTitle("Radio Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(menuBlue, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Radio Group")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .underline()
            }
        }
    }

    private var toastsOverlay: some View {
        baseChrome
            .overlay(alignment: .bottom) {
                if let toastText {
                    Text(toastText)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay {
                if Date().timeIntervalSince1970 < joinSuccessUntilEpoch {
                    VStack {
                        Spacer()

                        Text(
                            joinResultIsSuccess
                            ? (joinSuccessGroupName.isEmpty
                               ? "You have successfully joined Radio Group!"
                               : "You have successfully joined \(joinSuccessGroupName)!")
                            : (joinSuccessGroupName.isEmpty
                               ? "Sorry, your request to join Radio Group was not approved."
                               : "Sorry, your request to join \(joinSuccessGroupName) was not approved.")
                        )
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(joinResultIsSuccess ? .green : .red)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .background(Color(white: 0.85).opacity(0.95))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )

                        Spacer()
                    }
                    .padding(.horizontal, 24)
                }
            }
    }

    // MARK: - Body

    var body: some View {
        toastsOverlay
            .onAppear {
                MenuAppearance.applyNavBar()
                startMyMembershipsListener()

                if isPendingJoin {
                    // Ensure listener is attached even if the page is already open.
                    attachMyJoinRequestListener()

                    // One-shot check so the popup shows even if approval happened while page was closed.
                    ensureAnonAuth {
                        guard let uid = currentUid() else { return }
                        let gid = pendingJoinGroupId.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !gid.isEmpty else { return }

                        db.collection("groups").document(gid).collection("joinRequests").document(uid)
                            .getDocument { snap, _ in
                                guard let data = snap?.data() else { return }
                                let status = (data["status"] as? String) ?? "pending"

                                DispatchQueue.main.async {
                                    if status == "approved" {
                                        let joinedName = pendingJoinGroupName
                                        pendingJoinGroupId = ""
                                        pendingJoinGroupName = ""
                                        showJoinResultPopup(isSuccess: true, groupName: joinedName)
                                        setActivePinsGroup(gid)
                                    } else if status == "rejected" {
                                        let rejectedName = pendingJoinGroupName
                                        pendingJoinGroupId = ""
                                        pendingJoinGroupName = ""
                                        showJoinResultPopup(isSuccess: false, groupName: rejectedName)
                                    }
                                }
                            }
                    }
                }
            }
            .onDisappear {
                myJoinRequestListener?.remove()
                myJoinRequestListener = nil
            }
            .onChange(of: pendingJoinGroupId) { _ in
                if isPendingJoin {
                    attachMyJoinRequestListener()
                }
            }
            // Sheets / dialogs must live on the root view so they keep working.
            .sheet(isPresented: $showInviteCode) {
                VStack(spacing: 16) {
                    Text("Invite Code")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)

                    Text(inviteCodeToShow.isEmpty ? "—" : inviteCodeToShow)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Text("New members will use this code to join.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))

                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = inviteCodeToShow
                            showToast("Invite code copied.", seconds: 2.0)
                        } label: {
                            Text("Copy").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)

                        Button { showInviteCode = false } label: {
                            Text("Close").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.gray)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
                .environment(\.colorScheme, .dark)
            }
            .sheet(isPresented: $showCreateFlow) {
                VStack(spacing: 16) {
                    Text("Create Radio Group")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)

                    TextField("Radio Group Name", text: $createGroupNameInput)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled(true)
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(Color.white.opacity(0.12))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    TextField("First Name", text: $createAdminFirstNameInput)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled(true)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(Color.white.opacity(0.12))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    TextField("Last Name", text: $createAdminLastNameInput)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled(true)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(Color.white.opacity(0.12))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button {
                        guard canSubmitCreateFlow else { return }
                        createRadioGroup()
                        showCreateFlow = false
                    } label: {
                        Text("Submit").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(canSubmitCreateFlow ? .blue : .gray)
                    .disabled(!canSubmitCreateFlow)

                    Button { showCreateFlow = false } label: {
                        Text("Cancel").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.gray)
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
                .environment(\.colorScheme, .dark)
            }
            .sheet(isPresented: $showJoinFlow) {
                VStack(spacing: 16) {
                    Text("Join Existing Radio Group")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)

                    TextField("First Name", text: $joinMemberFirstNameInput)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled(true)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(Color.white.opacity(0.12))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    TextField("Last Name", text: $joinMemberLastNameInput)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled(true)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(Color.white.opacity(0.12))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    TextField("Enter Invite Code", text: $joinCodeInput)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(Color.white.opacity(0.12))
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button {
                        guard canSubmitJoinFlow else { return }
                        submitJoinRequestFirestore()
                        showJoinFlow = false
                    } label: {
                        Text("Submit").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(canSubmitJoinFlow ? .blue : .gray)
                    .disabled(!canSubmitJoinFlow)

                    Button { showJoinFlow = false } label: {
                        Text("Cancel").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.gray)
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
                .environment(\.colorScheme, .dark)
            }
            .confirmationDialog("Delete last location pin?", isPresented: $showConfirmDeleteLastPin, titleVisibility: .visible) {
                Button("Delete Last Pin", role: .destructive) {
                    radioGroup.deleteLastPin()
                    showToast("Deleted last pin.", seconds: 2.0)
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete all location pins?", isPresented: $showConfirmDeleteAllPins, titleVisibility: .visible) {
                Button("Delete All Pins", role: .destructive) {
                    radioGroup.deleteAllPins()
                    showToast("Deleted all pins.", seconds: 2.0)
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                confirmLeaveGroupId.flatMap { gid in
                    let name = groupsById[gid]?.name ?? "Radio Group"
                    return "Are you sure you want to leave \(name)?"
                } ?? "Leave Radio Group?",
                isPresented: Binding(
                    get: { confirmLeaveGroupId != nil },
                    set: { if !$0 { confirmLeaveGroupId = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Leave", role: .destructive) {
                    if let gid = confirmLeaveGroupId { leaveGroup(gid: gid) }
                    confirmLeaveGroupId = nil
                }
                Button("Cancel", role: .cancel) { confirmLeaveGroupId = nil }
            }
            .confirmationDialog(
                confirmDeleteGroupId.flatMap { gid in
                    let name = groupsById[gid]?.name ?? "Radio Group"
                    return "Delete \(name)? This will delete group for all members!"
                } ?? "Delete Radio Group?",
                isPresented: Binding(
                    get: { confirmDeleteGroupId != nil },
                    set: { if !$0 { confirmDeleteGroupId = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let gid = confirmDeleteGroupId { deleteGroup(gid: gid) }
                    confirmDeleteGroupId = nil
                }
                Button("Cancel", role: .cancel) { confirmDeleteGroupId = nil }
            }
    }
}
