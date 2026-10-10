import Foundation
import Testing

@testable import whitenoise_mac

private actor ScopedHistoryReadGate {
    private var entered = false
    private var waitingForEntry: CheckedContinuation<Void, Never>?
    private var waitingForRelease: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation { continuation in
            waitingForRelease = continuation
            entered = true
            waitingForEntry?.resume()
            waitingForEntry = nil
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waitingForEntry = $0 }
    }

    func release() {
        waitingForRelease?.resume()
        waitingForRelease = nil
    }
}

@MainActor struct SynchronizedHistoryAccountScopeTests {
    @Test func switchingActualAccountScopeRetiresLateHistoryRead() async throws {
        let session = SessionState()
        let runtime = FakeMarmotRuntime(accounts: [])
        let accounts = AccountItem.samples
        let gate = ScopedHistoryReadGate()
        await session.activate(account: accounts[0], runtime: runtime, connectivityAvailable: true)
        let oldScope = try #require(session.accountScope)
        let expectedAccount = accounts[0].accountRef
        let history = oldScope.synchronizedHistoryModel(groupIdHex: "synthetic-chat") { account, group, _, _ in
            #expect(account == expectedAccount)
            #expect(group == "synthetic-chat")
            await gate.pause()
            let record = SynchronizedHistoryRecord(
                id: String(repeating: "01", count: 32), authorPubkey: String(repeating: "02", count: 32),
                createdAt: 1, expiresAt: nil, deleted: false, content: "synthetic old account history",
                tags: [], mediaAttachments: [], transferId: Data(repeating: 3, count: 32),
                sourceDevice: Data(repeating: 4, count: 32), manifestDigest: Data(repeating: 5, count: 32))
            return .init(records: [record], nextMessageId: nil)
        }
        let loading = Task { await history.loadNextPage() }
        await gate.waitUntilEntered()
        await session.activate(account: accounts[1], runtime: runtime, connectivityAvailable: true)
        #expect(!history.isActive)
        await gate.release()
        await loading.value
        #expect(history.records.isEmpty)
        #expect(!history.isLoading)
        #expect(session.accountScope?.account.id == accounts[1].id)
        await session.deactivate()
    }
}
