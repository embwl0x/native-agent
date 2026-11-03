# Codex bridge: ownership and interactive conversation

Direct Codex command invocations read the assistant reply only from their
declared final-message file. A missing, empty or unreadable file returns
`final_reply_unavailable`, retains stdout separately and names the file to
repair. Exit zero alone cannot establish a completed reply. Inspect existing
effects and captured process evidence before repeating the command.

Runtime status is app-server-local. A desktop projection of
`notLoaded` or `interrupted` does not establish that the bridge's writer stopped.

## Direct invocation owns its execution

`codex.invoke` keeps the `invoke_codex` schema and executor through the app
registry; it does not use the contact-message transport. Discovery and argument
validation use that same schema, including `run_id`, `abort`, and both timeouts.
It admits the verified executable as a required launch value;
it never rediscovers another executable on PATH. `timeout_seconds` bounds
observation only (0–3600 seconds, default 600). Expiry, the calling turn's
deadline and caller Stop release that wait without stopping the admitted
execution. The pending reply carries `runId`, `auditPath` and
`outcome:unsettled`; it is never evidence that work ended.

Inspect with `codex.invoke {run_id:"<runId>"}`. This reads the exact retained
owner and its audit without starting work. `abort:true` with that ID stops
only that owner. `execution_timeout_seconds` is its independent wall-clock
ceiling (30–86400 seconds, default 3600). Actual process exit enters `settle`
once, drains output, writes the terminal audit and records the Runs projection.
No result arriving before the observation ends means pending, not failure.
After app restart an unfinished audit with no retained owner remains unknown;
a missing or unreadable audit reports observation unavailable. Inspect the
existing effects before repeating work. Active audits are excluded from
the existing 100-pair audit retention.

## Inbox admission precedes acknowledgement

OMP and Claude use the one Swift inbox-admission owner; Codex's helper uses
its one locked inbox-projection owner. New admission flushes and closes
before returning queued; storage failure returns before wake. A damaged
feed remains untouched and returns `prior_admission_uncertain`,
`effects:unknown`, `outcome:unsettled`, and `inboxUnavailable.preservedPath`.
No parseable subset is used to admit another send. Reconcile that original
feed and its retained execution identities before sending again.

## Before replacing supposedly interrupted work

Use `app {"action":"agent.jobs","args":{"agent":"codex","message_id":"<exact-id>"}}`
to recover recorded thread/turn identities. Missing or partial job evidence
does not prove no work exists.

For an owning-server read from this checkout:

```sh
node script/codex_thread_wakeup.js --read-thread codex:<thread-id>
```

This connects to the existing bridge app-server and reads that thread without
starting the worker service, resuming work or returning conversation content.
An unavailable socket or unknown status never authorizes replay. Do not use
`--probe` as the read-only substitute; it uses the service recovery path.

The completion watcher and this diagnostic read use the same durable rollout's
exact `task_complete` / `turn_aborted` evidence. RPC completion events and file
changes wake that read; RPC thread projections never replace it. Missing terminal
evidence stays pending across bounded caller observation windows. A damaged
rollout keeps the owning job owed with `observationFailure`; an unavailable
liveness probe records `lastWait.status: observation_unavailable` and
`observationFailure`, with unknown execution effects and its original cause.
`replyWaitTimeoutMs` ends one wait window; the durable reply job re-arms that
window until canonical terminal evidence or a recorded disposition. Rollout and
RPC edges wake the canonical read immediately. The bridge retains an event-backed
`--recover-wakes` owner, attaching pending entries and reply jobs at readiness
and on their directory changes. Each job owns its delivery lock independently;
a long reply never occupies another job's recovery slot. Helper exit or an
unavailable/contended observation reattaches after a 30-second failure backoff.
An unrepaired source remains owed, with its cause, indefinitely. Unavailable probes never become
`completedExecution` or completion deliveries. Execution is still unknown;
neither unavailability nor expiry permits replay or interruption.
Retained answer text alone does not prove completion. Coordinate with an active
writer before launching replacement work in its checkout.

Wake JSON and JSONL readers accept only proven file absence as empty. Existing
read/decode faults refuse admission or ledger rewriting, preserving retained
bytes and naming the failing source. Saved wake policy is validated before
queue admission; `deliveryMode` is `fresh_thread` or `pinned_thread`. The selected
executable is the app's `CODEX_BIN`, or the standalone Codex path for an unbound
manual invocation; a launch failure never tries another installation.

The canonical pending queue is resolved by `pendingPath()` from
`NATIVE_AGENT_CODEX_PENDING_PATH` or beside the wake policy. Admission, drain,
watch and race-closing reads all use it; `pendingPath` in saved policy is refused.
The queue reader validates every current row, naming the file and zero-based
index and preserving damaged bytes. Only ENOENT means an absent queue or recovery
ledger; other read failures remain unavailable. The drainer has no thirty-minute
lifetime: it owns one kernel lock while entries remain and subscribes to each
busy thread's `turn/completed` events as well as rollout and queue changes.
Heartbeat rows describe the drainer; their timestamps and numeric PIDs do not
grant ownership. `drainTimeoutMs` and `drainerHeartbeatStaleMs` are retired.
The supervisor's own source-availability gaps are retained in
`wake-owner-observation.json` beside the wake policy, including the exact queue
path/index on schema failure. That record describes observation, never a work
completion verdict.

