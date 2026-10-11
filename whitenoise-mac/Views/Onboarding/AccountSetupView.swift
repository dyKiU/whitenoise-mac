import MarmotKit
import SwiftUI

/// Renders the durable MarmotKit onboarding checkpoint for an imported identity.
/// The snapshot is authoritative: every command operates on its advertised actions and
/// the screen survives termination because no progress is held only in SwiftUI state.
struct AccountSetupView: View {
    let model: OnboardingCoordinator
    @State private var acknowledgesRecoveryRisk = false

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                AccountSetupHeader(snapshot: model.snapshot)

                if let snapshot = model.snapshot {
                    AccountSetupStepList(snapshot: snapshot, model: model)
                }

                if model.recoveryRequired {
                    AccountSetupRecoveryControls(
                        model: model,
                        acknowledgesRisk: $acknowledgesRecoveryRisk
                    )
                }

                if let error = model.error {
                    Text(error)
                        .foregroundStyle(WNColor.intentionErrorContent)
                        .fixedSize(horizontal: false, vertical: true)
                }

                AccountSetupCancellationControls(model: model)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .disabled(model.isBusy)
        .overlay {
            if model.isBusy {
                ProgressView()
                    .controlSize(.large)
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .accessibilityIdentifier("onboarding.account-setup")
    }
}

private struct AccountSetupHeader: View {
    let snapshot: OnboardingSnapshotFfi?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string(snapshot?.ready == true ? "You’re ready" : "Getting you ready"))
                .wnFont(.bold28)
            if snapshot?.ready != true {
                Text(L10n.string("Checking your profile before you start chatting."))
                    .wnFont(.medium16)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
            }
            if snapshot?.cancellationPending == true {
                Text(
                    L10n.string(
                        "Finishing cancellation. Your saved identity and completed changes will be kept."
                    )
                )
                .foregroundStyle(WNColor.backgroundContentSecondary)
            }
        }
    }
}

private struct AccountSetupStepList: View {
    let snapshot: OnboardingSnapshotFfi
    let model: OnboardingCoordinator

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(snapshot.steps.enumerated()), id: \.element.step) { index, step in
                AccountSetupStepRow(step: step, snapshot: snapshot, model: model)
                if index < snapshot.steps.count - 1 {
                    Divider()
                }
            }
        }
        .background(WNColor.fillSecondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct AccountSetupStepRow: View {
    let step: OnboardingStepStateFfi
    let snapshot: OnboardingSnapshotFfi
    let model: OnboardingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AccountSetupStatusIcon(status: step.status)
                VStack(alignment: .leading, spacing: 3) {
                    Text(AccountSetupPresentation.title(step.step))
                        .wnFont(.semiBold14)
                    Text(AccountSetupPresentation.status(step.status))
                        .wnFont(.medium12)
                        .foregroundStyle(WNColor.backgroundContentSecondary)
                }
                Spacer(minLength: 0)
            }

            ForEach(AccountSetupPresentation.findings(step.findings), id: \.self) { finding in
                Text(finding)
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if step.step == .singleDevice, snapshot.ready,
                snapshot.steps.contains(where: { $0.step == .keyPackage && $0.status == .skipped })
            {
                Text(L10n.string("Existing invitation keys stay unchanged. Pair devices to share chats."))
                    .wnFont(.medium12)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AccountSetupStepActions(step: step, snapshot: snapshot, model: model)
        }
        .padding(16)
    }
}

private struct AccountSetupStatusIcon: View {
    let status: OnboardingStatusFfi

