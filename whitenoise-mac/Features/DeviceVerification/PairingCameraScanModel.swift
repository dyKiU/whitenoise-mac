#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import Observation

    /// Stages a single bootstrap; scanning never confirms comparison or grants trust.
    @MainActor @Observable final class PairingCameraScanModel {
        @ObservationIgnored private let isCurrent: @MainActor () -> Bool
        @ObservationIgnored private let onScan: @MainActor (String) -> Void
        private var closed = false
        private(set) var failed = false
        var canScan: Bool { !closed && isCurrent() }

        init(isCurrent: @escaping @MainActor () -> Bool, onScan: @escaping @MainActor (String) -> Void) {
            self.isCurrent = isCurrent
            self.onScan = onScan
        }
        nonisolated static func bootstrap(from payload: String) -> String? {
            guard let packet = try? PairingQRCode.decode(payload),
                let bytes = Data(base64Encoded: packet), bytes.count <= 1024,
                String(data: bytes, encoding: .utf8)?.hasPrefix("WNPAIR1:") == true
            else { return nil }
            return packet
        }
        func receive(_ payload: String) {
            guard canScan, let packet = Self.bootstrap(from: payload) else { return }
            closed = true
            onScan(packet)
        }
        func fail() {
            guard canScan else { return }
            closed = true
            failed = true
        }
        func close() { closed = true }
    }
#endif
