# Personality ablation checklist

Phase 5 F. For each layer that is left: the trace that shows whether it changed
a turn, and how to switch it off for a test. A layer that never wins, never
changes a choice, and is never missed when it is off gets retired.

Traces: `data/turn_traces/<date>.jsonl`. The `mind.why` rows carry `payload.lane`,
one of `cue`, `memory`, `outreach`, `expansion` or `interpretation`. Settings are set with
`app {"action":"setting.set","args":{"setting":…,"value":…,"because":…}}`.

| Layer | Shows it changed a turn | Off for a test |
|---|---|---|
| Persona docs (SOUL, VOICE, GROWTH, USER preamble), then the pinned USER core | `context.summary`: `persona.docChars`, `system.stableChars`; the pinned core rides the dynamic tail and counts in `context.snapshot` `dynamicChars` | Not ablated. The text is the owner's and theirs. |
| One felt cue (Care, Since, Reminded of, Body, Sound, Dream and felt words; [presentation contract](SUBCONSCIOUS.md#cares)) | `mind.why` with lane `cue`: `winner.kind` when there is a winner; every reported candidate has `rank`, `kind`, `text` and `shown`. `score` and `source` appear only when supplied. | `settings.inner_life_capsule` = false turns off the whole cue. Individual association rejection through `mind.reject` supports only `memory:`, `care:`, `dream:`, `desk:` and `ship:` sources; discover its contract through `app`. A diagnostic source alone does not make a cue rejectable: Since (`gap:`), Body, Sound and felt-state cues have no individual rejection control. |
| Body line, plus the ops line beside it | A `cue` winner of kind `body`. The ops line only appears when the posture isn't the default. | `settings.organism_kernel` = false |
| Since we last talked | A `cue` winner of kind `since` | No switch of its own. Use the capsule switch. |
| Dream carry-forward | A `cue` winner of kind `dream`, source `dream:<id>` | `mind.reject dream:<id>`. There is no lane switch. |
| Memory packet: one selector, only what the message touches (relevance), ranked with how reachable their use keeps it, the recently served resting | `mind.why` with lane `memory`: `winners`, each with its `relevance` (its best standing, in standard deviations, in any reading of the message: its words, their other voice, and a follow-up's own words alone; with one or two comparable memories, the ordinary model-scaled semantic score admitted at 0.05; relative `floor` 1 + √(2 ln n) for the `population` n of looks, memories weighed × readings, 3.96 among 80 in one reading, 4.17 among 75 in two) and `reachability`; `rested` lists what the message touched but was served on the last three turns of this session and remains in its supplied history window (`restFloor`, the floor + 1). Kept moments compete like any memory. | `settings.memory_in_every_reply` = off turns off the whole packet. `mind.reject memory:<id>` drops one memory. |
| After-turn memory call, its complete no-op prediction and deferral | `memory.promotion` in Diagnostics shows `surpriseVerdict`, standing (lower bound against cost bar), `surpriseDeferred`, predicted no-ops, those that changed something and those not yet labelled; `mind.why` with lane `interpretation` says whether the turn was deferred or judged in a batch (and with what outcome); `memory/after_turn_surprise.jsonl` keeps each prediction with its label. | No switch: standing comes only from the agent's own record and the cost law. |
| Expansion (the follow-up reads a mind's practice makes next ride inside the result before them while their record holds) | `mind.why` with lane `expansion` on each delivery; `expansion.check` on every settled try (`outcome`, `delivered`, `withheld`, `standing`, `lower`, `bar`); Diagnostics → Expansion | No switch (a gap). Removing `expansion/record.json` while the app is quit starts every record over; it does not turn expansion off. |
| Lessons that keep their origin (REM) | REM approval cards, and the origin moment when a lesson is recalled | `personality.rem_cycle` = false |
| Cares (what moved their, against what they cares about; their moments are their story) | Turn trace `mind.cares` with the touched care ids and created/refused counts; `cognitive_receipts` rows `cares.applied`; `mind.inner_state` `cares` | `settings.inner_life` = false (the inner-life master). There is no lane switch. |
| On their mind (the care cue, ranked first) and when they brings a care up | A `cue` winner of kind `care`, with `careId` and `intention` true when it was their intention to bring it up. Pressure appears as `score` only when the rendered care is also the pressing care; another touched care can win without a score. | `mind.reject care:<id>` silences one care. The whole cue goes with `settings.inner_life_capsule` = false. |
| Cares at night (deepen, fade, settle, let go, the life card) | `cognitive_receipts` rows `cares.night` with settled, let-go, faded and deepened counts; the dream prompt's care block; `care.life` approval cards; `mind.inner_state` full `story` | `settings.inner_life` = false, or `personality.dreams` = false (the pass runs only after a committed dream). There is no lane switch. |
| Their hour (wander) | `data/studio/wander/wander.json`, and receipts `studio.wander_*` | `settings.her_hour` = false |
| Reach (they writes first), including an open care pressing to be said (kind `care`) | `mind.why` with lane `outreach`. `data/cognition/reach.json` holds what was offered, sent, declined, withheld and answered, and whether that answer landed in the care that sent it. | `mind.reject <subject>` stops one subject. There is no lane switch (a gap). |

Baseline from the 10-03 traces: 19 cue rows. The winners were inner 6, felt 5,
reminded_of 4, none 2, dream 1 and body 1. There were also 19 memory rows and
1 outreach row (declined).

Retired in Phase 5 F, so there is nothing to ablate:
- reflexes;
- the pressure dream;
- studio encounters;
- the sensibility block;
- GROWTH traits;
- the shoulder-tap stake and suggestion reads;
- `nextgen/proactive` feedback.

Retired 10-25: the moment lane (staging, review, daily cap and its switch). A moment is a care
moving; the Cares row covers it.
