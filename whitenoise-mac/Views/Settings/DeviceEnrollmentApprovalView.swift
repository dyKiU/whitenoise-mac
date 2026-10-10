#if WN_EXPERIMENTAL_DEVICE_SYNC
    import MarmotKit
    import SwiftUI

    /// Review metadata stays on the original account-owned approval; display never grants consent.
    struct DeviceEnrollmentApprovalView: View {
        let model: DeviceEnrollmentApprovalViewModel?
        @State private var incoming = ""
        @State private var task: Task<Void, Never>?
        @State private var readFailed = false

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
                            Button("Approve") { perform(.approve, revision: review.revision) }
                                .disabled(model.isWorking)
                        } else if model.isActive, let snapshot = model.snapshot,
                            snapshot.phase == .approvedAwaitingPacket
                        {
                            TextField("Opaque packet from the other device", text: $incoming, axis: .vertical)
                                .lineLimit(2...4)
                            Button("Receive packet") { perform(.receivePacket, revision: snapshot.revision) }
                                .disabled(model.isWorking)
                        } else if model.isActive {
                            Button("Try again") { refreshReview() }.disabled(model.isWorking)
                        }
                        if readFailed || model.actionError != nil || model.cleanupError != nil {
                            Text("Enrollment action failed. Retry or cancel.").foregroundStyle(.red)
                        }
                        Button(L10n.string(model.cleanupError == nil ? "Cancel" : "Try again")) {
                            incoming = ""
                            task?.cancel()
                            task = Task { try? await model.cancel() }
                        }
                    }
                    .padding()
                } else {
                    Text("Verification complete. Enrollment remains unavailable.")
                }
            }
            .task { refreshReview() }
            .onDisappear {
                task?.cancel()
                incoming = ""
            }
            .onChange(of: model?.isActive) { _, active in if active != true { incoming = "" } }
        }

        private func refreshReview() {
            guard let model, model.isActive, !model.isWorking else { return }
            readFailed = false
            task?.cancel()
            task = Task {
                do { try await model.refreshReview() } catch {
                    if !Task.isCancelled, model.isActive { readFailed = true }
                }
            }
        }
        private func perform(_ action: DeviceEnrollmentApprovalViewModel.ReviewAction, revision: UInt64) {
            guard let model, model.isActive, !model.isWorking else { return }
            let packet = incoming
            task = Task {
                do {
                    try await model.performReviewAction(action, displayedRevision: revision, input: packet)
                    if model.isActive, !Task.isCancelled { incoming = "" }
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
