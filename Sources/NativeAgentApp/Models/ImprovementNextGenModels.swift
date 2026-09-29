import DoctorChecks
import Foundation
import Observation
import NativeAgentShared
import PersistenceCore
import SelfImprovement

typealias ImprovementGauntletRun = SelfImprovement.ImprovementGauntletRun

typealias GauntletCheck = SelfImprovement.GauntletCheck

typealias ProductionHardeningSummary = DoctorChecks.ProductionHardeningSummary

struct ProductionExport: Identifiable, Codable, Hashable {
    var id: String
    var kind: String?
    var path: String
    var scope: [String]
    var checksum: String?
    var sizeBytes: Int?
    var createdAt: String?
}

typealias NextGenSummary = EngineRuntime.NextGenSummary
typealias NextGenPhaseRange = EngineRuntime.NextGenPhaseRange
typealias NextGenPhase = EngineRuntime.NextGenPhase
typealias NextGenAction = EngineRuntime.NextGenAction
typealias NextGenReceipt = EngineRuntime.NextGenReceipt
typealias NextGenPhasesResponse = EngineRuntime.NextGenPhasesResponse
typealias NextGenActionResponse = EngineRuntime.NextGenActionResponse
typealias NextGenJSONValue = EngineRuntime.NextGenJSONValue

extension NextGenReceipt {
    // 2026-06-07 ui-taste-sweep #83: receipt rows on Capabilities used to
    // render the raw `detail` string — comma-separated "key: value, key:
    // value, createdAt: <ISO>" dumps with microsecond timestamps. Users
    // can't parse that at a glance. `humanized` runs the parser in
    // UserDisplayFormatters.humanizeReceipt so the row shows
    // "Archived · stale duplicate · 5 days ago" and the raw kv pairs are
    // available for an inspector / disclosure. Falls back gracefully when
    // the detail isn't kv-shaped (free-form text passes through).
    var humanized: UserDisplayFormatters.HumanizedReceipt {
        UserDisplayFormatters.humanizeReceipt(
            name: name,
            detail: detail ?? output,
            fallbackTitle: actionId ?? phaseId ?? "Receipt"
        )
    }
}
