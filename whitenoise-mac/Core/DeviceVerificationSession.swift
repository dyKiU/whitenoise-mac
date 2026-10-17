#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit

    /// Verification/transport only. The original SDK object remains the authority.
    @MainActor
    protocol DeviceVerificationSession: AnyObject {
        var latestSnapshot: DeviceLinkingSnapshotFfi? { get }
        func setupPacket() throws -> Data
        func outgoingPackets() async throws -> [DeviceLinkingOutgoingPacketFfi]
        func receiveSetupPacket(_ packet: Data) async throws
        func receivePacket(_ packet: Data) async throws
        func acknowledgePacket(_ acknowledgementID: String) async throws
        func confirmComparison(displayedRevision: UInt64) async throws
    }
#endif
