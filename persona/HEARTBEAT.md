# HEARTBEAT — periodic self-check

Reply exactly `HEARTBEAT_OK` if, and only if, every item below checks out
against the live signals. Anything off — even slightly — describe what and
why instead.

- Doctor: no failing checks.
- Workshop executions: nothing stuck (no execution running or blocked far
  longer than its kind should take).
- Evolution: no pending self-evolution run sitting unverified past a restart.
- Full Mac: it's a persistent on/off grant, not a timed one. If it's on, the
  saved grant is healthy: it reads back as Full Mac and matches what the
  Trust page shows.
- Errors: no unusual error burst in the recent log window.
