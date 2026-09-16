# NativeAgent user and agent guide

NativeAgent is a personal agent for Mac. Start with a conversation; connect
other devices and grant access as you need them.

## First setup

1. On an Apple-silicon Mac running macOS 26 or newer, download the DMG from the
   [releases page](https://github.com/embwl0x/native-agent/releases). Open it,
   drag NativeAgent to Applications, and open the app.
2. Enter your name and the agent's name. Expand **What the agent can help with ·
   Optional** for an overview.
3. Connect one AI account during setup, then finish onboarding. If you skip
   connecting, open **Providers** on the left rail before chatting.
4. Open **Chat** and say hello, or ask for help with a task.

Without a connected account, Chat offers **Open Providers**. Sign in with an
account you already use or add an API key; **Cancel** stops a stalled browser
sign-in so you can retry.

Connect one AI account to start chatting. **Work** and **Memory and mind** follow
**Chat** unless you choose otherwise in Providers; a group that holds a choice of
its own is captioned **Custom choice**, and **Use Chat's choice** clears it. A
group's choice is the whole answer for every activity in it. There are three
groups and nothing else:

- **Chat** — Chat, iPhone, Telegram and Slack.
- **Work** — Desk, Task execution, Independent tasks, Coordinated tasks, Skill
  practice, Background check-ins and Diagnostics.
- **Memory and mind** — Memory, Dreams, REM, Reflection, Conversation summaries,
  Learning and Creative exploration.

Every activity in a group runs on that group's account and model: the group's own
choice when it has one, Chat's when it does not. No activity carries a model of
its own, so none can be pointed at a model its account cannot serve. If a model
you once picked is no longer offered by that account, it stops counting as a
pick and the activity goes back to the group's choice — nothing is silently
swapped for a different model.

When a task needs access, open **Trust** on the left rail and choose the least
authority that fits. Use **Trust → Mac integration** for individual Mac
services. Trust does not replace macOS permission prompts or service sign-in.
Shell access is not required for a first chat. Trust saves each control as you
change it; controls that only take effect after a restart are marked with a
restart tag beside them.

## Optional background and memory settings

These settings are optional and can be changed after your first chat.

1. Open **Settings**.
2. **An inner life** starts on after setup and a working account. Use it to
   turn background reflection off or on.
3. Use **Memory in every reply** to choose whether remembered context feeds
   replies. **Observe Only** measures selection without supplying it to the
   model; **Off** disables it.

In the classic sidebar, use **Settings → Advanced → Subconscious** and set
**Fluid Context** to **Active** for resident context selection to feed
replies.

The classic reflection status names the selected model with **Running with …**
or explains a missing connection, unavailable model, or inactive background
activity. To inspect the exact state, open
**Diagnostics → Cognition** on the default rail. In the classic sidebar, turn
on **Settings → Show Developer Surfaces**, then use **Settings → Advanced →
Diagnostics → Cognition**. Developer Surfaces changes UI visibility only; the
saved Trust policy's shell and system-control authority is a separate thing —
see [Three terms that are often confused](#three-terms-that-are-often-confused).

Background reflection can shape attention, voice, and carefulness, but cannot
grant permissions, approve actions, or bypass Trust.

## Turn on Mac computer control and the activity watcher

- Computer control (see, click, type): grant macOS **Accessibility** (and
  **Screen Recording** for pixel perception) to NativeAgent, then select the
  intended access in **Trust**. The ordinary agent-facing tools are
  `screen`, `act`, `go`, and `wait`: named controls and observed visual regions
  are resolved again before input. Shell execution has its own control further
  down the same **Trust** tab, in the **Shell Commands** panel:
  **Enable Shell Commands** (marked restart). The saved policy and
  macOS permissions still apply, along with redaction, user takeover,
  locked-screen refusal, and truthful effect receipts.
- While the agent drives the Mac, the working card above the message box shows
  what the agent is looking at: a small picture of the last screen the agent
  took, and a line naming the verb in flight. The line says only what the
  picture can back. While the agent is still deciding where to click, the
  picture shows the button unclicked and the line reads **About to click
  Save**; once the click has happened and the agent has looked again, the line
  becomes **Clicked Save** — or **Could not click Save**. A plain look says
  **Looking at Safari**, and a wait says **Waiting for the page**. Click the
  picture, or select it with Tab and press Space, for a larger view; Escape
  closes it. It appears only on turns that actually use the Mac, and it goes
  away when the turn ends. No picture is taken for it and none is kept: it is
  the frame the verb already captured, held in memory for the length of the
  turn and dropped when the turn ends — never written to the conversation,
  never saved to disk, never sent to the AI provider, and never part of memory.
  Secure fields — password, passcode, and one-time-code boxes — are painted out
  of it, in web pages as well as in ordinary Mac apps. Only secure fields are
  hidden: the rest of the picture is the screen as it is, including ordinary
  text boxes beside them.
  The per-verb receipts remain the record of what happened; this is the live
  view while it happens.
- Chrome control is separate: in **Trust**, click **Set up Chrome**. It opens
  the bundled extension folder and Chrome's extensions page. Turn on Chrome's
  **Developer mode**, click **Load unpacked**, and select that folder; no second
  download is needed. Enable **Chrome control** in Trust and keep Chrome open.
  See the [extension setup guide](../Extensions/NativeAgentChrome/README.md).
  It can create an inactive agent tab or claim an exact existing tab, read a
  bounded structured snapshot, and act on that snapshot's nodes. Touching or
  activating the tab yields its lease. Native screen control still operates
  the visible desktop; NativeAgent's built-in Browser is a third, WebKit-based
  surface. Enabling one does not silently enable the others.
- Activity watcher: in **Trust**, enable **Record which apps I use**. It records
  app and permitted, redacted window-title history locally while enabled.
  **Let the agent answer from activity history** separately allows a requested
  excerpt to reach the selected AI provider when you ask what you were working
  on. The database stays local and does not become long-term memory.

## Main Mac pages

The default shell puts the main pages on the left rail, in the order below, and
related controls are tabs within those pages. A hairline separates the everyday
places from the setup ones, and **Settings** sits at the foot.

| Place | Use it for |
|---|---|
| **Chat** | Conversations, attachments, voice, sessions, and the configured agent's name and status. |
| **Today** | Notifications, approvals, proposals, recent work, and items waiting for the user. **Read dream** checks the source and opens **Dreams**. |
| **Memories** | Search and manage saved facts; decide **Keep** or **Don't keep** beside each proposal. Kept facts sit under **What I've kept**; a fold at the bottom — **N things I let go** — lists what you rejected, read-only, so the same fact cannot quietly return. The **Knowledge graph** is the second tab. |
| **Desk** | Line up large projects, dependencies, bridge work, schedules, research, agent pursuits, approvals, progress, verification, and outcomes. |
| **Notifications** | **Proactive inbox** — **Let the agent raise things unasked** — plus its **Triggers**, **Watched folders**, and the inbox history. |
| **Bots** | Standing briefs the agent runs on a schedule or on a GitHub or Slack event, their dated replies, **Run once** and **Pause**. On the rail by default since 0.4.10. |
| **Personality** | Documents labeled by purpose: **Identity**, **Expression**, **About you**, **Personal growth**, and **Working guidelines**; the agent's minds and **Dreams** have their own tabs. |
| **Providers** | Connect an AI account; optionally tune models per activity group. An account whose access has expired says so rather than reading as ready. |
| **Trust** | Presets, feature permissions and approvals; the **Mac integration** tab holds individual Mac-service access. |
| **Connectors** | Service connections, with **MCP**, **Telegram**, and **iPhone** tabs. |
| **Capabilities** | What the agent can actually do, with **Show all actions**. |
| **Diagnostics** | **Doctor**, **Status**, **Runs log**, **Cognition**, **Inspector**, **Skills**, and **Tools** tabs. |
| **Settings** | Appearance, shortcuts, updates, help, **An inner life**, and **Memory in every reply**. The classic layout also shows **App status**. |

### The agent reading and setting these pages, quietly

Since 0.4.14 the agent can look at NativeAgent's own pages and change what they
expose without touching the desktop. It never brings the window forward, never
moves the pointer, never changes what is on screen, and makes no sound — the
page it reads is drawn a second time offscreen, from the same live state the
visible window shows. A person watching sees nothing happen at all. Scope is
this app only; anything on the rest of the Mac still goes through Mac control.

- **Reading is always allowed**, in every Trust mode, including Safe and Work
  mode. The agent can say what a page shows and what each control is set to.
- **Changing needs Builder or Full Mac.** In Safe and Work mode a change is
  refused in plain words, naming the mode, rather than half-applied.
- **Trust's own posture is never the agent's to change** — presets, Full Mac,
  the unattended-work switch, Mac control, Mac service access, and the file
  access mode. The agent reads them, reports them, and says it cannot set them.
- **Every change leaves a receipt you can read**, in the same activity trail
  every other tool call leaves: the page, the setting, the old value and the new
  one. The page itself updates immediately, exactly as if it had been clicked.
- **Reading aloud has a silent path.** The agent can render speech to a file and
  report how long it runs, how large it is, and which voice spoke, without the
  speakers ever opening. Your own read-aloud setting is untouched by it.

**Classic sidebar note:** **Settings → Use the classic sidebar**
switches layouts. That layout's own sidebar rows are Chat, Activity, Memories,
Desk, Skills & Tools, Providers, Trust, Mac Integration, and Settings, and its
**Advanced** disclosure holds **Personality** and **Connectors** plus the
developer-gated **Capabilities**, **Knowledge Graph**, **Dreams**,
**Diagnostics**, **Inbox Policy**, and **MCP**. **Show Developer Surfaces**
reveals that second half. The same disclosure holds embeddings and
**Subconscious**. Providers, Trust, and Mac Integration are classic sidebar rows
in their own right, not Advanced entries.

The system-health pill (the "N warnings" readout) and the session token meter
live in **Diagnostics**, not in the chat window. Chat carries one status dot
instead of two competing warning surfaces.

Every page is still reachable by **Command-K** and by its existing deep link,
whether or not it appears on the rail.

## Memory, personality, and context

- **Personality** owns the configured agent identity and voice documents.
- **MemoryV2** owns durable facts. A memory is not canonical merely because it
  appeared in conversation, a dream, or the knowledge graph.
- **Knowledge Graph** is a derived index over canonical memory, not a separate
  place to store truth.
- **Fluid Context** circulates bounded persona, memory, skill, project,
  cognitive, and organism material. It is rebuildable and does not replace the
  original stores.
- **Dreams and REM** consolidate experience on slow paths. They do not turn raw
  transcripts into unquestioned facts.

Tell the agent explicitly when something should be remembered. Review proposed
preferences or goals in Today or Memories before treating them as durable.
In Personality, **About you** is read-only; change those facts in **Memories**.
Other editable documents use **Save document**, and switching documents keeps
unsaved edits.

## Skills, tools, MCP, and connectors

NativeAgent keeps ordinary turns small by loading capabilities lazily.

- Twenty tools ride every request (sixteen until Full Mac accessibility is on,
  since the four Mac verbs wait for it), and so do the tools of any MCP server you
  have mounted — those are inserted automatically. Everything else is catalogued
  but costs nothing until it is needed, and leaves again after two turns without
  a real call — including under Full Mac, where the file and system tools load
  on intent like any other group. A dropped tool is never gone: it stays in the
  catalog and one call brings it back. [Tool loading](TOOL_LOADING.md) states
  the contract.
- `tool_catalog` or `list_tools` discovers capability names and groups;
  `tool_load` activates only what the current session needs.
- `dream_diary_read` lets the agent read its own dream diary — the weekly index
  the Dreams page shows, one night in full by date, or the nights whose text
  mentions something. Read-only, and archived nights are included.
- The agent's studio journal is append-only, and `studio_journal_amend` is how a
  wrong fact in an entry gets fixed: it files a dated correction against that
  entry rather than editing it, so the original wording stays visible, struck
  through, beside the correction and the reason for it. A changed judgment is
  still a new entry linked to the old one, not an amendment.
- File, shell, Git, builds, and Mac control follow the saved Trust permissions.
  A connected external service still needs the applicable access checks.
- `list_skills` lists compact procedure summaries; `read_skill` loads one
  relevant body; `save_skill` is the canonical creation/update path. A body saved
  without a heading is given one from the skill's name rather than refused; the
  other hygiene rules still refuse, and say why.
- Skills may recommend a procedure but cannot grant tools, permissions,
  approvals, or safety authority.
- MCP servers translate external protocol calls into the same bounded action
  and verification language as native tools. A protocol response is evidence,
  not proof that an external effect settled.
- Connectors provide explicit setup for services such as Telegram, Slack,
  GitHub, Gmail, Google Calendar, Notion, and X. Credential presence alone is
  not a successful connection; NativeAgent requires the provider's applicable
  validation path.

In **Connectors → Share a folder**, enter a name, click **Choose Folder…**,
choose whether to **Let the agent write to it**, then click **Share this folder**.
**Search the shared folders** distinguishes searching, no matches, and errors;
narrow the query when more matches are loaded than shown. **Capabilities**,
reachable with **Command-K**, offers **Show all actions** to expand the native
action list.

For app-only/public installations, the safe default for file, shell, Git,
patch, and build work is:

```text
~/Library/Application Support/NativeAgent/workspace
```

A verified source-backed developer install uses the checkout's `workspace/`.
Every chat surface and the Desk resolves the same canonical workspace for
relative paths and ordinary trust modes. With Full Mac access, the agent
may explicitly select an existing absolute project elsewhere on the Mac for
native shell/build work or a Codex/Claude Code handoff. NativeAgent validates
that directory again at dispatch time; protected system and credential/
authority paths do not become valid coding roots.

macOS privacy permission is separate from NativeAgent trust. On a new Mac, a
project under **Documents**, **Desktop**, **Downloads**, Mail, Messages, or
another protected location may require an Apple consent prompt or a manual
grant in **System Settings → Privacy & Security → Files & Folders**. If the
project must span multiple protected locations, grant **Full Disk Access** to
NativeAgent and relaunch it. Full Mac access cannot grant macOS privacy
authority. Projects in ordinary user-owned locations do not need this extra
Apple permission.

## Trust modes and approvals

Start with the four presets at the top of **Trust**:

- **Safe** reads files without changes or Mac control.
- **Work mode** edits approved workspaces and denies writes outside them.
- **Builder** edits approved workspaces and asks before writing outside them.
- **Full Mac** permits broader file access after confirmation; macOS permissions
  still apply. It has no timer: it stays in force until you choose another mode.

The four cards sit under **Access and policy**, each with its own one-line
summary — **Read files; no changes or Mac control**, **Edit approved workspaces;
no outside writes or shell**, **Edit workspaces; ask to write outside; no
shell**, **Files anywhere, shell, system control, move or trash**. Choosing one
applies it immediately and saves it; a line under the cards names the saved
state, which stays named even with custom settings. Choosing **Full Mac** asks
**Enable Full Mac access?** first. **Create backup now** is on the same panel.

Below that, a read-only summary restates what the saved policy currently allows,
then **Feature permissions** holds five cards — **Multimodal**, **Chrome
Control**, **Self-Improvement**, **Desk Autonomy**, and **Living Memory**. Under
those sit the Mac Control panels (file operations, AppleScript, JXA, **Shell
Commands**) and the activity watcher. **Advanced** is one fold: **Safety
boundaries**, **Privacy map**, and **Backups**.

There is no separate draft to save. Each control writes its own change; where a
change only lands on the next launch, the control carries a restart tag.

### Three terms that are often confused

- **Full Mac** is one of the four presets above. Choosing it grants the machine:
  broad file access, shell and system control. It asks for confirmation once and
  then stays on with no timer — until you pick another preset. Nothing counts it
  down, and any expiry left in an older install's saved policy is ignored.
- **Developer mode** is the internal name of an execution field in the saved
  Trust policy, not a preset and not a control with that title anywhere in the
  app. It is what actually authorises shell, system control, and moving or
  trashing files; with it off, those are refused and the policy is rewritten on
  load to say so. The **Full Mac** card is what turns it on — Full Mac sets it
  and every other preset clears it. The operator-facing control nearest to it is
  **Enable Shell Commands**, in the **Shell Commands** panel further down the
  **Trust** tab; it is marked restart, and its caption says to keep it off
  unless that field is intentionally on for the operator session. **Show
  Developer Surfaces** in Settings is a third, unrelated thing — it changes UI
  visibility only and grants nothing.
- **YOLO** is not a mode and there is nothing to switch on. It is the name for
  the 2026-08-12 defaults ruling in the Trust defaults table: unlisted tools
  resolve to `auto` rather than asking, and Mac motor actions are `auto`, so an
  admitted Full Mac action does not raise a per-call prompt. The Full Mac grant
  is the consent. Trust presets, the macOS permission grants, and the protected
  floors below are still the gates — the ruling removed the prompt, not the
  boundary. `restart_app`, `install_app`, and the self-modification tools are
  deliberately still held at confirm.

Trust remains authoritative on Telegram, Slack, iPhone, and delegated work.

Broader access does not remove protected-system restrictions, external-service
checks, or required approval for consequential actions.

If approval is requested, resolve the exact item in **Today**. A pressed
Approve button is not success until the action produces its terminal receipt
and, where applicable, domain verification.

Chat tool receipts show the outcome first; **Details** expands the evidence in
place. A partial result says what was not created and why.

## Desk, background work, and swarms

- Put durable multi-step work on the **Desk**. One Desk identity follows the
  task through planning, execution, pauses, verification, and completion.
- A row that reads **held** is work that cannot move yet — blocked, deferred, or
  waiting on a held parent. The same line says which. It is not a status anyone
  sets; clear the cause and the row returns to its own status.
- The agent's own pursuits use a restricted Desk work membrane rather than an
  unrestricted hidden chat. A Workshop session that ends without recording what
  it did is written down as **blocked** with the reason named, rather than
  counted as progress.
- Background loops handle event-driven maintenance, messaging, snapshots,
  notifications, dreams, memory hygiene, and scheduled work. Quiet operation
  should perform no model work unless a real event or due boundary requires it.
- Swarms are temporary parallel workers inside the same runtime. They use the
  Swarms provider default unless explicitly specialized, start read-only by
  default, and gain no authority beyond the parent turn.

## Bots: standing helpers

**Bots** holds the standing helpers the agent makes — for you, or to help itself.
A bot needs a name, a brief, and a model. It keeps its own conversation, uses the
agent's ordinary tools under the Trust policy you have saved, gets the same
remembered context any other turn gets, and lives until the agent deletes it.

- **A bot always runs on the model it was made with.** The account, model, Think
  level and Fast setting are chosen when the bot is made and are part of it; a
  bot never follows Chat's model. A bot saved before this rule reads **Choose a
  model** on its card and does not run until one is set.
- Timing is manual, twice daily, daily, every N hours, a custom schedule, or
  **On an event**. **Run once** and **Pause** are always available.
- **On an event** wakes the bot when something arrives instead of on a clock.
  Two sources: a new GitHub issue or pull request on a repository the GitHub
  connector already tracks, and a Slack message in a channel the Slack connector
  already receives. Enter the repository as `owner/repo`, or the Slack channel
  ID (Slack delivers an ID, not a name: open the channel, choose **View channel
  details**, copy the ID at the bottom — it looks like `C0123ABCD`), and a
  keyword if only some events should wake the bot. The event text goes to the
  bot as the input for that run, so the brief can say what to do with it. The
  card shows **Wakes on: GitHub · owner/repo** and the last event that arrived.
  An event is unattended spend like a scheduled run and passes the same Autonomy
  switch below: with Autonomy off the card records the event as held and nothing
  runs.
- Each finished run is one settled card at the top of the bot's page, newest
  first: the first line of the reply, when the run happened and how long it took,
  one word for how it ended (Completed, Stopped, Failed, Blocked), the model the
  run used, and any file or link the reply produced. **Open the reply** expands
  the full text in place. The last five cards stay on the page; everything the
  run said and did is under **Session · messages and tool activity** below them.
- Scheduled runs are the agent spending on your account while you are not there,
  so they sit behind one switch: **Trust → Self-Improvement → Let the agent work
  unattended (bots, practice runs, background improvement)**, the master switch
  for that card and the same one the Workshop runs behind. (**Desk Autonomy** is
  a separate card beside it and governs Desk work, not this switch.) A fresh
  install has it on. Turn it off and no bot timer fires and no event wakes a bot.
  One exception: **Full Mac** access runs unattended work whatever the switch
  says, and shows it on — changing the access mode is how to turn it off.
  **Run once** is you asking, so it still runs either way.
- A scheduled run that never happened says so. The bot's card reads
  **Missed Sep 12 at 9:00 AM · the Mac was asleep** — or the app was closed,
  Autonomy was off, the queue was busy, the daily token ceiling was reached, or
  plainly "not run" when the app cannot tell. The Desk's schedule fold counts
  those apart from what runs and what is paused. A missed occurrence is a
  record, never a retry: nothing runs late behind your back, and the next
  occurrence is scheduled as usual. **Run once** runs it now if you want it.
- **Continue in Chat** opens the bot's own conversation and keeps the bot's
  model, reasoning effort and approval rule. You are typing in the bot's session,
  not moving its work into Chat's settings.
- Per-run and daily limits are yours to set; blank means the defaults. A token
  figure shown against a run is the allowance reserved for it, not what it spent.
- A brief is an instruction to the agent, not a permission. "Read only" in a
  brief does not narrow what Trust has already granted — set that in **Trust**.

## iPhone and iPad

1. Install NativeAgent Mobile and keep the Mac and mobile device signed into
   the intended iCloud account.
2. On Mac, open **Connectors → iPhone** (classic sidebar:
   **Settings → Pair iPhone / iPad**).
3. Pairing details arrive automatically for the same Apple Account. On mobile,
   choose **Connect via iCloud** when ready. If waiting, tap **Check for Mac**.
   **Correct pairing key manually** appears only after the Mac's details arrive.
   For correction, expand **Pairing hasn't connected?** on the Mac, **Copy** the
   key, then use **Paste pairing key** and **Save Pairing Key** on the phone.
   Manual correction must match the published key. Keep the key secret.
4. Enable NativeAgent notifications in iOS Settings.

The phone tabs are **Chat**, **Activity**, **Memories**, **Desk**, and **More**.
Desk includes **Desk tasks** and expandable history. **Activity** waits for each
section's own data before showing a zero, so an empty list means clear rather than
not yet arrived, and a freshness badge reports when that screen's data was
delivered rather than when any sync last ran. The Mac sends the phone a bounded
slice of the Desk: text it had to cut is marked as cut, and the history says how
many items were published out of how many exist. Mobile also supports
sessions and pins, attachments, model controls, approvals, Skills & Tools,
agent status, signed remote actions, and lock-screen notifications. **More →
Settings → Push deliveries** shows recent push receipts; **Connection** offers
**Check for Mac updates** when paired and connected. The Mac must remain
available to run provider turns and tools. See
[mobile_companion.md](mobile_companion.md) for transport detail.

## Telegram, Slack, and local bridges

- Configure Telegram in **Connectors → Telegram** and other services in
  **Connectors**. In the classic sidebar, use **Settings → Telegram** and
  **Settings → Advanced → Connectors**.
- Each surface has a scoped session but uses the same persona, memory, Fluid
  Context, provider policy, tools, trust gates, and receipts. A bridge turn is a
  full turn: what the agent remembers from it names the sender, and the session is
  digested like any other conversation.
- Local Codex and Claude Code clients must read the authenticated bridge
  descriptor at `~/.config/claude-bridge/bridge.json`; never assume port 8771
  is free or bypass the published bearer token.
- The local return listener starts automatically with NativeAgent. Developer
  Mode is not required for Codex or Claude Code to return a completed turn;
  TrustCenter and the normal action/approval gates still govern what either
  builder may do.

### Codex and Claude Code as specialist builders

NativeAgent has native file, shell, git, patch, test, and build tools and can
complete ordinary development work itself. For a difficult repository-scale
task, however, Codex and Claude Code are purpose-built coding environments:
they are usually better at sustained multi-file implementation, debugging,
large test runs, review, and repair. The bridge lets the configured agent hand
that work to a stronger temporary builder without turning the builder into a
second memory, personality, scheduler, or authority owner.

These are real coding sessions, not one stateless model call with a copied
prompt:

- **Codex:** `codex_message` normally starts a persisted, non-ephemeral Codex
  app-server thread in the selected project directory. The thread receives the
  chosen model and reasoning controls, Codex's normal repository tools, a
  bounded execution policy, durable turn identity, and a tracked final reply.
  A specifically configured pinned thread can be resumed, but the safe public
  default is a fresh full thread for each independent handoff; it does not
  silently hijack whichever Codex task the user currently has open.
- **Claude Code:** `claude_message` starts the real Claude Code CLI with a
  durable session id. NativeAgent keeps one session pointer per topic, so a
  follow-up on the same topic resumes the prior Claude Code conversation and
  tool history instead of starting an unaware one-shot process. An explicit
  `working_directory` on a new work order wins over the saved pointer's cwd,
  allowing that topic to move to the real target project deliberately.

The NativeAgent app bundles both bridge workers; a public install does not need
a NativeAgent source checkout. The coding products remain user-owned local
organs: install and sign into Codex CLI and/or Claude Code on the same Mac, and
install Node.js for the bundled bridge workers. NativeAgent searches standard
system and user-local locations such as `~/.local/bin`, including when the app
was launched from Finder and inherited no interactive-shell `PATH`. The
`tool_catalog` response reports helper, runtime, CLI, and authenticated return
path readiness separately. Authentication to the coding product is proven only
when execution begins. Seeing a tool schema is therefore not a claim that an
uninstalled, signed-out, or incomplete bridge is ready, and an unavailable
return path fails before NativeAgent queues a message that cannot come back.

Sessions and credentials belong to that Mac's own Codex or Claude Code
installation. A new computer starts with its own clean builder history; the
bridge does not import the maintainer's conversations, account, or private
context from another machine.

NativeAgent sends a bounded work order and the correct working directory; the
builder then inspects the repository itself. It does **not** receive an
unbounded dump of private memories, and it does not inherit permission to
bypass TrustCenter, approvals, connector proof, or effect-time checks.
Human-out-of-loop bridge turns cannot stop for invisible interactive approval;
if required authority is unavailable, the builder must return the blocker.

When the builder finishes, NativeAgent records the completion, returns it to
the originating Mac, Telegram, Slack, or iOS session, and assesses the result
as success, partial, or failure. A builder's statement is still not proof:
tests, receipts, git state, and the domain that owns the external effect must
verify the outcome before the persistent agent treats it as settled. This is
the intended division of labor: NativeAgent remains the continuous mind;
Codex or Claude Code temporarily supplies deeper engineering cognition, and
the verified result returns to that same mind.

## What the configured agent should do

1. Treat persona and MemoryV2 as identity/fact authority; use `commit_memory`
   for explicit durable facts rather than editing generated `USER.md`.
2. Use the compact manifest first, then `tool_catalog`, `tool_load`,
   `list_skills`, and `read_skill`. Do not crawl private registries or stuff the
   whole catalog into context.
3. Use only same-turn `context_expand` pointers when deeper Fluid Context is
   truly needed.
4. Put work products in the canonical workspace and use Desk for durable
   multi-step execution.
5. Respect the originating surface, session, TrustCenter policy, approvals,
   connector proof, and effect-time checks.
6. Verify outcomes through the domain that owns reality. A model statement,
   tool envelope, MCP response, HTTP success, queued push, or approval click is
   not automatically a completed external effect.
7. Convert a repeated successful procedure into a reviewed skill or Desk
   procedure, never into silently expanded authority.

## Health and troubleshooting

- **Diagnostics → Doctor** checks providers, connectors, storage, tools, and
  background loops. It reports when the checks were taken, not just when the page
  last saved them, and declines to grade a sample too small to judge.
- **Diagnostics → Status** and **Runs log** show app and execution state, and
  **Inspector** reads one turn end to end.
- **Diagnostics → Cognition** shows Fluid Context and Organism readouts.
- **Today** is the first place to check approvals, warnings, and work waiting
  on the user.
- Use **Settings → Check for Updates…** for signed public releases.

For pairing, notifications, permissions, provider, and data-removal steps, see
[../SUPPORT.md](../SUPPORT.md). Do not post API keys, OAuth tokens, pairing
keys, private prompts, personal files, or unredacted support archives.

## Honest boundaries

For architecture and runtime details, see
[NativeAgent Internal Workings](INTERNAL_WORKINGS.md). The
[capability map](CAPABILITIES.md) and [project status](../PROJECT_STATUS.md)
describe supported features and current limitations.

NativeAgent is local-first and single-operator, but provider requests and
configured connectors still send selected data to those external services.
The shell is not a security sandbox. The Organism and cognitive substrate are
bounded experimental layers. NativeAgent should not be the sole control for
medical, legal, financial, emergency, or other safety-critical decisions.
