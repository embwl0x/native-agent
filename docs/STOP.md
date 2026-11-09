# Stop

One law for every Stop, cancel, quit and timeout in NativeAgent.

**Stop cancels the work, never its settlement.**

A person's readable, untainted arrival withdraws only calls that have not
started. This is not Stop: a running call finishes under its existing owner,
and its receipt stays. Before dispatch, a withdrawn round keeps only its prose
and names its unstarted calls in `turn.proposalSkipped`. After dispatch pairing,
unstarted slots retain paired `skipped` / `not_run` results with `effects: none`
and `reason: person_arrival`; they are neither executions, failures nor
cancellations. A batch hands back its unstarted entries and earlier receipts.
An earlier receipt's failure, even nested, keeps its failed batch status,
remedy and provider error bit; arrival hand-back only adds the unstarted work.
Admission is checked before publishing a tool start, so a skipped slot leaves
no started activity or cognitive work charge; its paired receipt still settles.
The [turn anatomy](ANATOMY_OF_A_TURN.md#1-a-surface-admits-the-turn) owns arrival
eligibility and the boundary checks.

The turn program's optional `hear` may cut only a generating provider round.
A cut retains prose, discards every unstarted proposal, saves its checkpoint
and reads arrivals before asking again. It cancels the round's stream wait,
never the turn or a running call; it records `provider.roundCut`, not a stopped
turn. The observation names hearing rather than guessing the sender. If no
arrival remains for the boundary read, both the turn part and the next request
are told that no new message was read; the cut still happened.
HTTP cancellation closes the request. Codex's stdout producer retains
its existing exit-and-EOF settlement; closing the round stops forwarding its
words, without claiming that the process or remote generation stopped.

Stop-marker writes merge under the marker's lock using a checked UTF-8 read.
Only confirmed file absence starts a new marker. Unreadable existing bytes are
preserved and the Stop request reports the read failure; a named Stop never
erases earlier run identities or an existing empty stop-all marker.

Work in flight has two parts:

- **Its effect** is what it does in the world: send a message, write a file,
  run a process, drive an app, wait for a reply. Stop cancels the effect. No
  new effect starts after Stop.
- **Its settlement** is the truth about what happened: save what was produced
  (a partial reply, landed steps), write its one terminal record, release what
  it held (a process tree, the foreground app, an observer, a slot), and say
  plainly what landed and what did not. Settlement always runs to completion,
  exactly once, however the effect ended. It runs through `settle { … }`
  (`Modules/NativeAgentCore/Sources/NativeAgentCore/Settle.swift`), which a
  cancelled caller still waits for.

Inbound contact and builder tasks settle returned text and files even when
Stop arrives at the return boundary. Cancellation selects the terminal state
independently of produced output; a throwing cancellation recovers committed
parts from the exact saved run. Output retention precedes checkpoint removal.
A payload-recovery failure remains a named repair debt alongside the canonical
execution state, rather than converting known execution into failure or expiry.
HTTP enqueue/reply deadlines end the wait and leave the accepted task alive.

Ephemeral workers and tool-capable part thoughts join the same answer/heard
settlement on every exit. Their answer keeps produced prose and artifacts from
completed dispatches, including when the loop throws. Interrupted calls retain
that prose in `TurnEngineError.streamInterrupted` or `streamCancelled`; the
latter remains distinguishable as Stop. An incomplete engine result keeps its
existing `EphemeralToolTurnIncomplete` output carrier.

Buffered whole provider replies collect outside the caller's cancellation, with one
sticky reply owner bound before stream creation. Stop ends the caller's wait
at once and cancels HTTP requests; the Codex process runs to its own exit and
pipe EOF. The owner selects either the reply or cancellation once, including
Stop before its wait registers. Collection and forwarding settle independently
through `settle`, joining actual producer exit and drain. A collection failure
stops its producers without replacing its cause with cancellation. After drain,
a stopped collection delivers its retained partial to the existing partial-reply
sink and `llm.reply.partial` trace. A missing exit remains pending settlement,
never a terminal receipt, and does not hold the cancelled caller. Live chat's
Stop also ends its stream wait. Codex's plain, structured and streaming calls
use the same stdout producer, which saves redacted output through
`ProviderOutputDiagnostics` after exit and EOF, even after the caller or the
turn's forwarders have ended. `codex.reply.produced` in the experience store's `detail`
grain points to that file; the trace preview is bounded and the diagnostic file
keeps the full text under its newest-100 retention. Recording failures retain
their cause in that trace. Its process error stays beside the
produced output. A request that declares silence complete accepts empty output
only after EOF and successful process exit; other empty streams retain their
malformed-output cause. A process that never exits retains its pending producer,
and a silent answer's wait stays open with Stop available, without an invented terminal
record. Read and process failures retain their causes. Stop also cancels a
pending network-path wait. No provider deadline or retry-backoff worker runs.

Retry classification keeps a failed read-only classification as
`classificationFailed` with its cause. It cannot label an unreadable call as an
action that ran, and it still asks the person before repeating unknown effects.

Owned programs stop their helper immediately, cancel the in-flight host call
and await its actual terminal result before forming the final receipt. A
result arriving after Stop keeps its real effects and handles in the journal;
the stopped program cannot continue, and completed writes are never replayed.

An admitted authored fetch owns its network request separately from the calling
program's response wait. Stop, caller expiry and run close end that wait without
cancelling the request. Its own wall-clock transport ceiling cancels and joins
actual transport exit; `settle` saves its one redacted receipt and settles its
experience's `finish` obligation. The timeout names that experience for later
inspection; no response means unknown effects, never permission to resend.
The [authored fetch contract](skill_manifest_spec.md#secret-insertion-and-redaction)
owns the wait/transport limits and receipt path.

A resident program's call waiting for another call's busy slot parks through
`ScopedWaiter` (`Senses/OwnedProgramRunner.swift`). Cancelling that call releases and removes only its own parker, without stopping
the active resident call or waking sibling parkers. Slot release, completed
retirement and pool closure resolve the remaining waits. Without cancellation
or an inherited deadline, a still-busy slot remains pending; waking alone is
never evidence that it is vacant, so the caller rechecks admission.

Every unit of work has **one owner** that holds its record. The record moves
from running to exactly one terminal state, written at settlement:

- **done**: the effect completed;
- **stopped**: Stop ended it; the record keeps what it produced or sent
  ("sent to Grok; any answer stays in that chat");
- **failed**: it broke; the record says how.

Native browser sign-in selects one outcome for callback, cancellation, launch
failure or its ten-minute deadline. Before returning that outcome, the session
runner joins `settle`: cancel/join the deadline, remove the callback, cancel the
authentication session and release its presentation retention.
Mac dispatch retains and joins its original execution after cancellation or a
deadline, then persists its terminal evidence through `settle`. A cancel
requester with a retained execution awaits that execution's settlement event,
then checks the durable terminal record, including its `terminalAt`. A failed
terminal write wakes the requester with its cause; the original response retains
the produced body result alongside `settlement_failed`. Without a retained
execution it reports the observed pending state without acknowledgement. A missing
or uncommitted terminal record reports unconfirmed settlement;
there is no settlement-grace timer. Cancelling a requester's wait removes only
that waiter and does not retire the
execution or discard its late result. Mac dispatch, four-verb actions and watch
hands add no response deadline; inherited caller deadlines remain in effect.
The process adapter's typed cancellation carries drained stdout, stderr and
truncation flags; Mac dispatch returns that material with its stopped receipt.

Restoring changes the data-root life. A missing stamp means the first life;
work from another life reads **stopped**, reason **restored**.
Resume starts fresh work in the new life;
the [restore law](canonical_data_paths.md#restore-law) owns this boundary.

No intermediate state ("stopping", "waiting" after the waiter is gone) is ever
persisted, and nothing promises what can no longer happen.

Their mind's durable work record is the lived-moment journal (`lived_moments` in
`cognition/cognition.sqlite`; [SUBCONSCIOUS.md](SUBCONSCIOUS.md#lived-moments)).
Its `owed` and `meant` rows are not promises about an effect in flight: they are what is still owed to them, and the next wake lives them.
Quitting is their **sleep**, one joinable operation started in the async quit
hold: bridge and phone ingress closes immediately, and retained launch,
wake, practice, aging and background producers are stopped and joined before
`NativeAgentEngine.sleepMind` takes the final snapshot. Admission of interpretation closes
(settled turns are still recorded owed), the interpretations in flight stop (a
returned one is already `meant`; an interrupted call stays owed), the fold in
flight finishes, `appSleep` is lived once as the terminal transition, and body
and substrate are saved through `settle { … }` (the substrate in one checked
final flush of affect, consumed residue and nodes, `persistAffectAndNodes`). Its result names each part's
final save and the moments left unlived (a `lifecycle.sleep` receipt); a save
that fails is reported, never swallowed.

Ordinary quit waits for the turns captured at entry and joins the retained
producer/turn settlement and final mind save from their actual completion.
Neither join has a clock cutoff. The final synchronous resident drain still
waits only three seconds at the app termination callback. Process exit can
therefore interrupt unfinished dependency settlement; removing that remaining
bound requires the app callback to await the dependency join before termination.
The three-second drain joins the very same retained operation;
it cannot start a competing flush or retire Chrome, senses, resident programs,
ACP, ContextFlow or memory services ahead of producer and turn settlement.
Browser IPC's full stop likewise follows tracked turns and wake runs, so it
does not cancel their browser operations early. Browser admission-only closure
and universal turn/cognition admission still require their owning APIs; new
requests through those doors are not fenced by this ordering alone.
OtherDoorTurns' stop receipt joins its retained consumer, including an in-flight
transcript refresh, subscription cleanup through `settle` and exit bookkeeping.
ActivityWatch's controller retains one termination task joining startup, policy,
policy/cadence observation and retention bodies. The watcher's `requestStop()`
has two phases: a bounded request (at most five seconds for capture-thread
handoff and five for thread/pump settlement) returns `settled` or
`settlementPending`, alongside the existing pump's eventual settlement task.
The controller retains and joins that task even when stopping was already
underway. A pending outcome reports degraded state without releasing live
capture ownership or cancelling the pump; a wedged thread can leave this join
pending until process exit. A
policy-disable handoff alone is not the controller's full termination barrier. The quit producer
settlement joins both the OtherDoorTurns and ActivityWatch handles before the
final mind save, subject to the final dependency-drain/process-exit limitation above.
The next launch reconciles retained journal work and committed
dream cutoffs; the quit result must never claim an unfinished snapshot landed.

A missing cooldown stamp permits the first tool restart; an unreadable
or invalid existing stamp refuses restart with its storage/schema error and
preserves the file or symlink entry. A dangling stamp symlink is not missing
restart history.
Restart admission, the acquired lock, the audit/stamp boundary and relauncher
spawn all check cancellation. Stop before spawn schedules no termination;
`settle` saves an explicit stopped outcome in any produced audit/stamp.
An unscheduled attempt (Stop or spawn failure) retains its evidence with
`restartScheduled: false`, which does not consume the fired-restart cooldown.
A tool restart waits for its originating turn's settlement before requesting
quit. Its stalled-turn allowance is 60 wall-clock seconds (the 120-second
relauncher exit deadline minus the 60-second whole-quit reserve); expiry is
reported as unfinished. The detached relauncher still waits for actual process
exit before reopening the app. Restart discovery describes this settlement wait
and stalled-turn allowance; the separate 20-second install delay is not a
restart grace period.
The shared detached-spawn API reports a missing executable as an argument
error through its throwing result, so an empty request cannot abort the app.

Scheduled notifications retain settled channel receipts on their occurrence;
cancellation joins the body before recording confirmed deliveries and unconfirmed
channels, and no later channel is sent after Stop.
What was already sent stays sent and the record says so. What was produced is
saved once, never twice and never zero times. A store closes only after every
unit allowed to write to it has settled.

An act restores its temporarily raised app and releases enhanced Accessibility
through `settle` under the original driver's settlement binding. Stop cannot
cancel that release; takeover, handback and shutdown still revoke its generation.
An owned repeated-act attention session is released once by its captured session
identity through the same settlement binding. A replaced session is untouched;
this input-free release needs no renewed work admission, and release failures
stay in the act receipt. An expired/stopped observation returns
the attention owner's current status, never its earlier active snapshot.
Mac tool-call deadlines bound the reporting caller and its work waiters, never
detached settlement. A reporting timeout or Stop without the body's result is
an unknown effect, not proof of cancellation acknowledgement; the in-flight
body alone writes its terminal settlement. Reporting uncertainty has no
`terminalAt`; actual exit replaces it with the body's real result. The registry
keeps the newest 32 settled results in memory for matching-operation retrieval,
including output if lifecycle settlement failed; it never reruns an action to
retrieve a result. The lifecycle file remains payload-free. After result eviction
or restart, a lifecycle-only replay says `result_available:false`; interrupted
unsettled bodies become terminal unknown effects at startup. A body that never
returns remains owned and uncertain, without holding its caller's response.
See [turn resilience](TURN_RESILIENCE.md#3-tool-dispatch-deadline).
A returned SSH result, including `ProcessRunCancellation.result`, becomes its
`node.run` remote-effect receipt through `settle`, retaining bounded stdout,
stderr, exit code, timeout and truncation evidence. Stop ends local SSH, never
proves the remote command stopped: the receipt says cancelled with effects
unknown. If Stop won dispatch's first terminal outcome, that cancelled outcome
keeps the joined body's returned receipt as settlement evidence; it cannot
erase output or become a late success.

Background shutdown closes the managed execution gates and cancels their
physical workers, then joins their bodies and accounting. Physiology tasks
replaced before quit remain retained until exit and join the same shutdown;
cancelling or freeing an active slot is never proof of settlement.
Helper scheduler shutdown permanently closes that scheduler's admission,
cancels its retained runs and joins their shelf, claim and deadline settlement.
Telegram voice Stop/deadline cancels the selected ffmpeg conversion and
recognition, then joins the owning body and its temporary-file cleanup before
releasing the turn.
Context Flow stop also cancels and joins admitted query-embedding bodies before
releasing their memory runtime; failing a waiting ticket does not end its body.
Transcript aging joins both its retained bodies and their cancellation
deadlines. Part wakes also retain replaced file/trust watchers through exit.

A returned dream's exact publication, consumed cutoff and pending effects are
saved in its one durable work record through `settle`, even when Stop raced the
model response. Publication recovers by the section's immutable diary identity.
Lessons, reflection, care and dated mood delivery checkpoint that record only
after their checked durable effects land; diary evidence stays byte-stable.
Disabled reflection settles with its off reason;
reflection that must wait (its daily ceiling, one in flight, a held slot), failed reflection and
care/self persistence remain owed for the next real run, including older and archived dates;
scheduling alone clears nothing.
A returned weekly analysis and its terminal
outcome are saved in its digest through `settle`; Stop prevents subsequent mood
changes, proposal staging and practice. Interpretation and reflection follow
the same law: returned meaning is settlement, never new work.
Reflection decodes and validates a returned judgment even if Stop has arrived,
then saves its result and receipt through `settle`; Stop prevents a later pursuit.
The runtime retains their hour too: sleep cancels and joins it before the final
snapshot. An admitted hour always attempts its terminal trace and receipt,
including a witnessed journal entry, even after a switch changes or its provider
fails; turning the lane off cannot erase settlement.
Sleep also joins cognition's retained launch chores, recent-life reading,
event reflection, canon, horizon and Reach producers before `appSleep` and the
final saves. Closing admission prevents another recent-life provider call;
judgments already returned finish their settlement.

A tool dispatch owns its actual body across the deadline/Stop race. The first
response stays selected. Its response deadline ends only the wait: it never
cancels a write or joins a body that has not returned. The original body keeps
its checkpoint until actual exit, records the real receipt through `settle`,
and emits `tool.dispatch.settled` with the invocation/call IDs. A late receipt
is evidence, not a replacement response or another dispatch. Missing completion
stays unknown; Stop requests cancellation without asserting effects stopped.
The active-work response clock still renews on progress and pauses for human
waits, but supplies no downstream effect budget. Practice keep turns retain
their `TurnBodyLifetime` cancellation/join behavior; `TurnDeadline` owns their
response verdict separately.

Local Calendar and Reminders check cancellation at their EventKit save/remove
boundary, including writes whose selection awaited an EventKit read.

Connector actions capture their returned output and append the receipt through
`settle`, including waits for the receipt lock. A persistence failure reports
the returned status and retains the redacted output in its recording error;
it cannot claim that the action itself never ran.

This is NORTHSTAR clause 2 (no theater) applied to Stop: every receipt records
something that actually ran.
