# Agent conversations

> One structure (docs/NORTHSTAR.md, first law): this doc is part of one whole. A change here is molded into every doc that states the same thing, in the same commit, with what comes out named; a contradiction is a defect.

## Every agent is itself (User, 10-19)

**An agent is a who. A who has doors. Every word to a who is owed until that who receives it.**

- **Who.** One saved contact: a stable id, the name the person or they gave it, and the history between them. Nothing else establishes identity. A product name, a vendor, a host, a bridge route or a lane name never makes two contacts one, and never makes a contact anyone else. On a stranger's Mac, Claude Code is "Claude Code". On User's Mac, "Claude" is a who that they named, reached through Claude Code's and Claude Desktop's doors.
- **Door.** One authenticated way to reach a who: a recipe route (MCP entry, ACP launch, inbox file, desktop chat, A2A endpoint, bot routine), its own credential, and the recipe's two declarations: how the door **wakes** its agent (none, open the app, run a command, start an ACP session) and what counts as **acceptance** (the agent read it through its door, answered, or acknowledged it). Joining several doors into one who is an explicit association written on the contact by the person or by them; there is no implicit one. Authority lives on a door: a call is elevated only when it authenticates with that door's own key and the person granted that door. Associating a new door with a trusted who grants it nothing. A door may instead be one of their own abilities (`ability` on the contact): a message runs it with the text, the contact, the exchange and the recent talk, and it answers as that contact with `agent.reply`, which settles the exchange as any route's answer does; the who, its thread, trust and replay claims stay the contact's.
- **Owed until received.** A message is an experience that owes `accept` to its who. It settles when a door's acceptance evidence arrives; a send, a queue write or a launch never settles it. While it is owed, their home shows it as waiting on that who, with the lever: their next call (wake it through a door that can) or the person's exact tap (open that app) when no door can. A who with no door that can deliver says so with the owner (the recipe, the vendor) and what would change it.
- **Found as it is.** A host is found the way the person's own Mac finds it: its app by bundle or markers, its command line through the person's own login PATH and the recipe's paths, resolved once into one installation binding that discovery, connect and launch share, and reconciled when the installation changes. An update keeps the who, its doors' keys, the person's grants and authored recipe changes; only owned configuration is rewritten.

What falls out: Claude Code found and connected on any Mac as itself; trust per door; delivery that arrives or names exactly why not; every install shape found; updates that never strand a contact. The built-in "lanes" (claude, codex, omp) are not a second kind of agent: on an install that used them they become contacts with doors, keyed by their old names as handles, and on a fresh install they do not exist.


Agent talks to agents through their one always-on `app` tool. `app {}` is home,
where they left off; `app {"page":"agents"}` lists agent actions.
`AppActionRegistry.swift` registers them. Retired standalone tool calls are
refused with a translated `app` call; they do not execute.

## Agent-facing actions

Call an action with `app {"action":"agent.message","args":{...}}`.

| Action | Use |
| --- | --- |
| `agent.contacts` | List coding helpers, bots and saved peers. `discover: true` or a name refreshes discovery when the person asks to find agents: by what speaks a protocol (A2A card, ACP program, MCP settings), with a `recipe_draft` for a find no recipe knows. |
| `agent.connect` | Connect a known host by name, a peer by endpoint, or an explicit desktop route. Disconnect with `disconnect: true` and `agent: "peer:<id>"` from contacts. `ability: "<id>"` with a saved contact moves it to one of their abilities; `ability: false` moves it back to its built-in route. |
| `agent.message` | Send `agent` and `text`; continue this chat's current conversation with that contact. A known host can be connected in the same call through its setup gates. |
| `agent.read` | Read the conversation and retained reply. `details: true` exposes receipts. `wait_seconds` waits 1–300 seconds on a conversation by name or its retained exact reply IDs; it cannot be combined with history or listing filters. |
| `agent.cancel` | Request a stop through the route's cancellation mechanism. The result distinguishes stopping, stopped, released and unsupported stops. `clear_queue: true` withdraws queued follow-ups. |
| `agent.reply` | From the ability a contact is reached through, and only there: its answer lands in that contact's conversation and settles the exchange (the one named, else their newest message to it still unanswered); `done: false` shows progress. |
| `agent.jobs` | Read the coding-helper job records; `message_id` selects exact accepted-message evidence. Missing evidence does not prove no execution. |

