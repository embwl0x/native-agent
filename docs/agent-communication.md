# Agent conversations

NativeAgent exposes a small conversation interface over the agents it already
owns and explicitly configured peers. Address an agent by its unique contact
name, open the conversation, and speak. NativeAgent retains the exact route,
conversation and reply identities underneath that interface.
No directory entry grants permission or proves the agent is online.

## Agent-facing tools

Load the `agents`/`delegation` category or the individual tools as needed.
Natural subagent discovery also includes the conversation tools.

- `agent_contacts`: list local coding agents, standing bots, configured peers, and
  the agent hosts on this Mac that could be connected by name. Every row carries
  its honest state — see "Honest states" below.
- `agent_connect`: connect an agent by NAME, or add a remote contact with a
  display name and endpoint. With an endpoint, omit transport (or choose `auto`)
  for bounded supported-protocol discovery; an optional bearer credential is
  stored in that contact's dedicated Keychain entry. With a name and nothing
  else, the agent looks that name up among the agent hosts on this Mac and sets
  the connection up itself — see "Connecting by name" below. `disconnect: true`
  with the same name reverses exactly that setup.
- `agent_message`: send `agent` and `text`. This continues the contact's current
  conversation scoped to Agent's initiating session. Optional `conversation`
  selects a human label, creating a separate discussion when that label is new;
  `new_conversation: true` explicitly starts fresh. A rejected start preserves
  the old binding. Local coding options remain in `options` and are checked
  against that executor's actual capabilities.
- `agent_read`: open the contact's current conversation, or select an existing
  human label with `conversation`. NativeAgent resolves its retained exact
  reply locator. Advanced explicit receipt/task identities and supported listing
  filters remain available. The runtime collects supported pending remote replies;
  Agent does not need to manage a polling routine. It never automatically resends.
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
A display name resolves only when it identifies exactly one contact. Ambiguity
is a choice, not permission to select a similarly named agent. Stored bindings
use exact references, never a name alone. Bots retain their persistent session.
Codex/Claude/OMP continue through the existing bridge owners and receipts. A
failed resume never falls back to creating another conversation. Both the facade
and the executed tool's explicit policy rules apply before execution.

For example, `agent_message(agent: "Hermes", text: "Help me plan this change")`
followed by `agent_message(agent: "Hermes", text: "What about the second option?")`
continues the same supported conversation. `agent_read(agent: "Hermes")` opens it
without a copied session or receipt ID. Adding `conversation: "browser work"`
selects a separate named discussion. This is persistent routing convenience,
not a second persona, memory system or transcript. Inbound agent turns retain
the existing full Agent chat composition and peer authority boundary.

Continuity depends on the actual adapter. A send-only desktop contact remains
send-only, a standalone command cannot acquire history it does not support, and
missing remote context is reported rather than silently replaced. NativeAgent
handles those differences and presents the useful result or recovery decision.

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
artifacts and lifecycle evidence. The routing owner retains `contextId` as
`conversation_id` and `taskId` as `task_id`; advanced callers may still supply
them explicitly. A conversation and a task are different identities.
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

### Other agents connecting to the agent

The same listener also exposes an authenticated A2A 0.3 card at
`/.well-known/agent-card.json` and JSON-RPC at `/a2a`. Supported operations are
text `message/send` and `tasks/get`. Sends acknowledge submitted work, and the
returned task ID identifies canonical retained reply evidence. Continue the
returned `contextId` for a new turn in the same full agent session. Arbitrary
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

### Connecting by name

`agent_connect` with a NAME and no endpoint is the other door into the same
contract. The name is looked up in the known-agent table, `AgentHostDirectory`,
which is DATA: one row per agent host, carrying its display name and aliases,
the read-only paths that show it is installed, where it keeps its MCP servers
and in which format, whether it must be restarted, and the documentation that
row was verified against. A row exists only where both the host's own
documentation and the real file on this Mac agreed. A name with no row, or a
host that is not installed, gets an honest result and nothing is changed; it is
never a guess at somebody else's configuration format.

The rows this build ships:

| Agent | Configuration | Format | Restart | Verified against |
| --- | --- | --- | --- | --- |
| Claude Code | `~/.claude.json` | `mcpServers` object | required; read when a session starts | <https://code.claude.com/docs/en/mcp> |
| Codex | `~/.codex/config.toml` | `[mcp_servers.<name>]` | required | <https://learn.chatgpt.com/docs/extend/mcp?surface=cli> |

