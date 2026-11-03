# NativeAgent Approval Action Schema

Signed iOS action envelopes reach the in-process Swift runtime through iCloud
Drive or the CloudKit device transport. `MacSyncEngine` owns transport
validation and transaction recovery; `MacSyncActionRouter` dispatches actions.

## Inbox action envelope (iOS → Mac)

The Drive lane writes `inbox/<msgId>.json` under the configured iCloud container.
The current sender produces:

```json
{
  "msgId": "<UUID>",
  "clientId": "<device-public-key SHA-256 hex>",
  "action": "approveApproval",
  "payload": { "approvalId": "<approval-id>" },
  "createdAt": "<ISO-8601 timestamp>",
  "protocolVersion": 2,
  "transactionId": "<UUID>",
  "devicePublicKey": "<base64 Ed25519 public key>",
  "deviceSignature": "<base64 Ed25519 signature>",
  "signature": "<HMAC-SHA256 hex>"
}
```

### Required fields

| Field | Contract |
| --- | --- |
| `msgId` | Canonical UUID spelling; message and response identity. |
| `clientId` | Current iOS sends the SHA-256 fingerprint of its device public key. |
| `action` | Router action name. |
| `payload` | String-to-string object; structured values are encoded as strings. |
| `createdAt` | ISO-8601 timestamp. New execution requires a time within ±5 minutes. |
| `protocolVersion`, `transactionId` | Optional in the decoder; current iOS sends version 2 and a separate UUID. An absent transaction ID defaults to `msgId`. |
| `devicePublicKey`, `deviceSignature` | Base64 values binding this phone to its signed action. Approval actions require a verified, paired phone. |
| `signature` | Required HMAC over the envelope, including device-signature fields. |

## Action names

| Action | Payload / purpose |
| --- | --- |
| `approveApproval`, `rejectApproval`, `cancelApproval` | `approvalId` (or `id`): resolve a durable approval. |
| `approveStep`, `rejectStep` | `executionId`, plus a real `stepId`: decide a Workshop step. Retained old records remain readable until their conversion. |
| `approveMemoryProposal`, `rejectMemoryProposal` | `proposalId`: decide a staged memory proposal. |
| `submitWorkshopTask`, `submitMission` | `title`, `objective`: submit Workshop work. |
| `set_trust_policy` | Validated trust change through the Mac policy owner. |
| `mac_control` | Remote Mac control through its policy/dispatch owner. |

These are iOS wire actions, not Agent's tool names. Agent uses the single
`app` tool and its action registry.

## Resolution and execution

Workshop step payloads freeze the resolved `tool` and `args`, plus `source_args`
for validation against the original plan schema. Replay checks the frozen call
without resolving step references again; existing payloads whose source and
resolved arguments are identical use their saved `args`.

The chat autonomy gate validates its timeout before filing a request. A timeout
must be finite, nonnegative and representable as UInt64 nanoseconds; unsupported
values throw `AutonomyGateError.invalidApprovalTimeout` without creating a card.

The Drive lane authenticates before consulting the transaction ledger.
Unsigned or invalidly signed files are quarantined without reserving message,
response or transaction identities. A matching completed transaction returns
retained evidence without executing again, even after the freshness window.
Conflicting identities and unreadable ledger records fail closed.
Freshness rejection handles only timestamps; Drive archives rejected work only
after its signed refusal is durable. Unavailable pairing material stays retryable.

Approval actions also pass `PairedPhoneStore` device authorization. A pending
phone does not gain approval authority until paired on the Mac. Resolution
carries signed-iOS provenance into the canonical approval owner.

An approval coordinator resolves its data root once at construction. Resolution,
execution fences, domain replay, browser recovery and result/report annotations
use that root; an explicit store argument takes precedence for that operation.

Local and signed-phone inline cards use the same resolver for credential,
permission and capability effects. Phone grants retain their authenticated
action and client identities; macOS prompting remains with the local adapter.
Local controls carry the running revision they acquired into completion and
model selection, just as phone controls do. One open ask is retained per
conversation, originating tool and subject (kind, targets, access mode, secret
grant and the full options, including labels and detail; choices also match the
question text, with a subject digest made before display clipping/redaction).
An unreadable interaction row is skipped for matching and names
its own repair, without blocking other asks. A re-ask returns that card under the
transcript lock, preserving its continuation and the same inbox/Telegram identity. Different
subjects remain visible. The former capability-wide filing cache and
cross-conversation reuse are removed; transcript state is the one owner.
Transcript and mirror-ownership read errors refuse the operation with their
cause. They never prove a card completed or that the agent may answer User's card.
Connector, provider and permission verification preserve the owning read error
instead of reporting missing setup. A failed control acquisition is shown on the
card; a failed inbox speech delivery keeps that same delivery owed. Stale
revision callbacks are settled no-ops and never create repair debt. Local
control watches retire missing or moved cards without claiming their effects
succeeded, and each watch is checked even when another remains unverified.
An inbox speech act addresses the card's own conversation, or the checked
current anchor when the card has no conversation. A missing or unreadable
destination refuses before marking the card read; read follows acceptance.

