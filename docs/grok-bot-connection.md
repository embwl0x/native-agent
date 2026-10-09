# Grok Bot connection

The `grok-bot` row in `AgentHostDirectory` uses the installed app with bundle ID
`com.anysphere.sand`. Its route is a webhook routine with a local reply helper.

## Connect

Use `app {"action":"agent.connect","args":{"agent":"Grok Bot"}}`.
Sign in to Grok Bot and grant NativeAgent Accessibility access if required.
Approve Grok's own routine/local-execution requests when it asks. Its approval policy is
independent of NativeAgent Full Mac: ask-every-time requires a person for each
local reply command unless they choose another policy in Grok.

Setup asks the selected Bot to create one Active routine named
`NativeAgent reply <contact UUID>`. The saved Bot name is used again for
cleanup; setup defaults to `grok` when no name was selected. The request tells
Grok to reuse an existing routine and preserve its local execution policy.

The native importer reads the routine credentials into Keychain. If it cannot,
the setup card offers **Read routine securely** and a masked field accepting
`{"url":"…","key":"…"}`. **Save securely to Keychain** clears that field.
Never paste these secrets into chat. A `set up` result means credentials were
saved, not that an answer has arrived.

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
- `Sources/NativeAgentApp/GrokSecureSetupCard.swift`: secure credential fallback.
- `Sources/NativeAgentLink/NativeAgentLink.swift`: local reply command.
