# iPhone Desk — 2026-09-09

The six assigned source files now preserve a notification's exact task ID
through cold/warm delivery, push Desk tasks from More, and open the matching
loaded task after refreshing. An unavailable task leaves an explicit notice.
Desk stays the board and adds a Desk tasks link. Resolved decisions and board
history disclose additional loaded records in batches of 10 and 40.

`WorkshopMountEvalTests.renderDeskDisclosureFixtures` uses DEBUG ImageRenderer
without a window or screen capture. The four PNGs show the production link
label, disclosure buttons, unavailable notice, and task row in light/dark and
accessibility text sizes. These are component layout fixtures, not full-screen
navigation or live APNS evidence. All four images were visually inspected.

Validation uses the NativeAgentMobile scheme and R26-iPhone simulator:

```sh
xcodebuild -project iOS/NativeAgentMobile/NativeAgentMobile.xcodeproj \
  -scheme NativeAgentMobile -destination 'platform=iOS Simulator,name=R26-iPhone' \
  -derivedDataPath /tmp/nativeagent-phone-desk-build \
  -disableAutomaticPackageResolution -skipPackageUpdates build
```

The same command with `test -only-testing:NativeAgentMobileTests/WorkshopMountEvalTests`
runs the existing four-test suite, including exact-ID intent consumption and
the headless renders. Final logs: `/tmp/nativeagent-phone-desk-build.log` and
`/tmp/nativeagent-phone-desk-final-tests.log`; result bundle:
`/tmp/nativeagent-phone-desk-final-tests.xcresult`.

The required timer inventory and architecture blueprint checks passed.
No timer sites or turn/memory ownership changed. No live Mac notification
delivery was exercised. The separate directed-task list's existing 20-row
history cap is outside the requested board-history change and remains.