Permission requests accept `read`, `write` and `read_write`; supplied nonempty
unknown modes are refused before reading or constructing a grant. Stored scope,
access mode and control location reject unknown executable enum values. Optional
omitted access modes in retained cards remain readable. Inline replay requires
the recorded originating envelope. Direct card filing requires that envelope
and uses it for both continuation stamping and the transcript row. First-provider
setup records the accepted chat request's envelope even before a provider can
run; the launch-owned Input Monitoring card records its native owner and remains
nonresumable. Follow-up execution maps `chat` explicitly to the Mac profile and
refuses unsupported surfaces.
Mac Control permission descriptors read the checked saved Trust authority.
Unreadable or invalid policy makes the existing card unavailable with the
policy path and owner repair instruction; it never appears as a saved Safe
or Workspace posture. Cards cannot change the person's Trust posture.

Approval payload `peer` and authored-run `steer` records require both `sources`
and `elevated` arrays of nonempty principal strings. Valid empty arrays record
an unsteered run; missing or malformed records refuse restoration. Inline
continuations likewise require recorded `peerSources` and
`elevatedPeerSources`. A refusal preserves the saved work and its unresolved
obligations, reports the unavailable provenance, and runs no continuation;
it never invents a principal or an empty steering verdict. A claimed authored
checkpoint is saved back through its owner on provenance refusal, with
`checkpoint_preserved` reporting whether that write succeeded; a failed save
owes repair instead of claiming preservation. Previews record no repair debt.

Current owners under `Modules/NativeAgentCore/Sources/`:

| Responsibility | Source |
| --- | --- |
| Envelope identity validation | `DeviceSync/MacSyncInboxAction.swift` |
| Transport, ledger and response handling | `DeviceSync/MacSyncEngine+Inbox.swift` |
| HMAC and freshness | `DeviceSync/MacSyncEngine+Security.swift` |
| Action dispatch | `DeviceSync/MacSyncActionRouter.swift` |
| Phone authorization | `DeviceSync/PairedPhoneStore.swift` |
| Durable approvals and execution | `ApprovalInbox/`, `ApprovalTransactions/` |
| Remote Mac control | `EngineRuntime/EngineDeviceSync+Snapshots.swift` (`remoteMacControl`) |

## Approval receipts

The canonical inbox uses one strict current stored-record decoder for pending
and terminal rows, including decision/provenance invariants and the saved
authority flags. A true not-found is distinct from unavailable or malformed
authority. Conversation approval waits read that inbox using their conversation's
data root. Continuation ownership lives in the approval row alone; transcript
receipt metadata does not claim it. The empty retired approval-store importer
and unused procedure-review adapter have been removed.
Chat replay accepts only `chat_tool_approval` payloads with canonical origin
strings. Retired skill-proposal, external-send, nextgen and self-evolution
executor branches are removed after retained-data and saved-caller inventory.

Drive responses use `responses/<msgId>.json` and the
`inbox_response_<msgId>` KVS signal. Response bodies are string-to-string
objects, signed with the pairing secret. iOS verifies responses before using
them. An approval decision and the action's execution result are separate
evidence.

`ApprovalRequest.Outcome` interprets consent for turn, inline and phone cards.
Only undecided pending rows offer consent; explicit decisions, expiry (including
orphaned requests) and unavailable evidence remain distinct from execution results.

Injection and ordinary effects share the inbox's locked spend-map algorithm,
with separate files, schemas and marker fields. Live inboxes and restore select
requests and both spend files through the same root-parameterized paths.
Generic replay checks the marker's action, surface, digest and freshness and
consumes dispatch in the same locked read.
Execution receipts remain independent evidence of what ran.
Telegram approval previews redact the complete readable ask before applying
the display length bound, so clipping cannot hide a credential's shape from
the shared redactors.

Reporting accepts an approval ID and reads the record under continuation ownership;
an unreadable record fails reporting and remains eligible for reconciliation retry.
Reporting is owed only to an originating conversation or a retained delivery.
A mirrored review card does not create a reporting turn. Finished approvals
without that obligation are settled history and can leave the capped store;
approved actions still await their execution receipt before eviction.
Retention uses the same data-root-life projection as reads: previous-life
unexecuted approvals and reporting read stopped and become evictable history.
Current-life unexecuted work and unsettled reporting retain their places.

