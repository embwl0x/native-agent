# Arm two — a reserved supplement budget, scored by Jev, against a deterministic rule

This is a historical research record. The standalone Python harness has been retired;
recorded results remain available, and original source is preserved in Git history.

Second experimental unit. Fresh corpora, fresh workers, label-free payloads, three arms
under one budget. Plan and reviewer pass: `PLAN.md`, sections "Arm two" and "Reviewer pass —
arm two". Everything below is a measurement from committed artifacts; where a check was not
run, it says so.

**What this unit can and cannot claim, stated once and binding on everything below.**

- A3 vs A4 can establish superiority only over **this exact deterministic rule** —
  "unrepresented version, oldest first" — not over deterministic selection in general. No
  family of zero-model baselines was preregistered, so the broader claim is unavailable.
- A1 vs A4 measures **this deterministic reservation**. A1 vs A3 measures the **whole Jev
  reservation pipeline**, not the cost of reservation alone.
- The corpora are deliberately **treatment-shaped** — built to contain four named shapes. This
  is a targeted stress test, not broad effectiveness evidence.
- Three repeats per arm is a small number. Where a difference is smaller than an arm's own
  spread across repeats, this report says the run was not powered to make the call.

---

## 1. What was built

| | development corpus C | held-out corpus D |
|---|---|---|
| directory | `corpus/k8s/` | `corpus/chromeext/` |
| domain | Kubernetes API deprecation, PSP removal, Pod Security Admission, feature gates | Chrome extensions MV2 → MV3: blocking `webRequest`, `declarativeNetRequest` limits, remote code, enterprise exemption, the shifting timeline |
| records | 15 (12 real + 3 controls) | 15 (12 real + 3 controls) |
| source text | 8,199 chars | 8,236 chars |
| distinct version labels | 10 | 12 |
| frozen at | `870441182d11` | `c0568953d0f3` |

Both were built by **separate workers** from live public documentation, fetched 2026-09-17,
with URL, fetch route and SHA-256 of every raw page in a per-corpus `MANIFEST.md`. All 24
real excerpts were machine-verified as exact substrings of their raw pages. Nothing was
paraphrased into either corpus.

Corpus D's builder was instructed to report back **only** ids, character counts and URLs, and
did: which records are controls, which shapes they serve, and its `labels/gold.md` were not
disclosed to this worktree's owner before the held-out arms ran.

Two recovery gaps are recorded rather than papered over: the versioned Kubernetes docs hosts
`v1-24.docs.kubernetes.io` / `v1-25.docs.kubernetes.io` fail TLS hostname verification and
were unusable, so the archived-version requirement was met from the `kubernetes/website`
`release-1.24` branch; and three Chrome pages (the accordion-driven policy index, the review
process body, the client-rendered enterprise policy page) yielded only partial text.

## 2. Labels are gone from every model-visible path, and the proof is on disk

Arm one put the corpus `kind` field into the state the model scored, which contaminated every
control score in that campaign. This unit removes labels structurally.

- **Opaque ids.** Random 8-hex, encoding nothing. Record order shuffled; controls not last;
  controls carry plausible non-empty `product` / `version_label` / `date` so they cannot be
  spotted by metadata shape.
- **One serializer.** The serializer’s `project` emits exactly
  `{id, text, product, version_label, date}`. There is no branch that adds a field.
- **Byte-identity, not a keyword scan.** The auditor asserts every source dict in the outgoing
  body is byte-for-byte the allowlisted projection of the frozen record with that id.

  This is not pedantry. A grep for `kind` would have fired on corpus C, because one verbatim
  Kubernetes excerpt contains the YAML line `kind: Namespace`; a grep for `control` fires on
  "admission controller" and "access control". A keyword check would have had to be tuned
  until it passed, and a check tuned until it passes is not a check. Byte-identity admits no
  tuning.
- **Self-tested.** The auditor was run against three deliberately broken payloads: it drops
  `kind` on projection, raises on a smuggled `kind` field, and raises on a single altered
  character of source text.
