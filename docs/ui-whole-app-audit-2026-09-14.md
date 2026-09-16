# Whole Mac UI audit — September 14, 2026

User requested the whole UI, including smooth composer model controls and the
remaining observed leak. This pass extends the earlier Chat/Bots work.

## Corrections

- Composer: content-sized panel; aligned Provider/Model rows with selected
  values, direct checked choices, one Thinking section, trailing Fast switch,
  integrated refresh and save feedback. Existing routing and Trust owners remain.
- Knowledge Graph: cancelled/superseded pagination and neighbor reads cannot
  replace newer results or keep paging after departure. Canonical nodes are
  computed once per draw. Compact clipped labels avoid collisions; accessible
  nodes and the detail view retain full names.
- Settings memory status: late reads cannot resurrect hidden polling; refresh
  replaces an old poll, and the ten-minute timeout remains finite.
- iPhone pairing: cancelling an old reveal timer cannot erase the newer handle;
  cancelled initial reads do not update a departed page.
- Telegram: entering the tab checks saved configuration before displaying the
  form, instead of displaying uninitialized false/empty values beside live
  poller status. Read-only hydration preserves dirty fields and credential drafts.
- Cognition: unverified initial state reads Loading/Unavailable rather than Off;
  the initial substrate toggle is disabled until checked state arrives.
- Classic chat health: its polling registration follows retained-page visibility.
- Research: empty-result wording uses the submitted query, not later input edits.

## Coverage

All 13 sidebar destinations were opened in the installed app. Visual inspection
used the 1040 × 712 minimum content window (some toolbar pages add titlebar height),
plus the large window. Source review covered the related sheets and alternate
layouts; those inspections are distinguished below from live navigation.

| Surface | Coverage and result |
| --- | --- |
| Chat | Live composer, popup values, keyboard Provider/Model menus, dismissal and unchanged model; previous typing, attachments, scrolling and streaming receipts remain in the earlier audit. Main/detached lifecycle, key monitors and glass source reviewed. |
| Today / Activity | Live Today at minimum; attention/timeline/note and classic Activity/Approvals/Inbox/Self-Improvement source reviewed. Coalesced scene-owned reads; no additional defect found. |
| Memories | Live Memories and Knowledge Graph list/graph/filter; pending/rejected/full text and classic tabs reviewed. Graph read and label fixes above. |
| Desk | Live default page; classic boards/executions/watchers/done, disclosures, palette/nags/debug, Schedule and Research reviewed. Existing scene/sheet-gated poll remains documented; Research wording fixed. |
| Notifications | Live preferences; history/triggers/watched folders reviewed. No continuous view work found. |
| Bots | Live shelf; prior repeated navigation and hidden-motion checks retained. One retained shelf remains bounded and hidden work cancels. |
| Personality | Live root, Minds, Dreams; document editor and diary/detail controls reviewed. Finite/generation-gated reads. |
| Providers | Live accounts and all three choice groups at minimum width; account setup sheets reviewed. Controls fit; no layout change warranted. |
| Trust | Live presets and Mac integration tab; policy/permission/multimodal/voice/autonomy/memory descendants reviewed without changing permissions. |
| Connectors | Live root, MCP, Telegram and iPhone; account wizard/folder/search paths reviewed. Telegram and pairing fixes above. |
| Capabilities | Live Overview, Build, Operate and Hardening; initial/manual read owners reviewed. No new continuous-work defect found. |
| Diagnostics | Live Health, Status, Run history, Cognition, Chat turn details, Skills and Tools. Cognition settles correctly; initial misleading label corrected. Stream cancellation and trace-reader cleanup reviewed. |
| Settings | Live root; basic/update/hotkey/navigation/subconscious/memory sections reviewed. Hidden memory polling fixed and covered by mounted test. |
| Shared and secondary windows | Source review of shell/glass, focus routing, browser navigation cancellation/timeouts, onboarding and tour, detached chat teardown. Existing contrast/transparency/motion gates retained. Onboarding was not reset on the owner's live installation. |

## Verification notes

The first popup visual check caught AppKit flattening rich labels under the
borderless menu style; the button menu style fixed it. An independent SwiftUI
popover reproduced inconclusive computer-control mouse clicks; keyboard
activation opened both the probe and production menus. The real provider and
model menus were inspected without selecting another value. Inline choices
remove their unnecessary submenu level.

Initial test execution exposed a missing AppModel environment in the new mounted
Settings fixture; corrected with isolated data and disabled background tasks.
The graph's new accessibility/Text drawing expressions required compiler type
decomposition; this was a build failure, not an installed runtime failure.

Final optimized installation passed signature and authenticated bridge/chat/source
readiness: `/tmp/nativeagent-whole-ui-final-pass-install.log`, owner PID 81994,
version `0.4.13-dev.cc124d47.dirty`. The final 30 tests in 8 suites passed in
2.650 seconds after compilation, including the mounted late-read test, Telegram
configuration byte preservation, graph label geometry/collision checks, graph
canonical reader/safety, request ordering, refresh/access and poll-scheduler
behavior. Receipt: `/tmp/nativeagent-whole-ui-final-tests.log`. Test data was
isolated with `NATIVE_AGENT_DATA_ROOT`; the mounted check was enabled explicitly.

Final live checks: Telegram shows configured/on; the same graph query no longer
overlaps labels and an accessible node opens full detail; Cognition progresses
from Loading to Enabled; both composer menus open direct choices by keyboard
(five model choices, including the active Astra selection). Model, Trust and
credential settings remained unchanged. Temporary graph search was cleared,
page tabs restored and Chat reopened with no popup. Temporary menu probe closed.

