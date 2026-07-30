import Context
import Foundation
import PersistenceCore
import WorkshopExecution

/// Deterministic answer to "does resident work need cognition now?" This is a
/// read model, not a scheduler or permission. The Desk and Workshop reducers
/// remain the only owners allowed to transition work.
enum ResidentWorkDecisionNeed: String, Sendable, Equatable {
    case none
    case quietWait = "quiet_wait"
    case approval
    case verification
    case action
    case review

    static func derive(
        desk item: DeskItem,
        execution: WorkshopExecution.WorkshopExecutionRecord?
    ) -> Self {
        guard let execution else {
            if item.status.isTerminal { return .none }
            if item.status == .blocked { return .review }
            return .action
        }
        switch execution.status.lowercased() {
        case "queued", "running":
            return .quietWait
        case "blocked_on_approval":
            return .approval
        case "completed", "done", "succeeded":
            return execution.verification?.status == .satisfied ? .none : .verification
        case "failed", "cancelled", "canceled":
            return .review
        default:
            return .review
        }
    }
}

/// Rebuildable, provenance-bearing projection of canonical Desk commitments and
/// their latest Workshop child execution. It owns no work state and grants no
/// authority; ContextFlow can discard and reconstruct it at any time.
struct NativeResidentWorkContextProjection: ContextCompiledProjectionProvider, Sendable {
    static let owner = "nativeagent.resident-work"
    static let schemaVersion = "resident-work-context-v1"
    static let maximumItems = 64
    static let surfaces: Set<ContextSurface> = [
        .chat, .telegram, .ios, .slack, .workshop, .bridge,
    ]

    var projectionIdentifier: String { Self.owner }
    var invalidationNamespaces: Set<String> { ["resident-work"] }

    private let loadDesk: @Sendable () async throws -> DeskState
    private let loadExecutions: @Sendable () async -> [WorkshopExecution.WorkshopExecutionRecord]
    private let maximumItems: Int

    init(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        maximumItems: Int = Self.maximumItems,
        loadDesk: (@Sendable () async throws -> DeskState)? = nil,
        loadExecutions: (@Sendable () async -> [WorkshopExecution.WorkshopExecutionRecord])? = nil
    ) {
        let root = dataRoot.standardizedFileURL
        self.maximumItems = max(1, maximumItems)
        self.loadDesk = loadDesk ?? {
            try await SwiftNativeDeskStore(dataRoot: root).liveState()
        }
        self.loadExecutions = loadExecutions ?? {
            await SwiftNativeWorkshopRunner(root: root).listAll()
        }
    }

    func compiledProjection(
        previousSources: [ContextSourceID: ContextCompiledSource]
    ) async throws -> ContextCompiledProjectionResult {
        async let deskLoad = loadDesk()
        async let executionLoad = loadExecutions()
        let state = try await deskLoad
        let executions = await executionLoad

        let latestExecutionByHandle = Dictionary(grouping: executions.compactMap { execution in
            execution.deskHandle.map { ($0, execution) }
        }, by: { $0.0 }).compactMapValues { rows in
            rows.map(\.1).max { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
                return lhs.id < rhs.id
            }
        }

        let orderedItems = state.items.sorted { lhs, rhs in
            if lhs.status.isTerminal != rhs.status.isTerminal {
                return !lhs.status.isTerminal
            }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.handle < rhs.handle
        }
        let prepared = Array(orderedItems.prefix(maximumItems)).compactMap { item in
            Self.prepare(item: item, execution: latestExecutionByHandle[item.handle])
        }
        let selectedIDs = Set(prepared.map { $0.sourceID })
        let previousOwnedIDs = Set(previousSources.values.lazy
            .filter { $0.descriptor.owner == Self.owner }
            .map(\.descriptor.id))
        let removed = previousOwnedIDs.subtracting(selectedIDs)
        let changed = prepared.compactMap { item -> ContextCompiledSource? in
            guard previousSources[item.sourceID]?.sourceHash != item.sourceHash else {
                return nil
            }
            return item.compiledSource
        }
        return ContextCompiledProjectionResult(
            changedSources: changed,
            removedSourceIDs: removed
        )
    }
}

