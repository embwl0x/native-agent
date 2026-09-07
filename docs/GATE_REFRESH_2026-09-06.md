# Gate reconciliation — 2026-09-06 task, final results 2026-09-07

## Final result — the complete gate is green

After the registry race fix (bot registry rows keyed by per-instance UUID, 91bb52c6),
`./script/test.sh --require-ios` exited 0 end to end on 2026-09-07 at 01:02 local:
29 shell suites, 224 + 59 node tests, 230 Core XCTest, 9,202 Core Swift Testing across
15 shards, 86 Shared, 23 + 3,098 root, 571 iOS. The sections below are the history of
how it got there and stay as the record.

## Earlier gate4 result — blocked by a production registry race (since fixed)

**The complete gate is not green.** The last `./script/test.sh --require-ios`
exited **1** after **911.41 seconds (15m 11.41s)**. Its only remaining failure
was the Telegram-containing Core shard: two routing assertions failed under
load, and the second test then trapped while indexing its empty result array.
Those tests and their assertions remain unchanged. Fixing their shared
production lifecycle defect is outside this task's test-seam/gate-speed exception.

Work stayed in `NativeAgent-wt-codex-gate4`, branch `codex/gate4`, based on
`497da6d9`. Four complete attempts ran, all exiting 1, totaling **3,854.06
seconds (64m 14.06s)**. Downstream commands blocked by the last attempt were
then run separately: Shared, root, and required iOS all passed in **296.88
seconds combined**. Those diagnostic receipts are not an end-to-end gate pass.

### Stage results

| Stage | Final evidence |
| --- | --- |
| Shell suites | All 29 passed: 27 `tests/scripts` suites and two `script/tests` suites. |
| Source/inventory/privacy | Passed, including Xcode project reproducibility, canonical wiring, architecture, timers, persona hygiene, and tracked privacy. |
| Node helpers / Chrome | 224 / 59 passed, zero failed. |
| Core XCTest | 230 passed, zero failed. |
| Core Swift Testing | Attempt 3 completed all 9,202 tests across 15 shards with no unexpected failures. On final attempt 4, 14 shards passed (8,741 tests); the 461-test Telegram-containing shard aborted after the two assertions below, so that attempt has no complete Core test count. One unchanged known issue. |
| Shared, downstream diagnostic | 86 Swift Testing tests passed; zero XCTest discovered. Exit 0, 3.41 seconds wall time. |
| Root, downstream diagnostic | 23 XCTest and 3,098 Swift Testing tests passed, zero failed. Exit 0, 244.85 seconds wall time. |
| Required iOS, downstream diagnostic | 571 passed: 558 XCTest and 13 Swift Testing, zero failed/skipped/expected failures. Exit 0, 48.62 seconds wall time. |
| Trailing guards, downstream diagnostic | Existing tracked/working-tree Python, generated-cache, and whitespace checks passed. |

The final serial Core shard counts/times were 2,413/79.806s, 847/96.411s,
and 181/44.306s. VisionPerception stayed in its existing `--no-parallel`
shard. The final MCP/Mac shard passed all 1,555 tests in 16.744 seconds.
The repaired Telegram retry test and its exact receipt sequence passed in
attempts 2 and 3; attempt 4's unrelated process crash interrupted that shard.

### Remaining production finding and load evidence

`SwiftNativeTelegramBot.deinit`, introduced by **`6bc33d24`**, schedules
asynchronous registry cleanup keyed only by `ObjectIdentifier(self)`.
The registry neither retains the bot nor distinguishes successive objects
allocated at the same address. A new bot can therefore see an old row, and
delayed cleanup can remove the new bot's registered dependencies. The source
owners are `TelegramBot+Client.swift` and `TelegramBot+Completeness.swift`.

Observed manifestations, all left unchanged:

| Test | Observed failure and isolation |
| --- | --- |
| `releasedBotRemovesItsDependenciesAndRegistryReturnsToBaseline` | Attempt 2: its new bot ID was already registered, and dependencies were non-nil before registration (two assertions). Passed alone in 0.005s. |
| `dispatchSwiftSlashCommand_provider_returns_current_model` | Attempt 4: a bot registered with routing returned nil instead of `anthropic`. Passed alone in 0.008s. |
| `spokenEffortAndFastReachTheSameConfigWriter` | Attempt 4: zero routing writes instead of two, then `Index out of range` from indexing the empty array. Passed alone in 0.010s. |

The two routing consumers use this same shared registry; their lost routing
is consistent with its delayed-removal race. The earlier lifecycle test
directly observed address reuse with a stale registry row. The failures are
load-sensitive, not new behavior to accept. No global reset, serial-shard
workaround, retry, or production repair was used to hide them. Their passing
attempt 3 does not erase the failures observed in attempts 2 and 4.