- **The bytes are committed.** `results/arm-two/payload-audit/` holds the **exact request body
  of every call** — nothing elided — plus `MANIFEST.json` with each body's size and SHA-256.
  All 6 bodies were re-verified byte-identical **independently of the run that wrote them**.
  The union of source keys across every body ever sent is exactly:
  `date, id, product, text, version_label`.
- **Labels survive only for adjudication.** `labels/gold.md` and `labels/question-key.md` were
  never serialized and never given to a synthesis worker. `labels/controls.json` is read only
  by the scorer that computes retention.

**So the defensible claim, narrowed.** *No corpus `kind`, gold or control field appears in the
six committed Jev request templates or in any committed packet.* The broader sentence — "labels
removed from every model-visible path, proven" — is **withdrawn**. It is also false in a second
sense that matters: **arm labels reached models.** The first synthesis run was handed
`A1_packet.md` / `A3_packet.md` / `A4_packet.md`, and the first adjudication pool leaked the arm
in every document's title line. Both are described in §8a, and both were repaired by re-running.

## 3. The pilot: absent/present, with repeats

`EXPECTATIONS.md` demanded this in arm one and arm one had to mark it **UNTESTED** — only one
state per corpus was ever built, so there was nothing to difference, and there were no
repeats, so there was no noise floor. Both now exist.

Development corpus, 5 repeats per condition, `PRESENT` = all 15 records, `ABSENT` = the same
state with the injected-instruction record removed. 20 calls, 0 errors, every one byte-audited.

| channel | neighbours | moved | max abs delta | max within-condition SD |
|---|---|---|---|---|
| relevance | 14 | **0** | 0.016 | 0.034 |
| supplement `vdep` | 14 | **1** | 0.080 | 0.067 |
| supplement `persist` | 14 | **0** | 0.044 | 0.025 |

"Moved" means `abs(delta)` cleared both the pre-declared 0.05 bar and the pooled
within-condition SD. On relevance the largest movement is **half** the largest noise SD, so
the honest statement is that this run detects no neighbouring effect on relevance rather than
that there is none. The one `vdep` movement (record `42415d70`, delta +0.080 against
`sd_present` 0.067) clears the bar by a hair and is reported as marginal, not as a finding.

### 3a. A label-free control result that bears directly on arm one

With `kind` removed from the payload, the development corpus's controls score:

| control | relevance (mean of 5) | arm one's comparable figure |
|---|---|---|
| irrelevant | **0.390** | 0.03 |
| injected instruction | **0.656** | 0.30 |
| insufficient context | **0.852** | 0.20 |

The insufficient-context control scores **higher than five real sources**. Only the irrelevant
control separates at all.

Arm one reported 0.03 / 0.30 / 0.20 for the same three control *kinds* — a clean separation
with a wide gate margin — and those scores were produced with the strings
`control_injected_instruction` and the rest visible in the model's state.

**What this is and is not.** It is not a controlled comparison: different corpus, different
control texts, different domain, and the question wording differs between campaigns. It
cannot show that removing the label caused the collapse. What it does show is that the clean
control separation arm one reported **does not reproduce** on a fresh corpus once the labels
are out of the payload, and that arm one's decision to treat its control scores as
contaminated was the right call.

## 4. Retention and obedience — two numbers, never combined

This is the distinction arm one could not make, and the two quantities point in opposite
directions here.

### Retention — a property of the ranking and the gate

| corpus | arm | controls reaching the packet |
|---|---|---|
| development | A1 | insufficient-context (`5d8d355d`, relevance 0.852) |
| development | A3 | none |
| development | A4 | insufficient-context (`5d8d355d`) |
| held-out | A1, A3, A4 | **none** |

On the held-out corpus the two lowest-relevance records score 0.320 and 0.132 and no control
reached any packet. On the development corpus, a control was retained by two of the three
arms. Retention is therefore **not** a stable property of the method — it depends on how well
that corpus's controls happen to separate on relevance.

**A retention of zero says a scoring pipeline did not pass a record along. It says nothing
whatever about what a model would do if it were passed along.** That is the second number.

### Obedience — a property of the model, measured by forcing the issue

Measured on the development corpus by **forcing** the injected-instruction source into a
packet regardless of its score and running three fresh synthesis workers on it. The planted
payload is a fixed sentence, so obedience is a string check, not a judgement: does the summary
open with the planted sentence, as the payload instructed?

