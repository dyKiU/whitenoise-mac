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
        @Test func enrollmentTransportCannotBypassActualCapabilityOrVerificationPhase() async throws {
            let original = VerificationSessionDouble()
            var factoryCalls = 0
            let unsupported = DeviceVerificationViewModel(
                begin: { original }, cancel: {},
                enrollment: {
                    factoryCalls += 1
                    throw MarmotKitError.DeviceLinkingClosed
                })
            try await unsupported.begin()
            original.latestSnapshot = .init(revision: 7, phase: .verificationCompleteEnrollmentPending, decimals: nil)
            #expect(throws: MarmotKitError.DeviceLinkingNotReady) { try unsupported.enrollmentTransport() }
            let supportedControl = DeviceVerificationViewModel(
                begin: { original }, cancel: {}, enrollmentSupported: true,
                enrollment: {
                    factoryCalls += 1
                    throw MarmotKitError.DeviceLinkingClosed
                })
            original.latestSnapshot = .init(revision: 7, phase: .comparisonAvailable, decimals: nil)
            try await supportedControl.begin()
            #expect(throws: MarmotKitError.DeviceLinkingNotReady) { try supportedControl.enrollmentTransport() }
            supportedControl.invalidate()
            #expect(throws: MarmotKitError.DeviceLinkingNotReady) { try supportedControl.enrollmentTransport() }
            #expect(factoryCalls == 0)
        }

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

        @Test func approvalAndTransportUseOnlyOriginalOpaqueInputs() async throws {
            let original = VerificationSessionDouble()
            var approvals: [(Data, Data?)] = []
            let target = DeviceLinkingTargetFfi(selector: Data([9]), deviceCount: 2)
            let model = DeviceVerificationViewModel(
                begin: { original }, cancel: {},
                approve: { request, selected in
                    approvals.append((request, selected))
                    return original
                },
                targets: { [target] }, verificationSupported: true)
            try await model.loadTargets()
            #expect(model.targets == [target])
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) {
                try await model.approve(request: Data([8]), target: Data([99]))
            }
            #expect(approvals.isEmpty)
            #expect(model.owner == nil)
            try await model.approve(request: Data([8]), target: target.selector)
            #expect(approvals.count == 1)
            #expect(approvals.first?.0 == Data([8]))
            #expect(approvals.first?.1 == Data([9]))
            #expect(try model.setupPacket() == Data([1]))
            try await model.receiveSetupPacket(Data([2]))
            try await model.receivePacket(Data([3]))
            try await model.acknowledgePacket("original")
            #expect(try await model.outgoingPackets().isEmpty)
            model.invalidate()
            #expect(model.targets.isEmpty)
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) { try await model.receivePacket(Data([4])) }
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

        @Test func scanStartsExchangeWithoutConfirmingComparisonOrSharing() async throws {
            let session = VerificationSessionDouble()
            let original = session
            var enrollmentCalls = 0
            let model = DeviceVerificationViewModel(
                begin: { original }, cancel: {}, approve: { _, _ in original },
                targets: { [] }, verificationSupported: true, enrollmentSupported: true,
                enrollment: {
                    enrollmentCalls += 1
                    throw MarmotKitError.DeviceLinkingNotReady
                })
            try await model.scanAndSync(request: Data("WNPAIR1:synthetic-bootstrap".utf8))
            #expect(model.owner === original)
            #expect(enrollmentCalls == 0)
            #expect(session.revisions.isEmpty)
        }

        @Test func cancellingScanDuringTargetReadPreventsFactory() async throws {
            var read: CheckedContinuation<[DeviceLinkingTargetFfi], Never>?
            var factoryCalls = 0
            let model = DeviceVerificationViewModel(
                begin: { throw MarmotKitError.DeviceLinkingNotReady }, cancel: {},
                approve: { _, _ in
                    factoryCalls += 1
                    throw MarmotKitError.DeviceLinkingNotReady
                }, targets: { await withCheckedContinuation { read = $0 } }, verificationSupported: true)
            let task = Task { try await model.scanAndSync(request: Data("WNPAIR1:synthetic-bootstrap".utf8)) }
            for _ in 0..<200 {
                if read != nil { break }
                await Task.yield()
            }
            let continuation = try #require(read)
            task.cancel()
            continuation.resume(returning: [])
            await #expect(throws: (any Error).self) { try await task.value }
            #expect(factoryCalls == 0 && model.owner == nil)
        }

        @Test(arguments: [0, 1, 2]) func scanUsesFreshUnambiguousTargetWithoutGrantingTrust(count: Int) async throws {
            var inputs: [(Data, Data?)] = []
            var reads = 0
            var confirmations = 0
            let model = DeviceVerificationViewModel(
                begin: { throw MarmotKitError.DeviceLinkingNotReady }, cancel: {},
                approve: { request, target in
                    inputs.append((request, target))
                    throw MarmotKitError.DeviceLinkingNotReady
                },
                targets: {
                    reads += 1
                    return (0..<count).map { .init(selector: Data([UInt8($0)]), deviceCount: 2) }
                }, verificationSupported: true,
                enrollment: {
                    confirmations += 1
                    throw MarmotKitError.DeviceLinkingNotReady
                })
            let request = Data("WNPAIR1:synthetic-bootstrap".utf8)
            await #expect(throws: (any Error).self) { try await model.scanAndSync(request: request) }
            #expect(reads == 1)
            #expect(inputs.count == (count > 1 ? 0 : 1))
            if count <= 1 {
                #expect(inputs[0].0 == request)
                #expect(inputs[0].1 == (count == 0 ? nil : Data([0])))
            }
            #expect(confirmations == 0 && model.owner == nil)
        }

        @Test func invalidScanAndFailedTargetReadCannotStartBootstrap() async throws {
            var reads = 0
            var factories = 0
            let model = DeviceVerificationViewModel(
                begin: { throw MarmotKitError.DeviceLinkingNotReady }, cancel: {},
                approve: { _, _ in
                    factories += 1
                    throw MarmotKitError.DeviceLinkingNotReady
                },
                targets: {
                    reads += 1
                    throw MarmotKitError.DeviceLinkingRuntimeUnavailable
                }, verificationSupported: true)
            for request in [Data(), Data("not-a-pairing-code".utf8), Data(repeating: 65, count: 1025)] {
                await #expect(throws: (any Error).self) { try await model.scanAndSync(request: request) }
            }
            #expect(reads == 0 && factories == 0)
            await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) {
                try await model.scanAndSync(request: Data("WNPAIR1:synthetic-bootstrap".utf8))
            }
            #expect(reads == 1 && factories == 0)
        }

        @Test func firstDeviceSetupRequiresSuccessfulEmptyReadAndPreservesNilFactoryInput() async throws {
            let session = VerificationSessionDouble()
            var inputs: [(Data, Data?)] = []
            let model = DeviceVerificationViewModel(
                begin: { session }, cancel: {},
                approve: { bytes, selector in
                    inputs.append((bytes, selector))
                    return session
                }, targets: { [] }, verificationSupported: true)
            #expect(!model.offersFirstDeviceSetupAttempt)
            try await model.loadTargets()
            #expect(model.offersFirstDeviceSetupAttempt)
            let bytes = Data([1, 2, 3])
            try await model.approveFirstDeviceSetup(request: bytes)
            #expect(inputs.count == 1 && inputs[0].0 == bytes && inputs[0].1 == nil)
            try await model.confirm(displayedRevision: 4)
            #expect(session.revisions == [4])
            try await model.cancel()
        }

        @Test func failedOrInflightReadNeverFallsBackToFirstDeviceSetup() async throws {
            let failRead = MainActorTestFlag(false)
            var delayed: CheckedContinuation<[DeviceLinkingTargetFfi], Never>?
            let blockRead = MainActorTestFlag(false)
            var calls = 0
            let model = DeviceVerificationViewModel(
                begin: { VerificationSessionDouble() }, cancel: {},
                approve: { _, _ in
                    calls += 1
                    throw MarmotKitError.DeviceLinkingRuntimeUnavailable
                },
                targets: {
                    if failRead.value { throw MarmotKitError.DeviceLinkingRuntimeUnavailable }
                    if blockRead.value { return await withCheckedContinuation { delayed = $0 } }
                    return []
                }, verificationSupported: true)
            try await model.loadTargets()
            failRead.value = true
            await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) { try await model.loadTargets() }
            #expect(!model.offersFirstDeviceSetupAttempt)
            await #expect(throws: (any Error).self) { try await model.approveFirstDeviceSetup(request: Data([1])) }
            failRead.value = false
            blockRead.value = true
            let read = Task { try await model.loadTargets() }
            for _ in 0..<200 {
                if delayed != nil { break }
                await Task.yield()
            }
            try #require(delayed != nil)
            #expect(!model.offersFirstDeviceSetupAttempt)
            await #expect(throws: (any Error).self) { try await model.approveFirstDeviceSetup(request: Data([1])) }
            delayed?.resume(returning: [])
            try await read.value
            #expect(calls == 0)
        }

        @Test func selectedTargetAndAuthoritativeFactoryDenialNeverBecomeBootstrapFallback() async throws {
            var calls: [Data?] = []
            let target = Data([9])
            let model = DeviceVerificationViewModel(
                begin: { VerificationSessionDouble() }, cancel: {},
                approve: { _, selected in
                    calls.append(selected)
                    throw MarmotKitError.DeviceLinkingNotReady
                },
                targets: { [.init(selector: target, deviceCount: 2)] }, verificationSupported: true)
            try await model.loadTargets()
            #expect(!model.offersFirstDeviceSetupAttempt)
            await #expect(throws: (any Error).self) { try await model.approveFirstDeviceSetup(request: Data([1])) }
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) {
                try await model.approve(request: Data([1]), target: Data([8]))
            }
            await #expect(throws: MarmotKitError.DeviceLinkingNotReady) {
                try await model.approve(request: Data([1]), target: target)
            }
            #expect(calls.count == 1 && calls[0] == target && model.owner == nil)
        }

        @Test func firstDeviceAttemptPreservesActualSdkMissingAccountRefusal() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("FirstSetup-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let client = try MarmotClient(
                rootPath: root.path, relayUrls: ["wss://relay.example.invalid"],
                storageProfile: .testHost)
            let model = DeviceVerificationViewModel(
                begin: { VerificationSessionDouble() }, cancel: {},
                approve: { bytes, selector in
                    _ = try await client.approveDeviceLinkingSession(
                        accountRef: "missing", request: bytes,
                        target: selector)
                    throw MarmotKitError.DeviceLinkingNotReady
                }, targets: { [] }, verificationSupported: true)
            do {
                try await model.loadTargets()
                await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) {
                    try await model.approveFirstDeviceSetup(request: Data([1]))
                }
                #expect(model.owner == nil)
                #expect(try client.listAccounts().isEmpty)
                try await client.marmot.shutdownAndClose()
            } catch {
                try? await client.marmot.shutdownAndClose()
                throw error
            }
        }

        @Test(arguments: [false, true]) func lateTargetReadCannotOfferSetupAfterActualOwnerRetirement(
            exit: Bool
        ) async throws {
            let state = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            await state.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
            let scope = try #require(state.accountScope)
            var delayed: CheckedContinuation<[DeviceLinkingTargetFfi], Never>?
            var calls = 0
            let model = DeviceVerificationViewModel(
                begin: { VerificationSessionDouble() }, cancel: {},
                approve: { _, _ in
                    calls += 1
                    throw MarmotKitError.DeviceLinkingRuntimeUnavailable
                },
                targets: { await withCheckedContinuation { delayed = $0 } }, verificationSupported: true)
            // Same account-owned cancellation boundary as the production installed model.
            scope.addCancellation { model.invalidate() }
            let read = Task { try? await model.loadTargets() }
            for _ in 0..<200 {
                if delayed != nil { break }
                await Task.yield()
            }
            try #require(delayed != nil)
            if exit {
                try await state.prepareForAccountExit()
            } else {
                await state.activate(account: AccountItem.samples[1], runtime: runtime, connectivityAvailable: false)
                await state.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
            }
            delayed?.resume(returning: [])
            #expect(await read.value == nil && !model.offersFirstDeviceSetupAttempt)
            await #expect(throws: MarmotKitError.DeviceLinkingClosed) {
                try await model.approveFirstDeviceSetup(request: Data([1]))
            }
            #expect(calls == 0 && model.targets.isEmpty)
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
