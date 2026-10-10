#if WN_EXPERIMENTAL_DEVICE_SYNC
    import MarmotKit

    /// Actions on a retained original source transfer, never on a recipient observation.
    @MainActor protocol HistorySourceTransferring: AnyObject {
        var isActive: Bool { get }
        var snapshot: HistoryTransferSnapshotFfi? { get }
        func refresh() async throws
        func continueSource(displayedRevision: UInt64) async throws
        func cancel()
    }
#endif
