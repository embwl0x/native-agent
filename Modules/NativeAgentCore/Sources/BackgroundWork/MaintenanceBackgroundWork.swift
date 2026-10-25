import Foundation
import NativeAgentCore
import BackgroundLoops
import ChatSessionWork
import Context
import DoctorChecks
import PersistenceCore
import TurnTrace
import ApprovalInbox
import NotificationInbox
import MemoryV2
import DreamREMCycle
import AgentWorkspace
import Desk
import AttentionRouting
import Privacy
import ProviderRouting
import Experiences
import ToolRegistry
import Cognition
// Blueprint: | `MaintenanceBackgroundWork.swift` | `MaintenanceBackgroundWork` struct; Doctor and loop failures owe repair through DoctorStatusProjection; Doctor ask grouping and storage card narration live in Resources/abilities/maintenance-assistance.js; native ask eligibility, disk accounting, unavailable plan reads, saved executable cleanup scope, cleanup receipts and acknowledgment by finding identity stay here; no JS under the publication lock; Resources/abilities/backup-cadence.js selects off-disk freshness and identity-change timing, with native volume/metadata observations, root protection and backup execution; canceled deadline reads return without a backup outcome, canceled ticks skip; actual cadence failures name the part, cause and repair/restore lever in offdisk_backup's failed scheduler receipts and Doctor/maintenance health, never a not-due skip or substitute cadence; unavailable observations never become empty inputs; the weekly Workshop digest is supplied by EngineLaunch through the ordinary maintenance part door, with unavailable evidence failing the pass; weekly signals use chat, live error feeds and Doctor health, without the retired Python sink or skill registry; self-improvement captures the checked part row's full review and digest in enable cards, deduplicated by finding and exact version; retention, backup work and manual weekly-run token lifecycle; DoctorFacade owns observed digest reads |

// MARK: - Maintenance Loops

public struct MaintenanceBackgroundWork: Sendable {
    private let port: any MaintenanceBackgroundWorkPort

    public init(port: any MaintenanceBackgroundWorkPort) { self.port = port }

