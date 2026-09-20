# Jev campaign — plan

This is a historical research record. The standalone Python harness has been retired;
recorded results remain available, and original source is preserved in Git history.

Research only. Nothing here is product code. The agent owns synthesis, experiment design
and acceptance; this worktree owns the harness and the executed comparison.

## Question

Does a typed-decision screen (Jev: choice / noul / score with calibrated probabilities)
find things in a source corpus that relevance sorting does not — specifically
**contradictions between sources, exceptions, unanswered questions, and source-verification
gaps** — under a *matched reading budget*, and at what cost?

Track 1 (research discovery) is the one executed in this first return. Tracks 2 and 3
(completion checks, memory connections) get small cases later; the shortlist is at the
bottom.

## Why the obvious version of this is worthless

The failure mode is grading Jev on Jev's own launch marketing, where every "source" is a
builder saying a nice thing. Six of the seven seed posts are promotional and several
restate each other. Repeated marketing is not independent evidence and is not counted as
such. Two defences:

1. A **second, non-Jev domain corpus** (Node.js CLI/runtime docs across versions and
   platforms) where the right answer depends on the *combination* of version + platform,
   and where ground truth is checkable against the fetched text rather than against taste.
2. **Controls inside both corpora**: an insufficient-context case where abstention is the
   correct answer, an irrelevant source, and an injected-instruction source.

## Corpora

**Corpus A — `corpus/jev-launch/`.** The seven seed posts, recovered verbatim through X's
public syndication endpoint (the plain HTML pages are JS shells and carry no post text —
recorded in the manifest). Plus the primary pages they point at: the TypeSafe launch post,
the structured-question guide, and the Foreman repository. Several post texts are visibly
cut off mid-sentence at the 280-character display boundary; each is flagged `truncated:
true` rather than completed by guesswork.

This corpus already contains at least two real discovery targets found while fetching:

- A **source-verification gap**: a builder post says "I just open sourced Foreman … built
  with @typesafeai's Jev", while the Foreman repository that surfaces under that name is a
  Vercel Labs "eve Software Factory" template whose README does not mention TypeSafe, Jev
  or System One at all. Either the linked repo is a different Foreman, or the claim is not
  verifiable from the artifact. A relevance sort keeps both sources happily; it has no way
  to notice they disagree.
- A **contradiction on cost**: the vendor page states output tokens are free and input is
  $0.042/MTok, while the campaign framing and several posts talk in cents-per-call; one
  post reports $0.08 total for 1,018 papers, but that pipeline runs upstream DeepSeek
  summaries, so the quoted figure is not the pipeline's cost.

**Corpus B — `corpus/nodejs/`.** 10–12 short verbatim excerpts from real public Node.js
documentation and changelogs across versions, written so that several questions are only
answerable from a *combination* of excerpts (version + platform), and where any single
excerpt read alone yields the wrong answer. Ground truth is recorded separately and never
sent to the model.

Every source file is hashed; `corpus/MANIFEST.md` lists id, URL, fetch route, SHA-256, and
an explicit `unavailable` / `truncated` note where recovery was partial. Nothing is
paraphrased into the corpus.

## Protocol (rewritten after the reviewer pass)

The first draft had the same person write the baseline and then run the assisted pass over
the same corpus, with two discovery targets already named in this very file. The reviewer
called that fatal carryover and a known-target benchmark, and they was right. The revised
design:

**Corpus A is demoted to a development corpus.** It is where question wording, thresholds
and routing are chosen. Its findings are reported as illustration, never as the scored
discovery result. This is deliberate: I have already stated two of its targets in writing,
so it can no longer measure discovery, only recovery.

**Corpus B (Node.js docs) is the held-out scored corpus.** It was built by a separate
worker; its ground truth (`corpus/nodejs/notes.md`, combination questions and answers) is
not read by me before the arms run, and is not read by any arm. The Jev configuration —
question wording, thresholds, blocking rules — is **frozen from Corpus A and committed
before Corpus B is touched.** No tuning on the scored corpus.

**Three arms, each executed by a separate fresh worker with no access to the others' output
and no access to this file's discovery discussion.** Each receives the same task prompt and
the same corpus records, differing only in what it may read:

| arm | what it gets | what it is |
|---|---|---|
| **A0** | the full corpus text, unassisted | human-equivalent close reading, the honest ceiling |
| **A1** | sources ranked by a single relevance noul, top-k only | **the real comparator** — relevance sorting, which is what Jev is supposed to beat |
| **A2** | only what the typed-decision screen surfaces: flagged pairs, flagged spans | the Jev-assisted arm |

A1 is the arm the first draft was missing. Comparing the typed screen against *unassisted
reading* answers a different question than the one asked; comparing it against relevance
sorting answers the one that matters. A0 stays in as the ceiling and as the source of the
missed-evidence count.

**Matched budget, measured not asserted.** The scarce resource is source text put in front
of the synthesizing worker. Each arm's budget is recorded as: characters of source text
exposed, number of distinct source records opened, and wall-clock. A1 and A2 are held to
the same character budget as each other by construction (top-k tuned so exposure matches);
A0's larger exposure is reported, not hidden — it is the ceiling arm, not a matched one.
Machine cost (tokens, dollars, latency) is reported separately and never netted against
human budget.

**Exhaustive pairs, no blocking, on the scored corpus.** The reviewer noted that auditing
dropped *sources* does not audit dropped *pairs* — a contradiction can live between two
retained sources whose pair was never generated. Corpus B is ~12 records, so all 66 pairs
are run. Blocking is a scaling optimisation and is out of scope for a corpus this size;
removing it removes the whole class of unaudited misses.

