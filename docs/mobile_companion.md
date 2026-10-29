# NativeAgent mobile companion

The iPhone/iPad app is a surface of the Mac-owned agent. Keep the Mac awake
with NativeAgent open to process new work. The runtime is in
`EngineRuntime` and `ChatTurnRuntime`; mobile sync does not create another
brain. Agent's tool interface remains the single `app` tool:
`app {}` opens their home, while `page`, `item`, `find`, `action` and
`script` reach its contents and actions.

## What the mobile app exposes

The main tabs are **Chat**, **Activity**, **Memories**, **Desk**, and **More**.
More follows the phone's surface layout: Rooms holds Scheduler, Helpers, Agents,
Desk tasks, Skills & Tools, Personality, Connectors and Trust; Setup opens Settings;
Power user holds deeper views. Settings nests Telegram, Providers and Mac settings,
including Mac Integration.

Self-Improvement points to the Mac; the phone has no training-proposal queue.
Memory reviews and approval decisions remain on the phone, and Trust owns dream
and REM settings. The Mac still publishes an empty training-proposal tombstone
for older phones.

Chat supports sessions, streaming replies, queued sends and attachments.
Its shared sync transcript projection owns versioned snapshots, history pages
and live bridge updates by row/run identity. Version checks read retained index
rows without preparing conversation titles or navigation. Admitted live and phone replies
share terminal and delta mutations; only visible replies produce UI effects.
Snapshots and history use one concrete shared transport row, metadata and
attachment values. Phone decoding keeps its required-field checks; canonical
disk rows retain their tolerant parsing and raw provenance handling in core.
The phone persists unfinished
requests and attachment bytes in `ChatPendingExchange.request`; signed expiry
retains that request for “Send now”. Older expiry-only requests migrate on decode.
It does not cache settled transcripts.
Saved replies, including failures, settle the matching pending run. Regeneration
keeps the previous answer visible until the Mac publishes its replacement.
One store-owned catch-up loop serves pending replies; silence deadlines stay per exchange.
Session changes retire visible callbacks and waits without deleting durable exchanges or signed sends.
A matched full message stays full when a snapshot's truncation prefix agrees,
independently of history membership and unrelated transcript generation changes.
Approval, inbox and memory readbacks stay in the shared projection until a
Mac snapshot revision acknowledges them. Mac capture revisions order those
reads and removals; phone request or arrival order does not. Model choices use
the checked routing owner's committed revision across catalog, snapshot and
action delivery; an acknowledgment never creates a second pending fence.
The selection command validates the response and adopts the shared selection directly.
Skills & Tools reads Mac-published snapshots through one refresh shared by both
pages; its Tools view does not load tools into Agent's context. Settings offers
System, Light and Dark appearance.
The [Share extension](ios-sharing.md) adds items from other apps to Chat.
Native Shortcuts offer Ask, Remember, Approve, Status and Quick Ask; see
[Siri and notification actions](siri-notification-actions.md#iphone-and-ipad).

Mac Tools offers notifications, Spotlight search and output-volume targets.
`PhoneMacControlAction` owns executable method/path support for the phone and
Mac dispatcher. Volume keeps the signed `system`/`volume`/`value` envelope and
dispatches to MacControl's `volume` executor with a numeric `level`. Run Shortcut,
Lock screen and Sleep display have no native executors and are removed, along
with their send helpers and retry cards. Existing Trust and Full Mac gates remain
with their owners; the policy snapshot is not evidence of route support.
Connector rows own toggle eligibility: local files or a supported setup wizard,
excluding browser and Telegram. Mac controls and phone readbacks use that fact.

## Pairing and setup

Use the same Apple Account on the Mac and phone:

1. Open the Mac pairing page, available under **Connectors → iPhone** in the
   Mac rail, and **Pair with Mac** on the phone.
2. Wait for the pairing key to arrive through iCloud. Tap **Check for Mac** if
   it has not arrived; tap **Connect** when available.
3. Match **This phone’s code** to the waiting device on the Mac and choose
   **Pair** there. Then tap **Connect** on the phone again.
4. Keep both apps open until the Mac confirms the connection.

`PairingSecret` owns the shared secret; `PairedPhoneStore` owns the
Mac's device records. The phone also has a signing identity for device approval
decisions. See [iPhone approval pairing](ios-device-pairing.md).

Each device projects its evidence directly into `NAPhoneConnection`: pairing,
transport and accepted exchange. Phone headers, connection details and
accessibility read that assessment's facts and headline. Send eligibility uses
pairing, transport and network evidence independently of Mac silence.

For source builds, generate `iOS/NativeAgentMobile/NativeAgentMobile.xcodeproj`
from `iOS/NativeAgentMobile/project.yml` with XcodeGen, then build and install
the app with compatible signing and container configuration. The Release
configuration requests production CloudKit and APNS. Public Mac release
configuration is covered in [Release setup](release_setup.md).

## Transport architecture

The shared `CloudKitDeviceTransport` owns CloudKit private-database transport;
the bridges separately own KVS/iCloud Drive transport. Selection uses
`NATIVE_AGENT_DEVICE_SYNC=cloudkit|kvs`, then the build's
`NativeAgentDeviceSync` Info.plist value, then `kvs`. The iOS project selects
CloudKit. The shared factory alone constructs a CloudKit transport, after
`DeviceCloudKitPreflight` admits the service and exact container entitlements.

`BridgeMessage` carries message/session identity, text, attachments, metadata
and an HMAC signature. CloudKit uses inline `payloadJSON` within the 800 KiB
record-value budget. Larger qualifying attachment envelopes use pairing-encrypted
`payloadAsset` (48 MiB encoded payload, 10,000,000 bytes per file; scalar fields
still fit inline). Mac-to-phone asset messages also carry a reduced signed
`payloadJSON` reading copy for older readers. The bridges handle signed chat and
delivery; `MacSyncEngine` handles snapshots and remote actions.

Mac routing and the phone Providers page share `ProviderSurfaceGroups` in
NativeAgentShared for the three model choices, membership, labels and captions;
`ProviderSurfaceLabel` classifies known, unrecognized and malformed surface keys.

The Drive inbox authenticates envelopes before claiming their filenames. An
existing processing claim is preserved: identical authenticated bytes coalesce;
conflicting or invalid incoming bytes are preserved under their digest in
`processed`, with conflicts reported. A queued handler keeps its claimed path.

The phone dispatches Drive and CloudKit messages through one verification and
consumer boundary. Accepted phone requests, action responses, notifications and chat
share one seen-ID/archive settlement tail. Notifications schedule and actions persist
before consumption; chat callbacks follow archival and the lifecycle check. CloudKit
consumption and Drive archival are separate receipts; foreign Drive files stay put.

Durable delivery receipts cover terminal replies, actions and notifications.
Ephemeral text deltas, progress, notices and tool presentation do not append or
rewrite that journal; existing receipt bytes and confirmation semantics remain.

Each phone action returns its own verified response or throws its own typed
failure. `responseUnconfirmed` distinguishes response and transaction deadlines.
The shared sync banner is presentation only; overlapping actions never recover
their error from it. Signature verification keeps its bounded wait/recovery path,
and canonical readbacks precede rejection presentation.

Owner-waiting Desk notifications seed their baseline only when
`notify/needs_user_edge.json` is absent. An unreadable or invalid existing store
reports unavailability, preserves its bytes and leaves the edge pending for a
later evaluation after repair.

The text coalescer accumulates deltas and emits full-text replacements; final answers take precedence.
Incoming turns publish these snapshots, progress, tool presentation and notices through one retained sender, conflated by channel. Stream
consumption never waits on those sends. Before a terminal reply, the sender
discards unsent optional values and joins its admitted send. Transport wake
nudges use the same retained, conflated mechanism outside the send's return
path; text deltas never schedule the Drive retry-nudge plan.

## Remote actions and snapshots

The phone sends signed `NativeAgentShared.InboxAction` envelopes and waits for Mac responses.
The signed response carries the approval owner's `result_class` through string serialization; Mac and iPhone transaction settlement share `InboxAction.responseTransactionState`, preserving approval waits and unknown execution independently of decision acceptance.
Remote cognition consumes that same verdict for provider-failure observations.
The phone normalizes older responses at ingress, renders that verdict, and checks
applied state and exact selection tuples separately. Transport success proves no completion. An `outcome_unknown` ledger row has already dispatched; redelivery replays its retained signed response without executing the action again.
`iCloudSyncEngine+Actions.swift` owns submission and verified response waiting;
`Transactions` owns pending envelopes, pairing reconciliation and verified persistence.
`Commands` sends subject commands. `MacSyncEngine+Security.swift` verifies signatures
before dispatch. Pairing does not replace action-specific authority checks.

The agent can ask the paired phone through `app` action `phone.request` for
`location.current`, `photo.pick` or `photo.capture`; `phone.location` asks only
for location. Keep NativeAgent active on the phone and choose **Share location**,
**Choose photo** or **Open camera**, or cancel. Location and camera permissions
apply. Requests use CloudKit, one at a time, and expire after
`wait_seconds` (1–120, default 60; `phone.location` uses 20). A Mac timeout ends
its wait; it does not prove the request was undelivered or undo a phone action.

The Mac publishes separate snapshots for sessions, trust/providers, approvals,
memory, skills, tools and other mobile views. Workshop rows cross the snapshot
boundary as shared typed values; the Mac computes their approval state.
All snapshot scopes hold one writer through publication and staleness bookkeeping.
Publication carries committed wire bytes and reads only unchanged files; scope selects payloads.
Drive initializes through `setup(docsURL:)`; CloudKit initializes its local
snapshot and mailbox directories through `enableCloudKitSnapshotCache()`.
Drive setup, outbox/archive batches, response reads and retained action files run
through Shared `VolumeIO`; `PhoneSigningIdentity` owns asynchronous signing.
`iCloudSyncEngine+Snapshots.swift` composes refresh through Shared's `LatestRead`;
`SnapshotReading` owns replica/byte decoding and `Transcripts` owns reconciliation/history:
full, lightweight and targeted readers share each snapshot's owner. Full and
lightweight reads share one lightweight adoption body; full and Activity reads
share independent Activity publication bodies. Activity publishes Inbox and work overview
once through the Inbox owner before queuing Workshop/Memory reads; push recovery records
Inbox acceptance immediately. A narrow read cannot retire another snapshot's pending
read. Settings share one `LatestRead`; admitted saves invalidate pending reads
and successful row readbacks publish through `write`. Publication advances only;
each read returns its own result. Lifecycle guards protect transport/root replacement.
Snapshot loaders return value and health together; only accepted publication updates
the engine's diagnostics. Refresh outcomes carry the diagnostic text from that acceptance.
The phone displays Mac-owned state without separate tool or policy authority.
Desk kinds and statuses live in Shared. The phone derives status choices from
that vocabulary, keeping an existing blocked value visible without offering it as a destination.

## Notifications

The phone sends its APNS registration to the Mac. Direct APNS owns remote
alerts; CloudKit subscriptions wake sync silently. When the phone processes a
signed bridge notification, it may post a local alert unless direct APNS
already accepted that event for the device. Delivery receipts do not establish
that a banner appeared. See [APNS push](apns-push.md) for configuration and
the current notification contract.

Notification taps persist one destination with its screen and applicable chat,
Desk or directed-task identity. ContentView consumes it once and hands the
identity to the destination view, including on cold launch.

Mac and phone notices use NativeAgentShared's `SystemToastCenter`, with separate
queue instances and platform rendering. Replacing an ID cancels its prior timer;
invalid durations replace the Mac notice with a sticky error and leave the phone
notice sticky. Severity defaults are 3/5/8/3 seconds.

## Source map

| Area | Owner |
|---|---|
| Shared transport and wire format | `Modules/NativeAgentShared/Sources/NativeAgentShared/DeviceSyncTransport.swift` |
| CloudKit transport/preflight | `CloudKitDeviceTransport.swift`, `DeviceCloudKitPreflight.swift` in the same shared directory |
| Mac chat bridge | `Modules/NativeAgentCore/Sources/DeviceSync/iCloudBridge.swift` |
| Mac pairing, snapshots and actions | `Modules/NativeAgentCore/Sources/DeviceSync/` |
| iOS admission/delivery, CloudKit and Drive | `iOS/NativeAgentMobile/Sources/iCloudBridge.swift`, `iCloudBridge+CloudKit.swift`, `iCloudBridge+Drive.swift` |
| iOS snapshot/action engine | `iOS/NativeAgentMobile/Sources/iCloudSyncEngine+*.swift` |
| iOS chat and share import | `iOS/NativeAgentMobile/Sources/ChatStore+*.swift` |
