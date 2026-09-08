# F1d chat and Memories finishing pass — 2026-09-07

R26-iPhone, iOS 26.5, 1206×2622 PNGs from `simctl io screenshot`.
Only the simulator was operated; no Mac UI captures or resident data changes.

## Capture map

| Capture | Brief item and visible evidence |
| --- | --- |
| [Normal, keyboard down, idle](chat-light-normal-down-idle.png) | 1, 3, 5: all five messages fit; single-row idle composer; deep teal selected Chat tab |
| [Normal, keyboard up, idle](chat-light-normal-up-idle.png) | 1, 5: final multiline bubble fully above compact composer and keyboard |
| [Normal, keyboard down, streaming](chat-light-normal-down-streaming.png) | 5: in-flight row above composer and visible tab bar |
| [Normal, keyboard up, streaming](chat-light-normal-up-streaming.png) | 5: in-flight row above composer with keyboard replacing tab exclusion |
| [AX2, keyboard down, idle](chat-light-ax2-down-idle.png) | 1, 5: composer reflows without shrinking type; last bubble above composer and tabs |
| [AX2, keyboard up, idle](chat-light-ax2-up-idle.png) | 5: complete final bubble clears expanded composer and software keyboard |
| [AX2, keyboard down, streaming](chat-light-ax2-down-streaming.png) | 5: final streaming row clears expanded composer and visible tab bar |
| [AX2, keyboard up, streaming](chat-light-ax2-up-streaming.png) | 5: complete in-flight row above expanded composer and keyboard |
| [Growing draft](chat-light-normal-growing.png) | 1, 5: four-line draft grows the composer; last bubble remains visible |
| [Light options](options-light-ax2.png), [dark options](options-dark-ax2.png) | 1: full long provider and model names wrap at AX2; vertical options replace clipped horizontal fragments |
| [Light Memories](memories-light-normal-end.png), [dark Memories](memories-dark-normal-end.png) | 2–4: matching title/tab; plain reading rows, labeled importance, neutral tags; one no-account cause/consequence/recovery region |
| [Light Memories AX2 end](memories-light-ax2-end.png), [dark Memories AX2 end](memories-dark-ax2-end.png) | 2: true final sample item (`sample-3`) and its `planning` tag scroll fully above the tab bar |
| [Never synced](memories-light-never.png) | 4: first snapshot absent with available connection, Refresh memories recovery (DEBUG status projection) |
| [Stale](memories-light-stale.png) | 4: two-hour-old snapshot retains its distinct freshness state (DEBUG status projection) |
| [Light chat AX2 opaque/contrast](chat-light-ax2-contrast-opaque.png), [dark chat AX2 opaque/contrast](chat-dark-ax2-contrast-opaque.png) | 5: Reduce Transparency + Increase Contrast together, keyboard up and streaming; opaque composer, single stronger border, full final row |
| [Light Memories AX2 opaque/contrast](memories-light-ax2-contrast-opaque.png), [dark Memories AX2 opaque/contrast](memories-dark-ax2-contrast-opaque.png) | 2, 3, 5: quiet opaque reading surface, selected tab and full final tag clear of the tab bar |

The sample-label row exists only in DEBUG captures; production rows begin directly
below the segmented control with zero extra top content margin. No body text was
shrunk. Metadata is the snapshot's **importance**, not its confidence field.

## Insets and reproduction

The transcript's `safeAreaInset` measures the complete composer, plus 12pt spacing
and its 8pt bottom padding. SwiftUI already excludes the keyboard or native tab
safe area from the available viewport. No keyboard height, tab height, or home
indicator is added a second time. Composer controls retain 44pt targets. Memories
uses the native tab-safe viewport plus a 24pt bottom scroll-content margin.
The AX2 end captures show the actual final row and its final tag, not an earlier
convenient row. Content above the viewport can be clipped normally while scrolling.

Build with:

```sh
xcodebuild -project iOS/NativeAgentMobile/NativeAgentMobile.xcodeproj \
  -scheme NativeAgentMobile -destination 'platform=iOS Simulator,name=R26-iPhone' \
  -derivedDataPath .build/f1d-ios -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile build
```

