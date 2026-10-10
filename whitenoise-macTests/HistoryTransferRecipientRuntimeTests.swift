#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Testing

    @testable import whitenoise_mac

    // This query fixture creates no identities and never accesses a profile Keychain.
    nonisolated private final class RecipientQueryStore: SecretStore {
        func hasSecretForLabel(label: String) throws -> Bool { false }
        func hasSecretForAccountId(accountIdHex: String) throws -> Bool { false }
        func writeSecret(label: String, accountIdHex: String, secretKeyHex: String) throws { throw Refusal.unexpected }
        func loadSecret(label: String, accountIdHex: String) throws -> String { throw Refusal.unexpected }
        func removeSecret(label: String, accountIdHex: String) throws { throw Refusal.unexpected }
        private enum Refusal: Error { case unexpected }
    }

    @MainActor struct HistoryTransferRecipientRuntimeTests {
        @Test func nativeQueryPreservesMalformedGroupAndUnavailableAccountRefusals() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecipientQuery-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let client = try MarmotClient(
                rootPath: root.path, relayUrls: [], storageProfile: .testHost,
                secretStore: RecipientQueryStore())
            let runtime: any MarmotRuntime = client
            do {
                for group in ["", "invalid", String(repeating: "ab", count: 256)] {
                    do {
                        _ = try await runtime.historyTransferRecipients(accountRef: "missing", groupIdHex: group)
                        Issue.record("Malformed groups must be refused by the native query")
                    } catch {
                        #expect((error as? MarmotKitError) == .HistoryTransferNotReady)
                    }
                }
                do {
                    _ = try await runtime.historyTransferRecipients(
                        accountRef: "missing", groupIdHex: String(repeating: "ab", count: 16))
                    Issue.record("A missing account must not produce recipient observations")
                } catch {
                    #expect((error as? MarmotKitError) == .HistoryTransferRuntimeUnavailable)
                }
                let accounts = try runtime.listAccounts()
                #expect(accounts.isEmpty)
                try await client.marmot.shutdownAndClose()
            } catch {
                try await client.marmot.shutdownAndClose()
                throw error
            }
        }

        @Test func fakeQueryDefaultsToUnsupportedWithoutCreatingAccounts() async throws {
            let runtime: any MarmotRuntime = FakeMarmotRuntime(accounts: [])
            do {
                _ = try await runtime.historyTransferRecipients(accountRef: "missing", groupIdHex: "invalid")
                Issue.record("The shared fake must not manufacture recipient choices")
            } catch {
                #expect((error as? MarmotKitError) == .HistoryTransferUnsupported)
            }
            let accounts = try runtime.listAccounts()
            #expect(accounts.isEmpty)
        }
    }
#endif
