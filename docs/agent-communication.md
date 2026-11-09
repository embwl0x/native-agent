# Agent conversations

> One structure (docs/NORTHSTAR.md, first law): this doc is part of one whole. A change here is molded into every doc that states the same thing, in the same commit, with what comes out named; a contradiction is a defect.

## Every agent is itself (User, 10-19)

**An agent is a who. A who has doors. Every word to a who is owed until that who receives it.**

- **Who.** One saved contact: a stable id, the name the person or they gave it, and the history between them. Nothing else establishes identity. A product name, a vendor, a host, a bridge route or a lane name never makes two contacts one, and never makes a contact anyone else. On a stranger's Mac, Claude Code is "Claude Code". On User's Mac, "Claude" is a who that they named, reached through Claude Code's and Claude Desktop's doors.
- **Door.** One authenticated way to reach a who: a recipe route (MCP entry, ACP launch, desktop chat, A2A endpoint, bot routine), its own credential, and the recipe's two declarations: how the door **wakes** its agent (none, open the app, run a command, start an ACP session) and what counts as **acceptance** (the agent read it through its door, answered, or acknowledged it). Joining several doors into one who is an explicit association written on the contact by the person or by them; there is no implicit one. Authority lives on a door: a call is elevated only when it authenticates with that door's own key and the person granted that door. Associating a new door with a trusted who grants it nothing. A door may instead be one of their own abilities (`ability` on the contact): a message runs it with the text, the contact, the exchange and the recent talk, and it answers as that contact with `agent.reply`, which settles the exchange as any route's answer does; the who, its thread, trust and replay claims stay the contact's.
- **Owed until received.** A message is an experience that owes `accept` to its who. It settles when a door's acceptance evidence arrives; a send, a queue write or a launch never settles it. While it is owed, their home shows it as waiting on that who, with the lever: their next call (wake it through a door that can) or the person's exact tap (open that app) when no door can. A who with no door that can deliver says so with the owner (the recipe, the vendor) and what would change it.
- **Found as it is.** A host is found the way the person's own Mac finds it: its app by bundle or markers, its command line through the person's own login PATH and the recipe's paths, resolved once into one installation binding that discovery, connect and launch share. Installation events settle together before comparing the candidate programs, bundle locations, app metadata and executables; unrelated directory changes keep the binding and do not scan running programs. Explicit discovery still refreshes immediately. An update keeps the who, its doors' keys, the person's grants and authored recipe changes; only owned configuration is rewritten.
  A supplied card URL is exact: failed resolution reports that URL instead of
  guessing another endpoint. An explicit executable path must validate as configured.
  Peer credentials require an install identity. Their old global Keychain reader
  remains pending an entitled installed-app inventory; command-line Keychain misses
  did not prove its absence, so this lane does not claim that reader retired.

Contact credential availability is a checked Keychain read for each contact.
A confirmed missing or nonunique readable key is unresolved; a failed read
retains its contact's name, peer ID and cause in the turn contact summary and
its cause and remedy in the contact row and compact/detailed tool projection.
Local projections never replace a Keychain access failure with reconnect advice.
An unreadable contact cannot authenticate or carry its grant, and its failed
read does not veto a sibling's readable key. Inbound authentication and authority
checks require exactly one matching readable contact key; duplicate readable
keys still deny. Read failures stay distinct from missing keys and are never
disclosed to the inbound peer. An unreadable address book remains a required-read
failure for authentication; no partial contact inventory stands in for it.

What falls out: Claude Code found and connected on any Mac as itself; trust per door; delivery that arrives or names exactly why not; every install shape found; updates that never strand a contact. The built-in "lanes" (claude, codex, omp) are not a second kind of agent: on an install that used them they become contacts with doors, keyed by their old names as handles, and on a fresh install they do not exist.

Conversations groups saved records through those explicit identities and opens
each contact's continuous thread. Conversation labels do not select historical
transcripts. A disconnected contact keeps its own history even when another
contact has the same display name. Room commands, including pagination, belong
to the chat that displayed them; stable item names keep their item identities.
The person's read-only Agent preview never replaces those command bindings.
The background reply-read boundary marks its own gated dispatcher as an
internal conversation read before the first page and retains that mark for
every continuation page, so reading a reply cannot re-enter its presentation.
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
| `agent.message` | Send `agent` and `text`, optionally `files: [{path}]` on A2A; continue this chat's current conversation with that contact. `wait_seconds` defaults to 20, accepts 0–120, and returns a live lane's answer inline. A known host can be connected in the same call through its setup gates. |
| `agent.read` | Read the conversation and retained reply: a successful read says `execution: executed`, `effect: none`, independently of the send it shows. Reply owners publish `retrieval_result_class`, `execution_result_class` and `execution_terminal`; terminal task snapshots remain readable when execution failed or was cancelled. An unknown name is `unknown_contact` with nearest contacts; a known contact never messaged is `no_history`. `details: true` exposes receipts. `wait_seconds` waits 1–300 seconds on a conversation by name or its retained exact reply IDs; it cannot be combined with history or listing filters. |
| `agent.cancel` | Request a stop through the route's cancellation mechanism. A thread's Stop retains its exact record and original chat scope; an absent or moved record cannot select another conversation by label. The result distinguishes stopping, stopped, released and unsupported stops. `clear_queue: true` withdraws queued follow-ups. |
| `agent.reply` | From the ability a contact is reached through, and only there: its answer lands in that contact's conversation and settles the exchange (the one named, else their newest message to it still unanswered); `done: false` shows progress. |
| `agent.jobs` | List their jobs, their own lines (`agent: "self"`) among them, newest first, and read retained reply deliveries (owed, delivered, let go) for the chats and contacts that asked. Missing evidence does not prove no execution. |

