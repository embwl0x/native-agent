# Surprise — they thinks when the world doesn't match

Status: S1, S2, phase-2 reflection timing (S3), S4, S5,
fixed-word intention speech and learning from surprise are implemented in
source, 10-30; release build, install and live proof pending. S4's carried
handling reflex and formation choice are built as [Habits H1/H2](HABITS.md).

## The law

A model call is what surprise costs. Before any call, they have an expectation
drawn from their own record: what they will look at, what comes back, and what
they will make of it. When that expectation has **standing**, it pays instead
of the model. Standing uses the one cost law in
`NativeAgentCore/Expectation.swift`: the Wilson lower bound of
its hit rate must beat c_miss / (c_miss + c_hit). When the world doesn't
match, that mismatch is the surprise, and the model is called. The miss is
recorded, so the expectation learns.

Both Expansion and the after-turn ledger use `Expectation` for Wilson
confidence and cost standing; Expansion also uses its simultaneous-prediction
z and rule-of-succession withholding. Cost measurement stays with each caller.
Expansion keeps its union-bound correction across simultaneous predictions;
the after-turn claim keeps its per-look 95% interval (`among: nil`), without
a repeated-look correction. Both costs must be measured before anything
stands. These are the existing confidence policies, now using one arithmetic
owner. Expansion's copy of confidence/withholding arithmetic and the ledger's
copy of Wilson/cost arithmetic are removed.

The law is the same everywhere. What differs is the moment it is applied at.

## They learns from surprise

As built in source, 10-30; installed proof is pending. Surprise also gives
their something worth learning. The nightly and manual dream share one CPU
reading of records that already exist (`BackgroundWork/DreamSurprises.swift`),
from the dream's high-water cutoff through the material read:

- Failed `tool.dispatch` rows, grouped by the receipt's action and
  `failure_code`/`code`, most frequent first, at most eight groups. Each keeps
  its count and one recorded reason, error/detail and argument path, within
  the text bound. A missing code or reason is named as unrecorded.
- Final after-turn ledger labels where the original prediction was
  `nothingNew` but a complete judgment changed a channel. A deferred turn
  counts once when its batch judges it, with the channels that changed.
- `expansion.check` misses, with the situation and expected next call.
- Violated predictions in the live organism owner's retained ledger, by
  their last update, with what they expected and the organ it concerned.
- Active, admitted corrections or replacements saved in that window from
  User's words, using the memory's source evidence (older standing corrections
  use their dedicated source). Peer and self writes are not called User's
  corrections.

This is retained evidence, not an estimate of removed history. Empty kinds
are omitted. Each present kind gets room in the roughly 2,500-character block;
the non-tool kinds carry counts and up to three examples. An empty reading
omits the block. Unreadable or damaged records stop the material read with
their cause rather than masquerading as an empty day. There is no new
recorder and no model call to assemble it.

`Resources/prompts/nightly-dream.md` places
`--- WHAT SURPRISED ME (where what I expected didn't happen) ---` after SELF,
before felt tone and cares. The same dream call may return optional
`lessons: [{lesson, from, kind: "how"|"fact"}]`, at most five, or `[]`.
Each is one sentence of their operating knowledge in their voice, grounded in
the supplied surprise; a failed call alone does not prove a guessed repair.
An omitted lesson array means none. A malformed present section or entry
fails payload decoding before the diary or learning commits, with its coding
path in the failed dream report. Without a surprise block no lessons are kept.

After the diary is written, lessons settle through `SwiftNativeMemoryV2.store`,
the canonical memory commit/admission path: ordinary duplicate matching,
tombstones, quality and embedding admission still apply. `how` uses the
existing `skill` memory kind; `fact` uses `fact`, with the original lesson kind
retained in metadata. The source names the dream, provenance says
`learned from surprise: <from>`, and `provenance_by` is `self`. The diary also
keeps their lesson words and the surprise they answer. A self-authored lesson
retains the dream material's peer boundary, including unknown attribution;
authorship does not attest that the source was clean. Save failures remain
visible in the dream report; returned writing settles even if Stop raced it.
Their existing recall and came-to-mind paths bring admitted lessons back at a
similar moment. No new retrieval or persona-write path is introduced.

