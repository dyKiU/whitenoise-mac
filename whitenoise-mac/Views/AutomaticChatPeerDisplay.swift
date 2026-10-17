import MarmotKit

#if WN_EXPERIMENTAL_DEVICE_SYNC
    /// Shell adapter: feature views receive titles explicitly and never reach into workspace state.
    @MainActor enum AutomaticChatPeerDisplay {
        static func title(_ row: PairedChatSummaryFfi, workspace: WorkspaceState) -> String {
            let peer = row.directPeerAccountIdHex
            let resolved = peer.flatMap { workspace.peerProfileFFICache[$0]?.resolved }
            let published = MentionPublishedName.resolve(
                profileDisplayName: resolved?.profileDisplayName, profileName: resolved?.profileName,
                rosterDisplayName: nil, directoryDisplayName: resolved?.directoryDisplayName)
            let nickname = peer.flatMap { workspace.contactNickname(forContactAccountIdHex: $0) }
            return PairedChatDisplayTitle.resolve(
                name: row.name, directPeerAccountIdHex: peer,
                peerDisplayName: PeerDisplayText.sanitize(nickname) ?? published)
        }
    }
#endif
