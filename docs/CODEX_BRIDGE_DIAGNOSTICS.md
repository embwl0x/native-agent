# Codex bridge: ownership and interactive conversation

Runtime status is app-server-local. A desktop projection of
`notLoaded` or `interrupted` does not establish that the bridge's writer stopped.

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

The completion watcher reconciles exact durable `task_complete` /
`turn_aborted` evidence with server state. Retained answer text alone does not
prove completion. Coordinate with an active writer before launching replacement
work in its checkout.

## A conversation keeps its worktree

`BuilderWorktreeAllocator` retains the checkout assignment for a builder
conversation. A follow-up reuses that assignment. A different
`working_directory` does not move it: the send receipt reports
`workingDirectoryIgnored` and `directoryNote`. Omit that field on follow-ups.

New allocation can retire up to three checkouts idle for seven days. Reuse
refreshes the pointer's mtime; all pointers to a checkout participate in the
idle decision. Dirty work, untracked files, unique commits and uncertain
ownership prevent retirement. Removal uses `git worktree remove` and preserves
the branch. Removal outcomes are recorded in
`nativeagent-builder-worktrees/retirements.jsonl` under the config root.

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
