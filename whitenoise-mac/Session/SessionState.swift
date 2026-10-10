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
            let previous = accountScope
            accountScope = nil
            await previous?.cancelAll()
            // Explicit exits expose this one cleanup failure. Projection teardown's
            // best-effort path must not trigger an implicit second cancellation.
            try await retryDeviceLinkingCleanup()
        }

        private func finishDeviceLinkingTeardown() async {
            do { try await retryDeviceLinkingCleanup() } catch {
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
                    verificationSupported: runtime.deviceLinkingCapabilities().verificationSupported
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
        #endif
        let previous = accountScope
        accountScope = nil
        await previous?.cancelAll()
        #if WN_EXPERIMENTAL_DEVICE_SYNC
            await finishDeviceLinkingTeardown()
        #endif
    }
}
