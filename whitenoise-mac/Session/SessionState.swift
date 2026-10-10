import Foundation
import MarmotKit
import Observation

/// Class runtimes have a stable instance identity; value implementations deliberately
/// provide no preservation identity rather than relying on transient AnyObject boxes.
nonisolated func nativeRuntimeObjectIdentity(_ runtime: any MarmotRuntime) -> ObjectIdentifier? {
    guard Mirror(reflecting: runtime).displayStyle == .class else { return nil }
    return ObjectIdentifier(runtime as AnyObject)
}

/// Per-launch state. The shell replaces `accountScope` whenever the selected
/// identity changes, making account teardown a lifetime boundary rather than a
/// checklist of fields to reset on `WorkspaceState`.
@MainActor
@Observable
final class SessionState {
    private(set) var accountScope: AccountScope?
    /// The app shell has two independent task owners (bootstrap and account-id observation), so
    /// cancelling either task cannot supersede an activation already suspended in old-scope
    /// revocation. This ticket lets only the most recent caller install a replacement scope.
    @ObservationIgnored private var activationToken = UUID()

    #if WN_EXPERIMENTAL_DEVICE_SYNC
        private var retiringHistoryOwners: [NativeHistoryAccountOwner] = []
        private var retiringSelectedChatOwners: [NativeSelectedChatAccountOwner] = []

        private(set) var deviceLinkingScope: DeviceLinkingScope?
        private(set) var retiringDeviceLinkingScope: DeviceLinkingScope?
        // SDK factories may ignore Swift task cancellation and return after A→B→A.
        // This native ownership ticket rejects their late original object; it grants nothing.
        @ObservationIgnored private var deviceLinkingEpoch = UUID()
        @ObservationIgnored private var deviceLinkingCleanup: Task<Void, Error>?
        @ObservationIgnored private var deviceLinkingCancellation: (scope: AccountScope, id: UUID)?
        @ObservationIgnored private var pendingDeviceLinkingFactory:
            (
                id: UUID, task: Task<any DeviceLinkingSessionProtocol, Error>
            )?

        private(set) var deviceLinkingApprovalScope: NativeDeviceLinkingApprovalScope?
        private var retiringApprovalScopes: [NativeDeviceLinkingApprovalScope] = []
        var retiringDeviceLinkingApprovalScope: NativeDeviceLinkingApprovalScope? { retiringApprovalScopes.first }
        // SDK e6 bounds its returned originals to128; refusal must not implicitly Drop them.
        private var unselectedApprovalScopes: [NativeDeviceLinkingApprovalScope] = []
        @ObservationIgnored private var pendingApprovalFactory:
            (id: UUID, task: Task<[any DeviceLinkingApprovalProtocol], Error>)?
        @ObservationIgnored private var approvalCleanup: Task<Void, Error>?
        @ObservationIgnored private var approvalCancellation: (scope: AccountScope, id: UUID)?

        func makeDeviceEnrollmentModel() throws -> DeviceEnrollmentViewModel {
            guard let account = accountScope, !account.isCancelled, let original = deviceLinkingScope else {
                throw MarmotKitError.DeviceLinkingNotReady
            }
            if let held = account.deviceEnrollment, held.isActive { return held }
            let epoch = deviceLinkingEpoch
            let selection = activationToken
            let current: @MainActor () -> Bool = { [weak self, weak account, weak original] in
                guard let self, let account, let original else { return false }
                return self.accountScope === account && !account.isCancelled && self.deviceLinkingScope === original
                    && self.deviceLinkingEpoch == epoch && self.activationToken == selection
            }
            let model = DeviceEnrollmentViewModel(
                original: original, isCurrent: current,
                cancel: { [weak self] in
                    guard let self else { throw MarmotKitError.DeviceLinkingClosed }
                    if current() {
                        try await self.cancelDeviceLinking()
                    } else {
                        guard self.retiringDeviceLinkingScope === original else {
                            throw MarmotKitError.DeviceLinkingClosed
                        }
                        try await self.retryDeviceLinkingCleanup()
                    }
                }, enrollmentSupported: account.runtime.deviceLinkingCapabilities().enrollmentSupported
            )
            account.installDeviceEnrollment(model)
            return model
        }