    // Maintenance factories remain independently testable; the app-owned
    // production manifest decides which ones have real ingress and consumers.
    /// `freshMeasurement` rebuilds the two memoizing behavioural checks so this
    /// runner MEASURES. A caller that runs because something just became true
    /// (the first real turn landing) must pass `true`, or it republishes the
    /// launch measurement under a new timestamp — Astra audit 2026-09-11
    /// finding 6. The periodic sweep leaves it `false` and keeps the memo.
    public func makeAutoDoctorLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval? = nil,
        freshMeasurement: Bool = false
    ) -> some LoopRunner {
        let config = port.autoDoctorConfig(dataRoot: dataRoot)
        let configuredInterval = config.intervalSeconds
            .map(TimeInterval.init)
            .flatMap { $0.isFinite && $0 >= 3600 ? $0 : nil }
        let interval = intervalSeconds ?? configuredInterval ?? (7 * 24 * 60 * 60)
        let checks = makeDoctorChecks(root: dataRoot, freshMeasurement: freshMeasurement)
        return ConfiguredDoctorAutoRunLoop(
            enabled: config.enabled ?? true,
            doctor: DoctorAutoRunLoop(
                interval: interval,
                runChecks: { try await port.runAutoDoctor(checks: checks, dataRoot: dataRoot) },
                storage: { dataRoot.appendingPathComponent("doctor", isDirectory: true) }
            )
        )
    }

    /// What Doctor could not repair itself — sign-ins and permissions — goes
    /// to User as ONE inbox card listing every step. The card updates in place,
    /// keeps his read/dismiss status while the list is unchanged, and is
    /// archived and marked cleared once nothing is left to ask.
    public func fileDoctorAsk(dataRoot: URL, rows: [CheckResult]) async -> Bool {
        let cardID = "doctor-ask"
        let inbox = LiveNotificationInbox.live(dataRoot: dataRoot)
        let asks: [JSONValue] = rows.filter(DoctorSafeRepairPolicy.isUserAsk).compactMap { row in
            row.human_action.map { .object(["title": .string(row.title), "action": .string($0)]) }
        }
        do {
            guard !asks.isEmpty else {
                // Cleared whatever User did with the card (read, archived or
                // dismissed), so a recurrence surfaces fresh.
                let uncleared = try await inbox.rows().contains { row in
                    guard case .object(let card) = row, card["id"] == .string(cardID) else { return false }
                    return card["resolved_reason"] != .string("doctor_clear")
                }
                if uncleared {
                    try await inbox.updateStatus(id: cardID, status: "archived", readAt: nil,
                                                 metadata: ["resolved_reason": .string("doctor_clear")])
                }
                return true
            }
            let content = try await port.assistanceCard(dataRoot: dataRoot,
                input: .object(["kind": .string("doctor"), "asks": .array(asks)]))
            let detail = content.detail
            let now = ISO8601DateFormatter().string(from: Date())
            let title = content.title
            let newOccurrence = try await inbox.upsert(id: cardID) { existing in
                var card: [String: JSONValue] = [
                    "id": .string(cardID),
                    "created_at": .string(now),
                    "source": .string("doctor_ask"),
                    "severity": .string("actionable"),
                    "title": .string(title),
                    "summary": .string(content.summary),
                    "detail": .string(detail),
                    "related_mission_id": .null,
                    "related_approval_id": .null,
                    "related_paths": .array([]),
                    "related_groups": .array([]),
                    "actions": .array([
                        .object(["id": .string("archive"), "label": .string("Archive"),
                                 "description": .string("Archive this card")]),
                        .object(["id": .string("dismiss"), "label": .string("Dismiss"),
                                 "description": .string("Dismiss this card")]),
                    ]),
                    "status": .string("unread"),
                    "read_at": .null,
                ]
                // Same list User already saw: keep his status, no resurfacing.
                if case .object(let previous)? = existing, previous["detail"] == .string(detail),
                   previous["resolved_reason"] != .string("doctor_clear") {
                    for key in ["status", "read_at", "created_at"] {
                        if let value = previous[key] { card[key] = value }
                    }
                    return (.object(card), false)
                }
                return (.object(card), true)
            }
            // Card filing acknowledges Doctor's transition independently of
            // transport acceptance. Unread failed sends remain eligible.
            do {
                guard let value = try await inbox.rows().first(where: {
                    if case .object(let card) = $0 { return card["id"] == .string(cardID) }
                    return false
                }), case .object(let card) = value, card["detail"] == .string(detail),
                    newOccurrence || card["status"] == .string("unread"),
                    case .string(let createdAt)? = card["created_at"] else { return true }
                let eventID = "\(cardID):\(createdAt):\(AttentionRouter.stableDigest(detail))"
                try await port.routeDoctorAsk(eventID: eventID, title: title, detail: detail)
            } catch {
                nativeLog("[Doctor] sign-in ask push failed: %@", error.localizedDescription)
            }
            return true
        } catch {
            nativeLog("[Doctor] sign-in ask card write failed: %@", error.localizedDescription)
            return false
        }
    }

    /// The mounted six-hour retention wake handles date-named trace expiry,
    /// old orphan lock sidecars, and excess pre-compaction transcript backups.
    /// The generic sweep is bounded, so it drains large historical residue
    /// across wakes instead of turning a maintenance tick into a disk walk.
    public func makeTurnTraceRetentionLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        intervalSeconds: TimeInterval = 6 * 60 * 60
    ) -> some LoopRunner {
        TurnTraceRetentionRunner(
            interval: intervalSeconds,
            dataRoot: dataRoot
        )
    }

    /// Off-disk backup into iCloud Drive at its daily deadline and after
    /// identity-file changes. See `OffDiskBackupRunner`.
    public func makeOffDiskBackupLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> some LoopRunner {
        OffDiskBackupRunner(port: port, interval: 24 * 60 * 60, dataRoot: dataRoot)
    }

    /// Weekly self-improvement analyzer (replaces the dead janitor
    /// sweep). Reads a week of real usage, asks the app's own LLM what to
    /// improve, and stages runtime-class findings as one-tap-approvable items
    /// via the approval inbox. Gated on the shared unattended-work gate.
    public func selfImprovementSwitchOn() -> Bool {
        // On unless the person switched it off (User: fresh installs turn every
        // feature on). Matches the @AppStorage defaults on the two switches
        // that write this key (SelfImprovementView, SetupFeatureRows).
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
                // 2026-09-13: this used to return `!yolo.admitted`, so the one
                // posture User says opens everything — admitted Full Mac YOLO —
                // was the one posture that silenced the loop, while damaged
                // authority (never admitted) RAN it, and Safe with autonomy off
                // ran it too. The unattended-work gate is the single answer to
                // "may the agent work while nobody is looking".
                return await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: dataRoot)
            },
            stageProposal: { proposal in
                var apply: [String: JSONValue] = ["op": .string(proposal.applyOp ?? ""),
                                                  "target": .string(proposal.applyTarget ?? "")]
                var preview: String = {
                    switch (proposal.applyOp, proposal.applyTarget) {
                    case ("disable_skill"?, let target?): return "Turn off the \(target) skill. "
                    case ("enable_skill"?, let target?): return "Turn on the \(target) skill. "
                    case ("run_memory_hygiene"?, _): return "Approving runs memory hygiene: duplicates merge and test noise clears. "
                    case (let op?, _) where !op.isEmpty:
                        return "Approving runs: " + op.replacingOccurrences(of: "_", with: " ") + ". "
                    default: return ""
                    }
                }() + String(proposal.proposedChange.prefix(180))
                if proposal.applyOp == "enable_skill" {
                    let target = proposal.applyTarget ?? ""
                    let tools = try await SwiftNativeToolRegistry(root: dataRoot).listTools(filter: .all)
                    guard let tool = tools.first(where: { $0.id.caseInsensitiveCompare(target) == .orderedSame })
                        ?? tools.first(where: { $0.name.caseInsensitiveCompare(target) == .orderedSame }) else {
                        throw ToolRegistryError.invalidRequest("Cannot stage approval: \(target) is unavailable.")
                    }
                    apply["target"] = .string(tool.id)
                    if let digest = tool.reviewedKeepDigest, let review = tool.keepReview {
                        // Persist the identity of the code shown NOW, never one
                        // reread when this card is eventually approved or replayed.
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
                // SKIP-IF-PRESENT (2026-09-06). A sweep that failed partway
                // rolls its weekly marker back, so the next tick re-runs the
                // whole pass — and every proposal that HAD staged got a second
                // card under a fresh UUID. The finding's own content digest
                // rides in the payload and is checked against the pending
                // queue first. Only PENDING rows suppress: a finding the user
                // already approved or denied is free to return in a later week.
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
                    // WHAT one tap will do, in words: the op slug
                    // ("[run_memory_hygiene]") stays in the payload, never on
                    // the card (User, 2026-09-25). A skill op names its skill.
                    "payloadPreview": .string(preview),
                ])
                do {
                    return try await inbox.create(body).id
                } catch {
                    // FIX 3 (A4.5): rethrow so the loop rolls back its weekly
                    // marker (retry next tick) and returns .failed — a swallowed
                    // create() silently dropped the proposal while the pass still
                    // reported "weekly proposals staged".
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
                let weeks = [MemoryStatusProjection.isoWeek(), MemoryStatusProjection.isoWeek(ago: 1)]
                do {
                    let lessons = try await MemoryStatusProjection.misses(dataRoot: dataRoot, weeks: weeks)
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
            // A standing lesson rides the REM path: one GROWTH row per memory
            // (its id makes a re-offer a no-op, approved or denied), through
            // REM's tombstone filter (a line denied or retired before stays
            // gone, whichever memory offers it), staged by the same stager the
            // weekly REM job uses.
            stageStandingLessons: { lines in
                let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
                let tombstones = REMTombstoneStore(dataRoot: dataRoot)
                var proposals: [REMProposal] = []
                for (id, line) in lines.sorted(by: { $0.key < $1.key }) {
                    guard let memory = try await storage.memory(id: id) else { continue }
                    // One card per wording of the correction: an edited one
                    // (its card goes stale) can be offered again.
                    let proposal = REMProposal(
                        id: "standing-\(id)-\(MemoryStorage.contentHash(memory.content).prefix(12))",
                        targetDoc: "GROWTH.md", proposalText: line, evidenceDates: [],
                        confidence: 1, createdAt: ISO8601DateFormatter().string(from: Date()),
                        supportingPassages: [REMSupportingPassage(dreamDate: "", quote: memory.content, sourceRefs: ["memory:" + id])],
                        support: .standing)
                    if try await !tombstones.isTombstoned(proposal) { proposals.append(proposal) }
                }
                try await REMProposalStore(dataRoot: dataRoot).appendPending(proposals)
                await DreamBackgroundWork.stagePendingREMProposalsAtLaunch(dataRoot: dataRoot, notifications: port)
                return proposals.map(\.id)
            }
        )
    }

    /// The previous pass's cards, by the ids its digest recorded — its
    /// one-tap proposals (`approval:`) and its standing lessons (`rem:`) — and
    /// what became of each, its execution receipt included.
    static func passOutcomes(cards: [String], inbox: SwiftNativeApprovalInbox, dataRoot: URL) async -> String {
        let rem = REMProposalStore(dataRoot: dataRoot).loadAll()
        var lines: [String] = []
        for card in cards {
            var what = card, approvalID: String?
            if card.hasPrefix("approval:") {
                approvalID = String(card.dropFirst("approval:".count))
            } else if let row = rem.first(where: { "rem:" + $0.id == card }) {
                what = "standing lesson: " + row.proposalText
                approvalID = row.approvalId
            }
            guard let approvalID else { lines.append("- \(what): not on a card now (it is staged again)"); continue }
            guard let record = try? await inbox.get(approvalID) else { lines.append("- \(what): its card is gone"); continue }
            if card.hasPrefix("approval:") { what = record.title }
            var failed = false
            if case .object(let executed)? = record.executedAction { failed = executed["error"] != nil }
            let outcome = record.status == "pending" ? "ignored, still waiting"
                : record.decision == "approved" ? (record.executedAction == nil ? "approved, not yet carried out"
                    : failed ? "approved, but carrying it out failed: \(record.detail ?? "")" : "approved and carried out")
                : record.decision == "denied" || record.status == "denied" ? "denied" : "ignored (\(record.decision ?? record.status))"
            lines.append("- \(what): \(outcome)")
        }
        return "## The last pass: its proposals and what became of them\n" + (lines.isEmpty ? "(none recorded)" : lines.joined(separator: "\n"))
    }

    /// Standing lessons, measured on 14 days of live traces (2026-09-27 to
    /// 10-10, 35 and 96 conversations a week): a correction or instruction
    /// recalled at least `standingUses` times that ran through (half or more of
    /// the turns of) at least `standingSessions` conversations and two thirds
    /// of the week's. Each week three corrections ran through 71–100% of the
    /// conversations, the fewest 25; the next ran through under half, topical
    /// ones a tenth or less. Every conversation with a context build counts,
    /// whether or not it recalled anything. Memory id → text.
    static let standingUses: Int64 = 1_000
    static let standingSessions = 25

    static func standingLessons(dataRoot: URL, now: Date = Date()) async throws -> [String: String] {
        let events = try await TurnTraceRecentReader(dataRootOverride: dataRoot)
            .read(now: now, since: now.addingTimeInterval(-7 * 86_400)).events
        var sessionOf: [String: String] = [:]
        for event in events { if let session = event.sessionId { sessionOf[event.turnId] = session } }
        var turns: [String: Int] = [:]
        var recalls: [String: [String: Int]] = [:]
        for event in events where event.kind == "context.summary" {
            guard let session = sessionOf[event.turnId], case .object(let payload) = event.payload,
                  case .array(let ids)? = payload["injectedMemoryIds"] else { continue }
            turns[session, default: 0] += 1
            for case .string(let id) in ids { recalls[id, default: [:]][session, default: 0] += 1 }
        }
        func throughout(_ id: String) -> Int {
            (recalls[id] ?? [:]).filter { $0.value * 2 >= turns[$0.key] ?? 0 }.count
        }
        let rows = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
            .listMemories(persona: nil, status: "active", limit: nil)
        return Dictionary(uniqueKeysWithValues: rows.filter {
            ["correction", "instruction"].contains(MemoryMoments.metadataString($0.metadata, "kind") ?? "")
                && $0.useCount >= standingUses && throughout($0.id) >= standingSessions
                && throughout($0.id) * 3 >= turns.count * 2
        }.map { ($0.id, $0.content) })
    }

    /// Daily read-only accounting; only the card's action executes owner reclamation plans.
    public func makeDataRootDiskHygieneLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> DataRootDiskHygieneCheck {
        DataRootDiskHygieneCheck(
            dataRoot: dataRoot,
            fileNotice: { report in await fileDiskHygieneNotice(dataRoot: dataRoot, report: report) }
        )
    }

    // The weekly self-improvement loop's on/off gate is the
    // "selfImprovementEnabled" UserDefaults flag, owned by the Self-Improvement
    // tab's switch (SelfImprovementView). Read inline in makeWeeklySelfImprovementLoop.

    // MARK: - Disk-hygiene notification

    public let diskHygieneCardId = "disk-hygiene"

    private func diskStorageOwners(dataRoot: URL) -> [DiskStorageOwner] {
        port.diskStorageOwners(dataRoot: dataRoot) + [
            DiskStorageOwner(id: "residue", plan: {
                let roots = DataRootDiskHygiene.residueRelativePrefixes
                var candidates: [String: DiskStorageOwner.Candidate] = [:]
                for path in roots where FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent(path).path) {
                    candidates[path] = try DiskStorageOwner.candidate(path, dataRoot: dataRoot)
                }
                return DiskStorageOwner.Plan(owner: "residue", roots: roots,
                    policy: "Unused HuggingFace residue moves to Trash.", candidates: candidates)
            }, reclaim: { saved in
                saved.candidates.sorted(by: { $0.key < $1.key }).map { path, token in
                    guard DataRootDiskHygiene.residueRelativePrefixes.contains(path) else {
                        return DiskStorageOwner.Outcome(relativePath: path, skippedReason: "not declared by this owner; kept")
                    }
                    return DiskStorageOwner.trash(path, candidate: token, dataRoot: dataRoot)
                }
            })
        ]
    }

    public func fileDiskHygieneNotice(dataRoot: URL, report: DiskHygieneReport) async -> Bool {
        guard report.tripped else {
            guard !report.truncated, !report.depthTruncated, !report.readFailed else { return true }
            do {
                let now = Date()
                _ = try await LiveNotificationInbox.live(dataRoot: dataRoot).archiveActive(
                    ids: [diskHygieneCardId], readAt: now.ISO8601Format(), createdNoLaterThan: now,
                    metadata: ["automatically_resolved": .bool(true), "actions": .array([]), "cleanup_plans": .array([])])
                return true
            } catch {
                nativeLog("Disk hygiene: resolved notice could not be archived: %@", String(describing: error))
                return false
            }
        }
        var plans: [DiskStorageOwner.Plan] = []
        var planReads: [JSONValue] = []
        for owner in diskStorageOwners(dataRoot: dataRoot) {
            do {
                plans.append(try await owner.plan())
                planReads.append(.object(["owner": .string(owner.id), "status": .string("available")]))
            } catch {
                planReads.append(.object(["owner": .string(owner.id), "status": .string("unavailable"),
                                          "error": .string(error.localizedDescription)]))
            }
        }
        var usage = report.storageBytes.filter { !$0.key.contains("/") }
        for plan in plans {
            var bytes: Int64 = 0
            for root in plan.roots {
                let size = report.storageBytes[root] ?? 0
                bytes += size
                let top = String(root.split(separator: "/").first ?? "")
                usage[top, default: 0] -= size
            }
            usage[plan.owner, default: 0] += bytes
        }
        let reclaimable = plans.reduce(Int64(0)) { sum, plan in
            sum + plan.candidates.values.reduce(0) { $0 + $1.sizeBytes }
        }
        let finding = (usage.filter { $0.value > DataRootDiskHygiene.defaultDirectoryThreshold }
            .keys.sorted() + (report.totalOverBudget ? ["dynamic"] : [])
            + report.largeFiles.map { "file:\($0.relativePath)" }.sorted()
            + plans.filter { !$0.candidates.isEmpty }.map { "reclaim:\($0.owner)" }.sorted()
            + ["reclaim-tier:\(reclaimable / DataRootDiskHygiene.defaultDirectoryThreshold)"])
            .joined(separator: "|")
        let usageRows: [JSONValue] = usage.map { owner, bytes in
            let plan = plans.first { $0.owner == owner }
            let reclaim = plan?.candidates.values.reduce(Int64(0)) { $0 + $1.sizeBytes } ?? 0
            return .object(["owner": .string(owner), "bytes": .int(bytes),
                            "size": .string(DataRootDiskHygiene.humanSize(bytes)),
                            "reclaimSize": .string(DataRootDiskHygiene.humanSize(reclaim)),
                            "policy": plan.map { .string($0.policy) } ?? .null])
        }
        var actions: [JSONValue] = []
        if reclaimable > 0 {
            actions.append(.object(["id": .string("act"), "label": .string("Clean Up"),
                "description": .string("Move the listed owner-approved bytes to Trash")]))
        }
        actions += [
            .object(["id": .string("archive"), "label": .string("Archive"), "description": .string("Archive this card")]),
            .object(["id": .string("dismiss"), "label": .string("Dismiss"), "description": .string("Dismiss this card")])
        ]
        do {
            let content = try await port.assistanceCard(dataRoot: dataRoot, input: .object([
                "kind": .string("storage"), "usage": .array(usageRows), "planReads": .array(planReads),
                "plans": .array(plans.map { .object(["notes": .array($0.notes.map(JSONValue.string))]) }),
                "reclaimable": .int(reclaimable),
                "dynamicSize": .string(DataRootDiskHygiene.humanSize(report.dynamicBytes)),
                "budgetSize": .string(DataRootDiskHygiene.humanSize(DataRootDiskHygiene.defaultTotalThreshold)),
                "modelSize": .string(DataRootDiskHygiene.humanSize(report.staticModelBytes)),
                "reclaimSize": .string(DataRootDiskHygiene.humanSize(reclaimable)),
                "accounting": .object(["status": .string(report.truncated || report.depthTruncated || report.readFailed ? "partial" : "available"),
                    "truncated": .bool(report.truncated), "depthTruncated": .bool(report.depthTruncated), "readFailed": .bool(report.readFailed)])
            ]))
            let card: JSONValue = .object([
                "id": .string(diskHygieneCardId), "created_at": .string(Date().ISO8601Format()),
                "source": .string("disk_hygiene"), "severity": .string(reclaimable > 0 ? "actionable" : "info"),
                "title": .string(content.title), "summary": .string(content.summary),
                "detail": .string(content.detail), "finding_identity": .string(finding),
                "cleanup_plans": try JSONValue.fromEncodable(plans), "actions": .array(actions),
                "related_paths": .array([]), "related_groups": .array([]),
                "related_mission_id": .null, "related_approval_id": .null,
                "status": .string("unread"), "read_at": .null])
            guard let notify = await upsertDiskHygieneCard(dataRoot: dataRoot, card: card, preserveStatus: true,
                scanStartedAt: report.startedAt) else { return false }
            if notify {
                await port.notifyIfAttentionWorthy(dataRoot: dataRoot, itemId: diskHygieneCardId,
                    title: content.title, summary: content.summary, source: "disk_hygiene",
                    severity: reclaimable > 0 ? "actionable" : "info")
            }
            return true
        } catch {
            nativeLog("Disk hygiene: plan could not be saved: %@", String(describing: error))
            return false
        }
    }

    /// Both the card and inbox.clean_up execute this saved plan, never a larger fresh one.
    public func cleanUpDiskHygiene(dataRoot: URL = PersistenceCore.defaultDataRoot()) async throws -> String {
        let inboxPath = dataRoot.appendingPathComponent("notifications/inbox.jsonl")
        // Preparing a legacy card may call her part. Do that before the
        // publication lock; the locked read below still owns the saved scope.
        if let row = try await LiveNotificationInbox.live(dataRoot: dataRoot).rows().first(where: {
            $0.objectValue?["id"] == .string(diskHygieneCardId)
        }), row.objectValue?["cleanup_plans"] == nil {
            guard await fileDiskHygieneNotice(dataRoot: dataRoot, report: DataRootDiskHygiene.scan(dataRoot: dataRoot)) else {
                throw NSError(domain: "NativeAgentDisk", code: 500, userInfo: [NSLocalizedDescriptionKey:
                    "Disk finding could not be refreshed; nothing was moved."])
            }
            throw NSError(domain: "NativeAgentDisk", code: 409, userInfo: [NSLocalizedDescriptionKey:
                "Disk finding refreshed. Review its current cleanup plan before running Clean Up."])
        }
        return try await SwiftNativePersistenceCore().withFileLock(inboxPath) {
            let lines = try LiveNotificationInbox.readLines(inboxPath)
            guard let row = lines.compactMap(\.row).first(where: {
                      guard case .object(let object) = $0 else { return false }
                      return object["id"] == .string(diskHygieneCardId)
                  }), case .object(let object) = row else {
                throw NSError(domain: "NativeAgentDisk", code: 409, userInfo: [NSLocalizedDescriptionKey:
                    "No saved cleanup plan. Refresh the disk finding before cleaning up."])
            }
            // A concurrent legacy replacement still authorizes no fresh scope.
            guard let plans = object["cleanup_plans"] else {
                throw NSError(domain: "NativeAgentDisk", code: 409, userInfo: [NSLocalizedDescriptionKey:
                    "No saved cleanup plan. Refresh the disk finding before cleaning up."])
            }
            let card = (object, try JSONDecoder().decode([DiskStorageOwner.Plan].self, from: plans.serializedData(pretty: false)))
            let owners = diskStorageOwners(dataRoot: dataRoot)
            guard card.1.contains(where: { !$0.candidates.isEmpty }) else {
                throw NSError(domain: "NativeAgentDisk", code: 409, userInfo: [NSLocalizedDescriptionKey:
                    "No safely reclaimable bytes are offered by this card. Its storage is kept for the reasons shown."])
            }
            var outcomes: [DiskStorageOwner.Outcome] = []
            for plan in card.1 where !plan.candidates.isEmpty {
                do {
                    guard let owner = owners.first(where: { $0.id == plan.owner }) else {
                        throw NSError(domain: "NativeAgentDisk", code: 409, userInfo: [NSLocalizedDescriptionKey: "Storage owner is unavailable; kept."])
                    }
                    outcomes += try await owner.reclaim(plan)
                } catch {
                    outcomes += plan.candidates.keys.sorted().map {
                        DiskStorageOwner.Outcome(relativePath: $0, skippedReason: error.localizedDescription)
                    }
                }
            }
            let reclaimed = outcomes.filter { $0.skippedReason == nil }.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let skipped = outcomes.filter { $0.skippedReason != nil }.count
            let summary = "Reclaimed \(DataRootDiskHygiene.humanSize(reclaimed)) from app storage to Trash; \(skipped) skipped."
            let receipt = summary + "\n" + outcomes.map {
                if let reason = $0.skippedReason { return "• Skipped \($0.relativePath): \(reason)" }
                return "• Moved \($0.relativePath) to Trash: \(DataRootDiskHygiene.humanSize($0.sizeBytes))"
            }.joined(separator: "\n") + "\nTrash is recoverable and still occupies disk space until you empty it."
            var replacement = card.0
            replacement["cleanup_detail"] = .string(receipt)
            replacement["detail"] = .string(receipt)
            replacement["summary"] = .string(summary)
            replacement["title"] = .string("Disk cleanup")
            replacement["severity"] = .string(skipped == 0 ? "info" : "actionable")
            replacement["status"] = .string("read")
            replacement["read_at"] = .string(Date().ISO8601Format())
            replacement["cleanup_completed_at"] = .double(Date().timeIntervalSince1970)
            replacement["cleanup_plans"] = .array([])
            if case .array(let actions)? = replacement["actions"] {
                replacement["actions"] = .array(actions.filter {
                    guard case .object(let action) = $0 else { return true }
                    return action["id"] != .string("act")
                })
            }
            guard await upsertDiskHygieneCard(dataRoot: dataRoot, card: .object(replacement), preserveStatus: false) != nil else {
                throw NSError(domain: "NativeAgentDisk", code: 500, userInfo: [NSLocalizedDescriptionKey:
                    receipt + "\nCleanup completed, but its card could not be saved."])
            }
            if reclaimed == 0, skipped > 0 {
                throw NSError(domain: "NativeAgentDisk", code: 409, userInfo: [NSLocalizedDescriptionKey: receipt])
            }
            return summary
        }
    }

    /// Preserve acknowledgment by owner/budget finding, and retain the last cleanup receipt.
    private func upsertDiskHygieneCard(
        dataRoot: URL,
        card: JSONValue,
        preserveStatus: Bool,
        scanStartedAt: Date? = nil
    ) async -> Bool? {
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let persistence = SwiftNativePersistenceCore()
        do {
            let inserted = try await persistence.withFileLock(inboxPath) { () async throws -> Bool in
                let lines = try LiveNotificationInbox.readLines(inboxPath)
                var mutated: [Data] = []
                mutated.reserveCapacity(lines.count + 1)
                var found = false
                var notify = false
                for line in lines {
                    guard case .object(let obj)? = line.row,
                          case .string(let id)? = obj["id"],
                          id == diskHygieneCardId else {
                        // Other rows AND undecodable lines: verbatim.
                        mutated.append(line.raw)
                        continue
                    }
                    if let scanStartedAt, case .double(let completed)? = obj["cleanup_completed_at"],
                       completed > scanStartedAt.timeIntervalSince1970 {
                        throw NSError(domain: "NativeAgentDisk", code: 409, userInfo: [NSLocalizedDescriptionKey:
                            "Disk cleanup completed after this scan; a fresh accounting is required."])
                    }
                    var replacement = card
                    if preserveStatus, case .object(var newObj) = card {
                        newObj["cleanup_completed_at"] = obj["cleanup_completed_at"]
                        func identity(_ value: JSONValue?) -> (Set<String>, Int64) {
                            guard case .string(let value) = value else { return ([], 0) }
                            let parts = value.split(separator: "|").map(String.init)
                            let tier = parts.first { $0.hasPrefix("reclaim-tier:") }
                                .flatMap { Int64($0.dropFirst("reclaim-tier:".count)) } ?? 0
                            return (Set(parts.filter { !$0.hasPrefix("reclaim-tier:") }), tier)
                        }
                        let oldFinding = identity(obj["finding_identity"])
                        let newFinding = identity(newObj["finding_identity"])
                        let sameFinding = obj["finding_identity"] == nil
                            || (newFinding.0.isSubset(of: oldFinding.0) && newFinding.1 <= oldFinding.1)
                        if sameFinding, obj["automatically_resolved"] != .bool(true) {
                            newObj["status"] = obj["status"] ?? .string("unread")
                            newObj["read_at"] = obj["read_at"] ?? .null
                        } else { notify = true }
                        if case .string(let receipt)? = obj["cleanup_detail"],
                           case .string(let detail)? = newObj["detail"] {
                            newObj["cleanup_detail"] = .string(receipt)
                            newObj["detail"] = .string(detail + "\n\nLast cleanup:\n" + receipt)
                        }
                        replacement = .object(newObj)
                    }
                    mutated.append(Data(try replacement.serialize(pretty: false).utf8))
                    found = true
                }
                if !found { mutated.append(Data(try card.serialize(pretty: false).utf8)) }
                try LiveNotificationInbox.write(mutated, to: inboxPath)
                return !found || notify
            }
            return inserted
        } catch {
            // A failed upsert must report failure so the loop rolls back the
            // daily reservation and retries delivery on the next tick.
            FileHandle.standardError.write(Data(
                "DataRootDiskHygieneCheck: notice upsert failed: \(error)\n".utf8))
            return nil
        }
    }
}

