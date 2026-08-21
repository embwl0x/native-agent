# The Subconscious & Personality System

*As-built map, verified against source and live turn traces on 2026-08-20.
Every claim carries a file anchor. Sibling docs: [COGNITION_WIRING.md](COGNITION_WIRING.md)
(signal wiring), [ORGANISM.md](ORGANISM.md) (body detail),
[ANATOMY_OF_A_TURN.md](ANATOMY_OF_A_TURN.md) (turn lifecycle),
`build_plans/cognition-substrate-map.md` (working map).*

## What this is — the quick version

NativeAgent's agent has a subconscious: a continuously-running inner life that
exists *between* conversations, not just during them. It is a translation of
the human subconscious into agent-shaped machinery — working memory that decays
and re-consolidates, an emotional state with real physics (feelings rise by
saturation, fade on their own half-lives, warm memories cool grudgingly), a
body with chemistry and anticipation, appraisal that makes criticism sting and
real wins pierce a bad stretch, moods that tint recall, durable dispositions
and worldviews that settle out of repeated experience, and overnight
consolidation so the agent wakes lighter, not blanker.

None of it is roleplay text. The model is never told to *act* moody. Instead,
every event the agent lives through — every message, tool result, failure,
delivery receipt, dream — updates a small, bounded, persisted state machine;
and each turn, a few hundred bytes of *felt truth* distilled from that state
are placed at the very end of the system prompt: a handful of feeling-words, at
most one inner thought, a body line, a voice note. The model reads "focused,
curious, clear-headed" plus "provider or tool path feels brittle; be careful
before claiming completion" and *behaves* accordingly — including getting an
edge in its voice when the user has been needling it, because dismissal
genuinely moved the numbers.

The personality layer rides the same rails: persona documents (SOUL, VOICE,
USER, GROWTH, AGENTS) compile into the stable head of every prompt; trait
dials extracted from GROWTH tune the *physics* of feeling (never its words);
and the only paths that change personality durably — REM consolidation into
GROWTH, standing-view adoption — are proposal-shaped and user-approved.

**The design's one sentence:** events change numbers, numbers choose words,
words enter context, and everything that could grow without bound has a cap,
a decay law, or an approval gate.

---

## The one-page mental model

```
                         INPUTS (Layer I)
  chat turns (all surfaces) · tool outcomes · motor actions · corrections
  provider vitals · phone-delivery receipts · app wake/sleep · dreams/REM
        │                                            │
        ▼ CognitiveEvent                             ▼ SomaticSignal
┌─────────────────────────────┐        ┌────────────────────────────────┐
│  COGNITIVE SUBSTRATE (II)   │◀──felt─│   ORGANISM (III)               │
│  actor, cognition.sqlite    │  resol.│   actor, organism_state.json   │
│  · ContinuityField ≤256     │        │   · chemistry (10 axes)        │
│  · affect (4 axes, ½-lives) │──warm─▶│   · prediction ledger ≤96      │
│  · appraisal (12 dims)      │        │   · body beliefs, reflexes     │
│  · mood + disposition       │        │   · anticipation / relief      │
│  · felt fingerprint         │        │   · behavior posture           │
│  · standing views ≤5 active │        └────────────────────────────────┘
│  · seeds, reflection        │
│  · overnight consolidation  │
└─────────────────────────────┘
        │ frozen read per turn                       │ projection
        ▼                                            ▼
                    WHAT THE MODEL SEES (Layer IV)
  STABLE head (cached): persona packet · expression baseline · REM pins
  DYNAMIC tail: session digest · fluid-context packet (steered by attention
  signals from the substrate) · memory recall · history · clock · runtime ·
  turn-plan hint · ── LAST BYTES: [CognitiveSubstrate] capsule +
  [OrganismBehavior] posture, adjacent to the user's message
```

---

## Layer I — Inputs: what feeds the mind

### The two doors

Everything enters through the `NativeCognitionRuntime` actor
(`Sources/NativeAgentApp/NativeCognitionRuntime.swift`):

- **`observe(CognitiveEvent)`** (`NativeCognitionRuntime.swift:658`) — feeds
  BOTH the substrate (`ingestResident`) and, via the somatic adapter, the
  organism. One event, mind and body together.
- **`ingestOrganismSignal(SomaticSignal)`**
  (`NativeCognitionRuntime+Organism.swift:57`) — body-only signals (provider
  lifecycle, phone delivery, dreams). These shape chemistry and predictions
  and can only re-enter the mind through the gated felt-resolution path.