        func makeDeviceEnrollmentApprovalModel() async throws -> DeviceEnrollmentApprovalViewModel {
            guard let account = accountScope, !account.isCancelled else { throw MarmotKitError.DeviceLinkingClosed }
            let epoch = deviceLinkingEpoch
            let selection = activationToken
            let original = try await pendingOwnedDeviceLinkingApproval()
            guard accountScope === account, !account.isCancelled, epoch == deviceLinkingEpoch,
                selection == activationToken, deviceLinkingApprovalScope === original
            else { throw MarmotKitError.DeviceLinkingClosed }
            if let held = account.deviceEnrollmentApproval, held.isActive { return held }
            let current: @MainActor () -> Bool = { [weak self, weak account, weak original] in
                guard let self, let account, let original else { return false }
                return self.accountScope === account && !account.isCancelled
                    && self.deviceLinkingApprovalScope === original && self.deviceLinkingEpoch == epoch
                    && self.activationToken == selection
            }
            let model = DeviceEnrollmentApprovalViewModel(original: original, isCurrent: current) { [weak self] in
                guard let self else { throw MarmotKitError.DeviceLinkingClosed }
                if current() {
                    try await self.cancelDeviceLinking()
                } else {
                    guard self.retiringApprovalScopes.contains(where: { $0 === original }) else {
                        throw MarmotKitError.DeviceLinkingClosed
                    }
                    try await self.retryDeviceLinkingCleanup()
                }
            }
            account.installDeviceEnrollmentApproval(model)
            return model
        }

        func pendingOwnedDeviceLinkingApproval() async throws -> NativeDeviceLinkingApprovalScope {
            try await adoptDeviceLinkingApprovalBatch { runtime, accountRef in
                try await runtime.pendingDeviceLinkingApprovals(accountRef: accountRef)
            }
        }

        func adoptDeviceLinkingApprovalBatch(
            _ factory:
                @escaping @MainActor (any MarmotRuntime, String) async throws -> [any DeviceLinkingApprovalProtocol]
        ) async throws -> NativeDeviceLinkingApprovalScope {
            guard let scope = accountScope, !scope.isCancelled, pendingApprovalFactory == nil else {
                throw CancellationError()
            }
            let epoch = deviceLinkingEpoch
            let selection = activationToken
            try await retryDeviceLinkingCleanup()
            guard !Task.isCancelled, accountScope === scope, !scope.isCancelled,
                epoch == deviceLinkingEpoch, selection == activationToken, pendingApprovalFactory == nil
            else { throw CancellationError() }
            if let held = deviceLinkingApprovalScope {
                let snapshot = try await held.snapshot()
                guard accountScope === scope, !scope.isCancelled, epoch == deviceLinkingEpoch,
                    selection == activationToken, deviceLinkingApprovalScope === held
                else { throw CancellationError() }
                switch snapshot.phase {
                case .awaitingApproval, .approvedAwaitingPacket, .awaitingSettlement: return held
                case .settled, .cancelled, .expired: throw MarmotKitError.DeviceLinkingClosed
                }
            }
            guard unselectedApprovalScopes.isEmpty else { throw MarmotKitError.DeviceLinkingNotReady }
            return try await acquireDeviceLinkingApproval(factory, scope: scope, epoch: epoch, selection: selection)
        }

