import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

#if WN_EXPERIMENTAL_DEVICE_SYNC
    // Immutable control; the generated superclass requires restating its unchecked conformance.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class EnrollmentSubscription: DeviceLinkingSubscription, @unchecked Sendable {
        override func close() {}
        override func next() async throws -> DeviceLinkingSnapshotFfi {
            throw MarmotKitError.DeviceLinkingClosed
        }
    }

    // Generated superclass conformance is unchecked; NSLock protects all mutable control state.
    // swiftlint:disable:next no_unchecked_sendable
    nonisolated private final class EnrollmentSession: DeviceLinkingSession, @unchecked Sendable {
        private let lock = NSLock()
        private let stream = EnrollmentSubscription(noPointer: .init())
        private var calls: [String] = []
        private var received: [Data] = []
        private var rejected = false
        private var pause = false
        private var pending: CheckedContinuation<Data, Never>?
        var actions: [String] { lock.withLock { calls } }
        var packets: [Data] { lock.withLock { received } }
        var isWaiting: Bool { lock.withLock { pending != nil } }
        override func subscribe() -> DeviceLinkingSubscription { stream }
        override func cancel() async throws {}
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

    @MainActor @Suite struct NativeDeviceLinkingEnrollmentActionTests {
        @Test func explicitActionsForwardOnlyToOriginalHandle() async throws {
            let session = EnrollmentSession(noPointer: .init())
            let scope = DeviceLinkingScope(accountRef: "account", session: session)
            defer { scope.invalidate() }
            try await scope.continueLinking(displayedRevision: 7)
            #expect(try await scope.enrollmentPacket(displayedRevision: 8) == Data([1, 2, 3]))
            try await scope.receiveEnrollmentPacket(displayedRevision: 9, packet: Data([4, 5]))
            try await scope.finalizeLinking(displayedRevision: 10)
            #expect(session.actions == ["continue:7", "export:8", "receive:9", "finalize:10"])
            #expect(session.packets == [Data([4, 5])])
        }

        @Test func originalSdkRevisionErrorRemainsAnError() async throws {
            let session = EnrollmentSession(noPointer: .init())
            session.rejectRevision()
            let scope = DeviceLinkingScope(accountRef: "account", session: session)
            defer { scope.invalidate() }
            await #expect(throws: MarmotKitError.DeviceLinkingStaleRevision) {
                try await scope.continueLinking(displayedRevision: 7)
            }
            #expect(session.actions == ["continue:7"])
        }

        @Test func explicitCancellationRejectsEveryEnrollmentOperation() async throws {
            let session = EnrollmentSession(noPointer: .init())
            let scope = DeviceLinkingScope(accountRef: "account", session: session)
            try await scope.cancel()
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) {
                try await scope.continueLinking(displayedRevision: 7)
            }
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) {
                try await scope.enrollmentPacket(displayedRevision: 7)
            }
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) {
                try await scope.receiveEnrollmentPacket(displayedRevision: 7, packet: Data([1]))
            }
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) {
                try await scope.finalizeLinking(displayedRevision: 7)
            }
            #expect(session.actions.isEmpty)
        }

        @Test func delayedPacketCannotEscapeAccountReplacementAndReturn() async throws {
            let session = EnrollmentSession(noPointer: .init())
            session.pauseExport()
            let state = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            let account = AccountItem.samples[0]
            await state.activate(account: account, runtime: runtime, connectivityAvailable: false)
            let scope = try await state.adoptDeviceLinkingFactory { _, _ in session }
            let export = Task { try? await scope.enrollmentPacket(displayedRevision: 7) }
            for _ in 0..<200 {
                if session.isWaiting { break }
                await Task.yield()
            }
            try #require(session.isWaiting)
            await state.activate(account: AccountItem.samples[1], runtime: runtime, connectivityAvailable: false)
            await state.activate(account: account, runtime: runtime, connectivityAvailable: false)
            session.finishExport()
            #expect(await export.value == nil)
            #expect(state.deviceLinkingScope == nil)
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) {
                try await scope.finalizeLinking(displayedRevision: 7)
            }
            #expect(session.actions == ["export:7"])
            await state.deactivate()
        }

        @Test(arguments: [false, true]) func deactivationOrExplicitExitRejectsDelayedEnrollmentResult(
            explicitExit: Bool
        ) async throws {
            let state = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            let account = AccountItem.samples[0]
            await state.activate(account: account, runtime: runtime, connectivityAvailable: false)
            let session = EnrollmentSession(noPointer: .init())
            session.pauseExport()
            let scope = try await state.adoptDeviceLinkingFactory { _, _ in session }
            let export = Task { try? await scope.enrollmentPacket(displayedRevision: 7) }
            for _ in 0..<200 {
                if session.isWaiting { break }
                await Task.yield()
            }
            try #require(session.isWaiting)
            if explicitExit {
                try await state.prepareForAccountExit(accountID: account.id)
            } else {
                await state.deactivate()
            }
            #expect(state.accountScope == nil)
            session.finishExport()
            #expect(await export.value == nil)
            #expect(state.deviceLinkingScope == nil)
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) {
                try await scope.continueLinking(displayedRevision: 7)
            }
            #expect(session.actions == ["export:7"])
            try await scope.cancel()
        }
    }
#endif
