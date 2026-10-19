# Agent Notes

Notes for automated agents working in this repo. Keep this file current when the
build/test workflow or the MarmotKit boundary changes.

## Running the app

- When validating the macOS app, keep exactly one `White Noise` instance running.
  Do not use `open -n`; before relaunching, quit or terminate the existing
  `White Noise` process, then launch a single replacement through Xcode or the
  built app.

## Building and testing

The project builds and tests with `xcodebuild` against the `whitenoise-mac`
scheme (Apple Silicon / `arch=arm64`, code signing disabled for CI/local checks):

```sh
# Build the app
xcodebuild -scheme whitenoise-mac -configuration Debug build CODE_SIGNING_ALLOWED=NO

# Build the unit-test target (catches test-only breakage without running)
xcodebuild -scheme whitenoise-mac -configuration Debug build-for-testing CODE_SIGNING_ALLOWED=NO

# Run unit tests in the PR plan with an isolated host identity
scripts/test-isolated.sh

# Run UI performance tests (requires macOS UI automation permissions)
xcodebuild test -scheme whitenoise-mac -configuration Debug -testPlan UIPerformance \
  -destination 'platform=macOS,arch=arm64'
```

Unit tests live in `whitenoise-macTests/`, split by domain across `TimelineTests`,
`ChatListTests`, `GroupsTests`, `MediaTests`, `SettingsTests`, `AccountTests` and
smaller focused suites, with shared fakes and helpers in
`whitenoise-macTests/Support/`. `-only-testing:` **does** select an individual
test function, which is how you iterate without paying for the full suite:

```sh
scripts/test-isolated.sh \
  -only-testing:'whitenoise-macTests/TimelineTests/someTestName()'
```

Three details decide whether that filter matches anything, and only one of them
is loud when it is wrong:

- The **target** is hyphenated — `whitenoise-macTests`. The underscored spelling
  fails the build outright.
- The **suite** is the Swift type — `TimelineTests`, or `whitenoise_macTests`
  (underscored) for what remains of the original serialized suite. A wrong suite
  name exits **0** with `Executed 0 tests`, which looks exactly like a pass.
- The function name **keeps its trailing `()`**, quoted so the shell does not
  glob it. Without the parentheses the filter selects nothing, silently.

`-testPlan PR` is required: the scheme's default plan does not contain the test
target. Never trust the exit code of a filtered run — grep the log for
`Executed [0-9]* test` and confirm the count is what you asked for. Run the whole
suite once before handing work off; the remaining serialized tests share global
state, and order-dependent breakage only shows up in a full pass.

UI performance tests live in `whitenoise-macUITests/`, are isolated in the
`UIPerformance` test plan, and launch the app with the DEBUG-only
`-uiFixture heavy-chat` argument for deterministic chat/search/media data.

## Test isolation on disk

Use `scripts/test-isolated.sh` for unit tests, including focused `-only-testing:`
arguments. `just test` and CI call the same runner. It overrides the hardcoded
`TEST_HOST` path and verifies `dev.ipf.whitenoise.mac.tests` before execution;
`MarmotStorageProfile.testHost` has a separate disk root and account-ID Keychain
service. Its product name is `White Noise Unit Host`, so coverage's test-bundle
name filter keeps the app. Choose task-specific `WN_TEST_DERIVED_DATA` and fresh
`WN_TEST_RESULT_BUNDLE` paths. The runner unregisters only its temporary test host
on exit and performs no installation. Preserve production preferences when
checking erase/reset behavior; use synthetic sentinel keys and remove them.
Storage-root fixtures describing production paths must inject `.production`
against their temporary support root, rather than assuming the running profile.


The explicit development bundle `dev.ipf.whitenoise.mac.syncdev` selects
`MarmotStorageProfile.syncDevelopment`: a separate Application Support root and
account-ID keyed `SyncDevelopmentSecretStore`. Production keeps the platform
default account store. Keep initialization and reset on the same captured
profile. An explicitly supplied `SecretStore` owns credential cleanup for that
client: enumerate its actual SDK accounts and remove through that callback before
shutdown or root deletion. Never purge the profile Keychain for a supplied store.
A refused removal must leave the runtime and root intact. Keychain regressions must use unique test service names and synthetic
credentials, with cleanup; never query production credentials.

