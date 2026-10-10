import MarmotKit
import SwiftUI

/// Browses committed source-attested history without creating live messages or download grants.
struct SynchronizedHistoryEntryView: View {
    let model: SynchronizedHistoryViewModel
    @State private var isPresented = false

    var body: some View {
        HStack {
            Spacer()
            Button("Synchronized history", systemImage: "clock.arrow.circlepath") {
                isPresented = true
            }
            .disabled(!model.isActive)
            .accessibilityIdentifier("conversation.synchronizedHistory.open")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .sheet(isPresented: $isPresented) {
            SynchronizedHistoryView(model: model)
        }
    }
}

struct SynchronizedHistoryView: View {
    let model: SynchronizedHistoryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Synchronized history").font(.title2)
                Spacer()
                Button("Close") { dismiss() }
            }
            Text("These records are attested by the source device and are separate from live authenticated messages.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if model.readFailed {
                Text("Could not load synchronized history.")
            } else if !model.isLoading && model.records.isEmpty {
                Text("No messages").foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                List(model.records) { record in
                    SynchronizedHistoryRecordView(record: record, referenceDate: context.date)
                }
            }
            .accessibilityIdentifier("conversation.synchronizedHistory.records")
            HStack {
                Button {
                    Task { await model.reload() }
                } label: {
                    if model.readFailed { Text("Retry") } else { Text("Refresh") }
                }
                .disabled(model.isLoading || !model.isActive)
                if model.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Next") { Task { await model.loadNextPage() } }
                    .disabled(model.isLoading || !model.hasMore || !model.isActive || model.readFailed)
            }
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 420)
        .task { await model.reload() }
    }
}

private struct SynchronizedHistoryRecordView: View {
    let record: SynchronizedHistoryRecord
    let referenceDate: Date

    private func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: record.authorPubkey).font(.caption).lineLimit(1)
                Spacer()
                Text(Date(timeIntervalSince1970: Double(record.createdAt)), style: .date)
                    .font(.caption)
            }
            if record.deleted {
                Text("Message deleted").foregroundStyle(.secondary)
            } else if record.expiresAt.map({ Double($0) <= referenceDate.timeIntervalSince1970 }) == true {
                Text("Message expired").foregroundStyle(.secondary)
            } else {
                Text(verbatim: record.content).textSelection(.enabled)
                ForEach(Array(record.mediaAttachments.enumerated()), id: \.offset) { _, attachment in
                    SynchronizedHistoryAttachmentView(attachment: attachment)
                }
            }
            DisclosureGroup("Source provenance") {
                LabeledContent("Source device key") {
                    Text(verbatim: hex(record.sourceDevice)).textSelection(.enabled)
                }
                LabeledContent("History transfer") {
                    Text(verbatim: hex(record.transferId)).textSelection(.enabled)
                }
                LabeledContent("Manifest digest") {
                    Text(verbatim: hex(record.manifestDigest)).textSelection(.enabled)
                }
                Text(verbatim: record.id).textSelection(.enabled)
            }
            .font(.caption)
        }
        .padding(.vertical, 6)
    }
}

private struct SynchronizedHistoryAttachmentView: View {
    let attachment: MediaAttachmentOutcomeFfi

    var body: some View {
        switch attachment {
        case .accepted(_, let reference):
            VStack(alignment: .leading) {
                Label("Attachment", systemImage: "paperclip")
                Text(verbatim: reference.fileName)
                Text("Attachment availability has not been verified on this device.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        case .rejected:
            Label("Attachment unavailable", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    SynchronizedHistoryView(
        model: SynchronizedHistoryViewModel(accountRef: "preview", groupIdHex: "preview") { _, _, _, _ in
            .init(records: [], nextMessageId: nil)
        })
}

#Preview("Entry") {
    SynchronizedHistoryEntryView(
        model: SynchronizedHistoryViewModel(accountRef: "preview", groupIdHex: "preview") { _, _, _, _ in
            .init(records: [], nextMessageId: nil)
        })
}

#Preview("Record") {
    SynchronizedHistoryRecordView(
        record: .init(
            id: String(repeating: "01", count: 32), authorPubkey: String(repeating: "02", count: 32),
            createdAt: 12, expiresAt: nil, deleted: false, content: "Preview history", tags: [],
            mediaAttachments: [], transferId: Data(repeating: 3, count: 32),
            sourceDevice: Data(repeating: 4, count: 32), manifestDigest: Data(repeating: 5, count: 32)),
        referenceDate: .now)
}

#Preview("Attachment") {
    SynchronizedHistoryAttachmentView(
        attachment: .rejected(attachmentIndex: 0, rejection: .init(kind: .unsupportedFormat, detail: "")))
}
