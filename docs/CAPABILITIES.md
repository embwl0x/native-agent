# NativeAgent capabilities

Provider model controls use the selected account's exact model descriptor.
Missing capability evidence leaves Think unavailable and preserves the saved
selection; it never borrows another model/provider or invents effort values.
Reload Providers repairs that source. Action discovery and policy admission
likewise require a checked complete catalog; an unreadable owner reports
unavailable rather than removing its actions from a successful inventory.

Capability inventory comes from current features, abilities, saved workflows
and connector actions. Retired pack records no longer appear as available or
installed capabilities. Catalog source and trust-root reads use only saved
typed records; they create no local pack source, root or signing key. Missing
lists have no saved rows; unreadable or malformed lists report their named
failure, preserving their bytes. Source saves take typed name, URL and kind
strings, update the same name-derived ID, and preserve existing creation and
trust metadata. A name whose retained first 120 characters cannot form an ASCII
letter/digit slug is refused before writing, with a correction instruction.
New sources acquire no synthetic pack trust root. Catalog privacy inventory
counts regular hidden files, including a retained `.pack_signing_key`; backup,
export and phone-sync exclusions are separate from that inventory. Retained
pack bytes are left untouched.

Ability admission uses `SwiftNativeManifestSigner` and its separate
`tools/.manifest_signing_key`. Its current signature version is the JSON integer
`2`; a string `"2"` is rejected before key access or verification. Verification
never creates missing signing authority.

Security effect profiling requires the addressed contact's readable transport
and host recipe. Unknown contact classification blocks admission, and advisory
risk reads say `unavailable`. Audit retention appends current receipts without
the completed pre-retention archival migration; existing archive files remain
untouched. Unrecognized call inputs are withheld by the generic redaction
boundary; the current folded `card.answer` executor keeps its typed value
protection without a retired-name table.

> One structure (docs/NORTHSTAR.md, first law): this doc is part of one whole. A change here is molded into every doc that states the same thing, in the same commit, with what comes out named; a contradiction is a defect.

A map of the current source. This is not a release receipt or an installed-app
check. For operation, read [User and Agent Guide](USER_GUIDE.md); for exact
file ownership, use [Architecture Blueprint](ARCHITECTURE_BLUEPRINT.md).

## The system in one sentence

One brain, many doors: NativeAgent is a Swift runtime hosted by the Mac app,
with shared conversation, memory, context, action and Trust across its surfaces.

## Native runtime

The core's `EngineRuntime` composes the system through `NativeAgentEngine`.
It owns the facades for turns, transcripts, memory, context, providers, Trust,
Desk, cognition, agents and device sync. `ChatTurnRuntime` owns turn execution;
`MacChatTurnRuntime` owns Mac-session admission, queues, cancellation and
lifecycle state. The SwiftUI app supplies platform wiring and presentation.

Source: [NativeAgentEngine.swift](../Modules/NativeAgentCore/Sources/EngineRuntime/NativeAgentEngine.swift),
[MacChatTurnRuntime.swift](../Modules/NativeAgentCore/Sources/ChatTurnRuntime/MacChatTurnRuntime.swift).

## Conversation surfaces

- **Mac:** streaming chat, sessions and queued follow-ups; Simple, Advanced
  and Agent views. Agent Home draws their shared face with row actions; the
  other Agent rooms remain read-only.
