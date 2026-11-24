import Foundation
import MacNerves
import NativeAgentCore
import PersistenceCore
import ProviderRouting
// Blueprint: | `MacActions+Mac.swift` | mac action contracts and execution |

enum MacActions {}

private struct MacNoArgs: DoorArgs {
    static let doorFields: [DoorFieldDescriptor] = []

    init(door: inout DoorObjectDecoder) {}
}

extension MacActions {
    static let macActions: [ActionDescriptor] = {
        var schemas: [ActionDescriptor] = []
        schemas.append(ActionDescriptor(MacNoArgs.self,
            name: "mac_location",
            run: { context, _ in
                try await context.client.dispatchMacLocation(invocation: context.invocation)
            },
            toolClass: .read, capabilities: [.toolCall],
            description: """
                Read where this Mac is through Location Services. If permission is unavailable, ask through its ordinary permission card; never \
                infer a city from timezone or network information.
                """
        ))
        schemas.append(contentsOf: [
            ActionDescriptor(MacScreenshotSaveArgs.self,
                name: "mac_screenshot_save",
                availability: .files, run: { context, input in
                    try await context.client.impl_mac_screenshot_save(turn: context.turn, invocation: context.invocation, input: input, surface: context.surface)
                },
                toolClass: .write, capabilities: [.filesystemWrite, .outsideAppDataWrite, .toolCall],
                description: """
                    Save a system screenshot as PNG with macOS screencapture only when a saved file is requested. To look at the screen or take \
                    a screenshot and describe it, use mac.look pixels:true, which respects owner takeover and writes no file. Saving defaults \
                    to all displays, Desktop and macOS screenshot naming; returns saved paths without displaying pixels to the model. Optional \
                    window_id, app (front visible window by exact app name) or region selects one capture. Requires Full Mac file access, the \
                    Accessibility category and Screen Recording permission; existing files are refused.
                    """
            ),
            ActionDescriptor(MacFileExcerptArgs.self,
                name: "file_excerpt",
                availability: .files, run: MacFileExcerptArgs.local,
                toolClass: .read, capabilities: [.toolCall],
                description: """
                    Read numbered lines of a local text file, or query its whole source for matching complete lines with positions and \
                    coverage. Continue with next unchanged. Requires Full Mac file access.
                    """
            ),
            ActionDescriptor(MacGrepArgs.self,
                name: "grep",
                availability: .files, run: MacGrepArgs.local,
                toolClass: .read, capabilities: [.toolCall],
                description: """
                    Search inside local text files for lines matching a pattern or phrase. Returns bounded matching text with file paths, line \
                    numbers and explicit coverage; narrow the path/pattern when results are limited. Available only when Full Mac file access \
                    is active.
                    """
            ),
            ActionDescriptor(MacGitStatusArgs.self,
                name: "git_status",
                availability: .files, run: MacGitStatusArgs.local,
                toolClass: .read,
                description: """
                    Read parsed branch, ahead/behind counts, and staged, unstaged, and untracked changes once, without raw status duplication. \
                    Omitted cwd uses the app's verified source checkout, or workspace when none exists; returns cwd. Requires Full Mac file \
                    access.
                    """
            ),
            ActionDescriptor(MacGitDiffArgs.self,
                name: "git_diff",
                availability: .files, run: MacGitDiffArgs.local,
                toolClass: .read, capabilities: [.toolCall],
                description: """
                    Read staged or unstaged changes, or committed patches since a date, optionally limited to a path. Omitted cwd uses the \
                    app's verified source checkout, or workspace when none exists; returns cwd. Requires Full Mac file access.
                    """
            ),
            ActionDescriptor(MacGitLogArgs.self,
                name: "git_log",
                availability: .files, run: MacGitLogArgs.local,
                toolClass: .read, capabilities: [.toolCall],
                description: """
                    Read commits and changed files across them, optionally since a date. Omitted cwd uses the app's verified source checkout, \
                    or workspace when none exists; returns cwd. With since, the file union covers the entire period even when commit details \
                    reach their limit. Returns per-commit files and has_more coverage. Requires Full Mac file access.
                    """
            ),
            ActionDescriptor(MacRepoDirtySummaryArgs.self,
                name: "repo_dirty_summary",
                availability: .files, run: MacRepoDirtySummaryArgs.local,
                toolClass: .read, capabilities: [.toolCall],
                description: """
                    Read a combined summary of the branch, changed files, and recent commits. Omitted cwd uses the app's verified source \
                    checkout, or workspace when none exists; returns cwd. Requires Full Mac file access.
                    """
            ),
            // CLI tools require Full Mac file access; the owner certifies literal reads. The admitted bridge uses the same autonomy gate as local chat.
            ActionDescriptor(ShellArgs.self,
                name: "shell",
                availability: .files, run: { context, input in
                    await SwiftToolDispatcher.impl_shell(turn: context.turn, input: input, dataRoot: context.runtime.dataRoot)
                },
                toolClass: .write, reach: .person, capabilities: [.processSpawn, .shell, .toolCall],
                description: """
                    Run a shell command via /bin/sh -c. Captures stdout/stderr/exit_code. Requires admitted Full Mac file access. Default cwd \
                    is your canonical workspace, the same root as files mutations; relative cwd starts there. Reach the owner's source checkout \
                    only with explicit cwd. Literal commands certified by the shell owner (pwd, df, uname, whoami, uptime, simple git \
                    log/status/diff/show) run as confined reads; everything else stays write. A pre-launch refusal returns execution:not_run \
                    and effect:none. Default timeout: 120s, max 600s.
                    """
            ),
            ActionDescriptor(BashArgs.self,
                name: "bash",
                availability: .files, run: { context, input in
                    await SwiftToolDispatcher.impl_shell(turn: context.turn, input: input, dataRoot: context.runtime.dataRoot, executable: "/bin/bash", toolName: "bash")
                },
                toolClass: .write, reach: .person, capabilities: [.processSpawn, .shell, .toolCall],
                description: """
                    Run a command via /bin/bash -c. Default cwd is your canonical workspace; relative cwd starts there. Use explicit cwd for \
                    the owner's source checkout. Same read certification and confinement as shell.run; everything else stays write. Pre-launch \
                    refusals return execution:not_run, effect:none. Use bash for arrays, [[ ]] tests and process substitution. Requires Full \
                    Mac file access.
                    """
            ),
            ActionDescriptor(GitArgs.self,
                name: "git",
                availability: .files, run: { context, input in
                    await SwiftToolDispatcher.impl_git(turn: context.turn, input: input, dataRoot: context.runtime.dataRoot)
                },
                toolClass: .write, reach: .person, capabilities: [.filesystemWrite, .outsideAppDataWrite, .processSpawn, .shell, .toolCall],
                description: """
                    Run git with an explicit argv array. Returns stdout/stderr/exit_code. Default cwd is a verified NativeAgent source checkout \
                    when present, otherwise the canonical NativeAgent workspace. Default timeout 60s. Mutating ops remain autonomy-gated.
                    """
            ),
            ActionDescriptor(MacApplyPatchArgs.self,
                name: "apply_patch",
                availability: .files, run: { context, input in
                    await SwiftToolDispatcher.impl_apply_patch(turn: context.turn, input: input, dataRoot: context.runtime.dataRoot)
                },
                toolClass: .write, capabilities: [.filesystemWrite, .outsideAppDataWrite, .processSpawn, .shell, .toolCall],
                description: """
                    Apply a unified diff patch via `git apply` (3-way merge by default inside a Git repository; plain apply outside one). \
                    Writes the patch payload to a tmpfile then runs git apply against it. Returns exit_code + stderr (which contains conflict \
                    info on failure). Default cwd is a verified NativeAgent source checkout when present, otherwise the canonical NativeAgent \
                    workspace.
                    """
            ),
            ActionDescriptor(SwiftBuildArgs.self,
                name: "swift_build",
                availability: .files, run: { context, input in
                    await SwiftToolDispatcher.impl_swift_package(turn: context.turn, command: "build", input: input, dataRoot: context.runtime.dataRoot)
                },
                toolClass: .write, capabilities: [.filesystemWrite, .outsideAppDataWrite, .processSpawn, .shell, .toolCall],
                description: """
                    Run a fixed-argv SwiftPM build. Ordinary modes use NativeAgent's workspace-confined outer wrapper; active Full Mac may \
                    build an explicitly selected external package without that wrapper. Command shape is `swift build --disable-sandbox \
                    --package-path <package_path> --configuration <debug|release>` plus optional product/target/jobs. TrustCenter, autonomy, \
                    audit receipts, and sensitive-path fences still apply.
                    """
            ),
            ActionDescriptor(SwiftTestArgs.self,
                name: "swift_test",
                availability: .files, run: { context, input in
                    await SwiftToolDispatcher.impl_swift_package(turn: context.turn, command: "test", input: input, dataRoot: context.runtime.dataRoot)
                },
                toolClass: .write, capabilities: [.destructive, .filesystemWrite, .outsideAppDataWrite, .processSpawn, .shell, .toolCall],
                description: """
                    Run fixed-argv SwiftPM tests. Ordinary modes use NativeAgent's workspace-confined outer wrapper; active Full Mac may test \
                    an explicitly selected external package without that wrapper. Command shape is `swift test --disable-sandbox --package-path \
                    <package_path> --configuration <debug|release>` plus optional filter/jobs. TrustCenter, autonomy, audit receipts, and \
                    sensitive-path fences still apply.
                    """
            ),
            ActionDescriptor(MacNoArgs.self,
                name: "remote_node_list",
                availability: .files, run: { context, _ in
                    try await context.client.impl_remote_node_list()
                },
                toolClass: .read, reach: .person,
                description: """
                    List explicitly configured MacControl trusted remote effect nodes, their pinned host-key fingerprints, enablement, and \
                    executable allowlists. This is a read-only inventory; remote nodes never own chat, memory, context, or schedules.
                    """
            ),
            ActionDescriptor(RemoteNodeExecuteArgs.self,
                name: "remote_node_execute",
                availability: .files, run: { context, input in
                    try await context.client.impl_remote_node_execute(input: input)
                },
                toolClass: .send, capabilities: [.filesystemWrite, .processSpawn, .remoteEffect, .toolCall],
                description: """
                    Run one argv-shaped command on an explicitly enabled trusted remote node. The node is re-read at effect time, the \
                    executable must exactly match its allowlist, SSH host identity is pinned, output is bounded, and the receipt is returned \
                    with the result. This remains behind Full Mac; standard modes follow their normal autonomy gate, while admitted Full Mac \
                    runs without a per-call prompt.
                    """
            ),
            ActionDescriptor(MacInstallAppArgs.self,
                name: "install_app",
                availability: .files, run: { context, input in
                    await SwiftToolDispatcher.impl_install_app(input: input, dataRoot: context.runtime.dataRoot)
                },
                toolClass: .write, capabilities: [.destructive, .filesystemWrite, .outsideAppDataWrite, .processSpawn, .systemControl,
                    .toolCall],
                description: """
                    Canonical NativeAgent app install after Swift source changes. Schedules `script/install_app.sh` outside NativeAgent's outer \
                    sandbox, after a short grace delay, so the current reply can persist before the installer rebuilds, signs, installs to \
                    ~/Applications/NativeAgent.app, and restarts the app. Do not use `app.restart` for this; app.restart only relaunches the \
                    already-installed bundle.
                    """
            ),
            // Restart requires Full Mac file access and defaults to confirmation. The detached relauncher waits for turn settlement and keeps the
            // ten-minute cooldown.
            ActionDescriptor(MacRestartAppArgs.self,
                name: "restart_app",
                availability: .files, run: { context, input in
                    return await AppRelaunch.shared.requestRestart(turn: context.turn,
                        reason: input.reason,
                        source: "chat:\(context.surface)"
                    )
                },
                toolClass: .write, capabilities: [.processSpawn, .systemControl, .toolCall],
                description: """
                    Restart the already-installed NativeAgent.app bundle: writes an audit receipt, spawns a detached relauncher, then requests \
                    termination when the originating turn settles. If that turn stalls for \(Int(AppRelaunch.stalledTurnSeconds))s, the app \
                    exits with an explicit unfinished outcome. This does not build, stage, sign, or install new Swift code; after Swift source \
                    edits use app.install instead. The relauncher reopens the app bundle once the old process has exited, however long its \
                    quit settles. Refuses if a restart called through app fired within the last 10 minutes (cooldown). Requires admitted Full \
                    Mac file access; restarting needs no routine approval card.
                    """
            ),
        ])
        schemas.append(ActionDescriptor(MacMediaArgs.self,
            name: "mac_media",
            availability: .system, run: MacMediaArgs.local,
            toolClass: .write, reach: .person,
            description: """
                Control the Mac's live Now Playing app with a system media key: toggle, next or previous across Music, Spotify, browsers and \
                podcasts. The player process must be known and obeys its integration's Write switch where one exists. The receipt names the \
                observed player and key sent without confirming playback. Requires Full Mac system access; never launches a player to resolve \
                it. For idempotent play, resume or pause use the player's own action.
                """
        ))
        schemas.append(ActionDescriptor(MacVolumeArgs.self,
            name: "mac_volume",
            availability: .system, run: MacVolumeArgs.local,
            toolClass: .write, reach: .person,
            description: """
                Read or change this Mac's output volume and mute state directly; no screen or guide read is needed. With no args, read only. \
                Set level, adjust by signed percentage points, or set muted; returns the observed level and mute state.
                """
        ))
        schemas.append(
            ActionDescriptor(MacSystemInfoArgs.self,
                name: "system_info",
                availability: .system, run: MacSystemInfoArgs.local,
                toolClass: .read, reach: .person, capabilities: [.toolCall],
                description: """
                    Read this Mac's system, named disk capacity (disk: Data at /System/Volumes/Data; system_disk: sealed System at /), memory, \
                    top five CPU/memory processes, battery, local network addresses, connected macOS VPN services, Wi-Fi SSID and whether the \
                    person is here directly; unavailable fields are labeled. With person:true, only read whether the person is here: {here, \
                    idle_seconds} from their own input (yours never counts), away after 300 seconds idle, here null while unknown. Ordinary \
                    system reads send no network probes. Only when requested, speed_test:true measures upload/download and responsiveness with \
                    networkQuality, limited to 20 seconds and using internet bandwidth. With app, only read that installed app's bundle version \
                    by exact name or full .app path from the Mac's app index. With check_updates:true, only list available macOS software \
                    updates, read-only with a 30-second deadline; this does not check NativeAgent or App Store apps. Use app, check_updates or \
                    speed_test separately.No app opening, screen or guide read is needed. Available only when Full Mac system access is active.
                    """
            )
        )
        // Perception requires both macOS Accessibility and the Trust Center category.
        schemas.append(contentsOf: [
            ActionDescriptor(MacClipboardReadArgs.self,
                name: "clipboard_read",
                availability: .accessibility, run: MacClipboardReadArgs.control,
                toolClass: .read, reach: .person,
                description: """
                    Read what is on this Mac's clipboard right now, as text. Read-only: it leaves the clipboard and the screen unchanged.Lines \
                    that are themselves a secret — a password, an API key, a one-time code, a card number, a recovery phrase — come back as \
                    \"[redacted: <reason>]\" and are listed under `redactions`; that is redaction, not an empty clipboard, and re-reading will \
                    not reveal them. Non-text contents (an image, a file, an app's own flavor) are reported by type and size under `types` — \
                    the bytes are never returned. Concealed or transient clipboard content returns no text or text length, with a note saying why. \
                    A clipboard change during the read returns clipboard_unavailable without a snapshot. \
                    Available only when Full Mac is active with the Accessibility category enabled.
                    """
            ),
            // Do not open menus to inspect them; disabled items remain evidence.
            ActionDescriptor(MacMenuArgs.self,
                name: "menu",
                availability: .accessibility, run: MacMenuArgs.control,
                toolClass: .read, reach: .person,
                description: """
                    List an app's menu bar as nameable paths — \"File › Export › PDF…\", \"Edit › Find › Find Next\". This is the cheapest \
                    deterministic route to anything an app can do: no coordinates, no scrolling, no guessing which toolbar icon means export. \
                    Read-only, and it does not open any menu — the paths come from the app's published accessibility tree whether or not a menu \
                    is drawn. Bounded: three levels deep, capped in item count, one walk (the result says if a bound cut it). Items that are \
                    greyed out are still listed with `enabled: false` — present but switched off in this state, which is different from absent. \
                    Press one with mac.menu_press. Available only when Full Mac is active with the Accessibility category enabled.
                    """
            ),
            // Consolidate requested content so perception does not require repeated frames.
            ActionDescriptor(MacReadArgs.self,
                name: "read",
                availability: .accessibility, courier: .read, run: { context, input in
                    try await context.client.impl_mac_read_tool(turn: context.turn, invocation: context.invocation, tool: context.tool, input: input.wire.merging(context.transportMetadata) { argument, _ in argument }, surface: context.surface)
                },
                toolClass: .read, reach: .person,
                description: """
                    Read document text from an explicit file path or the live window. File: extracts PDF/plain text, limited to 32 MiB, 400 PDF \
                    pages and 400,000 characters. Window: merges verified overlap, bounded to 40 frames, 400,000 characters and 20 seconds; \
                    unknown overlap returns gaps and truncated. It checks scroll restoration after movement. Read reached_end, truncation_reason \
                    and scroll_restored where returned. A stopped read may be incomplete. Presses/types/opens nothing. Page retained output with app result.page and \
                    result_handle; paging cannot recover unread source text. Secret lines become \"[redacted: <reason>]\". On failure, use the \
                    cause and supplied remedy; for a scanned PDF with no text layer, use screen. Requires Full Mac Accessibility; explicit path \
                    also requires Full Mac file access.
                    """
            ),
            // Limit perception detail to the caller's need.
            ActionDescriptor(MacScreenArgs.self,
                name: "screen",
                availability: .accessibility, courier: .screen, run: MacScreenArgs.verbs,
                toolClass: .read, reach: .person, capabilities: [.toolCall],
                description: """
                    Look at the live screen now. Default: a structured page in words — SCREEN (app/window), WHERE (navigation), LIST/GRID or \
                    CANVAS, DO (controls), SAYS (status). Address a numbered row as 'row 3' (a bare number means a control labeled with it); \
                    look again for fresh evidence. Pass part to inspect a section or thing; part: menu reads the app's menu bar. Pass app to \
                    read a named app without activating it. A stopped app succeeds with status:ok, app and running:false; a running app with no \
                    readable window succeeds with running:true, windows:0 and any cheaply readable menus. Nothing is launched or opened. Act \
                    with the same app works there in the background when its target is available. Structured reads of NativeAgent itself are \
                    refused because self Accessibility reads deadlock; use app (desk.read, mind.inner_state, agent.introspect) for internal \
                    state. When a window's accessibility is thin (canvas, game, video), screen attaches one small image of just that window; \
                    part: 'visual region N' crops to that region. For actual visible desktop pixels, use pixels:true with no app or part. That \
                    capture reads the other windows through Accessibility only to find secret fields (passwords, card codes, keys), which it \
                    masks; a window it cannot fully inspect, including NativeAgent's own, is masked in full. It does not claim an action \
                    succeeded just because a screenshot was captured. A window read's detail carries last_input (agent, person or unknown) and \
                    person_idle_seconds (how long the person has been idle, never counting your own input by any route; left out while unknown, \
                    as when the person hasn't been seen since launch or Secure Input hides typing), plus permission: input_monitoring_needed \
                    when macOS does not yet let NativeAgent tell them apart; check it before bringing an app forward.
                    """
            ),
            ActionDescriptor(MacWaitArgs.self,
                name: "wait",
                availability: .accessibility, run: MacWaitArgs.verbs,
                toolClass: .read, reach: .person, capabilities: [.toolCall],
                description: """
                    Wait for the frontmost external Mac app's screen to settle or for `until` text to appear, for example while a page loads. \
                    This is not a general sleep or a wait for background jobs. Bounded (default 10s, max 60s); returns the final screen or a \
                    timeout. If NativeAgent is in front, use app {page:\"current\"} to inspect it; screen waiting cannot observe NativeAgent. \
                    With `agent`, wait for that contact's in-flight reply instead (default 60s, max 300s), returning the conversation as app \
                    agent.read shows it; no polling or resend needed.
                    """
            ),
        ])
        // Keep activity capture at app/duration granularity, outside actions and field contents.
        schemas.append(contentsOf: [
            ActionDescriptor(MacActivityQueryArgs.self,
                name: "activity_query",
                availability: .activity, run: { context, input in
                    try await context.client.impl_activity_query_tool(turn: context.turn, tool: context.tool, input: input.wire.merging(context.transportMetadata) { argument, _ in argument }, surface: context.surface)
                },
                toolClass: .read, capabilities: [.toolCall],
                description: """
                    Summarize frontmost Mac apps and durations from the local activity log, not actions, typing or field contents. Recording \
                    must be on. Outside admitted Full Mac, activity-history model access must also be on and remote surfaces are refused. \
                    Trust-admitted Full Mac may return this bounded result to the selected provider on an admitted remote surface; it does not \
                    enable recording or change retention. Optional secret-redacted window titles are weak hints, never proof of content. \
                    Current exclusions also remove past spans, so totals may be below a full day. Read-only; at most 50 rows; an over-dense \
                    source range refuses instead of silently truncating. A refusal does not mean nothing happened.
                    """
            ),
        ])
        schemas.append(contentsOf: [
            ActionDescriptor(MacActArgs.self,
                name: "act",
                availability: .accessibility, courier: .act, run: MacActArgs.verbs,
                toolClass: .write, reach: .person, capabilities: [.axInjection, .macControl, .toolCall],
                description: """
                    Act by name/visible ordinal against a fresh screen, or run up to 12 steps in order. A name needs no look first: the act \
                    reads the screen itself before it acts. To see the immediate result, use one app call with actions in order: \
                    [{action:"mac.act",args:{app:"TextEdit",verb:"scroll",direction:"down"}},{action:"mac.look",args:{app:"TextEdit",pixels:true}}]. \
                    Steps accept names, menu paths, key \
                    chords, {verb,target,text,mode}, or {verb,handle,frame_id}; handle steps re-resolve the recorded identity live, stopping \
                    when it disappears or changes; each reads/verifies afresh, stops on first failure and returns a receipt line. A trailing ? \
                    skips an absent optional target. Example: app:'TextEdit', front:true, steps:['Format > Make Plain \
                    Text','OK?','cmd+s',{verb:'type',target:'Save As',text:'~/Desktop/hello.txt'},'Save'] (a whole path typed into a save \
                    panel's name field places the folder and names the file; the file on disk is the proof it saved). Named controls use \
                    accessibility; unlabeled visual regions accept physical gestures only. For points, use \
                    at:{x,y}, or drag from:{x,y} to:{x,y}, in the delivered image’s pixels; image defaults to this conversation’s latest screen \
                    image. The receipt reports the mapped screen point; repeat/to_app do not apply to point acts. Named type defaults to \
                    replace; append preserves verified prior text and inserts exactly text at its verified end (include newlines). Unverifiable \
                    append refuses. type with at clicks there then types into the editor that takes focus. Targetless type uses current \
                    editable focus in replace mode, even with frame_id and no handle. An unreadable editor receives keys with an unverified \
                    receipt and a pixel look offered; unknown or noneditable focus refuses. A bare scroll targets the window’s main content. \
                    A named scroll can use a target whose enabled state is false or unknown. \
                    Key chords post keys directly. repeat re-resolves each attempt and stops on ambiguity, drift, disappearance or time limit. \
                    holding wraps physical input in held keys/modifiers. Parameter help retains each gesture’s controls. With app behind, \
                    accessibility acts in the background; menus/keys/real input stop with needs_front unless the task explicitly requests \
                    front:true, which requests restoration of the previous front app afterward. Shotgun may bring the app forward. Requires Full Mac \
                    Accessibility app control; no per-call approval.
                    """
            ),
            // Clipboard writes require app-control authority because they replace the next paste. Menu presses run the app's own handler, including
            // destructive actions.
            ActionDescriptor(MacMenuPressArgs.self,
                name: "menu_press",
                availability: .accessibility, run: MacMenuPressArgs.control,
                toolClass: .write, reach: .person, capabilities: [.axInjection, .toolCall],
                description: """
                    Press one menu item by name, as the menu bar shows it: \"File › Export › PDF…\". Levels can be separated by ›, >, or /. \
                    This runs the app's own menu handler — the same thing that happens when a person picks it — so it can save, close, quit, or \
                    delete depending on what you name. A known path needs no `menu` read first, since the press reads the menu bar itself: \
                    an unknown path refuses and lists what is actually there, an ambiguous one refuses and names the candidates, and a disabled \
                    item refuses; use the cause and supplied remedy. Returns the screen after the press, so you see whether the intended thing \
                    happened. Needs active Full Mac Accessibility app control; there is no per-call approval.
                    """
            ),
            ActionDescriptor(MacClipboardWriteArgs.self,
                name: "clipboard_write",
                availability: .accessibility, run: MacClipboardWriteArgs.control,
                toolClass: .write, reach: .person, capabilities: [.clipboardWrite, .toolCall],
                description: """
                    Put text on this Mac's clipboard, replacing whatever was there. The next paste (⌘V) in any app will produce this text, and \
                    what was on the clipboard before is gone. It types nothing and clicks nothing by itself — to get the text into a document, \
                    paste it afterwards. Bounded at 100000 characters. The result reports how many characters were written and whether reading \
                    the clipboard back matched; the text itself is never echoed. Needs active Full Mac Accessibility app control; there is no \
                    per-call approval.
                    """
            ),
            ActionDescriptor(MacGoArgs.self,
                name: "go",
                availability: .accessibility, courier: .go, run: MacGoArgs.verbs,
                toolClass: .write, reach: .person, capabilities: [.macControl, .toolCall],
                description: """
                    Get to an app, file, folder, http/https URL, or System Settings pane link \
                    (x-apple.systempreferences:com.apple.wifi-settings-extension) through the canonical Mac-control owner, then read the fresh \
                    screen. Without front it opens or launches behind, activating nothing, and reads that app's window; act with app works \
                    there. While Shotgun is up it always goes in front. With front:true, only when the task explicitly asks to bring it \
                    forward, it switches the screen and activation is independently verified. File/URL opening is reported only as an accepted \
                    request unless the screen proves where it landed. Needs active Full Mac Accessibility app control; there is no per-call \
                    approval.
                    """
            ),
        ])
        return schemas
    }()
}

