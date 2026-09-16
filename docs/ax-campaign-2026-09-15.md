# AX improvement campaign — 2026-09-15

Authorized by User for three hours. Started 08:17:09 UTC (03:17:09 Chicago);
deadline 11:17:09 UTC (06:17:09 Chicago). Completed the full three-hour window;
post-deadline readiness and observer cleanup verified at 11:17:32 UTC. The
final 30 minutes were reserved for observation/closeout. The timer was not
restarted across compaction.

Preserve the existing dirty checkout and installed Agent. Initial tracked
baseline: `/tmp/nativeagent-ax-20260915-baseline.patch`. No commit, push or
release. Preserve persona/cognition, Trust, authentication and shared Glass.

The updated loop emphasizes current evidenced friction, comparable task
outcomes and uncoached final journeys. Historical leads are not a backlog.
Initial consultation `FA704AB0-39E0-4D3D-AF7A-D91336E867DA` reported no new
blocker; the old unscoped discovery example remains a limited observation.
The instrument (`/tmp/nativeagent-ax-20260915-instrument.md`) supplies historical
leads only. Source HEAD and installed source stamp both cc124d471; installed
dirty provenance is not exact content identity. Initial PID 36659 was left up.

## Selected evidence boundaries

- Exact history lookup discards the canonical reader's failure/parse statistics,
  turning unreadable history into `not_found`. Source inspection confirms this;
  field frequency is unknown. The change uses the existing reader's statistics
  and strict evidence decoding, preserves good matches with incomplete-coverage
  warnings, and avoids claiming a physical row index after skipped rows. Ordinary
  prompt decoding remains tolerant. Expected benefit: distinguish unavailable
  evidence from absence, without replay or storage repair.
- A current installed `grep` fixture with 12 matching lines returned `matches:2`
  with no coverage information at `max_results:2` (51 ms). Receipt:
  `/tmp/nativeagent-ax-20260915-grep-before.json`. The additive coverage contract
  distinguishes selected lines, observed admitted lower bound, possible engine
  limits and clipped text. Counts exclude sensitive filtered matches. No new
  search engine, recursive scope or permissions. Frequency outside this fixture
  is unknown; no speedup claim is intended.

Uncoached recovery prompt sent at 08:19:18 UTC asks for the earlier synthetic
source proof using Agent's chosen route. At 08:27 the trace still shows the
initial provider request, with no retrieval tool dispatched. This is provider
waiting evidence, not an established retrieval defect or failed task verdict.
No retry or parallel Agent turn has been sent.

The original recovery turn subsequently completed at 08:29:49 UTC. Bridge
HTTP returned `still_working` at 600 seconds; the durable transcript holds the
completed answer (`A34E3372-CA60-474C-A4D9-F282DF513FAC`, run
`77D6536E-17FB-4EC7-AC5A-A976879EAFB1`). Canonical turn
`20c6bee6-b96c-4a9c-beae-2541a67d306b` made exactly three successful calls:
tool_load, read_file of the known saved source, tool_result_page. It recovered
`AX_WEB_PROOF: amber-cove-582` and distinguished original complete coverage
from current availability. No supplied route, retry or source fetch. The
session already contained the source locator, so this demonstrates independent
use of known context, not discovery from a cold session.

Initial provider dispatch-to-first-call gap was about 606 seconds, but the first
reported llm.call duration was only 4,467 ms. A bounded read-only source
investigation traced that discrepancy before calling it an app defect; its
findings are recorded below.

Integrated build passed. Finished focused check passed 47 tests in two suites
(`/tmp/nativeagent-ax-20260915-focused-tests.log`), including exact-read damaged
storage, ordinary history compatibility, both search engines, clipping and
sensitive-path preservation. No full-suite claim. Optimized install PID 70316
passed signature/authenticated bridge/chat/dirty-source verification.

## Installed and independent outcomes

The same limited grep case now reports incomplete coverage, six observed
admitted matches and four omitted observed matches (17 ms; single readings,
not a speedup benchmark). `/tmp/nativeagent-ax-20260915-grep-after.json`.
Uncoached inventory run `D68EB35C-EA13-4746-82BD-FF3038CC5092` took 27,021 ms
and verified 76 item lines plus the exact birch terminal note. Six calls:
directory listing, catalog query, and four full small-file reads. It chose its
own route and did not exercise grep's limit; that mechanism is separately
verified by the installed direct probe. Receipts are under
`/tmp/nativeagent-ax-20260915-uncoached-inventory.json` and
`/tmp/nativeagent-ax-20260915-inventory-tool-rows.json`.

