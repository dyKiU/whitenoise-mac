# Native original history scope

`NativeHistoryActionScope` retains the exact SDK `HistoryTransferProtocol` or
`HistoryConsentProtocol` supplied at construction. Source continuation and
recipient approval never reconstruct an original from a displayed snapshot.
The scope reviews a snapshot before accepting its displayed revision, preserves
the fixed group/source/recipient/manifest selection, and serializes operations.
Cancellation clears presentation and calls the exact original; ignored-cancellation
or late snapshot results cannot reactivate it. Task cancellation interrupts the
original even while a native operation is blocked.

The new-feature unsupported baseline fails its actual one-test review requirement;
the unchanged test and six lifecycle/revision/selection controls then pass. These
are isolated original-protocol tests, not cryptographic network delivery. The
matching SDK original aliases have separate native acceptance evidence. Account
factory/runtime capture, Session retirement/teardown fencing and visible original
consent actions remain next, followed by full PR/installed app qualification.
