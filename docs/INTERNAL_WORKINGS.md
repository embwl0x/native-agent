# NativeAgent Internal Workings

NativeAgent is one Mac-owned runtime. `NativeAgentEngine` in `EngineRuntime` assembles clients, stores and app ports.
Launch attempts each operation owner's recovery, then joins seed installation and
housekeeping before constructing the engine. A Mac-control or browser recovery
failure leaves that owner's new effects unavailable, with its cause and repair;
chat, phone ingress, looks and unrelated surfaces still start. Mac-control's
`MacControlOperationStore.begin` and browser's `commitStart` each read their
owner's path-scoped recovery state before admitting a new effect. No completed
recovery means unavailable, never permission to act. Repair the named evidence,
reconcile unknown effects by observation, then restart to recover. Doctor's
`live.mac_operation_recovery` and `live.browser_operation_recovery` read these
same owners; reading Doctor never runs recovery.
The typed browser status projection preserves `recoveryIssue`, `admissionIssues`
and named `unavailableRuns` through the runtime readout to `browser.status`.
`ChatTurnRuntime` owns the turn engine. Conversation surfaces share that core
while retaining their own admission and delivery boundaries.
Background notifications call the supplied `AttentionRouter` directly; Trust's
checked connector statuses use the same supplied connector platform.
Needs-you counts and kinds derive from `DeskFacade`'s retained overview and are
unavailable when any overview source is unavailable; AppModel stores no copies.
Helper schedules and reminder settings retain their source errors on the Desk;
unreadable settings cannot appear as reminders switched off. Contact snapshots
require their conversation, helper shelf and active-run sources to read.

Trust registers one native face on `engine.pages` at launch, invalidated by its
policy, integration, contact, backup and activity owners and their exact change
notifications. `EngineTrustFace` reads those checked owners; a source failure
occupies its own row while unrelated sources remain readable. The Mac page,
Simple setup panel and offscreen page host draw `FacePageView`; the door reads
the face's text instead of a separate Trust projection. The privacy inventory
uses `TrustFacade.privacyMap`, sampled initially and on explicit Refresh, with
its reading time shown instead of rescanning the data root on every receipt.

The Trust action port receives `PartFaces.Actor`. Person changes use the
existing policy, integration, contact and activity mutation owners; controls
that can grant more access carry `Control.confirm`. The agent's held Turn goes
through the existing `setting.set` door checks; it is never turned into a
person action. Foreground permission acquisition, Chrome setup, the app picker
and the freeform workbench use the existing Mac adapters. Phone face actions
cannot open those controls. The existing phone Trust editor and
`trust_policy.json` publication stay in place until the phone face migration.
Desk registers once on `engine.pages`. `DeskFace` reads `DeskFacade.loadPage()`;
its epoch is the Desk store revision captured before that board read. Board
publication and selected-item changes refresh the face through the page port.
Selection holds only the handle on `DeskFacade`; details resolve against its
retained board. Mac navigation, slash previews, offscreen capture and the door
all read that face, and phone snapshots include it in `faces.json`. Desk's old
phone snapshot files remain until the companion transition. Face row actions
use `DeskToolDispatchRouter` and the existing pursuit veto owner. The mounted
Desk face supplies only editor/navigation/clipboard requests; absent mounted
faces refuse those requests. Offscreen capture installs no editor port. No
second board projection or write owner is introduced.

## Built-in browser operation ownership

`SwiftNativeBrowserClient` owns the current run array and transition outbox.
Launch recovers interrupted browser operations before engine construction and
ingress; an unreadable document or failed receipt projection refuses browser
starts with the recovery cause and repair while the app starts. Recovery keeps
unknown external outcomes unknown and never reopens a URL. The app-wide
interrupted-operation alert and its launch-abort callback are removed.

Browser previews validate and return proposed runs in memory, before any run,
receipt, trace or retention command. Every claimed page effect includes its
preflight read in the completion/settlement boundary. The canonical reader checks
run identity, required fields, current status vocabulary, timestamps, transition
counters and each outbox snapshot before any mutation or projection. A damaged
row reads as a named unavailable run; valid siblings still read, recover and
project. Mutations splice each damaged row's original JSON bytes unchanged and
retention never evicts it. A damaged row without explicit terminal status, a
parseable completion timestamp and an unambiguous identity keeps browser starts
unavailable: it cannot establish that its effect ended. A damaged terminal run
remains individually unavailable without blocking unrelated starts. Matching
motor and approval-reconciliation reads throw its named cause rather than
treating it as missing or terminal. Whole-document decoding/I/O failure stays
owner-wide unavailable. An unmatched read cannot infer absence from an
unidentified damaged row. Only a missing run file starts empty. Pre-outbox
translation, the old terminal spelling and persisted-preview
cancellation/retention are removed.

