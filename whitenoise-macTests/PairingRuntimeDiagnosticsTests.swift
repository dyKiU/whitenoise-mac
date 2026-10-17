import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

#if WN_EXPERIMENTAL_DEVICE_SYNC
    @MainActor @Suite struct PairingRuntimeDiagnosticsTests {
        private func failure(_ kind: String, account: String = "aabb") -> MarmotEventFfi {
            .accountError(
                accountIdHex: account, accountLabel: "sensitive-label", message: "runtime receive failed: " + kind)
        }

        @Test func exportsExactErrorKindForOnlyTheSelectedAccount() {
            #expect(
                PairingRuntimeDiagnostics.receiveFailure(failure("linking_welcome_denied"), accountIdHex: "AABB")
                    == "linking_welcome_denied")
            #expect(
                PairingRuntimeDiagnostics.receiveFailure(failure("storage_busy"), accountIdHex: "aabb")
                    == "storage_busy")
            #expect(
                PairingRuntimeDiagnostics.receiveFailure(
                    failure("invalid_welcome", account: "ccdd"), accountIdHex: "aabb") == nil)
        }

        @Test func backendDetailsAndUnknownKindsCannotEscape() {
            for value in [
                "sensitive-backend-details", "invalid_welcome: sensitive-details", "invalid_welcome\nsecret", "",
            ] {
                #expect(
                    PairingRuntimeDiagnostics.receiveFailure(failure(value), accountIdHex: "aabb") == "unclassified")
            }
            #expect(
                PairingRuntimeDiagnostics.receiveFailure(
                    .accountError(accountIdHex: "aabb", accountLabel: "private", message: "other failure: private"),
                    accountIdHex: "aabb") == nil)
        }

        @Test func disabledDiagnosticsDoNotSubscribe() {
            let runtime = FakeMarmotRuntime(accounts: [])
            #expect(PairingRuntimeDiagnostics.start(runtime: runtime, accountIdHex: "aabb", enabled: false) == nil)
            #expect(runtime.eventHub.subscriberCount == 0)
        }

        @Test func originalScopeOwnsAndCancelsTheRuntimeObservation() async throws {
            let runtime = FakeMarmotRuntime(accounts: [])
            var received: [String] = []
            let task = try #require(
                PairingRuntimeDiagnostics.start(
                    runtime: runtime, accountIdHex: "aabb", enabled: true, emit: { received.append($0) }))
            let original = LifetimeSession(noPointer: .init())
            let owner = DeviceLinkingScope(accountRef: "test", session: original, runtimeDiagnostics: task)
            #expect(runtime.eventHub.subscriberCount == 1)
            runtime.eventHub.emit(failure("invalid_welcome"))
            for _ in 0..<200 {
                if received == ["invalid_welcome"] { break }
                await Task.yield()
            }
            #expect(received == ["invalid_welcome"])
            owner.invalidate()
            #expect(task.isCancelled)
            runtime.eventHub.emit(failure("storage_busy"))
            await task.value
            #expect(received == ["invalid_welcome"])
            #expect(runtime.eventHub.subscriberCount == 0)
            try await owner.cancel()
            original.stream.finishWithClosed()
        }
    }
#endif
