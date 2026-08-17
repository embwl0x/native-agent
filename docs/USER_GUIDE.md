# NativeAgent user and agent guide

This is the compact operating map for a NativeAgent installation. It is meant
for both the person using the app and the configured agent running inside it.
For the connected context, memory, action, growth, delegation, and surface
lifecycles, see [NativeAgent Internal Workings](INTERNAL_WORKINGS.md). For the
product map, see [CAPABILITIES.md](CAPABILITIES.md); for current limitations,
see [../PROJECT_STATUS.md](../PROJECT_STATUS.md).

## What NativeAgent is

NativeAgent is one Mac-owned agent runtime with several surfaces. The Mac app
owns provider calls, persona, MemoryV2, Fluid Context, tools, permissions,
Desk, receipts, and background work. Mac chat, detached chats, iPhone and
iPad, Telegram, Slack, and authenticated local bridges all return to that same
runtime. The mobile app is a secure companion, not a second agent.

## First setup

1. Install and open NativeAgent on an Apple-silicon Mac running macOS 26 or
   newer, then complete onboarding.
2. Open **Providers**, connect at least one provider, and choose the provider,
   model, Think level, and Fast preference for ordinary chat. Provider choices
   for Telegram, Slack, Desk execution, dreams, and swarms can be set independently.
3. Open **Trust** and choose the least authority that fits the work. Trust mode
   controls what the agent may attempt; it does not replace macOS permission
   prompts, connector authorization, or protected safety floors.
4. Open **Mac Integration** and grant only the Calendar, Reminders, Contacts,
   Mail, Messages, Notes, Music, browser, screen, or app-control access wanted.
5. Start a chat. Ask naturally; NativeAgent selects relevant memory and lazy
   tools without requiring the user to name implementation details.

## Turn on the Subconscious and Organism

The Subconscious switch is the one user-facing master for the cognitive
substrate and Organism Kernel.

1. Open **Settings**.
2. Expand **Advanced**.
3. Turn on **Subconscious**.
4. Set **Fluid Context** to **Active** for resident context selection to feed
   replies. **Observe Only** measures selection without supplying it to the
   model; **Off** disables it.
5. Choose the model used for budgeted reflection. Ordinary conversation keeps
   its separately selected chat model.

When the status says **Running**, NativeAgent has enabled the bounded cognitive
capsule, background settlement, reflection budget, and Organism together. A
**Partially enabled** warning means setup, provider health, or a safety gate is
holding at least one lane off. To inspect the exact state, turn on **Settings →
Show Developer Surfaces**, then open **Diagnostics → Cognition**. Developer
Surfaces changes UI visibility only; **Trust → Developer Mode** is a separate,
security-sensitive execution setting that requires an app restart.

The Subconscious and Organism are advisory. They can shape attention, voice,
carefulness, and bounded background posture, but cannot grant permissions,
write canonical user facts, approve actions, or bypass TrustCenter.

## Turn on Mac computer control and the activity watcher

- Computer control (see, click, type): grant macOS **Accessibility** (and
  **Screen Recording** for `mac_view`'s picture) to NativeAgent, then open an
  active Full Mac window in Trust Center. Each injected action still requires
  its own one-time approval unless you enable full autonomy. Displayed
  secrets are redacted before the model sees the screen either way.
- Activity watcher: Trust Center -> capture tab -> enable. It records app and
  redacted window-title spans locally, nothing else, and only while enabled.
  Ask the agent "what was I working on yesterday" to use it. Disabling stops
  capture instantly; the data never leaves your Mac and the agent never
  memorizes it.

## Main Mac pages

| Page | Use it for |
|---|---|
| **Chat** | Conversations, attachments, screen context, voice, provider/model controls, pinned sessions, detached windows, stop, send-next, and steering. |
| **Activity** | Notifications, approvals, proposals, recent work, and items waiting for the user. Optionally, Journey presents learning, context receipts, workspaces, schedules, and capability readiness from their existing owners. |
| **Memories** | Search, review, edit, pin, delete, consolidate, and inspect durable MemoryV2 facts. |
| **Desk** | Line up large projects, dependencies, bridge work, schedules, research, agent pursuits, approvals, progress, verification, and outcomes. |
| **Skills & Tools** | Switch between reusable procedures and the current trust-aware tool catalog. Skills guide behavior; tools perform gated actions. |
| **Providers** | Connect accounts and set provider, model, Think, and Fast choices per surface. |
| **Trust** | Select autonomy, Full Mac windows, Developer Mode, Desk execution permissions, and protected action policy. |
| **Mac Integration** | Request macOS consent and control read/write access for individual Mac capabilities. |
| **Settings** | Pair mobile devices, configure Telegram, appearance, shortcut, chat compaction, embeddings, Subconscious, updates, help, and the presentation-only Journey switch. Return to Classic hides Journey without changing Fluid Context, the subconscious, memory, tools, trust, or schedules. |

The **Advanced** disclosure always includes **Personality** and **Connectors**.
With **Show Developer Surfaces** enabled it also exposes **Capabilities**,
**Knowledge Graph**, **Dreams**, **Diagnostics**, **Inbox Policy**, and **MCP**.
These pages inspect or configure the same runtime; they do not create extra
agents or alternate stores.

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
- **Developer Mode** enables explicitly development-only behavior after restart;
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
2. On Mac, open **Settings → Pair iPhone / iPad**.
3. On mobile, choose **Connect via iCloud**. Use the manual pairing key only if
   iCloud propagation is delayed; treat it as a secret.
4. Enable NativeAgent notifications in iOS Settings.

Mobile supports chat, sessions and pins, attachments, model controls, Activity,
approvals, Desk, memories, Skills & Tools, runtime status, organism status,
signed remote actions, and lock-screen notifications. The Mac must remain
available to run provider turns and tools. See
[mobile_companion.md](mobile_companion.md) for transport detail.

## Telegram, Slack, and local bridges

- Configure Telegram in **Settings → Telegram** and other services in
  **Advanced → Connectors**.
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

NativeAgent is local-first and single-operator, but provider requests and
configured connectors still send selected data to those external services.
The shell is not a security sandbox. The Organism and cognitive substrate are
bounded experimental layers. NativeAgent should not be the sole control for
medical, legal, financial, emergency, or other safety-critical decisions.
