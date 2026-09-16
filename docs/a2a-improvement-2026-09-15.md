# Agent communication improvement — 2026-09-15

User asked for communication that lets Agent address other agents as conversations,
including their bots, local coding agents, other NativeAgent installations, and
future agent systems. This work follows the completed AX campaign; it is not an
extension of its three-hour timer.

Agent identified transport bookkeeping, lost conversation context, ambiguous
queued/completed states, and private-log reply recovery as their main friction.
The implementation gives those operations one small lazy interface while retaining
existing execution and permission owners. Details and supported protocols are in
[agent-communication.md](agent-communication.md).

## Delivered behavior

- One directory of stable references and declared operations; availability stays
  unknown until checked.
- Local message/receipt routing through the existing bot and coding-agent owners,
  with the facade and executor's explicit policy constraints both preserved.
- Exact bot ownership checked before an entry is reconciled or marked read.
- One durable peer address book; dedicated bearer credentials; corrupt configuration
  fails closed without replacing its bytes.
- Negotiated A2A 1.0/0.3 clients for supported JSON-RPC/HTTP+JSON exchanges, task and
  conversation identity, lifecycle states, input/authentication needs, parts and
  artifacts. Same-origin endpoint and supported-auth checks precede dispatch.
- Generic NativeAgent bridge card, durable enqueue acknowledgement, and exact
  paged reply recovery over the existing receipt stream. The listener remains
  authenticated and loopback-only; ordinary turn admission remains authoritative.
- Bounded HTTP capture, rejected redirects, request cancellation, no automatic
  replay/fallback, and explicit unknown outcomes when evidence is incomplete.

## Validation

Integrated `swift build --jobs 4 --force-resolved-versions --skip-update` passed.
Initial core selection: **92 tests across 11 suites passed**; initial app selection:
**8 tests passed**. Final counts following live-discovered fixes are recorded below. The fixtures cover negotiation, request/task correlation,
conversation mismatch, unsupported auth, cross-origin refusal, no-follow redirects,
bounded capture, local gate ordering, explicit blocks on either policy name,
loaded/unloaded tools, bot receipt ownership, corrupt stores, exact recovery,
Unicode pagination, and synthetic-root credential denial.

Build fixes were limited to the new transport's required serialization argument
and a bridge dictionary type annotation. Test fixes corrected a throwing macro
and a malformed fixture. One fixture initially omitted the process-global-tools
opt-out and created a dedicated synthetic peer credential; that exact test-owned
credential was deleted, the fixture was isolated, and the final selection passed.
No user credential was read or changed by that fixture.

The ordinary installer passed signing plus authenticated chat/source readiness.
Installed process: **92782**, source branch `review-0414f`, base commit `cc124d47`
with the preserved dirty working tree. Logs are under
`/tmp/nativeagent-a2a-20260915-{build,core-tests,app-tests,install}.log`.

The installed generic card returned the declared protocol and durable-enqueue
contract. A bounded request to Agent was acknowledged immediately with request
`49D23165-E7F4-49B8-8642-CAAD1A37953D` and its exact test-session identity.
The first live pass found two concrete gaps: the receipt reader validated old
payload shapes before checking identity, and strict provider schemas required
fabricated values for inapplicable adapter fields. The reader now checks exact
identity before validating a matching payload; malformed JSON still fails closed.
The new schemas admit null for unused fields, including nested options, and the
router/remote handler consistently remove those null optionals. Added regressions
exercise both observed failures. Final installed acceptance follows below.

No external service account was configured or messaged. Remote interoperability
was exercised with hermetic transport fixtures, not a claim of testing every
third-party agent deployment. There is no public release, commit, or push; prior
dirty work remains intact. Unsupported protocol features are explicitly listed
in the contract document rather than silently advertised.

## Final revision

The integrated build passed after the two observed live fixes. Final selections:
**94 core tests across 11 suites and 9 app bridge tests passed (103 total)**.
The final installer verified signature, authenticated chat, and source identity;
Agent is running as PID **94416**. Final logs have `-final.log` suffixes.
On that installed build, `/agent/reply` recovered the first request's exact
receipt with complete retained scope and no private-file fallback. The scan over
the existing 8.5 MiB receipt log completed in the live request in about 23 ms.
The follow-up acceptance request is `72C5A9B8-CDC6-44CE-8086-FA8717DD7FFE`.

Final Agent acceptance completed with run
`65F4E690-6E19-46FF-B82A-CAA435A623A9`; the generic reply endpoint recovered its
exact receipt with complete retained scope. Agent reported: “The unified interface
works now.” Saved canonical tool receipts independently show one `agent_contacts`
and one `agent_read`, both successful. The historical Claude ID had
`lookup_status: not_observed` against 323 readable retained records, with no
malformed or unreadable source records; this does not establish that the original
message failed or never executed. No retries, other-agent sends, bot runs,
contact changes, settings changes or private-file fallback occurred in the final
acceptance. Authenticated readiness remains true on GPT-6-Astra, with context flow
and organism enabled. No selected implementation issue remains open.