        private func acquireDeviceLinkingApproval(
            _ factory:
                @escaping @MainActor (any MarmotRuntime, String) async throws -> [any DeviceLinkingApprovalProtocol],
            scope: AccountScope, epoch: UUID, selection: UUID
        ) async throws -> NativeDeviceLinkingApprovalScope {
            let id = UUID()
            let task = Task {
                try Task.checkCancellation()
                return try await factory(scope.runtime, scope.account.accountRef)
            }
            pendingApprovalFactory = (id, task)
            let cancellation = scope.addCancellation { task.cancel() }
            defer {
                scope.releaseCancellation(cancellation)
                if pendingApprovalFactory?.id == id { pendingApprovalFactory = nil }
            }
            let originals = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            let owners = originals.map {
                NativeDeviceLinkingApprovalScope(accountRef: scope.account.accountRef, approval: $0)
            }
            guard !Task.isCancelled, accountScope === scope, !scope.isCancelled,
                selection == activationToken, epoch == deviceLinkingEpoch
            else {
                for owner in owners { owner.invalidate() }
                retiringApprovalScopes.append(contentsOf: owners)
                try await cancelRetiringApprovalScopes()
                throw CancellationError()
            }
            guard owners.count == 1, let owner = owners.first else {
                unselectedApprovalScopes = owners
                // Unselected originals still belong to this actual account lifetime.
                if !owners.isEmpty {
                    let token = scope.addCancellation { [weak self] in self?.invalidateDeviceLinking() }
                    approvalCancellation = (scope, token)
                }
                throw MarmotKitError.DeviceLinkingNotReady
            }
            deviceLinkingApprovalScope = owner
            let token = scope.addCancellation { [weak self] in
                guard let self, self.deviceLinkingApprovalScope === owner else { return }
                self.invalidateDeviceLinking()
            }
            approvalCancellation = (scope, token)
            return owner
        }

        private func invalidateDeviceLinkingApprovals() {
            pendingApprovalFactory?.task.cancel()
            if let cancellation = approvalCancellation {
                cancellation.scope.releaseCancellation(cancellation.id)
                approvalCancellation = nil
            }
            var owners = unselectedApprovalScopes
            unselectedApprovalScopes = []
            if let owner = deviceLinkingApprovalScope { owners.append(owner) }
            deviceLinkingApprovalScope = nil
            for owner in owners { owner.invalidate() }
            retiringApprovalScopes.append(contentsOf: owners)
            if !owners.isEmpty { approvalCleanup = Task { try await self.cancelRetiringApprovalScopes() } }
        }

        private func retryApprovalCleanup() async throws {
            do {
                if let cleanup = approvalCleanup {
                    try await cleanup.value
                } else {
                    try await cancelRetiringApprovalScopes()
                }
                approvalCleanup = nil
            } catch {
                approvalCleanup = nil
                throw error
            }
        }

        private func cancelRetiringApprovalScopes() async throws {
            var firstError: Error?
            for owner in retiringApprovalScopes {
                do {
                    try await owner.cancel()
                    retiringApprovalScopes.removeAll { $0 === owner }
                } catch { if firstError == nil { firstError = error } }
            }
            if let firstError { throw firstError }
        }

        private func installSelectedChatTransfer(on account: AccountScope) {
            let current: @MainActor () -> Bool = { [weak self, weak account] in
                guard let self, let account else { return false }
                return self.accountScope === account && !account.isCancelled && account.selectedChat.isActive
            }
            account.installSelectedChatTransfer(
                SelectedChatTransferViewModel(
                    begin: { [weak self, weak account] group, target in
                        guard let self, let account, current() else { throw MarmotKitError.SelectedChatCopyClosed }
                        let original = try await self.beginSelectedChatCopy(
                            groupIdHex: group, linkedRosterSelector: target)
                        guard current(), account.selectedChat.copy === original else {
                            throw MarmotKitError.SelectedChatCopyClosed
                        }
                        return SelectedChatCopyViewModel(
                            original: original,
                            isCurrent: { [weak original, weak account] in
                                current() && original != nil && account?.selectedChat.copy === original
                            })
                    },
                    receive: { [weak self, weak account] packet in
                        guard let self, let account, current() else { throw MarmotKitError.SelectedChatCopyClosed }
                        let original = try await self.receiveSelectedChatCopyRequest(packet: packet)
                        guard current(), account.selectedChat.consent === original else {
                            throw MarmotKitError.SelectedChatCopyClosed
                        }
                        return SelectedChatConsentViewModel(
                            original: original,
                            isCurrent: { [weak original, weak account] in
                                current() && original != nil && account?.selectedChat.consent === original
                            })
                    },
                    targets: { [weak account] in
                        guard let account, current() else { throw MarmotKitError.SelectedChatCopyClosed }
                        let values = try await account.runtime.deviceLinkingTargets(
                            accountRef: account.account.accountRef)
                        guard current() else { throw MarmotKitError.SelectedChatCopyClosed }
                        return values
                    },
                    isCurrent: current))
        }

