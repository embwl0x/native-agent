# NativeAgent user and agent guide

Start with a conversation. Connect services and grant access as the work needs
them.

## First setup

1. On macOS 26 or newer, download the DMG from the
   [releases page](https://github.com/embwl0x/native-agent/releases), drag
   NativeAgent to Applications, and open it.
2. Enter your name and the agent's name.
3. Connect an AI account or add an API key. You can skip this step and connect
   later in **Providers**, but chat needs a connected account.

### Simple, Advanced and Agent

- **Simple** presents chat, the agent's contacts and its helpers. Ask the agent
  to configure the app. The panel's gear offers appearance controls and
  **More settings…**, which opens Settings in Advanced.
- **Advanced** exposes the pages below.
- **Agent** shows the agent's own desktop read-only.

A fresh install starts in Simple. An install with existing chats defaults to
Advanced. Page names in this guide refer to Advanced.

Providers has three groups: **Chat**, **Work**, and **Memory and mind**.
Work and Memory and mind inherit Chat unless you set a **Custom choice**.
**Use Chat's choice** restores inheritance. The group determines the account
and model used by its activities; an unusable saved choice is reported.

## Optional background and memory settings

In **Settings**, **An inner life** controls the inner-life master setting,
and **Memory in every reply** selects Active or Off for Fluid Context.
The memory controls also cover dreams, consolidation and meaning-based recall.
Use **Diagnostics → Cognition** to inspect the current state.

Remembered context and inner state do not grant action authority. Trust remains
the owner of permissions.

## Turn on Mac computer control and the activity watcher

For screen control, grant NativeAgent macOS **Accessibility** and, for pixel
perception, **Screen Recording**, then choose the appropriate **Trust** mode.
The agent reaches the Mac through `app` actions such as `mac.look`,
`mac.act`, `mac.go` and `mac.wait`. Available evidence and permissions
determine what it can do; a successful input is not by itself proof of the
intended result.

Chrome uses the optional bundled extension. Open its setup from **Trust** and
follow the [extension guide](../Extensions/NativeAgentChrome/README.md).
Chrome tab actions and NativeAgent's built-in browser are available through
the Browser page of `app`.

The activity watcher has its own **Record which apps you use** control in
Trust. Recording is off by default. It records app names and durations;
redacted window titles require separate opt-in. It does not record screenshots
or typed content. Full Mac permits recorded-activity answers in trusted chats;
narrower modes require **Let me answer from activity history**. Answers reach
the selected provider.

## Main Mac pages

| Place | Use it for |
|---|---|
| **Chat** | Conversations, sessions, attachments, voice and turn progress. |
| **Today** | Notifications, approvals, proposals, recent work and items waiting for you. |
| **Memories** | Saved facts, pending proposals and the **Knowledge graph** tab. |
| **Desk** | Projects, dependencies, schedules, pursuits, progress and outcomes. |
| **Notifications** | Proactive inbox, triggers, watched folders and history. |
| **Helpers** | Standing bots, their briefs, schedules or event triggers, and replies. |
| **Personality** | Identity, expression, about-you, growth and working guidelines; **My minds** and **Dreams** tabs. |
| **Providers** | AI accounts and the model choices for Chat, Work, and Memory and mind. |
| **Trust** | Access presets, feature permissions and approvals; **Mac integration** for individual Mac services. |
| **Connectors** | Service setup and the **Agents**, **MCP**, **Telegram** and **iPhone** tabs. |
| **Capabilities** | Capability inventory and **Show all actions**. |
| **Diagnostics** | Health checks, Status, Run history, Cognition, Chat turn details, Skills and Tools. |
| **Settings** | Appearance, shortcuts, updates, inner life and memory settings. |

### The agent reading and setting these pages, quietly

NativeAgent is the agent's one always-on tool, `app`. A normal page read or
setting change runs in process without bringing the window forward. Actions
that move the screen or make sound are marked `screen`.

| Call | Meaning |
|---|---|
| `app {}` | Home: where I left off, open work, what waits and what arrived, followed by the page index. |
| `app {"page":"desk"}` | Read a page, its version and available actions. |
| `app {"item":"…"}` | Open or act on an exact name or reference returned by home. |
| `app {"find":"disconnect telegram"}` | Find matching pages and actions by intent. |
| `app {"action":"…","args":{…}}` | Run an advertised action with its named arguments. |
| `app {"script":"return app.read('desk');"}` | Run bounded JavaScriptCore code using the app API. |

Home items can perform actions; follow the item's returned instructions.
For an action, `preview:true` reports what it would do without doing it.
`expected_version` refuses the action if the current page version differs
from the read.

Scripts can use `app.read`, `app.find`, `app.log` and the registry's
scriptable actions, such as `app.inbox.archive(args)`. They have no direct
file or network access. Each call is checked separately. A blocked action or
one waiting for approval stops the script; earlier completed calls stay done.

Page reads are available in Safe. Ordinary setting changes require Work mode,
Builder or Full Mac. The returned page states which controls the agent may
change. Selecting Full Mac and granting macOS privacy access remain owner
decisions. See [Trust modes and approvals](#trust-modes-and-approvals).

## Memory, personality, and context

**MemoryV2** stores durable memories. **Personality** holds identity and voice
documents. The generated about-you document is a projection of memory; edit
the facts through **Memories**. The knowledge graph is an index over memory,
and Fluid Context prepares bounded material for a turn from the underlying
stores.

Tell the agent when a fact should be remembered, and review pending proposals
in Today or Memories. Skills capture reusable procedures; dreams and REM
consolidate experience. Neither a conversation nor a dream automatically makes
a statement a canonical fact.

## Skills, tools, MCP, and connectors

Everything the agent calls goes through `app`. Pages and `find` expose
actions when needed, without adding more tool schemas to each request.
The old catalog, loading and per-area tool calls are refused with a translated
`app` call. Work previously opened through the workspace tool is now in home.

- Skills provide guidance and optional admitted scripts. `skill.list` and
  `skill.read` find and read them; `skill.save`, `skill.enable`, `skill.run`,
  `skill.resume` and `skill.rollback` manage scripted procedures. They grant
  no new authority. See the [manifest spec](skill_manifest_spec.md).
- To author a capability, use `tool.propose`, then `tool.approve`. An
  activated tool appears as `authored.<id>`. Approval follows the current
  [Trust and peer-turn rules](#trust-modes-and-approvals), including the
  exemption for agents enabled in Trust.
- Mounted MCP tools appear as `mcp.<server>.<tool>` actions on the MCP page.
  Their availability depends on the server and its connection.
- `web.search` tries Codex web search for general queries and SearXNG for
  code queries. Unfiltered searches try the other route if the first fails or
  returns no results, and the result explains the fallback. Non-general
  categories and time ranges use only SearXNG.
- Service connections live in **Connectors**. Authentication and service
  permissions still apply when an action is available.

In **Connectors → Share a folder**, enter a name, click **Choose folder…**,
select the folder, choose whether to enable **Let me write to it**, then click
**Share this folder**.

The [app tool contract](TOOL_LOADING.md) defines this interface. For file work,
the default folder on an app-only install is:

```text
~/Library/Application Support/NativeAgent/workspace
```

Source-backed installs use the checkout's `workspace/`. Every surface uses
the same resolver. Full Mac can authorize work in an explicitly selected
project elsewhere; Apple's privacy permissions still apply to protected
locations.

## Trust modes and approvals

| Preset | Access |
|---|---|
| **Safe** | Read files; no changes or Mac control. |
| **Work mode** | Edit approved workspaces; no outside writes or shell. |
| **Builder** | Edit workspaces; ask to write outside; no shell. |
| **Full Mac** | Files anywhere, shell, system control, move or trash. |

Choosing Full Mac asks for confirmation. It stays on until the mode changes;
there is no timer. For admitted turns, Full Mac grants the agent autonomy
without routine per-action approval. Explicit blocks, origin checks, service
authentication and macOS permissions remain in force.

**Resetting macOS privacy permissions always asks the owner first**, including
under Full Mac.

**Agents enabled in Trust → Connected agents carry User's authority on
authenticated turns.** They do not receive extra peer approval requirements;
ordinary Trust, domain, service and macOS permission checks still apply.

**Other peer-steered turns have an additional boundary.** Under Full Mac, deletes
and irreversible acts, sends or posts in the owner's name, persona writes and
approvals still raise the owner's card. Routine conversation with a connected
peer is allowed. More restrictive Trust modes can require additional approvals.

Resolve requested approvals in Today. An approval authorizes a step; the
action's receipt and the service that owns the effect establish what actually
happened. Chat receipts show the outcome, with evidence under **Details**.

## Desk, background work, and swarms

Use **Desk** for durable multi-step work: dependencies, schedules, checkpoints,
approval pauses and outcomes stay with the task. A **held** row has a blocker,
defer or held ancestor; its reason explains what needs to change.

Background work is owned by the core's `BackgroundLoopsManager`.
Temporary swarms are available through `agent.swarm`; read-only workers
perform reasoning, while inherited access uses the parent's Trust and workspace
gates. Delegating work does not grant new authority.

## Helpers: standing bots

A helper has a name, brief, model and persisted conversation. It runs with its
saved model choice and the live Trust policy. A missing or invalid model
choice prevents a run.

Use **Run once** for an explicit request, or configure a schedule or a supported
GitHub/Slack event. **Pause** stops the helper's scheduled work. A brief does
not change permissions.

Scheduled and event-triggered helpers use **Trust → Self-Improvement → Let me
work unattended**. Turn it off to stop unattended runs outside Full Mac. Under
Full Mac, change the access mode instead. **Run once** remains available.

The helper's page shows run replies and session activity. **Continue in Chat**
opens that helper's conversation with its own model choice. See
[Automated systems](AUTOMATED_SYSTEMS.md) for background ownership.

## iPhone and iPad

1. Keep NativeAgent open on the Mac and use the same Apple Account on both
   devices.
2. On the Mac, open **Connectors → iPhone**.
3. On the phone, tap **Check for Mac** if pairing details have not arrived,
   then **Connect**. If a phone code is shown, match it on the Mac and choose
   **Pair**, then connect again.

The phone reaches the same Mac runtime through signed iCloud transport.
Keep the Mac awake for replies. See [Mobile companion](mobile_companion.md)
and [iPhone approval pairing](ios-device-pairing.md) for transport and pairing
details.

## Telegram, Slack, and local bridges

Configure messaging services under **Connectors**. Each surface keeps its
conversation origin while sharing the engine's context, provider and action
policy.

Local bridge clients read `~/.config/claude-bridge/bridge.json` for the
current loopback URL and bearer token. Do not hardcode a port. See
[Agent conversations](agent-communication.md) for connected peers and
[Codex bridge](CODEX_BRIDGE_DIAGNOSTICS.md) for diagnostics.

### Codex and Claude Code as specialist builders

The agent can hand a bounded work order to a local coding session through
`app`: `codex.message` for Codex, and `claude.say` from home for Claude Code.
Install and sign into the corresponding coding product on the Mac; the
bundled bridge workers also require Node.js.

Codex distinguishes new work from an explicit resume using the returned
conversation identity. Claude Code keeps topic-scoped session continuity.
The work order should name the project and requested outcome. The builder
inspects the repository in its own coding environment.

The result returns to the originating conversation. A builder's reply is
evidence to assess, not proof of completion by itself. Check the resulting
files, receipts and any external service involved before claiming success.

## What the configured agent should do

1. Start at `app {}` when resuming work; use returned names and references.
2. Read pages or use `find` for the action and its arguments. Do not load
   tools or crawl private registries.
3. Use `memory.commit` for durable facts and `skill.read` for relevant
   procedures. Expand only the context pointers offered for the current turn.
4. Put work products in the canonical workspace and durable work on Desk.
5. Follow the originating session's Trust, approval and service checks.
6. Verify the outcome through the owner of the effect; do not equate a queued
   request, approval click or protocol response with completion.

## Health and troubleshooting

- **Diagnostics → Health checks** inspects system health.
- **Status**, **Run history** and **Chat turn details** expose runtime and turn
  evidence; **Cognition** exposes the inner-state and context views.
- **Today** shows approvals and work waiting on the user.
- **Settings** contains update controls.

For installation, permissions, provider and data-removal help, see
[Support](../SUPPORT.md). Keep credentials, pairing keys and private content
out of public reports.

## Honest boundaries

NativeAgent's provider requests and configured services can send selected data
off the Mac. A capability still needs its permissions and a working connection.
The [capability map](CAPABILITIES.md) names the source owners and limits;
[Project Status](../PROJECT_STATUS.md) describes this checkout.
