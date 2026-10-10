import AppKit
import MarmotKit
import SwiftUI
import XCTest

@testable import whitenoise_mac

@MainActor final class AddProfileRoutingTests: XCTestCase {
    func testAddProfileKeepsWelcomeRouteWithExistingReadyAccount() async throws {
        try await checkHostedRoute(initiallyReady: true)
    }

    func testUnfinishedSetupCompletesThenAllowsAnotherProfile() async throws {
        try await checkHostedRoute(initiallyReady: false)
    }

    private func checkHostedRoute(initiallyReady: Bool) async throws {
        let account = AccountSummaryFfi(
            label: "Routing fixture", accountIdHex: String(repeating: "ab", count: 32),
            localSigning: true, externalSigning: false, signedOut: false, running: true)
        let runtime = FakeMarmotRuntime(accounts: [account])
        runtime.onboardingState = OnboardingSnapshotFfi(
            accountIdHex: account.accountIdHex, recoveryEpoch: nil, revision: 4, ready: initiallyReady,
            steps: [], proposal: nil, singleDeviceNotice: nil, cancellationPending: false)
        let priorSelection = UserDefaults.standard.object(forKey: WorkspaceState.activeAccountKey)
        defer {
            if let priorSelection {
                UserDefaults.standard.set(priorSelection, forKey: WorkspaceState.activeAccountKey)
            } else {
                UserDefaults.standard.removeObject(forKey: WorkspaceState.activeAccountKey)
            }
        }
        let workspace = WorkspaceState(clientFactory: { runtime })
        await workspace.bootstrap()
        let session = SessionState()
        await session.activate(account: workspace.activeAccount, runtime: runtime, connectivityAvailable: true)
        let originalScope = try XCTUnwrap(session.accountScope)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while originalScope.onboarding.snapshot == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(originalScope.onboarding.isDurablyReady, initiallyReady)
        let host = NSHostingView(
            rootView: AnyView(
                MessengerShellView().environment(workspace).environment(session)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 750),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            host.rootView = AnyView(EmptyView())
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
        try await Task.sleep(for: .milliseconds(100))
        workspace.showAccountOnboarding()
        try await Task.sleep(for: .milliseconds(300))
        if !initiallyReady {
            XCTAssertEqual(workspace.phase, .onboarding)
            XCTAssertTrue(originalScope.onboarding.hasUnfinishedSetup)
            runtime.onboardingState?.ready = true
            await originalScope.onboarding.run()
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(workspace.phase, .ready)
            workspace.showAccountOnboarding()
            try await Task.sleep(for: .milliseconds(300))
        }
        XCTAssertEqual(workspace.phase, .onboarding, "Existing ready projection must not dismiss Add Profile")
        XCTAssertEqual(workspace.authenticationMode, .landing)
        XCTAssertEqual(workspace.activeAccount?.id, originalScope.account.id)
        XCTAssertTrue(session.accountScope === originalScope)
        XCTAssertFalse(originalScope.isCancelled)
        await session.deactivate()
    }
}
