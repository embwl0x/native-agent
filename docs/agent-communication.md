# Agent conversations

> One structure (docs/NORTHSTAR.md, first law): this doc is part of one whole. A change here is molded into every doc that states the same thing, in the same commit, with what comes out named; a contradiction is a defect.

## Every agent is itself (User, 10-19)

**An agent is a who. A who has doors. Every word to a who is owed until that who receives it.**

- **Who.** One saved contact: a stable id, the name the person or they gave it, and the history between them. Nothing else establishes identity. A product name, a vendor, a host, a bridge route or a lane name never makes two contacts one, and never makes a contact anyone else. On a stranger's Mac, Claude Code is "Claude Code". On User's Mac, "Claude" is a who that they named, reached through Claude Code's and Claude Desktop's doors.
- **Door.** One authenticated way to reach a who: a recipe route (MCP entry, ACP launch, inbox file, desktop chat, A2A endpoint, bot routine), its own credential, and the recipe's two declarations: how the door **wakes** its agent (none, open the app, run a command, start an ACP session) and what counts as **acceptance** (the agent read it through its door, answered, or acknowledged it). Joining several doors into one who is an explicit association written on the contact by the person or by them; there is no implicit one. Authority lives on a door: a call is elevated only when it authenticates with that door's own key and the person granted that door. Associating a new door with a trusted who grants it nothing. A door may instead be one of their own abilities (`ability` on the contact): a message runs it with the text, the contact, the exchange and the recent talk, and it answers as that contact with `agent.reply`, which settles the exchange as any route's answer does; the who, its thread, trust and replay claims stay the contact's.
- **Owed until received.** A message is an experience that owes `accept` to its who. It settles when a door's acceptance evidence arrives; a send, a queue write or a launch never settles it. While it is owed, their home shows it as waiting on that who, with the lever: their next call (wake it through a door that can) or the person's exact tap (open that app) when no door can. A who with no door that can deliver says so with the owner (the recipe, the vendor) and what would change it.
- **Found as it is.** A host is found the way the person's own Mac finds it: its app by bundle or markers, its command line through the person's own login PATH and the recipe's paths, resolved once into one installation binding that discovery, connect and launch share. Installation events settle together before comparing the candidate programs, bundle locations, app metadata and executables; unrelated directory changes keep the binding and do not scan running programs. Explicit discovery still refreshes immediately. An update keeps the who, its doors' keys, the person's grants and authored recipe changes; only owned configuration is rewritten.

What falls out: Claude Code found and connected on any Mac as itself; trust per door; delivery that arrives or names exactly why not; every install shape found; updates that never strand a contact. The built-in "lanes" (claude, codex, omp) are not a second kind of agent: on an install that used them they become contacts with doors, keyed by their old names as handles, and on a fresh install they do not exist.

Conversations groups saved records through those explicit identities and opens
each contact's continuous thread. Conversation labels do not select historical
transcripts. A disconnected contact keeps its own history even when another
contact has the same display name. Room commands, including pagination, belong
to the chat that displayed them; stable item names keep their item identities.
The person's read-only Agent preview never replaces those command bindings.
Simple's contact composer sends the known contact and text through the engine's
gated contact-send owner and shows its actual delivery state. Saved contacts use
their peer identity; discovery candidates are rows without a saved contact.


Agent talks to agents through their one always-on `app` tool. `app {}` is home,
where they left off; `app {"page":"agents"}` lists agent actions.
`AppActions+Declarations.swift` declares them. Retired standalone tool calls are
refused with a translated `app` call; they do not execute.

## Agent-facing actions

Call an action with `app {"action":"agent.message","args":{...}}`.

| Action | Use |
| --- | --- |
| `agent.contacts` | One short row per contact: name, state and `last_answered` from its thread, plus declared `capabilities` and `can_start_turn` for conversation actions. `details: true` includes doors, connection evidence and discovery details. `discover: true` or a name refreshes discovery when the person asks to find agents: by what speaks a protocol (A2A card, ACP program, MCP settings), with a `recipe_draft` for a find no recipe knows. |
| `agent.connect` | Connect a known host by name, a peer by endpoint, or an explicit desktop route. Disconnect with `disconnect: true` and `agent: "peer:<id>"` from contacts. `ability: "<id>"` with a saved contact moves it to one of their abilities; `ability: false` moves it back to its built-in route. |
| `agent.message` | Send `agent` and `text`; continue this chat's current conversation with that contact. `wait_seconds` defaults to 20, accepts 0–120, and returns a live lane's answer inline. A known host can be connected in the same call through its setup gates. |
| `agent.read` | Read the conversation and retained reply: a successful read says `execution: executed`, `effect: none`, independently of the send it shows. Reply owners publish `retrieval_result_class`, `execution_result_class` and `execution_terminal`; terminal task snapshots remain readable when execution failed or was cancelled. An unknown name is `unknown_contact` with nearest contacts; a known contact never messaged is `no_history`. `details: true` exposes receipts. `wait_seconds` waits 1–300 seconds on a conversation by name or its retained exact reply IDs; it cannot be combined with history or listing filters. |
| `agent.cancel` | Request a stop through the route's cancellation mechanism. The result distinguishes stopping, stopped, released and unsupported stops. `clear_queue: true` withdraws queued follow-ups. |
| `agent.reply` | From the ability a contact is reached through, and only there: its answer lands in that contact's conversation and settles the exchange (the one named, else their newest message to it still unanswered); `done: false` shows progress. |
| `agent.jobs` | Read the coding-helper job records; `message_id` selects exact accepted-message evidence. Missing evidence does not prove no execution. |