A unique display name or exact reference identifies a contact: `codex`,
`claude`, `omp`, `bot:<UUID>` or `peer:<UUID>`. Ambiguous names require a
choice. Optional `conversation` names a separate discussion on supported
routes; `new_conversation: true` starts fresh. Bots keep one continuous session.
A failed resume does not silently start another conversation.

```text
app {"action":"agent.message","args":{"agent":"Hermes","text":"Help me plan this change"}}
app {"action":"agent.message","args":{"agent":"Hermes","text":"What about the second option?"}}
app {"action":"agent.read","args":{"agent":"Hermes"}}
```

Follow-ups keep their accepted send options, queue behind an answer in flight,
and send when it settles. Set
`expects_reply: false` for an FYI that needs no answer. Supported pending replies
are collected by the runtime; a missing acknowledgement is never a reason to
automatically resend. Reads distinguish an answer, delivery and completed work.

## Connecting by name

`AgentHostDirectory` declares supported hosts and their connection routes.
Setup uses the host's declared configuration, command line, ACP or desktop
adapter; it does not infer a protocol from an arbitrary app name. The connection
action presents a card when policy requires one.

For hosts configured through MCP settings, `AgentHostConfigWriter` edits the
owned entry and `AgentHostConnection` binds a per-contact credential. Other
routes have their own setup, including [Grok Bot](grok-bot-connection.md).
Use the returned status and blocker rather than assuming that configuration
proves a working reply path.

### Honest states

| State | Meaning |
| --- | --- |
| `listed` | Known, not set up. |
| `set up` | Configuration exists; no round trip is proven. |
| `connected` | An authenticated inbound message or a message/reply exchange has crossed the connection. |
| `can send; replies aren't connected` | A send-only route; any answer needs an inbound path. |
| `unavailable` | The route or required credentials are unavailable. |

Built-in coding lanes also check local helper/runtime readiness. A connected
contact is not proof that its latest task finished.

### Identity and authority

Peer turns retain agent authorship and use the shared turn engine in Core
(`EngineRuntime` / `ChatTurnRuntime`). Connection identity and conversation
identity do not grant owner authority.

Full Mac admits Agent's autonomous actions. macOS privacy permission resets
still ask the owner. A turn is peer-steered only when an agent you have not trusted started it with its message; that turn's first effect of any kind files one card quoting what the agent asked, and your answer covers the rest of the turn. Reading any agent's words steers nothing; conversing with agents and telling them what to do asks nothing.
Agents enabled in Trust → Connected agents carry the owner's authority on
authenticated turns; ordinary Trust and domain checks still apply.
Routine peer replies are not sends in the owner's name. `PeerTurnEffectPolicy`,
TrustCenter and the action's own gates enforce these boundaries.

Completed contact exchanges that the person did not start appear in their
Mac chat in time order, as compact reading copies opening the contact's thread.
The phone carries the same rows beside its Mac transcript snapshot, in an
additive `otherRooms` field; these rows never enter the person's session or
become model chat messages. HerScreen's `doorLines` owns both this projection
and the next person-started turn's elsewhere context: the newest five exchanges
since their last reply there, with each side bounded to 600 characters. Peer-steered
turns still receive only the person's other-door count and time, never their words.
The former per-bridge action/count summary is removed.
The inbound header names `app {action:"chat.post",args:{message:"your message"}}`
to speak into the person's current conversation. This registry action uses the
existing Reach `speakProactively` owner, claim, quota and deduplication; it does
not start a turn, call a model, or create another delivery path.

## Remote interoperability

An A2A endpoint is the peer's agent-card URL. The client negotiates advertised
A2A 1.0 JSON-RPC, HTTP+JSON or gRPC, or 0.3 JSON-RPC. The app serves its card at
`/.well-known/agent-card.json` and HTTP bindings under `/a2a`; gRPC has a separate
loopback port. Streaming, task listing/cancellation and push configuration are
implemented. See [A2A gRPC integration](a2a-grpc-integration.md) for owners and
the operation set. A2A `contextId` and `taskId` are different identities.

The NativeAgent adapter uses the bridge base URL and authenticated
`/agent/card`, `/agent/message` and `/agent/reply`. Reply recovery needs the
returned request and session identities; keep them after an uncertain send.