private protocol MacWireArgs: DoorArgs {
    var wire: [String: JSONValue] { get }
}

private extension MacWireArgs {
    static func local(_ context: ActionContext, _ args: Self) async throws -> JSONValue {
        let input = args.wire.merging(context.transportMetadata) { argument, _ in argument }
        return try await context.client.impl_local_connector_tool(turn: context.turn, invocation: context.invocation,
            tool: context.tool, input: input, surface: context.surface)
    }

    static func control(_ context: ActionContext, _ args: Self) async throws -> JSONValue {
        let input = args.wire.merging(context.transportMetadata) { argument, _ in argument }
        return try await context.client.impl_mac_control_tool(turn: context.turn, invocation: context.invocation,
            tool: context.tool, input: input, surface: context.surface)
    }

    static func verbs(_ context: ActionContext, _ args: Self) async throws -> JSONValue {
        let input = args.wire.merging(context.transportMetadata) { argument, _ in argument }
        return try await context.client.impl_mac_four_verbs_tool(turn: context.turn, invocation: context.invocation,
            tool: context.tool, input: input, surface: context.surface)
    }
}

struct MacScreenshotSaveArgs: DoorArgs {
    static let pathField = DoorFieldDescriptor.string("path", """
        PNG destination path; defaults to Desktop/Screenshot with the local date and time. Additional displays get numbered PNG \
        paths.
        """)
    static let windowIdField = DoorFieldDescriptor.int("window_id", "Exact visible window number; cannot combine with app or region.", minimum: 1)
    static let appField = DoorFieldDescriptor.string("app", "Exact running app name; captures its front visible window without activating it.")
    static let regionField = DoorFieldDescriptor.string("region", "x,y,width,height in screen points; cannot combine with app or window_id.")
    static let doorFields: [DoorFieldDescriptor] = [pathField, windowIdField, appField, regionField]

