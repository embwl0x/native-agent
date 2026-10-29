# NativeAgent capabilities

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
  and Agent views. Agent view is read-only.
- **iPhone/iPad:** a companion using signed iCloud transport to the Mac.
  The Mac must remain awake with NativeAgent open to answer.
- **Telegram and Slack:** messaging surfaces with their own conversation
  origins and the shared engine's provider, context and action policy.
- **Local bridges and agent contacts:** authenticated conversations and coding
  handoffs. The bundled `nativeagent-link` helper and HTTP agent clients read
  the agent bridge's descriptor under `~/.config/nativeagent-link/` and send
  each contact's own credential; the older Claude/Codex lane keeps
  `~/.config/claude-bridge/bridge.json`.

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
`read_mode: "picture"`, through the same image slot as `chrome.look`. HTTP PDF
snapshots carry the verified picture and independent HTTP transcript together:
the transcript retains `status: "unverified"` and the reason that Chrome's
displayed document was not verified and Chrome cookies/authentication were not
used. Its read failures and truncation remain explicit beside the picture.
Unsupported navigation schemes refuse before any tab changes with `effects: none`.
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
- `ability.read`, `ability.list`, `ability.restore`, `ability.disable`, `ability.rollback` and
  `ability.drop` are the rest of its one lifecycle; see the [manifest
  spec](skill_manifest_spec.md). Abilities grant no new authority. The older
  `skill.*` and `tool.*` doors answer through these until the release after the one that ships one-part.
- NativeAgent runs no MCP client of its own: an MCP server they wants is an
  ability they grows, a resident one holding the server's program or connection.
  Servers a data root kept from before are raised to their once on home as theirs
  to grow; their file is left as it was.

A part's reach comes from its declared permissions: `app_data_read`, `app_data_write`, `model`, `network_localhost` and `app_read:*` are theirs; anything else is their.
Beneath every ability is the Mac's own reach, raw and gated: `host.fetch` and `host.network` to any host its network reach allows, and `host.program` to start a program by name and talk over its stdio, for the run or, in a resident ability, for as long as it holds it. A secret lives in the one keyring ([Keyring.swift](../Modules/NativeAgentCore/Sources/PersistenceCore/Keyring.swift)) under the name they gives it, granted once by the person on a card (pasted, or by a sign-in NativeAgent runs from their parameters, any client secret typed on the card) for the hosts and programs (each the exact file that runs) it may go to, replaced or removed the same way; their code writes `{{secret:<name>}}` and the broker inserts the value at the edge and redacts it from every reply, receipt and error.

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
  duplicate. Shell calls use the owner's conservative literal-command
  certifier: certified reads report `effect:read`, `read_only:true` and pass
  Trust as reads; all other forms remain writes. Read execution shares the
  Git reader's fixed executable/config/environment and read-only sandbox.
  A pre-launch refusal reports `execution:not_run`, `effect:none`.
- **Disk capacity:** `mac.system_info` returns `disk` for the named Data
  volume (`/System/Volumes/Data`) and `system_disk` for the named sealed System
  volume (`/`), each with free, used and total GiB and usage percentage.
- **Mac control:** `mac.look`, `mac.act`, `mac.go` and `mac.wait`
  expose perception and action. Perception, document, clipboard, filesystem and
  Spotlight reads bypass motor persistence and replay while retaining policy admission.
  Accessibility and Screen Recording grants
  remain macOS decisions. An attempted AX mutation with a failed reply returns
  its readback and never advances to another mutation mechanism.
  Background typing selects another writer only when the previous writer was
  proven unsupported before a write; selection-probe failures and every failed
  text or selection write stop with readback, including single-line replacement.
  Live captured-window continuations retain native AX identity, so a replacement
  window at the same position cannot inherit captured marks or paths.
  Named character chords resolve through the active keyboard layout (including
  its Command mapping); `key:` and `code:` retain explicit physical addressing.
  View pixels require a complete secret-mask walk independent of presentation
  caps; missing or incomplete AX coverage returns `redaction_coverage_unavailable`
  without an image. Full-desktop view pixels have no complete coverage owner.
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
  no input. Exact per-event window-number checks remain watch-specific.
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
  only while the original target is still current.
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
  System media `toggle` sends the play/pause key. Idempotent `play`, `resume`
  and `pause` report that the Now Playing owner/state cannot be established;
  they emit no toggle.
