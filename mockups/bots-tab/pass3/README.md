# Bots shelf — third design pass

Three targeted changes in `Sources/NativeAgentApp/BotsShelfView.swift`:

- The Results segments use dark selected text in dark mode and white
  selected text in light mode over the existing `NativeAgentShell.needsYou`
  accent. The same selection styling applies to Catch up and All runs.
  Native segmented pickers override label ink for this custom tint, so two
  plain SwiftUI buttons preserve the two-segment layout while explicitly
  owning selected ink. Both bind to the existing `allRuns` state and expose
  the selected accessibility trait; no new navigation state is introduced.
- The entry envelope shows one warning icon and the recorded coverage cause.
  The incomplete fixture reads “The secondary source was not checked before
  the time limit; additional changes may be missing.” Exhaustion status and
  token/time amounts are inside the folded Run budget disclosure.
- The folded history reads “2 no-change runs · 2 unread”; with the visible
  unread finding, this accounts for Catch up’s three unread entries.

The entry points remain `BotsShelfPreviewPage` → `BotsShelfView` →
`BotsShelfEntryView`. The flag remains off by default and fixtures remain
DEBUG-only. Report surfaces, flexible bodies, folded history, rail selection,
and local preview interactions retain the approved pass-two structure.

## Captures

| Appearance | 1280 × 800 points | 820 × 800 points |
| --- | --- | --- |
| Light list | [Image](list-1280-light.png) | [Image](list-820-light.png) |
| Dark list | [Image](list-1280-dark.png) | [Image](list-820-dark.png) |
| Light detail | [Image](detail-1280-light.png) | [Image](detail-820-light.png) |
| Dark detail | [Image](detail-1280-dark.png) | [Image](detail-820-dark.png) |

All eight PNGs are 2× exports from the existing DEBUG `BotsShelfSnapshots`
harness, called by `BotsShelfTests`. Offscreen NSHostingView rasterization
preserves native controls, then ImageRenderer exports the composed image.
The shipped shell samples the bundled Sonoma wallpaper within the offscreen
host. These are headless layout/material captures, not live desktop captures.
No window, browser, resident runtime, or user data root is opened.

## Measured selected-control contrast

Measured from the final composited PNGs, converted to sRGB, using the
lettering core and modal interior fill of the selected Catch up segment.
This includes the shared dark shell light overlay and the headless export’s
color conversion; these are not nominal palette ratios. Relative luminance
uses the sRGB transfer function and `(Llighter + 0.05) / (Ldarker + 0.05)`.
Antialiased edge pixels are not treated as the foreground color.

| Detail capture | Sample rectangle, PNG pixels (x, y, w, h) | Ink | Fill | Contrast |
| --- | --- | --- | --- | --- |
| 820 dark | 385, 550, 255, 38 | `#6B624C` | `#70FDFF` | **4.94:1** |
| 1280 dark | 750, 550, 255, 38 | `#6C624C` | `#70FDFF` | **4.92:1** |
| 820 light | 385, 550, 255, 38 | `#FFFFFF` | `#007289` | **5.57:1** |
| 1280 light | 750, 550, 255, 38 | `#FFFFFF` | `#007289` | **5.57:1** |

The sampled core-to-fill ratios exceed 4.5:1 in these fixtures. This is a
measurement of the requested control in the supplied captures, not a
whole-page or arbitrary-desktop contrast certification. Reproduce with
`measure-contrast.swift`, after exporting the environment below, for example:

```sh
swift mockups/bots-tab/pass3/measure-contrast.swift mockups/bots-tab/pass3/detail-820-dark.png 385 550 255 38
```

## Reproduce

Run from the worktree root with the seeded dependency cache:

```sh
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0="url.file://$HOME/Projects/NativeAgent/.build/checkouts/GRDB.swift/SQLiteCustom/src.insteadOf"
export GIT_CONFIG_VALUE_0="https://github.com/swiftlyfalling/SQLiteLib.git"
export GIT_CONFIG_KEY_1=protocol.file.allow
export GIT_CONFIG_VALUE_1=always
swift build --force-resolved-versions --skip-update --product NativeAgentApp --jobs 4
BOTS_SHELF_SNAPSHOT_DIR="$PWD/mockups/bots-tab/pass3" swift test --force-resolved-versions --skip-update --jobs 4 --filter BotsShelfTests
swift script/check_architecture_blueprint.swift --repo .
swift script/check_timer_inventory.swift
```

The architecture family narrative is updated additively. No files, ownership,
timers, memory, or turn contracts were added, so the timer inventory, memory
map, and turn resilience map need no changes. No installation or live UI
verification is part of this headless, default-off preview assignment.

## Validation and scope

- Integrated NativeAgentApp build passed with pinned, cached dependencies.
- The existing BotsShelfTests suite passed (2 tests). Only its headless capture
  test was rerun while resolving the control’s composited contrast; the final
  render passed and all eight final images were visually inspected.
- Architecture blueprint and timer inventory checks passed; `git diff --check`
  passed. No extra test suite, eval, live UI probe, or new test was added.
- No unrelated bug was established. The shared shell light overlay affects
  foreground contrast, but the shell is outside this assignment and was left
  unchanged; the selected-control fix accounts for it locally.
