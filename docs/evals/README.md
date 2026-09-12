# Evaluation guide

The canonical regression command is `./script/test.sh`. It runs deterministic
shell guards (including iOS release fixtures), bridge and Chrome-extension Node
tests, Core XCTest plus serial Swift Testing shards, Shared tests, Mac app tests,
and iOS simulator tests. Chrome fixtures mock the browser; they do not drive
the installed browser. iOS can explicitly skip when unavailable in an ordinary
run; use `--require-ios` when iOS execution is required.

`./script/test.sh --release-receipt /tmp/nativeagent-test-receipt.json` requires
iOS execution and a clean, unchanged Git revision. It first marks the attempt
incomplete, preserving any previous receipt, and publishes positive proof only
after every gate succeeds. A historical receipt never certifies later edits.

## Other eval entry points

2026-09-10: User authorized retiring the Full Mac timer. Full Mac now means
"the saved policy is Full Mac" — no clock, no expiry downgrade, no file-tool
sweep — so four ledger rows were retired: `core.trust.securityPolicy.fullMacNeverExpires`,
`core.trust.trustCenter.fullMacExpiryDurationIntentKey`,
`ui.TrustCenter.fullMacSessionPanel` and `app.background.loop.full_mac_expiry`.
Three surviving rows (`gate.fullMacActive`, `setting.trust.developerMode`,
`store.trust.policy`) lost their references to the deleted
`FullMacDurationAndExpiryTests.swift`, and `gate.fullMacActive` now records the
saved-policy failure mode instead of an expiry window. Three override
references were repointed onto renamed surviving cases. None of the retired rows
were in the frozen 633-row campaign, so that boundary is unchanged; both
baselineInputs hashes are refreshed.

2026-09-09: Refreshed the frozen input hash for four additive release-gate
inventory rows: `studio_shelf_set`, `studio_shelf_read`, `browser.chrome_drag`,
and `snapshot_simplicity.sh`. All 1,507 prior overrides and their coverage
references are unchanged, as are the 633 campaign members and phase1 hash.
The snapshot wrapper remains explicitly uncovered; tool rows reference their
existing dispatch tests.

2026-09-08: Refreshed the frozen total-coverage input hash after reviewing
`ed3c0b70`: 14 additive rows (ten bot/shelf tools, standing-bots module,
Bots shelf UI, chat tool pill, and snapshot script), with no existing rows or
coverage references removed or replaced. All 633 reviewed campaign members
remain in the ledger; these additions do not change that historical burn-down
boundary. The phase1-fragments hash is unchanged.

| Command | Scope and effects |
|---|---|
| `./script/evals.sh` | Smoke, read-only instrument over the checkout's `data/`, synthetic turn/range tests, ledger keeper and surface-contract checks. Not the full regression gate; duration varies. |
| `./script/evals.sh --changed <sha>` | Ledger-mapped checks for one commit plus keeper/contract checks, including focused iOS simulator classes referenced by changed surfaces. Fails on unmapped executable coverage or zero selected tests; not proof of unselected behavior. |
| `./script/evals.sh --ios` | Adds required iOS simulator execution. |
| `./script/evals.sh --ui` | Adds a strict Accessibility walk of the installed app; it interacts with UI. |
| `./script/evals.sh --full` | Adds feed observations, the canonical gate with required iOS, then installs and verifies the built app if prerequisites pass. **Mutates the installed app.** Does not imply `--ui`. |
| `./script/evals.sh --live` | Adds an explicitly opted-in provider-backed range scenario on a persona clone; spends tokens. |

Full-mode/source receipts do not turn simulated behavior into installed longevity,
external delivery, or a user-confirmed result. The standalone
`script/tests/codex_wakeup_helper_pipe.test.swift` is a historical mechanism
demonstration, outside the canonical gate; Node tests check shipped helper wiring.

## Coverage inventory, not a fresh receipt

[COVERAGE.md](COVERAGE.md) and `ledger.json` are deterministic projections of
`phase1-fragments.json`, `coverage-overrides.json`, and `coverage-campaigns.json`.
`COVERED` means the merged row contains a reference marked `strength: asserts`.
It is not a statement that the evaluator ran on HEAD, or that every failure
hypothesis/proposed eval in the original row has been resolved. Recorded audit
run notes and dated campaign lists remain historical evidence. The keeper and
structural contracts check inventory consistency, not all runtime behavior.
Catalog membership or reaching a known dispatch boundary is only reachability
evidence: the merge refuses to label the exhaustive route probes as asserting
functional tool coverage. A tool needs a valid-input behavior test at its
owning implementation before that route can be marked covered.

Every eval entry point also validates current `coverage-overrides.json` test
paths, path-qualified line anchors, and `[swift-filter: ...]` selectors. Historical
phase-1 prose remains dated evidence, but a post-inventory override cannot keep
certifying a deleted test, an out-of-range line, or a vanished suite.

Update canonical inputs, then regenerate both outputs:

```sh
swift script/evals_ledger_merge.swift docs/evals/phase1-fragments.json --out docs/evals
```

Use exact suite/function references for new evidence; preserve meaningful
behavior assertions and negative controls. A stale reference needs correction,
not a broader exemption or a passing label. Provider-backed, installed-UI, and
publication checks need their own explicitly authorized scope.
