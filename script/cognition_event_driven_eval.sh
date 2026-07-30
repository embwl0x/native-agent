#!/usr/bin/env bash
# Thin wrapper — the sampler now lives in script/cognition_eval.sh (cognition
# mode). Kept as a stable entry point: the living-fabric docs call this name
# directly. Env: NATIVE_AGENT_COGNITION_EVAL_{RUN_ID,DAY_INDEX,NOTE}.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cognition_eval.sh" cognition "$@"
