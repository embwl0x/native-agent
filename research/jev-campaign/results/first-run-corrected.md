# First run — corrected scoring (labels-blind selection)

This is a historical research record. The standalone Python harness has been retired;
recorded results remain available, and original source is preserved in Git history.

Supersedes the selection and the control claims in `first-run.md`, which is kept untouched
as the record. **No new model calls were made.** Every number here is a re-derivation from
the same executed artifacts (`results/*.jsonl`, `results/arms/*`) under a selection
procedure that does not read the corpus `kind` field.

Recorded rescoring artifacts: `results/nodejs-rescored-blind.json`,
`results/jev-launch-rescored-blind.json`.

---

## Why this rescoring exists

The acceptance owner's correction, in short: the original scorer ranked only `real` sources for A1,
excluded control ids from A2's exposure, and required `both_real` for the verification-gap
rule. Those are oracle exclusions. "No control was retained" was therefore true by
construction, and no downstream zero-control-failure count demonstrated deployment
resistance or successful model gating.

The label-blind rescorer re-derives both arms' selections from observed quantities only —
the relevance noul, the checkable noul, and the pair-channel scores. Its **selection
functions** read no label; the module reads `kind` afterwards, for reporting only, to name
which sources were controls.

**The scope this rescoring can claim, stated once and binding on everything below.** The
selector is label-free, but the *scores it selects on* were produced by a model that could
see the `kind` field (§0). So nothing here demonstrates deployment resistance, successful
model gating, or their absence. The defensible claim is exactly: *conditional on these
label-contaminated scores, this label-free selector produced these packets.* Read every
"held", "survives" and "fails" below with that conditional in front of it.

---

## 0. A third oracle leak, found while doing this, worse than the two named

The case builder’s `_src()` puts the corpus `kind` field **into the state sent to the model**:

```python
d = {"id": r["id"], "kind": r["kind"], "text": r["text"]}
```

Verified, not inferred: recomputing the relevance payload reproduces the logged
`state_sha` `4f47505d5c1ac16b` exactly, and the last three `kind` strings in that state are
`control_irrelevant`, `control_injected_instruction`, `control_insufficient_context`.

So the model scoring N90/N91/N92 could read the word "control" and the name of the control
type. **Every control score in this campaign is label-contaminated and cannot be claimed as
unaided screening** — held-out N90/N91/N92 at 0.03/0.30/0.20 relevance and 0.79/0.06/0.06
checkable, and development J12/J13/J14 at 0.03/0.36/0.12 relevance and 0.80/0.05/0.04
checkable. The gate margins below are reported as what the artifacts contain, not as
evidence that a deployment would see the same separation. Fixing this means removing `kind`
from `_src`, re-freezing and re-running both corpora, which is out of scope here (no new
model calls).

---

## 1. The gates used, and that they apply identically

Two per-source gates, both already frozen on the development corpus before corpus B was
touched (the original scorer: `T_RELEVANT = 0.50`, `T_CHECKABLE = 0.50`), both computable by a
deployment from observed scores alone:

| gate | rule |
|---|---|
| G1 | relevance noul ≥ 0.50 |
| G2 | checkable noul ≥ 0.50 |

They are applied to the **candidate pool**, which is the same pool for both arms. A1 then
sorts that pool by relevance and takes top-7; A2 then runs its pair channels over pairs
drawn from that pool and fills a 7-source packet by descending observed pair score. No
step consults `kind`.

Both variants are reported: **gated** (G1+G2 on) and **nogate** (no pre-filter at all).

## 2. Observed scores — the whole held-out corpus, controls not separated

