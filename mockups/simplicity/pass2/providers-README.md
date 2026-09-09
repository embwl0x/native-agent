# Providers — production view, second pass

The `providers-*.png` files render the **real `ProviderSettingsView`**, inside
the shipped `ShellFrame`, sidebar and `ShellPageFrame`. This replaces the
previous Providers presentation projection. No Mac window, browser or screen
capture is used, and nothing is installed.

Reproduce from the worktree root:

```sh
PROVIDERS_SNAPSHOT_ONLY=1 bash script/snapshot_simplicity.sh
```

`BotsShelfTests` calls the DEBUG-only `SimplicitySnapshots.renderProviders(to:)`.
The fixture creates a temporary data root, writes Chat/iPhone/Telegram routing
choices, resolves them through `SwiftNativeProviderRouting`, and gets the
supported providers and model catalogs from the production `NativeClient`.
A fixture registry round-trip supplies one explicitly simulated connected
ChatGPT account. There are no real credentials or authentication requests.
An `AppModel(startBackgroundTasks: false)` hosts the view; its DEBUG initializer
starts with those receipts and suppresses the initial refresh task. All UI
controls and save closures are production controls, not screenshot replicas.
The temporary root is removed after rendering.

Eight images cover folded/open overrides in light/dark at 1280 × 800 and
1024 × 700. The smaller size sets `DynamicTypeSize.accessibility5`, the largest
Dynamic Type environment value. The existing shared `ShellType` typography
uses fixed point sizes on macOS; this setting does not turn those fonts into
scalable text. Images are exact pixel dimensions at 1×.

Account readiness appears before Manage; reconnect is secondary. Every row
in the supported provider catalog remains an actionable setup route:

| Provider | Setup route |
| --- | --- |
| ChatGPT | Account sign-in through the ChatGPT disclosure in its configuration sheet |
| Codex CLI | Account configuration and the existing ChatGPT sign-in route |
| Anthropic | API-key configuration |
| Anthropic OAuth / Setup-Token | OAuth configuration; setup-token input remains in the Sign in disclosure |
| OpenAI | API-key configuration |
| OpenRouter | API-key configuration |
| Moonshot AI (Kimi) | API-key configuration |
| Kimi Code | Subscription API-key configuration |
| xAI Grok | Account sign-in |

Additional registry-provided accounts also use the same unfiltered setup list;
the model picker alone filters for usable or previously selected accounts.
No model, reasoning effort, Fast option, provider authentication method,
Telegram navigation or saved selection was removed. The full overrides list
scrolls; opening it writes nothing. Its source label distinguishes inherited
routing defaults from explicit stored choices, even when a saved choice matches
Chat. Inherited routing defaults can differ by activity.

The fixture simulates iPhone and Telegram using Fast and leaves other activity
defaults unpinned. This demonstrates a compact exception summary and both
selection origins without touching a user's choices. Readiness is fixture
evidence only, not a live provider connection test.

## Composited contrast

Measured from the final PNG pixels, including the shell's warm lamp overlay;
nominal SwiftUI color values alone would miss its effect. The first render
exposed intro contrast as low as 3.71:1 in dark mode. The intro now has its own
panel and dark Providers panels use a darker fill.

[providers-contrast.csv](providers-contrast.csv) records each image, label crop,
background scanline, sampled RGB pair and computed ratio. The measurement uses
solid glyph-core pixels (excluding antialiased edges) and the most adverse
nearby background along the label width. It converts sRGB channels to linear
light, calculates relative luminance with weights 0.2126/0.7152/0.0722, and uses
`(lighter + 0.05) / (darker + 0.05)`. This is sampled rendered-label evidence,
not an exhaustive accessibility audit.

| Final samples | Lowest ratio |
| --- | ---: |
| Light, both sizes and disclosure states | 7.13:1 |
| Dark, both sizes and disclosure states | 4.67:1 |

Samples cover the intro, connected-account status/method, all setup method
labels, folded exception summary, expanded explanation, explicit origin and
the inherited origin visible in the wide open render. All clear 4.5:1.

## Verification and limits

- Mac product: `swift build --force-resolved-versions --skip-update --product NativeAgentApp --jobs 4` passed.
- Existing snapshot runner: `PROVIDERS_SNAPSHOT_ONLY=1 bash script/snapshot_simplicity.sh` passed (3 BotsShelfTests).
- Closest existing suite: `swift test --force-resolved-versions --skip-update --skip-build --filter ProviderSettingsRefreshButtonBehaviorEvalTests` passed (2 tests).
- `swift script/check_architecture_blueprint.swift --repo .` passed.
- `swift script/check_timer_inventory.swift` passed (192 classified sites; no new timers).
- `git diff --check` passed.

Each Swift invocation used the task's prescribed local SQLite Git configuration.
The production view was visually inspected for setup discovery, account-state
hierarchy and clipping. Both columns scroll independently; at the smaller
height, later override rows and Telegram navigation require scrolling. No
control is removed. The nine provider setup routes fit in the initial viewport
at both requested sizes.

No live authentication, provider execution, installation or Mac UI automation
was performed. Existing shared fixed-size macOS typography remains a limitation
of the largest-Dynamic-Type exercise and was not changed outside this area.
The test fixture intentionally leaves default routing differences visible;
the summary does not pretend that every unpinned activity follows Chat.
