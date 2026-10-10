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
