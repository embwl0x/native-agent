import Foundation
import NativeAgentShared
import NativeAgentCore
import BackgroundLoops
import CognitiveSubstrate
import MemoryV2
import PersistenceCore
import DreamREMCycle
import ApprovalInbox
import Cognition
import TrustCenter
import Experiences
import AgentWorkspace
import Transcripts
import TurnTrace
// Blueprint: | `DreamBackgroundWork.swift` | Dream and REM settlement; care and growth approvals tell their one ForPerson face |

/// The app's notification delivery, after the Core-owned REM card is durable.
public typealias REMProposalNotificationPort = BackgroundWorkNotificationPort

// MARK: - Dreams and Memory Loops

public enum DreamBackgroundWork {
    /// The nightly job, its launch catch-up and mind.dream all run here, so the dream beats here once per run: worked with the lessons it saved, so a
    /// night that saved none breaks its record.
    public static func runDream(
        dataRoot: URL,
        cycle: SwiftNativeDreamREMCycle,
        cognitionRuntime: NativeCognitionRuntime,
        force: Bool,
        trigger: DreamTrigger,
        notifications: any REMProposalNotificationPort
    ) async throws -> DreamReport {
        let asked = trigger == .manual ? "asked: " : ""
        let report: DreamReport
        do {
            report = try await dream(dataRoot: dataRoot, cycle: cycle, cognitionRuntime: cognitionRuntime, force: force,
                                     trigger: trigger, notifications: notifications)
        } catch {
            beatThrown(dreamOrgan, error, note: asked, cadence: dreamCadence)
            throw error
        }
        if !report.errors.isEmpty {
            OrganJudge.beat(dreamOrgan, .failed, note: asked + report.errors.joined(separator: "; "), cadence: dreamCadence)
        } else if report.entriesWritten > 0 || report.effectsSettled > 0 {
            OrganJudge.beat(dreamOrgan, .worked, note: asked + "wrote \(report.entriesWritten) diary entries, saved \(report.lessonsSaved) lessons",
                            yield: report.lessonsSaved, cadence: dreamCadence)
        } else if report.skipReason != alreadyRunning {
            // Another run holding the reservation beats its own decision.
            OrganJudge.beat(dreamOrgan, .nothing, note: asked + (report.skipReason ?? "no new entries"), cadence: dreamCadence)
        }
        return report
    }

    /// A disabled cycle is off, a run cut short by Stop stopped; any other thrown run failed.
    private static func beatThrown(_ organ: String, _ error: Error, note prefix: String = "", cadence: TimeInterval) {
        if case DreamREMCycleError.cycleDisabled = error {
            OrganJudge.beatOff(organ, because: "the dream cycle is disabled")
        } else if error is CancellationError {
            OrganJudge.beat(organ, .stopped, note: prefix + "stopped before it finished", cadence: cadence)
        } else {
            OrganJudge.beat(organ, .failed, note: prefix + error.localizedDescription, cadence: cadence)
        }
    }

    static let dreamOrgan = "dream"
    /// The nightly job's interval; a dream silent past two nights is missed.
    static let dreamCadence: TimeInterval = 24 * 60 * 60
    static let remCadence: TimeInterval = 7 * 24 * 60 * 60
    /// DreamCycleRunner's and REMConsolidator's skip while another run holds the reservation.
    static let alreadyRunning = "already_running"