Any saved execution outcome closes replay eligibility, including failed outcomes.
Chat-tool and connector replay save returned outcomes and release execution
ownership through one awaited `settle` unit. A save failure reports its cause
and keeps the exact outcome in the process's execution owner for receipt-only
repair. Re-tapping the same decision while the app remains open retries only
that receipt, after the inbox checks the caller's resolution authority; it
never dispatches the effect again. A failed save leaves the visible card and
reports the failure to the resolving caller. Receipt repair shares execution
ownership with replay and reconciliation, so concurrent attempts cannot spend
or dispatch again. Telegram sends matching late taps through that same owner
after its identity and routing checks. Stop cannot discard the retained
outcome or start a new reporting turn. A process loss before durable receipt
storage still leaves the spent effect outcome unknown.

Domain application outcomes use the same retained receipt settlement owner.
The retired `memory.repair` truncated-row executor has no registration. Its
retirement checked retained approvals, execution fences and settlement debts;
historical completed markers remain untouched. Kind backfill remains data-gated
under [the memory contract](MEMORY_SYSTEM_MAP.md).
An application error remains owed for inspection at its domain owner; it is
never evidence that an already returned effect failed. REM application checks
Memory repair commits its one-shot outcome at `memory/repairs/executions.json`
before returning to that settlement owner. Relaunch reads the completed result
and original safety-backup path without rerunning edits. An application recorded
as started without a completed result stays unknown and owes inspection; missing
approval annotation never authorizes another repair.
An unknown application outcome remains owed for inspection at its domain owner;
it is never evidence that an already returned effect failed. A definitive
no-effect refusal is a terminal `refused` execution with `Not done: <reason>`
on the approval, so it closes the visible card and is not replayed at launch.
Part enable/disable adapters retain the owner's explicit effect evidence;
missing effect evidence remains unknown. REM application checks
the reviewed text against the canonical proposal and reconciles matching
GROWTH/graduation evidence before checking for external staleness. Exact
procedure installation returns its manifest before receipt settlement, so a
receipt failure cannot report that installation did not happen. Full Mac
kind backfill uses a persisted approval identity and creates a pending card
only for a genuinely pending record.

Telegram approval and inline prompts share the durable delivery journal at
`workflows/approvals/telegram-deliveries.json`. Dispatch is recorded before
sending; a returned result is retained through receipt-only settlement. A
dispatch left without a result after process loss stays unknown and refuses
automatic resend. A failed reconciliation scan leaves an `approval.reconcile`
repair obligation instead of reporting an empty batch.
Inline send results are recovered into their mirror receipt before checking
whether the source card is open. A closed card still owes its returned message
identity and Telegram button settlement; receipt failure remains a named repair.
Invalid saved interaction payloads remain strict decoding failures on that
card. The conversation renders that row unavailable with its own error while
its readable messages and sibling controls remain available.
Addressed inbox reads match the id before strict card decoding. A damaged
sibling does not disable an identified card; if no id matches and a physical
line cannot be parsed, absence remains unknown and the read reports that gap.
Independent card scans report each unreadable line/card and continue siblings;
complete snapshots and whole-feed mutations still require a complete valid feed.

## `signature_required` upgrade response

The iOS recovery path recognizes verified `signature_required` and
`signature_invalid` responses. It makes at most one replacement request with
fresh identities and signing. Encrypted secret payloads are not copied into a
replacement identity. An uncertain response does not authorize a fresh send.

## HMAC signing input format

Serialize the envelope with `JSONSerialization` and `.sortedKeys`, excluding
only `signature`, then compute HMAC-SHA256 with the shared pairing secret.
The Mac accepts 64 hexadecimal characters and compares normalized lowercase
values.

The device signature is separate: Ed25519 over sorted JSON excluding both
`signature` and `deviceSignature`. Its verification contract is
`Modules/NativeAgentShared/Sources/NativeAgentShared/DeviceApprovalSignature.swift`.
The outer HMAC covers the device signature too.

`PairingSecret` owns the Mac's 32-byte pairing secret in device-only
Keychain storage. `icloud_pairing_secret.bin` under
`PersistenceCore.defaultDataRoot()` names the stable Keychain account and
credential lock; its file contents are not read or migrated. Any retained file
bytes require a separate entitled authority inventory before cleanup.
Pairing material is published through the configured private iCloud pairing
transport. On iOS, `PairingStore` stores the shared secret in Keychain with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
The iOS sender is
`iOS/NativeAgentMobile/Sources/iCloudSyncEngine+Actions.swift`.