    let path: String?
    let windowId: DoorNumberLiteral?
    let app: String?
    let region: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        path = try door.string(Self.pathField)
        windowId = try door.numberLiteral(Self.windowIdField)
        app = try door.string(Self.appField)
        region = try door.string(Self.regionField)
    }
}

private struct MacFileExcerptArgs: MacWireArgs {
    static let pathField = DoorFieldDescriptor.string("path", "Absolute path or path relative to the NativeAgent repo root.", required: true)
    static let queryField = DoorFieldDescriptor.string("query", """
        Every whitespace-separated term must occur on a line, case-insensitively; empty reads consecutive lines. Search \
        pages fit 24000 serialized bytes; a larger single record is refused, never split.
        """)
    static let versionField = DoorFieldDescriptor.string("version", """
        Copy next unchanged for continuation. file_changed means restart at start_line 1 without version.
        """)
    static let startLineField = DoorFieldDescriptor.int("start_line", "1-based start line, default 1.")
    static let maxLinesField = DoorFieldDescriptor.int("max_lines", """
        Maximum lines, default 80, capped at 240. Requested text is capped at 1 MiB; for a larger window narrow this value, \
        or use files.read byte windows for very long lines.
        """)
    static let doorFields: [DoorFieldDescriptor] = [pathField, queryField, versionField, startLineField, maxLinesField]

