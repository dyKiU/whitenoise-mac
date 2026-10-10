# Incoming history review pane

Experimental builds expose **Settings → Profile & keys → History transfer →
Review incoming history**. The shell acquires the existing account-owned review
model only while that exact account scope is current and alive.

Opening or selecting a request does not approve it. Selecting an already-held
original displays the complete source and receiving-device fingerprints, chat ID,
snapshot cutoff, record/import counts, encoded size and source-attestation notice.
The explicit Approve button forwards the revision displayed in that render to the
original recipient consent. Cancel cancels only the selected original. Refresh
reloads pending originals. Closing the pane cancels its pending presentation task;
account replacement invalidates the model before runtime teardown.

Rows use local UUIDs only to select retained handles. Display fields never create
consent or reconstruct SDK authority. All new views have previews. Published builds
omit the entry through the existing experimental compile flag.

The catalog adds eight strings via Apple compiled stringsdata sync and XLIFF
import in all nine target languages; prior raw entry blocks and order are retained.
Focused compile/model checks and exact provenance are recorded in
`history-recipient-review-pane-verification.json`.

Full PR qualification passes at signed pane `ed16012`: experimental 1,787/0
and published 1,661/0, both without skips. Exact frozen inputs, raw logs and
actual Xcode summaries are in `history-recipient-review-full-pr-verification.json`.

Installed presentation/approval of a genuine pending original,
actual imported-history reader acceptance and combined-source SDK adoption remain
required. This slice does not provide the source-device picker or prove a complete
installed transfer workflow.