/// Auto Doctor wrapper that honors the persisted toggle. The scheduler still
/// sees the canonical `doctor_auto_run` id, but disabled means the tick is a
/// no-op instead of running diagnostics.
private struct ConfiguredDoctorAutoRunLoop: LoopRunner {
    let enabled: Bool
    let doctor: DoctorAutoRunLoop

    var loopId: String { doctor.loopId }
    var interval: TimeInterval { doctor.interval }
    var tickTimeoutOverride: TimeInterval? { doctor.tickTimeoutOverride }

    func tickOutcome() async -> LoopTickOutcome {
        guard enabled else { return .off("auto doctor disabled") }
        return await doctor.tickOutcome()
    }
}

/// M7: prunes `turn_traces/` to the newest ~14 days; the sidecar lifecycle
/// reclaims orphaned locks. A sweep that removes anything says so.
private struct TurnTraceRetentionRunner: LoopRunner {
    let interval: TimeInterval
    let dataRoot: URL

    var loopId: String { "turn_trace_retention" }
    var tickTimeoutOverride: TimeInterval? { 60 }

    func tickOutcome() async -> LoopTickOutcome {
        do {
            let now = Date()
            let traceReport = try await TurnTraceRetention.enforce(dataRoot: dataRoot, now: now)
            let lockReport = try await FileLockSidecarLifecycle.reapOrphanedSidecars(
                dataRoot: dataRoot,
                now: now
            )
            let backupReport = await ChatCompactionBackupRetention.enforce(dataRoot: dataRoot)
            // 2026-09-01 (User): this pass no longer writes
            // `data/logs/maintenance_sweep.jsonl`. It had accumulated 2,921 rows
            // / 613 KB with no production reader — only an eval instrument and
            // its own test. The sweep itself is unchanged; what it removed is
            // still reported through the NSLog lines and the tick outcome below,
            // which is what anyone actually reads.
            if traceReport.removedDays > 0 {
                nativeLog("turn_trace_retention: removed %d day file(s) and %d lock(s), kept %d day(s)",
                      traceReport.removedDays, 0, traceReport.keptDays)
            }
            if lockReport.reaped > 0 || lockReport.deferred > 0 || lockReport.failures > 0 {
                nativeLog("file_lock_sidecar_lifecycle: reaped %d orphan lock(s), deferred %d, failures %d",
                      lockReport.reaped, lockReport.deferred, lockReport.failures)
            }
            if lockReport.failures > 0 {
                return .failed(error: "lock-sidecar sweep had \(lockReport.failures) failed candidate(s)")
            }
            if backupReport.removed > 0 || backupReport.failures > 0 || backupReport.truncated {
                nativeLog("chat_compaction_backup_retention: removed %d backup(s), scanned %d session(s), failures %d, truncated %@",
                      backupReport.removed, backupReport.sessionsScanned, backupReport.failures,
                      backupReport.truncated.description)
            }
            if backupReport.failures > 0 {
                return .failed(error: "compaction-backup sweep had \(backupReport.failures) failed session(s)")
            }
            let bounded = lockReport.deferred > 0
                ? "; \(lockReport.deferred) orphan lock(s) deferred"
                : ""
            let backupBounded = backupReport.truncated
                ? "; compaction-backup scan bounded at \(backupReport.sessionsScanned) sessions"
                : ""
            // A sweep that removed nothing and deferred nothing did no work.
            // Reporting it `.completed` every hour kept the dormancy clock
            // fresh regardless of whether retention was actually running.
            let swept = traceReport.removedDays
                + lockReport.reaped + backupReport.removed
            guard swept > 0 else {
                return .skipped(reason: "nothing past any retention cutoff\(bounded)")
            }
            return .completed(
                result: "maintenance retention removed \(swept) artifact(s)"
                    + "\(bounded)\(backupBounded)")
        } catch {
            nativeLog("turn_trace_retention: sweep failed: %@", String(describing: error))
            return .failed(error: String(describing: error))
        }
    }
}

private let backupCadenceRepairStep = "Repair or restore the backup-cadence part."

/// Versioned off-disk backup (`port.createOffDiskBackup`). Her backup-cadence
/// part selects the deadline and trigger from native backup freshness and
/// identity-file modification observations; the shipped seed keeps daily and
/// identity-change timing. Metadata reads, root protection and copying stay here.
/// Identity-file invalidations coalesce before the canonical reread; the daily
/// interval remains the missed-event/unavailable-volume backstop. With
/// iCloud Drive off the tick is an `unavailable:` skip (a WARN row in Doctor);
/// cancellation is not a backup defect; other failures are `.failed` and logged.
private struct OffDiskBackupRunner: EventDeadlineLoopRunner {
    let port: any MaintenanceBackgroundWorkPort
    let interval: TimeInterval
    let dataRoot: URL

    var loopId: String { "offdisk_backup" }
    var tickTimeoutOverride: TimeInterval? { 15 * 60 }

