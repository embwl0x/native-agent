import Foundation
import Observation
import NativeAgentShared
import PersistenceCore

struct ImprovementGauntletStatus: Codable, Hashable {
    var status: String
    var promotionClasses: [PromotionClassRecord]
    var latestRun: ImprovementGauntletRun?
    var runCount: Int
    var createdAt: String?
}

struct PromotionClassRecord: Identifiable, Codable, Hashable {
    var id: String
    var autoPromote: Bool?
    var requiredChecks: [String]?
}

struct ImprovementGauntletRun: Identifiable, Codable, Hashable {
    var id: String
    var objective: String?
    var promotionClass: String?
    var status: String
    var dryRun: Bool?
    var checks: [GauntletCheck]?
    var createdAt: String?
}

struct GauntletCheck: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var passed: Bool
    var detail: String?
}

struct ProductionHardeningSummary: Codable, Hashable {
    var status: String
    var release: ReleaseChecklist?
    var doctorStatus: String?
    var createdAt: String?
}

struct ProductionExport: Identifiable, Codable, Hashable {
    var id: String
    var kind: String?
    var path: String
    var scope: [String]
    var checksum: String?
    var sizeBytes: Int?
    var createdAt: String?
}

struct NextGenSummary: Decodable, Hashable {
    var status: String?
    var readiness: String?
    var roadmap: String?
    var currentPhaseId: String?
    var currentPhaseName: String?
    var readyPhaseCount: Int?
    var totalPhaseCount: Int?
    var actionCount: Int?
    var receiptCount: Int?
    var phaseRange: NextGenPhaseRange?
    var phases: [NextGenPhase]?
    var actions: [NextGenAction]?
    var latestReceipts: [NextGenReceipt]?
    var receipts: [NextGenReceipt]?
    var latestReceipt: NextGenReceipt?
    var nextRecommendedPhases: [String]?
    var createdAt: String?
    var updatedAt: String?

    var displayReceipts: [NextGenReceipt] {
        var seen = Set<String>()
        let combined = (latestReceipts ?? []) + (receipts ?? []) + (latestReceipt.map { [$0] } ?? [])
        return combined.filter { seen.insert($0.id).inserted }
    }

    var readinessStatus: String {
        if let status, !status.isEmpty {
            return status
        }
        if let readiness, !readiness.isEmpty {
            return readiness
        }
        guard let readyPhaseCount, let totalPhaseCount, totalPhaseCount > 0 else {
            return "warn"
        }
        return readyPhaseCount == totalPhaseCount ? "ready" : "warn"
    }

    enum CodingKeys: String, CodingKey {
        case status
        case readiness
        case roadmap
        case currentPhaseId
        case current_phase_id
        case currentPhaseName
        case current_phase_name
        case readyPhaseCount
        case ready_phase_count
        case totalPhaseCount
        case total_phase_count
        case actionCount
        case action_count
        case receiptCount
        case receipt_count
        case phaseRange
        case phase_range
        case phases
        case actions
        case latestReceipts
        case latest_receipts
        case receipts
        case latestReceipt
        case latest_receipt
        case nextRecommendedPhases
        case next_recommended_phases
        case createdAt
        case created_at
        case updatedAt
        case updated_at
        case readyCount
        case ready_count
        case phaseCount
        case phase_count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try NextGenCoding.decodeString(container, .status)
        readiness = try NextGenCoding.decodeString(container, .readiness)
        roadmap = try NextGenCoding.decodeString(container, .roadmap)
        currentPhaseId = try NextGenCoding.decodeString(container, .currentPhaseId, .current_phase_id)
        currentPhaseName = try NextGenCoding.decodeString(container, .currentPhaseName, .current_phase_name)
        readyPhaseCount = try NextGenCoding.decodeInt(container, .readyPhaseCount, .ready_phase_count, .readyCount, .ready_count)
        totalPhaseCount = try NextGenCoding.decodeInt(container, .totalPhaseCount, .total_phase_count, .phaseCount, .phase_count)
        actionCount = try NextGenCoding.decodeInt(container, .actionCount, .action_count)
        receiptCount = try NextGenCoding.decodeInt(container, .receiptCount, .receipt_count)
        phaseRange = try NextGenCoding.decodeObject(container, .phaseRange, .phase_range)
        phases = try NextGenCoding.decodeArray(container, .phases)
        actions = try NextGenCoding.decodeArray(container, .actions)
        latestReceipts = try NextGenCoding.decodeArray(container, .latestReceipts, .latest_receipts)
        receipts = try NextGenCoding.decodeArray(container, .receipts)
        latestReceipt = try NextGenCoding.decodeObject(container, .latestReceipt, .latest_receipt)
        nextRecommendedPhases = try NextGenCoding.decodeStringArray(container, .nextRecommendedPhases, .next_recommended_phases)
        createdAt = try NextGenCoding.decodeString(container, .createdAt, .created_at)
        updatedAt = try NextGenCoding.decodeString(container, .updatedAt, .updated_at)
    }
}

