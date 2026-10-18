import MarmotKit
import SwiftUI

#if WN_EXPERIMENTAL_DEVICE_SYNC
    /// Paired-only text lane. Ordinary conversations keep their authenticated window and media actions.
    struct AutomaticConversationView: View {
        let model: AccountConversationViewModel?
        var localAccountIdHex: String? = nil
        var blockedAuthors: Set<String> = []
        var senderName: (String) -> String = { _ in L10n.string("Unknown user") }
        @State private var mentionSelections: [ComposerMentionSelection] = []
        var title: (PairedChatSummaryFfi) -> String = {
            PairedChatDisplayTitle.resolve(
                name: $0.name, directPeerAccountIdHex: $0.directPeerAccountIdHex, peerDisplayName: nil)
        }
        @State private var text = ""
        @State private var sending = false
        @State private var sendFailed = false
        @State private var scrollPosition = ScrollPosition(edge: .bottom)
        @State private var followsNewest = true
        @State private var userScrolling = false

        private var messages: [PairedChatMessageFfi] {
            model?.snapshot?.rows.compactMap { row in
                if case .pairedSource(let value) = row { return value }
                return nil
            } ?? []
        }

        private func statusLabel(_ status: LocalSendStatusFfi?) -> LocalizedStringKey {
            switch status {
            case .completed: "Sent"
            case .rejected: "Send failed"
            case .engineOwned: "Sending"
            case .queued, nil: "Pending"
            }
        }

        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    let header = model?.pairedHeader
                    let heading = header.map(title) ?? L10n.string("Unnamed group")
                    ProfileImageAvatarView(
                        seed: header?.directPeerAccountIdHex ?? model?.groupIdHex ?? "",
                        initials: heading, sanitizedPictureURL: nil, localImagePayload: nil,
                        size: 38, isSelected: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: heading).wnFont(.semiBold16).lineLimit(1)
                        Text("Shared from a linked device").wnFont(.medium10).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 76)
                .background { MessagesHeaderBackground() }
                GlassSeparator(axis: .horizontal)
                if model?.isLoading == true {
                    ProgressView()
                }
                if model?.error != nil {
                    Text(L10n.string("Chat unavailable"))
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model?.snapshot?.nextBefore != nil {
                            Button("Load older messages") { Task { await model?.loadOlder() } }
                        }
                        ForEach(PairedTimelineEntry.make(messages: messages, blockedAuthors: blockedAuthors)) { entry in
                            if let day = entry.dayStart {
                                TimelineDayHeaderView(title: DisplayText.timelineDayLabel(for: day))
                            }
                            PairedChatMessageRow(
                                message: entry.message,
                                markdown: model?.markdownByMessageId[entry.id],
                                localAccountIdHex: localAccountIdHex,
                                showsSenderName: model?.pairedHeader?.directPeerAccountIdHex == nil,
                                senderName: senderName)
                        }
                        if let model {
                            ForEach(Array(model.pendingTexts.values).sorted { $0.createdAt < $1.createdAt }) {
                                pending in
                                VStack(alignment: .trailing, spacing: 6) {
                                    Text(verbatim: pending.text)
                                        .wnFont(.medium14)
                                        .foregroundStyle(MessagesPalette.bubbleContent(isOutgoing: true))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background {
                                            MessageBubbleShape().fill(MessagesPalette.bubbleFill(isOutgoing: true))
                                        }
                                    Text(statusLabel(pending.status))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: 660, alignment: .trailing)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.leading, 72)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .scrollPosition($scrollPosition)
                .onScrollPhaseChange { _, phase in
                    userScrolling = phase == .interacting || phase == .decelerating
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.visibleRect.maxY < 80
                } action: { _, atBottom in
                    if userScrolling { followsNewest = atBottom }
                }
                .onChange(of: model?.snapshot?.sequence) { _, _ in
                    if followsNewest { scrollPosition.scrollTo(edge: .bottom) }
                }
                if sendFailed { Text(L10n.string("Send failed")) }
                if isBlockedDirectPeer {
                    BlockedConversationComposerNotice()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                } else {
                    HStack(alignment: .bottom, spacing: 8) {
                        ComposerMessageInputView(
                            text: $text, placeholder: L10n.string("Message"),
                            emojiInsertion: nil, onEmojiInsertionConsumed: { _ in },
                            mentionInsertion: nil, onMentionInsertionConsumed: { _ in },
                            mentionSelections: $mentionSelections, mentionContextScope: nil,
                            onMentionContextChange: { _ in }, onMentionCommand: { _ in false },
                            onPasteMedia: { _ in }, onSend: send
                        )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background { MessagesComposerFieldBackground() }
                        Button(action: send) {
                            MessagesSendButtonLabel(
                                systemImage: "paperplane.fill", isEnabled: canSend, isSending: sending)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .help(L10n.string("Send"))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background { MessagesComposerBarBackground() }
                }
            }
        }
        private var isBlockedDirectPeer: Bool {
            model?.pairedHeader?.directPeerAccountIdHex.map {
                blockedAuthors.contains($0.lowercased())
            } ?? false
        }

        private var canSend: Bool {
            !sending && !isBlockedDirectPeer && model?.pairedHeader != nil
                && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        private func send() {
            guard let model, canSend else { return }
            let captured = text
            sending = true
            sendFailed = false
            Task {
                defer { sending = false }
                do {
                    _ = try await model.sendText(captured)
                    if text == captured { text = "" }
                    followsNewest = true
                    scrollPosition.scrollTo(edge: .bottom)
                    await model.refreshPendingStatus()
                } catch { sendFailed = true }
            }
        }
    }

    #Preview {
        AutomaticConversationView(model: nil)
    }
#endif
