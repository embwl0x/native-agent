# Three-hour AX campaign — 2026-09-14

User authorized three hours of the dedicated Agent Experience loop. Start:
2026-09-14 23:40 UTC (18:40 Chicago); finished: 2026-09-15 02:40 UTC
(21:40 Chicago). The full three-hour campaign is complete; completion was
confirmed at 02:40:18 UTC. Selected changes are installed and Agent-verified:
scoped discovery, bounded file/directory continuation, truthful source and
delegate outcomes, and cross-turn recovery of retained evidence. The AX toolkit
field guide incorporates the lessons. No selected implementation remains open.

Baseline: branch review-0414f at cc124d471 with extensive earlier dirty UI and
capability work preserved; baseline tracked patch saved privately at
`/tmp/nativeagent-ax-3h-baseline.patch`. No commit/push/release authorized.
Read-only instrument: `/tmp/nativeagent-ax-3h-instrument.md`, generated 23:40:47Z.
Its historical leads are not automatically current defects or new work.

## Batch 1 — discovering and reaching evidence

Agent input run `656CF54C-A673-4740-B9AF-C26B73CE0951` identified unrelated
capability matches, missing bounded directory navigation, and historical missing
delegate errors. Direct baseline fixture with 421 files returned a bare array
of 200 names, omitted the target, and reported no incomplete coverage.

Assembled changes:
- Shared catalog scoring filters grammatical/repeated terms and distinguishes
  requested subjects/actions from incidental description text. Acceptance pending
  further relevance refinement.
- Existing list_dir supports literal filename filtering, explicit case behavior,
  deterministic pages, counts, coverage and stateless continuation snapshots.
  Both wrappers preserve metadata; ordinary path spelling survives continuation.
- Existing delegation status exposes a bounded redacted terminal execution error
  from Codex receipts independently of reply delivery. No historical job replay.

Initial installed run `44554688-AD8D-4534-8614-D9203AD541A5` verified 5/421 entries,
one continuation, filtered target and exact excerpt marker; execution error became
visible and was correctly identified as historical. Discovery partially improved:
Spotlight moved from fourth to first, but list_dir was absent and weak loading
suggestions remained. Those are being corrected before batch acceptance.

Initial final tests identified a relative-path continuation defect (corrected)
and three pre-existing system-gate expectations in ToolCatalogGateEvalTests: tests
expect throws while current system_info returns a permission-need envelope.
The latter is outside the selected boundary; no permission behavior changed.

## File-window continuation and finished evidence checks

Installed PID 27424 passed signature/authenticated bridge/chat/source identity.
Finished focused tests: 82 core tests and 2 app tests (including eight malformed/
ordinary catalog limit cases) passed. Logs:
`/tmp/nativeagent-ax-3h-evidence-{core,app}-tests.log`.

Resident run `654AA28D-558A-4C5D-9035-14224A67A9E1` reconstructed all 77 bytes of
the Unicode fixture in windows at offsets 0/28/59 (28/31/18 bytes), with eight
intact emoji and the exact continuation proof marker. Both file routes preserve
their byte ceilings, return explicit next arguments on partial reads, reject
changed versions and invalid UTF-8 offsets, and preserve the original authorized
path spelling. Nonregular inputs are refused without blocking open/readToEnd;
hermetic FIFO checks cover that safety boundary.

The same resident run verified matching-path filtering and distinct historical
delegate record kinds. Slack discovery returned only the already-loaded Slack
tool with no load suggestion. Filename discovery still included image generation
and preferred Spotlight over the directory filter; name/opening-purpose subject
evidence is being refined before that finding is accepted.

Current self-page timings (single read each): Providers 484 ms, Bots 379 ms.
Older multi-second timings were not reproduced; no speculative self-page/UI edit.
Read-only process samples began at 23:52Z and continue to the requested deadline
in `/tmp/nativeagent-ax-3h-resident-samples.jsonl`. Separate PIDs across installs;
do not treat cold/warm RSS changes as a leak or optimization benchmark.

## Public source reading and discovery refinement

