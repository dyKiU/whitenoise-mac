#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Observation

    @MainActor @Observable
    final class DeviceVerificationViewModel {
        @ObservationIgnored private let beginOriginal: @MainActor () async throws -> any DeviceVerificationSession
        @ObservationIgnored private let cancelOriginal: @MainActor () async throws -> Void
        private(set) var owner: (any DeviceVerificationSession)?
        private(set) var isActive = true
        private(set) var isStarting = false
        @ObservationIgnored private var pending: Task<any DeviceVerificationSession, Error>?
        var snapshot: DeviceLinkingSnapshotFfi? { isActive ? owner?.latestSnapshot : nil }

        init(
            begin: @escaping @MainActor () async throws -> any DeviceVerificationSession,
            cancel: @escaping @MainActor () async throws -> Void
        ) {
            beginOriginal = begin
            cancelOriginal = cancel
        }

        func begin() async throws {
            guard isActive, owner == nil, !isStarting else { throw MarmotKitError.DeviceLinkingClosed }
            isStarting = true
            let beginOriginal = self.beginOriginal
            let task = Task { try await beginOriginal() }
            pending = task
            defer {
                isStarting = false
                pending = nil
            }
            // The Session factory retains exact account/runtime ownership and cleans late SDK results.
            let original = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard isActive, !Task.isCancelled, !task.isCancelled else { throw MarmotKitError.DeviceLinkingClosed }
            owner = original
        }
        func confirm(displayedRevision: UInt64) async throws {
            guard isActive, let original = owner else { throw MarmotKitError.DeviceLinkingClosed }
            try await original.confirmComparison(displayedRevision: displayedRevision)
            guard isActive, owner === original else { throw MarmotKitError.DeviceLinkingClosed }
        }
        func cancel() async throws {
            pending?.cancel()
            owner = nil
            try await cancelOriginal()
        }

        func invalidate() {
            isActive = false
            pending?.cancel()
            owner = nil
        }
    }
#endif