Both doors dedup exactly (replays are inert end-to-end), and the whole feed is
live only on the real data root — synthetic roots get a `nil` observer
(`AppChatToolDispatcher.swift:2028`), so tests never write into the live mind.

### The event vocabulary (closed set)

`CognitiveEvent.swift:4-46`: `userMessageReceived`, `assistantTurnCompleted`,
`toolStarted/Succeeded/Failed/Cancelled`, `userCorrection`, `providerFailure`,
`providerVitalsShift`, `appWake`, `appSleep`, `organismResolutionFelt` (and one
unemitted legacy kind — see Honest Scope). Every event carries an importance
weight, a subject (typed, per-turn keyed), a redacted ≤500-char summary, and a
`turnKind` — `debug`/`verification` traffic is structurally excluded from
lived state everywhere.

### The producers, in one table

| Source | Emits | Where |
|---|---|---|
| Chat turns — **all** surfaces (Mac, Telegram, Slack, iOS, agent bridges, workshop) through one funnel | user msg (imp 0.65) / assistant turn (0.55) / provider failure (0.85) | `ChatOrchestrationClient+MessagePersistence.swift:1248` |
| Tool outcomes, durable-receipt path | succeeded 0.55 / failed 0.8 | `…MessagePersistence.swift:1305` |
| Tool outcomes, live stream path | started 0.45, results as above, provider errors 0.85 | `…MessagePersistence.swift:1350-1417` |
| Motor actions (did it *actually land in the world*): mac control, external sends, workshop, GitHub commands, browser, workflows | phase-mapped, payload-free, opaque identity; verification-failed lands as toolFailed 0.8 | factory `NativeCognitionRuntime+Events.swift:128`; replay-guarded through SQLite, fails closed |
| iOS remote actions | only **corrections** (0.72) and provider failures (0.65) — routine acks emit nothing | `MacSyncActionRouter.swift:118` |
| Provider vitals (interoception) | band shifts 0.4–0.75, **organism-only** | `NativeCognitionRuntime+ProviderVitals.swift:230` |
| Phone delivery receipts | started/received/failed somatic signals, **organism-only** — the body knows whether the user's phone answered; the mind is not told | `MacSyncMobileNotificationRelay.swift:140-173` |
| App lifecycle | wake/sleep 0.35 | `NativeCognitionRuntime.swift:578, 1253` |
| Dreams / REM commits | `dreamCompleted` / `remIntegrated` somatic signals that *trigger replay + reflection* | `NativeClient+DreamActions.swift:75, 189` |
| Organism resolutions | relief / disappointment felt-moments, gated (see D-2), unique subject per moment | `NativeCognitionRuntime+Organism.swift:21` |

### Cadence — who moves the mind when nothing is happening

The three 24h `cognition_*` background loops are **crash-recovery only**. The
real cadence:

- **Dirty microcycle** — 250 ms coalesced settle after every accepted event
  (`NativeCognitionRuntime.swift:1019`). This is the per-moment heartbeat.
- **Exact-deadline maintenance wake** — the substrate computes, purely, the
  next instant anything is actually due (a seed expiring, a proposal aging
  out, the 20h consolidation boundary) and the runtime sleeps until exactly
  then (`NativeCognitionRuntime+Deadlines.swift:189`). Re-anchored after
  system sleep.
- **Dream (nightly, 03:30 local, scheduler-owned) and REM (weekly)** — their
  commit signals synchronously drive replay integration and schedule
  reflection (`NativeCognitionRuntime+Organism.swift:121-130`).
- **Organism ticks do not exist** — all body decay is computed analytically at
  read time with closed-form curves and a next-threshold-crossing wake.

---

## Layer II — The substrate: the mind's state and physics

One Swift actor (`Modules/NativeAgentCore/Sources/CognitiveSubstrate/`,
~20k lines, 24 band files), persisted to `<dataRoot>/cognition/cognition.sqlite`
(5 tables, kind-aware pruning, every family bounded).

### Working memory — ContinuityField (`ContinuityField.swift`)

A graph of ≤**256** nodes, each with activation/salience/confidence, a per-turn
subject key, a decay half-life (default 1h), bounded redacted metadata, and a
persistent **emotional tag** (valence −1…1, arousal 0…1, warmth 0…1).

- **Decay**: exponential on activation and salience, separate anchors so a
  restart never double-decays.