The pre-existing known issue remains
`SessionIdentityCheckTests.liveDataRootIsNonZero`: this checkout has no live
data root. This is an acknowledged absence, not live-data validation.

### Repairs and cause commits

| Commit | Repair and cause |
| --- | --- |
| `10802d98` | Five MCP catalog fixtures now bind injected pool specs to the registered stdio implementation, as required by `e8fd9ab8`. Fixtures select the exact server ID and exclude built-in native rows. All resource, cache, descriptor, warning, and coalescing assertions remain. |
| `09324936` | After `7e21f9ca`/`152de86d` made command execution independent of ingress, an immediate first reply could finish before `/retry`. The fixture now holds its terminal edit after the reply receipt, admits retry in the next poll, waits for queue admission, then releases the first turn. Exact visible messages and receipt sequence retained. |
| `cebb29dd` | The malformed-frame helper now waits for the test's `tools/list` trigger before emitting invalid JSON. `98f8a7ab` had allowed early death while still racing a PID assertion. Original test failed under load and passed alone in 0.338s; the repaired fixture passed in complete attempts 3 and 4. Checkout, PID, termination, and crash-accounting requirements remain. |
| `c358f6b1` | Reconcile the existing Shared stable-ID replay test with `eba19104`: equivalent JSON whitespace is accepted, while changed payload content and wrong direction are rejected. Rename the test to describe equivalent payloads. |

**Production changes in this pass: none.** No gate wiring or dependency pins
changed. No tests were added or deleted; one existing Shared test was renamed.
No assertion was weakened. The retry and document-scroll seams inherited from
earlier passes remain historical changes, documented below.

### Attempt ledger and artifacts

| Attempt | Exit / wall time | Result |
| --- | --- | --- |
| 1 | 1 / 1,046.55s | Exact reported baseline: seven MCP issues and one Telegram retry receipt issue. Later stages not reached. |
| 2 | 1 / 935.43s | Initial MCP repair incorrectly selected built-in registry rows; corrected afterward. Exposed the malformed-frame fixture race and the production registry lifecycle race. Telegram retry repair passed. |
| 3 | 1 / 960.67s | All Core shards passed. Shared exposed the stale byte-exact replay pin from before `eba19104`; corrected afterward. Root and iOS not reached. |
| 4 | 1 / 911.41s | MCP and all other Core shards passed; Telegram routing consumers failed under load and aborted their shard. Shared/root/iOS subsequently passed as separate diagnostics. |

Integrated app build passed initially in 76.87 seconds; final incremental
builds passed in 0.96 and 0.39 seconds before complete attempts 3 and 4.
All SwiftPM commands retained User's Git dependency redirects and
`--force-resolved-versions --skip-update`. No package update/resolve or GitHub
fetch was run.

Logs and exit files are under `.runtime/gate4/`: `full-gate-{1,2,3,4}.log`,
all four `pooled-*` directories, integrated build logs, the four isolated
failure diagnostics, and `shared-final.log`, `root-final.log`, `ios-final.log`,
and `trailing-guards-final.log`. Required iOS wrote
`.runtime/test-ios-results/run.vU3Toh/tests.xcresult`.

All five changed test files are committed locally in the four cause groups
above; this report is committed separately. Nothing was pushed, merged, or
installed. No tracked implementation work remains uncommitted. Logs remain
ignored. The brief's `codex/gate2` finish reference conflicts with its explicit
gate4 worktree boundary, so commits stayed on `codex/gate4`. No external Agent
handoff or user data, persona, prompts, or policy were modified; this report
carries the worktree-only handoff.

## Historical gate3 result — blocked by production findings

**The complete gate is not green.** The last `./script/test.sh --require-ios`
attempt exited **1** after **362.96 seconds (6m 02.96s)** at the unchanged
Xcode project reproducibility guard. Three complete attempts were run (exit 1
each: 330.73, 339.75, and 362.96 seconds). Subsequent unchanged downstream gate
commands were executed as diagnostics to expose and reconcile all later stages;
they are not an end-to-end success receipt.

Final downstream validation took **863.81 seconds (14m 23.81s)**, including
the integrated build, Node, all Core stages, Shared, root, and required iOS.
It exposed one remaining attention fixture omission, then the corrected full
Mac/MCP shard passed **1,555 tests** in **16.596 seconds** (39.67 seconds with
compilation). The finished tree retains only the failures listed below.

