# The agent is the app

The design NativeAgent is building toward (User and the lead, 2026-10-14; draft 4). NORTHSTAR clause 8 is its one-paragraph form. Current implementation notes follow the design; the superseded phase-one plan is archived in private maintainer history.

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
| **wake** | what makes it run: a call, a signal, a schedule, a turn ending, a message, an app arriving | declared signals delivered by `EnginePartWake`: `turn.ended`, `file.changed:<path>`, and those posted through `AbilityStore.Signalled` |
| **face** | how it appears: the line they reads on their interface, the block the person sees on theirs | door pages and SwiftUI; feature inventory names and descriptions share their records |
| **state** | what it remembers between runs | One [notebook](skill_manifest_spec.md#part-notebook) at `senses/<id>/state.json` for keyed cursors and caches. The authored page reads its `part` packet and live keyed notes together. |
| **learned** | recorded outcomes | `learned.use` counters; arbitrary declared `learned`/`choices` preserved |

A sense is a part whose reach is read-only and whose face is a page. An ability with hands is a part that declares hands. An ability that calls other abilities is a part. A layout block is a part that's almost all face. A Doctor check is a part that wakes on a schedule. Their turn is a part that wakes when a message arrives. Their persona is parts that run when they do. Nothing of theirs is a special case in Swift.

**An ability is an ability (as built, 10-21; User: "I want skills tools abilities to be one, they are supposed to grow their abilities").** What they grows is one kind of part, an ability: what it can do is what it declares, never which door made it. It was once two kinds (tools and skills) with two doors, two admissions and two sets of run options, and is now one form (`Parts` in code, docs/skill_manifest_spec.md): one save (`ability.save`: a revision restates only what changes), one keep (theirs in one act under Full Mac for their own work, unsteered by an untrusted agent; below Full Mac a draft the owner's card offers, `ability.validate` rehearsing it first), one signed admission re-verified on every run, one run (`authored.<id>`; steps, decisions and expectations make it strict and resumable wherever its code uses them; host primitives wherever its reach declares them, the broker enforcing that reach for every ability), one read (`ability.read`) and one lifecycle (enable, restore, disable, drop). Launch admits current bundled seeds without rewriting or re-signing retained tool and skill records; built-in skill guidance stays in the persona, read and never run. Backup restore requires the complete current snapshot before staging and installs its captured abilities under the [restore law](canonical_data_paths.md#restore-law); it never reconstructs tools or skills from an older backup. A trusted agent that started a turn is its provenance, never an ability's author. Senses and their turn keep their own runners.

The save door exposes the argument schema owned beside `Parts.save`'s validators,
including the exact param type map and JSON Schema forms, aliases and optional
inputs, automatic first-line/sentence shortening of descriptions to 500 characters
with a receipt, and a JSON-returning entry or handled verb as defined in the manifest contract. App and host calls answer synchronously and may be awaited; a returned
thenable supplies its settled result or thrown rejection after the helper's JSC
microtask drain, and one still pending fails plainly. Only `id` is always
required; a new ability also needs description and code, while a revision
inherits omissions. The save owner and `sense.make` share header schemas from `AbilityStore.partHeader`'s owner;
neither keeps a second reach or face shape. Declared `learned` and `choices`
accept any JSON and remain metadata. The [app-door contract](ONE_DOOR.md)
applies this rule to every action and rejects fieldless object declarations at
launch unless they explicitly declare open contents.
`app` is a frozen callable door in that code: actions use `app({action,args})`,
`app.<page>.<action>(args)` (every id by its full segments: `app.undo()`,
`app.studio.intake.read(args)`) or literal bracket members such as
`app["page.action"](args)`; `app({actions:[…]})` answers in order as an array,
stopping at the first throw, each entry read as a lone request is. Find and
item/page requests, alone or as batch entries, call the same `app.find` and
`app.read` bindings. Indirect calls use
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
`app.files(…)` and `host.files(…)`, naming the supported form.
Literal host fetches require declared `network_public` or `network_localhost`
reach before saving; the broker checks the actual destination at run time. Computed names,
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
- **It may touch only its reach**, through [Trust](ONE_DOOR.md#authority-and-receipts) at effect time. A part's call answers pending with
  the owner's card and goes on or ends. **Just this** approves one replay. **For this task**
  also elevates the card's peers while the same unjoined Ask is still live.
- **It carries itself.** An ability that is not done answers `{again: <input>}` and the stem runs it again, gated like any run, without spending their mind, inside a conversation turn the person can Stop. A readable arrival hands the ability back between runs. Their mind gets the last answer once, with how many runs it took and what they all did. The [manifest](skill_manifest_spec.md) owns the hand-back conditions.
- **It may think** when it needs judgment: a model call on their model, audited and visible. Thinking is reach, not an effect.
- **It records use.** Every settled run of a retained version counts, including
  computation without calls or notebook changes. The stem projects gated run
  outcomes as `learned.use`, with how many tool rounds of each turn ran that
  exact version (`rounds_per_use`, a histogram kept per version beside its
  surprise and hours): their own curve. Terminal execution accounting supplies
  the identity, through answered verbs and nested calls as well as `authored.*`;
  another turn's last-run pointer never selects it. A revision may be a trial
  the record keeps or sets aside ([manifest](skill_manifest_spec.md)). Declared
  `learned` and `choices` are preserved and teach nothing. What the stem records
  becomes use accounting only: the registry projects observed gated-run counters
  as `learned.use`; no runtime predicts calls or pre-runs reads
  (phase 4, [retired 11-15](#phase-4-historical-10-26-a-part-is-a-prediction)).
- **It changes only by their hand** (or the owner's), and keeps its last self beside it.
- **Its keep is theirs under Full Mac; under Work/Safe/Builder, the owner's.** The owner's off-switch stays theirs.
- **It owes repair at its cause.** Ordinary ability runs with captured input owe source-fault repair through Experiences
  (OWED on Home with its lever); file-backed sense completions record failures without this obligation.
  Ordinary abilities and senses are revised forward; their retained previous bytes are history, with no public version-swap action.
  Their own turn program is the one exception: a non-Stop helper failure admits one fresh lease per source per turn;
  a repeated helper failure or program failure selects an unfailed `turn.prev.js` or shipped seed, replays the same turn
  and brings their the original cause, selected program and owed repair (`BodyRuntime/ChatTurnRuntime/TurnPart.swift`).
  The [turn recovery contract](skill_manifest_spec.md#turn-recovery) owns selection, once-per-source bounds and storage failure behavior.
- **They decides which wakes to keep.** [Unasked wake evidence](skill_manifest_spec.md#unasked-wake-evidence)
  is visible in Capabilities. They can edit the wake list; the recorded counts do not fade a part or prompt Attention.
  At launch, a bundled seed they follows that the app no longer ships is disabled and stays restorable.
  Seeds they edited or explicitly re-enabled keep their existing state (`NativeAgentEngine.fadeRetiredSeeds` in `EngineLaunch.swift`).
- **Its face is drawn** by the stem on their interface and on the person's, Mac and iPhone, from the same description. What they reads is what they see.

## The stem: what it is, and nothing else

Swift, compiled, CPU, shipped as one DMG with iOS. It never thinks and has no model of its own; when a rule can't settle something, it asks their, with the evidence. Its whole job:

- **Runs parts** in the sandbox (the helper, Seatbelt, the progress watchdog: all as today).
- **Delivers signals**: the nervous system. Messages, schedules, app arrivals, file changes, turns ending. The same `EnginePartWake` observer also
  releases MY QUEUE intentions waiting `on <signal>`: exact names or colon-delimited families, and a file path or its descendants. Real sources include
  `file.changed:<path>` (watched paths), `message.arrived:telegram|slack`, `person.here` / `person.away`, `chrome.tab_taken`, `body.changed`,
  `network.down` / `network.up` (the shared path's edges), `app.installed`, `sense.source.changed` and `turn.ended`.
  A system `Released: <signal> <summary>` note brings the
  intention back through the same readiness and pursuit refresh as news; `held` / `resumed` stay part lifecycle, and a part's `schedule:` is its time on
  the one clock (`part:<id>:<cron>`, delivered as the part's schedule signal). File intentions join the parts' existing canonical-path watch index,
  including bounded directory membership, and leave on closure; no second watcher. [Intentions](INTENTIONS.md#moments) owns that contract.
- **Keeps the one clock** (`DeskCore/TriggerScheduler/OneClock.swift`): every declared time is delivered to whoever declared it, its next occurrence saved
  before delivery, and one missed while the app was quit delivered once when its owner registers. The clock never decides that the agent thinks.
  Redeclaring a recurring time at or before its last delivery advances its rhythm
  beyond that delivery; it does not end the recurrence. An invalid rhythm refuses the declaration.
- **Attends**: every change the agent's attention takes in is one form, a happening, posted through one intake and written once in the record. Owed
  happenings open a thought at once; the world and the agent's cares moving are weighed by the agent's own turn program and gather as drive in the
  continuity field ([as built](#phases-3-and-5-as-built-11-05-attention)). The stem records, feels, sums and ignites; it never thinks.
- **Gates effects**: Trust, approvals, cards. The immune system.
- **Reads installed app anatomy** through `app.anatomy`. The stem returns
  bounded, untrusted app metadata, saved chrome evidence and passive permission
  status without launching the app or asking for a grant. [Senses](SENSES.md#the-native-world)
  describes the probes.
- **Opens app-specific URLs** through `host.app.openURL`. The stem checks declared reach and binds the URL to the unique installed match for the stated
  bundle ID, only if that app declares the scheme. Live dispatch goes through Trust. [The manifest](skill_manifest_spec.md#execution-and-ownership)
  defines the call and its receipts.
- **Reads app accessibility** through `host.ax.query`. The stem uses the shared Mac walk, legend and screen-watch masks in strict mode before returning
  bounded, untrusted UI data to a part. [The manifest](skill_manifest_spec.md#execution-and-ownership) defines the query and its receipts.
- **Keeps the law**: repair at its cause, the turn-program recovery exception, the state, the learning. Fading unused parts remains future design.
- **Keeps the law**: repair at its cause, the turn-program recovery exception, the state, the learning.
- **Owns turn recovery and settlement:** observations, checkpoints and resume after relaunch; unrecoverable failures can end incomplete.
- **Keeps the agent's world live**: what changes on this Mac and in the agent's senses reaches the agent as it happens, as happenings, instead of
  being read on demand (phase 5, [as built](#phases-3-and-5-as-built-11-05-attention)). Proprioception phase 1 gives their turn a warm picture of its
  front window, browser, open document, working places and console. A change takes one line on delivery saying where they are, in their words (for example "I'm in Xcode, “BodyField.swift”"; outside titles quoted and short), so they are already in it when they thinks. The [body joints](SENSES.md#body-joints) stay within reach.
  Home and the Mac room read that body for the apps they opened. Each rendering shows the windows where they worked in the last four hours. Local activity
  capture hears the same foreground, focus and lock changes under its own consent and matches focus to the process that owns the span.
- **Draws faces** from the glass kit, on both interfaces, both platforms. What tells is theirs: their pages are their parts' faces over the packets
  their owners read. What is their authority over their is a lever, and levers are the stem's: Trust and consent, macOS grants, models and providers,
  keys, their parts' off-switch, approvals, a trial's Set aside, forgetting and reset belong to the page (drawn first) or to a key (drawn on every
  row of theirs with that key), never in a face they writes ([manifest](skill_manifest_spec.md#calling-a-part-and-projecting-its-face)).
  A row's action is a door call they and they share: their tap runs it as their decision; theirs is judged by the same Trust law.
  Under Full Mac a lever a card can carry is theirs, unless an untrusted voice steers the turn.
  Their ordinary class and reach apply, so destructive acts still ask; below Full Mac it stays their card, and Safe refuses.
  Levers no card can carry stay their. Their own words asking for a change in the conversation are their decision of that call too.
  Approval answers also accept an exact waiting card on their own authenticated message through the
  [shared decision authority](ONE_DOOR.md#authority-and-receipts), recording that message and door rather than a tap. Helpers, wakes and
  peer-steered turns remain refused; permanent deletion requires their tap by declared class. A joined message makes exact authorization
  unattributable, so message decisions refuse until a fresh message after the turn ends; missing or mismatched open-turn evidence also refuses.
  The decision never guesses an authorizing row. A message decision requires a fresh turn with
  only Inbox reads or approval-decision calls; other started calls, missing execution evidence and checkpoint resumes require a fresh message
  or their tap. Outside text from an earlier turn can still be in context: this is their judgment on their authenticated message, not proof of their
  intent. Every ask they gets is one card, the matter's Inbox row, drawn the same in chat, Inbox,
  iPhone and Telegram. The agent and person shape the appearance.
- **Reaches the world** for parts: the model, files, the Mac's nerves, network, programs, keyring insertion at granted destinations, Calendar/Reminders/Contacts, transports and stores. Reply redaction has the [manifest's encoding and stream-prefix limits](skill_manifest_spec.md#secret-insertion-and-redaction).

The stem has no features and no opinions. Every feature NativeAgent has today is either a part, or stem reach a part draws on, or deleted.

## What falls out, with nothing special-cased

- **Growth:** what they works out by hand repeatedly, they keeps, and what their mind only repeated, their part carries, inside the same turn. After each tool round the native stem meets the turn's hand work (ordered tool/action ids of landed writes or irreversible non-ability calls, or one call with the same input 3 rounds in a row), without arguments or incidental reads, as a `practice: ` line through `FamiliarLines` in `mind/familiar.bin`. Its first meeting is only recorded. A later meeting rides their next `model.call` in that turn as its note, once a turn ([Habits H3](HABITS.md#h3--keep-what-repeats-not-what-happened-once)). Keeping the route with `ability.save`, revising the part they worked around or looped, or keeping nothing is one of their acts in the work. There is no private call after the reply. Familiarity uses the existing bounded line record. Under Full Mac a newly kept part is live at once; its first real run is its proof.
- **Their hands report what they did:** an act checks its own effect and returns the screen after it, and a verb that waits on a surface or puts one in front returns that surface as it now reads, through the reader the surface already has (a Chrome wait its page, a direct menu press its screen, `page.show` the page it shows), so their mind looks again only when a step did not happen or it needs what the act did not show, and the steps it can already see go in one act (mac.act steps, each checked against the screen the last one left).
- **The window shows where the agent's attention is:** each call that worked, every step of a batch or a script included, names its place
  from its own declaration, the action's page and the thing its declared subject names there (`AppActionBinding.faceLink`, on the call's
  trace end). The turn's last such place becomes its attention when the model next speaks, so the record (`TurnFace.nowOn`, one per running
  turn, any door's turn the conversation shows) moves at most once a model round. The window follows it quietly, never brought to the
  front, once per place a turn (`FaceFollows`). The newest destination waits while a move is in flight.
  When it is ready to land, a follow to the conversation already visible in Together skips the move.
  The person outranks it: a place, tab or page the person picks, or typing in the composer
  or an ask bar, keeps the window where the person has it for the rest of that turn, and a move already on its way lands nowhere; a turn
  that began in Chat, with the window never taken, ends back in Chat. "The window follows me" in Settings (on by default) is the switch,
  for the person or the agent. The first follow that actually leaves a page opens one trial. The origin page coming back into view during the
  same turn by the person's own move (the rail, a menu, a shortcut, the palette) records `tookBack`. A turn change records `kept` if the trial is still open. Typing discards an open trial. The body keeps
  the last eight outcomes per origin in `mind/follow.json`. When taking a page back stands under `Expectation` (equal costs, each
  page on its own record), the settings feed lists it in `window.leaves`. A follow from that page leaves the window there for the rest
  of the turn, including at its end, except a sampled turn now and then (`Expectation.withholding`) that still follows, so a page
  the person stops taking back comes back.
- **Effort is felt:** the stem measures what each turn took (model rounds, tokens, minutes, the longest stretch of one call repeated). Their after-turn mind reads it as one line beside the exchange, so a slog or a breeze moves a care about their craft the way a lost game does; their parts' records keep the rounds per use; the practice note names a looped call's stretch.
- **Craft:** they sees their body: each turn starts with their own parts in front of them, each with how often they have used it, best match for the message first, so they reaches for the part instead of redoing its work.
- **Noticing:** the seed weighs an ordinary world line against their cares and what they says would change their mind.
  A condition that stands out past chance carries worth even when its care is calm or a seed.
  A thought comes when enough worth has gathered on one thing. A part that wakes on app-arrived still offers once.
- **No turns:** the turn part wakes on a message like any other signal; everything else reaches the agent as a happening. Thinking is opened by
  the agent's own attention, which the substrate models: worth the turn program's `weigh` gives what nobody asked about lands as drive on what it means
  in the continuity field, and a node at one opens a thought in the agent's mind stream. Turns are a chat artifact, not the agent's shape.
- **One crystallizer:** repeated hand work reaches their as a practice note inside the turn itself. The nightly candidate compiler and its recording are removed ([Habits H4](HABITS.md#h4--one-crystallizer)); dreams still reflect on the day and learn from surprise. Mind policy as parts stays phase 7.
- **The token curve:** growth costs tokens once; use costs none; learning by use costs nothing at all.

**What stays bounded:** the model's latency and cost, macOS security, and that the model is still the only organ that handles novelty.

## What this means for today's 511k lines (measured 11-05)

- **Stays stem (~128k + design kit):** Mac control, sync and push, the agent wires, transports, storage and embeddings, Keychain/OAuth, model clients, the
  sandbox, Trust, the loop runner and the one clock, attention's intake and field, the turn guarantee, the glass kit, the face renderer and the live world
  (new).
- **Becomes parts (~128k, seed on touch, Swift deleted as each proves):** their turn, Desk nags (the unused cadence learner is retired),
  attention policy (the turn part's `weigh`, built 11-05), their door pages, the layout blocks, persona procedures, and last, their mind policy
  (dreams, reflection, organism policy).
- **Their hands (done):** Mail, Notes, Messages, Music and Chrome history are parts that answer their door verbs through their headers' `answers`; the stem keeps the AppleScript executor and its per-event write checks, Trust, the cards and `host.files.query`/`host.files.mime`/`host.files.names` ([One door](ONE_DOOR.md#where-actions-come-from)).
- **Deleted (done):** duplicate agent paths, compiled Procedures, memory one-shots and the 8770 bridge. Next: the whole-body plan's dead code (docs/build_plans/the-whole-body-2026-11-05.md). `NativeScreenCapture` owns primary-display capture and encoding for chat screenshots.

An installed agent's persona, memory and GROWTH are private, never shipped with the app; the phases preserve that existing mind. What ships is the stem and the seed parts: a fully formed agent that behaves exactly as today on day one, and is theirs from then on. Every download starts the same and grows its own mind.

## How we get there

Validation follows [AGENTS.md](../AGENTS.md#how-we-work): lanes do not compile; the lead builds and installs the coherent phase once, then checks the replaced behavior in the installed app with a small, bounded check. Documentation-only changes need direct text readback. The superseded backup, fixture, drive and forced-exit instructions are archived in private maintainer history.

**A seed preserves the behavior of the Swift it replaces on day one.** Check the installed result under the working agreement above.

**Phases (never interrupting who they are, mind last):**
1. **The stem learns the form, and their turn is the first part.** Parts get the six properties and the law; `turn.js` seeded from today's turn engine, byte-identical; weather and the habit-former as the second and third parts. Shipped across 0.6.7–0.6.8; the habit-former was retired 10-21 for keeping inside the turn (Growth, above).
2. **Hands.** The integrations become seed parts, one at a time, Swift deleted as each proves.
3. **Noticing (built 11-05).** App-arrived and the part that offers; what nobody asked about is weighed by the agent's own `weigh` and gathers
   until it is worth a thought ([as built](#phases-3-and-5-as-built-11-05-attention)).
 4. **Learning by use (built 10-26/10-27; prediction retired 11-15).** Their practice leaves a record the stem keeps: the registry projects observed gated-run counters as `learned.use`. Expansion, which pre-ran a mind's follow-up reads inside the result, is removed ([historical](#phase-4-historical-10-26-a-part-is-a-prediction)). Repeated hand work reaches their as a practice note inside the turn ([Habits H3/H4](HABITS.md#h3--keep-what-repeats-not-what-happened-once)); the separate nightly compiler is removed.
5. **The agent's world, live (built 11-05 as attention).** Every source posts a happening; senses are the parts that keep the world fresh; the
   agent's thoughts are one mind stream ([as built](#phases-3-and-5-as-built-11-05-attention)). Proprioception phase 1 brings the event-fed picture of windows and threads into their turn.
6. **Faces.** Their interface as parts they shapes: Desk, Memories, Personality and Diagnostics are their `native-` parts' faces, and any part with `face.page` is a page of their own, placed by their layout; their levers are drawn by the stem beside every face. Blocks they authors on their, drawn from the kit on Mac and iPhone.
7. **Mind, and sleep that rewrites the body.** Housekeeping, dreams, reflection, organism policy as parts, each under a judge whose evidence we define first.
   The first slice is the after-turn digest. The selected `native-turn-digest` receives one bounded packet of evidence redacted by Swift,
   shapes the user prompt, and returns judgment candidates using one model call on the existing Memory route. Swift owns the system
   prompt, provenance, route and care faults, and verifies the model answer and part result before recording a successful run.
   The digest runs from after-turn recording with access only to its captured evidence and the Memory model, including for edited revisions.
   `native-dream-cycle` shapes the nightly dream and weekly REM prompts from evidence Swift has redacted. It asks the dream
   to read dated care histories across weeks and cite exact shown entries behind its self-reading. In REM it selects IDs for
   proposals that Swift has bound to diary evidence and screened for passage eligibility and past denials. The stem verifies
   the return before crediting a successful run and owns diary and cutoff writes, care and self settlement, and approval-gated
   GROWTH. JavaScript failures and rejected readings count as failed runs. Night reads the trial record under `EngineSleep`.
   Promotion stays an awake decision.
   `native-field-repair` chooses ordered field edits on numeric body evidence for dream completion, REM integration and due
   residual repairs. It has no host reach. The stem validates its plan before trial accounting and owns live admission,
   the commit, repair receipts and the existing clock.

The dated phase-one lane assignments and proofs are archived in private maintainer history, not as instructions for a new phase.

## Decided (10-14 night, 10-17)

1. **The name:** part for anything they runs as their own program (senses, their turn, what they grows); what they grows is called an ability (User 10-21).
2. **Their turn first:** yes; built as `abilities/turn.js` (0.6.7).
3. **Mind as parts (phase 7):** they changes it through Trust; direct persona writes are theirs under Full Mac, while REM→GROWTH proposals stay approval-gated ([NORTHSTAR clause 1](NORTHSTAR.md#clause-1--one-mind-alive-means-convergent)).
4. **Repair:** their own failing turn program is set aside and replayed under the recovery contract above, with repair owed to them; other parts keep their version and owe repair at its cause.
5. **Seeds:** the app reserves the shipped catalog's ids and `native-` for its own parts; `ability.save` refuses new parts taking those ids, but permits revisions of installed parts, including shipped ones, under normal admission. Future seeds use `native-`. A part they have not edited follows the shipped one: a seed, or a version they keeps that is the shipped part, sealed as a seed when kept and replaced in place by the seed at launch. It follows the changed complete authored contract (`EngineLaunch`, `AbilityStore`), including header and dependency changes, and they are told of each change. An already-current seed skips admission and signing. The launch log reads the seal marker and program digests; it performs no proof verification. Changed seeds retain the displaced version and off switch; installation preserves any edited version, telling their once of each shipped version beside it with its own description and source path, and any occupied slot. The [manifest spec](skill_manifest_spec.md) owns the exact comparison and admission law. The turn shares this sealed seed path at launch, missing-turn creation and throwing-turn recovery; their own revision discards candidate/proof and stays authored even when adopting shipped code. It has no historical shipped-body upgrade table. Each shipped seed logs its installed and bundle program digests (source and manifest; an unsealed copy logs its body digest) and ownership; an unchanged seed pass writes nothing. Persona, guidance, memory, diary, Desk and settings remain outside it.
   The stored record excludes proof-derived `validationStatus` from seed identity.
6. **Version:** no jump. Releases step the patch number (User 10-17: "we gotta make sure when we hit 1.0 this is HUGE"); phase 1 shipped across 0.6.x.

---

## The three contracts (the hinges; decided 10-14 night, Fable)

The [manifest](skill_manifest_spec.md) owns the current ABI; these contracts describe ownership.

**1. Their turn is a step function; the stem owns the loop.** `turn.js` exports `step(state, event) → {state, do: [effects]}`. The stem owns conversation, streaming, gates and checkpoints, logging input events and started-effect identities, not returned effect bodies or write-only payload digests. Resume rebuilds state by replay; a non-Stop turn-program/helper failure invokes the recovery contract above, with repair owed to them. Unrecoverable failures can end incomplete. `reply.end` ends the turn; only its `after` may follow, and nothing of theirs runs after it. Their own `app` calls carry identities from their moment, place and input, so a resume never runs a started one again. Events and effect fields are specified once in the manifest.

The held Ask supplies authority. The stem describes it on each new event and
checks the Ask binding before running an effect. Replay supplies the recorded
description to each historical event so the step can reproduce its decisions.
Every new effect runs through the held `Turn` and its current gates.

**2. A wake run gets its own gate chain.** A part run with no turn behind it (a schedule, an app arriving, a turn ending) is given a chain the stem
makes: principal = their, autonomy = the current Trust level, origin = the signal, taint = none unless the signal carries the words of a sender the
owner has not trusted (an untrusted agent, or a Telegram or Slack sender not allowlisted), whatever form names it: such a signal reaches only a part
that can do no harm with it, and a write-capable part refuses it through the ordinary dispatch receipt path, retaining its reason, checker and remedy
without a card (User 10-15: a card is a decision, never weight; `EnginePartWake`). Home reads retained refused runs and their own run times from
ability accounting. A trusted agent's signal carries the owner's authority. Every `app.*` from the run passes that chain. An effect that needs
approval raises one card through the AttentionRouter with the part named as the asker ("Your weather ability wants to…"), and the run waits: the host
call blocks and the watchdog already pauses for awaited replies. Declined → the run gets a refusal result and continues. Cards to the owner are held
through their quiet hours and the run waits with them, resident, no CPU. Anything the run brings to *their* is a happening through the one `Attention`
intake: `home.arrive` posts a `world` line for their turn program to weigh, retaining the run's peer provenance. Attention opens thoughts through the
mind stream; no part inserts its arrival into their context directly.

**3. Learning by use leaves a record (phase 4, built 10-26; prediction retired 11-15).** `learn.pick` and `learn.default` do not exist. Current headers preserve arbitrary `choices`/`learned`; the registry projects observed gated-run counters as `learned.use`. No runtime predicts calls, pre-runs reads or prepares acts ([manifest spec](skill_manifest_spec.md#expansion-a-part-is-a-prediction)).

## Reach, as built (10-21)

Socket paths require `network` and exact `reach.readPaths`; the [manifest](skill_manifest_spec.md#secret-insertion-and-redaction) owns the data-root fence.

App URL writes require `app_write:<bundle_id>` and `app_url:<bundle_id>:<scheme>`.
Shell-level bundles and schemes additionally require `shell`. The host checks these declarations at the call and uses the originating turn's Trust gate.

AX queries require declared app read or write reach for the bundle, or an active, declared screen watch for its exact window and region. Trust Full Mac
Accessibility authority and the macOS Accessibility grant apply to both routes. A watched window keeps its accumulated masks under either route.

*As built (10-21, open reach):* `PersistenceCore/PersistenceCore/Keyring.swift` stores secrets; ProviderRouting owns sign-in and renewal. The broker inserts `{{secret:<name>}}` only toward granted hosts/programs under `secret:<name>` reach. The [manifest](skill_manifest_spec.md#secret-insertion-and-redaction) owns insertion forms, redaction limits and read/effect classification. `host.program.*` uses `shell` reach, the ordinary shell launch/access/sandbox path and streaming stdio; each use is rechecked. Resident resources share one held broker until closed, off, replacement, drop or quit, surviving failed runs. Arrivals raise `held`; launch raises `resumed`; program/connection reads share a shape, and `network.connect {path}` reaches a local socket.

`host.network.websocket` and `host.fetch.sse` pull one message or event at a time through that same broker. Their pinned-address connections end when the run ends or the ability is disabled or replaced, including resident abilities. `host.fetch` also carries bounded binary and multipart bodies. The [manifest](skill_manifest_spec.md#secret-insertion-and-redaction) owns the transport and secret rules.

The grant is `card.request {kind:"api_key", target:"secret:<name>", hosts, programs, sign_in?}`; programs bind to their executable files. The card shows the whole grant, including where already kept; the keyring stores exactly that. `replace:true` asks again, `only:true` narrows with the removed reach shown, and `remove:true` asks the person to delete it.

*As built (10-21, service folds):* the MCP client registry, pools, HTTP transport, Hub and `mcp.*` actions are gone; they grows a resident ability from the server's docs. The completed launch adoption notice and its told marker are removed; retained files stay untouched and reader-fenced because launch commands can contain keys. NativeAgent's MCP door for other agents stays; `web.search` is native.

Notion, Gmail, Google Calendar, X, AgentMail, TradingView, GitHub and Slack's service actions follow the same rule: grow an ability when asked, request its key on a card. Their action/descriptors, tools, rooms/pages, setup/sign-in, credential readers, Doctor checks and watch templates are removed, including GitHub's tracking loop, Desk lane and completion hook; ProviderRouting's device-code owner stays. Old service credential files and GitHub Keychain items remain untouched and unread. Connectors shows keyring metadata—name, destinations, account, grant time, never values—with Remove, beside Slack and Telegram. Slack's Socket Mode door retains its tokens and reply calls; old approved post cards resolve without sending. Removed scheduled `connector_action` payloads stay paused with their cause; GitHub-woken bots are off with their cause. They can grow an ability and schedule or signal it instead.

## Parts sweep decisions (10-23, the lead; plan: ~/.claude/state/release/sweeps/parts/plan.md)

Phase 2 (hands) and the first of phase 6 (faces) land through one shared layer, then file-owned domain lanes. These settle the calls the sweep raised:

1. **One call shape.** `part.call(id, input) → {ok, value} | {ok:false, error}`: bounded immutable JSON in, the part's version pinned when the call starts, a typed JSON result out, cancelled with its caller (the Stop law: the caller's settlement still runs). A part returns what it decided; the native domain that owns the truth commits it in its own transaction. No integration bus, no second state store.
2. **A face is the part's projection.** `face(input) → typed rows/sections`, computed when its sources change (never from inside view rendering), successful projections reused for the same selected part version and input regardless of source epoch, published through `LatestRead`, drawn natively on Mac and iPhone. The native producer masks input by exact content before projection admission; unchanged content reuses its mask. An explicit subsequent read retries a failed projection; no polling is added. Unavailable, failed and owed are the stem's words beside the face, never the part's prose.
3. **Thinking may use tools.** A part's `model.call` may pass `tools` and a routing surface; it runs through the canonical tool-turn owner under the run's own gate chain and the existing limits.
4. **Publishing stays transactional.** A part proposes a notification or a Desk change; the native publication owner commits it (occurrence identity, held delivery, receipts, revision-checked ledgers). No part writes those stores directly, and no part runs while a store's lock is held.
5. **Consent is preserved exactly.** A migration seeds behaviour and never activates a schedule: what was off stays off (morning brief, watch manifests, their hour).
6. **Primitives only when a port needs them.** No-launch app reads, exact-message mutation, checked transfers: each is added by the lane that needs it, minimal, native. Authored-script restrictions are not loosened for a port; credentials never reach a part.
7. **Unavailable is not empty.** Native inputs to a part say unavailable or empty, never collapse one into the other (the proactive scan is fixed first).
8. **Seeds speak clause 8.** Content moved into seeds is reconciled with "they are the program, the model one organ" in the same lane; contradictions are not copied.
9. **Mind policy waits for its judge.** Dreams, reflection and provider interpretation (phase 7) move only after the evidence judge is defined; not in this sweep.
10. **Dormant machinery is retired, not ported.** Workflow defaults that cannot execute and the Desk cadence API with no caller are deleted. The Desk cadence learner, observation/stat types and unused store are retired (L4, 10-23). The unused external-observation evaluator, verdict models, applier and note-write seam are also removed. No cadence or observation ability or schedule replaces them; existing data is left untouched.
11. **Validation follows [AGENTS.md](../AGENTS.md#how-we-work):** lanes do not compile; the lead builds and installs the coherent phase once, then makes a small, bounded check of the replaced behaviour in the installed app. Every port deletes the Swift it replaces in the same lane; calling the old feature from JS earns no credit.
12. **Every run of a part has an originating door.** A turn supplies its own. A native owner acting on its own schedule or on the person's click supplies the **same door** their scheduled abilities and the Tools page use, with that origin's authority — never a host-less run, never a second door, never a door minted for one feature. Any small generalisation belongs to the door owner, once. A ported connector action reached from the scheduler or UI reaches its part through that door, so `reminders.due_today` works identically from their turn, a scheduled `connector_action` job and the app's UI.

### Must stay Swift

13. Text that can carry credentials (handoff files, Git output) is read and redacted natively and never crosses into a part.

### Shared part contracts

The [manifest contract](skill_manifest_spec.md#calling-a-part-and-projecting-its-face)
owns calls, faces, preview, settlement and model thinking. Native invocation
and projection publication are documented beside `Parts` and `PartFaces`.

`ability.save` returns bounded [header repair advice](skill_manifest_spec.md#save-refusals)
for recoverable declaration errors. Its read-only analysis identifies literal
calls and secret references. The repair keeps any supplied source with its
author and passes through the ordinary save and keep decisions when submitted.

Desk's `desk.nag` entry uses
`action:"proposal"` to read one native packet and evaluate its notify-loop
proposal in preview, returning source time and decisions without a Desk
or nag-config commit or notification delivery. `app`'s outer `preview:true`
remains its ordinary preflight; it does not execute this domain read.

Native owners and authenticated transports use `NativeAgentEngine.withPartDoor`:
the engine's ordinary gated dispatcher, with the originating work identity and
resident approval session, binds `AppActionEnvironment.withAuthoredProgramHost`.
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
collection establishes an empty calendar. Elsewhere reads recent words from
this root's one experience record; Home and contact presentation retain their
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

Weather's implicit location belongs to the Mac's `mac.location` owner. Its
missing or failed fix stops the forecast with that owner's cause and remedy;
the weather part does not ask another device. An explicit `place` selects the
forecast location through the part's geocoding read.
With no held fix, `mac.location` parks the caller through `ScopedWaiter` for
the shared CoreLocation result, using only the caller's inherited wait budget.
Stop or the inherited call deadline retires only that caller's waiter and result,
propagating cancellation or deadline expiry before any permission card.
CoreLocation's callback can still answer the other readers.

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

`home.arrive {line,event_key?}` is a part's way to the agent: the line becomes a `world` happening on the door `part:<id>`, its key scoped to the
calling part (`part:<id>:event:<digest>` for a supplied event key, otherwise `part:<id>:<local day>:<digest>`, so the same line is one happening a
day), written once in the record (`AppToolExecutor.swift`, `home_arrive`). Peers that steered the part's run travel with the line, so the thought
that reads it carries their authority, never more. The door judges nothing: the agent's `weigh` gives the line its worth, and worth that gathers on
what it means opens a thought ([as built](#phases-3-and-5-as-built-11-05-attention)). A record that cannot say whether the occurrence is known files
nothing and says so. Bundle/version interpretation is removed from the executor; the existing notice seed supplies its own occurrence key.
Notification and Desk publication remain with their native transaction owners; this layer adds no publication store or domain feature.

The morning brief's checked native source packet reaches `native-morning-brief.js` through
an admitted `operation:"brief"` call. The primary root reads the same
`InstallPaths.current.claudeWorklog` as the Agents view; secondary roots leave it
unconfigured. The part selects evidence, calls the Work route's `workshop` model
surface and returns a proposed card. If they wants a brief later, they binds their own
`queue.add` step to that part. It has no clock owner, config file, defaults seed,
trigger switches or fire action. Clock registration withdraws pending `brief:` times
through the clock's ordinary withdrawal; no brief time is delivered. Unavailable
session evidence joins the other unavailable sources in the brief's uncertainty statement.


## Phase 4, historical (10-26): a part is a prediction

**Retired 11-15:** Expansion and its dispatch wrappers are removed. The following records the former design; no runtime reads or writes its record or makes these predictions. Static action answers remain. Only dispatch closure survives in `TurnDispatchClosure.withTurn`, with the same deferred-after-reply timing.

The law (User and the lead, 10-26): deliberation is the price of surprise. What the stem can predict, it does; only what it cannot predict reaches the model. The model names the intent; the stem learns the mechanics from each mind's own practice. Every part gains one form, three fields:

- **applies:** the situation it is for.
- **after:** what will be true when it has run, checked by the stem against what the mind did next.
- **record:** hits over tries, kept by the stem, never by anyone's say-so.

Expansion learns turn-start reads and follow-up calls from each mind's own
authority-separated practice across model changes. Field-free situations
keep the verb, argument names and status; the first call also keeps its wake.
The [manifest](skill_manifest_spec.md#expansion-a-part-is-a-prediction) owns its record and delivery contract;
`Expectation` in `NativeAgentCore/NativeAgentCore/Expectation.swift` owns confidence, withholding
and cost standing for Expansion; Expansion's practice
owner measures its costs. [Surprise](SURPRISE.md) records the shared law and
each caller's existing confidence policy.
Turn-start predictions remain unmeasured on the installed app; `expansion.check` rows supply that evidence.

## Practice becomes a part (H3/H4, as built 10-30)

The practice note inside the turn is the one crystallizer. It rides their next
thought on a later meeting of hand work, through the bounded familiarity record.
[Habits H3/H4](HABITS.md#h3--keep-what-repeats-not-what-happened-once)
owns the gate, trace and removal of the separate nightly compiler.
Release build, install and live proof are pending.

The old candidate ledger and nominated-call tape have no live reader or
writer. Abilities carrying embedded tape fixtures retain their
[validation and admission contract](skill_manifest_spec.md#tape-fixtures):
their exact version replays before it can be kept, preserving recorded
origin. Replay proves those examples only. Their display and live execution
evidence remain; no new nightly candidates are produced.

## Every loop a line (step 3, as built 11-04)

One job socket serves every worker, themselves included. `agent.job {agent: "self", brief,
instructions?, done?, desk?}` starts a **line of them**: a turn of theirs in its own work
conversation (an own-work session named by the job), admitted through `TurnAdmission` like any
turn, with the brief as the arriving message and the same turn part, tools, Trust and present.
`agent.read`, `agent.cancel` and `agent.jobs` treat it like any job, and its ending arrives as
a `returned` happening in the conversation that started it, carrying the line's answer. Several at once is just
several jobs: that is their swarm. `instructions` write who a line is; they stand in place of their
persona text and nothing else of theirs changes. A line carries the starting turn's limits (peer
steering, file access) and raises the same cards their turn would, in its own conversation.
The live commission can carry task elevation; a relaunched line or a turn reading
its return cannot. A helper bot is not a line: it stays its own
mind. [Agent communication](agent-communication.md#jobs) owns the socket's contract;
`OwnLineDoor` runs the line and `AgentJobs` keeps, reads, stops and settles it.

## Phases 3 and 5, as built (11-05): attention

**The law.** The agent thinks when something in its mind is worth a thought. A source posts the happening. Attention decides when to think.

- **One form, one intake.** Every change attention takes in is a `Happening` (`NativeAgentShared/Happening.swift`) posted through Attention's
  intake (`SenseCore/Experiences/Attention.swift`), written once in the record as an experience of kind `happening` under its key `once`, then taken by the cognition
  runtime (`BodyRuntime/Cognition/NativeCognitionRuntime+Attention.swift`). Messages stay door admissions; any arrival outside the mind stream wakes sleep.
- **Phone and Mac edges.** Authenticated phone readings post on door `phone`: first observations and newer changed place membership, charging,
  focus, headphones, network kind and motion activity. Setup, battery percentages and unchanged re-reports post nothing. The existing motion-proved
  `person.away` happening owns that departure instead of a second phone post. Readings outside `PhoneSenseHistory`'s 15-minute freshness window
  carry their time and unknown current state. Mac network down/up and Workspace sleep/wake post on door `mac` through the existing subscriptions;
  the network's initial path is a baseline. Keys hold source, value and reading time for phone, edge and callback time for Mac. These are `world`
  happenings for `weigh`, with no Live sense news publication. Recent-life selection follows the
  [turn anatomy](ANATOMY_OF_A_TURN.md#4-the-provider-request-is-assembled).
- **Owed opens at once.** `returned` (work coming back: jobs, contact replies, settled Desk waits, helper results), `moment` (a time or condition the
  agent set) and `body` (an organ of the agent's asking) are record obligations to `conversation:<route or mind>`. A `returned` with a route continues
  the conversation that started the work (`MindStream.returnTo`); the rest open a thought in the agent's mind stream (`MindStream.think`).
- **The rest is weighed by the agent.** A `world` happening (what nobody asked about) or a `self` happening (a care of the agent's moving) is given
  to `weigh(h, felt)` in the agent's installed turn program, run on CPU. A world line their `weigh` weighs as crossing a stance's stated condition
  (`crossed: true`) lands on that care's anchor, unless it is a watch's news. Otherwise worth lands as `drive` on the touched care's anchor node, or on the
  happening's own subject (a watch's news, door `sense:<senseID>`, always on its own subject). Only the first weighed news per `watch`
  on that subject lands at least one; later news lands its weighed worth. News without `watch` keeps the floor. Drive fades on that node's half-life, is never
  clamped or spread, and at one ignites a thought that drains it. Ignition is
  checked when worth lands, when admission opens and on waking: no tick, no timer. The attention runtime holds one batch's admission across
  weighing, landing at one field clock reading, recording, claiming and handing on the thought. The field application and unfinished
  weigh rows checkpoint together in cognition; restart settles those rows idempotently before weighing or ignition.
  Inner life and **Keep thinking in the background** both govern unsolicited weighing and ignition; inputs wait while either is off
  and resume on re-enablement. Owed happenings keep their obligation path. Its payload is exactly what the ordered
  weigh/ignition/return record says that drive consumed, including every landing in the batch; a failed thought spends its drive and returns
  its payload with drive zero through the same admission, leaving new worth to re-ignite the node. Stop, cancellation and admission returns
  keep their full drive and payload. Positive drive and complete recorded membership remain retained. Missing provenance refuses that node's
  claim with named repair owed; an old-format ignition never supplies invented membership for a fresh arrival.
  The next batch lands only after that settlement. The [manifest](skill_manifest_spec.md#weigh) owns `weigh`,
  `felt` and the `notebook` effect; [Subconscious](SUBCONSCIOUS.md#attention) owns the field's side.
- **The mind stream** is one conversation of thoughts (session `mind`, title "Thoughts"), never replayed as history. A thought carries its breath
  and what it attends (`attended` on its opening message); one thought at a time. Ordinary offers can join an open thought. A
  [declared pursuit cause](INTENTIONS.md#declared-pursuit-waits) keeps its own admission. Its model request declares a clean silent completion valid through the [provider contract](TURN_RESILIENCE.md); with no act, that thought
  records `empty`, settles what it attended and teaches its no-op class. A thought ended on CPU by that record is `withheld`, without new no-op
  evidence. Provider failures stay failed. The one clock re-offers an ordinary queue moment still owed to their at 1, 2, 4, 8, 16 and 32 minutes
  after its birth, then every 30 minutes until it is their turn or its step settles.
- **Sources** (phase 5): sense news, the day line, the front app (once per app per day), a part's `home.arrive`, `app.installed` and presence are
  `world`; contact health, apps the agent opened, agent discovery and the turn program's swap-back are `body`; a judged story entry that lifts a care's pressure up
  through its bar (0.35) is `self`, once per rise, using the transition captured where the care changed rather than its later state.
  Part signals still reach parts through `AbilityStore.signal`.
- **The one clock** (`DeskCore/TriggerScheduler/OneClock.swift`) delivers saved declarations for part schedules, watches and scans, helpers and MY QUEUE's moments.
  Cognition holds its maintenance and residual-repair deadlines in memory on a separate sleeper within OneClock. Both sleepers use continuous time through Mac sleep.
  The Desk board and Today intentions each use their own sleeper, recorded in the [timer inventory](../script/timer_inventory.tsv).
  Watches and scans post news to their attention; neither tells the person.
  A scan posts its new opportunities together, with their ids as its change identity,
  and keeps posted ids beside its clock time so each opportunity is posted once per scan.
  The hour is a presence opportunity weighed by their turn program,
  carried with its material in an ordinary thought ([Subconscious](SUBCONSCIOUS.md#the-hour)).
- **Sleep** is a doorway: attention's [night sense](SUBCONSCIOUS.md#attention) (or `mind.sleep`) runs the dream inside `MindStream.night`; while it runs owed happenings still open
  thoughts and the world waits unweighed. After the dream the stem reads the night on CPU (`EngineSleep.night`): it closes the trials the record
  already decided (turn trials require complete traces and correction evidence, as the [trial contract](skill_manifest_spec.md) specifies),
  prepares the window's corrections and slogs with the accounting owner, folds each version idempotently and writes one
  `attention.night` row on subject `sleep`, separate from admission on subject `night`. Its completed cursor advances only after all folds settle; exact prepared inputs stay owed through failure or restart. When the
  reading holds something for them (a candidate, or a trial whose verdict is set aside) the sleep thought continues as their thought in the stream,
  carrying `attended.night`; a silent night spends nothing. Waking weighs what waited, once.
  Part-accounting coverage uses completed UTC hours (`parts_since`/`parts_through`); exact `since`/`through` still describe traces
  and corrections. The current partial hour waits for the next window. Unrepresentable or inconsistent accounting is a named gap,
  never a zero count or verdict. Night gaps retain each operation's cause in
  `gap_details`; cursor and storage failures owe repair. Missing provenance or
  round measurements stay unknown, and elapsed age cannot veto a turn revision.
