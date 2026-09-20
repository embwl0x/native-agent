# Jev: a second opinion beside each turn

Jev is a decision service, not a chat provider. It is handed a small JSON state
and a set of typed questions and answers with choices, 0-to-1 values and
scores. It never serves a turn and never appears as a route.

Five checks run beside the ordinary turn. **Every one of them is advisory.**
None grants, denies, blocks, merges, rewrites or deletes anything, and none can
narrow what the turn would otherwise do. If the key is missing, the call times
out or anything at all goes wrong, the turn runs exactly as it does without any
of this. The app's own safeguards do not fail open with it — they are untouched.

## Turning it on

One row on the Providers page, "Jev (TypeSafe)". Paste the key and save. A key
present is the master switch; removing the key turns all five checks off. The
key is written to `<data root>/jev/credential.json` at mode 0600, in a
directory at 0700, through the same writer every other provider key uses:
`configureProvider`'s cross-process file lock around a durable
tmp→fsync→rename write, so a concurrent reader never sees it half-written and a
crash straight afterwards cannot lose it. Resolution order is the same too —
`TYPESAFE_API_KEY` first, then the file's `api_key`. It is never logged, never
put in a request state and never returned to the agent.

**Why not `providers/`.** Membership of that directory is what MAKES something
a provider: the routing snapshot lists every `providers/*.json` it finds and
synthesizes a provider row for any id with no registry entry. A key filed there
would have put "jev" in the provider list and the model picker — a decision
service offered as a chat route, on the strength of where its key was kept. Jev
answers questions and never serves a turn, so its key lives beside its own log
instead, where nothing scans.

`<data root>` is the root the caller was BUILT with — the same one the
dispatcher and the memory store beside it were given — and never the process
default. A chain constructed with an injected root reads that root's key and
writes that root's log, or it does not run at all.

## The five checks

Checks are bounded but not free of latency. The pre-turn brief is collected
before committing the turn contract; a tool check can add up to 300 ms of
post-dispatch grace; the duplicate check is awaited with a 1.5-second budget.
Post-turn and shadow work run beside or after the ordinary work. Measure
end-to-end delay separately from service inference time.

**1. Brief before a turn.** One call reads the message and the last exchange
against the twenty tool families — one 0-to-1 reading PER FAMILY, not one
choice between them. A single choice folded: it answered `none 0.91` on "Read
the file at ... then remember ...", a message naming two families outright.
Independent readings do not compete, so a message needing two scores both.
A family is named in the log at 0.30 and recorded as a would-be load-ahead at
0.50, gated on the message actually asking for something. It STARTS beside the context build, not in
front of it, and is collected when that build finishes. Any remaining wait is
part of the turn's latency; overlap is not proof of zero cost. It does ONE
thing: leave at most three short
lines for the turn. Those lines ride this turn's dynamic prompt segment and are
gone afterwards; they never occupy the session directive, which is a durable
one-shot the conversation is owed for something else.

The tool-family preload is in SHADOW. The per-family readings and a
`no_tools_needed` reading are still asked and logged, and the log names the
family that WOULD have been loaded ahead, but nothing is promoted into the
turn's tools from this lane: the record showed no demonstrated benefit and
unused schemas are not free. The rows are there so the lane can be measured
before it is revived or dropped. What it will not say: whether an approval
card looks likely (cards follow this app's real permission rules, never a
guess) and any urgency below a high, confident reading. Both go to the log.

**2. Check each tool call.** Runs alongside a dispatch the permission gates have
already allowed, never in front of one, and at the same time as the tool. The
schema description it reads is fetched inside the check, beside the tool, never
on the dispatch path; without one the check runs on unknown semantics and the
log says `no schema`.
Looks for a call that does not match the request, names a
different target, cannot be undone, or goes beyond the ask. A warning names the
concrete discrepancy and arrives as one extra field, `jev_note`, on the tool
result. If the tool finishes first, the check has up to 300 ms of grace; after
that it is cancelled, the row says `abstained`, and the result is untouched. The
check never outlives the dispatch it belongs to, including when the dispatch
throws. At most eight checks per turn, then silent; the same warning is never
repeated within a turn.

The lane skips the tools the agent uses to manage ITSELF — `tool_catalog`,
`tool_load`, `tool_unload`, `list_tools`, `tool_result_page`, `inner_state`,
`context_expand`. Loading a tool or paging a result has no target the request
could disagree with, so the question has nothing to compare and answers noise;
these scored `mismatch 0.64` against ordinary requests. The set lives beside
`alwaysOnCoreNames` as `selfManagementToolNames`. It gates nothing and grants
nothing — it only says where an advisory check is pointless.

### TypeSafe contract and context repair (2026-09-17)