The visible WebKit adapter has one native bounded callback owner: navigation
waits at most 30 seconds; snapshot, JavaScript and DOM callbacks wait at most
10 seconds, independently of the DOM script's 3750ms readiness deadline; an
earlier inherited tool-call ceiling ends the same native wait. A parking wake
without a callback result is an interruption, never evidence of completion.
Cancellation, native deadline expiry or renderer termination ends that wait
once and retires the affected view. This is not proof that a dispatched effect
was stopped: its outcome remains unknown. Late callbacks cannot change that
settlement or release a later owner; there is no automatic replay or page reload.
A later explicit navigation establishes a new page.

Browser IPC admits connections and Doctor reports readiness only after checked,
private `browser_ipc.json` publication. Publication failure closes the listener
and retains the cause for Doctor. Browser approval adapters return the actual
run to the existing checked approval settlement owner; malformed approvals throw
after their failure annotation is attempted. A failed annotation retains the
outcome for receipt-only repair and reports both the outcome and save failure.

## Shared runtime projections

Inbox registers one `engine.pages` face at launch. `InboxFace` reads
`ForPerson.at(root).matters()`, applies the owner's `isRow` and `reading`,
and groups active matters into requests, failures and unread-first news.
Earlier is an archived-in-the-last-day count; missing or unreadable settlement
times are named and excluded from the count. The epoch is the read-start moment
in wall-clock milliseconds because the reading exposes no record position.
One cancellable subscription to `ForPerson.changes()` refreshes the face;
`InboxFacade` holds the subscription lifetime, with no file watch or poll.
PartFaces' LatestRead remains the only publication gate.

Mac Activity's Inbox/Approvals and inbox/approval work details draw
`FacePageView(page: "inbox")`. The door's list read reaches the generic face
hook; individual note reads retain the existing Inbox detail owner. Notifications
projects preferences and trigger settings, with a pointer to the Inbox face
instead of a second card list. Earlier opens the existing preferences history;
the chat capsule retains its detail instrument and native transaction adapter.
Person actions call the existing Inbox host or ApprovalsFacade/ApprovalExecution;
agent actions call the existing `inbox.*` actions with the original turn. An
approval without readable details or awaiting the agent's own decision cannot
be decided by a person face action. At the phone's door the face actor carries
the paired device the router verified (`Actor.person(door:device:)`), so a phone
approval resolves through ApprovalExecution with `signedIOS` provenance, as the
signed approval card does; without a verified device it is refused, and no
identity is synthesized. `inbox.json` and
`approvals.json` publication remains for existing phone builds; `faces.json`
carries the Inbox face through the existing face publication path.

Model pickers advertise models and think/fast capabilities only from the selected
account's checked catalog. A saved unknown model stays visible as unverified,
with no invented capabilities; a missing catalog does not produce compiled or
provider-neutral replacement choices. Empty capability metadata offers no
controls and never invents a high think level or borrows another account's row.
An account projection or adoption inventory error is reported with its cause.
Session context usage distinguishes an absent initial provider receipt (a named
transcript estimate) from a damaged receipt or transcript, which is unavailable.
After a turn, an unavailable session index keeps the prior display with its
refresh error; checked persona-document reads retain their own error independently
of the reply that already landed.

Personality has one native `PartFace` on `engine.pages`, registered at launch.
Its read uses PersonaFacade's checked profile/documents, the resident self-reading,
ProviderRouting's checked catalog, CognitionViewFacade's diary and ApprovalsFacade's
waiting self-improvement cards. Source-file changes and the account-model refresh
notification reread it even when no view is mounted. The resident's bootstrap
and configuration events also refresh self-reading availability. The read-start moment is its
epoch; PartFaces' LatestRead owns publication. Mac FacePageView and the door's
generic face text read the same sections. The model choice calls the existing
Memory and mind group setter. Links retain the document/starter editor, minds
picker, Dreams and confirmed reset as destinations, and proposal review remains
in its approval card. No persona write or reset mechanism changes.

