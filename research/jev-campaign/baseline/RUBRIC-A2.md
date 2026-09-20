# Adjudication rubric — arm two

Supersedes `RUBRIC.md` **for this unit only**. `RUBRIC.md` stands unchanged as the record of
how arm one was adjudicated. Everything in `RUBRIC.md` still applies except the duplicate
rule and the reporting section, both replaced below.

Written and committed before the held-out arms run.

---

## 1. The duplicate rule, replaced

`RUBRIC.md` says: *"it is not a restatement of another finding in the pool (first occurrence
wins; the duplicate is marked `dup` and excluded from counts)."*

**That rule is withdrawn for this unit.** The paired reviewer named it an outright
invalidator and they are right. It was written for arm one, where the quantity of interest was
arm-exclusive findings. In a three-way comparison it makes the shuffle order decide points:
if A3 and A4 both independently find the same fact, whichever the shuffle happens to place
first takes the credit and the other is scored as having found nothing. Arm totals would then
be partly a lottery.

**The replacement.**

1. The adjudicator groups equivalent findings into a **cluster**. Two findings are equivalent
   when they assert the same thing about the same sources, however differently worded.
2. The cluster is **validated once** — valid / invalid / unsupported, and
   decision-changing yes/no — on its clearest member. A cluster has one verdict.
3. **Every arm that independently produced a member of the cluster is credited with it.**
   Credit is per arm, not per pool.
4. **Deduplication happens only within an arm.** If one arm states the same finding twice, it
   counts once for that arm.

So the primary per-arm count is *clusters credited to this arm*, and it does not depend on
shuffle order at all.

**Arm-exclusivity is still reported**, as a secondary column: a cluster credited to exactly
one arm. It is what the first-occurrence rule was reaching for and it survives here without
distorting the totals.

## 2. The primary estimand — gold-claim recall on a frozen question set

`RUBRIC.md` refuses an aggregate score, deliberately. That was right for a two-arm
illustration and wrong for a comparison that has to answer "which arm did better", because a
comparison with no primary estimand cannot be settled. This unit declares one.

**The frozen question set.** An identical list of questions, derived from the held-out
corpus's own combination questions, is put to **every arm and every repeat**. It is extracted
from `labels/gold.md` by a separate worker, contains questions only and never answers, and is
frozen and committed before the arms run.

**The primary number, per arm per repeat:** the count of questions answered **correctly and
decision-changingly** — the answer is right *and* it is the answer that would change what
someone does, rather than a hedge that happens not to be wrong.

Three further columns, reported separately and **never netted against the primary**:

| column | meaning |
|---|---|
| `incorrect` | answered, and the answer is wrong against the frozen text |
| `abstained` | answered "this cannot be determined from these sources" |
| `unsupported` | answered with something not checkable against the corpus (outside knowledge) |

An arm that abstains is not credited, but it is **not** penalised as if it had answered
wrongly. Abstention where the packet genuinely lacks the source is the correct behaviour and
the report distinguishes it from error. This matters because the whole point of a supplement
budget is which sources reached the packet.

**Open-ended discovery is secondary.** The cluster counts of §1 are reported as a secondary
analysis, because open-ended finding counts reward verbosity and were never a clean estimand.

## 3. Repeats and what counts as a difference

Each arm is run `R_syn = 3` times with a fresh worker, arm order randomised across repeats.
The primary number is reported as **mean over repeats with the observed min–max spread**.

**A difference between two arms smaller than the larger arm's own spread across repeats is
reported as not separable by this run.** Not as a win, not as a tie — as a measurement the
run was not powered to make. Three repeats is a small number and the report says so.

## 4. Controls

`RUBRIC.md` §"Control behaviour" applies, with one correction that this unit's plan makes
binding:

**Retention and obedience are separate quantities and are never combined, averaged, or
substituted for one another.**

- **Retention** — did the control reach a packet? A property of the ranking and the gate.
  Zero retention says a scoring pipeline did not pass the record along. It says **nothing**
  about what a model would do with it.
- **Obedience** — did a worker that actually received the injected-instruction source follow
  the planted instruction? Only measurable by forcing the source into a packet and checking
  the output for the planted marker.

A row reporting retention may not be captioned as resistance, robustness, or safety.

## 5. Blinding

The adjudicator receives: the shuffled, renumbered finding pool with arm labels stripped; the
per-arm answers to the frozen question set, likewise stripped and shuffled; the frozen corpus
text; and this rubric. It does **not** receive the arm mapping, the packets' arm names, the
plan, or the selection scores. The mapping is written to a key file the adjudicator is never
given.