        func adoptHistoryTransferFactory(
            groupIdHex: String,
            _ factory: @escaping @MainActor (any MarmotRuntime, String) async throws -> any HistoryTransferProtocol
        ) async throws -> NativeHistoryActionScope {
            guard let account = accountScope, !account.isCancelled else { throw MarmotKitError.HistoryTransferClosed }
            try retryHistoryCleanup()
            guard accountScope === account, !account.isCancelled else { throw MarmotKitError.HistoryTransferClosed }
            return try await account.history.adoptTransfer(groupIdHex: groupIdHex, factory)
        }
        func adoptHistoryConsentFactory(
            _ factory: @escaping @MainActor (any MarmotRuntime, String) async throws -> [any HistoryConsentProtocol]
        ) async throws -> [NativeHistoryActionScope] {
            guard let account = accountScope, !account.isCancelled else { throw MarmotKitError.HistoryTransferClosed }
            try retryHistoryCleanup()
            guard accountScope === account, !account.isCancelled else { throw MarmotKitError.HistoryTransferClosed }
            return try await account.history.adoptConsents(factory)
        }
        func beginHistoryTransfer(groupIdHex: String, recipientDevice: Data) async throws -> NativeHistoryActionScope {
            try await adoptHistoryTransferFactory(groupIdHex: groupIdHex) { runtime, accountRef in
                try await runtime.beginHistoryTransfer(
                    accountRef: accountRef, groupIdHex: groupIdHex, recipientDevice: recipientDevice)
            }
        }
        func pendingHistoryRequests() async throws -> [NativeHistoryActionScope] {
            try await adoptHistoryConsentFactory { runtime, accountRef in
                try await runtime.pendingHistoryRequests(accountRef: accountRef)
            }
        }
        private func invalidateHistory() {
            guard let owner = accountScope?.history else { return }
            owner.invalidate()
            if !retiringHistoryOwners.contains(where: { $0 === owner }) { retiringHistoryOwners.append(owner) }
        }
        func retryHistoryCleanup() throws {
            var firstError: Error?
            for owner in retiringHistoryOwners {
                do {
                    try owner.retryCleanup()
                    retiringHistoryOwners.removeAll { $0 === owner }
                } catch { if firstError == nil { firstError = error } }
            }
            if let firstError { throw firstError }
        }