Build the separate Mac sidecar with `scripts/build-sync-development.sh` and a
task-specific `WN_SYNC_DERIVED_DATA` path. App-only `WN_APP_*` settings keep the
SwiftPM privacy resource bundle name intact. The script signs locally with the
project's sandbox entitlements, verifies signing, and performs no installation.
The explicit experimental sidecar adds camera access and its usage description
through `whitenoise-mac.syncdev.entitlements`; production signing stays unchanged.
The sidecar registers `marmot-syncdev`, preserving production URL registration;
development deep-link flow verification remains pending. By default it uses
published MarmotKit 0.12.0. Explicit `WN_EXPERIMENTAL_DEVICE_SYNC=1` enables the
native device-linking runtime methods only after checking the installed local
framework, generated Swift, source/builder identity and feature cohort. Use the
same flag with `scripts/test-isolated.sh`; never enable it for published bindings.
Keep fresh pairing and chat delivery acceptance separate from runtime smoke tests.
Verified current SDK overlays also define `WN_CURRENT_SDK_API` for public API
shape changes. A `WN_SDK_PROFILE=default` overlay requires explicit SDK source/run
provenance and keeps private sync disabled. Use the stable settings helper; do
not enable either capability flag directly for published bindings.

For a reviewed local experimental cohort, use `scripts/sync-local-bindings.sh`
with a clean MDK checkout/full SHA and explicit `EXPERIMENTAL_DEVICE_SYNC=1`.
Reuse `CARGO_TARGET_DIR`; do not commit local binaries or generated local binding
overrides. Restore published bindings before integration. See
`docs/local-marmotkit-development.md` for checks and remaining native gates.

Tests write real files, so every on-disk root a test double hands out is isolated
per test and per process by default — see `whitenoise-macTests/Support/TestStorageRoot.swift`.

- `FakeMarmotRuntime(accounts:)` reports a `storageRootPath` unique to the running
  test. `WorkspaceState` builds a `HiddenMessageFileStore`, `PinnedChatFileStore`,
  `ContactNicknameFileStore` and `DirectPeerMemoryFileStore` under it for every store
  the test did not inject, so a test that forgets to inject one now reads an empty
  directory instead of another test's records. Two doubles built during the *same*
  test still share a root, which is what a relaunch test needs. Pass
  `storageRoot: .explicit(path)` only to share a directory on purpose.
- `MessageMediaDiskCache.shared` — the default for `WorkspaceState`'s `mediaDiskCache`
  parameter, which almost no test overrides — resolves to a per-process temporary
  directory and a fixed in-memory key under a test run, never to the user's real
  Application Support directory or Keychain. A test that asserts on cache contents
  should still build its own with `MessageMediaDiskCache.makeIsolated()`.
- Do not reintroduce a fixed shared path. Isolation that has to be remembered is
  isolation that gets forgotten; `StorageRootIsolationTests` guards these properties.

## Localization

All user-facing strings live in the single String Catalog
`whitenoise-mac/Localizable.xcstrings` (source language `en`; the target
languages are whatever `knownRegions` in `project.pbxproj` lists). Edit it
through Xcode's catalog editor — it is machine-owned, and hand-editing the
nested `substitutions` of a plural entry corrupts it easily.

`just locales` (CI step "Localization coverage", part of `just precommit`) fails
when any language is incomplete. It reports a per-language coverage percentage
and flags entries that are missing, still `state: "new"`, empty, `stale`, or
have a broken plural `substitutions` set; `needsReview` is a warning unless you
pass `--strict`. Keys with no words in them (`"%lld / %lld"`, `"99+"`) are
skipped automatically — `just locales --verbose` lists them — and marking a key
"Don't Translate" in Xcode (`shouldTranslate: false`) also excludes it.

## Test coverage

