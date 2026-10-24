#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Observation

    @MainActor protocol NativeSelectedChatHandle: AnyObject {
        func invalidate()
        func cancel() async throws
    }
    extension NativeSelectedChatCopyScope: NativeSelectedChatHandle {}
    extension NativeSelectedChatConsentScope: NativeSelectedChatHandle {}

    /// One account/runtime lifetime. A retired owner never becomes active again.
    @MainActor @Observable final class NativeSelectedChatAccountOwner {
        private(set) var isActive = true
        private(set) var copy: NativeSelectedChatCopyScope?
        private(set) var consent: NativeSelectedChatConsentScope?
        @ObservationIgnored private let accountRef: String
        @ObservationIgnored private let runtime: any MarmotRuntime
        @ObservationIgnored private var cancelFactory: (() -> Void)?
        @ObservationIgnored private var retiring: [any NativeSelectedChatHandle] = []
        @ObservationIgnored private var cleanup: Task<Void, Error>?

        init(accountRef: String, runtime: any MarmotRuntime) {
            self.accountRef = accountRef
            self.runtime = runtime
        }

        func adoptCopy(
            _ factory: @escaping @MainActor (any MarmotRuntime, String) async throws -> any SelectedChatCopyProtocol
        ) async throws -> NativeSelectedChatCopyScope {
            if let copy {
                guard !copy.isActive else { throw MarmotKitError.SelectedChatCopyBusy }
                try await copy.cancel()
                self.copy = nil
            }
            return try await adopt(
                factory, make: { NativeSelectedChatCopyScope(accountRef: self.accountRef, original: $0) },
                install: { self.copy = $0 })
        }

        func adoptConsent(
            _ factory: @escaping @MainActor (any MarmotRuntime, String) async throws -> any SelectedChatConsentProtocol
        ) async throws -> NativeSelectedChatConsentScope {
            if let consent {
                guard !consent.isActive else { throw MarmotKitError.SelectedChatCopyBusy }
                try await consent.cancel()
                self.consent = nil
            }
            return try await adopt(
                factory, make: { NativeSelectedChatConsentScope(accountRef: self.accountRef, original: $0) },
                install: { self.consent = $0 })
        }

        private func adopt<Original: Sendable, Handle: NativeSelectedChatHandle>(
            _ factory: @escaping @MainActor (any MarmotRuntime, String) async throws -> Original,
            make: (Original) -> Handle,
            install: (Handle) -> Void
        ) async throws -> Handle {
            try Task.checkCancellation()
            guard isActive else { throw MarmotKitError.SelectedChatCopyClosed }
            guard cancelFactory == nil else { throw MarmotKitError.SelectedChatCopyBusy }
            // A cancelled caller can leave its late original here while this account remains active.
            try await finishCleanup()
            try Task.checkCancellation()
            guard isActive else { throw MarmotKitError.SelectedChatCopyClosed }
            guard cancelFactory == nil else { throw MarmotKitError.SelectedChatCopyBusy }
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
                held.invalidate()
                retiring.append(held)
                try await finishCleanup()
                throw MarmotKitError.SelectedChatCopyClosed
            }
            install(held)
            return held
        }

        func invalidate() {
            guard isActive else { return }
            isActive = false
            cancelFactory?()
            if let copy {
                copy.invalidate()
                retiring.append(copy)
            }
            if let consent {
                consent.invalidate()
                retiring.append(consent)
            }
            copy = nil
            consent = nil
            if !retiring.isEmpty { cleanup = Task { try await cleanupRetired() } }
        }

        /// An ignored-cancellation factory still owns its future result and fences Core teardown.
        func retryCleanup() async throws {
            try await finishCleanup()
            guard cancelFactory == nil else { throw MarmotKitError.SelectedChatCopyBusy }
        }

        private func finishCleanup() async throws {
            while !retiring.isEmpty {
                let task: Task<Void, Error>
                if let cleanup {
                    task = cleanup
                } else {
                    task = Task { try await cleanupRetired() }
                    cleanup = task
                }
                do {
                    try await task.value
                    cleanup = nil
                } catch {
                    cleanup = nil
                    throw error
                }
            }
        }

        private func cleanupRetired() async throws {
            var firstError: Error?
            for held in retiring {
                do {
                    try await held.cancel()
                    retiring.removeAll { $0 === held }
                } catch { if firstError == nil { firstError = error } }
            }
            if let firstError { throw firstError }
        }
    }
#endif
