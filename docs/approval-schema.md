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
  "action": "faceAction",
  "payload": { "page": "inbox", "row": "<approval-id>", "action": "approve" },
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
| `faceAction` | `page`, `row`, `action`, optional `value`: the row's own call runs through the person's door as this paired phone. Every card is its matter's Inbox row (`page` `inbox`, `row` the matter id: an approval's own id, `interaction:<id>` for an ask), so this is how an approval or an ask is answered. |
| `approveApproval`, `rejectApproval`, `cancelApproval` | Installed builds 61/63: `approvalId` reaches the same approval transaction with verified signed-phone provenance; decision and execution remain separate, with `approvalJSON` and `approvalReadbackRevision` readback. |
| `inboxAction`, `interaction_action` | Installed builds 61/63: `itemId`/`actionId` translate to the canonical Inbox row; sealed interaction answers bind `sessionID`, `interactionID`, `revision`, `action`, optional `choice`/`scope`. They select that row's answer or check saved owner state. Credential-bearing answers refuse with protected Mac entry as the remedy. |
| `approveMemoryProposal`, `rejectMemoryProposal` | `proposalId`: decide a staged memory proposal. |
| `submitDeskTask` | `title`, `objective`: create a Desk item and start a line of theirs that carries it ([Desk](DESK.md)). |
| `set_trust_policy` | Validated trust change through the Mac policy owner. |
| `mac_control` | Remote Mac control through its policy/dispatch owner. |

These are iOS wire actions, not the agent's tool names. The agent uses its one
door, `app`, and its action registry.

## Resolution and execution

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