struct NextGenPhaseRange: Decodable, Hashable {
    var start: Int?
    var end: Int?

    var displayValue: String? {
        guard let start, let end else { return nil }
        return start == end ? "\(start)" : "\(start)-\(end)"
    }

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case from
        case to
        case min
        case max
    }

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            let parts = value
                .split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }
            start = parts.first
            end = parts.dropFirst().first ?? parts.first
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try NextGenCoding.decodeInt(container, .start, .from, .min)
        end = try NextGenCoding.decodeInt(container, .end, .to, .max)
    }
}

struct NextGenPhase: Identifiable, Decodable, Hashable {
    var id: String
    var name: String?
    var title: String?
    var phase: String?
    var status: String?
    var readiness: String?
    var ready: Bool?
    var detail: String?
    var summary: String?
    var receiptCount: Int?
    var dryRunActionId: String?
    var probeActionId: String?
    var actions: [NextGenAction]?
    var latestReceipt: NextGenReceipt?
    var createdAt: String?
    var updatedAt: String?

    var phaseNumber: Int? {
        NextGenCoding.phaseNumber(from: phase) ?? NextGenCoding.phaseNumber(from: id)
    }

    var displayName: String {
        let base = name ?? title ?? phase ?? id
        guard let phaseNumber else { return base }
        let prefix = "Phase \(phaseNumber)"
        if base.localizedCaseInsensitiveContains(prefix) {
            return base
        }
        return "\(prefix) · \(base)"
    }

    var displayStatus: String {
        if ready == true {
            return "ready"
        }
        return status ?? readiness ?? "warn"
    }

    var displayDetail: String {
        if let detail, !detail.isEmpty {
            return detail
        }
        if let summary, !summary.isEmpty {
            return summary
        }
        if let receiptCount {
            return "\(receiptCount) receipt(s)"
        }
        return id
    }

    var primaryDryRunActionId: String? {
        if let dryRunActionId, !dryRunActionId.isEmpty {
            return dryRunActionId
        }
        if let probeActionId, !probeActionId.isEmpty {
            return probeActionId
        }
        return actions?.first?.id
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case title
        case phase
        case phaseId
        case phase_id
        case status
        case readiness
        case ready
        case detail
        case summary
        case receiptCount
        case receipt_count
        case dryRunActionId
        case dry_run_action_id
        case probeActionId
        case probe_action_id
        case actions
        case latestReceipt
        case latest_receipt
        case createdAt
        case created_at
        case updatedAt
        case updated_at
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedPhase = try NextGenCoding.decodeString(container, .phase)
        let decodedPhaseId = try NextGenCoding.decodeString(container, .phaseId, .phase_id)
        id = try NextGenCoding.decodeString(container, .id) ?? decodedPhaseId ?? decodedPhase ?? UUID().uuidString
        name = try NextGenCoding.decodeString(container, .name)
        title = try NextGenCoding.decodeString(container, .title)
        phase = decodedPhase
        status = try NextGenCoding.decodeString(container, .status)
        readiness = try NextGenCoding.decodeString(container, .readiness)
        ready = try NextGenCoding.decodeBool(container, .ready)
        detail = try NextGenCoding.decodeString(container, .detail)
        summary = try NextGenCoding.decodeString(container, .summary)
        receiptCount = try NextGenCoding.decodeInt(container, .receiptCount, .receipt_count)
        dryRunActionId = try NextGenCoding.decodeString(container, .dryRunActionId, .dry_run_action_id)
        probeActionId = try NextGenCoding.decodeString(container, .probeActionId, .probe_action_id)
        actions = try NextGenCoding.decodeArray(container, .actions)
        latestReceipt = try NextGenCoding.decodeObject(container, .latestReceipt, .latest_receipt)
        createdAt = try NextGenCoding.decodeString(container, .createdAt, .created_at)
        updatedAt = try NextGenCoding.decodeString(container, .updatedAt, .updated_at)
    }
}