    private static func dream(
        dataRoot: URL,
        cycle: SwiftNativeDreamREMCycle,
        cognitionRuntime: NativeCognitionRuntime,
        force: Bool,
        trigger: DreamTrigger,
        notifications: any REMProposalNotificationPort
    ) async throws -> DreamReport {
        // Live owed moments, including deferrals, before the dream reads the day.
        await AdaptiveMemoryPromoter.shared.drainOwedAtNight(dataRoot: dataRoot)
        return try await cycle.runDream(force: force, trigger: trigger) { delivery in
            switch delivery.effect {
            case .reflectionJudgment(let material):
                switch try await cognitionRuntime.produceDreamReflection(id: delivery.id, material: material) {
                case .judged(let receipt): return .reflection(receipt)
                case .skipped(let reason): return .skipped(reason)
                }
            case .reflectionIntegration(let receipt):
                do {
                    if let reason = try await cognitionRuntime.integrateDreamReflection(receipt) { return .skipped(reason) }
                } catch let error as CognitiveWriteDiscarded {
                    if let epoch = receipt.integrationEpoch,
                       await cognitionRuntime.substrateForIntegration().forgettingEpochs().mind != epoch {
                        return .skipped("mind cleared after this reflection")
                    }
                    throw error
                }
                return .done
            case .reflectionAcknowledgment(let id):
                try await cognitionRuntime.substrateForIntegration().acknowledgeDreamReflection(id)
                return .done
            case .care(let night):
                if !(await cognitionRuntime.substrateForIntegration().configurationSnapshot().enabled) {
                    OrganJudge.beatOff("care_night", because: "inner life is off")
                    return .skipped("inner life off")
                }
                do {
                    try await passCaresNight(night, dataRoot: dataRoot, cognitionRuntime: cognitionRuntime,
                        notifications: notifications)
                } catch let error as CognitiveWriteDiscarded {
                    if let epoch = night.mindEpoch,
                       await cognitionRuntime.substrateForIntegration().forgettingEpochs().mind != epoch {
                        OrganJudge.beat("care_night", .held, note: "the mind was cleared after this care reading")
                        return .skipped("mind cleared after this care reading")
                    }
                    OrganJudge.beat("care_night", .failed, note: error.localizedDescription)
                    throw error
                } catch {
                    OrganJudge.beat("care_night", .failed, note: error.localizedDescription)
                    throw error
                }
                OrganJudge.beat("care_night", .worked, note: "judged the night's cares")
                return .done
            case .completion(let occurredAt, let feltSummary):
                var metadata: [String: JSONValue] = [
                    "entriesWritten": .int(1), "sessionsProcessed": .int(Int64(delivery.sessionsProcessed)),
                    "force": .bool(delivery.force), "trigger": .string(delivery.trigger.rawValue),
                ]
                if let feltSummary { metadata["feltDaySummary"] = .string(feltSummary) }
                let applied = try await cognitionRuntime.completeDreamSignal(id: delivery.id,
                    occurredAt: occurredAt, metadata: metadata)
                return applied ? .done : .skipped("body disabled")
            }
        }
    }

    /// Apply approved life depth before the substrate pass; offer each newly eligible care only once.
    static func passCaresNight(
        _ night: CognitiveCareNight, dataRoot: URL, cognitionRuntime: NativeCognitionRuntime,
        notifications: any REMProposalNotificationPort
    ) async throws {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let action = CognitiveSubstrate.careLifeApprovalAction
        let inventory: Result<[ApprovalRecord], Error>
        do { inventory = .success(try await inbox.list(filter: ApprovalFilter(action: action))) }
        catch { inventory = .failure(error) }
        var failures: [String] = []
        if case .success(let cards) = inventory {
            for card in cards where card.decision == "approved" && card.executedAction == nil {
                await cognitionRuntime.applyCareLifeApproval(card)
            }
        }
        let ready = try await cognitionRuntime.substrateForIntegration().passCaresNight(night)
        await cognitionRuntime.publishRuntimeChange(reason: "cares.night")
        // An unreadable approval inventory cannot authorize new cards, but it
        // does not withhold the independent care judgments already returned.
        let cards = try inventory.get()
        let offered = Set(cards.compactMap(NativeCognitionRuntime.careLifeCardCareID))
        for care in ready where !offered.contains(care.id) {
            let words = "\(care.about) has become part of who I am"
            do {
                _ = try await inbox.create(.object([
                    "title": .string("Part of who I am"),
                    "action": .string(action),
                    "risk": .string("low"),
                    "reason": .string(""),
                    "payload": .object(["kind": .string(action), "careId": .string(care.id.uuidString),
                                        "about": .string(care.about)]),
                    "payloadPreview": .string(words),
                ]), turn: nil)
            } catch {
                failures.append("life card for \(care.id) not staged: \(error)")
            }
        }
        if !failures.isEmpty { throw PersistenceCoreError.ioFailure(failures.joined(separator: "; ")) }
    }

