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
all exist with the fields in this file. `NANotification` is intentionally
separate: one visual subscription owns its APNS projection, while
`NAChatMessage` has only the silent chat-sync subscription.