    let path: String
    let query: String?
    let version: String?
    let startLine: DoorNumberLiteral?
    let maxLines: DoorNumberLiteral?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        path = try door.requiredString(Self.pathField)
        query = try door.string(Self.queryField)
        version = try door.string(Self.versionField)
        startLine = try door.numberLiteral(Self.startLineField)
        maxLines = try door.numberLiteral(Self.maxLinesField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.pathField.name] = JSONValue.string(path)
        fields[Self.queryField.name] = query.map(JSONValue.string)
        fields[Self.versionField.name] = version.map(JSONValue.string)
        fields[Self.startLineField.name] = startLine?.wire
        fields[Self.maxLinesField.name] = maxLines?.wire
        return fields
    }
}

private struct MacGrepArgs: MacWireArgs {
    static let patternField = DoorFieldDescriptor.string("pattern", """
        POSIX extended regular expression, matched byte-wise by macOS grep (C locale). Recursive searches skip .git, \
        .build, DerivedData*, node_modules and supported repository-root .gitignore basename globs; path-specific and \
        nested rules are not applied. Other hidden text files remain searchable. Binary files and recursive symlinks are \
        skipped. Unreadable children and undecodable matched lines appear as named gaps; readable siblings remain. A \
        30-second deadline returns partial coverage, even with no matches.
        """, required: true)
    static let pathField = DoorFieldDescriptor.string("path", """
        Directory or file to search. Defaults to a verified NativeAgent source checkout when present, otherwise the \
        canonical NativeAgent workspace.
        """)
    static let maxResultsField = DoorFieldDescriptor.int("max_results", """
        Maximum selected result lines, default/cap 50. Inspect coverage: a reached limit is not a total count. Narrow \
        path/pattern to recover omitted matches; output is bounded to 30000 characters and engine capture to 1 MiB.
        """)
    static let doorFields: [DoorFieldDescriptor] = [patternField, pathField, maxResultsField]

    let pattern: String
    let path: String?
    let maxResults: DoorNumberLiteral?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        pattern = try door.requiredString(Self.patternField)
        path = try door.string(Self.pathField)
        maxResults = try door.numberLiteral(Self.maxResultsField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.patternField.name] = JSONValue.string(pattern)
        fields[Self.pathField.name] = path.map(JSONValue.string)
        fields[Self.maxResultsField.name] = maxResults?.wire
        return fields
    }
}

private struct MacGitStatusArgs: MacWireArgs {
    static let cwdField = DoorFieldDescriptor.string("cwd", """
        Repository directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical \
        NativeAgent workspace.
        """)
    static let doorFields: [DoorFieldDescriptor] = [cwdField]

    let cwd: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        cwd = try door.string(Self.cwdField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.cwdField.name] = cwd.map(JSONValue.string)
        return fields
    }
}

private struct MacGitDiffArgs: MacWireArgs {
    static let cwdField = DoorFieldDescriptor.string("cwd", """
        Repository directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical \
        NativeAgent workspace.
        """)
    static let stagedField = DoorFieldDescriptor.bool("staged", "Use --staged.")
    static let sinceField = DoorFieldDescriptor.string("since", """
        Optional committed history boundary: today means local midnight; otherwise a Git date. Cannot combine with staged.
        """)
    static let pathField = DoorFieldDescriptor.string("path", "Optional path filter.")
    static let doorFields: [DoorFieldDescriptor] = [cwdField, stagedField, sinceField, pathField]

    let cwd: String?
    let staged: Bool?
    let since: String?
    let path: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        cwd = try door.string(Self.cwdField)
        staged = try door.bool(Self.stagedField)
        since = try door.string(Self.sinceField)
        path = try door.string(Self.pathField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.cwdField.name] = cwd.map(JSONValue.string)
        fields[Self.stagedField.name] = staged.map(JSONValue.bool)
        fields[Self.sinceField.name] = since.map(JSONValue.string)
        fields[Self.pathField.name] = path.map(JSONValue.string)
        return fields
    }
}

