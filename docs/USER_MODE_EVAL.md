# User Mode Eval

User Mode Eval is the user-visible app harness. It is separate from code sweeps: code sweeps look for implementation bugs, while this harness asks whether the installed app looks and behaves wrong from the user's seat.

Run it from the repo root:

```bash
./script/user_mode_eval.sh
```

Useful options:

```bash
./script/user_mode_eval.sh --no-ui
./script/user_mode_eval.sh --strict-ui
./script/user_mode_eval.sh --artifacts /tmp/nativeagent-user-mode
```

`--no-ui` runs only filesystem/runtime state oracles. `--strict-ui` turns missing macOS Accessibility permission into a failure instead of a warning. Full UI mode needs Accessibility access for the process running the script.

The harness checks three layers:

- Installed app/runtime state: installed app exists and launches, retired `native_agentd.py` is not running, Doctor latest has no hard failures, Memory hygiene has a last-run receipt, scheduled jobs have sane next-run/defaults.
- User-visible state: active Inbox rows are well formed, scheduled proactive scans are not placeholder receipts, hygiene runs surface a timestamp, and the app does not visibly contradict itself with healthy/stopped status text.
- Whole-app UI journeys: Accessibility inventory plus screenshots for every primary, Advanced, routed-child, and supported nested surface. The route pass covers Chat; Activity; Activity > Approvals; Activity > Inbox; Activity > Memory Proposals; Activity > Self-Improvement; Memories; Missions; Missions > Schedule; Missions > Research; Skills; Providers; Mac Integration; Settings; Personality; Connectors; Trust; Command Center; Capabilities; Knowledge Graph; Dreams; Diagnostics; Diagnostics > Status; Cognition; Desk; Inbox Policy; Tools; MCP; Inspector; and Telegram through the real command palette route.

User Mode also checks the current `SidebarItem.primaryItems` and `SidebarItem.advancedItems` declarations against its route table. It reads both the legacy `Sources/NativeAgentApp/Models.swift` anchor and split files under `Sources/NativeAgentApp/Models/`. If a primary or Advanced Mac surface is added without a User Mode route, the harness fails before the route screenshots can be trusted as a baseline.

The evaluator validates the exact route-ID set, including duplicate, missing, and unexpected IDs. Standalone Panels and Self-Improvement destinations are retired aliases; Diagnostics and Activity > Self-Improvement are the canonical routes.

The healthy/stopped contradiction check is scoped to status-like AX text lines. This still catches the real watchdog/runtime issue the user saw, while avoiding false failures when normal chat transcript prose contains the word "stopped."

The app exposes hidden User Mode keyboard routes for surfaces that SwiftUI's sidebar rows do not reliably select through Accessibility. The harness still proves the destination by checking visible detail text outside the sidebar, so it fails if a shortcut routes to the wrong surface.

The action-label inventory is user-surface scoped: SwiftUI rows/cells can satisfy the label check through visible child text, while hidden User Mode route controls, AppKit scroll-bar children, and standard macOS titlebar chrome are excluded from NativeAgent app-control accounting.

Every run writes artifacts under `.runtime/user-mode-eval/<timestamp>/` by default:

- `report.json`
- `findings.md`
- `initial.png`
- `route-*.png`
- `ui-inventory-*.json`

The script exits nonzero on failures. Warnings are intentionally allowed so stale-but-explained state, like an old scheduler `lastRunDetail` before the next live run, does not block unrelated work.
