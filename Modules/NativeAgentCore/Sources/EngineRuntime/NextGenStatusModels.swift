import Foundation
import PersistenceCore

public struct NextGenSummary: Sendable, Hashable {
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
    public var actions: [NextGenAction]?
    public var latestReceipts: [NextGenReceipt]?
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
}

public struct NextGenPhaseRange: Sendable, Hashable {
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
}

public struct NextGenPhase: Identifiable, Sendable, Decodable, Hashable {
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

public struct NextGenAction: Identifiable, Sendable, Decodable, Hashable {
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
        let value = try single.decode(JSONValue.self)
        if case .string(let value) = value {
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
        if case .int(let value) = value {
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

public struct NextGenReceipt: Identifiable, Sendable, Decodable, Hashable {
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
        if case .array = try JSONValue(from: decoder) {
            self.phases = try [NextGenPhase](from: decoder)
            self.createdAt = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let phases: [NextGenPhase] = try NextGenCoding.decodeArray(container, .phases, .items, .records) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected a next-gen phase feed."))
        }
        self.phases = phases
        createdAt = try NextGenCoding.decodeString(container, .createdAt, .created_at)
    }
}

private enum NextGenCoding {
    static func decodeString<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ keys: K...) throws -> String? {
        for key in keys {
            if let value = try container.decodeIfPresent(JSONValue.self, forKey: key) {
                return value.nextGenDisplayString
            }
        }
        return nil
    }

    static func decodeInt<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ keys: K...) throws -> Int? {
        for key in keys {
            guard let value = try container.decodeIfPresent(JSONValue.self, forKey: key) else { continue }
            let integer: Int?
            switch value {
            case .int(let value): integer = Int(exactly: value)
            case .double(let value): integer = Int(exactly: value.rounded(.towardZero))
            case .string(let value): integer = phaseNumber(from: value)
            case .bool(let value): integer = value ? 1 : 0
            default: integer = nil
            }
            guard let integer else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Expected a phase number.")
            }
            return integer
        }
        return nil
    }

    static func decodeBool<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ keys: K...) throws -> Bool? {
        for key in keys {
            guard let value = try container.decodeIfPresent(JSONValue.self, forKey: key) else { continue }
            let boolean: Bool?
            switch value {
            case .bool(let value): boolean = value
            case .int(let value): boolean = value != 0
            case .double(let value): boolean = value != 0
            case .string(let value): boolean = bool(from: value)
            default: boolean = nil
            }
            guard let boolean else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Expected a boolean.")
            }
            return boolean
        }
        return nil
    }

    static func decodeArray<T: Decodable, K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ keys: K...) throws -> [T]? {
        for key in keys {
            guard let value = try container.decodeIfPresent(JSONValue.self, forKey: key) else { continue }
            if case .array = value {
                return try container.decode([T].self, forKey: key)
            }
            return [try container.decode(T.self, forKey: key)]
        }
        return nil
    }

    static func decodeObject<T: Decodable, K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ keys: K...) throws -> T? {
        for key in keys {
            guard let value = try container.decodeIfPresent(JSONValue.self, forKey: key) else { continue }
            if case .array = value {
                return try container.decode([T].self, forKey: key).first
            }
            return try container.decode(T.self, forKey: key)
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