private struct MacGitLogArgs: MacWireArgs {
    static let cwdField = DoorFieldDescriptor.string("cwd", """
        Repository directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical \
        NativeAgent workspace.
        """)
    static let limitField = DoorFieldDescriptor.int("limit", "Commit count, default 10, capped at 100.")
    static let sinceField = DoorFieldDescriptor.string("since", "Optional history boundary: today means local midnight; otherwise a Git date.")
    static let pathField = DoorFieldDescriptor.string("path", "Optional path filter.")
    static let doorFields: [DoorFieldDescriptor] = [cwdField, limitField, sinceField, pathField]

    let cwd: String?
    let limit: DoorNumberLiteral?
    let since: String?
    let path: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        cwd = try door.string(Self.cwdField)
        limit = try door.numberLiteral(Self.limitField)
        since = try door.string(Self.sinceField)
        path = try door.string(Self.pathField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.cwdField.name] = cwd.map(JSONValue.string)
        fields[Self.limitField.name] = limit?.wire
        fields[Self.sinceField.name] = since.map(JSONValue.string)
        fields[Self.pathField.name] = path.map(JSONValue.string)
        return fields
    }
}

private struct MacRepoDirtySummaryArgs: MacWireArgs {
    static let cwdField = DoorFieldDescriptor.string("cwd", """
        Repository directory. Defaults to a verified NativeAgent source checkout when present, otherwise the canonical \
        NativeAgent workspace.
        """)
    static let logLimitField = DoorFieldDescriptor.int("log_limit", "Recent commit count, default 5, capped at 20.")
    static let doorFields: [DoorFieldDescriptor] = [cwdField, logLimitField]

    let cwd: String?
    let logLimit: DoorNumberLiteral?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        cwd = try door.string(Self.cwdField)
        logLimit = try door.numberLiteral(Self.logLimitField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.cwdField.name] = cwd.map(JSONValue.string)
        fields[Self.logLimitField.name] = logLimit?.wire
        return fields
    }
}

struct MacApplyPatchArgs: DoorArgs {
    static let patchField = DoorFieldDescriptor.string("patch", "Required. The unified diff text. Will be written to a tmpfile before git apply.", required: true)
    static let cwdField = DoorFieldDescriptor.string("cwd", """
        Optional existing working directory. Relative paths resolve in the canonical NativeAgent workspace/source checkout. \
        Active Full Mac may select an ordinary absolute external project; sensitive authority and protected system paths \
        remain denied.
        """)
    static let threeWayField = DoorFieldDescriptor("three_way", ToolSchema.nullable(ToolSchema.boolSchema("""
        Optional. Default true; passes --3way only inside a Git repository. Outside a repository, uses plain apply. Set \
        false for strict apply that fails fast on context mismatch.
        """)), required: false)
    static let doorFields: [DoorFieldDescriptor] = [patchField, cwdField, threeWayField]

    let patch: String
    let cwd: String?
    let threeWay: Bool?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        patch = try door.requiredString(Self.patchField)
        cwd = try door.string(Self.cwdField)
        threeWay = try door.bool(Self.threeWayField)
    }
}

struct MacInstallAppArgs: DoorArgs {
    static let reasonField = DoorFieldDescriptor.string("reason", "Required. Why the install/rebuild is needed; lands in the audit envelope.", required: true)
    static let startDelaySecondsField = DoorFieldDescriptor.int("start_delay_seconds", """
        Optional. Delay before launching install_app.sh so the final chat reply can persist. Defaults to app.restart's \
        grace window; clamped 5...120.
        """)
    static let doorFields: [DoorFieldDescriptor] = [reasonField, startDelaySecondsField]

    let reason: String
    let startDelaySeconds: DoorNumberLiteral?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        reason = try door.requiredString(Self.reasonField)
        startDelaySeconds = try door.numberLiteral(Self.startDelaySecondsField)
    }
}

private struct MacRestartAppArgs: DoorArgs {
    static let reasonField = DoorFieldDescriptor.string("reason", """
        Required. Why the restart is needed (lands in the audit envelope at data/restart_audit/<uuid>.json).
        """, required: true)
    static let doorFields: [DoorFieldDescriptor] = [reasonField]

    let reason: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        reason = try door.requiredString(Self.reasonField)
    }
}

private struct MacMediaArgs: MacWireArgs {
    static let actionField = DoorFieldDescriptor("action", ToolSchema.obj([("type", .string("string")),
        ("enum", .array(["play", "resume", "pause", "toggle", "next", "skip", "previous"].map(JSONValue.string))),
        ("description", .string("""
            toggle sends the play-pause key; next / skip send next; previous sends previous. play / resume / pause refuse rather \
            than toggle an unknown playback state.
            """))]), required: true)
    static let doorFields: [DoorFieldDescriptor] = [actionField]

    let action: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        action = try door.requiredString(Self.actionField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.actionField.name] = JSONValue.string(action)
        return fields
    }
}

private struct MacVolumeArgs: MacWireArgs {
    static let levelField = DoorFieldDescriptor.int("level", "Output volume percent (0–100); cannot combine with adjust.", minimum: 0, maximum: 100)
    static let adjustField = DoorFieldDescriptor.int("adjust", "Signed percentage points (−100–100), e.g. −10 to turn it down.", minimum: -100, maximum: 100)
    static let mutedField = DoorFieldDescriptor.bool("muted", "true to mute, false to unmute; omit to preserve mute state.")
    static let doorFields: [DoorFieldDescriptor] = [levelField, adjustField, mutedField]

    let level: DoorNumberLiteral?
    let adjust: DoorNumberLiteral?
    let muted: Bool?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        level = try door.numberLiteral(Self.levelField)
        adjust = try door.numberLiteral(Self.adjustField)
        muted = try door.bool(Self.mutedField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.levelField.name] = level?.wire
        fields[Self.adjustField.name] = adjust?.wire
        fields[Self.mutedField.name] = muted.map(JSONValue.bool)
        return fields
    }
}

private struct MacSystemInfoArgs: MacWireArgs {
    static let checkUpdatesField = DoorFieldDescriptor.bool("check_updates", "List macOS software updates instead of system information; never installs anything.")
    static let appField = DoorFieldDescriptor.string("app", """
        Exact installed app name or full .app path; read CFBundleShortVersionString and build directly without launching it.
        """)
    static let speedTestField = DoorFieldDescriptor.bool("speed_test", """
        Only on request: measure internet upload/download and responsiveness for at most 20 seconds; uses bandwidth. Omit for \
        an ordinary system read.
        """)
    static let personField = DoorFieldDescriptor.bool("person", """
        Only read whether the person is here and how long since their own input; instant, nothing else is read.
        """)
    static let doorFields: [DoorFieldDescriptor] = [checkUpdatesField, appField, speedTestField, personField]

    let checkUpdates: Bool?
    let app: String?
    let speedTest: Bool?
    let person: Bool?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        checkUpdates = try door.bool(Self.checkUpdatesField)
        app = try door.string(Self.appField)
        speedTest = try door.bool(Self.speedTestField)
        person = try door.bool(Self.personField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.checkUpdatesField.name] = checkUpdates.map(JSONValue.bool)
        fields[Self.appField.name] = app.map(JSONValue.string)
        fields[Self.speedTestField.name] = speedTest.map(JSONValue.bool)
        fields[Self.personField.name] = person.map(JSONValue.bool)
        return fields
    }
}

private struct MacClipboardReadArgs: MacWireArgs {
    static let maxCharsField = DoorFieldDescriptor.int("max_chars", """
        Maximum characters of clipboard text to return. Default 8000, clamped to 0-32000. Use 0 for types and original text \
        length only, with no text or redaction details returned; otherwise chars is the redacted text length. The result \
        says whether it cut.
        """)
    static let doorFields: [DoorFieldDescriptor] = [maxCharsField]

    let maxChars: DoorNumberLiteral?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        maxChars = try door.numberLiteral(Self.maxCharsField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.maxCharsField.name] = maxChars?.wire
        return fields
    }
}

private struct MacMenuArgs: MacWireArgs {
    static let appField = DoorFieldDescriptor.string("app", """
        Optional: read this running app's menu bar instead of the frontmost app's, without activating it. Defaults to \
        whatever is in front.
        """)
    static let findField = DoorFieldDescriptor.string("find", """
        Optional: words or a path (\"Import Timeline\", \"File › Import › Timeline…\"). Answers the paths holding every \
        word instead of the whole bar, and `found`: up to three items with exactly that name or path, each with its \
        shortcut.
        """)
    static let doorFields: [DoorFieldDescriptor] = [appField, findField]

