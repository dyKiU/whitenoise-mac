#if WN_EXPERIMENTAL_DEVICE_SYNC
    import AppKit
    @preconcurrency import AVFoundation
    import SwiftUI

    struct PairingCameraScannerSheet: View {
        @Environment(\.dismiss) private var dismiss
        let model: PairingCameraScanModel
        var body: some View {
            VStack(spacing: 16) {
                if model.failed {
                    Text("Verification action failed. Retry or cancel.")
                } else {
                    PairingCameraPreview(model: model).frame(width: 480, height: 320)
                }
                Button(L10n.string("Cancel")) {
                    model.close()
                    dismiss()
                }
            }
            .padding()
            .onDisappear { model.close() }
        }
    }

    private struct PairingCameraPreview: NSViewRepresentable {
        let model: PairingCameraScanModel
        func makeCoordinator() -> PairingCameraCapture {
            PairingCameraCapture(
                onPacket: { [weak model] in model?.receive($0) },
                onFailure: { [weak model] in model?.fail() })
        }
        func makeNSView(context: Context) -> PairingCameraPreviewView {
            let view = PairingCameraPreviewView()
            view.preview.session = context.coordinator.session
            if model.canScan { context.coordinator.start() }
            return view
        }
        func updateNSView(_ view: PairingCameraPreviewView, context: Context) {
            if !model.canScan { context.coordinator.stop() }
        }
        static func dismantleNSView(_ view: PairingCameraPreviewView, coordinator: PairingCameraCapture) {
            coordinator.stop()
            view.preview.session = nil
        }
    }

    private final class PairingCameraPreviewView: NSView {
        let preview = AVCaptureVideoPreviewLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            preview.videoGravity = .resizeAspectFill
            layer?.addSublayer(preview)
        }
        required init?(coder: NSCoder) { return nil }
        override func layout() {
            super.layout()
            preview.frame = bounds
        }
    }

    // AVFoundation callbacks and all mutable capture state are confined to queue.
    // MainActor delivery rechecks the original sheet/account owner independently.
    nonisolated private final class PairingCameraCapture: NSObject, AVCaptureMetadataOutputObjectsDelegate,
        @unchecked Sendable
    {
        let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "dev.ipf.whitenoise.pairing-camera")
        private var closed = false
        private var delivered = false
        private let onPacket: @MainActor @Sendable (String) -> Void
        private let onFailure: @MainActor @Sendable () -> Void
        init(
            onPacket: @escaping @MainActor @Sendable (String) -> Void,
            onFailure: @escaping @MainActor @Sendable () -> Void
        ) {
            self.onPacket = onPacket
            self.onFailure = onFailure
            super.init()
        }
        func start() {
            AVCaptureDevice.requestAccess(for: .video) { [self] granted in
                queue.async { [self] in
                    guard !closed else { return }
                    guard granted, let device = AVCaptureDevice.default(for: .video),
                        let input = try? AVCaptureDeviceInput(device: device)
                    else {
                        fail()
                        return
                    }
                    session.beginConfiguration()
                    let output = AVCaptureMetadataOutput()
                    guard session.canAddInput(input) else {
                        session.commitConfiguration()
                        fail()
                        return
                    }
                    session.addInput(input)
                    guard session.canAddOutput(output) else {
                        session.commitConfiguration()
                        fail()
                        return
                    }
                    session.addOutput(output)
                    guard output.availableMetadataObjectTypes.contains(.qr) else {
                        session.commitConfiguration()
                        fail()
                        return
                    }
                    output.setMetadataObjectsDelegate(self, queue: queue)
                    output.metadataObjectTypes = [.qr]
                    session.commitConfiguration()
                    session.startRunning()
                }
            }
        }
        private func fail() {
            closed = true
            session.stopRunning()
            Task { @MainActor [onFailure] in onFailure() }
        }
        func stop() {
            queue.async { [self] in
                closed = true
                session.stopRunning()
            }
        }
        func metadataOutput(
            _ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !closed, !delivered,
                let payload = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue })
                    .first(where: { PairingCameraScanModel.bootstrap(from: $0) != nil })
            else { return }
            delivered = true
            // Return from the delegate callback before synchronous session shutdown.
            stop()
            Task { @MainActor [onPacket] in onPacket(payload) }
        }
    }

    #Preview {
        PairingCameraScannerSheet(model: .init(isCurrent: { false }, onScan: { _ in }))
    }
#endif
