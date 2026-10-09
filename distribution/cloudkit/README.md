# NativeAgent CloudKit schema

`NativeAgent.ckdb` is the versioned production schema for Mac/iPhone device
continuity. It contains only transport records; MemoryV2 remains Mac-owned.
The permanent shared container is
`iCloud.io.github.embwl0x.nativeagent`.

Validate it against both environments before deployment:

```bash
xcrun cktool validate-schema \
  --team-id "$NATIVEAGENT_TEAM_ID" \
  --container-id "iCloud.io.github.embwl0x.nativeagent" \
  --environment development \
  --file distribution/cloudkit/NativeAgent.ckdb

```

Import the validated file into development with `cktool import-schema
--validate`. Apple does not expose production schema promotion through
`cktool`; deployment changes the live container and must be performed
deliberately in CloudKit Console. After promotion, export production again and
verify that `NAChatMessage`, `NANotification`, `NAPairingDevice`, and `NAStatus`
all exist with the fields in this file. `NANotification` provides durable signed
notification transport. Both its subscription and the `NAChatMessage`
subscription silently wake sync. Direct APNS owns normal remote alerts; when
the phone processes a bridge notification, it schedules a local fallback alert
unless direct APNS was accepted for that device. Acceptance is not proof of
delivery or display.