| Stage | Latest executed result |
| --- | --- |
| Shell suites | 28 suite receipts passed; the 29th, project inventory/reproducibility, fails. These include 27 `tests/scripts` suites and two `script/tests` suites. |
| Source/inventory/privacy | Architecture, timer, persona hygiene, canonical wiring, and tracked privacy passed; iOS inventory is wired but project regeneration differs. |
| Node helpers / Chrome | 224 / 59 passed, zero failed. |
| Core XCTest | 230 passed, zero failed. |
| Core Swift Testing | 9,202 tests across 15 shards; two unchanged Telegram tests fail with three assertions. One pre-existing known issue. All other tests passed, including the final corrected 1,555-test Mac/MCP shard. |
| Shared | 86 Swift Testing tests passed; zero XCTest discovered. |
| Root package | 23 XCTest and 3,098 Swift Testing tests passed, zero failed. |
| Required iOS | 571 passed: 558 XCTest and 13 Swift Testing; zero failed, skipped, or expected failures. |
| Trailing guards | Tracked/working-tree Python, generated caches, and whitespace passed. |

The solo Core shard counts/times were 2,413/82.220s, 847/97.843s, and
181/43.530s. VisionPerception remained in the second `--no-parallel` shard.
Final pooled counts were 307, 186, 103, 159, 1,555, 294, 871, 461, 625,
1,043, 131, and 26. Full per-shard logs are preserved in
`.runtime/gate3/diagnostic-pooled-3/`; the corrected Mac/MCP receipt is
`.runtime/gate3/mac-shard-final.log`. The other final receipts are
`downstream-final-3.log`, `trailing-guards-final.log`, and
`project-finding-final.log` under `.runtime/gate3/`.
iOS used R26-iPhone; its passing result bundle is
`.runtime/test-ios-results/run.tUlpnQ/tests.xcresult`.

### Remaining failures

1. **Xcode project reproducibility:** the canonical inventory suite exits 1
   because five moved production files have manually assigned IDs/order instead
   of XcodeGen's output. Exact cause commits and the prepared diff are below.
   The final existing inventory suite reproduced this failure. The guard was
   not weakened; generated-project repair remains unapplied because it exceeds
   the brief's production-change exceptions and no approval was received.
2. **Telegram terminal-card persistence:**
   `slashStopUsesTheSameConfirmedCancellationPathDuringWork` fails its wait for
   “Stopped.” and exact final-card assertion;
   `shutdownCancelsAndDrainsTheOwnedTurnWithoutAnOrphan` fails its exact final-card
   assertion. Both reproduce alone and in the final pooled run. The cancelled
   handler is drained, but `ccdacbfa`'s ledger cancellation checks reject the
   terminal write with `CancellationError()` and the card instead reports status
   persistence unavailable. Fixing this requires production lifecycle behavior
   changes, so both tests and all their assertions are unchanged.

The existing known issue is `SessionIdentityCheckTests.liveDataRootIsNonZero`:
the checkout has no live data root. It remains a known absence, not a claim of
live-data validation. No user data was supplied or changed to get a pass.

**Only production change:** a narrow injectable document-scroll restoration
seam, detailed below. No production default behavior, gate wiring, retries,
persona, prompt, or policy changed. No tests were added or deleted; one iOS
test was renamed to describe the new queue-preservation contract.

### Commits and handoff

All changes are committed locally on `codex/gate3`; nothing was pushed or
merged. The brief's `codex/gate2` finish reference conflicts with its explicit
gate3 worktree/branch boundary; work remained on gate3. No external handoff
file was changed because this task restricted writes to this worktree.

| Commit | Cause group |
| --- | --- |
| `d4ddf20e` | Captured export SHA fixtures |
| `d75cd31b` | Registered MCP consent identities and risk |
| `ada82e90` | Valid MCP helper notification handling |
| `7f313b00` | Native disk resource-cache fixture |
| `9545b2a5` | Live marked-action identity evidence |
| `1a69493c` | Document restoration test seam and fixture |
| `c706675b` | Exact redacted AX post-state |
| `7f1191cc` | Stream progress/idle lifetime fixtures |
| `061c7aa8` | Absent connector registry contract |
| `008f9044` | Moved/shared implementation source pins |
| `187713fd` | Returned safety-snapshot identities |
| `1de73533` | Persisted notification episode identity |
| `652989a1` | Telegram retry acknowledgement fixture |
| `3bb9a9a2` | Preservation of all admitted iOS turns |
| `3dc16e4b` | Surviving eval references and narrative |

This report is committed separately. Logs and the unapplied project diff
remain in ignored `.runtime/` paths. No tracked implementation work remains
uncommitted. Next work requires authorization for the project regeneration
and Telegram production lifecycle fixes described above.

## Reconciliation details — codex/gate3

Base: `62a89a3f`, worktree and branch `codex/gate3`. The historical green
gate2 receipt below is not a receipt for this tree.

Attempt 1: `./script/test.sh --require-ios`, exit **1**, **330.73 seconds**
wall time. Stopped at the public-export source inspection after the preceding
shell suites passed; Node, Core, Shared, root, and iOS were not reached.
Log: `.runtime/gate3/full-gate-1.log`.