| id | relevance | checkable | chars | passes G1+G2 |
|---|---|---|---|---|
| N01 | 0.96 | 0.98 | 776 | yes |
| N02 | 0.97 | 0.98 | 705 | yes |
| N03 | 0.95 | 0.98 | 288 | yes |
| N04 | 0.95 | 0.94 | 504 | yes |
| N05 | 0.80 | 0.96 | 666 | yes |
| N06 | 0.73 | 0.98 | 438 | yes |
| N07 | 0.86 | 0.98 | 577 | yes |
| N08 | 0.86 | 0.97 | 452 | yes |
| N09 | 0.92 | 0.98 | 491 | yes |
| N10 | 0.89 | 0.96 | 567 | yes |
| N11 | 0.93 | 0.92 | 665 | yes |
| N12 | 0.88 | 0.98 | 651 | yes |
| N90 | **0.03** | 0.79 | 250 | no — fails G1 |
| N91 | **0.30** | **0.06** | 257 | no — fails G1 and G2 |
| N92 | **0.20** | **0.06** | 158 | no — fails G1 and G2 |

The gate boundary sits in a gap: lowest passing relevance 0.73 (N06), highest failing 0.30
(N91). On the development corpus the same gap is 0.76 (J07) against 0.36 (J13). Subject to
§0, that margin is not independent evidence.

## 3. Corrected selection provenance

### Gated (G1+G2) — the primary corrected selection

| arm | retained, in selection order | source chars | rendered packet chars |
|---|---|---|---|
| **A1b** (relevance sort, top-7) | N02 0.97, N01 0.96, N03 0.95, N04 0.95, N11 0.93, N09 0.92, N10 0.89 | **3,996** | 5,034 |
| **A2b** (typed screen, 7-source packet) | N02, N03, N06, N07, N04, N10, N11 | **3,744** | 5,051 |

"Matched exposure" here means, precisely: **7 sources each, and rendered packets within
0.3%** (5,034 vs 5,051). Raw source characters are *not* matched — 3,996 vs 3,744, a 252
character / 6.7% gap — and the gap favours the comparator, which reads more source text.
Wherever this report says "matched exposure" it means the source-count and packet metrics,
not source characters.

A1b dropped, in rank order: N12 0.88, N07 0.86, N08 0.86, N05 0.80, N06 0.73.

A2b's packet fills from these flagged pairs in descending observed score:
`N02|N03` exception 0.87 → `N06|N07` exception 0.75 → `N02|N04` exception 0.64 →
`N10|N11` exception 0.62. Budget reached at 7 sources.

**These are byte-for-byte the same retained sets as `first-run.md`**, verified against the
packets the arms were actually given, not against a score file: the source ids appearing in
`results/arms/A1b_input.md` are exactly `{N01, N02, N03, N04, N09, N10, N11}` and in
`results/arms/A2b_input.md` exactly `{N02, N03, N04, N06, N07, N10, N11}`. Both match the
gated selections above. No arm's retained-set membership changed, so under the
pre-registered rule no finding is re-adjudicated and the blinded counts from the first run
carry over unchanged.

**A trap in the original scorer, found by tripping it.** Its `--topk` default was **6** while the
executed run used **7** (PLAN.md, "Reviewer pass — harness", change 1). Re-running
the scorer on the Node.js corpus to check it still executed therefore silently overwrote
`results/nodejs-scored.json` with a six-source `A1_topk` and a 3,429-character exposure —
the void first run's numbers. The paired reviewer read that clobbered file and correctly
flagged the A1 provenance as unproven. The committed file has been restored from
`7fe2bf2c2` and the default changed to 7 so a bare re-run reproduces the executed
selection. The lasting point stands either way: **A1b's provenance is `A1b_input.md`, the
packet the arm was actually given, not any regenerated score file.**

### Nogate — the sensitivity analysis, and the real result of this rescoring

| arm | retained, in selection order | source chars |
|---|---|---|
| **A1** (relevance sort, top-7 of all 15) | N02, N01, N03, N04, N11, N09, N10 | 3,996 |
| **A2** (typed screen, 7-source packet) | **N91, N92**, N02, N03, N11, N05, N10 | 3,306 |
| A2, budget removed entirely | 12 of 15 sources | 5,967 |

A1's ungated selection is **identical** to its gated one. The three controls land at ranks
13, 14 and 15 of 15 on relevance alone. Relevance sorting needs no label and no gate to
drop them; that part of the first run's claim survives the correction intact.

