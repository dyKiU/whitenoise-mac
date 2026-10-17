# Local MarmotKit development builds

The normal app still pins the published MarmotKit 0.12.0 binary. For the separate
sync development profile, build a clean, committed MDK checkout with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
EXPERIMENTAL_DEVICE_SYNC=1 \
CARGO_TARGET_DIR=/absolute/path/to/reused/target \
scripts/sync-local-bindings.sh /absolute/path/to/mdk <full-source-sha>
```

The installer builds and validates the arm64 macOS artifact, then verifies the
packaged source, builder and feature list before replacing local artifacts. It
records the actual source branch and features in `LOCAL_BUILD.json`,
`MARMOT_VERSION` and compiled Swift provenance. Local XCFrameworks and build
records are ignored; generated Swift and the package override are development
changes and must not be committed as a published release.

Restore the published cohort with `scripts/sync-bindings.sh 0.12.0`. That clears
the local binary override and reinstalls the matching Swift/privacy resources.
The normal sanity gate continues to check published artifact provenance.

Five isolated installer tests pass, including execution of compiled Swift
provenance and SwiftPM resolution of the local binary target. Wrong source or
feature manifests preserve the existing artifact. The initial run executed zero
behavior tests because the installer did not exist. The default package was
independently resolved and still selects the unchanged published URL/checksum.
Run `python3 -m unittest discover -s scripts/tests -v` to repeat these checks.

These tests use synthetic native build outputs. Actual experimental artifact
compilation, linking APIs, native pairing and message delivery require their
separate end-to-end qualification before installation.

The production sanity gate validates the resolved display name and URL scheme
from Xcode settings, and checks SwiftPM's actual binary target against the
published URL/checksum. On M5 the old literal-name check failed; the corrected
gate passes with the production defaults and rejects a temporary local override
pointing to the valid cached 0.12.0 XCFramework. The pin was restored afterward.
Two initial refusal probes used absolute binary paths and failed Xcode package
resolution before reaching the new guard; those are separate tooling failures.

The M5 full PR suite from signed `6fef644` passes all1,649 tests with zero failures
or skips (43.344seconds in the Swift Testing summary). The actual xcresult was
independently checked. Subsequent formatting changes only the new binary-target
declaration; the resolved SwiftPM JSON remains identical. Two existing trailing-
comma lint findings outside that declaration remain; no whole-file lint pass is
claimed. This still qualifies the published-core development profile, not sync.

## Experimental native runtime adoption

After installing a matching experimental cohort, explicitly select its app APIs:

```sh
WN_EXPERIMENTAL_DEVICE_SYNC=1 scripts/test-isolated.sh \
  -only-testing:'whitenoise-macTests/NativeDeviceLinkingRuntimeTests'
WN_EXPERIMENTAL_DEVICE_SYNC=1 scripts/build-sync-development.sh
```

Both test phases receive the same Swift flag. The runner refuses a missing local
manifest, a mismatched feature/source/builder cohort, modified generated Swift or
a changed native archive. Default builds retain the published pin. Runtime
methods forward the original opaque SDK sessions and approvals without adding
application permission or synthesizing approval state.

With MDK `e6b0e9c159b632b8c07eb68f12f46c3bc930699c`, the actual Mac framework
build and validator pass. Five isolated native runtime tests pass on M1 and M5:
verification is supported, enrollment is still not advertised, and all four
account-dependent factories/reads retain the typed missing-account error without
creating an identity. The M5 experimental PR suite passes1,654 tests; the final
published default suite passes1,649. No failures or skips occur in those runs.
The matching native archive and Swift cohort were verified before M1 adoption.

Two fixture conveniences cover added draft-version and attachment-role fields
only for the experimental test target. Local provenance is checked separately
from the published release pin. Three initial experimental compile failures
(draft version, attachment role, local provenance) and one stale-header cache
failure on returning to default are retained as compile failures, not behavioral
RED evidence. Only the two named stale FFI PCM cache files were retired.

See `docs/native-device-linking-runtime-verification.json` for exact frozen input
and log hashes. Generated local overrides and binaries are excluded from the
commit. These checks qualify native API adoption, not fresh pairing, ordinary
recipient admission, message delivery or history. The iOS device/simulator
framework build remains separate and in progress at this checkpoint.

## Preserving the original invitation receiver during sign-in

MDK `8af010399b44d9fdb09b823ef28cd91250d484b7` protects the existing public
invitation keys when a user acknowledges sign-in after discovery finds another
installation or cannot complete. The existing revision-bound onboarding call
persists the account publication hold before proceeding; no new host API or
app-side publication decision is needed. Confirmed empty discovery still permits
ordinary primary-account publication.

The Mac displays the preservation explanation only when the SDK reports ready
with its key-package step skipped. Older published SDKs keep their own behavior.
Signing into an additional installation does not pair it, supply existing MLS
chat state, repair previously advertised keys or recover missing invitations.
Native relay qualification and the exact installed cohort are recorded in the
parent workspace's `doc/ios-public-chat-invitation-investigation.json`.
