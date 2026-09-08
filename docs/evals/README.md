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
