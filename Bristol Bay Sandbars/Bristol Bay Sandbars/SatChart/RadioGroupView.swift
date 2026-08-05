import SwiftUI
import UIKit
import FirebaseAuth
import FirebaseFirestore

struct RadioGroupView: View {

    // MARK: - Shared layout styling (matched to Tables page)
    private let sectionCornerRadius: CGFloat = 16
    private let sectionBackground = Color.white.opacity(0.08)
    private let sectionBorder = Color.white.opacity(0.10)
    private let selectorHeight: CGFloat = 33

    // MARK: - Data access
    private let repository = RadioGroupRepository()
    private let service = RadioGroupService()
    private let profileService = UserProfileService()

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

    // User info (source of truth: account profile)
    @AppStorage("userFirstName") private var userFirstName: String = ""
    @AppStorage("userLastName") private var userLastName: String = ""

    // Vessel name drives pin display name
    @AppStorage("radioPinDisplayName") private var radioPinDisplayName: String = ""
    @AppStorage("vesselName") private var vesselName: String = ""
    @AppStorage("defaultWaypointPinColorID") private var defaultWaypointPinColorID: String = ""

    @AppStorage("liveLocationUpdateOption") private var liveLocationUpdateOptionRaw: String = LiveLocationUpdateOption.oneMinute.rawValue

    // MARK: - Focus
    @FocusState private var isVesselNameFocused: Bool

    // MARK: - UI state
    @State private var toastText: String? = nil
    @State private var toastHideWork: DispatchWorkItem? = nil
    @State private var isRadioGroupActionInProgress: Bool = false
    @State private var profileLoadAttempted: Bool = false
    @State private var loadedUserProfile: UserProfile? = nil
    @State private var isEditingVesselName: Bool = false
    @State private var isSavingVesselName: Bool = false
    @State private var vesselNameDraft: String = ""

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

    @State private var confirmLeaveGroupId: String? = nil

    // MARK: - Multi-group state
    private struct RGMember: Identifiable, Hashable {
        let id: String
        var name: String
        var vesselName: String
        var role: String
        var canApprove: Bool
        var publicMembershipCount: Int
    }

    private struct RGGroup: Identifiable, Hashable {
        let id: String
        var name: String
        var members: [RGMember]
    }

    @State private var myGroupIds: [String] = []
    @State private var groupsById: [String: RGGroup] = [:]

    @State private var myMembershipsListener: ListenerRegistration? = nil
    @State private var groupDocListeners: [String: ListenerRegistration] = [:]
    @State private var groupMembersListeners: [String: ListenerRegistration] = [:]
    @State private var pendingJoinRequestsByGroup: [String: [JoinRequestRow]] = [:]
    @State private var groupJoinRequestsListeners: [String: ListenerRegistration] = [:]
    @State private var myJoinRequestListener: ListenerRegistration? = nil

    private struct JoinRequestRow: Identifiable, Hashable {
        let id: String       // requester uid
        var requestedByName: String
        var requestedVesselName: String
        var createdAt: Date
    }

    // MARK: - Colors
    // Nav bar stays BB/Menu blue, but the page background uses the SatChart theme.
    private let menuBlueUIColor = UIColor(red: 0.03, green: 0.23, blue: 0.48, alpha: 1.0)
    private var menuBlue: Color { Color(uiColor: menuBlueUIColor) }

    // MARK: - Helpers


    private func erased<V: View>(_ view: V) -> AnyView { AnyView(view) }

    // MARK: - UIKit background fixer (kills the white strip above the tab bar)
    private struct HostingBackgroundFixer: UIViewRepresentable {
        let color: UIColor

        func makeUIView(context: Context) -> UIView {
            FixView(color: color)
        }

        func updateUIView(_ uiView: UIView, context: Context) {
            (uiView as? FixView)?.color = color
            (uiView as? FixView)?.apply()
        }

        private final class FixView: UIView {
            var color: UIColor

            init(color: UIColor) {
                self.color = color
                super.init(frame: .zero)
                backgroundColor = .clear
                isUserInteractionEnabled = false
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            override func didMoveToSuperview() {
                super.didMoveToSuperview()
                apply()
            }

            override func layoutSubviews() {
                super.layoutSubviews()
                apply()
            }

            func apply() {
                // Apply on next runloop to ensure we have a superview chain.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }

                    // Paint a couple levels up; this typically covers the UIHostingController root + container.
                    self.superview?.backgroundColor = self.color
                    self.superview?.superview?.backgroundColor = self.color
                    self.superview?.superview?.superview?.backgroundColor = self.color
                }
            }
        }
    }