Integrated app build passed in **82.32 seconds**. Attempt 2 exited **1** in
**339.75 seconds** at the next public-export fixture: its Git mock rejected
the publisher's startup source-SHA capture added by `e9ce31fa`. The mock now
accepts exactly that checkout's `rev-parse HEAD`; remote and purge assertions
remain intact. Log: `.runtime/gate3/full-gate-2.log`. Later stages not reached.

Reconciliations assembled for the next complete gate:

| Cause | Existing test/record repair |
| --- | --- |
| `e9ce31fa` | Public-export guard requires the captured commit assignment and archives that SHA, preserving tracked-resource and identity checks. |
| `da1ddc63` | MCPDispatcher, uniform-locking, app consent lifecycle, cold reload, and Hub fixtures register server identities before grants. The malformed-ledger grant check requires a ledger-specific malformed-response error. |
| `6bf1c514` | Hub status pins the granted external risk and its persisted server matches that risk. |
| `2ff0cb1a` | Delivery-envelope scan recognizes the moved ingest telemetry owner. |
| `a3c8957b` | Turn-identity scan reads TextCompatibilityEntry; cancellation/user-append ordering stays on TextCompatibility. |
| `7e5382e7` | Session watcher checks the live createChatSession writer after the uncalled lineage writer was removed. |
| `7234a16c` | Backup fixture selects provisional and final safety captures by their returned IDs, requiring both current-policy snapshots rather than relying on timestamp/UUID sorting. |
| `89a1cdcc`, `a9d7ee84` | iOS drain pins the absolute recovery-budget guard; push callback scan follows MobilePushNotifications while foreground checks stay on the app owner. |
| `fbb32474`, `61fc1358` | Eval references retain surviving TTS missing-key/positive-root coverage and point freshness at SnapshotFreshnessEvalTests. Existing override reference corrected in place; no replacement coverage row. |
| `cbbcb498` | Decoder eval narrative describes rejection of malformed tool batches before dispatch. |

Additional reconciliations after executing the previously blocked stages:

| Cause | Repair |
| --- | --- |
| `a11c1940` | Transcript-aging source check requires three calls to the shared preparation helper and one aging call inside it. |
| `e22b42d7` | Held error bodies now survive a progress check followed by an idle check. Anthropic/OpenRouter fixtures require at least four seconds and retain the former two-second scheduling allowance, plus all status/body/auth/cancellation assertions. |
| `2b12a28e` | Connector credential fixtures require the missing registry to remain absent. |
| `603e5997` | Idle-reaper helper ignores no-ID notifications instead of replying with an invalid object-valued response ID. Two pool failures passed alone; the deadline failure reproduced alone. The helper defect explains timing-dependent child termination; assertions remain unchanged. |
| `f30338d2` | Disk resource-cache fixture uses the retained native cache lane; generic HTTP now performs live discovery. |
| `eb55e5ef`, `e9454b68` | Marked-action fixtures supply matching live window, focus, stable handles, real labels/geometry, and unique-target lookup. |
| `66ecad9d` | Add the restoration seam described below; document-read fixtures capture and restore the actual synthetic viewport offset. |
| `a1c0e8c3` | Unmarked AX post-state pin requires the exact redacted value, digest, and count, while independently asserting the underlying action changed the value. |
| `111a40ce`, `7494c066`, `a204f41a`, `88fa05f8`, `0da22940` | Retention, Desk schema, attachment-cap, and iOS model-surface scans follow the shared/moved implementation owners. |
| `f9d0225f` | Notification dedup pins include the exact persisted episode UUID and stable reason digest. |
| `56a70cbc` | iOS queue test requires all 75 admitted turns to survive relaunch in order, replacing the deliberately removed eviction contract. No test was deleted. |
| `7ffc2bc8` queued-retry path | Telegram retry fixture supplies a valid message ID for its markup acknowledgement; exact receipt sequence retained. |
| Authorized eval reference corrections above | Refresh the two frozen input hashes; verified all 633 campaign members remain byte-equivalent as parsed values. No coverage row was replaced or added. |

Attempt 3 exited **1** after **362.96 seconds** at iOS project reproducibility.
All earlier release-script suites, including the repaired public-export suite,
passed. `.runtime/gate3/project-regeneration.diff` shows the exact discrepancy:
manual IDs/order for five production files added by `4c292906`, `a9d7ee84`,
`8e3b38c6`, `f416c34e`, and `587feb86` differ from canonical XcodeGen output.
No target membership or source body differs. This production-project change
is outside the brief's test-seam/gate-speed exception, so it remains unapplied.

