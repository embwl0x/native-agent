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

Every unit of work has **one owner** that holds its record. The record moves
from running to exactly one terminal state, written at settlement:

- **done**: the effect completed;
- **stopped**: Stop ended it; the record keeps what it produced or sent
  ("sent to Grok; any answer stays in that chat");
- **failed**: it broke; the record says how.

Restoring changes the data-root life. Work from another life, or unstamped work,
reads **stopped**, reason **restored**. Resume starts fresh work in the new life;
the [restore law](canonical_data_paths.md#restore-law) owns this boundary.

No intermediate state ("stopping", "waiting" after the waiter is gone) is ever
persisted, and nothing promises what can no longer happen.

What was already sent stays sent and the record says so. What was produced is
saved once, never twice and never zero times. A store closes only after every
unit allowed to write to it has settled.

This is NORTHSTAR clause 2 (no theater) applied to Stop: every receipt records
something that actually ran.