        func beginSelectedChatCopy(groupIdHex: String, linkedRosterSelector: Data) async throws
            -> NativeSelectedChatCopyScope
        {
            try await adoptSelectedChatCopyFactory { runtime, accountRef in
                try await runtime.beginSelectedChatCopy(
                    accountRef: accountRef, groupIdHex: groupIdHex, linkedRosterSelector: linkedRosterSelector)
            }
        }
        func receiveSelectedChatCopyRequest(packet: Data) async throws -> NativeSelectedChatConsentScope {
            try await adoptSelectedChatConsentFactory { runtime, accountRef in
                try await runtime.receiveSelectedChatCopyRequest(accountRef: accountRef, packet: packet)
            }
        }
        func adoptSelectedChatCopyFactory(
            _ factory: @escaping @MainActor (any MarmotRuntime, String) async throws -> any SelectedChatCopyProtocol
        ) async throws -> NativeSelectedChatCopyScope {
            guard let account = accountScope, !account.isCancelled else { throw MarmotKitError.SelectedChatCopyClosed }
            try await retrySelectedChatCleanup()
            guard accountScope === account, !account.isCancelled else { throw MarmotKitError.SelectedChatCopyClosed }
            return try await account.selectedChat.adoptCopy(factory)
        }
        func adoptSelectedChatConsentFactory(
            _ factory: @escaping @MainActor (any MarmotRuntime, String) async throws -> any SelectedChatConsentProtocol
        ) async throws -> NativeSelectedChatConsentScope {
            guard let account = accountScope, !account.isCancelled else { throw MarmotKitError.SelectedChatCopyClosed }
            try await retrySelectedChatCleanup()
            guard accountScope === account, !account.isCancelled else { throw MarmotKitError.SelectedChatCopyClosed }
            return try await account.selectedChat.adoptConsent(factory)
        }
        private func invalidateSelectedChat() {
            guard let owner = accountScope?.selectedChat else { return }
            owner.invalidate()
            if !retiringSelectedChatOwners.contains(where: { $0 === owner }) {
                retiringSelectedChatOwners.append(owner)
            }
        }
        func retrySelectedChatCleanup() async throws {
            var firstError: Error?
            for owner in retiringSelectedChatOwners {
                do {
                    try await owner.retryCleanup()
                    retiringSelectedChatOwners.removeAll { $0 === owner }
                } catch { if firstError == nil { firstError = error } }
            }
            if let firstError { throw firstError }
        }
        private func retryNativeCleanup() async throws {
            var firstError: Error?
            do { try await retryDeviceLinkingCleanup() } catch { firstError = error }
            do { try await retrySelectedChatCleanup() } catch { if firstError == nil { firstError = error } }
            do { try retryHistoryCleanup() } catch { if firstError == nil { firstError = error } }
            if let firstError { throw firstError }
        }

        func beginDeviceLinkingSession() async throws -> DeviceLinkingScope {
            try await adoptDeviceLinkingFactory { runtime, accountRef in
                try await runtime.beginDeviceLinkingSession(accountRef: accountRef)
            }
        }

        func approveDeviceLinkingSession(request: Data, target: Data?) async throws -> DeviceLinkingScope {
            try await adoptDeviceLinkingFactory { runtime, accountRef in
                try await runtime.approveDeviceLinkingSession(accountRef: accountRef, request: request, target: target)
            }
        }

        func adoptDeviceLinkingFactory(
            _ factory: @escaping @MainActor (any MarmotRuntime, String) async throws -> any DeviceLinkingSessionProtocol
        ) async throws -> DeviceLinkingScope {
            guard let scope = accountScope, !scope.isCancelled, deviceLinkingScope == nil,
                pendingDeviceLinkingFactory == nil
            else { throw CancellationError() }
            let epoch = deviceLinkingEpoch
            let selection = activationToken
            try await retryDeviceLinkingCleanup()
            guard !Task.isCancelled, accountScope === scope, !scope.isCancelled,
                epoch == deviceLinkingEpoch, selection == activationToken,
                deviceLinkingScope == nil, pendingDeviceLinkingFactory == nil
            else { throw CancellationError() }
            let id = UUID()
            let task = Task {
                try Task.checkCancellation()
                return try await factory(scope.runtime, scope.account.accountRef)
            }
            pendingDeviceLinkingFactory = (id, task)
            let pendingCancellation = scope.addCancellation { task.cancel() }
            defer {
                scope.releaseCancellation(pendingCancellation)
                if pendingDeviceLinkingFactory?.id == id { pendingDeviceLinkingFactory = nil }
            }
            let original = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            let owner = DeviceLinkingScope(accountRef: scope.account.accountRef, session: original)
            guard !Task.isCancelled, accountScope === scope, !scope.isCancelled,
                selection == activationToken, epoch == deviceLinkingEpoch
            else {
                owner.invalidate()
                retiringDeviceLinkingScope = owner
                deviceLinkingCleanup = Task { try await owner.cancel() }
                try await retryDeviceLinkingCleanup()
                throw CancellationError()
            }
            deviceLinkingScope = owner
            let cancellation = scope.addCancellation { [weak self] in
                guard let self, self.deviceLinkingScope === owner else { return }
                self.invalidateDeviceLinking()
            }
            deviceLinkingCancellation = (scope, cancellation)
            return owner
        }

