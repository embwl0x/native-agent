import Foundation
import CognitiveSubstrate
import Cognition
import ApprovalInbox
import NativeAgentShared
import PersistenceCore
import DeviceSync
import DreamREMCycle

public enum CognitionProposalsFeed: Sendable {
    public struct Pending: Sendable, Equatable {
        public init(standingViews: [CognitiveStandingView] = [], schemaProposals: [CognitiveSchemaProposal] = []) {
            self.standingViews = standingViews
            self.schemaProposals = schemaProposals
        }
        public var standingViews: [CognitiveStandingView] = []
        public var schemaProposals: [CognitiveSchemaProposal] = []
        public var count: Int { standingViews.count + schemaProposals.count }
    }

    public enum Read: Sendable, Equatable {
        case available(Pending)
        case unavailable(String)

        public var pending: Pending {
            guard case .available(let pending) = self else { return Pending() }
            return pending
        }
    }

}

public struct LivingStatusSnapshot: Sendable, Equatable {
    public var enabled: Bool
    public var posture: String
    public var postureStatus: String
    public var bodyState: String
    public var behaviorLine: String
    public var homeLine: String
    public var whyLine: String
    public var carryLine: String
    public var innerLine: String
    public var deskSummary: String
    public var approvalsSummary: String
    public var lastDreamSummary: String
    public var needsText: String
    public var showsOrganismDetails: Bool

    public var visibleText: [String] {
        [
            posture,
            bodyState,
            behaviorLine,
            homeLine,
            whyLine,
            carryLine,
            innerLine,
            deskSummary,
            approvalsSummary,
            lastDreamSummary,
            needsText,
        ]
    }

    public static func make(
        organism: OrganismSnapshot,
        activeDeskCount: Int,
        blockedDeskCount: Int,
        ownerWaiting: Int,
        pendingApprovals: Int,
        latestDream: DreamEntry?,
        agentDisplayName: String = "NativeAgent"
    ) -> LivingStatusSnapshot {
        let needsUser = ownerWaiting > 0
        let needsAttention = !needsUser && (
            blockedDeskCount > 0 || LivingAttentionPolicy.organismNeedsAttention(organism)
        )
        let posture = Self.posture(for: organism)
        let behaviorLine = Self.behaviorLine(for: organism)
        return LivingStatusSnapshot(
            enabled: organism.enabled,
            posture: posture,
            postureStatus: (needsUser || needsAttention) ? "warn" : (organism.enabled ? "ok" : "disabled"),
            bodyState: Self.bodyState(for: organism),
            behaviorLine: behaviorLine,
            homeLine: Self.homeLine(
                posture: posture,
                needsUser: needsUser,
                organism: organism,
                agentDisplayName: agentDisplayName
            ),
            whyLine: Self.whyLine(
                for: organism,
                pendingApprovals: pendingApprovals,
                ownerWaiting: ownerWaiting,
                blockedDeskCount: blockedDeskCount,
                agentDisplayName: agentDisplayName
            ),
            carryLine: Self.carryLine(for: organism),
            innerLine: Self.innerLine(from: organism.projectedBodyLine, enabled: organism.enabled),
            deskSummary: Self.deskSummary(active: activeDeskCount, blocked: blockedDeskCount),
            approvalsSummary: pendingApprovals > 0
                ? "\(pendingApprovals) approval\(pendingApprovals == 1 ? "" : "s") pending" : "no approvals pending",
            lastDreamSummary: latestDream.map { "last dream \($0.date)" } ?? "no dream entry yet",
            needsText: needsUser ? "needs you" : (needsAttention ? "no action needed" : "needs nothing"),
            showsOrganismDetails: organism.enabled
        )
    }

    private static func posture(for organism: OrganismSnapshot) -> String {
        guard organism.enabled else { return "Quiet" }
        let body = organism.bodySchema
        let chemical = organism.chemicalState
        if !body.providersHealthy || !body.toolHandsAvailable || chemical.vigilance > 0.35 { return "Careful" }
        if chemical.urgency > 0.35 { return "Urgent" }
        if chemical.fatigue > 0.35 || body.resourcePressure != .nominal { return "Tired" }
        if chemical.warmth > 0.35 || chemical.tenderness > 0.30 { return "Warm" }
        if chemical.curiosity > 0.35 || chemical.novelty > 0.35 { return "Curious" }
        if chemical.coherence > 0.56 && chemical.confidence > 0.55 { return "Integrated" }
        return "Steady"
    }

    private static func bodyState(for organism: OrganismSnapshot) -> String {
        guard organism.enabled else { return "body kernel off" }
        let body = organism.bodySchema
        if !body.macAwake { return "resting" }
        if !body.providersHealthy || !body.toolHandsAvailable { return "provider/tool brittle" }
        if !body.iPhoneReachable || !body.notificationPathHealthy { return "phone path stale" }
        if !body.memoryHealthy { return "memory brittle" }
        if !body.dreamHealthy { return "dreams need attention" }
        if !body.approvalChannelsOpen { return "approval path closed" }
        if body.resourcePressure != .nominal { return "resource tight" }
        return "body steady"
    }

