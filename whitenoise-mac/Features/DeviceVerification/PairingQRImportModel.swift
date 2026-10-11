#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import Observation

    /// Stages transport text only. An explicit existing SDK action receives/authenticates it later.
    @MainActor @Observable final class PairingQRImportModel {
        typealias Current = @MainActor () -> Bool
        typealias Capture = @MainActor () -> Current
        typealias Decode = @Sendable (Data) async throws -> String
        private(set) var stagedPacket: String?
        @ObservationIgnored private let capture: Capture
        @ObservationIgnored private let decode: Decode
        // A file chooser can complete after dismissal without an owning Swift task to cancel.
        @ObservationIgnored private var pending: (UUID, Current)?

        init(
            capture: @escaping Capture,
            decode: @escaping Decode = { data in
                try await Task.detached(priority: .utility) { try PairingQRCode.readImage(data) }.value
            }
        ) {
            self.capture = capture
            self.decode = decode
        }
        func beginImport() -> UUID {
            stagedPacket = nil
            let id = UUID()
            pending = (id, capture())
            return id
        }
        func importImage(_ data: Data, ticket: UUID) async throws {
            guard let pending, pending.0 == ticket, pending.1(), !Task.isCancelled
            else { throw PairingQRCode.Failure.invalidPacket }
            let value = try await decode(data)
            guard self.pending?.0 == ticket, pending.1(), !Task.isCancelled
            else { throw PairingQRCode.Failure.invalidPacket }
            stagedPacket = value
            self.pending = nil
        }
        func cancel() {
            pending = nil
            stagedPacket = nil
        }
    }
#endif