An exact pending approval can also be answered by the agent on the person's own
authenticated Mac-chat, paired-phone or allowlisted Telegram message. The shared
[decision authority](ONE_DOOR.md#authority-and-receipts) refuses helpers,
wakes and peer-steered turns; permanent deletion stays tap-only by declared tool
class. `resolutionProvenance` adds channel `person_message`, decidedBy
`agent_on_person_message`, canonical `sessionID` and `messageID`, and `door`
containing the verifying transport provenance. This is a message decision, never
a tap. Once another message joins the running turn, the exact authorizing
message cannot be established and the decision refuses; missing or mismatched
open-turn evidence also refuses. Neither the opener nor the latest row is guessed
as the authorizer. A fresh message after that turn ends can carry the decision.
The approval record, decision experience, card detail and retained history
carry that attribution. Phone action and `ApprovalRequest` wire fields remain
unchanged, including installed builds 61/63. Message decisions require a fresh
turn with only Inbox reads or approval-decision calls; any other started call,
missing execution evidence or checkpoint resume refuses with the fresh-message
or tap remedy. Outside text from an earlier turn can still be in context: this
is the agent's judgment on the authenticated message, not proof of the person's intent.

An approval coordinator resolves its data root once at construction. Resolution,
execution fences, domain replay, browser recovery and result/report annotations
use that root; an explicit store argument takes precedence for that operation.

Inline cards use the same resolver for verification and continuation. Phone
answers translate into the canonical Inbox row's door calls with verified
device provenance; there is no separate phone card executor. Credential entry
and macOS prompting stay with the protected local adapter.
The deployed phone's Check again uses non-destructive owner verification: an
unverified check writes no failure or revision and never interrupts a running
sign-in. Its reply classifies committed card readback, not whether a local watch
can retire: a moved revision still open stays pending/unknown. Missing or
unreadable readback stays outcome-unknown; only a saved result confirms completion.
The canonical matter displays the card owner's complete consent scope,
persistence and the recorded Not now consequence on every door before offering an answer.
Telegram's prompt reads those same matter words; it does not compose a shorter
request from the transcript's reason beside the canonical row's buttons.
Long consent is delivered in ordered parts of at most 4,000 UTF-16 units; only
the last part carries answer buttons, and its receipt accepts the Telegram door
after all parts returned. A partial send remains unknown and cannot be
automatically resent, including when a later part is explicitly refused.
Secret grants name allowed and removed destinations and sign-in endpoint hosts;
credential values stay confined to protected Mac entry and their credential owner.
Descriptor (connector names and saved Trust), permission-control category
verification, ask-door, data-root life and
Keychain/program-identity reads suspend the caller and run off MainActor. Secret
verification returns only a credential-free verdict, using one checked entry;
an unreadable credential or executable identity stays unverified.
The card payload and recorded-envelope decode and the live pairing witness
check also run off MainActor, including conversation recovery.
Running Mac chrome also shows the owner's transient sign-in instructions,
including a device authorization code and verification URL when required. Those
instructions are not filed in the matter, transcript or phone snapshot.
Local controls carry the running revision they acquired into completion and
model selection, just as phone controls do. One open ask is retained per
conversation, originating tool and subject (kind, targets, access mode, secret
grant and the full options, including labels and detail; choices also match the
question text, with a subject digest made before display clipping/redaction).
An unreadable interaction row is skipped for matching and names
its own repair, without blocking other asks. A re-ask returns that card under the
transcript lock, preserving its continuation and the same inbox/Telegram identity. Different
subjects remain visible. An unchanged reuse with no new tool receipt and no
matter-face change leaves transcript generations and change/completion
notifications untouched. The former capability-wide filing cache and
cross-conversation reuse are removed; transcript state is the one owner.
A raised request requires both its transcript filing and its matter filing to
succeed. A matter failure preserves the transcript and continuation, returns
filing failure without success publication, and retains the redacted cause and
repair lever in `interaction.raise:<id>` debt. Raising that same request after
repair reuses its transcript row and settles that debt only after matter filing.
Provider asks coordinate across conversations: the replacement is durably filed
or reused before older asks are superseded. An unreadable or damaged sibling
stays byte-preserved with an owed repair; it cannot prevent the new ask from
being filed, and no clean-feed replacement is attempted against damaged rows.
Transcript and mirror-ownership read errors refuse the operation with their
cause. They never prove a card completed or that the agent may answer User's card.
Provider requests verify exactly their canonical target account; a ready ChatGPT
sign-in does not settle an OpenAI API-key request or change its route.
Archive and Dismiss of a pending approval are decisions too: they require the
person's exact-call authority and verified door provenance, just like Approve
and Deny. Agent withdrawal remains a cancellation of its own ask. The native
inbox effect refuses a decision without that provenance; it never invents Mac attribution.
Connector, provider and permission verification preserve the owning read error
instead of reporting missing setup. A failed control acquisition is shown on the
card; a failed inbox speech delivery keeps that same delivery owed. Whether a
card still needs the person is one rule, the card's own `needsAttention` read
from its saved state: open, or failed with a control that can
retry it. The inbox pointer, Today, the phone and the owed decision all follow
it. Recovery may ask the resolver to verify an open setup against its owner,
reading existing Mail readiness without initiating a person's Check Mail action;
the resolver commits completion and settles its continuation before the resulting
face is filed. History and Inbox filing read saved cards, never a fabricated
completion. Later readiness preserves a saved Not now and its consequence.
A failure no control on this build can retry is let go, so its pointer archives
instead of drawing blank. Stale
revision callbacks are settled no-ops and never create repair debt. Local
control watches retire missing or moved cards without claiming their effects
succeeded, and each watch is checked even when another remains unverified.
An inbox speech act addresses the card's own conversation, or the checked
current anchor when the card has no conversation. A missing or unreadable
destination refuses before marking the card read; read follows acceptance.

Consent and continuation have separate outcomes: a continuation failure keeps
the verified consent and replay checkpoint, records its own reason, and offers
Try again on the same canonical history row. That tap retries only continuation;
setup and a checkpointed effect are never repeated. The tap's reply reports a
continuation failure ahead of the earlier successful consent; missing readback
stays outcome-unknown. Relaunch leaves a named
continuation failure for explicit retry. The owner may update a settled matter's
face without reopening its decision or deliveries. A decided or finished card's
history row leads with its saved outcome in words: Declined / Not now and its
consequence, Failed and its cause, Unknown and what is unconfirmed, or Done and
what changed. The original request follows as context. Mac Inbox, conversation
cards and the phone's `faces.json` carry that same row, including after relaunch.
Approval history reads the retained approval owner's decision/execution receipt,
without persisting another copy; a missing or unreadable receipt says Unknown
with its cause while other history remains visible. An unfamiliar interaction
state can explain an existing row but cannot create or settle a decision.
Saved terminal decisions remain intact when setup later becomes ready; open
cards keep their existing presentation and controls.
An approved action with an unknown execution result retains attention rather
than a completed tone.

Permission requests accept `read`, `write` and `read_write`; supplied nonempty
unknown modes are refused before reading or constructing a grant. Stored scope,
access mode and control location reject unknown executable enum values. Optional
omitted access modes in retained cards remain readable. Inline replay requires
the recorded originating envelope and `originTurnId`. Direct card filing requires
the held turn and envelope and uses them for continuation stamping and the transcript
row. Both card writers share that stamp; the phone signature witness binds the
originating act along with the envelope and replay input. The envelope codec
retains `declaredRemote` as provenance (a Boolean or absent), never a saved
signature verdict; malformed remoteness makes the envelope unavailable. A missing act or
origin refuses continuation with the card left retryable; there is no reconstruction
from the answering turn. Only the matching act in the same session can receive
a hand-back, checked against the open-turn owner. Every replay installs the
card's envelope, even when a live host supplies its other turn parts. A busy
Mac admission refuses a standalone card continuation with its replay checkpoint
retained for another tap; it cannot flatten the held turn into fresh queued input.
The resolving Mac/phone/Telegram door records who decided. It does not supply
replay authority. Chat approvals install the approved card's envelope (including
verified command signature) on their held host turn; bounded domain cards with
no requesting envelope execute as local approval acts. First-provider
setup records the accepted chat request's envelope even before a provider can
run; the launch-owned Input Monitoring card records its native owner and remains
nonresumable. Follow-up execution maps `chat` explicitly to the Mac profile and
refuses unsupported surfaces.
The request's complete `fileAccessCeiling` is retained on chat approval payloads
and inline continuations, compared for chat-card deduplication, and covered by
the inline phone-signature witness when present. Replay intersects it with the
held turn before any effect; an `auto` binding cannot widen it. A chat payload
without a complete recorded ceiling refuses execution and asks for a new request
from its originating conversation; scalar `fileAccess` cannot reconstruct authority. An inline card without a
recorded ceiling can use only its exact still-running host's ceiling; standalone
continuation refuses with an explanation to raise a new request in the
originating conversation. Existing records are neither repaired nor rewritten
to invent that evidence. These are additive optional fields; existing phone
decoders and their five mode IDs stay unchanged. Approval person origins use
`chat` for the Mac and `ios` for the phone; `app` is not an origin alias.
Expiry settlement joins the approval's queued experience projection, whose owner
reports persistence gaps while the unmet obligation remains owed.
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
has been removed.
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
Home and Today's native approval levers read the approval owner's redacted
`matter.title` and (on Today) `matter.summary`, then apply their display bounds.
The same rows reach the phone's face snapshot; no lever reads raw filer text
or invents a second title from the action name. Approval ids, destinations
and the person's decision provenance remain owned by the approval record.

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
GROWTH/graduation evidence before checking for external staleness. Full Mac
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
