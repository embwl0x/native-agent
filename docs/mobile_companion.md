# NativeAgent mobile companion

*Current architecture as of 2026-07-28.*

The NativeAgent iPhone/iPad app is a signed remote cockpit for the Mac-owned
Swift runtime. It does not run a second agent and it does not use a LAN HTTP,
Tailscale, or web-service fallback. The Mac remains the authority for provider
calls, memory, tools, policy, Workshop execution, and durable chat history.

## What the mobile app exposes

- streaming chat, progress events, cancellation, attachments, and sessions;
- pinned conversations and transcript snapshots;
- provider, model, Think, Fast, and permission controls;
- Activity and notification inbox;
- approval decisions;
- Workshop tasks and execution status;
- memories and proposals;
- a combined Skills & Tools surface: skill lifecycle plus the Mac's current
  trust-aware tool catalog, load state, and effective autonomy;
- connectors, runtime health, and recent runs;
- organism living status and bounded turn summaries;
- signed Mac actions with terminal response receipts;
- APNS lock-screen notifications.
- system-following, light, and dark appearance modes, with decorative motion
  respecting the iOS Reduce Motion setting.

The iOS app reads targeted snapshots for each surface instead of decoding one
giant state bundle on every refresh.

## Transport architecture

NativeAgent has one shared `DeviceSyncTransport` seam with two Apple-native
implementations.

| Transport | Intended use | Data path |
|---|---|---|
| KVS + iCloud Drive | Personal/local builds and compatibility fallback | KVS wake/progress keys plus signed Drive messages, snapshots, inbox actions, responses, and transactions |
| CloudKit private database | Entitled builds that select CloudKit | Lossless signed `BridgeMessage` records, pairing/status records, cursor-based drains, subscriptions, and silent-push wakeups |

Selection order is:

1. `NATIVE_AGENT_DEVICE_SYNC=cloudkit|kvs` runtime override;
2. the build's `NativeAgentDeviceSync` Info.plist value;
3. fail-safe default to `kvs`.

CloudKit is touched only when the selected build's signed entitlements actually
grant CloudKit. If preflight fails, NativeAgent stays on the legacy KVS/Drive
transport instead of constructing `CKContainer` and risking a launch crash.

The canonical direct-download public DMG lane uses a Developer ID distribution
profile authorizing the same production CloudKit container as the App Store iOS
app. The signed entitlement contract, production record schema, exact query
subscriptions, same-account pairing, chat/snapshot continuity, and repeated
locked-screen alerts have all been proven on the release family. A standalone
build without iCloud entitlements remains available for source/local use, but
it cannot pair with the App Store companion.

## Signed message model

Both transports carry the same `BridgeMessage` wire object:

- unique message ID and timestamp;
- sender and session identity;
- message kind, text, attachments, and compact metadata;
- HMAC-SHA256 signature generated from the paired secret.

The receiver verifies the signature, deduplicates by message ID, rejects stale
or malformed messages, and records delivery. CloudKit stores the complete
encoded message as authoritative `payloadJSON` plus scalar fields for query and
deduplication.

## Chat flow

```text
iPhone accepts a user turn
  -> signs BridgeMessage
  -> sends through active device transport
  -> Mac verifies and binds the exact iOS session
  -> shared ChatOrchestration runs provider + Fluid Context + tools + policy
  -> Mac emits signed received/thinking/tool/text_delta/final/error events
  -> iPhone merges deltas transactionally into the same conversation
```

The Mac and iPhone do not maintain separate agent memories or provider policy.
The phone is another surface over the same Mac-owned session and runtime.

## Remote actions and transaction ledger

iOS writes signed action envelopes for supported Mac operations. Each accepted
action carries a transaction ID and moves through durable states. A send is not
reported as successful merely because a file write was attempted:

1. iOS acquires the action-send ownership gate.
2. The signed envelope and pending transaction state are written.
3. The Mac verifies, dispatches through the normal runtime/policy boundary, and
   writes a response plus terminal transaction state.
4. iOS reads the terminal state back before showing success.
5. Write timeout or persistence failure releases ownership and reports failure.

Repeated taps are idempotent. Remote actions do not bypass approval, connector,
file, Mac Control, or external-send rules.

## Snapshot plane

The Mac publishes compact JSON snapshots for surfaces that need read-only
state, including:

- health, trust, providers, and model preferences;
- sessions, pinned chats, and bounded transcripts;
- Workshop, approvals, activity, and inbox;
- memory, skills, connectors, and runs;
- the current Mac-owned tool catalog for read-only phone inspection;
- organism living status and turn summaries.

KVS `snapshot_updated` is a wake hint; iCloud Drive remains the durable source
for the KVS/Drive mode. Snapshot writers are digest-aware and separate light
updates from heavier state so the phone does not create constant Mac I/O.
The tool snapshot is produced from the same dispatcher and TrustCenter-aware
catalog used by Mac chat. It is presentation data only: the phone does not own
tool registration, autonomy, approval, or execution authority.

