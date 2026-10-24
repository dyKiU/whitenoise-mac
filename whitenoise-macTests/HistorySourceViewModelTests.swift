#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Testing

    @testable import whitenoise_mac

    @MainActor private final class SourceReviewProbe: HistorySourceTransferring {
        var isActive = true
        var snapshot: HistoryTransferSnapshotFfi? = .init(
            revision: 7, importedRecords: 0, complete: false, groupIdHex: "chat",
            sourceDevice: Data(repeating: 1, count: 32), recipientDevice: Data(repeating: 2, count: 32),
            snapshotTimestampCeiling: 100, recordCount: 2, encodedBytes: 900, fragmentCount: 1)
        var refreshed = 0
        var continued: [UInt64] = []
        var cancelled = 0
        func refresh() async throws { refreshed += 1 }
        func continueSource(displayedRevision: UInt64) async throws { continued.append(displayedRevision) }
        func cancel() {
            cancelled += 1
            isActive = false
            snapshot = nil
        }
    }

    private actor SourceQueryGate {
        private var entered = false
        private var entry: CheckedContinuation<Void, Never>?
        private var release: CheckedContinuation<Void, Never>?
        func pause() async {
            await withCheckedContinuation { continuation in
                release = continuation
                entered = true
                entry?.resume()
                entry = nil
            }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { entry = $0 }
        }
        func resume() {
            release?.resume()
            release = nil
        }
    }

    @MainActor struct HistorySourceViewModelTests {
        private let device = Data(repeating: 2, count: 32)
        private var choice: HistoryTransferRecipientFfi { .init(leafIndex: 3, device: device) }

        @Test func observationsAndSelectionDoNotBeginOrContinueAnOriginal() async throws {
            let original = SourceReviewProbe()
            var begun: [Data] = []
            let model = HistorySourceViewModel(
                groupIdHex: "chat", query: { [choice] in [choice] },
                begin: { value in
                    begun.append(value)
                    return original
                })
            try await model.loadRecipients()
            try model.select(device: device)
            #expect(begun.isEmpty)
            #expect(original.continued.isEmpty)
            #expect(model.review == nil)
            try await model.requestTransfer()
            #expect(begun == [device])
            #expect(model.transfer === original)
            #expect(original.refreshed == 1)
            await #expect(throws: MarmotKitError.HistoryTransferStaleRevision) {
                try await model.continueTransfer(displayedRevision: 6)
            }
            #expect(original.continued.isEmpty)
            try await model.continueTransfer(displayedRevision: 7)
            #expect(original.continued == [7])
            model.invalidate()
            #expect(original.cancelled == 1)
            #expect(model.review == nil)
        }

        @Test func malformedOrAmbiguousObservationsCannotBeSelected() async throws {
            let invalid: [[HistoryTransferRecipientFfi]] = [
                [.init(leafIndex: 1, device: Data(repeating: 1, count: 31))],
                [choice, .init(leafIndex: 4, device: device)],
                [choice, .init(leafIndex: 3, device: Data(repeating: 4, count: 32))],
            ]
            for values in invalid {
                let model = HistorySourceViewModel(
                    groupIdHex: "chat", query: { values },
                    begin: { _ in
                        Issue.record("Invalid choices cannot create a transfer")
                        return SourceReviewProbe()
                    })
                await #expect(throws: MarmotKitError.HistoryTransferNotReady) { try await model.loadRecipients() }
                #expect(model.recipients.isEmpty)
                #expect(model.selectedDevice == nil)
            }
        }

        @Test func explicitListedSelectionIsRequiredAndReloadClearsIt() async throws {
            let model = HistorySourceViewModel(
                groupIdHex: "chat", query: { [choice] in [choice] },
                begin: { _ in
                    Issue.record("No request may begin without an explicit current selection")
                    return SourceReviewProbe()
                })
            try await model.loadRecipients()
            await #expect(throws: MarmotKitError.HistoryTransferNotReady) { try await model.requestTransfer() }
            #expect(throws: MarmotKitError.HistoryTransferNotReady) {
                try model.select(device: Data(repeating: 9, count: 32))
            }
            try model.select(device: device)
            try await model.loadRecipients()
            #expect(model.selectedDevice == nil)
        }

        @Test func lateQueryCannotResurrectRetiredModel() async throws {
            let gate = SourceQueryGate()
            let model = HistorySourceViewModel(
                groupIdHex: "chat",
                query: { [choice] in
                    await gate.pause()
                    return [choice]
                }, begin: { _ in SourceReviewProbe() })
            let loading = Task { try await model.loadRecipients() }
            await gate.waitUntilEntered()
            model.invalidate()
            await gate.resume()
            await #expect(throws: MarmotKitError.HistoryTransferClosed) { try await loading.value }
            #expect(model.recipients.isEmpty)
        }

        @Test func lateOriginalIsCancelledAfterModelRetirement() async throws {
            let gate = SourceQueryGate()
            let original = SourceReviewProbe()
            let model = HistorySourceViewModel(
                groupIdHex: "chat", query: { [choice] in [choice] },
                begin: { _ in
                    await gate.pause()
                    return original
                })
            try await model.loadRecipients()
            try model.select(device: device)
            let request = Task { try await model.requestTransfer() }
            await gate.waitUntilEntered()
            model.invalidate()
            await gate.resume()
            await #expect(throws: MarmotKitError.HistoryTransferClosed) { try await request.value }
            #expect(original.cancelled == 1)
            #expect(original.refreshed == 0)
            #expect(model.transfer == nil)
        }

        @Test func cancellingPendingRequestRetiresItsLateOriginal() async throws {
            let gate = SourceQueryGate()
            let original = SourceReviewProbe()
            let model = HistorySourceViewModel(
                groupIdHex: "chat", query: { [choice] in [choice] },
                begin: { _ in
                    await gate.pause()
                    return original
                })
            try await model.loadRecipients()
            try model.select(device: device)
            let request = Task { try await model.requestTransfer() }
            await gate.waitUntilEntered()
            model.cancelTransfer()
            await gate.resume()
            await #expect(throws: MarmotKitError.HistoryTransferClosed) { try await request.value }
            #expect(original.cancelled == 1)
            #expect(original.refreshed == 0)
            #expect(model.transfer == nil)
        }

        @Test func originalMustMatchSelectedChatAndRecipient() async throws {
            let original = SourceReviewProbe()
            original.snapshot?.groupIdHex = "other-chat"
            let model = HistorySourceViewModel(
                groupIdHex: "chat", query: { [choice] in [choice] }, begin: { _ in original })
            try await model.loadRecipients()
            try model.select(device: device)
            await #expect(throws: MarmotKitError.HistoryTransferNotReady) { try await model.requestTransfer() }
            #expect(original.cancelled == 1)
            #expect(model.transfer == nil)
        }

        @Test func actualScopeRetiresChatModelAndCapturesExactRuntime() async throws {
            let runtime = FakeMarmotRuntime(accounts: [])
            let account = AccountItem.samples[0]
            let scope = AccountScope(account: account, runtime: runtime)
            let model = scope.historySourceModel(
                groupIdHex: "chat",
                query: { [choice] actual, ref, group in
                    #expect(nativeRuntimeObjectIdentity(actual) == nativeRuntimeObjectIdentity(runtime))
                    #expect(ref == account.accountRef)
                    #expect(group == "chat")
                    return [choice]
                })
            #expect(scope.historySourceModel(groupIdHex: "chat") === model)
            try await model.loadRecipients()
            scope.releaseConversation(groupIdHex: "chat")
            #expect(!model.isActive)
            #expect(model.recipients.isEmpty)
            let fresh = scope.historySourceModel(groupIdHex: "chat")
            #expect(fresh !== model)
            await scope.cancelAll()
            #expect(!fresh.isActive)
            let retired = scope.historySourceModel(
                groupIdHex: "never-opened",
                query: { _, _, _ in
                    Issue.record("A retired account cannot query Core")
                    return []
                })
            await #expect(throws: MarmotKitError.HistoryTransferClosed) { try await retired.loadRecipients() }
        }

        @Test func queryCannotAttachAcrossActualAccountReplacementAndReturn() async throws {
            let session = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            let accounts = AccountItem.samples
            await session.activate(account: accounts[0], runtime: runtime, connectivityAvailable: false)
            let scope = try #require(session.accountScope)
            let gate = SourceQueryGate()
            let model = scope.historySourceModel(
                groupIdHex: "chat",
                query: { [choice] _, _, _ in
                    await gate.pause()
                    return [choice]
                })
            let loading = Task { try await model.loadRecipients() }
            await gate.waitUntilEntered()
            await session.activate(account: accounts[1], runtime: runtime, connectivityAvailable: false)
            await session.activate(account: accounts[0], runtime: runtime, connectivityAvailable: false)
            await gate.resume()
            await #expect(throws: MarmotKitError.HistoryTransferClosed) { try await loading.value }
            #expect(!model.isActive)
            #expect(model.recipients.isEmpty)
            await session.deactivate()
        }
    }
#endif
