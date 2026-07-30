#!/usr/bin/env bash
# Thin wrapper — the sampler now lives in script/cognition_eval.sh (organism
# mode). Kept as a stable entry point: organism_doctor.sh and the organism docs
# call this name directly. Env: NATIVE_AGENT_ORGANISM_EVAL_{RUN_ID,DAY_INDEX,NOTE}.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cognition_eval.sh" organism "$@"
