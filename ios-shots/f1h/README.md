# F1h iOS pairing and Desk text evidence — 2026-09-08

**Complete: all three directed Desk texts pass 4.5:1 in light and dark.**
The authorized continuation changes `WorkshopView.swift`: `WorkshopTaskRow`'s
objective and progress summary and `StatusBadge`'s foreground now use the existing
`NativeAgentMobileTheme.Colors.readingSecondary` token (three substitutions).
Fonts, weights, spacing, quiet badge fill and shadows are unchanged.

## Built

- `PairingView.swift`: `IOSPairingPresentation` resolves the configured bundle
  display name with `NativeAgentIdentity.displayName`; the manual instructions
  and missing-key/signature recovery messages now name “NativeAgent Settings
  on your Mac → Pair iPhone or iPad.” The ready-iCloud step uses the same name.
  Both numbered instruction blocks use leading text and frame alignment.
- `ContentView.swift`: comment only, explaining the More → Desk route.
- `docs/ARCHITECTURE_BLUEPRINT.md`: additive description of these responsibilities.

## Captures

Original simulator PNGs, R26-iPhone / iOS 26.5, 1206×2622 at 3×, ordinary Large
Dynamic Type. Before images are exact copies of f1g's reviewed after images;
after pairing images are from the first commit; after Desk images are fresh
captures of the continuation build with the contrast fix.

| Screen | Before light / dark | After light / dark |
| --- | --- | --- |
| Pairing | [Light](before-pairing-light.png) / [Dark](before-pairing-dark.png) | [Light](after-pairing-light.png) / [Dark](after-pairing-dark.png) |
| More → directed Desk | [Light](before-more-directed-desk-light.png) / [Dark](before-more-directed-desk-dark.png) | [Light](after-more-directed-desk-light.png) / [Dark](after-more-directed-desk-dark.png) |

## Rendered contrast and type

All three texts require 4.5:1; none qualifies as large text. Fonts are unchanged
before/after, as specified by the rendering code at ordinary Large Dynamic Type.
Sizes are points, not screenshot pixels. Contrast uses actual solid glyph
interiors and adjacent plate RGB values sampled from each PNG, excluding
antialiased edges; WCAG sRGB linearization and `(Llighter + .05)/(Ldarker + .05)`.
Pixel rectangles `(left, top, right, bottom)` in the full-resolution images:
summary `(95,775,1100,880)`, progress `(95,904,730,945)`, badge `(945,677,1100,710)`.
The two most frequent colors in each rectangle are background and solid ink;
the plate colors match before and after. PNGs embed sRGB IEC61966-2.1;
measurements use their stored RGB samples without an additional color conversion.

| Text | Font before → after | Light ink before → after / plate | Light before → after | Dark ink before → after / plate | Dark before → after |
| --- | --- | --- | --- | --- | --- |
| Reviewing the final two references. | caption, 12 pt regular → same | #BFBFBF → #555451 / #FFFFFF | **1.84 → 7.57:1 PASS** | #555556 → #B8B7B5 / #1C1C1E | **2.28 → 8.49:1 PASS** |
| Collect the most useful references and explain what each adds. | callout, 16 pt regular → same | #7F7F7F → #555451 / #FFFFFF | **4.00 → 7.57:1 PASS** | #8E8E8F → #B8B7B5 / #1C1C1E | **5.20 → 8.49:1 PASS** |
| Running | caption, 12 pt medium → same | #767676 → #555451 / #ECECEC | **3.84 → 6.41:1 PASS** | #939394 → #B8B7B5 / #272729 | **4.86 → 7.44:1 PASS** |

## Routing answer

The More entry was deliberately mounted for directed work: the dated comment
at the top of `AdvancedView.swift` explains that this surface previously lacked
a call site despite its signed submit/approve/reject path. Its actual
`NavigationLink` constructs `WorkshopView(embedInNavigationStack: false)`,
which reuses More's navigation stack and keeps More selected. `ContentView`
separately constructs `MobileDeskView()` for the primary Desk tab.

Thus this is intentional additional access to a **different directed-work
surface**, not two routes to the same board. The duplicated “Desk” title can
be confusing; the code establishes deliberate mounting, not evidence that
identical titles were a deliberate design decision. No routing was removed.
The DEBUG `designScreen workshop` route captures the actual More destination;
`designScreen desk` would instead push the primary board and miss this card.

## Verification and reproduction

Integrated R26-iPhone xcodebuild passed with seeded packages and automatic
resolution/updates disabled. The existing `UIIntegrityContractTests` suite ran
once: **23 tests, zero failures**. No existing pin for the actual Desk card text
foreground/font was found, so no new test was added. Blueprint and timer
inventory checks passed (192 timer/sleep sites); no new Swift files, timers,
turn behavior or memory ownership, so their inventories/maps needed no edits.
`git diff --check` passed.

```sh
xcodebuild -project iOS/NativeAgentMobile/NativeAgentMobile.xcodeproj \
  -scheme NativeAgentMobile -destination 'platform=iOS Simulator,name=R26-iPhone' \
  -derivedDataPath .build/f1h-ios -clonedSourcePackagesDirPath .build \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates build
xcrun simctl install R26-iPhone .build/f1h-ios/Build/Products/Debug-iphonesimulator/NativeAgentMobile.app
xcrun simctl ui R26-iPhone content_size large
xcrun simctl ui R26-iPhone appearance light # repeat dark
xcrun simctl launch R26-iPhone io.github.embwl0x.nativeagent.ios \
  -NativeAgentMobile.pairingSkipped YES -NativeAgentMobile.appearance system \
  -initialTab more -designScreen pairing # repeat workshop
```

Terminate between launches, allow navigation to settle, then capture with
`simctl io R26-iPhone screenshot`. The test command uses the same build options
and `-only-testing:NativeAgentMobileTests/UIIntegrityContractTests test`.
Light appearance and ordinary Large text were restored. DEBUG samples are
process-local projections; no pairing key was saved and no task submitted.
No Mac UI, browser, user data root, network fetch, push or merge was used.
No additional bug was established. The confusing shared Desk title remains as
requested; routing, transport and the primary Desk board were deliberately unchanged.