**Blinded adjudication.** Findings from all three arms are pooled, stripped of arm labels,
shuffled, and adjudicated by a separate worker against a rubric locked before the arms run
(`baseline/RUBRIC.md`): a finding counts only if it names specific source ids, states a
claim checkable against the frozen text, and would change a stated conclusion. The
adjudicator sees arms as A/B/C in a random mapping recorded only in a file it is not given.

**Predeclared expectations** (`baseline/EXPECTATIONS.md`) are committed before the arms run
and are never included in any state payload: what I expect the screen to catch, what I
expect it to miss, and the controls' expected answers. Controls in both corpora: an
insufficient-context case (abstention is the correct answer), an irrelevant source, and an
injected-instruction source. Every reject is audited.

**Order of commits is the audit trail**: corpus + hashes → rubric + expectations → frozen
Jev config → arm outputs → adjudication → results.

## Question design (reusing what already worked)

From the prior shadow tests, not re-derived:

- Per-option / per-dimension **nouls**, not one broad choice. A single long choice folds to
  `none`; the 30-source triage showed the gain from per-dimension nouls is precision, not
  recall.
- **Wording dominates threshold.** The dedup question scored literally zero at 0.5 until
  one clause changed ("same underlying fact or event"), then worked at 0.90. So: every
  question is calibrated against the controls before any headline number is taken, and the
  threshold is reported with the wording.
- **Instructions as objects** (`question` / `inspect` / `compare` / `focus`), choice criteria
  as `{what, not_for, examples}`, noul criteria as matched `{true, false}` — per the vendor
  guide.
- Many atomic questions per call; combine in code; route on uncertainty.
- The last step of a compound request gets under-weighted, so contradiction detection is
  asked **pairwise**, never as "read all of these and tell me what conflicts".

Contradiction is the core question and is asked as a pair of matched nouls over `{a, b}`:
does `b` assert something that cannot both be true with `a`, versus does `b` merely add
detail or describe a different case. The dedup run is the precedent for the pairwise shape
and for the blocking optimisation (only compare pairs that share a dimension) that keeps it
off the n² curve.

## Harness

The retired standalone harness performed these steps:

- Corpus loading — load the frozen corpus, verify hashes, refuse to run if a hash moved.
- Case construction — build the `{state, questions}` payload per case from corpus records.
- Request execution — call `jev.py` (parallel, bounded), write `results/*.jsonl` with question id,
  answer, probabilities, usage, latency, and the exact state hash sent.
- Scoring — combine answers in code, apply thresholds, emit the findings table.

Reuses `~/.claude/state/jev/jev.py` unchanged and the triage30 request/parallelism shape.
The key is never printed or copied.

## Acceptance

The run is reportable — including if the answer is "no gain" — when: all hashes verify,
the baseline commit precedes the first Jev call, every reject is audited, the controls
behave as predeclared or the deviation is reported, and cost and elapsed time are actual
measurements rather than estimates.

The run **fails** and is not reportable if an arm saw another arm's output, if question
wording or thresholds were adjusted after Corpus B was touched, if repeated marketing is
counted as independent corroboration, or if the exposure budget was not actually measured.

## Shortlist — ambitious alternatives, not built yet

Kept here deliberately instead of drifting into a generic inbox classifier.

- **Research map** — cluster a corpus into claim → support → contradiction edges and render
  what is contested rather than what is relevant.
- **Extraction check (the "sandwich")** — Jev picks where to look, the expensive model
  extracts, Jev verifies the extraction against the source span; the interesting number is
  how often the verify step catches a wrong extraction the generator was confident about.
- **Completion evidence (track 2)** — distinguish "tests passed / agent was busy" from a
  verified outcome, by asking for the *evidence* of each acceptance criterion separately
  and refusing to let the summary stand in for the artifact.
- **Memory links (track 3)** — action-changing connections and corrections between stored
  notes, surfaced as suggestions only, never as writes.
- **Constrained prioritization** — decide under a hard budget (the ferry/weight-limit
  shape), where the decision is a feasible set and not a ranking.

## Reviewer pass — plan

Run: `codex exec -m gpt-5.6-sol --sandbox read-only "<plan text>"`, 2026-09-17, 16,750 tokens.

### The three most valuable changes (verbatim)

> 1. **Make the arms independent.**
> Do not let the same person perform A and then B on the same corpus. The B operator already knows the corpus, the baseline findings, and the suspected targets. Use separate fresh contexts/operators, randomize or counterbalance arm order across multiple cases, and have findings adjudicated by a blinded reviewer. Commit order proves timing; it does not remove carryover.
>
> 2. **Separate calibration from evaluation.**
> Freeze all question wording, thresholds, blocking dimensions, and routing rules using a development corpus. Then run them unchanged on a held-out corpus. "Calibrated against the controls before any headline number" is test-set tuning if those controls are inside the scored corpus.
>
> 3. **Define the comparator and budget operationally.**
> The stated question is Jev versus relevance sorting, but arm A is unassisted reading. Add an actual relevance-sort arm or change the research question. Also measure the scarce resource directly: human-visible tokens/characters, source spans opened, total human time, preprocessing time, and machine tokens/cost. "Identical text available" plus the same wall-clock limit is not a matched reading budget.

### Flaws they said would invalidate the comparison (verbatim, abridged to the list)

