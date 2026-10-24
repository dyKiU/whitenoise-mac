import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

@MainActor @Suite struct DirectConversationRoutingTests {
    private let peer = String(repeating: "b", count: 64)

    private var recipient: NewChatRecipient {
        NewChatRecipient(
            sourceQuery: peer, memberRef: peer, accountIdHex: peer,
            npub: "npub1synthetic", displayName: "Synthetic peer", pictureURL: nil)
    }

    #if WN_EXPERIMENTAL_DEVICE_SYNC
        private var paired: PairedChatSummaryFfi {
            .init(
                groupIdHex: "source-only-group", name: "", description: "",
                source: .init(
                    deviceHex: String(repeating: "c", count: 64), policyDigestHex: String(repeating: "d", count: 64),
                    protectedGeneration: 1, sourceEpoch: 1, sourceSequence: 1,
                    sourceDigestHex: String(repeating: "e", count: 64)))
        }

        @Test func contactMessageReusesPairedChatWithoutAnotherInvitationOrLocalMembership() async {
            let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
            runtime.existingDirectConversationsByPeer[peer] = .pairedSource(paired)
            let state = WorkspaceState(clientFactory: { runtime })
            await state.bootstrap()
            state.showNewChat()
            await state.startDirectChat(with: recipient)
            #expect(state.selection == .chat(paired.groupIdHex))
            #expect(runtime.createGroupAttempts.isEmpty)
            #expect(runtime.promoteAdminDetailedCallCount == 0)
            #expect(state.activeChats.isEmpty)
            #expect(runtime.existingDirectConversationQueries.last?.peer == peer)
        }

        @Test func composerReusesPairedChatOutsideTheOrdinaryChatList() async {
            let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
            runtime.existingDirectConversationsByPeer[peer] = .pairedSource(paired)
            let state = WorkspaceState(clientFactory: { runtime })
            await state.bootstrap()
            state.showNewChat()
            state.newChatRecipients = [recipient]
            await state.createNewChat()
            #expect(state.selection == .chat(paired.groupIdHex))
            #expect(runtime.createGroupAttempts.isEmpty)
            #expect(runtime.promoteAdminDetailedCallCount == 0)
            #expect(state.activeChats.isEmpty)
        }
    #endif

    @Test func lookupFailureDoesNotFallThroughToCreatingAnotherInvitation() async {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        runtime.existingDirectConversationError = CancellationError()
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        state.showNewChat()
        await state.startDirectChat(with: recipient)
        #expect(runtime.createGroupAttempts.isEmpty)
    }

    @Test func firstDirectConversationUsesNativeUnnamedGroupSentinel() async {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        state.showNewChat()
        state.newChatRecipients = [recipient]
        await state.createNewChat()
        #expect(runtime.createdGroupName == "")
        #expect(runtime.createdGroupMemberRefs == [peer])
    }

    @Test func explicitNamedGroupDoesNotReuseADirectConversation() async {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        state.showNewChat()
        state.newChatRecipients = [recipient]
        state.newChatName = "Named project"
        await state.createNewChat()
        #expect(runtime.createdGroupName == "Named project")
        #expect(runtime.existingDirectConversationQueries.isEmpty)
    }
    @Test func accountSwitchAndReturnDuringLookupCannotCreateAnInvitationFromTheRetiredAction() async throws {
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
        runtime.onDirectConversationLookup = {
            await MainActor.run {
                state.selectAccountFromSettings(second)
                state.selectAccountFromSettings(first)
            }
        }
        state.showNewChat()
        await state.startDirectChat(with: recipient)
        #expect(state.activeAccountId == primary.label)
        #expect(runtime.createGroupAttempts.isEmpty)
        #expect(runtime.existingDirectConversationQueries.count == 1)
    }

    @Test func startNewBypassesSourceOwnedLocalSdkCandidate() async throws {
        let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
        runtime.existingDirectConversationsByPeer[peer] = .localMls(
            .init(
                groupIdHex: "existing-sdk-direct", reusable: true, lifecycleState: .stable,
                selfMembership: .member, pendingConfirmation: false, leaveRequestPending: false,
                disbanding: false, archived: false, activitySortAt: 1))
        let state = WorkspaceState(clientFactory: { runtime })
        await state.bootstrap()
        let accountId = try #require(state.activeAccountId)
        state.showNewChat()
        await state.startDirectChat(with: recipient, reusingExisting: false, expectedAccountId: accountId)
        #expect(runtime.existingDirectConversationQueries.isEmpty)
        #expect(runtime.createGroupAttempts == [[peer]])
        #expect(runtime.createdGroupMemberRefs == [peer])
        #expect(state.selection == .chat("created-group"))
    }

    #if WN_EXPERIMENTAL_DEVICE_SYNC
        @Test func startNewBypassesSourceOwnedPairedSdkCandidate() async throws {
            let runtime = FakeMarmotRuntime(accounts: [desktopAccount()])
            runtime.existingDirectConversationsByPeer[peer] = .pairedSource(paired)
            let state = WorkspaceState(clientFactory: { runtime })
            await state.bootstrap()
            let accountId = try #require(state.activeAccountId)
            state.showNewChat()
            await state.startDirectChat(with: recipient, reusingExisting: false, expectedAccountId: accountId)
            #expect(runtime.existingDirectConversationQueries.isEmpty)
            #expect(runtime.createGroupAttempts == [[peer]])
            #expect(runtime.createdGroupMemberRefs == [peer])
            #expect(state.selection == .chat("created-group"))
        }
    #endif

}
