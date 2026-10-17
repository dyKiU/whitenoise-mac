#if WN_EXPERIMENTAL_DEVICE_SYNC
    import MarmotKit
    import SwiftUI

    /// Review metadata stays on the original account-owned approval; display never grants consent.
    struct DeviceEnrollmentApprovalView: View {
        let model: DeviceEnrollmentApprovalViewModel?
        @State private var task: Task<Void, Never>?
        @State private var readFailed = false

        init(model: DeviceEnrollmentApprovalViewModel?) {
            self.model = model
        }

        var body: some View {
            Group {
                if let model {
                    SettingsSection(title: String(localized: "Review enrollment")) {
                        if let review = model.reviewDisplay {
                            EnrollmentReviewKeyView(
                                title: String(localized: "Source device key"), key: review.sourceKey)
                            EnrollmentReviewKeyView(
                                title: String(localized: "Joining device key"), key: review.joiningKey)
                            Text("Existing devices")
                            Text(String(review.existingDeviceCount))
                            Text(
                                "Pairing shares all existing and future chats, chat history, and messaging between these devices."
                            )
                            Button("Approve pairing and share all chats") {
                                perform(.approveAndShareChats, revision: review.revision)
                            }
                            .disabled(model.isWorking)
                        } else if model.isActive, model.snapshot?.phase == .approvedAwaitingPacket {
                            ProgressView(L10n.string("Waiting"))
                        } else if model.isActive, model.snapshot?.phase == .awaitingSettlement {
                            Text("Waiting")
                        } else if model.isActive, model.snapshot?.phase == .settled {
                            Text("Done")
                        } else if model.isActive {
                            Button("Try again") { refreshReview() }.disabled(model.isWorking)
                        }
                        if readFailed || model.actionError != nil || model.cleanupError != nil {
                            Text("Enrollment action failed. Retry or cancel.").foregroundStyle(.red)
                        }
                        Button(L10n.string(model.cleanupError == nil ? "Cancel" : "Try again")) {
                            task?.cancel()
                            task = Task { try? await model.cancel() }
                        }
                    }
                    .padding()
                } else {
                    Text("Verification complete. Enrollment remains unavailable.")
                }
            }
            .task {
                refreshReview()
                while !Task.isCancelled, model?.isActive == true {
                    do {
                        try await Task.sleep(for: .milliseconds(500))
                        if let model, !model.isWorking {
                            try await model.refresh()
                            if model.snapshot?.phase == .awaitingApproval, model.reviewDisplay == nil {
                                try await model.refreshForDisplay()
                            }
                            readFailed = false
                        }
                    } catch is CancellationError { return } catch { if !Task.isCancelled { readFailed = true } }
                }
            }
            .onDisappear {
                task?.cancel()
            }
            .onChange(of: model?.isActive) { _, active in
                if active != true { task?.cancel() }
            }
        }

        private func refreshReview() {
            guard let model, model.isActive, !model.isWorking else { return }
            readFailed = false
            task?.cancel()
            task = Task {
                do { try await model.refreshForDisplay() } catch {
                    if !Task.isCancelled, model.isActive { readFailed = true }
                }
            }
        }
        private func perform(_ action: DeviceEnrollmentApprovalViewModel.ReviewAction, revision: UInt64) {
            guard let model, model.isActive, !model.isWorking else { return }
            task = Task {
                do {
                    try await model.performReviewAction(action, displayedRevision: revision)
                } catch {
                    // The original model retains the typed error for retry or exact cleanup.
                }
            }
        }
    }

    private struct EnrollmentReviewKeyView: View {
        let title: String
        let key: String
        var body: some View {
            Text(title)
            Text(key).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            CopyToClipboardButton(value: key, actionDescription: L10n.string("Copy")) { _ in Text("Copy") }
        }
    }
    #Preview { DeviceEnrollmentApprovalView(model: nil) }
    #Preview("Reviewed key display") {
        EnrollmentReviewKeyView(title: String(localized: "Source device key"), key: String(repeating: "01", count: 32))
    }
#endif
