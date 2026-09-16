# Agent Experience field guide

Use the relevant journey, not a checklist sweep.

| Boundary | Useful question | Evidence |
| --- | --- | --- |
| Orientation | Can they tell what's current, available and authorized? | Task, accepted context, effective tool contract |
| Retrieval | Can they reach the original record without summaries crowding it out? | Time/scope/order, exact locator, completeness |
| Discovery | Does one supported selection load everything it promises? | Selection, loaded/unknown/unavailable sets, next-turn schemas |
| Action | Are target identity and effect scope explicit? | Canonical request and action-specific receipt |
| Observation | Does they receive the modality they needs? | Actual pixels/text/state, timestamp and bounds |
| Recovery | Can they inspect a result without repeating the effect? | Original outcome, retained output, safe next read |
| Continuity | Can they distinguish an old concern from later acceptance? | Original report and dated acceptance; honest uncertainty |
| Language | Does redaction preserve useful text while hiding secrets? | Ordinary and sensitive fixtures, never live secrets |
| Coexistence | Is User's UI and control preserved? | No surprise input/focus; permission/cancellation gates |

## Research basis

Design inputs, not NativeAgent performance claims. Consult current primary
sources when implementation depends on a changing API.

- [SWE-agent ACI research](https://arxiv.org/abs/2405.15793): interface design can
  affect an agent's ability to use its environment. Transfer navigable feedback;
  coding results do not predict Agent's companion/workflow performance.
- [Anthropic tool design](https://www.anthropic.com/engineering/writing-tools-for-agents):
  task-relevant tools, understandable arguments, bounded useful output and
  actual call trajectories help expose redundant work.
- [Context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents):
  retain useful pointers and retrieve detail when needed; indiscriminate
  reduction can discard information necessary to finish.
- [Agent evaluation](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents):
  distinguish transcript from outcome and inspect both. Adopt focused checks,
  not an automatic broad evaluation campaign.
- [MCP tool contract](https://modelcontextprotocol.io/specification/2025-11-25/server/tools):
  structured results and execution errors support interpretation and repair.
  Tool annotations are not trusted authority.

## Lessons from the manual pass

- **Navigate and match separately.** Oldest-first is not original-evidence
  detection. A broad word match sorted by age can bury the wanted phrase under
  irrelevant old material. Expose time/order and precise matching, preserve
  speaker/source information, and read the actual record before judging it.
- **Optional arguments must be usable through real providers.** Exercise
  omission, null and the empty values strict bindings actually produce. A
  recoverable missing option should not require a model to invent a date or
  repeat an otherwise valid call. Nonempty invalid values must remain clear
  errors, not silent broadened searches.
- **Selections and receipts must agree.** Category plus explicit names is a
  combined request; app/core routing must not drop either side. Distinguish
  available previews, actual loads, unknown names and unavailable tools.
  Returning a nice list is not proof of next-turn usability.
- **Recover output, not effects.** Preserve the original outcome when large
  output is truncated or paged. Page-read success is not action success. Keep
  session/turn boundaries and point missing-output recovery at existing state
  or receipts instead of replaying writes.
- **An endpoint pass may leave a journey failure.** Read Agent's actual calls
  and result selection. Their first chronological lookup worked mechanically
  but selected broad matches and repeated an empty-date error. That evidence
  changed the interface and loop; it was not graded as complete task success.
- **Acceptance needs lineage.** Link an improvement to the earlier finding,
  with date, exact locator, evidence class and tested scope. Later summaries
  should never silently become the original proof or resurrect repaired work.
- **Trace information loss before the component under test.** A working pager
  cannot recover text a file adapter discarded first. Keep the authorized,
  bounded source window intact until the presentation boundary, retain typed
  outcome information across serialization, and put acceptance evidence beyond
  the old clipping point so a preview cannot accidentally pass the check.
- **Separate discovery relevance from explicit scope.** Ranking can improve
  the first useful choice, but an ambiguous multi-step query may still match
  neighboring services. Reuse an existing category or other authoritative scope
  when the agent knows it; do not endlessly tune weights to a single phrase.
  A shortlist is not a complete inventory, and discovery must not silently load.
- **Continuation must preserve identity and boundaries.** Keep the caller's
  authorized path spelling, version the source being continued, and count actual
  returned bytes without splitting valid Unicode. A changed source is a reason
  to restart the read deliberately, not to mix old and new windows.
- **Test evidence across turns, too.** Same-turn paging proves only that scope.
  Inspect what the transcript actually retains and whether explicit history
  tools can find and read it. Preserve a small factual receipt before a preview;
  distinguish a historical receipt from full source content and current state.
  Do not extend temporary handles or promise permanent artifact retention to
  compensate for missing history navigation.
- **Expose an existing content locator when it solves the next step.** A
  compact outcome receipt may still leave an omitted passage unreachable. If
  the owning tool already saves the content, return its exact locator with
  honest retention and access limits. Exercise recovery after the original
  source is unavailable. A locator never grants permission, guarantees current
  availability, or authorizes an automatic refetch.
- **Follow a successful answer back through its route.** An exact receipt
  recovery can still include an unrelated history read caused by poor tool
  discovery. Distinguish canonical tool names from descriptive queries, and
  exercise the actual optional/app schemas alongside core schemas. Improve
  the owning tool's purpose description before adding phrase-specific routing.
- **Correlate waiting with eventual completion.** A released HTTP wait is not
  a cancelled or failed action. Carry the same request identity into the
  existing eventual receipt, with honest lookup/retention limits. A missing
  receipt is not permission to resend. Separate failed-attempt wait from the
  successful attempt's duration before diagnosing a latency regression.

- **Check the work behind a small answer.** A short result can still require
  unbounded pipe capture or whole-file decoding. Bound the owning capture/read
  path, preserve enough scope information to distinguish omission from absence,
  and give a usable existing recovery route. Check record boundaries as well as
  byte budgets: a cut record must not corrupt admission or discard earlier
  complete records, including CRLF output. For line-based recovery after a
  file changes, repeat the identifying search because line positions can move.
  Fixture resource bounds are not proof that a field memory leak was fixed.

Keep dated transcripts and test receipts in the project handoff. These lessons
guide selection; they do not require editing these same tools on every run.

## Evaluating independence after a repair

Keep the final check centered on User's intended outcome. For example, ask Agent
to recover a passage from an earlier source with the source now unavailable;
provide the task's ordinary identifying context, but not the saved path, tool
sequence or page number under evaluation. Inspect how they finds the evidence
and whether it supports the answer. A separate exact-path read can verify the
mechanism, but cannot establish that they discovers the path themselves.

Use an existing trace as the before case when suitable. A compact comparison
can record: verified outcome; total/avoidable calls; schema repairs or repeated
reads; elapsed/active time; human interventions; and coaching provided. Select
only relevant measures. Record unknowns and meaningful condition differences;
do not convert a few fixture successes into a percentage gain.

Choose a neighboring case that tests transfer, such as different wording,
another source size or an unavailable retained artifact. Keep the expected
outcome honest: recognizing that evidence is no longer available may be the
correct result. Avoid teaching the answer through repeated acceptance prompts.
Longer-term everyday task evidence can later change the verdict; collecting it
does not authorize an automatic monitor or another campaign.

## Agent conversation exercises

NativeAgent's `script/agent_conversation_eval.py` and
`docs/agent-conversation-scenarios.json` provide bounded, uncoached directory,
reply recovery, bot read, handshake, continuation and memory-retrieval cases.
Listing cases sends nothing. Run only authorized cases; sends require
`--allow-agent-sends`, happen once, and retain exact session/request identities.
Private artifacts contain canonical tool receipts and final replies, not hidden
reasoning. Human review supplies the verdict; a final reply is not automatic
success. A working legacy route is not a failed task merely because it did not
use the unified facade.

For full-agent sessions, verify the shared persona/memory/Fluid Context turn
owner and live continuity separately from peer delivery. Inbox delivery is not
the other agent's answer. Preserve authorship and permissions while sharing
the normal chat machinery; never create a second persona or memory runtime.