The installed baseline silently kept only the first 40,000 extracted characters,
discarded redirect provenance, and could turn binary content into apparent text.
A private loopback fixture placed evidence beyond that old cutoff. The source
reader now keeps up to its existing one-million-byte download boundary through
the ordinary retained-result pager, reports transport and extraction coverage
separately, and preserves requested/final URLs. Its production downloader stops
on overflow and cancellation; unsupported media is an explicit failed extraction.

Final optimized install PID 29880 passed signature, authenticated bridge, chat
and dirty-source verification. The finished focused research/catalog checks passed
25 tests in four suites (`/tmp/nativeagent-ax-3h-web-final-tests.log`). Counts
overlap earlier batches and are not a full-suite claim.

Resident run `99924F9A-34CF-4F2C-9C5F-42570CA8391F` confirmed a successful,
complete 62,041-character extraction through a redirect. The preceding resident
run `CD1CCF82-AEFF-45AE-8683-7DB38175ABF7` recovered the beyond-cutoff marker
from retained page five without another fetch, and distinguished HTTP 200 from
unsupported PDF extraction. A separate two-million-byte synthetic response was
stopped with 1,000,000 bytes retained and 1,032,192 bytes observed (one overflow
chunk), correctly reported as partial; this is not a claim of an exact wire cap.

Filename-only discovery now puts list_dir first, and Slack discovery returns
the already-loaded Slack search tool without unnecessary loading. An ambiguous
combined filename/section query still includes a GitHub match below the two
local file tools. An explicit existing-category constraint is being assembled
to let Agent state known scope without endless phrase-specific score tuning.

Category scope subsequently passed: installed PID 31435; nine core tests in
two suites and three app tests (including parameterized cases) passed. A missing
test import was corrected before the core run. Resident run
`EC2EB166-1031-4E83-968C-2C1F41811148` made exactly four catalog calls: files
scope selected file_excerpt/list_dir only; notifications browse stayed scoped;
blank category preserved ordinary Slack search; unknown category failed clearly.
Canonical dispatch trace confirms three successes and the intentional refusal,
with no loading or action. Null handling is covered by focused core tests; the
resident used the schema-compatible blank equivalent.

## Cross-turn receipt continuity

Agent's second consultation (`F6FF92CA-A72B-43F3-8A30-9CA9E2F5E9B9`)
identified reliance on them own prior prose after raw tool results were elided.
Source tracing confirmed that current tool rows have empty content and retain
their receipt in metadata; both explicit history tools overlooked that text.
Research source files have limited retention, so no permanent raw-artifact
promise or new store was introduced.

Large read_page/read_file/list_dir results now retain a bounded structured
receipt within the existing 8,000-character result limit: factual source/window
fields and outcome before an incomplete preview. Secret redaction remains;
oversized evidence fields are explicitly omitted instead of clipped into false
locators. Other tool receipts and short reads keep their existing contracts.
Explicit role:tool history searches and exact message reads expose persisted
tool receipts; default human-history search and global prompt assembly stay
unchanged. Legacy clipped receipts remain incomplete historical evidence.

Optimized install PID 32991 passed authenticated bridge/chat/source verification.
Twenty-nine focused continuity tests in two suites passed, including existing
receipt redaction/row behavior and the assembled persistence-to-history fixture.
Log: `/tmp/nativeagent-ax-3h-continuity-core-tests.log`.

Live source turn `F25660EE-68CB-4AA3-9C09-EF47F02AD2D0` created a 5,268-character
structured receipt. Separate history turn
`895601AA-C875-4044-9739-5034AF7CCBA7` found exactly one tool receipt and read all
5,860 characters of its history projection, recovering URL, completed/succeeded
outcome and 62,041-character complete extraction directly from that record.
Exact locator: session `644D65F1-0270-4B0B-8ED8-A3F31F2E795D`, message
`C3E9AAE5-18C9-4923-90DB-12690AF67539`. No source refetch, output-handle reuse
or action replay. The receipt correctly says full source content is not in the
transcript and does not establish current source state.

## Additional source-encoding finding — accepted