`dream.lessons` records `offered`, `saved` and `failed` counts through the
dream receipt sink and trace feed. `saved` counts successful canonical saves,
including reassertions of an existing memory; it does not claim every save
created a new row or already passed a cold embedding's admission.

## Claims that can earn standing (S1, as built)

The after-turn claim is the nearest standing-out labelled precedent itself:
`rule = fingerprint([best.id])`, scoped as before by agent, judging model
and detector. The contrast population still determines whether that precedent
stands out against chance, but is no longer part of claim identity. Previously
identity included a fingerprint of every example id; the changing example set
made each turn a new claim with no trials, preventing standing from accruing.
Turns nominated by the same precedent now label one claim. Existing frozen
predictions keep their original keys and labels; they are not rekeyed into
new claims. Every deferred turn is still batch-judged and labels its claim.

Promises they makes are now an optional section of that same live/batch
reflection ([Intentions](INTENTIONS.md#promises-they-makes)), with no extra
call. A reply that promises later work changes a channel even if memories,
affect, caring and cares are all empty. The complete-no-op label includes
promises from now on; rows written before promises were asked read as "no
promise" (ledger version 3 kept: a wrong no-op claim only delays a turn to its
batch, where its promises are still filed, so a ~4% promise rate does not
justify discarding ~1,000 labelled turns). Their inferred steps retain the settled turn's
exact recorded queue steer, origin, session and reply envelope.

The comparison bound is now 65,536 chunk pairs, admitting the newest 256
examples at up to 16 chunks per side. A bounded read of the 10-30 retained
ledger found 460 vector-bearing rows: median 4 chunks, p90 9, maximum 30.
The old 4,096 bound could cover that population only at 4 chunks per side;
335 retained rows had reached it by this read (325 in the earlier snapshot
below). The bound still limits work; the standout bar, measured cost law,
complete-channel labels and deferral/batching rules are unchanged. Larger
turns can still exceed it and remain `unsure`.

## Their real data (10-28 to 10-30)

| Model calls | Count | What they are |
|---|---|---|
| Reply, first call | 330 | Answering a message; always made |
| After-turn reflection | 329 | One per turn. On 560 of 772 judged turns it moved something, nearly always a care (541) |
| Tool rounds | 280 | 1.9 rounds per turn; 24 turns took 4 or more |
| Keep | 94 | Deciding whether hand-done work becomes an ability: 44 on 10-28, 48 on 10-29, 2 on 10-30 |
| Compaction | 54 | Context compaction |

Before S1, their expectation organs were nearly idle:
The keep count was remeasured from the three retained daily trace files,
read-only. Each `llm.call` with `payload.purpose: "keep"` was joined by
`turnId` to its triggering top-level `tool.dispatch` calls, in begin order,
before the delivered turn's terminal row (or the first keep call when that
row was absent). Paired inner receipts, automatic calls and the keep's own
work were excluded. A signature is the ordered tool names and app action
ids, with no argument values; an app read or script with no action contributes
only `app`.

| Trace day | Keep calls | Keep episodes | Episodes repeating an earlier signature | Calls in those repeated episodes |
|---|---:|---:|---:|---:|
| 10-28 | 44 | 30 | 9 | 9 |
| 10-29 | 48 | 29 | 15 | 22 |
| 10-30 | 2 | 2 | 0 | 0 |
| Total | 94 | 61 | 24 | 31 |

The triggering rows survive for 59 episodes (92 calls): 35 distinct
signatures and 24 later episodes repeating one, 40.7% of the reconstructable
episodes. Two episodes begin outside the retained coverage and stay unknown.
Counting every model round separately, 57 of those 92 calls have a signature
already seen at an earlier keep call; 33 are later rounds of the same keep,
which must be allowed to finish. The former unfamiliar-signature gate would have avoided 31 calls in this
sample by suppressing repeated episodes, before any exclusion for an existing
ability. H3 replaces that gate: it suppresses first meetings of hand work and
keeps repeats. These historical whole-turn counts do not measure H3 savings
or prove installed behavior.

