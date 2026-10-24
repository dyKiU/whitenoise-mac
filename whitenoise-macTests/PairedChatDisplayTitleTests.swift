import Testing

@testable import whitenoise_mac

@Suite struct PairedChatDisplayTitleTests {
    private let peer = String(repeating: "a", count: 64)

    @Test func knownDirectPeerUsesCurrentContactName() {
        #expect(
            PairedChatDisplayTitle.resolve(name: "Old name", directPeerAccountIdHex: peer, peerDisplayName: "New name")
                == "New name")
    }

    @Test func unresolvedDirectPeerKeepsSourceName() {
        #expect(
            PairedChatDisplayTitle.resolve(name: "Source name", directPeerAccountIdHex: peer, peerDisplayName: nil)
                == "Source name")
    }

    @Test func unnamedDirectPeerUsesIdentityInsteadOfGroupPlaceholder() {
        #expect(
            PairedChatDisplayTitle.resolve(name: "", directPeerAccountIdHex: peer, peerDisplayName: nil)
                == DisplayText.short(peer))
    }

    @Test func legacyUnknownPeerNeverBorrowsAContactName() {
        #expect(
            PairedChatDisplayTitle.resolve(name: "Group", directPeerAccountIdHex: nil, peerDisplayName: "Contact")
                == "Group")
    }

    @Test func unnamedLegacyGroupKeepsGroupPlaceholder() {
        #expect(
            PairedChatDisplayTitle.resolve(name: " ", directPeerAccountIdHex: nil, peerDisplayName: nil)
                == L10n.string("Unnamed group"))
    }

    @Test func peerControlledNamesAreSanitized() {
        #expect(
            PairedChatDisplayTitle.resolve(
                name: "", directPeerAccountIdHex: peer, peerDisplayName: "New\u{202e} name\n") == "New name")
    }

    @Test func aChangedNameIsVisibleWithoutChangingTheChatRecord() {
        let original = PairedChatDisplayTitle.resolve(name: "", directPeerAccountIdHex: peer, peerDisplayName: "Before")
        let updated = PairedChatDisplayTitle.resolve(name: "", directPeerAccountIdHex: peer, peerDisplayName: "After")
        #expect(original == "Before")
        #expect(updated == "After")
    }
}