struct NextGenAction: Identifiable, Decodable, Hashable {
    var id: String
    var name: String?
    var title: String?
    var phaseId: String?
    var kind: String?
    var status: String?
    var risk: String?
    var description: String?
    var dryRunAvailable: Bool?
    var requiresApproval: Bool?

    var displayName: String {
        name ?? title ?? id
    }

    var displayStatus: String {
        status ?? risk ?? "ready"
    }

    var displayDetail: String {
        if let description, !description.isEmpty {
            return description
        }
        return phaseId ?? kind ?? "Dry-run probe"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case actionId
        case action_id
        case name
        case title
        case phase
        case phaseId
        case phase_id
        case kind
        case group
        case category
        case status
        case risk
        case description
        case detail
        case dryRunAvailable
        case dry_run_available
        case requiresApproval
        case requires_approval
    }

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let value = try? single.decode(String.self) {
            id = value
            name = nil
            title = nil
            phaseId = nil
            kind = nil
            status = nil
            risk = nil
            description = nil
            dryRunAvailable = true
            requiresApproval = nil
            return
        }
        if let value = try? single.decode(Int.self) {
            id = String(value)
            name = nil
            title = nil
            phaseId = nil
            kind = nil
            status = nil
            risk = nil
            description = nil
            dryRunAvailable = true
            requiresApproval = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try NextGenCoding.decodeString(container, .id, .actionId, .action_id) ?? UUID().uuidString
        name = try NextGenCoding.decodeString(container, .name)
        title = try NextGenCoding.decodeString(container, .title)
        phaseId = try NextGenCoding.decodeString(container, .phaseId, .phase_id, .phase)
        kind = try NextGenCoding.decodeString(container, .kind, .group, .category)
        status = try NextGenCoding.decodeString(container, .status)
        risk = try NextGenCoding.decodeString(container, .risk)
        description = try NextGenCoding.decodeString(container, .description, .detail)
        dryRunAvailable = try NextGenCoding.decodeBool(container, .dryRunAvailable, .dry_run_available)
        requiresApproval = try NextGenCoding.decodeBool(container, .requiresApproval, .requires_approval)
    }
}

struct NextGenReceipt: Identifiable, Decodable, Hashable {
    var receiptId: String?
    var actionId: String?
    var phaseId: String?
    var name: String?
    var status: String?
    var dryRun: Bool?
    var approvalId: String?
    var detail: String?
    var output: String?
    var createdAt: String?

    var id: String {
        receiptId ?? "\(createdAt ?? "nextgen")-\(actionId ?? phaseId ?? name ?? status ?? "receipt")"
    }

    var displayName: String {
        name ?? actionId ?? phaseId ?? id
    }

    var displayStatus: String {
        status ?? "recorded"
    }

    var displayDetail: String {
        detail ?? output ?? createdAt ?? actionId ?? "Next-gen receipt"
    }

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

    init(
        receiptId: String? = nil,
        actionId: String? = nil,
        phaseId: String? = nil,
        name: String? = nil,
        status: String? = nil,
        dryRun: Bool? = nil,
        approvalId: String? = nil,
        detail: String? = nil,
        output: String? = nil,
        createdAt: String? = nil
    ) {
        self.receiptId = receiptId
        self.actionId = actionId
        self.phaseId = phaseId
        self.name = name
        self.status = status
        self.dryRun = dryRun
        self.approvalId = approvalId
        self.detail = detail
        self.output = output
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case receiptId
        case receipt_id
        case actionId
        case action_id
        case phaseId
        case phase_id
        case phase
        case name
        case title
        case status
        case dryRun
        case dry_run
        case approvalId
        case approval_id
        case detail
        case output
        case createdAt
        case created_at
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        receiptId = try NextGenCoding.decodeString(container, .receiptId, .receipt_id, .id)
        actionId = try NextGenCoding.decodeString(container, .actionId, .action_id)
        phaseId = try NextGenCoding.decodeString(container, .phaseId, .phase_id, .phase)
        name = try NextGenCoding.decodeString(container, .name, .title)
        status = try NextGenCoding.decodeString(container, .status)
        dryRun = try NextGenCoding.decodeBool(container, .dryRun, .dry_run)
        approvalId = try NextGenCoding.decodeString(container, .approvalId, .approval_id)
        detail = try NextGenCoding.decodeString(container, .detail)
        output = try NextGenCoding.decodeString(container, .output)
        createdAt = try NextGenCoding.decodeString(container, .createdAt, .created_at)
    }
}

