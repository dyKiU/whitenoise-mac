#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import OSLog
    import SwiftUI

    /// Verification transport with separate original-owner enrollment panes.
    struct DeviceVerificationView: View {
        private static let diagnostics = Logger(subsystem: "dev.ipf.whitenoise.mac", category: "DeviceVerification")
        let model: DeviceVerificationViewModel
        @State private var enrollment: DeviceEnrollmentViewModel?
        @State private var approval: DeviceEnrollmentApprovalViewModel?
        @State private var setup = ""
        @State private var isWorking = false
        @State private var actionFailed = false
        @State private var actionTask: Task<Void, Never>?
        @State private var camera: PairingCameraScanModel?
        init(model: DeviceVerificationViewModel) { self.model = model }

        var body: some View {
            SettingsSection(title: String(localized: "Device verification")) {
                if !model.verificationSupported {
                    Text("Device verification is unavailable in this build.")
                } else {
                    if !model.enrollmentSupported {
                        Text("Verification only. Device enrollment is not available in this build.")
                            .foregroundStyle(.secondary)
                    }
                    if model.enrollmentSupported, !model.targets.isEmpty {
                        Button("Review enrollment") { perform { approval = try await model.enrollmentApproval() } }
                            .disabled(!model.isActive)
                    }
                    if model.owner == nil {
                        Button("Show pairing QR code") {
                            perform {
                                try await model.begin()
                                setup = try model.setupPacket().base64EncodedString()
                            }
                        }
                        .disabled(model.isStarting || isWorking || !model.isActive)
                    }
                    if !setup.isEmpty,
                        model.snapshot?.phase == nil || model.snapshot?.phase == .awaitingSetup
                            || model.snapshot?.phase == .awaitingPeer
                    {
                        PairingQRExportButton(packet: setup, isActive: model.isActive, showOnAppear: true)
                            .id(
                                QRControlIdentity.setup(ObjectIdentifier(model), model.owner.map(ObjectIdentifier.init))
                            )
                    }
                    if model.owner == nil {
                        Button {
                            camera = PairingCameraScanModel(
                                isCurrent: { model.isActive && model.owner == nil && !model.isStarting },
                                onScan: { packet in
                                    guard model.isActive, model.owner == nil, !model.isStarting else { return }
                                    camera = nil
                                    perform { try await model.scanAndSync(request: decodedPacket(packet)) }
                                })
                        } label: {
                            Label("Scan and sync", systemImage: "qrcode.viewfinder")
                        }
                        .disabled(!model.isActive || model.isStarting || isWorking)
                    } else {
                        if let snapshot = model.snapshot, let decimals = snapshot.decimals,
                            snapshot.phase == .comparisonAvailable || snapshot.phase == .awaitingPeerVerification
                        {
                            Text(String(format: "%04d · %04d · %04d", decimals.first, decimals.second, decimals.third))
                                .font(.system(.title2, design: .monospaced))
                            Text("Compare these numbers on both devices before confirming.")
                            Button("The numbers match") {
                                // Capture the snapshot rendered by this button, never a newer revision.
                                perform { try await model.confirm(displayedRevision: snapshot.revision) }
                            }
                            .disabled(snapshot.phase != .comparisonAvailable || isWorking || !model.isActive)
                        }
                        if let snapshot = model.snapshot, snapshot.phase == .verificationCompleteEnrollmentPending {
                            if model.enrollmentSupported {
                                Text(
                                    "Pairing shares all existing and future chats, chat history, and messaging between these devices."
                                )
                                Button {
                                    perform {
                                        let original = try model.enrollmentTransport()
                                        enrollment = original
                                        try await original.performTransportAction(
                                            .shareChats, displayedRevision: snapshot.revision)
                                    }
                                } label: {
                                    if enrollment?.sharingApprovalSubmitted == true {
                                        ProgressView(L10n.string("Waiting"))
                                    } else {
                                        Text("Pair and share all chats")
                                    }
                                }
                                .disabled(isWorking || !model.isActive || enrollment?.sharingApprovalSubmitted == true)
                            } else {
                                Text("Verification complete. Enrollment remains unavailable.")
                            }
                        }

                    }
                    if let snapshot = model.snapshot {
                        if snapshot.phase == .enrollmentComplete {
                            Text("Done")
                        } else if snapshot.phase == .cancelled || snapshot.phase == .expired
                            || snapshot.phase == .failed
                        {
                            Text("Verification action failed. Retry or cancel.").foregroundStyle(.red)
                        } else if snapshot.decimals == nil && snapshot.phase != .verificationCompleteEnrollmentPending {
                            ProgressView(L10n.string("Waiting"))
                        }
                    }
                    if isWorking { ProgressView(L10n.string("Waiting")) }
                    Button(L10n.string("Cancel")) { cancel() }
                        .disabled(!model.isActive)
                    if actionFailed { Text("Verification action failed. Retry or cancel.").foregroundStyle(.red) }
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { camera != nil },
                    set: {
                        if !$0 {
                            camera?.close()
                            camera = nil
                        }
                    })
            ) {
                if let camera { PairingCameraScannerSheet(model: camera) }
            }
            .sheet(isPresented: Binding(get: { approval != nil }, set: { if !$0 { approval = nil } })) {
                if let approval { DeviceEnrollmentApprovalView(model: approval) }
            }
            .task {
                guard model.verificationSupported, model.isActive else { return }
                do {
                    try await model.loadTargets()
                    if model.owner != nil { setup = try model.setupPacket().base64EncodedString() }
                } catch { if model.isActive { actionFailed = true } }
            }
            .onDisappear {
                actionTask?.cancel()
                clearQR()
            }
            .onChange(of: model.isActive) { _, active in
                if !active {
                    enrollment = nil
                    approval = nil
                    setup = ""
                    actionFailed = false
                    clearQR()
                }
            }
            .onChange(of: model.owner.map(ObjectIdentifier.init)) { _, _ in clearQR() }
            .onChange(of: model.snapshot?.phase) { _, phase in
                if phase == .cancelled || phase == .expired || phase == .failed {
                    setup = ""
                    clearQR()
                }
            }
        }

        static func packetCopyButton(_ packet: String) -> CopyToClipboardButton<Text> {
            CopyToClipboardButton(value: packet, actionDescription: L10n.string("Copy"), concealed: false) {
                confirming in
                Text(packetCopyLabel(confirming: confirming))
            }
        }
        static func packetCopyLabel(confirming: Bool) -> String {
            L10n.string(confirming ? "Copied" : "Copy")
        }

        // Roles distinguish sibling controls while ownership changes still retire their local state.
        private enum QRControlIdentity: Hashable {
            case setup(ObjectIdentifier, ObjectIdentifier?)
        }

        private func clearQR() {
            camera?.close()
            camera = nil
        }

        private func decodedPacket(_ packet: String) throws -> Data {
            let encoded = packet.trimmingCharacters(in: .whitespacesAndNewlines)
            // Native resource bound only. The original SDK authenticates the packet and protocol.
            guard encoded.utf8.count <= 65_536, !encoded.isEmpty,
                let bytes = Data(base64Encoded: encoded), bytes.base64EncodedString() == encoded
            else { throw VerificationInputError.invalidPacket }
            guard PairingQRCode.isAutomaticBootstrap(bytes)
            else { throw VerificationInputError.invalidPacket }
            return bytes
        }

        private func cancel() {
            actionTask?.cancel()
            setup = ""
            enrollment = nil
            clearQR()
            actionTask = Task {
                do { try await model.cancel() } catch { if !Task.isCancelled { actionFailed = true } }
            }
        }

        private func perform(_ action: @escaping @MainActor () async throws -> Void) {
            guard !isWorking else { return }
            actionFailed = false
            isWorking = true
            actionTask = Task {
                defer { isWorking = false }
                do { try await action() } catch {
                    if !Task.isCancelled, model.isActive {
                        actionFailed = true
                        let category: DeviceVerificationFailure =
                            error is VerificationInputError ? .invalidPacket : DeviceVerificationFailure(error)
                        Self.diagnostics.error(
                            "Verification action failed category=\(category.rawValue, privacy: .public)")
                    }
                }
            }
        }
    }

    private enum VerificationInputError: Error { case invalidPacket }

    #Preview {
        DeviceVerificationView(
            model: .init(begin: { throw MarmotKitError.DeviceLinkingClosed }, cancel: {}, verificationSupported: true)
        )
        .padding()
        .frame(width: 600)
    }
#endif
