# NativeAgent Architecture Blueprint

Last navigation/ownership review: 2026-08-30.

Use the [documentation and repository guide](README.md) for a short reading
path. This catalog preserves detailed contracts; jump directly to the owner
you need rather than treating every dated note as a current task.

- [Runtime shape](#runtime-shape) and [high-level flow](#high-level-flow)
- [Mac app owners](#app-source-map), [iOS](#ios-companion-map), and [Core](#core-runtime-map)
- [Desk work](#desk-work-ownership) and [tool dispatcher](#tool-dispatcher-map)
- [State](#state-ownership), [policy](#policy-chokepoints), and [chat context](#chat-context-rules)
- [Background loops](#background-loops), [connectors](#connector-rules), and [build/test](#build-and-test-baseline)

## Recent contract notes

Phone catch-up limit (2026-09-06, ACCEPTED AS IS): the CloudKit device
transport sweeps chat and notification records past a 14-day retention
window, and the only fallback for a phone that was offline across that
window is the ordinary mobile snapshot. That snapshot is bounded, and these
are its exact numbers — `MacSyncEngine+Snapshots.swift`,
`chatTranscriptSnapshots` / `compactTranscriptMessages` /
`truncateTranscriptContent`:

- at most **8 sessions** (`sessions.prefix(8)`), chosen as one Mac main, one
  phone main, then the pins, in that order;
- at most **80 messages** per session (`messages.suffix(80)`);
- at most **6,000 characters** per message, tail truncated with a marker.

So a phone that misses the retention window recovers, at any one moment, the
last eighty messages of eight sessions — nothing older, nothing from a ninth
session, and no message body past 6,000 characters.

What that costs is narrower than "gone for good" (corrected 2026-09-06). The
sweep deletes the delivery records in CloudKit; it deletes nothing on the Mac,
which remains the whole record and republishes on every edge. And which eight
sessions the envelope covers is the user's to change — the set is one Mac main,
one phone main, then the pins, so pinning a session on the Mac publishes its
last eighty messages to the phone on the next pass. What a phone genuinely
cannot get back is the part of a missed conversation that no snapshot ever
carries: anything older than the last eighty messages of a session, and any
message body past 6,000 characters.

Making the fallback whole needs a cross-device protocol this pass did not
open: the phone would have to report that its last drained cursor is older
than the retention window and name the sessions it is short of, and the Mac
would have to answer with a one-time, bounded, fuller transcript snapshot for
exactly those sessions. That is a new status key, a new request/response
shape on the device transport, and a new bounded publisher on the Mac.

Bounded discovery contract (2026-08-30): `MacFourVerbs.zoom` owns on-demand
HUD/readout and controls/actions scopes. Whole-section expansion retains
source omissions and original addresses; observed caps and unobserved values
are distinct. `MacScreenRender` supplies real `screen(part:)` recourse without
exposing inaccessible renderer knobs. Ordinary-turn caps remain unchanged.

Natural aiming contract (2026-08-30): within-target diagonal prefixes are
parsed separately from object identity and select inset quarter-points.
Explicit covered points never relocate. `VisionFourVerbAdapter` shares natural
shape names across existing nearest-object relation aliases, without inferring
new relations or exposing the alias catalog in model context.

Fine-wheel contract (2026-08-30): Four-verb scroll has a local four-direction
type and optional bounded line magnitude; explicit wheel requests never fall
through to vertical page keys or change the lower semantic scroll enum. Zero
keeps defaults expressible in strict tool bindings. Existing hand input and
fresh clear-point selection own both axes and outcome observation.

Partial-region contract (2026-08-30): FourVerbPerception retains broad visual
regions with exact foreground exclusions; discrete objects still fail overlap
admission. `MacRegionAim` chooses a clear default point with bounded geometry
work, but never relocates an explicit spatial request or permits a drag across
an exclusion. All current region exclusions survive target fusion. This adds
no authority, input path, cached screen, or background observer.

Held-key contract (2026-08-30): `MacKeySyntax.parseHeldKeys` owns simultaneous
space-separated key/chord/modifier sets for both timed key holds and `holding`
around gestures. The ordinary key parser still means sequential chords. Both
paths reuse the existing balanced hand and cancellation release owner.

Pointer feedback contract (2026-08-30): `MacPointerPositionSource` supplies one
read-only system position to fused `view`. FourVerbPerception carries it with
the observed surface frame; screen renders a bounded normalized line. Hover
and move settle only pointer-in-current-target bounds, never inferred application
effects. Observed vision bounds remain separate from predicted motor bounds;
pointer prose is excluded from structural-effect comparisons. Missing reads
stay unavailable, and default test sources never read the real cursor.

Pointer button contract (2026-08-30): public four-verb `act` carries optional
left/right button choice through the canonical hand to click/drag/hold input.
`auto` (or omission) preserves ordinary semantic/key/hover actions even in tool
bindings that require a value for every field.
Explicit buttons never become AXPress or Control-left substitutes. Invalid
combinations fail before input; cancellation releases the actual held button.

Visual naming contract (2026-08-30): `VisionFourVerbAdapter` maps measured
square/round silhouettes to ordinary shape-noun aliases on existing targets.
Motion qualifiers require current tracker evidence; aliases neither fabricate
geometry nor relax ambiguity, and remain private rather than expanding context.

Transient menu contract (2026-08-30): `MacAXElementSource.transientMenuRoots`
and `MacTransientMenus` own bounded current native menu evidence. The fused
`view` publishes redacted, handle-free menu items; FourVerbPerception adds
fresh named physical targets. Application-sibling menu paths are never treated
as document-window paths, and hidden menu-bar inventories are not expanded.
Discovery includes direct siblings along the focused element's ancestor chain
(16 ancestors / 96 children maximum), because Chrome keeps page focus while
showing a menu beside the page's containing group.

Pointer coordination contract (2026-08-30): `MacHandRepertoire.hold` carries
held flags on key, mouse, and scroll events through `CGEventSink`, alongside
physical key down/up. Do not depend on asynchronous HID state for modified
clicks. Release flags track only still-held modifiers; cancellation retains
the canonical neutral-hand recovery.

Selective-context contract (2026-08-30): explicit correction topics remain
canonical memory metadata and become derived Context applicability, not a new
authority owner. Applied memory corrections return exact selected-atom feedback
through the prepared turn. Conversation continuation is bounded and on-demand;
work/reminders are not newly surfaced without the user's request. See
`docs/build_plans/fluid-context-as-built-map.md` for current telemetry and eval
boundaries.

## First Principle

NativeAgent is a Swift-native Mac + iPhone agent runtime. `NativeAgent.app` owns the live runtime in-process.

Shipped subsystems are unconditionally Swift-native. The migration-era
`SubsystemFlag` / `RuntimeSnapshot` / `MutableRuntime` control plane and its
app-lifecycle attachment have been retired. Product trust, onboarding, and
preference gates remain owned by their actual subsystems; no gate chooses
between runtimes, and unsupported edges fail closed in Swift.

There is no live external interpreter backend and no launchd-owned agent runtime. Do not add external runtime code, fallback loops, launchd install paths, or duplicated state roots. If a missing behavior exists, implement it in Swift or fail closed with an honest Swift error.

Historical daemon/Python-era words may still appear in old audit notes, compatibility tests, migration comments, or cleanup checks. Treat those as legacy compatibility vocabulary only. They are not the current architecture.

## Read Order

1. [Documentation guide](README.md) for the repository layout and task-specific reading path.
2. The relevant section of this blueprint for exact ownership.
3. [Project Direction](PROJECT_DIRECTION.md) for durable intent and [Project Status](../PROJECT_STATUS.md#capability-snapshot) for implementation boundaries.
4. In a maintainer checkout, the newest relevant section of `docs/HANDOFF_CURRENT.md` and the applicable current as-built map. Public exports omit those private handoffs/plans.

If docs and code disagree, trust code/git, then update the stale doc.

## Runtime Shape

- Mac app: `Sources/NativeAgentApp/`
- Swift runtime modules: `Modules/NativeAgentCore/`
- Shared Mac/iOS models: `Modules/NativeAgentShared/`
- iOS companion: `iOS/NativeAgentMobile/`
- Runtime state: `data/` and `.runtime/` are local/generated and gitignored.
- Work product has one resolver and one trust boundary:
  `NativeAgentWorkspaceRoot` uses `<verified-source>/workspace` for development
  and `<dataRoot>/workspace` for app-only/public installs. Mac chat, detached
  chat, Telegram, Slack, iOS-forwarded turns, bridge helpers, builder tools,
  TrustCenter, connector workspace actions, and compiled Workshop procedures
  consume that same root. Relative file-tool paths resolve there. It is
  local/generated and gitignored. The root is the safe default, not a hidden
  ceiling on Full Mac YOLO: when that exact effect-time policy authorizes file
  operations and outside-workspace access, native shell/build tools and
  Codex/Claude handoffs may select an existing absolute external project.
  Non-Full-Mac turns remain workspace-scoped, and sensitive authority paths
  plus protected system mutation roots remain denied.
- Persona source: `persona/`

The installed app is built by `script/install_app.sh` and normally lives in the current user's `~/Applications/NativeAgent.app`.

## High-Level Flow

```text
Mac / iOS / Telegram / Slack / local bridge
    -> App-side surface handler
    -> ChatOrchestration session + history + continuity
    -> TurnPlan intent/policy/resident-readiness snapshot
    -> compact persona / memory / runtime context
    -> optional gated CognitiveSubstrate capsule
    -> ProviderRouting model adapter
    -> tool loop through SwiftToolDispatcher / AppChatToolDispatcher
    -> MemoryV2, tools, connectors, browser, scheduler, Mac integration
    -> receipts, chat transcript, activity, iCloud/APNS notifications
```

Normal chat should stay fast. Use lazy manifests, small continuity cards, bounded recall, and tool loading. Do not inject broad memory, tool, skill, or connector inventories into every turn.

Full Mac is the deliberate exception to lazy native operator discovery. Once
TrustCenter has filtered the inventory and Full Mac YOLO is active, every chat
surface receives the native file, shell, Git, patch, build, Mac-control, and
maintenance schemas on its next turn without a restart. This removes an LLM
reconstruction/discovery loop. Full Mac also lets the agent name the actual
project cwd for native shell/build work and for `codex_message` /
`claude_message`; bridge workers no longer default real coding tasks into the
empty NativeAgent scratch workspace. Admitted Full Mac YOLO is also the
operator's answer to every per-call ask/confirm policy: local chat and
authenticated Telegram, Slack, iOS, bridge, mission, action, workflow, and
background paths must not create pending approval rows. It does not bypass
authenticated surface identity, explicit user `blocked` overrides, connector
readiness, protected roots, secret-egress denial, macOS TCC, provenance,
effect-time validation, receipts, or domain verification. Those unavailable or
forbidden effects fail as hard blocks rather than contradictory prompts.
Non-Full-Mac turns remain compact and lazy.

New `codex_message`, `claude_message`, and `omp_message` coding conversations fork the
resolved Git checkout into distinct ordinary worktrees before their durable
inbox rows are queued. A private two-line conversation pointer returns later
contextual messages to the same tree; a conflicting explicit follow-up cwd is
rejected before queueing. An omitted cwd remains absent, ordinary non-Git paths
retain their prior behavior, and Git evidence with a failed probe or allocation
is refused instead of dispatching into a potentially shared source directory.
This is dispatch isolation only, not a Factory state machine or lifecycle.

### Swarm workers

Ordinary chat turns do not construct or inject cross-session activity digests.
`buildTurnContextWithHistory` keeps same-session history and relevant memory;
its optional `SessionDigestProvider` is an explicit caller opt-in, including
when a cached digest exists. Historical work feeds and digest files remain
available to requested inspection, not automatic conversational agenda.
Active context assembly checks actual task cancellation at preparation and
completion boundaries. Packet memory-use accounting is admitted only after
the final context is assembled, not merely after selection; ordinary provider
failures still use the established fallback without claiming a user Stop.

Memory projection keeps validated canonical dates in its bounded presentation
body while embedding the original admitted fact text. These dates describe
recorded evidence, not a live-status check; adaptive memory remains subject to
the same selection and expansion policy. Canonical correction flushes join the
current owner's already-admitted derived deliveries as well as the pending
batch, without cancelling those deliveries or changing immutable turn leases.
Explicit `recall_memory`/`recall_search` reads can recover a truncated hit by
`memory_id`, following `read_more` in pages capped at 2,000 characters. Its
content hash binds continuations to one displayed text version; after the
usual eligibility check, a mismatch returns `record_changed` without text and
requires restarting at zero. Legacy unbound continuations are explicitly
unverified, without adding a cursor store or changing access authority.
The existing MemoryV2 boundary performs canonical point lookup and the same
lifecycle, disclosure and durable-quality checks; denied and missing IDs are
indistinguishable and never fall back to KnowledgeGraph. Ordinary search and
automatic turn budgets remain unchanged.
Search fallback may use KnowledgeGraph only to find exact memory-backed fact
candidates, then reads their current text through that same canonical MemoryV2
boundary. Retired, denied, missing, or unlinked graph summaries cannot bypass
recall eligibility after a zero-hit result or semantic outage. Explicit graph
inspection remains separately available.
Skill reads resolve an exact registered display name or ID before applying
legacy `.md` spelling compatibility. Punctuation in a display name never
becomes a filesystem path: only validated body handles and the existing
canonical-root containment checks reach file reads.
Saving a legacy skill without an ID allocates a collision-free identity before
body or version-history writes, including case-only filename collisions.
Explicit IDs remain unchanged; update receipts point to the body actually
written while the prior version and unrelated skill bodies are preserved.
App runtime-skill enable, status, delete, archive, and restore mutations await the existing serialized MemoryV2 pointer
reconciliation and admitted projection delivery before reporting completion.
If recall reconciliation fails after the canonical mutation, the UI refreshes
the saved state and explicitly reports the partial result without rollback.
Manifest-only installation confirms registration, not an unread body or recall
pointer; it does not construct a memory owner merely to change that state.
Canonical memory correction refuses a self-reference. If storing the correction
deduplicates to the original fact, that fact remains active and the tool reports
that no correction was applied rather than retiring its only recallable copy.
The same write transaction checks that a distinct replacement still exists and
is eligible before retiring the original, preserving recall if the replacement
was removed or retired between storage and correction.
Proposal acceptance rechecks exact forgotten-content hashes inside its write
transaction before the existing semantic tombstone gate, including legacy
records without embeddings; a late tombstone remains a committed rejection.
Foreground memory deletion uses the canonical owner's atomic delete result and
awaited projection completion, preserving missing-row errors and exact-root
isolation without changing prepared turn leases.
Foreground pinning uses the same owner's transactional pinned-only metadata
patch and completion boundary, without replacing a stale metadata snapshot.
Manual memory saves resolve that same exact-root owner rather than always
using the process-default singleton.
Duplicate reassertions also await existing projection publication after their
metadata update, so observed dates and provenance reach the next prepared turn
without changing identity, creation time, or embedding work.

`agent_swarm` is temporary fan-out inside the same runtime, not another mind.
Provider Routing's checked `swarms` surface tuple owns its default provider,
model, and reasoning effort. Explicit model choices can specialize workers;
TrustCenter does not own a competing model default.
Explicit malformed worker lists or unrecognized access modes are rejected
before provider execution, rather than silently substituting default workers
or another access mode. Omitted/nullable defaults and valid aliases remain.
Explicit worker mission/context aliases must contain text, null, or no value;
malformed supplied constraints fail before any worker starts instead of being
silently dropped, even when another alias contains valid text.
Each admitted swarm also captures its provider transport and service tier.
Prompt-only and inherited workers bind their selected model and effort to
that captured route; same-family specialization preserves the selected
transport, while explicit cross-family models retain existing inference.
Synthesis reuses the admitted tuple rather than rereading picker settings.
An inherited worker's originating surface still controls authority, not its
provider tier, and no parent call's effort silently replaces a worker choice.

Workers are prompt-only/read-only unless the parent selects `access: inherit`.
Inherited workers reuse `runEphemeralToolTurn` and the existing tool dispatcher,
workspace resolver, SecurityCenter/TrustCenter, autonomy, receipts, and
verification. The originating surface and verified session remain the
authorization identity even though LLM calls use the Swarms provider. Nested
delegation and NativeAgent install/restart are withheld from worker catalogs
and dispatch. SwarmRuns owns fan-out and receipts only; it does not become a
memory, permission, provider, or tool owner.
Worker discovery reflects that same scope. Its fixed-request load/unload
receipts never mutate the parent session's durable readiness; ordinary tools
retain their existing capabilities and effect-time authority checks.

Temporary tool turns bind their own execution ID to the existing trace bus
and durable tool receipts, without creating a chat session. Worker aliases
are canonicalized before the existing parent-only recursion/lifecycle check.
Cancellation stops queued admission and synthesis; retained partial output
is evidence, not proof of completed effects. Builder inbox retries retain the
accepted message ID, operation, brain and reply origin. Only explicit identical
unconsumed retries may re-enter canonical helpers; those helpers preserve
uncertain execution/delivery outcomes instead of inferring safety from a dead
process or elapsed time.
Prompt-only worker calls use their exact retained report IDs as trace IDs;
synthesis uses `<swarmRunId>-synthesis`. The existing trace bus carries an
ID-only link to the parent and report, without recording prompts or creating
another session or event store. Inherited tool workers retain their own
ephemeral turn identity.
Ephemeral large-result recovery and its turn-exit cleanup use the same verified
tool-session identity, releasing bounded spill capacity without creating a
persisted chat session or permitting cross-turn reads.
Regenerated assistant replies may follow their own canonical retry tool
receipts: the locked writer retains those receipts and replaces only the
target assistant. Any unrelated trailing turn or untyped receipt still
rejects replacement, preserving concurrent conversation evidence.
Local-only requests stopped before provider admission retain their exact user
row and typed retry notice across reloads only while the canonical conversation
IDs remain unchanged; a newer user or assistant turn supersedes them.
After a pre-write stream failure, that same canonical-ID proof restores the
original optimistic request and marks its notice unpersisted. An older
unanswered user row cannot substitute for the current request during retry.
Detached initial loads and session-selection snapshots use this same merge
after their existing lifecycle guards, rather than bypassing retry preservation.
Decoded UI messages belong to the validated transcript being viewed. A fork's
byte-identical copied source rows retain stored IDs/provenance, while actions
on those displayed rows target the fork rather than its source conversation.
Mac transcript clearing preflights the canonical session index, then clears
under the transcript lock and resets count/preview under a separate index
lock only while the transcript remains empty. A new append retains its own
projection; a later metadata-save failure explicitly reports a partial clear.
The UI reloads the exact target session behind existing lifecycle guards, so
selection changes and newer turns cannot be replaced by stale clear snapshots.
Compaction summaries share the cleared transcript; canonical memories remain
separate and are not implicitly forgotten by this action.
Native tool workers carry the engine's typed completed/incomplete terminal
state to swarm receipts. Exhaustion retains bounded partial evidence as failed,
not a completed report inferred from nonempty fallback text. Ordinary ephemeral
callers retain their existing behavior unless they request strict completion.
Text-compatible streaming rechecks the actual cancellation flag at EOF, so a
Stop after the last delta still retains partial output without issuing a final.
The nonstream text-compatible collector also treats a terminal save error as
failure even if reply generation already emitted a final value.

External `delegation_status` reads retain readable jobs while reporting bounded
per-source availability from the same observation. Missing stores are absent
evidence, not read failures; malformed or unreadable records produce partial
or unavailable status rather than a falsely healthy empty result.
Bridge `message_id` lookup matches canonical accepted-message IDs before
paging, including messages grouped into one Codex reply job. Matching output
keeps its internal job ID and exposes only recorded bounded thread/turn IDs;
it does not assign a single motor owner to a multi-message batch. A missing
match is `not_observed`, never proof that execution did not occur.
`delegation_status` can inspect an exact native swarm `run_id` with
`agent=swarm`, using the existing retained receipt store. The initial response
is compact metadata; selecting a `report_id` reads at most 2,000 characters
and provides a continuation offset. Receipt inspection never reruns work or
claims discarded output can be recovered. Bridge status pagination retains
its separate existing semantics, and a successful approval-filing receipt is
rendered as awaiting approval/not run rather than completed execution.
Canonical transcript tool rows retain the existing exact outcome class before
result clipping. History and compaction distinguish unconfirmed completion,
cancellation, timeout and failure from transport acceptance; legacy rows use
only valid explicit-status envelopes, never prose guesses. Claude delivery
reconciliation compares the exact retained completion text in the originating
session, so an earlier same-ID rejection cannot confirm a later result.
Claude/OMP completion delivery requires the original session. Missing routes
retain the terminal result as `blocked/missing_origin_session` without posting
to the currently selected chat; retries cannot rerun work or guess a route.
Ordinary incoming messages and Codex receipt-only GitHub delivery are unchanged.
Explicit Claude/OMP conversation handles carry a resume requirement into the
durable inbox and helper, including same-message-ID retry binding. Under the
existing topic lock, an unavailable pointer settles as `continuation_unavailable`
without starting fresh work. Claude also preserves an explicit pointer when
the provider reports its session missing, rather than automatically starting
a replacement. Legacy omitted-handle behavior and cwd selection are unchanged.
Claude preserves admitted Unicode message IDs rather than clipping UTF-16
units. Direct input beyond the existing 160-grapheme bound is rejected before
claiming work. A retained legacy truncated-ID mismatch remains ambiguous and
cannot authorize execution or delivery replay; filename mapping is unchanged.
Delegation projection retains blocked delivery and its allowlisted missing-route
reason separately from execution status. Outcome cards and motor state report
the blocked handoff rather than success, using the existing uncertainty class
without retrying the worker or adding a new outcome store.
Swarm receipt appends check the existing collection under the writer lock.
Only a missing file bootstraps an empty collection; unreadable, malformed, or
wrong-shaped evidence is preserved and reported unavailable after workers settle.
Persistence failures carry the settled run ID, execution status and counts in
a bounded error with the original diagnostic cause retained separately. Saving
is unconfirmed, not proven absent; inspect that run before considering replay.
Public non-streaming structured chat uses the same bounded, redacted tool-row
writer as streaming chat, whether or not the caller consumes progress events.
Telegram and bridge conversations therefore retain tool evidence for later
history instead of saving only the user prompt and final assistant reply.
Telegram reply quotes retain transport identity without assuming any bot sender
is this assistant; group replies to other bots use neutral bot attribution.
Post-approval receipt replacement preserves the same exact outcome class from
the original result before its preview is clipped. Approval permits execution;
it does not convert a queued, unknown, cancelled or timed-out result into
completed work. Existing approval authority and receipt identity remain intact.

## Shared Causal Language At Protocol Edges

NativeAgent uses one bounded read vocabulary for action phase and verification
across protocol shapes. This lets the resident agent interpret an action consistently
whether it began through a native tool, MCP, connector, messaging surface, or a
future webhook adapter. It does not merge the domains that own the truth.

```text
protocol response or native tool envelope
    -> transport classification + opaque owner action identity
    -> canonical domain read (Workshop / Browser / Mac Control / send / ...)
    -> MotorActionReadModel phase + separate verification state
    -> replay-guarded receipt and resident consequence
```

The ownership contract is strict:

- `ToolCausalBoundary` is a closed, value-only mapping for supported tool
  aliases. It does not dispatch, persist, approve, verify, or infer an unknown
  domain.
- `MCPInvocationOutcome` says only whether a response arrived or the remote
  protocol reported an error. Neither an MCP response nor HTTP `200` certifies
  an external effect.
- Each canonical domain owner retains its exact lifecycle, effect-time
  validation, verification, recovery, and receipt authority. Shared motor
  phases are a projection over those owners, never a replacement reducer.
- A canonical owner projection may return through the replay guard into
  resident state with its verification state still explicit. Duplicate, stale,
  dry-run, transport-only, and unowned evidence cannot masquerade as a new
  consequence.
- New MCPs, webhooks, and connectors should translate at this edge and bind to
  the domain that can verify reality. Do not create a universal webhook bus,
  integration store, scheduler, approval owner, or settlement service.

This is how protocol independence supports one persistent agent: the wire
format can change without making the agent reconstruct a new meaning for proposed,
running, externally waiting, verified, succeeded, or failed work. TrustCenter,
approvals, provenance, canonical stores, and domain verification remain the
authorities.

## Whole-System Tightening Invariants

The August 2026 reliability pass tightened the existing owners without adding a
new runtime, governor, memory, scheduler, approval path, or integration bus.
These rules are part of the architecture, not optional hardening:

- One authorization uses one checked `TrustPolicyAuthorizationSnapshot`: the
  normalized policy and raw autonomy overrides come from the same validated
  bytes and are evaluated at one captured instant. Trust mutations, including
  autonomy promotion and Full Mac expiry intent, commit through TrustCenter's
  locked checked transaction; app adapters do not rewrite the policy file.
- `ApprovalInbox` is the only approval-row mutation owner. Pending rows require
  strict identity and authority fields, duplicate IDs fail closed, execution
  annotation stays inside the inbox transaction, and terminal decisions record
  typed local, verified Telegram, or signed-iOS provenance. Remote authority is
  checked against the same row generation that is committed. Approved effects
  consume one durable spend record before dispatch, so a crash after spend is
  outcome-unknown and never an automatic replay. Restore preserves newer
  approval, replay, occurrence, spend, and external-send fences.
- Authority secrets use the shared fixed-size secret-file primitive: only a
  missing file may bootstrap; a symlink, non-regular file, wrong mode, wrong
  length, unreadable file, or failed readback is unavailable and is never
  silently rotated. Manifest signing and mobile pairing publish nothing until
  durable bytes have been read back successfully.
- Mac pairing rotation is an explicit atomic authority swap: validate the old
  file, stage exact 0600 bytes, fsync/read back, verify the inode boundary,
  replace with rollback, and reopen signing only from the canonical persisted
  read. iOS Keychain update/add/delete is transactional with exact readback or
  absence proof; UI/publication state changes only after durable commit.
  Unsigned resync remains a wake hint and cannot select or replay an
  attacker-supplied request.
- External effects claim durable identity before execution. Canonical external
  send receipts, Telegram update claims, scheduler occurrence claims, Desk
  reservations, Workshop settlement, and delegation cards fail closed on
  ambiguous or damaged authority instead of replaying an effect. A timeout does
  not free a background single-flight slot while its child is still running.
- Trust backups are manifest-bound, digest-checked snapshots below the canonical
  backup root. A destructive restore is staged with a safety snapshot and is
  applied or rolled back before app persistence owners open on the next launch;
  it never mutates the live runtime in place.
- Slack socket and history ingress share one fail-closed channel/user/mention
  policy. Telegram advances its offset only after a durable update claim, and
  quarantines an ambiguous processing generation rather than guessing whether
  an external effect occurred.
- Activity capture has a separate default-off model-disclosure consent. Query
  bounds, filters, time ranges, and truncation are applied in SQLite before
  results leave the local owner. A short process-local Mac motor epoch prevents
  NativeAgent's own accessibility/screen actions from being recorded as human
  behavior; watcher lifecycle and degraded storage truth remain explicit.
  Startup is bounded and asynchronous, partial startup rolls back, termination
  joins the existing watcher shutdown barrier, and chronological rollups reuse
  one Calendar/DST boundary set without changing overlap or clipping semantics.
- Default-root MemoryV2 resolves to one canonical actor/storage owner; injected
  roots never affect live stores. MemoryStorage caps kind-age recall attenuation
  at 10%; lifecycle owns invalidation. ContextSelector weights lexical relevance
  by specificity over its eligible resident corpus, without increasing context
  budgets or weakening mandatory coverage, disclosure, or permissions. Injected
  alternate roots remain isolated. Knowledge Graph panels, tools, and phone
  snapshots use bounded SQL reads, and a complete graph snapshot is compiled in
  one SQLite read transaction. Once SQLite exists, corruption fails closed and
  legacy JSON is not a fallback. Memory semantic audit rejects malformed JSON,
  empty/misaligned embedding blobs, and mixed dimensions within one epoch;
  migration sentinels and generated USER.md markers are checked durable
  authority, never success stamps over damaged legacy state. Memory backup uses
  one coherent SQLite snapshot with integrity verification and no retained
  WAL/SHM sidecars. KG indexing accepts legitimate older/minimal Memory schemas
  when all required authority columns exist, but refuses a missing required
  column; a canonical archived or excluded-lifecycle row overrides stale hook
  payload before any graph row is authored.
- A chat turn retains its admitted provider/model/effort tuple. Trust and
  credential revocation still revalidate at effect time, but no mid-turn picker
  reread may change transport. One turn-local appraisal/warmth/standing view
  feeds cognition; pending reflex review remains visible review state and cannot
  alter live posture or prompt context before approval.
- Chat acceptance remains transactional: screenshot drafts clear only after a
  turn is accepted or queued, detached sessions follow canonical transcript
  file events without overwriting an active stream, and provider diagnostics
  report the exact admitted transport. Delivery telemetry measures the full
  redacted reply length while model-facing summaries stay bounded.

## App Source Map

`Sources/NativeAgentApp/NativeAgentApp.swift` is the SwiftUI app/scene shell. Its executable entry point claims the single app process and completes public-release data-root quarantine before SwiftUI constructs `NativeAgentApp`, `AppModel`, or any process-wide persistence owner; moving a root after a SQLite owner opens it is forbidden because it splits canonical and derived writes across inodes. `UpdateController.swift` is the single Sparkle scheduler/controller shared by the application menu and both Settings presentations; it starts only when the signed bundle carries a non-placeholder feed, a valid EdDSA public key, and the release pipeline's Boolean proof that the feed was published. `ContentView.swift` owns canonical sidebar selection, typed child routing, and the scene-active vnode adapter that keeps AppModel's shared session read model current without polling. `SkillsToolsView.swift` is the single Skills & Tools sidebar destination: it owns only the persisted Skills/Tools page selection, while `SkillLifecycleView` and `ToolsView` retain their separate content and refresh behavior. Direct Skills and Tools routes select the exact child page without recreating a second sidebar destination. `NativeAgentLaunchPreflight.swift` owns the pre-AppKit guard that suppresses accidental Codex-shell execution of the repo dist GUI bundle while preserving canonical installed launches. AppDelegate and app lifecycle behavior belong in focused siblings:

| File | Owns |
|---|---|
| `AppDelegate+Launch.swift` | Launch/bootstrap wiring, URL handling, activation setup, GitHub Keychain credential reconciliation, append-only reconciliation of legacy contradictory Desk hierarchies, and one-shot recovery of durable Codex completion jobs after the bridge listener is ready |
| `AppDelegate+BackgroundTasks.swift` | Background-loop start/stop wiring. Opportunistic `NSBackgroundActivityScheduler` callbacks use Core's due-aware wake path; they never force REM, memory, or self-improvement work ahead of the loop's durable cadence. |
| `AppDelegate+ProcessLifecycle.swift` | Termination/sleep/wake lifecycle hooks |
| `AppDelegate+ICloudRuntimeForwarding.swift` | iCloud/runtime event forwarding through the resident iOS-profile chat client; reuse is profile-exact and cannot borrow Mac/Slack/Telegram policy identity |
| `NativeAgentWindowChrome.swift` | Main-window chrome and placement helpers |
| `NativeAgentEmbeddingWarmup.swift` | Startup embedding warmup |
| `ViewFileRefreshTask.swift` | View-lifetime adapter from canonical file/store invalidations to one trailing-edge SwiftUI refresh; owns no state or signal source and cancels with view visibility |
| `NativeCognitionRuntime.swift` | App-owned CognitiveSubstrate assembly gate, lifecycle restore/persist, atomic Subconscious-master configuration with actual substrate/Organism readback, same-process onboarding-transition refresh, event-coalesced dirty microcycle ownership, one generation-checked exact cognition-maintenance deadline, immediate Dream/REM replay with durable pending-reconciliation retry, reflection surface seed, organism body-state sampling, transactional reflex review + audit receipts, and observatory read model. CognitiveSubstrate projects only real discrete maintenance boundaries (emotional consolidation, thought-seed physical expiry, and proposed-view retirement); elapsed analytic reads create no checkpoint wake, unchanged projections do not churn the task, and the daily registered loop is only crash/integrity recovery. Residual organism repair persists and publishes its own transition without poking cognition. CognitiveSubstrate, OrganismKernel, and the bounded Desk pursuit replay publish immutable attention into one lock-backed handoff after owner transitions; an ordinary turn reads it without entering those actors, touching disk, scheduling work, or calling a model. Resident event admission updates bounded in-memory state and schedules one coalesced microcycle; it does not synchronously commit each physiological family. At microcycle start the runtime captures the scheduled count, turn class, generation, and execution identity, then clears pending state so a reentrant event owns a distinct later generation. One fixed-time field snapshot supplies both workspace and canonical SQLite persistence for nodes, affect, thought seeds, pruning, and the receipt. The ordinary provider seam also takes one fixed-time `CognitiveTurnProjection`: one body sample and canonical affect epoch feed one OrganismKernel refresh/frozen read, and that exact organism projection feeds the frozen capsule. Structured and Anthropic text-compatible turns consume the same capsule/posture pair and only mark it surfaced after appending it to provider context. This value owns no state or authority. Exact-root Desk invalidations still trigger detached canonical pursuit replay and clear stale intent immediately. The live OrganismKernel supplies current delivery prediction evidence after continuity restore; body projection does not decode the kernel's persistence file behind its owner. It publishes payload-free, buffering-newest owner invalidations after visible cognitive transitions so mounted views and the existing Mac→iPhone snapshot writer can reread state without polling. The live default-root runtime also feeds an optional payload-free installed-physiology recorder from existing events/deadlines; recording is asynchronous/coalesced with a bounded termination durability barrier, never another scheduler. Admission provenance assigns live/system/debug/verification class before asynchronous work; topic words in an ordinary user message cannot reclassify it. Alternate/test runtimes inject exact data roots and cognitive/organism configuration instead of mutating process defaults. |
| `NativeCognitionRuntimeModels.swift` | Value types for cognition observatory projections, runtime outcomes, debug overrides, telemetry and scheduling modes; mechanically separated from the runtime actor. |
| `ProviderSettingsView.swift` | Provider accounts page and per-surface provider/model/reasoning selection, save state and routing transactions. |
| `ProviderSettingsComponents.swift` | Reusable provider row, configuration sheet, credential/model/auth presentations, Anthropic connection panels and shared provider page components. |
| `NativeContextFlowRuntime.swift` | App-owned ContextFlow composition, start/stop/reload, the single persisted Active/Observe Only/Off production mode, resident MemoryV2 and Desk/Workshop projections, approved persona skill-body registration through the bounded `NativeMarkdownContextSourceCatalog`, attention handoff, and public pre-onboarding force-off. It does not own canonical memory/persona state or tool authority; file-backed skill bodies remain local, symlink-contained, size/count bounded, and on-demand. |
| `NativeAgentBuildIdentity.swift` | Fail-closed running-bundle identity from stamped version, full source object ID, and dirty-source truth. A revision is exact only when the bundle is clean and carries a full Git object ID. |
| `AgentDisplayName.swift` | Mac adapter over the shared pure identity formatter. Visible UI reads the configured PersonaEngine profile name through `AppModel.agentDisplayName`; generic onboarding labels and missing profile state fall back to `NativeAgent` instead of becoming a fixed persona. |
| `ClaudeBridge.swift` | Always-resident, authenticated localhost `/claude/*` and `/codex/*` router, return/state/message/tool/events/debug routes (independent of Developer Mode), descriptor-published preferred-port fallback, external-MCP deny, bounded activity, bridge attachment metadata, and honest completion status projection for text, attachment-only, failed-pre-dispatch, in-progress, and outcome-unknown results. Loopback binding, the private per-launch bearer, TrustCenter, approvals, and effect-time validation retain authority. |
| `ClaudeBridge+StandingViews.swift` | Standing-view list/resolve handlers and presentation/decision helpers; routed through the bridge's existing bearer gate and shared deadline latch to the Observatory actions. |
| `ClaudeBridge+StateProjection.swift` | State route, checked disk readers, and typed-to-JSON projections for organism, cognition microcycle, Context Flow, and compiled-procedure bridge state, plus reflex-review HTTP status mapping. |
| `NativeContextProjectionText.swift` | Shared whitespace normalization, character bounds, control-character rejection, and KG/Studio trigger tokenization for rebuildable app context projections. |
| `AdvancedPageComponents.swift` | Shared Advanced-page card, section, label, status, summary, and fold components used by Capabilities, Knowledge Graph, Dreams, and Security Center. |
| `CapabilitiesView.swift` | Capabilities page composition, action controls, and capability-specific presentation models and panels. |
| `CodexCompletionLifecycle.swift` | Durable digest-bound claim/cache/delivery lifecycle for Codex completion returns: at-most-once agent-turn admission, response synchronization before external send, per-artifact settlement, stable retry only for idempotent transports, and fail-closed ambiguity/corruption handling |
| `AgentBridgeCompletionRouter.swift` | Routes a cached Codex completion to the persisted origin, requires Slack/Telegram semantic acceptance, and refuses to replay accepted or ambiguity-settled non-idempotent artifacts |
| `NativeLoopbackListenerParameters.swift` | Shared listener-level loopback binding and preferred/consecutive/system-assigned fallback plan for the Mac Control and Codex/Claude bridges; each bridge publishes its selected port, while accept-time peer checks and bearer auth remain separate defense-in-depth gates |
| `ChromeControlRuntime.swift` | NativeAgent.app's sole real-Chrome authority and Unix-socket owner. The default-off Trust Center switch is reread before lease acquisition, navigation, structured snapshot, click, fill, sequential type, select, bounded keypress, checked-state, double-click, bounded wait, and scroll effects; disabling it removes the listener and exact native-host registration and releases active leases without closing tabs. Acts remain snapshot-scoped, password-inert, receipt-bearing, no-focus content-script operations; a lost post-dispatch page reply is outcome-unknown and never automatically retried. Structured snapshots aggregate a bounded every-frame content-script walk plus open shadow roots through service-worker-owned opaque node routing; unavailable frames and closed roots remain explicit rather than guessed. A connection is accepted only from the registered relay executable whose PARENT is a Chromium-family browser, presenting this launch's 0600 secret (2026-09-06). "Chromium-family" is decided by the parent's CODE SIGNATURE — `SecStaticCodeCheckValidity` against `anchor apple generic` plus an exact listed signing identifier — not by an Info.plist the impersonator could write, so an unsigned or self-signed browser build is refused (2026-09-06). When the peer's parent is launchd, the browser that launched the relay has exited and the live check cannot answer: the connection is then accepted only if the hello carries the parent evidence the relay validated at launch (bundle id, pid, validation time) AND the relay executable's own signature still matches its bytes; anything else is refused (2026-09-06). |
| `NativeAgentChromeRelay` | Minimal Swift native-messaging transport for the optional real-Chrome surface. It forwards bounded, length-prefixed top-level JSON objects between Chrome stdin/stdout and the app-owned Unix socket without interpreting browser operations or owning policy, leases, TrustCenter state, receipts, or verification. The host manifest pins the exact extension origin and exists only while the app-owned Chrome control capability is enabled. The bundled relay additionally refuses to start unless Chrome launched it: its parent process must pass code-signature validation as a listed Chromium-family browser and argv must carry the registered extension origin (2026-09-06). It records that parent's signing identifier, pid and validation time and presents them in its hello, which is the only account of the launching browser once that browser has exited (2026-09-06). A bare build-products relay is unaffected — the app does not accept it as a peer. |
| `AppChatToolDispatcher.swift` | App-native notification/browser tools plus lazy `reflex_review`, which routes approve/hold/reject into `NativeCognitionRuntime` rather than writing organism state directly. It is also the sole app-owned chat-body composition boundary: standard surface profiles and purpose-built restricted Workshop dispatchers converge on the same cognition, ContextFlow, memory-atom, provider-lifecycle, and root policy before entering Core. The explicit background profile omits evolution tools, denies external MCP, and does not file approvals without an explicit user-backed filer. One `ToolCausalBoundary.MotorReference` observer replaces per-domain Workshop/Mac/external-send callbacks; the factory still rereads the exact canonical owner before resident consequence admission, while Browser keeps its existing runner-owned readback. Shared chat composition disables only the inner duplicate autonomy decision because `ChatOrchestrationClient` has already authenticated the exact origin and owns the single approval/autonomy membrane; direct/raw app-tool clients retain the inner gate, and all SecurityCenter hard checks still run. |
| `AppChatToolDispatcher+ToolSchemas.swift` | App-native tool schema declarations and their local JSON schema constructors; preserves lazy catalog construction and ordering. |

Native-tool inventory is the union of Core's complete reserved dispatch namespace
and `AppChatToolDispatcher.catalogRegisteredToolNames`, not merely Core's ordinary
built-in list. `EvalCoverageLedgerTests` mechanically reconciles that union with
the coverage ledger. The exhaustive Core and app-owned dispatch tests must reach
a known production boundary for every name; an unknown-tool response, lazy-load
drift, or app-to-Core fallthrough is a failing contract.

Reachability is not functional coverage. The eval merger rejects route-only
gauntlets as asserting evidence; a tool is covered only when a schema-valid
call reaches its owning behavior test. Registry discovery also filters every
reserved canonical/dotted native spelling and `mcp__` name, so a custom row
cannot advertise a schema that native dispatch will route somewhere else.

Installed physiology submissions use one runtime-owned FIFO worker, capped at
256 accepted operations including the in-flight operation. This matches the
recorder's existing burst envelope without blocking cognition or chat. Overflow
and abandoned submissions aggregate into the existing recorder-loss evidence;
a failed drain also blocks the report's completeness claim. Abandonment clears
queued closures and fences later execution by generation, not merely counters.
The recorder's separate 256-row bound includes both pending and in-flight rows;
failed batches restore ahead of newer arrivals without creating extra capacity.
Loss counters become ordered durable rows only when a slot is available, so
repeated append failures cannot expand the retained buffer through loss receipts.

Accepted chat events and cognitive capsules share the same provenance-based
workload classifier. `CognitiveCapsuleRequest.turnKind` carries that class through
preparation and presentation commit, so diagnostic topic words cannot suppress
an admitted live turn's inner state. Bare diagnostic requests that omit the
explicit class retain their legacy inference and non-live presentation behavior.

Bridge message responses carry generated attachment metadata (`id`, type, MIME, name, byte size, and local generated-image path) but never inline base64 bytes. `/codex/message` uses the shared chat factory; `/codex/tool` uses read-only file access with no approval filer. Both deny and scrub external `mcp__*` tools.

`Sources/NativeAgentApp/AppModel.swift` is the observable state/bootstrap shell. It should stay mostly stored state, computed counts, bootstrap, and shared helpers.

`ActivityView.swift` remains the single needs-your-eyes landing, and its five
sections (Approvals, Inbox, Memory Proposals, Self-Improvement, Cognition
Proposals) are the whole of it.

User authorized retiring two surfaces on 2026-09-01 (clause 2, no theater):

- **Native Experience / Journey** — a second eight-page app behind
  `nativeagent.experience.*`, default off, owning nothing. Every record it
  showed already had a canonical owner (Memories, Skills & Tools, Desk,
  Diagnostics/Turn Inspector, Connectors, TriggerScheduler). Its 13 view files,
  `AppModel+NativeExperience.swift`, `NativeDiagnosticObserver.swift` and the
  eight `native-experience*` user-mode-eval routes are gone.
- **Spotlight overlay** — a floating ⌘⇧J panel that forked a hidden
  `sessionId = "spotlight"` chat thread. ⌘⇧J itself stays: hold still arms
  voice, and tap now brings the real main window forward. The
  `/macctl/spotlight_frame` bridge route went with the panel.

`ContentView.swift`'s `CommandPaletteView` sheet is the ONE ⌘K command palette.
Desk's item palette moved to ⌘⇧K so it can no longer shadow it from that screen.

Feature actions live in focused extensions:

| File | Owns |
|---|---|
| `AppModel+ChatState.swift` | Per-session message/receipt state, detached-window helpers, busy/streaming indicators, send-next queue projections, and exact-identity routing/persistence/repair of the Mac turn lifecycle owner |
| `MacChatTurnLifecycle.swift` | Mac-owned accepted-turn lifecycle value/reducer adapter, cancellation intent versus evidence-backed terminal settlement, bounded redacted snapshot store, strict bounded canonical-transcript proof reader, and restart-to-outcome-unknown repair; no UI or Telegram dependency |
| `AppModel+FirstRunWelcome.swift` | First-run welcome/autostart state and onboarding affordances |
| `AppModel+ChatSessions.swift` | Session loading, selection, naming, and the equal-write-suppressed lightweight canonical-index refresh shared by Chat, detached-window titles, Status, command search, and project/session lineage |
| `AppModel+ChatActions.swift` | Transactional send/regenerate/stop/archive/chat memory/scratch actions plus the bounded per-session send-next queue, ordered drain gate, steer cancellation boundary, and exact-turn lifecycle evidence wiring. Regenerate carries both the exact replacement assistant identity and a fresh canonical turn identity into persistence; it never appends then performs a best-effort cleanup. |
| `AppModel+Refresh.swift` | `refreshAll` and dashboard snapshot fan-in; global refresh loads privacy category metadata only, while Trust/Settings explicitly request recursive inventory counts |
| `AppModel+HealthEmbeddings.swift` | Health card, what's-running, embeddings controls; the visible health poll preserves live probe cadence but suppresses timestamp-only Observation writes so unchanged verdicts do not relayout the UI |
| `AppModel+BaseURLSettings.swift` | Transactional validation, persistence, and refresh reconciliation for externally configured service endpoints such as SearXNG; malformed refresh data preserves the last committed observable value |
| `AppModel+ProvidersAuth.swift` | Provider/model catalog, chat brain defaults, Codex login |
| `AppModel+ProviderReadiness.swift` | Provider readiness refresh and chat-brain availability summaries |
| `AppModel+RoutingWorkflowMCP.swift` | Research search, route planning, workflow registry creation, approvals, MCP details/calls |
| `AppModel+GraphCapabilityActions.swift` | KG actions, capability catalog/trust, native actions, browser, improvements |
| `AppModel+WorkshopPolicy.swift` | Dreams job shortcut, Workshop tasks, Trust Center policy, backups |
| `AppModel+MemoryActions.swift` | Memory search, pin/delete/consolidate/hygiene |
| `AppModel+SkillsIntegrations.swift` | Skills, tools, evals, workspaces, connectors, Telegram, Doctor |
| `AppModel+PersonalitySelfImprovement.swift` | Personality docs, self-improvement, memory proposals, training, dreams, promotion |
| `AppModel+ViewClientOps.swift` | Thin NativeClient passthroughs for views (R22): status/config reads, inbox, model catalog, raw POST |

`Modules/NativeAgentCore/Sources/ProviderRouting/FirstPartyModelCatalog.swift` owns the verified public OpenAI, Anthropic, xAI, and conservative Moonshot model/capability tables plus provider-specific request controls. `MoonshotModelCatalog.swift` overlays an authenticated `/v1/models` response on that offline Kimi baseline; its rebuildable cache is never a provider registry row. `LLMClient+MoonshotAdapter.swift` keeps Moonshot identity, credentials, and endpoint separate from generic OpenAI transport, preserves Kimi reasoning content through structured tool loops, and prevents hidden reasoning deltas from becoming assistant text. `LLMClient+AnthropicOAuthRequestBody.swift` owns Anthropic OAuth cache-marker placement: the text-compatible append-only lane retains the previous and current request boundaries within the four-breakpoint limit so cache reuse survives a new conversation turn; structured native-tool traffic retains its separate last-tool/current-message budget. Cache metadata must not alter model-visible prompt content, ordering, effort, or tool authority, and transport support must be established by live provider usage rather than inferred from API-key documentation. `CodexSelectableModelCatalog.swift` overlays the signed ChatGPT/Codex account entitlement cache on an account-verified fallback for both direct ChatGPT OAuth and Codex CLI; its account-only capability contract must never replace the separate OpenAI API-key contract. The account fallback includes exact `gpt-6-astra` metadata (Low through Ultra, Medium default, Fast/priority service), and the bridge schemas source that same canonical identifier. The API-key catalog deliberately withholds Astra until NativeAgent's public OpenAI adapter moves its tool-capable lane from Chat Completions to Responses. `OpenAIExecutionControls.swift` preserves account Max/Ultra as selectable Codex presets but maps either to the deepest direct ChatGPT OAuth wire effort, `xhigh`; Codex CLI retains the literal preset so it can apply its client-side behavior. `ProviderSettingsView.swift` owns provider/model/Think/Fast selection for every canonical model surface, while `ChatBrainControlBar.swift` owns the same provider-scoped controls for the active Mac chat. A successful Providers save must update the shared `AppModel` picker cache immediately so an open chat cannot send a stale provider/model/Think/Fast selection. API keys remain Mac-local and never travel through signed iCloud actions. Global compatibility caches cannot override canonical first-party capability rows. Accepted Slack and Telegram turns consume one checked `ProviderRoutingSnapshot`; their app wiring must not independently reread preference and active-provider files or reimplement effort/model compatibility.

`Sources/NativeAgentApp/NativeClient.swift` is the thin client/facade. Endpoint groups belong in `NativeClient+*.swift` files, not back in the facade.

Large NativeClient endpoint families are split by product surface:

| File | Owns |
|---|---|
| `NativeClient+ApprovalExecutors.swift` | Generic/misc approval resolution and reconciliation helpers |
| `NativeClient+BrowserRoutes.swift` | Visible Browser status/routes and the app-owned WebKit effect adapter. Canonical running/terminal/deadline/cancel/recovery state and derived receipts belong to the Core Browser operation store. |
| `BrowserWindow.swift` | MainActor-owned visible WKWebView and its optional authenticated loopback IPC adapter; the IPC listener shares the preferred/consecutive/system-assigned fallback contract and publishes `browser_ipc.json`, while browser effects and verification remain in the existing Browser domain path. |
| `NativeClient+ChatRuntime.swift` | Chat send/stream facades and chat runtime adapters, including payload-free typed final/failure/cancellation evidence and exact Mac turn-identity binding |
| `NativeClient+ConnectorActions.swift` | Connector action dispatch, status, and receipt helpers |
| `NativeClient+ConnectorAuthActions.swift` | Connector revoke/connect registry mutations |
| `NativeClient+CutoverSeams.swift` | Swift runtime seam helpers and adapter shims |
| `NativeClient+DreamActions.swift` | Manual dream/REM actions and dream diary reads |
| `NativeClient+ExportWorkshopInbox.swift` | Production export plus Workshop execution/inbox helpers |
| `NativeClient+ChatCompaction.swift` | Thin Mac client/UI adapter over ChatOrchestration's canonical transcript compactor; it owns no transcript rewrite and publishes the existing post-persistence completion edge only after a real replacement |
| `NativeClient+ExternalSendApproval.swift` | Slack/AgentMail external-send approval execution and strict canonical receipt handling. Existing malformed, symlinked, or identity-mismatched authoritative receipts are outcome-unknown and block replay; legacy receipt import is allowed only when the canonical receipt is genuinely missing. |
| `NativeClient+ImprovementOps.swift` | Improvement operation actions and receipts |
| `NativeClient+Improvements.swift` | Improvement dashboard, detail, and status helpers |
| `NativeClient+JSONPathSupport.swift` | Small shared JSON/path helpers |
| `NativeClient+KnowledgeGraphView.swift` | Checked canonical KnowledgeGraph projection for Mac panels and iCloud/iOS snapshots; SQLite is authoritative once present |
| `NativeClient+LocalAPI.swift` | In-process local API route adapters |
| `NativeClient+MCP.swift` | MCP server/status/call helpers |
| `NativeClient+MemoryApprovalExecutors.swift` | Memory repair/kind-backfill approval execution and reconciliation |
| `NativeClient+MemoryMutations.swift` | Memory pin/delete/consolidate/hygiene mutation routes |
| `NativeClient+MemoryPolicyActions.swift` | Memory proposals, consolidation, memory-policy patches |
| `NativeClient+WorkMemory.swift` | Work-memory and Workshop execution/status bridge helpers |
| `NativeClient+NativeActions.swift` | Native action catalog, status, and dispatch helpers |
| `NativeClient+NextGenActions.swift` | Next-gen feature action routes |
| `NativeClient+NextGenStatus.swift` | Next-gen status/readiness summaries |
| `NativeClient+Notifications.swift` | Notification, inbox, and APNS status/action helpers |
| `NativeClient+OnboardingActions.swift` | Onboarding start/complete/reset |
| `NativeClient+ProcedureExactActivation.swift` | Idempotent executor and crash reconciliation for the local-only, evidence-bound exact Workshop procedure activation approval; it revalidates canonical evidence before installing the active pointer |
| `NativeClient+ProviderTelegramSessions.swift` | Provider/Telegram session linkage helpers plus explicit-root model preference reads from one checked canonical routing snapshot. Damaged saved routing throws so MacSync retains its last-good phone projection. `iCloudBridge.publishProviderCatalogStatus` likewise projects provider/model/effort/tier from one frozen snapshot rather than independently rereading picker files; failed reads do not replace or deduplicate away the last accepted status. |
| `NativeClient+ProviderWorkflowGraph.swift` | Provider workflow/graph helpers plus explicit-root surface/provider preference writes |
| `NativeClient+Providers.swift` | Provider/model catalog, OAuth readiness, model preferences, and exact injected auth/cache roots for alternate-runtime construction |
| `NativeClient+RegistryMutations.swift` | Registry-backed runtime mutation helpers |
| `NativeClient+SessionLineage.swift` | Transactional conversation-prefix forks, route/project association, and read-only comparison over canonical chat session/index/JSONL stores |
| `NativeClient+ResearchOps.swift` | SearXNG config/autodetect and research search |
| `NativeClient+RuntimeReadAPIs.swift` | Read-only runtime/dashboard/status endpoints |
| `NativeClient+SchedulerJobActions.swift` | Scheduler job creation |
| `NativeClient+SelfEvolutionApproval.swift` | Self-evolution approval apply/reconcile/verify handling |
| `NativeClient+SkillActions.swift` | Skill registry, manifest/readme reads, enable/disable |
| `NativeClient+SwiftRuntime.swift` | Swift runtime status and health helpers |
| `NativeClient+SystemOpsActions.swift` | Doctor, rebuild, git push, git/process helper, stash recovery |
| `NativeClient+TelegramOps.swift` | Telegram config, test send, and log clearing |
| `NativeClient+ToolDispatch.swift` | Chat tool dispatch wrappers and bridge client helpers |
| `NativeClient+TrainingActions.swift` | Training runs, drills, proposals, promotion staging |
| `NativeClient+TrustBackupOps.swift` | Manifest-v2 trust backup creation and restart-bound restore transaction. Backup membership, sizes, SHA-256 digests, root containment, symlinks, and authority state are checked; destructive restore stages a safety snapshot and resumes apply/rollback before app persistence owners open. |
| `NativeClient+TrustPolicyActions.swift` | Trust, multimodal, Mac-control, Full Mac duration policy writes |

`NativeClient+ApprovalExecutors.swift` owns generic/misc approval resolution only. Memory repair/kind-backfill approval handling lives in `NativeClient+MemoryApprovalExecutors.swift`; self-evolution approval apply/reconcile/verify handling lives in `NativeClient+SelfEvolutionApproval.swift`.

`BackgroundLoopsAssembly.swift` is the composition manifest. Loop families live in `BackgroundLoopsAssembly+*.swift`; do not hide new long-running loops elsewhere.

`NativeAgentCore.BackgroundLoopsManager` is the sole owner of loop lifecycle, execution, single-flight state, counters, status, and live uptime. The app-side facade assembles dependencies and delegates to Core; it must not keep a second scheduler, uptime clock, or status ledger. Periodic ticks and opportunistic OS wakes pass through the same per-loop single-flight gate. An OS wake checks the scheduler's durable last-run cadence before the gate and again while holding it; a not-due wake is health-neutral and advances no counter or clock, while `runTickOnce` remains the explicit force-run diagnostic path. Targeted Telegram or Slack reload replaces only that surface's registration and preserves sibling tasks and counters. Registration replacement drains the retired execution gate to authoritative idle even if the administrative caller is cancelled, so a fresh gate cannot overlap an old effecting body. Event-driven loops carry per-loop stream-listener liveness state in the same manager: a dead listener is visible in status and restarted through the manager's own pending-restart handle, never by a second watchdog. App termination starts Activity Watch's Sendable watcher drain before the bounded main-thread join; it never queues the drain onto the MainActor that the join is about to block.

| File | Owns |
|---|---|
| `BackgroundLoopsAssembly+Autonomy.swift` | Autonomy/proactive/self-improvement loop wiring |
| `BackgroundLoopsAssembly+ChatSurfaces.swift` | Telegram, Slack, and iCloud/iOS chat-surface loop wiring; each long-lived surface registration reuses one client with that exact surface profile rather than reconstructing the full chat factory per turn |
| `SlackSocketModeLoop.swift` / `SlackInboundDeliveryJournal.swift` | Slack claims admitted payloads durably before ACK, prepares reply artifacts before dispatch, and recovers once at the canonical tick start even when Socket Mode cannot open. The journal is atomically published with creation-time 0600 permissions; it retains 500 completed deliveries and never evicts the at-most-100 pending/unknown rows. Interrupted generation and ambiguous sends do not automatically replay. Complete channel/thread history may prove one matching metadata/fingerprint/bot reply; absence is not non-delivery proof, and ambiguous image completion remains explicit. `NativeClient+LocalAPI` projects durable recovery/capacity counts into the existing Connectors `runtimeStatus`/`runtimeDetail` line independently of a healthy socket heartbeat, without exposing message bodies or changing credential/tool authority. Capacity requires human recovery, not automatic deletion or resend. |
| `BackgroundLoopsAssembly+DeskNotify.swift` | Desk-side push loop when a tracked item changes (idempotent, no cognition) |
| `BackgroundLoopsAssembly+UnconfiguredLane.swift` | Registered `.skipped` placeholders for unconfigured lanes so dormancy is visible to Doctor instead of a lane silently not existing (C8) |
| `BackgroundLoopsAssembly+GitHubTracking.swift` | Event/deadline-driven persisted-scope GitHub refresh. Exact tracking config/snapshot, Desk base/tail, and GitHub Command base/tail changes wake a coalesced reread; `GitHubConnector` projects the learned canonical next-refresh crossing, and the six-hour periodic interval is missed-event repair only. Contribution mode circulates only authenticated authored PRs plus their linked issues into deduplicated Desk refs/items, archives prior snapshot-owned rows that leave scope, and preserves closed PR snapshot history. Before delta carry it batches authoritative GraphQL mergeability across every open authored PR because base movement does not bump PR timestamps and REST may remain unknown; conflicting, changed, or indeterminate results force exact detail, while only PRs needing detail consume review-thread reads. New non-bot external PR conversation comments after the prior detail boundary are actionable without replaying history. The shared check classifier keeps executable CI failures actionable but treats a failing maintainer review-label gate plus its aggregate as maintainer-owned waiting when every executable check passes. |
| `BackgroundLoopsAssembly+DreamsMemory.swift` | Dream, REM, memory hygiene, and consolidation loop wiring |
| `BackgroundLoopsAssembly+Heartbeat.swift` | Heartbeat, watchdog, app-health, and self-healing loop wiring |
| `BackgroundLoopsAssembly+Maintenance.swift` | Snapshot, inbox cleanup, receipt, and maintenance loop wiring |
| `BackgroundLoopsAssembly+TriggerScheduler.swift` | TriggerScheduler due-deadline owner: canonical trigger file invalidations and exact next-fire deadlines wake one bounded due-job pass; no periodic trigger sweep |
| `BackgroundLoopsAssembly+WorkshopExecution.swift` | Workshop multi-step execution, approval staging, and due-trigger runner wiring |
| `BackgroundLoopsAssembly+Cognition.swift` | Manual/diagnostic microcycle factory plus production maintenance, daily replay integrity fallback, and budgeted reflection loop wiring; the 30-second microcycle is not in the production manifest because runtime events coalesce dirty settlement directly, and canonical Dream/REM commits wake replay directly |
| `BackgroundLoopsAssembly+Workshop.swift` | Organism-gated Desk Workshop pump, durable lease/reservation, bounded restricted-session wiring, exact Desk daily-cap prefiltering, and generation-based suppression of its own watched-file echoes |
| `BackgroundLoopsAssembly+Delegation.swift` | DelegationOutcomeLoop wiring: ordered cursor-tracked outcomes for delegated builder jobs, including OMP. Routine successful outcomes share one active informational rollup per bridge source so the inbox cannot become a completion ledger; failed, unknown, lost-delivery, stalled, recovered, and backlog states retain exact per-job/sticky identity. Open jobs consume `DelegationStatusProjector`'s existing stalled verdict, file one actionable stuck-step card at the exact recorded liveness crossing, and resolve that same row if liveness resumes without replaying or replacing work. OMP stdout/stderr observations persist into the existing claim-checked wake-job record while its process runs, so active output moves that crossing before evaluation and true silence still crosses `idleSeconds`. The cursor records the OUTCOME each terminal job was carded under, so a codex job carded "finished" while its POST was in flight re-cards as "outcome is unconfirmed" once the bridge preserves it under `reply-jobs/undelivered/`, plus ONE rolling "Codex: N undelivered replies preserved (oldest Xd)" card that re-files only on change and marks itself read when the directory empties — nothing re-delivers those replies by design. The Codex wake helper separately owns unretryable intake: it retains the full brief in a locked/bounded dead-letter ledger and projects terminal failure onto the exact unread inbox row; launch recovery reconciles older receipts without consuming or replaying them. Scans page through bursts beyond 100 without skipping older failures, preserve stable card/push identity, wake from canonical invalidation or the next exact stall deadline with slow missed-event repair, and map OMP through its own adapter rather than a universal bus. |
| `BackgroundLoopsAssembly+Studio.swift` | Studio wander lane wiring: the agent's own hour in the studio, gated like every other background-cognition lane |

`SchedulerDueJobRunner.swift` is the due-job actor shell and `runDueJobs` entry. Scheduler behavior is split by responsibility:

| File | Owns |
|---|---|
| `SchedulerDueJobRunner+Selection.swift` | Due-row selection, default job repair, dream receipt backfill, and durable stable-occurrence claim before effects; ambiguous surviving claims never replay blindly. Every path uses the same checked locked jobs read: only a missing file is empty genesis, while unreadable, malformed, or non-array authority fails closed and is never repaired into empty state. |
| `SchedulerDueJobRunner+Execution.swift` | `notify`, `connector_action`, `dream`, and `rem` execution |
| `SchedulerDueJobRunner+Persistence.swift` | Exact-claim settlement, job row updates, activity receipts, and notification inbox writes; recurring ambiguous occurrences advance while one-shot ambiguity parks for review. |
| `SchedulerDueJobRunner+CycleHelpers.swift` | Dream/REM scheduling and inbox-message helpers |
| `SchedulerDueJobRunner+ProactiveScan.swift` | Scheduled proactive-scan inbox surfacing adapter |
| `SchedulerDueJobRunner+Timeout.swift` | Per-job timeout table and race primitive. A timed-out pass stops admitting later effects, and the enclosing single-flight gate remains occupied until the non-cooperative child actually exits. |
| `NativeAppSecretRedactor.swift` | App-only Telegram-token and local-home privacy extensions layered after the canonical `PersistenceCore.NativeAgentSecretRedactor` credential contract |

Dream-cycle constants/policy live in `NativeAgentDreamCycleSupport.swift`; scheduled proactive-scan evaluation lives in `NativeAgentScheduledProactiveScan.swift`.

`PersistenceCore/OncePerPeriodReservation.swift` is the dependency-neutral
cross-process reservation primitive for low-rate work such as weekly REM. It
locks read/freshness/stamp as one boundary and can compare-restore only its own
unchanged stamp; lock/read/UTF-8/write uncertainty fails closed before any
provider or artifact effect.

`NativeOAuthFlow.swift` is the provider OAuth entry and provider-id normalization shell. OAuth behavior is split by responsibility:

| File | Owns |
|---|---|
| `NativeOAuthFlow+XAI.swift` | xAI OAuth discovery, loopback browser flow, token exchange/persistence |
| `NativeOAuthFlow+Slack.swift` | Slack pasted-token save, `auth.test`, Socket Mode token persistence |
| `NativeOAuthFlow+GitHub.swift` | GitHub PAT Keychain save/load through `GitHubCredentialStore`, `/user` validation, connector registry connection marking |
| `NativeOAuthFlow+Connectors.swift` | X/Gmail/Calendar PKCE loopback flow and owner-only token persistence |
| `NativeOAuthFlow+ConnectorCredentials.swift` | Operator-owned OAuth app credentials and validated Notion integration-token persistence |
| `NativeOAuthFlow+SessionRunner.swift` | `ASWebAuthenticationSession`, callback fallback, callback parsing |
| `NativeOAuthFlow+TokenStatus.swift` | Sign-out, expiry/status checks, provider token paths |
| `NativeOAuthFlow+Configs.swift` | Provider and connector OAuth catalogs |
| `NativeOAuthFlow+Helpers.swift` | PKCE, JSON file IO, JWT expiry parsing, redaction helpers |
| `NativeOAuthFlow+Loopback.swift` | Local OAuth callback listener helpers for direct browser flows |

OAuth callback state lives in `NativeOAuthCallbackRegistry.swift`, generic
session support lives in `NativeOAuthSessionSupport.swift`, and xAI plus cloud
connectors reuse `NativeOAuthLoopbackCallbackServer.swift`.

The iOS `ContentView.swift` owns the five primary tabs: Chat, Activity,
Memories, Desk, and More. `MobileDeskView` is the fourth primary destination;
`AdvancedView.swift` keeps the combined `SkillsToolsView` reachable from More,
and launch/notification aliases route through that same tab contract.

`MacSyncEngine.swift` is the iCloud bridge state shell. Keep mutable bridge state there; put behavior in the focused extensions:

| File | Owns |
|---|---|
| `MacSyncEngine+Lifecycle.swift` | attach/start/stop, setup directories, slow missed-event integrity fallback, one payload-free subscription that republishes bounded cognition/Organism transition snapshots to iPhone, and one observer of the existing canonical chat-completion edge. Lifecycle epochs fence late writes, state replacement, and publication across stop/restart. Completion bursts coalesce for 180 ms into a sessions/pins/transcripts-only demand retained across an already-running pass; create/auto-create/rename/archive/pin/unpin mutations publish session state immediately, with no idle poll or unrelated heavy rebuild. A checked live CloudKit transport starts the local rebuildable projection directly; the legacy Drive root is mounted only when CloudKit is unavailable or KVS is explicitly selected. |
| `MacSyncEngine+Storage.swift` | processed-id/digest persistence, transactions, coordinated iCloud file helpers, pruning/KVS sweep |
| `MacSyncEngine+Security.swift` | pairing secret cache, HMAC signing/validation, rejection responses |
| `MacSyncEngine+Snapshots.swift` | snapshot fan-in/write, pinned chats/transcripts, targeted sessions-plus-transcript publication, native snapshot byte helpers, and the iOS living-status projection. The living-status wire shape is one value-only `NativeAgentShared` DTO used by the Mac writer and iOS reader; organism authority remains Mac-owned. Transcript demand compiles no unrelated catalog, Knowledge Graph, run, or provider projection. Its `needsUser` bit is derived only from exact nonterminal Desk rows explicitly waiting on the owner; organism trouble, reflex review, and generic blocked work remain separate `needsAttention` state. If canonical Desk cannot be read, the composite living-status snapshot is retained rather than overwritten with invented calm/action truth. |
| `MacSyncEngine+Inbox.swift` | KVS/query callbacks, inbox file claiming/validation/dispatch/archival |
| `MacSyncEngine+Notifications.swift` | paired-device notification relay facade |
| `MacSyncEngine+NeedsUserNotify.swift` | one-shot needs-user APNS edge detection with stable SHA-256 identity; durable dedup advances only after successful delivery and retries failures across ticks/restarts. Its caller admits only explicit owner-waiting Desk rows; approval lanes notify independently, while generic blocks and body caution cannot generate needs-user APNS. The persisted private filename remains stable for installed-state continuity; notification wording resolves the configured profile name. |
| `MacPinnedChatSessionStore.swift` | single Mac mutation/codec seam for the ordered pinned-session IDs; publishes the reactive `@AppStorage` value and the matching retention-protection mirror together so Mac UI, retention, and iOS snapshots cannot define pins independently |
| `MacSyncActionRouter.swift` | iOS remote action policy/dispatch |
| `MacSyncRemoteMacControl.swift` | iOS-triggered Mac-control transport/policy |
| `MacSyncMobileNotificationRelay.swift` | push-token persistence plus APNS/iCloud notification fanout |
| `MacSyncInboxAction.swift` | iOS-compatible inbox wire struct |
| `SignedPeerEvidence.swift` | latest authenticated iOS contact receipt derived only after signed chat/action HMAC and freshness validation; body reachability must not derive from configuration-file timestamps |

`PairingSecretManager` plus signed iCloud/MacSync HMAC validation is the only
mobile pairing owner. The retired unsigned `mobile/pairing.json` token surface
does not exist and must not be recreated or used as organism/body evidence.
Remote message and transaction identifiers must be canonical UUIDs before any
path or state derivation, and every derived URL must remain an exact child of
its owned directory. Invalid CloudKit actions create no derived file state.
`push_tokens.json` remains APNS token authority; processed inbox artifacts are
never a token fallback. CloudKit transport construction requires both the
service entitlement and the exact case-sensitive container grant.
On an unpaired iOS launch, `PairingView` must bind its authoritative
`PairingStore` to both `iCloudSyncEngine` and `iCloudBridge` before the bridge
starts draining CloudKit. This preserves automatic same-account pairing even
when the Mac record is already waiting; manual secret entry remains a recovery
path, not the normal setup flow.

`MacAppleScriptBridge.swift` is the AppleScript bridge namespace only.

`NativeAgentShared/DeviceEventIdentity.swift` owns payload-free notification event identity across Mac APNS/iCloud fanout and iOS snapshot-local presentation. APNS collapse IDs, bridge metadata, Inbox/Approval/Workshop local notifications, and delivery receipts carry the same bounded digest when they represent the same semantic event; the iOS presentation gate checks pending/delivered requests before adding another local alert.

Repeated informational notifications may collapse only through the
producer-declared, stable-key API on `LiveNotificationInbox`; important,
actionable, archived, dismissed, and unrelated rows retain their individual
identity. The heartbeat's durable-residue projection is one bounded review
card derived from residual workflow run-state rows (history only since the
run engine retired 2026-09-01), preserved Codex replies, and old Desk
items. It never resumes, replays, deletes, or mutates those canonical owners.

`NativeAgentShared/CloudKitDeviceTransport.swift` owns the exact private-database
query-subscription contract. Subscriptions are user-level CloudKit objects, not
role-level device objects, so Mac and iPhone converge on one ID per record
type: `NAChatMessage.incoming`, `NANotification.visible`,
`NAPairingDevice.changes`, and `NAStatus.changes`. Registration must fetch
before create and may treat a
failed create as an idempotent race only when an authoritative refetch proves
the exact row exists. A production/schema rejection is never equivalent to
“already subscribed.” Legacy role-suffixed IDs are accepted only as exact push
compatibility values and are not authored by current builds. Successful idle
pulls slide an established durable cursor forward with the existing 30-second
overlap instead of repeatedly querying from the last historical record;
rejected delivery still pins the cursor before the rejected row.
Pull high-watermarks always advance in memory. Quiet empty-pull cursor writes
are throttled to five minutes; record progress and halt boundaries persist
immediately. APNS registration changes the missed-push repair drain from eight
seconds to five minutes, while missing/failed registration keeps eight-second
repair. Only recognized NativeAgent subscription pushes trigger the existing
single-flight drain, so sync is push-first but never push-dependent.

Retention is owned by the Mac and by nothing else. `NAChatMessage` and
`NANotification` records are deleted once their SERVER modificationDate is more
than fourteen days old, in bounded batches of a hundred per record type, at most
once an hour — once a minute while the query page still comes back full (there
is more of the collection to walk), so a first sweep clears an accumulated
backlog in hours rather than weeks; the iPhone never deletes. The sweep is
triggered by the Mac drain cadence but runs BESIDE the drain, in its own
single-flight task at low priority after the drain releases its flag, so a slow
or timing-out sweep never delays message delivery.
Eligibility does not ask whether the phone drained the record — a phone offline
that long resyncs from the Mac transcript snapshot, which is the source of
truth. The sweep reads the oldest page first (the same modificationDate order
the pull uses, falling back to `createdAt` order on a container whose
`___modTime` index is not sortable) and fetches no user fields. In that fallback
order the page is not sorted by the eligibility clock, so the sweep keeps an
in-memory server cursor per record type and walks past the records each page
already examined, restarting the walk only when a page comes back empty;
otherwise the same hundred ineligible records would be re-read on every sweep
and nothing would ever be deleted. A send that a stable id turns into an exact
replay re-saves the server record unchanged, so the record's retention clock
restarts and a replay is never swept away moments after the caller was told the
send succeeded. A delete batch whose wait times out may still have been applied
by the server: the log reports the confirmed count and says that batch's count
is unknown. Pairing and status records are overwritten singletons and are never
swept. No subscription fires on record deletion, so a sweep sends the phone no
pushes.

Silent `content-available` pushes remain the event-driven sync trigger for
ordinary `NAChatMessage` records, but Apple may coalesce them and they are not
delivery proof for a user alert. Explicit notifications are therefore written
as `NANotification` records and match only `NANotification.visible`, whose
localization-backed title and body are presented by iOS without granting the
app background execution. The ordinary `NAChatMessage.incoming` subscription
stays broad and schema-independent for legacy and mixed-version chat wakeups,
but the two subscriptions cannot overlap because their record types differ.
iOS registers the visual subscription before silent chat sync and retires the
old overlapping `NAChatMessage.notifications.visible` subscription on upgrade.
This is the credential-free public notification path for users signed into the
same iCloud account; direct APNS is an optional private/self-hosted parallel
route, not a public-service dependency.
The record retains the signed `BridgeMessage` as authority; the visible
projection carries only title, screen, and canonical event identity. After the
visual subscription is authoritatively registered, the later record drain
absorbs the signed outcome without scheduling a second local notification.
CloudKit permits no more than three `desiredKeys`; the visual contract uses
exactly screen, event identity, and kind while title/body travel through
localization arguments. iOS publishes an exact versioned capability status
only after registration succeeds and retries it on foreground activation.
Mac eligibility receipts consume that paired-phone status rather than
reconstructing readiness from Mac-side CloudKit configuration.

| File | Owns |
|---|---|
| `MacAppleScriptBridge+Mail.swift` | Apple Mail read/send/search AppleScript actions |
| `MacAppleScriptBridge+MessagesNotes.swift` | Messages and Notes AppleScript actions |
| `MacAppleScriptBridge+Music.swift` | Apple Music now-playing/search/library/player AppleScript actions |
| `MacAppleScriptBridge+Runtime.swift` | Shared executor, envelopes, escaping, input coercion, and record parsers |

`NativeAgentPaths.swift` owns data/persona root resolution and public first-run blank-slate quarantine. `NativeAgentPublicSafety.swift` owns pure public-safe launch predicates used by runtime defaults.

| File | Responsibility |
| --- | --- |
| `DeskView.swift` | Desk view state, composition, interaction, and refresh. |
| `DeskLanePresentation.swift` | Desk lane availability, attention ordering, callback failure copy, and GitHub portfolio presentation values used by the Desk view. |
| `SlackSocketModeLoop.swift` | Socket lifecycle, inbound/outbound handling, and Slack transport coordination. |
| `SlackSocketModeSupport.swift` | Slack conversation cache, history watermarks, delivery deduplication, socket health, bounded handler lifecycle, and injected transport adapters. |
| `SlackRuntimeDiagnostics.swift` | Checked Slack runtime-state reads and patches plus bounded receipt/error feed persistence and projections. |
| `SlackSocketModeConfig.swift` | Slack transport configuration decoding and shared pure ingress decisions. |
| `SlackSessionStore.swift` | Slack conversation-to-chat session mapping and locked canonical session-row creation. |

`ChatView.swift` remains the main chat composition view. Its session rail is session-first: the title row carries only the existing compact health signal, followed immediately by session search and the pinned/recent list. Global running-work and aggregate Today panels are intentionally not composed into Chat; their canonical state and actions remain owned by Activity, Desk, health, and their underlying read models. `ChatQueuedTurnsView.swift` is the shared main/detached Mac projection of the per-session send-next queue. Enter remains an acceptance action while a turn is active: the message is held in a bounded 20-item in-memory FIFO and does not become transcript/provider context until its execution starts. Natural completion drains the next turn, ordinary Stop pauses the queue, and Steer promotes a selected turn before ordered cancellation and restart. The drain-start gate is part of the transaction boundary so a new Enter cannot overtake a queued turn while that turn is being started. Scroll-follow behavior and toast queue/dedupe state live in `ChatViewStateCoordinators.swift`; Markdown transcript export lives in `ChatExportService.swift`; clipboard and attachment type utilities live in `ChatClipboardAndAttachmentSupport.swift`.

Chat submission crosses `AppModel.startActiveChatTurn` as an acceptance boundary: the composer clears only after the selected session accepted the turn, and startup/session failures leave the draft and attachments intact. Uncached session selection is likewise transactional in `AppModel+ChatSessions.swift`; only the newest successful load may replace the active transcript. Main and detached chat both render messages through `ChatMessageListView`, so message, tool, approval, retry, timestamp, copy, and read-aloud behavior has one presentation owner.

Mac transcript search is a temporary projection over that already-loaded message array. It is debounced off the main actor, retains a bounded recent navigation set while reporting the exact matching-message total, and writes no index or transcript state. Main and detached chat share its keyboard commands, result identity, selection highlight, and navigation behavior.

Chat surface helpers belong in focused `ChatView+*.swift` extensions:

| File | Owns |
|---|---|
| `ChatView+PinnedSessions.swift` | Pinned-session row/loading actions |
| `ChatSlashCommandRegistry.swift` | Typed built-in slash-command names, routes, help text, insertion placeholders, and developer-surface visibility |
| `ChatView+SlashCommands.swift` | Slash-command detection and execution against the typed registry; command mutations render their own typed result instead of sampling shared status text |
| `ChatView+ShellColumn.swift` | The conversations column of the new shell: plain-language session rows in place of the machine log, and the latest pill |
| `ChatView+Attachments.swift` | Attachment picking, paste/drop, and preview actions |
| `ChatView+SessionActions.swift` | Session-level UI commands and transcript actions |
| `ChatComposerChrome.swift` | Shared main/detached composer control strip. Voice, screen capture, and attachments live in one compact options menu while Stop and Send remain immediate; each window retains its own transactional draft owner. |
| `MacChatTranscriptSearch.swift` | Bounded view-local transcript search projection, async controller, shared search bar, exact result status, and stable message scroll targets. JSONL and AppModel remain the only transcript/state owners. |
| `LivingStatusPanel.swift` | Retained aggregate organism/Desk/approval/dream read model and reusable global-status presentation. Main Chat intentionally does not compose this dashboard panel; the canonical Activity, Desk, approval, health, and cognition owners remain unchanged. The internal `needsUser` state (rendered as "needs you") is reserved for canonical pending approvals or nonterminal Desk rows whose exact waiting party is `owner`, `user`, or `human`; failed verification, generic blocks, provider/tool caution, phone/resource trouble, and reflex review remain visible as `no action needed` attention. The panel refreshes from the existing Desk/approval/file and cognition invalidations. |
| `DeskLiveReloader.swift` | Event-driven Desk invalidation merge: process-local store tokens plus kqueue file watching, trailing-edge coalescing, visibility gating, reload timing receipts, and one replaceable exact presentation deadline for Desk Live Activity's five-minute stale / thirty-minute expiry boundaries. The deadline produces one ordinary dirty edge; it is not a polling cadence. |

`CognitionObservatoryView.swift` owns the Advanced sidebar view for default-off CognitiveSubstrate controls, Organism Kernel visibility/toggle, metrics, capsule preview, reflection receipts, schema proposals, standing views, and the developmental timeline. The never-produced resident identity-proposal family and never-called external-grounding/promotion island are retired. Legacy `identity_proposal` SQLite artifacts and timeline enum values remain decode/preservation compatibility only; store open and runtime restore do not delete or promote those historical bytes.

MemoryV2 storage separates persistence from its value contracts and recall scoring:

| File | Owns |
|---|---|
| `MemoryV2+Storage.swift` | MemoryStorage actor and stored state, canonical memory CRUD, projection hooks and retention bounds. |
| `MemoryStorage+Tombstones.swift` | Tombstone writes, exact and semantic matching, and embedding backfill on MemoryStorage. |
| `MemoryStorage+Codecs.swift` | Existing storage row/embedding/metadata codecs, temporal validation, hashing and scalar helpers. |
| `MemoryStorage+Integrity.swift` | Semantic integrity audit, canonical projection fingerprint, and verified SQLite backups on the existing MemoryStorage actor. |
| `MemoryStorage+Proposals.swift` | Proposal staging, acceptance, rejection, atomic corroboration merge, status and metadata updates, and proposal readers on MemoryStorage. |
| `MemoryStorage+Recall.swift` | Same-actor recall cache reads and invalidation, hybrid and keyword ranking, nearest-neighbor queries, and result deduplication |
| `MemoryStorage+EmbeddingEpoch.swift` | Canonical embedding corpus snapshots, frozen copies, epoch activation and rollback transactions, and writable epoch checks on MemoryStorage |
| `MemoryStorage+Migrations.swift` | MemoryStorage SQLite migration declarations and exact-shape ledgerless graph-store adoption; initialization remains in the actor file. |
| `MemoryV2+ConsolidationGate.swift` | Approval-gated consolidation orchestration, lock ownership, reconciliation, swap sequencing, and derived projections. |
| `MemoryConsolidationGateContracts.swift` | Consolidation diff, staging/swap outcomes, gate errors, and live derived-projection dependencies. |
| `MemoryV2+ConsolidationStorageSupport.swift` | Consolidation paths, committed-swap marker lookup, candidate cleanup, payload fields, and timestamp helpers. |
| `MemoryConsolidationGate+Receipts.swift` | Consolidation manifests, receipts, maintenance-health projection, approval staging/annotation and inbox-card publication on the existing gate. |
| `MemoryConsolidationGate+Database.swift` | Existing transactional table swap, backup retention, content fingerprints and before/after diff reads, extracted without changing SQL or ordering. |
| `MemoryStorageModels.swift` | Memory storage records, lifecycle/default constants, patches, errors, and embedding epoch value contracts |
| `MemoryV2Contracts.swift` | Recall request/response and proposal value types, patch contracts, storage capability protocols, and their default implementations. |
| `MemoryV2+Wiring.swift` | Storage-backed SwiftNativeMemoryV2 memory writes, duplicate provenance, tombstone lookup and shared value helpers. The retained in-memory fixture lives in `InMemoryMemoryStorage.swift`. |
| `MemoryV2+Recall.swift` | Same-actor recall, disclosure-filtered record lookup, access-signal recording and persona-starvation diagnostics; complete method bodies moved without changing ranking or filtering. |
| `MemoryV2+Proposals.swift` | Same-actor proposal staging, acceptance, reviewed-moment acceptance, rejection and proposal readers; complete method bodies moved without changing merge or promotion behavior. |
| `InMemoryMemoryStorage.swift` | Public in-memory MemoryStorageProtocol fixture, moved unchanged out of production operation wiring; retained for its test callers. |
| `MemoryRecallScoring.swift` | Recall tunables, timestamp parsing, decay, diversity selection, and lexical scoring |
| `KnowledgeGraph+MemoryIndexing.swift` | Canonical-memory KG index scheduling, rebuilds, fact/entity/relationship SQL and schema completion. |
| `KnowledgeGraph+PrimaryUserIndexing.swift` | Primary-user identity resolution, alias projection, consolidation and upsert SQL on the canonical-memory KG indexer. |
| `KnowledgeGraph+CanonicalRebuild.swift` | Canonical memory-derived graph rebuild and bounded missing-row backfill, with the indexer and foreign-writer provenance ownership sets. |
| `SwiftNativeKnowledgeGraphIndexer+EntityExtraction.swift` | Deterministic memory entity extraction, tagged-name credibility, term matching, name normalization and vocabulary constants; extraction bodies and thresholds are unchanged. |

`KnowledgeGraphView.swift` is the KnowledgeGraph screen composition surface. Keep graph view state/filtering there and put supporting owners in the focused files:

| File | Owns |
|---|---|
| `KnowledgeGraphStatusHeader.swift` | Native KG stack status probe and header |
| `KnowledgeGraphModels.swift` | KG UI response/entity/edge/search models |
| `KnowledgeGraphView+Maintenance.swift` | Load/enable/GC/forget actions |
| `KnowledgeGraphRows.swift` | Entity/detail/edge rows |
| `KGGraphCanvas.swift` | Graph canvas rendering |

## iOS Companion Map

`NativeAgentSharedTestSupport` contains the in-memory device cloud and transport
used by Shared, Mac, and iPhone tests. Only test targets depend on this product;
the production apps keep `NativeAgentShared` and its live CloudKit transport.

Signed provider-selection success carries a complete canonical surface/provider/model/effort/tier receipt through `iCloudSyncEngine+Actions` into Chat and Providers. Incomplete or wrong-surface receipts cannot supply defaults. Only the still-current request generation may adopt the recovered tuple, including Mac normalization; older replies preserve newer/ABA selections. The existing snapshot confirmation fence compares against that canonical tuple rather than the optimistic request, so stale projections cannot undo success and a normalized choice cannot remain permanently unacknowledged. Providers' success text names the returned model.

`iOS/NativeAgentMobile/Sources/iCloudSyncEngine.swift` owns iCloud sync state only. `iCloudSyncEngine+Setup.swift` owns setup and the rebuildable CloudKit snapshot/action cache, `iCloudSyncEngine+Snapshots.swift` owns lifecycle-fenced group routing/refresh/loaders, and `iCloudSyncEngine+Actions.swift` owns signed inbox actions, response polling, and Mac-control/provider mutation helpers. `MacSyncEngine` remains the sole snapshot compiler and action dispatcher. Public Developer ID builds carry its exact established snapshot files in five bounded, compressed, digest-checked `NAStatus` groups because they cannot use the Mac-App-Store-only CloudDocuments/KVS lane; CloudKit and KVS group signals enter one exact router and iOS atomically adopts those bytes into a local cache without creating another model or authority owner. Once the entitlement-checked CloudKit transport is live, neither app mounts or scans the legacy Drive data plane; KVS remains only a best-effort progress/resync nudge, and a failed CloudKit factory or explicit KVS selection retains the complete legacy path. Signed public action envelopes and responses reuse `BridgeMessage` CloudKit transport, but still pass the inner action HMAC/freshness, exact idempotency, TrustCenter/router, transaction receipt, and signed-response boundaries. The mobile inbox projection is active-first and bounded to 300 total rows, 200 active rows, and 384 KiB; truncation, write, publication, signal, and oversize failure are visible rather than advancing false freshness. A response is durably cached before CloudKit acknowledgement so retry resends evidence rather than repeating an effect. Partial multi-file refreshes preserve last-proven values and cannot advance full-sync freshness. Mac and iPhone use the same `NativeAgentIdentity` pure formatter over their already-authoritative profile projection; the helper owns no identity storage or sync and supplies only bounded configured-name display plus a neutral fallback.

`iOS/NativeAgentMobile/Sources/ChatStore.swift` owns observable chat state and cached-session helpers only. The app scene owns exactly one `ChatStore`; a view recreation cannot become a second queue restorer. Behavior lives in `ChatStore+Sending.swift`, `ChatStore+Sessions.swift`, `ChatStore+SnapshotMerge.swift`, `ChatStore+ICloudReplies.swift`, `ChatStore+Typewriter.swift`, and `ChatStore+Refresh.swift`. iOS mirrors the Mac send-next contract with a bounded, visible, session-owned, relaunch-persistent FIFO: natural completion drains it; Stop pauses it; Steer retires the old reply correlations, awaits signed Mac cancellation, and only then runs the promoted turn so late cancellation/final replies cannot stop or overwrite the replacement. Cached transcripts use a session-stamped envelope; a corrupt exact cache fails empty and refreshes from the Mac, and an unowned legacy global cache can never fill a pinned session. A phone-created main session also persists a provisional identity until a signed Mac event or the published session list acknowledges that exact id; lagging snapshots therefore cannot erase a new chat or stamp its first send with the previous main session. Chat no longer runs a five-second session poll: published sessions, pins, and changed transcript groups trigger a targeted read and exact-visible-session merge. That merge preserves pending user rows, active streaming placeholders and tool events, and composer input. Already-visible Chat, Workshop, Memory, Runs, Turn Inspector, approval, and inbox-badge stores consume the sync engine's publications directly; only the explicit legacy transport keeps a sampled activity fallback. While a reply is outstanding and on explicit refresh/foreground events, iOS still drains the active transport; it never checks the retired Drive outbox when CloudKit is selected and adds no idle polling. Transcript retention includes one exact Mac main session, one canonical `mobile_app` main session, and pinned sessions; legacy `source == ios` rows are accepted and migrated rather than becoming a second owner. Closing a pinned phone tab sends the signed `unpinChatSession` action, mutates the Mac-owned pin list, and republishes the snapshot without deleting or archiving the conversation. If another surface removes the selected pin, the next authoritative snapshot retires its pending correlations and returns the phone to its main chat.

## Core Runtime Map

| Mobile chat file | Owns |
|---|---|
| `iOS/NativeAgentMobile/Sources/NativeAgentMobileApp.swift` | App scene, launch arguments, and notification navigation intent |
| `iOS/NativeAgentMobile/Sources/MobilePushNotifications.swift` | Push token synchronization cache, APNS environment, remote push processing and completion gate, notification delegates and scheduling |
| `iOS/NativeAgentMobile/Sources/MacToolsView.swift` | Mac Tools screen, remote action cards and session ledger |
| `iOS/NativeAgentMobile/Sources/MacToolsPresentation.swift` | Mac quick-action execution and policy, privilege, notification, volume, shortcut and Spotlight presentation helpers |
| `iOS/NativeAgentMobile/Sources/InboxView.swift` | Mobile inbox store, list, cards, and detail surface |
| `iOS/NativeAgentMobile/Sources/InboxModels.swift` | Inbox wire records, decoding, action vocabulary, and notification burst presentation |
| `iOS/NativeAgentMobile/Sources/ChatView.swift` | Chat view composition and its private issue banner |
| `iOS/NativeAgentMobile/Sources/ChatPresentation.swift` | Chat control decisions, snapshot preference adoption, scroll scheduling, and attachment/voice presentation values |
| `iOS/NativeAgentMobile/Sources/AdvancedView.swift` | More, status, and run screens plus the observable health/run store |
| `iOS/NativeAgentMobile/Sources/AdvancedPresentation.swift` | Pure run, organism, health, and connection presentation models |

`Modules/NativeAgentCore` owns the Swift runtime modules:

Shared core formatting:

| File | Owns |
|---|---|
| `NativeTimestampFormat.swift` | Stateless timestamp rendering for the existing fractional-Z, fractional-UTC-offset, and six-digit-UTC-offset wire formats, plus UTC-day formatting and distinct default-first/fractional-first ISO date parsing; preserves caller-selected precision, suffix, and parser order without shared mutable formatters. |

PersistenceCore source boundaries:

| File | Owns |
|---|---|
| `PersistenceCore.swift` | Persistence protocol, native file I/O, factory, and unique append transaction |
| `JSONValue.swift` | JSON value representation, Python-compatible byte serialization, and Codable conformance |
| `JSONLRetention.swift` | JSONL retention budgets, capped append transactions, and path-owned retention policy |
| `PersistenceDataRoot.swift` | Data-root resolution, repository validation, and sandbox repository-root resolution |
| `DeskStore.swift` | Desk append-under-lock transactions and live-state memo |
| `DeskStore+Reduction.swift` | Pure Desk op replay, alias ordering, and per-item retention |
| `DeskStoreRecords.swift` | Desk errors, compaction records, and base-plus-tail feed representation |
| `DeskModels.swift` | Desk item, reference, pursuit, archive, and derived state value types |
| `DeskClock.swift` | Shared Desk/TaskLedger UTC formatting and Desk monotonic timestamp/identity helpers |
| `DeskOperations.swift` | Desk mutation vocabulary and tolerant operation JSON codec |
| `GitHubCommandStore.swift` | GitHub command transactions, private op encoding, replay, and live-state memo |
| `GitHubCommandModels.swift` | GitHub command public evidence, state, receipt, and error value types |
| `ProcedureCompilation.swift` | Payload-free trajectory extraction, reviewed candidate admission, and declarative artifact compilation |
| `ProcedureReplay.swift` | Pure historical replay and current-state dry-run checks with their context and result types |
| `CompiledToolProcedure.swift` | Repeated tool sequence shapes, declarative procedure compilation, skill-body rendering, and JSON round-trip |

| Module | Owns |
|---|---|
| `ChatOrchestration` | Turn engine, session history, turn planning, context assembly, tool loop, dispatch wrappers, same-turn lazy schema refresh, provider-facing tool-result ceilings with turn-scoped recovery paging, dispatch watchdogs, and exact no-progress recovery. One checked admission freezes provider/model/effort/tier for the accepted turn; central streaming/non-streaming paths, budget/compaction decisions, and actual completion/transcript accounting reuse that tuple rather than mixing routing generations. Canonical user persistence, cognition ingestion, and the compaction check finish before ordinary preparation fans out; deterministic turn planning and one frozen cognition/organism projection may then overlap unchanged Fluid Context/history assembly and active-tool/schema reads. The joined projection remains turn-scoped and commits only after entering provider input; this overlap introduces no cache or authority owner. `NaturalExpressionGuidance` is small prompt tissue inside this existing owner, not a personality subsystem: one positive identity-neutral sentence follows the compiled persona in the stable cached prefix, while a bounded pure scan of the six newest assistant rows may stage one unnamed response-shape cue. The existing turn plan admits that temporary cue only for chat/personality conversation, consumes it for task routes, and a single constructor option removes both additions without touching persona, memory, cognition, or transcript state. It performs no model call, persistence, output rewriting, provider override, or vocabulary ban. `ContextBudgetPolicy` is the single source of truth for prompt-assembly character budgets: budgets use a verified exact provider/model window when known (including the exact-root live OpenRouter catalog cache) and otherwise keep the conservative shipped floor; windows at or below 32k tokens stay byte-identical to those floors, and absolute ceilings are sized so the worst-case derived ask provably fits the smallest catalog-gated window because no post-assembly provider input clamp exists. In the floor regime Dynamic Context remains 6,000 characters; the shared turn engine permits one coordinator-owned retry only for authoritative mandatory overflow, bounded at the ranked-packet expanded budget (24,000 at the floor) with ranked-context reserve, so accumulated explicit corrections do not force the much larger legacy reconstruction path and strict callers still fail closed. The same admission compiles route-owned closed tool-group readiness with lexical hints and the exact surface policy before the first provider call; it changes request-scoped schemas only, never durable tool activation or authority. |
| `Context` | Rebuildable immutable context generations, required-document mirrors, bounded RAM arena, generation-checked cancellation-safe event coalescing, owner-selective projection invalidation, eligibility/ranking, feedback/prewarm, and generation-pinned expansion. `ContextSelector` is the sole live ranker; feedback utility/decay may reorder privacy-eligible peers but cannot bypass privacy. Cancellation is control flow rather than source degradation. MemoryV2 and Desk/Workshop projections remain derived reads; canonical stores and TrustCenter retain authority. |
| `PersistenceCore` | Canonical append-only local stores plus the single exact eight-pattern digest-bearing secret-redaction contract for durable receipts/activity and the shared non-digest chat/Turn Inspector preview contract, bounded store invalidation tokens, vnode file watching, a bounded `FileChangeEvents` async bridge with one registration-race read, visibility-aware reload debouncing for live projections, and bounded asynchronous TurnTrace emission/persistence pumps. Its canonical Python-compatible JSON serializer appends without repeatedly counting the accumulated Unicode string, keeping large derived projections linear while preserving exact bytes. Shared JSONL caps support stat-first soft byte triggers: authority owners may keep every append synchronous and durable while amortizing locked exact-line rotation instead of rereading a growing ledger on every write. The path-owned JSONL registry is the sole append chokepoint for the shared legacy `traces/events.jsonl` ledger and `harness/benchmark/runs.jsonl`, so callers cannot select a conflicting cap or bypass the common flock. Its installed-physiology store is observational evidence only: bounded daily JSONL/rotation and pure reporting, with no prompt/action/permission authority or scheduler. In measurement epoch `resident-live-latency-v3`, event rows require live/system/debug/verification class and separate total, substrate, somatic, and residual-scheduling admission latency. Live+system form the production resident population; live alone forms the ordinary population; diagnostics remain auditable but excluded. Resident and ordinary admission/microcycle populations each require twenty samples and fail at 25 ms or above; ordinary chat latency independently requires twenty live samples. The multi-day gate also rejects retention saturation, quiet CPU at or above 0.5%, and process wake rate at or above 18,000/hour. A fresh compatible `runtime_started` row opens the epoch, retaining older evidence without mixing it into current latency/restart claims. Recorder durability timeout becomes an explicit blocker rather than an unbounded shutdown wait. `HumanPresenceStamp.swift` is the shared value/codec for `<dataRoot>/activity_watch/last_input.json` and for the `presence_transition.json` beside it: the ActivityWatch tick publishes the last input it can attribute to a person, and the trigger scheduler reads it synchronously from inside its flock, so an idle trigger can measure absence from the Mac without either side opening the walled-off spans database. The stamp carries two timestamps and an away flag and no app identity whatever, which is exactly why the watcher keeps refreshing it while the person works in a privacy-excluded app: it records that there was human input at time T, never what produced it. Reads are stat-first, so only a regular file of at most 4 KiB is opened inside that flock. Absent, unparseable, oversized, or stale (older than five minutes) reads as unknown, never as absence, and a `written_at` more than five seconds ahead of the reader is a moved clock and reads as unknown too. A lock or sleep edge writes one final away-marked stamp and then nothing until the person is back, so locked counts as away from the lock instant and that one stamp is believed for as long as it stands. The transition file is touched only on a present-to-away or away-to-present crossing, so a background loop can watch it without waking once a minute for the stamp. Both files go through the canonical 0600 temp-and-rename atomic writer. |
| `Onboarding` | First-run identity/persona creation and reset. Completion is a resumable exact manifest transaction with persona/profile targets first and sentinel last. Public runtime safety treats a pending profile-before-sentinel manifest as incomplete; the narrow legacy compatibility read requires a valid local profile plus every required persona document. Reset has its own exact phased manifest: byte-preserving backups are written and reverified before source removal, completion markers clear only after cleanup, and reset intent clears last. Start/complete/resume reconcile an interrupted reset before exposing or creating onboarding state. |
| `CognitiveSubstrate` | Experimental/default-off active cognitive state infrastructure: bounded events, continuity field, SQLite snapshot/restore, workspace, capsule preview, affect, thought seeds, replay references, reflection receipts, and observatory read model (commitment/prediction task-tracking removed 2026-07-01 — the subconscious is feelings/views/continuity, not a task tracker). Affect and thought-seed reads settle analytically at the requested instant. `CognitiveFrozenRead` captures configuration, workspace, affect, mood, thought seeds, standing-view text, and Sound echo as one immutable evaluation epoch; ordinary chat compiles from that epoch at the same fixed time as its organism projection. Sound's duty-cycled self-exemplar and verbal-rut awareness are bounded local reads over this frozen/in-memory assistant history: first and closing edges can produce an unnamed range cue, while quoted content is excluded; the lane adds no provider call or durable owner and never bans vocabulary or rewrites output. Continuity owns rebuildable derived token and defensive-turn-kind indexes, so activation/workspace reads do not repeatedly reclassify every node from prose. Thought-seed score/decay/cap changes replace the exact persisted family and apply protected-family retention in one SQLite transaction. Resident sensory ingestion mutates bounded owner state but defers durability to the coalesced microcycle; that microcycle and larger maintenance use the existing canonical transaction for nodes, seed replacement, affect/ambient settlement, receipts, and pruning. Full maintenance additionally owns emotional consolidation, stale standing views, and lineage; all live mutators serialize at that transition boundary. |
| `ProviderRouting` | OpenAI/Anthropic/Codex/xAI/Moonshot/OpenRouter model routing and streaming adapters. Direct ChatGPT OAuth uses one shared accepted Codex-backend client identity across ordinary, streaming, structured-tool, OAuth authorization, and image-generation paths while retaining the NativeAgent build version in its User-Agent. Its SSE decoder accepts legacy and current nested error envelopes; explicit pre-output capacity failures may retry once without refreshing a healthy token, while any assistant/tool output closes that replay window. Account-backed Codex and direct ChatGPT OAuth expose exact `gpt-6-astra` controls (Low–Ultra, Medium default, Fast/priority); the API-key OpenAI catalog withholds Astra until its tool lane speaks Responses instead of Chat Completions. Moonshot owns authenticated live Kimi discovery, K3 Max reasoning, hidden-reasoning preservation through tool loops, streaming, tools, and vision without borrowing another provider's identity or credentials. OpenRouter carries structured image/tool/tool-result messages and streamed tool calls; its discovered capability/context cache is truthful and exact-root, with static verified fallback only. Surface provider+model preferences publish through one pending-marker recovery transaction without folding distinct API/OAuth/MCP siblings; `ProviderRoutingSnapshot` is the checked reconciled read consumed once at every central provider dispatch boundary, and Mac current-state/configuration delegates to that Core owner. GPT-5.6 Sol remains the canonical account default and exact persisted GPT-5.5 routes normalize forward at the execution boundary. |
| `ProviderRouting.swift` | Canonical provider registry and recoverable surface-routing transaction actor, including shared model-to-provider inference |
| `ProviderRoutingContracts.swift` | Provider and surface DTOs, checked routing snapshot, protocol defaults, and canonical/legacy surface-key lookup |
| `ChatCompletionsMessageEncoding.swift` | Shared text/image/tool-use/tool-result wire encoding for OpenAI, OpenRouter, Moonshot, and xAI, with optional Moonshot reasoning replay |
| `LLMClient+OpenAIResponsesDecoding.swift` | Buffered OpenAI OAuth Responses SSE parsing, usage and terminal-state capture, tool markers, and incomplete-response notes |
| `LLMClient+AnthropicOAuthDirectAdapter.swift` | Anthropic OAuth credential refresh, request execution, SSE decoding and telemetry |
| `LLMClient+AnthropicOAuthRequestBody.swift` | Anthropic OAuth request-body encoding, system/tool/conversation cache placement and request-scoped cache hints |
| `LLMClient+OpenAIOAuthDirectAdapter.swift` | OpenAI OAuth request/stream execution, provider errors, and serialized token refresh |
| `LLMClient+OpenAIOAuthCredentials.swift` | OpenAI OAuth credential discovery, CLI adoption consent, atomic credential storage, JWT claims and account identity |
| `MemoryV2` | SQLite memory store, shared candidate-quality gate, narrow structured-fact auto-save, review proposals, BM25/dense recall with ordinary-fact room ahead of excess skill discovery hints, KG indexing, USER.md projection, and Fluid Context projection source. One resolver supplies the single actor and `MemoryStorage` for the production default root; explicitly injected alternate roots receive isolated owners and never enter a process-wide registry. The generated USER.md body renders only active, recall-eligible, durable memories whose kind is in the person-kind allowlist and excludes `workshop:`-prefixed operational sources, so the identity document stays about the person rather than the runtime's work notes. A purely generated USER body is suppressed from dynamic Context only with exact healthy MemoryV2 parity; manual or malformed content fails back to normal selection. `MemoryStorage` owns the hard 2,000-row canonical bound: direct inserts, proposal acceptance, approved consolidation swaps, and legacy store-open repair prune inside the SQLite write boundary, then retract evicted rows from derived projections and write bounded retention receipts. Approved consolidation is terminal only after retryable canonical rebuild of USER.md, Spotlight, MemoryV2-owned KG claims, and Fluid Context invalidation. |
| `KnowledgeGraph` | SQLite graph/query owner plus exact MemoryV2-derived rebuild: corrected canonical facts and index-version changes retract prior indexer-owned entities, relations, provenance, and index rows, and a rebuild keeps a row only when a writer claims it: an indexer stamp, or a known foreign writer's provenance (studio journal, growth distillation, and the one-time legacy import, which stamps every row it lands). Unclaimed unstamped nodes and edges are daemon-era residue and are dropped. One stable primary-person role reads canonical onboarding `userName` once per index/rebuild/GC operation, exposes generic role labels as aliases, and narrowly consolidates exact legacy role duplicates without inferring identity from prose. Derived counts reset before replay. The deterministic extractor treats inline list markers as sentence boundaries, rejects grammatical negation and acronym-inflected verb fragments, and classifies Apple as an organization without a model call or frequency gate; source-backed facts and meaningful proper/domain concepts remain searchable. A present SQLite graph is the sole read/mutation owner and authoritative even when empty; unreadable SQLite fails closed. Mac panels, chat/MCP tools, and Mac-produced iOS snapshots use checked queries or a bounded complete projection. Legacy JSON is read/mutated only when SQLite is genuinely missing, with one-time import owned by the SQLite loader. |
| `TrustCenter` | Trust policy, SecurityCenter, capability source/root catalogs, strict local signing-key validation, tool risk/autonomy profiles, and canonical normalized conversation-surface classification shared by policy/planning/approval paths. Each authorization consumes one immutable checked snapshot containing normalized policy and raw overrides from the same bytes at one captured time. Policy patches, autonomy promotion, and Full Mac expiry intent commit through the same checked locked mutation owner. Only missing saved authority may bootstrap defaults; existing corrupt authority remains byte-preserved, unavailable, and fail-closed. SecurityCenter evaluates every tool call and synchronously appends its redacted receipt, applying the injection-argument redactor before building that preview so `keystroke.text` / `ax_act.value` — ordinary-looking strings its generic secret heuristics do not catch — cannot land in the audit ledger even when a caller hands it a raw body; its 20,000-row audit cap uses PersistenceCore's 32 MiB stat-first trigger and locked newest-row trim so accumulated history does not impose an O(file) scan on every dispatch. |
| `MacControl` | Full Mac gate, app/file/system control policy helpers, and the shared parent-owned subprocess seam for app commands and builder wake helpers: event-driven termination, concurrent bounded pipe draining, off-wait-path stdin, exact working directory/environment, cancellation, and process-tree timeout escalation. `MacAccessibilityReader.swift` is the read-only accessibility perception organ: it reads the frontmost window's `AXUIElement` tree as structured data (role, subrole, title, value, enabled, frame, advertised AX actions, child-index path) under hard 400-node / depth-12 / 200-character bounds that a caller can lower but never raise, and reports truncation with its reasons and a floor count of unseen elements rather than dropping silently. It performs no input synthesis and no AX mutation — no `CGEvent`, no `AXUIElementPerformAction`, no attribute writes — and its element access is an injectable seam so the caps and ranking are pinned without a window server. Its `ax_status`/`ax_tree`/`ax_find` sub-actions are Swift-native reads with no retired-daemon ancestor, so they live in `macControlAccessibilityReadActions` (and `macControlDispatchableActions`) rather than the daemon-parity inventory, gated under the existing `accessibility` category at read tier. `MacAccessibilityActuator.swift` is the separate ACT organ (W2/W3) and the only file in the module that synthesizes input or mutates another app's UI: the `MacKeySyntax` grammar resolving human chord specs (`cmd+shift+4`, `return`, raw `key:<n>`) to virtual keycodes with malformed specs refused whole rather than partially executed, the `MacEventSink` seam whose production `CGEventSink` posts key/mouse/scroll events at the HID tap, and the `MacAXActSource` seam whose production `SystemMacAXActSource` resolves a child-index path to a live element and runs `AXUIElementPerformAction` / `AXUIElementSetAttributeValue`. `ax_act` prefers the element's own advertised AX action so the app runs its real handler, falls back to a synthesized click at the frame centre only when no usable action exists and names which mechanism fired, and returns a re-read post-state that is offered as evidence to check rather than claimed as settlement. Its `keystroke`/`click` sub-actions moved from `macControlUnsupportedActions` into `macControlNativePortedActions` leaving the daemon-parity union unchanged, while the ancestor-less `scroll`/`ax_act` live in `macControlAccessibilityActActions`. Every action in `macControlAccessibilityInjectionActions` must clear three gates before an event is emitted: the accessibility category, an ACTIVE Full Mac trust window, and a `MacInjectionCapability` presented on the separate `dispatchApprovedInjection(action:body:capability:)` entry point. The capability replaces the earlier in-band `__mac_injection_approved` body key, which anything able to write a dictionary key could mint: it has a private init so it cannot be written as a literal, no `Decodable` conformance so it cannot arrive off-process, and it binds one action to a SHA-256 digest of the exact approved body under a two-minute TTL, consumed once through `MacInjectionCapabilityLedger` so a captured capability cannot be replayed. The unprivileged `dispatch(action:body:)` refuses every injection action by signature rather than by remembering to strip a key, which is what closes the HTTP/iOS-remote bridge, direct library callers, and raw dispatcher instantiations in one move; `MacControlClient` defaults the privileged method to a refusal so a new conformer cannot acquire injection by omission. `MacInjectionArgRedaction` reduces secret-bearing arguments (`keystroke.text`, `ax_act.value`) to `{character_count, sha256}` at every persistence and emission boundary, with the literal characters held only in the in-memory TTL'd `MacInjectionSecretVault` keyed by approval id — a lost replay after a restart is preferred to a typed password landing in a `remoteResolvable` approval record. `MacInjectionResultRedaction` is its RESULT-side counterpart: a value-carrying `ax_act` re-reads the field it wrote, so `element.value` and `post_state.value` are reduced to count+digest at the handler and again at each downstream preview boundary, while a press keeps its readable post-state. `MacInjectionApprovalDigest` binds an approval RECORD to the redacted body the human was shown, the counterpart to the capability's digest over the body that actually runs. `MacInjectionToolNames.clampedAutonomyLevel` is the single vocabulary and the hard approval floor applied after all autonomy resolution. `MacScreenView.swift` is the W3.5 FUSED VIEW organ — the answer to "most computer use is a screenshot and then you guess a coordinate": it pairs one ScreenCaptureKit screenshot with the read organ's AX walk in a single frozen scene, numbers every actionable or scrollable element with a marker drawn at its real frame, and returns a legend binding each number to that element's role, label, frame and true child-index path, so acting happens by REFERENCE (`mac_click{mark, view}`, `mac_ax_act{mark, view}`) and never by a model-computed coordinate. It walks no AX tree of its own and contains no CGEvent, `AXUIElementPerformAction`, attribute write or `CGRequestScreenCaptureAccess` call — a structural grep test pins that with the act organ as its positive control. Capture and marker rendering are two injectable seams (`MacScreenCaptureSource`, `MacScreenImageRenderer`), so the coordinate translation, the mark cap, the PNG byte ladder and the legend are pinned with no window server: `MacScreenViewGeometry` DERIVES its scale from the pixel count that actually came back divided by the requested point rect (never `backingScaleFactor`, which disagrees whenever a capture is clamped, mirrored, scaled or straddles a 1x and a 2x display) and carries x and y independently. `CGWindowListCreateImage` is not an option — it is obsoleted as of macOS 15 and does not compile. Screen Recording is a SEPARATE TCC grant from Accessibility, read-only preflighted and reported honestly: with Accessibility alone the numbered legend still returns and names the missing grant, with Screen Recording alone the raw picture returns for the canvas/game/video case, and the residual pairing gap between the two perceptions is reported as `fusion_gap_ms` rather than claimed to be zero. Marks are bound to an opaque single-slot `MacScreenViewStore` view id under a three-minute TTL, so a number from any earlier view is refused as `stale_view` rather than reinterpreted against a screen that has changed; a mark GRANTS NOTHING — it resolves to an element path and frame inside a handler the three injection gates already guard, and a secure-text-field value in a legend row is reduced to count+digest by `MacInjectionResultRedaction.redactedSecret`. Its `view` sub-action is read tier in `macControlAccessibilityReadActions`. Redacting only the secure FIELD's value left the wider hole an adversarial review found: a displayed secret — the 2FA code in a banner, a revealed API key, a recovery code under its caption, an app-drawn run of bullets — arrives as static TEXT, so `MacScreenViewTextRedaction` runs inside `visibleText` (at the source, before any caller can build an un-redacted channel) and reduces such a line to `{redacted, reason, character_count, sha256}` in the same digest shape the injection redactors use. It judges SHAPE, never subject matter — a lone 6-8 digit code, a long high-entropy or known-prefixed token, a masked bullet run, a one-line `label: value` whose label names a secret and whose value is a single token, or a code-shaped token sitting immediately right of / below a SHORT secret-naming caption via the same 240-point proximity heuristic the legend uses to name unlabeled controls — because over-redaction blinds the perception organ the wave exists to build: a sentence mentioning a password is prose and stays legible, and a qualified caption (zip, area, promo code) does not darken its neighbour. The same shape test guards legend `label`s and non-secure `value`s, since a `nearby_text` label inherits whatever text sits beside a control. `MacScreenViewResultRedaction` is the sink-side counterpart for the PICTURE: the base64 PNG is correct for the live model call and wrong everywhere downstream, so the trace bus preview, the persisted tool row and the cognitive-event preview strip `image` to `{image_redacted, image_bytes, image_sha256}` keyed by tool name, leaving `image_pixel_size` intact. A second adversarial round found three more paths to the same sink. (1) THE LATER ECHO: `mac_view` serialized each legend row redacted, but `mac_click{mark}` echoed `element.label` straight from the stored mark and `ax_act` echoed `element`/`post_state` from a live AX re-read, so the act tools re-emitted in the clear what the read tool had covered — both now pass through `MacScreenViewTextRedaction.redactedLegendString` / `redactedElementJSON`, which re-run the same standalone shape test over an already-built element object and leave an already-redacted value (an object, not a string) untouched. (2) THE CONTAINER TITLE: the root `AXWindow` is not a text role, so `window_title` never entered `visibleText` and bypassed the source redaction entirely; `mac_view` now runs the same standalone redactor over it. (3) THREE STRUCTURAL BLIND SPOTS in the shape test, each an assumption rather than a missing pattern — a 4-character length floor hid a 3-digit CVV, "a token has no whitespace" hid a card number written `4111 1111 1111 1111`, and an allowed charset of `[A-Za-z0-9-_.]` excluded base64's own `+ / =` — plus a fourth shape never modelled at all, the MULTI-WORD secret. The added detectors carry the guards that keep the organ from going blind, which is the failure mode that matters more: a card number is 13-19 digits AND must satisfy the LUHN checksum, so an order number, an invoice id, a 22-digit tracking number and a phone number stay legible; a base64 token needs a true marker character (`+`, `/`, `=`, which no identifier or English word contains), no `.` or `:` (killing URLs, hostnames and filenames), mixed case with a digit, no same-case alphabetic run over five (which is what separates `Reports/2024/Summary` from encoded bytes) and a Shannon entropy floor; a recovery phrase is a run of >=12 lowercase 3-8 letter words with no capital, no punctuation and no common English function word, dropping to six words only under an explicit seed/recovery/mnemonic caption, so an ordinary twelve-word sentence stays readable; and a CVV — far too short to darken on its own — is redacted only when paired with a caption naming it, by proximity in the text channel, by `label: value` on one line, or by the legend row's own label. The unprefixed high-entropy branch also gained a CamelCase guard, because `NativeAgentCoreBuildNumber42` cleared every existing entropy bar and went dark. `click` refuses a body naming both a `mark` and any coordinate/drag field with a 400 `ambiguous_target`, mirroring `ax_act`'s mark/path conflict: the approval digest binds the whole body so this was never a bypass, but exactly one target named exactly one way is the property that makes an approval card mean what it says. A third round closed the SIBLING organ: `mac_ax_tree` and `mac_ax_find` read the SAME screen through the SAME `MacAccessibilityReader` walk and shipped every node `title`/`value` plus `window_title` raw into the identical sinks — turn trace, persisted tool row, cognitive-event preview, iOS/Telegram sync — on a READ-tier tool that needs no approval, so a displayed 2FA code or revealed key left the machine in the clear even after `mac_view` was covered. `MacScreenViewTextRedaction.redactedNodesJSON` / `redactedMatchesJSON` / `nodeSecretContext` apply the SAME detectors (no new shape is invented; a second copy of the shape logic would drift) at the tool-serialization boundary in `MacControl+Client.swift`, NOT inside the walk — the shared read organ stays byte-identical and injection-free, exactly as `mac_view` redacts in its builder rather than in the AX walk beneath it, and a test pins that `MacAccessibilityReader.walk` still returns the raw strings. A node's own `title` acts as the caption for its `value` (the "CVV" box showing `123`), and the positional 240-point cone is fed by a context built from the WHOLE snapshot rather than the matched set, so an `ax_find` for text fields still sees the `AXStaticText` caption its query excluded. `role`, `subrole`, `enabled`, `frame`, `actions`, `path` and `score` survive redaction untouched: where a control is and that it is pressable is not a secret, and a dark node must stay fully addressable or the organ cannot be acted on. Reusing the detectors whole also inherits their false positives — a token-shaped string within 240 points to the right of a secret caption darkens even when that caption does not name it — A fourth round closed the last caption geometry and the last echo. Every caption rule before it asked only whether a secret-naming caption sat to the LEFT of or ABOVE a value, which is not how a real card form is built: an `AXGroup` titled "CVV" ENCLOSES an untitled `AXTextField` whose `451` is not secret-shaped on its own, so it rode out raw on `ax_tree`, `ax_find` and the `mac_view` legend alike. `MacScreenViewTextRedaction.enclosingCaptions` / `enclosingKinds` add that third geometry — an ancestor by child-index PATH PREFIX whose frame also CONTAINS the value — feeding the same existing vocabulary and the same existing shape detectors into the node redactor, the legend row and the prose channel. Because an enclosing caption darkens a whole SUBTREE rather than one value, it clears a stricter bar than the beside-geometry keeps: the secret word must match as a WORD and not a substring (a group titled "Shipping" contains "pin" and a shipping section is not a secret), the root `AXWindow` is never a caption (it encloses everything, so a window titled "Recovery Code" would blank the screen; its title is judged on its own shape instead), a caption naming ordinary structure ("Payment", "Toolbar", "Account") leaves its children fully legible, and the value must still carry a secret SHAPE — a "New Tab" button inside a group titled "Password" keeps its label. Separately, `ax_find` echoed the caller's own `query` back raw, so a model that read a code off the screen and then searched for it (`mac_ax_find{value: "482913"}`) put that code into the same traced/persisted/synced result the read path had just covered; the echo now passes `title`/`value` through the same standalone shape test, leaving an ordinary query ("Send") and the AX role constant legible so the echo stays useful. W6 adds `wake`, the smallest injection in the module and the answer to a screen Agent could see but not get past: an idle Mac shows a NON-LOCKED screensaver with `loginwindow` frontmost, so `mac_view` returned the saver and every act landed on it. `wake` posts a one-point mouse move and back through the SAME `MacEventSink` at the SAME HID tap (optionally a left-shift tap, off by default — a modifier alone inserts no character), waits a bounded settle, and then returns the `view` output FLATTENED plus a `wake` block, so the caller lands on the real screen in one call and the result inherits mac_view's source redaction and image stripping instead of opening a second screen-read channel — `MacScreenViewResultRedaction.viewToolNames` names it for exactly that reason. It is in `macControlAccessibilityInjectionActions`, not the read set: the tier follows the emission, never the payload. Its own refusal is the safety line, and an adversarial review found the first version of it inverted: `CGSSessionScreenIsLocked` is 1 during an ORDINARY screensaver as well as a password lock (verified live — the flag was set while `sysadminctl -screenLock status` said `screenLock is off`), and that ambiguity was resolved by PROCEEDING when the idle policy read off, which nudges and photographs a manually locked Mac. `sysadminctl -screenLock status` reads the IDLE policy — "after the screensaver starts, demand a password" — while a screen locked by hand (Ctrl-Cmd-Q, Apple menu ▸ Lock Screen) demands the account password regardless and sets the identical flag, so policy-off plus locked is a manual lock's exact fingerprint rather than a saver's. `MacWakeGuard.refusalReason` therefore FAILS CLOSED: unreadable session ⇒ refuse, foreign console ⇒ refuse, `screenIsLocked` ⇒ refuse whatever the policy says, and only a CLEAR lock flag proceeds. No screensaver-positive branch exists because none is sound — the session dictionary carries no auth flag (dumped live: ScreenIsLocked, ScreenLockedTime, UniqueSessionUUID, AuditID, GroupID, LoginwindowSafeLogin, OnConsole, SystemSafeBoot, UserID, UserName, LoginDone, LongUserName, SecuritySessionID), a running `ScreenSaverEngine` does not exclude a password lock (lock by hand, wait, and the saver starts on top of it) and would need a live subscription to catch a notification a one-shot call already missed, and `CGSSessionScreenLockedTime` against `secondsSinceLastEventType` is a timing heuristic needing a saver delay from a `com.apple.screensaver` domain that does not exist while the setting is off. The cost is accepted deliberately and is narrower than the wave hoped: `mac_wake` now reaches a sleeping display and an unlocked-but-obstructed screen, so a dismissable saver costs the user one mouse movement rather than costing them a nudged and photographed lock. The idle policy survives as reported diagnostics under the honest name `idle_password_policy`, never as permission. The guard runs BEFORE the sink is touched, and AGAIN on the post-nudge re-read before the capture — "not locked" is only true at the instant it was read, and the settle wait is a window in which the screen can lock — so a screen that locks mid-call comes back as a refusal carrying no image, no marks, no text and no view id, neither photographed nor described. The probe is the injectable `MacSessionStateSource` seam — deliberately not the event sink, since the thing that decides whether to post must not be the thing that posts — and its production impl reads the CoreGraphics session dictionary, `CGDisplayIsAsleep` and the frontmost bundle id. Its `isAvailable` reflects a REAL read rather than a hardcoded `true`, and a nil dictionary (or one missing `kCGSSessionOnConsoleKey`) yields `sessionReadable: false` — locked, off-console, unreadable — instead of the old empty dictionary whose per-key defaults silently read back as "unlocked and on console", which was proceeding on no evidence at all. The verdict it publishes is OBSERVED, not asserted: `dismissed` and `verified` come from re-reading the session after the nudge, and `idle_reset` reports whether `secondsSinceLastEventType` fell across it — the orthogonal evidence that the events reached the HID tap rather than being swallowed by a missing Accessibility grant. W7 adds `nudge`, which is the smallest possible version of that same idea and deliberately in NEITHER existing set: it posts ONE bare `mouseMoved` through the same `MacEventSink` — no button, no key, no scroll, no AX mutation, no body, no parameters at all, the destination being the current cursor position plus one point — and returns `{nudged: true}` with a message naming what it cannot do. It is not in `macControlAccessibilityReadActions` because it does post a CGEvent and that set's contract is that nothing in it does; it is not in `macControlAccessibilityInjectionActions` because that set is the predicate demanding a `MacInjectionCapability`, and a bare cursor move changes no app state, so there is nothing for a human to approve. Its own `macControlAccessibilityNudgeActions` keeps both of those contracts honest, and the Full Mac pre-flight names it alongside the read set, so the GATE it clears is `mac_ax_status`'s exactly: accessibility category + an ACTIVE Full Mac window + the Accessibility TCC grant and a live sink, no approval filer and no capability — which is the entire point, because a screensaver means nobody is at the keyboard to approve anything and an approval-gated wake tool fails precisely in the case it exists for. It is emphatically not a bypass for `click`/`keystroke`/`ax_act`/`wake`, which keep all three gates: what it buys is a cursor move, and on a locked Mac the most that achieves is showing the login field, exactly like a human bumping the mouse — which is also why it needs no lock probe and never touches `MacSessionStateSource`. The move-only property is structural rather than promised: one call site, no branch a caller can steer, and `MacNudgeToolTests` inspects the events the sink ACTUALLY received and fails on any key, any scroll, or any `down`/`up`/`drag` phase, with a body full of click/keystroke fields proven to change nothing about what is emitted. Verification is `unverified` and it claims no motor owner in `ToolCausalBoundary`: it observes no outcome and sets no effect a domain owner could later be asked to prove settled. `MacPerceptionCompiler.swift` is native-look item 2, the PERCEPTION COMPILER answering NORTHSTAR clause 5 for the screen: `mac_ax_tree` hands the model a tree and asks it to be the eyes, while this compiles the SAME `MacAXTreeSnapshot` — no second walker exists — into three GRADES of attention. `glance` is ONE line under 220 characters (app, window title, control census, focus, MODAL when a sheet or dialog is up, the first labeled buttons); `look` is the structured percept — window, focus, modal, landmarks (toolbar/sidebar/table/list/scrollarea/webarea/sheet/dialog/tabgroup, depth <=6, <=12) and every LABELED interactive control (<=60) with role, subrole, `label_source` (`title` or `value` — the fused view's `nearby_text` inference is deliberately NOT run here, since it needs capture geometry a look does not take), redacted value, enabled state, child-index path and a stable HANDLE; `stare` DELEGATES to `handleAXTree` so the full-tree payload can never drift from `mac_ax_tree`'s, pinned by a test asserting every key is equal. The spike measured the price on User's real apps (bytes stare/look/glance): Mail 9,586/877/140, Finder 43,861/625/102, Hermes (Electron, 1,200 nodes) 79,328/2,069/126 — a look is 10-70x cheaper than a stare and a glance 100-400x. The HANDLE is a fingerprint, not a path: ancestor chain of `role:label` (label capped at 24 chars) plus the element's own `role/subrole/title`, FNV-1a hashed (never `Hasher`, which is per-process SEEDED — determinism across launches is the contract) to six base36 characters, with an ORDINAL among same-token elements in document order (`h7k2q1`, `h7k2q1.2`). Child indices and VALUES are excluded on purpose: indices are what make paths fragile, and a popup button reading "Medium" then "Large" is the same control, which is why the fingerprint's label component is the TITLE even when the percept displays a value-derived label. Grouping ordinals by rendered TOKEN rather than by fingerprint makes a hash collision a disambiguated pair instead of a silent merge, and every affordance still carries its `path` as the resolve fallback and for `mac_ax_act`/`mac_click` compatibility. Interactive elements with NO label are COUNTED BY ROLE under `unlabeled`, never hidden — Finder's toolbar is 19% labeled and pretending the rest are absent is how "the third button" becomes the wrong button — and the look JSON is hard-capped at 6 KB by dropping affordance rows from the END and REPORTING it as `affordances_truncated`, never by silently shipping a shorter list. Redaction is not re-invented: labels, values, the window title and the modal's label all ride out through `MacScreenViewTextRedaction.redactedLegendString` / `MacInjectionResultRedaction.redactedSecret`, the exact path the `mac_view` legend uses, and the GLANCE omits any segment whose text is itself secret-shaped rather than being the laxer channel. `AXSecureTextField` is in the interactive role set (a login sheet's one control would otherwise be invisible to a look) with its value as count+digest. `MacLookFrameStore` is the task-scoped perceptual frame, modelled on `MacScreenViewStore` and carrying the same three properties: SINGLE SLOT, a 180 s TTL, and NO AUTHORITY — `resolve(handle:frameId:now:)` returns a path and rect or one of four named failures (`no_frame`/`stale_frame`/`frame_expired`/`unknown_handle`) each with guidance, and every gate the injection tools clear still runs upstream of any verb that consults it. `MacChromiumAccessibility` is the live seam for the Chromium/Electron family, which ships its web tree to the accessibility API only once told a screen reader is present: a known bundle id (Chrome, Claude, VS Code, Slack, Spotify, Discord, Notion, Figma, Obsidian) or a window that exposes no `AXWebArea`, stays under a shell-sized node count AND contains no interactive element at all (that last clause is load-bearing — without it a 12-node Mail compose window matched and the flag would have been set on native apps) causes both `AXEnhancedUserInterface` and `AXManualAccessibility` to be set on the APP element, after which a missing web area is polled for up to 4 s at 500 ms and the window re-walked EXACTLY once. Chrome's setter returns `kAXErrorCannotComplete` and the flag still takes effect, so the status is discarded and only the READ-BACK is reported. This is the one `AXUIElementSetAttributeValue` in the perception path and it deliberately lives in this file, leaving `MacAccessibilityReader.swift`'s no-attribute-writes contract intact; what it writes is the target app's accessibility MODE, not any UI state. The flag is left set for the frame's lifetime and cleared LAZILY at the next look whose frontmost app differs or whose frame has expired — never by a timer, which would be exactly the resident background thing the plan forbids. Focus is reported only when the source can tell: `MacAXElementSource.focusedElementPath()` defaults to nil and the live source computes it by walking the `AXParent` chain up from `kAXFocusedUIElement` to the window root, because an invented focus is a look that lies about the cursor. Its `look` sub-action is read tier in `macControlAccessibilityReadActions`, gated `accessibility`, verification `satisfied`, no approval and no motor owner. `MacActClosedLoop.swift` is native-look item 3, the CLOSED LOOP that turns the three model turns a computer-use step costs today (look, act, look again — only the middle one a decision) into ONE call: `mac_act {handle, frame_id, verb}` resolves the handle through `MacLookFrameStore`, re-resolves the path through the ACTUATOR's own `resolve` (never a second resolver), installs an `AXObserver` on the target app for twelve notification kinds BEFORE performing, runs the verb, waits for the first notification plus an 80 ms quiet window to collect the sibling burst, then re-compiles the SAME look percept and DIFFS it against the frame the agent acted from — returning what changed, a fresh `frame_id` and a one-line glance in the same result. The observer is the injectable `MacAXEffectObserverSource` seam (production `SystemMacAXEffectObserverSource`, a real `AXObserver` sourced on the MAIN run loop and created/removed on `MacAXExecutionLane`; tests a fake with scripted notifications and COUNTED installs/removals), and `MacAXEffectObserverGuard` removes it exactly once from every exit — success, refusal, timeout, an unwinding cancellation — with a `deinit` backstop. Only the notification KIND and timestamp are kept: a notification's userInfo can carry the changed value, and this result rides the trace, the operation store and the iOS/Telegram sync. NOTHING OBSERVED IS A REAL ANSWER, reported as `observed: false` with `reason: none_observed` (or `observer_unavailable` when no observer could be installed) rather than as a failure or an optimistic "acted" — the whole point is that the model never has to look again. The DRIFT GUARD is the safety line: a frame is up to 180 s old and a handle is a REFERENCE, not a lease, so if the live element's role — or its label, when the frame recorded one, read title-then-value exactly as the compiler read it — no longer matches, the call refuses with `handle_drifted` NAMING what is there now, because "press Save" pressing "Delete" is the worst failure this organ has. Six verbs, all through existing mechanisms and no new event poster: `click`/`select`/`toggle` are `MacAccessibilityActuator.act` at AXPress (inheriting its synthesized-click fallback and its honest `method`), `type` sets the value directly and falls back to focus-then-`MacEventPlanner.typeText` through the same sink `mac_keystroke` uses, `dismiss` presses the modal's OWN Cancel/Close/Dismiss/Done/OK button found in the current frame and scoped by PATH PREFIX to the modal (a window behind a sheet often has its own Close) preferring the least destructive answer, falling back to the element's `AXCancel` and failing loud with `no_dismiss_target` when neither exists, and `scroll` is `AXScrollToVisible` or the existing wheel path at the element's centre. The actuator gained one parameter for this — `act(resolved:)` — so the element the drift guard CHECKED is the element that gets pressed rather than a second resolve that could land elsewhere. `wait_ms` defaults to 300 (ten times the spike's measured 30-32 ms) and is HARD-capped at 2000. `act` is in `macControlAccessibilityInjectionActions`, not the read set, for the same reason `wake` is: the tier follows what a tool DOES, and read tier for it would have been a bypass with a percept stapled on — it clears the accessibility category, an ACTIVE Full Mac window and a body-bound single-use `MacInjectionCapability`, binds a `macControl` motor owner, redacts `text` as `{character_count, sha256}` through `MacInjectionArgRedaction`, and publishes `verified: false` because an observed effect is evidence the caller judges, not proof the intended consequence happened. |
| `MacAXAttributeRead.swift` | Shared nil-tolerant raw accessibility attribute, element, action-list and complete-frame reads for the system perception and actuation sources. |
| `MacControl+ClosedLoopAction.swift` | Closed-loop action request validation, live target resolution, effect dispatch and observed-result verification; client admission and lifecycle remain in `MacControl+Client.swift`. |
| `MacControl+MenusAndClipboard.swift` | Menu target selection, menu reading/pressing, and clipboard read/write handlers; client dispatch and admission remain in `MacControl+Client.swift`. |
| `MacFourVerbs+Navigation.swift` | The go verb, web/file/named-folder destination resolution, bounded landing observation, and landing-failure replies; screen, act, wait, and shared sighting remain in `MacFourVerbs.swift`. |
| `MacActReceiptRendering.swift` | Pure post-act readout selection, element redaction, bulk-effect summary and effect-diff JSON rendering; extracted from `MacControl+Client.swift` without changing execution or verification. |
| `MacControl+OperationSupport.swift` | Lock-owned in-flight execution signals/registry and pure operation result attachment, replay, cancellation, timeout and verification mapping; dispatch, policy and lifecycle transitions remain in the client. |
| `MacFourVerbs+TargetResolution.swift` | Pure observed-target matching by name, role, ordinal and motion identity, plus safe aim-point and visible-region geometry; observation budgets and dispatch remain in `MacFourVerbs.swift`. |
| `MacFourVerbs+PerceptReconstruction.swift` | Pure reconstruction of redacted look JSON, row/control partitioning, supplemental evidence fusion and JSON value readers; observation and dispatch remain in `MacFourVerbs.swift`. |
| `MacFourVerbs+ScreenPresentation.swift` | Pure screen zoom/scoping, row budget and reply wording; acquisition, action and wait execution remain in `MacFourVerbs.swift`. |
| `MacControl+Perception.swift` | `SwiftNativeMacControl` document/screen reads, anchored AX snapshots, look/tree/find, fused views, and attention handlers; mechanical extension of the client with the same actor isolation and effect-time checks. |
| `MacControl+SystemActions.swift` | `SwiftNativeMacControl` file read/write/list/move/trash, AppleScript, app focus/quit/open, Spotlight, and shell handlers; the client retains dispatch and effect-time policy checks. |
| `MCPDispatcher` | MCP registry, live stdio/http calls, strict consent authority, subprocess pool, and value-only `MCPInvocationOutcome` normalization. Only a missing consent ledger is empty; existing unreadable, malformed, duplicate, or oversized authority fails closed before list/grant/revoke and is never rewritten as empty. Raw and one adapter-wrapped protocol errors share one transport interpretation without claiming external effect settlement. |
| `WorkflowOrchestration` | Workflow REGISTRY only: list and create workflow definitions in `workflows/registry.json` under the shared flock, with the built-in defaults merged over saved overrides and the activity/trace save receipts. The workflow RUN engine was RETIRED 2026-09-01 (User authorized) — run/resume/cancel/rollback, the v1 and v2 step executors, `workflows/run_state`, the run ledger, run-control preflight, execution preflight, and the run motor projection are gone, along with every UI control that drove them. `workflows/runs.jsonl` and `run_state/*.json` remain on disk as history and are read by nothing. The approvals half is a different module (`ApprovalInbox`) and is unaffected; the live successor for doing work is Workshop execution. |
| `WorkshopExecution` | Workshop-owned multi-step execution engine for user-directed tasks: planner, checkpoints, executor, Desk lifecycle bridge, storage migration, and unified outcome scoreboard. `WorkshopCompiledLocalFileCopyProcedure.swift` is a value-only deterministic planner target for one locally reviewed read/write shape. Manual invocation is admitted inside `ProcedureArtifactStore.invokeManual`; `WorkshopCompiledProcedureInvocationExecutor` then accepts only the exact planned artifact/contract with zero provider accounting, canonical timeline replay, checked TrustCenter policy, and domain-owned motor verification. Workshop remains the executor, Desk the task owner, ApprovalInbox the review authority, and the procedure store the artifact/receipt owner. Stable caller keys bind idempotency to artifact, paths, and exact bounded source bytes. Resident-runner races are observed through vnode-backed `FileChangeEvents`, not polling. After at least twelve distinct canonical verified zero-provider invocations, an immutable local-only ApprovalInbox decision may install one exact implementation-bound active pointer. `workshop_submit(operation: copy_workspace_file)` consults that pointer only for the unambiguous typed operation; ambiguity, absent/stale/corrupt activation, or pre-admission mismatch falls back to ordinary Workshop, while an admitted invocation never duplicates the effect. The pointer lock spans canonical consequence, and deleting only that pointer restores ordinary routing. This is not a prose router, permission grant, scheduler, generated executable, or general learned selector, and it adds no work to ordinary chat unless Workshop is explicitly invoked. A completed child closes its Desk commitment only with domain-owned `satisfied` verification; unverified completion remains blocked awaiting canonical verification without recruiting a model. |
| `WorkshopExecution+OutcomeVerification.swift` | Completed-execution text criteria, exact file-byte readback, and neutral-tool classification; queue ownership, approvals, step dispatch, and terminal settlement remain in the executor. |
| `TriggerScheduler` | Canonical trigger/job state plus source invalidations and exact next-meaningful-deadline projection. App background assembly delegates one Core-owned due-work registration; it does not run a detached minute loop. Time and idle inbox triggers may produce real evidence-backed content; file-watch, execution-completion, and session-pattern placeholder paths remain dormant and reject manual firing until their missing canonical signal/cursor exists. An idle trigger's activity instant is the later of chat quiet (`max(updatedAt)` over `chat/sessions.json`) and the human-presence stamp, so it waits for the person to leave the Mac rather than for the conversation to pause; a missing chat signal still keeps it dark, and a missing or stale presence stamp falls back to chat quiet alone. Its due-work loop watches `activity_watch/presence_transition.json` — the present/away crossing file, deliberately not the per-minute stamp — because once an idle episode has fired the projection returns no next crossing at all, so the person coming back is the event that establishes the next one and it would otherwise reach the loop only on the six-hour integrity tick. |
| `ApprovalInbox+InjectionSpend.swift` | Durable CAS spend marker for Mac injection approvals at `workflows/approvals/injection_spends.json`. `consumeInjectionApproval(id:digest:tool:surface:)` returns `.spent` to exactly one caller ever — the flock around read-check-write is the compare-and-swap, so concurrent tasks and separate processes both spend once. It lives in a sidecar file rather than the record because `ApprovalRecord` round-trips through `init(json:)`/`toJSON()` on every resolve/annotate/archive write and drops unknown keys; an authority bit an ordinary write can erase is not an authority bit. A marker store that exists but cannot be parsed fails closed. Scope is injection tools only — persona/memory recovery replay is untouched. |
| `ApprovalInbox` | Canonical approval safety state and sole row-mutation owner, including execution annotations. Missing storage is an empty inbox; existing unreadable, malformed, non-array, duplicate-ID, or malformed pending-row storage fails closed for list/create/resolve/archive and is never overwritten as empty. Terminal legacy rows remain readable. Remote resolvability is strict: only the closed remote-safe action set (`workflow_step`, `mcp_tool`) may resolve from a non-local surface, hard local-only actions stay local regardless of declared body flags, and an undeclared `localOnly` defaults to local-only unless the action is in that set. Local, verified Telegram, and signed-iOS decisions persist typed resolution provenance, and the remote-authority check occurs under the same lock as the terminal decision. |
| `TelegramBot` | Telegram update models, polling, command/client helpers. Model selection commits the exact provider+model tuple through the canonical surface transaction; legacy xAI/Kimi aliases remain read-compatible without becoming current sibling routes. |
| `SlackConnector` | Slack Web API/socket/history connector with the shared fail-closed ingress policy, Anthropic-compatible text/tool turns, and authenticated `file_share` image hydration capped at four MIME-approved files, 10 MiB each and 20 MiB total before native attachment admission. History polling sleeps until the exact next gap-fill, unhealthy, or safety deadline instead of sampling every ten seconds; successful pings update in-memory health, while failure remains durable and cancels the socket. |
| `SystemOps` | Doctor/readiness/system repair/rebuild/git recovery helpers |
| `DreamREMCycle` | Nightly Dream and REM consolidation runners. One Dream invocation gathers all eligible recent conversations under global byte/message/time bounds and performs one bounded consolidation; no per-session provider-call knob remains. |
| `REMConsolidator.swift` | Weekly REM orchestration, persona and diary context, approval staging, run-report persistence, and REM pin publication. |
| `REMReport.swift` | Weekly REM result counters and durable run-report outcome envelope. |
| `REMPinsReader.swift` | Approved REM pin value, latest-pin selection, and process-local decoded index cache with its existing cache-stat seams. |
| `REMConsolidator+GrowthEviction.swift` | Locked GROWTH eviction, approved-lesson boundaries, distillation, and canonical KG or pre-SQLite legacy graph writes on REMConsolidator. |
| `Skills.swift` | Skills client protocol and local registry/body/history IO, serialized mutations, and mutation activity emission. |
| `SkillsJSON.swift` | Pure skills registry sorting, manifest merge/reshape, JSON convenience and mutation value/string normalization. |
| `SelfImprovement+TrainingPromotion.swift` | Local training-proposal and promotion-stage mutation paths, file locking, ledger updates, and body writes. |
| `SelfImprovement+TrainingReads.swift` | Training/promotion/evaluation readers, caller-facing gate predicates, stored-field projections, and shared journal lookup/coercion helpers. Only a missing saved trust policy receives bootstrap defaults; unreadable or malformed policy denies gates and aborts approval routing. |
| `CommandPalette` | Compact command/search/coordination manifest |
| `GitHubConnector` | Keychain-backed GitHub PAT lifecycle with exact-path plaintext migration, typed REST client, authoritative rate-limit-aware GraphQL review-thread observation, compact provider read projections (`GitHubToolProjection`) for repositories, bounded files/directories, commits, notifications, issues, and pull requests, confirm-gated mutation executor, contribution-scoped project tracking, snapshot cache, Desk reconciliation, and sampled digest |

Desk remains the canonical visible pursuit/project owner; Workshop only reserves
exact Desk work, executes one bounded turn, writes handle-scoped artifacts, and
durably settles that reservation. Refusal/no-op does not consume the lease, and
zero-effect durable repair runs before posture/resource admission so already
completed work heals without another model call. Continuation admits only the
last three Desk receipt summaries plus validated relative artifact references,
all labeled untrusted. Artifact bodies never enter MemoryV2, Fluid Context, or
automatic prompt context; handle-contained `openat`/`O_NOFOLLOW` reads are UTF-8
and capped at 64 KiB. Typed goal satisfaction closes only on verified durable
artifacts plus exact reservation/`expectedUpdatedAt` CAS; otherwise it records
progress. Additive reservation/artifact and workflow recovery fields decode
safely when absent.

### Explicit Mac Attention

`MacAttention.swift` is ephemeral continuity tissue inside `MacControl`, not a
background loop, second agent, memory, or screen-history store. The read-tier
`mac_attention` tool starts one bounded opt-in session, returns the existing
secret-redacted fused `mac_view`, and lets `next` sleep on actual physical-input
or app-activation events before taking exactly one fresh view. It never records
keycodes, modifiers, characters, screenshots, or a timeline; stop, expiry, and
replacement tear down the AppKit observers and forget the session. NativeAgent's
own `CGEvent`s carry a private source tag so the passive observer does not
misclassify the agent's motor output as human intervention.

Physical user input is the takeover authority. It increments an ephemeral user
sequence and invalidates `MacScreenViewStore` immediately. Every Mac motor path
rechecks the active attention session and observed user sequence at effect time,
including between individual events in a gesture; stale work returns
`yielded_to_user` and emits no further effect. Completed motor actions also
retire their frozen view. Drag endpoints are interpolated locally under a hard
step/duration cap, so smooth motion adds no model calls; a mid-drag takeover
posts only the necessary button-up before yielding. `MacScreenViewResultRedaction`
classifies `mac_attention` as an image-bearing fused-view result, preserving the
live picture while stripping it from traces, transcripts, cognitive previews,
and sync sinks exactly like `mac_view` and `mac_wake`. Rollback is immediate:
`mac_attention stop` removes all observers, and deleting the one tool/action
plus `MacAttention.swift` returns the frozen-view behavior without migrating or
repairing any durable state.

## Desk Work Ownership

Desk is the single work surface and owns canonical work identity and lifecycle; the agent's self-directed pursuits and user-directed tasks both appear there. It is the durable system for large-project breakdowns, dependency edges, bridge references, scheduled work, research, approvals, progress receipts, and verified completion. User-directed tasks retain the bounded `WorkshopExecution` multi-step planner/executor as the Desk's directed execution lane rather than being reduced to a one-shot pump job or presented as a separate orchestration product. Terminal execution state is synchronized back to the same Desk item and writes the same compatibility receipt ledger. ContextFlow projects a bounded, secret-checked read of Desk identity/status plus the latest linked child, verification, decision need, and expected evidence. It owns no transitions and rebuilds from exact file events or restart. Completed-but-unverified execution cannot close the Desk commitment.

Active execution state lives under `data/workshop/`: per-task records in `executions/`, trigger configuration/state in `triggers.json` and `trigger_state.json`, legacy flat summaries in `legacy_executions.json`, and unified receipts in `receipts.jsonl`. `WorkshopStorageMigrator` runs synchronously before background loops on launch, moves any remaining `data/missions` state, normalizes migrated absolute receipt pointers, preserves conflicts in a timestamped `data/archive/missions-pre-workshop-*` directory, and writes a migration receipt under `data/workshop/migrations/`. A migration failure aborts startup rather than silently splitting work across two roots. Doctor storage preparation and Trust backups likewise own `workshop`; neither may recreate or back up a live `missions` root.

The old `mission_submit`/`mission_status` chat tools and Missions UI are retired. `workshop_submit` and `workshop_status` remain the supported compatibility wire names for the Desk's execution lane; their schemas explicitly teach the model that Desk is the product and task owner. The de-mission wire migration (2026-08) renamed the persisted vocabulary: the per-task execution file is now `execution.json` (a migrator plus dual-read keeps legacy `mission.json` state loading until its scheduled removal — see `docs/build_plans/` removal schedule), and renamed Codable keys carry old-key readers on the same schedule. A few serialized tokens remain intentionally stable for on-disk/cross-device compatibility: provider/context surface `missions`, trust-policy key `missionPolicy`, approval action `mission.step` with `mission_id`, historical activity kinds such as `mission_complete`, the execution root `data/workshop`, and saved sidebar aliases such as `.workshop` and `.missions`. Treat these as compatibility wire IDs, not current product presentation or separate work owners.

The `CognitiveSubstrate` actor implementation is split by cognitive band (move-only R8b decomposition; all files are `extension CognitiveSubstrate` in the same target):

| File | Owns |
|---|---|
| `CognitiveSubstrate.swift` | Actor declaration, stored state, init/configure/snapshot and presentation state. Shared text/value helpers live in `CognitiveSubstrate+Values.swift`. Persistence lives in `CognitiveSubstrate+Persistence.swift`; replay lives in `CognitiveSubstrate+Replay.swift`; restore lives in `CognitiveSubstrate+Restore.swift`; research and observatory behavior lives in `CognitiveSubstrate+Research.swift`. The inert resident identity-proposal and external-grounding producers are retired; legacy artifact bytes remain preservation-only compatibility. |
| `CognitiveSubstrateContracts.swift` | Dependency injection and receipt-read value contracts, moved unchanged from the actor file. |
| `CognitiveSubstrate+Ingest.swift` | Same-actor direct/resident event ingestion and completion reconsolidation, preserving admission, appraisal, state mutation and persistence ordering. |
| `CognitiveSubstrate+Values.swift` | Existing text filters, metadata/value coercions, bounded capsule text, stable identifiers, and numeric helpers on CognitiveSubstrate; no formula or normalization changes. |
| `CognitiveSubstrate+Persistence.swift` | Snapshot, receipt and artifact persistence, thought-seed family and maintenance transactions, and in-memory artifact caps on CognitiveSubstrate. |
| `CognitiveMetadataSignals.swift` | Shared deterministic string/key extraction from JSON metadata for event, node and workspace readers; sorted object keys, array order, and scalar handling remain unchanged. |
| `CognitiveSQLiteStore.swift` | Cognitive SQLite connection ownership, mutation transactions, node/artifact/receipt writes, and retention. |
| `CognitiveSQLiteStore+Reads.swift` | Node and restore-bundle reads, artifact and receipt queries, schema-marker reads, and their checked JSON/row decoders using the store's existing connection. |
| `CognitiveSubstrate+Replay.swift` | Transactional replay integration and rollback, episode and schema projections, developmental timeline recording, and replay evidence helpers on CognitiveSubstrate. |
| `CognitiveSubstrate+Restore.swift` | Checked persistent restoration, artifact family loads and validation, restore payload readers, and restore failure classification on the same CognitiveSubstrate actor. |
| `CognitiveSubstrate+Capsule.swift` | Pure inner-state capsule preparation: capsule lines, inner-voice cues, fit/scoring, and an immutable `CognitivePreparedCapsule` plus value-only presentation commit derived from one frozen read. Preparation mutates no living state; the app runtime commits presentation only after the capsule is accepted into injected provider context. Standing-view Inner text is admitted only when existing concern vocabulary makes it relevant; disabling `standingViewCapsuleRelevanceEnabled` restores the prior state-free presentation rule. |
| `CognitiveSubstrate+CapsuleCadence.swift` | Inner/thread selection, fingerprint cadence, and felt session bridge rendering; exact existing presentation-state operations and nested types remain on CognitiveSubstrate. |
| `CognitiveSubstrate+CapsuleFeltSignals.swift` | Capsule felt-signal projection: actual-turn mode/valence, fingerprint object and ambivalence rendering, substrate fatigue/curiosity/clarity proxies, and the existing diagnostic read |
| `CognitiveSubstrate+CapsuleSoundEcho.swift` | Sound echo selection, register/landing factors, verbal-rut detection and shared deterministic capsule cadence helpers; extracted unchanged from capsule preparation. |
| `CognitiveSubstrate+Research.swift` | Observatory and welfare snapshots, faculty measurements, ablations, research experiment scoring and trace export; the actor retains the stored state. |
| `CognitiveSubstrate+Reflection.swift` | Reflection request planning with one bounded actor-owned in-flight daily-budget reservation, durable receipts, standing-view-only proposal parsing, and cost/yield scoring. Schema proposal rows remain read-only REM replay lineage; generic legacy resolve is a compatibility no-op. |
| `CognitiveSubstrate+Affect.swift` | Affect state update/materialization, memory re-feeling, emotional tags, pure analytic projection at an arbitrary read instant, ambient presence, and affect restore/reconcile. |
| `CognitiveSubstrate+ConversationalAppraisal.swift` | Conversational appraisal, relational warmth, user-authored event classification, and landing-score projection. Positive phrase appraisal reuses Mood's word-bounded two-token negation parser. |
| `CognitiveSubstrate+Workspace.swift` | Workspace microcycle/maintenance, node eligibility, scoring/sort, verification-node eviction, and one-epoch frozen read capture |
| `CognitiveSubstrate+ThoughtSeeds.swift` | Thought-seed add/materialization plus pure analytic priority/expiry projection, suggestions, prioritization, and cap enforcement |
| `CognitiveSubstrate+Serialization.swift` | `toJSON()` encoders for receipt/model types plus session-id helpers |

The Organism Kernel lives under `CognitiveSubstrate/Organism/` and stays default-off until explicitly enabled:

| File | Owns |
|---|---|
| `OrganismLivingDynamics.swift` | Analytic decay and shared sleep evidence, pressure, lane and control-state value types. |
| `OrganismResidualRepair.swift` | Residual repair opportunity and exact pressure/lane evaluation. |
| `OrganismOperationalConsolidation.swift` | Operational consolidation receipts and identity dream trigger. |
| `OrganismGeneratedSleepRecalibration.swift` | Generated sleep calibration models, authorization and recalibrator. |
| `OrganismCapabilitySelfModel.swift` | Capability belief values and existing self-model projection. |
| `OrganismModels.swift` | Somatic signal, chemical state, body schema, projection, snapshot, and configuration models |
| `OrganismBodySchema.swift` | Pure body-read merge into BodySchema from bounded app-body reader inputs |
| `OrganismChemistry.swift` | Pure, bounded chemical/body-schema update rules and neutral projection body-line logic |
| `OrganismDreamRepair.swift` | Pure dream/REM field-repair operation planner, bounded repair receipts, contradiction evidence, and summary models. It does not manufacture standing-view proposals; concrete reviewable views remain solely owned by `CognitiveSubstrate+StandingViews.swift` through reflection and explicit resolution |
| `OrganismField.swift` | Pure in-memory organism node/edge plastic field, decay, repair softening, and bounded summaries |
| `OrganismToken.swift` | Shared stable ASCII token normalization for field, prediction and reflex identifiers, preserving the existing 48-character bound and unknown fallback. |
| `OrganismKernel.swift` | Opt-in in-memory organism actor with signal ingest, projection, snapshot, and transient clear; ordinary chat can apply one body sample plus the substrate's same-time canonical affect and return its frozen projection/posture in one actor admission |
| `OrganismPrediction.swift` | Pure prediction settlement and retention: exact correlation for tool/provider/phone/approval/workflow expectations and prediction-error chemistry nudges. Shared provider calls emit payload-free lifecycle IDs; phone notification predictions use canonical device-event IDs and settle only from signed iOS process/scheduler receipts or exact local send failure—never generic health/reachability |
| `OrganismPrediction+Horizon.swift` | Horizon-only refresh, source reconciliation, confidence projection, and early settlement on OrganismPredictiveBody; reuses the prediction owner's expiry transition and satisfied effect |
| `OrganismPredictionModels.swift` | Prediction kinds, semantic expectation contract, horizon register and reads, body-path confidence, outcome weights/counts, limits, summaries, and in-memory ledger value types |
| `OrganismReflex.swift` | Pure in-memory reflex compatibility/review state with trust classes, approve/hold/permanent-reject transitions, and bounded reviewer receipts. Routine organism signals no longer run the generic candidate compiler; persisted review rows and approved historical biases remain readable. |
| `CognitiveSomaticSignalAdapter.swift` | Bounded CognitiveEvent-to-SomaticSignal mapping, redaction, debug/verification filtering |
| `OrganismSignalBus.swift` | SomaticSignalObserving protocol and feature-gated signal forwarding bus |

Trust and security implementation files are split by policy boundary:

| File | Owns |
|---|---|
| `TrustCenter.swift` | Actor state/init, public policy APIs, small decode/merge helpers |
| `TrustCenter+AppAdapter.swift` | App-facing JSON adapter for the Swift-native trust policy |
| `TrustCenter+PolicyModels.swift` | Trust policy wire/status models |
| `TrustCenter+Defaults.swift` | Default policy and fallback chains |
| `TrustCenter+PolicyLoading.swift` | Checked policy load/normalize/merge behavior; missing may bootstrap, while existing corrupt state is unavailable and projects a fail-closed compatibility policy only where a nonthrowing read is unavoidable |
| `TrustCenter+Autonomy.swift` | Tool autonomy lookup, glob matching, timestamp forwarding |
| `TrustCenter+ChromeControl.swift` | Checked, fail-closed effect-time authority for the default-off real-Chrome capability; no relay or lease session may cache this decision |
| `SwiftNativeManifestSigner.swift` | Manifest signing, HMAC, canonical JSON, timestamp signing |
| `SecurityCenter.swift` | Origin assessment, allowlists, public evaluation flow |
| `SecurityCenter+Models.swift` | SecurityCenter wire/status models |
| `SecurityCenter+ReceiptJSON.swift` | Receipt JSON serialization |
| `SecurityCenter+ToolProfiles.swift` | Tool risk/profile tables |
| `SecurityCenter+FullMacPolicy.swift` | Full Mac policy checks |
| `SecurityCenter+JSONUtilities.swift` | Shared JSON coercion helpers |
| `SecurityCenter+PathPolicy.swift` | File/path allow/deny policy |
| `SecurityCenter+InputScanning.swift` | Risk input scanning |
| `SecurityCenter+RegistryReceipts.swift` | Registry receipt helpers |

The surface-neutral `NativeAgentCore/TurnPresentation.swift` owns the single pure accepted-turn lifecycle kernel: stable phases, sanitized bounded activity history, timestamps and last movement, terminal immutability, stream-length coalescing, and derived stall classification. It imports no surface or transport module. Mac `MacChatTurnActivity.swift` maps the existing `TurnStreamEvent` notice/tool intake into the boundary-redacted shared vocabulary; raw tool arguments/results stop there and only safe notices continue through the pre-existing `nativeAgentTurnNotice` path. `MacChatTurnLifecycle.swift` is the one Mac lifecycle owner layered on that kernel: exact session/turn routing, nonterminal Stop intent, evidence-backed terminals, strict bounded canonical transcript receipts, a bounded payload-free snapshot, and restart repair that marks unproved interrupted work outcome-unknown. Natural stream close, `.final` alone, or cancellation request alone cannot claim completion or cancellation. Cancellation specifically is settled only from canonical transcript evidence or a TYPED cancellation observed at the app's own stream boundary; an untyped stream error string — including one whose whole body reads `cancelled` — is classified ambiguous and can only ever resolve to outcome-unknown, so a provider failure can never present as a quiet user cancel. Restart repair likewise keeps a record pending only while outcome work genuinely remains, so a deleted session's already-settled tombstone cannot pin repair incomplete for the life of the process. Telegram chat handler/progress contracts live in `TelegramChatHandling.swift`; ordinary growing-draft edits live in `TelegramDraftStreamer.swift`; command-menu sync contracts live in `TelegramCommandMenu.swift`; and Telegram's `TelegramTurnPresentation.swift` is a thin inward adapter that maps Telegram progress vocabulary and token redaction into the shared kernel while retaining Telegram-only text rendering. `TelegramTurnControls.swift` owns the bounded active-turn callback wire shape; `TelegramQueuedTurnControls.swift` owns exact queued-update steer/remove callbacks; and `TelegramTurnProgressCardDriver.swift` owns one best-effort, in-place-edited ordinary-message work card per accepted turn. Its active keyboard exposes status, redacted details, and stop; its 7-second heartbeat refreshes elapsed/stall presentation; terminal state removes stale controls; and card transport failure records redacted evidence without affecting or duplicating the separate draft/final reply. `TelegramRichMessage.swift` owns the bounded, user-visible-only Bot API 10.2 block subset; `TelegramAssistantDeliveryDriver.swift` selects exactly one rich or ordinary assistant-response lane and permits ordinary fallback only when rich delivery is known not to have occurred; and `TelegramTurnCardLedger.swift` persists bounded redacted card identities so process-start repair can edit interrupted cards in place to outcome-unknown and clear stale controls. Confirmed terminal cards are durably terminal-marked before their final edit and then removed from the ledger, so restart repair cannot overwrite terminal truth. `TelegramPollLoop.swift` owns the polling tick/state shell and admits turn execution into the actor-owned coordinator without blocking the next long poll. `TelegramTurnCoordinator.startTrackedTurn` makes per-chat admission, immutable turn identity, card ownership, callback de-duplication, and user-priority Task creation one actor operation. Ordinary follow-ups are durably marked `queued` in the canonical update inbox and mirrored into a bounded per-chat coordinator FIFO. Natural completion starts the next item; its acknowledgement offers exact-bound `Steer now` and `Remove` controls; steering promotes that update and crosses the existing confirmed cancellation boundary before launch. Restart rehydrates queued claims from their original Telegram update bytes. Callbacks and control commands remain responsive against the exact active or queued generation; scheduler shutdown cancels active tasks while durable queued claims remain recoverable. Mutable attachments are frozen before the `@Sendable` boundary, so an ordinary message and approval continuation cannot both begin the same chat turn.

The queued Telegram claim also retains its known acknowledgement message identity. Restart recovery therefore reclaims and edits the original queue card rather than leaving stale controls and sending a duplicate acknowledgement; legacy claims without the optional identity remain readable.

Telegram poll-loop behavior belongs in focused extensions:

| File | Owns |
|---|---|
| `TelegramPollLoop+StateReceipts.swift` | State paths, offsets, seen/blocked/error/receipt persistence, command menu sync |
| `TelegramUpdateInbox.swift` | Durable update claims, locked claim/index transactions, and restart recovery classification |
| `TelegramPollLoop+ChatProgress.swift` | Typing heartbeat, progress notices, retry/provider usage notices |
| `TelegramPollLoop+Voice.swift` | Voice transcription notices and attachment parsing |
| `TelegramPollLoop+Media.swift` | Photo/image ingestion and dropped-attachment notices |
| `TelegramPollLoop+Approvals.swift` | Approval slash-command and inline-callback routing |
| `TelegramPollLoop+Commands.swift` | Slash-command dispatch, model callbacks, retry/session command handling |
| `TelegramPollLoop+TurnControls.swift` | Live work-card status/details/stop callbacks, stale/duplicate protection, and observed cancellation outcomes |
| `TelegramPollLoop+QueuedTurnControls.swift` | Exact queued-message steer/remove callbacks, stale binding checks, durable removal settlement, and confirmed steering handoff |
| `TelegramPollLoop+Transport.swift` | Typed rich/ordinary send, edit, chat-action, callback, default-command transport, shared semantic response validation, and chunking |
| `TelegramRichMessage.swift` | User-visible-only rich block models, redaction, structural rendering, and Telegram 10.2 limits |
| `TelegramAssistantDeliveryDriver.swift` | One-response rich/ordinary draft and final lane, known-rejection fallback, and ambiguous-delivery suppression |
| `TelegramTurnCardLedger.swift` | Bounded redacted card identity persistence plus in-place startup repair and terminal cleanup |

Telegram command/media helpers are split by their own boundaries: `TelegramBot+Completeness.swift` owns completeness slash commands and dependency registration only; `TelegramMediaAttachment.swift` owns media attachment/download types; `TelegramVoiceTranscription.swift` owns Apple Speech/OpenAI Whisper transcription; `TelegramProgressNoticeChannel.swift` owns cross-surface progress notice plumbing.

`SwiftNativeChatOrchestrationClient` is split by execution concern:

| File | Owns |
|---|---|
| `ChatOrchestrationClient+Bridges.swift` | Bridge-specific chat entry points and surface adapters |
| `ChatOrchestrationClient+Client.swift` | Actor state/init and public chat facades |
| `ChatOrchestrationClient+DispatchWrappers.swift` | Dispatcher wrapper construction and tool-gate adapters. `AutonomyGatedDispatcher` is the sole mint site of `MacInjectionCapability`, and for an injection tool it mints only from an approval id that `InjectionApprovalVerifying` has resolved against the canonical ApprovalInbox: the record must exist, be resolved-approved, name that tool and surface, bind that exact body digest, and be unspent. Both entry points are verified — the exact post-approval replay (`ApprovedChatToolReplay` is a caller-built pointer to a record, never evidence in itself) and an approval resolved inside the call (a filer that merely returns an id and reports approval cannot authorize a keystroke). No verifier wired means no injection. SecurityCenter is evaluated with injection arguments already reduced to count+digest, because the envelope it returns is persisted to the audit ledger. |
| `ChatOrchestrationClient+EphemeralToolTurn.swift` | Stateless tool-capable turns for non-chat surfaces such as Workshop synthesis |
| `ChatOrchestrationClient+Factories.swift` | Client factories and dependency construction |
| `InjectionApprovalVerifier.swift` | The approval-record authority behind every Mac input injection: `InjectionApprovalVerifying` plus the inbox-backed `ApprovalInboxInjectionApprovalVerifier` and the process-global `MacInjectionApprovalConsumptionLedger`. Verification is single-use in THREE layers — the persisted `executedAction` marks a COMPLETED injection, the durable spend marker (`ApprovalInbox+InjectionSpend.swift`) marks one that merely STARTED, and the process ledger stops a second mint inside one process. The durable spend is written BEFORE `.verified` is returned, because the executor annotates `executedAction` only after dispatch returns: a crash in that window used to leave a resolved-approved record with no annotation, replayable on the next launch. The spend is permanent — a failed injection does not refund its approval — and an unrecordable spend refuses (`approval_spend_unrecordable`) rather than proceeding. It is the only conformer to the protocol in the source tree, pinned by a source-conformance test so a convenience always-approve stub cannot appear. |
| `ChatOrchestration+TurnEngine.swift` | Turn admission, context preparation, attention inputs, memory observation, and single-call execution; shared turn contracts live in `TurnEngineContracts.swift`. |
| `TurnEngineContracts.swift` | Turn errors, recall/promotion/tool boundaries, memory evidence projection, schema seed, context, and result value types used by the turn engine and tool loops. |
| `ContextSelection.swift` | Deterministic hybrid context selection, ranking, quotas, conflicts, and shared lexical tokenization. |
| `ContextSelectionContracts.swift` | Context need, authorization, score, packet, receipt, and configuration contracts; selection index entries use the selector's shared lexical tokenizer. |
| `ChatOrchestrationClient+MessagePersistence.swift` | Chat JSONL/session persistence; validates the shared session index before transcript mutation. It is also the sole automatic/manual transcript-compaction entry: an explicit manual request may bypass only the enable/threshold gates, while honest JSONL validation, verified backup, keep-tail replacement, durable write, trace projection, exact provider/model threshold, and optional distillation remain shared. Persisted tool receipts and cognitive tool events redact injection arguments and results BY TOOL before the generic secret redactor runs, so a typed password or an `ax_act` value never reaches the transcript that every surface reads back. A successful canonical regenerate swaps exactly one assistant row under the transcript lock; a missing, duplicate, or non-assistant target fails before any replacement row is written. |
| `ChatOrchestrationClient+RuntimeHelpers.swift` | Compact runtime helper functions |
| `ChatOrchestrationClient+StreamFacade.swift` | `chatStream` facade; signed remote regenerate binds its validated replacement identity inside the stream producer Task so task-local lifetime and transcript replacement remain request-scoped |
| `ChatOrchestrationClient+StructuredChat.swift` | Structured non-streaming/streaming execution |
| `ChatOrchestration+ToolLoop.swift` | Non-streaming structured tool-loop execution and shared completion, exhaustion, dispatch-round and same-turn schema-refresh helpers |
| `ChatOrchestration+StreamingToolLoop.swift` | Streaming structured tool-loop execution, using the same context, dispatch and completion helpers as the non-streaming loop |
| `ChatOrchestration+SessionHistory.swift` | Transcript records/readers and history threading into turn context |
| `SessionHistoryMessageProjection.swift` | Structured history admission/projection, per-turn tool-change value contracts, and provider conversation-prefix seeding and telemetry |
| `SessionHistoryPromptRenderer.swift` | Budgeted history text rendering, continuity and recall query selection, tool-result projection, and shared admission/rendering helpers used by structured history projection |
| `ChatOrchestrationClient+TextCompatibilityEntry.swift` | Text-compatibility lane selection, append-only transport eligibility and trace, and the chat entry facade that joins the stream producer, forwards progress and projects the saved final response |
| `ChatOrchestration+ToolDispatch.swift` | Shared iteration dispatch, ordered serial/parallel outcomes, per-tool deadlines, and dispatch error projection |
| `ToolLoopSupport.swift` | Tool-loop error carriers, iteration/wall-clock/deadline budgets, tool-result projections, no-progress guard, and shared provider retry receipts |
| `ParallelToolDispatch.swift` | Parallel-safety classification and stable ordered dispatch grouping, including distinct-worktree fleet overrides |
| `ToolCallParser.swift` | Provider tool-call parsing, protocol violation detection, and visible text prefix projection |
| `ChatOrchestrationClient+TextCompatibility.swift` | Anthropic text-stream compatibility, including one eager tool-schema preload per turn; `TurnToolSchemaCatalogSeed` reuses that catalog after packet preparation and scopes only the canonical `context_expand` member instead of repeating the full schema walk |
| `ChatOrchestrationClient+ToolReceipts.swift` | Value-only text-compatible tool receipts and their ordered transcript drain; writer task creation, completion, and join remain in the tool loop |
| `ChatOrchestrationClient+ToolDispatching.swift` | Traced/gated dispatcher choke point |
| `ChatOrchestrationClient+Types.swift` | Public response/support types and the current client-owned chat error contract; the retired protocol compatibility shell no longer ships |

`TurnPlanning.swift` owns the cheap per-turn plan used by structured chat before the first model call: router intent/context mode, policy snapshot, meaningful capability ids, resident tool readiness, preload prediction, compact context hinting, metadata-only aggregate `turn.plan` rows, and the smaller `turn.plan.v1` Turn Inspector event. Neither persists raw user text. `SystemOps` may attach only known closed tool groups to its existing route result; `ToolPreloadHeuristics` merges those route facts with lexical evidence, caps the request-scoped preload, and the normal schema/policy filter remains authoritative. Direct `github.com` repository URLs select the GitHub group without competing generic URL-only browser preload; an explicit browser request still keeps the browser group. Bridge status/progress/message intent deterministically attaches the lazy `delegation_status` projection before the first provider call. Both routes add only a short positive best-fit cue; they do not write memory, create a skill, ban fallback tools, or change effect authority. The same group definitions own compact catalog advertisement, category aliases, preload members, and explicit-load compatibility members; the two former `tool_load` switches no longer duplicate that contract. A generic word such as “find” does not imply web research. The metacognitive shadow is retired outright (User authorized, 2026-09-01): the recommendation evaluator, the governor shadow, the outcome tissue and its calibration report, their tests, the ChatDrive `living-fabric-eval` metacognition sections, and the architecture guard against reintroduction are all deleted. Only the shared turn-trace identity helpers survive, in `ChatOrchestration/TurnTraceIdentity.swift`, because structured chat and canonical message persistence correlate turns with them. Frozen-mind and adaptive-causal evaluation instruments live in the separate dependency-light `NativeAgentEvaluation` target, which only ChatDrive and tests depend on; the Mac app does not link it. The residual v1 frozen-mind epoch assembler/provider runner and personal-egress validators are retired; canonical packet/manifest/digest, generated nonpersonal fixtures, personal authorization, terminal provider phase, and the current v2 evaluation lifecycle remain. `NativeAgentCore/UserMessageIntentSignals.swift` is the shared pure guard used by SystemOps routing, the Dispatcher compatibility route, and tool preload: explicit tool prohibition is not creation intent, slash-joined prose is not a local path, and communication risk uses exact tokens rather than substrings such as `post` inside `posture`. Explicit tool creation, real path shapes, file nouns/extensions, and actual communication/calendar mutations retain their prior routes and authority gates. Provider-transplant evaluation remains CLI-only over frozen nonpersonal fixtures; it constructs no persona, memory, cognition, tool, or action owner and measures strict continuity-contract expression rather than identity. SwiftPM tests are automatically redirected to a process-specific trace root, including factories that explicitly pass the production default. Automatic preload predictions flow through request-scoped `LLMCallContext.turnActiveTools`; only explicit non-redundant `tool_load` writes grow `ActiveToolsStore`. `tool_catalog` returns a compact group/count/readiness view by default; `detail=full` is the schema-heavy diagnostic view. Compatibility aliases remain discovery/load and dispatch compatible without occupying the permanent hot set. `ChatOrchestration+ToolLoop.swift` appends newly authorized schemas after an explicit load before the next provider iteration and preserves existing provider aliases. It bounds provider-facing results to 12,000 UTF-8 bytes for GitHub/blocking delegation or 32,000 for other tools; `ProviderToolResultRecovery.swift` retains an oversized redacted result in owner-only temporary storage and exposes pages of at most 8,000 UTF-8 bytes through the read-only `tool_result_page` tool only to the same session and turn. Full dispatch records keep their existing diagnostic ownership. Every dispatch has a finite recovery backstop (15 minutes for ordinary interactive work, explicit tool timeouts plus cleanup margin, and 65 minutes for unattended work), and an exact same-call/same-result streak warns at eight rounds and stops at sixteen; any changed input or result resets the streak. These controls change transport and recovery behavior, never TrustCenter authorization or tool availability.

`DelegatedCampaignGuidance.swift` owns the compact prompt-only continuation
contract shared by native-tool and text-compatible turns: an accepted finding
inside an operator-delegated Desk/Claude/Codex campaign advances through all
reversible filing, routing, recovery, and verification without a ceremonial
permission question. It stops only at independently verified completion or a
genuine operator-only authority/scope boundary. This guidance grants no tool or
effect authority; TrustCenter, ApprovalInbox, effect-time gates, and canonical
domain verification remain authoritative.

Generic builder-completion notices do not preload builder, file, or GitHub tool
groups. Concrete status/message intent and repository evidence retain their
deterministic first-call attachments.

Provider output ceilings must cover the provider's complete response, including
hidden/adaptive reasoning and tool arguments. `FirstPartyExecutionControls`
owns Anthropic's model/effort-aware ceiling and empty-output classification for
both API-key and OAuth adapters. A terminal provider stream with neither
answer text nor a tool call is never success; `streamTurn` is the
provider-neutral backstop for legacy/string streaming paths, while structured
native-tool adapters enforce the same invariant before completion. This
boundary is shared by chat surfaces and secondary factories without granting
tools or changing TrustCenter authority.

`Research.swift` is the public research model/protocol/client shell and factory. Research behavior is split by responsibility:

| File | Owns |
|---|---|
| `Research+ActivityTrace.swift` | Activity/trace emission and redaction |
| `Research+Autodetect.swift` | SearXNG discovery and config persistence |
| `Research+Helpers.swift` | Small URL/timestamp helpers |
| `Research+Lab.swift` | Lab-run catalog/execution and brief generation |
| `Research+SearchFetch.swift` | Search/fetch plus HTML/result parsing |
| `ResearchTransports.swift` | URLSession and docker-process transports |

## Tool Dispatcher Map

`SwiftToolDispatcher.swift` is now the state/init/schema-listing shell. Keep it small.

Lazy dispatch may derive a missing `session_id` only from the current
task-local canonical chat session. Builder bridge tools distinguish a new
conversation from an explicit resume, reject stale or conflicting handles, and
return the continuation handle in successful receipts. Optional Desk
`assignee` and `lane_of` values are omitted or non-empty; empty identities are
schema errors rather than normalized state.

Tool families belong here:

| File | Owns |
|---|---|
| `SwiftToolDispatcher+ToolCatalog.swift` | Built-in tool name groups and always-on core |
| `SwiftToolDispatcher+Dispatch.swift` | Main dispatch switch and routing decisions |
| `SwiftToolDispatcher+SchemaBuilders.swift` | LLM schema assembly entry point and model-visible MCP boundary. NativeAgent's own MCP compatibility server remains available to raw MCP clients/UI but is not advertised back to the same runtime as duplicate model tools. |
| `BuiltInToolSchemaFactory.swift` | Per-request lazy schema factory, shared JSON Schema field builders, and stable core/optional assembly order. Requested names are checked before descriptions or parameters are evaluated. |
| `BuiltInToolSchemaFactory+CoreSchemas.swift` | Core tool schema catalog. Optional provider fields expose a neutral wire value when strict bindings may materialize every property: `commit_memory.context_topics=[]` is omission, Desk metadata/progress admit null, and destructive GitHub collection clears require explicit clear flags rather than an empty placeholder. |
| `BuiltInToolSchemaFactory+MacSchemas.swift` | Optional file, system, app, Accessibility, and activity-query schemas under the existing caller-selected inclusion flags. |
| `MCPToolCatalogWarmer.swift` | Nonblocking bounded MCP catalog warming, per-server refresh signatures and age limits, and the warm-sweep deadline latch. Schema assembly only triggers this existing owner. |
| `SwiftToolDispatcher+ToolImpls.swift` | Basic file/list/write concrete tool implementations |
| `SwiftToolDispatcher+ToolImplHelpers.swift` | Shared JSON/parsing helpers for tool implementations |
| `SwiftToolDispatcher+MemoryTools.swift` | Memory search/commit/proposal tools; an empty strict-schema `context_topics` array is wire-equivalent to omission, while nonempty correction scope remains validated and correction-only |
| `SwiftToolDispatcher+KnowledgeGraphTools.swift` | KG query/status/fact tools |
| `SwiftToolDispatcher+InnerStateTools.swift` | `inner_state` pull: the agent reads its own mood, energy and clock on demand |
| `SwiftToolDispatcher+MomentTools.swift` | The moments lane's review seat: the agent accepts or declines proposed moments |
| `SwiftToolDispatcher+StandingViewTools.swift` | The held tier's two verbs: hold and release a standing view |
| `SwiftToolDispatcher+StudioCanonTools.swift` | The canon lane: works earn a place by recurrence, tended by the agent |
| `SwiftToolDispatcher+MemoryCurationTools.swift` | `list_memories` (offset or after_id cursor), `rewrite_memory`, `forget_memory`, `rebuild_knowledge_graph`: the agent curates its own store |
| `SwiftToolDispatcher+ChatHistoryTools.swift` | Chat/session search tools; broad ranked matches are projected through compact 12-result offset pages so provider turns do not absorb the former 25-snippet payload while complete recall remains reachable. Matching and previews run on the substantive text (`ChatTranscriptBoilerplate`), never on bridge routing prefixes or wake-receipt slips. `read_chat_message` pages ONE matched message in full by its `message_id`, through `SessionHistoryReader` |
| `SwiftToolDispatcher+DelegationTools.swift` | Read-only provider projection over canonical Claude/Codex/OMP job stores; agent filtering precedes compact offset pagination, and full lifecycle detail is explicit rather than paid on every progress check |
| `SwiftToolDispatcher+StudioTools.swift` | Durable Studio consult, consult-read, encounter-journal, and recall tools. Description-only material requires explicit acknowledgement before filing, journal writes remain append-only and strict-field validated, and recall preserves the original response text while applying bounded creator/tag/relation filters. |
| `SwiftToolDispatcher+DeskTools.swift` | Desk explicit task-tracking tools; null/blank optional status metadata preserves the existing lane/assignee/progress, while malformed or self-referential non-null updates fail before append |
| `SwiftToolDispatcher+WorkshopTools.swift` | Workshop submit/status tools |
| `SwiftToolDispatcher+PersonaTools.swift` | Persona/doc reads plus compact runtime/provider/session identity; expensive roots, MCP/tool inventory, and outcome-population diagnosis are explicit `agent_introspect(detail=full)` work rather than the default status path |
| `SwiftToolDispatcher+RemoteNodes.swift` | Trusted remote-node list/execute tools; execution delegates to the MacControl owner and revalidates exact node policy at effect time. Standard modes retain their configured approval policy; admitted Full Mac YOLO executes without a per-call prompt. |
| `SwiftToolDispatcher+ToolLoading.swift` | Tool catalog/load state actions; compact catalog is the default group/count/readiness read, `detail=full` exposes model-visible schema rows for diagnostics, and explicit loads remain the only durable active-tool mutation. Custom registry names without a current active schema stay discoverable but return unavailable rather than being persisted or renewed as loaded; mixed loads retain usable tools without changing built-in/MCP authority. |
| `SwiftToolDispatcher+FourVerbPerception.swift` | Source-neutral bridge from MacControl's current fused `view` to the four-verb `screen`/target contract. It asks the existing capture owner for the frozen raw frame without human marker ink, crops pixel perception to the AX-located visual surface, preserves structural AX marks, and adds confidence-gated VisionPerception rows. Foreground-window geometry excludes covered pixels before world fusion/tracking and checks final projected targets while preserving clear targets; small overlays do not disappear behind screen-area thresholds. Its dispatcher-local `SwiftToolDispatcherFourVerbLiveScene` gives physical regions rebuildable stable identities and motion descriptions across observations; it is perception continuity, not memory, authority, persistence, event posting, or a second screen schema. |
| `Dispatcher/Actions/FileSystemActions.swift` | Shared local path resolution for file/git/repo actions; expands `~` before absolute/relative normalization and canonical sandbox validation |
| `SwiftToolDispatcher+ContextTraceTools.swift` | Context/turn trace inspection tools; `recent_trace_summary` reads the current bounded `turn_traces` day ledger and can scope to the injected chat session |
| `SwiftToolDispatcher+SwarmTools.swift` | Swarm/run tools |
| `SwiftToolDispatcher+SkillTools.swift` | Compact installed-skill manifest, one-body lazy read, and canonical conversational save. Discovery delegates to `PersistenceCore/InstalledSkillInventory.swift`; saves delegate to the existing locked `Skills` owner, then reconcile the exact-root MemoryV2 recall pointer through the shared receipt-backed sync. The model never reconstructs registry/body formats, and skill guidance cannot change tool or trust authority. |
| `SwiftToolDispatcher+Sandbox.swift` | Full Mac access checks, sandbox helpers, local connector dispatch, and the read-tier accessibility perception route. `impl_mac_accessibility_read_tool` serves the `mac_ax_status`/`mac_ax_tree`/`mac_ax_find`/`mac_view` model tools by mapping each to its MacControl `ax_*` / `view` sub-action; `mac_view` (W3.5) rides this route rather than one of its own because it is the same category, the same read tier and the same no-approval contract, its extra Screen Recording requirement being a system grant it reports in its result rather than a policy tier. It gates on `FullMacToolAccess.accessibilityReadAllowed` — the accessibility category's read tier, today the same policy key as app control because `MacControlPolicy` carries one `accessibility_allowed` boolean — rather than on `appControlAllowed`, so looking at the screen never requires authority to act on an app. There is no approval tier and no write side-effect: the tools are absent from `ToolCausalBoundary`'s motor bindings and permitted under `fileAccess=read_only`. `mac_ax_status` remains inside the category gate; exempting it is an owner decision, not a dispatcher default. `impl_mac_injection_tool` is the parallel ACT route for `mac_keystroke`/`mac_click`/`mac_scroll`/`mac_ax_act`: it gates on `appControlAllowed` rather than the read tier, and it MINTS NOTHING — it reads the `MacInjectionCapabilityContext` TaskLocal that `AutonomyGatedDispatcher` binds after admitted Full Mac YOLO or an exact resolved approval and relays it to `dispatchApprovedInjection`, refusing with `injection_approval_missing` when none is in scope. This is what makes a raw `SwiftToolDispatcher` instantiation — which tests and several app paths create directly, below any autonomy gate — unable to inject. The sole mint site is `AutonomyGatedDispatcher.runInner`, pinned by a source-conformance test. These tools resolve autonomous only through the canonical admitted Full Mac YOLO authority; standard modes retain their configured approval behavior, and a saved `toolAutonomy` exact or glob override cannot mint the body-bound capability by itself. They remain blocked under `fileAccess=read_only` and `none`, and unlike the reads they bind to a canonical `macControl` motor owner. W6's `mac_wake` joins that route unchanged — same `appControlAllowed` gate, same capability relay, same admitted-YOLO-or-approved-replay boundary, same read_only block, same motor owner — even though most of what it returns is a `mac_view`: it posts a HID mouse move first, and routing it through the read tier would have been a bypass with a view stapled to it. `impl_mac_nudge_tool` is W7's third route: it serves `mac_nudge` on the SAME `accessibilityReadAllowed` signal `mac_ax_status` uses — no approval filer, no capability, no TaskLocal to read — and calls the UNPRIVILEGED `dispatch` with an empty body, dropping caller input rather than forwarding it, so no supplied field can reach the handler and a future `nudge` that grew a button-down would have to join `macControlAccessibilityInjectionActions` and would then be refused here by signature instead of quietly gaining injection at read tier. native-look item 2 adds `mac_look` to `impl_mac_accessibility_read_tool`'s switch (-> the `look` sub-action) rather than a route of its own, for the same reason `mac_view` rides it: same category, same read tier, same no-approval contract — and unlike `mac_view` it needs no second system grant at all, since it takes no picture. native-look item 3 adds `mac_act` (-> the `act` sub-action) to `impl_mac_injection_tool`'s switch, NOT to the read route: it returns a percept but it presses and types to get one, so it takes the `appControlAllowed` gate, the capability relay and the motor owner its four neighbours take — the same reason `mac_wake` is on that route despite returning a `mac_view`. |
| `SwiftToolDispatcher+Markets.swift` | Market/TradingView read tools |
| `SwiftToolDispatcher+CloudConnectorTools.swift` | Bounded Gmail, Google Calendar, and Notion reads plus Google refresh-token persistence under the dispatcher's exact data root |
| `SwiftToolDispatcher+MCP.swift` | MCP bridge name parsing and live MCP calls |
| `SwiftToolDispatcher+ExternalConnectors.swift` | Connector-specific helper seams such as X fallback |
| `SwiftToolDispatcher+AgentBridgeTools.swift` | `time_now`, `claude_message`, `codex_message`, `omp_message`, asynchronous wake helpers, and the agent-scoped builder conversation-reference contract. The Codex bridge advertises exact built-in model identifiers from `OpenAIExecutionControls.codexBridgeModelIDs`, including `gpt-6-astra`, while its parser remains compatible with legacy and account-discovered model passthrough. A reference is only a wire handle over canonical Codex app-server history or the existing Claude/OMP topic pointer; this layer owns no transcript/session store and never conflates the builder conversation with the originating Agent chat session. An opt-in `pair_reviewer` bit travels with Codex/Claude implementation dispatches and is part of inbox idempotency; ordinary notes remain unchanged. The immediate tool receipt exposes only `reviewerPairRequested`, because a skipped or failed wake proves no builder or reviewer was actually paired. All three asynchronous wake helpers delegate subprocess lifecycle to `MacControl.SystemProcessAdapter`; this file retains only builder-specific environment, timeout, and receipt interpretation. A matching durable Codex inbox row suppresses another helper launch only after consumed/read evidence proves that an earlier wake was accepted; an identical unconsumed row retries the helper so append-before-wake failures cannot become lost work. |
| `SwiftToolDispatcher+AgentBridgeInvocations.swift` | Bounded Codex/Claude subprocess invocation, Claude session-pointer locking and promotion, invocation audit/run receipts, and Codex exec argument construction. Cancellation and output capture remain with the shared subprocess support owner. |
| `script/codex_thread_wakeup.js` | Durable Codex wake queue consumption and completion watcher admission. Queue/inbox mutations retain short global filesystem locks; execution uses hashed canonical per-conversation lane locks, preserves FIFO within a lane, and admits at most four lane operations globally through filesystem slots. Fresh work derives a lane from its durable message/correlation identity and identity-free work fails closed to one serial lane. For an explicitly review-paired implementation dispatch, the routed prompt tells the builder to pair exactly one reviewer immediately, give that reviewer the committed SHA, receive findings back, and retain ownership of fixes; the same narrow contract is emitted by the Claude wake helper. A queued wake is stale-recovered in place only after 15 minutes plus two dead/unlisted owning-turn probes five seconds apart; live or uncertain old turns remain untouched, and recovery preserves message/order identity with a receipt. |
| `AgentBridgeRuntime.swift` | One deterministic owner for bundled wakeup-helper lookup, Finder-safe local Codex/Claude/OMP/Node discovery, child-process environment construction, and structural bridge readiness; it never owns authentication or verification |
| `SwiftToolDispatcher+SubprocessSupport.swift` | Shared subprocess latches, timeout, bounded pipe buffers |
| `SwiftToolDispatcher+BuilderTools.swift` | shell/bash/git/apply_patch/tests/build/install tool execution; on a fresh Mac with no selected developer directory, the shared Process environment suppresses Apple's interactive Command Line Tools prompt so `/usr/bin` toolchain shims fail honestly instead of opening installer UI |
| `SwiftToolDispatcher+MacIntegration.swift` | Mail/Calendar/Contacts/Music/Scheduler bridge permission wrapper |
| `SwiftToolDispatcher+ImageGenerationTools.swift` | Image generation tool dispatch, provider routing, and artifact receipts |
| `SwiftToolDispatcher+DelegationTools.swift` | `delegation_status` read-only projection over the Claude/Codex wake-job stores: real lifecycle timestamps, stall basis, and proven-lost vs unknown delivery, with home-relative store labels |

Do not add a new generic dispatcher if one of these families can own the work.

Builder autonomy is broad, but host permission authority is a distinct
effect-time class. TrustCenter inspects the exact `shell`/`bash` body; a
`tccutil reset` or direct mutating TCC database command carries
`system_permission_reset` plus `destructive`. Standard modes may ask according
to policy; admitted Full Mac YOLO hard-blocks the effect instead of producing a
prompt it cannot honor. Ordinary shell/build commands keep their autonomous
Full Mac behavior. Observation is not mutation: a read-only `sqlite3` `SELECT`
against `TCC.db` stays autonomous, while the same target with an actual
mutating SQL/file operation receives the permission-authority class.

`SystemMacAXActSource` owns live semantic Accessibility mutation. Resolve,
perform, set, and post-action reread execute on the app main lane because an AX
action can synchronously enter the target SwiftUI/AppKit handler; invoking it
from a tool executor can otherwise violate the target MainActor and crash it.
SwiftPM/XCTest processes receive an inert default AX source, just as they
already receive an inert event sink, so tests cannot act on the host desktop.

Foreground Speech consent begins on the MainActor so macOS can present its TCC
sheet, but its framework completion is an arbitrary-queue callback. The
continuation bridge is therefore explicitly nonisolated; actor isolation is
re-entered only after the await returns. Never attach a MainActor-inherited
closure directly to `SFSpeechRecognizer.requestAuthorization`, because Swift 6
will trap when TCC invokes that closure off-main even though the permission was
successfully recorded.

Mac-local Calendar and Reminders authorization remains owned by
`MacPIMConnectorActions.swift`; `MacIntegrationView.swift` is the explicit
foreground consent surface. Calendar reads require full access, while a pure
event-create path may request Apple's narrower write-only access. Tools can
report `needs_permission` but do not invent a second permission owner. Every
hardened-runtime Mac signing profile must include
`com.apple.security.personal-information.calendars`: macOS TCC otherwise
rejects the Calendar prompt before it writes any authorization row. The release
guard checks source profiles and `verify_release_artifact.sh` checks the
entitlement embedded in the signed app. Public CloudKit packaging additionally
uses `script/lib/provisioning_profile_contract.sh` at both pre-build and mounted
artifact boundaries: the embedded profile must bind the signature team, exact
team-prefixed bundle identifier, exact public container, CloudKit service,
production APNS/CloudKit environments, and an all-devices/no-device-list
Developer ID grant. Because codesign does not copy identity grants out of an
embedded profile, the release derives `com.apple.application-identifier` and
`com.apple.developer.team-identifier` from that validated profile into a
temporary team-specific signing plist; the tracked entitlement template stays
team-neutral. Mounted verification requires those signed values to match the
actual signature team and bundle ID. Codesign, Gatekeeper, and notarization
alone do not prove either the AMFI profile relationship or live CloudKit
initialization authority. TCC, Mac Integration gates,
TrustCenter, approvals, and effect-time validation retain their existing
authority.

## State Ownership

- Memory source of truth: MemoryV2 SQLite under `data/`, plus generated `persona/USER.md`.
- CognitiveSubstrate state is bounded and default-off. Optional persistence lives under `data/cognition/cognition.sqlite` for cognitive nodes/artifacts/receipts only; it must not duplicate MemoryV2 facts, write persona identity, or create a second memory source of truth. `NativeCognitionRuntime` is the only app-owned live assembly gate.
- User-facing memory prose must stay clean. Dates/timestamps belong in metadata unless the date is part of the fact.
- Persona source: `persona/SOUL.md`, `persona/VOICE.md`, `persona/GROWTH.md`, generated `persona/USER.md`, and `persona/skills/bodies/`.
- Chat history: chat JSONL/session stores under app data; session search and continuity recall are lazy. `PersistenceCore/ChatSessionIndexFile.swift` is the strict shared `chat/sessions.json` decoder for mutation boundaries: only a missing file is fresh state, while unreadable, empty, malformed, non-array, or mixed-row files fail closed before Mac, Telegram, Slack, iCloud, retention, message, or backup writers mutate data. `ChatSessionIndexReconciler` is bounded restart recovery under that same index lock: it scans at most 256 regular non-symlink transcript files and 32 MiB, prioritizes missing-index orphans, validates message/session identity, adds only absent index rows, and reports damaged rows without rewriting transcript bytes. It then repairs the other half of the same two-file commit window — the row that SURVIVED the crash describing a transcript it no longer matches (short `messageCount`, previous turn's `lastMessagePreview`, `updatedAt` a message behind; autocompaction's transcript rewrite has the same shape). That pass never re-reads the directory: a transcript is opened only when its file mtime leads the row's `updatedAt` by more than 2s, and a repaired or verified row carries `reconciledTranscriptModifiedAt` so a compacted session is not re-read on every later launch. Bounded to 50 rows per launch, sharing the recovery pass's byte budget, and `updatedAt` only ever moves forward. The stale pass holds the index lock only to select candidates by stat and to write the repairs: transcripts are read with the index lock released, each under its own transcript lock and within a 5s wall-clock ceiling, the byte budget is charged the size measured under that lock, and a repair lands only if the row's `updatedAt` and stamp are unchanged since selection. A transcript that fails the same row validation as recovery (object rows with string `role`/`content` and no foreign `sessionId`) is counted corrupt and left unstamped.
- Turn traces: `PersistenceCore/TurnTracePersistLane` owns `data/turn_traces/<day>.jsonl`; `TurnTraceRecentReader` is the bounded diagnostic reader. Payloads are bounded per leaf and at 12 KiB as a whole; an oversized payload becomes an explicit digest/preview summary that retains lifecycle identity. The daily ledger trims under the append flock from 12 MiB to the newest whole rows fitting 8 MiB, with no polling owner. XCTest/SwiftPM helper processes never write the live lane. The legacy aggregate `data/traces/events.jsonl` remains a separate action/compatibility ledger and is not authoritative for session turn inspection; all of its writers use PersistenceCore's path-owned append, which crosses a 4 MiB soft trigger before retaining the newest 5,000 whole rows under the common flock.
- Harness benchmark history: `data/harness/benchmark/runs.jsonl` retains the newest 5,000 runs exactly after every append through the same path-owned PersistenceCore boundary.
- Builder audit receipts: `ChatOrchestration/SwiftToolDispatcher+BuilderTools.swift` retains the newest 500 UUID-named JSON receipts by modification time with a filename tie-break. When a receipt ages out, matching `<uuid>-*` sidecars age out with it. Pruning is best-effort after the new receipt lands; failures leave tool success semantics unchanged and surface as `audit_error` plus a restrained log.
- Installed skills: `PersistenceCore/InstalledSkillInventory.swift` merges clean runtime registry entries with runtime bodies and the one resolved canonical persona skill shelf, retaining the stable registry id needed for body resolution. `list_skills`, `read_skill`, pointer sync, the Mac UI, and `capabilities.summary` resolve that same app-only/dev persona root instead of reconstructing it from the data-root parent. `save_skill` reuses `SwiftNativeSkillsClient.createSkill`, then immediately reconciles the dispatcher's exact-root MemoryV2 pointer and writes the shared sync receipt; Mac mutations and launch call the same reconciler. Missing optional shelves remain healthy diagnostics, while existing disabled/draft runtime rows suppress automatic recall. Bodies remain lazy, and no path teaches the model private storage formats or grants guidance any tool/trust authority.
- Desk: `PersistenceCore/DeskStore.swift` owns the append-only hierarchy. Self-authored pursuit origin is the identity-neutral `agent` role; legacy private-name rows decode compatibly but all new/re-encoded writes use `agent`. Terminal parents require terminal descendants, children cannot reopen beneath terminal ancestors, and launch reconciliation repairs older contradictions by appending ordinary `set_status` ops rather than rewriting the op log or `desk_state.json`. Desk and GitHub Command store appends emit process-local invalidation tokens; the Mac Desk independently watches both canonical ops files through kqueue so out-of-process CLI writes also refresh without polling.
- GitHub Watcher: `PersistenceCore/GitHubCommandStore.swift` remains the sole append/reducer/state owner. The stored actionable event key binds canonical GitHub evidence, including GraphQL review-thread identity and unresolved generation or the bounded identity of a new external PR conversation comment. An actionable key updates Desk and claims one durable deduplicated Apple notification; it never starts or resumes Codex, a provider, a tool, a checkout, or repository work. `GitHubCommandRuntime` deliberately has no dispatch dependency or sender seam, and the general dispatcher no longer recognizes a privileged `github-command` working-directory surface. Ordinary GitHub inspection and `codex_message` remain available only through an explicit user/Agent turn and remote-verified repository selection. Legacy dispatch records and completion callbacks remain decode-compatible for work already in flight before this cutover, but launch recovery cannot resume them. Its optional `causalTransitionEvidence` observes the existing single-pass replay and emits only bounded SHA-256 identities, state names, operation classes, and expected next-evidence classes. It is a read-only offline/shadow projection: no second ledger, action authority, provider call, or prompt path.
- Cross-domain causal evidence: `PersistenceCore/CausalTransitionEvidence.swift` is a value-only read contract, not a store or bus. GitHub Command emits it from canonical reducer replay; `WorkshopExecution+CausalTransitionEvidence.swift` maps an already-read execution timeline without copying objectives, step output, receipts, or paths. Unknown domain events remain explicit `domain_specific` evidence. The retired observational transition model and its personal-trace authorization seam do not ship. `NativeAgentEvaluation/CausalOperationalSelfModel.swift` remains a deterministic generated/frozen evaluation instrument only; it has no prompt, provider, tool, memory, action, or installed-control seam and is not linked by the app.
- Shared motor semantics: `PersistenceCore/MotorActionReadModel.swift` provides one read-only phase/verification vocabulary while preserving each reducer's exact bounded `domainState`. GitHub Command, Workshop, and Browser conform without sharing an executor or authority owner (Workflow Orchestration's conformance retired with its run engine, 2026-09-01). Browser's Core operation store owns canonical `runs.json`, request-digest idempotency, deadlines, terminal absorption, restart recovery, and retry-safe derived receipt/trace projection; WebKit remains only the app effect adapter. Active and dry-run rows expose opaque cancellation identity through the payload-free motor view, observed WKWebView navigation may satisfy success, legacy success remains unverified, and malformed tokens/timestamps fail loud. Workshop owns an optional durable verification object inside its canonical execution record: exact output criteria and bounded local `write_file` byte read-back may satisfy it, disagreement fails the execution, and unsupported external effects remain explicitly unverified. Verification adds no provider call, scheduler, action authority, or second store. Before a canonical motor projection may re-enter resident physiology, `CognitiveSQLiteStore` admits it through a bounded payload-free replay guard keyed by domain and opaque action identity; exact duplicates and stale/equal-time contradictions are rejected across relaunch, while a strictly newer owner timestamp may correct prior state. This guard has no motor authority and evicts beyond 4,096 distinct actions.
- Tool causal edge: `ChatOrchestration/ToolCausalBoundary.swift` is a pure closed mapping from supported tool aliases and bounded envelope identity keys to existing motor-owner domains. Chat trace classification, OutcomeV2 response anchors, and app consequence observation consume it instead of maintaining independent switches. It owns no dispatch, lifecycle, state, verification, safety, or physiology authority; dry runs never produce a motor reference, and each mapped owner remains the sole source of consequence truth.
- MCP response truth: `MCPDispatcher/MCPInvocationOutcome.swift` is a pure transport classifier for the raw MCP tool-result shape and one exact native/HTTP adapter wrapper. It aligns provider error bits, UI status, traces, and activity receipts, but it is not a settlement model. External MCP responses stay neutral to resident outcome learning until a canonical domain owner supplies verified consequence evidence.
- Adaptive learning gate: `NativeAgentEvaluation/AdaptiveCausalLearningGate.swift` is a pure offline readiness review, not a learner or store. It can reject an evaluation proposal that lacks longitudinal outcome coverage, schema/privacy versions, holdout, drift detection, rollback, or explicit personal-trace approval. NativeAgent currently has no production personal-trace learner, transition-shadow authority, or adaptive reasoning-effort controller.
- Chat UI state: `AppModel` owns per-session persisted messages, tasks, receipts, and committed drafts; `ChatView` and `DetachedChatPanelView` may hold view-local draft text but commit it at acceptance, session-switch, or close boundaries.
- Background-loop state: Core `BackgroundLoopsManager` owns registrations, tasks, single-flight gates, counters, and status. App assembly owns dependency construction only.
- iCloud bridge: signed Mac/iOS outbox/inbox/response files, plus snapshots for cockpit state.
- Notifications/activity/inbox: app-owned ledgers under `data/`; APNS sends through Swift app paths.
- Live proactive notification rows have one file owner,
  `NotificationInbox/LiveNotificationInbox.swift`, over
  `notifications/inbox.jsonl`. All reads and mutations use the canonical
  PersistenceCore flock; parsed cache reuse requires unchanged inode, size, and
  modification time. Rewrites preserve malformed physical rows byte-for-byte,
  all-invalid nonempty input is an error, and the hard 1,000-row retention gives
  newest active/nonterminal cards priority before terminal/malformed history.
- Memory maintenance health is projected through
  `memory/hygiene_last_run.json`. A staged consolidation is compatible with a
  healthy organism reading only when its exact `consolidationRunId` has a
  readable, timestamp-valid `applied` or `applied_prior` receipt; write and
  launch reconciliation then converge the hygiene receipt to `completed`.
  Missing, malformed, failed, mismatched, or unrelated receipts remain
  unhealthy and preserve their candidate state.
- Provider tokens/OAuth state: NativeAgent-owned provider stores under `data/providers/` and connector auth stores. The GitHub PAT is owned by `GitHubCredentialStore` in the macOS Keychain; `connectors/github/auth.json` and `oauth_tokens/github.json` contain non-secret metadata only after read-once migration. The system vault uses an interaction-disabled `LAContext`, and XCTest/SwiftPM helpers are refused before any Security.framework call, so background runtime work and tests never open password UI or borrow the operator's live token.
- Data-root construction: defaults exist only at outer production factories.
  Once a provider, context, Browser, TriggerScheduler, cognition, or
  Workshop body receives an injected root, that exact standardized root is
  transitive through child stores, telemetry/receipts, RunLedger, memory and
  research clients, OAuth/model caches, provider readiness, and Codex child
  `HOME`/`CODEX_HOME`/`NATIVE_AGENT_DATA_ROOT`. An alternate body must not
  inherit environment API keys, shared OAuth discovery, `~/.codex`, or
  process-global MemoryV2 state; it binds exact-root paths or fails closed.

Do not create parallel `data/persona/Agent`, `data/memory/USER.md`, installer seed copies, second memory stores, or side-channel prompt files.

## Policy Chokepoints

- Trust policy: `TrustCenter`
- Risk classification: `SecurityCenter`
- Full Mac gate: `MacControlGate`
- Chat/tool autonomy: `AutonomyGatedToolDispatcher` owns the standard-mode
  approval decision for shared chat composition after exact origin
  authentication; direct/raw app-tool clients retain
  `AppChatToolDispatcher`'s inner autonomy gate, and `SwiftToolDispatcher`
  retains its access checks. An authenticated remote conversation surface
  inherits active Full Mac YOLO for every tool ask/confirm, not only ordinary
  reads. A surface label alone never establishes trust, and hard blocks such as
  explicit user denial, protected roots, secret egress, corrupt authority, and
  unavailable macOS capabilities remain authoritative without becoming prompts.
  Post-resolution chat-tool replay binds the approval to the exact tool, input,
  surface, verified session, chat, and user. That evidence may satisfy only the
  matching dynamic persona confirmation already answered by the user;
  SecurityCenter, file access, persona validation, and all downstream
  effect-time checks run again. Changed payload or origin fails closed, and
  known historical pre-dispatch double-confirmation failures are the only
  failed effects eligible for automatic retry.
- Mac integration permissions: `MacIntegrationPermissionStore`. A missing
  store receives the documented bootstrap defaults; existing unreadable,
  malformed, or wrongly typed known authority is unavailable, byte-preserved,
  and deny-all until repaired. All mutations revalidate under the owner lock.
- Connector truth: connector status/proof gates must prove the account, not just token presence
- External sends and destructive/system-level changes stay deliberate approval boundaries

Do not bypass these from Mac UI, iOS, Telegram, Slack, local bridge, Workshop execution, scheduler jobs, or app-native actions.

## Chat Context Rules

Session selection compares the existing retained turn lifecycle across its
awaited transcript load. A local turn that advances or finishes during that
load keeps its newer rows and receipt; selecting the requested conversation
still succeeds without applying the stale snapshot. Unchanged loads continue
to apply the authoritative fetched transcript.
Detached chat rechecks that same lifecycle and stream ownership after both
message and receipt awaits, so a later result cannot overwrite a newer turn's
rows, receipt or freshness status. Genuine read failures remain visible.

- Stable cache layout is persona/pins plus the current lazy tool
  contract/catalog. Put that prefix before volatile recall, rendered history,
  clock, route, and organism context. Loading/unloading tools intentionally
  changes the stable prefix once; an ordinary user turn does not.
- Append-only message cache markers only reuse repeated calls inside one tool
  loop. Ordinary text-compatible turns construct independent message arrays,
  so cross-turn reuse must come from the stable system breakpoint.
- Dynamic tail may include current time/date, current surface/provider/model, short session continuity, and bounded recent context.
- Durable persona/memory should be lazily loaded and compact.
- Use MemoryV2 recall/KG/session search when needed, not always-loaded bulk.
- Middle-of-session continuity matters: use continuity cards and targeted session search rather than only the last one or two messages.
- Tool results pass through the fast tool gateway and should be compressed into bounded source/hash/preview envelopes when large.

## Background Loops

Background loops are app-owned Swift loops. They belong in `BackgroundLoopsAssembly+*.swift`, the scheduler, or explicit runner modules.

Current loop families include:

- chat surfaces: Telegram, Slack, iCloud/iOS chat
- dreams/memory: nightly dream, REM, hygiene/consolidation
- heartbeat/self-healing: app health and self-improvement checks
- maintenance: snapshots, inbox cleanup, receipts
- Workshop/autonomy: proactive scans and directed-work execution gates

`LoopRunner.tickOutcome()` is the scheduler's truth boundary. Simple loops may
use the default completed outcome, but any loop that catches operational failure
must return `.failed` rather than treating function return as success. The
production scheduler records bounded failure evidence at
`data/logs/background_loop_failures.jsonl`; disabled/not-due work returns a
typed skipped outcome. Token-spending idempotency reservations fail closed on
marker or flock errors.

One schedule should have one canonical owner. Dreams are one 03:30 America/Chicago nightly run for the previous Central calendar day.

The retired cue-authoring lane is absent from the loop manifest, runtime,
provider surfaces, persistence families, and package targets. Legacy cue
receipts and inert node metadata drain idempotently when the cognition store
opens. Do not recreate a model-spending lane unless a current consumer and
acceptance contract first prove it belongs in the resident agent's living path.

## Connector Rules

- A connector is not real because OAuth/token storage exists.
- Non-status actions require a live account/status proof where applicable.
- Gmail, Google Calendar, and Notion expose read-only, bounded lazy tools. Their
  setup state, token proof, and tool dispatch share the exact connector data
  root; nominal write descriptors remain unavailable until a verified effect
  adapter exists.
- Slack is a chat surface with its own provider picker and session behavior.
- Visible Browser is an app-native WKWebView tool surface, not an OAuth connector.
  Core `Browser/runs.json` owns its durable lifecycle through one operation
  reducer. The app asks Core to persist `running` before WebKit starts and keeps
  only a process-local run-ID registry to cancel the matching Task/navigation;
  canonical cancellation is terminal against late capture or completion writes,
  and launch fails stranded prior-process runs as outcome-unknown without
  reopening them. Its shared-motor adapter is read-only and payload-free; even a
  dry run remains nonterminal/cancellable because the canonical owner can still
  transition it to canceled.
- X social connector is separate from xAI OAuth model provider.

## Build And Test Baseline

Assemble the coherent change, build the integrated target, then run the
proportionate finished-workflow validation. The
[validation map](README.md#validation-boundaries) distinguishes package tests,
whole-repository coverage, installed behavior, and exact-source release proof.

`script/lib/development_bundle_signing.sh` is the single mechanical owner for
development build/install signing: identity discovery, stale-override refusal,
profile membership and embedding, profile-derived app/team identifiers,
background-task entitlement stripping, DER hardened-runtime signing, guarded
ad-hoc signing, explicit-only development fallback, and deep strict final
verification. `build_and_run.sh` and `install_app.sh` supply their paths and
intent but must not copy that behavior.

Release publication consumes one exact attestation binding source revision,
canonical test-receipt digest including required iOS proof, final DMG bytes and
SHA-256, and app/DMG notarization plus stapling state. The publisher validates,
uploads, and reads back the appcast, DMG, receipt, and attestation exact bytes;
the receipt is an uploaded release asset whose recomputed digest must match the
attestation. The iOS release gate inventories every production/test source and
resource, requires the shared Build/Test action, and verifies XcodeGen
reproduction; no untested companion source may sit outside the release graph.

Build/test planning is inventory-driven: `build_and_run.sh` touches the package
manifest only when the deterministic source/resource path inventory changes,
and Core shard reuse is allowed only while the full Core source-content digest
is stable. Release archives the exact private dSYM by version/source, verifies
UUID and digest, strips local symbols before signing, and requires the final
artifact to contain no non-external symbols. CoreML compiled artifacts live in
the user cache keyed by model, exact OS build, and artifact digest, with one
cross-process lock, atomic publication, load-failure self-heal, and bounded
retention. Generated-artifact cleanup is dry-run by default, allowlisted to
rebuildable caches, refuses active builds, and never targets persona, user data,
distribution artifacts, quarantine, or receipts. Non-WMO compilation remains
unadopted until the benchmark and separate runtime proof meet their thresholds.

```bash
swift build --jobs 4 --force-resolved-versions --skip-update
# Select final checks by the changed boundary, not all of these per edit.
swift test --package-path Modules/NativeAgentCore --no-parallel
swift test --package-path Modules/NativeAgentShared
swift test --no-parallel
./script/test.sh
./script/test.sh --require-ios
./script/smoke_all.sh
./script/install_app.sh
```

For Mac runtime behavior changes, install with `./script/install_app.sh`. For iOS changes, build the iOS project with an installed simulator destination.

`script/test.sh` includes script/inventory/iOS-release guards, Node builder and
Chrome extension tests, Core
XCTest and serial Swift Testing shards, Shared, root Mac tests, and the iOS
runner. Its ordinary iOS lane can report unavailable/skipped; release receipt
mode cannot. The Chrome extension's Node suite also has a focused entry point
in its [guide](../Extensions/NativeAgentChrome/README.md); relay tests live in the
root package. No package gate alone proves installed perception, provider
behavior, locked-phone delivery, or a fresh-machine launch.

## Refactor Rules

- Prefer existing module/file-family ownership over new abstractions.
- Split by real ownership, not line count alone.
- Keep observable stored state centralized unless there is a clear feature-owned state object.
- Do not add duplicate roots, duplicate dispatchers, duplicate schedulers, or duplicate bridge paths.
- Keep public/default builds identity-neutral; local names come from runtime profile/persona/config.
- Update this blueprint when architecture ownership changes.

## Persona compiler

| File | Responsibility |
| --- | --- |
| `PersonaEngine+Compiler.swift` | Persona packet/profile contracts, compilation and document reads, display-name resolution, and growth summary. |
| `PersonaCompiler+Normalization.swift` | Profile normalization, normalized keys, and its private coercion/list/date helpers, moved verbatim from PersonaCompiler. |

## Dream cycle contracts

| File | Responsibility |
| --- | --- |
| `DreamCycleRunner.swift` | Nightly dream orchestration, diary/high-water writes, mood integration and prompt/entry rendering. |
| `DreamCycleRunner+Messages.swift` | Same-actor cross-session message/recollection gathering, unchanged count/character budgets and timestamp parsing. |
| `DreamPayload.swift` | Decoded dream model payload with unchanged required-field and nonblank validation. |
| `DreamRunReservation.swift` | Shared dream/REM nonblocking flock reservation, moved unchanged from the dream runner. |
| `DreamCycleContracts.swift` | Dream triggers/reports, memory/felt-context provider aliases, felt-origin identity, and receipt/mood sink contracts; declarations moved verbatim from the runner. |
