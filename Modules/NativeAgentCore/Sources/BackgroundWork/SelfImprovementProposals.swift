import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ApprovalInbox
import MemoryV2
import DreamREMCycle
import AgentWorkspace
import Desk
import ToolRegistry
import BackgroundLoops
import ProviderRouting
// Blueprint: | `SelfImprovementProposals.swift` | Maintenance weekly-loop factory and existing staging closures; runtime approval cards bind exact reviewed code and finding identity; code findings enter the builder queue; standing lessons use REM; `SelfImprovementProposal` owns stable finding identity |

extension MaintenanceBackgroundWork {
    /// Weekly analysis stages runtime findings for approval under the unattended-work gate.
    public func selfImprovementSwitchOn() -> Bool {
        // Enabled by default; the Self-Improvement and setup switches write this key.
        UserDefaults.standard.object(forKey: "selfImprovementEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "selfImprovementEnabled")
    }

    public func makeWeeklySelfImprovementLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        llm: any LLMClient,
        workshopOutcomes: @escaping @Sendable () async throws -> String
    ) -> WeeklySelfImprovementLoop {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        return WeeklySelfImprovementLoop(
            llm: llm,
            dataRoot: dataRoot,
            isEnabled: {
                guard selfImprovementSwitchOn() else { return false }
                // The shared unattended-work gate owns authority while nobody is looking.
                return await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: dataRoot)
            },
            stageProposal: { proposal in
                var apply: [String: JSONValue] = ["op": .string(proposal.applyOp ?? ""),
                                                  "target": .string(proposal.applyTarget ?? "")]
                var preview: String = {
                    switch (proposal.applyOp, proposal.applyTarget) {
                    case ("disable_skill"?, let target?): return "Turn off the \(target) skill. "
                    case ("enable_skill"?, let target?): return "Turn on the \(target) skill. "
                    case (let op?, _) where !op.isEmpty:
                        return "Approving runs: " + op.replacingOccurrences(of: "_", with: " ") + ". "
                    default: return ""
                    }
                }() + String(proposal.proposedChange.prefix(180))
                if proposal.applyOp == "enable_skill" {
                    let target = proposal.applyTarget ?? ""
                    let tools = try await SwiftNativeToolRegistry(root: dataRoot).listTools()
                    guard let tool = tools.first(where: { $0.id.caseInsensitiveCompare(target) == .orderedSame })
                        ?? tools.first(where: { $0.name.caseInsensitiveCompare(target) == .orderedSame }) else {
                        throw ToolRegistryError.invalidRequest("Cannot stage approval: \(target) is unavailable.")
                    }
                    apply["target"] = .string(tool.id)
                    if let digest = tool.reviewedKeepDigest, let review = tool.keepReview {
                        // Approval binds the code shown on this card, never a later reread.
                        apply["reviewedDigest"] = .string(digest)
                        preview += "\n\nApprove keeps only this exact version; a changed version is refused.\n"
                            + (try JSONValue.object(review).serialize(pretty: true))
                    } else {
                        guard (tool.candidateDigest ?? tool.codeFingerprint) == nil,
                              tool.activePath.map({ URL(fileURLWithPath: $0).pathExtension == "md" }) == true else {
                            throw ToolRegistryError.invalidRequest("Cannot stage approval without \(target)'s exact code and digest.")
                        }
                        apply["reviewedDigest"] = .null
                        preview += "\nMarkdown guidance only; this approval cannot enable executable code."
                    }
                }
                // Only a pending card for this finding and exact enable version suppresses a duplicate.
                let findingId = proposal.findingId
                if let existing = try? await inbox.list(
                    filter: ApprovalFilter(status: "pending", action: "self_improvement.apply")
                ), let card = existing.first(where: { record in
                    guard case .object(let payload) = record.payload,
                          case .string(let staged)? = payload["findingId"] else { return false }
                    guard staged == findingId else { return false }
                    if proposal.applyOp == "enable_skill" {
                        guard case .object(let saved)? = payload["apply"] else { return false }
                        return saved["target"] == apply["target"] && saved["reviewedDigest"] == apply["reviewedDigest"]
                    }
                    return true
                }) {
                    return card.id
                }
                let body: JSONValue = .object([
                    "title": .string(proposal.title),
                    "action": .string("self_improvement.apply"),
                    "payload": .object([
                        "kind": .string("self_improvement"),
                        "findingId": .string(findingId),
                        "evidence": .string(proposal.evidence),
                        "proposedChange": .string(proposal.proposedChange),
                        "apply": .object(apply),
                    ]),
                    // Describe what one tap does; a skill op names its skill.
                    "payloadPreview": .string(preview),
                ])
                do {
                    return try await inbox.create(body).id
                } catch {
                    // Propagate staging failures so the pass fails and releases its weekly reservation.
                    FileHandle.standardError.write(Data(
                        "WeeklySelfImprovement: stage failed for \(proposal.title): \(error)\n".utf8))
                    throw error
                }
            },
            // A code finding needs a code change: the harness queue holds it
            // for the builder, once per finding, with this pass's digest.
            fileCodeFinding: { proposal in
                let digest = dataRoot.appendingPathComponent("self_improvement/digests/\(NativeTimestampFormat.calendarDay(Date())).md")
                try await HarnessQueue.file(HarnessFinding(
                    key: proposal.findingId, title: proposal.title,
                    summary: proposal.proposedChange + "\nEvidence: " + proposal.evidence,
                    owner: .builder,
                    refs: [DeskRef(kind: .file(path: digest.path, line: nil, label: "weekly digest"))],
                    source: .sweep
                ), dataRoot: dataRoot)
            },
            workshopOutcomes: workshopOutcomes,
            // The sweep learns from itself: this week's misses by lesson against
            // last week's, and what became of the previous pass's cards.
            learning: { previousCards in
                var sections: [String] = []
                let weeks = [MemoryRecoveryReadout.isoWeek(), MemoryRecoveryReadout.isoWeek(ago: 1)]
                do {
                    let lessons = try await MemoryRecoveryReadout.misses(dataRoot: dataRoot, weeks: weeks)
                    sections.append("## Misses by lesson (corrections this week, last week in brackets)\n" + (lessons.isEmpty ? "(none)"
                        : lessons.map { "- \($0.lesson): \($0.count(week: weeks[0])) (\($0.count(week: weeks[1])))" }.joined(separator: "\n")))
                } catch { sections.append("## Misses by lesson\n(unreadable: \(error))") }
                if let previousCards {
                    sections.append(await Self.passOutcomes(cards: previousCards, inbox: inbox, dataRoot: dataRoot))
                }
                var standing: [String: String] = [:]
                do { standing = try await Self.standingLessons(dataRoot: dataRoot) } catch {
                    FileHandle.standardError.write(Data("WeeklySelfImprovement: standing lessons unreadable: \(error)\n".utf8))
                }
                return SelfImprovementLearning(signals: sections.joined(separator: "\n\n"), standing: standing)
            },
            // REM stages standing lessons by memory and wording; tombstones
            // keep denied or retired lines gone across memories.
            stageStandingLessons: { lines in
                let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
                let tombstones = REMTombstoneStore(dataRoot: dataRoot)
                var proposals: [REMProposalRow] = []
                for (id, line) in lines.sorted(by: { $0.key < $1.key }) {
                    guard let memory = try await storage.memory(id: id) else { continue }
                    // One card per wording of the correction: an edited one
                    // (its card goes stale) can be offered again.
                    let proposal = REMProposalRow(
                        id: "standing-\(id)-\(MemoryStorage.contentHash(memory.content).prefix(12))",
                        targetDoc: "GROWTH.md", proposalText: line, evidenceDates: [],
                        confidence: 1, createdAt: ISO8601DateFormatter().string(from: Date()),
                        supportingPassages: [REMSupportingPassage(dreamDate: "", quote: memory.content, sourceRefs: ["memory:" + id])],
                        support: .standing)
                    proposals.append(proposal)
                }
                proposals = try await tombstones.filterTombstoned(proposals)
                try await REMProposalStore(dataRoot: dataRoot).appendPending(proposals)
                await DreamBackgroundWork.stagePendingREMProposalsAtLaunch(dataRoot: dataRoot, notifications: port)
                return proposals.map(\.id)
            }
        )
    }
}