    let app: String?
    let find: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        app = try door.string(Self.appField)
        find = try door.string(Self.findField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.appField.name] = app.map(JSONValue.string)
        fields[Self.findField.name] = find.map(JSONValue.string)
        return fields
    }
}

private struct MacReadArgs: MacWireArgs {
    static let pathField = DoorFieldDescriptor.string("path", """
        Optional: read this file instead of the screen — an absolute path to a PDF or a plain-text file. Omit it to read \
        the live window’s text, including unsaved edits.
        """)
    static let appField = DoorFieldDescriptor.string("app", """
        Read this running app’s window without activating, raising or launching it, e.g. Preview. Missing/ambiguous app: \
        use the failure’s cause and remedy. Ignored with path, which reads the file.
        """)
    static let doorFields: [DoorFieldDescriptor] = [pathField, appField] + ToolSchema.senseViewProperties.map { DoorFieldDescriptor($0.0, $0.1, required: false) }

    let path: String?
    let app: String?
    let raw: Bool?
    let wrong: Bool?
    let why: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        path = try door.string(Self.pathField)
        app = try door.string(Self.appField)
        raw = try door.bool(door.declaredField("raw"))
        wrong = try door.bool(door.declaredField("wrong"))
        why = try door.string(door.declaredField("why"))
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.pathField.name] = path.map(JSONValue.string)
        fields[Self.appField.name] = app.map(JSONValue.string)
        fields["raw"] = raw.map(JSONValue.bool)
        fields["wrong"] = wrong.map(JSONValue.bool)
        fields["why"] = why.map(JSONValue.string)
        return fields
    }
}

private struct MacScreenArgs: MacWireArgs {
    static let pixelsField = DoorFieldDescriptor.bool("pixels", """
        Set true for actual primary-desktop pixels to verify visual outcomes, including overlapping windows and Liquid \
        Glass. Secret fields are masked; a window that cannot be fully inspected through Accessibility, including \
        NativeAgent's own, is masked in full. Requires existing Full Mac read authority and Screen Recording permission. No \
        focus change or permission prompt. With app or part it instead attaches that window's or region's image even when \
        its accessibility is rich. Image is transient and bounded so you see it at the receipt's own size (short side ≤ 768 \
        px); capture success is not action verification. Default false keeps the structured screen read.
        """)
    static let structuredField = DoorFieldDescriptor.bool("structured", """
        Include bounded, already-redacted controls for workspace selections in detail.controls. Each control's handle is \
        bound to that result's frame_id; return both to act for an exact selection. Default false keeps the concise natural \
        screen.
        """)
    static let senseScreenFrameField = DoorFieldDescriptor.string("__sense_screen_frame", """
        The frozen screen identity from More. To continue that page with its original handles, use the result's \
        Continue line: app {page, item} with the More object as item.
        """)
    static let senseTextOffsetField = DoorFieldDescriptor.int("__sense_text_offset", """
        The reading position from More; pass it unchanged with __sense_screen_frame and app.
        """)
    static let partField = DoorFieldDescriptor.string("part", """
        Optional: a section, thing, or status readout to inspect by name. Use hud/readouts for observed status values, or a \
        label such as Last drag or Energy to reveal a readout hidden by the ordinary display cap.
        """)
    static let appField = DoorFieldDescriptor.string("app", """
        Optional: observe this app instead of whatever is in front, without activating it (\"Mail\", \"Safari\"). A stopped \
        app is a successful running:false observation; a running app with no readable window reports running:true, \
        windows:0. An ambiguous name still requires clarification.
        """)
    static let doorFields: [DoorFieldDescriptor] = [pixelsField, structuredField, senseScreenFrameField, senseTextOffsetField, partField, appField] + ToolSchema.senseViewProperties.map { DoorFieldDescriptor($0.0, $0.1, required: false) }

    let pixels: Bool?
    let structured: Bool?
    let senseScreenFrame: String?
    let senseTextOffset: DoorNumberLiteral?
    let part: String?
    let app: String?
    let raw: Bool?
    let wrong: Bool?
    let why: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        pixels = try door.bool(Self.pixelsField)
        structured = try door.bool(Self.structuredField)
        senseScreenFrame = try door.string(Self.senseScreenFrameField)
        senseTextOffset = try door.numberLiteral(Self.senseTextOffsetField)
        part = try door.string(Self.partField)
        app = try door.string(Self.appField)
        raw = try door.bool(door.declaredField("raw"))
        wrong = try door.bool(door.declaredField("wrong"))
        why = try door.string(door.declaredField("why"))
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.pixelsField.name] = pixels.map(JSONValue.bool)
        fields[Self.structuredField.name] = structured.map(JSONValue.bool)
        fields[Self.senseScreenFrameField.name] = senseScreenFrame.map(JSONValue.string)
        fields[Self.senseTextOffsetField.name] = senseTextOffset?.wire
        fields[Self.partField.name] = part.map(JSONValue.string)
        fields[Self.appField.name] = app.map(JSONValue.string)
        fields["raw"] = raw.map(JSONValue.bool)
        fields["wrong"] = wrong.map(JSONValue.bool)
        fields["why"] = why.map(JSONValue.string)
        return fields
    }
}

private struct MacWaitArgs: MacWireArgs {
    static let untilField = DoorFieldDescriptor.string("until", "Optional: return as soon as this text appears on screen (case-insensitive).")
    static let secondsField = DoorFieldDescriptor.int("seconds", "Optional: how long to watch. Default 10, max 60 (with agent: default 60, max 300).")
    static let agentField = DoorFieldDescriptor.string("agent", """
        Optional: a contact's name (as app agent.message takes it). Wait for its reply instead of watching the screen.
        """)
    static let conversationField = DoorFieldDescriptor.string("conversation", "Optional, with agent: the conversation name; omit for its current one.")
    static let doorFields: [DoorFieldDescriptor] = [untilField, secondsField, agentField, conversationField]

    let until: String?
    let seconds: DoorNumberLiteral?
    let agent: String?
    let conversation: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        until = try door.string(Self.untilField)
        seconds = try door.numberLiteral(Self.secondsField)
        agent = try door.string(Self.agentField)
        conversation = try door.string(Self.conversationField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.untilField.name] = until.map(JSONValue.string)
        fields[Self.secondsField.name] = seconds?.wire
        fields[Self.agentField.name] = agent.map(JSONValue.string)
        fields[Self.conversationField.name] = conversation.map(JSONValue.string)
        return fields
    }
}

private struct MacActivityQueryArgs: MacWireArgs {
    static let rangeField = DoorFieldDescriptor.choice("range", ["today", "yesterday", "last_hour", "last_24_hours", "last_7_days", "last_30_days",
        "past_hour", "past_24_hours", "past_week", "this_week", "past_month"], """
        Named range: today, yesterday, last_hour, last_24_hours, last_7_days, last_30_days. Defaults to today. Ignored when \
        `from` is given.
        """)
    static let fromField = DoorFieldDescriptor.string("from", """
        Explicit range start: epoch seconds, an ISO-8601 instant, or YYYY-MM-DD (midnight in the asking timezone).
        """)
    static let toField = DoorFieldDescriptor.string("to", "Explicit range end, same formats as `from`. Defaults to now.")
    static let bundleIdField = DoorFieldDescriptor.string("bundle_id", "Restrict the answer to one app's bundle identifier, e.g. com.apple.Safari.")
    static let timezoneField = DoorFieldDescriptor.string("timezone", """
        IANA timezone the day/hour buckets are computed in, e.g. Europe/London. Defaults to this Mac's current timezone.
        """)
    static let limitField = DoorFieldDescriptor.int("limit", "Maximum rows in the answer. Clamped to 50; the answer says what the cap removed.")
    static let doorFields: [DoorFieldDescriptor] = [rangeField, fromField, toField, bundleIdField, timezoneField, limitField]

    let range: String?
    let from: String?
    let to: String?
    let bundleId: String?
    let timezone: String?
    let limit: DoorNumberLiteral?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        range = try door.string(Self.rangeField)
        from = try door.string(Self.fromField)
        to = try door.string(Self.toField)
        bundleId = try door.string(Self.bundleIdField)
        timezone = try door.string(Self.timezoneField)
        limit = try door.numberLiteral(Self.limitField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.rangeField.name] = range.map(JSONValue.string)
        fields[Self.fromField.name] = from.map(JSONValue.string)
        fields[Self.toField.name] = to.map(JSONValue.string)
        fields[Self.bundleIdField.name] = bundleId.map(JSONValue.string)
        fields[Self.timezoneField.name] = timezone.map(JSONValue.string)
        fields[Self.limitField.name] = limit?.wire
        return fields
    }
}

