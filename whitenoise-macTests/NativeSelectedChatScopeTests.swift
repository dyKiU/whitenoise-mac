import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

#if WN_EXPERIMENTAL_DEVICE_SYNC
    private actor SelectedChatPause {
        private var entered = false
        private var enteredWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        func pause() async {
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
                entered = true
                enteredWaiter?.resume()
                enteredWaiter = nil
            }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiter = $0 }
        }
        func release() {
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }
    // These original-handle controls use a lock because SDK protocols cross actor boundaries.
    nonisolated private final class CopyOriginal: SelectedChatCopyProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var revisions: [UInt64] = []
        private var packets: [Data] = []
        private var cancellations = 0
        private let pause: SelectedChatPause?
        private let failFirstCancel: Bool
        private let staleAction: Bool
        init(pause: SelectedChatPause? = nil, failFirstCancel: Bool = false, staleAction: Bool = false) {
            self.pause = pause
            self.failFirstCancel = failFirstCancel
            self.staleAction = staleAction
        }
        var captured: ([UInt64], [Data], Int) { lock.withLock { (revisions, packets, cancellations) } }
        func snapshot() async throws -> SelectedChatCopySnapshotFfi {
            .init(
                revision: 19, phase: .awaitingSiblingConsent, siblingCount: 2, consentingSiblingCount: 0,
                offeredSiblingCount: 0)
        }
        func requestPacket(revision: UInt64) async throws -> Data {
            lock.withLock { revisions.append(revision) }
            if staleAction { throw MarmotKitError.SelectedChatCopyStaleRevision }
            if let pause { await pause.pause() }
            return Data([7, 8, 9])
        }
        func receiveConsentPacket(revision: UInt64, packet: Data) async throws {
            lock.withLock {
                revisions.append(revision)
                packets.append(packet)
            }
        }
        func receiveOfferPacket(revision: UInt64, packet: Data) async throws {
            lock.withLock {
                revisions.append(revision)
                packets.append(packet)
            }
        }
        func continueCopy(revision: UInt64) async throws { lock.withLock { revisions.append(revision) } }
        func cancel() async throws {
            let attempt = lock.withLock {
                cancellations += 1
                return cancellations
            }
            if failFirstCancel && attempt == 1 { throw MarmotKitError.SelectedChatCopyBusy }
        }
    }
    nonisolated private final class ConsentOriginal: SelectedChatConsentProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var revisions: [UInt64] = []
        private var approvals = 0
        private var cancellations = 0
        private let pause: SelectedChatPause?
        private let failFirstCancel: Bool
        private let staleAction: Bool
        init(pause: SelectedChatPause? = nil, failFirstCancel: Bool = false, staleAction: Bool = false) {
            self.pause = pause
            self.failFirstCancel = failFirstCancel
            self.staleAction = staleAction
        }
        var captured: ([UInt64], Int, Int) { lock.withLock { (revisions, approvals, cancellations) } }
        func snapshot() async throws -> SelectedChatConsentSnapshotFfi {
            .init(revision: 23, phase: .awaitingApproval, chatSelector: Data(repeating: 4, count: 32))
        }
        func approve(revision: UInt64) async throws {
            lock.withLock {
                revisions.append(revision)
                approvals += 1
            }
            if staleAction { throw MarmotKitError.SelectedChatCopyStaleRevision }
        }
        func responsePacket(revision: UInt64) async throws -> Data {
            lock.withLock { revisions.append(revision) }
            if let pause { await pause.pause() }
            return Data([11, 12])
        }
        func offerPacket(revision: UInt64) async throws -> Data {
            lock.withLock { revisions.append(revision) }
            return Data([13, 14])
        }
        func cancel() async throws {
            let attempt = lock.withLock {
                cancellations += 1
                return cancellations
            }
            if failFirstCancel && attempt == 1 { throw MarmotKitError.SelectedChatCopyBusy }
        }
    }
    @MainActor @Suite struct NativeSelectedChatScopeTests {
        @Test func requestForwardsExactOriginalRevisionAndOpaquePackets() async throws {
            let original = CopyOriginal()
            let held = NativeSelectedChatCopyScope(accountRef: "isolated", original: original)
            #expect(try await held.snapshot().revision == 19)
            #expect(try await held.requestPacket(displayedRevision: 19) == Data([7, 8, 9]))
            try await held.receiveConsentPacket(displayedRevision: 19, packet: Data([1, 2]))
            try await held.receiveOfferPacket(displayedRevision: 19, packet: Data([3, 4]))
            try await held.continueCopy(displayedRevision: 19)
            #expect(original.captured.0 == [19, 19, 19, 19])
            #expect(original.captured.1 == [Data([1, 2]), Data([3, 4])])
            try await held.cancel()
            #expect(original.captured.2 == 1)
        }
        @Test func recipientReadDoesNotApproveAndExplicitActionUsesOriginalRevision() async throws {
            let original = ConsentOriginal()
            let held = NativeSelectedChatConsentScope(accountRef: "isolated", original: original)
            let review = try await held.snapshot()
            #expect(review.chatSelector == Data(repeating: 4, count: 32))
            #expect(original.captured.1 == 0)
            try await held.approve(displayedRevision: review.revision)
            #expect(try await held.responsePacket(displayedRevision: 23) == Data([11, 12]))
            #expect(try await held.offerPacket(displayedRevision: 23) == Data([13, 14]))
            #expect(original.captured.0 == [23, 23, 23])
            #expect(original.captured.1 == 1)
            try await held.cancel()
            #expect(original.captured.2 == 1)
        }
        @Test func invalidatedRequestBlocksAllNewActions() async throws {
            let original = CopyOriginal()
            let scope = NativeSelectedChatCopyScope(accountRef: "isolated", original: original)
            scope.invalidate()
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) { _ = try await scope.snapshot() }
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) {
                _ = try await scope.requestPacket(displayedRevision: 19)
            }
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) {
                try await scope.receiveConsentPacket(displayedRevision: 19, packet: Data([1]))
            }
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) {
                try await scope.receiveOfferPacket(displayedRevision: 19, packet: Data([2]))
            }
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) {
                try await scope.continueCopy(displayedRevision: 19)
            }
            #expect(original.captured.0.isEmpty)
            #expect(original.captured.1.isEmpty)
        }
        @Test func invalidatedConsentBlocksAllNewActions() async throws {
            let original = ConsentOriginal()
            let scope = NativeSelectedChatConsentScope(accountRef: "isolated", original: original)
            scope.invalidate()
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) { _ = try await scope.snapshot() }
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) {
                try await scope.approve(displayedRevision: 23)
            }
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) {
                _ = try await scope.responsePacket(displayedRevision: 23)
            }
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) {
                _ = try await scope.offerPacket(displayedRevision: 23)
            }
            #expect(original.captured.0.isEmpty)
            #expect(original.captured.1 == 0)
        }
        @Test func delayedRequestPacketCannotEscapeRetirement() async throws {
            let pause = SelectedChatPause()
            let original = CopyOriginal(pause: pause)
            let scope = NativeSelectedChatCopyScope(accountRef: "isolated", original: original)
            let action = Task { try await scope.requestPacket(displayedRevision: 19) }
            await pause.waitUntilEntered()
            scope.invalidate()
            await pause.release()
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) { _ = try await action.value }
            #expect(original.captured.0 == [19])
        }
        @Test func delayedConsentPacketCannotEscapeCancellation() async throws {
            let pause = SelectedChatPause()
            let original = ConsentOriginal(pause: pause)
            let scope = NativeSelectedChatConsentScope(accountRef: "isolated", original: original)
            let action = Task { try await scope.responsePacket(displayedRevision: 23) }
            await pause.waitUntilEntered()
            try await scope.cancel()
            await pause.release()
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) { _ = try await action.value }
            #expect(original.captured.0 == [23])
            #expect(original.captured.2 == 1)
        }
        @Test func requestFailedCleanupRetriesSameOriginalOnce() async throws {
            let original = CopyOriginal(failFirstCancel: true)
            let scope = NativeSelectedChatCopyScope(accountRef: "isolated", original: original)
            await #expect(throws: MarmotKitError.SelectedChatCopyBusy) { try await scope.cancel() }
            #expect(!scope.isActive)
            #expect(scope.cleanupError != nil)
            #expect(original.captured.2 == 1)
            try await scope.cancel()
            try await scope.cancel()
            #expect(scope.cleanupError == nil)
            #expect(original.captured.2 == 2)
        }
        @Test func consentFailedCleanupRetriesSameOriginalOnce() async throws {
            let original = ConsentOriginal(failFirstCancel: true)
            let scope = NativeSelectedChatConsentScope(accountRef: "isolated", original: original)
            await #expect(throws: MarmotKitError.SelectedChatCopyBusy) { try await scope.cancel() }
            #expect(!scope.isActive)
            #expect(scope.cleanupError != nil)
            #expect(original.captured.2 == 1)
            try await scope.cancel()
            try await scope.cancel()
            #expect(scope.cleanupError == nil)
            #expect(original.captured.2 == 2)
        }
        @Test func staleDisplayedRevisionPassesThroughWithoutImplicitRefreshOrApproval() async throws {
            let request = CopyOriginal(staleAction: true)
            let copy = NativeSelectedChatCopyScope(accountRef: "isolated", original: request)
            await #expect(throws: MarmotKitError.SelectedChatCopyStaleRevision) {
                _ = try await copy.requestPacket(displayedRevision: 17)
            }
            #expect(request.captured.0 == [17])
            let recipient = ConsentOriginal(staleAction: true)
            let consent = NativeSelectedChatConsentScope(accountRef: "isolated", original: recipient)
            await #expect(throws: MarmotKitError.SelectedChatCopyStaleRevision) {
                try await consent.approve(displayedRevision: 21)
            }
            #expect(recipient.captured.0 == [21])
            #expect(recipient.captured.1 == 1)
        }
        @Test func currentAccountOwnsExactRequestAndExitCancelsIt() async throws {
            let state = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            let account = AccountItem.samples[0]
            await state.activate(account: account, runtime: runtime, connectivityAvailable: false)
            let original = CopyOriginal()
            let held = try await state.adoptSelectedChatCopyFactory { actual, ref in
                #expect(nativeRuntimeObjectIdentity(actual) == nativeRuntimeObjectIdentity(runtime))
                #expect(ref == account.accountRef)
                return original
            }
            #expect(held.accountRef == account.accountRef)
            #expect(try await held.requestPacket(displayedRevision: 19) == Data([7, 8, 9]))
            try await state.prepareForAccountExit()
            #expect(!held.isActive)
            #expect(original.captured.2 == 1)
            #expect(state.accountScope == nil)
        }
        @Test func currentAccountOwnsExactConsentAndRuntimeReplacementRetiresIt() async throws {
            let state = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            let account = AccountItem.samples[0]
            await state.activate(account: account, runtime: runtime, connectivityAvailable: false)
            let original = ConsentOriginal()
            let held = try await state.adoptSelectedChatConsentFactory { actual, ref in
                #expect(nativeRuntimeObjectIdentity(actual) == nativeRuntimeObjectIdentity(runtime))
                #expect(ref == account.accountRef)
                return original
            }
            #expect(held.accountRef == account.accountRef)
            try await held.approve(displayedRevision: 23)
            let replacement = FakeMarmotRuntime(accounts: [])
            await state.activate(account: account, runtime: replacement, connectivityAvailable: false)
            #expect(!held.isActive)
            #expect(original.captured.2 == 1)
            #expect(original.captured.0 == [23])
            await state.deactivate()
        }
        @Test func lateRequestCannotAttachAcrossAccountReplacementAndReturn() async throws {
            let state = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            let account = AccountItem.samples[0]
            await state.activate(account: account, runtime: runtime, connectivityAvailable: false)
            let pause = SelectedChatPause()
            let original = CopyOriginal()
            let pending = Task {
                try await state.adoptSelectedChatCopyFactory { _, ref in
                    #expect(ref == account.accountRef)
                    await pause.pause()
                    return original
                }
            }
            await pause.waitUntilEntered()
            await state.activate(account: AccountItem.samples[1], runtime: runtime, connectivityAvailable: false)
            await state.activate(account: account, runtime: runtime, connectivityAvailable: false)
            var invoked = false
            await #expect(throws: MarmotKitError.SelectedChatCopyBusy) {
                _ = try await state.adoptSelectedChatCopyFactory { _, _ in
                    invoked = true
                    return CopyOriginal()
                }
            }
            #expect(!invoked)
            await pause.release()
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) { _ = try await pending.value }
            #expect(original.captured.2 == 1)
            try await state.retrySelectedChatCleanup()
            let fresh = CopyOriginal()
            let held = try await state.adoptSelectedChatCopyFactory { _, _ in fresh }
            #expect(held.isActive)
            await state.deactivate()
            #expect(fresh.captured.2 == 1)
        }
        @Test func lateConsentCannotAttachAcrossDeactivationAndNewAccountLifetime() async throws {
            let state = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            let account = AccountItem.samples[0]
            await state.activate(account: account, runtime: runtime, connectivityAvailable: false)
            let pause = SelectedChatPause()
            let original = ConsentOriginal()
            let pending = Task {
                try await state.adoptSelectedChatConsentFactory { _, _ in
                    await pause.pause()
                    return original
                }
            }
            await pause.waitUntilEntered()
            await state.deactivate()
            await state.activate(account: account, runtime: runtime, connectivityAvailable: false)
            await pause.release()
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) { _ = try await pending.value }
            #expect(original.captured.2 == 1)
            #expect(original.captured.1 == 0)
            try await state.retrySelectedChatCleanup()
            await state.deactivate()
        }
        @Test func callerCancellationRetiresIgnoredLateFactoryResult() async throws {
            let state = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            await state.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
            let pause = SelectedChatPause()
            let original = CopyOriginal()
            let pending = Task {
                try await state.adoptSelectedChatCopyFactory { _, _ in
                    await pause.pause()
                    return original
                }
            }
            await pause.waitUntilEntered()
            pending.cancel()
            await pause.release()
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) { _ = try await pending.value }
            #expect(original.captured.2 == 1)
            let held = try await state.adoptSelectedChatCopyFactory { _, _ in CopyOriginal() }
            #expect(held.isActive)
            await state.deactivate()
        }
        @Test func exactFailedChatCleanupBlocksCoreResetAndRetriesSameOriginal() async throws {
            let fixture = AccountItem.samples[0]
            let summary = AccountSummaryFfi(
                label: fixture.accountRef, accountIdHex: fixture.accountIdHex, localSigning: true,
                externalSigning: false, signedOut: false, running: true)
            let runtime = FakeMarmotRuntime(accounts: [summary])
            let workspace = WorkspaceState(clientFactory: { runtime })
            await workspace.bootstrap()
            let state = SessionState()
            await state.activate(account: workspace.activeAccount, runtime: runtime, connectivityAvailable: false)
            let original = CopyOriginal(failFirstCancel: true)
            let held = try await state.adoptSelectedChatCopyFactory { _, _ in original }
            await workspace.deleteAllData(beforeRuntimeReset: { try await state.prepareForAccountExit() })
            #expect(!runtime.didDeleteAllLocalData)
            #expect(!held.isActive)
            #expect(held.cleanupError != nil)
            #expect(original.captured.2 == 1)
            runtime.onDeleteAllLocalDataMidFlight = { #expect(original.captured.2 == 2) }
            await workspace.deleteAllData(beforeRuntimeReset: { try await state.prepareForAccountExit() })
            #expect(runtime.didDeleteAllLocalData)
            #expect(held.cleanupError == nil)
            #expect(original.captured.2 == 2)
        }
        @Test func pendingOriginalFactoryBlocksCoreExitWithoutDroppingItsResult() async throws {
            let state = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            await state.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
            let pause = SelectedChatPause()
            let original = ConsentOriginal()
            let pending = Task {
                try await state.adoptSelectedChatConsentFactory { _, _ in
                    await pause.pause()
                    return original
                }
            }
            await pause.waitUntilEntered()
            await #expect(throws: MarmotKitError.SelectedChatCopyBusy) { try await state.prepareForAccountExit() }
            #expect(state.accountScope == nil)
            await pause.release()
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) { _ = try await pending.value }
            try await state.prepareForAccountExit()
            #expect(original.captured.2 == 1)
        }
        @Test func cancelledLateFactoryCleanupFinishesBeforeNextOriginalFactory() async throws {
            let state = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            await state.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
            let pause = SelectedChatPause()
            let original = CopyOriginal(failFirstCancel: true)
            let pending = Task {
                try await state.adoptSelectedChatCopyFactory { _, _ in
                    await pause.pause()
                    return original
                }
            }
            await pause.waitUntilEntered()
            pending.cancel()
            await pause.release()
            await #expect(throws: MarmotKitError.SelectedChatCopyBusy) { _ = try await pending.value }
            #expect(original.captured.2 == 1)
            let fresh = CopyOriginal()
            let held = try await state.adoptSelectedChatCopyFactory { _, _ in
                #expect(original.captured.2 == 2)
                return fresh
            }
            #expect(held.isActive)
            await state.deactivate()
            #expect(original.captured.2 == 2)
            #expect(fresh.captured.2 == 1)
        }
        private func withRuntime(_ body: (any MarmotRuntime) async throws -> Void) async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "wn-selected-runtime-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let client = try MarmotClient(
                rootPath: root.path, relayUrls: ["wss://relay.example.invalid"], storageProfile: .testHost)
            do {
                try await body(client)
                #expect(try client.listAccounts().isEmpty)
                try await client.marmot.shutdownAndClose()
            } catch {
                try? await client.marmot.shutdownAndClose()
                throw error
            }
        }
        @Test func requestFactoryPreservesMissingAccountWithoutCreatingIdentity() async throws {
            try await withRuntime { runtime in
                await #expect(throws: MarmotKitError.SelectedChatCopyRuntimeUnavailable) {
                    _ = try await runtime.beginSelectedChatCopy(
                        accountRef: "missing", groupIdHex: "11", linkedRosterSelector: Data([2]))
                }
            }
        }
        @Test func recipientFactoryPreservesMissingAccountWithoutCreatingIdentity() async throws {
            try await withRuntime { runtime in
                await #expect(throws: MarmotKitError.SelectedChatCopyRuntimeUnavailable) {
                    _ = try await runtime.receiveSelectedChatCopyRequest(accountRef: "missing", packet: Data([1]))
                }
            }
        }
    }
#endif