    var body: some View {
        Group {
            if status == .checking {
                ProgressView()
            } else {
                Image(systemName: AccountSetupPresentation.symbol(status))
                    .foregroundStyle(AccountSetupPresentation.color(status))
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

private struct AccountSetupStepActions: View {
    let step: OnboardingStepStateFfi
    let snapshot: OnboardingSnapshotFfi
    let model: OnboardingCoordinator

    var body: some View {
        if !step.actions.isEmpty {
            HStack(spacing: 8) {
                if step.actions.contains(.retry) {
                    Button(L10n.string("Try again")) { Task { await model.retry(step.step) } }
                }
                if step.actions.contains(.useRecommendedRelays) {
                    Button(L10n.string("Use Default Relays")) {
                        Task { await model.proposeRecommendedRelays(step: step.step) }
                    }
                }
                if step.actions.contains(.approveRepair) {
                    Button(L10n.string("Continue")) { Task { await model.approveRepair() } }
                }
                if step.actions.contains(.cancelRepair) {
                    Button(L10n.string("Back")) { Task { await model.cancelRepair() } }
                }
                if step.actions.contains(.continueWithout) {
                    Button(L10n.string("Continue")) { Task { await model.skip(step.step) } }
                }
                if step.actions.contains(.continueAnyway), step.step == .singleDevice {
                    Button(L10n.string("Continue anyway")) {
                        Task { await model.acknowledgeSingleDevice() }
                    }
                }
                if step.actions.contains(.editDiscoveryRelays) {
                    AccountSetupDiscoveryRelayButton(model: model)
                }
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct AccountSetupDiscoveryRelayButton: View {
    let model: OnboardingCoordinator
    @State private var isPresented = false

    var body: some View {
        Button(L10n.string("Look on Another Relay")) { isPresented = true }
            .sheet(isPresented: $isPresented) {
                AccountSetupDiscoveryRelaySheet(model: model)
            }
    }
}

private struct AccountSetupDiscoveryRelaySheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: OnboardingCoordinator
    @State private var relay = ""
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string("Find Your Settings"))
                .wnFont(.bold20)
            Text(
                L10n.string(
                    "Choose a relay you’ve used with this profile. We’ll look there for your existing settings without publishing anything."
                )
            )
            .foregroundStyle(WNColor.backgroundContentSecondary)
            .fixedSize(horizontal: false, vertical: true)
            TextField("wss://relay.example.com", text: $relay)
                .textFieldStyle(.roundedBorder)
            if let validationError {
                Text(validationError)
                    .foregroundStyle(WNColor.intentionErrorContent)
            }
            HStack {
                Spacer()
                Button(L10n.string("Cancel")) { dismiss() }
                Button(L10n.string("Look for My Settings")) {
                    let trimmed = relay.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let url = URL(string: trimmed), url.scheme == "wss", url.host != nil else {
                        validationError = L10n.string("Enter a valid relay URL, like wss://relay.example.com.")
                        return
                    }
                    Task {
                        await model.setDiscoveryRelays([trimmed])
                        if model.error == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct AccountSetupRecoveryControls: View {
    let model: OnboardingCoordinator
    @Binding var acknowledgesRisk: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("This profile’s saved sign-in setup needs recovery."))
                .wnFont(.semiBold16)
            Text(
                L10n.string(
                    "Recovery signs this profile out and replaces its unreadable setup checkpoint. Only the latest recovery evidence is retained. It does not undo earlier relay publications. You will need the private key to start a new sign-in; no publication is approved by this action."
                )
            )
            .foregroundStyle(WNColor.backgroundContentSecondary)
            Toggle(L10n.string("Recover Sign-In Setup?"), isOn: $acknowledgesRisk)
            Button(L10n.string("Recover Sign-In Setup")) {
                Task { await model.recover(acknowledgeLatestOnlyEvidence: true) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!acknowledgesRisk)
        }
        .padding(16)
        .background(WNColor.fillSecondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct AccountSetupCancellationControls: View {
    let model: OnboardingCoordinator

    var body: some View {
        Button(L10n.string("Cancel"), role: .destructive) {
            Task { await model.cancel() }
        }
        .disabled(model.snapshot?.cancellationPending == true)
    }
}

private enum AccountSetupPresentation {
    static func title(_ step: OnboardingStepFfi) -> String {
        switch step {
        case .profile: L10n.string("Your profile")
        case .follows: L10n.string("People you follow")
        case .relays: L10n.string("Your relays")
        case .inboxRelays: L10n.string("Message inbox")
        case .singleDevice: L10n.string("Using one device")
        case .keyPackage: L10n.string("Secure messaging")
        }
    }

    static func status(_ status: OnboardingStatusFfi) -> String {
        switch status {
        case .pending: L10n.string("Waiting")
        case .checking: L10n.string("Checking…")
        case .passed: L10n.string("Done")
        case .needsInput: L10n.string("Needs your attention")
        case .retryableFailure: L10n.string("Couldn’t finish this check")
        case .waitingForSigner: L10n.string("Couldn’t access your private key")
        case .skipped: L10n.string("Skipped")
        }
    }

    static func symbol(_ status: OnboardingStatusFfi) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .skipped: "minus.circle"
        case .needsInput, .retryableFailure: "exclamationmark.circle"
        case .waitingForSigner: "key"
        case .checking, .pending: "circle"
        }
    }

    static func color(_ status: OnboardingStatusFfi) -> Color {
        switch status {
        case .passed: WNColor.intentionSuccessContent
        case .needsInput, .retryableFailure, .waitingForSigner: WNColor.intentionWarningContent
        case .pending, .checking, .skipped: WNColor.backgroundContentSecondary
        }
    }

    static func findings(_ findings: [OnboardingFindingFfi]) -> [String] {
        findings.map { finding in
            let endpoint = finding.endpoint.map { "\n\($0.prefix(200))" } ?? ""
            return issue(finding.issue) + endpoint
        }
    }

    static func issue(_ issue: OnboardingIssueFfi) -> String {
        switch issue {
        case .missing: L10n.string("No published settings were found.")
        case .malformed: L10n.string("The published settings could not be read.")
        case .futureDated: L10n.string("The published settings have a future date. Check your device clock and retry.")
        case .invalidRelay: L10n.string("A relay address is invalid.")
        case .retiredRelay: L10n.string("A relay is no longer supported.")
        case .unsafeRelay: L10n.string("A relay address is not safe to connect to.")
        case .unreachable: L10n.string("A relay could not be reached.")
        case .timedOut: L10n.string("A relay did not respond in time. Your existing settings have not been replaced.")
        case .authenticationRequired: L10n.string("A relay requires authentication.")
        case .paymentRequired: L10n.string("A relay requires payment.")
        case .accessRestricted: L10n.string("A relay restricted access.")
        case .noUsableRoute: L10n.string("No usable relay route was found.")
        case .publicationFailed: L10n.string("Publishing did not finish. Retry to continue from the saved progress.")
        case .signerUnavailable: L10n.string("Your signer is unavailable.")
        case .signerRejected: L10n.string("Your signer declined the request.")
        case .recordChanged: L10n.string("The published settings changed. Check again before approving a repair.")
        case .interrupted: L10n.string("This check was interrupted. Your progress is saved.")
        case .tooManyRelays: L10n.string("The relay list is too large.")
        case .multiDeviceUnsupported: L10n.string("Conversations do not sync across devices yet.")
        case .otherInstallationPossible: L10n.string("Another installation may exist.")
        case .discoveryIncomplete: L10n.string("Some discovery sources could not be checked.")
        }
    }
}

#Preview("Account setup") {
    AccountSetupHeader(
        snapshot: OnboardingSnapshotFfi(
            accountIdHex: "preview",
            recoveryEpoch: nil,
            revision: 1,
            ready: false,
            steps: [
                OnboardingStepStateFfi(
                    step: .profile,
                    status: .passed,
                    findings: [],
                    actions: [],
                    checkedAt: nil
                ),
                OnboardingStepStateFfi(
                    step: .relays,
                    status: .retryableFailure,
                    findings: [.init(issue: .unreachable, endpoint: "wss://relay.example.com")],
                    actions: [.retry, .useRecommendedRelays],
                    checkedAt: nil
                ),
            ],
            proposal: nil,
            singleDeviceNotice: nil,
            cancellationPending: false
        )
    )
    .padding(40)
    .frame(width: 620, alignment: .leading)
}
