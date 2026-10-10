import Foundation
import MarmotKit

/// Source-attested logical history, separate from authenticated live timeline rows.
nonisolated struct SynchronizedHistoryRecord: Sendable, Identifiable, CustomDebugStringConvertible {
    let id: String
    let authorPubkey: String
    let createdAt: UInt64
    let expiresAt: UInt64?
    let deleted: Bool
    let content: String
    let tags: [MessageTagFfi]
    let mediaAttachments: [MediaAttachmentOutcomeFfi]
    let transferId: Data
    let sourceDevice: Data
    let manifestDigest: Data

    var debugDescription: String { "SynchronizedHistoryRecord(redacted)" }
}

/// The cursor is a local read observation, never a transfer or download grant.
nonisolated struct SynchronizedHistoryPage: Sendable {
    let records: [SynchronizedHistoryRecord]
    let nextMessageId: String?
}