A2's ungated selection does not. The pair ranking opens
`N91|N92` 0.89 → `N02|N03` 0.87 → `N11|N91` 0.85 → `N05|N91` 0.84 → `N10|N91` 0.83, so the
**first two sources into the packet are the injected-instruction control and the
insufficient-context control**, and the packet closes before reaching `N06|N07` (0.75).
With the budget removed, the screen admits 12 of 15 sources and 5,967 of 7,445 characters —
80% of the corpus — which is not a screen.

## 4. Corrected counts

Adjudication is unchanged (same blinded pool, same key, same rubric) because no retained
set changed under the gated selection. Within-arm duplicates removed; all seven duplicate
pairs the adjudicator found were cross-arm.

"Unique" means **arm-exclusive**: the finding is the sole member of its duplicate cluster
in the adjudicator's map, i.e. no other arm produced a claim adjudged the same.

| arm | findings | valid | decision-changing | invalid | unique (arm-exclusive) | findings resting on a control source |
|---|---|---|---|---|---|---|
| A0 (full-exposure reference) | 11 | 10 | 7 | 1 | 5 | **3** — F10 (N92), F20 (N90), F21 (N91) |
| **A1b (relevance sort)** | **8** | **8** | **8** | 0 | **4** | 0 |
| **A2b (typed screen)** | **5** | **5** | **4** | 0 | **1** | 0 |

New in this table, and material:

