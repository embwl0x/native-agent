# NativeAgent Approval Action Schema

_Added R10-N6. Last updated: 2026-05-08._

This document describes the JSON schema for approval action envelopes exchanged
between the iOS app and the Mac Swift runtime via iCloud Drive.

---

## Inbox action envelope (iOS → Mac)

Written by iOS to `iCloud Drive/<container>/inbox/<msgId>.json`.

```json
{
  "msgId":     "<UUID>",
  "clientId":  "ios",
  "action":    "<action-name>",
  "payload":   { "<key>": "<value>" },
  "createdAt": "<ISO-8601-timestamp>",
  "signature": "<hmac-sha256-hex>"
}
```

### Required fields

| Field       | Type              | Description |
|-------------|-------------------|-------------|
| `msgId`     | string (UUID)     | Unique per-message ID. Used for deduplication (rolling 5000-entry window persisted in `processed_ids.json`). |
| `clientId`  | string            | Always `"ios"` from the iOS app. |
| `action`    | string            | Identifies the operation (see below). |
| `payload`   | object (string→string) | Action-specific parameters (all values are strings). |
| `createdAt` | string (ISO-8601) | Client-side timestamp. Mac rejects messages older than 5 minutes. |
| `signature` | string (hex)      | HMAC-SHA256 over the canonical body (see Signing below). |

---

## Action names

Common values for the `action` field:

| Action                   | Description |
|--------------------------|-------------|
| `submitMission`          | Submit a new mission objective. |
| `approveStep`            | Approve a pending improvement/approval step. |
| `rejectStep`             | Reject a pending step. |
| `approveMemoryProposal`  | Accept a staged memory proposal. |
| `rejectMemoryProposal`   | Reject a staged memory proposal. |
| `approvePromotion`       | Accept a promotion candidate. |
| `rejectPromotion`        | Reject a promotion candidate. |
| `saveTrustPolicy`        | Write an updated trust policy JSON through the Swift app policy path. |
| `mac_control`            | Invoke a Mac-side remote-control method (shell, AppleScript, Shortcut, notify, etc.). |

---

## Resolution and execution

Approval records are durable app-owned files, not daemon memory. Resolvers must
fail closed when an approval id is stale, missing, mismatched, or already
terminal.

The execution path is derived from the signed iCloud action plus the durable
approval/action record. The Swift resolver validates the action, re-checks
policy, executes the focused handler, and writes a response/receipt back through
the iCloud response channel.

| Action family | Swift owner |
|---|---|
| iOS inbox action routing | `Sources/NativeAgentApp/MacSyncActionRouter.swift` |
| Generic approval resolve/reconcile | `Sources/NativeAgentApp/NativeClient+ApprovalExecutors.swift` |
| Memory approval resolve/reconcile | `Sources/NativeAgentApp/NativeClient+MemoryApprovalExecutors.swift` |
| Self-evolution approval apply/verify/reconcile | `Sources/NativeAgentApp/NativeClient+SelfEvolutionApproval.swift` |
| Remote Mac control policy/dispatch | `Sources/NativeAgentApp/MacSyncRemoteMacControl.swift` |

---

## Approval receipts

When the Mac resolves an approval or remote action, it records a compact receipt
covering the requested action, policy/risk reason, decision, executor result,
and any follow-up verification. iOS receives the user-facing result through
`responses/<msgId>.json` plus the `inbox_response_<msgId>` KVS ping.

---

## `signature_required` upgrade response

When the Mac receives an inbox action **without** a `signature` field (old iOS
clients), it writes a structured error response to
`iCloud Drive/<container>/responses/<msgId>.json` and pings the iOS KVS key
`inbox_response_<msgId>`.

All fields are strings (`[String: String]`) so iOS's `JSONDecoder` can parse it
without a custom schema:

```json
{
  "msgId":     "<original-msgId>",
  "ok":        "false",
  "error":     "iOS app needs upgrade to enable HMAC signing. Update via App Store / TestFlight.",
  "code":      "signature_required",
  "createdAt": "<ISO-8601-timestamp>"
}
```

**iOS recovery (R10-C3):** on receiving `code == "signature_required"`, the iOS
app re-signs the original action body with the current HMAC key and resubmits
once. If the resubmission is also rejected the user sees an error alert via the
existing `syncError` path. At most one retry is attempted to prevent loops.

Reference: `Sources/NativeAgentApp/MacSyncEngine.swift` ~line 123,
`iOS/NativeAgentMobile/Sources/iCloudSyncEngine.swift`.

---

## HMAC signing input format

The signing input is the canonical JSON serialization of the action envelope
**excluding** the `signature` field itself, with object keys sorted
(`JSONSerialization.data(withJSONObject:options:[.sortedKeys])`).

Verification on the Mac side mirrors this: the Mac reconstructs the same
canonical JSON from the parsed body (minus `signature`), computes
HMAC-SHA256 with the shared pairing secret, and compares the result to the
`signature` field in lowercase hex.

The shared secret is 32 bytes of random data generated on the Mac and
exchanged out-of-band via QR code scan or manual paste. It is stored in the iOS
Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) and on the Mac at
`~/Library/Application Support/NativeAgent/remote/pairing_secret` (0600).
