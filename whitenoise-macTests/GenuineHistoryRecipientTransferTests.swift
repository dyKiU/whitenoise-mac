#if WN_EXPERIMENTAL_DEVICE_SYNC
    import CryptoKit
    import Foundation
    import MarmotKit
    import XCTest

    @testable import whitenoise_mac

    private enum GenuineRecipientTransferError: Error { case invalidFixture, deadline }
    private struct GenuineRecipientTransferFixture: Decodable {
        let version: Int
        let root: String
        let account: String
        let group: String
        let liveMessage: String
        let oldMessage: String
        let oldContent: String
        let oldTags: [[String]]
        let author: String
        enum CodingKeys: String, CodingKey {
            case version, root, account, group, author
            case liveMessage = "live_message"
            case oldMessage = "old_message"
            case oldContent = "old_content"
            case oldTags = "old_tags"
        }
    }
    private struct GenuineSourceRequestObservation: Decodable {
        let group: String
        let source: String
        let recipient: String
        let records: UInt32
        let encodedBytes: UInt32
        let fragments: UInt32
        let ceiling: UInt64
        let complete: Bool
        let explicitAction: Bool
        enum CodingKeys: String, CodingKey {
            case group, source, recipient, records, fragments, ceiling, complete
            case encodedBytes = "encoded_bytes"
            case explicitAction = "explicit_action"
        }
    }

    /// The controller closes B before A's fresh request. Only a newly received SDK original can approve.
    @MainActor final class GenuineHistoryRecipientTransferTests: XCTestCase {
        func testFreshRecipientOriginalThroughSessionModelAndIOSSource() async throws {
            continueAfterFailure = false
            guard let path = ProcessInfo.processInfo.environment["WN_MAC_HISTORY_APPROVAL_BRIDGE"] else {
                throw XCTSkip("Requires a positively closed native recipient and live iOS source bridge")
            }
            let bridge = URL(fileURLWithPath: path, isDirectory: true)
            let fixture: GenuineRecipientTransferFixture = try await read("fixture.json", bridge: bridge)
            let root = URL(fileURLWithPath: fixture.root, isDirectory: true).resolvingSymlinksInPath()
            guard fixture.version == 2, root.path.hasPrefix("/Users/pj/project/build/native-"),
                fixture.account.count == 64, fixture.author.count == 64,
                !fixture.group.isEmpty, fixture.group.utf8.count <= 512,
                fixture.oldContent.utf8.count == 8192,
                try Data(contentsOf: root.appendingPathComponent(".native-acceptance"))
                    == Data("native-sdk83-test-only-v1\n".utf8),
                try FileManager.default.attributesOfItem(atPath: bridge.path)[.posixPermissions] as? NSNumber == 0o700
            else { throw GenuineRecipientTransferError.invalidFixture }
            let client = try MarmotClient(
                rootPath: root.appendingPathComponent("runtime", isDirectory: true).path,
                relayUrls: ["ws://127.0.0.1:18181"], storageProfile: .testHost,
                secretStore: try MacImportedHistoryReadOnlyStore(root: root), relayPolicy: .allowLoopback)
            let session = SessionState()
            do {
                let accounts = try client.listAccounts()
                XCTAssertEqual(accounts.count, 1)
                let account = try XCTUnwrap(accounts.first)
                XCTAssertTrue(account.accountIdHex == fixture.account)
                try await client.start()
                await session.activate(
                    account: AccountItem(summary: account), runtime: client, connectivityAvailable: true)
                let accountScope = try XCTUnwrap(session.accountScope)
                let reader = accountScope.synchronizedHistoryModel(groupIdHex: fixture.group)
                await reader.reload()
                XCTAssertFalse(reader.readFailed)
                XCTAssertTrue(reader.records.isEmpty)
                let model = try session.historyConsentReviewModel()
                try await model.loadPending()
                XCTAssertTrue(model.requests.isEmpty)
                try write(["ready": true], name: "ready.json", bridge: bridge)
                let source: GenuineSourceRequestObservation = try await read("source-requested.json", bridge: bridge)
                let arrival = ContinuousClock.now.advanced(by: .seconds(40))
                while model.requests.isEmpty {
                    guard ContinuousClock.now < arrival else { throw GenuineRecipientTransferError.deadline }
                    try await model.loadPending()
                    if model.requests.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
                }
                XCTAssertEqual(model.requests.count, 1)
                let original = try XCTUnwrap(model.requests.first)
                try await model.select(id: original.id)
                XCTAssertTrue(model.selected === original)
                let displayed = try XCTUnwrap(model.review)
                try checkSelection(displayed, source: source, fixture: fixture)
                XCTAssertEqual(displayed.importedRecords, 0)
                XCTAssertFalse(displayed.complete)
                await reader.reload()
                XCTAssertTrue(reader.records.isEmpty)
                try write(observation(displayed, explicit: false), name: "reviewed.json", bridge: bridge)
                try await model.approve(displayedRevision: displayed.revision)
                XCTAssertTrue(model.selected === original)
                var approved = observation(displayed, explicit: true)
                approved["archive_before"] = 0
                try write(approved, name: "approved.json", bridge: bridge)
                let imported = ContinuousClock.now.advanced(by: .seconds(60))
                while original.snapshot?.complete != true {
                    guard ContinuousClock.now < imported else { throw GenuineRecipientTransferError.deadline }
                    try await original.refresh()
                    if original.snapshot?.complete != true { try await Task.sleep(for: .milliseconds(50)) }
                }
                let completed = try XCTUnwrap(original.snapshot)
                try checkSelection(completed, source: source, fixture: fixture)
                XCTAssertEqual(completed.importedRecords, 1)
                await reader.reload()
                try checkImported(reader, fixture: fixture, source: completed, client: client)
                // Keep the same receiver alive until A has authenticated the final receipt.
                let sourceComplete: [String: Bool] = try await read("source-complete.json", bridge: bridge)
                XCTAssertEqual(sourceComplete, ["source_complete": true])
                XCTAssertTrue(model.selected === original)
                await session.deactivate()
                XCTAssertFalse(model.isActive)
                XCTAssertFalse(original.isActive)
                XCTAssertFalse(reader.isActive)
                XCTAssertTrue(reader.records.isEmpty)
                try await client.marmot.shutdownAndClose()
                XCTAssertTrue(client.marmot.storageIsClosed())
                try write(
                    [
                        "consent_complete": completed.complete, "imported_records": completed.importedRecords,
                        "reader_verified": true, "owner_retired": !original.isActive,
                        "runtime_closed": client.marmot.storageIsClosed(),
                    ],
                    name: "completed.json", bridge: bridge)
            } catch {
                await session.deactivate()
                try await client.marmot.shutdownAndClose()
                try write(["failed": true], name: "failed.json", bridge: bridge)
                throw error
            }
        }

        private func checkSelection(
            _ value: HistoryTransferSnapshotFfi, source: GenuineSourceRequestObservation,
            fixture: GenuineRecipientTransferFixture
        ) throws {
            XCTAssertTrue(source.explicitAction)
            XCTAssertFalse(source.complete)
            XCTAssertTrue(value.groupIdHex == fixture.group && value.groupIdHex == source.group)
            XCTAssertTrue(hex(value.sourceDevice) == source.source && hex(value.recipientDevice) == source.recipient)
            XCTAssertEqual(value.recordCount, source.records)
            XCTAssertEqual(value.encodedBytes, source.encodedBytes)
            XCTAssertEqual(value.fragmentCount, source.fragments)
            XCTAssertEqual(value.snapshotTimestampCeiling, source.ceiling)
        }
        private func observation(_ value: HistoryTransferSnapshotFfi, explicit: Bool) -> [String: Any] {
            [
                "group": value.groupIdHex, "source": hex(value.sourceDevice), "recipient": hex(value.recipientDevice),
                "records": value.recordCount, "encoded_bytes": value.encodedBytes, "fragments": value.fragmentCount,
                "ceiling": value.snapshotTimestampCeiling, "revision": value.revision,
                "imported": value.importedRecords, "complete": value.complete, "explicit_action": explicit,
            ]
        }
        private func checkImported(
            _ reader: SynchronizedHistoryViewModel, fixture: GenuineRecipientTransferFixture,
            source: HistoryTransferSnapshotFfi, client: MarmotClient
        ) throws {
            XCTAssertFalse(reader.readFailed)
            XCTAssertEqual(reader.records.count, 1)
            let row = try XCTUnwrap(reader.records.first)
            XCTAssertTrue(row.id == fixture.oldMessage && row.authorPubkey == fixture.author)
            XCTAssertEqual(SHA256.hash(data: Data(row.content.utf8)), SHA256.hash(data: Data(fixture.oldContent.utf8)))
            XCTAssertTrue(row.tags.map(\.values) == fixture.oldTags)
            XCTAssertEqual(row.sourceDevice, source.sourceDevice)
            XCTAssertEqual(row.transferId.count, 32)
            XCTAssertEqual(row.manifestDigest.count, 32)
            XCTAssertGreaterThan(row.createdAt, 0)
            XCTAssertNil(row.expiresAt)
            XCTAssertFalse(row.deleted)
            XCTAssertTrue(row.mediaAttachments.isEmpty)
            let live = try client.marmot.messages(
                accountRef: fixture.account, groupIdHex: fixture.group, limit: 128, kinds: nil)
            XCTAssertTrue(live.contains { $0.messageIdHex == fixture.liveMessage })
            XCTAssertFalse(live.contains { $0.messageIdHex == fixture.oldMessage })
        }
        private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        private func read<T: Decodable>(_ name: String, bridge: URL) async throws -> T {
            let path = bridge.appendingPathComponent(name)
            let deadline = ContinuousClock.now.advanced(by: .seconds(120))
            while !FileManager.default.fileExists(atPath: path.path) {
                guard ContinuousClock.now < deadline else { throw GenuineRecipientTransferError.deadline }
                try await Task.sleep(for: .milliseconds(50))
            }
            let bytes = try Data(contentsOf: path)
            guard bytes.count <= 32768,
                try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber == 0o600
            else { throw GenuineRecipientTransferError.invalidFixture }
            return try JSONDecoder().decode(T.self, from: bytes)
        }
        private func write(_ value: [String: Any], name: String, bridge: URL) throws {
            let temporary = bridge.appendingPathComponent(".observation-\(UUID())")
            try JSONSerialization.data(withJSONObject: value).write(to: temporary, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try FileManager.default.moveItem(at: temporary, to: bridge.appendingPathComponent(name))
        }
    }
#endif