A 71-byte loopback HTML fixture declaring quoted, mixed-case Windows-1252
returned unsupported_text_encoding despite a complete HTTP response. The bounded
extension supports explicit UTF-8, ASCII, ISO-8859-1 and
Windows-1252, with encoding provenance in coverage. No browser sniffing, XML
prolog interpretation or broad converter fallback is being introduced.

Primary design references: [HTTP media types/charset, RFC 9110 §8.3](https://www.rfc-editor.org/rfc/rfc9110.html#section-8.3)
defines case-insensitive charset names and quoted parameter examples;
[JSON character encoding, RFC 8259 §8.1](https://www.rfc-editor.org/rfc/rfc8259.html#section-8.1)
requires UTF-8 for interoperable network JSON. These support the explicit decoding
contract, not a claim that read_page implements a complete browser parser.

Optimized installed PID 34815 passed authenticated readiness and dirty-source
verification. Twenty-two focused tests in four suites passed, including encoding
conflicts, JSON's UTF-8 rule, invalid trailing bytes versus an incomplete scalar,
source coverage and retained receipt fields. Resident run
`209D4EB9-8131-477E-85C1-553650298C14` made exactly two reads and recovered
both synthetic proof strings with accents and punctuation intact. Root checked
the actual persisted tool outputs; both report completed and complete with the
declared encoding used and zero discarded terminal bytes. Log:
`/tmp/nativeagent-ax-3h-charset-tests.log`.

Both loopback HTTP fixture processes were stopped after acceptance, around
00:37 UTC. Later continuity checks must read the historical receipt, never
mistake those now-offline fixture URLs for current sources. Only the read-only
process observer remains active through the requested campaign deadline.

## Existing-source locator and offline substance recovery

Follow-up consultation `676752AF-F4AF-4BF8-9EBA-5B8E96051302` distinguished
proof of an earlier read from recovery of an omitted passage. The existing
Research owner already saved that content but returned no exact file locator.
Current fetch results now expose source_receipt with the actual saved path,
source ID, bounded contents, limited retention and normal-access requirements.
No new storage, tool, permission route, fixed expiry or availability guarantee.
The compact historical receipt preserves this pointer; missing files never
become empty-source findings or automatic refetch instructions.

Optimized install PID 36659 passed authenticated readiness/source verification.
Seventeen focused tests in three suites passed after correcting a missing test
import, including saved-tail recovery without a second HTTP call and persistence
failure refusing to return a locator. Log:
`/tmp/nativeagent-ax-3h-source-locator-tests.log`.

Capture turn `D9246AC4-09C3-4F77-A8A8-4042C1C62878` fetched once. Root then
stopped the temporary server and verified connection refusal on its port 50780.
Separate recovery turn `715378E2-5E92-42ED-81E2-8BFE60183D36` recovered the exact
beyond-cutoff marker from saved source `29af1308-dbfe-4535-a26a-9b3e55731955`.
Canonical dispatch trace: tool_load, read_file, tool_result_page only, all ok;
one file read and zero-based page five, with no source refetch. The retained
local-read result was 63,638 bytes. Original source coverage remained explicit
and was not confused with the later file read or current source availability.

All HTTP fixture processes are stopped again. The final installed process and
read-only observation continue toward the original three-hour deadline.

## Timed installed observation — complete

At 01:20:07 UTC, after more than 30 minutes on installed PID 36659 and two
subsequent installs since the original 00:24 source receipt, a direct normal
tool load/exact history read recovered all 5,860 retained characters from
message `C3E9AAE5-18C9-4923-90DB-12690AF67539`. Original succeeded outcome,
complete extraction of 62,041 characters and full_result_in_transcript:false
matched the earlier evidence. No source fetch or temporary handle was used.
Receipt: `/tmp/nativeagent-ax-3h-delayed-history-1.json`.

The temporary provider-result directory contained zero files/bytes at this
check. Main-process RSS settled after the recovery turns; the ongoing sampled
series is not a heap-leak proof or an all-process/UI benchmark. The same final
PID continues running without a restart to improve the observation.

Agent's evidence-based assessment (`3784A621-26DA-4410-95FE-40DF693A4F11`)
ranked offline content recovery as the most useful change, followed by precise
directory/discovery scope and explicit source/execution outcomes. They established
no new regression in the exercised paths. The ambiguous unscoped combined file
query remains a limited case, not a claim of perfect semantic search; explicit
files scope resolves the tested task. No new cancellation or schema-freshness
failure was supplied, so those were not expanded into speculative work.

Final delayed resident run `B7AA74EB-3D24-4A30-B810-7BBEEAA0D014`, started
02:20:14 UTC after about 90 minutes on the final process, passed both checks.
The old web receipt remained readable. A literal, tool-only chronological search
found three earlier byte-fixture receipts; Agent read only the earliest
(`721B74C1-8980-45F9-9F63-A757362494B3`) and used its original saved version
and next arguments. One file continuation returned the same version, 31 bytes
at offset 28 of the 77-byte source, with next offset 59. Root compared those
returned bytes directly with the unchanged synthetic fixture and verified an
exact match. Canonical trace: two exact message reads, one history search and
one file continuation; all ok, no load, fresh initial read or source fetch.

The final context check remained healthy: generation parity 3720, 21 sources,
zero degraded sources/active leases, normal pressure, no last error. Temporary
provider results were again zero files/bytes.

The observer ended naturally at the original 02:40 UTC deadline and was reaped.
It recorded 335 samples from 23:52:30 through 02:39:45 UTC; 220 cover final PID
36659 from 00:50:05 onward. That process remained running for approximately
110 minutes. Its sampled main-process RSS ranged from 1,292.14 to 1,365.64 MiB,
with activity-related steps between stable periods. The last 15 minutes ranged
from 1,365.48 to 1,365.64 MiB; the final sample reported 0.0% CPU. No sustained
idle climb was observed. This is not a zero-leak proof or an all-process/UI
benchmark, and no comparison across installed PIDs is claimed. Summary:
`/tmp/nativeagent-ax-3h-observation-summary.json`. All campaign HTTP fixtures and
the observer are stopped; Agent remains on the final installed build.

## Additional no-change findings

Resident skills run `FEEC63AD-6D6A-4FCB-B7FE-2756B0CBA706` selected one relevant
manifest entry, nativeagent-capability-briefing, and loaded it by the exact same
name. No contradictory instruction was found; missing procedural examples were
not treated as a defect requiring another skill. The manifest contains 18
compact entries, without eagerly loading their bodies.

Current context check: chat ready; 21 registered sources, zero degraded sources,
store/arena generation 3720 parity, zero active leases, normal pressure and no
last error. This does not justify reopening historical missing-context leads.

## Preservation

Persona, cognition, Trust, authentication and shared Liquid Glass are unchanged.
Fixtures remain under /tmp; no private state is staged or repaired speculatively.

## Changed owners in this campaign

- Capability selection: `SwiftToolDispatcher+ToolLoading.swift`,
  `AppChatToolDispatcher.swift`, relevant core/Mac schema descriptions and focused
  catalog tests. No global router or eager-loading policy was introduced.
- File evidence: `FileSystemActions.swift`, ordinary/Full Mac wrappers in
  `SwiftToolDispatcher+ToolImpls.swift` and `SwiftToolDispatcher+Sandbox.swift`,
  corresponding schemas and directory/read-window tests.
- Delegate evidence: `DelegationStatusProjection.swift`,
  `SwiftToolDispatcher+DelegationTools.swift` and focused projection tests.
- Source reading: Research model/search-fetch/transports, new
  `BoundedResearchDownload.swift` and `ResearchTextDecoding.swift`, and focused
  transport/coverage/encoding/reader tests.
- Historical evidence: `ChatOrchestrationClient+MessagePersistence.swift`, new
  `PersistedReadToolReceipt.swift`, explicit `SwiftToolDispatcher+ChatHistoryTools.swift`
  projections and focused persistence/history tests.
- Maintained documentation: this campaign record, current handoff, architecture
  contract notes, the AX loop field guide and the cross-project Agent handoff.

The checkout also contains extensive earlier dirty/untracked work. This owner
list identifies this campaign's boundaries; it does not claim ownership of every
change currently shown by git. No commit, push, publication or clean-build claim.