    private func showToast(_ text: String, seconds: TimeInterval = 3.0) {
        toastHideWork?.cancel()
        toastText = text
        let work = DispatchWorkItem { toastText = nil }
        toastHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func currentUid() -> String? {
        guard let user = Auth.auth().currentUser, !user.isAnonymous else { return nil }
        return user.uid
    }

    private var hasSignedInRadioUser: Bool {
        currentUid() != nil
    }

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

    private func affiliationText(count: Int) -> String {
        "Member of \(max(0, count)) Radio \(max(0, count) == 1 ? "Group" : "Groups")"
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

    private func loadProfileFromSourceOfTruthIfNeeded() {
        guard hasSignedInRadioUser, !profileLoadAttempted else { return }
        profileLoadAttempted = true

        Task {
            do {
                let profile = try await profileService.loadProfile()
                await MainActor.run {
                    applyUserProfile(profile)
                }
            } catch {
                await MainActor.run {
                    showToast("Unable to load Radio Group profile. Please check your account settings.", seconds: 4.0)
                }
            }
        }
    }

    private func applyUserProfile(_ profile: UserProfile, updateDraft: Bool = true) {
        loadedUserProfile = profile
        userFirstName = profile.firstName
        userLastName = profile.lastName
        vesselName = profile.vesselName
        if updateDraft || !isEditingVesselName {
            vesselNameDraft = profile.vesselName
        }
        radioPinDisplayName = profile.radioDisplayName.isEmpty ? profile.vesselName : profile.radioDisplayName
    }

    private func saveVesselNameToAccountProfile() {
        guard hasSignedInRadioUser else {
            showToast("Sign in is required to update vessel name.", seconds: 4.0)
            return
        }

        let trimmed = vesselNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showToast("Vessel name cannot be empty.", seconds: 3.0)
            return
        }

        let cachedProfile = loadedUserProfile
        let previousVesselName = vesselName.trimmingCharacters(in: .whitespacesAndNewlines)
        isSavingVesselName = true
        Task {
            do {
                var profile: UserProfile
                if let cachedProfile {
                    profile = cachedProfile
                } else {
                    profile = try await profileService.loadProfile()
                }
                profile.vesselName = trimmed

                let currentRadioDisplayName = profile.radioDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
                if currentRadioDisplayName.isEmpty || currentRadioDisplayName == previousVesselName {
                    profile.radioDisplayName = trimmed
                }

                let saved = try await profileService.saveProfile(profile)
                var membershipUpdateError: Error?
                do {
                    try await service.updateMemberProfile(
                        firstName: saved.firstName,
                        lastName: saved.lastName,
                        vesselName: saved.vesselName
                    )
                } catch {
                    membershipUpdateError = error
                }

                await MainActor.run {
                    applyUserProfile(saved)
                    isEditingVesselName = false
                    isVesselNameFocused = false

                    if let membershipUpdateError {
                        showToast("Vessel name saved to your account, but Radio Group records could not update. \(RadioGroupService.friendlyMessage(for: membershipUpdateError))", seconds: 5.0)
                    } else {
                        showToast("Vessel name updated.", seconds: 2.5)
                    }
                }
            } catch {
                await MainActor.run {
                    showToast("Unable to update vessel name. \(UserProfileService.friendlyMessage(for: error))", seconds: 4.0)
                }
            }

            await MainActor.run {
                isSavingVesselName = false
            }
        }
    }

    private func runRadioAction(_ action: @escaping () async throws -> Void) {
        guard !isRadioGroupActionInProgress else { return }
        guard hasSignedInRadioUser else {
            showToast("Sign in is required for Radio Groups.", seconds: 4.0)
            return
        }

        isRadioGroupActionInProgress = true
        Task {
            do {
                try await action()
            } catch {
                await MainActor.run {
                    showToast(RadioGroupService.friendlyMessage(for: error), seconds: 4.0)
                }
            }
            await MainActor.run {
                isRadioGroupActionInProgress = false
            }
        }
    }

    // MARK: - Listeners

    private func startMyMembershipsListener() {
        guard let uid = currentUid() else {
            myMembershipsListener?.remove()
            myMembershipsListener = nil
            myGroupIds = []
            groupsById = [:]
            pendingJoinRequestsByGroup = [:]
            return
        }

        myMembershipsListener?.remove()
        myMembershipsListener = repository.listenMemberships(uid: uid) { memberships in
            let ids = memberships.map(\.groupId).sorted()
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

    private func startGroupListeners(groupId gid: String) {
        if groupDocListeners[gid] == nil {
            groupDocListeners[gid] = repository.listenGroup(groupId: gid) { group in
                guard let group else {
                    groupDocListeners[gid]?.remove()
                    groupDocListeners[gid] = nil
                    groupMembersListeners[gid]?.remove()
                    groupMembersListeners[gid] = nil
                    groupJoinRequestsListeners[gid]?.remove()
                    groupJoinRequestsListeners[gid] = nil
                    groupsById[gid] = nil
                    pendingJoinRequestsByGroup[gid] = nil
                    if radioGroupId == gid {
                        radioGroupId = ""
                        radioGroup.setGroupId("")
                    }
                    myGroupIds.removeAll { $0 == gid }
                    return
                }
                var g = groupsById[gid] ?? RGGroup(id: gid, name: group.name, members: [])
                g.name = group.name
                groupsById[gid] = g
            }
        }

        if groupMembersListeners[gid] == nil {
            groupMembersListeners[gid] = repository.listenMembers(groupId: gid) { members in
                let mapped: [RGMember] = members.map {
                    RGMember(
                        id: $0.uid,
                        name: $0.displayName,
                        vesselName: $0.vesselName,
                        role: $0.role.rawValue,
                        canApprove: $0.canApprove || $0.role.canApprove,
                        publicMembershipCount: $0.publicMembershipCount
                    )
                }
                var g = groupsById[gid] ?? RGGroup(id: gid, name: "Radio Group", members: [])
                g.members = mapped
                groupsById[gid] = g
                startJoinRequestsListener(groupId: gid)
            }
        }
    }

    private func startJoinRequestsListener(groupId gid: String) {
        guard groupJoinRequestsListeners[gid] == nil else { return }

        groupJoinRequestsListeners[gid] = repository.listenPendingJoinRequests(groupId: gid) { requests in
            pendingJoinRequestsByGroup[gid] = requests.map {
                JoinRequestRow(
                    id: $0.requestedByUid,
                    requestedByName: $0.requestedByName,
                    requestedVesselName: $0.requestedVesselName,
                    createdAt: $0.createdAt
                )
            }
        }
    }

    private func attachMyJoinRequestListener() {
        myJoinRequestListener?.remove()
        myJoinRequestListener = nil

        let gid = pendingJoinGroupId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gid.isEmpty else { return }

        guard let uid = currentUid() else { return }
        myJoinRequestListener = repository.listenJoinRequest(groupId: gid, uid: uid) { request in
            guard let request else { return }
            if request.status == "approved" {
                let joinedName = pendingJoinGroupName
                pendingJoinGroupId = ""
                pendingJoinGroupName = ""
                showJoinResultPopup(isSuccess: true, groupName: joinedName)
                setActivePinsGroup(gid)
            } else if request.status == "rejected" {
                let rejectedName = pendingJoinGroupName
                pendingJoinGroupId = ""
                pendingJoinGroupName = ""
                showJoinResultPopup(isSuccess: false, groupName: rejectedName)
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
        runRadioAction {
            let result = try await service.createRadioGroup(
                groupName: createGroupNameInput,
                firstName: createAdminFirstNameInput,
                lastName: createAdminLastNameInput,
                vesselName: vesselName
            )

            await MainActor.run {
                userFirstName = createAdminFirstNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                userLastName = createAdminLastNameInput.trimmingCharacters(in: .whitespacesAndNewlines)

                setActivePinsGroup(result.groupId)
                let color = WaypointPinColor.safe(
                    rawValue: defaultWaypointPinColorID,
                    fallback: WaypointColorPreferences.ensureLocalDefaultColor()
                )
                defaultWaypointPinColorID = color.rawValue
                radioGroup.updateWaypointPinColorForCurrentUser(colorID: color.rawValue)
                inviteCodeToShow = result.inviteCode
                showInviteCode = true
                showToast("Radio Group created.", seconds: 3.0)
            }
        }
    }

    private func submitJoinRequestFirestore() {
        let code = joinCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let name = fullName(first: joinMemberFirstNameInput, last: joinMemberLastNameInput)
        guard !code.isEmpty, !name.isEmpty else { return }

        runRadioAction {
            let result = try await service.requestJoinGroup(
                inviteCode: code,
                firstName: joinMemberFirstNameInput,
                lastName: joinMemberLastNameInput,
                vesselName: vesselName
            )

            await MainActor.run {
                pendingJoinGroupId = result.groupId
                pendingJoinGroupName = result.groupName

                userFirstName = joinMemberFirstNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                userLastName = joinMemberLastNameInput.trimmingCharacters(in: .whitespacesAndNewlines)

                attachMyJoinRequestListener()
                showToast("Your request has been sent to the Radio Group for approval", seconds: 4.0)
            }
        }
    }

    private func approve(reqID: String, groupId gid: String, requesterName: String) {
        runRadioAction {
            try await service.approveJoinRequest(groupId: gid, requesterUid: reqID)
            await MainActor.run {
                showToast("Approved.", seconds: 2.5)
            }
        }
    }

    private func reject(reqID: String, groupId gid: String) {
        runRadioAction {
            try await service.rejectJoinRequest(groupId: gid, requesterUid: reqID)
            await MainActor.run {
                showToast("Rejected.", seconds: 2.5)
            }
        }
    }

    private func leaveGroup(gid: String) {
        runRadioAction {
            try await service.leaveGroup(groupId: gid)
            await MainActor.run {
                if radioGroupId == gid {
                    radioGroup.stopLiveSharing()
                    radioGroupId = ""
                    radioGroup.setGroupId("")
                }
                showToast("Left Radio Group.", seconds: 3.0)
            }
        }
    }


    // MARK: - Info Row Helpers

    private var profileFullNameDisplay: String {
        let name = fullName(first: userFirstName, last: userLastName)
        return name.isEmpty ? "Not available" : name
    }

    @ViewBuilder
    private func readOnlyProfileRow(label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)

            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: selectorHeight, maxHeight: selectorHeight, alignment: .leading)
                .background(Color.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private var vesselNameProfileRow: some View {
        HStack(spacing: 10) {
            Text("Vessel Name")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)

            TextField(
                "",
                text: Binding(
                    get: { isEditingVesselName ? vesselNameDraft : vesselName },
                    set: { vesselNameDraft = $0 }
                ),
                prompt: Text("Enter vessel name").foregroundColor(.white.opacity(0.45))
            )
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(true)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .tint(.white)
                .padding(.horizontal, 10)
                .frame(height: selectorHeight)
                .background(Color.white.opacity(isEditingVesselName ? 0.14 : 0.10))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
                .disabled(!isEditingVesselName || isSavingVesselName)
                .focused($isVesselNameFocused)
                .onSubmit {
                    if isEditingVesselName {
                        saveVesselNameToAccountProfile()
                    }
                }

            Button {
                if isEditingVesselName {
                    saveVesselNameToAccountProfile()
                } else {
                    vesselNameDraft = vesselName
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isEditingVesselName = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isVesselNameFocused = true
                    }
                }
            } label: {
                Group {
                    if isSavingVesselName {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black)
                    } else {
                        Text(isEditingVesselName ? "Save" : "Edit")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                }
                .foregroundColor(isEditingVesselName ? .black : .white)
                .frame(width: 52, height: selectorHeight)
                .background(isEditingVesselName ? Color.white : Color.white.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(SatChartPressFeedbackButtonStyle())
            .disabled(isSavingVesselName)
        }
    }

    // MARK: - Button styling helpers

    @ViewBuilder
    private func filledActionButton(
        title: String,
        systemImage: String,
        titleColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(titleColor)
                .frame(maxWidth: .infinity, minHeight: selectorHeight, maxHeight: selectorHeight, alignment: .leading)
                .padding(.horizontal, 12)
                .background(Color.white.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    private func deleteConfirmationActionButton(
        title: String,
        systemImage: String,
        confirmationTitle: String,
        confirmationMessage: String,
        action: @escaping () -> Void
    ) -> some View {
        SatChartDeleteConfirmationButton(
            confirmationTitle: confirmationTitle,
            confirmationMessage: confirmationMessage,
            onConfirm: action
        ) { isFlashingRed in
            HStack(spacing: 8) {
                SatChartDeleteIcon(
                    systemName: systemImage,
                    isFlashingRed: isFlashingRed,
                    defaultColor: .white
                )
                Text(title)
                    .foregroundStyle(.white)
            }
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .frame(maxWidth: .infinity, minHeight: selectorHeight, maxHeight: selectorHeight, alignment: .leading)
            .padding(.horizontal, 12)
            .background(Color.white.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(SatChartPressFeedbackButtonStyle())
    }

    // MARK: - Sections

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .underline(true, color: Color.white.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 2)
    }

    @ViewBuilder
    private var myInfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("My Information")
            readOnlyProfileRow(label: "Name", value: profileFullNameDisplay)
            vesselNameProfileRow
        }
        .padding(14)
        .background(sectionBackground)
        .clipShape(RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous)
                .stroke(sectionBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var affiliationTransparencySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Radio Group Affiliation Transparency")
            Text("Members of your Radio Groups can see how many Radio Groups you belong to. This count is maintained by SatChart and shown in member rows for group safety and context.")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.84))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(sectionBackground)
        .clipShape(RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous)
                .stroke(sectionBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("My Status")

            HStack {
                Text("Live sharing")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Spacer()

                Text(radioGroup.isLiveSharing ? "On" : "Off")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(radioGroup.isLiveSharing ? .green : .red)
            }

            HStack {
                Text("Last location sent")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Spacer()

                Text(radioGroup.lastSentText)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
            }
            .padding(.top, 8)
        }
        .padding(14)
        .background(sectionBackground)
        .clipShape(RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous)
                .stroke(sectionBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var pinsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Location Pins and Live Location")
            HStack {
                Text("Location Pin Expires After")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Spacer(minLength: 10)

                Picker("", selection: $pinSettings.expiry) {
                    ForEach(PinExpiryOption.allCases) { opt in
                        Text(opt.label).tag(opt)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            HStack {
                Text("Live Location Sharing Updated")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Spacer(minLength: 10)

                Picker("", selection: $liveLocationUpdateOptionRaw) {
                    ForEach(LiveLocationUpdateOption.allCases) { opt in
                        Text(opt.label).tag(opt.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            deleteConfirmationActionButton(
                title: "Delete last pin",
                systemImage: "trash",
                confirmationTitle: "Delete last location pin?",
                confirmationMessage: "The most recent location pin you own will be deleted.",
                action: {
                    radioGroup.deleteLastPin()
                    showToast("Deleted last pin.", seconds: 2.0)
                }
            )
            deleteConfirmationActionButton(
                title: "Delete all pins",
                systemImage: "trash.slash",
                confirmationTitle: "Delete all location pins?",
                confirmationMessage: "All one-time location pins you own will be deleted and live sharing will be cleared.",
                action: {
                    radioGroup.deleteAllPins()
                    showToast("Deleted all pins.", seconds: 2.0)
                }
            )
            .padding(.top, 8)
        }
        .padding(14)
        .background(sectionBackground)
        .clipShape(RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous)
                .stroke(sectionBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var joinBannerSection: some View {
        if isPendingJoin {
            VStack(alignment: .leading, spacing: 10) {
                Text("Request Pending to join \"\(pendingJoinGroupName.isEmpty ? "Radio Group" : pendingJoinGroupName)\"")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.yellow)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            }
            .padding(14)
            .background(sectionBackground)
            .clipShape(RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous)
                    .stroke(sectionBorder, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func groupCard(for gid: String) -> some View {
        if let g = groupsById[gid] {

            // Determine founder/admin display name
            let adminMember = g.members.first(where: { $0.role.lowercased() == "owner" || $0.role.lowercased() == "admin" })
            let founderName: String = (adminMember?.name.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? (g.members.first?.name.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "—"

            // Members excluding founder/admin (for Member 2, 3, ...)
            let otherMembers: [RGMember] = {
                if let adminId = adminMember?.id {
                    return g.members.filter { $0.id != adminId }
                } else {
                    guard let firstId = g.members.first?.id else { return [] }
                    return g.members.filter { $0.id != firstId }
                }
            }()

            // Status
            let isSelected = (radioGroupId == gid)
            let isEligible = (g.members.count >= 2)

            VStack(alignment: .leading, spacing: 10) {

                // Top bar: Group Name
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Group Name:")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text(g.name)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)

                    Spacer(minLength: 0)
                }

                // Status bar: Active/Inactive + helper text
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Status:")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Button {
                        if isSelected {
                            // Clear active group
                            radioGroupId = ""
                            radioGroup.setGroupId("")
                            showToast("Active group cleared.", seconds: 2.0)
                        } else {
                            guard isEligible else {
                                showToast("Location sharing is enabled when your active Radio Group has at least 2 members.", seconds: 3.0)
                                return
                            }
                            setActivePinsGroup(gid)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isSelected && isEligible {
                                Text("Active")
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.80))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                                Text("(Sharing enabled)")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white.opacity(0.75))
                            } else {
                                Text("Inactive")
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.red.opacity(0.80))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                                Text("(Select to allow sharing)")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white.opacity(0.75))
                            }
                        }
                    }
                    .buttonStyle(SatChartPressFeedbackButtonStyle())

                    Spacer(minLength: 0)
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Group Founder:")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text(founderName)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    Spacer(minLength: 0)
                }
                if let adminMember {
                    Text(affiliationText(count: adminMember.publicMembershipCount))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.72))
                        .padding(.leading, 112)
                }

                // Member rows: Member 2, Member 3, ...
                if !otherMembers.isEmpty {
                    ForEach(Array(otherMembers.enumerated()), id: \.offset) { idx, m in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("Member \(idx + 2):")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            Text(m.name)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                            Spacer(minLength: 0)
                        }
                        Text(affiliationText(count: m.publicMembershipCount))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.72))
                            .padding(.leading, 86)
                    }
                }

                // Pending approvals (admin only)
                if let uid = currentUid(),
                   let me = g.members.first(where: { $0.id == uid }),
                   me.canApprove || me.role == "owner" || me.role == "admin",
                   let pending = pendingJoinRequestsByGroup[gid],
                   !pending.isEmpty {

                    Text("Pending join requests")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    ForEach(pending) { req in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(req.requestedByName)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                            if !req.requestedVesselName.isEmpty {
                                Text(req.requestedVesselName)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white.opacity(0.72))
                            }

                            HStack(spacing: 10) {
                                Button {
                                    approve(reqID: req.id, groupId: gid, requesterName: req.requestedByName)
                                } label: {
                                    Text("Approve").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .satChartExistingButtonFeedback()
                                .tint(.green)

                                Button {
                                    reject(reqID: req.id, groupId: gid)
                                } label: {
                                    Text("Reject").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .satChartExistingButtonFeedback()
                                .tint(.red)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                filledActionButton(
                    title: "Invite New Member",
                    systemImage: "person.badge.plus",
                    titleColor: scAccent,
                    action: {
                        runRadioAction {
                            let result = try await service.rotateInviteCode(groupId: gid)
                            await MainActor.run {
                                inviteCodeToShow = result.inviteCode
                                showInviteCode = true
                                showToast("Invite code created.", seconds: 2.2)
                            }
                        }
                    }
                )
                filledActionButton(
                    title: "Leave Radio Group",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    titleColor: .red,
                    action: { confirmLeaveGroupId = gid }
                )

            }
            // ✅ Outline around each radio group card
            .padding(14)
            .background(sectionBackground)
            .clipShape(RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous)
                    .stroke(sectionBorder, lineWidth: 1)
            )
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
                ForEach(Array(myGroupIds.enumerated()), id: \.element) { idx, gid in
                    groupCard(for: gid)
                        // 1-bar space under the header for the first card
                        .padding(.top, idx == 0 ? 8 : 0)
                        // 2-bar space between subsequent cards
                        .padding(.top, idx == 0 ? 0 : 16)
                }
            }
        }
        .padding(14)
        .background(sectionBackground)
        .clipShape(RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous)
                .stroke(sectionBorder, lineWidth: 1)
        )
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
                Text("Create Radio Group")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: selectorHeight, maxHeight: selectorHeight)
                    .background(Color.white.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(SatChartPressFeedbackButtonStyle())
            .disabled(isRadioGroupActionInProgress)

            Button {
                joinMemberFirstNameInput = userFirstName
                joinMemberLastNameInput = userLastName
                joinCodeInput = ""
                showJoinFlow = true
            } label: {
                Text("Join Existing Radio Group")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: selectorHeight, maxHeight: selectorHeight)
                    .background(Color.white.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(SatChartPressFeedbackButtonStyle())
            .disabled(isRadioGroupActionInProgress)
        }
        .padding(14)
        .background(sectionBackground)
        .clipShape(RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous)
                .stroke(sectionBorder, lineWidth: 1)
        )
    }

    private var listBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                myInfoSection
                affiliationTransparencySection
                statusSection
                pinsSection
                joinBannerSection
                myGroupsSection
                actionsSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .modifier(HideScrollIndicatorsIfAvailable())
        .background(Color.clear)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    private var signInRequiredBody: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.15, blue: 0.30), Color(red: 0.01, green: 0.08, blue: 0.18)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                Text("Sign in required for Radio Groups")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Radio Groups use your SatChart account profile for group membership, approvals, shared pins, live location, and affiliation transparency.")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Radio Group Affiliation Transparency: members of your Radio Groups can see how many Radio Groups you belong to.")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.yellow.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .background(sectionBackground)
            .clipShape(RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: sectionCornerRadius, style: .continuous)
                    .stroke(sectionBorder, lineWidth: 1)
            )
            .padding(20)
        }
        .environment(\.colorScheme, .dark)
        .navigationTitle("Radio Group")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var baseChrome: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.15, blue: 0.30), Color(red: 0.01, green: 0.08, blue: 0.18)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: [.top, .leading, .trailing])

            if hasSignedInRadioUser {
                listBody
            } else {
                signInRequiredBody
            }
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
                        .background(scSurface.opacity(0.95))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .padding(.bottom, 0)
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
                        .background(scSurfaceAlt)
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
        ZStack {
            menuBlue.ignoresSafeArea()

            // Force the underlying hosting/container views to menu blue so the exposed area
            // above the tab bar matches the tab bar color instead of appearing black/white/gray.
            HostingBackgroundFixer(color: menuBlueUIColor)
                .frame(width: 0, height: 0)

            toastsOverlay
        }
        .onAppear {
                MenuAppearance.applyNavBar()
                loadProfileFromSourceOfTruthIfNeeded()
                startMyMembershipsListener()

                if isPendingJoin {
                    // Ensure listener is attached even if the page is already open.
                    attachMyJoinRequestListener()
                }
            }
        .onReceive(NotificationCenter.default.publisher(for: .satChartUserProfileDidChange)) { notification in
            if let profile = notification.object as? UserProfile {
                applyUserProfile(profile, updateDraft: false)
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

                    Text("Raw invite codes are shown only here and are stored by SatChart as a hashed invite with an expiration.")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.72))
                        .multilineTextAlignment(.center)

                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = inviteCodeToShow
                            showToast("Invite code copied.", seconds: 2.0)
                        } label: {
                            Text("Copy").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .satChartExistingButtonFeedback()
                        .tint(scAccent)

                        Button { showInviteCode = false } label: {
                            Text("Close").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .satChartExistingButtonFeedback()
                        .tint(.gray)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(scBackground.ignoresSafeArea())
                .environment(\.colorScheme, .dark)
            }
            .sheet(isPresented: $showCreateFlow) {
                VStack(spacing: 16) {
                    Text("Create Radio Group")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)

                    Text("Radio Group Affiliation Transparency: members of your Radio Groups can see how many Radio Groups you belong to.")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.yellow.opacity(0.92))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

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
                    .satChartExistingButtonFeedback()
                    .tint(canSubmitCreateFlow && !isRadioGroupActionInProgress ? .blue : .gray)
                    .disabled(!canSubmitCreateFlow || isRadioGroupActionInProgress)

                    Button { showCreateFlow = false } label: {
                        Text("Cancel").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .satChartExistingButtonFeedback()
                    .tint(.gray)
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(scBackground.ignoresSafeArea())
                .environment(\.colorScheme, .dark)
            }
            .sheet(isPresented: $showJoinFlow) {
                VStack(spacing: 16) {
                    Text("Join Existing Radio Group")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)

                    Text("Radio Group Affiliation Transparency: members of this Radio Group can see how many Radio Groups you belong to.")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.yellow.opacity(0.92))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

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
                    .satChartExistingButtonFeedback()
                    .tint(canSubmitJoinFlow && !isRadioGroupActionInProgress ? .blue : .gray)
                    .disabled(!canSubmitJoinFlow || isRadioGroupActionInProgress)

                    Button { showJoinFlow = false } label: {
                        Text("Cancel").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .satChartExistingButtonFeedback()
                    .tint(.gray)
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(scBackground.ignoresSafeArea())
                .environment(\.colorScheme, .dark)
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
    }
}
