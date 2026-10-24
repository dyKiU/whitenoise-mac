#if WN_EXPERIMENTAL_DEVICE_SYNC
    import Foundation
    import CoreImage
    import MarmotKit
    import SwiftUI
    import Testing
    @testable import whitenoise_mac

    @MainActor @Suite(.serialized) struct PairingQRImportMultipartTests {
        private actor Gate {
            private var entered = false
            private var waiting: CheckedContinuation<Void, Never>?
            private var released: CheckedContinuation<Void, Never>?
            func pause() async {
                await withCheckedContinuation { continuation in
                    released = continuation
                    entered = true
                    waiting?.resume()
                    waiting = nil
                }
            }
            func waitUntilEntered() async {
                if entered { return }
                await withCheckedContinuation { waiting = $0 }
            }
            func resume() {
                released?.resume()
                released = nil
            }
        }

        private static func bytes() -> Data {
            var seed: UInt64 = 0x123_4567_89ab_cdef
            return Data(
                (0..<4678).map { _ in
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    return UInt8(truncatingIfNeeded: seed >> 32)
                })
        }
        private static func model(capture: @escaping PairingQRImportModel.Capture = { { true } })
            -> PairingQRImportModel
        {
            PairingQRImportModel(capture: capture, decode: { String(decoding: $0, as: UTF8.self) })
        }

        @Test func repeatedSelectionsPreservePartialAndDuplicatePagesWithoutStaging() async throws {
            let bytes = Self.bytes()
            let pages = try PairingQRCode.encodePages(bytes)
            #expect(pages.count > 1)
            let model = Self.model()
            try await model.importImage(Data(pages[0].utf8), ticket: model.beginImport())
            #expect(model.stagedPacket == nil && model.receivedFrameCount == 1)
            try await model.importImage(Data(pages[0].utf8), ticket: model.beginImport())
            #expect(model.stagedPacket == nil && model.receivedFrameCount == 1)
            for page in pages.dropFirst().reversed() {
                try await model.importImage(Data(page.utf8), ticket: model.beginImport())
            }
            #expect(model.stagedPacket == bytes.base64EncodedString())
        }

        @Test func oneFileSelectionCanSupplyAllPagesUnderTheSameOwnerTicket() async throws {
            let bytes = Self.bytes()
            let pages = try PairingQRCode.encodePages(bytes)
            let model = Self.model()
            let ticket = model.beginImport()
            for page in pages { try await model.importImage(Data(page.utf8), ticket: ticket) }
            #expect(model.stagedPacket == bytes.base64EncodedString())
        }

        @Test func accountRetirementDropsPartialBeforeTheNextImageSelection() async throws {
            let pages = try PairingQRCode.encodePages(Self.bytes())
            let owner = DeviceVerificationViewModel(
                begin: { throw MarmotKitError.DeviceLinkingClosed }, cancel: {}, verificationSupported: true)
            let model = Self.model(capture: { { owner.isActive } })
            try await model.importImage(Data(pages[0].utf8), ticket: model.beginImport())
            owner.invalidate()
            let ticket = model.beginImport()
            await #expect(throws: PairingQRCode.Failure.invalidPacket) {
                try await model.importImage(Data(pages[1].utf8), ticket: ticket)
            }
            #expect(model.stagedPacket == nil && model.receivedFrameCount == 0 && model.totalFrameCount == nil)
        }

        @Test func cancelledPartialCannotBeRepopulatedByAnAlreadyDecodingImage() async throws {
            let pages = try PairingQRCode.encodePages(Self.bytes())
            let gate = Gate()
            let model = PairingQRImportModel(
                capture: { { true } },
                decode: { data in
                    if data == Data(pages[1].utf8) { await gate.pause() }
                    return String(decoding: data, as: UTF8.self)
                })
            let ticket = model.beginImport()
            try await model.importImage(Data(pages[0].utf8), ticket: ticket)
            let pending = Task { try await model.importImage(Data(pages[1].utf8), ticket: ticket) }
            await gate.waitUntilEntered()
            model.cancel()
            await gate.resume()
            await #expect(throws: PairingQRCode.Failure.invalidPacket) { try await pending.value }
            #expect(model.stagedPacket == nil && model.receivedFrameCount == 0 && model.totalFrameCount == nil)
        }

        @Test func partialImportExpiresWithoutNeedingAnotherCameraOrFileCallback() async throws {
            let pages = try PairingQRCode.encodePages(Self.bytes())
            let model = PairingQRImportModel(
                capture: { { true } }, importLifetime: .milliseconds(10),
                decode: { String(decoding: $0, as: UTF8.self) })
            let ticket = model.beginImport()
            try await model.importImage(Data(pages[0].utf8), ticket: ticket)
            let deadline = ContinuousClock().now.advanced(by: .seconds(2))
            while !model.didExpire && ContinuousClock().now < deadline { await Task.yield() }
            #expect(model.didExpire && model.stagedPacket == nil && model.receivedFrameCount == 0)
            await #expect(throws: PairingQRCode.Failure.invalidPacket) {
                try await model.importImage(Data(pages[1].utf8), ticket: ticket)
            }
        }
        @Test func completedDecodeCannotBeDeliveredAfterItsAccountOwnerRetires() async throws {
            let owner = DeviceVerificationViewModel(
                begin: { throw MarmotKitError.DeviceLinkingClosed }, cancel: {}, verificationSupported: true)
            let model = Self.model(capture: { { owner.isActive } })
            try await model.importImage(Data("AQ==".utf8), ticket: model.beginImport())
            #expect(model.currentStagedPacket == "AQ==")
            owner.invalidate()
            #expect(model.currentStagedPacket == nil)
        }
        @Test func actualRenderedMultipartImagesStageOnlyTheCompletePacket() async throws {
            let bytes = Self.bytes()
            let pages = try PairingQRCode.encodePages(bytes)
            let model = PairingQRImportModel(capture: { { true } })
            let context = CIContext()
            for (index, page) in pages.reversed().enumerated() {
                let image = try #require(QRCodeImageView.ciImage(for: page, palette: .resolved(for: .light)))
                let png = try #require(
                    context.pngRepresentation(
                        of: image, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()))
                try await model.importImage(png, ticket: model.beginImport())
                if index < pages.count - 1 { #expect(model.currentStagedPacket == nil) }
            }
            #expect(model.currentStagedPacket == bytes.base64EncodedString())
        }
    }
#endif