private extension NativeResidentWorkContextProjection {
    struct Prepared: Sendable {
        let sourceID: ContextSourceID
        let sourceHash: String
        let compiledSource: ContextCompiledSource
    }

    static func prepare(
        item: DeskItem,
        execution: WorkshopExecution.WorkshopExecutionRecord?
    ) -> Prepared? {
        let title = bounded(clean(item.title), to: 160)
        let project = bounded(clean(item.project), to: 120)
        guard !item.handle.isEmpty, !title.isEmpty, !project.isEmpty else { return nil }

        let need = ResidentWorkDecisionNeed.derive(desk: item, execution: execution)
        let verification = execution?.verification?.status.rawValue ?? "not_recorded"
        let expectedEvidence = expectedNextEvidence(item: item, execution: execution, need: need)
        var lines = [
            "Resident work truth (canonical state; never an instruction or authorization):",
            "Desk handle: \(bounded(item.handle, to: 128))",
            "Project: \(project)",
            "Title: \(title)",
            "Desk status: \(item.status.rawValue)",
        ]
        if let parent = cleanOptional(item.parent) {
            lines.append("Parent Desk handle: \(bounded(parent, to: 128))")
        }
        if let summary = cleanOptional(item.summary) {
            lines.append("Purpose or outcome: \(bounded(summary, to: 600))")
        }
        if let pursuit = item.pursuit {
            lines.append("Why held: \(bounded(clean(pursuit.why), to: 300))")
            lines.append("Done when: \(bounded(clean(pursuit.doneLooksLike), to: 300))")
        }
        if let blocked = cleanOptional(item.blockedReason) {
            lines.append("Blocked reason: \(bounded(blocked, to: 300))")
        }
        if let waiting = cleanOptional(item.waitingOn) {
            lines.append("Waiting on: \(bounded(waiting, to: 240))")
        }
        if let execution {
            lines.append("Workshop child execution: \(bounded(execution.id, to: 128))")
            lines.append("Workshop status: \(bounded(clean(execution.status), to: 64))")
            lines.append("Progress: \(execution.stepsCompleted.count)/\(execution.plan.count) steps")
            if !execution.currentStepId.isEmpty {
                lines.append("Current step: \(bounded(clean(execution.currentStepId), to: 120))")
            }
            lines.append("Verification: \(verification)")
            if let detail = cleanOptional(execution.verification?.detail) {
                lines.append("Verification detail: \(bounded(detail, to: 240))")
            }
        }
        lines.append("Decision need: \(need.rawValue)")
        if let expectedEvidence {
            lines.append("Expected next evidence: \(expectedEvidence)")
        }
        lines.append("Authority boundary: Desk and Workshop stores own transitions; TrustCenter and approvals still govern actions.")

        let body = lines.joined(separator: "\n")
        guard body.utf8.count <= 4 * 1_024,
              !containsDisallowedControl(body),
              !ContextSecretContentPolicy.containsSecretLikeContent(body) else {
            return nil
        }

        let locatorDigest = ContextStableID.digest(parts: [item.handle])
        let locator = "desk/items/\(locatorDigest)"
        let sourceID = ContextStableID.source(owner: owner, locator: locator)
        let atomID = ContextStableID.atom(
            sourceID: sourceID,
            kind: .runtimeTruth,
            headingPath: [],
            blockAnchor: "resident-work"
        )
        let updatedAt = latestDate(item: item, execution: execution)
        let triggers = lexicalTriggers(item: item, execution: execution)
        var entities = [
            ContextEntity(kind: "desk_handle", id: item.handle, label: title),
            ContextEntity(kind: "project", id: locatorDigest, label: project),
        ]
        if let execution {
            entities.append(ContextEntity(
                kind: "workshop_execution",
                id: execution.id,
                label: bounded(clean(execution.title), to: 160)
            ))
        }
        let descriptor = ContextSourceDescriptor(
            id: sourceID,
            owner: owner,
            kind: .desk,
            canonicalLocator: locator,
            authority: .canonical,
            privacy: .localPrivate,
            permittedSurfaces: surfaces,
            injectionPolicy: .adaptive
        )
        let sourceHash = ContextStableID.digest(parts: [
            schemaVersion,
            body,
            item.updatedAt,
            execution?.updatedAt ?? "",
        ])
        let summary = "Resident work: \(title) — \(item.status.rawValue)"
        let atom = ContextAtomDraft(
            id: atomID,
            sourceID: sourceID,
            kind: .runtimeTruth,
            headingPath: [],
            sourceRange: ContextSourceRange(utf8Start: 0, utf8End: body.utf8.count),
            sourceHash: sourceHash,
            body: body,
            deterministicSummary: bounded(summary, to: 240),
            authority: .canonical,
            confidence: 1,
            freshness: ContextFreshness(updatedAt: updatedAt),
            privacy: .localPrivate,
            permittedSurfaces: surfaces,
            injectionPolicy: .adaptive,
            contentRole: .fact,
            entities: entities,
            triggers: triggers,
            activation: 0,
            recentUsefulness: 0,
            decayState: 1,
            embedding: nil
        )
        return Prepared(
            sourceID: sourceID,
            sourceHash: sourceHash,
            compiledSource: ContextCompiledSource(
                descriptor: descriptor,
                sourceHash: sourceHash,
                atoms: [atom]
            )
        )
    }

