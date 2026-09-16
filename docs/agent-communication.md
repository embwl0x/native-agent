# Agent conversations

NativeAgent exposes a small conversation interface over the agents it already
owns and explicitly configured peers. Find an agent once, address its stable
reference, carry its conversation identity forward, and read its replies.
No directory entry grants permission or proves the agent is online.

## Agent-facing tools

Load the `agents`/`delegation` category or the individual tools as needed.
Natural subagent discovery also includes the conversation tools.

- `agent_contacts`: list local coding agents, standing bots, and configured peers.
- `agent_connect`: add a remote contact with a display name and endpoint. Omit
  transport (or choose `auto`) for bounded supported-protocol discovery;
  an optional bearer credential is stored in that contact's dedicated Keychain entry.
- `agent_message`: send `agent` and `text`, optionally continuing the exact returned
  `conversation_id`. Local coding options live in `options` and are checked against
  that executor's actual capabilities.
- `agent_read`: retrieve the exact returned receipt/task identity or a supported
  local listing. No background polling or automatic resend is introduced.
  Default output is a compact conversation view: who replied, their text,
  recorded execution/delivery state and an exact `reply_with` action when the
  source retains a supported conversation handle. Set `details: true` to inspect
  the original technical receipt. An acknowledgement is never promoted into
  completed work. Coding text is explicitly a retained excerpt; bot listing
  headlines are previews with exact-entry recovery. NativeAgent reply pages carry
  `read_more`. Missing requests/handles remain missing, never borrowed from the
  latest conversation. This is a read projection, not another transcript store.
  Codex delivery assessments are distinguished from original executor text;
  original text is preferred when retained. A delivery-only record is labeled
  as such. Bot display names accompany stable addressing identities.
  Pass null for fields that do not apply to the selected adapter; strict provider
  schemas explicitly permit this, including unused coding options.

References are `codex`, `claude`, `omp`, `bot:<UUID>`, and `peer:<UUID>`.
Display names are labels, not identity. Bots retain their persistent session.
Codex/Claude/OMP continue through the existing bridge owners and receipts. A
failed resume never falls back to creating another conversation. Both the facade
and the executed tool's explicit policy rules apply before execution.

Coding-agent reads accept `message_id` or a bounded recent listing; they do not
accept a conversation filter. Bot exact reads verify the expected bot before
marking the shelf entry read. Existing shelf cursor tools remain available for
paging larger bot histories.

## Remote interoperability

