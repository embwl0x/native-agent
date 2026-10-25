# NativeAgent Changelog

Reverse-chronological. Each phase: 1–2 lines.

---

## 0.6.11 — one household (2026-10-24)

- Helpers are their own agents: each runs its own turns in its own conversation, with its own name, personality (a new field in the editor), job and model, remembers what has passed between it and their, and talks to them by name as a member of the household who carries your grant; a helper's time limit is reported when crossed and never cuts it off mid-conversation; a blank daily token limit means no limit, not a silent 256K; a helper run you ask for in its own chat answers there; Edit opens the helper it edits, and Regenerate in a helper chat on the phone replaces its last reply
- One timeline: a conversation another agent has with them that you did not start shows in your Mac chat in time order, each finished exchange a compact reading copy that opens that contact's thread, and the phone shows the same; they can speak to you from inside it, the next turn you start carries its newest exchanges, and the copies never become messages in your conversation
- Stop has one law: it cancels the work, never its settling, so whatever it ends is recorded once and says what landed. A stopped reply keeps its words and reads stopped; a card's wait ends and the call it blocked settles once; a message already sent to Grok Bot or a local agent stays sent and is said plainly; a program, Codex run, image generation or installer is stopped with its whole process tree before it settles; a shell command's own timeout is part of its output, and only your Stop cancels it; the phone's Stop keeps the run it was meant for
- They grows by doing: what they works out by hand during a turn becomes their own ability while they works (kept in one act under Full Mac, otherwise a draft your card offers); the tools and skills they made are one kind, abilities, which they revises by editing and can roll back; an ability's off-switch belongs to whoever flipped it (theirs they turns back on, yours they asks you to lift, and an update never clears it); much of them shipped behavior is now a part they can read and revise like their own: the morning brief, Telegram's help, status and model-choice words, when the Desk interrupts you, the weekly Workshop digest, the off-disk backup schedule, Research Lab's picks, Music, due reminders and the work journal
- A service is theirs to grow: the built-in Notion, Gmail, Google Calendar, X, AgentMail, TradingView and GitHub connectors and NativeAgent's own MCP client are gone (the Slack and Telegram chat doors stay), and they are told once which you had set up so they can grow the one you want; what they grows keeps each secret in one keyring you grant on a card, pasted or through a sign-in NativeAgent runs, and a secret goes only where its card says, only encrypted, and never back to them; the Connectors page lists each secret under Secrets with where it may go and Remove; what they builds can ask macOS for Bluetooth, Camera and Photos like any other access
- Nothing about the Mac slows their or drops their turn: Low Power Mode, heat and tiredness no longer throttle their background thinking, Workshop or repair, and Low Power Mode is no longer part of them body sense; a lost or dead connection or a busy provider is dialed again until the answer starts (up to ten times, backing off), as Claude Code and Codex do, so a flaky hotspot no longer fails their turn; offline, a message waits for the network instead of spending its retries; a long thinking stream is no longer cut at 60 seconds, and a large request gets the time it needs before its first word
- Web search is SearXNG: it is built in, not an MCP server, finds a SearXNG running on your Mac without a setup step, returns its results or says plainly why it failed, and no longer goes through Codex; a Mac without SearXNG searches in Chrome or their own browser; Doctor says a broken SearXNG means no search, and its check waits long enough for a slow network
- Grok Bot is a two-way contact: it can start a conversation with them through the same door every contact uses, never their tools, as well as answer theirs; Connect brings Grok Bot to the front and back again through them own app activation, an unfinished setup resumes with the same contact, the routine's webhook is read through a recipe they can edit, the clipboard is put back as it was, and a setup that saved its credentials and proved a round trip reports success
- A restore brings back what they had: the backup's conversations, queued messages and attachments come back as they were, and a backup from before abilities brings back their tools and skills; the life being left is kept in a safety backup first, work from before the restore reads stopped until you resume it fresh, their unread notices survive, an upgrade is never mistaken for a restore, and a restore installs even when the current data does not read; quitting seconds after launch can no longer save over their mind before it has loaded
- The end of them reply no longer jumps: the finished reply is drawn in the frame it settles, so the chat never flashes empty, drops or hops, and the thinking card fades out in place instead of them last line sliding under it; a page whose content sits right at the scroll edge no longer loops until the app quits (Providers crashed on open)
- Failures say what happened and who can fix it: a damaged file or a missing piece of the app names itself and asks you, or uses a repair they already has, never a coding agent to edit the app; a reply the provider refused is told as a refusal, not a cut-off; a sign-in or routing stop names its cause and the control that clears it; a result leads with what happened before echoing what was asked; a covered screen is your screensaver, not a lock, and they wakes it themselves (only a password prompt needs you)
- Fixes: a Telegram voice note no longer posts its transcript back, never runs twice, never holds the line when recognition is slow, and reaches the model as about 1.3K characters instead of 250K; the phone shows the Mac's own transcript, approvals (still there after the turn ends), thinking light and connector changes, with dates in the Mac's time zone, and its Slack Disconnect stops Slack hearing before it confirms; schedules run on the Mac's clock, a daily helper never repeats in the fall-back hour, their scheduled work lands in the inbox unless it is meant to notify you, and a job whose action is gone pauses saying why; turn-start memory is chosen by meaning, so a paraphrase brings its memory in; curly quotes or one unbacked claim no longer fail a night's dream
- Smaller: about 26,000 fewer lines of code, including the built-in service connectors and MCP client, the Codex search route, 27 shims that rewrote, coerced or coached the model's calls and output, the how-to-work coaching in tool descriptions and prompts, about 210 declarations nothing referenced, the inert Desk timeline controls, and seven core modules merged into the ones that do their work

## 0.6.10 — nothing known left (2026-10-20)