Five-second idle sampling after the page work, using `/usr/bin/sample` at 10ms,
captured all 456 main-thread samples waiting in the event loop, with no active
rendering stack. Reported footprint was 910.9 MB, peak 1.1 GB for this process;
this is not a cross-run memory reduction or endurance claim. Receipt:
`/tmp/nativeagent-whole-ui-idle-sample.txt`. Bridge confirmed chatReady true,
active Astra and active context/runtime. `git diff --check` passed. No commit,
push, merge or release; unrelated existing changes were preserved.

## Remaining platform allocation

The independently reproduced AppKit selective-sharing window leak is documented
in `diagnostics/sharing-window-leak-report-2026-09-14.md`. Source, measured stacks
and public API review found no supported NativeAgent cleanup hook. The report
contains a minimal reproduction and no conversations or full private memory dump.
It has not been submitted externally. Disabling accessibility, changing capture
permissions or releasing framework-owned objects is not an acceptable mitigation.

This audit establishes the documented source coverage, exercised live paths and
bounded measurements. It does not claim every possible account/error state or
indefinite operation is mathematically leak-free.


## Measured performance continuation — September 14

The earlier visual/source pass did not establish uniform smoothness. A 90-second
Core Animation workload revisited every root page and scrolled, with action and
AX-read timestamps recorded separately. Largest first-pass scroll-phase commits:
Trust 447.6 ms, Providers 291.3 ms. Trace:
`/tmp/nativeagent-whole-ui-interaction.trace`. A separate CPU trace identified
substantial real layout work as well as accessibility processing; tool overhead
cannot explain the whole delay.

Changes in this continuation:

- `NativeAgentDesign.swift` and `TrustCenterView.swift`: semantic card groups
  preserve child controls while bounding accessibility ordering; Trust sections
  are lazy. No new all-page retention cache.
- `ProviderSettingsView.swift`: lazy columns, account rows and sign-in cards;
  existing routing/draft/save owners remain on the page.
- `ActivityCapturePermissionsView.swift`: the 20-entry excluded-app list is a
  counted disclosure. Protection explanation and add control remain visible;
  opening it exposes all 20 Remove buttons. No policy writes during validation.
- `ShellWindowChrome.swift`: a disabled retained composer cannot keep its native
  key monitor active merely because its focus binding is stale.
- `ComposerKeyboardVisibilityTests.swift`: mounted disabled/enabled/disabled
  lifecycle, stale focus held true, same native monitor identity throughout.

The first grouping/lazy build measured Trust's expanded-window maximum at 280.9
ms (`/tmp/nativeagent-ui-card-after.trace`); Providers still reached 305.6 ms,
which led to its lazy-layout follow-through. Final normal-window (1040x712)
measurements are in `/tmp/nativeagent-final-normal-scroll.trace`:

| Surface / warm cycle | Whole interaction maximum | 95th percentile |
| --- | ---: | ---: |
| Trust / 1 | 54.224 ms | 40.857 ms |
| Trust / 2 | 58.949 ms | 43.158 ms |
| Providers / 1 | 63.559 ms | 1.931 ms |
| Providers / 2 | 60.531 ms | 1.932 ms |

Whole interaction includes input and subsequent AX/follow-through; delayed
scroll work must not be silently excluded from the latter. Tool-return latency
is not frame time. Providers input-only maxima were ~1.93 ms on these warm
cycles, but later commits remained. The earlier expanded-window and final
normal-window numbers must NOT be sold as a matched direct speedup.

Separate normal-window CPU trace `/tmp/nativeagent-final-normal-cpu.trace`:
warm Trust inputs each used ~50–53 ms sampled main-thread CPU, including 28–30
ms accessibility focus traversal, 18–21 ms non-AX layout, and 3–6 ms other.
`_XCopyHierarchy` was in the follow-up interval, not these input spans. Source/SDK
review found no supported subtree focus-pruning API. Hidden Chat ownership was
not proved; adding a giant retained-page cache or disabling accessibility was
rejected as an unsupported tradeoff. Uniform 60/120-fps behavior remains open.

Fresh allocation-logged app baseline was zero. Trust roundtrip: 210 objects /
10,176 bytes; adding Providers: 303 / 14,720; remaining-page roundtrip: 936 /
45,344. Allocation stacks identify AppKit AX observer cleanup, scroll-logger AX
remote tokens, and toolbar custom actions. The older unlogged 5,427-object /
184,224-byte report after much more activity cannot be rate-compared or assigned
wholesale to these stacks. Full bounded attribution is in the updated diagnostic
report. No application allocator was identified beyond main-entry frames; this
is not proof of universal absence of application leaks or an Apple-confirmed bug.

Final optimized owner install: PID 89855, source/signature/authenticated readiness
passed (`/tmp/nativeagent-ui-keyboard-final-install.log`). Final 14 tests / 4
suites passed in 0.574s after compilation, isolated data and mounted check enabled
(`/tmp/nativeagent-keyboard-final-regression.log`). Previously completed 30-test
UI regression remains documented above. Final live controls/exclusion/composer
checks passed; model and Trust settings were preserved. Profilers and temporary
allocation-logging process are stopped; the normal app remains in Chat.
No commit/push/release; all pre-existing dirt preserved. Remaining platform
allocations and focus/layout stalls are explicitly unresolved, so this is not a
claim that the entire UI is now leak-free or uniformly smooth.

Final Agent consultation (existing knowledge only, run D66FC10B-0FED-4E97-B369-847ED812978B): no verified source-owner fix or additional cleanup hook known. They confirmed that framework frames alone do not prove an app lifecycle is correct, hidden Chat is not an established culprit, and the measured stalls/leaks must remain explicitly unresolved. Receipt: `/tmp/nativeagent-final-agent-focus-advice.txt`. No fresh inspection or changes by Agent.
