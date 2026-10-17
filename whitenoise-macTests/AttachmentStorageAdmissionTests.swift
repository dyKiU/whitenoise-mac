import MarmotKit
import Testing

@testable import whitenoise_mac

#if WN_EXPERIMENTAL_DEVICE_SYNC
    struct AttachmentStorageAdmissionTests {
        @Test func storagePressureKeepsCheckpointRetryAndRemovalAvailable() {
            let status = AttachmentTransferStatusFfi(
                reference: "synthetic-checkpoint", state: .storageBlocked,
                attempt: 1, received: 16, total: 32, retryAt: nil)

            #expect(!status.isWorking)
            #expect(status.canRetry)
            #expect(status.canRemove)
            #expect(status.received == 16)
            #expect(!status.state.needsRearmToDownload)
        }
    }
#endif