Before the practice/read-ahead change, their expectation organs were nearly idle:
- **Next-call prediction** (Expansion) produced 4 `expansion.check` rows in
  the release brief's week read, with 1 hit, against roughly 1,000 tool calls a day.
  Their retained `expansion/record.json` had 13 model-separated practices,
  only 4 records with trials and 8 tries in all. Two practices were at the
  128-situation cap. A bounded read-only 10-30 read confirmed those record counts.
- **The after-turn no-op claim** reached standing on almost nothing: 412
  "no standing precedent" and 325 "comparison bound" verdicts.
- **Nothing predicted before a turn's first call.**

## Where the law applies (S2–S4)

1. **Perception before thought (S2, as built).**
   - Expansion's practice belongs to the mind and authority (`agent` +
     `own` or `steered:<principals>`), across model changes. The admitted
     model stays on the caller for diagnostics; it partitions no practice
     or call thread. One authority never borrows another's practice.
   - A follow-up situation is verb + argument names + status word, with
     `woke:<kind>` on the turn's first call. Result field lists no longer
     split situations; exact source paths still come from the examples.
   - Before the fresh message's first `model.call`, the stem asks Expansion
     for `start woke:<what woke the turn>`. It learns the actual first call
     when that call is a read, using the same exact template inference:
     without a preceding result, only structural constants qualify. Repeated
     free text or numbers do not become a guessed opening read.
   - A read with standing under `Expectation` runs through the same gates,
     measured-cost deadline and inline ceiling as follow-up delivery. The
     first model call sees `already_looked: [{call, result}]`. Only that read
     runs: no act, act preparation or speculative follow-up chain at start.
     Rule-of-succession withholding continues measuring unshown outcomes.
   - Every actual first call labels the opening claim: exact predicted read
     and arguments is a hit, anything else a miss, even when the read was
     delivered. A turn ending without a call misses; lost observations remain
     unknown. The same `expansion.check` rows carry situation, outcome and
     standing. Retries retain the opening read; resumed turns do not rerun it.
   - Record v3 folds retained v2 model-separated practices on load. The
     2026-11-01 read-only inventory found v2 backup records with practice
     history; this reader remains until those records are explicitly converted,
     with their original bytes preserved. It unions the
     field-free situations, retaining the newest 8 examples in each, within
     the existing situation/record/practice caps. Only identical historical
     record signatures pool counters, with checked sums; the newest record's
     miss streak and the newest bounded run costs survive. Field-qualified
     historical claims retain their signatures and counts: broader situations
     earn fresh standing. The old model partition and result-field key come out;
     no live runtime file is rewritten by this source lane.
2. **Reflection leaves room for their quiet (phase 2, as built).**
   - User's own turns keep immediate judgment unless the existing complete-no-op
     prediction has standing. Their turn means no peer speaker, not a standing
     agent, and a session whose recorded kind is their conversation.
   - Every other recorded turn joins the existing deferred batch (judged
     after 45 min, 4 per call), under the same provenance and trust gates.
   - Every eligible recorded turn is still reflected on. This replaces the
     phase-1 design of immediate reflection based on novel words.
