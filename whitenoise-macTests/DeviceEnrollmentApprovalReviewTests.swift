import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

#if WN_EXPERIMENTAL_DEVICE_SYNC
    // The generated superclass is unchecked; NSLock protects all original-handle control state.
    nonisolated private final class ReviewApproval: DeviceLinkingApproval, @unchecked Sendable {
        private let lock = NSLock()
        private var reads: [UInt64] = []
        private var actions: [UInt64] = []
        private var sharingActions: [UInt64] = []
        private var packets: [(UInt64, Data)] = []
        private var phase: DeviceLinkingApprovalPhaseFfi = .awaitingApproval
        private var invalid = 0
        private var paused = false
        private var reject = false
        private var failedCleanup = false
        private var cancellations = 0
        private var pending: CheckedContinuation<Void, Never>?
        var isWaiting: Bool { lock.withLock { pending != nil } }
        var cancelCount: Int { lock.withLock { cancellations } }
        func configure(invalid: Int = 0, paused: Bool = false, reject: Bool = false) {
            lock.withLock {
                self.invalid = invalid
                self.paused = paused
                self.reject = reject
            }
        }
        func setPhase(_ value: DeviceLinkingApprovalPhaseFfi) { lock.withLock { phase = value } }
        func advancePhase() { lock.withLock { phase = .approvedAwaitingPacket } }
        func failCleanup(_ value: Bool) { lock.withLock { failedCleanup = value } }
        func finishReview() {
            let continuation = lock.withLock {
                let result = pending
                pending = nil
                return result
            }
            continuation?.resume()
        }
        var reviewedRevisions: [UInt64] { lock.withLock { reads } }
        var sharingRevisions: [UInt64] { lock.withLock { sharingActions } }
        var approvedRevisions: [UInt64] { lock.withLock { actions } }
        var receivedPackets: [(UInt64, Data)] { lock.withLock { packets } }
        override func receiveEnrollmentPacket(displayedRevision: UInt64, packet: Data) async throws {
            lock.withLock { packets.append((displayedRevision, packet)) }
        }
        override func snapshot() async throws -> DeviceLinkingApprovalSnapshotFfi {
            .init(revision: 7, phase: lock.withLock { phase })
        }
        override func reviewMetadata(displayedRevision: UInt64) async throws -> DeviceLinkingApprovalReviewMetadataFfi {
            lock.withLock { reads.append(displayedRevision) }
            if lock.withLock({ reject }) { throw MarmotKitError.DeviceLinkingStaleRevision }
            if lock.withLock({ paused }) {
                await withCheckedContinuation { continuation in lock.withLock { pending = continuation } }
            }
            let invalid = lock.withLock { self.invalid }
            return .init(
                revision: invalid == 3 ? displayedRevision + 1 : displayedRevision,
                sourceDevicePublicKey: Data(repeating: 1, count: invalid == 1 ? 31 : 32),
                joiningDevicePublicKey: Data(repeating: 2, count: 32), existingDeviceCount: invalid == 2 ? 129 : 2)
        }
        override func approve(displayedRevision: UInt64) async throws {
            lock.withLock { actions.append(displayedRevision) }
        }
        override func approveAndShareChats(displayedRevision: UInt64) async throws {
            lock.withLock { sharingActions.append(displayedRevision) }
            if lock.withLock({ reject }) { throw MarmotKitError.DeviceLinkingStaleRevision }
        }
        override func cancel() async throws {
            lock.withLock { cancellations += 1 }
            if lock.withLock({ failedCleanup }) { throw MarmotKitError.DeviceLinkingRuntimeUnavailable }
        }
    }

    @MainActor @Suite struct DeviceEnrollmentApprovalReviewTests {
        private func heldModel(_ original: ReviewApproval) async throws
            -> (SessionState, FakeMarmotRuntime, DeviceEnrollmentApprovalViewModel)
        {
            let state = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            await state.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
            let held = try await state.adoptDeviceLinkingApprovalBatch { _, _ in [original] }
            let model = DeviceEnrollmentApprovalViewModel(
                original: held, isCurrent: { state.deviceLinkingApprovalScope === held },
                cancel: { try await state.cancelDeviceLinking() })
            return (state, runtime, model)
        }
        private func waitForReview(_ original: ReviewApproval) async throws {
            for _ in 0..<200 {
                if original.isWaiting { return }
                await Task.yield()
            }
            try #require(original.isWaiting)
        }
        @Test(arguments: [DeviceLinkingApprovalPhaseFfi.approvedAwaitingPacket, .awaitingSettlement, .settled])
        func resumedOriginalPhaseDisplaysWithoutReReviewOrApproval(phase: DeviceLinkingApprovalPhaseFfi) async throws {
            let original = ReviewApproval(noPointer: .init())
            let (state, _, model) = try await heldModel(original)
            // The original is adopted while pending; terminal snapshots cannot acquire a new owner.
            original.setPhase(phase)
            try await model.refreshForDisplay()
            #expect(model.snapshot?.phase == phase)
            #expect(model.reviewDisplay == nil)
            #expect(original.reviewedRevisions.isEmpty)
            #expect(original.approvedRevisions.isEmpty)
            await state.deactivate()
        }
        @Test func sharingApprovalRequiresExactCurrentReviewAndDistinctOriginalAction() async throws {
            let original = ReviewApproval(noPointer: .init())
            let (state, _, model) = try await heldModel(original)
            defer { model.invalidate() }
            try await model.refreshReview()
            #expect(original.sharingRevisions.isEmpty)
            await #expect(throws: MarmotKitError.DeviceLinkingStaleRevision) {
                try await model.approveReviewedAndShareChats(displayedRevision: 8)
            }
            #expect(original.sharingRevisions.isEmpty)
            try await model.approveReviewedAndShareChats(displayedRevision: 7)
            #expect(original.sharingRevisions == [7])
            #expect(original.approvedRevisions.isEmpty)
            await state.deactivate()
        }

        @Test func sharingApprovalPreservesSdkRefusalAndRetiredOwnerFence() async throws {
            let original = ReviewApproval(noPointer: .init())
            let (state, _, model) = try await heldModel(original)
            defer { model.invalidate() }
            try await model.refreshReview()
            original.configure(reject: true)
            await #expect(throws: MarmotKitError.DeviceLinkingStaleRevision) {
                try await model.approveReviewedAndShareChats(displayedRevision: 7)
            }
            #expect(original.sharingRevisions == [7])
            model.invalidate()
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) {
                try await model.approveReviewedAndShareChats(displayedRevision: 7)
            }
            #expect(original.sharingRevisions == [7])
            await state.deactivate()
        }

        @Test func staleDisplayedRevisionAndSdkFailureNeverApprove() async throws {
            let original = ReviewApproval(noPointer: .init())
            let (state, _, model) = try await heldModel(original)
            try await model.refreshReview()
            await #expect(throws: MarmotKitError.DeviceLinkingStaleRevision) {
                try await model.approveReviewed(displayedRevision: 8)
            }
            original.configure(reject: true)
            await #expect(throws: MarmotKitError.DeviceLinkingStaleRevision) { try await model.refreshReview() }
            #expect(model.review == nil)
            #expect(original.approvedRevisions.isEmpty)
            await state.deactivate()
        }
        @Test(arguments: [1, 2, 3]) func inconsistentReviewIsNotApprovalInput(invalid: Int) async throws {
            let original = ReviewApproval(noPointer: .init())
            original.configure(invalid: invalid)
            let (state, _, model) = try await heldModel(original)
            do {
                try await model.refreshReview()
                Issue.record("Inconsistent SDK review must be refused")
            } catch {}
            #expect(model.review == nil)
            await #expect(throws: MarmotKitError.DeviceLinkingStaleRevision) {
                try await model.approveReviewed(displayedRevision: 7)
            }
            #expect(original.approvedRevisions.isEmpty)
            await state.deactivate()
        }
        @Test(arguments: [0, 1, 2]) func lateReviewCannotPopulateRetiredOriginal(retirement: Int) async throws {
            let original = ReviewApproval(noPointer: .init())
            original.configure(paused: true)
            let (state, runtime, model) = try await heldModel(original)
            let read = Task { try? await model.refreshReview() }
            try await waitForReview(original)
            if retirement == 0 {
                await state.activate(account: AccountItem.samples[1], runtime: runtime, connectivityAvailable: false)
                await state.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
            } else if retirement == 1 {
                await state.deactivate()
            } else {
                try await state.prepareForAccountExit()
            }
            original.finishReview()
            await read.value
            #expect(model.review == nil)
            #expect(!model.isActive)
            #expect(original.approvedRevisions.isEmpty)
            #expect(original.cancelCount == 1)
            await state.deactivate()
        }
        @Test func phaseChangedDuringReviewRequiresNewReview() async throws {
            let original = ReviewApproval(noPointer: .init())
            original.configure(paused: true)
            let (state, _, model) = try await heldModel(original)
            let read = Task { try await model.refreshReview() }
            try await waitForReview(original)
            original.advancePhase()
            original.finishReview()
            await #expect(throws: MarmotKitError.DeviceLinkingStaleRevision) { try await read.value }
            #expect(model.review == nil)
            #expect(original.approvedRevisions.isEmpty)
            await state.deactivate()
        }
        @Test func cancelledReviewClearsKeysAndRetriesOnlyExactCleanup() async throws {
            let original = ReviewApproval(noPointer: .init())
            let (state, _, model) = try await heldModel(original)
            try await model.refreshReview()
            original.failCleanup(true)
            await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) { try await model.cancel() }
            #expect(model.review == nil)
            #expect(model.cleanupError != nil)
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) {
                try await model.approveReviewed(displayedRevision: 7)
            }
            original.failCleanup(false)
            try await model.cancel()
            #expect(model.cleanupError == nil)
            #expect(original.cancelCount == 2)
            #expect(original.approvedRevisions.isEmpty)
            await state.deactivate()
        }
        @Test func paneDisplaysFullAuthenticatedKeysAndOriginalReviewedRevision() async throws {
            let original = ReviewApproval(noPointer: .init())
            let (state, _, model) = try await heldModel(original)
            try await model.refreshReview()
            let display = try #require(model.reviewDisplay)
            #expect(display.revision == 7)
            #expect(display.sourceKey == String(repeating: "01", count: 32))
            #expect(display.joiningKey == String(repeating: "02", count: 32))
            #expect(display.existingDeviceCount == 2)
            #expect(original.approvedRevisions.isEmpty)
            await state.deactivate()
            #expect(model.reviewDisplay == nil)
        }
        @Test func paneActionInvokesOnlyExplicitReviewedOriginalRevision() async throws {
            let original = ReviewApproval(noPointer: .init())
            let (state, _, model) = try await heldModel(original)
            try await model.refreshReview()
            try await model.performReviewAction(.approve, displayedRevision: 7)
            #expect(original.approvedRevisions == [7])
            #expect(model.reviewDisplay == nil)
            await state.deactivate()
        }
        @Test func panePacketActionRequiresApprovedPhaseAndExactRevisionAndBytes() async throws {
            let original = ReviewApproval(noPointer: .init())
            let (state, _, model) = try await heldModel(original)
            try await model.refreshReview()
            let packet = Data([0, 1, 2, 255])
            await #expect(throws: MarmotKitError.DeviceLinkingStaleRevision) {
                try await model.performReviewAction(
                    .receivePacket, displayedRevision: 7, input: packet.base64EncodedString())
            }
            original.advancePhase()
            try await model.refresh()
            await #expect(throws: MarmotKitError.DeviceLinkingStaleRevision) {
                try await model.performReviewAction(
                    .receivePacket, displayedRevision: 8, input: packet.base64EncodedString())
            }
            do {
                try await model.performReviewAction(.receivePacket, displayedRevision: 7, input: "not base64!")
                Issue.record("Malformed opaque input must not reach the original SDK handle")
            } catch {}
            #expect(original.receivedPackets.isEmpty)
            try await model.performReviewAction(
                .receivePacket, displayedRevision: 7, input: packet.base64EncodedString())
            let received = try #require(original.receivedPackets.first)
            #expect(received.0 == 7)
            #expect(received.1 == packet)
            #expect(original.receivedPackets.count == 1)
            #expect(original.approvedRevisions.isEmpty)
            await state.deactivate()
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) {
                try await model.performReviewAction(
                    .receivePacket, displayedRevision: 7, input: packet.base64EncodedString())
            }
            #expect(original.receivedPackets.count == 1)
        }
        @Test func paneFactoryRequiresCapturedSdkCapabilityAndCurrentAccountOwner() async throws {
            let original = ReviewApproval(noPointer: .init())
            let (state, runtime, held) = try await heldModel(original)
            var calls = 0
            let unavailable = DeviceVerificationViewModel(
                begin: { throw MarmotKitError.DeviceLinkingNotReady }, cancel: {},
                enrollmentSupported: false,
                enrollmentApproval: {
                    calls += 1
                    return held
                })
            await #expect(throws: MarmotKitError.DeviceLinkingNotReady) { try await unavailable.enrollmentApproval() }
            #expect(calls == 0)
            let active = DeviceVerificationViewModel(
                begin: { throw MarmotKitError.DeviceLinkingNotReady }, cancel: {},
                enrollmentSupported: true,
                enrollmentApproval: {
                    calls += 1
                    await state.activate(
                        account: AccountItem.samples[1], runtime: runtime, connectivityAvailable: false)
                    await state.activate(
                        account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
                    return held
                })
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) { try await active.enrollmentApproval() }
            #expect(calls == 1)
            #expect(!held.isActive)
            #expect(original.cancelCount == 1)
            #expect(original.approvedRevisions.isEmpty)
            await state.deactivate()
        }
        @Test func originalReviewForwardPreservesCapturedRevisionAndReadOnlyMetadata() async throws {
            let original = ReviewApproval(noPointer: .init())
            let scope = NativeDeviceLinkingApprovalScope(accountRef: "A", approval: original)
            let review = try await scope.reviewMetadata(displayedRevision: 7)
            #expect(review.revision == 7)
            #expect(review.sourceDevicePublicKey == Data(repeating: 1, count: 32))
            #expect(review.joiningDevicePublicKey == Data(repeating: 2, count: 32))
            #expect(review.existingDeviceCount == 2)
            #expect(original.reviewedRevisions == [7])
            #expect(original.approvedRevisions.isEmpty)
            try await scope.cancel()
        }
        @Test func reviewedModelRequiresExplicitActionOnSameOriginalRevision() async throws {
            let state = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            await state.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
            let original = ReviewApproval(noPointer: .init())
            let held = try await state.adoptDeviceLinkingApprovalBatch { _, _ in [original] }
            let model = DeviceEnrollmentApprovalViewModel(
                original: held, isCurrent: { state.deviceLinkingApprovalScope === held },
                cancel: { try await state.cancelDeviceLinking() })
            try await model.refreshReview()
            let review = try #require(model.review)
            #expect(review.revision == 7)
            #expect(original.approvedRevisions.isEmpty)
            try await model.approveReviewed(displayedRevision: review.revision)
            #expect(original.approvedRevisions == [7])
            try await model.cancel()
            #expect(model.review == nil)
            await state.deactivate()
        }
    }
#endif