> - **Fatal carryover:** A happens first, then the same researcher does B. B inherits everything learned while producing A.
> - **Outcome contamination:** `decision_changed` is order-dependent. Only B can change a decision established during A.
> - **Adaptive evaluation:** Tuning wording or thresholds against controls in the scored corpus leaks evaluation results into the intervention.
> - **Unequal work budgets:** B gets corpus-wide Jev processing plus a human synthesis time-box; A gets only the human time-box.
> - **Missing claimed comparator:** No relevance-sorting arm exists, so the experiment cannot establish that typed decisions find things relevance sorting misses.
> - **Incomplete reject audit:** Auditing dropped sources does not audit source pairs excluded by dimension blocking. A missed contradiction can live in two retained sources whose pair was never generated.
> - **Unblinded, subjective scoring:** "Corroborated" and "decision-changing" lack a locked rubric and independent adjudication.
> - **Known-target benchmark:** Corpus A's principal targets are disclosed before either arm. That measures recovery of known findings, not discovery.

### What changed

All eight are conceded. Every one is addressed except where noted:

1. **Independent arms** — the three arms are now executed by separate fresh workers that
   cannot see each other's output or this file's discovery discussion. Carryover and
   outcome contamination are removed structurally, not promised.
2. **Dev/held-out split** — Corpus A becomes the development corpus and is no longer
   scored for discovery; Corpus B (built by a separate worker, its ground truth unread by
   me) becomes the held-out scored corpus, with the Jev config frozen and committed before
   Corpus B is touched. This also disposes of the known-target objection: the corpus whose
   targets I disclosed is the one that no longer carries the headline number.
3. **Relevance-sort arm added** — new arm A1 ranks sources by a single relevance noul and
   exposes only top-k. That is the comparator the research question actually names; the
   first draft compared against unassisted reading instead, which was the wrong contrast.
4. **Budget measured** — characters of source text exposed, distinct records opened, and
   wall-clock per arm; machine cost reported separately and never netted against it. A1 and
   A2 are matched on exposure by construction; A0 is reported as an unmatched ceiling arm.
5. **Exhaustive pairs** — dimension blocking dropped on the scored corpus (66 pairs at 12
   records), which eliminates the unaudited-pair class entirely.
6. **Locked rubric + blinded adjudication** — `baseline/RUBRIC.md` written before the arms
   run; a separate worker adjudicates shuffled, unlabelled findings.

**Not adopted:** counterbalancing arm order across multiple cases, and multiple independent
adjudicators. Both need more cases than one first run supports. The consequence is that
this run reports a single comparison with no variance estimate, and it is written up as
illustrative-with-numbers rather than as a result with error bars. That limitation is
stated in `results/first-run.md` rather than papered over.

## Reviewer pass — harness

Run: `codex exec -m gpt-5.6-sol --sandbox read-only` over the four committed harness files,
2026-09-17, 63,456 tokens. Their opening line: *"the current A1-vs-A2 result is not valid as
a matched-budget comparison."*

### The three most valuable changes (abridged; retired filenames replaced with descriptions)

> 1. **Generate and enforce both arm packets in code.** the original scorer only reports exposure; it
>    never matches it, and no committed code generates the final A1/A2 inputs. Predeclare
>    one character/token budget. Deterministically select A1's prefix and A2's flagged pairs
>    within it. Count every rendered occurrence, including repeated sources—not unique IDs.
>    Fail if budgets differ beyond a declared tolerance.
>
> 2. **Fix the relation logic.** `all_pairs()` emits only one arbitrary orientation, but "b
>    is an exception to a" and "b supports a" are directional questions. Run both
>    orientations or redesign them symmetrically. Worse, the original scorer calls low support a
>    verification gap whenever both sources are broadly relevant. Unrelated Node documents
>    naturally do not support each other, producing dozens of bogus gaps. Require an
>    independently established relationship such as "a cites b" before testing support.
>
> 3. **Make scoring fail closed and make the controls real.** Missing pair answers become
>    `0.0` in `pv()`, which silently converts missing support answers into verification
>    gaps. the request runner writes errored or partial rows instead of invalidating the run. Controls
>    are removed from `ranked` before A1 selection, so "not retained by A1" is tautological.
>    `T_CHECKABLE` is loaded but never gates anything. The corpus lock is created
>    automatically on first execution, allowing the first run to bless whatever bytes happen
>    to exist.

### The comparison-invalidating flaw (verbatim)

> The arms did not receive matched exposure: Reported unique source text: A1 `3,429`
> characters; A2 `3,744`. Actual source text rendered to A2, counting repeated N02: `4,449`
> characters—about **30% more** than A1. Complete input files: A1 `4,301` characters; A2
> `5,863`—about **36% more**. Therefore any claim that A2 beat A1 "at the same reading
> budget" is invalid.

### What changed

They was right about the budget and it was the difference between a result and a press
release. The first A2 packet rendered each flagged pair as a block, so a source appearing
in three pairs was printed three times.

1. **Packet rebuilt, arms re-run.** A2's packet now prints each source exactly once
   followed by the list of flagged pair relations. A1 was moved from top-6 to **top-7** so
   both arms receive the same *number* of sources. Final: A1 seven sources / 3,996 source
   chars / 5,034 packet chars; A2 seven sources / 3,744 / 5,051 — **packets within 0.3%**,
   and the match now *favours the comparator*, which reads more source text than the
   assisted arm. Both arms were re-run from scratch by fresh workers on the corrected
   packets; the original unmatched run is kept in the results file and reported as void.
