# Rail grouping comparison

Pictures only; no production navigation change. All nine images use the real
`ShellFrame`, `ShellPageFrame` and `ShellRailItem`, the same static Chat detail,
and the same offscreen renderer at one pixel per point. No window is shown,
screen captured, app installed, or resident data loaded.

| Version | Change | Possible cost |
| --- | --- | --- |
| Baseline | Today's ungrouped destination order, with preview Bots appended after Desk. | Twelve equally weighted rows above Settings require scanning the whole list. |
| Option A | Quiet uppercase EVERYDAY / CONFIGURE headings. Everyday: Chat, Today, Memories, Desk, Notifications, Bots. Configuration: Personality, Providers, Trust, Connectors, Capabilities, Diagnostics. | Headings add scanning distance and push Chat below its existing baseline. Reordering disrupts learned positions; category names may make an occasional destination harder to place. |
| Option B | The same two groups and order, separated by one inset hairline with no headings. | Less vertical overhead than A, but the boundary explains less. Reordering still disrupts muscle memory. |

Settings remains pinned at the bottom in all three. Rows retain the production
112-point rail width, 44-point height, 14-point word inset, 14-point medium text,
four-point stack spacing, 14-point top/bottom padding, trailing hairline and
Chat selection bar (two by twenty points). The real shared sheet and lamp sit
behind the whole shell; the renderer uses bundled wallpaper as the offscreen
glass backdrop. These are headless material comparisons, not desktop captures.

Bots is explicitly enabled in this fixture, without writing the preview
preference. It joins only the everyday group in A/B and disappears when the
fixture's Boolean is false. The baseline preserves the relative order of all
shipped destinations and appends Bots because today's unflagged list has no Bots
position. The existing flag-on production rail already uses a different grouped
proposal; it is deliberately not the baseline for this requested comparison.

Each version has light and dark 1280×800 renders plus a light 1024×700 pass with
`dynamicTypeSize = .accessibility5`. The current production rail uses fixed-size
fonts and fixed row heights, so that largest-text environment does **not** enlarge
its words. These pictures preserve that limitation rather than inventing a new
accessibility treatment. A uses ten-point medium tertiary headings with two-point
vertical padding; B uses the shared hairline token with six-point vertical padding.

Reproduce from the worktree after exporting the five Git configuration variables
specified in the task:

```sh
SIMPLICITY_RAIL_ONLY=1 SIMPLICITY_SNAPSHOT_DIR="$PWD/mockups/simplicity" \
  swift test --force-resolved-versions --skip-update --jobs 4 --filter BotsShelfTests
```

The existing DEBUG test entry calls `SimplicitySnapshots.render`; the rail-only
selector avoids all other fixtures and skips provider fixture creation. No timer,
turn-resilience or memory ownership changed, so their inventories/maps stay intact.

PNG names are `{baseline,option-a,option-b}-1280x800-{light,dark}.png` and
`{baseline,option-a,option-b}-1024x700-largest-light.png`.

Verification: Mac product built with `--disable-build-manifest-caching`,
`NativeAgentAppTests` target built, and all three existing `BotsShelfTests`
passed in one run. Blueprint and timer checks passed. Every PNG was opened and
visually inspected: all destination labels and Settings remain visible, Chat's
bar is retained, and the detail stays consistent across variants. A is the
densest at 700 points high; B retains the original Chat baseline. No additional
production bug was established; fixed-size rail typography remains an existing
accessibility limitation outside this picture-only assignment.