For `transport: a2a`, the endpoint is the peer's agent-card URL. The client chooses
an explicitly advertised supported interface: JSON-RPC for A2A 1.0 or 0.3, or
HTTP+JSON for 1.0. It sends the negotiated version and validates response identity.
See the [A2A specification](https://a2a-protocol.org/latest/specification/) and
[discovery contract](https://a2a-protocol.org/latest/topics/agent-discovery/).

The supported exchange is text SendMessage and GetTask, including task parts,
artifacts and lifecycle evidence. Carry `contextId` as `conversation_id` and
`taskId` as `task_id`; a conversation and a task are different identities.
A direct message reply is returned by the send operation; A2A has no GetMessage
endpoint in this client. Streaming, push notifications, gRPC, cancellation,
list-tasks, uploads, OAuth negotiation, and required extensions are not advertised
as implemented. Future adapters must preserve this same conversation contract
and retain their own execution authority.

For `transport: nativeAgent`, the endpoint is the NativeAgent bridge base URL.
Authenticated `/agent/card`, `/agent/message`, and `/agent/reply` share the existing
loopback bridge and chat admission pipeline. This is the `nativeagent-bridge` 1.0
adapter. A caller outside
the Mac needs its own authorized secure route to the loopback bridge; this change
does not expose a public listener or create a tunnel.

### Other agents connecting to Agent

The same listener also exposes an authenticated A2A 0.3 card at
`/.well-known/agent-card.json` and JSON-RPC at `/a2a`. Supported operations are
text `message/send` and `tasks/get`. Sends acknowledge submitted work, and the
returned task ID identifies canonical retained reply evidence. Continue the
returned `contextId` for a new turn in the same full Agent session. Arbitrary
human-chat IDs cannot be used as A2A contexts. Streaming, task resumption,
cancellation and push are not advertised. Missing evidence is explicitly
uncertain; it never authorizes a resend or becomes invented completion.

For MCP clients, `/agent/mcp` implements stateless Streamable HTTP with JSON
responses: initialize, ping, tools/list and tools/call. Its two tools are
`agent_message` and `agent_reply`. MCP conversations use their own persistent
session namespace, while persona, memory, context assembly and tool gates remain
shared. The transport supports protocol versions 2025-11-25, 2025-06-18 and
2025-03-26; clients supply both `application/json` and `text/event-stream` in
Accept. Notifications receive empty HTTP 202; GET has no SSE stream and returns
405. Origins, authentication and protocol headers are checked. A transport
session is distinct from the explicit conversation ID returned by the chat tool.

Connection details come from the live bridge descriptor; do not assume port
8771 or paste its token into conversations. Local clients can use the installed
`nativeagent-link` command to resolve that descriptor privately. Remote clients
need an explicitly authorized route to the Mac; these adapters do not open one.

Primary contracts: [A2A 0.3](https://a2a-protocol.org/v0.3.0/specification/),
[MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports),
[MCP tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools).

### Connection discovery and future adapters

Automatic setup probes only the supplied origin and bounded standard card paths;
it never sends a message during discovery. A valid supported card pins the
transport and endpoint in the existing contact store. Failed or ambiguous
discovery leaves saved contacts untouched and explains what setup is missing.
Configured, advertised-compatible, reachable and replied are different facts.

Future adapters must preserve stable recipient identity, persistent conversation
identity, per-message recovery, honest outcomes and existing authority gates.
They translate into the shared conversation interface rather than creating a
brand-specific persona, transcript owner, task scheduler or memory runtime.
Neither an arbitrary website nor a model API is automatically a full agent.
An application with no programmatic interface needs its own interaction route;
capability discovery must never claim compatibility it has not established.

Desktop contacts provide that route without a brand-specific driver. Configure
`transport: desktop`, the exact `app_bundle_id`, and an optional
`conversation_label`. The existing address book stores the intended destination.
The live app handles `agent_message` and `agent_read` internally through a bounded
desktop operator using the existing gated Mac controls. Agent receives observed
reply text, delivery state and reply/read actions, or a plain blocker. The Core
projection is only an internal plan; its `requires_interaction` is consumed by
the app, not handed to Agent as a clicking checklist. Automatic operation needs
an exact conversation label. The operator can select only that label, type only
the exact outgoing message once, and submit once; it stops if focus changes or
permissions, drafts, or recipient identity need attention. No saved coordinates,
shell commands, permission changes, or second transcript owner are involved.
A desktop label is not a verified protocol conversation ID or proof of delivery.
Ordinary app authentication and approvals still apply.
Desktop send results associate reply text with the exact outgoing message using
observed order and expose `in_reply_to`; a standalone read explicitly represents
the visible conversation, not an exact protocol receipt. Older matching reply
text before the new outgoing message cannot satisfy send verification.
Future adapters follow the same contract: connection-specific routine work is
executed beneath message/read, not returned as instructions for the speaker.

### Local command and stdio clients

The app bundle includes `~/Applications/NativeAgent.app/Contents/MacOS/nativeagent-link`.
Its `message` command accepts text and optional `--session`/`--request` identities;
`reply --session <returned-id> --request <returned-id>` recovers the response,
with `--offset` for another page. It assigns identity before sending and does not
resend automatically after an uncertain outcome. Credentials stay inside the
helper, which reads only the private live bridge descriptor and uses loopback.

For a client that supports stdio MCP servers, configure that executable as the
server command with argument `mcp`. For HTTP MCP clients, use the authenticated
live `/agent/mcp` URL instead. Both reach the same app-owned full chat session;
the helper is not another server, agent runtime or memory store. Installing the
helper does not grant another agent additional local-execution permissions.

Generic messages acknowledge durable enqueue and finish through the same full
chat turn owner used for User's conversations. Agent receives their active persona,
normal relevant memory assembly, recall/search tools, Fluid Context, cognition and
persistent session history. Agent authorship is retained; ordinary Trust gates
and the bridge's existing external-MCP restriction remain in force.

Omitting the conversation starts a fresh persistent session. Continue by carrying
its exact identity; invalid supplied identities are rejected. The NativeAgent
outbound adapter assigns this identity before sending, so a lost acknowledgement
still leaves a request/session pair for recovery. Generic inbound callers that
omit an identity receive a new one in the acknowledgement. Legacy named bridge
endpoints retain their existing selected-session semantics.

Both request and session identities are required for NativeAgent reply recovery.
Caller request IDs are correlation identifiers, not idempotency guarantees.
Recoverable receipts include `read_with` containing the exact `agent_read` input;
coding-agent reads use message identity, NativeAgent uses request plus session,
and A2A tasks use task identity. No locator is invented for A2A direct messages.
The unified schema uses bounded default reply pages and `offset` continuation.
Never resend solely because an acknowledgement or reply is missing.

## Honest outcomes and bounds

Queued, enqueued, running, replied, completed, input-required, failed, and unknown
remain distinct. Only an explicitly completed A2A task is reported as completed;
a reply or HTTP 200 alone does not prove a delegated action succeeded. Interrupted
sends retain available request/context identities and report uncertainty, without
retry or protocol fallback. Remote payloads are untrusted evidence, not tool or
permission instructions.

Peer configuration has one owner, `AgentPeerStore`, in `agents/peers.json`; it
contains references to credentials, never their values. Corrupt configuration is
preserved and fails closed. Dedicated credentials cannot point at provider keys,
and synthetic app roots cannot access the live Keychain. Trace redaction masks
credential arguments; responses mask the exact credential too.

HTTP capture is bounded to 2 MiB, uses an ephemeral session without ambient
cookies or credentials, rejects redirects, and permits HTTPS or exact loopback
HTTP. Advertised A2A interfaces must stay on the configured card's origin.
Unsupported authentication fails before message dispatch.

NativeAgent reply recovery scans only the existing retained receipt stream, at
most 16 MiB with 1 MiB rows, and returns at most 16,000 characters per page. It
requires exact request/session identity; duplicate, malformed, unreadable, changed,
or oversized evidence is incomplete, never an assertion that a request failed or
never ran. There is no new transcript, ledger, scheduler or retry queue.

## Owners

`AgentConversationRouting` and the outer canonical dispatcher own local translation
before gates. `SwiftToolDispatcher+AgentCommunication` owns the facade's directory,
configuration and remote exchanges. `AgentPeerStore` owns contacts,
`AgentPeerHTTP` owns bounded transport, `AgentPeerCredentials` owns dedicated keys,
and `AgentA2AWire` owns pure protocol negotiation/projection. `ClaudeBridge` retains
the sole inbound listener and receipt recovery. Existing bots, TrustCenter, builder
bridges, and session persistence keep their responsibilities.
