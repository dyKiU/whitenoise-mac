import Foundation
import Testing

@testable import whitenoise_mac

@MainActor struct SynchronizedHistoryRuntimeTests {
    @Test func accountOwnedReaderUsesCapturedRuntimeAndReadsOffMainThread() async {
        let runtime = FakeMarmotRuntime(accounts: [])
        let account = AccountItem.samples[0]
        let expectedAccount = account.accountRef
        let scope = AccountScope(account: account, runtime: runtime)
        let record = SynchronizedHistoryRecord(
            id: String(repeating: "01", count: 32), authorPubkey: String(repeating: "02", count: 32),
            createdAt: 12, expiresAt: nil, deleted: false, content: "synthetic runtime history",
            tags: [], mediaAttachments: [], transferId: Data(repeating: 3, count: 32),
            sourceDevice: Data(repeating: 4, count: 32), manifestDigest: Data(repeating: 5, count: 32))
        runtime.installSynchronizedHistoryPageHandler { account, group, cursor, limit in
            #expect(account == expectedAccount)
            #expect(group == "synthetic-chat")
            #expect(cursor == nil)
            #expect(limit == 200)
            return .init(records: [record], nextMessageId: nil)
        }
        let reader = scope.synchronizedHistoryModel(groupIdHex: "synthetic-chat")
        await reader.loadNextPage()
        #expect(reader.records.map(\.id) == [record.id])
        #expect(!reader.readFailed)
        #expect(runtime.syncCallThreadRecord("synchronizedHistoryPage") == [false])
        await scope.cancelAll()
        #expect(reader.records.isEmpty)
    }
}
