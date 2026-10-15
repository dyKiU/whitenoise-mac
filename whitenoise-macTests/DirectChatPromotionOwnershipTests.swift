import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

@MainActor @Suite struct DirectChatPromotionOwnershipTests {
    private enum Retirement { case replacement, replacementAndReturn, cancellation }

    @Test func accountReplacementDuringCreationCannotPromoteFromRetiredAction() async throws {
        try await verifyRetiredCreation(.replacement)
    }

    @Test func accountReturnDuringCreationCannotRevivePromotionAuthority() async throws {
        try await verifyRetiredCreation(.replacementAndReturn)
    }

    @Test func cancellationDuringCreationCannotStartAnotherAdminWrite() async throws {
        try await verifyRetiredCreation(.cancellation)
    }

    private func verifyRetiredCreation(_ retirement: Retirement) async throws {
        let primary = desktopAccount()
        let backup = AccountSummaryFfi(
            label: "Backup Account", accountIdHex: String(repeating: "f", count: 64),
            localSigning: true, externalSigning: false, signedOut: false, running: true)
        let runtime = FakeMarmotRuntime(accounts: [primary, backup])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let first = try #require(state.accounts.first { $0.id == primary.label })
        let second = try #require(state.accounts.first { $0.id == backup.label })
        state.selectAccountFromSettings(first)
        state.showNewChat()
        let recipient = NewChatRecipient(
            sourceQuery: "npub1synthetic", memberRef: "npub1synthetic",
            accountIdHex: String(repeating: "b", count: 64), npub: "npub1synthetic",
            displayName: "Synthetic peer", pictureURL: nil)
        runtime.createGroupGateEnabled = true
        let creation = Task { await state.startDirectChat(with: recipient) }
        while !runtime.didReachCreateGroupGate { await Task.yield() }
        try #require(runtime.createGroupAttempts.count == 1)
        try #require(runtime.promoteAdminDetailedCallCount == 0)
        switch retirement {
        case .replacement:
            state.selectAccountFromSettings(second)
        case .replacementAndReturn:
            state.selectAccountFromSettings(second)
            state.selectAccountFromSettings(first)
        case .cancellation:
            creation.cancel()
        }
        runtime.releaseCreateGroupGate()
        await creation.value
        try #require(runtime.createGroupAttempts.count == 1, "already-created-direct-chat-is-not-rolled-back")
        try #require(runtime.createdGroupMemberRefs == [recipient.memberRef])
        print("direct-promotion-owner-prerequisite actual-created-group=true retired-action=true")
        #expect(
            runtime.promoteAdminDetailedCallCount == 0,
            "retired-direct-chat-action-must-not-promote-peer")
    }
}
