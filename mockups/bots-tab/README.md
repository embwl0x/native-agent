# Bots tab design preview

The images below preserve the first pass. Current full-page routing and the
shipped-chrome second pass are documented in [pass2/README.md](pass2/README.md).
The sheet-routing description below applies only to the first pass.

Opt in using the defaults-backed `uiBotsShelfPreview` flag (default false),
following the existing `uiClassicShell` preference pattern. The current AREA
does not own ContentView or SidebarItem: the Bots rail entry opens the preview
as a sheet, with an explicit close control. It does not change saved navigation.
With the flag off the original rail branch, order and spacing are preserved.

Run `bash script/snapshot_bots_shelf.sh` to render these SwiftUI views with
ImageRenderer at 2×, without launching the resident runtime, opening windows,
or capturing the Mac screen:

| PNG | Contents | Pixel size |
| --- | --- | --- |
| bots-list-light.png | Three bots, light | 2160 × 1440 |
| bots-list-dark.png | Three bots, dark | 2160 × 1440 |
| bot-detail-light.png | Release notes, dated mixed-health entries and controls, light | 2800 × 2800 |
| bot-detail-dark.png | Same detail, dark | 2800 × 2800 |
| grouped-rail-light.png | Existing places grouped above configuration, plus Bots, light | 2400 × 2000 |
| grouped-rail-dark.png | Same grouping, dark | 2400 × 2000 |

The DEBUG fixture uses StandingBots definitions and shelf entries in memory.
Edit brief and pause/resume change only preview state. Run once explains the
budget and explicitly reports that no run started. Spend is shown against the
per-run token/time budget. No live store is opened or acknowledged, no provider
is called, and no budget is spent. The sample source links use example.com.

The renderer uses the shipped shell typography, colours, page frame and lamp
over a deterministic teal ground. Desktop-dependent Liquid Glass cannot be
captured by ImageRenderer; these images judge layout, copy and colour, not
the compositor's live desktop blur. No charts, attention badges or animations.
For detail images the renderer lays out the same detail content without its
interactive ScrollView, which ImageRenderer otherwise leaves blank.
