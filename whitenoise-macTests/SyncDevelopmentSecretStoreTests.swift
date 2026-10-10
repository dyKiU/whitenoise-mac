import Foundation
import Testing

@testable import whitenoise_mac

@Suite struct SyncDevelopmentSecretStoreTests {
    private func isolatedStore() -> SyncDevelopmentSecretStore {
        SyncDevelopmentSecretStore(service: "dev.ipf.whitenoise.tests.\(UUID().uuidString)")
    }

    @Test func credentialReopensByAccountIdentityAfterLabelChange() throws {
        let store = isolatedStore()
        defer { try? store.purgeAllAccountKeys() }
        try store.writeSecret(label: "old label", accountIdHex: "synthetic-account", secretKeyHex: "synthetic-secret")
        let reopened = SyncDevelopmentSecretStore(service: store.service)
        #expect(try reopened.hasSecretForAccountId(accountIdHex: "synthetic-account"))
        #expect(try !reopened.hasSecretForLabel(label: "old label"))
        #expect(try reopened.loadSecret(label: "new label", accountIdHex: "synthetic-account") == "synthetic-secret")
        try reopened.writeSecret(label: "new label", accountIdHex: "synthetic-account", secretKeyHex: "replacement")
        #expect(try store.loadSecret(label: "old label", accountIdHex: "synthetic-account") == "replacement")
        try reopened.removeSecret(label: "different label", accountIdHex: "synthetic-account")
        #expect(try !store.hasSecretForAccountId(accountIdHex: "synthetic-account"))
        try reopened.removeSecret(label: "different label", accountIdHex: "synthetic-account")
    }

    @Test func purgePreservesAnotherApplicationsCredentials() throws {
        let development = isolatedStore()
        let otherApplication = isolatedStore()
        defer {
            try? development.purgeAllAccountKeys()
            try? otherApplication.purgeAllAccountKeys()
        }
        try development.writeSecret(label: "same", accountIdHex: "same-account", secretKeyHex: "development")
        try otherApplication.writeSecret(label: "same", accountIdHex: "same-account", secretKeyHex: "other")
        try development.purgeAllAccountKeys()
        #expect(try !development.hasSecretForAccountId(accountIdHex: "same-account"))
        #expect(try otherApplication.loadSecret(label: "same", accountIdHex: "same-account") == "other")
    }

    @Test func developmentResetClearsItsStorageAndCredentialsOnly() async throws {
        let development = isolatedStore()
        let otherApplication = isolatedStore()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? development.purgeAllAccountKeys()
            try? otherApplication.purgeAllAccountKeys()
            try? FileManager.default.removeItem(at: root)
        }
        let developmentPath = try MarmotStorageRoot.resolve(baseURL: root, profile: .syncDevelopment)
        let otherPath = try MarmotStorageRoot.resolve(baseURL: root, profile: .production)
        let marker = "synthetic-marker"
        try Data([1]).write(to: URL(fileURLWithPath: developmentPath).appendingPathComponent(marker))
        try Data([2]).write(to: URL(fileURLWithPath: otherPath).appendingPathComponent(marker))
        try development.writeSecret(label: "same", accountIdHex: "same-account", secretKeyHex: "development")
        try otherApplication.writeSecret(label: "same", accountIdHex: "same-account", secretKeyHex: "other")
        try await MarmotClient.deleteAllLocalData(
            purgeAccountKeychain: development.purgeAllAccountKeys,
            shutdown: {},
            rootPath: developmentPath
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: developmentPath).isEmpty)
        #expect(try Data(contentsOf: URL(fileURLWithPath: otherPath).appendingPathComponent(marker)) == Data([2]))
        #expect(try !development.hasSecretForAccountId(accountIdHex: "same-account"))
        #expect(try otherApplication.loadSecret(label: "same", accountIdHex: "same-account") == "other")
    }
}
