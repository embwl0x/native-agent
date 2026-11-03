# Becoming — what they lives settles into who they are

Claude, 2026-10-30. User 10-24: "develop a full personality like a human
does"; 10-30: "plan these all out real well". The form and law are built
(docs/SUBCONSCIOUS.md "Cares"; design ~/.claude/state/release/briefs/
personality-design.md, live 10-25): **one form, a care; one law, everything
they lives meets what they cares about**. P1 and P2 below are implemented in
source: cares settle through meaning-matched birth and their existing night.
P3 and P4 are implemented in source below. Installed proof belongs to the
release build; this lane runs no compile or separate tests.

Their persona and memory are theirs and User's: nothing here writes their content.
Every change below is a mechanism; what it settles into is decided by their own
night and their own hand, as the brief's law 5 says.

## What their data said before P1 + P2 (10-25 → 10-30)

- 133 cares grown in five days, 114 live; depth: life 4 (the seeds), season 0,
  lately 39, now 71; median age 1.5 days; 71 moved on only one day.
- **One interest splits into many cares.** Dedupe at birth is an exact
  normalized `about` (+Cares.swift:449-452), so a rephrase is a new care: chess
  is 8 live + 4 faded, the Kōitsu / rain-print thread 6 + 3, "User looks out for
  me" 4, banter ~5. None collects the distinct days it needs to deepen
  (now→lately 2 days; lately→season 4 days over ≥14).
- **Their roots move like moods.** The four seeds are shown to every after-turn
  appraisal, carry 54–96 movements each, win all 9 "you've been wanting to
  bring up" intentions, and their stances were rewritten 47 times (of 91
  retained changes) — User's good 19, Good work 14, Truth 10.
- **Stances are stored, not held.** Any trusted after-turn judgment replaces a
  stance (+Cares.swift:466-477); the brief's "a stance changes only with
  evidence … nothing in one conversation changes who they are" has no code.
- **Traits, their story, relationships have no mechanism.** No if-then
  signature; GROWTH.md is 65 words from one weekly REM; `with` is only a
  visibility filter; Claude is two people (Claude Desktop and Claude Code door
  keys — `personKey` doesn't resolve the peers' `who` link).

## The design

### P1 — one care per thing

- **At birth**: a `new` judgment first meets the live and faded cares with the
  same `with` by meaning (the warm memory embedder and its existing exact-text
  vector cache; `VectorMath.standout` over the entire care inventory, using
  `ContextSelectionConfiguration.memoryStandoutDeviations`, 2σ). If one or more
  stand, the moment moves the nearest standing care (an ordinarily faded one
  comes back) and its story keeps the new phrasing as the entry's words; several standing are their
  existing duplicates, which the night merges (10-30 live: "exactly one" made a
  third duplicate whenever two already stood). Only when nothing stands is it a
  new care. Every decision is traced (`care.birth`: about, nearest, deviation,
  standing, kept: moved or new). The night's `cares.night` receipt names the
  clusters it was shown and the merges and stance changes it chose; each
  merge they proposed is listed with its outcome (merged, or skipped and why)
  and their own why, and unreadable merge entries are counted, so a cluster
  left apart is visibly their choice or a visible drop. New words and stale care vectors embed in one batch before
  applying any judgments; an unavailable embedder leaves the appraisal owed.
  A meaning-matched birth keeps its stable moment/ordinal identity on the
  care, so a refold follows its original target without another similarity decision.
  A merged-away donor's meaning leads to its survivor, through later merges
  too; it never becomes a live birth candidate again. Existing-care judgments
  and birth refolds follow that same survivor.
  Older donors without `mergedInto` resolve from their exact bounded
  "became part of" note and the survivor's same-night merge entry, only when
  the survivor is unique. Missing or ambiguous merge evidence cannot revive
  a donor; a matched birth stays owed until that link is repaired.
