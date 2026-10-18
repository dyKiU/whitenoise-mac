import MarmotKit
import SwiftUI

#if WN_EXPERIMENTAL_DEVICE_SYNC
    enum PairedChatSidebarPresentation {
        /// Display values only; actions continue to use the original paired conversation owner.
        static func item(_ row: PairedChatSummaryFfi, title: String) -> ChatItem {
            ChatItem(
                id: row.groupIdHex, title: title, subtitle: L10n.string("Shared from a linked device"),
                preview: L10n.string("Shared from a linked device"), updatedAt: nil,
                avatarSeed: row.directPeerAccountIdHex ?? row.groupIdHex, pictureURL: nil,
                unreadCount: 0, isDirect: row.directPeerAccountIdHex != nil,
                directPeerAccountIdHex: row.directPeerAccountIdHex,
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
                    let display = PairedChatSidebarPresentation.item(row, title: title(row))
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
