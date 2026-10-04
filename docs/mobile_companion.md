# NativeAgent mobile companion

The iPhone/iPad app is a surface of the Mac-owned agent. Keep the Mac awake
with NativeAgent open to process new work. The runtime is in
`EngineRuntime` and `ChatTurnRuntime`; mobile sync does not create another
brain. Agent's tool interface remains the single `app` tool:
`app {}` opens their home, while `page`, `item`, `find`, `action` and
`script` reach its contents and actions.

## What the mobile app exposes

The main tabs are **Chat**, **Activity**, **Memories**, **Desk**, and **More**.
More includes Scheduler, Helpers, Agents, Desk tasks, Skills & Tools,
Personality, Connectors, Trust, Telegram, Mac Integration, Providers and Settings.

Chat supports sessions, streaming replies, queued sends and attachments.
Skills & Tools reads Mac-published snapshots; its Tools view does not load
tools into Agent's context. Settings offers System, Light and Dark appearance.
The [Share extension](ios-sharing.md) adds items from other apps to Chat.

## Pairing and setup

Use the same Apple Account on the Mac and phone:

1. Open the Mac pairing page, available under **Connectors → iPhone** in the
   Mac rail, and **Pair with Mac** on the phone.
2. Wait for the pairing key to arrive through iCloud. Tap **Check for Mac** if
   it has not arrived; tap **Connect** when available.
3. Match **This phone’s code** to the waiting device on the Mac and choose
   **Pair** there. Then tap **Connect** on the phone again.
4. Keep both apps open until the Mac confirms the connection.

`PairingSecretManager` owns the shared secret; `PairedPhoneStore` owns the
Mac's device records. The phone also has a signing identity for device approval
decisions. See [iPhone approval pairing](ios-device-pairing.md).

For source builds, generate `iOS/NativeAgentMobile/NativeAgentMobile.xcodeproj`
from `iOS/NativeAgentMobile/project.yml` with XcodeGen, then build and install
the app with compatible signing and container configuration. The Release
configuration requests production CloudKit and APNS. Public Mac release
configuration is covered in [Release setup](release_setup.md).

## Transport architecture

The shared `DeviceSyncTransport` contract supports CloudKit private-database
transport and KVS/iCloud Drive compatibility transport. Selection uses
`NATIVE_AGENT_DEVICE_SYNC=cloudkit|kvs`, then the build's
`NativeAgentDeviceSync` Info.plist value, then `kvs`. The iOS project selects
CloudKit. `DeviceCloudKitPreflight` checks entitlement availability before
constructing a CloudKit transport.

`BridgeMessage` carries message/session identity, text, attachments, metadata
and an HMAC signature. CloudKit stores the complete encoded object in
`payloadJSON`. The bridges handle signed chat and delivery; `MacSyncEngine`
handles snapshots and remote actions.

## Remote actions and snapshots

The phone sends signed action envelopes and waits for Mac responses.
`iCloudSyncEngine+Actions.swift` owns send serialization and transaction
recovery; `MacSyncEngine+Security.swift` verifies the action signature before
dispatch. Pairing does not replace action-specific authority checks.

The Mac publishes separate snapshots for sessions, trust/providers, approvals,
memory, skills, tools and other mobile views.
`iCloudSyncEngine+Snapshots.swift` reads them on the phone. The phone displays
Mac-owned state rather than maintaining a separate tool or policy authority.

## Notifications

The phone sends its APNS registration to the Mac. Direct APNS owns remote
alerts; CloudKit subscriptions wake sync silently. When the phone processes a
signed bridge notification, it may post a local alert unless direct APNS
already accepted that event for the device. Delivery receipts do not establish
that a banner appeared. See [APNS push](apns-push.md) for configuration and
the current notification contract.

## Source map

| Area | Owner |
|---|---|
| Shared transport and wire format | `Modules/NativeAgentShared/Sources/NativeAgentShared/DeviceSyncTransport.swift` |
| CloudKit transport/preflight | `CloudKitDeviceTransport.swift`, `DeviceCloudKitPreflight.swift` in the same shared directory |
| Mac chat bridge | `Modules/NativeAgentCore/Sources/DeviceSync/iCloudBridge.swift` |
| Mac pairing, snapshots and actions | `Modules/NativeAgentCore/Sources/DeviceSync/` |
| iOS bridge and snapshot/action engine | `iOS/NativeAgentMobile/Sources/iCloudBridge.swift`, `iCloudSyncEngine+*.swift` |
| iOS chat and share import | `iOS/NativeAgentMobile/Sources/ChatStore+*.swift` |
