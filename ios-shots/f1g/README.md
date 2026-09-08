# F1g iOS clarity — 2026-09-07

26 original, unmodified R26-iPhone simulator PNGs (iOS 26.5, 1206×2622).
Baseline source: `37a59010`. Light/dark use ordinary Large text, except the
scrolled Memories pair uses Accessibility Large (AX2). Palette and materials
are retained; the Memories navigation backing is intentionally opaque.

| Case | Before light / dark | After light / dark |
| --- | --- | --- |
| Activity: unavailable iCloud, pending approval | [Light](before-activity-light.png) / [Dark](before-activity-dark.png) | [Light](after-activity-light.png) / [Dark](after-activity-dark.png) |
| Pairing | [Light](before-pairing-light.png) / [Dark](before-pairing-dark.png) | [Light](after-pairing-light.png) / [Dark](after-pairing-dark.png) |
| Settings | [Light](before-settings-light.png) / [Dark](before-settings-dark.png) | [Light](after-settings-light.png) / [Dark](after-settings-dark.png) |
| Desk pushed under More (reviewer route) | [Light](before-desk-light.png) / [Dark](before-desk-dark.png) | [Light](after-desk-light.png) / [Dark](after-desk-dark.png) |
| Chat streaming | [Light](before-chat-light.png) / [Dark](before-chat-dark.png) | [Light](after-chat-light.png) / [Dark](after-chat-dark.png) |
| Memories scrolled to first row, AX2 | [Light](before-memories-light.png) / [Dark](before-memories-dark.png) | [Light](after-memories-light.png) / [Dark](after-memories-dark.png) |

The current More menu's Desk link opens the directed-work view
(`WorkshopView(embedInNavigationStack: false)`), whereas the primary Desk tab
opens `MobileDeskView`. The supplied DEBUG `desk` route pushes the latter
under More. Both now carry the persistent More parent label. Additional
[light](after-more-directed-desk-light.png) and
[dark](after-more-directed-desk-dark.png) captures exercise the directed-work
destination using the existing `workshop` launch route. Routing was preserved
inside the assigned file boundary: **Desk opened under More is visibly a child
of More; it does not switch tabs.** No AdvancedView edit was required.

## Behavior and owners

- `ActivityView.InlineApprovalPreviewCard` keeps View available with teal ink.
  Approve and Deny use the same pairing/bridge/network availability gate and
  are both disabled when decisions cannot be sent. Available Deny uses teal,
  rather than disabled-looking gray. The card explicitly says the approval is
  still pending and that decisions are not automatically retried.
- `ApprovalsView.ApprovalCard` applies the same decision gate and stronger Deny
  styling. `ApprovalBannerPresentation` supplies honest unconfirmed-result copy
  to both full and inline approvals.
- `PairingView` presents short setup steps; format details live in the Pairing
  key help disclosure and existing validation messages. Unsupported-QR copy is
  removed. Key verification and pairing persistence are unchanged.
- `SettingsViewFull` identifies missing pairing as Not paired and offers Set up
  Mac connection, opening the existing pairing flow without first clearing a
  key. Unavailable connections offer setup help; connected devices can Check
  for Mac updates through the existing KVS-plus-settings refresh. Pairing
  version and replacement are in Connection diagnostics.
- `ContentView` owns the More parent label and explicitly resolves the native
  TabView tint against the root color scheme. The fresh baseline already had
  accessible teal native tab labels in light mode; the reported cyan baseline
  did not reproduce. Actual native chrome was measured, not inferred from a
  SwiftUI token.
- `NativeAgentMobileTheme.Colors.readingSecondary` adds opaque reading ink;
  Activity, Approvals, Pairing, Settings and Memories bind secondary text to it.
  Theme changes are additive. `ChatView.composerBar` makes Stop and Send mutually
  exclusive using the existing loading state and DEBUG stream projection.
  `MemoryView.memoryContent` gives the navigation bar visible canvas backing,
  masking scrolled text without adding shadow.

