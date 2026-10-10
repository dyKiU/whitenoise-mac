# Original native linking lifetime

The experimental Session boundary retains the exact SDK session/subscription under
its account scope. A synchronous ownership ticket prevents late factory adoption
across account replacement, A→B→A, runtime replacement or deactivation. One pending
factory is bounded; teardown cancels it without waiting for an implementation that
ignores cancellation. Its late SDK result remains negative cleanup, never an owner
for the replacement account. Cleanup failures preserve the exact original object
and error for deliberate retry. Active-account sign-out/removal and full reset call
this boundary before Core work; their existing mutation guard precedes awaits.

Class-only runtime identity preserves genuine MarmotClient shell rerenders. Value
protocol implementations intentionally cannot establish a preservation identity.
No snapshot, account string, or native flag reconstructs SDK permission.

## Observed tests

On M5 with the installed e6 SDK and dedicated MacTestIsolationM5 isolated host:

- Original lifetime RED: 0/3, including parameterized replacement/deactivation.
- Actual reset ordering RED: 0/1.
- Actual reset cleanup RED: 0/1 (implicit second cancel after failure).
- Final feature lifetime: 9/9, including real MarmotClient factory errors and
  sign-out/removal cleanup failure controls and repeated detached-exit refusal.
- Affected feature tests: 16/16 (account scope4, real runtime factories5,
  existing account exit/reset7).
- Owned Swiftformat6.2.3 and git diff checks pass.

Final signed9b245 product passed the full PR suite in both cohorts: experimental
e6/flag1 1663/1663 (62.36s), published0.12/flag0 1649/1649 (86.61s).
These are suite executions, not unique test counts across repeated selections. A default-off affected run
failed before tests because unchanged FakeMarmotRuntime omits e6 draftVersion.
A subsequent canonical published0.12/flag0 affected run passed11/11 after retiring
only diagnostic-named stale FFI PCM files. The e6 mixed-cohort failure is not a
published-default failure. The feature branch does not enable enrollment or add UI. Scene background currently
reports analytics rather than closing Core, so scene suspension is not qualified.

The first Green build passed3 then crashed in ordinary Workspace bootstrap. Its
exact415 source inputs and diagnostic remain preserved. Protocol constraint revert
plus owned Swift rebuild preceded Green4/4; this does not establish a unique crash
cause. Earlier zero-test stale FFI PCM failures are tooling failures, not RED tests.

The accompanying evidence JSON records exact result/input/log hashes and named
compact Git stashes. Parent build/results contains exact415-source recovery proofs,
restrictive generated overrides archive and full raw logs. Four existing generated
SDK overrides remain outside this commit. No production apps/accounts or SDK
artifacts were changed. The full published/experimental PR gates passed before fork publication.

## Detached cleanup retry follow-up

An actual repeated sign-out initially bypassed retained failed cleanup after the
first exit detached the account scope (RED0/1). The current selector distinguishes
a different actual current account from absent scope; absent scope still retries
the retained negative original cleanup before Core exit. The exact test source is
preserved in named stash caf4105c and a compact verified blob. No new SDK session or
permission is reconstructed. Both final full PR gates passed on that signed product.

## Original-owner verification actions

The scoped owner forwards setup/peer packet transport, outgoing acknowledgements and
comparison using the exact displayed revision to the original SDK object. It checks
active ownership before invocation and after asynchronous completion; replacement
therefore cannot expose delayed packet results. SDK errors remain typed and unchanged.
Enrollment actions remain unavailable.

The missing-feature RED ran 0/3 passing; guarded forwarding passed 3/3, then four
action controls plus the existing nine lifetime and five runtime tests passed 18/18.
These action controls use generated-protocol doubles and prove native ownership and
forwarding, not genuine SDK pairing. Scoped swift-format and diff checks passed.
The previous full published/experimental gates precede this slice; final full PR
qualification is required before integration. See native-device-linking-actions-evidence.json.

## Account-owned verification display model

AccountScope retains the verification display model, installed by SessionState with
weak exact-scope factory callbacks through the existing original-object adoption
boundary. Features use a Core verification-only protocol; they do not depend on a
Session concrete type. No snapshot is persisted or interpreted as permission.
The model confirms the revision captured by the caller display, invalidates on
account retirement, and rejects cancelled or late factory results. Session remains
responsible for exact late SDK cleanup.

The missing-feature display RED failed both tests; initial Green passed2/2 and the
affected final cohort passed26/26 (model4, action4, lifetime9, runtime5, AccountScope4).
Settings UI and final full PR qualification remain subsequent steps. See
native-device-linking-model-evidence.json.

## Verification-only Settings flow

Settings now receives the exact AccountScope verification model through the shell.
A new scope resets view-local opaque packets. The flow starts or approves through
the original SDK factory, transports canonical bounded base64 packets, explicitly
acknowledges delivery, and confirms the exact revision rendered with the comparison
numbers. Copying a packet is not a delivery acknowledgement. No enrollment or
continuation action is exposed; the screen states that enrollment is unavailable.

