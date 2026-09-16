# Full Agent agent sessions — 2026-09-15

User's requirement: agent conversations receive the same persona, relevant memory,
retrieval, Fluid Context and persistent history as their normal conversations.

## Final installed result

User approved the Xcode 27 compatibility fixes. The three knowledge-graph reads
now await the database read and finish their existing row-to-value conversion
inside its closure; SQL, filtering, ordering, limits and result types are unchanged.
The streaming path's nine nested async task-local bindings were grouped into
typed operations so Swift 6.4 can type-check them. Their order and lifetime still
span both stream creation and consumption. Two test fixtures received equivalent
compiler-compatible value conversion/string assembly; assertions were preserved.

The integrated build passed and `script/install_app.sh` verified signature,
authenticated chat and source identity. Installed PID **15402**, branch
review-0414f at cc124d47 plus dirty work. Fluid Context is active, has matched
generation 3720 and zero degraded sources at the final state check.

Validation: **131/132 selected core tests passed**, plus **10/10 app bridge tests**.
All selected A2A/routing/discovery, three knowledge-graph suites (20 tests),
streamTurn checks and the adjusted streaming telemetry fixture passed. The sole
failed test, `chatClient_textCompatibilityStopsOnlyAfterSixteenExactNoProgressRounds`,
expects two old stop-message strings at ChatStreamingTests.swift:437–438. The
current response uses different wording; sixteen provider/tool calls still passed.
This neighboring pre-existing assertion mismatch was left unchanged. No full-suite
pass is claimed. Logs: `/tmp/nativeagent-a2a-sessions-build-final.log`,
`/tmp/nativeagent-a2a-sessions-core-final.log`,
`/tmp/nativeagent-a2a-sessions-app-final.log`, and
`/tmp/nativeagent-a2a-sessions-install-final.log`.

Five uncoached installed exercises completed with exact replies and no tool
failures (17 tool calls total):

| Exercise | Observed result |
| --- | --- |
| Directory | One catalog, one load, one agent_contacts call; registered contacts separated from unchecked availability. |
| Missing Codex receipt | One canonical legacy reader and one history search; no schema repair, duplicate reader or resend. |
| Continuity after restart | Correct earlier phrase, recipient, conversation and delivery uncertainty; no tools or new contact. |
| Saved Plainspoken reply | Directory plus two agent_read calls recovered its latest saved reply without running the bot. |
| Fresh-session memory retrieval | Two recall_memory and three search_chat_history calls; retrieved related evidence and declined to invent unsupported preference. |

Exact private artifacts are referenced by the five `*-installed.log` files under
`/tmp/nativeagent-a2a-sim-20260915`. These are small-sample demonstrations, not a
general reliability percentage. Directory discovery improved from the observed
irrelevant subagent shortlist; missing-receipt recovery avoided the earlier
invalid page-size argument. Legacy routes remain valid and are not penalized.
No existing peer handshakes were replayed. No implementation/install work remains
pending. All prior dirty work is preserved; no staging, commit or push.

## Implementation

The generic inbound route now allocates a fresh session before canonical enqueue
when identity is omitted; explicit identity continues exactly or is rejected.
Named legacy endpoints retain their established behavior. Outbound NativeAgent
messages retain a new conversation identity before transport, allowing recovery
after a lost acknowledgement. Recoverable results include adapter-correct
`read_with` arguments, without treating acceptance as completion.

Natural subagent discovery includes the conversation tools; directory wording
matches actual discovery intent. The unified read schema no longer exposes a
NativeAgent-only page-size option that caused coding-agent argument rejection.
The advanced delegation reader explains that it shares evidence with agent_read.

Sources: ClaudeBridge.swift, AgentConversationRouting.swift,
SwiftToolDispatcher+AgentCommunication.swift, ToolPreloadHeuristics.swift,
BuiltInToolSchemaFactory+AgentCommunication.swift and +CoreSchemas.swift.
Tests cover session allocation/continuation, identity retention after lost ack,
adapter recovery arguments, discovery ranking and the nullable schema contract.

