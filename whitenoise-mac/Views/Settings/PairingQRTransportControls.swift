#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import SwiftUI
    import UniformTypeIdentifiers

    struct PairingQRExportButton: View {
        let packet: String
        let isActive: Bool
        var showOnAppear = false
        @State private var pages: [String]?
        @State private var tooLarge = false

        var body: some View {
            Button("Show pairing QR code", action: show)
                .disabled(!isActive)
                .sheet(isPresented: Binding(get: { pages != nil }, set: { if !$0 { pages = nil } })) {
                    if let pages { PairingQRCodeSheet(payloads: pages, close: { self.pages = nil }) }
                }
                .task { if showOnAppear { show() } }
                .onDisappear { pages = nil }
                .onChange(of: isActive) { _, active in if !active { pages = nil } }
                .onChange(of: packet) { _, _ in pages = nil }
            if tooLarge { Text("Packet is too large for QR. Use Copy instead.").foregroundStyle(.secondary) }
        }
        private func show() {
            guard isActive, let bytes = Data(base64Encoded: packet), bytes.base64EncodedString() == packet else {
                return
            }
            do {
                pages = try PairingQRCode.encodePages(bytes)
                tooLarge = false
            } catch { tooLarge = true }
        }
    }

    struct PairingQRImportControl: View {
        let model: PairingQRImportModel
        let isActive: Bool
        @Binding var incoming: String
        @State private var choosingImage = false
        @State private var ticket: UUID?
        @State private var task: Task<Void, Never>?
        @State private var failed = false

        var body: some View {
            Button("Import pairing QR image") {
                incoming = ""
                failed = false
                task?.cancel()
                ticket = model.beginImport()
                choosingImage = true
            }
            .disabled(!isActive)
            if let total = model.totalFrameCount, model.stagedPacket == nil {
                Text("\(model.receivedFrameCount) / \(total)").monospacedDigit()
            }
            if failed || model.didExpire { Text("Try again").foregroundStyle(.secondary) }
            Color.clear.frame(width: 0, height: 0)
                .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.image], allowsMultipleSelection: true)
            { result in
                guard let ticket else { return }
                if case .failure(let error) = result {
                    let cocoa = error as NSError
                    if cocoa.domain == NSCocoaErrorDomain, cocoa.code == NSUserCancelledError {
                        model.cancel()
                        self.ticket = nil
                        return
                    }
                }
                task = Task {
                    do {
                        let urls = try result.get()
                        guard urls.count <= 32 else { throw PairingQRCode.Failure.tooLarge }
                        for url in urls {
                            let access = url.startAccessingSecurityScopedResource()
                            defer { if access { url.stopAccessingSecurityScopedResource() } }
                            let image = try PairingQRCode.imageData(at: url)
                            try await model.importImage(image, ticket: ticket)
                            guard isActive, !Task.isCancelled else { throw PairingQRCode.Failure.invalidPacket }
                            if let value = model.currentStagedPacket {
                                incoming = value
                                break
                            }
                            if model.stagedPacket != nil { throw PairingQRCode.Failure.invalidPacket }
                        }
                        self.ticket = nil
                    } catch {
                        if isActive, !Task.isCancelled { failed = true }
                    }
                }
            }
                .onDisappear { cancel() }
                .onChange(of: isActive) { _, active in if !active { cancel() } }
        }
        private func cancel() {
            task?.cancel()
            task = nil
            choosingImage = false
            ticket = nil
            model.cancel()
        }
    }

    #Preview {
        PairingQRExportButton(packet: "AA==", isActive: true)
    }
    #Preview("Import") {
        PairingQRImportControl(model: .init(capture: { { true } }), isActive: true, incoming: .constant(""))
    }
#endif
