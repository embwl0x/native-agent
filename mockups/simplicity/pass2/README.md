# Shared form tokens — second pass

The production change lives entirely in `NativeAgentDesign.swift`:
`NativePanel` and `settingsCardSurface()` now share a 94%-opaque, warm-light /
charcoal-dark `formSurface` and a 55%-opaque `formBorder`. `ProviderCard` and
`SettingsCardSection` inherit the surface. `NativeAgentShell.secondary` becomes
`#35383E` in light appearance and `#C1C6CC` in dark. Glass, lamp, layout, actions,
control availability, and screen copy are unchanged.

## Evidence boundary

These PNGs render the **real production shell and shared form components** in
the existing DEBUG headless runner. Trust, Providers, and onboarding content
remains the original presentation fixtures. This checkout has no DEBUG fixture
store entry for those production screens; their private state and AppModel
dependencies belong to the three separately assigned screen owners. This token
pass does **not** establish full production-screen visual acceptance or prove
capability retention. No production fixture hooks were invented in their files.

The fourteen unsuffixed PNGs correspond exactly to the existing seven light/dark
states in the parent directory, at 1280 × 800. Compare parent and child with the
same basename: only the shared surface/secondary tokens change the presentation.
That includes the four Trust/Providers open/closed plates in both appearances,
plus both onboarding states and first chat. The original before PNGs are retained
unchanged in the parent directory (baseline commit `818fe61d`; this branch starts
at `a26f6487`). Fixture content and layout remain identical to that baseline.

| Comparison | Light | Dark |
|---|---|---|
| Trust, collapsed | [Before](../trust-closed-light.png) / [After](trust-closed-light.png) | [Before](../trust-closed-dark.png) / [After](trust-closed-dark.png) |
| Trust, expanded | [Before](../trust-open-light.png) / [After](trust-open-light.png) | [Before](../trust-open-dark.png) / [After](trust-open-dark.png) |
| Providers, collapsed | [Before](../providers-closed-light.png) / [After](providers-closed-light.png) | [Before](../providers-closed-dark.png) / [After](providers-closed-dark.png) |
| Providers, expanded | [Before](../providers-open-light.png) / [After](providers-open-light.png) | [Before](../providers-open-dark.png) / [After](providers-open-dark.png) |

The fourteen `*-1024-accessibility5.png` files use a 1024 × 700 canvas and the
largest SwiftUI Dynamic Type environment. Existing fixed-point `ShellType` fonts
do not scale with that environment. These images are a constrained-canvas check,
not proof that the application supports scalable typography. Changing font
metrics globally would exceed this token-only comparison.

## Reproduce

```sh
SIMPLICITY_SNAPSHOT_DIR="$PWD/mockups/simplicity/pass2" ./script/snapshot_simplicity.sh
```

The runner creates no NSWindow, reads no screen, starts no app runtime, and uses
the bundled Sonoma wallpaper. Fixture values are synthetic; no user stores,
credentials, policy, persona, or prompts-as-data are read or written.

## Composited contrast

The recorded measurements sample the strongest 1% of glyph pixels in the Trust
explanation and the Providers sign-in explanation. They compare median linear
sRGB luminance against an adjacent text-free strip of the rendered card using
`(lighter + 0.05) / (darker + 0.05)`. Both ink and background come from the PNG,
including compositing. In the 1280 × 800 PNGs, the Trust ink/background crops
are `(273,115,930,129)` / `(273,132,930,136)`; Providers uses
`(148,194,445,207)` / `(148,225,445,229)` (left, top, exclusive right/bottom).
The optional Python measurement helper was removed to honor the repository's
no-tracked-Python rule; the recorded results remain available. Antialiased
edge pixels are excluded; this is a representative glyph-core measurement,
not a claim about every label or every possible desktop background.

Results are recorded in [contrast.md](contrast.md).
Trust improves from 7.62:1 to 11.16:1 (light) and 4.01:1 to 4.71:1 (dark).
Providers improves from 7.46:1 to 11.09:1 (light) and 4.23:1 to 4.85:1 (dark).
The dark lamp brightens both ink and ground; these are composited samples, not
the much higher contrast one would calculate from the raw charcoal/gray tokens.

## Validation and remaining work

Mac product build passed with `--force-resolved-versions --skip-update --jobs 4`.
The closest runner suite, `BotsShelfTests`, passed all three tests and wrote all
28 PNGs in the final run. Architecture blueprint (504 Swift rows) and timer
inventory (192 sites) checks passed; `git diff --check` passed. No timer, memory, or
turn-resilience paths changed, so their inventories require no new entries.
No installation, desktop capture, browser use, push, or merge was performed.

Production Trust/Providers/onboarding fixtures remain a prerequisite for the
reviewer's requested screen acceptance. The existing projections' selection,
save-state, account-readiness, and capability-tour findings belong to the other
screen assignments and were left untouched. Fixed-size shell typography is a
real accessibility limitation observed in source, outside this color-token pass.
# Onboarding second pass

