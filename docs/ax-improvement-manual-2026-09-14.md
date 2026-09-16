# NativeAgent Agent Experience — manual improvement pass, 2026-09-14

User requested a dedicated AX (Agent Experience, not Apple Accessibility) loop,
Agent's input, and a deep manual pass before refining that loop. This pass
completed research, source and resident investigation, three coherent interface
improvements, installation and acceptance. It is not a claim that every possible
agent journey is defect-free.

## Design and research

The installed toolkit entry is
`~/.agents/skills/nativeagent-ax-improvement-loop/SKILL.md`.
Invoke `$nativeagent-ax-improvement-loop`. Its field guide carries transferable
lessons; this document carries dated evidence. The nativeagent skill, skills
index and general improvement loop route explicit AX work to it.

Primary design inputs:

- [SWE-agent ACI research](https://arxiv.org/abs/2405.15793): interface design
  affects usable agency; coding benchmark gains are not Agent performance claims.
- [Tools for agents](https://www.anthropic.com/engineering/writing-tools-for-agents):
  clear selections, useful responses and actual trajectories matter more than
  simply minimizing tool count.
- [Context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents):
  bounded context should retain useful pointers to retrievable detail.
- [Agent evaluations](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents):
  distinguish the narrative from the outcome; inspect the actual path.
- [MCP tools specification](https://modelcontextprotocol.io/specification/2025-11-25/server/tools):
  structured contracts and clear errors support recovery; annotations confer no authority.

Agent identified original-evidence retrieval, action-versus-outcome ambiguity,
resurfacing resolved limitations, historical delegated recovery, and an older
unverified prose-redaction issue. Input run:
`E2184AAC-3B71-412F-8FC3-E870CF18FF5B`. Draft review:
`DF52D99F-3C3F-4EA2-8D0C-7B5075996E93`. Their recommendations informed acceptance
lineage, coherent journey tests, verification reserve and stopping expansion on
regression. No mandatory reviewer wave, new framework or production metric store.

## Implemented behavior and evidence

### Original evidence retrieval

History search now supports exclusive ISO8601 before/after bounds and
oldest/newest ordering, retaining relevance as the default. Omission, null and
blank optional dates mean unbounded; invalid nonempty values fail clearly.
Results provide exact `read_chat_message` locators and coverage information,
including unreadable files/malformed rows. Partial coverage does not masquerade
as no evidence. Chronological hybrid results explain when exact matching helps.

First resident run `D19CE13C-3E1A-44CC-A836-FB4CBD956701` exposed broad phrase
matches and blank-date retry friction even though the component worked. Both
informed the finished contract. Final run
`DFCCE0A4-85F6-40D7-AD16-984A73578BE4` used an exact phrase, time bound and blank
optional date without repair, then read message
`09A2100D-1765-4190-9B81-7BD73032608F` in full (949 characters, dated
2026-08-22T23:41:21.755Z). Agent correctly identified it as a historical Codex
instruction, not proof a screensaver was observed or dismissed. One resident
acceptance case; not a retrieval-quality benchmark.

### Tool discovery and loading

Category, singular name and plural names combine across app/core routing rather
than silently overwriting selections. Invalid categories are rejected before
mutation. Unknown-only requests report unavailable, mixed requests partial,
and sessionless requests preview available tools without claiming a load.
Explicit persisted selections retain their protection against category caps;
turn-only tools do not create empty persisted files during reclassification.

The first resident acceptance combined research category with explicit history
tools successfully. Focused app/core tests cover mixed selections, invalid and
unknown requests, previews and persistence behavior. Lazy loading remains the
policy; an explicit load for a previously unavailable reader is not a failure.

### Large-result recovery without action replay

Projection and retained pages preserve `original_result_class` separately from
page `status`, identify recovery-only scope, and direct missing-output recovery
toward retained pages or existing receipts rather than repeating writes. Typed
native outcomes survive serialization/redaction; retained content stays redacted
and session/turn scoped. Page success does not prove external settlement.

Resident run `A93B2B6A-F809-44F2-B493-89FAAD566353` revealed an upstream defect:
the file adapter clipped at 30,000 characters before the pager could retain the
requested window. The reader now preserves that byte-bounded window (existing
200,000-byte ceiling and compact defaults unchanged). Metadata no longer counts
bytes discarded by a second presentation clip.

Final run `2EAB9818-27C5-4B8B-84E5-9EF571FF4D68`, trace turn
`54802ea7-7604-4773-801b-d01596c5b55e` at 2026-09-14T23:24Z, read synthetic
`/tmp/nativeagent-ax-recovery-fixture.txt` once with max_bytes 60,000. The 40,037
bytes were retained across six pages. One read of zero-based page 4 through
handle `26f4027c-6a42-436f-9a94-6741aac890d6` recovered the marker beyond character
35,000. Original class was succeeded; page status completed, recovery_only true.
The canonical `data/turn_traces/2026-09-14.jsonl` dispatch records confirm one
source read and one page read, without repeated effects. Agent reported this
materially easier. This is one synthetic resident case, backed by exact-content
and outcome-isolation tests, not an external-action verification.

## Loop refinements and no-change findings

The loop now explicitly separates matching from navigation, tests provider-shaped
optional arguments, preserves combined selections, follows upstream information
loss, distinguishes recovery from action success, and requires evidence lineage.
It judges improved/unchanged/regressed/inconclusive against the intended outcome,
not a composite score or call-count target. Research and Agent's suggestions are
inputs; canonical evidence remains required.

The earlier redaction concern was not reproduced as a current defect: source
already uses whole-token handling. No speculative redaction rewrite. Historical
delegated uncertainty remains history, with no replay or invented delivery proof.
No persona, cognition, Trust, authentication or Liquid Glass changes in this pass.

## Changed owners and validation

- History: `SwiftToolDispatcher+ChatHistoryTools.swift`, core schemas and history tests.
- Discovery: `AppChatToolDispatcher.swift`, `SwiftToolDispatcher+ToolLoading.swift`,
  `ChatSessionActiveTools.swift`, core schemas and app/core loading tests.
- Recovery: `ProviderToolResultRecovery.swift`, `ToolLoopSupport.swift`, both native
  and text-compatibility dispatch projections, `FileSystemActions.swift`, focused tests.
- Documentation: tool-loading/architecture notes, this report, current handoff,
  dedicated AX skill/field guide and toolkit routing.

Integrated optimized install: `./script/install_app.sh`; final owner PID 22073,
signature, authenticated bridge, chat and dirty-source identity passed.
Log: `/tmp/nativeagent-ax-recovery-install.log`.

Finished selection/history/recovery batch: 40 core tests and 8 app tests passed
(`/tmp/nativeagent-ax-core-tests-final.log`, `/tmp/nativeagent-ax-app-tests-final.log`).
After the resident-discovered file boundary fix, 22 focused read/projection/recovery
tests passed (`/tmp/nativeagent-ax-recovery-tests-final.log`), including full-content
reconstruction and safe byte-window limits. These counts overlap; do not sum them
as a unique-test total. Skill validation and whitespace checks passed.

Branch `review-0414f`, based on `cc124d471`, remains dirty with earlier UI and
capability work preserved. No commit, push or release. Current bounded AX batch
is complete. Future passes should select new observed friction, not automatically
repeat this list or promise all possible workflows have been exhaustively tested.
