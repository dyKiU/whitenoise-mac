#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit

    /// Only bounded categories cross the diagnostic boundary, never native details.
    nonisolated enum DeviceVerificationFailure: String {
        case invalidPacket = "invalid_packet"
        case closed = "closed"
        case notReady = "not_ready"
        case staleRevision = "stale_revision"
        case runtimeUnavailable = "runtime_unavailable"
        case secretStoreUnavailable = "secret_store_unavailable"
        case unsupported = "unsupported"
        case cancelled = "cancelled"
        case other = "other"

        init(_ error: any Error) {
            if error is CancellationError {
                self = .cancelled
                return
            }
            switch error as? MarmotKitError {
            case .DeviceLinkingInvalidPacket: self = .invalidPacket
            case .DeviceLinkingClosed: self = .closed
            case .DeviceLinkingNotReady: self = .notReady
            case .DeviceLinkingStaleRevision: self = .staleRevision
            case .DeviceLinkingRuntimeUnavailable: self = .runtimeUnavailable
            case .KeystoreUnavailable: self = .secretStoreUnavailable
            case .DeviceLinkingUnsupported: self = .unsupported
            default: self = .other
            }
        }
    }
#endif