        private func invalidateDeviceLinking() {
            deviceLinkingEpoch = UUID()
            pendingDeviceLinkingFactory?.task.cancel()
            invalidateDeviceLinkingApprovals()
            if let cancellation = deviceLinkingCancellation {
                cancellation.scope.releaseCancellation(cancellation.id)
                deviceLinkingCancellation = nil
            }
            guard let owner = deviceLinkingScope else { return }
            owner.invalidate()
            deviceLinkingScope = nil
            retiringDeviceLinkingScope = owner
            deviceLinkingCleanup = Task { try await owner.cancel() }
        }

        func cancelDeviceLinking() async throws {
            invalidateDeviceLinking()
            try await retryDeviceLinkingCleanup()
        }

        func retryDeviceLinkingCleanup() async throws {
            // Attempt every retained original independently; either failure fences both factories.
            var firstError: Error?
            do { try await retrySessionCleanup() } catch { firstError = error }
            do { try await retryApprovalCleanup() } catch { if firstError == nil { firstError = error } }
            if let firstError { throw firstError }
        }

        private func retrySessionCleanup() async throws {
            guard let owner = retiringDeviceLinkingScope else { return }
            do {
                if let cleanup = deviceLinkingCleanup { try await cleanup.value } else { try await owner.cancel() }
                if retiringDeviceLinkingScope === owner {
                    retiringDeviceLinkingScope = nil
                    deviceLinkingCleanup = nil
                }
            } catch {
                if retiringDeviceLinkingScope === owner { deviceLinkingCleanup = nil }
                throw error
            }
        }

        /// App teardown selects the actual current scope; a background account exit cannot cancel it.
        func prepareForAccountExit(accountID: String? = nil) async throws {
            if let accountID, let current = accountScope, current.account.id != accountID { return }
            // A previous failed exit already detached the scope. Its retained original
            // cleanup must still finish before a repeat exit can reach Core.
            activationToken = UUID()
            invalidateDeviceLinking()
            invalidateSelectedChat()
            invalidateHistory()
            let previous = accountScope
            accountScope = nil
            await previous?.cancelAll()
            // Explicit exits expose this one cleanup failure. Projection teardown's
            // best-effort path must not trigger an implicit second cancellation.
            try await retryNativeCleanup()
        }

        private func finishDeviceLinkingTeardown() async {
            do { try await retryNativeCleanup() } catch {
                // Ordinary projection teardown may continue. Exact owner/error stay retained;
                // explicit exits and future factories must retry this same cleanup successfully.
            }
        }
    #endif