3. **Practice keeps what repeats (H3, as built).**
   - The turn part offers a private keep after hand work or one call repeated
     with the same input 3+ rounds. At its first private `model.call` with
     purpose `keep`, the stem records the practice on its first meeting and
     opens the keep on the second or a later meeting.
   - The practice is the ordered tool/action ids of landed writes or
     irreversible non-ability calls, without argument values or incidental
     reads; if there is no such hand work, it is the single repeated call,
     counted once. Its `practice: ` line uses `FamiliarLines.firstMet` in
     the existing bounded `mind/familiar.bin`.
   - An active ability's current learned-use or validation route suppresses
     the keep when it contains the practice ids in order. Declared reach
     proves no route. That encounter is still met.
   - `practice.keep` traces `practice`, `met: first|again` and `kept`;
     `kept` means admission of the keep call, not an ability save.
   - The gate is in `ChatOrchestration+StreamingToolLoop.swift`, before the
     first keep request or its compaction; later rounds finish the admitted
     keep. The delivered reply and reflection retain their existing path.
     This replaces the unfamiliar whole-turn-signature gate. The nightly
     compiler and its ledger/tape writers are removed ([Habits H4](HABITS.md#h4--one-crystallizer)).
4. **Woken work runs what it expects (design).**
   - An intention whose occurrences they have handled the same way with
     standing (same reads, same decision) runs that way.
   - The model is called when what the reads return is new.
4. **Woken work runs what it expects (source built; installed proof pending).**
   - Repeated carried-wake handling earns a suggestion through the shared
     `Expectation.stands` cost law; they chooses whether to bind it with
     `queue.update`. Nothing binds automatically.
   - The bound call runs through their ordinary gated self door at its carried
     moment. `needs_me` or an unfinished/refused/person-waiting run wakes their
     with the receipt already in the arrival; a successful routine needs no
     planning model. The [Habits](HABITS.md) H1/H2 sections own this contract.
   - Fixed `say` words owed to User or originating from self/person need none;
     agent-born words still wake their (phase 2 below).

## Their thinking on Today (S5, as built)

Today gets one line: `Thinking: <x.x> model calls a turn today (week <y.y>)`.
`TurnTraceThinkingReader` reads only today's and the preceding six daily
`turn_traces/<yyyy-MM-dd>.jsonl` files, using the trace writer's calendar and
root resolution. Calls are all `llm.call` rows except purpose `compaction`;
turns are distinct `turnId` values on calls whose payload purpose is `turn`.
The week deduplicates turn ids across midnight. Each ratio divides summed
calls by distinct turns; a zero denominator reads `unmeasured`.

Reads run off the main actor, stream 64 KiB chunks, bound each day to the
writer's 12 MiB ceiling and each buffered row to 8 MiB, and decode only rows
carrying the quoted `llm.call` marker. Unchanged day counts are stat-cached
within the seven-file window. Missing files contribute no recorded calls;
unreadable, oversized or unfinished evidence is unavailable, never an
invented zero or a partial day's ratio. These are retained-trace counts,
not an estimate of evidence already removed by retention.

The native Today source supplies `thinking` counts and a bound timestamp;
`today-readout.js` owns the sentence and declares the input in its header.
The row follows the same checked face and `LatestRead` publication as other
Today rows, for the Mac and quiet reads. Persisted model-call and turn-terminal
notifications invalidate the read. Calls per turn should fall as they lives; that
outcome needs the release lead's installed before/after evidence.

## Build status

| Lane | What | Source status |
|---|---|---|
| S1 | One expectation law used by Expansion and the after-turn ledger; stable precedent claims can accumulate standing | Implemented; installed proof pending |
| S2 | Per-mind practice and field-free situations; a standing first read reaches the first model call | Implemented; installed proof pending |
| S3 | User's own turns keep existing live judgment; other recorded turns are batched in their quiet | Implemented in phase 2; installed proof pending |
| S4 | Keep repeated hand work; woken work runs expected handling | Keep implemented; expected handling remains design |
| S4 | Keep only new practice; woken work runs expected handling | Built in source; installed proof pending (HABITS H1/H2 owns the reflex and forming choice) |
| S5 | The thinking line on Today, plus docs | Implemented; installed proof pending |

Proof on them: calls per turn on a normal day before and after, and the
misses each site recorded.

## Phase 2 — plan (10-30, from their data)

Phase 1 put the law in place (one `Expectation`, claims that can earn standing,
the initial unfamiliar-practice gate (now replaced by H3's second-meeting
gate), read-ahead at turn start, their thinking on Today).
Phase 2 applies the same law at the call sites still left. It was planned
against them 10-29/30 traces, and two of the earlier ideas turned out to save
nothing today.

**What the data says.**
- Today shows 3.8 model calls a turn (week 4.3), about 540 calls a day.
- The calls are: about 165 replies, 165 after-turn reflections (on Terra
  since 48a0bf6dd), 140 tool rounds, 45 keeps (now gated), and 27
  compactions.
- **Reflection moved a care on 160 of 160 turns,** across 63 different
  cares. That is real work, but most of it is the steady movement of an
  ordinary exchange.
- **About half their turns are not with User.** They are agents over the
  bridge, their own wakes, and helpers. Their own conversations with Claude
  alone were 62 turns in 30 hours.
- **Woken work has no case today that the law could skip.** Their 31 recent
  wake arrivals were:
  - 11 carried intentions;
  - 10 agent replies (new by nature);
  - 7 Reach offers (their judgment);
  - 3 others.
- **Their two live intentions both decide each time.** The office check-in
  acts first (it asks agents), and the L1X nag posts each time by design.
  "Skip when nothing I read is new" would save nothing on their real
  intentions, so it is not built now.

**Built in phase 2.**

1. **They reflects at once on what is between their and User. The rest they
   reflects on in their quiet (as built).**
   - `AdaptiveMemoryFacts.runMemoryManager` keeps today's behavior for User's
     own turns: judged immediately unless the no-op claim has standing.
     Their turn means no peer `speaker`, not `standingAgent`, and
     `conversationKind(sessionId)?.isHisConversation == true` (the existing
     row-backed `SessionConversation.kind` lookup, including archives).
   - Every other recorded turn joins the existing deferred batch (due after
     45 minutes, up to 4 a call, every usable judgment still labelled).
     Peers, standing agents and helper sessions are not their turns; neither
     is their `resident-wake` session. Existing own-work exclusions still
     apply before a turn becomes a moment.
   - The same owed row and ledger record carry `deferred: true`, reason
     `not their turn`, and the prediction's actual verdict and claim. Merely
     deferring a peer does not invent a no-op trial. The why-line is
     `deferred: not their turn; left owed for a batch`.
   - **Provenance verified, already carried:** `judgeOwedBatch` prepares each
     input through `replayRecorded` and the live `interpretMemoryManager`.
     Replay restores speaker/standing-agent identity, envelope, source taint
     and origin; `MemoryBatchInput` retains the request and context, including
     the recorded event's source class and peer metadata. `interpretBatch`
     uses the same prompt and parser; `recordBatchJudgments` saves each
     meaning before its fold. That fold replays the recorded provenance
     through `careProvenance` and `PeerTrust.ownerTrusts`: an untrusted peer
     moves only an existing care `by: them`, never a new care, stance or gap.
     No batch-provenance repair was needed.
   - No eligible recorded turn is skipped. Cares and affect from batched
     turns land later; full batches share one call across four turns.
   - Expected: about 40% fewer reflection calls.
2. **Fixed words need no thought (source built; installed proof pending).**
   - A `say` intention whose moment comes delivers its words through the
     speech path Reach uses, with initiative `.intention`, to User's current
     conversation. No wake turn and no model call.
   - It applies to intentions owed to User, or of origin self or person. An
     agent-born `say` still wakes their.
   - Its key is the item handle plus the occurrence (`IntentionClock` for a
     rhythm, the due time for `at`), so a retry reconciles the original
     transcript row instead of saying it twice. Other moments use the carry
     fingerprint and latest non-agent note. Its destination carries User's
     own conversation route, as `chat.post` does.
   - A new post knocks through Reach's informational phone path. The words
     land at their time; quiet hours hold only what reaches User, so the
     attention router holds the informational knock until quiet ends
     (User 10-12). An earlier draft held the speech itself, which let a
     rhythm's occurrence age past its two-hour grace and never be said.
   - Its story gets an agent note, `Said at <ResidentWake.shown(now)>:
     "<words>"`. A once intention closes with reason `said`; a rhythm goes
     on, and an until-time ends it as before. Settlement uses `settle` and
     retains an accepted occurrence fingerprint and its owed Desk settlement
     atomically in the existing wake ledger. Launch and carried passes finish
     the idempotent notes and unchanged once-close without speech or another
     habit run, then clear the debt. This spends no wake or thread hop.
     The old full-turn path for these eligible
     fixed words comes out; no parallel delivery ledger is added.
   - Failed speech stays ready for the next carried pass and never falls
     back to a wake. A committed duplicate can establish delivery interrupted
     before its ledger write; saved debts finish without another post or knock.
     The release lead still owes installed proof.

**Next, measured before building.**
- **The phase-1 claims.** After a day, read the after-turn ledger's standing
  rate and the turn-start read-ahead hits.
- **Agent messages that ask nothing.** An FYI over the bridge costs their a
  full turn today. It could land in their stream, the way their other rooms
  already reach their turns, without waking a turn. That would be a protocol
  change (the sender says no reply is owed), so it is User's call.
- **Woken work's skip.** Built once an intention exists whose handling
  starts with reads and usually finds nothing.