Persona reads return authored contents as written, including GROWTH; they never
filter old-format rows or recreate authored documents. Ordinary persona tool
replacement, section append and editor saves require a checked existing UTF-8
document under its write lock before backup or mutation. A missing or unreadable
document fails with its full path and repair remedy; only explicit setup or
the compiler's missing-only genesis below creates it. The recovery copy retains the exact
bytes of that checked read. REM lesson
approval requires a checked existing GROWTH read under its write lock; a missing or
unreadable document fails application with its path and repair remedy, before
writing the lesson or marking the proposal approved. The compiler requires SOUL,
VOICE, USER, GROWTH and AGENTS; absent custom overrides explicitly inherit the
canonical document, while only MEMORY and surface guidance may be absent.
Onboarding seeds the five required documents in its completion transaction.
Before reading a required canonical document, every compile and context snapshot
asks PersonaEngine to create that named document only if its entry is checked
absent. Genesis requires completed onboarding and a checked saved profile,
rechecks absence under the completion and document locks, and uses the same
template owner as onboarding. It needs no Doctor Repair press. Missing USER.md
uses the saved userName when present; with no supplied name its genesis is the
blank User header. A malformed userName fails USER genesis. Existing entries,
including unreadable files and dangling links, are preserved and fail with their
own path and repair. Listing remains read-only; Doctor uses the same compiler.
`NativeAgentPublicSafety.hasCompletedOnboarding` owns completion for resident
admission, setup and USER generation: pending completion/reset blocks it, and
only the completion sentinel proves it. The sentinel travels in local/off-disk
backups and production exports with the identity data. Restore replaces only
captured paths, so an uncaptured sentinel leaves live completion evidence
unchanged; absence never invents completion. Profile reads/ordinary updates
require the saved identity; explicit onboarding or missing-profile repair supplies
genesis inputs. PersonaSelection alone chooses a custom directory. Name
presentation uses PersonaFacade's checked identity state, never memory or picker
text. Until that read succeeds, the name is blank and the error stays separate;
no loading/failure sentence is published as a name. Widget publication waits
for an available name while other work-status effects continue. Synchronous
notification name reads also return no label on failure, retaining their cause
in the diagnostic log. Saved instruction keys in older profiles remain opaque
preserved bytes;
persona documents alone supply those instructions. A committed document save
invalidates context even if readback fails; activity bookkeeping has its own
owed repair and cannot turn the saved edit into an unsuccessful append.

The agent reaches the system through one always-on `app` tool. `app {}` is
home—where they left off. Pages, home items, discovery, actions and scripts
reach the rest of the app. [Tool loading](TOOL_LOADING.md) defines that contract.

## The complete system in one flow

```mermaid
flowchart TD
    A["Accepted message"] --> B["Persona, selected context, history and optional inner state"]
    B --> C["Selected model, one app tool"]
    C --> D{"Answer or action?"}
    D -- "action" --> E["Trust and domain execution"]
    E --> F["Result and outcome evidence"]
    F --> C
    D -- "answer" --> G["Transcript and terminal settlement"]
    G --> H["After-turn interpretation and review candidates"]
    H --> I["Canonical memory or approved growth"]
    I --> B
```

## What “Fluid Context” means across the system

The Context module compiles and selects derived material; it does not own the
underlying facts. `NativeContextFlowRuntime` coordinates publication and turn
preparation. An immutable generation holds typed atoms; the bounded RAM arena
holds budget/eviction descriptors, lexical indexes and required-document mirrors.

Context configuration supplies defaults only for absent settings: mode `active` and a 96 MiB
arena. A present invalid `contextFlowMode`, `NATIVE_AGENT_CONTEXT_FLOW_MODE` or
`contextFlowRAMMiB` is unavailable with its startup cause; it never selects
another mode or budget. Saved values are checked even under an environment
override or public onboarding's temporary `off`. Turn admission, embedding
tickets, mode status and bridge health preserve that failure. Enabling inner
life initializes only an absent mode; it does not replace invalid saved bytes.
Settings shows an invalid saved mode as unavailable. A mode write whose checked
status has no effective mode reports that cause through the Settings warning or
the setting action's unavailable error; it never labels or returns a default mode.

Settings registers one native face on `engine.pages`. It reads
`QuietSettings.settings(forPage:host:)` through the mounted settings host and
projects each row's declared kind, value, choices and owner note. The read-start
wall-clock milliseconds are its source epoch. A control's `set` calls that
registry row's existing writer and reads it back; the Mac and authenticated
phone face gestures enter with owner authority. Agent face actions use
`setting.set` with their actual turn and its existing Trust admission, including
the inner-life recovery button. Platform update, reference and
clipboard actions remain with their Mac owners. Cognition, Mac access and
memory status read their existing runtime owners. Settings watches its owner
files and notifications at launch, independent of page visibility. Registry
rows declare their defaults keys; only changes to those preferences wake the
face. App-lifetime observation carries updater, shortcut, app health and memory
runtime changes, and cognition's change stream carries inner-life status.
Registry page reads enumerate peer consent rows only for Trust,
so unreadable contacts cannot block an unrelated Settings page. The Mac and door draw/read
the same face; the existing phone settings request remains in production until
the companion switches to `faces.json["settings"]`.

