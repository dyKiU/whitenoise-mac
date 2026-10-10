import Testing

@testable import whitenoise_mac

@MainActor struct SynchronizedHistoryScopeControlsTests {
    @Test func chatReleaseRetiresOnlyItsReaderAndNextOpenCreatesFreshReader() async {
        let scope = AccountScope(account: AccountItem.samples[0], runtime: FakeMarmotRuntime(accounts: []))
        let empty: SynchronizedHistoryViewModel.Reader = { _, _, _, _ in
            .init(records: [], nextMessageId: nil)
        }
        let first = scope.synchronizedHistoryModel(groupIdHex: "first", read: empty)
        let second = scope.synchronizedHistoryModel(groupIdHex: "second", read: empty)
        #expect(scope.synchronizedHistoryModel(groupIdHex: "first", read: empty) === first)
        scope.releaseConversation(groupIdHex: "first")
        #expect(!first.isActive)
        #expect(second.isActive)
        let reopened = scope.synchronizedHistoryModel(groupIdHex: "first", read: empty)
        #expect(reopened !== first)
        #expect(reopened.isActive)
        await scope.cancelAll()
        #expect(!second.isActive)
        #expect(!reopened.isActive)
    }

    @Test func cancelledAccountRefusesConstructionWithoutCallingReader() async {
        let scope = AccountScope(account: AccountItem.samples[0], runtime: FakeMarmotRuntime(accounts: []))
        await scope.cancelAll()
        let history = scope.synchronizedHistoryModel(groupIdHex: "first") { _, _, _, _ in
            Issue.record("A retired account must not begin a history read")
            return .init(records: [], nextMessageId: nil)
        }
        await history.loadNextPage()
        #expect(!history.isActive)
        #expect(!history.isLoading)
        #expect(history.records.isEmpty)
    }
}
