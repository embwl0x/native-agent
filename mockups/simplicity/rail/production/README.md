# Production rail — Option B

These offscreen renders host the production `ShellSidebarRail` inside
`ShellFrame`, beside the same static Chat detail used in the design comparison.
The rail has no headings, one inset decorative hairline between the two groups,
and Settings pinned at the bottom. Bots uses the existing fixture override;
the persisted preview preference is never changed.

Default Dynamic Type (`.large`), 1280 × 800, one pixel per point:

- `rail-bots-off-1280x800-light.png`
- `rail-bots-off-1280x800-dark.png`
- `rail-bots-on-1280x800-light.png`
- `rail-bots-on-1280x800-dark.png`

The existing four PNGs retain `.accessibility5`, the largest Dynamic Type
setting, at one pixel per point, with Bots enabled:

- `rail-1280x800-largest-light.png`
- `rail-1280x800-largest-dark.png`
- `rail-1024x700-largest-light.png`
- `rail-1024x700-largest-dark.png`

**Unresolved limitation:** the production rail uses fixed-size fonts and row
heights. Its words do not scale at the largest Dynamic Type size. This change
preserves that existing limitation; these images do not prove scalable rail
typography.

The existing renderer rasterizes the real view hierarchy without a window or
screen capture. Bundled wallpaper supplies the offscreen material backdrop.
No app is installed or launched, and no resident data is loaded.

Keyboard and selection finding: `ShellSidebarRail` is a `VStack` of ordinary
`ShellRailItem` buttons. There is no custom arrow-key handler or explicit focus
order; keyboard focus relies on SwiftUI's default view order and macOS keyboard
navigation settings. This is a model/source check, not a live keyboard test.
`railKeyboardModelOrderMatchesVisualOrder(botsEnabled:)` pins both gate states:
Chat, Today, Memories, Desk, Notifications, [Bots], Personality, Providers,
Trust, Connectors, Capabilities, Diagnostics, Settings. It also pins the actual
view grouping order. The divider is a plain Rectangle with hit testing disabled
and accessibility hidden, no button, focus modifier or selection tag. Every
button writes its own `SidebarItem` into the shared selection binding; selected
styling compares normalized destinations, including bottom-pinned Settings.
`ContentView.selection` normalizes reads and writes and sends activation through
`selectSidebarItem`; regrouping does not change that routing binding.

Validation: `swift build --disable-build-manifest-caching --product NativeAgentApp`
and `swift build --target NativeAgentAppTests` passed (both with
`--force-resolved-versions --skip-update --jobs 4`). The filtered run below passed
five tests, including both keyboard-model arguments. Timer inventory and
architecture blueprint checks passed. All eight PNGs were opened and inspected:
labels, Chat selection marker, divider and bottom Settings are visible without
clipping. The four largest-text files reproduced byte-for-byte unchanged.
No additional production bug was established. The unresolved font limitation
above remains outside this evidence-only change.

After exporting the task's five Git configuration variables, reproduce with:

```sh
SIMPLICITY_RAIL_PRODUCTION=1 SIMPLICITY_SNAPSHOT_DIR="$PWD/mockups/simplicity" \
  swift test --force-resolved-versions --skip-update --jobs 4 \
  --filter 'BotsShelfTests|NativeAgentAppCoordinatorTests.shellRailIsFivePlaces'
```
