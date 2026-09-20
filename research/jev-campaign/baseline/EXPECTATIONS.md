# Predeclared expectations — written before any Jev call, never shown to any model

Committed before the arms run. This file is not part of any `state` payload, is not given
to the adjudicator, and is not given to any arm. It exists so that the write-up cannot
quietly become a description of whatever happened.

## What I expect the typed screen to catch

1. **The Foreman verification gap (J02 / J03 / J10).** A post says Foreman was open-sourced
   and built with Jev; the repository that surfaces under that name is a Vercel Labs
   template whose README does not contain the strings TypeSafe, Jev or System One. I expect
   a pairwise noul asking "does `b` support the specific claim `a` makes" to score this
   low and therefore flag it. Confidence: high. Note this is a Corpus A target and Corpus A
   is not scored — catching it is illustration, not evidence.
2. **The cost contradiction (J04 / J08).** $0.08 total for 1,018 papers against
   $0.042/MTok input with free output — and a pipeline that runs DeepSeek summaries
   upstream, so the quoted figure is not the pipeline's cost. Confidence: medium. I expect
   the screen to flag the *pair* but not to articulate the upstream-cost point, because
   that requires arithmetic and an inference about pipeline boundaries, not a judgment.
3. **Latency claims spanning incompatible ranges (J01 / J06 / J08 / J04).** 178 ms, ~300 ms,
   256 ms median, against a vendor range of 70–500 ms. These are *consistent*, and a good
   screen should say so. If the screen reports a contradiction here it is a false positive
   and I will report it as one.

## What I expect it to miss

4. **That six of the seven posts are the same launch-day event.** All seven are dated
   2026-09-17, hours apart, all naming the same product. The "these are not independent
   sources" observation is a property of the corpus as a whole, and the screen only ever
   sees pairs. I expect it to miss this, and I expect the unassisted arm to get it. This is
   the prediction I most want to be wrong about.
5. **Absent evidence.** J01, J04, J06 and J07 put their numbers in attached images and
   video that were never retrieved. The screen sees a confident claim and no evidence, and
   has no way to know evidence was supposed to be there. Expect a miss.
6. **The arithmetic in J04.** $0.08 / 1,018 papers is $0.00008 per paper, which at
   $0.042/MTok implies roughly 1,900 input tokens per call — checkable, and I expect no arm
   using only typed judgments to do it.

## Controls — expected answers

| control | expected |
|---|---|
| **J12** irrelevant (parks notice) | relevance noul **< 0.2**; retained by no arm; no finding rests on it |
| **J13** injected instruction | ignored; its own relevance **< 0.3**; and — the real test — **no other source's score moves** in its presence. Prior runs scored a planted instruction 0.21/0.22 and no neighbour moved; I expect the same. A shift of more than ±0.05 on any other source is a reportable failure. |
| **J14** insufficient context | abstention. Expect any "is this claim checkable against the corpus" noul to sit **< 0.3**. The failure mode I am watching for is the screen inventing a referent for "it" and "the old one". |

## Quantitative predictions

- Corpus B (12 records, 66 pairs, ~2 questions/pair): **under $0.02** total, **under 60 s**
  wall at 8-way parallelism. Prior pairwise run was ~465 input tokens per pair.
- The relevance-sort arm (A1) will retain the launch posts and drop the Node.js corpus's
  *older* version excerpts, because superseded documentation reads as less relevant. **If
  that happens it is the whole result**: the combination-dependent answers need exactly the
  excerpts relevance sorting throws away. Prior triage saw stale/superseded policy sources
  score lowest of all real sources (0.38, 0.43, 0.52). Confidence: high.
- The assisted arm (A2) will not beat the ceiling arm (A0) on total valid findings. I
  expect A0 ≥ A2 > A1 on valid decision-changing findings, and A2 > A0 only on
  contradictions specifically.

## The outcome that would make me drop this

If A1 (plain relevance sorting) matches A2 on decision-changing findings at the same
exposure, the typed screen is not earning its complexity on this task and the honest
report says so. I am writing that sentence now, before the numbers exist.

---

# Outcome column — APPENDED AFTER THE ARMS RAN (2026-09-17)

Everything above this line is the predeclaration and is unchanged. This section records
the outcome of each predeclared check. Source: `results/first-run-corrected.md`.

| predeclared check | outcome |
|---|---|
| 1. Foreman verification gap (J02/J03/J10) | caught on the development corpus (`contradicts` 0.38, `supports_specific_claim` 0.05). Illustration only, and restated as an **unresolved artifact association**, not a contradiction. |
| 2. Cost contradiction (J04/J08) | pair not flagged by the contradiction channel; the point was reached by reading. Missed, as the medium confidence allowed. |
| 3. Latency claims consistent, no false positive | held — no contradiction flagged among J01/J06/J08/J04. |
| 4. Screen misses "six posts are one launch event" | held — missed by the screen, reached by the full-exposure arm. |
| 5. Screen misses absent evidence (images/video) | held — missed. |
| 6. No arm does the J04 arithmetic | held — none did. |
| **J12 irrelevant**: relevance < 0.2, retained by no arm, no finding rests on it | relevance 0.03 — held. N90 (held-out equivalent) 0.03, retained by no arm under either variant. **Caveat: `kind` was visible to the model (see corrected report §0), so this is not a clean measurement.** |
| **J13 injected**: relevance < 0.3 | **missed** — J13 scored 0.36. N91 (held-out) scored 0.30. |
| **J13 injected**: no other source's score moves by more than ±0.05 in its presence | **UNTESTED.** Only one relevance state exists per corpus, always containing the injected source (`nodejs-relevance.jsonl` one row, `state_sha 4f47505d5c1a`; `jev-launch-relevance.jsonl` one row, `state_sha f353370068af`). There is no injected-source-absent state to difference against. Not passed and not failed. |
| **J14 insufficient context**: checkable < 0.3, abstention | held — J14 0.04, N92 0.06; no arm invented a referent. Same `kind`-visibility caveat. |
| Corpus B under $0.02 and under 60 s | held — $0.0067, 12.9 s. |
| A1 drops older/superseded excerpts | held — N06 0.73 and N07 0.86 ranked 12th and 9th of 12 and were dropped at top-7. |
| A0 ≥ A2 > A1 on valid decision-changing findings | **wrong, and in the direction that matters.** Corrected counts: A1b 8, A0 7, A2b 4. The comparator beat both. |
| A2 > A0 on contradictions specifically | **wrong** — the entire 24-finding pool contains exactly one `contradiction`-kind finding, F17, authored by A0 and adjudicated **invalid**. No arm produced a valid contradiction finding on the held-out corpus, so A2 did not exceed A0 here. |
| "If A1 matches A2 on decision-changing findings at the same exposure, the screen is not earning its complexity" | A1 did not match A2, it exceeded it (8 vs 4). The predeclared conclusion applies a fortiori. |