The existing downstream commands were then executed separately as diagnostics,
without a canonical success receipt. `.runtime/gate3/downstream-guards-1.log`
passed all subsequent shell/source/privacy guards. The second Swift diagnostic
completed every Core shard, Shared, and root package in **747.29 seconds**;
its failures drove the table above. The first required-iOS diagnostic completed
558 XCTest and 13 Swift Testing tests, with three assertions in two stale tests,
exit **65**, **54.20 seconds**. The final passing iOS receipt supersedes it.

The unchanged Telegram stop/shutdown tests also failed alone:
`slashStopUsesTheSameConfirmedCancellationPathDuringWork` (two assertions) and
`shutdownCancelsAndDrainsTheOwnedTurnWithoutAnOrphan` (one assertion).
`ccdacbfa` added cancellation checks to the card ledger; the cancelled turn's
terminal persistence now throws `CancellationError()` despite writable fixture
storage. The card falls back to “Outcome unknown · status persistence
unavailable” rather than durably reporting “Stopped.” This is a production
finding, not an assertion to repin or an injected storage fault.

**Only production change:** `MacAccessibilityActuator.swift` adds internal
`MacDocumentScrollRestoring` and `MacDocumentScrollRestorationSource` protocols
and accepts a source-supplied restoration object. `SystemMacAXElementSource`
continues through the unchanged AX capture, restore, and readback implementation.
No production source implements the override; synthetic document fixtures do.
No gate wiring or retry logic changed. Integrated seam build passed in
**43.65 seconds**. No tests added or deleted.

Final validation and remaining findings are recorded above. All SwiftPM invocations retain
User's dependency redirect and `--force-resolved-versions --skip-update`.
No push, merge, installation, or user-data mutation. Worktree-only scope
excludes the external Agent handoff; this report carries the task handoff.

## Historical required-iOS gate — codex/gate2

**Passed end to end: `./script/test.sh --require-ios`, exit 0, 1,263.14
seconds wall time (21m 03.14s), completed 2026-09-06 at 18:19 CDT.**
This result supersedes the pending complete verification in the historical
report below. Work stayed in the `codex/gate2` worktree, based on `ac4a425b`.
The tested source change is committed as `a4998bbd`.

The exact Git dependency redirects supplied by User were exported before Swift
commands. SwiftPM used `--force-resolved-versions --skip-update`; no package
update/resolve or GitHub fetch was run. The integrated app build passed in
76.45 seconds wall time before the final gate.

### Final stage counts

| Stage | Final result |
| --- | --- |
| Shell suites | 29 passed: 27 under `tests/scripts`, plus the merge-candidate and iOS-release fixture suites under `script/tests` |
| Source/inventory/privacy guards | Passed, including blueprint, timer ownership, persona hygiene, canonical wiring, and tracked privacy |
| Node bridge helpers | 224 passed, 0 failed |
| Chrome extension | 59 passed, 0 failed |
| Core XCTest | 230 passed, 0 failed |
| Core Swift Testing | 9,204 tests across all 15 shards; 0 unexpected failures, 1 existing known issue described below |
| Shared | 86 Swift Testing tests passed; 0 XCTest tests discovered |
| Root package | 23 XCTest and 3,100 Swift Testing tests passed; 0 failures |
| Required iOS | 572 passed: 559 XCTest and 13 Swift Testing; 0 failed, 0 skipped, 0 expected failures |
| Trailing Python and whitespace guards | All passed; final `Swift-native checks passed` marker present |

iOS ran on the available `R26-iPhone` simulator (iPhone 17, iOS 26.5).
The fresh Xcode result bundle and its typed summary are retained at
`.runtime/test-ios-results/run.KuI9lf/`.

### Final Core shard receipts

Times below are each Swift Testing runner's reported elapsed time, not
additive wall time for the pooled stage.

| Shard targets | Tests | Seconds |
| --- | ---: | ---: |
| ActivityWatch, ApprovalInbox, BackgroundLoops, Browser, CapabilityFoundry, ChatOrchestration | 2,413 | 79.718 |
| PersonaEngine, ProviderRouting, Research, ScreenVision, VisionPerception | 847 | 80.573 |
| SelfImprovement | 181 | 43.196 |
| Connectors, Context | 307 | 51.393 |
| Dispatcher | 186 | 3.391 |
| DoctorChecks | 103 | 0.160 |
| DreamREMCycle | 159 | 0.205 |
| KnowledgeGraph, MCPDispatcher, MacAssistantStatus, MacControl, MemoryV2 | 1,555 | 16.457 |
| WorkshopExecution | 294 | 1.465 |
| MultimodalTTS, NativeAgentCore, NotificationInbox, PersistenceCore | 872 | 21.887 |
| Skills, SwarmRuns, SystemOps, TelegramBot | 462 | 15.377 |
| ToolExecution, ToolRegistry, TriggerScheduler, TrustCenter, WorkflowOrchestration | 625 | 5.882 |
| CognitiveSubstrate | 1,043 | 89.866 |
| GitHubConnector, SlackConnector | 131 | 0.236 |
| CommandPalette, Onboarding, MacIntegration, XConnector | 26 | 0.032 |

