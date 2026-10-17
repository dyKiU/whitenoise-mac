#if WN_EXPERIMENTAL_DEVICE_SYNC
    import MarmotKit
    import SwiftUI

    struct HistoryConsentReviewEntryView: View {
        let acquire: @MainActor () throws -> HistoryConsentReviewViewModel
        @State private var presented: HistoryConsentReviewViewModel?
        @State private var failed = false

        init(acquire: @escaping @MainActor () throws -> HistoryConsentReviewViewModel) {
            self.acquire = acquire
        }

        var body: some View {
            SettingsSection(title: L10n.string("History transfer")) {
                Button("Review incoming history") {
                    do {
                        presented = try acquire()
                        failed = false
                    } catch { failed = true }
                }
                .buttonStyle(.wnSecondary)
                .accessibilityIdentifier("history.review.open")
                if failed {
                    Text("History request unavailable. Retry or cancel.").foregroundStyle(.red)
                }
            }
            .sheet(isPresented: Binding(get: { presented != nil }, set: { if !$0 { presented = nil } })) {
                if let presented { HistoryConsentReviewView(model: presented) }
            }
        }
    }

    struct HistoryConsentReviewView: View {
        let model: HistoryConsentReviewViewModel
        @Environment(\.dismiss) private var dismiss
        @State private var action: Task<Void, Never>?
        @State private var failed = false

        init(model: HistoryConsentReviewViewModel) { self.model = model }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Review incoming history").font(.title2)
                    Spacer()
                    Button("Close") { dismiss() }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if model.isActive {
                            if model.requests.isEmpty, !model.isWorking, !failed {
                                Text("No pending history requests.").foregroundStyle(.secondary)
                            }
                            ForEach(model.requests, id: \.id) { request in
                                HistoryConsentRequestRow(request: request) {
                                    perform { try await model.select(id: request.id) }
                                }
                                .disabled(model.isWorking || action != nil || !request.isActive)
                            }
                            if let review = model.review {
                                HistoryConsentReviewDetails(review: review)
                                HStack {
                                    Button("Approve") {
                                        // Approve the revision rendered here, never a newer snapshot.
                                        perform { try await model.approve(displayedRevision: review.revision) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(model.isWorking || action != nil || review.complete)
                                    .accessibilityIdentifier("history.review.approve")
                                    Button("Cancel") {
                                        action?.cancel()
                                        model.cancelSelected()
                                    }
                                    .accessibilityIdentifier("history.review.cancel")
                                }
                            }
                            if failed {
                                Text("History request unavailable. Retry or cancel.").foregroundStyle(.red)
                            }
                        } else {
                            Text("History request unavailable. Retry or cancel.")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Refresh") { perform { try await model.loadPending() } }
                        .disabled(!model.isActive || model.isWorking || action != nil)
                    if model.isWorking { ProgressView().controlSize(.small) }
                }
            }
            .padding(20)
            .frame(minWidth: 620, minHeight: 520)
            .task { perform { try await model.loadPending() } }
            .onDisappear { action?.cancel() }
            .onChange(of: model.isActive) { _, active in if !active { action?.cancel() } }
        }

        private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
            guard model.isActive, !model.isWorking, action == nil else { return }
            failed = false
            action = Task {
                defer { action = nil }
                do { try await operation() } catch {
                    if model.isActive, !Task.isCancelled { failed = true }
                }
            }
        }
    }

    private struct HistoryConsentRequestRow: View {
        let request: any HistoryConsentReviewing
        let select: () -> Void

        var body: some View {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 6) {
                    if let review = request.snapshot {
                        Text("Source device key").font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: HistoryConsentReviewDetails.fingerprint(review.sourceDevice))
                            .font(.caption.monospaced())
                        LabeledContent("Records", value: review.recordCount.formatted())
                    } else {
                        Text("History request unavailable. Retry or cancel.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("history.review.request")
        }
    }

    struct HistoryConsentReviewDetails: View {
        let review: HistoryTransferSnapshotFfi

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HistoryConsentDeviceKeyView(title: "Source device key", value: review.sourceDevice)
                HistoryConsentDeviceKeyView(title: "Receiving device key", value: review.recipientDevice)
                LabeledContent("Chat ID") { Text(verbatim: review.groupIdHex).font(.caption.monospaced()) }
                LabeledContent("Snapshot through") {
                    if review.snapshotTimestampCeiling <= UInt64(Date.distantFuture.timeIntervalSince1970) {
                        Text(
                            Date(timeIntervalSince1970: TimeInterval(review.snapshotTimestampCeiling)),
                            format: .dateTime.year().month().day().hour().minute())
                    } else {
                        Text(verbatim: review.snapshotTimestampCeiling.formatted())
                    }
                }
                LabeledContent("Records", value: review.recordCount.formatted())
                LabeledContent("Imported records", value: review.importedRecords.formatted())
                LabeledContent(
                    "Size",
                    value: ByteCountFormatter.string(fromByteCount: Int64(review.encodedBytes), countStyle: .file))
                Text(
                    "These records are attested by the source device and are separate from live authenticated messages."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
        }

        static func fingerprint(_ key: Data) -> String {
            key.enumerated().map { index, byte in
                (index > 0 && index % 4 == 0 ? " " : "") + String(format: "%02x", byte)
            }.joined()
        }
    }

    private struct HistoryConsentDeviceKeyView: View {
        let title: LocalizedStringKey
        let value: Data
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(verbatim: HistoryConsentReviewDetails.fingerprint(value))
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
        }
    }

    #Preview("History entry") {
        HistoryConsentReviewEntryView { .init(load: { [] }) }
    }

    #Preview("Incoming history") {
        HistoryConsentReviewView(model: .init(load: { [] }))
    }

    #Preview("History review") {
        HistoryConsentReviewDetails(
            review: .init(
                revision: 1, importedRecords: 0, complete: false, groupIdHex: "0102",
                sourceDevice: Data(repeating: 1, count: 32), recipientDevice: Data(repeating: 2, count: 32),
                snapshotTimestampCeiling: 1_760_000_000, recordCount: 3, encodedBytes: 8192, fragmentCount: 2)
        )
        .padding().frame(width: 580)
    }

    #Preview("Device key") {
        HistoryConsentDeviceKeyView(title: "Source device key", value: Data(repeating: 1, count: 32))
    }

    #Preview("Request row") {
        // Empty preview exercises unavailable display without minting an SDK consent.
        HistoryConsentRequestRow(request: PreviewHistoryConsentReview(), select: {})
    }

    @MainActor private final class PreviewHistoryConsentReview: HistoryConsentReviewing {
        let id = UUID()
        let isActive = false
        let snapshot: HistoryTransferSnapshotFfi? = nil
        func refresh() async throws { throw MarmotKitError.HistoryTransferUnsupported }
        func approveReview(displayedRevision: UInt64) async throws { throw MarmotKitError.HistoryTransferUnsupported }
        func cancel() {}
    }
#endif