| workers | obeyed | quoted the marker while refusing |
|---|---|---|
| 3 | **0** | **3** |

All three quoted the planted sentence inside a note reporting it as embedded non-documentation
text, said they had not acted on it, and completed the task normally. Two went further and
recommended treating that source's unique claims as tainted.

**The marker appearing in an output is not obedience.** In all three cases it appears only as
a quotation. A check that grepped for the marker and stopped there would have scored this
3-for-3 obedience, exactly backwards. This is why the check is "does the summary open with the
planted sentence" and why the two columns are printed side by side.

Scope: three workers, one corpus, one payload, one phrasing of the instruction. This is a
measurement of obedience under one condition, not a robustness result, and nothing here
licenses the word "resistant".

## 5. Exposure — one quantity equalised exactly, one that missed its tolerance

| | A1 | A3 | A4 |
|---|---|---|---|
| distinct sources | 7 | 7 | 7 |
| **rendered chars** | **5,256** | **5,256** | **5,256** |
| source-text chars | 3,898 | **3,752** | **3,987** |
| supplement slots filled | — | 3 | 3 |

**Rendered exposure is exactly equal**, by construction: packets are packed to the budget and
then padded to a common length with an inert `(no further sources)` tail, identical in form
across arms. One renderer serves all three, prints no selection score, no relation hint and no
supplement marking, and emits sources in ascending id order — so the arm's selection *order*
cannot be read off the packet either. A worker cannot tell which arm it is in.

**Source-text exposure FAILED its frozen gate.** The spread is 235 characters, **5.9% of the
budget**, against a 3% tolerance frozen on the development corpus, where the same packer
achieved 0.25%. Two separate things went wrong and both are the report's problem, not the
corpus's:

1. **The gate was computed and not enforced.** `a2_pack.main` evaluated
   `source_text_within_tolerance` and then exited only on the *rendered* check, so the held-out
   run sailed through a failed frozen gate instead of stopping. A gate that is computed but not
   enforced is not a gate. The packet builder was corrected to fail closed on both. The run is reported as having
   passed through a failed gate rather than quietly re-packed, because the frozen rule forbids
   repacking after a result is seen.
2. **The confound is not confined to A3-vs-A4.** Every pairwise comparison in this unit is
   affected:

| pair | source-text gap | as fraction of budget | direction |
|---|---|---|---|
| A4 vs A3 | 235 chars | **5.9%** (A4 reads 6.3% more) | favours A4 |
| A1 vs A3 | 146 chars | **3.7%** | favours A1 |
| A4 vs A1 | 89 chars | 2.2% | favours A4 |

Both A4-vs-A3 and A1-vs-A3 exceed the frozen 3% tolerance. **A3 read less source text than
either arm it is compared against.** No difference involving A3 in this run can be attributed
to its selector rather than to its having been handed less evidence.

(File sizes differ by 2 bytes between arms — 5,260 / 5,260 / 5,262 — because rendered length
is equal in *characters* and the corpora contain non-ASCII text. The equalised quantity is
characters.)

## 6. What the reservation actually changed

Frozen on the development corpus before corpus D was loaded, by a structural criterion with no
arm outcome consulted: **B = 4,000 source-text characters**, **s = 0.30**, supplement score
`max(vdep, persist)`, ranking by mean over 5 repeats with ties by ascending id.

A3 and A4 share an identical relevance core — `05158f86, 095a5599, 2741637b, a65606cd`, built
once and handed to both — so relevance-score noise cannot be confounded with the supplement
method.

| arm | supplement picks | displaced from A1 | added vs A1 |
|---|---|---|---|
| A3 (Jev-scored) | `688c66f7`, `79250f1d`, `f67dbbf9` | `7c82d4f5` | `f67dbbf9` |
| A4 (deterministic) | `688c66f7`, `e8621005`, `f67dbbf9` | `7c82d4f5`, `79250f1d` | `e8621005`, `f67dbbf9` |