A row may also carry how that agent's COMMAND LINE takes a prompt and prints a
reply: the executable name (resolved on PATH plus the directories those agents
document installing into), the argument template for a first message, the
template for a later message in the same conversation where the CLI documents a
resume flag, and where its final message lands. Flags are checked against the
agent's documentation and installed CLI help; installed round-trip evidence
is recorded separately from these declared contracts:

| Agent | First message | Continuing | Reply | Verified against |
| --- | --- | --- | --- | --- |
| Claude Code | `claude -p --session-id <uuid> -- <text>` | `claude -p --resume <uuid> -- <text>` | stdout | <https://code.claude.com/docs/en/cli-reference> |
| Codex | `codex exec --json --skip-git-repo-check -o reply.txt -- <text>` | `codex exec resume --json --skip-git-repo-check -o reply.txt -- <uuid> <text>` | `reply.txt` in the run's own directory | <https://learn.chatgpt.com/docs/non-interactive-mode> |
| Antigravity CLI | `agy --mode plan --sandbox --disable-slash-commands --output-format json --print=<text>` | same flags plus `--conversation <uuid>` | successful JSON result's `response` | <https://www.antigravity.google/docs/cli/headless/> |

Antigravity CLI is a distinct `antigravity-cli` contact, also discoverable as
`antigravity` or `agy`; it does not relabel the older Gemini ACP route. Its
documented global `~/.gemini/config/mcp_config.json` uses the existing
`mcpServers` writer and exact-entry disconnect restoration. The JSON envelope's
real `conversation_id` is returned and verified on exact-ID resume; only
`status: SUCCESS` supplies a completed reply. Each turn launches a process in
the stable contact folder, retaining conversation context through the vendor's
resume contract, not a warm process. Plan mode, sandboxing, normal permission
requests and disabled slash-command expansion remain in force. No
`--continue` or skip-permissions option is used. Installed acceptance is separate
from the documented contract. Configuration source:
<https://www.antigravity.google/docs/mcp>.

