import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
// Blueprint: | `BuiltInToolSchemaFactory+MacSchemas.swift` | `BuiltInToolSchemaFactory`: `appendOptionalSchemas` |

extension BuiltInToolSchemaFactory {
    func appendOptionalSchemas(
        to schemas: inout [LLMToolSchema?],
        includeFullMacFileTools: Bool,
        includeFullMacSystemTools: Bool,
        includeFullMacAccessibilityReadTools: Bool,
        includeFullMacAccessibilityInjectionTools: Bool,
        includeActivityQueryTool: Bool
    ) {
        schemas.append(requestedSchema(
            name: "mac_location",
            toolClass: .read, capabilities: ["tool_call"],
            description: "Read where this Mac is through Location Services. If permission is unavailable, ask through its ordinary permission card; never infer a city from timezone or network information.",
            parametersJSON: ToolSchema.params(properties: [], required: [])
        ))
        if includeFullMacFileTools {
            schemas.append(contentsOf: [
                requestedSchema(
                    name: "mac_screenshot_save",
                    toolClass: .write, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                    description: "Save a system screenshot as PNG with macOS screencapture only when a saved file is requested. To look at the screen or take a screenshot and describe it, use mac.look pixels:true, which respects owner takeover and writes no file. Saving defaults to all displays, Desktop and macOS screenshot naming; returns saved paths without displaying pixels to the model. Optional window_id, app (front visible window by exact app name) or region selects one capture. Requires Full Mac file access, the Accessibility category and Screen Recording permission; existing files are refused.",
                    parametersJSON: ToolSchema.params(properties: [
                        ("path", ToolSchema.strSchema("PNG destination path; defaults to Desktop/Screenshot with the local date and time. Additional displays get numbered PNG paths.")),
                        ("window_id", ToolSchema.intSchema("Exact visible window number; cannot combine with app or region.", minimum: 1)),
                        ("app", ToolSchema.strSchema("Exact running app name; captures its front visible window without activating it.")),
                        ("region", ToolSchema.strSchema("x,y,width,height in screen points; cannot combine with app or window_id.")),
                    ], required: [])
                ),
                requestedSchema(
                    name: "file_excerpt",
                    toolClass: .read, capabilities: ["tool_call"],
                    description: "Read numbered lines of a local text file, or query its whole source for matching complete lines with positions and coverage. Continue with next unchanged. Requires Full Mac file access.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("path", ToolSchema.strSchema("Absolute path or path relative to the NativeAgent repo root.")),
                            ("query", ToolSchema.strSchema("Every whitespace-separated term must occur on a line, case-insensitively; empty reads consecutive lines. Search pages fit 24000 serialized bytes; a larger single record is refused, never split.")),
                            ("version", ToolSchema.strSchema("Copy next unchanged for continuation. file_changed means restart at start_line 1 without version.")),
                            ("start_line", ToolSchema.intSchema("1-based start line, default 1.")),
                            ("max_lines", ToolSchema.intSchema("Maximum lines, default 80, capped at 240. Requested text is capped at 1 MiB; for a larger window narrow this value, or use files.read byte windows for very long lines.")),
                        ],
                        required: ["path"]
                    )
                ),
                requestedSchema(
                    name: "grep",
                    toolClass: .read, capabilities: ["tool_call"],
                    description: "Search inside local text files for lines matching a pattern or phrase. Returns bounded matching text with file paths, line numbers and explicit coverage; narrow the path/pattern when results are limited. Available only when Full Mac file access is active.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("pattern", ToolSchema.strSchema("Regex/search pattern.")),
                            ("path", ToolSchema.strSchema("Directory or file to search. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.")),
                            ("max_results", ToolSchema.intSchema("Maximum selected result lines, default/cap 50. Inspect coverage: a reached limit is not a total count. Narrow path/pattern to recover omitted matches; output is bounded to 30000 characters and engine capture to 1 MiB.")),
                        ],
                        required: ["pattern"]
                    )
                ),
                requestedSchema(
                    name: "git_status",
                    toolClass: .read,
                    description: "Read parsed branch, ahead/behind counts, and staged, unstaged, and untracked changes once, without raw status duplication. Omitted cwd uses the app's verified source checkout, or workspace when none exists; returns cwd. Requires Full Mac file access.",
                    parametersJSON: ToolSchema.params(
                        properties: [("cwd", ToolSchema.strSchema("Repository directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace."))],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "git_diff",
                    toolClass: .read, capabilities: ["tool_call"],
                    description: "Read staged or unstaged changes, or committed patches since a date, optionally limited to a path. Omitted cwd uses the app's verified source checkout, or workspace when none exists; returns cwd. Requires Full Mac file access.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("cwd", ToolSchema.strSchema("Repository directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.")),
                            ("staged", ToolSchema.boolSchema("Use --staged.")),
                            ("since", ToolSchema.strSchema("Optional committed history boundary: today means local midnight; otherwise a Git date. Cannot combine with staged.")),
                            ("path", ToolSchema.strSchema("Optional path filter.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "git_log",
                    toolClass: .read, capabilities: ["tool_call"],
                    description: "Read commits and changed files across them, optionally since a date. Omitted cwd uses the app's verified source checkout, or workspace when none exists; returns cwd. With since, the file union covers the entire period even when commit details reach their limit. Returns per-commit files and has_more coverage. Requires Full Mac file access.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("cwd", ToolSchema.strSchema("Repository directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.")),
                            ("limit", ToolSchema.intSchema("Commit count, default 10, capped at 100.")),
                            ("since", ToolSchema.strSchema("Optional history boundary: today means local midnight; otherwise a Git date.")),
                            ("path", ToolSchema.strSchema("Optional path filter.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "repo_dirty_summary",
                    toolClass: .read, capabilities: ["tool_call"],
                    description: "Read a combined summary of the branch, changed files, and recent commits. Omitted cwd uses the app's verified source checkout, or workspace when none exists; returns cwd. Requires Full Mac file access.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("cwd", ToolSchema.strSchema("Repository directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.")),
                            ("log_limit", ToolSchema.intSchema("Recent commit count, default 5, capped at 20.")),
                        ],
                        required: []
                    )
                ),
                // CLI tools require Full Mac file access; the owner certifies literal reads.
                // The admitted bridge uses the same autonomy gate as local chat.
                requestedSchema(
                    name: "shell",
                    toolClass: .write, reach: .his, capabilities: ["process_spawn", "shell", "tool_call"],
                    description: "Run a shell command via /bin/sh -c. Captures stdout/stderr/exit_code. Requires admitted Full Mac file access. Default cwd is your canonical workspace, the same root as files mutations; relative cwd starts there. Reach the owner's source checkout only with explicit cwd. Literal commands certified by the shell owner (pwd, df, uname, whoami, uptime, simple git log/status/diff/show) run as confined reads; everything else stays write. A pre-launch refusal returns execution:not_run and effect:none. Default timeout: 120s, max 600s.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("cmd", ToolSchema.strSchema("Required. The shell command line. Passed as -c argument to /bin/sh.")),
                            ("cwd", ToolSchema.strSchema("Existing directory; defaults to your workspace and resolves relative paths there. Use explicit cwd for the source checkout. Active Full Mac may select an ordinary absolute external project; sensitive authority and protected system paths remain denied.")),
                            ("timeout_seconds", ToolSchema.intSchema("Optional. Default 120, max 600. Subprocess group gets SIGTERM then SIGKILL after 2s.")),
                        ],
                        required: ["cmd"]
                    )
                ),
                requestedSchema(
                    name: "bash",
                    toolClass: .write, reach: .his, capabilities: ["process_spawn", "shell", "tool_call"],
                    description: "Run a command via /bin/bash -c. Default cwd is your canonical workspace; relative cwd starts there. Use explicit cwd for the owner's source checkout. Same read certification and confinement as shell.run; everything else stays write. Pre-launch refusals return execution:not_run, effect:none. Use bash for arrays, [[ ]] tests and process substitution. Requires Full Mac file access.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("cmd", ToolSchema.strSchema("Required. The bash command line. Passed as -c argument to /bin/bash.")),
                            ("cwd", ToolSchema.strSchema("Existing directory; defaults to your workspace and resolves relative paths there. Use explicit cwd for the source checkout. Active Full Mac may select an ordinary absolute external project; sensitive authority and protected system paths remain denied.")),
                            ("timeout_seconds", ToolSchema.intSchema("Optional. Default 120, max 600.")),
                        ],
                        required: ["cmd"]
                    )
                ),
                requestedSchema(
                    name: "git",
                    toolClass: .write, reach: .his, capabilities: ["filesystem_write", "outside_app_data_write", "process_spawn", "shell", "tool_call"],
                    description: "Run git with explicit args. Equivalent to `git <args>`. Returns stdout/stderr/exit_code. Default cwd is a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace. Default timeout 60s.Args may be an array (preferred) or a shell-style string for forgiving model calls. Mutating ops remain autonomy-gated.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("args", stringOrStringArraySchema("Required. Full argv to pass to git. Prefer ['status'], ['log','--oneline','-5'], ['diff','HEAD~1','HEAD']; a string like 'status --short' is also accepted.")),
                            ("cwd", ToolSchema.strSchema("Optional existing working directory. Relative paths resolve in the canonical NativeAgent workspace/source checkout. Active Full Mac may select an ordinary absolute external project; sensitive authority and protected system paths remain denied.")),
                            ("timeout_seconds", ToolSchema.intSchema("Optional. Default 60, max 600.")),
                        ],
                        required: ["args"]
                    )
                ),
                requestedSchema(
                    name: "apply_patch",
                    toolClass: .write, capabilities: ["filesystem_write", "outside_app_data_write", "process_spawn", "shell", "tool_call"],
                    description: "Apply a unified diff patch via `git apply` (3-way merge by default inside a Git repository; plain apply outside one). Writes the patch payload to a tmpfile then runs git apply against it. Returns exit_code + stderr (which contains conflict info on failure). Default cwd is a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent workspace.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("patch", ToolSchema.strSchema("Required. The unified diff text. Will be written to a tmpfile before git apply.")),
                            ("cwd", ToolSchema.strSchema("Optional existing working directory. Relative paths resolve in the canonical NativeAgent workspace/source checkout. Active Full Mac may select an ordinary absolute external project; sensitive authority and protected system paths remain denied.")),
                            ("three_way", ToolSchema.nullable(ToolSchema.boolSchema("Optional. Default true; passes --3way only inside a Git repository. Outside a repository, uses plain apply. Set false for strict apply that fails fast on context mismatch."))),
                        ],
                        required: ["patch"]
                    )
                ),
                requestedSchema(
                    name: "swift_build",
                    toolClass: .write, capabilities: ["filesystem_write", "outside_app_data_write", "process_spawn", "shell", "tool_call"],
                    description: "Run a fixed-argv SwiftPM build. Ordinary modes use NativeAgent's workspace-confined outer wrapper; active Full Mac may build an explicitly selected external package without that wrapper. Command shape is `swift build --disable-sandbox --package-path <package_path> --configuration <debug|release>` plus optional product/target/jobs. TrustCenter, autonomy, audit receipts, and sensitive-path fences still apply.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("package_path", ToolSchema.strSchema("Optional Swift package directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical workspace. Active Full Mac may select an ordinary external package directory.")),
                        ("configuration", ToolSchema.enumStringSchema(["debug", "release"], "Optional. debug or release. Defaults to debug.")),
                            ("product", ToolSchema.strSchema("Optional product name to build. Mutually exclusive with target.")),
                            ("target", ToolSchema.strSchema("Optional target name to build. Mutually exclusive with product.")),
                            ("jobs", ToolSchema.intSchema("Optional SwiftPM --jobs value, clamped 1...64.")),
                            ("timeout_seconds", ToolSchema.intSchema("Optional. Default 600, max 3600.")),
                            ("disable_swiftpm_sandbox", ToolSchema.nullable(ToolSchema.boolSchema("Optional. Defaults true so SwiftPM does not invoke its own sandbox-exec inside our outer wrapper (profiles cannot nest). Leave it true; setting it false makes the build fail at manifest compile."))),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "swift_test",
                    toolClass: .write, capabilities: ["destructive", "filesystem_write", "outside_app_data_write", "process_spawn", "shell", "tool_call"],
                    description: "Run fixed-argv SwiftPM tests. Ordinary modes use NativeAgent's workspace-confined outer wrapper; active Full Mac may test an explicitly selected external package without that wrapper. Command shape is `swift test --disable-sandbox --package-path <package_path> --configuration <debug|release>` plus optional filter/jobs. TrustCenter, autonomy, audit receipts, and sensitive-path fences still apply.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("package_path", ToolSchema.strSchema("Optional Swift package directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical workspace. Active Full Mac may select an ordinary external package directory.")),
                            ("configuration", ToolSchema.enumStringSchema(["debug", "release"], "Optional. debug or release. Defaults to debug.")),
                            ("filter", ToolSchema.strSchema("Optional SwiftPM --filter regex/specifier.")),
                            ("jobs", ToolSchema.intSchema("Optional SwiftPM --jobs value, clamped 1...64.")),
                            ("timeout_seconds", ToolSchema.intSchema("Optional. Default 900, max 3600.")),
                            ("disable_swiftpm_sandbox", ToolSchema.nullable(ToolSchema.boolSchema("Optional. Defaults true so SwiftPM does not invoke its own sandbox-exec inside our outer wrapper (profiles cannot nest). Leave it true; setting it false makes the build fail at manifest compile."))),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "remote_node_list",
                    toolClass: .read, reach: .his,
                    description: "List explicitly configured MacControl trusted remote effect nodes, their pinned host-key fingerprints, enablement, and executable allowlists. This is a read-only inventory; remote nodes never own chat, memory, context, or schedules.",
                    parametersJSON: ToolSchema.params(properties: [], required: [])
                ),
                requestedSchema(
                    name: "remote_node_execute",
                    toolClass: .send, capabilities: ["filesystem_write", "process_spawn", "remote_effect", "tool_call"],
                    description: "Run one argv-shaped command on an explicitly enabled trusted remote node. The node is re-read at effect time, the executable must exactly match its allowlist, SSH host identity is pinned, output is bounded, and the receipt is returned with the result. This remains behind Full Mac; standard modes follow their normal autonomy gate, while admitted Full Mac runs without a per-call prompt.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("node_id", ToolSchema.strSchema("Required node id from node.list.")),
                            ("executable", ToolSchema.strSchema("Required absolute executable path; must exactly match the node allowlist.")),
                            ("arguments", stringArraySchema("Optional argv values. Values are individually shell-quoted; multiline/NUL arguments are rejected.")),
                            ("timeout_seconds", ToolSchema.intSchema("Optional. Default 60, clamped 1...300.")),
                        ],
                        required: ["node_id", "executable"]
                    )
                ),
                requestedSchema(
                    name: "install_app",
                    toolClass: .write, capabilities: ["destructive", "filesystem_write", "outside_app_data_write", "process_spawn", "system_control", "tool_call"],
                    description: "Canonical NativeAgent app install after Swift source changes. Schedules `script/install_app.sh` outside NativeAgent's outer sandbox, after a short grace delay, so the current reply can persist before the installer rebuilds, signs, installs to ~/Applications/NativeAgent.app, and restarts the app. Do not use `app.restart` for this; app.restart only relaunches the already-installed bundle.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("reason", ToolSchema.strSchema("Required. Why the install/rebuild is needed; lands in the audit envelope.")),
                            ("start_delay_seconds", ToolSchema.intSchema("Optional. Delay before launching install_app.sh so the final chat reply can persist. Defaults to app.restart's grace window; clamped 5...120.")),
                        ],
                        required: ["reason"]
                    )
                ),
                // Restart requires Full Mac file access and defaults to confirmation.
                // The detached relauncher waits for turn settlement and keeps the ten-minute cooldown.
                requestedSchema(
                    name: "restart_app",
                    toolClass: .write, capabilities: ["process_spawn", "system_control", "tool_call"],
                    description: "Restart the already-installed NativeAgent.app bundle: writes an audit receipt, spawns a detached relauncher, then requests termination when the originating turn settles. If that turn stalls for \(Int(AppRelaunch.stalledTurnSeconds))s, the app exits with an explicit unfinished outcome. This does not build, stage, sign, or install new Swift code; after Swift source edits use app.install instead. The relauncher observes process exit and reopens the app bundle; it aborts if quitting takes more than \(AppRelaunch.relaunchExitDeadlineSeconds)s. Refuses if a tool-initiated restart fired within the last 10 minutes (cooldown). Requires admitted Full Mac file access; restarting needs no routine approval card.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("reason", ToolSchema.strSchema("Required. Why the restart is needed (lands in the audit envelope at data/restart_audit/<uuid>.json).")),
                        ],
                        required: ["reason"]
                    )
                ),
            ])
        }
        if includeFullMacSystemTools {
            schemas.append(requestedSchema(
                name: "mac_media",
                toolClass: .write, reach: .his,
                description: "Control the Mac's Now Playing app with a system media key: play/pause, next or previous across Music, Spotify, browsers and podcasts. Play/pause is a toggle; the receipt reports the key sent and observed Music/Spotify states without claiming an unknown app's playback state. Requires Full Mac system access; never launches Music or Spotify to read their states.",
                parametersJSON: ToolSchema.params(properties: [
                    ("action", ToolSchema.obj([("type", .string("string")),
                        ("enum", .array(["play", "resume", "pause", "toggle", "next", "skip", "previous"].map(JSONValue.string))),
                        ("description", .string("play / resume / pause / toggle send the play-pause key; next / skip send next; previous sends previous."))])),
                ], required: ["action"])
            ))
            schemas.append(requestedSchema(
                name: "mac_volume",
                toolClass: .write, reach: .his,
                description: "Read or change this Mac's output volume and mute state directly; no screen or guide read is needed. With no args, read only. Set level, adjust by signed percentage points, or set muted; returns the observed level and mute state.",
                parametersJSON: ToolSchema.params(properties: [
                    ("level", ToolSchema.intSchema("Output volume percent (0–100); cannot combine with adjust.", minimum: 0, maximum: 100)),
                    ("adjust", ToolSchema.intSchema("Signed percentage points (−100–100), e.g. −10 to turn it down.", minimum: -100, maximum: 100)),
                    ("muted", ToolSchema.boolSchema("true to mute, false to unmute; omit to preserve mute state.")),
                ], required: [])
            ))
            schemas.append(
                requestedSchema(
                    name: "system_info",
                    toolClass: .read, reach: .his, capabilities: ["tool_call"],
                    description: "Read this Mac's system, named disk capacity (disk: Data at /System/Volumes/Data; system_disk: sealed System at /), memory, top five CPU/memory processes, battery, network, local/public IP, connected macOS VPN services, Wi-Fi SSID and whether the person is here directly; unavailable fields are labeled. With person:true, only read whether the person is here: {here, idle_seconds} from their own input (yours never counts), away after 300 seconds idle, here null while unknown. Public IP uses a 3-second HTTPS lookup. Only when requested, speed_test:true measures upload/download and responsiveness with networkQuality, limited to 20 seconds and using internet bandwidth. With app, only read that installed app's bundle version by exact name or full .app path from the Mac's app index. With check_updates:true, only list available macOS software updates, read-only with a 30-second deadline; this does not check NativeAgent or App Store apps. Use app, check_updates or speed_test separately.No app opening, screen or guide read is needed. Available only when Full Mac system access is active.",
                    parametersJSON: ToolSchema.params(properties: [
                        ("check_updates", ToolSchema.boolSchema("List macOS software updates instead of system information; never installs anything.")),
                        ("app", ToolSchema.strSchema("Exact installed app name or full .app path; read CFBundleShortVersionString and build directly without launching it.")),
                        ("speed_test", ToolSchema.boolSchema("Only on request: measure internet upload/download and responsiveness for at most 20 seconds; uses bandwidth. Omit for an ordinary system read.")),
                        ("person", ToolSchema.boolSchema("Only read whether the person is here and how long since their own input; instant, nothing else is read.")),
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
                    toolClass: .read, reach: .his,
                    description: "Read what is on this Mac's clipboard right now, as text. Read-only: it leaves the clipboard and the screen unchanged.Lines that are themselves a secret — a password, an API key, a one-time code, a card number, a recovery phrase — come back as \"[redacted: <reason>]\" and are listed under `redactions`; that is redaction, not an empty clipboard, and re-reading will not reveal them. Non-text contents (an image, a file, an app's own flavor) are reported by type and size under `types` — the bytes are never returned. Available only when Full Mac is active with the Accessibility category enabled.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("max_chars", ToolSchema.intSchema("Maximum characters of clipboard text to return. Default 8000, clamped to 0-32000. Use 0 for types and original text length only, with no text or redaction details returned; otherwise chars is the redacted text length. The result says whether it cut.")),
                        ],
                        required: []
                    )
                ),
                // Menu reads do not open menus; disabled items remain visible.
                requestedSchema(
                    name: "menu",
                    toolClass: .read, reach: .his,
                    description: "List an app's menu bar as nameable paths — \"File › Export › PDF…\", \"Edit › Find › Find Next\". This is the cheapest deterministic route to anything an app can do: no coordinates, no scrolling, no guessing which toolbar icon means export. Read-only, and it does not open any menu — the paths come from the app's published accessibility tree whether or not a menu is drawn. Bounded: three levels deep, capped in item count, one walk (the result says if a bound cut it). Items that are greyed out are still listed with `enabled: false` — present but switched off in this state, which is different from absent. Press one with mac.menu_press. Available only when Full Mac is active with the Accessibility category enabled.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("app", ToolSchema.strSchema("Optional: read this running app's menu bar instead of the frontmost app's, without activating it. Defaults to whatever is in front.")),
                            ("find", ToolSchema.strSchema("Optional: words or a path (\"Import Timeline\", \"File › Import › Timeline…\"). Answers the paths holding every word instead of the whole bar, and `found`: up to three items with exactly that name or path, each with its shortcut.")),
                        ],
                        required: []
                    )
                ),
                // Read consolidates the requested content instead of requiring repeated frames.
                requestedSchema(
                    name: "read",
                    toolClass: .read, reach: .his,
                    description: "Read document text from an explicit file path or the live window. File: extracts PDF/plain text, limited to 32 MiB, 400 PDF pages and 400,000 characters. Window: merges overlapping reads, bounded to 40 frames, 400,000 characters and 20 seconds; checks scroll restoration after movement. Read reached_end, truncated, truncation_reason, gaps and scroll_restored where returned; a stopped read may be incomplete. Presses/types/opens nothing. Page retained output with app result.page and result_handle; paging cannot recover unread source text. Secret lines become \"[redacted: <reason>]\". On failure, use the cause and supplied remedy; for a scanned PDF with no text layer, use screen. Requires Full Mac Accessibility; explicit path also requires Full Mac file access.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("path", ToolSchema.strSchema("Optional: read this file instead of the screen — an absolute path to a PDF or a plain-text file. Omit it to read the live window’s text, including unsaved edits.")),
                            ("app", ToolSchema.strSchema("Read this running app’s window without activating, raising or launching it, e.g. Preview. Missing/ambiguous app: use the failure’s cause and remedy. Ignored with path, which reads the file.")),
                        ],
                        required: []
                    )
                ),
                // Addressable marks are the default calling convention; coordinates are fallback.
                requestedSchema(
                    name: "mac_view",
                    toolClass: .read, reach: .his, capabilities: ["tool_call"],
                    description: "Read a bounded accessibility view and screenshot of the frontmost window. marks numbers selected clickable/scrollable elements with role, label, value, state, frame and element path; text contains selected reading-order text. Caps: 60 marks, 80 text items, plus node/depth/image limits; this is not complete window coverage. Read structure first, image for spatial context. Read-only. Marks belong to the latest view; after possible change, read mac.view again. Requires Full Mac Accessibility; screenshot also needs macOS Screen Recording. Without that grant, the legend remains and the missing image is reported.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("full_screen", ToolSchema.boolSchema("Capture the whole display instead of just the frontmost window. Defaults to false (the focused window).")),
                            ("max_marks", ToolSchema.intSchema("Maximum number of elements to number. Clamped to the view's own cap (60); omit for the default.")),
                            ("max_text_items", ToolSchema.intSchema("Maximum lines of on-screen text to return. Clamped to the view's own cap (80); omit for the default.")),
                            ("max_image_bytes", ToolSchema.intSchema("Maximum encoded PNG size. The image is downscaled to fit; clamped to the view's own cap. Omit for the default.")),
                            ("max_nodes", ToolSchema.intSchema("Maximum number of AX nodes to consider when choosing marks. Clamped to the reader's own cap.")),
                            ("max_depth", ToolSchema.intSchema("Maximum AX tree depth to descend. Clamped to the reader's own cap.")),
                        ],
                        required: []
                    )
                ),
                // Perception grades let the caller request only the detail needed.
                requestedSchema(
                    name: "screen",
                    toolClass: .read, reach: .his, capabilities: ["tool_call"],
                    description: "Look at the live screen now. Default: a structured page in words — SCREEN (app/window), WHERE (navigation), LIST/GRID or CANVAS, DO (controls), SAYS (status). Address a numbered row as 'row 3' (a bare number means a control labeled with it); look again for fresh evidence. Pass part to inspect a section or thing; part: menu reads the app's menu bar. Pass app to read another running app's window without activating it; act with the same app works there in the background. Structured reads of NativeAgent itself are refused because self Accessibility reads deadlock; use app (desk.read, mind.inner_state, agent.introspect) for internal state. When a window's accessibility is thin (canvas, game, video), screen attaches one small image of just that window; part: 'visual region N' crops to that region. For actual visible desktop pixels, use pixels:true with no app or part. That capture reads the other windows through Accessibility only to find secret fields (passwords, card codes, keys), which it masks; a window it cannot fully inspect, including NativeAgent's own, is masked in full. It does not claim an action succeeded just because a screenshot was captured. A window read's detail carries last_input (hers, person or unknown) and person_idle_seconds (how long the person has been idle, never counting your own input by any route; left out while unknown, as when the person hasn't been seen since launch or Secure Input hides typing), plus permission: input_monitoring_needed when macOS does not yet let NativeAgent tell them apart; check it before bringing an app forward.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("pixels", ToolSchema.boolSchema("Set true for actual primary-desktop pixels to verify visual outcomes, including overlapping windows and Liquid Glass. Secret fields are masked; a window that cannot be fully inspected through Accessibility, including NativeAgent's own, is masked in full. Requires existing Full Mac read authority and Screen Recording permission. No focus change or permission prompt. With app or part it instead attaches that window's or region's image even when its accessibility is rich. Image is transient and bounded so you see it at the receipt's own size (short side ≤ 768 px); capture success is not action verification. Default false keeps the structured screen read.")),
                            ("structured", ToolSchema.boolSchema("Include bounded, already-redacted controls for workspace selections in detail.controls. Each control's handle is bound to that result's frame_id; return both to act for an exact selection. Default false keeps the concise natural screen.")),
                            ("__sense_screen_frame", ToolSchema.strSchema("The frozen screen identity from More. Pass the entire More object as mac.look args to continue that page with its original handles.")),
                            ("__sense_text_offset", ToolSchema.intSchema("The reading position from More; pass it unchanged with __sense_screen_frame and app.")),
                            ("part", ToolSchema.strSchema("Optional: a section, thing, or status readout to inspect by name. Use hud/readouts for observed status values, or a label such as Last drag or Energy to reveal a readout hidden by the ordinary display cap.")),
                            ("app", ToolSchema.strSchema("Optional: read this running app's front window instead of whatever is in front, without activating it (\"Mail\", \"Safari\"). If nothing by that name is running, or the name matches more than one, the answer says so and names what is running.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "wait",
                    toolClass: .read, reach: .his, capabilities: ["tool_call"],
                    description: "Wait for the frontmost external Mac app's screen to settle or for `until` text to appear, for example while a page loads. This is not a general sleep or a wait for background jobs. Bounded (default 10s, max 60s); returns the final screen or a timeout. If NativeAgent is in front, use app {page:\"current\"} to inspect it; screen waiting cannot observe NativeAgent. With `agent`, wait for that contact's in-flight reply instead (default 60s, max 300s), returning the conversation as app agent.read shows it; no polling or resend needed.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("until", ToolSchema.strSchema("Optional: return as soon as this text appears on screen (case-insensitive).")),
                            ("seconds", ToolSchema.intSchema("Optional: how long to watch. Default 10, max 60 (with agent: default 60, max 300).")),
                            ("agent", ToolSchema.strSchema("Optional: a contact's name (as app agent.message takes it). Wait for its reply instead of watching the screen.")),
                            ("conversation", ToolSchema.strSchema("Optional, with agent: the conversation name; omit for its current one.")),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "mac_look",
                    toolClass: .read, reach: .his, capabilities: ["tool_call"],
                    description: "Read the frontmost window’s accessibility view. glance: one-line app/window, control count, focus, modal and first buttons. look: window, focus, modal, landmarks and bounded labeled controls with handles, roles, values and element paths. stare: bounded raw AX tree. Unlabeled controls are counted by role. Node/depth/affordance caps limit coverage; handles belong to the returned frame_id, so read again after possible change. Read-only; requires macOS Accessibility and Full Mac Accessibility.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("grade", ToolSchema.enumStringSchema(["glance", "look", "stare"], "How hard to look. Defaults to look.")),
                            ("max_affordances", ToolSchema.intSchema("Maximum labeled interactive controls to return. Clamped to the compiler's own cap (60); omit for the default.")),
                            ("max_nodes", ToolSchema.intSchema("Maximum number of AX nodes to walk. Clamped to the reader's own cap.")),
                            ("max_depth", ToolSchema.intSchema("Maximum AX tree depth to descend. Clamped to the reader's own cap.")),
                            ("scope", ToolSchema.enumStringSchema(
                                ["page", "chrome", "both"],
                                "For a browser or Electron window: `page` (the default) spends the whole walk on the web page and collapses the browser's own toolbar and bookmarks bar to one summary line; `chrome` looks at the browser's controls instead; `both` walks the whole window in one pass, where the page competes with the chrome for the node budget. Ignored for a window with no web area — the result always says which scope it used."
                            )),
                        ],
                        required: []
                    )
                ),
                requestedSchema(
                    name: "mac_attention",
                    toolClass: .read, reach: .his, capabilities: ["tool_call"],
                    description: "Pay continuous, explicit attention to this Mac without a polling loop or another model. `start` installs a passive, on-device event observer for a bounded time and returns a fresh fused screen view. `next` waits efficiently for physical pointer/keyboard/scroll activity or an app change (up to wait_ms), then returns one fresh fused view; keyboard content is never captured, only an activity pulse. Physical user input always wins: it immediately invalidates the old view and motor tools refuse with yielded_to_user until you call `next` and re-observe. `status` reports the live session; `stop` removes every observer and forgets the ephemeral state. While active, pass the returned attention.session and attention.user_sequence as attention_session and attention_user_sequence on every Mac motor action. Read-only perception under the Full Mac Accessibility gate; the screenshot half also needs Screen Recording permission.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("mode", ToolSchema.enumStringSchema(["start", "next", "status", "stop"], "Attention operation. Defaults to status.")),
                            ("session", ToolSchema.strSchema("Session id returned by start. Required for next.")),
                            ("after_sequence", ToolSchema.intSchema("For next: wait only for activity newer than this attention sequence.")),
                            ("wait_ms", ToolSchema.intSchema("For next: event-driven wait before refreshing anyway, 0-15000ms. Defaults to 1500.")),
                            ("duration_seconds", ToolSchema.intSchema("For start: bounded observer lifetime, 15-1800 seconds. Defaults to 300.")),
                            ("full_screen", ToolSchema.boolSchema("Capture the whole display instead of the focused window.")),
                            ("max_marks", ToolSchema.intSchema("Maximum numbered elements, with the same cap as mac.view.")),
                            ("max_text_items", ToolSchema.intSchema("Maximum visible text items, with the same cap as mac.view.")),
                            ("max_image_bytes", ToolSchema.intSchema("Maximum encoded PNG bytes, with the same cap as mac.view.")),
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
                    toolClass: .read, capabilities: ["tool_call"],
                    description: "Summarize frontmost Mac apps and durations from the local activity log, not actions, typing or field contents. Recording must be on. Outside admitted Full Mac, activity-history model access must also be on and remote surfaces are refused. Trust-admitted Full Mac may return this bounded result to the selected provider on an admitted remote surface; it does not enable recording or change retention. Optional secret-redacted window titles are weak hints, never proof of content. Current exclusions also remove past spans, so totals may be below a full day. Read-only; at most 50 rows; an over-dense source range refuses instead of silently truncating. A refusal does not mean nothing happened.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                        ("range", ToolSchema.enumStringSchema(["today", "yesterday", "last_hour", "last_24_hours", "last_7_days", "last_30_days", "past_hour", "past_24_hours", "past_week", "this_week", "past_month"], "Named range: today, yesterday, last_hour, last_24_hours, last_7_days, last_30_days. Defaults to today. Ignored when `from` is given.")),
                            ("from", ToolSchema.strSchema("Explicit range start: epoch seconds, an ISO-8601 instant, or YYYY-MM-DD (midnight in the asking timezone).")),
                            ("to", ToolSchema.strSchema("Explicit range end, same formats as `from`. Defaults to now.")),
                            ("bundle_id", ToolSchema.strSchema("Restrict the answer to one app's bundle identifier, e.g. com.apple.Safari.")),
                            ("timezone", ToolSchema.strSchema("IANA timezone the day/hour buckets are computed in, e.g. Europe/London. Defaults to this Mac's current timezone.")),
                            ("limit", ToolSchema.intSchema("Maximum rows in the answer. Clamped to 50; the answer says what the cap removed.")),
                        ],
                        required: []
                    )
                ),
            ])
        }
        if includeFullMacAccessibilityInjectionTools {
            let point: [(String, JSONValue)] = [
                ("type", .string("object")),
                ("properties", ToolSchema.obj([("x", numSchema("Image pixels from the left edge.")), ("y", numSchema("Image pixels from the top edge."))])),
                ("required", .array([.string("x"), .string("y")])),
            ]
            let at = ToolSchema.obj(point + [("description", .string("Instead of a target: a point in pixels of an image a screen call handed you; click, double_click, right_click, hover, move or hold lands there."))])
            let from = ToolSchema.obj(point + [("description", .string("For drag by point: where it starts, in pixels of the image; give `to` as a point too."))])
            let image = ToolSchema.strSchema("The screen observation's reference (frame_id and image.id are the same). With at/from: its delivered image's pixels. Omitted: the latest screen image this session was handed.")
            schemas.append(contentsOf: [
                requestedSchema(
                    name: "act",
                    toolClass: .write, reach: .his, capabilities: ["ax_injection", "mac_control", "tool_call"],
                    description: "Act by name/visible ordinal against a fresh screen, or run up to 12 steps in order. Steps accept names, menu paths, key chords or {verb,target,text,mode}; each reads/verifies afresh, stops on first failure and returns a receipt line. A trailing ? skips an absent optional target. Example: app:'TextEdit', front:true, steps:['Format > Make Plain Text','OK?','cmd+s',{verb:'type',target:'Save As',text:'hello.txt'},'cmd+d','return'] (cmd+d selects Desktop in a save dialog). Named controls use accessibility; unlabeled visual regions accept physical gestures only. For points, use at:{x,y}, or drag from:{x,y} to:{x,y}, in the delivered image’s pixels; image defaults to this conversation’s latest screen image. The receipt reports the mapped screen point; repeat/to_app do not apply to point acts. Named type defaults to replace; append preserves verified prior text and inserts exactly text at its verified end (include newlines). Unverifiable append refuses. Targetless type uses current focus in replace mode; when accessibility cannot set text, it uses keystrokes. repeat re-resolves each attempt and stops on ambiguity, drift, disappearance or time limit. holding wraps physical input in held keys/modifiers. Parameter help retains each gesture’s controls. With app behind, accessibility acts in the background; menus/keys/real input stop with needs_front unless the task explicitly requests front:true, which restores the previous front app afterward. Shotgun may bring the app forward. Requires Full Mac Accessibility app control; no per-call approval.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("verb", ToolSchema.enumStringSchema(["click", "double_click", "right_click", "open", "type", "select", "toggle", "scroll", "dismiss", "hover", "move", "drag", "hold", "key", "press"], "What to do. press = key for a key/chord (cmd+s, return), click for a named control. double_click and right_click are the real mouse gestures.")),
                            ("target", ToolSchema.strSchema("The thing, by name as the screen shows it — a label, a partial label, an ordinal like 'row 3', or a numbered unlabeled target like 'visual region 2'. For hold, `key w d` holds W and D simultaneously for seconds; space-separated keys/chords and bare modifiers are supported. For key, a space-separated sequence remains sequential.")),
                            ("handle", ToolSchema.strSchema("Exact control from screen structured:true, with its frame_id. Native verb enum permits click, open, type, select, toggle, scroll (press aliases click); no physical gesture options. Workspace selections additionally support focus; this native schema does not expose it. A stale handle requires a fresh screen read; no name substitution or repeated action.")),
                            ("frame_id", ToolSchema.strSchema("The screen observation's reference, shared by handles and image pixels; image is an alias. Required with handle. Old handles are refused; read the screen again to get current choices.")),
                            ("text", ToolSchema.strSchema("For `type`: the literal text. Append adds exactly this text; include a newline when needed.")),
                            ("mode", ToolSchema.enumStringSchema(["replace", "append"], "For named `type`: replace (default) keeps form-fill behavior and may replace the whole value; append inserts at the verified end, preserves prior text, and never sets the whole value. Append requires a named accessibility text target and verified contents/end; otherwise it refuses. Omit or use replace for other verbs.")),
                            ("direction", ToolSchema.enumStringSchema(["up", "down", "left", "right"], "For `scroll`: which way to move. Left/right sends horizontal wheel input.")),
                            ("scroll_amount", ToolSchema.intSchema("For scroll: wheel magnitude in lines, 1 for fine adjustment through120. Use0 (or omit) for ordinary/default behavior, including all non-scroll verbs. An explicit amount requests wheel input rather than page-key fallback.", minimum: 0, maximum: 120)),
                            ("to", ToolSchema.obj([("anyOf", .array([ToolSchema.strSchema(), ToolSchema.obj(point)])), ("description", .string("For `drag`: the named/numbered destination. A displayed canvas is also a target: drag from 'left side of canvas' to 'right side of canvas', or use top/bottom corners. Move, hover, pointer hold and scroll also accept canvas; fresh geometry and obstruction checks stay automatic. With `from`, a point {x, y} in the same image's pixels."))])),
                            ("at", at),
                            ("from", from),
                            ("image", image),
                            ("to_app", ToolSchema.strSchema("Drag destination in another running app, e.g. Mail. Resolves to without activation; if the drop needs the front, stops with needs_front unless the task explicitly requests front:true. Reports any focus move and cause. Missing/ambiguous app or target, source obstruction, or crossing a password field stops the drag: follow the failure’s cause and remedy. holding:option/cmd selects the app’s copy/move variant. For text, prefer mac.clipboard_write and paste.")),
                            ("again", ToolSchema.boolSchema("Run every step again, even ones a stopped batch already landed.")),
                            ("steps", ToolSchema.obj([
                                ("type", .string("array")),
                                ("maxItems", .int(12)),
                                ("description", .string("Optional: up to 12 acts in ONE call, in order — [\"AC\",\"9\",\"×\",\"8\",\"=\"] (a string presses/clicks that name, a menu path like 'File > Save', or a key/chord) or {verb, target, text, mode}. Each step reads the window fresh and is verified; it stops at the first failure and says which step. With steps, verb/target/mode are ignored at the top level; each step chooses its own mode (replace by default), and app/front apply to all.")),
                                ("items", ToolSchema.obj([("anyOf", .array([
                                    ToolSchema.obj([("type", .string("string"))]),
                                    ToolSchema.obj([
                                        ("type", .string("object")),
                                        ("properties", ToolSchema.obj([
                                            ("verb", ToolSchema.strSchema("click, double_click, right_click, open, type, select, toggle, scroll, dismiss, key or press.")),
                                            ("target", ToolSchema.strSchema("The name, as the screen shows it. Required for append; omit only for replace-mode type into whatever has focus, or when at/from gives a point.")),
                                            ("to", ToolSchema.obj([("anyOf", .array([ToolSchema.strSchema(), ToolSchema.obj(point)])), ("description", .string("For drag: the named destination, or with `from` a point {x, y} in image pixels."))])),
                                            ("at", at),
                                            ("from", from),
                                            ("image", image),
                                            ("frame_id", image),
                                            ("text", ToolSchema.strSchema("For type: the literal text; include a newline when append should add a line.")),
                                            ("mode", ToolSchema.enumStringSchema(["replace", "append"], "For named type: replace (default) keeps form-fill behavior; append preserves prior text and inserts at its verified end. Append requires a named accessibility text target; it never replaces the whole value. Omit or use replace for other verbs.")),
                                        ])),
                                        ("required", .array([.string("verb")])),
                                    ]),
                                ]))])),
                            ])),
                            ("app", ToolSchema.strSchema("Optional: act in this running app's window (\"TextEdit\", \"Mail\") without bringing it forward. Works for accessibility clicks, typing, select, toggle and open; effects that need the screen stop with needs_front and say why.")),
                            ("front", ToolSchema.boolSchema("Only when explicitly requested by the task. With app: bring that app forward for this act (menus, keys), then put the previous front app back. Not needed when the app is already in front or Shotgun is up. A name it lacks raises nothing. The result says how long it was in front.")),
                            ("seconds", numSchema("For hover or hold: duration up to10 seconds. For drag: paced travel duration, bounded0.08–2 seconds;0/omission uses0.24 seconds. Drag duration controls movement, not two endpoint pauses.", minimum: 0, maximum: 10)),
                            ("repeat", ToolSchema.intSchema("Optional bounded burst count. The target is freshly re-resolved before every attempt; planning and real elapsed execution are capped at 30 seconds.", minimum: 1, maximum: 12)),
                            ("interval", numSchema("Optional pause between repeated attempts.", minimum: 0, maximum: 2)),
                            ("holding", ToolSchema.strSchema("Optional keys/modifiers held around a physical action, such as `w d`, `shift`, or `cmd+w`. Works with pointer hold, including right-button hold while movement keys are down. Not valid with a keyboard hold (put all keys in its target) or literal type.")),
                            ("button", ToolSchema.enumStringSchema(["auto", "left", "right"], "Use auto for the ordinary/default action, including key, type, scroll, move, and hover. Use left or right only to request an explicit mouse button on click, open (double-click), drag, or pointer hold. Right drag sends genuine right-button events, not Control-left-drag. Omission is equivalent to auto.")),
                        ],
                        required: ["verb", "target"]
                    )
                ),
                // Clipboard writes require app-control authority because they replace the next
                // paste. Menu presses run the app's own handler, including destructive actions.
                requestedSchema(
                    name: "menu_press",
                    toolClass: .write, reach: .his, capabilities: ["ax_injection", "tool_call"],
                    description: "Press one menu item by name, as the menu bar shows it: \"File › Export › PDF…\". Levels can be separated by ›, >, or /. This runs the app's own menu handler — the same thing that happens when a person picks it — so it can save, close, quit, or delete depending on what you name. Resolve the path with `menu` first: an unknown path refuses and lists what is actually there, an ambiguous one refuses and names the candidates, and a disabled item refuses; use the cause and supplied remedy. Whether the intended thing happened is for the next look to say. Needs active Full Mac Accessibility app control; there is no per-call approval.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("path", ToolSchema.obj([
                                ("description", .string("The menu path to press: one string, e.g. \"File › Export › PDF…\" or \"Edit > Find > Find Next\", or the levels as a list of titles [\"File\", \"Export\", \"PDF…\"] (one press, not one per entry).")),
                                ("anyOf", .array([
                                    ToolSchema.obj([("type", .string("string"))]),
                                    ToolSchema.obj([("type", .string("array")), ("items", ToolSchema.obj([("type", .string("string"))])), ("minItems", .int(1))]),
                                ])),
                            ])),
                            ("app", ToolSchema.strSchema("Optional: press in this running app's menu bar instead of the frontmost app's. Defaults to whatever is in front.")),
                        ],
                        required: ["path"]
                    )
                ),
                requestedSchema(
                    name: "clipboard_write",
                    toolClass: .write, reach: .his, capabilities: ["clipboard_write", "tool_call"],
                    description: "Put text on this Mac's clipboard, replacing whatever was there. The next paste (⌘V) in any app will produce this text, and what was on the clipboard before is gone. It types nothing and clicks nothing by itself — to get the text into a document, paste it afterwards. Bounded at 100000 characters. The result reports how many characters were written and whether reading the clipboard back matched; the text itself is never echoed. Needs active Full Mac Accessibility app control; there is no per-call approval.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("text", ToolSchema.strSchema("The text to place on the clipboard.")),
                        ],
                        required: ["text"]
                    )
                ),
                requestedSchema(
                    name: "go",
                    toolClass: .write, reach: .his, capabilities: ["mac_control", "tool_call"],
                    description: "Get to an app, file, folder, http/https URL, or System Settings pane link (x-apple.systempreferences:com.apple.wifi-settings-extension) through the canonical Mac-control owner, then read the fresh screen. Without front it opens or launches behind, activating nothing, and reads that app's window; act with app works there. While Shotgun is up it always goes in front. With front:true, only when the task explicitly asks to bring it forward, it switches the screen and activation is independently verified. File/URL opening is reported only as an accepted request unless the screen proves where it landed. Needs active Full Mac Accessibility app control; there is no per-call approval.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("name", ToolSchema.strSchema("An app name, a file/folder path (~ allowed), an http/https URL, or an x-apple.systempreferences: pane link.")),
                            ("front", ToolSchema.boolSchema("Only when the task explicitly asks to bring it forward: switch the screen to this destination. Defaults to false, which opens it behind.")),
                        ],
                        required: ["name"]
                    )
                ),
                // An action returns the observed change with its receipt.
                requestedSchema(
                    name: "mac_wake",
                    toolClass: .write, reach: .his,
                    description: "Wake the screen: if this Mac is showing a screensaver or the display has gone to sleep, nudge it away and hand back a fresh view of the real desktop underneath, in one call.It posts the smallest possible input — a one-point mouse move plus a bare Shift tap, neither of which can click, type text, or authenticate — and then returns exactly what mac.view returns (`marks`, `text`, the annotated image, and a `view` id you can act on), plus a `wake` block saying whether the screen really came back. If the saver/login layer remains, it reports that observed obstruction without guessing why. Requires Full Mac and Accessibility access; waking the display raises no routine card.",
                    parametersJSON: ToolSchema.params(
                        properties: [
                            ("key_tap", ToolSchema.boolSchema("Also tap the left shift key, which types nothing but wakes some sleeping displays a mouse move alone does not. On by default; pass key_tap:false to omit the Shift tap.")),
                            ("settle_ms", ToolSchema.intSchema("How long to wait after the nudge before capturing, 0-3000ms. Defaults to 700, which is enough for the screensaver to finish tearing down. Raise it if the returned view still shows the saver.")),
                            ("full_screen", ToolSchema.boolSchema("Capture the whole screen instead of just the frontmost window, same as mac.view.")),
                            ("attention_session", ToolSchema.strSchema("Required while mac_attention is active: its current conversation id.")),
                            ("attention_user_sequence", ToolSchema.intSchema("Required while mac_attention is active: the user_sequence from its latest observed fused view.")),
                        ],
                        required: []
                    )
                ),
            ])
        }
    }
}
