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
