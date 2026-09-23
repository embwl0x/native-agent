# Cache and cognition handoff — 2026-09-20

The deferred next-build list mixed a real felt-label defect with old test
assumptions and parallel fixture interference. No persona, canonical memory,
appraisal policy, or permission settings were changed.

## Implemented

- Felt subjects check a two-word phrase's head against sentence evidence and
  the existing standalone non-name classifier. The existing regression produced
  `readings pull`: a focused diagnostic showed NLTagger calls `pull` a noun even
  in the full sentence, but refuses the bare word as an interjection. The head
  must pass those existing checks as well as the phrase check. Unknown vocabulary
  and modifier verbs remain available for real names such as `deploy pipeline`.
- The memory integration test awaits the existing deferred-promotion drain before
  checking the captured turn. Promotion remains off the reply latency path.
- The cognition overlap fixture registers its MCP server and loads its schema
  in the same isolated active-tool store used by its engine, honoring current
  server availability and lazy loading rather than bypassing them.
- The post-tool exhaustion test checks the current typed failure report and
  `ranPartly` work state while retaining the prohibition on whole-turn retry.
- Organism relaunch tests share an isolated preference suite instead of racing
  process-global preferences. Change-stream tests observe their intended event,
  allowing intermediate owner invalidations. The Activity subscription test uses
  the observed revision baseline instead of assuming bootstrap emitted once.
- A first-turn regression requires all component fingerprints even with no history.

## Evidence and validation scope

Recorded failures were recovered from Claude's wave K test logs. One bounded
core diagnostic reproduced the phrase defect, absent MCP fixture, and old error
type assertion. Memory promotion passed serially, consistent with its deferred
completion race. One serial root diagnostic passed all seven recorded root
cases unchanged, including the synthetic replay envelope. Those root failures
were not grounds to change the agent's runtime semantics.

Payload-free inspection of the 2026-09-20 call ledger found 343 measured chat
calls with component fingerprints, 209 correctly marked secondary unmeasured
calls, and nine workshop calls without chat-prefix fields. This does not prove a
new conversation's entire provider lifecycle, but provides no current evidence
of a first-turn chat fingerprint defect. The regression directly pins its empty
history measurement. Provider cache misses remain best-effort behavior, not a
reason to rewrite prompt policy.

The integrated build passed. The final gate reproduced two remaining owning
failures (felt phrase and MCP fixture); after their corrections, all 37 felt
tests and the exact MCP overlap test passed. The other selected cache/memory
cases and seven root cognition/replay cases passed. Relevant
core filters: `FeltObjectAmbivalenceTests`, `HistoryWindowReceiptPlumbingTests`,
`chatClient_promotesThroughTurnEngine`, `chatClient_recalled_memories`,
`chatClient_no_memories`, `chatClient_no_promoter`,
`chatClient_overlapsResidentProjection`, and
`textCompat_postToolEmptyExhaustionCarriesRetryUnsafeMarker`.
Root filters: `cognitionRuntimePublishes`,
`twoConcurrentSubscribersBothReceiveTheSameChange`,
`organismEnableReconfiguresTheLiveRuntimeAndPersists`,
`syntheticFixtureReplaysAndHoldsEveryEnvelopeInvariant`, and
`ActivityCognitionSubscriptionEvalTests`.

Work remains uncommitted with unrelated dirty work preserved.