    private static func behaviorLine(for organism: OrganismSnapshot) -> String {
        guard organism.enabled else { return "behavior posture off" }
        guard let posture = OrganismBehaviorPosture.from(snapshot: organism) else {
            return "behavior posture quiet"
        }
        return sanitized("claims \(posture.claimDiscipline.rawValue), tools \(posture.toolStrategy.rawValue), loops \(posture.loopBudget.rawValue)")
    }

    private static func homeLine(
        posture: String,
        needsUser: Bool,
        organism: OrganismSnapshot,
        agentDisplayName: String
    ) -> String {
        guard organism.enabled else { return "\(agentDisplayName) is quiet until organism mode is enabled." }
        let ask = needsUser ? "needs you" : "does not need you"
        return sanitized("\(agentDisplayName) is \(posture.lowercased()) and \(ask).")
    }

    private static func whyLine(
        for organism: OrganismSnapshot,
        pendingApprovals: Int,
        ownerWaiting: Int,
        blockedDeskCount: Int,
        agentDisplayName: String
    ) -> String {
        if pendingApprovals > 0 { return "Waiting on approval before irreversible movement." }
        if ownerWaiting > 0 { return "The Desk's Needs you holds \(ownerWaiting) thing\(ownerWaiting == 1 ? "" : "s") for your decision." }
        guard organism.enabled else { return "No body line appears while the organism kernel is off." }
        let body = organism.bodySchema
        if !body.providersHealthy || !body.toolHandsAvailable { return "Provider or tool path is brittle, so completion claims tighten." }
        if !body.notificationPathHealthy || !body.iPhoneReachable { return "Phone path is stale, so delivery needs receipts." }
        if body.resourcePressure != .nominal { return "Resource pressure is shaping loop budget." }
        if !body.memoryHealthy || !body.dreamHealthy || !body.approvalChannelsOpen {
            return "A local body path needs \(agentDisplayName)'s attention, but no user action is requested."
        }
        if blockedDeskCount > 0 { return "Desk has blocked work, but it is not waiting on your decision." }
        if organism.projectedBodyLine == nil { return "No Body line appears because the body state is steady enough to stay quiet." }
        return "Body line is active because the current state is shaping the turn."
    }

    private static func carryLine(for organism: OrganismSnapshot) -> String {
        guard organism.enabled else { return "carrying no organism state" }
        let proposals = organism.dreamRepairSummary.proposedStandingViews
        return sanitized("carrying \(organism.signalCount) signals, \(organism.fieldSummary.nodeCount) field nodes, \(proposals) dream proposals")
    }

    private static func deskSummary(active: Int, blocked: Int) -> String {
        let activeText = "\(max(0, active)) desk item\(active == 1 ? "" : "s")"
        guard blocked > 0 else { return activeText }
        return "\(activeText), \(blocked) blocked"
    }

    private static func innerLine(from projectedBodyLine: String?, enabled: Bool) -> String {
        guard enabled else { return "quiet until organism mode is enabled" }
        let raw = projectedBodyLine?
            .replacingOccurrences(of: "- Body:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let line = raw.isEmpty ? "steady enough to stay out of the way" : raw
        return sanitized(line)
    }

    private static func sanitized(_ value: String) -> String {
        let oneLine = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = oneLine.lowercased()
        let home = NSHomeDirectory().lowercased()
        let blockedFragments = [
            ["api", "key"].joined(separator: "_"),
            ["api", "key"].joined(),
            "authorization:",
            ["bear", "er "].joined(),
            ["token", "="].joined(),
            ["to", "ken:"].joined(),
            "secret",
            ["sk", ""].joined(separator: "-"),
            ["xox", "b-"].joined(),
            ["xa", "pp", "-"].joined(),
        ]
        if (!home.isEmpty && lower.contains(home)) || blockedFragments.contains(where: lower.contains) {
            return "private body cue hidden"
        }
        guard oneLine.count > 160 else { return oneLine }
        return String(oneLine.prefix(157)) + "..."
    }
    public init(
        enabled: Bool,
        posture: String,
        postureStatus: String,
        bodyState: String,
        behaviorLine: String,
        homeLine: String,
        whyLine: String,
        carryLine: String,
        innerLine: String,
        deskSummary: String,
        approvalsSummary: String,
        lastDreamSummary: String,
        needsText: String,
        showsOrganismDetails: Bool
    ) {
        self.enabled = enabled
        self.posture = posture
        self.postureStatus = postureStatus
        self.bodyState = bodyState
        self.behaviorLine = behaviorLine
        self.homeLine = homeLine
        self.whyLine = whyLine
        self.carryLine = carryLine
        self.innerLine = innerLine
        self.deskSummary = deskSummary
        self.approvalsSummary = approvalsSummary
        self.lastDreamSummary = lastDreamSummary
        self.needsText = needsText
        self.showsOrganismDetails = showsOrganismDetails
    }

}
