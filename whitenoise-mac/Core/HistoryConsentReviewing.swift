#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit

    /// Display/action interface over one held original; its row ID is not permission.
    @MainActor protocol HistoryConsentReviewing: AnyObject {
        var id: UUID { get }
        var isActive: Bool { get }
        var snapshot: HistoryTransferSnapshotFfi? { get }
        func refresh() async throws
        func approveReview(displayedRevision: UInt64) async throws
        func cancel()
    }
#endif
