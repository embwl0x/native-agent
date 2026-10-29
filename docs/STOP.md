# Stop

One law for every Stop, cancel, quit and timeout in NativeAgent.

**Stop cancels the work, never its settlement.**

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

Workshop's ordinary and approved steps share one outcome commit: produced
output and its receipt are saved before the status transition, cancellation
wins, and traversal skips steps with durable completed outcomes.

Ephemeral workers and tool-capable part thoughts join the same answer/heard
settlement on every exit. Their answer keeps produced prose and artifacts from
completed dispatches, including when the loop throws. Interrupted calls retain
that prose in `TurnEngineError.streamInterrupted` or `streamCancelled`; the
latter remains distinguishable as Stop. An incomplete engine result keeps its
existing `EphemeralToolTurnIncomplete` output carrier.

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
requester's bounded wait does not retire that execution or discard its late result.
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

Quit has a bounded unfinished outcome: ordinary quit waits at most 20 seconds
for the turns captured at entry, then at most 30 seconds waiting on the retained
producer/turn settlement and final mind save. The snapshot still waits for
tracked turns after the 20-second allowance; neither bound authorizes a
snapshot ahead of them. If the second bound expires, the result explicitly
says it did not settle; the settlement keeps running while termination proceeds.
The last resident drain waits only three seconds. Process exit can therefore
interrupt unfinished settlement: a completed final save is not guaranteed at
either bound. The three-second drain joins the very same retained operation;
it cannot start a competing flush or retire Chrome, senses, resident programs,
ACP, ContextFlow or memory services ahead of producer and turn settlement.
Browser IPC's full stop likewise follows tracked turns and wake runs, so it
does not cancel their browser operations early. Browser admission-only closure
and universal turn/cognition admission still require their owning APIs; new
requests through those doors are not fenced by this ordering alone.
OtherDoorTurns' stop receipt joins its retained consumer, including an in-flight
transcript refresh, subscription cleanup through `settle` and exit bookkeeping.
ActivityWatch's stop task does not yet join all its cancelled owner bodies;
awaiting that receipt alone does not establish the complete producer barrier
required by this law.
ActivityWatch retains one termination task joining startup, policy, event and
retention bodies plus the capture thread's drained store pump, including a stop
already underway. Its handoff deadline reports degraded state without releasing
that join; the quit owner owns the unfinished bound. OtherDoorTurns still returns
a stop task that does not join every cancelled owner body; that receipt alone
does not establish the complete producer barrier required by this law.
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

Scheduled jobs retain their actual body task through cancellation and timeout;
stopped settlement keeps any returned status, detail and output (including a
confirmed execution ID), and a watch's returned baseline. A throwing body keeps
its error and any settled channel receipts, with other effects still unknown.
Scheduled notifications retain settled channel receipts on their occurrence;
cancellation joins the body before recording confirmed deliveries and unconfirmed
channels, and no later channel is sent after Stop.
What was already sent stays sent and the record says so. What was produced is
saved once, never twice and never zero times. A store closes only after every
unit allowed to write to it has settled.

An act restores its temporarily raised app and releases enhanced Accessibility
through `settle` under the original driver's settlement binding. Stop cannot
cancel that release; takeover, handback and shutdown still revoke its generation.
A returned SSH result becomes its remote-effect receipt through `settle`;
Stop still cancels unfinished execution, but cannot erase returned output or status.

Background shutdown closes the managed execution gates and cancels their
physical workers, then joins their bodies and accounting. Physiology tasks
replaced before quit remain retained until exit and join the same shutdown;
cancelling or freeing an active slot is never proof of settlement.
Helper scheduler shutdown permanently closes that scheduler's admission,
cancels its retained runs and joins their shelf, claim and deadline settlement.
Telegram voice Stop/deadline cancels audio export and recognition, then joins
the owning body and its temporary-file cleanup before releasing the turn.
Context Flow stop also cancels and joins admitted query-embedding bodies before
releasing their memory runtime; failing a waiting ticket does not end its body.
Transcript aging joins both its retained bodies and their cancellation
deadlines. Part wakes also retain replaced file/trust watchers through exit.

A returned dream is saved with its consumed cutoff through `settle`, even
when Stop raced the model response. A returned weekly analysis and its terminal
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
terminal outcome stays selected, but the turn joins that body's settlement
before closing its dispatch checkpoint; an ability save and its trace cannot
outlive the keep turn that issued them. Its body is created inside the active
deadline scope, so progress and human waits still renew and pause that clock.
A deadline bounds the effect, not the time needed to record what it produced.
Practice keep turns, tool dispatch and Workshop sessions use `TurnBodyLifetime`
to admit one body inside its deadline scope and cancel and join its actual
result through `settle`; `TurnDeadline` selects the response verdict.

Local Calendar and Reminders check cancellation at their EventKit save/remove
boundary, including writes whose selection awaited an EventKit read.

Connector actions capture their returned output and append the receipt through
`settle`, including waits for the receipt lock. A persistence failure reports
the returned status and retains the redacted output in its recording error;
it cannot claim that the action itself never ran.

Canceling a Desk item also cancels its linked Workshop executions. The executor
reads that canonical cancellation before claiming work and admitting each step;
an in-flight step observes Desk changes, stops cooperatively, and saves its
returned output and receipt before the execution settles as canceled.
Workshop step deadlines likewise join the operation and retain its returned
receipt in the failed timeout outcome; they admit no following step.
Workshop sessions retain and join their worker after deadline or Stop, then
close artifact collection and write their one terminal receipt through `settle`.
Returned and partial text stays in the durable session result and receipt feed.

This is NORTHSTAR clause 2 (no theater) applied to Stop: every receipt records
something that actually ran.
