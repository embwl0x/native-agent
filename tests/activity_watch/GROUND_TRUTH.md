# Ambient activity watcher — simulation GROUND TRUTH

The correctness proof for the span state machine, used because the build machine's
screen was locked for the entire build (`HIDIdleTime` 5.4 h and rising), so the
live AX path could not be exercised.

**Why this is a real test, not a rationalisation:** the expected-output table was
written down *before* running the simulator, and `verify_ground_truth.py` encodes
it independently of the implementation. The watcher and the simulator drive the
**same** `ActivitySpanEngine` — a parallel copy would make this worthless.

Run:

```
swift build --package-path Modules/NativeAgentCore
Modules/NativeAgentCore/.build/debug/activity-probe \
    simulate --script tests/activity_watch/ground_truth_script.json --data-root /tmp/gt
Modules/NativeAgentCore/.build/debug/activity-probe reconcile --data-root /tmp/gt
sqlite3 -json /tmp/gt/activity_watch/activity_spans.sqlite \
  "SELECT id,started_at,ended_at,last_seen_at,bundle_id,app_name,title_redacted,event_count,close_reason
   FROM activity_span ORDER BY started_at;" \
  | python3 tests/activity_watch/verify_ground_truth.py /dev/stdin
```

The `reconcile` step is not a workaround — `crash` is the script's last event, and
closing an abandoned span is what the *next launch* does. It is the crash-recovery
path under test.

Base epoch `T = 1_700_000_000`. Policy: `captureEnabled`, `captureTitles` ON;
`browserTitlesEnabled` OFF.

## Expected spans (7) — matched exactly, 59/59 checks

| # | bundle | start | end | reason | title |
|---|---|---|---|---|---|
| 1 | com.apple.Terminal | 0 | 150 | windowChange | `build - zsh - 80x24` |
| 2 | com.apple.Terminal | 150 | 300 | appChange | `[redacted]` |
| 3 | com.apple.Safari | 300 | 900 | idle | **nil** |
| 4 | com.apple.dt.Xcode | 1200 | 1500 | lock | nil |
| 5 | com.apple.dt.Xcode | 1810 | 2400 | sleep | nil |
| 6 | com.apple.Terminal | 3010 | 3100 | appChange | nil |
| 7 | com.apple.Terminal | 3200 | 3250 | abandoned | nil |

A span's **first** title is its INITIAL title: it is stamped onto the open row in
place (a `retitle` command) and counted as an event. Only a title arriving when
the span **already has one** is a genuine window change — that closes the span as
`windowChange` and opens a successor carrying the new title, which is why row 2
carries `[redacted]` and not row 1.

### Why this table changed on 2026-08-14 (8 rows became 7)

**A LIVE run found the first-title split was manufacturing a junk zero-length row
on every single app switch.** Two minutes of real use with 6 app switches
produced **16 spans, 8 of them 0 seconds long**:

```
Finder      14:51:44  0s  windowChange   <- junk
Finder      14:51:44  26s appChange      <- real
TextEdit    14:52:09  0s  windowChange   <- junk
TextEdit    14:52:09  18s appChange      <- real
```

The mechanism: a span opens on `activate` with **no** title, because the
capture-time exclusion gate runs before any AX read. The live watcher then reads
the window title *microseconds* later and feeds it back as a `titleChange`. The
old engine saw `redacted != span.titleRedacted` and split the span it had just
opened.

**This script never caught it because it separated `activate` (t=0) from the
first `titleChange` (t=90) by ninety seconds** — so the split produced a
plausible-looking 90 s row instead of obvious garbage, and the old expected table
faithfully wrote that wrong behaviour down as correct. The table was wrong by
design, not by transcription. The fix (engine `retitle`) removes the split; rows
1 and 2 of the old table merge into one 0→150 span carrying the title, and the
count drops from 8 to 7.

The verifier now also asserts **no span has zero duration**, which is the check
the old table structurally could not make.

## The invariants this proves

1. **Exactly 7 spans** — an extra row means the lock gate or an exclusion leaked,
   or the first-title split came back.
2. **No zero-length spans** — the live-run defect above, pinned. Row 1's title
   lands IN PLACE at t=90 instead of splitting the span.
3. **Every open has exactly one close**; nothing left `ended_at IS NULL`.
4. **Zero rows while locked** — the script activates Notes *and* fires a focus
   event during `[1500, 1800]`; neither may produce anything.
5. **1Password never appears** — capture-time exclusion, checked before any AX read.
6. **Safari's title is nil** while its duration is kept — the browser double-gate
   (`captureTitles` AND `browserTitlesEnabled`) drops the title, not the span.
7. **A secret-shaped title becomes `[redacted]`** — row 2's raw input was an
   `sk-ant-…`-shaped string.
8. **The abandoned span closed AT `last_seen_at` (3250), not at "now"** — a crash
   must not invent the time between the crash and the next launch.
9. **No overlap** — `end[i] <= start[i+1]` for all spans.

## Event rate

`7 events / 1930 s observed = 13.06 events/hour`.

(7, not the pre-fix 6: the first title is now counted as an event on the span it
lands on instead of being spent opening a successor row. Observed seconds are
unchanged — the merge removed a row, not any time.)

This validates the arithmetic **only**. It is a property of this script, not of
any human. The real events/hour figure needs an unlocked screen and a person
generating live AX callbacks, and is still outstanding.