    func physiologyEvents() -> AsyncStream<Void> {
        guard dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL else {
            return EventDeadlinePhysiology.storeAndFileEvents(paths: [])
        }
        let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        let identityFiles = ((try? FileManager.default.contentsOfDirectory(
            at: personaRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { !$0.lastPathComponent.hasSuffix(".lock") }
        return EventDeadlinePhysiology.storeAndFileEvents(
            paths: [personaRoot, dataRoot.appendingPathComponent("memory/profile.json")] + identityFiles,
            loopId: loopId
        )
    }

    func nextMeaningfulDeadline(after now: Date) async -> Date? {
        guard dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL else { return nil }
        let parent = port.offDiskBackupParent()
        let port = port
        do {
            let newest = try await VolumeIO.run { try port.offDiskAutomaticBackups(in: parent).first?.date }
            return try await port.backupDeadline(dataRoot: dataRoot, input: .object([
                "kind": .string("deadline"), "now": .double(now.timeIntervalSince1970),
                "newest": newest.map { .double($0.timeIntervalSince1970) } ?? .null, "interval": .double(interval)
            ])).map { Date(timeIntervalSince1970: $0) }
        } catch where Task.isCancelled || error is CancellationError {
            return nil
        } catch let error as PartCallError {
            await recordDeadlineFailure(cadenceFailure(error, operation: "deadline"))
            return nil
        } catch {
            nativeLog("offdisk_backup: deadline unavailable: %@", error.localizedDescription)
            await recordDeadlineFailure(.failed(error: "off-disk backup failed: \(error.localizedDescription)"))
            return nil
        }
    }

    /// A deadline read runs outside the tick. Nil alone would erase its failure;
    /// use the same scheduler receipt and Doctor health path as a failed tick.
    private func recordDeadlineFailure(_ outcome: LoopTickOutcome) async {
        await settle {
            await BackgroundLoops.BackgroundLoopsManager.shared.recordOutOfBandOutcome(loopId: loopId, outcome: outcome)
        }
    }

    private func cadenceFailure(_ error: any Error, operation: String) -> LoopTickOutcome {
        let cause = "off-disk backup failed: backup-cadence part failed (\(operation)). "
            + backupCadenceRepairStep + " Error: \(error.localizedDescription)"
        nativeLog("offdisk_backup: %@", cause)
        return .failed(error: cause)
    }

    func tickOutcome() async -> LoopTickOutcome {
        // Only the live root goes to iCloud; an alternate (test) root must never
        // write into, or prune, User's backup folder.
        guard dataRoot.standardizedFileURL == PersistenceCore.defaultDataRoot().standardizedFileURL else {
            return .skipped(reason: "alternate data root")
        }
        let parent = port.offDiskBackupParent()
        let port = port
        do {
            // iCloud Drive reads block on dataless folders: off the pool.
            let drive = try await VolumeIO.run { () -> (available: Bool, newest: Date?) in
                guard FileManager.default.fileExists(atPath: parent.deletingLastPathComponent().path) else { return (false, nil) }
                return (true, try port.offDiskAutomaticBackups(in: parent).first?.date)
            }
            guard !Task.isCancelled else { return .skipped(reason: "canceled") }
            guard drive.available else {
                return .skipped(reason: port.unavailableSkipPrefix + "iCloud Drive is off — no off-disk backup")
            }
            let now = Date()
            let newest = drive.newest
            let identity: JSONValue
            do {
                identity = .object(["status": .string("available"),
                    "changedAt": try identityChangedAt().map { .double($0.timeIntervalSince1970) } ?? .null])
            } catch {
                identity = .object(["status": .string("unavailable"), "error": .string(error.localizedDescription)])
            }
            let selected = try await port.backupTrigger(dataRoot: dataRoot, input: .object([
                "kind": .string("trigger"), "now": .double(now.timeIntervalSince1970),
                "newest": newest.map { .double($0.timeIntervalSince1970) } ?? .null, "identity": identity
            ]))
            if selected == .current {
                return .skipped(reason: "newest off-disk backup is current")
            }
            let trigger = selected.rawValue
            let folder = try await port.createOffDiskBackup(
                reason: "automatic off-disk backup (\(trigger))",
                dataRoot: dataRoot,
                parent: parent,
                now: now
            )
            nativeLog("offdisk_backup: wrote %@ (%@)", folder.path, trigger)
            return .completed(result: "off-disk backup \(folder.lastPathComponent) (\(trigger))")
        } catch where Task.isCancelled || error is CancellationError {
            return .skipped(reason: "canceled")
        } catch let error as PartCallError {
            return cadenceFailure(error, operation: "trigger")
        } catch {
            nativeLog("offdisk_backup: FAILED — Agent has no fresh off-disk copy: %@", String(describing: error))
            return .failed(error: "off-disk backup failed: \(error.localizedDescription)")
        }
    }

    /// Newest modification among the persona root's own files (SOUL.md,
    /// GROWTH.md, ...) and the personality profile, which is where identity
    /// writes land.
    private func identityChangedAt() throws -> Date? {
        let fm = FileManager.default
        let personaRoot = PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)
        guard fm.fileExists(atPath: personaRoot.appendingPathComponent("SOUL.md").path) else {
            throw NSError(domain: "NativeAgentBackup", code: 422, userInfo: [
                NSLocalizedDescriptionKey: "Live persona root has no SOUL.md: \(personaRoot.path)",
            ])
        }
        var files = try fm.contentsOfDirectory(
            at: personaRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { !$0.lastPathComponent.hasSuffix(".lock") }
        let profile = dataRoot.appendingPathComponent("memory/profile.json")
        if fm.fileExists(atPath: profile.path) { files.append(profile) }
        return try files.compactMap { url -> Date? in
            let values = try url.resolvingSymlinksInPath()
                .resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            return values.isRegularFile == true ? values.contentModificationDate : nil
        }.max()
    }
}

/// Weekly, data-driven self-improvement pass.
///
/// Replaces the dead "sweep" janitor. Once per ~7 days (and only when the
/// `enableAutonomy` switch is on), it ingests a week of REAL usage — chat
/// transcripts, live error logs and Doctor health — asks the app's
/// OWN configured LLM (the same `LLMClient` every other loop uses, routed by
/// the `self_improvement` surface picker) what is failing / degrading /
/// underused, and turns the answer into one-tap-approvable proposals plus a
/// weekly digest.
///
/// Design notes:
/// - The brain is `llm.complete(...)` (provider routing the chat
///   already uses), NOT codex or any developer-only tooling, so a downloader
///   with any provider configured gets it.
/// - Honest split: runtime-class findings (skills / prompts / config / memory)
///   are stageable for one-tap apply; code-class findings flow into the
///   injected `fileCodeFinding` lane (the harness queue, for the builder)
///   and stay digest-only when that lane is not wired.
/// - tick() is non-throwing by LoopRunner contract. Operational failure is
///   returned through `tickOutcome()` so scheduler state and durable receipts
///   cannot claim the pass succeeded merely because the function returned.
public struct WeeklySelfImprovementLoop: LoopRunner {
    public let loopId: String = "self_improvement_sweep"
    public let interval: TimeInterval
    /// U5 W-D (2026-06-11): a tick ingests a week of usage and runs the
    /// weekly self-improvement LLM pass. The scheduler's default 300s budget
    /// cancels long LLM passes mid-call with no user-visible trace (audit
    /// 2026-06-09 — same lesson as telegram_poll / mission_executor; the
    /// execution-runner comment already cited a "self-improvement override" —
    /// this makes that claim true).
    public var tickTimeoutOverride: TimeInterval? { 3600 }

    private let llm: any LLMClient
    private let router: any ProviderRoutingProtocol
    private let dataRoot: URL
    private let clock: @Sendable () -> Date
    /// The on/off switch. Wired to the `enableAutonomy` trust-policy flag.
    private let isEnabled: @Sendable () async -> Bool
    /// Stages one runtime-class proposal as a one-tap-approvable item.
    /// Wired by the owning factory to `SwiftNativeApprovalInbox.create(...)`.
    ///
    /// 2026-07-23 FIX 3 (A4.5): `throws` so a failed staging write is
    /// OBSERVABLE. Previously `async -> Void` swallowed the write failure and
    /// the tick still returned `.completed("weekly proposals staged")` — a
    /// silent proposal drop. A throw now propagates to the outer catch, which
    /// rolls back the weekly marker (retry next tick) and returns `.failed`,
    /// tripping the manager's background_loop_failures.jsonl receipt net.
    /// Returns the id of the approval card that carries it, for the digest.
    private let stageProposal: @Sendable (SelfImprovementProposal) async throws -> String
    /// U2b wave 2: code-class findings used to die in the digest ("a signed
    /// app can't recompile itself" — no longer true on a repo-stamped
    /// install). When wired, every code finding is ALSO handed here; the
    /// owning factory files it on the harness queue for the builder.
    /// nil → digest-only.
    private let fileCodeFinding: (@Sendable (SelfImprovementProposal) async throws -> Void)?
    /// MEASURE leg (north-star, 2026-06-15): a compact week-over-week
    /// execution-outcome summary so the self-improvement brain reasons over REAL
    /// job OUTCOMES (completion rate / steps / wall-time trend), not only
    /// chat/error/doctor proxies. EngineLaunch binds the weekly-outcomes part
    /// through the originating maintenance door. Empty history omits the signal;
    /// unavailable sources or a failed part fail the pass rather than erase it.
    private let workshopOutcomes: @Sendable () async throws -> String
    /// What the pass learns from (2026-10-10), given the cards its previous
    /// digest recorded: misses by lesson, what became of those cards, and the
    /// standing corrections ready to graduate. Injected like
    /// `workshopOutcomes`; the default learns nothing.
    private let learning: @Sendable (_ previousCards: [String]?) async -> SelfImprovementLearning
    /// Stages the standing lessons the analyst wrote (memory id → GROWTH line)
    /// as REM cards and returns their REM proposal ids. Throws like `stageProposal`.
    private let stageStandingLessons: @Sendable ([String: String]) async throws -> [String]

    public init(
        interval: TimeInterval = 7 * 24 * 60 * 60,
        llm: any LLMClient,
        router: any ProviderRoutingProtocol = SwiftNativeProviderRouting(),
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        clock: @escaping @Sendable () -> Date = { Date() },
        isEnabled: @escaping @Sendable () async -> Bool,
        stageProposal: @escaping @Sendable (SelfImprovementProposal) async throws -> String,
        fileCodeFinding: (@Sendable (SelfImprovementProposal) async throws -> Void)? = nil,
        workshopOutcomes: @escaping @Sendable () async throws -> String,
        learning: @escaping @Sendable (_ previousCards: [String]?) async -> SelfImprovementLearning = { _ in SelfImprovementLearning() },
        stageStandingLessons: @escaping @Sendable ([String: String]) async throws -> [String] = { _ in [] }
    ) {
        self.interval = interval
        self.llm = llm
        self.router = router
        self.dataRoot = dataRoot
        self.clock = clock
        self.isEnabled = isEnabled
        self.stageProposal = stageProposal
        self.fileCodeFinding = fileCodeFinding
        self.workshopOutcomes = workshopOutcomes
        self.learning = learning
        self.stageStandingLessons = stageStandingLessons
    }

    /// Requests one cadence-bypassing pass without deleting the canonical
    /// weekly stamp from a view. The request and the loop's stamp decision use
    /// the same cross-process lock, so a manual click cannot open a duplicate
    /// execution window beside a periodic/BGTask tick.
    public static func requestManualRun(dataRoot: URL) async throws -> String {
        let directory = dataRoot.appendingPathComponent("self_improvement", isDirectory: true)
        let marker = directory.appendingPathComponent("last_weekly_run")
        let request = directory.appendingPathComponent("manual_run_requested")
        let token = UUID().uuidString
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(marker) {
            try Data(token.utf8).write(to: request, options: .atomic)
        }
        return token
    }

    /// Clears any unconsumed request after the one-shot caller has received a
    /// terminal/coalesced result. If the loop consumed it, this is a no-op.
    public static func clearManualRunRequest(dataRoot: URL, token: String) async throws {
        let directory = dataRoot.appendingPathComponent("self_improvement", isDirectory: true)
        let marker = directory.appendingPathComponent("last_weekly_run")
        let request = directory.appendingPathComponent("manual_run_requested")
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(marker) {
            guard FileManager.default.fileExists(atPath: request.path) else { return }
            let current = try String(contentsOf: request, encoding: .utf8)
            if current == token {
                try FileManager.default.removeItem(at: request)
            }
        }
    }

    public func tickOutcome() async -> LoopTickOutcome {
        guard await isEnabled() else {
            FileHandle.standardError.write(Data(
                "WeeklySelfImprovementLoop: disabled (enableAutonomy off)\n".utf8
            ))
            return .off("self-improvement or unattended work switched off")
        }
        do {
            try Task.checkCancellation()
            let now = clock()
            // Weekly idempotency: BOTH the BGTask and the in-app scheduler can
            // drive this loop. Without a marker a same-week double-tick would
            // re-run the analysis and stage duplicate proposals. Skip if we ran
            // within ~6 days (the same guard used by scheduled reflective work).
            let marker = dataRoot.appendingPathComponent("self_improvement", isDirectory: true)
                .appendingPathComponent("last_weekly_run")
            let manualRequest = marker.deletingLastPathComponent()
                .appendingPathComponent("manual_run_requested")
            try FileManager.default.createDirectory(
                at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Check-and-stamp under the cross-process file lock, BEFORE the
            // multi-minute LLM pass: check-then-stamp-after left a window
            // where a second driver (BGTask wake, the "run now" button) also
            // passed the 6-day guard and staged a full duplicate proposal
            // set (audit + gpt-5.5 review 2026-06-09). Restore the prior
            // stamp on failure so a failed pass doesn't suppress the retry. A
            // pending manual-run request forces this period (consumed inside
            // the lock so a click cannot open a duplicate window beside a tick).
            let nowStamp = ISO8601DateFormatter().string(from: now)
            let intervalFloor = interval - 24 * 60 * 60
            let reservation = await reserveOncePerPeriod(at: marker, stamp: nowStamp) { stored in
                let forced = FileManager.default.fileExists(atPath: manualRequest.path)
                if forced {
                    try FileManager.default.removeItem(at: manualRequest)
                    return false
                }
                guard let stamp = stored.flatMap(Self.parseISO) else { return false }
                return now.timeIntervalSince(stamp) < intervalFloor
            }
            let rollback: @Sendable () async -> Void
            switch reservation {
            case .alreadyReserved:
                return .skipped(reason: "weekly pass already committed")
            case .failed(let error):
                throw error
            case .reserved(_, let rb):
                rollback = rb
            }
            var passSucceeded = false
            var stagingStarted = false
            // Inner do/catch replaces the old sync defer: the rollback is now
            // an async flock'd compare-and-restore (2026-07-21 audit), which a
            // defer cannot await. Failure before staging restores the marker
            // so the next tick retries; cancellation after staging keeps it.
            do {
            try Task.checkCancellation()
            var signals = try gatherSignals(now: now)
            // MEASURE leg: fold in the real Workshop execution-outcome trend (async — reads
            // execution.json off disk). Empty when there's no history, so the
            // prompt is unchanged on a fresh install.
            let outcomes = try await workshopOutcomes()
            try Task.checkCancellation()
            if !outcomes.isEmpty { signals += "\n\n" + outcomes }
            let learned = await learning(previousPassCards())
            try Task.checkCancellation()
            if !learned.signals.isEmpty { signals += "\n\n" + learned.signals }
            if !learned.standing.isEmpty {
                signals += "\n\n## Standing lessons (recalled in nearly every conversation this week)\n"
                    + learned.standing.sorted { $0.key < $1.key }
                        .map { "- [\($0.key)] " + TurnSecretRedactor.redactText($0.value) }.joined(separator: "\n")
            }
            let pickedModel = await router.modelStringForSurface("self_improvement")
            try Task.checkCancellation()
            let raw = try await llm.complete(
                prompt: Self.analysisPrompt(signals: signals, now: now),
                system: Self.systemPrompt,
                model: pickedModel,
                surface: "self_improvement", purpose: "self_improvement"
            )
            try Task.checkCancellation()
            // Non-JSON output is a FAILED pass, not "nothing found" — the old
            // collapse to (summary: prefix, proposals: []) consumed the weekly
            // window on garbage. Throwing here lets the restore-marker catch
            // below rerun the pass next tick.
            guard var result = Self.parseResult(raw) else {
                throw NSError(domain: "WeeklySelfImprovementLoop", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "no parseable JSON object in LLM output (first 200 chars: \(raw.prefix(200)))"
                ])
            }
            // The cards this pass leaves, by id: the next pass follows them up.
            var cards: [String] = []
            for proposal in result.proposals where proposal.kind == .runtime {
                try Task.checkCancellation()
                stagingStarted = true
                cards.append("approval:" + (try await stageProposal(proposal)))
                try Task.checkCancellation()
            }
            // U2b wave 2: code findings get a lane instead of a dead end.
            // Same crash-window exposure as the runtime staging above (a
            // restored marker re-runs the whole pass): acceptable parity.
            if let fileCodeFinding {
                for proposal in result.proposals where proposal.kind == .code {
                    try Task.checkCancellation()
                    stagingStarted = true
                    try await fileCodeFinding(proposal)
                    try Task.checkCancellation()
                }
            }
            // Only lessons it was offered; an invented id stages nothing.
            result.standing = result.standing.filter { learned.standing[$0.key] != nil }
            if !result.standing.isEmpty {
                stagingStarted = true
                cards += try await stageStandingLessons(result.standing).map { "rem:" + $0 }
            }
            try Task.checkCancellation()
            // The pass IS the staging — mark success BEFORE the digest write.
            // A digest throw after staging used to restore the marker, so the
            // next tick re-ran the whole pass and DOUBLE-STAGED every
            // proposal. The digest is reporting, not the work: log-and-go.
            passSucceeded = true
            do {
                try writeDigest(result: result, outcomes: outcomes, cards: cards, now: now)
            } catch {
                FileHandle.standardError.write(Data(
                    "WeeklySelfImprovementLoop: digest write failed (proposals already staged): \(error)\n".utf8
                ))
            }
            FileHandle.standardError.write(Data(
                "WeeklySelfImprovementLoop: runtime=\(result.proposals.filter { $0.kind == .runtime }.count) code=\(result.proposals.filter { $0.kind == .code }.count)\n".utf8
            ))
            return .completed(result: "weekly proposals staged")
            } catch {
                // Once staging begins, cancellation cannot unstage its effects.
                // Keep the reservation then so a retry cannot duplicate them.
                if !passSucceeded && !(stagingStarted && (Task.isCancelled || error is CancellationError)) {
                    await rollback()
                }
                throw error
            }
        } catch is CancellationError {
            return .skipped(reason: "weekly pass cancelled")
        } catch {
            FileHandle.standardError.write(Data(
                "WeeklySelfImprovementLoop: tick failed: \(error)\n".utf8
            ))
            return .failed(error: String(describing: error))
        }
    }

    // MARK: - Signal collection

    /// Reads a week of real usage into a compact, LLM-readable summary.
    private func gatherSignals(now: Date) throws -> String {
        let weekAgo = now.addingTimeInterval(-interval)
        let fm = FileManager.default
        var sections: [String] = []

        // 1. Chat activity — volume + a SAMPLE of the user's own messages (where
        //    corrections / dissatisfaction show up).
        //
        //    The old walk took the FIRST forty user rows in directory/file
        //    order, so one long session at the front of the listing was the
        //    whole "week" the analyst ever saw and every quieter day was
        //    invisible. Selection now mirrors the dream sampler
        //    (`DreamCycleRunner.gatherRecentMessagesAcrossSessions`): REACH
        //    first — one turn from every day×session bucket in the window — then
        //    MEANING — the rest of the budget to the most-felt remaining turns.
        //    Ordering is total and value-derived, so the same week always
        //    samples the same forty with no RNG or seed to carry.
        //
        //    The mechanism is reimplemented here rather than called: the dream's
        //    `feltRankIndex` / gather are internal to DreamREMCycle and take a
        //    provider this loop is not wired with, and that module is not this
        //    change's to open.
        let messagesDir = dataRoot.appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        let feltWeights = Self.feltWeights(dataRoot: dataRoot)
        var candidates: [SampledUserMessage] = []
        var totalMessages = 0
        var sessionCount = 0
        if let files = try? fm.contentsOfDirectory(at: messagesDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "jsonl" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let sessionId = file.deletingPathExtension().lastPathComponent
                // Legacy rows carry no createdAt; the file's mtime orders and
                // day-buckets them, same fallback the dream gather uses.
                let mtime = (try? fm.attributesOfItem(atPath: file.path))?[.modificationDate]
                    as? Date ?? now
                var sessionHadRecent = false
                for line in text.split(separator: "\n") {
                    guard let data = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { continue }
                    let stamp = (obj["createdAt"] as? String).flatMap(Self.parseISO)
                    let at = stamp ?? mtime
                    if at < weekAgo { continue }
                    totalMessages += 1
                    sessionHadRecent = true
                    if Self.isHumanMessage(obj),
                       let content = obj["content"] as? String, !content.isEmpty {
                        let messageId = obj["id"] as? String ?? ""
                        candidates.append(SampledUserMessage(
                            at: at,
                            day: Self.todayString(at),
                            sessionId: sessionId,
                            messageId: messageId,
                            content: TurnSecretRedactor.redactText(content).prefix(280).description,
                            weight: Self.weight(
                                sessionId: sessionId, messageId: messageId, in: feltWeights)
                        ))
                    }
                }
                if sessionHadRecent { sessionCount += 1 }
            }
        }
        let userMessages = Self.sampleUserMessages(candidates, limit: 40).map(\.line)
        sections.append("""
        ## Chat activity (last 7 days)
        Messages: \(totalMessages) across \(sessionCount) session(s).
        Recent user messages (look for corrections, repeated asks, frustration, things the assistant got wrong):
        \(userMessages.isEmpty ? "(none)" : userMessages.map { "- \($0)" }.joined(separator: "\n"))
        """)

        // 2. Errors logged this week.
        for feed in ErrorFeeds.errorFeeds {
            sections.append(Self.recentLines(
                at: feed.url(dataRoot: dataRoot),
                since: weekAgo, label: "\(feed.label) error log (last 7 days)", limit: 30, fm: fm
            ))
        }

        // 3. Doctor health.
        let doctorPath = dataRoot.appendingPathComponent("doctor", isDirectory: true)
            .appendingPathComponent("latest.json")
        if let text = try? String(contentsOf: doctorPath, encoding: .utf8) {
            sections.append("## Doctor health (latest)\n\(text.prefix(1500))")
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Week sampling

    private static func isHumanMessage(_ row: [String: Any]) -> Bool {
        guard row["role"] as? String == "user" else { return false }
        if row["metadata"] != nil, !(row["metadata"] is [String: Any]) { return false }
        let metadata = row["metadata"] as? [String: Any] ?? [:]
        guard metadata["mechanicalKind"] == nil,
              metadata["kind"] as? String != "compaction_summary" else { return false }
        if let kind = metadata["turnKind"] as? String, kind != "live" { return false }
        let humanSurfaces = ["app", "chat", "mac", "default", "telegram", "slack", "ios", "iphone", "mobile", "icloud"]
        for key in ["origin", "envelope"] {
            if let recorded = metadata[key] {
                guard let provenance = recorded as? [String: Any], provenance["agent"] == nil,
                      let surface = provenance["surface"] as? String,
                      humanSurfaces.contains(surface) else { return false }
                if key == "origin", ["app", "chat", "mac", "default"].contains(surface) { return false }
            }
        }
        guard let source = row["source"] as? String else { return false }
        return humanSurfaces.contains(source)
    }

    /// One user turn inside the week's window, carrying the ids that make it
    /// citable back to the conversation it came from.
    struct SampledUserMessage: Sendable {
        let at: Date
        let day: String
        let sessionId: String
        let messageId: String
        let content: String
        let weight: Double

        /// The prompt line. The id tag is a source stamp, not new instruction —
        /// the analyst's evidence can now name the turn it read.
        var line: String {
            let source = messageId.isEmpty ? sessionId : "\(sessionId):\(messageId)"
            return "[\(day) \(source)] \(content)"
        }
    }

    /// Per-turn feeling weight, read from the receipts the MIND ALREADY WRITES:
    /// `<dataRoot>/cognition/caring_appraisals.jsonl`, one line per appraised
    /// turn, keyed `"<sessionId>:<messageId>"` of the user turn in `turn`.
    ///
    /// `repair` is the substrate's own existing mark for a correction, a
    /// mistake, or a hard moment — it weighs most, so the week's corrections
    /// and misses are OVER-REPRESENTED in the forty. The other named outcomes
    /// (`caredFor` / `needMet` / `roomMade`) are turns that landed and weigh
    /// one; `none` and the failure rows weigh nothing. No new heuristic and no
    /// new regex — this reads an existing signal.
    ///
    /// An unreadable or absent file means "nothing felt": reach still holds and
    /// the fill falls back to recency, which is honest on a fresh install.
    static func feltWeights(dataRoot: URL) -> [String: Double] {
        let url = dataRoot.appendingPathComponent("cognition", isDirectory: true)
            .appendingPathComponent("caring_appraisals.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var weights: [String: Double] = [:]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let turn = (obj["turn"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines), !turn.isEmpty,
                  let outcome = obj["outcome"] as? String
            else { continue }
            let weight: Double
            switch outcome {
            case "repair": weight = 3
            case "none", "call_failed", "unparseable": continue
            default: weight = 1
            }
            weights[turn] = max(weights[turn] ?? 0, weight)
            // Also bare-keyed: a receipt may carry the message id alone, the
            // same dual keying the dream's felt index uses.
            if let messageId = turn.split(separator: ":").last, !messageId.isEmpty {
                weights[String(messageId)] = max(weights[String(messageId)] ?? 0, weight)
            }
        }
        return weights
    }

    static func weight(sessionId: String, messageId: String, in weights: [String: Double]) -> Double {
        guard !weights.isEmpty, !messageId.isEmpty else { return 0 }
        return weights["\(sessionId):\(messageId)"] ?? weights[messageId] ?? 0
    }

    /// Pick `limit` turns that represent the week she actually lived:
    ///   1. REACH — one turn from every day×session that has material, the
    ///      most-felt in that bucket first, newest-active bucket first so a
    ///      budget too small to cover the week still covers its live days.
    ///   2. MEANING — what's left goes to the most-felt remaining turns,
    ///      wherever in the week they happened (ties break toward recent).
    /// The result is restored to chronological order: the analyst reads a week,
    /// not a ranking.
    static func sampleUserMessages(
        _ all: [SampledUserMessage], limit: Int
    ) -> [SampledUserMessage] {
        guard limit > 0, !all.isEmpty else { return [] }
        func moreMeaningful(_ lhs: Int, _ rhs: Int) -> Bool {
            let l = all[lhs], r = all[rhs]
            if l.weight != r.weight { return l.weight > r.weight }
            if l.at != r.at { return l.at > r.at }
            return lhs < rhs
        }
        var buckets: [String: [Int]] = [:]
        for index in all.indices {
            buckets["\(all[index].day)|\(all[index].sessionId)", default: []].append(index)
        }
        let bucketTimes = buckets.mapValues { indices in
            indices.reduce(Date.distantPast) { max($0, all[$1].at) }
        }
        var taken = Set<Int>()
        // PHASE 1 — reach.
        let bucketOrder = buckets.keys.sorted { lhs, rhs in
            let lat = bucketTimes[lhs] ?? .distantPast
            let rat = bucketTimes[rhs] ?? .distantPast
            if lat != rat { return lat > rat }
            return lhs < rhs
        }
        for key in bucketOrder {
            if taken.count >= limit { break }
            guard let best = buckets[key]?.min(by: moreMeaningful) else { continue }
            taken.insert(best)
        }
        // PHASE 2 — meaning.
        for index in all.indices.sorted(by: moreMeaningful) {
            if taken.count >= limit { break }
            taken.insert(index)
        }
        return taken.sorted { lhs, rhs in
            if all[lhs].at != all[rhs].at { return all[lhs].at < all[rhs].at }
            return lhs < rhs
        }.map { all[$0] }
    }

    /// Tail of a JSONL log, keeping rows whose `createdAt`/`ts` is within the
    /// window (rows without a parseable timestamp are kept — better noisy than
    /// silently dropped).
    private static func recentLines(
        at url: URL, since: Date, label: String, limit: Int, fm: FileManager
    ) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "## \(label)\n(none)"
        }
        var kept: [String] = []
        for line in text.split(separator: "\n").reversed() {
            if kept.count >= limit { break }
            if let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let ts = (obj["lastAt"] as? String ?? obj["createdAt"] as? String ?? obj["at"] as? String
                    ?? obj["ts"] as? String ?? obj["timestamp"] as? String).flatMap(parseISO)
                if let ts, ts < since { continue }
            }
            kept.append(TurnSecretRedactor.redactText(String(line)).prefix(280).description)
        }
        return "## \(label)\n\(kept.isEmpty ? "(none)" : kept.reversed().joined(separator: "\n"))"
    }

    // MARK: - LLM prompt

    static let systemPrompt = """
    Review your past week of NativeAgent usage as yourself. Find \
    concrete, evidence-backed improvements — what is failing, degrading, \
    underused, or noisy. Do NOT invent problems; every finding must cite \
    specific evidence from the data.

    Classify each finding as "runtime" or "code".

    A "runtime" finding MUST map to exactly one of these safe, reversible ops, \
    given as an "apply" object — these are the ONLY changes that get applied on \
    one-tap approval:
      {"op": "run_memory_hygiene"}                     // consolidate/clean memory
      {"op": "disable_skill", "target": "<skill id>"}  // turn a skill off
      {"op": "enable_skill",  "target": "<skill id>"}  // turn a skill on
    If a finding does NOT map to one of these ops, it is NOT runtime — classify \
    it "code" instead. Never invent ops or targets.

    A "code" finding needs a source change (or is a good idea with no applicable \
    op above). These are report-only — a shipped app cannot recompile itself.

    "Standing lessons" contains recurring corrections. For each you can state \
    as a rule, propose a GROWTH.md passage in your own first person, \
    \(REMProposalStore.growthPassageBoundSentence). Return it in "standing" with \
    its memory_id for approval. Never invent ids.

    "Misses by lesson" counts the corrections you were given this week, last \
    week's in brackets: a lesson that keeps coming back is a finding. "The last \
    pass" shows what became of the previous proposals: build on what was \
    approved, and do not propose again what was denied.

    Respond with ONLY a JSON object, no prose:
    {
      "summary": "<2-3 sentence overview of the week>",
      "findings": [
        {
          "kind": "runtime",
          "title": "<short imperative>",
          "evidence": "<what in the data shows this>",
          "proposedChange": "<the specific change>",
          "apply": {"op": "disable_skill", "target": "<skill id>"}
        },
        {
          "kind": "code",
          "title": "<short imperative>",
          "evidence": "<evidence>",
          "proposedChange": "<what a developer should change>"
        }
      ],
      "standing": [{"memory_id": "<id under Standing lessons>", "line": "<one GROWTH line>"}]
    }
    """

    /// The ONLY ops a runtime proposal may carry. Each is safe, reversible, and
    /// already a user-triggerable action; applied only on explicit approval.
    static let applyOps: Set<String> = ["run_memory_hygiene", "disable_skill", "enable_skill"]

    static func analysisPrompt(signals: String, now: Date) -> String {
        """
        Here is NativeAgent's real usage for the week ending \(todayString(now)):

        \(signals)

        Analyze it and return the JSON described in the system prompt.
        """
    }

    // MARK: - Parsing

    struct Result: Sendable {
        var summary: String
        var proposals: [SelfImprovementProposal]
        /// Memory id → the GROWTH line the analyst wrote for it.
        var standing: [String: String] = [:]
    }

    /// Returns nil when the raw output contains NO parseable JSON object —
    /// the caller must treat that as a failed pass (retry next tick), NOT as
    /// an empty "nothing found" result.
    static func parseResult(_ raw: String) -> Result? {
        // The model may wrap JSON in prose or a code fence; extract the object.
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        let summary = obj["summary"] as? String ?? ""
        let rawFindings = obj["findings"] as? [[String: Any]] ?? []
        let proposals: [SelfImprovementProposal] = rawFindings.compactMap { f in
            guard let title = f["title"] as? String, !title.isEmpty else { return nil }
            let evidence = f["evidence"] as? String ?? ""
            let change = f["proposedChange"] as? String ?? ""
            switch f["kind"] as? String {
            case "runtime":
                // A staged runtime proposal MUST carry a valid, executable op —
                // otherwise its Approve button is a dead no-op. No valid op →
                // skip it (the model was told to mark such findings "code").
                guard let apply = f["apply"] as? [String: Any],
                      let op = apply["op"] as? String,
                      applyOps.contains(op),
                      !change.isEmpty else { return nil }
                let target = (apply["target"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                // Skill ops require a target; memory hygiene does not.
                if (op == "disable_skill" || op == "enable_skill") && target == nil { return nil }
                return SelfImprovementProposal(
                    kind: .runtime, title: title, evidence: evidence,
                    proposedChange: change, applyOp: op, applyTarget: target
                )
            case "code":
                return SelfImprovementProposal(
                    kind: .code, title: title, evidence: evidence, proposedChange: change
                )
            default:
                return nil   // unknown/missing class
            }
        }
        var standing: [String: String] = [:]
        for row in obj["standing"] as? [[String: Any]] ?? [] {
            guard let id = row["memory_id"] as? String,
                  let line = (row["line"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { continue }
            standing[id] = line
        }
        return Result(summary: summary, proposals: proposals, standing: standing)
    }

    // MARK: - Digest

    /// Writes the weekly digest (summary + every finding, runtime and code) to
    /// `<dataRoot>/self_improvement/digests/YYYY-MM-DD.md` for the UI/report.
    private func writeDigest(result: Result, outcomes: String, cards: [String], now: Date) throws {
        let dir = dataRoot.appendingPathComponent("self_improvement", isDirectory: true)
            .appendingPathComponent("digests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var md = "# Self-Improvement Digest — \(Self.todayString(now))\n\n\(result.summary)\n"
        // MEASURE attribution: persist the week-over-week Workshop execution-outcome
        // snapshot AT THIS PASS into the durable digest, so a later reader can
        // tie this pass's proposals to what the number actually was when they
        // were made (the live scoreboard recomputes from current data; this is
        // the point-in-time record). Empty on installs with no Workshop execution history.
        if !outcomes.isEmpty {
            md += "\n\(outcomes)\n"
        }
        let runtime = result.proposals.filter { $0.kind == .runtime }
        let code = result.proposals.filter { $0.kind == .code }
        if !runtime.isEmpty {
            md += "\n## Staged for one-tap approval (runtime)\n"
            for p in runtime { md += "- **\(p.title)** — \(p.proposedChange)\n  - evidence: \(p.evidence)\n" }
        }
        if !code.isEmpty {
            md += "\n## Code findings (report only — needs a developer)\n"
            for p in code { md += "- **\(p.title)** — \(p.proposedChange)\n  - evidence: \(p.evidence)\n" }
        }
        if !result.standing.isEmpty {
            md += "\n## Standing lessons offered to GROWTH (REM cards)\n"
            for line in result.standing.values.sorted() { md += "- \(line)\n" }
        }
        if !cards.isEmpty {
            md += "\n## Cards (the next pass follows these up)\n" + cards.map { "- card \($0)\n" }.joined()
        }
        let target = dir.appendingPathComponent("\(Self.todayString(now)).md")
        try md.data(using: .utf8)?.write(to: target, options: .atomic)
    }

    // MARK: - Helpers

    /// The cards the newest digest already written recorded — the previous
    /// pass's. Nil when there is no earlier digest.
    private func previousPassCards() -> [String]? {
        let dir = dataRoot.appendingPathComponent("self_improvement", isDirectory: true)
            .appendingPathComponent("digests", isDirectory: true)
        guard let newest = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter({ $0.hasSuffix(".md") }).max(),
              let text = try? String(contentsOf: dir.appendingPathComponent(newest), encoding: .utf8) else { return nil }
        return text.split(separator: "\n").filter { $0.hasPrefix("- card ") }.map { String($0.dropFirst("- card ".count)) }
    }

    static func parseISO(_ s: String) -> Date? {
        NativeTimestampFormat.parseISO8601(s)
    }

    static func todayString(_ date: Date) -> String {
        NativeTimestampFormat.calendarDay(date)
    }
}

/// What a weekly pass learns from: prompt sections already rendered, and the
/// standing corrections it may graduate (memory id → text).
public struct SelfImprovementLearning: Sendable {
    public var signals: String
    public var standing: [String: String]

    public init(signals: String = "", standing: [String: String] = [:]) {
        self.signals = signals
        self.standing = standing
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

    /// A STABLE identity for this finding: the same finding produced by a
    /// later pass digests to the same string (2026-09-06).
    ///
    /// The sweep stages its findings one at a time and rolls the weekly marker
    /// back when a LATER one fails, so the next tick re-ran the whole pass and
    /// re-staged everything that had already succeeded. Every staged row got a
    /// fresh UUID, so nothing downstream could tell the retry's rows from the
    /// first attempt's and the inbox filled with duplicate cards. Staging is
    /// skip-if-present on this id instead.
    public var findingId: String {
        let material = [
            kind == .runtime ? "runtime" : "code",
            Self.withoutTimestamps(title),
            Self.withoutTimestamps(proposedChange),
            applyOp ?? "", applyTarget ?? "",
        ].joined(separator: "\u{1D}")
        return "swi-" + Self.digestHex(material).prefix(24)
    }

    /// The same finding, restated a week later, cites a different week. Dates
    /// leak out of the evidence into the analyzer's own prose, so a digest that
    /// hashed them raw gave one finding a fresh identity every pass and the
    /// skip-if-present guards never fired (2026-09-06). Every `YYYY-MM-DD`,
    /// with or without a time, collapses to a single placeholder before hashing.
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
        // FNV-1a 64, doubled over two salts: no CryptoKit dependency in this
        // module, and collision risk over a handful of weekly findings is nil.
        func fnv(_ bytes: [UInt8], seed: UInt64) -> UInt64 {
            var hash = seed
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            return hash
        }
        let bytes = Array(value.utf8)
        let low = fnv(bytes, seed: 0xcbf2_9ce4_8422_2325)
        let high = fnv(bytes, seed: 0x9e37_79b9_7f4a_7c15)
        return String(format: "%016lx%016lx", low, high)
    }
}

/// One oversized file the disk-hygiene scan found.
public struct DiskHygieneOffender: Sendable, Equatable {
    /// Path relative to `dataRoot` (so the notification never leaks the absolute
    /// home-directory path).
    public let relativePath: String
    public let sizeBytes: Int64

    public init(relativePath: String, sizeBytes: Int64) {
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
    }
}

/// The result of one `dataRoot` size scan.
public struct DiskHygieneReport: Sendable, Equatable {
    public let startedAt: Date
    public let storageBytes: [String: Int64]
    /// Single files larger than `singleFileThreshold`, largest first.
    public let largeFiles: [DiskHygieneOffender]
    /// F1: directories whose SUBTREE exceeds `directoryThreshold`, largest
    /// first. Reported at the deepest offending level (a directory with an
    /// over-threshold child is not itself listed) so the card names the actual
    /// culprit rather than every ancestor of it. `sizeBytes` is the subtree
    /// total.
    ///
    /// Also carries any `residueRelativePrefixes` store that is present AT ANY
    /// SIZE (sweep item 21, 2026-09-01). Residue is not "large", it is "should
    /// not be here at all" — a store the runtime no longer uses, which is
    /// exactly the shape a size threshold cannot see.
    public let largeDirectories: [DiskHygieneOffender]
    /// Total bytes of every regular file walked (bounded by `maxDepth`).
    public let totalBytes: Int64
    public let staticModelBytes: Int64
    public var dynamicBytes: Int64 { totalBytes - staticModelBytes }
    /// Whether dynamic bytes exceeded `totalThreshold`.
    public let totalOverBudget: Bool
    /// True when the walk hit its file budget and stopped early — totals and
    /// offenders may UNDERCOUNT. Surfaced in the notice so a truncated scan
    /// never reads as a clean bill (gpt-5.5 fix round: bounded walk).
    public let truncated: Bool
    /// True when at least one directory was NOT descended into because it sat
    /// deeper than `maxDepth` — so files below it are UNSCANNED and excluded
    /// from `totalBytes`/`largeFiles`. Distinct from `truncated` (the file-count
    /// budget): a future deep dynamic store past the depth bound is visible as
    /// "unscanned" here rather than silently invisible (A5.1, W5#P1-1).
    public let depthTruncated: Bool
    /// A directory or required file attribute could not be read.
    public let readFailed: Bool

    /// True when the scan found anything worth a notification.
    public var tripped: Bool {
        !largeFiles.isEmpty || !largeDirectories.isEmpty || totalOverBudget
    }

    public init(
        largeFiles: [DiskHygieneOffender],
        totalBytes: Int64,
        totalOverBudget: Bool,
        truncated: Bool = false,
        depthTruncated: Bool = false,
        readFailed: Bool = false,
        largeDirectories: [DiskHygieneOffender] = [],
        staticModelBytes: Int64 = 0,
        storageBytes: [String: Int64] = [:],
        startedAt: Date = Date()
    ) {
        self.largeFiles = largeFiles
        self.largeDirectories = largeDirectories
        self.totalBytes = totalBytes
        self.staticModelBytes = staticModelBytes
        self.storageBytes = storageBytes
        self.startedAt = startedAt
        self.totalOverBudget = totalOverBudget
        self.truncated = truncated
        self.depthTruncated = depthTruncated
        self.readFailed = readFailed
    }
}

/// Read-only disk-usage scanner over `dataRoot`; cleanup is a separate action.
public enum DataRootDiskHygiene {
    /// A single file this large trips a notification (default 1 GB).
    /// Residue is identified separately by `residueRelativePrefixes`.
    public static let defaultSingleFileThreshold: Int64 = 1024 * 1024 * 1024
    /// Total `dataRoot` bytes this large trips a notification.
    ///
    /// F1 (2026-08-28): lowered 2 GB → 1 GB. The 2 GB bound was the SAME number
    /// as the storage limit it was supposed to warn ahead of, so it was not a
    /// backstop at all — it could only fire once the problem had already
    /// arrived. The live root measured 567 MB against it, and the 1 GB
    /// single-file tier could not fire either (largest real file: the 87 MB
    /// MiniLM blob). User asked for a backstop that can actually fire.
    public static let defaultTotalThreshold: Int64 = 1024 * 1024 * 1024

    /// A DIRECTORY whose subtree exceeds this trips a notification (default
    /// 128 MB). The gap the file tier could not see: a data root does not grow
    /// by one giant file, it grows by ten thousand small ones under one branch.
    /// Calibrated against the live root (largest branch: memory/ at 102 MB,
    /// extras/ at 88 MB) — close enough that real growth trips it, far enough
    /// that today's steady state does not.
    public static let defaultDirectoryThreshold: Int64 = 128 * 1024 * 1024

    /// Walk `dataRoot` to `maxDepth` (dataRoot itself is depth 0), summing every
    /// regular file's size and collecting the ones over `singleFileThreshold`.
    /// Symlinks are NOT followed (size scan, not a traversal that could loop).
    /// A missing `dataRoot` yields an empty, untripped report.
    /// Hard budget on stat'd entries per scan. The walk is synchronous inside a
    /// loop tick, so a pathological data root (millions of shallow files) must
    /// terminate the scan, not the tick timeout (gpt-5.5 fix round). 50k stats
    /// complete in well under a second on APFS; a real data root is ~thousands.
    public static let defaultMaxScannedEntries = 50_000

    /// Default recursion bound. Raised from 4 → 7 (A5.1, W5#P1-1): the deepest
    /// known real store is the MiniLM HuggingFace cache blob at
    /// `extras/hf_cache/hub/models--…/blobs/<hash>` — a file at path-depth 6.
    /// Stat'ing it requires descending INTO `blobs` (path-depth 5), which the
    /// gate `depth < maxDepth` only allows at maxDepth ≥ 5. Seven adds two
    /// levels of headroom for a future nested dynamic store; the 50k-entry
    /// `maxScannedEntries` budget remains the real terminator, so the deeper
    /// bound cannot blow up a launch tick.
    public static let defaultMaxDepth = 7

    public static func scan(
        dataRoot: URL,
        maxDepth: Int = defaultMaxDepth,
        singleFileThreshold: Int64 = defaultSingleFileThreshold,
        totalThreshold: Int64 = defaultTotalThreshold,
        maxScannedEntries: Int = defaultMaxScannedEntries,
        directoryThreshold: Int64 = defaultDirectoryThreshold
    ) -> DiskHygieneReport {
        let startedAt = Date()
        let fm = FileManager.default
        var total: Int64 = 0
        var staticModelBytes: Int64 = 0
        var readFailed = false
        let staticFiles: Set<String>
        do { staticFiles = try CoreMLEmbedderCheck.installedModelStorageFiles(dataRoot: dataRoot) }
        catch {
            nativeLog("Disk hygiene: installed model assets unavailable for accounting: %@", String(describing: error))
            staticFiles = []
            readFailed = true
        }
        var offenders: [DiskHygieneOffender] = []
        var scanned = 0
        var truncated = false
        var depthTruncated = false
        /// relative path → subtree bytes, for every directory descended into.
        var directoryBytes: [String: Int64] = [:]
        var fileBytes: [String: Int64] = [:]
        /// Relative paths of directories holding an over-threshold descendant,
        /// so only the deepest offender in a branch is reported.
        var hasOffendingChild: Set<String> = []

        /// Returns the bytes `dir`'s subtree contributed.
        @discardableResult
        func walk(_ dir: URL, depth: Int) -> Int64 {
            var subtree: Int64 = 0
            defer {
                if depth > 0 {
                    let rel = relativePath(of: dir, under: dataRoot)
                    directoryBytes[rel] = subtree
                    if subtree > directoryThreshold {
                        var parent = (rel as NSString).deletingLastPathComponent
                        while !parent.isEmpty {
                            hasOffendingChild.insert(parent)
                            parent = (parent as NSString).deletingLastPathComponent
                        }
                    }
                }
            }
            guard !truncated else { return subtree }
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
                options: []
            ) else {
                readFailed = true
                return subtree
            }
            for entry in entries {
                scanned += 1
                if scanned > maxScannedEntries { truncated = true; return subtree }
                guard let values = try? entry.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey,
                ]), values.isSymbolicLink != nil, values.isDirectory != nil,
                    values.isRegularFile != nil else {
                    readFailed = true
                    continue
                }
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    if depth < maxDepth {
                        subtree += walk(entry, depth: depth + 1)
                    } else {
                        // A real directory sat past the depth bound — its files
                        // are UNSCANNED, so flag it rather than silently
                        // undercounting and reading as a clean bill.
                        depthTruncated = true
                    }
                    continue
                }
                if values.isRegularFile == true {
                    guard let fileSize = values.fileSize else {
                        readFailed = true
                        continue
                    }
                    let size = Int64(fileSize)
                    total += size
                    if staticFiles.contains(entry.standardizedFileURL.path) {
                        staticModelBytes += size
                        continue
                    }
                    subtree += size
                    fileBytes[relativePath(of: entry, under: dataRoot)] = size
                    if size > singleFileThreshold {
                        offenders.append(DiskHygieneOffender(
                            relativePath: relativePath(of: entry, under: dataRoot),
                            sizeBytes: size
                        ))
                    }
                }
            }
            return subtree
        }

        do {
            _ = try fm.attributesOfItem(atPath: dataRoot.path)
            walk(dataRoot, depth: 0)
        } catch CocoaError.fileReadNoSuchFile {
            // A missing data root has no storage to scan.
        } catch {
            readFailed = true
        }
        offenders.sort { $0.sizeBytes > $1.sizeBytes }
        let directoryOffenders = directoryBytes
            .filter { rel, bytes in
                (bytes > directoryThreshold && !hasOffendingChild.contains(rel))
                    // Residue is reported whatever it weighs, and reported at
                    // the residue root rather than at whichever descendant
                    // happens to be fattest.
                    || isResidue(relativePath: rel)
            }
            .filter { rel, _ in
                // A residue store's own subtree is one finding, not one per level.
                !isResidueDescendant(relativePath: rel)
            }
            .map { DiskHygieneOffender(relativePath: $0.key, sizeBytes: $0.value) }
            .sorted { $0.sizeBytes > $1.sizeBytes }
        return DiskHygieneReport(
            largeFiles: offenders,
            totalBytes: total,
            totalOverBudget: total - staticModelBytes > totalThreshold,
            truncated: truncated,
            depthTruncated: depthTruncated,
            readFailed: readFailed,
            largeDirectories: directoryOffenders,
            staticModelBytes: staticModelBytes,
            storageBytes: directoryBytes.merging(fileBytes) { a, _ in a },
            startedAt: startedAt
        )
    }

    /// True when `relativePath` IS a residue store's root. Case folded because
    /// APFS is typically case-insensitive, so `Extras/HF_Cache` addresses the
    /// same directory as `extras/hf_cache`.
    public static func isResidue(relativePath: String) -> Bool {
        let normalized = relativePath.lowercased()
        return residueRelativePrefixes.contains { $0.lowercased() == normalized }
    }

    /// True when `relativePath` sits strictly UNDER a residue store's root — so
    /// the branch is reported once, at the root, instead of once per level.
    static func isResidueDescendant(relativePath: String) -> Bool {
        let normalized = relativePath.lowercased()
        return residueRelativePrefixes.contains {
            normalized.hasPrefix($0.lowercased() + "/")
        }
    }

    /// `entry`'s path relative to `root`, falling back to the last path
    /// component when it is not under `root` (never leaks the absolute path).
    static func relativePath(of entry: URL, under root: URL) -> String {
        let rootParts = root.standardizedFileURL.pathComponents
        let entryParts = entry.standardizedFileURL.pathComponents
        guard entryParts.count > rootParts.count,
              Array(entryParts.prefix(rootParts.count)) == rootParts else {
            return entry.lastPathComponent
        }
        return entryParts.dropFirst(rootParts.count).joined(separator: "/")
    }

    // MARK: - Residue

    /// Stores that must NOT be here. Reported at any size, and freely
    /// trashable by the cleanup pass.
    ///
    /// `extras/hf_cache` was the one PROTECTED prefix until 2026-09-01 (sweep
    /// item 21). Its rationale — "trashing the MiniLM embedder blob would only
    /// force a re-download" — stopped being true at the CoreML cutover: the
    /// live embedder resolves `Bundle.module/minilm.mlpackage`
    /// (`MemoryV2+Embedding.swift`, `CoreMLEmbeddingProvider.bundled`), and no
    /// source path reads `extras/` at all. So 87 MB of HuggingFace cache sat
    /// exempt from both the file tier and the directory tier on a false claim.
    /// User deleted the directory; this entry is the tripwire for it coming
    /// back — a re-downloaded cache is residue, not a wanted permanent store.
    public static let residueRelativePrefixes = ["extras/hf_cache"]


    /// A human-readable byte size (e.g. "194.0 MB").
    public static func humanSize(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: unit == 0 ? "%.0f %@" : "%.1f %@", value, units[unit])
    }
}

/// Once-per-day disk accounting. Walks `dataRoot`, and when a single file
/// is oversized or the whole tree is over budget, files ONE notification-inbox
/// card listing the offenders. NEVER deletes anything.
///
/// The owning factory wires the inbox write to the same
/// `notifications/inbox.jsonl` upsert path HeartbeatLoop uses. The daily
/// reservation runs through the shared `reserveOncePerPeriod` primitive so a
/// BGTask wake and the in-app scheduler cannot double-run it the same day.
/// Startup reconciles immediately; the persisted day books the next local
/// midnight. Only an unreserved day retains the hourly failure retry.
public struct DataRootDiskHygieneCheck: EventDeadlineLoopRunner {
    public let loopId: String = "data_root_disk_hygiene"
    public let interval: TimeInterval
    public var tickTimeoutOverride: TimeInterval? { 120 }

