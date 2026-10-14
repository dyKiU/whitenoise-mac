#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Observation

    /// Native lifetime for one original SDK session; observations never restore permission.
    @MainActor
    @Observable
    final class DeviceLinkingScope: DeviceVerificationSession {
        let accountRef: String
        @ObservationIgnored private var automaticBootstrap: Data?
        private(set) var latestSnapshot: DeviceLinkingSnapshotFfi?
        private(set) var cleanupError: Error?
        private(set) var observationError: Error?
        @ObservationIgnored private let session: any DeviceLinkingSessionProtocol
        @ObservationIgnored private let subscription: DeviceLinkingSubscription
        @ObservationIgnored private var observation: Task<Void, Never>?
        @ObservationIgnored private var cleanup: Task<Void, Error>?
        @ObservationIgnored private var active = true

        init(accountRef: String, session: any DeviceLinkingSessionProtocol) {
            self.accountRef = accountRef
            self.session = session
            self.subscription = session.subscribe()
            let subscription = self.subscription
            observation = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let snapshot = try await subscription.next()
                        guard !Task.isCancelled, let self, self.active else { return }
                        self.latestSnapshot = snapshot
                    }
                } catch {
                    guard !Task.isCancelled, let self, self.active else { return }
                    self.observationError = error
                }
            }
        }

        private func checkActive() throws {
            guard active else { throw MarmotKitError.DeviceLinkingClosed }
        }

        /// Activate only after the exact original has been adopted by this live account scope.
        func activateAutomaticPairing(displayBootstrap: Bool) async throws {
            try checkActive()
            let code = try await session.automaticPairingCode()
            try checkActive()
            automaticBootstrap = displayBootstrap ? Data(code.utf8) : Data()
        }

        func setupPacket() throws -> Data {
            try checkActive()
            return automaticBootstrap ?? session.setupPacket()
        }

        // Explicit enrollment actions remain on the original account-owned SDK object.
        func continueLinking(displayedRevision: UInt64) async throws {
            try checkActive()
            if automaticBootstrap != nil {
                try await session.continueAutomaticLinking(displayedRevision: displayedRevision, shareChats: false)
            } else {
                try await session.continueLinking(displayedRevision: displayedRevision)
            }
            try checkActive()
        }

        // Broad chat sharing is a distinct explicit action; ordinary linking remains separate.
        func continueLinkingAndShareChats(displayedRevision: UInt64) async throws {
            try checkActive()
            if automaticBootstrap != nil {
                try await session.continueAutomaticLinking(displayedRevision: displayedRevision, shareChats: true)
            } else {
                try await session.continueLinkingAndShareChats(displayedRevision: displayedRevision)
            }
            try checkActive()
        }

        func enrollmentPacket(displayedRevision: UInt64) async throws -> Data {
            try checkActive()
            let packet = try await session.enrollmentPacket(displayedRevision: displayedRevision)
            try checkActive()
            return packet
        }

        func receiveEnrollmentPacket(displayedRevision: UInt64, packet: Data) async throws {
            try checkActive()
            try await session.receiveEnrollmentPacket(displayedRevision: displayedRevision, packet: packet)
            try checkActive()
        }

        func finalizeLinking(displayedRevision: UInt64) async throws {
            try checkActive()
            try await session.finalizeLinking(displayedRevision: displayedRevision)
            try checkActive()
        }

        func outgoingPackets() async throws -> [DeviceLinkingOutgoingPacketFfi] {
            try checkActive()
            let packets = try await session.outgoingPackets()
            try checkActive()
            return packets
        }

        func receiveSetupPacket(_ packet: Data) async throws {
            try checkActive()
            try await session.receiveSetupPacket(packet: packet)
            try checkActive()
        }

        func receivePacket(_ packet: Data) async throws {
            try checkActive()
            try await session.receivePacket(packet: packet)
            try checkActive()
        }

        func acknowledgePacket(_ acknowledgementID: String) async throws {
            try checkActive()
            try await session.acknowledgePacket(acknowledgementId: acknowledgementID)
            try checkActive()
        }

        func confirmComparison(displayedRevision: UInt64) async throws {
            try checkActive()
            try await session.confirmComparison(displayedRevision: displayedRevision)
            try checkActive()
        }

        func invalidate() {
            guard active else { return }
            active = false
            automaticBootstrap = nil
            latestSnapshot = nil
            subscription.closeStream()
            observation?.cancel()
            observation = nil
        }

        func cancel() async throws {
            invalidate()
            let task: Task<Void, Error>
            if let cleanup {
                task = cleanup
            } else {
                let session = self.session
                task = Task { try await session.cancel() }
                cleanup = task
            }
            do {
                try await task.value
                cleanupError = nil
            } catch {
                cleanupError = error
                cleanup = nil
                throw error
            }
        }
    }
#endif
