import Foundation
import Observation
import NativeAgentShared
import PersistenceCore
import TrustCenter

// PATCH-2026-05-29: dreams-tab Decodable models for the dream/REM diary surface.
// Keys match the retired daemon exactly:
//   list_entries()/latest_entry() -> {date, filename, content, size, modified_at}
//   get_entry()                   -> {date, filename, content, size}  (no modified_at)
// The diary endpoint wraps entries in {"entries": [...], "enabled": <bool>} where
// `enabled` is the COMPOSITE dream gate (trainingPolicy.dream_scheduler AND
// personalityPolicy.dream_cycle_enabled), per /v1/dream/diary in the retired daemon.
