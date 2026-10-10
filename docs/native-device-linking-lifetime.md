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