    /// The weekly job and mind.rem run here, so REM beats here once per run, worked with the proposals it generated.
    public static func runREM(
        dataRoot: URL,
        cycle: SwiftNativeDreamREMCycle,
        cognitionRuntime: NativeCognitionRuntime,
        force: Bool
    ) async throws -> REMReport {
        let report: REMReport
        do { report = try await rem(dataRoot: dataRoot, cycle: cycle, cognitionRuntime: cognitionRuntime, force: force) }
        catch {
            beatThrown("rem", error, cadence: remCadence)
            throw error
        }
        if let skip = report.skipReason {
            if skip != alreadyRunning { OrganJudge.beat("rem", .held, note: skip, cadence: remCadence) }
        } else {
            OrganJudge.beat("rem", .worked, note: "\(report.proposalsGenerated) proposals, \(report.archivedEntries) entries archived",
                            yield: report.proposalsGenerated, cadence: remCadence)
        }
        return report
    }

    private static func rem(
        dataRoot: URL,
        cycle: SwiftNativeDreamREMCycle,
        cognitionRuntime: NativeCognitionRuntime,
        force: Bool
    ) async throws -> REMReport {
        let result: REMReport
        do { result = try await cycle.runREM(force: force) }
        catch {
            if case DreamREMCycleError.remDecodeFailure(let detail) = error {
                do {
                    try await HarnessQueue.file(HarnessFinding(key: "loop-failure:nativeagent-weekly-rem",
                        title: "REM could not read its model's reply", summary: detail,
                        owner: .agent, refs: [], source: .loop), dataRoot: dataRoot)
                } catch { nativeLog("REM decode finding could not be filed: %@", error.localizedDescription) }
            }
            throw error
        }
        guard result.skipReason == nil else { return result }
        try await HarnessQueue.resolve(key: "loop-failure:nativeagent-weekly-rem",
            note: "REM decoded its next run.", dataRoot: dataRoot)
        let proposals = result.proposalsGenerated
        let archived = result.archivedEntries
        await cognitionRuntime.ingestOrganismSignal(
            kind: .remIntegrated,
            sourceOrgan: "rem",
            intensity: proposals > 0 ? 0.58 : 0.22,
            valence: 0.28,
            arousal: 0.14,
            metadata: [
                "proposalsGenerated": .int(Int64(proposals)),
                "archivedEntries": .int(Int64(archived)),
                "force": .bool(force),
                "feltDaySummary": .string("REM integrated \(proposals) proposal(s) from recent dream evidence."),
            ],
            reflectionMaterial: result.reflectionMaterial
        )
        if let gaps = result.unavailableDreamSections, !gaps.isEmpty {
            throw PersistenceCoreError.ioFailure("REM left unavailable dream sections pending: " + gaps.joined(separator: "; "))
        }
        return result
    }

    // The weekly scheduler owns REM and stages proposals through makeREMProposalStager.

    /// Share the weekly stager for canonical pending REM rows; catch-up must not generate another batch.
    /// Stamp approval identity to dedupe retries and keep ApprovalInbox outside the REM module.
    /// Bound launch catch-up so an accumulated backlog cannot flood the inbox; remaining rows wait for launch or weekly work.
    public static let remStagingCatchUpLimit = 10

    @discardableResult
    public static func stagePendingREMProposalsAtLaunch(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        limit: Int = remStagingCatchUpLimit,
        stager: REMApprovalStager? = nil,
        notifications: any REMProposalNotificationPort
    ) async -> Int {
        guard limit > 0 else { return 0 }
        let store = REMProposalStore(dataRoot: dataRoot)
        let inner = stager ?? makeREMProposalStager(dataRoot: dataRoot, notifications: notifications)
        do {
            return try await store.stagePendingApprovals(inner, limit: limit)
        } catch {
            nativeLog("REM approval staging remains owed: %@", error.localizedDescription)
            return 0
        }
    }