## Jobs

`agent.job {agent, brief, instructions?, where?, reach?, done?, desk?}` gives another agent,
or a line of the agent's own, a job. For as long as it lives, the job is a part the agent
grows: a contact is an organ that brings its own model and its own sign-in, and the agent
stays the speaker. No path picks, switches or escalates any model.

`agent: "self"` is the same socket with the agent themselves as the power: a **line of them**. It
is a turn of theirs in its own work conversation (an own-work session whose id is the job's, so
the person's chat list does not show it), through the `chat` surface, with a recorded
`builder` conversation kind
([conversation identity](session-conversations.md)). It is admitted through `TurnAdmission` like any turn, with
the brief as the arriving message and the same turn part, tools, Trust and present: their breath
reaches it each round and its words reach their other lines as their own work. `instructions`
(self only) write who the line is, a researcher, a critic or a specialist; they stand in place
of their persona text and nothing else changes. Without them the line is their. `where`, `reach`
and a `done` command bound another agent and are refused for their own line; a `done` file or
grep still judges it. A line carries the limits of the turn that started it, its peer steering
and its file access, so neither a peer's words nor a narrower door reach their hands wider through
a line of their own. An act that needs the person raises the same card their turn would, naming the
line's conversation; answering it continues the line there. Several lines at once is a swarm: each
runs side by side in its own conversation and each ending wakes the conversation that started
it with the line's answer. A relaunch continues a working line in its own conversation. A
helper bot is still its own mind and is not a line.

| Action | Use |
| --- | --- |
| `agent.job` | Commission a job. `where: <repo>` cuts a worktree on branch `nativeagent/job-<token>`; the organ works there and never writes to the agent's checkout. `done` is the check the stem runs before the job is called done. `agent: "self"` starts a line of them, with `instructions` when they writes who it is. `desk` names the Desk item the job moves ([Desk](DESK.md)). |
| `agent.read {job}` | Read the job: its beat (working, needs you, done, failed), its deliverable and the check's output. A line of their shows its `conversation`, `instructions` and its answer as their own words. |
| `agent.cancel {job}` | Stop the job through its transport; a line of their stops its turn. |
| `agent.apply {job}` | Merge a repo job's diff with the agent's own git call, gated by Trust; the commit carries `Assisted-by: <contact>:<model it reported>`. |
| `agent.discard {job}` | Drop a repo job's worktree and branch. |

What the agent commissions comes back as its own: the deliverable returns as the result of its
own call and registers with native provenance plus "made by ‹who› for ‹job›". The organ's prose
comes back labelled as its report. When a job settles it wakes the context that commissioned it.
Each agent takes jobs through its own native headless door: Codex `app-server`, Claude Code
`-p` stream-json, ACP and A2A. A worktree idle for seven days with no unique commits, no dirty
or untracked files and no uncertain ownership may be retired when a new one is cut; its branch
is kept, and the outcome is a `builder.worktree_retirement` turn-trace event.

The workspace's **Connection details** opens the detailed contact read,
preserving its doors, connection evidence and discovery details.

A unique display name or exact reference identifies a contact: its name,
`bot:<UUID>` or `peer:<UUID>`. Ambiguous names require a
choice. Optional `conversation` names a separate discussion on supported
routes; `new_conversation: true` starts fresh. Bots keep one continuous session.
A failed resume does not silently start another conversation.

A waiting exchange remains pending; sending or accepting a message does not make
it an answer. A follow-up queues behind it until settlement or an explicit
stop/release. The conversation store owns admission and settlement: a send is
occupied from its committed admission, including before its task registers.
A queue reservation names that exact record, skips transport refresh, and
admits only its oldest eligible message. If settlement races enqueue, the
caller reads the current record before deciding whether it can send. Store
writes, approval settlement and watch release wake the retained sender;
silence leaves the queue visibly waiting with `agent.cancel {clear_queue: true}`
as its withdrawal lever. Desktop and background reply watches belong to their
sending process.

A queued send refused before begin is terminal `not_sent`, with `sent: false`,
`terminal: true` and its reason. It releases its reservation in the same write
and never waits for a later gate change or sends itself again. A refusal
already decided when the message call returns appears in that call's own
result; a later refusal returns news to the caller scope saved on that queued
send. Each queued send, including a pre-Return Mac hold, keeps its own caller
scope independently of the conversation's active exchange. An older
agent-initiated item without caller scope still saves its terminal refusal,
but owes a named queue repair instead of guessing a destination for its news. `agent.read`,
conversation views and contact rows read that same refusal; its experience
lets go every outstanding deliver, accept and answer obligation as failed, so
Home and Desk do not keep an impossible send owed. Existing saved refusals
read the same way without a migration or history rewrite. The saved `held`
reason is current storage: only `waitingForMac: true` names a live pre-Return
hold; without that flag the saved reason proves refusal, not pending delivery.
No missing reply, missing row or missing owner supplies that proof.

Contact decoding rejects unknown fields at every depth.
Bridge, human-reply and contact completion
owners each reconcile independently under their existing delivery identities;
one owner's failure is reported after the others have had their recovery pass.
Continuation pre-run update failures retain `not_started` and their exact cause;
once execution is entered, interruption remains uncertain. Completion delivery
uses only its saved route; a missing route owes a named repair. A missing approval holds and names only its own send;
unrelated launch queues continue. The finished October contact-history import
and its marker dependency are removed after canonical transcript coverage was checked.

The canonical task store restores accepted contact and builder work. A failed
backlog read keeps restoration unavailable, with its source and repair lever;
it never counts as an empty backlog. Admission reports that failure rather than
waiting forever. A failed conversation read holds that conversation while other
conversations restore. Saved reply-file recovery has its own typed debt: known
execution state and recovered parts remain retained, damaged files are named,
and a later task read reconstructs only the payload after repair. Such payloads
are excluded from expiry while repair is owed.

Registered A2A callbacks retain their owed task update in the task's receipt.
If Keychain restoration fails or the destination is missing, recovery saves
the cause without advancing acceptance and retries twice, after one and two
seconds. If those reads also fail, the callback stays registered and any
unaccepted update stays owed; the next task read or bridge activation retries
recovery. Deleting the
registration or stopping the bridge cancels those passive retries. A terminal
update already accepted does not restore its deliberately retired secret.
Only the destination's acceptance advances the callback's delivered state;
restoration success alone cannot settle an owed update.

```text
app {"action":"agent.message","args":{"agent":"Hermes","text":"Help me plan this change"}}
app {"action":"agent.message","args":{"agent":"Hermes","text":"What about the second option?"}}
app {"action":"agent.read","args":{"agent":"Hermes"}}
```

### Outgoing files

`agent.message` takes `files: [{"path":"/absolute/path/report.pdf"}]`, the
local-path attachment form also used by bridge replies. File names, MIME types
and sizes come from the files, rather than caller-supplied metadata. The normal
send authority applies to the whole message and its file content.

| Contact adapter | Outgoing files |
| --- | --- |
| A2A 1.0 JSON-RPC, HTTP+JSON, gRPC; A2A 0.3 JSON-RPC | Up to four regular files, 8 MiB total. Checked bytes travel inline as versioned file parts, never as a local path or a URL the peer must fetch. |
| MCP bridge hosts, including command and pull hosts and Dot | Text only in this adapter. Existing reply attachments do not establish outgoing file support. |
| NativeAgent bridge, ACP, helpers, contact abilities | Text only in these adapters. |
| Desktop and desktop-chat apps; Grok Bot | Text only in these adapters; file paste/attach is not implemented by their contact-send route. |

Unsupported routes refuse the entire send before text is sent or a host is
connected. Omitted, null or empty `files` preserves ordinary text sends;
malformed entries refuse. A queued send retains file paths and reads them when
its send executes, through the same Trust workspace/sensitive-store fence as
`reply.attach`. Each file is read completely from one verified regular-file
descriptor with a bounded read; missing, unreadable, empty or oversized files
refuse the whole send before network operations. The shared secret-content
policy inspects the filename and captured content before base64 encoding.
Complete, NUL-free UTF-8 files receive the text policy's nested URL-escape
inspection. Binary files receive the same literal credential/token/assignment
checks through a lossy UTF-8 view, without interpreting incidental `%HH` bytes
as URL encoding. Credential-shaped content is refused, never silently redacted
into a different file; accepted files retain their exact original bytes.
This inspection does not decode binary encodings, archives, encrypted content
or embedded formats: use an export without secrets. The outgoing receipt fields contain
metadata, not file bytes. `outgoing_files` in the detailed transport receipt names
the captured files' sizes and SHA-256 hashes; it describes attempted content,
not delivery. The recipient's file observation is delivery proof. Existing
wait limits, uncertain-outcome recovery and no-automatic-resend rules apply.

Follow-ups queue behind an answer in flight,
and send when it settles. Set
`expects_reply: false` for an FYI that needs no answer. Supported pending replies
are collected by the runtime; a missing acknowledgement is never a reason to
automatically resend. A queued message keeps its id when its send begins.
The address book, current conversation/live state and reply retention are checked
reads: unavailable evidence reports its owner rather than becoming no contacts,
no work or completed delivery. A2A's retained task is the declared state reader
with its 15/60-second pending/read-error deadlines; authenticated pushes wake that
same reader sooner and never select a different state mechanism.
Contact rooms and `mac.wait` with an `agent` mark Grok routine requests as shown only for
`grokBot` contacts; ACP, MCP and desktop contacts read their own retained
conversation evidence. A real authenticated inbound contact clears an older
unavailable mark, while a newer failure remains visible.
The [send experience law](EXPERIENCE.md#delivery-and-face) closes its obligations
from its exchange: all unsettled keys release on failure, a confirmed delivery
closes a send explicitly requiring no reply, and superseded sends settle from
their retained exchange instead of remaining owed forever. Words such as
"no reply needed" do not change the explicit `expects_reply` flag.
Bridge replies retain the turn's terminal verdict and reply
text/attachments independently. Read receipts classify
execution from that turn verdict; historical combined statuses decode at the read
boundary. Reading a reply, finishing its turn and delivering it onward are separate facts.

A conversation lives on the door it was opened through. Each caller of a
contact's door has its own conversation: the `nativeagent-link mcp` relay a host
session starts names its caller on every call (`x-nativeagent-caller`: the parent
process id and its start time, `ContactCaller`), and that caller's conversation is
`mcp-` plus a UUID holding those values and a check binding them to the contact.
A call that names no caller (the one-shot CLI, `/agent/message`, `/agent/reply`,
or A2A) is in the contact's own conversation, `mcp-<id>`
(`AgentConversationStore.heldThread`). An MCP relay whose parent cannot be
identified exits with the cause on stderr before forwarding any call;
a malformed caller header is refused. A turn in a held conversation names it to the
agent by `conversation_id` in its contact line, never by the label "Main".

The MCP relay's descriptor wait follows publication or cancellation without a
local deadline and names that wait on stderr with its cancellation lever.
`notifications/cancelled` cancels the matching string or numeric request ID;
input EOF cancels every outstanding request before joining its exit. Cancellation
retires response and SSE forwarding immediately. Descriptor events and HTTP
dispatch check cancellation before sending; URLSession owns cancellation of an
in-flight exchange. Watch closure reports an observation failure, never an absent
bridge verdict. Chrome relay waits follow the socket's file events, including
the producer's metadata change after `listen` on the same inode. Observation is
armed before connecting; only a successful connect admits the greeting, using
that connected socket. Refused connects wait for another socket event. Browser
exit, directory loss or incomplete observation ends the wait with its cause;
elapsed silence never initiates a dial.
Each such conversation has its own session (`ContactThread.session(owner:
conversation:)`); a call whose `session_id` names another of the contact's
conversations runs in that one, and any other context runs in the contact's
own. A thread the contact opened by calling in is answered by holding the
message for its caller's next call, even when its host also has a command line.
In that thread, an unnamed message to the same contact goes back on that caller's
held thread (`AgentConversationStore.ownThread`), never to another caller or a
conversation of another door that was carried in; from any other chat an unnamed
message continues the chat's own conversation or the contact's Main, and never
lands on a held thread. A named conversation goes where it is named: every send
in a held conversation carries that conversation's name (the contact and when
its caller opened; the contact's name for its own), so another chat reaches it
by that name.

`agent.message` waits on the existing conversation-change signal, without
polling a file. `AgentConversationDelivery.answersLive` admits MCP hosts (including held messages), ACP, remote NativeAgent/A2A and desktop-chat
reply readers. A reply received within it returns `reply`, `replied_at` and
`delivery: answered`, and is filed once in the contact's thread; it does not
also start a delayed reply turn. Set `wait_seconds: 0` to send and continue.
When the deadline expires the receipt retains its current send evidence with
`delivery: queued` (or `held` for a held message); the accepted operation keeps
running and its later answer follows the existing delivery path once. A
queued receipt does not prove remote delivery: `sent: null` still means
unconfirmed.

An explicit `mac.wait` with an `agent` also watches an unanswered held send whose receipt is
`held`, `delivering` or `delivered`, through the same conversation-change signal.
Stop or release ends that watch; its requested deadline returns `still_waiting`
without resending or ending the owed answer. This leaves held sends' ordinary
queue behavior unchanged. Reading an already-selected conversation with no new
receipt or selection change performs no store rewrite or change notification;
the store compares the completed row collection, including sibling selections.

A bridge reply names the accepted send, or answers the sole delivered held
message in its returned conversation. That inbound arrival hands the answer
to the active waiter under the conversation store's settlement lock and files
it through the existing contact-thread owner, without starting another turn.
The call that first takes a held message cannot also answer it. If the waiter
has released, the incoming reply follows its existing bridge-turn path.
Replies carrying attachments retain that path too.
Inline and delayed bridge answers share the store's answer mutation and receipt
bound; transcript publication receives the complete answer in either path.

Dot's inbound door, abilities and bots use their asynchronous path and report
`wait_ignored: lane_is_async`. Waiting never opens a host's window or claims a
held message was sent. Explicit protocol-ID sends use the same
bounded send owner and retain a separate conversation record for their exact
receipt. Waiting on a queued follow-up does not wait on the earlier message;
the new message keeps its queue receipt and goes when its turn comes.

Completed full transport answers are committed to the contact's canonical thread
before making bounded receipt or send-ledger excerpts. A cached receipt over
96 KiB keeps its original outcome, conversation identity, a labelled answer
excerpt and `reply_location`, an exact `agent.read` history selection for the
committed answer. An explicit `history_exchange` or `history_before` reads that
committed session directly, independently of the latest send's transport or
execution outcome. A missing selected row or an unreadable session reports
`unavailable` with its own cause; it does not claim that the message was removed.
Upstream excerpts remain labelled and are never saved as
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

The shipped `AgentConversations/Resources/agent-hosts.json` seeds each host's launch contract and discovery words.
Loaded editable recipes govern setup through the declared configuration,
command line, ACP or desktop adapter; an arbitrary app name implies no protocol.
The connection action presents a card when policy requires one.

Every recipe consumer reads the current files through the serialized recipe
owner; a hand edit is visible on the next read, without relaunch. No catalog
snapshot survives between reads. Launch validates the addressed file under
its file lock. Seeding runs at startup (or when a missing A2A recipe is first
needed), using explicit `seedHost` and `authoredFields`; missing provenance is
a named repair, never reconstructed from a previous recipe or today's seed.
Only the structured Grok `navigation` controls are accepted; the retired flat
navigation fields and desktop selector alternates are removed.

An ACP permission callback's successful `false` is a denial. A missing or
throwing permission service is `permission_decision_unavailable`, with its
original `permission_failure`; it attempts session cancellation and a `cancelled`
outcome for every open permission request. Cancellation-write errors remain visible.
This terminal local failure leaves completion unconfirmed and never claims the
person denied permission. The existing turn deadline also bounds a permission
decision that never arrives; no second transport runs.

For hosts configured through MCP settings, `AgentHostConfigWriter` edits the
owned entry and `AgentHostConnection` binds a per-contact credential. Other
routes have their own setup, including [Grok Bot](grok-bot-connection.md).
Use the returned status and blocker rather than assuming that configuration
proves a working reply path.

Connect also grants the host's documented allowance for this connection's two
MCP tools, `agent_message` and `agent_reply`, where its recipe supports one.
The card names the resident agent from their current persona and says the other
agent can message their without being asked each time; disconnect removes the
allowance. Reconnecting an existing contact uses the same setup disclosure,
since reconnect can add or reconcile these allowances too. This changes the
host's messaging approval, not NativeAgent's Trust or the other program's authority.

| Host | Owned messaging allowance |
|---|---|
| Claude Code | `~/.claude/settings.json`, `permissions.allow`: `mcp__<server>__agent_message` and `mcp__<server>__agent_reply`. The MCP entry itself remains in `~/.claude.json`. |
| Antigravity CLI | `~/.gemini/antigravity-cli/settings.json`, `permissions.allow`: `mcp(<server>/agent_message)` and `mcp(<server>/agent_reply)`. |
| Codex | `default_tools_approval_mode = "approve"` in the owned `[mcp_servers.<server>]` entry in `~/.codex/config.toml`; removing that entry removes the allowance. No additional permission file or receipt. |
| Zed | `~/.config/zed/settings.json`, `agent.tool_permissions.tools`: only `mcp:<server>:agent_message` and `mcp:<server>:agent_reply`, each `{"default":"allow"}`. |

The JSON hosts share `grantMessaging`/`removeMessaging`; the recipe's
`host.messagingPermissionsPath` and `host.messagingPermissionSyntax` declare
the destination and spelling/layout (`mcpCall`, `doubleUnderscore`,
`toolDefaults`). An absent declaration grants nothing. Existing Ask/Deny rules
covering Claude Code or Antigravity messaging refuse setup; Claude Code's
full-name glob and bare-server restrictions are included. Zed's existing
per-tool settings are preserved: only an absent member is added, and only an
unchanged `{"default":"allow"}` member added here is removed. Any other existing
target-tool setting refuses setup. Zed's tool-specific default takes precedence
over its global fallback, so a global `confirm` or `deny` does not block these
two explicit allowances. Its global default, other tools and pattern rules
are not edited.

Ownership receipts retain the original allowance and raw JSON member, so
disconnect removes only additions made here; pre-existing allowances and
later unrelated edits survive. The historical `antigravity-<peer>-permission-backups.json`
filename and `antigravity-messaging` receipt tag remain the shared on-disk
protocol, including for existing Antigravity contacts. Missing ownership
preserves unproven permission bytes; an absent recipe permission declaration
also prevents guessed permission cleanup. Unreadable receipts/settings refuse the
operation. A recorded allowance later removed by the person is not silently
restored. Backups are prepared before replacement; receipts are published and
older undo files pruned only after replacement commits. A failed replacement
keeps the preceding receipt and undo, plus the prepared backup. A later receipt
or cleanup failure is reported and needs inspection; it does not undo a saved
configuration or prove the connection works.

Each individual configuration edit owns a fresh replaced-install recorder,
passed to its format splicer. One connection can edit several files without
carrying a displaced helper's identity into another file's receipt.

Existing connections adopt the new expected settings through the existing
Connect/reconnect path, after recipes load and merge untouched seed fields.
The settings check within `agent.verify` writes no host settings: an older Codex entry or missing Claude Code
allowances names `agent.connect` as the reconciliation action. Reconnect keeps
the same peer/key and updates only owned settings. Launch discovery already
connects new settings hosts and repairs missing keys; it does not automatically
reconnect every saved keyed host. Restart Codex/Claude Code sessions to load
their new MCP entry; no session is restarted here. Configuration and approval
still need an authenticated message/reply to prove the route.

Other seed routes keep their current setup:

| Host | Approval support and why no settings allowance is written here |
|---|---|
| Cursor / Cursor Workspace | Documented per-tool `server:tool` entries in `permissions.json`, but defining them replaces the UI MCP allowlist and requires a selected Run Mode. Automatically creating that file could discard existing approvals; Connect leaves it alone. |
| Cursor CLI | Seed uses ACP `sessionMCP`, not a persistent server entry; its documented `--approve-mcps` approves all servers, not just these two tools. |
| Goose | Documents per-tool permission levels; this recipe supplies tools through ACP in chat mode, without editing its persistent settings. |
| Hermes | Supplies tools through ACP with its own permission bridge; no documented per-server/per-tool auto-approval for these session-injected tools was established. Its global modes are not a scoped allowance. |
| Claude Desktop | Has user-facing tool approval controls; no documented writable scoped allowance in its MCP JSON entry was established. |
| LM Studio | Documents `mcp.json` server registration; no writable scoped auto-approval contract was established. |
| OMP / ChatGPT Dot / Grok Bot / Muse | These recipes use the running bridge, local environment, webhook, or desktop route; they do not write a persistent MCP server whose tool approval can be set here. |

Host contracts: [Claude Code permissions](https://code.claude.com/docs/en/permissions#mcp),
[Claude Code MCP](https://code.claude.com/docs/en/mcp),
[Codex configuration](https://developers.openai.com/codex/config-reference/),
[Zed tool permissions](https://zed.dev/docs/ai/tool-permissions),
[Cursor permissions](https://cursor.com/docs/reference/permissions),
[Gemini MCP](https://geminicli.com/docs/tools/mcp-server/),
[Goose configuration](https://goose-docs.ai/docs/guides/config-files/),
[Hermes ACP](https://hermes-agent.nousresearch.com/docs/user-guide/features/acp),
[Claude Desktop MCP](https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop),
[LM Studio MCP](https://lmstudio.ai/docs/app/mcp).

### Honest states

Each send has one outcome, read from its conversation record. A failed
dispatch settles that record immediately; history, home, the reply report
and receipt detail all say `failed`, even if older executor progress says
`running`. Delivery is claimed only from confirmed delivery evidence;
transport acceptance alone remains unconfirmed. Older inconsistent records
are projected on read, without rewriting their saved history.
Default and named contact reads use that record and contact history.
Reading a failed-send receipt with `details: true` is still a successful read:
its `execution: executed` and `effect: none` describe that read; the retained
error describes the send.

A contact's health is what happened on the wire. A failed send whose receipt
proves nothing was sent (`sent: false`, `effects: none` or `execution: not_run`)
reads **Not reached yet**, with the failure's own reason and date. It does not
break the reply path, trigger background reply-path repair or prohibit the next
send. Positive delivery or occurred/partial/unknown effects retain possible
delivery even if other fields disagree; absent evidence remains uncertain.
Only a possibly delivered message without a reply contributes to a broken path
or a reply deadline; a contact's bare unavailable mark proves no delivery.
An earlier unresolved possibly delivered failure still counts when a later
attempt sent nothing. A newer proven reply clears the older failures.
A failed send returns its first outcome with the owning repair action. It
never runs a repair and a second send automatically. `agent.verify` is an
explicit dry operation; desktop verification checks the authored labels once,
without selector guessing or rewriting the recipe.
A send whose reply deadline passes reads **unanswered** ("No reply"), not
failed: the deadline proves only that no answer came, never that the send was
lost. Its owed accept and answer let go as `expired`; only `sent: false` makes it
not delivered.

Desktop contact health reads today's Accessibility grant and app installation
without opening a window, prompting for permission or sending anything. A
structured Accessibility blocker whose grant is now present says the cause is
gone and the next send may try. Older desktop receipts without a blocker code
keep their original reason and report the current prerequisites explicitly;
health never infers a cause from message text. Readiness is not reply proof.
Saved health is reinterpreted from conversation receipts on load and refresh,
so old unsent failures lose their broken-path mark and stale repair guidance
without a migration file or a resend.

Desktop permission refusals carry the Accessibility permission-card remedy.
If the person types, holds the keyboard or takes the foreground before Return,
the desktop-chat send says they held off because the person is using the Mac,
nothing was sent, and it is waiting for the Mac to be free and will go then.
Its full text and original send id stay in the conversation's existing queue,
ahead of later follow-ups. Unknown input presence also waits, without claiming
the person is using the Mac. The shared presence owner says away after five
minutes without the person's input; that edge (or a driver change while away)
asks the conversation's existing release drain to unhold it only with positive
away evidence and a permitted driver. The resumed send clears the driver on its
explicit Mac operation and obtains a fresh binding at the desktop route,
through the normal permission chain. Startup uses the same path. A person-typed
queued send is terminal not sent after a restart because their original send
act does not carry over.
Explicit handback is distinguished from physical input and says to return
control; it does not enter automatic retry. A live hold has no expiry and
retains its text; `agent.cancel {clear_queue: true}` withdraws it. Missing or
unreadable presence or authority never means free. The receipt is `held`, not failed; when released,
the ordinary reply and delayed-answer path continues. An emitted Return always
keeps submission uncertain until the outgoing row confirms it and never enters
this queue automatically. This replaces the former “try again shortly” refusal.

Muse 9's recipe selects its first `AXWebArea` as the chat's content region
and names its `Side chats` navigation button. Region discovery can find
readable siblings past an unreadable element, reporting that element in the
native diagnostic log; an incomplete search without a matching region is a
read failure. Controls and transcript reads inside that region must still be
complete. Incomplete native reads report up to four unreadable element paths
with their AXRole read errors, distinguishing a missing role from a native AX
failure code. There is no alternate read or send path.

Before desktop input, the exact selected composer's text must be readable
and empty. A draft or unreadable value stops the send with the draft intact.
The sender checks that binding again before paste and confirms the full
composed message before Return. Its one answer observer requires three seconds
of stable, finished text within two minutes; a moved chat or deadline returns
an uncertain outcome with any partial answer. No second late-answer watcher
is started. The courier offers and dispatches only its scoped screen, go,
read, result paging and act operations, so another action door cannot perform
effects outside its send-evidence fence.
These native readers and native AX mutations use the same
[source renderer preparation](USER_GUIDE.md#turn-on-mac-computer-control-and-the-activity-watcher)
as the four verbs, including verified Enhanced mode and its process-scoped
settle. The former Grok-specific Manual write and look/act flag-clearing path
are removed; route-specific driver and posture admission remain in place.

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
Contact and helper reads retain availability independently. An unreadable
optimized read reports its actual error without running a second full reader.
Helper thread reply times use recorded exchange settlement or `replied_at`;
missing times display **Time unavailable** and supply no chronological evidence.
A failed helper refresh labels retained history; an empty-history claim requires
a successful first read. After an accepted replacement, a failed held-copy
withdrawal leaves that copy visible and reports the separate withdrawal failure.
An unchanged normalized conversation record leaves its committed store bytes,
experience publications and follow-up wake notifications untouched. Necessary
life normalization still commits when it differs from saved state.

Builder, MCP and A2A ingress share `AgentContactTasks` admission, record-owned
execution, output settlement and retained receipts. Builder formatting remains
at its door. Enqueue acknowledgment (30 seconds) and reply (600 seconds) bounds
end only the HTTP wait: a late enqueue still admits its original run. The bridge
reads the app's actual selected chat; recent activity cannot select a chat.
Discovery publication must commit before readiness, admission and recovery begin;
its file failure is exposed in listener health. HTTP JSON, SSE and gRPC record
reply acknowledgment through the same task operation after successful writes.
Retained reply reads keep `attachments` at the top level: builder attachment
descriptors retain their saved paths; canonical file parts carry their bytes as
`base64` with `mime`, `name` and `byteSize`. Reading produced words or files
acknowledges that output even when execution failed or was canceled; the
execution verdict stays unchanged. An empty reply or a failed transport write
does not acknowledge output.
MCP acceptance and requested retrieval are independent: an accepted message with
a failed waited read retains enqueue evidence and returns `isError: true` with
the read failure and repair lever, without suggesting a resend.
The MCP projection and `nativeagent-link` share a 1 MiB limit for the complete
encoded JSON-RPC body, including text, structured content and held messages;
SSE allows only its framing bytes beyond that body. If files do not fit, the
result carries `reply_artifact` instead of their inline payload. Its `read_with`
calls `agent_reply` with the same session/request, an exact content-digest
`artifact_id`, and a byte `offset`. Each call returns at most 64 KiB as base64,
with `next_offset` and `has_more`. Concatenating decoded chunks yields JSON with
the original `attachments` and `delegated_completions`, including every file's
bytes. `nativeagent-link reply --artifact <id> --offset <n>` reaches the same
read. The canonical task remains the only payload owner; a changed, expired,
missing or unreadable payload is unavailable, never another send. References
alone do not acknowledge output; returned words, inline files or the last
artifact chunk do. Oversized non-file fields report a projection failure while
retaining execution evidence and held-message settlement.

The old builder receipt reader remains solely for retained historical rows that
have no canonical task. Missing execution fields stay unknown; combined delivery
statuses cannot supply terminal execution facts. Historical completion artifact
verdicts also remain readable while retained files contain them. No current
builder ingress writes the old message-reply log.

A builder completion response reports the retained execution state, never a
successful receipt read as successful execution; a failed task returns HTTP 409
with `status: failed`.
A queued builder turn recovered after restart consumes
its exact saved session/run and framed input, then uses the same contact-reply
settlement as live ingress: recording the incoming reply and routing their answer
back to the asking chat. Settlement failures retain produced text/files and owe
repair on that task; they do not start another turn.

| State | Meaning |
| --- | --- |
| `listed` | Known, not set up. |
| `set up` | Configuration exists; no round trip is proven. |
| `connected` | Historical route proof in connection detail: an authenticated inbound message or a message/reply exchange crossed it at the recorded proof time. Contact summaries use `answered` and the thread's `last_answered` instead. |
| `can send; replies aren't connected` | A send-only route; any answer needs an inbound path. |
| `unavailable` | The route or required credentials are unavailable. |

A connected contact is not proof that its latest task finished. A new authenticated inbound
message clears an older unavailable mark on its credential-bound return door;
ACP and desktop routes still require their own round trip. Request-file
reconciliation reads Grok request records only for Grok Bot contacts; other
contact kinds retain their own receipt and reply owner.

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
become model chat messages. AgentScreen's `doorLines` owns both this projection
and the next person-started turn's elsewhere context: the newest five exchanges
since their last reply there, with each side bounded to 600 characters. The same
transcript index also feeds up to three helpers' newest replies into that
turn's context, under the [elsewhere bounds](ANATOMY_OF_A_TURN.md#4-the-provider-request-is-assembled).
Peer-steered turns receive the person's other-door count and time, never their
words, bridge words or helper replies.
Phone contact sends retain the action owner's refusal or unconfirmed outcome;
only an accepted terminal send returns the refreshed thread as success.
The former per-bridge action/count summary is removed. These shared timeline
reads preserve unavailable classification/history evidence through the checked
workspace owner; see the [turn anatomy](ANATOMY_OF_A_TURN.md#4-the-provider-request-is-assembled).
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

Present capability flags must be booleans; omitted optional flags are not
offered. Task states must match their wire enum exactly (explicit 0.3 `unknown`
or 1.0 `TASK_STATE_UNSPECIFIED` remains unknown). Present message metadata and
`provider_failure` must decode in their declared shapes. Discovery, send/get,
task lists, streams and push updates use those same checked wire readers;
malformed evidence retains its cause rather than becoming a capability omission,
unknown state or absent failure. A send whose response is malformed remains
unconfirmed and reports `malformed_remote_evidence` with `response_failure`.

An interface outside A2A 1.0, nonlocal endpoint or peer without webhook support
deliberately omits a callback. For an eligible local 1.0 interface in the
canonical app body, the callback owner must return a running
receiver and its checked credential. An unmounted owner, stopped receiver,
missing key or failed Keychain read stops the send before request construction;
it never becomes advice to use streaming or task reads instead.

The NativeAgent adapter uses the bridge base URL and authenticated
`/agent/card`, `/agent/message` and `/agent/reply`. Reply recovery needs the
returned request and session identities; keep them after an uncertain send.

Dot retains the actual terminal failure and its typed cause when supplied.
Network state and provider-success events never synthesize a cause or start
another turn. Launch resumes only an accepted arrival whose turn has not
started and has no saved failure. Completed room cleanup and its seen/marker
readers are removed; canonical transcript rows remain untouched.

Pull hosts receive the full accepted payload from the canonical contact
transcript, identified by its original send ID. The bounded exchange prompt is
only an excerpt for presentation. That canonical append must succeed before
dispatch; a missing or ambiguous payload, an oversized response, or a failed
held-message drain is a checked failure, never an empty batch. No message is
marked delivering until the whole selected batch commits. Conversation
settlement and queued-work read failures retain the original operation outcome
and exact storage debt in RepairOwed; the accepted send keeps its owner through
actual exit and never runs again to repair bookkeeping.

Held replies have one owner, `AgentConversationStore.drainHeld`, across contact
doors. Native HTTP `/agent/message` and `/agent/reply`, MCP calls, and the
Claude/Codex/OMP bridge's message and reply results carry `held_messages` and
`held_remaining`. Each message contains `at`, `text`, `conversation_id` and
`conversation_name`. A caller takes what is held in its own conversation, in
the contact's own, and in any caller's conversation whose process is gone
(`AgentConversationStore.reaches`: the pid no longer runs, or runs with another
start time); a live caller's messages go only to it, and a caller whose process
cannot be read keeps its messages until a later read decides.
A2A send/get responses carry `nativeagent.held_messages` and
`nativeagent.held_remaining` in the returned task's `metadata`; streaming
send/subscribe carries that metadata on its first event payload, across
JSON-RPC, HTTP+JSON and gRPC. Empty batches omit these optional fields. A door
without an authenticated principal peer ID drains nothing. A drain failure
returns that call's error, leaving the messages held. Only a written JSON
response or first stream event settles the batch as delivered; failed writes,
encoding failures and cancellation before writing release it back to held.
Later stream events do not repeat the batch. Delivery alone does not end the
sender's wait for the contact's answer, regardless of the original transport.
Repeated settlement writes nothing and wakes no observers unless an exchange
or its acceptance obligation actually changes.

News that reaches a contact conversation after its turn ended runs in that
conversation. `AgentContactHeldAnswer.hold` also accepts an answer without an
open turn: it saves the send before appending a held exchange, under
`AgentBridgeCompletionRouter.stableUUID(deliveryID)`. A return to the contact's
conversation (`MindStream.returnTo`) reuses its canonical completed assistant row
as that send, preserving one visible
answer and its completion evidence. Working commentary is excluded from the
held payload; saved attachment paths accompany the answer. Empty payloads,
missing file references and payloads over 8 KiB refuse with their reason and
preserve the saved answer. Repeating the exchange identity writes nothing.
The arrival's `agent-held` route never becomes a person-result notification.
Completion is `completed` / `held_for_contact` once the held owner takes it;
the exchange remains held until the contact's door writes it. Failed response
writes keep it held, and a contact that never calls leaves it held. Recovery
uses the same handoff and cannot replay the work or route it through a send.
An asynchronous Grok desktop reply that cannot be saved owes repair under its
original operation ID, retaining the terminal answer or partial reply and its
observation evidence. A later successful settlement of that exact exchange
settles the debt. Explicit protocol sends preserve the caller's `message_id`
as the protocol's string and bind it once in the exchange journal to a separate
internal operation UUID. A2A IDs need a non-empty string; their shape is never
validated as an internal UUID. Grok's request owner retains its UUID message-ID
contract. Without a supplied Grok ID, the send owner generates one once and
keeps it in the saved approval arguments. Exact and conversational approval
resumption use the same send/settlement owner as direct sends; the actual result
and its read locator replace the approval-waiting state. Grok's reply and history
readers resolve the protocol ID through the journal's operation binding.

Card discovery fetches the exact configured URL once. Transport errors remain
typed errors, and HTTP failures retain their status; neither becomes a claim
that no supported card exists. Helper/desktop identity wording comes from the
profile owner's checked projection of both saved names; missing or invalid
identity fields refuse the operation instead of inventing names. A malformed
worklog row makes its bounded feed read unavailable with the source and tail
row identified, including in continuity; it cannot disappear from an `ok` feed.

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
| `Agents/NativeAgentA2AWire+Tasks.swift`, `AgentContactTasks+Bridge.swift`, `AgentContactTaskReceipts.swift` | One retained task owner for inbound contact and builder admission, work, produced output and receipts; HTTP waits do not own accepted work. |
| `Agents/MindStream.swift`, `Agents/AgentContactHeldAnswer.swift` | Returns to the conversation that started the work; a contact's held answer. |
| `Agents/AgentConversationContinuation.swift`, `EngineComposition.swift` | The contact doors' reply reads and deadlines, run by `delegation_outcome`. |
