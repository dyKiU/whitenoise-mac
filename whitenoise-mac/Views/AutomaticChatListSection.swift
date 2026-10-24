import MarmotKit
import SwiftUI

#if WN_EXPERIMENTAL_DEVICE_SYNC
    enum PairedChatSidebarPresentation {
        /// Display values only; actions continue to use the original paired conversation owner.
        static func item(
            _ row: PairedChatSummaryFfi, title: String, activeAccountIdHex: String? = nil,
            senderName: (String) -> String? = { _ in nil },
            isBlocked: (String) -> Bool = { _ in false }, now: Date = Date()
        ) -> ChatItem {
            let latest = row.latestMessage.flatMap { message in
                message.expiresAt.map { Double($0) <= now.timeIntervalSince1970 } == true ? nil : message
            }
            let blocked = latest.map { isBlocked($0.authorHex) } ?? false
            let preview = latest.flatMap { message in
                blocked
                    ? nil
                    : ChatItem.previewProjection(
                        for: ChatPreviewInput(message), activeAccountIdHex: activeAccountIdHex,
                        senderNickname: PeerDisplayText.sanitize(senderName(message.authorHex)))
            }
            return ChatItem(
                id: row.groupIdHex, title: title,
                subtitle: L10n.string(row.directPeerAccountIdHex == nil ? "Group message" : "Direct message"),
                preview: blocked ? L10n.string("New message") : preview?.text ?? "",
                previewAttachmentKind: preview?.attachmentKind, previewAttribution: preview?.attribution,
                updatedAt: latest.map { Date(timeIntervalSince1970: TimeInterval($0.createdAt)) },
                avatarSeed: row.directPeerAccountIdHex ?? row.groupIdHex,
                directPeerAccountIdHex: row.directPeerAccountIdHex, pictureURL: nil,
                unreadCount: 0, isDirect: row.directPeerAccountIdHex != nil,
                isBlockedDirectPeer: row.directPeerAccountIdHex.map(isBlocked) ?? false,
                hasAuthoritativeConversationKind: true
            )
        }
    }

    struct AutomaticChatListSection: View {
        let model: AccountChatListViewModel?
        let searchText: String
        let excludedGroupIds: Set<String>
        let select: (String) -> Void
        var isCollapsed = false
        var selectedGroupId: String?
        var activeAccountIdHex: String?
        var senderName: (String) -> String? = { _ in nil }
        var isBlocked: (String) -> Bool = { _ in false }
        var title: (PairedChatSummaryFfi) -> String = {
            PairedChatDisplayTitle.resolve(
                name: $0.name, directPeerAccountIdHex: $0.directPeerAccountIdHex, peerDisplayName: nil)
        }

        private var rows: [PairedChatSummaryFfi] {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return (model?.pairedRows ?? []).filter { row in
                !excludedGroupIds.contains(row.groupIdHex)
                    && (query.isEmpty
                        || title(row).localizedStandardContains(query))
            }
        }

        var body: some View {
            ForEach(rows, id: \.groupIdHex) { row in
                Button {
                    select(row.groupIdHex)
                } label: {
                    let display = PairedChatSidebarPresentation.item(
                        row, title: title(row), activeAccountIdHex: activeAccountIdHex,
                        senderName: senderName, isBlocked: isBlocked)
                    if isCollapsed {
                        CollapsedChatRowContent(chat: display, isSelected: selectedGroupId == row.groupIdHex)
                    } else {
                        ChatRowContent(chat: display, isSelected: selectedGroupId == row.groupIdHex)
                    }
                }
                .buttonStyle(.plain)
            }
            if model?.hasPreviousPairedPage == true || model?.snapshot?.nextPairedGroupIdHex != nil {
                HStack {
                    if model?.hasPreviousPairedPage == true {
                        Button(L10n.string("Back")) { Task { await model?.loadPreviousPaired() } }
                    }
                    Spacer()
                    if model?.snapshot?.nextPairedGroupIdHex != nil {
                        Button(L10n.string("Next")) { Task { await model?.loadMorePaired() } }
                    }
                }
            }
            if model?.snapshot?.nextPairedGroupIdHex != nil {
                Color.clear
                    .frame(height: 1)
                    .onScrollVisibilityChange(threshold: 1) { visible in
                        Task { await model?.pairedBoundaryVisibilityChanged(visible) }
                    }
                    .onDisappear {
                        Task { await model?.pairedBoundaryVisibilityChanged(false) }
                    }
            }
        }
    }

    #Preview {
        AutomaticChatListSection(model: nil, searchText: "", excludedGroupIds: [], select: { _ in })
    }
#endif