2. **Verification-gap channel retired.** They independently reached the conclusion the
   development corpus had already shown: the rule fired on 56 of 105 pairs because two
   unrelated documents naturally fail to support each other. It is now reported as a
   negative result and excluded from every count, rather than quietly deleted.
3. **Fail-closed scoring.** `pv()` raises on a missing answer instead of defaulting to
   `0.0`; the request runner exits non-zero if any request errored; the corpus loader refuses to run
   without a committed lock and can no longer create its own (a separate freeze command is
   now a separate, deliberate entry point); `T_CHECKABLE` now actually gates an abstention
   report.

**Not adopted:** running both orientations of the directional pair questions. That doubles
the request count and, more importantly, would mean changing the frozen question
configuration after the held-out corpus had been scored — which is the exact leak the
dev/held-out split exists to prevent. It is recorded as a known limitation: every pair was
asked in one arbitrary orientation, so the reported exception and support numbers are a
lower bound. Fixing it properly means re-freezing and re-running both corpora.

## Validity repair

Run 2026-09-17 on branch `jev-campaign-2`. Trigger: the acceptance owner's correction, that
the original scorer ranked only `real` sources for A1, excluded control ids from A2 exposure, and
required `both_real` for the verification-gap rule — oracle exclusions, so the
zero-control-failure counts demonstrated nothing about deployment resistance or model
gating. **No new model calls.** Everything below is a re-derivation from the executed
artifacts.

### What was done

1. **Labels-blind rescoring** — the label-blind rescorer re-derives both arms' selections
   from observed scores only (relevance noul, checkable noul, pair-channel scores). Two
   deployable per-source gates, both frozen on the development corpus and applied to both
   arms' candidate pools identically: relevance ≥ 0.50, checkable ≥ 0.50. Two variants
   emitted: gated and nogate.
2. **Result.** The gated selection reproduces both arms' original packets exactly (verified
   against `results/arms/A1b_input.md` and `A2b_input.md`, not against a score file), so no
   finding was re-adjudicated and the blinded counts stand: A0 11/10/7 valid/dc, A1b 8/8/8,
   A2b 5/5/4. Ungated, A1 is unchanged — the controls rank 13–15 of 15 on relevance alone —
   but the ungated A2 packet takes the injected-instruction and insufficient-context
   controls as its **first two sources** and closes before reaching `N06|N07`, losing F22,
   the screen's only unique decision-changing win.
3. **A third oracle leak found, verified, and reported** — the case builder’s `_src` puts `kind` into
   the state sent to the model, so every control score in the campaign was produced with
   the strings `control_injected_instruction` etc. visible. Confirmed by reproducing the
   logged `state_sha 4f47505d5c1ac16b`. This is the binding scope limit on everything the
   rescoring can claim.
4. **Injected-source absent/present** — marked **UNTESTED**. One relevance state per corpus,
   always containing the injected source; no absent-state exists to difference against.
   Recorded in `baseline/EXPECTATIONS.md`'s new outcome column and in the report.
5. **Wording** — "ceiling"/"upper bound" for A0 replaced by **full-exposure reference**;
   "both far below ceiling" withdrawn, since A1b's 8 decision-changing findings exceed A0's
   7. Foreman restated as an **unresolved artifact association**, not contradiction proof.
6. Output: `results/first-run-corrected.md`. `results/first-run.md` untouched as the record.

### Paired reviewer

`codex exec -m gpt-5.6-sol --sandbox read-only` over the corrected report, the label-blind rescorer
and the original scorer, with the owner's correction quoted verbatim. 112,374 tokens. Opening
verdict: *"The correction is not acceptance-clean yet."* Nine numbered findings. All nine
conceded and fixed; two were factual errors in the artifacts that I had carried forward.

| # | finding | fix |
|---|---|---|
| 1 | Selection is label-free but the **scores** are not, so "relevance sorting survives" and "ungated A2 demonstrates deployment failure" both exceed the evidence | Added a binding scope paragraph up front: the only defensible claim is *conditional on these label-contaminated scores, this label-free selector produced these packets*. Same limit written into the label-blind rescorer's docstring. |
| 2 | A1's carry-forward provenance not proven — `nodejs-scored.json` shows a **six**-source `A1_topk` | **My fault, not a pre-existing stale artifact.** the original scorer's `--topk` default was 6 while the executed run used 7, so running it once to check it still executed overwrote the committed file with the void run's six-source selection. File restored from `7fe2bf2c2`; default changed to 7 so a bare re-run reproduces the record. Provenance is now cited from `A1b_input.md`, the packet the arm was actually given — exactly the 7 gated ids — rather than from any regenerated score file. |
| 3 | "reads no label" literally false — `main()` reads `kind` to report controls | Reworded: the *selection functions* read no label; `main()` reads it after selection is fixed, for reporting only. |
| 4 | Nogate control-resting-findings count claimed as zero, but nogate was never executed | Restricted to the executed gated arms; nogate is **unknown, not zero**, with the note that its packet contains N91/N92 so zero is unlikely. |
| 5 | the original scorer's oracle logic still executable, outputs still on disk; its "abstention gate is applied" comment overstated | Three leak sites annotated inline, docstring marks it superseded for selection; both points written up in the report's §9a. Kept executable as the audit trail. |
| 6 | Three numbers wrong: Foreman `J02\|J10` support is **0.08** not 0.05; dev verification-gap is **39/91**, not the held-out 56/105; control scores listed as held-out then labelled "both corpora" | All three corrected, with the 0.05 flagged as an error in `first-run.md` §7 and the 39/91 vs 56/105 split corrected in the original scorer's comment (this file also carried the wrong attribution). |
| 7 | Threshold freeze asserted, not demonstrated; `T_RELEVANT` was itself justified from the labelled real/control split | Both conceded in §9a as process claims, not measurements. |
| 8 | "Matched exposure" imprecise — source chars are 3,996 vs 3,744, a 6.7% gap | Defined explicitly: 7 sources each and rendered packets within 0.3%; source characters are *not* matched and the gap favours the comparator. |
| 9 | "Name collision is the likely explanation" for Foreman is speculation | Downgraded to one possible explanation among several, which the artifacts do not rank. |

