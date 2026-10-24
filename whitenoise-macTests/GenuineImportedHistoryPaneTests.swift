import AppKit
import CryptoKit
import Foundation
import MarmotKit
import SwiftUI
import XCTest

@testable import whitenoise_mac

#if WN_EXPERIMENTAL_DEVICE_SYNC
    private enum MacImportedHistoryFixtureError: Error { case invalidFixture, credentialMutationRefused }

    private struct MacImportedHistoryFixture: Decodable {
        let version: Int
        let root: String
        let account: String
        let group: String
        let liveMessage: String
        let record: Record
        enum CodingKeys: String, CodingKey {
            case version, root, account, group, record
            case liveMessage = "live_message"
        }
        struct Record: Decodable {
            let message: String
            let author: String
            let content: String
            let tags: [[String]]
            let createdAt: UInt64
            let expiresAt: UInt64?
            let deleted: Bool
            let mediaCount: Int
            let source: String
            let transfer: String
            let manifest: String
            enum CodingKeys: String, CodingKey {
                case message, author, content, tags, deleted, source, transfer, manifest
                case createdAt = "created_at"
                case expiresAt = "expires_at"
                case mediaCount = "media_count"
            }
        }
        static func read(_ path: String) throws -> Self {
            let url = URL(fileURLWithPath: path)
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= 32768,
                try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber == 0o600
            else { throw MacImportedHistoryFixtureError.invalidFixture }
            let value = try JSONDecoder().decode(Self.self, from: bytes)
            let root = URL(fileURLWithPath: value.root, isDirectory: true).resolvingSymlinksInPath()
            guard value.version == 1, try HostedNativeFixtureRoot.accepts(root, prefix: "native-"),
                try Data(contentsOf: root.appendingPathComponent(".native-acceptance"))
                    == Data("native-sdk83-test-only-v1\n".utf8),
                value.record.content.utf8.count == 8192, value.record.mediaCount == 0,
                !value.record.deleted, value.record.expiresAt == nil
            else { throw MacImportedHistoryFixtureError.invalidFixture }
            return value
        }
    }

    /// Read the original task callback's authenticated envelope; no Keychain or credential copy.
    nonisolated final class MacImportedHistoryReadOnlyStore: SecretStore {
        private let values: [String: String]
        init(root: URL) throws {
            let directory = root.appendingPathComponent("credentials", isDirectory: true)
            let keyFile = directory.appendingPathComponent("credentials.key")
            let sealedFile = directory.appendingPathComponent("signing-credentials.sealed")
            for (url, permissions) in [(root, 0o700), (directory, 0o700), (keyFile, 0o600), (sealedFile, 0o600)] {
                guard
                    try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
                        == NSNumber(value: permissions)
                else { throw MacImportedHistoryFixtureError.invalidFixture }
            }
            let key = try Data(contentsOf: keyFile)
            let sealed = try Data(contentsOf: sealedFile)
            guard key.count == 32, sealed.count <= 65536 else { throw MacImportedHistoryFixtureError.invalidFixture }
            let box = try AES.GCM.SealedBox(combined: sealed)
            values = try JSONDecoder().decode(
                [String: String].self, from: AES.GCM.open(box, using: SymmetricKey(data: key)))
        }
        func hasSecretForLabel(label: String) throws -> Bool { values[label] != nil }
        func hasSecretForAccountId(accountIdHex: String) throws -> Bool { values[accountIdHex] != nil }
        func loadSecret(label: String, accountIdHex: String) throws -> String {
            guard let secret = values[accountIdHex], secret.utf8.count == 64 else {
                throw MacImportedHistoryFixtureError.invalidFixture
            }
            return secret
        }
        func writeSecret(label: String, accountIdHex: String, secretKeyHex: String) throws {
            throw MacImportedHistoryFixtureError.credentialMutationRefused
        }
        func removeSecret(label: String, accountIdHex: String) throws {
            throw MacImportedHistoryFixtureError.credentialMutationRefused
        }
    }

    @MainActor private final class MacHistoryGraphLifetime {}
    private struct MacHistoryHostedRoot: View {
        let model: SynchronizedHistoryViewModel
        let lifetime: MacHistoryGraphLifetime
        var body: some View {
            SynchronizedHistoryView(model: model)
                .background(Color(nsColor: .windowBackgroundColor))
                .id(ObjectIdentifier(lifetime))
        }
    }

    @MainActor final class GenuineImportedHistoryPaneTests: XCTestCase {
        func testRealCommittedImportThroughSessionOwnedReaderAndHostedPane() async throws {
            guard let path = ProcessInfo.processInfo.environment["WN_IMPORTED_HISTORY_FIXTURE"] else {
                throw XCTSkip("Requires a freshly committed and positively closed native Mac recipient fixture")
            }
            let fixture = try MacImportedHistoryFixture.read(path)
            let root = URL(fileURLWithPath: fixture.root, isDirectory: true)
            let callback = try MacImportedHistoryReadOnlyStore(root: root)
            let client = try MarmotClient(
                rootPath: root.appendingPathComponent("runtime", isDirectory: true).path,
                relayUrls: ["ws://127.0.0.1:18181"], storageProfile: .testHost,
                secretStore: callback, relayPolicy: .allowLoopback)
            let session = SessionState()
            do {
                let accounts = try client.listAccounts()
                XCTAssertEqual(accounts.count, 1)
                let account = try XCTUnwrap(accounts.first)
                XCTAssertTrue(account.accountIdHex == fixture.account)
                try await client.start()
                await session.activate(
                    account: AccountItem(summary: account), runtime: client, connectivityAvailable: true)
                let scope = try XCTUnwrap(session.accountScope)
                let model = scope.synchronizedHistoryModel(groupIdHex: fixture.group)
                await model.loadNextPage()
                try checkImported(model: model, fixture: fixture, client: client)
                try await render(model: model, fixture: fixture)
                await session.deactivate()
                XCTAssertFalse(model.isActive)
                XCTAssertTrue(model.records.isEmpty)
                try await client.marmot.shutdownAndClose()
            } catch {
                await session.deactivate()
                try await client.marmot.shutdownAndClose()
                throw error
            }
        }
        private func checkImported(
            model: SynchronizedHistoryViewModel, fixture: MacImportedHistoryFixture, client: MarmotClient
        ) throws {
            XCTAssertTrue(model.isActive)
            XCTAssertFalse(model.readFailed)
            XCTAssertEqual(model.records.count, 1)
            let actual = try XCTUnwrap(model.records.first)
            XCTAssertTrue(actual.id == fixture.record.message && actual.authorPubkey == fixture.record.author)
            XCTAssertEqual(
                SHA256.hash(data: Data(actual.content.utf8)), SHA256.hash(data: Data(fixture.record.content.utf8)))
            XCTAssertTrue(actual.tags.map(\.values) == fixture.record.tags)
            XCTAssertEqual(actual.createdAt, fixture.record.createdAt)
            XCTAssertEqual(actual.expiresAt, fixture.record.expiresAt)
            XCTAssertEqual(actual.deleted, fixture.record.deleted)
            XCTAssertEqual(actual.mediaAttachments.count, 0)
            for (bytes, expected) in [
                (actual.sourceDevice, fixture.record.source), (actual.transferId, fixture.record.transfer),
                (actual.manifestDigest, fixture.record.manifest),
            ] {
                XCTAssertEqual(bytes.count, 32)
                XCTAssertTrue(bytes.map { String(format: "%02x", $0) }.joined() == expected)
            }
            XCTAssertFalse(actual.deleted)
            let live = try client.marmot.messages(
                accountRef: fixture.account, groupIdHex: fixture.group, limit: 128, kinds: nil)
            XCTAssertTrue(live.contains { $0.messageIdHex == fixture.liveMessage })
            XCTAssertFalse(live.contains { $0.messageIdHex == fixture.record.message })
        }
        private func render(model: SynchronizedHistoryViewModel, fixture: MacImportedHistoryFixture) async throws {
            var lifetime: MacHistoryGraphLifetime? = .init()
            weak var retiredGraph = lifetime
            var host: NSHostingView<AnyView>? = NSHostingView(
                rootView: AnyView(MacHistoryHostedRoot(model: model, lifetime: try XCTUnwrap(lifetime))))
            lifetime = nil
            weak var retiredHost = host
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 660),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host?.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            window.orderFront(nil)
            defer {
                host?.rootView = AnyView(EmptyView())
                window.contentView = nil
                window.orderOut(nil)
                window.close()
            }
            func retireGraph() async {
                host?.rootView = AnyView(EmptyView())
                window.contentView = nil
                window.orderOut(nil)
                window.close()
                host = nil
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while retiredHost != nil || retiredGraph != nil, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertNil(retiredHost)
                XCTAssertNil(retiredGraph)
            }
            do {
                // Hosting starts the pane's real reload task; retire the pre-host page before capturing.
                host?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                await Task.yield()
                for _ in 0..<2 {
                    try await Task.sleep(for: .milliseconds(20))
                    host?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while model.isLoading || model.records.count != 1, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertEqual(model.records.count, 1)
                XCTAssertTrue(model.records.first?.id == fixture.record.message)
                XCTAssertFalse(model.readFailed)
                do {
                    let view = try XCTUnwrap(host)
                    view.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                    attachment.name = "genuine-mac-source-attested-imported-history-pane"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                XCTAssertFalse(model.isLoading)
                XCTAssertEqual(model.records.count, 1)
                XCTAssertTrue(model.records.first?.id == fixture.record.message)
                await retireGraph()
            } catch {
                await retireGraph()
                throw error
            }
        }
    }
#endif
