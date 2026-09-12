# Codex bridge: ownership and interactive conversation

NativeAgent's Codex worker and Codex Desktop can use different app-server
processes while sharing the same history. Runtime status is server-local.
On 2026-09-04 the desktop reported an Astra worker as `notLoaded/interrupted`
with no completion time while the bridge server reported the same turn
`active/inProgress`. The original writer subsequently completed. This was
not evidence that the worker had stopped.

## Before replacing supposedly interrupted work

Use Agent's `delegation_status` with the exact `message_id` to find the recorded
thread/turn. For an owning-server diagnosis, run from this checkout:

```sh
node script/codex_thread_wakeup.js --read-thread codex:<thread-id>
```

This connects only to the existing bridge app-server socket and reads that
exact thread. It does not start/heal a daemon, resume a thread, send a turn,
or print conversation content. `unknown` or an unavailable socket is not
cancellation and never authorizes replay. Do not use `--probe` as a read-only
substitute: its connection path can start/heal the daemon.

An unloaded interrupted projection is no longer terminal evidence for the
completion watcher: require the saved `task_complete`/`turn_aborted` event or
an exact live completion event. Real loaded-server cancellations remain
cancellations. This protects bridge settlement; it does not alter Codex
Desktop's own status display. An `active writer` error means coordinate with
the existing writer, not launch another one in the same checkout.

## A conversation keeps its worktree

A builder conversation is allocated one checkout, and the pointer for that
conversation is the assignment. A follow-up (any send carrying a
`conversation_id`) reuses it. If the follow-up also passes a
`working_directory`, the existing assignment wins: both paths are resolved and
compared, and on a mismatch the message is still delivered, the pointer's
last-use clock is touched, and the receipt carries `workingDirectoryIgnored`
with the resolved path it ignored plus a `directoryNote` saying to omit
`working_directory` on follow-ups. Refusing the send for naming a different
directory was the failure mode this replaces. All three lanes — Claude, Codex
and OMP — stamp it identically, and their schemas promise it.

Retirement is paid for by allocation, not by a loop: taking new disk for a new
worktree is the one place `BuilderWorktreeAllocator` looks for idle ones, at
most three removals per sweep. Idleness is the pointer file's mtime, refreshed
on every reuse, and judged across **every** pointer naming a checkout — a
bootstrap alias and a later thread binding can name the same directory, and a
stale alias must not retire a live checkout. The cutoff is 7 days.

Every test is fail-closed: an unreadable or short pointer, a missing directory,
a directory that is not a worktree of this repo, a HEAD or basename that does
not match the expected `nativeagent/<agent>-<token>` branch and `-wt-<agent>-<token>`
suffix, anything dirty or untracked, or any commit unique to the branch, all
keep the worktree. Removal is `git worktree remove`, and the **branch is never
deleted**, so a retired worktree can be recreated at its own tip. Refusals are
receipted as well as removals: one JSONL line per decision in
`nativeagent-builder-worktrees/retirements.jsonl` under the config root, with
the worktree, branch, last touch, idle days and either `retired` or
`remove_refused` with the bounded git output that refused it.

## desk_item is optional

`claude_message`, `codex_message` and `omp_message` take an optional
`desk_item`. Omit it unless holding an exact live handle from a `desk_read`
result. A value that does not resolve to a live item does not fail the send: the
message is delivered without a Desk binding, and the receipt says
`deskItemIgnored` with a note naming what was dropped. Only a stable resolved
handle crosses into bridge job evidence, and nothing is inferred from a title or
topic. A message is worth more than its Desk link, so the link is what gives
way.

## A reply-free delivery is a notice

A wake delivery whose outcome was only "delivered" comes back marked as a
notice and is enqueued with `ackMode: "enqueue_only"`: it lands in the
transcript as an informational row and starts no turn. Its text says it is
recorded for reference and asks for nothing. Do not read a notice as a question
the agent declined to answer.

Everything else over the bridge is a full turn. A bridge-started session digests
like any conversation and its procedural lane learns from it: the seat on the
other side being Claude or Codex rather than User does not make the turn a
machine log.

## Talking with the resident Agent

Codex already has the same authenticated local conversation path Claude
uses. The `agent-bridge` skill's `send.sh "text" [sessionId]` calls
`/codex/message` with Codex identity and returns Agent's reply. Continue the
returned NativeAgent session ID for an interactive exchange; do not mistake
it for a Codex builder thread ID. A client timeout does not prove Agent's
turn stopped: inspect that session before repeating the request.

The reverse `codex_message` path normally creates a separate builder task.
Claude's interactive inbox hook is a different mechanism: seeing an open
Claude process is not proof Codex has an equivalent delivery hook. Do not
silently point the bridge worker daemon at an active desktop-owned task,
mark an unread inbox message consumed, or spawn a worker merely to chat.