Codex and OMP share one BSD file-lock owner, acquired through inherited fd 3
using macOS `lockf`. Closing/exiting releases the lock; sidecars stay in place.
OMP inherits the topic's locked descriptor, keeping accepted work exclusive if
its runner exits before the child.
No directory or separately published PID/owner file decides admission, and no
age permits stealing a live lock. An existing directory at a lock path is an
unavailable source to reconcile, never guessed abandoned. OMP claim recovery
compares the recorded process start identity, so a reused PID is not its owner;
missing identity stays unavailable. Pending rows, reply jobs/entries and OMP
jobs/payloads require their current `lifeID`; missing stamps have no synthetic
life. New records and request IDs carry no hung-turn replay fields or suffix.
Only the current durable admission constructs a reply job; a sent result without
its `replyDelivery` contract reports unknown execution and defers inbox consumption.

Rollout snapshots decode only newline-committed bytes, including UTF-8 framing;
an unfinished tail waits for the writer's next boundary and a malformed complete
row reports unavailable. OMP parses complete JSON events as stdout arrives and
retains protocol state separately from bounded diagnostic tails. Silence never
terminates OMP; its requested wall-clock execution limit and owned process-group
cleanup remain. A failed exact Codex `turn/interrupt` retains its cause and unknown
execution in `hangRecovery.interruption` and `hang-watchdog.jsonl`; it never kills
the shared daemon, removes lane locks or restarts the server as a substitute.

Requested live progress owns a separate availability receipt (`liveProgress`)
in the job and delivery receipt. Bad configuration, HTTP errors and transport
deadlines say unavailable; they do not change the execution or completion result.
Undelivered-reply retention leaves unknown-age files untouched and reports its
incomplete inventory rather than treating them as the oldest replies.

## Server version before launch

Every work-start connection checks the app-server's reported version against
the selected CLI's reported version before sending work. Both versions must
be present and equal; missing or unreadable control output is not alignment.
On drift, the current request waits for the existing detached idle-daemon
healer, then rereads the versions. The foreground version gate has an eight-second
deadline and at most two control-start calls, each capped at four seconds.
Waiting ends at the deadline without cancelling the healer. If alignment is
still unproven, the receipt says Codex is restarting and to try again; no turn
is sent to the stale server. A later queue attempt checks afresh.

The healer holds all wake-capacity slots and verifies loaded threads are idle
before `stopDaemonForRestart` and `daemonControlStart`. Queue consumers connect
before acquiring their execution slot so they cannot hold up the restart they
are waiting for. Reconnection uses the ordinary owner-aware orphan-socket
cleanup. `daemon-heal.jsonl` beside the wakeup config retains restart results;
the current helper receipt carries `daemonHeal` when drift was found.
The gate compares versions only; it adds no executable identity checks or
persisted launch authority. Connect-only thread reads and interrupts retain
their existing paths and do not launch work.

## Trust is asked at launch

A queued entry's stamped launch is the decision for its origin when it was
queued; it never outranks Trust at the moment it runs. Every launch (a fresh
thread, a turn start, and a retained reply job's turn start before it is marked
dispatched) asks the app's bridge `GET /codex/launch` for the Mac's current
ceiling and runs at the lower of the stamp and the ceiling. A Trust downgrade
therefore governs the next launch, queued or not. A paused or unreadable Trust
answers `denied`, and an unreachable bridge answers nothing; either way nothing
is launched and the receipt says why (`launch_blocked`,
`launch_decision_unavailable`). An entry with no stamp runs restricted.

## A conversation keeps its worktree

New Codex work selects a checkout only from explicit `working_directory` or
`repository`. An explicit repository must resolve to exactly one local clone
whose remote matches; ambiguity lists the candidates and requires the exact
working directory. Message text and topic never select a checkout or grant
the repository network execution profile. Omission keeps the bridge's ordinary
default-directory behavior. The allocator receives that one checked selection.

`BuilderWorktreeAllocator` retains the checkout assignment for a builder
conversation. A follow-up reuses that assignment. A different
`working_directory` does not move it: the send receipt reports
`workingDirectoryIgnored` and `directoryNote`. Omit that field on follow-ups.
First allocation is single-flight per config root, agent and conversation;
concurrent requests reread the winning assignment before probing a repository.
Conversation and checkout reservation waits respond to Stop: a canceled waiter
leaves the queue, and a cancellation racing ownership transfer releases that
ownership exactly once before returning.

New allocation can retire up to three checkouts idle for seven days. Reuse
refreshes the pointer's mtime; all pointers to a checkout participate in the
idle decision. Dirty work, untracked files, unique commits and uncertain
ownership prevent retirement. Retirement reserves the checkout across Git
checks and removal, rereading freshness while held; reuse and binding wait for
that reservation and revalidate before publishing. Removal uses `git worktree remove` and preserves
the branch. Removal outcomes are recorded as `builder.worktree_retirement` events in the
turn trace (`turn_traces/<yyyy-MM-dd>.jsonl`).

## desk_item is optional

The `app` actions `codex.message` and `omp.message`
accept `desk_item`. Supply only a live handle obtained through `desk.read`.
An unresolved handle is dropped while the message is delivered; the receipt
reports `deskItemIgnored`.

## Talking with the resident Agent

The authenticated `/codex/message` route enters Agent's app-owned conversation.
Continue its NativeAgent session identity; it is different from a Codex builder
thread. `/codex/reply` recovers an exact session/request pair after an uncertain
response. Check that evidence before repeating a message.

The reverse `app` action `codex.message` dispatches builder work. Do not
substitute a new builder task for continuing the resident conversation.
