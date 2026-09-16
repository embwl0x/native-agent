# App-managed desktop conversations — 2026-09-15

User requires Agent to speak through one conversation interface, with routine
transport work handled underneath it. The former desktop route returned a
clicking checklist. The live app now consumes that internal plan and executes
it through the existing gated Mac tools.

The ordinary full Agent session remains the speaker. A bounded ephemeral route
operator receives only the scoped contact and exact message as its task. It can
observe the target app, select the saved conversation, type that exact message
once, submit once and observe the reply. It returns conversation text/read/reply
actions, or a plain blocker. No shell, other-agent tools, permission changes,
new runtime, separate persona, transcript store or automatic resend is added.
Future adapters must similarly perform their routine transport work beneath
message/read rather than returning instructions for the caller to execute.

Scope checks constrain exact app identity, allowed conversation navigation,
foreground changes, default action fields, message text, repeat submission and
tool count. Message bodies omitted by compact screen perception can be read
through the existing canonical `read` and turn-result paging tools. A busy guard serializes
desktop conversations. Drafts, ambiguous recipients and approval/login screens
are blockers, not invitations to change permissions or overwrite user input.
Reply text must be grounded in the observed app text. Delivery and observed
reply are separate from independent verification of completed work.
Send replies must occur after the last exact outgoing-message anchor in the
observed text. Results carry `in_reply_to` and
`reply_association: observed_after_outgoing_message`. A standalone read instead
says `visible_conversation_only`; it does not manufacture a protocol message ID
or claim that an old answer belongs to a new request.

Integrated build passed; 12 selected Core checks and four app route checks
passed. The first live attempt stopped before composing: it exposed ordinary
schema-default rejection and bundle-ID/display-name activation comparison.
Those route defects were corrected, with a regression case for default fields
and decorated unread labels. The app now verifies the actual foreground bundle
and returns a fresh scoped screen instead of relying on name-comparison wording.

Final installed verification passed on PID 29042, with authenticated source/chat
readiness and active Fluid Context. Agent used only the unified conversation
tools: recovered the prior Grok reply without resending, then exercised a fresh
associated follow-up. Their final `agent_message` returned `sent: true`,
`status: reply_received`, the exact outgoing `in_reply_to`, and
`reply_association: observed_after_outgoing_message`. Grok replied with the prior
phrase `cobalt field 825` followed by the new marker `amber lake 926`. The new
marker and ordering check rule out merely rereading the old answer. This final
exchange required one message call, no resend, no separate recovery call, and
no Mac/transport operations by the speaking Agent turn. Internal route operations
are visible in the existing turn traces. No selected implementation/live check
remains pending; this does not claim every unrelated app has been exercised.

This is a general route for compatible accessible desktop apps, not a claim that
every future closed system already offers usable controls. Exact contact setup
and existing permissions are required. Unsupported UI or missing evidence is
reported honestly; the route never pretends to have a network protocol ID.

Build: `swift build --jobs 4 --force-resolved-versions --skip-update`.
Install: `./script/install_app.sh`. Logs: `/tmp/nativeagent-desktop-route-*`;
resident-agent evaluation: `/tmp/agent-desktop-route-eval*.json`.
Preserve branch review-0414f and unrelated dirty work. No staging, commit or push.
