# Grok Bot connection

The `grok-bot` row in `AgentHostDirectory` uses the installed app with bundle ID
`com.anysphere.sand`. Its route is a webhook routine with a local reply helper.

## Connect

Use `app {"action":"agent.connect","args":{"agent":"Grok Bot"}}`.
Sign in to Grok Bot and grant NativeAgent Accessibility access if required.
Foreground setup, desktop sends and foreground restoration use the Mac hands'
measured app activation, shared with their window raise. App activation does not
read AX windows, so restoration to NativeAgent retains the self-AX fence.
It includes the target-owned Apple Event when needed. If macOS refuses that event,
the receipt names Automation permission for Grok Bot in System Settings →
Privacy & Security → Automation. Front-app waits observe workspace activation,
without subscribing to Grok's Accessibility tree. An observation failure names
the failed observation rather than claiming a front-app or panel failure.
Approve Grok's own routine/local-execution requests when it asks. Its approval policy is
independent of NativeAgent Full Mac: ask-every-time requires a person for each
local reply command unless they choose another policy in Grok.

Setup asks the selected Bot to create one Active routine named
`NativeAgent reply <contact UUID>`. The saved Bot name is used again for
cleanup; setup uses the recipe's main chat when no Bot was selected. The request tells
Grok to reuse an existing routine and preserve its local execution policy.

The native importer reads the routine credentials into Keychain. If it cannot,
the setup card offers **Read routine securely** and a masked field accepting
`{"url":"…","key":"…"}`. **Save securely to Keychain** clears that field.
Never paste these secrets into chat. A `set up` result means credentials were
saved, not that an answer has arrived.

For Grok Bot 0.75.3, import selects the exact routine title **inside the
Routines content list**, requiring its Pause switch. It invokes the title
group's `AXShowMenu`, then the enabled **Webhook** menu item. Chat-log titles,
the chat's **Open routine** button and row `AXPress` are not navigation paths.
The Webhook view is read natively. Readable fields use their AX value directly;
only a masked field can use its own group's Copy button. Empty or unreadable
unmasked fields stop without Copy. Native code preserves the clipboard and
captures Copy's published generation once, including a pending publication
after physical takeover. It accepts text only while that generation remains
current, checking again after the native read; a newer generation is refused
and never adopted or overwritten. Settlement clears the owned generation and
restores the previous contents only if that generation is still current,
after success, failure, Stop or physical takeover alike. Neither field values
nor clipboard values reach the recipe, JavaScript, model, logs or receipts.
A receipt reports field counts and whether
each was readable or needed its own Copy control. Field labels, Copy grouping
and the closing control are matched against the recipe; a mismatch stops with
structural evidence and the recipe repair.

`Modules/NativeAgentCore/Sources/AgentConversations/Resources/grok-routine.json`
is the one shipped navigation seed, bundled with AgentConversations. The
existing recipe seed path puts it in `host.grokRoutine` of
`agents/recipes/grok-bot.json`. Unchanged seed fields move forward; authored
fields remain theirs. Setup rereads that file on every Connect, including hand
edits. They can read it with `agent.recipe {host:"grok-bot"}` and save the whole
corrected recipe with `agent.recipe_write`. The data contains labels, roles,
scopes, AX navigation actions and their dismissal controls, never credential
transfer instructions. When a control is missing, setup names the step and
expected control; a missing Webhook item includes the enabled items actually
found in the row menu. The lever is to update their recipe to Grok Bot's current
UI. It does not guess that closing Details will repair a missing field.

Connect reuses an unfinished contact, including `grokSetup=creating`. Before
Return, setup records that the request's submission is unconfirmed; a verified
request or routine marks it confirmed. A later Connect reads the routine and
continues secure import without sending an uncertain or confirmed request again.
An attempt that stopped before submission can finish sending on the next Connect.
Older unconfirmed attempts remain uncertain; Connect asks for their request to be
checked in Grok Bot rather than asserting that they were sent or resending them.
Sending to an unfinished contact reports its setup state and asks for Connect
before reading credentials or posting a message. Setup blockers retain their own
remedy; they are not replaced by secure-paste advice. Panel cleanup and foreground
restoration run through `settle` with an independent cancellation lifetime under
the original driver generation, so Stop does not cancel their release. Panel cleanup
settles once in reverse navigation order, for steps this import opened; if it
fails, its outcome follows the original blocker. A failed child dismissal
does not issue another ancestor action. An already open Details view stays
open; an existing secret-bearing view blocks import before navigation. Awakening
failures open no panel and do not initiate panel cleanup. Physical input retains
precedence through that same generation, including cleanup and foreground restoration.

## Delivery and disconnect

Send and read through `app` actions `agent.message` and `agent.read`.
Before the webhook POST, `GrokRequestStore` binds the message ID to its contact
and initiating conversation. HTTP 200 means accepted and waiting; a network
failure means an unknown outcome. The webhook is not automatically retried.
A read after ten minutes without an answer reports `no answer in time`;
silence cannot establish whether Grok is waiting for local approval.

The routine runs the saved absolute helper path:

```text
nativeagent-link reply --contact <UUID>
```

It supplies `{"message_id":"…","text":"…"}` on stdin. The helper reads its
credential from Keychain and sends the contact bearer over loopback. The saved
pending record chooses the destination, not the reply body.
Grok's credential authorizes only correlated replies to pending messages through
`POST /agent/grok-reply`. It cannot use MCP, general messaging, or HTTP/gRPC A2A;
the HTTP and gRPC authentication boundaries enforce this restriction.

`GrokInboundReply` claims the request, saves the answer and settles the exact
conversation exchange. If Agent's waiting turn already took the answer, it
does not start a second turn; otherwise the answer is handed into the initiating
chat with peer authorship. A person-initiated quiet send settles without waking
Agent.

Disconnect with the exact `peer:<id>` from `agent.contacts`. It revokes local
keys and removes the contact. When routine setup was confirmed, cleanup asks
the saved Bot to delete only that named routine. The result distinguishes a
cleanup request from confirmed deletion; if it cannot ask, it names the routine
for manual cleanup.

Release and development scripts still explicitly sign the helper
(`script/release.sh` and `script/lib/development_bundle_signing.sh`).
`GrokLinkCredential` binds Keychain access to the app and that helper during setup.

## Owners

- `Modules/NativeAgentCore/Sources/Agents/GrokBotConnection.swift`: setup,
  send coordination and cleanup.
- `Modules/NativeAgentCore/Sources/AgentConversations/GrokBotRoute.swift`:
  pending requests, webhook delivery and reply-helper instructions.
- `Modules/NativeAgentCore/Sources/Agents/GrokInboundReply.swift`: correlation
  and answer handoff.
- `Sources/NativeAgentApp/GrokSecureSetupCard.swift`: secure credentials for the exact contact supplied by its Agents row.
- `Sources/NativeAgentLink/NativeAgentLink.swift`: local reply command.
