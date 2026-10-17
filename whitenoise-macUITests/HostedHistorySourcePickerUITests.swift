import XCTest

@MainActor final class HostedHistorySourcePickerUITests: XCTestCase {
    func testNativeSourceSelectionRequestAndCancelButtons() throws {
        guard let path = ProcessInfo.processInfo.environment["WN_SOURCE_PICKER_BUTTON_BRIDGE"] else {
            throw XCTSkip("Requires the already-running isolated native source pane")
        }
        continueAfterFailure = false
        let bridge = URL(fileURLWithPath: path, isDirectory: true)
        let deadline = Date().addingTimeInterval(90)
        while !FileManager.default.fileExists(atPath: bridge.appendingPathComponent("ready").path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: bridge.appendingPathComponent("ready").path))
        // Attach to the running isolated test host; never launch or terminate the user's app.
        let app = XCUIApplication(bundleIdentifier: "dev.ipf.whitenoise.mac.tests")
        XCTAssertEqual(app.state, .runningForeground)
        let request = app.buttons["history.source.request"]
        XCTAssertTrue(request.waitForExistence(timeout: 10))
        XCTAssertFalse(request.isEnabled)
        let recipient = app.buttons.matching(identifier: "history.source.recipient").firstMatch
        XCTAssertTrue(recipient.waitForExistence(timeout: 10))
        recipient.click()
        XCTAssertTrue(request.isEnabled)
        request.click()
        let review = app.buttons["history.source.continue"]
        XCTAssertTrue(review.waitForExistence(timeout: 15))
        XCTAssertTrue(review.isEnabled)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "native-source-review-after-request-button"
        attachment.lifetime = .keepAlways
        add(attachment)
        let reviewed = bridge.appendingPathComponent("reviewed")
        let reviewDeadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: reviewed.path), Date() < reviewDeadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: reviewed.path))
        app.buttons["history.source.cancel"].click()
    }
}