The first three shards remained solo and `--no-parallel`, including
VisionPerception. The remaining twelve retained the existing four-way pool.
The ChatOrchestration-containing shard also passed in 79.420 seconds on the
first attempt, versus the historical 1,298.542-second receipt below. Both new
receipts include the already-shipped retry sleeper seam.

### Failure reconciliation and remaining findings

The first complete attempt exited **1** after **1,039.16 seconds** (17m
19.16s). Every Core shard completed, but the pooled MacControl shard had one
unexpected issue, so Shared, root-package, and iOS were not reached.

`readoutsChanged_neverShipsAContextualSecret_beforeOrAfter`, introduced in
`e1e14b27`, searched the whole serialized payload for ASCII `123` and `456`.
Its generated frame UUID happened to contain `123`. Both actual CVV values
were correctly represented by `enclosing_cvv` redaction objects; the assertion
matched unrelated metadata. The unchanged test passed alone in 0.095 seconds.
This is a random fixture collision observed in the pooled run, not evidence
that load caused a production redaction failure.

`a4998bbd` repairs the fixture in
`Modules/NativeAgentCore/Tests/MacControlTests/MacActClosedLoopTests.swift`:

- Use non-ASCII three-digit values accepted by the same shipped `isNumber`
  CVV rule, so the fixture cannot collide with ASCII UUIDs or digests.
- Retain the whole-payload leak checks, scanning the JSON-escaped contents
  without enclosing quotes so embedded leaks still fail.
- Retain the before/after and harmless-total assertions, and additionally
  require the exact `enclosing_cvv` reason on both redaction objects.
- Update the shared dense-summary fixture and retain its harmless-caption
  control. Its payload check now also catches embedded fixture contents.

Both affected existing tests passed in the final pooled shard (0.775 and
0.783 seconds). No tests were added, removed, disabled, or retried by the gate.
No assertion was relaxed and no gate wiring changed.

**Remaining unexpected failures or production findings: none.**
The one existing known issue is
`SessionIdentityCheckTests.liveDataRootIsNonZero`: this checkout has no live
data root, so the test records its pre-existing `withKnownIssue` absence case.
That is not live-data validation and was not changed or supplied with user
data to obtain a pass.

**Production changes in this pass: none.** The inherited retry seam and
compiler-cache changes remain documented in the historical report below.
No user data, persona, prompts, or policy were changed. No app installation,
push, or merge occurred. The external Agent handoff was not modified because
User restricted this task to this worktree; this report carries the closeout.

Logs are retained under `.runtime/gate2/`: `full-gate-1.log` and its exit-code
file, `cvv-original-alone.log`, `integrated-build.log`, `full-gate-2.log` and its
exit-code file, and the complete `pooled-1/` and `pooled-2/` shard logs. These
ignored artifacts are not committed.

## Historical gate-refresh pass

The following records the earlier pass and its then-pending stages; its
approval and continuation statements are superseded by the final result above.

Scope: `codex/gate-refresh`, based on `b7b8ede7`. Production behavior remains
authoritative. The eight commits from `ship2/chat-b` and `ship2/chat-a` were
cherry-picked in order; nothing was pushed or merged into another branch.

## Validation

- Integrated app build: passed, 93.27 seconds initially; final factory-seam
  rebuild passed in 31.76 seconds. Both used offline pinned dependencies.
- Prior ChatOrchestration receipt: 1,805 tests, 130 suites, 43 issues,
  1,298.542 seconds (21m 38.542s). This is a shard baseline, not a complete
  release-gate timing.
- Focused reconciliation: 307 tests in 29 suites passed in 162.948 seconds
  (330.05 seconds including the first Core test build). The remaining default
  factory fixture spent 155.771 seconds on real retry waits; it now explicitly
  receives the same sleeper seam.
- First full-gate attempt: stopped with failure after 843.78 seconds
  (14m 3.78s). All 29 shell suites, source/privacy guards, 224 Node helper
  tests, 59 Chrome tests, and 230 Core XCTest tests passed. The first Core
  Swift Testing shard reported four assertions in three sandboxed builder
  tests, caused by the gate's inherited worktree compiler-cache path. The
  shard was stopped after collecting that failure and identifying three
  remaining real-backoff fixtures. No successful full-gate receipt exists.
- After fixing the cache path and remaining slow fixtures: 29 focused tests
  passed in 5.589 seconds (27.50 seconds including build), including all
  three builder failures, all three error-surfacing tests, and the default
  factory test. Canonical wiring and development dependency-pin guards passed.