Approval delivery was traced through `approveApproval` / `rejectApproval` →
`sendDecisionActionWithSignatureRetry` → `sendAction` in
`iCloudSyncEngine+Actions.swift`, then `iCloudBridge.sendActionEnvelope`.
Missing signing material fails before submission. A definite first CloudKit
send failure retires its pending action; uncertain submission retains the
transaction for response checking or an explicit retry. The legacy Drive path
requires an inbox directory and can time out after staging a file. The UI
therefore never promises automatic future delivery and never treats a timeout
as proof that the Mac received or executed a decision. No transport was changed.

## Contrast

[Full measured results](contrast.md) retain the recorded measurements.
The one-off Python measurement helper was removed to honor the repository's
Swift tooling inventory. The measurements sampled glyph interiors and real plate pixels from the sRGB PNGs;
tab measurements include the native selected fill and use the least favorable
pixel from the gap immediately above the label.

| Measured text | Before | After |
| --- | --- | --- |
| Settings and Activity secondary, light white plates | 4.00:1 | **7.57:1** |
| Settings / Activity subtitle, dark native list plate | 5.20:1 | **8.49:1** |
| Activity approval body, dark reading card | 4.85:1 | **7.43:1** |
| Selected Activity / More tab labels, light | 5.97–5.98:1 | **5.78–6.00:1** |
| Selected Activity / More tab labels, dark | 6.38–6.77:1 | **5.80–6.73:1** |

These are measured locations on these captures, not a claim about every
possible scrolled glass backdrop. Disabled controls are intentionally muted.

## Reproduction and validation

Build with the seeded package cache, simulator signing enabled:

```sh
xcodebuild -project iOS/NativeAgentMobile/NativeAgentMobile.xcodeproj \
  -scheme NativeAgentMobile -destination 'platform=iOS Simulator,name=R26-iPhone' \
  -derivedDataPath .build/f1g-ios -clonedSourcePackagesDirPath .build \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates build
xcrun simctl install R26-iPhone .build/f1g-ios/Build/Products/Debug-iphonesimulator/NativeAgentMobile.app
```

Terminate the app between launches. Launch `io.github.embwl0x.nativeagent.ios`
with `-NativeAgentMobile.pairingSkipped YES -NativeAgentMobile.appearance system`:

- Activity: `-initialTab activity -designScreen activity`.
- Pairing / Settings / Desk: `-initialTab more -designScreen pairing|settings|desk`.
- Actual More directed Desk destination: `-initialTab more -designScreen workshop`.
- Chat: `-initialTab chat -chatSample -chatSampleStreaming`.
- Memories: `-initialTab memories -memorySample -memorySampleStatus noAccount -memorySampleRow sample-1`.

Use `simctl ui R26-iPhone appearance light|dark`, `content_size large` (Memories:
`accessibility-large`), normal contrast and transparency. Allow four seconds for
navigation to settle; capture with `simctl io R26-iPhone screenshot <path>`.
Light appearance and ordinary Large text were restored afterward.

Integrated iOS build passed. The existing `UIIntegrityContractTests` suite ran
once: **23 tests, zero failures**; the full test target compiled. Two old QR-copy
assertions moved with the copy change (no new tests). Architecture blueprint
and timer inventory checks passed (191 timer/sleep sites); no new Swift files
or timers. `git diff --check` passed. No Mac build, eval campaign, network fetch,
push or merge was performed.

The samples are existing DEBUG, process-local view projections, not live
approvals, delivery receipts, provider streams or canonical memories. No real
approval was submitted. iCloud delivery and cancellation were not exercised
against a paired Mac. No Mac UI or user data root was accessed.

An unsigned simulator build crashed when Memories constructed CKContainer:
the existing iOS preflight assumes install-time entitlements and returns true
on the simulator. Normal simulator signing resolved the capture blocker; that
shared preflight behavior was left outside this area. The existing differently
owned Desk destinations were also preserved, with their parent now explicit.