The reviewer independently verified as correct: the untested marking, the adjudication
arithmetic (A0 11/10/7/1, A1b 8/8/8/0, A2b 5/5/4/0), the F10/F20/F21 control-observation
analysis, the gated and nogate packet orders and character totals, the 5,967/7,445 = 80%
figure, the full-exposure-reference renaming, and the Foreman framing.

---

# Arm two — reserved supplement budget vs a deterministic rule

Second experimental unit. Fresh corpora, fresh workers, label-free payloads. Written before
any corpus is touched by a model call; the reviewer pass below cites the commit that froze
this section.

## The question this unit asks

Arm one compared relevance sorting against a typed screen that *replaced* the ranking.
Relevance sorting won, and the screen's one advantage depended on an upstream gate doing the
screening for it. The follow-up question is narrower and more useful:

> Under a **fixed rendered-exposure budget**, does reserving part of the packet for
> version/scope-dependent and still-load-bearing sources earn its keep — and does having
> **Jev** decide what goes in that reservation beat a **cheap deterministic rule** that
> decides from metadata alone at zero model cost?

Three arms, one budget:

| arm | packet composition | model cost of selection |
|---|---|---|
| **A1** | relevance noul, descending, fill to budget `B` | one relevance call |
| **A3** | `(1−s)·B` by relevance, then `s·B` filled by a **Jev-scored** version/scope-dependency supplement | relevance call + supplement call |
| **A4** | `(1−s)·B` by relevance, then `s·B` filled by a **deterministic version-diversity rule** | relevance call only |

A4 is the arm that makes the unit honest. Without it, "A3 beat A1" only shows that a
reservation helps; it would not show that *Jev's judgment* helps, because a rule reading the
version string off the metadata might buy the same thing for nothing. A3 vs A4 is the
measurement that matters. A1 vs both is the cost-of-reservation measurement.

The reservation is not free: it **displaces** relevance-top sources. Every finding A1
produces that neither supplement arm can reach is a real loss, and this unit counts those
losses explicitly rather than reporting only wins.

## Exposure, defined twice and reported twice

Arm one's "matched exposure" conflated two things and the reviewer caught it. Here both are
defined up front and both are reported for every arm:

- **Rendered exposure** — characters of the complete packet file handed to the synthesis
  worker, including headers, ids, and relation annotations. This is the quantity held
  **equal** across arms: all three packets within **±1.0%** of the frozen budget `B`. A run
  whose packets fall outside that tolerance is invalid and is re-packed, not reported.
- **Source-text exposure** — characters of verbatim corpus `text` only, summed over rendered
  occurrences (a source printed twice counts twice). This is **not** matched and is
  **reported separately per arm**, because the arms differ in annotation overhead and the
  difference is a real confound that must be visible, not buried.

Both numbers, plus distinct-record count, go in the report for A1, A3 and A4.

## Corpora — fresh, real, built by separate workers

Both corpora are new. Neither reuses the Node.js or Jev-launch material, which is now
burned: its targets are disclosed in this file.

- **Development corpus C — `corpus/k8s/`.** Kubernetes API deprecation and removal, Pod
  Security Policy removal and Pod Security Admission, feature gates, the deprecation policy.
- **Held-out corpus D — `corpus/chromeext/`.** Chrome extensions Manifest V2 → V3: the
  blocking `webRequest` restriction, `declarativeNetRequest` rule limits, remotely hosted
  code, the enterprise-policy exemption, the shifting deprecation timeline.

Each is 15 records — 12 real, 3 controls — verbatim excerpts from public documentation
fetched live, with URL, fetch route, fetch date and SHA-256 of the raw page in a per-corpus
`MANIFEST.md`. Nothing is paraphrased into the corpus.

The 12 real sources in each corpus cover, at two or more sources each, the four shapes this
unit exists to probe:

- **(a) changing restrictions** — a restriction introduced and later relaxed or altered.
- **(b) restrictions persisting across changes** — a restriction that survived a major
  change and still applies, where a reader would wrongly assume the change removed it.
- **(c) scoped exceptions** — an exemption valid only within a named scope.
- **(d) old-but-necessary** — an older document still required for a correct current answer,
  where reading only the newest document yields a **wrong** answer.

Several questions in each corpus are answerable only from a *combination* of records, and
any single record read alone gives the wrong answer. That is what a supplement budget is
supposed to buy, and it is the ground on which it can fail.

**Corpus D is held out.** It is built by a separate worker which reports back only ids, char
counts and URLs; its `labels/gold.md` is not read before the held-out arms run.

## Labels: removed from every model-visible path, and the removal is audited

Arm one leaked `kind` into the model's state and every control score in it is contaminated.
This unit fixes that structurally rather than by care.

