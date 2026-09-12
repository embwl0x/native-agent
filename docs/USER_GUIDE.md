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
sign-in so you can retry. Providers puts connected accounts and **Manage**
first, with every account and API key route visible. Model, Think, and Fast
are optional. **Optional model overrides** opens activity choices in three
groups — **Chat**, **Work**, and **Memory and mind** — each marked **Explicit
override** or **Inherited default**. Inherited defaults can differ from Chat;
changing a control saves an explicit choice. Grouping is presentation only, so a
saved choice still belongs to its own surface.

When a task needs access, open **Trust** on the left rail and choose the least
authority that fits. Use **Trust → Mac integration** for individual Mac
services. Trust does not replace macOS permission prompts or service sign-in.
Developer mode is not required for a first chat. Trust distinguishes controls
that apply immediately from the policy draft that needs **Save policy**.

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
Diagnostics → Cognition**. Developer Surfaces changes UI visibility only;
**Trust → Developer Mode** is a separate execution setting that applies now.

Background reflection can shape attention, voice, and carefulness, but cannot
grant permissions, approve actions, or bypass Trust.

## Turn on Mac computer control and the activity watcher

- Computer control (see, click, type): grant macOS **Accessibility** (and
  **Screen Recording** for pixel perception) to NativeAgent, then select the
  intended access in **Trust**. The ordinary agent-facing tools are
  `screen`, `act`, `go`, and `wait`: named controls and observed visual regions
  are resolved again before input. **Customize permissions** exposes the
  **Developer mode** control for shell and system control. The saved policy and
  macOS permissions still apply, along with redaction, user takeover,
  locked-screen refusal, and truthful effect receipts.
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

The default shell puts the main pages on the left rail. Related controls are
tabs within those pages.

| Place | Use it for |
|---|---|
| **Chat** | Conversations, attachments, voice, sessions, and the configured agent's name and status. |
| **Today** | Notifications, approvals, proposals, recent work, and items waiting for the user. **Read dream** checks the source and opens **Dreams**. |
| **Memories** | Search and manage saved facts; decide **Keep** or **Don't keep** beside each proposal. The **Deleted** tab lists what you rejected, kept so the same fact cannot quietly return. |
| **Desk** | Line up large projects, dependencies, bridge work, schedules, research, agent pursuits, approvals, progress, verification, and outcomes. |
| **Providers** | Connect an AI account; optionally tune models per activity group. An account whose access has expired says so rather than reading as ready. |
| **Trust** | Trust modes and approvals; the **Mac integration** tab holds individual Mac-service access. |
| **Personality** | Documents labeled by purpose: **Identity**, **Expression**, **About you**, **Personal growth**, and **Working guidelines**; model choices and **Dreams** have their own tabs. |
| **Connectors** | Service connections, with **MCP**, **Telegram**, and **iPhone** tabs. |
| **Diagnostics** | Health and detailed status, with **Cognition**, **Skills**, and **Tools** tabs. |
| **Settings** | Appearance, shortcuts, updates, help, **An inner life**, and **Memory in every reply**. The classic layout also shows **App status**. |

**Classic sidebar note:** **Settings → Use the classic sidebar**
switches layouts. In that layout, **Settings → Advanced** contains the setup
page list, including **Providers**, **Trust**, **Mac Integration**, and
**Connectors**. **Show Developer Surfaces** reveals the additional diagnostic
pages there. The same disclosure holds embeddings and **Subconscious**.

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

- Twenty tools ride every request, and so do the tools of any MCP server you
  have mounted — those are inserted automatically. Everything else is catalogued
  but costs nothing until it is needed, and leaves again after two turns without
  a real call — including under Full Mac, where the file and system tools load
  on intent like any other group. A dropped tool is never gone: it stays in the
  catalog and one call brings it back. [Tool loading](TOOL_LOADING.md) states
  the contract.
- `tool_catalog` or `list_tools` discovers capability names and groups;
  `tool_load` activates only what the current session needs.
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

Presets apply immediately, and the saved state remains named even with custom
settings. A preset does not discard unsaved edits. **Customize permissions**
separates **Applies immediately** (Agent access, Developer mode, and backup)
from **Policy draft · Save to apply**. Click **Save policy** for draft changes
to affect the next checked action; actions already running are unchanged.

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
A bot needs only a name and a brief. It keeps its own conversation, uses the
agent's ordinary tools under the Trust policy you have saved, gets the same
remembered context any other turn gets, and lives until the agent deletes it.

- Leave the model blank and a bot runs on the same route as Chat; choose any
  connected account, model, Think level and Fast setting when you want to.
- Timing is manual, twice daily, daily, every N hours, or a custom schedule.
  **Run once** and **Pause** are always available.
- Scheduled runs are the agent spending on your account while you are not there,
  so they sit behind the master Autonomy switch in **Trust**. Turn Autonomy off
  and no bot timer fires. **Run once** is you asking, so it still runs.
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
- **Diagnostics → Status** and **Runs Log** show app and execution state.
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
