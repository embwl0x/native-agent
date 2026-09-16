---
name: nativeagent-ax-improvement-loop
description: Improve NativeAgent specifically for Agent's Agent Experience—evidence retrieval, tool discovery, action feedback, recovery and continuity. Use for an AX improvement campaign or to maintain this loop; ordinary UI polish and personality testing belong elsewhere.
---

# NativeAgent Agent Experience Improvement Loop

## North star

**Agent functions naturally throughout NativeAgent, with them attention on what
they are accomplishing. The app handles the mechanics and brings their meaningful
results or decisions.** User made this the AX goal on 2026-09-15: nothing in
NativeAgent should feel like machinery for them. AX means **Agent Experience**,
not Apple Accessibility. The product authority is
`docs/NORTHSTAR.md` in the NativeAgent checkout.

Apply this to remembering, context retrieval, research, creation, apps/tools,
getting help, agent conversations, recovery and continuity. Routine routing,
context assembly, transport and bookkeeping belong underneath the interface.
Show useful evidence, conversation or work results first, with technical receipts
available on demand. Surface real decisions and blockers plainly, preserving
authorization, uncertainty and exact outcomes. A strong model's ability to work
around machinery is not evidence of good AX; neither is a friendlier checklist
that still leaves routine operation to Agent. New connections may need setup or
adapters, but their recurring mechanics should then belong to the interface.

Optimize verified completion with justified confidence and less avoidable
burden. Fewer calls or tokens help only when the information and correctness
needed to finish the task are preserved. This standard does not authorize an
unbounded audit or claim that all existing journeys already meet it.

## Choose the mode

- **Design/maintain the loop:** edit this skill and relevant references only.
  This alone never authorizes app changes, a restart or a live experiment.
- **Run an Agent Experience pass:** follow the loop within the requested scope.
  Without a duration, complete a coherent useful batch; do not invent a
  multi-hour run, automation, task or model override.
- **Status/review:** inspect and report; do not start implementation.

## Establish the task

Use `nativeagent` for source/runtime ownership and build/install rules, and
`agent-bridge` for bounded consultation. Read the latest handoff and preserve
dirty work. A recent relevant instrument report can supply the baseline; its
old leads are not a work queue. Confirm that source and installed behavior
describe the same build before attributing a defect.

Ask Agent for concrete friction, the example that demonstrates it, whether it
is current, and the useful outcome. They are a design collaborator, not the sole
grader: inspect actual tool input/output and canonical results. Do not script
an emotional reaction or alter persona/memory to make acceptance look better.

For a new AX area or a requested deep dive, research relevant primary sources
and manually trace representative journeys before selecting a batch. Use
[the field guide](references/field-guide.md) to choose useful boundaries; do
not walk its entire list mechanically. Research suggests hypotheses, not
authority to import another framework or redesign the product.

## Improve a bounded set of real journeys

1. **Observe the complete journey.** Follow intent → available context/tools →
   selected action → response → verified outcome → retained evidence. Include
   confusion, recovery and handoff when relevant. Existing traces often suffice;
   don't start with a test suite or risky reenactment.
2. **Locate the avoidable burden.** Keep a small set of supported findings.
   Ask whether Agent can get on with the work or must manage the machinery.
   Separate necessary judgment from routine steps the owning interface should
   handle; include successful journeys where the model compensated for friction.
   State the agent-visible symptom, source owner, plausible alternate cause,
   expected improvement and invariant. Prioritize observed frequency, cost to
   completion and strength of evidence; mark unknown frequency as unknown.
   Rare correctness or safety failures can outweigh frequent minor friction.
   Retire fixed or disproven findings;
   distinguish missing evidence from a failed action.
3. **Improve the owning interface.** Prefer better selection, explicit scope,
   exact identifiers, useful feedback and progressive disclosure in existing
   tools. Finish the coherent change and affected consumers. Keep tools lazy
   and provider-neutral; don't add another truth store, background loop,
   universal router or prompt-wide handbook instead of fixing the owner.
