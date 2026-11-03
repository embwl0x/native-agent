# HEARTBEAT — periodic self-check

This file is an enable gate for the native heartbeat. Any nonempty content
enables its deterministic assessment; these words are not an interpreted
checklist or a reply protocol. A missing, unreadable or whitespace-only file
turns the heartbeat off without claiming health.

`HeartbeatBackgroundWork.gatherHeartbeatAssessment` owns the checks: Doctor's
snapshot, stuck Workshop executions, recent error bursts, stale tasks and
durable residue. Clean assessments complete without a model call or a chat
reply. Anomalies surface stable notice cards; a failure to stage a notice is
reported as a failed tick. Changing this text does not configure the checks.
