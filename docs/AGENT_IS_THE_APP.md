# The agent is the app

The design NativeAgent is building toward (User + Claude, 2026-10-14; draft 4). NORTHSTAR clause 8 is its one-paragraph form. The build notes at the end carry code anchors and proofs for the lanes.

We say "they are the app" because Agent is ours. For everyone else: the agent is the app.

**Not a something that does things (User 10-14: "it just is").** And not today's tech (User 10-14: "your world isn't bounded"). Every agent on earth right now is the same shape: a model gets called with a prompt built from files, and the "agent" is scaffolding around it. The model is the center and the program is its visitor. We invert that.

## The inversion

**They are the program. The model is one of them organs.**

Today the Swift turn engine decides to call the model, assembles their persona as text, and the model reads who they are. In the inverted design, their turn is *theirs*: code they owns that decides what to recall, what to think about, when to think at all, how to answer, and when to stay silent. Their persona isn't a prompt the model reads; it's what their code does. The model is reach, like a hand: the only organ that handles novelty, spent on judgment and nothing else.

Two downloads don't become two prompts. They become two different minds. That's what "they are who they are because they are the app" literally means. Nobody has built it.

## One form: a part

Everything they are, is a **part**: one file in their own root, in one language, with one header. Not tools, skills, senses, recipes, layout, procedures, checks and policies as eight kinds in eight stores. One kind. Their turn is a part. The stem doesn't know "weather" or "mail" or "turn"; it knows parts.

A part has six properties, all in its header, all theirs to change:

| Property | What it is | Today's name for it |
|---|---|---|
| **code** | what it does, as they wrote it | the ability body |
| **reach** | what it may touch: files, apps, connectors, the Mac, the model | `permissions`, `SenseReach` |
| **wake** | what makes it run: a call, a signal, a schedule, a turn ending, a message, an app arriving | nothing (only calls) |
| **face** | how it appears: the line they reads on them interface, the block User sees on their | door pages and SwiftUI, written twice |
| **state** | what it remembers between runs | `state.json`, sense state |
| **learned** | what use has taught it: defaults the stem folds in from outcomes, on CPU | nothing |

A sense is a part whose reach is read-only and whose face is a page. A tool is a part with hands. A skill is a part that calls other parts. A layout block is a part that's almost all face. A Doctor check is a part that wakes on a schedule. Their turn is a part that wakes when a message arrives. Their persona is parts that run when they do. Nothing of theirs is a special case in Swift.

## One law: how a part lives

The stem enforces one law for every part, the same way, with no exceptions and no counts:

