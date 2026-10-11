#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Compression
    import CoreImage
    import Foundation
    import MarmotKit
    import SwiftUI
    import Testing
    @testable import whitenoise_mac

    @MainActor struct PairingQRCodeTests {
        private actor Gate {
            private var entered = false
            private var entry: CheckedContinuation<Void, Never>?
            private var release: CheckedContinuation<Void, Never>?
            func pause() async {
                await withCheckedContinuation { continuation in
                    release = continuation
                    entered = true
                    entry?.resume()
                    entry = nil
                }
            }
            func waitUntilEntered() async {
                if entered { return }
                await withCheckedContinuation { entry = $0 }
            }
            func resume() {
                release?.resume()
                release = nil
            }
        }
        @Test func purposeTaggedQRPreservesExactOpaqueBytes() throws {
            let bytes = Data((0..<256).map(UInt8.init))
            let payload = try PairingQRCode.encode(bytes)
            #expect(payload.hasPrefix("whitenoise-pairing:v1:"))
            #expect(try PairingQRCode.decode(payload) == bytes.base64EncodedString())
        }
        @Test func foreignPurposeMalformedAndNoncanonicalPacketsAreRefused() {
            for value in [
                "nostr:AA==", "AA==", "whitenoise-pairing:v2:AA==",
                "whitenoise-pairing:v1:", "whitenoise-pairing:v1:AB==",
                "whitenoise-pairing:v1:AA==\n",
            ] {
                #expect(throws: PairingQRCode.Failure.self) { try PairingQRCode.decode(value) }
            }
        }
        @Test func qrBoundRefusesOversizeWithoutTruncation() throws {
            let capacity = (PairingQRCode.maximumTextBytes - PairingQRCode.prefix.utf8.count) / 4 * 3
            let bytes = Data(repeating: 7, count: capacity)
            #expect(try PairingQRCode.decode(PairingQRCode.encode(bytes)) == bytes.base64EncodedString())
            #expect(throws: PairingQRCode.Failure.tooLarge) {
                try PairingQRCode.encode(Data(repeating: 7, count: PairingQRCode.maximumPacketBytes + 1))
            }
            #expect(throws: PairingQRCode.Failure.tooLarge) {
                try PairingQRCode.decode(String(repeating: "a", count: 2201))
            }
        }
        @Test func realCoreImageQRDecodesExactPurposeTaggedPacketInBothAppearances() throws {
            let bytes = Data(repeating: 9, count: 128)
            let payload = try PairingQRCode.encode(bytes)
            for scheme in [ColorScheme.light, .dark] {
                let image = try #require(QRCodeImageView.ciImage(for: payload, palette: .resolved(for: scheme)))
                let data = try #require(
                    CIContext().pngRepresentation(
                        of: image, format: .RGBA8,
                        colorSpace: CGColorSpaceCreateDeviceRGB()))
                #expect(try PairingQRCode.readImage(data) == bytes.base64EncodedString())
            }
        }
        @Test func realSetupSizedPacketCompressesAndScansWithoutChangingNativeBytes() throws {
            let bytes = Data((0..<2016).map { UInt8(truncatingIfNeeded: $0 * 73 + 19) })
            let payload = try PairingQRCode.encode(bytes)
            #expect(payload.hasPrefix(PairingQRCode.compressedPrefix))
            #expect(payload.utf8.count <= PairingQRCode.maximumTextBytes)
            let image = try #require(QRCodeImageView.ciImage(for: payload, palette: .resolved(for: .light)))
            let data = try #require(
                CIContext().pngRepresentation(
                    of: image, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()))
            #expect(try PairingQRCode.readImage(data) == bytes.base64EncodedString())
        }
        @Test func compressedInputRefusesMalformedAndExpansionOverNativeBound() throws {
            #expect(throws: PairingQRCode.Failure.self) {
                try PairingQRCode.decode(PairingQRCode.compressedPrefix + "AQID")
            }
            let bytes = Data(repeating: 7, count: PairingQRCode.maximumPacketBytes)
            #expect(try PairingQRCode.decode(PairingQRCode.encode(bytes)) == bytes.base64EncodedString())
            // A valid deflate stream expanding one byte beyond the resource bound.
            let oversized = Data(repeating: 7, count: PairingQRCode.maximumPacketBytes + 1)
            var compressed = [UInt8](repeating: 0, count: 1000)
            let size = oversized.withUnsafeBytes { source in
                compression_encode_buffer(
                    &compressed, compressed.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, oversized.count, nil, COMPRESSION_ZLIB)
            }
            #expect(size > 0)
            #expect(throws: PairingQRCode.Failure.self) {
                try PairingQRCode.decode(
                    PairingQRCode.compressedPrefix + Data(compressed.prefix(size)).base64EncodedString())
            }
        }
        @Test func unreadableAndOversizeImagesAreRefused() {
            #expect(throws: PairingQRCode.Failure.self) { try PairingQRCode.readImage(Data([1, 2, 3])) }
            #expect(throws: PairingQRCode.Failure.tooLarge) {
                try PairingQRCode.readImage(Data(repeating: 0, count: PairingQRCode.maximumImageBytes + 1))
            }
        }
        @Test func selectedFileReadIsBoundedAndPreservesExactImageBytes() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("synthetic.png")
            let bytes = Data([1, 2, 3])
            try bytes.write(to: file)
            #expect(try PairingQRCode.imageData(at: file) == bytes)
            try Data(repeating: 0, count: PairingQRCode.maximumImageBytes + 1).write(to: file)
            #expect(throws: PairingQRCode.Failure.tooLarge) { try PairingQRCode.imageData(at: file) }
            #expect(throws: PairingQRCode.Failure.unreadableImage) { try PairingQRCode.imageData(at: root) }
        }
        @Test func realForeignPurposeQRDoesNotStageInput() throws {
            let image = try #require(QRCodeImageView.ciImage(for: "nostr:npub-public", palette: .resolved(for: .light)))
            let data = try #require(
                CIContext().pngRepresentation(
                    of: image, format: .RGBA8,
                    colorSpace: CGColorSpaceCreateDeviceRGB()))
            #expect(throws: PairingQRCode.Failure.invalidPacket) { try PairingQRCode.readImage(data) }
        }
        @Test func multipleRealQRCodesAreRefusedRatherThanImplicitlySelected() throws {
            let first = try #require(
                QRCodeImageView.ciImage(
                    for: PairingQRCode.encode(Data([1])),
                    palette: .resolved(for: .light)))
            let second = try #require(
                QRCodeImageView.ciImage(
                    for: PairingQRCode.encode(Data([2])),
                    palette: .resolved(for: .light)))
            let combined = first.composited(
                over: second.transformed(
                    by: .init(
                        translationX: first.extent.width + 24,
                        y: 0)))
            let data = try #require(
                CIContext().pngRepresentation(
                    of: combined, format: .RGBA8,
                    colorSpace: CGColorSpaceCreateDeviceRGB()))
            #expect(throws: PairingQRCode.Failure.invalidPacket) { try PairingQRCode.readImage(data) }
        }
        @Test func cancelledImageImportCannotRepopulateInput() async throws {
            let gate = Gate()
            let model = PairingQRImportModel(
                capture: { { true } },
                decode: { _ in
                    await gate.pause()
                    return "AQ=="
                })
            let ticket = model.beginImport()
            let pending = Task { try await model.importImage(Data([1]), ticket: ticket) }
            await gate.waitUntilEntered()
            model.cancel()
            await gate.resume()
            await #expect(throws: PairingQRCode.Failure.invalidPacket) { try await pending.value }
            #expect(model.stagedPacket == nil)
        }
        @Test func accountOwnerRetirementRefusesDelayedImageImport() async throws {
            let gate = Gate()
            let owner = DeviceVerificationViewModel(
                begin: { throw MarmotKitError.DeviceLinkingClosed }, cancel: {},
                verificationSupported: true)
            let model = PairingQRImportModel(
                capture: { { owner.isActive } },
                decode: { _ in
                    await gate.pause()
                    return "AQ=="
                })
            let pending = Task { try await model.importImage(Data([1]), ticket: model.beginImport()) }
            await gate.waitUntilEntered()
            owner.invalidate()
            await gate.resume()
            await #expect(throws: PairingQRCode.Failure.invalidPacket) { try await pending.value }
            #expect(model.stagedPacket == nil && owner.owner == nil)
        }
    }
#endif