## Appearance and privacy packaging

The app defaults to the system appearance and lets the user select System,
Light, or Dark in Settings. The preference is applied at the app root, including
pairing and onboarding. Shared decorative animation observes Reduce Motion.

The iOS bundle includes `PrivacyInfo.xcprivacy` for the required-reason APIs
NativeAgent actually uses. The generated `Info.plist` declares only active
protected capabilities; obsolete camera and local-network usage descriptions
are intentionally absent. Before App Store submission, validate the final
Apple-signed archive's privacy report and App Store Connect privacy answers
against the shipped binary and production services.

## APNS

The phone registers its APNS token and sends the token metadata to the Mac over
the signed pairing channel. The Mac sends APNS directly from Swift; there is no
external notification daemon.

- The registered token carries the iOS bundle ID and development/production
  environment.
- The Mac derives topic and environment from that signed registration by
  default.
- Urgent notifications can use the time-sensitive interruption level.
- Successful sends append local receipts under
  `data/mobile_push/receipts.jsonl`.

The public credential-free lane uses CloudKit query subscriptions for sync and
lock-screen alerts. Ordinary chat is stored as `NAChatMessage` and matches one
broad silent subscription. Explicit alerts are stored as `NANotification` and
match one visual subscription. The record-type split prevents CloudKit from
coalescing a notification's visual projection with a competing silent
projection. iOS registers the visual subscription first and removes the retired
overlapping subscription on upgrade. A same-iCloud-account Mac/iPhone pair
therefore needs no hosted APNS provider. Direct APNS remains an optional
private/self-hosted parallel route.

The visual subscription is capped at CloudKit's three-key `desiredKeys` limit.
The iPhone publishes a versioned visual-capability status only after exact
registration succeeds and retries on foreground activation after a failure.
The Mac may report the visual lane eligible only after receiving that
paired-phone status; successful record persistence alone proves durable
delivery, not lock-screen readiness.

Before the first production release for a subscription contract, create the
exact query subscription from a Development-signed client and deploy the
Development schema to Production in CloudKit Console. A TestFlight/App Store
client cannot create a brand-new subscription shape directly in Production.
Record-type parity alone does not prove that this deployment happened.

See [apns-push.md](apns-push.md) for the untracked local credential file and
live verification flag.

## Pairing and setup

1. Sign the Mac and iOS apps under compatible Apple identities and configure
   the same iCloud container.
2. Enable the required iCloud services in both entitlements. CloudKit mode also
   requires the CloudKit service grant, deployed private-database schema, and
   any exact query-subscription contracts promoted from Development.
3. Enable iCloud Drive on the Mac and phone for KVS/Drive mode.
4. Build the iOS project from
   `iOS/NativeAgentMobile/NativeAgentMobile.xcodeproj`.
5. In NativeAgent on the Mac, open the pairing surface and pair the phone. The
   secret is transferred through the configured Apple-native pairing plane.
6. Confirm the phone reports signed transport ready before sending actions.

Example simulator build:

```bash
xcodebuild \
  -project iOS/NativeAgentMobile/NativeAgentMobile.xcodeproj \
  -scheme NativeAgentMobile \
  -destination 'platform=iOS Simulator,name=<installed simulator>' \
  build
```

Use an installed destination from `xcrun simctl list devices available`; do not
hardcode a simulator that is not present.

## Failure behavior

| Failure | Expected behavior |
|---|---|
| iCloud account unavailable | Surface reports the account state; messages/actions remain unsent rather than changing transports silently. |
| CloudKit selected without entitlement | Preflight refuses CloudKit and stays on KVS/Drive; `CKContainer` is never touched. |
| Pairing secret missing or invalid | Signed chat/actions pause and the UI asks the user to pair again. |
| Snapshot/message not downloaded | The item is requested and retried through the active sync lane. |
| Action ledger write times out | Send ownership is released and failure is shown; success is not fabricated. |
| Mac unavailable | Phone retains honest pending/offline state until transport and Mac runtime recover. |
| APNS unavailable | Durable iCloud state remains; push failure is receipted and does not imply message loss. |

## Source map

| Area | Owner |
|---|---|
| Shared wire and transport | `Modules/NativeAgentShared/Sources/NativeAgentShared/` |
| CloudKit implementation and crash guard | `CloudKitDeviceTransport.swift`, `DeviceCloudKitPreflight.swift` |
| Mac chat transport | `Sources/NativeAgentApp/iCloudBridge.swift` |
| Mac snapshots/actions | `MacSyncEngine+*.swift`, `AppDelegate+ICloudRuntimeForwarding.swift` |
| iOS transport | `iOS/NativeAgentMobile/Sources/iCloudBridge.swift` |
| iOS snapshot/actions | `iCloudSyncEngine+*.swift` |
| iOS chat state | `ChatStore+*.swift` |
| iOS app/APNS callbacks | `NativeAgentMobileApp.swift` |
| Mac APNS sender | `SwiftNativeAPNS.swift` |
