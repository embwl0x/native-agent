# NativeAgent user and agent guide

This is the compact operating map for a NativeAgent installation. It is meant
for both the person using the app and the configured agent running inside it.
For implementation detail, see [CAPABILITIES.md](CAPABILITIES.md); for current
limitations, see [../PROJECT_STATUS.md](../PROJECT_STATUS.md).

## What NativeAgent is

NativeAgent is one Mac-owned agent runtime with several surfaces. The Mac app
owns provider calls, persona, MemoryV2, Fluid Context, tools, permissions,
Workshop, receipts, and background work. Mac chat, detached chats, iPhone and
iPad, Telegram, Slack, and authenticated local bridges all return to that same
runtime. The mobile app is a secure companion, not a second agent.

## First setup

1. Install and open NativeAgent on an Apple-silicon Mac running macOS 14 or
   newer, then complete onboarding.
2. Open **Providers**, connect at least one provider, and choose the provider,
   model, Think level, and Fast preference for ordinary chat. Provider choices
   for Telegram, Slack, Workshop, dreams, and swarms can be set independently.
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

## Main Mac pages

| Page | Use it for |
|---|---|
| **Chat** | Conversations, attachments, screen context, voice, provider/model controls, pinned sessions, detached windows, stop, send-next, and steering. |
| **Activity** | Notifications, approvals, proposals, recent work, and items waiting for the user. |
| **Memories** | Search, review, edit, pin, delete, consolidate, and inspect durable MemoryV2 facts. |
| **Workshop** | Create and follow multi-step tasks, agent pursuits, checkpoints, approvals, verification, and outcomes. |
| **Skills & Tools** | Switch between reusable procedures and the current trust-aware tool catalog. Skills guide behavior; tools perform gated actions. |
| **Providers** | Connect accounts and set provider, model, Think, and Fast choices per surface. |
| **Trust** | Select autonomy, Full Mac windows, Developer Mode, Workshop permissions, and protected action policy. |
| **Mac Integration** | Request macOS consent and control read/write access for individual Mac capabilities. |
| **Settings** | Pair mobile devices, configure Telegram, appearance, shortcut, chat compaction, embeddings, Subconscious, updates, and help. |

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

For app-only/public installations, all file, shell, Git, patch, and build work
belongs under:

```text
~/Library/Application Support/NativeAgent/workspace
```

A verified source-backed developer install uses the checkout's `workspace/`.
Every chat surface and Workshop resolves the same canonical workspace.

## Trust modes and approvals

TrustCenter remains authoritative on every surface, including Telegram,
Slack, iPhone, and delegated or swarm work.

- **Workspace** keeps file work inside approved workspace roots.
- **Full Mac** allows broader file and Mac access for a time-bounded confirmed
  session.
- **Developer Mode** enables shell, system control, and other developer-class
  operations after restart; it does not erase protected floors.
- **Full Mac YOLO** reduces routine approval friction within its policy, but
  external sends, money actions, self-modification application, protected OS
  mutations, connector proof, effect-time validation, and hard security checks
  retain their authority.

If approval is requested, resolve the exact item in **Activity**. A pressed
Approve button is not success until the action produces its terminal receipt
and, where applicable, domain verification.

## Workshop, background work, and swarms

- Put durable multi-step work in **Workshop**. One Desk identity follows the
  task through planning, execution, pauses, verification, and completion.
- The agent's own pursuits use a restricted Workshop membrane rather than an
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
approvals, Workshop, memories, Skills & Tools, runtime status, organism status,
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

## What the configured agent should do

1. Treat persona and MemoryV2 as identity/fact authority; use `commit_memory`
   for explicit durable facts rather than editing generated `USER.md`.
2. Use the compact manifest first, then `tool_catalog`, `tool_load`,
   `list_skills`, and `read_skill`. Do not crawl private registries or stuff the
   whole catalog into context.
3. Use only same-turn `context_expand` pointers when deeper Fluid Context is
   truly needed.
4. Put work products in the canonical workspace and use Workshop for durable
   multi-step execution.
5. Respect the originating surface, session, TrustCenter policy, approvals,
   connector proof, and effect-time checks.
6. Verify outcomes through the domain that owns reality. A model statement,
   tool envelope, MCP response, HTTP success, queued push, or approval click is
   not automatically a completed external effect.
7. Convert a repeated successful procedure into a reviewed skill or Workshop
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
