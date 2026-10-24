#if WN_EXPERIMENTAL_DEVICE_SYNC
    import AppKit
    import MarmotKit
    import SwiftUI
    import XCTest

    @testable import whitenoise_mac

    final class HistorySourcePaneTests: XCTestCase {
        @MainActor func testHostedPickerLoadsAccountRecipientsWithoutRequestingTransfer() async throws {
            let scope = AccountScope(account: AccountItem.samples[0], runtime: FakeMarmotRuntime(accounts: []))
            let first = Data(repeating: 2, count: 32)
            var queries = 0
            var requests = 0
            let model = scope.historySourceModel(
                groupIdHex: "synthetic-chat",
                query: { _, _, _ in
                    queries += 1
                    return [
                        .init(leafIndex: 1, device: first), .init(leafIndex: 2, device: Data(repeating: 3, count: 32)),
                    ]
                },
                begin: { _, _, _, _ in
                    requests += 1
                    throw MarmotKitError.HistoryTransferUnsupported
                })
            let host = NSHostingView(
                rootView: AnyView(HistorySourceView(model: model).background(Color(nsColor: .windowBackgroundColor))))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 660),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            window.orderFront(nil)
            defer {
                host.rootView = AnyView(EmptyView())
                window.contentView = nil
                window.orderOut(nil)
                window.close()
            }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while model.recipients.count != 2 || model.isWorking, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(queries, 1)
            XCTAssertEqual(model.recipients.count, 2)
            XCTAssertNil(model.selectedDevice)
            XCTAssertNil(model.transfer)
            XCTAssertEqual(requests, 0)
            try await capture(host: host, window: window, name: "history-source-picker-unselected")
            // Model-driven selection verifies the rendered selected state, not a UI-button press.
            try model.select(device: first)
            try await capture(host: host, window: window, name: "history-source-picker-selected")
            XCTAssertEqual(requests, 0)
            XCTAssertNil(model.transfer)
            await scope.cancelAll()
            XCTAssertFalse(model.isActive)
            XCTAssertTrue(model.recipients.isEmpty)
        }

        @MainActor private func capture(host: NSHostingView<AnyView>, window: NSWindow, name: String) async throws {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(40))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(
                bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 0, 0.95,
                "The hosted capture must include an opaque drawing background")
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
#endif
