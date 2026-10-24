import Foundation
import MarmotKit
import Testing

@testable import whitenoise_mac

#if WN_EXPERIMENTAL_DEVICE_SYNC
    @MainActor @Suite struct PairedChatListPreviewTests {
        private func message() -> PairedChatMessageFfi {
            .init(
                kind: 9, canonicalChat: true, messageIdHex: String(repeating: "a", count: 64),
                authorHex: String(repeating: "b", count: 64), createdAt: 123, expiresAt: nil,
                deleted: false, content: "Synthetic text", contentTokens: emptyMarkdownDocument(),
                tags: [], mediaAttachments: [],
                source: .init(
                    deviceHex: String(repeating: "c", count: 64),
                    policyDigestHex: String(repeating: "d", count: 64),
                    protectedGeneration: 1, sourceEpoch: 1, sourceSequence: 1,
                    sourceDigestHex: String(repeating: "e", count: 64)))
        }

        @Test func pairedAndLocalTextUseTheSameNativePreview() throws {
            let paired = message()
            let local = try #require(
                chatListRow(
                    groupIdHex: "synthetic", title: "Friends", preview: paired.content,
                    sender: paired.authorHex, timelineAt: paired.createdAt
                ).lastMessage)
            for account in [nil, paired.authorHex] {
                let expected = ChatItem.previewProjection(
                    for: ChatPreviewInput(local), activeAccountIdHex: account, senderNickname: "Alice")
                let actual = ChatItem.previewProjection(
                    for: ChatPreviewInput(paired), activeAccountIdHex: account, senderNickname: "Alice")
                #expect(actual.text == expected.text)
                #expect(actual.attachmentKind == expected.attachmentKind)
                #expect(actual.attribution == expected.attribution)
            }
        }

        @Test func pairedCaptionAndPhotoUseTheSameNativePreview() throws {
            var paired = message()
            paired.mediaAttachments = [
                .accepted(
                    attachmentIndex: 0,
                    reference: mediaAttachmentReference(mediaType: "image/jpeg", fileName: "synthetic.jpg"))
            ]
            let local = try #require(
                chatListRow(
                    groupIdHex: "synthetic", title: "Friends", preview: paired.content,
                    sender: paired.authorHex, timelineAt: paired.createdAt,
                    attachmentKind: .photo, attachmentCount: 1
                ).lastMessage)
            let expected = ChatItem.previewProjection(for: ChatPreviewInput(local), activeAccountIdHex: nil)
            let actual = ChatItem.previewProjection(for: ChatPreviewInput(paired), activeAccountIdHex: nil)
            #expect(actual.text == expected.text)
            #expect(actual.attachmentKind == .photo)
        }

        @Test func photoOnlyPreviewUsesTheNativePluralAndOwnSenderPrefix() {
            var paired = message()
            paired.content = ""
            paired.mediaAttachments = (0..<2).map { index in
                .accepted(
                    attachmentIndex: UInt32(index),
                    reference: mediaAttachmentReference(mediaType: "image/jpeg", fileName: "synthetic.jpg"))
            }
            let actual = ChatItem.previewProjection(
                for: ChatPreviewInput(paired), activeAccountIdHex: paired.authorHex)
            #expect(actual.text == String(format: L10n.string("You: %@"), L10n.plural("%lld photos", Int64(2))))
            #expect(actual.attachmentKind == .photo)
        }

        @Test func unsupportedSourceKindsNeverInterpretPeerContent() {
            var paired = message()
            paired.canonicalChat = false
            paired.kind = 1068
            let actual = ChatItem.previewProjection(for: ChatPreviewInput(paired), activeAccountIdHex: nil)
            #expect(actual.text == L10n.string("Unsupported message"))
            #expect(actual.attribution == nil)
            #expect(actual.attachmentKind == nil)
        }

        @Test func deletionMasksContentAndAttachmentsBeforeAttribution() {
            var paired = message()
            paired.deleted = true
            paired.mediaAttachments = [
                .accepted(
                    attachmentIndex: 0,
                    reference: mediaAttachmentReference(mediaType: "image/jpeg", fileName: "synthetic.jpg"))
            ]
            let actual = ChatItem.previewProjection(
                for: ChatPreviewInput(paired), activeAccountIdHex: paired.authorHex, senderNickname: "Alice")
            #expect(actual.text == L10n.string("Message deleted"))
            #expect(actual.attribution == nil)
            #expect(actual.attachmentKind == nil)
        }

        @Test func sidebarUsesSourceMessageTimeAndCurrentContactName() {
            let value = message()
            let row = PairedChatSummaryFfi(
                groupIdHex: "synthetic", name: "Friends", description: "", source: value.source,
                latestMessage: value)
            let item = PairedChatSidebarPresentation.item(row, title: "Friends", senderName: { _ in "Alice" })
            #expect(item.preview == ChatItem.attributedPreviewText(body: value.content, senderName: "Alice"))
            #expect(item.previewAttribution?.senderAccountIdHex == value.authorHex)
            #expect(item.previewAttribution?.body == value.content)
            #expect(item.updatedAt == Date(timeIntervalSince1970: 123))
            #expect(item.latestMessageDelivery == .notApplicable)
        }

        @Test func blockedAuthorCannotLeakTextOrAttributionIntoSidebar() {
            let value = message()
            let row = PairedChatSummaryFfi(
                groupIdHex: "synthetic", name: "Friends", description: "", source: value.source,
                latestMessage: value)
            let item = PairedChatSidebarPresentation.item(
                row, title: "Friends", senderName: { _ in "Alice" }, isBlocked: { $0 == value.authorHex })
            #expect(item.preview == L10n.string("New message"))
            #expect(item.previewAttribution == nil)
            #expect(item.previewAttachmentKind == nil)
        }

        @Test func exactExpiryHidesTheMessagePreviewAndItsTime() {
            var value = message()
            value.expiresAt = 200
            let row = PairedChatSummaryFfi(
                groupIdHex: "synthetic", name: "Friends", description: "", source: value.source,
                latestMessage: value)
            let item = PairedChatSidebarPresentation.item(
                row, title: "Friends", now: Date(timeIntervalSince1970: 200))
            #expect(item.preview.isEmpty)
            #expect(item.updatedAt == nil)
        }
    }
#endif
