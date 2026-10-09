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