Production `OnboardingWizard`, including `IdentityAndAbilitiesStep`, its real
`DisclosureGroup`, text fields, and `OnboardingNavBar`. The existing
`script/snapshot_simplicity.sh` → `BotsShelfTests` → `SimplicitySnapshots.render`
entry selects only onboarding with:

```sh
SIMPLICITY_ONBOARDING_PASS2=1 bash script/snapshot_simplicity.sh
```

DEBUG injection supplies an in-memory `OnboardingWizardState` (Sam / Ada),
selects collapsed or expanded disclosure, and bypasses runtime loading. No
AppModel, provider client, user data, persona or policy stores are created.
The production wizard still requires AppModel for loading and actions.

The fixture attaches NSHostingView to an **unshown** AppKit window so the native
scroll document receives its actual layout. The window is never ordered onscreen,
made key, or activated, and is closed after rendering. AppKit appearance, SwiftUI
color scheme and active-control appearance are injected. PNGs are 1× bitmap
renders of this view hierarchy, not desktop captures or presentation projections.
The other screen fixtures are outside this pass.

## Files and reachability

Fourteen PNGs cover light/dark at 1280×800 (large/default text) and 1024×700
(accessibility5, the largest Dynamic Type category). Onboarding explicitly maps
that category to 2× text on macOS, where the initial ScaledMetric implementation
did not enlarge these fixed-font labels in the headless host.

- `onboarding-names-<width>-<theme>-0.png`: names, optional overview, Continue.
- `onboarding-overview-1280-<theme>-0.png` and `-1.png`: start and end; the end
  contains every complete capability row.
- `onboarding-overview-1024-<theme>-0.png`, `-1.png`, `-2.png`: overlapping
  positions covering the complete expanded content at maximum text size.
- `*-scroll.txt`: actual native viewport/content heights and capture offsets.
- `onboarding-contrast.json`: sampled composited colors, coordinates and ratios.

At 1024×700 the viewport is 600 points tall, the expanded content is 1516 points,
and offsets are 0, 480 and 916. The middle capture shows complete chat, project
and Mac entries; the last shows complete services, iPhone and improvement entries.
No entry has a line limit. The final card ends at y=608; the content viewport ends
at y=632 and Continue begins at y=648. The footer is a separate VStack child,
not a content overlay. At 1280×800 the viewport is 700 points and expanded content
821 points, with offsets 0 and 121. The collapsed names fit without scrolling at
both requested sizes. Continue is enabled by the two entered names; opening the
overview is optional and does not affect continuation.

All six capability IDs and complete descriptions remain available. The display
adapter translates both the bundled defaults and older start-response wording:
“keep receipts” → “show results”; “behind Trust settings” → “with your permission”.
Provider, completion, recovery and permission authority are unchanged.

## Composited contrast

Measurements use the final PNG RGB pixels: solid glyph interiors and adjacent
background samples after the gradient and opaque panels are composited. sRGB
channels are linearized, then luminance is `0.2126R + 0.7152G + 0.0722B`; contrast
is `(Llighter + 0.05) / (Ldarker + 0.05)`. Antialias fringe pixels are excluded.
The JSON records exact locations and glyph samples; numbers below are the lower
measured ratios across the requested sizes.

| Secondary content | Light | Dark |
| --- | ---: | ---: |
| Explanation | 8.12:1 | 9.71:1 |
| Name labels | 8.61:1 | 9.25:1 |
| Optional disclosure | 8.13:1 | 9.78:1 |
| Capability details on opaque panels | 8.61:1 | 9.25:1 |

Light ink is RGB (71,76,87), dark ink (204,209,219). Panels are opaque white
and RGB (41,43,48), respectively. All measured secondary text exceeds 4.5:1.

## Validation and limits

- Mac product built with `--force-resolved-versions --skip-update --jobs 4`.
- `BlankInstallOnboardingReachabilityTests`: 11 passed, run once.
- Headless snapshot entry: all 3 `BotsShelfTests` passed; inspected production
  names and overlapping expanded captures, checked all 14 PNG dimensions.
- Architecture blueprint and timer inventory checks passed. No production
  timer, turn or memory ownership changed, so those inventories/maps need no edit.
- `git diff --check` passed.

This is visual review evidence, not installation approval or a live account/setup
transaction test. No installation, browser control, desktop capture, push or merge.
The older provider-error presentation fixture remains outside this identity review;
these images make no claim about its production loading or alternate-provider setup.
# Trust simplicity pass 2 — 2026-09-09

These are headless renders of the **production `TrustCenterView`**, inside the
shipped `ShellFrame`, sidebar and `ShellPageFrame`. The old Trust presentation
projection has been removed from `SimplicitySnapshots.swift`.

