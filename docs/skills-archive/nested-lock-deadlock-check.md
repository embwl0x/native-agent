# Nested Lock Deadlock Check

## When to Use
Use this when a Swift service, scheduler, actor, or config manager hangs during construction, startup, or a mutating method that uses locks or actor hops.

## Procedure
1. Inspect the call path for a method that acquires a lock and then calls another method that also acquires the same lock.
2. Pay special attention to initializers calling load/refresh methods, and public methods like `setEnabled()` or `updateConfig()` calling list/read helpers.
3. Reproduce the suspected hang with a short timeout or alarm so the failure is explicit instead of an indefinite stall.
4. If the same object lock is acquired recursively, prefer one of two fixes:
   - Use a reentrant lock only when reentrant access is intentional and bounded.
   - Split helpers into locked and unlocked variants, where callers that already hold the lock use the unlocked helper.
5. Validate the fix by constructing the affected object and exercising the public methods that previously nested lock acquisition.
6. In review notes, include the exact nested call chain, the lock type, the reproduction timeout result, and any verification that remained blocked by the environment.
