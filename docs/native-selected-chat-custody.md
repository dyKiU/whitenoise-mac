# Experimental selected-chat original handles

The Mac runtime thinly forwards selected-chat request/recipient factories to
MarmotKit. `NativeSelectedChatCopyScope` and `NativeSelectedChatConsentScope`
retain the original opaque SDK handles and forward the displayed revision and
packet bytes. Snapshot records never create authority or grant consent.
Enrollment approval remains a separate action.

M5 isolated PR tests, experimental SDK source `3fab3184`, reused
`MacTestIsolationM5`: genuine RED four executed/four failed, unchanged GREEN
four passed, affected selected/linking/review suites33 passed; no skips.
Runner: `bash scripts/test-isolated.sh -jobs 2` with `WN_EXPERIMENTAL_DEVICE_SYNC=1`,
`-only-testing:whitenoise-macTests/NativeSelectedChatScopeTests`, then related
native linking lifetime/runtime/review suites. Parent evidence independently
checks all441 frozen inputs and complete logs for each cohort.

This checkpoint does not include account-owned factory adoption, lifecycle
qualification, chat consent UI, full PR qualification or installed delivery.
Generated local SDK overrides and framework binaries are not committed.

## Original-handle lifecycle controls

The next scoped control suite passes11 focused and40 affected tests with zero
skips, on the same isolated target/SDK. It checks retirement blocks all new
actions; paused original packet replies cannot escape retirement/cancellation;
failed cleanup stays observable and retries the same original, with successful
cleanup idempotent; stale displayed revisions pass through as SDK errors.
These are passing controls of existing scope behavior, not invented regressions
or new runtime fixes. Account-owned factories and full PR remain pending.

## Account and Core-teardown ownership

`AccountScope` owns one immutable account/runtime selected-chat coordinator.
`SessionState` uses it for actual SDK factories, retires it before account/runtime
teardown, and retains late results or failed cleanup. Pending factories that ignore
cancellation fence explicit Core exit until their exact original is cleaned up.
An A→B→A transition never reactivates an old owner. Caller cancellation also
retains late originals and finishes failed cleanup before another factory runs.

Actual missing ownership RED11/13 precedes unchanged minimal GREEN13/13 and
18 passing lifetime controls. An additional genuine failed-cleanup regression
runs18/19 before the minimal cleanup-before-next-factory fix; unchanged final
focused19/19 and affected52/52 pass, zero skips. This uses the same3fab SDK and
MacTestIsolationM5 cache. Parent evidence verifies every frozen source input and
complete raw log in all six cohorts. The Core-reset regression uses isolated
WorkspaceState/FakeMarmotRuntime exit callbacks and synthetic account storage.

Explicit consent UI, final matched SDK, full published/experimental PR suites,
installed multi-host delivery, history and offline/revocation remain pending.

## Explicit presentation actions

The selected-chat copy and consent models retain their already-owned original
scopes. Refresh only displays SDK state. Consent approval uses the reviewed
revision; response and offer exports require the approved snapshot revision.
Incoming packets use canonical base64 and the core's 16,384-byte bound; native
code never constructs protocol messages. Account retirement hides display and
packets, including a reply arriving after an action was suspended. Cleanup
remains attached to the same original and retries failures.

Actual missing-feature RED0/2 precedes unchanged GREEN2/2. Expanded controls
expose stale display/output after invalid snapshots (RED8/10); the minimal
state-clearing correction passes the unchanged10 tests. Final focused11/11
and affected64/64 pass with zero skips on isolated M5 PR host, SDK3fab and the
existing MacTestIsolationM5 target. All six complete447-input and raw-log cohorts
are independently checked in the parent evidence. Commands use
`bash scripts/test-isolated.sh -jobs 2`, `WN_EXPERIMENTAL_DEVICE_SYNC=1`, and
`-only-testing:whitenoise-macTests/SelectedChatPresentationTests`; affected also
selects native linking scope/runtime/lifetime, enrollment review, and selected
chat scope suites.

This is the presentation-model checkpoint. Account-owned pane composition,
localized views, final matched SDK, full PR suites and installed delivery remain
separate acceptance gates. No generated binding or binary overrides are committed.

## Account-owned transfer composition

Account activation installs a transfer feature with weak references to the exact
Session/account lifetime. It creates display models only through existing owned
factories, reads actual SDK target selectors, and checks the exact handle and
account again after awaits. Account cancellation invalidates the feature. No
WorkspaceState fields or methods were added. Creating a copy/request display
never exports a request or approves consent implicitly. Invalid packet input
and unknown targets refuse before factory entry; a failed first snapshot retains
its original model for explicit cancellation.

Actual transfer RED11/13 precedes unchanged GREEN13/13. The separate missing
account composition RED13/14 precedes unchanged GREEN14/14. Final focused17/17
and affected70/70 pass, no skips, on the same isolated M5 PR host and SDK3fab.
Parent verification checks six complete448-input/log cohorts and four signed
source paths. Localized panes, full PR, matched final SDK and installed delivery
remain pending. The feature permits an explicit experimental attempt; target
metadata and native capability flags do not grant chat admission.

## Explicit Mac pane and entry points

The chat shell injects the current account's transfer feature into a copy sheet
for the selected actual group ID. Profile Keys Settings injects the same feature
for incoming request review. The retained original copy group's ID stays visible
even if another chat is selected; the recipient displays the SDK-authenticated
chat selector in full hex. Review, approval, request export, consent/offer import
and export, and continuation are explicit actions with the rendered revision.
The pane cancels its awaiting tasks when dismissed; account custody still owns
original cleanup and late factory results. Failed cleanup remains retryable.

Actual group-display RED16/17 precedes unchanged GREEN17/17. Terminal consent
phases retaining old output fail17/18 (three cases); the minimal phase-clearing
fix passes18/18. An original SDK snapshot error retaining prior controls/output
fails18/19; clearing native display while rethrowing the same error passes19/19.
Final affected72/72 passes, no skips. Parent evidence independently verifies all
eight source/log cohorts and the eight signed implementation/catalog/test paths.
The pane compiles in the actual isolated host; interactive installed UI/delivery
acceptance and full PR qualification remain open.

Apple xcstringstool sync on actual compiled stringsdata and nine XLIFF imports
adds12 keys, preserving all1,247 prior catalogue values and key order. All nine
languages pass repository translation coverage (1,250/1,250 translatable keys).
The compact catalogue tool provenance records complete import log/XLIFF hashes.
Generated SDK overrides, products and raw logs are not committed.
