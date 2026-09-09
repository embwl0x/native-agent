# Simplicity sweep — Mac review fixtures

Run `./script/snapshot_simplicity.sh` from this worktree. It uses the existing
DEBUG test entry, offscreen NSHostingView rasterization and ImageRenderer PNG
export. No app launch, window, desktop capture, provider request, AppModel,
persona or policy store is involved. Each PNG is exactly **1280 × 800 pixels**
(1x), with the shipped ShellFrame, ShellSidebarRail and appearance tokens.
The shelf's existing 2x renderer output remains unchanged.

| PNG | Sweep finding demonstrated |
| --- | --- |
| `onboarding-setup-light.png` | F2/F3: plain name/setup copy, blank names, abilities overview. |
| `onboarding-setup-dark.png` | F2/F3: the same setup step in dark appearance. |
| `onboarding-account-failure-light.png` | F2/F3: an account-read failure stays visible with Retry, rather than masquerading as an empty account list. |
| `onboarding-account-failure-dark.png` | F2/F3: account failure and Retry in dark appearance. |
| `trust-closed-light.png` | F5: access presets precede the closed Customize permissions disclosure. |
| `trust-closed-dark.png` | F5: presets and closed customization in dark appearance. |
| `trust-open-light.png` | F5: expanded customization retains the presets and explicit save/immediate-effect distinction. |
| `trust-open-dark.png` | F5: expanded customization in dark appearance. |
| `providers-closed-light.png` | F11: account setup and Chat remain visible with Optional model overrides closed. |
| `providers-closed-dark.png` | F11: accounts, Chat and closed overrides in dark appearance. |
| `providers-open-light.png` | F11: expanded overrides use customer-facing surface labels, including Task execution. |
| `providers-open-dark.png` | F11: expanded overrides in dark appearance. |
| `first-chat-no-provider-light.png` | F10: shipped first-chat guidance directs the user to existing account sign-in or an API key before sending. |
| `first-chat-no-provider-dark.png` | F10: the same guidance and inert composer in dark appearance. |

These are **presentation fixtures**, not captures of a running account or proof
of the complete production screens. Onboarding, TrustCenterView's access/policy
section and ProviderSettingsView's account/model choices have private state and
runtime dependencies. Their fixtures mirror the sweep's copy and disclosure
states using inert controls; unrelated Trust panels, additional sign-in cards,
and the full provider catalog are omitted. The provider fixture uses a compact
model-row arrangement to expose both columns in the review canvas. It does not
validate production picker geometry. No production views were edited to add
fixture hooks. The names remain blank or use “the agent”; all account/model
values are synthetic, with no credentials or host-account information.

Chat renders the shipped `ChatProviderConnectEmptyState` and
`MacChatComposerControlStrip` directly. ShellPageFrame, NativePanel, ProviderCard,
ProviderSection, ProviderCardTitle, typography and effect timing tags are also
the shipped components. Material samples the renderer's bundled macOS wallpaper
ground; no pixels come from the desktop. Fixture actions are inert.

The single focused DEBUG-boundary test checks that both render entry-point files
are entirely enclosed by one `#if DEBUG`, and type-checks the callable entries in
DEBUG. Rendering is opt-in through `SIMPLICITY_SNAPSHOT_DIR`; the script also runs
the existing BotsShelfTests suite. There are no new sleeps/timers, turn-resilience
paths or memory owners, so those inventories/maps require no new entries.

Validation on 2026-09-09: Mac product build passed with resolved versions and
updates disabled; BotsShelfTests passed all three tests; architecture blueprint
and timer inventory checks passed. All fourteen PNG dimensions were checked
with `sips` and both appearances were visually reviewed. Setup abilities and
expanded overrides continue below their scroll viewport, as shown; the targeted
copy and disclosure controls are visible. No live-runtime behavior was tested,
and no production bug is established by these synthetic fixtures.