The DEBUG fixture supplies a Safe policy to a temporary-root AppModel with
background tasks disabled, initializes the real view's draft/disclosure state,
and disables Security Center's live loading. The Security Center loading row is
fixture state, not a claim about the installed app. No window, browser, resident
runtime or desktop screenshot is used. The existing renderer composites the
bundled Sonoma wallpaper behind the actual shell material.

## Images

| Files | Viewport and state |
|---|---|
| `trust-closed-1280-{light,dark}.png` | 1280 × 800, customization folded |
| `trust-open-1280-{light,dark}.png` | 1280 × 800, customization expanded |
| `trust-closed-1024-largest-{light,dark}.png` | 1024 × 700, `.accessibility5`, folded |
| `trust-open-1024-largest-{light,dark}.png` | 1024 × 700, `.accessibility5`, expanded |
| `trust-open-full-{light,dark}.png` | Supplemental 1280 × 1500 viewport exposing the complete Access and policy controls, including Save policy |

The smaller screenshots show the real scroll viewport: staged controls continue
below its bottom edge. The taller images supplement them; they are not substitutes
for the requested sizes or captures of the entire Trust page. Shared `ShellType`
fonts use fixed point sizes, so injecting the largest Dynamic Type environment
does not enlarge those fonts. That shared typography limitation is outside this
area; these images do not establish full Dynamic Type support.

## What changed

- Saved presets have a checkmark, selected accessibility trait and strong outline.
  The saved policy determines `Safe · Saved`, `Work mode`, `Builder`, or `Full Mac`;
  any mismatch in preset-owned policy fields, including Developer mode, is Custom.
  Unsaved edits never masquerade as saved authority.
- Work mode denies writes outside approved workspaces; Builder asks first.
  The introduction covers files, shell and system actions, and distinguishes
  Trust from macOS permissions.
- Immediate access, Developer mode and Create backup controls are grouped
  separately from the staged policy controls. Save timing explicitly refers to
  subsequent action checks, replacing the yellow “next run” label.
- Observed policy changes reconcile untouched draft fields and retain edited
  fields. A deliberate preset replaces the draft; cancelling Full Mac confirmation
  retains it. Full Mac access changes preserve a draft unless a preset was chosen.
- Existing guardrail summary, Security Center, Full Mac duration, feature and Mac
  permissions, activity capture, policy map, advanced panels, simulator and backups
  remain reachable. Their runtime owners are unchanged.

## Composited contrast

Measured from the final PNGs, decoded with `NSBitmapImageRep` and converted to
sRGB, including shell material, wallpaper and the warm `ShellLamp` overlay.
For each label region, 20-pixel horizontal bins compare glyph interiors with a
nearby blank background row. Reported minima use the strongest glyph interior
in each text-bearing bin and a conservative background within that bin; edge
antialiasing is not treated as a separate text color. WCAG luminance uses the
sRGB transfer function and `(Llighter + 0.05) / (Ldarker + 0.05)`.

| Sampled labels | Light minimum | Dark minimum |
|---|---:|---:|
| Access section heading | 6.20:1 | 6.19:1 |
| Intro and preset timing | 6.20:1 | 4.90:1 |
| Four preset descriptions | 5.46:1 | 5.19:1 |
| Immediate heading and explanation | 6.20:1 | 5.45:1 |
| Developer mode explanation | 6.20:1 | 7.76:1 |
| Draft heading and save timing | 6.20:1 | 9.28:1 |

These minima span the two requested sizes and the supplemental tall images
where the label is visible. The weakest dark sample is white on `#7F6F55` in
`trust-open-1024-largest-dark.png`, the bin starting at x=368, y=148. The weakest
light sample is `#626771` on `#F9FBFD`, in Safe's description. Full per-label
measurements and coordinates are in [trust-contrast.txt](trust-contrast.txt).
The black base in dark mode is intentional: the shared shell adds warm light
*over* the page. The earlier lighter base failed contrast after that composition.
These are fixture-composite measurements, not a claim for every desktop setting.

## Reproduction and validation

Run from the worktree, using the task's prescribed Git cache environment before
Swift commands. The snapshot script also exports that environment itself.

```sh
swift build --force-resolved-versions --skip-update --product NativeAgentApp --jobs 4
swift test --force-resolved-versions --skip-update --jobs 4 --filter TrustCenterPresetButtonsEvalTests
SIMPLICITY_TRUST_ONLY=1 bash script/snapshot_simplicity.sh
swift script/check_architecture_blueprint.swift --repo .
swift script/check_timer_inventory.swift
```

Mac build passed. The closest suite passed all five tests, including isolated
real Developer mode and Full Mac writes, repeated draft reconciliation, and
saving the retained edits. The existing snapshot harness passed all three tests;
visual iterations reran only that harness after color/layout adjustments.
Blueprint and timer checks passed. No install, push or merge was performed.

Unchanged shared issues visible here: fixed-point ShellType fonts, the warm
overlay's effect on contrast, and the guardrail summary's existing agent pronouns.
Those owners are outside this assignment. Turn and memory ownership did not
change, so their maps require no new contract entries.
