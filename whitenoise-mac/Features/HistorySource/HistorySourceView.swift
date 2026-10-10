#if WN_EXPERIMENTAL_DEVICE_SYNC
    import MarmotKit
    import SwiftUI

    struct HistorySourceEntryView: View {
        let model: HistorySourceViewModel
        @State private var isPresented = false

        var body: some View {
            HStack {
                Spacer()
                Button("Send chat history", systemImage: "arrow.up.doc") { isPresented = true }
                    .disabled(!model.isActive)
                    .accessibilityIdentifier("history.source.open")
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .sheet(isPresented: $isPresented) { HistorySourceView(model: model) }
        }
    }

    struct HistorySourceView: View {
        let model: HistorySourceViewModel
        @Environment(\.dismiss) private var dismiss
        @State private var action: Task<Void, Never>?
        @State private var failed = false

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Send chat history").font(.title2)
                    Spacer()
                    Button("Close") {
                        action?.cancel()
                        model.cancelTransfer()
                        dismiss()
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if model.isActive {
                            if let review = model.review {
                                HistoryConsentReviewDetails(review: review)
                                Button("Continue") {
                                    perform { try await model.continueTransfer(displayedRevision: review.revision) }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.isWorking || action != nil || review.complete)
                                .accessibilityIdentifier("history.source.continue")
                            } else {
                                Text("Choose a linked device to receive a snapshot of this chat.")
                                if model.recipients.isEmpty, !model.isWorking, !failed {
                                    Text("No eligible receiving devices.").foregroundStyle(.secondary)
                                }
                                ForEach(model.recipients, id: \.device) { recipient in
                                    HistorySourceRecipientRow(
                                        recipient: recipient,
                                        selected: model.selectedDevice == recipient.device,
                                        select: {
                                            do { try model.select(device: recipient.device) } catch { failed = true }
                                        }
                                    )
                                    .disabled(model.isWorking || action != nil)
                                }
                                Button("Request history transfer") { perform { try await model.requestTransfer() } }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(model.selectedDevice == nil || model.isWorking || action != nil)
                                    .accessibilityIdentifier("history.source.request")
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
                    Button("Refresh") {
                        perform {
                            if model.transfer != nil {
                                try await model.refreshTransfer()
                            } else {
                                try await model.loadRecipients()
                            }
                        }
                    }
                    .disabled(!model.isActive || model.isWorking || action != nil)
                    Button("Cancel") {
                        action?.cancel()
                        model.cancelTransfer()
                    }
                    .accessibilityIdentifier("history.source.cancel")
                    if model.isWorking { ProgressView().controlSize(.small) }
                }
            }
            .padding(20)
            .frame(minWidth: 620, minHeight: 520)
            .task { perform { try await model.loadRecipients() } }
            .onDisappear {
                action?.cancel()
                model.cancelTransfer()
            }
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

    struct HistorySourceRecipientRow: View {
        let recipient: HistoryTransferRecipientFfi
        let selected: Bool
        let select: () -> Void

        var body: some View {
            Button(action: select) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Receiving device key").font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: HistoryConsentReviewDetails.fingerprint(recipient.device))
                            .font(.caption.monospaced())
                    }
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").accessibilityLabel("Selected") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("history.source.recipient")
        }
    }

    #Preview("Send history entry") {
        HistorySourceEntryView(
            model: .init(
                groupIdHex: "chat", query: { [] },
                begin: { _ in
                    throw MarmotKitError.HistoryTransferUnsupported
                }))
    }

    #Preview("Send history") {
        HistorySourceView(
            model: .init(
                groupIdHex: "chat",
                query: {
                    [.init(leafIndex: 1, device: Data(repeating: 2, count: 32))]
                }, begin: { _ in throw MarmotKitError.HistoryTransferUnsupported }))
    }

    #Preview("Receiving device") {
        HistorySourceRecipientRow(
            recipient: .init(leafIndex: 1, device: Data(repeating: 2, count: 32)), selected: true, select: {}
        )
        .padding().frame(width: 580)
    }
#endif
