#if WN_EXPERIMENTAL_DEVICE_SYNC
    import MarmotKit
    import SwiftUI

    /// Opaque A/C transport on an already-held original; no approval or packet interpretation.
    struct DeviceEnrollmentTransportView: View {
        let model: DeviceEnrollmentViewModel?
        @State private var incoming = ""
        @State private var action: Task<Void, Never>?

        @State private var qrImport: PairingQRImportModel

        init(model: DeviceEnrollmentViewModel?) {
            self.model = model
            _qrImport = State(initialValue: .init(capture: { { model?.isActive == true } }))
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
                            Button("Read outgoing packets") { perform(.exportPacket, revision: snapshot.revision) }
                            if let outgoing = model.outgoingPacket {
                                Text(outgoing).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                CopyToClipboardButton(value: outgoing, actionDescription: L10n.string("Copy")) { _ in
                                    Text("Copy")
                                }
                                PairingQRExportButton(packet: outgoing, isActive: model.isActive && !model.isWorking)
                            }
                            PairingQRImportControl(
                                model: qrImport, isActive: model.isActive && !model.isWorking, incoming: $incoming
                            )
                            .id(ObjectIdentifier(model))
                            TextField("Opaque packet from the other device", text: $incoming, axis: .vertical)
                                .lineLimit(2...4)
                            Button("Receive packet") { perform(.receivePacket, revision: snapshot.revision) }
                            Button("Finalize enrollment") { perform(.finalizeLinking, revision: snapshot.revision) }
                        }
                        if model.transportError != nil || model.cleanupError != nil {
                            Text("Enrollment action failed. Retry or cancel.").foregroundStyle(.red)
                        }
                        Button(L10n.string(model.cleanupError == nil ? "Cancel" : "Try again")) {
                            incoming = ""
                            qrImport.cancel()
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
                incoming = ""
                qrImport.cancel()
            }
            .onChange(of: model?.isActive) { _, active in
                if active != true {
                    incoming = ""
                    qrImport.cancel()
                }
            }
        }

        private func perform(_ operation: DeviceEnrollmentViewModel.TransportAction, revision: UInt64) {
            guard let model, model.isActive, !model.isWorking else { return }
            let input = incoming
            action = Task {
                do {
                    try await model.performTransportAction(operation, displayedRevision: revision, input: input)
                    if model.isActive, !Task.isCancelled, operation == .receivePacket { incoming = "" }
                } catch {
                    // The original model retains the typed action or cleanup error.
                }
            }
        }
    }

    #Preview { DeviceEnrollmentTransportView(model: nil) }
#endif