private struct MacActArgs: MacWireArgs {
    private static let holdingSchema = ToolSchema.strSchema("""
        Optional keys/modifiers held around a physical action, such as `w d`, `shift`, or `cmd+w`. Works with pointer hold, including \
        right-button hold while movement keys are down. Not valid with a keyboard hold (put all keys in its target) or literal type.
        """)
    private static let buttonSchema = ToolSchema.enumStringSchema(["auto", "left", "right"], """
        Use auto for the ordinary/default action, including key, type, scroll, move, and hover. Use left or right only to request an \
        explicit mouse button on click, open (double-click), drag, or pointer hold. Right drag sends genuine right-button events, not \
        Control-left-drag. Omission is equivalent to auto.
        """)
    private static let point: [(String, JSONValue)] = [
        ("type", .string("object")),
        ("properties", ToolSchema.obj([("x", ActionDescriptor.numSchema("Image pixels from the left edge.")), ("y", ActionDescriptor.numSchema("Image pixels from the top edge."))])),
        ("required", .array([.string("x"), .string("y")])),
    ]
    private static let atSchema = ToolSchema.obj(point + [("description", .string("""
        Instead of a target: a point in pixels of an image a screen call handed you; click, type (click then type into the focused editor), \
        double_click, right_click, hover, move or hold lands there.
        """))])
    private static let fromSchema = ToolSchema.obj(point + [("description", .string("""
        For drag by point: where it starts, in pixels of the image; give `to` as a point too.
        """))])
    private static let imageSchema = ToolSchema.strSchema("""
        The screen observation's reference (frame_id and image.id are the same). With at/from: its delivered image's pixels. Omitted: the \
        latest screen image this session was handed. Moved, resized, replaced or covered windows, changed controls, and missing \
        capture-time control identity refuse the old point; take a fresh image.
        """)
    private static let screenAddress = ToolSchema.obj([
        ("type", .string("object")),
        ("properties", ToolSchema.obj([
            ("handle", ToolSchema.strSchema()), ("frame_id", ToolSchema.strSchema()),
            ("app", ToolSchema.strSchema()), ("target", ToolSchema.strSchema()),
            ("__sense_screen_frame", ToolSchema.strSchema()), ("label", ToolSchema.strSchema()),
        ])),
        ("anyOf", .array([
            ToolSchema.obj([("required", .array([.string("handle"), .string("frame_id")]))]),
            ToolSchema.obj([("required", .array([.string("app"), .string("target"), .string("__sense_screen_frame")]))]),
        ])),
    ])
    private static let scrollDirections = MacActScrollDirection.allCases.map(\.rawValue)
    static let verbField = DoorFieldDescriptor.choice("verb", MacFourVerbs.actionVerbs, """
        What to do. focus sets accessibility focus on a control that offers it. press = key for a key/chord (cmd+s, \
        return), click for a named control. double_click and right_click are the real mouse gestures.
        """)
    static let targetField = DoorFieldDescriptor("target", ToolSchema.obj([
            ("anyOf", .array([ToolSchema.strSchema(), screenAddress])),
            ("description", .string("""
                Omit for scroll of main content or replace-mode type into editable focus. Otherwise the name as the screen \
                shows it, or the complete target object returned by that screen (handle/frame_id or a native-surface address). \
                For hold, `key w d` holds W and D simultaneously for seconds. For key, a space-separated sequence remains \
                sequential and `key:36` uses physical key code 36.
                """)),
        ]), required: false)
    static let handleField = DoorFieldDescriptor.string("handle", "Exact control from screen structured:true, with its frame_id. Supports "
        + MacFourVerbs.selectionVerbs.joined(separator: ", ") + """
         on that same live element (press aliases click). Only scroll accepts direction and scroll_amount. A handle \
        takes no point, drag, button, holding or repeat options. A stale handle requires a fresh screen read.
        """)
    static let frameIdField = DoorFieldDescriptor.string("frame_id", """
        The screen observation's reference, shared by handles and image pixels; image is an alias. Required with handle. \
        Old handles are refused; read the screen again to get current choices.
        """)
    static let textField = DoorFieldDescriptor.string("text", "For `type`: the literal text. Append adds exactly this text; include a newline when needed.")
    static let modeField = DoorFieldDescriptor.choice("mode", ["replace", "append"], """
        For named `type`: replace (default) keeps form-fill behavior and may replace the whole value; append inserts at the \
        verified end, preserves prior text, and never sets the whole value. Append requires a named accessibility text \
        target and verified contents/end; otherwise it refuses. Omit or use replace for other verbs.
        """)
    static let directionField = DoorFieldDescriptor.choice("direction", scrollDirections,
        "For `scroll`: which way to move. Left/right sends horizontal wheel input.")
    static let scrollAmountField = DoorFieldDescriptor.int("scroll_amount", """
        For scroll: wheel magnitude from 1 to 120 lines. Omit or use 0 for the default, three lines for a handle. \
        Other handle verbs require omission. A positive amount requests wheel input.
        """, minimum: 0, maximum: 120)
    static let toField = DoorFieldDescriptor("to", ToolSchema.obj([("anyOf", .array([ToolSchema.strSchema(), ToolSchema.obj(point)])), ("description", .string("""
        For `drag`: the named/numbered destination. A displayed canvas is also a target: drag from 'left side of canvas' to \
        'right side of canvas', or use top/bottom corners. Move, hover, pointer hold and scroll also accept canvas; fresh \
        geometry and obstruction checks stay automatic. With `from`, a point {x, y} in the same image's pixels.
        """))]), required: false)
    static let atField = DoorFieldDescriptor("at", atSchema, required: false)
    static let fromField = DoorFieldDescriptor("from", fromSchema, required: false)
    static let imageField = DoorFieldDescriptor("image", imageSchema, required: false)
    static let toAppField = DoorFieldDescriptor.string("to_app", """
        Drag destination in another running app, e.g. Mail. Resolves to without activation; if the drop needs the front, \
        stops with needs_front unless the task explicitly requests front:true. Reports any focus move and cause. \
        Missing/ambiguous app or target, source obstruction, or crossing a password field stops the drag: follow the \
        failure’s cause and remedy. holding:option/cmd selects the app’s copy/move variant. For text, prefer \
        mac.clipboard_write and paste.
        """)
    static let againField = DoorFieldDescriptor.bool("again", "Run every step again, even ones a stopped batch already landed.")
    static let stepsField = DoorFieldDescriptor("steps", ToolSchema.obj([
            ("type", .string("array")),
            ("maxItems", .int(12)),
            ("description", .string("""
                Optional: up to 12 acts in ONE call, in order — [\"AC\",\"9\",\"×\",\"8\",\"=\"] (a string presses/clicks that \
                name, a menu path like 'File > Save', or a key/chord) or {verb, target, text, mode}, or {verb,handle,frame_id}. \
                A handle records control identity; each step resolves it live in its recorded window and stops if it cannot be \
                confirmed. frame_id may be inherited from the call. Each step reads the window fresh and is verified; it stops \
                at the first failure and says which step. With steps, verb/target/mode are ignored at the top level; each step \
                chooses its own mode (replace by default), and app/front apply to all.
                """)),
            ("items", ToolSchema.obj([("anyOf", .array([
                ToolSchema.obj([("type", .string("string"))]),
                ToolSchema.obj([
                    ("type", .string("object")),
                    ("properties", ToolSchema.obj([
                        ("verb",
                            ToolSchema.strSchema(MacFourVerbs.actionVerbs.joined(separator: ", ")
                            + ". The same verbs and synonyms as a single act.")),
                        ("handle", ToolSchema.strSchema("""
                            Control identity from structured screen, with frame_id here or inherited from the call. Supports \
                            the same handle verbs as a single act. Only scroll takes direction (or to) and scroll_amount. \
                            A handle step takes no named target, point, holding or button options.
                            """)),
                        ("target", ToolSchema.strSchema("""
                            The name, as the screen shows it. Required for append; omit for scroll of the main content, \
                            replace-mode type into editable focus, a handle selection, or when at/from gives a point.
                            """)),
                        ("to", ToolSchema.obj([("anyOf", .array([ToolSchema.strSchema(), ToolSchema.obj(point)])), ("description",
                            .string("For drag: the named destination, or with `from` a point {x, y} in image pixels. For a handle scroll: an alias for direction."))])),
                        ("direction", ToolSchema.enumStringSchema(scrollDirections,
                            "For a named, handle or targetless scroll: which way to move. Defaults to down.")),
                        ("scroll_amount", ToolSchema.intSchema(
                            "For a named, handle or targetless scroll: wheel magnitude in lines. Omit or use 0 for the default.",
                            minimum: 0, maximum: 120)),
                        ("at", atSchema),
                        ("from", fromSchema),
                        ("image", imageSchema),
                        ("frame_id", imageSchema),
                        ("holding", holdingSchema),
                        ("button", buttonSchema),
                        ("text", ToolSchema.strSchema("For type: the literal text; include a newline when append should add a line.")),
                        ("mode", ToolSchema.enumStringSchema(["replace", "append"], """
                            For named type: replace (default) keeps form-fill behavior; append preserves prior text and inserts \
                            at its verified end. Append requires a named accessibility text target; it never replaces the whole \
                            value. Omit or use replace for other verbs.
                            """)),
                    ])),
                    ("required", .array([.string("verb")])),
                ]),
            ]))])),
        ]), required: false)
    static let appField = DoorFieldDescriptor.string("app", """
        Optional: act in this running app's window (\"TextEdit\", \"Mail\") without bringing it forward. Works for \
        accessibility clicks, typing, select, toggle and open; effects that need the screen stop with needs_front and say \
        why.
        """)
    static let frontField = DoorFieldDescriptor.bool("front", """
        Only when explicitly requested by the task. With app: bring that app forward for this act (menus, keys), then request \
        restoration of the previous front app. Not needed when the app is already in front or Shotgun is up. A name it lacks raises \
        nothing. front_seconds is the rounded time from requesting the foreground to requesting restoration, not time observed in front.
        """)
    static let secondsField = DoorFieldDescriptor.number("seconds", """
        For hover or hold: duration up to 10 seconds. For drag: paced travel duration, bounded 0.08–2 seconds; 0 or \
        omission uses 0.24 seconds. Drag duration controls movement, not two endpoint pauses.
        """, minimum: 0, maximum: 10)
    static let repeatCountField = DoorFieldDescriptor.int("repeat", """
        Optional bounded burst count. The target is freshly re-resolved before every attempt; planning and real elapsed \
        execution are capped at 30 seconds.
        """, minimum: 1, maximum: 12)
    static let intervalField = DoorFieldDescriptor.number("interval", "Optional pause between repeated attempts.", minimum: 0, maximum: 2)
    static let holdingField = DoorFieldDescriptor("holding", holdingSchema, required: false)
    static let buttonField = DoorFieldDescriptor("button", buttonSchema, required: false)
    static let doorFields: [DoorFieldDescriptor] = [verbField, targetField, handleField, frameIdField, textField, modeField, directionField, scrollAmountField, toField, atField, fromField, imageField, toAppField, againField, stepsField, appField, frontField, secondsField, repeatCountField, intervalField, holdingField, buttonField]

