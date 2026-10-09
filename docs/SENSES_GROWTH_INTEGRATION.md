# P6 Growth lane integration

`BackgroundGrowthLane(dataRoot:)` lives in the app, beside provider plumbing.
Its `loopRunner` is an `EventDeadlineLoopRunner`. No tests, install, app launch,
bridge call, live data or persona edits were used to build this package.

## Package seams

- **P2:** install the lane through `SensesHub.shared.install(...)`, then register
  `lane.loopRunner` with BackgroundLoops. Forward a canonical turn-end/quiet
  event to `lane.quietOpportunity()` so ahead work held during a turn resumes.
  A wake cannot manufacture needs. The runner must execute a supplied draft
  record from `<dataRoot>/senses/<id>/v<N>/sense.js` without requiring registry
  publication first. Candidate source calls use the supplied frozen provider.
- **P8:** make `ExistingCornersSourceProvider` also conform to the additive
  `SenseGrowthSourceProvider` protocol. `growthSample(for:address:)` returns
  a `SenseGrowthSample`: immutable real material, its source address and text
  independently extracted from the same input by the raw/Quick Look/AX route.
  For files, retain a stable private snapshot path during the call/rounds;
  never point at changing file bytes paired with an older extract. The source
  must not launch an app, open a window, change focus or make sound. Bundle
  metadata alone cannot certify a document or an unseen app view; throw
  `SenseFailure(code: "source_unavailable", message: ...)` and wait when no
  safe independent text exists. Do not silently call a foreground reader.
  `recentGrowthNeeds()` returns ahead needs from actual recent app/file/site
  use, with source references and stable last-use/count revisions. On newly
  observed use, enqueue that need through `SensesHub.shared.lane` to signal
  growth. Repeated identical use revisions are deduplicated.
- **P5:** enqueue stuck/repair/upgrade needs normally; `enqueue` wakes the loop
  and cancels lower-priority in-flight work when stuck arrives. Repair obtains
  the previous sense's real runner failure and input excerpt itself.
- **P7:** ship the complete starter, SDK/builders and worked examples under
  `Contents/Resources/Senses/`. The kit reader accepts `.js`/`.md` regular files
  in that directory or its subdirectories, requires a filename containing `starter` or `frame`, and
  bounds the complete bundled kit to 180000 bytes. No generated substitute is
  provided when it is missing.
- **P10:** `NativeAgent.senses.growthBudgetPerDay` is a nonnegative integer of
  model calls per UTC day; zero/absent means unlimited. Each call, including a
  failed call, is reserved on disk before dispatch. Stuck bypasses the budget.
  The unit was unspecified in the assignment and is an explicit integration
  assumption. Growth status/failures are the BackgroundLoops receipt; accepted
  growth posts one ready news line and one idempotent inbox note per sense id.

## Behavior and bounds

Priority is stuck, repair, upgrade, ahead; use count and recency order equal
priority. Only ahead work waits for sixty seconds without input and no active
chat turn. One sense receives at most three model rounds in five minutes;
each provider call is bounded to ninety seconds and each runner read to thirty.
No provider call starts outside the registered loop. Cancellation is checked
before writing or registering. Failed versions are removed without replacing
the registered sense. A new wall revision can retry a bounded failed episode.

Candidate reads use only the frozen sample, never a foreground reader. The
independent check requires at least 85% distinct-word coverage, all observed
numbers in the checked window, no unsupported words/numbers (apart from a
small structural-word vocabulary), bounded text and unique thing addresses.
Long inputs require folding and a more address; the first 24000 characters
are the coverage window. This conservative lexical check cannot establish
semantic correctness. One more route, when supplied, must run on the same
material, publish a distinct page at that address and pass lexical grounding. Grown
senses default to on-call and retain an existing sense's mode on repair;
offered verbs are recorded for discovery and only the
in-turn runner may dispatch an act request under Trust. This lane never runs
an act request or watch request during growth. Live supervision is P2's owner.
Success code is kept as local examples. Registry
truth replays example/inbox delivery after a crash or failed delivery.

The background model uses the same `SwiftNativeLLMClient` and checked Memory
and mind reflection route as existing background work, with no model override
or extra tool schemas. Source text and samples are untrusted prompt data.

## Bounded installed check (integrator performs after install)

1. Install the merged build with P1/P2/P3/P5/P7/P8/P10 wired. Use one real file
   whose existing view hit a wall. Read it through the existing app door once.
2. Confirm `senses_growth` wakes, the queue prioritizes that need, and a draft
   JS version is run on the captured material. Inspect its loop receipt and
   the registry's accepted version, then read the same file through the door.
   Compare the actual words and numbers to the raw read, including provenance.
3. Confirm exactly one new-sense inbox note and an additional local example.
   Mark that actual sense-served view wrong once; check one bounded repair
   episode and a new accepted version or an honest failure receipt. The old
   registered version survives a failed repair.
4. For ahead growth, use an app/file/site normally, let the computer become
   quiet, and check one episode. Keep a closed app closed: no launched app,
   changed focus/window or sound. An unavailable independent view must defer.
5. Set the optional budget to one, consume one ordinary model call, and confirm
   another non-stuck call waits until the next UTC day. A stuck need can still
   proceed. Return the setting to zero if unlimited growth is desired.

No separate tests or harnesses are needed for these installed checks.

## P6 validation receipt — 2026-10-05

- `xcodegen --spec project.yml`: passed; no tracked generated-project changes.
- Architecture blueprint: passed, 20 families / 968 Swift table rows.
- Timer inventory: passed, 256 sites / 170 ownership rules; no added primitive.
- `git diff --check`: passed.
- Required `swift build --disable-keychain -j 6`: this restricted worker cannot
  write the default module cache or apply SwiftPM's nested sandbox. Moving the
  module caches under `/private/tmp` and disabling SwiftPM's nested sandbox
  reaches production compilation, but the default Xcode backend then fails
  CoreMLModelCompile at its own `sandbox-exec` / `sandbox_apply` boundary.
- Actual app compilation/linking passed with:
  `CLANG_MODULE_CACHE_PATH=/private/tmp/p6-growth-clang SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/p6-growth-swift swift build --disable-keychain --disable-sandbox --disable-automatic-resolution --skip-update --build-system native -j 6`.
  The final pass linked `NativeAgentApp` successfully in 73.21 seconds. This
  backend is deprecated by the installed SwiftPM; it is a worker validation
  workaround, not a project build-policy change. Existing warnings remain.
- No app install, launch, quit, provider call, bridge request, separate test
  target or live check occurred. Global handoff outside the worktree was not
  modified because this assignment permits work only in this worktree.
