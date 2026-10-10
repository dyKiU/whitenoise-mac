import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

#if WN_EXPERIMENTAL_DEVICE_SYNC
    @MainActor private final class VerificationSessionDouble: DeviceVerificationSession {
        var latestSnapshot: DeviceLinkingSnapshotFfi? = .init(revision: 7, phase: .comparisonAvailable, decimals: nil)
        var revisions: [UInt64] = []
        func setupPacket() throws -> Data { Data([1]) }
        func outgoingPackets() async throws -> [DeviceLinkingOutgoingPacketFfi] { [] }
        func receiveSetupPacket(_ packet: Data) async throws {}
        func receivePacket(_ packet: Data) async throws {}
        func acknowledgePacket(_ acknowledgementID: String) async throws {}
        func confirmComparison(displayedRevision: UInt64) async throws { revisions.append(displayedRevision) }
    }

    @MainActor @Suite struct DeviceVerificationViewModelTests {
        @Test func confirmsCapturedDisplayRevisionAndClearsRetiredDisplay() async throws {
            let original = VerificationSessionDouble()
            let model = DeviceVerificationViewModel(begin: { original }, cancel: {})
            try await model.begin()
            let displayed = try #require(model.snapshot)
            original.latestSnapshot = .init(revision: 8, phase: .awaitingPeerVerification, decimals: nil)
            try await model.confirm(displayedRevision: displayed.revision)
            #expect(original.revisions == [7])
            model.invalidate()
            #expect(model.snapshot == nil)
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) { try await model.confirm(displayedRevision: 8) }
            #expect(original.revisions == [7])
        }

        @Test func actualAccountReplacementRetiresInstalledFeatureAndItsFactoryCallbacks() async throws {
            let state = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            await state.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
            let originalModel = try #require(state.accountScope?.deviceVerification)
            await state.activate(account: AccountItem.samples[1], runtime: runtime, connectivityAvailable: false)
            #expect(originalModel.isActive == false)
            #expect(originalModel.snapshot == nil)
            #expect(state.accountScope?.deviceVerification !== originalModel)
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) { try await originalModel.begin() }
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) {
                try await originalModel.confirm(displayedRevision: 7)
            }
            await state.deactivate()
        }

        @Test func cancellationDuringFactoryWaitRejectsItsLateResult() async throws {
            let original = VerificationSessionDouble()
            var delayed: CheckedContinuation<any DeviceVerificationSession, Never>?
            var cancellations = 0
            let model = DeviceVerificationViewModel(
                begin: { await withCheckedContinuation { delayed = $0 } }, cancel: { cancellations += 1 })
            let pending = Task {
                do {
                    try await model.begin()
                    return true
                } catch { return false }
            }
            for _ in 0..<200 {
                if delayed != nil { break }
                await Task.yield()
            }
            #expect(delayed != nil)
            try await model.cancel()
            delayed?.resume(returning: original)
            #expect(await pending.value == false)
            #expect(cancellations == 1)
            #expect(model.owner == nil)
        }

        @Test func lateOriginalFactoryCannotPopulateInvalidatedFeature() async throws {
            let original = VerificationSessionDouble()
            var delayed: CheckedContinuation<any DeviceVerificationSession, Never>?
            let model = DeviceVerificationViewModel(
                begin: { await withCheckedContinuation { delayed = $0 } }, cancel: {})
            let pending = Task {
                do {
                    try await model.begin()
                    return true
                } catch { return false }
            }
            for _ in 0..<200 {
                if delayed != nil { break }
                await Task.yield()
            }
            #expect(delayed != nil)
            model.invalidate()
            delayed?.resume(returning: original)
            #expect(await pending.value == false)
            #expect(model.snapshot == nil)
        }
    }
#endif