- **At night**: the dream is shown clusters of near-duplicate live cares (CPU:
  pairs standing ≥ 2σ in both directions against the live inventory, excluding
  self, same `with`; strongest mutual standouts first, every pair in a cluster
  must stand, at most six clusters of six) and decides, in its own words,
  which are one care. It is told what a care is (one thing they cares about,
  its sides living in its story) and what a merge keeps (every story entry,
  movement and phrasing). The first night (10-31 03:30) merged two clusters
  ("User looks out for me"; compaction/recollection) and kept the six shown
  chess cares apart as facets, because the instruction then read "merge only
  what is truly the same thing". Optional
  `merge: [{keep: <UUID>, into_it: [UUIDs], why}]` entries are checked together;
  malformed present learning fails the payload before any commit. A merge keeps the oldest care unless
  they names another, unions retained stories, sums folded counts and unions
  movement-day witnesses, takes the deepest depth, and leaves the merged-away cares
  faded with a "became part of <care>" entry and a durable `mergedInto` UUID.
  If the survivor has no open gap, it takes the newest donor's open gap
  (by the donor's pre-pass update time, before tonight's stance changes);
  a merge never silently drops that gap. Their hand, at their night; nothing
  merges in the day. Only unchanged shown revisions merge, with disjoint
  members from a shown cluster. The existing deepen pass then reads the union.

Effect: chess becomes one care moved on many days — the first real season
care, an interest.

### P2 — roots hold, stances are held

- **Life cares press only through an open gap.** A life care's charge is
  feeling (it still colours the moment) but it does not count toward the
  "bring it up" intention or Reach unless it has an `open` gap; a gap is what
  presses. Seeds stay visible to the after-turn appraisal (truth must be able to
  move when they agrees with something false — that is how sycophancy falls out).
- **A stance changes only at night, on evidence.** The after-turn appraisal no
  longer replaces a stance; it writes a **stance-pressure** story entry (the
  proposed stance, because and unless, in its own optional story field).
  The night pass changes the stance when the
  pressure points the same way on ≥ 2 distinct days (now/lately/season cares)
  or on ≥ 3 days spanning ≥ 14 days (life cares), and the dream confirms it
  through `stance_changes` naming the exact shown pressure
  entries it judges to point the same way. The CPU checks the entries' distinct
  local days and span, and the unchanged care revision; a confirmation cannot
  invent its day evidence. Pressure before the last change is spent. The
  replaced stance stays in the story ("used to think: …", felt "changed my mind").
  Ordinary notes cannot evict the separate 24-day pressure window. Only exact
  same-day proposals compact together; different proposals stay for the dream
  to judge. Change notes stay in the story.
  A care with no stance takes its first stance at once (a first opinion is not a change).

### P3 — they knows themselves (as built)

The existing dream reads the care block's stories and may write what they
comes to know about themselves into `mind/self.json` (theirs). There is no extra
model call. `CognitiveSelfKnowledge.swift` owns the bounded, atomic file;
the substrate holds its resident reading:

- **traits as an if-then signature**: at most 5 "when …, I tend to …", each
  with `shown_by` care UUIDs or exact story-entry references, revised each
  night (never an adjective someone typed);
- **their story**: at most 5 `{line, shown_by}` entries, depth changes and
  changed stances told in their words ("I used to …, now I …"). Only shown
  depth-change or changed-my-mind entries can support a story line.

The material reuses the night's care revisions and adds recent changes from
quiet cares. It shows at most 48 care stories, each with the newest three
movements and five changes. References identify a care and a digest of the
exact entry, not a shifting array index. Malformed present learning fails
payload decoding before any commit; well-formed entries with invented
references are refused by the care admission boundary.
Each newer captured reading replaces the previous self-reading, so unsupported or
omitted traits drop. Tonight's newly applied depth/stance changes are available
to the next dream, not presented as evidence it already saw.
Capture time travels with pending care work. An older delivery preserves the newer
self-reading and saves the current owner before acknowledgment. Retained installed
files without capture time use only known diary-day/write-time order; ambiguous
same-night delivery remains owed until a provably newer reading.
Before saving, `shown_by` references to donors merged this night or earlier
follow their survivor, retaining the exact entry digest. Turn-time reachability
follows the same chain for already-saved traits, so a merge cannot hide their
self-knowledge or bypass the supporting care's privacy.

