import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

#if WN_EXPERIMENTAL_DEVICE_SYNC
    // Generated protocol doubles exercise native forwarding/lifetime, not SDK verification.
    nonisolated private final class ActionSubscription: DeviceLinkingSubscription, @unchecked Sendable {
        override func next() async throws -> DeviceLinkingSnapshotFfi { throw MarmotKitError.DeviceLinkingClosed }
        override func close() {}
    }

    nonisolated private final class ActionSession: DeviceLinkingSession, @unchecked Sendable {
        private let lock = NSLock()
        private var revisions: [UInt64] = []
        private var packetReads = 0
        private var receivedSetup: [Data] = []
        private var receivedPackets: [Data] = []
        private var acknowledgements: [String] = []
        var setupInputs: [Data] { lock.withLock { receivedSetup } }
        var packetInputs: [Data] { lock.withLock { receivedPackets } }
        var acknowledgementInputs: [String] { lock.withLock { acknowledgements } }
        override func setupPacket() -> Data { Data([2]) }
        override func receiveSetupPacket(packet: Data) async throws { lock.withLock { receivedSetup.append(packet) } }
        override func receivePacket(packet: Data) async throws { lock.withLock { receivedPackets.append(packet) } }
        override func acknowledgePacket(acknowledgementId: String) async throws {
            lock.withLock { acknowledgements.append(acknowledgementId) }
        }
        private var delayed: CheckedContinuation<[DeviceLinkingOutgoingPacketFfi], Never>?
        var pausePacketRead = false
        var confirmedRevisions: [UInt64] { lock.withLock { revisions } }
        var outgoingReadCount: Int { lock.withLock { packetReads } }
        var isPacketReadWaiting: Bool { lock.withLock { delayed != nil } }
        override func subscribe() -> DeviceLinkingSubscription { ActionSubscription(noPointer: .init()) }
        override func cancel() async throws {}
        override func confirmComparison(displayedRevision: UInt64) async throws {
            lock.withLock { revisions.append(displayedRevision) }
            guard displayedRevision == 8 else { throw MarmotKitError.DeviceLinkingStaleRevision }
        }
        override func outgoingPackets() async throws -> [DeviceLinkingOutgoingPacketFfi] {
            lock.withLock { packetReads += 1 }
            if pausePacketRead {
                return await withCheckedContinuation { continuation in lock.withLock { delayed = continuation } }
            }
            return [DeviceLinkingOutgoingPacketFfi(acknowledgementId: "original", bytes: Data([1]))]
        }
        func finishPacketRead() {
            let continuation = lock.withLock {
                let result = delayed
                delayed = nil
                return result
            }
            continuation?.resume(
                returning: [DeviceLinkingOutgoingPacketFfi(acknowledgementId: "original", bytes: Data([1]))])
        }
    }

    @MainActor @Suite struct NativeDeviceLinkingActionTests {
        private func waitFor(_ condition: () -> Bool) async {
            for _ in 0..<200 {
                if condition() { return }
                await Task.yield()
            }
        }

        @Test func comparisonUsesDisplayedRevisionWithoutReplacingItWithNewestSnapshot() async throws {
            let original = ActionSession(noPointer: .init())
            let owner = DeviceLinkingScope(accountRef: "isolated", session: original)
            await #expect(throws: MarmotKitError.DeviceLinkingStaleRevision) {
                try await owner.confirmComparison(displayedRevision: 7)
            }
            #expect(original.confirmedRevisions == [7])
            try await owner.confirmComparison(displayedRevision: 8)
            #expect(original.confirmedRevisions == [7, 8])
            try await owner.cancel()
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) {
                try await owner.confirmComparison(displayedRevision: 8)
            }
            #expect(original.confirmedRevisions == [7, 8])
        }

        @Test func packetReadForwardsOriginalAndRefusesRetiredOwner() async throws {
            let original = ActionSession(noPointer: .init())
            let owner = DeviceLinkingScope(accountRef: "isolated", session: original)
            let packets = try await owner.outgoingPackets()
            #expect(packets.count == 1)
            #expect(packets.first?.acknowledgementId == "original")
            #expect(original.outgoingReadCount == 1)
            try await owner.cancel()
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) { _ = try await owner.outgoingPackets() }
            #expect(original.outgoingReadCount == 1)
        }

        @Test func opaqueTransportForwardsExactInputsAndStopsAfterCancellation() async throws {
            let original = ActionSession(noPointer: .init())
            let owner = DeviceLinkingScope(accountRef: "isolated", session: original)
            #expect(try owner.setupPacket() == Data([2]))
            try await owner.receiveSetupPacket(Data([3]))
            try await owner.receivePacket(Data([4]))
            try await owner.acknowledgePacket("exact")
            #expect(original.setupInputs == [Data([3])])
            #expect(original.packetInputs == [Data([4])])
            #expect(original.acknowledgementInputs == ["exact"])
            try await owner.cancel()
            #expect(throws: MarmotKitError.DeviceLinkingClosed) { _ = try owner.setupPacket() }
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) { try await owner.receiveSetupPacket(Data([5])) }
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) { try await owner.receivePacket(Data([6])) }
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) { try await owner.acknowledgePacket("late") }
            #expect(original.setupInputs == [Data([3])])
            #expect(original.packetInputs == [Data([4])])
            #expect(original.acknowledgementInputs == ["exact"])
        }

        @Test func delayedPacketCannotEscapeActualAccountReplacement() async throws {
            let state = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            await state.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
            let original = ActionSession(noPointer: .init())
            original.pausePacketRead = true
            let owner = try await state.adoptDeviceLinkingFactory { _, _ in original }
            let pending = Task {
                do {
                    _ = try await owner.outgoingPackets()
                    return true
                } catch { return false }
            }
            await waitFor { original.isPacketReadWaiting }
            #expect(original.isPacketReadWaiting)
            await state.activate(account: AccountItem.samples[1], runtime: runtime, connectivityAvailable: false)
            original.finishPacketRead()
            #expect(await pending.value == false)
            #expect(state.deviceLinkingScope == nil)
            #expect(owner.latestSnapshot == nil)
            await state.deactivate()
        }
    }
#endif
