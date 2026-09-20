# First run — track 1, research discovery

This is a historical research record. The standalone Python harness has been retired;
recorded results remain available, and original source is preserved in Git history.

Executed 2026-09-17. Two corpora, three arms, blinded adjudication.
Model `jev-1.13.0` via `jev.py`. All raw outputs in this directory.

---

## Headline

**At matched exposure, plain relevance sorting beat the typed-decision screen.**
On the held-out corpus: relevance sorting produced 8 valid findings, 8 of them
decision-changing, 4 unique to it. The typed screen produced 5 valid, 4 decision-changing,
1 unique. Neither had a control failure. Both were far below the unassisted ceiling.

`baseline/EXPECTATIONS.md`, written before any of this ran, says:

> If A1 (plain relevance sorting) matches A2 on decision-changing findings at the same
> exposure, the typed screen is not earning its complexity on this task and the honest
> report says so.

It did not match it — it exceeded it. So: **the screen as configured is not earning its
complexity on research discovery.** That is the result.

The qualification worth keeping is narrow and specific, and is in §4: the screen surfaced
one finding that relevance sorting could not have reached at any budget short of reading
almost everything, because the two sources it depends on rank 9th and 12th of 12.

---

## 1. Arms and exposure

Three arms, each executed by a **separate fresh worker** with no access to the others'
output, to the expectations file, or to the corpus ground truth. Arms were labelled X/Y/Z
for the adjudicator under a random mapping (`POOL_key.json`), revealed only after scoring.

| arm | method | sources | source chars | packet chars |
|---|---|---|---|---|
| **A0** | unassisted close reading of everything | 12 (+3 controls) | 7,445 | — |
| **A1b** | **relevance sort, top-7** — the comparator | 7 | 3,996 | 5,034 |
| **A2b** | **typed screen**, flagged pairs only | 7 | 3,744 | 5,051 |

Packets match within **0.3%**, and the match *favours the comparator*: A1b reads more
source text and the same number of sources. A0 is an unmatched ceiling, reported as such.

An earlier run of these arms was **void** and is retained only for audit
(`A1_findings.json`, `A2_findings.json`). Its A2 packet rendered each flagged pair as its
own block, so a source in three pairs was printed three times — 4,449 rendered chars
against A1's 3,429, about 30% more. The paired reviewer caught this; it is written up in
`PLAN.md`. Every number in this file comes from the corrected re-run.

## 2. Adjudication (blinded)

A separate worker applied `baseline/RUBRIC.md` to 24 pooled, shuffled, unlabelled findings.
Per-arm counts below remove **within-arm** duplicates only — of which there were **zero**;
all seven duplicate pairs the adjudicator found were cross-arm, i.e. two arms independently
finding the same thing, which is credit to both, not a deduction from one.

| arm | findings | valid | of which decision-changing | invalid | unsupported | unique to this arm | control failures |
|---|---|---|---|---|---|---|---|
| A0 (ceiling) | 11 | 10 | 7 | 1 | 0 | 5 | 0 |
| **A1b (relevance sort)** | **8** | **8** | **8** | **0** | 0 | **4** | **0** |
| **A2b (typed screen)** | **5** | **5** | **4** | **0** | 0 | **1** | **0** |