struct NextGenPhasesResponse: Decodable, Hashable {
    var phases: [NextGenPhase]
    var createdAt: String?

    init(phases: [NextGenPhase], createdAt: String? = nil) {
        self.phases = phases
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case phases
        case items
        case records
        case createdAt
        case created_at
    }

    init(from decoder: Decoder) throws {
        if let phases = try? [NextGenPhase](from: decoder) {
            self.phases = phases
            self.createdAt = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        phases = try NextGenCoding.decodeArray(container, .phases, .items, .records) ?? []
        createdAt = try NextGenCoding.decodeString(container, .createdAt, .created_at)
    }
}

struct NextGenReceiptsResponse: Decodable, Hashable {
    var receipts: [NextGenReceipt]

    enum CodingKeys: String, CodingKey {
        case receipts
        case latestReceipts
        case latest_receipts
        case latestReceipt
        case latest_receipt
        case items
        case records
    }

    init(from decoder: Decoder) throws {
        if let receipts = try? [NextGenReceipt](from: decoder) {
            self.receipts = receipts
            return
        }

        if let lossy = try? LossyDecodableArray<NextGenReceipt>(from: decoder) {
            self.receipts = lossy.elements
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        var combined: [NextGenReceipt] =
            (try NextGenCoding.decodeArray(container, .receipts, .items, .records) ?? []) +
            (try NextGenCoding.decodeArray(container, .latestReceipts, .latest_receipts) ?? [])
        if let latest: NextGenReceipt = try NextGenCoding.decodeObject(container, .latestReceipt, .latest_receipt) {
            combined.insert(latest, at: 0)
        }

        var seen = Set<String>()
        receipts = combined.filter { seen.insert($0.id).inserted }
    }
}

struct NextGenActionResponse: Decodable, Hashable {
    var responseId: String?
    var actionId: String?
    var phaseId: String?
    var name: String?
    var status: String?
    var dryRun: Bool?
    var detail: String?
    var output: String?
    var receipt: NextGenReceipt?
    var receipts: [NextGenReceipt]?
    var summary: NextGenSummary?
    var createdAt: String?

    var displayReceipt: NextGenReceipt {
        if let receipt {
            return receipt
        }
        if let first = receipts?.first {
            return first
        }
        if let first = summary?.displayReceipts.first {
            return first
        }
        return NextGenReceipt(
            receiptId: responseId,
            actionId: actionId,
            phaseId: phaseId,
            name: name,
            status: status ?? "recorded",
            dryRun: dryRun,
            detail: detail,
            output: output,
            createdAt: createdAt
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case responseId
        case response_id
        case actionId
        case action_id
        case phaseId
        case phase_id
        case phase
        case name
        case title
        case status
        case dryRun
        case dry_run
        case detail
        case output
        case receipt
        case receipts
        case latestReceipt
        case latest_receipt
        case summary
        case createdAt
        case created_at
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        responseId = try NextGenCoding.decodeString(container, .responseId, .response_id, .id)
        actionId = try NextGenCoding.decodeString(container, .actionId, .action_id)
        phaseId = try NextGenCoding.decodeString(container, .phaseId, .phase_id, .phase)
        name = try NextGenCoding.decodeString(container, .name, .title)
        status = try NextGenCoding.decodeString(container, .status)
        dryRun = try NextGenCoding.decodeBool(container, .dryRun, .dry_run)
        detail = try NextGenCoding.decodeString(container, .detail)
        output = try NextGenCoding.decodeString(container, .output)
        receipt = try NextGenCoding.decodeObject(container, .receipt, .latestReceipt, .latest_receipt)
        receipts = try NextGenCoding.decodeArray(container, .receipts)
        summary = try? container.decodeIfPresent(NextGenSummary.self, forKey: .summary)
        createdAt = try NextGenCoding.decodeString(container, .createdAt, .created_at)
    }
}

private enum NextGenCoding {
    static func decodeString<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ keys: K...) throws -> String? {
        for key in keys {
            if let value = decodeSingleString(container, key) {
                return value
            }
        }
        return nil
    }

