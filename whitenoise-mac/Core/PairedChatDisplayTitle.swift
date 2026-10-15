import Foundation

/// An attested direct peer permits contact naming; an absent peer preserves group semantics.
nonisolated enum PairedChatDisplayTitle {
    static func resolve(name: String?, directPeerAccountIdHex: String?, peerDisplayName: String?) -> String {
        let name = PeerDisplayText.sanitize(name)
        guard let peer = directPeerAccountIdHex?.nilIfBlank else {
            return name ?? L10n.string("Unnamed group")
        }
        return PeerDisplayText.sanitize(peerDisplayName) ?? name ?? DisplayText.short(peer)
    }
}
