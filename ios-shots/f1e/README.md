# iOS secondary screens — f1e, 2026-09-07

40 unmodified `simctl io screenshot` captures from F1E-iPhone (iPhone 17, iOS 26.5, 1206×2622). This isolated simulator uses the same device type/runtime as R26-iPhone, where the build and test ran. A concurrent fleet task replaced the app on the shared simulator, so the complete evidence set was regenerated on F1E-iPhone. Standard captures use Large text. The four AX2 captures combine Accessibility Large, Reduce Transparency, and Increase Contrast.

| Family / source owner | Light | Dark | Rule demonstrated |
| --- | --- | --- | --- |
| SettingsViewFull | [settings-light.png](settings-light.png) | [settings-dark.png](settings-dark.png) | Native form rows, wrapping connection status, menu-based appearance selection. |
| ActivityView | [activity-light.png](activity-light.png) | [activity-dark.png](activity-dark.png) | Populated approval and Inbox previews, neutral badges, readable action titles. |
| ApprovalsView | [approvals-light.png](approvals-light.png) | [approvals-dark.png](approvals-dark.png) | Populated request, full wrapping title, quiet payload reading area, approval action. |
| InboxView | [inbox-light.png](inbox-light.png) | [inbox-dark.png](inbox-dark.png) | Populated summary, neutral source metadata, opaque reading surface. |
| DeskView / MobileDeskView | [desk-light.png](desk-light.png) | [desk-dark.png](desk-dark.png) | Populated task with a long project name and neutral status. |
| WorkshopView | [workshop-light.png](workshop-light.png) | [workshop-dark.png](workshop-dark.png) | Directed tasks use the visible title Desk; a populated task retains full objective text. |
| AutonomyView | [autonomy-light.png](autonomy-light.png) | [autonomy-dark.png](autonomy-dark.png) | Populated Self-Improvement proposal with readable proposed text and Mac-only action explanation. |
| SkillsToolsView / SkillLifecycleView | [skills-light.png](skills-light.png) | [skills-dark.png](skills-dark.png) | Populated skill, neutral lifecycle/source metadata, compact menu selectors. |
| KnowledgeGraphView | [graph-light.png](graph-light.png) | [graph-dark.png](graph-dark.png) | Populated entity; the real unavailable-snapshot warning participates in layout instead of covering a row. |
| TurnInspectorView | [turns-light.png](turns-light.png) | [turns-dark.png](turns-dark.png) | Populated turn metrics in native SF type with neutral metadata. |
| ProviderSettingsView | [providers-light.png](providers-light.png) | [providers-dark.png](providers-dark.png) | Long provider name wraps; routing controls are reachable through Models by activity. |
| PairingView | [pairing-light.png](pairing-light.png) | [pairing-dark.png](pairing-dark.png) | Modest 56pt symbol, neutral setup copy, opaque pairing-key status surface. |
| MacToolsView | [mac-tools-light.png](mac-tools-light.png) | [mac-tools-dark.png](mac-tools-dark.png) | Real unavailable-policy state with one modest symbol and a useful Mac setup instruction. |
| MacIntegrationView | [mac-integration-light.png](mac-integration-light.png) | [mac-integration-dark.png](mac-integration-dark.png) | Real unpaired state, readable policy explanation, clearly labeled unconfirmed defaults. |
| AdvancedView | [more-light.png](more-light.png) | [more-dark.png](more-dark.png) | Neutral navigation labels and icons, a primary pairing action, and the Desk destination. |
| AdvancedView / StatusDetailView | [status-light.png](status-light.png) | [status-dark.png](status-dark.png) | Connection facts read as text rather than colored glass statistics. |
| AdvancedView / RunsLogView | [runs-light.png](runs-light.png) | [runs-dark.png](runs-dark.png) | Real unavailable state with a modest symbol and a useful explanation. |
| SystemToastBar / MacSnapshotFreshnessBadge | [toast-light.png](toast-light.png) | [toast-dark.png](toast-dark.png) | One root floating toast uses system glass; freshness text is separate, compact reading content. |

