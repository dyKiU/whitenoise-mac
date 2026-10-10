# Synchronized history reader model

`SynchronizedHistoryViewModel` owns a read-only account/chat projection. Its
immutable dependency receives the captured account, opaque group ID, message-ID
cursor and page limit. Storage/native permission and provenance remain with MDK;
a page is never an original history action or a media download grant.

The model keeps one page of at most 200 records. Next-page traversal follows the
exact returned message-ID cursor, not timestamp order. A final empty page ends
traversal. Reload clears prior records and starts from the first page, allowing
MDK retention, expiry and live-message precedence to be reevaluated. Invalid
pages and read failures clear prior rows; explicit retry starts from the beginning.

Create a reader through `AccountScope.synchronizedHistoryModel`. It captures the
account reference, reuses the chat reader, and invalidates it on account replacement
or chat release. A retired account returns an inactive reader. Invalidation
cancels its read and clears all records/cursors. A cancelled or superseded read
cannot install a late result, including a dependency that ignores cancellation.
Synchronous native storage work must be offloaded; the model calls its reader
through a detached task. It has no transfer, approval, send or acquisition method.

The factory without an injected reader uses the exact account runtime's
`synchronizedHistoryPage` method. The experimental `MarmotClient` bridge calls the
native committed-page query and copies every logical/provenance field into the
read-only model. Published builds refuse unavailable history. Experimental builds
require matching history-capable Swift and native artifacts; SDK83 does not
provide this API. No imported record is converted into an authenticated live row.

Record values preserve logical content/tags, tombstones, ordered media outcomes
and source/transfer/manifest provenance. Debug omits all fields. A future view
must label source attestation separately from live authenticated messages and
must not fetch attachments merely because a descriptor appears in a page.

This source slice has an unchanged runtime regression (0/1 before, 1/1 after)
and eight passing reader controls against published0.12 value types. The actual
runtime dispatch regression and focused controls now qualify account/runtime
capture and off-main reads against an isolated fake. Matching experimental SDK
typechecking, actual native execution and the visible pane remain separate;
these source tests do not prove history delivery or installed app presentation.
