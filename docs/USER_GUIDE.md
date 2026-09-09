# NativeAgent user and agent guide

NativeAgent is a personal agent for Mac. Start with a conversation; connect
other devices and grant access as you need them.

## First setup

1. On an Apple-silicon Mac running macOS 26 or newer, download the DMG from the
   [releases page](https://github.com/embwl0x/native-agent/releases). Open it,
   drag NativeAgent to Applications, and open the app.
2. Give the agent a name and enter your name.
3. Connect one AI account during setup, then finish onboarding. If you skip
   connecting, open **Providers** on the left rail before chatting.
4. Open **Chat** and say hello, or ask for help with a task.

Model, Think, Fast, and per-surface choices are optional tuning in **Providers**.
You do not need to configure Telegram, Slack, Desk, or background models to
start chatting.

When a task needs access, open **Trust** on the left rail and choose the least
authority that fits. Use **Trust → Mac integration** for individual Mac
services. Trust does not replace macOS permission prompts or service sign-in.
Developer Mode is not required for a first chat; changes apply immediately
after saving, without restarting the app.

## Optional background and memory settings

These settings are optional and can be changed after your first chat.

1. Open **Settings**.
2. Turn on **An inner life** to enable background reflection and memory.
3. Use **Memory in every reply** to choose whether remembered context feeds
   replies. **Observe Only** measures selection without supplying it to the
   model; **Off** disables it.

In the classic sidebar, use **Settings → Advanced → Subconscious** and set
**Fluid Context** to **Active** for resident context selection to feed
replies.

When the status says **Running**, NativeAgent has enabled the bounded cognitive
capsule, background settlement, reflection budget, and Organism together. A
**Partially enabled** warning means setup, provider health, or a safety gate is
holding part of the background work off. To inspect the exact state, open
**Diagnostics → Cognition** on the default rail. In the classic sidebar, turn
on **Settings → Show Developer Surfaces**, then use **Settings → Advanced →
Diagnostics → Cognition**. Developer Surfaces changes UI visibility only;
**Trust → Developer Mode** is a separate execution setting that applies now.

The Subconscious and Organism are advisory. They can shape attention, voice,
carefulness, and bounded background posture, but cannot grant permissions,
write canonical user facts, approve actions, or bypass TrustCenter.

## Turn on Mac computer control and the activity watcher

- Computer control (see, click, type): grant macOS **Accessibility** (and
  **Screen Recording** for pixel perception) to NativeAgent, then select the
  intended Full Mac mode in Trust Center. The ordinary agent-facing tools are
  `screen`, `act`, `read`, and `open`: named controls and observed visual regions
  are resolved again before input. Full Mac YOLO removes routine approval
  friction for the admitted operator, including authenticated remote chat;
  other modes retain their applicable approvals. Redaction, takeover,
  locked-screen refusal, and truthful effect receipts remain either way.
- Chrome control is separate: enable **Chrome control** in Trust Center and
  install/load the [NativeAgent Chrome extension](../Extensions/NativeAgentChrome/README.md).
  It can create an inactive agent tab or claim an exact existing tab, read a
  bounded structured snapshot, and act on that snapshot's nodes. Touching or
  activating the tab yields its lease. Native screen control still operates
  the visible desktop; NativeAgent's built-in Browser is a third, WebKit-based
  surface. Enabling one does not silently enable the others.
- Activity watcher: Trust Center -> capture tab -> enable. It records app and
  redacted window-title spans locally, nothing else, and only while enabled.
  Ask the agent "what was I working on yesterday" to use it. Disabling stops
  capture instantly; the data never leaves your Mac and the agent never
  memorizes it.

## Main Mac pages

The default shell puts the main pages on the left rail. Related controls are
tabs within those pages.

| Place | Use it for |
|---|---|
| **Chat** | Conversations, attachments, voice, sessions, and the configured agent's name and status. |
| **Today** | Notifications, approvals, proposals, recent work, and items waiting for the user (the Activity page). |
| **Memories** | Search, review, edit, pin, delete, consolidate, and inspect durable MemoryV2 facts. |
| **Desk** | Line up large projects, dependencies, bridge work, schedules, research, agent pursuits, approvals, progress, verification, and outcomes. |
| **Providers** | Connect an AI account; optionally tune models and per-surface preferences. |
| **Trust** | Trust modes and approvals; the **Mac integration** tab holds individual Mac-service access. |
| **Personality** | Identity and voice, with tabs for model choices and Dreams. |
| **Connectors** | Service connections, with **MCP**, **Telegram**, and **iPhone** tabs. |
| **Diagnostics** | Health and detailed status, with **Cognition**, **Skills**, and **Tools** tabs. |
| **Settings** | Appearance, shortcuts, updates, help, **An inner life**, and **Memory in every reply**. |

**Classic sidebar note:** **Settings → Appearance → Use the classic sidebar**
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
preferences or goals in Activity or Memories before treating them as durable.

## Skills, tools, MCP, and connectors

NativeAgent keeps ordinary turns small by loading capabilities lazily.

- The agent always receives a compact tool and skill contract.
- `tool_catalog` or `list_tools` discovers capability names and groups;
  `tool_load` activates only what the current session needs.
- With **Full Mac YOLO** active, the complete native operator set—files, shell,
  Git, patching, builds, Mac control, and related maintenance tools—is available
  on the next turn without `tool_catalog`, `tool_load`, or an app restart.
  External-service readiness and protected safety floors still apply.
- `list_skills` lists compact procedure summaries; `read_skill` loads one
  relevant body; `save_skill` is the canonical creation/update path.
- Skills may recommend a procedure but cannot grant tools, permissions,
  approvals, or safety authority.
- MCP servers translate external protocol calls into the same bounded action
  and verification language as native tools. A protocol response is evidence,
  not proof that an external effect settled.
- Connectors provide explicit setup for services such as Telegram, Slack,
  GitHub, Gmail, Google Calendar, Notion, and X. Credential presence alone is
  not a successful connection; NativeAgent requires the provider's applicable
  validation path.

For app-only/public installations, the safe default for file, shell, Git,
patch, and build work is:

```text
~/Library/Application Support/NativeAgent/workspace
```

A verified source-backed developer install uses the checkout's `workspace/`.
Every chat surface and the Desk resolves the same canonical workspace for
relative paths and ordinary trust modes. With Full Mac YOLO active, the agent
may explicitly select an existing absolute project elsewhere on the Mac for
native shell/build work or a Codex/Claude Code handoff. NativeAgent validates
that directory again at dispatch time; protected system and credential/
authority paths do not become valid coding roots.

macOS privacy permission is separate from NativeAgent trust. On a new Mac, a
project under **Documents**, **Desktop**, **Downloads**, Mail, Messages, or
another protected location may require an Apple consent prompt or a manual
grant in **System Settings → Privacy & Security → Files & Folders**. If the
project must span multiple protected locations, grant **Full Disk Access** to
NativeAgent and relaunch it. Full Mac YOLO removes NativeAgent's workspace and
routine-approval restriction; it cannot silently grant itself macOS TCC
authority. Projects in ordinary user-owned locations do not need this extra
Apple permission.

## Trust modes and approvals

TrustCenter remains authoritative on every surface, including Telegram,
Slack, iPhone, and delegated or swarm work.

- **Workspace** keeps file work inside approved workspace roots.
- **Full Mac** allows broader file and Mac access for a time-bounded confirmed
  session.
- **Developer Mode** enables explicitly development-only behavior immediately after saving;
  it is not required for the normal Full Mac operator set and does not erase
  protected floors.
- **Full Mac YOLO** takes effect on the next turn and removes routine approval
  and lazy-discovery friction within its policy. It also permits an explicit
  external project cwd for native or delegated coding work, but
  external sends, money actions, self-modification application, protected OS
  mutations, connector proof, effect-time validation, and hard security checks
  retain their authority.

If approval is requested, resolve the exact item in **Activity**. A pressed
Approve button is not success until the action produces its terminal receipt
and, where applicable, domain verification.

## Desk, background work, and swarms

- Put durable multi-step work on the **Desk**. One Desk identity follows the
  task through planning, execution, pauses, verification, and completion.
- The agent's own pursuits use a restricted Desk work membrane rather than an
  unrestricted hidden chat.
- Background loops handle event-driven maintenance, messaging, snapshots,
  notifications, dreams, memory hygiene, and scheduled work. Quiet operation
  should perform no model work unless a real event or due boundary requires it.
- Swarms are temporary parallel workers inside the same runtime. They use the
  Swarms provider default unless explicitly specialized, start read-only by
  default, and gain no authority beyond the parent turn.

## iPhone and iPad

1. Install NativeAgent Mobile and keep the Mac and mobile device signed into
   the intended iCloud account.
2. On Mac, open **Connectors → iPhone** (classic sidebar:
   **Settings → Pair iPhone / iPad**).
3. On mobile, choose **Connect via iCloud** after the Mac pairing record arrives.
   Manual paste also verifies the key against that published record; it cannot
   bypass missing iCloud material. If verification is waiting, keep the pairing
   screen open and retry after the record arrives. Treat the key as a secret.
4. Enable NativeAgent notifications in iOS Settings.

Mobile supports chat, sessions and pins, attachments, model controls, Activity,
approvals, Desk, memories, Skills & Tools, runtime status, organism status,
signed remote actions, and lock-screen notifications. The Mac must remain
available to run provider turns and tools. See
[mobile_companion.md](mobile_companion.md) for transport detail.

## Telegram, Slack, and local bridges

- Configure Telegram in **Connectors → Telegram** and other services in
  **Connectors**. In the classic sidebar, use **Settings → Telegram** and
  **Settings → Advanced → Connectors**.
- Each surface has a scoped session but uses the same persona, memory, Fluid
  Context, provider policy, tools, trust gates, and receipts.
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
  background loops.
- **Diagnostics → Status / Runs Log** shows runtime and execution state.
- **Diagnostics → Cognition** shows Fluid Context and Organism readouts.
- **Activity** is the first place to check approvals, warnings, and work waiting
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