## Full-turn ownership and live evidence

ClaudeBridge uses canonical enqueueUserMessage and client.chat with the active
persona, accepted session and ordinary chat surface. Its shared app factory
injects NativeCognitionRuntime, NativeContextFlowRuntime and memory translation.
No second persona or memory runtime was introduced. Agent authorship, Trust and
the bridge's existing external-MCP restriction remain intact.

These live observations are from the previously installed build, not proof that
the pending changes are installed:

- A natural directory request discovered avoidable category/ranking friction.
- A missing Claude receipt exercise correctly reported uncertainty without
  replay, but made one rejected max_chars call and consulted overlapping readers.
- One Claude send and one Codex send were accepted with exact conversation IDs.
- A second Claude send reused its original conversation without coaching tool
  selection. Agent chose the working legacy claude_message route; that is not
  a failed communication merely because it did not use the facade.
- A separate same-session continuity check correctly retained harbor-lime,
  Claude, the follow-up nonce and uncertainty. Zero tools or resends were needed.
  Claude's delivered_live notices mean inbox delivery, not a peer answer; no
  actual repeated-phrase reply was established.
- A fresh generic agent session used recall_memory four times and
  search_chat_history three times, with no failed calls. It retrieved an existing
  related memory and correctly said the requested precise preference was not
  established by that evidence. No memory/persona content was modified.
- Authenticated state reported Fluid Context active, generation parity and zero
  degraded sources. This plus the source trace and retrieval exercise supports
  shared machinery, not a claim that every contextual detail is identical.

Private exact run/request/session receipts are under
`/tmp/nativeagent-a2a-sim-20260915`. The reusable bounded evaluation runner is
`script/agent_conversation_eval.py`, with cases in
`docs/agent-conversation-scenarios.json`. It sends once only when authorized,
keeps private evidence, and deliberately leaves success to human review.

## Earlier validation blockers (resolved)

Update after User completed Mac Xcode setup: Swift 6.4 and Xcode 27.0 now run;
the license blocker is resolved. Both default swiftbuild and legacy native
build attempts fail on existing async database reads returning non-Sendable Row
values in KnowledgeGraph+ContextRelations.swift:113,
KnowledgeGraph+StudioRelationAudit.swift:142 and
KnowledgeGraph+StudioRelations.swift:256. Proposed narrow correction: map rows to
ordinary values inside the read closure and await the async read. User was asked
to approve this scope extension; approval is pending. No compatibility source
edits made. New logs: `/tmp/nativeagent-a2a-sessions-build-ready.log` and
`/tmp/nativeagent-a2a-sessions-build-native.log`.

Earlier, the default Xcode tools reported an unaccepted license. Using the usable
Command Line Tools compiled the core production modules but the integrated app
failed because SwiftUI's Entry macro plugin is absent. A focused core test attempt
was blocked before execution because that toolchain lacks XCTest. These are not
passing builds/tests. No app install or restart was attempted.

At that stage, Agent was consulted and knew no approved alternative toolchain. User was
asked to review the Xcode agreement; no legal terms or machine settings were
changed. After that decision, run the integrated build, focused core tests
(AgentCommunicationTests, AgentCommunicationContractTests,
AgentConversationRoutingTests, AgentConversationDispatchTests,
ToolCatalogIntentRankingTests, ToolPreloadHeuristicsTests) and app
NativeAgentPeerBridgeTests; install with script/install_app.sh. Then run a fresh
directory, missing-receipt and saved-bot read holdout plus continuity on the
installed build. Do not resend the existing Codex/Claude handshakes.

Build log: `/tmp/nativeagent-a2a-sessions-build.log`; blocked test log:
`/tmp/nativeagent-a2a-sessions-core-tests.log`. Evaluator case listing and
git diff --check passed. Branch review-0414f retains prior dirty work; no staging,
commit or push. Current tree: 97 tracked modified files and 45 untracked entries
before this report, overwhelmingly inherited from earlier work.