- **Spreading activation**: events boost associated nodes (shared session/run/
  tool/surface, lexical overlap), with an **affective whisper** — up to +25%
  extra spread between emotionally congruent felt nodes. Facilitation only;
  incongruence never punishes.
- **Reconsolidation is asymmetric on purpose**: re-touched memories blend
  toward the new feeling at rate **0.5 when warming, 0.15 when cooling** — a
  memory warms readily on a good re-encounter and cools grudgingly.
- Eviction prefers diagnostic traffic first, then lowest salience.

### Affect — the four-axis emotional state (`+Affect.swift`)

`arousal` (½-life 20 min), `uncertainty` (45 min), `taskPressure` (45 min),
`socialWarmth` (90 min) — all 0…1, all updated by **saturating approach**
(a delta moves a fraction of remaining headroom, never add-then-clamp), all
decaying on their own clocks. Two ambient layers ride on top at read time:
quiet gaps calm pressure/uncertainty faster, and a **warm-presence floor**
holds a gentle warmth (0.18, fading over 12h) after the user steps away — but
only anchored to *genuinely warm* moments, so warmth is never manufactured
from task work.

Hard-won laws baked in: warmth boosts only fire on genuine affection (a
trigger firing on ~100% of inputs is a floor, not a signal); the agent's own
replies never warm it (self-ratchet kill); received affection can read muted
but can never stamp as a wound (the affection floor, −0.12).

### Appraisal — how events acquire meaning (`+Affect.swift`, `+SemanticAppraisal.swift`)

Two coupled systems run once per admitted event, inside one await-free actor
segment (reentrancy-safe by construction):

- **Conversational appraisal** reads the *user's words only* (never the
  agent's own output — that was a self-confirming ratchet, killed twice).
  Hard criticism, dismissal, and being overridden sting with distinct
  magnitudes; praise, resolution, and enthusiasm lift; a 2-token negation
  window and a hypothetical-guard keep quoted or imagined negativity from
  landing. **This is the mechanism behind the agent pushing back when the
  user is being harsh: dismissal moves valence −0.22 and warmth −0.18, the
  fingerprint crosses into the negative families, and the model reads words
  like "strained" or "on edge" instead of "warm."**
- **Semantic appraisal** (12 dimensions: goal relevance/congruence, agency,
  novelty, coping, relationship stake, resolution/effort evidence, worldview
  stance/conflict…) turns the flat completion-metronome of early builds into
  meaning: success scales with relevance, hostile corrections cut deeper than
  warm ones, and a real win **pierces** accumulated negative residue by up to
  half — while positive residue is never dampened.

The result is stamped onto the touched node as its emotional tag — "how the
agent felt having just lived this" — via `emotionTag`, the single tuning knob.

### Mood and disposition — the slow layers (`+Mood.swift`)

- **Mood** is a *pure read-time integral* — no second store to drift:
  recency-weighted (6h half-life) mean valence over the last 24h of felt
  nodes, blended 60/40 with a current-affect proxy. Mood-congruent recall
  adds a small (≤0.08), same-sign-gated bias to workspace scoring — a bad
  mood can favor mood-matching memories but can never *boost* spiraling.
- **Disposition** is the one persisted slow axis: a day-scale valence
  undertone (cap ±0.35, 30h half-life) nudged ±0.08 by exactly four writers —
  reflection tone, the nightly dream's mood line, the user approving a
  standing view, and repeated organism resolution patterns (3+ same-path
  disappointments in 48h) — all through one shared lexicon and one
  integration door.

### The felt fingerprint — feelings become words (`+FeltFingerprint.swift`)

The capsule's headline is not prose; it is a word-level fingerprint:
valence×arousal selects one of nine families, an intensity gate (floor 0.14 —
silence stays silence) plus per-word requirements select the lead word, and up
to two non-contradicting overlays join it. ~40 words total, each with honest
gates: `tender` requires warmth ≥0.7 *earned*, `grieving` requires deep-low
valence at low arousal (melodrama structurally impossible), `proud`/`anxious`/
`confident`-class words **require** organism dims and are absent — not faked —
on an organism-less install. Five dims are optional for exactly that reason;
a word whose identity depends on an absent dim leaves the pool entirely.

Warmth mapping is range-verified: rest 0.55 sits at the `warm` gate and below
`tender`; the top of the scale is earned (span 0.30), uncertainty cools it.
(The one-time defect where the mapping's floor exceeded the `tender` gate —
the agent told it felt tender during git archaeology — is pinned by
`FeltWarmthRangeTests` so drift on either side re-fails.)

