#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Testing

    @testable import whitenoise_mac

    private final class HistoryCancellationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func cancel() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private actor HistorySnapshotGate {
        private var entered = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var release: CheckedContinuation<Void, Never>?
        func pause() async {
            await withCheckedContinuation { continuation in
                release = continuation
                entered = true
                waiter?.resume()
                waiter = nil
            }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func resume() {
            release?.resume()
            release = nil
        }
    }

    private actor OriginalHistoryProbe: HistoryTransferProtocol, HistoryConsentProtocol {
        nonisolated let cancellation = HistoryCancellationCounter()
        nonisolated func cancel() { cancellation.cancel() }
        private let gate: HistorySnapshotGate?
        init(gate: HistorySnapshotGate? = nil) { self.gate = gate }
        func changeRecipient() { value.recipientDevice = Data(repeating: 9, count: 32) }
        private(set) var observed = 0
        private(set) var advanced: [UInt64] = []
        var value = HistoryTransferSnapshotFfi(
            revision: 7, importedRecords: 0, complete: false, groupIdHex: "exact-chat",
            sourceDevice: Data(repeating: 1, count: 32), recipientDevice: Data(repeating: 2, count: 32),
            snapshotTimestampCeiling: 100, recordCount: 2, encodedBytes: 900, fragmentCount: 1)
        func snapshot() async throws -> HistoryTransferSnapshotFfi {
            observed += 1
            if let gate { await gate.pause() }
            return value
        }
        func continueTransfer(revision: UInt64) async throws { advanced.append(revision) }
        func approve(revision: UInt64) async throws { advanced.append(revision) }
    }

    @MainActor struct NativeHistoryActionScopeTests {
        @Test func accountFactoryCapturesExactRuntimeAndExitCancelsOriginal() async throws {
            let state = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            let account = AccountItem.samples[0]
            await state.activate(account: account, runtime: runtime, connectivityAvailable: false)
            let original = OriginalHistoryProbe()
            let held = try await state.adoptHistoryTransferFactory(groupIdHex: "exact-chat") { actual, ref in
                #expect(nativeRuntimeObjectIdentity(actual) == nativeRuntimeObjectIdentity(runtime))
                #expect(ref == account.accountRef)
                return original
            }
            try await held.refresh()
            try await state.prepareForAccountExit()
            #expect(!held.isActive)
            #expect(held.snapshot == nil)
            #expect(original.cancellation.value == 1)
            #expect(await original.advanced.isEmpty)
        }

        @Test func lateHistoryFactoryCannotAttachAcrossAccountReplacementAndReturn() async throws {
            let state = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            let account = AccountItem.samples[0]
            await state.activate(account: account, runtime: runtime, connectivityAvailable: false)
            let gate = HistorySnapshotGate()
            let original = OriginalHistoryProbe()
            let pending = Task {
                try await state.adoptHistoryTransferFactory(groupIdHex: "exact-chat") { _, _ in
                    await gate.pause()
                    return original
                }
            }
            await gate.waitUntilEntered()
            await state.activate(account: AccountItem.samples[1], runtime: runtime, connectivityAvailable: false)
            await state.activate(account: account, runtime: runtime, connectivityAvailable: false)
            var invoked = false
            await #expect(throws: MarmotKitError.HistoryTransferNotReady) {
                _ = try await state.adoptHistoryTransferFactory(groupIdHex: "exact-chat") { _, _ in
                    invoked = true
                    return OriginalHistoryProbe()
                }
            }
            #expect(!invoked)
            await gate.resume()
            await #expect(throws: MarmotKitError.HistoryTransferClosed) { _ = try await pending.value }
            #expect(original.cancellation.value == 1)
            let fresh = try await state.adoptHistoryTransferFactory(groupIdHex: "exact-chat") { _, _ in
                OriginalHistoryProbe()
            }
            #expect(fresh.isActive)
            await state.deactivate()
            #expect(!fresh.isActive)
        }

        @Test func pendingConsentOriginalsFenceCoreExitAndRetireLateUnselectedResults() async throws {
            let state = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            await state.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
            let gate = HistorySnapshotGate()
            let first = OriginalHistoryProbe()
            let second = OriginalHistoryProbe()
            let pending = Task {
                try await state.adoptHistoryConsentFactory { _, _ in
                    await gate.pause()
                    return [first, second]
                }
            }
            await gate.waitUntilEntered()
            await #expect(throws: MarmotKitError.HistoryTransferNotReady) {
                try await state.prepareForAccountExit()
            }
            #expect(state.accountScope == nil)
            await gate.resume()
            await #expect(throws: MarmotKitError.HistoryTransferClosed) { _ = try await pending.value }
            #expect(first.cancellation.value == 1)
            #expect(second.cancellation.value == 1)
            #expect(await first.advanced.isEmpty)
            #expect(await second.advanced.isEmpty)
            try await state.prepareForAccountExit()
        }

        @Test func cancelledCallerRetiresItsIgnoredFactoryResult() async throws {
            let state = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            await state.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
            let gate = HistorySnapshotGate()
            let original = OriginalHistoryProbe()
            let pending = Task {
                try await state.adoptHistoryTransferFactory(groupIdHex: "exact-chat") { _, _ in
                    await gate.pause()
                    return original
                }
            }
            await gate.waitUntilEntered()
            pending.cancel()
            await gate.resume()
            await #expect(throws: MarmotKitError.HistoryTransferClosed) { _ = try await pending.value }
            #expect(original.cancellation.value == 1)
            await state.deactivate()
        }

        @Test func repeatedPendingReadRetainsOriginalsWithoutImplicitApproval() async throws {
            let owner = NativeHistoryAccountOwner(accountRef: "a", runtime: FakeMarmotRuntime(accounts: []))
            let original = OriginalHistoryProbe()
            var reads = 0
            let first = try await owner.adoptConsents { _, _ in
                reads += 1
                return [original]
            }
            let second = try await owner.adoptConsents { _, _ in
                reads += 1
                return [OriginalHistoryProbe()]
            }
            #expect(reads == 1)
            #expect(first.count == 1 && second.count == 1)
            #expect(first[0] === second[0])
            #expect(await original.observed == 0)
            #expect(await original.advanced.isEmpty)
            owner.invalidate()
            #expect(original.cancellation.value == 1)
        }

        @Test func oldViewReleaseCannotCancelReplacementOriginal() async throws {
            let owner = NativeHistoryAccountOwner(accountRef: "a", runtime: FakeMarmotRuntime(accounts: []))
            let first = OriginalHistoryProbe()
            let old = try await owner.adoptTransfer(groupIdHex: "exact-chat") { _, _ in first }
            owner.release(old)
            let second = OriginalHistoryProbe()
            let replacement = try await owner.adoptTransfer(groupIdHex: "exact-chat") { _, _ in second }
            owner.release(old)
            #expect(owner.transfer === replacement)
            #expect(replacement.isActive)
            #expect(second.cancellation.value == 0)
            owner.invalidate()
            #expect(first.cancellation.value == 1)
            #expect(second.cancellation.value == 1)
        }

        @Test func runtimeReplacementRetiresEveryHeldConsentWithoutApproval() async throws {
            let state = SessionState()
            let account = AccountItem.samples[0]
            let runtime = FakeMarmotRuntime(accounts: [])
            await state.activate(account: account, runtime: runtime, connectivityAvailable: false)
            let first = OriginalHistoryProbe()
            let second = OriginalHistoryProbe()
            let held = try await state.adoptHistoryConsentFactory { actual, ref in
                #expect(nativeRuntimeObjectIdentity(actual) == nativeRuntimeObjectIdentity(runtime))
                #expect(ref == account.accountRef)
                return [first, second]
            }
            await state.activate(
                account: account, runtime: FakeMarmotRuntime(accounts: []), connectivityAvailable: false)
            #expect(held.count == 2)
            #expect(held.allSatisfy { !$0.isActive })
            #expect(first.cancellation.value == 1)
            #expect(second.cancellation.value == 1)
            #expect(await first.advanced.isEmpty)
            #expect(await second.advanced.isEmpty)
            await state.deactivate()
        }

        @Test func oversizedOriginalCollectionIsExplicitlyCancelledAndRefused() async throws {
            let owner = NativeHistoryAccountOwner(accountRef: "a", runtime: FakeMarmotRuntime(accounts: []))
            let originals = (0..<129).map { _ in OriginalHistoryProbe() }
            await #expect(throws: MarmotKitError.HistoryTransferNotReady) {
                _ = try await owner.adoptConsents { _, _ in originals }
            }
            #expect(owner.consents.isEmpty)
            #expect(originals.allSatisfy { $0.cancellation.value == 1 })
            owner.invalidate()
        }

        @Test func refreshReviewsExactOwnedSourceAndRecipientOriginals() async throws {
            let source = OriginalHistoryProbe()
            let recipient = OriginalHistoryProbe()
            let outgoing = NativeHistoryActionScope(accountRef: "account-a", groupIdHex: "exact-chat", transfer: source)
            let incoming = NativeHistoryActionScope(accountRef: "account-b", consent: recipient)
            try await outgoing.refresh()
            try await incoming.refresh()
            #expect(outgoing.snapshot?.revision == 7)
            #expect(incoming.snapshot?.sourceDevice == Data(repeating: 1, count: 32))
            #expect(await source.observed == 1)
            #expect(await recipient.observed == 1)
            #expect(await source.advanced.isEmpty)
            #expect(await recipient.advanced.isEmpty)
        }

        @Test func actionsRequireTheRevisionReviewedOnThisExactOriginal() async throws {
            let source = OriginalHistoryProbe()
            let recipient = OriginalHistoryProbe()
            let outgoing = NativeHistoryActionScope(accountRef: "a", groupIdHex: "exact-chat", transfer: source)
            let incoming = NativeHistoryActionScope(accountRef: "b", consent: recipient)
            await #expect(throws: MarmotKitError.HistoryTransferStaleRevision) {
                try await outgoing.perform(displayedRevision: 7)
            }
            try await outgoing.refresh()
            try await incoming.refresh()
            await #expect(throws: MarmotKitError.HistoryTransferStaleRevision) {
                try await outgoing.perform(displayedRevision: 8)
            }
            #expect(await source.advanced.isEmpty)
            try await outgoing.perform(displayedRevision: 7)
            try await incoming.perform(displayedRevision: 7)
            #expect(await source.advanced == [7])
            #expect(await recipient.advanced == [7])
        }

        @Test func cancellationRetiresTheOriginalAndClearsItsReviewedSnapshot() async throws {
            let original = OriginalHistoryProbe()
            let scope = NativeHistoryActionScope(accountRef: "a", groupIdHex: "exact-chat", transfer: original)
            try await scope.refresh()
            scope.cancel()
            scope.cancel()
            #expect(!scope.isActive)
            #expect(scope.snapshot == nil)
            #expect(original.cancellation.value == 1)
            await #expect(throws: MarmotKitError.HistoryTransferClosed) { try await scope.refresh() }
            await #expect(throws: MarmotKitError.HistoryTransferClosed) {
                try await scope.perform(displayedRevision: 7)
            }
            #expect(await original.observed == 1)
            #expect(await original.advanced.isEmpty)
        }

        @Test func lateNonCooperativeSnapshotCannotRestoreCancelledConsent() async {
            let gate = HistorySnapshotGate()
            let original = OriginalHistoryProbe(gate: gate)
            let scope = NativeHistoryActionScope(accountRef: "b", consent: original)
            let read = Task { try await scope.refresh() }
            await gate.waitUntilEntered()
            scope.cancel()
            await gate.resume()
            await #expect(throws: MarmotKitError.HistoryTransferClosed) { try await read.value }
            #expect(scope.snapshot == nil)
            #expect(!scope.isActive)
            #expect(original.cancellation.value == 1)
        }

        @Test func callerCancellationCancelsTheOriginalWhileSnapshotIsBlocked() async {
            let gate = HistorySnapshotGate()
            let original = OriginalHistoryProbe(gate: gate)
            let scope = NativeHistoryActionScope(accountRef: "b", consent: original)
            let read = Task { try await scope.refresh() }
            await gate.waitUntilEntered()
            read.cancel()
            #expect(original.cancellation.value >= 1)
            await gate.resume()
            await #expect(throws: CancellationError.self) { try await read.value }
            #expect(!scope.isActive)
            #expect(scope.snapshot == nil)
            #expect(await original.advanced.isEmpty)
        }

        @Test func changedSelectionCancelsRatherThanReconstructingConsent() async throws {
            let original = OriginalHistoryProbe()
            let scope = NativeHistoryActionScope(accountRef: "b", consent: original)
            try await scope.refresh()
            await original.changeRecipient()
            await #expect(throws: MarmotKitError.HistoryTransferNotReady) { try await scope.refresh() }
            #expect(!scope.isActive)
            #expect(scope.snapshot == nil)
            #expect(original.cancellation.value == 1)
            #expect(await original.advanced.isEmpty)
        }

        @Test func overlappingReadsDoNotAcquireASecondOriginalOperation() async throws {
            let gate = HistorySnapshotGate()
            let original = OriginalHistoryProbe(gate: gate)
            let scope = NativeHistoryActionScope(accountRef: "a", groupIdHex: "exact-chat", transfer: original)
            let read = Task { try await scope.refresh() }
            await gate.waitUntilEntered()
            await #expect(throws: MarmotKitError.HistoryTransferNotReady) { try await scope.refresh() }
            #expect(await original.observed == 1)
            await gate.resume()
            try await read.value
            #expect(scope.snapshot?.revision == 7)
        }
    }
#endif