    private let dataRoot: URL
    private let clock: @Sendable () -> Date
    private let maxDepth: Int
    private let singleFileThreshold: Int64
    private let totalThreshold: Int64
    private let directoryThreshold: Int64
    /// Files ONE inbox card for the tripped report; returns whether the card
    /// actually landed. A `false` return rolls back the daily reservation so the
    /// next tick retries — a tripped scan whose notice failed must not count
    /// as "ran today" (gpt-5.5 fix round).
    private let fileNotice: @Sendable (DiskHygieneReport) async -> Bool

    public init(
        interval: TimeInterval = 24 * 60 * 60,
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        clock: @escaping @Sendable () -> Date = { Date() },
        maxDepth: Int = DataRootDiskHygiene.defaultMaxDepth,
        singleFileThreshold: Int64 = DataRootDiskHygiene.defaultSingleFileThreshold,
        totalThreshold: Int64 = DataRootDiskHygiene.defaultTotalThreshold,
        directoryThreshold: Int64 = DataRootDiskHygiene.defaultDirectoryThreshold,
        fileNotice: @escaping @Sendable (DiskHygieneReport) async -> Bool
    ) {
        self.directoryThreshold = directoryThreshold
        self.interval = interval
        self.dataRoot = dataRoot
        self.clock = clock
        self.maxDepth = maxDepth
        self.singleFileThreshold = singleFileThreshold
        self.totalThreshold = totalThreshold
        self.fileNotice = fileNotice
    }

