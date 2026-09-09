# Capabilities and personality copy review

2026-09-09. Scoped evening fleet W5 implementation.

- `CapabilitiesView.nativeMacPower` offers Show all actions / Show fewer actions
  for more than six loaded records. Expanded rows use the same
  `NativeMacPowerPanelPresentation.action`, checked admission dictionary, and
  `AppModel.runNativeAction` callbacks. The count explicitly describes loaded
  records. The readiness panel retains its detailed status and probes.
- `PersonalityView.docsPanel` labels the existing editor by purpose.
  `PersonalityDocumentPurpose` supplies each explanation; exact filenames stay
  visible beneath it. Existing per-document drafts, save, reload, and read-only
  USER handling remain. MEMORY is optional and absent from the live editor
  catalog, so its explanatory note does not advertise an editor.
- `SlimSettingsView` reuses `ProviderSettingsSurfaceLabel` for Creative
  exploration, says App status, and limits the embeddings claim to embeddings.
- `InboxView` names the notification category, including accessibility.
  `DeskPageView.workingRows` counts child parts of parent assignments.
  Workflow copy points to requesting work in Chat and following it on Desk.
- The architecture blueprint documents the presentation wiring. No timers,
  turn ownership, or memory ownership changed, so their inventories/maps did
  not need edits.

## Visual evidence

The DEBUG `renderCopyReview(to:)` methods in the two edited views mount the
actual sections inside `ShellFrame` / `ShellPageFrame` and call
`BotsShelfSnapshots.write` (offscreen hosting plus ImageRenderer). Temporary
AppModels have background tasks disabled. No window, desktop capture, browser,
installed app, or user data root was used.

All eight PNGs were inspected for visible labels, controls, and clipping:

| State | Light | Dark |
| --- | --- | --- |
| Six of eight loaded actions | [PNG](actions-collapsed-light.png) | [PNG](actions-collapsed-dark.png) |
| Eight of eight loaded actions | [PNG](actions-expanded-light.png) | [PNG](actions-expanded-dark.png) |
| Editable identity | [PNG](personality-soul-light.png) | [PNG](personality-soul-dark.png) |
| Generated, read-only About you | [PNG](personality-user-light.png) | [PNG](personality-user-dark.png) |

The native actions fixture uses eight shipped action records, not the person's
registry. It does not invoke actions. Personality content is synthetic.

## Validation

Each Swift command used the five required GIT_CONFIG exports from the task.

- PASS: `swift build --force-resolved-versions --skip-update --disable-build-manifest-caching --product NativeAgentApp`
- PASS: `swift build --force-resolved-versions --skip-update --target NativeAgentAppTests`
- PASS: `swift script/check_timer_inventory.swift` — 192 sites, 127 rules.
- PASS: `swift script/check_architecture_blueprint.swift --repo .` — 16 families, 507 rows.
- PASS: `swift test --force-resolved-versions --skip-update --filter SlimSettingsStatusLineBehaviorEvalTests` — 2 tests in the existing suite.
  Set `CAPABILITIES_COPY_SNAPSHOT_DIR="$PWD/mockups/simplicity/round3/capabilities-copy"`
  to reproduce the images while running that suite.
- PASS: `git diff --check`.

Builds and the same suite were repeated only to resolve an input modified
during compilation and visual-review corrections to the fixture shell and
footer direction. No new test cases or additional suites were introduced.
Build output contains existing warnings.

No iOS changes, install, merge, or push. No unrelated bug was confirmed.