The missing transport-forwarding regression failed0/1; final affected selection
passed27/27 (model5/action4/lifetime9/runtime5/AccountScope4). Final exact424-input
full PR gates passed experimental e6/flag1 1672/1672 and published0.12/flag0
1649/1649. Two published runs failed before tests on compiler-named stale FFI PCMs;
only those named modules were retired while the cache was idle, then the canonical
gate passed. All four experimental generated overrides were restored byte-exact.
These counts describe suite executions, not distinct tests across repetitions.

Localization used Apple compiler stringsdata and Xcode XLIFF export/import. Only
18 new machine-produced catalog entry blocks were imported, with162 translations
across nine languages; all1220 prior entries remain unchanged. Thirteen unrelated
extraction metadata changes were discarded. Coverage passes1229/1229 in each
language. Initial extraction/import attempts with the wrong feature cohort were
retained as unsuccessful workflow attempts, then repeated with the actual feature
flag and dedicated cache. No plural substitutions were hand-edited.

See native-device-verification-settings-evidence.json for hashes, compact RED stash
and tool provenance. Scoped Swift formatting and diff checks pass. The controls
use generated-protocol doubles; actual native two-device UI pairing and scene
suspension remain unqualified. Full PR gates qualify the source before integration,
not enrollment, chat admission or live account behavior.

## Original-owner enrollment scope (development only)

DeviceLinkingScope now forwards explicit revision-bound `continueLinking`,
`enrollmentPacket`, `receiveEnrollmentPacket` and `finalizeLinking` to the original
retained SDK session. `checkActive` runs before and after each await. Native
account replacement A→B→A, deactivation and `prepareForAccountExit` invalidate
the original owner before a delayed packet can escape; SDK revision errors and
opaque bytes are preserved.

Default-deny RED executed five functions (six cases including both exit paths)
and failed all five. GREEN passed five; affected original action/lifetime/runtime
tests passed23/23. Exact426-input source hashes were frozen before/after each run.
Two earlier zero-test stale FFI PCM failures and one runner preflight guard are
preserved; only the exact compiler-named idle modules were retired. The RED
source is recoverable from a named compact Git stash and hash-verified against
the manifest. Strict scoped Swiftformat6.2.3 and diff checks pass. See
native-device-linking-enrollment-scope-evidence.json.

DeviceVerificationSession, Settings/model and advertised capability remain
unchanged. Approval custody and enrollment UI are separate future slices. This
is generated-handle native lifetime qualification, not genuine SDK enrollment,
ABC settlement, selected-chat consent or native application acceptance. No full
PR rerun, push/merge, SDK rebuild or sidecar adoption is claimed.


## Original approval custody (development only)

SessionState now owns one original DeviceLinkingApproval separately from its
verification session. Finite snapshot, explicit approval and enrollment packet
receipt forward exact displayed revisions/opaque bytes and check native ownership
before and after awaits. The original SDK object remains the permission authority;
no cached snapshot recreates an action. A held original is returned only while its
current SDK phase remains nonterminal.

Account/runtime replacement, deactivation and prepareForAccountExit invalidate
pending factories and retained originals synchronously. Late original results are
never adopted. Failed exact cleanup is retained for retry; session and approval
cleanup are attempted independently, and either failure blocks either factory.
The SDK's bounded multiple-pending batch (e6 limit128) is retained on refusal,
without selecting an original or implicitly cancelling it by dropping the list.

Default-deny RED ran eight tests and failed eight. Initial implementation passed
8/8; final source avoids an empty-batch cancellation callback and passes8/8 plus
31/31 affected session/action/lifetime/runtime tests. Repository strict swift-format
and diff checks pass. Exact RED/initial GREEN sources remain in compact Git stashes;
all429 input paths and terminal log hashes are recorded in
native-device-linking-approval-scope-evidence.json.

This is native custody/lifecycle qualification with generated original-handle test
doubles and actual SessionState paths. It is not actual SDK enrollment or a full PR
suite. Verification UI/protocol and advertised capability are unchanged. No merge,
push, installation, production app or account data action occurred.


## Separate enrollment presentation models (development only)

AccountScope retains separate DeviceEnrollmentViewModel and
DeviceEnrollmentApprovalViewModel objects. SessionState creates the session model
only from its already-held concrete original scope; it never starts a session from
snapshot display. Both models retain the exact account/runtime ownership ticket.
Session actions forward explicit continue/export/receive/finalize revisions and
opaque bytes. B actions refresh finite metadata or explicitly approve/receive on
the separately held original approval. Refreshing or decoding never approves.
Canonical base64 input is bounded to16KiB of opaque bytes and carries no native
identity or permission. Cancellation immediately retires display and retains exact
failed cleanup for retry; that retry checks the same retiring original rather than
cancelling a replacement owner.