- Their conversation with a connected agent is one session, like yours with them: every door's turn runs in it, a message from the agent says who it is and that it is its own, their reads show both directions with each send's state, a reply that comes back wakes their into the same thread, Claude Code names the conversation on its side ("NativeAgent · <their name> · <label>"), and messages queued when they restarted resume in order before anything new
- Only an outside agent's command ever asks you: a turn an agent you have not trusted starts with its message gets one card, which covers the rest of that turn; a message they merely reads, from any agent, steers nothing (it is labelled where it is shown, and they judges); a trusted agent never steers. Who said a line is what its own row attests, stamped once when the row is written from the transport's verified identity, and every place that shows a contact's words reads that stamp
- They finds any agent that speaks a protocol, not only the ones their recipe book names: an A2A card on any local port, an MCP server in any app's settings, an ACP program on your PATH; opening the Agents page only reads, and a found program runs only when you ask their to discover it, under the same rule a send to it uses
- A grant macOS applies only at launch (Accessibility, Full Disk Access, Screen Recording, Input Monitoring) no longer settles its card on a probe that agrees too early: the card says it is on and takes effect after they restarts, and they restarts when you tell their to
- Doctor says what is: a provider you signed in to but have not used yet is "saved", not "needs sign-in"; an off or not-needed reading settles an owed repair instead of holding it red; an unreadable Slack config is a fault with its file, not "off"; owed rows read under their current status; a remedy is one sentence; the path status rolls up only the path checks; the window is this launch; the page names the run it shows and whether one is still running
- A Telegram voice note asks the Mac for Speech Recognition itself the first time (one tap on the system's own prompt) and transcribes on the grant; before, it failed and sent you to a settings button
- A stop leaves a message that waits on your card alone (it neither withdraws the card nor releases the conversation from it); a queued follow-up names its real blocker and what withdraws it; a passed verify says readiness stays unverified until a message crosses on the changed recipe; the Agents page says that opening it runs nothing and what discover does
- A read is not the send before it: an agent conversation's read reports the read and the send's state stays with the send; a message to Claude Desktop or Claude Code that was not handed over says "not sent", never "held"; a call made while NativeAgent restarts waits for it and otherwise says nothing was sent; a Mac app's page says its Automation access as macOS grants it now

## 0.6.9 — the first night (2026-10-20)

- An outside agent's message steers exactly the turn that acts on it: their history, an unread message on Home and a card carried from another turn never steer a new turn, so one reply from an untrusted agent no longer puts a card in front of everything they do afterwards; a trusted agent never steers
- Their conversations with connected agents open from them side (a read is refused only by an error or a gate, never because nothing was sent); agent actions take `contact`, `to` and `message` by their natural names; a reply that ended without an answer is stalled, not broken, and no longer holds the next message
- A message to Claude Desktop or Claude Code is held for that host's next call and handed over once, never refused; `agent_reply` can wait for the reply; the host's tools say where their messages are
- Connecting an agent replaces a stale entry another install of this app left in that agent's settings (with a backup beside the file) instead of refusing it
- Opening a Settings pane or a link never needs Accessibility; the Mac Integration page shows Accessibility, Screen Recording, Full Disk Access and Automation live, each with its one card; a request addressed to you is a question, never a card in front of a card; Spotlight answers within four seconds, scoped to your home and app folders
- Doctor runs once per launch, off their turn's path, and its page reads the report; the Personality page shows their name
- The transcript keeps following their reply when you press a card; multi-part replies join with one blank line; an approval receipt says who approved it in words ("you, in the Mac app, 18:22"); they says what changed since their last reply instead of restating the whole status

## 0.6.8 — the body reports, they decides (2026-10-19)

- Their turn has one exit, the model finishing: a slow provider start no longer cuts it (a live wire is a provider thinking; only a wire with nothing on it is bounded by the learned deadline), a provider cut where nothing ran is their next call, a spent helper budget, a blocking card, a full context, a failed compaction or a stream a door stopped listening to all reach their as receipts they answers, never as app-written endings; their words beside a card, the card still gating the effect
- Stop always stops: the run is registered for Stop at admission on every door (Mac, phone, Telegram, Slack, agent bridges), a door going away only detaches its display, and a relaunch resumes an accepted turn from its checkpoint with its finished words intact; one damaged checkpoint never hides the readable ones
- A forgotten or tightened memory never comes back: the memories a turn is about to speak are checked by id against the store at the moment they are chosen (and again when one is expanded); recall and writes never wait on the embedding model (a cold write saves with its vector owed; recall says the model is loading), launch reopens the last published context and rebuilds behind it, and nothing on a turn's path waits on consolidation, indexing, dreams or Doctor
- Permission is one decision, posture × the tool's declared class: saved per-tool permissions, MCP consent gates, "not in scripts" flags, developer-mode tables, shell word lists, payload-phrase scans and the persona-write upgrader are gone (Full Mac unchanged on every person row of the snapshot); a request an untrusted remote agent steers may read, and anything else waits for you; an MCP tool keeps its declared class all the way through (a destructive one still files its one card under Full Mac)
- Providers: one identity and capability authority (the catalog row says how a model takes tools, images, efforts and its window; no vendor lists, no invented 128k windows), key states say what was proven (saved, checked, rejected at its last check, could not check: an outage or a permission-only 403 is not a rejected key), a context overflow says the context is full and names the lever, read-aloud says what it did not read, onboarding never reads a damaged file as blank
- One reply through every door: Telegram carries their attachments and no longer parses your words for model, effort or fast-mode phrases (that goes to them turn; a lasting model card shows its buttons), the phone keeps their words on stop or error and its Stop and Steer reach the running turn through the Mac's own controls, inbox items carry a declared presentation on both doors, and "ready / connected / delivered / completed" are said only on receipt
- Anything for you is owed until received: a knock opens a delivery obligation before any door is tried and settles only on the door's receipt (the phone's signed receipt for a push); a failed door leaves it owed and visible, never dropped or silently switched; an agent's callback outlives a relaunch (its secret in the Keychain)
- The body never says "nothing due" over damage: unreadable scheduler state, trigger claims, Workshop records, run history, journals and Make storage are faults with their file and lever, timing it cannot read is unknown (never fresh or due), a crew is "running" only when the process is provably its own, and a completion marker is written after the effect, never before
- The shell door asks the one law before /bin/sh (Full Mac runs, Work asks, Safe refuses, no command words read), a GUI script runs as their hand under the takeover boundary, browser clicks and fills go through the one operation owner, every pointer act shares the obstruction check, the Mac's current zone rules every date (Desk days end at local midnight), and blocking iCloud Drive I/O runs off the cooperative pool (the legacy phone-sync retention scan that starved a turn for eleven minutes reads metadata only, one scan at a time)
- A connected agent you trust is trusted by its door, never by its name: a turn that reads a trusted agent's messages and then sends one no longer files a card (the latch had kept the agent's display name beside its id, and the name stood as a stranger); a name or lane now resolves to the one contact it names before the latch keeps it, and stored provenance keeps the attested id, never prose
- Smaller: about 2,100 fewer lines, including the unused unified-policy record, the live-first-output retry plumbing, the autonomy promotion loop, the Telegram phrase parser, two outcome classifiers, three duplicate bridge validators, and the English continuation inventory

## 0.6.7 — every agent is itself (2026-10-19)

