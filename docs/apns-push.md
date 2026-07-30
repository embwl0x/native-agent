# NativeAgent APNS Push Setup

NativeAgent's public lock-screen path is CloudKit/APNS under each user's own
iCloud account. The Mac writes an explicit `NANotification` record to that
account's private database. The iPhone owns one high-priority
`NANotification.visible` query subscription, so Apple can present the alert
while the app is closed. Ordinary chat uses the separate silent
`NAChatMessage.incoming` subscription; no record matches both projections.
This path needs no NativeAgent-hosted push service and ships no provider key.
CloudKit permits at most three `desiredKeys` on a subscription. NativeAgent's
visual contract therefore uses exactly `notificationScreen`,
`notificationEventId`, and `kind`; the visible body and title are supplied as
localization arguments. iOS publishes the versioned visual-capability contract
only after exact registration succeeds. Mac delivery receipts must not call
the route visually eligible merely because the Mac can write CloudKit records.

CloudKit query-subscription shapes have a release prerequisite that ordinary
record-schema export does not prove. Create the exact subscription once from a
Development-signed client, then use CloudKit Console to deploy Development to
Production before relying on TestFlight or App Store clients. Apple rejects a
first-time subscription creation attempt made directly in Production. Keep the
subscription ID, record type, predicate, fire options, localization keys and
arguments, sound, collapse key, and three desired keys identical to the shipped
client. This is a one-time container contract, not a resident helper service or
an app bootstrap subsystem.

NativeAgent also supports an optional direct APNS route for maintainer
diagnostics or explicitly self-hosted installations. The phone registers its
APNS device token and sends it to the Mac over the signed iCloud pairing
channel. The Swift Mac app can then send APNS directly; there is no external
runtime or daemon HTTP fallback.

Never treat a CloudKit write receipt or direct APNS `2xx` as proof that the
device displayed an alert. Display proof requires an independent phone/user
observation. Never bundle a private `.p8` key into the app or repository.

For the optional direct route, create this local, untracked file on the Mac:

```json
{
  "team_id": "YOUR_APPLE_TEAM_ID",
  "key_id": "YOUR_APNS_KEY_ID",
  "key_path": "local/AuthKey_YOURKEYID.p8"
}
```

`topic` and `environment` are optional. When omitted or set to `"auto"`, the
Mac app derives them from the paired iOS token registration (`bundleId` and
APNS environment). `team_id`, `key_id`, and `key_path` remain required APNS
provider credentials.

Live verification is intentionally opt-in because it sends a real notification:

```bash
NATIVE_AGENT_DATA_ROOT="$PWD/data" \
NATIVE_AGENT_LIVE_MOBILE_NOTIFY_TEST=1 \
swift test --filter liveMobileNotify_optInOnly
```

Successful sends append Swift-native receipts to
`data/mobile_push/receipts.jsonl` with `httpStatus: 200`. Notification titles
default to the onboarded agent display name from `data/memory/profile.json`.
An APNS `2xx` proves Apple accepted the request, not that the device displayed
it. NativeAgent tool receipts therefore keep `lockScreenDisplayVerified` false
until an independent device/user observation exists.

For a release/TestFlight/App Store build, the iOS entitlement controls whether
the optional direct-route token is development or production. Leave
`environment` on auto unless diagnostics require a forced lane. Public
iCloud-only proof must temporarily disable this local configuration and verify
multiple distinct notifications while the phone stays locked.

The production baseline established on 2026-07-29 is TestFlight
`0.3.0 (10)`: after `NANotification.visible` was created in Development and
deployed to Production, three distinct alerts sent about ten seconds apart all
reported the CloudKit visual route, no APNS send, and no foreground
requirement; the user confirmed all three appeared while the phone stayed
locked. Future notification-affecting builds must repeat that physical proof.
