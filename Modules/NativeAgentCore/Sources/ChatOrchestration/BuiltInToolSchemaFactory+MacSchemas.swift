import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

extension BuiltInToolSchemaFactory {
    func appendOptionalSchemas(
        to schemas: inout [LLMToolSchema?],
        includeFullMacFileTools: Bool,
        includeFullMacSystemTools: Bool,
        includeFullMacAppTools: Bool,
        includeFullMacAccessibilityReadTools: Bool,
        includeFullMacAccessibilityInjectionTools: Bool,
        includeActivityQueryTool: Bool
    ) {
        if includeFullMacFileTools {
            schemas.append(contentsOf: [
                requestedSchema(
                    name: "file_excerpt",
                    description: "Read a line-numbered excerpt from a file on the Mac filesystem. Available only when Trust Center Full Mac file access is active.",
                    parametersJSON: params(
                        properties: [
                            ("path", strSchema("Absolute path or path relative to the NativeAgent repo root.")),
                            ("start_line", intSchema("1-based start line, default 1.")),
                            ("max_lines", intSchema("Maximum lines, default 80, capped at 240.")),
                        ],
                        required: ["path"]
                    )
                ),
                requestedSchema(
                    name: "grep",
                    description: "Search files with rg or grep through the Swift dispatcher. Available only when Trust Center Full Mac file access is active.",
                    parametersJSON: params(
                        properties: [
                            ("pattern", strSchema("Regex/search pattern.")),
                            ("path", strSchema("Directory or file to search. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.")),
                            ("max_results", intSchema("Maximum result lines, default/cap 50.")),
                        ],
                        required: ["pattern"]
                    )
                ),
                requestedSchema(
                    name: "git_status",
                    description: "Run git status --short --branch in a repository through the Swift dispatcher and return branch, ahead/behind, clean, staged, unstaged, and untracked metadata. Available only when Trust Center Full Mac file access is active.",
                    parametersJSON: params(
                        properties: [("cwd", strSchema("Repository directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace."))],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "git_diff",
                    description: "Read a git diff through the Swift dispatcher. Available only when Trust Center Full Mac file access is active.",
                    parametersJSON: params(
                        properties: [
                            ("cwd", strSchema("Repository directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.")),
                            ("staged", boolSchema("Use --staged.")),
                            ("path", strSchema("Optional path filter.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "git_log",
                    description: "Read recent git commits through the Swift dispatcher. Available only when Trust Center Full Mac file access is active.",
                    parametersJSON: params(
                        properties: [
                            ("cwd", strSchema("Repository directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.")),
                            ("limit", intSchema("Commit count, default 10, capped at 100.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "repo_dirty_summary",
                    description: "Summarize branch, dirty files, and recent commits through the Swift dispatcher. Available only when Trust Center Full Mac file access is active.",
                    parametersJSON: params(
                        properties: [
                            ("cwd", strSchema("Repository directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.")),
                            ("log_limit", intSchema("Recent commit count, default 5, capped at 20.")),
                        ],
                        required: []
                    )
                ),
                // CLI tools require Full Mac file access and default to confirmation.
                // The admitted bridge uses the same autonomy gate as local chat.
                requestedSchema(
                    name: "shell",
                    description: "Run a shell command via /bin/sh -c. Captures stdout/stderr/exit_code. Requires Trust Center Full Mac file_ops_allowed; queues an approval request unless toolAutonomy=auto for 'shell'. Default cwd is a verified NativeAgent source checkout when present, otherwise the canonical <dataRoot>/workspace used by public installs. Default timeout: 120s, max 600s. Use bash tool instead if you need bash-specific syntax (arrays, [[, process substitution). For checks, do not append `| tail; echo EXIT...` because that can mask the real failing exit code. \(SwiftToolDispatcher.nativeToolPreferenceGuidance)",
                    parametersJSON: params(
                        properties: [
                            ("cmd", strSchema("Required. The shell command line. Passed as -c argument to /bin/sh.")),
                            ("cwd", strSchema("Optional existing working directory. Relative paths resolve in the canonical NativeAgent workspace/source checkout. Active Full Mac YOLO may select an ordinary absolute external project; sensitive authority and protected system paths remain denied.")),
                            ("timeout_seconds", intSchema("Optional. Default 120, max 600. Subprocess group gets SIGTERM then SIGKILL after 2s.")),
                        ],
                        required: ["cmd"]
                    )
                ),
                requestedSchema(
                    name: "bash",
                    description: "Run a shell command via /bin/bash -c (not sh). Same shape as shell. Use this when the command needs bash features: arrays, [[ ]] tests, process substitution, $'...' ANSI-C quoting, etc. For checks, do not append `| tail; echo EXIT...` because that can mask the real failing exit code. \(SwiftToolDispatcher.nativeToolPreferenceGuidance)",
                    parametersJSON: params(
                        properties: [
                            ("cmd", strSchema("Required. The bash command line. Passed as -c argument to /bin/bash.")),
                            ("cwd", strSchema("Optional existing working directory. Relative paths resolve in the canonical NativeAgent workspace/source checkout. Active Full Mac YOLO may select an ordinary absolute external project; sensitive authority and protected system paths remain denied.")),
                            ("timeout_seconds", intSchema("Optional. Default 120, max 600.")),
                        ],
                        required: ["cmd"]
                    )
                ),
                requestedSchema(
                    name: "git",
                    description: "Run git with explicit args. Equivalent to `git <args>`. Returns stdout/stderr/exit_code. Default cwd is a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace. Default timeout 60s. Use for status, diff, log, blame, show, etc. Args may be an array (preferred) or a shell-style string for forgiving model calls. Mutating ops remain autonomy-gated.",
                    parametersJSON: params(
                        properties: [
                            ("args", stringOrStringArraySchema("Required. Full argv to pass to git. Prefer ['status'], ['log','--oneline','-5'], ['diff','HEAD~1','HEAD']; a string like 'status --short' is also accepted.")),
                            ("cwd", strSchema("Optional existing working directory. Relative paths resolve in the canonical NativeAgent workspace/source checkout. Active Full Mac YOLO may select an ordinary absolute external project; sensitive authority and protected system paths remain denied.")),
                            ("timeout_seconds", intSchema("Optional. Default 60, max 600.")),
                        ],
                        required: ["args"]
                    )
                ),
                requestedSchema(
                    name: "apply_patch",
                    description: "Apply a unified diff patch via `git apply` (3-way merge by default). Writes the patch payload to a tmpfile then runs git apply against it. Returns exit_code + stderr (which contains conflict info on failure). Default cwd is a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.",
                    parametersJSON: params(
                        properties: [
                            ("patch", strSchema("Required. The unified diff text. Will be written to a tmpfile before git apply.")),
                            ("cwd", strSchema("Optional existing working directory. Relative paths resolve in the canonical NativeAgent workspace/source checkout. Active Full Mac YOLO may select an ordinary absolute external project; sensitive authority and protected system paths remain denied.")),
                            ("three_way", boolSchema("Optional. Default true (passes --3way to git apply). Set false for strict apply that fails fast on context mismatch.")),
                        ],
                        required: ["patch"]
                    )
                ),
                requestedSchema(
                    name: "run_tests",
                    description: "Run the NativeAgent test suite via `bash script/test.sh`. Captures full stdout/stderr/exit_code. Default timeout 600s. Always anchored at the NativeAgent repo root — no cwd parameter. Use after a code change to confirm nothing regressed before asking for commit. Scope param reserved for future per-subsystem targeting; currently runs the full suite.",
                    parametersJSON: params(
                        properties: [
                            ("scope", strSchema("Optional. Reserved — currently ignored, runs the full test.sh. Future: 'unit', 'smoke', 'integration'.")),
                            ("timeout_seconds", intSchema("Optional. Default 600, max 3600.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "swift_build",
                    description: "Run a fixed-argv SwiftPM build. Ordinary modes use NativeAgent's workspace-confined outer wrapper; active Full Mac YOLO may build an explicitly selected external package without that wrapper. Command shape is `swift build --disable-sandbox --package-path <package_path> --configuration <debug|release>` plus optional product/target/jobs. TrustCenter, autonomy, audit receipts, and sensitive-path fences still apply.",
                    parametersJSON: params(
                        properties: [
                            ("package_path", strSchema("Optional Swift package directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical workspace. Active Full Mac YOLO may select an ordinary external package directory.")),
                            ("configuration", strSchema("Optional. debug or release. Defaults to debug.")),
                            ("product", strSchema("Optional product name to build. Mutually exclusive with target.")),
                            ("target", strSchema("Optional target name to build. Mutually exclusive with product.")),
                            ("jobs", intSchema("Optional SwiftPM --jobs value, clamped 1...64.")),
                            ("timeout_seconds", intSchema("Optional. Default 600, max 3600.")),
                            ("disable_swiftpm_sandbox", boolSchema("Optional. Defaults true so SwiftPM does not invoke its own sandbox-exec inside our outer wrapper (profiles cannot nest). Leave it true; setting it false makes the build fail at manifest compile.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "swift_test",
                    description: "Run fixed-argv SwiftPM tests. Ordinary modes use NativeAgent's workspace-confined outer wrapper; active Full Mac YOLO may test an explicitly selected external package without that wrapper. Command shape is `swift test --disable-sandbox --package-path <package_path> --configuration <debug|release>` plus optional filter/jobs. TrustCenter, autonomy, audit receipts, and sensitive-path fences still apply.",
                    parametersJSON: params(
                        properties: [
                            ("package_path", strSchema("Optional Swift package directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical workspace. Active Full Mac YOLO may select an ordinary external package directory.")),
                            ("configuration", strSchema("Optional. debug or release. Defaults to debug.")),
                            ("filter", strSchema("Optional SwiftPM --filter regex/specifier.")),
                            ("jobs", intSchema("Optional SwiftPM --jobs value, clamped 1...64.")),
                            ("timeout_seconds", intSchema("Optional. Default 900, max 3600.")),
                            ("disable_swiftpm_sandbox", boolSchema("Optional. Defaults true so SwiftPM does not invoke its own sandbox-exec inside our outer wrapper (profiles cannot nest). Leave it true; setting it false makes the build fail at manifest compile.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "remote_node_list",
                    description: "List explicitly configured MacControl trusted remote effect nodes, their pinned host-key fingerprints, enablement, and executable allowlists. This is a read-only inventory; remote nodes never own chat, memory, context, or schedules.",
                    parametersJSON: params(properties: [], required: [])
                ),
                requestedSchema(
                    name: "remote_node_execute",
                    description: "Run one argv-shaped command on an explicitly enabled trusted remote node. The node is re-read at effect time, the executable must exactly match its allowlist, SSH host identity is pinned, output is bounded, and a durable receipt is written. This remains behind Trust Center Full Mac; standard modes follow their normal autonomy gate, while admitted Full Mac YOLO runs without a per-call prompt.",
                    parametersJSON: params(
                        properties: [
                            ("node_id", strSchema("Required node id from remote_node_list.")),
                            ("executable", strSchema("Required absolute executable path; must exactly match the node allowlist.")),
                            ("arguments", stringArraySchema("Optional argv values. Values are individually shell-quoted; multiline/NUL arguments are rejected.")),
                            ("timeout_seconds", intSchema("Optional. Default 60, clamped 1...300.")),
                        ],
                        required: ["node_id", "executable"]
                    )
                ),
                requestedSchema(
                    name: "install_app",
                    description: "Canonical NativeAgent app install after Swift source changes. Schedules `script/install_app.sh` outside NativeAgent's outer sandbox, after a short grace delay, so the current reply can persist before the installer rebuilds, signs, installs to ~/Applications/NativeAgent.app, and restarts the app. Use this when `swift_build` passed and the running UI must pick up code changes. Do not use `restart_app` for this; restart_app only relaunches the already-installed bundle.",
                    parametersJSON: params(
                        properties: [
                            ("reason", strSchema("Required. Why the install/rebuild is needed; lands in the audit envelope.")),
                            ("start_delay_seconds", intSchema("Optional. Delay before launching install_app.sh so the final chat reply can persist. Defaults to restart_app's grace window; clamped 5...120.")),
                        ],
                        required: ["reason"]
                    )
                ),
                // Restart requires Full Mac file access and defaults to confirmation.
                // The detached relauncher preserves the reply grace and ten-minute cooldown.
                requestedSchema(
                    name: "restart_app",
                    description: "Restart the already-installed NativeAgent.app bundle: writes an audit receipt, spawns a detached relauncher, then terminates the app after a \(Int(AppRestartCoordinator.terminateGraceSeconds))s grace so this turn finishes persisting. This does NOT build, stage, sign, or install new Swift code; after Swift source edits use install_app instead. After this tool returns 'restarting', keep the final reply to one short sentence; it must be composed and persisted inside the grace window. The relauncher waits for the process to exit (up to \(AppRestartCoordinator.relauncherPollSeconds)s) and reopens the app bundle. Refuses if a tool-initiated restart fired within the last 10 minutes (cooldown). Requires Trust Center Full Mac file_ops_allowed; queues an approval unless toolAutonomy=auto for 'restart_app'.",
                    parametersJSON: params(
                        properties: [
                            ("reason", strSchema("Required. Why the restart is needed (lands in the audit envelope at data/restart_audit/<uuid>.json).")),
                        ],
                        required: ["reason"]
                    )
                ),
                // Evolution tools require Full Mac file access. Standard modes retain
                // approval; admitted YOLO uses the same candidate/CAS/backup/rollback executor.
                requestedSchema(
                    name: "evolution_propose",
                    description: "File a self-evolution proposal into the evolution store (data/evolution/proposals.json). Use when you have identified a concrete improvement to your own codebase. With a diff it lands as 'proposed' (eligible to build+test in an isolated worktree); without one it lands as 'needs_diff'. This NEVER edits the live repo; it only records a proposal for the build/approve pipeline. Requires Trust Center Full Mac file_ops_allowed; queues an approval unless toolAutonomy=auto for 'evolution_propose'.",
                    parametersJSON: params(
                        properties: [
                            ("title", strSchema("Required. Short one-line description of the proposed change.")),
                            ("evidence", strSchema("Required. Why this change is warranted — the usage/error/observation that motivates it.")),
                            ("diff_text", strSchema("Optional. A unified diff. If given the proposal is 'proposed'; if omitted it is 'needs_diff'.")),
                            ("expected_head", strSchema("Optional. The git HEAD sha the diff was authored against (staleness guard).")),
                        ],
                        required: ["title", "evidence"]
                    )
                ),
                requestedSchema(
                    name: "evolution_status",
                    description: "Read the self-evolution proposal store. With proposal_id, return that one proposal's status + receipts; without it, list the in-flight proposals (proposed / building / candidate_green / staged). Read-only.",
                    parametersJSON: params(
                        properties: [
                            ("proposal_id", strSchema("Optional. The evolution proposal id (evo_…). Omit to list in-flight proposals.")),
                        ],
                        required: []
                    )
                ),
                // evolution_withdraw (2026-09-02): the queue was write-only
                // from the agent's side — she could file a proposal and read
                // status, but had no way to take back one filed by mistake.
                // This is the only tool that walks a proposal BACKWARD, and it
                // only ever lands on the terminal `denied` state the legal
                // transition table already permits.
                requestedSchema(
                    name: "evolution_withdraw",
                    description: "Withdraw one of YOUR OWN self-evolution proposals — the one you filed by mistake. Moves it to the terminal 'denied' state with deny_reason 'withdrawn by agent: …' and an audit receipt. Refuses: proposals already in a terminal state (verified/reverted/denied), proposals with a candidate build/test run in flight (status 'building'), proposals past the withdrawal point (approved/installed — those need a revert, not a withdrawal), and any proposal you did not file yourself (only source='chat' records are yours; weekly / self_heal / external proposals are not withdrawable here). This never edits the live repo, never touches an installed change, and never withdraws anything on someone else's behalf. Requires Trust Center Full Mac file_ops_allowed; queues an approval unless toolAutonomy=auto for 'evolution_withdraw'; under the Everything (full run) trust posture the approval passes straight through and no card is shown.",
                    parametersJSON: params(
                        properties: [
                            ("id", strSchema("Required. The evolution proposal id (evo_…) to withdraw. Must be one you filed (source='chat').")),
                            ("reason", strSchema("Optional. Why you are withdrawing it. Recorded as the proposal's deny_reason, prefixed 'withdrawn by agent: '. Max 500 characters.")),
                        ],
                        required: ["id"]
                    )
                ),
                requestedSchema(
                    name: "self_install",
                    description: "Advance a self-evolution proposal that has already built+tested GREEN (status candidate_green). Standard modes stage a self_evolution.apply approval card. Admitted Full Mac YOLO enters the same candidate/CAS/backup/rollback executor directly without a per-call prompt; installation still requires Trust Center systemRebuild to be enabled. Returns an honest 'not installable yet' envelope if the proposal is not candidate_green. Requires Trust Center Full Mac file_ops_allowed.",
                    parametersJSON: params(
                        properties: [
                            ("proposal_id", strSchema("Required. The evolution proposal id (evo_…) to stage for install. Must be status candidate_green.")),
                        ],
                        required: ["proposal_id"]
                    )
                ),
            ])
        }
        if includeFullMacSystemTools {
            schemas.append(
                requestedSchema(
                    name: "system_info",
                    description: "Read basic local system/disk/memory information through the Swift dispatcher. Available only when Trust Center Full Mac system access is active.",
                    parametersJSON: params(properties: [], required: [])
                )
            )
        }
        if includeFullMacAppTools {
            schemas.append(contentsOf: [
                requestedSchema(
                    name: "mac_focus_app",
                    description: "Focus or launch a macOS app by app name, bundle identifier, or .app path through Swift MacControl. Available only when Trust Center Full Mac Accessibility app control is active.",
                    parametersJSON: params(
                        properties: [
                            ("app", strSchema("App name such as Safari, bundle identifier such as com.apple.Safari, or an absolute .app path.")),
                        ],
                        required: ["app"]
                    )
                ),
                requestedSchema(
                    name: "mac_quit_app",
                    description: "Ask a macOS app to quit by app name, bundle identifier, or .app path through Swift MacControl. Available only when Trust Center Full Mac Accessibility app control is active.",
                    parametersJSON: params(
                        properties: [
                            ("app", strSchema("App name such as Safari, bundle identifier such as com.apple.Safari, or an absolute .app path.")),
                        ],
                        required: ["app"]
                    )
                ),
            ])
        }
        if includeFullMacAccessibilityReadTools {
            // Perception requires both macOS Accessibility and the Trust Center category.
            schemas.append(contentsOf: [
                // Nudge shares the read gate; it cannot bypass action approval.
                requestedSchema(
                    name: "mac_nudge",
                    description: "Post a single bare mouse MOVE (one point) to wake a sleeping display or dismiss a screensaver — the software equivalent of bumping the mouse. It moves the cursor and does nothing else: it cannot click, type, scroll, drag, or authenticate. Takes no arguments. Available only when Trust Center Full Mac is active with the Accessibility category enabled; to actually click or type, use mac_click / mac_keystroke.",
                    parametersJSON: params(properties: [], required: [])
                ),
                // Clipboard reads redact text and name non-text flavors without dumping them.
                requestedSchema(
                    name: "clipboard_read",
                    description: "Read what is on this Mac's clipboard right now, as text. Read-only: it changes the clipboard and nothing else on the screen. Pair it with a copy (select all, then ⌘C) to read a dense document the screen cannot show you in words. Lines that are THEMSELVES a secret — a password, an API key, a one-time code, a card number, a recovery phrase — come back as \"[redacted: <reason>]\" and are listed under `redactions`; that is redaction, not an empty clipboard, and re-reading will not reveal them. Non-text contents (an image, a file, an app's own flavor) are reported by type and size under `types` — the bytes are never returned. Available only when Trust Center Full Mac is active with the Accessibility category enabled.",
                    parametersJSON: params(
                        properties: [
                            ("max_chars", intSchema("Maximum characters of clipboard text to return. Default 8000, clamped to 200-32000; the result says whether it cut and how many characters there were.")),
                        ],
                        required: []
                    )
                ),
                // Menu reads do not open menus; disabled items remain visible.
                requestedSchema(
                    name: "menu",
                    description: "List an app's menu bar as nameable paths — \"File › Export › PDF…\", \"Edit › Find › Find Next\". This is the cheapest deterministic route to anything an app can do: no coordinates, no scrolling, no guessing which toolbar icon means export. Read-only, and it does NOT open any menu — the paths come from the app's published accessibility tree whether or not a menu is drawn. Bounded: three levels deep, capped in item count, one walk (the result says if a bound cut it). Items that are greyed out are still listed with `enabled: false` — present but switched off in this state, which is different from absent. Press one with menu_press. Available only when Trust Center Full Mac is active with the Accessibility category enabled.",
                    parametersJSON: params(
                        properties: [
                            ("app", strSchema("Optional: read this running app's menu bar instead of the frontmost app's, without activating it. Defaults to whatever is in front.")),
                        ],
                        required: []
                    )
                ),
                // Read consolidates the requested content instead of requiring repeated frames.
                requestedSchema(
                    name: "read",
                    description: "READ a document end to end — a contract, a PDF, a long article, a thread. Different from `screen`: `screen` answers \"what is in front of me and what can I do to it\" in one bounded glance; `read` answers \"what does this SAY\" and returns ALL of it. If the window in front is showing a file (or you name one with `path`), the file's own text is extracted — PDFs through PDFKit, plain text directly — so you get the author's characters rather than a scrape of a rendering. Otherwise it reads the front window's text, scrolls one screenful, reads again, merges on the overlap, and keeps going until the content stops changing; it then scrolls back to where it started. It presses nothing, types nothing and opens nothing. Long results are retained whole for this turn — when the answer comes back as a bounded summary with a `result_handle`, call tool_result_page to page through the rest; do NOT re-run this to see more. Lines that are THEMSELVES a secret come back as \"[redacted: <reason>]\". Refusals are in words: no document in front, a password-protected file, a scanned PDF with no text layer (ask for `screen` instead), a secure password field. Available only when Trust Center Full Mac is active with the Accessibility category enabled; naming an explicit `path` additionally needs Full Mac file access.",
                    parametersJSON: params(
                        properties: [
                            ("path", strSchema("Optional: read this file instead of the screen — an absolute path to a PDF or a plain-text file. Omit it to read whatever document is in front of you (or, when the front window names no file, the window's own text).")),
                            ("app", strSchema("Optional: read THIS running app's front window instead of whatever is in front — \"read the contract, app: Preview\". The window is read where it sits: nothing is activated, raised or launched, so your focus does not move and neither does User's. Refused in words if nothing by that name is running or the name matches more than one running app. Ignored when you name a `path`, which reads the file rather than any window.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "mac_ax_status",
                    description: "Report whether this app currently holds the macOS Accessibility (AX) system grant needed to read the on-screen UI tree. Read-only: changes nothing. Available only when Trust Center Full Mac is active with the Accessibility category enabled.",
                    parametersJSON: params(properties: [], required: [])
                ),
                requestedSchema(
                    name: "mac_ax_tree",
                    description: "Read the on-screen accessibility (AX) tree of the frontmost window — the roles, titles and values macOS itself publishes for the UI. This is perception, not control: it clicks nothing, types nothing and changes nothing. Requires the macOS Accessibility system grant; available only when Trust Center Full Mac is active with the Accessibility category enabled. Results are bounded by node/depth caps and may come back truncated.",
                    parametersJSON: params(
                        properties: [
                            ("max_nodes", intSchema("Maximum number of AX nodes to return. Clamped to the reader's own cap; omit for the default.")),
                            ("max_depth", intSchema("Maximum tree depth to descend. Clamped to the reader's own cap; omit for the default.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "mac_ax_find",
                    description: "Search the on-screen accessibility (AX) tree of the frontmost window for elements matching a role, title and/or value, and return their paths. Read-only perception: it locates UI elements, it does not click or focus them. Requires the macOS Accessibility system grant; available only when Trust Center Full Mac is active with the Accessibility category enabled. At least one of role/title/value must be given.",
                    parametersJSON: params(
                        properties: [
                            ("role", strSchema("AX role to match, such as AXButton or AXTextField.")),
                            ("title", strSchema("Substring to match against an element's AX title/label.")),
                            ("value", strSchema("Substring to match against an element's AX value.")),
                            ("limit", intSchema("Maximum number of matches to return. Clamped to the reader's own cap.")),
                        ],
                        required: []
                    )
                ),
                // Addressable marks are the default calling convention; coordinates are fallback.
                requestedSchema(
                    name: "mac_view",
                    description: "SEE the screen the way a person does: one fused view of the frontmost window that returns the accessibility structure AND a screenshot, with every clickable and scrollable element outlined and NUMBERED on the image. Read the structure first — `marks` gives each number's role, label, value, state, frame and real element path, and `text` gives everything the window says in reading order; together they describe the screen completely, and the image is the spatial backdrop showing where each numbered thing sits rather than something you must decode. Act by NUMBER, not by coordinate — pass the returned `view` id with mac_ax_act {mark, view} to press an element the app's own way, or mac_click {mark, view} to click its centre; this call is read-only and changes nothing. Only fall back to raw x/y coordinates for parts of the picture with no marks (a canvas, a game, a video). Marks are valid ONLY for the most recent view: if the screen may have changed, call mac_view again — an older view id is refused rather than guessed at. Read-only perception: it changes nothing. Needs the Trust Center Full Mac Accessibility category, and the picture half also needs the macOS Screen Recording permission (a separate grant from Accessibility) — when that is missing you still get the numbered legend, and the result says so.",
                    parametersJSON: params(
                        properties: [
                            ("full_screen", boolSchema("Capture the whole display instead of just the frontmost window. Defaults to false (the focused window).")),
                            ("max_marks", intSchema("Maximum number of elements to number. Clamped to the view's own cap (60); omit for the default.")),
                            ("max_text_items", intSchema("Maximum lines of on-screen text to return. Clamped to the view's own cap (80); omit for the default.")),
                            ("max_image_bytes", intSchema("Maximum encoded PNG size. The image is downscaled to fit; clamped to the view's own cap. Omit for the default.")),
                            ("max_nodes", intSchema("Maximum number of AX nodes to consider when choosing marks. Clamped to the reader's own cap.")),
                            ("max_depth", intSchema("Maximum AX tree depth to descend. Clamped to the reader's own cap.")),
                        ],
                        required: []
                    )
                ),
                // Perception grades let the caller request only the detail needed.
                requestedSchema(
                    name: "screen",
                    description: "Look at the live screen, right now, in words. One structured page: SCREEN (which app and window, whether it is front), WHERE (your position in the app's own navigation), the dominant content as a numbered LIST/GRID (the numbers are addresses — say 'row 3' to point at one) or CANVAS when part of the screen is not controls, DO (everything you can act on, with its state inline), SAYS (status text worth knowing). Nothing to hold and nothing expires: look again by calling again. Pass `part` to lean in — the same shape scoped to the section or thing you name ('the list', 'the toolbar', 'the Send button'). Pass `app` to glance at ANOTHER running app's front window without switching to it: nothing is activated, nothing moves on the user's screen, and the answer says the window is not in front. Acting still needs the app in front — use `go` for that.",
                    parametersJSON: params(
                        properties: [
                            ("part", strSchema("Optional: a section, thing, or status readout to inspect by name. Use hud/readouts for observed status values, or a label such as Last drag or Energy to reveal a readout hidden by the ordinary display cap.")),
                            ("app", strSchema("Optional: read this running app's front window instead of whatever is in front, WITHOUT activating it (\"Mail\", \"Safari\"). If nothing by that name is running, or the name matches more than one, the answer says so and names what is running.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "wait",
                    description: "Watch the screen until it settles or until something you name appears — like watching a page load. Bounded (default 10s, max 60s); returns early when the screen stops changing or when `until` text shows up, and says honestly when it timed out with the screen still moving. Answers with what happened and the final screen.",
                    parametersJSON: params(
                        properties: [
                            ("until", strSchema("Optional: return as soon as this text appears on screen (case-insensitive).")),
                            ("seconds", intSchema("Optional: how long to watch. Default 10, max 60.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "mac_look",
                    description: "LOOK at the frontmost window — the app reads the on-screen accessibility structure and hands you the distilled answer instead of a tree you have to parse. Three grades: `glance` is ONE line (app, window title, how many controls, where the focus is, whether a sheet or dialog is up, the first few buttons); `look` is the structured percept — the window, the focused element, any modal, the landmarks (toolbar, sidebar, table, list, web area) and every LABELED interactive control with a stable `handle`, its role, value and real element path; `stare` is the full raw AX tree, the same payload mac_ax_tree returns, and you should rarely need it. Prefer `glance` to orient and `look` to act: a look costs roughly a tenth to a seventieth of a stare. Controls the app publishes no name for are never hidden — they are counted by role under `unlabeled`. Handles are valid only for the returned `frame_id`; if the screen may have changed, look again. Read-only perception: it clicks nothing, types nothing and changes nothing. Requires the macOS Accessibility system grant; available only when Trust Center Full Mac is active with the Accessibility category enabled.",
                    parametersJSON: params(
                        properties: [
                            ("grade", enumStringSchema(["glance", "look", "stare"], "How hard to look. Defaults to look.")),
                            ("max_affordances", intSchema("Maximum labeled interactive controls to return. Clamped to the compiler's own cap (60); omit for the default.")),
                            ("max_nodes", intSchema("Maximum number of AX nodes to walk. Clamped to the reader's own cap.")),
                            ("max_depth", intSchema("Maximum AX tree depth to descend. Clamped to the reader's own cap.")),
                            ("scope", enumStringSchema(
                                ["page", "chrome", "both"],
                                "For a browser or Electron window: `page` (the default) spends the whole walk on the web page and collapses the browser's own toolbar and bookmarks bar to one summary line; `chrome` looks at the browser's controls instead; `both` walks the whole window in one pass, where the page competes with the chrome for the node budget. Ignored for a window with no web area — the result always says which scope it used."
                            )),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "mac_attention",
                    description: "Pay continuous, explicit attention to this Mac without a polling loop or another model. `start` installs a passive, on-device event observer for a bounded time and returns a fresh fused screen view. `next` waits efficiently for physical pointer/keyboard/scroll activity or an app change (up to wait_ms), then returns one fresh fused view; keyboard CONTENT is never captured, only an activity pulse. Physical user input always wins: it immediately invalidates the old view and motor tools refuse with yielded_to_user until you call `next` and re-observe. `status` reports the live session; `stop` removes every observer and forgets the ephemeral state. While active, pass the returned attention.session and attention.user_sequence as attention_session and attention_user_sequence on every Mac motor action. Read-only perception under the Full Mac Accessibility gate; the screenshot half also needs Screen Recording permission.",
                    parametersJSON: params(
                        properties: [
                            ("mode", enumStringSchema(["start", "next", "status", "stop"], "Attention operation. Defaults to status.")),
                            ("session", strSchema("Session id returned by start. Required for next.")),
                            ("after_sequence", intSchema("For next: wait only for activity newer than this attention sequence.")),
                            ("wait_ms", intSchema("For next: event-driven wait before refreshing anyway, 0-15000ms. Defaults to 1500.")),
                            ("duration_seconds", intSchema("For start: bounded observer lifetime, 15-1800 seconds. Defaults to 300.")),
                            ("full_screen", boolSchema("Capture the whole display instead of the focused window.")),
                            ("max_marks", intSchema("Maximum numbered elements, with the same cap as mac_view.")),
                            ("max_text_items", intSchema("Maximum visible text items, with the same cap as mac_view.")),
                            ("max_image_bytes", intSchema("Maximum encoded PNG bytes, with the same cap as mac_view.")),
                        ],
                        required: []
                    )
                ),
            ])
        }
        // Activity reports frontmost apps and durations, not actions or field contents.
        if includeActivityQueryTool {
            schemas.append(contentsOf: [
                requestedSchema(
                    name: "activity_query",
                    description: "Summarise which Mac apps were in use over a time range, from a local, on-device activity log the user explicitly opted into and separately allowed this selected AI provider to read. It knows WHICH APP was frontmost and FOR HOW LONG — not what was done inside it, not what was typed, and not the contents of any field. Where the user enabled window titles, a secret-redacted title may appear on example spans; treat it as a weak hint, not a description of the work, and never quote it as fact about content. Apps on the user's exclusion list are absent from the answer entirely, even for days when they were still being recorded, so totals can legitimately be lower than a full day. The answer is capped at 50 rows and refuses rather than silently truncating an over-dense source range. Read-only and deterministic; the store is never exposed to iPhone/Telegram/Slack/iCloud/bridges. If capture or Agent Access is off in Trust Center this tool refuses rather than returning an empty day; do not read a refusal as \"nothing happened\".",
                    parametersJSON: params(
                        properties: [
                            ("range", strSchema("Named range: today, yesterday, last_hour, last_24_hours, last_7_days, last_30_days. Defaults to today. Ignored when `from` is given.")),
                            ("from", strSchema("Explicit range start: epoch seconds, an ISO-8601 instant, or YYYY-MM-DD (midnight in the asking timezone).")),
                            ("to", strSchema("Explicit range end, same formats as `from`. Defaults to now.")),
                            ("bundle_id", strSchema("Restrict the answer to one app's bundle identifier, e.g. com.apple.Safari.")),
                            ("timezone", strSchema("IANA timezone the day/hour buckets are computed in, e.g. Europe/London. Defaults to this Mac's current timezone.")),
                            ("limit", intSchema("Maximum rows in the answer. Clamped to 50; the answer says what the cap removed.")),
                        ],
                        required: []
                    )
                ),
            ])
        }
        if includeFullMacAccessibilityInjectionTools {
            // Action descriptions state their target and required authority.
            func intArraySchema(_ desc: String) -> JSONValue {
                obj([
                    ("type", .string("array")),
                    ("items", obj([("type", .string("integer"))])),
                    ("description", .string(desc)),
                ])
            }
            func pointSchema(_ desc: String) -> JSONValue {
                obj([
                    ("type", .string("object")),
                    ("description", .string(desc)),
                    ("properties", obj([
                        ("x", intSchema("Screen x coordinate.")),
                        ("y", intSchema("Screen y coordinate.")),
                    ])),
                ])
            }
            schemas.append(contentsOf: [
                requestedSchema(
                    name: "act",
                    description: "Do something naturally, by NAME or visible ordinal, against a fresh fused screen. Semantic actions: click/open/type/select/toggle/scroll/dismiss. Physical actions: hover, move, drag (give `to`), hold, or key (target may be a bounded key/chord sequence such as `w`, `cmd+s`, or `1 2 3`; `hold` can target `key w`). Prominent unlabeled pixel objects appear in the same screen as numbered visual regions; they accept literal physical actions without being misrepresented as semantic controls. Use `repeat` for a short continuous burst: the target is freshly seen and re-resolved before every attempt, so moving visual targets are followed instead of reusing an old point. Use `holding` to keep one or more keys/modifiers down around a physical move, drag, click, scroll, or key action (for example hold `w d` while dragging a world view). Accessibility targets use the app's own action; coordinated or pixel-only actions use the bounded physical hand. Burst results distinguish requested, accepted, planned, completed, visibly verified, elapsed, and runtime-limited work. Ambiguity, drift, a vanished target, or the elapsed boundary stops the burst before another action. Needs active Full Mac Accessibility app control; there is no per-call approval.",
                    parametersJSON: params(
                        properties: [
                            ("verb", enumStringSchema(["click", "open", "type", "select", "toggle", "scroll", "dismiss", "hover", "move", "drag", "hold", "key"], "What to do.")),
                            ("target", strSchema("The thing, by name as the screen shows it — a label, a partial label, an ordinal like 'row 3', or a numbered unlabeled target like 'visual region 2'. For hold, `key w d` holds W and D simultaneously for seconds; space-separated keys/chords and bare modifiers are supported. For key, a space-separated sequence remains sequential.")),
                            ("text", strSchema("For `type`: the text to put in the target.")),
                            ("direction", enumStringSchema(["up", "down", "left", "right"], "For `scroll`: which way to move. Left/right sends horizontal wheel input.")),
                            ("scroll_amount", intSchema("For scroll: wheel magnitude in lines, 1 for fine adjustment through120. Use0 (or omit) for ordinary/default behavior, including all non-scroll verbs. An explicit amount requests wheel input rather than page-key fallback.", minimum: 0, maximum: 120)),
                            ("to", strSchema("For `drag`: the named/numbered destination.")),
                            ("to_app", strSchema("For `drag` only: the running app whose front window `to` lives in, when the drop lands in a DIFFERENT app from the one in front — \"drag report.pdf to the message body, to_app: Mail\". The destination is resolved in that app's window without activating it, so nothing moves while I am looking; then, only if the drop needs it, that app is brought forward once and the result says that focus moved and why. Refused in words if the app is not running, if the name matches more than one running app, if nothing in that window answers to `to`, if raising it would cover the thing being picked up, or if the drag would cross a password field. Hold `option`/`cmd` with `holding` for the app's own copy/move variant. For text, prefer clipboard_write plus a paste — this is for dragging things accessibility can name.")),
                            ("seconds", numSchema("For hover or hold: duration up to10 seconds. For drag: paced travel duration, bounded0.08–2 seconds;0/omission uses0.24 seconds. Drag duration controls movement, not two endpoint pauses.", minimum: 0, maximum: 10)),
                            ("repeat", intSchema("Optional bounded burst count. The target is freshly re-resolved before every attempt; planning and real elapsed execution are capped at 30 seconds.", minimum: 1, maximum: 12)),
                            ("interval", numSchema("Optional pause between repeated attempts.", minimum: 0, maximum: 2)),
                            ("holding", strSchema("Optional keys/modifiers held around a physical action, such as `w d`, `shift`, or `cmd+w`. Works with pointer hold, including right-button hold while movement keys are down. Not valid with a keyboard hold (put all keys in its target) or literal type.")),
                            ("button", enumStringSchema(["auto", "left", "right"], "Use auto for the ordinary/default action, including key, type, scroll, move, and hover. Use left or right only to request an explicit mouse button on click, open (double-click), drag, or pointer hold. Right drag sends genuine right-button events, not Control-left-drag. Omission is equivalent to auto.")),
                        ],
                        required: ["verb", "target"]
                    )
                ),
                // Clipboard writes require app-control authority because they replace the next
                // paste. Menu presses run the app's own handler, including destructive actions.
                requestedSchema(
                    name: "menu_press",
                    description: "Press one menu item by name, as the menu bar shows it: \"File › Export › PDF…\". Levels can be separated by ›, >, or /. This runs the app's OWN menu handler — the same thing that happens when a person picks it — so it can save, close, quit, or delete depending on what you name. Resolve the path with `menu` first: an unknown path refuses and lists what is actually there, an ambiguous one refuses and names the candidates, and an item the app has greyed out refuses in words rather than pressing nothing and calling it done. Whether the intended thing happened is for the next look to say. Needs active Full Mac Accessibility app control; there is no per-call approval.",
                    parametersJSON: params(
                        properties: [
                            ("path", strSchema("The menu path to press, e.g. \"File › Export › PDF…\" or \"Edit > Find > Find Next\".")),
                            ("app", strSchema("Optional: press in this running app's menu bar instead of the frontmost app's. Defaults to whatever is in front.")),
                        ],
                        required: ["path"]
                    )
                ),
                requestedSchema(
                    name: "clipboard_write",
                    description: "Put text on this Mac's clipboard, replacing whatever was there. The next paste (⌘V) in ANY app will produce this text, and what was on the clipboard before is gone. It types nothing and clicks nothing by itself — to get the text into a document, paste it afterwards. Bounded at 100000 characters. The result reports how many characters were written and whether reading the clipboard back matched; the text itself is never echoed. Needs active Full Mac Accessibility app control; there is no per-call approval.",
                    parametersJSON: params(
                        properties: [
                            ("text", strSchema("The text to place on the clipboard.")),
                        ],
                        required: ["text"]
                    )
                ),
                requestedSchema(
                    name: "go",
                    description: "Get to an app, file, folder, or http/https URL through the canonical Mac-control owner, then read the fresh screen. App activation is independently verified; file/URL opening is reported only as an accepted request unless the screen proves where it landed. Needs active Full Mac Accessibility app control; there is no per-call approval.",
                    parametersJSON: params(
                        properties: [
                            ("name", strSchema("An app name, a file/folder path (~ allowed), or an http/https URL.")),
                        ],
                        required: ["name"]
                    )
                ),
                requestedSchema(
                    name: "mac_keystroke",
                    description: "Type text and/or press key combinations on this Mac, exactly as if typed on the physical keyboard. The input goes to WHATEVER APP IS FRONTMOST — focus the intended app first. `text` is typed literally (any Unicode, any layout); `keys` is a space-separated sequence of chords using cmd/shift/opt/ctrl/fn plus a key, for example \"cmd+s\", \"cmd+shift+4\", \"return\", \"cmd+a cmd+c\". At least one of text/keys is required; text is typed before keys. This requires approval and an active Full Mac window with the Accessibility category on.",
                    parametersJSON: params(
                        properties: [
                            ("text", strSchema("Literal text to type, character by character. Any Unicode; layout-independent.")),
                            ("keys", strSchema("Space-separated key chords, e.g. \"cmd+shift+4\" or \"escape\" or \"cmd+a cmd+c\". Modifiers: cmd, shift, opt, ctrl, fn. Named keys: return, tab, escape, space, delete, forward_delete, home, end, pageup, pagedown, up, down, left, right, f1-f20.")),
                            ("attention_session", strSchema("Required while mac_attention is active: its current session id.")),
                            ("attention_user_sequence", intSchema("Required while mac_attention is active: the user_sequence from its latest observed fused view.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "mac_click",
                    description: "Click, double-click, right-click, or drag on this Mac, exactly as if done with the physical mouse. PREFER pointing by NAME: pass `mark` plus the `view` id from mac_view and the click lands on that element's real centre, no coordinate guessing — or better still use mac_ax_act, which presses the control the app's own way. Give x/y only for parts of the screen with no marks (a canvas, a game, a video), or from/to for a drag. This requires approval and an active Full Mac window with the Accessibility category on.",
                    parametersJSON: params(
                        properties: [
                            ("x", intSchema("Screen x coordinate to click.")),
                            ("y", intSchema("Screen y coordinate to click.")),
                            ("button", enumStringSchema(["left", "right"], "Mouse button. Defaults to left.")),
                            ("count", intSchema("Number of clicks, 1-3. Use 2 for a double-click.")),
                            ("double", boolSchema("Shorthand for count:2.")),
                            ("from", pointSchema("Drag start point. Give both from and to to drag instead of click.")),
                            ("to", pointSchema("Drag end point.")),
                            ("duration_ms", intSchema("For a drag: smooth local movement duration, 80-2000ms. Defaults to 240ms; no extra model calls.")),
                            ("mark", intSchema("A number from the latest mac_view legend. Clicks that element's centre; needs `view` too. Preferred over x/y.")),
                            ("view", strSchema("The `view` id mac_view returned with that mark. A mark from any earlier view is refused — take a fresh mac_view instead.")),
                            ("attention_session", strSchema("Required while mac_attention is active: its current session id.")),
                            ("attention_user_sequence", intSchema("Required while mac_attention is active: the user_sequence from its latest observed fused view.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "mac_scroll",
                    description: "Scroll on this Mac with synthesized mouse-wheel events, exactly as if using the physical wheel or trackpad. Positive dy scrolls up, negative dy scrolls down. Optionally give x/y to move the pointer over the view to scroll first. This requires approval and an active Full Mac window with the Accessibility category on.",
                    parametersJSON: params(
                        properties: [
                            ("dy", intSchema("Vertical scroll amount. Positive scrolls up, negative down.")),
                            ("dx", intSchema("Horizontal scroll amount.")),
                            ("x", intSchema("Optional screen x to move the pointer to before scrolling.")),
                            ("y", intSchema("Optional screen y to move the pointer to before scrolling.")),
                            ("units", enumStringSchema(["line", "pixel"], "Scroll units. Defaults to line.")),
                            ("attention_session", strSchema("Required while mac_attention is active: its current session id.")),
                            ("attention_user_sequence", intSchema("Required while mac_attention is active: the user_sequence from its latest observed fused view.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "mac_ax_act",
                    description: "Act on ONE UI element of the frontmost window, addressed either by a `mark` number from the latest mac_view (pass `view` too) or by the `path` that mac_ax_tree or mac_ax_find returned for it. By default it presses the element (AXPress), which runs the app's own handler — more reliable than clicking a coordinate, and it works even when the element is partly covered. Pass `value` instead to set a text field's contents directly. If the element exposes no usable accessibility action, this falls back to a synthesized click at the element's centre and says so in the result's `method` field. The result carries a re-read `post_state` so you can check whether the UI actually changed. Needs Trust Center Full Mac with the Accessibility category on and the macOS Accessibility grant; there is no per-call approval.",
                    parametersJSON: params(
                        properties: [
                            ("path", intArraySchema("Child-index path from mac_ax_tree / mac_ax_find. [] is the window itself.")),
                            ("action", strSchema("Accessibility action to perform, e.g. AXPress (default), AXShowMenu, AXIncrement.")),
                            ("value", strSchema("When given, set the element's value to this text instead of performing an action. For text fields.")),
                            ("mark", intSchema("A number from the latest mac_view legend, addressing the same element its legend row names. Needs `view` too. Use instead of `path`.")),
                            ("view", strSchema("The `view` id mac_view returned with that mark. A mark from any earlier view is refused — take a fresh mac_view instead.")),
                            ("attention_session", strSchema("Required while mac_attention is active: its current session id.")),
                            ("attention_user_sequence", intSchema("Required while mac_attention is active: the user_sequence from its latest observed fused view.")),
                        ],
                        required: []
                    )
                ),
                // An action returns the observed change with its receipt.
                requestedSchema(
                    name: "mac_act",
                    description: "ACT on one control you saw in a mac_look, and get back WHAT CHANGED in the same call — you never need to look again to find out whether it landed. Pass the `handle` of a control from the latest look plus that look's `frame_id`, and a `verb`: `click` presses it the app's own way (falling back to a real click at its centre when it advertises no action), `open` opens it — a Finder row, a file, a folder — via AXOpen or a synthesized double-click, `type` puts `text` into it (setting the value directly when the control allows it, otherwise focusing it and typing), `select` picks a row/cell/menu item, `toggle` flips a checkbox/radio/switch, `dismiss` closes the sheet or dialog that is up by pressing its own Cancel/Close/Dismiss/Done/OK button, and `scroll` brings the control into view (`direction` up or down). Before acting it watches the app for accessibility change notifications, then re-reads the window and diffs it: the result's `effect` names the notifications that fired, the acted control's before/after label and value, which affordances appeared, disappeared or changed, whether focus moved, whether a modal opened or closed, and whether the window title changed — with `observed:false` when the app published no change at all, which is itself an answer. It also returns a FRESH `frame_id` and a one-line `glance` of the new state, so the next act continues from there; handles from the previous frame are dead. If the control the handle named is no longer what it was, this refuses with `handle_drifted` rather than acting on a different control; it also refuses with `frame_app_gone` when the app you looked at is no longer there, and with `observer_unavailable` when it cannot watch that app for the effect — in every one of those cases NOTHING is acted on. Needs Trust Center Full Mac with the Accessibility category on and the macOS Accessibility grant; there is no per-call approval.",
                    parametersJSON: params(
                        properties: [
                            ("handle", strSchema("Handle of the control, from the latest mac_look's affordances.")),
                            ("frame_id", strSchema("The frame_id that mac_look returned with that handle. A handle from any earlier frame is refused — take a fresh mac_look instead.")),
                            ("verb", enumStringSchema(
                                ["click", "open", "type", "select", "toggle", "dismiss", "scroll"],
                                "What to do to the control."
                            )),
                            ("text", strSchema("For verb=type: the characters to put into the control.")),
                            ("direction", enumStringSchema(["up", "down"], "For verb=scroll: which way. Defaults to down.")),
                            ("wait_ms", intSchema("How long to wait for the app to react before reporting no observed effect, 0-2000ms. Defaults to 300, which is ten times the measured latency.")),
                            ("attention_session", strSchema("Required while mac_attention is active: its current session id.")),
                            ("attention_user_sequence", intSchema("Required while mac_attention is active: the user_sequence from its latest observed fused view.")),
                        ],
                        required: ["handle", "frame_id", "verb"]
                    )
                ),
                requestedSchema(
                    name: "mac_wake",
                    description: "Wake the screen: if this Mac is showing a screensaver or the display has gone to sleep, nudge it away and hand back a fresh view of the real desktop underneath, in one call. Use it when mac_view shows only the screensaver or the login window and you need to see or act on what is actually there. It posts the smallest possible input — a one-point mouse move plus a bare Shift tap, neither of which can click, type text, or authenticate — and then returns exactly what mac_view returns (`marks`, `text`, the annotated image, and a `view` id you can act on), plus a `wake` block saying whether the screen really came back. If the saver/login layer remains, it reports that observed obstruction without guessing why. Requires approval and an active Full Mac window with the Accessibility category on.",
                    parametersJSON: params(
                        properties: [
                            ("key_tap", boolSchema("Also tap the left shift key, which types nothing but wakes some sleeping displays a mouse move alone does not. Off by default; try it if a first wake reports dismissed:false.")),
                            ("settle_ms", intSchema("How long to wait after the nudge before capturing, 0-3000ms. Defaults to 700, which is enough for the screensaver to finish tearing down. Raise it if the returned view still shows the saver.")),
                            ("full_screen", boolSchema("Capture the whole screen instead of just the frontmost window, same as mac_view.")),
                            ("attention_session", strSchema("Required while mac_attention is active: its current session id.")),
                            ("attention_user_sequence", intSchema("Required while mac_attention is active: the user_sequence from its latest observed fused view.")),
                        ],
                        required: []
                    )
                ),
            ])
        }
    }
}