Default-deny RED ran seven tests: two negative controls passed and five missing
action controls failed. Unchanged controls passed7/7 after implementation;
affected models/custody/session/transport/lifecycle/runtime controls passed43/43.
Strict repository swift-format and diff checks pass. All433 source inputs and
full terminal log hashes are recorded in native-enrollment-models-evidence.json;
exact RED and GREEN source are preserved in named compact Git stashes.

These are original-handle model/lifecycle controls, not actual SDK enrollment or a
full PR suite. No view, capability, SDK/artifact, profile, installation or production
state changed. The e6 B snapshot contains revision/phase only; authenticated review
identity metadata and nativeABC acceptance are required before general approval UI.

## Explicit first-device setup attempt

The verification pane offers a separate first-device setup attempt only after a
successful empty target read under its exact account/runtime owner. Failed,
in-flight and retired reads cannot offer it; existing-target approval still
requires the exact current selector. Nil reaches the original factory only from
that explicit action. Empty target metadata does not grant eligibility: actual
Core genesis policy and SelectionBusy remain authoritative.

Default-denying RED ran9 (7passed/2failed), unchanged GREEN9/9, actual SessionState
owner-retirement controls10/10, final affected48/48. Scoped strict formatting,
diff and nine-language100% coverage pass. Apple stringsdata/XLIFF import added
one key with nine translations; all1238 previous entries/order are preserved.
See native-first-device-setup-evidence.json for exact source and terminal hashes.

This is a scoped model/factory check, not full native enrollment or full PR
qualification. SDK capability, verification protocol and original owners remain
unchanged. No application installation or production state action occurred.

## A/C opaque enrollment transport (capability gated)

A separate Settings pane composes the already-held original enrollment model.
Continue, opaque export/receive and finalize forward the rendered revision to
that owner. Input is canonical base64 and bounded16KiB; no protocol is parsed.
The original SDK decides permission/phase. Late results cannot populate replaced
account state; cancellation clears displayed bytes and preserves cleanup retry.

Actual runtime enrollmentSupported is captured into original-owner composition.
It remainsfalse with e6, so this pane is unavailable; no advertised capability
is enabled. B approval review and native A/B/C acceptance remain separate.

Observable defaultdenyRED9 ran8pass/1fail; unchangedGREEN9/9, focused11/11 and
final affected53/53 pass. Scoped strict formatting/diff and localization coverage
pass. Three Apple sync/import-generated keys×9translations preserve all1239
previous entries/order. Exact source/runs, compile-only fixture failure and
comment-format correction are in native-enrollment-transport-evidence.json.
No full PR, visual acceptance, new SDK, install or publication is claimed.

The original B approval scope now forwards `reviewMetadata` on the same retained
SDK object, with lifetime checks before and after the read. The separate approval
model retains review display only under that owner and pending revision; reading
never approves. Explicit reviewed approval uses the exact displayed revision and
clears review metadata before the SDK action. SDK errors, actual account A→B→A,
deactivation/account-exit, changed phase and failed exact cleanup are covered.

Candidate SDK source `3fab3184` passed all ten release artifact/consumer gates.
Native review RED0/2 precedes GREEN2/2 and seven control tests (eleven case
executions); final affected60/60 passes. The first affected run59/60 retained the
old e6 capability expectation; its smoke assertion was corrected to the new
SDK-derived capability, without changing app capability logic. See
`native-enrollment-approval-review-evidence.json`. This qualifies the original
handle/model boundary, not an approval pane or native A/B/C acceptance. No local
SDK overrides are part of the commit; final integrated SDK/native full gates
remain required before development application adoption.

A separate B approval pane now opens only through the actual account-owned factory
while the SDK reports enrollment support. It displays the original SDK-authenticated
source and joining device public keys in full, plus the existing device count.
Explicit approval captures that rendered revision. Opaque packet intake is separate
and only reaches the same original approval in its approved-awaiting-packet phase.
Refresh, display and packet decoding do not approve or reconstruct permission.

Pane default-deny RED0/2 precedes GREEN2/2; final focused11/11 and affected64/64
pass on the matched3fab candidate SDK. Apple stringsdata/XLIFF import adds five
keys across nine languages, preserving all1242 previous entries and order; strict
coverage and scoped formatting pass. See native-enrollment-approval-pane-evidence.json.
This is scoped native action/lifetime qualification, not visual acceptance or
actual native A/B/C enrollment. Full native PR and final integrated SDK gates
remain required before development application adoption.

## Resumed original enrollment approval display

An already-owned approval can resume in approvedAwaitingPacket,
awaitingSettlement or settled. The pane refresh reads the original snapshot and
requests authenticated review metadata only while awaitingApproval. Waiting/Done
use existing catalogue keys; displaying resumed state never approves again.
New terminal approvals remain ineligible for factory adoption.

A genuine three-phase control first adopts the pending original, then advances
that same handle: RED11/12 precedes unchanged GREEN12/12, affected53/53 passes,
zero skips, with the isolated Mac host and matching experimental3fab SDK.
Parent independently verifies all445 inputs per cohort and every complete log.
Full native PR, final SDK and installed cryptographic flow remain open.