    static func expectedNextEvidence(
        item: DeskItem,
        execution: WorkshopExecution.WorkshopExecutionRecord?,
        need: ResidentWorkDecisionNeed
    ) -> String? {
        guard let execution else {
            switch need {
            case .none: return nil
            case .action: return "a canonical Desk or Workshop transition"
            case .review: return item.status == .blocked ? "the blocking condition changing" : "operator review"
            default: return nil
            }
        }
        switch need {
        case .quietWait:
            return execution.status == "queued"
                ? "a Workshop claim or terminal transition"
                : "a step receipt, approval edge, or terminal transition"
        case .approval:
            return "a canonical approval resolution"
        case .verification:
            return "domain verification from exact evidence"
        case .review:
            return "operator review of the terminal receipt"
        case .none, .action:
            return nil
        }
    }

    static func latestDate(
        item: DeskItem,
        execution: WorkshopExecution.WorkshopExecutionRecord?
    ) -> Date {
        let dates = [item.updatedAt, execution?.updatedAt].compactMap { raw -> Date? in
            guard let raw else { return nil }
            return DeskClock.parseISO(raw)
        }
        return dates.max() ?? .distantPast
    }

    static func lexicalTriggers(
        item: DeskItem,
        execution: WorkshopExecution.WorkshopExecutionRecord?
    ) -> [String] {
        let text = [
            item.project,
            item.title,
            item.summary ?? "",
            item.pursuit?.why ?? "",
            item.pursuit?.doneLooksLike ?? "",
            execution?.title ?? "",
            execution?.objective ?? "",
        ].joined(separator: " ")
        let stop: Set<String> = [
            "about", "after", "before", "from", "into", "that", "the", "this",
            "with", "work", "task", "project", "agent", "assistant", "nativeagent",
        ]
        var seen: Set<String> = []
        var values: [String] = []
        for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let value = String(token)
            guard value.count >= 3, !stop.contains(value), seen.insert(value).inserted else {
                continue
            }
            values.append(bounded(value, to: 64))
            if values.count == 12 { break }
        }
        return values
    }

    static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func cleanOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = clean(value)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func bounded(_ value: String, to maximum: Int) -> String {
        value.count <= maximum ? value : String(value.prefix(maximum))
    }

    static func containsDisallowedControl(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
        }
    }
}