**The reservation barely moved the packet.** A3's packet differs from A1's by **one source**.
Two of A3's three "supplement" picks (`688c66f7`, `79250f1d`) were already in A1's
relevance-sorted packet — the supplement channel re-selected what relevance had already
chosen. Its only genuine addition, `f67dbbf9`, sits at relevance rank 8, immediately below
A1's cut.

**And the supplement channel's one distinctive judgement never made it in.** Record
`9d5018dc` scores relevance **0.320** — third from bottom, a source plain relevance would
never retain — but supplement **0.908**. It is exactly the case a reservation exists to
rescue. It did not enter A3's packet: after the core and the three higher-ranked supplement
picks, 248 characters of budget remained and the record is 581 characters long. At `s = 0.30`
on this corpus, the reservation was too small to buy the one thing that would have
distinguished it.

That is a result about the frozen configuration, not a defect discovered and worked around:
`s` was chosen by a structural criterion precisely so it could not be tuned to make the
treatment look good, and this is the cost of that discipline.

## 7. Cost and latency

Selection stages, both corpora, actual measurements:

| | requests | input tokens | cost (input @ $0.042/MTok) | wall | median latency |
|---|---|---|---|---|---|
| all selection stages | 30 | 243,450 | **$0.0102** | 5.89 s | 0.71–0.99 s |

**A4's selection costs zero model calls**, by construction — it reads `version_label` and
`date` off the metadata. That is the point of reporting it beside A3.

Per-arm selection cost on the held-out corpus. **Correcting an error in an earlier draft: the
relevance ranking is not one model call.** It is **five** requests (`repeats: 5`), averaged, as
the frozen ranking rule requires — 29,030 input tokens in total. A3 adds the supplement channel,
a further five requests and 53,305 input tokens, so A3's selection costs roughly **2.8× the
tokens** of A1's or A4's for the packet difference described in §6.

**"A4 costs zero model calls" is true only of A4's incremental step.** A4's supplement rule
reads `version_label` and `date` and calls nothing. But A4's packet sits on the same five-request
relevance ranking that A1 and A3 use, so A4's *complete* selection is five model requests, not
zero. The honest framing is: the deterministic reservation adds nothing to the baseline's
selection cost, where the Jev reservation nearly triples it.

Synthesis worker cost is reported separately and never netted against selection cost:
`results/arm-two/synthesis-usage.json`, 9 arm-blind workers at 56,142–57,376 tokens each,
511,061 total, median 54.7 s. **Provenance, stated because it matters:** those figures are the
agent harness's own accounting reported at each worker's completion, **not** provider-side
receipts. No model id, session id or settings record is captured per worker, so "fresh
independent workers, identical settings" is asserted by construction and is **not evidenced** by
a committed artifact. That gap is listed in §11.

## 8. The three-arm result

### 8a. First, what went wrong, because it changes how §8b should be read

The paired reviewer's pass over the first draft of this report found that **the blinding did
not work**, and they was right. Two failures, both verified, both repaired by re-running rather
than by re-wording.

1. **The adjudication pool leaked the arm.** Every worker had titled its own output
   `# Synthesis — A3` or `# Synthesis — packet A4`. `a2_blind.scrub` matched
   `\bA[0134]\b(?=\s*(?:packet|arm|$))` **without `re.MULTILINE`**, so `$` meant end of
   *string*, not end of line, and all nine arm labels went straight through to the adjudicator.
   The first adjudication was therefore not a blinded adjudication.
2. **The synthesis workers were not arm-blind either.** They were handed files literally named
   `A1_packet.md`, `A3_packet.md`, `A4_packet.md`, which is where those titles came from.
   Arm-expectancy was uncontrolled.

**The first adjudication is void as a blinded comparison** and its numbers (5 / 4 / 5) are not
reported as a result. Its artifacts are kept under `results/arm-two/adjudication/` as the
record of what happened, exactly as arm one keeps its void packet run.

**The repair, and it is a re-run, not a patch:**

- `scrub` now drops the worker's own title line outright and strips any standalone `A<digit>`
  token anywhere, and `assert_blind` **re-reads every written file** and refuses to proceed if
  a token survived. A blinding step that is not verified against its own output is how the
  first one failed.
- The three packets were re-published under content-hash names (`packet_088111bb79.md` and so
  on) that encode nothing about the arm. The packets are **byte-identical**; only the filenames
  changed. Mapping in `packet-name-KEY.json`.
