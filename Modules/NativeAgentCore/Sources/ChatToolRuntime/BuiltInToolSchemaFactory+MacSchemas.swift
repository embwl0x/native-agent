import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting

extension BuiltInToolSchemaFactory {
    func appendOptionalSchemas(
        to schemas: inout [LLMToolSchema?],
        includeFullMacFileTools: Bool,
        includeFullMacSystemTools: Bool,
        includeFullMacAccessibilityReadTools: Bool,
        includeFullMacAccessibilityInjectionTools: Bool,
        includeActivityQueryTool: Bool
    ) {
        if includeFullMacFileTools {
            schemas.append(contentsOf: [
                requestedSchema(
                    name: "mac_screenshot_save",
                    description: "Save a system screenshot as PNG with macOS screencapture, without displaying pixels to the model. Defaults to all displays, Desktop and macOS screenshot naming; returns saved paths. Optional window_id, app (front visible window by exact app name) or region selects one capture. Requires Full Mac file access, the Accessibility category and Screen Recording permission; existing files are refused. Use mac.look pixels:true separately to view masked model pixels.",
                    parametersJSON: params(properties: [
                        ("path", strSchema("PNG destination path; defaults to Desktop/Screenshot with the local date and time. Additional displays get numbered PNG paths.")),
                        ("window_id", intSchema("Exact visible window number; cannot combine with app or region.", minimum: 1)),
                        ("app", strSchema("Exact running app name; captures its front visible window without activating it.")),
                        ("region", strSchema("x,y,width,height in screen points; cannot combine with app or window_id.")),
                    ], required: [])
                ),
                requestedSchema(
                    name: "file_excerpt",
                    description: "Read numbered lines of a local text file. Returns start_line, end_line, total_lines, has_more and next arguments. For byte windows use files.read. Requires Trust Center Full Mac file access.",
                    parametersJSON: params(
                        properties: [
                            ("path", strSchema("Absolute path or path relative to the NativeAgent repo root.")),
                            ("start_line", intSchema("1-based start line, default 1.")),
                            ("max_lines", intSchema("Maximum lines, default 80, capped at 240. Requested text is capped at 1 MiB; for a larger window narrow this value, or use read_file byte windows for very long lines.")),
                        ],
                        required: ["path"]
                    )
                ),
                requestedSchema(
                    name: "grep",
                    description: "Search inside local text files for lines matching a pattern or phrase. Returns bounded matching text with file paths, line numbers and explicit coverage; narrow the path/pattern when results are limited. Available only when Trust Center Full Mac file access is active.",
                    parametersJSON: params(
                        properties: [
                            ("pattern", strSchema("Regex/search pattern.")),
                            ("path", strSchema("Directory or file to search. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.")),
                            ("max_results", intSchema("Maximum selected result lines, default/cap 50. Inspect coverage: a reached limit is not a total count. Narrow path/pattern to recover omitted matches; output is bounded to 30000 characters and engine capture to 1 MiB.")),
                        ],
                        required: ["pattern"]
                    )
                ),
                requestedSchema(
                    name: "git_status",
                    description: "Read branch, ahead/behind counts, and staged, unstaged, and untracked changes. Available only when Trust Center Full Mac file access is active.",
                    parametersJSON: params(
                        properties: [("cwd", strSchema("Repository directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace."))],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "git_diff",
                    description: "Read staged or unstaged changes, or committed patches since a date, optionally limited to a path. Available only when Trust Center Full Mac file access is active.",
                    parametersJSON: params(
                        properties: [
                            ("cwd", strSchema("Repository directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.")),
                            ("staged", boolSchema("Use --staged.")),
                            ("since", strSchema("Optional committed history boundary: today means local midnight; otherwise a Git date. Cannot combine with staged.")),
                            ("path", strSchema("Optional path filter.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "git_log",
                    description: "Read commits and changed files across them, optionally since a date. With since, the file union covers the entire period even when commit details reach their limit. Returns per-commit files and has_more coverage. Available only when Trust Center Full Mac file access is active.",
                    parametersJSON: params(
                        properties: [
                            ("cwd", strSchema("Repository directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.")),
                            ("limit", intSchema("Commit count, default 10, capped at 100.")),
                            ("since", strSchema("Optional history boundary: today means local midnight; otherwise a Git date.")),
                            ("path", strSchema("Optional path filter.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "repo_dirty_summary",
                    description: "Read a combined summary of the branch, changed files, and recent commits. Available only when Trust Center Full Mac file access is active.",
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
                    description: "Run a shell command via /bin/sh -c. Captures stdout/stderr/exit_code. Requires Trust Center Full Mac file_ops_allowed; queues an approval request unless toolAutonomy=auto for 'shell'. Default cwd is a verified NativeAgent source checkout when present, otherwise the canonical <dataRoot>/workspace used by public installs. Default timeout: 120s, max 600s. Use bash tool instead if you need bash-specific syntax (arrays, [[, process substitution). For checks, do not append `| tail; echo exit...` because that can mask the real failing exit code. \(Self.nativeToolPreferenceGuidance)",
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
                    description: "Run a shell command via /bin/bash -c (not sh). Same shape as shell. Use this when the command needs bash features: arrays, [[ ]] tests, process substitution, $'...' ANSI-C quoting, etc. For checks, do not append `| tail; echo exit...` because that can mask the real failing exit code. \(Self.nativeToolPreferenceGuidance)",
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
                    description: "Apply a unified diff patch via `git apply` (3-way merge by default inside a Git repository; plain apply outside one). Writes the patch payload to a tmpfile then runs git apply against it. Returns exit_code + stderr (which contains conflict info on failure). Default cwd is a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.",
                    parametersJSON: params(
                        properties: [
                            ("patch", strSchema("Required. The unified diff text. Will be written to a tmpfile before git apply.")),
                            ("cwd", strSchema("Optional existing working directory. Relative paths resolve in the canonical NativeAgent workspace/source checkout. Active Full Mac YOLO may select an ordinary absolute external project; sensitive authority and protected system paths remain denied.")),
                            ("three_way", nullableRecallField(boolSchema("Optional. Default true; passes --3way only inside a Git repository. Outside a repository, uses plain apply. Set false for strict apply that fails fast on context mismatch."))),
                        ],
                        required: ["patch"]
                    )
                ),
                requestedSchema(
                    name: "swift_build",
                    description: "Run a fixed-argv SwiftPM build. Ordinary modes use NativeAgent's workspace-confined outer wrapper; active Full Mac YOLO may build an explicitly selected external package without that wrapper. Command shape is `swift build --disable-sandbox --package-path <package_path> --configuration <debug|release>` plus optional product/target/jobs. TrustCenter, autonomy, audit receipts, and sensitive-path fences still apply.",
                    parametersJSON: params(
                        properties: [
                            ("package_path", strSchema("Optional Swift package directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical workspace. Active Full Mac YOLO may select an ordinary external package directory.")),
                        ("configuration", enumStringSchema(["debug", "release"], "Optional. debug or release. Defaults to debug.")),
                            ("product", strSchema("Optional product name to build. Mutually exclusive with target.")),
                            ("target", strSchema("Optional target name to build. Mutually exclusive with product.")),
                            ("jobs", intSchema("Optional SwiftPM --jobs value, clamped 1...64.")),
                            ("timeout_seconds", intSchema("Optional. Default 600, max 3600.")),
                            ("disable_swiftpm_sandbox", nullableRecallField(boolSchema("Optional. Defaults true so SwiftPM does not invoke its own sandbox-exec inside our outer wrapper (profiles cannot nest). Leave it true; setting it false makes the build fail at manifest compile."))),
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
                            ("configuration", enumStringSchema(["debug", "release"], "Optional. debug or release. Defaults to debug.")),
                            ("filter", strSchema("Optional SwiftPM --filter regex/specifier.")),
                            ("jobs", intSchema("Optional SwiftPM --jobs value, clamped 1...64.")),
                            ("timeout_seconds", intSchema("Optional. Default 900, max 3600.")),
                            ("disable_swiftpm_sandbox", nullableRecallField(boolSchema("Optional. Defaults true so SwiftPM does not invoke its own sandbox-exec inside our outer wrapper (profiles cannot nest). Leave it true; setting it false makes the build fail at manifest compile."))),
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
                    description: "Restart the already-installed NativeAgent.app bundle: writes an audit receipt, spawns a detached relauncher, then terminates the app after a \(Int(AppRestartCoordinator.terminateGraceSeconds))s grace so this turn finishes persisting. This does not build, stage, sign, or install new Swift code; after Swift source edits use install_app instead. After this tool returns 'restarting', keep the final reply to one short sentence; it must be composed and persisted inside the grace window. The relauncher waits for the process to exit and reopens the app bundle. Refuses if a tool-initiated restart fired within the last 10 minutes (cooldown). Requires Trust Center Full Mac file_ops_allowed; queues an approval unless toolAutonomy=auto for 'restart_app'.",
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
                    description: "File a self-evolution proposal into the evolution store (data/evolution/proposals.json). Use when you have identified a concrete improvement to your own codebase. With a diff it lands as 'proposed'; without one it lands as 'needs_diff'. This records a proposal without editing the live repo, building, or installing it. Automatic candidate builds are unavailable. Requires Trust Center Full Mac file_ops_allowed; queues an approval unless toolAutonomy=auto for 'evolution_propose'.",
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
                    description: "Withdraw one of your own self-evolution proposals — the one you filed by mistake. Moves it to the terminal 'denied' state with deny_reason 'withdrawn by agent: …' and an audit receipt. Refuses: proposals already in a terminal state (verified/reverted/denied), proposals recorded as 'building' (ask User to review this state), proposals past the withdrawal point (approved/installed — those need a revert, not a withdrawal), and any proposal you did not file yourself (only source='chat' records are yours; weekly / self_heal / external proposals are not withdrawable here). This never edits the live repo, never touches an installed change, and never withdraws anything on someone else's behalf. Requires Trust Center Full Mac file_ops_allowed; queues an approval unless toolAutonomy=auto for 'evolution_withdraw'; under the Everything (full run) trust posture the approval passes straight through and no card is shown.",
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
                    description: "Advance a self-evolution proposal that has already built green (status candidate_green). Standard modes stage a self_evolution.apply approval card. Admitted Full Mac YOLO enters the same candidate/CAS/backup/rollback executor directly without a per-call prompt; installation still requires Trust Center systemRebuild to be enabled. Returns an honest 'not installable yet' envelope if the proposal is not candidate_green. Requires Trust Center Full Mac file_ops_allowed.",
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
            schemas.append(requestedSchema(
                name: "mac_media",
                description: "Control the Mac's Now Playing app with a system media key: play/pause, next or previous across Music, Spotify, browsers and podcasts. Play/pause is a toggle; the receipt reports the key sent and observed Music/Spotify states without claiming an unknown app's playback state. Requires Full Mac system access; never launches Music or Spotify to read their states.",
                parametersJSON: params(properties: [
                    ("action", obj([("type", .string("string")),
                        ("enum", .array(["play", "resume", "pause", "toggle", "next", "skip", "previous"].map(JSONValue.string))),
                        ("description", .string("play / resume / pause / toggle send the play-pause key; next / skip send next; previous sends previous."))])),
                ], required: ["action"])
            ))
            schemas.append(requestedSchema(
                name: "mac_volume",
                description: "Read or change this Mac's output volume and mute state directly; no screen or guide read is needed. With no args, read only. Set level, adjust by signed percentage points, or set muted; returns the observed level and mute state.",
                parametersJSON: params(properties: [
                    ("level", intSchema("Output volume percent (0–100); cannot combine with adjust.", minimum: 0, maximum: 100)),
                    ("adjust", intSchema("Signed percentage points (−100–100), e.g. −10 to turn it down.", minimum: -100, maximum: 100)),
                    ("muted", boolSchema("true to mute, false to unmute; omit to preserve mute state.")),
                ], required: [])
            ))
            schemas.append(
                requestedSchema(
                    name: "system_info",
                    description: "Read this Mac's system, disk, memory, top five CPU/memory processes, battery, network, local/public IP, connected macOS VPN services and Wi-Fi SSID directly; unavailable fields are labeled. Public IP uses a 3-second HTTPS lookup. Only when requested, speed_test:true measures upload/download and responsiveness with networkQuality, limited to 20 seconds and using internet bandwidth. With app, only read that installed app's bundle version by exact name or full .app path in the standard application directories. With check_updates:true, only list available macOS software updates, read-only with a 30-second deadline; this does not check NativeAgent or App Store apps. Use app, check_updates or speed_test separately. Check App Store → Updates for App Store app updates. No app opening, screen or guide read is needed. Available only when Trust Center Full Mac system access is active.",
                    parametersJSON: params(properties: [
                        ("check_updates", boolSchema("List macOS software updates instead of system information; never installs anything.")),
                        ("app", strSchema("Exact installed app name or full .app path; read CFBundleShortVersionString and build directly without launching it.")),
                        ("speed_test", boolSchema("Only on request: measure internet upload/download and responsiveness for at most 20 seconds; uses bandwidth. Omit for an ordinary system read.")),
                    ], required: [])
                )
            )
        }
        if includeFullMacAccessibilityReadTools {
            // Perception requires both macOS Accessibility and the Trust Center category.
            schemas.append(contentsOf: [
                // Clipboard reads redact text and name non-text flavors without dumping them.
                requestedSchema(
                    name: "clipboard_read",
                    description: "Read what is on this Mac's clipboard right now, as text. Read-only: it leaves the clipboard and the screen unchanged. Pair it with a copy (select all, then ⌘C) to read a dense document the screen cannot show you in words. Lines that are themselves a secret — a password, an API key, a one-time code, a card number, a recovery phrase — come back as \"[redacted: <reason>]\" and are listed under `redactions`; that is redaction, not an empty clipboard, and re-reading will not reveal them. Non-text contents (an image, a file, an app's own flavor) are reported by type and size under `types` — the bytes are never returned. Available only when Trust Center Full Mac is active with the Accessibility category enabled.",
                    parametersJSON: params(
                        properties: [
                            ("max_chars", intSchema("Maximum characters of clipboard text to return. Default 8000, clamped to 0-32000. Use 0 for types and original text length only, with no text or redaction details returned; otherwise chars is the redacted text length. The result says whether it cut.")),
                        ],
                        required: []
                    )
                ),
                // Menu reads do not open menus; disabled items remain visible.
                requestedSchema(
                    name: "menu",
                    description: "List an app's menu bar as nameable paths — \"File › Export › PDF…\", \"Edit › Find › Find Next\". This is the cheapest deterministic route to anything an app can do: no coordinates, no scrolling, no guessing which toolbar icon means export. Read-only, and it does not open any menu — the paths come from the app's published accessibility tree whether or not a menu is drawn. Bounded: three levels deep, capped in item count, one walk (the result says if a bound cut it). Items that are greyed out are still listed with `enabled: false` — present but switched off in this state, which is different from absent. Press one with menu_press. Available only when Trust Center Full Mac is active with the Accessibility category enabled.",
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
                    description: "read a document end to end — a contract, a PDF, a long article, a thread. Different from `screen`: `screen` answers \"what is in front of me and what can I do to it\" in one bounded glance; `read` answers \"what does this say\" and returns all of it. If the window in front is showing a file (or you name one with `path`), the file's own text is extracted — PDFs through PDFKit, plain text directly — so you get the author's characters rather than a scrape of a rendering. Otherwise it reads the front window's text, scrolls one screenful, reads again, merges on the overlap, and keeps going until the content stops changing; it then scrolls back to where it started. It presses nothing, types nothing and opens nothing. Long results are retained whole for this turn — when the answer comes back as a bounded summary with a `result_handle`, page through the rest with app result.page (tool_result_page where that is your tool); do not re-run this to see more. Lines that are themselves a secret come back as \"[redacted: <reason>]\". Refusals are in words: no document in front, a password-protected file, a scanned PDF with no text layer (ask for `screen` instead), a secure password field. Available only when Trust Center Full Mac is active with the Accessibility category enabled; naming an explicit `path` additionally needs Full Mac file access.",
                    parametersJSON: params(
                        properties: [
                            ("path", strSchema("Optional: read this file instead of the screen — an absolute path to a PDF or a plain-text file. Omit it to read whatever document is in front of you (or, when the front window names no file, the window's own text).")),
                            ("app", strSchema("Optional: read this running app's front window instead of whatever is in front — \"read the contract, app: Preview\". The window is read where it sits: nothing is activated, raised or launched, so your focus does not move and neither does the person's. Refused in words if nothing by that name is running or the name matches more than one running app. Ignored when you name a `path`, which reads the file rather than any window.")),
                        ],
                        required: []
                    )
                ),
                // Addressable marks are the default calling convention; coordinates are fallback.
                requestedSchema(
                    name: "mac_view",
                    description: "see the screen the way a person does: one fused view of the frontmost window that returns the accessibility structure and a screenshot, with every clickable and scrollable element outlined and numbered on the image. Read the structure first — `marks` gives each number's role, label, value, state, frame and real element path, and `text` gives everything the window says in reading order; together they describe the screen completely, and the image is the spatial backdrop showing where each numbered thing sits rather than something you must decode. Use the numbered marks to understand where controls are; use act by name to interact with them. This call is read-only and changes nothing. Marks are valid only for the most recent view: if the screen may have changed, call mac_view again — an older view id is refused rather than guessed at. Read-only perception: it changes nothing. Needs the Trust Center Full Mac Accessibility category, and the picture half also needs the macOS Screen Recording permission (a separate grant from Accessibility) — when that is missing you still get the numbered legend, and the result says so.",
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
                    description: "Look at the live screen now. Default: a structured page in words — SCREEN (app/window), WHERE (navigation), LIST/GRID or CANVAS, DO (controls), SAYS (status). Address a numbered row as 'row 3' (a bare number means a control labeled with it); look again for fresh evidence. Pass part to inspect a section or thing; part: menu reads the app's menu bar. Pass app to read another running app's window without activating it; act with the same app works there in the background. Structured reads of NativeAgent itself are refused because self Accessibility reads deadlock; use app (desk.read, mind.inner_state, agent.introspect) for internal state. When a window's accessibility is thin (canvas, game, video), screen attaches one small image of just that window; part: 'visual region N' crops to that region. For actual visible desktop pixels, use pixels:true with no app or part. That capture reads the other windows through Accessibility only to find secret fields (passwords, card codes, keys), which it masks; a window it cannot fully inspect, including NativeAgent's own, is masked in full. It does not claim an action succeeded just because a screenshot was captured.",
                    parametersJSON: params(
                        properties: [
                            ("pixels", boolSchema("Set true for actual primary-desktop pixels to verify visual outcomes, including overlapping windows and Liquid Glass. Secret fields are masked; a window that cannot be fully inspected through Accessibility, including NativeAgent's own, is masked in full. Requires existing Full Mac read authority and Screen Recording permission. No focus change or permission prompt. With app or part it instead attaches that window's or region's image even when its accessibility is rich. Image is transient and bounded to 1600px; capture success is not action verification. Default false keeps the structured screen read.")),
                            ("structured", boolSchema("Include bounded, already-redacted controls for workspace selections in detail.controls. Each control's handle is bound to that result's frame_id; return both to act for an exact selection. Default false keeps the concise natural screen.")),
                            ("__sense_screen_frame", strSchema("The frozen screen identity from More. Pass the entire More object as mac.look args to continue that page with its original handles.")),
                            ("__sense_text_offset", intSchema("The reading position from More; pass it unchanged with __sense_screen_frame and app.")),
                            ("part", strSchema("Optional: a section, thing, or status readout to inspect by name. Use hud/readouts for observed status values, or a label such as Last drag or Energy to reveal a readout hidden by the ordinary display cap.")),
                            ("app", strSchema("Optional: read this running app's front window instead of whatever is in front, without activating it (\"Mail\", \"Safari\"). If nothing by that name is running, or the name matches more than one, the answer says so and names what is running.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "wait",
                    description: "Wait for the frontmost external Mac app's screen to settle or for `until` text to appear, for example while a page loads. This is not a general sleep or a wait for background jobs. Bounded (default 10s, max 60s); returns the final screen or a timeout. If NativeAgent is in front, use app {page:\"current\"} to inspect it; screen waiting cannot observe NativeAgent. With `agent`, wait for that contact's in-flight reply instead (default 60s, max 300s), returning the conversation as app agent.read shows it; no polling or resend needed.",
                    parametersJSON: params(
                        properties: [
                            ("until", strSchema("Optional: return as soon as this text appears on screen (case-insensitive).")),
                            ("seconds", intSchema("Optional: how long to watch. Default 10, max 60 (with agent: default 60, max 300).")),
                            ("agent", strSchema("Optional: a contact's name (as app agent.message takes it). Wait for its reply instead of watching the screen.")),
                            ("conversation", strSchema("Optional, with agent: the conversation name; omit for its current one.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "mac_look",
                    description: "look at the frontmost window — the app reads the on-screen accessibility structure and hands you the distilled answer instead of a tree you have to parse. Three grades: `glance` is one line (app, window title, how many controls, where the focus is, whether a sheet or dialog is up, the first few buttons); `look` is the structured percept — the window, the focused element, any modal, the landmarks (toolbar, sidebar, table, list, web area) and every labeled interactive control with a stable `handle`, its role, value and real element path; `stare` is the full raw AX tree, the full raw AX tree, and you should rarely need it. Prefer `glance` to orient and `look` to act: a look costs roughly a tenth to a seventieth of a stare. Controls the app publishes no name for are never hidden — they are counted by role under `unlabeled`. Handles are valid only for the returned `frame_id`; if the screen may have changed, look again. Read-only perception: it clicks nothing, types nothing and changes nothing. Requires the macOS Accessibility system grant; available only when Trust Center Full Mac is active with the Accessibility category enabled.",
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
                    description: "Pay continuous, explicit attention to this Mac without a polling loop or another model. `start` installs a passive, on-device event observer for a bounded time and returns a fresh fused screen view. `next` waits efficiently for physical pointer/keyboard/scroll activity or an app change (up to wait_ms), then returns one fresh fused view; keyboard content is never captured, only an activity pulse. Physical user input always wins: it immediately invalidates the old view and motor tools refuse with yielded_to_user until you call `next` and re-observe. `status` reports the live session; `stop` removes every observer and forgets the ephemeral state. While active, pass the returned attention.session and attention.user_sequence as attention_session and attention_user_sequence on every Mac motor action. Read-only perception under the Full Mac Accessibility gate; the screenshot half also needs Screen Recording permission.",
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
                    description: "Summarise which Mac apps were in use over a time range, from a local, on-device activity log the user explicitly opted into and separately allowed this selected AI provider to read. It knows which app was frontmost and for how long — not what was done inside it, not what was typed, and not the contents of any field. Where the user enabled window titles, a secret-redacted title may appear on example spans; treat it as a weak hint, not a description of the work, and never quote it as fact about content. Apps on the user's exclusion list are absent from the answer entirely, even for days when they were still being recorded, so totals can legitimately be lower than a full day. The answer is capped at 50 rows and refuses rather than silently truncating an over-dense source range. Read-only and deterministic; the store is never exposed to iPhone/Telegram/Slack/iCloud/bridges. If capture or Agent Access is off in Trust Center this tool refuses rather than returning an empty day; do not read a refusal as \"nothing happened\".",
                    parametersJSON: params(
                        properties: [
                        ("range", enumStringSchema(["today", "yesterday", "last_hour", "last_24_hours", "last_7_days", "last_30_days", "past_hour", "past_24_hours", "past_week", "this_week", "past_month"], "Named range: today, yesterday, last_hour, last_24_hours, last_7_days, last_30_days. Defaults to today. Ignored when `from` is given.")),
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
                    description: "Do a whole flow in ONE call with steps:[…] — names, menu paths ('Format > Make Plain Text'), chords, {verb,target,text,mode}; each verified on a fresh read, stops at first failure. One receipt line per step; a step ending in ? ('OK?') is skipped if absent. Menus and keys that need the screen stop with needs_front unless the task explicitly requests front:true. E.g. save as plain text on the Desktop: app:'TextEdit' front:true steps:['Format > Make Plain Text','OK?','cmd+s',{verb:'type',target:'Save As',text:'hello.txt'},'cmd+d','return'] (cmd+d = Desktop in a save dialog). In a Save sheet, type only the file name; choose a folder via Go to Folder (cmd+shift+g), type its path, then Return. Single act: verb + target, by name or visible ordinal, against a fresh fused screen. Semantic: click/open/type/select/toggle/scroll/dismiss. Physical: double_click, right_click, hover, move, drag (give `to`), hold, key (target a key/chord sequence like `cmd+s` or `1 2 3`; `hold` can target `key w`). For named type, mode:'replace' (default) keeps the existing form-fill behavior and can replace the whole value. mode:'append' preserves existing text, inserts at the target's verified end, and verifies prior text plus insertion; it never replaces the whole value. Include a newline in text when adding a new line. Append requires a named accessibility text target; if its contents or end cannot be verified, it refuses. type with no target keeps typing into whatever has focus (replace mode only); where accessibility can't set a value it types real keystrokes. Unlabeled pixel objects appear as numbered visual regions and take physical actions only. `repeat` runs a short burst, re-resolving the target before every attempt so moving targets are followed; ambiguity, drift, a vanished target or the time limit stops it. `holding` keeps keys/modifiers down around a physical move, drag, click, scroll or key (e.g. `w d` while dragging a world view). Accessibility targets use the app's own action; pixel-only ones use the bounded physical hand. Pass app to act in that app's window in the background without taking the front; if it needs the front it stops with needs_front and says why. Only pass front:true when the task explicitly asks to bring the app forward; then it restores the previous front app. Needs active Full Mac Accessibility app control; there is no per-call approval.",
                    parametersJSON: params(
                        properties: [
                            ("verb", enumStringSchema(["click", "double_click", "right_click", "open", "type", "select", "toggle", "scroll", "dismiss", "hover", "move", "drag", "hold", "key", "press"], "What to do. press = key for a key/chord (cmd+s, return), click for a named control. double_click and right_click are the real mouse gestures.")),
                            ("target", strSchema("The thing, by name as the screen shows it — a label, a partial label, an ordinal like 'row 3', or a numbered unlabeled target like 'visual region 2'. For hold, `key w d` holds W and D simultaneously for seconds; space-separated keys/chords and bare modifiers are supported. For key, a space-separated sequence remains sequential.")),
                            ("handle", strSchema("Optional exact control handle from screen structured:true. Requires its frame_id. Used by workspace selections; no name fallback or repeated action if stale. Supports click, open, type, focus, select, toggle, scroll without physical gesture options.")),
                            ("frame_id", strSchema("Required with handle: the same screen's detail.controls.frame_id. Old frames are refused; read the screen again to get current choices.")),
                            ("text", strSchema("For `type`: the literal text. Append adds exactly this text; include a newline when needed.")),
                            ("mode", enumStringSchema(["replace", "append"], "For named `type`: replace (default) keeps form-fill behavior and may replace the whole value; append inserts at the verified end, preserves prior text, and never sets the whole value. Append requires a named accessibility text target and verified contents/end; otherwise it refuses. Omit or use replace for other verbs.")),
                            ("direction", enumStringSchema(["up", "down", "left", "right"], "For `scroll`: which way to move. Left/right sends horizontal wheel input.")),
                            ("scroll_amount", intSchema("For scroll: wheel magnitude in lines, 1 for fine adjustment through120. Use0 (or omit) for ordinary/default behavior, including all non-scroll verbs. An explicit amount requests wheel input rather than page-key fallback.", minimum: 0, maximum: 120)),
                            ("to", strSchema("For `drag`: the named/numbered destination. A displayed canvas is also a target: drag from 'left side of canvas' to 'right side of canvas', or use top/bottom corners. Move, hover, pointer hold and scroll also accept canvas; fresh geometry and obstruction checks stay automatic.")),
                            ("to_app", strSchema("For `drag` only: the running app whose front window `to` lives in, when the drop lands in a different app from the one in front — \"drag report.pdf to the message body, to_app: Mail\". The destination is resolved in that app's window without activating it, so nothing moves while I am looking; then, if the drop needs that app in front, it stops with needs_front unless the task explicitly requests front:true. With front:true it is brought forward once and the result says that focus moved and why. Refused in words if the app is not running, if the name matches more than one running app, if nothing in that window answers to `to`, if raising it would cover the thing being picked up, or if the drag would cross a password field. Hold `option`/`cmd` with `holding` for the app's own copy/move variant. For text, prefer clipboard_write plus a paste — this is for dragging things accessibility can name.")),
                            ("steps", obj([
                                ("type", .string("array")),
                                ("maxItems", .int(12)),
                                ("description", .string("Optional: up to 12 acts in ONE call, in order — [\"AC\",\"9\",\"×\",\"8\",\"=\"] (a string presses/clicks that name, a menu path like 'File > Save', or a key/chord) or {verb, target, text, mode}. Each step reads the window fresh and is verified; it stops at the first failure and says which step. With steps, verb/target/mode are ignored at the top level; each step chooses its own mode (replace by default), and app/front apply to all.")),
                                ("items", obj([("anyOf", .array([
                                    obj([("type", .string("string"))]),
                                    obj([
                                        ("type", .string("object")),
                                        ("properties", obj([
                                            ("verb", strSchema("click, double_click, right_click, open, type, select, toggle, scroll, dismiss, key or press.")),
                                            ("target", strSchema("The name, as the screen shows it. Required for append; omit only for replace-mode type into whatever has focus.")),
                                            ("text", strSchema("For type: the literal text; include a newline when append should add a line.")),
                                            ("mode", enumStringSchema(["replace", "append"], "For named type: replace (default) keeps form-fill behavior; append preserves prior text and inserts at its verified end. Append requires a named accessibility text target; it never replaces the whole value. Omit or use replace for other verbs.")),
                                        ])),
                                        ("required", .array([.string("verb")])),
                                    ]),
                                ]))])),
                            ])),
                            ("app", strSchema("Optional: act in this running app's window (\"TextEdit\", \"Mail\") without bringing it forward. Works for accessibility clicks, typing, select, toggle and open; effects that need the screen stop with needs_front and say why.")),
                            ("front", boolSchema("Only when explicitly requested by the task. With app: bring that app forward for this act (menus, keys), then put the previous front app back. A name it lacks raises nothing. The result says how long it was in front.")),
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
                    description: "Press one menu item by name, as the menu bar shows it: \"File › Export › PDF…\". Levels can be separated by ›, >, or /. This runs the app's own menu handler — the same thing that happens when a person picks it — so it can save, close, quit, or delete depending on what you name. Resolve the path with `menu` first: an unknown path refuses and lists what is actually there, an ambiguous one refuses and names the candidates, and an item the app has greyed out refuses in words rather than pressing nothing and calling it done. Whether the intended thing happened is for the next look to say. Needs active Full Mac Accessibility app control; there is no per-call approval.",
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
                    description: "Put text on this Mac's clipboard, replacing whatever was there. The next paste (⌘V) in any app will produce this text, and what was on the clipboard before is gone. It types nothing and clicks nothing by itself — to get the text into a document, paste it afterwards. Bounded at 100000 characters. The result reports how many characters were written and whether reading the clipboard back matched; the text itself is never echoed. Needs active Full Mac Accessibility app control; there is no per-call approval.",
                    parametersJSON: params(
                        properties: [
                            ("text", strSchema("The text to place on the clipboard.")),
                        ],
                        required: ["text"]
                    )
                ),
                requestedSchema(
                    name: "go",
                    description: "Get to an app, file, folder, http/https URL, or System Settings pane link (x-apple.systempreferences:com.apple.wifi-settings-extension) through the canonical Mac-control owner, then read the fresh screen. Without front it opens or launches behind, activating nothing, and reads that app's window; act with app works there. With front:true, only when the task explicitly asks to bring it forward, it switches the screen and activation is independently verified. File/URL opening is reported only as an accepted request unless the screen proves where it landed. Needs active Full Mac Accessibility app control; there is no per-call approval.",
                    parametersJSON: params(
                        properties: [
                            ("name", strSchema("An app name, a file/folder path (~ allowed), an http/https URL, or an x-apple.systempreferences: pane link.")),
                            ("front", boolSchema("Only when the task explicitly asks to bring it forward: switch the screen to this destination. Defaults to false, which opens it behind.")),
                        ],
                        required: ["name"]
                    )
                ),
                // An action returns the observed change with its receipt.
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
