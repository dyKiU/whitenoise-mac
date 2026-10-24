import MarmotKit
import SwiftUI

#if WN_EXPERIMENTAL_DEVICE_SYNC
    /// Native bubble chrome around source-attested text; no live-message action handle is synthesized.
    struct PairedChatMessageRow: View {
        let message: PairedChatMessageFfi?
        var markdown: MarkdownDisplayDocument? = nil
        var localAccountIdHex: String? = nil
        var showsSenderName = true
        var showsSenderAvatar = false
        var senderName: (String) -> String = { _ in L10n.string("Unknown user") }
        @State private var isSelectable = false

        var body: some View {
            if let message {
                let presentation = PairedMessagePresentation(message: message, localAccountIdHex: localAccountIdHex)
                TimelineView(.periodic(from: .now, by: 1)) { clock in
                    if presentation.isVisible(at: clock.date) {
                        let timeLabel = DisplayText.messageTimestamp(
                            for: Date(timeIntervalSince1970: TimeInterval(presentation.timestamp)), now: clock.date)
                        VStack(alignment: presentation.isOutgoing ? .trailing : .leading, spacing: 6) {
                            if !presentation.isOutgoing, showsSenderName {
                                Text(verbatim: senderName(message.authorHex))
                                    .wnFont(.medium10)
                                    .foregroundStyle(WNColor.backgroundContentSecondary)
                                    .padding(.horizontal, 4)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                if presentation.isDeleted {
                                    Text(L10n.string("Message deleted")).italic()
                                } else if message.canonicalChat {
                                    MarkdownMessageView(
                                        document: markdown,
                                        fallbackText: PeerDisplayText.strippingBidiControls(presentation.text),
                                        trailingMetadata: usesInlineMetadata(presentation)
                                            ? metadataSpacer(presentation, timeLabel: timeLabel) : nil
                                    )
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text(L10n.string("Unsupported message"))
                                }
                                if presentation.showsUnavailableAttachment {
                                    Text(L10n.string("Attachment unavailable")).wnFont(.medium10)
                                }
                                if !presentation.isDeleted, !usesInlineMetadata(presentation) {
                                    metadata(presentation, timeLabel: timeLabel).hidden()
                                }
                            }
                            .wnFont(.medium16)
                            .foregroundStyle(MessagesPalette.bubbleContent(isOutgoing: presentation.isOutgoing))
                            .tint(MessagesPalette.bubbleContent(isOutgoing: presentation.isOutgoing))
                            .overlay(alignment: .bottomTrailing) {
                                if !presentation.isDeleted {
                                    metadata(presentation, timeLabel: timeLabel)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background {
                                MessageBubbleShape().fill(
                                    MessagesPalette.bubbleFill(isOutgoing: presentation.isOutgoing))
                            }
                            .modifier(MessageTextSelection(enabled: isSelectable))
                            .onHover { isSelectable = $0 }
                            .frame(maxWidth: 540, alignment: presentation.isOutgoing ? .trailing : .leading)
                        }
                        .frame(maxWidth: 660, alignment: presentation.isOutgoing ? .trailing : .leading)
                        .frame(maxWidth: .infinity, alignment: presentation.isOutgoing ? .trailing : .leading)
                        .padding(presentation.isOutgoing ? .leading : .trailing, 72)
                        .padding(.leading, !presentation.isOutgoing && showsSenderAvatar ? 36 : 0)
                        .overlay(alignment: .bottomLeading) {
                            if !presentation.isOutgoing, showsSenderAvatar {
                                ProfileImageAvatarView(
                                    seed: message.authorHex, initials: senderName(message.authorHex),
                                    sanitizedPictureURL: nil, localImagePayload: nil, size: 28, isSelected: false
                                )
                                .padding(.bottom, 2)
                            }
                        }
                    }
                }
            }
        }

        private func usesInlineMetadata(_ presentation: PairedMessagePresentation) -> Bool {
            !presentation.isDeleted && !presentation.showsUnavailableAttachment
                && message?.canonicalChat == true && !presentation.text.isEmpty
                && (markdown == nil || markdown?.inlineParagraph != nil)
        }

        private func metadata(_ presentation: PairedMessagePresentation, timeLabel: String) -> some View {
            HStack(spacing: 4) {
                if presentation.isEdited { Text(L10n.string("Edited")) }
                Text(timeLabel).monospacedDigit()
            }
            .wnFont(.medium10)
            .foregroundStyle(WNColor.backgroundContentTertiary)
        }

        private func metadataSpacer(_ presentation: PairedMessagePresentation, timeLabel: String) -> Text {
            var result = Text(verbatim: "  ")
            if presentation.isEdited {
                result = result + Text(L10n.string("Edited")).wnFont(.medium10) + Text(verbatim: " ")
            }
            return (result + Text(timeLabel).wnFont(.medium10.monospacedDigit())).foregroundColor(.clear)
        }
    }

    #Preview { PairedChatMessageRow(message: nil) }
#endif