    let verb: String?
    let target: JSONValue?
    let handle: String?
    let frameId: String?
    let text: String?
    let mode: String?
    let direction: String?
    let scrollAmount: DoorNumberLiteral?
    let to: JSONValue?
    let at: JSONValue?
    let from: JSONValue?
    let image: String?
    let toApp: String?
    let again: Bool?
    let steps: JSONValue?
    let app: String?
    let front: Bool?
    let seconds: DoorNumberLiteral?
    let repeatCount: DoorNumberLiteral?
    let interval: DoorNumberLiteral?
    let holding: String?
    let button: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        verb = try door.string(Self.verbField)
        target = try door.value(Self.targetField)
        handle = try door.string(Self.handleField)
        frameId = try door.string(Self.frameIdField)
        text = try door.string(Self.textField)
        mode = try door.string(Self.modeField)
        direction = try door.string(Self.directionField)
        scrollAmount = try door.numberLiteral(Self.scrollAmountField)
        to = try door.value(Self.toField)
        at = try door.value(Self.atField)
        from = try door.value(Self.fromField)
        image = try door.string(Self.imageField)
        toApp = try door.string(Self.toAppField)
        again = try door.bool(Self.againField)
        steps = try door.value(Self.stepsField)
        app = try door.string(Self.appField)
        front = try door.bool(Self.frontField)
        seconds = try door.numberLiteral(Self.secondsField)
        repeatCount = try door.numberLiteral(Self.repeatCountField)
        interval = try door.numberLiteral(Self.intervalField)
        holding = try door.string(Self.holdingField)
        button = try door.string(Self.buttonField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.verbField.name] = verb.map(JSONValue.string)
        fields[Self.targetField.name] = target
        fields[Self.handleField.name] = handle.map(JSONValue.string)
        fields[Self.frameIdField.name] = frameId.map(JSONValue.string)
        fields[Self.textField.name] = text.map(JSONValue.string)
        fields[Self.modeField.name] = mode.map(JSONValue.string)
        fields[Self.directionField.name] = direction.map(JSONValue.string)
        fields[Self.scrollAmountField.name] = scrollAmount?.wire
        fields[Self.toField.name] = to
        fields[Self.atField.name] = at
        fields[Self.fromField.name] = from
        fields[Self.imageField.name] = image.map(JSONValue.string)
        fields[Self.toAppField.name] = toApp.map(JSONValue.string)
        fields[Self.againField.name] = again.map(JSONValue.bool)
        fields[Self.stepsField.name] = steps
        fields[Self.appField.name] = app.map(JSONValue.string)
        fields[Self.frontField.name] = front.map(JSONValue.bool)
        fields[Self.secondsField.name] = seconds?.wire
        fields[Self.repeatCountField.name] = repeatCount?.wire
        fields[Self.intervalField.name] = interval?.wire
        fields[Self.holdingField.name] = holding.map(JSONValue.string)
        fields[Self.buttonField.name] = button.map(JSONValue.string)
        return fields
    }
}

private struct MacMenuPressArgs: MacWireArgs {
    static let pathField = DoorFieldDescriptor("path", ToolSchema.obj([
            ("description", .string("""
                The menu path to press: one string, e.g. \"File › Export › PDF…\" or \"Edit > Find > Find Next\", or the levels \
                as a list of titles [\"File\", \"Export\", \"PDF…\"] (one press, not one per entry).
                """)),
            ("anyOf", .array([
                ToolSchema.obj([("type", .string("string"))]),
                ToolSchema.obj([("type", .string("array")), ("items", ToolSchema.obj([("type", .string("string"))])), ("minItems",
                    .int(1))]),
            ])),
        ]), required: true)
    static let appField = DoorFieldDescriptor.string("app", """
        Optional: press in this running app's menu bar instead of the frontmost app's. Defaults to whatever is in front.
        """)
    static let doorFields: [DoorFieldDescriptor] = [pathField, appField]

    let path: DoorStringOrList
    let app: String?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        path = try door.stringOrList(Self.pathField)!
        app = try door.string(Self.appField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.pathField.name] = path.wire
        fields[Self.appField.name] = app.map(JSONValue.string)
        return fields
    }
}

private struct MacClipboardWriteArgs: MacWireArgs {
    static let textField = DoorFieldDescriptor.string("text", "The text to place on the clipboard.", required: true)
    static let doorFields: [DoorFieldDescriptor] = [textField]

    let text: String

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        text = try door.requiredString(Self.textField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.textField.name] = JSONValue.string(text)
        return fields
    }
}

private struct MacGoArgs: MacWireArgs {
    static let nameField = DoorFieldDescriptor.string("name", """
        An app name, a file/folder path (~ allowed), an http/https URL, or an x-apple.systempreferences: pane link.
        """, required: true)
    static let frontField = DoorFieldDescriptor.bool("front", """
        Only when the task explicitly asks to bring it forward: switch the screen to this destination. Defaults to false, \
        which opens it behind.
        """)
    static let doorFields: [DoorFieldDescriptor] = [nameField, frontField]

    let name: String
    let front: Bool?

    init(door: inout DoorObjectDecoder) throws(DoorDecodeError) {
        name = try door.requiredString(Self.nameField)
        front = try door.bool(Self.frontField)
    }

    var wire: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        fields[Self.nameField.name] = JSONValue.string(name)
        fields[Self.frontField.name] = front.map(JSONValue.bool)
        return fields
    }
}