    public static func makeREMProposalStager(dataRoot: URL, notifications: any REMProposalNotificationPort) -> REMApprovalStager {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let securityCenter = SwiftNativeSecurityCenter(dataRoot: dataRoot)
        return { row, experiences in
            let yolo = await securityCenter.fullMacYoloAuthority(
                origin: SecurityOriginContext(
                    surface: "desk",
                    source: "rem_proposal_stager",
                    isRemote: false
                ),
                turn: nil
            )
            // Only an explicit block refuses staging; staging does not apply the proposal.
            if yolo.state == .explicitlyBlocked {
                return nil
            }
            // Reuse pending approvals after a crash; dedupe read failures leave staging owed.
            let pendingREM = try await inbox.list(
                filter: ApprovalFilter(status: "pending", action: "rem.proposal"))
            if let existing = pendingREM.first(where: { rec in
                guard case .object(let p) = rec.payload,
                      case .object(let proposal)? = p["proposal"],
                      case .string(let pid)? = proposal["id"] else { return false }
                return pid == row.id
            }) {
                return existing.id
            }
            let cardTitle = "REM growth lesson"
            let body: JSONValue = .object([
                "title": .string(cardTitle),
                "action": .string("rem.proposal"),
                "risk": .string("medium"),
                // An empty reason hides boilerplate so the preview carries the agent's words verbatim.
                "reason": .string(""),
                "payload": .object([
                    "kind": .string("rem.proposal"),
                    "proposal": .object([
                        "id": .string(row.id),
                        "targetDoc": .string(row.targetDoc),
                        "proposalText": .string(row.proposalText),
                        "evidenceDates": .array(row.evidenceDates.map { .string($0) }),
                        "confidence": .double(row.confidence),
                        "createdAt": .string(row.createdAt),
                        "replaced": try row.replaced.map { try JSONValue.parse(JSONEncoder().encode($0)) } ?? .null,
                        // Preserve support evidence so repeated reflection stays distinct from recurrence.
                        "support": row.support.map { .string($0.rawValue) } ?? .null,
                        "livedDates": .array((row.livedDates ?? []).map { .string($0) }),
                        "supportingPassages": .array((row.supportingPassages ?? []).map {
                            .object([
                                "dreamDate": .string($0.dreamDate),
                                "quote": .string($0.quote),
                                "livedDates": .array($0.livedDates.map { .string($0) }),
                                "sourceRefs": .array($0.sourceRefs.map { .string($0) }),
                            ])
                        }),
                    ]),
                ]),
                // ApprovalRecord owns displacement rendering from the payload.
                "payloadPreview": .string(remProposalPreview(row, experiences: experiences, includeReplacement: false)),
            ])
            // The approval is the one matter the person sees; its owner draws its face.
            return try await inbox.create(body, turn: nil).id
        }
    }

    /// Distinguish repeated reflection from recurrence across nights; missing support earns no guessed label.
    public static func remSupportLabel(_ row: REMProposalRow, experiences: Int?) -> String? {
        guard row.support != .standing, row.support != nil else { return nil }
        guard let experiences else {
            return "provenance unavailable · whether it recurred is not known"
        }
        let dreams = max(row.evidenceDates.count, row.supportingPassages?.count ?? 0)
        func support(_ n: Int) -> String { "\(n) experience" + (n == 1 ? "" : "s") }
        switch row.support {
        case .recurring:
            return "recurring · " + support(experiences)
        case .dweltOn:
            return "dwelt on · \(dreams) dream" + (dreams == 1 ? "" : "s")
                + ", " + support(experiences)
        case .provenanceUnavailable:
            return "provenance unavailable · whether it recurred is not known"
        case .standing, nil:
            return nil
        }
    }

    /// Keep support beside proposal wording so every REM surface carries the same provenance.
    public static func remProposalPreview(_ row: REMProposalRow, experiences: Int?, includeReplacement: Bool = true) -> String {
        let lesson: String
        // Standing corrections move into GROWTH and must identify themselves before quoting the line.
        if row.support == .standing {
            lesson = "Standing lesson, recalled in nearly every conversation. Approve to keep it in GROWTH "
                + "and retire the memory:\n“\(row.proposalText)”"
        } else if let label = remSupportLabel(row, experiences: experiences) {
            lesson = row.proposalText + "\n" + label
        } else {
            lesson = row.proposalText
        }
        return includeReplacement ? lesson + "\n\n" + REMReplacement.describe(row.replaced) : lesson
    }

