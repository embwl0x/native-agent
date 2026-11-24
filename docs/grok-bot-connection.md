# Grok Bot connection

The `grok-bot` row in `Modules/NativeAgentCore/Sources/BodyRuntime/AgentConversations/Resources/agent-hosts.json` uses the installed app with bundle ID
`com.anysphere.sand`. Its route is a webhook routine with a local reply helper.

## Connect

Use `app {"action":"agent.connect","args":{"agent":"Grok Bot"}}`: it answers at
once with the steps (below). Sign in to Grok Bot first.
Setup is what a person would do, and NativeAgent drives nothing and reads
nothing of Grok's window for it. The words are the agent's own ability,
[`grok-bot-setup`](../Resources/abilities/grok-bot-setup.js): the one message to
type into Grok Bot's chat and the steps around it. It is shipped as a seed into
the agent's own abilities, so when Grok Bot's app changes and a step no longer
fits, the agent revises it like any part the agent has (`ability.read`, then
`ability.save` with the edit); the agent's revision stays the agent's across
updates.
Compiled code keeps only the contact record, its Keychain entry,
`agent.grok_paste`'s clipboard-to-Keychain take and the webhook send; the
routine's instruction (the exact reply command and contact) is bound natively
and handed to the ability as data.
`agent.connect` for a Grok Bot contact without a saved webhook answers at once
with `needs_agent_steps`: the chat, the routine name, the ability's `message`,
`steps` and `detail`, and `next_call` (`agent.grok_paste`). It activates no app,
observes nothing, types nothing and takes no desktop lane; it clears old webhook
values and any submission record from earlier builds. If the ability gives no
words, the connect says so and changes nothing on the contact. A contact
already set up answers `set up`. The shipped steps:

1. Type the message into the Grok Bot chat with your own Mac hands and send it.
   It asks Grok to create one Active webhook routine named
   `NativeAgent reply <contact UUID>`, or reuse it (never a second one), with the
   routine instruction below it, to turn it on and change nothing else, and to
   say when it is done or exactly what is needed. It asks for no URL or key:
   Grok keeps those out of chat. Sending it twice is harmless.
2. When Grok says the routine exists and is on, open that routine in Grok Bot
   and press its own Copy for the webhook address.
3. Call `agent.grok_paste` for this contact, then press the routine's Copy for
   the key and call it again. The agent's own hands do not reach the
   person-only secure window (its acts on NativeAgent's own windows run in
   process, and protected windows take no agent input), so the call is the one
   paste that field allows the agent: the app reads the clipboard natively into
   the secure field's sink and Keychain, never into a call's arguments, a result,
   a log or the model, and clears the clipboard unless something newer was
   copied. The field takes `{"url":"…","key":"…"}`, the address and the key one
   after the other separated by a space or a new line (either order), or each
   alone in turn; the contact is set up once both are saved.

