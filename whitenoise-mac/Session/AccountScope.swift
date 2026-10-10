import Foundation
import MarmotKit
import Observation

/// Owns everything whose lifetime is exactly one signed-in account.
///
/// Feature subscriptions register their cancellation with this scope instead of
/// relying on account-id checks after every await. Replacing the scope therefore
/// tears down the old account before the new account can publish view state.
@MainActor
@Observable
final class AccountScope {
    private(set) var isCancelled = false
    #if WN_EXPERIMENTAL_DEVICE_SYNC
        private(set) var historyConsentReview: HistoryConsentReviewViewModel?

        func installHistoryConsentReview(_ model: HistoryConsentReviewViewModel) {
            guard !isCancelled, historyConsentReview == nil else {
                model.invalidate()
                return
            }
            historyConsentReview = model
            addCancellation { model.invalidate() }
        }

        let history: NativeHistoryAccountOwner
        @ObservationIgnored private var historySources: [String: (model: HistorySourceViewModel, cancellation: UUID)] =
            [:]

        func historySourceModel(
            groupIdHex: String,
            query:
                @escaping @MainActor (any MarmotRuntime, String, String) async throws -> [HistoryTransferRecipientFfi] =
                {
                    runtime, account, group in
                    try await runtime.historyTransferRecipients(accountRef: account, groupIdHex: group)
                },
            begin:
                @escaping @MainActor (any MarmotRuntime, String, String, Data) async throws ->
                any HistoryTransferProtocol = {
                    runtime, account, group, device in
                    try await runtime.beginHistoryTransfer(
                        accountRef: account, groupIdHex: group, recipientDevice: device)
                }
        ) -> HistorySourceViewModel {
            if let existing = historySources[groupIdHex] { return existing.model }
            let model = HistorySourceViewModel(
                groupIdHex: groupIdHex,
                query: { [weak self] in
                    guard let self, !self.isCancelled else { throw MarmotKitError.HistoryTransferClosed }
                    let values = try await query(self.runtime, self.account.accountRef, groupIdHex)
                    guard !self.isCancelled else { throw MarmotKitError.HistoryTransferClosed }
                    return values
                },
                begin: { [weak self] device in
                    guard let self, !self.isCancelled else { throw MarmotKitError.HistoryTransferClosed }
                    return try await self.history.adoptTransfer(groupIdHex: groupIdHex) { runtime, account in
                        try await begin(runtime, account, groupIdHex, device)
                    }
                })
            guard !isCancelled else {
                model.invalidate()
                return model
            }
            let cancellation = addCancellation { model.invalidate() }
            historySources[groupIdHex] = (model, cancellation)
            return model
        }

        let selectedChat: NativeSelectedChatAccountOwner
        private(set) var selectedChatTransfer: SelectedChatTransferViewModel?

        func installSelectedChatTransfer(_ model: SelectedChatTransferViewModel) {
            guard !isCancelled, selectedChatTransfer == nil else {
                model.invalidate()
                return
            }
            selectedChatTransfer = model
            addCancellation { model.invalidate() }
        }

        private(set) var deviceVerification: DeviceVerificationViewModel?

        private(set) var deviceEnrollment: DeviceEnrollmentViewModel?
        private(set) var deviceEnrollmentApproval: DeviceEnrollmentApprovalViewModel?

        func installDeviceEnrollment(_ model: DeviceEnrollmentViewModel) {
            guard !isCancelled else {
                model.invalidate()
                return
            }
            if deviceEnrollment == nil { addCancellation { [weak self] in self?.deviceEnrollment?.invalidate() } }
            deviceEnrollment?.invalidate()
            deviceEnrollment = model
        }
        func installDeviceEnrollmentApproval(_ model: DeviceEnrollmentApprovalViewModel) {
            guard !isCancelled else {
                model.invalidate()
                return
            }
            if deviceEnrollmentApproval == nil {
                addCancellation { [weak self] in self?.deviceEnrollmentApproval?.invalidate() }
            }
            deviceEnrollmentApproval?.invalidate()
            deviceEnrollmentApproval = model
        }