    /// The scheduled assembly needs the same self-memory provider; otherwise its dream omits that half.
    /// DreamCycleRunner owns count and character budgets.
    public static func makeDreamMemoryDeltaProvider(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) -> DreamMemoryDeltaProvider {
        let memory = SwiftNativeMemoryV2.resolvedOwner(
            dataRoot: dataRoot,
            alternateRootEmbedder: MockEmbeddingProvider()
        )
        return { @Sendable cutoff in
            // Feedback shares the runner’s timestamp parsing and volume bounds.

            let records = try await memory.listMemory(kind: nil)
            let sorted = records.sorted { $0.createdAt > $1.createdAt }

            var tagged: [String] = []
            var general: [String] = []
            for rec in sorted {
                let text = rec.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                // Only absorption after the dream’s high-water mark is new material.
                if let parsed = ConversationHistory.parseTimestamp(.string(rec.createdAt)),
                   parsed < cutoff {
                    continue
                }
                // Only what recall could speak: active, recall-eligible, admitted.
                guard rec.status == "active", MemoryLifecycle.isRecallEligible(rec.lifecycle),
                      !MemoryStorage.metadataFlag(rec.extras, MemoryStorage.pendingAdmissionKey)
                else { continue }
                let tags = rec.tags ?? []
                let layer = (rec.layer ?? "").lowercased()
                let line = "\(rec.createdAt) — \(text)"
                if tags.contains("persona-feedback")
                    || layer == "persona_feedback"
                    || layer == "persona-feedback" {
                    tagged.append(line)
                } else {
                    general.append(line)
                }
            }
            return tagged.isEmpty ? general : tagged
        }
    }

    /// Read felt tone without mutation or persistence and reuse it in both scheduled and direct dreams.
    /// The substrate owns affect gating; no felt material omits the section without another model call.
    public static func makeDreamFeltSummaryProvider(
        cognitionRuntime: NativeCognitionRuntime
    ) -> DreamFeltSummaryProvider {
        let runtime = cognitionRuntime
        return { @Sendable in
            let substrate = await runtime.substrateForIntegration()
            return await substrate.feltDaySummary(at: Date())
        }
    }

    /// Read origins from the same felt population so the dream can cite what it felt.
    /// No journal-derived feeling means cite nothing; the dream still proceeds.
    /// Scheduled and direct runners must share this provider.
    public static func makeDreamFeltOriginProvider(
        cognitionRuntime: NativeCognitionRuntime
    ) -> DreamFeltOriginProvider {
        let runtime = cognitionRuntime
        return { @Sendable in
            let substrate = await runtime.substrateForIntegration()
            return await substrate.feltDayOrigins(at: Date())
        }
    }

    public static func makeDreamCareNightProvider(
        cognitionRuntime: NativeCognitionRuntime
    ) -> DreamCareNightProvider {
        let runtime = cognitionRuntime
        return { @Sendable in
            try await runtime.substrateForIntegration().careNightMaterial()
        }
    }

    /// The cycle has no substrate reference; pass receipts to its owner here.
    /// Commit the ledger before tracing so unavailable persistence leaves journal citations owed.
    public static func makeDreamReceiptSink(
        cognitionRuntime: NativeCognitionRuntime
    ) -> DreamReceiptSink {
        let runtime = cognitionRuntime
        return { @Sendable kind, payload in
            let substrate = await runtime.substrateForIntegration()
            if kind == DreamCycleRunner.studioCitationReceiptKind {
                guard let text = payload.objectValue?["dreamId"]?.stringValue, let id = UUID(uuidString: text) else {
                    throw PersistenceCoreError.ioFailure("dream citation receipt has no saved dream identity")
                }
                try await substrate.recordReceiptChecked(kind: kind, payload: payload, id: id)
            } else {
                try await substrate.recordReceiptChecked(kind: kind, payload: payload)
            }
            if kind == "dream.lessons" {
                let failed = payload.objectValue?["failed"]?.integerValue ?? 0
                await TurnTraceBus.shared.deliver(TurnTraceEvent(
                    kind: kind, title: "Learned from surprise", status: failed == 0 ? "ok" : "failed",
                    payload: payload, createdAt: NativeTimestampFormat.fractionalZulu(Date()), turn: nil))
            }
        }
    }

    /// Apply explicit dream affect only after commit through the disposition owner’s claims, caps and decay.
    public static func makeDreamMoodSink(
        cognitionRuntime: NativeCognitionRuntime
    ) -> DreamDatedMoodSink {
        let runtime = cognitionRuntime
        return { @Sendable affect, dateKey in
            let substrate = await runtime.substrateForIntegration()
            guard await substrate.configurationSnapshot().enabled else { return .skipped("inner life off") }
            guard await substrate.integrateDreamDisposition(
                tone: affect,
                at: Date(),
                // Claim residue per committed dream using the runner's date key.
                dreamId: "dream:\(dateKey)"
            ) else {
                throw PersistenceCoreError.ioFailure("dream mood \(dateKey) did not persist; its judgment remains owed")
            }
            return .done
        }
    }
}
