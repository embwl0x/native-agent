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
| `approvePromotion`, `rejectPromotion` | `candidateId`: decide a promotion. |
| `submitWorkshopTask`, `submitMission` | `title`, `objective`: submit Workshop work. |
| `set_trust_policy` | Validated trust change through the Mac policy owner. |
| `mac_control` | Remote Mac control through its policy/dispatch owner. |

These are iOS wire actions, not Agent's tool names. Agent uses the single
`app` tool and its action registry.

## Resolution and execution

The Drive lane authenticates before consulting the transaction ledger.
Unsigned or invalidly signed files are quarantined without reserving message,
response or transaction identities. A matching completed transaction returns
retained evidence without executing again, even after the freshness window.
Conflicting identities and unreadable ledger records fail closed.

Approval actions also pass `PairedPhoneStore` device authorization. A pending
phone does not gain approval authority until paired on the Mac. Resolution
carries signed-iOS provenance into the canonical approval owner.

Current owners under `Modules/NativeAgentCore/Sources/`:

| Responsibility | Source |
| --- | --- |
| Envelope identity validation | `DeviceSync/MacSyncInboxAction.swift` |
| Transport, ledger and response handling | `DeviceSync/MacSyncEngine+Inbox.swift` |
| HMAC and freshness | `DeviceSync/MacSyncEngine+Security.swift` |
| Action dispatch | `DeviceSync/MacSyncActionRouter.swift` |
| Phone authorization | `DeviceSync/PairedPhoneStore.swift` |
| Durable approvals and execution | `ApprovalInbox/`, `ApprovalTransactions/` |
| Remote Mac control | `DeviceSync/MacSyncRemoteMacControl.swift` |

## Approval receipts

Drive responses use `responses/<msgId>.json` and the
`inbox_response_<msgId>` KVS signal. Response bodies are string-to-string
objects, signed with the pairing secret. iOS verifies responses before using
them. An approval decision and the action's execution result are separate
evidence.

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

`PairingSecretManager` owns the Mac's regular, 0600, 32-byte
`icloud_pairing_secret.bin` under `PersistenceCore.defaultDataRoot()`.
Pairing material is published through the configured private iCloud pairing
transport. On iOS, `PairingStore` stores the shared secret in Keychain with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
The iOS sender is
`iOS/NativeAgentMobile/Sources/iCloudSyncEngine+Actions.swift`.
