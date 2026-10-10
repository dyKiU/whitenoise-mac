import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

#if WN_EXPERIMENTAL_DEVICE_SYNC
    // These original-handle controls use a lock because SDK protocols cross actor boundaries.
    nonisolated private final class CopyOriginal: SelectedChatCopyProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var revisions: [UInt64] = []
        private var packets: [Data] = []
        private var cancellations = 0
        var captured: ([UInt64], [Data], Int) { lock.withLock { (revisions, packets, cancellations) } }
        func snapshot() async throws -> SelectedChatCopySnapshotFfi {
            .init(
                revision: 19, phase: .awaitingSiblingConsent, siblingCount: 2, consentingSiblingCount: 0,
                offeredSiblingCount: 0)
        }
        func requestPacket(revision: UInt64) async throws -> Data {
            lock.withLock { revisions.append(revision) }
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
        func cancel() async throws { lock.withLock { cancellations += 1 } }
    }
    nonisolated private final class ConsentOriginal: SelectedChatConsentProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var revisions: [UInt64] = []
        private var approvals = 0
        private var cancellations = 0
        var captured: ([UInt64], Int, Int) { lock.withLock { (revisions, approvals, cancellations) } }
        func snapshot() async throws -> SelectedChatConsentSnapshotFfi {
            .init(revision: 23, phase: .awaitingApproval, chatSelector: Data(repeating: 4, count: 32))
        }
        func approve(revision: UInt64) async throws {
            lock.withLock {
                revisions.append(revision)
                approvals += 1
            }
        }
        func responsePacket(revision: UInt64) async throws -> Data {
            lock.withLock { revisions.append(revision) }
            return Data([11, 12])
        }
        func offerPacket(revision: UInt64) async throws -> Data {
            lock.withLock { revisions.append(revision) }
            return Data([13, 14])
        }
        func cancel() async throws { lock.withLock { cancellations += 1 } }
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