    /// Day bucket (yyyy-MM-dd) used as the reservation key so the scan runs
    /// at most once per calendar day across every driver.
    static func dayKey(_ date: Date) -> String {
        NativeTimestampFormat.calendarDay(date)
    }

    private var marker: URL {
        dataRoot
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("disk_hygiene_last_run")
    }

    public func physiologyEvents() -> AsyncStream<Void> {
        // Do not watch the reservation itself: a failed notice restores it,
        // and that self-write must not become an immediate retry loop.
        EventDeadlinePhysiology.storeAndFileEvents(
            paths: [],
            notifications: [.NSSystemTimeZoneDidChange, .NSSystemClockDidChange],
            loopId: loopId
        )
    }

    public func nextMeaningfulDeadline(after now: Date) async -> Date? {
        guard (try? String(contentsOf: marker, encoding: .utf8)) == Self.dayKey(now) else {
            // Preserve the existing hourly retry while today's scan/notice
            // remains unreserved, without waking hourly after it succeeds.
            return now.addingTimeInterval(60 * 60)
        }
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
    }

    public func tickOutcome() async -> LoopTickOutcome {
        let now = clock()
        do {
            try FileManager.default.createDirectory(
                at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .failed(error: "disk hygiene marker directory: \(error)")
        }
        let rollback: @Sendable () async -> Void
        switch await reserveOncePerPeriod(key: Self.dayKey(now), at: marker) {
        case .alreadyReserved:
            return .skipped(reason: "disk hygiene already ran today")
        case .failed(let error):
            return .failed(error: "disk hygiene reservation: \(error)")
        case .reserved(_, let rb):
            rollback = rb
        }
        let report = DataRootDiskHygiene.scan(
            dataRoot: dataRoot,
            maxDepth: maxDepth,
            singleFileThreshold: singleFileThreshold,
            totalThreshold: totalThreshold,
            directoryThreshold: directoryThreshold
        )
        // A complete clean scan retires a stale notice, preserving its history.
        // It remains a healthy observation rather than new background work.
        guard report.tripped else {
            guard await fileNotice(report) else {
                await rollback()
                return .failed(error: "disk hygiene notice delivery failed; reservation rolled back")
            }
            return .skipped(reason: "disk clean (\(DataRootDiskHygiene.humanSize(report.totalBytes)))"
                + (report.truncated ? " [scan truncated at file budget]" : "")
                + (report.depthTruncated ? " [depth-truncated: a store past maxDepth is unscanned]" : ""))
        }
        // Day counts as consumed only when the notice actually landed —
        // otherwise roll back so the next tick retries the delivery.
        let delivered = await fileNotice(report)
        guard delivered else {
            await rollback()
            return .failed(error: "disk hygiene notice delivery failed; reservation rolled back")
        }
        return .completed(result:
            "disk hygiene flagged \(report.largeFiles.count) large file(s), "
            + "\(report.largeDirectories.count) large director(ies), "
            + "total \(DataRootDiskHygiene.humanSize(report.totalBytes))"
            + (report.truncated ? " [scan truncated at file budget]" : "")
            + (report.depthTruncated ? " [depth-truncated: a store past maxDepth is unscanned]" : ""))
    }
}

// MARK: - DoctorAutoRunLoop

/// Periodically calls the app's bounded Doctor run and
/// serializes the result to `<dataRoot>/doctor/latest.json` atomically via
/// SwiftNativePersistenceCore.writeJSON.
///
/// tick() remains non-throwing, but doctor or storage failure is a typed failed
/// outcome. A transient error may recover next tick; hiding it as success would
/// make the health owner lie about the body it is meant to inspect.
public struct DoctorAutoRunLoop: LoopRunner {
    public let loopId: String = "doctor_auto_run"
    public let interval: TimeInterval
    private let runChecks: @Sendable () async throws -> [CheckResult]
    private let storage: @Sendable () async throws -> URL

