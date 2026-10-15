import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

#if WN_EXPERIMENTAL_DEVICE_SYNC
    // Generated superclass conformance is unchecked; NSLock protects mutable controls.
    nonisolated private final class ScopeApproval: DeviceLinkingApproval, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [UInt64] = []
        private var received: [Data] = []
        private var cancellations = 0
        private var failCleanup = false
        private var alreadyClosed = false
        private var rejectRevision = false
        private var pause = false
        private var phase: DeviceLinkingApprovalPhaseFfi = .awaitingApproval
        private var pending: CheckedContinuation<DeviceLinkingApprovalSnapshotFfi, Never>?
        var revisions: [UInt64] { lock.withLock { calls } }
        var packets: [Data] { lock.withLock { received } }
        var cancelCount: Int { lock.withLock { cancellations } }
        var isWaiting: Bool { lock.withLock { pending != nil } }
        override func snapshot() async throws -> DeviceLinkingApprovalSnapshotFfi {
            if lock.withLock({ pause }) {
                return await withCheckedContinuation { continuation in lock.withLock { pending = continuation } }
            }
            return DeviceLinkingApprovalSnapshotFfi(revision: 7, phase: lock.withLock { phase })
        }
        override func approve(displayedRevision: UInt64) async throws {
            lock.withLock { calls.append(displayedRevision) }
            if lock.withLock({ rejectRevision }) { throw MarmotKitError.DeviceLinkingStaleRevision }
        }
        override func receiveEnrollmentPacket(displayedRevision: UInt64, packet: Data) async throws {
            lock.withLock {
                calls.append(displayedRevision)
                received.append(packet)
            }
        }
        override func cancel() async throws {
            lock.withLock { cancellations += 1 }
            if lock.withLock({ alreadyClosed }) { throw MarmotKitError.DeviceLinkingClosed }
            if lock.withLock({ failCleanup }) { throw MarmotKitError.DeviceLinkingRuntimeUnavailable }
        }
        func reportAlreadyClosed() { lock.withLock { alreadyClosed = true } }
        func failCancellation(_ value: Bool) { lock.withLock { failCleanup = value } }
        func rejectNextRevision() { lock.withLock { rejectRevision = true } }
        func pauseSnapshot() { lock.withLock { pause = true } }
        func expire() { lock.withLock { phase = .expired } }
        func finishSnapshot() {
            let continuation = lock.withLock {
                let result = pending
                pending = nil
                return result
            }
            continuation?.resume(returning: DeviceLinkingApprovalSnapshotFfi(revision: 7, phase: .awaitingApproval))
        }
    }

    // Immutable generated stream control.
    nonisolated private final class ScopeSubscription: DeviceLinkingSubscription, @unchecked Sendable {
        override func closeStream() {}
        override func next() async throws -> DeviceLinkingSnapshotFfi { throw MarmotKitError.DeviceLinkingClosed }
    }

    // Generated superclass conformance is unchecked; NSLock protects cleanup controls.
    nonisolated private final class CleanupSession: DeviceLinkingSession, @unchecked Sendable {
        private let lock = NSLock()
        private var cancellations = 0
        private var failed = true
        var cancelCount: Int { lock.withLock { cancellations } }
        override func subscribe() -> DeviceLinkingSubscription { ScopeSubscription(noPointer: .init()) }
        override func cancel() async throws {
            lock.withLock { cancellations += 1 }
            if lock.withLock({ failed }) { throw MarmotKitError.DeviceLinkingRuntimeUnavailable }
        }
        func allowCleanup() { lock.withLock { failed = false } }
    }

    @MainActor @Suite struct NativeDeviceLinkingApprovalScopeTests {
        private func activeState() async -> (SessionState, FakeMarmotRuntime) {
            let state = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            await state.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
            return (state, runtime)
        }
        private func waitFor(_ condition: () -> Bool) async {
            for _ in 0..<200 {
                if condition() { return }
                await Task.yield()
            }
        }
        private func hold(_ original: ScopeApproval, state: SessionState) async throws
            -> NativeDeviceLinkingApprovalScope
        {
            try await state.adoptDeviceLinkingApprovalBatch { _, _ in [original] }
        }
        @Test func nativeAlreadyClosedApprovalCompletesCleanup() async throws {
            let original = ScopeApproval(noPointer: .init())
            original.reportAlreadyClosed()
            let owner = NativeDeviceLinkingApprovalScope(accountRef: "test", approval: original)
            try await owner.cancel()
            try await owner.cancel()
            #expect(owner.cleanupError == nil)
            #expect(original.cancelCount == 1)
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) { _ = try await owner.snapshot() }
        }

        @Test func originalActionsPreserveRevisionBytesAndSdkError() async throws {
            let original = ScopeApproval(noPointer: .init())
            let owner = NativeDeviceLinkingApprovalScope(accountRef: "A", approval: original)
            #expect(try await owner.snapshot().revision == 7)
            try await owner.approve(displayedRevision: 7)
            try await owner.receiveEnrollmentPacket(displayedRevision: 8, packet: Data([1, 2]))
            original.rejectNextRevision()
            await #expect(throws: MarmotKitError.DeviceLinkingStaleRevision) {
                try await owner.approve(displayedRevision: 9)
            }
            #expect(original.revisions == [7, 8, 9])
            #expect(original.packets == [Data([1, 2])])
            try await owner.cancel()
        }
        @Test func cancellationRejectsAllPositiveActions() async throws {
            let original = ScopeApproval(noPointer: .init())
            let owner = NativeDeviceLinkingApprovalScope(accountRef: "A", approval: original)
            try await owner.cancel()
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) { try await owner.snapshot() }
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) { try await owner.approve(displayedRevision: 7) }
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) {
                try await owner.receiveEnrollmentPacket(displayedRevision: 7, packet: Data([1]))
            }
            #expect(original.cancelCount == 1)
            #expect(original.revisions.isEmpty)
        }
        @Test func delayedSnapshotCannotEscapeActualAccountReplacementAndReturn() async throws {
            let (state, runtime) = await activeState()
            let original = ScopeApproval(noPointer: .init())
            original.pauseSnapshot()
            let owner = try await hold(original, state: state)
            let read = Task { try? await owner.snapshot() }
            await waitFor { original.isWaiting }
            try #require(original.isWaiting)
            await state.activate(account: AccountItem.samples[1], runtime: runtime, connectivityAvailable: false)
            await state.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
            original.finishSnapshot()
            #expect(await read.value == nil)
            #expect(state.deviceLinkingApprovalScope == nil)
            #expect(original.cancelCount == 1)
            await state.deactivate()
        }
        @Test func ignoredLateFactoryCannotAttachAcrossActualAccountReplacementAndReturn() async throws {
            let (state, runtime) = await activeState()
            let original = ScopeApproval(noPointer: .init())
            var continuation: CheckedContinuation<Void, Never>?
            let pending = Task {
                try? await state.adoptDeviceLinkingApprovalBatch { _, _ in
                    await withCheckedContinuation { continuation = $0 }
                    return [original]
                }
            }
            await waitFor { continuation != nil }
            try #require(continuation != nil)
            await state.activate(account: AccountItem.samples[1], runtime: runtime, connectivityAvailable: false)
            await state.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
            continuation?.resume()
            #expect(await pending.value == nil)
            #expect(state.deviceLinkingApprovalScope == nil)
            #expect(original.cancelCount == 1)
            await state.deactivate()
        }
        @Test(arguments: [false, true]) func deactivationOrAccountExitRejectsLateOriginal(explicitExit: Bool)
            async throws
        {
            let (state, _) = await activeState()
            let original = ScopeApproval(noPointer: .init())
            var continuation: CheckedContinuation<Void, Never>?
            let pending = Task {
                try? await state.adoptDeviceLinkingApprovalBatch { _, _ in
                    await withCheckedContinuation { continuation = $0 }
                    return [original]
                }
            }
            await waitFor { continuation != nil }
            try #require(continuation != nil)
            if explicitExit {
                try await state.prepareForAccountExit(accountID: AccountItem.samples[0].id)
            } else {
                await state.deactivate()
            }
            #expect(state.accountScope == nil)
            continuation?.resume()
            #expect(await pending.value == nil)
            #expect(state.deviceLinkingApprovalScope == nil)
            #expect(original.cancelCount == 1)
        }
        @Test func failedSessionAndApprovalCleanupBothRunAndBlockFreshAcquisition() async throws {
            let (state, _) = await activeState()
            let session = CleanupSession(noPointer: .init())
            _ = try await state.adoptDeviceLinkingFactory { _, _ in session }
            let original = ScopeApproval(noPointer: .init())
            original.failCancellation(true)
            _ = try await hold(original, state: state)
            await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) {
                try await state.cancelDeviceLinking()
            }
            #expect(session.cancelCount == 1)
            #expect(original.cancelCount == 1)
            #expect(state.retiringDeviceLinkingApprovalScope != nil)
            var calls = 0
            await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) {
                try await state.adoptDeviceLinkingApprovalBatch { _, _ in
                    calls += 1
                    return [original]
                }
            }
            #expect(calls == 0)
            session.allowCleanup()
            await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) {
                try await state.adoptDeviceLinkingFactory { _, _ in
                    calls += 1
                    return session
                }
            }
            #expect(calls == 0)
            original.failCancellation(false)
            try await state.cancelDeviceLinking()
            #expect(state.retiringDeviceLinkingScope == nil)
            #expect(state.retiringDeviceLinkingApprovalScope == nil)
            await state.deactivate()
        }
        @Test func multipleOriginalsStayOwnedOnRefusalAndAllCleanupIsAttempted() async throws {
            let (state, _) = await activeState()
            let first = ScopeApproval(noPointer: .init())
            let second = ScopeApproval(noPointer: .init())
            var calls = 0
            for _ in 0..<2 {
                await #expect(throws: MarmotKitError.DeviceLinkingNotReady) {
                    try await state.adoptDeviceLinkingApprovalBatch { _, _ in
                        calls += 1
                        return [first, second]
                    }
                }
            }
            #expect(calls == 1)
            #expect(first.cancelCount == 0 && second.cancelCount == 0)
            second.failCancellation(true)
            await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) {
                try await state.cancelDeviceLinking()
            }
            #expect(first.cancelCount == 1 && second.cancelCount == 1)
            second.failCancellation(false)
            try await state.cancelDeviceLinking()
            #expect(first.cancelCount == 1 && second.cancelCount == 2)
            await state.deactivate()
        }
        @Test func heldOriginalIsReusedOnlyWhileSdkPhaseRemainsLive() async throws {
            let (state, _) = await activeState()
            let original = ScopeApproval(noPointer: .init())
            var calls = 0
            let first = try await state.adoptDeviceLinkingApprovalBatch { _, _ in
                calls += 1
                return [original]
            }
            let second = try await state.adoptDeviceLinkingApprovalBatch { _, _ in
                calls += 1
                return [original]
            }
            #expect(first === second && calls == 1)
            original.expire()
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) {
                try await state.adoptDeviceLinkingApprovalBatch { _, _ in
                    calls += 1
                    return [original]
                }
            }
            #expect(calls == 1)
            try await state.cancelDeviceLinking()
            await state.deactivate()
        }
    }
#endif