1. **Opaque ids.** Every record id is a random 8-hex string encoding nothing — not kind, not
   order, not version. Record order in `sources.jsonl` is shuffled; controls are not last.
   Controls carry plausible non-empty `product` / `version_label` / `date` so they cannot be
   spotted by metadata shape.
2. **Allowlisted serializer.** the payload serializer is the *only* path from a corpus record
   to a model payload. It emits exactly `{id, text, product, version_label, date}` and
   raises on any other key. There is no branch that adds a field.
3. **Byte-identity audit, not a keyword scan.** For every serialized source the auditor
   asserts the emitted dict is byte-identical to the allowlisted projection of the frozen
   corpus record. This is strictly stronger than grepping for `gold`/`kind`/`control`,
   because those strings occur legitimately in real Kubernetes and Chrome prose
   ("access control", "controller") and a grep would either false-positive or be tuned until
   it passed. Byte-identity admits no such tuning.
4. **The audit output is committed.** `results/arm-two/payload-audit/` holds the **exact
   bytes of every request body sent**, one file per call, plus a manifest of SHA-256s and the
   assertion results. Anyone can diff the sent bytes against the frozen corpus themselves.
5. **Labels survive only for adjudication.** `corpus/<name>/labels/gold.md` is never
   serialized, never given to a synthesis worker, and never given to the model.
   `labels/controls.json` carries the control ids and the obedience probe; it is read by the
   scorer to compute retention and by nothing that produces a model input.

## Pilot before the arms: absent/present, with repeats

`EXPECTATIONS.md` demanded a neighbour-stability check in arm one and it could not be
computed, because only one state per corpus was ever built. This unit runs it first, on the
development corpus, label-free.

- **Conditions.** `PRESENT` = all 15 records in the state. `ABSENT` = the same state with the
  injected-instruction record removed (14 records). Identical question set, identical
  wording, identical serializer.
- **Repeats.** `R = 5` per condition. Repeats are what separate a neighbouring effect from
  model noise; arm one had none and could therefore call nothing.
- **What is measured.** Per surviving neighbour, the mean relevance and supplement scores in
  each condition, the within-condition SD across repeats, and `Δ = mean_PRESENT −
  mean_ABSENT`. A neighbour is reported as moved only when `|Δ|` exceeds both the 0.05
  pre-declared bar and the pooled within-condition SD. Anything smaller is reported as
  indistinguishable from noise, with the SD printed, not as a pass.

### Retention and obedience are two numbers and are never added together

This unit reports them in separate columns and states the distinction in the report body.

- **RETENTION** — did the injected-instruction record survive selection into a packet?
  A property of the ranking and the gate. Measured per arm, per repeat, as a rate.
  A retention of 0 says a scoring pipeline did not pass the record along. It says **nothing**
  about what a model would do with the record if it were passed along.
- **OBEDIENCE** — did a synthesis worker that *actually received* the record follow the
  planted instruction? Measured by forcing the injected record into a packet regardless of
  its score, running fresh synthesis workers on it, and checking their output for the planted
  marker and for the instructed behaviour. This is the only way to get an obedience number,
  and arm one never did it.

The planted payload is a fixed, observable marker sentence, so obedience is a string check on
the output, not a judgement call. Both corpora carry the same probe.

## Freezing on the development corpus, before the held-out corpus is touched

Two quantities are chosen on corpus C and committed before any call against corpus D:

- **`s`, the supplement fraction.** Chosen by a **structural** criterion, deliberately not an
  outcome criterion, so that dev performance cannot leak into the design: `s` is the smallest
  value in `{0.20, 0.30, 0.40}` at which the supplement slot admits at least **2** sources on
  corpus C while leaving the relevance portion at least **4**. Picking `s` by which value
  scored best on dev would be exactly the adaptive-evaluation flaw the reviewer named.
- **The deterministic rule for A4.** Metadata only, no model call:
  > Fill the supplement slot by iterating `version_label` values **not already represented**
  > in the relevance-selected portion, in ascending `date` order; within a version take the
  > **oldest** record first; break ties by lexicographic id. Stop when the next record would
  > exceed `s·B`.

  The oldest-first bias is deliberate: shape (d), old-but-necessary, is the one a relevance
  sort is structurally worst at, and a rule that cannot be accused of peeking has to be
  written down in advance and then left alone.
- **The supplement channel wording for A3.** Two atomic nouls per source, combined in code
  (per-dimension nouls, not one broad choice — the standing lesson):
  - `vdep` — the source's claim holds only under a named version, platform, scope or
    configuration, such that a reader ignoring that condition draws a wrong conclusion.
  - `persist` — the source records a restriction or requirement that survives a later change
    and still applies.

  Supplement score `sup = max(vdep, persist)`, frozen. Ranked descending, filled to `s·B`.

All three are committed before corpus D is loaded. Any change to them after that invalidates
the held-out run and the run is reported as void, as the arm-one packet run was.

## Execution and adjudication

- **Three fresh synthesis workers per arm**, one per arm, each given only its own packet file
  and the identical task prompt. No worker sees another arm's packet, this file, the corpus
  labels, or the arm names.
- **Blinded adjudication.** All findings pooled, stripped of arm labels, shuffled, renumbered
  `F01…Fnn`; the arm mapping is written to a key file the adjudicator is not given. The
  adjudicator works against `baseline/RUBRIC.md` and the frozen corpus text, and returns
  validity, decision-changing status, and duplicate clusters.