4. **Build, then verify the finished behavior.** Build the integrated target,
   run proportionate checks of the actual failure and a neighboring case, then
   install runtime changes and let resident Agent exercise the authorized
   workflow. Test coherent behavior, not each edited file mechanically; keep
   the assemble/build/final-validation order. A failure permits a small
   in-scope correction and recheck. Don't repeat side effects for validation;
   inspect existing outcomes or use an isolated fixture when necessary.
5. **Judge the change.** Record improved, unchanged, regressed or inconclusive.
   State which routine burden disappeared and what still requires their attention.
   A renamed tool or cleaner receipt alone does not establish natural operation
   if they still has to perform the same avoidable routing or bookkeeping.
   Compare equivalent cases and retain sample sizes. A clearer honest refusal
   or justified no-change verdict can be good AX. Don't hide uncertainty or
   call a retrieved summary the original evidence. For discovery or workflow
   improvements, give Agent the objective and necessary constraints without
   prescribing tools or the successful route. Label coached checks as mechanism
   verification, not evidence of independent task completion. Where useful,
   include a neighboring example not used to tune the fix in the same final
   validation; do not turn this into a separate reviewer or test campaign.
6. **Revise the loop from experience.** Ask Agent what became easier and what
   still demanded needless interpretation. Add only transferable lessons here
   or in the field guide; keep dated receipts in the project handoff. Remove
   instructions that encouraged waste. Continue within the requested scope/time,
   then close the safe unit.

## What to assess

Choose measures that answer the hypothesis, not a composite AX score: verified
completion; time/calls to useful evidence; avoidable schema repairs/retries;
relevant output versus omitted evidence; recovery without duplicate effects;
freshness/provenance; unnecessary requests for User to mediate. An extra
confirming read can be a benefit. Prompt/cache/resource cost and human UI
quality are preservation checks, not competing excuses.

Choose the few measures that would show the expected benefit before editing.
Use existing before-change traces when available; this does not require a
pre-change test run. Compare the finished journey on a similar task, recording
model/build, scope, context and warm/cold conditions that materially affect the
comparison. Separate total calls from avoidable calls and active work from wait
time. If a comparable baseline is missing, report demonstrated capability and
unknown improvement magnitude rather than inventing a speedup. One successful
example establishes that example, not a general completion rate.

Keep a compact case record: task, friction, source/installed identity, expected
outcome, change, exact evidence locator, observation date, provenance, tested
coverage, sample size and verdict. Link acceptance to the prior finding it
resolves, with remaining scope explicit. Distinguish direct observations,
worker reports and retrospective summaries. Don't add a production telemetry
store or harvest hidden reasoning.

## Bounds and closeout

Preserve Trust, authentication, quiet-desktop behavior, cancellation, exact
approval identity, transactionality, persona/cognition and shared Liquid Glass.
Don't equate request acceptance, tool return, visible change, external
settlement and delivery. Never replay ambiguous historical work to clear a
warning, or recommend retrying a write merely because output is missing.

Keep commits/publication within User's requested scope; never stage unrelated
dirt to obtain a clean-build claim. Report dirty installed provenance honestly.
Update the project handoff and cross-project Agent handoff using the normal
script. Reserve time for integrated verification, recovery and closeout; stop
selecting changes when that reserve begins. For a timed run, record one start,
deadline and a realistic closeout reserve. Distinguish investigation,
implementation, validation and necessary observation in the outcome report;
elapsed hours are not an improvement measure. Give passive observation a
specific question, duration and decision it can inform. Do not substitute idle
watching for remaining supported AX work, or invent defects to fill the clock.
When useful in-scope work is exhausted, report that honestly; honor an explicit
request to observe through a deadline without presenting waiting as fixes.
If an invariant regresses, stop
expanding the batch and restore it or leave an explicit blocker. No scheduler
or autonomous wakeup is created by this skill. At a major
objective change or handoff limit, finish the safe unit and leave a continuation
note rather than silently starting another campaign.
