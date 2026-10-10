import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

#if WN_EXPERIMENTAL_DEVICE_SYNC
    private actor PresentationPause {
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
    @MainActor private final class PresentationAccount { var isCurrent = true }
    // SDK originals cross actor boundaries; locks protect only test control state.
    nonisolated private final class PresentationCopy: SelectedChatCopyProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var revisions: [UInt64] = []
        private var incoming: [(UInt64, Data)] = []
        private var continued: [UInt64] = []
        private var cancelled = 0
        var invalidSnapshot = false
        var requestBytes = Data([7, 8, 9])
        var cancelFails = false
        var afterRequest: (@Sendable () async -> Void)?
        var received: [(UInt64, Data)] { lock.withLock { incoming } }
        var continuations: [UInt64] { lock.withLock { continued } }
        var cancellations: Int { lock.withLock { cancelled } }
        var requested: [UInt64] { lock.withLock { revisions } }
        func snapshot() async throws -> SelectedChatCopySnapshotFfi {
            .init(
                revision: 19, phase: .awaitingSiblingConsent, siblingCount: invalidSnapshot ? 129 : 2,
                consentingSiblingCount: 0,
                offeredSiblingCount: 0)
        }
        func requestPacket(revision: UInt64) async throws -> Data {
            lock.withLock { revisions.append(revision) }
            await afterRequest?()
            return requestBytes
        }
        func receiveConsentPacket(revision: UInt64, packet: Data) async throws {
            lock.withLock { incoming.append((revision, packet)) }
        }
        func receiveOfferPacket(revision: UInt64, packet: Data) async throws {
            lock.withLock { incoming.append((revision, packet)) }
        }
        func continueCopy(revision: UInt64) async throws { lock.withLock { continued.append(revision) } }
        func cancel() async throws {
            lock.withLock { cancelled += 1 }
            if cancelFails { throw MarmotKitError.SelectedChatCopyBusy }
        }
    }
    nonisolated private final class PresentationConsent: SelectedChatConsentProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var revisions: [UInt64] = []
        var invalidSnapshot = false
        private var packetRevisions: [UInt64] = []
        var exported: [UInt64] { lock.withLock { packetRevisions } }
        var approved: [UInt64] { lock.withLock { revisions } }
        func snapshot() async throws -> SelectedChatConsentSnapshotFfi {
            lock.withLock {
                .init(
                    revision: revisions.isEmpty ? 23 : 24, phase: revisions.isEmpty ? .awaitingApproval : .approved,
                    chatSelector: invalidSnapshot ? Data() : Data(repeating: 4, count: 32))
            }
        }
        func approve(revision: UInt64) async throws { lock.withLock { revisions.append(revision) } }
        func responsePacket(revision: UInt64) async throws -> Data {
            lock.withLock { packetRevisions.append(revision) }
            return Data([11, 12])
        }
        func offerPacket(revision: UInt64) async throws -> Data {
            lock.withLock { packetRevisions.append(revision) }
            return Data([13, 14])
        }
        func cancel() async throws {}
    }
    @MainActor @Suite struct SelectedChatPresentationTests {
        @Test func requestDisplayExportsOnlyExplicitOriginalRevision() async throws {
            let original = PresentationCopy()
            let scope = NativeSelectedChatCopyScope(accountRef: "isolated", original: original)
            let model = SelectedChatCopyViewModel(original: scope, isCurrent: { true })
            try await model.refresh()
            #expect(model.snapshot?.revision == 19)
            #expect(original.requested.isEmpty)
            #expect(model.outgoingPacket == nil)
            try await model.exportRequest(displayedRevision: 19)
            #expect(original.requested == [19])
            #expect(model.outgoingPacket == Data([7, 8, 9]).base64EncodedString())
            try await scope.cancel()
        }
        @Test func consentDisplayDoesNotApproveAndActionUsesDisplayedOriginalRevision() async throws {
            let original = PresentationConsent()
            let scope = NativeSelectedChatConsentScope(accountRef: "isolated", original: original)
            let model = SelectedChatConsentViewModel(original: scope, isCurrent: { true })
            try await model.refresh()
            #expect(model.snapshot?.chatSelector == Data(repeating: 4, count: 32))
            #expect(original.approved.isEmpty)
            try await model.approveReviewed(displayedRevision: 23)
            #expect(original.approved == [23])
            try await scope.cancel()
        }

        @Test func incomingPacketsAndContinuationUseExactOriginalRevision() async throws {
            let original = PresentationCopy()
            let model = SelectedChatCopyViewModel(
                original: NativeSelectedChatCopyScope(accountRef: "isolated", original: original), isCurrent: { true })
            try await model.refresh()
            let packet = Data([0, 255, 13, 10])
            try await model.perform(.consent, displayedRevision: 19, input: " \n" + packet.base64EncodedString() + "\n")
            try await model.perform(.offer, displayedRevision: 19, input: packet.base64EncodedString())
            try await model.perform(.continueCopy, displayedRevision: 19)
            #expect(original.received.map { $0.0 } == [19, 19])
            #expect(original.received.map { $0.1 } == [packet, packet])
            #expect(original.continuations == [19])
            try await model.cancel()
        }
        @Test(arguments: ["", "%%%%", "AB==", Data(repeating: 1, count: 16_385).base64EncodedString()])
        func invalidInputNeverReachesOriginal(input: String) async throws {
            let original = PresentationCopy()
            let model = SelectedChatCopyViewModel(
                original: NativeSelectedChatCopyScope(accountRef: "isolated", original: original), isCurrent: { true })
            try await model.refresh()
            await #expect(throws: MarmotKitError.SelectedChatCopyInvalidPacket) {
                try await model.perform(.consent, displayedRevision: 19, input: input)
            }
            #expect(original.received.isEmpty)
            #expect(model.actionError != nil)
            try await model.cancel()
        }
        @Test func staleDisplayedRevisionNeverExports() async throws {
            let original = PresentationCopy()
            let model = SelectedChatCopyViewModel(
                original: NativeSelectedChatCopyScope(accountRef: "isolated", original: original), isCurrent: { true })
            try await model.refresh()
            await #expect(throws: MarmotKitError.SelectedChatCopyStaleRevision) {
                try await model.exportRequest(displayedRevision: 18)
            }
            #expect(original.requested.isEmpty)
            try await model.cancel()
        }
        @Test func malformedCopySnapshotClearsPreviouslyDisplayedPacket() async throws {
            let original = PresentationCopy()
            let model = SelectedChatCopyViewModel(
                original: NativeSelectedChatCopyScope(accountRef: "isolated", original: original), isCurrent: { true })
            try await model.refresh()
            try await model.exportRequest(displayedRevision: 19)
            original.invalidSnapshot = true
            await #expect(throws: MarmotKitError.SelectedChatCopyNotReady) { try await model.refresh() }
            #expect(model.snapshot == nil)
            #expect(model.outgoingPacket == nil)
            try await model.cancel()
        }
        @Test func malformedConsentSnapshotClearsPreviouslyExportedPacket() async throws {
            let original = PresentationConsent()
            let model = SelectedChatConsentViewModel(
                original: NativeSelectedChatConsentScope(accountRef: "isolated", original: original),
                isCurrent: { true })
            try await model.refresh()
            try await model.approveReviewed(displayedRevision: 23)
            try await model.perform(.response, displayedRevision: 24)
            original.invalidSnapshot = true
            await #expect(throws: MarmotKitError.SelectedChatCopyNotReady) { try await model.refresh() }
            #expect(model.snapshot == nil)
            #expect(model.outgoingPacket == nil)
            try await model.cancel()
        }
        @Test func consentPacketsRequireExplicitApprovalAndNewDisplayedRevision() async throws {
            let original = PresentationConsent()
            let model = SelectedChatConsentViewModel(
                original: NativeSelectedChatConsentScope(accountRef: "isolated", original: original),
                isCurrent: { true })
            try await model.refresh()
            await #expect(throws: MarmotKitError.SelectedChatCopyStaleRevision) {
                try await model.perform(.response, displayedRevision: 23)
            }
            #expect(original.exported.isEmpty)
            try await model.approveReviewed(displayedRevision: 23)
            #expect(model.snapshot?.revision == 24)
            await #expect(throws: MarmotKitError.SelectedChatCopyStaleRevision) {
                try await model.perform(.offer, displayedRevision: 23)
            }
            try await model.perform(.response, displayedRevision: 24)
            #expect(model.outgoingPacket == Data([11, 12]).base64EncodedString())
            try await model.perform(.offer, displayedRevision: 24)
            #expect(model.outgoingPacket == Data([13, 14]).base64EncodedString())
            #expect(original.exported == [24, 24])
            #expect(original.approved == [23])
            try await model.cancel()
        }
        @Test(arguments: [Data(), Data(repeating: 1, count: 16_385)])
        func oversizedOrEmptyOriginalPacketNeverDisplays(packet: Data) async throws {
            let original = PresentationCopy()
            original.requestBytes = packet
            let model = SelectedChatCopyViewModel(
                original: NativeSelectedChatCopyScope(accountRef: "isolated", original: original), isCurrent: { true })
            try await model.refresh()
            await #expect(throws: MarmotKitError.SelectedChatCopyInvalidPacket) {
                try await model.exportRequest(displayedRevision: 19)
            }
            #expect(model.outgoingPacket == nil)
            try await model.cancel()
        }
        @Test func failedCleanupRetriesSameOriginalAndHidesDisplayImmediately() async throws {
            let original = PresentationCopy()
            let model = SelectedChatCopyViewModel(
                original: NativeSelectedChatCopyScope(accountRef: "isolated", original: original), isCurrent: { true })
            try await model.refresh()
            try await model.exportRequest(displayedRevision: 19)
            original.cancelFails = true
            await #expect(throws: MarmotKitError.SelectedChatCopyBusy) { try await model.cancel() }
            #expect(model.snapshot == nil)
            #expect(model.outgoingPacket == nil)
            #expect(model.cleanupError != nil)
            original.cancelFails = false
            try await model.cancel()
            try await model.cancel()
            #expect(original.cancellations == 2)
            #expect(model.cleanupError == nil)
        }
        @Test func latePacketCannotEscapeRetiredAccountAndOverlappingActionIsBusy() async throws {
            let pause = PresentationPause()
            let account = PresentationAccount()
            let original = PresentationCopy()
            original.afterRequest = { await pause.pause() }
            let model = SelectedChatCopyViewModel(
                original: NativeSelectedChatCopyScope(accountRef: "isolated", original: original),
                isCurrent: { account.isCurrent })
            try await model.refresh()
            let request = Task { try await model.exportRequest(displayedRevision: 19) }
            await pause.waitUntilEntered()
            await #expect(throws: MarmotKitError.SelectedChatCopyBusy) {
                try await model.exportRequest(displayedRevision: 19)
            }
            account.isCurrent = false
            await pause.release()
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) { try await request.value }
            #expect(model.outgoingPacket == nil)
            #expect(model.snapshot == nil)
            #expect(original.requested == [19])
            #expect(!model.isWorking)
            try await model.cancel()
            #expect(original.cancellations == 1)
        }

        @Test func transferUsesSelectedGroupAndActualTargetWithoutExportingImplicitly() async throws {
            let original = PresentationCopy()
            let copy = SelectedChatCopyViewModel(
                original: NativeSelectedChatCopyScope(accountRef: "isolated", original: original), isCurrent: { true })
            let selector = Data([32, 31, 30])
            var receivedGroup: String?
            var receivedTarget: Data?
            let transfer = SelectedChatTransferViewModel(
                begin: { group, target in
                    receivedGroup = group
                    receivedTarget = target
                    return copy
                }, receive: { _ in throw MarmotKitError.SelectedChatCopyUnsupported },
                targets: { [.init(selector: selector, deviceCount: 2)] }, isCurrent: { true })
            try await transfer.loadTargets()
            try await transfer.begin(groupIdHex: "actual-group", linkedRosterSelector: selector)
            #expect(receivedGroup == "actual-group")
            #expect(receivedTarget == selector)
            #expect(transfer.copy === copy)
            #expect(copy.snapshot?.revision == 19)
            #expect(original.requested.isEmpty)
            try await copy.cancel()
        }
        @Test func transferReceivesExactOpaqueRequestWithoutApproving() async throws {
            let original = PresentationConsent()
            let consent = SelectedChatConsentViewModel(
                original: NativeSelectedChatConsentScope(accountRef: "isolated", original: original),
                isCurrent: { true })
            var receivedPacket: Data?
            let transfer = SelectedChatTransferViewModel(
                begin: { _, _ in throw MarmotKitError.SelectedChatCopyUnsupported },
                receive: { packet in
                    receivedPacket = packet
                    return consent
                }, targets: { [] }, isCurrent: { true })
            let packet = Data([128, 0, 255])
            try await transfer.receive(input: packet.base64EncodedString())
            #expect(receivedPacket == packet)
            #expect(transfer.consent === consent)
            #expect(consent.snapshot?.chatSelector == Data(repeating: 4, count: 32))
            #expect(original.approved.isEmpty)
            try await consent.cancel()
        }
        @Test func actualAccountActivationOwnsAndRetiresTransferPresentation() async throws {
            let session = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            let account = AccountItem.samples[0]
            await session.activate(account: account, runtime: runtime, connectivityAvailable: false)
            let first = try #require(session.accountScope?.selectedChatTransfer)
            #expect(first.isActive)
            await #expect(throws: MarmotKitError.SelectedChatCopyUnsupported) {
                try await first.receive(input: Data([1]).base64EncodedString())
            }
            #expect(first.consent == nil)
            await session.activate(account: AccountItem.samples[1], runtime: runtime, connectivityAvailable: false)
            #expect(!first.isActive)
            #expect(first.targets.isEmpty)
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) {
                try await first.receive(input: Data([1]).base64EncodedString())
            }
            let second = try #require(session.accountScope?.selectedChatTransfer)
            #expect(second !== first)
            await session.deactivate()
            #expect(!second.isActive)
        }
        @Test func unknownTargetAndInvalidRequestNeverReachFactories() async throws {
            var begins = 0
            var receives = 0
            let transfer = SelectedChatTransferViewModel(
                begin: { _, _ in
                    begins += 1
                    throw MarmotKitError.SelectedChatCopyUnsupported
                },
                receive: { _ in
                    receives += 1
                    throw MarmotKitError.SelectedChatCopyUnsupported
                }, targets: { [.init(selector: Data([1]), deviceCount: 2)] }, isCurrent: { true })
            await #expect(throws: MarmotKitError.SelectedChatCopyNotReady) {
                try await transfer.begin(groupIdHex: "actual-group", linkedRosterSelector: Data([1]))
            }
            try await transfer.loadTargets()
            await #expect(throws: MarmotKitError.SelectedChatCopyNotReady) {
                try await transfer.begin(groupIdHex: "actual-group", linkedRosterSelector: Data([2]))
            }
            await #expect(throws: MarmotKitError.SelectedChatCopyInvalidPacket) {
                try await transfer.receive(input: "%%%%")
            }
            #expect(begins == 0)
            #expect(receives == 0)
            #expect(!transfer.isWorking)
        }
        @Test func retiredTargetReadCannotPopulateTransferOrStartFactory() async throws {
            let pause = PresentationPause()
            var begins = 0
            let transfer = SelectedChatTransferViewModel(
                begin: { _, _ in
                    begins += 1
                    throw MarmotKitError.SelectedChatCopyUnsupported
                }, receive: { _ in throw MarmotKitError.SelectedChatCopyUnsupported },
                targets: {
                    await pause.pause()
                    return [.init(selector: Data([1]), deviceCount: 2)]
                }, isCurrent: { true })
            let read = Task { try await transfer.loadTargets() }
            await pause.waitUntilEntered()
            await #expect(throws: MarmotKitError.SelectedChatCopyBusy) { try await transfer.loadTargets() }
            transfer.invalidate()
            await pause.release()
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) { try await read.value }
            #expect(transfer.targets.isEmpty)
            await #expect(throws: MarmotKitError.SelectedChatCopyClosed) {
                try await transfer.begin(groupIdHex: "actual-group", linkedRosterSelector: Data([1]))
            }
            #expect(begins == 0)
            #expect(!transfer.isWorking)
        }
        @Test func failedInitialDisplayRetainsExactOriginalForCancellation() async throws {
            let original = PresentationConsent()
            original.invalidSnapshot = true
            let consent = SelectedChatConsentViewModel(
                original: NativeSelectedChatConsentScope(accountRef: "isolated", original: original),
                isCurrent: { true })
            let transfer = SelectedChatTransferViewModel(
                begin: { _, _ in throw MarmotKitError.SelectedChatCopyUnsupported }, receive: { _ in consent },
                targets: { [] }, isCurrent: { true })
            await #expect(throws: MarmotKitError.SelectedChatCopyNotReady) {
                try await transfer.receive(input: Data([1]).base64EncodedString())
            }
            #expect(transfer.consent === consent)
            #expect(consent.snapshot == nil)
            await #expect(throws: MarmotKitError.SelectedChatCopyBusy) {
                try await transfer.receive(input: Data([1]).base64EncodedString())
            }
            try await consent.cancel()
            #expect(!consent.isActive)
        }
    }
#endif