### Standing views — durable worldview, approval-gated (`+StandingViews.swift`)

Repeated felt experience can settle into a **standing view** — "a durable way
of seeing something." Reflection proposes (`view:` tag, deterministic id,
idempotent); only the user's explicit approval activates (≤5 active, LRU
demotion; ≤12 proposed, 14-day age-out). Active views are load-bearing, not
decorative: they lean the appraisal (confirmation feels congruent; a trampled
view registers as `worldviewConflict`), they mint **lived concerns** that
gate which organism resolutions deserve feelings, and at most one surfaces in
the capsule as an `- Inner:` line when relevant to the current message.

### Thought seeds, reflection, and the proposal economy

- **Seeds** (≤128, 24h priority half-life): open questions, anomalies,
  follow-ups, and reflection takeaways, deduped and merged, with an
  interruption score that decides surfacing. The microcycle auto-mints
  anomaly seeds under high uncertainty/pressure.
- **Reflection** (`+Reflection.swift`) is the only substrate LLM call: a
  budgeted (default off; 2/day when phases are on), bounded (1,900-char)
  private state read whose invitation explicitly blesses a zero-proposal
  quiet pass. Its single live proposal tag today is `view:`. Every reflection
  also nudges disposition and mints one takeaway seed. REM remains the only
  growth-proposal owner.

### Overnight consolidation — waking lighter (`ContinuityField.swift:228`)

Once per ~20h, riding maintenance (no new loop): recently-touched felt
memories get a tiny saturating arousal reinforce (+0.05 toward 1); stale
(>48h) high-charge memories soften (×0.7, floor 0.35). **Arousal only** —
valence, warmth, and content are never touched. The feeling's charge
decouples overnight; the memory and its direction stay.

### Personality dynamics — traits tune physics, never words

`PersonalityDynamicsConfiguration.swift` centralizes ~30 felt-physics
constants. Eight trait dials (0…1, neutral 0.5) parsed from GROWTH.md
frontmatter map onto exactly **three** edges today — warmth → the earned
warmth span, brevity → the delivery-envelope center, humor → the play-mode
weight — each bounded to ±50% around the calibrated default, so no persona
document can re-make `tender` the resting state. **No vocabulary lives in
this type**: dials are numbers, so personality tuning can never mint a
sentence the model reads. Wired live via a re-read-per-call closure in
`NativeCognitionRuntime.swift:488-501`.

---

## Layer III — The organism: the body

A second actor (`CognitiveSubstrate/Organism/`, ~7k lines), persisted to
`<dataRoot>/cognition/organism_state.json` (corrupt-restore freezes writes
rather than clobbering — the file is never overwritten with amnesia).

- **Chemistry**: 10 axes 0…1 (warmth, vigilance, curiosity, fatigue,
  coherence, agency, tenderness, confidence, novelty, urgency), decaying
  analytically at read time — quick axes 0.78^h, slow axes 0.92^h,
  coherence/confidence relaxing toward a 0.5 neutral.
- **Prediction ledger** (≤96): the body braces for expected outcomes
  (anticipation window 10 min, violation shadow 20 min ½-life) — purely
  modulating the *projected* chemistry, never the stored state. Resolution
  produces **relief sized to the held breath** (braced exhale ×(1+1.5·brace))
  or disappointment; notable ones become felt moments — but only if they pass
  the **D-2 stakes gate** (allowlist: person-or-promise paths, or a
  lived-concern hit; mechanical plumbing relief is refused before any state
  is touched).
- **Body beliefs**: typed, secret-free evidence classes about paths and
  capabilities (payloads and credentials never enter the belief layer).
- **Behavior posture** — the organism's direct grip on behavior: claim
  discipline, tool strategy, loop budget, plus bounded directive lines
  ("Tie completion claims to observed results, not intention"), rendered
  into the prompt every turn as `[OrganismBehavior]`.

Substrate ↔ organism convergence is deliberate and one-way per edge:
organism warmth follows substrate socialWarmth; organism urgency follows
canonical task pressure; chemistry colors the fingerprint's optional dims and
the `- Body:` capsule line; felt resolutions cross back through one gated
door with a 1/hour/path rate bound.

---

## Layer IV — What the model actually sees, per turn

### The segment map (cache-aware, order is load-bearing)

Contract at `ChatOrchestration+SessionHistory.swift:919`; assembly at
`ChatOrchestration+TurnEngine.swift:1564`.