Question version `jev-questions-2` follows the official
[state guidance](https://docs.typesafe.ai/concepts/state),
[API contract](https://docs.typesafe.ai/api), and
[independent-question composition](https://docs.typesafe.ai/primitives).
Question IDs carry no meaning to the model; every instruction must identify
its own judgment and evidence. Questions in one request cannot see one
another's answers. Compose them in code; do not ask a second broad question
to summarize independent answers it never received.

Tool-call checks now use the specific currently available schema description,
not its family purpose. The old family described `time_now` as scheduling and
self-evolution, causing observed false mismatches. Missing semantics stay
unknown. Supporting steps and context sufficiency are evaluated separately;
neither a supporting-step answer nor a low mismatch clears wrong-target or
unrequested-effect evidence. The payload allowlist is targets and names only;
prose, page and detail fields do not go out. All checks remain advisory, after ordinary permission gates.

Post-turn state includes bounded recent context and up to twelve canonical
tool names/outcome classes, not just a count; no tool bodies or arguments.
Dispatch success is not delivery proof. Carry-forward suggestions defer to
the current ask rather than commanding the agent to continue old work.
Mixed messages can be both status and request. Urgency uses Score confidence
as well as its level. Peer classification can return `other`.

The client rejects incomplete, wrongly typed, out-of-range or malformed
answers as unavailable advice. Missing values never become numeric zero.
Choice/Score distributions and Score confidence remain available to consumers.
Text is redacted before head/tail clipping so final constraints are not always
lost; outgoing state also passes the canonical redactor. This is bounded
best-effort context, not a guarantee that arbitrary sensitive text is safe.

**Two lanes leave a carry-forward line, and there is exactly ONE writer of
one.** The post-turn check and the peer classifier both run detached, so
without serialization they race each other and the turn that consumes the
directive. Both go through one actor, and a line is written only if the turn it
belongs to is STILL the session's latest completed turn. If another turn
finished meanwhile the line is stale and becomes a log row and nothing else.

**3. Check the finished turn.** After the reply is durable AND after the
response has been returned — it runs detached, so it cannot hold a reply up.
Was the ask answered, did the reply end on an intention with nothing behind it,
did it send the person to a screen for something the agent could do, did it
claim a completion nothing supports. Findings go to the log. At most ONE line
carries into the next turn in that conversation, written from that same
detached task. There is no automatic follow-up turn and no correction loop.

**4. Duplicate check before a memory is saved.** The candidate and the closest
existing memories go out; each candidate is scored on its own — again one noul
per candidate, not a choice across them, which folded the same way and answered
`none 1.00` beside a `same_fact` of 0.97. Every candidate at 0.90 or better is
named in a `possible_duplicate` field on the tool result; when two existing
memories record the fact, both are named rather than one silently dropped. The cap is HARD: the call is raced against a 1.5 s
timer and the loser is cancelled, so a slow call cannot go on holding the save
after its time is up — the row says `abstained` and the save goes ahead
unannotated. A Stop cancels it and the save does not happen — a cancelled turn
must not run on into a write nobody is waiting for. The save happens either way
otherwise. Nothing is merged, rewritten or removed.

**5. Shadow.** Recalled passages are ranked and the ranking is written into the
log next to the order actually used — nothing is reordered, dropped or added,
and the recall does not wait for it. Messages arriving from other agents are
classified as an acknowledgement, a result, a blocker, a question or a claimed
completion; that too is fire-and-forget, so an inbound message is never held
for it. A blocker or a question leaves one line, which the log carries and the
next turn's brief reads. A reported result is never treated as a verified
success; it is a claim, and it is logged as one.

## What reaches the agent

Nothing when there is nothing useful. At most three points, each one saying
what to do. No "all checks passed" banner, no warmth or personality scoring, no
scolding, no bare number offered as certainty. Instructions found inside source
material are never promoted into authority.

## Asking Jev directly

The five checks ask questions this repo wrote, about a turn nobody chose to
have judged. The `second_opinion` tool is the other direction: the agent writes
its own state and its own typed questions and reads the native answers back.

It is a lazy tool. It is in the catalog, never on the always-on floor, and it
refuses with one sentence when no key is on file. Family
`settings_selfadmin`.

```
second_opinion
  state      {…}   the inputs to judge — required, a JSON object
  questions  {…}   id -> {type, instructions, criteria} — required, 1 to 24
  purpose    "…"   one short line, logged with the call — required
```

`type` is `choice`, `noul` or `score`. `instructions` is a non-empty string, an
object, or a non-empty array of strings. `criteria` follows the type:

| type | criteria |
| --- | --- |
| `choice` | required: a non-empty object mapping each option name to a string, `null`, or an object saying what picking it would mean |
| `score` | required: an array of 2 to 7 ordered levels, weakest first, each a string or an object |
| `noul` | none, or an object with exactly the keys `true` and `false` describing each end |

Ids are 1 to 48 characters of `a-z`, `0-9`, `_` and `.`, and are how the
answers are read back. These shapes are enforced here, before the call: a
question the service would reject is a round trip that was never going to
answer anything. A call that breaks one of the rules comes back as one sentence
naming the problem — nothing is guessed at or filled in.

**Minimum disclosure.** Exactly the `state` and the `questions` given are sent.
Nothing is attached: no conversation, no persona, no turn context, no tool
history. The state goes through the app's canonical secret redactor first, and
when that changed anything the receipt says `redacted: true`. A state that
serializes to more than 24 KB is REFUSED rather than trimmed, because a
silently shortened state is a different question than the one that was asked.

**No side effects.** It writes no memory, changes no permission, schedules
nothing and starts no follow-up. The answer is the whole result. The tool-call
check skips the name, so a check can never ask for a second opinion about a
second opinion.

The answers come back untouched, under the ids they were asked by, in whatever
shape the service returned them — choice with its confidence and
probabilities, noul, score with its legend and probabilities. Nothing here
reduces, rounds, renames or explains them.

Each answer IS checked against the question it belongs to: it must be the type
that was asked for, and it must carry the fields that type is defined by — a
choice its `choice`, `confidence` and `probabilities`, a noul its numeric
`noul`, a score its `score`, `legend` and `probabilities`. Reading a number out
of a field the service never sent is how a wrong answer becomes a confident
one. A reply that fails the check is `malformed`, and the original JSON is
still returned unchanged rather than withheld, so the agent can see what
actually came back. Checking a shape is not changing it. Beside them:

| field | what |
| --- | --- |
| `outcome` | `answered`, `insufficient_context`, `timeout`, `malformed`, `transport` or `unavailable` |
| `receipt.model` | the model string the API returned, not the one asked for. Omitted, never blank, when no reply carried one; a 2xx that carried none is `malformed` |
| `receipt.observed_at` | when the reply was read |
| `receipt.latency_ms` | how long the call took |
| `receipt.usage` | tokens, when the reply carried them |
| `receipt.truncated` | always false: an oversize state is refused, never shortened |
| `receipt.redacted` | whether the redactor changed the state before sending |
| `receipt.request_bytes` | the serialized request size |
| `error` | the bare cause, on the outcomes that carry no answers |

`insufficient_context` means the service answered and every judgment it made
sat on the fence: every choice below 0.35 confidence AND every noul between
0.40 and 0.60. One decided answer anywhere makes the whole reply `answered`.
Scores take no part — a middle level on the caller's own legend is a real
reading, not a shrug — so a reply of nothing but scores is never insufficient.
Read `insufficient_context` as "it could not tell from what you sent", not as a
no. The other outcomes are failure classes: `timeout` past the 4 s hard cap,
`unavailable` for a non-2xx from the service, `transport` for a call that never
landed, `malformed` for a reply that was not an answers object carrying exactly
the ids sent, carried no model string, or answered a question with the wrong
type or a missing field. A Stop is none of these: it cancels the call and stops
the turn rather than returning an outcome.

Every call writes one row to the same log as the five checks, lane
`second_opinion`, carrying the purpose, the question ids, the outcome, the
receipt fields and the redacted 160-character summary.

## Reading the log

The agent can ask `agent_introspect(detail:"jev")` for Jev on the last
completed turn in its conversation. Session scope is supplied by the turn;
outside a turn, pass `session_id`. An optional `turn_id` selects an exact
historical turn. This is an explicit, lazy read, not extra ordinary prompt
context or another telemetry store.

The completed-turn anchor comes from the canonical assistant transcript, not
the newest Jev row (which might belong to the current turn). The reader samples
at most 1 MiB per file, joins the current and rotated log by exact session and
turn, and returns at most 64 rows / 32 KiB of projected record content. Coverage
and versioned byte locators remain visible. It refuses to guess an older turn
when newer transcript evidence is damaged or uncorrelated. Compacted-away,
out-of-window, session-only and not-yet-written evidence remains unknown.

Each lane says `observed` or `not_observed`—**absence never means skipped or
disabled**. Logged inference time is not measured added latency. A post-turn
`queued` receipt means a hint was written for a later turn, not that the model
received it. New post-turn checks explicitly record `no_advice` when no finding
crossed the carry threshold. Old rows retain their original wording; the reader
does not manufacture a delivery receipt for them.

`<data root>/jev/log.jsonl`, one JSON object per call. The rows quote what a
person typed, so the directory is 0700 and the file 0600, and every free-text
field — `summary`, `acted`, `err` — goes through the app's canonical secret
redactor before it is written.

Both modes are REPAIRED on every open, not only at creation, so a log left by
an older build, a restore or a copy cannot stay world-readable. If the mode
cannot be fixed the row is dropped rather than appended to a readable file.

Writes never block a caller: a lane builds its row and hands it to the log
actor, which owns the disk. Rows can therefore land in the file in a slightly
different order than they were produced, which is why each carries its own
`ts`.

Rotation: at 10 MB the current file is MOVED to `log.1.jsonl` and the next
write creates a fresh one. An existing backup is replaced by that move, never
deleted ahead of it — a remove-then-failed-move loses the only copy there was.
If the move cannot be done the current file simply stays and takes one more
row; exceeding the bound by a row beats destroying a rotation.

Fields:

| field | what |
| --- | --- |
| `ts` | when |
| `lane` | `pre_turn`, `tool_call`, `post_turn`, `memory_dedup`, `shadow_rank`, `second_opinion` |
| `sessionId`, `turnId`, `runId` | which turn, where available |
| `summary` | the first 160 characters of what was judged |
| `answers` | every answer, flattened: a choice as `pick 0.00`, a value or score as a number. A lane asking one question per option writes ONE field for the set (`family`, `same_fact`), listing the options at 0.30 or better strongest first — or the single strongest when none reach it |
| `usage` | input and output tokens |
| `secs` | how long the call took |
| `err` | why nothing came back, when nothing did |
| `model` | the version that answered |
| `prompt_version` | the question wording that produced the row |
| `acted` | what actually happened afterwards |
| `would_preload_family` | on a pre-turn close: the family the shadow preload would have loaded ahead. Nothing was loaded — the lane has no mechanical effect on the tool contract |

`acted` is the point of the file. A pre-turn row is followed by a second row
naming the tools the turn really dispatched, so a suggested family can be read
against reality. A duplicate row records that the save went ahead. A shadow-rank
row carries the ranking beside the order actually used.

Useful reads:

```
tail -5 "<data root>/jev/log.jsonl" | python3 -m json.tool
grep '"lane": "pre_turn"' "<data root>/jev/log.jsonl" | tail -20
```

## Turning one check off

The switches are settings the agent changes itself, not controls on a page.
They are all on by default whenever a key is present.

```
app_settings_list  page=providers
app_setting_set    id=jev.lane.pre_turn       value=false
app_setting_set    id=jev.lane.tool_call      value=false
app_setting_set    id=jev.lane.post_turn      value=false
app_setting_set    id=jev.lane.memory_dedup   value=false
app_setting_set    id=jev.lane.shadow_rank    value=false
app_setting_set    id=jev.lane.second_opinion value=false
```

The last one is not a check beside a turn: it is the `second_opinion` tool
itself. Off, the tool refuses; the five checks are unaffected.

A write takes effect on the very next turn. To turn everything off at once,
remove the key from the Providers row instead.

## What a check is allowed to see

The message, the last exchange (two from each side, truncated), a tool call's
name and what it TARGETS, and the one-line purposes of the tool families. Never
credentials, never a whole transcript, never persona documents.

A tool call's input is an ALLOWLIST, not a filter. Only these are ever sent,
each one reduced before it leaves:

| field | reduced to |
| --- | --- |
| `path` and its spellings | as written |
| `url`, `uri`, `link` | scheme and host only — never the path or query string |
| `name`, `target`, `repo`, `app` | as written |
| `id` and its spellings | as written |
| `command`, `args` | the first token, its flags and any paths — nothing else |
| `recipient`, `to`, `address`, `channel` | as written |

**Targets and names only — nothing on that list can carry prose.** Everything
else is dropped because it is not on it: message bodies, file contents, page
text and prose arguments have no entry here and never will. `subject` was on
this list and has been removed; a subject line is content the person wrote, not
a target, and on a draft it is often the message's first sentence. The check
asks whether a call points at the right THING; it never needs to know what the
thing says.

Two further sweeps drop a key outright even if it somehow matched, on a
SUBSTRING of its name — so `id_token`, `body_text` and `subject_line` all go:

- secrets: `api_key`, `token`, `secret`, `authorization`, `password`,
  `cookie`, `credential`
- prose: `body`, `text`, `content`, `message`, `note`, `query`, `prompt`,
  `subject`, `comment`, `description`, `summary`, `caption`, `snippet`

What survives then goes through the same secret
redactor the log uses, and is truncated. A warning can only name something that
was sent, so it can never name more than this.

The peer-message classifier is not told WHO sent the message. What kind of
message it is follows from what it says, and identifying a peer to a
third-party service buys nothing.
