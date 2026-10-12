import Foundation
import MarmotKit
import Synchronization
import XCTest

@testable import whitenoise_mac

#if WN_EXPERIMENTAL_DEVICE_SYNC
    private enum NativeSwitchFailure: Error { case invalidRoot, deadline, unexpectedWrite }

    /// Existing encrypted task credentials stay read-only. Only fresh SDK-created accounts enter memory.
    nonisolated private final class NativeSwitchSecretStore: SecretStore, Sendable {
        private struct State {
            var secrets: [String: String] = [:]
            var labels: Set<String> = []
        }
        private let state = Mutex(State())
        private let original: MacImportedHistoryReadOnlyStore
        init(root: URL) throws { original = try MacImportedHistoryReadOnlyStore(root: root) }
        func hasSecretForLabel(label: String) throws -> Bool {
            try state.withLock { $0.labels.contains(label) } || original.hasSecretForLabel(label: label)
        }
        func hasSecretForAccountId(accountIdHex: String) throws -> Bool {
            try state.withLock { $0.secrets[accountIdHex] != nil }
                || original.hasSecretForAccountId(accountIdHex: accountIdHex)
        }
        func loadSecret(label: String, accountIdHex: String) throws -> String {
            if let value = state.withLock({ $0.secrets[accountIdHex] }) { return value }
            return try original.loadSecret(label: label, accountIdHex: accountIdHex)
        }
        func writeSecret(label: String, accountIdHex: String, secretKeyHex: String) throws {
            guard try !original.hasSecretForAccountId(accountIdHex: accountIdHex) else {
                throw NativeSwitchFailure.unexpectedWrite
            }
            state.withLock {
                $0.secrets[accountIdHex] = secretKeyHex
                $0.labels.insert(label)
            }
        }
        func removeSecret(label: String, accountIdHex: String) throws {
            guard try !original.hasSecretForAccountId(accountIdHex: accountIdHex) else {
                throw NativeSwitchFailure.unexpectedWrite
            }
            state.withLock {
                $0.secrets.removeValue(forKey: accountIdHex)
                $0.labels.remove(label)
            }
        }
    }

    @MainActor final class GenuineAutomaticAccountSwitchTests: XCTestCase {
        private func taskRoot() throws -> URL {
            guard let path = ProcessInfo.processInfo.environment["WN_AUTOMATIC_SWITCH_ROOT"] else {
                throw XCTSkip("Requires a fresh positively closed synthetic paired native root")
            }
            let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
            guard root.path.hasPrefix("/Users/pj/project/build/automatic-host-switch-"),
                try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber == 0o700,
                try Data(contentsOf: root.appendingPathComponent(".native-acceptance"))
                    == Data("native-sdk83-test-only-v1\n".utf8)
            else { throw NativeSwitchFailure.invalidRoot }
            return root
        }
        private func eventually(_ predicate: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while !predicate() {
                guard ContinuousClock.now < deadline else { throw NativeSwitchFailure.deadline }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        private func refusesSend(_ model: AccountConversationViewModel) async {
            do {
                _ = try await model.sendText("isolated retired owner must refuse")
                XCTFail("Retired owner admitted a send")
            } catch {
                XCTAssertTrue((error as? AutomaticChatPresentationError) == .retired)
            }
            XCTAssertTrue(model.pendingTexts.isEmpty)
            XCTAssertNil(model.snapshot)
            XCTAssertTrue(model.pairedMessages.isEmpty)
        }

        func testActualAccountsReplacePairedOwnersAndRetireBeforeRuntimeClose() async throws {
            let root = try taskRoot()
            let client = try MarmotClient(
                rootPath: root.appendingPathComponent("runtime").path,
                relayUrls: ["ws://127.0.0.1:18181"], storageProfile: .testHost,
                secretStore: try NativeSwitchSecretStore(root: root), relayPolicy: .allowLoopback)
            let session = SessionState()
            do {
                let initialAccounts = try client.listAccounts()
                XCTAssertEqual(initialAccounts.count, 1)
                let firstAccount = try XCTUnwrap(initialAccounts.first)
                try await client.start()
                let secondAccount = try await client.marmot.createIdentity(
                    defaultRelays: ["ws://127.0.0.1:18181"],
                    bootstrapRelays: ["ws://127.0.0.1:18181"], inboxRelays: ["ws://127.0.0.1:18181"])
                XCTAssertNotEqual(firstAccount.accountIdHex, secondAccount.accountIdHex)
                XCTAssertEqual(try client.listAccounts().count, 2)
                await session.activate(
                    account: AccountItem(summary: firstAccount), runtime: client, connectivityAvailable: true)
                let firstScope = try XCTUnwrap(session.accountScope)
                let firstList = try XCTUnwrap(firstScope.automaticChatList)
                try await eventually { !firstList.pairedRows.isEmpty }
                let group = try XCTUnwrap(firstList.pairedRows.first).groupIdHex
                let firstConversation = try XCTUnwrap(firstScope.selectAutomaticConversation(groupIdHex: group))
                try await eventually { !firstConversation.pairedMessages.isEmpty }
                let observedEvent = try XCTUnwrap(firstConversation.pairedMessages.first).messageIdHex
                XCTAssertEqual(observedEvent.utf8.count, 64)
                await session.activate(
                    account: AccountItem(summary: secondAccount), runtime: client, connectivityAvailable: true)
                XCTAssertTrue(firstScope.isCancelled)
                XCTAssertNil(firstList.snapshot)
                XCTAssertTrue(firstList.pairedRows.isEmpty)
                await refusesSend(firstConversation)
                XCTAssertNil(firstScope.selectAutomaticConversation(groupIdHex: group))
                let secondScope = try XCTUnwrap(session.accountScope)
                XCTAssertFalse(secondScope === firstScope)
                XCTAssertEqual(secondScope.account.accountRef, secondAccount.label)
                let secondList = try XCTUnwrap(secondScope.automaticChatList)
                try await eventually { secondList.snapshot != nil }
                XCTAssertTrue(secondList.pairedRows.isEmpty)
                let foreignConversation = try XCTUnwrap(secondScope.selectAutomaticConversation(groupIdHex: group))
                try await eventually { !foreignConversation.isLoading }
                XCTAssertNil(foreignConversation.pairedHeader)
                await refusesSend(foreignConversation)
                await session.activate(
                    account: AccountItem(summary: firstAccount), runtime: client, connectivityAvailable: true)
                XCTAssertTrue(secondScope.isCancelled)
                XCTAssertNil(secondList.snapshot)
                let returnedScope = try XCTUnwrap(session.accountScope)
                XCTAssertFalse(returnedScope === firstScope)
                let returnedList = try XCTUnwrap(returnedScope.automaticChatList)
                try await eventually { returnedList.pairedRows.contains { $0.groupIdHex == group } }
                let returnedConversation = try XCTUnwrap(returnedScope.selectAutomaticConversation(groupIdHex: group))
                XCTAssertFalse(returnedConversation === firstConversation)
                try await eventually {
                    returnedConversation.pairedMessages.contains { $0.messageIdHex == observedEvent }
                }
                await refusesSend(firstConversation)
                await session.deactivate()
                XCTAssertNil(session.accountScope)
                XCTAssertTrue(returnedScope.isCancelled)
                XCTAssertNil(returnedList.snapshot)
                await refusesSend(returnedConversation)
                try await client.marmot.shutdownAndClose()
                XCTAssertTrue(client.marmot.storageIsClosed())
            } catch {
                await session.deactivate()
                try await client.marmot.shutdownAndClose()
                XCTAssertTrue(client.marmot.storageIsClosed())
                throw error
            }
        }
    }
#endif