- The other Core shards, Shared, root-package tests, and iOS have not run in
  this attempt. Another complete gate run awaits User's approval under the
  supplied working agreement against repeated broad runs without approval.
- No new tests, evals, guards, or gate exclusions. Existing gate pooling and
  the serial shard containing VisionPerceptionTests are unchanged.

## Production changes

Only a retry-sleeper seam, following the ladders introduced by `b593d8f2`
and `4af32f79`:

| File under `Modules/NativeAgentCore/Sources/ChatOrchestration` | Change |
| --- | --- |
| `ChatOrchestration+TurnEngine.swift` | Inject `providerRecoverySleep`. The default remains the identical throwing `Task.sleep` conversion from seconds to nanoseconds. |
| `ChatOrchestration+ToolLoop.swift` | Both structured retry waits call that sleeper. Retry classification, counts, Retry-After, budgets, notices, and cancellation checks remain intact. |
| `ChatOrchestrationClient+TextCompatibility.swift` | The compatibility retry wait shares its engine's sleeper and retains its existing `try?` semantics. |
| `ChatOrchestrationClient+Factories.swift` | The tools-injecting factory forwards an optional sleeper to its engine; nil retains the engine's production default. |

Tests explicitly inject a cancellation-checking immediate wait. No process-wide
test detection or environment switch changes production timing. Nine ordinary
backoffs total 150 seconds per exhausted provider call; tests still execute
every attempt.

`script/timer_inventory.tsv` moves the existing sleep counts to TurnEngine
(two: attention deadline and the shared provider wait). The two old call-site
entries are removed because inventory rows require positive counts. The
inventory's existing unclassified-timer check still rejects an unlisted sleep.

`script/test.sh` now places both inherited module-cache paths under its existing
temporary test root. The original worktree paths (`4cccd008`) were outside
sandboxed fixture write roots, causing `SwiftShims` manifest compilation to
fail with `Operation not permitted`. The production sandbox already permits
the system temporary directory. No sandbox rule or test assertion changed;
the same caches are shared for the lifetime of the gate and removed by its
existing cleanup.

## Test changes by file

All files below are under `Modules/NativeAgentCore/Tests/ChatOrchestrationTests`.
Imported commit messages retain the detailed rationale; the table identifies
the shipped behavior or fixture premise behind each reconciliation.