- **iPhone/iPad:** a companion using signed iCloud transport to the Mac.
  The Mac must remain awake with NativeAgent open to answer.
  Optional phone senses and their setup evidence share one bounded owner;
  `app {page:"pairing",item:"phone-senses"}` reads missing steps and the guide.
  [Phone senses and their limits](mobile_companion.md#where-the-person-is).
- **Telegram and Slack:** messaging surfaces with their own conversation
  origins and the shared engine's provider, context and action policy.
- **Local bridges and agent contacts:** authenticated conversations and coding
  handoffs. The bundled `nativeagent-link` helper and HTTP agent clients read
  the agent bridge's descriptor under `~/.config/nativeagent-link/` and send
  each contact's own credential; the older Claude/Codex lane keeps
  `~/.config/claude-bridge/bridge.json`.

`agent.message` can initiate an A2A conversation with `files: [{path}]`
(four regular files, 8 MiB total), through the normal send authority, attachment
fence and shared secret-content inspection. Other contact adapters refuse the
whole file send explicitly; see [outgoing files](agent-communication.md#outgoing-files)
for the transport table and inspection limits.

Connected-peer turns follow the
[Trust rules](#trust-security-and-receipts), including the
exemption for authenticated agents enabled in Trust.

See [Mobile companion](mobile_companion.md) and
[Agent conversations](agent-communication.md).

## Tools and capability growth

Chrome form batches accept scalar field values (strings, numbers and booleans)
or `Label: value` / `Label=value` fragments. Every supplied entry is validated
before navigation, filling or submission; an unsupported value or malformed
nonempty fragment refuses the batch and identifies the offending field.

After Chrome navigation reports verified completion, the attached page goes
directly to the snapshot reader. Chrome's own tab completion and landed URL
verify HTTP(S), internal, file and PDF navigation without a DOM reader.
Chrome internal pages (`chrome://`, `about:`) return their URL and title with
`read_mode: "none"` and "Chrome allows no reader on its internal pages" as one
text line; snapshot and look attempt no picture. Other restricted pages and the
PDF viewer are read as pictures, explicitly marked
`read_mode: "picture"`, through the same image slot as `chrome.look`. PDF
snapshots preserve Chrome's document receipt with `status: "unread"` and
explicitly report that text is unavailable from the picture reader. They make
no independent HTTP request; an explicit web read is a separate source.
Without an image slot, Chrome picture reads and local `files.read` image reads
succeed with verified source dimensions, byte size and encoded type,
`image_pixels:false`, and a note to view the pixels from a turn. Invalid image
bytes still fail; metadata never proves pixels were seen. Program receipts keep
their own execution verdict and aggregate all calls' effects.
Unsupported navigation schemes refuse before any tab changes with `effects: none`.
Chrome history reads only a private, unchanged-across-capture copy of the admitted
Default profile History and its WAL/journal, independent of extension connection
or profile. SQLite opens the copy read-only; it is deleted after success or
failure, and cleanup failures are reported. Results identify `source: "sqlite_snapshot"`.
Top-domain counts aggregate all qualifying visits since `since` before limiting
returned domains, without a candidate-URL count cap. Search matches title or URL
case-insensitively. The existing two-second SQLite progress deadline bounds query
work, not filesystem I/O. Full Mac and file-read admission remain required;
the extension has no history action or `history` permission. Capture/read failures
never select another reader or profile.
Actions that may start an as-yet unverified navigation retain the
navigation-settled observation.

`files.read` returns `content_sha256` for a whole-file read. A replacement
through `files.write` with `expected_content_sha256` hashes the entire existing
file in bounded, version-checked descriptor reads before comparing that hash
and the destination identity. This conflict check is not an atomic
compare-and-swap against other processes.

`app` is the sole always-on model-facing tool. `app {}` returns home:
where the agent left off, open work, waiting items and arrivals, then the page
index. `page` reads a page; `item` follows a home reference; `find`
discovers actions; `action` with `args` executes one. Actions come from
`AppActions+Declarations.swift`, including arguments and flags for ownership,
irreversibility and screen movement.

Pages and results carry detail without expanding the provider's tool list.
Retired names are refused with translated `app` calls. There is no tool
loading/unloading workflow or separate workspace tool; workspace items are
part of app home.

Action preview follows the [preview contract](TOOL_LOADING.md#one-tool-every-action).
`expected_version` guards a read's page version. Home items can act and support neither option.

### Scripts

`app {script}` runs JavaScriptCore with `app.read`, `app.find`,
`app.log` and the registry's actions. Each call re-enters the action
checks and adds a ledger row. A call that raises a card waits for the answer
and continues or receives the refusal; a blocked action stops the script
without undoing earlier calls. The script has no direct network or
filesystem API; it cannot call every action merely because the action exists.

### Abilities

- An ability is an ability ([AGENT_IS_THE_APP.md](AGENT_IS_THE_APP.md)): what it can do
  is what it declares, never which door made it. `ability.save {id, description,
  code | edits, params?, actions?, reach?, wake?, face?, resident?}` saves a new
  ability or a revision (what it does not restate carries over). Under Full Mac their
  own save is kept and on at once (no rehearsal; its first run is its proof);
  below Full Mac, or when an untrusted agent started the turn, it waits as a
  draft: `ability.validate` rehearses it and `ability.enable` files the owner's card.
- Every kept ability is its own action, `authored.<id>`, on its face page
  (Diagnostics by default), under one signed admission re-verified each run.
  Steps, decisions and expectations in its code make its run strict and
  resumable (`ability.resume`); declared reach gives it the host primitives.
- `ability.read`, `ability.list`, `ability.restore`, `ability.disable` and
  `ability.drop` are the rest of its one lifecycle; see the [manifest
  spec](skill_manifest_spec.md). Abilities grant no new authority. The older
  `skill.*` and `tool.*` doors answer through these until the release after the one that ships one-part.
- NativeAgent runs no MCP client of its own: an MCP server they wants is an
  ability they grows, a resident one holding the server's program or connection.
  Servers a data root kept from before are raised to their once on home as theirs
  to grow; their file is left as it was.

A part's reach comes from its declared permissions: `app_data_read`, `app_data_write`, `model`, `network_localhost` and `app_read:*` are theirs; anything else is their.
Beneath every ability is the Mac's own reach, raw and gated: `host.fetch` and `host.network` to any host its network reach allows, and `host.program` to start a program by name and talk over its stdio, for the run or, in a resident ability, for as long as it holds it. A secret lives in the one keyring ([Keyring.swift](../Modules/NativeAgentCore/Sources/PersistenceCore/Keyring.swift)) under the name they gives it, granted once by the person on a card (pasted, or by a sign-in NativeAgent runs from their parameters, any client secret typed on the card) for the hosts and programs (each the exact file that runs) it may go to, replaced or removed the same way; their code writes `{{secret:<name>}}` and the broker inserts the value at the edge. Redaction covers exact values as written, URL-encoded, escaped in a JSON string and base64 (case-insensitively in reply header names); stream-piece boundaries can expose up to three leading bytes. A granted program or service can transform the value into an encoding the redactor does not catch: the granted recipient is the fence. The [manifest's secret contract](skill_manifest_spec.md#secret-insertion-and-redaction) owns these limits.

Sources: [AppActions+Declarations.swift](../Modules/NativeAgentCore/Sources/AppToolRuntime/AppActions+Declarations.swift),
[app door](../Modules/NativeAgentCore/Sources/AppToolRuntime/AppToolExecutor+AppDoor.swift),
[AppScriptRunner.swift](../Modules/NativeAgentCore/Sources/AppToolRuntime/AppScriptRunner.swift).
The interface contract is [TOOL_LOADING.md](TOOL_LOADING.md).

## Mac, files and web

Mac Control public dispatch uses policy, Full Mac, category, TCC and driver
checks directly, without per-call human approval, including for bridge callers.
An explicit approved replay also validates and consumes its body-bound,
expiring, single-use capability.

The app's pages expose files, shell, Mac apps, browser, screen control,
connectors and agent communication under the saved policy.

- **Files and shell:** a common workspace resolver for all surfaces.
  App-only installs default to
  `~/Library/Application Support/NativeAgent/workspace`; source-backed
  installs use the checkout's `workspace/`.
  `shell.run` and `shell.bash` start in that workspace, including relative
  `cwd`; the owner's source checkout requires an explicit `cwd`. `git.*`
  instead defaults to the app's verified source checkout when no repository
  is named, or the workspace when no checkout exists, and returns `cwd`.
  `git.status` returns parsed branch/tracking/change fields without a raw
  duplicate. `git.run` takes only an exact argv array, preserving empty
  arguments. SwiftPM actions read `configuration`, `package_path` and
  `disable_swiftpm_sandbox`; retired alternate spellings are not read.
  Every command launch checks required workspace preparation; a writable confined
  launch also checks its required SwiftPM shim before starting. Preparation
  failure reports its cause without running a degraded command.
  Three-way patch mode uses one checked Git discovery: only confirmed
  non-repository selects plain apply; other discovery errors stop before
  applying the patch. Shell calls use the owner's conservative literal-command
  certifier: certified reads report `effect:read`, `read_only:true` and pass
  Trust as reads; all other forms remain writes. Read execution shares the
  Git reader's fixed executable/config/environment and read-only sandbox.
  A pre-launch refusal reports `execution:not_run`, `effect:none`.
  Text windows and excerpts require valid UTF-8; invalid source bytes return
  `invalid_utf8`. Explicit `files.read {raw:true}` returns exact bytes as base64,
  even when the prefix looks like text. Size-sort `allocated_bytes` measures disk
  allocation; `size_bytes` is a logical length only when separately measured,
  otherwise null. `files.write` accepts a Boolean `append` only; omission chooses
  replacement. Persona skill inventory `limit`/`offset` accept integers only;
  omission uses zero (uncapped limit, initial offset); explicit nonpositive limits
  remain uncapped and negative offsets count from the end.
  Spotlight executes the requested metadata words/predicate once; `name` selects
  an explicit filename predicate before execution. An empty result never changes
  the search to another mode. MacControl file write/move/trash receipts retain
  the completed mutation (`effects:occurred`) separately from checked `readback`:
  `matched`, `mismatched`, `absent`, or `unavailable`. Only a kernel ENOENT proves
  absence; unavailable readback retains its error domain/code/message and returns
  `verified:null`, while known matches/contradictions return true/false. Move reads
  both entries and keeps each result. Append uses the same checked entry read
  before choosing an existing file or creating a missing one; unreadability stops
  it before writing.
  File grep uses only macOS `/usr/bin/grep`, independent of the launch PATH and
  without an extra install. Patterns are POSIX extended regular expressions
  matched byte-wise in the C locale, with no inherited `GREP_OPTIONS`. Recursive
  searches skip `.git`, `.build`, `DerivedData*` and `node_modules` directories,
  plus repository-root `.gitignore` basename globs supported by grep. Directory
  rules exclude directories only; other basename rules exclude files and
  directories. A later negation that could re-include a basename prevents that
  exclusion. Anchored/path-specific, escaped, double-star and nested ignore
  rules are not translated; hidden entries otherwise remain searchable.
  An absent root `.gitignore` adds no rules; an unreadable, invalid UTF-8 or
  over-64-KiB root ignore file reports `grep_ignore_unavailable` before searching.
  Binary files, devices and symlinks are skipped. Verified single files bypass
  ignore rules and are read directly through their
  inherited descriptor. The old ripgrep lookup and installation/PATH remedy are
  removed; a missing system executable reports `grep_unavailable` with macOS
  repair, never a second engine. Captured search bytes are framed before strict
  per-line UTF-8 decoding: an undecodable match reports an `invalid_utf8` gap
  naming its path and line, while valid siblings remain. A cap-cut line retains
  its captured text through the last complete UTF-8 character and reports
  `capture_cut_line`; invalid interior bytes still make that line unavailable.
  An incomplete/unreadable filename or malformed record reports its own gap.
  Recursive child read failures (including grep exit 2) report each available
  path and reason in `unreadable_search_path` gaps; readable sibling matches
  return with `status:partial`. Grep's exit status and captured output decide
  the result: exit 0 means matches, exit 1 without stderr means no matches, and
  exit 2 retains stdout matches and named path gaps as partial evidence, even
  when readable siblings have no matches. An abnormal exit with neither stdout
  matches nor a diagnostic naming a path, or a launch failure, is `grep_error`.
  The 30-second process deadline returns `status:partial`, `timed_out:true`,
  `deadline_seconds:30` and a `search_timed_out` gap, including when no matches
  arrived. It never becomes an exit-status-9 error or evidence of absence.
  Captured matches remain; a deadline-cut final line has the same complete-character
  retention and `capture_cut_line` gap as a capture cap. Partial abnormal exits
  include a `search_incomplete` gap. Unreadable or capped
  diagnostics report their own gaps rather than establishing complete coverage.
  Gaps make coverage incomplete; at most 50 gap details are shown, with the total
  and omitted counts retained. Capture is still capped at 1 MiB, selected matches
  at 50 and displayed text at 30000 characters. Git uses `/usr/bin/git`; missing
  developer tools report their repair. Repository summaries propagate every
  failed history read. Only Git's
  explicit porcelain-v2 `branch.oid (initial)` establishes an unborn history,
  reported as `history_state:unborn` with no commits.
  URL and verified-directory subprocess captures share `ManagedProcess`'s
  before-exec group, deadline and checked settlement. The deadline freezes and
  kills that owned group; unavailable termination stays an explicit capture
  failure. Pipe EOF waits end after two seconds; grep classifies its exit status
  and captured output as above, while other subprocess readers report incomplete reads as errors.
  Non-search subprocess readers retain strict whole-output UTF-8 decoding.
  Unrepresentable C arguments (embedded NUL, or invalid environment keys) are
  refused before spawn rather than executed with truncated values.
- **Disk capacity:** `mac.system_info` returns `disk` for the named Data
  volume (`/System/Volumes/Data`) and `system_disk` for the named sealed System
  volume (`/`), each with free, used and total GiB and usage percentage.
  `memory.total_mb` comes from OS physical memory, independent of the current
  `vm_stat` counters (`free_mb`, `active_mb`, `inactive_mb`, `wired_mb`,
  `speculative_mb`, `compressor_mb`). Counters require the measured page size and
  valid page counts; unavailable measurements are named in `partial_failures`,
  never substituted with zero or a guessed page size. `battery.source` comes
  from the IOKit power-source snapshot; internal battery presence, capacity and
  charging come from that same snapshot. Missing fields stay null and partial;
  a completely read list without an internal battery establishes `present:false`.
  The one system-info envelope retains available facts with `status:partial`
  whenever a measurement fails.
- **Mac control:** `mac.look`, `mac.act`, `mac.go` and `mac.wait`
  expose perception and action. Perception, document, clipboard, filesystem and
  Spotlight reads bypass motor persistence and replay while retaining policy admission.
  Interactive AX reads and mutations share capability-based renderer preparation,
  checked readback and a per-process Enhanced settle at the source; passive reads
  never write mode flags. See [renderer perception](USER_GUIDE.md#turn-on-mac-computer-control-and-the-activity-watcher)
  for empty/unknown topology, assistive/system exclusions and window-animation effects.
  An optional AX attribute's error `-25200` is an element's named
  `attribute_gaps`, retaining every readable attribute without blocking acts.
  Act-time name reads have the same scope. A failed own-name read, including
  `AXTitle`, marks the label unreadable without trying another label attribute,
  caption or hint; unsupported/no-value attributes remain absent.
  A separate caption read's failure
  yields one caption gap and `label_source:"unreadable"` on the control;
  sibling attributes are never reported as its own, and another name is not
  substituted. Pixel masking requires readable values and name/role/frame
  evidence for secrets, including static text: failures withhold the image
  with element/attribute evidence, or mask the affected desktop window in full
  and report its inspection error in `masking_failures`.
  Action-name error `-25200` stays separate as `actions_unreadable` instead of
  an action list. Raw nodes, menu-bar paths, transient menu items and marks expose these gaps;
  screen replies report observed counts and first errors. Numbered views
  include transient-menu nodes and count overlapping native identities once.
  AX actions (including numbered marks) still require live readable action
  names and refuse with that error, without switching mechanisms. Required
  reads and transport/preparation failures remain checked; see
  the [AX observation evidence contract](USER_GUIDE.md#turn-on-mac-computer-control-and-the-activity-watcher).
  A named-app look that finds the app stopped succeeds with `status:"ok"`,
  `app:<name>`, `running:false`; a running app without a readable window
  succeeds with `running:true`, `windows:0`, and menu-bar titles in `menus`
  when a bounded read can obtain them. Nothing is launched or opened.
  These are empty observations, not action preconditions: acts still require
  their target and window, with the existing menu/key handling for windowless apps.
  Ambiguity, permission, lock, minimized-window and read-budget failures remain explicit.
  Bare-name action misses retain an auxiliary menu read's failure text and its
  original detail in `menu_lookup_failure`; unreadable menus do not establish
  that the menu item is absent. Menu name/role grammar resolves against one
  reading, with literal names first; a failed read is returned without another
  lookup. Named acts and batch steps execute once and return their failure
  without automatic replay. Explicit requested repetition stops at its first
  failed attempt.
  Arbitrary `applescript` actions always use
  foreground driver authority and stop their script process on physical takeover,
  regardless of a supplied or inherited `background` label. Fixed-purpose volume
  and player-state scripts keep their existing execution paths.
  Accessibility and Screen Recording grants
  remain macOS decisions. An attempted AX mutation with a failed reply returns
  its readback and never advances to another mutation mechanism.
  Background typing selects another writer only when the previous writer was
  proven unsupported before a write; selection-probe failures and every failed
  text or selection write stop with readback, including single-line replacement.
  Live captured-window continuations retain native AX identity, so a replacement
  window at the same position cannot inherit captured marks or paths.
  Delivered window/region and desktop image points retain their capture-start time,
  window-server numbers, owning processes, frames and capture-time AX control
  regions through cropping and resizing. The existing complete masking walk
  supplies the regions; bounded hit reads through the action source retain the
  reached role and a digest of its identity label, without field values or raw
  captions. Missing, unnamed or unverified inner regions cannot inherit an
  enclosing control's identity. Desktop composition retains each actual window
  layer's evidence; masked layers supply no control identity.
  Image coordinates use half-open pixel bounds (`0 <= x < width`, `0 <= y < height`).
  Point acts require an image already delivered to the model; an implicit point
  without a session image refuses before acquiring pixels or acting.
  A requested region must crop successfully before attachment or deduplication;
  crop failure attaches no image. Deduplication includes the delivered geometry.
  Before a point gesture and before each pointer event, the hand checks the
  captured window against the live input owner and its window-server identity
  at that point (AX input ownership corrects input-transparent backings). Movement,
  resize, replacement or cover returns `window_drifted`; absent identity,
  unavailable window evidence or captures older than the shared 180-second
  frame lifetime return `stale_frame`. No old coordinate is translated onto
  a moved window. Where a named control was captured at the point, the same
  point is hit-tested again through the existing AX action source: a changed
  role, identity label or control frame, ambiguous historical regions, or
  unreadable control evidence returns `stale_frame`, including after scrolling
  or navigation in an unmoved window. A point with no named control (a canvas,
  game or picture) keeps the window checks only, so pixel pointing still works
  where AX has nothing to say. Only the press and release points of a gesture
  are checked; the path between them may cross unnamed background. Point refusals
  are not retried as name resolutions: take a fresh image. This compares the
  AX role/label/frame identity; identical AX identities are not distinguishable.
  Named character chords resolve through the active keyboard layout (including
  its Command mapping); `key:` and `code:` retain explicit physical addressing.
  Chords post keyboard input directly, independent of duplicate menu titles.
  Point `type` clicks the image point, then admits text only to the editor
  that takes focus. Focused typing requires positive AX editability (text role,
  `AXEditable`, caret range or writable selected text), separately from readable
  value/selection proof. Unreadable text returns unverified with a pixel look
  offered; unknown, noneditable and secure focus refuse. Append retains its
  readable-content/end requirement. Handle steps retain their original frame
  identity for one batch, re-resolve it live for every step, and compare effects
  against each step's fresh before-read. A changed field value preserves an
  otherwise unchanged control identity. Missing or unconfirmed identities and
  declared-effect mismatches stop the batch; positional handles retain
  cohort/geometry checks and the shared TTL.
  A targetless scroll selects the largest visible scrollable content region,
  or the observed window content area when AX supplies none. Application names
  prefer exact bundle filenames over display names; duplicate winning filenames
  remain ambiguous. Explicit bundle IDs and paths keep their exact meaning.
  Fused views capture the anchored window alone; open menus remain structural
  observations. Desktop pixels use the separate desktop look owner. Window
  pixel disclosure brackets capture with complete secret inspections of that
  same retained AX root, unions both masks, and checks process, geometry and
  capture provenance within one five-second disclosure budget. AX, ScreenCaptureKit
  and window-server geometry use the window selector's shared two-point tolerance
  per origin/size component; native window identity remains required. Missing, changed,
  late or incomplete evidence returns `redaction_coverage_unavailable` without
  an image. Released images report both inspected node counts and the union's
  mask count in `pixel_coverage`. Superseded views discard pixels and marks;
  superseded looks return no action handles. LatestRead remains the publication owner and the shared
  frame lifetime remains 180 seconds. Selected marks/text report omissions and
  AX truncation; they never claim an exhaustive window. Control names come from
  their own attributes or owned descendants, never unrelated nearby text.
  Focus paths use the owning observation's element identities and child order;
  an unobserved focus stays unknown. Native AX reference tables belong to one
  dispatch or retained sight/continuation, and are released with that owner.
  Menu reads retain checked availability and truncation in the screen page;
  an incomplete required menu branch cannot establish command absence or uniqueness.
  Press reads only the exact named branch and its duplicate-bearing siblings;
  unrelated descendants and the listing's 60-child/160-item presentation caps do
  not refuse a command. The shared AX node/time/depth bounds still apply.
  Menu-bar optional attribute failures stay on the item as `attribute_gaps`,
  with indexed gaps on the reading for unnamed or unreadable items. An unreadable
  name leaves branch coverage incomplete and never becomes an alternate name.
  Window identity reads retain optional subrole, title and geometry failures as
  that window's `attribute_gaps`; sibling windows remain in the inventory. Missing
  optional attributes stay absent, while required identity/channel failures,
  cancellation and the shared read deadline still end the transaction.
  A document read without a path reads the live window;
  an explicit path reads the saved PDF or text file before resolving any app or
  window, even when a named app is stopped. PDF extraction marks a
  partial read and lists any inspected pages without extractable text. File I/O
  failures retain their cause separately from document decoding failures.
  Screen document reads select the focused readable container, an explicit named
  `section`, or the sole document region; unresolved multiple regions are reported
  as ambiguous before scrolling.
  expose perception and action. Accessibility and Screen Recording grants
  remain macOS decisions. Action verification retains every observed change;
  only the rendered receipt limits each change channel to ten rows, with full totals.
  Visible-text deduplication keeps AX coordinates as floating-point values,
  avoiding a trapping integer conversion for an externally supplied frame.
  Native menu reads use an iterative traversal with structural depth and node
  bounds, including unnamed menu wrappers; revisited elements mark the read truncated.
  Menu presses require exact normalized title components; partial names return
  suggestions without executing a longer or merely similar command.
  Repeated identical full paths are one command when every duplicate publishes
  an identifier or key equivalent; enabled entries win. Unpublished duplicates
  remain ambiguous unless only one is enabled or a supplied chord selects one.
  Their displayed paths offer and accept `[first]`/`[second]` occurrence suffixes
  in current menu order (through `[tenth]`, then `[item 11]`, etc.); shown key
  chords can be used directly. Distinct paths remain ambiguous. Exact handles
  also accept double-click, right-click, hover and `focus` through the same live
  element and input gates. Focus sets and verifies `AXFocused`; screen offers
  and schemas read the executing hand's verb inventory.
  An acknowledged AXValue type returns its readback without physical retry.
  Text verification preserves case and whitespace exactly. A differing value
  remains unverified with its observed difference; global capitalization,
  punctuation or whitespace normalization cannot certify an edit. Literal
  text over the character limit reports `invalid_text_length`, independently
  of the chord-count limit.
  An unchanged value leaves the write unverified; inspect it before writing
  again. Explicit keystrokes and routes selected before an effect remain;
  append and continuation insertion retain their rules.
  Universal control resolution does not equate AC/C with Clear/All Clear or
  issue a second clearing action after a press; app-specific flows belong to authored behavior.
  Named acts, exact selections and watch hands share one serialization owner.
  Before input ownership transfers between driver bindings, the prior binding's
  held keys and buttons are released; watch input cannot overlap an ordinary act.
  Physical input shares one hand executor for posting, waits and held-input release;
  raw typing and targeted typing retain their own admission and effect checks.
  Every four-verb physical hand carries the observed foreground PID, including
  keys in an app with no window. A cross-app drag retains the source PID, or the
  destination PID after an authorized raise. An unknown foreground identity sends
  no input. Popup cleanup also carries the burst attention fields and the open
  popup's captured native window identity; every event checks that identity.
  Its failure is retained in `popup_cleanup`. Exact per-event window-number
  checks remain watch-specific. PID-directed field typing rechecks the intended
  window and focused field at every key-down.
  Foreground borrowing retains the prior native window identity without a JSON
  round trip and restores it once through settlement. A missing or ambiguous
  explicit window refuses; ordinary activation has no Apple Event substitute,
  and failed key-window admission never raises the old target. Our own app is
  restored through AppKit activation without self-AX inspection.
  AX mutation receipts retain native cause, code and emission stage; a failed
  reply after attempted emission is an unknown result, never evidence of no
  effect. The duplicate `fallback_reason` result channel is removed.
  Incomplete post-action walks cannot prove modal/focus disappearance.
  Save placement requires the Where control's native full directory URL,
  compared after path standardization and symlink resolution; a folder basename
  cannot verify it. Missing URL evidence leaves placement unverified, and no
  Save command is issued by placement.
  Supplied mouse buttons, scroll units and gesture durations are validated
  before emission; defaults apply only to omitted values.
  A screen watch establishes complete secret masks before retaining a candidate,
  then inspects it again and masks the union of both inspections before publication.
  A field scrolling out during inspection still masks its captured pixels.
  Inspections start at most twice per second. Captures arriving during an inspection
  or its interval replace one pending capture, retaining that capture's preceding
  masks. The same inspection task processes the pending capture when due even if
  the window stays static and supplies no further frame. An incomplete inspection
  ends the watch; expiry or retirement cancels inspection and discards pending pixels.
  Pointer obstruction checks include visible system panels, including full-display
  overlays; neither an application's name nor its window size proves pass-through.
  A document read without a path reads the live window;
  an explicit path reads the saved PDF or text file. PDF extraction marks a
  partial read and lists any inspected pages without extractable text.
  Raw `file/read` (also phone `readFile`) selects UTF-8 by validation, UTF-8/16/32
  by BOM, or an encoding identified by Foundation's lossless detector, including
  Latin-1 and Windows encodings when identified. Its result names `encoding` and
  `encoding_source` (`utf8_validation`, `bom`, or `detected`); detected encoding is
  an inference from a bounded sample, not guaranteed original author metadata.
  No replacement conversion is allowed. The sample reads at most
  `max(4096,max_bytes)+9` source bytes; returned bytes stay within `max_bytes`,
  ending at a complete encoded character, with `truncated:true` if bytes remain.
  A window too small for the first character returns empty content and is
  truncated. `bytes` and `sha256` describe the returned source prefix (including
  any retained BOM), not the encoding sample. NUL characters are preserved;
  empty files return empty content without truncation. Undetermined or un-decodable
  encoding reports `unreadable_text_encoding` and no content.
  Document extraction still requires strict UTF-8 or BOM-marked UTF-16 without
  decoded NULs; it reports `unreadable_text_encoding` for invalid text and no text
  for empty documents.
  When every kept line of the first screen frame comes from an `AXTextArea`
  value and no node, depth, character or per-node bound cut it, that frame is
  the whole text: `reached_end: true`, without scrolling, pointer movement,
  scroll capture/restoration or a scroll-target check. This works in a background
  window and includes the beginning wherever the window is scrolled; it reports
  neither `started_below_beginning` nor `scrollable: false`. Cancellation,
  deadlines, secure-content handling and redaction still apply.
  Passive reads may return that effect-free whole-text frame; viewport-only
  passive reads return their visible text as incomplete without scrolling.
  Other screen reads accumulate by scrolling and report `scroll_target_changed`
  when a changed target interrupts accumulation, including an empty frame left
  by a container replaced during its walk. For those reads, the end is accepted
  only while the original target is still current, with a nonempty, uncut frame
  at the restoration owner's observed scrollbar maximum. Repeated or overlapping
  text affects accumulation only; it never proves the end. Moving through repeated
  text continues reading. Missing position evidence reports
  `scroll_position_unavailable`; a position that fails to advance without proven
  completion reports `scroll_progress_unconfirmed`. Both return partial text with
  `reached_end: false` and `truncated: true`, retaining the existing frame and
  deadline bounds. A missing/invalid maximum never proves completion.
  Once that end is read without gaps or clipping, a target check during view
  restoration cannot make that text incomplete;
  `scroll_restored` reports restoration separately. Restoration runs through
  `settle` under the original driver generation even after Stop; physical takeover,
  explicit handback and changed-target refusals still apply. A read accumulating by
  scrolling from below the beginning still reports `started_below_beginning`
  and `truncated: true`.
- **Mac services:** Mail, Calendar, Reminders, Notes, Contacts, Messages and
  Music have app pages and actions. Service-specific permissions apply.
  Music's `now_playing` leads with `playing`, `paused` or `stopped` (closed Music
  is stopped), with `since` explicitly the first observed time, `observed_at`
  the current read, and no claim of a transition date or unseen continuity.
  `music.control` has real `stop`; `play` with `seconds` (whole 1–30) starts
  the selected song, or a playlist's first song, at its beginning and stops
  Music before returning. The native automation call owns the wait and settles
  the stop even on cancellation, retaining both receipts; a different track
  taken over meanwhile is left alone. No turn timer or lasting track edit.
  Search, library and playlist pages carry `count`, `total` and `has_more`;
  search also takes `offset`. Playlists say `kind: owner|smart|library`.
  Music metadata travels as checked typed AppleScript lists, so punctuation,
  delimiters and whitespace in names remain data. A required property read or
  malformed response fails explicitly; no empty text, zero or guessed index
  stands in for a failed read. Stopped playback explicitly has no current track;
  a failed current-track read while playing or paused remains a failure.
  Track selection uses Music's case-insensitive exact title and optional artist
  query, counting every match before limiting refusal examples to six. Only one
  match can play. Control takes `track`, `playlist`, `artist`, `seconds` and the
  declared `play|pause|stop|toggle|next|previous` actions; retired fields and action
  spellings fail rather than selecting another command. Pages write only `has_more`.
  Library `sort` is `title` (default) or `artist` ascending, or `added` newest
  first; `filter` combines artist/album/genre text with case-insensitive contains
  matching before sorting and paging. The Music page explains its `screen` tag.
  Notes reads return the name separately from the body or preview: a stored
  first line equal to the name, exactly or after trimming whitespace, is
  omitted before paging. `title_line_elided: true` records a page skipping
  that line; a differing first line is preserved. `body_total`, `body_offset`
  and `next_body_offset` still count the stored UTF-16 text, including the title.
  Read `access` receipts confirm automation and the read, with no `write` key;
  write checks belong only to create, update and delete receipts.
  Notes creation resolves one destination before writing: an omitted or blank
  folder uses Notes' default account's default folder; a named folder must match
  exactly one folder. An unavailable destination never selects another route.
  A missing named folder returns `folder_not_found` and `available_folders` from
  folders' own names, without reading their containers or creating a note.
  Notes reads exclude Recently Deleted by matching note ids to folders' own note
  lists and names. An unreadable folder or note is a named `gaps` entry while readable siblings
  return with `status: partial` and `total_is_complete: false`; an empty partial
  result never establishes no matches. Shared Automation/channel failures still
  fail the read. Updates return the exact note id and observed title; if only the title
  readback fails after the update, the completed receipt retains that id and a
  failed `readback` with its actual error, without an invented title.
  Exact Messages history completes only when its history owner reports
  `history_status: available`. A failed history read returns `status: failed`
  with the owner's reason/note; retained thread metadata is explicitly partial.
  Mail distinguishes a missing new-message subject (`missing_compose_subject`)
  from a missing existing-message selector (`missing_message_selector`). Reply
  results accept only the script's known codes or checked draft id; unexpected
  output retains unknown effects and asks for reconciliation in Mail before
  repeating. Mailbox pages and inbox sender counts share one checked account
  header decoder: malformed records or escapes report the transport failure,
  and an empty valid header reports unavailable coverage, never an empty inbox.
  Mailbox pages publish `account_coverage: complete|partial`; omitted accounts
  make a covered page `partial`, preserve covered messages and their continuation,
  name the gaps in `accounts_not_listed`, and omit whole-mailbox totals.
  Search forms and record views show covered partial pages through the shared
  read-evidence rule, retaining message actions, continuation and the named gaps.
  A page with no matched account mailbox fails with `mailbox_coverage_unavailable`;
  a checked mailbox with no matching messages remains usable coverage.
  Mail status, setup-card verification and transcript projections share the
  Mac Integration owner's checked permission and read evidence. Check Mail
  marks readiness after a completed page with explicit complete account
  coverage or a partial page with explicit partial coverage and named account
  gaps. Covered accounts are ready; the missing accounts remain visible in the
  Mail access row and connected-card receipt. Missing coverage and a page with
  no covered account remain unavailable. Transcript reads
  use that evidence without starting a Mail check; a grant alone cannot settle
  a card, and absent or invalidated read evidence still needs Check Mail.
  A Mail check refreshes grants after its read, publishing those grants before
  the checked result in one ordered snapshot, so launching Mail cannot erase
  that result. A Mail launch or quit, or an unknown Automation probe, is not a
  permission change and does not invalidate checked Mail coverage; an observed
  consent refusal, changed consent grant or changed Full Disk Access does.
  Assistant watch setup describes these local Mail read owners and EventKit's
  current grants. A missing Calendar or Reminders grant returns a permission
  card; only the person's Allow action opens macOS acquisition. The status read
  itself does not request a grant or create jobs. An unreadable Trust policy
  makes Mac control and Mac notification access unavailable with the read error;
  local Mail, Calendar, Reminders and phone readiness still appear, and dependent
  watch recipes reflect the unavailable access. Its scheduler actions come
  from the current app declarations, and inactive watch recipes name
  `schedule.create` for explicit creation with `kind`, `schedule` and `payload`
  arguments; recipe titles stay outside those arguments.
  System media `toggle` sends the play/pause key. Idempotent `play`, `resume`
  and `pause` report that the Now Playing owner/state cannot be established;
  they emit no toggle.
  Target discovery uses one bounded Now Playing process recipe. Both preflight
  admission and execution retain typed discovery failures, process output and
  capture/exit evidence in `target_discovery`; no media key is sent after a
  discovery failure. A successful read with no Now Playing path/client or a zero
  player PID returns `no_player` with no effect; Stop propagates cancellation,
  rather than a discovery failure. The player's Write switch still decides admission.
  `mac.apps` consumes the resident Spotlight snapshot. A readable bundle with no
  declared platform is a Mac app. Missing bundle-identity or installation evidence produces
  per-row `classification_failures`, `classification_unavailable` and a
  `partial` reply, never a guessed installed classification. Such rows are
  excluded from the actionable installed projection; exact matching resolution
  reports uncertainty only for potentially installed Mac candidates, so known
  copies and iOS builds cannot block a separate target. Unreadable bundle
  scriptability is `null`. An unreadable ancestor directory reports its own path
  in `directory_gaps` and makes the inventory partial; it does not override a
  descendant app's bundle/location/Launch Services classification. Directory gaps
  and app rows publish in the same snapshot. Synchronous consumers report not ready during initial
  gathering; async request waits end at four seconds or the inherited call
  deadline, whichever comes first, leaving the query alive. Resident arrival
  observation ends with its consumer lifetime; the engine shuts down the query
  only after producers, admitted turns and resident consumers have settled.
- **Connectors:** the Slack and Telegram doors are built in. Any other service
  (GitHub, Notion, Gmail, Google Calendar, X, AgentMail, TradingView, and
  Slack beyond its door, among them) is
  an ability the agent grows from its documentation, its secret kept in the
  keyring and listed on the Connectors page, where it can be removed.
- **Browser:** the built-in browser and optional Chrome extension have their
  own app actions. Chrome requires the extension's connection and authority.
  The built-in browser's [operation contract](INTERNAL_WORKINGS.md#built-in-browser-operation-ownership)
  owns pure previews, settlement, bounded WebKit waits and checked IPC readiness.
- **Web search:** `web.search` searches SearXNG and returns its results or an explicit failure with setup or repair guidance. A malformed result is skipped with a named `gaps` entry; valid siblings still return, and an empty result with gaps cannot establish no matches. Required response/envelope failures still fail the search. Research's results view and Lab evidence retain these gaps. Without configured SearXNG, search is unavailable; it does not select a browser route. The requested time range travels with the SearXNG search.
- **Web search:** `web.search` searches SearXNG and returns its results or an explicit failure with setup or repair guidance. A malformed result or `unresponsive_engines` entry is skipped with a named `gaps` entry; valid siblings still return, and an empty result with gaps cannot establish no matches. Required response/envelope failures still fail the search. Research's results view and Lab evidence retain these gaps. Without configured SearXNG, search is unavailable; it does not select a browser route. The requested time range travels with the SearXNG search.
- **Private web reads:** `web.read` (`read_page`) extracts the retained HTML as
  paragraphs, list items and table rows, with each content link inline as
  `title → url` (a URL label appears once). HN stories keep their points and
  comments link in one row; comments keep their author line and paragraphs.
  Scripts, navigation, footers, hidden content and recognized cookie banners
  are omitted. Extraction has no DOM node cutoff; the response byte bound and
  coverage remain explicit. `find` returns up to eight matching paragraphs with
  surroundings (`around:0...3`, default 1); every find word must occur in the
  paragraph, case-insensitively. Without it the reply is the whole extracted
  text; `full:true` with `find` asks for the whole text instead. `selection`
  states omissions; output paging (`result.page` / `next_page`) or a serving
  sense's `sense_more` continues the selected result. Every successful fetch's
  `source_receipt.path`, `purpose` and file-read arguments explain the locally
  retained source evidence and how to inspect it without refetching, subject to
  normal permissions and limited retention. Neither continuation recovers bytes
  beyond the response bound. Network failures name `no_such_host`,
  `connection_refused` or `timeout` when those are the cause.
- **Maps:** `maps.search` accepts the location in `query` after near/in/around
  when a separate `near` is absent/empty, and reports the split in `query_split`.
  `maps.route` returns every step with path-segment distances and explicit
  `traffic:"not_included"`; its expected time describes ideal conditions.
- **Activity:** capture has a separate consent control. Activity sharing is
  distinct from recording.

Sources: [page vocabulary](../Modules/NativeAgentShared/Sources/NativeAgentShared/SurfaceLayout.swift),
[workspace resolver](../Modules/NativeAgentCore/Sources/PersistenceCore/NativeAgentWorkspaceRoot.swift),
[search routing](../Modules/NativeAgentCore/Sources/Research/Research+WebSearch.swift).
Chrome setup is in the [extension guide](../Extensions/NativeAgentChrome/README.md).

## Memory, knowledge, and learning

Make allocates positive, increasing artifact versions with checked arithmetic;
exhausted version numbers refuse the append without changing its metadata.
Decoded refs must match their lookup; local version filenames and resolved
destinations must stay inside that ref's Make folder, including through symlinks.
Studio recall counting validates stored counters and checks increments; invalid
or exhausted counters stay byte-preserved and counting is reported unavailable.
Returned recall entries survive a counting failure. The counter owner records
each unconfirmed pull (time, work keys and cause) as an owed repair in Experiences;
canon evidence remains unavailable until that debt is reconciled. A later
successful pull does not settle an earlier unconfirmed one. A missing counter
means no recorded pulls only when no counting repair is owed.

Studio reads one current saved shape for consults, encounters, corrections,
canon rows and approval payloads. Required writer fields must exist; malformed
present fields or array elements reject their owning row. Journal holes and
correction-history warnings preserve that unavailability; pending canon cards
show their own decode failures and remain unchanged for reconciliation. Canon
rows require the agent seat, live-turn surface/identity and explicit evidence.
Approval reconciliation reports an unreadable canon ledger as an unknown row
outcome, retaining the proposal identity rather than inferring a missing row.
Shelf cards expose correction-history availability independently of any known
supersession. Encounter invitations come from named consults or unjournaled
graph works; there is no implicit screen-encounter source.

Canon tending has cognition's single-flight guard, with a fresh capacity/dedupe
read before each independently committed card. It is not a multi-card
transaction. A damaged saved card blocks only proposals for its own work;
unrelated or unidentifiable damaged cards leave named gaps, and other works
continue. These per-work failures and gaps travel in the pass result and
cognition receipt. An inbox-read or card-write failure stops staging and returns
already-staged approval IDs with the exact cause; an unconfirmed card write must
be inspected before repetition. Audit read and persistence failures travel
separately in the pass result and journal append's derived-failure list. They do not undo a
committed card, journal entry or graph projection. An unavailable graph has no
consistency verdict. Journal appends maintain the current full graph projection;
the completed one-shot backfill and its receipt reader are retired.

Persona editor/setup appends reject a combined document above 30,000 code
points before backup or mutation, leaving the caller's draft recoverable.
The separately authored `personaAppendSection` path remains unbounded.
Onboarding voice selection, UTC backup timestamps and journal encounter stamps
use total value selection without forced optional unwraps.

MemoryV2 owns durable memories in SQLite, with lexical and semantic recall and
proposal review. The about-you persona document is generated from memory.
Knowledge-graph indexing derives from memory rather than becoming a second
fact store.

The Mac Knowledge Graph keeps the selected List or Graph presentation. The
canvas alone refuses more than 200 renderable entities; kind, time and search
filters remain available. Time filters use complete ISO-8601 `last_seen`
timestamps from MemoryV2, without truncation or creation-time substitution.
Missing or invalid recency is counted visibly, stays visible in All time, and
is excluded from time-bounded views. The capability graph panel describes this
same canonical graph's entities and relationships, with no capability counter.
Optional measurements in graph and capability panels, context help and export
receipts remain unavailable when absent; a measured zero stays zero.

Their abilities hold reusable procedures; skills are built-in guidance. Dreams and REM consolidate experience through
their own memory and persona boundaries. These are separate from the turn's
temporary context.

See [Memory system map](MEMORY_SYSTEM_MAP.md) and
[What a good memory is](memory-quality.md).

## Fluid Context

Fluid Context prepares bounded material from persona, memory, skills and other
sources into rebuildable generations. A turn pins a generation; deeper
`context.expand` reads are limited to the pointers offered for that turn.
The source stores remain authoritative.

Settings exposes Active and Off through **Memory in every reply**.
See [Internal Workings](INTERNAL_WORKINGS.md) for context preparation.

## Cognitive substrate and Organism Kernel

Cognition and organism state support continuity, appraisal, reflection and
posture. They are observable through Diagnostics and controlled through the
inner-life settings. Their projections can inform a turn; they do not grant
permissions or replace persona and memory authority.

See [Cognition wiring](COGNITION_WIRING.md) and [Organism](ORGANISM.md).

## Desk and directed work

Desk holds durable work identity, hierarchy, dependencies, schedules, progress
and outcomes. A task the person starts becomes a Desk item carried by a line of
theirs, and their jobs are its movement ([Desk](DESK.md)).
Pursuit feed rows and compaction snapshots share checked reservation accounting;
unrepresentable totals refuse decoding before scheduling can use them.
Pursuit `maxDays` is an elapsed-day lifetime from `openedAt`: selection and
reservation refuse expired work.
A held row reflects its current blocker or defer, rather than a new stored
task status.
An absent hold file starts empty; unreadable or malformed hold state refuses
hold reads and writes with its storage cause and preserves the existing bytes.
Finished continuation replies are due immediately; Desk invalidation wakes their delivery owner.
Reminder settings refuse an exhausted window counter before a transition can
overflow; failed transitions leave the saved settings unchanged.

Standing helpers own their model/tool loops, using their names, personalities,
jobs and persisted conversations under the live Trust policy. Their model
selection follows Chat's Providers settings unless explicitly pinned.
They talk to the resident through the contact path. Scheduled and event-triggered work uses
the unattended-work gate. Explicit **Run once** requests and **Continue in
Chat** are available on the helper's page.

The core's `BackgroundLoopLifetimes` owns background lifecycle and execution.
See [Automated systems](AUTOMATED_SYSTEMS.md).

## Provider and model control

The provider page and routing code share three groups: **Chat**, **Work**, and
**Memory and mind**. Work and Memory and mind inherit Chat unless configured.
Effort-only and tier-only choices preserve model/account inheritance. Partial or
conflicting overrides are unavailable with their saved keys and repair controls;
they cannot execute through Chat. Picker failures retain forward intent and
report each projection's checked state, without compensating writes. The
[provider admission contract](INTERNAL_WORKINGS.md) owns catalog credential
binding and route-specific control evidence, including unknown Moonshot controls.
Quiet account settings, model/effort choices, Fast writes and image-model
readback use the checked routing snapshot. Unreadable routing returns its
repair evidence instead of an empty account or default choice. A missing
selection in a successfully read snapshot retains its existing semantics.
A group's choice includes the provider and model; the UI reports unusable
saved choices rather than presenting them as available. Helpers follow Chat's
provider, model, Think and Fast unless explicitly pinned; a missing legacy pin
flag also follows Chat. Following helpers refuse conflicting submitted settings
at the field supplied, including when unpinning or saving from the phone;
matching inherited values are accepted as no-ops with a note. The
[helper settings contract](USER_GUIDE.md#helpers-standing-bots) describes this rule.

The routing group table is in `ProviderRouting`; its UI projection is
[ProviderActivityChoices.swift](../Sources/NativeAgentApp/ProviderActivityChoices.swift).

## Trust, security, and receipts

Mac Integration bootstraps permissions only when `lstat` confirms the store
is absent. Unreadable or unsupported entries, including symlinks, remain
unavailable and preserved; they cannot restore fresh-install grants.
Native-action and connector receipt histories read checked JSONL tails.
ConnectorActions projects each returned outcome once for the append owner;
approval waits and dry runs retain unknown completion (`ok: null`).
Unreadable files or malformed rows report the actual read/decode failure;
their existing facade owners retain prior checked rows rather than publishing
a successful empty history. Tails remain bounded to 50 rows and 1 MB.

TrustCenter owns policy; SecurityCenter evaluates the requested action and its
origin. The four presets are Safe, Work mode, Builder and Full Mac.

Full Mac grants autonomy for admitted turns without routine per-action
approval and has no expiry timer. Explicit user blocks, origin authentication,
macOS grants and hard domain refusals remain authoritative. **macOS privacy
permission resets always ask the owner first.**

A turn is peer-steered only when an agent you have not trusted started it with its message; that turn's first effect of any kind files one card quoting what the agent asked, and your answer covers the rest of the turn. Reading any agent's words steers nothing; conversing with agents and telling them what to do asks nothing.
Agents enabled in Trust → Connected agents carry the owner's authority on
authenticated turns; ordinary Trust and domain checks still apply.

A returned protocol response, approval or builder report is evidence, not
automatic proof that the requested effect completed. Inspect the receipt and
the owner of the external effect.

Sources: [Full Mac policy](../Modules/NativeAgentCore/Sources/TrustCenter/SecurityCenter+FullMacPolicy.swift),
[SecurityCenter.swift](../Modules/NativeAgentCore/Sources/TrustCenter/SecurityCenter.swift),
[PeerTurnEffectPolicy.swift](../Modules/NativeAgentCore/Sources/TrustCenter/PeerTurnEffectPolicy.swift).

## Honest limits

Screen attachments pass the captured image directly to the bounded chat encoder;
resizing precedes transport encoding, with no full-resolution PNG round trip.

Mac notification readiness requires enabled policy, current macOS authorization,
and a delivered app notification still retained by Notification Center. A granted
switch without retained delivery proof stays `probe_needed`; denied authorization
needs permission, and unavailable authorization stays explicit.

Work-journal Git reads check branch, HEAD, status and log exit codes. A failed
read reports the command and cause instead of presenting unknown state as clean.
Roots that fail repository discovery retain an unavailable row with the command,
exit status and error; they cannot silently disappear from the journal.
Handoff reads distinguish confirmed absence from read or UTF-8 failure; the
journal's unavailable handoff includes the read failure's cause.

Messages reads give their each US number as a person writes it, (555) 123-4567,
in participants' `name` and each message's `sender_name`, never a contact's
name: the number is the identity they works with (User 10-28: going by names
drifted to the wrong person).

`messages.recent` retains its registered action id so saved abilities declaring
it continue to resolve. It lists all existing row fields by default.
Its optional `fields` selects only named row keys: `["handle","name","last_at","unread"]`
returns participant handles (an array), the thread name, latest-message date
and unread count, without message text. `last_at` aliases `date`; `unread`
aliases the all-date `unread_count`. Existing row keys are also selectable;
omitted or unavailable keys stay absent. `fields:[]` returns empty rows while
preserving envelope counts. Fields apply to thread lists, not exact-thread
history or `from_me` reads. Projection happens after contact enrichment so it
cannot add unrequested fields.

`unread_only:true` keeps only threads whose latest message is incoming and
unread; old unread records alone do not qualify. `since` bounds the latest
message date for either sort and also the unread message selected by
`sort:"oldest_unread"`. That sort defaults to the past 30 days; `newest` has
no default cutoff. `since` accepts local `YYYY-MM-DD`, ISO-8601 with a time
zone, a positive duration such as `7d` (minutes/hours/days/weeks: `m/h/d/w`),
or `this week` from the local week's start. The same date forms work with
`from_me` and its exact window counts; exact-thread history uses its own
message cursor instead. Read flags describe local state, not recipient receipts.

Calendar day selection accepts `today`, `tomorrow`, or an exact `YYYY-MM-DD`
date. Invalid supplied days fail explicitly; only an omitted day selects the
default upcoming window.

Available actions still depend on permissions, platform support, connections
and credentials. Provider requests and configured services may send selected
data off the Mac. A source checkout does not establish App Store review status,
release publication or installed behavior.

Read [Project Status](../PROJECT_STATUS.md) for the current source summary,
[Privacy](../PRIVACY.md) for data handling and
[Threat model](threat-model.md) for security boundaries.
