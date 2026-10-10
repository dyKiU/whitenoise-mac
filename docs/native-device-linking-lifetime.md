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
- Final feature lifetime: 8/8, including real MarmotClient factory errors and
  sign-out/removal cleanup failure controls.
- Affected feature tests: 16/16 (account scope4, real runtime factories5,
  existing account exit/reset7).
- Owned Swiftformat6.2.3 and git diff checks pass.

These are suite executions, not full PR qualification. A default-off affected run
failed before tests because unchanged FakeMarmotRuntime omits e6 draftVersion.
The feature branch does not enable enrollment or add UI. Scene background currently
reports analytics rather than closing Core, so scene suspension is not qualified.

The first Green build passed3 then crashed in ordinary Workspace bootstrap. Its
exact415 source inputs and diagnostic remain preserved. Protocol constraint revert
plus owned Swift rebuild preceded Green4/4; this does not establish a unique crash
cause. Earlier zero-test stale FFI PCM failures are tooling failures, not RED tests.

The accompanying evidence JSON records exact result/input/log hashes and named
compact Git stashes. Parent build/results contains exact415-source recovery proofs,
restrictive generated overrides archive and full raw logs. Four existing generated
SDK overrides remain outside this commit. No production apps/accounts or SDK
artifacts were changed. Full PR qualification is required before push/merge.