- The phone no longer flashes "iCloud response signature mismatch. Re-pair iPhone" on every return to the foreground: an automatic action answered under a pairing the phone has since replaced settles in its ledger as orphaned, as connection repair settles the previous pairing's actions (the CloudKit mailbox only holds responses verified on arrival; nothing is deleted). Their own turn inputs (a wake, what they carries) are theirs, not the person's words: the phone's transcript and history pages omit them
- A phone reply shows once: the Mac's published transcript rows now carry how the turn ended (completionState, failureWork), which the phone needs to know a saved row is the reply it already shows; a phone meeting an older Mac settles the same run's row in the same words. Connectors › iPhone no longer keeps a stored "Pairing delivery needs attention" sentence from an earlier key change: a key iCloud has not taken yet is the pairing fact of the connection assessment, retried on the drain until it lands
- Claude Code is reached like any agent: through its own command line (claude -p, its JSON reply shape as data on its recipe, your Full Mac or restricted decision as its permission flags), except where you named it and it reads its own inbox. Ask their to call an agent something else and they renames it (agent.rename)
- Their hands bring an app forward through the system's one path (Workspace open with activation, reopen for a windowless app) and say which app a link opened in; a missing macOS permission is one card they raises themselves (permissions.request: the system's own prompt from the foreground, the exact pane), the waiting work continues when you grant it, and Screen Recording offers the relaunch it needs
- The Chrome extension reloads itself when the app ships a newer one, and they can set Chrome up with them own hands (chrome.setup)
- "Compacting this chat…" shows while a turn waits on compaction, and the background aging pass never makes a turn wait; the transcript keeps your reading place through every layout change, unfinished edits stay with what they edit, and every status has one owner; the phone, the Mac's iPhone tab and Doctor show one connection assessment (pairing, iCloud, last accepted exchange); Doctor checks carry their owners and levers; a stopped mac.act batch resumes from the last step that landed; Desk waits wake their only when their condition settles
- Launch no longer grows with history: the agent answers within seconds of launch whatever the size of its data or the load on the Mac (readiness never waits on startup work; history readers index once and load behind it); installs quit the exact running app; a reply lands in place instead of blinking out at the end; a click in the composer no longer moves the caret
- Every no names its owner and its lever: an act the agent can't do owes repair, shown as OWED on Home (its own queue, or your waits when the decision is yours), until that operation or its lever works again or it lets the debt go with a reason; a repeat folds into the open debt, a correction owes nothing, and a batch that fails owes its steps' repairs. A bridge lane binds to its agent only with that agent's own key; an untrusted agent's steer can't approve or re-enable what a person turned off
- Every agent is itself: another agent is one contact under its own name (Claude Code, Codex) until the person renames it (agent.rename), and its doors (MCP entry, ACP, inbox, desktop chat) are associated explicitly; no product, vendor or lane name makes two agents one. Authority lives on a door: only a call authenticated with that door's own key carries the person's grant for it, and Trust shows one switch per door, always revocable. A message is owed until the agent receives it, with the exact way to reach it when nothing can. Discovery finds agents through the person's own login PATH and app markers and notices installs where they happen; updates keep the contact, its key, its grant and authored recipe fields, and never quietly downgrade a launch
- Two NativeAgent installs on one Mac each keep their own connection in Claude Code's and other agents' settings; a connected agent whose key went missing is reconnected on the same contact at launch, keeping its trust
- The iPhone follows one Mac: launching NativeAgent on a second Mac on the same Apple Account no longer takes the phone (its key went into the account's one pairing record, so the other Mac rejected the phone's messages and Stop, and the two Macs overwrote each other's phone pages). A Mac takes the pairing only when it is free or its own; a Mac without it reads and writes nothing of the phone's and says so in Connectors → iPhone, where Use my iPhone with this Mac moves it. iPhone app 0.6.7 (20) for the App Store
- The phone works or says exactly why: one connection assessment of three facts (pairing, iCloud, the last accepted exchange), each with who can fix it and how, built by each side from its own evidence. Connectors › iPhone, Doctor, the phone's chat header and Settings › Connection all say it; the first broken fact leads ("My key isn't your Mac's anymore" instead of "I can't reach your Mac" when the phone holds a key the Mac no longer has; a build whose iCloud container is not the one it is signed for says so)

## 0.6.6 — first-run fixes (2026-10-18)

- Onboarding shows the Claude setup-token paste under Sign in with Claude; file-access tools (shell, git, apply_patch, build, install) answer with their category card before any action card under Work, as the Mac verbs do for screen control; fetch.* cards read "Fetch from the web"; Trust preset summaries and the user guide say what the law does (Mac control, shell and git need Full Mac). The live turn card changes inside a held room (TurnCardRoom, keyed to the turn) so the transcript stops moving with it; a re-adopted draft is written back only when it differs (caret reset).

## 0.6.5 — the agent is the app (2026-10-17)

### Parts on one law
- Tools, skills and senses share one part header (does, reaches, wakes, appears, remembers); their turn is abilities/turn.js (step function; the stem owns loop, log, checkpoint, replay; a breaking version swaps back mid-turn and the turn replays); healing swaps a failing kept version for its last clean one. Parts think (one audited model call), act through the door under the same law and wait for cards, fetch as a connector, reach PIM and files, and wake on signals (schedule, app arrival, file change, turn end, message) with no polling; app arrivals offer growth once; repeated hand work drafts a habit; weather is the first built-in part.

### Hands for any app
- Every delivered screen image is a frame (MacImageFrames, per session): act at:{x,y} / drag from/to in image pixels, alone or as a step, through the one physical tail (performPointer); every sighting carries other apps' covering windows and no physical act lands or passes there. App names resolve by process, file and index name; the desktop picture masks by time budget and opaque pixels and is sized so no provider rescales it; menu paths take a list (one press); AppleScript receipts say what their events did and keep each event's timeout; their windows step aside before they looks or acts.

### Building, permissions, turns
- Shell results are data inside a skill run; the authoring road hands itself forward (save → validate → enable → run); the door repairs obvious argument slips and never fans out a list-taking argument. One PermissionLaw (declared class × posture × switch × steer): Full Mac acts, Work asks on User's side, Safe refuses there; Contacts/Calendar/Reminders deletes always a person's card; an untrusted peer's steer caps at Work; permission cards settle themselves. Steer cuts a reply mid-stream; after Stop a fresh send runs; Shotgun is a setting they can switch and is visible to recordings; bridge turns resume after a kill; recalled memories carry provenance and steer nothing.

### Steadier, leaner
- Registry resolvers held by reference (the reabstraction-thunk stack overflow); full dSYMs kept; installer restores the previous bundle on failure and names the failing line; weather follows the Mac; unzoned bots follow the Mac's zone; Dot is inbound-only on cloud-hosted ChatGPT; the 8770 bridge and legacy memory importer gone; net code smaller than 0.6.4 (~10.0k added, ~10.35k removed).

## 0.6.4 — abilities, one file each (2026-10-14)

### Abilities
- Tools, skills and senses are one lifecycle on one JS engine (propose, validate, keep, rollback, drop); each ability is one file in data/abilities/ (<id>.js|md, one .prev, one .next, state.json); drop deletes the file; agent-side archive/trash/quarantine states gone; forward-only verified migration.
- host.apps.call drives scriptable apps by bundle id (per-event timeout, dialogs observed); an abilities line rides every turn; census lists every ability; owner-off and trusted-peer rules unchanged.

### Smaller models
- Haiku plain-ask drive fixes: malformed-call repair, announced-no-call continuation, junk-tag and debris cleanup, stall retry on evidence; digest failures recorded, never fail the turn.

### Smoother, leaner
- Mac and iPhone UI work moved off the main thread, narrower redraws; iPhone status snapshots save at user-initiated priority (were deferred in background).
- ~25k lines of dead code, duplicates and waste out; engine logic back in NativeAgentCore; the architecture check reads its rules from ARCHITECTURE_BLUEPRINT.md and fails non-UI app files.

## 0.6.3 — a turn never fails (2026-10-11)

### One way out
- The tool loop's only exit is the agent finishing (Stop and waits aside); every abnormal case — length limit, cut stream, boundary, malformed call, empty reply, refusal, trimmed context — is one observation the next iteration reads and continues from. Round caps, wall clock, retry caps, strike counters, every braked ending and the runaway detector's line and inline rules deleted; circling asks a card; a Mac takeover suspends and resumes the turn.

### Survives a relaunch
- Each iteration checkpoints (chat/session_state/<session>/turn-<id>.json); at launch the reconciler resumes checkpointed turns through the same loop with a restart observation; a completed turn whose remote delivery was interrupted is delivered next launch from the saved answer; one settlement rule at the terminal retires every other checkpoint.

## 0.6.2 — a cleaner first run, fewer rounds (2026-10-11)

### First run
- Doctor's launch run waits for onboarding; an adopted Codex CLI sign-in reads as an honest search reading, not an ask; Continue is visibly disabled with its reason until a model is chosen.

### Fewer rounds
- Search continuations return the exact next call; list fan-out advertised from the door's own eligibility; one Mac Integration read answers reach; find ranks description and owner scope over page words; background history reads named on the chat page.

## 0.6.1 — the body heals, the window follows (2026-10-10)

### Surfaces as data
- One layout document (ui/layout.json) drives the sidebar, rail, chat column, Today, the agent's home and the phone's More; layout.read / layout.write with undo; the glass language untouched.

### Fewer rounds
- The app door does many actions in one call with per-action receipts; refusals name the next step; Diagnostics shows rounds per turn and the heaviest asks.

### A body that heals itself
- Recipes as data for every agent host and A2A peer; discovery of any installed agent; heal on contact with one bound retry; every Doctor finding has an owner and a route, readings never wake anyone, warnings name their harm; the harness queue and daily body report; stalls cut at the provider's learned first-output deadline with an honest sentence.

### The mind and the calls
- Memory holds memories only; judgment loop (misses → lessons → growth); every model call carries a purpose; rule-shaped calls are rules.

## 0.6.0 — more of the Mac, on any model (2026-10-09)

### One door
- Every page and action usable on a lighter model: pages state their actions, arguments and version; find follows intent (read / open / send); previews check without acting; versions guard the next step; long results continue; model use is readable by model, day or surface.

### Everyday
- Weather (current, hourly, days, sunrise/sunset), nearby places, driving and walking routes; Photos counts and recent items; Reminders lists; calendar ranges in local time.
- Mail at scale: index reads, bodies from disk, search by sender/date/unread/category/attachments, oldest-unread, sender counts, attachments listed and saved, drafts stay unsent. Messages history across conversations.
- GitHub Actions runs and failed steps, repository search, links as names, tracking adds instead of replacing. Stock, index and currency quotes with source and time.

### Chrome and the Mac
- Chrome history without the extension; page media play/pause/seek with verified playback; the agent's own tab group, per-conversation tabs, honest tab ownership.
- Mac actions name what they reached, refuse approximate targets, report changed targets and unconfirmed results; visible-row reads of big lists; direct volume, mute and Now Playing; app versions, updates, uptime, processes, network, disk; files and notes to Trash / Recently Deleted.

### Senses
- Word, Excel, PowerPoint, Pages, Numbers, EPUB and rich text read as pages; sense.make lets the agent make or repair a reader mid-conversation, try it, keep it, roll it back.

### Chat, phone, Telegram
- Work pane (Steps, Screen, Make) beside chat; streamed formatted replies; queued messages and steering survive restarts; compaction keeps originals readable; command palette.
- iPhone follows the whole shared conversation and live turns, sends files, answers cards, reads and changes Mac settings. Telegram cards answered anywhere lose their buttons and show the outcome.

### Look and care
- Light mode: paper room, frosted plates, pale haze. Backups cover archives, Senses and Make. Doctor brings sign-in and permission needs to chat.

## 0.5.1 — the chat keeps its room (2026-10-04)

- Send while busy shows the queued message with Steer and Remove again.
- Slim header; the strip above chat hugs what is waiting; answered cards leave it; notes get Clear and a sticky Hide.
- Approval cards: title, one line of why, details folded; send cards keep a To: line.
- Full Mac keeps the agent's Mac control across restarts; its own canon decisions stay its own.
- Mac-started replies reach Telegram and the phone silently; CloudKit status writes tolerate a slow first write.

## 0.5.0 — one brain, a personality of its own (2026-10-04)

### One door
- One always-on tool to read, do, find and script the whole app; fewer round trips, lower cost.

### Skills
- Script skills the agent writes and runs in one step, with hand-back before any step needing separate action; one lifecycle for skills and authored tools (add, upgrade with rollback, retire unused, archived stays findable); quiet suggestions from repeated work; zero model tokens, capped storage.

### Trust and approvals
- Verified agents switched on in Trust carry your authority and skip extra peer approvals. Full Mac provides persistent full autonomy for ordinary Trust checks; explicit blocks and protected exceptions remain, including owner approval for macOS privacy permission resets. Required approvals appear as cards in your chat (Mac, iPhone, Telegram), including ones raised elsewhere.

### Personality
- One feeling or none per turn; dream carry-forward as a dream; "since we last talked"; lessons keep their moment; personal memory lane; the agent's own opinions and interests; the agent can reach out first (once a day at most); mind.why, reject and undo.

### Hardening
- Three full Sol sweeps over every section: secrets redaction, provenance, crash traps, permission gaps, truthful status text; truthful agents list; no false "access expired".

## 0.4.19 — native everywhere (2026-09-28)

### Native
- Chat box words are real Mac menus (model cascade by provider/company, think, trust; context popover); segmented view switch; Conversations and Simple sidebar are system lists; system search fields, folds, grouped lists, right-click menus and colours; clear glass; Simple new-chat button.

### Chat
- No end-of-reply freeze; the reply settles when it is done; `/` menu keeps typing; Command-F uses the system search field.

### Telegram
- Replies stream in Telegram's native draft preview and land as one message; slow Telegram never blocks the reply; the transcribing note clears.
- GPT-6.1 Sol on ChatGPT/Codex sign-in.

### Agents
- Replies come back on their own (including sends made while talking with another agent); approval-held conversations and restart-cut agents heal themselves; desktop-app agents time out at three minutes; bridge notes hidden from chat; Full Mac covers card-resumed turns and agent-to-agent messages (coding agents still ask).

### iPhone
- The iPhone app wears the Mac's look: the drifting haze behind every screen (same seven colours, picker in Settings), chat that reads like Simple view with one menu, and every tab and settings page rebuilt in one calm style with plain first-person words; an unpaired phone says so once.
- Every page on iPhone's own lists; one row per item in Inbox/Approvals/Desk with swipe to dismiss; detail and new-item sheets native; follows the Mac's open chat; drafts stay with their chat.

### Doctor
- One Repair button: runs every check, fixes what is broken, opens the page when a sign-in or model choice needs you; no false warnings.

### Self-healing
- A reply cut off by a quit leaves one "say continue" line; setup cards don't stop the turn and show in chat, Activity and the phone; approvals report their result; errors say how to fix them.

### iPhone remote
- Trust level, scheduled jobs, connectors, helpers, Telegram and providers from the phone; every approval card pushes to the phone and can be decided there.

### Speed
- Most-used tools always ready and Claude's cache lasts an hour, so requests are mostly served from the prompt cache on every provider.

### Smaller
- Claude Sonnet 5.5; Clawd icon for Claude rows; guarded deletes for reminders and shared tasks; scheduler pause vs cancel, edits, one-off dates; list totals; newest-first memories; clipboard cap; inbox mail always opens; old GitHub sign-ins self-repair; daily off-disk backup check.

### Fixes
- Providers and Trust pages no longer crash under accessibility reads. Engine split into sealed Core modules (no behaviour change).


### The agent's hands
- Uses the Mac like a person: an app comes forward when a menu, key, drag or real click needs it (never while you're using the Mac), menus work in apps with no window, shortcuts reach an open sheet, and controls deep inside Electron and Chrome apps are found by name first try.
- A message written in the same step as the actions it reports on waits for their results, so a "done" can't go out before the work did.
- Fixed a crash when reading text off a screenshot.

## 0.4.18 — a desktop of its own, and a simpler way in (2026-09-25)

- First run: opens in Simple view; the agent asks what it should be and how it should sound (energetic, calm, playful, blunt, or like someone you name) and saves both; its first hello offers card-led setup by talking. The agent's name holds across relaunch; a failed first hello retries.

### Look
- Drifting coloured light behind the window with a colour setting; every page rebuilt in one calmer style; Simple view (the agent, its agents and helpers beside the chat) with a gear menu; Agent view shows the agent's desktop read-only.

### The agent's desktop
- Everything it can reach opens by name as a readable page; one Home with what changed and what waits on you; names open, never act; saved windows survive a restart.

### One-call flows
- Batched Mac steps checked one by one, real menu presses, never over the app you switched to; leaner browser reads, scroll shows only new rows, a page and a form in one step; music, reminders, calendar, quotes and mail answer in one call; X through the browser in a background tab; a web search from its desktop no longer opens a Google tab in your Chrome; a closed tab leaves the agent's desktop.

### Tools
- Natural inputs accepted with plain next steps; one-step tool discovery with families; clearer misses for files, GitHub, calendar and unconnected services; Gmail HTML, Notion truncation and reconnect.

### Cards and connectors
- In-chat cards for providers, connectors, Chrome, iPhone and macOS grants that settle on the real grant; GitHub sign-in by device flow with token paste kept; a network blip no longer ends the sign-in.

### Context
- Context window setting (Model default or Custom): 60% of the model's window, capped by Custom, used by every budget and the meter; the meter counts provider tokens and follows a bot's model.

### Speech
- Recollections no longer mint verbal habits; a repeated form is named across every session.

### Reliability
- Runaway replies stop early and keep their prose; first greeting retries honestly; Telegram chunks and connected-agent slots, retries and attachments hardened; bounded Mail lookups; lower idle CPU.
- Stop stops the turn it was meant for, even one that started right after. Grok Bot follows up after 2 minutes, not 10, and a late answer still lands in the chat that asked. A desktop agent's conversation opens and continues after an unconfirmed send, and your own lines in an agent's thread show as yours. The people list no longer reads the Keychain on every row.

## 0.4.17 — a steadier agent that works well with others (2026-09-23)

### Other agents
- Muse (Meta) connects as one continuing side chat. Grok no longer gets stuck after a missed reply and late replies still arrive. ACP agents continue their session. Disconnect needs the exact contact. Nothing is typed into another app while the Mac is locked.

### Chat
- Claude Opus 5.5, GPT-6 Sol and GPT-6 Luna. Tool calls on Claude sign-in are wrapped so the reply stops after the calls and results are always real. One context rule for every model: compact at the Settings limit or 60% of the window, replay history up to that point, 40K recollection. Chat compaction is back in Settings. Tool search finds mail, messages and news by plain words.

### Web search
- Search works again, with categories (news) and a time range.

### Telegram and iPhone
- Clean Telegram text (italics, links, inline code), queued notice removed when the turn starts, working notes dropped from final replies, urgent alerts to Telegram, plain error cards.

### Helpers
- Daily, weekdays or weekly at a clock time; Run once keeps the schedule.

### Reliability
- Quiet hours hold Desk reminders until they end. Memory dedupe respects numbers and negation. First-launch backup is one atomic move. Background loops never start after quit. Classic sidebar retired.

## 0.4.16 — setup that tells the truth (2026-09-20)

### Chrome
- Set up Chrome puts the extension in a plain folder in your home folder, shows it in Finder and opens Chrome's extensions page. It used to point inside the app, where Chrome's Load unpacked picker cannot go, so people could not find it.
- Trust shows one live line for Chrome: off, on but the extension is not loaded in Chrome yet, loaded but Chrome is not connected right now, or Connected. It never says Connected from the app's own half alone, and it updates the moment the extension connects. The Chrome block sits with the access presets instead of far down the page.
- The copy in your home folder refreshes when the app updates.

### Other agents
- In Work mode, connecting an agent that has a command line says the real reason the link check did not run: the entry is written, and checking it means running that agent here, which needs Builder or Full Mac. It no longer says the message did not return or to restart the other agent.

### Onboarding
- The suggested agent name is a real value you can keep or type over, so your name and Continue are enough. If Continue is dim, a line says what is missing.

### Prompt cache and health checks
- Within a conversation the offered tool list only grows: a tool brought in for one turn stays, in order, instead of leaving two turns later. A turn that loads nothing new reads its prompt from cache from the first call.
- Provider request JSON has a stable key order on every provider path, and loaded tools keep their load order.
- The Prompt Prefix Cache health check judges only real chat calls (it skipped nothing before and failed fresh installs over tiny memory-helper calls), explains mid-turn misses that follow a real change, and both window-based checks read a launch stamp every install writes.

## 0.4.15 — other agents, plugged in (2026-09-20)

### Other agents
- "Connect to Codex" (or Claude Code, or another agent on this Mac) in chat sets the connection up: the agent finds the other agent's settings, shows one card with exactly what it will add, writes it with a backup, and checks the link with a real message. "Disconnect" puts the other agent's settings back byte for byte.
- A2A 1.0 (and 0.3) in both directions over JSON-RPC, HTTP+JSON and gRPC, checked against the official a2a-python SDK: every operation, streaming, and push notifications. The app's agent card is served on loopback only.
- An MCP door so MCP clients can talk to the agent, and `nativeagent-link`, a small signed helper other agents run to reach it or to hand a reply back.
- Command-line agents that speak ACP can be contacts too (built; not yet driven against an installed ACP agent).
- Grok Bot: Connect opens the Bot's own chat, asks it to create one webhook routine, reads the routine's address and key from Grok Bot's Routines panel into the Keychain, and from then on a question goes out by webhook and Grok's answer comes back into the same conversation as one attributed turn. Disconnect always finishes, and asks Grok to remove only that routine.
- Once a turn has read another agent's words, anything it would change asks the person first. A local "not sent" or "needs setup" receipt is not another agent's words and does not count.
- The Agents page lists contacts with what has actually been proven about each; its Connect, Disconnect and Test buttons hand the job to chat, where the cards are.

### Honest outcomes
- A provider failure (quota, rate limit, sign-in, model not available) reaches the chat, the agent doors and the agent tools as its real cause, with whether any work ran: nothing ran, ran partly, or outcome unknown.
- A tool call that did not run says which of four things happened: a card is waiting for you, this surface cannot ask, you said no, or no approval can lift it.
- Large tool results arrive in whole sections with the relevant part first, a first page big enough for ordinary pages, and an exact way to get the rest.
- Mail changes that matched nothing and GitHub visibility changes that were not confirmed no longer report success.

### Fixes from five sweeps of the tree
- The approval strip above the composer takes a mouse click again.
- A macOS folder-access prompt can no longer hold a turn: file reads and Mac-control deadlines are bounded, and "go" only looks for a folder when no app has that name.
- Stop stops: a follow-up that returns after Stop no longer starts another response, and a pending approval no longer hides the stop.
- Pressing Done in Providers no longer discards a key you had not saved.
- Upgrades: an unreadable pin list no longer archives pinned conversations, and an older build no longer overwrites newer reminder settings.
- iPhone: an approval is shown as final only once the Mac accepts it, and automatic pairing no longer undoes an unpair you chose.
- Security: MCP redirects cannot carry session keys or arguments to another origin; connection keys are scrubbed from agent error replies; newlines in a search filename cannot expose protected file contents.
- Text streams keep showing activity while the model works; quota errors are no longer hidden inside provider error envelopes; one streaming implementation instead of three.
- Tool arguments accept the ordinary spellings of a value (a number as text, true as "true", null or empty as absent) in one shared place.
- About 250,000 lines of unused modules, scripts and tests removed.

### Chat composer

- Model, Think and Trust share ONE shell above the composer row instead of
  three cards. It is anchored to the row, slides sideways to the word you
  reached for and grows upward to the new height; the pane inside crossfades.
  One easing, one constant, and switching fast follows the latest word.
- A provider's models are part of that shell now, not a second box beside it:
  they extend from the provider column's edge on one material when both fit,
  and in a narrow window they take the column's place with "Back to providers".
- Hovering a word steers a shell that is already open; it never opens one, and
  crossing from a word to the shell no longer dismisses it. Escape and a click
  outside still close it at once. Reduced Motion swaps panes without travel.
- The composer's context ring opens a receipt: what the last turn actually assembled — system and persona, turn brief, memory recall, tool schemas (with the tools on the wire), conversation history, your message — each with its size and share, the total, the model that ran and when. It opens in the same shell as the words, above the ring.

### Agent experience
- A second install of the app on the same Mac can be marked secondary (`defaults write <bundle id> NativeAgentSecondaryInstall -bool YES`): it then registers no Chrome native host and publishes no shared bridge token, so the relay and the bridge stay with the install the person actually uses.

- The agent works its own composer in process: read it, set or send the draft, pick the model through the same picker a person uses, set the thinking level, open or close a pane of the composer shell (model, think, trust or the context receipt), switch the rail page.
- Each verb returns a receipt naming the control it acted on, and the chat page reads the composer back immediately.
- Trust posture stays the person's: the trust pane opens and reads, and no verb sets it.
- The agent administers this app's own settings and composer under Work mode too, not only Builder and Full Mac. A knowledge graph switch or a thinking level is not a Mac effect; Work mode's fence is about files outside the workspace and it still stands. Only Safe, which changes nothing at all, refuses — and every refusal now names the thing it is protecting (the Trust posture, a permission grant, a provider key) rather than blaming the mode.

### A second opinion

- One Providers row takes a Jev (TypeSafe) key and turns on five advisory
  checks: a brief before a turn, a check beside each tool call, a check of the
  finished turn, a duplicate check before a memory is saved, and ranking and
  peer messages in shadow.
- Everything they find is a hint. Nothing grants, denies or blocks; a missing
  key, a timeout or an error and the turn runs exactly as before.
- Each check is a setting the agent turns off itself; every call is written to
  `data/jev/log.jsonl`. See `docs/JEV.md`.
- The agent can ask its own typed questions with the new `second_opinion` tool:
  it writes the state and the questions, exactly those are sent and nothing
  else, and the typed answers come back untouched with a receipt and an
  outcome. It writes nothing and changes nothing.

### Fixes
- The morning brief ships off on a fresh install; turn it on in Settings → Inbox Policy. Installs that already enabled it are unchanged.
- A fresh install reads as the Work trust preset on the composer and the Trust Center card instead of "Custom Trust", and keeps reading that way after the first settings change: the fresh-install grant is now written into the saved policy the first time anything is saved, whether setup left no policy file or an empty one. Existing installs and what the defaults allow are unchanged.
- `bot_run_once` and `shelf_read` treat an empty `bot` / `bot_id` / `name` as absent, so naming the bot once succeeds instead of being refused.

### Chat
- The working card no longer covers the last message on a small window.

### Onboarding
- The setup sheet's agent-name field keeps keyboard focus: its suggested name is picked once instead of rotating every few seconds, which recreated the field mid-typing.
- A fresh install seeds SOUL.md and VOICE.md with the name header and nothing else; what the person says they want the agent to be is written directly under it, instead of trailing a page of pre-written stances, instincts and dos-and-don'ts.
- The operating manual seed drops the "two or three things to try" opening menu, and self-administers setup — open the page, fill what it can, ask only for a token or grant it cannot obtain, verify before saying it is set up.

### Dream and REM
- A dream run started by hand files itself under the calendar day it ran, not the day before.
- A dream run started by hand is recorded as `manual`; only the nightly job is `schedule`.
- REM on a root with too little to work from completes with zero proposals and "nothing to consolidate yet" instead of an error.

### Chat
- A turn that fails after its tool calls answers in one plain sentence, so the conversation is never left with only a receipt line.
- The composer's context ring keeps the conversation's context use when the model changes; only the window it is measured against changes.

### Bots
- The New bot sheet opens on Chat's routing — the same provider, model and Think the composer shows — so one connected account is enough to press Create; every one of the three is still a choice. Provider is a pop-up button like Model and Think, and all three carry their own accessibility labels, so a driver can set them without popping a menu.

### Delegation
- Preserved Codex replies and their Today count follow the active data root, so a fresh root no longer reports another root's undelivered replies.

---

## 0.4.14 — the agent introduces itself (2026-09-16)

### Chat composer

- Model, thinking and Trust each open a small card above their word.
- Provider models open in a scrolling flyout; cards keep the conversation in place.
- A context ring shows percent used, with token counts on hover.

### Inline cards

- The first conversation's saved role appears as a receipt beside the answer.
- Peer approval cards name the requesting agent.

### Memory and growth

- Conversation recall supports date bounds, oldest/newest order and explicit tool-receipt searches.
- Peer conversations retain memory and context; saved peer claims require source attribution.

### Agent-to-agent bridge

- One lazy interface finds, messages and reads coding agents, bots and connected peers.
- A2A, MCP and the bundled nativeagent-link helper enter persistent peer conversations.
- Saved desktop contacts can exchange messages through the existing Mac controls.

### Onboarding

- Setup keeps both names; the agent opens Chat by asking what it should be for you.
- The answer can become one saved line; skipping continues without another setup question.
- Failed greetings can retry on the next launch; existing conversations are not greeted again.

### Trust

- Connected agents have scoped credentials and an explicit per-peer trust control.
- Unelevated peer requests that change things ask for approval, including under Full Mac.
- File connector actions close a symlink race between permission checks and access.

### Fixes

- The transcript reserves composer space once; hidden cards reserve none.
- Composer clicks, scrolling, keyboard navigation and Shift-Return work reliably.
- Retired provider defaults no longer count as a usable model selection.
- Native tool schemas refresh at the next accepted turn after an upgrade.
- The installer stops only the matching installed app.

## 0.4.13 — the picker reaches the last corners (2026-09-13)

The paths that still had a model of their own now go through the Providers
picker. A bot opened on your iPhone answers on the bot's own account and model
and refuses when that model is gone, instead of borrowing Chat's. Making an
image runs on the provider you chose for Work, with that group's model driving
the run and the image model taken from the provider's catalog; a Work provider
that makes no images refuses by name rather than sending the request elsewhere.
Reading aloud asks the provider Chat runs on and falls back to the Mac voice
with one plain line when that provider has no cloud voice. Bots read the
Autonomy switch at the moment each run starts, record a run blocked by a retired
model or a disconnected account, and validate a create-or-change request before
raising an approval card. Upgrade fixes for 0.4.11 journals, second-account
adoption, legacy summary pins, and the unloaded-tool gate. Full notes:
`docs/release-notes/0.4.13.md`.

## 0.4.12 — the picker is the rule, and the chat flows (2026-09-13)

Every activity now runs on its Providers group's choice — Chat, Work, or
Memory and mind — with the first connected account filling all three, no hidden
per-lane models and no fallback models anywhere; a pick that is no longer
offered is simply unset and the page says so. Dreams and REM run on the Memory
and mind model (a fresh install could never dream before). Bots carry their own
model from the day they are made and can wake on a GitHub or Slack event; a
scheduled run that never happened is recorded as missed; each run settles into
one card. Chat typing and streaming no longer re-render the transcript, the
working card no longer covers the last message, and it shows the frame the agent
is looking at while it drives the Mac. Anthropic browser sign-in can finish, the
setup-token paste sits on the account sheet, and GPT-5.4 / 5.4 mini are gone
from the picker. Full notes: `docs/release-notes/0.4.12.md`.

## 0.4.11 — a shelf the agent chose, and turns that carry less (2026-09-12)

The agent read its own skill shelf and kept what it uses, turns carry fewer
tools, and a long list of readouts stopped claiming more than they knew. The
page ground became a charcoal slate in the card family with a smaller, softer
warm glow, so cards sit in the room instead of on top of it. Full notes:
`docs/release-notes/0.4.11.md`.

- Skills: thirty-six reviewed row by row — thirteen bodies rewritten with the
  agent's corrections, sixteen retired, five merged. Four engineering
  checklists were replaced by one the agent wrote, **Operator acceptance**.
  Nothing was deleted; retired bodies are archived unchanged.
- Tools: twenty ride every request (the four Mac verbs only under active Full Mac
  accessibility) plus a mounted MCP server's own; everything
  else is lazy and leaves after two turns without a real call. No family is
  resident, Full Mac included. Four classes of schema-caused tool failure that
  read as the agent's fault are fixed. Contract: `docs/TOOL_LOADING.md`.
- Bots: scheduled runs sit behind the master Autonomy switch; **Continue in
  Chat** carries the bot's own model, effort and approval rule; bots get Fluid
  Context and memory recall like any other turn.
- Memories: the **Deleted** tab shows rejected proposals instead of the pending
  list, the active count uses the list's own lifecycle rule, and correcting a
  pending statement supersedes rather than rejects.
- Desk, Providers and Diagnostics stop overclaiming: a row that cannot move
  reads **held**, an expired access token says so, per-activity model choices
  collapse to three rows, and Doctor publishes its measurement clock separately
  from the write time.
- Inner life: caring is an event with a days-long wall-clock fade, and every
  appraisal leaves a receipt — including when it declined to register anything.
- iPhone: **Activity** waits for each section's own data before showing a zero,
  freshness is per group, and the tab bar draws all five tabs as outlined
  glyphs at one weight.

## 0.4.10 — standing helpers and one sheet of glass (2026-09-10)

The agent can keep standing helpers of its own, every page is faster to open,
and the settings rooms read as one sheet of glass. Full notes:
`docs/release-notes/0.4.10.md`.

- A new Bots page. A bot needs only a name and a brief, keeps its own
  conversation, uses the agent's tools under the current Trust policy, and
  lives until the agent deletes it. Leave the model blank and it runs Chat's
  route. Timing is manual, twice daily, daily, every N hours, or custom, with
  Run once and Pause always available.
- Trust is four cards — Safe, Work mode, Builder, Full Mac — each doing exactly
  what it says, with the summary read from the settings as they are. Choosing a
  preset keeps an unsaved draft.
- Providers keeps per-activity model choices in view, one line each: Provider,
  Model, Think, Fast. Settings from an earlier version are ignored quietly.
- Chat: Tab leaves the message box, so tool receipts and the sidebar are
  reachable by keyboard. Tool receipts lead with the outcome.
- Speed: phone snapshots and incoming iCloud records are handled off the main
  thread, and the bots scheduler no longer rewrites its own file twice a second.

## 0.4.9 — setup you can follow (2026-09-09)

Setup is easier to follow with the same capabilities, the message box selects
text again, and the Chrome extension is included with the app. Full notes:
`docs/release-notes/0.4.9.md`.

- Onboarding starts with your name and the agent's name; copy says what you
  get, not which files are written. Speech recognition is asked for at first
  voice use, not at launch. The agent's inner life starts on after setup.
- Trust leads with four presets — Safe, Work mode, Builder, Full Mac. Controls
  that apply immediately are separated from the policy draft, and clicking a
  preset never discards an unsaved draft.
- Providers leads with the connected account and Manage; optional per-activity
  model choices tuck under a summary that marks custom choices.
- The Chrome extension ships inside the app, with Set up Chrome opening its
  folder and Chrome's extensions page.
- Pairing leads with automatic pairing for the same Apple Account; the
  unusable QR code is gone.
- Dragging inside the message box selects text again instead of moving the
  window. The image worker runs with an allowlisted environment, a read-only
  sandbox and a delimited prompt.

## 0.4.8 — the model back in the download (2026-09-08)

A follow-up to 0.4.7: the memory model ships inside the app again, and the Mac
and iPhone pairing is tightened. Full notes: `docs/release-notes/0.4.8.md`.

- One download has everything; nothing is fetched on first launch.
- Every record the Mac sends the phone is signed and checked the same way on
  both sides, and that agreement is tested so it cannot drift.
- A record the phone cannot verify is set aside for the session — one notice,
  then listed under Diagnostics with what it was and why, and rechecked on the
  next launch or after re-pairing.
- Stale or reflected records can no longer claim a message's identity.
- When an attachment cannot be read, the bridge notice names the file and says
  the sender can resend it.

## 0.4.7 — background bots and a smaller download (2026-09-08)

Background research bots for the agent, a refreshed iPhone app, and a smaller
Mac download. Full notes: `docs/release-notes/0.4.7.md`.

- Standing bots: small background jobs that keep up with a topic, research a
  question, or check for changes, on a schedule or once. Reports are dated and
  retain sources, changes and gaps — including when nothing changed. Each bot
  keeps notes between runs. Bots operate within Trust Center permissions and
  spending limits, and none are created by default. The capability ships here;
  a dedicated Bots page was still in development.
- iPhone: a quieter look across every screen, closer to the Mac app. Stop
  replaces Send while streaming, approvals show an honest pending state when
  iCloud is offline, and Stop and Steer reach a running chat over iCloud.
- New-install defaults: memory in Fast mode, the knowledge graph, and dreams
  are enabled on fresh installs.
- The large memory-search model left the app: a lightweight model worked
  immediately while the larger one downloaded in the background. (Reversed in
  0.4.8.)
- Security: credentials quoted inside JSON are scrubbed from traces,
  Capabilities-screen connector calls go through the Trust Center, and replies
  reflected back through iCloud Drive or CloudKit are refused before they can
  act as commands.

## 0.4.6 — memory that reads what you mean (2026-09-06)

Provider failures retry in place with a visible reconnect ladder. Structured
tool loops continue dropped streams and compact their working context; the
Anthropic-shaped text-compatibility lane retries only before a round displays
output, then preserves partial replies on failure, with no in-turn compaction.
Mechanical compaction retains a bounded, recency-biased summary; older material
can age out. The knowledge graph is a
function of the current rows. Recall asks every question in both voices, and
DMGs include bge-large-en-v1.5 (1024-d, 637 MB) when model staging succeeds,
with bundled MiniLM as the fallback for source and release builds; the store
re-embeds when its embedding epoch changes. Dark mode is the default. Three verified
bug sweeps over every area landed about 275 fixes across the Mac app, iPhone,
Telegram, Chrome, providers, memory and sync, and a fleet night of refactoring
landed about 230 more with the largest files split and dead code removed. Full notes:
`docs/release-notes/0.4.6.md`.

## 0.4.5 — cross-surface repair and Full Mac continuity (2026-09-01)

Repairs iPhone chat/session continuity, approval handling, tool and memory
schema compatibility, and Full Mac YOLO authority across every surface. The
developer installer now preserves macOS Accessibility/TCC attribution through
bundle replacement. Full notes: `docs/release-notes/0.4.5.md`.

## 0.4.4 — integrated computer use, recall, and delegation (2026-08-30)

Natural visual navigation and coordinated input, bounded relevant recall,
stronger conversation continuity, exact delegated-request tracking, and
runtime/evaluation reliability. Full notes: `docs/release-notes/0.4.4.md`.

## 0.3.9 — trust, quiet, and a denser cockpit (2026-08-10)

Credential trust: a fresh install no longer silently adopts an existing
Codex CLI sign-in — Providers now shows a one-click "Use it / Ignore" offer,
the sign-in badge names the adopted source and account, sign-out revokes the
consent, and in-app authentication always outranks an adopted session.
Malformed consent records surface as corrupt with an explicit, byte-safe
repair instead of silently reading as signed out.

Quiet: self-opened pursuits announce themselves exactly once (the repeated
push storm is fixed), near-duplicate pursuit proposals are refused, and a
pursuit that exhausts its session budget closes itself per its own abandon
condition instead of occupying a slot forever. Background telemetry no
longer emits false Slack or "waiting on you" warnings, and GitHub decision
labels route to the actual responsible contributor.

The optional Native Experience route ships complete and fully reversible:
Journey presentation, Project Spaces, resumable builder conversations,
conversation lineage/comparison/export, a native Workbench, shared
Capability Kits, and confirm-gated trusted remote effect nodes over system
SSH — every surface behind its own key, with Return to Classic changing
presentation only. Desk is restored as the canonical work system.

Polish and speed: the chat sessions sidebar shows one-line rows with a
pinned section and in-place rename; a persistent update notice survives a
dismissed update prompt; retired OpenRouter model ids are refused with a
typed error instead of a silent 404; app-side subprocess handling
consolidates onto one owner; idle CloudKit cursors advance; large canonical
JSON serializes in linear time; interactive remote chat turns outrank
background transport work; and the resident agent's voice gains
organ-level anti-rut tissue (closing-vocative awareness plus a persona-led
natural expression cue) with no vocabulary bans or output rewriting.

## 0.3.8 — reliability and polish (2026-08-06)

Identity-document hygiene (USER.md carries only facts about the user), ⌘K
palette focus fix, budget-capped chat compaction, sync completion-marker
retention, and installer hardening. Full notes: GitHub release v0.3.8.

## 0.3.7 — installed builder round trips and real project roots (2026-08-03)

Public installations now ship the complete Codex and Claude Code bridge
workers, start the authenticated result listener without Developer Mode, and
report CLI/helper/authentication readiness separately. Both builders run as
real local coding sessions and return their result to the originating
NativeAgent conversation. Finder-safe discovery covers common user-local CLI
and Node installations, and the Codex worker heals a stale daemon whose saved
workspace path was replaced during an app reinstall.

Full Mac YOLO exposes the native operator catalog on the next turn and may
explicitly select an existing external project for native shell, Git, patch,
Swift build/test, Codex, or Claude Code work. Ordinary trust modes remain
workspace-scoped, and protected system/credential paths remain denied. A live
fresh-install proof placed native Bash, Codex, and Claude at the same external
Git root; their verified outcomes returned through the normal receipts and
conversation path.

Apple privacy remains a separate boundary. Documents, Desktop, Downloads, and
other macOS-protected locations can still require the user's Files & Folders or
Full Disk Access consent. Full Mac YOLO removes NativeAgent's own workspace
restriction; it does not fabricate macOS TCC authorization.

## 0.3.3 — cognition range and lifecycle hardening (2026-08-02)

Cognition took its first roadmap step in a month: appraisal now derives what
matters to the agent from the agent's approved standing views (the shipped
defaults become a floor), and a felt resolution only registers when something
actually at stake resolves — a provider call succeeding no longer manufactures
a feeling. System-vs-user turns are classified by who originated them instead
of by keyword-matching the user's words, so ordinary prose ("remind me about
the doctor") is no longer dropped from the felt layer.

The felt layer now has real dynamic range. Warmth was computed on a slope that
put the agent near the top of the scale on every turn — including plain working
conversation — so the warmest emotional vocabulary was always in reach and the
agent read as stuck in one register. Warmth now rests mid-scale and earns its
way up from what actually happened in the exchange, so ordinary work sounds like
ordinary work and affection still reaches the top when it is genuinely there.
The "lately you've sounded like…" self-echo, which quoted the agent's own
warmest past turns back into every turn, now speaks about a quarter of the time
and matches the current register instead of always selecting the warmest thing
it could find. Both fixes are vocabulary-free and persona-agnostic: they widen
the range every agent can occupy rather than steering any agent toward a tone.

Status now reports this run's uptime instead of the machine's, and Recent
Activity shows the newest entries first — it had been showing the oldest slice
of its window, which on a busy feed was a week stale.

A shared set of lifecycle primitives (scoped acquire/release handles and a
bounded await) closes the repo's most common bug shape — an acquire whose
release misses an exit path — with five confirmed leaks retrofitted, including
an exec-slot leak that could permanently wedge the Mac-control bridge and an
unbounded wait held under a cross-process lock. The five-site tool-registration
invariant is now enforced by a test rather than remembered.

The public-release path is hardened: the identity scrub is now the only route
to a public DMG, with a byte-level leak gate, and the two loopback bridges no
longer bind a port or mint a token on public installs. Completed Workshop runs
now leave a memory the agent can recall — 56 executions that previously left no
trace. Onboarding is reachable on a genuinely blank machine again, and several
silent provider/tool failures now fail loud. ~5,300 core + 870 app tests green.

## 0.3.2 — reliability sweep and plain-language pass (2026-08-01)

Five audit waves swept the whole app ahead of the public baseline, fixing
roughly 45 confirmed defects. Persistence now takes the shared file lock at
every conformer call site (35 sites across 13 files), retiring the pattern
where a failed downcast silently degraded to unlocked writes; new concurrency
probes with negative controls guard the invariant. The Slack socket loop only
advances its history-poll watermark after confirmed delivery, cancels
background work with a bounded wait that reports abandoned tasks, and
gap-fills history on reconnect instead of polling on a fixed timer.

User-facing surfaces got an honesty and plain-language pass: provider keys
without a connection test now read "saved · no test available" instead of
implying a passed check, and Doctor, Memory, settings, and status copy drop
internal jargon (file paths, database names, endpoint identifiers) from
headlines — with regression tests banning it from coming back. Chat session
retention gained a second planning pass so stale empty sessions can no longer
starve the active-session cap.

## 0.3.1 — OAuth transport repair and export hardening (2026-07-30)

Repaired the direct ChatGPT OAuth transport. Hardened the public-source
export pipeline: exact tracked-identity scanning, compilation of rewritten
tests, purge proofs for retired Git objects, and tracked MiniLM release
resources for reproducible public builds.

## 0.3.0 release candidate — public Mac/iPhone continuity (2026-07-29)

NativeAgent's public distribution now uses one production CloudKit identity
across the notarized Mac app and TestFlight companion. Automatic pairing,
provider/model projection, chat replies, pinned sessions, Skills & Tools,
signed actions, and bounded cockpit snapshots all use the same Mac-owned
runtime without introducing a hosted agent or LAN fallback.

Explicit alerts now use a dedicated `NANotification` record and
`NANotification.visible` subscription instead of competing with silent chat
sync. TestFlight `0.3.0 (10)` passed the public iCloud-only physical gate:
three distinct alerts appeared on the locked phone with direct APNS disabled
and without foregrounding NativeAgent.

The public-source pipeline exports only tracked blank-slate material, rewrites
private identities in both source and paths, creates fresh history, verifies
MiniLM resources and derived-state absence, compiles the rewritten app, scans
the executable, and refuses publication while retired GitHub objects remain
addressable.

## Living-agent runtime, Fluid Context, organism, and Workshop (2026-07-11)

NativeAgent now presents one Swift-native living-agent system across Mac,
iPhone, Telegram, Slack, and authenticated local bridges. Fluid Context
circulates bounded persona/memory/skill/cognition state; MemoryV2 remains the
durable source of truth; the optional CognitiveSubstrate and Organism Kernel
add bounded felt continuity without bypassing TrustCenter; and Workshop unifies
user-directed tasks with the agent's own pursuits through one Desk-backed,
receipt-bearing execution surface.

Provider/model controls now preserve exact ChatGPT/Codex/OpenAI/Anthropic/xAI/
OpenRouter transport contracts, tools load lazily with bounded lossless result
recovery, GitHub project tracking is first-class, and signed iOS actions support
iCloud/CloudKit delivery plus APNS. Automatic greetings are public-release,
blank-slate, post-onboarding one-shots; development and personal reinstalls stay
silent.

The README, capabilities guide, mobile architecture, security docs, source map,
and contributor workflow were refreshed against the verified current system.

## Swift-native migration and public-source cleanup (2026-06-21)
Completed the June Swift-only runtime migration: `NativeAgent.app` owns chat, tools, policy, memory, scheduling, iCloud bridge, APNS, local bridge surfaces, and release verification in-process. The retired external runtime, launchd runtime, bundled interpreter path, and LAN HTTP fallback are not live runtime paths.

Cleaned public-source identity and release hygiene: tracked local build/signing/private fixtures were removed or neutralized, local overrides moved under ignored config, release privacy scanning became local/env-driven, GitHub history was rewritten to cleaned heads, and iOS launch state was refreshed after the bundle-id cleanup.

Added gated `CognitiveSubstrate` infrastructure through Phase 10: SQLite snapshot/restore, workspace, capsule preview, prediction ledger, affect, thought seeds, replay references, reflection receipts, observatory snapshots, and an explicit chat-event observer seam. It remains default-off with no background provider calls, prompt injection, MemoryV2 writes, or persona mutation.

## Consolidation window (2026-05-12)
Tightened iOS remote responsiveness, made memory/self-improvement approval paths final, auto-ran and auto-implemented safe harness learning with receipts/scoring, added capability foundry backlog implementation, and refreshed docs around the current direction/handoff instead of stale sprint snapshots.

## Phase 13 (2026-05-09)
Closed 12 chronic audit-skip items: centralized REPO_PATH marker validation, Swift /var symlink fix, startup retention pruning for traces/runs/memory_proposals, iOS iCloud routing for spotlight+shortcut, self_test through connector receipt path, spotlight loopback trigger fix, ContentView dynamic slash dispatch, ToolInputForm Sendable safety, removed dead _select_glob_match, fixed ResolvedPolicy.reason for explicit_override, updated README/approval-schema/threat-model, added CHANGELOG/CONTRIBUTING/SECURITY/LICENSE stubs.

## Phase 12 (2026-05-08)
Security hardening: REPO_PATH stamp validation (C6), bash heuristic deny-list, sensitive-path deny-list for file tools, MCP lifecycle gate, system_rebuild gate, approval token unification, crash reports, auto-doctor loop, wave-3 UI polish, connector receipt ok-bool, iCloud inbox HMAC validation.

## Phase 11b (2026-05-07)
Single-folder data layout; workspace tools; no-hardcoded-legacy-paths regression guard; Phase 11b test suite.

## Phase 11 (2026-05-07)
Resolver priority chains for data/persona/workspace; Phase 11 test suite; REPO_PATH stamp for installed bundle.

## Phase 10 / R10 (2026-05-06)
Approval schema v2; one-time token pattern; iOS approval helpers; iCloud inbox signature validation; memory proposal flow.

## Phase 9 / R9 (2026-05-06)
pairings.json dict split; approvals RLock; mtime-invalidated pairings cache; HMAC pairing secret; fix-R9 series.

## Phase 8 (2026-05-06)
Wave-3 UI (onboarding, approvals badge, chat UX); DaemonProcessController; BrowserWindow; SkillLifecycleView; crash improvement throttle.

## Phase 7b (2026-05-06)
ToolsPaletteView; ToolInputForm; slash command dispatch to capability tools; /v1/dispatch endpoint.

## Phase 7 (2026-05-06)
Spotlight overlay (⌘⇧J); global hotkey; VoiceInputController; VoiceOutputController; persona templates.

## Phase 6 / R6 (2026-05-06)
iCloud pairing v2; MacSyncEngine SnapshotWriter + InboxWatcher; iOS companion app skeleton; HMAC signing.

## Phase 5 (2026-05-06)
MacControlBridge.swift in-app TCC bridge; mac_control_bridge_client.py; bearer-token auth; port 8770.

## Phase 4 (2026-05-06)
Mac Control module (mac_control.py); connector action registry; run_connector_action; approval gate; iOS MacToolsView.

## Phase 3c / R3 (2026-05-06)
Scratchpad per-session ephemeral key-value store; scratchpad_write/scratchpad_read tools; namespace design.

## Phase 3b (2026-05-06)
Mission runner (missions.py); planning loop; timeline events; mission_chat_parity test suite.

## Phase 3 (2026-05-06)
Dispatcher phase 1b: mission path wired; unified receipt shape across chat + mission surfaces.

## Phase 2b (2026-05-06)
Adaptive memory promotion; contradiction detection; decay weighting; forget endpoint.

## Phase 2 (2026-05-06)
Knowledge graph (knowledge_graph.py); entity/relation extraction; KG subgraph for prompt.

## Phase 1b (2026-05-06)
Dream cycle (dream_cycle.py); nightly 3:30am reflective diary; inbox digest; trust gates.

## Phase 1a (2026-05-06)
Unified dispatcher (dispatcher.py); AutonomyLevel enum; Receipt shape; structured trace events; builtin_tools registry; 22-test dispatcher suite.

## Phase 1 (2026-05-06)
Initial: NativeAgent.app plus a retired external runtime; SwiftUI plus a local HTTP server; `/v1/chat`; Codex OAuth; persona/SOUL.md.
