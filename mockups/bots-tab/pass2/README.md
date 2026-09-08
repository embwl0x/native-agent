# Bots shelf — second design pass

The default-off `uiBotsShelfPreview` experiment now routes through
`SidebarItem.bots` and ContentView as a full rail page. Bots owns the rail
selection. Rows open a bounded reading column; “All bots” returns to the shelf.
The original unflagged destination lists are unchanged. The sample roster is
compiled only in DEBUG and never opens or writes a resident store.

## Review images

Eight ImageRenderer captures at 2×, each 800 points high:

| Files | Window in points | Content |
| --- | --- | --- |
| list-1280-light.png / list-1280-dark.png | 1280 × 800 | Full shelf |
| detail-1280-light.png / detail-1280-dark.png | 1280 × 800 | Default catch-up |
| list-820-light.png / list-820-dark.png | 820 × 800 | Narrow shelf |
| detail-820-light.png / detail-820-dark.png | 820 × 800 | Narrow catch-up |

These compose the shipped ShellFrame, ShellSheet, ShellLamp,
ShellSidebarRail and BotsShelfView. A single bundled macOS Sonoma wallpaper
is placed behind the shared sheet; there are no per-column backgrounds
substituting for the shell. Plain neutral backing belongs only to the bounded
reading/list content. Teal marks Bots selection and actions; warning text and
icons accompany amber. The long title wraps, and the fixture includes seven
runs across multiple days, partial coverage, failure, findings, no changes,
sparse read state and a paused bot.

ImageRenderer cannot directly draw AppKit glass, segmented controls or links.
The renderer rasterizes the actual page, including its ScrollView and native
controls, in an offscreen NSHostingView at 2×, then exports through ImageRenderer.
Only in that host, the existing glass uses active within-window blending so it
can sample the fixture wallpaper instead of an absent desktop behind a window.
The bundled wallpaper is blurred deterministically under the actual shell coat.
This is layout/material composition evidence, not a capture of the live desktop
compositor. No NSWindow, app runtime, browser, screen capture, provider or
resident data access is involved.

## Behavior

Catch-up includes unread entry IDs and the latest failure/coverage warning,
including a warning already read. The latest warning comes first. All runs
remain reachable through the adjacent control. No-change runs are folded into
a disclosure and retain separate dates, read states, evidence, budgets and
coverage intervals. Gaps between recorded intervals are explicitly unchecked.
Viewing a preview does not acknowledge entries.

The stable envelope is date, outcome/coverage, read state, optional evidence,
and bot-defined body. The example body includes shorthand and freeform prose;
findings/change fields are rendered as prose without mandatory section labels.
Empty uncertainty text and duplicate outcome/budget lines are absent.
Real uncertainties appear next to coverage; incomplete runs that reached
their budget show exhaustion before the body. Token/time amounts are below
results in “Run budget”. Dates are local with exact timestamps in help text.
Next scheduled run is a fixture value, not an inferred successful check.
Edit/pause/resume affect only local preview values; Run once says no run started.

## Reproduce

From this worktree, without fetching dependencies:

```sh
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0="url.file://$HOME/Projects/NativeAgent/.build/checkouts/GRDB.swift/SQLiteCustom/src.insteadOf"
export GIT_CONFIG_VALUE_0="https://github.com/swiftlyfalling/SQLiteLib.git"
export GIT_CONFIG_KEY_1=protocol.file.allow
export GIT_CONFIG_VALUE_1=always
swift build --force-resolved-versions --skip-update --product NativeAgentApp --jobs 4
BOTS_SHELF_SNAPSHOT_DIR="$PWD/mockups/bots-tab/pass2" swift test --force-resolved-versions --skip-update --jobs 4 --filter BotsShelfTests
```

Routing required the two authorized out-of-area edits:
`Sources/NativeAgentApp/Models/SidebarModels.swift` adds the Bots case/icon,
and `Sources/NativeAgentApp/ContentView.swift` hosts the page.
The additionally authorized one-line routing edit adds `.bots` to the no-fetch
branch in `Sources/NativeAgentApp/AppModel+ChatSessions.swift`.
The architecture family map moves with the implementation. No timer, turn
resilience or memory ownership changes were introduced.

## Validation

The integrated NativeAgentApp build passed with pinned, cached dependencies.
The existing BotsShelfTests suite passed (2 tests); the snapshot test was rerun
after fixing the native-control rendering failure. All eight final images were
visually inspected. Blueprint and timer inventory checks passed. No installed
app or live UI verification was performed, as required by this assignment.