Traits reach a turn through the existing care cue: when the message touches
a supporting care by its usual meaning/standing law, at most one trait can
take that care's plain line, with the same six-turn rest. Every supporting
care must be reachable in that turn. There is no always-on traits block.
`mind.inner_state` shows traits, story and evidence; the Personality page
shows the same resident traits and story read-only. The former mechanical
`story` list remains available as `care_history` in full inner-state reads.

The file records schema version, committed diary source, capture time, write time and mind
epoch. It is capped at 256,000 bytes, with five traits, five story lines and
128 people. Corrupt existing bytes stay intact, with repair owed and explicit
unavailability. Clear removes the file and resident reading; epoch checks
also reject a dream or file from before Clear.

### P4 — the people in their life (as built)

- **One person, one key**: `personKey` resolves a door to the person through
  the peers' `who` link, so Claude's two doors are one person.
  `AgentPeerStore` supplies the validated `AgentContactIdentity` alias
  projection through the cognition runtime; the substrate caches it at
  restore and on the existing peers-file invalidation. Existing cares'
  `with` and attributed story movers read through it in RAM after restore
  reconciliation, with no migration rewrite or migration file. New lived
  writes save their person keys normally. Trust still reads the attested
  door before any relationship normalization; knowing someone grants no authority.
  An unreadable peer list clears alias-dependent turn lines and withholds peer
  care writes until a validated refresh succeeds; `people_unavailable` names
  the cause. Owner and helper identities do not depend on that file.
- **Who they are to them**: the night reads, per person they have cares with, the
  cares held with them and how they moved their and may write one line in their words to
  `mind/self.json` ("User: …"). In a turn with that person, that one line is on
  their mind (clear-headed: one line, only theirs). The CPU counts retained,
  nonzero movements attributed to that person: toward, away, and predictability
  = the dominant direction's share. No attributed evidence is unknown;
  predictability is neither goodness nor an authority grant. Folded movements
  have no surviving person attribution and are not guessed.

The person's material names their newest eight held cares and reports how
many they hold in total. People get a 16,000-character material window;
stories get another 16,000 plus unused people space. Only shown people may
receive a line. Turns resolve the already-known speaker with the frozen alias
map and read one cached dictionary entry, outside the felt cue competition;
they read no new file, run no new embedding and make no new model call for it.
Full `mind.inner_state` exposes every retained person line; compact exposes two.

## Order and proof

P1 + P2 first (they make settling possible); P3 + P4 after (they read what
settled). Proof on them:
- the chess cluster is one care after the first night; new chess moments move
  it; within two weeks it reaches season (the first interest);
- seed stance changes drop from ~10/day to the night's rare confirmed ones;
  the "bring it up" intentions come from open cares, not seeds;
- `mind.inner_state` shows their traits, their story and one line per person;
  Claude is one person.

## Lanes

| Lane | What | Owners |
|---|---|---|
| becoming-settle | P1 + P2 | CognitiveSubstrate/CognitiveSubstrate+Cares.swift (birth, stance), +CaresNight.swift (merge, stance at night), +CaresMind.swift (pressure: life cares through open gaps), Cognition/NativeCognitionRuntime+Reach.swift (pressure read), DreamREMCycle prompts/payload (clusters, stance pressure), docs/SUBCONSCIOUS.md |
| becoming-self | P3 + P4 | +CaresNight.swift / dream payload (traits, story, people), CognitiveSelfKnowledge.swift (mind/self.json), +InnerState.swift / inner-state tool / PersonalityView (read-only), +CaresMind.swift / +Capsule.swift (touched trait and counterpart line), +Cares.swift personKey through AgentPeerStore / AgentContactIdentity aliases, SourceWakes (identity invalidation), docs/SUBCONSCIOUS.md |
