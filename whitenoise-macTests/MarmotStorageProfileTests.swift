import Foundation
import Testing

@testable import whitenoise_mac

@Suite struct MarmotStorageProfileTests {
    private func withSupportRoot(_ test: (URL) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("white-noise-storage-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try test(base)
    }

    @Test func developmentRootCannotReadProductionAccountFiles() throws {
        try withSupportRoot { base in
            let production = try MarmotStorageRoot.resolve(baseURL: base, profile: .production)
            let marker = URL(fileURLWithPath: production).appendingPathComponent("synthetic-account-marker")
            try Data([1, 2, 3]).write(to: marker)
            let development = try MarmotStorageRoot.resolve(baseURL: base, profile: .syncDevelopment)
            #expect(development != production)
            #expect(try FileManager.default.contentsOfDirectory(atPath: development).isEmpty)
            #expect(try Data(contentsOf: marker) == Data([1, 2, 3]))
        }
    }

    @Test func explicitTestHostCannotReadProductionOrDevelopmentAccountFiles() throws {
        try withSupportRoot { base in
            let production = try MarmotStorageRoot.resolve(baseURL: base, profile: .production)
            let development = try MarmotStorageRoot.resolve(baseURL: base, profile: .syncDevelopment)
            let name = "synthetic-account-marker"
            let productionMarker = URL(fileURLWithPath: production).appendingPathComponent(name)
            let developmentMarker = URL(fileURLWithPath: development).appendingPathComponent(name)
            try Data([11]).write(to: productionMarker)
            try Data([12]).write(to: developmentMarker)
            let profile = MarmotStorageProfile.forBundleIdentifier("dev.ipf.whitenoise.mac.tests")
            let testRoot = try MarmotStorageRoot.resolve(baseURL: base, profile: profile)
            #expect(testRoot != production)
            #expect(testRoot != development)
            #expect(try FileManager.default.contentsOfDirectory(atPath: testRoot).isEmpty)
            #expect(try Data(contentsOf: productionMarker) == Data([11]))
            #expect(try Data(contentsOf: developmentMarker) == Data([12]))
            let reopened = try MarmotStorageRoot.resolve(baseURL: base, profile: profile)
            #expect(reopened == testRoot)
        }
    }

    @Test func developmentReopenRetainsItsOwnAccountFiles() throws {
        try withSupportRoot { base in
            let development = try MarmotStorageRoot.resolve(baseURL: base, profile: .syncDevelopment)
            let marker = URL(fileURLWithPath: development).appendingPathComponent("synthetic-account-marker")
            try Data([4, 5, 6]).write(to: marker)
            let reopened = try MarmotStorageRoot.resolve(baseURL: base, profile: .syncDevelopment)
            #expect(reopened == development)
            #expect(
                try Data(contentsOf: URL(fileURLWithPath: reopened).appendingPathComponent("synthetic-account-marker"))
                    == Data([4, 5, 6]))
        }
    }

    @Test func productionRootKeepsItsExistingLocation() throws {
        try withSupportRoot { base in
            let existing = base.appendingPathComponent("White Noise/Marmot", isDirectory: true)
            try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
            let marker = existing.appendingPathComponent("synthetic-account-marker")
            try Data([7, 8, 9]).write(to: marker)
            let resolved = try MarmotStorageRoot.resolve(baseURL: base, profile: .production)
            #expect(resolved == existing.path)
            #expect(try Data(contentsOf: marker) == Data([7, 8, 9]))
        }
    }

    @Test func onlyTheExplicitDevelopmentBundleSelectsDevelopmentStorage() {
        #expect(MarmotStorageProfile.forBundleIdentifier("dev.ipf.whitenoise.mac.syncdev") == .syncDevelopment)
        #expect(MarmotStorageProfile.forBundleIdentifier("dev.ipf.whitenoise.mac.tests") == .testHost)
        #expect(MarmotStorageProfile.forBundleIdentifier("dev.ipf.whitenoise.mac.tests.extra") == .production)
        #expect(MarmotStorageProfile.forBundleIdentifier("dev.ipf.whitenoise.mac") == .production)
        #expect(MarmotStorageProfile.forBundleIdentifier(nil) == .production)
        #expect(MarmotStorageProfile.forBundleIdentifier("dev.ipf.whitenoise.mac.syncdev.extra") == .production)
    }

    @Test func developmentUsesItsOwnSecretStoreAndProductionKeepsPlatformDefault() throws {
        #expect(MarmotStorageProfile.production.makeSecretStore() == nil)
        let store = try #require(
            MarmotStorageProfile.syncDevelopment.makeSecretStore() as? SyncDevelopmentSecretStore)
        #expect(store.service == MarmotStorageProfile.syncDevelopment.keychainService)
        #expect(store.service != MarmotStorageProfile.production.keychainService)
        let testStore = try #require(MarmotStorageProfile.testHost.makeSecretStore() as? SyncDevelopmentSecretStore)
        #expect(testStore.service == MarmotStorageProfile.testHost.keychainService)
        #expect(testStore.service != store.service)
        #expect(testStore.service != MarmotStorageProfile.production.keychainService)
    }
}