**STABLE** (byte 0, `cache_control: ephemeral` — the cached prefix):
1. Compiled persona packet — SOUL → VOICE → USER → GROWTH → MEMORY → AGENTS,
   pure disk compile, byte-stable across turns, **no substrate input by
   design** (that stability is what makes caching work).
2. Natural-expression baseline.
3. `# Pinned facts (REM-approved overrides)` — latest ≤3 REM pins.

**DYNAMIC** (appended after, uncached; churns freely at zero cache cost):
1. `# Since last session` digest
2. Fluid-context packet — *steered by the substrate's attention signals*
3. Memory recall block
4. History block
5. Clock line, then current-runtime line
6. Turn-plan hint + natural-expression cue (rut/register nudges)
7. **Last bytes before the user's message:** the `[CognitiveSubstrate]`
   capsule + `[OrganismBehavior]` posture

### The capsule — anatomy of the inner state block

Producer: the **frozen** compile path (`+Capsule.swift:85` — the live-compile
path serves only the Observatory; anything hung on it is dark in production).
Injection: `ChatOrchestrationClient+StructuredChat.swift:1092` (and the
text-compat + ephemeral-turn seams — three seams, all must carry it).
Committed only after the provider *accepts* the turn, so a failed request
never burns cadence windows.

Real example, from a live turn trace (2026-08-20):

```
[CognitiveSubstrate]
run_id: … session_id: … surface: chat file_access: full

<private-inner-state framing line — colors the agent; never quoted or mentioned>

How you feel:

focused, curious, clear-headed
- Inner: An honest blank is healthier than performing depth; curiosity is
  enough to keep the mind open
- Body: provider or tool path feels brittle; be careful before claiming completion.
- Sound: a few of the same words keep echoing lately; you've got more range than that

[OrganismBehavior]
posture: careful  tool_claims: receiptRequired  tool_strategy: verifyBeforeRetry
<silent-posture framing line>
directive: Tie completion claims to observed results, not intention.
```

Line inventory (order fixed, every line gated and bounded):