    private static func decodeSingleString<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return value ? "true" : "false"
        }
        if let value = try? container.decodeIfPresent(NextGenJSONValue.self, forKey: key) {
            return value.displayString
        }
        return nil
    }

    static func decodeInt<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ keys: K...) throws -> Int? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return Int(value)
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let intValue = phaseNumber(from: value) {
                return intValue
            }
            if let value = try? container.decodeIfPresent(NextGenJSONValue.self, forKey: key),
               let intValue = value.intValue {
                return intValue
            }
        }
        return nil
    }

    static func decodeBool<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ keys: K...) throws -> Bool? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value != 0
            }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return value != 0
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let boolValue = bool(from: value) {
                return boolValue
            }
            if let value = try? container.decodeIfPresent(NextGenJSONValue.self, forKey: key),
               let boolValue = value.boolValue {
                return boolValue
            }
        }
        return nil
    }

    static func decodeStringArray<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ keys: K...) throws -> [String]? {
        for key in keys {
            if let values = try? container.decodeIfPresent([String].self, forKey: key) {
                return values
            }
            if let values = try? container.decodeIfPresent([NextGenJSONValue].self, forKey: key) {
                return values.map(\.displayString)
            }
            if let value = try decodeString(container, key) {
                return [value]
            }
        }
        return nil
    }

    static func decodeArray<T: Decodable, K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ keys: K...) throws -> [T]? {
        for key in keys {
            if let values = try? container.decodeIfPresent([T].self, forKey: key) {
                return values
            }
            if let values = try? container.decodeIfPresent(LossyDecodableArray<T>.self, forKey: key) {
                return values.elements
            }
            if let value = try? container.decodeIfPresent(T.self, forKey: key) {
                return [value]
            }
        }
        return nil
    }

    static func decodeObject<T: Decodable, K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ keys: K...) throws -> T? {
        for key in keys {
            if let value = try? container.decodeIfPresent(T.self, forKey: key) {
                return value
            }
            if let values = try? container.decodeIfPresent([T].self, forKey: key) {
                return values.first
            }
            if let values = try? container.decodeIfPresent(LossyDecodableArray<T>.self, forKey: key) {
                return values.elements.first
            }
        }
        return nil
    }

    static func phaseNumber(from value: String?) -> Int? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let intValue = Int(trimmed) {
            return intValue
        }
        if let doubleValue = Double(trimmed) {
            return Int(doubleValue)
        }
        return trimmed
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
            .first
    }

    private static func bool(from value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "y", "1", "ready", "ok", "succeeded", "success":
            return true
        case "false", "no", "n", "0", "not_ready", "blocked", "failed", "fail":
            return false
        default:
            return nil
        }
    }
}

private struct LossyDecodableArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let value = try? container.decode(Element.self) {
                elements.append(value)
            } else {
                _ = try? container.decode(NextGenJSONValue.self)
            }
        }
        self.elements = elements
    }
}

enum NextGenJSONValue: Decodable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: NextGenJSONValue])
    case array([NextGenJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else if let value = try? single.decode(Double.self) {
            self = .number(value)
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode([String: NextGenJSONValue].self) {
            self = .object(value)
        } else if let value = try? single.decode([NextGenJSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    var displayString: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            if value.rounded() == value {
                return String(Int(value))
            }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        case .array(let values):
            return values.map(\.displayString).joined(separator: ", ")
        case .object(let object):
            return object
                .sorted { $0.key < $1.key }
                .prefix(4)
                .map { "\($0.key): \($0.value.displayString)" }
                .joined(separator: ", ")
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let value):
            return Int(value)
        case .string(let value):
            return NextGenCoding.phaseNumber(from: value)
        case .bool(let value):
            return value ? 1 : 0
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .number(let value):
            return value != 0
        case .string(let value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "y", "1", "ready", "ok", "succeeded", "success":
                return true
            case "false", "no", "n", "0", "not_ready", "blocked", "failed", "fail":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