A direct exact read of the old C3E web receipt returned complete-scope not_found.
Inspection confirmed that ID is no longer in the live transcript after normal
history evolution; this is truthful absence, not a new error. The saved source
still supported the independent recovery above. No history was repaired.

## Further findings from these journeys

- Provider retry trace at 08:29:20.928 explicitly records a 600-second completion
  wall timeout. The next successful call took 4,467 ms; total turn elapsed was
  629,231 ms. The buffered adapter requests SSE but reads the completed body,
  and existing evidence cannot distinguish connectivity/refresh admission from
  ongoing generation. No arbitrary timeout reduction, new retry or transport
  policy is justified. One bounded read-only explorer traced these owners.
- The actual bridge `still_working` response lacked request identity; terminal
  rows also lacked the HTTP request ID. A narrow additive change correlates
  pending/normal responses, SSE and existing durable reply records, returning
  the existing receipt path and honest retention limits when HTTP wait ends.
  It does not cancel/retry work, add storage or guarantee persistence. Integrated
  build plus 59 selected app checks passed.
- The inventory's query `grep count matching lines in local files` returned
  only file_excerpt despite naming the available grep tool. Exact canonical
  identifiers now outrank descriptive matches within already-allowed scope.
  Neighboring app verification exposed dotted identifiers (`browser.status`),
  corrected before acceptance. Normal natural-language ranking remains intact.
  The corrected build and focused discovery checks passed: 11 core tests in
  two suites plus three app tests with parameterized cases. PID 72699 installed
  these and the bridge correlation change, with authenticated readiness.

Live exact-name catalog receipt now returns grep alone for the previously
missed named query (`/tmp/nativeagent-ax-20260915-discovery-after.json`).
Assessment response `83D1C2C8-BCBC-4BFC-AFED-074C7DCB3903` matched exactly one
durable reply row by requestId, including identical runId/reply. Agent then
recovered that historical receipt in uncoached run
`7C9DDED3-2EBF-41E2-913C-F328047E944D` (41,310 ms), distinguishing it from a new
execution. However, its six-call route exposed continuing natural-language
discovery friction: `search text within exact local file` ranked file_excerpt,
causing a first-80-lines read of unrelated history before a shell search found
the exact row. This success is not graded as optimal routing.

The content-search tool's purpose description now states local text, matching
lines, pattern/phrase and bounded coverage explicitly. The discovery test
inventory now includes actual Full Mac file schemas; after correcting the test
factory call, all 11 tests passed, including three untuned content-search
queries and neighboring filename/read operations. A final coverage guard also
rejects every engine exit except 0/1, so interrupted partial stdout cannot be
called complete; its finished focused check passed (recorded below). No provider timeout,
retry policy, shell gate or file access policy changed.

Agent's assessment correctly credited the existing successful recovery and
inventory routes without claiming new speed or call-count gains. The improved
bridge correlation is independently observed; its pending envelope is covered
by hermetic tests, not a forced ten-minute live stall.

## Finished content discovery and fresh-session acceptance

The content description/coverage build passed; 11 discovery tests (two suites,
parameterized cases) and 14 grep tests passed. Installed PID 74347 passed
authenticated bridge/chat/dirty-source verification. The exact natural query
that caused the old-history detour now returns grep alone, score 7374, within
files scope (`/tmp/nativeagent-ax-20260915-natural-discovery-after.json`).

A fresh NativeAgent test conversation `E93EB9E8-7225-436E-9010-BD15486EAEAC`
received the same receipt-recovery objective with no tool names or route.
Run `424A84A4-5350-43D9-8230-BFE2032B010F` completed in 13,766 ms using exactly
one grep call and recovered the right historical status/run/finding. It did
not replay the original request. The app's selected conversation remained
`644D65F1-0270-4B0B-8ED8-A3F31F2E795D`. This is a useful independent outcome;
the earlier six-call/41,310 ms route had different session/loading state, so
the difference is not a controlled speedup or attributable completion-rate gain.
Receipts: `/tmp/nativeagent-ax-20260915-fresh-reply-recovery.json` and
`/tmp/nativeagent-ax-20260915-fresh-recovery-tool-rows.json`.

Source tracing of the excerpt call found one more bounded correction: it used
an ordinary whole-file open and could block on a named pipe, bypassing the
existing regular-file guard used by read_file. file_excerpt now reuses the
same nonblocking-open/fstat guard, preserving ordinary line-window behavior.
Field frequency is unknown; acceptance uses an isolated no-writer FIFO plus
ordinary/Unicode newline fixtures, never a live pipe. The finished check passed
six tests (including four FIFO and eleven newline parameter cases); installed
PID 75746 passed authenticated readiness.

