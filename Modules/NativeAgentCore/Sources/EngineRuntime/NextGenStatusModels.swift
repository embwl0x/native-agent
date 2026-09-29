import Foundation

public struct NextGenSummary: Decodable, Hashable {
    public var status: String?
    public var readiness: String?
    public var roadmap: String?
    public var currentPhaseId: String?
    public var currentPhaseName: String?
    public var readyPhaseCount: Int?
    public var totalPhaseCount: Int?
    public var actionCount: Int?
    public var receiptCount: Int?
    public var phaseRange: NextGenPhaseRange?
    public var phases: [NextGenPhase]?
    public var actions: [NextGenAction]?
    public var latestReceipts: [NextGenReceipt]?
    public var receipts: [NextGenReceipt]?
    public var latestReceipt: NextGenReceipt?
    public var nextRecommendedPhases: [String]?
    public var createdAt: String?
    public var updatedAt: String?

    public init(
        status: String,
        readiness: String,
        roadmap: String,
        currentPhaseId: String?,
        currentPhaseName: String?,
        readyPhaseCount: Int,
        totalPhaseCount: Int,
        actionCount: Int,
        receiptCount: Int,
        phaseRange: NextGenPhaseRange?,
        latestReceipts: [NextGenReceipt],
        createdAt: String,
        updatedAt: String
    ) {
        self.status = status
        self.readiness = readiness
        self.roadmap = roadmap
        self.currentPhaseId = currentPhaseId
        self.currentPhaseName = currentPhaseName
        self.readyPhaseCount = readyPhaseCount
        self.totalPhaseCount = totalPhaseCount
        self.actionCount = actionCount
        self.receiptCount = receiptCount
        self.phaseRange = phaseRange
        self.latestReceipts = latestReceipts
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayReceipts: [NextGenReceipt] {
        var seen = Set<String>()
        let combined = (latestReceipts ?? []) + (receipts ?? []) + (latestReceipt.map { [$0] } ?? [])
        return combined.filter { seen.insert($0.id).inserted }
    }

    public var readinessStatus: String {
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

    public init(from decoder: Decoder) throws {
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

public struct NextGenPhaseRange: Decodable, Hashable {
    public var start: Int?
    public var end: Int?

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public var displayValue: String? {
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

    public init(from decoder: Decoder) throws {
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

public struct NextGenPhase: Identifiable, Decodable, Hashable {
    public var id: String
    public var name: String?
    public var title: String?
    public var phase: String?
    public var status: String?
    public var readiness: String?
    public var ready: Bool?
    public var detail: String?
    public var summary: String?
    public var receiptCount: Int?
    public var dryRunActionId: String?
    public var probeActionId: String?
    public var actions: [NextGenAction]?
    public var latestReceipt: NextGenReceipt?
    public var createdAt: String?
    public var updatedAt: String?

    public var phaseNumber: Int? {
        NextGenCoding.phaseNumber(from: phase) ?? NextGenCoding.phaseNumber(from: id)
    }

    public var displayName: String {
        let base = name ?? title ?? phase ?? id
        guard let phaseNumber else { return base }
        let prefix = "Phase \(phaseNumber)"
        if base.localizedCaseInsensitiveContains(prefix) {
            return base
        }
        return "\(prefix) · \(base)"
    }

    public var displayStatus: String {
        if ready == true {
            return "ready"
        }
        return status ?? readiness ?? "warn"
    }

    public var displayDetail: String {
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

    public var primaryDryRunActionId: String? {
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

    public init(from decoder: Decoder) throws {
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

public struct NextGenAction: Identifiable, Decodable, Hashable {
    public var id: String
    public var name: String?
    public var title: String?
    public var phaseId: String?
    public var kind: String?
    public var status: String?
    public var risk: String?
    public var description: String?
    public var dryRunAvailable: Bool?
    public var requiresApproval: Bool?

    public var displayName: String {
        name ?? title ?? id
    }

    public var displayStatus: String {
        status ?? risk ?? "ready"
    }

    public var displayDetail: String {
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

    public init(from decoder: Decoder) throws {
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

public struct NextGenReceipt: Identifiable, Decodable, Hashable {
    public var receiptId: String?
    public var actionId: String?
    public var phaseId: String?
    public var name: String?
    public var status: String?
    public var dryRun: Bool?
    public var approvalId: String?
    public var detail: String?
    public var output: String?
    public var createdAt: String?

    public var id: String {
        receiptId ?? "\(createdAt ?? "nextgen")-\(actionId ?? phaseId ?? name ?? status ?? "receipt")"
    }

    public var displayName: String {
        name ?? actionId ?? phaseId ?? id
    }

    public var displayStatus: String {
        status ?? "recorded"
    }

    public var displayDetail: String {
        detail ?? output ?? createdAt ?? actionId ?? "Next-gen receipt"
    }



    public init(
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

    public init(from decoder: Decoder) throws {
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

public struct NextGenPhasesResponse: Decodable, Hashable {
    public var phases: [NextGenPhase]
    public var createdAt: String?

    public init(phases: [NextGenPhase], createdAt: String? = nil) {
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

    public init(from decoder: Decoder) throws {
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

public struct NextGenActionResponse: Decodable, Hashable {
    public var responseId: String?
    public var actionId: String?
    public var phaseId: String?
    public var name: String?
    public var status: String?
    public var dryRun: Bool?
    public var detail: String?
    public var output: String?
    public var receipt: NextGenReceipt?
    public var receipts: [NextGenReceipt]?
    public var summary: NextGenSummary?
    public var createdAt: String?

    public var displayReceipt: NextGenReceipt {
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

    public init(from decoder: Decoder) throws {
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
            if let value = decodeTolerantDisplayString(container, key) {
                return value
            }
        }
        return nil
    }

    static func decodeInt<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ keys: K...) throws -> Int? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key),
               let integer = Int(exactly: value.rounded(.towardZero)) {
                // 2026-09-07: Int(Double) traps on NaN/inf/out-of-range; keep the truncation, reject the rest.
                return integer
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
            return Int(exactly: doubleValue.rounded(.towardZero))
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

public enum NextGenJSONValue: Decodable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: NextGenJSONValue])
    case array([NextGenJSONValue])
    case null

    public init(from decoder: Decoder) throws {
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

    public var displayString: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            if let integer = Int(exactly: value) {
                return String(integer)
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

    public var intValue: Int? {
        switch self {
        case .number(let value):
            return Int(exactly: value.rounded(.towardZero))
        case .string(let value):
            return NextGenCoding.phaseNumber(from: value)
        case .bool(let value):
            return value ? 1 : 0
        default:
            return nil
        }
    }

    public var boolValue: Bool? {
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