A failed source compilation excludes that source's old atoms from new selection
and expansion while independent healthy sources remain usable. Discovery,
registry, health persistence or publication failures keep new turn preparation
unavailable until reconciliation succeeds. Already leased generations retain
their own immutable snapshot. Feedback restore or reduction failure remains
unavailable; an empty learned history cannot stand in for a failed read.
Committed reconciliation retains each source failure's identity even before its
first stored row exists. The same checked failure snapshot accompanies selection
receipts and the turn's ambient reads; an empty ambient result with unavailable
sources neither reports `no_match` nor settles recollection repair debt.

Persona, MemoryV2, Desk and skills retain their own authority. Conversation
history is read separately from the transcript store. The optional cognitive
capsule joins these inputs as advisory state. The turn engine assembles the
provider request from them.

Context and history preparation read the model admission held on their turn;
fresh ephemeral work admits it before preparation and retains that same turn
through execution. History renderers require a checked resolved budget, with no
optional-window entry. Missing admission or window stops preparation. See the
[history contract](conversation-context-history.md).

Provider admission uses the selected account's checked catalog and explicit
provider/model/control tuple. A required failed or stale catalog refresh,
unknown window or unsupported explicit control refuses the dependent operation.
A catalog/control failure leaves only the surfaces using that provider tuple
unavailable, with their cause; independent healthy provider groups still route.
Saving a group validates that group's resulting tuple before publishing intent.
Work and Memory and mind inherit Chat only when no override is saved. A partial
or conflicting override is unavailable for the whole group, naming its saved
keys and the Providers repair controls; a caller-supplied model cannot bypass
that refusal. Effort-only and tier-only rows inherit Chat's other fields and
validate the retained control. Account-only changes preserve the saved model;
an incompatible model requires an explicit combined account/model choice.
Picker persistence keeps one forward intent. Failed projection writes never
restore previous choices: readback reports the intent's state and the committed,
pending or unknown projections. The existing reconciler completes retained intent
on a later checked read or reports the actual conflict; no arrival is promised.
Fetched API-key catalog bytes carry `credential_binding`, checked against the
current credential on every passive/routing/availability read as well as fetch
publication. Unbound or mismatched bytes stay historical and unavailable until
an explicit refresh succeeds. A settings refresh publishes one catalog operation's
result and cause, without a second cache-mode call after failure.
OpenAI public controls use its shipped descriptor; Codex and ChatGPT controls use
the selected sign-in's matched account catalog. Builder bridge tools use the
command CLI's sign-in; runtime adapters retain their exact admitted sign-in path.
Moonshot rows with no declared adapter reasoning contract keep unknown controls
and carry `controls_note`; they do not advertise a synthetic `none` effort.
OpenRouter's current catalog supplies its per-model `reasoning.supported_efforts`
and `default_effort` through cache, picker, routing and transport admission.
The explicit `default` choice permits provider-default execution without a
reasoning field, including models with no effort selector. Explicit efforts
travel unchanged and are checked against that model's declared list.
Mandatory reasoning excludes `none`. An unavailable
catalog or unknown control evidence requires a Providers refresh.
Credentials stay bound to the runtime's data root; unreadable credentials keep
their cause rather than becoming an ordinary signed-out state. With CLI adoption
allowed and the app-owned credential absent, a present Codex CLI credential stays
selected even if unreadable or malformed: the checked reader reports its path
and repair, preserving the bytes. A valid file without `tokens.access_token`
(including Codex CLI API-key mode) has no ChatGPT session to adopt; it is not a
credential-read error. Credential reads follow symlinks to regular files, and
atomic token writes replace the resolved target, preserving the link. A dangling
or unreadable link reports its own read failure. Sign-out reports completed app
credential removal even when the independent shared CLI session cannot be read,
and names that inspection failure separately.
Introspection reads the admitted turn provider identity and reports unavailable if it is
missing; model spelling cannot establish the transport or account.
Native OAuth connection checks bind their receipt to the outgoing Authorization
header at the transport send, including a renewed attempt after 401. API-key
drafts never publish a saved-credential receipt. A check without a fingerprint
cannot establish saved-account health. A failed connection attempt reports its
cause even when admission or refresh prevented any request; credential matching
gates only successful verification, never the failure verdict. Image generation, read-aloud and
tail fitting propagate their credential or routing owner's checked read failure.
The saved connection-check owner reads and merges only the
`llm.provider_status.v2` envelope. Every new check uses the row codec before
saving; each `byProvider` row is decoded independently on read. A malformed
row remains a named failure for that provider while sibling checks can be saved,
preserving unrelated rows as JSON values. A fresh check replaces only its own
row and the latest-check copy; damage in that copy cannot gate sibling rows.
Unreadable envelope bytes block the merge. A confirmed missing file alone starts
an empty history. Saved-account checks propagate receipt-write failures to the
caller; draft-key checks return their probe result without writing verification.
No file timestamp can bind a check to a key.
Provider preference responses use the saved `SurfacePreference` vocabulary:
`surface`, `model`, `reasoningEffort`, `serviceTier`. Current phone selection
uses `configure_surface_selection` with its complete tuple. The older
`configure_provider`, `set_active_provider` and `set_surface_model` readers
remain pending inspection of retained transaction bytes in the previous
iCloud container; unavailable archive bytes cannot establish that no caller
remains. Sealed credential setup stays separate from model selection.
<a id="oauth-token-response-contract"></a>

