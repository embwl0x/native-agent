# NativeAgent APNS Push Setup

Direct APNS owns remote alerts. CloudKit carries durable signed messages and
wakes sync; both `NAChatMessage.incoming` and `NANotification.visible` are
**silent** subscriptions. The latter keeps its deployed ID while removing the
visual alert. It requests `notificationScreen`, `notificationEventId` and
`kind`, with `notificationEventId` as its collapse key.

For ordinary notifications, `MacSyncMobileNotificationRelay.sendNotification`
attempts direct APNS, then queues the signed bridge notification with the IDs
of devices whose APNS send was accepted. When the phone processes that message,
`NativeAgentBridgeNotificationScheduler` skips a duplicate local alert for
those devices; otherwise it schedules a local notification. This fallback
depends on the phone processing sync. A CloudKit write alone is not proof of
lock-screen delivery.

Requested-result notifications instead persist the signed result first and
send a background APNS wake. Their receipt reports the queued bridge record,
not visual APNS acceptance.

## CloudKit deployment prerequisite

Before relying on production, TestFlight or App Store clients, create or repair
the current silent subscription shapes once from a Development-signed client,
then use CloudKit Console to deploy Development to Production. This includes
the chat, notification, pairing and status subscriptions in
`CloudKitDeviceTransport`. Keep their IDs, record types, predicates, fire
options and notification settings identical to the shipped client, including
the desired keys and collapse key above. `NANotification.visible` must remain
silent despite its legacy name.

Deploy the matching record schema, including `NAChatMessage`, `NANotification`,
`NAPairingDevice` and `NAStatus`, and re-export the Production schema for
`NATIVEAGENT_PRODUCTION_CLOUDKIT_SCHEMA`. A record-schema export alone does not
prove subscription readiness: Production can reject an undeployed subscription
shape with `serverRejectedRequest`. That error is not proof the subscription
already exists.

## Direct APNS configuration

Create `<dataRoot>/config/apns.json` locally, outside tracked source:

```json
{
  "team_id": "YOUR_APPLE_TEAM_ID",
  "key_id": "YOUR_APNS_KEY_ID",
  "key_path": "/absolute/private/path/AuthKey_YOUR_APNS_KEY_ID.p8"
}
```

Never bundle the private key. `topic` and `environment` are optional; omitted
or `"auto"` values use the phone's registered bundle ID and environment. If
environment metadata is absent, the sender defaults to production. Prefer
complete token metadata over forcing an environment.

The phone registers its token through the paired sync channel. The iOS build
sets the APNS environment; its Release configuration requests production.
The Mac sender also looks beside `apns.json` for `AuthKey_<key_id>.p8` if the
configured key path is unavailable.

## Delivery evidence

Receipts are returned to the caller, including APNS status/errors and the
bridge message ID.
`apnsAccepted` means Apple accepted the request; `lockScreenDisplayVerified`
remains false. The relay sets `cloudKitVisualPushEligible` to false.

For an installed-app check, enable phone notifications and send one benign
notification through `app` action `notify.phone`. Inspect its receipt and
independently confirm presentation on the phone. Do not infer display from an
APNS success, a sync receipt, or a subscription's name.

## Source owners

- `Modules/NativeAgentCore/Sources/DeviceSync/SwiftNativeAPNS.swift` — credentials,
  token targeting, APNS sends and receipts.
- `Modules/NativeAgentCore/Sources/DeviceSync/MacSyncMobileNotificationRelay.swift`
  — direct/bridge routing.
- `Modules/NativeAgentShared/Sources/NativeAgentShared/CloudKitDeviceTransport.swift`
  — subscription registration and repair.
- `iOS/NativeAgentMobile/Sources/MobilePushNotifications.swift` — token sync,
  background drains and local notification projection.
