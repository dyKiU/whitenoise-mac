#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import Observation

    /// Stages transport text only. An explicit existing SDK action receives/authenticates it later.
    @MainActor @Observable final class PairingQRImportModel {
        typealias Current = @MainActor () -> Bool
        typealias Capture = @MainActor () -> Current
        typealias Decode = @Sendable (Data) async throws -> String
        private(set) var stagedPacket: String?
        private(set) var receivedFrameCount = 0
        private(set) var totalFrameCount: Int?
        private(set) var didExpire = false
        @ObservationIgnored private let capture: Capture
        @ObservationIgnored private let decode: Decode
        @ObservationIgnored private let importLifetime: Duration
        // A file chooser can complete after dismissal without an owning Swift task to cancel.
        @ObservationIgnored private var pending: (UUID, Current)?
        @ObservationIgnored private var fragments: PairingQRCode.FragmentAccumulator?
        @ObservationIgnored private var fragmentOwner: Current?
        @ObservationIgnored private var packetOwner: Current?
        @ObservationIgnored private var expiryTask: Task<Void, Never>?
        var currentStagedPacket: String? { packetOwner?() == true ? stagedPacket : nil }

        init(
            capture: @escaping Capture,
            importLifetime: Duration = .seconds(120),
            decode: @escaping Decode = { data in
                try await Task.detached(priority: .utility) {
                    let payload = try PairingQRCode.readImagePayload(data)
                    if payload.hasPrefix("whitenoise-pairing:v3:part:") { return payload }
                    return try PairingQRCode.decode(payload)
                }.value
            }
        ) {
            self.capture = capture
            self.decode = decode
            self.importLifetime = min(importLifetime, .seconds(120))
        }
        func beginImport() -> UUID {
            if stagedPacket != nil || fragmentOwner?() == false { cancel() }
            didExpire = false
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
            if value.hasPrefix("whitenoise-pairing:v3:part:") {
                if fragments == nil {
                    fragments = PairingQRCode.FragmentAccumulator()
                    fragmentOwner = pending.1
                    let lifetime = importLifetime
                    expiryTask = Task { [weak self] in
                        do { try await Task.sleep(for: lifetime) } catch { return }
                        guard !Task.isCancelled else { return }
                        self?.expire()
                    }
                }
                guard fragmentOwner?() == true else {
                    cancel()
                    throw PairingQRCode.Failure.invalidPacket
                }
                do {
                    stagedPacket = try fragments?.ingest(value)
                    receivedFrameCount = fragments?.receivedFrameCount ?? 0
                    totalFrameCount = fragments?.totalFrameCount
                } catch PairingQRCode.Failure.expired {
                    expire()
                    throw PairingQRCode.Failure.expired
                }
                if stagedPacket == nil { return }
            } else {
                guard let bytes = Data(base64Encoded: value), !bytes.isEmpty,
                    bytes.count <= PairingQRCode.maximumPacketBytes,
                    bytes.base64EncodedString() == value
                else { throw PairingQRCode.Failure.invalidPacket }
                stagedPacket = value
            }
            expiryTask?.cancel()
            expiryTask = nil
            packetOwner = pending.1
            self.pending = nil
        }
        func cancel() {
            expiryTask?.cancel()
            expiryTask = nil
            fragments?.reset()
            fragments = nil
            fragmentOwner = nil
            packetOwner = nil
            receivedFrameCount = 0
            totalFrameCount = nil
            didExpire = false
            pending = nil
            stagedPacket = nil
        }
        private func expire() {
            cancel()
            didExpire = true
        }
        deinit { expiryTask?.cancel() }
    }
#endif