/// One improvement the weekly analyzer found. `runtime` proposals carry a
/// safe, reversible `applyOp` and are staged for one-tap approval (approval
/// runs the op); `code` proposals are report-only.
public struct SelfImprovementProposal: Sendable {
    public enum Kind: Sendable { case runtime, code }
    public let kind: Kind
    public let title: String
    public let evidence: String
    public let proposedChange: String
    /// The applied-on-approval op. ONE of `WeeklySelfImprovementLoop.applyOps`.
    /// Non-nil for every staged runtime proposal (guaranteed by parseResult),
    /// nil for code/report findings.
    public let applyOp: String?
    public let applyTarget: String?

    public init(
        kind: Kind, title: String, evidence: String, proposedChange: String,
        applyOp: String? = nil, applyTarget: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.evidence = evidence
        self.proposedChange = proposedChange
        self.applyOp = applyOp
        self.applyTarget = applyTarget
    }

    /// Stable, date-independent finding identity prevents duplicate pending approval cards.
    public var findingId: String {
        let material = [
            kind == .runtime ? "runtime" : "code",
            Self.withoutTimestamps(title),
            Self.withoutTimestamps(proposedChange),
            applyOp ?? "", applyTarget ?? "",
        ].joined(separator: "\u{1D}")
        return "swi-" + Self.digestHex(material).prefix(24)
    }

    /// Collapse dates and optional times before hashing so a later week's restatement keeps its identity.
    static func withoutTimestamps(_ value: String) -> String {
        guard let regex = timestampRegex else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return regex.stringByReplacingMatches(
            in: value, options: [], range: range, withTemplate: "<date>")
    }

    private static let timestampRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\d{4}-\\d{2}-\\d{2}(?:[T ]\\d{2}:\\d{2}(?::\\d{2})?(?:\\.\\d+)?(?:Z|[+-]\\d{2}:?\\d{2})?)?"
    )

    private static func digestHex(_ value: String) -> String {
        // FNV-1a 64 over two salts supplies a stable finding digest.
        let low = fnv1a64(value, seed: 0xcbf2_9ce4_8422_2325)
        let high = fnv1a64(value, seed: 0x9e37_79b9_7f4a_7c15)
        return String(format: "%016lx%016lx", low, high)
    }
}
