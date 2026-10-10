#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Observation

    /// One original SDK action; display snapshots never create authority.
    @MainActor @Observable final class NativeHistoryActionScope: HistoryConsentReviewing {
        let id = UUID()
        enum Role { case source, recipient }
        let accountRef: String
        let role: Role
        private(set) var isActive = true
        private(set) var isWorking = false
        private(set) var snapshot: HistoryTransferSnapshotFfi?
        @ObservationIgnored private let original: Original
        @ObservationIgnored private let expectedGroup: String?
        @ObservationIgnored private var selection: HistoryTransferSnapshotFfi?

        private nonisolated enum Original: Sendable {
            case source(any HistoryTransferProtocol)
            case recipient(any HistoryConsentProtocol)

            func snapshot() async throws -> HistoryTransferSnapshotFfi {
                switch self {
                case .source(let handle): return try await handle.snapshot()
                case .recipient(let handle): return try await handle.snapshot()
                }
            }
            func perform(revision: UInt64) async throws {
                switch self {
                case .source(let handle): try await handle.continueTransfer(revision: revision)
                case .recipient(let handle): try await handle.approve(revision: revision)
                }
            }
            func cancel() {
                switch self {
                case .source(let handle): handle.cancel()
                case .recipient(let handle): handle.cancel()
                }
            }
        }

        init(accountRef: String, groupIdHex: String, transfer: any HistoryTransferProtocol) {
            self.accountRef = accountRef
            role = .source
            expectedGroup = groupIdHex
            original = .source(transfer)
        }

        init(accountRef: String, consent: any HistoryConsentProtocol) {
            self.accountRef = accountRef
            role = .recipient
            expectedGroup = nil
            original = .recipient(consent)
        }

        private func checkActive() throws {
            try Task.checkCancellation()
            guard isActive else { throw MarmotKitError.HistoryTransferClosed }
        }

        private func startAction() throws {
            try checkActive()
            guard !isWorking else { throw MarmotKitError.HistoryTransferNotReady }
            isWorking = true
        }

        func refresh() async throws {
            try startAction()
            defer { isWorking = false }
            do { try await readSnapshot() } catch {
                snapshot = nil
                if Task.isCancelled { cancel() }
                throw error
            }
        }

        func perform(displayedRevision: UInt64) async throws {
            try checkActive()
            guard snapshot?.revision == displayedRevision else {
                throw MarmotKitError.HistoryTransferStaleRevision
            }
            try startAction()
            defer { isWorking = false }
            let original = original
            do {
                try await withTaskCancellationHandler {
                    try await original.perform(revision: displayedRevision)
                } onCancel: {
                    original.cancel()
                }
                try checkActive()
                try await readSnapshot()
            } catch {
                snapshot = nil
                if Task.isCancelled { cancel() }
                throw error
            }
        }

        func approveReview(displayedRevision: UInt64) async throws {
            guard role == .recipient else { throw MarmotKitError.HistoryTransferNotReady }
            try await perform(displayedRevision: displayedRevision)
        }

        func cancel() {
            guard isActive else { return }
            isActive = false
            snapshot = nil
            selection = nil
            original.cancel()
        }

        private func readSnapshot() async throws {
            let original = original
            let value = try await withTaskCancellationHandler {
                try await original.snapshot()
            } onCancel: {
                original.cancel()
            }
            try checkActive()
            guard !value.groupIdHex.isEmpty, value.groupIdHex.utf8.count <= 512,
                expectedGroup.map({ $0 == value.groupIdHex }) ?? true,
                value.sourceDevice.count == 32, value.recipientDevice.count == 32,
                selection.map({ sameSelection($0, value) }) ?? true
            else {
                cancel()
                throw MarmotKitError.HistoryTransferNotReady
            }
            if selection == nil { selection = value }
            snapshot = value
        }

        private func sameSelection(_ previous: HistoryTransferSnapshotFfi, _ value: HistoryTransferSnapshotFfi) -> Bool
        {
            previous.groupIdHex == value.groupIdHex && previous.sourceDevice == value.sourceDevice
                && previous.recipientDevice == value.recipientDevice
                && previous.snapshotTimestampCeiling == value.snapshotTimestampCeiling
                && previous.recordCount == value.recordCount && previous.encodedBytes == value.encodedBytes
                && previous.fragmentCount == value.fragmentCount
        }
    }
#endif