        func installDeviceVerification(_ model: DeviceVerificationViewModel) {
            guard !isCancelled, deviceVerification == nil else { return }
            deviceVerification = model
            addCancellation { model.invalidate() }
        }
    #endif
    let account: AccountItem
    @ObservationIgnored let runtime: any MarmotRuntime
    let settingsModel: SettingsViewModel
    let chatListModel: ChatListViewModel
    let attentionModel: AccountAttentionViewModel
    let attachmentPolicy: AttachmentPolicyController
    let avatarAssets: AvatarAssetStore
    let blockedUsers: BlockedUsersViewModel
    let onboarding: OnboardingCoordinator
    let historyNotices: HistoryNoticesViewModel
    let productAnalytics: ProductAnalyticsRecorder
    private(set) var selectedConversationModel: ConversationViewModel?
    @ObservationIgnored private var attachmentPolicyTask: Task<Void, Never>?
    @ObservationIgnored private var cancellations: [UUID: @MainActor () -> Void] = [:]
    @ObservationIgnored private var conversations: [String: (model: ConversationViewModel, cancellation: UUID)] = [:]
    @ObservationIgnored private var synchronizedHistoryReaders:
        [String: (model: SynchronizedHistoryViewModel, cancellation: UUID)] = [:]
    @ObservationIgnored private var attachments: [String: (model: AttachmentViewModel, cancellation: UUID)] = [:]
    @ObservationIgnored private var groupSafety: [String: GroupSafetyViewModel] = [:]

    init(
        account: AccountItem,
        runtime: any MarmotRuntime,
        relayListsDidChange: @escaping @MainActor () -> Void = {}
    ) {
        let attachmentPolicy = AttachmentPolicyController(accountRef: account.accountRef, runtime: runtime)
        let blockedUsers = BlockedUsersViewModel(accountRef: account.accountRef, runtime: runtime)
        let productAnalytics = ProductAnalyticsRecorder()
        #if WN_EXPERIMENTAL_DEVICE_SYNC
            self.history = NativeHistoryAccountOwner(accountRef: account.accountRef, runtime: runtime)
            self.selectedChat = NativeSelectedChatAccountOwner(accountRef: account.accountRef, runtime: runtime)
        #endif
        self.account = account
        self.runtime = runtime
        self.settingsModel = SettingsViewModel(
            account: account,
            runtime: runtime,
            attachmentPolicyController: attachmentPolicy,
            blockedUsersModel: blockedUsers,
            productAnalytics: productAnalytics,
            relayListsDidChange: relayListsDidChange
        )
        self.chatListModel = ChatListViewModel(
            account: account,
            runtime: runtime,
            blockedUsersModel: blockedUsers
        )
        self.attentionModel = AccountAttentionViewModel(runtime: runtime)
        self.attachmentPolicy = attachmentPolicy
        self.avatarAssets = AvatarAssetStore(accountRef: account.accountRef, runtime: runtime)
        self.blockedUsers = blockedUsers
        self.onboarding = OnboardingCoordinator(accountRef: account.accountRef, runtime: runtime)
        self.historyNotices = HistoryNoticesViewModel(
            accountRef: account.accountRef,
            accountIdHex: account.accountIdHex,
            runtime: runtime
        )
        self.productAnalytics = productAnalytics
        #if WN_EXPERIMENTAL_DEVICE_SYNC
            addCancellation { [selectedChat] in selectedChat.invalidate() }
            addCancellation { [history] in history.invalidate() }
        #endif
    }

    func start(connectivityAvailable: Bool) {
        chatListModel.start()
        attentionModel.start()
        blockedUsers.start()
        onboarding.start()
        historyNotices.start()
        let diagnosticsTask = Task { [settingsModel] in
            await settingsModel.diagnostics.load()
        }
        addCancellation {
            [chatListModel, attentionModel, blockedUsers, onboarding, historyNotices, productAnalytics, settingsModel]
            in
            chatListModel.stop()
            attentionModel.stop()
            blockedUsers.stop()
            onboarding.stop()
            historyNotices.stop()
            productAnalytics.deactivate()
            settingsModel.deactivate()
        }
        own(diagnosticsTask)
        updateConnectivity(available: connectivityAvailable)
    }

    func updateConnectivity(available: Bool) {
        attachmentPolicyTask?.cancel()
        attachmentPolicyTask = Task { [attachmentPolicy] in
            await attachmentPolicy.refresh(connectivityAvailable: available)
        }
    }

    @discardableResult
    func own(_ task: Task<Void, Never>) -> UUID {
        addCancellation { task.cancel() }
    }

    @discardableResult
    func addCancellation(_ cancellation: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        cancellations[id] = cancellation
        return id
    }

    func releaseCancellation(_ id: UUID) {
        cancellations[id] = nil
    }

    func synchronizedHistoryModel(
        groupIdHex: String
    ) -> SynchronizedHistoryViewModel {
        synchronizedHistoryModel(groupIdHex: groupIdHex) { [runtime] account, group, cursor, limit in
            try runtime.synchronizedHistoryPage(
                accountRef: account, groupIdHex: group, afterMessageIdHex: cursor, limit: limit)
        }
    }