## Bounded search capture and excerpt memory

Further source tracing showed the search presentation cap came after an
unbounded pipe capture. The engine's `-m` is per file, so recursive output could
materialize far more text than the selected answer. Grep now opts into 1 MiB
capture per pipe, continues draining discarded bytes to avoid blocking the
engine, and reports `capture_truncated`/`capture_byte_limit`. Cut final records
are discarded before the sensitive-path filter; incomplete capture cannot
establish absence or totals. Other process callers retain their prior default.
Integrated build and 17 focused tests passed, including both real engines,
oversized records, simultaneous stdout/stderr capture and unbounded-default
compatibility. Installed PID 77247 passed authenticated readiness. Logs:
`/tmp/nativeagent-ax-20260915-capture-{build,tests,install}.log`.

The adjacent excerpt reader also materialized and split the complete file for
a small line request. The assembled correction reuses stable 64 KiB byte
windows and retains only requested lines while counting universal newlines.
Selected text over 1 MiB returns an explicit `excerpt_too_large` recovery cue;
file mutation returns `file_changed`, without a fabricated total. Integrated
build and final boundary/Unicode/mutation/large-line checks passed.
These are source-supported resource bounds, not measured field leak fixes.
Agent's bounded critique (`5D22D9ED-214E-4801-A7D7-7C99EC45459F`) confirmed no
demonstrated task requires an unbounded excerpt and suggested repeating the
identifying search after mutation because line positions can move. That cue
is included. The final integrated build and ten focused excerpt checks passed
after the cue, and PID 78568 installed with authenticated readiness. Skill
validation and `git diff --check` passed. No full-suite claim.

Installed direct mechanism checks retrieved the small second line after a
1.1 MB first line, returned `excerpt_too_large` for that first line, and marked
the clipped search incomplete even though selected matches were zero. Files:
`/tmp/nativeagent-ax-20260915-{stream-live,stream-limit-live,capture-limit-live}.json`.
An independent objective then asked Agent for the initial label and trailing
bird tag without naming tools or prescribing a route. Run
`F6AB3E75-B9D1-48E5-A1CC-0D27C85B7A0C` used two 256-byte read_file windows with
the same file version and correctly recovered `AX_LARGE_LINE` and `copper finch`.
It distinguished a limited first read from absence and made no changes. This
demonstrates a useful existing recovery route on the final build; it did not
encounter the excerpt refusal and therefore does not prove independent recovery
from that particular error. Receipt/tool rows:
`/tmp/nativeagent-ax-20260915-large-line-{recovery,tool-rows}.json`.

## Timed observation

The owned read-only observer (`/tmp/nativeagent-ax-20260915-observe.py`, session
71243) samples only main-process PID/RSS/CPU once per minute and exits at
11:17:09 UTC. Question: does the final installed process settle after the
retrieval work and remain responsive through delayed receipt checks? Separate
PIDs across installs; no cross-build memory comparison or zero-leak claim.
Samples: `/tmp/nativeagent-ax-20260915-process-samples.jsonl`.

At 09:21 UTC, delayed uncoached receipt run
`035B177D-5961-45E7-AC7D-CFE17B49F19A` (16,717 ms) used one grep call with
complete, unclipped coverage. It identified the original 83D1 request's own
receipt and excluded its mention in another reply; an invented missing ID was
correctly reported absent from the retained log, not as an action failure.
No replay or mutation. Receipts:
`/tmp/nativeagent-ax-20260915-delayed-{recovery,tool-rows}.json`.

At 09:26, final PID 78568 had eleven one-minute samples across its first ten
minutes. RSS ranged 1248.2–1300.2 MiB, latest 1291.2 MiB at 0% sampled CPU.
This includes retrieval turns and is only an early settling observation, not
a leak verdict. No further defect is selected. Remaining time is explicitly
delayed observation and closeout, not additional implementation.

One adjacent source-only trace checked directory omission/recovery. Existing
list_dir already returns total_visible/total_matching, has_more, explicit
immediate-child coverage and complete next arguments bound to a snapshot of
path/filter/order/names/types; it rejects changed continuation and avoids child
mount metadata probes. No new defect or change selected, and no redundant live
directory test was added.

At 10:16:50 UTC, the final process had 62 samples and remained on PID 78568.
The latest fifteen samples ranged 1312.6–1312.9 MiB RSS and 0–1% CPU. The
authenticated readiness check still reported chat ready, ContextFlow active,
and organism enabled (`/tmp/nativeagent-ax-20260915-hour-readiness.json`).
At that checkpoint the owned observer was still running toward the unchanged deadline.

