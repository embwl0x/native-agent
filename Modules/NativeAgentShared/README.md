# Waiting for an operation

`ContinuationOnce` holds one operation's result. The first caller to resolve it wins. Its `beforeResume` closure runs outside the mutex and finishes before the waiting task receives the result. A continuation installed during that closure receives the same result.

`ScopedWaiter` can park several tasks on one event. Each park has its own identity. Cancellation or expiry releases that park, even if it races registration. A producer calling `resume()` releases all remaining parks and makes later parks return immediately.

Both primitives resume continuations after releasing their mutex. The producer supplies the outcome and owns settlement. See [Turn resilience](../../docs/TURN_RESILIENCE.md) and [Stop](../../docs/STOP.md).

## Caller contracts

A busy sidecar parks the caller while a dedicated thread waits in `flock`. Stop releases the caller with `CancellationError`. If the thread subsequently acquires the lock, it releases the descriptor itself. A one-attempt async acquisition reports `FileLockError.busy` on contention. A transaction that entered its body propagates the body's own error. A checked secret read or creation that fails reports `CheckedFixedSizeSecretFile.Unavailable` with the path and cause.

Mac workspace edges reach listeners synchronously so a launch is attributed while its work is still active. The Mac body nerve posts the notification representation of its typed `Edge` for that reason. Consent writes can deliver asynchronously because the receipt is durable before `ConsentDidWrite` is posted.

Ability changes and signals, bot-queue changes, and shelf writes likewise post the notification representation of their typed messages. Existing observers on the posting thread still see the same name, object, and payload before the writer returns. A bot definition change has no queue root; an enqueue carries its data root.

A managed process group records a signal or reap failure under its mutex, then notifies its owner after unlocking. Deadline changes and Stop still belong to the held turn; releasing a lock never decides whether its work settled.