Anthropic and xAI own flat token sets; their readers and refresh writers use
that format directly. xAI's flat secret fields live in its referenced Keychain
object. ChatGPT's current grant remains under `tokens`, with its persisted
expiry on the enclosing object. `anthropic_mcp`, `xai-oauth`, `grok-oauth`,
`x-ai-oauth`, `xai-grok-oauth` and the provider ID `kimi` have no routing aliases
or catalog rows; Anthropic setup uses direct OAuth or an API key, with no
Claude MCP process panel or local CLI-presence probe.

Every OAuth token response crosses `OAuthGrantOperations.validateTokenResponse`
before any credential update: ChatGPT, Anthropic and xAI sign-in/refresh, and
Keyring browser/device sign-in and renewal. Access tokens and refresh tokens
must be nonempty strings without whitespace or control characters.
ChatGPT, Anthropic and xAI initial grants require refresh authority to maintain
their ongoing sessions; a generic Keyring initial grant may omit it and is then
nonrenewable. Every refresh response may omit or return null for `refresh_token`, retaining the
existing saved refresh token; a supplied empty or whitespace token is malformed.
`expires_in` is optional: omission or null means no stated expiry; a supplied value must
be a positive finite number or numeric string. The preceding access token's expiry is cleared
when none is supplied; undated Anthropic and Keyring access is used until rejected.
The network response is validated for the grant's tokens and lifetime, not against
the saved-file metadata schema (for example, `scope` and `account_id` are not
required credential fields in a token response).
Device authorization separately requires a positive code
lifetime to bound polling. Malformed token data reports `.malformedResponse`
with its retry remedy and leaves the saved grant unchanged. This is the token
response contract in [RFC 6749 §§5.1 and 6](https://www.rfc-editor.org/rfc/rfc6749.html#section-5.1).
xAI persistence
failures read back the committed reference, report that state or its read failure, and retain
Keychain items without restoring old metadata. Previous-item cleanup follows
successful checks of both the new metadata and its referenced Keychain bytes.

## 1. Anatomy of resident context and a turn

A turn combines a checked provider route, selected Context atoms, bounded
history and optional inner state. The resident turn part decides the work;
see [Anatomy of a Turn](ANATOMY_OF_A_TURN.md) for its execution and settlement
from the request and actual tool activity. The prepared Context turn leases
one generation through the model/action loop; a later source
change belongs to a later generation.

Stable persona material leads the provider prefix, followed by the verbatim
conversation tail. At the model-default window bound, a whole oldest block leaves
replay at stateless half-budget checkpoints; transcript rows remain saved. `ConversationPrefixSeeding.seed` applies the
[sent-context contract](conversation-context-history.md) before provider dispatch.
The resident turn's replay metadata write and context/prefix diagnostics run
beside dispatch and join before tool reads or turn settlement; the in-memory
seed alone supplies the request. Exact-source/version idle turn programs
retain their opened JavaScript body and realm; each call replaces frozen
input and uses the requesting turn's journal and host reach.
The `app` schema stays fixed while action discovery travels in results.
Documents and skill bodies are retrieved when needed. There is no tool preload
or session tool-loading lifecycle.

Turn preparation reuses pure decoded/rendered history only when its input
bytes match; transcript reads, replay admission and live contacts still belong
to the current turn. The [turn timeline](ANATOMY_OF_A_TURN.md#measuring-the-work-before-the-model)
defines the bounded memos and distinguishes route dispatch from the later
URLSession send attempt.

See [Anatomy of a Turn](ANATOMY_OF_A_TURN.md) for admission, streaming,
dispatch and settlement, including
[prompt caching](ANATOMY_OF_A_TURN.md#how-prompt-caching-reduces-token-cost).
Live delivery belongs to the session's `SessionTurnDelivery` owner, which attaches
the mounted or resident surface recipient on every structured turn, including
approval follow-ups and restart/Desk/queued continuations. Callers may add a
progress observer; they no longer supply the required delivery sink. An unavailable
recipient leaves transcript settlement intact.

## 2. Anatomy of a memory

| Material | Owner |
|---|---|
| Identity and voice | Canonical persona documents |
| Durable facts, corrections and proposals | MemoryV2 |
| Exact conversation wording | Chat transcripts |
| Selected working context | Context projections |
| Felt state and posture | CognitiveSubstrate and Organism |

### How information enters MemoryV2

An explicit `memory.commit` action reaches the canonical memory write path.
After a conversation, the adaptive promoter keeps or stages candidates.

[Memory system map](MEMORY_SYSTEM_MAP.md) owns mutation and read contracts:
provenance, kinds, counted reads, trusted acceptance, untrusted review,
care movements, atomic replacement and rejection protection.

`EngineRuntime/MemoriesFace.swift` reads those owners through `MemoryFacade`
and watches the canonical SQLite database/WAL and memory profile from launch
in `EnginePages`, independently of mounted views. Mac `FacePageView`,
the door's `PartFace.text(door: true)`, and the phone's `faces.json` publication
consume that face. The read uses its start time as the epoch because the
facade exposes no store revision; `PartFaces` owns publication through
`LatestRead`. Failed sections carry their cause while readable siblings remain.
Reading a face with an active query re-ranks through the same search owner
without crediting recall hits; **Check again** also retries a failed search.
Its row actions call the existing pin/delete and proposal accept/reject owners.
Mac navigation retains native destinations for the graph canvas, full text and
correction draft, and upkeep. Inline search input and disclosure folds are not
in the face vocabulary; `/memory` supplies the existing search owner a query.
The Mac continues writing the existing phone memory snapshots during the
phone's transition to the shared face.

The current after-turn path uses one model interpretation for facts, cares
and semantic appraisal; routing follows [cognition wiring](COGNITION_WIRING.md#shared-after-turn-interpretation).
Before this pass the agent's own labelled record predicts whether the
interpretation would be a complete no-op. User's own conversation keeps live
judgment unless that claim stands; every other recorded turn is left owed
and judged later with other owed turns in one batch call.
Details, the cost law and its assumptions are in
[cognition wiring](COGNITION_WIRING.md#shared-after-turn-interpretation).
Peer conversations identify their speaker so a peer's words are not
mistaken for facts about the human.

### When the work happens

After the assistant row is durable, its `AfterReply` follows the
[owed-recording contract](SUBCONSCIOUS.md#lived-moments), then releases private work.
A process exit can interrupt unfinished promotion without losing the already
written transcript.

### Acceptance, correction and recall

Canonical changes trigger derived-memory refreshes. The generated `USER.md`
is a projection of eligible active memories, not a place to repair facts by
hand.
Knowledge Graph and Context projections do not replace MemoryV2's authority.

Retirement and retention follow the [memory contract](MEMORY_SYSTEM_MAP.md#consolidation-and-hygiene).

Relevant memories can arrive through resident selection. `memory.recall`
supports deeper retrieval, while `chat.search` and `chat.message` recover
conversation wording. Skills are built-in guidance, read through `ability.read`; what they writes is a
ability, saved with `ability.save` and run as `authored.<id>`, with `ability.enable`,
`ability.resume`, `ability.disable` and `ability.drop` in its one lifecycle; see the
[manifest spec](skill_manifest_spec.md). Skills are not factual memory and
grant no new authority.

Source owners: `MemoryV2/MemoryV2+AdaptivePromoter.swift`,
`AdaptiveMemoryPromoter+Recovery.swift`,
`MemoryStorage+Projections.swift`,
`MemoryV2+Proposals.swift`, `MemoryV2+UserMDGen.swift`,
`MemoryV2+Recall.swift` and `ChatTurnRuntime/MindMemoryManager.swift`.
See [Memory system map](MEMORY_SYSTEM_MAP.md) for the store-level map.

## 3. Anatomy of a safe action

An `app` request resolves to an action in `AppActionRegistry.swift`.
Folded actions re-enter the dispatcher under their underlying identity so
saved Trust decisions and domain checks still bind. A page read or discovery
result grants no authority.

Full Mac gives the agent autonomy, including actions otherwise marked the owner's.
The Capabilities autonomy summary uses that same effective unattended-work
verdict; its saved autonomy switch remains labeled separately, including
when that switch is off under Full Mac.

Checked policy, explicit blocks, actual macOS grants and connector
authentication still govern execution. macOS privacy permission resets always
ask the owner. Peer turns follow the [authority contract](TOOL_LOADING.md#authority-and-receipts).

Approval-gated effects consume a durable single-use claim immediately before
dispatch. Replay validates the exact tool, input, surface and payload digest;
unavailable authority fails closed. An already-spent effect with an unknown
outcome is not automatically replayed.

Approval and execution are separate states. An approval authorizes its bound
request; it does not establish that the effect succeeded. Dispatch results and
the domain's verification evidence determine what can be reported. An
uncertain send or interrupted effect must not be presented as confirmed.

Source owners: `TrustCenter/SecurityCenter.swift`,
`TrustCenter/PeerTurnEffectPolicy.swift`,
`ApprovalTransactions/ApprovalTransactionCoordinator.swift` and
`AppToolRuntime/AppToolExecutor+AppDoor.swift`.

## 4. How a native agent grows without losing itself

Different kinds of growth return through different owners:

| Mechanism | Durable destination or influence |
|---|---|
| After-turn memory candidates | Kept MemoryV2 records with their source; an untrusted peer's reviewed |
| Cognitive capsule and organism posture | Optional advisory input to a turn |
| Dream synthesis | Dream diary |
| REM consolidation | Reviewable lessons targeting `GROWTH.md` |
| Skills | Built-in guidance, read through `ability.read` |
| Authored abilities | Kept executable parts exposed as `authored.<id>` |

Dream and REM use `DreamREMCycle`. REM stages growth proposals;
`ApprovalExecution` applies an approved lesson through
`REMGrowthWriter` and its prompt pin. A diary entry alone does not approve a
persona change.
Proposals retain source-bound displaced words for review; old records say
"not recorded". [Cognition wiring](COGNITION_WIRING.md#rem-proposal-replacement-evidence)
owns the retained-evidence contract.

Ability authoring follows `ability.save` → kept (theirs under Full Mac, else the
owner's card through `ability.enable`) → `authored.<id>`, subject to current authority. It adds
no second model-facing tool schema.

Cognitive state remains advisory; Context is derived. Neither replaces persona,
memory or permission stores. See [Cognition Wiring](COGNITION_WIRING.md),
[Organism](ORGANISM.md) and [Automated Systems](AUTOMATED_SYSTEMS.md).

## 5. One persistent mind, specialist hands

One door reaches each other agent: a contact. `agent.message` talks with it;
`agent.job` gives it a job, which runs through that agent's own headless door
(Codex `app-server`, Claude Code `-p` stream-json, ACP or A2A) and comes back
as the agent's own deliverable. `where: <repo>` makes `BuilderWorktreeAllocator`
cut one worktree for the job; the agent applies or discards its diff. The
organ's answer does not by itself verify the work: the job's `done` check does.
`agent: "self"` on the same socket starts a line of them: a turn of theirs in its
own work conversation with their tools, Trust and present, and their written
`instructions` in place of their persona when they gives some. Several lines at
once run side by side, each ending as news where it started
([Jobs](agent-communication.md#jobs)).

Desk tracks work; a job that carries a Desk item is its movement
([Desk](DESK.md)). Delegation does not replace the canonical persona, MemoryV2
or Trust owners.

Source owners: `AgentConversations/AgentJob*.swift`, `AgentConversations/JobDoor*.swift` and
`AgentConversations/BuilderWorktreeAllocator.swift`.
See [Agent conversations](agent-communication.md).

## 6. One agent across every surface

Readout preparation binds the existing or newly created part-face owner
directly. Today binds source bounds and returned faces without forced unwraps;
missing permission, secret-metadata or Desk-overview evidence uses the existing
unavailable projection. A bodyless root refreshes no absent cognition owner;
phone reply recovery reports an absent delivery owner as a failure.

The Mac app hosts the engine. Mac chat and detached windows present its
sessions; Telegram, Slack and local bridges adapt their incoming messages and
outgoing replies to the shared conversation runtime. Their origin and
conversation identities remain attached to the work.
Slack DMs keep their own bindings: an allowlisted sender alone does not prove
ownership and never moves the shared owner conversation anchor.

Anything for them is one experience addressed to `person` (`Experiences/ForPerson.swift`, step 4 Build 4c). Its face is a
`PartFace.Row` (title, detail, symbol, tone, link, actions) plus the words text doors read; an ask owes their `decide`;
each of the person's doors owes `deliver:<door>` (`phone`, `mac`, `telegram:<chat>[:<thread>]`, `slack:<channel>[:<ts>]`,
`conversation:<session>`), declared at birth (`Matter.born`, the one birth shape). Their reading is the matter's
progress (`read`) or outcome (archived, dismissed; an owner's `resolved`). `ForPerson` holds every matter addressed to
them in memory: one record read at launch (`ExperienceStore.addressed(to:)` plus the open ones), then fed by its own
writes and by `written(addressedTo:)`. The inbox (`ForPerson.inbox()`), held deliveries (`owed()`) and the phone's
`inbox.json` are readings of it; no file holds them and no turn queries the record for them. The inbox is a reading,
never a copy of a conversation: a matter is a row when it asks them, went wrong, or has no thread.

The person's doors (`Door.person`): their phone always, the Telegram or Slack thread it came from, and the Mac, which is let go at
send time when their own input does not show them there, so walking up later never alerts again. Two facts replace
importance: an ask needs their answer, and a matter that went wrong is the only thing that breaks their quiet hours.
Routine success reaches no door (`.inbox`). `AttentionRouter.tell` files a matter through ForPerson and sends what is
owed; `watch()` sends whatever a change leaves owed, so an owner below the router only tells ForPerson with its doors.
Each send reserves the door under an attempt and marks it started before the transport runs, then records accepted,
rejected (tried again on launch, network return or a door configured) or outcome_unknown (never resent); a
preference that closes a door lets it go. A door's own receipt (the phone's signed receipt, a Telegram prompt's
message) is accepted whenever it lands. The phone carries `ForPerson.phoneEvent(id)`, the matter's canonical event id.
An answer anywhere closes it everywhere: once `decide` settles, every door still owed lets go. An ask's Telegram
door is its prompt with answer buttons; a conversation door is delivered by its owner (the chat card), never the
router. Putting a matter away lets go what it still owes; an approval or interaction is declined through its
resolve first.

Mac fire-and-forget posts retain the OS verdict under the original occurrence.
The `mac.notify` platform callback requires the calling turn and operation
deadline: its verified session binds banner replies and resident-wake quiet-hour
holding, and its deadline bounds the callback wait.
The native callback wait ends after five seconds or the call's earlier
deadline; expiry leaves the operation alive to settle its original row, and a
missing callback remains unknown. Shutdown closes admission without joining it.
Memory-review crossings retain a source-cycle identity; the same native ledger
owns acceptance. A below-threshold source supersedes its unsent reminder; no
producer flag is spent merely because a reminder was offered.

Telegram downloads and transcribes media inside the destination's tracked
turn. Its poller continues admitting Stop and approval controls while media
is being prepared; Stop cancels preparation and settles that update. Shutdown
returns an interrupted, unstarted media update to pending for recovery in
the conversation pinned when it was admitted.

Approval transactions own decision receipts and reporting turns for Telegram
cards. Telegram acknowledges decisions; reporting answers use the session's
update-delivery journal and send driver. There is no approval-specific answer
transport, continuation payload or retry path. Failure notices use that same
journal: confirmed notices settle as failed-before-answer, uncertain sends stay
unconfirmed, and recovery retains the notice instead of sending a second one.

The mobile companion uses DeviceSync. The Mac verifies signed incoming
commands, executes them and publishes progress, results and snapshots.
Processed-message IDs and completion markers prevent already-executed
commands from being dispatched again after a restart. The phone does not
become the execution or memory owner.

Source owners: `EngineRuntime/NativeAgentEngine.swift`,
`DeviceSync/MacSyncEngine+Inbox.swift` and
`DeviceSync/State/ICloudSyncStatePaths.swift`.
See [Mobile companion](mobile_companion.md).

## 7. Why the owners remain separate

| Question | Authority |
|---|---|
| Who is the agent? | Persona |
| What is durably known? | MemoryV2 |
| What was said? | Transcript store |
| What matters to this turn? | Context selection and turn assembly |
| Which provider/model runs? | ProviderRouting |
| May this action run? | TrustCenter and the domain's gates |
| Did it take effect? | The executing domain's evidence |
| What work remains? | Desk |
| What runs in the background? | BackgroundLoopLifetimes and its registered owners |

One shared engine coordinates these owners. It does not turn a projection,
approval or transport acknowledgment into a different kind of truth.

## Reading path

Source paths above are under `Modules/NativeAgentCore/Sources/`.

- [Anatomy of a Turn](ANATOMY_OF_A_TURN.md)
- [Tool loading](TOOL_LOADING.md)
- [Memory system map](MEMORY_SYSTEM_MAP.md)
- [Automated systems](AUTOMATED_SYSTEMS.md)
- [Architecture Blueprint](ARCHITECTURE_BLUEPRINT.md)
