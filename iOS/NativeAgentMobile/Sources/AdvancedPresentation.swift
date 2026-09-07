import SwiftUI
import NativeAgentShared

enum RunsLogPresentation: Equatable {
    case content
    case empty
    case unavailable(String)

    static func state(runs: [RunRecord], error: String?) -> RunsLogPresentation {
        guard runs.isEmpty else { return .content }
        if let error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .unavailable(error)
        }
        return .empty
    }
}

enum RunKindPresentation {
    static func displayName(_ kind: String) -> String {
        RunKindVocabulary.displayName(kind, on: .iOS)
    }

    static func icon(_ kind: String) -> String {
        switch kind.lowercased() {
        case "codex": return "terminal"
        case "claude": return "sparkles"
        case "swarm": return "circle.hexagongrid.fill"
        case "mission": return "target"
        default: return "questionmark.circle"
        }
    }

    static func tint(_ kind: String) -> Color {
        switch kind.lowercased() {
        case "codex": return .teal
        case "claude": return NativeAgentPalette.agentAccent
        case "swarm": return .orange
        case "mission": return .blue
        default: return .secondary
        }
    }
}

struct RunDetailModelFact: Identifiable, Equatable {
    let label: String
    let value: String
    var id: String { label }
}

enum RunDetailPresentation {
    static func modelFacts(for run: RunRecord) -> [RunDetailModelFact] {
        func nonEmpty(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return value
        }

        var facts: [RunDetailModelFact] = []
        let model = nonEmpty(run.model)
        if let model { facts.append(.init(label: "Model", value: model)) }
        if let requested = nonEmpty(run.requestedModel), requested != model {
            facts.append(.init(label: "Requested (substituted)", value: requested))
        }
        if let effort = nonEmpty(run.reasoningEffort) {
            facts.append(.init(label: "Reasoning effort", value: effort.capitalized))
        }
        if let sandbox = nonEmpty(run.codexSandbox) {
            facts.append(.init(label: "Sandbox", value: sandbox))
        }
        if let fileAccess = nonEmpty(run.fileAccessMode) {
            facts.append(.init(label: "File access", value: fileAccess))
        }
        return facts
    }
}

enum RunDetailCopyPresentation {
    static func successMessage(for section: String) -> String {
        let label = section.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty
            ? "Copied run detail to clipboard."
            : "Copied \(label) to clipboard."
    }
}

enum RunDetailPromptPresentation {
    static let unavailableDescription = "The prompt was not captured for this run."

    /// Keep the captured prompt verbatim for copy fidelity, but do not render a
    /// prompt section (or a Copy action) for a blank payload.
    static func copyablePrompt(_ prompt: String?) -> String? {
        guard let prompt,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return prompt
    }
}

enum OrganismStatusPresentation {
    enum SnapshotState: Equatable {
        case available
        case disabled
        case unavailable(reason: String?)
        case invalidTimestamp(futureBy: TimeInterval)
        case stale(age: TimeInterval)
        case absent

        var displaysDetails: Bool {
            switch self {
            case .available, .stale: true
            case .disabled, .unavailable, .invalidTimestamp, .absent: false
            }
        }
    }

    struct DreamProposalSlice: Equatable {
        let visible: [OrganismLivingStandingViewProposalFile]
        let hiddenCount: Int
    }

    static func approvedBiasesText(_ value: Int?) -> String {
        value.map(String.init) ?? "Not reported"
    }

    static func canApprove(_ candidate: OrganismLivingReflexCandidateFile) -> Bool {
        candidate.trustClass == "lowRisk" && candidate.reviewRequired
    }

    static func isStale(generatedAt: Date, now: Date = Date(), maximumAge: TimeInterval = 300) -> Bool {
        now.timeIntervalSince(generatedAt) > maximumAge
    }

