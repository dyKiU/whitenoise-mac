#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Observation

    @MainActor @Observable final class HistorySourceViewModel {
        typealias Query = @MainActor () async throws -> [HistoryTransferRecipientFfi]
        typealias Begin = @MainActor (Data) async throws -> any HistorySourceTransferring
        let groupIdHex: String
        private(set) var isActive = true
        private(set) var isWorking = false
        private(set) var recipients: [HistoryTransferRecipientFfi] = []
        private(set) var selectedDevice: Data?
        private(set) var transfer: (any HistorySourceTransferring)?
        var review: HistoryTransferSnapshotFfi? { isActive ? transfer?.snapshot : nil }
        @ObservationIgnored private let query: Query
        @ObservationIgnored private let begin: Begin

        init(groupIdHex: String, query: @escaping Query, begin: @escaping Begin) {
            self.groupIdHex = groupIdHex
            self.query = query
            self.begin = begin
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

        func loadRecipients() async throws {
            try startAction()
            defer { isWorking = false }
            guard transfer == nil else { throw MarmotKitError.HistoryTransferNotReady }
            recipients = []
            selectedDevice = nil
            let values = try await query()
            try checkActive()
            guard values.count <= 128, values.allSatisfy({ $0.device.count == 32 }),
                Set(values.map(\.device)).count == values.count,
                Set(values.map(\.leafIndex)).count == values.count
            else { throw MarmotKitError.HistoryTransferNotReady }
            recipients = values
        }

        func select(device: Data) throws {
            try checkActive()
            guard !isWorking, transfer == nil, recipients.contains(where: { $0.device == device }) else {
                throw MarmotKitError.HistoryTransferNotReady
            }
            selectedDevice = device
        }

        func requestTransfer() async throws {
            try startAction()
            defer { isWorking = false }
            guard transfer == nil, let device = selectedDevice,
                recipients.contains(where: { $0.device == device })
            else { throw MarmotKitError.HistoryTransferNotReady }
            // The native factory revalidates the current roster and creates fresh authority.
            let original = try await begin(device)
            do {
                try checkActive()
                guard selectedDevice == device else { throw MarmotKitError.HistoryTransferClosed }
                try await original.refresh()
                try checkActive()
                guard selectedDevice == device, original.isActive, let snapshot = original.snapshot,
                    snapshot.groupIdHex == groupIdHex, snapshot.recipientDevice == device
                else { throw MarmotKitError.HistoryTransferNotReady }
                transfer = original
            } catch {
                original.cancel()
                throw error
            }
        }

        func refreshTransfer() async throws {
            try startAction()
            defer { isWorking = false }
            guard let original = transfer, original.isActive else { throw MarmotKitError.HistoryTransferNotReady }
            try await original.refresh()
            try checkActive()
        }

        func continueTransfer(displayedRevision: UInt64) async throws {
            try startAction()
            defer { isWorking = false }
            guard let original = transfer, original.isActive, let snapshot = original.snapshot, !snapshot.complete
            else { throw MarmotKitError.HistoryTransferNotReady }
            guard snapshot.revision == displayedRevision else { throw MarmotKitError.HistoryTransferStaleRevision }
            try await original.continueSource(displayedRevision: displayedRevision)
            try checkActive()
        }

        func cancelTransfer() {
            transfer?.cancel()
            transfer = nil
            recipients = []
            selectedDevice = nil
        }

        func invalidate() {
            isActive = false
            cancelTransfer()
        }
    }
#endif
