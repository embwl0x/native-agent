# Agent conversation reader — 2026-09-15

User asked to address Agent's feedback that the unified reply reader still felt
like technical paperwork. Agent requested reply text first, honest separation
of acknowledgements from work completion, and exact continuation actions.

`agent_read` now defaults to a compact conversation projection over the existing
authorized owners. It provides agent labels, reply text, recorded execution and
delivery states, exact `read_with`/`reply_with` actions and available page actions.
`details: true` exposes the original owner receipt. Desktop interaction guidance
and refusals remain intact. No sends, implicit retries, new history storage or
authority changes are introduced by reading.

The live evaluation exposed a source distinction: Codex delivery records may
contain Agent's assessment as well as retained original executor text. The
existing delegation projection now exposes the latter separately. The compact
view prefers the original; if only delivery text exists, it explicitly labels
that source instead of attributing it to Codex. Bot shelf reads supply configured
names, with stable handles kept in actions. Codex thread IDs are translated to
the builder owner's required `codex:<thread>` reference.

Validation: integrated build and final 65 focused tests passed. Installer passed
signature and authenticated source/chat readiness; final installed PID 23532.
Agent's initial live evaluation confirmed easier text discovery, proper
acknowledgement/completion distinction and ready-to-use continuation actions;
their attribution and bot-label critiques were fixed before closeout. Final
installed reads recovered Codex's exact original acknowledgement and Plainspoken's
configured name and reply, both with their exact conversation actions. Chat is
ready, Fluid Context active and organism enabled.
Agent independently reread both exact exchanges after the final install and
confirmed that their attribution/name critiques were fixed. Delivery-only fallback
is covered by the focused test; they did not exercise that fallback live.

Limits are visible: older receipts cannot supply a request they never retained;
coding text is an explicitly labeled retained excerpt. Bot listing headlines
are previews, with exact-entry reads. This is a view of the available exchange,
not a manufactured complete transcript. Continuation actions were checked
against routing and retained identities; this read-only evaluation sent no new
messages to coding agents or bots and did not claim a fresh continuation turn.

Build: `swift build --jobs 4 --force-resolved-versions --skip-update`.
Install: `./script/install_app.sh`.
Logs and private live results: `/tmp/nativeagent-conversation-view-*` and
`/tmp/agent-conversation-view-*`. The read-only instrument's seven-day report
was reviewed as context; unrelated historical leads were not treated as a queue.
Branch review-0414f and unrelated dirty work are preserved. No staging, commit
or push.
