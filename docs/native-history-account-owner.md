# Account-owned original history actions

`AccountScope.history` captures one exact account/runtime lifetime. Its source and
pending-recipient factories retain original SDK handles; snapshots never create
consent. Live recipient handles are reused while held, avoiding snapshot-based
identity deduplication or replacement of an original approval.

Account switching, scene deactivation and reset invalidate before teardown. An
ignored-cancellation factory remains a teardown fence until its result is
explicitly cancelled. Caller cancellation follows the same path. SDK history
cancellation is synchronous and nonthrowing; unlike selected-chat cleanup, it
requires no fallible cancellation retry. The pending factory itself remains
retained while cancellation has not yet produced a terminal result.

Only the exact held handle may be released, so a closing old view cannot cancel
its replacement. The SDK collection limit is 128; an oversized collection is
refused after explicitly cancelling every returned original.

Fifteen focused controls pass after the original factory baseline fails its
unchanged regression. Full PR suites, consent UI and installed native acceptance
remain required before integration. See the accompanying verification JSON.
