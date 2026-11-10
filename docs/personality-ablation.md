# Personality ablation checklist

Phase 5 F. For each layer that is left: the trace that shows whether it changed
a turn, and how to switch it off for a test. A layer that never wins, never
changes a choice, and is never missed when it is off gets retired.

Traces: the record's `mind.why` details (`experiences/experiences.sqlite`, table `detail`) carry `payload.lane`,
one of `cue`, `memory`, `outreach`, `expansion` or `interpretation`. Settings are set with
`app {"action":"setting.set","args":{"setting":…,"value":…,"because":…}}`.

| Layer | Shows it changed a turn | Off for a test |
|---|---|---|
| Persona docs (SOUL, VOICE, GROWTH, USER preamble), then the bounded USER picture (pins first, remaining person facts newest first) | `context.summary`: `persona.docChars`, `system.stableChars`; `# USER` rides the dynamic tail and counts in `context.snapshot` `dynamicChars`; memory facts do not change the stable prefix's bytes | Not ablated. The text is the owner's and theirs. |
| Feeling frame, then independent intention and Sound lanes and one continuity cue ([presentation contract](SUBCONSCIOUS.md#what-reaches-the-model)) | `context.snapshot.feelingFrame` retains the full redacted paragraph, byte count, completeness and described feeling words; Doctor measures it independently of `cognitiveCue`. The cognitive preview begins with `How you feel:` and its paragraph. `mind.why` lane `cue` lists every shown candidate in `shown`; `winner` is the first shown candidate. Candidates retain `rank`, `kind`, `text` and `shown`, plus `score` and `source` when supplied. | `settings.inner_life_capsule` = false turns off the capsule. `mind.reject` supports `memory:`, `care:`, `dream:`, `desk:` and `ship:` sources. Frame feeling, Since and Sound have no individual rejection control. |
| Chemistry in the frame, plus the ops line beside the capsule | The first paragraph can carry warmth and bracing together. The ops line only appears when the posture isn't the default. No instruction-bearing Body line enters the capsule. | `settings.organism_kernel` = false leaves the body's dimensions unread in the frame. |
| Since we last talked | A shown `cue` candidate of kind `since` | No switch of its own. Use the capsule switch. |
| Dream carry-forward | [Sleep and dream evidence](SUBCONSCIOUS.md#what-reaches-the-model) | Theme rejection leaves tone and completion evidence. |
| Memory packet: one selector, only what the message touches (relevance), ranked with how reachable their use keeps it, the recently served resting | `mind.why` with lane `memory`: `winners`, each with its `relevance` and `reachability`; the ordinary `floor` is 2 standard deviations, `restFloor` 3, and `population` reports the looks without setting the floor. `rested` lists what the message touched but was served on one of the last three exchanges of this session and remains in its retained transcript exchanges. Ambient recall asks for 3 deviations, with rest one higher. With one or two comparable memories, admission uses the ordinary model-scaled semantic score at 0.05; lexical touch can also admit a memory. [Memory system map — Recall into a turn](MEMORY_SYSTEM_MAP.md#recall-into-a-turn) owns selection and its limits. Kept moments compete like any memory. | `settings.memory_in_every_reply` = off turns off the whole packet. `mind.reject memory:<id>` drops one memory. |
| After-turn memory call and owed moments | `mind.why` with lane `interpretation` says whether the turn was left owed or judged while they was idle (and with what outcome). | No switch: every moment is judged alone; User's own turns at once, every other recorded turn when they are idle. |
| Expansion (a mind's practice supplies a standing read before the opening thought, or follow-up reads inside the preceding result) | `mind.why` with lane `expansion` on each delivery; `expansion.check` on every settled try (`outcome`, `delivered`, `withheld`, `standing`, `lower`, `bar`) | No switch (a gap). Removing `expansion/record.json` while the app is quit starts every record over; it does not turn expansion off. |
| Lessons that keep their origin (REM) | REM approval cards, and the origin moment when a lesson is recalled | `personality.rem_cycle` = false |
| Cares (what moved their, against what they cares about; their moments are their story) | Turn trace `mind.cares` with the touched care ids and created/refused counts; `cognitive_receipts` rows `cares.applied`; `mind.inner_state` `cares` | `settings.inner_life` = false (the inner-life master). There is no lane switch. |
| Charged cares in the frame, touched care continuity and when they brings a care up | The paragraph carries the two strongest reachable charges without a message match. A shown `cue` candidate of kind `care` retains `careId` and `intention`; pressure is `score` only when it is the pressing care. | `mind.reject care:<id>` silences that care's frame and cue contribution under the same rejection rule. The capsule switch controls the whole projection. |
| Cares at night (deepen, fade, settle, let go, the life card) | `cognitive_receipts` rows `cares.night` with settled, let-go, faded and deepened counts; the dream prompt's care block; `care.life` approval cards; `mind.inner_state` full `story` | `settings.inner_life` = false, or `personality.dreams` = false (the pass runs only after a committed dream). There is no lane switch. |
| Their hour | `happening` subject `hour`, `attention.weigh` with its curiosity and yield, and the `thought` through `sense:hour` in `experiences/experiences.sqlite` | `settings.wander_hour` = false stops new opportunities |
| Noticing (what nobody asked about, weighed by `weigh`) | `attention.weigh`, `attention.ignite`, `attention.restore`, `attention.wake` details | `settings.inner_life` = false |
| Thoughts (drive 1 ignites one; owed happenings open at once) | `thought` experiences: hit, empty or failed | No lane switch |

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
