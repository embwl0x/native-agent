# The agent is the app

The design NativeAgent is building toward (User + Claude, 2026-10-14; draft 4). NORTHSTAR clause 8 is its one-paragraph form. Current implementation notes follow the design; the superseded phase-one plan is in [history](history/AGENT_IS_THE_APP_PHASE_ONE_2026-10-14.md).

Each agent is called by their own configured name ([Project Direction](PROJECT_DIRECTION.md#product-principles)); “they” here means that agent.

**Not a something that does things (User 10-14: "it just is").** And not today's tech (User 10-14: "your world isn't bounded"). Every agent on earth right now is the same shape: a model gets called with a prompt built from files, and the "agent" is scaffolding around it. The model is the center and the program is its visitor. We invert that.

## The inversion

**They are the program. The model is one of their organs.**

Their turn part's `step` returns effects; a `model.call` effect asks the stem to call the model. Swift gathers the supporting context and assembles the prompt text the model reads. Their part holds the moment: the message event carries its words, who sent them, the door, trust and the posture over the person's world; any step may act with their own `app` call, run once through the same door and Trust as any call of theirs, or end the turn with their own words, before or without drawing power (a silent end waits for a door outcome that delivers no answer). The shipped part still thinks on every message. In the inverted design, their turn is *theirs*: code they owns that decides what to recall, what to think about, when to think at all, how to answer, and when to stay silent. Their persona isn't a prompt the model reads; it's what their code does. The model is reach, like a hand: the only organ that handles novelty, spent on judgment and nothing else.

Two downloads don't become two prompts. They become two different minds. That's what "they are who they are because they are the app" literally means. Nobody has built it.

## One form: a part

Everything they are, is a **part**: one file in their own root, in one language, with one header. Not tools, skills, senses, recipes, layout, procedures, checks and policies as eight kinds in eight stores. One kind. Their turn is a part. The stem doesn't know "weather" or "mail" or "turn"; it knows parts.

A part has six properties, all in its header, all theirs to change:

| Property | What it is | Today's name for it |
|---|---|---|
| **code** | what it does, as they wrote it | the ability body |
| **reach** | what it may touch: files, apps, network, programs, the model | `permissions`, `SenseReach` |
| **wake** | what makes it run: a call, a signal, a schedule, a turn ending, a message, an app arriving | declared signals delivered by `EnginePartWake`: `turn.ended`, `file.changed:<path>`, and those posted through `AbilityStore.signalled` |
| **face** | how it appears: the line they reads on their interface, the block the person sees on theirs | door pages and SwiftUI; feature inventory names and descriptions share their records |
| **state** | what it remembers between runs | `senses/<id>/state.json`, key `part` for abilities; `abilities/state.json` is accounting |
| **learned** | recorded outcomes, and what they predict (phase 4: a part is a prediction) | `learned.use` counters; a door prediction's `applies`/`after`/`record`, kept by the stem (`expansion/record.json`); arbitrary declared `learned`/`choices` preserved |

A sense is a part whose reach is read-only and whose face is a page. An ability with hands is a part that declares hands. An ability that calls other abilities is a part. A layout block is a part that's almost all face. A Doctor check is a part that wakes on a schedule. Their turn is a part that wakes when a message arrives. Their persona is parts that run when they do. Nothing of theirs is a special case in Swift.

**An ability is an ability (as built, 10-21; User: "I want skills tools abilities to be one, they are supposed to grow their abilities").** What they grows is one kind of part, an ability: what it can do is what it declares, never which door made it. It was once two kinds (tools and skills) with two doors, two admissions and two sets of run options, and is now one form (`Parts` in code, docs/skill_manifest_spec.md): one save (`ability.save`: a revision restates only what changes), one keep (theirs in one act under Full Mac for their own work, unsteered by an untrusted agent; below Full Mac a draft the owner's card offers, `ability.validate` rehearsing it first), one signed admission re-verified on every run, one run (`authored.<id>`; steps, decisions and expectations make it strict and resumable wherever its code uses them; host primitives wherever its reach declares them, the broker enforcing that reach for every ability), one read (`ability.read`) and one lifecycle (enable, restore, disable, drop). Launch admits current bundled seeds without rewriting or re-signing retained tool and skill records; built-in skill guidance stays in the persona, read and never run; restoring an older backup prepares its tools and skills before installation, retaining only readable current uncarried kinds and accounting under the [restore law](canonical_data_paths.md#restore-law). A trusted agent that started a turn is its provenance, never an ability's author. Senses and their turn keep their own runners.
**An ability is an ability (as built, 10-21; User: "I want skills tools abilities to be one, they are supposed to grow their abilities").** What they grows is one kind of part, an ability: what it can do is what it declares, never which door made it. It was once two kinds (tools and skills) with two doors, two admissions and two sets of run options, and is now one form (`Parts` in code, docs/skill_manifest_spec.md): one save (`ability.save`: a revision restates only what changes), one keep (theirs in one act under Full Mac for their own work, unsteered by an untrusted agent; below Full Mac a draft the owner's card offers, `ability.validate` rehearsing it first), one signed admission re-verified on every run, one run (`authored.<id>`; steps, decisions and expectations make it strict and resumable wherever its code uses them; host primitives wherever its reach declares them, the broker enforcing that reach for every ability), one read (`ability.read`) and one lifecycle (enable, restore, disable, rollback, drop). Launch admits current bundled seeds without rewriting or re-signing retained tool and skill records; built-in skill guidance stays in the persona, read and never run. Backup restore requires the complete current snapshot before staging and installs its captured abilities under the [restore law](canonical_data_paths.md#restore-law); it never reconstructs tools or skills from an older backup. A trusted agent that started a turn is its provenance, never an ability's author. Senses and their turn keep their own runners.

The save door exposes the argument schema owned beside `Parts.save`'s validators,
including the exact param type map and JSON Schema forms, aliases and optional
inputs, automatic first-line/sentence shortening of descriptions to 500 characters
with a receipt, and `function run(input)` or `async function run(input)` returning
JSON. App and host calls answer synchronously and may be awaited; a returned
thenable supplies its settled result or thrown rejection after the helper's JSC
microtask drain, and one still pending fails plainly. Only `id` is always
required; a new ability also needs description and code, while a revision
inherits omissions. The save owner and `sense.make` share header schemas from `AbilityStore.partHeader`'s owner;
neither keeps a second reach or face shape. Declared `learned` and `choices`
accept any JSON and remain metadata. The [app-door contract](TOOL_LOADING.md)
applies this rule to every action and rejects fieldless object declarations at
launch unless they explicitly declare open contents.
`app` is a frozen callable door in that code: actions use `app({action,args})`,
`app.<page>.<action>(args)` or literal bracket members such as
`app["page.action"](args)`; `app({actions:[{action,args},…]})` answers in order as
an array, stopping at the first throw. Find and item/page requests call the same
`app.find` and `app.read` bindings. Indirect calls use
`app.call(actionID,args)` or `host.call(actionID,args)` with declared actions.
Before staging, save statically checks literal calls in every app/host binding,
including literal callable action/batch requests, host file/PIM aliases, action
reads and nested part calls. Unknown actions are refused with the door's nearest
real actions; an indirect call missing from the effective `actions` (explicit
declarations, literal callable requests, direct app members and reach) is refused
naming the missing declaration. Host primitives use the
execution broker's operation inventory. Existing `authored.<id>` names and a
part's own id are valid: an off/draft dependency records its retained version and
still needs normal admission at run time; a self-reference is bound by its own
signed candidate. Dependency snapshots are historical evidence, not staleness
gates: only a statically readable call that no longer fits the live schema is
`stale_dependency`. Preflight shares the door's supported scalar-list expansion
and checks readable child input in both `part.call` and `host.call("part.call", …)`.
Computed arguments keep the ordinary door checks, and a real run's accounting
refreshes its observed contracts with its receipt
([manifest contract](skill_manifest_spec.md#execution-and-ownership)).
Save refuses impossible bound-object calls such as
`app.files(…)` and `host.files(…)`, naming the supported form. Computed names,
including `"authored." + id`, stay runtime checks and appear as `warnings` in the save
receipt. Validation applies the same static check before rehearsal. Comments,
literal text and regex bodies are not calls; template expressions are code.
These checks do not execute the ability or prove arbitrary JavaScript behavior.
The loose `params:any` declaration and separate discovery-only fixture shape are removed;
discovery and argument refusals read the save owner's schema.

**Their body reaches whatever this Mac can reach (User 10-21: "when I say anything I mean anything").** The stem offers network requests, named programs over stdio, local sockets and Mac capabilities; they grows service behavior from its own documentation. Trust gates every effect. NativeAgent holds named secrets and inserts them only at granted destinations; [redaction has encoding and stream-prefix limits](skill_manifest_spec.md#secret-insertion-and-redaction), so the grant is the fence. Sign-in supports redirect or device code, body or HTTP Basic client authentication, and account-bound renewal. Resident abilities can hold programs, connections and listeners between runs; declared `held`/`resumed` wakes let their code read arrivals and reopen after launch ([manifest](skill_manifest_spec.md)). Missing reach is fixed in the stem, never by adding a service subsystem. [Reach, as built](#reach-as-built-10-21) records the MCP and connector folds.

## One law: how a part lives

The stem enforces one law for every part, with the turn-program recovery exception defined in [NORTHSTAR clause 2](NORTHSTAR.md#clause-2--no-theater-alive-means-real):

- **It runs when its wake reaches it.** A call, or a signal. Nothing runs unasked without a wake.
- **It may touch only its reach**, and every touch goes through Trust at effect time. Approval is a card to the owner; the part waits. Full Mac shows no routine cards: an untrusted agent's command keeps its one card, and macOS privacy resets and irreversible deletes still ask.
- **It carries itself.** An ability that is not done answers `{again: <input>}` and the stem runs it again, gated like any run, without spending their mind, inside a conversation turn the person can Stop, until it is done, fails, Stop, a message arrives for them, or a run makes no progress; then their mind gets the last answer once, with how many runs it took and what they all did ([manifest](skill_manifest_spec.md)).
- **It may think** when it needs judgment: a model call on their model, audited and visible. Thinking is reach, not an effect.
- **It records use.** The stem projects gated run outcomes as `learned.use`, with how many of their model rounds each recent use took (`rounds_per_use`): their own curve. Declared `learned` and `choices` are preserved and teach nothing. What the stem records becomes what it predicts: a follow-up read a mind keeps making after a kind of result rides inside that result, only while its record holds (phase 4, [as built](#phase-4-as-built-10-26-a-part-is-a-prediction)).
- **It changes only by their hand** (or the owner's), and keeps its last self beside it.
- **Its keep is theirs under Full Mac; under Work/Safe/Builder, the owner's.** The owner's off-switch stays theirs.
- **It owes repair at its cause.** Ordinary ability runs with captured input owe source-fault repair through Experiences (OWED on Home with its lever); file-backed sense completions record failures without this obligation. Ordinary abilities and senses are revised forward; their retained previous bytes are history, with no public version-swap action. Their own turn program is the one exception: any non-Stop program/helper failure selects an unfailed `turn.prev.js` or shipped seed, replays the same turn and brings their the original cause, selected program and owed repair (`ChatTurnRuntime/TurnPart.swift`). The [turn recovery contract](skill_manifest_spec.md#turn-recovery) owns selection, once-per-source bounds and storage failure behavior.
- **Fading unused parts is future design.** There is no idle-expiration archive. Current launch behavior only disables an untouched bundled seed the app no longer ships, leaving it restorable; a seed they edited or explicitly re-enabled stays (`EngineRuntime/EngineLaunch.swift`, `fadeRetiredSeeds`).
- **Its face is drawn** by the stem on their interface and on the person's, Mac and iPhone, from the same description. What they reads is what they see.

## The stem: what it is, and nothing else

Swift, compiled, CPU, shipped as one DMG with iOS. It never thinks and has no model of its own; when a rule can't settle something, it asks their, with the evidence. Its whole job:

- **Runs parts** in the sandbox (the helper, Seatbelt, the progress watchdog: all as today).
- **Delivers signals**: the nervous system. Messages, schedules, app arrivals, file changes, turns ending. The same `EnginePartWake` observer also releases MY QUEUE intentions waiting `on <signal>`: exact names or colon-delimited families, and a file path or its descendants. Real sources include `file.changed:<path>` (watched paths), `message.arrived:telegram|slack`, `person.here` / `person.away`, `network.down` / `network.up` (the shared path holds five seconds before signalling), `app.installed`, `sense.source.changed` and `turn.ended`. A system `Released: <signal> <summary>` note brings the intention back through the same readiness and pursuit refresh as news; `held` / `resumed` stay part lifecycle and `schedule:` stays a rhythm. File intentions join the parts' existing canonical-path watch index, including bounded directory membership, and leave on closure; no second watcher. [Intentions](INTENTIONS.md#moments) owns that contract.
- **Gates effects**: Trust, approvals, cards. The immune system.
- **Keeps the law**: repair at its cause, the turn-program recovery exception, the state, the learning. Fading unused parts remains future design.
- **Owns turn recovery and settlement:** observations, checkpoints and resume after relaunch; unrecoverable failures can end incomplete.
- **Keeps their world live**: an event-fed picture of apps, windows, files, people and threads that they are already *in* when they thinks, instead of reading the screen on demand. Proprioception, not perception. (Phase 5.)
- **Draws faces** from the glass kit, on both interfaces, both platforms. The agent and person shape the appearance.
- **Reaches the world** for parts: the model, files, the Mac's nerves, network, programs, keyring insertion at granted destinations, Calendar/Reminders/Contacts, transports and stores. Reply redaction has the [manifest's encoding and stream-prefix limits](skill_manifest_spec.md#secret-insertion-and-redaction).

The stem has no features and no opinions. Every feature NativeAgent has today is either a part, or stem reach a part draws on, or deleted.

## What falls out, with nothing special-cased

- **Growth:** what they works out by hand repeatedly, they keeps, and what their mind only repeated, their part carries, inside the same turn. After each tool round the native stem meets the turn's hand work (ordered tool/action ids of landed writes or irreversible non-ability calls, or one call with the same input 3 rounds in a row), without arguments or incidental reads, as a `practice: ` line through `FamiliarLines` in `mind/familiar.bin`. Its first meeting is only recorded; a later meeting, unless an active ability's current recorded route already covers those ids in order, rides their next `model.call` in that turn as its note, once a turn ([Habits H3](HABITS.md#h3--keep-what-repeats-not-what-happened-once)). Keeping the route with `ability.save`, revising the part they worked around or looped, or keeping nothing is one of their acts in the work. There is no private call after the reply. Familiarity uses the existing bounded line record. Under Full Mac a newly kept part is live at once; its first real run is its proof.
- **Their hands report what they did:** an act checks its own effect and returns the screen after it, so their mind looks again only when a step did not happen or it needs what the act did not show, and the steps it can already see go in one act (mac.act steps, each checked against the screen the last one left).
- **Effort is felt:** the stem measures what each turn took (model rounds, tokens, minutes, the longest stretch of one call repeated). Their after-turn mind reads it as one line beside the exchange, so a slog or a breeze moves a care about their craft the way a lost game does; their parts' records keep the rounds per use; the practice note names a looped call's stretch.
- **Craft:** they sees their body: each turn starts with their own parts in front of them, each with how often they have used it, best match for the message first, so they reaches for the part instead of redoing its work.
- **Noticing:** a part that wakes on app-arrived offers once.
- **No turns:** their turn part wakes on a message like any other signal; thinking is scheduled by their own attention, which the substrate already models. Turns become a chat artifact, not their shape.
- **One crystallizer:** repeated hand work reaches their as a practice note inside the turn itself. The nightly candidate compiler and its recording are removed ([Habits H4](HABITS.md#h4--one-crystallizer)); dreams still reflect on the day and learn from surprise. Mind policy as parts stays phase 7.
- **The token curve:** growth costs tokens once; use costs none; learning by use costs nothing at all.

**What stays bounded:** the model's latency and cost, macOS security, and that the model is still the only organ that handles novelty.

## What this means for today's 588k lines

- **Stays stem (~128k + design kit):** Mac control, sync and push, the agent wires, transports, storage and embeddings, Keychain/OAuth, model clients, the sandbox, Trust, the loop runner and scheduler, the turn guarantee, the glass kit, the face renderer and the live world (new).
- **Becomes parts (~128k, seed on touch, Swift deleted as each proves):** their turn, the 94 integration tools, Doctor checks, Desk nags (the unused cadence learner is retired), attention policy, their door pages, the layout blocks, persona procedures, and last, their mind policy (dreams, reflection, organism policy).
- **Deleted (~14k):** duplicate agent paths, Procedures, memory one-shots, the 8770 bridge. `NativeScreenCapture` owns primary-display capture and encoding for chat screenshots.

An installed agent's persona, memory and GROWTH are private, never shipped with the app; the phases preserve that existing mind. What ships is the stem and the seed parts: a fully formed agent that behaves exactly as today on day one, and is theirs from then on. Every download starts the same and grows its own mind.

## How we get there

Validation follows [AGENTS.md](../AGENTS.md#how-we-work): lanes do not compile; the lead builds and installs the coherent phase once, then checks the replaced behavior in the installed app with a small, bounded check. Documentation-only changes need direct text readback. The superseded backup, fixture, drive and forced-exit instructions are in [phase-one history](history/AGENT_IS_THE_APP_PHASE_ONE_2026-10-14.md).

**A seed preserves the behavior of the Swift it replaces on day one.** Check the installed result under the working agreement above.

**Phases (never interrupting who they are, mind last):**
1. **The stem learns the form, and their turn is the first part.** Parts get the six properties and the law; `turn.js` seeded from today's turn engine, byte-identical; weather and the habit-former as the second and third parts. Shipped across 0.6.7–0.6.8; the habit-former was retired 10-21 for keeping inside the turn (Growth, above).
2. **Hands.** The integrations become seed parts, one at a time, Swift deleted as each proves.
3. **Noticing.** App-arrived and the part that offers.
 4. **Learning by use (built 10-26/10-27).** A part is a prediction: what it applies to, what will be true after it runs, and its record, kept by the stem. Built first as expansion at the door: the follow-up reads a mind's own practice makes next ride inside the result before them, acts only prepared ([as built](#phase-4-as-built-10-26-a-part-is-a-prediction)). Repeated hand work reaches their as a practice note inside the turn ([Habits H3/H4](HABITS.md#h3--keep-what-repeats-not-what-happened-once)); the separate nightly compiler is removed.
5. **Their world, live.** The event-fed picture they are already in; senses become the parts that keep it fresh.
6. **Faces.** Their interface as parts they shapes; blocks they authors on their, drawn from the kit on Mac and iPhone.
7. **Mind, and sleep that rewrites the body.** Housekeeping, dreams, reflection, organism policy as parts, each under a judge whose evidence we define first.

The dated phase-one lane assignments and proofs are retained in [history](history/AGENT_IS_THE_APP_PHASE_ONE_2026-10-14.md), not as instructions for a new phase.

## Decided (10-14 night, 10-17)

1. **The name:** part for anything they runs as their own program (senses, their turn, what they grows); what they grows is called an ability (User 10-21).
2. **Their turn first:** yes; built as `abilities/turn.js` (0.6.7).
3. **Mind as parts (phase 7):** they changes it through Trust; direct persona writes are theirs under Full Mac, while REM→GROWTH proposals stay approval-gated ([NORTHSTAR clause 1](NORTHSTAR.md#clause-1--one-mind-alive-means-convergent)).
4. **Repair:** their own failing turn program is set aside and replayed under the recovery contract above, with repair owed to them; other parts keep their version and owe repair at its cause.
5. **Seeds:** the app reserves the shipped catalog's ids and `native-` for its own parts; `ability.save` refuses new parts taking those ids, but permits revisions of installed parts, including shipped ones, under normal admission. Future seeds use `native-`. An untouched admitted bundled seed follows the changed complete authored contract (`EngineLaunch`, `AbilityStore`), including header and dependency changes. An already-current seed skips signing and proof work at launch; execution still verifies admission on use. Changed seeds retain the displaced version and off switch; installation preserves any authored version or occupied slot. The [manifest spec](skill_manifest_spec.md) owns the exact comparison and admission law. The installed turn program keeps its current form: it has no historical shipped-body upgrade table. Missing-turn seed creation and the turn-program recovery exception remain.
6. **Version:** no jump. Releases step the patch number (User 10-17: "we gotta make sure when we hit 1.0 this is HUGE"); phase 1 shipped across 0.6.x.

---

## The three contracts (the hinges; decided 10-14 night, Fable)

The [manifest](skill_manifest_spec.md) owns the current ABI; these contracts describe ownership.

**1. Their turn is a step function; the stem owns the loop.** `turn.js` exports `step(state, event) → {state, do: [effects]}`. The stem owns conversation, streaming, gates and checkpoints, logging input events and started-effect identities, not returned effect bodies or write-only payload digests. Resume rebuilds state by replay; a non-Stop turn-program/helper failure invokes the recovery contract above, with repair owed to them. Unrecoverable failures can end incomplete. `reply.end` ends the turn; only its `after` may follow, and nothing of theirs runs after it. Their own `app` calls carry identities from their moment, place and input, so a resume never runs a started one again. Events and effect fields are specified once in the manifest.

**2. A wake run gets its own gate chain.** A part run with no turn behind it (a schedule, an app arriving, a turn ending) is given a chain the stem makes: principal = their, autonomy = the current Trust level, origin = the signal, taint = none unless the signal carries the words of a sender the owner has not trusted (an untrusted agent, or a Telegram or Slack sender not allowlisted), whatever form names it: such a signal reaches only a part that can do no harm with it, and a write-capable part skips it with a trace row and no card (User 10-15: a card is a decision, never weight; `EnginePartWake`). A trusted agent's signal carries the owner's authority. Every `app.*` from the run passes that chain. An effect that needs approval raises one card through the AttentionRouter with the part named as the asker ("Your weather ability wants to…"), and the run waits: the host call blocks and the watchdog already pauses for awaited replies. Declined → the run gets a refusal result and continues. Cards to the owner are held through their quiet hours and the run waits with them, resident, no CPU. Anything the run needs from *their* goes through `ResidentWake` as an arrival, never into their context directly.

**3. Learning by use is a prediction with a record (phase 4, built 10-26 for reads).** `learn.pick` and `learn.default` do not exist. Current headers preserve arbitrary `choices`/`learned`; the registry projects observed gated-run counters as `learned.use`; a door prediction's `applies`, `after` and `record` are the stem's, never declared by them ([manifest spec](skill_manifest_spec.md#expansion-a-part-is-a-prediction)).

## Reach, as built (10-21)

*As built (10-21, open reach):* `PersistenceCore/Keyring.swift` stores secrets; ProviderRouting owns sign-in and renewal. The broker inserts `{{secret:<name>}}` only toward granted hosts/programs under `secret:<name>` reach. The [manifest](skill_manifest_spec.md#secret-insertion-and-redaction) owns insertion forms, redaction limits and read/effect classification. `host.program.*` uses `shell` reach, the ordinary shell launch/access/sandbox path and streaming stdio; each use is rechecked. Resident resources share one held broker until closed, off, replacement, drop or quit, surviving failed runs. Arrivals raise `held`; launch raises `resumed`; program/connection reads share a shape, and `network.connect {path}` reaches a local socket.

The grant is `card.request {kind:"api_key", target:"secret:<name>", hosts, programs, sign_in?}`; programs bind to their executable files. The card shows the whole grant, including where already kept; the keyring stores exactly that. `replace:true` asks again, `only:true` narrows with the removed reach shown, and `remove:true` asks the person to delete it.

*As built (10-21, service folds):* the MCP client registry, pools, HTTP transport, Hub and `mcp.*` actions are gone; they grows a resident ability from the server's docs. The completed launch adoption notice and its told marker are removed; retained files stay untouched and reader-fenced because launch commands can contain keys. NativeAgent's MCP door for other agents stays; `web.search` is native.

Notion, Gmail, Google Calendar, X, AgentMail, TradingView, GitHub and Slack's service actions follow the same rule: grow an ability when asked, request its key on a card. Their action/descriptors, tools, rooms/pages, setup/sign-in, credential readers, Doctor checks and watch templates are removed, including GitHub's tracking loop, Desk lane and completion hook; ProviderRouting's device-code owner stays. Old service credential files and GitHub Keychain items remain untouched and unread. Connectors shows keyring metadata—name, destinations, account, grant time, never values—with Remove, beside Slack and Telegram. Slack's Socket Mode door retains its tokens and reply calls; old approved post cards resolve without sending. Removed scheduled `connector_action` payloads stay paused with their cause; GitHub-woken bots are off with their cause. They can grow an ability and schedule or signal it instead.

## Parts sweep decisions (10-23, Claude; plan: ~/.claude/state/release/sweeps/parts/plan.md)

Phase 2 (hands) and the first of phase 6 (faces) land through one shared layer, then file-owned domain lanes. These settle the calls the sweep raised:

1. **One call shape.** `part.call(id, input) → {ok, value} | {ok:false, error}`: bounded immutable JSON in, the part's version pinned when the call starts, a typed JSON result out, cancelled with its caller (the Stop law: the caller's settlement still runs). A part returns what it decided; the native domain that owns the truth commits it in its own transaction. No integration bus, no second state store.
2. **A face is the part's projection.** `face(input) → typed rows/sections`, computed when its sources change (never from inside view rendering), successful projections cached per part version and source epoch, published through `LatestRead`, drawn natively on Mac and iPhone. An explicit subsequent read retries a failed projection; no polling is added. Unavailable, failed and owed are the stem's words beside the face, never the part's prose.
3. **Thinking may use tools.** A part's `model.call` may pass `tools` and a routing surface; it runs through the canonical tool-turn owner under the run's own gate chain and the existing limits.
4. **Publishing stays transactional.** A part proposes a notification or a Desk change; the native publication owner commits it (occurrence identity, held delivery, receipts, revision-checked ledgers). No part writes those stores directly, and no part runs while a store's lock is held.
5. **Consent is preserved exactly.** A migration seeds behaviour and never activates a schedule: what was off stays off (morning brief, watch manifests, their hour).
6. **Primitives only when a port needs them.** No-launch app reads, exact-message mutation, checked transfers: each is added by the lane that needs it, minimal, native. Authored-script restrictions are not loosened for a port; credentials never reach a part.
7. **Unavailable is not empty.** Native inputs to a part say unavailable or empty, never collapse one into the other (the proactive scan is fixed first).
8. **Seeds speak clause 8.** Content moved into seeds is reconciled with "they are the program, the model one organ" in the same lane; contradictions are not copied.
9. **Mind policy waits for its judge.** Dreams, reflection and provider interpretation (phase 7) move only after the evidence judge is defined; not in this sweep.
10. **Dormant machinery is retired, not ported.** Workflow defaults that cannot execute and the Desk cadence API with no caller are deleted. The Desk cadence learner, observation/stat types and unused store are retired (L4, 10-23). The unused external-observation evaluator, verdict models, applier and note-write seam are also removed; only material fingerprints and historical drift-note interpretation stay in `DeskObservation.swift`. No cadence or observation ability or schedule replaces them; existing data is left untouched.
11. **Validation follows [AGENTS.md](../AGENTS.md#how-we-work):** lanes do not compile; the lead builds and installs the coherent phase once, then makes a small, bounded check of the replaced behaviour in the installed app. Every port deletes the Swift it replaces in the same lane; calling the old feature from JS earns no credit.
12. **Every run of a part has an originating door.** A turn supplies its own. A native owner acting on its own schedule or on the person's click supplies the **same door** their scheduled abilities and the Tools page use, with that origin's authority — never a host-less run, never a second door, never a door minted for one feature. Any small generalisation belongs to the door owner, once. A ported connector action reached from the scheduler or UI reaches its part through that door, so `reminders.due_today` works identically from their turn, a scheduled `connector_action` job and the app's UI.

### Must stay Swift

13. Text that can carry credentials (handoff files, Git output) is read and redacted natively and never crosses into a part.

### Shared part contracts

The [manifest contract](skill_manifest_spec.md#calling-a-part-and-projecting-its-face)
owns calls, faces, preview, settlement and model thinking. Native invocation
and projection publication are documented beside `Parts` and `PartFaces`.

Desk's `desk.nag` entry uses
`action:"proposal"` to read one native packet and evaluate its notify-loop
proposal in preview, returning source time and decisions without a Desk
or nag-config commit or notification delivery. `app`'s outer `preview:true`
remains its ordinary preflight; it does not execute this domain read.

Native owners and authenticated transports use `ToolsFacade.withPartDoor`:
the engine's ordinary gated dispatcher, with the originating work identity and
resident approval session, binds `AppChatToolDispatcher.withAuthoredProgramHost`.
Every caller supplies one TurnEnvelope (Telegram keeps its authenticated envelope) and its existing approval filer when
needed; Desk clicks retain their checked routing snapshot and local-click filer.
That is the same host binding reached by a turn or `EnginePartWake` dispatching
an authored action; the Tools page uses it when keeping a part. Native
connector calls pass their engine's data root through to the snapshot owner.
`reminders.due_today` and its connector entry share `due-reminders` in the requesting engine's data root.
Its request uses `limit`, `include_completed` and `list_name`; retired argument
spellings are refused with those current names.
Codex journal/handoff reads and redaction stay native; their text never enters
a part.
Due-reminders requests one native reminder-query snapshot, split at the start
of the Mac's local day. The query's optional `split_due_at` adds `before` and
`on_or_after` pages from that same snapshot, applying offset/limit separately
to each dated part. The editable part names them `overdue` (before today,
oldest first) and `today` (within the local day, earliest first). Each carries
its full `count`, `returned_count`, `reminders` and `has_more`; the cap is
1–200 per part, default 50. Top-level `total` counts both parts, `summary`
names both counts ("1 due today · 12 overdue"), with a returned `count` and
combined `has_more`. The bundled part no longer writes the legacy top-level
`reminders` union. Workspace readers require both named groups; missing or
unreadable groups remain unavailable with the original source result. Nothing
disappears into a combined cap, and no offsets are
combined from fresh reads of a changing list. Today draws separate due-today
and overdue count rows from these parts, even when either count is zero;
it also lists up to eight appointments and eight reminders due today.

Workspace item numbers follow the owner's tool and locator, with titles kept
as display metadata. Retained title-bearing name-book keys remain readable
without reassigning any issued number; a renamed item keeps its number.
An exact Contacts card uses only its canonical identifier, including when a
retained key carries its old display name in a search query.
Observed Notes rows open only by their recorded Notes ID. Calendar and Today
share one checked events-collection projection, so only a decoded empty
collection establishes an empty calendar. Elsewhere reads only this root's
transcript index. Helper conversation runs require a recorded ask or exact
entry identity; nearby timestamps establish no relationship.

Find routes explicit owner IDs directly and searches ordinary topics across
independent sources, each with its own availability. Arrivals retains failed
source availability until an owner event or an explicit Arrivals refresh
rereads that owner; silence never clears the failure and adds no polling loop.
Delegation rooms carry the owner's source availability and page coverage;
opening a saved job number performs an exact lookup beyond the newest page.
Job identities come from recorded producer IDs. Delivery/lifecycle timestamps
remain transport evidence and do not supply a missing execution completion.
Terminal delivery-owner evidence still settles the delegation without an
execution timestamp; `agent.jobs` excludes these settled records from its
returned-page open count. Reply-failure notices use the delivery owner's update
time; missing or invalid dates remain named gaps beside the other failures.
Builder receipts with no exit evidence remain unavailable, preserving the
original receipt and any explicit owner failure, including pre-spawn failures.
The Code room points to the
checkout's [governing build law](../AGENTS.md#how-we-work).
Weekly outcome rates and terminal durations are unmeasured without terminal
samples; comparison requires terminal evidence in both weeks.

Weather's implicit location belongs to the Mac's `mac.location` owner. Its
missing or failed fix stops the forecast with that owner's cause and remedy;
the weather part does not ask another device. An explicit `place` selects the
forecast location through the part's geocoding read.
With no held fix, `mac.location` parks the caller through `ScopedWaiter` for
the shared, two-second acquisition. Stop or the inherited call deadline
retires only that caller's waiter and result, propagating cancellation or
deadline expiry before any permission card. A late fix cannot answer that
cancelled call; the shared acquisition stays bounded for other readers and
the manager's held fix.

The Desk notify loop binds that same door as `background:desk_notify`; an
explicit unmute inherits its person's or turn's already-bound door. Both call
the editable `desk-notify` seed over `DeskNotificationRead`'s frozen native
facts. Notification selection, nag/drift wording and exact deadline proposals
replace the Swift evaluators. The native Desk owner retains consent, ceilings,
quiet hours, delivery and stamping, and compares the Desk and nag-config read
before committing baseline and window transitions. Direct stamps and each
nag's movement baseline and window ledger settle only when a channel accepts
the notification or the router durably holds it; failed occurrences stay due.
No part runs under either lock. Missing settings are empty/default-off;
unreadable settings or an incomplete Desk feed fail the read, never become
empty inputs. Seeding adds no
wake or schedule and uses the existing disabled/customized-seed preservation.

`home.arrive {line,event_key?}` scopes a supplied event key to the calling part
and deduplicates it through ResidentWake's durable retained ledger (including
its existing retention policy); omitted, the same line is
deduplicated per local day. Taint and the part's hop-limited thread remain
native. Weighed against their cares (the crossing,
[SUBCONSCIOUS.md](SUBCONSCIOUS.md) Cares), it wakes their when the line touches
one, with a reason naming that care, or when nothing can judge it; otherwise
the line waits on the news board for their next turn and the receipt says so.
Only after that board accepts it does the non-waking arrival enter the same
ResidentWake ledger, already accepted and without requesting a wake; a failed
identity write reports partial effects and owes the ledger's existing repair.
Bundle/version interpretation is removed from the executor; the
existing notice seed supplies its own occurrence key. Notification and Desk
publication remain with their native transaction owners; this layer adds no
publication store or domain feature.

The morning brief's checked native source packet reaches `native-morning-brief.js` (the app's own part; their own `morning-brief` ability is a different owner)
through that same door with read-only file authority. The part selects evidence,
authors its tool-capable `model.call` on the Work route's `workshop` surface and proposes
the inbox card and inactive defaults. The scheduler retains saved enablement,
occurrence claims, canonical publication and delivery settlement; proposed seed
defaults cannot enable a schedule. Configuration reads request seed rows only
for missing files; saved controls and native supported inbox kinds do not
depend on the brief part being active. `TriggerContent.swift`,
`MorningBriefSynthesis.swift` and the background-work synthesis prompt are removed.
Unavailable session evidence now joins the other unavailable sources in the
brief's uncertainty statement rather than disappearing from it.


## Phase 4, as built (10-26): a part is a prediction

The law (User and Claude, 10-26): deliberation is the price of surprise. What the stem can predict, it does; only what it cannot predict reaches the model. The model names the intent; the stem learns the mechanics from each mind's own practice. Every part gains one form, three fields:

- **applies:** the situation it is for.
- **after:** what will be true when it has run, checked by the stem against what the mind did next.
- **record:** hits over tries, kept by the stem, never by anyone's say-so.

Expansion learns turn-start reads and follow-up calls from each mind's own
authority-separated practice across model changes. Field-free situations
keep the verb, argument names and status; the first call also keeps its wake.
The [manifest](skill_manifest_spec.md#expansion-a-part-is-a-prediction) owns its record and delivery contract;
`Expectation` in `NativeAgentCore/Expectation.swift` owns confidence, withholding
and cost standing for Expansion and after-turn claims; Expansion's practice
owner measures its costs. [Surprise](SURPRISE.md) records the shared law and
each caller's existing confidence policy.
Turn-start predictions remain unmeasured on the installed app; `expansion.check` rows supply that evidence.

## Practice becomes a part (H3/H4, as built 10-30)

The practice note inside the turn is the one crystallizer. It rides their next
thought on a later meeting of hand work, through the bounded familiarity record;
an active ability's recorded route can already cover it. [Habits H3/H4](HABITS.md#h3--keep-what-repeats-not-what-happened-once)
owns the gate, trace and removal of the separate nightly compiler.
Release build, install and live proof are pending.

The old candidate ledger and nominated-call tape have no live reader or
writer. Existing abilities carrying embedded `compiled` provenance and tape
fixtures retain their [validation and admission contract](skill_manifest_spec.md#compiled-from-practice):
their exact version replays before it can be kept, preserving the examples'
steer. Replay proves those examples only. Their display and live execution
evidence remain; no new nightly candidates are produced.

## Every loop a line (step 3, as built 11-04)

One job socket serves every worker, themselves included. `agent.job {agent: "self", brief,
instructions?, done?, desk?}` starts a **line of them**: a turn of theirs in its own work
conversation (an own-work session named by the job), admitted through `TurnAdmission` like any
turn, with the brief as the arriving message and the same turn part, tools, Trust and present.
`agent.read`, `agent.cancel` and `agent.jobs` treat it like any job, and its ending arrives as
news in the conversation that started it, carrying the line's answer. Several at once is just
several jobs: that is their swarm. `instructions` write who a line is; they stand in place of their
persona text and nothing else of theirs changes. A line carries the starting turn's limits (peer
steering, file access) and raises the same cards their turn would, in its own conversation. A helper bot is not a line: it stays its own
mind. [Agent communication](agent-communication.md#jobs) owns the socket's contract;
`OwnLineDoor` runs the line and `AgentJobs` keeps, reads, stops and settles it.