| File | Cause and reconciliation |
| --- | --- |
| `AttentionSignalsTurnEngineTests.swift` | Packet preparation now carries the renderer's stable-persona, 400-character expansion, and five-row memory settings (`785d7c42`); include them in the baseline. |
| `AutonomyGuardCharacterizationTests.swift` | Replay exemptions require canonical approval verification (`2cb58a71`); supply a verifier for the approved replay fixture. Denial cases retain missing verification. |
| `ChatOrchestrationClientTests.swift` | Hot floor includes `inner_state` (`259a331a`); session text no longer supplies Telegram identity (`7df7a4cd`); history moved into message content (`785d7c42`); explicitly select the helper spawn fixture (`a8d506f7`). Enable graph consent before testing corrupt SQLite (`130f1553`). Inject the retry sleeper. |
| `ChatErrorSurfacingTests.swift` | The three compatibility-error fixtures exhaust the `4af32f79` ladder; inject the sleeper without changing partial-text, terminal-error, or no-final assertions. |
| `ChatOrchestrationTurnEngineTests.swift` | Canonical `context_expand` belongs in the schema seed; update exact schema expectations. |
| `ChatPersistenceLifecycleRegressionTests.swift` | Retention excludes newly written or unsynced transcripts (`24b6fed3`, `91618a10`); stamp cap-victim fixtures quiet relative to their injected clock. |
| `ChatSessionAgingConsolidationTests.swift` | Model-capped backstop and aging threshold, bounded watchdog, and rendered row caps supersede older fixtures; use a reached threshold and sufficient text to exercise the cap. |
| `CognitiveProjectionCommitTimingTests.swift` | Compatibility replay follows two empty-reply nudges (`4af32f79`). Pin successful recovery and retain the existing post-tool terminal marker test by exhausting all ten attempts through the sleeper seam. Failed-provider projection coverage now requires the exact attempt count. |
| `ConversationPrefixV2ProjectionTests.swift` | Boundary replaces pinned anchors (`cb1cb132`); use current-user index and lane-owned capsule carrier (`785d7c42`); delivery is always stamped (`a08a8814`). Repair wire-marker/current-question fixtures, grow history by complete turns, measure the stable head, exceed the slide threshold, and append unique row IDs. |
| `DelegationStatusToolTests.swift` | Delivery has its own stall clock (`aaafb9c2`); an expired run deadline alone does not make a fresh delivery stalled. |
| `InnerStateToolTests.swift` | Shared redaction rule precedence (`09d7ccfd`) labels the synthetic key as an OpenAI-key match; retain the no-secret assertion. |
| `KimiNativeToolLoopTests.swift` | Wire tool names use `mac_notify`, not the TrustCenter registry ID; preserve charset and no-dot assertions. Inject the retry sleeper. |
| `LazyToolFilterTwinEvalTests.swift` | Snapshot generation and advertised contract membership govern schemas (`90cad6b2`, `49131442`); give both twins the same pinned contract. |
| `MemoryPromotionContextStageTelemetryEvalTests.swift` | Promotion events include moment outcome (`e2ddc19a`); pin the stub's `unreported` value. |
| `MidConversationToolChangePlanTests.swift` | New declarations append to the existing order (`2477b8be`); expect the new name at the tail. |
| `ParallelToolDispatchTests.swift` | Stop after the last dispatch batch throws cancellation (`bb110ae5`); assert the throw and both children’s teardown receipts. |
| `ProviderTransplantContractBaselineTests.swift` | Fatigue uses the shipped felt register (`259a331a`, `92023f8c`); update wording while preserving gates, decay, and ordering. |
| `RecallCanonicalFallbackTests.swift` | Graph consent gates explicit search and fallback (`130f1553`, `acbd2df8`); enable consent so canonical eligibility assertions reach their intended reader. |
| `SessionHistoryTests.swift` | Tail cap increased to 2 MiB (`4f6a63f5`); seed beyond that cap and assert the bounded read. |
| `StreamPartialCarryEvalTests.swift` | Inject immediate retry waits; existing partial-result and error assertions remain. |
| `StudioChatToolDispatchTests.swift` | Studio canon tools joined the catalog (`7df7a4cd`); update the exact set and retain append-only journal checks. |
| `StudioJournalWiringTests.swift` | Dispatcher construction now creates exact-root memory storage; arrange the absent-store fixture after constructing the dispatcher. |
| `TextCompatTurnFailedTraceEvalTests.swift` | Inject immediate retry waits; existing terminal trace assertions remain. |
| `ToolContractStabilityTests.swift` | Only a snapshotted declaration authorizes advertisement (`90cad6b2`, `49131442`); activate generation one and keep merely active tools dispatch-only. |
| `ToolLoopWallClockBudgetTests.swift` | Productive turns may extend to the six-hour ceiling (`7f7ed8e6`); update that ceiling and keep the idle-turn expiry assertion. |

## Measured retry-fixture speed

Times are seconds from the prior Chat receipt versus the focused passing
receipts in this worktree. These are individual-test comparisons, not a claim
about a completed whole-gate run.

| Existing test | Before | After |
| --- | ---: | ---: |
| `compatPath_midStreamFailure_surfacesNonEmptyErrorEvent` | 158.442 | 0.052 |
| `compatPath_immediateFailure_surfacesNonEmptyErrorEvent` | 156.616 | 0.039 |
| `compatPath_valueErrorAfterToolMarker_doesNotDispatchToolAndSurfacesError` | 157.376 | 0.042 |
| `alternateRootDefaultChatFactoryFailsClosedBeforeProviderCredentials` | 157.598 | 0.129 |
| `projectionCommit_providerFailure_doesNotConsumeTheWindow` | 154.710 | 0.050 |
| `projectionCommit_retryAfterFailure_deliversAndCommitsTheFeltLine` | 155.839 | 0.073 |
| `projectionCommit_streamingFailure_doesNotCommit` | 156.095 | 0.060 |

## Closeout and continuation

Commits, in order:

- `db3b471e`, `24db2b4a`, `0b0caabc`, `b537b934`, `c8749290`: imported chat-b.
- `68e5668d`, `0c475520`, `681fce20`: imported chat-a.
- `aeaedaa8`: graph corruption fixture consent.
- `23750aea`: unique appended prefix-window fixture identities.
- `5f18be1f`: retry sleeper, factory forwarding, terminal proof, timer inventory.
- `6fd34c1e`: remaining error-surfacing fixture waits.
- `480be5d0`: sandbox-writable gate compiler caches.

Logs are retained under `.runtime/gate-refresh/`: `build.log`,
`build-final.log`, `chat-reconciliation.log`, `full-gate.log`,
`cache-and-sleeper-check.log`, and `wiring-check.log`.

Next action after approval: export the five exact Git environment settings
from User's task and rerun `./script/test.sh --require-ios`, logging to a new
file. Do not overwrite the failed receipt or reuse its result as full proof.
No push, main merge, app installation, or live-data mutation occurred.
Worktree-only scope means the cross-project handoff outside this checkout
is not modified; this document carries the continuation instead.
