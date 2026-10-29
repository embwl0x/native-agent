# NativeAgent user and agent guide

> One structure (docs/NORTHSTAR.md, first law): this doc is part of one whole. A change here is molded into every doc that states the same thing, in the same commit, with what comes out named; a contradiction is a defect.

Start with a conversation. Connect services and grant access as the work needs
them.

## First setup

1. On macOS 26 or newer, download the DMG from the
   [releases page](https://github.com/embwl0x/native-agent/releases), drag
   NativeAgent to Applications, and open it.
2. Enter your name and the agent's name.
3. Connect an AI account or add an API key. You can skip this step and connect
   later in **Providers**, but chat needs a connected account.

First-run setup opens only after a successful eligibility read. A read failure
shows its cause and a **Retry** action; it does not automatically retry or
assume that setup is needed.
Setup reports a missing app model instead of aborting. Name suggestions do not
depend on narrowing the system clock to an integer. An empty tour has no current
stop and completes without indexing a missing step.

### Simple, Advanced and Agent

- **Simple** presents chat, the agent's contacts and its helpers. Ask the agent
  to configure the app. The panel's gear offers appearance controls and
  **More settings…**, which opens Settings in Advanced.
- **Advanced** exposes the pages below.
- **Agent** shows the agent's own desktop read-only.

A fresh install starts in Simple. An install with existing chats defaults to
Advanced. Page names in this guide refer to Advanced.
The `simple_settings_menu` page screenshot draws the same Settings items
above the sidebar's gear; offscreen capture does not open a native menu window.
Rail screenshots derive their tab selection without changing remembered tabs;
hidden-tab reconciliation and the legacy Trust tab migration run on live pages.
Screenshot height rejects nonfinite or invalid input before rendering. Status
uptime and contact elapsed time say unavailable when their values cannot be
represented; an invalid toast duration leaves a visible auto-dismiss error.

Providers has three groups: **Chat**, **Work**, and **Memory and mind**.
Work and Memory and mind inherit Chat unless you set a **Custom choice**.
**Use Chat's choice** restores inheritance. The group determines the account
and model used by its activities; an unusable saved choice is reported.
Thinking and Fast can be set independently while the group keeps following Chat's
model and account.
**Personality → My minds** edits the same Memory and mind group for reflection
and the daily hour. Changing its model keeps the group's Think level, adjusted
only to the selected model's supported choices.

## Optional background and memory settings

In **Settings**, **An inner life** controls the inner-life master setting,
and **Memory in every reply** selects Active or Off for Fluid Context.
The memory controls also cover dreams and meaning-based recall.
Use **Diagnostics → Cognition** to inspect the current state.

When meaning-based search fails, Memories displays the search owner's reason
even if word matches are available, and labels those rows **Word matches only**.
Knowledge graph time filters refresh at their next entity expiry while mounted,
and re-evaluate when the system clock, time zone or calendar changes.

Memories keeps Spotlight reindexing and **Check again**. The bulk
**Consolidate now** and **Run hygiene** controls and their report are retired.
Old memories fade from recall through disuse. Records can also be removed when
you ask to forget them or when the store exceeds its capacity (2,000 rows by
default): lower-value records go first, then the least recently used; pinned
and identity records go last. See [Data bounds](data-bounds.md).

Remembered context and inner state do not grant action authority. Trust remains
the owner of permissions.

While a tint-enabled window is visible, mood input follows cognition changes.
The room keeps its four-hour damping; five-minute display steps advance that
damping without rereading cognition. Hiding the last consumer stops both.

## Turn on Mac computer control and the activity watcher

For screen control, grant NativeAgent macOS **Accessibility** and, for pixel
perception, **Screen Recording**, then choose the appropriate **Trust** mode.
The agent reaches the Mac through `app` actions such as `mac.look`,
`mac.act`, `mac.go` and `mac.wait`. Available evidence and permissions
determine what it can do; a successful input is not by itself proof of the
intended result.
When Shotgun steps the main window aside for a screen operation, that operation
awaits the fade's completion directly. Bringing the window back during the fade
keeps it visible and still releases the waiting operation.

The Mac control badge and selected preset show effective Trust authority.
Category switches enable actions; your access mode decides when I ask.
While Full Mac is active, Advanced switches edit saved restricted-mode settings;
they do not turn Full Mac off. Change the access mode to leave Full Mac.
If a permission button cannot open System Settings, the Mac control pane shows
the handoff failure.
The iPhone notification setup button follows the readiness item's identity and
status, so changing recovery wording does not remove the route.

When a default `mac.look` finds NativeAgent in front, `behind` names the
person's app behind their when one is visible, so they can address it directly;
that app has not been read yet. After an act, an unchanged target surface
without press evidence is unobserved (`acted_unobserved`); a destination that
contradicts the intended one is a mismatch (`acted_mismatch`).

Chrome uses the optional bundled extension. Open its setup from **Trust** and
follow the [extension guide](../Extensions/NativeAgentChrome/README.md).
Chrome tab actions and NativeAgent's built-in browser are available through
the Browser page of `app`. `chrome.snapshot` reads a NativeAgent group tab's
text, or returns its picture with an explicit note when Chrome provides no DOM
access (including the PDF viewer). Internal pages (`chrome://`, `about:`) return
one line with the title, URL and "Chrome allows no reader on its internal pages"
(`read_mode: "none"`) from both snapshot and look, without a picture attempt.
For HTTP PDFs, the snapshot keeps both Chrome's verified picture and an
independent text transcript in the same receipt. The transcript is explicitly
unverified: it did not verify Chrome's displayed document or use Chrome's
cookies/authentication. Its failure or truncation is reported beside the picture.
`chrome.navigate` verifies
arrival from Chrome's completed tab and landed URL, independently of DOM access;
unsupported schemes such as `javascript:` and `data:` refuse before any tab moves.
`chrome.look` shows the picture Chrome renders now, including image
documents with no text. Omit `tab_id` for the conversation's remembered tab.
Looking never activates or moves the tab; pictures use the same model-turn
image slot as `files.read`, bounded to 2048 pixels with source dimensions kept.
`guide:chrome.look` on the Browser page describes the action. Chrome's temporary
debugging infobar is visible during capture; an unpainted hidden tab is refused.
`chrome.status` also lists the last eight tabs released in this app run, with
the reason and time they stopped being theirs. Ownership refusals say whether
the person selected the tab, it left the group, or it no longer exists.

The activity watcher has its own **Record which apps you use** control in
Trust. Recording is off by default. It records app names and durations;
redacted window titles require separate opt-in. It does not record screenshots
or typed content. Full Mac permits recorded-activity answers in trusted chats;
narrower modes require **Let me answer from activity history**. Answers reach
the selected provider.

## Main Mac pages

Holding ⌘⇧J starts push-to-talk after its hold delay. Releasing an active
recording ends capture even if the Mac's clock changed during the hold.

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
| **Connectors** | Service setup and the **Agents**, **Telegram** and **iPhone** tabs. |
| **Capabilities** | Capability inventory and **Show all actions**. |
| **Diagnostics** | Health checks, Status, Run history, Cognition, Chat turn details, Skills and Tools. **Expansion** lists, for each mind using the app, the follow-up reads its own practice makes next after a kind of result, and each one's record: tries, hits, its bar and standing, and how often the app ran, prepared or held one back. |
| **Settings** | Appearance, shortcuts, updates, inner life and memory settings. |

Today recognizes collaboration from recorded peer-bridge provenance, with
contact names resolved by the connected-agent directory. Unreadable contact
evidence is reported as unavailable. Approval requester names use the same
directory, including saved legacy bridge routes; route names do not override
the person's contact names.

### The agent reading and setting these pages, quietly

Notification trigger switches show a pending choice only while saving. When
the write ends, they show the inbox owner's current setting, including changes
made from another surface during the save.
Inbox surfaces read each distinct origin transcript once on arrival and per
invalidation; rows render that publication. `interaction_session_id` identifies
the origin; `chat_session_id` identifies its separate mirror destination.
An interaction note that cannot read its original card shows the lookup cause
and **Try again**, rather than disappearing as though it were answered.
If **Not now** cannot save a decline, the notice lane shows the owner's error.
**Mark all read** keeps failed updates and their causes in the open list, with
**Retry failed**; successful writes alone dismiss the list.

In **Diagnostics → Chat turn details → Replay**, a failed date read ends
loading and shows its cause. Any earlier cards remain labeled with the date
they actually came from.

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
Discovery ranks the registry's action descriptions and schemas with semantic
and lexical evidence; an exact action ID takes priority. A named page or Mac
integration puts its own actions next, in page order, and its page first in
the matching pages, using registered page IDs, titles, door aliases and
integration IDs (see [discovery](TOOL_LOADING.md)).
For example, `find:"Notes actions"` starts with Notes' search, create, update
and delete actions. The remaining matches keep their semantic and lexical
ranking; there are no feature-specific keyword routes.
For an action, `preview:true` reports what it would do without doing it.
`expected_version` refuses the action if the current page version differs
from the read.

Scripts can use `app.read`, `app.find`, `app.log` and the registry's
actions, such as `app.inbox.archive(args)`. They have no direct file or
network access. Each call is checked separately. A call that raises a card
waits for your answer; a blocked action stops the script; earlier completed
calls stay done.

Page reads are available in Safe. Ordinary setting changes require Work mode,
Builder or Full Mac. The returned page states which controls the agent may
change. Selecting Full Mac and granting macOS privacy access remain owner
decisions. See [Trust modes and approvals](#trust-modes-and-approvals).

## Memory, personality, and context

Panel refresh notices publish through a per-panel `LatestRead`: an older read
cannot clear a newer completed read's failure, and a canceled read publishes
no freshness or status claim. Each caller still receives its own read outcome.

**MemoryV2** stores durable memories. **Personality** holds identity and voice
documents. The generated about-you document is a projection of memory; edit
the facts through **Memories**. The knowledge graph is an index over memory,
and Fluid Context prepares bounded material for a turn from the underlying
stores.

Pinning or deleting a memory refreshes the Memories panel and reports the
committed mutation's result; it does not wait for a global app refresh.

The composer context readout formats percentages without integer narrowing
and signed token changes without taking an absolute value. Large recorded
counts remain visible, including usage above the selected window.

What you tell the agent about yourself, and what a trusted agent or the agent itself says,
is kept as a fact at once with where and when it was said; correct or forget it when it is wrong.
Facts from an agent you have not trusted wait in Today or Memories for review. Skills are built-in guidance;
dreams and REM consolidate experience. A dream never makes a statement a canonical fact.

Cognition's reflection records show an unavailable token total if the recorded
components overflow, retaining the individual prompt and result counts.

## Skills, tools, and connectors

Everything the agent calls goes through `app`. Pages and `find` expose
actions when needed, without adding more tool schemas to each request.
The old catalog, loading and per-area tool calls are refused with a translated
`app` call. Work previously opened through the workspace tool is now in home.

- Skills are built-in guidance: `ability.list` and `ability.read` find and read
  them.
- To author a capability, the agent grows an ability with `ability.save`. Under
  Full Mac their ordinary own save is kept and on at once;
  [practice-compiled abilities and their revisions](skill_manifest_spec.md#compiled-from-practice)
  must replay their recorded examples before anyone can keep them. Otherwise
  `ability.enable` asks you with a card (or keep it on the Tools page). A kept ability appears as
  `authored.<id>`; `ability.disable`, `ability.rollback` and `ability.drop` manage it.
  Abilities grant no new authority. See the [manifest spec](skill_manifest_spec.md).
  Keeping follows the current
  [Trust and peer-turn rules](#trust-modes-and-approvals), including the
  exemption for agents enabled in Trust.
- An MCP server is an ability the agent grows, a resident one keeping the
  server running; NativeAgent has no MCP page of its own.
- `web.search` searches SearXNG, every engine it has, and returns its results or its failure said plainly (no fallback; Doctor names a broken SearXNG); on a Mac without SearXNG the result hands their `browser_search`, the same search in a browser (Chrome through the extension when it is connected, else their own browser), which they runs and reads; a time range travels with either.
  In Research's search service settings, Find and Save run one at a time.
  Editing the URL while either runs preserves that edit; its earlier result
  cannot clear the new draft or replace its feedback.
- Service connections live in **Connectors**: the Slack and Telegram doors
  are set up there. Any other service is an ability the agent grows; its secret is
  granted once on a card the agent raises and kept in the keyring.
  **Connectors → Secrets** lists each kept secret by name, where it may go,
  its account and when it was granted; **Remove** deletes it.
  Authentication and service permissions still apply when an action is available.

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

Make's HTML previews stay offline and script-free within the selected
artifact's folder. File, revision and read folder publish together through
`LatestRead`; changing selection or closing the preview cancels pending WebKit
preparation, so an earlier load cannot replace the current artifact.
Quick Look construction failure is shown as an unavailable preview.
If the offline rule list cannot be prepared, Make keeps the artifact closed
and displays the sanitized WebKit cause.

## Trust modes and approvals

| Preset | Access |
|---|---|
| **Safe** | Read files; change nothing on your side; no shell or git. |
| **Work mode** | Edit approved workspaces; ask before sends or changes on your side; Mac control, shell and git need Full Mac. |
| **Builder** | Edit workspaces and ask before writing elsewhere; Mac control, shell and git need Full Mac. |
| **Full Mac** | Files anywhere, shell, system control, move or trash; deleting a contact, event or reminder still asks you. |

Choosing Full Mac asks for confirmation. It stays on until the mode changes;
there is no timer. For admitted turns, Full Mac grants the agent autonomy
without routine per-action approval. Explicit blocks, origin checks, service
authentication and macOS permissions remain in force.

**Resetting macOS privacy permissions always asks the owner first**, including
under Full Mac.

**Agents enabled in Trust → Connected agents carry the owner's authority on
authenticated turns.** They do not receive extra peer approval requirements;
ordinary Trust, domain, service and macOS permission checks still apply.

**An agent you have not trusted gets one card per command.** A turn such an
agent starts with its message files one card on its first effect, quoting what
it asked; your answer covers the rest of that turn. Reading any agent's words
steers nothing, and conversing with agents or telling them what to do asks
nothing. More restrictive Trust modes can require their own approvals.

Resolve requested approvals in Today. An approval authorizes a step; the
action's receipt and the service that owns the effect establish what actually
happened. Chat receipts show the outcome, with evidence under **Details**.

## Desk, background work, and swarms

Use **Desk** for durable multi-step work: dependencies, schedules, checkpoints,
approval pauses and outcomes stay with the task. A **held** row has a blocker,
defer or held ancestor; its reason explains what needs to change.
The [Desk vocabulary](DESK.md) describes its actions, person waits, paged reads
and the separate shared task ledger.

Background work is owned by the core's `BackgroundLoopLifetimes`.
Temporary swarms are available through `agent.swarm`; read-only workers
perform reasoning, while inherited access uses the parent's Trust and workspace
gates. Delegating work does not grant new authority.

## Helpers: standing bots

A helper has a name, optional personality, brief, model and persisted conversation.
Its own turn runner uses those instructions and its own conversation, with its
saved model choice and the live Trust policy. It can talk to the resident by
name through `agent.message`, receiving the reply in that call. A missing or
invalid model choice prevents a run.

Use **Run once** for an explicit request, or configure a schedule or a supported
Slack event. A run requested from a conversation returns there as one line:
the helper's name, actual success/failure/waiting status and
the exact saved reply to open with `bot.reply`. It uses the same durable
reply-delivery and arrival path as a peer answer, without another model turn
to summarize it. A rejected or interrupted request also keeps an exact shelf
record; it is never repeated to obtain a result. A run requested from the
helper's own page stays in that helper's conversation.

`bot.list`, `bot.run_once`, `bot.pause`, `bot.delete`, `bot.update` and `bot.ask`
use `id` for a helper's UUID or exact name. For example,
`app {"action":"bot.run_once","args":{"id":"Research helper"}}`.
Returned `read_with` calls name the registered `bot.reply` action.
**Pause** stops scheduled or event-woken work; a manual helper has no schedule
to pause or resume and refuses with `effects: none`. Run once and manual
messages remain available. Refusals before any write report `effects: none`.
A brief does not change permissions.
Deleting a helper excludes it from new runs and listings while retaining its
definition and audit so an already running job can save its result.

Scheduled and event-triggered helpers use **Trust → Self-Improvement → Let me
work unattended**. Turn it off to stop unattended runs outside Full Mac. Under
Full Mac, change the access mode instead. **Run once** remains available.

The helper's page shows run replies and session activity. Recorded durations
are formatted without narrowing to an integer; invalid durations are labeled.
`bot.replies {}` lists saved replies newest first, including already read
replies. Choose `sort: "oldest_first"` for ascending history, or
`sort: "oldest_unread"` for unread replies oldest first. `include_read: false`
selects unread replies in the chosen order. Reads acknowledge only when
`mark_read: true`; headlines stop at a whole word. Page with a zero-based
`offset` and returned `next_offset`, or a query-bound `cursor` and returned
`nextCursor`, keeping the same filters and sort. Use one paging form at a
time; changing unread state or new arrivals can change offset positions.
Helper-history reads and their continuation calls select a helper with `id`.
Saved calls using `bot_id`, `bot` or `name`, or the old `newest_first` ordering
field, remain accepted without a correction response.
**Continue in Chat**
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
Keep the Mac awake for replies. Your agent can ask you to share location, choose a
photo or take one while the phone app is active. Native Shortcuts offer Ask,
Remember, Approve, Status and Quick Ask. See [Mobile companion](mobile_companion.md),
[Siri actions](siri-notification-actions.md#iphone-and-ipad) and
[iPhone approval pairing](ios-device-pairing.md) for details.

## Telegram, Slack, and local bridges

Once Slack setup commits, its save settles the worker replacement and connector
refresh even if the setup sheet is dismissed. Cancellation suppresses later
wizard updates without skipping reconciliation of the saved configuration.

Configure messaging services under **Connectors**. Each surface keeps its
conversation origin while sharing the engine's context, provider and action
policy.
Telegram's **Check sender** reports the sanitized configuration or transport
failure returned by its owner, so a failure is not always described as a bad token.

The bundled `nativeagent-link` helper and HTTP agent clients read the agent
bridge's descriptor under `~/.config/nativeagent-link/` for the current
loopback URL; each contact sends its own credential. The older Claude/Codex
lane keeps `~/.config/claude-bridge/bridge.json`. Do not hardcode a port. See
[Agent conversations](agent-communication.md) for connected peers and
[Codex bridge](CODEX_BRIDGE_DIAGNOSTICS.md) for diagnostics.

### Codex and Claude Code as specialist builders

The agent can hand a bounded work order to a local coding session through
`app`: `agent.message` to the Codex or Claude Code contact; on an install
that set those lanes up, their older names `codex.message` and `claude.say`
still work as the same doors.
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
2. Call an action you know; the door returns its schema for a missing or invalid argument.
   Read pages or use `find` to discover actions; an exact action ID returns its
   arguments. Do not load tools or crawl private registries.
3. Use `memory.commit` for durable facts and `ability.read` for relevant
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
