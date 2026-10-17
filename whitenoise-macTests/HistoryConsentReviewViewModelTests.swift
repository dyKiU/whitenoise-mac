#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Testing
    @testable import whitenoise_mac

    private final class ReviewCancellationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func cancel() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private actor ReviewFactoryGate {
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

    private actor ReviewOriginalProbe: HistoryConsentProtocol, HistoryTransferProtocol {
        private(set) var approvals: [UInt64] = []
        nonisolated let cancellation = ReviewCancellationCounter()
        nonisolated func cancel() { cancellation.cancel() }
        private let malformed: Bool
        init(malformed: Bool = false) { self.malformed = malformed }
        func snapshot() async throws -> HistoryTransferSnapshotFfi {
            .init(
                revision: 7, importedRecords: 0, complete: false, groupIdHex: "ab",
                sourceDevice: Data(repeating: 1, count: malformed ? 1 : 32),
                recipientDevice: Data(repeating: 2, count: 32),
                snapshotTimestampCeiling: 100, recordCount: 2, encodedBytes: 900, fragmentCount: 1)
        }
        func approve(revision: UInt64) async throws { approvals.append(revision) }
        func continueTransfer(revision: UInt64) async throws { approvals.append(revision) }
    }

    @MainActor struct HistoryConsentReviewViewModelTests {
        private func setup() async throws -> (SessionState, HistoryConsentReviewViewModel, ReviewOriginalProbe) {
            let state = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            await state.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
            let original = ReviewOriginalProbe()
            let model = try state.historyConsentReviewModel { _, _ in [original] }
            return (state, model, original)
        }

        @Test func listingAndSelectingNeverApproveAndExplicitActionUsesDisplayedRevision() async throws {
            let (state, model, original) = try await setup()
            defer { model.invalidate() }
            try await model.loadPending()
            let request = try #require(model.requests.first)
            #expect(await original.approvals.isEmpty)
            try await model.select(id: request.id)
            #expect(model.review?.revision == 7)
            #expect(await original.approvals.isEmpty)
            try await model.approve(displayedRevision: 7)
            #expect(await original.approvals == [7])
            try await state.prepareForAccountExit()
        }

        @Test func staleDisplayedRevisionCannotApproveHeldOriginal() async throws {
            let (state, model, original) = try await setup()
            try await model.loadPending()
            let request = try #require(model.requests.first)
            try await model.select(id: request.id)
            do {
                try await model.approve(displayedRevision: 6)
                Issue.record("stale review approved")
            } catch MarmotKitError.HistoryTransferStaleRevision {}
            #expect(await original.approvals.isEmpty)
            try await state.prepareForAccountExit()
        }

        @Test func accountReplacementAndReturnCannotRestoreOldReview() async throws {
            let (state, model, original) = try await setup()
            try await model.loadPending()
            let request = try #require(model.requests.first)
            try await model.select(id: request.id)
            let runtime = FakeMarmotRuntime(accounts: [])
            await state.activate(account: AccountItem.samples[1], runtime: runtime, connectivityAvailable: false)
            await state.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
            #expect(!model.isActive)
            #expect(model.requests.isEmpty)
            #expect(model.review == nil)
            #expect(await original.approvals.isEmpty)
            try await state.prepareForAccountExit()
        }

        @Test func cancellingSelectionRetiresOnlyItsExactOriginal() async throws {
            let state = SessionState()
            await state.activate(
                account: AccountItem.samples[0], runtime: FakeMarmotRuntime(accounts: []), connectivityAvailable: false)
            let first = ReviewOriginalProbe()
            let second = ReviewOriginalProbe()
            let model = try state.historyConsentReviewModel { _, _ in [first, second] }
            try await model.loadPending()
            let selected = try #require(model.requests.first)
            try await model.select(id: selected.id)
            model.cancelSelected()
            model.cancelSelected()
            #expect(first.cancellation.value == 1)
            #expect(second.cancellation.value == 0)
            #expect(model.review == nil)
            #expect(model.requests.count == 1)
            try await model.select(id: #require(model.requests.first).id)
            try await model.approve(displayedRevision: 7)
            #expect(await first.approvals.isEmpty)
            #expect(await second.approvals == [7])
            try await state.prepareForAccountExit()
            #expect(first.cancellation.value == 1)
            #expect(second.cancellation.value == 1)
        }

        @Test func foreignRowIdentityClearsReviewAndCannotApprove() async throws {
            let (state, model, original) = try await setup()
            try await model.loadPending()
            try await model.select(id: #require(model.requests.first).id)
            await #expect(throws: MarmotKitError.HistoryTransferNotReady) {
                try await model.select(id: UUID())
            }
            #expect(model.review == nil)
            await #expect(throws: MarmotKitError.HistoryTransferNotReady) {
                try await model.approve(displayedRevision: 7)
            }
            #expect(await original.approvals.isEmpty)
            try await state.prepareForAccountExit()
        }

        @Test func malformedOriginalCannotPreventAnotherRecipientReview() async throws {
            let state = SessionState()
            await state.activate(
                account: AccountItem.samples[0], runtime: FakeMarmotRuntime(accounts: []), connectivityAvailable: false)
            let malformed = ReviewOriginalProbe(malformed: true)
            let valid = ReviewOriginalProbe()
            let model = try state.historyConsentReviewModel { _, _ in [malformed, valid] }
            try await model.loadPending()
            #expect(malformed.cancellation.value == 1)
            let request = try #require(model.requests.first(where: { $0.isActive }))
            try await model.select(id: request.id)
            try await model.approve(displayedRevision: 7)
            #expect(await malformed.approvals.isEmpty)
            #expect(await valid.approvals == [7])
            try await state.prepareForAccountExit()
        }

        @Test func lateFactoryCannotRestoreReviewAfterAccountReplacementAndReturn() async throws {
            let state = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            await state.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
            let gate = ReviewFactoryGate()
            let original = ReviewOriginalProbe()
            let model = try state.historyConsentReviewModel { _, _ in
                await gate.pause()
                return [original]
            }
            let pending = Task { try await model.loadPending() }
            await gate.waitUntilEntered()
            await state.activate(account: AccountItem.samples[1], runtime: runtime, connectivityAvailable: false)
            await state.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
            await gate.resume()
            await #expect(throws: MarmotKitError.HistoryTransferClosed) { try await pending.value }
            #expect(!model.isActive)
            #expect(model.requests.isEmpty)
            #expect(model.review == nil)
            #expect(original.cancellation.value == 1)
            #expect(await original.approvals.isEmpty)
            try await state.prepareForAccountExit()
        }

        @Test func recipientApprovalCannotAdvanceASourceOriginal() async throws {
            let original = ReviewOriginalProbe()
            let source = NativeHistoryActionScope(accountRef: "synthetic", groupIdHex: "ab", transfer: original)
            let model = HistoryConsentReviewViewModel { [source] }
            try await model.loadPending()
            try await model.select(id: source.id)
            await #expect(throws: MarmotKitError.HistoryTransferNotReady) {
                try await model.approve(displayedRevision: 7)
            }
            #expect(await original.approvals.isEmpty)
            source.cancel()
            model.invalidate()
        }
    }
#endif