`just coverage` (CI job "Coverage", part of `just precommit`) reports Swift line
coverage for the app target, read out of the `TestResults.xcresult` bundle that
`just test` leaves behind. Only first-party source under `whitenoise-mac/`
counts; the MarmotKit bindings and the test bundle are separate targets and are
filtered out. A file whose header carries `// coverage:ignore-file` is excluded
entirely — reach for that only when a file genuinely cannot be exercised from a
test, not to make a number go up.

CI does one thing more than the local recipe: it compares the run's coverage
against the number from master's most recent green run and **fails the PR when
coverage drops by more than 0.10 percentage points**. There is no baseline file
in the repo to update — every green run publishes its own coverage as the
`mac-coverage` artifact, and pull requests read master's. When no baseline is
reachable (nothing green on master inside the 90-day retention window) the
check reports the bare number and passes.

Two things the number will not tell you. Files xccov never reports are *not*
counted as 0%: they are compiled into no instrumented target, which is a target
membership problem rather than a testing one, so `just coverage` warns about
them separately. And coverage says nothing about whether a test asserts on
behavior — see the note on source-scraping tests above.

## Project structure is filesystem-synchronized

`whitenoise-mac.xcodeproj` uses `PBXFileSystemSynchronizedRootGroup`, so source
files under `whitenoise-mac/`, `whitenoise-macTests/`, and
`whitenoise-macUITests/` are picked up automatically by path. **Adding a new
`.swift` file under one of those roots requires no `project.pbxproj` edit** —
just write it under the right directory and it joins the target on the next
build.

## The MarmotKit / MDK FFI boundary

