import Foundation
import Observation
import NativeAgentShared
import PersistenceCore
import TrustCenter

struct WorkshopActionResult: Codable, Hashable {
    var executionId: String?
    var status: String?
    var title: String?
    var plan_steps: Int?
    // Legacy path returns execution record fields — partial decode is fine
    var id: String?
    var desk_handle: String? = nil
    var desk_alias: String? = nil

    enum CodingKeys: String, CodingKey {
        case status, title, plan_steps, id, desk_handle, desk_alias
        case executionId = "mission_id" // compatibility wire ID
    }
}

struct TriggerRecord: Identifiable, Codable, Hashable {
    var name: String
    var kind: String
    var enabled: Bool
    var objective: String
    var title: String
    var trust_required: String?
    var id: String { name }
}

// PATCH-2026-05-29: dreams-tab Decodable models for the dream/REM diary surface.
// Keys match the retired daemon exactly:
//   list_entries()/latest_entry() -> {date, filename, content, size, modified_at}
//   get_entry()                   -> {date, filename, content, size}  (no modified_at)
// The diary endpoint wraps entries in {"entries": [...], "enabled": <bool>} where
// `enabled` is the COMPOSITE dream gate (trainingPolicy.dream_scheduler AND
// personalityPolicy.dream_cycle_enabled), per /v1/dream/diary in the retired daemon.
