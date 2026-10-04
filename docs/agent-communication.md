# Agent conversations

Agent talks to agents through them one always-on `app` tool. `app {}` is home,
where they left off; `app {"page":"agents"}` lists agent actions.
`AppActionRegistry.swift` registers them. Retired standalone tool calls are
refused with a translated `app` call; they do not execute.

## Agent-facing actions

Call an action with `app {"action":"agent.message","args":{...}}`.

| Action | Use |
| --- | --- |
| `agent.contacts` | List coding helpers, bots and saved peers. `discover: true` or a name refreshes discovery when the person asks to find agents. |
| `agent.connect` | Connect a known host by name, a peer by endpoint, or an explicit desktop route. Disconnect with `disconnect: true` and `name: "peer:<id>"` from contacts. |
| `agent.message` | Send `agent` and `text`; continue this chat's current conversation with that contact. A known host can be connected in the same call through its setup gates. |
| `agent.read` | Read the conversation and retained reply. `details: true` exposes receipts. `wait_seconds` waits 1–300 seconds on a conversation by name; it cannot be combined with exact IDs, history or listing filters. |
| `agent.cancel` | Request a stop through the route's cancellation mechanism. The result distinguishes stopping, stopped, released and unsupported stops. `clear_queue: true` withdraws queued follow-ups. |
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

Follow-ups queue behind an answer in flight and send when it settles. Set
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
still ask User. Peer-steered turns retain approval cards for deletes and
irreversible losses, sends in User's name, persona writes and approval actions.
Authenticated turns from agents enabled in Trust → Connected agents carry
User's authority and skip extra peer approvals; ordinary Trust and domain checks
still apply.
Routine peer replies are not sends in User's name. `PeerTurnEffectPolicy`,
TrustCenter and the action's own gates enforce these boundaries.

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

The installed helper is
`~/Applications/NativeAgent.app/Contents/MacOS/nativeagent-link`.
Use the generated connection's environment for these commands:

```text
nativeagent-link message <text> [--session id] [--request id]
nativeagent-link reply --session <returned-id> --request <returned-id> [--offset n]
nativeagent-link mcp
```

`message` waits up to 25 seconds, then returns an enqueue acknowledgement if the
answer is still pending. Retain both returned IDs and use `reply` to recover;
use `--offset` for another page. Never automatically resend an uncertain message.

The helper resolves the private live bridge descriptor. Do not assume a fixed
port or put credentials in conversation text. These app-owned loopback routes
do not provide a public listener or tunnel.

## Owners

Paths below are relative to `Modules/NativeAgentCore/Sources/`, except the
app route file.

| Owner | Responsibility |
| --- | --- |
| `AppToolRuntime/AppActionRegistry.swift` | Agent actions exposed through `app`. |
| `ChatToolRuntime/CanonicalToolNameDispatcher.swift` | Contact selection, conversation continuity and dispatch gates. |
| `AgentConversations/AgentConversationStore.swift` | Scoped conversation bindings and retained exchange evidence in `agents/conversations.json`. |
| `AgentConversations/AgentPeerStore.swift` | Saved contacts and connection proof. |
| `ChatToolRuntime/SwiftToolDispatcher+AgentCommunication.swift` | Contact setup and route execution. |
| `AgentLinkTransport/AgentA2AWire.swift` | A2A negotiation and wire projection. |
| `Sources/NativeAgentApp/AgentContactRoutes.swift` | Inbound bridge, MCP and HTTP A2A routes. |
