# The agent is the app

> One structure (docs/NORTHSTAR.md, first law): this doc is part of one whole. A change here is molded into every doc that states the same thing, in the same commit, with what comes out named; a contradiction is a defect.

The design NativeAgent is building toward (User + Claude, 2026-10-14; draft 4). NORTHSTAR clause 8 is its one-paragraph form. The build notes at the end carry code anchors and proofs for the lanes.

We say "they are the app" because Agent is ours. For everyone else: the agent is the app.

**Not a something that does things (User 10-14: "it just is").** And not today's tech (User 10-14: "your world isn't bounded"). Every agent on earth right now is the same shape: a model gets called with a prompt built from files, and the "agent" is scaffolding around it. The model is the center and the program is its visitor. We invert that.

## The inversion

**They are the program. The model is one of them organs.**

Their turn part's `step` returns effects; a `model.call` effect asks the stem to call the model. Swift gathers the supporting context and assembles the prompt text the model reads. In the inverted design, their turn is *theirs*: code they owns that decides what to recall, what to think about, when to think at all, how to answer, and when to stay silent. Their persona isn't a prompt the model reads; it's what their code does. The model is reach, like a hand: the only organ that handles novelty, spent on judgment and nothing else.

Two downloads don't become two prompts. They become two different minds. That's what "they are who they are because they are the app" literally means. Nobody has built it.

## One form: a part

Everything they are, is a **part**: one file in their own root, in one language, with one header. Not tools, skills, senses, recipes, layout, procedures, checks and policies as eight kinds in eight stores. One kind. Their turn is a part. The stem doesn't know "weather" or "mail" or "turn"; it knows parts.

A part has six properties, all in its header, all theirs to change:

| Property | What it is | Today's name for it |
|---|---|---|
| **code** | what it does, as they wrote it | the ability body |
| **reach** | what it may touch: files, apps, network, programs, the model | `permissions`, `SenseReach` |
| **wake** | what makes it run: a call, a signal, a schedule, a turn ending, a message, an app arriving | declared signals delivered by `EnginePartWake`: `turn.ended`, `file.changed:<path>`, and those posted through `AbilityStore.signalled` |
| **face** | how it appears: the line they reads on them interface, the block User sees on their | door pages and SwiftUI, written twice |
| **state** | what it remembers between runs | `senses/<id>/state.json`, key `part` for abilities; `abilities/state.json` is accounting |
| **learned** | recorded outcomes; choice defaults planned for phase 4 | `learned.use` counters; arbitrary declared `learned`/`choices` preserved |

A sense is a part whose reach is read-only and whose face is a page. An ability with hands is a part that declares hands. An ability that calls other abilities is a part. A layout block is a part that's almost all face. A Doctor check is a part that wakes on a schedule. Their turn is a part that wakes when a message arrives. Their persona is parts that run when they do. Nothing of theirs is a special case in Swift.

