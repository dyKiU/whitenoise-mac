#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import Testing

    @testable import whitenoise_mac

    // SDK callbacks run off the main actor; the lock owns all mutable test credentials.
    nonisolated private final class IsolatedBoundaryStore: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var secrets: [String: String] = [:]
        private var labels: Set<String> = []
        private var writes = 0
        let refusesWrites: Bool
        let refusesRemoval: Bool
        init(refusesWrites: Bool = false, refusesRemoval: Bool = false) {
            self.refusesWrites = refusesWrites
            self.refusesRemoval = refusesRemoval
        }
        var writeCount: Int { lock.withLock { writes } }
        func hasSecretForLabel(label: String) throws -> Bool { lock.withLock { labels.contains(label) } }
        func hasSecretForAccountId(accountIdHex: String) throws -> Bool {
            lock.withLock { secrets[accountIdHex] != nil }
        }
        func writeSecret(label: String, accountIdHex: String, secretKeyHex: String) throws {
            try lock.withLock {
                writes += 1
                guard !refusesWrites else { throw Refusal.write }
                secrets[accountIdHex] = secretKeyHex
                labels.insert(label)
            }
        }
        func loadSecret(label: String, accountIdHex: String) throws -> String {
            try lock.withLock {
                guard let secret = secrets[accountIdHex] else { throw Refusal.write }
                return secret
            }
        }
        func removeSecret(label: String, accountIdHex: String) throws {
            try lock.withLock {
                guard !refusesRemoval else { throw Refusal.removal }
                secrets.removeValue(forKey: accountIdHex)
                labels.remove(label)
            }
        }
        private enum Refusal: Error { case write, removal }
    }

    @Suite(.serialized) @MainActor struct NativeSecretStoreBoundaryTests {
        private static let relay = "ws://127.0.0.1:18181"

        @Test func suppliedStoreOwnsActualIdentityAcrossEncryptedReopen() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeBoundary-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = IsolatedBoundaryStore()
            let client = try MarmotClient(
                rootPath: root.path, relayUrls: [Self.relay], storageProfile: .testHost,
                secretStore: store, relayPolicy: .allowLoopback)
            let account: String
            do {
                try await client.start()
                let identity = try await client.marmot.createIdentity(
                    defaultRelays: [Self.relay], bootstrapRelays: [Self.relay], inboxRelays: [Self.relay])
                account = identity.accountIdHex
                #expect(store.writeCount == 1)
                #expect(try store.hasSecretForAccountId(accountIdHex: account))
                try await client.marmot.shutdownAndClose()
            } catch {
                try await client.marmot.shutdownAndClose()
                throw error
            }
            let reopened = try MarmotClient(
                rootPath: root.path, relayUrls: [Self.relay], storageProfile: .testHost,
                secretStore: store, relayPolicy: .allowLoopback)
            do {
                #expect(try reopened.listAccounts().map(\.accountIdHex) == [account])
                let secret = try await reopened.marmot.revealNsec(accountRef: account)
                #expect(!secret.isEmpty)
                #expect(store.writeCount == 1)
                try await reopened.removeAccount(accountRef: account)
                try await reopened.marmot.shutdownAndClose()
            } catch {
                try await reopened.marmot.shutdownAndClose()
                throw error
            }
        }

        @Test func suppliedStoreRefusalCannotFallBackToProfileKeychain() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeBoundaryRefusal-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = IsolatedBoundaryStore(refusesWrites: true)
            let client = try MarmotClient(
                rootPath: root.path, relayUrls: [Self.relay], storageProfile: .testHost,
                secretStore: store, relayPolicy: .allowLoopback)
            do {
                try await client.start()
                let identity = try await client.marmot.createIdentity(
                    defaultRelays: [Self.relay], bootstrapRelays: [Self.relay], inboxRelays: [Self.relay])
                // Clean up only this SDK-created synthetic identity before reporting a bypass.
                try await client.removeAccount(accountRef: identity.accountIdHex)
                Issue.record("Supplied callback refusal must not fall back to profile credentials")
            } catch { #expect(store.writeCount == 1) }
            try await client.marmot.shutdownAndClose()
        }
        @Test func resetUsesSuppliedStoreAndPreservesUnrelatedProfileCredential() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeBoundaryReset-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let sentinel = "boundary-sentinel-\(UUID())"
            let profileStore = SyncDevelopmentSecretStore(service: MarmotStorageProfile.testHost.keychainService)
            try profileStore.writeSecret(label: sentinel, accountIdHex: sentinel, secretKeyHex: "synthetic-sentinel")
            defer { try? profileStore.removeSecret(label: sentinel, accountIdHex: sentinel) }
            let store = IsolatedBoundaryStore()
            let client = try MarmotClient(
                rootPath: root.path, relayUrls: [Self.relay], storageProfile: .testHost,
                secretStore: store, relayPolicy: .allowLoopback)
            do {
                try await client.start()
                let identity = try await client.marmot.createIdentity(
                    defaultRelays: [Self.relay], bootstrapRelays: [Self.relay], inboxRelays: [Self.relay])
                #expect(try store.hasSecretForAccountId(accountIdHex: identity.accountIdHex))
                try await client.deleteAllLocalData()
                #expect(try profileStore.hasSecretForAccountId(accountIdHex: sentinel))
                #expect(try !store.hasSecretForAccountId(accountIdHex: identity.accountIdHex))
                try await client.marmot.shutdownAndClose()
            } catch {
                try await client.marmot.shutdownAndClose()
                throw error
            }
        }

        @Test func omittedDependenciesRetainDefaultRelayPolicyAcrossReopen() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeBoundaryDefault-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let client = try MarmotClient(rootPath: root.path, relayUrls: [], storageProfile: .testHost)
            let before = client.marmot.classifyRelayEndpoints(endpoints: [Self.relay])
            #expect(before.count == 1)
            #expect(before.first?.policy != .allowed)
            #expect(try client.listAccounts().isEmpty)
            try await client.marmot.shutdownAndClose()
            let reopened = try MarmotClient(rootPath: root.path, relayUrls: [], storageProfile: .testHost)
            let after = reopened.marmot.classifyRelayEndpoints(endpoints: [Self.relay])
            #expect(after == before)
            #expect(try reopened.listAccounts().isEmpty)
            try await reopened.marmot.shutdownAndClose()
        }
        @Test func refusedCredentialRemovalPreservesRootAndRuntime() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "NativeBoundaryResetRefusal-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = IsolatedBoundaryStore(refusesRemoval: true)
            let client = try MarmotClient(
                rootPath: root.path, relayUrls: [Self.relay], storageProfile: .testHost,
                secretStore: store, relayPolicy: .allowLoopback)
            do {
                try await client.start()
                let identity = try await client.marmot.createIdentity(
                    defaultRelays: [Self.relay], bootstrapRelays: [Self.relay], inboxRelays: [Self.relay])
                let marker = root.appendingPathComponent("reset-sentinel")
                try Data("synthetic-root-sentinel".utf8).write(to: marker)
                do {
                    try await client.deleteAllLocalData()
                    Issue.record("A refused credential removal must prevent root deletion")
                } catch {
                    #expect(FileManager.default.fileExists(atPath: marker.path))
                    #expect(try store.hasSecretForAccountId(accountIdHex: identity.accountIdHex))
                    #expect(try client.listAccounts().map(\.accountIdHex) == [identity.accountIdHex])
                    let secret = try await client.marmot.revealNsec(accountRef: identity.accountIdHex)
                    #expect(!secret.isEmpty)
                }
                try await client.marmot.shutdownAndClose()
            } catch {
                try await client.marmot.shutdownAndClose()
                throw error
            }
        }
    }
#endif