    func synchronizedHistoryModel(
        groupIdHex: String,
        read: @escaping SynchronizedHistoryViewModel.Reader
    ) -> SynchronizedHistoryViewModel {
        if let existing = synchronizedHistoryReaders[groupIdHex] { return existing.model }
        let model = SynchronizedHistoryViewModel(accountRef: account.accountRef, groupIdHex: groupIdHex, read: read)
        guard !isCancelled else {
            model.invalidate()
            return model
        }
        let cancellation = addCancellation { [model] in model.invalidate() }
        synchronizedHistoryReaders[groupIdHex] = (model, cancellation)
        return model
    }

    /// Conversations open in `.automatic`: MarmotKit anchors the window on the first unread row,
    /// which the transcript positions under a "New messages" divider, else on the latest row.
    func conversationModel(
        groupIdHex: String,
        mode: ConversationOpenModeFfi = .automatic,
        messageIdHex: String? = nil
    ) -> ConversationViewModel {
        if let existing = conversations[groupIdHex]?.model {
            return existing
        }
        let model = ConversationViewModel(
            account: account,
            groupIdHex: groupIdHex,
            runtime: runtime,
            productAnalytics: productAnalytics
        )
        let cancellation = addCancellation { [model] in model.stop() }
        conversations[groupIdHex] = (model, cancellation)
        model.start(mode: mode, messageIdHex: messageIdHex)
        return model
    }

    @discardableResult
    func selectConversation(
        groupIdHex: String,
        mode: ConversationOpenModeFfi = .automatic,
        messageIdHex: String? = nil
    ) -> ConversationViewModel {
        if let selectedConversationModel, selectedConversationModel.groupIdHex == groupIdHex {
            return selectedConversationModel
        }
        let staleGroupIds = conversations.keys.filter { $0 != groupIdHex }
        for existingGroupId in staleGroupIds {
            releaseConversation(groupIdHex: existingGroupId)
        }
        let model = conversationModel(groupIdHex: groupIdHex, mode: mode, messageIdHex: messageIdHex)
        selectedConversationModel = model
        return model
    }

    func releaseSelectedConversation() {
        guard let groupIdHex = selectedConversationModel?.groupIdHex else { return }
        selectedConversationModel = nil
        releaseConversation(groupIdHex: groupIdHex)
    }

    func releaseConversation(groupIdHex: String) {
        #if WN_EXPERIMENTAL_DEVICE_SYNC
            if let source = historySources.removeValue(forKey: groupIdHex) {
                releaseCancellation(source.cancellation)
                source.model.invalidate()
            }
        #endif
        if let history = synchronizedHistoryReaders.removeValue(forKey: groupIdHex) {
            releaseCancellation(history.cancellation)
            history.model.invalidate()
        }
        guard let owned = conversations.removeValue(forKey: groupIdHex) else { return }
        if selectedConversationModel === owned.model {
            selectedConversationModel = nil
        }
        releaseCancellation(owned.cancellation)
        owned.model.stop()
        releaseAttachments(groupIdHex: groupIdHex)
        groupSafety[groupIdHex] = nil
    }

    func attachmentModel(groupIdHex: String) -> AttachmentViewModel {
        if let existing = attachments[groupIdHex]?.model {
            return existing
        }
        let model = AttachmentViewModel(accountRef: account.accountRef, groupIdHex: groupIdHex, runtime: runtime)
        let cancellation = addCancellation { [model] in model.stopTransferObservation() }
        attachments[groupIdHex] = (model, cancellation)
        return model
    }

    func releaseAttachments(groupIdHex: String) {
        guard let owned = attachments.removeValue(forKey: groupIdHex) else { return }
        releaseCancellation(owned.cancellation)
        owned.model.stopTransferObservation()
    }

    func safetyModel(groupIdHex: String) -> GroupSafetyViewModel {
        if let existing = groupSafety[groupIdHex] { return existing }
        let model = GroupSafetyViewModel(
            accountRef: account.accountRef,
            groupIdHex: groupIdHex,
            runtime: runtime,
            historyNotices: historyNotices
        )
        groupSafety[groupIdHex] = model
        return model
    }

    func cancelAll() async {
        isCancelled = true
        attachmentPolicyTask?.cancel()
        attachmentPolicyTask = nil
        let pending = Array(cancellations.values)
        cancellations.removeAll()
        selectedConversationModel = nil
        conversations.removeAll()
        synchronizedHistoryReaders.removeAll()
        #if WN_EXPERIMENTAL_DEVICE_SYNC
            historySources.removeAll()
        #endif
        attachments.removeAll()
        groupSafety.removeAll()
        for cancel in pending {
            cancel()
        }
        await attachmentPolicy.revoke()
    }
}
