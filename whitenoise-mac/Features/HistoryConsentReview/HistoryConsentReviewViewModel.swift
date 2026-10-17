#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Observation

    @MainActor @Observable final class HistoryConsentReviewViewModel {
        typealias Loader = @MainActor () async throws -> [any HistoryConsentReviewing]
        private(set) var isActive = true
        private(set) var isWorking = false
        private(set) var requests: [any HistoryConsentReviewing] = []
        private(set) var selected: (any HistoryConsentReviewing)?
        var review: HistoryTransferSnapshotFfi? { isActive ? selected?.snapshot : nil }
        @ObservationIgnored private let load: Loader

        init(load: @escaping Loader) { self.load = load }
        private func checkActive() throws {
            try Task.checkCancellation()
            guard isActive else { throw MarmotKitError.HistoryTransferClosed }
        }

        private func startAction() throws {
            try checkActive()
            guard !isWorking else { throw MarmotKitError.HistoryTransferNotReady }
            isWorking = true
        }

        func loadPending() async throws {
            try startAction()
            defer { isWorking = false }
            selected = nil
            requests = []
            let originals = try await load()
            try checkActive()
            guard originals.count <= 128, Set(originals.map(\.id)).count == originals.count else {
                throw MarmotKitError.HistoryTransferNotReady
            }
            requests = originals.filter(\.isActive)
            for request in requests {
                do { try await request.refresh() } catch {
                    try checkActive()
                    // One unreadable original must not prevent reviewing another.
                }
                try checkActive()
            }
        }

        func select(id: UUID) async throws {
            try startAction()
            defer { isWorking = false }
            selected = nil
            guard let original = requests.first(where: { $0.id == id && $0.isActive }) else {
                throw MarmotKitError.HistoryTransferNotReady
            }
            try await original.refresh()
            try checkActive()
            guard original.isActive, original.snapshot != nil else { throw MarmotKitError.HistoryTransferNotReady }
            selected = original
        }

        func approve(displayedRevision: UInt64) async throws {
            try startAction()
            defer { isWorking = false }
            guard let original = selected, original.isActive, let review = original.snapshot,
                !review.complete
            else { throw MarmotKitError.HistoryTransferNotReady }
            guard review.revision == displayedRevision else { throw MarmotKitError.HistoryTransferStaleRevision }
            try await original.approveReview(displayedRevision: displayedRevision)
            try checkActive()
        }

        func cancelSelected() {
            guard isActive, let original = selected else { return }
            original.cancel()
            requests.removeAll { $0.id == original.id }
            selected = nil
        }
        func invalidate() {
            isActive = false
            requests = []
            selected = nil
        }
    }
#endif