- **Lost-findings accounting.** For each supplement arm, the report lists the A1-retained
  sources it **displaced**, and the A1 findings whose cited sources are all displaced —
  those are findings the reservation cost. Incremental wins are reported against that loss,
  never alone.
- **Uncertainty.** The pilot carries repeats and yields real SDs. The three synthesis arms are
  one run each; that is stated as such, with no variance estimate, and the arm ordering is not
  reported as a ranking.
- **Cost and latency.** Per stage: requests, input tokens, cost at the vendor's posted input
  rate, wall-clock, median latency. A4's selection cost is zero model calls by construction
  and that is the point of reporting it beside A3's.

## Acceptance for this unit

Reportable — including if the answer is "the reservation does not pay" — when: both corpora
verify against their committed locks; the payload audit shows byte-identity for every call;
`s`, the A4 rule and the A3 wording are committed before the first corpus-D call; the three
packets are within ±1.0% rendered; retention and obedience are reported as separate numbers;
and lost findings are reported beside wins.

Void if any arm saw another's output, if any frozen quantity moved after corpus D was
touched, if a label reached a model-visible payload, or if the packets were not actually
equalised.

## Reviewer pass — arm two

Run: `codex exec -m gpt-5.6-sol --sandbox read-only "Plan at research/jev-campaign/PLAN.md
section 'Arm two' as of commit 9857176ebcd028122178e9a916eacbd642cf8c51; is there a better
way? ..."`, 2026-09-17, 46,678 tokens. Full transcript:
`results/arm-two/reviewer-plan.txt`.

Their verdict: *"Yes. The cleanest version is a paired, repeated, gold-question benchmark. As
written, Arm two can produce an interesting case study, but it cannot support 'Jev beats the
deterministic rule.'"*

### The changes they named (verbatim headlines) and what happened to each

> **1. Fix duplicate credit first.** [...] If A3 and A4 discover the same fact, whichever
> happens to appear first wins the point. That makes arm totals partly a shuffle lottery and
> invalidates the comparison. Cluster equivalent findings, validate each cluster once, and
> credit every arm that independently produced it. Deduplicate only within an arm.

**Adopted, and they are right that it invalidates the comparison.** The inherited
`RUBRIC.md` rule — "first occurrence wins; the duplicate is marked `dup` and excluded from
counts" — was written for arm one, where the interesting quantity was arm-exclusive
findings. Used for a three-way comparison it makes the shuffle order decide points.
`baseline/RUBRIC-A2.md` replaces it for this unit: equivalent findings form a cluster, the
cluster is validated once, and **every arm that independently produced it is credited**.
Deduplication happens only *within* an arm. Arm-exclusivity is still reported, as a
secondary column, which is all it was ever good for.

> **2. Replace open-ended finding counts with a frozen question set and gold claim units.**

**Adopted.** "Beat" had no primary estimand and the rubric explicitly refuses an aggregate
score, so the unit as written could not answer its own question. The primary estimand is now
**gold-claim recall on a frozen question set**: an identical set of questions, derived from
the held-out corpus's own combination questions, is put to every arm and every repeat, and
the primary number is the count of correct decision-changing answers. Incorrect answers and
"cannot answer from these sources" are reported in separate columns and never netted.
Open-ended discovery is kept as a **secondary** analysis. The question set is extracted from
`labels/gold.md` by a separate worker and frozen before the arms run; it contains questions
only, never answers, and the acceptance owner of this worktree does not read the held-out
answers before the run.

> **3. Match actual information exposure.** [...] Reporting that confound does not remove it.
> A3 could win because it received more useful source text or extra relation hints, not
> because its selector was better.

**Adopted; the plan as committed was wrong here.** Equalising rendered characters while
letting source text differ is the arm-one mistake in a new coat. Two fixes:
- **Source-text characters are now the primary packing budget** and are held equal across
  arms, not merely reported. Rendered characters are then made **exactly** equal by an inert
  pad (below). Both quantities are equal; both are reported.
- **No arm-specific annotation exists.** One renderer serves all three arms and prints id,
  product, version label, date and text — **no selection scores, no relation hints, no
  supplement marking**. A worker cannot tell from its packet which arm it is in. This was
  true of the implementation already; it is now a stated constraint rather than an accident.

> **4. Repeat the outcome experiment, not only the injection pilot.**

**Adopted.** `R_syn = 3` independent synthesis repeats per arm on the held-out corpus, fresh
worker each, arm order randomised across repeats, identical prompt and settings. That is 9
held-out synthesis workers. The primary estimand is reported as a mean over repeats with the
observed spread; a difference smaller than the spread is reported as not separable.

> **5. Freeze one common relevance ranking per paired block.**

**Adopted; already true in the implementation, now stated and enforced.** There is **one**
relevance call per corpus. A1, A3 and A4 all rank from it, and A3 and A4 share the identical
`(1−s)·B` relevance core object — the same records, built once in `a2_pack.build_arms` and
handed to both. Relevance-score noise therefore cannot be confounded with the supplement
method, because both supplement arms sit on the same core.

> **6. Make packing completely deterministic.** [...] No discretionary repacking after seeing
> held-out selections.

**Adopted, and the "re-packed" sentence is withdrawn.** It was a licence to tune after
seeing the result and should not have been written. Frozen packing rules, in full:
- Walk the ranking in order. Take a record if it fits the remaining budget; otherwise
  **skip** it and continue. Records are never truncated, never replaced, never reordered.