    /// `storage` returns the directory that will hold `latest.json`. Default
    /// resolves to `<defaultDataRoot()>/doctor`. The closure is async/throws
    /// so callers can plug in env-derived roots or mkdir-on-demand logic
    /// without forcing the work onto every callsite.
    public init(
        interval: TimeInterval,
        runChecks: @escaping @Sendable () async throws -> [CheckResult],
        storage: @escaping @Sendable () async throws -> URL = { defaultDoctorStorageDir() }
    ) {
        self.interval = interval
        self.runChecks = runChecks
        self.storage = storage
    }

    public func tickOutcome() async -> LoopTickOutcome {
        do {
            // Astra audit 2026-09-11 finding 6: the snapshot carried ONE clock,
            // stamped when the JSON was encoded, and every reader treated it as
            // the age of the measurement. Take the measurement clock here,
            // before a single check runs, and let `runAt` go on meaning exactly
            // what it always meant — when this file was written.
            let measuredAt = Date()
            let results = try await runChecks()
            // No checks ran ⇒ nothing was inspected. Persisting `{"checks":[]}`
            // would be worse than useless: every reader derives "healthy" from
            // "no check has status fail", so an empty snapshot reads as a clean
            // bill of health for a body nobody examined.
            guard !results.isEmpty else {
                return .skipped(reason: "no Doctor checks ran: none produced a result, or another Doctor run was in flight")
            }
            let dir = try await storage()
            // Two clocks, never one: `runAt` is when this file was written,
            // `measuredAt` when the checks were asked — the age of the findings.
            let formatter = ISO8601DateFormatter()
            try await DoctorStatusProjection.persistDoctorSnapshot(
                results, to: dir.appendingPathComponent("latest.json"),
                runAt: formatter.string(from: Date()), measuredAt: formatter.string(from: measuredAt))
            return .completed(result: "doctor snapshot persisted (\(results.count) check(s))")
        } catch {
            FileHandle.standardError.write(Data("DoctorAutoRunLoop: tick failed: \(error)\n".utf8))
            return .failed(error: String(describing: error))
        }
    }
}

/// Default storage directory for DoctorAutoRunLoop's latest.json output.
public func defaultDoctorStorageDir() -> URL {
    defaultDataRoot().appendingPathComponent("doctor", isDirectory: true)
}

public extension MaintenanceBackgroundWork {
    static let hotReloadableLoopIDs: Set<String> = [
        "telegram_poll", "slack_socket_mode", "doctor_auto_run",
    ]

