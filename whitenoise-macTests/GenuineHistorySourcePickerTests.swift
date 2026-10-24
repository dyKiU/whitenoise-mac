#if WN_EXPERIMENTAL_DEVICE_SYNC
    import AppKit
    import Foundation
    import SwiftUI
    import MarmotKit
    import XCTest

    @testable import whitenoise_mac

    private struct NativeSourcePickerFixture: Decodable {
        let version: Int
        let root: String
        let account: String
        let group: String
        let recipientCount: Int
        enum CodingKeys: String, CodingKey {
            case version, root, account, group
            case recipientCount = "recipient_count"
        }

        static func read(_ path: String) throws -> Self {
            guard
                try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber == 0o600
            else { throw CocoaError(.fileReadNoPermission) }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            guard bytes.count <= 32768 else { throw CocoaError(.fileReadCorruptFile) }
            let value = try JSONDecoder().decode(Self.self, from: bytes)
            let root = URL(fileURLWithPath: value.root, isDirectory: true).resolvingSymlinksInPath()
            guard value.version == 1, value.recipientCount == 2,
                try HostedNativeFixtureRoot.accepts(root, prefix: "native-"),
                try Data(contentsOf: root.appendingPathComponent(".native-acceptance"))
                    == Data("native-sdk83-test-only-v1\n".utf8)
            else { throw CocoaError(.fileReadCorruptFile) }
            return value
        }
    }

    @MainActor final class GenuineHistorySourcePickerTests: XCTestCase {
        func testHostedNativePickerButtonsWithExternalDriver() async throws {
            let environment = ProcessInfo.processInfo.environment
            guard let path = environment["WN_SOURCE_PICKER_FIXTURE"],
                let bridgePath = environment["WN_SOURCE_PICKER_BUTTON_BRIDGE"]
            else { throw XCTSkip("Requires an explicit external UI driver and closed native fixture") }
            let fixture = try NativeSourcePickerFixture.read(path)
            let bridge = URL(fileURLWithPath: bridgePath, isDirectory: true)
            guard try FileManager.default.attributesOfItem(atPath: bridge.path)[.posixPermissions] as? NSNumber == 0o700
            else { throw CocoaError(.fileReadNoPermission) }
            let root = URL(fileURLWithPath: fixture.root, isDirectory: true)
            let client = try MarmotClient(
                rootPath: root.appendingPathComponent("runtime", isDirectory: true).path,
                relayUrls: ["ws://127.0.0.1:18181"], storageProfile: .testHost,
                secretStore: try MacImportedHistoryReadOnlyStore(root: root), relayPolicy: .allowLoopback)
            let session = SessionState()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 660),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: AnyView(EmptyView()))
            defer {
                host.rootView = AnyView(EmptyView())
                window.contentView = nil
                window.orderOut(nil)
                window.close()
            }
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
                host.rootView = AnyView(
                    HistorySourceView(model: model).background(Color(nsColor: .windowBackgroundColor)))
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                let readyDeadline = ContinuousClock.now.advanced(by: .seconds(10))
                while model.recipients.count != 2 || model.isWorking, ContinuousClock.now < readyDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertEqual(model.recipients.count, fixture.recipientCount)
                XCTAssertNil(model.selectedDevice)
                XCTAssertNil(model.transfer)
                try Data("ready\n".utf8).write(to: bridge.appendingPathComponent("ready"), options: .withoutOverwriting)
                let requestDeadline = ContinuousClock.now.advanced(by: .seconds(90))
                while model.review == nil, ContinuousClock.now < requestDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                let original = try XCTUnwrap(model.transfer)
                let review = try XCTUnwrap(model.review)
                XCTAssertTrue(review.groupIdHex == fixture.group)
                XCTAssertTrue(review.recipientDevice == model.selectedDevice)
                XCTAssertFalse(review.complete)
                try Data("reviewed\n".utf8).write(
                    to: bridge.appendingPathComponent("reviewed"), options: .withoutOverwriting)
                let cancelDeadline = ContinuousClock.now.advanced(by: .seconds(30))
                while model.transfer != nil, ContinuousClock.now < cancelDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertNil(model.transfer)
                XCTAssertFalse(original.isActive)
                await session.deactivate()
                XCTAssertFalse(model.isActive)
                try await client.marmot.shutdownAndClose()
            } catch {
                await session.deactivate()
                try await client.marmot.shutdownAndClose()
                throw error
            }
        }

        func testRealRecipientsAndFreshOriginalThroughSessionOwnedModel() async throws {
            guard let path = ProcessInfo.processInfo.environment["WN_SOURCE_PICKER_FIXTURE"] else {
                throw XCTSkip("Requires a freshly qualified and positively closed native source fixture")
            }
            let fixture = try NativeSourcePickerFixture.read(path)
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
                XCTAssertNil(model.selectedDevice)
                XCTAssertNil(model.transfer)
                XCTAssertNil(model.review)
                let device = try XCTUnwrap(model.recipients.first).device
                try model.select(device: device)
                XCTAssertNil(model.transfer)
                // Explicit model action, not a simulated UI button or reconstructed consent.
                try await model.requestTransfer()
                let original = try XCTUnwrap(model.transfer)
                let review = try XCTUnwrap(model.review)
                XCTAssertTrue(original.isActive)
                XCTAssertTrue(review.groupIdHex == fixture.group)
                XCTAssertTrue(review.recipientDevice == device)
                XCTAssertFalse(review.complete)
                try await model.refreshTransfer()
                XCTAssertTrue(model.transfer === original)
                model.cancelTransfer()
                XCTAssertFalse(original.isActive)
                XCTAssertNil(model.transfer)
                await session.deactivate()
                XCTAssertFalse(model.isActive)
                try await client.marmot.shutdownAndClose()
            } catch {
                await session.deactivate()
                try await client.marmot.shutdownAndClose()
                throw error
            }
        }
    }
#endif