Antigravity setup discloses and grants only `mcp(<our server>/agent_message)`
and `mcp(<our server>/agent_reply)` in the CLI's `permissions.allow` list.
The existing byte-splicing writer records ownership before mutation; disconnect
removes only grants added for this contact, preserving preexisting grants and
unrelated later edits. Existing matching Ask/Deny rules and malformed authority
are refused unchanged. Setup of an existing contact can add the missing scoped
grants without replacing its identity. No wildcard, shell, file, skip-permissions,
or Full Mac setting is added or changed. See the [CLI permission contract](https://www.antigravity.google/docs/permissions/).
Setup still does not send an automatic callback. An ordinary command reply and
exact-ID continuation work independently; inbound MCP proof remains unverified
until a real authenticated message arrives.

Codex's universal contact captures its real UUID from the JSONL `thread.started`
event and returns it as `conversation_id`; a subsequent message resumes that
exact UUID. It never guesses a rollout path, uses `--last`, or invents a local
session identity. Missing, malformed, conflicting, or unexpected identities
produce `continuation_available: false` with an explanation; a returned reply
remains available but continuity is unverified, and nothing is retried or
silently replaced with a new conversation. JSON events are never substituted
for a missing final reply file. Claude Code retains its existing caller-assigned
UUID contract. The built-in Codex/Claude/OMP builder lanes are unchanged.

Templates use an end-of-options marker or bind the prompt directly as an option
value, and each placeholder is substituted as a WHOLE argument, so a message
beginning with a dash stays a message instead of becoming a flag. Both rows were
run here with exactly that: `--help me pick a word: …` came back as the prompt.

`agent_message` to such a contact runs that command ONCE with the message and
brings its reply back in the same call: a message goes out and a message comes
back, in one result. `AgentHostCommandLine` is the whole adapter's input, so no
routing code branches on an agent's id — the adapter reads the row. The run gets
the contact's stable working directory, stdin closed, and the row's wall-clock limit; the
reply file lives in a separate temporary directory for each run. The
reply is read bounded at 64 KiB and marked `untrusted_remote_data` like every
other transport's, with `reply_truncated` when there was more. Running another
program is running another program, so it takes the ordinary path for one: the
same Trust Center Full Mac `file_ops` gate as `shell`, the same sandbox-profiled
runner, the same `data/builder_audit` receipt, and `agent_message` declares the
same `shell`/`process_spawn` capabilities when its target is a contact whose host
actually has a command line. No new authority and no quieter door.

Two things the run does NOT inherit. It gets a scrubbed environment — `PATH`,
`HOME`, `USER`, `LANG`/`LC_*`, `TMPDIR`, `TERM` and nothing else — because this
app's own environment carries provider keys and the bridge token, and an
external program must never be handed them; both rows were verified running
under exactly that set. And when it ends, whether by exiting or by running past
its limit, its process group is settled — TERM, then KILL after the grace — so
nothing it backgrounded outlives the turn or the directory it ran in.

For these command-line contacts the reply arrives in the message's own result;
there is no independent remote receipt endpoint to poll. The conversation view
uses retained exchange evidence where available. Anything the other agent says
on its own still arrives through the ordinary inbound route.

### Honest states

Four words, on every contact, in `agent_contacts` and in the result of every
connect, message and read. They say what has actually happened, without the
agent needing to know what a transport is:

| State | Means |
| --- | --- |
| `listed` | Known, nothing set up. |
| `set up` | The entry is written, nothing has crossed yet. |
| `connected` | A real message AND a real reply have crossed this connection. |
| `can send; replies aren't connected` | Messages go out; there is no route back. |

A handshake proves tools exist, not that the other agent will answer, so a
handshake NEVER reads as connected; neither does a written entry, a saved
endpoint or a probe that returned on its own command line. Only two things
promote a contact, and both are recorded where they happen: an inbound request
that arrived on a real message lane carrying that connection's key
(`ClaudeBridge.peerTurnContext`), and a command-line message that really left
and really came back with a reply. The whole record is two timestamps on the
contact, `provenInboundAt` and `provenOutboundAt`, written only by
`AgentPeerStore.recordProof` — `upsert` preserves them exactly as it preserves
the person's elevation grant, so no configure can claim a round trip or erase
one. `agent_contacts` surfaces them as `last_reply_in` and `last_message_out`.

Connect proves the round trip where that is possible. For a host whose row has a
command line, once the entry is written and approved, that command is run once
with a fixed probe asking it to answer through its `agent_message` MCP tool with
a fixed token. The contact turns connected when the inbound request carrying this
connection's key arrives — the probe's own stdout is the command line talking and
proves nothing about the entry, so it is deliberately not counted. A probe that
times out, or a command that is not installed, leaves the contact `set up` with
the reason. For a host with no command line the connect result says the other
app may need a restart before it picks the entry up, that nothing of its window
will be read, and that it turns connected on its first inbound message. The
probe is disclosed on the same single approval card as the rest of the setup,
before anything runs.

The setup is one entry named `nativeagent`, running the installed
`nativeagent-link` with argument `mcp` — the same stdio adapter documented
below, and nothing else. It is disclosed on ONE approval card that names the
exact file, the exact entry, the access it opens and the restart it needs, and
nothing is written before the person presses Connect: `agent_connect` is
confirm-tier, so its body runs only on the approved replay. The other
application is never launched, restarted or signalled; where a restart is
needed the card says so and leaves it to the person.

Writing is deliberately narrow. Each FORMAT has one writer, chosen by the row's
format and never by its id. A writer locates the byte range our own entry
occupies and replaces only those bytes, so every other byte in the file — key
order, indentation, comments, trailing commas in a TOML table — survives
exactly as it was. The file is read first, a timestamped backup is written
beside it, and the new bytes are put in place atomically. A file the writer
cannot walk is REFUSED with the reason, never overwritten: malformed JSON, a
TOML file containing a multi-line string, anything that is not a regular file
the person owns. `disconnect` removes exactly that entry — and, because the
entry was appended without adding any byte around it, removing it restores the
file it found.

### Identity is bound to the connection

At setup the app mints a key for THAT connection, stores it through the existing
per-peer credential path (`AgentPeerCredentials`, in this install's own Keychain
service), and writes it only into that agent's entry as two environment
variables, `NATIVE_AGENT_PEER_ID` and `NATIVE_AGENT_PEER_SECRET`. The entry
carries a third, `NATIVE_AGENT_BRIDGE_DESCRIPTOR`: the absolute path of THIS
install's descriptor file. Without it the link command falls back to the
machine-wide rendezvous at `~/.config/claude-bridge`, which belongs to whichever
install owns it — so an entry written by a second install, or by one on its own
data root, would offer this connection's key to an install that never minted it.
Every entry names the path, owner included, so it keeps meaning the same thing if
ownership later changes; the path is not a secret. One rule decides where that
file lives, `AgentHostDirectory.bridgeDiscoveryDirectory`, and `ClaudeBridge`
writes the descriptor to the directory that rule returns.
`nativeagent-link` reads them from its environment — never from a command-line
argument, which every process on the Mac can read — and sends them as
`X-NativeAgent-Peer-Id` and `X-NativeAgent-Peer-Secret` beside the bridge
bearer. The bridge resolves that pair to the contact that owns it
(`AgentBridgePrincipal`), and the inbound turn is attributed to that contact:
the transcript's `[from: …, via bridge]` label and the turn header they reads are
the contact's own name, and a destructive action that raises a permission card names it as
the requester.

Connection approval persists in the existing contact and executable/credential
binding. Reading an agent reply no longer causes a fresh approval for the next
message. The additional peer-origin gate uses the shared destructive capability
classification; routine conversation and non-destructive collaboration retain
the ordinary tool policy. Arbitrary shell execution and unclassified external
actions still ask because their safety cannot be established. Revocation,
changed executable checks, secret protection and explicit user blocks remain.
Human Full Mac sessions and their settings are unchanged. ACP permissions
requested by the other program remain that program's separate per-action gate.

The label is presentation only. The lane, its recorded surface and its
authorship still come from the route, so a contact name can neither claim a lane
nor widen what a turn may do. A request carrying only the machine bridge token
behaves exactly as it did before and stays a generic local agent. Authorship
remains `.agent`; a connection set up this way is NOT elevated, and elevation
remains the person's own grant in Trust Center. Disconnect revokes the key. The
key never appears in a tool result, a log line, a conversation row or a command
line, and the link command scrubs it out of anything a local server echoes back.

Configured is not connected. An entry that exists proves only that it was
written; the connection is proven when a real message arrives through it
carrying that key. See "Honest states" above for the four words every contact
reports and what is allowed to change them.

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

Desktop contacts provide that route without a brand-specific driver, and they are
SEND-ONLY. Configure `transport: desktop`, the exact `app_bundle_id`, and an
optional `conversation_label`. The existing address book stores the intended
destination. The live app handles `agent_message` internally through a bounded
desktop operator using the existing gated Mac controls: it types the message into
that app's chat, confirms the outgoing text is visible, and stops. Its
capabilities are `message` only. `agent_read` on a desktop contact opens,
focuses and inspects nothing; it returns a plain result saying so.

The other agent answers through this app's own inbound door instead of having its
screen read. Every outgoing desktop message therefore carries one appended
sentence asking the recipient to reply through the agent's MCP tool
`agent_message`. Setup on their side is one MCP server entry whose command is the
bundled `nativeagent-link` executable with argument `mcp`; its tools are
`agent_message` and `agent_reply`. Their reply then arrives as an ordinary
inbound turn in the agent's chat — the same lane as any other peer message, with
agent authorship and the existing Trust gates — rather than as the result of the
send.

The Core projection is only an internal plan; its `requires_interaction` is
consumed by the app, not handed to the agent as a clicking checklist. Automatic
operation needs an exact conversation label. The operator can select only that
label, type only the exact outgoing message once, and submit once; it stops if
focus changes or permissions, drafts, or recipient identity need attention. No
saved coordinates, shell commands, permission changes, or second transcript owner
are involved. A desktop label is not a verified protocol conversation ID or proof
of delivery. Ordinary app authentication and approvals still apply.
Future adapters follow the same contract: connection-specific routine work is
executed beneath message, not returned as instructions for the speaker, and a
reply is a message that arrives, never a screen that is scraped.

### Local command and stdio clients

The app bundle includes `~/Applications/NativeAgent.app/Contents/MacOS/nativeagent-link`.
Its `message` command accepts text and optional `--session`/`--request` identities;
`reply --session <returned-id> --request <returned-id>` recovers the response,
with `--offset` for another page. It assigns identity before sending and does not
resend automatically after an uncertain outcome. Credentials stay inside the
helper, which reads only the private live bridge descriptor and uses loopback.

For a client that supports stdio MCP servers, configure that executable as the
server command with argument `mcp` — this is the one entry another agent needs in
order to answer, including a desktop contact the agent messages. For HTTP MCP
clients, use the authenticated live `/agent/mcp` URL instead. Both reach the same app-owned full chat session;
the helper is not another server, agent runtime or memory store. Installing the
helper does not grant another agent additional local-execution permissions.

Generic messages acknowledge durable enqueue and finish through the same full
chat turn owner used for User's conversations. Agent receives their active persona,
normal relevant memory assembly, recall/search tools, Fluid Context, cognition and
persistent session history. Agent authorship is retained; ordinary Trust gates
and the bridge's existing external-MCP restriction remain in force.

At the inbound protocol boundary, omitting the conversation starts a fresh
persistent session. Direct protocol callers continue by carrying its exact
identity; invalid supplied identities are rejected. The agent-facing facade
retains that identity for Agent's current conversation. The NativeAgent
outbound adapter assigns this identity before sending, so a lost acknowledgement
still leaves a request/session pair for recovery. Generic inbound callers that
omit an identity receive a new one in the acknowledgement. Legacy named bridge
endpoints retain their existing selected-session semantics.

Both request and session identities are required for NativeAgent reply recovery.
Caller request IDs are correlation identifiers, not idempotency guarantees.
Advanced recoverable receipts retain the exact `agent_read` input;
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
never ran. Conversation bindings retain exact locators and bounded exchange
evidence; canonical remote receipts and chat transcripts keep their authority.
Pending reply collection does not replay sends or become another execution owner.

## Local ACP conversation continuity

Gemini CLI 0.46.0 has an inspected sandbox-launcher incompatibility: it consumes
non-TTY stdin before entering ACP. The app refuses this exact installed version
before launch with `incompatible_sandboxed_acp`, `sent: false`, and an actionable
explanation. See [upstream issue #23959](https://github.com/google-gemini/gemini-cli/issues/23959).
No fixed release has been verified; reconnect only after a compatible sandboxed
ACP installation is available. The app does not remove sandboxing, fake sandbox
state, or generalize this refusal to uninspected versions and other agents.

The conversation binding carries the returned `conversation_id` when continuing
an ACP conversation; explicit exact-ID continuation remains compatible.
NativeAgent retains up to eight live ACP connections, each with one active turn
and a 30-minute idle expiry. This preserves Hermes command-only sessions: Hermes
does not persist an empty conversation merely because `/model` changed its model.
The peer owns history and memory; NativeAgent does not create a second transcript.

After a connection closes, Hermes restoration must provide matching session
identity/provenance or replayed history before the new message is sent. A missing
session is reported explicitly rather than silently replacing its context.
Disconnect and app termination close retained children. Executable identity,
current permissions, and connection configuration remain checked on each turn.

Timeouts before the first attempted prompt write identify connection
initialization, session startup, or mode setup and explicitly report
`sent: false`. Check that named startup boundary before explicitly reconnecting.
Once prompt delivery has been attempted, timeout reports an uncertain outcome;
never resend automatically. Neither a timeout nor an empty session proves that
an earlier uncertain message was absent.

An ACP permission request appears in its initiating local chat through the
existing approval card. It is tied to the live request, cannot authorize replay,
and remains local-only; cancellation retires the request.

## Owners

`AgentConversationStore` owns `agents/conversations.json`: scoped operational
bookmarks and a bounded latest-receipt cache, never a transcript or authority
store. `CanonicalToolNameDispatcher` manages name/label selection and continuity
around the existing dispatch gates. `AgentConversationRouting` owns local
translation before those gates. Automatic remote reply recovery runs through
the existing `DelegationOutcomeEventRunner`; coding-agent callbacks retain
their existing owners. `SwiftToolDispatcher+AgentCommunication` owns the facade's directory,
configuration and remote exchanges. `AgentPeerStore` owns contacts and the
two proof timestamps behind their states, `AgentHostDirectory` owns the
known-agent table including each row's command line, `AgentHostConfigWriter` owns
the per-format splicers that edit another program's file, `AgentHostConnection`
owns the setup and its card text,
`AgentPeerHTTP` owns bounded transport, `AgentPeerCredentials` owns dedicated keys,
and `AgentA2AWire` owns pure protocol negotiation/projection. `ClaudeBridge` retains
the sole inbound listener and receipt recovery. Existing bots, TrustCenter, builder
bridges, and session persistence keep their responsibilities.