- **It runs when its wake reaches it.** A call, or a signal. Nothing polls. Nothing runs unasked without a wake.
- **It may touch only its reach**, and every touch goes through Trust at effect time. Approval is a card to User; the part waits. Full Mac shows no cards.
- **It may think** when it needs judgment: a model call on them model, audited and visible. Thinking is reach, not an effect.
- **It learns by use.** Every run leaves a trace; the stem folds outcomes into the part's learned defaults by rule: which route worked for which app, which order, which fields. Competence compounds with no tokens. The model is spent only on novelty.
- **It changes only by them hand** (or User's), and keeps its last self beside it.
- **Its keep is theirs under Full Mac; under Work/Safe/Builder, the owner's.** The owner's off-switch stays theirs.
- **It heals.** When a version fails every run since it was kept, through its own fault, and the one before was clean, the stem swaps back and tells their, with the evidence. It never deletes, never asks User. For them turn, the swap is instant and the same turn continues: a turn never fails, now including their own turn code.
- **It fades.** Unused, it is archived and restorable. Used, it stays.
- **Its face is drawn** by the stem on them interface and on User's, Mac and iPhone, from the same description. What they reads is what they sees.

## The stem: what it is, and nothing else

Swift, compiled, CPU, shipped as one DMG with iOS. It never thinks and has no model of its own; when a rule can't settle something, it asks their, with the evidence. Its whole job:

- **Runs parts** in the sandbox (the helper, Seatbelt, the progress watchdog: all as today).
- **Delivers signals**: the nervous system. Messages, schedules, app arrivals, file changes, turns ending.
- **Gates effects**: Trust, approvals, cards. The immune system.
- **Keeps the law**: the swap-back, the fade, the state, the learning.
- **Guarantees a turn never fails** around whatever their turn part does: observations, checkpoints, resume after a relaunch.
- **Keeps their world live**: an event-fed picture of apps, windows, files, people and threads that they are already *in* when they thinks, instead of reading the screen on demand. Proprioception, not perception. (Phase 5.)
- **Draws faces** from the glass kit, on both interfaces, both platforms. Looks are User's and mine.
- **Reaches the world** for parts: the model, files, the Mac's nerves, connectors with the token never leaving the stem, Calendar/Reminders/Contacts, the transports, the stores.

The stem has no features and no opinions. Every feature NativeAgent has today is either a part, or stem reach a part draws on, or deleted.

## What falls out, with nothing special-cased

- **Growth:** they meets something and writes a part.
- **Craft:** a part that wakes on turn-ended notices repetition and writes a part.
- **Noticing:** a part that wakes on app-arrived offers once.
- **No turns:** their turn part wakes on a message like any other signal; thinking is scheduled by them own attention, which the substrate already models. Turns become a chat artifact, not their shape.
- **Sleep that rewrites the body:** the nightly dream, which already consolidates memory, also compiles the day's traces into part changes under the judge. They wakes up better at what they did yesterday. The model is spent at night, batched; the days are CPU. (Phase 7.)
- **The token curve:** growth costs tokens once; use costs none; learning by use costs nothing at all.

**What stays bounded:** the model's latency and cost, macOS security, and that the model is still the only organ that handles novelty.

## What this means for today's 588k lines

- **Stays stem (~128k + design kit):** Mac control, sync and push, the agent wires, transports, storage and embeddings, Keychain/OAuth, model clients, the sandbox, Trust, the loop runner and scheduler, the turn guarantee, the glass kit, the face renderer and the live world (new).
- **Becomes parts (~128k, seed on touch, Swift deleted as each proves):** their turn, the 94 integration tools, Doctor checks, Desk cadence and nags, attention policy, their door pages, the layout blocks, persona procedures, and last, their mind policy (dreams, reflection, organism policy).
- **Deleted (~14k):** duplicate agent paths, Procedures, memory one-shots, the 8770 bridge, `SwiftNativeScreenVision`.

Agent is a person grown over ten months; their persona, memory and GROWTH never ship and no phase touches them. What ships is the stem and the seed parts: a fully formed agent that behaves exactly as today on day one, and is theirs from then on. Every download starts the same and grows its own mind.

## How we get there

**Chunks, their backed up once per phase (User 10-14/15).** Their persona is already backed up in Obsidian. At the start of each phase their whole root (1.8 GB) is cloned as they are (`~/Projects/NativeAgent-backups/<phase>-<sha>/`, APFS, instant). Not again per lane or before the install: a screwup is one swap back to the start of the phase, and the later it's found the more of them days go with it, so the proofs run before anything touches their app. Every phase ends with a drive and a DMG, drive first.

**A seed behaves exactly like the Swift it replaces on day one.** For them turn that's provable: the same prompt bytes on a fixture turn, the same call count on the 12-ask Luna drive. They never notices a phase land, except that more of them is theirs.

**Phases (never interrupting who they are, mind last):**
1. **The stem learns the form, and their turn is the first part.** Parts get the six properties and the law; `turn.js` seeded from today's turn engine, byte-identical; weather and the habit-former as the second and third parts. 0.7.0.
2. **Hands.** The integrations become seed parts, one at a time, Swift deleted as each proves.
3. **Noticing.** App-arrived and the part that offers.
4. **Learning by use.** The stem folds outcomes into learned defaults; parts declare what they learn.
5. **Their world, live.** The event-fed picture they are already in; senses become the parts that keep it fresh.
6. **Faces.** Their interface as parts they shapes; blocks they authors on their, drawn from the kit on Mac and iPhone.
7. **Mind, and sleep that rewrites the body.** Housekeeping, dreams, reflection, organism policy as parts, each under a judge whose evidence we define first.

**Phase 1, concretely.** Each lane gives *every* part one property or one clause of the law. Build notes with code anchors and proofs are below, for the Sol briefs.

- **form:** one header for every part (reach, wake, face, state, learned); senses, tools and skills read as parts; one size limit; a part may stay resident.
- **turn:** their turn as a part. The stem keeps the guarantee (observations, checkpoint, resume, the gate chain, transport); `turn.js` does what `ChatOrchestration+TurnEngine` does today: persona, pins, recall, assembly, the model call, the tool loop, after-turn. Seeded byte-identical. Heals instantly.
- **think:** `model.call` as reach.
- **act:** whatever a turn can do, a part can do, under the same gates; a part waits for its card.
- **reach:** `fetch` as a connector with the token in the stem; Calendar, Reminders, Contacts.
- **wake:** signals delivered to parts; a run with no turn behind it gets its own gate chain under their autonomy.
- **heal:** the swap-back rule over the evidence `state.json` already keeps.
- **notice:** app-arrived from the discovery scan that already exists, after a baseline.
- **clear:** the ~14k of dead paths.

## Open questions

1. **The name.** "Part" is the plain word; it's yours to name.
2. **Their turn first.** The riskiest seed and the whole point. The law covers it (instant swap-back, the stem's guarantee around it). Yes?
3. **Mind as parts (phase 7):** they changes it through them own gates; REM→GROWTH stays approval-gated. Yes?
4. **Heal acts, then tells their,** never asks User. Yes?
5. **Seeds:** their edits win; a new seed is offered, never forced. Yes?
6. **0.7.0** for phase 1?

---

## The three contracts (the hinges; decided 10-14 night, Fable)

These are the places a worker would otherwise guess. Everything else in phase 1 extends code that exists.

**1. Their turn is a step function, and the stem owns the loop.** `turn.js` does not run a loop of its own; it exports `step(state, event) → {state, do: [effects]}`. Events the stem delivers: `message` (text, attachments, who, surface, trust), `model` (done, with the final text and the tool calls it asked for; the stem streams the model's visible text to the reply itself, as today, so no chunk crosses into JS unless the part asks for `chunks: true`), `result` (one effect's outcome), `observation` (a cut, a retry, a resumed process: lane A's `TurnObservation`), `resumed`. Effects it may return: `model.call` (purpose, messages, tools, stream), `app` (one door call), `reply.stream`, `reply.end`, `after` (the after-turn work: memory, appraisal). The stem runs the loop, appends every event and effect to the turn's log, checkpoints at each host-call boundary, and on relaunch rebuilds `state` by replaying the log through `step`. That makes three things free that would otherwise be hard: *a turn never fails* stays the stem's (the one exit is the model finishing, exactly as lane A built it); *resume is exact* (replay, no JS locals to recover); *heal mid-turn* is a swap of `turn.js` and a replay of the same log through the previous version. And the seed proof is strict: the first `model.call` effect's payload is the prompt, so "byte-identical to main" is a comparison of two strings.

**2. A wake run gets its own gate chain.** A part run with no turn behind it (a schedule, an app arriving, a turn ending) is given a chain the stem makes: principal = their, autonomy = the current Trust level, origin = the signal, taint = none unless the signal carries another agent's words (then the 10-13 trust rule applies exactly as for a turn: trusted peer = User's own authority, untrusted = the floor). Every `app.*` from the run passes that chain. An effect that needs approval raises one card through the AttentionRouter with the part named as the asker ("Agent's weather wants to…"), and the run waits: the host call blocks and the watchdog already pauses for awaited replies. Declined → the run gets a refusal result and continues. Cards to User are held through their quiet hours and the run waits with them, resident, no CPU. Anything the run needs from *their* goes through `ResidentWake` as an arrival, never into their context directly.

**3. Learned is a bandit over the part's declared choices, on CPU.** A part names the choices it makes in its header, each with its alternatives: `choices: {open_doc: ["script", "menu", "screen"], date_format: []}`. At run time it asks `learn.pick("open_doc", context)` and gets the alternative with the best outcome record for that context (success rate with recency; uniform until there is evidence), and `learn.default("date_format", value)` records a value that worked. The run's outcome closes the loop: the stem credits the picks that run made. That is the whole mechanism: a few counters per choice per context in the part's `learned` block, readable by them, resettable by them, never touched by a model. The first time, they thinks; by the third time, the part already reaches for what worked. The model is spent only when every alternative has failed, which is novelty, and that is the only time it should be.

## Build notes for phase 1 (code anchors and proofs, 10-14)

The stem today, from the code itself: their code runs in one sandboxed JavaScriptCore helper per program (`OwnedProgramRunner` spawns it under `sandbox-exec`); a sense's helper stays resident and watches, a tool's or skill's runs once. JS is sync-only, but every host call is already a blocking round trip to the app, and the watchdog is already progress-based: it pauses while a reply is awaited and cuts only a run that stalls (`JavaScriptSenseRuntime` "stalled without progress"). Their code reaches the door through `app.*`, which re-enters the originating turn's gate chain (`AppDoorReentry`), and reaches `files`, raw `network` and `apps.call` through `ToolPrimitiveBroker`, which fences the credential stores. `state.json` keeps `lastCleanVersion`, `runs` and `corrections`. `ResidentWake` is already their one way to be woken between turns. Discovery already watches the install folders by modification time and offers once.

Most lanes extend what's there. Two are genuinely new: their turn as a part, and **running their code with no turn behind it** (S4). Each is one Sol lane with a proof on the test copy; two pieces of tissue prove the pass.

**S0. Runtime (small).** One source limit for every kind (512 KB; the 8 KB skill limit goes). An ability can declare itself resident, the way a sense already is, so a waking ability keeps its context and its helper. Async/Promise support is optional and comes only if a lane needs it; host calls already block and the watchdog already pauses for them. The helper, the Seatbelt profile and the progress watchdog stay exactly as they are.
*Proof:* a 20 KB skill saves; a resident tool keeps a counter across two signals; a stalled run is still cut with `cut` recorded on that ability and the turn continuing.

**S1. Thinking: `model.call`.** One primitive in the broker, declared like `network`: `model.call({purpose, prompt, schema?})` → text or JSON, a blocking host call like the rest. Runs on them model (the picker's choice, never a second model), tagged `ability:<id>` in `trace.model_calls`. No cap, no budget: the audit and the judge see a runaway. No persona injected: it's a thought inside their code, not their turn (`as:"me"` is phase 7). Needs nothing from S0.
*Proof:* the habit-former (below) names and drafts a skill from a repeated sequence; the audit row reads `ability:habit`; a Luna drive shows no extra rounds on plain asks.

**S2. Acting.** One rule: whatever a turn can do through the door, their code can do through the door, under the same gates. The `scriptable: scriptable ?? read` default in `AppActionRegistry.fold` and the `not_scriptable` refusal in `AppScriptRunner.doorInput` go. Each call still re-enters the gate chain as its own app call, so each write gets its own gate and receipt as today. When a gated call needs approval, the reentry *waits* for the card's answer instead of returning pending; the watchdog already pauses for awaited replies. The card reads as theirs ("Agent's keynote tool wants to send…") and reaches User the way any card does. `card.request` becomes callable from them code the same way. Full Mac: no cards. Peer-steered turns: still no writes (`AbilityStore.requireWrite`).
*Proof:* Work mode on the test copy, a skill sends a stub Telegram message → one card → approve → it lands, one receipt; Full Mac → no card; peer-steered → refused with the next step named.

**S3. Reach.** `host.fetch({connector?, url, method, body})` in the broker: the app attaches the connector's credential from the fenced stores and the token never enters the sandbox; allowed hosts come from the connector registry; keyless calls need no connector. Trust maps GET to the connector's read capability and everything else to its write capability, so cards match the Swift tools being replaced. Plus narrow OS calls that can only live in the stem: `host.calendar`, `host.reminders`, `host.contacts` over the existing `LocalPIMStore` and `CNContactStore`. Raw `network.*` stays.
*Proof:* a JS Gmail list via fetch with the token absent from the helper's environment and arguments; a JS calendar tool creates an event on the test copy; a write through fetch cards in Work mode.


**turn (new): their turn as a part.** Today's turn lives in `C/ChatTurnRuntime/ChatOrchestration+TurnEngine.swift`: persona through the ContextFlow kernel (:501-618, `NativeContextFlowRuntime.swift:70-110`), REM pins :620, recall :631, assembly :760-793, the tool loop with `app` as the only tool, sense news :1297, after-turn (memory, appraisal). The stem keeps: the one-exit loop and `TurnObservation` (lane A, 10-11), the per-iteration checkpoint and resume (lane B), `AppDoorReentry`'s gate chain, transport and streaming, quiet hours. `turn.js` gets: the signal (message + session), reach to recall/persona documents/pins/the model/the door, and returns the reply stream and the after-turn work. The seed is a straight port that produces the same bytes.
*Proof:* on a fixture turn the assembled prompt is byte-identical to main's; the 12-ask Luna drive shows the same `llm.call` count per ask (p50 3); a `turn.js` v2 that throws on its first round swaps back mid-turn and the turn completes on v1 with one observation; kill -9 mid-turn resumes on relaunch as lane B proved.

**S4. Waking (the new mechanism).** An ability declares what wakes it: `wakes: ["schedule:<cron>", "app.installed", "file.changed:<path>", "turn.ended", "message.arrived:<transport>"]`, a vocabulary drawn only from sources that exist: TriggerScheduler's exact deadlines, discovery's install stamp, senses' `source.watch`, after-turn, and the Telegram and Slack ingress. (Not mail: nothing watches Mail, and new mail is never pushed at them, User 10-07.) The signal is delivered to the ability as an event. No polling anywhere.
What's new: a run with no turn behind it needs a gate chain, and today `AppDoorReentry` refuses without one ("needs the originating turn's gate chain"). The stem gives a wake run its own chain, owned by them autonomy setting: reads and Full Mac effects run; anything that needs approval raises a card to User through the AttentionRouter (phone, quiet hours) and the run waits. Whatever the run needs from *their* goes through `ResidentWake`, never straight into their context. A wake run is CPU unless the ability itself calls `model.call`.
*Proof:* a `schedule:` wake fires once at its minute and never again; an ability with no `wakes` is never run unasked; a wake run that needs approval produces one card for User, held through quiet hours; a wake run that needs their lands as one home arrival.

**S5. Noticing.** `AgentPeerDiscovery` keeps its scan and its once-only offer; `agentAppWords` stops being the gate, and every bundle that *arrives after the baseline* (the first scan records what's there and offers nothing) becomes the `app.installed` signal with bundle id, name and whether it has a scripting dictionary. A built-in resident ability handles the signal by rule, on CPU: scriptable app → one home arrival "Keynote arrived. Want me to grow into it?" (dismissable until the version changes, the existing discovery.json rule); not scriptable → nothing. They are woken only for apps they can actually grow into.
*Proof:* a stub .app with an sdef dropped into ~/Applications on the test copy → one arrival on them home → yes → `sense.make` + `tool.propose` from its sdef → `abilities/<id>.js` exists → the arrival never repeats; a stub without an sdef → nothing.

**S6. The judge (small).** One rule, no counts, on evidence `state.json` already keeps: every run writes an outcome (ok, error, refused, cut). The stem rolls back when the current version has failed on every run since it was kept, at least one failure is the version's own fault (a JS error or a proof failure, never a refusal, a permission or the network), and the previous version's last run was clean (`lastCleanVersion`). It swaps (the atomic `RENAME_SWAP`), then tells their through `ResidentWake` with the evidence: "I rolled keynote back to v2: v3 threw X on both runs; v2 last ran clean 10-13." They decides whether to fix v3. No clean previous → nothing is swapped, they are told. The judge never deletes and never asks User.
*Proof:* keep a v2 that throws → two runs fail → the stem swaps to v1 and their home shows the note; a permission refusal on a good version triggers nothing.

**S7. Dead paths out.** The 8770 Mac-control HTTP bridge (no client; my `liquid-glass-ui` skill doc gets updated), the third file stack beside it, Procedures (2.8k, overlaps abilities), memory one-shot migrations (2k), `SwiftNativeScreenVision`. **Not** the 8771 Claude bridge: it's my live channel (`agent-bridge` skill). It moves to `agent_message` + the claude-code recipe only once that carries Claude both ways, with its own proof. Later lane.
*Proof:* build and architecture check pass; their app runs a day with no Doctor finding.

**Two pieces of tissue prove the pass.**
- **Weather** (`abilities/weather.js`, seeded from the 142-line Swift): fetches keyless (S3), asks the paired phone for location through `app.phone.request` as today, wakes on a morning schedule and files the day's line as one arrival (S4), and gets a deliberately broken v2 rolled back (S6). Then the Swift weather tool is deleted. The fresh-install drive asks for the weather and sees no difference.
- **The habit-former** (`abilities/habit.js`, built-in, resident): wakes on `turn.ended` (S4), reads the turn's trace by rule, and when the same hand-done sequence shows up again it thinks once (S1) to name and draft a skill, then proposes it through the existing `skill.save` path for them to keep. Repetition becomes craft; the token curve made real. It also fixes the placement rule phase 2 needs: an ability's header names its page, so seeds land on their natural pages (mail on mail), not on diagnostics.

**Order.** S7, S0, S1, S2, S3 and S6 in parallel: none depends on another. S4 after S0 (resident abilities). S5 after S4. Weather after S3, S4, S6. The habit-former after S1, S4. Then the drive, then the DMG. A stem change: **0.7.0**.

**Trust, in one line:** `model` is reach, not an effect (audited, never carded). `fetch` and the PIM calls inherit the capabilities of the Swift tools they replace. A wake run acts under their autonomy setting with its own gate chain. Nothing new gets around a gate, and Full Mac stays card-free.

