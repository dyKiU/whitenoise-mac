import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

#if WN_EXPERIMENTAL_DEVICE_SYNC
    // Immutable control; the generated superclass requires restating its unchecked conformance.
    nonisolated private final class EnrollmentSubscription: DeviceLinkingSubscription, @unchecked Sendable {
        private let lock = NSLock()
        private var emitted = false
        override func close() {}
        override func next() async throws -> DeviceLinkingSnapshotFfi {
            let first = lock.withLock {
                let first = !emitted
                emitted = true
                return first
            }
            guard first else { throw MarmotKitError.DeviceLinkingClosed }
            return .init(revision: 7, phase: .verificationCompleteEnrollmentPending, decimals: nil)
        }
    }

    // Generated superclass conformance is unchecked; NSLock protects all mutable control state.
    nonisolated private final class EnrollmentSession: DeviceLinkingSession, @unchecked Sendable {
        private let lock = NSLock()
        private let stream = EnrollmentSubscription(noPointer: .init())
        private var failedCleanup = false
        private var cancellations = 0
        var cancelCount: Int { lock.withLock { cancellations } }
        func failCancellation(_ value: Bool) { lock.withLock { failedCleanup = value } }
        private var calls: [String] = []
        private var received: [Data] = []
        private var rejected = false
        private var pause = false
        private var pending: CheckedContinuation<Data, Never>?
        var actions: [String] { lock.withLock { calls } }
        var packets: [Data] { lock.withLock { received } }
        var isWaiting: Bool { lock.withLock { pending != nil } }
        override func subscribe() -> DeviceLinkingSubscription { stream }
        override func cancel() async throws {
            lock.withLock { cancellations += 1 }
            if lock.withLock({ failedCleanup }) { throw MarmotKitError.DeviceLinkingRuntimeUnavailable }
        }
        override func continueLinking(displayedRevision: UInt64) async throws {
            lock.withLock { calls.append("continue:\(displayedRevision)") }
            if lock.withLock({ rejected }) { throw MarmotKitError.DeviceLinkingStaleRevision }
        }
        override func enrollmentPacket(displayedRevision: UInt64) async throws -> Data {
            lock.withLock { calls.append("export:\(displayedRevision)") }
            if lock.withLock({ pause }) {
                return await withCheckedContinuation { continuation in
                    lock.withLock { pending = continuation }
                }
            }
            return Data([1, 2, 3])
        }
        override func receiveEnrollmentPacket(displayedRevision: UInt64, packet: Data) async throws {
            lock.withLock {
                calls.append("receive:\(displayedRevision)")
                received.append(packet)
            }
        }
        override func finalizeLinking(displayedRevision: UInt64) async throws {
            lock.withLock { calls.append("finalize:\(displayedRevision)") }
        }
        func rejectRevision() { lock.withLock { rejected = true } }
        func pauseExport() { lock.withLock { pause = true } }
        func finishExport() {
            let continuation = lock.withLock {
                let result = pending
                pending = nil
                return result
            }
            continuation?.resume(returning: Data([1, 2, 3]))
        }
    }

    // Generated superclass conformance is unchecked; NSLock protects mutable controls.
    nonisolated private final class ScopeApproval: DeviceLinkingApproval, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [UInt64] = []
        private var received: [Data] = []
        private var cancellations = 0
        private var failCleanup = false
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
            if lock.withLock({ failCleanup }) { throw MarmotKitError.DeviceLinkingRuntimeUnavailable }
        }
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

    @MainActor @Suite struct DeviceEnrollmentViewModelTests {
        private func state() async -> (SessionState, FakeMarmotRuntime) {
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
        private func sessionModel(_ state: SessionState, original: EnrollmentSession) async throws
            -> DeviceEnrollmentViewModel
        {
            let scope = try await state.adoptDeviceLinkingFactory { _, _ in original }
            await waitFor { scope.latestSnapshot != nil }
            try #require(scope.latestSnapshot != nil)
            return try state.makeDeviceEnrollmentModel()
        }
        @Test func sessionModelRequiresAlreadyHeldOriginal() async throws {
            let (state, _) = await state()
            #expect(throws: MarmotKitError.DeviceLinkingNotReady) { try state.makeDeviceEnrollmentModel() }
            await state.deactivate()
        }
        @Test func sessionActionsUseCapturedRevisionAndOpaqueBytes() async throws {
            let (state, _) = await state()
            let original = EnrollmentSession(noPointer: .init())
            let model = try await sessionModel(state, original: original)
            #expect(try state.makeDeviceEnrollmentModel() === model)
            let shown = try #require(model.snapshot)
            try await model.continueLinking(displayedRevision: shown.revision)
            #expect(try await model.enrollmentPacket(displayedRevision: 8) == Data([1, 2, 3]))
            try await model.receiveEnrollmentPacket(displayedRevision: 9, packet: Data([4, 5]))
            try await model.finalizeLinking(displayedRevision: 10)
            #expect(original.actions == ["continue:7", "export:8", "receive:9", "finalize:10"])
            #expect(original.packets == [Data([4, 5])])
            original.rejectRevision()
            await #expect(throws: MarmotKitError.DeviceLinkingStaleRevision) {
                try await model.continueLinking(displayedRevision: shown.revision)
            }
            try await model.cancel()
            await state.deactivate()
        }
        @Test func delayedSessionPacketCannotEscapeActualAccountReplacementAndReturn() async throws {
            let (state, runtime) = await state()
            let original = EnrollmentSession(noPointer: .init())
            let model = try await sessionModel(state, original: original)
            original.pauseExport()
            let export = Task { try? await model.enrollmentPacket(displayedRevision: 7) }
            await waitFor { original.isWaiting }
            try #require(original.isWaiting)
            await state.activate(account: AccountItem.samples[1], runtime: runtime, connectivityAvailable: false)
            await state.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
            original.finishExport()
            #expect(await export.value == nil)
            #expect(model.snapshot == nil && !model.isActive)
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) {
                try await model.finalizeLinking(displayedRevision: 7)
            }
            #expect(original.actions == ["export:7"])
            await state.deactivate()
        }
        @Test func explicitApprovalOnlyUsesOriginalActionNotRefreshOrDecode() async throws {
            let (state, _) = await state()
            let original = ScopeApproval(noPointer: .init())
            _ = try await state.adoptDeviceLinkingApprovalBatch { _, _ in [original] }
            let model = try await state.makeDeviceEnrollmentApprovalModel()
            #expect(try await state.makeDeviceEnrollmentApprovalModel() === model)
            try await model.refresh()
            let shown = try #require(model.snapshot)
            let packet = try DeviceEnrollmentPacketInput.decode("AQID")
            #expect(packet == Data([1, 2, 3]))
            #expect(original.revisions.isEmpty)
            try await model.approve(displayedRevision: shown.revision)
            try await model.receiveEnrollmentPacket(displayedRevision: 8, packet: packet)
            original.rejectNextRevision()
            await #expect(throws: MarmotKitError.DeviceLinkingStaleRevision) {
                try await model.approve(displayedRevision: 9)
            }
            #expect(original.revisions == [7, 8, 9] && original.packets == [packet])
            try await model.cancel()
            await state.deactivate()
        }
        @Test(arguments: [false, true]) func delayedApprovalSnapshotCannotEscapeDeactivationOrExit(explicitExit: Bool)
            async throws
        {
            let (state, _) = await state()
            let original = ScopeApproval(noPointer: .init())
            _ = try await state.adoptDeviceLinkingApprovalBatch { _, _ in [original] }
            let model = try await state.makeDeviceEnrollmentApprovalModel()
            original.pauseSnapshot()
            let read = Task { try? await model.refresh() }
            await waitFor { original.isWaiting }
            try #require(original.isWaiting)
            if explicitExit {
                try await state.prepareForAccountExit(accountID: AccountItem.samples[0].id)
            } else {
                await state.deactivate()
            }
            original.finishSnapshot()
            #expect(await read.value == nil)
            #expect(model.snapshot == nil && !model.isActive)
            #expect(original.revisions.isEmpty)
        }
        @Test func cancelledSessionModelRetainsExactCleanupForRetry() async throws {
            let (state, _) = await state()
            let original = EnrollmentSession(noPointer: .init())
            let model = try await sessionModel(state, original: original)
            original.failCancellation(true)
            await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) { try await model.cancel() }
            #expect(model.snapshot == nil && !model.isActive)
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) {
                try await model.continueLinking(displayedRevision: 7)
            }
            original.failCancellation(false)
            try await model.cancel()
            #expect(original.cancelCount == 2)
            await state.deactivate()
        }
        @Test func invalidPacketNeverBecomesAnAction() async throws {
            for text in ["", "AQI", "AQID=", Data(repeating: 1, count: 16_385).base64EncodedString()] {
                #expect(throws: DeviceEnrollmentPacketInput.Error.invalidPacket) {
                    try DeviceEnrollmentPacketInput.decode(text)
                }
            }
        }
    }
#endif