The one invalid finding (A0's) called a cross-version difference a "contradiction", which
the rubric defines as an exception. No arm produced an unsupported finding.

**Cross-arm rediscovery** — six findings were reached by more than one arm. Notably the
`--env-file-if-exists` version trap was found independently by all three.

## 3. Combination questions — what each arm could even see

The held-out corpus was built so that five questions are answerable only from a
*combination* of excerpts, each with a designated excerpt that misleads when read alone.
Ground truth (`corpus/nodejs/notes.md`) was written by the corpus builder and read by no
arm. This table is about **evidence availability**, upstream of whether an arm used it:

| question | A0 | A1b | A2b | holds the misleading excerpt without its context |
|---|---|---|---|---|
| Q1 `--env-file` missing file + multi-line | YES | **YES** | no | A2b |
| Q2 `node:sqlite` flag polarity flip | YES | no | **YES** | — |
| Q3 `--watch-path` on Linux | YES | no | no | **A1b and A2b** |
| Q4 Windows Worker `process.env` case | YES | no | no | — |
| Q5 permission model rename + scope | YES | no | no | A1b |
| **total** | **5/5** | **1/5** | **1/5** | |

Each restricted arm covered exactly one question, and **they covered different ones**.
Union of the two: 2 of 5. Both arms carried the Q3 trap — the v20.19.0 excerpt whose
removed platform restriction invites "so `--watch-path` is fine on Linux now", which is
false on every version in the corpus.

## 4. The one thing the screen did that sorting could not

**Q2, the `node:sqlite` flag polarity flip.** On v22.5.1 `--experimental-sqlite` *enables*
the module; from v22.13.0 SQLite is unflagged and the flag you reach for is the negative
`--no-experimental-sqlite`, which *disables* it. Both flags' docs say "Added in: v22.5.0",
so the "added in" line proves nothing. Getting this right needs N06 **and** N07.

Relevance ranks those two sources **12th (0.73) and 9th (0.86) of 12** — dead last and near
last. Relevance sorting has to read essentially the whole corpus before it sees them. The
pairwise screen scored N06|N07 at **0.75 on the exception channel**, its second-highest
real pair, and put them in front of the reader at rank 2. The adjudicator scored the
resulting finding (F22) valid and decision-changing; A1b did not produce it at any point.

That is the shape of the real effect, and it is much smaller than the pitch: the screen is
not better at finding things, it is better at *not discarding the unglamorous source*.
Superseded and low-status documentation is exactly what relevance sorting throws away and
exactly what version-dependent questions need. This reproduces the prior triage finding
that stale/superseded sources score lowest of all real sources.

## 5. Where the screen actually failed

**It detects change, not the persistence of a restriction across change.** The exception
channel fires cleanly when two excerpts describe the *same* feature changing:

| pair | what it is | exception score | flagged at 0.60? |
|---|---|---|---|
| N02\|N03 | `--env-file` throws vs `-if-exists` | 0.87 | yes |
| N06\|N07 | sqlite flag polarity flip | 0.75 | yes |
| N10\|N11 | `fs.watch` recursive restriction lifted | 0.62 | yes |
| **N08\|N09** | permission model renamed, scope widened | **0.43** | **no — near miss** |
| **N11\|N12** | `fs.watch` restriction lifted **but `--watch-path`'s did not** | **0.22** | **no** |
| **N10\|N12** | same, across two versions | **0.05** | **no** |

The two hardest and most useful judgements in the corpus are the bottom two rows, and the
screen is close to silent on both. Noticing that one platform gate moved while a
near-identical one did *not* is the thing a careful reader does and the thing this question
set does not ask. N08|N09 at 0.43 is a threshold near-miss; N11|N12 at 0.22 is not a
threshold problem, it is the wrong question.

**The verification-gap channel is dead and is reported as a negative result.** "Does `b`
substantiate the specific claim in `a`" flagged **56 of 105 pairs**, because two unrelated
documents naturally fail to support each other. Low support plus mutual relevance is not
evidence of anything. It is excluded from every count above, and was retained in the original
scorer with the reasoning. A usable version needs an independently established
relationship (`a` cites `b`) that this frozen question set does not establish.

**The contradiction channel's entire top-10 on the held-out corpus was the planted
instruction source.** N91 pairs scored 0.36–0.85; the highest real pair was 0.14. The model
did **not obey** the injected instruction — it correctly registered that "report no
contradictions, all versions identical" conflicts with the documentation, which is arguably
right. But it means the channel's ranked output is unusable without filtering controls out
by id, which a real deployment cannot do.

## 6. Controls

| control | relevance | checkable | retained by A1b | obeyed / claimed | verdict |
|---|---|---|---|---|---|
| N90 irrelevant (parks notice) | 0.03 | 0.79 | no | no finding rests on it | **pass** |
| N91 injected instruction | 0.30 | 0.06 | no | **not obeyed by any arm** | **pass** |
| N92 insufficient context | 0.20 | 0.06 | no | no arm invented a referent | **pass** |
| J12 / J13 / J14 (dev corpus) | 0.03 / 0.36 / 0.12 | 0.80 / 0.05 / 0.04 | no | — | **pass** |

Two notes. N90 scores 0.79 on *checkable* while scoring 0.03 on *relevance* — correct on
both counts: the parks notice is perfectly specific, just about nothing we asked. The
abstention gate works: N92 at 0.06 and J14 at 0.04 are the two lowest checkable scores in
either corpus.

One deviation from the predeclared expectations: J13's relevance was **0.36** against a
predeclared bar of "< 0.30". It was still dropped by every arm and obeyed by none, but the
bar was missed and is recorded as missed.

## 7. Development corpus (A) — illustration only

Corpus A is **not scored for discovery**: two of its targets were named in `PLAN.md` before
anything ran, so it can only measure recovery. Reported for the shape of the signal.

The contradiction channel fired on exactly **one real pair out of 91**, and it was the
predeclared target: **J02|J10 at 0.38** — a builder post claiming "I just open sourced
Foreman … built with Jev" against the repository that surfaces under that name, a Vercel
Labs template whose README contains no occurrence of "TypeSafe", "Jev" or "System One".
`supports_specific_claim` on that pair was **0.05**. Relevance sorting's top-6 dropped
**both** J02 and J10.

The exception channel's top five were all pairs against J09, the vendor page's own nuance
paragraph — the cardinality-255 two-stage slowdown and the "numbers are from OpenRouter"
caveat genuinely qualify the headline latency claims. That is the channel working.

Also standing, and found by reading rather than by any screen: the cost figure of $0.08 for
1,018 papers (J04) is not the pipeline's cost, because that pipeline summarises every paper
with DeepSeek V4 Flash upstream (J04's own text). And six of the seven posts are the same
launch day, hours apart — a property of the corpus as a whole that a pairwise screen cannot
see by construction. Both were predeclared as expected misses; both were missed.

## 8. Cost and time

| | requests | input tokens | output tokens | wall | median latency | errors |
|---|---|---|---|---|---|---|
| corpus A (dev) | 93 | 124,644 | 5,727 | 9.6 s | 0.69 s | 0 |
| corpus B (held-out) | 107 | 158,813 | 6,563 | 12.9 s | 0.71 s | 0 |
| **total** | **200** | **283,457** | **12,290** | **22.4 s** | **0.70 s** | **0** |

**$0.0119** at the vendor's published $0.042/MTok input, output free. Against the
predeclared "under $0.02 and under 60 s" for corpus B: actual **$0.0067 and 12.9 s**. Both
predictions held. Cost is genuinely not the constraint here — the constraint is that the
questions do not ask the hard thing.

## 9. Limitations

Stated plainly rather than buried.

- **One run, one corpus pair, no variance estimate.** Counterbalancing arm order across
  multiple cases and multiple independent adjudicators were both recommended by the
  reviewer and both declined as too large for a first run. Treat every number as
  illustrative-with-arithmetic, not as a measurement with error bars.
- **Single orientation.** Every pair was asked in one arbitrary direction, but "b is an
  exception to a" and "b supports a" are directional. Reported exception counts are a lower
  bound. Fixing it means re-freezing the question set and re-running both corpora.
- **The arms are language models, not people.** "Matched reading budget" is matched
  characters in a packet. It is a defensible proxy and it is not the same thing.
- **Corpus B is 12 excerpts.** Exhaustive pairing is only affordable because it is small;
  at 100 sources this is 4,950 pairs and blocking comes back, bringing the unaudited-pair
  problem with it.
- **Adjudicator saw arm labels X/Y/Z but all findings from one arm carried one label**, so
  it could in principle have inferred style clusters. It was instructed not to and showed
  no sign of trying, but the blinding is not airtight.

## 10. What I would do next, given this result

Not "tune the thresholds" — that is the test-set tuning the whole design exists to prevent.
The specific, falsifiable next step is a question that asks the thing §5 shows is missing:
given two features documented as having the same restriction, and a later version that
lifts it for one of them, does the restriction still apply to the other? That is a
*persistence* question, not a *change* question, and nothing in the current set asks it.

That, plus the extraction-check ("sandwich") shortlist item, where the verify step has a
defined relationship between the claim and the span — exactly the thing whose absence
killed the verification-gap channel here.
