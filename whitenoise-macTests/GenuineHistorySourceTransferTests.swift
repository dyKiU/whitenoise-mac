#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import XCTest

    @testable import whitenoise_mac

    private struct NativeSourceTransferFixture: Decodable {
        let version: Int
        let root: String
        let account: String
        let group: String
        let recipientCount: Int
        let expectedRecipient: String
        enum CodingKeys: String, CodingKey {
            case version, root, account, group
            case recipientCount = "recipient_count"
            case expectedRecipient = "expected_recipient"
        }

        static func read(_ path: String) throws -> Self {
            guard
                try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber == 0o600
            else { throw CocoaError(.fileReadNoPermission) }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            guard bytes.count <= 32768 else { throw CocoaError(.fileReadCorruptFile) }
            let value = try JSONDecoder().decode(Self.self, from: bytes)
            let root = URL(fileURLWithPath: value.root, isDirectory: true).resolvingSymlinksInPath()
            guard value.version == 2, value.recipientCount == 2,
                value.expectedRecipient.count == 64,
                value.expectedRecipient.allSatisfy({ "0123456789abcdef".contains($0) }),
                root.path.hasPrefix("/Users/pj/project/build/native-"),
                try Data(contentsOf: root.appendingPathComponent(".native-acceptance"))
                    == Data("native-sdk83-test-only-v1\n".utf8)
            else { throw CocoaError(.fileReadCorruptFile) }
            return value
        }
    }

    @MainActor final class GenuineHistorySourceTransferTests: XCTestCase {
        func testCompleteFreshSourceOriginalThroughAccountModelAndNativeRecipient() async throws {
            guard let path = ProcessInfo.processInfo.environment["WN_SOURCE_TRANSFER_BRIDGE"] else {
                throw XCTSkip("Requires a live native-recipient controller and positively closed source handoff")
            }
            let bridge = URL(fileURLWithPath: path, isDirectory: true)
            let descriptor = bridge.appendingPathComponent("fixture.json")
            let handoffDeadline = ContinuousClock.now.advanced(by: .seconds(120))
            while !FileManager.default.fileExists(atPath: descriptor.path), ContinuousClock.now < handoffDeadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            let fixture = try NativeSourceTransferFixture.read(descriptor.path)
            XCTAssertEqual(
                try FileManager.default.attributesOfItem(atPath: bridge.path)[.posixPermissions] as? NSNumber,
                NSNumber(value: 0o700))
            let root = URL(fileURLWithPath: fixture.root, isDirectory: true)
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
                let scope = try XCTUnwrap(session.accountScope)
                let model = scope.historySourceModel(groupIdHex: fixture.group)
                try await model.loadRecipients()
                XCTAssertEqual(model.recipients.count, fixture.recipientCount)
                XCTAssertNil(model.transfer)
                XCTAssertNil(model.selectedDevice)
                try write(["ready": true], name: "ready.json", bridge: bridge)
                let chosen = try XCTUnwrap(
                    model.recipients.first { Self.hex($0.device) == fixture.expectedRecipient })
                // Explicit app-model actions; observations cannot create native authority.
                try model.select(device: chosen.device)
                try await model.requestTransfer()
                let original = try XCTUnwrap(model.transfer)
                let displayed = try XCTUnwrap(model.review)
                XCTAssertTrue(displayed.groupIdHex == fixture.group)
                XCTAssertTrue(displayed.recipientDevice == chosen.device)
                XCTAssertGreaterThan(displayed.recordCount, 0)
                try write(
                    [
                        "group": displayed.groupIdHex, "source": Self.hex(displayed.sourceDevice),
                        "recipient": Self.hex(displayed.recipientDevice), "records": displayed.recordCount,
                        "encoded_bytes": displayed.encodedBytes, "fragments": displayed.fragmentCount,
                        "ceiling": displayed.snapshotTimestampCeiling, "revision": displayed.revision,
                        "complete": displayed.complete, "explicit_action": true,
                    ], name: "requested.json", bridge: bridge)
                let approvedFile = bridge.appendingPathComponent("recipient-approved.json")
                let approvalDeadline = ContinuousClock.now.advanced(by: .seconds(30))
                while !FileManager.default.fileExists(atPath: approvedFile.path), ContinuousClock.now < approvalDeadline
                {
                    try await Task.sleep(for: .milliseconds(20))
                }
                let approved = try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: approvedFile))
                XCTAssertEqual(approved, ["approved": true])
                try await model.refreshTransfer()
                XCTAssertTrue(model.transfer === original)
                let currentDisplayed = try XCTUnwrap(model.review)
                XCTAssertTrue(currentDisplayed.groupIdHex == displayed.groupIdHex)
                XCTAssertTrue(currentDisplayed.recipientDevice == displayed.recipientDevice)
                XCTAssertEqual(currentDisplayed.recordCount, displayed.recordCount)
                try await model.continueTransfer(displayedRevision: currentDisplayed.revision)
                let completeDeadline = ContinuousClock.now.advanced(by: .seconds(30))
                while model.review?.complete != true, ContinuousClock.now < completeDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                    try await model.refreshTransfer()
                }
                let completed = try XCTUnwrap(model.review)
                XCTAssertTrue(completed.complete)
                XCTAssertTrue(model.transfer === original)
                await session.deactivate()
                XCTAssertFalse(model.isActive)
                XCTAssertFalse(original.isActive)
                try await client.marmot.shutdownAndClose()
                try write(
                    [
                        "source_complete": completed.complete, "original_retired": !original.isActive,
                        "runtime_closed": true,
                    ],
                    name: "completed.json", bridge: bridge)
            } catch {
                try? write(["failed": true], name: "failed.json", bridge: bridge)
                await session.deactivate()
                try await client.marmot.shutdownAndClose()
                throw error
            }
        }

        private static func hex(_ bytes: Data) -> String {
            bytes.map { String(format: "%02x", $0) }.joined()
        }

        private func write(_ value: [String: Any], name: String, bridge: URL) throws {
            let path = bridge.appendingPathComponent(name)
            let pending = bridge.appendingPathComponent(name + ".pending")
            try JSONSerialization.data(withJSONObject: value).write(to: pending, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
            try FileManager.default.linkItem(at: pending, to: path)
            try FileManager.default.removeItem(at: pending)
        }
    }
#endif