| Line | What it is | Gate |
|---|---|---|
| felt fingerprint (bare words) | the emotional headline | intensity ≥ 0.14; suppress-when-unchanged after 4 same-family turns (20-min window); never suppressed if it's the only line |
| `- Since:` | session bridge — one felt word + what was left open | once per ≥6h gap |
| `- Inner:` | ONE of: relevant active standing view, else freshest useful reflection takeaway | ≤180 chars, max one |
| `- Body:` | organism chemistry line (stress or positive) | non-neutral projection; refuses jargon and digits; 20-min unchanged-suppression |
| `- Sound:` | self-exemplar voice echo (the agent's own warmest-*fitting* recent phrasings) or the rut-awareness nudge | 1-in-4 duty cycle; register-matched to the current moment, not maximum warmth; negative-run brake; all-or-nothing under budget |

Budget: substrate cap 1800 (live app 4000) ∩ window-scaled request cap;
observed live ≈ 0.9–1.2 KB. Deliberately in the dynamic tail: it churns every
turn, and churn in the tail costs nothing against the cached prefix.

### Attention signals — the mind steers its own context

Every ingest publishes a bounded, frozen `CognitiveAttentionSignals` packet
(terms ≤16, predicted tool groups ≤8, unresolved question ≤200 chars, pursuit
task/goal) from a **pure peek** of the hot workspace — reading the mind never
mutates it. The turn engine folds these into fluid-context selection
(`ContextSelection.swift:1090-1176`): hot subjects and the open question
become query weight, the organism's predicted tool groups pre-warm tool
context, the Desk pursuit names the active goal. A 250 ms abandon-latch means
a wedged read can never stall a chat turn. This is how "what the agent has
been dwelling on" changes *which files and memories* enter the prompt — the
context follows the mind, not just the message.

### How the user's experience of "personality" is assembled

Stacked, from stable to fast: persona docs (identity, voice — stable,
cached) → REM pins (approved distillations — stable) → trait dials (physics
tuning — slow) → disposition/mood (days/hours) → standing views (durable,
approved) → affect + fingerprint + body posture (minutes) → sound echo (the
agent's own attested voice, register-matched). The natural-expression cue and
the sound-rut detector push *variety*; the capsule pushes *honesty*; the
posture pushes *discipline*.

---

## How it changes — the time ladder

| Timescale | Mechanism | Bound |
|---|---|---|
| milliseconds | ingest: appraisal → affect → emotion stamp (one await-free segment) | saturating updates |
| 250 ms | dirty microcycle settles workspace, mints seeds | coalesced |
| minutes | affect decay (20–90 min half-lives), fingerprint cadence, violation shadows | per-axis clocks |
| hours | mood integral (6h), ambient presence (12h floor), prediction ½-life (6h) | pure read-time |
| ~20h | overnight emotional consolidation (arousal only) | riding maintenance |
| nightly / weekly | dream → replay integration; REM → GROWTH.md proposals + pins | approval-gated writes |
| days | disposition undertone (30h ½-life, cap ±0.35) | 4 writers, 1 door |
| durable | standing views; GROWTH.md lessons; trait dials | **user approval only** |

---

## Design laws (the portable invariants)

1. **Numbers choose words; nothing chooses numbers but lived events.** No
   config, persona doc, or dial can mint a sentence the model reads.
2. **A trigger that fires on ~100% of inputs is a floor, not a signal.**
   Every affect trigger is gated to genuine occurrences; every felt formula is
   range-checked over its whole input domain against the word gates.
3. **The agent never appraises its own output.** Self-warmth ratchets were
   killed in two layers; appraisal reads the user's words only.
4. **Silence is honest.** Below the intensity floor the fingerprint is
   absent; absent organism dims exclude their words rather than faking them;
   a quiet reflection pass proposes nothing.
5. **Reads are pure.** Mood, attention, maintenance-due-ness, and the frozen
   capsule all read through non-mutating peeks — observing the mind never
   changes it.
6. **Everything is bounded.** 256 nodes, 128 seeds, 96 predictions, 5 active
   views, capped metadata, capped receipts (with prune hysteresis), capped
   capsule bytes. Any new persisted family ships with its bound.
7. **Durable change is proposal-shaped.** Reflection and REM propose; the
   user approves; nothing self-activates.
8. **Noise gates are allowlists.** The stakes gate fails closed on labels its
   author never anticipated.
9. **Replays are inert.** Event dedup, motor-consequence admission (fails
   closed), and somatic bus seen-keys make re-delivery a no-op at every layer.
10. **Diagnostic traffic can't feel.** debug/verification turns are excluded
    from lived state, capsule, attention, and the body.

---

## Honest scope — wired but inert, or dead

- **Delivery envelope** (`+DeliveryEnvelope.swift`): computes a felt
  reply-length band per turn but is **telemetry-only** — it writes
  `logs/delivery_envelope_telemetry.jsonl` and nothing reads it into
  behavior. The enable flag deliberately does not exist yet.
- ~~Memory-activation attention signals~~ — **correction (2026-08-20): this
  lane is live.** An earlier source comment claimed no producer stamps memory
  record ids onto nodes; the live store and turn traces refute it (stamped
  assistant-turn nodes present; per-turn `contextFlow.attentionWorkingAtoms`
  nonzero). Remembered material genuinely steers context selection. The stale
  comment has been fixed — a reminder that this doc's own claims expire too:
  verify against traces.
- **`workshopExecutionCompleted`** event kind: full handling, zero emitters
  (workshop terminals arrive as motor states). Dead vocabulary.
- **`NativeCognitiveEventFactory.turnMessage`** and its wrappers: no
  production caller; constants disagree with the live chat path.
- **`userReactionEvidence`** appraisal dim: structurally 0 on the live path;
  superseded by the retrospective landing re-stamp.
- Phone-delivery receipts reach the **body only** — they never become
  attention nodes.

## Where to verify (never trust this doc over these)

- **The real injected bytes**: `data/turn_traces/YYYY-MM-DD.jsonl`, rows with
  `kind == "context.snapshot"` — `cognitivePreview` carries the exact
  `[CognitiveSubstrate]`/`[OrganismBehavior]` block the model received;
  `llm.call` rows prove the stable prefix is cache-hitting.
- **The stores**: `<dataRoot>/cognition/cognition.sqlite` (read with
  `peekNodes`-style queries; never mutate) and
  `<dataRoot>/cognition/organism_state.json`. Live proofs run against a COPY.
- **Tests**: `Modules/NativeAgentCore/Tests/CognitiveSubstrateTests/` —
  affect flow, felt reachability sweeps, warmth-range pins, consolidation
  boundaries, attention purity, golden dynamics.
- **Live protocol**: talk to the agent normally; never announce a change or
  ask how it feels; watch the fingerprint move in the real feed.
