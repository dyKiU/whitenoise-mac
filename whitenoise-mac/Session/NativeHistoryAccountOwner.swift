#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Observation

    /// One account/runtime lifetime; original factories retain custody until their result retires.
    @MainActor @Observable final class NativeHistoryAccountOwner {
        private(set) var isActive = true
        private(set) var transfer: NativeHistoryActionScope?
        private(set) var consents: [NativeHistoryActionScope] = []
        @ObservationIgnored private let accountRef: String
        @ObservationIgnored private let runtime: any MarmotRuntime
        @ObservationIgnored private var cancelFactory: (() -> Void)?

        init(accountRef: String, runtime: any MarmotRuntime) {
            self.accountRef = accountRef
            self.runtime = runtime
        }

        func adoptTransfer(
            groupIdHex: String,
            _ factory: @escaping @MainActor (any MarmotRuntime, String) async throws -> any HistoryTransferProtocol
        ) async throws -> NativeHistoryActionScope {
            guard transfer?.isActive != true else { throw MarmotKitError.HistoryTransferNotReady }
            let held = try await adopt(factory) { original in
                NativeHistoryActionScope(accountRef: self.accountRef, groupIdHex: groupIdHex, transfer: original)
            } retire: {
                $0.cancel()
            }
            transfer = held
            return held
        }

        func adoptConsents(
            _ factory: @escaping @MainActor (any MarmotRuntime, String) async throws -> [any HistoryConsentProtocol]
        ) async throws -> [NativeHistoryActionScope] {
            consents.removeAll { !$0.isActive }
            guard consents.isEmpty else { return consents }
            let originals = try await adopt(
                factory, make: { $0 },
                retire: { values in
                    for original in values { original.cancel() }
                })
            guard originals.count <= 128 else {
                for original in originals { original.cancel() }
                throw MarmotKitError.HistoryTransferNotReady
            }
            consents = originals.map { NativeHistoryActionScope(accountRef: accountRef, consent: $0) }
            return consents
        }

        private func adopt<Original: Sendable, Held>(
            _ factory: @escaping @MainActor (any MarmotRuntime, String) async throws -> Original,
            make: (Original) -> Held,
            retire: (Held) -> Void
        ) async throws -> Held {
            try Task.checkCancellation()
            guard isActive else { throw MarmotKitError.HistoryTransferClosed }
            guard cancelFactory == nil else { throw MarmotKitError.HistoryTransferNotReady }
            let task = Task {
                try Task.checkCancellation()
                return try await factory(runtime, accountRef)
            }
            cancelFactory = { task.cancel() }
            defer { cancelFactory = nil }
            let original = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            let held = make(original)
            guard isActive, !Task.isCancelled else {
                retire(held)
                throw MarmotKitError.HistoryTransferClosed
            }
            return held
        }

        func release(_ held: NativeHistoryActionScope) {
            guard transfer === held || consents.contains(where: { $0 === held }) else { return }
            held.cancel()
            if transfer === held { transfer = nil }
            consents.removeAll { $0 === held }
        }

        func invalidate() {
            guard isActive else { return }
            isActive = false
            cancelFactory?()
            transfer?.cancel()
            for consent in consents { consent.cancel() }
            transfer = nil
            consents = []
        }

        /// Do not close Core while an ignored-cancellation factory still owns a future original.
        func retryCleanup() throws {
            guard cancelFactory == nil else { throw MarmotKitError.HistoryTransferNotReady }
        }
    }
#endif