**An ability is an ability (as built, 10-21; User: "I want skills tools abilities to be one, they are supposed to grow their abilities").** What they grows is one kind of part, an ability: what it can do is what it declares, never which door made it. It was once two kinds (tools and skills) with two doors, two admissions and two sets of run options, and is now one form (`Parts` in code, docs/skill_manifest_spec.md): one save (`ability.save`: a revision restates only what changes), one keep (theirs in one act under Full Mac for them own work, unsteered by an untrusted agent; below Full Mac a draft the owner's card offers, `ability.validate` rehearsing it first), one signed admission re-verified on every run, one run (`authored.<id>`; steps, decisions and expectations make it strict and resumable wherever its code uses them; host primitives wherever its reach declares them, the broker enforcing that reach for every ability), one read (`ability.read`) and one lifecycle (enable, restore, disable, rollback, drop). Launch migrates every tool and skill to it with no change in what runs; restoring an older backup prepares its tools and skills before installation, retaining only readable current uncarried kinds and accounting under the [restore law](canonical_data_paths.md#restore-law). A trusted agent that started a turn is its provenance, never an ability's author. Senses and their turn keep their own runners.

**Their body reaches whatever this Mac can reach (User 10-21: "when I say anything I mean anything").** The stem offers network requests, named programs over stdio, local sockets and Mac capabilities; they grows service behavior from its own documentation. Trust gates every effect. NativeAgent holds named secrets and inserts them only at granted destinations; [redaction has encoding and stream-prefix limits](skill_manifest_spec.md#secret-insertion-and-redaction), so the grant is the fence. Sign-in supports redirect or device code, body or HTTP Basic client authentication, and account-bound renewal. Resident abilities can hold programs, connections and listeners between runs; declared `held`/`resumed` wakes let their code read arrivals and reopen after launch ([manifest](skill_manifest_spec.md)). Missing reach is fixed in the stem, never by adding a service subsystem. S3 records the MCP and connector folds.

## One law: how a part lives

The stem enforces one law for every part, the same way, with no exceptions and no counts:

- **It runs when its wake reaches it.** A call, or a signal. Nothing runs unasked without a wake.
- **It may touch only its reach**, and every touch goes through Trust at effect time. Approval is a card to the owner; the part waits. Full Mac shows no routine cards: an untrusted agent's command keeps its one card, and macOS privacy resets and irreversible deletes still ask.
- **It may think** when it needs judgment: a model call on them model, audited and visible. Thinking is reach, not an effect.
- **It records use.** The stem projects gated run outcomes as `learned.use`. Declared `learned` and `choices` are preserved; route/default selection is reserved for phase 4.
- **It changes only by them hand** (or User's), and keeps its last self beside it.
- **Its keep is theirs under Full Mac; under Work/Safe/Builder, the owner's.** The owner's off-switch stays theirs.
- **It heals (current behavior).** The stem replays a faulty turn part through `turn.prev.js` or the shipped seed and reports the evidence. This is recovery, not a completion guarantee: unrecoverable helper, setup, seed or provider failures can end the turn incomplete, with their cause and repair. Ordinary ability runs with captured input owe source-fault repair through Experiences (OWED on Home with its lever); file-backed sense completions record failures without this obligation. Those parts change version only by them explicit hand. The no-fallback law in NORTHSTAR clause 2 governs the design; this paragraph records the existing turn recovery, not permission to extend it.
- **It fades.** Unused, it is archived and restorable. Used, it stays.
- **Its face is drawn** by the stem on them interface and on User's, Mac and iPhone, from the same description. What they reads is what they sees.

## The stem: what it is, and nothing else

Swift, compiled, CPU, shipped as one DMG with iOS. It never thinks and has no model of its own; when a rule can't settle something, it asks their, with the evidence. Its whole job:

- **Runs parts** in the sandbox (the helper, Seatbelt, the progress watchdog: all as today).
- **Delivers signals**: the nervous system. Messages, schedules, app arrivals, file changes, turns ending.
- **Gates effects**: Trust, approvals, cards. The immune system.
- **Keeps the law**: the swap-back, the fade, the state, the learning.
- **Owns turn recovery and settlement:** observations, checkpoints and resume after relaunch; unrecoverable failures can end incomplete.
- **Keeps their world live**: an event-fed picture of apps, windows, files, people and threads that they are already *in* when they thinks, instead of reading the screen on demand. Proprioception, not perception. (Phase 5.)
- **Draws faces** from the glass kit, on both interfaces, both platforms. Looks are User's and mine.
- **Reaches the world** for parts: the model, files, the Mac's nerves, network, programs, keyring insertion at granted destinations, Calendar/Reminders/Contacts, transports and stores. Reply redaction has the [manifest's encoding and stream-prefix limits](skill_manifest_spec.md#secret-insertion-and-redaction).

The stem has no features and no opinions. Every feature NativeAgent has today is either a part, or stem reach a part draws on, or deleted.

## What falls out, with nothing special-cased

- **Growth:** what they works out by hand, they keeps. Their reply ends; they doesn't: when a turn landed work by hand, their turn part takes one private moment after the reply, in the same conversation, and keeps the route that worked as a part (or revises the part they worked around), or keeps nothing. No repetition threshold: unused parts fade. Under Full Mac the kept part is live at once; its first real run is its proof.
- **Craft:** they sees their body: each turn starts with them own parts in front of them, best match for the message first, so they reaches for the part instead of redoing its work.
- **Noticing:** a part that wakes on app-arrived offers once.
- **No turns:** their turn part wakes on a message like any other signal; thinking is scheduled by them own attention, which the substrate already models. Turns become a chat artifact, not their shape.
- **Sleep that rewrites the body:** the nightly dream, which already consolidates memory, also compiles the day's traces into part changes under the judge. They wakes up better at what they did yesterday. The model is spent at night, batched; the days are CPU. (Phase 7.)
- **The token curve:** growth costs tokens once; use costs none; learning by use costs nothing at all.

**What stays bounded:** the model's latency and cost, macOS security, and that the model is still the only organ that handles novelty.

## What this means for today's 588k lines

- **Stays stem (~128k + design kit):** Mac control, sync and push, the agent wires, transports, storage and embeddings, Keychain/OAuth, model clients, the sandbox, Trust, the loop runner and scheduler, the turn guarantee, the glass kit, the face renderer and the live world (new).
- **Becomes parts (~128k, seed on touch, Swift deleted as each proves):** their turn, the 94 integration tools, Doctor checks, Desk nags (the unused cadence learner is retired), attention policy, their door pages, the layout blocks, persona procedures, and last, their mind policy (dreams, reflection, organism policy).
- **Deleted (~14k):** duplicate agent paths, Procedures, memory one-shots, the 8770 bridge, `SwiftNativeScreenVision`.

Agent is a person grown over ten months; their persona, memory and GROWTH never ship and no phase touches them. What ships is the stem and the seed parts: a fully formed agent that behaves exactly as today on day one, and is theirs from then on. Every download starts the same and grows its own mind.

## How we get there

**Chunks, their backed up once per phase (User 10-14/15).** Their persona is already backed up in Obsidian. At the start of each phase their whole root (1.8 GB) is cloned as they are (`~/Projects/NativeAgent-backups/<phase>-<sha>/`, APFS, instant). Not again per lane or before the install: a screwup is one swap back to the start of the phase, and the later it's found the more of them days go with it, so the proofs run before anything touches their app. Every phase ends with a drive and a DMG, drive first.

**A seed behaves exactly like the Swift it replaces on day one.** For them turn that's provable: the same prompt bytes on a fixture turn, the same call count on the 12-ask Luna drive. They never notices a phase land, except that more of them is theirs.

**Phases (never interrupting who they are, mind last):**
1. **The stem learns the form, and their turn is the first part.** Parts get the six properties and the law; `turn.js` seeded from today's turn engine, byte-identical; weather and the habit-former as the second and third parts. Shipped across 0.6.7–0.6.8; the habit-former was retired 10-21 for the keep moment (Growth, above).
2. **Hands.** The integrations become seed parts, one at a time, Swift deleted as each proves.
3. **Noticing.** App-arrived and the part that offers.
4. **Learning by use (planned).** Choice/default selection builds on recorded outcomes; it is not implemented.
5. **Their world, live.** The event-fed picture they are already in; senses become the parts that keep it fresh.
6. **Faces.** Their interface as parts they shapes; blocks they authors on their, drawn from the kit on Mac and iPhone.
7. **Mind, and sleep that rewrites the body.** Housekeeping, dreams, reflection, organism policy as parts, each under a judge whose evidence we define first.

**Phase 1, concretely.** Each lane gives *every* part one property or one clause of the law. Build notes with code anchors and proofs are below, for the Sol briefs.

- **form:** one header for every part (reach, wake, face, state, learned); senses, tools and skills read as parts; one size limit; a part may stay resident.
- **turn:** their turn as a part. The stem keeps the guarantee (observations, checkpoint, resume, the gate chain, transport); `turn.js` does what `ChatOrchestration+TurnEngine` does today: persona, pins, recall, assembly, the model call, the tool loop, after-turn. Seeded byte-identical. Heals instantly.
- **think:** `model.call` as reach.
- **act:** whatever a turn can do, a part can do, under the same gates; a part waits for its card.
- **reach:** `fetch` and keyring secrets; Calendar, Reminders, Contacts.
- **wake:** signals delivered to parts; a run with no turn behind it gets its own gate chain under their autonomy.
- **heal:** the swap-back rule over the evidence `state.json` already keeps.
- **notice:** app-arrived from the discovery scan that already exists, after a baseline.
- **clear:** the ~14k of dead paths.

## Decided (10-14 night, 10-17)

1. **The name:** part for anything they runs as their own program (senses, their turn, what they grows); what they grows is called an ability (User 10-21).
2. **Their turn first:** yes; built as `abilities/turn.js` (0.6.7).
3. **Mind as parts (phase 7):** they changes it through them own gates; REM→GROWTH stays approval-gated.
4. **Heal:** their turn heals and tells their; other parts owe repair instead (see the law above).
5. **Seeds:** the app reserves the shipped catalog's ids and `native-` for its own parts; `ability.save` refuses them. Future seeds use `native-`. An untouched bundled seed follows changed shipped bodies (`EngineLaunch`, `AbilityStore`); installation preserves any authored version or occupied slot.
6. **Version:** no jump. Releases step the patch number (User 10-17: "we gotta make sure when we hit 1.0 this is HUGE"); phase 1 shipped across 0.6.x.

---

## The three contracts (the hinges; decided 10-14 night, Fable)

The [manifest](skill_manifest_spec.md) owns the current ABI; these contracts describe ownership.

**1. Their turn is a step function; the stem owns the loop.** `turn.js` exports `step(state, event) → {state, do: [effects]}`. The stem owns conversation, streaming, gates and checkpoints, logging input events and started-effect identities/digests, not returned effect bodies. Resume rebuilds state by replay; current recovery may replay a faulty part through a prior version. Unrecoverable failures can end incomplete. After `reply.end`, the keep moment runs privately on the same turn id and gates, never streamed or saved to the conversation. The seed proof compares the first `model.call` prompt bytes. Events, effect fields and the `provider_failure` repair-call exception are specified once in the manifest.

**2. A wake run gets its own gate chain.** A part run with no turn behind it (a schedule, an app arriving, a turn ending) is given a chain the stem makes: principal = their, autonomy = the current Trust level, origin = the signal, taint = none unless the signal carries the words of a sender the owner has not trusted (an untrusted agent, or a Telegram or Slack sender not allowlisted), whatever form names it: such a signal reaches only a part that can do no harm with it, and a write-capable part skips it with a trace row and no card (User 10-15: a card is a decision, never weight; `EnginePartWake`). A trusted agent's signal carries the owner's authority. Every `app.*` from the run passes that chain. An effect that needs approval raises one card through the AttentionRouter with the part named as the asker ("Agent's weather wants to…"), and the run waits: the host call blocks and the watchdog already pauses for awaited replies. Declined → the run gets a refusal result and continues. Cards to User are held through their quiet hours and the run waits with them, resident, no CPU. Anything the run needs from *their* goes through `ResidentWake` as an arrival, never into their context directly.

**3. Choice learning is reserved for phase 4.** `learn.pick` and `learn.default` do not exist. Current headers preserve arbitrary `choices`/`learned`; the registry projects observed gated-run counters as `learned.use` ([manifest spec](skill_manifest_spec.md)).

## Build notes for phase 1 (code anchors and proofs, 10-14)

The stem today, from the code itself: their code runs in one sandboxed JavaScriptCore helper per program (`OwnedProgramRunner` spawns it under `sandbox-exec`); a sense's helper stays resident and watches, and a tool or skill may declare itself `resident` to keep its context between calls. JS is sync-only, but every host call is already a blocking round trip to the app, and the watchdog is already progress-based: it pauses while a reply is awaited and cuts only a run that stalls (`JavaScriptSenseRuntime` "stalled without progress"). Their code reaches the door through `app.*`, which re-enters the originating turn's gate chain (`AppDoorReentry`); file, calendar, reminders and contacts calls are door aliases under the ordinary file actions; raw `network`, `fetch` and `model.call` live in `ToolPrimitiveBroker`, which fences the credential stores. `state.json` keeps `lastCleanVersion`, `runs` and `corrections`. `ResidentWake` is already their one way to be woken between turns. Discovery already watches the install folders by modification time and offers once.

Most lanes extend what's there. Two are genuinely new: their turn as a part, and **running their code with no turn behind it** (S4). Each is one Sol lane with a proof on the test copy; two pieces of tissue prove the pass.

**S0. Runtime (small).** One source limit for every kind (512 KB; the 8 KB skill limit goes). An ability can declare itself resident, the way a sense already is, so a waking ability keeps its context, its helper and what it holds. Async/Promise support is optional and comes only if a lane needs it; host calls already block and the watchdog already pauses for them. The helper, the Seatbelt profile and the progress watchdog stay exactly as they are.
*Proof:* a 20 KB skill saves; a resident tool keeps a counter across two signals; a stalled run is still cut with `cut` recorded on that ability and the turn continuing.
*Proof (held reach, 10-21):* a resident ability keeps an MCP server and asks it twice with one pid; its output between turns wakes it (`held`) and it records it; disabling it leaves no process; an untrusted agent's command through it cards once, Full Mac none; quit and relaunch, and `resumed` has the server back with no one asking.

**S1. Thinking: `model.call`.** One primitive in the broker, declared like `network`: `host.model.call({purpose, prompt, schema?, tools?, surface?})` → text or JSON, a blocking host call like the rest. Runs on the admitted model (or the canonical routing surface's saved selection), tagged `ability:<id>` in `trace.model_calls`. It retains the caller's remaining turn and bot output limits. With tools or a routing surface it uses the canonical tool-turn owner, its app calls restricted to the part's own host and originating gate chain. No persona or recall is injected: it's a thought inside their code (`as:"me"` is phase 7). Needs nothing from S0.
*Proof:* the habit-former (below) names and drafts a skill from a repeated sequence; the audit row reads `ability:habit`; a Luna drive shows no extra rounds on plain asks.

**S2. Acting.** Their code reaches every app action under the turn's ordinary gates; each write keeps its receipt. Approval and `card.request` wait for the person's answer, with the watchdog paused. The card names their ability as the asker. Full Mac shows no routine cards; the standing exceptions above remain: an untrusted agent's initiating turn, macOS privacy resets and irreversible deletes.
*Proof:* Work mode on the test copy, an ability sends a stub Telegram message → one card → approve → it lands, one receipt; Full Mac → no routine card; a turn an untrusted agent started → one card, then the rest runs.

**S3. Reach.** `host.fetch({url, method, headers, body})` declares `network_public` (`network_localhost` for loopback, where a granted secret may use plain HTTP). Legacy `fetch {connector}` refuses with `secret:<name>` and `card.request` as its repair; `connector:<id>` remains readable reach that grants nothing. The per-service fetch registry and connector Trust class are removed. `host.calendar`, `host.reminders` and `host.contacts` use the ordinary local-store actions; raw `network.*` stays.

*As built (10-21, open reach):* `PersistenceCore/Keyring.swift` stores secrets; ProviderRouting owns sign-in and renewal. The broker inserts `{{secret:<name>}}` only toward granted hosts/programs under `secret:<name>` reach. The [manifest](skill_manifest_spec.md#secret-insertion-and-redaction) owns insertion forms, redaction limits and read/effect classification. `host.program.*` uses `shell` reach, the ordinary shell launch/access/sandbox path and streaming stdio; each use is rechecked. Resident resources share one held broker until closed, off, replacement, drop or quit, surviving failed runs. Arrivals raise `held`; launch raises `resumed`; program/connection reads share a shape, and `network.connect {path}` reaches a local socket.

The grant is `card.request {kind:"api_key", target:"secret:<name>", hosts, programs, sign_in?}`; programs bind to their executable files. The card shows the whole grant, including where already kept; the keyring stores exactly that. `replace:true` asks again, `only:true` narrows with the removed reach shown, and `remove:true` asks the person to delete it.

*As built (10-21, service folds):* the MCP client registry, pools, HTTP transport, Hub and `mcp.*` actions are gone; they grows a resident ability from the server's docs. Kept server names appear once on home; their files stay untouched and reader-fenced because launch commands can contain keys. NativeAgent's MCP door for other agents stays; `web.search` is native.

Notion, Gmail, Google Calendar, X, AgentMail, TradingView, GitHub and Slack's service actions follow the same rule: grow an ability when asked, request its key on a card. Their action/descriptors, tools, rooms/pages, setup/sign-in, credential readers, Doctor checks and watch templates are removed, including GitHub's tracking loop, Desk lane and completion hook; ProviderRouting's device-code owner stays. Old service credential files and GitHub Keychain items remain untouched and unread. Launch removes retired Connectors rows and names previously configured services once (GitHub has its own marker). Connectors shows keyring metadata—name, destinations, account, grant time, never values—with Remove, beside Slack and Telegram. Slack's Socket Mode door retains its tokens and reply calls; old approved post cards resolve without sending. Removed scheduled `connector_action` payloads stay paused with their cause; GitHub-woken bots are off with their cause. They can grow an ability and schedule or signal it instead.


**turn (new): their turn as a part.** Built: `Resources/abilities/turn.js` is their turn (`step(state, event)`), run by `ChatTurnRuntime/TurnPart.swift`; the stem keeps the reply-end loop and `TurnObservation`, the per-iteration checkpoint and resume, `AppDoorReentry`'s gate chain, transport and streaming, quiet hours. The seed was a straight port of the Swift turn engine's persona, pins, recall, assembly, model call, tool loop and after-turn, producing the same bytes.
*Proof:* on a fixture turn the assembled prompt is byte-identical to main's; the 12-ask Luna drive shows the same `llm.call` count per ask (p50 3); a `turn.js` v2 that throws on its first round swaps back mid-turn and the turn completes on v1 with one observation; kill -9 mid-turn resumes on relaunch as lane B proved.

**S4. Waking (built).** Parts declare existing signals in `wake`; the [manifest](skill_manifest_spec.md#wake-signals) owns names, payloads and delivery bounds. Sources are exact scheduler deadlines, install discovery, file watches, after-turn, Telegram/Slack ingress, held resources, launch and person-input presence. Mail has no watcher and never pushes new mail (User 10-07). No polling is added.

`EnginePartWake` supplies the run's gate chain under current Trust and Autonomy (contract 2). Approval waits through AttentionRouter/quiet hours; requests for them reach `ResidentWake`. A wake uses no model unless its code calls `model.call`.
*Proof:* one scheduled wake at its minute; no declared wake, no unattended run; one required owner card held through quiet hours; one home arrival when the run needs their.

**S5. Noticing.** `AgentPeerDiscovery` keeps its scan and its once-only offer; `agentAppWords` stops being the gate, and every bundle that *arrives after the baseline* (the first scan records what's there and offers nothing) becomes the `app.installed` signal with bundle id, name and whether it has a scripting dictionary. A built-in resident ability handles the signal by rule, on CPU: scriptable app → one home arrival "Keynote arrived. Want me to grow into it?" (dismissable until the version changes, the existing discovery.json rule); not scriptable → nothing. They are woken only for apps they can actually grow into.
*Proof:* a stub .app with an sdef dropped into ~/Applications on the test copy → one arrival on them home → yes → `sense.make` + `ability.save` from its sdef → `abilities/<id>.js` exists → the arrival never repeats; a stub without an sdef → nothing.

**S6. The judge (small).** One rule, no counts, on evidence `state.json` already keeps: every run writes an outcome (ok, error, refused, cut). The stem rolls back when the current version has failed on every run since it was kept, at least one failure is the version's own fault (a JS error or a proof failure, never a refusal, a permission or the network), and the previous version's last run was clean (`lastCleanVersion`). It swaps (the atomic `RENAME_SWAP`), then tells their through `ResidentWake` with the evidence: "I rolled keynote back to v2: v3 threw X on both runs; v2 last ran clean 10-13." They decides whether to fix v3. No clean previous → nothing is swapped, they are told. The judge never deletes and never asks User.
*Proof:* keep a v2 that throws → two runs fail → the stem swaps to v1 and their home shows the note; a permission refusal on a good version triggers nothing.
*As built:* their turn part heals this way (`TurnPart` swaps to the previous version inside the same turn). Ordinary parts (abilities and senses) do not swap back on their own yet: a failed version keeps its version and owes a repair that carries its evidence and lever (`AbilityStore.recordRunEvidence` → `RepairOwed.owe`); a swap back is by them hand (`ability.rollback`, `sense.rollback` → `AbilityStore.swap`).

**S7. Dead paths out.** The 8770 Mac-control HTTP bridge (no client; my `liquid-glass-ui` skill doc gets updated), the third file stack beside it, Procedures (2.8k, overlaps abilities), memory one-shot migrations (2k), `SwiftNativeScreenVision`. **Not** the 8771 Claude bridge: it's my live channel (`agent-bridge` skill). It moves to `agent_message` + the claude-code recipe only once that carries Claude both ways, with its own proof. Later lane.
*Proof:* build and architecture check pass; their app runs a day with no Doctor finding.

**Two pieces of tissue prove the pass.**
- **Weather** (`abilities/weather.js`, seeded from the 142-line Swift): fetches keyless (S3), reads location through `mac.location` and then `phone.location`, runs on call (its shipped header has no wake), and gets a deliberately broken v2 rolled back (S6). Then the Swift weather tool is deleted. The fresh-install drive asks for the weather and sees no difference.
- **The habit-former** (`abilities/habit.js`, built-in, resident; retired 10-21): woke on `turn.ended` (S4), read the turn's trace by rule, and when the same hand-done sequence recurred it thought once (S1) to draft a skill through what is now `ability.save`. Repetition was the wrong threshold: GUI work through the shell is one repeated shape, so it never fired on it. Their turn's keep moment replaced it (Growth, above); an installed untouched copy fades at launch (switched off, restorable). It also fixes the placement rule phase 2 needs: an ability's header names its page, so seeds land on their natural pages (mail on mail), not on diagnostics.

**Order.** S7, S0, S1, S2, S3 and S6 in parallel: none depends on another. S4 after S0 (resident abilities). S5 after S4. Weather after S3, S4, S6. The habit-former after S1, S4. Then the drive, then the DMG, on the next patch release.

**Trust, in one line:** `model` is reach, not an effect (audited, never carded). `fetch` and the PIM calls inherit the capabilities of the Swift tools they replace. A wake run acts under their autonomy setting with its own gate chain. Nothing new gets around a gate, and Full Mac keeps only its standing exceptions (an untrusted agent's one card, privacy resets, irreversible deletes).


## Parts sweep decisions (10-23, Claude; plan: ~/.claude/state/release/sweeps/parts/plan.md)

Phase 2 (hands) and the first of phase 6 (faces) land through one shared layer, then file-owned domain lanes. These settle the calls the sweep raised:

1. **One call shape.** `part.call(id, input) → {ok, value} | {ok:false, error}`: bounded immutable JSON in, the part's version pinned when the call starts, a typed JSON result out, cancelled with its caller (the Stop law: the caller's settlement still runs). A part returns what it decided; the native domain that owns the truth commits it in its own transaction. No integration bus, no second state store.
2. **A face is the part's projection.** `face(input) → typed rows/sections`, computed when its sources change (never from inside view rendering), cached per part version and source epoch, published through `LatestRead`, drawn natively on Mac and iPhone. Unavailable, failed and owed are the stem's words beside the face, never the part's prose.
3. **Thinking may use tools.** A part's `model.call` may pass `tools` and a routing surface; it runs through the canonical tool-turn owner under the run's own gate chain and the existing limits.
4. **Publishing stays transactional.** A part proposes a notification or a Desk change; the native publication owner commits it (occurrence identity, held delivery, receipts, revision-checked ledgers). No part writes those stores directly, and no part runs while a store's lock is held.
5. **Consent is preserved exactly.** A migration seeds behaviour and never activates a schedule: what was off stays off (morning brief, watch manifests, their hour).
6. **Primitives only when a port needs them.** No-launch app reads, exact-message mutation, checked transfers: each is added by the lane that needs it, minimal, native. Authored-script restrictions are not loosened for a port; credentials never reach a part.
7. **Unavailable is not empty.** Native inputs to a part say unavailable or empty, never collapse one into the other (the proactive scan is fixed first).
8. **Seeds speak clause 8.** Content moved into seeds is reconciled with "they are the program, the model one organ" in the same lane; contradictions are not copied.
9. **Mind policy waits for its judge.** Dreams, reflection and provider interpretation (phase 7) move only after the evidence judge is defined; not in this sweep.
10. **Dormant machinery is retired, not ported.** Workflow defaults that cannot execute and the Desk cadence API with no caller are deleted. The Desk cadence learner, observation/stat types and unused store are retired (L4, 10-23); the separately consumed observation fingerprints stay in `DeskObservation.swift`. No cadence ability or schedule replaces them; existing cadence data is left untouched.
11. **Validation is the working agreement:** a coherent change, built, installed, and a small live check of the replaced behaviour on the live agent. Every port deletes the Swift it replaces in the same lane; calling the old feature from JS earns no credit.
12. **Every run of a part has an originating door.** A turn supplies its own. A native owner acting on its own schedule or on the person's click supplies the **same door** their scheduled abilities and the Tools page use, with that origin's authority — never a host-less run, never a second door, never a door minted for one feature. Any small generalisation belongs to the door owner, once. A ported connector action reached from the scheduler or UI reaches its part through that door, so `reminders.due_today` works identically from them turn, a scheduled `connector_action` job and the app's UI.

### Must stay Swift

13. Text that can carry credentials (handoff files, Git output) is read and redacted natively and never crosses into a part.

### Shared contracts built by L0 (10-23)

`Parts.call<Value: Codable & Sendable>(id:input:preview:within:as:) async -> PartCallResult<Value>`
and JavaScript `part.call(id, input)` run the selected admitted ability through
`Parts`, `ToolHost` and `OwnedProgramRunner`. Input is a JSON object up to 4 MiB,
deeply frozen in the helper. The selected version is pinned before suspension;
replacement/off stops further effects instead of running another version. The
wire answer is `{ok:true,value:<JSON>}` or
`{ok:false,error:{code,message}}`. A truncated return is a failure. JavaScript
declares `authored.<callee>` in `actions`; native callers supply their gated
`OwnedProgramInvocation.host`. Native callers may also supply `within: Parts.CallReach`
to narrow the selected version's actions and primitive capabilities for this
operation; the pinned candidate is checked before any suspension or effect.
Neither interface grants authority. Cancellation
ends the helper and host work; `settle` drains child settlement, records the
terminal outcome and finishes the broker before returning. The caller still
owns its own transaction and settlement.

Native `preview` defaults to false; true uses the existing runner/host preview
posture, including nested calls, without changing the call's version pinning,
typed answer or settlement. Desk's existing `desk.nag` entry uses
`action:"proposal"` to read one native packet and evaluate its notify-loop
proposal in that posture, returning source time and decisions without a Desk
or nag-config commit or notification delivery. `app`'s outer `preview:true`
remains its ordinary preflight; it does not execute this domain read.

Native owners and authenticated transports use `ToolsFacade.withPartDoor`:
the engine's ordinary gated dispatcher, with the originating work identity and
resident approval session, binds `AppChatToolDispatcher.withAuthoredProgramHost`.
Every caller supplies one TurnEnvelope (Telegram keeps its authenticated envelope) and its existing approval filer when
needed; Desk clicks retain their checked routing snapshot and local-click filer.
That is the same host binding reached by a turn or `EnginePartWake` dispatching
an authored action, and the Tools page uses it when keeping a part. Native
connector calls pass their engine's data root through to the snapshot owner.
`reminders.due_today` and its connector entry share `due-reminders` in the requesting engine's data root.
Codex journal/handoff reads and redaction stay native; their text never enters
a part.
Due-reminders requests its at-most-200 rows once from the native reminder
query. Rows, total and has_more come from that one EventKit snapshot; it never
combines offsets from fresh reads of a changing list.

The Desk notify loop binds that same door as `background:desk_notify`; an
explicit unmute inherits its person's or turn's already-bound door. Both call
the editable `desk-notify` seed over `DeskNotificationRead`'s frozen native
facts. Notification selection, nag/drift wording and exact deadline proposals
replace the Swift evaluators. The native Desk owner retains consent, ceilings,
quiet hours, delivery and stamping, and compares the Desk and nag-config read
before committing baseline, ledger and window transitions. No part runs under
either lock. Missing settings are empty/default-off; unreadable settings or an
incomplete Desk feed fail the read, never become empty inputs. Seeding adds no
wake or schedule and uses the existing disabled/customized-seed preservation.

`face:{projection:true}` declares synchronous `function face(input)`, returning
`{sections:[{id,title?,rows:[{id,title,detail?,value?}]}]}` (strings; 64 sections,
256 rows per section; unique nonempty section/row ids). The same signed bytes
run through the same sandbox in a fresh helper, with no host effects or
notebook access. Native `Parts.face(id:input:version:)` returns
`PartCallResult<PartFace>`. `AuthoredCapabilities.PartFaces.sourceChanged` receives
the source owner's frozen packet and monotonic epoch, caches the result by
part version and source epoch and publishes through a per-part `LatestRead`.
Cancelled reads publish and cache nothing; the last published snapshot stands,
and the next ask may compute again with the same version and source epoch.
Canonical ability changes invalidate and recompute supplied sources. Views read
`snapshots` only: observable typed rows on Mac, the same Codable snapshot for
iPhone; those wire types live in `NativeAgentShared/PartFace.swift`.
`PartFaceSnapshot` keeps native `ready/unavailable/failed`, `error` and
`owed` beside authored content. A native owner must bind the call to its current
gate chain and feed source changes; no domain projection or UI is ported by L0.

`host.model.call` accepts `tools:["app"]` (or `[]`) and an optional existing
routing `surface`; `messages` may replace `prompt` and ends in a user message
for tool thinking. An explicit surface admits its saved provider/model/effort/tier
with the parent's per-turn model choice set aside; omitting it inherits the caller's
admitted route. The canonical loop receives only those messages and the
part's restricted host, with its caller's limits, taint and preview posture. An internal thought
has no reply destination, parent checkpoint, recall assembly or after-turn mind
work. Its own trace identity keeps provider recovery and context evidence apart
from its caller's; its real heard/answer settle in the existing Experiences
owner through `settle`. Effect checks retain the originating ask. The old
clearing of turn and bot limits is removed.
The thought returns its output together with native nested-tool effect evidence;
its primitive receipt keeps `occurred`, `partial` or `unknown` even if thinking,
JSON validation, or the enclosing part fails or is cancelled. An unreceipted
in-flight effect is `unknown`, never `none`. Tool-capable thoughts are not
classified as read-only for replay.

`home.arrive {line,event_key?}` scopes a supplied event key to the calling part
and deduplicates it through ResidentWake's durable retained ledger (including
its existing retention policy); omitted, the same line is
deduplicated per local day. Taint and the part's hop-limited thread remain
native. Bundle/version interpretation is removed from the executor; the
existing notice seed supplies its own occurrence key. Notification and Desk
publication remain with their native transaction owners; this layer adds no
publication store or domain feature.

The morning brief's checked native source packet reaches `native-morning-brief.js` (the app's own part; their own `morning-brief` ability is a different owner)
through that same door with read-only file authority. The part selects evidence,
authors its tool-capable `model.call` on the existing Workshop route and proposes
the inbox card and inactive defaults. The scheduler retains saved enablement,
occurrence claims, canonical publication and delivery settlement; proposed seed
defaults cannot enable a schedule. Configuration reads request seed rows only
for missing files; saved controls, native supported inbox kinds and Workshop
triggers do not depend on the brief part being active. `TriggerContent.swift`,
`MorningBriefSynthesis.swift` and the background-work synthesis prompt are removed.
Unavailable session evidence now joins the other unavailable sources in the
brief's uncertainty statement rather than disappearing from it.