`agent.grok_paste` is not a lever: it only moves what Grok Bot's own Copy put
on the clipboard into this contact's Keychain entry while its setup is owed,
and no value reaches a result, so it runs at once and never sits on a card. One
rule decides its path: the person's own press of the Connectors row's button in
the app opens the Mac's secure Grok field for the person's paste (same forms, in
one paste; an open window is brought forward, never a refusal). Every call
through the door (the agent's own, one the person's word decided, an approved
card's replay) takes the clipboard at once, never opens a window and is never
blocked by one. Each paste is independent: address and key in either order,
each saved as it arrives; the one that completes the setup says so and closes
any secure window still open for the contact. A connect that fails carries
`next_call` (the same connect), and the contact shows `setup_owed` until it is
set up. A `set up` result means the webhook was saved, not that an answer has
arrived.

The recipe file `agents/recipes/grok-bot.json` (`host.grokRoutine`) is still read
for the main chat's name (`mainChat`); nothing reads its navigation entries. Approve Grok's own routine/local-execution requests when it asks. Its
approval policy is independent of NativeAgent Full Mac.

An older contact that saved Grok Bot's app as a `desktop` contact gets no
answer back (its app has no MCP entry for this app): a send to it answers
`reconnect_required` with `next_call` (`agent.connect` for Grok Bot). One
connect by name and the steps above make the Grok Bot contact; then disconnect
the desktop one.

## Delivery and disconnect

Send and read through `app` actions `agent.message` and `agent.read`. The
routine's reply command runs through Grok Bot's Mac app, so a send opens that
app by bundle id when it is not running (launch only: nothing of its window is
read or typed, and the send does not wait on the launch). With the app not
installed, nothing is sent.
Before the webhook POST, `GrokRequestStore` binds the message ID to its contact
and the asking chat's session (where the answer returns). Receipts and the
webhook body name the one Grok conversation, `GrokBotRoute.conversation(peer:)`
(the contact's thread), never the asking chat. HTTP 200 means accepted and waiting; a network
failure means an unknown outcome. Acceptance waits at most 45 seconds, the bound every HTTP send
to a contact carries; past it the outcome is unknown. The webhook is not automatically retried.
A read after ten minutes without an answer reports `no answer in time`;
silence cannot establish whether Grok is waiting for local approval.

The routine runs the saved absolute helper path:

```text
nativeagent-link reply --contact <UUID>
```

It supplies `{"message_id":"…","text":"…"}` on stdin. The helper reads its
credential from Keychain and sends the contact bearer over loopback. The saved
pending record chooses the destination, not the reply body.
The conversation journal binds the outbound `message_id` to a separately
generated internal operation UUID. A supplied protocol ID is preserved exactly;
without one, the send owner generates it once. The contact transcript uses the
operation UUID; the pending request and webhook use the bound protocol ID.
An exact send's saved approval carries the original arguments, including that
message ID. Approval resumption uses the same send and settlement function as a
direct send, retaining its read locator and replacing the approval-waiting state
with the actual result. Replies and history correlation read the journal binding.
Retained Grok requests whose protocol ID was their operation UUID remain readable
through one Grok-only binding reader while those saved exchanges exist.
Grok's credential authorizes correlated replies through `POST /agent/grok-reply`
and conversations through `/agent/mcp`, with verified peer authorship under
peer Trust, including Trust → Connected agents. Control routes, direct tool
access and HTTP A2A remain excluded.

`GrokRequestStore` claims the request, persists the full correlated answer and
its pending handover in one durable transition. A failed write leaves it
claimable; an identical webhook replay keeps the saved handover intact.
`GrokInboundReply` projects that saved answer onto the exact conversation
exchange, repeating only this projection after a failed response or restart.
Failed receipt restoration owes repair by file. Subsequent contact reconciliation
retries those receipts while other receipts and contacts continue. Retention keeps
receipts with open restoration debt, and a successful restoration settles that
debt before the receipt can expire. If restoration debt is unreadable, retention
logs the failure and keeps the receipts while new sends continue.
If the agent's waiting turn, a read in the asking chat or the room already took the
answer, it does not start a second turn; otherwise the answer is handed into the initiating
chat with peer authorship. A person-initiated quiet send settles without waking
The agent.

Disconnect with the exact `peer:<id>` from `agent.contacts`. It revokes local
keys and removes the contact first. When setup had given its message (the
contact has a Grok Bot chat), it answers `needs_agent_steps` with
`disconnected: true` and the ability's cleanup message and steps: the agent
types the request to delete only that named routine into the same chat with
the agent's own hands. Deletion is confirmed only by Grok Bot. If the ability gives no
words, the result is `disconnected` and names the routine for manual cleanup.

Release and development scripts still explicitly sign the helper
(`script/release.sh` and `script/lib/development_bundle_signing.sh`).
`GrokLinkCredential` binds Keychain access to the app and that helper during setup.

## Owners

- `Modules/NativeAgentCore/Sources/BodyRuntime/Agents/GrokBotConnection.swift`: the
  contact record, `agent.grok_paste`'s clipboard take, send coordination, and
  connect and disconnect answering with the ability's words.
- `Resources/abilities/grok-bot-setup.js`: setup's and disconnect's message and
  steps, the agent's own to revise.
- `Modules/NativeAgentCore/Sources/BodyRuntime/AgentConversations/GrokBotRoute.swift`:
  pending requests, webhook delivery and reply-helper instructions.
- `Modules/NativeAgentCore/Sources/BodyRuntime/Agents/GrokInboundReply.swift`: correlation
  and answer handoff.
- `Sources/NativeAgentFace/GrokSecureSetupCard.swift`: secure credentials for the exact contact supplied by its Agents row.
- `Sources/NativeAgentLink/NativeAgentLink.swift`: local reply command.