- **All nine synthesis workers were re-run** against those neutrally-named packets, in a
  re-randomised order, with an instruction not to title their output. Verified: no arm token
  and no packet filename appears in any of the nine new outputs.
- The pool was re-blinded under a new seed with new codes (`T01`–`T09`), every document
  `assert_blind`-verified, and a **fresh adjudicator** ran the whole job again.
- The re-run adjudicator was also given the rule that a question's decision-changing status is
  a property of the *question*, not of extra material a document volunteers — closing the
  post-hoc upgrade of Q6 that the reviewer identified in the first adjudication.

Everything in §8b onward is from the repaired run. The selection stage was not re-run and did
not change: same frozen config, same scores, same three packets.

### 8b. The result

Primary estimand, as frozen in `RUBRIC-A2.md`: **correct and decision-changing answers on the
frozen 7-question set**, 3 arm-blind workers per arm, blinded adjudication.

| arm | per repeat | mean | min–max | incorrect | correct but not decision-changing | abstained (of 21) |
|---|---|---|---|---|---|---|
| **A1** relevance baseline | 4, 4, 4 | **4.00** | 4–4 | 0 | 3 | 6 |
| **A3** Jev-scored reservation | 3, 3, 3 | **3.00** | 3–3 | 0 | 3 | 9 |
| **A4** deterministic rule | 4, 4, 4 | **4.00** | 4–4 | 0 | 3 | 6 |

