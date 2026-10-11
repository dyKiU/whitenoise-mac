import MarmotKit

#if WN_EXPERIMENTAL_DEVICE_SYNC
    extension TranscriptRow {
        static func withPairedObservations(
            ordinary: [TranscriptRow], paired: [PairedChatMessageFfi], blockedAuthors: Set<String>, now: UInt64
        ) -> [TranscriptRow] {
            let messages = ordinary.compactMap { row -> (TimelineMessageDisplayItem, Bool, TranscriptRowContext)? in
                if case .message(let item, let divider, let context) = row { return (item, divider, context) }
                return nil
            }
            let context =
                messages.first?.2
                ?? TranscriptRowContext(
                    canVoteInPolls: false, showsDebugMetadata: false, isSelectionMode: false,
                    localeIdentifier: "", referenceDay: 0)
            let positions = SourceQualifiedTimelineUnion.rows(
                ordinary: messages.map { item, _, _ in
                    .init(
                        canonicalId: item.message.sourceMessageIdHex ?? item.message.id,
                        timestamp: item.message.timelineAt)
                },
                paired: paired.map { row in
                    .init(
                        canonicalId: row.messageIdHex, timestamp: row.createdAt, expiresAt: row.expiresAt,
                        visible: !blockedAuthors.contains(row.authorHex.lowercased()))
                }, now: now)
            let merged: [TranscriptRow] = positions.map { position in
                switch position {
                case .ordinary(let index):
                    let (item, divider, context) = messages[index]
                    return .message(item, showsUnreadDivider: divider, context: context)
                case .paired(let index, _): return .pairedSource(paired[index], context: context)
                }
            }
            let prefix = ordinary.filter {
                if case .loadingOlder = $0 { return true }
                return false
            }
            let suffix = ordinary.filter {
                switch $0 {
                case .message, .loadingOlder, .pairedSource: false
                default: true
                }
            }
            return prefix + merged + suffix
        }
    }
#endif
