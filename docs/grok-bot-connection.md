# Grok Bot connection — 2026-09-19

The known Grok Bot row declares a routine webhook / local reply route, detected
by Launch Services bundle `com.anysphere.sand`. It does not edit Grok settings,
register MCP, use a daemon API, change execution policy, or add a listener.

Vendor pages fetched and read for this implementation:

- https://cursor.com/help/grok-bot/routines — webhook body, bearer, 200 starts a run;
  routine editing may require asking the Bot in chat.
- https://cursor.com/docs/grok-bot/security#local-execution — desktop local
  execution and the person's existing per-command approval policy.
- https://cursor.com/docs/grok-bot/work — cloud and local computers are separate.
- https://cursor.com/help/grok-bot/connect-plugins — account-wide marketplace
  connections, not a documented custom local MCP configuration.

## Connect

From chat or Agents, Connect raises the normal approval card, titled
“Connect to Grok Bot?”. It explains routine creation, the small local command,
per-command approval in Grok unless the person already chose another policy,
Keychain storage, secure paste fallback, and loopback-only inbound access.
The person approves that card, signs in or grants Accessibility if required,
and approves Grok's own routine/local-execution requests when it asks.

The desktop conversation owner submits one fixed routine request into the
current, unambiguous Grok chat with no draft. The exact helper path is saved
from the installed bundle. The routine name includes the contact's UUID:
`NativeAgent reply <contact UUID>`. An uncertain submission is never repeated.
Setup and cleanup use plain code: activate Grok, click the empty Prompt box,
paste once and press Return once through foreground HID events. The previous
clipboard contents and frontmost app are restored. Confirmation requires an
empty box and visible static text containing the message's first 40 characters.
The open chat is the destination; its name is never used to select a chat.

The native AX reader inspects live controls; no tree, screenshot, secret field,
webhook response body or credential is passed to a model. It imports only
unambiguous labelled URL/key values beneath the exact owned routine's panel.
Unreadable or masked values stop setup. The approved Connect card then shows
the precise safe-import blocker, a **Read routine securely** action (also useful
after Grok finishes creating the routine), and **one SecureField** accepting
`{"url":"…","key":"…"}`. **Save securely to Keychain** clears the field.
Do not put these values in chat. No secret is part of the approval record.

## Delivery and disconnect

`agent_message` binds a nonsecret pending record to the verified asking session
before its single POST. HTTP 200 means **accepted, waiting for Grok**. Network
ambiguity keeps the pending record and never retries. `agent_read(message_id)`
shows that request's state; ten minutes without a reply shows **no answer in
time**. Silence does not prove a local approval was denied or usage exhausted;
the result directs the person to check Grok for those causes.

The routine invokes the absolute `nativeagent-link reply --contact <UUID>`
command with bounded `{message_id,text}` JSON on stdin. The helper reads its
credential from Keychain and sends only that contact's bearer over loopback.
The app's existing contact authentication runs first. Grok's scope cannot use
MCP, general messaging, or HTTP/gRPC A2A. Only the pending record supplies the
destination conversation. Unknown, expired, claimed or answered IDs are refused.
One attributed agent row is enqueued in the original session and wakes Agent
with the existing restricted peer envelope, never as the person's instruction.
An ambiguous enqueue remains claimed rather than risking a duplicate.

Disconnect deletes the local registration/webhook and contact bearer first,
then requests deletion of only the named routine in the open Grok chat.
The result says deletion was requested, not confirmed. If that chat cannot be
reached, the revoked contact remains for a cleanup retry. No other routine is
changed. Release and development scripts still explicitly sign the helper.

## Handoff limits and the one live acceptance drive

No Grok app was driven, no installed accessibility tree was inspected, no live
Keychain item/config/app data was changed, and no app was installed/restarted
during development. Thus the installed UI contract is **not proven**: the
current native bootstrap requires one window with a distinct chat title, one
empty editable composer and one Send button. The importer requires an exact
routine panel and labelled readable fields. UI differences stop with a blocker;
they do not trigger a private API or model-visible secret read.

The owner must do the reserved live drive: Connect, send a unique nonce plus
“what is 12 times 12”, see webhook acceptance, approve the local helper in Grok
if asked, and verify exactly one attributed `144 + nonce` answer in the same
asking conversation. Keychain ACL access by the signed bundled helper also
remains part of that live check. Fix only the concrete blocker from that drive.

The external Agent handoff script was not invoked because its `~/.codex`
location is prohibited for this task; this repository handoff contains the
implementation and the remaining live check.

Both `swift build --disable-keychain --package-path Modules/NativeAgentCore`
and root `swift build --disable-keychain` passed. The final
`swift test --disable-keychain --filter GrokBotConnectionTests` passed two tests.
The initial test compile required splitting a nested Testing macro assertion;
no broader test campaign ran. `git diff --check` passed.

Commit `1f7ba6b7b` contains the initial Core route. The rest is staged and not
pushed: the pre-commit timer inventory gate fails on the existing, unchanged
`NativeAgentA2AWire+Push.swift:59` timer. The Grok setup timer is classified.
The unrelated timer was not repaired and the hook was not bypassed.
