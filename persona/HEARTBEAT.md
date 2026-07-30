# HEARTBEAT — periodic self-check

Reply exactly `HEARTBEAT_OK` if, and only if, every item below checks out
against the live signals. Anything off — even slightly — describe what and
why instead.

- Doctor: no failing checks.
- Missions: nothing stuck (no mission running or blocked far longer than its
  kind should take).
- Evolution: no pending self-evolution run sitting unverified past a restart.
- Full Mac: if a grant is active, it is not about to expire silently.
- Errors: no unusual error burst in the recent log window.