Install the Debug app, then launch `io.github.embwl0x.nativeagent.ios` with
`-NativeAgentMobile.pairingSkipped YES -initialTab chat -chatSample`.
Add `-chatSampleKeyboard`, `-chatSampleStreaming`, `-chatSampleModel` (opens
Options), or `-chatSampleDraft <multiline text>` as named by each case.
For memory use `-initialTab memories -memorySample -memorySampleEnd`.
`-memorySampleStatus never|stale|noAccount` supplies process-local status cases;
the ordinary/end captures use the real simulator account result (no account).

AX2: `simctl ui <device> content_size accessibility-large`; normal: `large`.
Appearance: `simctl ui <device> appearance light|dark`. Increased contrast:
`simctl ui <device> increase_contrast enabled`. Reduce Transparency:
`simctl spawn <device> defaults write com.apple.Accessibility
EnhancedBackgroundContrastEnabled -bool YES`, then relaunch. Light, large,
normal contrast and transparency were restored after capturing.

All fixtures are view-only. Streaming is a held in-flight presentation with a
pulsing indicator, not a live provider stream or a claim of delivery. The existing
production scroll scheduler still follows real text and streaming-state changes.
No sample memory/transcript is saved and sample submission/deletion is disabled.

## Actual composited contrast

`measure-contrast.swift` decodes PNGs into explicit sRGB RGBA. It finds the modal
solid ink within a stated text region (excluding antialiased edges) and samples
an adjacent composited background. WCAG luminance ratio is `(Lmax+.05)/(Lmin+.05)`.
Native selected labels alter the supplied tint: these measurements use the
**rendered label**, not the raw theme color or navigation plus button.

| Text / capture | Rendered ink | Adjacent background | Ratio |
| --- | --- | --- | --- |
| Selected Memories, light normal | #006066 | #EAE9E5 | **6.03:1** |
| Selected Memories, dark normal | #8AF1F5 | #4A4946 | **6.85:1** |
| Selected Memories, light AX2 opaque/contrast | #00474C | #E1E1E0 | **8.00:1** |
| Selected Memories, dark AX2 opaque/contrast | #97FFFF | #2F2F2F | **11.52:1** |
| Memory layer/importance, light normal | #4C5055 | #FFFFFF | **8.12:1** |
| Memory layer/importance, dark normal | #A4AAB0 | #292725 | **6.35:1** |
| Memory tag, light normal | #4C5055 | #ECECEC | **6.87:1** |
| Memory tag, dark normal | #A4AAB0 | #343230 | **5.44:1** |

All measured small-text cases exceed 4.5:1. Selected-tab label region is normalized
`(.4,.95)–(.6,.965)`, background `(.5,.969)`. Normal metadata region:
`(.03,.435)–(.55,.46)`, background `(.6,.447)`. Normal tag region:
`(.06,.525)–(.16,.545)`, background `(.10,.526)`.
Run the script with PNG, x0 y0 x1 y1, expected ink hex (or `accent` to select
chromatic teal without assuming its resulting color), background x y. Export
User's prescribed five Git configuration variables before invoking Swift.
Glass varies with its backdrop; these are measurements of the listed captures.

## Wiring and boundaries

`ChatView` owns adaptive composition and the Options sheet; model/provider actions
retain their existing transactional implementation. `ChatBubbleViews` removes the
40pt/one-line cap from streaming text. `NativeAgentMobileTheme` adds metadata ink
and maps its existing accent alias to accessible accent text; `ContentView` uses
that same role for root tab selection. Other screen owners can consume these
tokens without renaming any existing API.

`MemoryView` groups the existing freshness/bridge state with an entitlement-guarded
CloudKit account read, opens system Settings for no account, opens existing
pairing setup for other connection failures, and refreshes the existing store
for missing/stale snapshots. No transport authority or memory ownership changed.
No timers were added to the inventory's counted primitives; the replacement
status retains the old visible 15-second TimelineView cadence.

Final `xcodebuild build` and the existing `ChatScrollSchedulerEvalTests` suite
passed (2 tests, zero failures; run once). Architecture blueprint and timer
inventory scripts passed (191 classified timer/sleep sites); `git diff --check`
passed. No Mac
build, provider execution, live sync test, public release, push, or merge was in
scope. Other screens remain owned by the concurrent styling agent.