    static func snapshotState(
        for organism: OrganismLivingStatusFile?,
        now: Date = Date(),
        maximumAge: TimeInterval = 300,
        maximumFutureClockSkew: TimeInterval = 60
    ) -> SnapshotState {
        guard let organism else { return .absent }
        switch organism.availabilityState {
        case .unavailable:
            return .unavailable(reason: organism.unavailableReason)
        case .disabled:
            return .disabled
        case .live:
            let age = now.timeIntervalSince(organism.generatedAt)
            let allowedFutureSkew = max(0, maximumFutureClockSkew)
            if age < -allowedFutureSkew {
                return .invalidTimestamp(futureBy: -age)
            }
            return age > maximumAge ? .stale(age: age) : .available
        }
    }

    static func staleAgeText(_ age: TimeInterval) -> String {
        let seconds = max(0, Int(age.rounded(.down)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h"
    }

    struct ReflexCandidateSlice: Equatable {
        let visible: [OrganismLivingReflexCandidateFile]
        let hiddenCount: Int
    }

    static func reflexCandidateSlice(
        _ candidates: [OrganismLivingReflexCandidateFile],
        visibleLimit: Int = 6
    ) -> ReflexCandidateSlice {
        .init(visible: Array(candidates.prefix(visibleLimit)), hiddenCount: max(0, candidates.count - visibleLimit))
    }

    static func removingLocallyFinalizedCandidate(
        id: String,
        from candidates: [OrganismLivingReflexCandidateFile]
    ) -> [OrganismLivingReflexCandidateFile] {
        candidates.filter { $0.id != id }
    }

    static func dreamProposalSlice(
        _ proposals: [OrganismLivingStandingViewProposalFile],
        visibleLimit: Int = 4
    ) -> DreamProposalSlice {
        .init(visible: Array(proposals.prefix(visibleLimit)), hiddenCount: max(0, proposals.count - visibleLimit))
    }
}

enum MacHealthPresentation {
    enum Snapshot {
        case available(RuntimeHealth)
        case unavailable
    }

    static let unavailableTitle = "Mac health is unavailable"
    static let unavailableDetail = "Waiting for a health snapshot from the Mac."

    static func snapshot(for health: RuntimeHealth?) -> Snapshot {
        guard let health else { return .unavailable }
        return .available(health)
    }
}

/// One freshness contract for Mac-owned iCloud snapshots on the phone. Every
/// screen that reports a snapshot age must use this threshold rather than
/// deciding independently when a snapshot becomes stale.
enum MobileSnapshotFreshnessPresentation {
    static let staleAfter: TimeInterval = 30

    static func isStale(lastSyncedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastSyncedAt) > staleAfter
    }
}

enum StatusConnectionPresentation {
    enum SyncState: Equatable {
        case current(age: TimeInterval)
        case stale(age: TimeInterval, limit: TimeInterval)
        case neverSynced
        case clockMismatch(futureBy: TimeInterval)
    }

    static func syncState(
        lastSyncedAt: Date?,
        now: Date = Date(),
        staleAfter: TimeInterval = MobileSnapshotFreshnessPresentation.staleAfter,
        maximumFutureClockSkew: TimeInterval = 60
    ) -> SyncState {
        guard let lastSyncedAt else { return .neverSynced }

        let age = now.timeIntervalSince(lastSyncedAt)
        if age < -max(0, maximumFutureClockSkew) {
            return .clockMismatch(futureBy: -age)
        }
        let limit = max(0, staleAfter)
        return age > limit ? .stale(age: age, limit: limit) : .current(age: max(0, age))
    }

    static func ageText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h"
    }

    static func cardValue(for state: SyncState) -> String {
        switch state {
        case .current(let age): return "Fresh · \(ageText(age)) ago"
        case .stale(let age, _): return "STALE · \(ageText(age)) old"
        case .neverSynced: return "Never synced"
        case .clockMismatch: return "Clock mismatch"
        }
    }

    static func detail(for state: SyncState) -> String? {
        switch state {
        case .current:
            return nil
        case .stale(_, let limit):
            return "Expected a newer iCloud snapshot within \(ageText(limit))."
        case .neverSynced:
            return "No iCloud snapshot has reached this phone yet."
        case .clockMismatch(let futureBy):
            return "The Mac snapshot is \(ageText(futureBy)) ahead of this phone."
        }
    }

    static func needsAttention(_ state: SyncState) -> Bool {
        switch state {
        case .current: false
        case .stale, .neverSynced, .clockMismatch: true
        }
    }
}