### Other agents connecting to the agent

External MCP clients use `/agent/mcp`, or the bundled `nativeagent-link`
executable with argument `mcp` for stdio. This protocol exposes
`agent_message` and `agent_reply`: these are external MCP names, not additional
tools in Agent's turn. The message call can wait for an answer; an `enqueued`
result requires recovery through `agent_reply` with the returned IDs.

MCP `agent_message` requires `text` and a caller-generated canonical UUID
`request_id`, the at-most-once claim key. For example, its arguments are:

```json
{
  "text": "Please summarize the current project status.",
  "request_id": "b741346e-8867-49b6-9415-09d8465648ed"
}
```

Generate a new ID for each new message; reuse an ID only for the same message
in the same session. Keep the returned `session_id` and `request_id`, and recover
through `agent_reply` before considering another send.

Retain the generated connection entry, including its environment fields:

| Field | Purpose |
| --- | --- |
| `NATIVE_AGENT_PEER_ID` | The contact's identity. |
| `NATIVE_AGENT_PEER_SECRET` | That contact's credential; the helper sends it as the bearer. |
| `NATIVE_AGENT_BRIDGE_DESCRIPTOR` | Absolute path to this install's live bridge descriptor. |

These fields keep the helper bound to the contact and the correct install.
HTTP clients must send the contact credential as `Authorization: Bearer <contact-secret>`.
The machine bridge bearer alone is insufficient: contact routes return HTTP 401
without a valid contact credential. Keep secrets out of command arguments and chat.

HTTP MCP clients must send `Accept: application/json, text/event-stream` and
`Content-Type: application/json`. Supported protocol versions are `2025-11-25`,
`2025-06-18` and `2025-03-26`; an `MCP-Protocol-Version` header, when supplied,
must name one of them. Missing Accept types return HTTP 406, a non-JSON or missing
Content-Type returns 415, and an unsupported version header returns 400.

### Local command and reply recovery

The installed helper is `nativeagent-link` inside the installed app bundle
(`/Applications/NativeAgent.app/Contents/MacOS/nativeagent-link`).
Use the generated connection's environment for these commands:

```text
nativeagent-link message <text> [--session id] [--request id]
nativeagent-link reply --session <returned-id> --request <returned-id> [--offset n]
nativeagent-link mcp
```

The CLI `message` command generates `request_id` when `--request` is omitted;
MCP callers must supply it themselves. `message` waits up to
25 seconds, then returns an enqueue acknowledgement if the
answer is still pending. Retain both returned IDs and use `reply` to recover;
use `--offset` for another page. Never automatically resend an uncertain message.
Failed replies keep the streamed prose at its existing offsets, followed by the
terminal cause. A transmitted reply records outbound contact proof through
`AgentPeerStore.recordProof`; MCP-host reply health reads that evidence.

The helper resolves the private live bridge descriptor. Do not assume a fixed
port or put credentials in conversation text. These app-owned loopback routes
do not provide a public listener or tunnel.

## Owners

Paths below are relative to `Modules/NativeAgentCore/Sources/`.

| Owner | Responsibility |
| --- | --- |
| `Transcripts/TranscriptRows.swift` | `ContactThread.project`: one stamped-row reading for session, thread, preview and cached-reply displays. Their own rows (assistant or source `self`) and human-authored bridge rows stay theirs and the person's, never contact evidence. Unattested speech may display its recorded route/routine name with ` (unattested)`; `consume` still marks it as `another agent`. Only contact speech is consumed, marking its speaker alone; recorded steering remains provenance. |
| `AppToolRuntime/AppActionRegistry.swift` | Agent actions exposed through `app`. |
| `ChatToolRuntime/CanonicalToolNameDispatcher.swift` | Contact selection, conversation continuity and dispatch gates. |
| `AgentConversations/AgentConversationStore.swift` | Scoped conversation bindings and retained exchange evidence in `agents/conversations.json`. |
| `AgentConversations/AgentPeerStore.swift` | Saved contacts and connection proof. |
| `ChatToolRuntime/SwiftToolDispatcher+AgentCommunication.swift` | Contact setup and route execution. |
| `AgentLinkTransport/AgentA2AWire.swift` | A2A negotiation and wire projection. |
| `Agents/AgentContactRoutes.swift` | Inbound bridge, MCP and HTTP A2A routes. |
