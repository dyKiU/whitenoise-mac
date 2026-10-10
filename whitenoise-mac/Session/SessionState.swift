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
        #endif
        let previous = accountScope
        accountScope = nil
        await previous?.cancelAll()
        #if WN_EXPERIMENTAL_DEVICE_SYNC
            await finishDeviceLinkingTeardown()
        #endif
    }
}