| Accessibility capture | Rule demonstrated |
| --- | --- |
| [settings-light-ax2-contrast-opaque.png](settings-light-ax2-contrast-opaque.png) | Appearance label/value stack naturally; the connection status stays fully readable. Native rows remain opaque. |
| [settings-dark-ax2-contrast-opaque.png](settings-dark-ax2-contrast-opaque.png) | Appearance label/value stack naturally; the connection status stays fully readable. Native rows remain opaque. |
| [activity-light-ax2-contrast-opaque.png](activity-light-ax2-contrast-opaque.png) | Section facts stack, the long approval title wraps, and the content surface has one stronger boundary. |
| [activity-dark-ax2-contrast-opaque.png](activity-dark-ax2-contrast-opaque.png) | Section facts stack, the long approval title wraps, and the content surface has one stronger boundary. |

## Reproduction

Build the NativeAgentMobile scheme for `platform=iOS Simulator,name=R26-iPhone`, with `-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates CODE_SIGNING_ALLOWED=NO`. Install the Debug app with `simctl install` on an isolated iPhone 17 / iOS 26.5 simulator. Use that simulator's UDID explicitly in every command when other simulators are booted.

Launch `io.github.embwl0x.nativeagent.ios` with:

```text
-NativeAgentMobile.pairingSkipped YES
-NativeAgentMobile.appearance system
-initialTab more
-designScreen <capture-family>
```

Use the filename stem from the table as the capture family. Activity uses `-initialTab activity -designScreen activity`. More uses `-initialTab more` without `-designScreen`. Terminate the app between captures. Allow navigation to settle before taking the screenshot. No Mac UI automation or Mac screenshots were used.

Appearance and accessibility setup (set `F1E_SIMULATOR` to the isolated simulator’s UDID):

```sh
xcrun simctl ui "$F1E_SIMULATOR" appearance light
xcrun simctl ui "$F1E_SIMULATOR" content_size accessibility-large
xcrun simctl ui "$F1E_SIMULATOR" increase_contrast enabled
xcrun simctl spawn "$F1E_SIMULATOR" defaults write com.apple.Accessibility EnhancedBackgroundContrastEnabled -bool YES
```

Use `appearance dark` for dark captures. Relaunch after changing accessibility settings. The simulator was restored to Large text, light appearance, normal contrast and transparency afterward.

## Wiring and scope

All assigned screen files were styled. Shared consumers live in `AdvancedPresentation.swift`: `mobileReadingScreen`, `MobileReadingSurface`, `MobileAdaptiveRow`, `MobileActionRow`, `MobileReadingEmptyState`, and `MobileReadingStat`. They consume the unchanged `NativeAgentMobileTheme` canvas, content, accentText/onAccent, spacing, radius, glass and typography roles. Navigation status now has an unconstrained compact row below navigation; this fixes iOS 26 clipping the old toolbar label into a circular slot. Toasts consume the shared glass modifier, including its Reduce Transparency fallback.

`AdvancedView` supplies the DEBUG routes. `MobileDesignSamples` projects fixtures only when the corresponding live collection is empty. Activity, Approvals, Inbox, Desk, directed tasks, Self-Improvement, skills, graph, turn summaries and Providers are populated. These fixtures are process-local; no sample records are written to sync snapshots, history, canonical memory, persona or the Mac. Capture interaction is disabled, and the Inbox capture does not request notification permission.

Settings, More, Pairing and Status already have useful content without fixture health claims. Mac Tools and Mac Integration retain real unpaired/unavailable permission state; no sample grants were fabricated. The extra Runs capture documents the unavailable state. The samples demonstrate composition, not live iCloud delivery or remote actions. These are first-viewport captures, not a claim that every expanded detail or scrolled position was photographed. Long content remains scrollable in normal operation.

Chat, ChatBubbleViews, Memories, ContentView and both theme/design foundations were left to their owners. Native tab icon size and tab accent in these captures are main's existing root styling. No missing color token required a substitute; the shared foundation lacks a reusable contrast-aware reading-card/secondary-screen layout modifier, so this area composes those existing tokens locally without editing the theme.

## Validation

- Integrated simulator `xcodebuild build` passed.
- `ActivityNavigationDestinationsEvalTests` ran once: 1 test passed, zero failures.
- Three existing test expectations that pinned the old Workshop copy were updated with the Desk rename; the full test target compiled with `build-for-testing`.
- Architecture blueprint and timer inventory checks passed; `git diff --check` passed.
- No new Swift files, timers, transport authority or memory owners. The blueprint, timer inventory, resilience map and memory map document the unchanged boundaries.

The simulator exposed the existing root toast placement over the tab chrome; ContentView owns that placement and remains outside this area. Mac Integration's missing-snapshot view also retains its existing disabled placeholder defaults and explicit warning. Neither is evidence of a live permission grant.