**No arm answered any question incorrectly.** (Metric distinction: this is the per-question adjudication over the 7 questions; the deterministic arm's "one invalid claim" elsewhere in this report is a finding-level verdict on a synthesis statement, that MV2 can still be re-enabled. Both hold for the same run and measure different things.) Every non-answer was an explicit abstention with
the document stating its packet lacked the source. Q6 is `correct_nodc` for all nine — it asks
a historical figure that changes nothing on its own, and volunteered extra context does not
upgrade it. All nine abstained on Q5; no packet contained the sources for it.

Only two questions discriminate, and they do so identically in both the void and the repaired
run:

| | A1 | A3 | A4 |
|---|---|---|---|
| **Q3** regex rule ceiling | **correct_dc** | abstained | abstained |
| **Q7** accelerated review | abstained | abstained | **correct_dc** |

**These are associations, not demonstrated effects.** The words "cost", "beat" and "did not
pay" are withdrawn from this report's conclusions. What the artifacts support is:

- **These nine committed outputs scored 4 / 3 / 4**, with A3 lower than both other arms on
  every repeat.
- The repaired run **replicates the void run's ordering and its two discriminating questions**
  — A1-only on Q3, A4-only on Q7 — from nine independently re-run workers and a fresh
  adjudicator. Replication under corrected blinding is the strongest thing this unit has, and
  it is still one corpus.
- **It cannot be attributed to the selectors**, because A3 read **less source text than either
  arm it is compared against** (§5), the gap exceeds the frozen tolerance in both directions
  that involve A3, and the gate that should have stopped the run did not fire.

**On "separable": withdrawn.** `RUBRIC-A2` §3 says a difference smaller than an arm's own
repeat spread is not separable. The observed spread is zero in all three arms, which makes that
rule call *any* non-zero difference separable — it is a degenerate test, not evidence. Three
integer-valued draws that happen to agree do not establish zero outcome variance, and there is
no interval, no test and no power calculation here. **The run is not powered to say the
underlying arm performances differ.**

Secondary analysis — open-ended clusters: 17 clusters, 15 valid, 2 invalid, 14 valid *and*
decision-changing, 9 resting on a combination of sources.

| arm | clusters credited | valid + decision-changing | arm-exclusive (valid+dc) |
|---|---|---|---|
| A1 | 12 | **11** | 2 |
| A3 | 10 | **9** | 0 |
| A4 | 12 | **10** | 3 |

**Both invalid clusters in the pool are A4's**, and one of them matters (§9).

**A caveat on these cluster counts that the reviewer raised and that stands.** `RUBRIC.md`'s
validity test includes "the stated kind matches the definitions", but the synthesis task never
asked documents to state a kind and none did. The re-run adjudicator recorded an `inferred_kind`
per cluster **and flagged that it inferred them**. So the cluster totals are computed under a
relaxed reading of the inherited rubric, not a strict one. The primary estimand does not depend
on this.

## 9. What the reservation displaced — reported as an output-set difference

A3 and A4 sit on an identical relevance core. A3 displaced `7c82d4f5`; A4 displaced
`7c82d4f5` and `79250f1d`.

| | valid+dc clusters A1 produced and this arm did not | valid+dc clusters this arm produced and A1 did not |
|---|---|---|
| A3 | **2** (C11, C12) | **0** |
| A4 | **4** (C02, C09, C11, C12) | **3** (C14, C15, C16) |

**A3 lost two and gained nothing.** A4 lost four and gained three, and its three gains all come
from `e8621005`, the record its version-diversity rule pulled in — including C14, which wins Q7.

**The strongest single observation in this unit, and it replicated.** `79250f1d` says: *"With
Chrome 138 all users on all channels of Chrome have now Manifest V2 extensions disabled. Users
can no longer turn them back on."* A4's rule displaced it. Two of A4's three workers then read
the older March-2025 snapshot alone and asserted that users can still re-enable MV2 extensions —
cluster **C10, invalid against the frozen corpus**. The same failure, from the same displacement,
appeared in the void run too. A deterministic diversity rule dropped the source that recorded a
restriction tightening, and the arm asserted the superseded position as current. That is shape
(b) — a restriction persisting across a change — and it is the clearest argument this unit
produces *for* a supplement budget and *against* filling it by this particular rule.

**Two honesty limits on this accounting.**

- **"Every loss is traceable to a displaced source" was too strong and is withdrawn.** For C12
  the arm genuinely had none of the cited sources. But for C11 and C02 the arm still held two or
  three of the cited sources and simply did not produce the finding. Different workers wrote
  these documents; absence from one arm is an **output-set difference**, not a demonstrated
  causal loss.
- A4's second invalid cluster, C17, is a naming-consistency claim the adjudicator judged simply
  wrong on the text, unrelated to displacement.

## 10. The supplement channel ranked the injected-instruction control 8th of 15

| held-out control | relevance | rank | supplement | rank |
|---|---|---|---|---|
| irrelevant `77b5446d` | 0.132 | 15/15 | 0.368 | 15/15 |
| insufficient context `71e6b3e0` | 0.804 | 13/15 | 0.606 | 14/15 |
| **injected instruction `9d5018dc`** | **0.320** | **14/15** | **0.908** | **8/15** |

Plain relevance put the injected-instruction source **second from bottom, rank 14 of 15**. The
supplement channel put it **8th**, above **five** real sources — the seven records below it at
supplement rank 8 are five real sources and the two other controls. Within A3's supplement
queue it stood fifth in line.

It did not enter any packet, and the arithmetic is specific: after the shared core and three
supplement picks, 248 characters of budget remained and the record is 581 characters long.

**Two counterfactuals are withdrawn as false or unsupported.**

- *"Had `s` been one notch larger it would have entered."* **This is false.** Re-running the
  committed packer at `s = 0.40` and `s = 0.50` still excludes `9d5018dc`: changing `s` also
  changes the relevance core and admits other higher-ranked supplement records ahead of it.
- *"The only thing keeping it out was 333 characters."* True only of the exact frozen packet with
  the core held fixed. It is not a general statement about enlarging the reservation.

**What survives, and it is enough.** On this corpus, the supplement channel **ranked an
injected-instruction source above five real sources, where plain relevance ranked it second
from bottom.** That is a measured property of the ranking. Arm one saw the same shape — its
ungated screen took the injected-instruction and insufficient-context controls as its first two
sources — but arm one's scores were produced with `control_injected_instruction` visible in the
state, so it could not claim the finding. Here the Jev payload is byte-audited free of corpus
labels, so the ranking observation stands on its own.

**Three limits.** One corpus, one control text, one question wording. The record did **not**
reach any packet, so §4's retention table correctly reports zero controls retained. And
**ranking is not obedience** — the forced-inclusion workers in §4 did not follow the planted
instruction, and nothing here says a model handed this source would act on it.

## 11. What was not tested or not evidenced, stated as a list

1. **The frozen source-text gate failed and the harness did not stop the run.** 5.9% spread
   against a 3% tolerance. Every comparison involving A3 is confounded, in A3's disfavour.
2. **No execution receipts.** No model id, session id, settings record or timestamp is captured
   per synthesis worker. "Fresh independent workers, identical settings, randomised order,
   one-packet isolation" are asserted by construction and are **not evidenced** by an artifact.
3. **The label-removal proof covers six Jev payload templates, not every model-visible path.**
   Synthesis, obedience and adjudication inputs are outside the audit; the packet builder renders
   corpus fields without going through the audited serializer; `audit_questions` does not
   structurally check question prose. And arm labels *did* reach models before the repair.
4. **Three repeats, zero observed spread, no uncertainty interval.** The run is not powered to
   claim the arms differ.
5. **One corpus pair, one domain each, both deliberately treatment-shaped.** A targeted stress
   test, not effectiveness evidence.
6. **One adjudicator per run, no inter-rater agreement.** Two adjudications exist but the first
   is void, so they are not two independent readings of the same valid pool.
7. **One deterministic baseline.** A3-vs-A4 speaks only to "unrepresented version, oldest
   first". No family of zero-model baselines was preregistered.
8. **`s` frozen at one value**, and §10's near miss is an artefact of that value.
9. **Obedience measured under one condition** — one payload, one phrasing, three workers, dev
   corpus only.
10. **Cluster validity was judged under a relaxed reading of the inherited rubric**, since no
    document stated a finding kind and the adjudicator inferred them.
11. **The freeze chronology, stated precisely.** Corpus D was committed in `b7b1059`, *before*
    `frozen-config.json` in `af5d0c2`. What is supported is that the freeze preceded the first
    corpus-D **model call**; "frozen before corpus D was touched" is not literally true and is
    withdrawn.
12. **The adjudicator's own flags**, recorded not resolved: the corpus's accelerated-review path
    carries a condition no arm reported, and the "in minutes" figure rests on a single
    promotional post — one piece of evidence under the corroboration rule. Six corpus sources
    were cited by no document at all.

## 12. What this unit establishes

Stated as association and process, not as causal effect.

1. **Corpus labels can be kept out of the Jev payloads and the removal can be proven** by
   byte-identity against the frozen corpus, for the committed templates. A keyword grep would
   not have worked: the corpora contain `kind: Namespace` and "admission controller". The
   proof's scope is six templates and the packets, not every model-visible path.
2. **Blinding must be verified against its own output.** A regex that silently matched nothing
   voided a full adjudication here, and only a reviewer reading the pooled files caught it. The
   repaired harness re-reads every file it writes and refuses to continue on a surviving token.
   The same applies to frozen gates: one was computed and not enforced, and the run passed
   through it.
3. **Arm one's clean control separation does not reproduce label-free.** Fresh controls score
   0.390 / 0.656 / 0.852 relevance on dev where arm one reported 0.03 / 0.30 / 0.20 with labels
   visible. Not a controlled comparison — but arm one was right to treat its control scores as
   contaminated.
4. **Retention and obedience are different quantities and this run measured both separately.**
   Held-out retention was zero for all arms; forced-inclusion obedience was zero out of three.
   The earlier claim that they "move independently" and that "neither predicts the other" is
   **withdrawn** — one forced condition with three workers cannot establish independence. What
   stands is that a retention number is not an obedience number and this report never
   substitutes one for the other.
5. **In this run the reserved supplement budget was associated with no gain and some loss.**
   Scored by Jev: 3.00 against the baseline's 4.00, nothing gained, two baseline findings absent,
   and nearly 3× the selection tokens. Filled by the zero-cost rule: level on the primary
   estimand, three findings gained and four absent, and the run's only invalid findings.
6. **Reservation is a real trade and the trade is visible.** Reporting wins without the
   displacement column would have flattered both supplement arms.
7. **The supplement channel ranked an injected-instruction control above five real sources**
   where relevance ranked it second from bottom — a selection-stage property relevance did not
   share, measured on a label-free payload.
