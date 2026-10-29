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
| `approveStep`, `rejectStep` | `missionId` or `executionId`, plus a real `stepId`: decide a Workshop step. |
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
Mac Control permission descriptors read the checked saved Trust authority.
Unreadable or invalid policy makes the existing card unavailable with the
policy path and owner repair instruction; it never appears as a saved Safe
or Workspace posture. Cards cannot change the person's Trust posture.

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
Keychain storage; a legacy 0600 `icloud_pairing_secret.bin` under
`PersistenceCore.defaultDataRoot()` is migrated into the Keychain and removed
once verified.
Pairing material is published through the configured private iCloud pairing
transport. On iOS, `PairingStore` stores the shared secret in Keychain with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
The iOS sender is
`iOS/NativeAgentMobile/Sources/iCloudSyncEngine+Actions.swift`.