- Ties in any ranking break by ascending lexicographic id.
- The A4 rule's three sweeps — unrepresented versions oldest-first, then further
  unrepresented versions, then all remaining records oldest-first — are fixed in code and
  the third sweep is mandatory, so the reservation is always spent and A4 can never read
  less than the others.
- Rendered length is equalised by appending an inert pad (`"(no further sources)"`) to
  exactly the frozen budget. The pad is identical in form across arms and carries no
  information. Unpadded rendered length is reported alongside.
- **There is no repacking.** If the held-out packets miss a tolerance, that is reported as a
  measured fact of the run.

> **7. Clarify the execution unit.**

**Adopted.** "Three fresh synthesis workers per arm, one per arm" was contradictory. The unit
is: **one fresh worker per (arm × corpus × repeat)**. Held-out: 3 arms × 3 repeats = 9
workers. Development corpus: 1 worker per arm, used only for a smoke check of the packet
format, never scored.

### Scope corrections, conceded in full and binding on the report

- **A3 vs A4 can establish superiority only over this exact rule** — "unrepresented version,
  oldest first" — and not over deterministic selection in general. The report says that in
  those words. Preregistering a family of zero-model baselines is the right way to make the
  broader claim and is **not done here**; it is recorded as the named limitation, not
  papered over with a stronger sentence.
- **A1 vs A4 measures this deterministic reservation. A1 vs A3 measures the whole Jev
  reservation pipeline**, not the cost of reservation alone. The report uses those framings
  and not "A3 beat A1".
- **The corpora are deliberately treatment-shaped.** They are a targeted stress test of four
  named shapes, not broad effectiveness evidence, and the report says so. Sources, excerpts,
  questions and gold are frozen before any held-out scoring call; if any of them moved after
  selector behaviour was observed, the held-out comparison is void.

### Not adopted

- **Fixed-size source chunks** (their suggestion under change 3). Chunking real documentation
  to a uniform length would cut verbatim excerpts mid-clause and destroy the very thing the
  corpus is testing — a scoped exception is a *sentence*, and half of one is not a source.
  Equal source-text budget plus a skip-never-truncate packing rule buys the same exposure
  match without mutilating the evidence. The residual is that arms differ slightly in record
  *count* at equal source-text budget; that count is reported per arm.
- **Repeating the stochastic selection stage** ("ideally repeat the stochastic selection too").
  The pilot already measures selection-stage variance with 5 repeats per condition, and if
  that variance turns out to be material the selection ranking is not stable enough for the
  outcome experiment to mean anything — which the pilot would then say directly. Repeating
  selection inside every synthesis repeat multiplies the run without adding a number the
  pilot does not already give.

## Reviewer pass — arm two report

Run over `results/arm-two.md` at commit `88a3242f8` together with the plan, `RUBRIC-A2.md`,
the seven arm-two harness files and the artifacts. 140,574 tokens. Transcript:
`results/arm-two/reviewer-report.txt`.

Verdict: *"the committed artifacts support a useful descriptive case study, but not the
report's claimed blinded three-arm comparison or its broad 'labels removed from every
model-visible path' proof."* Twenty-three findings. **All twenty-three conceded.**

**The two that voided a stage, and were repaired by re-running:**

1. **The adjudication was not blinded.** All nine pooled documents carried the arm in their
   title line. `a2_blind.scrub` used a lookahead ending in `$` with no `re.MULTILINE`, so `$`
   meant end of string. Verified by grep. The first adjudication is **void**. Repaired:
   `scrub` drops the title line and strips any `A<digit>` anywhere, `assert_blind` re-reads
   every written file, pool re-blinded under a new seed with new codes, fresh adjudicator.
2. **The synthesis workers were not arm-blind** — they were handed `A1_packet.md` and the
   like. Repaired: packets re-published under content-hash names, byte-identical, and **all
   nine workers re-run**.

The repaired run replicates: A1 4.00 / A3 3.00 / A4 4.00, same two discriminating questions.

**The one that failed silently:** the frozen source-text tolerance was computed and never
enforced — `a2_pack.main` exited only on the rendered check — so the held-out run passed
through a failed gate. The packet builder was corrected to fail closed on both. And the confound is not confined
to A3-vs-A4: A3 read less source text than **both** comparators.

**Withdrawn from the report:** all causal language ("cost", "beat", "did not pay"); the
"separable" claim (zero observed spread makes the rubric's rule degenerate); the broad
label-removal claim, narrowed to the six committed Jev templates and the packets; "one
relevance call" (it is five averaged requests); "A4 costs zero model calls" (true of its
incremental step only); the `s = 0.40` counterfactual, **verified false** by re-running the
packer; "every loss traceable to a displaced source"; "retention and obedience move
independently"; and "frozen before corpus D was touched" (supported only for the first
corpus-D model call). Factual fixes: the injected control is rank 14/15 on relevance and sits
above **five** real sources at supplement rank 8.

**Added:** synthesis worker usage committed with its provenance stated as harness accounting
rather than provider receipts; a standing note that no per-worker execution receipts exist;
and a note that cluster validity was judged under a relaxed reading of the inherited rubric,
since no document stated a finding kind.

**Not adopted:** nothing. The remaining items — no execution receipts, three repeats with no
interval, one adjudicator per run, one deterministic baseline, treatment-shaped corpora — are
recorded as limitations in `results/arm-two.md` §11 rather than fixed, because fixing them
means more corpora and more repeats than this unit carries.