At 10:25, manual boundary review identified a narrow correction in the new
grep capture projection: Swift Character treats CRLF as one character, so a
character-based LF search could discard complete CRLF records before the cut
record. The trim now finds LF in Unicode scalars. Both real engines and both
LF/CRLF endings are in the finished focused check. This does not change capture
limits or path admission. Integrated build, focused checks and install passed,
as recorded next.
Keep the pre-correction PID observation separate from the final install.

The boundary correction passed 17 focused search tests, including four real
engine/line-ending combinations. PID 84756 installed with authenticated
bridge/chat/dirty-source readiness. A direct installed CRLF fixture retained
the complete first record, discarded the cut long second record, and reported
one selected match with incomplete capture coverage (48 ms, not a benchmark).
Receipt: `/tmp/nativeagent-ax-20260915-crlf-live.json`; logs:
`/tmp/nativeagent-ax-20260915-capture-crlf-{build,tests}.log` and
`/tmp/nativeagent-ax-20260915-final-install.log`.

## Changed owners and preservation

- Exact evidence: `ChatOrchestration+SessionHistory.swift`,
  `SwiftToolDispatcher+ChatHistoryTools.swift`,
  `BuiltInToolSchemaFactory+CoreSchemas.swift`, `ExactHistoryEvidenceTests.swift`.
- Search/excerpt contracts: `FileSystemActions.swift`,
  `BuiltInToolSchemaFactory+MacSchemas.swift`, `FileSystemActionsTests.swift`,
  `RepoIntrospectActionsTests.swift`.
- Discovery: `SwiftToolDispatcher+ToolLoading.swift`,
  `AppChatToolDispatcher.swift`, `ToolCatalogIntentRankingTests.swift`,
  `AppChatToolDispatcherTests.swift`.
- Existing bridge receipt correlation: `ClaudeBridge.swift`,
  `BridgePendingReplyEvidenceTests.swift`.
- Documentation: this report, `docs/HANDOFF_CURRENT.md`,
  `docs/ARCHITECTURE_BLUEPRINT.md`, the AX skill's `references/field-guide.md`,
  and the script-maintained cross-project Agent handoff.

No UI/Glass, persona/cognition, Trust/authentication, provider model/timeout/retry
policy, or new production store/background loop was introduced. No commit,
push, public release, or staging. Pre-close checkout: 91 tracked changed files,
27 untracked, zero staged and zero unmerged; this includes substantial prior
work and is not the campaign's changed-file count. The installed app honestly
reports dirty provenance, not an exact clean source revision.

## Time and evidence limits

The main investigation, implementation and installed journeys ran during
08:17–09:21 UTC. Observation, a directory no-change trace and handoff preparation
followed. The narrow CRLF correction ran around 10:25–10:29, followed by final
build observation and closeout. These are phases, not a stopwatch breakdown of
active typing, builds and provider wait. Elapsed campaign time is not a claimed
performance gain. The provider wall-timeout diagnosis remains limited by the
available transport evidence; arbitrary timeout/retry changes were not made.
No generic completion-rate, speedup percentage or zero-leak claim is supported.

## Final installed result — complete

Final PID 84756 remained running through the deadline and authenticated chat
readiness passed afterward. The selected main conversation remains
`644D65F1-0270-4B0B-8ED8-A3F31F2E795D`, model gpt-6-astra. The temporary
observer exited naturally at its deadline and session 71243 was reaped; no
campaign sampler/server or active campaign worker remains. Agent is left up.

The final process has 49 one-minute samples, 10:28:50–11:16:52 UTC. RSS ranged
1240.42–1249.58 MiB, ending 9.16 MiB above its first sample. The latest fifteen
samples ranged 1244.02–1249.58 MiB and 0–1.6% CPU. This is modest upward drift,
not a perfectly flat trace and not enough evidence to diagnose or exclude a
leak. The earlier PID 78568 has a separate 73-sample observation over about
72 minutes; its measurements are not combined into a final-build speed/memory
comparison. There was no unexplained process replacement in these samples.
Receipts: `/tmp/nativeagent-ax-20260915-observation-summary.json` and
`/tmp/nativeagent-ax-20260915-final-readiness.json`.

All selected changes and their focused checks are complete. No further fix
was selected from historical instrument leads or uncertain provider transport
timing. Future everyday evidence can establish frequency or magnitude; this
campaign creates no automatic follow-up. Existing dirty work remains intact,
with no commit or push.