- **Connectors:** the Slack and Telegram doors are built in. Any other service
  (GitHub, Notion, Gmail, Google Calendar, X, AgentMail, TradingView, and
  Slack beyond its door, among them) is
  an ability the agent grows from its documentation, its secret kept in the
  keyring and listed on the Connectors page, where it can be removed.
- **Browser:** the built-in browser and optional Chrome extension have their
  own app actions. Chrome requires the extension's connection and authority.
- **Web search:** `web.search` searches SearXNG, every engine it has, and returns its results or its failure said plainly (no fallback; Doctor names a broken SearXNG); on a Mac without SearXNG the result hands their `browser_search`, the same search in a browser (Chrome through the extension when it is connected, else their own browser), which they runs and reads; a time range travels with either.
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
Persona editor/setup appends reject a combined document above 30,000 code
points before backup or mutation, leaving the caller's draft recoverable.
The separately authored `personaAppendSection` path remains unbounded.
Onboarding voice selection, UTC backup timestamps and journal encounter stamps
use total value selection without forced optional unwraps.

MemoryV2 owns durable memories in SQLite, with lexical and semantic recall and
proposal review. The about-you persona document is generated from memory.
Knowledge-graph indexing derives from memory rather than becoming a second
fact store.

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
and outcomes. Its execution path retains checkpoints, approvals and verification.
Workshop admission reports active-plus-pending capacity overflow as invalid configuration.
Planner calls declare no separate elapsed-time ceiling; provider/transport
termination and caller cancellation own their lifetime.
Execution reads and mutations require a faithful checked record, including every
plan row and field; damaged records remain byte-preserved and cannot be admitted
or rewritten as empty work.
Synthesis uses the turn owner's completed-return contract and explicit
`expected_outputs` evidence. English phrases, text length and instructions
quoted in objective prose never create refusal or exact-equality verdicts.
Verification classifies resolved action calls through `PermissionLaw`, as
dispatch does; read-like names cannot exempt writes from effect verification.
Pursuit feed rows and compaction snapshots share checked reservation accounting;
unrepresentable totals refuse decoding before scheduling can use them.
Pursuit `maxDays` is an elapsed-day lifetime from `openedAt`: selection and
reservation refuse expired work, and sessions enforce its remaining wall-clock
bound separately from their default 600-second active-work deadline, which renews
on progress and pauses during human waits. The existing pump deadline wakes
budget-exhaustion closure at expiry.
Workshop uses Desk's unresolved-receipt interpretation: acceptance, running work,
unknown effects and unsatisfied verification block dependent steps while the
original receipt and owner references remain available for reconciliation.
Every blocked Workshop session disposition blocks its Desk item, including
timeout, failed turns and missing progress reports, using the actual receipt cause.
Directed submission reports an accepted execution ID if Desk linkage fails;
terminal reconciliation restores that execution's exact Desk trace association
before settling it, without submitting the work again.
Directed reconciliation appends missing receipts from one locked feed snapshot
before checking each execution's Desk settlement marker.
Link repair is idempotent under Desk's lock and compares canonical acceptance
timestamps, so repairing an older execution cannot supersede newer linked work.
A held row reflects its current blocker or defer, rather than a new stored
task status.
An absent hold file starts empty; unreadable or malformed hold state refuses
hold reads and writes with its storage cause and preserves the existing bytes.
Finished continuation replies are due immediately; Desk invalidation wakes their delivery owner.
Reminder settings refuse an exhausted window counter before a transition can
overflow; failed transitions leave the saved settings unchanged.

Standing helpers own their model/tool loops, using their names, personalities,
jobs, persisted conversations and saved model choices under the live Trust policy.
They talk to the resident through the contact path. Scheduled and event-triggered work uses
the unattended-work gate. Explicit **Run once** requests and **Continue in
Chat** are available on the helper's page.

The core's `BackgroundLoopLifetimes` owns background lifecycle and execution.
See [Automated systems](AUTOMATED_SYSTEMS.md).

## Provider and model control

The provider page and routing code share three groups: **Chat**, **Work**, and
**Memory and mind**. Work and Memory and mind inherit Chat unless configured.
A group's choice includes the provider and model; the UI reports unusable
saved choices rather than presenting them as available. Helpers retain their
own saved choices.

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

Messages' optional contact-name enrichment invalidates its cached projection on
Contacts store changes. A failed enumeration publishes no partial name cache.
Phone-name matches retain the entire explicit international number; local
numbers without region evidence and handles shared by different contacts stay
unnamed. No country is inferred from a ten-digit suffix.

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