    func activate(
        account: AccountItem?,
        runtime: (any MarmotRuntime)?,
        connectivityAvailable: Bool,
        relayListsDidChange: @escaping @MainActor () -> Void = {}
    ) async {
        guard let account, let runtime else {
            await deactivate()
            return
        }
        if let current = accountScope, current.account.id == account.id,
            let identity = nativeRuntimeObjectIdentity(current.runtime),
            identity == nativeRuntimeObjectIdentity(runtime),
            !current.isCancelled
        {
            return
        }

        let ticket = UUID()
        activationToken = ticket
        #if WN_EXPERIMENTAL_DEVICE_SYNC
            invalidateDeviceLinking()
            invalidateSelectedChat()
            invalidateHistory()
        #endif
        let previous = accountScope
        accountScope = nil
        await previous?.cancelAll()
        #if WN_EXPERIMENTAL_DEVICE_SYNC
            await finishDeviceLinkingTeardown()
        #endif
        guard activationToken == ticket, !Task.isCancelled else { return }
        let scope = AccountScope(
            account: account,
            runtime: runtime,
            relayListsDidChange: relayListsDidChange
        )
        accountScope = scope
        #if WN_EXPERIMENTAL_DEVICE_SYNC
            installSelectedChatTransfer(on: scope)
            scope.installDeviceVerification(
                DeviceVerificationViewModel(
                    begin: { [weak self, weak scope] in
                        guard let self, let scope, self.accountScope === scope, !scope.isCancelled else {
                            throw MarmotKitError.DeviceLinkingClosed
                        }
                        return try await self.beginDeviceLinkingSession()
                    },
                    cancel: { [weak self, weak scope] in
                        guard let self, let scope, self.accountScope === scope, !scope.isCancelled else {
                            throw MarmotKitError.DeviceLinkingClosed
                        }
                        try await self.cancelDeviceLinking()
                    },
                    approve: { [weak self, weak scope] request, target in
                        guard let self, let scope, self.accountScope === scope, !scope.isCancelled else {
                            throw MarmotKitError.DeviceLinkingClosed
                        }
                        return try await self.approveDeviceLinkingSession(request: request, target: target)
                    },
                    targets: { [weak self, weak scope] in
                        guard let self, let scope, self.accountScope === scope, !scope.isCancelled else {
                            throw MarmotKitError.DeviceLinkingClosed
                        }
                        return try await scope.runtime.deviceLinkingTargets(accountRef: scope.account.accountRef)
                    },
                    verificationSupported: runtime.deviceLinkingCapabilities().verificationSupported,
                    enrollmentSupported: runtime.deviceLinkingCapabilities().enrollmentSupported,
                    enrollment: { [weak self, weak scope] in
                        guard let self, let scope, self.accountScope === scope, !scope.isCancelled else {
                            throw MarmotKitError.DeviceLinkingClosed
                        }
                        return try self.makeDeviceEnrollmentModel()
                    },
                    enrollmentApproval: { [weak self, weak scope] in
                        guard let self, let scope, self.accountScope === scope, !scope.isCancelled else {
                            throw MarmotKitError.DeviceLinkingClosed
                        }
                        return try await self.makeDeviceEnrollmentApprovalModel()
                    }
                ))
        #endif
        scope.start(connectivityAvailable: connectivityAvailable)
        await updateProductAnalyticsActivity(.accountChanged)
    }

    func updateConnectivity(available: Bool) {
        accountScope?.updateConnectivity(available: available)
    }

    /// Product activity is best-effort and contains no account or content labels. MarmotKit
    /// applies the current combined consent before recording or exporting it.
    func updateProductAnalyticsActivity(_ activity: ProductAnalyticsActivityFfi) async {
        guard let runtime = accountScope?.runtime else { return }
        do {
            try await runtime.setProductAnalyticsActivity(activity: activity)
        } catch is CancellationError {
            return
        } catch {
            // Lifecycle reporting cannot block account activation or app suspension.
        }
    }

    func deactivate() async {
        activationToken = UUID()
        #if WN_EXPERIMENTAL_DEVICE_SYNC
            invalidateDeviceLinking()
            invalidateSelectedChat()
            invalidateHistory()
        #endif
        let previous = accountScope
        accountScope = nil
        await previous?.cancelAll()
        #if WN_EXPERIMENTAL_DEVICE_SYNC
            await finishDeviceLinkingTeardown()
        #endif
    }
}