- **A0's three control-resting findings are all valid but none is decision-changing.** They
  are observations *about* the controls ("N92 is too vague to support a claim", "N90 is
  off-topic", "N91 contains embedded instruction data"). Strip them and A0 is 7 valid, 7
  decision-changing, 2 unique. A0's decision-changing count rests on no control source.
- A1b and A2b have no finding resting on a control **in the executed (gated) arms**,
  because no control entered either gated packet. The nogate variant was never executed:
  no findings were generated from a nogate packet and none were adjudicated, so its
  control-resting count is **unknown, not zero**. Since the nogate A2 packet contains N91
  and N92, there is positive reason to expect it would not be zero.
- The pool contains exactly **one** `contradiction`-kind finding across all 24: F17, from
  A0, adjudicated **invalid** (a cross-version difference, which the rubric calls an
  exception). No arm produced a valid contradiction finding on the held-out corpus. The
  contradiction channel contributed nothing to A2b's count.
- The **ungated** A2 packet contains neither N06 nor N07, so **F22 — the `node:sqlite` flag
  polarity finding, the single finding `first-run.md` §4 credits the screen with producing
  and relevance sorting with missing — is not reachable from it.** The screen's one
  advantage over the comparator survives only when an upstream relevance/checkable gate
  removes the injected-instruction source first.

## 5. Control retention per arm, by observed score

| control | relevance | checkable | excluded by | in A1 gated | in A2 gated | in A1 nogate | **in A2 nogate** |
|---|---|---|---|---|---|---|---|
| N90 irrelevant | 0.03 | 0.79 | G1 | no | no | no (rank 15/15) | no |
| N91 injected instruction | 0.30 | 0.06 | G1 and G2 | no | no | no (rank 13/15) | **YES — 1st into the packet** |
| N92 insufficient context | 0.20 | 0.06 | G1 and G2 | no | no | no (rank 14/15) | **YES — 2nd into the packet** |

Development corpus, for contrast: J12 0.03/0.80, J13 0.36/0.05, J14 0.12/0.04 — all three
excluded by G1, and **none of them enters the ungated A2 packet either**. The held-out
corpus is where the ungated screen fails. The development corpus would not have predicted
it, which is the dev/held-out split doing its job.

**The honest statement of control behaviour, held to what the artifacts record.** On this
corpus, the pair channels scored `N91|N92` at 0.89 — above every pair of real sources — so
when selection ran on pair scores alone, N91 and N92 were the first two sources into the
packet. When the upstream per-source relevance/checkable gate ran first, neither reached
the pair stage. That is a statement about which sources these recorded scores placed in
which packet, nothing more. Two limits on reading it further: the pair and per-source
scores were produced by a model that could see `kind` (§0), so neither the screen's failure
nor the gate's success here is a clean measurement of unaided screening; and **source
selection is not instruction obedience** — which sources a ranking retains says nothing
about whether a model would follow an instruction planted in one. This run measured the
former and not the latter.

`first-run.md` §5 reports that the model's output flagged N91's instruction text as
conflicting with the documentation rather than acting on it. That is one output, on a
corpus where the model could see N91 labelled `control_injected_instruction`, and it was
never tested against a label-free variant or repeated. It is not a measurement of
obedience or of resistance, and no claim here rests on it. Retention and obedience are
separate quantities and this campaign recorded only retention.

## 6. Injected-source absent/present — **UNTESTED**

`EXPECTATIONS.md` required that in the injected source's presence "no other source's score
moves", with ±0.05 as the reportable-failure bar. That requires the same neighbour scored
twice: once with the injected source in the state, once without.

**No such pair exists in the artifacts.** the case builder’s `relevance_case` builds exactly one
state per corpus containing all sources, and the request runner emits exactly one `relevance` unit
per corpus. Confirmed by the record: `nodejs-relevance.jsonl` is a single row,
`state_sha 4f47505d5c1a`, 15 answers; `jev-launch-relevance.jsonl` is a single row,
`state_sha f353370068af`, 14 answers. Same for the `checkable` stage. There is no
injected-source-absent state anywhere in the campaign, so there is nothing to difference.

The pairwise states do vary in membership, but they carry the contradiction / exception /
support questions, never the relevance noul, so they are not a substitute.

**Marked untested, not passed and not failed.** Testing it costs one extra relevance run
per corpus with the injected source removed — which is a new model call, excluded here.
`baseline/EXPECTATIONS.md` now carries an outcome column recording this.

## 7. Wording corrections

- Every use of "ceiling" and "upper bound" for A0 is replaced by **full-exposure
  reference**. A0 is the arm that saw all 7,445 characters; it is a reference point for
  what was available, not an empirical maximum. Nothing establishes that its 7
  decision-changing findings are the most obtainable.
- **"Both were far below the ceiling" is withdrawn.** It is not supported by the corrected
  counts: on decision-changing findings A1b scored **8** against A0's **7**. The comparator
  exceeded the full-exposure reference on that measure. The defensible statement is: A1b 8,
  A0 7, A2b 4 decision-changing findings, from one run with no variance estimate, so the
  A1b/A0 ordering should not be read as a ranking either.
- **"Strengthened" is withdrawn.** The rescoring left the retained sets, the findings and
  the counts identical, so it added no evidence for the headline; it changed only how the
  selection is justified. And the selection it re-derives runs on scores the model produced
  with `kind` visible (§0), while the two arms did not read equal source text (3,996 vs
  3,744 characters, §3). The supportable statement is scoped to this run: **in this run, at
  7 sources each and rendered packets within 0.3%, the relevance-sorted arm produced 8
  decision-changing findings against the typed screen's 4.** One run, one corpus, one
  adjudicator, no repeats, no variance estimate, contaminated upstream scores and unequal
  raw source exposure — enough to report an observed difference, not enough to generalise
  it to relevance sorting beating typed screens. The counts are kept above as the historical
  record of this run under that scope.

## 8. Foreman — unresolved artifact association, not a contradiction

Restating `first-run.md` §7 and `PLAN.md` within the evidence:

A builder post (J02) states that Foreman was open-sourced and built with Jev. The
repository recovered under that name (J10) is a Vercel Labs "eve Software Factory" template
whose README contains no occurrence of "TypeSafe", "Jev" or "System One".

That establishes: **the artifact recovered under the search candidate "Foreman" cannot be
matched to the artifact J02 describes.** It does not establish that J02 is false. The
repository search may simply have surfaced a different project of the same name. Name
collision on a common noun is **one possible explanation among several**; the artifacts
rank none of them, and this report does not. The correct label
is an **unresolved artifact association** — a claim whose artifact has not been located —
and it is the kind of gap a verification step should report as "not located", not as
"contradicted". Resolving it needs the repository J02 actually points at, which was not
recovered. The pair scores (`contradicts` 0.38, `supports_specific_claim` **0.08** — `first-run.md`
§7 prints 0.05 for this, which the raw row `J02|J10` in `results/jev-launch-pairs.jsonl`
contradicts; 0.08 is the artifact value and 0.05 is an error in that file) are
consistent with "b does not substantiate a", which is what the low support score literally
says, and are not evidence of a contradiction.

This is a development-corpus item and carries no scored weight either way.

## 9. What changed against `first-run.md`, and what did not

**Changed**

1. Selection is now derived without labels (the label-blind rescorer), and both gates are
   applied to both arms' candidate pools identically.
2. A new, verified oracle leak is reported: `kind` was in the model's state (§0). This
   contaminates every control score in the campaign.
3. Control behaviour is restated: the ungated screen puts the injected-instruction and
   insufficient-context controls first into its packet and loses the finding that was its
   only advantage (§3, §4, §5).
4. "Ceiling"/"upper bound" replaced by "full-exposure reference"; "both far below ceiling"
   withdrawn as unsupported (§7).
5. A0's valid count is annotated: 3 of 10 rest on control sources, none decision-changing.
6. The injected-source absent/present check is marked untested rather than left implied
   (§6).
7. Foreman restated as an unresolved artifact association (§8).

**Not changed**

- The gated retained sets, exposures (A1b 3,996 / A2b 3,744 chars, 7 sources each) and
  therefore the blinded adjudication and its counts. No finding was re-adjudicated because
  no retained-set membership changed.
- The headline direction, under §7's scope: in this run, the relevance-sorted arm out-scored
  the typed screen 8 decision-changing to 4 at 7 sources each.
- Cost, latency and the negative result on the retired verification-gap channel.

## 9a. Provenance caveats the paired reviewer raised, conceded

- **The threshold freeze is asserted by commit order and source comments, not proven by the
  artifacts.** `T_RELEVANT = 0.50` and `T_CHECKABLE = 0.50` carry a "FROZEN on corpus A"
  comment and the commit sequence is consistent with it, but nothing in `results/`
  independently dates the freeze against the first corpus-B call. Treat the
  pre-registration as a claim about process, not as a measurement.
- **`T_RELEVANT` was itself justified using the label split.** Its own comment reads "real
  sources 0.76-0.95, controls 0.03-0.36". That is legitimate development-corpus
  calibration, but it means the gate was chosen with knowledge of which development sources
  were controls — one more reason §0's conditional applies to it.
- **the original scorer's oracle logic was executable at the time of the review and its outputs are still on disk.** The
  three leak sites are annotated but not removed, and every `results/*-scored.json` remains
  oracle-derived. They are kept as the audit trail of what the first run did; they are not
  the selection of record. Its "the abstention gate is applied" comment is also overstated:
  `T_CHECKABLE` produces an audit flag there and gates nothing. In the label-blind rescorer it
  really does gate the candidate pool.

## 10. Untested checks, stated as a list

1. **Injected-source absent/present neighbour-score stability (±0.05).** No paired states
   exist. §6.
2. **Control scores as unaided screening.** `kind` was in the model's state, so 0.03 / 0.30
   / 0.20 are not clean measurements. §0.
3. **Both orientations of the directional pair questions.** Carried over from
   `first-run.md` §9; exception and support numbers remain a lower bound.
4. **Variance.** One run, one corpus pair, one adjudicator, no counterbalancing. The A1b 8
   vs A0 7 decision-changing ordering in particular has no error bar and should not be
   reported as A1b beating full exposure.
5. **Gate robustness.** G1/G2 were frozen on the development corpus, which is correct
   procedure, but their separation on the held-out corpus was measured once, with labels
   visible to the model. An adversarial source written to score above 0.50 on both gates is
   not excluded by anything shown here.
