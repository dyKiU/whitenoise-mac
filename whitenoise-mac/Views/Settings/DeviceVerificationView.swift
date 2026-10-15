#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import MarmotKit
    import OSLog
    import SwiftUI
    import UniformTypeIdentifiers

    /// Verification transport with separate original-owner enrollment panes.
    struct DeviceVerificationView: View {
        private static let diagnostics = Logger(subsystem: "dev.ipf.whitenoise.mac", category: "DeviceVerification")
        let model: DeviceVerificationViewModel
        @State private var enrollment: DeviceEnrollmentViewModel?
        @State private var approval: DeviceEnrollmentApprovalViewModel?
        @State private var incoming = ""
        @State private var setup = ""
        @State private var selectedTarget: Data?
        @State private var actionFailed = false
        @State private var actionTask: Task<Void, Never>?
        @State private var camera: PairingCameraScanModel?
        @State private var qrImport: PairingQRImportModel

        init(model: DeviceVerificationViewModel) {
            self.model = model
            _qrImport = State(
                initialValue: PairingQRImportModel(capture: {
                    let owner = model.owner
                    return { model.isActive && model.owner === owner }
                }))
        }

        var body: some View {
            SettingsSection(title: String(localized: "Device verification")) {
                if !model.verificationSupported {
                    Text("Device verification is unavailable in this build.")
                } else {
                    if !model.enrollmentSupported {
                        Text("Verification only. Device enrollment is not available in this build.")
                            .foregroundStyle(.secondary)
                    }
                    if model.enrollmentSupported {
                        Button("Review enrollment") { perform { approval = try await model.enrollmentApproval() } }
                            .disabled(!model.isActive)
                    }
                    if model.owner == nil {
                        Button("Start verification") {
                            perform {
                                try await model.begin()
                                setup = try model.setupPacket().base64EncodedString()
                            }
                        }
                        .disabled(model.isStarting || !model.isActive)
                        if !model.targets.isEmpty {
                            Picker("Existing device group", selection: $selectedTarget) {
                                Text("Choose a target").tag(Optional<Data>.none)
                                ForEach(Array(model.targets.enumerated()), id: \.offset) { index, target in
                                    Text("Target \(index + 1)").tag(Optional(target.selector))
                                }
                            }
                        }
                    }
                    if !setup.isEmpty {
                        PairingQRExportButton(packet: setup, isActive: model.isActive)
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
                                    incoming = packet
                                    camera = nil
                                })
                        } label: {
                            Label(L10n.string("Scan"), systemImage: "qrcode.viewfinder")
                        }
                        .disabled(!model.isActive || model.isStarting)
                        PairingQRImportControl(
                            model: qrImport, isActive: model.isActive && !model.isStarting, incoming: $incoming
                        )
                        .id(QRControlIdentity.incoming(ObjectIdentifier(model), nil))
                    }
                    if model.owner == nil {
                        if model.offersFirstDeviceSetupAttempt {
                            Button("Approve first-device setup") {
                                perform {
                                    try await model.approveFirstDeviceSetup(request: decodedPacket())
                                    setup = try model.setupPacket().base64EncodedString()
                                    incoming = ""
                                }
                            }
                            .disabled(incoming.isEmpty || model.isStarting || !model.isActive)
                        } else if !model.targets.isEmpty {
                            Button("Approve setup") {
                                perform {
                                    guard let selectedTarget else { throw VerificationInputError.invalidPacket }
                                    try await model.approve(request: decodedPacket(), target: selectedTarget)
                                    setup = try model.setupPacket().base64EncodedString()
                                    incoming = ""
                                }
                            }
                            .disabled(incoming.isEmpty || selectedTarget == nil || model.isStarting || !model.isActive)
                        }
                        if !model.hasLoadedTargets && !model.isReadingTargets && actionFailed {
                            Button("Try again") { perform { try await model.loadTargets() } }
                                .disabled(model.isStarting || !model.isActive)
                        }
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
                            .disabled(snapshot.phase != .comparisonAvailable)
                        }
                        if model.snapshot?.phase == .verificationCompleteEnrollmentPending {
                            if model.enrollmentSupported {
                                Button("Device enrollment") { perform { enrollment = try model.enrollmentTransport() } }
                            } else {
                                Text("Verification complete. Enrollment remains unavailable.")
                            }
                        }

                    }
                    if let snapshot = model.snapshot {
                        if snapshot.phase == .enrollmentComplete {
                            Text("Done")
                        } else if snapshot.decimals == nil {
                            ProgressView(L10n.string("Waiting"))
                        }
                    }
                    Button(L10n.string("Cancel")) {
                        perform {
                            setup = ""
                            incoming = ""
                            clearQR()
                            try await model.cancel()
                        }
                    }
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
            .sheet(isPresented: Binding(get: { enrollment != nil }, set: { if !$0 { enrollment = nil } })) {
                if let enrollment { DeviceEnrollmentTransportView(model: enrollment) }
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
                    incoming = ""
                    selectedTarget = nil
                    actionFailed = false
                    clearQR()
                }
            }
            .onChange(of: model.owner.map(ObjectIdentifier.init)) { _, _ in clearQR() }
            .onChange(of: model.snapshot?.phase) { _, phase in
                if phase == .cancelled || phase == .expired || phase == .failed { clearQR() }
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
            case incoming(ObjectIdentifier, ObjectIdentifier?)
        }

        private func clearQR() {
            qrImport.cancel()
            camera?.close()
            camera = nil
        }

        private func decodedPacket() throws -> Data {
            let encoded = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
            // Native resource bound only. The original SDK authenticates the packet and protocol.
            guard encoded.utf8.count <= 65_536, !encoded.isEmpty,
                let bytes = Data(base64Encoded: encoded), bytes.base64EncodedString() == encoded
            else { throw VerificationInputError.invalidPacket }
            guard bytes.count <= 1024, String(data: bytes, encoding: .utf8)?.hasPrefix("WNPAIR1:") == true
            else { throw VerificationInputError.invalidPacket }
            return bytes
        }

        private func perform(_ action: @escaping @MainActor () async throws -> Void) {
            actionTask?.cancel()
            actionFailed = false
            actionTask = Task {
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
