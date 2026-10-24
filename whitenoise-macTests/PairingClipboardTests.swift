#if WN_EXPERIMENTAL_DEVICE_SYNC
    import SwiftUI
    import XCTest
    @testable import whitenoise_mac

    @MainActor final class PairingClipboardTests: XCTestCase {
        func testConfiguredWirePacketCopyAllowsPeerTransportAndShowsConfirmation() {
            var copied: [(String, Bool)] = []
            let workspace = WorkspaceState(copyTextHandler: { copied.append(($0, $1)) })
            let packet = Data([1, 2, 3]).base64EncodedString()
            // Exercise the actual component selected by both setup and encrypted outgoing wire packet views.
            let button = DeviceVerificationView.packetCopyButton(packet)
            button.copyValue(using: workspace)
            XCTAssertEqual(copied.count, 1)
            XCTAssertEqual(copied.first?.0, packet)
            XCTAssertEqual(
                copied.first?.1, false, "Intentional pairing wire transport must not discourage Universal Clipboard")
            XCTAssertEqual(DeviceVerificationView.packetCopyLabel(confirming: true), L10n.string("Copied"))
            XCTAssertEqual(DeviceVerificationView.packetCopyLabel(confirming: false), L10n.string("Copy"))
        }
        func testPrivateClipboardDefaultsRemainConcealed() {
            var copied: [(String, Bool)] = []
            let workspace = WorkspaceState(copyTextHandler: { copied.append(($0, $1)) })
            let button = CopyToClipboardButton(value: "private fixture", actionDescription: L10n.string("Copy")) { _ in
                Text("Copy")
            }
            button.copyValue(using: workspace)
            workspace.copyText("private message fixture")
            XCTAssertEqual(copied.count, 2)
            XCTAssertTrue(copied.allSatisfy { $0.1 })
        }
    }
#endif
