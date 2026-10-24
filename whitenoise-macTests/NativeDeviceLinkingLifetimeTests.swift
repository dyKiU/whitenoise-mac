import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

#if WN_EXPERIMENTAL_DEVICE_SYNC
    @MainActor @Suite struct NativeDeviceLinkingLifetimeTests {
        private func waitFor(_ condition: () -> Bool) async {
            for _ in 0..<200 {
                if condition() { return }
                await Task.yield()
            }
        }

        @Test func nativeAlreadyClosedSessionCompletesCleanup() async throws {
            let original = LifetimeSession(noPointer: .init())
            original.reportAlreadyClosed()
            let owner = DeviceLinkingScope(accountRef: "test", session: original)
            defer { original.stream.finishWithClosed() }
            await waitFor { original.stream.isWaiting }
            try await owner.cancel()
            try await owner.cancel()
            #expect(owner.cleanupError == nil)
            #expect(original.cancelCount == 1)
            #expect(original.stream.closeCount == 1)
            #expect(owner.latestSnapshot == nil)
        }

        @Test func replacingAccountCancelsOriginalAndRejectsDelayedSnapshot() async throws {
            let session = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            await session.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
            let original = LifetimeSession(noPointer: .init())
            let owned = try await session.adoptDeviceLinkingFactory { _, _ in original }
            await waitFor { original.stream.isWaiting }
            await session.activate(account: AccountItem.samples[1], runtime: runtime, connectivityAvailable: false)
            #expect(original.cancelCount == 1)
            #expect(original.stream.closeCount == 1)
            #expect(session.deviceLinkingScope == nil)
            original.stream.deliverDelayedSnapshot()
            await Task.yield()
            #expect(owned.latestSnapshot == nil)
            try await owned.cancel()
            await session.deactivate()
        }

        @Test(arguments: [false, true]) func lateFactoryCannotAttachAcrossReplacementOrDeactivation(
            deactivate: Bool
        ) async throws {
            let session = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            let account = AccountItem.samples[0]
            await session.activate(account: account, runtime: runtime, connectivityAvailable: false)
            let original = LifetimeSession(noPointer: .init())
            var result: CheckedContinuation<any DeviceLinkingSessionProtocol, Never>?
            let pending = Task {
                do {
                    _ = try await session.adoptDeviceLinkingFactory { _, ref in
                        #expect(ref == account.accountRef)
                        return await withCheckedContinuation { result = $0 }
                    }
                    return true
                } catch { return false }
            }
            await waitFor { result != nil }
            #expect(result != nil)
            if deactivate {
                await session.deactivate()
                #expect(session.accountScope == nil)
            } else {
                await session.activate(account: AccountItem.samples[1], runtime: runtime, connectivityAvailable: false)
                await session.activate(account: account, runtime: runtime, connectivityAvailable: false)
            }
            result?.resume(returning: original)
            #expect(await pending.value == false)
            #expect(original.cancelCount == 1)
            #expect(original.stream.closeCount == 1)
            #expect(session.deviceLinkingScope == nil)
            original.stream.deliverDelayedSnapshot()
            await session.deactivate()
        }

        @Test func sameAccountNewRuntimeReplacesScopeAndCancelsOriginal() async throws {
            let session = SessionState()
            let first = FakeMarmotRuntime(accounts: [])
            let second = FakeMarmotRuntime(accounts: [])
            let account = AccountItem.samples[0]
            await session.activate(account: account, runtime: first, connectivityAvailable: false)
            let scope = try #require(session.accountScope)
            let original = LifetimeSession(noPointer: .init())
            let owner = try await session.adoptDeviceLinkingFactory { _, _ in original }
            await session.activate(account: account, runtime: second, connectivityAvailable: false)
            #expect(session.accountScope !== scope)
            #expect(original.cancelCount == 1)
            #expect(original.stream.closeCount == 1)
            #expect(owner.latestSnapshot == nil)
            original.stream.deliverDelayedSnapshot()
            try await owner.cancel()
            await session.deactivate()
        }

        @Test func actualRuntimeResetTearsDownOriginalBeforeCoreDeletion() async throws {
            let fixture = AccountItem.samples[0]
            let summary = AccountSummaryFfi(
                label: fixture.accountRef, accountIdHex: fixture.accountIdHex, localSigning: true,
                externalSigning: false, signedOut: false, running: true)
            let runtime = FakeMarmotRuntime(accounts: [summary])
            let workspace = WorkspaceState(clientFactory: { runtime })
            await workspace.bootstrap()
            let account = try #require(workspace.activeAccount)
            let session = SessionState()
            await session.activate(account: account, runtime: runtime, connectivityAvailable: false)
            let original = LifetimeSession(noPointer: .init())
            let owner = try await session.adoptDeviceLinkingFactory { _, _ in original }
            var callbackCalled = false
            runtime.onDeleteAllLocalDataMidFlight = {
                #expect(original.cancelCount == 1)
                #expect(original.stream.closeCount == 1)
            }
            await workspace.deleteAllData(beforeRuntimeReset: {
                callbackCalled = true
                await session.deactivate()
            })
            #expect(callbackCalled)
            #expect(runtime.didDeleteAllLocalData)
            #expect(session.accountScope == nil)
            #expect(owner.latestSnapshot == nil)
            original.stream.deliverDelayedSnapshot()
            try await owner.cancel()
            await session.deactivate()
        }
        @Test func actualResetCleanupFailureRetainsExactOwnerWithoutRetryingImplicitly() async throws {
            let fixture = AccountItem.samples[0]
            let summary = AccountSummaryFfi(
                label: fixture.accountRef, accountIdHex: fixture.accountIdHex, localSigning: true,
                externalSigning: false, signedOut: false, running: true)
            let runtime = FakeMarmotRuntime(accounts: [summary])
            let workspace = WorkspaceState(clientFactory: { runtime })
            await workspace.bootstrap()
            let session = SessionState()
            await session.activate(account: workspace.activeAccount, runtime: runtime, connectivityAvailable: false)
            let original = LifetimeSession(noPointer: .init())
            let owner = try await session.adoptDeviceLinkingFactory { _, _ in original }
            original.setCancellationFailure(true)
            await workspace.deleteAllData(beforeRuntimeReset: { try await session.prepareForAccountExit() })
            #expect(!runtime.didDeleteAllLocalData)
            #expect(!workspace.isDeletingAllData)
            #expect(original.cancelCount == 1)
            #expect(original.stream.closeCount == 1)
            #expect(session.deviceLinkingScope == nil)
            #expect(session.retiringDeviceLinkingScope === owner)
            #expect(owner.cleanupError != nil)
            original.setCancellationFailure(false)
            try await session.retryDeviceLinkingCleanup()
            #expect(original.cancelCount == 2)
            #expect(session.retiringDeviceLinkingScope == nil)
            original.stream.deliverDelayedSnapshot()
        }
        @Test func originalFactoryRemainsBoundedWhileIgnoredCancellationReturnsLate() async throws {
            let session = SessionState()
            let runtime = FakeMarmotRuntime(accounts: [])
            await session.activate(account: AccountItem.samples[0], runtime: runtime, connectivityAvailable: false)
            var result: CheckedContinuation<any DeviceLinkingSessionProtocol, Never>?
            let pending = Task {
                do {
                    _ = try await session.adoptDeviceLinkingFactory { _, _ in
                        await withCheckedContinuation { result = $0 }
                    }
                    return true
                } catch { return false }
            }
            await waitFor { result != nil }
            #expect(result != nil)
            var secondCalled = false
            await #expect(throws: CancellationError.self) {
                _ = try await session.adoptDeviceLinkingFactory { _, _ in
                    secondCalled = true
                    return LifetimeSession(noPointer: .init())
                }
            }
            #expect(!secondCalled)
            await session.deactivate()
            #expect(session.accountScope == nil)
            let late = LifetimeSession(noPointer: .init())
            late.setCancellationFailure(true)
            result?.resume(returning: late)
            #expect(await pending.value == false)
            #expect(late.cancelCount == 1)
            #expect(late.stream.closeCount == 1)
            #expect(session.deviceLinkingScope == nil)
            #expect(session.retiringDeviceLinkingScope?.cleanupError != nil)
            late.setCancellationFailure(false)
            try await session.retryDeviceLinkingCleanup()
            #expect(late.cancelCount == 2)
            #expect(session.retiringDeviceLinkingScope == nil)
            late.stream.deliverDelayedSnapshot()
        }

        @Test func actualClassRuntimeRerenderPreservesScopeAndFactoryErrors() async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("white-noise-linking-scope-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let runtime = try MarmotClient(
                rootPath: root.path, relayUrls: ["wss://relay.example.invalid"], storageProfile: .testHost)
            let session = SessionState()
            let account = AccountItem.samples[0]
            await session.activate(account: account, runtime: runtime, connectivityAvailable: false)
            let originalScope = try #require(session.accountScope)
            await session.activate(account: account, runtime: runtime, connectivityAvailable: false)
            #expect(session.accountScope === originalScope)
            await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) {
                _ = try await session.beginDeviceLinkingSession()
            }
            await #expect(throws: MarmotKitError.DeviceLinkingRuntimeUnavailable) {
                _ = try await session.approveDeviceLinkingSession(request: Data(), target: nil)
            }
            #expect(session.deviceLinkingScope == nil)
            #expect(try runtime.listAccounts().isEmpty)
            await session.deactivate()
            try await runtime.marmot.shutdownAndClose()
        }
        @Test(arguments: [false, true]) func actualAccountExitCleanupFailureBlocksCoreAndRetainsOwner(
            remove: Bool
        ) async throws {
            let fixture = AccountItem.samples[0]
            let summary = AccountSummaryFfi(
                label: fixture.accountRef, accountIdHex: fixture.accountIdHex, localSigning: true,
                externalSigning: false, signedOut: false, running: true)
            let runtime = FakeMarmotRuntime(accounts: [summary])
            let workspace = WorkspaceState(clientFactory: { runtime })
            await workspace.bootstrap()
            let account = try #require(workspace.activeAccount)
            let session = SessionState()
            await session.activate(account: account, runtime: runtime, connectivityAvailable: false)
            let original = LifetimeSession(noPointer: .init())
            let owner = try await session.adoptDeviceLinkingFactory { _, _ in original }
            original.setCancellationFailure(true)
            let teardown: @MainActor () async throws -> Void = {
                try await session.prepareForAccountExit(accountID: account.id)
            }
            if remove {
                await workspace.removeAccount(account, beforeAccountExit: teardown)
            } else {
                await workspace.signOutAccount(account, beforeAccountExit: teardown)
            }
            #expect(runtime.removedAccountRefs.isEmpty)
            #expect(runtime.signedOutAccountRefs.isEmpty)
            #expect(!workspace.isAccountMutationInProgress)
            #expect(workspace.activeAccount?.id == account.id)
            #expect(original.cancelCount == 1)
            #expect(original.stream.closeCount == 1)
            #expect(session.retiringDeviceLinkingScope === owner)
            original.setCancellationFailure(false)
            try await session.retryDeviceLinkingCleanup()
            #expect(original.cancelCount == 2)
            original.stream.deliverDelayedSnapshot()
        }
        @Test func repeatedAccountExitCannotBypassDetachedFailedCleanup() async throws {
            let fixture = AccountItem.samples[0]
            let summary = AccountSummaryFfi(
                label: fixture.accountRef, accountIdHex: fixture.accountIdHex, localSigning: true,
                externalSigning: false, signedOut: false, running: true)
            let runtime = FakeMarmotRuntime(accounts: [summary])
            let workspace = WorkspaceState(clientFactory: { runtime })
            await workspace.bootstrap()
            let account = try #require(workspace.activeAccount)
            let session = SessionState()
            await session.activate(account: account, runtime: runtime, connectivityAvailable: false)
            let original = LifetimeSession(noPointer: .init())
            let owner = try await session.adoptDeviceLinkingFactory { _, _ in original }
            original.setCancellationFailure(true)
            let teardown: @MainActor () async throws -> Void = {
                try await session.prepareForAccountExit(accountID: account.id)
            }
            await workspace.signOutAccount(account, beforeAccountExit: teardown)
            #expect(runtime.signedOutAccountRefs.isEmpty)
            #expect(session.accountScope == nil)
            await workspace.signOutAccount(account, beforeAccountExit: teardown)
            #expect(runtime.signedOutAccountRefs.isEmpty)
            #expect(workspace.activeAccount?.id == account.id)
            #expect(original.cancelCount == 2)
            #expect(original.stream.closeCount == 1)
            #expect(session.retiringDeviceLinkingScope === owner)
            original.setCancellationFailure(false)
            try await session.retryDeviceLinkingCleanup()
            #expect(original.cancelCount == 3)
            original.stream.deliverDelayedSnapshot()
        }
    }
#endif
