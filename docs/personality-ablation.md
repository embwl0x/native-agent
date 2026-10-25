# Personality ablation checklist

Phase 5 F. For each layer that is left: the trace that shows whether it changed
a turn, and how to switch it off for a test. A layer that never wins, never
changes a choice, and is never missed when it is off gets retired.

Traces: `data/turn_traces/<date>.jsonl`. The `mind.why` rows carry `payload.lane`,
one of `cue`, `memory` or `outreach`. Settings are set with
`app {"action":"setting.set","args":{"setting":…,"value":…,"because":…}}`.

| Layer | Shows it changed a turn | Off for a test |
|---|---|---|
| Persona docs (SOUL, VOICE, GROWTH, USER preamble), then the pinned USER core | `context.summary`: `persona.docChars`, `system.stableChars`; the pinned core rides the dynamic tail and counts in `context.snapshot` `dynamicChars` | Not ablated. The text is the owner's and theirs. |
| One felt cue (Care, Since, Reminded of, Settling, Body, Sound, Dream) | `mind.why` with lane `cue`: `winner.kind`, plus every candidate with its rank, score and source | `settings.inner_life_capsule` = false turns off the whole cue. To drop one source, `mind.reject` it with the source from `mind.why`. |
| Body line, plus the ops line beside it | A `cue` winner of kind `body`. The ops line only appears when the posture isn't the default. | `settings.organism_kernel` = false |
| Since we last talked | A `cue` winner of kind `since` | No switch of its own. Use the capsule switch. |
| Dream carry-forward | A `cue` winner of kind `dream`, source `dream:<id>` | `mind.reject dream:<id>`. There is no lane switch. |
| Memory packet and the personal lane (one memory or none) | `mind.why` with lane `memory`: `winners`, and the personal pick with its `lift` | `settings.memory_in_every_reply` = off turns off the whole packet. `mind.reject memory:<id>` drops one memory. |
| Moments, with corrections and disagreements as candidates | Turn trace `memory.promotion`; staged proposals in MemoryV2 | `settings.moments_lane` = false |
| After-turn memory call and its novelty gate | Turn trace label `noveltySkip`: `ran`, `ack`, `filler` or `repeat`. On 10-03 it was `ran` on 20 of 20 turns. | The gate has no switch. |
| Lessons that keep their origin (REM) | REM approval cards, and the origin moment when a lesson is recalled | `personality.rem_cycle` = false |
| Cares (what moved their, against what they cares about) | Turn trace `mind.cares` with the touched care ids and created/refused counts; `cognitive_receipts` rows `cares.applied`; `mind.inner_state` `cares` | `settings.inner_life` = false (the inner-life master). There is no lane switch. |
| On their mind (the care cue, ranked first) and when they brings a care up | A `cue` winner of kind `care`, with `careId`, its pressure as `score`, and `intention` true when it was their intention to bring it up | `mind.reject care:<id>` silences one care. The whole cue goes with `settings.inner_life_capsule` = false. |
| Cares at night (deepen, fade, settle, let go, the life card) | `cognitive_receipts` rows `cares.night` with settled, let-go, faded and deepened counts; the dream prompt's care block; `care.life` approval cards; `mind.inner_state` full `story` | `settings.inner_life` = false, or `personality.dreams` = false (the pass runs only after a committed dream). There is no lane switch. |
| Their hour (wander) | `data/studio/wander/wander.json`, and receipts `studio.wander_*` | `settings.her_hour` = false |
| Reach (they writes first), including an open care pressing to be said (kind `care`) | `mind.why` with lane `outreach`. `data/cognition/reach.json` holds what was offered, sent, declined, withheld and answered. | `mind.reject <subject>` stops one subject. There is no lane switch (a gap). |

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
