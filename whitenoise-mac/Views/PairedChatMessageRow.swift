import MarmotKit
import SwiftUI

#if WN_EXPERIMENTAL_DEVICE_SYNC
    /// Native bubble chrome around source-attested text; no live-message action handle is synthesized.
    struct PairedChatMessageRow: View {
        let message: PairedChatMessageFfi?
        var markdown: MarkdownDisplayDocument? = nil
        var localAccountIdHex: String? = nil
        var showsSenderName = true
        var senderName: (String) -> String = { _ in L10n.string("Unknown user") }
        @State private var isSelectable = false

        var body: some View {
            if let message {
                let presentation = PairedMessagePresentation(message: message, localAccountIdHex: localAccountIdHex)
                TimelineView(.periodic(from: .now, by: 1)) { clock in
                    if presentation.isVisible(at: clock.date) {
                        VStack(alignment: presentation.isOutgoing ? .trailing : .leading, spacing: 6) {
                            if !presentation.isOutgoing, showsSenderName {
                                Text(verbatim: senderName(message.authorHex))
                                    .wnFont(.medium10)
                                    .foregroundStyle(WNColor.backgroundContentSecondary)
                                    .padding(.horizontal, 4)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                if presentation.isDeleted {
                                    Text(L10n.string("Message deleted")).italic()
                                } else if message.canonicalChat {
                                    MarkdownMessageView(
                                        document: markdown,
                                        fallbackText: PeerDisplayText.strippingBidiControls(presentation.text)
                                    )
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text(L10n.string("Unsupported message"))
                                }
                                if presentation.showsUnavailableAttachment {
                                    Text(L10n.string("Attachment unavailable")).wnFont(.medium10)
                                }
                                HStack(spacing: 4) {
                                    Spacer(minLength: 0)
                                    if presentation.isEdited {
                                        Text(L10n.string("Edited"))
                                            .wnFont(.medium10)
                                            .opacity(0.75)
                                    }
                                    Text(
                                        Date(timeIntervalSince1970: TimeInterval(presentation.timestamp)), style: .time
                                    )
                                    .wnFont(.medium10)
                                    .opacity(0.75)
                                }
                            }
                            .wnFont(.medium14)
                            .foregroundStyle(MessagesPalette.bubbleContent(isOutgoing: presentation.isOutgoing))
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
                    }
                }
            }
        }
    }

    #Preview { PairedChatMessageRow(message: nil) }
#endif
