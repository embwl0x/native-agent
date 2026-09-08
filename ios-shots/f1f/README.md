# F1f iOS closeout — 2026-09-07

R26-iPhone, iOS 26.5; original 1206×2622 simulator PNGs. No Mac UI operated.

| Captures | Item and evidence |
| --- | --- |
| [Light streaming](chat-light-streaming.png), [dark streaming](chat-dark-streaming.png) | 1, 3: labeled Stop beside Send, minimum 44pt target, neutral streaming dot without cyan glow |
| [Light AX2 header](memories-light-ax2-header.png), [dark AX2 header](memories-dark-ax2-header.png) | 2: search/status remain full accessible size; Memories and Proposals now use Dynamic Type body labels and selected traits |
| [Light AX2 first](memories-light-ax2-first.png), [dark AX2 first](memories-dark-ax2-first.png) | 2: list scrolled to sample-1; search/status have scrolled away, first and second rows fully visible including metadata and tags |
| [Light AX2 end](memories-light-ax2-end.png), [dark AX2 end](memories-dark-ax2-end.png) | 2: final sample-3 body and planning tag fully above tab bar; together with first captures, every sample memory is fully reachable |

`ChatView.composerBar` calls the existing `ChatStore.stop(client:)`, which pauses
the queue, freezes session/run IDs, cancels local observation and calls
`MacBridgeClient.cancelChat` → signed `iCloudSyncEngine.cancelChat`. The existing
error banner reports when the Mac does not confirm cancellation. No store edit
was needed. The prior DEBUG streaming fixture did not set store.isLoading and
therefore hid the production Stop. It now projects the same labeled control;
its action is guarded so a visual fixture cannot cancel actual work. These
captures prove presentation, not a live Mac cancellation or provider stream.

`ChatBubbleViews` replaces the decorative pulsing/glowing dot with a static
neutral 7pt circle. `MemoryView.memoryHeader` supplies search, status, errors and
segment buttons as ordinary content to MemoryListView and ProposalsListView.
Search still binds the existing local snapshot filter. No accessible text is
shrunk and no nested scrolling container is introduced. Theme APIs are untouched.

Build/install:

```sh
xcodebuild -project iOS/NativeAgentMobile/NativeAgentMobile.xcodeproj \
  -scheme NativeAgentMobile -destination 'platform=iOS Simulator,name=R26-iPhone' \
  -derivedDataPath .build/f1f-ios -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile build
xcrun simctl install R26-iPhone .build/f1f-ios/Build/Products/Debug-iphonesimulator/NativeAgentMobile.app
```

Terminate the app between fixture launches. Launch bundle
`io.github.embwl0x.nativeagent.ios` with `-NativeAgentMobile.pairingSkipped YES`:

- Chat: `-initialTab chat -chatSample -chatSampleStreaming`.
- Memories header: `-initialTab memories -memorySample -memorySampleStatus noAccount`.
- First row: add `-memorySampleRow sample-1`; this DEBUG hook uses the actual
  list's ScrollViewProxy, without changing rows or saving a scroll position.
- End: add `-memorySampleEnd` instead.

Use `simctl ui R26-iPhone content_size accessibility-large` for AX2, `large` for
chat; `appearance light|dark`. Capture with `simctl io R26-iPhone screenshot`.
Light appearance and ordinary large text were restored afterward.

Validation: integrated iOS build passed. Architecture blueprint and timer
inventory passed (191 sites); no new timers. Existing MemorySearchEvalTests
initially rejected removal of the pinned `.searchable` modifier; its source
assertion moved to the bound scrolling TextField per the brief. The final suite
passed all four tests with zero failures; `git diff --check` passed. No new suite,
Mac build, live sync, provider request, push or merge. No unrelated bug was
established during this bounded change.