- The Rust core lives in the [mdk](https://github.com/marmot-protocol/mdk)
  workspace (formerly "darkmatter"). The app consumes it through one pinned,
  published release: `Vendored/MarmotKit/Package.swift` declares the macOS
  XCFramework as a remote `binaryTarget` (URL + SwiftPM checksum), and the
  generated UniFFI Swift bindings are tracked next to it. **No mdk checkout is
  needed to build**, and nothing binary is committed.
- To move to another core release: `just sync-bindings <version-or-full-sha>`.
  The script verifies the binary checksum, generated Swift source hash,
  separately checksummed privacy manifest, and the release manifest's
  `source_sha` and distribution metadata before installing anything, then
  rewrites the pin and stamps `Vendored/MarmotKit/MARMOT_VERSION`. `just sanity`
  cross-checks every stamp, re-hashes the vendored `MarmotKit.swift` and
  `PrivacyInfo.xcprivacy`, and verifies the Swift package resource declaration
  — so never hand-edit generated release artifacts, re-run the sync instead.
- The published macOS XCFramework is `aarch64-apple-darwin` only — there is no
  Intel or universal build upstream, so the app stays arm64-only.
- `MarmotRuntime` (in `Core/MarmotClient.swift`) is the `nonisolated` protocol the
  app calls; the concrete `MarmotClient` forwards thinly to the generated `Marmot`
  object, and `FakeMarmotRuntime` in the tests mirrors it. **Adding an FFI method
  means updating all three.**
- Projection subscriptions are owned below `Session/AccountScope.swift` and use
  cancellation-aware `nextCancellable()` bridges. Prepared chat rows, account
  attention, conversation windows, transfer snapshots, block lists, and
  onboarding snapshots are complete replacements; do not merge them with an
  older snapshot or restart per-row enrichment.
- MarmotKit 0.10.4 upgrades account databases through migrations 57–89, 0.11.0
  through 90–98, 0.12.0 through 99–101, and 0.13.0 through 102–107. An older app must not
  reopen an upgraded database (0.10.4 refuses a 0.11.0 one with `UnsupportedSchemaVersion`; locally that
  shows as a `storage_backend` startup error after a branch switch); see
  `docs/MarmotKit-0.10.4-migration.md`, `docs/MarmotKit-0.11.0-migration.md` and
  `docs/MarmotKit-0.12.0-migration.md`.
- 0.11.0 hosts must surface and let the user dismiss "history may be incomplete"
  notices: a parked loss keeps the account's transport cursor fenced until dismissed.
  `HistoryNoticesViewModel` on `AccountScope` owns this, re-reading on the runtime's
  `historyNoticesChanged` event.
- FFI value records crossing the off-main boundary (`WorkspaceState.runOffMain`)
  no longer need app-side `Sendable` conformances: since UniFFI 0.29 the
  generated module declares (checked) `Sendable` on them itself, which is why
  `Core/MarmotConcurrency.swift` is gone. If a new FFI type is rejected as
  non-`Sendable`, check the generated `MarmotKit.swift` before adding a
  retroactive conformance here — a duplicate is a build warning, not a fix.
  Conversions from FFI types into the app's own value types live in
  `Core/MarmotMapping.swift` — those projections are `struct`s, not view models.

## Architecture

The app is mid-refactor out of a `WorkspaceState` god object. Everything below is a contract for
**new** code — existing code is migrated one feature at a time, never swept — and none of it is
gated. The migration order is: break the test monolith open, then `AccountScope`, then delete
`lastError` as a global channel, then Settings as the first feature/view-model/service slice, then
the view layer.

**The layer direction is `App → Session → Features → Core`, and nothing below reaches up.** `App` is
the shell that composes everything (`whitenoise_macApp`, `ContentView`). `Session` owns per-launch
and per-account lifetime. `Features` are self-contained panes that own their own state. `Core` is
view-agnostic services and value types. A `Core` type never imports a feature, and no layer reads
the layer above it.

Where the tree actually stands, measured at `04cf5e0` — quote these numbers rather than guessing,
and never write a rule's target as though it were already true:

| | Today |
| --- | --- |
| `WorkspaceState` family | 17,424 lines across 33 files (`WorkspaceState.swift` + 32 `WorkspaceState+*.swift`) |
| `@Environment(WorkspaceState.self)` reads | 121, spread over 51 files |
| computed `var …: some View` | 351 |
| `#Preview` blocks | 5, against 280 `View` structs |
| `…Generation` stored properties | 38 |
| view models | 0 |
| `Session/`, `Features/`, `AccountScope` | do not exist yet |

The rules, in the order they are most often broken:

- **`WorkspaceState` is frozen.** Never add a stored property to it, never add a feature method to
  it, and never add a 34th `WorkspaceState+*.swift` file — 33 is a ceiling, not a running total.
  New feature state goes on a `@MainActor @Observable final class <Feature>ViewModel` in its own
  file. *(No example in the tree yet; the Settings slice writes the first one.)*
- **Account-scoped state goes on `AccountScope`**, an object whose lifetime is one signed-in
  account, so switching accounts destroys the state instead of running a reset checklist against
  it. *(No example in the tree yet. Until there is one, do not grow
  `resetActiveAccountUIState()` and its private helper — 51 statements between them, and both are
  scheduled for deletion.)*
- **A new `…Generation` counter needs a written reason, at the declaration, why cancelling the
  owning scope's task cannot do the job.** Hand-rolled staleness tokens are a failure mode this
  refactor exists to remove: a trailing fire-and-forget task steals the counter, the test passes
  locally, and it flakes only in CI. There are 38 of them; the 39th without that comment is a
  review rejection.
- **A feature view takes its model through `init`** — `let model: RelaySettingsViewModel`, not
  `@Environment`. `@Environment(WorkspaceState.self)` is reserved for the app shell. A dependency
  that is invisible in the initialiser is one nobody can substitute, which is why views are
  currently untestable and unpreviewable.
- **Every new view gets a `#Preview`.** If you cannot write one, the view depends on something it
  should not; fix the dependency rather than skip the preview. This is the cheapest possible check
  that the rule above was actually followed.
- **No new computed `var …: some View`.** Extract a `View` struct instead. A computed property
  shares its parent's observation set, so it re-renders whenever anything the parent reads changes;
  a struct observes only what it is given.

## Experimental native linking owner

`SessionState` and `DeviceLinkingScope` retain the original opaque SDK session and
subscription. Never reconstruct it from snapshot metadata or enable enrollment from
native capability flags. Factory adoption must retain the exact account scope,
runtime instance and ownership ticket across awaits, including A→B→A. Invalidate
before any Core teardown; retain failed exact cleanup and retry deliberately.
The generic `beforeAccountExit`/`beforeRuntimeReset` callbacks wire existing app
exit paths without adding feature state to `WorkspaceState`. Runtime identity is
only positive for class implementations, tested with actual `MarmotClient`.
Keep generated development SDK overrides out of commits. Use the dedicated
`MacTestIsolationM5` cache and isolated host for focused tests. Lifetime qualification on signed9b245 passed the full PR suite with published0.12
and experimental e6. It does not cover pairing UI or scene suspension.


The experimental Settings verification pane takes its account-owned model explicitly
through the shell. Keep the initial bootstrap and comparison display local to that
owner and confirm the displayed revision. The SDK exchanges encrypted packets and
authenticated processing receipts automatically; normal UI never asks the user to
receive or acknowledge individual packets.
Do not add enrollment actions while the SDK capability is unavailable. Localization
for this pane used Apple stringsdata/XLIFF export-import, preserving all prior
catalog entries; retain that tool provenance when extending it. Final source passed
full published0.12 and experimental e6 PR gates; actual native pairing remains a
separate acceptance gate.

## Synchronized logical history reader

`Features/SynchronizedHistory` owns one bounded source-attested page; Core value
records preserve logical tags, ordered media outcomes and provenance. Invalidate
before account teardown and refuse late cancelled/superseded reads. Keep this
projection separate from live authenticated timeline rows and original consent.
Use `docs/synchronized-history-reader.md`; native adapter/UI acceptance is a
separate gate, and no record or cursor supplies transfer/download permission.

Create chat history readers through `AccountScope.synchronizedHistoryModel`,
which captures the account reference and registers exact reader invalidation.
Account replacement invalidates before teardown; releasing a chat retires its
reader even when no live conversation has been opened. Retired scopes return
inactive readers and must never call the injected storage read dependency.

The default reader factory captures the scope's exact `MarmotRuntime`; synchronous
history storage calls run through the model's detached task. Update protocol,
`MarmotClient` and shared fake together. Experimental native history requires the
matching history-capable SDK; the older SDK83 cohort cannot compile the new
bridge with `WN_EXPERIMENTAL_DEVICE_SYNC` enabled. Published builds refuse the
unavailable query. Mapping preserves source attestation, not live authorship.

## Incoming history review

`AccountScope` owns the experimental `HistoryConsentReviewViewModel`. Its loader
captures the exact account scope across awaits and retains original SDK consent
handles through `NativeHistoryAccountOwner`. Features depend on the Core
`HistoryConsentReviewing` interface, never Session. Row UUIDs select already-held
originals; snapshot fields and device fingerprints never create approval authority.
Listing and selection only refresh. Approval forwards the displayed revision to
the exact recipient original; account replacement invalidates the model before
teardown. One malformed original must not block review of another. Focused model
and related lifetime evidence is in `docs/history-recipient-review-model-verification.json`;
installed UI, real transfer acceptance and full PR qualification remain separate.

The incoming review pane is acquired explicitly from Settings through the exact
live account scope. Approval must capture the snapshot revision rendered in the
button; listing, selecting and refresh never approve. Keep full device fingerprints
and source-attestation visible; row IDs only select already-held originals.
Cancel presentation tasks on dismissal or account retirement. Apple catalog
provenance and focused gates are in
`docs/history-recipient-review-pane-verification.json`; full PR and genuine
installed approval/reader acceptance remain separate requirements.

Full recipient-pane PR qualification at signed `ed16012` passes experimental
1,787/0 and published 1,661/0, with no skips. Two prior published attempts
executed no tests because of individually diagnosed stale FFI PCMs; both are
preserved separately. See `docs/history-recipient-review-full-pr-verification.json`.
Genuine installed original approval and imported reader acceptance remain open.

One-scan development pairing uses the compact native bootstrap and automatic
SDK-owned encrypted relay exchange. Activate only after exact account/runtime
factory adoption; a late result must be cancelled before it can export a scanner
response. Keep visual SAS comparison, bilateral enrollment/chat-sharing approval
and each existing device's explicit review. Transport receipts never replace
approval. The normal UI offers no per-packet export/import/receive/ACK/finalize
controls; the existing low-level SDK APIs remain available for controlled tests.
