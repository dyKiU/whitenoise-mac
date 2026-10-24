import Foundation
import Testing

@testable import whitenoise_mac

#if WN_EXPERIMENTAL_DEVICE_SYNC
    @MainActor @Suite struct PairingCameraScanModelTests {
        @Test(arguments: ["WNPAIR1:", "WNPAIR2:"])
        func onlyOneBoundedBootstrapIsStagedAndNeverAProfileOrVerifierPacket(_ bootstrapPrefix: String) throws {
            var packets: [String] = []
            let model = PairingCameraScanModel(isCurrent: { true }, onScan: { packets.append($0) })
            model.receive("nostr:npub1profile")
            model.receive(try PairingQRCode.encode(Data([1, 2, 3])))
            #expect(packets.isEmpty && model.canScan)
            let bootstrap = Data((bootstrapPrefix + "synthetic-bootstrap").utf8)
            let payload = try PairingQRCode.encode(bootstrap)
            model.receive(payload)
            model.receive(payload)
            #expect(packets == [bootstrap.base64EncodedString()])
            #expect(!model.canScan)
            #expect(
                PairingCameraScanModel.bootstrap(from: try PairingQRCode.encode(Data(repeating: 1, count: 1025))) == nil
            )
        }
        @Test func dismissalAndRetiredAccountRejectLateCameraCallbacks() throws {
            let current = MainActorTestFlag(true)
            var packets: [String] = []
            let payload = try PairingQRCode.encode(Data("WNPAIR1:synthetic-bootstrap".utf8))
            let model = PairingCameraScanModel(isCurrent: { current.value }, onScan: { packets.append($0) })
            current.value = false
            model.receive(payload)
            #expect(packets.isEmpty)
            current.value = true
            model.close()
            model.receive(payload)
            model.fail()
            #expect(packets.isEmpty && !model.canScan)
            #expect(!model.failed)
        }
        @Test func cameraFailureRejectsLaterCaptureUntilAnotherScanIsStarted() throws {
            var packets: [String] = []
            let model = PairingCameraScanModel(isCurrent: { true }, onScan: { packets.append($0) })
            model.fail()
            model.receive(try PairingQRCode.encode(Data("WNPAIR1:synthetic-bootstrap".utf8)))
            #expect(model.failed && !model.canScan && packets.isEmpty)
        }
    }
#endif