A scheduled Workshop step without a chat session sends, reads and waits on a
saved contact in that contact's own conversation session.

The workspace's **Connection details** opens the detailed contact read,
preserving its doors, connection evidence and discovery details.

A unique display name or exact reference identifies a contact: `codex`,
`claude`, `omp`, `bot:<UUID>` or `peer:<UUID>`. Ambiguous names require a
choice. Optional `conversation` names a separate discussion on supported
routes; `new_conversation: true` starts fresh. Bots keep one continuous session.
A failed resume does not silently start another conversation.

Bridge inbox admission deduplicates by durable message identity and recovers
that identity's retained receipt. Identical words on the same topic with a new
message identity are new work; text similarity and elapsed time cannot suppress
the wake.
Damaged Swift-owned OMP/Claude inbox admission storage remains byte-preserved
and unavailable. A parseable subset cannot prove a message was never admitted;
reconcile the message identity before repairing the record or sending again.

Saved reply recovery isolates unreadable retained bridge jobs and logs their
failure without changing their bytes. Contact decoding rejects unknown fields at every depth.
Bridge, human-reply and contact completion
owners each reconcile independently under their existing delivery identities;
one owner's failure is reported after the others have had their recovery pass.

```text
app {"action":"agent.message","args":{"agent":"Hermes","text":"Help me plan this change"}}
app {"action":"agent.message","args":{"agent":"Hermes","text":"What about the second option?"}}
app {"action":"agent.read","args":{"agent":"Hermes"}}
```

The static options schema projects declared inbox recipes; the selected live door admits only its own keys and continuation options.
Follow-ups keep their accepted send options, queue behind an answer in flight,
and send when it settles. Set
`expects_reply: false` for an FYI that needs no answer. Supported pending replies
are collected by the runtime; a missing acknowledgement is never a reason to
automatically resend. Bridge replies retain the turn's terminal verdict, reply
text/attachments and `completionDelivery` independently. Read receipts classify
execution from that turn verdict; historical combined statuses decode at the read
boundary. Reading a reply, finishing its turn and delivering it onward are separate facts.

`agent.message` waits on the existing conversation-change signal, without
polling a file. `AgentConversationDelivery.answersLive` admits live inbox readers,
MCP hosts (including held messages), ACP, remote NativeAgent/A2A and desktop-chat
reply readers. A reply received within it returns `reply`, `replied_at` and
`delivery: answered`, and is filed once in the contact's thread; it does not
also start a delayed reply turn. Set `wait_seconds: 0` to send and continue.
When the deadline expires the receipt retains its current send evidence with
`delivery: queued` (or `held` for a held message); the accepted operation keeps
running and its later answer follows the existing delivery path once. A
queued receipt does not prove remote delivery: `sent: null` still means
unconfirmed.

A bridge reply names the accepted send, or answers the sole delivered held
message in its returned conversation. That inbound arrival hands the answer
to the active waiter under the conversation store's settlement lock and files
it through the existing contact-thread owner, without starting another turn.
An exact Claude inbox answer writes its linked reply receipt before the
exchange is published to the waiter, so `agent.read(message_id:)` retains the
answer returned inline. A repeated handoff does not append that receipt again;
a recording failure is reported instead of returning an answered receipt.
The call that first takes a held message cannot also answer it. If the waiter
has released, the incoming reply follows its existing bridge-turn path.
Replies carrying attachments retain that path too.
Inline and delayed bridge answers share the store's answer mutation and receipt
bound; transcript publication receives the complete answer in either path.

Inbox doors without live readers (including Codex and OMP), Dot's inbound
door, abilities and bots use their asynchronous path and report
`wait_ignored: lane_is_async`. Waiting never opens a host's window or claims a
held message was sent. Explicit protocol-ID sends use the same
bounded send owner and retain a separate conversation record for their exact
receipt. Waiting on a queued follow-up does not wait on the earlier message;
the new message keeps its queue receipt and goes when its turn comes.

