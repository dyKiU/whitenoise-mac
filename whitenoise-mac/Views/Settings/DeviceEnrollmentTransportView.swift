#if WN_EXPERIMENTAL_DEVICE_SYNC
    import MarmotKit
    import SwiftUI

    /// Opaque A/C transport on an already-held original; no approval or packet interpretation.
    struct DeviceEnrollmentTransportView: View {
        let model: DeviceEnrollmentViewModel?
        @State private var action: Task<Void, Never>?

        init(model: DeviceEnrollmentViewModel?) {
            self.model = model
        }

        var body: some View {
            Group {
                if let model {
                    SettingsSection(title: String(localized: "Device enrollment")) {
                        if model.enrollmentSupported, model.isActive,
                            let snapshot = model.snapshot, snapshot.phase == .verificationCompleteEnrollmentPending
                        {
                            Text(
                                "Pairing shares all existing and future chats, chat history, and messaging between these devices."
                            )
                            Button("Pair and share all chats") { perform(.shareChats, revision: snapshot.revision) }
                        }
                        if model.snapshot?.phase == .enrollmentComplete {
                            Text("Done")
                        } else {
                            ProgressView(L10n.string("Waiting"))
                        }
                        if model.transportError != nil || model.cleanupError != nil {
                            Text("Enrollment action failed. Retry or cancel.").foregroundStyle(.red)
                        }
                        Button(L10n.string(model.cleanupError == nil ? "Cancel" : "Try again")) {
                            action?.cancel()
                            action = Task { try? await model.cancel() }
                        }
                    }
                    .padding()
                } else {
                    Text("Verification complete. Enrollment remains unavailable.")
                }
            }
            .onDisappear {
                action?.cancel()
            }
            .onChange(of: model?.isActive) { _, active in
                if active != true { action?.cancel() }
            }
        }

        private func perform(_ operation: DeviceEnrollmentViewModel.TransportAction, revision: UInt64) {
            guard let model, model.isActive, !model.isWorking else { return }
            action = Task {
                do {
                    try await model.performTransportAction(operation, displayedRevision: revision)
                } catch {
                    // The original model retains the typed action or cleanup error.
                }
            }
        }
    }

    #Preview { DeviceEnrollmentTransportView(model: nil) }
#endif