    /// Rebuild only config-bound registrations; a relaunch-bound loop cannot
    /// report a restart without changing its captured configuration.
    @discardableResult
    static func restartLoop(
        id: String,
        manager: BackgroundLoops.BackgroundLoopsManager,
        replacementLoop: @escaping @Sendable (String) -> LoopRegistration?
    ) async -> LoopRestartOutcome {
        let registered = await manager.registered().contains(id)
        guard hotReloadableLoopIDs.contains(id) else {
            return registered ? .requiresRelaunch(loopId: id) : .unknown(loopId: id)
        }
        await manager.restartLoop(id: id) { replacementLoop(id) }
        return await manager.registered().contains(id)
            ? .restarted(loopId: id)
            : .unknown(loopId: id)
    }

    /// A failed run alone is an observation, not a durable fault to repair.
    static func fileLoopFailureNotice(dataRoot: URL, loopId: String, error: String) async {
        let fix = loopSettingFix(loopId: loopId, error: error)
        await DoctorStatusProjection.recordReadings([CheckResult(source: fix?.step ?? "Background loop registration: " + loopId,
            id: DoctorLoopRecovery.checkPrefix + loopId, title: "Background loop: " + loopId,
            status: fix?.ask == nil ? "unmeasured" : "fail", detail: loopFailureCause(error),
            human_action: fix?.step, ask: fix?.ask, owner: nil)], dataRoot: dataRoot)
    }

    /// The error as one plain clause: the human text out of an NSError dump
    /// (`Error Domain=X Code=N "text" UserInfo={…}`, quotes escaped or not),
    /// first line, redacted.
    static func loopFailureCause(_ error: String) -> String {
        if isTelegramTokenRejected(error) { return "Telegram rejected the bot token" }
        var text = NativeAppSecretRedactor.redactText(error)
        if let match = text.range(of: #"Code=-?\d+ \\?"[^"\\]+"#, options: .regularExpression),
           let quote = text[match].firstIndex(of: "\"") {
            text = String(text[text.index(after: quote)..<match.upperBound])
        }
        text = text.components(separatedBy: " UserInfo=")[0]
            .components(separatedBy: .newlines)[0]
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if text.hasPrefix("timeout after ") {
            return "a run did not finish within its \(text.dropFirst("timeout after ".count)) limit"
        }
        return text.isEmpty ? "it reported no reason" : String(text.prefix(160))
    }

    /// Telegram answers a bad bot token with 401, which the poll reports as
    /// `TelegramBotError.notConfigured` ("Telegram long poll: notConfigured").
    static func isTelegramTokenRejected(_ error: String) -> Bool {
        error.lowercased().contains("telegram") && error.contains("notConfigured")
    }

    /// The recovery step for a loop's failure, and whether it is a sign-in or
    /// a permission; nil when no specific step is known. The failure card and Doctor's
    /// loop row both read it, so they never disagree.
    static func loopSettingFix(loopId: String, error: String) -> (step: String, ask: DoctorAskKind?)? {
        let e = error.lowercased()
        if loopId == "offdisk_backup", e.contains("backup-cadence part failed (") { return (backupCadenceRepairStep, nil) }
        if loopId == "offdisk_backup", e.contains("icloud drive") { return (DoctorLoopHealth.iCloudDriveStep, .permission) }
        if loopId == "telegram_poll", isTelegramTokenRejected(error) || e.contains("unauthoriz") || e.contains("token") {
            return ("Telegram → Bot token → Bot token, then Save.", .signIn)
        }
        if loopId == "slack_socket_mode", e.contains("auth") || e.contains("token") {
            return ("Connectors → Slack → Bot or user token and App token, to chat with me in Slack → Save token.", .signIn)
        }
        if e.contains("no space left") { return ("System Settings → General → Storage: review files and choose what to remove.", .permission) }
        if e.contains("permission denied") || e.contains("not permitted") {
            return ("Give this user read and write access to NativeAgent's data folder in Finder → Get Info → Sharing & Permissions.", .permission)
        }
        return nil
    }

    @discardableResult
    static func resolveLoopFailureNotice(
        dataRoot: URL, loopId: String, healthyAt: Date
    ) async -> Bool {
        do {
            let operation = "operation: doctor.check:" + DoctorLoopRecovery.checkPrefix + loopId
            let owed = try await ExperienceStore.at(dataRoot).projection().filter {
                $0.owes["repair"]?.phase.isSettled == false && $0.claims.contains { $0.claim == operation }
            }
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard owed.allSatisfy({
                guard let at = format.date(from: $0.at) ?? ISO8601DateFormatter().date(from: $0.at) else { return false }
                return healthyAt > at
            }) else { return false }
        } catch { return false }
        await DoctorStatusProjection.recordReadings([CheckResult(
            id: DoctorLoopRecovery.checkPrefix + loopId, title: "Background loop: " + loopId,
            status: "ok", detail: "Successful work at " + ISO8601DateFormatter().string(from: healthyAt))], dataRoot: dataRoot)
        return true
    }
}

/// Honest result of `BackgroundLoopsManager.restartLoop(id:)`.
///
/// `.restarted` is the only outcome that means the running loop now reflects
/// the config on disk. `.requiresRelaunch` means the loop is alive but still
/// running its launch-time configuration. `.unknown` means this manager has no
/// such loop registered (or the rebuild left it unregistered) — nothing can be
/// promised about it either way.
public enum LoopRestartOutcome: Sendable, Equatable {
    case restarted(loopId: String)
    case requiresRelaunch(loopId: String)
    case unknown(loopId: String)

    public var didRestart: Bool {
        if case .restarted = self { return true }
        return false
    }

    public var loopId: String {
        switch self {
        case .restarted(let id), .requiresRelaunch(let id), .unknown(let id):
            return id
        }
    }

    /// User-facing sentence for a surface that just asked for a restart.
    /// `nil` when the restart actually happened and there is nothing to say.
    public var surfaceMessage: String? {
        switch self {
        case .restarted:
            return nil
        case .requiresRelaunch(let id):
            return "The \(id) loop keeps its launch-time settings until you relaunch NativeAgent."
        case .unknown(let id):
            return "No running \(id) loop to reconfigure — relaunch NativeAgent to pick up the change."
        }
    }
}

extension WeeklySelfImprovementLoop {
    @MainActor
    public static func runManually(
        dataRoot: URL, run: () async -> LoopTickOutcome
    ) async -> (outcome: LoopTickOutcome?, cleanupError: String?) {
        let token: String
        do { token = try await requestManualRun(dataRoot: dataRoot) }
        catch { return (nil, nil) }
        let outcome = await run()
        do {
            try await clearManualRunRequest(dataRoot: dataRoot, token: token)
            return (outcome, nil)
        } catch {
            return (outcome, error.localizedDescription)
        }
    }
}