Completed full transport answers are committed to the contact's canonical thread
before making bounded receipt or send-ledger excerpts. A cached receipt over
96 KiB keeps its original outcome, conversation identity, a labelled answer
excerpt and `reply_location`, an exact `agent.read` history selection for the
committed answer. Upstream excerpts remain labelled and are never saved as
complete transcript messages. A live connection or send still running when
`wait_seconds` expires reports delivery unconfirmed (`sent: null`) until its
transport supplies evidence. Asynchronous ability sends retain their existing
two-second dispatch handoff; their answer is not awaited by `wait_seconds`.
Command receipts separately retain physical launch (`ran`), successful exit
(`command_succeeded`) and reply evidence. A launched command without proven
delivery reports `sent: null` and unknown effects, even if it failed or timed
out; only an unlaunched command proves that nothing ran. Launch alone does not
promote the contact's outbound proof or mark it unavailable.
If canonical saving fails, the completed transport outcome and save error stay
on a settled attention record, without an invented history locator.
Contact startup replays durable projections once; mutations publish later
changes, and ordinary history reads do not replay the dropped-record archive.
Delayed reply turns consume the saved answer's run and full text, without
appending another contact message or replaying it again as prior context.

## Connecting by name

`AgentHostDirectory` seeds each host's launch contract and discovery words.
Loaded editable recipes govern setup through the declared configuration,
command line, ACP or desktop adapter; an arbitrary app name implies no protocol.
The connection action presents a card when policy requires one.

For hosts configured through MCP settings, `AgentHostConfigWriter` edits the
owned entry and `AgentHostConnection` binds a per-contact credential. Other
routes have their own setup, including [Grok Bot](grok-bot-connection.md).
Use the returned status and blocker rather than assuming that configuration
proves a working reply path.

### Honest states

Each send has one outcome, read from its conversation record. A failed
dispatch settles that record immediately; history, home, the reply report
and receipt detail all say `failed`, even if older executor progress says
`running`. Delivery is claimed only from confirmed delivery evidence;
transport acceptance alone remains unconfirmed. Older inconsistent records
are projected on read, without rewriting their saved history.
Default and named coding-helper reads use that record and contact history;
`agent.jobs` reads the executor's diagnostic job listing separately.
Reading a failed-send receipt with `details: true` is still a successful read:
its `execution: executed` and `effect: none` describe that read; the retained
error describes the send.

`last_answered` (and detailed `last_reply_in`) comes from the same contact
thread the room shows, including explicitly associated doors. A connection
proof's timestamp remains route evidence, never a substitute reply time.
Helpers derive `last_answered` from their latest saved shelf reply, using
the shelf entry's `runAt`; an unreadable shelf reports `history_unavailable`.
Contact summaries say `answered` with that time, or their current waiting or
unavailable state; a historical successful connection does not claim current
availability. Bridge and contact replies use `ChatResponse.answerOnly` at the turn's
recorded commentary boundary; interim lines remain in the transcript. An absent
boundary keeps the whole output; an invalid boundary or empty/whitespace-only
suffix yields an empty answer. Attachments keep their existing destinations.
Bridge reply doors share completion settlement and task-first, missing-only receipt reads;
each ingress owns session admission, HTTP status and acknowledgement after transmission.

| State | Meaning |
| --- | --- |
| `listed` | Known, not set up. |
| `set up` | Configuration exists; no round trip is proven. |
| `connected` | Historical route proof in connection detail: an authenticated inbound message or a message/reply exchange crossed it at the recorded proof time. Contact summaries use `answered` and the thread's `last_answered` instead. |
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

Dot's automatic link recovery repeats an admitted turn only when its retained
failure has a typed network cause. Completion limits, other terminal failures
and an app interruption are not network evidence. Older saved failures without
a typed cause migrate once to terminal admissions, keeping their reason; a
later provider success cannot restart them.

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
| `AppToolRuntime/AppActions+Declarations.swift` | Agent actions exposed through `app`. |
| `ChatToolRuntime/CanonicalToolNameDispatcher.swift` | Contact selection, conversation continuity and dispatch gates. |
| `AgentConversations/AgentConversationStore.swift` | Scoped conversation bindings and retained exchange evidence in `agents/conversations.json`. |
| `AgentConversations/AgentPeerStore.swift` | Saved contacts and connection proof. |
| `ChatToolRuntime/SwiftToolDispatcher+AgentCommunication.swift`, `AgentContactConnection.swift`, `AgentContactACP.swift`, `AgentContactCommand.swift`, `AgentContactCancellation.swift`, `AgentContactPresentation.swift` | Contact interpretation, setup, transport execution, cancellation and retained presentation through one dispatcher. |
| `AgentLinkTransport/AgentA2AWire.swift` | A2A negotiation and wire projection. |
| `Agents/AgentContactRoutes.swift` | Inbound bridge, MCP and HTTP A2A routes. |
